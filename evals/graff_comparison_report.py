#!/usr/bin/env python3
"""Export a complete v3 run to portable evidence, omitting sessions and prompts from logs."""
import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re

from graff_comparison import BUNDLE, load_bundle


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def priced_usage(usage):
    required = ("in", "cached", "out", "calls", "cost_usd")
    if not all(key in usage for key in required):
        return None
    if not (0 <= usage["cached"] <= usage["in"]) or usage["out"] < 0:
        raise ValueError("Invalid token accounting")
    # A session below this bound cannot contain a request above the pricing
    # threshold. Larger sessions need per-request usage, not aggregate guessing.
    estimate = None
    if usage["in"] < 200_000:
        estimate = (2 * (usage["in"] - usage["cached"]) + 0.5 * usage["cached"] + 6 * usage["out"]) / 1_000_000
    return {
        "input_including_cached": usage["in"], "cached_input": usage["cached"],
        "uncached_input": usage["in"] - usage["cached"], "output": usage["out"],
        "total_tokens": usage["in"] + usage["out"], "model_calls": usage["calls"],
        "reported_model_charge_usd": usage["cost_usd"], "api_equivalent_usd": estimate,
    }


def tool_stats(path):
    if not path.exists():
        return {"calls": {}, "error_responses": 0}
    calls, ids, errors = Counter(), set(), 0
    for line in path.read_text().splitlines():
        event = json.loads(line)
        m = event["message"]
        if not isinstance(m, dict):
            continue
        if event["direction"] == "in" and m.get("method") == "tools/call":
            calls[m["params"]["name"]] += 1
            ids.add(m["id"])
        if event["direction"] == "out" and m.get("id") in ids:
            errors += bool(m.get("error") or m.get("result", {}).get("isError"))
    return {"calls": dict(calls), "error_responses": errors}


def aggregate(records):
    result = {}
    for arm in ("baseline", "codedb", "graphify"):
        rows = [r for r in records if r["arm"] == arm]
        complete = all(r["usage"] is not None for r in rows)
        total = {
            "attempts": len(rows), "passed": sum(r["passed"] for r in rows),
            "usage_complete": complete,
            "agent_wall_seconds": sum(r["wall_seconds"] for r in rows),
            "index_setup_seconds": sum(r["index_setup"]["seconds"] for r in rows),
            "retrieval_calls": sum(r["retrieval_calls"] for r in rows),
            "workspace_calls": sum(r["workspace_calls"] for r in rows),
            "attempts_with_retrieval": sum(r["retrieval_calls"] > 0 for r in rows),
        }
        if complete:
            for key in rows[0]["usage"]:
                values = [r["usage"][key] for r in rows]
                total[key] = sum(values) if all(v is not None for v in values) else None
        else:
            # Never sum a partial set and present it as the cost of the arm.
            total.update({k: None for k in priced_usage(dict.fromkeys(("in", "cached", "out", "calls", "cost_usd"), 0))})
        total["api_equivalent_per_pass_usd"] = (
            total["api_equivalent_usd"] / total["passed"]
            if total["passed"] and total["api_equivalent_usd"] is not None else None
        )
        result[arm] = total
    return result


