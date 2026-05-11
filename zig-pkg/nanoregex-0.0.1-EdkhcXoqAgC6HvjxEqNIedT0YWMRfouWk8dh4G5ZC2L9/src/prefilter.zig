//! Compile-time pattern analysis for fast-path optimisations.
//!
//! Two analyses, both consumed by `findAll`:
//!
//! 1. `extractFullLiteral` — when the AST is purely literal (literal bytes,
//!    optional non-capturing concat/group wrapping, no metacharacters, no
//!    capture groups), returns the literal byte sequence. Callers can then
//!    bypass the NFA entirely and use `std.mem.indexOf` in a loop — a
//!    50-100x win on patterns like `compileAllocFlags` that came in as
//!    "regex" but have no actual regex content.
//!
//! 2. `extractRequiredLiteral` — for genuinely-regex patterns, finds the
//!    longest contiguous run of bytes that MUST appear in any successful
//!    match. Callers use it as a pre-filter: if the haystack doesn't
//!    contain the substring, no match exists and we skip the engine. When
//!    the haystack does contain it, we still gate engine work to windows
//!    around hits via `findOccurrences`.
//!
//! Both analyses are conservative: when in doubt, they return null/empty so
//! the matcher falls back to the full engine. The unit tests pin down what
//! we extract for each shape.

const std = @import("std");
const ast = @import("ast.zig");

/// If the AST is purely literal — only `.literal` / `.concat` / non-capturing
/// `.group` nodes — flatten it to a single byte slice. Returns null when any
/// regex feature (dot, class, anchor, alt, repeat, capturing group) is
/// present. The returned slice is arena-allocated.
pub fn extractFullLiteral(arena: std.mem.Allocator, root: *const ast.Node) !?[]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(arena);
    if (!try collectLiteral(root, arena, &buf)) {
        buf.deinit(arena);
        return null;
    }
    if (buf.items.len == 0) {
        buf.deinit(arena);
        return null;
    }
    return try buf.toOwnedSlice(arena);
}

fn collectLiteral(node: *const ast.Node, arena: std.mem.Allocator, buf: *std.ArrayList(u8)) !bool {
    return switch (node.*) {
        .literal => |c| {
            try buf.append(arena, c);
            return true;
        },
        .concat => |children| {
            for (children) |child| {
                if (!try collectLiteral(child, arena, buf)) return false;
            }
            return true;
        },
        .group => |g| {
            // A capturing group changes externally-observable behaviour
            // (callers may want span info), so bail out and let the engine
            // handle it. Non-capturing groups are pure parens; transparent.
            if (g.capturing) return false;
            return collectLiteral(g.sub, arena, buf);
        },
        .dot, .class, .anchor, .alt, .repeat => false,
    };
}

/// Find the longest run of unconditionally-required literal bytes inside
/// the pattern. "Required" means every successful match must contain these
/// bytes contiguously. Returns null when no run of length ≥ `min_len` can
/// be extracted; below that threshold the prefilter overhead beats the
/// win.
pub fn extractRequiredLiteral(arena: std.mem.Allocator, root: *const ast.Node, min_len: usize) !?[]const u8 {
    var best: std.ArrayList(u8) = .empty;
    errdefer best.deinit(arena);
    var current: std.ArrayList(u8) = .empty;
    defer current.deinit(arena);

    try walkRequired(root, arena, &current, &best);
    // Final flush in case the longest run ends at the AST tail.
    if (current.items.len > best.items.len) {
        best.deinit(arena);
        best = current;
        current = .empty;
    }

    if (best.items.len < min_len) {
        best.deinit(arena);
        return null;
    }
    return try best.toOwnedSlice(arena);
}

fn walkRequired(
    node: *const ast.Node,
    arena: std.mem.Allocator,
    current: *std.ArrayList(u8),
    best: *std.ArrayList(u8),
) error{OutOfMemory}!void {
    switch (node.*) {
        .literal => |c| try current.append(arena, c),
        .concat => |children| for (children) |child| try walkRequired(child, arena, current, best),
        .group => |g| try walkRequired(g.sub, arena, current, best),
        .repeat => |r| {
            // The sub-pattern is required iff min ≥ 1. When it is, treat the
            // first mandatory copy as additional bytes in the current run.
            // Past that, the rest can repeat-with-variation so we flush
            // and start fresh.
            if (r.min >= 1) {
                try walkRequired(r.sub, arena, current, best);
            }
            try flush(current, best, arena);
        },
        .dot, .class, .anchor => try flush(current, best, arena),
        .alt => {
            // We could pick the longest common prefix across branches but
            // for v1 we bail conservatively — the run ends here.
            try flush(current, best, arena);
        },
    }
}

fn flush(current: *std.ArrayList(u8), best: *std.ArrayList(u8), arena: std.mem.Allocator) !void {
    if (current.items.len > best.items.len) {
        best.deinit(arena);
        best.* = current.*;
        current.* = .empty;
    } else {
        current.clearRetainingCapacity();
    }
}

/// Extract the contiguous literal byte sequence at the very START of the
/// pattern, if any. Differs from `extractRequiredLiteral` in two ways:
///   - We anchor at the pattern start instead of picking the longest run.
///   - Callers can use the result as a STARTING-POSITION hint: every match
///     must begin where this byte sequence occurs in the haystack.
///
/// Bails on alternation at the top level (different branches → different
/// possible prefixes; we'd need their common prefix). Returns null when
/// the prefix is shorter than `min_len`, the threshold below which the
/// indexOf-and-resume overhead beats the engine.
pub fn extractLiteralPrefix(arena: std.mem.Allocator, root: *const ast.Node, min_len: usize) !?[]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(arena);
    _ = collectPrefix(root, arena, &buf) catch |err| switch (err) {
        error.OutOfMemory => return err,
    };
    if (buf.items.len < min_len) {
        buf.deinit(arena);
        return null;
    }
    return try buf.toOwnedSlice(arena);
}

