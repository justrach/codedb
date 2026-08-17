# subagent sa-023-b38a4deb

- label: Synthesize optimization plan
- kind: workflow_task
- status: ok
- elapsed_ms: 85694
- tools: codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb!,codedb,codedb,codedb,codedb!,codedb,codedb,codedb,codedb,codedb,codedb!,codedb

## task

You are the lead performance engineer for the codedb repository. Below are three independent audits of possible cold-search/indexing performance wins after recent parallelization. Do not edit files. Reconcile the reports with the repo using codedb structural tools first if any details need checking. Produce a concise decision memo: (1) the single best low-risk next implementation, or explicitly say no candidate is justified; (2) exact code-level plan including affected functions and failure/correctness behavior; (3) how it will be benchmarked against the current HEAD; (4) optional follow-ups ranked by payoff. Do not suggest speculative changes without evidential support.

AUDIT REPORTS:
### Trace cold startup path
## Scope and traced MCP cold path

I made no changes. I first traced the structural call graph with `codedb` symbols/callers/dependencies, then inspected the relevant symbol bodies.

### Verified path

1. `mainImpl` creates the shared threaded I/O object, allocator, `Store`, and `Explorer`; its normal bootstrap call site is `bootstrap.coldLoadOrScan` at `src/main.zig:448`. However, `coldLoadOrScan` immediately returns for `cmd == "mcp"`, so it is **not** the actual MCP cold-indexing path. [src/main.zig:L130-L140; src/main.zig:L417-L421; src/main.zig:L448; src/bootstrap.zig:L387]

2. `commands.runMcp` is the MCP bootstrap owner. For an explicit root it:
   - gets Git HEAD;
   - synchronously attempts `loadBestSnapshot`;
   - starts `background.scanBg` if no valid snapshot loads;
   - starts `watcher.incrementalLoop`;
   - enters `mcp_server.run`.  
   [src/commands.zig:L453-L468; src/commands.zig:L488-L489]

   For an implicit-CWD root, it defers the root decision until the MCP roots handshake; `triggerScanFromRoots` then performs the same snapshot-or-`scanBg` decision. [src/commands.zig:L434-L451; src/background.zig:L203-L225]

3. Snapshot eligibility is Git-HEAD based. `loadBestSnapshot` tries `<root>/codedb.snapshot`, then the central snapshot; each candidate first reads its 44-byte-ish header/HEAD and only deserializes if it matches the current HEAD. [src/bootstrap.zig:L37-L53; src/bootstrap.zig:L56-L75; src/snapshot.zig:L503-L523]

4. On a cold MCP start, `scanBg`:
   - checks the on-disk trigram header/HEAD;
   - sets `word_index.skip_file_words = true`;
   - calls `watcher.initialScan(..., skip_trigram=true)`;
   - persists the word index;
   - either loads a matching trigram index or builds trigrams from `Explorer.contents`, writes them, and mmaps them;
   - sets `scan_done` and MCP scan state to `ready`;
   - **then** emits a snapshot and may release cache/index memory.  
   [src/background.zig:L35-L58; src/background.zig:L73-L98; src/background.zig:L130-L186; src/background.zig:L190-L201]

5. `initialScan` uses up to `min(cpu_count, 8)` workers unless `CODEDB_SCAN_WORKERS` overrides it. Its initial collector serially walks/filter paths, duplicates every path, then runs a separate stat-and-`Store.recordSnapshot` phase. [src/watcher.zig:L527-L599; src/watcher.zig:L1179-L1189]

6. The scan workers parse files concurrently, but the main thread commits their results to shared `Explorer` structures serially and in static worker/chunk order. Each commit acquires `Explorer.mu`, updates outlines/content/dependencies/symbol index, and duplicates content into `ContentCache`. [src/watcher.zig:L762-L824; src/watcher.zig:L663-L688; src/explore.zig:L1511-L1615; src/hot_cache.zig:L151-L231]

