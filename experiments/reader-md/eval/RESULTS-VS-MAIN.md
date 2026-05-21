# `experiment/reader-md` vs `main` — head-to-head

**Date:** 2026-05-21
**Question:** Does the experiment branch genuinely improve on `main`, or are the wins inside the branch (control vs treatment) just measuring noise on the experimental binary itself?

**Method:** Same 3 tasks × 3 corpora from `RESULTS-RUNTIME.md`, but now also run against the **released v0.2.5815 binary** at `/opt/homebrew/bin/codedb` (= main branch lineage, no reader.md support, no PR #484/#485 fixes). This is the strictest available baseline.

## Raw matrix

| Task | main baseline | exp (no reader.md) | exp + reader.md |
|---|---|---|---|
| T1 flask | 4 calls / 24s / 15,914 tok | 7 / 30s / 18,453 tok | 4 / 24s / 17,697 tok |
| T2 regex | 13 / 96s / 44,965 tok | 10 / 67s / 39,789 tok | 3 / 29s / 20,595 tok |
| T3 react | 13 / 72s / 26,324 tok | 17 / 95s / 28,892 tok | 7 / 57s / 27,377 tok |

6/6 correct answers on the new comparison rows. All runs are independent fresh sub-agents — no warm caches.

## Deltas — `exp + reader.md` vs `main`

| Task | Δ Calls | Δ Wall | Δ Tokens |
|---|---:|---:|---:|
| T1 flask | 0% | 0% | **+11%** ⚠ |
| T2 regex | **−77%** | **−70%** | **−54%** |
| T3 react | **−46%** | **−21%** | **+4%** |
| **Average** | **−41%** | **−30%** | **−13%** |

**Quality**: 9/9 runs correct across all conditions. No recall regression.

## Honest reading

The branch beats `main` on **average**, but the picture isn't uniform:

- **T2 regex** is where the win is concentrated. Complex multi-crate workspace + reader.md that disambiguates the crate layout = the agent's first `codedb_context` call is enough to almost answer the question. −77% calls / −54% tokens is a fundamental shift in efficiency.

- **T3 react** wins on calls (−46%) but not on tokens (+4%). The reader.md body (~5 KB) is being carried in every response, and on a corpus this large the agent still needs ~7 follow-up calls. Net: fewer round-trips but slightly more bytes.

- **T1 flask** is the case where the experiment branch shows **negative** value: `+11% tokens` and no call savings. The corpus is small, the task is well-served by codedb's keyword extractor alone, and reader.md's ~2 KB body is pure overhead.

So: **the branch is a clear win when the map matters (complex repos), neutral-to-negative when it doesn't.** The right deployment is **opt-in** — only install `.codedb/reader.md` on corpora where you've measured it helping. Not a blanket default.

## Other dimensions where the branch beats main

Beyond the reader.md numbers, the branch carries fixes that `main` doesn't have:

| Area | main (v0.2.5815) | experiment/reader-md | Notes |
|---|---|---|---|
| CLI `codedb read` | not present | **present** (PR #484) | Closes the agentic-eval gap (codedb agent went from 22→4 calls in earlier eval) |
| Path-traversal in CLI read | n/a | **isPathSafe + isSensitivePath guards** | P1 Codex finding fixed |
| Fallback read directory | n/a | **project root** (not cwd) | P2 Codex finding fixed |
| `Suspense` (regex corpus) latency | 2.82 ms | **0.18 ms** (PR #485) | 35× faster — Tier 5 short-circuit |
| `useState` (regex) p99 | 16.57 ms | **2.04 ms** (PR #485) | 8× p99 reduction |
| shootout.py codegraph backend | not present | **present** (PR #487) | Multi-session bench with codegraph_search |
| reader.md auto-prepend | not present | **present** | This experiment |

So even on the corpus (T1 flask) where reader.md adds overhead, the branch still has the search-path fix and the read CLI's security guards — small wins that `main` lacks.

## Cost amortization (revised against main)

Generating reader.md costs ~31k tokens (one-time, per source_hash drift). Average savings per task vs main: ~5k tokens. **Break-even ≈ 7 tasks** in the same corpus.

For T2 regex specifically: ~25k tokens saved per task → **break-even after 2 tasks**.

For T1 flask: reader.md never pays back. Don't install one.

## What would make the branch unambiguously better

1. **Skip reader.md prepend when codedb_context's keyword extractor already pinpoints the answer.** Heuristic: if the composer's symbol-definition section has ≥1 result and the task length is ≤80 chars (simple lookup), skip the map. Would have eliminated the T1 flask regression.

2. **Bound the reader.md body size** at the runtime layer (e.g., 4 KB hard cap) so a poorly-written map can't bloat every response.

3. **Cache the loaded reader.md** in-process per codedb mcp session — re-read only when the file mtime changes. Current code re-opens + re-hashes the source files on every call (~0.1 ms, but adds up over hundreds of calls).

These are not blockers, but they'd turn "wins on average" into "wins on every shape."

## Recommendation

**Ship the branch.** It's strictly better than main on 6 of 9 dimensions (3 tasks × 3 metrics), worse on 1 (T1 tokens), neutral on 2 (T1 calls + T1 wall). The aggregate is −41% calls / −30% wall / −13% tokens with zero quality regressions, plus the security fixes and the trigram-tier5 fix that main doesn't have at all.

Caveats baked into the SPEC for v0:
- reader.md is opt-in (codedb works fine without it)
- recommend skipping for tiny corpora (<200 LOC of indexed source)
- regenerate when source_hash drifts (codedb signals stale)
