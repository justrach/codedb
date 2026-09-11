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

## Observable latency and an inspectable failure catalog

The ANN layer already measures remote embedding time, but the MCP retrieval
receipt omitted it. The follow-up now exposes that measurement as
`ann_embed_ns`, alongside `ann_load_ns` and `ann_search_ns`. This is an additive
diagnostic field. Ranking, candidate breadth and provider deadlines are unchanged.
Zero on a non-ANN result is not a measured provider duration.

Both the released source and the frozen candidate were rebuilt with the same
two-line field/assignment instrumentation. Stable ReleaseFast copies were used
for a new 148-question diagnostic with three alternating repeats: 888 calls,
all using the calibrated hosted-Jina mmap path, with no failed/fallback samples
and no rank changes from the frozen run. All seven repositories were already
observed. This run does not create a new holdout or replace the accuracy freeze.

The [portable dashboard receipt](../../evals/results/2026-09-11-followup-dashboard.json)
contains the new binary hashes, raw report hashes, warm sample counts, stage
distributions and every threshold flag. Cold generation validation is excluded
from the following timing comparison; each arm has 95 warm OpenClaw calls,
47 Express calls and 59 calls for each other repository.

| Repository | Candidate median embedding share of wall time | Median wall minus embedding, release → candidate |
| --- | ---: | ---: |
| OpenClaw | 98.07% | 13.95 → 12.42 ms |
| Express | 97.57% | 14.44 → 13.42 ms |
| Flask | 97.98% | 13.73 → 11.85 ms |
| Chi | 97.90% | 11.11 → 12.08 ms |
| Anyhow | 97.64% | 11.90 → 15.16 ms |
| Requests | 98.17% | 11.73 → 14.06 ms |
| ItsDangerous | 97.99% | 14.05 → 14.81 ms |

Embedding includes transport, service execution, decoding and bounded retry.
The remainder includes local computation, process scheduling and MCP overhead;
it is not a CPU measurement. We subtract each call's embedding duration before
computing remainder percentiles, rather than subtracting unrelated percentiles.

Warm wall-time p95 remains flagged for Anyhow (+16.2%), Requests (+185.9%) and
ItsDangerous (+10.4%). Their embedding p95 moves in the same direction. Requests'
p95 is 1,585 → 4,533 ms in the warm subset. These small-sample tail estimates are
sensitive to individual slow calls and to removing the cold observation; retain
the warm sample counts when comparing them with the earlier all-call results.
The evidence supports a large hosted-operation contribution, but does not
identify a specific DNS, network or server cause. No claim is made that the
transient retry repairs provider reliability.

The >10% local/overhead review flags also remain: Anyhow's median remainder rises
3.26 ms, Requests' rises 2.33 ms, Anyhow's ANN p95 rises 0.088 ms, and Flask and
Requests have load-check increases below 0.05 ms. This is still not a passed
performance gate. Use exact local stage profiling and more independent timing
windows before attributing the remainder to a ranking-code regression.

The data exporter verifies hashes, validates all repetitions, rejects fallback
samples, and keeps unique-question counts separate from repeated calls. Its
interactive view filters by repository, cohort and outcome, expands expected
versus returned paths, and shows lexical/semantic lane evidence. It also exports
11 comparison cases for further investigation:

- Four expected files are lexical rank zero but lose after fusion: the two
  OpenClaw auth behavior queries, Express dispatch, and Requests redirect methods.
- Seven other misses retrieve the expected file through ANN but favor related
  files. This is a diagnostic grouping, not proof of one common root cause.
  The Requests adapter-test regression is the first priority in this group.

Source spot-checks confirmed that the OpenClaw auth-mode assertion and mode
precedence live in the expected files; Flask's expected file emits the signals
while the competing file declares them; Requests' adapter test contains the
requested leading-separator assertion. The gold labels were not changed.

Use these observed comparisons to test general behavior/call-site and test-symbol
evidence, with the six existing first-result improvements as regression guards.
Do not patch individual query IDs or repository paths, train a local model, or
claim these cases as unseen validation. Any next ranking candidate needs a new
frozen holdout before promotion. The nine original first-result misses, two later
holdout misses, and Requests' second-to-third regression are still unresolved.

Validation of the timing-field change: `zig build test --summary all` succeeded
on all 33 build steps (1,137 tests passed, nine skipped in the rerun groups;
other groups cached); MCP end-to-end checks passed 76/76. The exporter passed
four tests covering rejected fallback/incomplete/hash-mismatched reports,
missing timing instrumentation, warm-only samples, per-call remainders and
invalid numeric values. JavaScript syntax, Zig formatting and whitespace checks
passed. The watcher mutation and cross-platform evidence above belongs to the
previous frozen runtime; this follow-up did not repeat those measurements or
ship a new release.
