# codedb v0.2.572 social copy

## Tweet

Hey guys!! I finally posted codedb here properly.

codedb is a local code intelligence engine for AI agents, written in Zig.

v0.2.572 just shipped:
220µs search on 6,315 files
2.3x faster than fff-mcp
6x better recall
2,272x faster than ripgrep

Deep dives:
https://codegraff.com/blog/codedb-code-intelligence
https://codegraff.com/blog/codedb-0-2-572

## LinkedIn

Hey guys!! I haven't properly posted about codedb on LinkedIn yet, and since v0.2.572 just shipped I figured I'd do a proper intro.

codedb is a local code intelligence engine for AI agents, written in Zig.

The basic idea is simple. Every time an agent needs to understand a codebase, it usually shells out to grep or ripgrep, reads full files, and pushes raw text back into the prompt. The codebase barely changes between queries, but the agent keeps paying the same cost again and again in process startup, filesystem scans, latency, and token burn.

codedb indexes a repo once on startup, keeps structural information in memory, and serves it back over MCP. So instead of rescanning the filesystem every time, an agent can ask directly for symbol outlines, exact identifier hits, dependency edges, file trees, structured reads, and edits.

That is why it feels fast. The win is not just wall-clock latency. It is also that the responses are shaped for agents instead of dumping giant walls of raw text into the context window.

v0.2.572 is a good snapshot of where the project is right now. On 6,315 files, search is down to 220µs. That is 2.3x faster than fff-mcp, 6x better recall on the comparison query, and 2,272x faster than ripgrep.

If you want the full write-up, I published two posts on Codegraff.

Why codedb feels instant for agents:
https://codegraff.com/blog/codedb-code-intelligence

codedb 0.2.572:
https://codegraff.com/blog/codedb-0-2-572

codedb is open source here:
https://github.com/justrach/codedb

I think AI agents should have the same kind of structural code intelligence that IDEs have had for years. codedb is my attempt to make that available everywhere, not just inside one editor.

#codedb #zig #ai #mcp #devtools
