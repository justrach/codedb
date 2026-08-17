#!/usr/bin/env python3
"""Typed deterministic-task evaluator for model-backed Graff prompt tournaments."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import runpy
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from typing import Any, Callable

REQUEST_SCHEMA = "codegraff.learn.evaluation.request.v1"
RESPONSE_SCHEMA = "codegraff.learn.evaluation.response.v1"
BASELINE_REQUEST_SCHEMA = "codegraff.learn.primary-baseline.request.v1"
BASELINE_RESPONSE_SCHEMA = "codegraff.learn.primary-baseline.response.v1"
PRIMARY_REQUEST_SCHEMA = "codegraff.learn.primary-evaluation.request.v1"
PRIMARY_RESPONSE_SCHEMA = "codegraff.learn.primary-evaluation.response.v1"
PROGRESS_SCHEMA = "codegraff.learn.evaluator-progress.v1"
ATTEMPT_SCHEMA = "codegraff.learn.evaluator-attempt.v1"
METRIC_FIELDS = ("latency_ms", "tool_calls", "cost_micros")
MAX_EXACT_INTEGER = 9_007_199_254_740_991

class EvaluationAttemptError(Exception):
    """A bounded model turn failed before producing gradeable evidence."""

    def __init__(
        self,
        message: str,
        *,
        latency_ms: int = 0,
        tool_calls: int = 0,
        cost_micros: int = 0,
    ) -> None:
        super().__init__(message)
        self.latency_ms = max(0, latency_ms)
        self.tool_calls = max(0, tool_calls)
        self.cost_micros = max(0, cost_micros)

def fail(message: str) -> "NoReturn":
    print(f"learn_graff_evaluator: {message}", file=sys.stderr)
    raise SystemExit(2)

def load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        fail(f"cannot read {path}: {exc}")

def request_pairs(request: dict[str, Any]) -> list[dict[str, Any]]:
    pairs = request.get("pairs")
    if not isinstance(pairs, list) or any(not isinstance(pair, dict) for pair in pairs):
        fail("request pairs must be an object array")
    return pairs

def load_progress(
    path: Path,
    request_path: Path,
    pairs: list[dict[str, Any]],
) -> tuple[str, list[dict[str, Any]]]:
    request_sha256 = hashlib.sha256(request_path.read_bytes()).hexdigest()
    if not path.exists():
        return request_sha256, []
    value = load_json(path)
    if (not isinstance(value, dict) or value.get("schema") != PROGRESS_SCHEMA
            or value.get("request_sha256") != request_sha256):
        fail("evaluator progress does not match the request")
    results = value.get("results")
    if not isinstance(results, list) or len(results) > len(pairs):
        fail("invalid evaluator progress results")
    for result, pair in zip(results, pairs):
        if (not isinstance(result, dict) or result.get("case_id") != pair.get("case_id")
                or result.get("seed") != pair.get("seed")):
            fail("evaluator progress is not a valid pair prefix")
    return request_sha256, results

def save_json_atomic(path: Path, value: Any) -> None:
    temporary = path.with_name(path.name + ".tmp")
    with temporary.open("w", encoding="utf-8") as output:
        output.write(json.dumps(value, separators=(",", ":")) + "\n")
        output.flush()
        os.fsync(output.fileno())
    temporary.replace(path)
    if hasattr(os, "O_DIRECTORY"):
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)

def save_progress(path: Path, request_sha256: str, results: list[dict[str, Any]]) -> None:
    save_json_atomic(path, {
        "schema": PROGRESS_SCHEMA,
        "request_sha256": request_sha256,
        "results": results,
    })

def zero_metrics() -> dict[str, int]:
    return {field: 0 for field in METRIC_FIELDS}

def add_metrics(left: dict[str, int], right: dict[str, int]) -> dict[str, int]:
    return {
        field: min(MAX_EXACT_INTEGER, max(0, left[field]) + max(0, right[field]))
        for field in METRIC_FIELDS
    }

def attempt_key(
    request_sha256: str,
    pair: dict[str, Any],
    label: str,
    prompt: str,
) -> str:
    framed = json.dumps([
        request_sha256,
        pair.get("case_id"),
        pair.get("seed"),
        label,
        hashlib.sha256(prompt.encode("utf-8")).hexdigest(),
    ], separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(b"codegraff-learn/attempt/v1\0" + framed).hexdigest()

def load_attempt(path: Path, key: str) -> tuple[dict[str, int], dict[str, Any] | None]:
    if not path.exists():
        return zero_metrics(), None
    value = load_json(path)
    if not isinstance(value, dict) or value.get("schema") != ATTEMPT_SCHEMA:
        fail("invalid evaluator attempt journal")
    if value.get("key") != key:
        return zero_metrics(), None
    metrics = value.get("metrics")
    if (not isinstance(metrics, dict)
            or any(not isinstance(metrics.get(field), int)
                   or not 0 <= metrics[field] <= MAX_EXACT_INTEGER
                   for field in METRIC_FIELDS)):
        fail("invalid evaluator attempt metrics")
    normalized = {field: metrics[field] for field in METRIC_FIELDS}
    if value.get("complete") is not True:
        return normalized, None
    result = value.get("result")
    if (not isinstance(result, dict) or not isinstance(result.get("pass"), bool)
            or not isinstance(result.get("score_ppm"), int)
            or not 0 <= result["score_ppm"] <= 1_000_000
            or any(result.get(field) != normalized[field] for field in METRIC_FIELDS)):
        fail("invalid completed evaluator attempt")
    return normalized, dict(result)

def save_attempt(
    path: Path,
    key: str,
    metrics: dict[str, int],
    result: dict[str, Any] | None = None,
) -> None:
    save_json_atomic(path, {
        "schema": ATTEMPT_SCHEMA,
        "key": key,
        "complete": result is not None,
        "metrics": metrics,
        "result": result,
    })

def clear_attempt(path: Path) -> None:
    path.unlink(missing_ok=True)

def validate_settings(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict) or value.get("schema") != "codegraff.learn.graff-evaluator.v1":
        fail("invalid evaluator settings schema")
    if not isinstance(value.get("provider"), str) or not value["provider"]:
        fail("evaluator must pin a provider")
    if not isinstance(value.get("model"), str) or not value["model"]:
        fail("evaluator must pin a model")
    # Absent effort means the pinned provider cannot apply one.
    if value.get("effort") is not None and value["effort"] not in {"low", "medium", "high", "xhigh", "max", "ultra"}:
        fail("invalid evaluator effort")
    for field in ("max_model_calls", "max_tool_calls", "max_attempts", "task_timeout_seconds"):
        if not isinstance(value.get(field), int) or value[field] <= 0:
            fail(f"invalid {field}")
    if value["max_attempts"] > 3:
        fail("max_attempts must be at most 3")
    return value

def send(proc: subprocess.Popen[str], value: dict[str, Any], expected: str) -> dict[str, Any]:
    assert proc.stdin is not None and proc.stdout is not None
    proc.stdin.write(json.dumps(value, separators=(",", ":")) + "\n")
    proc.stdin.flush()
    for raw in proc.stdout:
        try:
            event = json.loads(raw)
        except json.JSONDecodeError:
            continue
        if not isinstance(event, dict):
            continue
        if event.get("type") == "error":
            fail(f"Graff error during {expected}: {event.get('message', 'unknown')}")
        if event.get("type") == expected:
            return event
    fail(f"Graff exited before {expected}")

def safe_setup(root: Path, files: Any) -> None:
    if files is None:
        return
    if not isinstance(files, dict):
        fail("setup_files must be an object")
    resolved_root = root.resolve()
    for raw_name, content in files.items():
        if not isinstance(raw_name, str) or not isinstance(content, str):
            fail("setup file names and contents must be strings")
        target = (root / raw_name).resolve()
        if target == resolved_root or resolved_root not in target.parents:
            fail("setup path escapes task scratch")
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8")


def executable_snapshot(source: Path) -> Path:
    target = Path(".learn-graff-bin").resolve()
    if not target.exists():
        shutil.copyfile(source, target)
        target.chmod(0o700)
    return target


def run_variant(
    graff: Path,
    settings: dict[str, Any],
    prompt: str,
    case: dict[str, Any],
    cwd: Path,
    observe: Callable[[dict[str, int]], None] | None = None,
) -> dict[str, Any]:
    support_path = os.environ.get("GRAFF_LEARN_INPUT_4")
    support = runpy.run_path(support_path or str(Path(__file__).with_name("learn_graff_case.py")))
    env = os.environ.copy()
    env["GRAFF_NO_TELEMETRY"] = "1"
    env["GRAFF_BEHAVIOR_TRACE"] = "full"
    env["HARNESS_CLIENT"] = "learn-evaluator"
    env.pop("OTEL_EXPORTER_OTLP_ENDPOINT", None)
    env.pop("GRAFF_OTEL_ENDPOINT", None)
    argv = [
        str(graff), "--json", "--model", settings["provider"], "--no-resume", "--no-telemetry", "--yolo",
        "--max-model-calls", str(settings["max_model_calls"]),
        "--max-tool-calls", str(settings["max_tool_calls"]),
    ]
    started = time.monotonic()
    proc = subprocess.Popen(
        argv, cwd=cwd, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, text=True, bufsize=1,
    )
    timer = threading.Timer(settings["task_timeout_seconds"], proc.kill)
    timer.start()
    tool_calls = 0
    final: dict[str, Any] | None = None
    attempt_error: str | None = None
    cost_micros = 0
    try:
        prompt_event = send(proc, {"type": "set_system_prompt", "text": prompt}, "system_prompt")
        if prompt_event.get("ok") is not True or prompt_event.get("chars") != len(prompt.encode("utf-8")):
            fail("evaluator system prompt was not honored")
        model = send(proc, {
            "type": "set_model", "provider": settings["provider"], "model": settings["model"],
        }, "model")
        if model.get("provider") != settings["provider"] or model.get("model") != settings["model"]:
            fail("evaluator model pin was not honored")
        if settings.get("effort") is not None:
            effort = send(proc, {"type": "set_effort", "level": settings["effort"]}, "effort")
            if effort.get("level") != settings["effort"] or effort.get("applies") is not True:
                fail("evaluator effort pin was not honored")
        assert proc.stdin is not None and proc.stdout is not None
        proc.stdin.write(json.dumps({"type": "user", "text": case["task"]}, separators=(",", ":")) + "\n")
        proc.stdin.flush()
        for raw in proc.stdout:
            try:
                event = json.loads(raw)
            except json.JSONDecodeError:
                continue
            if not isinstance(event, dict):
                continue
            if "cost_usd" in event:
                cost_micros = support["reported_cost_micros"](event)
            if event.get("type") == "tool_call":
                tool_calls += 1
            if observe is not None:
                observe({
                    "latency_ms": max(0, round((time.monotonic() - started) * 1000)),
                    "tool_calls": tool_calls,
                    "cost_micros": cost_micros,
                })
            if event.get("type") == "error":
                attempt_error = f"evaluation turn failed: {event.get('message', 'unknown')}"
                break
            elif event.get("type") == "turn":
                if event.get("complete") is not True:
                    attempt_error = "evaluation turn was incomplete"
                    break
                final = event
                break
    finally:
        timer.cancel()
        if proc.stdin is not None:
            proc.stdin.close()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
    latency_ms = max(0, round((time.monotonic() - started) * 1000))
    if observe is not None:
        observe({
            "latency_ms": latency_ms,
            "tool_calls": tool_calls,
            "cost_micros": cost_micros,
        })
    if attempt_error is not None:
        raise EvaluationAttemptError(
            attempt_error,
            latency_ms=latency_ms,
            tool_calls=tool_calls,
            cost_micros=cost_micros,
        )
    if final is None:
        raise EvaluationAttemptError(
            "evaluation produced no terminal turn",
            latency_ms=latency_ms,
            tool_calls=tool_calls,
            cost_micros=cost_micros,
        )
    behavior = {"measured": False, "score_ppm": 0}
    metrics_module = os.environ.get("GRAFF_LEARN_INPUT_2")
    if metrics_module:
        try:
            behavior = runpy.run_path(metrics_module)["audited_behavior_metrics"](cwd, tool_calls)
            tool_calls = behavior["tool_calls"]
        except (OSError, RuntimeError, subprocess.SubprocessError) as exc:
            raise EvaluationAttemptError(
                f"behavioral metric audit failed: {exc}",
                latency_ms=latency_ms, tool_calls=tool_calls, cost_micros=cost_micros,
            ) from exc
    try:
        passed = support["check_case"](case, str(final.get("text", "")), cwd)
    except ValueError as exc:
        fail(str(exc))
    return {
        "pass": passed,
        "score_ppm": 1_000_000 if passed else 0,
        "cost_micros": cost_micros,
        "latency_ms": latency_ms,
        "tool_calls": tool_calls,
        "behavior_measured": behavior["measured"],
        "behavior_score_ppm": behavior["score_ppm"],
    }


def run_with_retries(
    graff: Path,
    settings: dict[str, Any],
    prompt: str,
    case: dict[str, Any],
    label: str,
    key: str,
    journal_path: Path,
) -> dict[str, Any]:
    prior, completed = load_attempt(journal_path, key)
    if completed is not None:
        return completed
    last_error: EvaluationAttemptError | None = None
    for _attempt in range(settings["max_attempts"]):
        scratch = Path(tempfile.mkdtemp(prefix=f"learn-{label}-", dir="."))
        try:
            safe_setup(scratch, case.get("setup_files"))

            def observe(attempt: dict[str, int]) -> None:
                save_attempt(journal_path, key, add_metrics(prior, attempt))

            run = run_variant(graff, settings, prompt, case, scratch, observe)
            total = add_metrics(prior, {field: run[field] for field in METRIC_FIELDS})
            for field in METRIC_FIELDS:
                run[field] = total[field]
            save_attempt(journal_path, key, total, run)
            return run
        except EvaluationAttemptError as exc:
            last_error = exc
            prior = add_metrics(prior, {
                "latency_ms": exc.latency_ms,
                "tool_calls": exc.tool_calls,
                "cost_micros": exc.cost_micros,
            })
            save_attempt(journal_path, key, prior)
        finally:
            shutil.rmtree(scratch, ignore_errors=True)
    fail(f"evaluation failed after bounded retries: {last_error}")


def load_request_suite(request_path: Path, expected_schema: str) -> tuple[dict[str, Any], dict[str, Any], dict[str, Any]]:
    request = load_json(request_path)
    suite = load_json(Path(request.get("suite_path", ""))) if isinstance(request, dict) else None
    if not isinstance(request, dict) or request.get("schema") != expected_schema:
        fail("invalid evaluation request schema")
    if not isinstance(suite, dict) or suite.get("schema") != "codegraff.learn.suite.v1":
        fail("invalid suite schema")
    cases = suite.get("cases")
    if not isinstance(cases, list):
        fail("suite cases must be an array")
    case_map = {case.get("id"): case.get("payload") for case in cases if isinstance(case, dict)}
    return request, suite, case_map


def case_for_pair(pair: Any, case_map: dict[str, Any]) -> dict[str, Any]:
    if not isinstance(pair, dict) or pair.get("case_id") not in case_map:
        fail("pair references an unknown case")
    case = case_map[pair["case_id"]]
    if not isinstance(case, dict) or not isinstance(case.get("task"), str):
        fail("case payload must contain a task")
    return case


def evaluate(settings_path: Path, graff: Path, request_path: Path, response_path: Path) -> None:
    settings = validate_settings(load_json(settings_path))
    request, _, case_map = load_request_suite(request_path, REQUEST_SCHEMA)
    parent = Path(request["parent"]["path"]).read_text(encoding="utf-8")
    child = Path(request["child"]["path"]).read_text(encoding="utf-8")
    graff_executable = executable_snapshot(graff)
    pairs = request_pairs(request)
    progress_path = Path(".paired-progress.json")
    request_sha256, results = load_progress(progress_path, request_path, pairs)
    for pair in pairs[len(results):]:
        case = case_for_pair(pair, case_map)
        runs: dict[str, dict[str, Any]] = {}
        order = (("parent", parent), ("child", child))
        if int(str(pair.get("seed", "0"))[-1], 16) % 2:
            order = tuple(reversed(order))
        for label, prompt in order:
            journal = Path(f".attempt-{label}.json")
            runs[label] = run_with_retries(
                graff_executable, settings, prompt, case, label,
                attempt_key(request_sha256, pair, label, prompt), journal,
            )
        parent_run = runs["parent"]
        child_run = runs["child"]
        results.append({
            "case_id": pair["case_id"], "seed": pair["seed"],
            "parent_pass": parent_run["pass"], "child_pass": child_run["pass"],
            "parent_score_ppm": parent_run["score_ppm"], "child_score_ppm": child_run["score_ppm"],
            "parent_cost_micros": parent_run["cost_micros"], "child_cost_micros": child_run["cost_micros"],
            "parent_latency_ms": parent_run["latency_ms"], "child_latency_ms": child_run["latency_ms"],
            "latency_measured": True,
            "tool_calls_measured": True,
            "parent_tool_calls": parent_run["tool_calls"], "child_tool_calls": child_run["tool_calls"],
            "behavior_measured": bool(parent_run.get("behavior_measured")) and bool(child_run.get("behavior_measured")),
            "parent_behavior_score_ppm": parent_run.get("behavior_score_ppm", 0), "child_behavior_score_ppm": child_run.get("behavior_score_ppm", 0),
        })
        save_progress(progress_path, request_sha256, results)
        clear_attempt(Path(".attempt-parent.json"))
        clear_attempt(Path(".attempt-child.json"))
    response = {
        "schema": RESPONSE_SCHEMA,
        "trial_id": request.get("trial_id"),
        "candidate_index": request.get("candidate_index"),
        "cohort_id": request.get("cohort_id"),
        "suite_sha256": request.get("suite_sha256"),
        "parent_id": request.get("parent", {}).get("id"),
        "child_id": request.get("child", {}).get("id"),
        "pairs": results,
    }
    response_path.write_text(json.dumps(response, separators=(",", ":")) + "\n", encoding="utf-8")


def evaluate_baseline(settings_path: Path, graff: Path, request_path: Path, response_path: Path) -> None:
    settings = validate_settings(load_json(settings_path))
    request, _, case_map = load_request_suite(request_path, BASELINE_REQUEST_SCHEMA)
    parent = Path(request["parent"]["path"]).read_text(encoding="utf-8")
    graff_executable = executable_snapshot(graff)
    pairs = request_pairs(request)
    progress_path = Path(".baseline-progress.json")
    request_sha256, results = load_progress(progress_path, request_path, pairs)
    for pair in pairs[len(results):]:
        case = case_for_pair(pair, case_map)
        journal = Path(".attempt-baseline.json")
        run = run_with_retries(
            graff_executable, settings, parent, case, "baseline",
            attempt_key(request_sha256, pair, "baseline", parent), journal,
        )
        results.append({
            "case_id": pair["case_id"], "seed": pair["seed"],
            "pass": run["pass"], "score_ppm": run["score_ppm"],
            "cost_micros": run["cost_micros"], "latency_ms": run["latency_ms"],
            "latency_measured": True, "tool_calls_measured": True,
            "tool_calls": run["tool_calls"],
            "behavior_measured": bool(run.get("behavior_measured")), "behavior_score_ppm": run.get("behavior_score_ppm", 0),
        })
        save_progress(progress_path, request_sha256, results)
        clear_attempt(journal)
    response = {
        "schema": BASELINE_RESPONSE_SCHEMA,
        "trial_id": request.get("trial_id"),
        "cohort_id": request.get("cohort_id"),
        "suite_sha256": request.get("suite_sha256"),
        "parent_id": request.get("parent", {}).get("id"),
        "pairs": results,
    }
    response_path.write_text(json.dumps(response, separators=(",", ":")) + "\n", encoding="utf-8")


def evaluate_primary(settings_path: Path, graff: Path, request_path: Path, response_path: Path) -> None:
    settings = validate_settings(load_json(settings_path))
    request, _, case_map = load_request_suite(request_path, PRIMARY_REQUEST_SCHEMA)
    baseline = load_json(Path(request.get("baseline", {}).get("path", "")))
    if not isinstance(baseline, dict) or baseline.get("schema") != BASELINE_RESPONSE_SCHEMA:
        fail("invalid primary baseline")
    pairs = request_pairs(request)
    baseline_pairs = baseline.get("pairs")
    if not isinstance(baseline_pairs, list) or len(baseline_pairs) != len(pairs):
        fail("primary baseline pair count mismatch")
    child = Path(request["child"]["path"]).read_text(encoding="utf-8")
    graff_executable = executable_snapshot(graff)
    progress_path = Path(".primary-progress.json")
    request_sha256, results = load_progress(progress_path, request_path, pairs)
    for pair, parent_run in zip(pairs[len(results):], baseline_pairs[len(results):]):
        case = case_for_pair(pair, case_map)
        if (not isinstance(parent_run, dict)
                or parent_run.get("case_id") != pair.get("case_id")
                or parent_run.get("seed") != pair.get("seed")):
            fail("primary baseline pair mismatch")
        journal = Path(".attempt-child.json")
        child_run = run_with_retries(
            graff_executable, settings, child, case, "child",
            attempt_key(request_sha256, pair, "child", child), journal,
        )
        results.append({
            "case_id": pair["case_id"], "seed": pair["seed"],
            "parent_pass": parent_run.get("pass"), "child_pass": child_run["pass"],
            "parent_score_ppm": parent_run.get("score_ppm"), "child_score_ppm": child_run["score_ppm"],
            "parent_cost_micros": parent_run.get("cost_micros", 0), "child_cost_micros": child_run["cost_micros"],
            "parent_latency_ms": parent_run.get("latency_ms", 0), "child_latency_ms": child_run["latency_ms"],
            "latency_measured": bool(parent_run.get("latency_measured")),
            "tool_calls_measured": bool(parent_run.get("tool_calls_measured")),
            "parent_tool_calls": parent_run.get("tool_calls", 0), "child_tool_calls": child_run["tool_calls"],
            "behavior_measured": bool(parent_run.get("behavior_measured")) and bool(child_run.get("behavior_measured")),
            "parent_behavior_score_ppm": parent_run.get("behavior_score_ppm", 0), "child_behavior_score_ppm": child_run.get("behavior_score_ppm", 0),
        })
        save_progress(progress_path, request_sha256, results)
        clear_attempt(journal)
    response = {
        "schema": PRIMARY_RESPONSE_SCHEMA,
        "trial_id": request.get("trial_id"),
        "candidate_index": request.get("candidate_index"),
        "cohort_id": request.get("cohort_id"),
        "suite_sha256": request.get("suite_sha256"),
        "parent_id": request.get("parent_id"),
        "child_id": request.get("child", {}).get("id"),
        "pairs": results,
    }
    response_path.write_text(json.dumps(response, separators=(",", ":")) + "\n", encoding="utf-8")


def main() -> None:
    if len(sys.argv) == 3 and sys.argv[1] == "--validate":
        validate_settings(load_json(Path(sys.argv[2])))
        print("Graff evaluator settings valid")
        return
    if len(sys.argv) != 6:
        fail("usage: learn_graff_evaluator.py SETTINGS GRAFF OPERATION REQUEST RESPONSE")
    settings_path, graff_path, operation, request_path, response_path = sys.argv[1:]
    operations = {
        "evaluate": evaluate,
        "baseline": evaluate_baseline,
        "evaluate_primary": evaluate_primary,
    }
    handler = operations.get(operation)
    if handler is None:
        fail("unsupported evaluator operation")
    handler(Path(settings_path), Path(graff_path), Path(request_path), Path(response_path))


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as exc:
        fail(f"unexpected {type(exc).__name__}: {exc}")
