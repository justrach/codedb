#!/usr/bin/env python3
"""Package or verify byte-exact, allowlisted captures from the frozen v3 study.

Only captured MCP/CLI/grader output and runner metadata are included. Session
configuration, auth stores, environment dumps and unrelated files are excluded.
The JSONL bodies retain original timestamps and local paths; they are not
redacted or rewritten. This does not reconstruct uncaptured provider traffic.
"""
import argparse
import gzip
import hashlib
import io
import json
from pathlib import Path
import re
import tarfile

from graff_comparison import relative_path

SECRET_PATTERNS = {
    "private key": rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----",
    "token prefix": rb"(?:gh[pousr]_[A-Za-z0-9]{25,}|github_pat_[A-Za-z0-9_]{25,}|xai-[A-Za-z0-9]{20,}|sk-[A-Za-z0-9_-]{25,})",
    "bearer credential": rb"(?i)authorization[\"\s:=]+bearer\s+[A-Za-z0-9._-]{10,}",
    "assigned credential": rb"(?i)(?:api_key|access_token|refresh_token|client_secret)[\"\s]*[:=][\"\s]+[A-Za-z0-9._-]{16,}",
}


def sha(data):
    return hashlib.sha256(data).hexdigest()


def check_bytes(name, data):
    for kind, pattern in SECRET_PATTERNS.items():
        if re.search(pattern, data):
            raise ValueError(f"Possible {kind} in {name}; review locally before publishing")


def build(source, output, suite_runner):
    manifest = json.loads((source / "manifest.json").read_text())
    freeze = json.loads((source / "freeze.json").read_text())
    receipt = json.loads((output / "results-v3.json").read_text())
    records = {r["attempt"]: r for r in receipt["records"]}
    if len(records) != 48 or len(manifest["tasks"]) != 16:
        raise ValueError("Expected the complete 48-attempt v3 study")
    for name in ("run.py", "manifest.json", "workspace_mcp.py", "proxy.py"):
        if sha((source / name).read_bytes()) != freeze[name]:
            raise ValueError(f"Frozen file changed: {name}")
    archive = output / "traces-v3.tar.gz"
    index = output / "traces-v3.json"
    if archive.exists() or index.exists():
        raise FileExistsError("Trace outputs already exist")
    members = {}

    def add(name, path, source_label):
        relative_path(name)
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"Missing regular input: {source_label}")
        data = path.read_bytes()
        check_bytes(name, data)
        if name in members:
            raise ValueError(f"Duplicate archive name: {name}")
        members[name] = (data, source_label)

    captured_count = 0
    for task in manifest["tasks"]:
        relative_path(task["id"])
        for arm in ("baseline", "codedb", "graphify"):
            attempt = task["id"] + "/" + arm
            area = source / attempt
            for name in ("result.json", "grader.log"):
                key = "result_sha256" if name == "result.json" else "grader_log_sha256"
                if sha((area / name).read_bytes()) != records[attempt][key]:
                    raise ValueError(f"Trace no longer matches published receipt: {attempt}/{name}")
            names = ["workspace.jsonl", "answer.txt", "progress.log", "grader.log", "process.json", "result.json"]
            if arm != "baseline":
                names += ["retrieval.jsonl", "setup.log"]
            for name in names:
                add("attempts/" + attempt + "/" + name, area / name, "study/" + attempt + "/" + name)
                captured_count += 1
    for name in ("manifest.json", "freeze.json", "validation.json", "json-stream-sensitivity.json", "batch.log"):
        add("metadata/" + name, source / name, "study/" + name)
    for name in ("run.py", "batch.py", "prepare.py", "validate.py", "workspace_mcp.py", "proxy.py"):
        add("runner/" + name, source / name, "study/" + name)
    add("runner/source-suite-runner.py", suite_runner, "prior-suite-snapshot/run.py")
    # Normalize archive headers for a deterministic container. File contents,
    # including JSONL timestamps and whitespace, remain byte-for-byte original.
    with archive.open("xb") as raw:
        with gzip.GzipFile(fileobj=raw, mode="wb", filename="", mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode="w") as tar:
                for name, (data, _) in sorted(members.items()):
                    info = tarfile.TarInfo(name)
                    info.size, info.mode, info.mtime = len(data), 0o644, 0
                    tar.addfile(info, io.BytesIO(data))
    inventory = {
        "schema_version": 1, "archive": archive.name, "archive_sha256": sha(archive.read_bytes()),
        "attempts": 48, "captured_attempt_files": captured_count,
        "total_files": len(members), "uncompressed_bytes": sum(len(v[0]) for v in members.values()),
        "content_policy": "Original file contents, with no redaction or reserialization. Archive filesystem headers normalized.",
        "scope": "Captured MCP JSON-RPC and stderr, Graff stdout/stderr, process/grader/setup records, original runner files and metadata.",
        "not_captured": "Raw provider HTTP traffic and a complete model-conversation transcript were not captured by this runner.",
        "excluded": ["Session .mcp.json and .harness configuration", "Authentication stores and environment dumps", "Unrelated project files"],
        "privacy": "Original local filesystem paths and timestamps retained. Credential pattern screening performed before packaging.",
        "runner_note": "Original runner files retain machine paths and are audit references. Use the portable fixture/regrade helper for local replay.",
        "license": "The original CodeGraff suite runner retains CODEGRAFF-LICENSE.txt, alongside this study bundle.",
        "files": [{"path": name, "sha256": sha(data), "size": len(data), "source": label}
                  for name, (data, label) in sorted(members.items())],
    }
    index.write_text(json.dumps(inventory, indent=2) + "\n")
    verify(index)
    return inventory


def verify(index_path):
    inventory = json.loads(index_path.read_text())
    if inventory["schema_version"] != 1:
        raise ValueError("Unknown trace manifest schema")
    archive_name = relative_path(inventory["archive"])
    archive = index_path.parent / archive_name
    if sha(archive.read_bytes()) != inventory["archive_sha256"]:
        raise ValueError("Trace archive hash mismatch")
    expected = {}
    for entry in inventory["files"]:
        relative_path(entry["path"])
        if entry["path"] in expected:
            raise ValueError("Duplicate manifest member")
        expected[entry["path"]] = entry
    seen = set()
    with tarfile.open(archive, "r:gz") as tar:
        for member in tar:
            relative_path(member.name)
            if not member.isfile() or member.name not in expected or member.name in seen:
                raise ValueError(f"Unexpected trace member: {member.name}")
            entry = expected[member.name]
            if member.size != entry["size"] or member.size > 16_000_000:
                raise ValueError(f"Invalid member size: {member.name}")
            data = tar.extractfile(member).read()
            if sha(data) != entry["sha256"]:
                raise ValueError(f"Trace member hash mismatch: {member.name}")
            check_bytes(member.name, data)
            seen.add(member.name)
    if seen != set(expected) or len(seen) != inventory["total_files"]:
        raise ValueError("Missing trace members")
    return len(seen)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("build")
    p.add_argument("source", type=Path)
    p.add_argument("output", type=Path)
    p.add_argument("--suite-runner", type=Path, required=True)
    p = sub.add_parser("verify")
    p.add_argument("manifest", type=Path)
    args = parser.parse_args()
    if args.command == "build":
        inventory = build(args.source, args.output, args.suite_runner)
        print(f"Packaged {inventory['total_files']} byte-exact files, including {inventory['captured_attempt_files']} attempt captures")
    else:
        print(f"Verified {verify(args.manifest)} byte-exact archive members")
