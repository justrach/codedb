<p align="center">
  <img src="assets/codedb.png" alt="codedb" width="200" />
</p>

<p align="center">
  <a href="https://github.com/justrach/codedb/releases/latest"><img src="https://img.shields.io/github/v/release/justrach/codedb?style=flat-square&label=version" alt="Release" /></a>
  <a href="https://github.com/justrach/codedb/blob/main/LICENSE"><img src="https://img.shields.io/github/license/justrach/codedb?style=flat-square" alt="License" /></a>
  <img src="https://img.shields.io/badge/zig-0.15-f7a41d?style=flat-square" alt="Zig 0.15" />
  <img src="https://img.shields.io/badge/status-alpha-orange?style=flat-square" alt="Alpha" />
  <a href="https://deepwiki.com/justrach/codedb"><img src="https://deepwiki.com/badge.svg" alt="Ask DeepWiki" /></a>
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
> - **Language support** — Zig, Python, TypeScript/JavaScript, Rust, PHP, C# (more planned)
> - **No auth** — HTTP server binds to localhost only
> - **Snapshot format** may change between versions
> - **MCP protocol** is JSON-RPC 2.0 over stdio (stable)

| What works today                                       | What's in progress                       |
|--------------------------------------------------------|------------------------------------------|
| 16 MCP tools for full codebase intelligence            | Additional language parsers (HCL/Go)     |
| Trigram v2: integer doc IDs, batch-accumulate, merge intersect | Incremental segment-based indexing |
| 538x faster than ripgrep on pre-indexed queries        | WASM target for Cloudflare Workers       |
| O(1) inverted word index for identifier lookup         | Multi-project support                    |
| Structural outlines (functions, structs, imports)      | mmap-backed trigram index                |
| Reverse dependency graph                               |                                          |
| Atomic line-range edits with version tracking          |                                          |
| Auto-registration in Claude, Codex, Gemini, Cursor     |                                          |
| Polling file watcher with filtered directory walker    |                                          |
| Portable snapshot for instant MCP startup              |                                          |
| Singleton MCP with PID lock + 10min idle timeout       |                                          |
| Sensitive file blocking (.env, credentials, keys)      |                                          |
| Codesigned + notarized macOS binaries                  |                                          |
| SHA256 checksum verification in installer              |                                          |
| Cross-platform: macOS (ARM/x86), Linux (ARM/x86)      |                                          |

---

## ⚡ Install

```bash
curl -fsSL https://codedb.codegraff.com/install.sh | bash
```

Downloads the binary for your platform and auto-registers codedb as an MCP server in **Claude Code**, **Codex**, **Gemini CLI**, and **Cursor**.

| Platform | Binary | Signed |
|----------|--------|--------|
| macOS ARM64 (Apple Silicon) | `codedb-darwin-arm64` | ✅ codesigned + notarized |
| macOS x86_64 (Intel) | `codedb-darwin-x86_64` | ✅ codesigned + notarized |
| Linux ARM64 | `codedb-linux-arm64` | — |
| Linux x86_64 | `codedb-linux-x86_64` | — |

