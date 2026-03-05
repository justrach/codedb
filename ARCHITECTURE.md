# codedb2 — Architecture & Design

A lightweight, zero-dependency code intelligence server written in Zig. Indexes a codebase at startup, watches for changes, and serves structural queries over HTTP and MCP (Model Context Protocol).

## Overview

codedb2 scans a project directory, builds in-memory indexes (outlines, symbols, trigrams, word index, dependency graph), and exposes them via two interfaces:

- **HTTP server** on `:7719` — REST-style JSON API
- **MCP server** over stdio — JSON-RPC for tool-calling LLMs

Both interfaces share the same core: `Explorer` (code intelligence), `Store` (version tracking), and `Prerender` (cached snapshots).

## Modules

### `main.zig` — CLI Entry Point

Parses args, resolves the project root, runs an initial scan, then dispatches to one of:

| Command | Description |
|---------|-------------|
| `tree` | Print file tree with symbol counts |
| `outline <path>` | Show symbols in a file |
| `find <name>` | Find a symbol definition |
| `search <query>` | Full-text search (trigram-accelerated) |
| `word <id>` | Exact word lookup (inverted index, O(1)) |
| `hot` | Recently modified files |
| `serve` | Start HTTP daemon on :7719 |
| `mcp` | Start MCP server (JSON-RPC over stdio) |

Data is stored per-project at `~/.codedb/projects/<hash>/`.

### `explore.zig` — Code Intelligence Engine

The central struct. Holds all indexed data behind a single mutex.

**Data structures:**
- `outlines: StringHashMap(FileOutline)` — per-file symbol lists (functions, structs, enums, imports)
- `contents: StringHashMap([]const u8)` — raw file content cache
- `dep_graph: StringHashMap(ArrayList([]const u8))` — file → imported files
- `word_index: WordIndex` — inverted word index for O(1) identifier lookup
- `trigram_index: TrigramIndex` — trigram index for fast substring search

**Language parsers:** Zig, Python, TypeScript/JavaScript. Each parser extracts functions, classes/structs, constants, imports, and test declarations from source lines.

**Key operations:**
- `indexFile(path, content)` — parse + index a file (outline, content, words, trigrams, deps)
- `indexFileOutlineOnly(path, content)` — fast path for initial scan (skips search indexes)
- `removeFile(path)` — clean removal from all maps and indexes
- `getTree()` — sorted file tree with directory nodes and symbol counts
- `findSymbol(name)` / `findAllSymbols(name)` — symbol lookup across all files
- `searchContent(query, max)` — trigram-accelerated full-text search
- `searchWord(word)` — O(1) inverted index lookup
- `getImportedBy(path)` — reverse dependency lookup
- `getHotFiles(store, limit)` — files sorted by most recent change sequence

### `index.zig` — Search Indexes

**WordIndex** — inverted index mapping words to `(path, line_num)` hits. Tokenizes content into identifiers, skipping single-character tokens. Supports efficient re-indexing via per-file word tracking. Deduplicates results by `(path, line)`.

**TrigramIndex** — maps 3-byte character sequences to file sets. Used to narrow full-text search candidates before brute-force scanning. Queries < 3 chars fall back to brute force. Intersection of trigram sets gives candidate files.

### `store.zig` — Version Store

Append-only version log per file. Each mutation (snapshot, edit, delete) gets a monotonically increasing sequence number.

**Key features:**
- `recordSnapshot/recordEdit/recordDelete` — append a version entry
- `getLatest(path)` / `getAtCursor(path, cursor)` — version queries (return by value for safety)
- `changesSince(seq)` / `changesSinceDetailed(seq)` — change tracking for polling clients
- `currentSeq()` — atomic sequence counter
- Optional `data.log` file for persisting diff data
- Version history capped at 100 entries per file

### `version.zig` — Version Types

- `Version` — seq, agent, timestamp, op, hash, size, data offset/len
- `Op` — snapshot | replace | insert | delete | tombstone
- `FileVersions` — ordered list of versions for a single file path

### `watcher.zig` — File System Watcher

Polling-based file watcher (2-second interval). Uses mtime + content hash to detect changes.

**FilteredWalker** — custom directory walker that prunes `.git`, `node_modules`, `.next`, `target`, `zig-out`, `zig-cache`, `__pycache__`, `.venv`, `dist`, `build` directories *before* descending. This prevents the CPU-hogging bug where `std.fs.Dir.walk()` would traverse tens of thousands of files in ignored directories every poll cycle.

**Flow:**
1. `initialScan` — walk all files, index outlines (fast path, no search indexes)
2. `incrementalLoop` — poll every 2s, detect added/modified/deleted files
3. `incrementalDiff` — compare current filesystem state against cached `FileMap`, push `FsEvent`s to `EventQueue`

**EventQueue** — bounded ring buffer (256 entries) for filesystem events. Non-blocking push, blocking pop. Used to feed events to the HTTP server's SSE endpoint.

### `server.zig` — HTTP Server

Thread-per-connection HTTP server on `:7719`. Parses raw HTTP/1.1 requests.

