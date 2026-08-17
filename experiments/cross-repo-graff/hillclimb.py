#!/usr/bin/env python3
"""Cross-repo hill-climb: OpenClaw + React. Keep only if both hold and calls drop."""
from __future__ import annotations

import json
import os
import random
import re
import subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
RUN_PY = ROOT / "experiments" / "openclaw-graff" / "run.py"
EMPTY_MCP = ROOT / "experiments" / "openclaw-graff" / "empty-mcp.json"
SUITES = [
    ("openclaw", ROOT / "experiments" / "openclaw-graff" / "cases.json"),
    ("react", ROOT / "experiments" / "react-graff" / "cases.json"),
]
BIN = Path(os.environ.get("CODEDB_BIN", ROOT / "zig-out" / "bin" / "codedb"))
N_STEPS = int(os.environ.get("HILLCLIMB_STEPS", "50"))
GRAFF_CAP = int(os.environ.get("HILLCLIMB_GRAFF_CAP", "6"))
SEED = int(os.environ.get("HILLCLIMB_SEED", "11"))

# Product defaults — not the OpenClaw-only keep from wave 1.
DEFAULTS = {
    "CODEDB_CONTEXT_PHRASE": "1",
    "CODEDB_CONTEXT_PHRASE_BOOST": "2",
    "CODEDB_CONTEXT_IDENT_SYMBOLS": "1",
    "CODEDB_CONTEXT_MAX_CANDIDATES": "5",
    "CODEDB_CONTEXT_TOP_FILES": "5",
    "CODEDB_CONTEXT_DEMOTE_TESTS": "0",
    "CODEDB_CONTEXT_COVERAGE_BOOST": "0",
}
CHOICES = {
    "CODEDB_CONTEXT_PHRASE": ["0", "1"],
    "CODEDB_CONTEXT_PHRASE_BOOST": ["1", "2", "3", "4"],
    "CODEDB_CONTEXT_IDENT_SYMBOLS": ["0", "1"],
    "CODEDB_CONTEXT_MAX_CANDIDATES": ["5", "7", "9"],
    "CODEDB_CONTEXT_TOP_FILES": ["3", "5"],
    "CODEDB_CONTEXT_DEMOTE_TESTS": ["0", "1"],
    "CODEDB_CONTEXT_COVERAGE_BOOST": ["0", "0.5", "1", "2"],
}
FILE_RE = re.compile(r"^-\s+(\S+)\s+\(", re.M)


def load_suites() -> list[dict]:
    out = []
    for name, path in SUITES:
        spec = json.loads(path.read_text())
        spec["name"] = name
        spec["cases_path"] = str(path)
        out.append(spec)
    return out


def gold_path(gold: str) -> str:
    return gold.split(":", 1)[0]


def base_env(knobs: dict[str, str]) -> dict[str, str]:
    env = os.environ.copy()
    env.update({
        "CODEDB_ALLOW_TEMP": "1",
        "CODEDB_NO_TELEMETRY": "1",
        "CODEDB_NO_CLI_DAEMON": "1",
        "CODEDB_NO_SEARCH_CACHE": "1",
        "GRAFF_NO_TELEMETRY": "1",
        "GRAFF_FLEET": "off",
        "GRAFF_LEARN_AUTO": "off",
        "GRAFF_MCP_CONFIG": str(EMPTY_MCP),
        "PATH": str(BIN.parent) + os.pathsep + env.get("PATH", ""),
        "CODEDB_BIN": str(BIN),
    })
    env.update(knobs)
    return env


def context_rank(corpus: Path, task: str, path: str, env: dict[str, str]) -> int | None:
    proc = subprocess.run(
        [str(BIN), str(corpus), "context", task],
        env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=60,
    )
    section = proc.stdout.split("## Most-relevant files", 1)
    if len(section) < 2:
        return None
    body = section[1].split("## ", 1)[0]
    files = FILE_RE.findall(body)
    for i, f in enumerate(files, 1):
        if f == path or f.endswith("/" + path):
            return i
    return None


