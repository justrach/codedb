# codedb 0.2.5830

codedb 0.2.5830 is a performance and correctness release for steady-state MCP and core read-only tools. It makes common code-intelligence operations substantially faster while preserving retrieval results, ordering, ranking, security policy, telemetry behavior, and client-visible MCP responses.

**Release:** <https://github.com/justrach/codedb/releases/tag/v0.2.5830>

## What changed in 0.2.5830

### Faster indexed retrieval

- **Exact symbol lookup now uses the existing symbol hash index directly.** Exact-name requests no longer scan the broader symbol path. Prefix, pattern, fuzzy, kind-only, incomplete-index fallback, result-cap, and deterministic-ordering behavior remain unchanged.
- **Tree, outline, exact-word, and fuzzy-file results use bounded, generation-validated caches.** Mutations advance the Explorer generation before changed or removed content can be served. Tree entries are capped at 16 MiB; outline and word rendering use 32-entry, 16 MiB LRUs with a 4 MiB per-entry ceiling; fuzzy scoring keeps at most 32 query/limit entries.
- **Repeated and deep reads reuse cached content hashes and newline offsets.** After the first offset-table build, ranged extraction scales with the requested range instead of every byte before it.
- **Context symbol bodies use zero-copy, offset-based extraction** when content is resident, with the previous disk fallback retained.
- **Generic and incremental indexing use rolling trigram construction.** Each incoming byte is loaded and normalized once while preserving case folding, whitespace suppression, location masks, following-character masks, and final-boundary behavior.
- **Compact JSON-RPC responses use a one-slice copy fast path.** Any payload containing raw CR/LF bytes still takes the original sanitizing fallback, preserving one-response-per-line MCP framing.

### Cache correctness and concurrency

- Cache reads are synchronized with watcher mutation paths.
- Content-cache identity uses non-reused entry generations rather than allocator addresses.
- Cached fuzzy results are copied before request-specific boosts, so callers cannot mutate shared scores.
- Add, replace, remove, reparse, and generation-change tests verify that stale content and rendered output cannot be reused.

No ranking formula, result cap, parser behavior, path-security policy, sensitive-file filtering, telemetry behavior, or MCP response schema changed in this release.

## Zig 0.16.0 → pinned Zig 0.17

The release line moved from Zig 0.16.0 to the exact tested snapshot `0.17.0-dev.813+2153f8143` in 0.2.5829, immediately before this performance release. codedb 0.2.5830 inherits and validates that migration across native, Windows, and freestanding/WASM targets.

The migration includes:

- a pinned compiler/package minimum and release jobs that verify the compiler version;
- Zig 0.17 build-graph passthrough and lazy-path APIs;
- migration from removed repetition, sentinel-formatting, writer, I/O, and allocator APIs;
- target-appropriate atomics and host-operation guards for Windows and WASM;
- borrowed process-lifetime argv instead of another command-parser copy;
- a vendored, licensed Zig-0.17-compatible `nanoregex` dependency;
- internal protocol-neutral JSON helpers replacing an otherwise incompatible server-framework dependency.

The migration line initially measured **1.20× faster cold CLI search**, **1.14× faster warm snapshot-backed CLI search**, and a **3.217× exact-word geometric-mean speedup** against the Zig 0.16 build. The final 0.2.5830 generic initial-index comparison then measured **136.0 ms → 131.0 ms**, a **3.7% improvement**, with 20/20 paired wins and identical hit counts across all 14 query rows.

