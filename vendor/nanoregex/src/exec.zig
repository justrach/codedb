//! Pike-VM NFA simulator.
//!
//! Classic two-list simulation: at each input position we hold a `clist` of
//! threads parked at consuming states, then step them on input[pos] into a
//! `nlist`. Zero-width states (epsilon, anchor, group_*) are walked inside
//! `addThread` so they never appear in the active lists — only consuming
//! states (byte / any / class) and the accept state do.
//!
//! Leftmost-first semantics: threads are added by DFS following out1 before
//! out2, so the priority order matches the AST's left-to-right reading.
//! Inside one input position the first thread to reach `accept` wins; lower-
//! priority threads at the same position are stopped from advancing.
//!
//! Captures are per-thread arrays of `?Span`. When a thread crosses a
//! group_start / group_end state, we dupe the array first so siblings
//! don't see each other's updates. This is the simplest correct shape;
//! a copy-on-write or generation-tagged store is the obvious v2 win.

const std = @import("std");
const ast = @import("ast.zig");
const nfa = @import("nfa.zig");

pub const Flags = struct {
    case_insensitive: bool = false,
    /// `^` / `$` match line boundaries (default). When false they only match
    /// input start / end.
    multiline: bool = true,
    /// `.` matches `\n`. Default false.
    dot_all: bool = false,
};

pub const Span = struct { start: usize, end: usize };

pub const MatchResult = struct {
    span: Span,
    /// Slot 0 is the whole match (equal to `span`). Slots 1..n are capture
    /// groups by declaration order. A null entry means the group didn't
    /// participate in the match.
    captures: []const ?Span,

    pub fn deinit(self: *MatchResult, alloc: std.mem.Allocator) void {
        alloc.free(self.captures);
        self.* = undefined;
    }
};

const Thread = struct {
    pc: nfa.StateId,
    captures: []?Span,
};

/// Sparse-set thread list. Generation counter avoids per-step clears.
const ThreadList = struct {
    threads: std.ArrayList(Thread),
    seen_gen: []u32,
    cur_gen: u32,

    fn init(alloc: std.mem.Allocator, n_states: usize) !ThreadList {
        const seen = try alloc.alloc(u32, n_states);
        @memset(seen, 0);
        return .{
            .threads = .empty,
            .seen_gen = seen,
            .cur_gen = 1,
        };
    }

    fn deinit(self: *ThreadList, alloc: std.mem.Allocator) void {
        self.threads.deinit(alloc);
        alloc.free(self.seen_gen);
    }

    /// True iff the state was not yet in this generation. Marks it seen.
    fn markIfNew(self: *ThreadList, pc: nfa.StateId) bool {
        if (self.seen_gen[pc] == self.cur_gen) return false;
        self.seen_gen[pc] = self.cur_gen;
        return true;
    }

    fn clear(self: *ThreadList, alloc: std.mem.Allocator) void {
        self.cur_gen += 1;
        self.threads.clearRetainingCapacity();
        _ = alloc;
    }
};

pub const ExecError = error{OutOfMemory};

