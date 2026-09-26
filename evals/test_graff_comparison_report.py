import unittest

from graff_comparison_report import aggregate, priced_usage


class AccountingTests(unittest.TestCase):
    def test_cached_input_is_not_double_counted(self):
        usage = priced_usage({"in": 10000, "cached": 6000, "out": 1000, "calls": 2, "cost_usd": 0})
        self.assertEqual(usage["total_tokens"], 11000)
        self.assertEqual(usage["uncached_input"], 4000)
        self.assertAlmostEqual(usage["api_equivalent_usd"], 0.017)
        self.assertEqual(usage["reported_model_charge_usd"], 0)

    def test_missing_footer_is_unknown(self):
        self.assertIsNone(priced_usage({}))

    def test_large_session_requires_per_request_pricing(self):
        usage = priced_usage({"in": 200000, "cached": 0, "out": 1000, "calls": 2, "cost_usd": 0})
        self.assertIsNone(usage["api_equivalent_usd"])

    def test_rejects_impossible_cache_count(self):
        with self.assertRaises(ValueError):
            priced_usage({"in": 5, "cached": 10, "out": 1, "calls": 2, "cost_usd": 0})

    def test_failed_attempt_cost_is_included_and_missing_is_not_zero(self):
        rows = []
        for arm in ("baseline", "codedb", "graphify"):
            for passed in (True, False):
                rows.append(dict(
                    arm=arm, passed=passed, wall_seconds=1, index_setup={"seconds": 1},
                    retrieval_calls=0, workspace_calls=1,
                    usage=priced_usage({"in": 10000, "cached": 6000, "out": 1000, "calls": 2, "cost_usd": 0}),
                ))
        totals = aggregate(rows)
        self.assertAlmostEqual(totals["codedb"]["api_equivalent_per_pass_usd"], 0.034)
        rows[0]["usage"] = None
        totals = aggregate(rows)
        self.assertFalse(totals["baseline"]["usage_complete"])
        self.assertIsNone(totals["baseline"]["total_tokens"])
        self.assertIsNone(totals["baseline"]["api_equivalent_usd"])


if __name__ == "__main__":
    unittest.main()
