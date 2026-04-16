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

Hey guys!! I haven't properly posted about codedb on LinkedIn yet, so here's the clean intro.

codedb is a local code intelligence engine for AI agents, written in Zig.

The problem it solves is pretty straightforward: most agent workflows still bounce between `grep`, full-file reads, and raw shell output just to answer simple questions about a codebase. The repo barely changes between queries, but the agent keeps paying the same cost over and over again in latency, process startup, and token waste.

codedb indexes a repo once on startup, keeps structural information in memory, and serves it back over MCP. So instead of rescanning the filesystem every time, an agent can ask directly for symbol outlines, exact identifier hits, dependency edges, file trees, structured reads, and edits.

The speedup matters, but the bigger win is shape. Agents do better when they get structured answers instead of giant walls of raw text.

The latest release, v0.2.58, is a good example of the direction I want the project to keep moving in. People do not search code the way identifiers are written. They search for the fragment they remember: `search`, not `searchContent`; `http`, not `HTTPHandler`; `index`, not `word_index`.

So v0.2.58 changes the word index to split identifiers into lowercased sub-tokens and normalize lookups to lowercase. A lot of those queries now resolve in the Tier 0 word index instead of falling through to the heavier trigram/content scan path.

On a warm, pre-indexed repo, sub-token queries are 3.9x faster p50, full identifier queries are 2.9x faster, and recall stays the same.

If you want the deeper write-up, I published two posts on Codegraff:

- Why codedb feels instant for agents: https://codegraff.com/blog/codedb-code-intelligence
- codedb 0.2.572: https://codegraff.com/blog/codedb-0-2-572

codedb is open source here: https://github.com/justrach/codedb

I think AI agents should have the same kind of structural code intelligence that IDEs have had for years. codedb is my attempt to make that usable everywhere, not just inside one editor.

#codedb #zig #ai #mcp #devtools
