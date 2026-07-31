# codedb Hooks Labs

codedb does not have its own hook runtime. It installs an MCP server, and Codex
or Claude Code can run hooks around MCP tool calls. Use hooks for local policy,
logging, and guardrails around calls such as `codedb_search`; do not use them as
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

### Guard unbounded search calls

This hook blocks unbounded `codedb_search` calls unless the agent sets a
reasonable `max_results`. That keeps broad content searches from dumping too
much context.

`.codex/hooks.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "mcp__codedb__codedb_search",
        "hooks": [
          {
            "type": "command",
            "command": "/usr/bin/env bash \"$(git rev-parse --show-toplevel)/.codex/hooks/codedb_search_guard.sh\"",
            "timeout": 5,
            "statusMessage": "Checking codedb_search request"
          }
        ]
      }
    ]
  }
}
```

`.codex/hooks/codedb_search_guard.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

input="$(cat)"
max_results="$(printf '%s' "$input" | jq -r '.tool_input.max_results // empty')"

if [ -z "$max_results" ] || [ "$max_results" -gt 100 ]; then
  jq -n '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: "Use codedb_search with an explicit max_results of 100 or less."
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
codedb tools match as `mcp__codedb__codedb_tree`,
`mcp__codedb__codedb_search`, or `mcp__codedb__.*`.

`.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "mcp__codedb__codedb_search",
        "hooks": [
          {
            "type": "command",
            "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/codedb_search_guard.sh",
            "timeout": 5,
            "statusMessage": "Checking codedb_search request"
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

The same `codedb_search_guard.sh` script from the Codex lab works for Claude
Code because both clients pass MCP tool input as JSON and accept
`hookSpecificOutput.permissionDecision`.

`.claude/hooks/log_codedb_tool.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

input="$(cat)"
tool="$(printf '%s' "$input" | jq -r '.tool_name // "unknown"')"
event="$(printf '%s' "$input" | jq -r '.hook_event_name // "unknown"')"
query="$(printf '%s' "$input" | jq -r '.tool_input.query // empty')"
path="$(printf '%s' "$input" | jq -r '.tool_input.path // empty')"

mkdir -p .claude/logs
printf '%s\t%s\t%s\t%s\n' "$event" "$tool" "$query" "$path" >> .claude/logs/codedb-tools.tsv
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

## Public repos — DeepWiki

The `codedb_remote` tool (api.wiki.codes) was removed. For questions about
public GitHub repos, the installer registers [DeepWiki](https://deepwiki.com)
(`https://mcp.deepwiki.com/mcp` — free, no auth) as a separate remote MCP
server in each detected client. Its tools — `read_wiki_structure`,
`read_wiki_contents`, `ask_question` — match as `mcp__deepwiki__*` in hook
matchers if you want the same guardrail/logging patterns from the labs above.
Opt out of the registration with `CODEDB_INSTALL_DEEPWIKI=0`.
