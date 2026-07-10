# codedb-FL — implementation TODO (what to build next)

Prioritized by leverage / cost. See `research.md` for the full synthesis.

**Methodology (hard rule):** implement each behind an env flag, measure against
`CODEDB_BIN=<exp-binary> engram codedb-report <fixed-corpus>` (MRR), ON vs OFF,
**keep only if it moves.** Baseline: codedb MRR ≈ 0.32, engram ≈ 0.57. The bench
resolves ~0.04 MRR per query, so "flat" means no gold changed rank. Don't hand-tune
signals in isolation — 3 experiments proved that flat-lines; the win is the
*combination* + learned weighting.

## P0 — cheapest, highest-leverage, grounded (do first)
- [x] **rVSM file-size prior** (BugLocator) — **DONE → FLAT, dropped as standalone.**
      Built behind `CODEDB_RVSM_SIZE_PRIOR` (amp/k via `CODEDB_RVSM_AMP`/`_K`) in
      `rerankAndFinalize` (NOT `searchContentRanked`/BM25 — that path is MCP-only and
      the bench never hits it). MRR 0.357→0.357 at amp 0.5 and 1.0; per-query ranks
      byte-identical. Debug-proved the prior fires and doubles `index.zig`'s score,
      but the gold stays #11 — a uniform size multiplier lifts its (bigger, more
      lexically-relevant) competitors in lockstep. See research.md "P0 result". Keep
      `line_count` as a P4 feature; it is inert alone.

- [x] **Def-first: rank the defining file first in codedb_search** — **DONE → +1, SHIPPED (PR #665).**
      `codedb_search`'s fast path (`renderPlainSearchUncached`) ordered tier0 by hit
      count + basename prior only; the def-aware ranking lived in `searchContentRanked`,
      which `codedb_search` never calls. Added a `defines` flag (via `fileDefinesSymbol`)
      + `+20` rank prior for defining files. Measured on a **pinned** eval
      (`scripts/rank-eval.py`, methodology in `def-first-eval.md`): def-file-#1 8/10→9/10,
      zero regressions. The pinned corpus + isolated `$HOME` is what makes a ranking A/B
      trustworthy — an earlier unpinned run showed a phantom 8→7 that reproduced with the
      code reverted (snapshot drift). Holdout: `renderPlainSearch`-as-query bails to
      `searchContentAuto` (docs not demoted there) — next pass.

## P1 — biggest signal gap (the real IRFL win)
- [ ] **Git version-history signals** (AmaLgam / Rahman / BLIA). Mine `git log`
      once at index time:
  - [ ] per-file **fix-frequency** (commit count touching the file)
  - [ ] per-file **fix-recency** (decay by commits-ago / age)
  - fold into the score (additive, then learned). This is the #550 "git co-change"
    sub-item, now evidence-backed.
- [ ] (stretch) **co-change** `A⇒B` support+confidence → *recall expansion*: when a
      lexical hit co-changes with file X, surface X even if X isn't a lexical hit.

## P2 — structured retrieval
- [ ] **BLUiR-style symbol fields** — retrieve over symbol names (class/method/fn)
      as a separate field; strong boost when `q` matches a *defined* symbol name.
      Strengthen well beyond the current `+5` symbol-def boost.

## P3 — centrality, done right
- [ ] **Normalized fan-in/out centrality** (PRINCE). codedb's `centralityBoost` is
      ≈1.0× (per-file PageRank mass is tiny). Normalize/percentile it into a real
      feature. NOTE: tested raw + normalized *in isolation* → flat; only useful
      inside a multi-signal **learned** fusion (P4).

## P4 — the proven path: learned fusion
- [ ] **Lightweight learning-to-rank** over [lexical(rVSM), structured, history,
      centrality] trained on git history (commit→query, changed files→gold). This is
      engram's approach (0.57) and FLUCCS/PRINCE's result that learned > hand-tuned.
      Either (a) port engram's learned policy into codedb, or (b) route
      `codedb_search` through engram's re-rank.

## Orthogonal track — recall (not reranking)
- [ ] **Recall audit** — 7/24 git-bench golds aren't retrieved at all; reranking is
      powerless there. Classify git-noise (query word absent from file — unfixable)
      vs real search-blindness (#547-class — fixable). Fix the real ones.

## Notes / guardrails
- The git-derived gold IS the IRFL target — it's the right fitness function. Don't
  chase a cleaner benchmark unless P0–P4 plateau.
- Build experiments on an isolated worktree + corpus (don't perturb the live MCP /
  main repo snapshot). Pattern used so far: `git worktree add` an experiment branch
  + a detached `cdb-corpus`, bench via `engram codedb-report`.
