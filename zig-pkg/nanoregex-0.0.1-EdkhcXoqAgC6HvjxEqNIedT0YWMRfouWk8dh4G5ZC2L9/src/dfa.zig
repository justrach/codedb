//! Lazy DFA built by subset construction over the Thompson NFA.
//!
//! Each DFA state is a sorted set of NFA state IDs. Transitions are computed
//! on demand: when (state, byte) is first encountered we run `step`, hash
//! the resulting NFA-state set, look it up (or create a new DFA state for
//! it), and cache the edge. Subsequent bytes through the same transition
//! are a single indexed lookup.
//!
//! Scope for v1:
//!   - No capture-group tracking (caller must check `nfa.n_groups == 0`).
//!   - No anchors (caller must check the AST for `Anchor` nodes; if present,
//!     fall back to the Pike VM).
//!   - Bounded state count (MAX_STATES). On overflow we surface an error
//!     and the caller falls back to the Pike VM.
//!
//! The forward-only driver below handles unanchored search by trying each
//! starting position. Per-character cost is one table lookup, so this is
//! O(n) for cases where matches don't overlap heavily.

const std = @import("std");
const ast = @import("ast.zig");
const nfa = @import("nfa.zig");
const minterm = @import("minterm.zig");

pub const DfaStateId = u32;
pub const DEAD: DfaStateId = std.math.maxInt(DfaStateId);
const UNCOMPUTED: DfaStateId = std.math.maxInt(DfaStateId) - 1;

const MAX_STATES: u32 = 4096;

pub const Error = error{ OutOfMemory, TooManyStates, HasCaptures, HasAnchors, HasLazyQuantifier };

/// Knobs the runtime needs the DFA to bake in at construction time —
/// flags whose meaning isn't visible from the NFA alone. (case_insensitive
/// is intentionally absent: v1 falls back to the Pike VM when CI is set.)
pub const BuildOptions = struct {
    /// Forwarded from the public Flags.dot_all. When true, `.` matches `\n`.
    dot_all: bool = false,
};

/// Set of NFA states reached after a particular byte sequence. Sorted,
/// deduplicated; the byte representation is the hash-map key.
const NfaSet = struct {
    ids: []const nfa.StateId,
    accepts: bool,
};

/// Hash-map context that compares NfaSet identity by content of `ids`.
/// We key on the raw byte slice of the sorted ids — same length, same
/// bytes, same set.
const SetMapCtx = struct {
    pub fn hash(_: SetMapCtx, key: []const u8) u64 {
        return std.hash.Wyhash.hash(0, key);
    }
    pub fn eql(_: SetMapCtx, a: []const u8, b: []const u8) bool {
        if (a.len != b.len) return false;
        return std.mem.eql(u8, a, b);
    }
};

const SetMap = std.HashMap([]const u8, DfaStateId, SetMapCtx, std.hash_map.default_max_load_percentage);

