<p align="center">
  <img src="assets/codedb.png" alt="codedb" width="200" />
</p>

<p align="center">
  <a href="https://github.com/justrach/codedb/releases/latest"><img src="https://img.shields.io/github/v/release/justrach/codedb?style=flat-square&label=version" alt="Release" /></a>
  <a href="https://github.com/justrach/codedb/blob/main/LICENSE"><img src="https://img.shields.io/github/license/justrach/codedb?style=flat-square" alt="License" /></a>
  <img src="https://img.shields.io/badge/zig-0.17.0--dev-f7a41d?style=flat-square" alt="Zig 0.17.0-dev" />
  <img src="https://img.shields.io/badge/status-alpha-orange?style=flat-square" alt="Alpha" />
  <a href="https://deepwiki.com/justrach/codedb"><img src="https://deepwiki.com/badge.svg" alt="Ask DeepWiki" /></a>
  <br />
  <a href="https://trendshift.io/repositories/26207" target="_blank"><img src="https://trendshift.io/api/badge/repositories/26207" alt="justrach%2Fcodedb | Trendshift" width="250" height="55" /></a>
</p>

<h1 align="center">codedb</h1>

<h3 align="center">Code intelligence server for AI agents. Zig core. MCP native. Zero dependencies.</h3>

<p align="center">
  Structural indexing · Trigram search · Word index · Dependency graph · File watching · MCP + HTTP
</p>

<p align="center">
  <em><strong>A context engine, not an editor.</strong> codedb helps agents <strong>find and understand</strong> code — search, symbols, callers, dependencies, outlines — and hands editing back to your native tools. codedb has no edit capability.</em>
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
> - **Parser support** — Zig, C/C++, Python, TypeScript/JavaScript, Rust, Go, PHP, Ruby, HCL, R, Dart/Flutter, OCaml
> - **Lightweight outline support** — Java, Kotlin, Svelte, Vue, Astro, shell, CSS/SCSS, SQL, protobuf, Fortran, LLVM IR, MLIR, and TableGen
> - **No auth** — HTTP server binds to localhost only
> - **Snapshot format** may change between versions
> - **MCP protocol** is JSON-RPC 2.0 over stdio (stable)

| What works today                                       | What's in progress                       |
|--------------------------------------------------------|------------------------------------------|
| 21 MCP tools for full codebase intelligence            | Deeper parser coverage and edge-case handling |
| Trigram v2: integer doc IDs, batch-accumulate, merge intersect | Incremental segment-based indexing |
| 538x faster than ripgrep on pre-indexed queries        | WASM target for Cloudflare Workers       |
| O(1) inverted word index for identifier lookup         | Multi-project support                    |
| Structural outlines (functions, structs, imports)      | mmap-backed trigram index                |
| Reverse dependency graph                               |                                          |
| Fallback editor: atomic line-range edits + version tracking          |                                          |
| Auto-registration in Claude, Codex, Gemini, Cursor, Windsurf, Devin |                                |
| Polling file watcher with filtered directory walker    |                                          |
| Portable snapshot for instant MCP startup              |                                          |
| Singleton MCP with PID lock + 1h idle timeout          |                                          |
| Sensitive file blocking (.env, credentials, keys)      |                                          |
| Codesigned + notarized macOS binaries — ARM64 and Intel (0.2.5833+) |                                          |
| SHA256-verified release downloads and npm packages     |                                          |
| Cross-platform: macOS (ARM/x86), Linux (ARM/x86), Windows (x86_64) |                              |

---

## ⚡ Install

### macOS and Linux

```bash
curl -fsSL https://codedb.codegraff.com/install.sh | bash
```

Downloads the binary for your platform and auto-registers codedb as an MCP server in **Claude Code**, **Codex**, **Gemini CLI**, **Cursor**, **Windsurf**, and **Devin** — each written directly and additively into that tool's config (only when the tool is present). The installer prints the exact `codedb mcp` command it registered plus hook setup pointers for Codex and Claude Code.

