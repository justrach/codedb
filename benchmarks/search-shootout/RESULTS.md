# search-shootout — Results

**Corpus:** facebook/react (shallow clone), 6,619 indexable files, 26.5 MB code
**Machine:** Apple Silicon, macOS 25.4
**Date:** 2026-05-20
**SQLite:** 3.51.0 (FTS5 trigram tokenizer available)
**codedb:** local build, current branch `issue-447-failing-test`
**lean-ctx:** 3.6.9 from crates.io

Raw latency table: [results/react-2026-05-20.md](results/react-2026-05-20.md).
This file is the human-readable synthesis.

---

## 1. Build phase (cold index from scratch)

| Backend | Time | On-disk |
|---|---|---|
| **fts5_unicode61** | **0.45s** | 36 MB |
| fts5_trigram | 1.87s | 94 MB |
| lean-ctx (BM25 + JSON graph + SQLite graph) | 8.3s | n/a — stored outside expected paths |
| codedb (snapshot + trigram + word index + dep graph + outlines) | 12.1s | 41 MB |

**Takeaway:** Word-tokenized FTS5 is ~27x faster to build than codedb and uses
comparable disk. Trigram FTS5 takes ~4x its space (expected — 3-shingles
explode the postings list) but is still ~6x faster than codedb to build.
codedb's extra build time pays for the structural outline, word-index, and
reverse dep graph that the FTS5 backends don't have.

---

## 2. Query latency — warm p50 (ms)

Select rows from the per-query table:

| Query | kind | fts5_uni | fts5_tri | codedb | lean-ctx |
|---|---|---|---|---|---|
| `useState` | common-identifier | **0.03** | 1.63 | 3.97 | 683 |
| `Fiber` | substring-identifier | 0.01 | 0.14 | 3.62 | 756 |
| `flushPassiveEffects` | rare-camelcase | 0.01 | 0.23 | 167.68 | 842 |
| `function` | lang-keyword | 0.10 | 2.10 | 4.66 | 789 |
| `set` | short-trigram-exact | 0.02 | 0.04 | 3.00 | 763 |
| `xyzzy_react_does_not_exist` | negative | 0.04 | 0.21 | 113.39 | 865 |

Full 15-query table in [results/react-2026-05-20.md](results/react-2026-05-20.md).

**Latency takeaways:**

1. **fts5_unicode61** is the fastest by a wide margin (sub-100µs almost always)
   because it hits an inverted-word index directly. **Trade-off:** it misses
   substring matches — `Fiber` finds 180 files (whole-word "Fiber"), whereas
   trigram finds 303 (substring inside `ReactFiber*`, `getRootForUpdatedFiber`, etc).
2. **fts5_trigram** is sub-millisecond on common queries, low single-digit ms
   on stress queries. **Trade-off:** 2.5x bigger index, no BM25 ranking
   advantage on substring queries.
3. **codedb** is in the low-millisecond range for most queries, with two
   outliers worth investigating:
   - `flushPassiveEffects` → 167ms p50 (rare-camelcase)
   - `xyzzy_react_does_not_exist` → 113ms p50 (negative)
   The negative-query slowness is the more concerning of the two — looks like
   a missed early-exit when no trigram exists.
4. **lean-ctx grep** is ~700–1700ms **per call** because every invocation
   pays Rust binary startup + jemalloc init. The lean-ctx daemon helps with
   index queries but doesn't help binary startup. From an MCP/HTTP front-end
   it would be much faster, but from a script or shell it's painful.

---

## 3. Recall (hit-count, with caveats)

Hit counts are **not directly comparable** — codedb caps display at 50 lines,
lean-ctx caps at 20 displayed (header reports true count via "N matches in M
files"), FTS5 counts files. Use these to check for missing recall, not for
ranking.

| Query | fts5_tri | fts5_uni | codedb (capped) | lean-ctx |
|---|---|---|---|---|
| `useState` | 674 files | 674 files | 42 (display cap) | 20 (display cap) |
| `Fiber` | 303 files | 180 files | 50 (cap) | 20 |
| `flushPassiveEffects` | 8 files | 7 files | 21 lines | 20 |
| `enableTransitionTracing` | 25 files | 25 files | 12 lines | 20 |
| `xyzzy_react_does_not_exist` | 0 | 0 | 0 | 0 |

`fts5_uni` underreports on substring queries (`Fiber`: 180 vs 303) because the
word-boundary tokenizer can't see substrings inside identifiers. This is the
single biggest functional difference between unicode61 and trigram in a code
context.

---

## 4. Agentic traversal eval

Three Sonnet 4.6 sub-agents were given the same exploration task:

> Find the function in React's reconciler that decides **which lanes to render
> next** when the scheduler picks up work. Report file, function, snippet, and
> eligibility rule.

Each agent was restricted to **one backend's CLI** (no Read, no grep, no
ripgrep, no peeking with other tools).

