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

Posting about codedb on LinkedIn for the first time because this release gets at the core of what I want the project to do.

codedb is a local code search and indexing engine for AI agents, written in Zig.

One thing that always bothered me with code search is that humans rarely search for the exact identifier. We type the concept we remember:

- `search`, not `searchContent`
- `http`, not `HTTPHandler`
- `index`, not `word_index`

In v0.2.58 I changed the word index so identifiers are split into lowercased sub-tokens:

- `searchContent` -> `search` + `content`
- `word_index` -> `word` + `index`
- `HTTPHandler` -> `http` + `handler`

That means a lot of common queries now resolve in the Tier 0 word index instead of falling through to the trigram candidate + content scan path.

Benchmark on a warm, pre-indexed repo:

- sub-token queries: 3.9x faster p50
- full identifier queries: 2.9x faster
- recall: unchanged

I like this class of improvement because users do not need to learn a new trick. They type what they were already going to type, and the engine gets better at meeting them there.

Release: https://github.com/justrach/codedb2/releases/tag/v0.2.58
Benchmark: https://github.com/justrach/codedb2/blob/main/benchmarks/v0.2.58-vs-v0.2.572.md

#codedb #zig #ai #mcp #devtools
