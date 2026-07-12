//! Thompson NFA construction.
//!
//! Each AST node compiles to a Frag: a single entry state plus a list of
//! "dangling" out-edges that the parent patches when concatenating. The
//! final NFA has one start state and one accept state, both well-defined
//! indices into `states`. The graph is arena-allocated alongside the AST.
//!
//! Greedy vs lazy quantifiers differ only in the *order* of out-edges on
//! the fork state — out1 is preferred by the matcher, so greedy puts the
//! sub-fragment on out1 (consume more) and lazy puts the continuation on
//! out1 (consume less). The matcher honours the ordering during simulation.
//!
//! Counted quantifiers `{m,n}` are unfolded inline — m mandatory copies
//! followed by (n-m) optional copies, capped at 1024 unfolds to keep
//! compile time bounded.

const std = @import("std");
const ast = @import("ast.zig");

pub const StateId = u32;

pub const Consume = union(enum) {
    /// No input consumed; no observation. Used at forks and merges.
    epsilon,
    /// Consume one byte; succeeds iff `byte == value`.
    byte: u8,
    /// Consume one byte; succeeds iff byte matches dot. The matcher consults
    /// its `dot_all` flag to decide whether `\n` is included.
    any,
    /// Consume one byte; succeeds iff `byte ∈ class.bitmap`.
    class: *const ast.Class,
    /// Zero-width anchor — succeeds iff the current position satisfies it.
    anchor: ast.Anchor,
    /// No input consumed. Side effect: mark capture group N start at the
    /// current position. The matcher updates its capture array.
    group_start: u32,
    /// No input consumed. Side effect: mark capture group N end.
    group_end: u32,
};

pub const State = struct {
    consume: Consume,
    /// Primary out edge. For consuming states (byte/any/class), out1 is
    /// followed only when the byte matches. For zero-width states
    /// (epsilon/anchor/group_*), out1 is followed unconditionally.
    out1: ?StateId,
    /// Secondary out — populated only when this is an alt or repeat fork.
    /// Both out edges are then epsilon-like.
    out2: ?StateId,
};

pub const Nfa = struct {
    states: []State,
    start: StateId,
    /// The accept state is an epsilon state with no out edges. Matcher
    /// detects acceptance by id, not by Consume tag.
    accept: StateId,
    n_groups: u32,
};

pub const BuildError = error{ OutOfMemory, QuantifierTooLarge };

/// Compile an AST into an NFA. Allocates state buffer + dangling-edge
/// scratch from `arena`. The returned slice is also arena-owned.
pub fn build(arena: std.mem.Allocator, root: *const ast.Node, n_groups: u32) BuildError!Nfa {
    var b: Builder = .{ .arena = arena, .states = .empty };
    var frag = try b.compile(root);
    defer frag.dangles.deinit(arena);

    // All dangling out-edges become inputs to a single accept state.
    const accept = try b.newState(.epsilon, null, null);
    for (frag.dangles.items) |p| b.patch(p, accept);

    return .{
        .states = try arena.dupe(State, b.states.items),
        .start = frag.start,
        .accept = accept,
        .n_groups = n_groups,
    };
}

// ── Internal construction state ──

const PatchSlot = enum { out1, out2 };

const PatchPoint = struct {
    state: StateId,
    slot: PatchSlot,
};

const Frag = struct {
    start: StateId,
    /// Out-edges that haven't been wired to anything yet. The parent
    /// node patches them when concatenating with the next fragment.
    dangles: std.ArrayList(PatchPoint),
};

