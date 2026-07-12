//! comptime.zig — comptime-specialised regex matchers.
//!
//! `compileComptime(pattern)` returns a `ComptimeRegex(pattern)` whose
//! internals are fully resolved at compile time for two pattern shapes:
//!
//!   1. Pure literal  — no metacharacters → tight `std.mem.indexOf` loop
//!      with the needle baked as a `*const [N]u8` constant.
//!
//!   2. Single-class quantifier — `\d+`, `[a-z]+`, `\w{2,}`, etc. → a
//!      256-element `[256]bool` membership table baked into `.rodata` at
//!      compile time; the hot loop is a single `table[b]` lookup per byte.
//!
//! Any other pattern shape falls back to the runtime `Regex.compile` path.
//! The fallback is wrapped in the same API surface so callers don't need to
//! branch.
//!
//! # Usage
//!
//!   const cx = comptime nanoregex.compileComptime("\\d+");
//!   const matches = try cx.findAll(allocator, haystack);
//!   defer { for (matches) |*m| @constCast(m).deinit(allocator); allocator.free(matches); }
//!
//! Note: `cx` is a value type (no heap, no deinit needed). The `findAll` and
//! `search` methods do allocate for the returned Match slices.

const std = @import("std");
const root = @import("root.zig");

pub const Span = root.Span;
pub const Match = root.Match;

// ── Pattern classification (all comptime) ──────────────────────────────────

/// Classify a pattern string into one of three shapes that we can
/// specialize at compile time.
const PatternKind = enum {
    /// Pattern has no metacharacters — every byte is literal.
    pure_literal,
    /// Pattern is exactly `CLASS+` or `CLASS{n,}` where CLASS is one of:
    ///   `\d`, `\D`, `\w`, `\W`, `\s`, `\S`, or `[...]`.
    /// We bake the 256-bool membership table into `.rodata`.
    single_class_plus,
    /// Everything else — delegate to the runtime engine.
    runtime_fallback,
};

/// Returns true iff `c` is a regex metacharacter that may alter meaning.
fn isMeta(c: u8) bool {
    return switch (c) {
        '.', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|', '^', '$', '\\' => true,
        else => false,
    };
}

/// Classify `pattern` at comptime.
fn classify(comptime pattern: []const u8) PatternKind {
    if (pattern.len == 0) return .pure_literal;

    // Check for pure literal: no metacharacters at all.
    var has_meta = false;
    for (pattern) |c| {
        if (isMeta(c)) {
            has_meta = true;
            break;
        }
    }
    if (!has_meta) return .pure_literal;

    // Check for single-class-plus:  CLASS+ or CLASS{n,}
    // CLASS is one of the shorthand escapes \d \D \w \W \s \S, or a
    // bracket expression [...]. We do a lightweight hand-rolled parse
    // here (no allocator, comptime-safe).
    return classifyAsSingleClass(pattern);
}

/// Lightweight comptime check: is `pattern` exactly `CLASS+` or `CLASS{n,}`?
fn classifyAsSingleClass(comptime pattern: []const u8) PatternKind {
    if (pattern.len < 2) return .runtime_fallback;

    // Unwrap optional non-capturing group `(?:...)` at the very outside.
    const inner: []const u8 = blk: {
        if (pattern.len > 4 and
            pattern[0] == '(' and pattern[1] == '?' and pattern[2] == ':' and
            pattern[pattern.len - 1] == ')')
        {
            break :blk pattern[3 .. pattern.len - 1];
        }
        break :blk pattern;
    };

    // Determine the class span and the quantifier that follows it.
    var class_end: usize = 0;
    if (inner[0] == '\\') {
        // Shorthand escape: \d \D \w \W \s \S
        if (inner.len < 2) return .runtime_fallback;
        switch (inner[1]) {
            'd', 'D', 'w', 'W', 's', 'S' => class_end = 2,
            else => return .runtime_fallback,
        }
    } else if (inner[0] == '[') {
        // Bracket expression — scan forward for the closing `]`.
        // Handle `[^...]` negation and `[]...]` (literal `]` first).
        var i: usize = 1;
        if (i < inner.len and inner[i] == '^') i += 1;
        if (i < inner.len and inner[i] == ']') i += 1; // literal `]` at start
        while (i < inner.len and inner[i] != ']') i += 1;
        if (i >= inner.len) return .runtime_fallback;
        class_end = i + 1; // include the `]`
    } else {
        return .runtime_fallback;
    }

    // What follows the class?
    const quant = inner[class_end..];
    // Accept: `+`, `{n,}`, `{n,m}` where n >= 1
    if (quant.len == 0) return .runtime_fallback;
    if (quant[0] == '+') {
        if (quant.len == 1) return .single_class_plus;
        return .runtime_fallback;
    }
    if (quant[0] == '{') {
        // Minimal parse: must have a digit, then `,`, optionally digits, then `}`.
        var i: usize = 1;
        if (i >= quant.len or quant[i] < '0' or quant[i] > '9') return .runtime_fallback;
        // Read the min value; reject min == 0.
        var min_val: usize = 0;
        while (i < quant.len and quant[i] >= '0' and quant[i] <= '9') {
            min_val = min_val * 10 + (quant[i] - '0');
            i += 1;
        }
        if (min_val == 0) return .runtime_fallback;
        if (i >= quant.len or quant[i] != ',') return .runtime_fallback;
        i += 1; // skip ','
        // Optional upper bound digits.
        while (i < quant.len and quant[i] >= '0' and quant[i] <= '9') i += 1;
        if (i >= quant.len or quant[i] != '}') return .runtime_fallback;
        if (i + 1 == quant.len) return .single_class_plus;
        return .runtime_fallback;
    }
    return .runtime_fallback;
}

