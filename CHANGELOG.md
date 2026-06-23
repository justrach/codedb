# Changelog


## 0.2.5826 - 2026-06-23

A correctness + **coverage** + agent-steering cut. It widens index coverage to
2 MB files (medium source/vendored/lockfile/data files were being silently
dropped), fixes editor MCP launches that pass an unexpanded `${workspaceFolder}`,
makes `index` a first-class command, and clears a cluster of issues surfaced by a
SWE-bench Lite token-efficiency benchmark and real session traces — on top of a
`main.zig` split into focused modules and a halved live-update read path.

### Index coverage widened to 2 MB — medium files are no longer dropped (#635)

- **`max_indexed_file_bytes` raised 512 KB → 2 MB.** Files between 512 KB and
  2 MB — generated code, vendored bundles, lockfiles, data fixtures — were
  silently dropped from the index entirely: invisible to `search`, `word`,
  `symbol`, and `find`, reachable only via `codedb_read`. They are now indexed
  (full trigram up to 1 MB; outline + word index up to 2 MB). Files over the
  2 MB cap are still skipped, but the skip is now logged rather than silent.
- **Empirically verified A/B, 10 isolated sandboxes.** Identical fixture repos
  (files at eight sizes, each carrying a unique sentinel token) were indexed by
  `0.2.5825` and `0.2.5826` in separate microVMs. Result was deterministic with
  zero variance:

  | file size | 0.2.5825 (prev) | 0.2.5826 |
  |-----------|-----------------|----------|
  | ≤ 400 KB | found 10/10 | found 10/10 |
  | 550 KB – 1.9 MB | **0/10** | **10/10** |

  i.e. every medium file that the previous release made unsearchable is found by
  this one. The fix reaches the cold CLI scan, not just the live watcher path.

### Editor `${workspaceFolder}` MCP launches resolve to the workspace (#639)

- **An unexpanded `${workspaceFolder}` no longer pins the index to a literal
  path.** Editors (Zed, opencode) spawn `codedb mcp ${workspaceFolder}`; when the
  client does not expand the variable, the literal string arrived as an *explicit*
  root and pinned the index to a directory named `${workspaceFolder}` — which
  silently disabled the #502 git-root walk-up, the deferred-scan handshake, and
  the `CODEDB_ROOT` fallback all at once, leaving the user with an empty index.
  The unexpanded placeholder now normalizes to cwd, non-explicit, so all three
  recovery paths fire. The mcp root-resolution gates were extracted into pure,
  unit-tested predicates so the parse and consume halves can no longer drift —
  the exact gap that hid this bug.

### `index` is a first-class command (#633)

- **`codedb index` / `codedb <root> index` are explicitly recognized.** The
  command existed but was not in the dispatcher's command set, so it fell through
  to the default path and read as unrecognized.

### `codedb_read` raw mode returns byte-exact ranged output (#632)

- **Raw ranged reads are no longer line-number-prefixed.** `mode=raw` with a line
  range returned decorated output instead of the exact bytes; raw now means raw.

### Live-update path reads each changed file once (perf)

- **The watcher hashed-then-indexed every edit — two full reads per change; now
  one.** `hashAndIndexFile` reads the changed file once and reuses the buffer for
  both the content hash and indexing, roughly halving file I/O on every save while
  `codedb mcp` is running — a gap that widened once the cap moved to 2 MB.

### Internal: `main.zig` split + help-flag predicate

- **`main.zig` (2345 lines) split into focused modules** — `background`,
  `bootstrap`, `cli_args`, `cli_proxy`, `commands`, `out`, `query` (≤ 600 lines
  each). Behaviour-preserving; it's what made the gate-predicate and help-flag
  extractions tractable.
