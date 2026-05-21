# ACE × codedb — integration spec

**Status:** Design draft. Not implemented.
**Author:** spec drafted 2026-05-21 in response to roadmap question "should codedb compete with kayba-ai/agentic-context-engine?"
**Decision:** No — they're different categories. This doc sketches how codedb could be a **tool that ACE wraps**, not a competitor.

## Background

- **codedb** indexes source code (symbols, files, deps). Returns file:line snippets in milliseconds. Used by the agent's *search* step.
- **ACE** ([kayba-ai/agentic-context-engine](https://github.com/kayba-ai/agentic-context-engine)) maintains a per-project "Skillbook" of strategies learned from prior runs. Used by the agent's *thinking* step.

They're stack-complementary. ACE in the brain, codedb in the eyes.

The interesting question isn't "which wins" but: **could codedb_context's ranking benefit from ACE-style learning?** Currently it uses hand-coded heuristics:

- `+5` if file contains a symbol definition for any extracted keyword
- `−3` for test / spec / fixture paths
- `−2` for doc paths
- tiebreak by raw hit count

These are sensible but invariant — they can't learn that *for the flask codebase, prefer `src/flask/sansio/` over `tests/`* or that *for this internal monorepo, prefer `packages/core/`*.

## Proposal — a small skillbook layer on top of `codedb_context`

The smallest viable surface that earns its complexity:

### 1. Persistent storage

A per-project `~/.codedb/projects/<hash>/skillbook.json`:

```jsonc
{
  "version": 1,
  "project_root": "/Users/user/flask",
  "updated_at": "2026-05-21T10:00:00Z",
  "skills": [
    {
      "id": "sk_001",
      "kind": "path_boost",
      "pattern": "src/flask/sansio/**",
      "weight": 4.0,
      "reason": "user accepted snippets from these paths 8/10 times for routing/middleware tasks",
      "evidence": ["task_12", "task_18", "task_31"],
      "decay_at": "2026-08-21T10:00:00Z"
    },
    {
      "id": "sk_002",
      "kind": "path_penalty",
      "pattern": "tests/test_basic.py",
      "weight": -2.0,
      "reason": "low signal; never selected for production paths"
    },
    {
      "id": "sk_003",
      "kind": "keyword_synonym",
      "from": "auth middleware",
      "to": ["before_request", "decorator", "g.user"],
      "reason": "in this codebase 'auth middleware' is implemented via before_request hooks"
    }
  ]
}
```

Three skill kinds initially:
- **`path_boost`** / **`path_penalty`**: glob-matched additive weight on top of the static heuristics
- **`keyword_synonym`**: expand the keyword set the composer extracts from the task

### 2. Read path — `codedb_context` consults the skillbook

`handleContext` already extracts keywords + ranks files. After the static-heuristic score is computed for each candidate file, layer skillbook adjustments:

```zig
const skillbook = explorer.loadSkillbook(project_root) catch null;
if (skillbook) |sb| {
    for (sb.path_boosts) |pb| {
        if (globMatch(pb.pattern, file.path)) file.score += pb.weight;
    }
    for (sb.path_penalties) |pp| {
        if (globMatch(pp.pattern, file.path)) file.score += pp.weight;
    }
}
// Keyword expansion happens earlier, before symbol-definition lookup.
```

The change is bounded: ~50 LOC in `handleContext`, plus a `skillbook.zig` module (~200 LOC for parse / glob-match / decay).

### 3. Write path — out of scope for core codedb

This is where ACE belongs. codedb deliberately **does not** include:
- Trace collection
- Reflection / strategy synthesis
- An LLM client

Instead, codedb exposes a write endpoint:

```
codedb_skillbook_update(skills: [...], project?: <path>)
```

ACE (or any other learner) calls this with synthesized skills. The skillbook becomes the *boundary* between learning and serving — codedb stays focused on milliseconds-per-query, ACE handles the slow, expensive reflection loop.

### 4. Trace collection — already partially there

codedb already logs `codedb_search` / `codedb_find` / `codedb_word` queries to a WAL (see `mcp.handleCall` L991-996, `logQuery`). The natural extension: also log which file:line snippets were SELECTED by the agent (i.e., subsequently passed to `codedb_read` / `codedb_edit`).

That selection signal is what ACE needs to reflect on. The trace surface stays in codedb; the reflection stays in ACE.

## Why this earns its complexity

| | without skillbook | with skillbook |
|---|---|---|
| Cold codebase | hand-coded heuristics — works | hand-coded heuristics — same |
| After 50 tasks | hand-coded heuristics — same | learned path/keyword skills compound |
| Wrong default for a project | persists forever | demoted via repeated negative selection signal |
| Per-team conventions | invisible | encodable as a skill |

The cost: ~250 LOC + a JSON file. The risk: skillbook accumulates noise. Mitigations:
- **Decay**: every skill has `decay_at`; expired skills are pruned on read
- **Cap**: max 50 skills per project; lowest-weight evicted first
- **Audit**: `codedb_skillbook_list` + `codedb_skillbook_reset` MCP tools so a human can inspect/wipe

## Why this is NOT codedb's job

codedb's value is determinism + milliseconds. The reflection loop is:
- Slow (LLM round-trips)
- Stochastic (depends on the LLM)
- Opinionated (what counts as "success"?)

ACE owns all three. codedb owns the deterministic, sub-ms read/write of the skillbook. Clean separation.

## What this is not

- **Not RAG with embeddings.** No vector store, no semantic similarity. Keyword + glob + score deltas only.
- **Not user-facing.** The agent reads the skillbook implicitly via `codedb_context`. No CLI for end-users.
- **Not a feedback loop in codedb.** No reflection, no LLM calls. Pure read of an externally-maintained file.

## Acceptance criteria for a v0

1. `codedb_context` is at most 10% slower with skillbook present (no perf regression on top of the [v0.2.5815 fixes](../../README.md))
2. With a 20-skill skillbook, react `getNextLanes` task quality (rubric/5) stays ≥ 4.5 (i.e., skillbook doesn't break the baseline)
3. With a synthetic skillbook crafted from 50 mock tasks, quality on those tasks improves by ≥ 0.5 rubric points
4. Skillbook reset (`codedb_skillbook_reset`) returns the system to pre-learning baseline

(3) is the proof-it-pays test. (1), (2), (4) are guardrails.

## Open questions

- **Skill conflict resolution.** If `sk_001` boosts `src/**` and `sk_002` penalizes `src/legacy/**`, which wins for `src/legacy/foo.py`? Proposal: sum the weights.
- **Per-task-shape skills.** Should skills be tagged with task fingerprints ("for refactor tasks, prefer …") or always project-global? v0 stays project-global.
- **Multi-language projects.** Does a `path_boost` apply across the whole repo or just per-language? v0 applies globally; let the user encode language-specificity in the glob.

## Sequencing if this gets prioritized

1. **Spike: skillbook reader + glob-matcher** (~1 day, no MCP changes; just `loadSkillbook` + unit tests)
2. **Wire into `handleContext` behind a feature flag** (`CODEDB_ACE=1`)
3. **Add `codedb_skillbook_update` / `_list` / `_reset` MCP tools** (~1 day)
4. **Eval harness**: synthetic skillbook of 20 hand-crafted skills, measure context quality on 16-task shootout corpus
5. **Demo integration** with [kayba-ai/agentic-context-engine](https://github.com/kayba-ai/agentic-context-engine) — write a small ACE adapter that calls `codedb_skillbook_update`

Estimated total: 4-6 engineering days for a v0 that earns real eval data.

## What this doc commits to

Nothing yet. This is a design draft to keep the option open. Filing it so:
- Future "should we add learning?" questions can point here
- If the option is taken, the implementer has a starting shape
- If the option is rejected, the reason can be recorded against this concrete proposal rather than a vague "what if"
