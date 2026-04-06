#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Compare codedb benchmark JSON results.")
    parser.add_argument("base", help="baseline benchmark JSON")
    parser.add_argument("head", help="candidate benchmark JSON")
    parser.add_argument("--threshold-pct", type=float, default=10.0, help="maximum allowed latency regression percentage")
    parser.add_argument("--min-abs-ns", type=int, default=50000, help="ignore regressions below this absolute delta (ns)")
    parser.add_argument("--markdown-out", help="write markdown report to this path")
    return parser.parse_args()


def load_tools(path: str) -> dict[str, dict]:
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    return {tool["tool"]: tool for tool in data["tools"]}


def pct_change(base_ns: int, head_ns: int) -> float:
    if base_ns == 0:
        return 0.0
    return ((head_ns - base_ns) / base_ns) * 100.0


def render_markdown(rows: list[tuple[str, int, int, float]], threshold_pct: float) -> str:
    lines = [
        "## Benchmark Regression Report",
        "",
        f"Threshold: {threshold_pct:.2f}%",
        "",
        "| Tool | Base (ns) | Head (ns) | Delta | Status |",
        "| --- | ---: | ---: | ---: | --- |",
    ]
    for tool, base_ns, head_ns, delta in rows:
        status = "FAIL" if delta > threshold_pct else "OK"
        lines.append(f"| `{tool}` | {base_ns} | {head_ns} | {delta:+.2f}% | {status} |")
    return "\n".join(lines) + "\n"


def main() -> int:
    args = parse_args()
    base = load_tools(args.base)
    head = load_tools(args.head)

    # Only compare tools that exist in both base and head.
    # New tools in head (not in base) are skipped — not a regression.
    # Tools removed from head (in base but not head) are flagged.
    removed = sorted(set(base) - set(head))
    if removed:
        print(f"error: tools removed from head: {', '.join(removed)}", file=sys.stderr)
        return 1
    common = sorted(set(base) & set(head))

    rows: list[tuple[str, int, int, float]] = []
    failures: list[str] = []

    for tool in common:
        base_ns = int(base[tool]["avg_latency_ns"])
        head_ns = int(head[tool]["avg_latency_ns"])
        delta = pct_change(base_ns, head_ns)
        abs_delta = head_ns - base_ns
        rows.append((tool, base_ns, head_ns, delta))
        # Only flag as regression if BOTH percentage AND absolute delta exceed thresholds
        # This prevents false positives on fast tools where CI noise dominates
        if delta > args.threshold_pct and abs_delta > args.min_abs_ns:
            failures.append(f"{tool} regressed by {delta:.2f}%")

    report = render_markdown(rows, args.threshold_pct)
    sys.stdout.write(report)

    if args.markdown_out:
        Path(args.markdown_out).write_text(report, encoding="utf-8")

    if failures:
        for failure in failures:
            print(failure, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
