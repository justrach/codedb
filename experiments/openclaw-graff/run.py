#!/usr/bin/env python3
"""Baseline: frozen graff + 5.6-luna using codedb on OpenClaw. Records tokens."""

from __future__ import annotations

import json
import os
import re
import subprocess
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
CASES_PATH = Path(os.environ.get("GRAFF_CASES", HERE / "cases.json"))
CASES = json.loads(CASES_PATH.read_text())
CORPUS = Path(CASES["corpus"])
EMPTY_MCP = Path(os.environ.get("GRAFF_MCP_CONFIG", HERE / "empty-mcp.json"))
RESULTS_PATH = Path(os.environ.get("GRAFF_RESULTS", HERE / "results.jsonl"))
USAGE_RE = re.compile(
    r"\[usage\] (\d+) api call\(s\) · (\d+) in \((\d+) cached\) \+ (\d+) out tokens"
)
TOOL_RE = re.compile(r"\[main\] ⚙ (\S+)")
PATH_LINE_RE = re.compile(r"([\w./-]+\.\w+):(\d+)")


def answer_matches(gold: str, stdout: str, answer_text: str) -> bool:
    if gold in stdout or gold in answer_text:
        return True
    gm = PATH_LINE_RE.fullmatch(gold)
    if not gm:
        return gold in stdout
    gpath, gline = gm.group(1), int(gm.group(2))
    for m in PATH_LINE_RE.finditer(stdout):
        if m.group(1) == gpath and abs(int(m.group(2)) - gline) <= 2:
            return True
    return False


def run_case(case: dict) -> dict:
    env = os.environ.copy()
    env["GRAFF_MCP_CONFIG"] = str(EMPTY_MCP)
    env["GRAFF_NO_TELEMETRY"] = "1"
    env["GRAFF_FLEET"] = "off"
    env["CODEDB_ALLOW_TEMP"] = "1"
    env["CODEDB_NO_TELEMETRY"] = "1"
    env["GRAFF_LEARN_AUTO"] = "off"
    codedb_bin = os.environ.get("CODEDB_BIN", str(HERE.parents[1] / "zig-out" / "bin" / "codedb"))
    env["PATH"] = str(Path(codedb_bin).parent) + os.pathsep + env.get("PATH", "")
    argv = [
        "graff", "-p",
        "--model", CASES["model"],
        "--yolo", "--no-telemetry", "--no-resume", "--timing",
        case["task"],
    ]
    started = time.monotonic()
    proc = subprocess.run(
        argv, cwd=CORPUS, env=env, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=180,
    )
    wall = time.monotonic() - started
    answer = (proc.stdout or "").strip().splitlines()
    answer_text = answer[-1] if answer else ""
    usage = {"api_calls": 0, "in_tokens": 0, "cached_tokens": 0, "out_tokens": 0}
    m = USAGE_RE.search(proc.stderr or "")
    if m:
        usage = {
            "api_calls": int(m.group(1)),
            "in_tokens": int(m.group(2)),
            "cached_tokens": int(m.group(3)),
            "out_tokens": int(m.group(4)),
        }
    tools = TOOL_RE.findall(proc.stderr or "")
    gold = case["gold"]
    passed = answer_matches(gold, proc.stdout or "", answer_text)
    return {
        "id": case["id"],
        "gold": gold,
        "answer": answer_text,
        "pass": passed,
        "wall_s": round(wall, 3),
        "tools": tools,
        "used_codedb": any(t == "codedb" for t in tools),
        **usage,
        "exit": proc.returncode,
        "stderr_tail": "\n".join((proc.stderr or "").splitlines()[-8:]),
    }


def main() -> None:
    rows = []
    for case in CASES["cases"]:
        print(f"-- {case['id']}", flush=True)
        row = run_case(case)
        rows.append(row)
        print(
            f"   pass={row['pass']} in={row['in_tokens']} cached={row['cached_tokens']} "
            f"out={row['out_tokens']} tools={row['tools']} answer={row['answer']!r}",
            flush=True,
        )
    out = RESULTS_PATH
    out.write_text("".join(json.dumps(r) + "\n" for r in rows))
    md = ["# OpenClaw × graff × codedb — hard suite", ""]
    md.append(f"- corpus: `{CASES['corpus']}` @ `{CASES['commit']}`")
    md.append(f"- model: `{CASES['provider']}/{CASES['model']}`")
    md.append(f"- codedb: `{CASES['codedb']}`")
    md.append("")
    md.append("| case | pass | in | cached | out | api | tools | answer |")
    md.append("|---|---|---:|---:|---:|---:|---|---|")
    tin = tcache = tout = tapis = 0
    for r in rows:
        tin += r["in_tokens"]
        tcache += r["cached_tokens"]
        tout += r["out_tokens"]
        tapis += r["api_calls"]
        md.append(
            f"| {r['id']} | {r['pass']} | {r['in_tokens']} | {r['cached_tokens']} | "
            f"{r['out_tokens']} | {r['api_calls']} | {','.join(r['tools']) or '—'} | `{r['answer']}` |"
        )
    md.append(f"| **total** | {sum(1 for r in rows if r['pass'])}/{len(rows)} | **{tin}** | **{tcache}** | **{tout}** | **{tapis}** | | |")
    md.append("")
    passed = sum(1 for r in rows if r["pass"])
    score = 0 if not rows else round(100.0 * passed / len(rows))
    md.append(f"Uncached input tokens (in - cached): **{tin - tcache}**.")
    md.append(f"score={score}")
    hist = HERE / "trajectory.md"
    prev = hist.read_text() if hist.exists() else ""
    hist.write_text(prev + ("\n" if prev else "") + "\n".join(md) + "\n")
    print(f"wrote {out} and {hist}")
    print(f"score={score}")


if __name__ == "__main__":
    main()
