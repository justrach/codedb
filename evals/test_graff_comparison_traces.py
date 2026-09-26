import json
from pathlib import Path
import tarfile
import tempfile
import unittest

from graff_comparison_traces import sha, verify
from graff_comparison_report import priced_usage

STUDY = Path(__file__).parent / "graff-comparison/study-v3"


class TraceTests(unittest.TestCase):
    def test_exact_capture_hashes_and_receipt_agree(self):
        self.assertEqual(verify(STUDY / "traces-v3.json"), 364)
        receipt = json.loads((STUDY / "results-v3.json").read_text())
        solutions = {s["attempt"]: s for s in json.loads((STUDY / "solutions-v3.json").read_text())["solutions"]}
        fixtures = {t["id"]: t for t in json.loads((STUDY.parent / "fixtures-v3.json").read_text())["tasks"]}
        with tarfile.open(STUDY / "traces-v3.tar.gz") as tar:
            for row in receipt["records"]:
                for name, key in (("result.json", "result_sha256"), ("grader.log", "grader_log_sha256")):
                    data = tar.extractfile("attempts/" + row["attempt"] + "/" + name).read()
                    self.assertEqual(sha(data), row[key], row["attempt"])
                captured = json.loads(tar.extractfile("attempts/" + row["attempt"] + "/result.json").read())
                self.assertEqual(priced_usage(captured["usage"]), row["usage"])
                writes = {c["arguments"]["path"]: c["arguments"]["content"]
                          for c in captured["calls"]["workspace"] if c["name"] == "write_file"}
                for name, item in solutions[row["attempt"]]["files"].items():
                    text = writes.get(name, fixtures[row["family"]]["files"][name]["text"])
                    self.assertEqual(sha(text.encode()), item["sha256"], (row["attempt"], name))

    def test_corrupted_archive_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "traces-v3.json").write_bytes((STUDY / "traces-v3.json").read_bytes())
            data = (STUDY / "traces-v3.tar.gz").read_bytes()
            (root / "traces-v3.tar.gz").write_bytes(data[:-1] + bytes([data[-1] ^ 1]))
            with self.assertRaisesRegex(ValueError, "archive hash mismatch"):
                verify(root / "traces-v3.json")


if __name__ == "__main__":
    unittest.main()
