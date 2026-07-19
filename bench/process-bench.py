#!/usr/bin/env python3
"""Measure process-wall latency and output for a fixed command."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import resource
import statistics
import subprocess
import time


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    position = (len(ordered) - 1) * fraction
    lower = int(position)
    upper = min(lower + 1, len(ordered) - 1)
    weight = position - lower
    return ordered[lower] * (1.0 - weight) + ordered[upper] * weight


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cwd", required=True)
    parser.add_argument("--warmups", type=int, default=1)
    parser.add_argument("--iterations", type=int, default=10)
    parser.add_argument("--include-output", action="store_true")
    parser.add_argument("--env", action="append", default=[])
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()

    if args.command[:1] == ["--"]:
        args.command = args.command[1:]
    if not args.command:
        parser.error("command is required after --")
    if args.warmups < 0 or args.iterations < 1:
        parser.error("warmups must be non-negative and iterations must be positive")

    environment = os.environ.copy()
    for item in args.env:
        key, separator, value = item.partition("=")
        if not separator or not key:
            parser.error(f"invalid --env value: {item!r}")
        environment[key] = value

    measured: list[dict[str, object]] = []
    last_stdout = b""
    last_stderr = b""
    total_runs = args.warmups + args.iterations
    for run_index in range(total_runs):
        started = time.perf_counter_ns()
        completed = subprocess.run(
            args.command,
            cwd=args.cwd,
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        elapsed_ms = (time.perf_counter_ns() - started) / 1_000_000.0
        last_stdout = completed.stdout
        last_stderr = completed.stderr
        if completed.returncode != 0:
            print(
                json.dumps(
                    {
                        "command": args.command,
                        "run": run_index,
                        "returncode": completed.returncode,
                        "wall_ms": elapsed_ms,
                        "stdout": completed.stdout.decode("utf-8", errors="replace"),
                        "stderr": completed.stderr.decode("utf-8", errors="replace"),
                    },
                    separators=(",", ":"),
                )
            )
            return completed.returncode
        if run_index >= args.warmups:
            measured.append(
                {
                    "wall_ms": elapsed_ms,
                    "stdout_bytes": len(completed.stdout),
                    "stderr_bytes": len(completed.stderr),
                    "stdout_sha256": hashlib.sha256(completed.stdout).hexdigest(),
                }
            )

    walls = [float(run["wall_ms"]) for run in measured]
    stdout_sizes = [int(run["stdout_bytes"]) for run in measured]
    usage = resource.getrusage(resource.RUSAGE_CHILDREN)
    result: dict[str, object] = {
        "command": args.command,
        "cwd": args.cwd,
        "warmups": args.warmups,
        "iterations": args.iterations,
        "wall_ms": {
            "min": min(walls),
            "p50": statistics.median(walls),
            "p95": percentile(walls, 0.95),
            "max": max(walls),
        },
        "stdout_bytes": {
            "min": min(stdout_sizes),
            "p50": statistics.median(stdout_sizes),
            "max": max(stdout_sizes),
        },
        "peak_child_rss_kib": usage.ru_maxrss,
        "runs": measured,
    }
    if args.include_output:
        result["last_stdout"] = last_stdout.decode("utf-8", errors="replace")
        result["last_stderr"] = last_stderr.decode("utf-8", errors="replace")
    print(json.dumps(result, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
