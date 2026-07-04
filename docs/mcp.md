# codedb MCP Setup

`codedb mcp` runs as a stdio JSON-RPC server speaking the
[Model Context Protocol](https://spec.modelcontextprotocol.io/). It exposes
21 tools for code intelligence — search, outline, callers, deps, edit,
context, etc. — backed by the indexes in `~/.codedb/projects/<hash>/`.

This guide covers per-client setup, how codedb decides which project to
scan, and the most common failure modes.

> **codedb is a context tool, not an editor.** Its job is to help an agent
> *find and understand* code — fast structural search, symbol/caller lookup,
> dependency graph, outlines, and task-shaped context. Edits belong to your
> client's native file tools; `codedb_edit` exists only as a fallback for
> clients that have no native editing capability.

---

## 1. Quick install (auto-configures all detected clients)

```bash
curl -fsSL https://codedb.codegraff.com/install.sh | bash
```

The installer downloads the binary for your platform, drops it in
`~/.local/bin/` (or `/usr/local/bin/` on root installs), and auto-registers
codedb as an MCP server in every client it can find — Claude Code, Codex,
Gemini CLI, Cursor, opencode. It prints the exact `codedb mcp` command it
registered.

If you prefer to wire it up by hand, the client-specific snippets below
all work directly.

---

## 2. Client-specific configuration

All clients launch `codedb mcp` as a stdio child process. Replace
`/usr/local/bin/codedb` with `which codedb` output on your system.

### Claude Code

```bash
claude mcp add codedb -s user -- /usr/local/bin/codedb mcp
```

Or edit `~/.claude.json` directly:

```json
{
  "mcpServers": {
    "codedb": {
      "command": "/usr/local/bin/codedb",
      "args": ["mcp"]
    }
  }
}
```

Verify: `claude mcp list` should show `codedb: /usr/local/bin/codedb mcp - ✓ Connected`.

### Claude Desktop

Edit `~/Library/Application Support/Claude/claude_desktop_config.json`
(macOS) or `%APPDATA%\Claude\claude_desktop_config.json` (Windows):

```json
{
  "mcpServers": {
    "codedb": {
      "command": "/usr/local/bin/codedb",
      "args": ["mcp"]
    }
  }
}
```

Restart Claude Desktop. The tools should appear in the slash-command menu.

### Cursor

Edit `~/.cursor/mcp.json` (per-user) or `<project>/.cursor/mcp.json`
(per-project):

```json
{
  "mcpServers": {
    "codedb": {
      "command": "/usr/local/bin/codedb",
      "args": ["mcp"]
    }
  }
}
```

Cursor advertises the open workspace via the `roots/list` MCP handshake,
so codedb scans the right project automatically (see Root Resolution
below).

### VS Code (with an MCP extension)

Same `mcpServers` block as Cursor, scoped to whichever extension you use.

### Codex CLI

```bash
codex mcp add codedb -- /usr/local/bin/codedb mcp
```

### Gemini CLI / opencode

Both read MCP configuration from `~/.gemini/mcp.json` (Gemini) and
`~/.config/opencode/mcp.json` (opencode):

```json
{
  "mcpServers": {
    "codedb": {
      "command": "/usr/local/bin/codedb",
      "args": ["mcp"]
    }
  }
}
```

---

## 3. Root resolution — which project does `codedb mcp` scan?

`codedb mcp` figures out the project root in this order (first match wins):

1. **MCP `roots/list` handshake** (preferred). When a client supports it
   (Cursor, Windsurf, recent VS Code MCP extensions), codedb requests
   `roots/list` immediately after `initialize` and uses the first workspace
   root the client returns. This is the most reliable path — codedb scans
   exactly the project the user has open in their editor.

2. **Per-call `project` argument**. Every tool accepts an optional
   `project: "<abs path>"` field that switches the active project for that
   single call. Useful for cross-project queries:

   ```json
   {
     "name": "codedb_search",
     "arguments": {
       "query": "scheduleUpdateOnFiber",
       "project": "/Users/me/code/react"
     }
   }
   ```

3. **Process `cwd`**. If the client doesn't speak `roots/list` and no
   per-call `project` is set, codedb falls back to the directory it was
   launched from. Some editors launch MCP servers from `/Applications` or
   `~`, which is almost certainly the wrong directory — set the `project`
   arg explicitly for those.

System directories (`/`, `/Applications`, `/usr`, `/opt`, `~`,
`/tmp`, etc.) are blocked from being indexed as project roots — see
[`docs/rfc-346-mcp-root-resolution.md`](rfc-346-mcp-root-resolution.md)
for the full safety logic.

---

## 4. `.codedbrc` — per-project configuration

Drop a `.codedbrc` at the root of any project to override defaults for
that project. INI-style `key = value` pairs, one per line, `#` for
comments. Unknown keys are ignored.

```ini
# .codedbrc
max_cached   = 16384   # in-memory ContentCache size (files); default 16384
max_versions = 100     # versions kept per file in the change log; default 100
rerank_trace = false   # write per-search rerank-trace.jsonl (debug only)
```

Pass an alternative path with `--config-file <path>` to the CLI for
testing.

---

## 5. Verifying the install

```bash
codedb --version          # codedb 0.2.5815 (or later)
codedb status             # one-line: indexed file count + scan phase
```

In a client, the simplest tool to smoke-test is `codedb_status` — it
takes no arguments and returns `files: N, seq: N, scan: ready` in <50 ms.

---

## 6. Troubleshooting

### "No project root yet" / empty tree

The MCP server hasn't received a project root. Either:
- the client doesn't speak `roots/list`, or
- the client launched codedb from a system directory that's blocked from
  indexing (`/Applications`, `/usr`, `~`, etc.).

**Fix:** pass `project: "/abs/path/to/your/project"` on the first tool
call, or restart the client from inside the project directory.

### `codedb_find` returns `missing 'query'`

Fixed in v0.2.5815 — `codedb_find` now accepts `query`, `name`, `path`,
`pattern`, and `q` as aliases. If you're still seeing this error,
`codedb --version` will show < 0.2.5815; rerun the installer.

### Tools list looks short / `codedb_context` is missing

`codedb_context` was added in **v0.2.5815**. Older binaries expose only
20 tools. Upgrade with `codedb update` (or the installer one-liner above)
and verify with `codedb --version`.

### Snapshot indexer keeps re-scanning

The watcher debounces filesystem events for ~500 ms. If your editor saves
files in quick succession (e.g. a formatter that rewrites everything),
back-to-back saves can extend the scan phase. Check `codedb status` —
`scan: ready` means it's caught up.

### Permission errors on macOS

The first time you run a fresh codedb binary on macOS, Gatekeeper may
quarantine it. Apple Silicon release binaries from v0.2.5811+ are signed
with a Developer ID and notarized via Apple — verify with:

```bash
spctl -a -vv -t install /usr/local/bin/codedb
# expected: accepted, source=Notarized Developer ID
```

The Intel `codedb-darwin-x86_64` release slice is temporarily unsigned.
Signed Zig 0.16 x86_64-macos binaries can segfault on macOS 26 and under
Rosetta after codesign, so the release workflow leaves that artifact
unsigned and relies on the published SHA256 checksum instead.

If you built from source on Apple Silicon, codesign the binary locally:

```bash
codesign --force --sign - /usr/local/bin/codedb
```

Avoid codesigning locally built x86_64-macos binaries on macOS 26 until
the upstream Zig/Mach-O issue is resolved.

### Stale signatures after `cp` over an existing binary

macOS caches codesignatures by path. After replacing the binary,
re-codesign Apple Silicon builds or the MCP server may fail to launch:

```bash
codesign --force --sign - /usr/local/bin/codedb
```

The installer does this for you.

---

## 7. Going deeper

- [Architecture](architecture.md) — engine internals, index layout
- [CLI reference](cli.md) — every command, every flag
- [Skill base & context files](skills.md) — `agents.md`, `CLAUDE.md`,
  `GEMINI.md`, and the per-project skill hierarchy
- [RFC #346 — MCP root resolution](rfc-346-mcp-root-resolution.md) —
  full design + safety logic for project-root detection
- [Telemetry](telemetry.md) — what codedb sends, how to disable
