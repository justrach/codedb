//! nanoregex — pure-Zig regex engine with Python-re-compatible semantics.
//!
//! Layered design:
//!   1. parser.zig    — pattern bytes  → AST
//!   2. ast.zig       — AST node tagged union, arena-owned
//!   3. nfa.zig       — AST → Thompson NFA
//!   4. exec.zig      — Pike-VM NFA simulation (always-correct fallback)
//!   5. prefilter.zig — literal/required-substring extraction (fast path)
//!   6. dfa.zig       — Lazy subset-construction DFA (perf path)
//!
//! Dispatch policy in findAll/search:
//!   1. Pure-literal AST + no captures + case-sensitive → memmem loop
//!   2. Required literal absent in haystack → early-return empty
//!   3. DFA eligible (no captures, no anchors, no case-insensitive) → DFA
//!   4. Otherwise → Pike VM
//!
//! The DFA is built eagerly at compile time (when eligible) so the hot loop
//! is a single transition-table lookup per byte. Regex deinit cleans the
//! DFA's arena.

const std = @import("std");
pub const ast = @import("ast.zig");
pub const parser = @import("parser.zig");
pub const nfa = @import("nfa.zig");
pub const exec = @import("exec.zig");
pub const prefilter = @import("prefilter.zig");
pub const dfa = @import("dfa.zig");
pub const minterm = @import("minterm.zig");

pub const Flags = exec.Flags;
pub const Span = exec.Span;
pub const Match = exec.MatchResult;