On Windows, run this command inside WSL only if you want the Linux binary inside WSL. For the native Windows binary, use PowerShell below.

### Windows

Run in PowerShell:

```powershell
irm https://raw.githubusercontent.com/justrach/codedb/v0.2.5841/install/install.ps1 | iex
```

Run the same command again to update codedb.

### npm/npx on macOS and Linux

```bash
npx -y codedeebee mcp
```

Or install globally:

```bash
npm install -g codedeebee
codedb mcp
```

The npm package is named [`codedeebee`](https://www.npmjs.com/package/codedeebee) (the bare `codedb` name is restricted on npm); it ships a thin launcher that downloads the matching native binary from GitHub Releases on `postinstall` and verifies the SHA256 checksum. The installed CLI is still called `codedb`.

The launcher already knows how to fetch `codedb-windows-x86_64.exe`, but the currently published `codedeebee` predates that release asset, so `npx -y codedeebee mcp` does not work on Windows yet — it becomes available with the next published release. Use the PowerShell installer above until then.

Useful for MCP clients (Claude Code, Cursor, opencode, Claude Desktop) that already use `npx`:

```json
{
  "codedb": {
    "type": "local",
    "command": ["npx", "-y", "codedeebee"],
    "args": ["mcp"],
    "enabled": true
  }
}
```

### Updating or repairing an older install

On macOS or Linux, if `codedb update` fails on an older release, rerun the installer:

```bash
curl -fsSL https://codedb.codegraff.com/install.sh | bash
```

This replaces the `codedb` binary with the latest GitHub Release and keeps your existing MCP registrations, config, caches, and snapshots. Use this path for any release whose built-in updater cannot fetch release checksums.

Self-update works on native Windows from 0.2.5833 onward (`codedb update`). On older builds, rerun the PowerShell installer above to update or repair the binary.

## Documentation

- **[MCP setup](docs/mcp.md)** — per-client configurations (Claude Desktop, Cursor, VS Code, Claude Code, Codex CLI, Gemini CLI), root resolution, troubleshooting
- **[Skill base & context files](docs/skills.md)** — `agents.md` / `CLAUDE.md` / `GEMINI.md`, `.codedbrc`, per-developer memory
- **[CLI reference](docs/cli.md)** — every command, every flag
- **[Architecture](docs/architecture.md)** — engine internals, index layout
- **[Benchmarks](docs/benchmarks.md)** — micro-benchmarks + agentic-eval results vs codegraph, FTS5, lean-ctx
- **[Raspberry Pi 4](docs/raspberry-pi.md)** — full-performance ARM64 setup, Cortex-A72 build, and on-device benchmark
- **[Zig 0.17.0-dev migration guide](docs/zig-0.17-migration.md)** — repeatable zigup workflow and API change recipes

| Platform | Binary | Signed |
|----------|--------|--------|
| macOS ARM64 (Apple Silicon) | `codedb-darwin-arm64` | ✅ codesigned + notarized |
| macOS x86_64 (Intel) | `codedb-darwin-x86_64` | codesigned + notarized (0.2.5833+) |
| Linux ARM64 | `codedb-linux-arm64` | — |
| Linux x86_64 | `codedb-linux-x86_64` | — |
| Windows x86_64 | `codedb-windows-x86_64.exe` | SHA256 verified automatically |

Or install manually from [GitHub Releases](https://github.com/justrach/codedb/releases/latest). Always verify the binary against the attached `checksums.sha256` before running it.

---

## ⚡ Quick Start

### As an MCP server (recommended)

The macOS/Linux shell installer registers codedb automatically. For npm/npx installs on macOS/Linux and manual Windows installs, use the MCP configuration above or the client-specific examples in [docs/mcp.md](docs/mcp.md). Then open a project and the 21 MCP tools are available to your AI agent.

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

22 tools over the Model Context Protocol (JSON-RPC 2.0 over stdio). Agents see five one-shots by default (`context`, `explain`, `callpath`, `list_dir`, `status`). codedb's job is to **give agents context** — **not** to be your editor. codedb has no edit tool; use your client's native edit tools.

| Tool | Description |
|------|-------------|
| `codedb_tree` | Full file tree with language, line counts, symbol counts |
| `codedb_outline` | Symbols in a file: functions, structs, imports, with line numbers |
| `codedb_symbol` | Find where a symbol is defined across the codebase |
| `codedb_search` | Trigram-accelerated full-text search (supports regex, scoped results) |
| `codedb_word` | O(1) inverted index word lookup |
| `codedb_callers` | Every call site of a symbol — word index ∩ outline scope, in one round-trip |
| `codedb_explain` | Definition body + callers in one call (CLI aliases: `explain`, `around`) |
| `codedb_callpath` | Shortest resolved call chain A→B (CLI alias: `path`) |
| `codedb_context` | Task-shaped composer — Pareto-frontier hybrid retrieval by default: local BM25/symbol retrieval first, then local ANN search using a remote task embedding plus a fixed public calibration string when an explicit sidecar exists, or a bounded transient semantic rerank otherwise. Pass `semantic=local` for an on-device-only call. `format=json` adds typed provenance and retrieval-privacy metadata; `document_hops=1..2` expands linked Markdown |
| `codedb_hot` | Most recently modified files |
| `codedb_deps` | Typed dependency graph: imports by default, or Markdown links with `edge_type=documents`; document traversal is capped at 2 hops / 64 files |
| `codedb_read` | Read file content (line ranges, `if_hash` skip-unchanged, `compact` mode) |
| `codedb_changes` | Changed files since a sequence number |
| `codedb_status` | Index status (file count, current sequence, scan phase) |
| `codedb_snapshot` | Full pre-rendered JSON snapshot of the codebase |
| `codedb_projects` | List all locally indexed projects on this machine |
| `codedb_index` | Index a local folder and write `codedb.snapshot` |
| `codedb_find` | Fuzzy **file-name** search (typo-tolerant subsequence match against indexed paths — not a content/symbol search) |
| `codedb_glob` | Match indexed paths against a glob pattern (`src/**/*.zig`, `*.md`, …) |
| `codedb_ls` | List immediate children of a directory — dirs first, then files with language + counts |
| `codedb_list_dir` | Live BFS folder listing (gitignore, 10k cap) — works without an index |
| `codedb_query` | Composable pipeline — chain `find`, `search`, `filter`, `deps`, `outline`, `read`, `sort`, `limit` in one request |

`codedb_context` accepts `max_tokens` as a conservative approximate response
budget. Compact evidence is admitted progressively; when the remaining
evidence does not fit, the response reports the omission once instead of
overflowing the request with lower-priority sections.

MCP responses are plain text by default, without ANSI styling. Set
`CODEDB_MCP_ANSI=1` in the MCP server environment to opt into ANSI-colored
summary and guidance blocks for clients that render terminal colors.

**Tool profile:** agent harnesses default to `mini` — five one-shot tools
(`context`, `explain`, `callpath`, `list_dir`, `status`). Hop tools stay
callable; they are not advertised. `CODEDB_TOOLS_PROFILE=core` is the older
10-tool navigation set; `slim` is the terse hop six; `full` advertises
everything. GUI clients that emit rich blocks still get `full` unless the
env var is set.

### Public repos — DeepWiki (remote MCP)

codedb is deliberately local-only: it indexes *your* checked-out code. For
questions about *public* GitHub repos, the installer registers
[DeepWiki](https://deepwiki.com) (`https://mcp.deepwiki.com/mcp` — free, no
auth) as a separate remote MCP server in each detected client, with tools
`read_wiki_structure`, `read_wiki_contents`, and `ask_question`. Opt out at
install time with `CODEDB_INSTALL_DEEPWIKI=0`. (The old `codedb_remote` tool
backed by api.wiki.codes was removed; DeepWiki replaces that role.)

### CLI Commands

| Command | Description |
|---------|-------------|
| `codedb tree` | Show file tree with language and symbol counts |
| `codedb outline <path>` | List all symbols in a file |
| `codedb find <name>` | Find where a symbol is defined |
| `codedb search <query>` | Full-text search (trigram, case-insensitive) |
| `codedb search --regex <pattern>` | Regex search |
| `codedb word <identifier>` | Exact word lookup via inverted index |
| `codedb read <path>` | Read file contents (supports `-L FROM-TO`, `--compact`) |
| `codedb hot` | Recently modified files |
| `codedb reindex` | Force a fresh filesystem scan, rebuild all local indexes, and refresh the live daemon |
| `codedb snapshot` | Write codedb.snapshot to project root |
| `codedb serve` | HTTP daemon on :7719 |
| `codedb mcp [path]` | JSON-RPC/MCP server over stdio |
| `codedb update` | Self-update to the latest release on macOS/Linux; on Windows rerun the PowerShell installer |
| `codedb nuke` | Uninstall codedb, remove caches/snapshots, and deregister MCP integrations |
| `codedb --version` | Print version |

**Options:** `--no-telemetry` (or set `CODEDB_NO_TELEMETRY` env var)

**Claude Code hook opt-out:** the installer registers a PreToolUse hook that nudges agents from `grep`/`cat` to codedb inside indexed repos. `CODEDB_NO_HOOKS=1` skips it for that run only (it is never persisted from the environment, so a transient export can't be promoted to a permanent opt-out by the background auto-updater). To make it permanent, run the installer with `CODEDB_PERSIST_NO_HOOKS=1` or `touch ~/.codedb/no-hooks`; `rm ~/.codedb/no-hooks` re-enables it. Deleting the hook entry from `~/.claude/settings.json` is also permanent — the installer records its registrations and treats a missing entry as a deliberate removal (it writes `~/.codedb/no-hooks` for you, so `rm` that file to undo).

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

- **Explorer** — structural index engine. Parses Zig, Python, TypeScript/JavaScript, Rust, Go, PHP, Ruby, HCL, R, and Dart. Maintains outlines, trigram index, inverted word index, content cache, and dependency graph behind a single mutex.
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

`codedb_context` uses Pareto-frontier hybrid retrieval by default. Local BM25,
trigram, symbol, and graph retrieval always runs first. Pass `semantic=local`
for an entirely on-device call that sends no query or source text to an
embedding service. In the default hybrid mode:

- local BM25/symbol retrieval still runs first and remains the failure-safe
  result;
- when a fresh local OpenPuffer sidecar exists, codedb sends the task plus a
  fixed public calibration string in one embedding request, verifies that the
  provider still represents the same vector space, and searches the stored
  code chunks locally through a validated mmap-backed graph;
- without a sidecar, codedb sends the task plus at most 24 locally selected
  relative paths and bounded snippets, capped at 2 KiB per path+snippet item /
  8 KiB candidate text total, in one exact-rerank batch;
- the hosted codedb embedding service performs transient inference and does
  not retain request bodies, candidate paths, source snippets, or vectors;
- no repository archive or server-side repository/vector index is created;
- provider/network failure keeps the local result and never invokes a CPU
  embedding fallback.

The local ANN is built only by an explicit command:

```bash
codedb /path/to/repo semantic-index
```

It splits already-indexable files into bounded 832-byte source chunks, uses
four concurrent 25-item requests by default (explicitly configurable from one
to eight), and writes a
small `semantic-chunks-v3.meta` mapping plus a generation-named `.hmls` mmap
slab only in codedb's per-project local data directory. The directory and
files use private permissions (0700/0600 on POSIX).
On lookup, codedb checks model/vector-space identity, Git/content freshness,
and the bounded metadata before opening the slab. Metadata heap use is capped
at 64 MiB and graph-validation reads at 128 MiB; vector slabs remain
demand-paged rather than being copied into the query process.
It never scans or uploads `.env`, `.env.*`, `.envrc`, credentials, private keys, or other paths on
the sensitive-file denylist. Ordinary indexing does not build this sidecar.

The default managed semantic lane is free to call and requires no API token or
manual setup. On first use, CodeDB creates a local Ed25519 installation key,
enrolls its public key, and receives a short-lived server-signed certificate.
Every request proves possession of the installation key; renewal is automatic.
The private seed stays in a global `~/.codedb/credentials.json` file written
atomically with mode `0600` on POSIX and is never part of an embedding request.
The public route exposes only the managed CodeDB lane and enforces enrollment,
installation, and aggregate network limits. General provider APIs remain authenticated.

`format=json` exposes this boundary in the `retrieval` object, including vector
dimensions, bounded byte/document counts, retention policy, and failure
policy. If `CODEDB_EMBEDDINGS_URL` points to a custom provider, codedb labels
its retention as `custom_endpoint_unverified` because the client cannot prove
another operator's storage policy.

| Location | Contents | Purpose |
|----------|----------|---------|
| `~/.codedb/projects/<hash>/` | Trigram index, frequency table, data log; optional `semantic-chunks-v3.meta` plus `.hmls` slab | Persistent local indexes |
| `~/.codedb/credentials.json` | Private Ed25519 seed and public installation certificate (0600 on POSIX) | Automatic hosted-lane authentication |
| `~/.codedb/telemetry.ndjson` | Aggregate tool calls and startup stats | Local telemetry log |
| `./codedb.snapshot` | File tree, outlines, content, frequency table | Portable snapshot for instant MCP startup |

**Not stored:** In explicit `semantic=local` mode, no source code is sent
anywhere. In the default hybrid and explicit index-build modes, only the
bounded transient batches above leave the machine; the hosted service does not
store them and never creates a
repository index. The optional ANN vectors and graph remain in the local codedb
data directory. No file contents, file paths, or search queries are collected
in telemetry. Sensitive files are auto-excluded from indexing and therefore
cannot become hybrid candidates (`.env`, `.env.*`, `.envrc`,
`credentials.json`, `secrets.*`, `.pem`, `.key`, SSH keys, AWS configs).
The hybrid request builder repeats the canonical safe-path check immediately
before serialization, so those paths remain blocked even if a stale or
hand-built in-memory index contains one. Structured provenance reports only
the aggregate `sensitive_paths_blocked` count, never the rejected path.

Optional custom-provider overrides (the managed lane needs none):

```bash
CODEDB_EMBEDDINGS_URL=https://provider.example/v1/embeddings
CODEDB_EMBEDDINGS_MODEL=your-deployment-id
CODEDB_EMBEDDINGS_DIMENSIONS=512
CODEDB_EMBEDDINGS_TOKEN='optional bearer token for a protected/custom endpoint'
CODEDB_EMBEDDINGS_TIMEOUT_MS=15000
CODEDB_SEMANTIC_INDEX_CONCURRENCY=4
```

To disable telemetry: set `CODEDB_NO_TELEMETRY=1` or pass `--no-telemetry`.

To sync the local NDJSON file into Postgres for analysis or dashboards, use [`scripts/sync-telemetry.py`](./scripts/sync-telemetry.py) with the schema in [`docs/telemetry/postgres-schema.sql`](./docs/telemetry/postgres-schema.sql). The data flow is documented in [`docs/telemetry.md`](./docs/telemetry.md).

```bash
codedb nuke                # uninstall binary, clear caches/snapshots, remove MCP registrations
rm -rf ~/.codedb/          # cache-only cleanup if you want to keep the binary installed
rm -f codedb.snapshot      # remove snapshot from current project only
```

---

## 🔨 Building from Source

**Requirements:** Zig `0.17.0-dev.813+2153f8143` (the exact tested development snapshot). See the [migration guide](docs/zig-0.17-migration.md) for reproducible zigup setup.

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
zig build -Doptimize=ReleaseFast -Dtarget=x86_64-windows
```

### Releasing

```bash
./release.sh 0.2.0              # build, codesign, notarize, upload to GitHub Releases
./release.sh 0.2.0 --dry-run    # preview without executing
```

---

## License

See [LICENSE](LICENSE) for details.
