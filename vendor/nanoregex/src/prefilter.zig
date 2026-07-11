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

/// Walk the AST left-to-right adding ONLY contiguous required literal bytes at
/// the start. Returns `false` when the prefix must stop here — at a non-literal
/// node, or after a quantifier. A quantifier ends the contiguous prefix even
/// when it contributes a mandatory copy: bytes past that copy land at a variable
/// offset, so nothing after the repeat may join the prefix. Without this, `hel+o`
/// yielded the prefix `helo`, which wrongly demands the `o` sit immediately after
/// a single `l` — making `search` miss `helllo` entirely.
fn collectPrefix(node: *const ast.Node, arena: std.mem.Allocator, buf: *std.ArrayList(u8)) error{OutOfMemory}!bool {
    switch (node.*) {
        .literal => |c| {
            try buf.append(arena, c);
            return true;
        },
        .concat => |children| {
            for (children) |child| {
                const cont = try collectPrefix(child, arena, buf);
                if (!cont) return false;
            }
            return true;
        },
        .group => |g| return try collectPrefix(g.sub, arena, buf),
        .repeat => |r| {
            // min ≥ 1 contributes one mandatory copy of the sub-pattern's
            // prefix; min == 0 contributes nothing. Either way the contiguous
            // prefix ends here — the repeat may match more bytes, pushing
            // anything that follows to a variable offset.
            if (r.min >= 1) _ = try collectPrefix(r.sub, arena, buf);
            return false;
        },
        // Class, dot, anchor, and alt all end the prefix.
        .class, .dot, .anchor, .alt => return false,
    }
}

/// If the entire AST is a single `class+` or `class{n,}` quantifier (e.g.
/// `\d+`, `[a-z]+`, `\w{2,}`), return the underlying class so callers can
/// dispatch to a specialised SIMD-only scanner: "first byte in class →
/// first byte not in class → emit; repeat." Avoids the DFA entirely and
/// runs at memmem speed.
///
/// Returns null for any compound shape (concat, alt, group with non-trivial
/// structure, anchors, etc.) — those need the real engine.
pub fn extractSingleClassRepeat(root: *const ast.Node) ?*const ast.Class {
    // Allow `(?:class+)` and `(class+)` wrapping but only if the group is
    // non-capturing (we don't track group spans on this path).
    var n = root;
    while (true) {
        switch (n.*) {
            .group => |g| if (!g.capturing) {
                n = g.sub;
                continue;
            } else return null,
            else => break,
        }
    }
    switch (n.*) {
        .repeat => |r| {
            if (r.min < 1) return null; // min=0 has a zero-width quirk we skip
            if (r.max != std.math.maxInt(u32)) return null;
            switch (r.sub.*) {
                .class => |cls| return cls,
                else => return null,
            }
        },
        else => return null,
    }
}

/// If the entire AST is a pure literal alternation — `foo|bar|baz`, with
/// each branch a concat of `.literal` nodes only — return the branch byte
/// strings. Callers dispatch to a multi-literal scanner that finds the
/// earliest match across all needles via per-needle `indexOfPos`. This is
/// the same niche `aho-corasick`'s Teddy fills for ripgrep.
///
/// Returns null for any branch that isn't purely literal, or for a single
/// branch (that'd already be caught by `extractFullLiteral`). Caller owns
/// the returned slice via the passed arena.
pub fn extractLiteralAlternation(arena: std.mem.Allocator, root: *const ast.Node) !?[]const []const u8 {
    // Unwrap one layer of non-capturing group at the root (very common
    // shape from `(?:foo|bar)`).
    var n = root;
    if (n.* == .group) {
        const g = n.group;
        if (g.capturing) return null;
        n = g.sub;
    }
    if (n.* != .alt) return null;
    const branches = n.alt;
    if (branches.len < 2) return null;

    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |b| arena.free(b);
        out.deinit(arena);
    }
    for (branches) |branch| {
        var bytes: std.ArrayList(u8) = .empty;
        errdefer bytes.deinit(arena);
        if (!try collectBranchLiteral(branch, arena, &bytes)) {
            bytes.deinit(arena);
            for (out.items) |b| arena.free(b);
            out.deinit(arena);
            return null;
        }
        if (bytes.items.len == 0) {
            // Empty branch — would match at every position, not worth this fast path.
            bytes.deinit(arena);
            for (out.items) |b| arena.free(b);
            out.deinit(arena);
            return null;
        }
        try out.append(arena, try bytes.toOwnedSlice(arena));
    }
    return try out.toOwnedSlice(arena);
}

