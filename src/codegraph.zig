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

/// A resolved call edge `from` → `to`. Edges are emitted only when resolution
/// selects one definition, so every retained call contributes its full weight.
pub const Edge = struct {
    from: NodeId,
    to: NodeId,
    weight: f32,
};

pub const ImportBinding = struct {
    alias: []const u8,
    target_path: []const u8,
};

pub const FuncInput = struct {
    id: NodeId,
    /// The function's body text (caller slices it from content via line ranges).
    body: []const u8,
    /// Optional resolution facts. The lightweight unit-test API can omit these;
    /// Explorer supplies them for same-file and imported-module resolution.
    path: []const u8 = "",
    imports: []const ImportBinding = &.{},
    extract_zig_thread_spawn_callbacks: bool = false,
};

pub const Callee = struct {
    name: []const u8,
    /// Dotted expression before the final callee name (`std.Thread` in
    /// `std.Thread.spawn`). Null for a bare call such as `helper()`.
    qualifier: ?[]const u8 = null,
};

/// True for identifiers that precede `(` but are language keywords / control flow,
/// not callees — so `if (`, `for (`, `while (`, `catch (`, `return (` etc. are not
/// counted as calls. Deliberately a cross-language superset (codedb indexes ~40
/// languages); over-filtering a rare real call only loses an additive boost.
fn isCallKeyword(name: []const u8) bool {
    const kws = [_][]const u8{
        "if",     "else",  "for",      "while", "switch", "return", "catch",
        "try",    "defer", "errdefer", "and",   "or",     "orelse", "sizeof",
        "typeof", "do",    "case",     "when",  "match",  "with",   "in",
        "not",    "is",    "await",    "yield", "throw",  "new",    "delete",
        "fn",     "func",  "function", "def",   "class",  "struct", "enum",
        "union",  "const", "var",      "let",   "static", "assert", "where",
        "select", "from",  "foreach",  "using", "unless", "until",  "elif",
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

const ParsedCallee = struct {
    callee: Callee,
    key: []const u8,
};

fn calleeBeforeOpenParen(body: []const u8, open_paren: usize) ?ParsedCallee {
    var end = open_paren;
    while (end > 0 and (body[end - 1] == ' ' or body[end - 1] == '\t')) end -= 1;

    var start = end;
    while (start > 0 and isIdentChar(body[start - 1])) start -= 1;
    if (start == end) return null;
    const name = body[start..end];
    if (!isIdentStart(name[0]) or isCallKeyword(name)) return null;

    var qualifier: ?[]const u8 = null;
    var key_start = start;
    if (start > 0 and body[start - 1] == '.') {
        const qualifier_end = start - 1;
        var cursor = qualifier_end;
        var qualifier_start = qualifier_end;
        while (cursor > 0) {
            const segment_end = cursor;
            while (cursor > 0 and isIdentChar(body[cursor - 1])) cursor -= 1;
            if (cursor == segment_end or !isIdentStart(body[cursor])) break;
            qualifier_start = cursor;
            if (cursor == 0 or body[cursor - 1] != '.') break;
            cursor -= 1;
        }
        if (qualifier_start < qualifier_end) {
            qualifier = body[qualifier_start..qualifier_end];
            key_start = qualifier_start;
        }
    }

    return .{
        .callee = .{ .name = name, .qualifier = qualifier },
        .key = body[key_start..end],
    };
}

/// Extract deduped call sites from a function body. Qualified calls retain the
/// receiver/module expression (`server.run(` becomes `{run, server}`) so the
/// edge builder can use import facts instead of fanning out by bare name.
/// Items borrow from `body`; the caller frees only the returned array.
pub fn extractCallees(allocator: std.mem.Allocator, body: []const u8) ![]Callee {
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();
    var out: std.ArrayList(Callee) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        const c = body[i];
        // Skip line comments, block comments, and string/char literals so an identifier
        // mentioned only inside one is not mistaken for a call site (#548 family).
        if (c == '/' and i + 1 < body.len and body[i + 1] == '/') {
            i += 2;
            while (i < body.len and body[i] != '\n') i += 1;
            continue;
        }
        if (c == '/' and i + 1 < body.len and body[i + 1] == '*') {
            i += 2;
            while (i + 1 < body.len and !(body[i] == '*' and body[i + 1] == '/')) i += 1;
            i += 1; // land on '/' of '*/'; the loop's i += 1 then moves past it
            continue;
        }
        if (c == '"' or c == '\'') {
            i += 1;
            while (i < body.len and body[i] != c) {
                if (body[i] == '\\') i += 1; // skip an escaped char
                i += 1;
            }
            continue;
        }
        if (c != '(') continue;
        const parsed = calleeBeforeOpenParen(body, i) orelse continue;
        const g = try seen.getOrPut(parsed.key);
        if (!g.found_existing) try out.append(allocator, parsed.callee);
    }
    return out.toOwnedSlice(allocator);
}

fn functionValueOnly(raw: []const u8) ?ParsedCallee {
    const value = std.mem.trim(u8, raw, " \t\r\n");
    if (value.len == 0 or !isIdentStart(value[0])) return null;
    var segment_start: usize = 0;
    var last_dot: ?usize = null;
    for (value, 0..) |c, i| {
        if (c == '.') {
            if (i == segment_start) return null;
            last_dot = i;
            segment_start = i + 1;
            continue;
        }
        if (!isIdentChar(c) or (i == segment_start and !isIdentStart(c))) return null;
    }
    if (segment_start == value.len) return null;
    const name = value[segment_start..];
    return .{
        .callee = .{
            .name = name,
            .qualifier = if (last_dot) |dot| value[0..dot] else null,
        },
        .key = value,
    };
}

/// Return the bare or module-qualified function value passed as the second
/// argument to one exact Zig form: `std.Thread.spawn(config, callback, args)`.
/// This intentionally does not infer arbitrary expressions or dynamic callbacks.
const SpawnCallbackParse = struct {
    callback: ?ParsedCallee = null,
    /// Last byte inspected. The outer scanner advances here so a malformed
    /// spawn prefix cannot make every following `(` rescan the same suffix.
    end: usize,
};

fn zigThreadSpawnCallback(body: []const u8, open_paren: usize) SpawnCallbackParse {
    var paren_depth: usize = 0;
    var brace_depth: usize = 0;
    var bracket_depth: usize = 0;
    var arg_index: usize = 0;
    var arg_start = open_paren + 1;
    var second_start: ?usize = null;
    var second_end: ?usize = null;
    var i = open_paren + 1;
    while (i < body.len) : (i += 1) {
        const c = body[i];
        if (c == '/' and i + 1 < body.len and body[i + 1] == '/') {
            i += 2;
            while (i < body.len and body[i] != '\n') i += 1;
            continue;
        }
        if (c == '/' and i + 1 < body.len and body[i + 1] == '*') {
            i += 2;
            while (i + 1 < body.len and !(body[i] == '*' and body[i + 1] == '/')) i += 1;
            if (i + 1 >= body.len) return .{ .end = body.len };
            i += 1;
            continue;
        }
        if (c == '"' or c == '\'') {
            const quote = c;
            i += 1;
            while (i < body.len and body[i] != quote) {
                if (body[i] == '\\') i += 1;
                i += 1;
            }
            if (i >= body.len) return .{ .end = body.len };
            continue;
        }
        switch (c) {
            '(' => paren_depth += 1,
            ')' => {
                if (paren_depth > 0) {
                    paren_depth -= 1;
                } else {
                    if (brace_depth != 0 or bracket_depth != 0 or arg_index != 2) return .{ .end = i };
                    if (std.mem.trim(u8, body[arg_start..i], " \t\r\n").len == 0) return .{ .end = i };
                    const start = second_start orelse return .{ .end = i };
                    const end = second_end orelse return .{ .end = i };
                    return .{ .callback = functionValueOnly(body[start..end]), .end = i };
                }
            },
            '{' => brace_depth += 1,
            '}' => {
                if (brace_depth == 0) return .{ .end = i };
                brace_depth -= 1;
            },
            '[' => bracket_depth += 1,
            ']' => {
                if (bracket_depth == 0) return .{ .end = i };
                bracket_depth -= 1;
            },
            ',' => if (paren_depth == 0 and brace_depth == 0 and bracket_depth == 0) {
                if (std.mem.trim(u8, body[arg_start..i], " \t\r\n").len == 0) return .{ .end = i };
                if (arg_index == 0) {
                    second_start = i + 1;
                    arg_index = 1;
                } else if (arg_index == 1) {
                    second_end = i;
                    arg_index = 2;
                } else {
                    return .{ .end = i };
                }
                arg_start = i + 1;
            },
            else => {},
        }
    }
    return .{ .end = body.len };
}

pub fn extractZigThreadSpawnCallbacks(allocator: std.mem.Allocator, body: []const u8) ![]Callee {
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();
    var out: std.ArrayList(Callee) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        const c = body[i];
        if (c == '/' and i + 1 < body.len and body[i + 1] == '/') {
            i += 2;
            while (i < body.len and body[i] != '\n') i += 1;
            continue;
        }
        if (c == '/' and i + 1 < body.len and body[i + 1] == '*') {
            i += 2;
            while (i + 1 < body.len and !(body[i] == '*' and body[i + 1] == '/')) i += 1;
            i += 1;
            continue;
        }
        if (c == '"' or c == '\'') {
            i += 1;
            while (i < body.len and body[i] != c) {
                if (body[i] == '\\') i += 1;
                i += 1;
            }
            continue;
        }
        if (c != '(') continue;
        const parsed = calleeBeforeOpenParen(body, i) orelse continue;
        if (!std.mem.eql(u8, parsed.callee.name, "spawn")) continue;
        const qualifier = parsed.callee.qualifier orelse continue;
        if (!std.mem.eql(u8, qualifier, "std.Thread")) continue;
        const parsed_callback = zigThreadSpawnCallback(body, i);
        i = parsed_callback.end;
        const callback = parsed_callback.callback orelse continue;
        const g = try seen.getOrPut(callback.key);
        if (!g.found_existing) try out.append(allocator, callback.callee);
    }
    return out.toOwnedSlice(allocator);
}