pub const Regex = struct {
    /// Backing arena for the AST + NFA + prefilter slices. Lives until deinit().
    arena: *std.heap.ArenaAllocator,
    parent_alloc: std.mem.Allocator,
    root: *const ast.Node,
    /// Heap-allocated on `arena` so the address is stable for `dfa.nfa_ref`
    /// and for `exec.Vm.init`. Storing the Nfa by-value here used to give
    /// us a dangling pointer when the Regex was returned by value.
    automaton: *nfa.Nfa,
    flags: Flags,
    n_groups: u32,

    /// Non-null iff the pattern is purely literal AND has zero capture
    /// groups. Callers bypass the engine entirely and use SIMD `indexOf`.
    pure_literal: ?[]const u8,
    /// Non-null iff a contiguous substring is required to appear in every
    /// match. Used as a coarse pre-filter.
    required_literal: ?[]const u8,
    /// Non-null iff every match's start position is at an occurrence of
    /// this byte sequence. Used to skip directly to candidate start
    /// positions via SIMD-accelerated indexOf, then run the DFA only at
    /// those hits.
    literal_prefix: ?[]const u8,

    /// Built eagerly when the pattern is DFA-eligible (no captures, no
    /// anchors, no case-insensitive). Null otherwise. Mutable because the
    /// DFA fills its transition table lazily during matching.
    dfa_engine: ?dfa.Dfa,

    pub fn compile(alloc: std.mem.Allocator, pattern: []const u8) !Regex {
        return compileWithFlags(alloc, pattern, .{});
    }

    pub fn compileWithFlags(alloc: std.mem.Allocator, pattern: []const u8, flags: Flags) !Regex {
        const arena = try alloc.create(std.heap.ArenaAllocator);
        errdefer alloc.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(alloc);
        errdefer arena.deinit();

        var p = parser.Parser.init(arena.allocator(), pattern);
        const root = try p.parseRoot();

        // Heap-allocate the Nfa on the arena. We point at it from both the
        // Regex itself and the Dfa; storing by value would invalidate the
        // address once compileWithFlags returns by value.
        const automaton_ptr = try arena.allocator().create(nfa.Nfa);
        automaton_ptr.* = try nfa.build(arena.allocator(), root, p.n_groups);

        const pure_lit: ?[]const u8 = if (flags.case_insensitive)
            null
        else if (p.n_groups != 0)
            null
        else
            try prefilter.extractFullLiteral(arena.allocator(), root);

        const req_lit: ?[]const u8 = if (flags.case_insensitive)
            null
        else
            try prefilter.extractRequiredLiteral(arena.allocator(), root, 3);

        const lit_prefix: ?[]const u8 = if (flags.case_insensitive)
            null
        else
            try prefilter.extractLiteralPrefix(arena.allocator(), root, 3);

        // Try to build a DFA. Falls back to null (=> Pike VM at runtime)
        // when the pattern has captures, anchors, or grows the state
        // table past the budget. Case-insensitive also skips DFA for v1 —
        // adding case-folding to the bitmap test is straightforward but
        // not done yet.
        var dfa_engine: ?dfa.Dfa = null;
        if (!flags.case_insensitive) {
            if (dfa.Dfa.fromNfa(alloc, automaton_ptr, root, .{ .dot_all = flags.dot_all })) |built| {
                dfa_engine = built;
            } else |_| {
                // Any DFA build error (HasCaptures, HasAnchors, TooManyStates,
                // OOM) falls back silently. The Pike VM handles the same
                // patterns correctly, just slower.
                dfa_engine = null;
            }
        }

        return .{
            .arena = arena,
            .parent_alloc = alloc,
            .root = root,
            .automaton = automaton_ptr,
            .flags = flags,
            .n_groups = p.n_groups,
            .pure_literal = pure_lit,
            .required_literal = req_lit,
            .literal_prefix = lit_prefix,
            .dfa_engine = dfa_engine,
        };
    }

    pub fn deinit(self: *Regex) void {
        if (self.dfa_engine) |*d| d.deinit();
        self.arena.deinit();
        self.parent_alloc.destroy(self.arena);
        self.* = undefined;
    }

    /// First leftmost match, or null. Caller owns the returned Match.
    pub fn search(self: *Regex, alloc: std.mem.Allocator, input: []const u8) !?Match {
        if (self.required_literal) |lit| {
            if (std.mem.indexOf(u8, input, lit) == null) return null;
        }
        if (self.pure_literal) |lit| return try literalFirst(alloc, lit, input);
        if (self.literal_prefix) |prefix| if (self.dfa_engine) |*d|
            return try dfaFirstWithPrefix(alloc, d, input, prefix);
        if (self.dfa_engine) |*d| return try dfaFirst(alloc, d, input);

        var vm = exec.Vm.init(alloc, self.automaton, self.flags);
        return try vm.search(input);
    }

    /// All non-overlapping matches, leftmost-first.
    pub fn findAll(self: *Regex, alloc: std.mem.Allocator, input: []const u8) ![]Match {
        if (self.required_literal) |lit| {
            if (std.mem.indexOf(u8, input, lit) == null) {
                return try alloc.alloc(Match, 0);
            }
        }
        if (self.pure_literal) |lit| return try literalAll(alloc, lit, input);
        if (self.literal_prefix) |prefix| if (self.dfa_engine) |*d|
            return try dfaAllWithPrefix(alloc, d, input, prefix);
        if (self.dfa_engine) |*d| return try dfaAll(alloc, d, input);

        var vm = exec.Vm.init(alloc, self.automaton, self.flags);
        return try vm.findAll(input);
    }

    /// Replace every non-overlapping match. Backreferences (`\N`) honoured.
    pub fn replaceAll(self: *Regex, alloc: std.mem.Allocator, input: []const u8, replacement: []const u8) ![]u8 {
        const matches = try self.findAll(alloc, input);
        defer {
            for (matches) |*m| @constCast(m).deinit(alloc);
            alloc.free(matches);
        }

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(alloc);

        var cursor: usize = 0;
        for (matches) |m| {
            try out.appendSlice(alloc, input[cursor..m.span.start]);
            try appendReplacement(alloc, &out, replacement, m, input);
            cursor = m.span.end;
        }
        try out.appendSlice(alloc, input[cursor..]);
        return try out.toOwnedSlice(alloc);
    }
};

// ── Literal fast paths ──

fn literalFirst(alloc: std.mem.Allocator, needle: []const u8, haystack: []const u8) !?Match {
    if (needle.len == 0) {
        const captures = try alloc.alloc(?Span, 1);
        captures[0] = .{ .start = 0, .end = 0 };
        return .{ .span = .{ .start = 0, .end = 0 }, .captures = captures };
    }
    const idx = std.mem.indexOf(u8, haystack, needle) orelse return null;
    const captures = try alloc.alloc(?Span, 1);
    captures[0] = .{ .start = idx, .end = idx + needle.len };
    return .{ .span = .{ .start = idx, .end = idx + needle.len }, .captures = captures };
}

