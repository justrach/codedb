#!/usr/bin/env python3
"""50-step hill-climb of codedb context knobs on the frozen OpenClaw suite.

Cheap metric (every step): MRR of the gold file in `codedb context`.
Graff+luna (on a new best, capped): real agent codedb-call count.
"""
from __future__ import annotations

import json
import os
import random
import re
import subprocess
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
CASES = json.loads((HERE / "cases.json").read_text())
CORPUS = Path(CASES["corpus"])
BIN = Path(os.environ.get("CODEDB_BIN", HERE.parents[1] / "zig-out" / "bin" / "codedb"))
N_STEPS = int(os.environ.get("HILLCLIMB_STEPS", "50"))
GRAFF_CAP = int(os.environ.get("HILLCLIMB_GRAFF_CAP", "8"))
SEED = int(os.environ.get("HILLCLIMB_SEED", "7"))

DEFAULTS = {
    "CODEDB_CONTEXT_PHRASE": "1",
    "CODEDB_CONTEXT_PHRASE_BOOST": "2",
    "CODEDB_CONTEXT_IDENT_SYMBOLS": "1",
    "CODEDB_CONTEXT_MAX_CANDIDATES": "7",
    "CODEDB_CONTEXT_TOP_FILES": "5",
    "CODEDB_CONTEXT_DEMOTE_TESTS": "1",
    "CODEDB_CONTEXT_COVERAGE_BOOST": "0",
}
CHOICES = {
    "CODEDB_CONTEXT_PHRASE": ["0", "1"],
    "CODEDB_CONTEXT_PHRASE_BOOST": ["1", "1.5", "2", "2.5", "3", "4"],
    "CODEDB_CONTEXT_IDENT_SYMBOLS": ["0", "1"],
    "CODEDB_CONTEXT_MAX_CANDIDATES": ["5", "7", "9"],
    "CODEDB_CONTEXT_TOP_FILES": ["3", "5", "8"],
    "CODEDB_CONTEXT_DEMOTE_TESTS": ["0", "1"],
    "CODEDB_CONTEXT_COVERAGE_BOOST": ["0", "0.25", "0.5", "1", "1.5", "2"],
}
FILE_RE = re.compile(r"^-\s+(\S+)\s+\(", re.M)


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
        "GRAFF_MCP_CONFIG": str(HERE / "empty-mcp.json"),
        "PATH": str(BIN.parent) + os.pathsep + env.get("PATH", ""),
    })
    env.update(knobs)
    return env


def context_rank(task: str, path: str, env: dict[str, str]) -> int | None:
    proc = subprocess.run(
        [str(BIN), str(CORPUS), "context", task],
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


def cheap_eval(knobs: dict[str, str]) -> dict:
    env = base_env(knobs)
    ranks = []
    for case in CASES["cases"]:
        r = context_rank(case["task"], gold_path(case["gold"]), env)
        ranks.append(r)
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


def graff_eval(knobs: dict[str, str]) -> dict:
    env = base_env(knobs)
    env["CODEDB_BIN"] = str(BIN)
    proc = subprocess.run(
        ["python3", str(HERE / "run.py")],
        env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=900,
    )
    calls = 0
    passed = 0
    tin = 0
    for line in (HERE / "results.jsonl").read_text().splitlines():
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


def main() -> None:
    rng = random.Random(SEED)
    parent = dict(DEFAULTS)
    print("baseline cheap...", flush=True)
    best_cheap = cheap_eval(parent)
    best = dict(parent)
    log = []
    out = HERE / "hillclimb.jsonl"
    out.write_text("")
    rec = {
        "step": 0, "status": "keep", "knobs": dict(parent),
        **best_cheap, "description": "baseline (current defaults)",
    }
    log.append(rec)
    print(f"  step=0 KEEP mrr={best_cheap['mrr']} p@1={best_cheap['p_at_1']} ranks={best_cheap['ranks']}", flush=True)
    print("  step=0 graff baseline...", flush=True)
    g0 = graff_eval(parent)
    rec.update(g0)
    graff_runs = 1
    print(f"           graff score={g0['graff_score']} calls={g0['codedb_calls']} in={g0['in_tokens']}", flush=True)
    out.write_text(json.dumps(rec) + "\n")

    for step in range(1, N_STEPS + 1):
        child = mutate(parent, rng)
        cheap = cheap_eval(child)
        improved = cheap["mrr"] > best_cheap["mrr"] or (
            cheap["mrr"] == best_cheap["mrr"] and cheap["p_at_1"] > best_cheap["p_at_1"]
        )
        status = "keep" if improved else "discard"
        row = {"step": step, "status": status, "knobs": child, **cheap}
        if improved:
            parent = child
            best = child
            best_cheap = cheap
            if graff_runs < GRAFF_CAP:
                print(f"  step={step} KEEP mrr={cheap['mrr']} — graff confirm...", flush=True)
                g = graff_eval(child)
                row.update(g)
                graff_runs += 1
                print(f"           graff score={g['graff_score']} calls={g['codedb_calls']} in={g['in_tokens']}", flush=True)
            else:
                print(f"  step={step} KEEP mrr={cheap['mrr']} p@1={cheap['p_at_1']} ranks={cheap['ranks']}", flush=True)
        else:
            print(f"  step={step} discard mrr={cheap['mrr']} p@1={cheap['p_at_1']} ranks={cheap['ranks']}", flush=True)
        log.append(row)
        with out.open("a") as fh:
            fh.write(json.dumps(row) + "\n")

    out = HERE / "hillclimb.jsonl"
    out.write_text("".join(json.dumps(r) + "\n" for r in log))
    keeps = [r for r in log if r["status"] == "keep"]
    md = [
        "# OpenClaw hill-climb",
        "",
        f"- steps: {N_STEPS}  seed={SEED}  keeps={len(keeps)}",
        f"- best MRR: {best_cheap['mrr']}  p@1={best_cheap['p_at_1']}  ranks={best_cheap['ranks']}",
        f"- best knobs: `{json.dumps(best)}`",
        "",
        "| step | status | mrr | p@1 | ranks | knobs |",
        "|---:|---|---:|---:|---|---|",
    ]
    for r in log:
        md.append(
            f"| {r['step']} | {r['status']} | {r['mrr']} | {r['p_at_1']} | {r['ranks']} | `{json.dumps(r['knobs'])}` |"
        )
    hist = HERE / "trajectory.md"
    prev = hist.read_text() if hist.exists() else ""
    hist.write_text(prev + "\n" + "\n".join(md) + "\n")
    print(f"wrote {out}")
    print(f"best {json.dumps(best)} mrr={best_cheap['mrr']}")


if __name__ == "__main__":
    main()
