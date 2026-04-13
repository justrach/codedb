# Changelog

## 0.2.57 - 2026-04-13

`0.2.57` is a broad correctness, performance, and reliability release. It ships everything merged to main since `0.2.56` plus nine index and watcher bug fixes.

### Highlights

- **10× faster initial indexing.** Worker-local parallel scan with deterministic merge: each scan worker builds its own partial `Explorer`, then the results are merged on the main thread with no lock contention during the hot path. Closes [#221](https://github.com/justrach/codedb/pull/221).
- **Full `codedb nuke` uninstall.** `nuke` now removes all codedb data, kills any running daemon, deregisters MCP entries from Claude / VS Code / Cursor configs, and cleans up the install binary. Closes [#239](https://github.com/justrach/codedb/pull/239).
- **MCP: 10-minute idle timeout + dead-client detection.** Sessions that go quiet for 10 minutes are reaped automatically; POLLHUP on stdin is detected immediately so zombie MCP processes don't accumulate. Closes [#148](https://github.com/justrach/codedb/issues/148).
- **TrigramIndex id_to_path is now bounded.** A free-list of released doc_id slots is reused on re-index, so `id_to_path` grows only to the peak number of simultaneously live files, not total files ever indexed. Closes [#247](https://github.com/justrach/codedb/issues/247), [#227](https://github.com/justrach/codedb/issues/227).
- **watcher: git HEAD check is mtime-gated.** `.git/HEAD` mtime is statted per poll; `git rev-parse HEAD` forks only when it changes. Reduces steady-state background subprocesses from ~30/min to ~0 on idle repos. Closes [#254](https://github.com/justrach/codedb/issues/254).
- **Rosetta 2 / Apple Silicon stack fix.** Release builds now use an 8 MB stack on macOS, fixing stack-overflow crashes under Rosetta translation. Closes [#223](https://github.com/justrach/codedb/issues/223).

### Performance And Memory

- Worker-local initial indexing: each thread maintains its own `Explorer` during scan, eliminating the cross-thread merge bottleneck. Merge is deterministic so snapshot replay is reproducible. (#221)
- Steady-state watcher: mtime guard on `.git/HEAD` eliminates per-cycle fork+exec, saving CPU on large repos. (#254)
- `searchContent` fallback now iterates only the `skip_trigram_files` set (files indexed past the 15k cap) instead of all outlines. (#250)
- `EventQueue.head/tail` and `Store.seq` converted from atomic values to plain integers — all access already holds the owning mutex. Removes unnecessary memory fence instructions.

### Correctness: Index And Explorer

- `TrigramIndex.removeFile`: `path_to_id.remove` is now the first operation, fixing a ghost-entry bug where files missing from `file_trigrams` left stale map entries. (#246)
- `TrigramIndex.getOrCreateDocId`: reuses freed doc_id slots from `free_ids: ArrayList(u32)`, keeping `id_to_path` bounded. (#247, #227)
- `PostingList.removeDocId`: O(log n) binary search replacing the previous O(n) linear scan.
- `AnyTrigramIndex` mmap_overlay: `candidates` / `candidatesRegex` now `deinit` the result ArrayList on the error path, closing an OOM buffer leak. (#251)
- `commitParsedFileOwnedOutline`: errdefer rolls back `word_index.indexFile` if the subsequent trigram index step fails, keeping word and trigram indexes in sync. (#252)
- `searchContent` fallback restricted to `skip_trigram_files` set, reducing false-negative range from O(all files) to O(skip-trigram files). (#250)

### Correctness: Nuke And Config

- `rewriteConfigFile`: writes to `{path}.tmp`, syncs, then renames — no more truncated config files on kill. (#249)
- `nuke` now deregisters MCP server entries from JSON configs (Claude, VS Code), TOML configs (Cursor), and removes the install binary. Handles corrupted or non-standard config files gracefully. (#239)

### Correctness: Snapshot

- `readSectionBytes` opens the snapshot file once; extracted `readSectionsFromFile` helper shared with `readSections`. (#253)
- `readSectionString` limit raised from 4,096 to `std.math.maxInt(u16)` — long symbol names no longer return errors.
- `loadSnapshotFast` treats a corrupt `OUTLINE_STATE` section as an empty map rather than aborting startup.

### MCP Stability

- 10-minute idle timeout: MCP sessions that stop receiving input are reaped, preventing zombie processes on long-running Claude sessions. (#148)
- POLLHUP detection: stdin is polled; a closed read-end triggers immediate clean shutdown instead of waiting for the next read timeout. (#148)
- `codedb_status` memory and index diagnostics are unaffected by telemetry call-count race (atomic increment fix). (#179)

### Infrastructure

- 8 MB release stack on macOS prevents stack overflows under Rosetta 2 on `aarch64` binaries running via translation. (#223)
- `help` command now compiles and exits correctly as a standalone CLI invocation. (#238)
- `approxIndexSizeBytes` updated for the `AnyTrigramIndex` union layout. (#236)

### Benchmarks (`ReleaseFast`, openclaw/openclaw, 6,315 files, Apple M4 Pro)

| Metric | 0.2.56 | 0.2.57 | Delta |
| --- | ---: | ---: | ---: |
| Initial index time | 3.6 s | 346 ms | **10× faster** |
| Steady-state RSS | 1,867 MB | 1,706 MB | −161 MB |
| git subprocesses / 30 s (steady state) | 15 | 2 | **−87%** |
| Trigram search latency (avg) | 55 ms | 53 ms | −4% |
| Word index latency (avg) | 35 ms | 32 ms | −9% |
| Recall: `webhook` | **0 hits** | **50 hits** | +50 (index fix) |
| Recall: `middleware` | 50 hits | 50 hits | same |

### Merged PRs In This Release

- [#255](https://github.com/justrach/codedb/pull/255) `fix: index growth, stale entries, atomics, git HEAD perf, snapshot robustness`
- [#239](https://github.com/justrach/codedb/pull/239) `feat: expand nuke into a full codedb uninstall`
- [#238](https://github.com/justrach/codedb/pull/238) `fix: restore help CLI build and exit behavior`
- [#236](https://github.com/justrach/codedb/pull/236) `fix: 8 MB release stack (#223) + atomic call_count in telemetry (#179)`
- [#233](https://github.com/justrach/codedb/pull/233) `fix: 10min idle timeout + poll stdin for dead clients (#148)`
- [#221](https://github.com/justrach/codedb/pull/221) `perf: worker-local initial indexing with deterministic merge`

### Issues Closed In This Release

- [#254](https://github.com/justrach/codedb/issues/254) `watcher: git HEAD fork+exec every 2s`
- [#253](https://github.com/justrach/codedb/issues/253) `readSectionBytes opens snapshot file twice`
- [#252](https://github.com/justrach/codedb/issues/252) `word_index and trigram_index diverge on OOM`
- [#251](https://github.com/justrach/codedb/issues/251) `AnyTrigramIndex mmap_overlay buffer leak`
- [#250](https://github.com/justrach/codedb/issues/250) `searchContent fallback scans all outlines`
- [#249](https://github.com/justrach/codedb/issues/249) `rewriteConfigFile not atomic`
- [#247](https://github.com/justrach/codedb/issues/247) `TrigramIndex id_to_path grows without bound`
- [#246](https://github.com/justrach/codedb/issues/246) `TrigramIndex.removeFile leaves stale path_to_id entry`
- [#227](https://github.com/justrach/codedb/issues/227) `TrigramIndex.id_to_path unbounded growth (many files)`
- [#223](https://github.com/justrach/codedb/issues/223) `Rosetta 2 stack overflow`
- [#148](https://github.com/justrach/codedb/issues/148) `MCP: 10min idle timeout + dead-client detection`

### Validation

- `zig build test` — 341/341 tests pass
- `zig build -Doptimize=ReleaseFast`
- Live benchmark against openclaw/openclaw (6,315 files)
- `zig build benchmark -- --root /path/to/repo`

## 0.2.56 - 2026-04-09

`0.2.56` is a release hotfix for the installer and self-update path after the manual `0.2.55` release.

### Hotfixes

- The install script now resolves the latest version from GitHub Releases first, then falls back to `codedb.codegraff.com/latest.json` only if GitHub is unavailable.
- `codedb update` now uses the same GitHub-first version lookup, avoiding stale release metadata during post-release propagation windows.
- The install worker lowers `/latest.json` cache lifetime from 5 minutes to 1 minute and updates its fallback version to `0.2.56`.

## 0.2.55 - 2026-04-09

`0.2.55` is a performance and reliability release focused on warm reopen, MCP startup behavior, search quality, parser correctness, and installer safety. The headline change is that warm CLI and MCP project loads now reopen persisted state directly instead of spending seconds rebuilding heap indexes.

### Highlights

- Warm snapshot reopen now restores snapshot outline/state directly, reuses persisted trigram sidecars, and avoids redundant `word.index` rewrites. This closes [#220](https://github.com/justrach/codedb/issues/220).
- `codedb_query` adds a composable MCP search pipeline so agents can do multi-step retrieval in one tool call. This closes [#168](https://github.com/justrach/codedb/issues/168).
- Search ranking now learns from query-to-open history through WAL-backed combo boosts. This closes [#195](https://github.com/justrach/codedb/issues/195).
- MCP sessions now record real client identity and expose memory diagnostics in `codedb_status`. This closes [#37](https://github.com/justrach/codedb/issues/37).
- Root policy now refuses to index the home directory itself, preventing the large MCP RAM spike reported in [#174](https://github.com/justrach/codedb/issues/174).

### Performance And Memory

- Persisted warm-reopen state now covers startup-critical outline/state data and trigram sidecars, with lazy word-index rebuild and persistence on demand.
- Repeat snapshots in the same cache location skip redundant `word.index` rewrites instead of paying full rewrite cost every time.
- `mmap_overlay` now supports zero-heap incremental updates on top of mmap-backed indexes, and allocation-pressure fallback avoids false negatives by dropping to the safe full-scan path.
- `releaseContents` now uses `clearAndFree` so content-cache bucket arrays are actually released instead of being retained.
- MCP startup refuses exact home-directory roots, preventing pathological scans of `~` and the resulting multi-gigabyte memory spikes.

#### CLI Benchmarks (`ReleaseFast`, `openclaw`, current `main` vs `v0.2.54`)

| Benchmark | 0.2.55 | 0.2.54 | Delta |
| --- | ---: | ---: | ---: |
| cold `tree` | `5.32s` | `5.29s` | `+0.6%` |
| `snapshot` | `6.53s` | `6.25s` | `+4.6%` |
| warm `tree` | `0.26s` | `6.16s` | `23.7x faster` |
| warm `search workspace` | `0.24s` | `6.14s` | `25.6x faster` |
| warm `word session` | `0.61s` | `5.99s` | `9.9x faster` |

Cold paths stay effectively flat, snapshot creation remains within the benchmark regression threshold, and warm reopen is dramatically faster.

#### MCP First Secondary-Project Call (`ReleaseFast`, `openclaw`)

| Tool | 0.2.55 | 0.2.54 | Delta |
| --- | ---: | ---: | ---: |
| `codedb_tree` | `0.076s` | `5.289s` | `69.6x faster` |
| `codedb_search` | `0.067s` | `5.278s` | `78.8x faster` |
| `codedb_word` | `0.285s` | `5.312s` | `18.6x faster` |

#### Peak RSS On `openclaw`

| Benchmark | 0.2.55 | 0.2.54 |
| --- | ---: | ---: |
| cold `tree` | `3478.8MB` | `3478.1MB` |
| warm `tree` | `192.6MB` | `3314.0MB` |
| warm `search` | `193.3MB` | `3312.9MB` |
| warm `word` | `677.1MB` | `3313.3MB` |

Warm RSS is materially lower because reopen no longer reconstructs the same large heap state on every process start.

#### Small-Corpus Sanity Pass (`codedb/src`)

| Benchmark | 0.2.55 | 0.2.54 |
| --- | ---: | ---: |
| cold `tree` | `0.045s` | `0.040s` |
| warm `tree` | `0.010s` | `0.030s` |
| warm `search` | `0.010s` | `0.030s` |
| warm `word` | `0.010s` | `0.030s` |

### Search, Ranking, And MCP

- Added `codedb_query`, a composable search pipeline for agent-driven retrieval workflows, including chained `find`, `search`, `filter`, `outline`, `read`, and `limit` stages in one call.
- `codedb_find` now retries delimiter-heavy queries more intelligently, truncates overly noisy per-file output, and skips more large generated directories by default.
- Search and file-access activity now writes to a local WAL, enabling combo-boost ranking for files that were historically opened after similar queries.
- WAL profiling now records latency and file-access patterns locally, and hashed telemetry upload preserves aggregation value without sending raw queries or file paths off-machine.
- `codedb_status` now reports client identity and index-memory diagnostics so MCP clients can see which kind of index is active and how much memory it is retaining.

### Installer, Update, And Release Reliability

- `codedb update` now downloads binaries directly from GitHub Releases instead of depending on the old CDN path.
- The install script now downloads release binaries from GitHub Releases as well.
- The `nuke` output now points at the correct install URL.
- Installer shell docs and checksum fallback behavior were tightened so release/install flows fail more predictably.

### Parser And Correctness Fixes

- Fixed five correctness bugs from [#179](https://github.com/justrach/codedb/issues/179), including large-repo mmap cache validation, ANSI escape stripping, block-comment handling, Python docstring detection, and a telemetry write-path race.
- Parsing now correctly resumes after single-line `/* ... */` comments instead of skipping subsequent code on the line.
- Added regression coverage for the `#179` parser fixes so comment/docstring edge cases stay fixed.

### Merged PRs In This Release

- [#222](https://github.com/justrach/codedb/pull/222) `perf: speed up warm snapshot reopen`
- [#204](https://github.com/justrach/codedb/pull/204) `test: regression tests for #179 parser fixes`
- [#203](https://github.com/justrach/codedb/pull/203) `fix: parse code after single-line /* */ comments`
- [#202](https://github.com/justrach/codedb/pull/202) `fix: 5 bugs from issue #179`
- [#201](https://github.com/justrach/codedb/pull/201) `fix: install script downloads from GitHub releases`
- [#200](https://github.com/justrach/codedb/pull/200) `feat: combo-boost ranking from WAL`
- [#199](https://github.com/justrach/codedb/pull/199) `feat: cloud WAL sync — hashed profiling telemetry`
- [#198](https://github.com/justrach/codedb/pull/198) `feat: WAL profiling — latency + file access logging`
- [#194](https://github.com/justrach/codedb/pull/194) `feat: search UX — auto-retry, per-file truncation, query WAL, skip dirs`
- [#192](https://github.com/justrach/codedb/pull/192) `feat: MCP client identity + memory diagnostics`
- [#191](https://github.com/justrach/codedb/pull/191) `fix: mmap_overlay fail-safe on allocation pressure`
- [#190](https://github.com/justrach/codedb/pull/190) `perf: mmap overlay pattern for zero-heap incremental updates`
- [#189](https://github.com/justrach/codedb/pull/189) `fix: releaseContents reclaims HashMap bucket memory`
- [#180](https://github.com/justrach/codedb/pull/180) `feat: composable search pipeline — codedb_query`
- [#178](https://github.com/justrach/codedb/pull/178) `fix: block home directory indexing to prevent 17GB RAM spike`
- [#177](https://github.com/justrach/codedb/pull/177) `fix: correct install URL in nuke output`
- [#176](https://github.com/justrach/codedb/pull/176) `fix: codedb update downloads directly from GitHub releases`

### Issues Closed In This Release Window

- [#220](https://github.com/justrach/codedb/issues/220) `perf: persist startup-critical indexes aggressively for mmap-backed warm reopen`
- [#195](https://github.com/justrach/codedb/issues/195) `feat: combo-boost ranking from query WAL`
- [#174](https://github.com/justrach/codedb/issues/174) `MCP mode: 17GB RAM spike when Claude Code starts in home directory`
- [#168](https://github.com/justrach/codedb/issues/168) `feat: agent-defined search — let agents compose custom search pipelines`
- [#37](https://github.com/justrach/codedb/issues/37) `Add real MCP client identity instead of hardcoding all edits to agent 1`

### Validation Used For This Release

- `SDKROOT=$(xcrun --show-sdk-path) zig build test`
- `SDKROOT=$(xcrun --show-sdk-path) zig build -Doptimize=ReleaseFast`
- `SDKROOT=$(xcrun --show-sdk-path) zig build run -- --version`
