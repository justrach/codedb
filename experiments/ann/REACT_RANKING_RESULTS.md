# React hybrid-ranking hill climb

Date: 2026-08-30

The benchmark uses 12 production-source localization tasks against React at
`2dc7da790d63`: eight queries for policy selection and four held out. Gold
labels identify production implementation files. Each query explicitly asks
for production source and excludes irrelevant tests, fixtures, examples, or
debug/server variants where appropriate.

Lexical and ANN evidence is collected once per query. The local replay then
searches 15,360 combinations of ANN RRF weight, RRF `k`, lexical guard depth,
and intent-aware path multipliers. Selection is train-only; the held-out set is
opened once after selection. A candidate is unsafe if held-out hit@5, MRR,
NDCG@5, or recall@5 regress, or if test/fixture pollution increases.

## Retrieval result

| split | policy | hit@5 | MRR@5 | NDCG@5 | recall@5 | test-like files in top 5/query |
|---|---|---:|---:|---:|---:|---:|
| train | released 0.2.5850 | 0.625 | 0.238 | 0.186 | 0.375 | 3.00 |
| train | candidate binary | **1.000** | **0.729** | **0.646** | **0.719** | **0.00** |
| held out | released 0.2.5850 | 0.750 | 0.150 | 0.226 | 0.625 | 1.25 |
| held out | candidate binary | **1.000** | **1.000** | **0.738** | **0.750** | **0.00** |

The selected policy removes the unconditional top-three lexical guard, uses
ANN RRF `k=20` and semantic weight `1.5`, and applies path priors only when the
query expresses production/exclusion intent. Exact fallback fusion keeps its
existing constants, so a missing or stale ANN cannot weaken the lexical floor.

Ablation showed that fusion tuning alone left 1.0–2.4 test-like paths in the
top five. Production-aware test handling removed that pollution; debug/client
and documentation intent supplied additional MRR/NDCG lift. Documentation is
not demoted when the task asks for docs, README, or architecture material.

## Semantic-index concurrency

The indexing benchmark used 371 files / 6,713 chunks from React's production
reconciler, hooks, and DOM-bindings trees. Every run produced the same 18.7 MB
sidecar and sent the same 6.01 MB of bounded chunk text.

| parallel batches | elapsed | relative to c1 | peak RSS | outcome |
|---:|---:|---:|---:|---|
| 1 | 180.8 s | 1.00x | 65.3 MiB | completed |
| 2 | 98.9 s | 1.83x | 63.2 MiB | completed |
| 4 | **68.8 s** | **2.63x** | 81.6 MiB | completed |
| 8 | >338 s | <0.54x | 60.8 MiB | aborted during retry/queue contention |

The existing default of four is therefore retained. The bottleneck above four
is hosted-lane scheduling/backoff, not local HNSW insertion or memory. Raising
the client default would make indexing slower on the current service.

## Reproduce

```bash
python3 experiments/ann/react_ranking_hillclimb.py \
  --binary ./zig-out/bin/codedb \
  --project /path/to/react \
  --out /tmp/react-ranking-hillclimb.json
```

The script exits successfully both when it finds a safe promotion and when the
tested binary already matches or beats the selected replay policy. It fails on
a held-out regression.
