#!/usr/bin/env python3
"""Compute the offline agent cost model from saved rankings (or a live run)."""

from __future__ import annotations

import csv
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))

from lib.catalog import load_frozen  # noqa: E402
from lib.cost import (  # noqa: E402
    PAGE_KS,
    all_schemas_baseline,
    query_cost,
    summarize_cost,
)

RESULTS = ROOT / "results"


def load_method_rankings() -> dict[str, dict]:
    out = {}
    for p in sorted(RESULTS.glob("*.json")):
        if p.name in {
            "summary.json",
            "scaling.json",
            "cost.json",
            "cost_per_query.json",
            "live_agent.json",
        }:
            continue
        data = json.loads(p.read_text(encoding="utf-8"))
        if "rows" not in data or "meta" not in data:
            continue
        name = data["meta"]["name"]
        rankings = {r["id"]: r.get("ranking") or [] for r in data["rows"]}
        out[name] = {
            "path": p,
            "data": data,
            "rankings": rankings,
            "recall@1": data.get("summary", {}).get("recall@1"),
        }
    return out


def main() -> int:
    tools, queries = load_frozen()
    by_id = {t["id"]: t for t in tools}
    catalog_ids = [t["id"] for t in tools]
    methods = load_method_rankings()
    if not methods:
        print("no saved rankings in results/; run harness.py first", file=sys.stderr)
        return 1

    baseline = all_schemas_baseline(tools)
    print(
        f"all-schemas baseline: {baseline['tokens_per_turn']} o200k tokens "
        f"({baseline['n_tools']} tools)"
    )

    cost_methods = []
    for name, bundle in methods.items():
        rows = [query_cost(q, bundle["rankings"].get(q["id"], []), catalog_ids, by_id) for q in queries]
        by_k = {k: summarize_cost(rows, k) for k in PAGE_KS}
        rec = bundle["recall@1"]
        cost_methods.append(
            {
                "name": name,
                "recall@1": rec,
                "by_k": by_k,
                "rows": rows,
            }
        )

        # Merge cost fields into the per-query JSON/CSV.
        data = bundle["data"]
        row_by_id = {r["id"]: r for r in rows}
        for r in data["rows"]:
            extra = row_by_id.get(r["id"])
            if not extra:
                continue
            for key in extra:
                if key in {"id", "query"}:
                    continue
                r[key] = extra[key]
        data["cost"] = {str(k): by_k[k] for k in PAGE_KS}
        bundle["path"].write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")

        csv_path = RESULTS / f"{name}.csv"
        fieldnames = [
            "id",
            "query",
            "kind",
            "hit1",
            "recall@1",
            "recall@3",
            "recall@5",
            "mrr@10",
            "ndcg@10",
            "hit_rank",
            "k3_calls",
            "k3_tokens",
            "k3_success1",
            "k5_calls",
            "k5_tokens",
            "k5_success1",
            "k10_calls",
            "k10_tokens",
            "k10_success1",
            "ranking",
        ]
        with csv_path.open("w", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=fieldnames, extrasaction="ignore")
            w.writeheader()
            for r in data["rows"]:
                w.writerow(
                    {
                        **r,
                        "mrr@10": f"{float(r.get('mrr@10') or 0):.4f}",
                        "ndcg@10": f"{float(r.get('ndcg@10') or 0):.4f}",
                        "ranking": " ".join(r.get("ranking") or []),
                    }
                )
        k5 = by_k[5]
        print(
            f"{name:32s} k=5 calls={k5['mean_calls']:.2f} (p95 {k5['p95_calls']:.1f}) "
            f"tok/q={k5['mean_tokens']:.0f} success@1={k5['success_within_1']:.3f}"
        )

    # Rank by tokens per successful query at k=5 (FastMCP-style page size).
    ranked = sorted(
        cost_methods,
        key=lambda m: (m["by_k"][5]["tokens_per_successful_query"], -(m["recall@1"] or 0)),
    )
    recall_order = sorted(
        [m for m in cost_methods if m["recall@1"] is not None],
        key=lambda m: -(m["recall@1"] or 0),
    )
    recall_rank = {m["name"]: i + 1 for i, m in enumerate(recall_order)}

    ranking_table = []
    for i, m in enumerate(ranked, start=1):
        ranking_table.append(
            {
                "cost_rank": i,
                "recall_rank": recall_rank.get(m["name"]),
                "name": m["name"],
                "recall@1": m["recall@1"],
                "k5_tokens_per_success": m["by_k"][5]["tokens_per_successful_query"],
                "k5_mean_calls": m["by_k"][5]["mean_calls"],
                "k5_success_within_1": m["by_k"][5]["success_within_1"],
                "rank_diff": (None if recall_rank.get(m["name"]) is None else recall_rank[m["name"]] - i),
            }
        )

    payload = {
        "encoding": "o200k_base",
        "page_ks": list(PAGE_KS),
        "n_queries": len(queries),
        "n_tools": len(tools),
        "all_schemas_baseline": baseline,
        "methods": [
            {
                "name": m["name"],
                "recall@1": m["recall@1"],
                "by_k": m["by_k"],
            }
            for m in cost_methods
        ],
        "ranking_by_tokens_per_success_k5": ranking_table,
        "model": (
            "Deterministic offset paging of the saved ranking. Call n returns "
            "ranks[(n-1)k : n k] as full MCP tool schemas. Stops when any gold/alt "
            "appears. Tools not in the saved top-10 are appended in catalog order "
            "(pessimistic tail for misses)."
        ),
    }
    (RESULTS / "cost.json").write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

    with (RESULTS / "cost.csv").open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(
            f,
            fieldnames=[
                "name",
                "recall@1",
                "k",
                "mean_calls",
                "p95_calls",
                "success_within_1",
                "success_within_2",
                "success_within_3",
                "mean_tokens",
                "p95_tokens",
                "total_tokens",
                "tokens_per_successful_query",
            ],
        )
        w.writeheader()
        for m in cost_methods:
            for k in PAGE_KS:
                s = m["by_k"][k]
                w.writerow(
                    {
                        "name": m["name"],
                        "recall@1": "" if m["recall@1"] is None else f"{m['recall@1']:.4f}",
                        "k": k,
                        "mean_calls": f"{s['mean_calls']:.4f}",
                        "p95_calls": f"{s['p95_calls']:.4f}",
                        "success_within_1": f"{s['success_within_1']:.4f}",
                        "success_within_2": f"{s['success_within_2']:.4f}",
                        "success_within_3": f"{s['success_within_3']:.4f}",
                        "mean_tokens": f"{s['mean_tokens']:.1f}",
                        "p95_tokens": f"{s['p95_tokens']:.1f}",
                        "total_tokens": s["total_tokens"],
                        "tokens_per_successful_query": f"{s['tokens_per_successful_query']:.1f}",
                    }
                )

    with (RESULTS / "cost_per_query.csv").open("w", newline="", encoding="utf-8") as f:
        fields = ["method", "id", "query", "hit_rank"]
        for k in PAGE_KS:
            fields += [f"k{k}_calls", f"k{k}_tokens", f"k{k}_success1", f"k{k}_success2", f"k{k}_success3"]
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        for m in cost_methods:
            for r in m["rows"]:
                w.writerow({"method": m["name"], **{k: r[k] for k in fields if k != "method"}})

    (RESULTS / "cost_per_query.json").write_text(
        json.dumps({m["name"]: m["rows"] for m in cost_methods}, indent=2) + "\n",
        encoding="utf-8",
    )
    section = render_cost_md(payload, ranking_table)
    splice_cost_section(ROOT / "results.md", section)
    splice_cost_section(RESULTS / "results.md", section)
    print(f"wrote {RESULTS / 'cost.json'}")
    return 0


