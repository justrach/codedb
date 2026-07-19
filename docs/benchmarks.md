# codedb Benchmarks

## 0.2.5831 verified output, latency, and recall audit

The 0.2.5831 audit adds machine-readable evidence and an explicit retrieval
recall gate. The code candidate is
`0478eff8dbef2cd2daa6cbd7413d4529ba932d1d`; measurements were taken on an
Apple M4 Pro with 48 GB RAM and macOS 26.5.1.

| Measurement | Baseline | Candidate | Change |
|---|---:|---:|---:|
| `codedb_context` core tokens, 10 tasks | 13,288 | 4,848 | **−63.52%** |
| Context anchor recall, micro | 14 / 29 (48.28%) | 14 / 29 (48.28%) | unchanged |
| Context anchor recall, macro | 54.17% | 54.17% | unchanged |
| Tasks preserving recall | — | 10 / 10 | parity gate passed |
| Generated-fixture cold scan | 123.299 ms | 87.092 ms | **−29.37%** |
| Hot-word output | 611,915 B | 371 B | **−99.94%** |
| Common-search output | 1,324,470 B | 1,766 B | **−99.87%** |
| Huge-outline output | 291,056 B | 16,152 B | **−94.45%** |

Anchor recall measures whether named task-intent markers appear in returned
context. It is a deterministic retrieval regression check, not a semantic
answer-accuracy score. The suite's absolute micro recall is 48.28% and its macro
per-task recall is 54.17%; both are published so “unchanged recall” has a clear
denominator.

The edge suite includes all 22 cases, including two remaining latency
regressions: uncached ranked search (0.996 ms → 7.668 ms) and the hot-callers
case (0.030 ms → 0.067 ms). The full report explains compiler and binary
provenance, exact methodology, the paired outline measurement, exploratory
trigram observations, implementation and security findings, verification, and
the normalized three-engine sandbox comparison.

- [Full 0.2.5831 performance and recall report](performance-0.2.5831.md)
- [Machine-readable 0.2.5831 results](../bench/results/0.2.5831/results.json)
- [Raw normalized engine-comparison runs](../bench/results/0.2.5831/engine-comparison.json)

### Normalized 1:1 comparison with other engines

