#!/usr/bin/env python3
"""Flatten bootstrap rows into (k, v, label) pairs for the student.

label 3 = gold definition, 0 = BM25 near-miss (teacher may overwrite).
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path


def flatten(row: dict) -> list[dict]:
    q = row["query"]
    pos = row["positive"]
    out = [{
        "k": q,
        "v": pos["text"],
        "label": 3,
        "path": pos["path"],
        "line": pos.get("line"),
        "kind": "gold",
        "id": row["id"],
        "suite": row["suite"],
    }]
    for n in row.get("negatives", []):
        out.append({
            "k": q,
            "v": n["text"],
            "label": 0,
            "path": n["path"],
            "rank": n.get("rank"),
            "kind": n.get("kind", "bm25-near-miss"),
            "id": row["id"],
            "suite": row["suite"],
        })
    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--pairs", type=Path, default=Path(__file__).with_name("pairs.jsonl"))
    ap.add_argument("--out", type=Path, default=Path(__file__).with_name("kv.jsonl"))
    args = ap.parse_args()
    rows = []
    for line in args.pairs.read_text().splitlines():
        if line.strip():
            rows.extend(flatten(json.loads(line)))
    args.out.write_text("".join(json.dumps(r) + "\n" for r in rows))
    gold = sum(1 for r in rows if r["label"] == 3)
    print(f"wrote {args.out} kv={len(rows)} gold={gold} negs={len(rows) - gold}")


if __name__ == "__main__":
    main()