pub const Dfa = struct {
    /// Arena for state sets and transition rows. Lives until deinit.
    arena: *std.heap.ArenaAllocator,
    parent_alloc: std.mem.Allocator,
    nfa_ref: *const nfa.Nfa,

    states: std.ArrayList(NfaSet),
    /// Flat 2-D transition table indexed by `state * minterm.n_classes + class_id`.
    /// Far smaller than 256-per-row when the pattern's atomic predicates
    /// partition the alphabet into a handful of equivalence classes —
    /// `[a-z]+` ends up with 2 classes, a 128× shrink.
    transitions: []DfaStateId,
    /// Resolves byte → class id. Built once from the AST at compile time.
    minterm: minterm.Table,
    set_to_id: SetMap,

    start: DfaStateId,
    /// Whether `.` should match `\n`. Threaded in from the public Flags
    /// at compile time so the inner-loop test stays branch-cheap.
    dot_all: bool,

    pub fn fromNfa(alloc: std.mem.Allocator, n: *const nfa.Nfa, root: *const ast.Node, opts: BuildOptions) Error!Dfa {
        if (n.n_groups != 0) return Error.HasCaptures;
        if (containsAnchor(root)) return Error.HasAnchors;
        // Lazy quantifiers need leftmost-shortest semantics, which a
        // plain subset-construction DFA cannot express — it always picks
        // leftmost-longest. Bail and let the Pike VM handle the pattern.
        if (containsLazy(root)) return Error.HasLazyQuantifier;

        const arena = try alloc.create(std.heap.ArenaAllocator);
        errdefer alloc.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(alloc);
        errdefer arena.deinit();
        const aa = arena.allocator();

        // Compute byte equivalence classes from the pattern so the
        // transition table can be indexed by class instead of raw byte.
        // Typical pattern → 4-20 classes, so the row shrinks 12-64× and
        // fits in L1 instead of L2.
        const mt = try minterm.build(aa, root, opts.dot_all);

        const transitions = try aa.alloc(DfaStateId, @as(usize, MAX_STATES) * mt.n_classes);
        @memset(transitions, UNCOMPUTED);

        var dfa: Dfa = .{
            .arena = arena,
            .parent_alloc = alloc,
            .nfa_ref = n,
            .states = .empty,
            .transitions = transitions,
            .minterm = mt,
            .set_to_id = SetMap.init(aa),
            .start = 0,
            .dot_all = opts.dot_all,
        };

        // Seed: the start DFA state is the epsilon-closure of {nfa.start}.
        const seed = try epsilonClosure(aa, n, &.{n.start});
        dfa.start = try dfa.internState(seed);

        return dfa;
    }

    pub fn deinit(self: *Dfa) void {
        self.arena.deinit();
        self.parent_alloc.destroy(self.arena);
        self.* = undefined;
    }

    /// Insert a state set into the DFA, returning either a fresh id or the
    /// existing one. Sorts the input slice in place before hashing.
    fn internState(self: *Dfa, ids: []const nfa.StateId) Error!DfaStateId {
        // Sort + dedupe — caller is allowed to pass an unsorted set.
        const dup = try self.arena.allocator().dupe(nfa.StateId, ids);
        std.mem.sort(nfa.StateId, dup, {}, comptime std.sort.asc(nfa.StateId));
        const deduped = uniqueSorted(dup);

        const key_bytes = std.mem.sliceAsBytes(deduped);
        if (self.set_to_id.get(key_bytes)) |existing| return existing;

        if (self.states.items.len >= MAX_STATES) return Error.TooManyStates;

        var accepts = false;
        for (deduped) |id| if (id == self.nfa_ref.accept) {
            accepts = true;
            break;
        };

        const id: DfaStateId = @intCast(self.states.items.len);
        try self.states.append(self.arena.allocator(), .{ .ids = deduped, .accepts = accepts });
        try self.set_to_id.put(key_bytes, id);
        return id;
    }

    /// Public wrapper around the inlined hot-path transition. Mostly used
    /// by tests; the matching loop in `matchAt` reads `transitions` and
    /// `byte_to_class` directly to skip the function-call overhead.
    pub fn transition(self: *Dfa, state: DfaStateId, byte: u8) Error!DfaStateId {
        const class_id: usize = self.minterm.byte_to_class[byte];
        const idx = @as(usize, state) * self.minterm.n_classes + class_id;
        const cached = self.transitions[idx];
        if (cached != UNCOMPUTED) return cached;
        return try self.computeAndCacheTransition(state, class_id);
    }

    /// Slow path: compute the successor set for `(state, class_id)`, intern
    /// it as a new DFA state if needed, and cache the edge. Called from the
    /// hot loops only when the transition is missing.
    fn computeAndCacheTransition(self: *Dfa, state: DfaStateId, class_id: usize) Error!DfaStateId {
        const idx = @as(usize, state) * self.minterm.n_classes + class_id;
        const rep_byte = self.minterm.representatives[class_id];

        const cur = self.states.items[state];
        var next_ids: std.ArrayList(nfa.StateId) = .empty;
        defer next_ids.deinit(self.arena.allocator());

        for (cur.ids) |sid| {
            const ns = self.nfa_ref.states[sid];
            const matched = switch (ns.consume) {
                .byte => |b| b == rep_byte,
                .any => self.dot_all or rep_byte != '\n',
                .class => |cls| cls.contains(rep_byte),
                .epsilon, .anchor, .group_start, .group_end => false,
            };
            if (matched) {
                if (ns.out1) |o| try next_ids.append(self.arena.allocator(), o);
            }
        }

        if (next_ids.items.len == 0) {
            self.transitions[idx] = DEAD;
            return DEAD;
        }

        const closure = try epsilonClosure(self.arena.allocator(), self.nfa_ref, next_ids.items);
        const next_id = try self.internState(closure);
        self.transitions[idx] = next_id;
        return next_id;
    }

    /// Anchored match starting at `start` in `input`. Returns the end index
    /// of the longest accepted run, or null if no match.
    ///
    /// The hot loop reads the byte → class table and the transition table
    /// directly. The slow-path branch (`UNCOMPUTED`) is hoisted out so the
    /// fast path is a tight series of array reads + one compare. After
    /// warmup the slow path is essentially never taken, so this trades
    /// one predicted-not-taken branch for skipping a function frame and
    /// the redundant idx recomputation that the older `transition` call
    /// did inside the loop.
    pub fn matchAt(self: *Dfa, input: []const u8, start: usize) Error!?usize {
        var cur: DfaStateId = self.start;
        var longest: ?usize = if (self.states.items[cur].accepts) start else null;
        const byte_to_class = &self.minterm.byte_to_class;
        const n_classes: usize = self.minterm.n_classes;
        // `transitions` is a fixed-size buffer allocated once in fromNfa
        // — capturing its slice is safe. `states.items`, on the other
        // hand, can be reallocated by computeAndCacheTransition's call
        // to internState, so we re-read it on the read-back path.
        const transitions = self.transitions;

        var i = start;
        while (i < input.len) : (i += 1) {
            const class_id: usize = byte_to_class[input[i]];
            const idx = @as(usize, cur) * n_classes + class_id;
            var next = transitions[idx];
            if (next == UNCOMPUTED) {
                next = try self.computeAndCacheTransition(cur, class_id);
            }
            if (next == DEAD) break;
            cur = next;
            if (self.states.items[cur].accepts) longest = i + 1;
        }
        return longest;
    }

    /// Find every non-overlapping match span in `input`. Tries each
    /// starting position; on a hit, skips past the match end. Zero-width
    /// matches advance one byte so we don't loop.
    pub fn findAll(self: *Dfa, alloc: std.mem.Allocator, input: []const u8) Error![]Span {
        var out: std.ArrayList(Span) = .empty;
        errdefer out.deinit(alloc);

        var p: usize = 0;
        while (p <= input.len) {
            const end_opt = try self.matchAt(input, p);
            if (end_opt) |end| {
                try out.append(alloc, .{ .start = p, .end = end });
                p = if (end > p) end else p + 1;
            } else {
                p += 1;
            }
        }
        return try out.toOwnedSlice(alloc);
    }
};

