#!/usr/bin/env python3
"""Compare counterbalanced codedb benchmark samples with output parity gates."""
from __future__ import annotations

import argparse
import json
import random
import re
import statistics
import sys
from pathlib import Path


PINNED_BASELINE_HARNESSES = {
    "24e89c70d4f9cdaf5542a78d83d1890a42b4a046": "dd36e9431925014ee2bed80346669a4afee7e42e",
}
PINNED_COMMIT_TREES = {
    "24e89c70d4f9cdaf5542a78d83d1890a42b4a046": "e0012e49b5819b8ac800831d7e0dce6a84bca1a1",
    "dd36e9431925014ee2bed80346669a4afee7e42e": "e705e2623b28d2456eb9d4934817b79f4de35216",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("samples", help="directory containing base-NN.json and head-NN.json")
    parser.add_argument("--threshold-pct", type=float, default=10.0)
    parser.add_argument("--min-abs-ns", type=int, default=50_000)
    parser.add_argument("--require-parity", action="store_true")
    parser.add_argument("--require-provenance", action="store_true")
    parser.add_argument("--allow-parity-skip", action="append", default=[], metavar="TOOL")
    parser.add_argument("--allow-regression", action="append", default=[], metavar="TOOL")
    parser.add_argument("--expected-head-sha")
    parser.add_argument("--expected-head-tree-sha")
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
    tools = data["tools"]
    mapped = {tool["tool"]: tool for tool in tools}
    if len(mapped) != len(tools):
        raise ValueError("duplicate tool records in benchmark sample")
    return mapped


def validate_provenance(
    samples: list[tuple[dict, dict]],
    expected_head_sha: str | None = None,
    expected_head_tree_sha: str | None = None,
) -> tuple[list[str], str | None]:
    failures: list[str] = []
    base_sources: set[str] = set()
    head_sources: set[str] = set()
    base_production_sources: set[str] = set()
    base_source_trees: set[str] = set()
    head_source_trees: set[str] = set()
    compilers: set[str] = set()
    compiler_hashes: set[str] = set()
    corpus_sources: set[str] = set()
    corpus_trees: set[str] = set()
    sha_pattern = re.compile(r"^[0-9a-f]{40}$")

    for pair_index, (base, head) in enumerate(samples, 1):
        expected_order = "AB" if pair_index % 2 == 1 else "BA"
        expected_sequences = {"base": 1 if expected_order == "AB" else 2, "head": 2 if expected_order == "AB" else 1}
        for side, data in (("base", base), ("head", head)):
            meta = data.get("benchmark_provenance")
            if not isinstance(meta, dict):
                failures.append(f"pair {pair_index} {side}: benchmark_provenance missing")
                continue
            expected = {
                "side": side,
                "pair": pair_index,
                "order": expected_order,
                "sequence": expected_sequences[side],
                "build_mode": "ReleaseFast",
            }
            for field, value in expected.items():
                if meta.get(field) != value:
                    failures.append(f"pair {pair_index} {side}: {field}={meta.get(field)!r}, expected {value!r}")
            if meta.get("source_dirty") is not False:
                failures.append(f"pair {pair_index} {side}: source tree was dirty")
            if meta.get("corpus_source_dirty") is not False:
                failures.append(f"pair {pair_index} {side}: corpus source tree was dirty")
            for field in ("source_sha", "source_tree_sha", "production_source_sha", "corpus_source_sha", "corpus_source_tree_sha"):
                value = meta.get(field)
                if not isinstance(value, str) or not sha_pattern.fullmatch(value):
                    failures.append(f"pair {pair_index} {side}: invalid {field}")
            compiler = meta.get("compiler_version")
            if not isinstance(compiler, str) or not compiler:
                failures.append(f"pair {pair_index} {side}: compiler_version missing")
            else:
                compilers.add(compiler)
            compiler_hash = meta.get("compiler_sha256")
            if not isinstance(compiler_hash, str) or not re.fullmatch(r"[0-9a-f]{64}", compiler_hash):
                failures.append(f"pair {pair_index} {side}: invalid compiler_sha256")
            else:
                compiler_hashes.add(compiler_hash)
            source_sha = meta.get("source_sha")
            production_sha = meta.get("production_source_sha")
            corpus_sha = meta.get("corpus_source_sha")
            source_tree = meta.get("source_tree_sha")
            corpus_tree = meta.get("corpus_source_tree_sha")
            if isinstance(corpus_sha, str):
                corpus_sources.add(corpus_sha)
            if isinstance(corpus_tree, str):
                corpus_trees.add(corpus_tree)
            if source_sha in PINNED_COMMIT_TREES and source_tree != PINNED_COMMIT_TREES[source_sha]:
                failures.append(f"pair {pair_index} {side}: source tree does not match pinned commit")
            if corpus_sha in PINNED_COMMIT_TREES and corpus_tree != PINNED_COMMIT_TREES[corpus_sha]:
                failures.append(f"pair {pair_index} {side}: corpus tree does not match pinned commit")
            if side == "base":
                if isinstance(source_sha, str):
                    base_sources.add(source_sha)
                if isinstance(source_tree, str):
                    base_source_trees.add(source_tree)
                if isinstance(production_sha, str):
                    base_production_sources.add(production_sha)
                expected_production = PINNED_BASELINE_HARNESSES.get(source_sha, source_sha)
                if production_sha != expected_production:
                    failures.append(f"pair {pair_index} base: unrecognized production/harness source mapping")
            else:
                if isinstance(source_sha, str):
                    head_sources.add(source_sha)
                if isinstance(source_tree, str):
                    head_source_trees.add(source_tree)
                if source_sha != production_sha:
                    failures.append(f"pair {pair_index} head: production_source_sha differs from built source_sha")

    for label, values in (
        ("base harness source", base_sources),
        ("base production source", base_production_sources),
        ("base source tree", base_source_trees),
        ("head source", head_sources),
        ("head source tree", head_source_trees),
        ("compiler version", compilers),
        ("compiler executable hash", compiler_hashes),
        ("corpus source", corpus_sources),
        ("corpus source tree", corpus_trees),
    ):
        if len(values) != 1:
            failures.append(f"{label} changed across samples: {sorted(values)}")
    if len(base_production_sources) == 1 and corpus_sources != base_production_sources:
        failures.append("corpus source does not match the production baseline source")
    if (expected_head_sha is None) != (expected_head_tree_sha is None):
        failures.append("expected head SHA and tree SHA must be provided together")
    if expected_head_sha is not None:
        if not sha_pattern.fullmatch(expected_head_sha) or not sha_pattern.fullmatch(expected_head_tree_sha or ""):
            failures.append("expected head SHA/tree is invalid")
        if head_sources != {expected_head_sha}:
            failures.append(f"head source does not match expected {expected_head_sha}")
        if head_source_trees != {expected_head_tree_sha}:
            failures.append(f"head source tree does not match expected {expected_head_tree_sha}")

    if failures:
        return failures, None
    summary = (
        f"base={next(iter(base_production_sources))[:12]} "
        f"harness={next(iter(base_sources))[:12]} "
        f"head={next(iter(head_sources))[:12]} "
        f"compiler={next(iter(compilers))}/{next(iter(compiler_hashes))[:12]}"
    )
    return [], summary


def compare(
    samples: list[tuple[dict, dict]],
    threshold_pct: float,
    min_abs_ns: int,
    require_parity: bool,
    bootstrap_samples: int,
    require_provenance: bool = False,
    allowed_parity_skips: set[str] | None = None,
    allowed_regressions: set[str] | None = None,
    expected_head_sha: str | None = None,
    expected_head_tree_sha: str | None = None,
) -> tuple[str, list[str]]:
    failures: list[str] = []
    parity_failures: list[str] = []
    corpus_hashes: list[str] = []
    allowed_parity_skips = allowed_parity_skips or set()
    allowed_regressions = allowed_regressions or set()
    provenance_failures, provenance_summary = (
        validate_provenance(samples, expected_head_sha, expected_head_tree_sha)
        if require_provenance
        else ([], None)
    )

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

        parity_policies = {
            (bool(base[tool].get("parity", False)), bool(head[tool].get("parity", False)))
            for base, head in mapped
        }
        parity_enabled = parity_policies == {(True, True)}
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
        elif require_parity:
            if parity_policies != {(False, False)}:
                parity_failures.append(f"{tool}: parity policy differs between revisions or samples")
            elif tool not in allowed_parity_skips:
                parity_failures.append(f"{tool}: parity disabled without an explicit comparator allowlist entry")

        status = "OK"
        if pct_median > threshold_pct and delta_median > min_abs_ns:
            if tool in allowed_regressions:
                status = "WAIVED"
            else:
                status = "FAIL"
                failures.append(f"{tool} median paired regression {pct_median:+.2f}% ({delta_median:+d} ns)")
        elif pct_median > threshold_pct:
            status = "NOISE"
        rows.append((tool, base_median, head_median, pct_median, delta_median, ci_low, ci_high, wins, ties, parity_status, status))

    actual_parity_skips = {row[0] for row in rows if row[9] == "SKIP"}
    if require_parity:
        for tool in sorted(allowed_parity_skips - actual_parity_skips):
            parity_failures.append(f"{tool}: parity skip allowlist entry was not used")
    if parity_failures:
        failures.extend(parity_failures)
    if provenance_failures:
        failures.extend(provenance_failures)

    counterbalance = "verified" if require_provenance and not provenance_failures else "not provenance-verified"
    lines = [
        "## Paired Benchmark Report",
        "",
        f"Pairs: {len(samples)} (counterbalance {counterbalance})",
        f"Regression gate: median paired delta > {threshold_pct:.2f}% and > {min_abs_ns:,} ns",
        f"Corpus parity: {'PASS' if corpus_hashes and not any('corpus' in failure for failure in parity_failures) else 'FAIL' if parity_failures else 'UNAVAILABLE'}",
        f"Provenance: {'PASS (' + provenance_summary + ')' if provenance_summary else 'FAIL' if require_provenance else 'NOT REQUIRED'}",
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
    if provenance_failures:
        lines.extend(["", "### Provenance failures", ""] + [f"- {failure}" for failure in provenance_failures])
    return "\n".join(lines) + "\n", failures


def main() -> int:
    args = parse_args()
    try:
        files = paired_files(Path(args.samples))
        samples = [(load(base), load(head)) for base, head in files]
        report, failures = compare(
            samples,
            args.threshold_pct,
            args.min_abs_ns,
            args.require_parity,
            args.bootstrap_samples,
            require_provenance=args.require_provenance,
            allowed_parity_skips=set(args.allow_parity_skip),
            allowed_regressions=set(args.allow_regression),
            expected_head_sha=args.expected_head_sha,
            expected_head_tree_sha=args.expected_head_tree_sha,
        )
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
