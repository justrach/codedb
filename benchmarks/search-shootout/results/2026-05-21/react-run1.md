# search-shootout — react

**Date:** 2026-05-21 10:21
**Corpus:** `/Users/blackfloofie/codedb-bench/react`
**Indexed files:** 6,620
**Corpus bytes:** 26.5 MB
**Iterations:** 20 warm

## Build phase

| Backend | Cold index time | On-disk size |
|---|---|---|
| fts5_trigram | 2.06s | 93.5 MB |
| fts5_unicode61 | 0.44s | 36.3 MB |
| codedb | 1.18s | 69.5 MB |
| lean-ctx | 8.25s | — |
| codegraph | 15.12s | 195.5 MB |

## Query latency (warm, ms)

> codedb: MCP stdio (one server, many calls).
> fts5_*: persistent SQLite connection.
> lean-ctx: per-call CLI spawn (includes ~700ms binary startup).
> Hit counts are NOT directly comparable across backends — use them as recall sanity (zero vs non-zero).

| query | kind | fts5_tri p50 | fts5_tri p99 | fts5_tri hits | fts5_uni p50 | fts5_uni p99 | fts5_uni hits | codedb p50 | codedb p99 | codedb hits | leanctx p50 | leanctx p99 | leanctx hits | codegraph p50 | codegraph p99 | codegraph hits |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `useState` | common-identifier | 0.88 | 1.03 | 674 | 0.02 | 0.02 | 674 | 1.85 | 2.02 | 20 | 470.90 | 491.82 | 20 | 2.42 | 3.34 | 65 |
| `useEffect` | common-identifier | 0.40 | 0.44 | 434 | 0.01 | 0.02 | 426 | 1.02 | 1.19 | 20 | 464.99 | 485.16 | 20 | 5.89 | 6.72 | 101 |
| `forwardRef` | camelcase-identifier | 0.18 | 0.21 | 129 | 0.01 | 0.01 | 127 | 0.25 | 0.32 | 20 | 468.88 | 486.10 | 20 | 2.16 | 3.11 | 55 |
| `createElement` | camelcase-identifier | 1.02 | 1.08 | 403 | 0.01 | 0.02 | 401 | 0.92 | 1.01 | 20 | 502.85 | 516.09 | 20 | 1.61 | 2.30 | 189 |
| `Fiber` | substring-identifier | 0.13 | 0.17 | 303 | 0.01 | 0.01 | 180 | 0.35 | 0.44 | 20 | 528.84 | 570.11 | 20 | 3.22 | 3.81 | 151 |
| `Lane` | substring-identifier | 0.06 | 0.06 | 72 | 0.01 | 0.01 | 40 | 0.12 | 0.20 | 20 | 561.95 | 569.48 | 20 | 2.37 | 3.87 | 305 |
| `Suspense` | substring-identifier | 0.40 | 0.43 | 314 | 0.01 | 0.02 | 259 | 0.54 | 0.68 | 20 | 473.47 | 492.31 | 20 | 2.59 | 3.13 | 52 |
| `flushPassiveEffects` | rare-camelcase | 0.20 | 0.26 | 8 | 0.01 | 0.01 | 7 | 0.15 | 0.29 | 11 | 613.06 | 633.25 | 20 | 1.76 | 2.99 | 4 |
| `enableTransitionTracing` | rare-flag | 0.78 | 0.86 | 25 | 0.01 | 0.01 | 25 | 0.19 | 0.33 | 20 | 605.41 | 627.06 | 20 | 1.48 | 2.04 | 162 |
| `scheduleCallback` | camelcase-identifier | 0.43 | 0.47 | 22 | 0.01 | 0.01 | 22 | 0.16 | 0.25 | 20 | 558.79 | 586.04 | 20 | 1.39 | 1.59 | 38 |
| `concurrent` | lowercase-word | 0.40 | 0.44 | 127 | 0.01 | 0.01 | 75 | 0.24 | 0.32 | 20 | 553.55 | 575.15 | 20 | 1.63 | 2.25 | 222 |
| `function` | lang-keyword | 1.77 | 1.89 | 5286 | 0.07 | 0.09 | 5245 | 16.07 | 16.36 | 20 | 491.60 | 516.44 | 20 | 8.22 | 9.47 | 69 |
| `set` | short-trigram-exact | 0.04 | 0.05 | 2039 | 0.02 | 0.02 | 851 | 3.71 | 4.00 | 20 | 486.10 | 506.05 | 20 | 3.45 | 4.23 | 103 |
| `ReactDOMRoot` | rare-camelcase | 0.13 | 0.16 | 8 | 0.01 | 0.01 | 6 | 0.11 | 0.21 | 8 | 626.39 | 648.94 | 12 | 1.45 | 1.97 | 26 |
| `xyzzy_react_does_not_exist` | negative | 0.20 | 0.22 | 0 | 0.03 | 0.04 | 0 | 0.07 | 0.11 | 0 | 630.53 | 657.50 | 0 | 7.35 | 8.38 | 0 |

