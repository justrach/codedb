# swe-lite

A small **file-localization** hypothesis snapshot for code-retrieval
backends, graded by a deterministic oracle (file-path match against
the merged upstream patch) on 4 [SWE-bench Lite](https://github.com/princeton-nlp/SWE-bench)
instances × 6 backends.

This folder is a sibling to [`../search-shootout`](../search-shootout),
which uses a hand-authored React corpus + LLM judge. The two views
stress different things:

| | `search-shootout/` | `swe-lite/` (this folder) |
|---|---|---|
| Corpus | facebook/react (one repo) | 3 upstream repos (flask, requests, seaborn) |
| Tasks | hand-authored | merged upstream PRs |
| Ground truth | hand-written `tasks.json` | gold patch's `changed_files` |
| Oracle | LLM-as-judge, 5-point rubric | deterministic file-path match |
| Risk | closed loop (same model family writes test + takes test) | independent ground truth |

Both views together are stronger than either alone. The
search-shootout grades *answer quality*; swe-lite grades
*file-localization correctness*.

## Files

- [`results.json`](./results.json) — frozen snapshot: 4 tasks ×
  6 backends, per-cell metrics, summary, hypothesis.
- [`replay.py`](./replay.py) — loads `results.json`, recomputes the
  per-backend averages from the raw cells, asserts the summary
  matches, and prints the dominance table (with `*` annotation
  for tool-output-only measurements).
- [`RESULTS.md`](./RESULTS.md) — the publishable read of the data:
  dominance table, what jumps out, the measurement caveat, and the
  falsifiable hypothesis this snapshot supports.

## Quick start

```sh
python3 replay.py
```

Prints the matrix and exits non-zero if any summary cell disagrees
with what the raw cells imply. JSON form:

```sh
python3 replay.py --json
```

## What this is NOT

- **Not a live SWE-bench runner.** Four of six rows (`codedb`,
  `codedb_CONTEXT`, `leanctx`, `fts5_trigram`) were populated by
  running each backend through an LLM agent loop and recording the
  agent's `files` output; codegraph rows were freshly measured here
  using a fixed query plan (subprocess only, no LLM in the loop).
  See `RESULTS.md` §Measurement caveat.
- **Not a patch-correctness eval.** Grades "did the agent name the
  right file?", not "did the agent's patch make the failing tests
  pass?". The latter is tracked as future work.
- **Not a statistic.** n=4 is a sanity check, not a sample. The
  doc is framed as a hypothesis snapshot, not a settled claim.

See [`RESULTS.md`](./RESULTS.md) for the full list of caveats and
the hypothesis statement.
