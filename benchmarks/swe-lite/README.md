# swe-lite

A small **file-localization** benchmark for code-retrieval backends,
graded by a deterministic oracle (file-path match against the merged
upstream patch) on 4 [SWE-bench Lite](https://github.com/princeton-nlp/SWE-bench)
instances.

This folder is a sibling to [`../search-shootout`](../search-shootout),
which uses a hand-authored React corpus + Claude-as-judge. The two
benches stress different things:

| | `search-shootout/` | `swe-lite/` (this folder) |
|---|---|---|
| Corpus | facebook/react (one repo) | 3 upstream repos (flask, requests, seaborn) |
| Tasks | hand-authored | merged upstream PRs |
| Ground truth | hand-written `tasks.json` | gold patch's `changed_files` |
| Oracle | Claude-as-judge, 5-point rubric | deterministic file-path match |
| Risk | closed loop (same model family writes test + takes test) | independent ground truth |

Both views together are stronger than either alone. The
search-shootout grades *answer quality* (could the agent answer the
question well?); swe-lite grades *file-localization correctness*
(did the agent name the file the patch actually edited?).

## Files

- [`results.json`](./results.json) — frozen snapshot: tasks, per-cell
  metrics, summary. Captured 2026-05-22.
- [`replay.py`](./replay.py) — loads `results.json`, recomputes the
  per-backend averages from the raw cells, asserts the summary
  matches, and prints the dominance table.
- [`RESULTS.md`](./RESULTS.md) — the publishable read of the data:
  dominance table, the deployment-shape caveat, and what this bench
  does and does not measure.

## Quick start

```sh
python3 replay.py
```

That prints the dominance table and exits non-zero if any summary
cell disagrees with what the raw cells imply. JSON form:

```sh
python3 replay.py --json
```

## What this is NOT

- **Not a live SWE-bench runner.** `results.json` was populated by
  running each backend by hand and recording the agent's `files`
  output. The script in this folder replays that record; it does not
  re-invoke the backends.
- **Not a patch-correctness eval.** This grades "did the agent name
  the right file?", not "did the agent's patch make the failing
  tests pass?". The latter (SWE-bench's headline `pass@1`) is the
  metric that actually matters and is tracked as future work.
- **Not a statistic.** n=4 is a sanity check, not a sample.

See [`RESULTS.md`](./RESULTS.md) §Caveats for the full list.
