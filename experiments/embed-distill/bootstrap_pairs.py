#!/usr/bin/env python3
"""Bootstrap (query, +chunk, -chunks) pairs from codedb context + gold.

Parallel over cases. Optional --graff adds agent-trajectory negatives.
This is the training-pair miner for the 100M/5M-active MoE embedder.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BIN = Path(os.environ.get("CODEDB_BIN", ROOT / "zig-out" / "bin" / "codedb"))
EMPTY_MCP = ROOT / "experiments" / "openclaw-graff" / "empty-mcp.json"
RUN_PY = ROOT / "experiments" / "openclaw-graff" / "run.py"
FILE_RE = re.compile(r"^-\s+(\S+)\s+\(", re.M)
DEFAULT_SUITES = [
    ROOT / "experiments" / "openclaw-graff" / "cases.json",
    ROOT / "experiments" / "react-graff" / "cases.json",
]


def gold_path_line(gold: str) -> tuple[str, int | None]:
    if ":" in gold and gold.rsplit(":", 1)[-1].isdigit():
        p, n = gold.rsplit(":", 1)
        return p, int(n)
    return gold, None


def env() -> dict[str, str]:
    e = os.environ.copy()
    e.update({
        "CODEDB_ALLOW_TEMP": "1",
        "CODEDB_NO_TELEMETRY": "1",
        "CODEDB_NO_CLI_DAEMON": "1",
        "CODEDB_NO_SEARCH_CACHE": "1",
        "CODEDB_CONTEXT_MAX_CANDIDATES": e.get("CODEDB_CONTEXT_MAX_CANDIDATES", "9"),
        "CODEDB_CONTEXT_DEMOTE_TESTS": e.get("CODEDB_CONTEXT_DEMOTE_TESTS", "1"),
        "CODEDB_CONTEXT_TOP_FILES": e.get("CODEDB_CONTEXT_TOP_FILES", "9"),
        "GRAFF_NO_TELEMETRY": "1",
        "GRAFF_FLEET": "off",
        "GRAFF_LEARN_AUTO": "off",
        "GRAFF_MCP_CONFIG": str(EMPTY_MCP),
        "PATH": str(BIN.parent) + os.pathsep + e.get("PATH", ""),
        "CODEDB_BIN": str(BIN),
    })
    return e


def snippet(corpus: Path, rel: str, line: int | None, radius: int = 12) -> str:
    path = corpus / rel
    if not path.is_file():
        return ""
    text = path.read_text(errors="replace")
    lines = text.splitlines()
    if not lines:
        return ""
    if line is None:
        start, end = 0, min(len(lines), 40)
    else:
        i = max(line - 1, 0)
        start, end = max(i - radius, 0), min(i + radius + 1, len(lines))
    body = "\n".join(lines[start:end])
    return f"{rel}\t{start + 1}-{end}\n{body}"


def context_files(corpus: Path, task: str) -> list[str]:
    proc = subprocess.run(
        [str(BIN), str(corpus), "context", task],
        env=env(), text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=60,
    )
    section = proc.stdout.split("## Most-relevant files", 1)
    if len(section) < 2:
        return []
    body = section[1].split("## ", 1)[0]
    return FILE_RE.findall(body)


def one_case(suite_name: str, corpus: Path, commit: str, case: dict) -> dict:
    gpath, gline = gold_path_line(case["gold"])
    ranked = context_files(corpus, case["task"])
    negs = []
    for i, f in enumerate(ranked, 1):
        if f == gpath or f.endswith("/" + gpath):
            continue
        negs.append({
            "path": f,
            "rank": i,
            "text": snippet(corpus, f, None),
            "kind": "bm25-near-miss",
        })
    return {
        "id": f"{suite_name}/{case['id']}",
        "suite": suite_name,
        "commit": commit,
        "query": case["task"],
        "positive": {
            "path": gpath,
            "line": gline,
            "gold": case["gold"],
            "text": snippet(corpus, gpath, gline),
            "kind": "gold",
        },
        "negatives": negs,
        "context_rank": next(
            (i for i, f in enumerate(ranked, 1) if f == gpath or f.endswith("/" + gpath)),
            None,
        ),
        "context_files": ranked,
        "source": "codedb-context+gold",
    }


def load_jobs(paths: list[Path]) -> list[tuple[str, Path, str, dict]]:
    jobs = []
    for p in paths:
        spec = json.loads(p.read_text())
        name = spec.get("schema", p.parent.name).split(".")[1] if "." in spec.get("schema", "") else p.parent.name
        if "openclaw" in str(p):
            name = "openclaw"
        elif "react" in str(p):
            name = "react"
        corpus = Path(spec["corpus"])
        for case in spec["cases"]:
            jobs.append((name, corpus, spec.get("commit", ""), case))
    return jobs


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", type=Path, default=Path(__file__).with_name("pairs.jsonl"))
    ap.add_argument("--workers", type=int, default=8)
    ap.add_argument("--cases", type=Path, nargs="*", default=DEFAULT_SUITES)
    args = ap.parse_args()
    jobs = load_jobs(args.cases)
    rows = []
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        futs = {pool.submit(one_case, *j): j for j in jobs}
        for fut in as_completed(futs):
            row = fut.result()
            rows.append(row)
            print(
                f"  {row['id']} rank={row['context_rank']} negs={len(row['negatives'])}",
                flush=True,
            )
    rows.sort(key=lambda r: r["id"])
    args.out.write_text("".join(json.dumps(r) + "\n" for r in rows))
    hits = sum(1 for r in rows if r["context_rank"] == 1)
    print(f"wrote {args.out} pairs={len(rows)} p@1={hits}/{len(rows)} workers={args.workers}")


if __name__ == "__main__":
    main()
