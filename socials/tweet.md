# codedb launch tweets

Best times to post (PST): Tue-Thu, 8-10 AM
Best times to post (SGT): Tue-Thu, 11 PM - 1 AM

---

Tweet 1 (Hook)

I built a code intelligence server in Zig that gives AI agents 469x faster queries than grep/find — and uses 92x fewer tokens.

0.2ms lookups. 3.9ms symbol search. Indexes once, then every query hits memory. No filesystem scans. No raw text dumps.
---

Tweet 2 (The problem)

Every time an AI agent runs grep or find on your codebase, it pays the full cost.

Filesystem scan. Raw text dump. Thousands of tokens for a simple lookup.

grep a symbol across 7k files: 763ms, 7.7KB response.
codedb: 3.9ms, 4.4KB. Same answer. 200x faster. Half the bytes.

---

Tweet 3 (The numbers)

Benchmarked on openclaw (7,364 files, 128MB):

Word lookup: 0.2ms vs 65ms. 325x.
Symbol find: 3.9ms vs 763ms. 200x.
Reverse deps: 1.3ms vs 750ms. 469x.
Deps response: 162 bytes vs 15KB. 92x less data.

Cold start: 2.9 seconds for 7,364 files. Then sub-millisecond everything.

---

Tweet 4 (What you get)

16 MCP tools. Not 5, not 8. Sixteen.

tree, outline, symbol, search, word, hot, deps, read, edit, changes, status, snapshot, bundle, remote, projects, index.

codedb_remote queries any GitHub repo without cloning.
codedb_bundle batches multiple queries in one call.
codedb_index indexes any local folder on demand.

Pure Zig. Single binary. Zero dependencies.

---

Tweet 5 (CTA)

One command. Auto-registers in Claude Code, Codex, Gemini CLI, and Cursor.

curl -fsSL https://codedb.codegraff.com/install.sh | sh

BSD-3 licensed. Open source.

https://codedb.codegraff.com
github.com/justrach/codedb

---

Alt: Single tweet

I built a code intelligence server in Zig that gives AI agents 469x faster queries and sends 92x fewer bytes than grep/find.

16 MCP tools. Zero deps. 2.9s to index 7k files. Sub-millisecond everything after.

Works with Claude Code, Codex, Gemini CLI, Cursor. One command install.

curl -fsSL https://codedb.codegraff.com/install.sh | sh
