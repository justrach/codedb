# subagent sa-003-54f1efcc

- label: Review Zig migration
- kind: workflow_task
- status: ok
- elapsed_ms: 132378
- tools: codedb,bash,bash,bash,bash,bash,bash,bash!,bash,bash,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb

## task

Review the current working tree changes in the codedb repository for the Zig 0.17.0-dev migration. Focus on correctness, portability, security, build graph, dependency reproducibility, and whether pre-existing user changes in src/index.zig and src/test_index.zig appear preserved. Inspect git diff/status and relevant files. Do not edit anything. Report actionable P0/P1/P2 findings and verification gaps.

## report

## Findings

### P1 — Required source and dependency files are untracked, so the migration can produce a broken commit

**Locations:** `build.zig.zon:8`, `src/mcp.zig:3`, `build.zig:186`

The tracked changes now depend on files that Git does not currently track:

- `build.zig.zon:8` points `nanoregex` at `vendor/nanoregex`, but the entire `vendor/` tree is untracked.
- `src/mcp.zig` imports `mcp_json.zig`, but `src/mcp_json.zig` is untracked.
- `build.zig:186` adds the WASM root; the source is tracked, but the generated `wasm/codedb.wasm` is also untracked and its intended publication status is unclear.

**Failure sequence:**

1. Commit only the modified tracked files, as a normal `git commit -a` would do.
2. Clone or check out that commit in CI.
3. Run `zig build test`.
4. Dependency resolution fails because `vendor/nanoregex` does not exist; if that is separately included but `src/mcp_json.zig` is omitted, compilation fails on the missing import.

**Action:** Ensure all required vendored sources and `src/mcp_json.zig` are explicitly added to the migration commit. Decide whether `wasm/codedb.wasm` is a committed release artifact or a generated output; do not accidentally commit it without a reproducible artifact policy.

---

### P2 — Search cache invalidation was narrowed from 64 to 32 bits and can serve stale results after wraparound

**Locations:** `src/explore.zig:1355`, `src/explore.zig:2035-2037`, cache reads at `src/explore.zig:3412`, `3863`, `4977`

`search_gen` changed from `std.atomic.Value(u64)` to `std.atomic.Value(u32)`. `bumpSearchGen` uses wrapping `fetchAdd`, and cached entries use this generation to decide whether they remain valid.

**Failure sequence:**

1. A cached query is stored at generation `G`.
2. Files are reindexed, added, or removed exactly `2^32` times over the lifetime of a long-running daemon.
3. `search_gen` wraps back to `G`.
4. The old cache entry’s generation once again matches the current generation.
5. The daemon can return results predating all intervening mutations.

This is reachable through sustained watcher churn or automated repeated indexing; narrowing the counter creates a correctness regression without an apparent Zig 0.17 requirement.

**Action:** Retain a 64-bit generation on native targets. If WASM atomics forced the change, use a target-specific representation or clear the result caches on wraparound.

---

### P2 — The pinned Zig compiler is downloaded without integrity verification in privileged release jobs

**Locations:** `.github/workflows/release-binaries.yml:56-62`, `.github/workflows/bench-regression.yml:18-22`

The version and filename are pinned, but the workflows execute a downloaded archive without checking a cryptographic digest or signature. The release workflow has `contents: write` and subsequently uploads binaries to GitHub Releases.

**Failure sequence:**

1. The download endpoint, DNS/TLS path, or upstream build artifact is compromised or replaced.
2. `curl -L` accepts the replacement archive.
3. `tar` extracts it and the workflow executes its `zig` binary.
4. The attacker runs code under the release token and can emit backdoored release binaries or alter release assets.

The versioned filename helps repeatability but does not establish artifact identity.

**Action:** Pin and verify the official SHA-256 digest for every host archive before extraction. Prefer `curl --fail --show-error --location`, and fail closed on checksum mismatch.

## Verification gaps

- `zig version` reported the intended `0.17.0-dev.813+2153f8143`.
- `zig build test` completed successfully in the current dirty working tree.
- Native cross-builds for `x86_64-linux` and `aarch64-linux` with `ReleaseFast` completed successfully.
- `git diff --check` found no whitespace errors.
- macOS native builds, macOS signing order, Windows compilation/runtime, and the GitHub Actions release matrix were not executed.
- The new WASM build graph was not independently validated in this review beyond observing an existing untracked `wasm/codedb.wasm`; browser/Worker runtime behavior and exported ABI remain unverified.
- Dependency reproducibility was only validated while the untracked vendored directory was present. A clean-checkout build was not possible without first deciding which untracked files belong in the commit.
- The vendored `nanoregex` tree has no manifest-level provenance tying it to the previously pinned commit `736b46703454d5f37d3e46164fc91354386bb29c`. Its source equivalence and license completeness were not established.
- The workflow URLs were not fetched to confirm that all four Zig archives currently exist under the selected `/builds/` naming scheme.

## Preservation assessment

There is no Git state from which to reconstruct uncommitted edits that existed before this migration, so preservation cannot be proven from the current repository alone.

What is visible is consistent with preservation rather than wholesale replacement:

- `src/index.zig` retains substantial non-migration persistence and posting-order changes, including the `getOrAddPosting` fix and streamed trigram lookup/postings work.
- `src/test_index.zig` gains roughly 141 lines of substantive tests rather than being reduced or regenerated.
- The apparent deletions in `src/test_explore.zig`, `src/test_parser.zig`, and `src/test_query.zig` are blank-line removals, not deleted tests.
- There are no staged changes, backup files, or reflog-visible worktree snapshots that can prove the exact pre-migration contents.

A definitive preservation check requires the pre-migration patch, stash, editor local history, or a saved working-tree snapshot.

## Verdict

**Most dangerous defect: required migration sources and the vendored dependency are untracked, allowing an apparently complete commit to fail immediately in every clean checkout.**