7. Cold search-dependent MCP tools wait for `ready` using a 25 ms polling loop (up to the configured timeout); therefore initial-scan, word persistence, trigram build/write/mmap are directly on the cold-search critical path. Snapshot writing is not, because readiness is published first. [src/mcp.zig:L808-L815; src/mcp.zig:L1436-L1444; src/background.zig:L185-L195]

---

## Ranked candidate changes

Impact rankings are hypotheses, not measured results. The suggested benchmarks should be run on both a many-small-file repository and a byte-skewed repository, with a deleted project cache/snapshot for each cold trial.

### 1. Stream trigram persistence instead of materializing the complete postings blob
**Expected impact: High peak-RSS reduction; medium-to-high cold-ready latency improvement on large trigram indexes.**

**Evidence.** `TrigramIndex.writeToDisk` first creates:
- a complete file table plus a path→disk-ID hash map;
- a `doc_to_disk` array;
- sorted trigram keys;
- a complete `postings_buf`;
- a complete `lookup_entries` buffer.  
Only after fully building `postings_buf` does it write the postings file. [src/index.zig:L1721-L1800] The MCP scan cannot publish `ready` until `writeToDisk` completes and the written index is remapped/adopted. [src/background.zig:L154-L186]

**Concrete change.** In `TrigramIndex.writeToDisk` (`src/index.zig:L1721-L1879`), retain sorted trigram keys and the small lookup table, but write each posting list directly into the temporary postings writer while tracking a running `u32` posting offset. This removes `ArrayList(DiskPosting) postings_buf`; the lookup record can be appended per trigram. If lookup entries are also material at very large cardinalities, write a temporary lookup stream or pre-size/write it after counts are known.

**Correctness risks.**
- Preserve exactly the existing sorted-trigram order and every posting-list order.
- Validate `u32` posting offsets/counts before serialization.
- Keep the two-file atomicity failure semantics: the current code atomically renames postings and lookup independently, so changing write order needs compatibility validation with the mmap loader.
- Do not mutate heap posting lists while serializing.

**Minimal benchmark.**
1. Cold-start MCP with no snapshot and no trigram disk files.
2. Record time from MCP initialization to the first index-dependent `codedb_search` response; capture peak RSS.
3. Compare `trigram write` time and total ready time using existing `CODEDB_INDEX_PROFILE`; the build already exposes distinct trigram-build/write/mmap phases in the CLI profile path. [src/bootstrap.zig:L549-L568; src/bootstrap.zig:L612-L622]
4. Verify

…[13985 chars truncated — full result in the inspect file below]…

L1615]  
3. **Trigram disk persistence constructs a whole in-memory postings blob before writing, directly before readiness.** [src/index.zig:L1773-L1846; src/background.zig:L154-L186]  

## Open question

What do real cold-MCP profiles show for the relative shares of **serial Explorer commit/word-shard merge**, **trigram serialization**, and **scan-result allocation/copying** on the target large repositories? Existing profiling exposes coarse scan and trigram phases but does not isolate those three costs sufficiently.

[subagent sa-019-d9ede167 · inspect: .graff/subagents/sa-019-d9ede167.md]

### Audit index build hot loops
**P0 — trigram file-count cap is bypassed by the parallel cache builder.**  
`src/watcher.zig:953-957` includes every cached file ≤1 MiB, but never applies `trigramFileCap()`; `collectInitialScanEntries` enforces that cap only at `src/watcher.zig:537,593-598`. Both `background.scanBg` (`src/background.zig:144`) and the cold path call `buildTrigramsFromCache` after deliberately deferring per-file trigram indexing. A large repository can therefore exceed `CODEDB_TRIGRAM_CAP`, defeating its RSS bound.  
**Fix:** carry the scan’s ordered trigram-eligibility decision into the cache builder (or pass an ordered eligible-entry slice). Do not cap a `ContentCache` hash-map iterator directly: that would change discovery-order semantics and make coverage nondeterministic.

