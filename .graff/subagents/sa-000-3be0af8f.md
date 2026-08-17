# subagent sa-000-3be0af8f

- label: benchmark and profiling audit
- kind: workflow_task
- status: ok
- elapsed_ms: 63188
- tools: codedb,codedb,codedb,read_file,read_file,read_file,codedb,codedb,read_file,read_file,read_file,read_file,codedb

## task

You are an expert Zig performance engineer auditing measurement and profiling in codedb (repo at /Users/rachpradhan/codedb). Recent benchmark: full initial scan ~2200ms, trigram-only cold scan ~430ms on 13,792 files. Focus on src/benchmark.zig, existing profiling points (CODEDB_INDEX_PROFILE), and any timing logs in src/watcher.zig and src/bootstrap.zig. Use the codedb tool (search/symbol/callers/outline/context) to inspect code before using bash. Look for: missing profiling granularity, benchmark artifacts not installed, unrepresentative iterations, and opportunities to measure subphases (walk, stat, parse, trigram build, merge, persistence). Propose concrete changes to improve measurement so we can optimize better. Maximum 5 findings. Do not edit files.

## report

## Audit summary: measurement and profiling in `codedb`

I inspected `src/benchmark.zig`, `src/bootstrap.zig`, `src/watcher.zig`, and `build.zig`. Below are the 5 most actionable measurement gaps, each with file/line citations and a concrete proposal.

---

### Finding 1: Benchmark reports only one coarse `index_ms`; subphase logs exist but are not captured or structured

**Evidence**
- `src/benchmark.zig:301-311` times the whole `watcher.initialScan(...)` call and stores only `index_ms` (`index_ns / ns_per_ms`).
- `src/watcher.zig:691-841` already emits `[index-profile] scan ... collect=... setup_spawn=... parse_commit=... join=... merge_free=...` when `CODEDB_INDEX_PROFILE` is set, but these lines go to `stderr` and are never parsed into the JSON / human output.
- `src/bootstrap.zig:449-607` emits even more subphase timings (`scan`, `word_persist`, `tri_build`, `tri_write`, `tri_mmap`, `freq`, `centrality`, `snapshot`, `other`) for the production cold path, but `benchmark.zig` does not exercise that path.

**Impact**
The reported ~2200ms full scan is a black box. Optimizers cannot tell whether a regression is in directory walk, stat, parsing, commit, word-index merge, or trigram indexing.

**Proposed change**
- Extend `BenchResult` (`src/benchmark.zig:69`) with subphase fields: `walk_ms`, `stat_ms`, `parse_ms`, `commit_ms`, `word_merge_ms`, `trigram_build_ms`, `trigram_merge_ms`, `persist_ms`.
- Plumb explicit timers through `watcher.initialScanWithWorkerCount` to split the currently lumped `collect` (walk + stat) and `parse_commit` (parse + commit) phases.
- Capture `CODEDB_INDEX_PROFILE` output and fold it into the JSON/human report.

---

### Finding 2: The `benchmark` executable is never installed

**Evidence**
- `build.zig:44` installs the main `codedb` binary: `const install_exe = b.addInstallArtifact(exe, .{});`
- `build.zig:174-187` defines the repo benchmark executable and a `benchmark` step, but there is no corresponding `b.addInstallArtifact(benchmark, .{})`.

**Impact**
`zig build install` does not place a `benchmark` binary in `zig-out/bin`. You can only run it through `zig build benchmark`, which makes it harder to profile the binary directly, ship it, or run it against multiple repos outside the build directory.

**Proposed change**
Add `b.addInstallArtifact(benchmark, .{})` and make the `benchmark` step depend on it, mirroring the main executable setup.

---

### Finding 3: Uniform iteration count is unrepresentative across query kinds; the reindex sample is tiny

**Evidence**
- `src/benchmark.zig:22` defaults to `iterations: usize = 50` and applies that same count to search, word, symbol, and cached queries.
- `src/benchmark.zig:170-172` hardcodes `cycles = 5` and at most 10 files in `benchReindex`.
- `src/benchmark.zig:85-127` measure per-query total time and divide by `n`; there is no per-kind calibration.

