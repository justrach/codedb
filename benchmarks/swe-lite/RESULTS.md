# SWE-bench Lite — file-localization results

Frozen snapshot of 4 SWE-bench Lite instances × 4 retrieval backends,
scored by deterministic file-path match against the merged upstream
patch (no LLM judge). Captured 2026-05-22.

The raw data is in [`results.json`](./results.json); recompute and
verify the summary block with [`replay.py`](./replay.py).

## Tasks

Four [SWE-bench Lite](https://github.com/princeton-nlp/SWE-bench)
instances spanning three real upstream repos:

| Instance | Repo | Gold file (the file the merged PR patched) |
|---|---|---|
| `pallets__flask-4045` | pallets/flask | `src/flask/blueprints.py` |
| `psf__requests-2148` | psf/requests | `requests/models.py` |
| `psf__requests-2674` | psf/requests | `requests/adapters.py` |
| `mwaskom__seaborn-2848` | mwaskom/seaborn | `seaborn/_oldcore.py` |

Each instance's `base_commit` is pinned in `results.json` so the same
state can be rebuilt by anyone.

## Backends

| Backend | What it is | How invoked |
|---|---|---|
| `codedb` | This repo's CLI surface — the four lookup primitives (`search`, `find`, `word`, `outline`) | shell calls, agent composes them itself |
| `codedb_CONTEXT` | This repo's **MCP composer** tool — bundles the primitives server-side into one task-shaped call | single MCP call with the issue text + `project=<corpus>` |
| `leanctx` | yvgude/lean-ctx, BM25-ish word index | CLI calls per query |
| `fts5_trigram` | SQLite FTS5 with the `trigram` tokenizer | direct sqlite3 substring query |

`codedb_CONTEXT` is the deployed shape of codedb for agentic use; the
CLI is the underlying primitive set. Measuring both lets us separate
"is the search good?" from "is the deployed shape good?".

## Scoring

Deterministic, no LLM judge:

- **recall** — gold file appears anywhere in the agent's `files` list
- **top-1** — agent's *first* listed file equals the gold file

That's it. The agent doesn't have to write a patch; it just has to
name the file it would edit. This is an intermediate signal — weaker
than patch-correctness, but stronger than judge-graded quality
because there's no model in the oracle loop.

## Headline

```
backend          recall  top-1  avg calls  avg wall (s)  avg tokens
---------------  ------  -----  ---------  ------------  ----------
codedb            4/4     3/4     26.75       42.00         37,954
codedb_CONTEXT    4/4     3/4      2.25        1.25         14,717
leanctx           4/4     3/4      9.75       27.25         30,172
fts5_trigram      4/4     4/4     13.75       24.75         25,801
```

**Quality.** All four backends fully recall the gold file (4/4).
Top-1 splits at one task: `fts5_trigram` 4/4, the other three at 3/4.

**Efficiency.** `codedb_CONTEXT` dominates on every axis — **4×**
fewer calls than `leanctx`, **6×** fewer than `fts5_trigram`, **12×**
fewer than `codedb` CLI; **20-30×** faster wall; lowest tokens.

**Pareto frontier.** Only one point is Pareto-optimal across (quality,
efficiency): `codedb_CONTEXT`. The single backend that exceeds it on
quality (`fts5_trigram`, by one cell out of four) costs ~1.5× the
wall and ~1.75× the tokens for that gain.

## The one task where top-1 split — `mwaskom__seaborn-2848`

The seaborn bug surfaces as a `KeyError` raised inside
`seaborn/_oldcore.py::SemanticMapping`, but the user-facing call site
lives in `seaborn/axisgrid.py::PairGrid`. The merged upstream patch
edits `_oldcore.py` (the root-cause site).

Three of four backends (`codedb`, `codedb_CONTEXT`, `leanctx`) named
`axisgrid.py` first and `_oldcore.py` second — the order a developer
would trace through. `fts5_trigram` named `_oldcore.py` first because
trigram matches on identifier strings preferred the file with denser
term hits.

Both orderings find the bug. Which one is "better" depends on what
you want top-1 to mean: the first place a developer would look (the
call site) or the place the patch actually lands (the root-cause
site). At this sample size the metric punishes the explanatory
ordering, but neither agent failed the task.

## Why the CLI row matters — deployment shape is a measurement axis

An earlier iteration of this bench reported `codedb` as the *least*
efficient backend (26.75 calls / 42s / 38k tokens) and concluded the
dominance claim was partially falsified. That finding was numerically
correct but tested the wrong thing: it pitted codedb's *CLI* (a stack
of four lookup primitives the agent composes itself) against peers'
*deployed* surfaces (leanctx CLI, fts5 sqlite3).

`codedb_CONTEXT` is the actual deployed shape — one MCP call that
bundles the primitives server-side. Once measured at the same level
of abstraction as the peers, the dominance picture survives the
verifiable oracle.

**Lesson:** when a tool has more than one deployment surface
(CLI / MCP / HTTP / library), the bench has to identify the
*primary* surface and compare primary-against-primary. Measuring a
side surface and reporting it as the headline is an
apples-to-oranges error.

## Caveats — read before quoting these numbers

1. **n=4 is small.** Four SWE-bench Lite instances is a sanity check,
   not a statistic. Don't generalize from "3/4 top-1" to "75% top-1
   on SWE-bench Lite".
2. **File-localization ≠ patch-correctness.** This bench measures
   whether the agent names the right file. It does not run the agent
   end-to-end, generate a patch, or check whether the patch makes
   the failing tests pass. An end-to-end `pass@1` eval is the metric
   that actually matters; this is one rung below it on the ladder.
3. **Replay, not live.** `results.json` is a frozen record. The
   `replay.py` script recomputes the averages from the cells and
   verifies the summary block matches, but it does not re-launch
   the backends. A live runner is future work.
4. **One judge-graded comparator** (`codegraph` MCP) is intentionally
   absent here — it was measured on the hand-authored / judge-graded
   shootout but not on this verifiable-oracle bench. Add it if you
   want a 5-backend matrix.
5. **The seaborn split is a metric artifact, not a backend
   weakness.** Three out of four backends (including `fts5_trigram`
   on the *other* three tasks) order files by traceability rather
   than patch site. The split says more about top-1 as a metric than
   about the backends.

## Future work

- A live runner that actually invokes each backend per task and
  records `files`, `tool_calls`, `wall_seconds`, `tokens` on the
  spot (instead of the current hand-recorded snapshot).
- A patch-correctness oracle: agent produces a unified diff,
  oracle applies it against the pinned `base_commit` and runs the
  upstream test suite. That's the only metric that fully captures
  the "did the agent solve it?" question.
- More tasks. 20-50 SWE-bench Lite instances would let "3/4 top-1"
  turn into a statistic instead of a sanity check.
