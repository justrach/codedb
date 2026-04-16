# codedb v0.2.58 social copy

## Tweet

codedb v0.2.58 is out.

Code search should match how people think, not how identifiers are spelled.

`search` now hits `searchContent`
`http` now hits `HTTPHandler`
`index` now hits `word_index`

Identifier splitting + lowercase normalization moved sub-token queries into Tier 0 word-index lookup.

3.9x faster p50. Same recall.

## LinkedIn

First time posting codedb on LinkedIn, so here is the short version.

codedb is a local code search and indexing engine for AI agents, written in Zig.

The problem I wanted to solve was simple: most agent workflows still keep bouncing between `grep`, file reads, and huge prompt dumps just to answer basic codebase questions. That wastes latency, tokens, and a lot of context window on raw text the model should never have needed in the first place.

codedb indexes a repo once, keeps the useful structure in memory, and gives agents direct access to things like:

- file trees
- symbol outlines
- exact symbol lookup
- full-text search
- dependency lookups
- structured file reads and edits

So instead of rescanning the filesystem every time, the agent can ask the codebase directly.

v0.2.58 is a small release, but it shows the kind of improvements I care about.

People do not search code the way identifiers are written. They type the piece they remember:

- `search`, not `searchContent`
- `http`, not `HTTPHandler`
- `index`, not `word_index`

So I changed the word index to split identifiers into lowercased sub-tokens and normalize lookups to lowercase.

That moved a lot of common queries out of the trigram/content scan path and into Tier 0 word-index lookup.

Benchmark on a warm, pre-indexed repo:

- sub-token queries: 3.9x faster p50
- full identifier queries: 2.9x faster
- recall: unchanged

My favorite kind of optimization is the one where the user does nothing differently. You type the thing you remember, and the engine gets better at meeting you there.

Release: https://github.com/justrach/codedb2/releases/tag/v0.2.58
Benchmark: https://github.com/justrach/codedb2/blob/main/benchmarks/v0.2.58-vs-v0.2.572.md

#codedb #zig #ai #mcp #devtools
