#!/usr/bin/env python3
"""Typed four-arm Graff mutator for `graff learn`.

The adapter sends only the configured target excerpt and mutation instruction
to the selected Codex model. A local deterministic patcher inserts the returned
clause; the complete parent genome never leaves this process.
"""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
from typing import Any


REQUEST_SCHEMA = "codegraff.learn.mutation.request.v1"
RESPONSE_SCHEMA = "codegraff.learn.mutation.response.v1"
EFFORTS = {"low", "medium", "high", "xhigh", "max", "ultra"}


def fail(message: str) -> "NoReturn":
    print(f"learn_graff_mutator: {message}", file=sys.stderr)
    raise SystemExit(2)


def load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        fail(f"cannot read {path}: {exc}")


def validate_arms(value: Any) -> tuple[list[dict[str, Any]], list[str], dict[str, str], int, int]:
    if not isinstance(value, dict) or value.get("schema") != "codegraff.learn.graff-arms.v1":
        fail("invalid arms schema")
    if value.get("template_egress") is not True:
        fail("arms must explicitly acknowledge template_egress")
    protected = value.get("protected_substrings")
    if not isinstance(protected, list) or not protected or any(not isinstance(item, str) or not item for item in protected):
        fail("protected_substrings must be a non-empty string array")
    maximum_changed = value.get("maximum_changed_bytes")
    maximum_total = value.get("maximum_total_bytes")
    if not isinstance(maximum_changed, int) or not 64 <= maximum_changed <= 4096:
        fail("maximum_changed_bytes must be between 64 and 4096")
    if not isinstance(maximum_total, int) or not 1024 <= maximum_total <= 1_048_576:
        fail("maximum_total_bytes must be between 1024 and 1048576")
    targets = value.get("targets")
    if not isinstance(targets, dict) or not targets:
        fail("targets must be a non-empty object")
    if any(not isinstance(key, str) or not key or not isinstance(text, str) or not text
           for key, text in targets.items()):
        fail("targets must map non-empty names to non-empty paragraphs")
    arms = value.get("arms")
    if not isinstance(arms, list) or not 1 <= len(arms) <= 16:
        fail("between one and sixteen arms are required")
    seen: set[str] = set()
    for index, arm in enumerate(arms):
        if not isinstance(arm, dict) or arm.get("index") != index:
            fail("arm indexes must be exactly 0..3")
        required = ("id", "provider", "model", "focus", "target", "placement")
        if any(not isinstance(arm.get(key), str) or not arm[key] for key in required):
            fail(f"arm {index} has missing fields")
        # An absent effort means this provider cannot pin one; a present one is
        # still verified against the running harness below.
        if arm.get("effort") is not None and arm["effort"] not in EFFORTS:
            fail(f"arm {index} has an unsupported effort")
        if arm["id"] in seen:
            fail(f"arm {index} is a duplicate")
        if arm["placement"] not in {"append", "replace"}:
            fail(f"arm {index} has an unsupported placement")
        fixed_clause = arm.get("fixed_clause")
        if fixed_clause is not None and (not isinstance(fixed_clause, str) or not fixed_clause):
            fail(f"arm {index} has an invalid fixed_clause")
        if arm["target"] not in targets:
            fail(f"arm {index} names an unknown target")
        seen.add(arm["id"])
    return arms, protected, targets, maximum_changed, maximum_total


def request(proc: subprocess.Popen[str], value: dict[str, Any], expected: str) -> dict[str, Any]:
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


def changed_bytes(old: str, new: str) -> int:
    old_bytes, new_bytes = old.encode("utf-8"), new.encode("utf-8")
    prefix = 0
    while prefix < min(len(old_bytes), len(new_bytes)) and old_bytes[prefix] == new_bytes[prefix]:
        prefix += 1
    suffix = 0
    while (suffix < len(old_bytes) - prefix and suffix < len(new_bytes) - prefix
           and old_bytes[-1 - suffix] == new_bytes[-1 - suffix]):
        suffix += 1
    return len(old_bytes) + len(new_bytes) - 2 * prefix - 2 * suffix


