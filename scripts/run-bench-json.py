#!/usr/bin/env python3
from __future__ import annotations

import argparse
import pathlib
import subprocess
import sys


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run `zig build bench -- --json` and persist the JSON payload.")
    parser.add_argument("output", help="output JSON file")
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


def main() -> int:
    args = parse_args()
    proc = subprocess.run(
        ["zig", "build", "bench", "--", "--json"],
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
    payload = extract_json(proc.stdout, proc.stderr)
    pathlib.Path(args.output).write_text(payload, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