/// Build resolved call edges for a set of functions. Ambiguous names are skipped
/// instead of fanning out to unrelated definitions.
pub fn buildEdges(
    allocator: std.mem.Allocator,
    funcs: []const FuncInput,
    resolve: *const std.StringHashMap([]const NodeId),
    allow_self: bool,
) !std.ArrayList(Edge) {
    return buildEdgesScoped(allocator, funcs, resolve, null, null, allow_self);
}

/// Like buildEdges, but only resolves a call to definitions in the caller's
/// language family. `groups` is indexed by NodeId. This prevents a generic
/// name such as `route` or `run` from creating a synthetic Zig -> Python edge
/// while still allowing deliberately compatible families (for example
/// JavaScript/TypeScript) to share definitions.
pub fn buildEdgesWithinGroups(
    allocator: std.mem.Allocator,
    funcs: []const FuncInput,
    resolve: *const std.StringHashMap([]const NodeId),
    groups: ?[]const u8,
    allow_self: bool,
) !std.ArrayList(Edge) {
    return buildEdgesScoped(allocator, funcs, resolve, null, groups, allow_self);
}

const CandidateChoice = struct {
    id: ?NodeId = null,
    count: usize = 0,
};

fn chooseCandidates(
    f: FuncInput,
    cands: []const NodeId,
    node_paths: ?[]const []const u8,
    groups: ?[]const u8,
    required_path: ?[]const u8,
) CandidateChoice {
    var result: CandidateChoice = .{};
    for (cands) |to| {
        if (groups) |node_groups| {
            if (f.id >= node_groups.len or to >= node_groups.len or node_groups[to] != node_groups[f.id]) continue;
        }
        if (required_path) |path| {
            const paths = node_paths orelse continue;
            if (to >= paths.len or !std.mem.eql(u8, paths[to], path)) continue;
        }
        result.count += 1;
        if (result.count == 1) result.id = to else result.id = null;
    }
    return result;
}

