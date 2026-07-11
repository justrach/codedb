#!/usr/bin/env python3
"""Compare counterbalanced codedb benchmark samples with output parity gates."""
from __future__ import annotations

import argparse
import json
import random
import statistics
import sys
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("samples", help="directory containing base-NN.json and head-NN.json")
    parser.add_argument("--threshold-pct", type=float, default=10.0)
    parser.add_argument("--min-abs-ns", type=int, default=50_000)
    parser.add_argument("--require-parity", action="store_true")
    parser.add_argument("--markdown-out")
    parser.add_argument("--bootstrap-samples", type=int, default=20_000)
    return parser.parse_args()


def load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def paired_files(root: Path) -> list[tuple[Path, Path]]:
    bases = {p.stem.removeprefix("base-"): p for p in root.glob("base-*.json")}
    heads = {p.stem.removeprefix("head-"): p for p in root.glob("head-*.json")}
    if not bases or set(bases) != set(heads):
        raise ValueError(f"unpaired samples: base={sorted(bases)} head={sorted(heads)}")
    return [(bases[key], heads[key]) for key in sorted(bases)]


def percentile(values: list[float], q: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, int(q * len(ordered))))
    return ordered[index]


def bootstrap_median_ci(values: list[float], samples: int, seed: int = 0xC0DE) -> tuple[float, float]:
    if not values:
        return (0.0, 0.0)
    rng = random.Random(seed)
    medians = []
    for _ in range(samples):
        draw = [values[rng.randrange(len(values))] for _ in values]
        medians.append(float(statistics.median(draw)))
    return percentile(medians, 0.025), percentile(medians, 0.975)


def tool_map(data: dict) -> dict[str, dict]:
    return {tool["tool"]: tool for tool in data["tools"]}


def compare(samples: list[tuple[dict, dict]], threshold_pct: float, min_abs_ns: int, require_parity: bool, bootstrap_samples: int) -> tuple[str, list[str]]:
    failures: list[str] = []
    parity_failures: list[str] = []
    corpus_hashes: list[str] = []

    mapped: list[tuple[dict[str, dict], dict[str, dict]]] = []
    expected_tools: set[str] | None = None
    for pair_index, (base, head) in enumerate(samples, 1):
        base_hash = base.get("corpus_hash")
        head_hash = head.get("corpus_hash")
        if base_hash is None or head_hash is None:
            if require_parity:
                parity_failures.append(f"pair {pair_index}: benchmark schema lacks corpus_hash")
        elif base_hash != head_hash:
            parity_failures.append(f"pair {pair_index}: corpus hash differs ({base_hash} != {head_hash})")
        else:
            corpus_hashes.append(str(base_hash))

        base_tools = tool_map(base)
        head_tools = tool_map(head)
        if set(base_tools) != set(head_tools):
            parity_failures.append(
                f"pair {pair_index}: tool set differs (base-only={sorted(set(base_tools)-set(head_tools))}, head-only={sorted(set(head_tools)-set(base_tools))})"
            )
        common = set(base_tools) & set(head_tools)
        if expected_tools is None:
            expected_tools = common
        elif common != expected_tools:
            parity_failures.append(f"pair {pair_index}: common tool set changed across samples")
        mapped.append((base_tools, head_tools))

    if corpus_hashes and len(set(corpus_hashes)) != 1:
        parity_failures.append(f"corpus hash changed across pairs: {sorted(set(corpus_hashes))}")

    rows = []
    for tool in sorted(expected_tools or ()):
        base_ns = [int(base[tool]["avg_latency_ns"]) for base, _ in mapped]
        head_ns = [int(head[tool]["avg_latency_ns"]) for _, head in mapped]
        deltas = [h - b for b, h in zip(base_ns, head_ns)]
        delta_pcts = [((h - b) / b * 100.0) if b else 0.0 for b, h in zip(base_ns, head_ns)]
        base_median = int(statistics.median(base_ns))
        head_median = int(statistics.median(head_ns))
        delta_median = int(statistics.median(deltas))
        pct_median = float(statistics.median(delta_pcts))
        ci_low, ci_high = bootstrap_median_ci(delta_pcts, bootstrap_samples, seed=0xC0DE + len(rows))
        wins = sum(h < b for b, h in zip(base_ns, head_ns))
        ties = sum(h == b for b, h in zip(base_ns, head_ns))

        parity_enabled = all(bool(base[tool].get("parity", False)) and bool(head[tool].get("parity", False)) for base, head in mapped)
        parity_status = "SKIP"
        if parity_enabled:
            missing = any("response_hash" not in base[tool] or "response_hash" not in head[tool] for base, head in mapped)
            mismatches = [
                index
                for index, (base, head) in enumerate(mapped, 1)
                if base[tool].get("response_hash") != head[tool].get("response_hash")
            ]
            if missing:
                parity_status = "MISSING"
                if require_parity:
                    parity_failures.append(f"{tool}: response_hash missing")
            elif mismatches:
                parity_status = "FAIL"
                parity_failures.append(f"{tool}: output hash differs in pairs {mismatches}")
            else:
                parity_status = "PASS"
        elif require_parity and any(bool(base[tool].get("parity", False)) or bool(head[tool].get("parity", False)) for base, head in mapped):
            parity_failures.append(f"{tool}: parity policy differs between base and head")

        status = "OK"
        if pct_median > threshold_pct and delta_median > min_abs_ns:
            status = "FAIL"
            failures.append(f"{tool} median paired regression {pct_median:+.2f}% ({delta_median:+d} ns)")
        elif pct_median > threshold_pct:
            status = "NOISE"
        rows.append((tool, base_median, head_median, pct_median, delta_median, ci_low, ci_high, wins, ties, parity_status, status))

    if parity_failures:
        failures.extend(parity_failures)

    lines = [
        "## Paired Benchmark Report",
        "",
        f"Pairs: {len(samples)} (counterbalanced by the runner)",
        f"Regression gate: median paired delta > {threshold_pct:.2f}% and > {min_abs_ns:,} ns",
        f"Corpus parity: {'PASS' if not parity_failures and corpus_hashes else 'FAIL' if parity_failures else 'UNAVAILABLE'}",
        "",
        "No single-run minima are used. CI is a deterministic bootstrap 95% interval for the paired percentage median.",
        "",
        "| Tool | Base median | Head median | Paired delta | Abs delta | 95% CI | Head wins | Output parity | Status |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- |",
    ]
    for tool, base_median, head_median, pct_median, delta_median, ci_low, ci_high, wins, ties, parity_status, status in rows:
        lines.append(
            f"| `{tool}` | {base_median} | {head_median} | {pct_median:+.2f}% | {delta_median:+d} | [{ci_low:+.2f}%, {ci_high:+.2f}%] | {wins}/{len(samples)} ({ties} ties) | {parity_status} | {status} |"
        )
    if parity_failures:
        lines.extend(["", "### Parity failures", ""] + [f"- {failure}" for failure in parity_failures])
    return "\n".join(lines) + "\n", failures


def main() -> int:
    args = parse_args()
    try:
        files = paired_files(Path(args.samples))
        samples = [(load(base), load(head)) for base, head in files]
        report, failures = compare(samples, args.threshold_pct, args.min_abs_ns, args.require_parity, args.bootstrap_samples)
    except (OSError, ValueError, KeyError, json.JSONDecodeError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    sys.stdout.write(report)
    if args.markdown_out:
        Path(args.markdown_out).write_text(report, encoding="utf-8")
    for failure in failures:
        print(failure, file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