The detailed migration inventory and reusable upgrade guide are in [`docs/zig-0.17-migration.md`](https://github.com/justrach/codedb/blob/main/docs/zig-0.17-migration.md).

## Measured performance

### Final release gate: 20 real paired runs

The final source-attribution gate used:

- production baseline `v0.2.5829` (`dd36e94`), plus pinned harness-only parity backport `24e89c7`;
- executable candidate `bc72bfc`;
- the same fixed 21-file corpus copied from the immutable baseline;
- pinned Zig `0.17.0-dev.813+2153f8143` for both binaries;
- 20 counterbalanced AB/BA pairs.

Every sample passed commit/tree, clean-worktree, compiler, corpus, pair, order, and sequence provenance checks. Every parity-enabled tool matched across every measured iteration after normalizing only response duration. No parity-enabled tool crossed the paired regression threshold of more than 10% and more than 50 µs.

Largest in-process paired-median latency reductions:

| Operation | Improvement |
|---|---:|
| Exact symbol | **81.72%** |
| Tree | **67.60%** |
| Outline | **59.79%** |
| Exact word | **37.16%** |
| Bundle | **27.73%** |
| Hot-file lookup | **17.81%** |
| Context | **11.89%** |
| Read | **4.81%** |
| Find | **3.27%** |
| Edit | **2.04%** |

### End-to-end MCP round trips

A separate immutable-corpus transport benchmark—including JSON-RPC serialization, stdio transport, parsing, dispatch, envelope generation, escaping, response writing, and client receipt—measured **2.16× to 99.11×** speedups across tree, outline, symbol, read, find, word, search, and bundle workloads. Normalized responses were byte-identical.

| MCP operation | Baseline | 0.2.5830 candidate | Speedup |
|---|---:|---:|---:|
| Tree | 343.8 µs | 40.1 µs | **8.56×** |
| Outline | 995.0 µs | 148.9 µs | **6.68×** |
| Symbol | 229.4 µs | 20.9 µs | **10.96×** |
| Read | 189.3 µs | 53.9 µs | **3.51×** |
| Find | 5.52 ms | 409.2 µs | **13.50×** |
| Word | 13.83 ms | 215.0 µs | **64.32×** |
| Search | 72.1 µs | 33.4 µs | **2.16×** |
| Bundle | 13.36 ms | 134.7 µs | **99.11×** |

Large synthetic edge cases improved **12.8×–109.7×** for huge outlines, deep reads, large trees, fuzzy-file lookup, and exact-word output; exact symbol lookup improved **22.4×**.

These are workload-specific measurements. The largest cache-backed gains are steady-state gains; first calls still construct cached representations. Full methodology, limits, raw evidence, and per-tool results:

- [`docs/performance-0.2.5830.md`](https://github.com/justrach/codedb/blob/v0.2.5830/docs/performance-0.2.5830.md)
- [`docs/bench-0.2.5830-paired-report.md`](https://github.com/justrach/codedb/blob/v0.2.5830/docs/bench-0.2.5830-paired-report.md)
- attached `bench-0.2.5830-paired-samples.tar.gz`, SHA-256 `104edc6875a9d121d2e5a4c1e69c12735f2c60128e48ae384aa8c6cfb950bc24`

## Token and deployment efficiency snapshot

At release time, the Codegraff dashboard reported:

- **19.7 billion tokens saved over the previous 30 days**;
- **580,000 codedb operations over the previous 7 days**;
- **63 µs p50 per codedb operation**;
- approximately **47 tokens per outline** and **14 tokens per lookup**.

These are aggregate deployment/dashboard counters from activated installs, not a causal A/B measurement of 0.2.5830. They describe codedb's broader context-efficiency footprint; the version-specific performance claims above come from the immutable paired benchmarks.

## Benchmark-gate hardening

The release also makes future performance claims harder to get wrong:

- baseline and candidate run from clean throwaway worktrees;
- the runner binds evidence to expected source commit and tree identities;
- both sides receive the same fixed corpus copied from the baseline;
- corpus fingerprints and compiler executable identities are recorded per sample;
- AB/BA order, side, pair number, and sequence are validated;
- full normalized JSON-RPC responses are hashed across every measured iteration;
- parity exemptions require both case metadata and an explicit comparator allowlist;
- duplicate tool records, missing pairs, dirty worktrees, and mismatched provenance fail closed;
- regressions use paired medians and deterministic bootstrap intervals rather than single-run minima.

## Verification

- `zig build test`
- native `ReleaseFast` build
- Windows x86_64 `ReleaseFast` cross-build
- WASM build
- MCP E2E: **20/20 scenarios passed**
- paired comparator tests: **12/12 passed**
- final local release gate: **20/20 pairs passed**
- GitHub paired benchmark workflow: **passed**
- `git diff --check`

## Release assets

Published binaries:

- macOS arm64
- macOS x86_64
- Linux arm64
- Linux x86_64
- Windows x86_64

The shipped macOS arm64 binary is signed with hardened runtime and a secure timestamp. Apple notary service returned **Accepted**, and Gatekeeper reports `source=Notarized Developer ID` for the exact shipped binary.

- arm64 notarization submission: `de536fc8-44ae-41dc-9826-b1f7847dcfe2`

The x86_64 macOS binary is intentionally unsigned because post-link signing reproduces the Rosetta startup crash tracked in #504. The exact shipped unsigned binary was executed successfully under Rosetta as `codedb 0.2.5830`. A signed x86_64 candidate was notarized but failed that runtime check and was not shipped.

Install or update:

```bash
curl -fsSL https://codedb.codegraff.com/install.sh | bash
```

Or through npm:

```bash
npx -y codedeebee mcp
```

## SHA-256

```text
2b786d7404cf8ea79857dcd3a067d35493e67d3eb523ea1eb5810103dec048cd  codedb-darwin-arm64
514424656a3c632315c90d08ea00349ba879327d70d0e997c435136a74129fbd  codedb-linux-x86_64
abca6aceb29c8665c3ac18071b6e0260ebe8419de2d5aa0c1473f07e6284cf42  codedb-linux-arm64
efbff83e4482cd441dc3ef89871603e836f7e5d700381815e616803ed7b4a79a  codedb-darwin-x86_64
fbb106ca1cc084cb514994a937d1508f3a9785e0f44964fd5af9f09bf94f662e  codedb-windows-x86_64.exe
```

Verify downloads with the attached `checksums.sha256`.
