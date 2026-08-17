# subagent sa-004-f2c6e7ae

- label: Identify current serial stat/walk points
- kind: workflow_task
- status: ok
- elapsed_ms: 143224
- tools: codedb,codedb,codedb,read_file,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,bash!,bash!,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,read_file,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,read_file,read_file!,read_file,codedb,codedb

## task

Use codedb to find where filesystem stat calls happen during the initial serial walk (collectInitialScanEntries or nearby). Look for std.fs operations like stat, access, openDir, etc. in the scan path. Distinguish between path collection vs stat collection. Note any TODOs or comments about parallelization.

## report

**collectInitialScanEntries + nearby initial-scan walk (src/watcher.zig only).**

- Definition: `fn collectInitialScanEntries(io: std.Io, store: *Store, dir: std.Io.Dir, allocator: std.mem.Allocator, skip_trigram: bool) !std.ArrayList(InitialScanEntry)` (L509; callers: L639 in `initialScanWithWorkerCount`, L987 in `initialScanWithTrigrams` which always passes `true` for skip_trigram).
- It does a *single serial walk* (no threads) that produces an ordered list of `InitialScanEntry {path: []u8, skip_trigram: bool}` while also doing `store.recordSnapshot`.
- The walk is "initial" / cold-scan only; later incremental paths (e.g. `incrementalDiff`, `incrementalLoop`) and parse paths reuse similar logic but are separate.

**Path collection (discovery/pruning) vs. stat collection (size/snapshot + content).**

- **Path collection** (pure discovery of relative paths, with pruning): entirely inside `FilteredWalker` (struct at L275).
  - `init` (L294): `root.iterate()` (L303), `root.readFileAlloc` for `.codedbignore` + `.gitignore` (L315, L327), `root.realPathFile` for the real_root seed + visited set (L307).
  - `next` (L386): `top.iter.next(self.io)` (L392), `top.dir_handle.openDir(..., .{.iterate=true})` for every non-skipped subdir (L405, L449 for symlinks), `shouldSkipDir` + `isIgnored` checks, `top.dir_handle.statFile` + `realPathFile` *only* on symlinks to decide "is it a dir?" + cycle/escape guard (L425, L437), name_buffer appends, and ignore checks on the built path. It never stats regular files for size/content. Pruning (skip_dirs, .codedbignore, .gitignore, visited_real_paths) happens here.
  - Returns only a path string (`.path = name_buffer.items`); no size/stat yet. Uses a stack of `StackItem {dir_handle, iter}` (L276); single-threaded depth-first.

- **Stat collection** (post-path):
  - Immediately after `walker.next()` in `collectInitialScanEntries` (L521): `const stat = dir.statFile(io, entry.path, .{}) catch continue;` then `store.recordSnapshot(entry.path, stat.size, 0)` (L522-523). This is the *only* stat in the pure "collect" step. It also decides the `skip_trigram` flag via `trigramFileCap()` (L519, L504; env `CODEDB_TRIGRAM_CAP`).
  - Downstream (still part of the "initial scan" pipeline fed by the entries list):
    - `parseInitialScanEntry` (L533; called from serial path + `parseInitialScanWorkerEntry`): `std.Io.Dir.cwd().openDir` (L541) + `dir.statFile` (L543) + `readIndexableFile` (which does `dir.readFileAlloc` + binary check, L544; see L173).
    - Worker paths (`initialScanWorker` L595, `readAndBuildTrigramShardWorker` L783, `initialScanWithTrigrams` etc.) repeat the same `openDir`/`statFile`/`readFileAlloc` per chunk.
    - `readIndexableFile` (L173) is the shared gate: size > `max_indexed_file_bytes` (2MB) or binary → skip (with a log only on the warn_oversize path).

- `std.fs` / `std.Io.Dir` ops seen in the initial serial walk path (all via the `io: std.Io` + `std.Io.Dir` abstraction, never raw `std.fs` directly in the hot path):
  - `iterate` / `iter.next`
  - `openDir(..., .{.iterate=true})`
  - `statFile` (twice: symlink decision in walker, size snapshot in collect)
  - `realPathFile` (real_root + symlink targets)
  - `readFileAlloc` (ignores + later content)
  - (No `access`, `openFile`, or `walk`—they deliberately avoid `std.Io.Dir.walk` per the comment at L280: "Unlike std.Io.Dir.walk(), this never enters .git...".)

**Parallelization notes/comments (none on the walk itself).**

- The *walk* (FilteredWalker + collectInitialScanEntries) is always serial (stack-based next(), single caller thread).
- Parallelism comments are exclusively about *post-walk* phases:
  - `initialScanWithWorkerCount` (L623) + `initialScanWorker` (L595): chunks the *already-collected* `InitialScanEntry` list across N workers (threads) for `parseInitialScanEntry` + word shards + commit. See L694 ("build it in parallel per-worker shards"), L727 ("Shared Explorer maps remain serial"), L696-700 (gated on `skip_file_words`), and profile prints.
  - `initialScanWithTrigrams` (L975) + `readAndBuildTrigramShardWorker` / `cachedTrigramBuildWorker` / `buildTrigramsFromCache` (L865): similar chunking + shards for trigrams (when `skip_outlines`).
  - `initialScan` (L1114) just picks `worker_count` (env `CODEDB_SCAN_WORKERS` or min(cpu,8)).
  - No TODO/FIXME/"parallelize the walk"/"stat in parallel" in the source (searches for TODO|parallel|serial|walk|stat etc. surface only test/docs/comments about the parse/merge side, or unrelated).
  - External claim (website/app/improvements.zig:253) says "FilteredWalker now uses thread-pool parallelism for directory traversal, saturating I/O... instead of single-threaded stat() calls" — not reflected in the impl.

**Other nearby/initial-scan context.**
- `InitialScanEntry` (L85) is the bridge between collect and parse.
- `shouldSkipFile` (L1399) + `shouldSkip`/`shouldSkipDir` are applied *after* collection (in parse paths).
- Snapshot side effect is only the size-only `recordSnapshot` (delegates to store.zig:67 `appendVersion`); full hash/content happens later.
- All verified via `codedb symbol`/`read`/`callers`/`outline` on `collectInitialScanEntries`, `FilteredWalker`, `parseInitialScanEntry`, `statFile` etc. (no other files contain the core walk).

**3 most load-bearing facts (with cites):**
1. The serial walk + first stat lives only in `collectInitialScanEntries:509` (L521 `while (try walker.next()) |entry| { const stat = dir.statFile(io, entry.path, .{}) ...; store.recordSnapshot... }`) and the two callers (L639, L987); this is the *only* place the ordered entry list + initial Store snapshots are produced for cold scans.
2. Path discovery (iterate/openDir/realPathFile/stat-on-symlinks only + pruning) is strictly inside `FilteredWalker.next:386` + `init:294` (e.g. L392 `iter.next`, L405/449 `openDir`, L425 `statFile`, L437 `realPathFile`); the post-walk `statFile` in collect is purely for size/snapshot (distinct from content stats in `parseInitialScanEntry:533` + `readIndexableFile:173`).
3. Parallelization applies only *after* collection (worker chunks of the entry list for parse/word/trigram shards; see `initialScanWithWorkerCount:623` L694-730 comments and `initialScanWithTrigrams:975`); the walk itself has no threads/TODOs about parallelizing stats or walking.

**1 open question:** Does any code path (e.g. via Explorer, background.zig:58 `scanBg`, or bootstrap coldLoadOrScan) ever invoke equivalent collection without going through `collectInitialScanEntries` (or the FilteredWalker used by incremental rescan)? (callers only showed the two direct sites + tests.)