const Builder = struct {
    arena: std.mem.Allocator,
    states: std.ArrayList(State),

    fn newState(self: *Builder, consume: Consume, out1: ?StateId, out2: ?StateId) BuildError!StateId {
        const id: StateId = @intCast(self.states.items.len);
        try self.states.append(self.arena, .{ .consume = consume, .out1 = out1, .out2 = out2 });
        return id;
    }

    fn patch(self: *Builder, point: PatchPoint, target: StateId) void {
        switch (point.slot) {
            .out1 => self.states.items[point.state].out1 = target,
            .out2 => self.states.items[point.state].out2 = target,
        }
    }

    fn singleton(self: *Builder, consume: Consume) BuildError!Frag {
        const s = try self.newState(consume, null, null);
        var dangles: std.ArrayList(PatchPoint) = .empty;
        try dangles.append(self.arena, .{ .state = s, .slot = .out1 });
        return .{ .start = s, .dangles = dangles };
    }

    fn epsilonFrag(self: *Builder) BuildError!Frag {
        return self.singleton(.epsilon);
    }

    fn compile(self: *Builder, node: *const ast.Node) BuildError!Frag {
        return switch (node.*) {
            .literal => |c| try self.singleton(.{ .byte = c }),
            .dot => try self.singleton(.any),
            .class => |cls| try self.singleton(.{ .class = cls }),
            .anchor => |a| try self.singleton(.{ .anchor = a }),
            .concat => |children| try self.compileConcat(children),
            .alt => |children| try self.compileAlt(children),
            .repeat => |r| try self.compileRepeat(r),
            .group => |g| try self.compileGroup(g),
        };
    }

    fn compileConcat(self: *Builder, children: []const *const ast.Node) BuildError!Frag {
        if (children.len == 0) return try self.epsilonFrag();
        var acc = try self.compile(children[0]);
        var i: usize = 1;
        while (i < children.len) : (i += 1) {
            const next = try self.compile(children[i]);
            for (acc.dangles.items) |p| self.patch(p, next.start);
            acc.dangles.deinit(self.arena);
            acc.dangles = next.dangles;
        }
        return acc;
    }

    fn compileAlt(self: *Builder, children: []const *const ast.Node) BuildError!Frag {
        if (children.len == 1) return self.compile(children[0]);

        // Build right-to-left so the leftmost branch is preferred at the
        // top-level fork (matches Python re's leftmost-first semantics).
        var i: usize = children.len;
        i -= 1;
        var rest = try self.compile(children[i]);
        while (i > 0) {
            i -= 1;
            var branch = try self.compile(children[i]);
            const fork = try self.newState(.epsilon, branch.start, rest.start);
            // Merge danglers from both sides.
            for (rest.dangles.items) |p| try branch.dangles.append(self.arena, p);
            rest.dangles.deinit(self.arena);
            rest = .{ .start = fork, .dangles = branch.dangles };
        }
        return rest;
    }

    fn compileRepeat(self: *Builder, r: *const ast.Repeat) BuildError!Frag {
        // Fast paths for the common shapes — *, +, ?.
        if (r.min == 0 and r.max == std.math.maxInt(u32)) return try self.compileStar(r.sub, r.greedy);
        if (r.min == 1 and r.max == std.math.maxInt(u32)) return try self.compilePlus(r.sub, r.greedy);
        if (r.min == 0 and r.max == 1) return try self.compileQuestion(r.sub, r.greedy);
        return try self.compileCounted(r);
    }

    fn compileStar(self: *Builder, sub_node: *const ast.Node, greedy: bool) BuildError!Frag {
        var sub = try self.compile(sub_node);
        const fork = if (greedy)
            try self.newState(.epsilon, sub.start, null)
        else
            try self.newState(.epsilon, null, sub.start);
        for (sub.dangles.items) |p| self.patch(p, fork);
        sub.dangles.deinit(self.arena);
        var dangles: std.ArrayList(PatchPoint) = .empty;
        try dangles.append(self.arena, .{
            .state = fork,
            .slot = if (greedy) .out2 else .out1,
        });
        return .{ .start = fork, .dangles = dangles };
    }

    fn compilePlus(self: *Builder, sub_node: *const ast.Node, greedy: bool) BuildError!Frag {
        var sub = try self.compile(sub_node);
        const fork = if (greedy)
            try self.newState(.epsilon, sub.start, null)
        else
            try self.newState(.epsilon, null, sub.start);
        for (sub.dangles.items) |p| self.patch(p, fork);
        sub.dangles.deinit(self.arena);
        var dangles: std.ArrayList(PatchPoint) = .empty;
        try dangles.append(self.arena, .{
            .state = fork,
            .slot = if (greedy) .out2 else .out1,
        });
        return .{ .start = sub.start, .dangles = dangles };
    }

    fn compileQuestion(self: *Builder, sub_node: *const ast.Node, greedy: bool) BuildError!Frag {
        var sub = try self.compile(sub_node);
        const fork = if (greedy)
            try self.newState(.epsilon, sub.start, null)
        else
            try self.newState(.epsilon, null, sub.start);
        try sub.dangles.append(self.arena, .{
            .state = fork,
            .slot = if (greedy) .out2 else .out1,
        });
        return .{ .start = fork, .dangles = sub.dangles };
    }

    fn compileCounted(self: *Builder, r: *const ast.Repeat) BuildError!Frag {
        // Bound unfold size — a pattern like `a{100000}` is almost certainly
        // pathological; refuse so compile-time stays sane.
        const max_unfold: u32 = 1024;
        if (r.min > max_unfold) return BuildError.QuantifierTooLarge;
        if (r.max != std.math.maxInt(u32) and r.max > max_unfold) return BuildError.QuantifierTooLarge;

        var head: ?Frag = null;
        var idx: u32 = 0;
        while (idx < r.min) : (idx += 1) {
            const next = try self.compile(r.sub);
            if (head) |*h| {
                for (h.dangles.items) |p| self.patch(p, next.start);
                h.dangles.deinit(self.arena);
                h.dangles = next.dangles;
            } else {
                head = next;
            }
        }

        if (r.max == std.math.maxInt(u32)) {
            // {m,∞} → m mandatory copies followed by a star tail.
            const tail = try self.compileStar(r.sub, r.greedy);
            if (head) |*h| {
                for (h.dangles.items) |p| self.patch(p, tail.start);
                h.dangles.deinit(self.arena);
                h.dangles = tail.dangles;
                return h.*;
            }
            return tail;
        }

        // {m,n} → m mandatory + (n-m) optional copies.
        const optionals = r.max - r.min;
        var i: u32 = 0;
        while (i < optionals) : (i += 1) {
            const opt = try self.compileQuestion(r.sub, r.greedy);
            if (head) |*h| {
                for (h.dangles.items) |p| self.patch(p, opt.start);
                h.dangles.deinit(self.arena);
                h.dangles = opt.dangles;
            } else {
                head = opt;
            }
        }

        if (head) |h| return h;
        // Pure {0,0} — match the empty string.
        return try self.epsilonFrag();
    }

    fn compileGroup(self: *Builder, g: *const ast.Group) BuildError!Frag {
        var sub = try self.compile(g.sub);
        if (!g.capturing) return sub;

        // Wrap sub with group_start ... sub ... group_end.
        const start = try self.newState(.{ .group_start = g.index }, sub.start, null);
        const end = try self.newState(.{ .group_end = g.index }, null, null);
        for (sub.dangles.items) |p| self.patch(p, end);
        sub.dangles.deinit(self.arena);

        var dangles: std.ArrayList(PatchPoint) = .empty;
        try dangles.append(self.arena, .{ .state = end, .slot = .out1 });
        return .{ .start = start, .dangles = dangles };
    }
};