**Impact**
Search, word, symbol, and cached-hit latencies differ by orders of magnitude. A single `50` under-samples slow symbols and over-samples sub-microsecond cached hits. The reindex measurement is too small to surface allocator/GC effects.

**Proposed change**
- Introduce per-kind iteration flags (`--iterations-search`, `--iterations-word`, `--iterations-symbol`, `--iterations-reindex`) or switch to fixed-duration sampling with a minimum iteration count.
- Increase `benchReindex` sample size and report throughput as `files/sec` in addition to `id_to_path` growth.
- Report `min/max/stdev` alongside `avg_ns` to catch tail latency.

---

### Finding 4: The benchmark calls `watcher.initialScan` directly, missing the real production cold-load pipeline

**Evidence**
- `src/benchmark.zig:301-311` calls `watcher.initialScan(io, &store, &explorer, root, alloc, false)`.
- The production cold path is `src/bootstrap.zig:372-626` `coldLoadOrScan`, which additionally loads snapshots, persists the word index, builds trigrams from the content cache, builds the frequency table, builds call-graph centrality, and persists a project snapshot.
- `src/bootstrap.zig:530-535` and `src/bootstrap.zig:606-607` show these post-scan phases can be hundreds of milliseconds, yet they are absent from the benchmark.

**Impact**
The benchmark’s “full initial scan” is not the full cold start a user or the CI server experiences. Optimizations to snapshot persistence, trigram mmap, or frequency-table construction are invisible to this benchmark.

**Proposed change**
Add a `--cold` flag (or change the default) to run `bootstrap.coldLoadOrScan` with `cmd = "bench-engine"` and capture every `CODEDB_INDEX_PROFILE` subphase into the result JSON. Keep a `--scan-only` mode for the current micro-benchmark.

---

### Finding 5: `initialScanWithTrigrams` — the trigram-only cold scan path — has no profiling instrumentation

**Evidence**
- `src/watcher.zig:1040-1177` (`initialScanWithTrigrams`) has no `profile` variable, no `cio.nanoTimestamp()` calls, and no `[index-profile]` print.
- In contrast, `src/watcher.zig:691-841` (`initialScanWithWorkerCount`) and `src/watcher.zig:930-1032` (`buildTrigramsFromCache`) both have full `CODEDB_INDEX_PROFILE` instrumentation.
- `src/bootstrap.zig:483` uses `watcher.initialScanWithTrigrams` for the `search` cold-start path.

**Impact**
The ~430ms trigram-only cold scan cannot be decomposed into walk/stat, outline parsing, trigram extraction, shard building, and shard merging. This is exactly the path the user wants to optimize.

**Proposed change**
Add the same profiling structure to `initialScanWithTrigrams`:
- `profile_start` before entry collection
- `profile_collect_done` after `collectInitialScanEntries`
- `profile_spawn_done` after thread spawn
- `profile_build_done` after workers finish
- `profile_merge_done` after `mergeBulkShard`
- Emit `[index-profile] trigram-scan files=... workers=... outline=... collect=... spawn=... build=... merge=... total=...`

---

## Most load-bearing facts

1. **`src/benchmark.zig` measures only `watcher.initialScan`**, not the production `bootstrap.coldLoadOrScan` path, so the reported 2200ms omits persistence and post-scan index builds. (`src/benchmark.zig:301-311`, `src/bootstrap.zig:372-626`)
2. **The `benchmark` executable is built but never installed**, so `zig build install` produces no `zig-out/bin/benchmark`. (`build.zig:44`, `build.zig:174-187`)
3. **`initialScanWithTrigrams`, the path used for the ~430ms trigram-only cold scan, has zero `CODEDB_INDEX_PROFILE` instrumentation**, making it impossible to decompose into walk/stat/parse/trigram-build/merge. (`src/watcher.zig:1040-1177`)

## Open question

Should the repo benchmark be restructured to run the production `bootstrap.coldLoadOrScan` path (full cold-start fidelity, including all persistence phases) and report every subphase, or should it remain a targeted `watcher.initialScan` micro-benchmark with added timers?