- **`isHelpRequest` centralizes `--help`/`-h`/`help`** — previously hand-written
  at four sites (including the `mcp --no-telemetry --help` combo bypass that only
  existed because two of those copies couldn't see each other). One predicate now,
  with a reintroduction guard.

### `codedb_read` / `codedb_edit` accept absolute paths inside the project (#629)

- **Absolute in-project paths no longer read as "path traversal".** `isPathSafe`
  rejected every absolute path via a blanket leading-`/` check, so a path
  pointing at a file *inside* the indexed root was refused. Agents naturally
  hold absolute paths, hit the terse error, and abandon codedb for `bash` — a
  real session trace showed `codedb`,`codedb` rejected back-to-back followed by
  seven `bash` fallbacks. A new `projectRelPath` helper rewrites an in-root
  absolute path to its project-relative form; out-of-root absolutes, `..`
  traversal, NUL bytes, backslashes, and sensitive files stay rejected.

### Regex alternation no longer drops matches silently (#628)

- **`a|b` alternation where one branch can't form a trigram now scans all
  files.** A top-level alternation like `xy|createGateway` or `.*|foo`
  prefiltered candidates down to only the trigram-bearing branches, silently
  dropping files that matched the other branch — `mode=regex` returned 0 and
  read as an authoritative "not found". `decomposeRegex` now falls back to an
  unconstrained query whenever any branch yields no trigrams. Alternations
  where every branch has trigrams still prefilter as before.

### In-tree `codedb.snapshot` is hidden from git (#625)

- **The index no longer pollutes `git status` or risks an accidental commit.**
  The snapshot (22.8 MB in one real repo) was written to the project root and
  swept into working-tree diffs. After writing the in-tree snapshot,
  `codedb.snapshot` is appended to the repo's `.git/info/exclude` — a local,
  untracked ignore file — so git never sees it without touching the user's own
  `.gitignore`. Best-effort and idempotent; only the in-tree write triggers it.

### Agents are steered to the structural tools (#626)

- **`symbol`/`callers`/`deps`/`outline` are now the path of least resistance.**
  Tool descriptions and the MCP `initialize` instructions frame `search` as a
  fallback and point agents at the code graph first; `codedb_deps` is surfaced
  as the impact/blast-radius tool. Previously agents used codedb as a leaner
  grep/read and left its structural value on the table.

### Convergence governor caps navigation runaways (#624)

- **Repeated identical nav calls get an in-band nudge to change strategy.** A
  per-session ring buffer tracks recent `search`/`find`/`word`/`read`/`outline`
  signatures; when the same call recurs ≥3× it appends a one-line hint steering
  the agent to a structural tool, a direct read, or a refined query. It never
  alters a tool's result and does not govern write/admin tools — a cheap
  interception for the 3–5× token runaways seen on large repos.

## 0.2.5825 - 2026-06-12

`0.2.5825` is a broad retrieval-quality + capability + performance cut. It fixes
a class of **post-snapshot-load search and recall gaps** found by engram's
`codedb-report` (#537, #539, #547), restores **call-graph edges into
snapshot-restored files** (#537b), adds a **call-path query tool** and
**PageRank graph ranking** (#531), **richer symbol search** and **token-leaner
JSON output**, a batch of **TS/JS dependency-graph fixes** (#540, #541, #548),
an **opt-in for indexing temp roots** (#538), and **CLI hardening** (#528).

On top of that, a sustained latency pass driven by 2,467 production query-log
calls cut the **search hot path ~4–8×** (#611), added **whole-query result
caches + a background warmup** that drop first-call MCP search latency
**21.8 → 6.3 ms** and repeat searches to microseconds (#613), and fixed the
single biggest production-tail bug: **tier-3 whole-repo content scans after a
snapshot restore** — negative searches **9.2 → 0.5–0.9 ms** with
`recall_complete=true` (#615). Query-specific **call-graph-distance and git
co-change ranking signals** landed (#550), `codedb_context` gained a
**`max_tokens` budget** (#531), and a long run of correctness fixes hardened
the store, the mmap overlay, the word index, and the caches
(#583–#606).

### Search recall after a snapshot load (#537, #539)

- **Restored files are searchable again.** After a fast snapshot load a restored
  file was registered in neither `trigram_index` nor `skip_trigram_files`, so
  `codedb_search` omitted it entirely once the trigram index was non-empty (the
  Tier 5 full scan is then ruled out). `insertRestoredFile` now registers restored
  files in `skip_trigram_files`, mirroring the outline-only path (#507).
- **`searchContent` blends the complete word index into recall.** It rebuilds the
  lazily-loaded word index on first use (like `searchWord`), so Tier 0 ranks every
  file the inverted index knows about — a relevant restored file competes on
  relevance instead of being crowded out of `max_results` by hot files.

### Call graph into restored files (#537b)

- **`resolveCallees` no longer drops edges into restored files.** `insertRestoredFile`
  now rebuilds `symbol_index` for restored files (it is built eagerly on every
  commit and has no lazy fallback), so `codedb_callers` and call-path resolution
  see edges into snapshot-restored files after a load.

### Opt-in temp-root indexing (#538)

- **`CODEDB_ALLOW_TEMP=1` env or `--allow-temp` flag** allow indexing roots under
  `/tmp` and `/private/tmp`. The footgun guard stays the default; the opt-in
  unblocks SWE-bench-Lite / CI retrieval harnesses that clone throwaway checkouts
  into temp dirs. System dirs (`/usr`, `/etc`, …) and the home-directory guard are
  unchanged.

### Call-path queries + PageRank ranking (#531)

- **New `codedb_callpath` tool / CLI command** — the shortest resolved call chain
  between two symbols (`A → … → B`), each hop returned as `path:name@line`. Backed
  by `codegraph.shortestCallPath` (BFS) over the retained resolved call graph;
  `codedb_callers` now chains a `next: codedb_callpath …` hint.
- **Graph-aware ranking upgraded to PageRank.** Per-file centrality used by
  `searchContentRanked` now defaults to PageRank over the resolved call graph,
  replacing simple weighted in-degree. `CODEDB_IN_DEGREE_CENTRALITY` reverts to
  in-degree; `CODEDB_NO_CENTRALITY` disables the boost.

### Smarter symbol search

- **`codedb_symbol` gains kind / prefix / glob / fuzzy filters** (`searchSymbols`)
  — match by exact name, prefix, glob pattern, typo-tolerant fuzzy, or kind
  (function / struct / interface / class / method / enum), with an optional source
  body per hit.

### Token-leaner, structured output

- **`format=json`** on `codedb_search` and `codedb_symbol` returns structured
  results with search-provenance meta and structured tool errors.
- **`paths_only`** on `codedb_search` drops the matched-line text (~50% fewer
  tokens per call for broad surveys), and **`path_glob`** filters results by glob
  (bare patterns like `*.zig` are auto-promoted to `**/*.zig`).

### TS/JS dependency graph (#540, #541, #548)

- **Multi-line and re-export imports are captured** (#540, #542) — a closing
  `} from "..."` line or `export * from "..."` now feeds the dep graph, guarded so
  `from "..."` inside comments/strings isn't mistaken for a dependency.
- **Relative imports resolve to repo paths** (#541, #543) — `./` / `../`
  specifiers resolve to repo-rooted paths (with extensionless-import handling) so
  they show up in `deps` / `imported_by`; resolved keys are interned so re-indexing
  doesn't grow the arena per import.
- **No bogus deps from strings** (#548) — a line that merely *contains* `import `
  (e.g. an error message) is no longer captured as a dependency; only
  statement-position imports are.

### `search` consults the word index (#547)

- **The CLI `search` path now loads the word inverted index**, not just the
  trigram, so `searchContent`'s Tier 0 recall surfaces identifier terms that
  `word` finds (long / low-frequency names) — matching `word` / `mcp`. Previously
  `search` was trigram-only and went blind to such identifiers at scale.

### CLI hardening (#528)

- **Argument arity + validation** — extra or typo'd arguments to commands
  (`tree`, `hot`, `status`, …) now report a usage error and exit non-zero instead
  of silently succeeding.

### Performance: search hot path ~4–8× (#611)

- **`searchContent` hot path rewritten** — line-offset cache, doc_id-grouped
  candidate processing, packed-key sorts, rare-byte scan anchors, keyed final
  sort, pointer-facts memoization, direct-address doc slots, symbol-length
  masks, init-time path classification, run-at-a-time posting grouping, and a
  single outline fetch per candidate.
- Measured on the codedb repo (`c_allocator`, min-of-N, uncached):
  `middleware` 88 → 10.2 µs (**8.6×**), `database` 65 → 7.4 µs (**8.8×**),
  `error` 107 → 19.6 µs (**5.5×**), `authentication` 28.7 µs,
  `webhook` 16.6 µs. The benchmark pins `CODEDB_NO_SEARCH_CACHE=1` so rows
  stay comparable across versions, plus one explicit cached row.

### Performance: result caches + background warmup (#613)

- **Whole-query result LRUs** for `searchContent`, `renderPlainSearch` (the MCP
  fast path), and the BM25 `searchContentRanked` path — 64 entries / 4 MB each.
  Entries are served only when both the search generation and a fingerprint of
  the nine ranking kill-switch env vars still match. Repeat searches:
  **20.7 µs → 2.0 µs**. `CODEDB_NO_SEARCH_CACHE=1` disables.
- **Background warmup** — serve / mcp / cli-daemon spawn a thread that builds +
  persists the word index off the query path and replays the most-repeated
  queries from the project's `queries.log` through the real search entry
  points. 62% of production calls are exact repeats. First-call MCP search:
  **21.8 → 6.3 ms**. `CODEDB_NO_WARMUP=1` disables; skipped under
  `CODEDB_LOW_MEMORY`.
- **Generation race fixed** — search-generation bumps now happen inside the
  exclusive lock, so a concurrent search can never cache pre-mutation results
  under the post-mutation generation. Cache hits restore the producing search's
  provenance breakdown.
- **Symbol lookups gated on `symbol_index_complete`** — `findSymbol` /
  `findAllSymbols` / `renderSymbols` ran full O(files × symbols) outline safety
  scans on every call (a #310-era net predating #564). When the index is
  complete: **~6 ms/call → 50–100 ns** on a 20k-file corpus.

### Performance: tier-3 scan-set reconciliation after snapshot restore (#615)

- **The dominant production search-tail bug.** Snapshot restore parks every file
  in `skip_trigram_files`, and (1) nothing pruned the set when the disk trigram
  index was mmap-loaded, while (2) the freshness pass reindexing one dirty file
  blocked the disk load entirely (`loadTrigramFromDiskIfPresent` early-returned
  on any heap entry). Net: tier 3 content-scanned the whole project on every
  fall-through query with `recall_complete=false`. Measured live: 613/616 files
  in the scan set, negative searches **9.2 → 0.5–0.9 ms** after the fix.
- All trigram replacement now funnels through `adoptTrigramIndex` /
  `adoptTrigramBase` (swap, bump generation, prune the skip set); the mmap load
  keeps freshness-reindexed files as a masking overlay so newer content wins
  over stale base entries.
- **`CODEDB_TRIGRAM_CAP`** overrides the 15k-file heap-trigram cap (measured on
  a 20k-file corpus: uncapped = zero-hit queries 7.1 → 1.4 ms for +110 MB peak
  RSS); provenance meta reports the effective cap.

### Performance: load path + CLI status (#553, #564)

- **`codedb <dir> status` is metadata-only** (#553) — it no longer materializes
  the full index (previously a multi-GB resident process that never exited).
  Reported by **@lekt9**. 🙏
- **Snapshot fast-load defers the symbol index** (#564) — built lazily on
  first symbol query, tracked by the new `symbol_index_complete` flag.
  Measured on openclaw (13,654 files, ReleaseFast, warm): load 60 → 40 ms,
  Pass C heap +62.5 → +20.5 MB, one-shot search physical footprint
  132.7 → 89.2 MB (−33%), max RSS 244 → 200 MB.

### Ranking: query-specific graph signals (#550, #546, #554)

- **Call-graph distance** (#608) — files near the matched symbols in the
  resolved call graph get a query-specific boost; defines-first tier-0
  candidates seed the BFS. `CODEDB_NO_GRAPH_DISTANCE` opts out.
- **Git co-change** (#609) — bounded history pass (500 commits, ≤32-file
  commits, top-8 partners per file) boosts files that historically change with
  the matched ones. `CODEDB_NO_COCHANGE` opts out.
- **Negative lexical file-frequency penalty** (#554) — mention-everywhere terms
  stop dragging hub files up; ported from engram's ranking experiments,
  default-on with `CODEDB_LEX_FREQ_PENALTY` kill switch.
- **Multi-word CLI search is ranked end-to-end** (#546) — the cold CLI path
  rebuilds an incomplete word index and routes through BM25 ranking; bench /
  scripts / website / install tooling paths are down-ranked below `src`
  implementation; basename-only test files get the test penalty (#580);
  mention-dense tooling files can no longer saturate past the path prior
  (#598).

### `codedb_context` token budget (#531 → #610)

- **`max_tokens`** — sections render to buffers and are admitted by value order
  (head → files → symbols rich→lean → reader.md → callers → calls → snippets)
  under the budget, then emitted in document order with `[max_tokens: omitted …]`
  markers. Without the arg, output is byte-identical to before.

### Correctness: store, caches, and indexes (#583–#606)

- **Store hardening** (#597, #603) — no unlocked diff writes, data-log
  compaction, and `appendVersion` cleans up half-initialized entries on
  failure.
- **mmap overlay** (#593, #600) — overlay edits mask stale base entries and
  `writeToDisk` persists merged base+overlay state instead of dropping edits.
- **Word index** (#583, #585, #606) — disk-loaded indexes drop stale postings;
  doc_id slots freed by `removeFile` are reused (bounded `id_to_path` in
  long-lived daemons) with attribution preserved across persist/reload.
- **ContentCache** (#584, #596) — every entry stays reachable from its probe
  window, and capacity is now byte-budgeted (owned values bounded, oversized
  values refused).
- **OOM-safe indexing** (#594) — `indexFile` failure paths no longer panic,
  use-after-free, double-deinit, or poison entries.
- **Explorer re-index safety** (#586, #587) — symbol-index keys no longer
  dangle after re-index; `removeFile` clears its `skip_trigram_files` entry.
- **Secret filtering** (#589, #572) — `id_ecdsa` / `id_dsa` / `*_sk` FIDO key
  names, `*.env` variants, and `.git-credentials` are blocked in both
  `isSensitivePath` copies (now shared with `snapshot.zig`).
- **Misc**: per-project flock makes cli-daemon spawn mutually exclusive (#592);
  call-site extraction skips comments and string literals (#562, #572);
  `renderImportedBy` gates its basename fallback on ambiguity (#588);
  `codedb_query` deps-op strings are arena-owned (use-after-free + leak, #572).

### CLI & tool UX (#558–#578)

- `codedb_changes` is bridged into the CLI (#578); `codedb_ls` names a
  non-indexed path instead of saying "no entries" (#576); leading flags no
  longer bind as the positional and empty symbol names error (#573);
  `codedb_context` falls back to plain words for all-lowercase tasks (#570);
  multi-word `word` queries fall back to per-token matching (#569); `deps`
  empty lists always print the `(N files)` summary (#568); `codedb_query`
  filter accepts `pattern` and errors on missing params (#558); `path_glob`
  pages fill from the glob-filtered sequence (#560); `CODEDB_NO_CLI_DAEMON`
  disables the thin client entirely (#566).

### Contributors

Thanks to **@nsxdavid** for the TS/JS dependency-graph fixes (#542, #543), and
to **@lekt9** for reporting the resident-status-process leak (#553). 🙏

## 0.2.5824 - 2026-06-05

`0.2.5824` adds a deterministic, no-LLM **code-graph** layer. codedb now builds a
resolved call graph from the indexed symbols and uses it to rank search results
more precisely and to assemble richer first-touch context. The graph is computed
locally with no model calls and persisted in the snapshot, so it costs nothing on
the query hot path.

Beyond the graph, this cut also lands a **warm CLI daemon** (near-MCP latency
from the plain `codedb` CLI), a **faster fuzzy `find`**, **hardened CLI** parsing
and exit codes (#529), and **ReScript** `.res`/`.resi` support (#532).

### Graph-aware ranking (call-graph centrality)

- **New `src/codegraph.zig` builds a resolved call graph.** For each function
  body it extracts call sites (`extractCallees` — identifier-before-`(`, keyword
  filtered, de-duped), resolves each callee name through the function/method
  symbol table, and accumulates a weighted in-degree centrality per file
  (ambiguous names split their weight 1/N across candidates).
- **`searchContentRanked` folds centrality into the score.** Each candidate is
  multiplied by `1 + 0.15·log(1 + centrality)` — purely additive, never a filter,
  so recall is unchanged. Set `CODEDB_NO_CENTRALITY` to disable.
- **MRR-gated on the codedb repo** (18 labelled multi-word queries):
  MRR 0.819 → 0.944 (+15%), P@1 12 → 16, recall@5 unchanged, four queries' correct
  file jumped to rank 1, none regressed.

### Persisted call-graph centrality

- **The centrality map is stored in the snapshot** (new `CALL_CENTRALITY` section)
  and restored on load, instead of being rebuilt lazily on the first ranked query.
  The index/scan path builds it once via `Explorer.buildCallCentrality` before
  persisting; the loader restores it keyed off the stable outline paths, so
  `ensureCallCentrality` short-circuits.
- **Removes a large first-query stall.** On openclaw/openclaw (~39k files) the lazy
  build measured ~960 ms; it is now paid once at index time, and restoring it at
  load adds ~3 ms. Snapshots without the section fall back to the lazy build
  (backward compatible).

### Edge-aware codedb_context (callees)

- **`codedb_context` now surfaces a "Calls" section** alongside the existing
  callers section: for each key symbol it walks the symbol's call sites through
  the call graph and lists where each callee is defined, so an agent sees both who
  calls a symbol and what it calls without a follow-up `codedb_outline` /
  `codedb_read`.
- **High-precision by design.** Resolution is name-based (no type info), so a
  callee is shown only when it resolves to exactly one non-test function/method,
  and ubiquitous std/container method names (`init`, `get`, `append`, `lock`,
  `next`, …) are filtered out — guessing would assert a false edge in an
  LLM-facing block, so ambiguous calls are omitted rather than mis-resolved.

### Snapshot load performance (~3× faster load, ~338 MB lower RSS)

A series of load-path changes, each A/B-measured on openclaw/openclaw (~39k
files; interleaved warm loads, zero overlap between arms), found with a new gated
`CODEDB_LOAD_PROFILE` phase profiler (near-zero cost when off). Cumulatively the
load went from ~380 ms to ~125 ms and peak RSS from ~795 MB to ~457 MB.

- **Borrow restored outline strings + pre-size the load maps.** Imports / symbol
  names / details are now slices into the retained `OUTLINE_STATE` section instead
  of ~170k (millions on a dense repo) per-string dupes, and the load's hashmaps are
  pre-sized to the known file count. ~34% faster.
- **`statFile` instead of `openFile` + `stat` + `close` in the freshness check.**
  Only the mtime is needed, so one syscall per file instead of three. ~36% faster,
  and far more resilient to machine load.
- **mmap the content section.** Records are parsed from one memory mapping instead
  of ~4 `readPositionalAll` syscalls per file (~156k on a 39k-file repo); file-
  backed and demand-paged, with a heap bulk-read fallback. ~23% faster.
- **Borrow content from the mmap.** Drops the transient per-file content copy — a
  full pass over all content plus ~39k alloc/free pairs. ~8% faster.
- **Zero-copy `ContentCache`.** Cache values are borrowed (`putBorrowed`,
  `value_owned=false`) directly from the retained mmap instead of duped into owned
  heap; the Explorer munmaps at deinit, and a later re-index safely replaces a
  borrowed entry with an owned one. ~17% faster load and ~237 MB lower RSS — the
  ~268 MB owned content dupe is gone; content lives in the reclaimable mmap.
- **Stored content hashes (`CONTENT_HASHES` section).** Per-file content hashes are
  computed once at write time and read back at load, so the loader no longer
  re-hashes every file's content (which also faulted in every content page). ~14%
  faster and ~100 MB lower RSS; an absent section makes the loader recompute
  (backward compatible).

### Warm CLI daemon — near-MCP latency from the plain CLI

- **`codedb <root> <query>` auto-spawns then reuses a per-project warm daemon.**
  A cold query starts a background daemon that binds a per-project Unix socket
  (`/tmp/codedb-<uid>-<hash>.sock`); later CLI calls proxy to it and stream the
  rendered output back, skipping the cold snapshot reload. On any failure (no
  daemon, refused connect, short read) the client falls back to the cold
  in-process path, so the proxy is never a correctness risk.
- **Full navigation coverage.** The daemon serves the read-only query commands —
  `tree`, `outline`, `find`, `search`, `word`, `read`, `hot`, `symbol`,
  `callers`, `deps`, `glob`, `ls`, `file`, `context` — bridged to the same warm
  handlers the MCP server uses, so a proxied call pays roughly the MCP dispatch
  cost instead of a per-call cold index (**13–114× faster per call** in
  head-to-head runs).
- **Lean warm RSS.** The daemon mmaps the word index zero-copy and skips
  `file_words` on load so a long-lived warm daemon doesn't balloon; a u16
  name-length overflow that could panic the snapshot writer on very long
  identifiers is fixed.

### Faster fuzzy `find`

- **SIMD Smith-Waterman with a soundness prefilter (~1.8×, retrieval-identical).**
  Fuzzy filename ranking gained a presence prefilter and a SIMD-across-files
  inner loop; results are byte-for-byte identical to the scalar path.
- **Compound-identifier fast path (~22×).** A query that is itself a known
  compound symbol id is routed straight to the symbol index and returns the
  definition instead of scoring every file.

### CLI hardening (#529)

- **Robust argument parsing, validation, and exit codes** for every command:
  clear errors, correct non-zero exit on failure, a new `codedb status`, and a
  globally-honored `--no-telemetry`, so subagents and scripts can trust the exit
  code.

### ReScript (.res / .resi) support (#532)

- **ReScript is now a first-class indexed language.** A line-based parser
  extracts `let`/`and` bindings (function when the body has a `=>` arrow,
  constant otherwise), `type` → type alias, `module` → struct (`module type` →
  interface), `external` → function, and `open`/`include` as imports; leading
  `@decorators` are stripped so a decorated `@val external` / `@react.component`
  binding still resolves.

### Audit fixes (#530)

- **Secret-filter drift guard + per-session edit locks** from the #528 capability
  audit, with a runtime test proving an edit through a non-first session acquires
  the lock and applies.

### Validation

- `zig build test` — all pass, including new codegraph unit tests, `resolveCallees`
  resolution, and snapshot round-trip + centrality-persistence tests under the
  DebugAllocator.
- Graph ranking MRR-gated on the codedb query set (0.819 → 0.944, zero regressions).
- `codedb_context` verified end-to-end through the MCP server on codedb itself
  (e.g. `searchContentRanked` → `lockShared` / `posixGetenv` / `ensureCallCentrality`
  / `normalizeChar` / `splitIdentifier`, all correctly resolved).
- Snapshot load + RSS A/B'd on openclaw/openclaw (~39k files), two binaries on the
  same snapshot, interleaved warm loads: load ~380 ms → ~125 ms, peak RSS
  ~795 MB → ~457 MB, with no overlap between arms on any step. New ContentCache
  borrow tests and a `CONTENT_HASHES` order-alignment test pass under the
  DebugAllocator.

## 0.2.5823 - 2026-05-29

`0.2.5823` is an MCP compatibility hotfix for direct `tools/call` requests.
It ships the issue #512 fix and adds a wire-level stdio backtest so future
releases catch this exact client-wrapper failure mode.

### MCP direct tool-call compatibility

- **#512 — direct calls no longer drop inline args when `arguments` is empty.**
  Some clients send canonical MCP `params.name` and `params.arguments`, but a
  wrapper layer may also emit `arguments: {}` while placing the real fields
  inline on `params`, for example `{"name":"codedb_outline","arguments":{},
  "path":"src/mcp.zig"}`. Direct `tools/call` previously treated the empty
  `arguments` object as authoritative, dispatched `codedb_outline` with no
  `path`, and returned `missing 'path'` / `received keys: []` even though the
  request contained a path.
- **Canonical MCP behavior is preserved.** Non-empty `params.arguments` remains
  authoritative. When `arguments` is empty or absent, direct calls now copy
  non-administrative inline fields into a clean argument map before dispatch.
  A legacy `params.args` object is accepted only as a compatibility fallback
  when canonical args are absent or empty. Malformed non-object `arguments`
  still returns the protocol error `arguments must be object`.
- **Diagnostics now match direct calls.** Missing-arg guidance no longer says
  "sub-op" for direct `tools/call`; it explains the canonical direct shape and
  separately mentions the bundled inline fallback.

### Backtesting

- Added `test "issue-512: direct tools call accepts inline args when arguments
  is empty"` to exercise the direct call handler.
- Extended `scripts/e2e_mcp_test.py` with Scenario 4, which sends the malformed
  direct stdio MCP request through the real server process. The fixed binary
  passes **20/20** E2E checks; the pre-fix binary fails Scenario 4 with the old
  `missing 'path'` / `received keys: []` response.
- A subagent also validated the change with codedb MCP available. Its MCP
  snapshot was stale, so it used codedb MCP to inspect what was available and
  then confirmed the current disk state plus the focused and stdio E2E tests.

### Release metadata

- `src/release_info.zig`, `build.zig.zon`, and `npm/package.json` are aligned
  on `0.2.5823`.

### Validation

- `zig build test -Dtest-filter=issue-512`
- `zig build test`
- `zig build`
- `python3 scripts/e2e_mcp_test.py --binary zig-out/bin/codedb --project /Users/blackfloofie/codedb-release-0.2.5823`
  — **20/20 passed**
- GitHub PR bench-regression for #513: **success**
- Release asset workflow now builds the expected Linux ARM64 asset in addition
  to macOS ARM64, macOS x86_64, and Linux x86_64.

See [`benchmarks/v0.2.5823-validation.md`](benchmarks/v0.2.5823-validation.md)
for the release validation notes.


## 0.2.5822 - 2026-05-29

`0.2.5822` is a hot-path performance and release-reliability follow-up to
`0.2.5821`. It keeps the protocol fixes from `0.2.5821`, cuts the cost of
the common MCP tools, removes parser boilerplate, and fixes the remaining
Intel macOS/Rosetta release crash by leaving the x86_64 macOS artifact
unsigned until the Zig/Mach-O signing issue is resolved.

### MCP hot-path performance

- **Pre-rendered responses for hot tools.** `codedb_tree`, `codedb_outline`,
  `codedb_hot`, `codedb_deps`, `codedb_status`, and related MCP response paths
  now avoid unnecessary deep clones and intermediate buffers. The corrected
  benchmark harness now runs cases from the temp corpus root, so edit/read
  timings measure the intended project instead of the caller's checkout.
- **Lower edit latency.** `codedb_edit` avoids extra project-root work in the
  hot path and dropped from `236300 ns` to `44700 ns` p50 in the corrected
  microbench, an **81.08%** reduction.
- **No benchmark-critical regressions.** Comparing the corrected baseline to
  this release, every comparable MCP benchmark improved by more than 50%:
  `codedb_tree` `14530 -> 6270 ns`, `codedb_outline` `62930 -> 12820 ns`,
  `codedb_search` `33700 -> 8450 ns`, `codedb_deps` `1620 -> 70 ns`,
  `codedb_bundle` `93040 -> 28380 ns`, and `codedb_snapshot`
  `60100 -> 27750 ns`.

### Parser maintenance

- **`src/explore.zig` parser append cleanup.** Older language parsers had many
  repeated "dupe name/detail/import then append" blocks. These now route
  through shared helpers that preserve the prior symbol/detail behavior while
  cutting **393 net lines** from `src/explore.zig` (`83 insertions`,
  `476 deletions`). This is intentionally behavior-preserving cleanup after
  the parser expansion in earlier releases.

### Glob matching

- **#511 — brace alternatives in glob patterns.** `codedb_glob` and all MCP
  `path_glob` filters now support simple shell-style alternatives such as
  `**/*.{yaml,yml}` and `src/{mcp,explore}.zig`. Malformed braces without a
  comma continue to match literally, so existing literal-brace paths keep
  working. This fixes the confusing zero-result behavior agents hit when
  surveying YAML files with one glob.

### macOS Intel / Rosetta

- **#504 — signed x86_64 macOS binaries still crashed.** Local Rosetta testing
  reproduced the published `v0.2.5821` `codedb-darwin-x86_64` crash:
  `--help` exited `139` with no output. A fresh `0.2.5822` x86_64 build works
  when unsigned, but manually applying an ad-hoc signature to that exact binary
  brings back exit `139`. This matches the issue thread's native-Intel finding:
  the crash is triggered by codesigning Zig 0.16 x86_64-macos binaries on
  macOS 26, not by codedb startup logic.
- **Release workaround.** `build.zig` now makes `-Dcodesign-identity` opt-in and
  skips codesign for `x86_64-macos` even if the option is provided. The release
  workflow no longer passes `-Dcodesign-identity` for the Intel macOS matrix
  entry. Apple Silicon macOS artifacts still sign with hardened runtime when
  the signing identity is configured.
- **Docs updated to match distribution reality.** README and MCP docs now state
  that `codedb-darwin-x86_64` is temporarily unsigned and should be verified
  by SHA256 checksum. Zig version badges / requirements now say Zig 0.16.

### Release metadata

- `src/release_info.zig`, `build.zig.zon`, and `npm/package.json` are aligned
  on `0.2.5822`, so the native binary and `codedeebee` package metadata agree.

### Validation

- `zig build test`
- `zig build test-query -Dtest-filter="issue-511"`
- `zig build test-mcp -Doptimize=ReleaseFast`
- `zig build`
- `python3 scripts/e2e_mcp_test.py --binary zig-out/bin/codedb --project /Users/blackfloofie/codedb`
  — **17/17 passed**
- Rosetta x86_64 release test:
  - published signed `v0.2.5821` asset: `--help` exit `139`
  - patched unsigned `0.2.5822` x86_64 build: `--help` exit `0`,
    `--version` exit `0`, MCP e2e **17/17 passed**
  - manually re-signed patched x86_64 build: `--help` exit `139`
  - patched arm64 macOS build: signed and `--help` exit `0`
- Four-subagent SWE-bench Lite smoke using `codedb 0.2.5822` on non-temp
  workspaces:
  - `pallets__flask-4992`: target TOML config test passed.
  - `pytest-dev__pytest-5221`: two target fixture-listing tests passed with
    plugin autoload disabled for the old pytest checkout.
  - `sympy__sympy-12454`: rectangular matrix upper-triangular and Hessenberg
    target tests passed.
  - `psf__requests-2317`: codedb navigation succeeded, but the old checkout's
    target pytest collection is blocked on Python 3.14 because stdlib `cgi` was
    removed; a direct smoke confirmed byte and string methods normalize to
    `GET`.

See [`benchmarks/v0.2.5822-validation.md`](benchmarks/v0.2.5822-validation.md)
for the benchmark table and SWE-bench Lite smoke details.


## 0.2.5821 - 2026-05-28

Bundle of seven fixes from the open-issue triage on 2026-05-28.

### MCP server fixes

- **#502 + #503 — arg parser overhaul.** `codedb mcp <path>` no longer hangs forever in deferred mode (it now honors the path as root). `codedb mcp --help` prints usage instead of starting the server. Unknown post-`mcp` flags (e.g. `codedb mcp --snapshot`) are now rejected with a listed-valid-flags error. `codedb mcp` from a git-repo subdirectory walks up to the repo root. The deferred-scan path can no longer hang in `loading_snapshot` forever when the cwd isn't indexable — gives up after 13 s and unblocks `scan_done`.
- **#505 + #506 — MCP protocol version negotiation.** The server previously hardcoded `protocolVersion: "2025-06-18"`, which older Zed and certain opencode versions rejected with a startup timeout / "No MCP tools". Now echoes the client's version when it's one we've verified against (`2024-11-05`, `2025-03-26`, `2025-06-18`); for newer-than-known clients we return our latest known version.
- **#507 — search misses content after snapshot rebuild.** Files routed through `indexFileOutlineOnly` (snapshot load fallback, watcher incremental updates, WASM fast-path) were registered in `outlines` and `contents` but not in any search index. They were invisible to every search tier — including the tier-5 full-scan fallback, which short-circuited because the trigram index returned a non-null empty candidate set. Fixed by registering outline-only files in `skip_trigram_files` so tier 3 substring-scans them.
- **#508 — actionable `codedb_remote` errors.** The remote tool now distinguishes Cloudflare 530 / 1033 origin-unreachable from 404 (repo not indexed), 429 (rate limited), and 5xx (upstream error) with retry / local-fallback hints. The server-side outage at `api.wiki.codes` is not fixed by this change; the UX is.

### Startup / platform

- **#504 — macOS Intel x64 segfault on bare `codedb`.** Bisected via Rosetta: Zig 0.16's runtime wrapper around `pub fn main(...) !void` crashes at startup on signed x86_64-macos binaries. The user saw `codedb` segfault before any output reached the terminal. Fix: `pub fn main(...) void` (infallible) + `mainTrampoline()` for the fallible work + a `handleFastPath` short-circuit for bare/`--version` invocations that writes via raw `std.c.write` and bypasses the worker-thread trampoline entirely. Also fixes a related "output silently lost on early exit" bug where `std.process.exit(_)` skipped the deferred `Out.flush()`; `Out.exitWithFlush` now handles the common usage / error-message exit paths.

### Distribution

- **#501 — npm/npx distribution.** Published [`codedeebee`](https://www.npmjs.com/package/codedeebee) as the npx-friendly sibling of `codedb`. `npx -y codedeebee mcp` does a one-shot install: thin Node launcher + `postinstall` that downloads the matching native binary from this GitHub release and SHA256-verifies against `checksums.sha256`. The bare `codedb` name is restricted on npm; the package is `codedeebee` but the CLI it installs is still called `codedb`.

### Installer

- **Hook-priority race.** `install/install.sh` now detects competing legacy-tools hooks (`block-legacy-tools.sh`, muonry, zigrep, zigread) and inserts codedb's hook at index 0 instead of appending. Re-runs reshuffle an already-registered codedb hook to the front if a competitor has appeared since the previous install.


## 0.2.5813 - 2026-05-12

`0.2.5813` ships three structural improvements: a Tier 0 search-quality rewrite, a 4-6x faster regex matcher, and a bounded-memory content cache.

### Explore — search quality rewrite ([#448](https://github.com/justrach/codedb/issues/448), [#449](https://github.com/justrach/codedb/issues/449), [#450](https://github.com/justrach/codedb/issues/450), [#451](https://github.com/justrach/codedb/issues/451), [#447](https://github.com/justrach/codedb/issues/447))

- **Tier 0 builds candidates directly from `word_index.search`**, deduplicating hits per path and sorting by code-first / hit-count-desc / posting-list-order. This restructure (a) keeps the code/doc diversity logic active for popular identifiers regardless of total posting-list length (#449), (b) surfaces canonical definition sites in large skip-trigram files (>64KB) without waiting for Tier 3 to fire (#447, #451), and (c) clamps prefix-tier expansion to `max_results` so the contract is honored (#450).
- **Rerank uses symmetric stem/query matching** so a query like `Explorer` now boosts `src/explore.zig` even though the stem `explore` doesn't textually contain `Explorer` (#448-a). Symbol-definition equality is now case-insensitive, matching the rest of `searchContent` (#448-b).
- **Regression test for #447** locks the new Tier 0 path against future refactors that might silently bury skip-trigram canonical files behind small-file hits.

### Regex — nanoregex integration ([#454](https://github.com/justrach/codedb/issues/454))

- **Replaced the ~300-line homegrown backtracking matcher with [`justrach/nanoregex`](https://github.com/justrach/nanoregex)**, a pure-Zig Thompson-NFA/DFA engine with Python-`re`-compatible semantics. End-to-end in-process benchmarks on codedb's own ~1.2MB source tree show **2.7-4.3x speedup** on the common `codedb_search regex=true` shapes (literal, alternation, dot-star, char-class).
- **Correctness fixes** that previously failed silently:
  - `\b` and `\B` now work as word-boundary assertions instead of being treated as the escaped literal `b`/`B`. Patterns like `\bfn\b` now return matches.
  - `{n,m}` bounded quantifiers, lazy quantifiers (`*?`, `+?`), and the other PCRE-shaped features nanoregex supports.
  - ReDoS-safe: patterns like `(a+)+b` can no longer cause catastrophic backtracking.
- **Upstream patch:** while integrating, also fixed a false-negative in nanoregex's `extractLiteralPrefix` (patterns like `hel+o` computed prefix `helo` and silently missed `helllo`). Worth pushing upstream.

### Explore — bounded-memory content cache ([#208](https://github.com/justrach/codedb/issues/208))

- **Replaced `Explorer.contents: StringHashMap` with a fixed-capacity CLOCK eviction cache** (`src/hot_cache.zig`). Pre-fix, file contents were all-or-nothing — either fully resident in RAM (1.7GB on openclaw) or entirely released by `releaseContents`. Now: 16384 slots with second-chance eviction, hot files stay cached, cold files fall through to disk read on next access.
- **Memory impact:** the `snapshot: writer streams` test (1002 files) drops MaxRSS from **623MB → 225MB** end-to-end. Cache state is bounded; eviction is exercised under pressure (5 inline `ContentCache` tests + the issue-208 integration test).
- Design adapted from [justrach/turbodb `src/hot_cache.zig`](https://github.com/justrach/turbodb/blob/main/src/hot_cache.zig) — CLOCK with probe limit 4, atomic hit/miss/eviction counters, zero dynamic allocation past init.


## 0.2.5812 - 2026-05-07

`0.2.5812` cleans up two papercuts surfaced during a v0.2.5811 verification run ([#445](https://github.com/justrach/codedb/issues/445)).

### Explore ([#445](https://github.com/justrach/codedb/issues/445))

- **`codedb_deps depends_on` no longer dupes multi-aliased imports.** A file aliasing the same dep across multiple `@import` sites (e.g. `const idx = @import("index.zig"); const Index = @import("index.zig").Foo;`) previously appeared once per `@import` in the forward edges — `src/main.zig` in this very repo showed `index.zig` 5x and `mcp.zig` 2x. `rebuildDepsFor` now dedupes via a `StringHashMap(void)` before calling `setDeps`. The reverse index (`getImportedBy`) was already correct.

### MCP

- **`codedb_find` description tightened.** The previous wording ("fuzzy file-name search") didn't make it explicit that it's filename-only — agents kept reaching for it on symbol-name lookups (e.g. `find rerank` expecting `src/explore.zig`). The new description says explicitly it is NOT content/symbol search and routes callers to `codedb_word`/`codedb_symbol`/`codedb_search` instead.


## 0.2.5811 - 2026-05-07

`0.2.5811` disables `codedb_bundle` advertisement by default ([#443](https://github.com/justrach/codedb/issues/443)).

### MCP ([#443](https://github.com/justrach/codedb/issues/443))

- **`codedb_bundle` is no longer advertised in `tools/list` by default.** Across multiple stages — empty-args schema (#434), `oneOf` augmentation (#437), OpenAI strict-mode regression (#440), and `codedb_projects` replay-loop (#441) — the bundle has remained a footgun for OpenAI clients (codex, forgecode, etc.) because the default schema can't bind sub-tool argument shape without `oneOf`, and `oneOf` is OpenAI-strict-incompatible. Disable the advertisement entirely until the schema can be reworked to bind args inline (no `arguments` wrapper). The dispatcher-side handler stays so any client with a cached schema doesn't crash on call. Set `CODEDB_BUNDLE_ENABLED=1` to re-advertise.
- **New helper `buildToolsListResponse(alloc, opts)`** centralizes the env-var-gated `tools/list` builder previously inlined in `run()`. `opts` are `{ bundle_enabled, discriminated_opt_in }`. Always returns an allocator-owned slice.

## 0.2.5810 - 2026-05-07

`0.2.5810` blocks `codedb_projects` from being a valid `codedb_bundle` sub-op ([#441](https://github.com/justrach/codedb/issues/441)).

### MCP ([#441](https://github.com/justrach/codedb/issues/441))

- **`codedb_bundle` rejects `codedb_projects` sub-ops.** `codedb_projects` lists every indexed project on the machine — a global directory enumeration unrelated to whatever repo the agent is actually working on. When a planner sees a previous bundle that called `codedb_projects`, it tends to replay the same shape (e.g. 5x `codedb_projects` in one batch), and recent-message attention bias amplifies it on continuation: graff and similar resumable clients ship the delta + `previous_response_id`, so the previous assistant message dominates the planner's context. Block it at the dispatcher, mirroring the existing rejections of `codedb_bundle` (recursive) and `codedb_edit` (write op). The `oneOf` discriminated schema (opt-in via `CODEDB_DISCRIMINATED_SCHEMA=1`) also drops the `codedb_projects` branch, so model output can't suggest it. Standalone calls to `codedb_projects` outside a bundle are unchanged.

## 0.2.5809 - 2026-05-07

`0.2.5809` is a hotfix for a v0.2.5808 regression: the discriminated `oneOf` on `codedb_bundle` ops items (Stage 2 of [#437](https://github.com/justrach/codedb/issues/437)) breaks every MCP client backed by the OpenAI Responses API (codex, forgecode, etc.). OpenAI's strict-mode tool-schema validator rejects `oneOf` outright with `Invalid schema for function 'mcp_codedb_tool_codedb_bundle': 'oneOf' is not permitted`, which makes the entire `codedb_bundle` tool unusable on those clients.

### MCP

- **`oneOf` is now opt-in via `CODEDB_DISCRIMINATED_SCHEMA=1`.** By default, `tools/list` serves the raw schema with only Stage 1's `required: ["tool", "arguments"]` (from [#434](https://github.com/justrach/codedb/issues/434)) — works on every MCP client. Anthropic-backed clients that benefit from the discriminated `oneOf` can re-enable it by setting the env var on the codedb process. The `buildAugmentedToolsList` builder is unchanged; only the call site in `mcp.zig` is gated on the env var. The `#424` runtime inline-args fallback continues to handle non-conformant clients.

### Compatibility

- v0.2.5808 set the bundle schema to a structure OpenAI's validator rejects. If you upgraded yesterday and saw `tools[N].parameters` errors from codex/forgecode, this is the fix — no opt-in needed.
- Anthropic-backed clients (Claude Code, etc.) that want the stronger constraint: `export CODEDB_DISCRIMINATED_SCHEMA=1` before launching the MCP server.

## 0.2.5808 - 2026-05-06

`0.2.5808` is a tool-schema fix for `codedb_bundle` plus an opt-in rerank-trace logger for offline ranking experiments. Three PRs ship together: [#435](https://github.com/justrach/codedb/pull/435) (Stage 1 of [#434](https://github.com/justrach/codedb/issues/434)), [#438](https://github.com/justrach/codedb/pull/438) (Stage 2 of [#437](https://github.com/justrach/codedb/issues/437)), and [#436](https://github.com/justrach/codedb/pull/436) (rerank-trace logger).

### MCP ([#434](https://github.com/justrach/codedb/issues/434), [#437](https://github.com/justrach/codedb/issues/437))

Function-calling LLMs were emitting `{tool: "codedb_outline", arguments: {}}` and similar payloads that then failed each sub-op with `received keys: [tool, arguments]`. The schema permitted the empty payload and the model picked the minimum-valid one. Fixed in two stages, both shipping here.

- **Stage 1: `arguments` is now required on bundle ops items.** Pre-fix the items schema was `required: ["tool"]` with `arguments` as a bare `{type: "object"}`, so `arguments: {}` and outright omission were both valid input. Schema-greedy function-calling models read this as authoritative and emitted the empty form, which then misrouted through the inline-args fallback at `mcp.zig:1948` and surfaced as `received keys: [tool, arguments]` from each sub-tool. Adding `"arguments"` to `items.required` forces the model to populate the wrapper. The `#424` runtime inline-args fallback stays as a backstop for non-conformant clients.
- **Stage 2: discriminated `oneOf` over `tool`.** Stage 1 forces presence but not contents — a schema-greedy model could still satisfy `required: ["tool", "arguments"]` by emitting `{tool: "...", arguments: {}}`. Stage 2 binds the *contents* of `arguments` to each sub-tool's actual `inputSchema` via a discriminated `oneOf` with one branch per dispatchable codedb_* sub-tool. Each branch pins `tool` to a `const` (e.g. `"codedb_outline"`) and `arguments` to that sub-tool's schema (with its own `required` array preserved), so once a model picks a sub-tool the only matching branch tells it exactly which keys to populate. `codedb_bundle` (recursive) and `codedb_edit` (write op) are excluded since `handleBundle` rejects them at runtime. The augmented schema is built once at server startup from the per-sub-tool schemas already advertised in `tools_list` — no hand-maintained duplication. Falls back to the raw `tools_list` if augmentation fails.

### Search ([#436](https://github.com/justrach/codedb/pull/436))

- **Opt-in rerank-trace logger for offline tuning.** A v0 JSONL trace logger is added behind `rerank_trace = true` in `.codedbrc`. When enabled, each `searchContent` invocation appends one line — `{ts, query, results:[{path, line, score}]}` — so the data can be analyzed offline before deciding whether online learning-to-rank from agent traces is worth building. Pure observation, disabled by default, no ranking-behavior change. Query is capped at 256 bytes, results at 50 entries, and the file rotates by truncate-clobber at 10 MB. All I/O errors are swallowed — logging never breaks a search.
- **`rerankAndFinalize`: score-then-sort, even at len 1.** A pre-existing micro-optimization skipped multi-signal scoring when the result list had fewer than two entries. With the trace logger landed, single-result entries logged `score=0.0`, indistinguishable from genuinely zero-confidence matches. Scoring now always runs; only the sort is guarded behind `len > 1`. Cost is a few µs per single-result search.

### Validation

- Two failing tests in `src/tests.zig` (`issue-434`, `issue-437`), each one fails on `main` without its respective stage and passes with it. End-to-end Sonnet 4.6 test against the new bundle schema: prior bug (empty `arguments` payloads under no fix; wrong-keyname payloads under Stage 1 only) does not reproduce. Same task that previously emitted `codedb_word` with `{"query": "..."}` (failing) now emits `{"word": "..."}` (succeeding) — the discriminated branch's `required: ["word"]` constraint flows through to model output.
- Bundle schema payload size doubled (~12KB → ~24KB) due to inlining 19 sub-tool schemas as `oneOf` branches. Acceptable cost for the constraint.
- 513/513 tests pass on the merged release branch.

## 0.2.5807 - 2026-05-06

`0.2.5807` is a search-quality + crash-fix release covering six issues. The headline is a multi-signal reranker for `searchContent` plus a P0 crash fix in `searchInContent`. All six fixes ship in a single bundle ([#425](https://github.com/justrach/codedb/issues/425), [#426](https://github.com/justrach/codedb/issues/426), [#427](https://github.com/justrach/codedb/issues/427), [#429](https://github.com/justrach/codedb/issues/429), [#430](https://github.com/justrach/codedb/issues/430), [#431](https://github.com/justrach/codedb/issues/431)).

### Reliability ([#431](https://github.com/justrach/codedb/issues/431))

- **`searchInContent`: bounds-check fixes a P0 crash.** When the query was longer than any indexed file's content, `content.len - query.len + 1` underflowed `usize` and the binary aborted with integer-overflow panic (Debug) or SIGBUS (ReleaseFast). One-line guard at the top of `searchInContent` returns early when `query.len > content.len`. Reachable from any user-supplied query that exceeded the smallest indexed file (e.g. a one-byte stub). Fixed.

### Search quality ([#425](https://github.com/justrach/codedb/issues/425), [#426](https://github.com/justrach/codedb/issues/426))

- **`codedb_callers`: whole-word match.** `handleCallers` previously substring-matched the symbol name across the index and only excluded the canonical definition line of the searched name itself. Searching for `fooBar` returned matches inside `fooBarExtended` — both its definition site and any references — as if they were call sites. A new `hasWholeWordMatch` check gates every emitted result on identifier-boundary characters on both sides of the hit.
- **`codedb_callers`: language gate.** `handleCallers` fed `searchContentWithScope` across every indexed file regardless of language, so markdown design docs and other prose surfaced as call sites whenever the symbol name was mentioned. A new `langHasCallSites` predicate excludes data formats (`json`, `yaml`), markup/styling (`markdown`, `css`, `scss`), declarative schemas (`protobuf`), and unknown files.

### Search ranking ([#427](https://github.com/justrach/codedb/issues/427), [#429](https://github.com/justrach/codedb/issues/429), [#430](https://github.com/justrach/codedb/issues/430))

- **Tier 1 candidate sort by per-file word-hit count.** `searchContent`'s Tier 1 sorted trigram candidates by content length ascending and then capped per-file at `max(1, max_results / estimated_total)`. When small unrelated files dominated the candidate list, they each contributed one hit and saturated the result quota before the larger definition-dense file was scanned. Now Tier 1 ranks candidates by per-file word-index hit count (desc) with content length (asc) as a stable tiebreaker — the file with the most occurrences scans first.
- **Tier 0 processes code before docs.** With `max_results=50` and the per-file cap of 10, five markdown files mentioning the query 10+ times each could collectively saturate the quota before the canonical source file was reached, leaving the source file completely absent from results. A new `isDocLanguage(Language)` predicate gates a two-pass loop: code-language hits first, doc-language hits second. Same per-file cap, same dedup, same early-return — only iteration order changes. Source files now win the recall race.
- **Multi-signal rerank.** The post-pass rerank counted per-line query occurrences only and broke ties on path-asc + line-asc, which buried symbol-definition lines under alphabetically-earlier comment mentions, ranked `examples/foo.zig` above `src/foo.zig`, and lost basename-match intent entirely. New `rerankSignalScore` composes per-line occurrence count, a symbol-definition boost (+5 when the hit line is a defined symbol whose name matches the query, looked up via outlines), a basename-match boost (+15 exact stem, +8 substring, case-insensitive), a path-segment match boost (+6 for queries like `parser` matching `src/parser/foo.zig`), and a path-prior penalty (×0.6 for `tests/`, `examples/`; ×0.4 for `vendor/`, `node_modules/`, `third_party/`). Constants are tuned so a 5x-higher per-line frequency still wins on its own, while each signal individually flips alphabetic ties.
- **Rerank applies on every return path.** Pre-fix the multi-signal rerank only ran on fall-through to the final return; Tier 0 and Tier 1 early-returns at `max_results` bypassed it entirely. Lifting the rerank into a `rerankAndFinalize` helper called from every searchContent return point gives the symbol-def / basename / path-prior signals consistent coverage regardless of which tier filled the quota.
- **Doc-language penalty in rerank.** Live-binary testing showed CHANGELOG and benchmark `.md` files with 4-6 mentions of an identifier on one line outranking actual code call sites under per-line frequency. The reranker now caps doc-language scores at 1.0 then halves them, so any code hit (`score >= 1`) outranks any markdown / json / yaml / unknown-language hit. Symmetric with the path-prior penalty.

### Validation

- 271 lines of regression tests in `src/tests.zig` — one or more per issue, all failing on `main` without the fix and passing with it. Bundle-level Sonnet 4.6 validation (real codebase, side-by-side comparison vs. the 0.2.5806 baseline) shows definition sites promoted to #1 for `handleCallers`, `pathHasSegment`, `BenchContext`, `Explorer`; `src/explore.zig` now ranks #1 for the `searchContent` query (was completely absent from baseline top-5); `src/watcher.zig` at #1 for `watcher`; no quality regressions on innocent queries; RSS delta under 1%.

## 0.2.5795 - 2026-05-04

`0.2.5795` closes out [#356](https://github.com/justrach/codedb/issues/356) with phase 3 — three small ergonomics polishes that complete the rewritten reliability scope — plus a privacy/disk-leak fix for [#367](https://github.com/justrach/codedb/issues/367).

### Reliability ([#356](https://github.com/justrach/codedb/issues/356) phase 3)

- **`codedb_outline`: stale-index recovery hint.** When a path isn't indexed, the response already gets fuzzy suggestions (phase 1). It now also includes `hint: try codedb_index if the file was added recently` so agents know how to recover from a freshly-added file the watcher hasn't seen yet — no more relying on tribal knowledge of the operator command.
- **`codedb_read`: fuzzy path fallback on read failure.** `codedb_outline` already surfaces `did you mean:` suggestions when its path doesn't index; `codedb_read` now does the same when its disk read fails. A mistyped path is recoverable in one shot without a separate `codedb_find` round-trip.
- **`codedb_query`: per-stage summary tail.** Successful pipelines now emit a structured `--- stages ---` block listing each step's op and outgoing file count. Long pipelines become legible at a glance without parsing the unstructured per-step output above it.

### Storage ([#367](https://github.com/justrach/codedb/issues/367))

- **`data.log`: truncate on open.** Previously, `Store.openDataLog` opened the file with `truncate=false` and seeded the write cursor to the existing length, while `Store.init` returned an empty in-memory index and nothing replayed the log on load. Net effect: every prior session's raw `codedb_edit` content (potentially including secrets/PII pasted into a `content` arg) accumulated forever as unreachable orphan bytes in a file that looks like a log but isn't read by anyone. The log is now truncated on every process start, since the in-memory index is always empty at that point and the on-disk bytes are unreachable.

### DX

- **TTY summary surfaces received-keys diagnostic.** The `received keys: [...]` hint from #356 phase 1+2 only landed in `content[1]` of the MCP envelope, but many clients only render `content[0]` (the colored single-line summary). Missing-arg errors now append a compact `(received: [...])` tail to the summary too, so the diagnostic is visible regardless of how many blocks the client renders.

With this release, [#356](https://github.com/justrach/codedb/issues/356) is closed:
- ✅ Phase 1 — pipeline partial results, outline fuzzy fallback, query received-keys diagnostic (0.2.5793)
- ✅ Phase 2 — received-keys diagnostic across all single-tool handlers (0.2.5794)
- ✅ Phase 3 — stale-index hint, read fuzzy fallback, query per-stage summary (0.2.5795)

## 0.2.5794 - 2026-05-04

`0.2.5794` extends [#356](https://github.com/justrach/codedb/issues/356) phase 2 — the `received keys: [...]` diagnostic now lands on every single-tool handler with a required argument. Tiny release; entirely an ergonomics polish on top of `0.2.5793`.

### Reliability ([#356](https://github.com/justrach/codedb/issues/356) phase 2)

The `received keys: [...]` self-diagnose hint is now wired into:

- `codedb_outline` — missing `'path'`
- `codedb_symbol` — missing `'name'`
- `codedb_search` — missing `'query'`
- `codedb_word` — missing `'word'`
- `codedb_deps` — missing `'path'`
- `codedb_read` — missing `'path'`

Combined with phase 1 (`codedb_query` pipeline steps and `codedb_bundle` ops), every read-path tool now surfaces the keys it actually received when a required argument is missing. Callers can self-diagnose typos like `file_path` vs `path` without retrying blind. `codedb_edit` deliberately keeps the bare error — write operations should fail loudly without hinting at alternatives.

## 0.2.5793 - 2026-05-04

`0.2.5793` is a search recall, ranking, and reliability release on top of `0.2.5792`. All three items from [#363](https://github.com/justrach/codedb/issues/363) plus phase 1 of [#356](https://github.com/justrach/codedb/issues/356) are resolved.

### Search and ranking ([#363](https://github.com/justrach/codedb/issues/363))

- **`codedb_search` recall: source-file matches no longer dropped when doc files dominate the word index.** A Sonnet 4.6 sub-agent driving the live MCP reproduced [#363](https://github.com/justrach/codedb/issues/363) item a: querying `searchContent` against this repo returned doc files (CHANGELOG.md, architecture.md, etc.) but missed `src/explore.zig` itself. Root cause: Tier 0 of `searchContent` (`explore.zig:1511`) iterates word-index hits in posting-list order and saturates the result quota with hits from heavily-mentioning files before reaching source files indexed later. Fix: per-file cap of `max(1, max_results / 5)` in Tier 0 so a single hot file can't crowd out the rest. Closes [#363](https://github.com/justrach/codedb/issues/363) (item a).
- **Fuzzy find: exact basename match now dominates ranking.** Querying `cli.rs` against a multi-crate workspace previously returned four unrelated `lib.rs` files ahead of the actual `crates/forge_main/src/cli.rs`. The compounding factors were the special-entry-point bonus (which gave `lib.rs` / `main.go` / `index.ts` a +5% boost regardless of query) and path-length normalization rewarding shorter parent paths. Fix: when the query case-insensitively equals the filename, apply a 4× multiplier — fzf-style "exact match always wins." Closes [#363](https://github.com/justrach/codedb/issues/363) (item b).

### Query reliability and ergonomics ([#356](https://github.com/justrach/codedb/issues/356) phase 1)

The "Agent Context Planner" framing was dropped — codedb stays a tool, agents stay in charge of composition. Three small reliability improvements land:

- **`codedb_query`: partial results when a step fails.** The pipeline previously bailed on the first error and discarded successful prior-step output. Now the prior-step output is preserved and a structured `--- partial ---` tail names the failing step + reason. Agents can recover from a single bad step instead of starting over.
- **`codedb_outline`: fuzzy path fallback.** A non-indexed path used to return a bare `error: file not indexed`. Now appends up to 3 fuzzy-matched indexed paths under a `did you mean:` header, so an agent that mistypes can self-correct without a separate `codedb_find` round-trip.
- **`codedb_query`: received-keys diagnostic on missing-arg errors.** Mirrors the [#357](https://github.com/justrach/codedb/issues/357) `codedb_bundle` diagnostic. When a step fails with `error: search needs 'query'` but the step actually has a `q` key instead, callers see `received keys: [op, q]` so they can tell whether codedb dropped the field or the client sent it under the wrong name. Wired through `op`-detection plus `find`, `search`, `word`, and `symbol` step error paths.

### Cosmetic

- **`codedb --version` and `codedb_status` now report the correct version.** The `0.2.5792` release shipped with `src/release_info.zig` at `"0.2.579"` while `build.zig.zon` was at `"0.2.5792"` — so binaries built from that source tree self-reported as the older version. Both are now synced to `0.2.5793`.

### Carried over from 0.2.5792

The `received keys: [...]` diagnostic that landed in [#357](https://github.com/justrach/codedb/issues/357) (PR [#362](https://github.com/justrach/codedb/pull/362), shipped in 0.2.5792) addresses [#363](https://github.com/justrach/codedb/issues/363) item c — bundled-op argument errors now surface the keys actually received so callers can self-diagnose.

## 0.2.5792 - 2026-05-04

`0.2.5792` is a tools, safety, and performance release. Two new MCP tools land (`codedb_glob`, `codedb_ls`), `codedb_edit` gains a `dry_run` preview and an `if_hash` stale-line guard, and the `**` glob matcher is rewritten to fix a recall regression and pick up a 30% p50 win on common patterns.

### Highlights

- **New: `codedb_glob` and `codedb_ls` MCP tools.** Native glob and directory listing surfaced to MCP clients alongside the existing search/outline tools. Closes [#359](https://github.com/justrach/codedb/issues/359).
- **`codedb_edit` is now safer.** `if_hash` is enforced — edits against stale lines fail fast instead of silently overwriting. `dry_run` returns the would-be diff (and a corrected `inserted_count`) without writing. Closes [#360](https://github.com/justrach/codedb/issues/360).
- **Glob `**` correctness fix.** The pipeline filter previously used `mcp.globMatch`, which dropped matches when `**` had to backtrack across directory depths. Replaced with `explore.matchGlob`. A retrieval-recall regression test now pins behavior across all six retrieval surfaces (full-text, word index, symbol index, fuzzy path, glob, dep graph). Closes [#359](https://github.com/justrach/codedb/issues/359).
- **30% faster `**/*.md` glob.** `matchGlob` short-circuits common patterns: `**/*X` degenerates to `endsWith`, and patterns with long literal prefixes that the path can't match exit early. Measured 540 µs → 377 µs p50.

### Correctness: Edit

- `if_hash` mismatch returns an error instead of writing — no more silent stale-line overwrites. (#360)
- `dry_run` mode returns the planned diff without touching the file; `inserted_count` reports the correct line count. (#360)
- `codedb_edit` response is now hex-consistent with `codedb_read` so callers don't have to normalize hash formats.

### Correctness: Glob

- Pipeline glob filter routes through `explore.matchGlob`, fixing `**` backtracking across directory depths. (#359)
- Recall regression test plants a flat 5-file corpus (definition, importer, test, decoy, prose) and asserts every retrieval surface — `searchContent`, `searchWord`, `findAllSymbols`, `fuzzyFindFiles`, `globPaths`, `getImportedBy` — returns the expected files and excludes the decoy. Fires if any index silently drops a file in the future.

### Performance

- `matchGlob` fast paths for `**/*X` (endsWith) and long literal prefixes. −30% p50 on `**/*.md` (540 → 377 µs).
- `lsDir` / `globPaths` allocation trims: pre-reserved result-list capacity, removed the redundant `seen_files` map in `lsDir`. Effect on a 113-file repo is within run-to-run noise; kept because it removes dead work and reduces allocations on larger repos.

### Issues Closed

- [#359](https://github.com/justrach/codedb/issues/359) — Tool suggestions: native `glob` and `ls` tools
- [#360](https://github.com/justrach/codedb/issues/360) — `codedb_edit` suggestions (`if_hash` + `dry_run`)

## 0.2.57 - 2026-04-13

`0.2.57` is a broad correctness, performance, and reliability release. It ships everything merged to main since `0.2.56` plus nine index and watcher bug fixes.

### Highlights

- **10× faster initial indexing.** Worker-local parallel scan with deterministic merge: each scan worker builds its own partial `Explorer`, then the results are merged on the main thread with no lock contention during the hot path. Closes [#221](https://github.com/justrach/codedb/pull/221).
- **Full `codedb nuke` uninstall.** `nuke` now removes all codedb data, kills any running daemon, deregisters MCP entries from Claude / VS Code / Cursor configs, and cleans up the install binary. Closes [#239](https://github.com/justrach/codedb/pull/239).
- **MCP: 10-minute idle timeout + dead-client detection.** Sessions that go quiet for 10 minutes are reaped automatically; POLLHUP on stdin is detected immediately so zombie MCP processes don't accumulate. Closes [#148](https://github.com/justrach/codedb/issues/148).
- **TrigramIndex id_to_path is now bounded.** A free-list of released doc_id slots is reused on re-index, so `id_to_path` grows only to the peak number of simultaneously live files, not total files ever indexed. Closes [#247](https://github.com/justrach/codedb/issues/247), [#227](https://github.com/justrach/codedb/issues/227).
- **watcher: git HEAD check is mtime-gated.** `.git/HEAD` mtime is statted per poll; `git rev-parse HEAD` forks only when it changes. Reduces steady-state background subprocesses from ~30/min to ~0 on idle repos. Closes [#254](https://github.com/justrach/codedb/issues/254).
- **Rosetta 2 / Apple Silicon stack fix.** Release builds now use an 8 MB stack on macOS, fixing stack-overflow crashes under Rosetta translation. Closes [#223](https://github.com/justrach/codedb/issues/223).

### Performance And Memory

- Worker-local initial indexing: each thread maintains its own `Explorer` during scan, eliminating the cross-thread merge bottleneck. Merge is deterministic so snapshot replay is reproducible. (#221)
- Steady-state watcher: mtime guard on `.git/HEAD` eliminates per-cycle fork+exec, saving CPU on large repos. (#254)
- `searchContent` fallback now iterates only the `skip_trigram_files` set (files indexed past the 15k cap) instead of all outlines. (#250)
- `EventQueue.head/tail` and `Store.seq` converted from atomic values to plain integers — all access already holds the owning mutex. Removes unnecessary memory fence instructions.

### Correctness: Index And Explorer

- `TrigramIndex.removeFile`: `path_to_id.remove` is now the first operation, fixing a ghost-entry bug where files missing from `file_trigrams` left stale map entries. (#246)
- `TrigramIndex.getOrCreateDocId`: reuses freed doc_id slots from `free_ids: ArrayList(u32)`, keeping `id_to_path` bounded. (#247, #227)
- `PostingList.removeDocId`: O(log n) binary search replacing the previous O(n) linear scan.
- `AnyTrigramIndex` mmap_overlay: `candidates` / `candidatesRegex` now `deinit` the result ArrayList on the error path, closing an OOM buffer leak. (#251)
- `commitParsedFileOwnedOutline`: errdefer rolls back `word_index.indexFile` if the subsequent trigram index step fails, keeping word and trigram indexes in sync. (#252)
- `searchContent` fallback restricted to `skip_trigram_files` set, reducing false-negative range from O(all files) to O(skip-trigram files). (#250)

### Correctness: Nuke And Config

- `rewriteConfigFile`: writes to `{path}.tmp`, syncs, then renames — no more truncated config files on kill. (#249)
- `nuke` now deregisters MCP server entries from JSON configs (Claude, VS Code), TOML configs (Cursor), and removes the install binary. Handles corrupted or non-standard config files gracefully. (#239)

### Correctness: Snapshot

- `readSectionBytes` opens the snapshot file once; extracted `readSectionsFromFile` helper shared with `readSections`. (#253)
- `readSectionString` limit raised from 4,096 to `std.math.maxInt(u16)` — long symbol names no longer return errors.
- `loadSnapshotFast` treats a corrupt `OUTLINE_STATE` section as an empty map rather than aborting startup.

### MCP Stability

- 10-minute idle timeout: MCP sessions that stop receiving input are reaped, preventing zombie processes on long-running Claude sessions. (#148)
- POLLHUP detection: stdin is polled; a closed read-end triggers immediate clean shutdown instead of waiting for the next read timeout. (#148)
- `codedb_status` memory and index diagnostics are unaffected by telemetry call-count race (atomic increment fix). (#179)

### Infrastructure

- 8 MB release stack on macOS prevents stack overflows under Rosetta 2 on `aarch64` binaries running via translation. (#223)
- `help` command now compiles and exits correctly as a standalone CLI invocation. (#238)
- `approxIndexSizeBytes` updated for the `AnyTrigramIndex` union layout. (#236)

### Benchmarks (`ReleaseFast`, openclaw/openclaw, 6,315 files, Apple M4 Pro)

| Metric | 0.2.56 | 0.2.57 | Delta |
| --- | ---: | ---: | ---: |
| Initial index time | 3.6 s | 346 ms | **10× faster** |
| Steady-state RSS | 1,867 MB | 1,706 MB | −161 MB |
| git subprocesses / 30 s (steady state) | 15 | 2 | **−87%** |
| Trigram search latency (avg) | 55 ms | 53 ms | −4% |
| Word index latency (avg) | 35 ms | 32 ms | −9% |
| Recall: `webhook` | **0 hits** | **50 hits** | +50 (index fix) |
| Recall: `middleware` | 50 hits | 50 hits | same |

### Merged PRs In This Release

- [#255](https://github.com/justrach/codedb/pull/255) `fix: index growth, stale entries, atomics, git HEAD perf, snapshot robustness`
- [#239](https://github.com/justrach/codedb/pull/239) `feat: expand nuke into a full codedb uninstall`
- [#238](https://github.com/justrach/codedb/pull/238) `fix: restore help CLI build and exit behavior`
- [#236](https://github.com/justrach/codedb/pull/236) `fix: 8 MB release stack (#223) + atomic call_count in telemetry (#179)`
- [#233](https://github.com/justrach/codedb/pull/233) `fix: 10min idle timeout + poll stdin for dead clients (#148)`
- [#221](https://github.com/justrach/codedb/pull/221) `perf: worker-local initial indexing with deterministic merge`

### Issues Closed In This Release

- [#254](https://github.com/justrach/codedb/issues/254) `watcher: git HEAD fork+exec every 2s`
- [#253](https://github.com/justrach/codedb/issues/253) `readSectionBytes opens snapshot file twice`
- [#252](https://github.com/justrach/codedb/issues/252) `word_index and trigram_index diverge on OOM`
- [#251](https://github.com/justrach/codedb/issues/251) `AnyTrigramIndex mmap_overlay buffer leak`
- [#250](https://github.com/justrach/codedb/issues/250) `searchContent fallback scans all outlines`
- [#249](https://github.com/justrach/codedb/issues/249) `rewriteConfigFile not atomic`
- [#247](https://github.com/justrach/codedb/issues/247) `TrigramIndex id_to_path grows without bound`
- [#246](https://github.com/justrach/codedb/issues/246) `TrigramIndex.removeFile leaves stale path_to_id entry`
- [#227](https://github.com/justrach/codedb/issues/227) `TrigramIndex.id_to_path unbounded growth (many files)`
- [#223](https://github.com/justrach/codedb/issues/223) `Rosetta 2 stack overflow`
- [#148](https://github.com/justrach/codedb/issues/148) `MCP: 10min idle timeout + dead-client detection`

### Validation

- `zig build test` — 341/341 tests pass
- `zig build -Doptimize=ReleaseFast`
- Live benchmark against openclaw/openclaw (6,315 files)
- `zig build benchmark -- --root /path/to/repo`

## 0.2.56 - 2026-04-09

`0.2.56` is a release hotfix for the installer and self-update path after the manual `0.2.55` release.

### Hotfixes

- The install script now resolves the latest version from GitHub Releases first, then falls back to `codedb.codegraff.com/latest.json` only if GitHub is unavailable.
- `codedb update` now uses the same GitHub-first version lookup, avoiding stale release metadata during post-release propagation windows.
- The install worker lowers `/latest.json` cache lifetime from 5 minutes to 1 minute and updates its fallback version to `0.2.56`.

## 0.2.55 - 2026-04-09

`0.2.55` is a performance and reliability release focused on warm reopen, MCP startup behavior, search quality, parser correctness, and installer safety. The headline change is that warm CLI and MCP project loads now reopen persisted state directly instead of spending seconds rebuilding heap indexes.

### Highlights

- Warm snapshot reopen now restores snapshot outline/state directly, reuses persisted trigram sidecars, and avoids redundant `word.index` rewrites. This closes [#220](https://github.com/justrach/codedb/issues/220).
- `codedb_query` adds a composable MCP search pipeline so agents can do multi-step retrieval in one tool call. This closes [#168](https://github.com/justrach/codedb/issues/168).
- Search ranking now learns from query-to-open history through WAL-backed combo boosts. This closes [#195](https://github.com/justrach/codedb/issues/195).
- MCP sessions now record real client identity and expose memory diagnostics in `codedb_status`. This closes [#37](https://github.com/justrach/codedb/issues/37).
- Root policy now refuses to index the home directory itself, preventing the large MCP RAM spike reported in [#174](https://github.com/justrach/codedb/issues/174).

### Performance And Memory

- Persisted warm-reopen state now covers startup-critical outline/state data and trigram sidecars, with lazy word-index rebuild and persistence on demand.
- Repeat snapshots in the same cache location skip redundant `word.index` rewrites instead of paying full rewrite cost every time.
- `mmap_overlay` now supports zero-heap incremental updates on top of mmap-backed indexes, and allocation-pressure fallback avoids false negatives by dropping to the safe full-scan path.
- `releaseContents` now uses `clearAndFree` so content-cache bucket arrays are actually released instead of being retained.
- MCP startup refuses exact home-directory roots, preventing pathological scans of `~` and the resulting multi-gigabyte memory spikes.

#### CLI Benchmarks (`ReleaseFast`, `openclaw`, current `main` vs `v0.2.54`)

| Benchmark | 0.2.55 | 0.2.54 | Delta |
| --- | ---: | ---: | ---: |
| cold `tree` | `5.32s` | `5.29s` | `+0.6%` |
| `snapshot` | `6.53s` | `6.25s` | `+4.6%` |
| warm `tree` | `0.26s` | `6.16s` | `23.7x faster` |
| warm `search workspace` | `0.24s` | `6.14s` | `25.6x faster` |
| warm `word session` | `0.61s` | `5.99s` | `9.9x faster` |

Cold paths stay effectively flat, snapshot creation remains within the benchmark regression threshold, and warm reopen is dramatically faster.

#### MCP First Secondary-Project Call (`ReleaseFast`, `openclaw`)

| Tool | 0.2.55 | 0.2.54 | Delta |
| --- | ---: | ---: | ---: |
| `codedb_tree` | `0.076s` | `5.289s` | `69.6x faster` |
| `codedb_search` | `0.067s` | `5.278s` | `78.8x faster` |
| `codedb_word` | `0.285s` | `5.312s` | `18.6x faster` |

#### Peak RSS On `openclaw`

| Benchmark | 0.2.55 | 0.2.54 |
| --- | ---: | ---: |
| cold `tree` | `3478.8MB` | `3478.1MB` |
| warm `tree` | `192.6MB` | `3314.0MB` |
| warm `search` | `193.3MB` | `3312.9MB` |
| warm `word` | `677.1MB` | `3313.3MB` |

Warm RSS is materially lower because reopen no longer reconstructs the same large heap state on every process start.

#### Small-Corpus Sanity Pass (`codedb/src`)

| Benchmark | 0.2.55 | 0.2.54 |
| --- | ---: | ---: |
| cold `tree` | `0.045s` | `0.040s` |
| warm `tree` | `0.010s` | `0.030s` |
| warm `search` | `0.010s` | `0.030s` |
| warm `word` | `0.010s` | `0.030s` |

### Search, Ranking, And MCP

- Added `codedb_query`, a composable search pipeline for agent-driven retrieval workflows, including chained `find`, `search`, `filter`, `outline`, `read`, and `limit` stages in one call.
- `codedb_find` now retries delimiter-heavy queries more intelligently, truncates overly noisy per-file output, and skips more large generated directories by default.
- Search and file-access activity now writes to a local WAL, enabling combo-boost ranking for files that were historically opened after similar queries.
- WAL profiling now records latency and file-access patterns locally, and hashed telemetry upload preserves aggregation value without sending raw queries or file paths off-machine.
- `codedb_status` now reports client identity and index-memory diagnostics so MCP clients can see which kind of index is active and how much memory it is retaining.

### Installer, Update, And Release Reliability

- `codedb update` now downloads binaries directly from GitHub Releases instead of depending on the old CDN path.
- The install script now downloads release binaries from GitHub Releases as well.
- The `nuke` output now points at the correct install URL.
- Installer shell docs and checksum fallback behavior were tightened so release/install flows fail more predictably.

### Parser And Correctness Fixes

- Fixed five correctness bugs from [#179](https://github.com/justrach/codedb/issues/179), including large-repo mmap cache validation, ANSI escape stripping, block-comment handling, Python docstring detection, and a telemetry write-path race.
- Parsing now correctly resumes after single-line `/* ... */` comments instead of skipping subsequent code on the line.
- Added regression coverage for the `#179` parser fixes so comment/docstring edge cases stay fixed.

### Merged PRs In This Release

- [#222](https://github.com/justrach/codedb/pull/222) `perf: speed up warm snapshot reopen`
- [#204](https://github.com/justrach/codedb/pull/204) `test: regression tests for #179 parser fixes`
- [#203](https://github.com/justrach/codedb/pull/203) `fix: parse code after single-line /* */ comments`
- [#202](https://github.com/justrach/codedb/pull/202) `fix: 5 bugs from issue #179`
- [#201](https://github.com/justrach/codedb/pull/201) `fix: install script downloads from GitHub releases`
- [#200](https://github.com/justrach/codedb/pull/200) `feat: combo-boost ranking from WAL`
- [#199](https://github.com/justrach/codedb/pull/199) `feat: cloud WAL sync — hashed profiling telemetry`
- [#198](https://github.com/justrach/codedb/pull/198) `feat: WAL profiling — latency + file access logging`
- [#194](https://github.com/justrach/codedb/pull/194) `feat: search UX — auto-retry, per-file truncation, query WAL, skip dirs`
- [#192](https://github.com/justrach/codedb/pull/192) `feat: MCP client identity + memory diagnostics`
- [#191](https://github.com/justrach/codedb/pull/191) `fix: mmap_overlay fail-safe on allocation pressure`
- [#190](https://github.com/justrach/codedb/pull/190) `perf: mmap overlay pattern for zero-heap incremental updates`
- [#189](https://github.com/justrach/codedb/pull/189) `fix: releaseContents reclaims HashMap bucket memory`
- [#180](https://github.com/justrach/codedb/pull/180) `feat: composable search pipeline — codedb_query`
- [#178](https://github.com/justrach/codedb/pull/178) `fix: block home directory indexing to prevent 17GB RAM spike`
- [#177](https://github.com/justrach/codedb/pull/177) `fix: correct install URL in nuke output`
- [#176](https://github.com/justrach/codedb/pull/176) `fix: codedb update downloads directly from GitHub releases`

### Issues Closed In This Release Window

- [#220](https://github.com/justrach/codedb/issues/220) `perf: persist startup-critical indexes aggressively for mmap-backed warm reopen`
- [#195](https://github.com/justrach/codedb/issues/195) `feat: combo-boost ranking from query WAL`
- [#174](https://github.com/justrach/codedb/issues/174) `MCP mode: 17GB RAM spike when Claude Code starts in home directory`
- [#168](https://github.com/justrach/codedb/issues/168) `feat: agent-defined search — let agents compose custom search pipelines`
- [#37](https://github.com/justrach/codedb/issues/37) `Add real MCP client identity instead of hardcoding all edits to agent 1`

### Validation Used For This Release

- `SDKROOT=$(xcrun --show-sdk-path) zig build test`
- `SDKROOT=$(xcrun --show-sdk-path) zig build -Doptimize=ReleaseFast`
- `SDKROOT=$(xcrun --show-sdk-path) zig build run -- --version`