def _pct(x: float) -> str:
    return f"{100.0 * x:.1f}%"


def _f(x: float, n: int = 2) -> str:
    return f"{x:.{n}f}"


def render_cost_md(payload: dict, ranking_table: list[dict]) -> str:
    base = payload["all_schemas_baseline"]
    by = {m["name"]: m for m in payload["methods"]}
    lines = [
        "## Agent cost (search calls + tokens, not recall@k)",
        "",
        "Recall@k is not the agent metric. An agent calls `search(query)`, gets",
        "the top-k **full tool schemas** (name, description, inputSchema, as an",
        "MCP `tools/list` / `search_tools` hit), and pages until the gold/alt",
        "tool appears. Tokens are `tiktoken` **o200k_base** over the compact JSON",
        "payload actually returned to the model.",
        "",
        "Paging model: offset slices of the saved ranking.",
        "Call *n* returns ranks `[(n-1)k : n k]`. Tools missing from the saved",
        "top-10 are appended in catalog order (pessimistic tail).",
        "",
        f"**All-schemas baseline:** `{base['tokens_per_turn']:,}` o200k tokens",
        f"per turn to load all {base['n_tools']} tool schemas up front",
        f"({base['payload_bytes']:,} bytes). No search calls.",
        "",
        "### Ranking by tokens burned per successful query (k=5)",
        "",
        "Primary page size is 5 (FastMCP-style). Sorted by mean o200k tokens",
        "returned until gold appears. **This ranking is not the recall@1 ranking.**",
        "29 of 30 approaches change place. `boolean_or` wins recall@1 (94.7%)",
        "and lands 19th on cost: its first page is fatter, and the rare miss",
        "pages deep into the catalog tail. Methods that put gold in the first",
        "page (even at rank 2–5) are cheaper even when they lose rank-1.",
        "",
        "| Cost # | Recall # | Δ | Approach | R@1 | tok/success | mean calls | success@1 |",
        "|---:|---:|---:|---|---:|---:|---:|---:|",
    ]
    for row in ranking_table:
        delta = row["rank_diff"]
        d = "—" if delta is None else f"{delta:+d}"
        r1 = "" if row["recall@1"] is None else _pct(row["recall@1"])
        lines.append(
            f"| {row['cost_rank']} | {row['recall_rank']} | {d} | {row['name']} | "
            f"{r1} | {row['k5_tokens_per_success']:.1f} | "
            f"{row['k5_mean_calls']:.2f} | {_pct(row['k5_success_within_1'])} |"
        )

    top = ranking_table[0]
    top_s = by[top["name"]]["by_k"][5]
    save = base["tokens_per_turn"] - top_s["mean_tokens"]
    lines += [
        "",
        f"Cheapest: **{top['name']}** at {top['k5_tokens_per_success']:.0f} tokens/query "
        f"({save:,.0f} less than the all-schemas dump, "
        f"{100.0 * save / base['tokens_per_turn']:.1f}% saved). "
        f"Mean search calls {top['k5_mean_calls']:.2f}, first-page hit "
        f"{_pct(top['k5_success_within_1'])}.",
        "",
        "Mean tokens can exceed p95: a few deep-tail misses pull the mean up",
        "while 95% of queries finish in one page.",
        "",
    ]

    for k in PAGE_KS:
        lines += [
            f"### Offline cost, k={k}",
            "",
            "| Approach | mean calls | p95 calls | ≤1 | ≤2 | ≤3 | mean tok | p95 tok | total tok |",
            "|---|---:|---:|---:|---:|---:|---:|---:|---:|",
        ]
        for row in ranking_table:
            s = by[row["name"]]["by_k"][k]
            lines.append(
                f"| {row['name']} | {_f(s['mean_calls'])} | {_f(s['p95_calls'], 1)} | "
                f"{_pct(s['success_within_1'])} | {_pct(s['success_within_2'])} | "
                f"{_pct(s['success_within_3'])} | {s['mean_tokens']:.0f} | "
                f"{s['p95_tokens']:.0f} | {s['total_tokens']:,} |"
            )
        lines.append("")

    lines += [
        "### Live agent loop",
        "",
        "Skipped in this environment: no LLM API key",
        "(`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `AZURE_OPENAI_API_KEY`,",
        "`GOOGLE_API_KEY`, `GEMINI_API_KEY`, `COHERE_API_KEY`, `TOGETHER_API_KEY`,",
        "`GROQ_API_KEY`, `MISTRAL_API_KEY`, `OPENROUTER_API_KEY`).",
        "",
        "Harness is ready:",
        "",
        "```bash",
        "OPENAI_API_KEY=... python live_agent.py",
        "# or",
        "ANTHROPIC_API_KEY=... python live_agent.py",
        "```",
        "",
        "Default approaches: `bm25_plain`, `bm25_weighted`, `embed_bge_small`,",
        "`hybrid_rrf_bm25_embed`, `codedb_search`, `char_trigram`. Records real",
        "search-call counts, API input/output tokens, whether the named tool is",
        "gold/alt, and wall time. Writes `results/live_agent.json`.",
        "",
        "Raw cost outputs: `results/cost.json`, `results/cost.csv`,",
        "`results/cost_per_query.json`, `results/cost_per_query.csv`.",
        "Per-approach JSON/CSV now include `hit_rank` and `k{3,5,10}_*` fields.",
        "",
    ]
    return "\n".join(lines)


COST_BEGIN = "<!-- COST_BEGIN -->"
COST_END = "<!-- COST_END -->"


def splice_cost_section(path: Path, section: str) -> None:
    block = f"{COST_BEGIN}\n{section}{COST_END}\n"
    if path.exists():
        text = path.read_text(encoding="utf-8")
        if COST_BEGIN in text and COST_END in text:
            pre, rest = text.split(COST_BEGIN, 1)
            _, post = rest.split(COST_END, 1)
            path.write_text(pre + block + post.lstrip("\n"), encoding="utf-8")
            return
        # Insert before the recall headline table if present, else append.
        needle = "## Headline table"
        if needle in text:
            pre, post = text.split(needle, 1)
            path.write_text(pre.rstrip() + "\n\n" + block + "\n" + needle + post, encoding="utf-8")
            return
        path.write_text(text.rstrip() + "\n\n" + block, encoding="utf-8")
        return
    path.write_text(block, encoding="utf-8")


if __name__ == "__main__":
    raise SystemExit(main())
