//! codegraph.zig — deterministic resolved call graph (Phase 1 foundation).
//!
//! codedb already has the two ingredients a precise call graph needs: the parser
//! emits function symbols with line ranges, and `symbol_index` maps a name to its
//! definition sites. What was missing is the middle step — walking call sites and
//! resolving them — which this module provides, deterministically and without an
//! LLM. (Mirrors graphify's `extract.py` walk_calls + symbol-resolution facts, but
//! in codedb's fast/local model.)
//!
//! The graph is the foundation for: centrality-boosted ranking, edge-aware
//! context expansion, and community detection. It is always an ADDITIVE signal —
//! never a filter — so a misresolved edge can never drop a real result.

const std = @import("std");

pub const NodeId = u32;

/// A resolved call edge `from` → `to`. `weight` splits 1.0 across the candidate
/// definitions of an ambiguous callee name (1 candidate → 1.0), so a name that
/// resolves cleanly contributes full weight and an ambiguous one is discounted.
pub const Edge = struct {
    from: NodeId,
    to: NodeId,
    weight: f32,
};

pub const FuncInput = struct {
    id: NodeId,
    /// The function's body text (caller slices it from content via line ranges).
    body: []const u8,
};

/// True for identifiers that precede `(` but are language keywords / control flow,
/// not callees — so `if (`, `for (`, `while (`, `catch (`, `return (` etc. are not
/// counted as calls. Deliberately a cross-language superset (codedb indexes ~40
/// languages); over-filtering a rare real call only loses an additive boost.
fn isCallKeyword(name: []const u8) bool {
    const kws = [_][]const u8{
        "if",     "else",   "for",     "while",  "switch", "return",  "catch",
        "try",    "defer",  "errdefer", "and",   "or",     "orelse",  "sizeof",
        "typeof", "do",     "case",    "when",   "match",  "with",    "in",
        "not",    "is",     "await",   "yield",  "throw",  "new",     "delete",
        "fn",     "func",   "function", "def",   "class",  "struct",  "enum",
        "union",  "const",  "var",     "let",    "static", "assert",  "where",
        "select", "from",   "foreach", "using",  "unless", "until",   "elif",
    };
    for (kws) |kw| if (std.mem.eql(u8, name, kw)) return true;
    return false;
}

inline fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}
inline fn isIdentChar(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9');
}

/// Extract deduped callee identifier names that appear as call sites (`ident(`)
/// in a function body. The identifier immediately preceding an unmatched `(` is
/// the candidate callee (`obj.foo(` yields `foo`; `a[i](` yields nothing). Items
/// are slices into `body`; caller frees the returned array.
pub fn extractCallees(allocator: std.mem.Allocator, body: []const u8) ![][]const u8 {
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        if (body[i] != '(') continue;
        // Skip spaces/tabs between the identifier and the '('.
        var end = i;
        while (end > 0 and (body[end - 1] == ' ' or body[end - 1] == '\t')) end -= 1;
        // Walk back over identifier characters.
        var start = end;
        while (start > 0 and isIdentChar(body[start - 1])) start -= 1;
        if (start == end) continue; // nothing before '(' (e.g. `(expr)`, `)(`)
        const name = body[start..end];
        if (!isIdentStart(name[0])) continue; // started on a digit → not an ident
        if (isCallKeyword(name)) continue;
        const g = try seen.getOrPut(name);
        if (!g.found_existing) try out.append(allocator, name);
    }
    return out.toOwnedSlice(allocator);
}

/// Build resolved call edges for a set of functions. `resolve` maps a callee name
/// to the node ids of its candidate definitions (codedb's `symbol_index`). Edge
/// weight is split across candidates; self-edges are dropped unless `allow_self`.
pub fn buildEdges(
    allocator: std.mem.Allocator,
    funcs: []const FuncInput,
    resolve: *const std.StringHashMap([]const NodeId),
    allow_self: bool,
) !std.ArrayList(Edge) {
    var edges: std.ArrayList(Edge) = .empty;
    errdefer edges.deinit(allocator);
    for (funcs) |f| {
        const callees = try extractCallees(allocator, f.body);
        defer allocator.free(callees);
        for (callees) |name| {
            const cands = resolve.get(name) orelse continue;
            if (cands.len == 0) continue;
            const w: f32 = 1.0 / @as(f32, @floatFromInt(cands.len));
            for (cands) |to| {
                if (!allow_self and to == f.id) continue;
                try edges.append(allocator, .{ .from = f.id, .to = to, .weight = w });
            }
        }
    }
    return edges;
}

/// Weighted in-degree centrality: how much a node is called by others. This is
/// the "god node" signal (graphify's most-connected nodes) and the additive
/// boost we fold into ranking in Phase 2.
pub fn inDegreeCentrality(allocator: std.mem.Allocator, edges: []const Edge, n_nodes: usize) ![]f32 {
    const c = try allocator.alloc(f32, n_nodes);
    @memset(c, 0);
    for (edges) |e| {
        if (e.to < n_nodes) c[e.to] += e.weight;
    }
    return c;
}