**P1 — parallel stat loop has a data race and loses its intended speedup.**  
`statScanForInitial` concurrently reads/writes shared `*?anyerror` at `src/watcher.zig:517,521`. Its callers spawn several workers with the same pointer (`src/watcher.zig:579`). Also every `store.recordSnapshot` serializes under `Store.mu` (`src/store.zig:80-81`), making the hot loop lock-contended and assigning snapshot sequence numbers in scheduler-dependent order.  
**Fix:** workers should only `statFile` into disjoint `InitialScanEntry.size` fields and write per-worker error slots; after joining, serially call `recordSnapshot` in `entries` order. This removes the race, restores deterministic sequence order, and makes stat parallelism useful.

**P2 — static file-count sharding causes severe trigram/word stragglers.**  
`buildTrigramsFromCache` partitions by number of files (`src/watcher.zig:997-1005`), while work is proportional to bytes/unique trigrams. A chunk containing several near-1 MiB files dominates completion; the same issue exists for word shards in `initialScanWithWorkerCount` (`src/watcher.zig:776-783`).  
**Fix:** form contiguous, byte-weighted ranges from the already-collected entries. Preserve range order and merge in range order, so doc IDs, posting order, serialization, and result determinism remain unchanged. Dynamic work stealing is faster in the worst case but risky unless document IDs are assigned independently of completion order.

**P3 — frequency parallelism has a fixed merge/memory tax that can exceed counting work.**  
`buildFrequencyTableFromMapParallel` allocates and clears one 512-KiB `[256][256]u64` table per worker (`src/index.zig:3295-3298`), then merges all 65,536 cells per worker (`3318-3326`), even for many tiny files. It also allocates a slices array merely to distribute borrowed cache values (`3279-3286`). Bootstrap falls back safely to serial on failure (`src/bootstrap.zig:578-579`).  
**Fix:** accumulate total eligible bytes while collecting slices and stay serial below a byte threshold; retain `u64` counters and the existing serial fallback. This is result-identical absent impossible corpus-scale `u64` overflow. Replacing counters with `u32` is risky because saturation changes relative pair weights.

**P4 — trigram merge still copies collision postings and repeatedly reallocates them.**  
`TrigramIndex.mergeBulkShard` offsets every posting (`src/index.zig:1476`) and transfers only first-seen terms when allocators match (`1481-1484`); a term seen in later shards is copied by `appendSlice` (`1487`). Common non-whitespace trigrams therefore incur repeated growth/copy during the serial merge.  
**Candidate:** first pass over shards to count per-trigram postings, reserve destination list capacity, then perform the existing ordered merge. Safe only if shard order remains fixed; it adds a full hash-map pass and may regress small corpora. The current path correctly preserves sorted posting IDs because chunks are contiguous and merged in order.

**P5 — avoid “simplifying” worker extraction through the existing helper without changing its error contract.**  
`cachedTrigramBuildWorker` correctly treats local-map allocation failure as build failure (`src/watcher.zig:910-913`), whereas `TrigramIndex.extractTrigrams` silently continues on `getOrPut` failure (`src/index.zig:1379`). Reusing that helper would turn OOM into a partial index and false-negative search results.  
**Fix:** factor the duplicate extraction loops only into a fallible helper returning `!AutoHashMap`; retain worker failure propagation and the current “do not adopt/persist failed build” behavior in `background.scanBg` (`src/background.zig:144-180`).

**Ownership constraint:** path duplication in `TrigramIndex.mergeBulkShard` (`src/index.zig:1463-1469`) is currently necessary: shards borrow paths from the temporary entry list and are deinitialized after merge. Zero-copy path transfer requires a redesigned canonical path owner with a lifetime beyond both shards; otherwise it creates dangling index keys.  
⟦ELITE-LIVE-ON-PROD⟧

[subagent sa-018-cd9b2f60 · inspect: .graff/subagents/sa-018-cd9b2f60.md]