def export(source, output):
    manifest = json.loads((source / "manifest.json").read_text())
    freeze = json.loads((source / "freeze.json").read_text())
    if "COMPLETE: 48 attempts; binary hashes unchanged" not in (source / "batch.log").read_text():
        raise ValueError("Study has not completed all attempts and final binary checks")
    for name in ("manifest.json", "run.py", "workspace_mcp.py", "proxy.py"):
        if sha(source / name) != freeze[name]:
            raise ValueError(f"Study file changed after freeze: {name}")
    bundle = load_bundle()
    tasks = {t["id"]: t for t in bundle["tasks"]}
    records, solutions = [], []
    for item in manifest["tasks"]:
        task = tasks[item["family"]]
        if item["hashes"] != {k: v["sha256"] for k, v in task["files"].items()}:
            raise ValueError("Published input does not match frozen input")
        if item["hidden_sha256"] != task["hidden_test"]["sha256"]:
            raise ValueError("Published hidden grader does not match frozen grader")
        for arm in manifest["arms"]:
            area = source / item["id"] / arm
            path = area / "result.json"
            result = json.loads(path.read_text())
            attempt = item["id"] + "/" + arm
            if result["task"] != item["id"] or result["arm"] != arm:
                raise ValueError("Result identity mismatch")
            row = {k: result[k] for k in (
                "arm", "exit_code", "timed_out", "wall_seconds", "passed", "grader_exit_code",
                "tests_spec_unchanged", "isolation_ok", "retrieval_calls", "workspace_calls",
            )}
            row.update(attempt=attempt, family=item["family"], repeat=item["rep"],
                       previously_observed=task["previously_observed_in_comparison"],
                       usage=priced_usage(result["usage"]), result_sha256=sha(path),
                       grader_log_sha256=sha(area / "grader.log"),
                       index_setup=manifest["setup"][attempt])
            row["retrieval_used"] = result["retrieval_calls"] > 0
            row["retrieval_use_deviation"] = arm != "baseline" and not row["retrieval_used"]
            row["tools"] = {kind: tool_stats(area / (kind + ".jsonl")) for kind in ("retrieval", "workspace")}
            for kind in ("retrieval", "workspace"):
                if sum(row["tools"][kind]["calls"].values()) != row[kind + "_calls"]:
                    raise ValueError("Tool counts disagree with saved result")
            if not row["passed"]:
                log = (area / "grader.log").read_text().replace(str(source), "<study>")
                log = re.sub(r"/Users/[^\s\"']+", "<local-path>", log)
                row["failure_grader_excerpt"] = log[-4000:]
            files = {}
            for name in task["editable"]:
                candidate = area / "fixture" / name
                files[name] = {"sha256": sha(candidate), "text": candidate.read_text()}
            row["solution_hashes"] = {k: v["sha256"] for k, v in files.items()}
            solutions.append({"attempt": attempt, "task": task["id"], "files": files})
            records.append(row)
    if len(records) != 48 or len({r["attempt"] for r in records}) != 48:
        raise ValueError("Expected exactly 48 distinct attempts")
    receipt = {
        "schema_version": 1,
        "started_utc": datetime.fromtimestamp(freeze["started"], timezone.utc).isoformat(),
        "design": "8 Python task families x 3 arms x 2 repeats; three concurrent arms per matched block",
        "baseline": "Shared workspace MCP listing/search/read/write/test, without retrieval; not stock Graff defaults",
        "model": "xai/grok-4.6", "graff_version": manifest["graff_version"],
        "graphify_version": manifest["graphify_version"], "graphify_commit": manifest["graphify_commit"],
        "python": manifest["python"], "source_checkout_revision": manifest["source_commit"],
        "source_revision_available_upstream": False,
        "fixture_bundle_sha256": sha(BUNDLE), "freeze": freeze,
        "limits": manifest["limits"], "system_prompt": manifest["system_prompt"],
        "launch_blocks": manifest["blocks"],
        "grader_preflight": json.loads((source / "validation.json").read_text()),
        "posthoc_sensitivity": json.loads((source / "json-stream-sensitivity.json").read_text()),
        "pricing": {
            "source": "https://docs.x.ai/developers/models/grok-4.6", "checked_date": "2026-09-12",
            "usd_per_million": {"uncached_input": 2, "cached_input": 0.5, "output": 6},
            "formula": "(2 * (input - cached) + 0.5 * cached + 6 * output) / 1000000",
            "exclusions": "Subscription fees, hosted embeddings, installation, machine costs, follow-up repair costs",
        },
        "limitations": [
            "Eight task families, not 48 independent tasks; two repeats do not establish a population advantage.",
            "All tasks are small Python fixtures, mostly with the target file named in the prompt.",
            "Five families were new to this comparison; three were previously observed. All are now observed.",
            "Concurrent arms contend for resources; wall time is descriptive, not a clean latency benchmark.",
            "Provider cache was observed, not controlled. API equivalents are not cash savings on the subscription.",
            "Indexes were explicitly prepared; this does not test first installation or automatic refresh.",
            "Setup includes semantic-index for CodeDB and AST-only graphify update for Graphify; indexing capabilities differ.",
            "Retrieval use was requested but not enforced by the grader. Deviating attempts remain in the primary results.",
            "The JSON-sequence whitespace-only gold check is underspecified by the supplied specification; sensitivity results do not replace strict scores.",
        ],
        "totals": aggregate(records), "records": records,
    }
    output.mkdir(parents=True, exist_ok=False)
    solution_path = output / "solutions-v3.json"
    solution_path.write_text(json.dumps({
        "schema_version": 1, "fixture_bundle_sha256": sha(BUNDLE),
        "notice": "Model-generated repairs of the licensed fixture bundle; see CODEGRAFF-LICENSE.txt.",
        "solutions": solutions,
    }, indent=2) + "\n")
    receipt["solutions_sha256"] = sha(solution_path)
    (output / "results-v3.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt["totals"], indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path, help="New directory, never overwritten")
    args = parser.parse_args()
    export(args.source, args.output)
