# ADR 0010: Expand multilingual accuracy coverage and respect test requests

Status: retained native candidate; frozen Requests validation passed. No install,
deployment, commit, or merge. Extends ADR 0009 without changing fusion constants.

## Objective and datasets

Improve actual default-hybrid retrieval using hosted Jina and the local
OpenPuffer mmap sidecar. Expand beyond repeated tuning on the original three
small corpora. Added 60 source-checked questions and 119 public source/test files:

| New dataset | Language | Files | Questions | Role in this round |
| --- | --- | ---: | ---: | --- |
| Chi | Go | 65 | 20 | Development |
| Anyhow | Rust | 26 | 20 | Development |
| Requests | Python | 28 | 20 | Fresh frozen holdout |

Each has 16 behavior/identifier lookups and four explicit test-finding requests,
with varied question forms. Source commits and file hashes are pinned in the
[dataset inventory](../../evals/datasets/README.md). The complete suite now has
128 positive questions, 234 files, six repositories and five source languages
(TypeScript, JavaScript, Python, Go, Rust). These are bounded fixtures, not full
repository benchmarks. Existing OpenClaw, Express and Flask are development data.
Requests was not queried until the candidate freeze; it is now observed too.

## Label audit before tuning

Initial Chi v1 question chi-03 allowed both realip.go and client_ip.go as correct
implementations. After source review, Chi v2 adds the second target at equal
relevance. Preserve v1 and its initial baseline; do not count this label repair
as a code improvement. All candidate comparisons remeasure both binaries with
v2. The source corpus is identical, so its existing sidecar remains valid.
Anyhow and Requests labels were unchanged. Gold anchors record source locations.

## Diagnosis and minimal native change

Explicit test-finding requests sometimes ranked production implementation ahead
of the requested tests. Extend the existing soft implementation preference
symmetrically: for test requests, multiply non-test file fusion scores by 0.5.
Test files remain unmodified, and no candidates are removed. Explicit test
exclusions remain respected. Recognize whole words test/tests rather than
substrings, so words such as latest and contest do not switch retrieval intent
or suppress exact-definition priority. Reuse the existing path classifier.

The change is in src/mcp.zig, with a targeted unit test. No ranking-weight sweep,
new model, provider, index format, query service, or runtime option is added.
Jina remains hosted. Default hybrid, calibrated mmap search, 4× ANN breadth,
unique explicit definition priority, and hosted exact fallback stay intact.
ADR 0009's k=1 and semantic weight=2.5 are unchanged.

## Live experiments

The initial Chi/Anyhow baselines ran the ADR 0009 binary on both arms to establish
behavior before any candidate: 80 calls. The candidate then ran against all five
development repositories, two repeats per question per binary: 432 calls.
The fresh Requests comparison used three repeats: 120 calls. All 632 calls used
the actual hosted service and reported ann_applied, two query/calibration inputs,
and mmap storage. Repeats are not independent questions. Timing fields are
recorded, but speed was not the selection objective.

| Correct file first | ADR 0009 | Candidate | Candidate recall@5 |
| --- | ---: | ---: | ---: |
| OpenClaw, development | 30/32 | 30/32 | 32/32 |
| Express, development | 12/16 | 12/16 | 16/16 |
| Flask, development | 19/20 | 19/20 | 20/20 |
| Chi v2, development | 17/20 | 17/20 | 19/20 |
| Anyhow, development | 16/20 | 18/20 | 20/20 |
| Requests, fresh holdout | 17/20 | 17/20 | 20/20 |

Development macro top1 improves 0.8575 to 0.8775; macro NDCG@5 improves 0.9323
to 0.9417. Anyhow's chain-test and formatting-test questions now rank first.
Chi's slash-cleaning test result moves from fourth to third. There are no
per-question ranking or recall regressions across the five development sets.

The [freeze](../../evals/results/2026-09-05-jina-round3-freeze.json) locks both
binaries, Requests dataset, suite manifest, and development summary. Its gate
requires no per-question recall loss, no aggregate top1/NDCG decline, and no
provider failures. No policy was changed after observing Requests.

Requests passes: NDCG@5 improves 0.9315 to 0.9381; its adapter-test question moves
from third to second. Top1 and recall are unchanged, with no per-question rank
regressions. This is incremental improvement, not a holdout top1 gain.
[Decision](../../evals/results/2026-09-05-jina-round3-decision.json),
[full comparison ledger](../../evals/results/2026-09-05-jina-round3-trials.tsv),
[holdout](../../evals/results/2026-09-05-jina-round3-requests-heldout/requests.json).

## Remaining failures and limits

The [failure catalog](../../evals/results/2026-09-05-jina-round3-failure-catalog.json)
contains all 15 remaining first-result misses, gold paths, top-five results and
ANN evidence. One question misses the top five: chi-10's route-pattern cleanup.
The right context.go chunk is present at ANN rank 16, with no lexical rank;
this is weak ranking evidence rather than an absent source chunk. Other misses
include neighboring API implementations and competing test files. The new
intent preference cannot resolve confusion between two test files.

Hand-written, correlated file labels do not prove correct snippets, answers,
unrelated-query rejection, large-repository behavior, or comprehensive language
support. The extra Chi target demonstrates why label audits matter. The existing
path classifier includes fixtures/examples, which these questions do not
separately test. All six datasets are now observed; another policy promotion
requires new holdout data. Do not silently retune or relabel this holdout.

## Reproduction and verification

[jina_accuracy_suite.py](../../evals/jina_accuracy_suite.py) runs a selected
development group or a single frozen holdout, using the existing live comparison
runner. The [manifest](../../evals/suites/jina-accuracy-round3.json) prevents the
holdout from entering a default development run. Reports include repository
metrics, macro averages and individual regressions. Runner exit success means
execution succeeded; apply the recorded quality gate separately.

Use stable copies of ReleaseFast binaries outside zig-out: unit tests rebuild
that output in debug mode. A clean b72db9b checkout plus the
[ADR 0009 patch](../../evals/patches/adr0009-baseline.patch) reproduces incumbent
source. Build paths may change binary hashes; use new replay freeze/results,
never overwrite historical records. Rebuild corpus reports on other machines
using their pinned source checkouts; saved scratch paths are not portable.

ReleaseFast passed; Zig tests: 31/31 steps, 1089/1093 executed tests passed,
four skipped (other steps cached). Frozen-binary MCP end-to-end: 76/76 passed.
Python compilation, missing-freeze/invalid-repository rejection, baseline patch
reconstruction, and final frozen-binary hash checks passed. See the
[validation record](../../evals/results/2026-09-05-jina-round3-validation.json).
No credentials, source snippets, or raw vectors are stored in reports.