Or install manually from [GitHub Releases](https://github.com/justrach/codedb/releases/latest).

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

16 tools over the Model Context Protocol (JSON-RPC 2.0 over stdio):

| Tool | Description |
|------|-------------|
| `codedb_tree` | Full file tree with language, line counts, symbol counts |
| `codedb_outline` | Symbols in a file: functions, structs, imports, with line numbers |
| `codedb_symbol` | Find where a symbol is defined across the codebase |
| `codedb_search` | Trigram-accelerated full-text search (supports regex, scoped results) |
| `codedb_word` | O(1) inverted index word lookup |
| `codedb_hot` | Most recently modified files |
| `codedb_deps` | Reverse dependency graph (which files import this file) |
| `codedb_read` | Read file content (supports line ranges, hash-based caching) |
| `codedb_edit` | Apply line-range edits (replace, insert, delete — atomic writes) |
| `codedb_changes` | Changed files since a sequence number |
| `codedb_status` | Index status (file count, current sequence) |
| `codedb_snapshot` | Full pre-rendered JSON snapshot of the codebase |
| `codedb_bundle` | Batch multiple read-only queries in one call (max 20 ops) |
| `codedb_remote` | Query any GitHub repo via cloud intelligence — no local clone needed |
| `codedb_projects` | List all locally indexed projects on this machine |
| `codedb_index` | Index a local folder and create a codedb.snapshot |


### `codedb_remote` — Cloud Intelligence

Query any public GitHub repo without cloning it. Powered by `codedb.codegraff.com`.

```
# Get the file tree of an external repo
codedb_remote repo="vercel/next.js" action="tree"

# Search for code in a dependency
codedb_remote repo="justrach/merjs" action="search" query="handleRequest"

# Get symbol outlines
codedb_remote repo="justrach/merjs" action="outline"

# Get repo metadata
codedb_remote repo="justrach/merjs" action="meta"
```

**Actions:** `tree`, `outline`, `search`, `meta`

**Note:** This tool calls `codedb.codegraff.com` via HTTPS. No API key required. The service must be available for this tool to work.

### CLI Commands

| Command | Description |
|---------|-------------|
| `codedb tree` | Show file tree with language and symbol counts |
| `codedb outline <path>` | List all symbols in a file |
| `codedb find <name>` | Find where a symbol is defined |
| `codedb search <query>` | Full-text search (trigram, case-insensitive) |
| `codedb search --regex <pattern>` | Regex search |
| `codedb word <identifier>` | Exact word lookup via inverted index |
| `codedb hot` | Recently modified files |
| `codedb snapshot` | Write codedb.snapshot to project root |
| `codedb serve` | HTTP daemon on :7719 |
| `codedb mcp [path]` | JSON-RPC/MCP server over stdio |
| `codedb update` | Self-update via install script |
| `codedb nuke` | Uninstall codedb, remove caches/snapshots, and deregister MCP integrations |
| `codedb --version` | Print version |

**Options:** `--no-telemetry` (or set `CODEDB_NO_TELEMETRY` env var)

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

**codedb repo** (20 files, 12.6k lines):

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

**rtk-ai/rtk repo** (329 files) — codedb vs rtk vs ripgrep vs grep:

| Tool | Search "agent" | Speedup |
|------|---------------|---------|
| codedb (pre-indexed) | **0.065 ms** | baseline |
| rtk | 37 ms | 569x slower |
| ripgrep | 45 ms | 692x slower |
| grep | 80 ms | 1,231x slower |

### Token Efficiency

codedb returns structured, relevant results — not raw line dumps. For AI agents, this means dramatically fewer tokens per query:

| Repo | codedb MCP | ripgrep / grep | Reduction |
|------|-----------|---------------|-----------|
| codedb (search `allocator`) | ~20 tokens | ~32,564 tokens | **1,628x fewer** |
| merjs (search `allocator`) | ~20 tokens | ~4,007 tokens | **200x fewer** |

### Indexing Speed

codedb v0.2.57 uses worker-local parallel scan with deterministic merge — each worker builds its own partial index, then results are merged on the main thread:

| Repo | Files | Cold start | Per file | vs v0.2.56 |
|------|-------|-----------|----------|-----------|
| codedb | 20 | **17 ms** | 0.85 ms | — |
| merjs | 100 | **16 ms** | 0.16 ms | — |
| 5,200 mixed files | 5,200 | **310 ms** | 0.06 ms | — |
| [openclaw/openclaw](https://github.com/openclaw/openclaw) | 6,315 | **346 ms** | 0.05 ms | **10× faster** |

Indexes are built once on startup. After that, the file watcher keeps them updated incrementally (single-file re-index: **<2ms**). Queries never re-scan the filesystem. For repos >1000 files, file contents are released after indexing to save ~300-500MB.

### Background Resource Usage (`openclaw`, 6,315 files, Apple M4 Pro)

| Metric | v0.2.56 | v0.2.57 | Delta |
|--------|---------|---------|-------|
| Steady-state RSS | 1,867 MB | 1,706 MB | −161 MB |
| `git` subprocesses / min (idle) | ~30 | ~0 | **mtime-gated** |

The watcher now stats `.git/HEAD` mtime before forking `git rev-parse HEAD`. On an idle repo the subprocess never fires.
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

codedb collects anonymous usage telemetry to improve the tool. Telemetry is **on by default** — written to `~/.codedb/telemetry.ndjson` and periodically synced to the codedb analytics endpoint. **No source code, file contents, file paths, or search queries are collected** — only aggregate tool call counts, latency, and startup stats.

| Location | Contents | Purpose |
|----------|----------|---------|
| `~/.codedb/projects/<hash>/` | Trigram index, frequency table, data log | Persistent index cache |
| `~/.codedb/telemetry.ndjson` | Aggregate tool calls and startup stats | Local telemetry log |
| `./codedb.snapshot` | File tree, outlines, content, frequency table | Portable snapshot for instant MCP startup |

**Not stored:** No source code is sent anywhere. No file contents, file paths, or search queries are collected in telemetry. Sensitive files auto-excluded (`.env*`, `credentials.json`, `secrets.*`, `.pem`, `.key`, SSH keys, AWS configs).

To disable telemetry: set `CODEDB_NO_TELEMETRY=1` or pass `--no-telemetry`.

To sync the local NDJSON file into Postgres for analysis or dashboards, use [`scripts/sync-telemetry.py`](./scripts/sync-telemetry.py) with the schema in [`docs/telemetry/postgres-schema.sql`](./docs/telemetry/postgres-schema.sql). The data flow is documented in [`docs/telemetry.md`](./docs/telemetry.md).

```bash
codedb nuke                # uninstall binary, clear caches/snapshots, remove MCP registrations
rm -rf ~/.codedb/          # cache-only cleanup if you want to keep the binary installed
rm -f codedb.snapshot      # remove snapshot from current project only
```

---

## 🔨 Building from Source

**Requirements:** Zig 0.15+

```bash
git clone https://github.com/justrach/codedb.git
cd codedb
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
