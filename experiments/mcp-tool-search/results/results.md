# MCP tool search — reproduction results

**This is a reproduction, not Zed's unpublished benchmark.** Zed's exact
queries, tools, labels, and 25-approach list are not public. See
[`GAPS.md`](GAPS.md).

## Headline

On this 150×536 public reproduction:

| Result | Number | Note |
|---|---|---|
| Best no-model ranker | `boolean_or` / `hybrid_rrf_bm25_trigram` / `bm25_plain` | R@1 94.7% / 92.0% / 90.7%. CIs overlap. |
| Zed-like weighted BM25 | **85.3% R@1** | Worse than plain BM25 here (CI overlap). Field/verb weights are our guess, not Zed's. |
| Best overall | `hybrid_rrf_bm25_embed` and `hybrid_codedb_weighted_bm25` | **93.3% R@1**, MRR@10 0.96. Embedding needs a model; the codedb hybrid does not. |
| **Embedding vs trigram** | bge-small **92.7%** vs char-trigram **85.3%** vs codedb-trigram **60.7%** | Dense wins R@1; CIs: embed 88–97%, trigram 79–91%. Embed is ~6× slower than in-process trigram. |
| **Where codedb ranks** | `codedb_search` **91.3% R@1** (3rd among shipped-like locals) | Word/symbol/find are the wrong primitive (30–67%). |
| Scaling 536→5k | BM25 and trigram **do not fall off** | Distractors are vendor-distinct; they do not recreate StackOne's lookalike-tool failure. |
| **Agent cost (k=5)** | cheapest **373 tok/q**, 1.01 calls | `hybrid_codedb_weighted_bm25`. All-schemas dump is **38,003** tok/turn (102×). |
| Cost vs recall rank | **different** (29/30 move) | `boolean_or` is #1 recall, #19 cost. Weighted first-page hits beat rank-1. |
| Live agent | **skipped** | No LLM key. `OPENAI_API_KEY=... python live_agent.py` |

Zed shipped weighted BM25 because it is fast, local, and good enough. On
*this* catalog that conclusion is supportable for **plain** BM25 (0.14 ms
p50, no model). Our guessed field weights did not beat plain BM25; that
is a gap in the reproduction, not a refutation of Zed.

codedb's own multi-word search (`searchContentRanked` BM25+) already
matches plain BM25 on this task. To *win* tool search it would need
fielded BM25 / verb down-weight / namespace boosts — see GAPS.md.

---

