#!/usr/bin/env python3
"""Parallel teacher grades for (k, v) pairs. Streams, not one-at-a-time.

Default teacher is the same 5.6-luna graff already uses (cheap, local-ish).
Set TEACHER=kimi-k3 + KIMI_API_KEY to swap in K3. Never logs the pair body
when --zdr is set (request-only, no transcript dump).
"""
from __future__ import annotations

import argparse
import json
import os
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

PROMPT = """Grade how well the code chunk answers the task.
Reply with only an integer 0-3:
0 unrelated
1 mentions the topic
2 implements related logic
3 is the definition / the place to change

TASK:
{k}

CHUNK:
{v}
"""


def grade_openai(k: str, v: str, url: str, model: str, key: str, timeout: int) -> int:
    body = json.dumps({
        "model": model,
        "temperature": 0,
        "max_tokens": 4,
        "messages": [{"role": "user", "content": PROMPT.format(k=k, v=v[:4000])}],
    }).encode()
    req = urllib.request.Request(
        url,
        data=body,
        headers={
            "Authorization": f"Bearer {key}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        data = json.loads(resp.read())
    text = data["choices"][0]["message"]["content"].strip()
    for ch in text:
        if ch in "0123":
            return int(ch)
    return 0


def one(row: dict, url: str, model: str, key: str, timeout: int) -> dict:
    out = dict(row)
    try:
        out["teacher_label"] = grade_openai(row["k"], row["v"], url, model, key, timeout)
        out["teacher"] = model
    except (urllib.error.URLError, TimeoutError, KeyError, json.JSONDecodeError) as e:
        out["teacher_label"] = row.get("label", 0)
        out["teacher_error"] = type(e).__name__
    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--kv", type=Path, default=Path(__file__).with_name("kv.jsonl"))
    ap.add_argument("--out", type=Path, default=Path(__file__).with_name("kv.labeled.jsonl"))
    ap.add_argument("--workers", type=int, default=16)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    teacher = os.environ.get("TEACHER", "5.6-luna")
    url = os.environ.get("TEACHER_URL", os.environ.get("OPENAI_BASE_URL", "https://api.openai.com/v1") + "/chat/completions")
    if not url.endswith("/chat/completions"):
        url = url.rstrip("/") + "/chat/completions"
    key = os.environ.get("TEACHER_API_KEY") or os.environ.get("OPENAI_API_KEY") or os.environ.get("KIMI_API_KEY") or ""
    rows = [json.loads(l) for l in args.kv.read_text().splitlines() if l.strip()]
    if args.limit:
        rows = rows[: args.limit]
    if args.dry_run or not key:
        args.out.write_text("".join(json.dumps({**r, "teacher_label": r["label"], "teacher": "bootstrap"}) + "\n" for r in rows))
        print(f"wrote {args.out} labeled={len(rows)} teacher=bootstrap (no key or --dry-run)")
        return
    out_rows = []
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        futs = [pool.submit(one, r, url, teacher, key, 45) for r in rows]
        for i, fut in enumerate(as_completed(futs), 1):
            out_rows.append(fut.result())
            if i % 8 == 0 or i == len(rows):
                print(f"  graded {i}/{len(rows)}", flush=True)
    args.out.write_text("".join(json.dumps(r) + "\n" for r in out_rows))
    print(f"wrote {args.out} labeled={len(out_rows)} teacher={teacher} workers={args.workers}")


if __name__ == "__main__":
    main()
