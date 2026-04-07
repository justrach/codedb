# Changelog

## v0.2.55 (2026-04-07)

### New Features

- **Fuzzy file search (`codedb_find`)** — Smith-Waterman scoring with typo/transposition tolerance, multi-part queries (`"snapshot json"`), extension constraints (`"auth *.py"`), entry point bonuses. 100% top-3 recall across 82 test queries.
- **Composable search pipeline (`codedb_query`)** — Chain operations in one call: `find → filter → outline`. Reduces round-trips from 3-5 to 1.
- **mmap-backed trigram index** — Binary search on memory-mapped disk files. ~0 RSS for the trigram index (OS page cache). 121MB RSS reduction on 5k-file repos.
- **mmap overlay pattern** — Incremental updates without rebuilding. Watcher adds files to a small heap overlay on top of the immutable mmap base.
- **Combo-boost ranking** — Files previously opened after similar queries rank higher (+5.0 per historical open). Powered by local query WAL.
- **Query WAL profiling** — Every search/find/word query and read/outline access logged to `~/.codedb/projects/<hash>/queries.log` with microsecond latency.
- **Cloud telemetry sync** — Hashed query/path data (no PII) synced to Postgres on MCP shutdown. Respects `--no-telemetry`.
- **Memory diagnostics in `codedb_status`** — Shows outline count, content cache, trigram index type (heap/mmap/mmap+overlay), index memory in KB.
- **MCP client identity** — Extracts `clientInfo.name` from initialize for agent tracking.
- **`codedb nuke` command** — Kill all processes, remove `~/.codedb/`, clean all project snapshots. Works from any directory.
- **Search auto-retry** — Strips delimiters and retries when 0 results.
- **Per-file match truncation** — Search output limits to 5 matches per file to save tokens.

### Bug Fixes

- **u16 file count truncation** — mmap cache comparison was truncated to 65K, broke instant startup for repos >65K files. Now u32.
- **ANSI escape stripping** — Was only removing ESC byte, leaving `[32m` garbage. Now full ECMA-48 CSI parsing.
- **C/C++/Rust/Zig block comments** — `/* */` tracking was only for JS/TS/Go. Phantom symbols from commented-out code eliminated.
- **Code after `*/` on same line** — `/* comment */ pub fn foo()` was skipped entirely. Now parsed.
- **Python docstrings** — Only caught bare `"""` lines. Now catches `"""text`, `x = """`, `'''text` anywhere on line.
- **Telemetry data race** — `call_count` was mutated outside lock (UB). Moved inside `write_lock`.
- **Telemetry file sync race** — `syncToCloud` now holds lock during file upload+truncate.
- **mmap_overlay alloc safety** — Merge path silently dropped candidates on allocation pressure. Now returns null (triggers full scan fallback).
- **Home directory blocking** — `root_policy` now denies `$HOME`, `/root`, `/home/<user>`, `/Users/<user>` to prevent 17GB RAM spike.
- **Double-join UB** — `scan_thread` was joined twice (POSIX undefined behavior). Removed duplicate.
- **`codedb update` fix** — CDN install script failed silently on macOS. Now downloads directly from GitHub releases.
- **Install script URL** — Changed from CDN to GitHub releases for binary downloads.
- **Idle timeout** — Increased from 2 minutes to 10 minutes. Added POLLHUP detection for instant exit on client disconnect.

### Performance

- **Process lifecycle** — Shutdown gates in `scanBg` between all phases. Sub-second shutdown via 1s sleep granularity.
- **`releaseContents` uses `clearAndFree`** — Fully releases HashMap bucket memory (~160KB reclaimed).
- **Additional skip dirs** — `.swc`, `.terraform`, `.serverless`, `elm-stuff`, `.stack-work`, `.cabal-sandbox`, `.cargo`, `bower_components`.
- **CI bench hardening** — `--min-abs-ns` threshold prevents false positives on fast tools. New tools handled gracefully.

### Testing

- 60+ new tests covering mmap, fuzzy search, pipeline, recall, overlay, parser fixes, coverage gaps.
- Codex-verified test coverage audit with gap fixes.

## v0.2.54 (2026-04-06)

- Initial mmap trigram index release
- See GitHub releases for prior changelog
