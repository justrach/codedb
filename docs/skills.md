# codedb Skill Base & Context Files

This guide explains the hierarchy of context / instruction files that
codedb-aware agents (Claude Code, Gemini CLI, Codex, Cursor, opencode,
etc.) consult when working in a codedb-indexed project, and how each
file's scope and precedence works.

There are three layers, from broadest to narrowest:

1. **Agent profile files** — `agents.md`, `CLAUDE.md`, `GEMINI.md`,
   `.cursorrules` and friends. Per-agent project-wide instructions
   committed to the repo.
2. **Per-project codedb config** — `.codedbrc`. Tunes index sizes,
   versioning, and tracing for the project.
3. **Per-developer memory** — `~/.claude/projects/<id>/memory/`
   (Claude Code), `~/.gemini/memory/` (Gemini CLI). Personal, not
   committed, persists across sessions.

---

## 1. Agent profile files (committed, per-repo)

These files live at the repo root (or a subdirectory) and are loaded by
the agent at session start. Each agent reads its own file:

| Agent | File name | Notes |
|---|---|---|
| Claude Code | `CLAUDE.md` | also reads `agents.md` |
| Codex CLI | `agents.md` | reads `CLAUDE.md` as a fallback |
| Gemini CLI | `GEMINI.md` | |
| Cursor | `.cursorrules` | |
| opencode | `AGENTS.md` | |

codedb itself ships `docs/agents.md` (the project's contributor
instructions) — that is the canonical example of what an agent profile
file looks like.

### What to put in them

Agent profile files should describe things the LLM cannot derive from
reading source — project conventions, the build/test commands, where
tests live, the issue-filing protocol, code style preferences, language
versions. Things that *are* derivable from source (file layout, function
signatures, dependency graph) belong in the code, not here — agents
discover those via `codedb_tree`, `codedb_outline`, `codedb_deps`, etc.

Example skeleton, drawn from `docs/agents.md`:

```markdown
# <project> — Agent Instructions

## Project
<one paragraph: language, key dependencies, what to run for tests>

## Rules

### Filing Issues
<process the maintainer wants — required labels, failing-test convention>

### Test Style
<framework, allocator conventions, naming>

### Code Style
<comment policy, refactor scope, language version constraints>
```

### Subdirectory overrides

Agents that support hierarchical instruction files (Gemini CLI, Codex)
also read `./src/CLAUDE.md`, `./tests/AGENTS.md`, etc. — the agent
merges the deepest-matching file's rules on top of the repo-root file.

Use subdirectory files when one part of the codebase has materially
different conventions (e.g. `frontend/` uses TypeScript with different
formatting from a Zig `backend/`).

### Activating specialised skills

Claude Code and Gemini CLI both support **skills** — named bundles of
instructions that the agent can invoke explicitly (`/skill <name>`) or
that fire on matching prompts. codedb provides `/codedb-troubleshooting`
and `/codedb-bench` skills when installed via the official installer.

A skill lives under `~/.claude/skills/<name>/SKILL.md` (Claude Code) or
`~/.gemini/skills/<name>/SKILL.md` (Gemini). Same shape as a profile
file, plus front-matter declaring when it activates:

```yaml
---
name: codedb-troubleshooting
description: Diagnose codedb MCP errors, missing files, stale indexes
when:
  - "codedb_*" tool calls return unexpected errors
  - "no project root" or "scan: loading_snapshot" appears
---
```

---

## 2. `.codedbrc` — per-project codedb tuning (committed)

Drop a `.codedbrc` at the project root to override codedb defaults for
that project. Full keys + defaults:

```ini
# .codedbrc
max_cached   = 16384   # in-memory ContentCache size (files); v0.2.5815+
max_versions = 100     # versions kept per file in the change log
max_watched  = 1024    # macOS vnode-FD ceiling; overflow paths are polled
rerank_trace = false   # write per-search rerank-trace.jsonl (debug)
```

INI-style `key = value`, one per line, `#` for comments, unknown keys
ignored. Pass `--config-file <path>` to the CLI to load an alternative.

Until v0.2.5815 (#460) `max_cached` was parsed-and-forgotten — the
ContentCache was hardcoded to 16,384 files. v0.2.5815+ actually honors
it.

---

## 3. Per-developer memory (not committed)

Personal memory persists across sessions for **one** developer on **one**
machine, never committed. Different agents store it differently:

| Agent | Path |
|---|---|
| Claude Code | `~/.claude/projects/<project-id>/memory/` |
| Gemini CLI | `~/.gemini/memory/<project-id>/` |

Memory is for things specific to *you*: your preferred review style, who
the right reviewer is, past incidents you got burned by. Anything the
team needs to know belongs in the committed agent profile file instead.

---

## 4. Where each file goes — quick reference

| What | Where | Committed? | Scope |
|---|---|---|---|
| Project conventions, build/test commands | `agents.md` / `CLAUDE.md` / `GEMINI.md` at repo root | yes | every developer + agent |
| Subdirectory-specific rules | `<subdir>/CLAUDE.md` etc. | yes | when working in that subdir |
| Index sizes, change-log depth | `.codedbrc` | yes | every developer (per project) |
| Personal preferences, past incidents | `~/.claude/...memory/` | no | one developer, all projects |
| Specialised skills | `~/.claude/skills/<name>/SKILL.md` | no | one developer, on demand |

---

## 5. Linking it to MCP

When an agent uses codedb (via [`docs/mcp.md`](mcp.md)), the agent
profile file teaches the agent **how** to use it — e.g.:

```markdown
## How to navigate this repo
- Use `codedb_tree` first to orient.
- Use `codedb_context` with a natural-language task when starting work
  on an unfamiliar area — one call replaces 3–5 search/word/symbol calls.
- Use `codedb_symbol` for exact definition lookups, `codedb_search` for
  substring matches, `codedb_word` for single-identifier lookups.
- Use `codedb_callers` to find every usage of a symbol before refactoring.
```

The combination — codedb providing the **engine**, the agent profile
file providing the **playbook** — is what makes the agent fast and
opinionated on your codebase specifically.

---

## See also

- [MCP setup](mcp.md) — client configurations + root resolution
- [CLI reference](cli.md) — every codedb command + flag
- [Architecture](architecture.md) — engine internals
