# subagent sa-017-b4b6eb3e

- label: Benchmark strategy audit
- kind: workflow_task
- status: ok
- elapsed_ms: 153279
- tools: codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,bash,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb

## task

Review the codedb repo's benchmark and test surfaces to determine how to make performance claims about cold MCP search robustly, then inspect implementation paths for likely measurable next wins. Do not edit. Use codedb structural navigation first, especially src/benchmark.zig, benchmark scripts/tests, bootstrap/watcher/index. Explain which benchmarks measure true cold-start versus only scan, identify noisy or missing controls, and recommend a small reproducible A/B protocol. Also list only high-confidence code optimizations likely to move the ~0.93s MCP cold-search result, with locations and likely magnitude.

## report

## Verdict: **refuted**

The claimed **~0.93 s “MCP cold-search”** result is not supported by the repository’s benchmark evidence. The exact `0.93` figure I found is **0.93 ms**, not seconds, and is explicitly a **warm MCP query** result:

- `benchmarks/search-shootout/results/2026-05-21/react-run2.md:7,17–29`
  - says **“Iterations: 20 warm”** and **“codedb: MCP stdio (one server, many calls)”**.
  - `createElement` is `0.93 ms p50`.
- The same shootout separately calls `codedb <corpus> tree` to get its “cold index” time (`shootout.py:316–337`), then starts a fresh MCP server for the query measurements (`shootout.py:903–926`).
- Therefore the reported `1.13 s` “cold index time” in that report is a **CLI `tree` bootstrap**, not an MCP startup-to-first-search measurement. It cannot be combined with the `0.93 ms` warm MCP query result into a cold-MCP claim.

A claim would have survived if the harness had timed a newly spawned MCP process, with persisted state removed, through handshake/root resolution and the first correctness-checked `codedb_search` response.

---

## Attack run

I structurally inspected:

- `src/benchmark.zig`
- `src/bootstrap.zig`
- `src/watcher.zig`
- `src/background.zig`
- `src/commands.zig`
- `src/main.zig`
- `src/bench.zig`, `src/bench_edge.zig`
- `bench/run-benchmarks.{sh,py}`
- `benchmarks/search-shootout/shootout.py` and its result artifact
- MCP and index test surfaces, especially `src/test_mcp.zig`, `src/test_index.zig`, and `src/test_search.zig`
- CI scripts `scripts/run-bench-json.py`, `scripts/compare-bench.py`, and `.github/workflows/bench-regression.yml`.

The central counterexample is the shootout artifact itself: it labels the 0.93 value as warm and measures build time through another command and another process.

---

## What each benchmark actually measures

| Surface | What it measures | Why it is **not** cold MCP first-search |
|---|---|---|
| `src/benchmark.zig:298–349` / `zig build benchmark` | One direct `watcher.initialScan(..., skip_trigram=false)` plus in-process query loops | No MCP process, JSON-RPC, handshake, deferred-root handling, snapshot probing, background scan, persistence, mmap adoption, watcher, or first request. It is a scan/index microbenchmark. |
| `src/bench.zig:74–152` / `zig build bench` | In-memory MCP **tool dispatch** after `initialScan`; reports only `dispatch_ns` | It bypasses stdio transport and process startup. It is a warm dispatch benchmark, not even full MCP round trip. |
| `src/bench_edge.zig:103–208` / `zig build bench-edge` | Same in-memory dispatch model on a synthetic pathological corpus | Useful for hot-path regression coverage; not startup or cold MCP. Its cache “busting” mutates the Explorer but does not recreate a process or remove on-disk state. |
| `bench/run-benchmarks.sh:64–119` | One server, fixed sleeps, then averages repeated requests | It declares itself “MCP server (pre-indexed, warm queries)” at line 57. The `0.3s + 0.5s` sleeps are not readiness verification. |
| `bench/run-benchmarks.py:19–83` | One MCP process, one warm-up call, then average repeated calls | Explicitly warms each tool before timing (`time_mcp`, line 79). |
| Search shootout | Build a cold CLI index step, then a separate warm MCP latency phase | The current source of the 0.93 ms result; categorically not cold MCP search. |
| `scripts/e2e_mcp_test.py` | Functional MCP lifecycle/root-resolution checks | It verifies behavior and waits for scan completion, but does not collect startup or first-search latency distributions. |
| `src/test_index.zig:544–584`, `src/test_search.zig:2685–…` | Correctness equivalence for parallel scan and trigram build/mmap adoption | Valuable guards, but no performance assertions or phase budgets. |

### The production MCP cold path is different

For explicit-root MCP, `commands.runMcp`:

1. loads a snapshot (`src/commands.zig:453–466`);
2. if unavailable, spawns `background.scanBg` (`:457–459`);
3. runs `watcher.initialScan(..., skip_trigram=true)` (`src/background.zig:44–58`);
4. persists the word index (`:73–75`);
5. builds trigrams from the content cache in parallel (`:130–162`);
6. writes the trigram index, then mmaps/adopts it (`:154–181`);
7. only then marks `scan_done` and MCP state ready (`:185–186`).

