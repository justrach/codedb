#!/usr/bin/env python3
"""One-command MCP tool-search reproduction harness.

This is a reproduction of Zed's unpublished 150×536 MCP tool-search
benchmark (tweet https://x.com/zeddotdev/status/2112588120558338261).
Zed's exact queries/tools/labels are not public.
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import sys
import time
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))

from lib.catalog import (  # noqa: E402
    build_catalog,
    build_distractors,
    build_queries,
    load_frozen,
    materialize_codedb_corpus,
    write_frozen,
)
from lib.codedb_client import CodedbSession  # noqa: E402
from lib.methods import CatalogSearch, MethodResult, MethodMeta, rrf, tokenize, VERBS  # noqa: E402
from lib.metrics import per_query_row, summarize  # noqa: E402

RESULTS = ROOT / "results"
DATA = ROOT / "data"


def ensure_data() -> tuple[list[dict], list[dict]]:
    if (DATA / "catalog.json").exists() and (DATA / "queries.json").exists():
        return load_frozen()
    tools = build_catalog(536)
    queries = build_queries(tools)
    write_frozen(tools, queries)
    return tools, queries


def write_method_outputs(name: str, queries: list[dict], mr: MethodResult, summary: dict) -> None:
    RESULTS.mkdir(parents=True, exist_ok=True)
    rows = [per_query_row(q, mr.rankings.get(q["id"], [])) for q in queries]
    (RESULTS / f"{name}.json").write_text(
        json.dumps({"summary": summary, "meta": mr.meta.__dict__, "rows": rows}, indent=2)
        + "\n",
        encoding="utf-8",
    )
    with (RESULTS / f"{name}.csv").open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(
            f,
            fieldnames=["id", "query", "kind", "hit1", "recall@1", "recall@3", "recall@5", "mrr@10", "ndcg@10", "ranking"],
        )
        w.writeheader()
        for r in rows:
            w.writerow(
                {
                    "id": r["id"],
                    "query": r["query"],
                    "kind": r["kind"],
                    "hit1": r["hit1"],
                    "recall@1": r["recall@1"],
                    "recall@3": r["recall@3"],
                    "recall@5": r["recall@5"],
                    "mrr@10": f"{r['mrr@10']:.4f}",
                    "ndcg@10": f"{r['ndcg@10']:.4f}",
                    "ranking": " ".join(r["ranking"]),
                }
            )


def codedb_methods(session: CodedbSession, queries: list[dict], local: CatalogSearch) -> list[MethodResult]:
    out: list[MethodResult] = []

    def run(name: str, notes: str, fn) -> MethodResult:
        rankings = {}
        qms = []
        for q in queries:
            t0 = time.perf_counter()
            ranking = fn(q)
            qms.append((time.perf_counter() - t0) * 1000.0)
            rankings[q["id"]] = ranking[:10]
        return MethodResult(
            name,
            rankings,
            qms,
            session.index_s,
            None,
            MethodMeta(name, False, False, notes),
        )

    out.append(
        run(
            "codedb_search",
            "codedb_search via MCP (multi-word → searchContentRanked BM25+; single token → trigram substring)",
            lambda q: session.search(q["query"], 20),
        )
    )

    def trigram_tokens(q: dict) -> list[str]:
        toks = [t for t in tokenize(q["query"]) if t not in VERBS]
        if not toks:
            toks = tokenize(q["query"])
        lists = []
        for tok in toks[:4]:
            lists.append(session.search(tok, 20))
        fused = rrf(lists) if lists else []
        return [r.tool_id for r in fused]

    out.append(
        run(
            "codedb_trigram_tokens",
            "per-token codedb_search (single-token trigram path) fused with RRF",
            trigram_tokens,
        )
    )

    def word_search(q: dict) -> list[str]:
        toks = [t for t in tokenize(q["query"]) if t not in VERBS] or tokenize(q["query"])
        lists = [session.word(tok) for tok in toks[:3]]
        fused = rrf(lists) if lists else []
        return [r.tool_id for r in fused]

    out.append(run("codedb_word", "codedb_word on distinctive query tokens, RRF", word_search))

    def symbol_search(q: dict) -> list[str]:
        toks = tokenize(q["query"])
        # Prefer the last content token; also try joined identifier.
        candidates = []
        if toks:
            candidates.append(toks[-1])
            if len(toks) >= 2:
                candidates.append("_".join(toks[-2:]))
        lists = [session.symbol(c) for c in candidates]
        fused = rrf(lists) if lists else []
        return [r.tool_id for r in fused]

    out.append(run("codedb_symbol", "codedb_symbol fuzzy on guessed identifier tokens", symbol_search))

    out.append(
        run(
            "codedb_find",
            "codedb_find fuzzy filename search (server__name.py files)",
            lambda q: session.find(q["query"], 20),
        )
    )

    # Hybrids with local weighted BM25 / trigram need those rankings.
    # Recompute cheaply via CatalogSearch scorer already stored? We re-run weighted
    # by calling local methods from earlier results if present.
    return out


def fuse_hybrid(name: str, a: MethodResult, b: MethodResult, queries: list[dict], notes: str) -> MethodResult:
    rankings = {}
    qms = []
    for q in queries:
        t0 = time.perf_counter()
        fused = rrf([a.rankings.get(q["id"], []), b.rankings.get(q["id"], [])])
        qms.append((time.perf_counter() - t0) * 1000.0)
        rankings[q["id"]] = [r.tool_id for r in fused][:10]
    return MethodResult(
        name,
        rankings,
        qms,
        (a.index_s or 0) + (b.index_s or 0),
        None,
        MethodMeta(name, a.meta.needs_model or b.meta.needs_model, False, notes),
    )


def fmt_pct(x: float) -> str:
    return f"{100.0 * x:.1f}%"


def fmt_ci(summary: dict, key: str) -> str:
    mu = summary[key]
    lo = summary[f"{key}_lo"]
    hi = summary[f"{key}_hi"]
    return f"{fmt_pct(mu)} [{fmt_pct(lo)}, {fmt_pct(hi)}]"


def write_results_md(
    summaries: list[tuple[MethodResult, dict]],
    scaling: list[dict],
    gaps_preview: str,
) -> None:
    lines = [
        "# MCP tool search — reproduction results",
        "",
        "**This is a reproduction, not Zed's unpublished benchmark.**",
        "",
        "Zed posted on 20 Oct 2026 that they tested 25 approaches on 150 queries",
        "against 536 tools and shipped weighted BM25 with a few normalization",
        "rules ([tweet](https://x.com/zeddotdev/status/2112588120558338261)).",
        "The tweet image is a meme, not a write-up. The Zed blog has no post.",
        "The `zed-industries/zed` repo has no public tool-search fixtures",
        "(only an unrelated edit-prediction BM25 retriever).",
        "",
        "Catalog: 536 tools from real public MCP servers (GitHub, filesystem,",
        "memory, postgres, Slack, Linear, Jira, Notion, Playwright, Docker,",
        "Kubernetes, Stripe, …) plus expanded tools from the same families.",
        "Queries: 150 hand-labelled natural-language / identifier queries.",
        "See `GAPS.md` and `data/catalog_stats.json`.",
        "",
        "Metrics are means over 150 queries with 2000-resample bootstrap 95% CIs.",
        "Differences of a few points are usually noise.",
        "",
        "<!-- COST_BEGIN -->",
        "Cost tables are produced by `cost_eval.py` after this file is written.",
        "<!-- COST_END -->",
        "",
        "## Headline table (n=536 tools, 150 queries)",
        "",
        "| Approach | R@1 | R@3 | R@5 | MRR@10 | nDCG@10 | p50 ms | p95 ms | index s | model/API |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|---|",
    ]
    for mr, s in summaries:
        if mr.skipped:
            lines.append(
                f"| {mr.name} | — | — | — | — | — | — | — | — | skipped: {mr.skipped} |"
            )
            continue
        model = "model" if mr.meta.needs_model else ("API" if mr.meta.needs_api else "local")
        lines.append(
            "| {name} | {r1} | {r3} | {r5} | {mrr:.3f} | {nd:.3f} | {p50:.2f} | {p95:.2f} | {ix:.3f} | {model} |".format(
                name=mr.name,
                r1=fmt_pct(s["recall@1"]),
                r3=fmt_pct(s["recall@3"]),
                r5=fmt_pct(s["recall@5"]),
                mrr=s["mrr@10"],
                nd=s["ndcg@10"],
                p50=s["p50_ms"],
                p95=s["p95_ms"],
                ix=s["index_s"],
                model=model,
            )
        )
    lines += [
        "",
        "### Bootstrap 95% CIs for Recall@1 / MRR@10",
        "",
        "| Approach | Recall@1 | MRR@10 |",
        "|---|---|---|",
    ]
    for mr, s in summaries:
        if mr.skipped:
            continue
        lines.append(f"| {mr.name} | {fmt_ci(s, 'recall@1')} | {s['mrr@10']:.3f} [{s['mrr@10_lo']:.3f}, {s['mrr@10_hi']:.3f}] |")

    # Embedding vs trigram
    by_name = {mr.name: (mr, s) for mr, s in summaries}
    lines += [
        "",
        "## Embedding vs trigram (same queries)",
        "",
        "Head-to-head on the 150-query / 536-tool set. `char_trigram` is an",
        "in-process character-trigram cosine (codedb-like). `codedb_trigram_tokens`",
        "is codedb's real trigram path (one search per token). Dense embedding is",
        "`embed_bge_small` when fastembed is available, else hashed n-grams.",
        "",
    ]
    pair_names = [
        "char_trigram",
        "codedb_trigram_tokens",
        "embed_bge_small",
        "hashed_ngram_embed",
        "hybrid_rrf_trigram_embed",
        "hybrid_rrf_bm25_trigram",
        "hybrid_rrf_weighted_embed",
    ]
    lines += [
        "| Approach | R@1 | R@3 | MRR@10 | nDCG@10 | p50 ms |",
        "|---|---:|---:|---:|---:|---:|",
    ]
    for n in pair_names:
        if n not in by_name:
            continue
        mr, s = by_name[n]
        if mr.skipped:
            lines.append(f"| {n} | skipped | — | — | — | — |")
            continue
        lines.append(
            f"| {n} | {fmt_pct(s['recall@1'])} | {fmt_pct(s['recall@3'])} | {s['mrr@10']:.3f} | {s['ndcg@10']:.3f} | {s['p50_ms']:.2f} |"
        )

    lines += [
        "",
        "## Where codedb ranks",
        "",
        "codedb is a **code-intelligence** engine. Here it is asked to retrieve",
        "MCP tools from a synthetic catalog (one Python file per tool). That is",
        "off-label: no field weights, no verb down-weighting, ranking is for source",
        "files (centrality / call-graph) rather than tool metadata.",
        "",
    ]
    codedb_names = [n for n, _ in by_name.items() if n.startswith("codedb") or n.startswith("hybrid_codedb")]
    scored = []
    for n in codedb_names:
        mr, s = by_name[n]
        if not mr.skipped:
            scored.append((s["mrr@10"], n, s))
    scored.sort(reverse=True)
    if scored:
        lines.append("Best codedb-family method by MRR@10: **{}** ({:.3f}).".format(scored[0][1], scored[0][0]))
        lines.append("")

    if scaling:
        lines += [
            "## Scaling (536 → ~2k → ~5k tools)",
            "",
            "Gold tools stay fixed; distractors reuse the same create/get/list verbs.",
            "",
            "| n tools | Approach | R@1 | R@5 | MRR@10 | p50 ms |",
            "|---:|---|---:|---:|---:|---:|",
        ]
        for row in scaling:
            lines.append(
                f"| {row['n_tools']} | {row['name']} | {fmt_pct(row['recall@1'])} | {fmt_pct(row['recall@5'])} | {row['mrr@10']:.3f} | {row['p50_ms']:.2f} |"
            )

    lines += [
        "",
        "## Approaches we could not run",
        "",
        gaps_preview,
        "",
        "Full gap list: [`GAPS.md`](GAPS.md).",
        "",
        "## Raw outputs",
        "",
        "Per-approach JSON/CSV lives in `results/`. Combined table:",
        "`results/summary.json`. Cost: `results/cost.json`. Live: `results/live_agent.json`.",
        "",
    ]
    (ROOT / "results.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    (RESULTS / "results.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def run_scaling(base_tools: list[dict], queries: list[dict]) -> list[dict]:
    rows = []
    sizes = [536, 2000, 5000]
    methods = ("bm25_plain", "bm25_weighted", "char_trigram", "tfidf", "hybrid_rrf_weighted_trigram")
    for n in sizes:
        if n == 536:
            tools = base_tools
        else:
            extra = build_distractors(n - len(base_tools), seed=20261020 + n)
            tools = base_tools + extra
        search = CatalogSearch(tools)
        results = search.run_all(queries, want_dense=False)
        for mr in results:
            if mr.name not in methods or mr.skipped:
                continue
            s = summarize(queries, mr.rankings, mr.query_ms, mr.index_s, mr.rss_mb)
            rows.append({"n_tools": n, "name": mr.name, **{k: s[k] for k in ("recall@1", "recall@3", "recall@5", "mrr@10", "ndcg@10", "p50_ms", "p95_ms", "index_s")}})
    return rows


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--skip-codedb", action="store_true")
    ap.add_argument("--skip-dense", action="store_true")
    ap.add_argument("--skip-scaling", action="store_true")
    ap.add_argument("--codedb-bin", default=str(ROOT / "bin" / "codedb"))
    args = ap.parse_args()

    tools, queries = ensure_data()
    print(f"catalog={len(tools)} queries={len(queries)} servers={len({t['server'] for t in tools})}")

    search = CatalogSearch(tools)
    local = search.run_all(queries, want_dense=not args.skip_dense)
    all_results = list(local)

    codedb_ran = False
    if not args.skip_codedb and Path(args.codedb_bin).exists():
        corpus = ROOT / "catalog_index"
        print("materializing codedb corpus…")
        materialize_codedb_corpus(tools, corpus)
        sess = CodedbSession(str(Path(args.codedb_bin).resolve()), corpus)
        print("starting codedb mcp…")
        sess.start()
        if not sess.ready:
            print("codedb skipped:", sess.error)
            all_results.append(
                MethodResult(
                    "codedb_search",
                    {},
                    [],
                    0.0,
                    None,
                    MethodMeta("codedb_search", False, False, "codedb MCP"),
                    skipped=sess.error or "not ready",
                )
            )
        else:
            print(f"codedb ready in {sess.index_s:.2f}s")
            codedb_ran = True
            try:
                cd = codedb_methods(sess, queries, search)
                all_results.extend(cd)
                by = {m.name: m for m in all_results}
                if "codedb_search" in by and "bm25_weighted" in by:
                    all_results.append(
                        fuse_hybrid(
                            "hybrid_codedb_weighted_bm25",
                            by["codedb_search"],
                            by["bm25_weighted"],
                            queries,
                            "RRF codedb_search + weighted BM25",
                        )
                    )
                if "codedb_trigram_tokens" in by and "bm25_weighted" in by:
                    all_results.append(
                        fuse_hybrid(
                            "hybrid_codedb_trigram_bm25",
                            by["codedb_trigram_tokens"],
                            by["bm25_weighted"],
                            queries,
                            "RRF codedb trigram tokens + weighted BM25",
                        )
                    )
                embed = by.get("embed_bge_small") or by.get("hashed_ngram_embed")
                if embed and not embed.skipped and "codedb_search" in by:
                    all_results.append(
                        fuse_hybrid(
                            "hybrid_codedb_embed",
                            by["codedb_search"],
                            embed,
                            queries,
                            "RRF codedb_search + embedding",
                        )
                    )
            finally:
                sess.close()
    elif not args.skip_codedb:
        all_results.append(
            MethodResult(
                "codedb_search",
                {},
                [],
                0.0,
                None,
                MethodMeta("codedb_search", False, False, "codedb MCP"),
                skipped=f"binary not found: {args.codedb_bin}",
            )
        )

    summaries: list[tuple[MethodResult, dict]] = []
    for mr in all_results:
        if mr.skipped:
            summaries.append((mr, {}))
            continue
        s = summarize(queries, mr.rankings, mr.query_ms, mr.index_s, mr.rss_mb)
        write_method_outputs(mr.name, queries, mr, s)
        summaries.append((mr, s))
        print(f"{mr.name:32s} R@1={s['recall@1']:.3f} R@5={s['recall@5']:.3f} MRR={s['mrr@10']:.3f} p50={s['p50_ms']:.2f}ms")

    scaling: list[dict] = []
    if not args.skip_scaling:
        print("scaling…")
        scaling = run_scaling(tools, queries)
        (RESULTS / "scaling.json").write_text(json.dumps(scaling, indent=2) + "\n", encoding="utf-8")

    combined = []
    for mr, s in summaries:
        item = {"name": mr.name, "skipped": mr.skipped, "notes": mr.meta.notes, "needs_model": mr.meta.needs_model}
        item.update(s)
        combined.append(item)
    RESULTS.mkdir(parents=True, exist_ok=True)
    (RESULTS / "summary.json").write_text(
        json.dumps(
            {
                "reproduction": True,
                "zed_fixtures_public": False,
                "n_tools": len(tools),
                "n_queries": len(queries),
                "codedb_ran": codedb_ran,
                "methods": combined,
                "scaling": scaling,
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )

    gaps_preview = (
        "- Zed's exact 25-approach list, queries, tools, labels, field weights, and BM25 parameters are not public.\n"
        "- LLM routing and trained decision models (LightGBM etc.) were not run: no API key / no labelled train split from Zed.\n"
        "- Cross-encoder rerankers and API embedding models were not run unless those packages/keys are present.\n"
        "- A second local dense model (gte/nomic) was not downloaded to keep the one-command path small.\n"
    )
    write_results_md(summaries, scaling, gaps_preview)
    print("wrote results.md")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