/// Walk the AST left-to-right adding ONLY contiguous required literal
/// bytes at the start. Stops at the first non-literal node (or at a
/// quantifier that makes a byte optional).
/// Returns true iff the prefix collection can continue past this node.
fn collectPrefix(node: *const ast.Node, arena: std.mem.Allocator, buf: *std.ArrayList(u8)) error{OutOfMemory}!bool {
    switch (node.*) {
        .literal => |c| {
            try buf.append(arena, c);
            return true;
        },
        .concat => |children| {
            for (children) |child| {
                const ok = try collectPrefix(child, arena, buf);
                if (!ok) return false;
            }
            return true;
        },
        .group => |g| return collectPrefix(g.sub, arena, buf),
        .repeat => |r| {
            // A repeat with min ≥ 1 contributes one mandatory copy of its
            // sub-pattern's prefix. With min == 0, the entire repeat is
            // optional and contributes nothing.
            if (r.min >= 1) _ = try collectPrefix(r.sub, arena, buf);
            // Always stop here — beyond the first mandatory copy the
            // repeat could match more bytes, but they're not part of a
            // CONTIGUOUS prefix every match shares.
            return false;
        },
        // Class, dot, anchor, and alt all end the prefix.
        .class, .dot, .anchor, .alt => return false,
    }
}


// ── Tests ──

const parser = @import("parser.zig");

fn fullFor(alloc: std.mem.Allocator, pattern: []const u8) !?[]const u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var p = parser.Parser.init(arena.allocator(), pattern);
    const root = try p.parseRoot();
    const lit = try extractFullLiteral(arena.allocator(), root);
    if (lit) |bytes| return try alloc.dupe(u8, bytes);
    return null;
}

fn requiredFor(alloc: std.mem.Allocator, pattern: []const u8) !?[]const u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var p = parser.Parser.init(arena.allocator(), pattern);
    const root = try p.parseRoot();
    const lit = try extractRequiredLiteral(arena.allocator(), root, 3);
    if (lit) |bytes| return try alloc.dupe(u8, bytes);
    return null;
}

fn prefixFor(alloc: std.mem.Allocator, pattern: []const u8) !?[]const u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var p = parser.Parser.init(arena.allocator(), pattern);
    const root = try p.parseRoot();
    const lit = try extractLiteralPrefix(arena.allocator(), root, 3);
    if (lit) |bytes| return try alloc.dupe(u8, bytes);
    return null;
}

test "full literal: plain identifier" {
    const got = (try fullFor(std.testing.allocator, "compileAllocFlags")).?;
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("compileAllocFlags", got);
}

test "full literal: non-capturing group is transparent" {
    const got = (try fullFor(std.testing.allocator, "(?:abc)def")).?;
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("abcdef", got);
}

test "full literal: capturing group blocks" {
    try std.testing.expect((try fullFor(std.testing.allocator, "(abc)")) == null);
}

test "full literal: dot blocks" {
    try std.testing.expect((try fullFor(std.testing.allocator, "a.b")) == null);
}

test "full literal: class blocks" {
    try std.testing.expect((try fullFor(std.testing.allocator, "a[bc]")) == null);
}

test "full literal: alternation blocks" {
    try std.testing.expect((try fullFor(std.testing.allocator, "abc|def")) == null);
}

test "full literal: repeat blocks" {
    try std.testing.expect((try fullFor(std.testing.allocator, "ab+")) == null);
}

test "required literal: extracts prefix before class" {
    const got = (try requiredFor(std.testing.allocator, "compileAllocFlags\\([a-z]+")).?;
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("compileAllocFlags(", got);
}

test "required literal: picks longest run" {
    const got = (try requiredFor(std.testing.allocator, "[a-z]hello\\d+worlds\\s+end")).?;
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("worlds", got);
}

test "required literal: too short returns null" {
    try std.testing.expect((try requiredFor(std.testing.allocator, "a.b")) == null);
}

test "required literal: alternation bails" {
    try std.testing.expect((try requiredFor(std.testing.allocator, "foo|bar")) == null);
}

test "required literal: min=0 quantifier doesn't contribute" {
    // 'a*bar' — 'a' is optional, so the required run is 'bar'.
    const got = (try requiredFor(std.testing.allocator, "a*barbaz")).?;
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("barbaz", got);
}

test "required literal: min=1 quantifier contributes single copy" {
    // 'a+bar' — 'a' is required (at least once), then 'bar'.
    // After walking the repeat, we flush — so 'a' alone is the run, but
    // 'bar' is longer. Best = 'bar'.
    const got = (try requiredFor(std.testing.allocator, "a+barbaz")).?;
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("barbaz", got);
}

test "literal prefix: simple identifier" {
    const got = (try prefixFor(std.testing.allocator, "compileAllocFlags\\([a-z]+")).?;
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("compileAllocFlags(", got);
}

test "literal prefix: class at start bails" {
    try std.testing.expect((try prefixFor(std.testing.allocator, "[a-z]+hello")) == null);
}

test "literal prefix: alternation at top bails" {
    try std.testing.expect((try prefixFor(std.testing.allocator, "foo|bar")) == null);
}

test "literal prefix: under threshold returns null" {
    try std.testing.expect((try prefixFor(std.testing.allocator, "ab.c")) == null);
}

test "literal prefix: stops at optional byte" {
    // `foox?bar` — 'foo' is mandatory, then 'x?' is optional, so prefix is 'foo'.
    const got = (try prefixFor(std.testing.allocator, "foox?bar")).?;
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("foo", got);
}
