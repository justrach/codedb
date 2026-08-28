# OpenPuffer vendored engine

This directory contains only the pure-Zig in-process HNSW engine from
[justrach/openpuffer](https://github.com/justrach/openpuffer), plus its Zig
package files and MIT license.

- Upstream revision: `b76cbfdafbad152a460dc956ed7482140ddacc6c`
- Upstream library merge: [PR #16](https://github.com/justrach/openpuffer/pull/16)
- The codedb adapter's 512D search profile (`ef=48`, rerank x2) comes from the
  real-repository/synthetic recall gate merged in upstream
  [PR #24](https://github.com/justrach/openpuffer/pull/24) at
  `df5d3671d3783f8874620561a719195656e22936`.
- Finite/non-zero vector ingress validation is backported from upstream
  [PR #30](https://github.com/justrach/openpuffer/pull/30), merged at
  `5596b785faf0c4fcf3a77f999a1d6883789ae454`. The accompanying server-only
  Zig 0.17 fix is intentionally absent because codedb vendors no server code.
- POSIX HMLS persistence and macOS mmap coverage are synced through upstream
  [PR #31](https://github.com/justrach/openpuffer/pull/31), merged at
  `b76cbfdafbad152a460dc956ed7482140ddacc6c`. The 1536D-only traversal prefix
  remains disabled for codedb's 512D profile, as enforced by the upstream
  dimension guard and recall regression.
- Included from upstream: `src/lib.zig`, `src/hnsw.zig`, `src/vector.zig`, `src/rss.zig`,
  `build.zig.zon`, `LICENSE`, `README.md`
- Local adapter: `build.zig` exposes only upstream's `src/lib.zig` module and
  runs the included library/HNSW/vector tests; the omitted executable/server
  sources are not needed.
- Local hardening in `src/hnsw.zig`: portable POSIX slab I/O on macOS (instead
  of Linux-only syscalls), 0600 slab creation, checked offset/layout arithmetic,
  parent-directory fsync after atomic slab rename, and validation of entry
  points, graph degrees, and neighbor IDs before a persisted graph is attached
  or searched. Graph validation is capped at 128 MiB of faulted adjacency pages
  so a self-consistent sparse-file header cannot force unbounded query RSS;
  legacy heap-copy loaders are separately capped at 256 MiB and validate
  counts, levels, degrees, and neighbor IDs before exposing the graph.
- Excluded: HTTP server, server-side object persistence/S3, Gemini,
  turbopuffer client, benchmark harness, and research tooling

Refresh by reviewing the upstream diff from the revision above, reapplying or
dropping each documented local hardening patch deliberately, and retaining the
engine-only build adapter. Run `zig build test` inside this directory,
`zig build test-ann`, and the full codedb test suite afterward.