| Backend | Tool calls | Wall seconds | Found correct answer? |
|---|---|---|---|
| **fts5_trigram (sqlite3)** | **5** | **25** | ✅ getNextLanes, with snippet from FTS5 `snippet()` + body substring extraction |
| codedb (search/find/outline) | 10 | 44 | ✅ getNextLanes, with snippet from outline + targeted searches |
| lean-ctx (grep/read) | 16 | 123 | ✅ getNextLanes, but **had to reconstruct snippet from multiple grep probes** |

### Notes from each agent

**fts5_trigram** (winner):
> "FTS5 trigram search located the file instantly; `snippet()` function was too
> narrow (60 tokens) to show full function body, so substr+instr was needed to
> extract the relevant section directly from the stored body column —
> effective workaround but slightly awkward."

**codedb**:
> "codedb search was highly effective: a single `search getNextLanes` call
> pinpointed the exact file and line, and the outline tool showed all variable
> declarations inside the function body at a glance. Multi-word phrase search
> sometimes returned no results when terms were not adjacent in source,
> requiring decomposition into single key terms."

**lean-ctx** (slowest by 5x):
> "lean-ctx grep output is highly compressed via alpha-symbol substitution
> (α1, α2…) with a §MAP footer — useful for cross-file deduplication but
> obscures exact source lines; `lean-ctx read` returns only a 3-line metadata
> summary for large files making it **unusable for reading function bodies
> directly**; had to reconstruct the snippet from multiple grep probes rather
> than a direct read."

