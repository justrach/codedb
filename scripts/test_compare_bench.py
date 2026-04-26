#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
from pathlib import Path
import unittest


SCRIPT = Path(__file__).with_name("compare-bench.py")
spec = importlib.util.spec_from_file_location("compare_bench", SCRIPT)
assert spec is not None
compare_bench = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(compare_bench)


class CompareBenchTests(unittest.TestCase):
    def test_small_absolute_regression_is_noise(self) -> None:
        self.assertEqual(compare_bench.status_for(22.54, 11_399, 10.0, 50_000), "NOISE")

    def test_large_absolute_regression_fails(self) -> None:
        self.assertEqual(compare_bench.status_for(12.0, 75_000, 10.0, 50_000), "FAIL")

    def test_report_explains_noise_status(self) -> None:
        report = compare_bench.render_markdown(
            [("codedb_read", 50_580, 61_979, 22.54, 11_399)],
            10.0,
            50_000,
        )
        self.assertIn("50,000 ns absolute delta", report)
        self.assertIn("| `codedb_read` | 50580 | 61979 | +22.54% | +11399 | NOISE |", report)


if __name__ == "__main__":
    unittest.main()
