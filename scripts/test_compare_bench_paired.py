#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).with_name("compare-bench-paired.py")
SPEC = importlib.util.spec_from_file_location("compare_bench_paired", MODULE_PATH)
assert SPEC and SPEC.loader
paired = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(paired)


def payload(latency: int, response_hash: int = 7, corpus_hash: int = 11, parity: bool = True) -> dict:
    return {
        "corpus_hash": corpus_hash,
        "tools": [
            {
                "tool": "codedb_tree",
                "avg_latency_ns": latency,
                "response_hash": response_hash,
                "parity": parity,
            }
        ],
    }


def add_provenance(data: dict, side: str, pair: int, order: str, sequence: int) -> dict:
    source_sha = (
        "24e89c70d4f9cdaf5542a78d83d1890a42b4a046" if side == "base" else "c" * 40
    )
    source_tree_sha = (
        "e0012e49b5819b8ac800831d7e0dce6a84bca1a1" if side == "base" else "e" * 40
    )
    production_sha = (
        "dd36e9431925014ee2bed80346669a4afee7e42e" if side == "base" else source_sha
    )
    data["benchmark_provenance"] = {
        "side": side,
        "pair": pair,
        "order": order,
        "sequence": sequence,
        "source_sha": source_sha,
        "source_tree_sha": source_tree_sha,
        "source_dirty": False,
        "production_source_sha": production_sha,
        "corpus_source_sha": "dd36e9431925014ee2bed80346669a4afee7e42e",
        "corpus_source_tree_sha": "e705e2623b28d2456eb9d4934817b79f4de35216",
        "corpus_source_dirty": False,
        "compiler_version": "0.17.0-test",
        "compiler_sha256": "d" * 64,
        "build_mode": "ReleaseFast",
    }
    return data


class PairedComparisonTests(unittest.TestCase):
    def test_uses_paired_median_not_single_minimum(self) -> None:
        samples = [
            (payload(100), payload(10)),
            (payload(100), payload(120)),
            (payload(100), payload(130)),
        ]
        report, failures = paired.compare(samples, threshold_pct=10, min_abs_ns=0, require_parity=True, bootstrap_samples=500)
        self.assertIn("+20.00%", report)
        self.assertIn("1/3", report)
        self.assertTrue(any("median paired regression" in failure for failure in failures))

    def test_output_hash_mismatch_is_a_failure(self) -> None:
        report, failures = paired.compare(
            [(payload(100, response_hash=1), payload(90, response_hash=2))],
            threshold_pct=10,
            min_abs_ns=0,
            require_parity=True,
            bootstrap_samples=100,
        )
        self.assertIn("Output parity", report)
        self.assertIn("FAIL", report)
        self.assertTrue(any("output hash differs" in failure for failure in failures))

    def test_corpus_mismatch_is_a_failure(self) -> None:
        _, failures = paired.compare(
            [(payload(100, corpus_hash=1), payload(90, corpus_hash=2))],
            threshold_pct=10,
            min_abs_ns=0,
            require_parity=True,
            bootstrap_samples=100,
        )
        self.assertTrue(any("corpus hash differs" in failure for failure in failures))

    def test_parity_opt_out_is_explicit(self) -> None:
        report, failures = paired.compare(
            [(payload(100, response_hash=1, parity=False), payload(90, response_hash=2, parity=False))],
            threshold_pct=10,
            min_abs_ns=0,
            require_parity=True,
            bootstrap_samples=100,
            allowed_parity_skips={"codedb_tree"},
        )
        self.assertIn("SKIP", report)
        self.assertEqual([], failures)

    def test_unallowlisted_parity_opt_out_fails(self) -> None:
        _, failures = paired.compare(
            [(payload(100, parity=False), payload(90, parity=False))],
            threshold_pct=10,
            min_abs_ns=0,
            require_parity=True,
            bootstrap_samples=100,
        )
        self.assertTrue(any("without an explicit comparator allowlist" in failure for failure in failures))

    def test_legacy_schema_is_reported_but_allowed_without_requirement(self) -> None:
        legacy = {"tools": [{"tool": "codedb_tree", "avg_latency_ns": 100}]}
        report, failures = paired.compare(
            [(legacy, legacy)],
            threshold_pct=10,
            min_abs_ns=0,
            require_parity=False,
            bootstrap_samples=100,
        )
        self.assertIn("Corpus parity: UNAVAILABLE", report)
        self.assertEqual([], failures)

    def test_corpus_change_across_pairs_is_a_failure(self) -> None:
        _, failures = paired.compare(
            [
                (payload(100, corpus_hash=1), payload(90, corpus_hash=1)),
                (payload(100, corpus_hash=2), payload(90, corpus_hash=2)),
            ],
            threshold_pct=10,
            min_abs_ns=0,
            require_parity=True,
            bootstrap_samples=100,
        )
        self.assertTrue(any("corpus hash changed across pairs" in failure for failure in failures))

    def test_counterbalance_provenance_is_verified(self) -> None:
        samples = [
            (
                add_provenance(payload(100), "base", 1, "AB", 1),
                add_provenance(payload(90), "head", 1, "AB", 2),
            ),
            (
                add_provenance(payload(100), "base", 2, "BA", 2),
                add_provenance(payload(90), "head", 2, "BA", 1),
            ),
        ]
        report, failures = paired.compare(
            samples,
            threshold_pct=10,
            min_abs_ns=0,
            require_parity=True,
            bootstrap_samples=100,
            require_provenance=True,
        )
        self.assertIn("Provenance: PASS", report)
        self.assertEqual([], failures)

    def test_incorrect_counterbalance_provenance_fails(self) -> None:
        samples = [
            (
                add_provenance(payload(100), "base", 1, "BA", 1),
                add_provenance(payload(90), "head", 1, "BA", 2),
            )
        ]
        _, failures = paired.compare(
            samples,
            threshold_pct=10,
            min_abs_ns=0,
            require_parity=True,
            bootstrap_samples=100,
            require_provenance=True,
        )
        self.assertTrue(any("order='BA', expected 'AB'" in failure for failure in failures))

    def test_unpaired_sample_files_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "base-01.json").write_text("{}", encoding="utf-8")
            with self.assertRaises(ValueError):
                paired.paired_files(root)


if __name__ == "__main__":
    unittest.main()
