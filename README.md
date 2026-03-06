<p align="center">
  <img src="assets/logo.png" alt="DevSwarm" width="480" />
</p>

# DevSwarm

> Your AI coding assistant just got a team.

You're already using Codex, Amp, or Claude Code. It writes code, fixes bugs, answers questions. But it's still **one agent doing one thing at a time.**

What if it could spin up 10 agents in parallel, each tackling a different part of your codebase, then synthesize everything into one clean answer?

That's DevSwarm. An MCP server you drop into any AI coding tool that gives it the ability to **orchestrate itself** — spawning sub-agents, running parallel workloads, and chaining multi-step task pipelines. All without leaving your existing workflow.

```
You: "Find all the memory leaks in this codebase and fix them"

  Orchestrator decomposes the task
       │
  ┌────┼────┐
  ▼    ▼    ▼
 [W1] [W2] [W3]   ← parallel agents, each owns a subsystem
  │    │    │
  └────┼────┘
       ▼
  Synthesizer → one clean report back to you
```

No new UI. No new workflow. Just 37 new tools available inside the AI assistant you already use.

---

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

Add to your Amp MCP config:

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

Then run `/mcp` to verify — you'll see 37 tools added to your assistant.

---

## What You Can Do With It

### Swarms — parallel agents on big tasks

```
run_swarm("Audit the entire auth system for security issues", max_agents=5)
```

An orchestrator breaks the task into sub-tasks. Workers run in parallel. A synthesizer combines everything. You get one answer instead of five tabs.

### Task Chains — multi-step pipelines

```
run_task("Fix the race condition in src/queue.zig", preset="reviewer_fixer")
```

Built-in presets chain agents together automatically:

| Preset | Pipeline |
|--------|---------|
| `finder_fixer` | find the issue → fix it |
| `reviewer_fixer` | review → fix reported issues |
| `explore_report` | deep exploration → structured report |
| `architect_build` | design → implement |

### Review-Fix Loops — iterate until clean

```
review_fix_loop("Check for memory leaks", max_iterations=3)
```

Runs reviewer → fixer → reviewer again, until the reviewer says `NO_ISSUES_FOUND` or hits the iteration cap.

### Single Agents with Role + Model Routing

```
run_agent("Explain the PPR algorithm", role="explorer", mode="deep")
```

Each agent gets the right model automatically:

| Role | Model | Does |
|------|-------|------|
| `finder` | Sonnet | Search and locate |
| `reviewer` | Sonnet | Review for correctness |
| `fixer` | Sonnet | Apply fixes (writable) |
| `explorer` | Sonnet | Deep codebase exploration |
| `architect` | Opus | System design decisions |
| `orchestrator` | Opus | Decomposes swarm tasks |
| `synthesizer` | Sonnet | Combines agent outputs |
| `monitor` | Haiku | Lightweight checks |

| Mode | Model | Use when |
|------|-------|---------|
| `smart` | Sonnet | Most tasks |
| `rush` | Haiku | Quick answers |
| `deep` | Opus | Hard problems, architecture |
| `free` | Haiku | Minimize cost |

---

## Full Tool List (37 tools)

**Agents**
`run_agent` · `run_swarm` · `run_task` · `review_fix_loop` · `run_reviewer` · `run_explorer` · `run_zig_infra`

**Planning**
`decompose_feature` · `get_project_state` · `get_next_task` · `prioritize_issues`

**Issues**
`create_issue` · `update_issue` · `close_issue` · `get_issue` · `create_issues_batch` · `close_issues_batch` · `link_issues`

**Git**
`create_branch` · `get_current_branch` · `commit_with_context` · `push_branch` · `recently_changed` · `git_history_for`

**Pull Requests**
`create_pr` · `get_pr_status` · `list_open_prs` · `merge_pr` · `get_pr_diff` · `review_pr_impact`

**Code Intelligence**
`blast_radius` · `relevant_context` · `symbol_at` · `find_callers` · `find_callees` · `find_dependents`

**Repo**
`set_repo`

---

## How It Works

DevSwarm is a provider-agnostic runtime. When you call `run_agent`, it:

1. **Resolves** — picks backend (Claude or Codex), model tier, system prompt, and tool preamble based on role + mode + what's available on your PATH
2. **Dispatches** — spawns the agent on the right backend, falls back automatically if one isn't available
3. **Returns** — streams output back through MCP

System prompts are assembled dynamically from agency rules, role instructions, mode guidance, and auto-detected tool availability (zig tools → ripgrep → grep). No hardcoded prompts.

---

## Requirements

- [Zig 0.15.x](https://ziglang.org/download/)
- `codex` and/or `claude` CLI on PATH
- Git

## License

MIT

---

*Full changelog: [README-changelog.md](README-changelog.md)*
