"""IR metrics + bootstrap CIs for the MCP tool-search harness."""

from __future__ import annotations

import math
import random
from typing import Any


def relevant(q: dict[str, Any]) -> set[str]:
    return set(q.get("gold") or []) | set(q.get("alts") or [])


def gold_gain(q: dict[str, Any], tid: str) -> float:
    if tid in (q.get("gold") or []):
        return 2.0
    if tid in (q.get("alts") or []):
        return 1.0
    return 0.0


def recall_at(ranking: list[str], rel: set[str], k: int) -> float:
    if not rel:
        return 0.0
    return 1.0 if any(t in rel for t in ranking[:k]) else 0.0


def mrr_at(ranking: list[str], rel: set[str], k: int = 10) -> float:
    for i, tid in enumerate(ranking[:k], start=1):
        if tid in rel:
            return 1.0 / i
    return 0.0


def dcg(gains: list[float]) -> float:
    return sum(g / math.log2(i + 2) for i, g in enumerate(gains))


def ndcg_at(ranking: list[str], q: dict[str, Any], k: int = 10) -> float:
    gains = [gold_gain(q, tid) for tid in ranking[:k]]
    ideal = sorted(
        [gold_gain(q, tid) for tid in relevant(q)],
        reverse=True,
    )[:k]
    if not ideal or dcg(ideal) == 0:
        return 0.0
    return dcg(gains) / dcg(ideal)


def per_query_row(q: dict[str, Any], ranking: list[str]) -> dict[str, Any]:
    rel = relevant(q)
    return {
        "id": q["id"],
        "query": q["query"],
        "kind": q.get("kind"),
        "gold": q.get("gold"),
        "alts": q.get("alts"),
        "ranking": ranking,
        "hit1": ranking[0] if ranking else None,
        "recall@1": recall_at(ranking, rel, 1),
        "recall@3": recall_at(ranking, rel, 3),
        "recall@5": recall_at(ranking, rel, 5),
        "mrr@10": mrr_at(ranking, rel, 10),
        "ndcg@10": ndcg_at(ranking, q, 10),
    }


def mean(xs: list[float]) -> float:
    return sum(xs) / len(xs) if xs else 0.0


def percentile(xs: list[float], p: float) -> float:
    if not xs:
        return 0.0
    ys = sorted(xs)
    if len(ys) == 1:
        return ys[0]
    k = (len(ys) - 1) * (p / 100.0)
    f = int(math.floor(k))
    c = int(math.ceil(k))
    if f == c:
        return ys[f]
    return ys[f] * (c - k) + ys[c] * (k - f)


def bootstrap_ci(
    values: list[float],
    n: int = 2000,
    seed: int = 20261020,
) -> tuple[float, float, float]:
    rng = random.Random(seed)
    if not values:
        return 0.0, 0.0, 0.0
    means = []
    m = len(values)
    for _ in range(n):
        sample = [values[rng.randrange(m)] for _ in range(m)]
        means.append(sum(sample) / m)
    means.sort()
    lo = means[int(0.025 * n)]
    hi = means[min(n - 1, int(0.975 * n))]
    return mean(values), lo, hi


def summarize(
    queries: list[dict[str, Any]],
    rankings: dict[str, list[str]],
    query_ms: list[float],
    index_s: float,
    rss_mb: float | None,
) -> dict[str, Any]:
    rows = [per_query_row(q, rankings.get(q["id"], [])) for q in queries]
    out: dict[str, Any] = {
        "n": len(rows),
        "index_s": index_s,
        "rss_mb": rss_mb,
        "p50_ms": percentile(query_ms, 50),
        "p95_ms": percentile(query_ms, 95),
    }
    for key in ("recall@1", "recall@3", "recall@5", "mrr@10", "ndcg@10"):
        vals = [float(r[key]) for r in rows]
        mu, lo, hi = bootstrap_ci(vals)
        out[key] = mu
        out[f"{key}_lo"] = lo
        out[f"{key}_hi"] = hi
    return out