// ── Comptime membership table generation ──────────────────────────────────

/// Build a `[256]bool` membership table for the CLASS at the front of
/// `pattern` (same syntax as `classifyAsSingleClass` recognises).
/// Called at comptime so the array lives in `.rodata`.
fn buildClassTable(comptime pattern: []const u8) [256]bool {
    // Strip outer (?:...) group if present.
    const inner: []const u8 = blk: {
        if (pattern.len > 4 and
            pattern[0] == '(' and pattern[1] == '?' and pattern[2] == ':' and
            pattern[pattern.len - 1] == ')')
        {
            break :blk pattern[3 .. pattern.len - 1];
        }
        break :blk pattern;
    };

    var table: [256]bool = @splat(false);

    if (inner[0] == '\\') {
        // Shorthand escape.
        switch (inner[1]) {
            'd' => {
                var b: usize = '0';
                while (b <= '9') : (b += 1) table[b] = true;
            },
            'D' => {
                var b: usize = 0;
                while (b < 256) : (b += 1) {
                    if (b < '0' or b > '9') table[b] = true;
                }
            },
            'w' => {
                var b: usize = 0;
                while (b < 256) : (b += 1) {
                    const c: u8 = @intCast(b);
                    if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
                        (c >= '0' and c <= '9') or c == '_') table[b] = true;
                }
            },
            'W' => {
                var b: usize = 0;
                while (b < 256) : (b += 1) {
                    const c: u8 = @intCast(b);
                    if (!((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
                        (c >= '0' and c <= '9') or c == '_')) table[b] = true;
                }
            },
            's' => {
                for ([_]u8{ ' ', '\t', '\n', '\r', 0x0C, 0x0B }) |c| table[c] = true;
            },
            'S' => {
                var b: usize = 0;
                while (b < 256) : (b += 1) {
                    const c: u8 = @intCast(b);
                    if (c != ' ' and c != '\t' and c != '\n' and c != '\r' and
                        c != 0x0C and c != 0x0B) table[b] = true;
                }
            },
            else => {},
        }
        return table;
    }

    // Bracket expression `[...]` or `[^...]`.
    std.debug.assert(inner[0] == '[');
    var i: usize = 1;
    var negate = false;
    if (i < inner.len and inner[i] == '^') {
        negate = true;
        i += 1;
    }

    // Handle literal `]` as first char inside brackets.
    if (i < inner.len and inner[i] == ']') {
        table[']'] = true;
        i += 1;
    }

    while (i < inner.len and inner[i] != ']') {
        if (i + 2 < inner.len and inner[i + 1] == '-' and inner[i + 2] != ']') {
            // Range a-z.
            var lo: usize = inner[i];
            const hi: usize = inner[i + 2];
            while (lo <= hi) : (lo += 1) table[lo] = true;
            i += 3;
        } else if (inner[i] == '\\' and i + 1 < inner.len) {
            // Escape inside bracket.
            switch (inner[i + 1]) {
                'd' => {
                    var b: usize = '0';
                    while (b <= '9') : (b += 1) table[b] = true;
                },
                'w' => {
                    var b: usize = 0;
                    while (b < 256) : (b += 1) {
                        const c: u8 = @intCast(b);
                        if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
                            (c >= '0' and c <= '9') or c == '_') table[b] = true;
                    }
                },
                's' => {
                    for ([_]u8{ ' ', '\t', '\n', '\r', 0x0C, 0x0B }) |c| table[c] = true;
                },
                'n' => table['\n'] = true,
                't' => table['\t'] = true,
                'r' => table['\r'] = true,
                else => table[inner[i + 1]] = true,
            }
            i += 2;
        } else {
            table[inner[i]] = true;
            i += 1;
        }
    }

    if (negate) {
        for (&table) |*b| b.* = !b.*;
    }
    return table;
}

