# subagent sa-018-d8cfbb94

- label: Review release workflow prep
- kind: subagent
- status: ok
- elapsed_ms: 39102
- tools: codedb,bash,bash,read_file,bash,bash,bash,read_file,read_file,bash,bash,bash_output

## task

Review current uncommitted release prep including .github/workflows/release-binaries.yml, version files, changelog/docs/release notes, PR guard. Verify Windows cross-build artifact path, matrix/publish/checksums, version sync, factual claims, and release process readiness. Local Windows cross-build produced zig-out/bin/codedb.exe. Do not edit. Report blockers or ready.

## report

**BLOCKER — release evidence is untracked.** `docs/release-notes-0.2.5830.md:26` links to release documentation, but both that file and `docs/bench-0.2.5830-paired-report.md` are untracked. A tag from the committed tree would omit the release notes/report and break the factual evidence chain. Add both files to the release commit before tagging; exclude unrelated untracked `.graff/`, `.harness/`, caches, traces, and `wasm/` unless intentionally shipped.

Otherwise verified:

- `.github/workflows/release-binaries.yml:114-117` correctly resolves the observed Windows output `zig-out/bin/codedb.exe`.
- Matrix contains five unique assets: macOS/Linux x86_64+arm64 and Windows x86_64.
- Publish waits for every matrix build, gathers all assets, creates sorted SHA-256 checksums, and uploads to the existing tagged release.
- Versions agree at `0.2.5830` in `build.zig.zon`, `npm/package.json`, and `src/release_info.zig`.
- Changelog date/tag references and benchmark commit provenance are consistent.
- The claimed GitHub paired benchmark run for candidate `33ea66c` succeeded.
- PR guard no longer hard-codes a stale release branch.
- Workflow YAML parses, `git diff --check` passes, and `zig build test` passes.

Not ready until the two release documents are tracked and release-only files are committed before creating `v0.2.5830`.

⟦ELITE-LIVE-ON-PROD⟧