pub const Vm = struct {
    alloc: std.mem.Allocator,
    automaton: *const nfa.Nfa,
    flags: Flags,
    /// Total capture-array length: index 0 = whole match, 1..n_groups = explicit.
    cap_len: usize,

    pub fn init(alloc: std.mem.Allocator, automaton: *const nfa.Nfa, flags: Flags) Vm {
        return .{
            .alloc = alloc,
            .automaton = automaton,
            .flags = flags,
            .cap_len = @as(usize, automaton.n_groups) + 1,
        };
    }

    /// Find a single match starting at or after position 0 (whichever
    /// position succeeds first, leftmost-first within that). Returns null
    /// when nothing in the input matches.
    pub fn search(self: *Vm, input: []const u8) ExecError!?MatchResult {
        var start: usize = 0;
        while (start <= input.len) : (start += 1) {
            if (try self.matchAt(input, start)) |m| return m;
        }
        return null;
    }

    /// Find all non-overlapping matches, leftmost-first. Caller owns the
    /// returned slice and each MatchResult's captures.
    pub fn findAll(self: *Vm, input: []const u8) ExecError![]MatchResult {
        var results: std.ArrayList(MatchResult) = .empty;
        errdefer {
            for (results.items) |*m| m.deinit(self.alloc);
            results.deinit(self.alloc);
        }

        var pos: usize = 0;
        while (pos <= input.len) {
            const m_opt = try self.matchAt(input, pos);
            if (m_opt) |m| {
                try results.append(self.alloc, m);
                // Advance past the match. Zero-width match (start == end)
                // must still advance one byte or we'd loop forever.
                pos = if (m.span.end > pos) m.span.end else pos + 1;
            } else {
                pos += 1;
            }
        }
        return results.toOwnedSlice(self.alloc);
    }

    /// Try to match the pattern against `input` starting exactly at `start`.
    /// Returns the longest match the engine finds via leftmost-first
    /// exploration, or null. Threads / captures are allocated from
    /// `self.alloc` and the returned MatchResult owns its capture slice.
    /// Try to match the pattern against `input` starting exactly at `start`.
    /// Returns the longest leftmost-first match the engine finds, or null.
    /// Captures in the returned MatchResult are owned by `self.alloc`; the
    /// per-attempt scratch arena dies at end-of-scope.
    fn matchAt(self: *Vm, input: []const u8, start: usize) ExecError!?MatchResult {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const aa = arena.allocator();

        var clist = try ThreadList.init(aa, self.automaton.states.len);
        var nlist = try ThreadList.init(aa, self.automaton.states.len);

        const initial_caps = try aa.alloc(?Span, self.cap_len);
        @memset(initial_caps, null);
        initial_caps[0] = .{ .start = start, .end = start };

        try self.addThread(&clist, self.automaton.start, start, initial_caps, input, aa);

        var best: ?MatchResult = null;
        var pos = start;
        while (true) : (pos += 1) {
            // Scan clist for accept in priority order. Lower-priority
            // threads (after the first accept) are killed for this step;
            // higher-priority threads (before it) keep stepping — they
            // can still yield a longer leftmost-first match at a later
            // position, which beats the recorded one.
            var accept_idx: ?usize = null;
            for (clist.threads.items, 0..) |t, idx| {
                if (t.pc == self.automaton.accept) {
                    var captures = try self.alloc.alloc(?Span, self.cap_len);
                    for (t.captures, 0..) |c, i| captures[i] = c;
                    if (captures[0]) |*c0| c0.end = pos;
                    // Free the previous best (an older, shorter or
                    // lower-priority accept) before replacing.
                    if (best) |*old| old.deinit(self.alloc);
                    best = .{
                        .span = .{ .start = start, .end = pos },
                        .captures = captures,
                    };
                    accept_idx = idx;
                    break;
                }
            }

            if (pos == input.len) break;
            if (clist.threads.items.len == 0) break;

            // Priority cutoff: only threads with index < accept_idx are
            // allowed to step. When no accept was found this step, all
            // threads step.
            const step_limit = accept_idx orelse clist.threads.items.len;

            for (clist.threads.items[0..step_limit]) |t| {
                if (t.pc == self.automaton.accept) continue;
                const state = self.automaton.states[t.pc];
                switch (state.consume) {
                    .byte => |b| {
                        if (self.byteMatches(b, input[pos])) {
                            if (state.out1) |o| try self.addThread(&nlist, o, pos + 1, t.captures, input, aa);
                        }
                    },
                    .any => {
                        if (self.flags.dot_all or input[pos] != '\n') {
                            if (state.out1) |o| try self.addThread(&nlist, o, pos + 1, t.captures, input, aa);
                        }
                    },
                    .class => |c| {
                        if (self.classMatches(c, input[pos])) {
                            if (state.out1) |o| try self.addThread(&nlist, o, pos + 1, t.captures, input, aa);
                        }
                    },
                    // Zero-width states never reach an active list —
                    // addThread walks past them. Reaching here means an
                    // NFA construction bug.
                    .epsilon, .anchor, .group_start, .group_end => unreachable,
                }
            }

            // Nothing advanced this step. If we've recorded a match, ship it.
            if (nlist.threads.items.len == 0) break;

            clist.clear(aa);
            std.mem.swap(ThreadList, &clist, &nlist);
        }

        return best;
    }

    /// Walk every zero-width state reachable from `pc` and add any consuming
    /// states (or the accept state) into `list`. Captures are duplicated at
    /// every group boundary so sibling threads don't observe each other's
    /// writes.
    fn addThread(
        self: *Vm,
        list: *ThreadList,
        pc: nfa.StateId,
        pos: usize,
        captures: []?Span,
        input: []const u8,
        aa: std.mem.Allocator,
    ) ExecError!void {
        if (!list.markIfNew(pc)) return;

        if (pc == self.automaton.accept) {
            try list.threads.append(aa, .{ .pc = pc, .captures = captures });
            return;
        }

        const state = self.automaton.states[pc];
        switch (state.consume) {
            .epsilon => {
                if (state.out1) |o| try self.addThread(list, o, pos, captures, input, aa);
                if (state.out2) |o| try self.addThread(list, o, pos, captures, input, aa);
            },
            .anchor => |a| {
                if (self.anchorMatches(a, input, pos)) {
                    if (state.out1) |o| try self.addThread(list, o, pos, captures, input, aa);
                }
                // Anchor fail: thread dies here.
            },
            .group_start => |idx| {
                const new_caps = try dupeAndSet(aa, captures, idx, .{ .start = pos, .end = pos });
                if (state.out1) |o| try self.addThread(list, o, pos, new_caps, input, aa);
            },
            .group_end => |idx| {
                const new_caps = try dupeAndSetEnd(aa, captures, idx, pos);
                if (state.out1) |o| try self.addThread(list, o, pos, new_caps, input, aa);
            },
            .byte, .any, .class => {
                try list.threads.append(aa, .{ .pc = pc, .captures = captures });
            },
        }
    }

    // ── Predicates ──

    fn byteMatches(self: *const Vm, expected: u8, actual: u8) bool {
        if (!self.flags.case_insensitive) return expected == actual;
        return toLower(expected) == toLower(actual);
    }

    fn classMatches(self: *const Vm, cls: *const ast.Class, actual: u8) bool {
        if (cls.contains(actual)) return true;
        if (self.flags.case_insensitive) {
            const swapped = if (actual >= 'A' and actual <= 'Z')
                actual + 32
            else if (actual >= 'a' and actual <= 'z')
                actual - 32
            else
                actual;
            if (swapped != actual and cls.contains(swapped)) return true;
        }
        return false;
    }

    fn anchorMatches(self: *const Vm, a: ast.Anchor, input: []const u8, pos: usize) bool {
        return switch (a) {
            .string_start => pos == 0,
            .string_end => pos == input.len,
            .line_start => pos == 0 or (self.flags.multiline and pos > 0 and input[pos - 1] == '\n'),
            .line_end => pos == input.len or (self.flags.multiline and pos < input.len and input[pos] == '\n'),
            .word_boundary => isAtWordBoundary(input, pos),
            .non_word_boundary => !isAtWordBoundary(input, pos),
        };
    }
};

