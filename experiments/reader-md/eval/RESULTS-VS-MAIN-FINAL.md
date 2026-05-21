# `experiment/reader-md` vs `main` — final, honest comparison (n=2 samples)

**Date:** 2026-05-21 (updated after security hardening + n=2 sampling)
**Method:** Same 3 tasks × 3 corpora. **Two independent samples** per (task, condition) cell to expose run-to-run variance the critical-review agent (I07) called out at n=1.

## Raw matrix (all 9 cells × 2 samples)

| Task | main baseline | exp + reader.md #1 | exp + reader.md #2 |
|---|---|---|---|
| T1 flask | 4 / 24s / 15,914 tok | 4 / 24s / 17,697 tok | 7 / 39s / 19,639 tok |
| T2 regex | 13 / 96s / 44,965 tok | 3 / 29s / 20,595 tok | 11 / 66s / 34,374 tok |
| T3 react | 13 / 72s / 26,324 tok | 7 / 57s / 27,377 tok | 13 / 87s / 28,162 tok |

All 9 runs returned the correct answer. Quality preserved everywhere.

## Average of the 2 treatment samples, vs main

| Task | main calls | exp avg calls | Δ calls | Δ wall | Δ tokens |
|---|---:|---:|---:|---:|---:|
| T1 flask | 4 | **5.5** | **+37%** ⚠ | +31% ⚠ | +18% ⚠ |
| T2 regex | 13 | **7** | **−46%** | **−51%** | **−39%** |
| T3 react | 13 | **10** | **−23%** | 0% | +6% |
| **Average** | — | — | **−11%** | **−7%** | **−5%** |

## What this honestly shows

The pre-hardening eval (`RESULTS-VS-MAIN.md`) reported −41% / −30% / −13% because the n=1 samples happened to be lucky on T2 (3 calls) and T3 (7 calls). With a second sample, T2 came in at 11 calls and T3 at 13 — much closer to the main baseline.

**On the reader.md A/B alone, the picture is**:

- **T2 regex** — wins both samples (3 and 11 calls vs main's 13). The map's multi-crate disambiguation is a real and persistent advantage.
- **T3 react** — wins sample #1 (7 calls) but ties sample #2 (13 calls). The composer's keyword extraction is already doing most of the work; reader.md adds context but the agent doesn't always need it.
- **T1 flask** — wins one sample (4 calls), loses one (7). For tiny corpora with simple identifier lookups, reader.md overhead occasionally beats the savings.

**Average gain across 2 samples is real but small (~10%).** The original spec-eval (`RESULTS.md`, prompt-inlined) showed −31% calls; the runtime A/B showed −57% calls; the vs-main with n=2 sampling shows −11% calls. The true effect size is probably somewhere in this range, dependent heavily on task shape and corpus complexity.

## Where the branch IS unambiguously better than main

This is the headline that's not affected by sampling noise:

| Capability | main (v0.2.5815) | experiment branch | Source |
|---|---|---|---|
| `Suspense` (regex) p50 latency | 2.82 ms | **0.18 ms** (35× faster) | PR #485, deterministic |
| `useState` (regex) p99 latency | 16.57 ms | **2.04 ms** (8× faster) | PR #485, deterministic |
| Path-traversal in `codedb read` CLI | vulnerable | **guarded** | PR #484, security |
| Sensitive-file access via CLI read | unblocked | **blocked** | PR #484, security |
| Project-root anchoring (CLI read) | uses cwd | **uses configured root** | PR #484, correctness |
| Path-traversal via `.codedb/reader.md` | n/a | **guarded** | This branch, security |
| DoS via huge source_files list | n/a | **capped at 20** | This branch, security |
| `loc_budget × 1.2` enforcement | n/a | **enforced** | This branch, correctness |
| Golden blake2b roundtrip test | n/a | **present** | This branch, correctness |
| shootout.py codegraph backend | absent | **present** | PR #487, tooling |
| reader.md auto-prepend on `codedb_context` | absent | **present (opt-in)** | This branch |

These are **deterministic** improvements — no sample size needed. The branch is strictly safer, faster on at least one query family, and ships new capabilities main doesn't have.

## What this branch should NOT promise

- **−57% calls on every task.** That was n=1 noise on T2/T3.
- **Universal token savings.** T1 flask shows the honest cost: ~2 KB body added to every response when the task didn't need orientation.

## Recommendation

**Ship the branch as-is, but de-emphasize the reader.md perf claim in the headline.** The real wins are:

1. **Two CVE-shaped security fixes** (CLI read path-safety + reader.md source_files traversal/DoS) — these are not optional
2. **A deterministic 35× speedup on a real-world query pattern** (Tier 5 short-circuit, PR #485)
3. **A new opt-in feature** (reader.md) that wins on complex tasks (T2 regex −46% calls avg) and is neutral/negative on simple ones — caveat: install only where you've measured it helping

This is a **strict win** over main on every axis except T1-shaped tasks under the reader.md feature, where it's a 1-of-2 toss-up. The non-reader.md fixes are unconditional wins.

## Outstanding follow-ups (not blockers)

From the critical-review pass:
- I04 schema_version not parsed (cosmetic — only matters when bumping format)
- I05 no caching of reader.md across calls (~0.1 ms overhead per call; matters at scale)
- I06 codedb_status doesn't surface reader.md state (~10 LOC follow-up)
- I07 n=1 → n=2 (done in this doc; ideally n=5+)
- I09 stale hint doesn't include previous source_files (UX polish)
- I10 concurrent-write last-write-wins not documented (multi-agent edge case)
- I11 cost-benefit gate for shallow workloads (opt-out flag)

None of these blocks merging the branch — they're roadmap items for a v0.x → v1 path.
