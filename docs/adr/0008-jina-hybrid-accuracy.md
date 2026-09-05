> Superseded ranking values: see [ADR 0009](0009-jina-implementation-accuracy.md).
> This record preserves the previous candidate and its original evidence.

# ADR 0008: Improve default Jina hybrid retrieval accuracy

Status: implemented experimental candidate; improves measured top-five retrieval,
but broad first-result accuracy is not established. Not installed or deployed.

## Objective and scope

Optimize accuracy through the existing hosted Jina embedding service and CodeDB's
local OpenPuffer mmap sidecar. This is native engine ranking work, based on
`release/0.2.5852` at `b72db9b`, on `codex/jina-sidecar-hillclimb`.
The old main checkout's Qwen/local-default experiments are not applicable.

The service and model stay hosted. Default hybrid, query/calibration validation,
512-dimensional Jina vectors, the 4× ANN candidate pool, and missing-sidecar
hosted exact fallback stay intact. The 2× speed experiment from ADR 0007 was
discarded: it did not improve accuracy. No local model training is involved.

## Diagnosis and change

Rank fusion flattened strong semantic matches: a correct file ranked first by
ANN could lose to weak matches appearing in both lists. An excessive semantic
weight then displaced literal function definitions and neighboring behavior.

The candidate uses ANN RRF k=1 and semantic weight=2 (previously 20 and 1.5).
A single file containing an exact code-shaped symbol definition takes priority
for definition-oriented requests. Imports/comments are excluded; multiple
matching definition files do not pin a result. Code-shaped means a bare name
with an underscore or lower-to-upper transition, not an ordinary prose word.
Requests mentioning tests, callers, usage, or references disable this priority.

For where/implementation requests without those other intents, test-file fusion
scores receive a 0.75 multiplier. Tests remain candidates. The exact fallback
and lexical-only policies are unchanged. This adds two small intent helpers;
it introduces no model, provider, index format, or tuning configuration.

## Fixed-evaluator hill climb

Following the experiment discipline of [autoresearch](https://github.com/karpathy/autoresearch),
change one small policy at a time, compile the real binary, run an unchanged
evaluator through live inference, retain raw outcomes, and freeze before fresh
validation. No cached-score replay substitutes for the current integration.

OpenClaw development: 34 pinned public files, 473 chunks, 32 positive questions,
two repeats each per binary. Both prior splits are now development data, not
fresh holdout evidence. Repeats are not independent questions. Both persistent
MCP sessions share the same Jina sidecar, alternate request order, omit the
semantic override, and must report ann_applied, two query/calibration inputs,
and mmap storage. Every request uses the hosted service.

| Native trial | NDCG@5 | Recall@5 | Correct file first |
| --- | ---: | ---: | ---: |
| Baseline k20, weight1.5 | 0.9070 | 31/32 | 26/32 |
| k1, weight1.5 | 0.9341 | 31/32 | 28/32 |
| k1, weight3 | 0.9423 | 32/32 | 27/32 |
| Add unique definition priority | 0.9654 | 32/32 | 29/32 |
| Add implementation preference | 0.9769 | 32/32 | 30/32 |
| Weight2, freeze this candidate | 0.9885 | 32/32 | 31/32 |

[Trial ledger](../../evals/results/2026-09-05-jina-accuracy-trials.tsv) links all
raw reports, including inferior candidates. The remaining first-result miss is
`auth-mode-policy-1`: the correct auth-mode-policy file is second behind a
neighboring auth implementation. The gold was not changed to hide this miss.

## Fresh cross-repository validation

Express source `023767fe9872e029271df1418f73401bff20ff40`: 35 pinned public
files, 388 chunks, 16 questions (12 implementation and four test-finding),
three repeats per binary. Labels were source-checked before querying.
The [freeze record](../../evals/results/2026-09-05-jina-accuracy-freeze.json)
locks baseline, final candidate binary and dataset hashes before this run.
The evaluator refuses changed hashes. No policy changed after seeing results.

| Frozen Express holdout | Baseline | Candidate |
| --- | ---: | ---: |
| NDCG@5 | 0.7526 | 0.7757 |
| Recall@5 | 15/16 | 16/16 |
| Correct file first | 8/16 | 8/16 |

[Raw holdout](../../evals/results/2026-09-05-jina-accuracy-express-heldout.json):
96/96 calls used the intended live Jina/mmap path without provider failures.
No per-question top-five recall regression occurred. Ranking is not uniformly
better: express-01 and express-07 fall from second to third; express-09 falls
from first to second. Express-10 improves from second to first; express-11
recovers from absent in top five to third. Overall first-result accuracy is
unchanged. Keep these failures visible to future agents.

## Decision, limits and next work

Retain the candidate as a measured coverage/ranking improvement, not a claim
that retrieval is now universally very accurate. Express first-result accuracy
is only 50%; that is the main unresolved problem. These small hand-labeled
corpora contain correlated questions and cannot establish large-repository,
multilingual, symbol-level, or unrelated-query accuracy. Returning the correct
file within five is not the same as supplying the correct answer or snippet.

Both sets are now observed data. Future work should inspect why neighboring
implementations and tests outrank exact behavior, evaluate changes on these
regression sets, and reserve a new repository holdout before another promotion.
Do not tune against Express and continue calling it fresh. Do not exchange
candidate breadth for speed or reintroduce local-model/default changes.

## Verification and handoff

Final ReleaseFast build passed. `zig build test --summary all`: 31/31 build
steps succeeded, 1249/1253 executed tests passed, four skipped (other steps
cached). MCP end-to-end scenarios: 76/76 passed using the final binary.
The final binary hash is in the freeze record. The development run preceded
a comment-only rebuild; the frozen binary is the one tested on Express.
No installed client replacement, deployment, merge, or commit was performed.

Use [evals/README.md](../../evals/README.md) for replay instructions.
Keep credentials, vectors, and source snippets out of reports. Current service
authentication uses the existing installation/device flow, not embedded shared
origin credentials. Architecture and baseline fallback proof: [ADR 0007](0007-current-jina-hybrid-sidecar.md).