### Benchmark strategy audit
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
   `src/benchmark.zig:304–311` measures `watcher.initialScan` directly. The production MCP route is `commands.runMcp → background

…[9253 chars truncated — full result in the inspect file below]…

ning I/O contention or tail latency.

---

## Bottom line

- **Do not claim 0.93 ms—or any derivative of it—as cold MCP search.**
- The repository currently has useful **warm dispatch**, **warm MCP**, **scan-only**, and **CLI bootstrap** benchmarks, but no valid end-to-end cold MCP first-search benchmark.
- First make the measurement precise and reproducible; then the two persistence operations immediately before `scan_done` are the only currently high-confidence candidates for reducing first-usable-search latency.

[subagent sa-017-b4b6eb3e · inspect: .graff/subagents/sa-017-b4b6eb3e.md]

## report

## Decision memo

### 1. Best low-risk next implementation

**Defer word-index persistence until immediately after MCP readiness is published.**

This is the best supported, smallest change:

- `background.scanBg` synchronously calls `persistWordIndexToDisk` before `scan_done=true` / `setScanState(.ready)` (`src/background.zig:73–75`).
- The current process already has a complete in-memory word index after `watcher.initialScan`; persistence is only for reuse by a later process.
- `persistWordIndexToDisk` takes a shared Explorer lock, writes atomically, and uses generation checking before marking persistence complete (`src/bootstrap.zig:299–310`; `src/explore.zig:2269–2283`). It is therefore safe for queries to proceed while it writes and safe if a concurrent update advances the generation.

This removes exactly the word-index write duration from **cold MCP first-usable-search latency**, without changing index construction, query results, trigram behavior, or the persisted format.

The reported `0.93` measurement is not evidence for this decision: it is a **0.93 ms warm MCP query**, not cold MCP first search. The repository has no valid current cold-MCP benchmark, so the size of the gain must be measured rather than assumed.

### 2. Exact code-level plan and correctness behavior

**Affected functions**

- `src/background.zig`
  - `scanBg`
- No format, index, or query-path changes.

**Change**

1. Remove the pre-readiness call:
   ```zig
   if (initial_scan_ok) persistWordIndexToDisk(io, explorer, data_dir, git_head);
   ```
   from its current position after `.indexing` is set.

2. In each successful `scanBg` path that currently publishes readiness:
   - matching mmap trigram load;
   - matching heap trigram load;
   - newly built trigram path;

   call `persistWordIndexToDisk(...)` **immediately after**:
   ```zig
   scan_done.store(true, .release);
   mcp_server.setScanState(.ready);
   ```
   and **before** the existing shutdown-return check / telemetry / snapshot-finalization work.

   This preserves the existing best-effort persistence attempt even when shutdown is requested immediately after readiness, while no longer gating the first query on it.

**Correctness and failure behavior**

- The in-memory word index remains the source of current-process word-search correctness; publishing readiness earlier does not expose a partial index.
- Persistence failures remain warning-only, exactly as today. The current MCP process remains searchable; only next-process reuse may be unavailable.
- If a watcher or edit mutates the word index while persistence is in progress, `markWordIndexPersisted(generation)` only records success if the generation still matches. A newer generation remains dirty and is not falsely marked persisted.
- The existing atomic write behavior of `WordIndex.writeToDisk` remains unchanged.
- No attempt should be made to move trigram persistence/mmap adoption in this change: the current implementation destroys the temporary heap trigram after writing, so publishing it early requires an ownership/lifetime redesign and has materially higher RSS and concurrency risk.

### 3. Benchmark against current HEAD

Use a purpose-built external MCP driver; existing `zig build benchmark`, `zig build bench`, and shootout results are not valid cold-MCP measurements.

**Workload and controls**

- Use an immutable corpus revision and an **explicit root**:
  ```text
  codedb <absolute-corpus-path> mcp
  ```
  This avoids deferred-root handshake/fallback timing.
- Record corpus file count, eligible bytes, query ground truth, binary commit, Zig version, build mode, CPU/OS/filesystem, and fixed `CODEDB_SCAN_WORKERS`.
- Before every trial, remove that corpus’s codedb snapshot, word-index, and trigram artifacts. Kill any prior codedb process for the corpus.
- Use `CODEDB_NO_SEARCH_CACHE=1`; disable warmup/telemetry if supported, and report whether production-default background services were enabled.
- Run at least 15 independent fresh-process trials per revision, alternating **HEAD / candidate / candidate / HEAD**.

**Primary metric**

Measure monotonic time from process spawn immediately before `exec` through:

1. MCP `initialize`;
2. `initialized`;
3. one correctness-checked, index-dependent `codedb_search` response.

Report raw samples plus median, p95, min/max, and a bootstrap confidence interval for the median difference. Label this **application-cold, OS-cache-warm** unless page-cache state is explicitly controlled.

**Required correctness checks**

- The first query must assert expected matching files/lines, not merely a non-error response.
- Run a small query set after readiness: rare identifier, common identifier, content/trigram query, negative query.
- Start a second process after each successful run and verify the persisted word index loads and returns equivalent word-search results.

**Secondary diagnostics**

- Capture peak RSS with the platform’s process-memory tool (for example `/usr/bin/time -v` on Linux).
- Since the MCP path does not currently emit structured phase timings, record the end-to-end difference as the acceptance metric. Add no performance claim beyond that observed difference.
- Run a separate snapshot-cold-load series with valid artifacts retained; do not combine it with no-index cold results.

### 4. Follow-ups, ranked by payoff

1. **Enforce `CODEDB_TRIGRAM_CAP` in the cache-based parallel trigram builder — high conditional payoff; correctness fix first.**  
   `collectInitialScanEntries` applies discovery-order cap semantics (`src/watcher.zig:537`, `593–598`), but MCP’s `buildTrigramsFromCache` iterates cache entries and only filters size (`src/watcher.zig:950–957`). Thus a cold MCP scan can index more than the configured cap.  
   Preserve the ordered eligibility decision from collection through the cache build; do **not** cap the hash-table iterator, which would be nondeterministic. Benchmark only on corpora exceeding the cap and verify intended capped coverage.

2. **Stream trigram postings in `TrigramIndex.writeToDisk` — high peak-RSS payoff, measurement required.**  
   The writer materializes the full `postings_buf` before writing (`src/index.zig:1773–1844`) on the current readiness-critical path. Stream postings to the temporary file while tracking offsets, retaining sorted trigram order and loader-compatible lookup entries. This needs disk-format/mmap reload equivalence tests and careful two-file failure handling.

3. **Repair the parallel stat-pass shared-error race and serialize snapshot recording after parallel stats — medium/high many-file payoff.**  
   `statScanForInitial` concurrently reads/writes a shared `*?anyerror` and calls mutex-serialized `Store.recordSnapshot` from every worker (`src/watcher.zig:515–524`, `579`; `src/store.zig:79–144`). Use per-worker error slots and disjoint size writes, then record snapshots in discovery order after joins. This improves determinism and removes the race; benchmark on many-small-file trees.

4. **Size-weight static trigram/word shard ranges — skewed-corpus payoff, higher behavioral risk.**  
   Current shards are equal-file-count (`src/watcher.zig:776–793`, `997–1011`), despite available file-size information. Only pursue after a byte-skewed benchmark demonstrates worker stragglers; preserve contiguous range and merge order so document/posting order remains stable.

No recommendation is made for broader parallelization of the serial Explorer commit spine or ownership-transfer/copy elimination yet: both are structurally plausible but lack MCP-path phase evidence and have substantially larger correctness/lifetime surface.

```diff
- No repository files changed.
+ Analysis-only decision: defer word-index persistence until immediately after MCP readiness,
+ because it is proven synchronous pre-ready durability work while the complete in-memory
+ index already satisfies current-process search correctness.
```
