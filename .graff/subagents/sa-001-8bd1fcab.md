# subagent sa-001-8bd1fcab

- label: Audit vendored dependency
- kind: workflow_task
- status: ok
- elapsed_ms: 66007
- tools: codedb,bash,codedb,codedb,codedb,bash,bash,bash,bash,bash,bash!,bash,bash,codedb,bash,bash,bash

## task

Audit vendor/nanoregex and root dependency wiring for reproducibility, licensing, package completeness, and Zig 0.17 compatibility. Also assess removal of mcp-zig and src/mcp_json.zig for behavioral/security regressions. Do not edit. Report actionable findings by severity.

## report

## Medium

### Vendored `nanoregex` is missing files required by its declared `parity` build step

- **Location:** `vendor/nanoregex/build.zig:126-131`
- **Missing path:** `vendor/nanoregex/tests/parity/fixtures/`
- **Failure sequence:**
  1. A developer or CI job runs `zig build parity --build-file vendor/nanoregex/build.zig`.
  2. The build invokes `tests/parity/run.sh` with `tests/parity/fixtures` as its third argument.
  3. The vendored tree contains the script but not the fixtures.
  4. The command exits with `fixtures dir not found` and the build fails.
- **Impact:** The vendored package is not a complete copy of the package it claims to provide. Its parity suite—the strongest compatibility check against Python regex behavior—cannot run from either the repository or a root package archive.
- **Evidence:** The previous cached `nanoregex` package contains 27 fixture files, while `vendor/nanoregex` contains none. Reproduction produced:
  ```text
  fixtures dir not found: ./vendor/nanoregex/tests/parity/fixtures
  parity transitive failure
  ```
- **Action:** Vendor the fixture directory, or remove/disable the `parity` step if parity testing is intentionally excluded. Add a clean-package test that invokes this step.

## Low

### The dependency migration can be accidentally committed without either new dependency source file

- **Locations:** `build.zig.zon:7-9`, `src/mcp.zig:9`, current repository index
- **Failure sequence:**
  1. The tracked modifications to `build.zig`, `build.zig.zon`, and `src/mcp.zig` are committed.
  2. `vendor/nanoregex/` and/or `src/mcp_json.zig` are omitted because both are currently untracked.
  3. A clean checkout runs `zig build`.
  4. The build fails because the local dependency path or imported helper file does not exist.
- **Impact:** This is an immediate clean-checkout/release failure rather than a runtime defect. The root package manifest does include both `src` and `vendor/nanoregex`, so packaging will be complete once the files are actually tracked; the current staging state is the risk.
- **Action:** Ensure both paths are included in the same commit and add a CI check that builds from `git archive` or a fresh checkout with empty Zig caches.

## Areas with no defensible defect found

- **Reproducibility:** Replacing the moving `mcp-zig` branch archive and remote `nanoregex` fetch with repository-local source removes network and mutable-branch dependence. CI and release workflows pin the full Zig build `0.17.0-dev.813+2153f8143`.
- **Licensing:** `vendor/nanoregex/LICENSE` contains the MIT license and is covered by the root manifest’s `vendor/nanoregex` package path.
- **Zig 0.17 compatibility:** `zig build test --summary all` succeeds under the declared compiler, with all 23 steps successful.
- **`mcp-zig` removal:** The locally copied `Root` layout is identical to the dependency’s type. The used `readLineBuf`, field accessors, equality helper, and JSON escaping behavior match the removed implementation. No used helper was omitted.
- **Behavior/security:** No new protocol or escaping regression was found from the dependency removal. The one-megabyte line limit and oversized-message connection termination are inherited behavior, not introduced by this change.

## Verdict

**The most dangerous defect is the incomplete `nanoregex` vendoring: its declared parity validation is deterministically broken because all fixtures are missing.**