const ImportTarget = struct {
    found: bool = false,
    ambiguous: bool = false,
    path: ?[]const u8 = null,
};

fn importedTarget(f: FuncInput, qualifier: []const u8) ImportTarget {
    const alias_end = std.mem.indexOfScalar(u8, qualifier, '.') orelse qualifier.len;
    const alias = qualifier[0..alias_end];
    var result: ImportTarget = .{};
    for (f.imports) |binding| {
        if (!std.mem.eql(u8, binding.alias, alias)) continue;
        if (!result.found) {
            result.found = true;
            result.path = binding.target_path;
        } else if (!std.mem.eql(u8, result.path.?, binding.target_path)) {
            result.ambiguous = true;
            result.path = null;
        }
    }
    return result;
}

fn resolveDirectCallee(
    f: FuncInput,
    callee: Callee,
    cands: []const NodeId,
    node_paths: ?[]const []const u8,
    groups: ?[]const u8,
) ?NodeId {
    if (callee.qualifier) |qualifier| {
        const imported = importedTarget(f, qualifier);
        if (imported.found) {
            if (imported.ambiguous) return null;
            const choice = chooseCandidates(f, cands, node_paths, groups, imported.path.?);
            return if (choice.count == 1) choice.id else null;
        }
        // Preserve the old behavior for globally unique method names when the
        // receiver is a value whose type codedb cannot infer.
        const choice = chooseCandidates(f, cands, node_paths, groups, null);
        return if (choice.count == 1) choice.id else null;
    }

    if (node_paths != null and f.path.len != 0) {
        const local = chooseCandidates(f, cands, node_paths, groups, f.path);
        if (local.count > 0) return if (local.count == 1) local.id else null;
    }
    const global = chooseCandidates(f, cands, node_paths, groups, null);
    return if (global.count == 1) global.id else null;
}

