#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import shutil
import subprocess
import sys


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run `zig build bench -- --json` and persist the JSON payload.")
    parser.add_argument("--bench-side", choices=("base", "head"))
    parser.add_argument("--bench-pair", type=int)
    parser.add_argument("--bench-order", choices=("AB", "BA"))
    parser.add_argument("--bench-sequence", type=int, choices=(1, 2))
    parser.add_argument("--production-source-sha")
    parser.add_argument("--corpus-source-sha")
    parser.add_argument("output", help="output JSON file")
    parser.add_argument("bench_args", nargs=argparse.REMAINDER, help="arguments forwarded to the benchmark after --json")
    return parser.parse_args()


def extract_json(stdout: str, stderr: str) -> str:
    text = stdout.strip()
    if text.startswith("{") and text.endswith("}"):
        return text + "\n"

    for stream in (stdout, stderr):
        for line in reversed(stream.splitlines()):
            line = line.strip()
            if line.startswith("{") and line.endswith("}"):
                return line + "\n"
    raise RuntimeError("benchmark command did not emit JSON")


def command_output(*command: str) -> str:
    return subprocess.run(command, check=True, capture_output=True, text=True).stdout.strip()


def file_sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def bench_arg_value(args: argparse.Namespace, name: str) -> str | None:
    try:
        index = args.bench_args.index(name)
    except ValueError:
        return None
    if index + 1 >= len(args.bench_args):
        raise ValueError(f"{name} requires a value")
    return args.bench_args[index + 1]


def git_is_clean(path: pathlib.Path) -> bool:
    status = command_output("git", "-C", str(path), "status", "--porcelain", "--untracked-files=all")
    return status == ""


def benchmark_provenance(args: argparse.Namespace) -> dict | None:
    fields = (
        args.bench_side,
        args.bench_pair,
        args.bench_order,
        args.bench_sequence,
        args.production_source_sha,
        args.corpus_source_sha,
    )
    if not any(value is not None for value in fields):
        return None
    if any(value is None for value in fields):
        raise ValueError("paired benchmark provenance arguments must be provided together")
    source_root = pathlib.Path.cwd().resolve()
    corpus_arg = bench_arg_value(args, "--corpus-source")
    if corpus_arg is None:
        raise ValueError("paired benchmark provenance requires --corpus-source")
    corpus_root = pathlib.Path(corpus_arg).resolve()
    source_sha = command_output("git", "-C", str(source_root), "rev-parse", "HEAD")
    corpus_source_sha = command_output("git", "-C", str(corpus_root), "rev-parse", "HEAD")
    if corpus_source_sha != args.corpus_source_sha:
        raise ValueError(
            f"corpus source HEAD {corpus_source_sha} does not match claimed {args.corpus_source_sha}"
        )
    zig_command = shutil.which("zig")
    if zig_command is None:
        raise ValueError("zig executable not found on PATH")
    zig_path = pathlib.Path(zig_command).resolve()
    return {
        "side": args.bench_side,
        "pair": args.bench_pair,
        "order": args.bench_order,
        "sequence": args.bench_sequence,
        "source_sha": source_sha,
        "source_tree_sha": command_output("git", "-C", str(source_root), "rev-parse", "HEAD^{tree}"),
        "source_dirty": not git_is_clean(source_root),
        "production_source_sha": args.production_source_sha,
        "corpus_source_sha": corpus_source_sha,
        "corpus_source_tree_sha": command_output("git", "-C", str(corpus_root), "rev-parse", "HEAD^{tree}"),
        "corpus_source_dirty": not git_is_clean(corpus_root),
        "compiler_version": command_output(str(zig_path), "version"),
        "compiler_sha256": file_sha256(zig_path),
        "build_mode": "ReleaseFast",
    }


def semantic_safety_commands(build_graph: str, bench_side: str | None) -> tuple[tuple[str, ...], ...]:
    """Return head-only safety roots supported by the checked-out build graph."""
    if bench_side == "base" or 'name = "test-semantic-index"' not in build_graph:
        return ()
    return (
        ("zig", "build", "test-semantic-index"),
        ("zig", "build", "test-explore", "-Dtest-filter=file symlink aliases"),
    )


def main() -> int:
    args = parse_args()
    # The PR benchmark is the hosted Linux lane available to release branches.
    # Run the named safety roots whenever the checked-out source graph exposes
    # the semantic-index step. The unpaired historical-base invocation does
    # not pass --bench-side, so source capability (not a missing flag) must be
    # the compatibility gate; old release bases intentionally keep their own
    # graph unchanged.
    build_graph = pathlib.Path("build.zig").read_text(encoding="utf-8")
    for command in semantic_safety_commands(build_graph, args.bench_side):
        safety = subprocess.run(command, capture_output=True, text=True, check=False)
        if safety.stdout:
            sys.stderr.write(safety.stdout)
        if safety.stderr:
            sys.stderr.write(safety.stderr)
        if safety.returncode != 0:
            sys.stderr.write(f"\n[run-bench-json] {' '.join(command)} exited {safety.returncode}\n")
            return safety.returncode
    proc = subprocess.run(
        ["zig", "build", "bench", "--", "--json", *args.bench_args],
        capture_output=True,
        text=True,
        check=False,
    )
    # Always surface stderr so CI logs show compile errors even on success.
    if proc.stderr:
        sys.stderr.write(proc.stderr)
    if proc.returncode != 0:
        sys.stderr.write(f"\n[run-bench-json] zig build bench exited {proc.returncode}\n")
        if proc.stdout:
            sys.stderr.write("---- stdout ----\n")
            sys.stderr.write(proc.stdout)
        return proc.returncode
    payload = json.loads(extract_json(proc.stdout, proc.stderr))
    provenance = benchmark_provenance(args)
    if provenance is not None:
        payload["benchmark_provenance"] = provenance
    pathlib.Path(args.output).write_text(json.dumps(payload, separators=(",", ":")) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
