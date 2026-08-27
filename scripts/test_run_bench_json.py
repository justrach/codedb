#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import pathlib
import unittest


SCRIPT = pathlib.Path(__file__).with_name("run-bench-json.py")
SPEC = importlib.util.spec_from_file_location("run_bench_json", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)

COMPARE_SCRIPT = pathlib.Path(__file__).with_name("compare-bench.py")
COMPARE_SPEC = importlib.util.spec_from_file_location("compare_bench", COMPARE_SCRIPT)
assert COMPARE_SPEC is not None and COMPARE_SPEC.loader is not None
COMPARE_MODULE = importlib.util.module_from_spec(COMPARE_SPEC)
COMPARE_SPEC.loader.exec_module(COMPARE_MODULE)


class SemanticSafetyCommandsTests(unittest.TestCase):
    def test_unpaired_historical_base_without_step_skips_new_safety_root(self) -> None:
        self.assertEqual((), MODULE.semantic_safety_commands("const old_graph = true;", None))

    def test_unpaired_head_with_step_runs_both_safety_roots(self) -> None:
        commands = MODULE.semantic_safety_commands('.name = "test-semantic-index",', None)
        self.assertEqual("test-semantic-index", commands[0][-1])
        self.assertEqual("test-explore", commands[1][2])

    def test_explicit_base_skips_even_when_head_script_is_used(self) -> None:
        graph = '.name = "test-semantic-index",'
        self.assertEqual((), MODULE.semantic_safety_commands(graph, "base"))


class WholeTreeComparatorTests(unittest.TestCase):
    def test_mismatched_corpus_is_diagnostic_not_a_latency_gate(self) -> None:
        gated, reason = COMPARE_MODULE.corpus_gate({"corpus_hash": 1}, {"corpus_hash": 2})
        self.assertFalse(gated)
        report = COMPARE_MODULE.render_markdown(
            [("codedb_context", 300_000, 500_000, 66.67, 200_000)],
            10.0,
            50_000,
            gated=gated,
            diagnostic_reason=reason,
        )
        self.assertIn("Corpus parity: **MISMATCH**", report)
        self.assertIn("| DIAGNOSTIC |", report)


if __name__ == "__main__":
    unittest.main()
