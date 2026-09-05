> Extended by [ADR 0010](0010-multilingual-datasets-and-test-intent.md), which preserves these fusion weights and adds test-intent handling.

# ADR 0009: Improve implementation ranking without changing retrieval architecture

Status: retained experimental candidate; frozen third-repository gate passed.
Not installed, deployed, committed, or merged. Supersedes ADR 0008's ranking
values; its architecture and historical results remain valid.

## Objective and diagnosis

Improve correct-file-first accuracy through default hybrid, hosted Jina, and
local OpenPuffer. Start from the ADR 0008 candidate, not the original release.
Express is now development data, not a fresh holdout. Strong implementation
matches were present, but tests and neighboring APIs still outranked them.

Only two production values change relative to ADR 0008:

- Implementation-intent test-file multiplier: 0.75 to 0.5. Explicit requests
  for tests/callers/usage/references remain exempt; tests are still candidates.
- ANN semantic weight: 2 to 2.5, retaining RRF k=1.

No additional ranking helper, runtime configuration, model, remote service, or
index format is added. Preserve unique explicit definition priority, default
hybrid, query/calibration checks, hosted exact fallback, and 4× ANN breadth.

## Native development experiments

Compile and evaluate each candidate against the same pinned Jina sidecars using
persistent MCP sessions, alternating request order and making live hosted
inference requests for every sample. Use the unchanged positive-query labels:
32 OpenClaw questions and 16 Express questions, two repeats per binary per trial.
Repetition is not extra independent evidence. The two trials total 384 measured
calls; all used ann_applied, two query/calibration inputs, and mmap storage.

| Candidate | OpenClaw first / NDCG@5 | Express first / NDCG@5 |
| --- | --- | --- |
| ADR 0008 incumbent | 31/32 / 0.9885 | 8/16 / 0.7757 |
| Test multiplier 0.5 only | 31/32 / 0.9885 | 9/16 / 0.8151 |
| Also semantic weight 2.5 | 30/32 / 0.9769 | 12/16 / 0.8870 |

Every question retained top-five recall in both trials. Select the combined
candidate for higher macro-average top1 and NDCG across the two repositories,
while explicitly accepting one development ranking regression:
`auth-resolve-1` falls from first to second. Express gains four first results,
with no per-question rank regressions versus ADR 0008. The correct files for
express-00, express-01, express-07, and express-12 still do not rank first.

[Trial ledger](../../evals/results/2026-09-05-jina-round2-trials.tsv) links both
trials' complete outputs. The first candidate is retained as evidence, not a
second runtime policy. No post-hoc label changes or cached-score replay.

## Frozen Flask holdout

Flask commit `d318b683471101618febed18996405ad26462110`; all 46 Python package
and top-level test files selected by the dataset, 713 embedded chunks. Twenty
source-checked questions: 16 implementation and four test-finding. No Flask
ranking results were read until the candidate and dataset hashes were frozen.
The [freeze](../../evals/results/2026-09-05-jina-round2-freeze.json) records the
selection tradeoff and acceptance criteria before evaluation: no per-question
recall regression, no aggregate top1 or NDCG decline, and no provider failures.

| Fresh Flask holdout | ADR 0008 | New candidate |
| --- | ---: | ---: |
| Correct file first | 19/20 | 19/20 |
| Recall@5 | 20/20 | 20/20 |
| NDCG@5 | 0.9715 | 0.9750 |

All 120 measured calls (three repeats per binary per question) used the intended
live service/mmap path without failures. There were no per-question ranking
regressions. The one miss, flask-08, improves from fourth to third: signal
definitions and the public export file still outrank the actual template-render
implementation. The source-verified implementation gold is unchanged.
[Raw holdout](../../evals/results/2026-09-05-jina-round2-flask-heldout.json) and
[acceptance decision](../../evals/results/2026-09-05-jina-round2-decision.json).

## Decision and limitations

Retain the two-value change: Express first-result accuracy improves from 50%
to 75%, and fresh Flask preserves 95%. It does not uniformly improve every
repository or query. OpenClaw drops from 96.875% to 93.75%. These are small,
hand-labeled, correlated file-level questions, not proof of broad production
accuracy, correct snippets, answer quality, or unrelated-query abstention.
The datasets are now all observed regression data. Further tuning needs a new
holdout; do not tune on Flask and continue calling it fresh.

## Reproduction and verification

Use [evals/README.md](../../evals/README.md). A clean b72db9b checkout plus
[the ADR 0008 source patch](../../evals/patches/adr0008-baseline.patch) recreates
the incumbent source; build it with ReleaseFast in a separate worktree.
The candidate lives on codex/jina-sidecar-hillclimb. Binary hashes are recorded,
but debug/build paths can change rebuilt hashes: make a new freeze for a replay,
never overwrite the historical one. Historical scratch paths are not portable.

The runner now resolves binary paths before changing subprocess cwd, creates
missing scratch parents, validates corpus hashes before inference, and records
dataset/corpus-report hashes and individual ranking regressions. The first
setup attempts hit missing-directory and relative-binary-path errors before
candidate inference; corrected runs are the complete reports in the ledger.
These harness fixes do not alter relevance metrics or ranking labels.

Final ReleaseFast build passed. zig build test --summary all: 31/31 build steps,
1249/1253 executed tests passed, four skipped (other steps cached). MCP end-to-end:
76/76 passed. Python compilation passed; invalid freeze and corpus hashes were
verified to reject before inference. No source change followed the freeze.
Keep credentials, raw vectors, and source snippets out of experiment artifacts.

Final artifact audit found that the unit suite itself runs a debug CLI build,
replacing zig-out/bin/codedb. ReleaseFast was restored byte-for-byte to the
frozen hash and copied outside the build directory. MCP checks were repeated
against that separate frozen binary. A one-repeat Flask recheck verifies the
same rankings; it is a regression check, not a second fresh holdout. Future
comparisons must use stable binary copies, and the runner now rejects binary
replacement during evaluation.