pub const Span = struct { start: usize, end: usize };

// ── Helpers ──

/// Compute the epsilon-closure of `seeds`: every NFA state reachable from
/// the seeds via zero-width transitions (epsilon, group_start, group_end —
/// not anchor, since we caller-fail when anchors are present).
fn epsilonClosure(alloc: std.mem.Allocator, n: *const nfa.Nfa, seeds: []const nfa.StateId) Error![]nfa.StateId {
    var stack: std.ArrayList(nfa.StateId) = .empty;
    defer stack.deinit(alloc);
    var seen = try alloc.alloc(bool, n.states.len);
    defer alloc.free(seen);
    @memset(seen, false);

    var out: std.ArrayList(nfa.StateId) = .empty;
    errdefer out.deinit(alloc);

    for (seeds) |s| {
        if (!seen[s]) {
            seen[s] = true;
            try stack.append(alloc, s);
        }
    }

    while (stack.pop()) |sid| {
        try out.append(alloc, sid);
        if (sid == n.accept) continue;
        const ns = n.states[sid];
        switch (ns.consume) {
            .epsilon, .group_start, .group_end => {
                if (ns.out1) |o| if (!seen[o]) {
                    seen[o] = true;
                    try stack.append(alloc, o);
                };
                if (ns.out2) |o| if (!seen[o]) {
                    seen[o] = true;
                    try stack.append(alloc, o);
                };
            },
            // Consuming and anchor states don't contribute to the closure —
            // they're already terminal for this iteration.
            else => {},
        }
    }

    return try out.toOwnedSlice(alloc);
}

fn uniqueSorted(sorted: []nfa.StateId) []nfa.StateId {
    if (sorted.len == 0) return sorted;
    var w: usize = 1;
    var i: usize = 1;
    while (i < sorted.len) : (i += 1) {
        if (sorted[i] != sorted[w - 1]) {
            sorted[w] = sorted[i];
            w += 1;
        }
    }
    return sorted[0..w];
}

fn containsAnchor(node: *const ast.Node) bool {
    return switch (node.*) {
        .anchor => true,
        .literal, .dot, .class => false,
        .concat => |children| for (children) |c| {
            if (containsAnchor(c)) break true;
        } else false,
        .alt => |children| for (children) |c| {
            if (containsAnchor(c)) break true;
        } else false,
        .repeat => |r| containsAnchor(r.sub),
        .group => |g| containsAnchor(g.sub),
    };
}

/// True iff any quantifier in the AST is lazy (`*?`/`+?`/`??`/`{n,m}?`).
/// The DFA always yields leftmost-longest matches, which contradicts
/// lazy semantics — we caller-fail so the Pike VM runs instead.
fn containsLazy(node: *const ast.Node) bool {
    return switch (node.*) {
        .literal, .dot, .class, .anchor => false,
        .concat => |children| for (children) |c| {
            if (containsLazy(c)) break true;
        } else false,
        .alt => |children| for (children) |c| {
            if (containsLazy(c)) break true;
        } else false,
        .repeat => |r| !r.greedy or containsLazy(r.sub),
        .group => |g| containsLazy(g.sub),
    };
}

