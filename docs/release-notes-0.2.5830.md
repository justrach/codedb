# codedb 0.2.5830

codedb 0.2.5830 accelerates steady-state MCP and core read-only tools while preserving retrieval and client-visible response behavior.

## Highlights

- Generation-validated caches speed repeated tree, outline, exact-word, and fuzzy-file requests.
- Exact symbol lookup uses the existing symbol hash index directly.
- Cached content hashes and newline offsets accelerate repeated and deep reads.
- Context symbol bodies use offset-based extraction with the disk fallback retained.
- Rolling trigram construction reduces repeated byte loads and normalization.
- Compact JSON-RPC payloads use a fast copy path while CR/LF sanitization remains in place.
- Cache reads are synchronized with watcher mutations, and cache identity uses entry generations rather than allocator addresses.

No ranking formula, result cap, parser behavior, path-security policy, telemetry behavior, or MCP response schema changes in this release.

## Performance and parity

The final release gate uses 20 counterbalanced AB/BA pairs against production baseline `v0.2.5829`, with a pinned harness-only backport, the same fixed 21-file benchmark corpus, and pinned Zig `0.17.0-dev.813+2153f8143` for both binaries.

- shared corpus fingerprint: **PASS**
- auditable source/compiler/order provenance: **PASS**
- duration-normalized full JSON-RPC response parity across every measured iteration: **PASS** for every parity-enabled tool
- paired regression gate (>10% and >50us): **PASS**

The largest in-process paired-median improvements are exact symbol **81.63%**, tree **66.03%**, outline **60.39%**, word **37.54%**, bundle **25.26%**, and hot-file lookup **19.18%**. Full methodology, transport-level measurements, limitations, and the persisted paired report are in [`docs/performance-0.2.5830.md`](https://github.com/justrach/codedb/blob/v0.2.5830/docs/performance-0.2.5830.md).

## Verification

- `zig build test`
- native `ReleaseFast` build
- Windows x86_64 cross-build
- WASM build
- MCP E2E: 20/20 scenarios
- paired comparator unit tests
- 20-pair local release gate
- GitHub paired benchmark workflow
- `git diff --check`

## Release assets

The release workflow publishes binaries for:

- macOS arm64
- macOS x86_64
- Linux arm64
- Linux x86_64
- Windows x86_64

Verify downloads with the attached `checksums.sha256`.