// ── Core scanner functions ─────────────────────────────────────────────────

/// Find the first match using a compile-time-known literal needle.
fn literalFirst(comptime needle: []const u8, alloc: std.mem.Allocator, haystack: []const u8) !?Match {
    if (needle.len == 0) {
        const caps = try alloc.alloc(?Span, 1);
        caps[0] = .{ .start = 0, .end = 0 };
        return .{ .span = .{ .start = 0, .end = 0 }, .captures = caps };
    }
    const idx = std.mem.indexOf(u8, haystack, needle) orelse return null;
    const caps = try alloc.alloc(?Span, 1);
    caps[0] = .{ .start = idx, .end = idx + needle.len };
    return .{ .span = .{ .start = idx, .end = idx + needle.len }, .captures = caps };
}

/// Find all matches using a compile-time-known literal needle.
fn literalAll(comptime needle: []const u8, alloc: std.mem.Allocator, haystack: []const u8) ![]Match {
    var results: std.ArrayList(Match) = .empty;
    errdefer {
        for (results.items) |*m| @constCast(m).deinit(alloc);
        results.deinit(alloc);
    }
    if (needle.len == 0) return try results.toOwnedSlice(alloc);
    var pos: usize = 0;
    while (pos <= haystack.len) {
        const idx = std.mem.indexOfPos(u8, haystack, pos, needle) orelse break;
        const caps = try alloc.alloc(?Span, 1);
        caps[0] = .{ .start = idx, .end = idx + needle.len };
        try results.append(alloc, .{ .span = .{ .start = idx, .end = idx + needle.len }, .captures = caps });
        pos = idx + needle.len;
        if (needle.len == 0) break; // guard against empty-needle infinite loop
    }
    return try results.toOwnedSlice(alloc);
}

/// Find the first match using a compile-time membership table.
fn classFirst(comptime table: *const [256]bool, alloc: std.mem.Allocator, input: []const u8) !?Match {
    var i: usize = 0;
    while (i < input.len) {
        if (table[input[i]]) {
            const start = i;
            while (i < input.len and table[input[i]]) i += 1;
            const caps = try alloc.alloc(?Span, 1);
            caps[0] = .{ .start = start, .end = i };
            return .{ .span = .{ .start = start, .end = i }, .captures = caps };
        }
        i += 1;
    }
    return null;
}

/// Find all matches using a compile-time membership table.
fn classAll(comptime table: *const [256]bool, alloc: std.mem.Allocator, input: []const u8) ![]Match {
    var out: std.ArrayList(Match) = .empty;
    errdefer {
        for (out.items) |*m| @constCast(m).deinit(alloc);
        out.deinit(alloc);
    }
    var i: usize = 0;
    while (i < input.len) {
        if (table[input[i]]) {
            const start = i;
            while (i < input.len and table[input[i]]) i += 1;
            const caps = try alloc.alloc(?Span, 1);
            caps[0] = .{ .start = start, .end = i };
            try out.append(alloc, .{ .span = .{ .start = start, .end = i }, .captures = caps });
        } else {
            i += 1;
        }
    }
    return try out.toOwnedSlice(alloc);
}

// ── Public API ─────────────────────────────────────────────────────────────