// ── Validation helpers (also used by tests) ──

/// Walk every state and assert that out-edge ids point at real states.
/// Catches construction bugs that would otherwise show up as wrong matches.
pub fn validate(nfa: Nfa) !void {
    if (nfa.start >= nfa.states.len) return error.InvalidStartState;
    if (nfa.accept >= nfa.states.len) return error.InvalidAcceptState;
    for (nfa.states, 0..) |s, i| {
        if (s.out1) |o| if (o >= nfa.states.len) {
            std.debug.print("state {d} out1={d} out-of-bounds\n", .{ i, o });
            return error.InvalidOutEdge;
        };
        if (s.out2) |o| if (o >= nfa.states.len) {
            std.debug.print("state {d} out2={d} out-of-bounds\n", .{ i, o });
            return error.InvalidOutEdge;
        };
    }
}

// ── Tests ──

const parser = @import("parser.zig");

fn buildFrom(arena: *std.heap.ArenaAllocator, pattern: []const u8) !Nfa {
    var p = parser.Parser.init(arena.allocator(), pattern);
    const root = try p.parseRoot();
    return try build(arena.allocator(), root, p.n_groups);
}

test "nfa: literal compiles to one byte state + accept" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nfa = try buildFrom(&arena, "a");
    try validate(nfa);
    try std.testing.expectEqual(@as(usize, 2), nfa.states.len);
    try std.testing.expectEqual(Consume{ .byte = 'a' }, nfa.states[nfa.start].consume);
}

