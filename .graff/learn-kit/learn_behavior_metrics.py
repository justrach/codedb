#!/usr/bin/env python3
"""Recompute trusted tournament metrics from a completed behavioral stream."""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys


def audited_behavior_metrics(workspace: Path, observed_tool_calls: int) -> dict[str, int | bool]:
    """Return bounded metrics recomputed from one closed behavioral stream."""
    scorer = os.environ.get("GRAFF_LEARN_INPUT_3")
    if not scorer:
        return {"measured": False, "tool_calls": observed_tool_calls, "score_ppm": 0}
    traces = sorted((workspace / ".graff" / "behavior").glob("*.jsonl"))
    if len(traces) != 1:
        raise RuntimeError("expected exactly one behavioral stream")
    completed = subprocess.run(
        [sys.executable, scorer, str(traces[0])],
        text=True,
        capture_output=True,
        timeout=15,
        check=False,
    )
    if completed.returncode != 0:
        raise RuntimeError("behavioral stream failed its recomputable audit")
    try:
        report = json.loads(completed.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError("behavioral scorer returned invalid JSON") from exc
    if not isinstance(report, dict) or report.get("ok") is not True:
        raise RuntimeError("behavioral scorer did not attest the stream")
    if report.get("complete") is not True or report.get("terminal_status") != "closed":
        raise RuntimeError("behavioral stream did not close cleanly")
    tool_calls = report.get("tool_calls")
    if not isinstance(tool_calls, int) or tool_calls < 0:
        raise RuntimeError("behavioral scorer omitted tool_calls")
    if tool_calls != observed_tool_calls:
        raise RuntimeError("protocol and behavioral tool counts disagree")
    tool_errors = report.get("tool_errors")
    if not isinstance(tool_errors, int) or not 0 <= tool_errors <= tool_calls:
        raise RuntimeError("behavioral scorer returned invalid tool_errors")
    score_ppm = 1_000_000 if tool_calls == 0 else round(
        (tool_calls - tool_errors) * 1_000_000 / tool_calls
    )
    return {"measured": True, "tool_calls": tool_calls, "score_ppm": score_ppm}


def audited_tool_calls(workspace: Path, observed_tool_calls: int) -> int:
    """Backward-compatible exact-count adapter."""
    return int(audited_behavior_metrics(workspace, observed_tool_calls)["tool_calls"])
