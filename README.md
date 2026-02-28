# CodeDB

**v0.0.2** — A high-performance MCP server and code graph engine written in Zig. Provides AI-powered GitHub project management, agent swarm orchestration, blast radius analysis, and intelligent code navigation via the [Model Context Protocol](https://modelcontextprotocol.io/).

## What's New in v0.0.2

- **Agent Swarm** (`run_swarm`) — spawn up to 100 parallel Codex sub-agents via Zig threads. An orchestrator decomposes your task, workers execute in parallel, a synthesis agent combines results. 4–5× faster than sequential for broad research and multi-file analysis.
- **Subagent Tools** — `run_reviewer`, `run_explorer`, `run_zig_infra` invoke specialized Codex agents directly as MCP tools
- **Runtime Repo Switch** (`set_repo`) — change the active repository without restarting the server
- **`--mcp` flag** — binary now requires explicit `--mcp` to enter MCP mode; auto-detects repo via `git rev-parse` when `REPO_PATH` is unset
- **Codex app-server protocol** — subagents now use the full JSON-RPC 2.0 app-server protocol with streaming `item/agentMessage/delta` instead of blocking `codex exec`
- **30 MCP tools** (up from 21)

## Features

- **30 MCP Tools** for issue management, PR workflows, branching, commits, code analysis, graph queries, and agent orchestration
- **Agent Swarm** — self-organizing parallel sub-agents using Zig's `std.Thread`; orchestrator → N workers → synthesis pipeline
- **Code Graph Engine** with Personalized PageRank ranking, edge weighting, and multi-language symbol extraction
- **Blast Radius Analysis** — find all code affected by a change before you make it
- **Dependency-Aware Prioritization** — automatically prioritize issues based on their dependency graph
- **Write-Ahead Log** for crash recovery and deterministic replay
- **Binary Storage Format** with CRC32 checksums and versioning
- **Session Caching** for zero-latency GitHub label/milestone lookups

## Requirements

- [Zig](https://ziglang.org/) 0.15.1+
- [GitHub CLI](https://cli.github.com/) (`gh`) — authenticated
- [Codex CLI](https://github.com/openai/codex) (`codex`) — for subagent tools (`run_reviewer`, `run_explorer`, `run_zig_infra`, `run_swarm`)
- One of: `zigrep`, `rg` (ripgrep), or `grep` — for symbol search

## Quick Start

### Build

```bash
zig build
```

### Run

```bash
# Explicit repo path
REPO_PATH=/path/to/your/repo ./zig-out/bin/gitagent-mcp --mcp

# Auto-detect from git (must run inside a git repo)
./zig-out/bin/gitagent-mcp --mcp
```

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
      "args": ["--mcp"],
      "env": {
        "REPO_PATH": "/path/to/your/repo"
      }
    }
  }
}
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
├── main.zig              # MCP server entry point (JSON-RPC 2.0 over stdio, --mcp flag)
├── tools.zig             # All 30 tool implementations + dispatch
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

### v0.0.2
- `run_swarm`: parallel agent swarm via Zig threads (up to 100 agents)
- `run_reviewer`, `run_explorer`, `run_zig_infra`: Codex subagent tools
- `set_repo`: runtime repository switching without server restart
- `--mcp` flag required to enter MCP mode; auto-detect repo via `git rev-parse`
- Codex app-server JSON-RPC 2.0 protocol with streaming delta output
- 30 tools total (up from 21)
- Fix: spurious backslash-escapes in `tools_list` multiline strings

### v0.0.1
- Initial release: 21 MCP tools for GitHub workflow management
- Code graph engine with Personalized PageRank
- Blast radius analysis, dependency-aware prioritization
- Write-ahead log, binary storage with CRC32

## License

See [LICENSE](LICENSE) for details.