Zed posted on 20 Oct 2026 that they tested 25 approaches on 150 queries
against 536 tools and shipped weighted BM25 with a few normalization
rules ([tweet](https://x.com/zeddotdev/status/2112588120558338261)).
The tweet image is a meme (`fixtures/zed-tweet-2026-10-20.png`), not a
write-up. The Zed blog has no post. `zed-industries/zed` has no public
tool-search fixtures (only an unrelated edit-prediction BM25 retriever).

Catalog: 536 tools (366 public MCP names + 170 expanded), 51 servers,
150 hand-labelled queries. Frozen in `data/`.

Metrics are means over 150 queries with 2000-resample bootstrap 95% CIs.
Differences of a few points are usually noise. codedb latencies include
MCP RPC; `hybrid_codedb_*` p50 is RRF-fusion only.

<!-- COST_BEGIN -->
## Agent cost (search calls + tokens, not recall@k)

Recall@k is not the agent metric. An agent calls `search(query)`, gets
the top-k **full tool schemas** (name, description, inputSchema, as an
MCP `tools/list` / `search_tools` hit), and pages until the gold/alt
tool appears. Tokens are `tiktoken` **o200k_base** over the compact JSON
payload actually returned to the model.

Paging model: offset slices of the saved ranking.
Call *n* returns ranks `[(n-1)k : n k]`. Tools missing from the saved
top-10 are appended in catalog order (pessimistic tail).

**All-schemas baseline:** `38,003` o200k tokens
per turn to load all 536 tool schemas up front
(170,223 bytes). No search calls.

### Ranking by tokens burned per successful query (k=5)

Primary page size is 5 (FastMCP-style). Sorted by mean o200k tokens
returned until gold appears. **This ranking is not the recall@1 ranking.**
29 of 30 approaches change place. `boolean_or` wins recall@1 (94.7%)
and lands 19th on cost: its first page is fatter, and the rare miss
pages deep into the catalog tail. Methods that put gold in the first
page (even at rank 2–5) are cheaper even when they lose rank-1.

| Cost # | Recall # | Δ | Approach | R@1 | tok/success | mean calls | success@1 |
|---:|---:|---:|---|---:|---:|---:|---:|
| 1 | 3 | +2 | hybrid_codedb_weighted_bm25 | 93.3% | 372.8 | 1.01 | 99.3% |
| 2 | 14 | +12 | hybrid_rrf_weighted_trigram | 86.0% | 376.5 | 1.01 | 99.3% |
| 3 | 13 | +10 | hybrid_rrf_weighted_hashed | 86.0% | 379.0 | 1.01 | 99.3% |
| 4 | 12 | +8 | lexical_rerank_weighted_top20 | 88.0% | 380.4 | 1.01 | 98.7% |
| 5 | 18 | +13 | hashed_ngram_embed | 84.0% | 380.9 | 1.01 | 99.3% |
| 6 | 15 | +9 | bm25_weighted | 85.3% | 382.8 | 1.02 | 98.7% |
| 7 | 17 | +10 | decision_heuristic | 85.3% | 382.8 | 1.02 | 98.7% |
| 8 | 25 | +17 | hybrid_codedb_trigram_bm25 | 70.7% | 384.9 | 1.05 | 95.3% |
| 9 | 10 | +1 | hybrid_rrf_trigram_embed | 90.0% | 388.1 | 1.05 | 99.3% |
| 10 | 4 | -6 | hybrid_rrf_bm25_embed | 93.3% | 389.6 | 1.05 | 99.3% |
| 11 | 2 | -9 | hybrid_codedb_embed | 93.3% | 393.0 | 1.05 | 99.3% |
| 12 | 5 | -7 | embed_bge_small | 92.7% | 393.7 | 1.05 | 99.3% |
| 13 | 11 | -2 | hybrid_rrf_weighted_embed | 88.7% | 397.3 | 1.05 | 99.3% |
| 14 | 19 | +5 | query_rewrite_weighted_bm25 | 83.3% | 398.8 | 1.05 | 97.3% |
| 15 | 6 | -9 | hybrid_rrf_bm25_trigram | 92.0% | 446.9 | 1.20 | 98.7% |
| 16 | 23 | +7 | tfidf | 80.0% | 449.4 | 1.19 | 98.7% |
| 17 | 22 | +5 | bm25_tfidf_hybrid | 82.0% | 450.0 | 1.19 | 98.7% |
| 18 | 8 | -10 | bm25_ident_split | 90.7% | 452.4 | 1.20 | 98.7% |
| 19 | 1 | -18 | boolean_or | 94.7% | 464.9 | 1.11 | 99.3% |
| 20 | 9 | -11 | bm25_plain | 90.7% | 465.3 | 1.23 | 98.0% |
| 21 | 16 | -5 | char_trigram | 85.3% | 503.1 | 1.32 | 98.0% |
| 22 | 7 | -15 | codedb_search | 91.3% | 529.3 | 1.37 | 96.7% |
| 23 | 20 | -3 | bm25_desc_only | 82.7% | 597.3 | 1.52 | 96.0% |
| 24 | 26 | +2 | codedb_word | 67.3% | 748.4 | 1.87 | 91.3% |
| 25 | 21 | -4 | bm25_name_only | 82.0% | 1036.0 | 2.63 | 92.7% |
| 26 | 27 | +1 | codedb_trigram_tokens | 60.7% | 1088.8 | 2.78 | 85.3% |
| 27 | 24 | -3 | boolean_and | 76.7% | 2707.6 | 6.79 | 77.3% |
| 28 | 29 | +1 | codedb_symbol | 30.7% | 3668.0 | 9.29 | 61.3% |
| 29 | 28 | -1 | codedb_find | 48.7% | 6801.5 | 17.26 | 50.7% |
| 30 | 30 | +0 | name_exact_substr | 0.0% | 14978.9 | 38.48 | 0.7% |

Cheapest: **hybrid_codedb_weighted_bm25** at 373 tokens/query (37,630 less than the all-schemas dump, 99.0% saved). Mean search calls 1.01, first-page hit 99.3%.

Mean tokens can exceed p95: a few deep-tail misses pull the mean up
while 95% of queries finish in one page.

### Offline cost, k=3

| Approach | mean calls | p95 calls | ≤1 | ≤2 | ≤3 | mean tok | p95 tok | total tok |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| hybrid_codedb_weighted_bm25 | 1.01 | 1.0 | 98.7% | 100.0% | 100.0% | 236 | 337 | 35,445 |
| hybrid_rrf_weighted_trigram | 1.02 | 1.0 | 98.7% | 99.3% | 100.0% | 237 | 333 | 35,500 |
| hybrid_rrf_weighted_hashed | 1.01 | 1.0 | 98.7% | 100.0% | 100.0% | 239 | 325 | 35,885 |
| lexical_rerank_weighted_top20 | 1.03 | 1.0 | 97.3% | 100.0% | 100.0% | 241 | 373 | 36,149 |
| hashed_ngram_embed | 1.03 | 1.0 | 96.7% | 100.0% | 100.0% | 241 | 340 | 36,135 |
| bm25_weighted | 1.04 | 1.0 | 97.3% | 99.3% | 99.3% | 243 | 350 | 36,435 |
| decision_heuristic | 1.04 | 1.0 | 97.3% | 99.3% | 99.3% | 243 | 350 | 36,435 |
| hybrid_codedb_trigram_bm25 | 1.16 | 2.0 | 90.0% | 95.3% | 98.7% | 268 | 577 | 40,240 |
| hybrid_rrf_trigram_embed | 1.10 | 1.0 | 97.3% | 99.3% | 99.3% | 254 | 329 | 38,082 |
| hybrid_rrf_bm25_embed | 1.09 | 1.0 | 98.7% | 99.3% | 99.3% | 251 | 322 | 37,621 |
| hybrid_codedb_embed | 1.09 | 1.0 | 98.7% | 99.3% | 99.3% | 253 | 346 | 37,948 |
| embed_bge_small | 1.08 | 1.0 | 99.3% | 99.3% | 99.3% | 253 | 316 | 38,022 |
| hybrid_rrf_weighted_embed | 1.08 | 1.0 | 99.3% | 99.3% | 99.3% | 255 | 318 | 38,304 |
| query_rewrite_weighted_bm25 | 1.11 | 1.0 | 95.3% | 98.7% | 99.3% | 261 | 389 | 39,171 |
| hybrid_rrf_bm25_trigram | 1.34 | 1.0 | 98.0% | 98.7% | 99.3% | 314 | 333 | 47,157 |
| tfidf | 1.35 | 1.0 | 97.3% | 98.7% | 99.3% | 319 | 315 | 47,779 |
| bm25_tfidf_hybrid | 1.35 | 1.0 | 97.3% | 98.7% | 99.3% | 319 | 337 | 47,789 |
| bm25_ident_split | 1.34 | 1.0 | 98.0% | 98.7% | 99.3% | 316 | 333 | 47,382 |
| boolean_or | 1.20 | 1.0 | 98.0% | 99.3% | 99.3% | 309 | 393 | 46,369 |
| bm25_plain | 1.40 | 1.0 | 97.3% | 98.0% | 98.7% | 332 | 324 | 49,733 |
| char_trigram | 1.54 | 1.0 | 96.7% | 98.7% | 98.7% | 368 | 330 | 55,230 |
| codedb_search | 1.63 | 1.0 | 96.0% | 97.3% | 97.3% | 400 | 353 | 59,945 |
| bm25_desc_only | 1.90 | 2.0 | 92.7% | 96.7% | 97.3% | 467 | 441 | 70,036 |
| codedb_word | 2.51 | 3.0 | 87.3% | 93.3% | 96.7% | 622 | 668 | 93,371 |
| bm25_name_only | 3.77 | 3.5 | 90.0% | 94.0% | 94.7% | 924 | 976 | 138,610 |
| codedb_trigram_tokens | 4.06 | 30.1 | 80.7% | 87.3% | 90.7% | 1007 | 8227 | 151,069 |
| boolean_and | 10.73 | 59.7 | 77.3% | 77.3% | 77.3% | 2656 | 14505 | 398,471 |
| codedb_symbol | 15.01 | 85.6 | 53.3% | 62.0% | 70.0% | 3683 | 20396 | 552,471 |
| codedb_find | 28.31 | 101.2 | 50.7% | 50.7% | 51.3% | 6935 | 24073 | 1,040,178 |
| name_exact_substr | 63.75 | 116.5 | 0.7% | 0.7% | 1.3% | 15419 | 27302 | 2,312,788 |

### Offline cost, k=5

| Approach | mean calls | p95 calls | ≤1 | ≤2 | ≤3 | mean tok | p95 tok | total tok |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| hybrid_codedb_weighted_bm25 | 1.01 | 1.0 | 99.3% | 100.0% | 100.0% | 373 | 523 | 55,917 |
| hybrid_rrf_weighted_trigram | 1.01 | 1.0 | 99.3% | 100.0% | 100.0% | 377 | 517 | 56,478 |
| hybrid_rrf_weighted_hashed | 1.01 | 1.0 | 99.3% | 100.0% | 100.0% | 379 | 511 | 56,851 |
| lexical_rerank_weighted_top20 | 1.01 | 1.0 | 98.7% | 100.0% | 100.0% | 380 | 511 | 57,062 |
| hashed_ngram_embed | 1.01 | 1.0 | 99.3% | 100.0% | 100.0% | 381 | 509 | 57,132 |
| bm25_weighted | 1.02 | 1.0 | 98.7% | 99.3% | 100.0% | 383 | 521 | 57,427 |
| decision_heuristic | 1.02 | 1.0 | 98.7% | 99.3% | 100.0% | 383 | 521 | 57,427 |
| hybrid_codedb_trigram_bm25 | 1.05 | 1.0 | 95.3% | 99.3% | 100.0% | 385 | 587 | 57,741 |
| hybrid_rrf_trigram_embed | 1.05 | 1.0 | 99.3% | 99.3% | 99.3% | 388 | 489 | 58,209 |
| hybrid_rrf_bm25_embed | 1.05 | 1.0 | 99.3% | 99.3% | 99.3% | 390 | 536 | 58,441 |
| hybrid_codedb_embed | 1.05 | 1.0 | 99.3% | 99.3% | 99.3% | 393 | 538 | 58,957 |
| embed_bge_small | 1.05 | 1.0 | 99.3% | 99.3% | 99.3% | 394 | 507 | 59,055 |
| hybrid_rrf_weighted_embed | 1.05 | 1.0 | 99.3% | 99.3% | 99.3% | 397 | 492 | 59,589 |
| query_rewrite_weighted_bm25 | 1.05 | 1.0 | 97.3% | 99.3% | 99.3% | 399 | 566 | 59,822 |
| hybrid_rrf_bm25_trigram | 1.20 | 1.0 | 98.7% | 99.3% | 99.3% | 447 | 518 | 67,039 |
| tfidf | 1.19 | 1.0 | 98.7% | 99.3% | 99.3% | 449 | 471 | 67,404 |
| bm25_tfidf_hybrid | 1.19 | 1.0 | 98.7% | 99.3% | 99.3% | 450 | 486 | 67,506 |
| bm25_ident_split | 1.20 | 1.0 | 98.7% | 99.3% | 99.3% | 452 | 515 | 67,853 |
| boolean_or | 1.11 | 1.0 | 99.3% | 99.3% | 99.3% | 465 | 601 | 69,734 |
| bm25_plain | 1.23 | 1.0 | 98.0% | 98.7% | 98.7% | 465 | 478 | 69,795 |
| char_trigram | 1.32 | 1.0 | 98.0% | 98.7% | 98.7% | 503 | 501 | 75,462 |
| codedb_search | 1.37 | 1.0 | 96.7% | 97.3% | 97.3% | 529 | 573 | 79,401 |
| bm25_desc_only | 1.52 | 1.0 | 96.0% | 97.3% | 97.3% | 597 | 598 | 89,594 |
| codedb_word | 1.87 | 2.0 | 91.3% | 96.7% | 96.7% | 748 | 839 | 112,253 |
| bm25_name_only | 2.63 | 2.5 | 92.7% | 94.7% | 95.3% | 1036 | 1115 | 155,394 |
| codedb_trigram_tokens | 2.78 | 18.5 | 85.3% | 92.7% | 92.7% | 1089 | 8117 | 163,319 |
| boolean_and | 6.79 | 35.6 | 77.3% | 77.3% | 77.3% | 2708 | 13944 | 406,143 |
| codedb_symbol | 9.29 | 52.1 | 61.3% | 72.7% | 73.3% | 3668 | 20001 | 550,193 |
| codedb_find | 17.26 | 61.1 | 50.7% | 52.0% | 52.0% | 6801 | 23343 | 1,020,221 |
| name_exact_substr | 38.48 | 70.0 | 0.7% | 1.3% | 2.0% | 14979 | 26505 | 2,246,838 |

### Offline cost, k=10

| Approach | mean calls | p95 calls | ≤1 | ≤2 | ≤3 | mean tok | p95 tok | total tok |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| hybrid_codedb_weighted_bm25 | 1.00 | 1.0 | 100.0% | 100.0% | 100.0% | 705 | 946 | 105,777 |
| hybrid_rrf_weighted_trigram | 1.00 | 1.0 | 100.0% | 100.0% | 100.0% | 741 | 1001 | 111,088 |
| hybrid_rrf_weighted_hashed | 1.00 | 1.0 | 100.0% | 100.0% | 100.0% | 755 | 1008 | 113,236 |
| lexical_rerank_weighted_top20 | 1.00 | 1.0 | 100.0% | 100.0% | 100.0% | 731 | 960 | 109,649 |
| hashed_ngram_embed | 1.00 | 1.0 | 100.0% | 100.0% | 100.0% | 756 | 942 | 113,413 |
| bm25_weighted | 1.01 | 1.0 | 99.3% | 100.0% | 100.0% | 733 | 953 | 110,019 |
| decision_heuristic | 1.01 | 1.0 | 99.3% | 100.0% | 100.0% | 733 | 953 | 110,019 |
| hybrid_codedb_trigram_bm25 | 1.01 | 1.0 | 99.3% | 100.0% | 100.0% | 716 | 947 | 107,331 |
| hybrid_rrf_trigram_embed | 1.02 | 1.0 | 99.3% | 99.3% | 99.3% | 745 | 970 | 111,823 |
| hybrid_rrf_bm25_embed | 1.02 | 1.0 | 99.3% | 99.3% | 99.3% | 737 | 996 | 110,507 |
| hybrid_codedb_embed | 1.02 | 1.0 | 99.3% | 99.3% | 99.3% | 729 | 979 | 109,423 |
| embed_bge_small | 1.02 | 1.0 | 99.3% | 99.3% | 99.3% | 751 | 979 | 112,672 |
| hybrid_rrf_weighted_embed | 1.02 | 1.0 | 99.3% | 99.3% | 99.3% | 759 | 1008 | 113,793 |
| query_rewrite_weighted_bm25 | 1.01 | 1.0 | 99.3% | 99.3% | 100.0% | 750 | 988 | 112,464 |
| hybrid_rrf_bm25_trigram | 1.09 | 1.0 | 99.3% | 99.3% | 99.3% | 784 | 985 | 117,622 |
| tfidf | 1.09 | 1.0 | 99.3% | 99.3% | 99.3% | 813 | 954 | 121,949 |
| bm25_tfidf_hybrid | 1.09 | 1.0 | 99.3% | 99.3% | 99.3% | 812 | 962 | 121,875 |
| bm25_ident_split | 1.09 | 1.0 | 99.3% | 99.3% | 99.3% | 795 | 1001 | 119,308 |
| boolean_or | 1.05 | 1.0 | 99.3% | 99.3% | 99.3% | 876 | 1188 | 131,331 |
| bm25_plain | 1.11 | 1.0 | 98.7% | 98.7% | 99.3% | 804 | 989 | 120,565 |
| char_trigram | 1.15 | 1.0 | 98.7% | 98.7% | 98.7% | 851 | 994 | 127,618 |
| codedb_search | 1.17 | 1.0 | 97.3% | 97.3% | 98.7% | 844 | 1107 | 126,604 |
| bm25_desc_only | 1.24 | 1.0 | 97.3% | 97.3% | 97.3% | 932 | 1045 | 139,870 |
| codedb_word | 1.40 | 1.0 | 96.7% | 96.7% | 97.3% | 1084 | 1101 | 162,574 |
| bm25_name_only | 1.79 | 1.5 | 94.7% | 95.3% | 95.3% | 1366 | 1302 | 204,854 |
| codedb_trigram_tokens | 1.84 | 9.5 | 92.7% | 92.7% | 92.7% | 1371 | 8033 | 205,675 |
| boolean_and | 3.84 | 18.1 | 77.3% | 78.0% | 78.0% | 3004 | 13725 | 450,537 |
| codedb_symbol | 5.03 | 26.5 | 72.7% | 73.3% | 74.0% | 3851 | 19869 | 577,646 |
| codedb_find | 9.01 | 30.5 | 52.0% | 52.7% | 53.3% | 6907 | 22689 | 1,036,085 |
| name_exact_substr | 19.49 | 35.0 | 1.3% | 4.0% | 7.3% | 14759 | 25789 | 2,213,858 |

### Live agent loop

Skipped in this environment: no LLM API key
(`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `AZURE_OPENAI_API_KEY`,
`GOOGLE_API_KEY`, `GEMINI_API_KEY`, `COHERE_API_KEY`, `TOGETHER_API_KEY`,
`GROQ_API_KEY`, `MISTRAL_API_KEY`, `OPENROUTER_API_KEY`).

Harness is ready:

```bash
OPENAI_API_KEY=... python live_agent.py
# or
ANTHROPIC_API_KEY=... python live_agent.py
```

Default approaches: `bm25_plain`, `bm25_weighted`, `embed_bge_small`,
`hybrid_rrf_bm25_embed`, `codedb_search`, `char_trigram`. Records real
search-call counts, API input/output tokens, whether the named tool is
gold/alt, and wall time. Writes `results/live_agent.json`.

Raw cost outputs: `results/cost.json`, `results/cost.csv`,
`results/cost_per_query.json`, `results/cost_per_query.csv`.
Per-approach JSON/CSV now include `hit_rank` and `k{3,5,10}_*` fields.
<!-- COST_END -->

## Headline table (n=536 tools, 150 queries)

| Approach | R@1 | R@3 | R@5 | MRR@10 | nDCG@10 | p50 ms | p95 ms | index s | model/API |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---|
| name_exact_substr | 0.0% | 0.0% | 0.0% | 0.000 | 0.000 | 0.31 | 0.36 | 0.000 | local |
| boolean_and | 76.7% | 77.3% | 77.3% | 0.770 | 0.767 | 0.24 | 0.28 | 0.000 | local |
| boolean_or | 94.7% | 98.0% | 99.3% | 0.964 | 0.959 | 0.30 | 0.37 | 0.000 | local |
| bm25_plain | 90.7% | 97.3% | 98.0% | 0.940 | 0.948 | 0.14 | 0.23 | 0.001 | local |
| bm25_ident_split | 90.7% | 98.0% | 98.7% | 0.942 | 0.952 | 0.14 | 0.26 | 0.001 | local |
| bm25_name_only | 82.0% | 90.0% | 92.7% | 0.870 | 0.882 | 0.10 | 0.14 | 0.001 | local |
| bm25_desc_only | 82.7% | 92.7% | 96.0% | 0.881 | 0.900 | 0.14 | 0.25 | 0.001 | local |
| bm25_weighted | 85.3% | 97.3% | 98.7% | 0.911 | 0.923 | 0.40 | 0.65 | 0.003 | local |
| tfidf | 80.0% | 97.3% | 98.7% | 0.880 | 0.902 | 0.17 | 0.28 | 0.001 | local |
| bm25_tfidf_hybrid | 82.0% | 97.3% | 98.7% | 0.892 | 0.913 | 0.38 | 0.65 | 0.002 | local |
| char_trigram | 85.3% | 96.7% | 98.0% | 0.912 | 0.926 | 0.35 | 0.47 | 0.005 | local |
| hashed_ngram_embed | 84.0% | 96.7% | 99.3% | 0.909 | 0.921 | 4.20 | 4.38 | 0.021 | local |
| hybrid_rrf_bm25_trigram | 92.0% | 98.0% | 98.7% | 0.949 | 0.956 | 0.55 | 0.79 | 0.006 | local |
| hybrid_rrf_weighted_trigram | 86.0% | 98.7% | 99.3% | 0.922 | 0.936 | 0.84 | 1.21 | 0.008 | local |
| hybrid_rrf_weighted_hashed | 86.0% | 98.7% | 99.3% | 0.924 | 0.936 | 4.69 | 4.95 | 0.024 | local |
| decision_heuristic | 85.3% | 97.3% | 98.7% | 0.911 | 0.923 | 0.81 | 1.07 | 0.003 | local |
| query_rewrite_weighted_bm25 | 83.3% | 95.3% | 97.3% | 0.895 | 0.913 | 0.40 | 0.56 | 0.003 | local |
| lexical_rerank_weighted_top20 | 88.0% | 97.3% | 98.7% | 0.929 | 0.940 | 0.58 | 0.82 | 0.003 | local |
| embed_bge_small | 92.7% | 99.3% | 99.3% | 0.957 | 0.960 | 2.14 | 2.64 | 1.960 | model |
| hybrid_rrf_bm25_embed | 93.3% | 98.7% | 99.3% | 0.959 | 0.967 | 2.39 | 3.31 | 1.961 | model |
| hybrid_rrf_weighted_embed | 88.7% | 99.3% | 99.3% | 0.938 | 0.950 | 2.68 | 3.20 | 1.963 | model |
| hybrid_rrf_trigram_embed | 90.0% | 97.3% | 99.3% | 0.940 | 0.950 | 2.59 | 3.03 | 1.965 | model |
| codedb_search | 91.3% | 96.0% | 96.7% | 0.938 | 0.943 | 10.28 | 10.41 | 0.442 | local |
| codedb_trigram_tokens | 60.7% | 80.7% | 85.3% | 0.718 | 0.759 | 30.78 | 41.26 | 0.442 | local |
| codedb_word | 67.3% | 87.3% | 91.3% | 0.783 | 0.819 | 30.81 | 32.20 | 0.442 | local |
| codedb_symbol | 30.7% | 53.3% | 61.3% | 0.432 | 0.497 | 20.62 | 20.85 | 0.442 | local |
| codedb_find | 48.7% | 50.7% | 50.7% | 0.495 | 0.494 | 10.25 | 10.37 | 0.442 | local |
| hybrid_codedb_weighted_bm25 | 93.3% | 98.7% | 99.3% | 0.960 | 0.965 | 0.01 | 0.02 | 0.445 | local |
| hybrid_codedb_trigram_bm25 | 70.7% | 90.0% | 95.3% | 0.809 | 0.845 | 0.01 | 0.01 | 0.445 | local |
| hybrid_codedb_embed | 93.3% | 98.7% | 99.3% | 0.959 | 0.966 | 0.01 | 0.01 | 2.401 | model |

### Bootstrap 95% CIs for Recall@1 / MRR@10

| Approach | Recall@1 | MRR@10 |
|---|---|---|
| name_exact_substr | 0.0% [0.0%, 0.0%] | 0.000 [0.000, 0.000] |
| boolean_and | 76.7% [70.0%, 83.3%] | 0.770 [0.703, 0.840] |
| boolean_or | 94.7% [90.7%, 98.0%] | 0.964 [0.937, 0.987] |
| bm25_plain | 90.7% [86.0%, 95.3%] | 0.940 [0.907, 0.971] |
| bm25_ident_split | 90.7% [86.0%, 95.3%] | 0.942 [0.910, 0.971] |
| bm25_name_only | 82.0% [75.3%, 88.0%] | 0.870 [0.822, 0.916] |
| bm25_desc_only | 82.7% [76.0%, 88.7%] | 0.881 [0.836, 0.922] |
| bm25_weighted | 85.3% [79.3%, 90.7%] | 0.911 [0.874, 0.946] |
| tfidf | 80.0% [73.3%, 86.0%] | 0.880 [0.840, 0.917] |
| bm25_tfidf_hybrid | 82.0% [76.0%, 88.0%] | 0.892 [0.854, 0.927] |
| char_trigram | 85.3% [79.3%, 90.7%] | 0.912 [0.877, 0.946] |
| hashed_ngram_embed | 84.0% [78.0%, 90.0%] | 0.909 [0.874, 0.942] |
| hybrid_rrf_bm25_trigram | 92.0% [87.3%, 96.0%] | 0.949 [0.919, 0.977] |
| hybrid_rrf_weighted_trigram | 86.0% [80.7%, 91.3%] | 0.922 [0.889, 0.953] |
| hybrid_rrf_weighted_hashed | 86.0% [80.0%, 91.3%] | 0.924 [0.893, 0.953] |
| decision_heuristic | 85.3% [79.3%, 90.7%] | 0.911 [0.874, 0.946] |
| query_rewrite_weighted_bm25 | 83.3% [77.3%, 89.3%] | 0.895 [0.855, 0.933] |
| lexical_rerank_weighted_top20 | 88.0% [82.7%, 93.3%] | 0.929 [0.897, 0.960] |
| embed_bge_small | 92.7% [88.0%, 96.7%] | 0.957 [0.929, 0.980] |
| hybrid_rrf_bm25_embed | 93.3% [89.3%, 97.3%] | 0.959 [0.933, 0.983] |
| hybrid_rrf_weighted_embed | 88.7% [83.3%, 93.3%] | 0.938 [0.908, 0.966] |
| hybrid_rrf_trigram_embed | 90.0% [85.3%, 94.7%] | 0.940 [0.908, 0.968] |
| codedb_search | 91.3% [86.7%, 96.0%] | 0.938 [0.901, 0.970] |
| codedb_trigram_tokens | 60.7% [52.7%, 68.7%] | 0.718 [0.658, 0.778] |
| codedb_word | 67.3% [59.3%, 74.7%] | 0.783 [0.728, 0.835] |
| codedb_symbol | 30.7% [24.0%, 38.0%] | 0.432 [0.370, 0.497] |
| codedb_find | 48.7% [40.0%, 56.7%] | 0.495 [0.413, 0.577] |
| hybrid_codedb_weighted_bm25 | 93.3% [89.3%, 97.3%] | 0.960 [0.935, 0.983] |
| hybrid_codedb_trigram_bm25 | 70.7% [63.3%, 78.0%] | 0.809 [0.761, 0.857] |
| hybrid_codedb_embed | 93.3% [89.3%, 97.3%] | 0.959 [0.932, 0.983] |

## Embedding vs trigram (same queries)

Head-to-head on the 150-query / 536-tool set. `char_trigram` is an
in-process character-trigram cosine (codedb-like). `codedb_trigram_tokens`
is codedb's real trigram path (one search per token). Dense embedding is
`embed_bge_small` when fastembed is available, else hashed n-grams.

| Approach | R@1 | R@3 | MRR@10 | nDCG@10 | p50 ms |
|---|---:|---:|---:|---:|---:|
| char_trigram | 85.3% | 96.7% | 0.912 | 0.926 | 0.35 |
| codedb_trigram_tokens | 60.7% | 80.7% | 0.718 | 0.759 | 30.78 |
| embed_bge_small | 92.7% | 99.3% | 0.957 | 0.960 | 2.14 |
| hashed_ngram_embed | 84.0% | 96.7% | 0.909 | 0.921 | 4.20 |
| hybrid_rrf_trigram_embed | 90.0% | 97.3% | 0.940 | 0.950 | 2.59 |
| hybrid_rrf_bm25_trigram | 92.0% | 98.0% | 0.949 | 0.956 | 0.55 |
| hybrid_rrf_weighted_embed | 88.7% | 99.3% | 0.938 | 0.950 | 2.68 |

## Where codedb ranks

codedb is a **code-intelligence** engine. Here it is asked to retrieve
MCP tools from a synthetic catalog (one Python file per tool). That is
off-label: no field weights, no verb down-weighting, ranking is for source
files (centrality / call-graph) rather than tool metadata.

Best codedb-family method by MRR@10: **hybrid_codedb_weighted_bm25** (0.960).

## Scaling (536 → ~2k → ~5k tools)

Gold tools stay fixed; distractors reuse the same create/get/list verbs.

| n tools | Approach | R@1 | R@5 | MRR@10 | p50 ms |
|---:|---|---:|---:|---:|---:|
| 536 | bm25_plain | 90.7% | 98.0% | 0.940 | 0.14 |
| 536 | bm25_weighted | 85.3% | 98.7% | 0.911 | 0.40 |
| 536 | tfidf | 80.0% | 98.7% | 0.880 | 0.16 |
| 536 | char_trigram | 85.3% | 98.0% | 0.912 | 0.35 |
| 536 | hybrid_rrf_weighted_trigram | 86.0% | 99.3% | 0.922 | 0.84 |
| 2000 | bm25_plain | 92.0% | 98.0% | 0.945 | 0.48 |
| 2000 | bm25_weighted | 84.0% | 99.3% | 0.899 | 1.43 |
| 2000 | tfidf | 79.3% | 96.7% | 0.868 | 0.61 |
| 2000 | char_trigram | 85.3% | 97.3% | 0.912 | 1.33 |
| 2000 | hybrid_rrf_weighted_trigram | 86.7% | 99.3% | 0.924 | 2.74 |
| 5000 | bm25_plain | 92.0% | 98.0% | 0.944 | 1.28 |
| 5000 | bm25_weighted | 83.3% | 97.3% | 0.887 | 3.42 |
| 5000 | tfidf | 78.0% | 96.7% | 0.854 | 1.51 |
| 5000 | char_trigram | 85.3% | 97.3% | 0.912 | 3.39 |
| 5000 | hybrid_rrf_weighted_trigram | 86.7% | 98.7% | 0.922 | 6.68 |

## Approaches we could not run

- Zed's exact 25-approach list, queries, tools, labels, field weights, and BM25 parameters are not public.
- LLM routing and trained decision models (LightGBM etc.) were not run: no API key / no labelled train split from Zed.
- Live agent loop was not run: no LLM API key. Harness is `python live_agent.py`.
- Cross-encoder rerankers and API embedding models were not run unless those packages/keys are present.
- A second local dense model (gte/nomic) was not downloaded to keep the one-command path small.


Full gap list: [`GAPS.md`](GAPS.md).

## Raw outputs

Per-approach JSON/CSV lives in `results/` (now includes `hit_rank` and
`k{3,5,10}_*` cost fields). Combined recall table: `results/summary.json`.
Cost tables: `results/cost.json`, `results/cost.csv`,
`results/cost_per_query.json`. Live skip/run: `results/live_agent.json`.

