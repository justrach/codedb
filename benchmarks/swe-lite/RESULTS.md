# SWE-bench Lite — file-localization, six backends

Small file-localization snapshot: 4 [SWE-bench Lite](https://github.com/princeton-nlp/SWE-bench)
instances × 6 retrieval backends, graded by a deterministic oracle
(does the agent name the file that the merged upstream patch actually
edits?). Captured 2026-05-22. Codegraph rows re-verified at v0.9.3
(released the same day) — file lists are byte-identical to v0.7.10,
so the quality picture below isn't a version artifact.

This is published as a **hypothesis snapshot**, not a settled
dominance claim — n=4 is too small for statistics, and not all rows
were measured the same way (see [Measurement caveat](#measurement-caveat)).
The raw data is in [`results.json`](./results.json); recompute and
verify the summary block with [`replay.py`](./replay.py).

## Tasks

| Instance | Repo | Gold file (the file the merged PR patched) |
|---|---|---|
| `pallets__flask-4045` | pallets/flask | `src/flask/blueprints.py` |
| `psf__requests-2148` | psf/requests | `requests/models.py` |
| `psf__requests-2674` | psf/requests | `requests/adapters.py` |
| `mwaskom__seaborn-2848` | mwaskom/seaborn | `seaborn/_oldcore.py` |

Each instance's `base_commit` is pinned in `results.json` so the
state can be rebuilt.

## Backends

Six backends, three of which ship in two surfaces (a primitive
"search" surface and a task-shaped "build context for this query"
surface). Both surfaces are reported separately when they exist —
mixing a tool's primitive surface against another tool's deployed
surface gives a misleading read.

| Backend | What it is | Surface |
|---|---|---|
| `codedb` | This repo. Zig trigram + word index. | primitive (`search`, `find`, `word`, `outline`) |
| `codedb_CONTEXT` | This repo's MCP composer | task-shaped (single call) |
| `leanctx` | yvgude/lean-ctx, BM25-ish word index | primitive |
| `fts5_trigram` | SQLite FTS5 with `trigram` tokenizer | primitive |
| `codegraph` | TS+SQLite code-graph (`codegraph query`) | primitive |
| `codegraph_CONTEXT` | codegraph's task composer (`codegraph context`) | task-shaped |

## Oracle

Deterministic, no LLM judge:

- **recall** — gold file appears anywhere in the agent's `files` list
- **top-1** — the agent's *first* listed file equals the gold file

The agent doesn't have to write a patch — only name the file it
would edit. This is an intermediate signal: weaker than patch
correctness, but stronger than judge-graded quality because there's
no model in the oracle loop.

## Headline

```
backend              recall  top-1  avg calls  avg wall (s)  avg tokens
-------------------  ------  -----  ---------  ------------  ----------
codedb               4/4     3/4    26.75      42.00         37,954
codedb_CONTEXT       4/4     3/4     2.25       1.25         14,716
leanctx              4/4     3/4     9.75      27.25         30,172
fts5_trigram         4/4     4/4    13.75      24.75         25,800
codegraph *          4/4     3/4     3.00       0.17          1,981
codegraph_CONTEXT *  2/4     2/4     1.00       0.11          4,146
```

*\* Codegraph rows use a different measurement methodology — see
[Measurement caveat](#measurement-caveat) before reading the
efficiency cells.*

## What jumps out

**Quality is mostly uniform.** Five of six backends fully recall the
gold file (4/4). Top-1 splits across one task (`seaborn-2848`,
discussed below): `fts5_trigram` 4/4, four others tied at 3/4.

**`codegraph_CONTEXT` is the lone quality outlier.** It misses both
`requests` tasks because the issue text mentions urllib3 keywords
("socket", "urllib3", "DecodeError"), and the composer surfaces
urllib3 internals over the requests-layer wrapper where the patch
actually lands. This is the only cell where graph-relevance signal
diverges sharply from patch-site relevance in this sample.

**Among the apples-to-apples (agent-loop) rows, `codedb_CONTEXT`
sits at the efficient end of the matched-quality cluster.** It
matches the 3/4-top-1 cluster (codedb / leanctx / codedb_CONTEXT)
on quality and is the cheapest in that cluster across calls, wall,
and tokens. `fts5_trigram` is the only backend that gets the
top-1-4/4 cell — at ~20× the wall time of `codedb_CONTEXT`.

## The one task where top-1 split — `mwaskom__seaborn-2848`

The seaborn bug surfaces as a `KeyError` raised inside
`seaborn/_oldcore.py::SemanticMapping`, but the user-facing call site
lives in `seaborn/axisgrid.py::PairGrid`. The merged upstream patch
edits `_oldcore.py` (the root-cause site).

Four backends (`codedb`, `codedb_CONTEXT`, `leanctx`, `codegraph`)
named `axisgrid.py` first and `_oldcore.py` second — the order a
developer would trace through. `fts5_trigram` and
`codegraph_CONTEXT` named `_oldcore.py` first. Both orderings find
the bug; "top-1 correctness" is really asking *which* ordering you
want — the first file a developer would look at (call site) or the
file the patch actually lands in (root cause).

## Measurement caveat

Codegraph rows (`codegraph` and `codegraph_CONTEXT`) were measured
differently from the other four rows:

- **Calls / wall:** codegraph numbers reflect subprocess invocations
  driven by a fixed 3-query plan (primitive surface) or a single
  `codegraph context` call (task surface). The other four rows
  reflect a full LLM-driven agent loop that decides which queries
  to run.
- **Tokens:** codegraph numbers are stdout bytes / 4 (just the
  tool's output). The other four rows include the agent's full
  context (system prompt + tool defs + tool outputs + LLM
  reasoning).

Under a comparable LLM-driven loop, codegraph's tool_calls would
likely rise (an LLM tends to make 5–15 queries when exploring) and
tokens would rise to the agent-context level (~10–20× current
values). What's NOT expected to change much: recall and top-1,
since those depend on which files codegraph surfaces — and the file
sets above are what codegraph actually returned for those queries.

The takeaway is that codegraph's **quality** cells are directly
comparable to other backends, and its **efficiency** cells are not.
This is annotated in the table with `*` and in `results.json` via
the `measurement: tool_output_only` field.

## Other caveats — read before quoting these numbers

1. **n=4 is small.** Four SWE-bench Lite instances is a sanity
   check, not a statistic. Don't read "3/4 top-1" as "75% top-1 on
   SWE-bench Lite".
2. **File-localization ≠ patch-correctness.** This bench grades
   whether the agent names the right file. It does not run the
   agent end-to-end, generate a patch, or check whether the patch
   makes the failing tests pass. An end-to-end `pass@1` eval is the
   metric that actually matters; this is one rung below it on the
   ladder.
3. **Snapshot, not live.** `results.json` is a frozen record.
   `replay.py` recomputes the averages from the cells and verifies
   the summary block matches, but does not re-launch the four
   non-codegraph backends. Codegraph rows *were* freshly measured
   while preparing this snapshot.
4. **The seaborn top-1 split is a metric artifact, not a backend
   weakness.** Four of six backends order files by traceability
   rather than by patch site. The split says more about top-1 as a
   metric than about any individual backend.

## Hypothesis

Stated as something to falsify, not declare:

> Among compared backends, **`codedb_CONTEXT`** is the cheapest
> backend in the matched-quality cluster (3/4 top-1, 4/4 recall) on
> file-localization. **`fts5_trigram`** is the only backend that
> currently reaches 4/4 top-1, and it does so at ~20× the wall time
> of `codedb_CONTEXT`. The expected next-step result, if a live
> agent-loop runner is built and codegraph is re-measured under
> matched methodology, is: **codegraph (primitive) joins the
> 3/4-top-1 cluster at agent-loop call counts somewhere between
> codedb_CONTEXT's 2.25 and leanctx's 9.75, with comparable
> tokens.**

This hypothesis is **falsifiable** by:

- Building a live LLM-loop runner and re-measuring codegraph at
  agent-loop methodology.
- Expanding to 20–50 SWE-bench Lite instances — at that sample size
  the quality differences (or lack of them) become statistical.
- Adding a patch-correctness oracle (apply the agent's patch
  against the pinned `base_commit` and run the failing tests).

Until any of those hold, treat the headline as **directional**, not
quantitative.

## Future work

- A live runner that actually invokes each backend per task with a
  consistent LLM agent loop, so all rows are measured the same way.
- A patch-correctness oracle.
- More tasks.
- Quality cells under the existing oracle are robust; everything
  else is a calibration exercise.
