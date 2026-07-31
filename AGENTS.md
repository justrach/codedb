# codedb Agent Guidelines

## What codedb is (and isn't)

codedb is a **code-intelligence and context tool, not an editor.** It exists to
help agents *find and understand* code — structural search, symbol/caller
lookup, dependency graph, outlines, and task-shaped context — so they can edit
with their own native tools. codedb has **no edit capability**: the old
`codedb_edit` fallback (and the HTTP `POST /edit` endpoint, the post-edit
linter, and `codedb_diagnostics`) was removed because MCP edit calls bypass the
client's own undo/rewind tracking. Keep that framing consistent across tool
descriptions, the MCP `initialize` instructions, the README, and these docs.

## Review guidelines

- Flag any security issues: injection, file traversal, untrusted input, secret exposure
- Verify that sensitive files (.env, .pem, .key, credentials) are excluded from indexing AND search
- Check that telemetry behavior matches documentation claims
- Flag any regression in benchmark-critical paths (threshold: 10%)
- Treat P1 issues as merge-blocking
- Verify new language parsers handle malformed input gracefully (braces in strings, unterminated comments)
- Check that installer scripts don't execute untrusted code or skip verification

## Pre-merge verification

Run these before merging any MCP-related change:

```bash
zig build test                                          # unit tests
python3 scripts/e2e_mcp_test.py \
    --binary zig-out/bin/codedb \
    --project /path/to/codedb                          # E2E MCP scenarios
```

`e2e_mcp_test.py` covers three scenarios:
1. **issue-346 regression** — spawn from cwd=`/`, roots handshake, tools return real data
2. **Normal mode** — explicit positional root (`codedb <path> mcp`), immediate scan
3. **No-roots client** — spawn from `/` with no roots capability, stays alive gracefully

## Security-sensitive areas

- `src/watcher.zig` — file indexing skip lists (secrets must be excluded)
- `src/mcp.zig` — file read/search (path traversal, scope boundaries)
- `src/telemetry.zig` — data collection and transmission (must match docs)
- `src/snapshot.zig` — sensitive file filtering
- `install/install.sh` — binary download and config modification
