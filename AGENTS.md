# codedb Agent Guidelines

## Review guidelines

- Flag any security issues: injection, file traversal, untrusted input, secret exposure
- Verify that sensitive files (.env, .pem, .key, credentials) are excluded from indexing AND search
- Check that telemetry behavior matches documentation claims
- Flag any regression in benchmark-critical paths (threshold: 10%)
- Treat P1 issues as merge-blocking
- Verify new language parsers handle malformed input gracefully (braces in strings, unterminated comments)
- Check that installer scripts don't execute untrusted code or skip verification
- Treat CI, release, and installer changes as security-sensitive even when product code is unchanged
- Flag unsafe GitHub Actions triggers for untrusted PR code, especially `pull_request_target` and `workflow_run`
- Flag GitHub Actions that are not pinned to immutable commit SHAs
- Flag downloads in CI, installer, or release scripts that are executed without checksum or signature verification
- Flag secrets or write permissions that are broader than necessary; prefer least-privilege job and environment scoping
- Flag release flows that allow mutable tags, mutable release artifacts, or bypass of approval gates
- For automations that need privileged actions on third-party PRs or issues, prefer isolated GitHub App or bot patterns over privileged workflow triggers

## Security-sensitive areas

- `src/watcher.zig` — file indexing skip lists (secrets must be excluded)
- `src/mcp.zig` — file read/search (path traversal, scope boundaries)
- `src/telemetry.zig` — data collection and transmission (must match docs)
- `src/snapshot.zig` — sensitive file filtering
- `install/install.sh` — binary download and config modification
- `.github/workflows/*` — trigger choice, action pinning, permissions, secret scope, artifact integrity
- release scripts and packaging paths — checksum/signature verification, tag/release immutability, approval gates
