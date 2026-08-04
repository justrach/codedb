# codedb 0.2.5830 - Twitter/X copy

Release: https://github.com/justrach/codedb/releases/tag/v0.2.5830

Best times to post (PST): Tue-Thu, 8-10 AM
Best times to post (SGT): Tue-Thu, 11 PM - 1 AM

---

Tweet 1/5 (Hook)

We are now releasing codedb 0.2.5830.

Faster code intelligence for AI agents. Same answers. Just sooner.

Finding a symbol is 81.72% faster, listing files 67.60%, outlining a file 59.79%.

Zig 0.16.0 -> 0.17.0-dev. Indexing 136ms -> 131ms.

~1,290x vs ripgrep. ~1,520x vs grep.

---

Tweet 2/5 (We actually measured it)

We compared this build head-to-head against 0.2.5829 on the same machine, same files, same Zig 0.17 compiler.

Same answers came back. Just faster.

Word lookups 37% quicker. Bundles 28%. Hot files 18%. Context 12%.

Nothing got slower.

---

Tweet 3/5 (What changed)

Exact symbols now hit a hash index. Tree/outline/word use smart caches. Context is zero-copy.

End-to-end over MCP: 2x-99x faster. Same responses, byte-for-byte.

Zig 0.16 -> 0.17 shaved indexing 136ms -> 131ms. The big % drops are the new perf work on that same compiler.

---

Tweet 4/5 (In the wild)

What agents are seeing right now:

19.7B tokens saved / 30 days
580K ops / 7 days
63µs p50
~47 tokens/outline, ~14/lookup

(Live install stats, not caused by 0.2.5830 alone.)

macOS, Linux, Windows. macOS arm64 signed + notarized.

---

Tweet 5/5 (CTA)

codedb gives AI agents symbols, callers, deps, outlines, and compact context. Your editor still does the edits.

curl -fsSL https://codedb.codegraff.com/install.sh | bash

Star it here: https://github.com/justrach/codedb/

View the release: https://github.com/justrach/codedb/releases/tag/v0.2.5830

---

Alt: Single tweet

codedb 0.2.5830: symbol -81.72%, tree -67.60%, outline -59.79%. Zig 0.16 -> 0.17.0-dev. ~1,290x vs ripgrep. Full MCP parity.

https://github.com/justrach/codedb/releases/tag/v0.2.5830

---

Alt text (dashboard image)

Dark Codegraff dashboard showing engineering teams using Codegraff and four codedb metrics: 19.7 billion tokens saved in the last 30 days, 580,000 operations in the last 7 days, 63 microseconds per operation at p50, and about 47 tokens per outline versus 14 per lookup.

---

Posting notes

- Attach the dashboard image to tweet 4, or tweet 1 if you want a stronger visual opener.
- No link on tweet 1. Put the release URL on tweet 5 only.
- Keep the release URL unshortened.
- Optional tags on the final post: #Zig #MCP #AIEngineering #DeveloperTools
- 19.7B / 580K / 63µs = release-day deployment snapshot, not caused solely by 0.2.5830.
- Grep/ripgrep speedups: local 2026-07-13 check on this repo (761 files), `bench-engine search allocator` p50=13µs vs warm `rg` ~16.8ms (~1,290x) and `grep -R src` ~19.7ms (~1,520x).
