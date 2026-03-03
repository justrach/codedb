# Changelog

All notable changes to CodeDB are documented here.

## [0.0.22] — 2026-03-03

### Added
- `review_fix_loop` tool — iterative review → fix → re-review cycle using Codex subagents. Runs a read-only reviewer to find issues, a writable fixer to patch them, then re-reviews until clean or `max_iterations` reached (default 3, cap 5). Returns JSON with per-iteration history and convergence status.

### Fixed
- `handleReviewFixLoop` uses atomic JSON output via deferred flush — early exits no longer leave `out` empty
- `total_iterations` tracked explicitly instead of derived from loop variable (off-by-one on full exhaustion)
- `swarm.buildPreamble` made public so `review_fix_loop` reuses the writable tool preamble

### Changed
- 33 MCP tools total (up from 30)

## [0.0.21] — 2026-03-02

### Added
- Release pipeline for npm and Homebrew distribution (#169)
- GitHub Actions CI to run tests on every PR (#168)
- `streamTurn` ContextWindowExceeded unit tests (#164)
- Idiomatic unit coverage for protocol boundaries (#163)

### Fixed
- Auto-compact on ContextWindowExceeded + fix sandboxPolicy type (#162)
- Remove redundant npm version step (#173)

### Changed
- Binary renamed to `devswarm` end-to-end (#172)
- Restored missing `steps:` key in build job of release.yml (#171)
- Use macos-latest for aarch64-macos builds (#170)

## [0.0.2] — 2026-03-01

### Added
- `run_swarm` — parallel agent swarm via Zig threads (up to 100 agents). Orchestrator → N workers → synthesis pipeline.
- `run_reviewer`, `run_explorer`, `run_zig_infra` — Codex subagent tools invoked as MCP tool calls
- `set_repo` — runtime repository switching without server restart
- `get_issue` — fetch any issue by number including closed ones
- Codex app-server JSON-RPC 2.0 protocol with streaming `item/agentMessage/delta` output
- Writable tool-use preamble injected into swarm worker prompts (#132)
- Thread-based repo/session API for parallel gitagent users (#139)
- Transport reconnect + session tests (#138)
- Off-the-shelf install docs (#160)

### Fixed
- PATH injection for codex app-server child env (#134)
- SIGABRT on `create_branch` + invalid free in slugify (#137)
- Numeric/time robustness gaps — underflow on clock skew, unchecked integer narrowing (#124)
- Misclassified backend outcomes in search.zig and tools.zig (#123)
- Milestone cache never populated (#122, #107)
- Hardcoded socket path in harness.zig reconnect logic (#121)
- Non-transactional reingest and symbol-id leaks in ingest.zig (#120)
- Per-instance CRC state in WalWriter — shared global causes checksum corruption (#118)
- JSON-RPC error response contract — swallowed write failures and null id coercion (#117)
- Subprocess stream lifecycle in gh.run — deadlock and OOM leak paths (#116)
- Enum reconstruction from bytes in WAL/storage parsing (#115)
- Replace DEFAULT_REPO hardcode with dynamic repo from set_repo/cwd (#114)
- Spurious backslash-escapes in `tools_list` multiline strings

### Changed
- 30 MCP tools total (up from 21)
- MCP mode starts directly; repo auto-detection uses `git rev-parse` when `REPO_PATH` is unset

## [0.0.1] — 2026-02-28

### Added
- Initial release: 21 MCP tools for GitHub workflow management
- Code graph engine with Personalized PageRank ranking
- Multi-language symbol extraction (TypeScript, JavaScript, Python, Java, Go, Rust, Zig)
- Blast radius analysis — find all code affected by a change
- Dependency-aware issue prioritization via graph topology
- Write-ahead log for crash recovery and deterministic replay
- Binary storage format with CRC32 checksums and versioning
- Session caching for zero-latency GitHub label/milestone lookups
