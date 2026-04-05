# codedb v0.2.52 update tweets

Best times to post (PST): Tue-Thu, 8-10 AM
Best times to post (SGT): Tue-Thu, 11 PM - 1 AM

---

Tweet 1 (Hook)

codedb v0.2.52 just dropped.

538x faster than ripgrep. 569x faster than rtk. 1,231x faster than grep.

0.065ms code search. Pre-built trigram index. Query once, instant forever.

21 issues closed. 14 PRs merged. 7 contributors. One weekend.

---

Tweet 2 (The numbers)

Benchmarked on rtk-ai/rtk (329 files):

codedb search: 0.065ms
rtk: 37ms
ripgrep: 45ms
grep: 80ms

codedb word lookup: 0.013ms. That's 13 microseconds. For an exact match across 329 files.

First index: 126ms. Then sub-millisecond everything. Forever.

---

Tweet 3 (What changed)

36% faster indexing. 59% less CPU. 47% less memory.

Integer doc IDs replaced string HashMaps in the trigram index. Batch-accumulate per file. Skip whitespace trigrams. Sorted merge intersection with zero allocations.

481ms → 310ms indexing on 5,200 files. Dense queries 63% faster. Pure Zig. No magic.

---

Tweet 4 (Security)

Also shipped a full security audit this release.

Blocked .env and credentials from MCP read/edit tools.
Fixed SSRF in codedb_remote.
Added SHA256 checksum verification to the installer.
Telemetry hardened — argv-based curl, no shell injection.

macOS binary is now codesigned AND notarized. First time.

---

Tweet 5 (Memory)

Your MCP server was eating 2.5GB on a 5k file repo.

Now it releases file contents after indexing. Zero-copy ContentRef for search — borrows from cache, reads from disk when evicted.

447MB → 234MB at 40k files. -47%.

Large repos (>1000 files) auto-release. Small repos keep everything in RAM. No config needed.

---

Tweet 6 (Fixes)

Python deps finally work.
TypeScript block comments don't produce ghost symbols.
Triple-quote docstrings don't fool the parser.
Linux installer doesn't choke on Dash.
MCP idle timeout is 2 minutes, not 30.
Duplicate MCP servers get detected.
Exit crash from double thread join — fixed.

21 bugs. 14 PRs. Zero regressions.

---

Tweet 7 (CTA)

Update now:

curl -fsSL https://codedb.codegraff.com/install.sh | bash

Or just run: codedb update

macOS (codesigned + notarized) and Linux x86_64.
SHA256 checksums included.
Auto-registers in Claude Code, Codex, Gemini CLI, Cursor.

codedb.codegraff.com/update

---

Alt: Single tweet

codedb v0.2.52: 538x faster than ripgrep on code search.

36% faster indexing. 47% less memory. Full security audit. Python/TS parser fixes. macOS notarized.

21 issues closed by 7 contributors in one session.

curl -fsSL https://codedb.codegraff.com/install.sh | bash

---

Alt: Thread opener (punchy)

538x faster than ripgrep.
569x faster than rtk.
1,231x faster than grep.

codedb doesn't scan your files. It already knows. 0.065ms.

Thread on what we shipped in v0.2.52 👇
