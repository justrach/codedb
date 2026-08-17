#!/usr/bin/env python3
"""Write one pinned primary suite and one freshly randomized holdout suite.

`graff learn init` materializes this next to learn_graff_suites.py and runs it
once, so a workspace gets independent suites without a repository checkout.
"""

from __future__ import annotations

import json
from pathlib import Path
import secrets
import sys

from learn_graff_suites import (
    fresh_holdout,
    primary_cases,
    statistical_unit_count,
    validate_case_catalog,
)


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, separators=(",", ":")) + "\n", encoding="utf-8")
    path.chmod(0o600)


def main() -> None:
    if len(sys.argv) != 3:
        print("usage: learn_generate_suites.py PRIMARY HOLDOUT", file=sys.stderr)
        raise SystemExit(2)
    primary_path, holdout_path = Path(sys.argv[1]), Path(sys.argv[2])
    public_cases, hidden_cases = primary_cases(), fresh_holdout()
    validate_case_catalog(public_cases, 60)
    validate_case_catalog(hidden_cases, 40)
    primary_units = statistical_unit_count(public_cases)
    holdout_units = statistical_unit_count(hidden_cases)
    if primary_units < 40 or holdout_units < 40:
        raise SystemExit("primary and holdout each require 40 independent statistical units")
    write_json(primary_path, {
        "schema": "codegraff.learn.suite.v1",
        "suite_id": "graff-primary-v7",
        "cases": public_cases,
    })
    # A per-workspace random suite_id keeps the holdout distinct from the
    # primary suite and from every other workspace's holdout.
    write_json(holdout_path, {
        "schema": "codegraff.learn.suite.v1",
        "suite_id": "fresh-" + secrets.token_hex(8),
        "cases": hidden_cases,
    })
    print(json.dumps({
        "primary_cases": len(public_cases),
        "holdout_cases": len(hidden_cases),
        "primary_units": primary_units,
        "holdout_units": holdout_units,
    }))


if __name__ == "__main__":
    main()