test "nfa: concat 'ab' chains two byte states" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nfa = try buildFrom(&arena, "ab");
    try validate(nfa);
    try std.testing.expectEqual(@as(usize, 3), nfa.states.len);
    try std.testing.expectEqual(Consume{ .byte = 'a' }, nfa.states[nfa.start].consume);
    const second = nfa.states[nfa.start].out1.?;
    try std.testing.expectEqual(Consume{ .byte = 'b' }, nfa.states[second].consume);
}

test "nfa: alt 'a|b' builds a fork" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nfa = try buildFrom(&arena, "a|b");
    try validate(nfa);
    // Fork (epsilon) + a + b + accept = 4.
    try std.testing.expectEqual(@as(usize, 4), nfa.states.len);
    try std.testing.expectEqual(Consume.epsilon, nfa.states[nfa.start].consume);
    try std.testing.expect(nfa.states[nfa.start].out1 != null);
    try std.testing.expect(nfa.states[nfa.start].out2 != null);
}

test "nfa: star 'a*' builds fork pointing at sub + continuation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nfa = try buildFrom(&arena, "a*");
    try validate(nfa);
    // a + fork + accept = 3.
    try std.testing.expectEqual(@as(usize, 3), nfa.states.len);
    try std.testing.expectEqual(Consume.epsilon, nfa.states[nfa.start].consume);
    // Greedy: out1 should be the sub.
    const sub_id = nfa.states[nfa.start].out1.?;
    try std.testing.expectEqual(Consume{ .byte = 'a' }, nfa.states[sub_id].consume);
}

test "nfa: lazy star 'a*?' reverses fork ordering" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nfa = try buildFrom(&arena, "a*?");
    try validate(nfa);
    // Lazy: out1 is the continuation, out2 is the sub.
    try std.testing.expectEqual(Consume.epsilon, nfa.states[nfa.start].consume);
    const sub_id = nfa.states[nfa.start].out2.?;
    try std.testing.expectEqual(Consume{ .byte = 'a' }, nfa.states[sub_id].consume);
}

test "nfa: plus 'a+' starts at sub, not fork" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nfa = try buildFrom(&arena, "a+");
    try validate(nfa);
    // 'a' must be matched at least once — start is the byte state.
    try std.testing.expectEqual(Consume{ .byte = 'a' }, nfa.states[nfa.start].consume);
}

test "nfa: question 'a?' makes sub optional" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nfa = try buildFrom(&arena, "a?");
    try validate(nfa);
    try std.testing.expectEqual(Consume.epsilon, nfa.states[nfa.start].consume);
}

test "nfa: capturing group wraps sub with group_start / group_end" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nfa = try buildFrom(&arena, "(ab)");
    try validate(nfa);
    try std.testing.expectEqual(@as(u32, 1), nfa.n_groups);
    switch (nfa.states[nfa.start].consume) {
        .group_start => |idx| try std.testing.expectEqual(@as(u32, 1), idx),
        else => return error.ExpectedGroupStart,
    }
}

test "nfa: non-capturing group has no group_start/end" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nfa = try buildFrom(&arena, "(?:ab)");
    try validate(nfa);
    try std.testing.expectEqual(@as(u32, 0), nfa.n_groups);
    try std.testing.expectEqual(Consume{ .byte = 'a' }, nfa.states[nfa.start].consume);
}

test "nfa: counted {2,3}" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nfa = try buildFrom(&arena, "a{2,3}");
    try validate(nfa);
    // 2 mandatory + 1 optional + accept = at least 4 states.
    try std.testing.expect(nfa.states.len >= 4);
    try std.testing.expectEqual(Consume{ .byte = 'a' }, nfa.states[nfa.start].consume);
}

test "nfa: oversized quantifier errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(arena.allocator(), "a{2000}");
    const root = try p.parseRoot();
    try std.testing.expectError(BuildError.QuantifierTooLarge, build(arena.allocator(), root, p.n_groups));
}

test "nfa: anchor compiles to anchor state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nfa = try buildFrom(&arena, "^abc");
    try validate(nfa);
    switch (nfa.states[nfa.start].consume) {
        .anchor => |a| try std.testing.expectEqual(ast.Anchor.line_start, a),
        else => return error.ExpectedAnchor,
    }
}

test "nfa: validate catches no-bug case" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nfa = try buildFrom(&arena, "a(b|c)*d");
    try validate(nfa);
}
