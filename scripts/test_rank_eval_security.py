"""Regression test: eval cases and paths remain data, never shell programs."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("rank_eval", Path(__file__).with_name("rank-eval.py"))
rank_eval = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rank_eval)


class RankEvalSecurity(unittest.TestCase):
    def test_literal_query_and_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            corpus = root / "corpus with spaces; $(touch injected)"
            corpus.mkdir()
            binary = root / "fake tool; literal"
            binary.write_text('''#!/usr/bin/env python3
import json, sys
from pathlib import Path
if sys.argv[1:] == [".", "index"]:
    Path("prewarmed").write_text("ok")
    sys.exit(0)
init = json.loads(sys.stdin.readline())
request = json.loads(sys.stdin.readline())
Path("received.json").write_text(json.dumps(request))
print(json.dumps({"id":1,"result":{"content":[{"text":"src/control.zig:1: safe"}]}}))
''')
            binary.chmod(0o700)
            rank_eval.prewarm(str(binary), corpus, dict(os.environ))
            self.assertEqual((corpus / "prewarmed").read_text(), "ok")
            for query in ['ordinary_symbol', '" \\ $(touch injected) `touch injected`\nnew line']:
                with patch.object(rank_eval.time, "sleep"):
                    rank_eval.search(str(binary), corpus, dict(os.environ), query)
                request = json.loads((corpus / "received.json").read_text())
                self.assertEqual(request["params"]["arguments"]["query"], query)
                self.assertFalse((corpus / "injected").exists())
                self.assertFalse((root / "injected").exists())


if __name__ == "__main__":
    unittest.main()
