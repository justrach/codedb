#!/usr/bin/env python3
"""Materialize and grade the frozen Graff comparison fixtures (Python 3.10+).

This runs fixture code locally; it is a grader, not a security sandbox. Keep the
bundle and this script outside the agent's workspace because they contain gold
checks. The recorded study used Python 3.14.3 for both visible and hidden tests.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import signal
import subprocess
import sys
import tempfile

BUNDLE = Path(__file__).parent / "graff-comparison/fixtures-v3.json"


def digest(data):
    return hashlib.sha256(data).hexdigest()


def relative_path(value):
    path = PurePosixPath(value)
    if not value or not path.parts or path.is_absolute() or ".." in path.parts or str(path) != value or "\\" in value:
        raise ValueError(f"Invalid fixture path: {value!r}")
    return path


def load_bundle(path=BUNDLE):
    bundle = json.loads(Path(path).read_text())
    if bundle["schema_version"] != 1:
        raise ValueError("Unsupported bundle schema")
    ids = set()
    for task in bundle["tasks"]:
        if task["id"] in ids:
            raise ValueError("Duplicate task ID")
        ids.add(task["id"])
        for name, item in task["files"].items():
            relative_path(name)
            if digest(item["text"].encode()) != item["sha256"]:
                raise ValueError(f"Fixture hash mismatch: {task['id']}/{name}")
        hidden = task["hidden_test"]
        if digest(hidden["text"].encode()) != hidden["sha256"]:
            raise ValueError(f"Hidden grader hash mismatch: {task['id']}")
        if not set(task["editable"]) <= task["files"].keys():
            raise ValueError("Editable file is missing from fixture")
        if task["visible_test"] not in task["files"] or task["visible_test"] in task["editable"]:
            raise ValueError("Visible test must be present and immutable")
    return bundle


def materialize(task, root):
    root = Path(root)
    root.mkdir(parents=True, exist_ok=False)
    for name, item in task["files"].items():
        target = root / relative_path(name)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(item["text"].encode())


def replay(bundle, solutions_path, attempt, root, bundle_path=BUNDLE):
    saved = json.loads(Path(solutions_path).read_text())
    if saved["schema_version"] != 1 or saved["fixture_bundle_sha256"] != digest(Path(bundle_path).read_bytes()):
        raise ValueError("Solutions do not match the fixture bundle")
    solution = next((s for s in saved["solutions"] if s["attempt"] == attempt), None)
    if solution is None:
        raise ValueError(f"Unknown saved attempt: {attempt}")
    task = next(t for t in bundle["tasks"] if t["id"] == solution["task"])
    if set(solution["files"]) != set(task["editable"]):
        raise ValueError("Solution must contain exactly the editable files")
    for item in solution["files"].values():
        if digest(item["text"].encode()) != item["sha256"]:
            raise ValueError("Solution hash mismatch")
    materialize(task, root)
    for name, item in solution["files"].items():
        (Path(root) / name).write_bytes(item["text"].encode())
    return task


def immutable_changes(task, root):
    changed = []
    for name, item in task["files"].items():
        path = root / name
        # Every source file must remain a regular file inside the fixture.
        if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(root):
            changed.append(name)
        elif name not in task["editable"] and digest(path.read_bytes()) != item["sha256"]:
            changed.append(name)
    return changed


def execute_test(path, root, timeout):
    proc = subprocess.Popen(
        [sys.executable, str(path)], cwd=root, start_new_session=True,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        env={"PATH": "/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE": "1"},
    )
    try:
        output, _ = proc.communicate(timeout=timeout)
        return {"exit_code": proc.returncode, "timed_out": False, "output": output}
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGKILL)
        output, _ = proc.communicate()
        return {"exit_code": 124, "timed_out": True, "output": output}


def grade(task, root, timeout=45):
    root = Path(root).resolve(strict=True)
    changed = immutable_changes(task, root)
    if changed:
        return {"passed": False, "immutable_changes": changed, "visible": None, "hidden": None}
    visible = execute_test(root / task["visible_test"], root, timeout)
    hidden = None
    if visible["exit_code"] == 0:
        # This directory is outside the supplied agent root and exists only
        # after the agent has finished. Hidden checks are never materialized.
        with tempfile.TemporaryDirectory(prefix="graff-grader-") as temp:
            path = Path(temp) / "hidden_check.py"
            path.write_bytes(task["hidden_test"]["text"].encode())
            hidden = execute_test(path, root, timeout)
    changed = immutable_changes(task, root)
    return {
        "passed": bool(hidden and hidden["exit_code"] == 0 and not changed),
        "immutable_changes": changed, "visible": visible, "hidden": hidden,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path, default=BUNDLE)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("list")
    sub.add_parser("verify")
    for command in ("materialize", "grade"):
        p = sub.add_parser(command)
        p.add_argument("task")
        p.add_argument("root", type=Path)
    p = sub.add_parser("replay", help="Restore a saved repair for independent grading")
    p.add_argument("attempt", help="For example json-stream-r2/graphify")
    p.add_argument("root", type=Path)
    p.add_argument("--solutions", type=Path, default=BUNDLE.parent / "study-v3/solutions-v3.json")
    args = parser.parse_args()
    bundle = load_bundle(args.bundle)
    if args.command == "list":
        print("\n".join(t["id"] for t in bundle["tasks"]))
        return 0
    if args.command == "verify":
        print(json.dumps({"tasks": len(bundle["tasks"]), "bundle_sha256": digest(args.bundle.read_bytes())}))
        return 0
    if args.command == "replay":
        task = replay(bundle, args.solutions, args.attempt, args.root, args.bundle)
        print(f"Restored {args.attempt}; grade with: grade {task['id']} {args.root}")
        return 0
    task = next((t for t in bundle["tasks"] if t["id"] == args.task), None)
    if task is None:
        parser.error(f"Unknown task: {args.task}")
    if args.command == "materialize":
        materialize(task, args.root)
        print(task["prompt"])
        return 0
    result = grade(task, args.root)
    print(json.dumps(result, indent=2))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
