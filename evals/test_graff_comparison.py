import copy
import json
from pathlib import Path
import tempfile
import unittest

from graff_comparison import BUNDLE, digest, grade, load_bundle, materialize, relative_path, replay


class FixtureTests(unittest.TestCase):
    def test_rejects_unsafe_paths(self):
        for value in ("../outside", "/tmp/outside", "a/../b", "a//b", "a\\b", "", "."):
            with self.subTest(value=value), self.assertRaises(ValueError):
                relative_path(value)

    def test_detects_bundle_tampering(self):
        bundle = copy.deepcopy(load_bundle())
        bundle["tasks"][0]["hidden_test"]["text"] += "\n# changed\n"
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "bundle.json"
            path.write_text(json.dumps(bundle))
            with self.assertRaisesRegex(ValueError, "hash mismatch"):
                load_bundle(path)

    def test_no_hidden_checks_or_overwrite(self):
        task = load_bundle()["tasks"][0]
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "fixture"
            materialize(task, root)
            self.assertEqual(set(p.name for p in root.iterdir()), set(task["files"]))
            with self.assertRaises(FileExistsError):
                materialize(task, root)

    def test_immutable_test_change_rejected_before_execution(self):
        task = load_bundle()["tasks"][0]
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "fixture"
            materialize(task, root)
            (root / task["visible_test"]).write_text("raise RuntimeError('must not run')")
            result = grade(task, root)
            self.assertFalse(result["passed"])
            self.assertIsNone(result["visible"])
            self.assertEqual(result["immutable_changes"], [task["visible_test"]])

    def test_all_original_bugs_fail(self):
        with tempfile.TemporaryDirectory() as temp:
            for task in load_bundle()["tasks"]:
                with self.subTest(task=task["id"]):
                    root = Path(temp) / task["id"]
                    materialize(task, root)
                    result = grade(task, root)
                    self.assertFalse(result["passed"])
                    self.assertNotEqual(result["visible"]["exit_code"], 0)
                    self.assertFalse(result["immutable_changes"])

    def test_replay_cannot_replace_tests(self):
        bundle = load_bundle()
        task = bundle["tasks"][0]
        saved = {
            "schema_version": 1, "fixture_bundle_sha256": digest(BUNDLE.read_bytes()),
            "solutions": [{"attempt": "example", "task": task["id"], "files": task["files"]}],
        }
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "solutions.json"
            path.write_text(json.dumps(saved))
            root = Path(temp) / "must-not-be-created"
            with self.assertRaisesRegex(ValueError, "exactly the editable files"):
                replay(bundle, path, "example", root)
            self.assertFalse(root.exists())


if __name__ == "__main__":
    unittest.main()