fn dupeAndSet(alloc: std.mem.Allocator, captures: []?Span, idx: u32, value: Span) ![]?Span {
    const out = try alloc.alloc(?Span, captures.len);
    @memcpy(out, captures);
    if (idx < out.len) out[idx] = value;
    return out;
}

fn dupeAndSetEnd(alloc: std.mem.Allocator, captures: []?Span, idx: u32, end: usize) ![]?Span {
    const out = try alloc.alloc(?Span, captures.len);
    @memcpy(out, captures);
    if (idx < out.len) {
        if (out[idx]) |*span| {
            span.end = end;
        } else {
            // group_end without a matching group_start — shouldn't happen
            // with our NFA construction, but treat as zero-width if it does.
            out[idx] = .{ .start = end, .end = end };
        }
    }
    return out;
}

fn toLower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

fn isWordChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '_';
}

fn isAtWordBoundary(input: []const u8, pos: usize) bool {
    const left_is_word = pos > 0 and isWordChar(input[pos - 1]);
    const right_is_word = pos < input.len and isWordChar(input[pos]);
    return left_is_word != right_is_word;
}

// ── Tests ──

const parser = @import("parser.zig");

fn runFindAll(alloc: std.mem.Allocator, pattern: []const u8, input: []const u8) ![]MatchResult {
    return runFindAllFlags(alloc, pattern, input, .{});
}

fn runFindAllFlags(alloc: std.mem.Allocator, pattern: []const u8, input: []const u8, flags: Flags) ![]MatchResult {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var p = parser.Parser.init(arena.allocator(), pattern);
    const root = try p.parseRoot();
    const automaton = try nfa.build(arena.allocator(), root, p.n_groups);
    var vm = Vm.init(alloc, &automaton, flags);
    return try vm.findAll(input);
}

fn freeMatches(alloc: std.mem.Allocator, matches: []MatchResult) void {
    for (matches) |*m| m.deinit(alloc);
    alloc.free(matches);
}

test "exec: literal match" {
    const ms = try runFindAll(std.testing.allocator, "abc", "the abc and abc again");
    defer freeMatches(std.testing.allocator, ms);
    try std.testing.expectEqual(@as(usize, 2), ms.len);
    try std.testing.expectEqual(@as(usize, 4), ms[0].span.start);
    try std.testing.expectEqual(@as(usize, 7), ms[0].span.end);
    try std.testing.expectEqual(@as(usize, 12), ms[1].span.start);
}

test "exec: no match" {
    const ms = try runFindAll(std.testing.allocator, "xyz", "the abc");
    defer freeMatches(std.testing.allocator, ms);
    try std.testing.expectEqual(@as(usize, 0), ms.len);
}

