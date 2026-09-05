> Current objective: **retrieval accuracy through default hybrid + hosted Jina**.
> Do not trade retrieval breadth or relevance for a speed-only improvement.
> The smaller ANN candidate pool was discarded; accuracy is the experiment goal.

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

## Jina hybrid accuracy experiments

Optimize accuracy through default hybrid, hosted Jina and local OpenPuffer mmap.
Preserve calibration, hosted exact fallback, and the 4× ANN pool. Do not run local
models or exchange retrieval breadth for speed. Release integration: 0.2.5853, based on the validated 0.2.5852 experiments. Old main Qwen experiments
are obsolete and do not govern this integration.

Before changing intent, read [ADR 0011](docs/adr/0011-release-intent-guards.md) for release review fixes.
Read [ADR 0010](docs/adr/0010-multilingual-datasets-and-test-intent.md),
[CLOUD.md](CLOUD.md), and [evals/](evals/README.md). The suite now has 128 questions
across six repositories. The latest native change recognizes whole-word test
intent and softly favors test files for explicit test requests. Anyhow top1
improves 16/20 to 18/20; the other five top1 scores hold. No per-question ranking
or recall regressions were measured. Requests was the fresh holdout for this
round and is now observed too. Chi still has one top-five miss; inspect the saved
failure catalog before proposing another change. Chi v2 corrects one ambiguous
gold label; never count label repairs as code improvements.

Use stable ReleaseFast binary copies outside zig-out because the unit suite
rebuilds the CLI in debug mode. Use the batch runner's development group; freeze
before a new holdout. Keep raw outcomes and credentials separate. The experiments preceded release integration; consult release notes for publication status.
