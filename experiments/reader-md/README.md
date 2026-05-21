# reader.md — experimental codebase-map for codedb

Experiment branch: `experiment/reader-md`. **Status: now wired into the codedb runtime** (commit `da71484`). Earlier versions of this experiment were spec-only; this branch ships an actual integration that any `codedb mcp` build can use.

## TL;DR (runtime-wired)

A hash-stable, ≤200-LOC, agent-authored markdown file at `.codedb/reader.md` that codedb's runtime auto-prepends to every `codedb_context` response. Measured against the experimental binary with `.codedb/reader.md` installed in each corpus:

- **−57% tool calls** vs control (avg of 3 tasks, Sonnet 4.6)
- **−39% wall time**
- **−19% tokens consumed** (T2 regex alone: −48%)
- **6/6 quality preserved**

This is **better than the prompt-inlined version** measured in [`eval/RESULTS.md`](eval/RESULTS.md) — see [`eval/RESULTS-RUNTIME.md`](eval/RESULTS-RUNTIME.md) for the full A/B breakdown.

- [`SPEC.md`](SPEC.md) — file format, frontmatter, hash protocol, lifecycle, open questions
- [`readers/`](readers/) — generated `reader.md` for 3 corpora:
  - [`flask.md`](readers/flask.md) — 107 LOC, 10 source files
  - [`regex.md`](readers/regex.md) — 80 LOC, 10 source files
  - [`react.md`](readers/react.md) — 95 LOC, 8 source files
- [`eval/TASKS.md`](eval/TASKS.md) — task definitions + conditions
- [`eval/RESULTS.md`](eval/RESULTS.md) — raw numbers, deltas, threats to validity

## Cost to generate reader.md

| Corpus | LOC | Tool calls | Wall (s) |
|---|---:|---:|---:|
| flask | 107 | 22 | 147 |
| regex | 80 | 18 | 183 |
| react | 95 | 22 | 204 |

~31k tokens per generation (one-time per source_hash drift). Pays for itself after ~3 tasks.

## Hash protocol

```python
import hashlib
def source_hash(files: list[str]) -> str:
    h = hashlib.blake2b(digest_size=16)
    for f in sorted(files):
        h.update(f.encode()); h.update(b"\0")
        with open(f, "rb") as fp: h.update(fp.read())
        h.update(b"\0\0")
    return "blake2b:" + h.hexdigest()
```

Deterministic. Codedb can verify on every scan; mismatch ⇒ stale ⇒ regenerate.

## Side-finding

## What this experiment now DOES wire in (commit `da71484`)

- **New module `src/reader_md.zig`** (~170 LOC). Parses minimal YAML frontmatter (source_hash + source_files), recomputes blake2b via `std.crypto.hash.blake2.Blake2b128`, returns `.ready` / `.stale` / `.missing` / `.malformed`.
- **`handleContext` integration** — at the top of every `codedb_context` MCP call, codedb loads `.codedb/reader.md`, verifies the hash, and either prepends the body (with `<!-- reader.md (hash-verified): -->` markers) or emits a "regenerate" hint.
- **Algorithm parity with Python**: blake2b digest of `for f in sorted(source_files): f.bytes ++ \0 ++ open(f).read() ++ \0\0` — byte-for-byte identical to the canonical algorithm in SPEC.md.

End-to-end verified on a hand-crafted fixture:

```
valid reader.md     → body prepended with hash-verified marker  ✓
src.py mutated      → "reader.md is stale (source_hash drifted)" hint  ✓
.codedb/ removed    → silent (no overhead, no noise)  ✓
perf overhead       → +0 ms (codedb_context p50 ~6 ms on react, within noise)  ✓
```

## What this experiment still does NOT do
## What this experiment does NOT do

- Wire reader.md into the codedb runtime
- Implement the regeneration policy (when to mark stale, who selects source_files)
- Compare against `codedb_context` (only against raw codedb CLI)
- Run at scale (3×3 only)

## If this gets prioritized

See [`SPEC.md` § Sequencing](SPEC.md#sequencing-if-this-gets-prioritized) and [`eval/RESULTS.md` § Recommended next steps](eval/RESULTS.md#recommended-next-steps-if-this-gets-prioritized).