For implicit-root MCP, the same work is additionally delayed behind the MCP roots handshake/deferred-root mechanism (`src/main.zig:297–304`, `src/background.zig:203–225`, `src/mcp.zig:45–67`). A benchmark that does not specify explicit versus negotiated root is measuring an ambiguous workload.

`bootstrap.coldLoadOrScan` is **not** the MCP cold path: it immediately returns for `cmd == "mcp"` (`src/bootstrap.zig:387`). It is nevertheless relevant as a related CLI cold-load path and contains useful profiling.

---

## Missing controls and major noise sources

1. **No end-to-end cold definition.**  
   Existing benchmarks do not distinguish:
   - executable spawn → initialize response;
   - initialize/root negotiation → scan-ready;
   - executable spawn → first `codedb_search` response;
   - scan-ready → first search;
   - persisted-snapshot load versus no persisted state.

2. **Wrong execution path.**  
   `src/benchmark.zig:304–311` measures `watcher.initialScan` directly. The production MCP route is `commands.runMcp → background.scanBg`, with intentionally different choices: `skip_trigram=true`, background work, word persistence, cache-based parallel trigram construction, disk write, and mmap adoption.

3. **Stale or contradictory automation.**  
   `scripts/run-bench-json.py:11,32` invokes `zig build bench -- --json`; that runs `src/bench.zig`, whereas its description and the related code imply the repo benchmark JSON shape. `src/bench.zig` emits `{"tools":[...]}`, while `src/benchmark.zig` emits `{"queries":[...]}`.  
   `scripts/compare-bench.py:20–23` expects `tools`, so CI compares the in-memory dispatch benchmark—not `src/benchmark.zig` scan results. This is a strong counterexample to any claim that benchmark CI protects cold MCP search.

4. **Single average hides both tails and thermal/cache effects.**  
   `src/benchmark.zig:80–123` and `src/bench.zig:136–152` calculate only arithmetic means. No per-run samples, min/median/p95/p99, confidence interval, or order randomization is retained. The edge benchmark at least records a minimum, but that is not a robust estimator either.

5. **Uncontrolled OS cache and storage state.**  
   “No snapshot” is only application-cold. It does not make directory metadata, source files, executable pages, or newly written index files cold in the kernel page cache. Results need separate labels:
   - **app-cold / cache-warm:** persisted codedb artifacts deleted, ordinary OS cache;
   - **machine-cold:** controlled reboot or privileged cache eviction, if available;
   - **snapshot-cold-load:** valid persisted snapshot/index exists but no server process exists.

6. **Uncontrolled concurrency and worker count.**  
   Default scan workers are `min(cpu_count, 8)` (`src/watcher.zig:1179–1188`); trigram and frequency builders use the same kind of CPU-derived cap. CPU contention, power state, and host size directly change the result. Set and report `CODEDB_SCAN_WORKERS`, CPU affinity, governor/power mode where practical, and the build mode.

7. **Background work can contaminate measurements.**  
   MCP starts telemetry, a watcher, a thin CLI listener, auto-update checking, and warmup (`src/commands.zig:395–419`, `:467–489`). Warmup waits for ready, so it should not change scan-ready directly, but it can affect a measurement that starts querying immediately afterward. Disable or separately report it.

8. **No phase visibility for the most relevant path.**  
   `CODEDB_INDEX_PROFILE` gives useful phase output for normal scan and CLI bootstrap:
   - scan collection / parsing / commits / joins / shard merge: `src/watcher.zig:691–843`;
   - word persistence, trigram build/write/mmap, frequency, centrality, snapshot: `src/bootstrap.zig:449–623`.
   
   But `initialScanWithTrigrams`—the specialized cold CLI-search route—has no corresponding phase instrumentation (`src/watcher.zig:1040–1176`). More importantly, `background.scanBg`, the MCP route, has no structured timing output for its scan → word persist → trigram build → write → mmap critical path.

9. **Correctness is not tied to timing.**  
   The shootout admits hit counts are not comparable (`react-run2.md:22`). A cold benchmark must validate expected files/lines before treating a fast response as a successful search; otherwise a partial scan or wrong-root response can appear as a win.

---

## Small, reproducible A/B protocol

Use this before accepting any performance claim.

### Fixed workload

- Pin one immutable corpus revision and report:
  - commit/hash;
  - file count, indexable bytes, language mix;
  - query set and expected matching files/lines;
  - binary commit, Zig version, `ReleaseFast` status;
  - CPU model/core count, RAM, OS/filesystem.
- Use **explicit root**: `codedb <absolute-corpus-path> mcp`. This avoids three-second deferred-root fallback behavior and makes the workload unambiguous.
- Use 3–5 representative queries: rare identifier, common identifier, short trigram, multiword/ranked query, negative query.
- Make the first measured query fixed per trial and validate its result against precomputed ground truth.

### Two modes; never call both “cold”

