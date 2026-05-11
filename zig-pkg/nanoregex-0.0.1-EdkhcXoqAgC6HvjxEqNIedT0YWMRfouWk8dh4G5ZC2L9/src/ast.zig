//! Regex AST. Built by parser.zig, consumed by nfa.zig (later).
//!
//! All nodes are arena-owned by the parent Regex. The arena is freed in one
//! shot on Regex.deinit, so individual nodes never need their own deinit.
//! Child references use `*const Node` rather than slices to keep the union
//! tag size predictable and to avoid sub-allocations for unary nodes.

const std = @import("std");

pub const Node = union(enum) {
    /// A single literal byte. Case-folding (when flags.case_insensitive) is
    /// handled at match time so the AST stays case-preserving — useful for
    /// reporting in error messages.
    literal: u8,

    /// `.` — matches any byte except `\n`, or any byte at all when the
    /// pattern was compiled with `flags.dot_all`. The matcher consults the
    /// flag; the AST node itself is flag-agnostic.
    dot,

    /// `[abc]`, `[^abc]`, `[a-z]`, plus the shorthands `\d \D \w \W \s \S`
    /// which the parser desugars into a Class node with the right bitmap.
    class: *const Class,

    /// Zero-width anchors: `^ $ \b \B \A \z`.
    anchor: Anchor,

    /// A concatenation `abc` — match each sub-node in order.
    concat: []const *const Node,

    /// Alternation `a|b|c` — match any one branch (left to right, first
    /// wins under leftmost-first semantics, matching Python re).
    alt: []const *const Node,

    /// Quantified sub-pattern: `a*`, `a+`, `a?`, `a{n,m}`.
    repeat: *const Repeat,

    /// `(foo)` or `(?:foo)`. The group's `index` is 0 for non-capturing,
    /// 1..N for capturing groups in left-paren order. Index 0 (the whole
    /// match) is implicit at the top level — not a Group node.
    group: *const Group,
};

pub const Anchor = enum {
    /// `^` — start of input, or start of any line in multiline mode.
    line_start,
    /// `$` — end of input, or end of any line in multiline mode.
    line_end,
    /// `\b` — boundary between a word char (`[A-Za-z0-9_]`) and not.
    word_boundary,
    /// `\B` — anywhere `\b` doesn't match.
    non_word_boundary,
    /// `\A` — start of input (ignores multiline flag).
    string_start,
    /// `\z` — end of input (ignores multiline flag).
    string_end,
};

/// Character class represented as a 256-bit bitmap. `bitmap[byte/8] &
/// (1 << (byte%8))` is set iff the byte is included. Negation is folded
/// into the bitmap at parse time so the matcher does a single bit test.
pub const Class = struct {
    bitmap: [32]u8,

    pub fn empty() Class {
        return .{ .bitmap = [_]u8{0} ** 32 };
    }

    pub fn set(self: *Class, byte: u8) void {
        self.bitmap[byte / 8] |= @as(u8, 1) << @intCast(byte % 8);
    }

    pub fn setRange(self: *Class, lo: u8, hi: u8) void {
        var b: usize = lo;
        while (b <= hi) : (b += 1) {
            self.set(@intCast(b));
            if (b == 0xff) break;
        }
    }

    pub fn contains(self: *const Class, byte: u8) bool {
        return (self.bitmap[byte / 8] >> @intCast(byte % 8)) & 1 != 0;
    }

    pub fn negate(self: *Class) void {
        for (&self.bitmap) |*b| b.* = ~b.*;
    }
};

pub const Repeat = struct {
    sub: *const Node,
    min: u32,
    /// `std.math.maxInt(u32)` represents unbounded (`*` and `+`).
    max: u32,
    /// True for `*`/`+`/`?`/`{n,m}`, false for the lazy `??`/`*?`/`+?`/`{n,m}?`
    /// variants. Greedy is the Python re default.
    greedy: bool,
};

pub const Group = struct {
    sub: *const Node,
    /// 0 = non-capturing; ≥1 = capture index in left-paren declaration order.
    index: u32,
    capturing: bool,
};

// ── Test helpers ──

/// Pretty-print an AST for debugging and tests. Indents to make tree shape
/// visible. The format is stable enough to assert against in tests.
/// Pretty-print an AST for debugging and tests. Indents to make tree shape
/// visible. The format is stable enough to assert against in tests.
/// Writes into an ArrayList(u8) rather than a std.io.Writer because Zig 0.16
/// reworked the writer interface and we don't want to chase the new shape
/// from a leaf debug helper.
pub fn debugWrite(node: *const Node, buf: *std.ArrayList(u8), alloc: std.mem.Allocator, indent: u32) error{OutOfMemory}!void {
    var i: u32 = 0;
    while (i < indent) : (i += 1) try buf.appendSlice(alloc, "  ");
    var tmp: [128]u8 = undefined;
    switch (node.*) {
        .literal => |c| {
            const line = std.fmt.bufPrint(&tmp, "literal '{c}'\n", .{c}) catch unreachable;
            try buf.appendSlice(alloc, line);
        },
        .dot => try buf.appendSlice(alloc, "dot\n"),
        .anchor => |a| {
            const line = std.fmt.bufPrint(&tmp, "anchor {s}\n", .{@tagName(a)}) catch unreachable;
            try buf.appendSlice(alloc, line);
        },
        .class => |c| {
            var popcnt: u32 = 0;
            for (c.bitmap) |b| popcnt += @popCount(b);
            const line = std.fmt.bufPrint(&tmp, "class [{d} bytes]\n", .{popcnt}) catch unreachable;
            try buf.appendSlice(alloc, line);
        },
        .concat => |children| {
            try buf.appendSlice(alloc, "concat\n");
            for (children) |child| try debugWrite(child, buf, alloc, indent + 1);
        },
        .alt => |children| {
            try buf.appendSlice(alloc, "alt\n");
            for (children) |child| try debugWrite(child, buf, alloc, indent + 1);
        },
        .repeat => |r| {
            const line = std.fmt.bufPrint(&tmp, "repeat min={d} max={d} greedy={}\n", .{ r.min, r.max, r.greedy }) catch unreachable;
            try buf.appendSlice(alloc, line);
            try debugWrite(r.sub, buf, alloc, indent + 1);
        },
        .group => |g| {
            const line = std.fmt.bufPrint(&tmp, "group #{d} cap={}\n", .{ g.index, g.capturing }) catch unreachable;
            try buf.appendSlice(alloc, line);
            try debugWrite(g.sub, buf, alloc, indent + 1);
        },
    }
}

test "class bitmap set/contains" {
    var c = Class.empty();
    c.set('a');
    c.set('z');
    try std.testing.expect(c.contains('a'));
    try std.testing.expect(c.contains('z'));
    try std.testing.expect(!c.contains('b'));
    try std.testing.expect(!c.contains('y'));
}

test "class range" {
    var c = Class.empty();
    c.setRange('a', 'd');
    try std.testing.expect(c.contains('a'));
    try std.testing.expect(c.contains('b'));
    try std.testing.expect(c.contains('c'));
    try std.testing.expect(c.contains('d'));
    try std.testing.expect(!c.contains('e'));
    try std.testing.expect(!c.contains('`'));
}

test "class negate" {
    var c = Class.empty();
    c.setRange('a', 'z');
    c.negate();
    try std.testing.expect(!c.contains('a'));
    try std.testing.expect(!c.contains('z'));
    try std.testing.expect(c.contains('A'));
    try std.testing.expect(c.contains('0'));
}
