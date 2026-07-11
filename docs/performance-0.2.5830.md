# 0.2.5830 performance work

This document records the first performance batch queued for the 0.2.5830
release branch. More experiments may be added before the release is finalized.

## Scope

The pass targets steady-state daemon and MCP usage while retaining correctness on
cold and incremental paths. It includes:

- rolling trigram construction for generic and incremental indexing;
- direct hash-index lookup for exact symbol names;
- generation-validated rendered-output caches for trees, outlines, and exact
  word postings;
- a generation-validated fuzzy-file score cache;
- cached file hashes and newline offsets for repeated/deep reads;
- zero-copy, offset-based symbol-body extraction in `codedb_context`;
- a compact JSON-RPC payload fast path that retains CR/LF sanitization.

No ranking formula, result cap, path policy, parser behavior, telemetry behavior,
or MCP response schema changes in this batch.

## Benchmark methodology

### MCP round trips

The client-visible MCP measurements used:

- baseline source: `dd36e94` (`v0.2.5829` release branch head);
- candidate source: the performance changes documented here;
- compiler: pinned Zig `0.17.0-dev.813+2153f8143` for both binaries;
- build mode: native `ReleaseFast`;
- corpus: immutable git archive, 730 files on disk / 633 indexed files;
- process protocol: newline-delimited JSON-RPC over MCP stdio;
- sampling: three counterbalanced baseline/candidate process pairs;
- per process/tool: five warmups and 50 measured calls;
- statistic: median across the three per-process medians.

The benchmark includes request serialization, stdin/stdout transport, JSON-RPC
parsing, tool dispatch, MCP content-envelope generation, JSON escaping, response
writing, and client receipt. It therefore complements `zig build bench`, whose
latency field measures in-process dispatch only.

| MCP tool | Baseline | Candidate | Speedup |
|---|---:|---:|---:|
| `codedb_tree` | 343.8 us | 40.1 us | **8.56x** |
| `codedb_outline` | 995.0 us | 148.9 us | **6.68x** |
| `codedb_symbol` | 229.4 us | 20.9 us | **10.96x** |
| `codedb_read` | 189.3 us | 53.9 us | **3.51x** |
| `codedb_find` | 5.52 ms | 409.2 us | **13.50x** |
| `codedb_word` | 13.83 ms | 215.0 us | **64.32x** |
| `codedb_search` | 72.1 us | 33.4 us | **2.16x** |
| `codedb_bundle` | 13.36 ms | 134.7 us | **99.11x** |

Normalized MCP responses were byte-identical between baseline and candidate for
`tree`, `outline`, `symbol`, `read`, `find`, `word`, `search`, `context`, and
`bundle`.

### Core edge cases

`zig build bench-edge -- --json` used a generated 3,005-file corpus to expose
algorithmic and output-size scaling behavior.

| Handler case | Baseline | Candidate | Speedup |
|---|---:|---:|---:|
| exact symbol | 42.9 us | 1.92 us | **22.4x** |
| huge outline | 187.4 us | 14.6 us | **12.8x** |
| deep ranged read | 306.7 us | 14.9 us | **20.6x** |
| 3,005-file tree | 760.3 us | 6.93 us | **109.7x** |
| fuzzy file find | 2.19 ms | 46.9 us | **46.6x** |
| large exact-word output | 572.7 us | 29.5 us | **19.4x** |

### Indexing versus Zig 0.16

The generic initial-index benchmark was also compared directly with commit
`428d8df` built by Zig 0.16.0. Both binaries used the same immutable corpus,
c allocator, two workers, and 20 counterbalanced pairs.

- Zig 0.16 median: 136.0 ms
- current Zig 0.17 median: 131.0 ms
- release-outcome improvement: **3.7%**
- paired wins: **20/20**
- paired median saved: 5.0 ms
- paired-mean bootstrap 95% interval: 4.6-8.2 ms saved

All 14 benchmark query rows retained identical hit counts.

