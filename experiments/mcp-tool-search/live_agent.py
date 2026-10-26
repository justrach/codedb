#!/usr/bin/env python3
"""Live agent loop: a small model + search_tools backed by one approach.

Skipped automatically when no LLM API key is present. Ready to run:

    OPENAI_API_KEY=... python live_agent.py
    ANTHROPIC_API_KEY=... python live_agent.py

Uses gpt-4o-mini or claude-haiku-4-5. Each of the 150 queries is a fresh
conversation with one tool, `search_tools`, then the model must name the
tool it would call. We record API usage tokens, search-call count, whether
the named tool is gold/alt, and wall time.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))

from lib.catalog import load_frozen  # noqa: E402
from lib.cost import complete_ranking, first_hit_rank  # noqa: E402
from lib.metrics import relevant  # noqa: E402
from lib.schema_payload import search_payload  # noqa: E402

RESULTS = ROOT / "results"
DEFAULT_APPROACHES = (
    "bm25_plain",
    "bm25_weighted",
    "embed_bge_small",
    "hybrid_rrf_bm25_embed",
    "codedb_search",
    "char_trigram",
)


CHECKED_KEYS = (
    "OPENAI_API_KEY",
    "ANTHROPIC_API_KEY",
    "AZURE_OPENAI_API_KEY",
    "GOOGLE_API_KEY",
    "GEMINI_API_KEY",
    "COHERE_API_KEY",
    "TOGETHER_API_KEY",
    "GROQ_API_KEY",
    "MISTRAL_API_KEY",
    "OPENROUTER_API_KEY",
)


def detect_provider() -> tuple[str, str] | None:
    if os.environ.get("OPENAI_API_KEY"):
        return "openai", os.environ.get("LIVE_AGENT_MODEL") or "gpt-4o-mini"
    if os.environ.get("ANTHROPIC_API_KEY"):
        return "anthropic", os.environ.get("LIVE_AGENT_MODEL") or "claude-haiku-4-5"
    return None


def skip_reason() -> str:
    present = [k for k in CHECKED_KEYS if os.environ.get(k)]
    if present:
        return (
            f"Keys present ({', '.join(present)}) but no supported live-loop "
            "provider adapter (need OPENAI_API_KEY or ANTHROPIC_API_KEY)."
        )
    return (
        "No LLM API key in the environment (checked "
        + ", ".join(CHECKED_KEYS)
        + "). Offline cost model still ran. To execute the live loop: "
        "OPENAI_API_KEY=... python live_agent.py"
    )


def load_rankings(name: str) -> dict[str, list[str]]:
    p = RESULTS / f"{name}.json"
    if not p.exists():
        raise FileNotFoundError(p)
    data = json.loads(p.read_text(encoding="utf-8"))
    return {r["id"]: r.get("ranking") or [] for r in data["rows"]}


SYSTEM = """You pick MCP tools. You do not have the catalog in context.
Use search_tools to find a tool for the user request, then answer with ONLY
the tool id (server.name) you would call. Do not call a tool that was not
returned by search_tools. If the first page is wrong, search again with a
narrower query."""


def openai_loop(model: str, query: str, page_fn, k: int, max_calls: int) -> dict:
    from openai import OpenAI

    client = OpenAI()
    tools = [
        {
            "type": "function",
            "function": {
                "name": "search_tools",
                "description": "Search the MCP tool catalog. Returns the top-k tool schemas.",
                "parameters": {
                    "type": "object",
                    "properties": {"query": {"type": "string"}},
                    "required": ["query"],
                },
            },
        }
    ]
    messages = [
        {"role": "system", "content": SYSTEM},
        {"role": "user", "content": query["query"]},
    ]
    search_calls = 0
    in_tok = 0
    out_tok = 0
    named = None
    t0 = time.perf_counter()
    for _ in range(max_calls + 2):
        resp = client.chat.completions.create(model=model, messages=messages, tools=tools, temperature=0)
        if resp.usage:
            in_tok += resp.usage.prompt_tokens or 0
            out_tok += resp.usage.completion_tokens or 0
        msg = resp.choices[0].message
        if msg.tool_calls:
            messages.append(msg.model_dump(exclude_unset=True))
            for tc in msg.tool_calls:
                if tc.function.name != "search_tools":
                    continue
                search_calls += 1
                args = json.loads(tc.function.arguments or "{}")
                payload = page_fn(args.get("query") or query["query"], search_calls)
                messages.append(
                    {"role": "tool", "tool_call_id": tc.id, "content": payload}
                )
            continue
        named = (msg.content or "").strip().split()[0] if msg.content else None
        break
    return {
        "search_calls": search_calls,
        "input_tokens": in_tok,
        "output_tokens": out_tok,
        "named_tool": named,
        "wall_s": time.perf_counter() - t0,
    }


def anthropic_loop(model: str, query: str, page_fn, k: int, max_calls: int) -> dict:
    import anthropic

    client = anthropic.Anthropic()
    tools = [
        {
            "name": "search_tools",
            "description": "Search the MCP tool catalog. Returns the top-k tool schemas.",
            "input_schema": {
                "type": "object",
                "properties": {"query": {"type": "string"}},
                "required": ["query"],
            },
        }
    ]
    messages = [{"role": "user", "content": query["query"]}]
    search_calls = 0
    in_tok = 0
    out_tok = 0
    named = None
    t0 = time.perf_counter()
    for _ in range(max_calls + 2):
        resp = client.messages.create(
            model=model,
            max_tokens=256,
            system=SYSTEM,
            tools=tools,
            messages=messages,
            temperature=0,
        )
        in_tok += resp.usage.input_tokens
        out_tok += resp.usage.output_tokens
        if resp.stop_reason == "tool_use":
            messages.append({"role": "assistant", "content": resp.content})
            tool_results = []
            for block in resp.content:
                if block.type != "tool_use":
                    continue
                search_calls += 1
                q = (block.input or {}).get("query") or query["query"]
                tool_results.append(
                    {
                        "type": "tool_result",
                        "tool_use_id": block.id,
                        "content": page_fn(q, search_calls),
                    }
                )
            messages.append({"role": "user", "content": tool_results})
            continue
        text = "".join(b.text for b in resp.content if getattr(b, "type", "") == "text")
        named = text.strip().split()[0] if text.strip() else None
        break
    return {
        "search_calls": search_calls,
        "input_tokens": in_tok,
        "output_tokens": out_tok,
        "named_tool": named,
        "wall_s": time.perf_counter() - t0,
    }


def make_page_fn(ranking: list[str], by_id: dict, catalog_ids: list[str], k: int, original: str):
    full = complete_ranking(ranking, catalog_ids)

    def page_fn(search_query: str, call_n: int) -> str:
        # Offset paging on the original ranking. A rewritten query still
        # pages the same list in this harness (documented in GAPS.md) unless
        # the caller re-runs a real index; keep it deterministic + cheap.
        start = max(0, (call_n - 1) * k)
        ids = full[start : start + k]
        tools = [by_id[i] for i in ids if i in by_id]
        return search_payload(tools, search_query or original, offset=start)

    return page_fn


def run_live(approaches: list[str], k: int, max_calls: int, limit: int | None) -> dict:
    provider = detect_provider()
    if provider is None:
        return {
            "skipped": True,
            "reason": skip_reason(),
            "checked_keys": list(CHECKED_KEYS),
            "command": "OPENAI_API_KEY=... python live_agent.py",
        }
    kind, model = provider
    tools, queries = load_frozen()
    if limit:
        queries = queries[:limit]
    by_id = {t["id"]: t for t in tools}
    catalog_ids = [t["id"] for t in tools]
    loop = openai_loop if kind == "openai" else anthropic_loop
    out_approaches = []
    for name in approaches:
        rankings = load_rankings(name)
        rows = []
        for q in queries:
            page_fn = make_page_fn(rankings.get(q["id"], []), by_id, catalog_ids, k, q["query"])
            rec = loop(model, q, page_fn, k, max_calls)
            rel = relevant(q)
            named = rec["named_tool"]
            rec.update(
                {
                    "id": q["id"],
                    "query": q["query"],
                    "gold": q["gold"],
                    "correct": bool(named and named in rel),
                    "gold_in_first_page": first_hit_rank(
                        complete_ranking(rankings.get(q["id"], []), catalog_ids), rel
                    )
                    is not None
                    and first_hit_rank(complete_ranking(rankings.get(q["id"], []), catalog_ids), rel)
                    <= k,
                }
            )
            rows.append(rec)
            print(
                f"{name} {q['id']} calls={rec['search_calls']} "
                f"in={rec['input_tokens']} out={rec['output_tokens']} "
                f"named={named} ok={rec['correct']}"
            )
        n = len(rows) or 1
        out_approaches.append(
            {
                "name": name,
                "n": len(rows),
                "correct_rate": sum(r["correct"] for r in rows) / n,
                "mean_search_calls": sum(r["search_calls"] for r in rows) / n,
                "total_input_tokens": sum(r["input_tokens"] for r in rows),
                "total_output_tokens": sum(r["output_tokens"] for r in rows),
                "mean_wall_s": sum(r["wall_s"] for r in rows) / n,
                "rows": rows,
            }
        )
    return {
        "skipped": False,
        "provider": kind,
        "model": model,
        "k": k,
        "approaches": out_approaches,
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--approaches", default=",".join(DEFAULT_APPROACHES))
    ap.add_argument("--k", type=int, default=5)
    ap.add_argument("--max-calls", type=int, default=3)
    ap.add_argument("--limit", type=int, default=0, help="cap queries (0 = all 150)")
    args = ap.parse_args()
    result = run_live(
        [a.strip() for a in args.approaches.split(",") if a.strip()],
        k=args.k,
        max_calls=args.max_calls,
        limit=args.limit or None,
    )
    RESULTS.mkdir(parents=True, exist_ok=True)
    (RESULTS / "live_agent.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    if result.get("skipped"):
        print("live agent skipped:", result["reason"])
        return 0
    print("wrote", RESULTS / "live_agent.json")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
