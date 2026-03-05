# CodeDB

**v0.0.24** — A high-performance MCP server, code graph engine, and evolutionary algorithm platform written in Zig. Provides AI-powered GitHub project management, agent swarm orchestration, iterative review-fix loops, blast radius analysis, and intelligent code navigation via the [Model Context Protocol](https://modelcontextprotocol.io/).

## What's New in v0.0.24

- **TenantManager thread-safety** (#108) — `std.Thread.Mutex` now guards all shared HashMap and counter access in `TenantManager`; a private `repoDataDirLocked` helper avoids recursive lock acquisition.
- **Error propagation in graph engine** (#119) — `onEdgeAdded`, `onEdgeRemoved`, `onFileInvalidated` (ppr_incremental.zig) and `evictIdle`/`evictIdleAt` (tier_manager.zig) now return `!void`/`!u32`, propagating OOM errors via `try` instead of silently dropping state mutations.
- **muonry availability hint** (#135) — Swarm `WRITABLE_PREAMBLE` clarifies muonry MCP tools require configuration in `~/.codex/config.toml`.
- **`run_agent` tool** — new general-purpose agent invocation tool via the Agent SDK
- **34 MCP tools** (up from 33)

## What's New in v0.0.22
- **Subagent Tools** — `run_reviewer`, `run_explorer`, `run_zig_infra` invoke specialized Codex agents directly as MCP tools
- **Runtime Repo Switch** (`set_repo`) — change the active repository without restarting the server
- MCP mode starts directly; `REPO_PATH` is optional when the binary can auto-detect via `git rev-parse`
- **Codex app-server protocol** — subagents now use the full JSON-RPC 2.0 app-server protocol with streaming `item/agentMessage/delta` instead of blocking `codex exec`
- **34 MCP tools** (up from 21)

## Features

- **34 MCP Tools** for issue management, PR workflows, branching, commits, code analysis, graph queries, agent orchestration, and iterative review-fix loops
- **Agent Swarm** — self-organizing parallel sub-agents using Zig's `std.Thread`; orchestrator → N workers → synthesis pipeline
- **Code Graph Engine** with Personalized PageRank ranking, edge weighting, and multi-language symbol extraction
- **Blast Radius Analysis** — find all code affected by a change before you make it
- **Dependency-Aware Prioritization** — automatically prioritize issues based on their dependency graph
- **Write-Ahead Log** for crash recovery and deterministic replay
- **Binary Storage Format** with CRC32 checksums and versioning
- **Session Caching** for zero-latency GitHub label/milestone lookups
- **Threaded repo sessions** (`thread_id`) so one MCP process can keep separate working repos per thread without requiring `repo` on every tool call

## Requirements

- [Zig](https://ziglang.org/) 0.15.1+
- [GitHub CLI](https://cli.github.com/) (`gh`) — authenticated
- [Codex CLI](https://github.com/openai/codex) (`codex`) — for subagent tools (`run_reviewer`, `run_explorer`, `run_zig_infra`, `run_swarm`, `review_fix_loop`)
- One of: `zigrep`, `rg` (ripgrep), or `grep` — for symbol search

## Quick Start

### Build

```bash
zig build
```

### Run

```bash
# Explicit repo path
REPO_PATH=/path/to/your/repo ./zig-out/bin/gitagent-mcp

# Auto-detect from git (must run inside a git repo)
./zig-out/bin/gitagent-mcp
```

### Push safety checks (pre-push hook)

Use the checked-in hook at `.githooks/pre-push` to run `zig build test` before every `git push`:

```bash
git config core.hooksPath .githooks
```

Use the checked-in hook at `.githooks/pre-commit` to run focused MCP protocol regression tests before every `git commit`:

```bash
git config core.hooksPath .githooks
```

If you need an emergency push, skip checks with:

```bash
SKIP_MCP_TESTS=1 git push
```

Useful local test commands:

- `zig build test-mcp` — MCP protocol regression tests (line/header framing parsing and framing selection)
- `zig build test` — full unit test suite (including thread-context tests)
- `zig build test -- --test-filter "thread"` — run only thread-related tests in `src/main.zig`

### Threaded sessions (multi-repo / multi-user)

- Send a stable `thread_id` once (inside `tools/call.params` or `tools/call.params.arguments`).
- On the first call with that `thread_id`, include a one-time repo location in either:
  - `working_directory`
  - `repo_path`
  - `repo`
- On subsequent calls for the same `thread_id`, the server restores and reuses that thread's repo automatically.
- Different `thread_id` values are kept separate (up to 32 active threads) with independent current-repo state.

### Test

```bash
zig build test          # unit tests
python3 test_e2e.py     # end-to-end tests
```

## MCP Integration

Add to your Claude Code config (`~/.claude.json`):

```json
{
  "mcpServers": {
    "gitagent": {
      "type": "stdio",
      "command": "/path/to/gitagent-mcp",
      "env": {
        "REPO_PATH": "/path/to/your/repo"
      }
    }
  }
}
```

## Distribution and Installation

If you want an off-the-shelf install path (no local Zig build), track:

- Homebrew tap + formula release
- npm/bun install via a JS wrapper package that downloads matching `gitagent-mcp` binaries
- GitHub release artifacts with checksums

### Current install baseline

At the moment, the repository supports source build and local run. The packaging pipeline is tracked in:

- https://github.com/justrach/codedb/issues/144
- https://github.com/justrach/codedb/issues/145
- https://github.com/justrach/codedb/issues/146
- https://github.com/justrach/codedb/issues/147

Suggested target for end-users once packaging ships:

```bash
# Homebrew (planned)
brew tap justrach/codedb
brew install gitagent-mcp

# npm / bun (planned)
npm install -g @justrach/gitagent-mcp
bun add -g @justrach/gitagent-mcp
```

Until those distributions are shipped, use source mode:

```bash
zig build
./zig-out/bin/gitagent-mcp
```

## Tools

### Planning

| Tool | Description |
|------|-------------|
| `decompose_feature` | Break a feature description into structured issue drafts |
| `get_project_state` | View all issues, branches, and PRs grouped by status |
| `get_next_task` | Find the highest-priority unblocked issue |
| `prioritize_issues` | Apply priority labels (p0–p3) based on dependency order |

### Issue Management

| Tool | Description |
|------|-------------|
| `create_issue` | Create a single issue with labels and milestones |
| `create_issues_batch` | Batch create issues (up to 5 concurrently) |
| `update_issue` | Modify title, body, or labels |
| `close_issue` | Close an issue and mark as `status:done` |
| `link_issues` | Create dependency relationships between issues |

### Branch & Commit

| Tool | Description |
|------|-------------|
| `create_branch` | Create a `feature/` or `fix/` branch linked to an issue |
| `get_current_branch` | Get current branch and extract linked issue number |
| `commit_with_context` | Stage and commit with issue references |
| `push_branch` | Push to origin with upstream tracking |

### Pull Requests

| Tool | Description |
|------|-------------|
| `create_pr` | Open a PR from current branch to main |
| `get_pr_status` | Check CI status, review state, and merge readiness |
| `list_open_prs` | List all open PRs with CI status |

### Code Analysis

| Tool | Description |
|------|-------------|
| `review_pr_impact` | Analyze a PR's blast radius (changed files, affected symbols) |
| `blast_radius` | Find all files referencing symbols in a file |
| `relevant_context` | Find related files via cross-reference analysis |
| `git_history_for` | View commit history for a specific file |
| `recently_changed` | Find actively modified areas of the codebase |

### Graph Queries (requires `.codegraph/graph.bin`)

| Tool | Description |
|------|-------------|
| `symbol_at` | Find symbol(s) at a file:line location |
| `find_callers` | Find all symbols calling a given symbol |
| `find_callees` | Find all symbols called by a given symbol |
| `find_dependents` | Find dependent symbols ranked by PageRank |

### Repository Management

| Tool | Description |
|------|-------------|
| `set_repo` | Switch active repository at runtime without restarting the server |

### Subagents (requires `codex` CLI)

| Tool | Description |
|------|-------------|
| `run_reviewer` | Invoke a Codex reviewer: checks errdefer gaps, RwLock ordering, Zig 0.15.x API misuse, missing tests |
| `run_explorer` | Invoke a Codex explorer: trace execution paths read-only, gather evidence |
| `run_zig_infra` | Invoke a Codex infra agent: review `build.zig` module graph, `@import` wiring, test step coverage |
| `run_swarm` | Spawn N parallel sub-agents, synthesize results (see below) |
| `review_fix_loop` | Iterative review → fix → re-review loop until clean or max iterations |
## Agent Swarm

`run_swarm` implements a self-organizing parallel agent pipeline backed by Zig threads:

```
run_swarm(prompt, max_agents=5)
        │
        ▼
  Orchestrator agent              ← single codex app-server call
  → JSON: [{role, prompt}, ...]   ← decomposes task into sub-tasks
        │
        ├── Thread 1: codex app-server  ─┐
        ├── Thread 2: codex app-server   │  parallel via std.Thread.spawn
        ├── Thread 3: codex app-server   │  each owns its own allocator
        └── Thread N: codex app-server  ─┘
                    │
                    ▼  (all joined)
        Synthesis agent             ← another codex app-server call
        → combined final response
```

**Best for:** broad code reviews, multi-file analysis, multi-angle research, batch issue triage.
**Hard cap:** 100 parallel agents. Default: 5.

```json
{
  "tool": "run_swarm",
  "arguments": {
    "prompt": "Review the entire codebase for bugs, missing error handling, and performance issues",
    "max_agents": 10
  }
}
```

## Architecture

```
src/
├── main.zig              # MCP server entry point (JSON-RPC 2.0 over stdio)
├── tools.zig             # All 34 tool implementations + dispatch
├── swarm.zig             # Agent swarm: orchestrator → N threads → synthesis
├── codex_appserver.zig   # Codex app-server JSON-RPC 2.0 client (streaming)
├── gh.zig                # GitHub CLI executor with concurrent output draining
├── cache.zig             # Session-scoped label/milestone cache (60s TTL)
├── state.zig             # Label-based workflow state machine
├── search.zig            # Search tool cascade (zigrep → rg → grep)
├── auth.zig              # Authentication (JWT / trial period)
└── graph/
    ├── types.zig         # Core types: Symbol, File, Commit, Edge, Language
    ├── graph.zig         # In-memory graph data structure
    ├── ingest.zig        # Multi-language symbol extraction (TS, JS, Python, Java, Go, Rust, Zig)
    ├── storage.zig       # Binary serialization with versioning
    ├── wal.zig           # Write-ahead log for crash recovery
    ├── hot_cache.zig     # LRU cache for frequent queries
    ├── query.zig         # Symbol lookup, callers, callees, dependents
    ├── ipc.zig           # Unix socket frame protocol for daemon communication
    ├── ppr.zig           # Personalized PageRank (push algorithm)
    └── edge_weights.zig  # Recency decay, call frequency, modification boost
```

## Workflow

CodeDB tracks issues through a label-based state machine:

```
backlog → in-progress → in-review → done
               ↓
           blocked
```

Labels are managed automatically as you use the tools:

- `create_branch` sets `status:in-progress`
- `create_pr` sets `status:in-review`
- `close_issue` sets `status:done`
- `link_issues` sets `status:blocked` on dependent issues

## Environment Variables

| Variable | Description |
|----------|-------------|
| `REPO_PATH` | Path to the target repository (auto-detected from `git rev-parse` if unset) |
| `ZIGTOOLS_TOKEN` | JWT authentication token (optional) |

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for the full release history.
### v0.0.24
- `TenantManager` mutex: `std.Thread.Mutex` guards all shared state (#108)
- Error propagation in ppr_incremental and tier_manager: `!void`/`!u32` return types, OOM errors no longer silently dropped (#119)
- muonry availability hint clarified in swarm preamble (#135)

### v0.0.22
- 34 tools total (up from 30)

### v0.0.21
- Release pipeline for npm and Homebrew distribution
- Binary renamed to `devswarm` end-to-end
- CI: GitHub Actions test pipeline on every PR

### v0.0.2
- `run_swarm`: parallel agent swarm via Zig threads (up to 100 agents)
- `run_reviewer`, `run_explorer`, `run_zig_infra`: Codex subagent tools
- `set_repo`: runtime repository switching without server restart
- Codex app-server JSON-RPC 2.0 protocol with streaming delta output
- 30 tools total (up from 21)
- Fix: spurious backslash-escapes in `tools_list` multiline strings

### v0.0.1
- Initial release: 21 MCP tools for GitHub workflow management
- Code graph engine with Personalized PageRank
- Blast radius analysis, dependency-aware prioritization
- Write-ahead log, binary storage with CRC32

## Contributors

- Rach Pradhan
- Yuxi Lim

## License

This project is licensed under the GNU Affero General Public License, version 3 (AGPL-3.0). See [LICENSE](LICENSE) for the full terms.
