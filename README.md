# DevSwarm

**Provider-agnostic agent orchestration for codebases.**

DevSwarm is an MCP server that gives any AI coding assistant the ability to spawn sub-agents, run parallel swarms, and execute multi-step task chains — all routed through a provider-agnostic runtime that picks the best model for each job.

```
┌─────────────────────────────────────────────────┐
│  Your AI Assistant (Claude Code, Codex, Amp, etc.) │
│                      │                          │
│               MCP protocol (stdio)              │
│                      ▼                          │
│  ┌─────────────────────────────────────────┐    │
│  │            DevSwarm Server               │    │
│  │                                         │    │
│  │  resolve() ──► dispatch() ──► agent     │    │
│  │     │              │                    │    │
│  │  role/mode    claude / codex            │    │
│  │  grid/tier    auto-fallback             │    │
│  └─────────────────────────────────────────┘    │
└─────────────────────────────────────────────────┘
```

## Quick Start

### Build

```bash
git clone https://github.com/justrach/codedb.git
cd codedb
zig build          # builds zig-out/bin/devswarm
zig build test     # run all tests
```

### Connect to Codex

Add to `~/.codex/config.toml`:

```toml
[mcp_servers.devswarm]
command = "/path/to/devswarm"
args = ["--mcp"]
env = { REPO_PATH = "/path/to/your/repo" }
```

### Connect to Amp

Add to your MCP config:

```json
{
  "mcpServers": {
    "devswarm": {
      "command": "/path/to/devswarm",
      "args": ["--mcp"],
      "env": { "REPO_PATH": "/path/to/your/repo" }
    }
  }
}
```

### Connect to Claude Code

Add to `~/.claude.json`:

```json
{
  "mcpServers": {
    "devswarm": {
      "command": "/path/to/devswarm",
      "args": ["--mcp"],
      "env": { "REPO_PATH": "/path/to/your/repo" }
    }
  }
}
```

Then verify: `/mcp` in Claude Code, or just start using the 37 tools.

## What It Does

### Agent Orchestration

| Tool | What it does |
|------|-------------|
| `run_agent` | Spawn a single sub-agent with role/mode routing |
| `run_swarm` | Parallel swarm — orchestrator decomposes → N workers → synthesis |
| `run_task` | Multi-step chain presets (finder→fixer, reviewer→fixer, explore→report, etc.) |
| `review_fix_loop` | Iterative review → fix → review cycle until convergence |

### Agent Roles

Each role maps to a model tier via the grid, with tailored system prompts:

| Role | Tier | Writable | Purpose |
|------|------|----------|---------|
| `finder` | Sonnet | no | Search and locate code patterns |
| `reviewer` | Sonnet | no | Code review, correctness checks |
| `fixer` | Sonnet | yes | Apply fixes from review findings |
| `explorer` | Sonnet | no | Deep codebase exploration |
| `architect` | Opus | no | System design, architecture decisions |
| `orchestrator` | Opus | no | Task decomposition for swarms |
| `synthesizer` | Sonnet | no | Combine multi-agent outputs |
| `monitor` | Haiku | no | Lightweight checks, linting |

### Agent Modes

| Mode | Model | Behavior |
|------|-------|----------|
| `smart` | Sonnet | Balanced — search broadly, then act |
| `rush` | Haiku | Fast — one search pass, <3 lines |
| `deep` | Opus | Thorough — trace call chains, multiple passes |
| `free` | Haiku | Budget — fewest tokens possible |

### Code Intelligence (37 tools total)

Beyond agents, DevSwarm provides tools for the full development lifecycle:

- **Planning** — `decompose_feature`, `get_project_state`, `get_next_task`
- **Issues** — `create_issue`, `update_issue`, `close_issue`, batch operations
- **Git** — `create_branch`, `commit_with_context`, `push_branch`
- **PRs** — `create_pr`, `merge_pr`, `review_pr_impact`, `get_pr_diff`
- **Code Analysis** — `blast_radius`, `symbol_at`, `find_callers`, `find_callees`, `find_dependents`
- **History** — `git_history_for`, `recently_changed`

## Architecture

```
Layer 3: Orchestration     run_task, run_swarm, review_fix_loop
Layer 2: Primitive         run_agent → resolve() → dispatch()
Layer 1: Resolution        resolve() picks backend/model/prompt
Layer 0: Plumbing          detect, cascade, grid, prompts, dispatch
```

**Provider-agnostic**: `resolve()` decides everything (backend, model, system prompt, tool tier). `dispatch()` just spawns. Supports Claude and Codex backends with automatic fallback.

**Dynamic prompts**: System prompts are assembled at runtime from:
1. Agency rules (derived from analysis of production coding agent prompts)
2. Role-specific instructions
3. Mode guidance (smart/rush/deep/free)
4. Tool preamble (auto-detected: zig tools → ripgrep → grep fallback)

## How Swarms Work

```
You: "Find and fix all memory leaks in src/"

  ┌──────────────┐
  │ Orchestrator  │  Decomposes into N sub-tasks (JSON)
  │  (Opus)       │
  └──────┬───────┘
         │
    ┌────┼────┐
    ▼    ▼    ▼
  ┌──┐ ┌──┐ ┌──┐   N workers run in parallel (Zig threads)
  │W1│ │W2│ │W3│   Each gets role + system prompt + tools
  └──┘ └──┘ └──┘
    │    │    │
    └────┼────┘
         ▼
  ┌──────────────┐
  │ Synthesizer   │  Combines all results into one response
  │  (Sonnet)     │
  └──────────────┘
```

## Environment Variables

| Variable | Description |
|----------|-------------|
| `REPO_PATH` | Target repository path (or auto-detected from git) |
| `GITHUB_TOKEN` | GitHub API token for PR/issue operations |

## Requirements

- [Zig 0.15.x](https://ziglang.org/download/)
- `claude` CLI and/or `codex` CLI on PATH (for agent spawning)
- Git (for repository operations)

## License

MIT

---

*Previous changelog and version history: [README-changelog.md](README-changelog.md)*
