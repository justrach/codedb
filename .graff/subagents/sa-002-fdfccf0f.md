# subagent sa-002-fdfccf0f

- label: Review auto-update patch
- kind: subagent
- status: ok
- elapsed_ms: 317071
- tools: skill!,codedb,codedb,bash,bash,bash,bash,bash,read_file,read_file,read_file,bash,read_file,read_file,read_file,read_file,read_file,bash!,bash!,bash!,bash!,bash,bash,bash,bash,bash,bash,bash,bash,bash,bash,bash,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,read_file,codedb,codedb,codedb,codedb,read_file,read_file,read_file,read_file,bash,bash,bash,read_file,read_file,codedb,read_file,codedb,read_file,read_file,bash,bash,codedb,codedb,codedb

## task

HARD CONSTRAINTS (user, do not violate):
- When discussing this release, describe only the latest unreleased changes just pushed, not v0.2.5837.

Review the current unstaged diff in README.md, src/update.zig, and src/test_mcp.zig for the requested MCP-only automatic update behavior. Do not edit. Focus on P1/security concerns, detached-thread lifetime and allocation ownership, subprocess/stdout behavior, offline semantics, cross-platform behavior, race conditions, whether the built-in updater truly checksum-verifies before replacement, test adequacy, and scope. Report findings by severity with exact path/line refs; explicitly say if no merge-blocking findings. Ignore unrelated pre-existing worktree files.

## report

## P1 — merge blocker

- **Windows replacement can leave the executable unlaunchable.** The new worker invokes the built-in updater at `src/update.zig:418`. On Windows, `src/update.zig:313-315` first moves the current executable to `.old`, then attempts to rename the verified temporary file into place. If the second rename fails (antivirus, permissions, transient I/O, or another updater), the original path remains absent; the detached child exits, and the next MCP invocation cannot start. This contradicts `README.md:133`.
  - **Fix:** make replacement transactional: retain `.old` until the new rename succeeds, restore it on failure, and serialize replacement with an updater lock. Prefer the platform atomic-replace API where possible.

## P2 — concurrency/race

- **The 24-hour throttle is not atomic.** `src/update.zig:391-404` performs an unlocked read/check, spawns the worker, then writes the stamp. Two simultaneous MCP starts can both pass the check and launch workers, potentially racing replacement—especially the Windows `.old` handling—and violating the “at most once every 24 hours” behavior.
  - **Fix:** use an exclusive lock/flock around stamp check, worker admission, and stamp update; share the lock with manual updates.

## P2 — security hardening

- **Checksum verification has a temp-file TOCTOU window.** `src/update.zig:286-290` uses a predictable timestamp-based path created by `curl`; `src/update.zig:292-295` hashes it, then `src/update.zig:315` renames it later. A local process able to manipulate the installation directory can replace the file after verification, or pre-create a symlink.
  - **Fix:** create a private/exclusive temporary file (`O_CREAT|O_EXCL`/`mkstemp`), download into the owned file descriptor, hash that same descriptor, and atomically rename without following attacker-controlled links.

- **The unattended path still executes `curl` via `PATH`** (`src/update.zig:321`, reached by the new worker at `src/update.zig:418`). A tampered `PATH` can cause arbitrary code execution even if the downloaded binary later fails checksum verification.
  - **Fix:** use an embedded HTTP client or resolve and validate a trusted absolute `curl` path; checksum verification cannot undo subprocess side effects.

## P2 — test adequacy

- `src/test_mcp.zig:437-444` only verifies the two argv strings. It does not exercise detached-thread ownership, stdout/stderr capture, offline failure, concurrent starts, checksum-mismatch non-replacement, Windows rollback, or the actual no-shell subprocess path.
  - **Fix:** add injectable worker/process tests plus platform integration coverage for failed replacement and concurrent updater admission.

## Confirmed behavior

- The new invocation is direct argv, not a shell, and paths containing spaces are preserved.
- `executable_path` ownership is correctly transferred to the detached worker and freed there; captured stdout/stderr are freed at `src/update.zig:423-424`.
- The parent MCP process is not blocked by network failure.
- The normal updater path does hash the downloaded file at `src/update.zig:292-295` before attempting replacement at `src/update.zig:315`; the concerns above are about replacement atomicity and the hash-to-rename race.
- `zig build test` passes.

⟦ELITE-LIVE-ON-PROD⟧
