# CodeDB

A high-performance MCP server and code graph engine written in Zig. Provides AI-powered GitHub project management, blast radius analysis, and intelligent code navigation via the [Model Context Protocol](https://modelcontextprotocol.io/).

## Features

- **21 MCP Tools** for issue management, PR workflows, branching, commits, and code analysis
- **Code Graph Engine** with Personalized PageRank ranking, edge weighting, and multi-language symbol extraction
- **Blast Radius Analysis** — find all code affected by a change before you make it
- **Dependency-Aware Prioritization** — automatically prioritize issues based on their dependency graph
- **Write-Ahead Log** for crash recovery and deterministic replay
- **Binary Storage Format** with CRC32 checksums and versioning
- **Session Caching** for zero-latency GitHub label/milestone lookups

## Requirements

- [Zig](https://ziglang.org/) 0.15.1+
- [GitHub CLI](https://cli.github.com/) (`gh`) — authenticated
- One of: `zigrep`, `rg` (ripgrep), or `grep` — for symbol search

## Quick Start

### Build

```bash
zig build
```

### Run

```bash
REPO_PATH=/path/to/your/repo ./zig-out/bin/gitagent-mcp
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
    "gitagent-mcp": {
      "command": "/path/to/gitagent-mcp",
      "args": [],
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
| `prioritize_issues` | Apply priority labels (p0-p3) based on dependency order |

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

## Architecture

```
src/
├── main.zig            # MCP server entry point (JSON-RPC 2.0 over stdio)
├── tools.zig           # All 21 tool implementations
├── gh.zig              # GitHub CLI executor with concurrent output draining
├── cache.zig           # Session-scoped label/milestone cache (60s TTL)
├── state.zig           # Label-based workflow state machine
├── search.zig          # Search tool cascade (zigrep → rg → grep)
├── auth.zig            # Authentication (JWT / trial period)
└── graph/
    ├── types.zig       # Core types: Symbol, File, Commit, Edge, Language
    ├── graph.zig       # In-memory graph data structure
    ├── ingest.zig      # Multi-language symbol extraction (TS, JS, Python, Java, Go, Rust, Zig)
    ├── storage.zig     # Binary serialization with versioning
    ├── wal.zig         # Write-ahead log for crash recovery
    ├── hot_cache.zig   # LRU cache for frequent queries
    ├── query.zig       # Symbol lookup, callers, callees, dependents
    ├── ipc.zig         # Unix socket frame protocol for daemon communication
    ├── ppr.zig         # Personalized PageRank (push algorithm)
    └── edge_weights.zig # Recency decay, call frequency, modification boost
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
| `REPO_PATH` | Path to the target repository (required) |
| `ZIGTOOLS_TOKEN` | JWT authentication token (optional) |

## License

See [LICENSE](LICENSE) for details.
