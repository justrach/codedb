# LinkedIn launch copy — codedb 0.2.5830

## Primary post

codedb 0.2.5830 is live: a performance and correctness release for the code-intelligence layer used by AI agents.

The goal was straightforward to state and difficult to prove: make common retrieval operations substantially faster without changing what agents receive.

The final release gate ran 20 real, counterbalanced AB/BA pairs against an immutable, parity-capable 0.2.5829 baseline. Both sides used the same pinned Zig compiler and the same fixed corpus. The runner verified source commit and tree, clean worktrees, compiler identity, corpus fingerprint, pair order, and sequence.

Most importantly, every parity-enabled tool produced the same full normalized JSON-RPC response across every measured iteration.

The largest reductions in paired-median in-process latency were:

• Exact symbol lookup: **81.72%**
• Tree: **67.60%**
• Outline: **59.79%**
• Exact-word lookup: **37.16%**
• Bundle: **27.73%**
• Hot-file lookup: **17.81%**
• Context: **11.89%**

A separate end-to-end MCP benchmark—including request serialization, stdio transport, JSON-RPC parsing, dispatch, response generation, escaping, and client receipt—measured speedups from **2.16× to 99.11×** across the tested workloads. Normalized responses were byte-identical. Large synthetic handler cases improved between **12.8× and 109.7×**.

What changed under the hood?

• Exact-name symbol requests now use the existing hash index directly.
• Tree, outline, exact-word, and fuzzy-file paths use bounded, generation-validated caches.
• Repeated and deep reads reuse cached content hashes and newline offsets.
• Context bodies use offset-based extraction when content is resident.
• Generic and incremental indexing use rolling trigram construction.
• Compact MCP responses use a fast copy path while retaining CR/LF sanitization.
• Cache identity and watcher synchronization were hardened so stale content cannot survive mutation.

This release line also carries codedb's migration from Zig 0.16.0 to the exact tested `0.17.0-dev.813+2153f8143` snapshot. That work covered the build graph, I/O and writer APIs, target-specific atomics, Windows, freestanding/WASM, dependency reproducibility, and release automation. In the final 0.2.5830 initial-index comparison, the Zig 0.17 build improved from 136 ms to 131 ms versus the Zig 0.16 anchor: **3.7% faster, with 20/20 paired wins and identical hit counts**.

The broader context-efficiency snapshot matters too. At release time, the Codegraff dashboard reported:

• **19.7 billion tokens saved** over 30 days
• **580,000 codedb operations** over 7 days
• **63 microseconds p50** per operation
• roughly **47 tokens per outline** and **14 per lookup**

Those are aggregate deployment counters from activated installs—not a causal A/B claim for this version. The release-specific claims come from the immutable paired benchmarks and published raw evidence.

0.2.5830 ships binaries for macOS arm64 and x86_64, Linux arm64 and x86_64, and Windows x86_64. The macOS arm64 binary is Developer ID signed, Apple-notarized, and Gatekeeper accepted. Every published asset was downloaded again and checksum-verified before the release went live.

codedb is a context engine, not an editor. It helps agents find and understand code—search, symbols, callers, dependencies, outlines, and compact context—then hands editing back to native tools.

Release, checksums, methodology, and raw benchmark evidence:
https://github.com/justrach/codedb/releases/tag/v0.2.5830

Install:
`curl -fsSL https://codedb.codegraff.com/install.sh | bash`

#Zig #MCP #AIEngineering #DeveloperTools #CodeIntelligence

## Suggested image alt text

Dark Codegraff dashboard showing engineering teams using Codegraff and four codedb metrics: 19.7 billion tokens saved in the last 30 days, 580,000 operations in the last 7 days, 63 microseconds per operation at p50, and about 47 tokens per outline versus 14 per lookup.

## Short version

codedb 0.2.5830 is live.

The final immutable 20-pair gate measured **81.72% lower exact-symbol latency, 67.60% lower tree latency, 59.79% lower outline latency, and 37.16% lower exact-word latency**, with full normalized MCP-response parity across every measured iteration.

The release adds direct hash-index symbol lookup, bounded generation-validated caches, cached hashes and line offsets, zero-copy context extraction, rolling trigrams, and a compact JSON-RPC fast path. It also ships on pinned Zig 0.17, with the final initial-index comparison **3.7% faster** than the Zig 0.16 anchor.

At release time, activated installs reported 19.7B tokens saved over 30 days and 580K operations over 7 days. That is a deployment snapshot; the version-specific claims come from the published paired evidence.

Five platform targets are available now:
https://github.com/justrach/codedb/releases/tag/v0.2.5830