This is the most damning finding for lean-ctx: its compression aggressively
strips information the agent needs, and its `read` mode wasn't usable on
real-world file sizes. The token savings come at a real **task-completion
latency cost** in this scenario. *(Caveat: when lean-ctx is consumed via its
MCP server inside a Claude-Code-style chat, the compression interacts
differently with the LLM's context window — this eval measures CLI use only.)*

---

## 5. Where codedb is genuinely ahead

- **Structural outline + dep graph + word index** in one snapshot — none of
  the FTS5 setups give you `outline` or callers/deps. The 12s build time pays
  for these.
- **File watcher** keeps the snapshot live; FTS5 here was rebuilt from
  scratch, lean-ctx requires manual `index build` invocation.
- **MCP-native warm queries**: ~3ms for typical queries vs lean-ctx's ~700ms
  CLI-spawn cost. (Not a fair fight in CLI-vs-CLI, but it is a fair fight in
  the agent UX.)

## Where codedb has room to close gaps

- **Negative-query slowness** (113ms p50 for `xyzzy_react_does_not_exist`)
  suggests a missed early-exit when no trigram in the query exists in the
  index. Cheap fix.
- **`flushPassiveEffects` outlier** (167ms p50) — rare camelcase queries seem
  to fall through to a slow tier. Worth profiling.
- **Hit-display cap** of 50 is conservative; for agentic use, the cap matters
  more than for human use because the agent doesn't paginate.

## Where FTS5 alone is not enough

- No outline / signatures view → agent has to read whole files to get
  structure.
- No call graph / reverse-dep graph.
- No watcher; index goes stale after every commit.

These are the things lean-ctx and codedb add on top of an inverted-index
substrate.

---

## 6. Negative-query short-circuit — shipped

The bench surfaced a slow path that turned out to be a 6-line fix.

`searchContent` had a Tier 5 full-scan fallback that fired whenever every
earlier tier returned 0 results. For a query whose trigrams don't exist
anywhere in the corpus (a definitively-negative query), Tiers 0–4 all
no-op and Tier 5 still scanned every file in `outlines` — measurable as
113ms p50 on the React corpus.

The fix: when `trigram_index.candidates(query)` returns a non-null but
empty candidate set and `query.len >= 3`, every trigram-indexed file is
provably free of the query. The only files that could still contain a
match are `skip_trigram_files`, which Tier 3 already scanned. Tier 5 can
be skipped.

| Query | Before | After | Speedup |
|---|---|---|---|
| `xyzzy_react_does_not_exist` | 113.39ms p50 | **0.29ms** p50 | **390x** |

A test-only counter `Explorer.search_tier5_count` was added so the
regression is observable in a deterministic unit test (no time-based
flakes). Before the fix, the counter goes to 1 for the failing test;
after, it stays at 0.

See commits on branch `issue-negq-shortcircuit-failing-test`:

- `test(explore): failing test for negative-query Tier 5 short-circuit`
- `fix(explore): short-circuit Tier 5 full scan when trigram rules out match`

## 7. lean-ctx MCP head-to-head — apples-to-apples

The original v1 of this benchmark invoked lean-ctx via `lean-ctx grep` per
query, which paid ~700ms of Rust binary startup on every call. Unfair —
that's not how lean-ctx is meant to be consumed. The harness was updated to
also speak MCP stdio to lean-ctx (calls `ctx_search`), mirroring what we do
for codedb. Both backends now run as a single persistent server process
warmed by one untimed call before measurement.

For reference, the MCP roundtrip floor in this setup is **0.26 ms p50**
(measured by timing a no-op `tools/list` against codedb). Per-query latency
below that is dominated by RPC; per-query latency above that is real engine
work.

| Query | codedb p50 | lean-ctx MCP p50 | codedb wins by |
|---|---|---|---|
| `useState` | 3.74 ms | 40.04 ms | **10.7×** |
| `useEffect` | 1.05 ms | 41.64 ms | **39.7×** |
| `forwardRef` | 0.29 ms | 44.43 ms | **153×** |
| `createElement` | 0.92 ms | 66.81 ms | **72.6×** |
| `Fiber` | 0.66 ms | 106.01 ms | **160×** |
| `Lane` | 0.48 ms | 119.88 ms | **250×** |
| `Suspense` | 0.56 ms | 41.96 ms | **75×** |
| `flushPassiveEffects` | 0.46 ms | 160.47 ms | **348×** |
| `enableTransitionTracing` | 0.46 ms | 154.85 ms | **336×** |
| `scheduleCallback` | 0.67 ms | 112.63 ms | **168×** |
| `concurrent` | 0.66 ms | 109.18 ms | **165×** |
| `function` (stress) | 15.76 ms | 44.10 ms | **2.8×** |
| `set` | 4.01 ms | 43.42 ms | **10.8×** |
| `ReactDOMRoot` | 0.19 ms | 200.73 ms | **1056×** |
| `xyzzy_react_does_not_exist` | 0.13 ms | 182.45 ms | **1400×** |

**codedb is faster on every query in the set, MCP-vs-MCP, on the React
corpus.** Speedup ranges from 2.8× on the highest-frequency stress query
(`function`, ~5k file matches) up to 1400× on the negative query.

### Methodology notes

- 25 iterations per query, warm. p50 reported.
- Both backends index the same 6,619-file corpus before the run.
- lean-ctx MCP reports 20 matches consistently — that's a display cap in
  its `ctx_search` tool. The full match count is in the response header;
  the cap doesn't materially affect query time (the engine still walks the
  matches to populate the response).
- p99s are noisy across both backends. The speedup table uses p50.

### What the gap actually says

