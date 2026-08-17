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

## Cursor Cloud specific instructions

Single-product Zig codebase: one binary `codedb` exposing a CLI, an MCP stdio
server, and an HTTP server (`:7719`). No external services, DB, or network deps
— the vendored `nanoregex` under `vendor/` is the only dependency.

### Toolchain

- Requires the exact pinned Zig dev snapshot `0.17.0-dev.813+2153f8143`
  (`minimum_zig_version` in `build.zig.zon`, also pinned in
  `.github/workflows/release-binaries.yml`). The startup update script installs
  it to `~/.local/zig` and symlinks it to `/usr/local/bin/zig`, so `zig` is on
  `PATH`. A non-matching `zig` will fail the build.

### Build / lint / test / run

- Build (dev/debug): `zig build` → binary at `zig-out/bin/codedb`. See README
  "Building from Source" for release/cross-compile variants.
- Lint (format check): `zig fmt --check src`. NOTE: on the current tree this
  exits non-zero due to **pre-existing** formatting drift in a handful of files
  (e.g. `src/update.zig`, `src/lib.zig`, `src/watcher.zig`); that drift is not
  introduced by the environment. Only judge your own changed files.
- Tests: `zig build test` (or a single split binary, e.g. `zig build test-mcp`;
  see `build.zig`).
- E2E MCP harness: `python3 scripts/e2e_mcp_test.py --binary zig-out/bin/codedb
  --project <repo>` (per the Pre-merge section above).
- Run the app: one-shot CLI (`codedb <root> tree|search|find|word|outline …`;
  root arg comes FIRST) works out of the box. Long-running daemons are
  `codedb serve <root>` (HTTP) and `codedb mcp <root>` (MCP stdio).

### Linux gotchas (important)

- The long-running daemons (`serve` / `mcp`) and the watcher-exercising tests
  crash on Linux with a `watcher.zig` panic ("integer does not fit in
  destination type") when arming inotify against the sentinel path
  `/tmp/codedb-notify`. Root cause: the binary links libc, so `std.posix.errno`
  uses libc semantics (only `-1` is an error) while `std.os.linux.inotify_add_watch`
  returns `-errno`; a missing sentinel path yields `-ENOENT`, which is
  misread as success and then `@intCast` panics. Maintainers develop on macOS
  (kqueue path), so this Linux-only bug is currently unfixed on `main`.
- Workaround to run the daemons / full E2E harness without touching source:
  `: > /tmp/codedb-notify` (create the sentinel file) before starting the
  process. With it present, the daemon stays up and `e2e_mcp_test.py` passes
  53/54 (the lone failure is an unrelated `codedb_index` MCP-tool assertion).
- `zig build test` shows one pre-existing crash on Linux
  (`test_index … issue-690 incrementalLoop`) from the same inotify bug; the
  other 981 tests pass.
- `scripts/e2e_mcp_test.py` creates temp projects in the *parent* of
  `--project`. `/workspace`'s parent is `/` (not writable), so point
  `--project` at a copy under a writable parent (e.g. `~/codedb-run`) when
  running scenarios 5–7.
