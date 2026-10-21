# Gaps

This experiment is a **reproduction**. Zed's tweet of 20 Oct 2026
([2112588120558338261](https://x.com/zeddotdev/status/2112588120558338261))
is the only primary source. The linked `t.co` asset is a midwit-meme image
(`fixtures/zed-tweet-2026-10-20.png`), not a paper, table, or fixture dump.
Replies asking for a blog, paper, or the 150 tests went unanswered at the
time of this run.

## Zed setup that is not public

| Item | Status |
|---|---|
| The 150 queries | Not public |
| The 536-tool catalog | Not public (which servers, which names, which schemas) |
| Gold labels / acceptable alternatives | Not public |
| The list of 25 approaches | Not public — tweet only says "decision models, LLMs, and embeddings" |
| Field weights, k1/b, verb list, boost values | Not public |
| Identifier-splitting / normalization code | Not in `zed-industries/zed` (searched BM25, tool_search, 536, weighted) |
| Per-approach scores, latency, CIs | Not public |
| Train/test split or significance tests | Not public |
| Whether IDF is per-user catalog or global | Asked in-thread; unanswered |

The only BM25 in the Zed repo is `crates/edit_prediction_context/src/bm25_context.rs`
(edit-prediction context, June 2026). That is a different problem.

## Catalog / query differences vs Zed

Our catalog (`data/catalog.json`):

- 536 tools, 51 servers
- 366 tools hand-authored from public MCP names/descriptions (GitHub official
  MCP, modelcontextprotocol filesystem/memory/fetch/git/postgres/time,
  Slack/Linear/Jira/Notion-style servers, Playwright, Docker, Kubernetes,
  Stripe, …)
- 170 `expanded` tools generated from the same servers' resource/action
  families so the size matches Zed's 536
- 150 hand-labelled queries (`data/queries.json`) in five kinds:
  verb+product, paraphrase, identifier, resource, ambiguous

This is **easier than StackOne's published suite** (270 tools / 2,700
queries, BM25 top-1 14%). Our descriptions almost always contain the
product token (`jira`, `slack`, `postgres`), so lexical overlap is a
strong signal. That is why `boolean_or` and plain BM25 look extremely
strong here. Do **not** treat the absolute percentages as Zed's numbers.

Scaling distractors (`acme_*`, `northstar_*`, …) reuse create/get/list
verbs but use vendor names that never appear in the queries. They test
"does IDF get polluted?" more than "does `create` steal the rank from
`jira`?" — so BM25 does **not** fall off at 2k/5k the way StackOne/Stacklok
reported on lookalike tools. A harder distractor set (many issue-trackers
named `create_issue`) would be a better stress test; we did not have Zed's.

## Approaches not reproduced

Zed said they tested 25 approaches. They did not publish the list. We ran
every class they named that can be done locally, plus codedb.

### Could not run

| Approach | Why |
|---|---|
| LLM tool router / LLM query rewrite | No API key in this environment; Zed's prompt and model unknown |
| Trained decision model (LightGBM / classifier) | No Zed training labels; a 20KB LightGBM was mentioned only in a reply, not by Zed |
| Cross-encoder reranker (ms-marco MiniLM, bge-reranker, Jev) | Not installed; would need a second model download and a candidate generator we do not know they used |
| API embedding (`text-embedding-3-small`, Voyage, Jina, …) | No provider key |
| Second local dense model (gte-small, nomic-embed) | Only `BAAI/bge-small-en-v1.5` via fastembed was run, to keep the one-command path small |
| Zed's exact weighted-BM25 binary | Weights and tokenizer unpublished |
| Orama / SQLite FTS5 / ripgrep-as-Zed-used-it | Implementation details unknown; we used in-process Python BM25/TF-IDF instead |

### Ran as stand-ins (not claimed to be Zed's)

| Our name | What it stands in for |
|---|---|
| `bm25_weighted` | Zed "weighted BM25 + normalization": identifier split, verb down-weight 0.25, field weights name 3.0 / server 2.2 / description 1.0 / params 0.45, +1.35 namespace boost if the query names the server |
| `decision_heuristic` | Decision model: identifier-shaped query → name match, else weighted BM25 |
| `query_rewrite_weighted_bm25` | LLM rewrite: a 6-entry synonym table |
| `lexical_rerank_weighted_top20` | Neural reranker: overlap rerank of the weighted-BM25 top 20 |
| `hashed_ngram_embed` | Extra local embedding if fastembed is missing (not a neural model) |
| `char_trigram` | In-process analog of codedb's trigram index |

## codedb primitives vs tool search

codedb is a **code-intelligence** engine. We indexed one Python file per
tool (`server__name.py` with a `def name(...):` and a docstring). That is
off-label.

| Primitive | What it did here | Why it is a poor fit for MCP tool search |
|---|---|---|
| `codedb_search` (multi-word → `searchContentRanked` BM25+) | **91.3% R@1** — competitive with plain BM25 | Ranking includes code-graph centrality / test-file priors that do nothing on a flat catalog |
| `codedb_trigram_tokens` | 60.7% R@1 | Single-token trigram path; fusing tokens loses phrase/product context |
| `codedb_word` | 67.3% R@1 | Exact identifier postings; NL queries are not identifiers |
| `codedb_symbol` | 30.7% R@1 | Looks up a guessed symbol; `create`/`issue` collide across servers |
| `codedb_find` | 48.7% R@1 | Fuzzy **filename** search, not content |

codedb already has identifier splitting and BM25+ (`explore.zig`
`searchContentRanked`). It does **not** have:

1. Fielded BM25 (name vs description vs params vs server)
2. Verb down-weighting
3. Namespace / server-alias boosts
4. A first-class "document is a tool" schema (MCP name, JSON-schema params)
5. A tool-search MCP surface (by design: codedb does not edit, and it is
   not a tool router)

### What codedb would need to win at tool search

If codedb wanted to be the thing Zed shipped:

1. **Index tools as structured docs**, not source files: `{server, name, description, params}`.
2. **Field weights + verb down-weight + ident split** — the three rules
   everyone (Zed tweet, StackOne, thread replies) agrees matter. codedb
   already splits identifiers for code; it does not down-weight `create`.
3. **Keep the trigram/word indexes** as a cheap first-stage or hybrid
   (RRF with BM25). On this set, `codedb_search` already matches plain
   BM25; `hybrid_codedb_weighted_bm25` is the headline winner (R@1 93.3%,
   tied with BM25+bge, **no model**).
4. **Do not route NL tool queries through `codedb_symbol` / `codedb_word`.**
   Those are the right tools for code, the wrong tools for "create a Jira
   ticket".
5. Optional: a small local embedding only as a hybrid, not a default.
   bge-small won some points here (+2 R@1 vs plain BM25) but the CI
   overlaps, it needs a model, and it is 15× slower than in-process BM25.

## Measurement caveats

- codedb query latency includes MCP JSON-RPC in a warm process (~10 ms
  p50 for `codedb_search`). In-process Python BM25 is ~0.14 ms. Do not
  compare those as algorithm time.
- `hybrid_codedb_*` p50 ≈ 0.01 ms is **RRF fusion only** on precomputed
  rankings, not end-to-end.
- `embed_bge_small` index time (~2 s) is first-build of 536 short docs
  after the ONNX weights were already cached.
- Bootstrap CIs (2000 resamples) on 150 queries: a 4–5 point R@1 gap is
  often inside the interval (`bm25_plain` 86–95%, `bm25_weighted` 79–91%).
- No Zed number can be confirmed or refuted from this run.

## Sources checked

- Tweet + photo + 50 replies (no official follow-up with numbers)
- https://zed.dev/blog (no MCP tool-search post as of 21 Oct 2026)
- https://delta.dev/blog (none)
- `zed-industries/zed` code search: BM25, tool_search, ToolSearch, 536
- StackOne's public BM25/TF-IDF write-up (different catalog; used only
  as a known 20/80 hybrid formula)
- FastMCP `BM25SearchTransform` (generic Okapi; not Zed)
- GitHub official MCP `AllTools` list and public MCP server schemas
