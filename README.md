<p align="center">
  <img src="assets/codedb.png" alt="codedb" width="200" />
</p>

<p align="center">
  <a href="https://github.com/justrach/codedb2/releases/latest"><img src="https://img.shields.io/github/v/release/justrach/codedb2?style=flat-square&label=version" alt="Release" /></a>
  <a href="https://github.com/justrach/codedb2/blob/main/LICENSE"><img src="https://img.shields.io/github/license/justrach/codedb2?style=flat-square" alt="License" /></a>
  <img src="https://img.shields.io/badge/zig-0.15-f7a41d?style=flat-square" alt="Zig 0.15" />
  <img src="https://img.shields.io/badge/status-alpha-orange?style=flat-square" alt="Alpha" />
  <a href="https://deepwiki.com/justrach/codedb2"><img src="https://deepwiki.com/badge.svg" alt="Ask DeepWiki" /></a>
</p>

<h1 align="center">codedb</h1>

<h3 align="center">Code intelligence server for AI agents. Zig core. MCP native. Zero dependencies.</h3>

<p align="center">
  Structural indexing · Trigram search · Word index · Dependency graph · File watching · MCP + HTTP
</p>

<p align="center">
  <a href="#-status">Status</a> ·
  <a href="#-install">Install</a> ·
  <a href="#-quick-start">Quick Start</a> ·
  <a href="#-mcp-tools">MCP Tools</a> ·
  <a href="#-benchmarks">Benchmarks</a> ·
  <a href="#️-architecture">Architecture</a> ·
  <a href="#-data--privacy">Data & Privacy</a> ·
  <a href="#-building-from-source">Building</a>
</p>

---

## Status

> **Alpha software — API is stabilizing but may change**
>
> codedb works and is used daily in production AI workflows, but:
> - **Language support** — Zig, Python, TypeScript/JavaScript (more planned)
> - **No auth** — HTTP server binds to localhost only
> - **Snapshot format** may change between versions
> - **MCP protocol** is JSON-RPC 2.0 over stdio (stable)

| What works today                                       | What's in progress                       |
|--------------------------------------------------------|------------------------------------------|
| 12 MCP tools for full codebase intelligence            | Additional language parsers              |
| Trigram-accelerated full-text search                   | WASM target for Cloudflare Workers       |
| O(1) inverted word index for identifier lookup         | Incremental snapshot updates             |
| Structural outlines (functions, structs, imports)      | Multi-project support                    |
| Reverse dependency graph                               | Remote indexing over SSH                  |
| Atomic line-range edits with version tracking          |                                          |
| Auto-registration in Claude, Codex, Gemini, Cursor     |                                          |
| Polling file watcher with filtered directory walker    |                                          |
| Portable snapshot for instant MCP startup              |                                          |
| Multi-agent support with file locking + heartbeats     |                                          |
| Codesigned + notarized macOS binaries                  |                                          |
| Cross-platform: macOS (ARM/x86), Linux (ARM/x86)      |                                          |

---

## ⚡ Install

```bash
curl -fsSL https://codedb.codegraff.com/install.sh | sh
```

Downloads the binary for your platform and auto-registers codedb as an MCP server in **Claude Code**, **Codex**, **Gemini CLI**, and **Cursor**.

| Platform | Binary | Signed |
|----------|--------|--------|
| macOS ARM64 (Apple Silicon) | `codedb-darwin-arm64` | ✅ codesigned + notarized |
| macOS x86_64 (Intel) | `codedb-darwin-x86_64` | ✅ codesigned + notarized |
| Linux ARM64 | `codedb-linux-arm64` | — |
| Linux x86_64 | `codedb-linux-x86_64` | — |

