# search-shootout — regex

**Date:** 2026-05-21 10:27
**Corpus:** `/Users/blackfloofie/codedb-bench/regex`
**Indexed files:** 285
**Corpus bytes:** 5.9 MB
**Iterations:** 20 warm

## Build phase

| Backend | Cold index time | On-disk size |
|---|---|---|
| fts5_trigram | 0.54s | 20.3 MB |
| fts5_unicode61 | 0.12s | 7.8 MB |
| codedb | 0.15s | 13.5 MB |
| lean-ctx | 8.17s | — |
| codegraph | 2.56s | 17.6 MB |

## Query latency (warm, ms)

> codedb: MCP stdio (one server, many calls).
> fts5_*: persistent SQLite connection.
> lean-ctx: per-call CLI spawn (includes ~700ms binary startup).
> Hit counts are NOT directly comparable across backends — use them as recall sanity (zero vs non-zero).

| query | kind | fts5_tri p50 | fts5_tri p99 | fts5_tri hits | fts5_uni p50 | fts5_uni p99 | fts5_uni hits | codedb p50 | codedb p99 | codedb hits | leanctx p50 | leanctx p99 | leanctx hits | codegraph p50 | codegraph p99 | codegraph hits |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `useState` | common-identifier | 0.17 | 0.23 | 0 | 0.00 | 0.01 | 0 | 1.87 | 16.57 | 0 | 449.84 | 499.80 | 1 | 1.78 | 2.81 | 0 |
| `useEffect` | common-identifier | 0.04 | 0.05 | 0 | 0.00 | 0.01 | 0 | 0.05 | 0.09 | 0 | 447.89 | 453.75 | 1 | 1.62 | 1.95 | 0 |
| `forwardRef` | camelcase-identifier | 0.05 | 0.06 | 0 | 0.00 | 0.01 | 0 | 0.04 | 0.06 | 0 | 448.38 | 459.98 | 1 | 1.64 | 1.93 | 0 |
| `createElement` | camelcase-identifier | 0.08 | 0.09 | 0 | 0.00 | 0.01 | 0 | 0.04 | 0.07 | 0 | 447.22 | 463.45 | 1 | 1.74 | 2.08 | 0 |
| `Fiber` | substring-identifier | 0.01 | 0.01 | 0 | 0.00 | 0.01 | 0 | 0.04 | 0.07 | 0 | 449.86 | 493.24 | 1 | 1.96 | 2.45 | 11 |
| `Lane` | substring-identifier | 0.01 | 0.03 | 3 | 0.00 | 0.01 | 0 | 0.07 | 0.14 | 4 | 445.58 | 457.24 | 1 | 1.89 | 2.25 | 2 |
| `Suspense` | substring-identifier | 0.04 | 0.05 | 0 | 0.00 | 0.01 | 0 | 2.82 | 3.08 | 0 | 444.82 | 468.38 | 1 | 1.68 | 1.99 | 0 |
| `flushPassiveEffects` | rare-camelcase | 0.06 | 0.07 | 0 | 0.00 | 0.01 | 0 | 0.04 | 0.10 | 0 | 444.97 | 471.07 | 1 | 1.59 | 1.80 | 0 |
| `enableTransitionTracing` | rare-flag | 0.16 | 0.19 | 0 | 0.00 | 0.01 | 0 | 0.04 | 0.10 | 0 | 441.13 | 456.66 | 1 | 1.76 | 2.00 | 0 |
| `scheduleCallback` | camelcase-identifier | 0.09 | 0.10 | 0 | 0.00 | 0.01 | 0 | 0.05 | 0.07 | 0 | 443.44 | 449.59 | 1 | 1.85 | 2.28 | 0 |
| `concurrent` | lowercase-word | 0.05 | 0.06 | 2 | 0.00 | 0.01 | 1 | 0.05 | 0.10 | 4 | 448.29 | 472.74 | 3 | 0.33 | 0.46 | 1 |
| `function` | lang-keyword | 0.07 | 0.10 | 65 | 0.00 | 0.01 | 51 | 0.12 | 0.19 | 20 | 429.55 | 435.06 | 20 | 2.09 | 2.59 | 185 |
| `set` | short-trigram-exact | 0.01 | 0.02 | 154 | 0.01 | 0.01 | 127 | 0.13 | 0.23 | 20 | 430.41 | 438.46 | 20 | 2.34 | 3.06 | 115 |
| `ReactDOMRoot` | rare-camelcase | 0.05 | 0.07 | 0 | 0.00 | 0.01 | 0 | 0.06 | 0.13 | 0 | 465.57 | 526.76 | 1 | 1.71 | 1.90 | 0 |
| `xyzzy_react_does_not_exist` | negative | 0.13 | 0.15 | 0 | 0.00 | 0.01 | 0 | 0.04 | 0.08 | 0 | 470.83 | 479.19 | 1 | 1.49 | 1.82 | 0 |

