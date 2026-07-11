# nanoregex

Small, fast, pure-Zig regex engine. Built to be a drop-in replacement for `zig-regex 0.1.1` with substantially better performance on real workloads.

3,200 lines of Zig. No FFI. No external dependencies. 27/27 parity fixtures green against Python's `re` module.

## Benchmarks

Search across a 142 KB Zig source file, 200 iterations, ReleaseFast.

| Pattern | Python `re` | **nanoregex** | Winner |
|---|---|---|---|
| pure literal `compileAllocFlags` | 0.067ms | **0.037ms** | nanoregex 1.8× |
| literal-prefix `compileAllocFlags\([a-z]+` | 0.061ms | **0.037ms** | nanoregex 1.65× |
| `fn [A-Za-z]+\(.*alloc` | **0.061ms** | 0.092ms | python 1.5× |
| `\d+` (1307 matches) | 0.991ms | **0.455ms** | nanoregex 2.2× |
| `[a-z]+` (17711 matches) | 1.654ms | **0.594ms** | nanoregex 2.8× |
| alt `foo\|bar\|baz` | 0.731ms | **0.423ms** | nanoregex 1.7× |
| IPv4-ish `\d+\.\d+\.\d+\.\d+` | 0.904ms | **0.416ms** | nanoregex 2.2× |

8 of 8 head-to-head non-anchored patterns won. Versus `zig-regex 0.1.1` on a pattern that triggers catastrophic backtracking, nanoregex is ~5000× faster (43 seconds → 8 milliseconds).

## Architecture

Layered, with five dispatch tiers that compose at compile time:

```
parser.zig    pattern bytes  →  AST
ast.zig       AST node tagged union, arena-owned
nfa.zig       AST  →  Thompson NFA
exec.zig      Pike-VM simulation (always-correct fallback)
dfa.zig       Lazy subset-construction DFA (perf path)
minterm.zig   Byte-class compression for the DFA's transition table
prefilter.zig Literal-prefix / required-substring extraction
root.zig      Public API + dispatch
```

`findAll` and `search` route to the cheapest engine that can correctly handle a given pattern:

1. **Pure-literal pattern** → `std.mem.indexOf` loop (memmem)
2. **Required-literal absent** → return empty (no engine work at all)
3. **Literal-prefix + DFA-eligible** → `indexOfPos` to candidate starts, DFA at each hit
4. **DFA-eligible** → plain lazy DFA
5. **Otherwise** → Pike VM

DFA-eligible means: no capture groups, no anchors (`^`, `$`, `\b`), no lazy quantifiers, not case-insensitive, and the on-demand DFA stays under the 4096-state budget. Everything that doesn't fit those rules takes the Pike-VM path, which is linear-time and correct on every input.

Bytes are folded to **minterm classes** before indexing the DFA's transition table. A pattern with `[a-z]+` reduces 256 bytes to 2 classes (in-set, out-of-set), shrinking the per-state row from 1 KB to 8 bytes and letting the whole transition table live in L1 cache.

## API

Mirrors `zig-regex 0.1.1` enough that most callers can switch by changing one path in `build.zig`:

```zig
const nanoregex = @import("nanoregex");

var r = try nanoregex.Regex.compile(allocator, "(\\w+)@(\\w+)");
defer r.deinit();

const matches = try r.findAll(allocator, "alice@example bob@host");
defer {
    for (matches) |*m| @constCast(m).deinit(allocator);
    allocator.free(matches);
}
for (matches) |m| {
    std.debug.print("{d}..{d}\n", .{ m.span.start, m.span.end });
}
```

Methods take `*Regex` (mutable) rather than `*const Regex` because the lazy DFA fills its transition table on the fly. The first `findAll` call on a fresh `Regex` warms the cache; subsequent calls are pure table lookups.

Compile flags:

```zig
try nanoregex.Regex.compileWithFlags(alloc, pattern, .{
    .case_insensitive = false,
    .multiline = true,    // grep-like default — `^`/`$` match line edges
    .dot_all = false,
});
```

Backreference expansion in `replaceAll` (`\1`, `\2`, ...):

```zig
const out = try r.replaceAll(alloc, "alice@example", "\\2/\\1");
// → "example/alice"
```

## Supported syntax (v1)

- Literals, `.`, character classes `[abc]` / `[^abc]` / `[a-z]`
- Shorthand `\d \D \w \W \s \S`
- Quantifiers `? * + {n} {n,m}` — greedy and lazy (`*?`, `+?`, `??`, `{n,m}?`)
- Groups `(foo)` capturing, `(?:foo)` non-capturing
- Alternation `foo|bar`
- Anchors `^ $ \b \B \A \z`
- Flags: case-insensitive, multiline, dot-all

**Not yet supported**: backreferences in *patterns* (`\1` inside the regex itself), lookaround `(?=...)`/`(?!...)`, inline flag groups `(?i)...`, named groups `(?P<name>...)`, Unicode property classes. Patterns using these features parse OK if the syntax shape is recognised, but matching may diverge — fall back to a richer engine if you need them.

## Build

```bash
zig build install -Doptimize=ReleaseFast
# → zig-out/bin/nanoregex_probe   (parity test CLI)
# → zig-out/bin/nanoregex_bench   (single-file benchmark)
```

## Tests

Tests are split into narrow per-module steps so the inner loop stays tight:

```bash
zig build test-ast        # 3 tests
zig build test-parser     # parser + ast tests
zig build test-nfa        # nfa + parser + ast
zig build test-exec       # Pike VM tests
zig build test-prefilter  # literal-extraction tests
zig build test-minterm    # byte-class compression
zig build test-dfa        # DFA construction + matching
zig build test-root       # public API
zig build parity          # Python re parity (requires python3)
zig build test-all        # everything, explicit and opt-in
```

Add `-Dtest-filter='substring'` to any step to narrow further.

## Why it exists

This was extracted from the [zigrepper](https://github.com/justrach/zigrepper) toolchain, where `zig-regex 0.1.1`'s backtracking engine was making `zigrep --regex` take 43 seconds on patterns like `compileAllocFlags\([a-z]+` against a directory tree. After this engine landed, the same query finished in 0.43 seconds end-to-end.

Inspired by Russ Cox's writing on regex implementation, RE2's lazy DFA, and the [RE# / Resharp blog post](https://iev.ee/blog/resharp-how-we-built-the-fastest-regex-in-fsharp/) which laid out minterm compression and several other optimizations cleanly.

## License

MIT