// ── Tests ──

const parser = @import("parser.zig");

fn buildDfa(arena: *std.heap.ArenaAllocator, pattern: []const u8) !Dfa {
    var p = parser.Parser.init(arena.allocator(), pattern);
    const root = try p.parseRoot();
    // Heap-allocate the Nfa on the arena so its address is stable for the
    // returned Dfa's `nfa_ref`. An earlier version did `&local_const`
    // which was a dangling stack pointer the moment buildDfa returned,
    // and every test that actually exercised the DFA either crashed or
    // returned bogus values from torn-over stack memory.
    const automaton_ptr = try arena.allocator().create(nfa.Nfa);
    automaton_ptr.* = try nfa.build(arena.allocator(), root, p.n_groups);
    return try Dfa.fromNfa(std.testing.allocator, automaton_ptr, root, .{});
}

test "dfa: literal pattern matches via findAll" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var dfa = try buildDfa(&arena, "abc");
    defer dfa.deinit();
    const spans = try dfa.findAll(std.testing.allocator, "the abc and abc again");
    defer std.testing.allocator.free(spans);
    try std.testing.expectEqual(@as(usize, 2), spans.len);
    try std.testing.expectEqual(@as(usize, 4), spans[0].start);
    try std.testing.expectEqual(@as(usize, 7), spans[0].end);
}

test "dfa: greedy plus consumes longest run" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var dfa = try buildDfa(&arena, "\\d+");
    defer dfa.deinit();
    const spans = try dfa.findAll(std.testing.allocator, "abc 42 def 1234 xyz");
    defer std.testing.allocator.free(spans);
    try std.testing.expectEqual(@as(usize, 2), spans.len);
    // "42" — two digits.
    try std.testing.expectEqual(@as(usize, 2), spans[0].end - spans[0].start);
    // "1234" — four digits. The earlier expectation of `6` was a typo.
    try std.testing.expectEqual(@as(usize, 4), spans[1].end - spans[1].start);
}

test "dfa: alternation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var dfa = try buildDfa(&arena, "cat|dog|bird");
    defer dfa.deinit();
    const spans = try dfa.findAll(std.testing.allocator, "the cat saw a dog and a bird");
    defer std.testing.allocator.free(spans);
    try std.testing.expectEqual(@as(usize, 3), spans.len);
}

test "dfa: class quantifier" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var dfa = try buildDfa(&arena, "[a-z]+");
    defer dfa.deinit();
    const spans = try dfa.findAll(std.testing.allocator, "Hello World");
    defer std.testing.allocator.free(spans);
    try std.testing.expectEqual(@as(usize, 2), spans.len);
}

test "dfa: rejects capture patterns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(arena.allocator(), "(abc)");
    const root = try p.parseRoot();
    const automaton_ptr = try arena.allocator().create(nfa.Nfa);
    automaton_ptr.* = try nfa.build(arena.allocator(), root, p.n_groups);
    try std.testing.expectError(Error.HasCaptures, Dfa.fromNfa(std.testing.allocator, automaton_ptr, root, .{}));
}

test "dfa: rejects anchor patterns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(arena.allocator(), "^foo");
    const root = try p.parseRoot();
    const automaton_ptr = try arena.allocator().create(nfa.Nfa);
    automaton_ptr.* = try nfa.build(arena.allocator(), root, p.n_groups);
    try std.testing.expectError(Error.HasAnchors, Dfa.fromNfa(std.testing.allocator, automaton_ptr, root, .{}));
}

test "dfa: dot wildcard" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var dfa = try buildDfa(&arena, "a.b");
    defer dfa.deinit();
    const spans = try dfa.findAll(std.testing.allocator, "axb ayb azb");
    defer std.testing.allocator.free(spans);
    try std.testing.expectEqual(@as(usize, 3), spans.len);
}

test "dfa: longest match wins on greedy" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var dfa = try buildDfa(&arena, "a*");
    defer dfa.deinit();
    const spans = try dfa.findAll(std.testing.allocator, "aaa");
    defer std.testing.allocator.free(spans);
    // a* should match "aaa" once at position 0, then zero-width at position 3.
    try std.testing.expect(spans.len >= 1);
    try std.testing.expectEqual(@as(usize, 0), spans[0].start);
    try std.testing.expectEqual(@as(usize, 3), spans[0].end);
}