/// A pattern-specialised matcher.  The concrete type (and its `search` /
/// `findAll` implementation) are chosen at compile time based on the
/// pattern's shape.  Callers never call `deinit` on the `ComptimeRegex`
/// value itself — there's nothing to free.
pub fn ComptimeRegex(comptime pattern: []const u8) type {
    const kind = classify(pattern);
    return switch (kind) {
        .pure_literal => struct {
            const needle: []const u8 = pattern;

            pub fn search(self: @This(), alloc: std.mem.Allocator, input: []const u8) !?Match {
                _ = self;
                return literalFirst(needle, alloc, input);
            }
            pub fn findAll(self: @This(), alloc: std.mem.Allocator, input: []const u8) ![]Match {
                _ = self;
                return literalAll(needle, alloc, input);
            }
        },
        .single_class_plus => struct {
            const table: [256]bool = buildClassTable(pattern);

            pub fn search(self: @This(), alloc: std.mem.Allocator, input: []const u8) !?Match {
                _ = self;
                return classFirst(&table, alloc, input);
            }
            pub fn findAll(self: @This(), alloc: std.mem.Allocator, input: []const u8) ![]Match {
                _ = self;
                return classAll(&table, alloc, input);
            }
        },
        .runtime_fallback => struct {
            // Thin wrapper: we call Regex.compile at first use (lazy) or
            // callers can use this struct as a value and call the runtime path.
            //
            // Because we can't store a Regex by value here without an
            // allocator, the runtime fallback re-compiles on each call. This
            // is intentional: the comptime path is only meant for patterns
            // that ARE pure-literal or single-class. For everything else the
            // normal Regex API should be used. The fallback here exists only
            // so callers don't need to branch.
            pub fn search(self: @This(), alloc: std.mem.Allocator, input: []const u8) !?Match {
                _ = self;
                var r = try root.Regex.compile(alloc, pattern);
                defer r.deinit();
                return r.search(alloc, input);
            }
            pub fn findAll(self: @This(), alloc: std.mem.Allocator, input: []const u8) ![]Match {
                _ = self;
                var r = try root.Regex.compile(alloc, pattern);
                defer r.deinit();
                return r.findAll(alloc, input);
            }
        },
    };
}

/// Construct a `ComptimeRegex(pattern)` value.  Call with a comptime-known
/// string literal; the compiler constant-folds the entire specialisation.
///
///   const cx = comptime compileComptime("hello");
///   const m = try cx.findAll(allocator, "say hello world");
pub fn compileComptime(comptime pattern: []const u8) ComptimeRegex(pattern) {
    return .{};
}

// ── Tests ──────────────────────────────────────────────────────────────────

test "comptime: pure-literal findAll matches runtime path" {
    const cx = comptime compileComptime("hello");
    const haystack = "say hello world, hello again";
    const ms = try cx.findAll(std.testing.allocator, haystack);
    defer {
        for (ms) |*m| @constCast(m).deinit(std.testing.allocator);
        std.testing.allocator.free(ms);
    }
    // Runtime reference
    var r = try root.Regex.compile(std.testing.allocator, "hello");
    defer r.deinit();
    const rt_ms = try r.findAll(std.testing.allocator, haystack);
    defer {
        for (rt_ms) |*m| @constCast(m).deinit(std.testing.allocator);
        std.testing.allocator.free(rt_ms);
    }
    try std.testing.expectEqual(rt_ms.len, ms.len);
    for (ms, rt_ms) |m, rt| {
        try std.testing.expectEqual(rt.span.start, m.span.start);
        try std.testing.expectEqual(rt.span.end, m.span.end);
    }
}

test "comptime: pure-literal search first match" {
    const cx = comptime compileComptime("fox");
    var m = (try cx.search(std.testing.allocator, "the quick brown fox jumps")).?;
    defer m.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 16), m.span.start);
    try std.testing.expectEqual(@as(usize, 19), m.span.end);
}

test "comptime: pure-literal no match returns null" {
    const cx = comptime compileComptime("xyz");
    const result = try cx.search(std.testing.allocator, "hello world");
    try std.testing.expect(result == null);
}

test "comptime: \\d+ class findAll matches runtime path" {
    const cx = comptime compileComptime("\\d+");
    const haystack = "abc 42 def 1234 xyz";
    const ms = try cx.findAll(std.testing.allocator, haystack);
    defer {
        for (ms) |*m| @constCast(m).deinit(std.testing.allocator);
        std.testing.allocator.free(ms);
    }
    var r = try root.Regex.compile(std.testing.allocator, "\\d+");
    defer r.deinit();
    const rt_ms = try r.findAll(std.testing.allocator, haystack);
    defer {
        for (rt_ms) |*m| @constCast(m).deinit(std.testing.allocator);
        std.testing.allocator.free(rt_ms);
    }
    try std.testing.expectEqual(rt_ms.len, ms.len);
    for (ms, rt_ms) |m, rt| {
        try std.testing.expectEqual(rt.span.start, m.span.start);
        try std.testing.expectEqual(rt.span.end, m.span.end);
    }
}