fn literalAll(alloc: std.mem.Allocator, needle: []const u8, haystack: []const u8) ![]Match {
    var results: std.ArrayList(Match) = .empty;
    errdefer {
        for (results.items) |*m| @constCast(m).deinit(alloc);
        results.deinit(alloc);
    }
    if (needle.len == 0) return try results.toOwnedSlice(alloc);

    var pos: usize = 0;
    while (pos <= haystack.len) {
        const idx = std.mem.indexOfPos(u8, haystack, pos, needle) orelse break;
        const captures = try alloc.alloc(?Span, 1);
        captures[0] = .{ .start = idx, .end = idx + needle.len };
        try results.append(alloc, .{ .span = .{ .start = idx, .end = idx + needle.len }, .captures = captures });
        pos = idx + needle.len;
    }
    return try results.toOwnedSlice(alloc);
}

// ── DFA wrappers ──
//
// Adapter from `dfa.Dfa`'s span-only output to the public `Match` shape
// (which carries a captures slice). DFA mode has no captures so we emit a
// 1-element captures array containing just the whole-match span.

fn dfaFirst(alloc: std.mem.Allocator, d: *dfa.Dfa, input: []const u8) !?Match {
    var p: usize = 0;
    while (p <= input.len) : (p += 1) {
        const end_opt = try d.matchAt(input, p);
        if (end_opt) |end| {
            const captures = try alloc.alloc(?Span, 1);
            captures[0] = .{ .start = p, .end = end };
            return .{ .span = .{ .start = p, .end = end }, .captures = captures };
        }
    }
    return null;
}

fn dfaAll(alloc: std.mem.Allocator, d: *dfa.Dfa, input: []const u8) ![]Match {
    const spans = try d.findAll(alloc, input);
    defer alloc.free(spans);

    var results = try alloc.alloc(Match, spans.len);
    var built: usize = 0;
    errdefer {
        for (results[0..built]) |*m| m.deinit(alloc);
        alloc.free(results);
    }
    for (spans) |span| {
        const captures = try alloc.alloc(?Span, 1);
        captures[0] = .{ .start = span.start, .end = span.end };
        results[built] = .{ .span = .{ .start = span.start, .end = span.end }, .captures = captures };
        built += 1;
    }
    return results;
}

/// Like `dfaFirst` but uses `prefix` to skip directly to candidate match
/// starts via `std.mem.indexOfPos`. Far fewer engine invocations for
/// sparse literal-prefixed patterns.
fn dfaFirstWithPrefix(alloc: std.mem.Allocator, d: *dfa.Dfa, input: []const u8, prefix: []const u8) !?Match {
    var pos: usize = 0;
    while (true) {
        const hit = std.mem.indexOfPos(u8, input, pos, prefix) orelse return null;
        if (try d.matchAt(input, hit)) |end| {
            const captures = try alloc.alloc(?Span, 1);
            captures[0] = .{ .start = hit, .end = end };
            return .{ .span = .{ .start = hit, .end = end }, .captures = captures };
        }
        // DFA didn't accept at this hit (the prefix matched but the rest
        // of the pattern didn't). Advance one byte past this hit and
        // resume the indexOf scan.
        pos = hit + 1;
    }
}

fn dfaAllWithPrefix(alloc: std.mem.Allocator, d: *dfa.Dfa, input: []const u8, prefix: []const u8) ![]Match {
    var results: std.ArrayList(Match) = .empty;
    errdefer {
        for (results.items) |*m| @constCast(m).deinit(alloc);
        results.deinit(alloc);
    }

    var pos: usize = 0;
    while (true) {
        const hit = std.mem.indexOfPos(u8, input, pos, prefix) orelse break;
        if (try d.matchAt(input, hit)) |end| {
            const captures = try alloc.alloc(?Span, 1);
            captures[0] = .{ .start = hit, .end = end };
            try results.append(alloc, .{
                .span = .{ .start = hit, .end = end },
                .captures = captures,
            });
            // Skip past the match end. Zero-width match falls back to
            // hit+1 so we don't infinite-loop.
            pos = if (end > hit) end else hit + 1;
        } else {
            pos = hit + 1;
        }
    }
    return try results.toOwnedSlice(alloc);
}

