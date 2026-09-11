# ADR 0012: Follow-up retrieval and transport fixes

Status: local candidate after the 0.2.5855 stress test; not released or installed.

## Problem and changes

The original 128-question run found 15 first-result misses and one top-five miss.
The mmap sidecar loaded successfully. Inspection showed useful ANN candidates
losing during fusion, truncated keyword requests missing compound identifiers,
and documentation-heavy chunks beating implementation files.

The candidate adds the existing whole-query BM25 search to the lexical union.
Each distinct file contributes once, using the maximum of its existing keyword
score and whole-query score, rather than counting repeated matching lines as
independent whole-query votes. The existing two-lane RRF constants stay unchanged.

For an implementation request, a semantic chunk whose nonempty lines are more
than 75% `//` comments contributes half its usual semantic vote. Declaration,
macro, type, example and documentation requests keep their usual contribution.
This is a conservative comment detector, not a language-independent classifier.

A unique complete compound symbol can receive definition priority for a
`where is` implementation request. Explicit test requests can prioritize a
unique compound test filename literally named in the request. Ordinary call/use
requests retain the existing dependency-intent guards. These rules inspect
existing candidates; there are no query IDs, gold paths or repository names in
the ranking implementation. Provenance exposes whole-query rank and the
documentation adjustment.

Hosted Jina, calibration, exact hosted fallback, the 4× ANN candidate pool and
OpenPuffer mmap remain in place. No local embedding model is introduced, and
the ANN request still sends the query plus the fixed calibration string.

Interactive embeddings now retry one transient DNS or connection failure after
100ms, inside the original request deadline. The signed request is regenerated.
TLS errors, provider rejection, rate limits, malformed vectors and calibration
failures are not retried. Persistent failures still fall back to lexical search.
This mitigates transient transport failures; it does not repair DNS infrastructure.

## Evaluation discipline

The five development repositories have 108 previously observed questions.
Requests adds 20 previously observed questions and is not a fresh holdout.
Early whole-query additive scoring, a third RRF vote, and broad natural-language
definition pinning were rejected because of individual ranking regressions.
The selected policy was frozen before running a new 20-question ItsDangerous
holdout. No ranking edits were made after opening that holdout.

ItsDangerous is pinned at `672971d66a2ef9f85151e53283113f33d642dabd` in
[`itsdangerous-jina-followup-v1.json`](../../evals/datasets/itsdangerous-jina-followup-v1.json).
The questions cover 12 implementation behaviors, two type definitions and six
test lookups. All source hashes and gold anchors were fixed before evaluation.
Both binaries use the same calibrated sidecar and real hosted Jina on every
measured request, with two repetitions per question.

| Repository | Release 0.2.5855 first result | Candidate first result |
| --- | ---: | ---: |
| OpenClaw | 30/32 | 30/32 |
| Express | 12/16 | 14/16 |
| Flask | 19/20 | 19/20 |
| Chi | 17/20 | 19/20 |
| Anyhow | 18/20 | 20/20 |
| Requests, observed validation | 17/20 | 17/20 |
| ItsDangerous, fresh frozen holdout | 18/20 | 18/20 |

Across the original six repositories, first-result accuracy improves from
113/128 to 119/128; top-five coverage improves from 127/128 to 128/128.
There are no first-result or recall regressions. Requests question 17 moves
from second to third, lowering that repository's NDCG; this is a real tradeoff,
not a fixed query. The fresh holdout has no individual ranking regressions.

## Remaining work and limits

Nine original queries still miss the first position. The test-adapter lookup
regression and these misses remain catalogued rather than being patched with
query-specific exceptions. The fresh holdout has two first-result misses shared
by both binaries. All seven repositories are now observed; another ranking
round needs a new holdout before promotion. Do not describe these changes as
fixing every retrieval failure or providing perfect search.

Live-network timings include provider variance. They must not be used alone to
claim a speedup. Watcher CPU measurements and retrieval correctness are separate
experiments. The final observed run flags OpenClaw p95 (+54.3%), Express median
(+20.3%), Anyhow p95 (+20.9%) and fresh ItsDangerous p95 (+17.3%) above the 10%
review threshold. Other timing statistics move in both directions. These are
unresolved live-latency flags, not proof of a local-code regression; they are
also not a passed performance gate. Keep this ranking change separate from
the watcher and transport fixes while reviewing that tradeoff.

A follow-up phase profile of the eight largest OpenClaw timing deltas used
three alternating repeats with the existing markdown profiler. Median keyword
work was 0.049 ms in the release and 0.0705 ms in the candidate. Median ranking
time was 278.36 ms and 248.89 ms respectively. That stage includes the hosted
request, ANN lookup and fusion, so this diagnostic narrows the investigation
but does not isolate the provider or clear the live-latency flags.

The [validation receipt and remaining-query catalog](../../evals/results/2026-09-11-followup-summary.json)
contain per-question top-five paths, both binary hashes, frozen source hashes,
the new holdout freeze, raw-report hashes and the rejected-trial ledger.
The full raw reports remain under `/Users/blackfloofie/tmp/codedb-followup-evidence`.
No release, installed-client replacement or deployment happened here.
