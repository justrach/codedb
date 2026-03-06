<p align="center">
  <img src="assets/logo.png" alt="DevSwarm" width="480" />
</p>

<p align="center">
  <a href="https://github.com/justrach/codedb/releases/latest"><img src="https://img.shields.io/github/v/release/justrach/codedb?style=flat-square&label=version" alt="Latest Release" /></a>
  <a href="https://github.com/justrach/codedb/blob/main/LICENSE"><img src="https://img.shields.io/github/license/justrach/codedb?style=flat-square" alt="MIT License" /></a>
  <a href="https://github.com/justrach/codedb/stargazers"><img src="https://img.shields.io/github/stars/justrach/codedb?style=flat-square" alt="GitHub Stars" /></a>
  <img src="https://img.shields.io/badge/built_with-Zig-f7a41d?style=flat-square" alt="Built with Zig" />
  <img src="https://img.shields.io/badge/MCP-compatible-6c63ff?style=flat-square" alt="MCP Compatible" />
</p>

<h3 align="center">Your AI coding assistant, now with a team.</h3>

<p align="center">
  Drop one MCP server into Codex, Amp, or Claude Code and get <strong>37 tools</strong> for spawning parallel agents, running task pipelines, and doing multi-step code work — without leaving your existing workflow.
</p>

<p align="center">
  <a href="#-quick-start">Quick Start</a> ·
  <a href="#-what-you-can-do">Features</a> ·
  <a href="#-full-tool-list">All 37 Tools</a> ·
  <a href="#-how-it-works">How It Works</a> ·
  <a href="#-contributing">Contributing</a>
</p>

---

## The Problem

You're already using Codex, Amp, or Claude Code. It writes code, fixes bugs, answers questions. But it's still **one agent doing one thing at a time**.

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

DevSwarm is an MCP server that gives your AI assistant the ability to **orchestrate itself** — spawning sub-agents, running parallel workloads, and chaining multi-step task pipelines. No new UI. No new workflow.

---

## ⚡ Quick Start

### Option 1: Download a binary (recommended)

Grab the latest release for your platform from [GitHub Releases](https://github.com/justrach/codedb/releases/latest).

### Option 2: Build from source

```bash
git clone https://github.com/justrach/codedb.git
cd codedb
zig build          # builds zig-out/bin/devswarm
zig build test     # run all tests
```

**Requirements:** [Zig 0.15.x](https://ziglang.org/download/), `codex` and/or `claude` CLI on PATH, Git

---

### Connect to your AI assistant

<details>
<summary><strong>Claude Code</strong></summary>

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
</details>

<details>
<summary><strong>Codex</strong></summary>

Add to `~/.codex/config.toml`:

```toml
[mcp_servers.devswarm]
command = "/path/to/devswarm"
args = ["--mcp"]
env = { REPO_PATH = "/path/to/your/repo" }
```
</details>

<details>
<summary><strong>Amp</strong></summary>

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
</details>

---

## 🚀 What You Can Do

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

| Mode | Use when |
|------|---------|
| `smart` | Most tasks |
| `rush` | Quick answers |
| `deep` | Hard problems, architecture |
| `free` | Minimize cost |

---

## 🔧 Full Tool List (37 tools)

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

## ⚙️ How It Works

DevSwarm is a provider-agnostic runtime. When you call `run_agent`, it:

1. **Resolves** — picks backend (Claude or Codex), model tier, system prompt, and tool preamble based on role + mode + what's available on your PATH
2. **Dispatches** — spawns the agent on the right backend, falls back automatically if one isn't available
3. **Returns** — streams output back through MCP

System prompts are assembled dynamically from agency rules, role instructions, mode guidance, and auto-detected tool availability (zig tools → ripgrep → grep). No hardcoded prompts.

---

## 🤝 Contributing

Contributions are welcome! Please open an issue before submitting a large PR so we can discuss the approach.

```bash
git clone https://github.com/justrach/codedb.git
cd codedb
zig build test     # make sure tests pass before and after your change
```

---

## License

MIT — see [LICENSE](LICENSE)

---

*Full changelog: [README-changelog.md](README-changelog.md)*
