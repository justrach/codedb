#!/usr/bin/env python3
"""Replay + verify the SWE-bench Lite file-localization snapshot.

This is NOT a live SWE-bench runner. It loads `results.json` (a frozen
record of agent runs on 4 SWE-bench Lite instances, populated by hand
from agent traces), recomputes the per-backend averages from the raw
cells, and asserts they match the summary block. Then prints a
dominance table.

A live runner (that actually launches each backend, sends the issue
text, captures the agent's `files` list, and patch-tests the result)
is out of scope for this snapshot and tracked separately.

Usage:
    python3 replay.py                # verify + print dominance table
    python3 replay.py --json         # print raw recomputed summary as JSON
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from statistics import mean

SNAPSHOT = Path(__file__).resolve().parent / "results.json"


def recompute(snapshot: dict) -> dict:
    by_backend: dict[str, dict] = {}
    cells_by_backend: dict[str, list[dict]] = {}
    for cell in snapshot["cells"]:
        cells_by_backend.setdefault(cell["backend"], []).append(cell)

    n_tasks = len(snapshot["tasks"])
    for backend, cells in cells_by_backend.items():
        recall_hits = sum(1 for c in cells if c["recall"])
        top1_hits = sum(1 for c in cells if c["top_1"])
        by_backend[backend] = {
            "recall": f"{recall_hits}/{n_tasks}",
            "top_1": f"{top1_hits}/{n_tasks}",
            "avg_tool_calls": round(mean(c["tool_calls"] for c in cells), 2),
            "avg_wall_seconds": round(mean(c["wall_seconds"] for c in cells), 2),
            "avg_tokens": round(mean(c["tokens"] for c in cells), 2),
        }
    return by_backend


def verify(snapshot: dict, recomputed: dict) -> list[str]:
    errors: list[str] = []
    claimed = snapshot["summary"]["by_backend"]
    for backend, claim in claimed.items():
        actual = recomputed.get(backend)
        if actual is None:
            errors.append(f"{backend}: claimed in summary but has no cells")
            continue
        for key in ("recall", "top_1"):
            if claim[key] != actual[key]:
                errors.append(f"{backend}.{key}: claimed {claim[key]} != actual {actual[key]}")
        for key in ("avg_tool_calls", "avg_wall_seconds", "avg_tokens"):
            if abs(float(claim[key]) - float(actual[key])) > 0.01:
                errors.append(f"{backend}.{key}: claimed {claim[key]} != actual {actual[key]}")
    return errors


def print_table(snapshot: dict, recomputed: dict) -> None:
    backends = snapshot["backends"]
    rows = [("backend", "recall", "top-1", "avg calls", "avg wall (s)", "avg tokens")]
    for backend in backends:
        s = recomputed[backend]
        rows.append((
            backend,
            s["recall"],
            s["top_1"],
            f"{s['avg_tool_calls']:.2f}",
            f"{s['avg_wall_seconds']:.2f}",
            f"{s['avg_tokens']:,.0f}",
        ))
    widths = [max(len(row[i]) for row in rows) for i in range(len(rows[0]))]
    sep = "  ".join("-" * w for w in widths)
    for i, row in enumerate(rows):
        print("  ".join(cell.ljust(widths[j]) for j, cell in enumerate(row)))
        if i == 0:
            print(sep)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", help="emit recomputed summary as JSON")
    parser.add_argument("--snapshot", type=Path, default=SNAPSHOT, help="path to results.json")
    args = parser.parse_args()

    snapshot = json.loads(args.snapshot.read_text())
    recomputed = recompute(snapshot)
    errors = verify(snapshot, recomputed)

    if args.json:
        print(json.dumps(recomputed, indent=2))
    else:
        print(f"source:     {snapshot['source']}")
        print(f"frozen at:  {snapshot['frozen_at']}")
        print(f"tasks:      {len(snapshot['tasks'])}  ({', '.join(t['id'] for t in snapshot['tasks'])})")
        print(f"backends:   {len(snapshot['backends'])}  ({', '.join(snapshot['backends'])})")
        print()
        print_table(snapshot, recomputed)
        print()
        print("headline:", snapshot["summary"]["headline"])

    if errors:
        print(file=sys.stderr)
        print("VERIFY FAILED — summary does not match cells:", file=sys.stderr)
        for err in errors:
            print(f"  - {err}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
