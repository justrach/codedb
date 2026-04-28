# codedb Hooks Labs

codedb does not have its own hook runtime. It installs an MCP server, and Codex
or Claude Code can run hooks around MCP tool calls. Use hooks for local policy,
logging, and guardrails around calls such as `codedb_remote`; do not use them as
the only security boundary.

The installer registers the MCP server. Hook configuration is separate because
hooks execute arbitrary commands with your user permissions.

## Lab 1: Codex Hooks

Enable Codex hooks in `~/.codex/config.toml`:

```toml
[features]
codex_hooks = true
```

The codedb MCP registration should look like this:

```toml
[mcp_servers.codedb]
command = "/Users/you/bin/codedb"
args = ["mcp"]
startup_timeout_sec = 30
```

Codex discovers hooks next to active config layers:

- `~/.codex/hooks.json`
- `~/.codex/config.toml`
- `<repo>/.codex/hooks.json`
- `<repo>/.codex/config.toml`

Project-local hooks load only when the project `.codex/` layer is trusted.
Matching hooks from multiple files all run.

### Guard remote tree calls

This hook blocks unbounded `codedb_remote action=tree` calls unless the agent
uses `limit`, `prefix`, or compact summary mode. That keeps huge remote repos
from dumping too much context.

`.codex/hooks.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "mcp__codedb__codedb_remote",
        "hooks": [
          {
            "type": "command",
            "command": "/usr/bin/env bash \"$(git rev-parse --show-toplevel)/.codex/hooks/codedb_remote_guard.sh\"",
            "timeout": 5,
            "statusMessage": "Checking codedb_remote request"
          }
        ]
      }
    ]
  }
}
```

`.codex/hooks/codedb_remote_guard.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

input="$(cat)"
action="$(printf '%s' "$input" | jq -r '.tool_input.action // empty')"
limit="$(printf '%s' "$input" | jq -r '.tool_input.limit // empty')"
prefix="$(printf '%s' "$input" | jq -r '.tool_input.prefix // empty')"
expand="$(printf '%s' "$input" | jq -r '.tool_input.expand // empty')"

if [ "$action" = "tree" ] && [ -z "$limit" ] && [ -z "$prefix" ] && [ "$expand" != "false" ]; then
  jq -n '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: "Use codedb_remote tree with expand=false, a prefix, or a limit."
    }
  }'
fi
```

Useful Codex hook events for codedb:

- `PreToolUse`: block or ask before a `mcp__codedb__...` call.
- `PostToolUse`: summarize or log MCP output after it returns.
- `PermissionRequest`: decide approval prompts.
- `UserPromptSubmit`: add repo-specific context before the prompt reaches the model.
- `Stop`: continue a turn when validation is still missing.

## Lab 2: Claude Code Hooks

Claude Code hook settings live in Claude settings files, while codedb MCP
registration may live in `~/.claude.json` depending on the installed Claude
Code version.

Claude Code's documentation index is published at
`https://code.claude.com/docs/llms.txt`; use it to discover the current hook
reference pages before relying on advanced events.

Common hook locations:

- `~/.claude/settings.json`
- `.claude/settings.json`
- `.claude/settings.local.json`
- managed policy settings
- plugin `hooks/hooks.json`
- skill or agent frontmatter

Claude Code MCP tool names use the same `mcp__<server>__<tool>` shape, so
codedb tools match as `mcp__codedb__codedb_remote`,
`mcp__codedb__codedb_search`, or `mcp__codedb__.*`.

`.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "mcp__codedb__codedb_remote",
        "hooks": [
          {
            "type": "command",
            "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/codedb_remote_guard.sh",
            "timeout": 5,
            "statusMessage": "Checking codedb_remote request"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "mcp__codedb__.*",
        "hooks": [
          {
            "type": "command",
            "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/log_codedb_tool.sh",
            "async": true,
            "timeout": 30
          }
        ]
      }
    ]
  }
}
```

The same `codedb_remote_guard.sh` script from the Codex lab works for Claude
Code because both clients pass MCP tool input as JSON and accept
`hookSpecificOutput.permissionDecision`.

`.claude/hooks/log_codedb_tool.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

input="$(cat)"
tool="$(printf '%s' "$input" | jq -r '.tool_name // "unknown"')"
event="$(printf '%s' "$input" | jq -r '.hook_event_name // "unknown"')"
repo="$(printf '%s' "$input" | jq -r '.tool_input.repo // empty')"
action="$(printf '%s' "$input" | jq -r '.tool_input.action // empty')"

mkdir -p .claude/logs
printf '%s\t%s\t%s\t%s\n' "$event" "$tool" "$repo" "$action" >> .claude/logs/codedb-tools.tsv
```

Claude Code has more hook events and handler types than Codex. The ones most
useful for codedb are:

- `PreToolUse`, `PostToolUse`, and `PostToolUseFailure` for MCP tool policy and telemetry.
- `PostToolBatch` when the next model call needs context from a full batch of tools.
- `UserPromptSubmit` and `UserPromptExpansion` for prompt-time repo context.
- `Stop` or `SubagentStop` for validation gates before an agent finishes.
- `ConfigChange`, `CwdChanged`, and `FileChanged` for environment reloads.

Claude Code also supports command, HTTP, MCP-tool, prompt, and agent hook
handlers. Prefer command hooks for deterministic policy checks; use async
command hooks for logging that should not block the agent loop.

## codedb_remote Defaults

`codedb_remote` always calls `https://api.wiki.codes`. The old `codegraff`
backend name is no longer a supported route. Keep `backend="wiki"` only for
compatibility with older prompts, or omit `backend` entirely.

Start with:

```text
codedb_remote repo="openai/codex" action="actions"
codedb_remote repo="openai/codex" action="tree" expand=false
codedb_remote repo="openai/codex" action="tree" prefix="codex-rs/" limit=100
codedb_remote repo="openai/codex" action="search" query="AuthMode" limit=10
codedb_remote repo="openai/codex" action="branches" limit=20
codedb_remote repo="openai/codex" action="read" path="codex-rs/core/src/codex.rs" lines="1-80"
```

Use `scope="runtime"` for user-facing dependency risk and `scope="all"` when
you also need dev and tooling dependencies:

```text
codedb_remote repo="vercel/next.js" action="score" scope="runtime"
codedb_remote repo="vercel/next.js" action="cves" scope="all"
```
