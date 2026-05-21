# search-shootout — flask

**Date:** 2026-05-21 10:29
**Corpus:** `/Users/blackfloofie/codedb-bench/flask`
**Indexed files:** 127
**Corpus bytes:** 0.6 MB
**Iterations:** 20 warm

## Build phase

| Backend | Cold index time | On-disk size |
|---|---|---|
| fts5_trigram | 0.04s | 2.3 MB |
| fts5_unicode61 | 0.01s | 0.9 MB |
| codedb | 0.05s | 3.6 MB |
| lean-ctx | 8.29s | — |
| codegraph | 0.58s | 3.7 MB |

## Query latency (warm, ms)

> codedb: MCP stdio (one server, many calls).
> fts5_*: persistent SQLite connection.
> lean-ctx: per-call CLI spawn (includes ~700ms binary startup).
> Hit counts are NOT directly comparable across backends — use them as recall sanity (zero vs non-zero).

| query | kind | fts5_tri p50 | fts5_tri p99 | fts5_tri hits | fts5_uni p50 | fts5_uni p99 | fts5_uni hits | codedb p50 | codedb p99 | codedb hits | leanctx p50 | leanctx p99 | leanctx hits | codegraph p50 | codegraph p99 | codegraph hits |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `useState` | common-identifier | 0.09 | 0.14 | 0 | 0.01 | 0.02 | 0 | 0.66 | 1.39 | 0 | 449.06 | 465.16 | 0 | 0.70 | 1.60 | 0 |
| `useEffect` | common-identifier | 0.01 | 0.01 | 0 | 0.00 | 0.01 | 0 | 0.05 | 0.08 | 0 | 451.48 | 472.32 | 0 | 0.62 | 0.80 | 0 |
| `forwardRef` | camelcase-identifier | 0.01 | 0.02 | 0 | 0.00 | 0.00 | 0 | 0.04 | 0.07 | 0 | 453.87 | 469.16 | 0 | 0.58 | 0.76 | 0 |
| `createElement` | camelcase-identifier | 0.02 | 0.03 | 0 | 0.00 | 0.01 | 0 | 0.05 | 0.08 | 0 | 453.36 | 466.15 | 0 | 0.68 | 0.83 | 0 |
| `Fiber` | substring-identifier | 0.01 | 0.01 | 0 | 0.00 | 0.00 | 0 | 0.04 | 0.09 | 0 | 451.23 | 467.81 | 0 | 0.65 | 0.78 | 0 |
| `Lane` | substring-identifier | 0.01 | 0.01 | 0 | 0.00 | 0.01 | 0 | 0.05 | 0.08 | 0 | 452.00 | 470.30 | 0 | 0.64 | 0.84 | 0 |
| `Suspense` | substring-identifier | 0.00 | 0.01 | 0 | 0.00 | 0.01 | 0 | 0.06 | 0.08 | 0 | 448.85 | 456.00 | 0 | 0.66 | 0.77 | 0 |
| `flushPassiveEffects` | rare-camelcase | 0.00 | 0.01 | 0 | 0.00 | 0.00 | 0 | 0.04 | 0.10 | 0 | 450.76 | 475.44 | 0 | 0.64 | 0.75 | 0 |
| `enableTransitionTracing` | rare-flag | 0.05 | 0.05 | 0 | 0.00 | 0.01 | 0 | 0.05 | 0.08 | 0 | 451.71 | 463.39 | 0 | 0.76 | 1.03 | 0 |
| `scheduleCallback` | camelcase-identifier | 0.04 | 0.13 | 0 | 0.00 | 0.01 | 0 | 0.05 | 0.10 | 0 | 448.54 | 467.48 | 0 | 0.64 | 0.79 | 0 |
| `concurrent` | lowercase-word | 0.02 | 0.03 | 2 | 0.00 | 0.00 | 1 | 0.07 | 0.14 | 10 | 457.91 | 474.26 | 11 | 0.15 | 0.30 | 2 |
| `function` | lang-keyword | 0.03 | 0.04 | 23 | 0.00 | 0.00 | 20 | 0.10 | 0.19 | 20 | 449.05 | 471.18 | 20 | 1.38 | 1.88 | 105 |
| `set` | short-trigram-exact | 0.00 | 0.01 | 46 | 0.00 | 0.01 | 29 | 0.10 | 0.22 | 20 | 437.50 | 457.94 | 20 | 0.35 | 0.49 | 70 |
| `ReactDOMRoot` | rare-camelcase | 0.02 | 0.03 | 0 | 0.00 | 0.00 | 0 | 0.05 | 0.17 | 0 | 440.40 | 455.97 | 0 | 0.64 | 0.82 | 0 |
| `xyzzy_react_does_not_exist` | negative | 0.01 | 0.01 | 0 | 0.00 | 0.00 | 0 | 0.06 | 0.09 | 0 | 444.86 | 453.83 | 0 | 0.57 | 0.69 | 0 |