/// Iterative PageRank over a directed call graph. `damping` is typically 0.85;
/// `iterations` is usually 20–50. Dangling nodes (no outgoing edges) leak rank
/// uniformly. Returns per-node scores (caller frees).
pub fn pageRank(
    allocator: std.mem.Allocator,
    edges: []const Edge,
    n_nodes: usize,
    damping: f32,
    iterations: usize,
) ![]f32 {
    if (n_nodes == 0) return try allocator.alloc(f32, 0);

    const rank = try allocator.alloc(f32, n_nodes);
    errdefer allocator.free(rank);
    const scratch = try allocator.alloc(f32, n_nodes);
    defer allocator.free(scratch);

    const init: f32 = 1.0 / @as(f32, @floatFromInt(n_nodes));
    @memset(rank, init);

    const out_weight = try allocator.alloc(f32, n_nodes);
    defer allocator.free(out_weight);
    @memset(out_weight, 0);
    for (edges) |e| {
        if (e.from < n_nodes) out_weight[e.from] += e.weight;
    }

    const leak: f32 = (1.0 - damping) / @as(f32, @floatFromInt(n_nodes));

    for (0..iterations) |_| {
        @memset(scratch, leak);

        var dangling: f32 = 0;
        for (0..n_nodes) |i| {
            if (out_weight[i] == 0) dangling += rank[i];
        }
        if (dangling > 0) {
            const share = damping * dangling / @as(f32, @floatFromInt(n_nodes));
            for (scratch) |*s| s.* += share;
        }

        for (edges) |e| {
            if (e.from >= n_nodes or e.to >= n_nodes) continue;
            const ow = out_weight[e.from];
            if (ow > 0) scratch[e.to] += damping * rank[e.from] * (e.weight / ow);
        }

        @memcpy(rank, scratch);
    }

    return rank;
}

/// Build a forward adjacency list (caller owns returned slice and inner lists).
pub fn buildAdjacency(
    allocator: std.mem.Allocator,
    edges: []const Edge,
    n_nodes: usize,
) ![]std.ArrayList(NodeId) {
    const adj = try allocator.alloc(std.ArrayList(NodeId), n_nodes);
    errdefer {
        for (adj) |*list| list.deinit(allocator);
        allocator.free(adj);
    }
    for (adj) |*list| list.* = .empty;
    for (edges) |e| {
        if (e.from < n_nodes and e.to < n_nodes) {
            try adj[e.from].append(allocator, e.to);
        }
    }
    return adj;
}

pub fn freeAdjacency(allocator: std.mem.Allocator, adj: []std.ArrayList(NodeId)) void {
    for (adj) |*list| list.deinit(allocator);
    allocator.free(adj);
}

/// Shortest call chain from any `from_ids` node to any node in `to_ids`.
/// Returns owned node-id path (inclusive) or null when unreachable within
/// `max_hops` (default unlimited when max_hops == 0).
pub fn shortestCallPath(
    allocator: std.mem.Allocator,
    adj: []const std.ArrayList(NodeId),
    n_nodes: usize,
    from_ids: []const NodeId,
    to_ids: []const NodeId,
    max_hops: usize,
) !?[]NodeId {
    if (n_nodes == 0 or from_ids.len == 0 or to_ids.len == 0) return null;

    var to_set = std.AutoHashMap(NodeId, void).init(allocator);
    defer to_set.deinit();
    for (to_ids) |id| {
        if (id < n_nodes) try to_set.put(id, {});
    }
    if (to_set.count() == 0) return null;

    for (from_ids) |id| {
        if (id < n_nodes and to_set.contains(id)) {
            const path = try allocator.alloc(NodeId, 1);
            path[0] = id;
            return path;
        }
    }

    var queue: std.ArrayList(NodeId) = .empty;
    defer queue.deinit(allocator);
    var visited = std.AutoHashMap(NodeId, void).init(allocator);
    defer visited.deinit();
    const parent = try allocator.alloc(?NodeId, n_nodes);
    defer allocator.free(parent);
    @memset(parent, null);

    for (from_ids) |id| {
        if (id >= n_nodes) continue;
        try queue.append(allocator, id);
        try visited.put(id, {});
    }

    var head: usize = 0;
    var depth: usize = 0;
    var level_end = queue.items.len;

    while (head < queue.items.len) {
        if (head == level_end) {
            depth += 1;
            if (max_hops > 0 and depth > max_hops) return null;
            level_end = queue.items.len;
        }

        const cur = queue.items[head];
        head += 1;

        if (depth > 0 and to_set.contains(cur)) {
            var len: usize = 0;
            var n: ?NodeId = cur;
            while (n) |v| : (n = parent[v]) len += 1;

            const path = try allocator.alloc(NodeId, len);
            var idx = len;
            n = cur;
            while (n) |v| {
                idx -= 1;
                path[idx] = v;
                n = parent[v];
            }
            return path;
        }

        if (cur >= adj.len) continue;
        for (adj[cur].items) |next| {
            if (next >= n_nodes or visited.contains(next)) continue;
            try visited.put(next, {});
            parent[next] = cur;
            try queue.append(allocator, next);
        }
    }

    return null;
}
