#!/usr/bin/env python3
"""Black-box regression gate for #709's macOS descriptor-per-file slope."""

from __future__ import annotations

import argparse
import os
import platform
import subprocess
import tempfile
import time
from pathlib import Path

from e2e_mcp_test import MCPProcess, do_initialize, wait_for_scan


def descriptor_count(pid: int) -> int:
    proc_fd = Path(f"/proc/{pid}/fd")
    if proc_fd.is_dir():
        return len(list(proc_fd.iterdir()))
    output = subprocess.check_output(
        ["lsof", "-a", "-p", str(pid), "-Fn"], text=True, timeout=10
    )
    return sum(1 for line in output.splitlines() if line.startswith("n"))


def measure(binary: str, file_count: int, budget: int) -> int:
    with tempfile.TemporaryDirectory(prefix=f"codedb-fd-{file_count}-") as tmp:
        root = Path(tmp).resolve()
        subprocess.run(["git", "init", "-q", str(root)], check=True)
        (root / "pyproject.toml").write_text(
            f"[project]\nname='fd-fixture-{file_count}'\nversion='0'\n"
        )
        (root / ".codedbrc").write_text(f"max_watched = {budget}\n")
        for i in range(file_count):
            directory = root / "src" / f"bucket-{i % 64:02d}"
            directory.mkdir(parents=True, exist_ok=True)
            (directory / f"file-{i:05d}.py").write_text(
                f"def value_{i}():\n    return {i}\n"
            )

        env = {
            **os.environ,
            "CODEDB_NO_AUTO_UPDATE": "1",
            "CODEDB_NO_CLI_DAEMON": "1",
            "CODEDB_NO_TELEMETRY": "1",
            "CODEDB_QUIET": "1",
        }
        p = MCPProcess(
            binary,
            [],
            cwd=str(root),
            env=env,
            command=[
                binary,
                str(root),
                "mcp",
                f"--config-file={root / '.codedbrc'}",
                "--no-telemetry",
            ],
        )
        try:
            if not do_initialize(p, with_roots=False):
                raise RuntimeError("initialize failed")
            if not wait_for_scan(p, timeout=90):
                raise RuntimeError("index did not become ready")
            # `scan: ready` is published just before the watcher completes its
            # first arm/reconcile pass. Sample only after that bounded handoff,
            # otherwise a tiny fixture can look artificially lower than the
            # large fixture and create a false positive slope.
            time.sleep(1.0)
            return descriptor_count(p.proc.pid)
        finally:
            p.close()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", default="zig-out/bin/codedb")
    parser.add_argument("--budget", type=int, default=32)
    parser.add_argument("--small", type=int, default=128)
    parser.add_argument("--large", type=int, default=2048)
    args = parser.parse_args()
    binary = str(Path(args.binary).resolve())
    if platform.system() != "Darwin":
        print("SKIP: #709 is a macOS kqueue descriptor regression")
        return 0

    small = measure(binary, args.small, args.budget)
    large = measure(binary, args.large, args.budget)
    fixed_overhead_allowance = 48
    slope_allowance = 8
    print(
        f"macOS descriptors: small({args.small})={small}, "
        f"large({args.large})={large}, budget={args.budget}"
    )
    if large > args.budget + fixed_overhead_allowance:
        raise SystemExit(
            f"FAIL: {large} descriptors exceeds budget + fixed overhead "
            f"({args.budget + fixed_overhead_allowance})"
        )
    if large - small > slope_allowance:
        raise SystemExit(
            f"FAIL: descriptor count still scales with corpus (+{large - small})"
        )
    print("PASS: descriptor acquisition is bounded and corpus-size independent")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
