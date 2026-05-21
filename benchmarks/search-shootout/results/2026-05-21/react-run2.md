# search-shootout — react

**Date:** 2026-05-21 10:24
**Corpus:** `/Users/blackfloofie/codedb-bench/react`
**Indexed files:** 6,620
**Corpus bytes:** 26.5 MB
**Iterations:** 20 warm

## Build phase

| Backend | Cold index time | On-disk size |
|---|---|---|
| codedb | 1.13s | 69.5 MB |
| lean-ctx | 8.31s | — |
| codegraph | 15.05s | 195.5 MB |

## Query latency (warm, ms)

> codedb: MCP stdio (one server, many calls).
> fts5_*: persistent SQLite connection.
> lean-ctx: per-call CLI spawn (includes ~700ms binary startup).
> Hit counts are NOT directly comparable across backends — use them as recall sanity (zero vs non-zero).

| query | kind | codedb p50 | codedb p99 | codedb hits | leanctx p50 | leanctx p99 | leanctx hits | codegraph p50 | codegraph p99 | codegraph hits |
|---|---|---|---|---|---|---|---|---|---|---|
| `useState` | common-identifier | 2.87 | 4.91 | 20 | 498.69 | 523.87 | 20 | 2.75 | 4.31 | 65 |
| `useEffect` | common-identifier | 1.04 | 1.25 | 20 | 483.85 | 502.82 | 20 | 5.66 | 5.89 | 101 |
| `forwardRef` | camelcase-identifier | 0.24 | 0.34 | 20 | 483.99 | 497.38 | 20 | 2.26 | 2.76 | 55 |
| `createElement` | camelcase-identifier | 0.93 | 1.05 | 20 | 510.25 | 532.48 | 20 | 2.86 | 3.49 | 189 |
| `Fiber` | substring-identifier | 0.39 | 0.81 | 20 | 550.13 | 571.72 | 20 | 4.50 | 5.14 | 151 |
| `Lane` | substring-identifier | 0.11 | 0.24 | 20 | 563.37 | 594.56 | 20 | 2.13 | 2.67 | 305 |
| `Suspense` | substring-identifier | 0.51 | 0.61 | 20 | 487.01 | 501.94 | 20 | 2.69 | 2.99 | 52 |
| `flushPassiveEffects` | rare-camelcase | 0.14 | 0.27 | 11 | 597.10 | 622.17 | 20 | 1.32 | 1.52 | 4 |
| `enableTransitionTracing` | rare-flag | 0.18 | 0.28 | 20 | 593.63 | 604.01 | 20 | 1.52 | 1.94 | 162 |
| `scheduleCallback` | camelcase-identifier | 0.17 | 0.26 | 20 | 545.70 | 565.42 | 20 | 1.40 | 1.68 | 38 |
| `concurrent` | lowercase-word | 0.23 | 0.34 | 20 | 557.32 | 565.11 | 20 | 1.97 | 2.47 | 222 |
| `function` | lang-keyword | 17.88 | 29.38 | 20 | 472.26 | 488.21 | 20 | 8.84 | 10.03 | 69 |
| `set` | short-trigram-exact | 3.95 | 4.13 | 20 | 468.22 | 505.09 | 20 | 5.84 | 8.15 | 103 |
| `ReactDOMRoot` | rare-camelcase | 0.25 | 0.36 | 8 | 632.26 | 680.78 | 12 | 1.84 | 2.36 | 26 |
| `xyzzy_react_does_not_exist` | negative | 0.04 | 0.08 | 0 | 635.35 | 670.92 | 0 | 8.36 | 9.74 | 0 |

