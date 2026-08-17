#!/usr/bin/env python3
"""Case-verdict and cost helpers for the pinned Graff tournament evaluator."""

from __future__ import annotations

from pathlib import Path
import subprocess
from typing import Any


def check_case(case: dict[str, Any], text: str, cwd: Path) -> bool:
    check = case.get("check")
    if not isinstance(check, dict):
        raise ValueError("case check must be an object")
    if isinstance(check.get("exact"), str):
        return text.strip() == check["exact"]
    if isinstance(check.get("substring"), str):
        return check["substring"] in text
    if isinstance(check.get("cmd"), str):
        completed = subprocess.run(
            ["sh", "-c", check["cmd"]], cwd=cwd,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10, check=False,
        )
        return completed.returncode == 0
    raise ValueError("case has no supported check")


def reported_cost_micros(event: dict[str, Any]) -> int:
    try:
        return max(0, round(float(event.get("cost_usd", 0.0) or 0.0) * 1_000_000))
    except (TypeError, ValueError, OverflowError):
        return 0