The issue [#679](https://github.com/justrach/codedb/issues/679) trial used
`justrach/smolify@835070d`, the exact symbol `toFtsMatch`, and separate Linux
x86_64 sandboxes with 2 vCPU and 2 GB RAM on one gateway node. Cold indexing
used a clean cache. Warm tasks used one warmup plus 10 separate CLI-process
runs. Results are **p50 / p95 process wall time · output bytes / tokens · anchor
recall**.

| Same outcome | **codedb 0.2.5831** | [codebase-memory-mcp 0.9.0](https://github.com/DeusData/codebase-memory-mcp) | [GitNexus 1.6.9](https://github.com/abhigyanpatwari/GitNexus) |
|---|---:|---:|---:|
| Exact definition | **0.711 / 0.741 ms · 250 B / 74 tok · 2/2** | 11.815 / 15.351 ms · 1,273 B / 515 tok · 2/2 | 1,729.866 / 1,770.555 ms · 889 B / 274 tok · 2/2 |
| Direct production caller | **0.480 / 0.522 ms** · 951 B / 299 tok · 1/1 | 6.730 / 9.252 ms · **177 B / 44 tok** · 1/1 | 1,712.238 / 1,741.577 ms · 889 B / 274 tok · **0/1** |
| Definition + caller + callee | **0.494 / 0.535 ms · 594 B / 182 tok · 3/3** | 8.156 / 11.335 ms · 1,664 B / 627 tok · 3/3 | 1,720.325 / 1,755.486 ms · 1,170 B / 355 tok · **2/3** |

| Cold metric | **codedb 0.2.5831** | [codebase-memory-mcp 0.9.0](https://github.com/DeusData/codebase-memory-mcp) | [GitNexus 1.6.9](https://github.com/abhigyanpatwari/GitNexus) |
|---|---:|---:|---:|
| Index wall time | **186.293 ms** | 422.518 ms | 8,305.209 ms |
| Peak child RSS | **41,360 KiB** | 85,304 KiB | 709,348 KiB |
| Persistent index | 5,027,199 B | **4,759,552 B** | 28,815,656 B |

Each engine received its closest documented one-call operation for the same
outcome. GitNexus missed the production caller in that operation;
codebase-memory produced the smallest caller response and persistent index.
Warm CLI results include process startup and index loading. See the
[full protocol, ground truth, and limitations](performance-0.2.5831.md#normalized-11-sandbox-comparison).

## Historical benchmarks

The remaining measurements on this page predate the 0.2.5831 audit. They were
benchmarked on Apple Silicon (M-series), Zig 0.15.1, and macOS; treat their
hardware, compiler, fixture, and methodology as separate from the release gate
above.

## Cold Start (Indexing)

Time to walk, stat, read, and parse all source files into the in-memory index.

| Codebase | Files | Size | Index Time |
|---|---|---|---|
| codedb (self) | 16 | 56KB | <50ms |
| openclaw/openclaw | 7,364 | 128MB | **2.9s** |

Previously 35s on openclaw — reduced by **12x** via:
- Skipping 37 junk directories (node_modules, .git, dist, build, __pycache__, target, vendor, etc.)
- Skipping 40+ binary file extensions (png, jpg, wasm, ttf, lock, etc.)
- 512KB file size cap (skips minified bundles)
- Binary content detection (null byte check in first 512B)
- Deferred word/trigram indexing (outline-only on startup, search indexes built lazily)

## Hot Query Performance (MCP Server)

After the one-time cold start, all queries run against the in-memory index.  
Tested on openclaw/openclaw (7,364 files, 128MB TypeScript monorepo).

| Tool | Latency | Response Size | What it does |
|---|---|---|---|
| `codedb_status` | **0.1ms** | 135B | Seq counter + file count |
| `codedb_word` | **0.2ms** | 112B | O(1) inverted index lookup |
| `codedb_outline` | **0.7ms** | 9.7KB | Symbols + line numbers for a file |
| `codedb_deps` | **1.3ms** | 162B | Reverse dependency graph lookup |
| `codedb_hot` | **3.6ms** | 399B | Most recently modified files |
| `codedb_symbol` | **3.9ms** | 4.4KB | Find all definitions of a symbol |
| `codedb_tree` | **29ms** | 549KB | Full file tree with metadata |
| `codedb_search` | **49ms** | 5.1KB | Trigram-accelerated substring search |

## Synthetic Microbenchmarks

From `zig build bench` (500 files, 100K lines, 7MB synthetic content):

| Operation | Latency |
|---|---|
| Word index lookup | **4ns/query** |
| Trigram search | **110μs/query** |
| Brute force search | **603μs/query** |

Trigram index is **5.5x faster** than brute force substring search.

## codedb vs Raw Tools

Side-by-side comparison on openclaw/openclaw. "Raw" = grep/find/cat (what an AI agent uses without codedb).

| Task | Raw (grep/find) | codedb (hot) | Speed | Bytes |
|---|---|---|---|---|
| Project tree | 87ms, 313KB | **29ms**, 549KB | **3x** faster | +metadata |
| Read file (773 lines) | 27ms, 24.7KB | **0.7ms**, 9.7KB | **38x** faster | **2.5x** less |
| Find symbol | 763ms, 7.7KB | **3.9ms**, 4.4KB | **200x** faster | 1.8x less |
| Text search | 283ms, 5.3KB | **49ms**, 5.1KB | **6x** faster | same |
| Word lookup | 65ms, 4.7KB | **0.2ms**, 112B | **325x** faster | **42x** less |
| Reverse deps | 750ms, 15KB | **1.3ms**, 162B | **469x** faster | **92x** less |

### Full Edit Workflow

An agent editing a function in a 773-line file:

| Step | Raw | codedb + muonry |
|---|---|---|
| Understand file | Read entire file (24.7KB) | Outline (9.7KB) |
| Find function | Scan output | Symbol-mode read (~1.5KB) |
| Make edit | edit_file (old_str/new_str) | Symbol-mode edit (line-drift immune) |
| Verify | Re-read file (24.7KB) | diff (~300B) |
| **Total** | **~50KB** | **~12KB** |
| **Savings** | — | **4x fewer bytes** |

## Incremental Watcher

Background thread polls for filesystem changes every 2 seconds.

| Property | Value |
|---|---|
| Poll interval | 2s |
| Change detection | Two-stage: mtime (stat) → content hash (wyhash) |
| False positive handling | Hash match after mtime change = skip re-index |
| Memory per cycle | Per-cycle arena allocator (freed after each poll) |
| Memory per file | 8 bytes (mtime i64) + 8 bytes (hash u64) = 16 bytes |
| Binary files | Skipped (40+ extensions + null byte detection) |
| Large files | Skipped (>512KB) |
| Junk directories | Skipped (37 patterns including node_modules, .git, dist, etc.) |

### Change Detection Flow

```
stat() every file (cheap, no IO)
  │
  ├─ mtime unchanged → skip (zero cost)
  │
  └─ mtime changed → read file, compute wyhash
       │
       ├─ hash matches stored → update mtime only (no re-index)
       │   (handles: touch, git checkout, save-without-change)
       │
       └─ hash differs → re-index file (actual content change)
```

## Architecture

```
Store           append-only version chains, global monotonic seq, data log
AgentRegistry   first-class agents, advisory locks with TTL, heartbeat + auto-reap
Explorer        symbol index (Zig/Python/TS/JS parsers), dep graph, content storage
WordIndex       inverted word → (path, line) index, O(1) lookup
TrigramIndex    3-byte sequence → file set index, intersection-based candidate filtering
Watcher         mtime + hash change detection, 2s polling, per-cycle arena
EditEngine      line-based replace/insert/delete with lock acquisition + provenance
MCP Server      JSON-RPC 2.0 over stdio, 11 tools
HTTP Server     JSON API on :7719
```

## Skip Lists

### Directories (37 patterns)

```
.git  .claude  .codedb  node_modules  .zig-cache  zig-out  .next  .nuxt  .svelte-kit
dist  build  .build  .output  out  __pycache__  .venv  venv  .env  .tox
.mypy_cache  .pytest_cache  .ruff_cache  target  .gradle  .idea  .vs
vendor  Pods  .dart_tool  .pub-cache  coverage  .nyc_output  .turbo
.parcel-cache  .cache  .tmp  .temp  .DS_Store
```

### File Extensions (40+ patterns)

```
Images:   .png .jpg .jpeg .gif .bmp .ico .icns .webp .svg
Fonts:    .ttf .otf .woff .woff2 .eot
Archives: .zip .tar .gz .bz2 .xz .7z .rar
Docs:     .pdf .doc .docx .xls .xlsx .pptx
Media:    .mp3 .mp4 .wav .avi .mov .flv .ogg .webm
Binaries: .exe .dll .so .dylib .o .a .lib .wasm .pyc .pyo .class
Data:     .db .sqlite .sqlite3
Locks:    .lock .sum
```
