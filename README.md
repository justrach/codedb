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

Measured on Apple M4 Max, 48GB RAM. codedb indexes itself (17 source files, ~6k lines).

### Startup & Indexing

| Operation | Time |
|-----------|------|
| Initial scan + full index (outlines, trigrams, words, deps) | **<50ms** |
| Incremental re-index (single file change) | **<2ms** |
| Snapshot generation (full JSON) | **<10ms** |
| MCP server ready (from snapshot) | **<5ms** |

### Query Performance

| Query | Time | Notes |
|-------|------|-------|
| `codedb_tree` | **<1ms** | Pre-computed, cached |
| `codedb_outline` | **<1ms** | HashMap lookup |
| `codedb_symbol` (single) | **<1ms** | HashMap lookup |
| `codedb_search` (trigram) | **<5ms** | Trigram candidate filter → brute-force verify |
| `codedb_word` | **<1ms** | O(1) inverted index |
| `codedb_deps` | **<1ms** | Pre-computed reverse graph |
| `codedb_hot` | **<1ms** | Sorted by sequence number |

### HTTP Throughput

| Endpoint | Requests/sec |
|----------|-------------|
| `GET /status` | **~120,000/s** |
| `GET /tree` | **~85,000/s** |
| `GET /outline?path=...` | **~95,000/s** |
| `GET /search?q=...` | **~40,000/s** |

### Memory

| Metric | Value |
|--------|-------|
| RSS at startup (17 files indexed) | **~8MB** |
| Per-file overhead | **~50KB** (outline + content + indexes) |
| Binary size (ReleaseFast) | **~1.1MB** (macOS ARM64) |

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

codedb is **fully local** — no telemetry, no analytics, no network calls. Nothing leaves your machine.

| Location | Contents | Purpose |
|----------|----------|---------|
| `~/.codedb/projects/<hash>/` | Trigram index, frequency table, data log | Persistent index cache |
| `./codedb.snapshot` | File tree, outlines, content, frequency table | Portable snapshot for instant MCP startup |

**Not stored:** No source code is sent anywhere. No network requests. No usage analytics. Sensitive files auto-excluded (`.env*`, `credentials.json`, `secrets.*`, `.pem`, `.key`, SSH keys, AWS configs).

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
