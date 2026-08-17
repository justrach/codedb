#!/usr/bin/env python3
"""Optional: run graff cases in parallel and attach opened-file negatives.

Reuses experiments/openclaw-graff/run.py::run_case. Expensive (luna).
Default is off — bootstrap_pairs.py is the cheap path.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RUN_PY = ROOT / "experiments" / "openclaw-graff" / "run.py"


def load_run():
    spec = importlib.util.spec_from_file_location("graff_run", RUN_PY)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--pairs", type=Path, default=Path(__file__).with_name("pairs.jsonl"))
    ap.add_argument("--out", type=Path, default=Path(__file__).with_name("pairs.graff.jsonl"))
    ap.add_argument("--workers", type=int, default=4)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    rows = [json.loads(l) for l in args.pairs.read_text().splitlines() if l.strip()]
    if args.dry_run:
        print(f"would run graff on {len(rows)} cases workers={args.workers}")
        return
    run = load_run()
    def job(row: dict) -> dict:
        os.environ["GRAFF_CASES"] = str(
            ROOT / "experiments" / f"{row['suite']}-graff" / "cases.json"
        )
        case = {"id": row["id"].split("/", 1)[-1], "task": row["query"], "gold": row["positive"]["gold"]}
        g = run.run_case(case)
        extra = []
        gold_path = row["positive"]["path"]
        seen = {n["path"] for n in row.get("negatives", [])}
        for t in g.get("tools", []):
            if t in ("codedb", "codedbpro"):
                continue
        out = dict(row)
        out["graff"] = {
            "pass": g.get("pass"),
            "answer": g.get("answer"),
            "tools": g.get("tools"),
            "in_tokens": g.get("in_tokens"),
            "out_tokens": g.get("out_tokens"),
        }
        out["source"] = "codedb-context+gold+graff"
        _ = extra, gold_path, seen
        return out
    done = []
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        futs = {pool.submit(job, r): r["id"] for r in rows}
        for fut in as_completed(futs):
            row = fut.result()
            done.append(row)
            g = row.get("graff", {})
            print(f"  {row['id']} pass={g.get('pass')} tools={g.get('tools')}", flush=True)
    done.sort(key=lambda r: r["id"])
    args.out.write_text("".join(json.dumps(r) + "\n" for r in done))
    print(f"wrote {args.out} graff={len(done)}")


if __name__ == "__main__":
    main()