test "comptime: [a-z]+ class findAll matches runtime path" {
    const cx = comptime compileComptime("[a-z]+");
    const haystack = "Hello World foo BAR baz";
    const ms = try cx.findAll(std.testing.allocator, haystack);
    defer {
        for (ms) |*m| @constCast(m).deinit(std.testing.allocator);
        std.testing.allocator.free(ms);
    }
    var r = try root.Regex.compile(std.testing.allocator, "[a-z]+");
    defer r.deinit();
    const rt_ms = try r.findAll(std.testing.allocator, haystack);
    defer {
        for (rt_ms) |*m| @constCast(m).deinit(std.testing.allocator);
        std.testing.allocator.free(rt_ms);
    }
    try std.testing.expectEqual(rt_ms.len, ms.len);
    for (ms, rt_ms) |m, rt| {
        try std.testing.expectEqual(rt.span.start, m.span.start);
        try std.testing.expectEqual(rt.span.end, m.span.end);
    }
}

test "comptime: [A-Z]+ class (uppercase only)" {
    const cx = comptime compileComptime("[A-Z]+");
    const haystack = "Hello WORLD foo BAR";
    const ms = try cx.findAll(std.testing.allocator, haystack);
    defer {
        for (ms) |*m| @constCast(m).deinit(std.testing.allocator);
        std.testing.allocator.free(ms);
    }
    try std.testing.expectEqual(@as(usize, 3), ms.len);
    try std.testing.expectEqualStrings("H", haystack[ms[0].span.start..ms[0].span.end]);
    try std.testing.expectEqualStrings("WORLD", haystack[ms[1].span.start..ms[1].span.end]);
    try std.testing.expectEqualStrings("BAR", haystack[ms[2].span.start..ms[2].span.end]);
}

test "comptime: \\w+ word class" {
    const cx = comptime compileComptime("\\w+");
    const haystack = "foo bar_baz 123";
    const ms = try cx.findAll(std.testing.allocator, haystack);
    defer {
        for (ms) |*m| @constCast(m).deinit(std.testing.allocator);
        std.testing.allocator.free(ms);
    }
    try std.testing.expectEqual(@as(usize, 3), ms.len);
}

test "comptime: runtime fallback compiles and runs" {
    // `(abc)+` is a compound pattern — falls back to runtime.
    const cx = comptime compileComptime("(abc)+");
    const ms = try cx.findAll(std.testing.allocator, "abcabc def abc");
    defer {
        for (ms) |*m| @constCast(m).deinit(std.testing.allocator);
        std.testing.allocator.free(ms);
    }
    // Should find matches regardless of code path.
    try std.testing.expect(ms.len >= 1);
}

test "comptime: classify pure_literal" {
    try std.testing.expectEqual(.pure_literal, comptime classify("hello"));
    try std.testing.expectEqual(.pure_literal, comptime classify("compileAllocFlags"));
    try std.testing.expectEqual(.pure_literal, comptime classify(""));
}

test "comptime: classify single_class_plus" {
    try std.testing.expectEqual(.single_class_plus, comptime classify("\\d+"));
    try std.testing.expectEqual(.single_class_plus, comptime classify("[a-z]+"));
    try std.testing.expectEqual(.single_class_plus, comptime classify("\\w+"));
    try std.testing.expectEqual(.single_class_plus, comptime classify("\\s+"));
    try std.testing.expectEqual(.single_class_plus, comptime classify("[0-9]{3,}"));
    try std.testing.expectEqual(.single_class_plus, comptime classify("(?:\\d+)"));
}

test "comptime: classify runtime_fallback" {
    try std.testing.expectEqual(.runtime_fallback, comptime classify("(abc)+"));
    try std.testing.expectEqual(.runtime_fallback, comptime classify("a.b"));
    try std.testing.expectEqual(.runtime_fallback, comptime classify("foo|bar"));
    try std.testing.expectEqual(.runtime_fallback, comptime classify("\\d*")); // min=0 skipped
}