def suite_cheap(spec: dict, env: dict[str, str]) -> dict:
    corpus = Path(spec["corpus"])
    ranks = []
    for case in spec["cases"]:
        ranks.append(context_rank(corpus, case["task"], gold_path(case["gold"]), env))
    mrr = 0.0
    hits = 0
    for r in ranks:
        if r:
            mrr += 1.0 / r
            hits += 1
    n = max(len(ranks), 1)
    return {
        "mrr": round(mrr / n, 4),
        "p_at_1": round(sum(1 for r in ranks if r == 1) / n, 4),
        "hits": hits,
        "ranks": ranks,
    }


def cheap_eval(suites: list[dict], knobs: dict[str, str]) -> dict:
    env = base_env(knobs)
    per = {}
    mrrs = []
    for spec in suites:
        s = suite_cheap(spec, env)
        per[spec["name"]] = s
        mrrs.append(s["mrr"])
    return {
        "mrr": round(sum(mrrs) / max(len(mrrs), 1), 4),
        "min_mrr": round(min(mrrs) if mrrs else 0.0, 4),
        "suites": per,
    }


def mutate(parent: dict[str, str], rng: random.Random) -> dict[str, str]:
    child = dict(parent)
    keys = rng.sample(list(CHOICES), k=rng.choice((1, 1, 2)))
    for k in keys:
        opts = [v for v in CHOICES[k] if v != child.get(k)]
        if opts:
            child[k] = rng.choice(opts)
    if child["CODEDB_CONTEXT_PHRASE"] == "0":
        child["CODEDB_CONTEXT_PHRASE_BOOST"] = parent.get("CODEDB_CONTEXT_PHRASE_BOOST", "2")
    return child


def graff_suite(spec: dict, knobs: dict[str, str]) -> dict:
    env = base_env(knobs)
    results = HERE / f"results-{spec['name']}.jsonl"
    env["GRAFF_CASES"] = spec["cases_path"]
    env["GRAFF_RESULTS"] = str(results)
    proc = subprocess.run(
        ["python3", str(RUN_PY)],
        env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=900,
    )
    calls = 0
    passed = 0
    tin = 0
    if results.exists():
        for line in results.read_text().splitlines():
            row = json.loads(line)
            calls += sum(1 for t in row.get("tools", []) if t == "codedb")
            passed += int(bool(row.get("pass")))
            tin += int(row.get("in_tokens") or 0)
    score_m = re.search(r"score=(\d+)", proc.stdout)
    return {
        "graff_score": int(score_m.group(1)) if score_m else passed * 25,
        "codedb_calls": calls,
        "in_tokens": tin,
        "pass_n": passed,
    }


def graff_eval(suites: list[dict], knobs: dict[str, str]) -> dict:
    per = {}
    calls = 0
    tin = 0
    passed = 0
    ncases = 0
    for spec in suites:
        print(f"           graff {spec['name']}...", flush=True)
        g = graff_suite(spec, knobs)
        per[spec["name"]] = g
        calls += g["codedb_calls"]
        tin += g["in_tokens"]
        passed += g["pass_n"]
        ncases += len(spec["cases"])
    score = 0 if not ncases else round(100.0 * passed / ncases)
    return {
        "graff_score": score,
        "codedb_calls": calls,
        "in_tokens": tin,
        "pass_n": passed,
        "graff_suites": per,
    }


def no_suite_regression(parent: dict, child: dict) -> bool:
    for name, p in parent["suites"].items():
        c = child["suites"][name]
        if c["mrr"] + 1e-9 < p["mrr"] - 0.02:
            return False
    return True


def cheap_better(parent: dict, child: dict) -> bool:
    if not no_suite_regression(parent, child):
        return False
    if child["mrr"] > parent["mrr"]:
        return True
    if child["mrr"] == parent["mrr"] and child["min_mrr"] > parent["min_mrr"]:
        return True
    return False