/// Thread callback values are resolved more strictly than direct calls: an
/// imported qualifier must bind to exactly one function in that imported file;
/// otherwise the callback must name exactly one function in the caller's file.
/// There is deliberately no repository-global fallback for function values.
fn resolveThreadCallback(
    f: FuncInput,
    callback: Callee,
    cands: []const NodeId,
    node_paths: ?[]const []const u8,
    groups: ?[]const u8,
) ?NodeId {
    if (callback.qualifier) |qualifier| {
        const imported = importedTarget(f, qualifier);
        if (imported.found) {
            if (imported.ambiguous) return null;
            const choice = chooseCandidates(f, cands, node_paths, groups, imported.path.?);
            return if (choice.count == 1) choice.id else null;
        }
    }
    if (node_paths == null or f.path.len == 0) return null;
    const local = chooseCandidates(f, cands, node_paths, groups, f.path);
    return if (local.count == 1) local.id else null;
}

fn appendUniqueEdge(
    allocator: std.mem.Allocator,
    edges: *std.ArrayList(Edge),
    function_edge_start: usize,
    from: NodeId,
    to: NodeId,
    allow_self: bool,
) !void {
    if (!allow_self and to == from) return;
    for (edges.items[function_edge_start..]) |edge| {
        if (edge.to == to) return;
    }
    try edges.append(allocator, .{ .from = from, .to = to, .weight = 1.0 });
}

/// Resolve using caller paths and per-file import bindings. Resolution priority
/// is: imported module receiver, same-file bare helper, globally unique name.
/// Every tier keeps the language-family guard; ambiguity emits no edge.
pub fn buildEdgesScoped(
    allocator: std.mem.Allocator,
    funcs: []const FuncInput,
    resolve: *const std.StringHashMap([]const NodeId),
    node_paths: ?[]const []const u8,
    groups: ?[]const u8,
    allow_self: bool,
) !std.ArrayList(Edge) {
    var edges: std.ArrayList(Edge) = .empty;
    errdefer edges.deinit(allocator);
    for (funcs) |f| {
        const function_edge_start = edges.items.len;
        const callees = try extractCallees(allocator, f.body);
        defer allocator.free(callees);
        for (callees) |callee| {
            const cands = resolve.get(callee.name) orelse continue;
            const to = resolveDirectCallee(f, callee, cands, node_paths, groups) orelse continue;
            try appendUniqueEdge(allocator, &edges, function_edge_start, f.id, to, allow_self);
        }

        if (f.extract_zig_thread_spawn_callbacks and node_paths != null and f.path.len != 0) {
            const callbacks = try extractZigThreadSpawnCallbacks(allocator, f.body);
            defer allocator.free(callbacks);
            for (callbacks) |callback| {
                const cands = resolve.get(callback.name) orelse continue;
                const to = resolveThreadCallback(f, callback, cands, node_paths, groups) orelse continue;
                try appendUniqueEdge(allocator, &edges, function_edge_start, f.id, to, allow_self);
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
