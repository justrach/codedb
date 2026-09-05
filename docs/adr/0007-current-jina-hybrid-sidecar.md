> Objective correction: the user prioritizes retrieval accuracy. The 2× pool
> candidate was discarded and the original 4× pool restored because it did not
> improve accuracy. The timings below are historical measurements, not a reason
> to reduce retrieval breadth. Subsequent work targets ranking quality.

# ADR 0007: Correct target — hosted Jina and default hybrid OpenPuffer integration

Status: current architecture verified live; sidecar search experiments below.

## Correction

The user explicitly specified default hybrid retrieval through the existing
hosted Jina embedding service and CodeDB/OpenPuffer integration. The earlier
work mistakenly evaluated obsolete `main` with Qwen and a local-only default.
ADRs 0001–0006 are historical wrong-target work, not decisions for the current
system. Their cached-score hill climb cannot establish Jina hybrid quality.
The agent handoff documents now lead with this correction.

## Actual integration

Inspected current source: `release/0.2.5852` at `b72db9b`. The installed
`/Users/blackfloofie/bin/codedb` is 0.2.5852. Live commands verified:

1. Default `context` is hybrid; no opt-in semantic flag is required.
2. Without a compatible sidecar, hybrid calls the hosted service for bounded
   exact reranking (`applied_exact_fallback`). This remains part of the system.
3. `semantic-index` sends safe code chunks to the existing hosted Jina service
   and builds the local OpenPuffer generation. The actual metadata reports
   `jinaai/jina-embeddings-v2-base-code`, 512 dimensions, `CDBANN03`.
4. With that sidecar, each default context request sends query + fixed public
   calibration text in one hosted request. The calibration vector must match
   the generation's vector space before local ANN search.
5. OpenPuffer searches a local memory-mapped slab, deduplicates chunk hits into
   files, and CodeDB fuses them with lexical results using its current
   intent-aware policy. Persistent MCP sessions cache the loaded generation.

Neither the embedding model nor a GPU trainer runs locally. The embedding
service was already deployed; these experiments change no server configuration.

## Live evaluation protocol

[jina_hybrid_live.py](../../evals/jina_hybrid_live.py) measures no-sidecar and
sidecar calls using default CLI behavior. It pins the public source corpus and
verifies the model in the newly built sidecar metadata. CLI daemon reuse is
disabled only for the cold-process comparison.

[jina_sidecar_compare.py](../../evals/jina_sidecar_compare.py) runs two persistent
MCP sessions against the **same Jina sidecar**, alternating baseline/candidate
request order. Both make real hosted requests for every sample; no cached-score
policy replay. Requests omit the `semantic` field. Each must report
`ann_applied`, two query/calibration inputs, and mmap-backed storage. Three
repeats of 16 previously seen positive queries give 48 calls per binary. This
is a regression diagnostic, not fresh held-out generalization evidence.

The first trial changes only chunk candidate oversampling before file
deduplication: 4× (baseline) versus 8×. The next checks 2×. Neither changes
Jina, service authentication, sidecar format, embedding vectors, fusion weights,
or the hybrid default. Candidate changes live in a separate experiment worktree;
the installed binary is unchanged. Live baseline exact-fallback and sidecar
successes are distinguished from provider failures.

## Initial evidence

- [Installed-client baseline](../../evals/results/2026-09-05-jina-hybrid-installed.json):
  all calls passed. Cold-process no-sidecar NDCG 0.8452; sidecar NDCG 0.9144;
  recall 0.9375 for both. Built 473 code chunks across 34 public source files.
- [4× versus 8×](../../evals/results/2026-09-05-jina-sidecar-pool8.json): both
  NDCG 0.9144 and recall 0.9375. Average distinct ANN files rose 15.69 → 22.44,
  but mean ANN search rose 0.267 → 0.414 ms. Median full-call latency was
  169.36 → 169.31 ms; p95 264.66 → 295.39 ms. Each session had 47/48 sidecar
  cache hits, and no provider failures. Reject 8×: no quality gain, extra search
  work, and this run exceeded the 10% p95 regression gate.

Provider and machine-load variation affect end-to-end latency; these figures
are observations, not proof that pool size alone caused the p95 change. The
local ANN search is only a small portion of the full service-backed request.


## Discarded 2× experiment

[4× versus 2×](../../evals/results/2026-09-05-jina-sidecar-pool2.json) preserved
NDCG 0.9144 / recall 0.9375. Mean ANN search fell 0.269 → 0.178 ms (33.7%).
Full-call median was 166.35 → 166.94 ms and p95 209.22 → 222.56 ms, so there
was no demonstrated end-to-end speedup. Mean distinct candidate files fell
15.69 → 10.75.

The [additional 16-question regression set](../../evals/results/2026-09-05-jina-sidecar-pool2-regression.json)
also preserved every query's relevance metrics: NDCG 0.8995 / recall 1.0. Mean
ANN search fell 0.076 → 0.049 ms (35.9%); distinct candidates fell 14.94 → 9.81.
This set was previously used in obsolete experiments and is explicitly a
regression set, not fresh held-out validation. Compilation ran concurrently
with this second comparison, so its latency numbers are not a clean standalone
performance benchmark. All measured calls used the real hosted Jina service
and mmap sidecar, with no provider failures.

The 2× candidate was discarded and the original 4× restored. It did not
improve accuracy, the user's objective. These speed-only experiments are
historical; current native accuracy work and its validation are recorded in
[ADR 0008](0008-jina-hybrid-accuracy.md). Neither installed client nor hosted
service was replaced.