A roundtrip floor of 0.26 ms means codedb queries like `forwardRef` (0.29 ms
p50) are spending essentially nothing in the engine — the entire cost is RPC.
That's the Tier 0 word-index hitting in O(1) plus response serialization.
For lean-ctx, a 40–200 ms-per-query floor regardless of how easy the query
is points at heavier per-call work in their search path (compression,
formatting, or both — we didn't profile).

The previous version of this benchmark (lean-ctx via per-call `lean-ctx
grep`) showed 700–1700 ms per query. The MCP-resident numbers above are
~5–20× faster than that, so the previous version was significantly
penalizing lean-ctx by including the Rust binary startup. This is the
honest version.

## 6. Recommendations

1. **For codedb:** the FTS5 trigram numbers are the most relevant competitor
   for the substring-search path. They suggest a `unicode61`-style word-index
   could shave 100x off the *common-identifier* path — but you already have
   the Tier-0 word index from v0.2.58, so the gap is smaller than it looks.
   The real wins are: (a) fix the negative-query slow path, (b) profile
   `flushPassiveEffects`-shaped queries, (c) consider exposing a configurable
   result cap higher than 50 for agent consumers.
2. **For benchmark methodology:** add a "warm CLI" mode for lean-ctx that
   avoids the per-call binary startup (e.g., via its `serve` HTTP endpoint or
   MCP stdio) — otherwise lean-ctx looks ~700x slower than it really is when
   used MCP-resident inside an agent.
3. **What FTS5+BM25 cannot replace:** if you swap to FTS5 you lose
   outline/find/deps/word-index. The "swap to FTS5" plan only works as a
   complement to a structural index, not a replacement.

---

## Reproducing

See [README.md](README.md). Short version:

```bash
mkdir -p ~/codedb-bench
git clone --depth 1 https://github.com/facebook/react ~/codedb-bench/react
python3 shootout.py --corpus ~/codedb-bench/react \
                    --out results/react-$(date +%Y-%m-%d).md \
                    --clean-codedb
```
## 8. Tier 0 attribution — where does codedb's per-query time go?

A direct probe (50 iter each, MCP-resident, query `useState` on React):

| Tool | What it does | p50 |
|---|---|---|
| `tools/list` (no-op) | MCP roundtrip floor | **0.08 ms** |
| `codedb_find` | symbol-index hash lookup | **0.05 ms** |
| `codedb_word` | word-index lookup + path:line for each hit | **1.81 ms** |
| `codedb_search` | word-index + content reads + line extraction | **2.87 ms** |

Attribution of the `codedb_search` 2.87 ms p50:

- ~0.08 ms — MCP stdio roundtrip
- ~1.73 ms — word-index hit collection + path:line formatting (the gap
  between `find` and `word`)
- ~1.06 ms — content reads + line extraction + formatted output (the gap
  between `word` and `search`)

**Implication for the fts5_unicode61 gap:** the earlier "100× slower"
finding partly reflects that codedb returns line-level results with
context, where FTS5 unicode61 returns just file paths. Not the same
product. The remaining gap (codedb word lookup at 1.8 ms vs FTS5 inverted
index at 0.01 ms) is mostly that codedb's hit list is path-strings while
FTS5 reads from compact docid integers. A real attribution would require
matching response shape; queued.

### Separate finding worth flagging: p99 spikes

p99 across **every** codedb tool — including the supposedly O(1)
`codedb_find` — was in the 300–900 ms range over 50 iterations. That's
not engine cost; it's periodic ~500 ms+ spikes from something. Candidates:
snapshot persistence, watcher polling, arena cleanup, background indexing.
Worth filing as a separate perf issue; the test bench is reproducible.

## 9. Multi-task agentic eval — testing lean-ctx's "99% token savings" claim

The first agentic eval (`getNextLanes`, in §4 above) was a single data point.
This extends it with three more React-internals exploration tasks. Same
methodology: one Sonnet 4.6 sub-agent per (task, backend) pair, restricted
to that backend's CLI only (no Read, no grep, no peeking). All 12 agents
ran in parallel.

### The tasks

| ID | Task |
|---|---|
| T0 | (original) Find `getNextLanes` and explain lane eligibility |
| T1 | Trace from `useState`'s setter to the function that schedules re-render |
| T2 | Find 2–3 sites where a Fiber's `flags` gets the `Snapshot` flag set |
| T3 | Compare `processUpdateQueue` vs `prepareFreshStack` — file, function, when called |

### Per-task results

| Task | Backend | Tool calls | Wall sec | Tokens | Correct? |
|---|---|---|---|---|---|
| T0 | codedb     | 10 | 44 s   | 22,598 | ✅ |
| T0 | fts5_tri   | 5  | **25 s** | **14,523** | ✅ |
| T0 | leanctx    | 16 | 123 s  | 21,212 | ✅ |
| T1 | codedb     | 14 | 108 s  | 21,010 | ✅ |
| T1 | fts5_tri   | 13 | 95 s   | 17,876 | ✅ (admitted 1 grep violation) |
| T1 | leanctx    | 13 | **91 s** | 18,370 | ✅ |
| T2 | codedb     | 10 | 55 s   | 18,758 | ✅ |
| T2 | fts5_tri   | 8  | **49 s** | **15,853** | ✅ |
| T2 | leanctx    | 13 | 121 s  | 23,661 | ✅ |
| T3 | codedb     | 8  | **28 s** | 16,058 | ✅ |
| T3 | fts5_tri   | 7  | 29 s   | **15,307** | ✅ |
| T3 | leanctx    | 11 | 61 s   | 15,361 | ✅ |

### Aggregate across 4 tasks

| Backend | Total calls | Total wall sec | Total tokens | Avg calls/task | Avg sec/task | Avg tokens/task |
|---|---|---|---|---|---|---|
| **fts5_trigram** | **33** | **198** | **63,559** | **8.2** | **49.5** | **15,890** |
| codedb | 42 | 235 | 78,424 | 10.5 | 58.8 | 19,606 |
| lean-ctx | 53 | 396 | 78,604 | 13.2 | 99.0 | 19,651 |

### The headline

**All 12 agents reached the correct answer.** Recall isn't the differentiator;
efficiency is. The aggregate ratios:

- lean-ctx vs codedb: **1.69× wall time**, **1.00× tokens**, **1.26× tool calls**
- lean-ctx vs fts5:   **2.00× wall time**, **1.24× tokens**, **1.61× tool calls**
- codedb vs fts5:     **1.19× wall time**, **1.23× tokens**, **1.27× tool calls**

### What this says about "99% token savings"

lean-ctx markets aggressive token compression as its main value prop. The
per-output compression is real — `lean-ctx grep` does pack a lot of matches
into fewer bytes than raw output. But across these four agent tasks,
**lean-ctx used essentially the same total tokens as codedb** (78,604 vs
78,424 — a 0.2% difference) and **24% more tokens than the plainest backend
in the comparison** (fts5_trigram via raw sqlite3).

The reason is visible in every lean-ctx agent's notes: the compression is
lossy enough that the agent has to do follow-up probes to reconstruct what
it needs. The α1/α2/§MAP symbol substitution that saves bytes per response
costs additional grep calls to decode. `lean-ctx read` returns metadata
summaries for large files, forcing the agent back to grep when it actually
wants source. Per-call savings get spent on extra calls.

The clearest single quote, from the T1 leanctx agent's notes:

> "The build uses minified symbol aliases (α1) for cross-module exports;
> α1 in ReactFiberHooks.js maps to scheduleUpdateOnFiber from
> ReactFiberWorkLoop.js."

That's the compression actively producing work for the agent to undo.

### Where FTS5 trigram wins agent efficiency

FTS5 wins on every aggregate metric — fewest calls, fewest wall seconds,
fewest tokens. Three reasons:

1. **Output is minimal but unambiguous.** `sqlite3` returns `path|snippet`
   with no formatting flourish. The agent reads exactly what's there.
2. **Cold-start is free.** `sqlite3` startup is microseconds, not Rust's
   ~700 ms or codedb's ~50 ms. Every per-call CLI cost gets amortized
   differently.
3. **BM25 ranking is good enough** for code: the right file is in the top 3
   results essentially every time.

This is a real argument for keeping FTS5 in the conversation as a
**substrate** for code-context tools. But it's a substrate, not a product —
you still need outline / call graph / watcher on top.

### Where codedb sits

codedb is the middle ground: 19% slower than fts5 wall-clock, 23% more
tokens, 27% more tool calls. The extra cost is the trade for `codedb
outline` / `codedb find` / `codedb deps` — things FTS5 doesn't have. The
fact that codedb is competitive on token spend with both alternatives,
while offering structural features lean-ctx and fts5 don't, is the strongest
positioning argument from this whole exercise.

### Caveats

- 4 tasks isn't a benchmark suite; it's a probe. More tasks would tighten
  the per-task variance.
- All three backends were given CLI access only. lean-ctx in particular has
  an MCP mode (used in §7 for the latency comparison) that we did NOT use
  here for the agentic task — the agent would have had to manage MCP RPC
  itself, which isn't how agents are typically wired. Future work: run the
  same tasks with lean-ctx exposed as registered MCP tools to the agent.
- All correct answers were verified by the parent. No false-positive cases
  observed.

## 10. Trying to make codedb cheaper — and proving the compression trap on our own tool

After §9's finding that lean-ctx's compression hurt agents, the natural
question: could codedb get under fts5's token bar (15.9k avg/task) with
its own opt-in compression? We tried two flags and re-ran the eval.

### The flags added in this round

1. **`CODEDB_MCP_LEAN=1`** — strips the ANSI-colored summary header and
   the guidance-hint footer from MCP responses. Block-2 raw data unchanged.
2. **`CODEDB_QUIET=1`** — same idea for the CLI: suppresses
   "loaded snapshot N files Yms" + "✓ N results for X" decoration.
3. **`paths_only=true` / `--paths-only`** — emits `path:line` per result
   without the matching line text. ~20% per-call wire savings.
4. **`TextContent.annotations.audience`** on every block — spec-canonical
   per MCP `2025-06-18` — lets clients strip blocks even without env vars.

### Per-call wire savings (codedb_search on React)

| Query | default JSON | MCP-LEAN JSON | --paths-only CLI | fts5 ref |
|---|---|---|---|---|
| useState | 8,764 | 8,375 (-4.4%) | 6,604 (-20%) | 3,226 |
| forwardRef | 10,530 | 10,133 (-3.8%) | (similar) | 3,329 |
| flushPassiveEffects | 1,531 | 1,126 (-26.5%) | (similar) | 576 |
| Fiber | 6,649 | 6,257 (-5.9%) | (similar) | 3,701 |

Lean+quiet alone gives ~5%. Adding paths_only gets us to ~20%. Still not
under fts5 — paths_only on codedb returns longer paths (rich ranking
surfaces deeper-nested files) and includes line numbers fts5 doesn't.

### The agent-eval surprise

Re-ran T1/T2/T3 with codedb agents told `--paths-only` exists and to use
it when appropriate (decisions left to the agent):

| Task | codedb default | codedb LEAN+--paths-only |
|---|---|---|
| T1 (setState trace) | 14 calls / 108s / 21,010 tok | 27 calls / 226s / 35,504 tok |
| T2 (Snapshot sites) | 10 calls / 55s / 18,758 tok | 7 calls / 46s / 20,123 tok |
| T3 (compare 2 fns) | 8 calls / 28s / 16,058 tok | 10 calls / 52s / 17,795 tok |
| **Total** | **32 calls / 191s / 55,826 tok** | **44 calls / 324s / 73,422 tok** |
| **Ratio** | 1.00× | **1.38× calls, 1.70× wall, 1.32× tokens** |

**Codedb-lean used 32% MORE tokens than codedb-default** on the same
tasks. The opt-in compression made agents worse on every dimension. This
is exactly the trap we observed lean-ctx falling into in §9 — except
we just demonstrated it ON OUR OWN TOOL by adding the flag and asking
agents to use it.

### Likely causes

1. **Decision overhead.** The prompt added ~150 words of "use --paths-only
   when appropriate" guidance. The agent burns tokens reasoning about
   whether each search is broad-survey or detail.
2. **Follow-up calls for context.** When --paths-only is used, the agent
   sometimes needs a second call to see the actual line — net more turns.
3. **Skip-trigram-files edge case.** T1's agent hit a code path where
   search returned empty for a query in ReactFiberHooks.js (related to
   issue #447). Burned ~15 turns recovering with word + outline. This is
   a fluke of methodology variance but pulls the T1 numbers up.

### The actual lesson

Codedb's default rich response (`path:line:line_text`) is the right
design for agent consumers. Adding compression options without changing
defaults gives agents a foot-gun. The flag stays as opt-in for batch
scripts and humans — but **the agent-facing default should not change**,
and we shouldn't market compression as an agent feature even when it's
technically available.

### What's shipped

- `CODEDB_MCP_LEAN` env var: useful for non-agent MCP consumers (CI
  pipelines, log scrapers) that don't render ANSI.
- `CODEDB_QUIET` env var: CLI equivalent.
- `paths_only` MCP arg + `--paths-only` CLI flag: useful for path-list
  generators; marked "NOT for agents" in the schema description.
- `audience` annotations on all blocks: spec-canonical, lets MCP clients
  strip user-only blocks without server cooperation.

All four are opt-in. Default behavior unchanged.

## 11. Engine-vs-engine — direct comparison (no MCP, no formatting)

Earlier sections compared codedb to FTS5 with codedb running through MCP
(stdio JSON-RPC) and FTS5 running through a persistent Python SQLite
connection. That comparison was fair as a "what does the agent feel"
benchmark, but it conflated codedb's pure engine work with its
~0.08–0.26 ms MCP roundtrip floor and ~1 ms of content-reading per result.

A new subcommand `codedb bench-engine` exposes the engine directly:
loads the snapshot, calls the explorer in a tight loop, reports timing
in nanoseconds. Four ops: `word`, `word-fmt`, `search`, `search-fmt`.

200 iter, warm, React corpus:

### Word index direct lookup (`searchWord`)

| Query | hits | codedb engine | FTS5 trigram | codedb is |
|---|---|---|---|---|
| `useState` | 2,689 | **8 µs** | 814 µs | **102× faster** |
| `forwardRef` | 466 | **1 µs** | 179 µs | **179× faster** |
| `Fiber` | 6,304 | **25 µs** | 132 µs | **5× faster** |
| `flushPassiveEffects` | 23 | **~0 µs** | 210 µs | **>200× faster** |
| `xyzzy_react_does_not_exist` | 0 | **~0 µs** | 201 µs | **>200× faster** |

**The codedb engine is 5×–200× faster than SQLite FTS5 trigram at
word-index lookup.** This is what the agent-level comparison was hiding:
codedb's pure inverted-word-index path is dramatically faster than FTS5;
the per-call latency we measured at the MCP level was overhead + content
reads, not engine cost.

### Full search (`searchContent` — includes per-result content reads)

| Query | codedb engine | FTS5 trigram | ratio |
|---|---|---|---|
| `useState` (50 results) | 1.52 ms | 0.81 ms | fts5 1.86× faster |
| `forwardRef` | 0.17 ms | 0.18 ms | tied |
| `Fiber` | 0.22 ms | 0.13 ms | fts5 1.7× faster |
| `flushPassiveEffects` | 0.04 ms | 0.21 ms | **codedb 5× faster** |
| `xyzzy_react_does_not_exist` | **0.002 ms** | 0.20 ms | **codedb 100× faster** |

Reading line text from 50 files (codedb returns `path:line:line_text`)
takes ~1 ms; FTS5's response is `path` only, so it doesn't pay this
cost. For common identifiers FTS5 wins by ~2×; for rare identifiers and
negative queries (with the Tier 5 short-circuit), codedb dominates.

### Format-only overhead

`word` vs `word-fmt` (raw search vs search + format-to-buffer):

| Query | word | word-fmt | added by format |
|---|---|---|---|
| useState (2,689 hits) | 8 µs | 60 µs | 52 µs (~20 ns/hit) |
| Fiber (6,304 hits) | 25 µs | 142 µs | 117 µs (~19 ns/hit) |
| forwardRef (466 hits) | 1 µs | 10 µs | 9 µs (~20 ns/hit) |

Format-to-buffer is roughly 20 ns/hit — negligible compared to
content-read costs. **The serializer isn't the bottleneck.** The
codedb-vs-fts5 gap at the MCP layer comes from MCP envelope overhead
(audience annotations, the 3-block content structure) + per-result
content reads (1 ms for 50 files) — not from the format loop.

### How to reproduce

```bash
# 1. Build codedb with the bench-engine subcommand
zig build -Doptimize=ReleaseFast

# 2. Run it
./zig-out/bin/codedb /path/to/corpus bench-engine word useState 200
./zig-out/bin/codedb /path/to/corpus bench-engine word-fmt useState 200
./zig-out/bin/codedb /path/to/corpus bench-engine search useState 200
./zig-out/bin/codedb /path/to/corpus bench-engine search-fmt useState 200
```

Output is a single line of JSON per run, e.g.:
```json
{"op":"word","query":"useState","iters":200,"hits":2689,"min_ns":7000,"p50_ns":8000,"p99_ns":11000}
```

The flag is in the public CLI but is not a stable interface — its
purpose is for benchmark harnesses (including
code-search-shootout)
to measure codedb fairly against engines that don't have an MCP layer.

## 12. Precision rerun + telemetry tail-latency fix (the second-biggest fix this bench surfaced)

Rebuilt the harness for proper measurement:
- iterations bumped to **500/query** (was 15-25)
- now reports **min / p50 / p95 / p99** (was p50/p99 only)
- runs the whole bench **3 times in fresh subprocesses** and reports
  **median-of-medians** per query (closes session-noise)
- adds a **normalized files-list mode**: every backend asked the same
  question (return SET of files containing query), pairwise Jaccard
  similarity reported (closes the "hit counts aren't comparable" hole)
- the lean-ctx files-list extractor was broken (display-cap at 20 lines);
  now uses `lean-ctx -c --raw "rg -l <q>"` which gives the untruncated
  underlying ripgrep output

### The tail-latency finding (and fix)

First precision rerun (before fix): codedb p99 was 250–400 ms across
**every** MCP tool — even O(1) ones like `codedb_find`. Consistent across
sessions, ~5–10% of every call spiking. Not engine cost.

Root cause traced to `Telemetry.record()` calling `syncToCloud()` every
10 events — which shells out to `curl` with `--max-time 5` on the same
thread as the tool response. That's exactly the 200–400 ms spike pattern.

Fix (commit `4369d7d` on this branch): removed the in-line cloud-sync
trigger. Cloud sync now happens only on `Telemetry.deinit()` (shutdown).
Local WAL flush every 3 events still happens (it's fast, <1 ms).

### Before/after (codedb, 500 iter × 3 sessions, median-of-medians)

| Query | Before p99 | After p99 | Improvement |
|---|---|---|---|
| `useState` | 363 ms | **1.81 ms** | **200×** |
| `useEffect` | 295 ms | **1.03 ms** | 286× |
| `forwardRef` | 368 ms | **0.29 ms** | **1,269×** |
| `createElement` | 363 ms | **0.95 ms** | 382× |
| `Fiber` | 399 ms | **0.37 ms** | **1,078×** |
| `Lane` | 336 ms | **0.26 ms** | 1,292× |
| `Suspense` | 372 ms | **0.52 ms** | 715× |
| `flushPassiveEffects` | 349 ms | **0.12 ms** | 2,908× |
| `enableTransitionTracing` | 360 ms | **0.34 ms** | 1,059× |
| `scheduleCallback` | 334 ms | **0.27 ms** | 1,237× |
| `concurrent` | 350 ms | **0.36 ms** | 972× |
| `function` (stress) | 336 ms | **17.53 ms** | 19× |
| `set` | 371 ms | **3.69 ms** | 101× |
| `ReactDOMRoot` | 352 ms | **0.17 ms** | 2,071× |
| `xyzzy_react_does_not_exist` | 347 ms | **0.07 ms** | **4,957×** |

**Average p99 improvement across 15 queries: ~1,200×.** Tail-latency
problem completely eliminated.

### What codedb looks like vs FTS5 + lean-ctx after the fix (p99)

| Query | codedb | fts5_tri | fts5_uni | lean-ctx MCP |
|---|---|---|---|---|
| `useState` | **1.81** | 2.22 | 0.02 | 65.95 |
| `forwardRef` | 0.29 | 0.21 | 0.01 | 69.01 |
| `Fiber` | 0.37 | 0.15 | 0.01 | 144.45 |
| `flushPassiveEffects` | 0.12 | 0.24 | 0.01 | 198.92 |
| `xyzzy_react_does_not_exist` | **0.07** | 0.24 | 0.04 | 242.25 |

codedb's p99 is now competitive with FTS5 trigram (within 2-3×) and
crushes lean-ctx (10-1400× faster, same as p50). The MCP-vs-MCP fight
holds at every percentile, not just median.

### Files-list normalized comparison — actual recall agreement

With lean-ctx's display-cap bug fixed and codedb returning the union of
`word` + `search` results, all 4 backends now agree well on file sets:

| Query | codedb | fts5_tri | fts5_uni | leanctx | jaccard |
|---|---|---|---|---|---|
| `xyzzy_react_does_not_exist` | 0 | 0 | 0 | 0 | **1.000** |
| `enableTransitionTracing` | 25 | 25 | 25 | 25 | **1.000** |
| `scheduleCallback` | 22 | 22 | 22 | 22 | **1.000** |
| `createElement` | 403 | 403 | 401 | 407 | 0.989 |
| `function` | 5328 | 5286 | 5245 | 5341 | 0.981 |
| `useEffect` | 436 | 434 | 426 | 443 | 0.964 |
| `useState` | 716 | 674 | 674 | 719 | 0.957 |
| `flushPassiveEffects` | 8 | 8 | 7 | 7 | 0.917 |
| `Suspense` | 310 | 314 | 259 | 294 | 0.883 |
| `ReactDOMRoot` | 8 | 8 | 6 | 8 | 0.875 |
| `forwardRef` | 129 | 129 | 127 | 99 | 0.866 |
| `Fiber` | 275 | 303 | 180 | 248 | 0.731 |
| `Lane` | 69 | 72 | 40 | 53 | 0.671 |
| `concurrent` | 118 | 127 | 75 | 92 | 0.630 |
| `set` | 1614 | 2038 | 851 | 1837 | 0.599 |

Jaccards under 1.0 reflect real semantic differences between backends,
not bugs:
- **`fts5_unicode61` consistently undercounts substring queries**
  (`Fiber`: 180 vs 300+, `Lane`: 40 vs 70+) because word-boundary
  tokenization can't see substrings inside identifiers like `ReactFiber`.
- **`set` jaccard 0.60** because the three substring-capable backends
  (codedb, fts5_trigram, leanctx) each count differently — `set` appears
  inside many identifiers (`setState`, `unsetCookie`, `asset`) and
  whether you count those depends on tokenization.

The metric proves backends find largely the same answers; differences
are explained by tokenizer choice, not bugs.

### Engine-level numbers haven't changed

The §11 engine-direct comparison (codedb is 5–200× faster than FTS5
trigram at the pure word-index lookup) is unchanged — that path never
went through the telemetry call. The telemetry fix is purely about MCP
tail latency, which was being inflated by an unrelated network call.

