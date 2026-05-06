# Changelog

## 0.2.5808 - 2026-05-06

`0.2.5808` is a tool-schema fix for `codedb_bundle` plus an opt-in rerank-trace logger for offline ranking experiments. Three PRs ship together: [#435](https://github.com/justrach/codedb/pull/435) (Stage 1 of [#434](https://github.com/justrach/codedb/issues/434)), [#438](https://github.com/justrach/codedb/pull/438) (Stage 2 of [#437](https://github.com/justrach/codedb/issues/437)), and [#436](https://github.com/justrach/codedb/pull/436) (rerank-trace logger).

### MCP ([#434](https://github.com/justrach/codedb/issues/434), [#437](https://github.com/justrach/codedb/issues/437))

Function-calling LLMs were emitting `{tool: "codedb_outline", arguments: {}}` and similar payloads that then failed each sub-op with `received keys: [tool, arguments]`. The schema permitted the empty payload and the model picked the minimum-valid one. Fixed in two stages, both shipping here.

- **Stage 1: `arguments` is now required on bundle ops items.** Pre-fix the items schema was `required: ["tool"]` with `arguments` as a bare `{type: "object"}`, so `arguments: {}` and outright omission were both valid input. Schema-greedy function-calling models read this as authoritative and emitted the empty form, which then misrouted through the inline-args fallback at `mcp.zig:1948` and surfaced as `received keys: [tool, arguments]` from each sub-tool. Adding `"arguments"` to `items.required` forces the model to populate the wrapper. The `#424` runtime inline-args fallback stays as a backstop for non-conformant clients.
- **Stage 2: discriminated `oneOf` over `tool`.** Stage 1 forces presence but not contents — a schema-greedy model could still satisfy `required: ["tool", "arguments"]` by emitting `{tool: "...", arguments: {}}`. Stage 2 binds the *contents* of `arguments` to each sub-tool's actual `inputSchema` via a discriminated `oneOf` with one branch per dispatchable codedb_* sub-tool. Each branch pins `tool` to a `const` (e.g. `"codedb_outline"`) and `arguments` to that sub-tool's schema (with its own `required` array preserved), so once a model picks a sub-tool the only matching branch tells it exactly which keys to populate. `codedb_bundle` (recursive) and `codedb_edit` (write op) are excluded since `handleBundle` rejects them at runtime. The augmented schema is built once at server startup from the per-sub-tool schemas already advertised in `tools_list` — no hand-maintained duplication. Falls back to the raw `tools_list` if augmentation fails.

### Search ([#436](https://github.com/justrach/codedb/pull/436))

- **Opt-in rerank-trace logger for offline tuning.** A v0 JSONL trace logger is added behind `rerank_trace = true` in `.codedbrc`. When enabled, each `searchContent` invocation appends one line — `{ts, query, results:[{path, line, score}]}` — so the data can be analyzed offline before deciding whether online learning-to-rank from agent traces is worth building. Pure observation, disabled by default, no ranking-behavior change. Query is capped at 256 bytes, results at 50 entries, and the file rotates by truncate-clobber at 10 MB. All I/O errors are swallowed — logging never breaks a search.
- **`rerankAndFinalize`: score-then-sort, even at len 1.** A pre-existing micro-optimization skipped multi-signal scoring when the result list had fewer than two entries. With the trace logger landed, single-result entries logged `score=0.0`, indistinguishable from genuinely zero-confidence matches. Scoring now always runs; only the sort is guarded behind `len > 1`. Cost is a few µs per single-result search.

### Validation

- Two failing tests in `src/tests.zig` (`issue-434`, `issue-437`), each one fails on `main` without its respective stage and passes with it. End-to-end Sonnet 4.6 test against the new bundle schema: prior bug (empty `arguments` payloads under no fix; wrong-keyname payloads under Stage 1 only) does not reproduce. Same task that previously emitted `codedb_word` with `{"query": "..."}` (failing) now emits `{"word": "..."}` (succeeding) — the discriminated branch's `required: ["word"]` constraint flows through to model output.
- Bundle schema payload size doubled (~12KB → ~24KB) due to inlining 19 sub-tool schemas as `oneOf` branches. Acceptable cost for the constraint.
- 513/513 tests pass on the merged release branch.

## 0.2.5807 - 2026-05-06

`0.2.5807` is a search-quality + crash-fix release covering six issues. The headline is a multi-signal reranker for `searchContent` plus a P0 crash fix in `searchInContent`. All six fixes ship in a single bundle ([#425](https://github.com/justrach/codedb/issues/425), [#426](https://github.com/justrach/codedb/issues/426), [#427](https://github.com/justrach/codedb/issues/427), [#429](https://github.com/justrach/codedb/issues/429), [#430](https://github.com/justrach/codedb/issues/430), [#431](https://github.com/justrach/codedb/issues/431)).

### Reliability ([#431](https://github.com/justrach/codedb/issues/431))

- **`searchInContent`: bounds-check fixes a P0 crash.** When the query was longer than any indexed file's content, `content.len - query.len + 1` underflowed `usize` and the binary aborted with integer-overflow panic (Debug) or SIGBUS (ReleaseFast). One-line guard at the top of `searchInContent` returns early when `query.len > content.len`. Reachable from any user-supplied query that exceeded the smallest indexed file (e.g. a one-byte stub). Fixed.

### Search quality ([#425](https://github.com/justrach/codedb/issues/425), [#426](https://github.com/justrach/codedb/issues/426))

- **`codedb_callers`: whole-word match.** `handleCallers` previously substring-matched the symbol name across the index and only excluded the canonical definition line of the searched name itself. Searching for `fooBar` returned matches inside `fooBarExtended` — both its definition site and any references — as if they were call sites. A new `hasWholeWordMatch` check gates every emitted result on identifier-boundary characters on both sides of the hit.
- **`codedb_callers`: language gate.** `handleCallers` fed `searchContentWithScope` across every indexed file regardless of language, so markdown design docs and other prose surfaced as call sites whenever the symbol name was mentioned. A new `langHasCallSites` predicate excludes data formats (`json`, `yaml`), markup/styling (`markdown`, `css`, `scss`), declarative schemas (`protobuf`), and unknown files.

### Search ranking ([#427](https://github.com/justrach/codedb/issues/427), [#429](https://github.com/justrach/codedb/issues/429), [#430](https://github.com/justrach/codedb/issues/430))

- **Tier 1 candidate sort by per-file word-hit count.** `searchContent`'s Tier 1 sorted trigram candidates by content length ascending and then capped per-file at `max(1, max_results / estimated_total)`. When small unrelated files dominated the candidate list, they each contributed one hit and saturated the result quota before the larger definition-dense file was scanned. Now Tier 1 ranks candidates by per-file word-index hit count (desc) with content length (asc) as a stable tiebreaker — the file with the most occurrences scans first.
- **Tier 0 processes code before docs.** With `max_results=50` and the per-file cap of 10, five markdown files mentioning the query 10+ times each could collectively saturate the quota before the canonical source file was reached, leaving the source file completely absent from results. A new `isDocLanguage(Language)` predicate gates a two-pass loop: code-language hits first, doc-language hits second. Same per-file cap, same dedup, same early-return — only iteration order changes. Source files now win the recall race.
- **Multi-signal rerank.** The post-pass rerank counted per-line query occurrences only and broke ties on path-asc + line-asc, which buried symbol-definition lines under alphabetically-earlier comment mentions, ranked `examples/foo.zig` above `src/foo.zig`, and lost basename-match intent entirely. New `rerankSignalScore` composes per-line occurrence count, a symbol-definition boost (+5 when the hit line is a defined symbol whose name matches the query, looked up via outlines), a basename-match boost (+15 exact stem, +8 substring, case-insensitive), a path-segment match boost (+6 for queries like `parser` matching `src/parser/foo.zig`), and a path-prior penalty (×0.6 for `tests/`, `examples/`; ×0.4 for `vendor/`, `node_modules/`, `third_party/`). Constants are tuned so a 5x-higher per-line frequency still wins on its own, while each signal individually flips alphabetic ties.
- **Rerank applies on every return path.** Pre-fix the multi-signal rerank only ran on fall-through to the final return; Tier 0 and Tier 1 early-returns at `max_results` bypassed it entirely. Lifting the rerank into a `rerankAndFinalize` helper called from every searchContent return point gives the symbol-def / basename / path-prior signals consistent coverage regardless of which tier filled the quota.
- **Doc-language penalty in rerank.** Live-binary testing showed CHANGELOG and benchmark `.md` files with 4-6 mentions of an identifier on one line outranking actual code call sites under per-line frequency. The reranker now caps doc-language scores at 1.0 then halves them, so any code hit (`score >= 1`) outranks any markdown / json / yaml / unknown-language hit. Symmetric with the path-prior penalty.

### Validation

- 271 lines of regression tests in `src/tests.zig` — one or more per issue, all failing on `main` without the fix and passing with it. Bundle-level Sonnet 4.6 validation (real codebase, side-by-side comparison vs. the 0.2.5806 baseline) shows definition sites promoted to #1 for `handleCallers`, `pathHasSegment`, `BenchContext`, `Explorer`; `src/explore.zig` now ranks #1 for the `searchContent` query (was completely absent from baseline top-5); `src/watcher.zig` at #1 for `watcher`; no quality regressions on innocent queries; RSS delta under 1%.

## 0.2.5795 - 2026-05-04

`0.2.5795` closes out [#356](https://github.com/justrach/codedb/issues/356) with phase 3 — three small ergonomics polishes that complete the rewritten reliability scope — plus a privacy/disk-leak fix for [#367](https://github.com/justrach/codedb/issues/367).

### Reliability ([#356](https://github.com/justrach/codedb/issues/356) phase 3)

- **`codedb_outline`: stale-index recovery hint.** When a path isn't indexed, the response already gets fuzzy suggestions (phase 1). It now also includes `hint: try codedb_index if the file was added recently` so agents know how to recover from a freshly-added file the watcher hasn't seen yet — no more relying on tribal knowledge of the operator command.
- **`codedb_read`: fuzzy path fallback on read failure.** `codedb_outline` already surfaces `did you mean:` suggestions when its path doesn't index; `codedb_read` now does the same when its disk read fails. A mistyped path is recoverable in one shot without a separate `codedb_find` round-trip.
- **`codedb_query`: per-stage summary tail.** Successful pipelines now emit a structured `--- stages ---` block listing each step's op and outgoing file count. Long pipelines become legible at a glance without parsing the unstructured per-step output above it.

### Storage ([#367](https://github.com/justrach/codedb/issues/367))

- **`data.log`: truncate on open.** Previously, `Store.openDataLog` opened the file with `truncate=false` and seeded the write cursor to the existing length, while `Store.init` returned an empty in-memory index and nothing replayed the log on load. Net effect: every prior session's raw `codedb_edit` content (potentially including secrets/PII pasted into a `content` arg) accumulated forever as unreachable orphan bytes in a file that looks like a log but isn't read by anyone. The log is now truncated on every process start, since the in-memory index is always empty at that point and the on-disk bytes are unreachable.

### DX

- **TTY summary surfaces received-keys diagnostic.** The `received keys: [...]` hint from #356 phase 1+2 only landed in `content[1]` of the MCP envelope, but many clients only render `content[0]` (the colored single-line summary). Missing-arg errors now append a compact `(received: [...])` tail to the summary too, so the diagnostic is visible regardless of how many blocks the client renders.

With this release, [#356](https://github.com/justrach/codedb/issues/356) is closed:
- ✅ Phase 1 — pipeline partial results, outline fuzzy fallback, query received-keys diagnostic (0.2.5793)
- ✅ Phase 2 — received-keys diagnostic across all single-tool handlers (0.2.5794)
- ✅ Phase 3 — stale-index hint, read fuzzy fallback, query per-stage summary (0.2.5795)

## 0.2.5794 - 2026-05-04

`0.2.5794` extends [#356](https://github.com/justrach/codedb/issues/356) phase 2 — the `received keys: [...]` diagnostic now lands on every single-tool handler with a required argument. Tiny release; entirely an ergonomics polish on top of `0.2.5793`.

### Reliability ([#356](https://github.com/justrach/codedb/issues/356) phase 2)

The `received keys: [...]` self-diagnose hint is now wired into:

- `codedb_outline` — missing `'path'`
- `codedb_symbol` — missing `'name'`
- `codedb_search` — missing `'query'`
- `codedb_word` — missing `'word'`
- `codedb_deps` — missing `'path'`
- `codedb_read` — missing `'path'`

Combined with phase 1 (`codedb_query` pipeline steps and `codedb_bundle` ops), every read-path tool now surfaces the keys it actually received when a required argument is missing. Callers can self-diagnose typos like `file_path` vs `path` without retrying blind. `codedb_edit` deliberately keeps the bare error — write operations should fail loudly without hinting at alternatives.

## 0.2.5793 - 2026-05-04

`0.2.5793` is a search recall, ranking, and reliability release on top of `0.2.5792`. All three items from [#363](https://github.com/justrach/codedb/issues/363) plus phase 1 of [#356](https://github.com/justrach/codedb/issues/356) are resolved.

### Search and ranking ([#363](https://github.com/justrach/codedb/issues/363))

- **`codedb_search` recall: source-file matches no longer dropped when doc files dominate the word index.** A Sonnet 4.6 sub-agent driving the live MCP reproduced [#363](https://github.com/justrach/codedb/issues/363) item a: querying `searchContent` against this repo returned doc files (CHANGELOG.md, architecture.md, etc.) but missed `src/explore.zig` itself. Root cause: Tier 0 of `searchContent` (`explore.zig:1511`) iterates word-index hits in posting-list order and saturates the result quota with hits from heavily-mentioning files before reaching source files indexed later. Fix: per-file cap of `max(1, max_results / 5)` in Tier 0 so a single hot file can't crowd out the rest. Closes [#363](https://github.com/justrach/codedb/issues/363) (item a).
- **Fuzzy find: exact basename match now dominates ranking.** Querying `cli.rs` against a multi-crate workspace previously returned four unrelated `lib.rs` files ahead of the actual `crates/forge_main/src/cli.rs`. The compounding factors were the special-entry-point bonus (which gave `lib.rs` / `main.go` / `index.ts` a +5% boost regardless of query) and path-length normalization rewarding shorter parent paths. Fix: when the query case-insensitively equals the filename, apply a 4× multiplier — fzf-style "exact match always wins." Closes [#363](https://github.com/justrach/codedb/issues/363) (item b).

### Query reliability and ergonomics ([#356](https://github.com/justrach/codedb/issues/356) phase 1)

The "Agent Context Planner" framing was dropped — codedb stays a tool, agents stay in charge of composition. Three small reliability improvements land:

- **`codedb_query`: partial results when a step fails.** The pipeline previously bailed on the first error and discarded successful prior-step output. Now the prior-step output is preserved and a structured `--- partial ---` tail names the failing step + reason. Agents can recover from a single bad step instead of starting over.
- **`codedb_outline`: fuzzy path fallback.** A non-indexed path used to return a bare `error: file not indexed`. Now appends up to 3 fuzzy-matched indexed paths under a `did you mean:` header, so an agent that mistypes can self-correct without a separate `codedb_find` round-trip.
- **`codedb_query`: received-keys diagnostic on missing-arg errors.** Mirrors the [#357](https://github.com/justrach/codedb/issues/357) `codedb_bundle` diagnostic. When a step fails with `error: search needs 'query'` but the step actually has a `q` key instead, callers see `received keys: [op, q]` so they can tell whether codedb dropped the field or the client sent it under the wrong name. Wired through `op`-detection plus `find`, `search`, `word`, and `symbol` step error paths.

### Cosmetic

- **`codedb --version` and `codedb_status` now report the correct version.** The `0.2.5792` release shipped with `src/release_info.zig` at `"0.2.579"` while `build.zig.zon` was at `"0.2.5792"` — so binaries built from that source tree self-reported as the older version. Both are now synced to `0.2.5793`.

### Carried over from 0.2.5792

The `received keys: [...]` diagnostic that landed in [#357](https://github.com/justrach/codedb/issues/357) (PR [#362](https://github.com/justrach/codedb/pull/362), shipped in 0.2.5792) addresses [#363](https://github.com/justrach/codedb/issues/363) item c — bundled-op argument errors now surface the keys actually received so callers can self-diagnose.

## 0.2.5792 - 2026-05-04

`0.2.5792` is a tools, safety, and performance release. Two new MCP tools land (`codedb_glob`, `codedb_ls`), `codedb_edit` gains a `dry_run` preview and an `if_hash` stale-line guard, and the `**` glob matcher is rewritten to fix a recall regression and pick up a 30% p50 win on common patterns.

### Highlights

- **New: `codedb_glob` and `codedb_ls` MCP tools.** Native glob and directory listing surfaced to MCP clients alongside the existing search/outline tools. Closes [#359](https://github.com/justrach/codedb/issues/359).
- **`codedb_edit` is now safer.** `if_hash` is enforced — edits against stale lines fail fast instead of silently overwriting. `dry_run` returns the would-be diff (and a corrected `inserted_count`) without writing. Closes [#360](https://github.com/justrach/codedb/issues/360).
- **Glob `**` correctness fix.** The pipeline filter previously used `mcp.globMatch`, which dropped matches when `**` had to backtrack across directory depths. Replaced with `explore.matchGlob`. A retrieval-recall regression test now pins behavior across all six retrieval surfaces (full-text, word index, symbol index, fuzzy path, glob, dep graph). Closes [#359](https://github.com/justrach/codedb/issues/359).
- **30% faster `**/*.md` glob.** `matchGlob` short-circuits common patterns: `**/*X` degenerates to `endsWith`, and patterns with long literal prefixes that the path can't match exit early. Measured 540 µs → 377 µs p50.

### Correctness: Edit

- `if_hash` mismatch returns an error instead of writing — no more silent stale-line overwrites. (#360)
- `dry_run` mode returns the planned diff without touching the file; `inserted_count` reports the correct line count. (#360)
- `codedb_edit` response is now hex-consistent with `codedb_read` so callers don't have to normalize hash formats.

### Correctness: Glob

- Pipeline glob filter routes through `explore.matchGlob`, fixing `**` backtracking across directory depths. (#359)
- Recall regression test plants a flat 5-file corpus (definition, importer, test, decoy, prose) and asserts every retrieval surface — `searchContent`, `searchWord`, `findAllSymbols`, `fuzzyFindFiles`, `globPaths`, `getImportedBy` — returns the expected files and excludes the decoy. Fires if any index silently drops a file in the future.

### Performance

- `matchGlob` fast paths for `**/*X` (endsWith) and long literal prefixes. −30% p50 on `**/*.md` (540 → 377 µs).
- `lsDir` / `globPaths` allocation trims: pre-reserved result-list capacity, removed the redundant `seen_files` map in `lsDir`. Effect on a 113-file repo is within run-to-run noise; kept because it removes dead work and reduces allocations on larger repos.

### Issues Closed

- [#359](https://github.com/justrach/codedb/issues/359) — Tool suggestions: native `glob` and `ls` tools
- [#360](https://github.com/justrach/codedb/issues/360) — `codedb_edit` suggestions (`if_hash` + `dry_run`)

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
