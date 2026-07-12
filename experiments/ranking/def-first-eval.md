# Def-first ranking eval — methodology & result

Harness: [`scripts/rank-eval.py`](../../scripts/rank-eval.py). Change it validated:
**PR #665** (`codedb_search` now ranks the *defining* file first).

## What it measures

For a set of symbol-shaped queries, does the file that actually **defines** the
symbol rank at the top of `codedb_search`? Two metrics over the gold set:

- **def-file-#1** — the def file is the first result.
- **def-file-top3** — the def file is in the top 3.

Gold cases are `(query, expected_def_file)` pairs, deliberately weighted toward
symbols whose def file has a basename that does *not* match the query (e.g.
`searchContentRanked` → `src/explore.zig`) — the case plain hit-count + basename
ranking gets wrong.

## The confound this harness exists to kill: snapshot drift

codedb indexes the current project and persists a snapshot under `$HOME/.codedb`.
If you eval against the **codedb repo itself**, editing the ranking code
re-indexes the corpus *mid-measurement*, so the score moves for reasons that have
nothing to do with your change. The first def-first attempt looked like an 8→7
**regression** — and reproduced 8→7 with the code **reverted**. That was 100%
drift, not the code.

The fix (what "pinned" means):

1. **Frozen corpus** — a representative slice of the repo (`src/` + `CHANGELOG.md`
   + `experiments/`) copied *out* of the repo into a temp dir. Never edited, so
   the index is stable across builds.
2. **Isolated `$HOME`** — a throwaway home dir, wiped per binary, so each build
   re-indexes the *identical bytes* from scratch. The only variable across an A/B
   is the binary.

Result: **deterministic** — repeated runs of the same binary are byte-identical,
so any delta is attributable to the code.

## Gotchas (encoded in the harness)

- **Temp-root guard** — the corpus lives under a temp dir, which codedb refuses to
  index by default, so the child gets `CODEDB_ALLOW_TEMP=1`.
- **Async snapshot load** — a `tools/call` fired immediately after `initialize`
  hits `state=loading_snapshot` and returns 0 results. The harness spaces them in
  the pipe (`printf init; sleep 6; printf query; sleep 2`) and pre-warms once with
  `codedb . index`.
- **Debug is fine** — result *order* is version-independent; only indexing speed
  differs. Build once with `zig build`; no ReleaseFast needed for a ranking A/B.
- **`CODEDB_NO_CLI_DAEMON=1`** — no shared warm daemon, so each run is
  self-contained and can't inherit another run's state.

## Run it

```sh
zig build                                   # Debug build is fine for ranking
python3 scripts/rank-eval.py                # self-freezes a corpus, evals zig-out/bin/codedb

# A/B two builds against ONE frozen corpus:
python3 scripts/rank-eval.py --binary /tmp/codedb.baseline --corpus /tmp/frozen
python3 scripts/rank-eval.py --binary /tmp/codedb.head     --corpus /tmp/frozen
```

Custom gold set: `--cases mycases.json` where the file is a JSON list of
`[query, expected_def_file]` pairs.

## Result (PR #665)

Same frozen corpus, Debug builds, only the binary differs:

| binary   | def-file-#1 | def-file-top3 |
|----------|-------------|---------------|
| baseline | 8/10        | 9/10          |
| def-first| **9/10**    | 9/10          |

`searchContentRanked` moved pos 3 → **#1**; **zero regressions**. The change:
tier0 gets a `defines` flag (via `fileDefinesSymbol`) and `+20` to the rank prior
for defining files — same result *set*, better *order*. Regression test:
`def-first: renderPlainSearch ranks the defining file above higher-count mentions`
in `src/test_search.zig` (fails on baseline, passes with the fix).

## Known holdout / next pass

`renderPlainSearch` as a query stays at pos 4: it bails from the tier0 fast path
to `searchContentAuto`, a **different** path where docs aren't demoted
(`CHANGELOG.md` / `experiments/**/*.md` outrank the def) and this boost doesn't
apply. Two follow-ups for the next def-first pass:

1. Apply def-first + doc demotion in the `searchContentAuto` fallback too.
2. Surface the def *line* within the file (today the def file floats up but the
   render still shows the file's first hit line, often a mention, not the def).
