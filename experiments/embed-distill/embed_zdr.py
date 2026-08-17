#!/usr/bin/env python3
"""ZDR GPU embed client — batch / parallel streams, no request logging.

End-user query strings go here. Chunk vectors are batched at index time.
Set CODEDB_EMBED_URL + CODEDB_EMBED_KEY. Provider must be ZDR (zero retention).
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.request
from pathlib import Path


def embed(texts: list[str], url: str, key: str, model: str) -> list[list[float]]:
    body = json.dumps({
        "model": model,
        "input": texts,
        "encoding_format": "float",
    }).encode()
    req = urllib.request.Request(
        url,
        data=body,
        headers={
            "Authorization": f"Bearer {key}",
            "Content-Type": "application/json",
            "X-Zero-Data-Retention": "1",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        data = json.loads(resp.read())
    rows = sorted(data["data"], key=lambda r: r["index"])
    return [r["embedding"] for r in rows]


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--kv", type=Path, default=Path(__file__).with_name("kv.jsonl"))
    ap.add_argument("--out", type=Path, default=Path(__file__).with_name("kv.vectors.jsonl"))
    ap.add_argument("--batch", type=int, default=32)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    url = os.environ.get("CODEDB_EMBED_URL", "")
    key = os.environ.get("CODEDB_EMBED_KEY", "")
    model = os.environ.get("CODEDB_EMBED_MODEL", "codedb-moe-5m")
    rows = [json.loads(l) for l in args.kv.read_text().splitlines() if l.strip()]
    if args.dry_run or not url:
        print(f"dry-run batches={((len(rows) + args.batch - 1) // args.batch)} rows={len(rows)} model={model}")
        return
    out = []
    for i in range(0, len(rows), args.batch):
        chunk = rows[i : i + args.batch]
        vecs = embed([r["v"] for r in chunk], url, key, model)
        qvecs = embed([r["k"] for r in chunk], url, key, model)
        for r, v, q in zip(chunk, vecs, qvecs):
            out.append({**r, "v_vec": v, "k_vec": q})
        print(f"  embedded {min(i + args.batch, len(rows))}/{len(rows)}", flush=True)
    args.out.write_text("".join(json.dumps(r) + "\n" for r in out))
    print(f"wrote {args.out} vectors={len(out)} zdr=1")


if __name__ == "__main__":
    main()