Or install manually from [GitHub Releases](https://github.com/justrach/codedb2/releases/latest).

---

## ⚡ Quick Start

### As an MCP server (recommended)

After installing, codedb is automatically registered. Just open a project and the 12 MCP tools are available to your AI agent.

```bash
# Manual MCP start (auto-configured by install script)
codedb mcp /path/to/your/project
```

### As an HTTP server

```bash
codedb serve /path/to/your/project
# listening on localhost:7719
```

### CLI

```bash
codedb tree /path/to/project          # file tree with symbol counts
codedb outline src/main.zig           # symbols in a file
codedb find AgentRegistry             # find symbol definitions
codedb search "handleAuth"            # full-text search (trigram-accelerated)
codedb word Store                     # exact word lookup (inverted index, O(1))
codedb hot                            # recently modified files
```

---

## 🔧 MCP Tools

12 tools over the Model Context Protocol (JSON-RPC 2.0 over stdio):

| Tool | Description |
|------|-------------|
| `codedb_tree` | Full file tree with language, line counts, symbol counts |
| `codedb_outline` | Symbols in a file: functions, structs, imports, with line numbers |
| `codedb_symbol` | Find where a symbol is defined across the codebase |
| `codedb_search` | Trigram-accelerated full-text search |
| `codedb_word` | O(1) inverted index word lookup |
| `codedb_hot` | Most recently modified files |
| `codedb_deps` | Reverse dependency graph (which files import this file) |
| `codedb_read` | Read file content |
| `codedb_edit` | Apply line-range edits (atomic writes) |
| `codedb_changes` | Changed files since a sequence number |
| `codedb_status` | Index status (file count, current sequence) |
| `codedb_snapshot` | Full pre-rendered JSON snapshot of the codebase |

### Example: agent explores a codebase

```bash
# 1. Get the file tree
curl localhost:7719/tree
# → src/main.zig      (zig, 55L, 4 symbols)
#   src/store.zig     (zig, 156L, 12 symbols)
#   src/agent.zig     (zig, 135L, 8 symbols)

# 2. Drill into a file
curl "localhost:7719/outline?path=src/store.zig"
# → L20: struct_def Store
#   L30: function init
#   L55: function recordSnapshot

# 3. Find a symbol across the codebase
curl "localhost:7719/symbol?name=AgentRegistry"
# → {"path":"src/agent.zig","line":30,"kind":"struct_def"}

# 4. Full-text search
curl "localhost:7719/search?q=handleAuth&max=10"

# 5. Check what changed
curl "localhost:7719/changes?since=42"
```

---

## 📊 Benchmarks

Measured on Apple M4 Pro, 48GB RAM. MCP = pre-indexed warm queries (20 iterations avg). CLI/external tools include process startup (3 iterations avg). Ground truth verified against Python reference implementation.

### Latency — codedb MCP vs codedb CLI vs ast-grep vs ripgrep vs grep

**codedb2 repo** (20 files, 12.6k lines):

| Query | codedb MCP | codedb CLI | ast-grep | ripgrep | grep | MCP speedup |
|-------|-----------|-----------|----------|---------|------|-------------|
| File tree | **0.04 ms** | 52.9 ms | — | — | — | **1,253x** vs CLI |
| Symbol search (`init`) | **0.10 ms** | 54.1 ms | 3.2 ms | 6.3 ms | 6.5 ms | **549x** vs CLI |
| Full-text search (`allocator`) | **0.05 ms** | 60.7 ms | 3.2 ms | 5.3 ms | 6.6 ms | **1,340x** vs CLI |
| Word index (`self`) | **0.04 ms** | 59.7 ms | n/a | 7.2 ms | 6.5 ms | **1,404x** vs CLI |
| Structural outline | **0.05 ms** | 53.5 ms | 3.1 ms | — | 2.4 ms | **1,143x** vs CLI |
| Dependency graph | **0.05 ms** | 2.2 ms | n/a | n/a | n/a | **45x** vs CLI |

**merjs repo** (100 files, 17.3k lines):

| Query | codedb MCP | codedb CLI | ast-grep | ripgrep | grep | MCP speedup |
|-------|-----------|-----------|----------|---------|------|-------------|
| File tree | **0.05 ms** | 54.0 ms | — | — | — | **1,173x** vs CLI |
| Symbol search (`init`) | **0.07 ms** | 54.4 ms | 3.4 ms | 6.3 ms | 3.6 ms | **758x** vs CLI |
| Full-text search (`allocator`) | **0.03 ms** | 54.1 ms | 2.9 ms | 5.1 ms | 3.7 ms | **1,554x** vs CLI |
| Word index (`self`) | **0.04 ms** | 54.7 ms | n/a | 6.3 ms | 4.2 ms | **1,518x** vs CLI |
| Structural outline | **0.04 ms** | 54.9 ms | 3.4 ms | — | 2.5 ms | **1,243x** vs CLI |
| Dependency graph | **0.05 ms** | 1.9 ms | n/a | n/a | n/a | **41x** vs CLI |

### Token Efficiency

codedb returns structured, relevant results — not raw line dumps. For AI agents, this means dramatically fewer tokens per query:

| Repo | codedb MCP | ripgrep / grep | Reduction |
|------|-----------|---------------|-----------|
| codedb2 (search `allocator`) | ~20 tokens | ~32,564 tokens | **1,628x fewer** |
| merjs (search `allocator`) | ~20 tokens | ~4,007 tokens | **200x fewer** |

### Indexing Speed

codedb builds **all** indexes on startup (outlines, trigram, word, dependency graph) — not just a parse tree:

| Repo | Files | Lines | Cold start | Per file |
|------|-------|-------|-----------|----------|
| codedb2 | 20 | 12.6k | **17 ms** | 0.85 ms |
| merjs | 100 | 17.3k | **16 ms** | 0.16 ms |
| [openclaw/openclaw](https://github.com/openclaw/openclaw) | 11,281 | 2.29M | **75 s** | 6.66 ms |
| [vitessio/vitess](https://github.com/vitessio/vitess) | 5,028 | 2.18M | **50 s** | 9.95 ms |
Indexes are built once on startup. After that, the file watcher keeps them updated incrementally (single-file re-index: **<2ms**). Queries never re-scan the filesystem.


### Why codedb is fast

- **MCP server** indexes once on startup → all queries hit in-memory data structures (O(1) hash lookups)
- **CLI** pays ~55ms process startup + full filesystem scan on every invocation
- **ast-grep** re-parses all files through tree-sitter on every call (~3ms)
- **ripgrep/grep** brute-force scan every file on every call (~5-7ms)
- The MCP advantage: **index once, query thousands of times at sub-millisecond latency**

### Feature Matrix

| Feature | codedb MCP | codedb CLI | ast-grep | ripgrep | grep | ctags |
|---------|-----------|-----------|----------|---------|------|-------|
| Structural parsing | ✅ | ✅ | ✅ | ❌ | ❌ | ✅ |
| Trigram search index | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ |
| Inverted word index | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ |
| Dependency graph | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ |
| Version tracking | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ |
| Multi-agent locking | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ |
| Pre-indexed (warm) | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ |
| No process startup | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ |
| MCP protocol | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ |
| Full-text search | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| Atomic file edits | ✅ | ✅ | ✅ | ❌ | ❌ | ❌ |
| File watcher | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ |

> **codedb = tree-sitter + search index + dependency graph + agent runtime.** Zero external dependencies. Pure Zig. Single binary.


---

## 🏗️ Architecture

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
```

**No SQLite. No dependencies.** Purpose-built data model:

- **Explorer** — structural index engine. Parses Zig, Python, TypeScript/JavaScript. Maintains outlines, trigram index, inverted word index, content cache, and dependency graph behind a single mutex.
- **Store** — append-only version log. Every mutation (snapshot, edit, delete) gets a monotonically increasing sequence number. Version history capped at 100 per file.
- **Watcher** — polling file watcher (2s interval). `FilteredWalker` prunes `.git`, `node_modules`, `zig-cache`, `__pycache__`, etc. before descending.
- **Agents** — first-class structs with cursors, heartbeats, and exclusive file locks. Stale agents reaped after 30s.

### Threading Model

| Thread | Role |
|--------|------|
| Main | HTTP accept loop or MCP read loop |
| Watcher | Polls filesystem every 2s via `FilteredWalker` |
| ISR | Rebuilds snapshot when stale flag is set |
| Reap | Cleans up stale agents every 5s |
| Per-connection | HTTP server spawns a thread per connection |

All threads share a `shutdown: atomic.Value(bool)` for graceful termination.

---

## 🔒 Data & Privacy

codedb keeps runtime data local by default. Telemetry, when enabled, is written to `~/.codedb/telemetry.ndjson` on the same machine and is not uploaded automatically.

| Location | Contents | Purpose |
|----------|----------|---------|
| `~/.codedb/projects/<hash>/` | Trigram index, frequency table, data log | Persistent index cache |
| `~/.codedb/telemetry.ndjson` | Aggregate tool calls and startup stats | Local telemetry log |
| `./codedb.snapshot` | File tree, outlines, content, frequency table | Portable snapshot for instant MCP startup |

**Not stored:** No source code is sent anywhere. No file contents, file paths, or search queries are collected in telemetry. Sensitive files auto-excluded (`.env*`, `credentials.json`, `secrets.*`, `.pem`, `.key`, SSH keys, AWS configs).

To disable the local telemetry log entirely, set `CODEDB_NO_TELEMETRY=1`.

To sync the local NDJSON file into Postgres for analysis or dashboards, use [`scripts/sync-telemetry.py`](./scripts/sync-telemetry.py) with the schema in [`docs/telemetry/postgres-schema.sql`](./docs/telemetry/postgres-schema.sql). The data flow is documented in [`docs/telemetry.md`](./docs/telemetry.md).

```bash
rm -rf ~/.codedb/          # clear all cached indexes
rm -f codedb.snapshot      # remove snapshot from project
```

---

## 🔨 Building from Source

**Requirements:** Zig 0.15+

```bash
git clone https://github.com/justrach/codedb2.git
cd codedb2
zig build                              # debug build
zig build -Doptimize=ReleaseFast       # release build
zig build test                         # run tests
zig build bench                        # run benchmarks
```

Binary: `zig-out/bin/codedb`

### Cross-compilation

```bash
zig build -Doptimize=ReleaseFast -Dtarget=x86_64-linux
zig build -Doptimize=ReleaseFast -Dtarget=aarch64-linux
zig build -Doptimize=ReleaseFast -Dtarget=x86_64-macos
```

### Releasing

```bash
./release.sh 0.2.0              # build, codesign, notarize, upload to GitHub Releases
./release.sh 0.2.0 --dry-run    # preview without executing
```

---

## License

See [LICENSE](LICENSE) for details.