test "exec: dot star greedy" {
    const ms = try runFindAll(std.testing.allocator, "a.*b", "axxxb yyy");
    defer freeMatches(std.testing.allocator, ms);
    try std.testing.expectEqual(@as(usize, 1), ms.len);
    try std.testing.expectEqual(@as(usize, 0), ms[0].span.start);
    try std.testing.expectEqual(@as(usize, 5), ms[0].span.end);
}

test "exec: dot star lazy" {
    const ms = try runFindAll(std.testing.allocator, "a.*?b", "axxxbxxxb");
    defer freeMatches(std.testing.allocator, ms);
    try std.testing.expectEqual(@as(usize, 1), ms.len);
    // Lazy stops at the first 'b'.
    try std.testing.expectEqual(@as(usize, 0), ms[0].span.start);
    try std.testing.expectEqual(@as(usize, 5), ms[0].span.end);
}

test "exec: char class" {
    const ms = try runFindAll(std.testing.allocator, "[a-z]+", "Hello World");
    defer freeMatches(std.testing.allocator, ms);
    try std.testing.expectEqual(@as(usize, 2), ms.len);
    try std.testing.expectEqual(@as(usize, 1), ms[0].span.start);
    try std.testing.expectEqual(@as(usize, 5), ms[0].span.end);
}

test "exec: alternation prefers leftmost" {
    const ms = try runFindAll(std.testing.allocator, "cat|dog|bird", "the dog saw a cat and a bird");
    defer freeMatches(std.testing.allocator, ms);
    try std.testing.expectEqual(@as(usize, 3), ms.len);
}

test "exec: anchors line start" {
    const flags = Flags{ .multiline = true };
    const ms = try runFindAllFlags(std.testing.allocator, "^foo", "foo\nbar foo\nfoo bar", flags);
    defer freeMatches(std.testing.allocator, ms);
    // multiline: ^foo matches at offset 0 and at offset 8 (after \n).
    try std.testing.expectEqual(@as(usize, 2), ms.len);
}

test "exec: counted quantifier" {
    const ms = try runFindAll(std.testing.allocator, "a{2,3}", "a aa aaa aaaa");
    defer freeMatches(std.testing.allocator, ms);
    // Single 'a' doesn't match (need >=2). "aa" matches. "aaa" matches.
    // "aaaa" matches as "aaa" + "a" (the trailing 'a' alone doesn't qualify),
    // so we get exactly: aa, aaa, aaa.
    try std.testing.expectEqual(@as(usize, 3), ms.len);
    try std.testing.expectEqual(@as(usize, 2), ms[0].span.end - ms[0].span.start);
    try std.testing.expectEqual(@as(usize, 3), ms[1].span.end - ms[1].span.start);
    try std.testing.expectEqual(@as(usize, 3), ms[2].span.end - ms[2].span.start);
}

test "exec: capturing group" {
    const ms = try runFindAll(std.testing.allocator, "(\\w+)@(\\w+)", "alice@example bob@host");
    defer freeMatches(std.testing.allocator, ms);
    try std.testing.expectEqual(@as(usize, 2), ms.len);
    // First match: alice@example, groups: alice, example
    try std.testing.expect(ms[0].captures[1] != null);
    try std.testing.expectEqual(@as(usize, 0), ms[0].captures[1].?.start);
    try std.testing.expectEqual(@as(usize, 5), ms[0].captures[1].?.end);
    try std.testing.expectEqual(@as(usize, 6), ms[0].captures[2].?.start);
    try std.testing.expectEqual(@as(usize, 13), ms[0].captures[2].?.end);
}

test "exec: case-insensitive flag" {
    const flags = Flags{ .case_insensitive = true };
    const ms = try runFindAllFlags(std.testing.allocator, "hello", "HELLO Hello hello", flags);
    defer freeMatches(std.testing.allocator, ms);
    try std.testing.expectEqual(@as(usize, 3), ms.len);
}

test "exec: word boundary" {
    const ms = try runFindAll(std.testing.allocator, "\\bcat\\b", "the cat sat on a catnap");
    defer freeMatches(std.testing.allocator, ms);
    // 'cat' alone matches, 'catnap' doesn't (no boundary after 'cat').
    try std.testing.expectEqual(@as(usize, 1), ms.len);
}

test "exec: digit shorthand" {
    const ms = try runFindAll(std.testing.allocator, "\\d+", "abc 42 def 1234 xyz");
    defer freeMatches(std.testing.allocator, ms);
    try std.testing.expectEqual(@as(usize, 2), ms.len);
}
