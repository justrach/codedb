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
            expected_head_sha="c" * 40,
            expected_head_tree_sha="e" * 40,
        )
        self.assertIn("Provenance: PASS", report)
        self.assertEqual([], failures)

    def test_v5846_version_neutral_baseline_harness_is_pinned(self) -> None:
        base = add_provenance(payload(100), "base", 1, "AB", 1)
        head = add_provenance(payload(90), "head", 1, "AB", 2)
        meta = base["benchmark_provenance"]
        meta["source_sha"] = "f5657e30f2e5bad759b5de20b591e2f67436e1b9"
        meta["source_tree_sha"] = "6834d4dd512d9af34d1dab8e92815ea98dd1e00a"
        meta["production_source_sha"] = "3db4242b9b39a857bdb4657d39bb623c76501fe9"
        meta["corpus_source_sha"] = "3db4242b9b39a857bdb4657d39bb623c76501fe9"
        meta["corpus_source_tree_sha"] = "f5a3c3a705f514833a0b1c61f41dc7f7ad6a0c5f"
        head_meta = head["benchmark_provenance"]
        head_meta["corpus_source_sha"] = "3db4242b9b39a857bdb4657d39bb623c76501fe9"
        head_meta["corpus_source_tree_sha"] = "f5a3c3a705f514833a0b1c61f41dc7f7ad6a0c5f"

        _, failures = paired.compare(
            [(base, head)],
            threshold_pct=10,
            min_abs_ns=0,
            require_parity=True,
            bootstrap_samples=100,
            require_provenance=True,
            expected_head_sha="c" * 40,
            expected_head_tree_sha="e" * 40,
        )
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

    def test_expected_head_identity_mismatch_fails(self) -> None:
        samples = [
            (
                add_provenance(payload(100), "base", 1, "AB", 1),
                add_provenance(payload(90), "head", 1, "AB", 2),
            )
        ]
        _, failures = paired.compare(
            samples,
            threshold_pct=10,
            min_abs_ns=0,
            require_parity=True,
            bootstrap_samples=100,
            require_provenance=True,
            expected_head_sha="f" * 40,
            expected_head_tree_sha="e" * 40,
        )
        self.assertTrue(any("head source does not match expected" in failure for failure in failures))

    def test_duplicate_tool_records_are_rejected(self) -> None:
        duplicate = payload(100)
        duplicate["tools"].append(dict(duplicate["tools"][0]))
        with self.assertRaisesRegex(ValueError, "duplicate tool records"):
            paired.compare(
                [(duplicate, payload(90))],
                threshold_pct=10,
                min_abs_ns=0,
                require_parity=True,
                bootstrap_samples=100,
            )

    def test_unpaired_sample_files_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "base-01.json").write_text("{}", encoding="utf-8")
            with self.assertRaises(ValueError):
                paired.paired_files(root)


if __name__ == "__main__":
    unittest.main()
