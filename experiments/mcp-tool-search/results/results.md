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
- Cross-encoder rerankers and API embedding models were not run unless those packages/keys are present.
- A second local dense model (gte/nomic) was not downloaded to keep the one-command path small.


Full gap list: [`GAPS.md`](GAPS.md).

## Raw outputs

Per-approach JSON/CSV lives in `results/`. Combined table:
`results/summary.json`.