fn appendReplacement(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    replacement: []const u8,
    m: Match,
    input: []const u8,
) !void {
    var i: usize = 0;
    while (i < replacement.len) {
        const c = replacement[i];
        if (c == '\\' and i + 1 < replacement.len) {
            const n = replacement[i + 1];
            switch (n) {
                '0'...'9' => {
                    const idx: usize = n - '0';
                    if (idx < m.captures.len) {
                        if (m.captures[idx]) |span| try out.appendSlice(alloc, input[span.start..span.end]);
                    }
                    i += 2;
                    continue;
                },
                'n' => { try out.append(alloc, '\n'); i += 2; continue; },
                't' => { try out.append(alloc, '\t'); i += 2; continue; },
                'r' => { try out.append(alloc, '\r'); i += 2; continue; },
                '\\' => { try out.append(alloc, '\\'); i += 2; continue; },
                else => { try out.append(alloc, '\\'); i += 1; continue; },
            }
        }
        try out.append(alloc, c);
        i += 1;
    }
}

test "module imports compile" {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(ast);
    std.testing.refAllDecls(parser);
    std.testing.refAllDecls(nfa);
    std.testing.refAllDecls(exec);
    std.testing.refAllDecls(prefilter);
    std.testing.refAllDecls(dfa);
}

test "Regex.search basic" {
    var r = try Regex.compile(std.testing.allocator, "[a-z]+");
    defer r.deinit();
    var m = (try r.search(std.testing.allocator, "Hello World")).?;
    defer m.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), m.span.start);
    try std.testing.expectEqual(@as(usize, 5), m.span.end);
}

test "Regex.findAll" {
    var r = try Regex.compile(std.testing.allocator, "\\d+");
    defer r.deinit();
    const ms = try r.findAll(std.testing.allocator, "abc 42 xyz 1234");
    defer {
        for (ms) |*m| @constCast(m).deinit(std.testing.allocator);
        std.testing.allocator.free(ms);
    }
    try std.testing.expectEqual(@as(usize, 2), ms.len);
}

test "Regex pure literal fast path" {
    var r = try Regex.compile(std.testing.allocator, "compileAllocFlags");
    defer r.deinit();
    try std.testing.expect(r.pure_literal != null);
    try std.testing.expectEqualStrings("compileAllocFlags", r.pure_literal.?);
    const ms = try r.findAll(std.testing.allocator, "abc compileAllocFlags xyz compileAllocFlags");
    defer {
        for (ms) |*m| @constCast(m).deinit(std.testing.allocator);
        std.testing.allocator.free(ms);
    }
    try std.testing.expectEqual(@as(usize, 2), ms.len);
}

test "Regex DFA engine is built when eligible" {
    var r = try Regex.compile(std.testing.allocator, "[a-z]+");
    defer r.deinit();
    // [a-z]+ has no captures, no anchors → DFA should be built.
    try std.testing.expect(r.dfa_engine != null);
}

test "Regex falls back to Pike VM with captures" {
    var r = try Regex.compile(std.testing.allocator, "(abc)");
    defer r.deinit();
    try std.testing.expect(r.dfa_engine == null);
}

test "Regex falls back to Pike VM with anchors" {
    var r = try Regex.compile(std.testing.allocator, "^foo");
    defer r.deinit();
    try std.testing.expect(r.dfa_engine == null);
}

test "Regex required-literal pre-filter skips haystack with no candidates" {
    var r = try Regex.compile(std.testing.allocator, "hello\\d+");
    defer r.deinit();
    try std.testing.expectEqualStrings("hello", r.required_literal.?);
    const ms = try r.findAll(std.testing.allocator, "no candidates anywhere here");
    defer std.testing.allocator.free(ms);
    try std.testing.expectEqual(@as(usize, 0), ms.len);
}

test "Regex.replaceAll with backreference" {
    var r = try Regex.compile(std.testing.allocator, "(\\w+)@(\\w+)");
    defer r.deinit();
    const out = try r.replaceAll(std.testing.allocator, "alice@example bob@host", "\\2/\\1");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("example/alice host/bob", out);
}
