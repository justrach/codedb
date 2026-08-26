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


if __name__ == "__main__":
    unittest.main()
