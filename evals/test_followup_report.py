"""Guard against misleading timing and accuracy receipts."""
import copy
import json
from pathlib import Path
import tempfile
import unittest

from followup_report import checked_report, distribution, rank, timing_report


def fixture():
    retrieval = {'ann_cache_hit': True, 'ann_embed_ns': 90_000_000,
                 'ann_load_ns': 1000, 'ann_search_ns': 100_000,
                 'semantic': 'ann_applied', 'documents_sent': 2, 'ann_mmap_backed': True}
    sample = {'wall_ms': 100, 'retrieval': retrieval}
    return {'complete': True, 'failures': [], 'rows': [{'id': 'a', 'samples': [
        {arm: copy.deepcopy(sample) for arm in ('baseline', 'candidate')}]}]}


class ReceiptTests(unittest.TestCase):
    def test_cold_calls_are_excluded_and_remainder_is_per_sample(self):
        raw = fixture()
        cold = copy.deepcopy(raw['rows'][0]['samples'][0])
        for sample in cold.values():
            sample['retrieval']['ann_cache_hit'] = False
            sample['wall_ms'] = 2000
        raw['rows'][0]['samples'].append(cold)
        result = timing_report(raw)
        self.assertEqual(result['candidate']['wall_ms']['samples'], 1)
        self.assertEqual(result['candidate']['wall_minus_embed_ms']['median'], 10)
        self.assertEqual(result['candidate']['embed_share_percent']['median'], 90)

    def test_missing_instrumentation_is_not_zero(self):
        raw = fixture()
        del raw['rows'][0]['samples'][0]['candidate']['retrieval']['ann_embed_ns']
        with self.assertRaises(KeyError):
            timing_report(raw)

    def test_bad_run_and_changed_receipt_are_rejected(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / 'report.json'
            raw = fixture()
            path.write_text(json.dumps(raw))
            with self.assertRaisesRegex(ValueError, 'hash mismatch'):
                checked_report(path, '0' * 64)
            raw['rows'][0]['samples'][0]['candidate']['retrieval']['semantic'] = 'unavailable'
            path.write_text(json.dumps(raw))
            with self.assertRaisesRegex(ValueError, 'Fallback'):
                checked_report(path)
            raw['complete'] = False
            path.write_text(json.dumps(raw))
            with self.assertRaisesRegex(ValueError, 'Incomplete'):
                checked_report(path)

    def test_invalid_timings_and_nonpositive_gold(self):
        for values in ([], [-1], [float('nan')], [float('inf')]):
            with self.assertRaises(ValueError):
                distribution(values)
        self.assertEqual(distribution(list(range(1, 21)))['p95'], 19)
        self.assertEqual(rank(['wrong', 'correct'], {'wrong': 0, 'correct': 3}), 2)
        self.assertIsNone(rank(['wrong'], {'correct': 3}))


if __name__ == '__main__':
    unittest.main()
