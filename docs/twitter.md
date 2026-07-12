# Twitter/X launch copy — codedb 0.2.5830

Release: <https://github.com/justrach/codedb/releases/tag/v0.2.5830>

## Primary thread

### 1/9

> 1/9 codedb 0.2.5830 is live.
>
> Faster code intelligence for AI agents, with retrieval and full MCP-response parity preserved.
>
> Exact symbol: 81.72% lower latency
> Tree: 67.60%
> Outline: 59.79%
>
> https://github.com/justrach/codedb/releases/tag/v0.2.5830

### 2/9

> 2/9 The final gate was 20 real, counterbalanced AB/BA pairs against an immutable 0.2.5829 baseline.
>
> Same compiler. Same fixed corpus. Source/tree/order provenance verified. Full normalized JSON-RPC responses matched across every measured iteration.

### 3/9

> 3/9 The biggest paired-median latency reductions:
>
> • symbol 81.72%
> • tree 67.60%
> • outline 59.79%
> • word 37.16%
> • bundle 27.73%
> • hot lookup 17.81%
> • context 11.89%
>
> No parity-enabled tool had a material regression.

### 4/9

> 4/9 Under the hood: direct hash-index symbol lookup, bounded generation-validated render/score caches, cached hashes + newline offsets, zero-copy context bodies, rolling trigrams, and a compact JSON-RPC fast path with CR/LF sanitization retained.

### 5/9

> 5/9 A separate end-to-end MCP benchmark—including JSON-RPC, stdio, dispatch, escaping, and client receipt—measured 2.16× to 99.11× speedups.
>
> Normalized responses were byte-identical. Large synthetic handler cases improved 12.8×–109.7×.

### 6/9

> 6/9 This release line also completes the move from Zig 0.16.0 to pinned Zig 0.17.0-dev.
>
> The final initial-index comparison: 136ms → 131ms, 3.7% faster, 20/20 paired wins, with identical hit counts across all 14 query rows.

### 7/9

> 7/9 The context-efficiency snapshot is just as important:
>
> • 19.7B tokens saved / 30 days
> • 580K codedb ops / 7 days
> • 63µs p50 per op
> • ~47 tokens per outline
> • ~14 per lookup
>
> Aggregate deployment counters—not a version-specific A/B claim.

### 8/9

> 8/9 Shipping for macOS arm64/x86_64, Linux arm64/x86_64, and Windows x86_64.
>
> macOS arm64 is Developer ID signed, Apple-notarized, and Gatekeeper accepted. Every published asset was downloaded again and checksum-verified before release.

### 9/9

> 9/9 codedb gives AI agents structural search, symbols, callers, dependencies, outlines, and compact context—then hands edits to native tools.
>
> Install:
> curl -fsSL https://codedb.codegraff.com/install.sh | bash
>
> https://github.com/justrach/codedb/releases/tag/v0.2.5830

## Single-post version

> codedb 0.2.5830 is live: exact symbol 81.72%, tree 67.60%, outline 59.79%, word 37.16%, and bundle 27.73% lower paired-median latency—with full MCP-response parity. Built on pinned Zig 0.17. Five platforms. https://github.com/justrach/codedb/releases/tag/v0.2.5830

## Shorter single-post version

> codedb 0.2.5830 is live. Up to 81.72% lower paired-median latency in the final 20-pair gate, full MCP-response parity, pinned Zig 0.17, and binaries for five OS/architecture targets. https://github.com/justrach/codedb/releases/tag/v0.2.5830

## Suggested media alt text

> Dark Codegraff dashboard showing engineering teams using Codegraff and four codedb metrics: 19.7 billion tokens saved in the last 30 days, 580,000 operations in the last 7 days, 63 microseconds per operation at p50, and about 47 tokens per outline versus 14 per lookup.

## Posting notes

- Attach the dashboard image to post 7, or to post 1 if the thread needs a stronger visual opener.
- Keep the release URL unshortened so readers can inspect the binaries, checksums, benchmark report, and raw evidence.
- Optional tags on the final post: `#Zig #MCP #AIEngineering #DeveloperTools`.
- The 19.7B/580K/63µs figures are a release-day deployment snapshot. Do not present them as improvements caused solely by 0.2.5830.
