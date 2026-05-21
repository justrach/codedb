# Takeaways from mnemon-dev/mnemon

**Reviewed:** 2026-05-21 — [mnemon-dev/mnemon](https://github.com/mnemon-dev/mnemon) at HEAD
**Author:** justrach (review session notes, not a roadmap commitment)

## What mnemon is

Persistent cross-session memory for LLM agents. Single Go binary + SQLite WAL. Four-graph knowledge store (temporal / entity / causal / semantic), intent-aware recall, importance-with-decay, automatic deduplication. Integrates with Claude Code, Codex, OpenClaw, Nanobot, NanoClaw via a markdown-installable harness.

272 stars, Go, MIT, actively maintained.

**The category is different from codedb.** Mnemon is *agent memory* (insights, decisions, context across sessions). Codedb is *code search* (sub-ms index over a single project's source tree). They're stack-complementary, like ACE in the previous spec at `docs/design/ace-integration.md`.

## The design idea worth stealing

### 1. LLM-Supervised vs LLM-Embedded — same pattern codedb already uses

> "Most memory tools embed their own LLM inside the pipeline. Mnemon takes a different approach: **your host LLM is the supervisor.** The binary handles deterministic computation (storage, graph indexing, search, decay); the LLM makes judgment calls (what to remember, how to link, when to forget). No middleman, no extra inference cost."

This is exactly the shape codedb has: codedb does the deterministic index work (trigram / word / outline / deps), and the agent makes judgment calls about what to query for. The shape is validated — mnemon explicitly contrasts it with Mem0/Letta (LLM-embedded) and Claude Code Memory (file injection).

**Takeaway:** keep the LLM-Supervised pattern as codedb's identifying architecture. Resist the temptation to bake an LLM into codedb (e.g., for the reader.md regeneration loop — leave that to the host agent).

### 2. Intent-native protocol — `remember / link / recall`

Mnemon's three primary verbs are:
- `remember` (write)
- `link` (graph edge)
- `recall` (read)

…not `INSERT`, `UPSERT`, `SELECT`. The argument is that command names should map to the LLM's cognitive vocabulary so the agent can use them without translation.

Codedb has a mix today: `codedb_search` and `codedb_outline` are operation-named; `codedb_callers` and `codedb_context` lean cognition-named.

**Takeaway:** when adding new MCP tools, prefer cognition-named verbs over operation-named ones. E.g. a future "who-calls-this-API-from-outside-this-package" tool should be `codedb_external_callers` (intent) not `codedb_xref_filter` (operation).

### 3. Effective Importance (EI) decay formula

```
EI = base_weight(importance) × access_factor × decay_factor × edge_factor

base_weight:   imp 5 → 1.0, … 1 → 0.15
access_factor: max(1.0, log(1 + access_count))
decay_factor:  0.5 ^ (days_since_access / 30)  — half-life of 30 days
edge_factor:   1.0 + 0.1 × min(edge_count, 5)  — up to +0.5
```

Auto-pruning fires at >1000 active insights; immunity for importance ≥4 or access_count ≥3.

**Takeaway for codedb's reader.md staleness model:** today reader.md is binary `ready | stale | missing | malformed`. A graceful-decay analog would be:

```
freshness = 1.0 × decay(time_since_generation) × structural_match(source_hash_partial)

structural_match: 1.0 if hash exact match, 0.9 if same files but small edits,
                  0.5 if same files with significant edits, 0.0 if files renamed/removed
```

This would let reader.md remain "useful but aging" for a while instead of cliff-edging into stale on the first whitespace change. **Not a current priority** — the binary hash is simpler and conservative — but worth keeping in the design folder.

### 4. Hybrid extraction (regex + tech dictionary + LLM-assisted)

For entity extraction (binding insights to common terms like `Qdrant`, `Kubernetes`, `React`), mnemon uses:

1. Regex patterns (CamelCase, ALL_CAPS, file paths, URLs)
2. A 200+ entry technical dictionary
3. User-provided `--entities` flag
4. LLM-assisted causal-edge candidacy

Codedb's `extractContextCandidates` (in `handleContext`) already does (1) via CamelCase / snake_case / quoted-string heuristics. It could borrow (2) — a small technical-term dictionary would catch keywords like `WSGI`, `JIT`, `IPC`, `TLS` that the current pattern misses.

**Takeaway:** consider augmenting the keyword extractor with a small (~100-entry) curated tech dictionary. Cheap, deterministic, no LLM call. File as a P3 enhancement.

### 5. Lifecycle hooks — Prime / Remind / Nudge / Compact

Mnemon installs hooks at four phases:

| phase | trigger | mnemon action |
|---|---|---|
| Prime | session start | make skill, guideline, active store visible |
| Remind | user prompt arrives | decide whether recall could change this task |
| Nudge | mid-conversation | suggest writing important moments |
| Compact | before context compression | persist what would be lost |

**Takeaway for codedb:** ship a `codedb hooks install` mode that writes `.claude/hooks.json` entries for:
- `SessionStart`: print `codedb status` + reader.md staleness summary
- `Stop`: if reader.md was marked stale during the session, prompt the agent to regenerate before context-compact

Closes critical-review I06 (`codedb_status` doesn't surface reader.md state). Small, concrete, follow-up.

### 6. Skill + Guideline split

Mnemon ships **two** markdown files for agent integration:
- `SKILL.md` — the commands (what)
- `GUIDELINE.md` — the judgment (when, why)

The split is intentional: SKILL teaches syntax, GUIDELINE teaches taste. Pasting both into an agent's prompt is the markdown-installable harness.

Codedb has `docs/skills.md` (similar to SKILL.md) but no separate GUIDELINE. A short `docs/guideline.md` could codify things like:
- When to use `codedb_context` vs `codedb_search`
- When the reader.md prepend is helping vs noise (and how to tell)
- How to interpret "stale" hints
- When to write a new `.codedb/reader.md` vs let the existing one stay

**Takeaway:** add `docs/guideline.md` as a v0.2.5818 follow-up. ~150 lines max.

## What NOT to steal

- **Knowledge graph storage** (the four-graph model). Code is structural — it already has graphs (`codedb_callers`, `codedb_deps`). Adding a temporal/causal/semantic memory graph on top is the wrong shape for a code-search tool.
- **Auto-pruning + soft-delete**. Codedb's snapshot is a snapshot of the current source tree; "pruning" old code paths doesn't make sense.
- **The `remember / link / recall` API verbatim**. Codedb doesn't write user-authored facts; the agent doesn't author code memories via codedb. Skip.

## Concrete v0.2.5818 candidates (ranked by ROI)

1. **Lifecycle hooks installer** — `codedb hooks install` writes `.claude/hooks.json` with SessionStart + Stop checks. Closes I06. ~50 LOC + a tiny JSON template. **High value, low risk.**
2. **`docs/guideline.md`** — separate from skills.md, teaches when/why. **Pure docs.**
3. **Tech-dictionary keyword extraction** — augment `extractContextCandidates` with a 100-entry dict for terms regex misses. **~30 LOC.**
4. **Decay-style reader.md staleness** — design only for now; the binary hash protocol is fine for v0. **Design doc, no code.**

None of these are urgent. Tracking them here so the option stays open.
