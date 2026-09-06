#!/usr/bin/env python3
"""Compare CPU consumed by MCP watchers under fixed ignored-file activity.

Pass stable ReleaseFast binaries with repeated --binary flags, then repeat in
reverse order. Each measured process loads an existing snapshot. An edit after
measurement must become visible through MCP. No timing threshold is used in CI.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import tempfile
import time
from pathlib import Path

from e2e_mcp_test import MCPProcess, do_initialize, tool_text, wait_for_scan


def cpu_seconds(pid: int) -> float:
    raw = subprocess.check_output(["ps", "-p", str(pid), "-o", "time="], text=True, timeout=10).strip()
    days, separator, tail = raw.partition("-")
    return (float(days) * 86400 if separator else 0) + sum(
        float(part) * 60**power for power, part in enumerate(reversed((tail if separator else raw).split(":")))
    )


def measure(binary: str, root: Path, cycles: int, warmup: bool = False) -> dict | None:
    (root / "probe.py").write_text("def probe_before():\n    return 1\n")
    env = {**os.environ, "CODEDB_NO_AUTO_UPDATE": "1", "CODEDB_NO_TELEMETRY": "1", "CODEDB_NO_CLI_DAEMON": "1"}
    p = MCPProcess(binary, [], cwd=str(root), env=env, command=[
        binary, str(root), "mcp", f"--config-file={root / '.codedbrc'}", "--no-telemetry",
    ])
    try:
        if not do_initialize(p, with_roots=False) or not wait_for_scan(p, timeout=90):
            raise RuntimeError("MCP did not become ready")
        time.sleep(3)
        if warmup:
            return None
        before = cpu_seconds(p.proc.pid)
        started = time.monotonic()
        noise = root / "activity-noise.tmp"
        for _ in range(cycles):
            noise.write_text("ignored filesystem activity\n")
            time.sleep(0.125)
            noise.unlink()
            time.sleep(0.125)
        time.sleep(1)  # let the last event finish
        used_cpu = cpu_seconds(p.proc.pid) - before
        elapsed = time.monotonic() - started
        rss_kib = int(subprocess.check_output(["ps", "-p", str(p.proc.pid), "-o", "rss="], text=True, timeout=10))
        changed_at = time.monotonic()
        (root / "probe.py").write_text("def probe_after():\n    return 2\n")
        while time.monotonic() - changed_at < 6:
            text = tool_text(p.call_tool("codedb_symbol", {"name": "probe_after"}))
            if "probe.py" in text and "probe_after" in text:
                break
            time.sleep(0.05)
        else:
            raise AssertionError("Live edit did not become visible")
        return {"binary": binary, "cycles": cycles, "cpu_seconds": used_cpu, "elapsed_seconds": elapsed,
                "cpu_percent": 100 * used_cpu / elapsed, "rss_kib": rss_kib,
                "visible_edit_ms": 1000 * (time.monotonic() - changed_at)}
    finally:
        p.close()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", action="append", required=True)
    parser.add_argument("--cycles", type=int, default=40)
    args = parser.parse_args()
    if args.cycles < 1:
        parser.error("--cycles must be positive")
    binaries = [str(Path(binary).resolve()) for binary in args.binary]
    with tempfile.TemporaryDirectory(prefix="codedb-activity-bench-") as temp:
        root = Path(temp).resolve()
        subprocess.run(["git", "init", "-q", str(root)], check=True)
        (root / ".codedbrc").write_text("max_watched = 256\n")
        (root / ".codedbignore").write_text("activity-noise.tmp\n")
        for i in range(512):
            directory = root / "src" / f"d{i % 64}"
            directory.mkdir(parents=True, exist_ok=True)
            (directory / f"f{i}.py").write_text(f"def value_{i}():\n    return 1\n")
        measure(binaries[0], root, args.cycles, warmup=True)
        for binary in binaries:
            print(json.dumps(measure(binary, root, args.cycles)), flush=True)


if __name__ == "__main__":
    main()
