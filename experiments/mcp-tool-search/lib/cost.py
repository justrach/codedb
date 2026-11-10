"""Offline agent cost model: search-call counts and tokens burned."""

from __future__ import annotations

import math
from typing import Any

from lib.metrics import mean, percentile, relevant
from lib.schema_payload import all_schemas_payload, count_tokens, search_payload

PAGE_KS = (3, 5, 10)
MAX_CALLS_CAP = 32  # safety; 536/3 ≈ 179 would be the true worst case


def complete_ranking(partial: list[str], catalog_ids: list[str]) -> list[str]:
    seen = set(partial)
    return list(partial) + [tid for tid in catalog_ids if tid not in seen]


def first_hit_rank(ranking: list[str], rel: set[str]) -> int | None:
    for i, tid in enumerate(ranking, start=1):
        if tid in rel:
            return i
    return None


def page_cost(
    ranking: list[str],
    rel: set[str],
    by_id: dict[str, dict[str, Any]],
    query: str,
    k: int,
) -> dict[str, Any]:
    """Page through `ranking` in slices of k until a relevant tool appears."""
    calls = 0
    tokens = 0
    pages: list[dict[str, Any]] = []
    hit_rank = first_hit_rank(ranking, rel)
    if hit_rank is None:
        return {
            "calls": MAX_CALLS_CAP,
            "tokens": 0,
            "found": False,
            "hit_rank": None,
            "success_within": {1: 0.0, 2: 0.0, 3: 0.0},
        }
    n_pages = max(1, math.ceil(hit_rank / k))
    for p in range(n_pages):
        chunk_ids = ranking[p * k : (p + 1) * k]
        chunk = [by_id[tid] for tid in chunk_ids if tid in by_id]
        payload = search_payload(chunk, query, offset=p * k)
        tok = count_tokens(payload)
        calls += 1
        tokens += tok
        pages.append({"offset": p * k, "ids": chunk_ids, "tokens": tok})
    return {
        "calls": calls,
        "tokens": tokens,
        "found": True,
        "hit_rank": hit_rank,
        "success_within": {1: 1.0 if calls <= 1 else 0.0, 2: 1.0 if calls <= 2 else 0.0, 3: 1.0 if calls <= 3 else 0.0},
        "pages": pages,
    }


def query_cost(
    q: dict[str, Any],
    ranking: list[str],
    catalog_ids: list[str],
    by_id: dict[str, dict[str, Any]],
) -> dict[str, Any]:
    rel = relevant(q)
    full = complete_ranking(ranking, catalog_ids)
    row: dict[str, Any] = {
        "id": q["id"],
        "query": q["query"],
        "hit_rank": first_hit_rank(full, rel),
    }
    for k in PAGE_KS:
        c = page_cost(full, rel, by_id, q["query"], k)
        row[f"k{k}_calls"] = c["calls"]
        row[f"k{k}_tokens"] = c["tokens"]
        row[f"k{k}_found"] = c["found"]
        row[f"k{k}_success1"] = c["success_within"][1]
        row[f"k{k}_success2"] = c["success_within"][2]
        row[f"k{k}_success3"] = c["success_within"][3]
    return row


def summarize_cost(rows: list[dict[str, Any]], k: int) -> dict[str, Any]:
    calls = [float(r[f"k{k}_calls"]) for r in rows]
    toks = [float(r[f"k{k}_tokens"]) for r in rows]
    found = [r[f"k{k}_found"] for r in rows]
    n_ok = sum(1 for f in found if f)
    tok_ok = [t for t, f in zip(toks, found) if f]
    return {
        "k": k,
        "n": len(rows),
        "n_found": n_ok,
        "mean_calls": mean(calls),
        "p95_calls": percentile(calls, 95),
        "success_within_1": mean([float(r[f"k{k}_success1"]) for r in rows]),
        "success_within_2": mean([float(r[f"k{k}_success2"]) for r in rows]),
        "success_within_3": mean([float(r[f"k{k}_success3"]) for r in rows]),
        "mean_tokens": mean(toks),
        "p95_tokens": percentile(toks, 95),
        "total_tokens": int(sum(toks)),
        "tokens_per_successful_query": mean(tok_ok) if tok_ok else float("inf"),
        "total_tokens_successful": int(sum(tok_ok)),
    }


def all_schemas_baseline(tools: list[dict[str, Any]]) -> dict[str, Any]:
    payload = all_schemas_payload(tools)
    n = count_tokens(payload)
    return {
        "n_tools": len(tools),
        "tokens_per_turn": n,
        "encoding": "o200k_base",
        "payload_bytes": len(payload.encode("utf-8")),
    }
