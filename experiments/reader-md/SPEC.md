# `reader.md` — agent-authored, hash-stable codebase map

**Status:** Experimental. Prototype only — no codedb runtime changes yet.
**Goal:** Give a fresh agent one-shot orientation on an unfamiliar codebase, so it skips 3-5 exploratory `codedb_search` / `codedb_outline` calls per task.

## Premise

`codedb_context` already returns a task-shaped composite (keywords + symbol-defs + ranked files + ±2-line snippets). It works well for *narrow* tasks. It doesn't help with *orientation* — "what kind of project is this, how is it laid out, what are the load-bearing modules."

Other tools fake this with:
- aider: `.aider.chat.history.md` (conversation log; not a map)
- codegraph: per-repo `wiki` (auto-generated, often verbose)
- claude/cursor: `CLAUDE.md` / `.cursor/rules` (hand-written by humans)

The proposal: a **hash-stable, agent-authored, ≤200-LOC markdown file** at `.codedb/reader.md`. Codedb prepends it to `codedb_context` responses when the source hash still matches. When the hash drifts (the load-bearing files changed enough), codedb returns a "stale: regenerate" signal so the next agent run produces a fresh `reader.md`.

## File format

```markdown
---
schema_version: 1
generated_at: 2026-05-21T14:30:00Z
generator: "claude-sonnet-4-6"
source_hash: "blake2b:abc123…"
source_files:
  - src/flask/app.py
  - src/flask/blueprints.py
  - src/flask/wrappers.py
  - src/flask/sansio/scaffold.py
  - src/flask/sansio/app.py
loc_budget: 200
loc_actual: 187
---

# flask

Python micro-web-framework. Single-import, decorator-driven routing,
WSGI underneath, blueprints for modular composition.

## Layout

- `src/flask/` — public API
  - `app.py` — `Flask` class, the WSGI callable
  - `blueprints.py` — `Blueprint` for modular routing
  - `wrappers.py` — `Request` / `Response` (subclass werkzeug)
  - `sansio/` — sync/async-agnostic core (scaffold + app)
- `tests/` — pytest, integration tests in `test_basic.py`
- `examples/tutorial/` — reference app

## Key concepts

- **Application context** (`g`, `current_app`): thread-locals via
  werkzeug LocalStack…

[…trimmed for spec; full body ≤200 LOC]
```

### Frontmatter fields

- **`schema_version`**: bump if codedb's parser changes shape
- **`generated_at`**: ISO 8601; informational only
- **`generator`**: model name; informational
- **`source_hash`**: blake2b (16-byte digest, 32 hex chars) of `concat(sort(source_files), open(f).read() for f in source_files)`. Recomputed on every codedb scan; mismatch ⇒ stale. See § Hash protocol below for the canonical algorithm.
- **`source_files`**: list of paths the reader summarizes — **THE hash is over these specific files**, NOT the whole repo. The agent picks them when generating.
- **`loc_budget`** / **`loc_actual`**: enforces terseness. Codedb rejects files over `loc_budget * 1.2` to prevent drift.

## Lifecycle

```
        ┌───────────────────────┐
        │  codedb_context call  │
        └──────────┬────────────┘
                   ▼
   ┌──────────────────────────────┐
   │  read .codedb/reader.md      │
   │  + verify source_hash        │
   └────┬──────────────┬──────────┘
        │              │
    valid│      stale/missing
        ▼              ▼
   ┌────────┐   ┌────────────────────────────┐
   │ PREPEND│   │ emit signal:               │
   │ to ctx │   │ "no reader.md — please     │
   │ output │   │  generate by analysing     │
   └────────┘   │  these files: <hot list>"  │
                └────────────────────────────┘
                          │
                  agent writes reader.md
                          │
                          ▼
                  codedb stores blake2b hash
```

## Why this earns the LOC

| | without reader.md | with reader.md |
|---|---|---|
| Cold task on unfamiliar repo | 5–10 exploratory `codedb_search` / `outline` calls | 0–1 — the map is already in context |
| Tokens consumed | ~8–20 KB of snippets across calls | ~3–5 KB once + targeted snippets |
| Time-to-first-correct-answer | 30–120 s | 10–40 s expected |
| Convention drift | invisible to agent | encoded in the "Conventions" section |

The cost: 1× agent run to write it (~$0.05 per repo); regenerate only when load-bearing files drift.

## What goes in the body (recommended sections)

1. **One-paragraph orientation** — what the project IS in 2-3 sentences
2. **Layout** — top-level directory tree with one-line annotations (≤30 lines)
3. **Key concepts** — domain vocabulary the codebase uses unusually (≤30 lines)
4. **Entry points** — "I want to: [add a route / write a test / extend the model] → start in <file>" (≤20 lines)
5. **Conventions** — naming, file organization, anti-patterns

Stop sections:
- ❌ No code snippets (codedb_context already returns those)
- ❌ No API docs (read the source)
- ❌ No "this project uses Python" (obvious from file extensions)
- ❌ No exhaustive symbol lists (codedb already has those)

## Hash protocol

```python
import hashlib
def source_hash(files: list[str]) -> str:
    h = hashlib.blake2b(digest_size=16)
    for f in sorted(files):
        h.update(f.encode())
        h.update(b"\0")
        with open(f, "rb") as fp:
            h.update(fp.read())
        h.update(b"\0\0")
    return "blake2b:" + h.hexdigest()
```

- Sorted file list (order-stable)
- File content concatenated with null separators
- 16-byte blake2b digest (32 hex chars)

The hash is **deterministic on the same input set** — so the agent can verify its own work before writing, and codedb can verify on every scan.

## Sizing rationale

200 LOC ≈ 4-6 KB of text ≈ 1-1.5K tokens. That's:
- 1× a typical `codedb_search` response
- 10% of a 16K context window for Claude Haiku
- 0.6% of a 256K context window for Claude Opus

So even on small-context models, prepending reader.md to every `codedb_context` response is a near-free augmentation.

## Open questions for the prototype

- **Source-file selection**: who decides which files go in `source_files`? Initial heuristic: most-imported-from + most-recently-modified, ≤10 files.
- **Hash drift sensitivity**: if `src/app.py` changes by 1 line, do we mark stale? Proposal: yes — content hash is binary. Most updates are bigger; the small-change case is rare.
- **Multi-language repos**: one `reader.md` or one per top-level dir? v0 says one.
- **Concurrency**: two agents writing reader.md simultaneously. v0 uses a `.codedb/reader.md.lock` file or last-write-wins.

## What this experiment proves (or disproves)

If reader.md cuts tokens-per-task by ≥20% **and** preserves answer quality (rubric ≥4.0/5), it's worth wiring into codedb_context.

If it doesn't, we've learned that orientation can't be pre-computed and the existing on-demand model is right.
