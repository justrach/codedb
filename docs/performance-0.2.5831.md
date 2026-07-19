# codedb 0.2.5831 performance and recall report

This report records the performance, output-size, and retrieval-recall audit for
the `release/0.2.5831` line. The code candidate is commit
`0478eff8dbef2cd2daa6cbd7413d4529ba932d1d`.

The complete machine-readable measurements are in
[`bench/results/0.2.5831/results.json`](../bench/results/0.2.5831/results.json).
The JSON contains all 10 context tasks and all 22 edge-benchmark cases, including
results that did not improve.

## Headline results

| Area | Baseline | Candidate | Change |
|---|---:|---:|---:|
| `codedb_context` core tokens, 10 tasks | 13,288 | 4,848 | **−63.52%** |
| Client-visible context tokens | 13,763 | 4,975 | **−63.85%** |
| Context wire bytes | 51,973 | 18,130 | **−65.12%** |
| Context anchor hits | 14 / 29 | 14 / 29 | unchanged |
| Context macro task recall | 54.17% | 54.17% | unchanged |
| Edge-fixture cold scan | 123.299 ms | 87.092 ms | **−29.37%** |
| Hot-word output | 611,915 B | 371 B | **−99.94%** |
| Huge-outline output | 291,056 B | 16,152 B | **−94.45%** |
| Common-search output | 1,324,470 B | 1,766 B | **−99.87%** |

These are reductions in measured output, not estimates derived from source
line counts. The context benchmark uses token counts; the edge benchmark uses
exact response bytes.

## Context token and recall gate

The context suite contains three symbol-shaped tasks and seven natural-language
tasks. The exact manifest is
[`context-tasks.json`](../bench/results/0.2.5831/context-tasks.json). Both
binaries ran that identical task set, whose SHA-256 is
`e9f7d748a563de4ff95db91f66e821d81cdb1cada19bb3c3a7389279282bea02`.
Tokens were counted with tiktoken 0.13.0 using `o200k_base`.

| Task | Core tokens, before → after | Intent anchors hit | Recall, before → after |
|---|---:|---:|---:|
| `symbol_1` | 1,462 → 556 | 1 / 1 | 100% → 100% |
| `symbol_2` | 2,304 → 876 | 2 / 2 | 100% → 100% |
| `symbol_3` | 3,429 → 1,305 | 3 / 3 | 100% → 100% |
| `natural_perf` | 497 → 280 | 1 / 3 | 33.33% → 33.33% |
| `natural_security` | 743 → 248 | 2 / 4 | 50% → 50% |
| `natural_startup` | 895 → 50 | 1 / 4 | 25% → 25% |
| `natural_symbol_bug` | 885 → 443 | 0 / 3 | 0% → 0% |
| `natural_memory` | 850 → 433 | 0 / 3 | 0% → 0% |
| `natural_watcher` | 752 → 101 | 1 / 3 | 33.33% → 33.33% |
| `natural_with_symbol` | 1,471 → 556 | 3 / 3 | 100% → 100% |
| **Aggregate** | **13,288 → 4,848** | **14 / 29** | **unchanged on 10 / 10 tasks** |

Two recall summaries are published because they answer different questions:

- **Micro anchor recall: 48.28%.** This is `14 / 29`, so tasks with more
  anchors contribute more weight.
- **Macro task recall: 54.17%.** This averages the 10 per-task recall values so
  every task has equal weight.

The recall gate is parity, not a claim that 48.28% is the maximum achievable
retrieval quality. An anchor hit means a named intent marker appeared in the
returned context. It is a deterministic regression signal; it does not measure
semantic answer correctness, ranking quality, or whether an agent completed a
task successfully.

### Context provenance

The measured candidate was a pre-port audit binary reporting version
`0.2.5828`, SHA-256
`b1138c22fbb9e6136d4eb72c9f75e391792003fdfe5c99e6689cd07e2f5f778b`.
Its measured context behavior was ported to the 0.2.5831 code candidate. It was
not built from the final release-line commit, so the report does not present
that binary hash as a release artifact. The full provenance, timestamps, and
baseline hash are retained in the results JSON.

## Edge benchmark

The edge suite uses a generated 3,005-file, 4,519,505-byte project and runs:

```bash
zig build bench-edge -- --json
```

The baseline is commit `296e2abdfbde72ec5b26a781acdc8f35a065522a`
built with Zig 0.16.0. The candidate is commit
`0478eff8dbef2cd2daa6cbd7413d4529ba932d1d` built with Zig
0.17.0-dev.813+2153f8143. This is therefore a **release-line outcome** comparison:
output bytes are directly comparable, while latency includes both code changes
and the compiler migration.

Selected cases are below. Average latency and output bytes for every case are
available in the machine-readable results.

| Case | Average latency, before → after | Output, before → after | Output change |
|---|---:|---:|---:|
| `search_common` | 0.846 → 0.110 ms | 1,324,470 → 1,766 B | **−99.87%** |
| `search_scope` | 0.888 → 0.110 ms | 1,325,343 → 2,690 B | **−99.80%** |
| `search_longline` | 2.079 → 0.921 ms | 2,107,709 → 623 B | **−99.97%** |
| `search_miss` | 0.421 → 0.365 ms | 223 → 166 B | −25.56% |
| `symbol_exact` | 0.037 → 0.002 ms | 444 → 387 B | −12.84% |
| `outline_huge` | 0.130 → 0.008 ms | 291,056 → 16,152 B | **−94.45%** |
| `read_deep` | 0.305 → 0.019 ms | 1,984 → 1,929 B | −2.77% |
| `find_fuzzy` | 2.074 → 0.039 ms | 659 → 606 B | −8.04% |
| `word_hot` | 0.480 → <0.001 ms | 611,915 → 371 B | **−99.94%** |

