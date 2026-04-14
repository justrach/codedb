# codedb v0.2.572 launch tweets

Best times to post (PST): Tue-Thu, 8-10 AM
Best times to post (SGT): Tue-Thu, 11 PM - 1 AM

---

Tweet 1 (The big numbers)

codedb v0.2.572 is out.

10× faster cold indexing: 3.6s → 346ms
83% less cold RSS: 3.5GB → 580MB
92% less warm RSS: 1.9GB → 150MB

Hotfix patch on v0.2.57 — same performance gains, correctness fixes included.

---

Tweet 2 (vs fff-mcp)

Real benchmark: query "fn" on openclaw (6,315 files)

codedb:   220µs  — 12 files found (22% recall)
fff-mcp:  510µs  — 2 files found (4% recall)
ripgrep:  ~500ms — ~48,000 lines dumped
grep:    ~1,500ms — ~48,200 lines dumped

2.3× faster than fff-mcp (Rust + rayon).
6× better recall.
2,272× faster than ripgrep.

---

Tweet 3 (Why codedb beats fff-mcp on recall)

fff-mcp uses word-boundary grep.
It misses "DatabaseManager" when you search "manager".

codedb uses a trigram index.
It finds substrings — the way you actually think.

Same latency tier. Way more results.

---

Tweet 4 (What 220 microseconds means)

220 microseconds = 0.00022 seconds

Your AI agent can:
- Run 4,500 codedb searches in 1 second
- Or wait 1 second for a single grep

Pre-indexed. No filesystem scan. No raw text dumps.

---

Tweet 5 (SIMD search engine)

12 optimizations in v0.2.572 search engine:

- SIMD memmem: 16-byte @Vector first-byte scanner
- Tiered search: trigram → sparse → word → full scan
- Lazy sparse: skip covering-set hash when trigrams hit
- Size-sorted candidates: smallest files first
- Per-file result cap: no single file dominates

Single-threaded Zig beating Rust + rayon.

---

Tweet 6 (Zero std.json MCP layer)

MCP layer in v0.2.572:

- Zero std.json: scanner-based extraction for all request types
- Arena allocator + reusable buffers
- Single stdout write per response
- Buffered stdin reads (4KB)

Every microsecond counts.

---

Tweet 7 (Contributors)

18 issues closed. 10 contributors.

@JF10R: trigram growth, drainNotifyFile
@ocordeiro: symbol.line_end
@destroyer22719: MCP disconnections
@wilsonsilva: remote requests
@killop: Windows support
@sims1253: R language, PHP/Ruby fixes
@JustFly1984: DNS, version issues
@mochadwi: comparisons
@Mavis2103: memory ideas

Thank you all.

---

Tweet 8 (CTA)

Update now:

codedb update

Or fresh install:
curl -fsSL https://codedb.codegraff.com/install.sh | bash

macOS: signed + notarized
Linux: x86_64

---

Single tweet version

codedb v0.2.572: 220µs search on 6k files. 2.3× faster than fff-mcp (Rust). 6× better recall. 2,272× faster than ripgrep.

Trigram index + SIMD scanner. Pure Zig. Zero deps.

codedb update

---

Thread starter

codedb v0.2.572

220µs search (fn, openclaw 6k files)
2.3× faster than fff-mcp
6× better recall than fff-mcp
2,272× faster than ripgrep
12 SIMD optimizations

Full thread ↓
🧵

---

Emoji options

⚡ 220µs search (2,272× ripgrep)
🎯 6× better recall than fff-mcp (Rust)
🔍 Trigram finds substrings, word-boundary grep doesn't
🛠️ 18 issues fixed
🙏 10 contributors

---

Hashtags

#codedb #zig #ai #mcp #codeintelligence #devtools #performance

---

Link to use

https://github.com/justrach/codedb/releases/tag/v0.2.572
