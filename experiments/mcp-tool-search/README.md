# experiments/mcp-tool-search

Reproduction of [Zed's 20 Oct 2026 MCP tool-search tweet](https://x.com/zeddotdev/status/2112588120558338261).

**This does not change codedb's shipped behaviour.** Everything lives under this directory.

## Status: reproduction, not Zed's fixtures

Zed said they tested 25 approaches (decision models, LLMs, embeddings) on
150 queries against 536 tools and shipped weighted BM25 with a few
normalization rules. Their tweet links a meme, not a write-up. The Zed
blog has no post. `zed-industries/zed` has no public tool-search
benchmark (the only BM25 code is an edit-prediction retriever).

This harness builds the closest faithful public reproduction:

- 536-tool catalog from real public MCP servers (GitHub, filesystem,
  memory, postgres, Slack, Linear, Jira, Notion, Playwright, Docker,
  Kubernetes, Stripe, …) plus expanded tools from those families
- 150 hand-labelled queries
- Local implementations of the approaches that can be run without Zed's
  unpublished weights or an LLM API

See [`GAPS.md`](GAPS.md) for everything that is not public or was not run.

## Run

```bash
./run.sh
```

That creates a venv, optionally installs `fastembed` (bge-small),
downloads a codedb release binary if needed, freezes the catalog, runs
the recall harness, then the offline agent-cost model (`cost_eval.py`)
and the live-agent loop (`live_agent.py`, skipped if no LLM key).

Useful flags (passed through to `harness.py`):

```bash
./run.sh --skip-dense
./run.sh --skip-codedb
./run.sh --skip-scaling
```

Cost-only (reuses saved rankings, no search rerun):

```bash
python cost_eval.py
OPENAI_API_KEY=... python live_agent.py   # skipped without a key
```

## Approaches

Local / Zed-like:

- plain BM25, identifier-split BM25, name-only / description-only BM25
- **weighted field BM25** (name/namespace boosts, verb down-weighting,
  identifier splitting) — our stand-in for what Zed shipped
- TF-IDF, StackOne-style BM25+TF-IDF (20/80)
- boolean AND/OR, name exact/substring
- character trigram cosine
- hashed n-gram embedding (fallback, not neural)
- RRF hybrids (BM25↔trigram, weighted↔trigram, weighted↔embed)
- rule-based decision heuristic and tiny synonym rewrite (not an LLM)
- lexical rerank of weighted-BM25 top-20

If `fastembed` installs:

- `BAAI/bge-small-en-v1.5` plus RRF hybrids with BM25 / weighted / trigram

codedb primitives (one Python file per tool: name, description, params, server):

- `codedb_search` (auto: ranked BM25+ on multi-word, trigram substring on one token)
- `codedb_trigram_tokens` (per-token trigram path + RRF)
- `codedb_word`, `codedb_symbol`, `codedb_find`
- hybrids: codedb + weighted BM25, codedb trigram + BM25, codedb + embedding

Not run (see GAPS.md): LLM routing, trained LightGBM/decision models,
cross-encoder rerankers, API embedding models, Zed's exact 25 list.

## Metrics

Recall@1/3/5, MRR@10, nDCG@10, p50/p95 query latency, index build time,
RSS where available, model/API need. Bootstrap 95% CIs (2000 resamples).
Scaling: 536, ~2k, ~5k tools by adding verb-heavy distractors.

Agent cost (the metric that matters for a tool-using model): search-call
count and o200k_base tokens returned as full MCP schemas, paging at
k ∈ {3, 5, 10}, plus an all-536-schemas baseline. Approaches are ranked
by tokens burned per successful query. Live loop records real API usage
when `OPENAI_API_KEY` or `ANTHROPIC_API_KEY` is set.
