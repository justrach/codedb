# Eval tasks — reader.md A/B

Each task is run by a Sonnet 4.6 sub-agent restricted to codedb v0.2.5816 CLI (`/tmp/codedb-fixes/zig-out/bin/codedb`). Each task is run twice per corpus: **without** reader.md (control) and **with** reader.md prepended to the agent's prompt (treatment).

We measure: tool_calls, wall_seconds, total tokens, found_correct_answer (rubric/5 by a judge agent).

## Tasks

### T1 — flask: "Where do I implement a global pre-request hook, and what's the canonical pattern?"

**Expected answer must mention:** `before_request` decorator on `Flask` or `Blueprint`, registered against `before_request_funcs`, executed by `full_dispatch_request` / `preprocess_request`. File: `src/flask/sansio/scaffold.py` (decorator) + `src/flask/app.py` (execution).

### T2 — regex: "Where is the regex pattern compiled into the internal NFA/DFA representation? Identify the file + entry function driving compilation."

**Expected answer must mention:** `regex-syntax` for AST → HIR, `regex-automata` for HIR → NFA → DFA. Entry: `regex_automata::meta::Regex::new` or the high-level `regex::Regex::new`. The pipeline goes through `Parser::parse`, `Translator::translate`, `Compiler::new`/`build`.

### T3 — react: "How does React decide WHEN to flush passive effects (`useEffect`) vs sync effects (`useLayoutEffect`)? Identify the function and the queueing mechanism."

**Expected answer must mention:** `flushPassiveEffects` in `packages/react-reconciler/src/ReactFiberWorkLoop.js`, queue is `rootWithPendingPassiveEffects`, scheduled via `scheduleCallback(NormalPriority, …)` after commit. Sync effects run inside `commitMutationEffects` synchronously.

## Conditions

### Control (no reader.md)

Sub-agent prompt:
> Use ONLY `codedb` CLI at /tmp/codedb-fixes/zig-out/bin/codedb against `<corpus>`. Answer the task. Restricted from all other tools.

### Treatment (with reader.md)

Sub-agent prompt:
> Below is the project's reader.md (auto-generated codebase map). Use it to orient before running queries. Then use ONLY `codedb` CLI at /tmp/codedb-fixes/zig-out/bin/codedb against `<corpus>` to find specifics.
>
> ```
> <full reader.md contents>
> ```
>
> [task]

## Metrics collected per run

```json
{
  "corpus": "flask",
  "task_id": "T1",
  "condition": "with_reader" | "control",
  "tool_calls": <int>,
  "wall_seconds": <float>,
  "answer": "<text>",
  "found_correct": true|false,
  "quality_rubric_5": <int 1-5, judged separately>
}
```

## Hypothesis

reader.md cuts tokens-per-task by **≥20%** and tool calls by **≥30%** while preserving quality (rubric ≥4.0/5 in both conditions).

If wins are smaller, reader.md may still be useful for token-budget-tight scenarios (Haiku, 16K context) but not a default win.

If wins are negative (reader.md slows the agent down), the experiment refutes the hypothesis — orientation is not pre-computable for this task shape.