`word_hot` reaches the benchmark timer's resolution floor after the result is
served from the bounded grouped representation; its byte reduction is the more
reliable measurement.

### Known remaining latency regressions

The audit deliberately retains regressions in the published evidence:

- `search_ranked` increased from 0.996 ms to 7.668 ms average, with essentially
  unchanged output size (1,823 B to 1,810 B). The uncached ranked path is the
  clearest next optimization target.
- `callers_hot` increased from 0.030 ms to 0.067 ms average while output fell
  from 5,400 B to 5,148 B.

Neither result is hidden by the aggregate improvements. Any follow-up should
profile these paths separately and preserve the context recall gate.

## Direct outline-pagination attribution

To isolate the final outline change from the compiler migration, the same
source tree and compiler were measured immediately before and after bounded
outline pagination:

| Measurement | Before | After | Change |
|---|---:|---:|---:|
| Average latency | 131.800 µs | 8.166 µs | **−93.80%** |
| Output | 290,982 B | 16,134 B | **−94.46%** |

This paired result directly attributes the improvement to pagination rather
than to the wider release line.

## What changed

The measured reductions came from compact grouped results, bounded pagination,
and removal of response overhead. The audit also found performance and
correctness issues that ordinary query timing did not expose:

- [`src/hot_cache.zig`](../src/hot_cache.zig) keeps large mmap snapshots as
  zero-copy content instead of evicting their contents after 4,096 files.
- [`src/index.zig`](../src/index.zig) removes a dangling pointer and one pointer
  of overhead from every trigram posting list.
- Paired trigram-cache files carry a shared generation nonce, preventing mixed
  cache adoption after an interrupted write.
- [`src/project_fs.zig`](../src/project_fs.zig) and
  [`src/snapshot.zig`](../src/snapshot.zig) use anchored, no-follow access for
  cache paths, snapshot sources, watcher notifications, MCP reads, and edits.
- [`src/mcp.zig`](../src/mcp.zig) strips terminal-control sequences from raw
  repository output and avoids ANSI formatting in plain MCP output.
- Zero-result responses no longer spend tokens on unusable follow-up guidance.

## Exploratory observations not promoted to release gates

The audit also observed the following on representative queries:

- grouped word results reduced tokens by 99.67% on hot identifiers;
- ordinary grouped search samples used 14.7–20.2% fewer tokens;
- warm word and search calls completed in roughly 0.10–0.69 ms; and
- recovered trigram caches made representative searches 5–52× faster than
  rebuilding or missing the cache.

Those observations motivated the durable edge cases above, but their original
raw samples were not retained with sufficient provenance. They are directional,
not release gates. The reproducible response-byte and context-token results are
the numbers used for release claims.

## Directional sandbox comparison

A separate trial explored
[`codedb` issue #679](https://github.com/justrach/codedb/issues/679) without
installing the competing engines into the workstation. It used the
[`sandbox-gateway` protocol](https://github.com/justrach/sandbox-gateway/blob/main/docs.md)
with `justrach/smolify` at commit
`835070d0826ab581f7efb564a1457b72c2bbe3da` (96 blobs, approximately 1.32 MB)
and the exact symbol `toFtsMatch`. Each tool ran in a separate Linux x86_64
sandbox with 2 vCPU and 2,048 MB on one gateway node.

| Tool | Cold index process time | Sampled cgroup peak | Warm CLI process measurements | Result |
|---|---:|---:|---:|---|
| codedb 0.2.5830 | 178 ms (74.7 ms internal) | 41,972 KiB | search 18/3/3 ms; callers 54/3/3 ms; context 18/3/3 ms | Definition, 8 search sites, 7 caller sites, narrowed context |
| codebase-memory-mcp 0.9.0 | 430 ms | 6,068 KiB | graph operations 16–23 ms | Exact symbol and inbound graph |
| GitNexus 1.6.9 | not measured | not measured | not measured | Tagged CLI rejected the documented `--skip-embeddings` flag |

This is deliberately not a winner table. Warm CLI times include process startup
and cache loading; graph traversal and textual callers/context are not
semantically identical; and codedb used the latest published 0.2.5830 binary,
not the unreleased branch. GitNexus 1.6.9 is PolyForm Noncommercial 1.0, so
commercial company use also requires license review. Sampled cgroup peaks are
directional because a short-lived process can finish between samples or report
zero. All sandboxes created for the trial were deleted after measurement; no
competing engine was installed locally.

## Verification

The code candidate passed:

```text
zig build test
zig build -Doptimize=ReleaseFast
python3 scripts/e2e_mcp_test.py --binary zig-out/bin/codedb --project <codedb-root>
```

The MCP suite passed all 20 scenarios. Formatting and diff checks also passed.
No deployment is represented by this report.

## Reproduction and interpretation rules

1. Use the exact commits and Zig versions recorded above when comparing the
   release line. Do not silently compare a debug binary to a release binary.
2. Run edge cases on an otherwise idle machine and retain the emitted JSON.
3. Compare output bytes even when a sub-millisecond timer reaches its resolution
   floor.
4. For context changes, run the identical task file and tokenizer and fail the
   change if any task loses anchor recall.
5. Keep semantic-answer evaluation separate from anchor recall. Both are useful;
   they measure different failure modes.
6. Report regressions alongside wins rather than collapsing all paths into one
   aggregate score.
