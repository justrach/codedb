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
    parser.add_argument("--allow-regression", action="append", default=[], metavar="TOOL", help="waive an intended latency regression for this tool")
    return parser.parse_args()


def load_payload(path: str) -> dict:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def tool_map(data: dict) -> dict[str, dict]:
    return {tool["tool"]: tool for tool in data["tools"]}


def corpus_gate(base: dict, head: dict) -> tuple[bool, str | None]:
    """Gate latency only when both samples measured identical source bytes.

    The hosted workflow also runs the authoritative counterbalanced benchmark
    against a frozen base corpus. These one-shot samples remain useful as a
    whole-tree diagnostic, but comparing their latency is invalid when a PR
    adds or changes files in the benchmark corpus.
    """
    base_hash = base.get("corpus_hash")
    head_hash = head.get("corpus_hash")
    if base_hash is not None and head_hash is not None and base_hash != head_hash:
        return False, f"corpus hash differs ({base_hash} != {head_hash})"
    return True, None


def pct_change(base_ns: int, head_ns: int) -> float:
    if base_ns == 0:
        return 0.0
    return ((head_ns - base_ns) / base_ns) * 100.0


def status_for(delta_pct: float, abs_delta_ns: int, threshold_pct: float, min_abs_ns: int, waived: bool = False) -> str:
    if delta_pct <= threshold_pct:
        return "OK"
    if abs_delta_ns <= min_abs_ns:
        return "NOISE"
    return "WAIVED" if waived else "FAIL"


def render_markdown(
    rows: list[tuple[str, int, int, float, int]],
    threshold_pct: float,
    min_abs_ns: int,
    allowed_regressions: set[str] | None = None,
    *,
    gated: bool = True,
    diagnostic_reason: str | None = None,
) -> str:
    lines = [
        "## Benchmark Regression Report",
        "",
        f"Thresholds: {threshold_pct:.2f}% and {min_abs_ns:,} ns absolute delta",
        "",
    ]
    if gated:
        lines.append("`NOISE` means the percentage threshold was exceeded, but the absolute delta was too small to fail CI.")
    else:
        lines.extend(
            [
                f"Corpus parity: **MISMATCH** — {diagnostic_reason}.",
                "",
                "Latency deltas are diagnostic only; the frozen-corpus paired benchmark is the regression gate.",
            ]
        )
    lines.extend([
        "",
        "| Tool | Base (ns) | Head (ns) | Delta | Abs Delta (ns) | Status |",
        "| --- | ---: | ---: | ---: | ---: | --- |",
    ])
    for tool, base_ns, head_ns, delta, abs_delta in rows:
        status = (
            status_for(delta, abs_delta, threshold_pct, min_abs_ns, waived=tool in (allowed_regressions or set()))
            if gated
            else "DIAGNOSTIC"
        )
        lines.append(f"| `{tool}` | {base_ns} | {head_ns} | {delta:+.2f}% | {abs_delta:+d} | {status} |")
    return "\n".join(lines) + "\n"


def main() -> int:
    args = parse_args()
    base_payload = load_payload(args.base)
    head_payload = load_payload(args.head)
    base = tool_map(base_payload)
    head = tool_map(head_payload)
    gated, diagnostic_reason = corpus_gate(base_payload, head_payload)

    # Only compare tools that exist in both base and head.
    # New tools in head (not in base) are skipped — not a regression.
    # Tools removed from head (in base but not head) are flagged.
    removed = sorted(set(base) - set(head))
    if removed:
        print(f"error: tools removed from head: {', '.join(removed)}", file=sys.stderr)
        return 1
    common = sorted(set(base) & set(head))

    rows: list[tuple[str, int, int, float, int]] = []
    failures: list[str] = []

    for tool in common:
        base_ns = int(base[tool]["avg_latency_ns"])
        head_ns = int(head[tool]["avg_latency_ns"])
        delta = pct_change(base_ns, head_ns)
        abs_delta = head_ns - base_ns
        rows.append((tool, base_ns, head_ns, delta, abs_delta))
        # Only flag as regression if BOTH percentage AND absolute delta exceed thresholds
        # This prevents false positives on fast tools where CI noise dominates
        if gated and delta > args.threshold_pct and abs_delta > args.min_abs_ns and tool not in args.allow_regression:
            failures.append(f"{tool} regressed by {delta:.2f}% ({abs_delta:+d} ns)")

    report = render_markdown(
        rows,
        args.threshold_pct,
        args.min_abs_ns,
        set(args.allow_regression),
        gated=gated,
        diagnostic_reason=diagnostic_reason,
    )
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
