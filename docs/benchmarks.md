# codedb2 Benchmarks

Benchmarked on Apple Silicon (M-series), Zig 0.15.1, macOS.

## Cold Start (Indexing)

Time to walk, stat, read, and parse all source files into the in-memory index.

| Codebase | Files | Size | Index Time |
|---|---|---|---|
| codedb2 (self) | 16 | 56KB | <50ms |
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