def apply_patch(
    raw: str,
    parent: str,
    target: str,
    protected: list[str],
    maximum_changed: int,
    maximum_total: int,
    placement: str = "append",
) -> tuple[str | None, list[str]]:
    violations: list[str] = []
    try:
        patch = json.loads(raw.strip())
    except json.JSONDecodeError:
        return None, ["the response was not one JSON object"]
    if not isinstance(patch, dict) or set(patch) != {"clause"}:
        return None, ["the JSON object must contain only clause"]
    clause = patch.get("clause")
    if not isinstance(clause, str):
        return None, ["clause must be a string"]
    if not clause or clause != clause.strip() or "\0" in clause:
        violations.append("clause was empty, padded, or contained a NUL byte")
    if "\n" in clause:
        violations.append("clause contained a newline")
    new = target + " " + clause if placement == "append" else clause
    if changed_bytes(target, new) > maximum_changed:
        violations.append(f"the patch changed more than {maximum_changed} bytes")
    if violations:
        return None, violations
    child = parent.replace(target, new, 1)
    if len(child.encode("utf-8")) > maximum_total:
        violations.append(f"the merged prompt exceeded {maximum_total} UTF-8 bytes")
    changed_protected = [item for item in protected if child.count(item) != parent.count(item)]
    if changed_protected:
        violations.append(f"the patch changed {len(changed_protected)} protected substrings")
    return (None if violations else child), violations


def executable_snapshot(source: Path) -> Path:
    target = Path(".learn-graff-bin").resolve()
    shutil.copyfile(source, target)
    target.chmod(0o700)
    return target