fn collectBranchLiteral(node: *const ast.Node, arena: std.mem.Allocator, buf: *std.ArrayList(u8)) !bool {
    return switch (node.*) {
        .literal => |c| blk: {
            try buf.append(arena, c);
            break :blk true;
        },
        .concat => |children| blk: {
            for (children) |child| {
                if (!try collectBranchLiteral(child, arena, buf)) break :blk false;
            }
            break :blk true;
        },
        .group => |g| if (g.capturing) false else collectBranchLiteral(g.sub, arena, buf),
        else => false,
    };
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

fn singleClassFor(pattern: []const u8) !bool {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(arena.allocator(), pattern);
    const root = try p.parseRoot();
    return extractSingleClassRepeat(root) != null;
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

test "literal prefix: stops after + quantifier (regression)" {
    // `hel+o` — the contiguous start prefix is `hel`, never `helo`: the `o`
    // sits at a variable offset after one-or-more `l`. Demanding `helo` as a
    // starting-position hint made `search` miss `helllo` outright.
    const got = (try prefixFor(std.testing.allocator, "hel+o")).?;
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("hel", got);
}

test "literal prefix: stops after {n,m} quantifier (regression)" {
    const got = (try prefixFor(std.testing.allocator, "hel{1,3}o")).?;
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("hel", got);
}

test "literal prefix: stops at optional byte" {
    // `foox?bar` — 'foo' is mandatory, then 'x?' is optional, so prefix is 'foo'.
    const got = (try prefixFor(std.testing.allocator, "foox?bar")).?;
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("foo", got);
}

test "single-class-repeat: \\d+" {
    try std.testing.expect(try singleClassFor("\\d+"));
}

test "single-class-repeat: [a-z]+" {
    try std.testing.expect(try singleClassFor("[a-z]+"));
}

test "single-class-repeat: counted lower bound" {
    try std.testing.expect(try singleClassFor("[0-9]{3,}"));
}

test "single-class-repeat: non-capturing group is transparent" {
    try std.testing.expect(try singleClassFor("(?:\\w+)"));
}

test "single-class-repeat: capturing group blocks" {
    try std.testing.expect(!(try singleClassFor("(\\w+)")));
}

test "single-class-repeat: concat blocks" {
    try std.testing.expect(!(try singleClassFor("\\d+abc")));
}

test "single-class-repeat: alternation blocks" {
    try std.testing.expect(!(try singleClassFor("\\d+|abc")));
}

test "single-class-repeat: star (min=0) skipped" {
    // min=0 has a zero-width-match quirk — not yet handled by the fast path.
    try std.testing.expect(!(try singleClassFor("\\d*")));
}

fn altLiteralFor(alloc: std.mem.Allocator, pattern: []const u8) !?[][]const u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var p = parser.Parser.init(arena.allocator(), pattern);
    const root = try p.parseRoot();
    const lits = try extractLiteralAlternation(arena.allocator(), root);
    if (lits) |bs| {
        var owned = try alloc.alloc([]const u8, bs.len);
        for (bs, 0..) |b, i| owned[i] = try alloc.dupe(u8, b);
        return owned;
    }
    return null;
}

test "literal alternation: three branches" {
    const got = (try altLiteralFor(std.testing.allocator, "foo|bar|baz")).?;
    defer {
        for (got) |b| std.testing.allocator.free(b);
        std.testing.allocator.free(got);
    }
    try std.testing.expectEqual(@as(usize, 3), got.len);
    try std.testing.expectEqualStrings("foo", got[0]);
    try std.testing.expectEqualStrings("bar", got[1]);
    try std.testing.expectEqualStrings("baz", got[2]);
}

test "literal alternation: non-capturing group wraps" {
    const got = (try altLiteralFor(std.testing.allocator, "(?:cat|dog|bird)")).?;
    defer {
        for (got) |b| std.testing.allocator.free(b);
        std.testing.allocator.free(got);
    }
    try std.testing.expectEqual(@as(usize, 3), got.len);
}

test "literal alternation: bails on non-literal branch" {
    try std.testing.expect((try altLiteralFor(std.testing.allocator, "foo|b.r")) == null);
}

test "literal alternation: bails on capturing group" {
    try std.testing.expect((try altLiteralFor(std.testing.allocator, "(foo|bar)")) == null);
}

test "literal alternation: single branch is null" {
    // Only one branch — handled by extractFullLiteral, not this path.
    try std.testing.expect((try altLiteralFor(std.testing.allocator, "foo")) == null);
}