def main() -> None:
    rng = random.Random(SEED)
    suites = load_suites()
    parent = dict(DEFAULTS)
    print("baseline cheap (openclaw+react)...", flush=True)
    best_cheap = cheap_eval(suites, parent)
    best = dict(parent)
    out = HERE / "hillclimb.jsonl"
    out.write_text("")
    rec = {"step": 0, "status": "keep", "knobs": dict(parent), **best_cheap}
    print(
        f"  step=0 KEEP mean={best_cheap['mrr']} min={best_cheap['min_mrr']} "
        f"oc={best_cheap['suites']['openclaw']} react={best_cheap['suites']['react']}",
        flush=True,
    )
    print("  step=0 graff baseline (both suites)...", flush=True)
    g0 = graff_eval(suites, parent)
    rec.update(g0)
    best_calls = g0["codedb_calls"]
    graff_runs = 1
    print(
        f"           graff score={g0['graff_score']} calls={g0['codedb_calls']} in={g0['in_tokens']}",
        flush=True,
    )
    out.write_text(json.dumps(rec) + "\n")
    log = [rec]

    for step in range(1, N_STEPS + 1):
        child = mutate(parent, rng)
        cheap = cheap_eval(suites, child)
        improved = cheap_better(best_cheap, cheap)
        status = "keep-candidate" if improved else "discard"
        row = {"step": step, "status": status, "knobs": child, **cheap}
        if improved and graff_runs < GRAFF_CAP:
            print(
                f"  step={step} cheap-up mean={cheap['mrr']} min={cheap['min_mrr']} — graff...",
                flush=True,
            )
            g = graff_eval(suites, child)
            row.update(g)
            graff_runs += 1
            calls_ok = g["codedb_calls"] <= best_calls
            pass_ok = g["pass_n"] >= rec.get("pass_n", 0) if step == 0 else g["pass_n"] >= log[0].get("pass_n", 0)
            # Accept only if calls do not rise and we didn't lose cases.
            baseline_pass = log[0].get("pass_n", 0)
            if g["pass_n"] >= baseline_pass and g["codedb_calls"] < best_calls:
                status = "keep"
                parent = child
                best = child
                best_cheap = cheap
                best_calls = g["codedb_calls"]
                print(
                    f"           KEEP calls {best_calls} score={g['graff_score']}",
                    flush=True,
                )
            else:
                status = "discard-calls"
                print(
                    f"           discard-calls score={g['graff_score']} "
                    f"calls={g['codedb_calls']} (best={best_calls})",
                    flush=True,
                )
            row["status"] = status
        elif improved:
            print(
                f"  step={step} skip-graff-cap mean={cheap['mrr']} min={cheap['min_mrr']}",
                flush=True,
            )
            row["status"] = "skip-graff-cap"
        else:
            oc = cheap["suites"]["openclaw"]
            rc = cheap["suites"]["react"]
            print(
                f"  step={step} discard mean={cheap['mrr']} min={cheap['min_mrr']} "
                f"oc={oc['mrr']}{oc['ranks']} react={rc['mrr']}{rc['ranks']}",
                flush=True,
            )
        log.append(row)
        with out.open("a") as fh:
            fh.write(json.dumps(row) + "\n")

    out.write_text("".join(json.dumps(r) + "\n" for r in log))
    keeps = [r for r in log if r["status"].startswith("keep")]
    md = [
        "# Cross-repo hill-climb (OpenClaw + React)",
        "",
        f"- steps: {N_STEPS}  seed={SEED}  keeps={len(keeps)}",
        f"- best mean MRR: {best_cheap['mrr']}  min={best_cheap['min_mrr']}",
        f"- best knobs: `{json.dumps(best)}`",
        f"- best codedb_calls: {best_calls}",
        "",
    ]
    hist = HERE / "trajectory.md"
    prev = hist.read_text() if hist.exists() else ""
    hist.write_text(prev + "\n" + "\n".join(md) + "\n")
    print(f"wrote {out}")
    print(f"best {json.dumps(best)} mean={best_cheap['mrr']} calls={best_calls}")


if __name__ == "__main__":
    main()
