#!/usr/bin/env python3
"""Measure idle watcher CPU beyond the macOS vnode budget on a fixed corpus.

Build stable ReleaseFast binaries outside zig-out, then compare both orders:
  python3 scripts/bench_watcher_idle.py --binary /tmp/base/bin/codedb --binary /tmp/new/bin/codedb
  python3 scripts/bench_watcher_idle.py --binary /tmp/new/bin/codedb --binary /tmp/base/bin/codedb

This reports CPU consumption, not a machine-dependent CI timing assertion.
The deterministic fallback-read regression lives in the test-watcher target.
"""
from __future__ import annotations

import argparse
import json
import os
import platform
import statistics
import subprocess
import tempfile
import time
from pathlib import Path

from e2e_mcp_test import MCPProcess, do_initialize, wait_for_scan


def cpu_seconds(pid: int) -> float:
    value = subprocess.check_output(
        ["ps", "-p", str(pid), "-o", "time="], text=True, timeout=10
    ).strip()
    # ps reports [[days-]hours:]minutes:seconds.fraction.
    days, sep, value_tail = value.partition("-")
    total = float(days) * 86400 if sep else 0.0
    for power, part in enumerate(reversed((value_tail if sep else value).split(":"))):
        total += float(part) * 60**power
    return total


def measure(binary: str, root: Path, seconds: float) -> dict:
    env = {
        **os.environ,
        "CODEDB_NO_AUTO_UPDATE": "1",
        "CODEDB_NO_TELEMETRY": "1",
        "CODEDB_NO_CLI_DAEMON": "1",
        "CODEDB_QUIET": "1",
    }
    p = MCPProcess(
        binary, [], cwd=str(root), env=env,
        command=[binary, str(root), "mcp", f"--config-file={root / '.codedbrc'}", "--no-telemetry"],
    )
    try:
        if not do_initialize(p, with_roots=False) or not wait_for_scan(p, timeout=90):
            raise RuntimeError("MCP did not become ready")
        # Ready precedes watcher arming and its startup reconciliation.
        time.sleep(3)
        samples = []
        for _ in range(3):
            before = cpu_seconds(p.proc.pid)
            start = time.monotonic()
            time.sleep(seconds)
            samples.append(100 * (cpu_seconds(p.proc.pid) - before) / (time.monotonic() - start))
        return {"binary": binary, "cpu_percent": samples, "median_cpu_percent": statistics.median(samples)}
    finally:
        p.close()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", action="append", required=True)
    parser.add_argument("--seconds", type=float, default=6)
    args = parser.parse_args()
    if args.seconds <= 0:
        parser.error("--seconds must be positive")
    if platform.system() != "Darwin":
        raise SystemExit("This benchmark targets the macOS vnode-budget fallback.")
    with tempfile.TemporaryDirectory(prefix="codedb-idle-bench-") as temp:
        root = Path(temp).resolve()
        subprocess.run(["git", "init", "-q", str(root)], check=True)
        (root / ".codedbrc").write_text("max_watched = 32\n")
        (root / ".gitignore").write_text("".join(f"ignored_{i}/\n" for i in range(50)))
        for i in range(512):
            folder = root / "src" / f"d{i % 16}"
            folder.mkdir(parents=True, exist_ok=True)
            (folder / f"f{i}.py").write_text(
                f"def value_{i}():\n    return {i}\n" + "# filler data for watcher measurement\n" * 1800
            )
        for binary in args.binary:
            print(json.dumps(measure(str(Path(binary).resolve()), root, args.seconds)), flush=True)


if __name__ == "__main__":
    main()
