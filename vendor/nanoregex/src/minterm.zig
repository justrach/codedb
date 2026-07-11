//! Byte-class compression for the DFA's transition table.
//!
//! Two bytes are EQUIVALENT for a given pattern when every atomic predicate
//! in that pattern (literal-byte tests, character classes, `.`) agrees on
//! them. Equivalent bytes drive the DFA to the same next state, so we can
//! collapse them into a single "minterm" class and index transitions by
//! class id instead of raw byte.
//!
//! Concretely: a pattern with `[a-z]+` has two classes — {a..z} and
//! everything else — so the DFA's transition row shrinks from 256 entries
//! to 2. A pattern with several distinct literals plus a class typically
//! has 10-20 classes. Resharp reported a 7× speedup from this alone,
//! mostly because the smaller table fits in L1.
//!
//! Build cost is one O(256 × n_predicates) pass at compile time. We cap
//! n_predicates at 64 (fits a u64 signature); patterns with more atomic
//! predicates than that fall back to an identity (byte == class) table,
//! which makes minterm a no-op and we still match correctly.

const std = @import("std");
const ast = @import("ast.zig");

pub const Table = struct {
    /// byte → class_id (0..n_classes-1). For n_classes == 256 this is the
    /// identity mapping and minterm acts as a no-op.
    byte_to_class: [256]u8,
    /// Number of distinct classes. 1..256.
    n_classes: u16,
    /// class_id → arbitrary byte that lives in that class. Used when the
    /// DFA's `move` step needs a concrete byte to feed into per-NFA-state
    /// predicate tests.
    representatives: [256]u8,
};

pub const Error = error{OutOfMemory};

pub fn build(arena: std.mem.Allocator, root: *const ast.Node, dot_all: bool) Error!Table {
    var preds: std.ArrayList(Predicate) = .empty;
    defer preds.deinit(arena);
    try collectPredicates(root, arena, &preds);

    // Pattern with no consuming atoms — only anchors / empty. Nothing to
    // distinguish; collapse the alphabet to a single class.
    if (preds.items.len == 0) return singleClass();
    // Too many predicates for our 64-bit signature; bail to identity. The
    // matcher still works, the minterm is just a pass-through.
    if (preds.items.len > 64) return identity();

    var sigs: [256]u64 = undefined;
    for (0..256) |b| {
        var sig: u64 = 0;
        for (preds.items, 0..) |pred, i| {
            if (matches(pred, @intCast(b), dot_all)) {
                sig |= @as(u64, 1) << @intCast(i);
            }
        }
        sigs[b] = sig;
    }

    var sig_to_class = std.AutoHashMap(u64, u16).init(arena);
    defer sig_to_class.deinit();

    var byte_to_class: [256]u8 = undefined;
    var representatives: [256]u8 = undefined;
    var n_classes: u16 = 0;

    for (0..256) |b| {
        const sig = sigs[b];
        if (sig_to_class.get(sig)) |existing| {
            byte_to_class[b] = @intCast(existing);
        } else {
            const c = n_classes;
            try sig_to_class.put(sig, c);
            representatives[c] = @intCast(b);
            byte_to_class[b] = @intCast(c);
            n_classes += 1;
        }
    }

    return .{
        .byte_to_class = byte_to_class,
        .n_classes = n_classes,
        .representatives = representatives,
    };
}

// ── Internals ──

const Predicate = union(enum) {
    byte: u8,
    any,
    class: *const ast.Class,
};

fn collectPredicates(node: *const ast.Node, arena: std.mem.Allocator, out: *std.ArrayList(Predicate)) Error!void {
    switch (node.*) {
        .literal => |c| try out.append(arena, .{ .byte = c }),
        .dot => try out.append(arena, .any),
        .class => |cls| try out.append(arena, .{ .class = cls }),
        .anchor => {}, // zero-width — doesn't partition bytes
        .concat => |children| for (children) |c| try collectPredicates(c, arena, out),
        .alt => |children| for (children) |c| try collectPredicates(c, arena, out),
        .repeat => |r| try collectPredicates(r.sub, arena, out),
        .group => |g| try collectPredicates(g.sub, arena, out),
    }
}

fn matches(p: Predicate, b: u8, dot_all: bool) bool {
    return switch (p) {
        .byte => |v| v == b,
        .any => dot_all or b != '\n',
        .class => |cls| cls.contains(b),
    };
}

fn singleClass() Table {
    var bts: [256]u8 = undefined;
    @memset(&bts, 0);
    var reps: [256]u8 = undefined;
    @memset(&reps, 0);
    return .{ .byte_to_class = bts, .n_classes = 1, .representatives = reps };
}

fn identity() Table {
    var bts: [256]u8 = undefined;
    var reps: [256]u8 = undefined;
    for (0..256) |i| {
        bts[i] = @intCast(i);
        reps[i] = @intCast(i);
    }
    return .{ .byte_to_class = bts, .n_classes = 256, .representatives = reps };
}

// ── Tests ──

const parser = @import("parser.zig");

fn buildFor(pattern: []const u8, dot_all: bool) !Table {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(arena.allocator(), pattern);
    const root = try p.parseRoot();
    return try build(std.testing.allocator, root, dot_all);
}

test "minterm: single class for a-z+" {
    const t = try buildFor("[a-z]+", false);
    // {a..z} ⇒ one class, everything else ⇒ another. 2 classes.
    try std.testing.expectEqual(@as(u16, 2), t.n_classes);
    try std.testing.expectEqual(t.byte_to_class['a'], t.byte_to_class['z']);
    try std.testing.expect(t.byte_to_class['a'] != t.byte_to_class['A']);
}

test "minterm: pure-literal pattern splits each distinct byte" {
    const t = try buildFor("abc", false);
    // 'a', 'b', 'c' each get a class; everything else is one more. 4.
    try std.testing.expectEqual(@as(u16, 4), t.n_classes);
    try std.testing.expect(t.byte_to_class['a'] != t.byte_to_class['b']);
    try std.testing.expect(t.byte_to_class['b'] != t.byte_to_class['c']);
}

test "minterm: dot collapses everything except newline" {
    const t = try buildFor("a.b", false);
    // Classes: 'a', 'b', '\n' (because . doesn't match it), and "rest".
    try std.testing.expectEqual(@as(u16, 4), t.n_classes);
    try std.testing.expect(t.byte_to_class['\n'] != t.byte_to_class['x']);
}

test "minterm: dot-all collapses newline with the rest" {
    const t = try buildFor("a.b", true);
    // With dot_all the . matches \n too. So \n joins the "rest" class.
    // Classes: 'a', 'b', "rest" (incl '\n'). 3.
    try std.testing.expectEqual(@as(u16, 3), t.n_classes);
    try std.testing.expectEqual(t.byte_to_class['\n'], t.byte_to_class['x']);
}

test "minterm: anchors don't partition bytes" {
    const t = try buildFor("^abc$", false);
    // ^ and $ are zero-width, they don't appear in the predicate list.
    // Classes are the same as for "abc": 'a', 'b', 'c', "rest" = 4.
    try std.testing.expectEqual(@as(u16, 4), t.n_classes);
}

test "minterm: representatives are valid bytes in their class" {
    const t = try buildFor("[a-z]+", false);
    var c: u16 = 0;
    while (c < t.n_classes) : (c += 1) {
        const rep = t.representatives[c];
        try std.testing.expectEqual(@as(u16, c), @as(u16, t.byte_to_class[rep]));
    }
}