**Endpoints:**

| Route | Method | Description |
|-------|--------|-------------|
| `/tree` | GET | File tree |
| `/outline?path=` | GET | File outline |
| `/symbol?name=` | GET | Find symbol definitions |
| `/search?q=&max=` | GET | Full-text search |
| `/word?w=` | GET | Inverted index word lookup |
| `/hot?limit=` | GET | Recently modified files |
| `/deps?path=` | GET | Reverse dependencies |
| `/read?path=` | GET | Read file content |
| `/edit` | POST | Apply a line-range edit |
| `/changes?since=` | GET | Changed files since sequence N |
| `/status` | GET | File count + current sequence |
| `/snapshot` | GET | Full pre-rendered JSON snapshot |
| `/events` | GET | SSE stream of file change events |

**Safety:** path traversal prevention (`isPathSafe`), JSON string escaping for user input, POST body size cap, FD leak protection on thread spawn failure.

### `mcp.zig` — MCP Server

JSON-RPC 2.0 over stdio with Content-Length framing. Implements the Model Context Protocol for LLM tool use.

**Tools exposed:**

| Tool | Description |
|------|-------------|
| `codedb_tree` | File tree |
| `codedb_outline` | File outline |
| `codedb_symbol` | Symbol lookup |
| `codedb_search` | Full-text search |
| `codedb_word` | Word index lookup |
| `codedb_hot` | Hot files |
| `codedb_deps` | Reverse dependencies |
| `codedb_read` | Read file content |
| `codedb_edit` | Apply edits |
| `codedb_changes` | Changes since seq |
| `codedb_status` | Index status |
| `codedb_snapshot` | Full snapshot |

**Safety:** path validation, oversized message handling (drains >1MB lines instead of killing the loop).

### `edit.zig` — File Editor

Line-range editing engine. Supports `replace` and `delete` operations on line ranges.

**Atomic writes:** writes to a `.codedb_tmp` temp file then renames, preventing corruption on crash. Returns `EditResult` with new content, hash, size, and line count.

### `prerender.zig` — Snapshot Cache (ISR)

Next.js-inspired incremental static regeneration. Pre-computes a full JSON snapshot containing tree, all outlines, symbol index, and dependency graph.

- `getSnapshot()` — returns an owned copy of the cached blob (rebuilds if stale)
- `invalidate()` — atomic flag set on file changes
- `isrLoop()` — background thread polls every 2s, rebuilds when stale
- `rebuild()` — builds deterministic JSON (sorted keys) from Explorer state

### `agent.zig` — Agent Registry

Multi-agent support. Agents register with names, get assigned integer IDs. Supports file locking (exclusive per-agent) and heartbeat-based stale agent reaping (30s timeout).

### `build.zig` — Build Configuration

Zig 0.15.x build system. Produces:
- `codedb` CLI executable
- Test runner (`zig build test`)
- Benchmarks (`zig build bench`)
- Importable `codedb` module via `src/lib.zig`

## Architecture Diagram

```
┌─────────────┐     ┌─────────────┐
│  HTTP :7719 │     │  MCP stdio  │
│  server.zig │     │  mcp.zig    │
└──────┬──────┘     └──────┬──────┘
       │                   │
       └───────┬───────────┘
               │
    ┌──────────▼──────────┐
    │     Explorer        │
    │   explore.zig       │
    │  ┌───────────────┐  │
    │  │ WordIndex      │  │
    │  │ TrigramIndex   │  │
    │  │ Outlines       │  │
    │  │ Contents       │  │
    │  │ DepGraph       │  │
    │  └───────────────┘  │
    └──────────┬──────────┘
               │
    ┌──────────▼──────────┐
    │      Store          │──── data.log
    │    store.zig        │
    └──────────┬──────────┘
               │
    ┌──────────▼──────────┐
    │     Watcher         │ ← polls every 2s
    │   watcher.zig       │
    │  (FilteredWalker)   │
    └─────────────────────┘

    ┌─────────────────────┐
    │   Prerender (ISR)   │ ← background rebuild
    │  prerender.zig      │
    └─────────────────────┘
```

## Threading Model

- **Main thread** — runs HTTP accept loop or MCP read loop
- **Watcher thread** — `incrementalLoop`, polls filesystem every 2s
- **ISR thread** — `isrLoop`, rebuilds snapshot when stale flag is set
- **Reap thread** — `reapLoop`, cleans up stale agents every 5s
- **Per-connection threads** — HTTP server spawns a thread per connection

All threads share a `shutdown: std.atomic.Value(bool)` flag for graceful termination.

## Data Flow

1. **Startup:** `initialScan` walks the project (via `FilteredWalker`), indexes each file's outline and content into `Explorer`, records snapshots in `Store`
2. **Steady state:** `incrementalLoop` detects changes, re-indexes modified files, pushes events to `EventQueue`, invalidates `Prerender`
3. **Queries:** HTTP/MCP handlers call `Explorer` methods under its mutex, return JSON responses
4. **Edits:** `/edit` applies line-range changes atomically, re-indexes the file, records the edit in `Store`