## Implementation details

### Exact symbols

The common `{ "name": "..." }` symbol request now reads the existing symbol hash
index directly. Prefix, pattern, fuzzy, kind-only, incomplete-index fallback,
max-result, and deterministic ordering behavior remain on their prior paths.

### Render caches

Tree, outline, exact-word, and fuzzy-file results are keyed by the Explorer
mutation generation. Mutations make old entries ineligible before newly indexed
or removed content can be served.

Memory is bounded:

- tree entries are capped at 16 MiB each, with separate plain/color slots;
- outline and word-render caches use 32-entry, 16 MiB LRUs with a 4 MiB
  per-entry ceiling;
- fuzzy-file scoring keeps at most 32 query/limit entries.

Fuzzy paths borrow stable outline keys only while their generation is current.
Callers receive a copied match array, so combo boosts cannot mutate cached scores.

### Reads and context bodies

Cached file hashes avoid hashing a whole file on every ranged read. Hash entries
validate the canonical content pointer and length and are explicitly invalidated
on update/removal, guarding against allocator-address reuse.

Deep ranges reuse newline-offset tables, making extraction proportional to the
requested range after the first table build rather than proportional to every
byte before the range. The context composer uses the same path for symbol bodies
and retains its disk fallback when content is not resident.

### MCP framing

Compact generated JSON-RPC payloads normally contain no raw CR/LF bytes. The MCP
writer now proves that with the standard library's vectorized search and copies
the payload in one slice. A non-canonical payload still uses the original
sanitizing fallback, preserving one-response-per-line framing.

## Correctness and security checks

The new tests cover:

- exact scalar-versus-rolling trigram masks, including short, whitespace-only,
  mixed-case, final-position, null, and `0xff` bytes;
- tree, outline, word, fuzzy-find, content-hash, and line-offset cache hits;
- mutation invalidation after additions, replacements, and removals;
- deep range boundaries and content replacement;
- output parity across baseline and candidate MCP responses.

Validation completed for this batch:

```text
zig fmt --check <modified Zig files>
zig build test
zig build -Doptimize=ReleaseFast
python3 scripts/e2e_mcp_test.py --binary zig-out/bin/codedb --project <repo>
zig build wasm
git diff --check
```

MCP E2E passed 20/20 scenarios, including roots negotiation, explicit-root,
no-roots, and direct-inline-argument modes.

## Required protocol for follow-up performance changes

Further optimization commits on this branch use the automated paired gate:

```bash
CODEDB_BENCH_PAIRS=10 CODEDB_BENCH_OUT=zig-out/bench-ab \
  scripts/bench-ab.sh <base-ref>
```

For release claims, use at least 20 pairs. The runner:

1. builds the base ref in a throwaway worktree;
2. gives base and head the exact same base-worktree corpus;
3. verifies the corpus fingerprint for every pair;
4. alternates `base -> head` and `head -> base` order;
5. requires raw response-hash parity for parity-enabled tools;
6. reports paired medians, head win counts, and a deterministic bootstrap 95%
   interval;
7. rejects regressions from the paired median rather than a single-run minimum.

Raw samples and the Markdown report remain in `CODEDB_BENCH_OUT` when it is set.
Cross-compiler release-outcome comparisons remain separate from same-compiler
source-attribution runs.

## Limits and follow-up work

These numbers are workload-specific, and the largest cache-backed gains are
steady-state gains. First calls still construct the cached representation.
Exact-symbol lookup is an algorithmic improvement on both cold and warm paths.

Not every operation is 2-3x faster yet. Remaining targets for later commits on
this branch include:

- uncached ranked, regex, and high-candidate content search;
- edit/write/reparse/reindex latency;
- general context composition beyond deep body extraction;
- cold tree/outline construction;
- benchmark separation of handler-only, in-process MCP, and transport-level
  latency in CI.

Performance changes should continue to require output/hit parity and paired,
counterbalanced measurements rather than single-run minima.