1. **App-cold MCP first usable search**
   - Delete only that corpus’s codedb project artifacts/snapshot/word/trigram state before every trial.
   - Spawn a new MCP process.
   - Send `initialize`, `initialized`, then the first `codedb_search`.
   - Measure monotonic time from `Popen` immediately before exec to the completed search response.
   - Record scan state transitions if exposed, plus response correctness.
   - This is the most useful normal-user cold metric, but label it **OS-cache-warm unless cache state was controlled**.

2. **Snapshot cold-load MCP first search**
   - Prebuild exactly one valid state with a separate setup run.
   - Kill all codedb processes.
   - Start a new MCP server and send the same first search.
   - Measure spawn → response, separately reporting snapshot-load completion and search time.
   - This quantifies the common “server absent, index present” case; it must not be conflated with no-index cold start.

### Controls

- Set `CODEDB_SCAN_WORKERS=<fixed N>`—e.g. physical cores capped at 8—and report N.
- For diagnostic runs, set `CODEDB_NO_WARMUP=1`; also disable telemetry/auto-update if the supported switches are available. Run one production-default series separately.
- Ensure no existing codedb process/CLI daemon is serving the corpus.
- Disable search-cache influence with `CODEDB_NO_SEARCH_CACHE=1`; each fresh process already avoids prior in-memory cache, but the flag makes accidental repeats explicit.
- Alternate builds **A/B/B/A** on each trial rather than running all A then all B.
- Run at least 15 independent process trials per build; report raw samples, median, p90/p95, min/max, and bootstrap CI for median difference. Do not use a single average as the decision rule.
- For true machine-cold claims, reboot between randomized trials or use a documented privileged cache-eviction mechanism. Otherwise explicitly state **not disk-cold**.

### Required phase output

For each app-cold trial, emit structured JSON timings:

`exec_to_initialize`, `snapshot_probe`, `walk_collect`, `parse_commit`, `word_persist`, `trigram_build`, `trigram_write`, `trigram_mmap_adopt`, `scan_ready`, `first_search_dispatch`, `first_search_response`, `result_count`, and `ground_truth_pass`.

The existing profile points are a starting point, but stderr prose is not sufficient for automated A/B analysis.

---

## Likely measurable next wins — high confidence only

These are limited to work demonstrably on MCP’s scan-ready critical path. Exact savings are **not currently defensible** because that path lacks phase measurements; estimates below are bounded by the phase removed from the critical path, not promises.

1. **Move word-index persistence out of the MCP readiness critical path**  
   **Location:** `src/background.zig:73–75`  
   `scanBg` calls `persistWordIndexToDisk` before it builds trigrams and before `scan_done=true`. The in-memory word index has already been built by the initial scan’s worker shards where enabled (`src/watcher.zig:762–820`). Persisting it is durability for future processes, not a prerequisite for the current process to answer a search.

   **Why high confidence:** it is synchronous disk work before ready, and moving it after ready cannot make current-process index contents less complete.  
   **Likely cold-ready impact:** save up to the measured `word_persist` wall time; plausibly tens to hundreds of milliseconds on a medium corpus, but measure first.  
   **Caveat:** a crash before deferred persistence sacrifices next-process reuse; this is a durability/startup trade, not a free deletion.

2. **Adopt the completed heap trigram index before disk write + mmap; persist/remap afterward**  
   **Location:** `src/background.zig:139–181`  
   The parallel builder returns a queryable `tmp_tri`, but the current route writes it to disk and then mmaps it before setting ready. The first query needs a correct trigram index; it does not inherently need that index to be mmap-backed. Adopt `tmp_tri` as heap state for readiness, then write/remap in background when safe.

   **Why high confidence:** `tmp_tri` is the fully built index immediately before `tri.writeToDisk`; disk persistence and mmap adoption are separate from index construction.  
   **Likely cold-ready impact:** save up to `trigram_write + trigram_mmap` from the first-ready path—typically storage-dependent milliseconds to low hundreds of milliseconds.  
   **Caveat:** transient RSS rises and first-query performance may differ from mmap behavior; correctness and memory limits must be tested. This improves first usable search, not necessarily steady-state RSS.

I do **not** consider “parallelize the serial commit/merge loop” or “add more scan threads” high-confidence wins yet. `initialScanWithWorkerCount` already overlaps parsing with serial commit (`src/watcher.zig:795–824`), and trigram construction is already parallelized (`src/background.zig:130–162`; `src/watcher.zig:928–1037`). Without MCP-path phase measurements, claiming a gain from further parallelism would be speculation and risks worsening I/O contention or tail latency.

---

## Bottom line

- **Do not claim 0.93 ms—or any derivative of it—as cold MCP search.**
- The repository currently has useful **warm dispatch**, **warm MCP**, **scan-only**, and **CLI bootstrap** benchmarks, but no valid end-to-end cold MCP first-search benchmark.
- First make the measurement precise and reproducible; then the two persistence operations immediately before `scan_done` are the only currently high-confidence candidates for reducing first-usable-search latency.
