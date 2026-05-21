---
schema_version: 1
generated_at: 2026-05-21T00:00:00Z
generator: "claude-sonnet-4-6"
source_hash: "blake2b:2348b7427c5c2697a3e956d1c6104558"
source_files:
  - Cargo.toml
  - src/lib.rs
  - src/builders.rs
  - regex-automata/src/lib.rs
  - regex-automata/src/meta/regex.rs
  - regex-automata/src/meta/strategy.rs
  - regex-automata/src/nfa/thompson/mod.rs
  - regex-syntax/src/lib.rs
  - regex-syntax/src/hir/mod.rs
  - regex-lite/src/lib.rs
loc_budget: 200
loc_actual: 80
---

# regex

Cargo workspace providing linear-time regex search in Rust. The `regex` crate
is a thin ergonomic wrapper over `regex-automata`, which houses all engines.
All searches guarantee worst-case O(m*n) time by refusing look-around and
backreferences.

## Layout

- `src/` — the public `regex` crate (v1.12.3): ergonomic `Regex` / `RegexSet`
  - `lib.rs` — re-exports from `builders::string`, `regex::string`, `regexset::string`
  - `builders.rs` — `RegexBuilder` / `RegexSetBuilder` (wraps internal `Builder`)
  - `regex/` / `regexset/` — string and bytes sub-modules
- `regex-automata/src/` — all engine implementations
  - `meta/` — primary high-level engine; auto-selects strategy at build time
    - `regex.rs` — `Regex` struct, `Cache`, search APIs
    - `strategy.rs` — `Strategy` trait + `Pre<P>` prefilter dispatch
  - `nfa/thompson/` — Thompson NFA: `PikeVM`, `BoundedBacktracker`, `NFA`
  - `dfa/` — fully compiled DFA (`dense`, `sparse`, `onepass`)
  - `hybrid/` — lazy NFA/DFA; builds transition table at search time
  - `util/` — shared primitives: `Input`, `Match`, `Captures`, `Prefilter`, `Pool`
- `regex-syntax/src/` — parser and HIR
  - `ast/` — concrete syntax tree + `parse.rs` (6 KLOC)
  - `hir/` — high-level IR; `translate.rs` lowers AST→HIR, expands Unicode
- `regex-lite/` — lightweight alternative: no Unicode tables, smaller binary
- `regex-capi/` — C FFI bindings
- `regex-cli/` — developer CLI for benchmarking and debugging engines
- `regex-test/` — shared test harness (TOML-driven test suites)
- `testdata/*.toml` — pattern-level test cases consumed by `regex-test`

## Key concepts

- **Compilation pipeline**: `&str` → AST (regex-syntax) → HIR → Thompson NFA → engine
- **meta::Regex**: the orchestrator; picks among PikeVM, BoundedBacktracker,
  one-pass DFA, lazy DFA, or full DFA based on pattern complexity and size limits
- **Strategy trait**: dynamic dispatch over the chosen engine; `Pre<P>` wraps any
  strategy with an Aho-Corasick or literal prefilter to skip non-matching regions
- **Cache**: mutable scratch space for lazy DFA state tables and PikeVM slots;
  thread-local via `Pool`; pass directly to `search_with` to avoid sync overhead
- **Input / Anchored**: `Input<'h>` carries haystack + search range + anchoring mode;
  anchored searches do not require `^` in the pattern
- **HIR literals**: `regex-syntax::hir::literal` extracts prefix/suffix literal sets
  used by the prefilter system

## Entry points

- Adding a flag or builder option: `src/builders.rs` `RegexBuilder`, delegates to
  `regex-automata/src/meta/regex.rs` `Config`
- Understanding search dispatch: `regex-automata/src/meta/strategy.rs` `new()`
- Tracing a match through the NFA: `regex-automata/src/nfa/thompson/pikevm.rs`
- Extending the HIR: `regex-syntax/src/hir/translate.rs`
- Writing engine-level tests: `testdata/*.toml` + `regex-test/lib.rs`

## Conventions

- `string` / `bytes` sub-modules mirror each other; bytes variants operate on `&[u8]`
- Builder methods return `&mut Self` for chaining; `build()` produces `Result<_, Error>`
- Error types are per-crate (`BuildError` in regex-automata, `Error` in regex-syntax)
- `no_std` / no-alloc is supported for DFA deserialization via `dfa::dense::DFA::from_bytes`
- Cargo features gate Unicode tables, perf optimizations, and engine availability