def mutate(arms_path: Path, graff: Path, request_path: Path, response_path: Path) -> None:
    request_value = load_json(request_path)
    if not isinstance(request_value, dict) or request_value.get("schema") != REQUEST_SCHEMA:
        fail("invalid mutation request schema")
    arms, protected, targets, maximum_changed, configured_total = validate_arms(load_json(arms_path))
    index = request_value.get("candidate_index")
    if not isinstance(index, int) or not 0 <= index < len(arms):
        fail("candidate_index is outside the configured arms")
    arm = arms[index]
    parent_path = request_value.get("parent", {}).get("path")
    child_path = request_value.get("child_path")
    maximum = request_value.get("maximum_bytes")
    instruction = request_value.get("instruction")
    if not isinstance(parent_path, str) or not isinstance(child_path, str):
        fail("invalid genome paths")
    if not isinstance(maximum, int) or maximum <= 0 or not isinstance(instruction, str):
        fail("invalid mutation limits")
    parent = Path(parent_path).read_text(encoding="utf-8")
    missing_parent = [item for item in protected if item not in parent]
    if missing_parent:
        fail("parent prompt is missing configured protected substrings")
    target = targets[arm["target"]]
    if parent.count(target) != 1:
        fail(f"configured target for {arm['id']} must occur exactly once in the parent")
    total_limit = min(maximum, configured_total)

    system = (
        "You draft one concise clause for a coding-agent system prompt. Return ONLY one "
        "strict JSON object with exactly one string field: clause. The local caller applies "
        "it at one fixed target. No analysis, preface, Markdown fence, secrets, or "
        "repository-specific data."
    )
    task = f"""Draft one behavioral clause.

Mutation instruction:
{instruction}

Arm focus:
{arm['focus']}

Success criteria:
- the clause is self-contained, unambiguous, and has no newline
- do not repeat or rewrite the existing paragraph
- the local patch placement is {arm['placement']}
- the local insertion may add at most {maximum_changed} UTF-8 bytes
- keep the locally merged complete prompt within {total_limit} UTF-8 bytes
- return exactly {{"clause":"..."}}

Target paragraph:
<target>
{target}
</target>
"""
    fixed_clause = arm.get("fixed_clause")
    if fixed_clause is not None:
        child, violations = apply_patch(
            json.dumps({"clause": fixed_clause}), parent, target, protected, maximum_changed, total_limit,
            arm["placement"],
        )
    else:
        env = os.environ.copy()
        env["GRAFF_NO_TELEMETRY"] = "1"
        env["GRAFF_BEHAVIOR_TRACE"] = "0"
        env["HARNESS_CLIENT"] = "learn-mutator"
        env.pop("OTEL_EXPORTER_OTLP_ENDPOINT", None)
        env.pop("GRAFF_OTEL_ENDPOINT", None)
        graff_executable = executable_snapshot(graff)
        argv = [
            str(graff_executable), "--json", "--model", arm["provider"], "--no-resume", "--no-telemetry",
            "--max-model-calls", "2", "--max-tool-calls", "0", "--system-prompt", system,
        ]
        proc = subprocess.Popen(
            argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, bufsize=1, env=env,
        )
        try:
            model_event = request(proc, {
                "type": "set_model", "provider": arm["provider"], "model": arm["model"],
            }, "model")
            if model_event.get("provider") != arm["provider"] or model_event.get("model") != arm["model"]:
                fail(f"model pin was not honored for {arm['id']}")
            if arm.get("effort") is not None:
                effort_event = request(proc, {"type": "set_effort", "level": arm["effort"]}, "effort")
                if effort_event.get("level") != arm["effort"] or effort_event.get("applies") is not True:
                    fail(f"effort pin was not honored for {arm['id']}")
            turn = request(proc, {"type": "user", "text": task}, "turn")
            child, violations = apply_patch(
                str(turn.get("text", "")), parent, target, protected, maximum_changed, total_limit,
                arm["placement"],
            )
            if violations:
                correction = (
                    "Your clause failed deterministic validation: "
                    + "; ".join(violations)
                    + ". Return ONLY a corrected JSON object with exactly one clause string. "
                    + "Use one concise clause with no newline or commentary."
                )
                turn = request(proc, {"type": "user", "text": correction}, "turn")
                child, violations = apply_patch(
                    str(turn.get("text", "")), parent, target, protected, maximum_changed, total_limit,
                    arm["placement"],
                )
        finally:
            if proc.stdin is not None:
                proc.stdin.close()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
    validation_fallback = child is None or bool(violations)
    if validation_fallback:
        # Invalid model text never becomes a genome. An unchanged parent is a
        # safe, deterministic non-contender that lets other arms finish.
        child = parent
    assert child is not None
    child_bytes = child.encode("utf-8")
    Path(child_path).write_bytes(child_bytes)
    response = {
        "schema": RESPONSE_SCHEMA,
        "trial_id": request_value.get("trial_id"),
        "candidate_index": index,
        "parent_id": request_value.get("parent", {}).get("id"),
        "child_path": child_path,
        "child_sha256": hashlib.sha256(child_bytes).hexdigest(),
        "description": (
            f"{arm['id']} ({arm['model']}/{arm.get('effort') or 'default'})"
            + ("; frozen confirmation" if fixed_clause is not None else "")
            + ("; validation fallback: parent" if validation_fallback else "")
        ),
    }
    response_path.write_text(json.dumps(response, separators=(",", ":")) + "\n", encoding="utf-8")


def main() -> None:
    if len(sys.argv) == 3 and sys.argv[1] == "--validate":
        validate_arms(load_json(Path(sys.argv[2])))
        print("four Graff mutation arms valid")
        return
    if len(sys.argv) != 6:
        fail("usage: learn_graff_mutator.py ARMS GRAFF mutate REQUEST RESPONSE")
    arms_path, graff_path, operation, request_path, response_path = sys.argv[1:]
    if operation != "mutate":
        fail("only mutate is supported")
    mutate(Path(arms_path), Path(graff_path), Path(request_path), Path(response_path))


if __name__ == "__main__":
    main()
