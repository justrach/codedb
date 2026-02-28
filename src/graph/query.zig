// CodeGraph DB — graph query functions
//
// Higher-level queries built on top of CodeGraph: symbol_at, find_callers,
// find_callees, find_dependents. These are the core operations exposed
// via MCP tools to the agent.

const std = @import("std");
const types = @import("types.zig");
const graph_mod = @import("graph.zig");
const ppr_mod = @import("ppr.zig");
const CodeGraph = graph_mod.CodeGraph;
const Symbol = types.Symbol;
const Edge = types.Edge;
const EdgeKind = types.EdgeKind;

// ── Query results ───────────────────────────────────────────────────────────

pub const SymbolResult = struct {
    id: u64,
    name: []const u8,
    kind: types.SymbolKind,
    file_path: []const u8,
    line: u32,
    col: u16,
    scope: []const u8,
};

pub const CallerResult = struct {
    symbol: SymbolResult,
    edge_kind: EdgeKind,
    weight: f32,
};

// ── Queries ─────────────────────────────────────────────────────────────────

/// Find all symbols defined at a given file path and line number.
/// Returns all symbols at that exact line, or the closest symbol if none match exactly.
pub fn symbolAt(
    g: *const CodeGraph,
    file_path: []const u8,
    line: u32,
    alloc: std.mem.Allocator,
) ![]SymbolResult {
    // Find the file ID for this path
    const file_id = findFileId(g, file_path) orelse return &.{};

    // Collect symbols at this file + line
    var results: std.ArrayList(SymbolResult) = .empty;
    defer results.deinit(alloc);

    var sym_it = g.symbols.iterator();
    while (sym_it.next()) |entry| {
        const sym = entry.value_ptr.*;
        if (sym.file_id == file_id and sym.line == line) {
            try results.append(alloc, makeSymbolResult(g, sym));
        }
    }

    // If no exact match, find closest symbol before this line
    if (results.items.len == 0) {
        var best: ?Symbol = null;
        var best_dist: u32 = std.math.maxInt(u32);
        sym_it = g.symbols.iterator();
        while (sym_it.next()) |entry| {
            const sym = entry.value_ptr.*;
            if (sym.file_id == file_id and sym.line <= line) {
                const dist = line - sym.line;
                if (dist < best_dist) {
                    best_dist = dist;
                    best = sym;
                }
            }
        }
        if (best) |sym| {
            try results.append(alloc, makeSymbolResult(g, sym));
        }
    }

    const out = try alloc.alloc(SymbolResult, results.items.len);
    @memcpy(out, results.items);
    return out;
}

/// Find all callers of a symbol (nodes with edges pointing to it).
pub fn findCallers(
    g: *const CodeGraph,
    symbol_id: u64,
    alloc: std.mem.Allocator,
) ![]CallerResult {
    const in = g.inEdges(symbol_id);

    var results: std.ArrayList(CallerResult) = .empty;
    defer results.deinit(alloc);

    for (in) |edge| {
        const sym = g.getSymbol(edge.src) orelse continue;
        try results.append(alloc, .{
            .symbol = makeSymbolResult(g, sym),
            .edge_kind = edge.kind,
            .weight = edge.weight,
        });
    }

    const out = try alloc.alloc(CallerResult, results.items.len);
    @memcpy(out, results.items);
    return out;
}

/// Find all callees of a symbol (nodes it has edges pointing to).
pub fn findCallees(
    g: *const CodeGraph,
    symbol_id: u64,
    alloc: std.mem.Allocator,
) ![]CallerResult {
    const edges = g.outEdges(symbol_id);

    var results: std.ArrayList(CallerResult) = .empty;
    defer results.deinit(alloc);

    for (edges) |edge| {
        const sym = g.getSymbol(edge.dst) orelse continue;
        try results.append(alloc, .{
            .symbol = makeSymbolResult(g, sym),
            .edge_kind = edge.kind,
            .weight = edge.weight,
        });
    }

    const out = try alloc.alloc(CallerResult, results.items.len);
    @memcpy(out, results.items);
    return out;
}

/// Find all symbols that depend on the given symbol, ranked by PPR score.
/// This uses Personalized PageRank to find the most relevant dependents,
/// not just direct callers but transitive ones weighted by graph structure.
pub fn findDependents(
    g: *const CodeGraph,
    symbol_id: u64,
    max_results: usize,
    alloc: std.mem.Allocator,
) ![]ppr_mod.ScoredNode {
    var scores = try ppr_mod.pprPush(g, symbol_id, ppr_mod.DEFAULT_ALPHA, ppr_mod.DEFAULT_EPSILON, alloc);
    defer scores.deinit();

    const top = try ppr_mod.topK(&scores, max_results, symbol_id, alloc);
    return top;
}

// ── Helpers ─────────────────────────────────────────────────────────────────

fn findFileId(g: *const CodeGraph, path: []const u8) ?u32 {
    var it = g.files.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.value_ptr.path, path)) return entry.key_ptr.*;
    }
    return null;
}

fn makeSymbolResult(g: *const CodeGraph, sym: Symbol) SymbolResult {
    const file_path = if (g.getFile(sym.file_id)) |f| f.path else "";
    return .{
        .id = sym.id,
        .name = sym.name,
        .kind = sym.kind,
        .file_path = file_path,
        .line = sym.line,
        .col = sym.col,
        .scope = sym.scope,
    };
}

// ── Tests ───────────────────────────────────────────────────────────────────

fn buildTestGraph(alloc: std.mem.Allocator) !CodeGraph {
    var g = CodeGraph.init(alloc);

    try g.addFile(.{ .id = 1, .path = "src/main.ts", .language = .typescript, .last_modified = 0, .hash = [_]u8{0} ** 32 });
    try g.addFile(.{ .id = 2, .path = "src/utils.ts", .language = .typescript, .last_modified = 0, .hash = [_]u8{0} ** 32 });

    try g.addSymbol(.{ .id = 10, .name = "main", .kind = .function, .file_id = 1, .line = 1, .col = 0, .scope = "" });
    try g.addSymbol(.{ .id = 20, .name = "handleRequest", .kind = .function, .file_id = 1, .line = 10, .col = 0, .scope = "" });
    try g.addSymbol(.{ .id = 30, .name = "formatOutput", .kind = .function, .file_id = 2, .line = 5, .col = 0, .scope = "" });
    try g.addSymbol(.{ .id = 40, .name = "validate", .kind = .function, .file_id = 2, .line = 20, .col = 0, .scope = "" });

    // main → handleRequest → formatOutput
    // main → validate
    try g.addEdge(.{ .src = 10, .dst = 20, .kind = .calls, .weight = 2.0 });
    try g.addEdge(.{ .src = 20, .dst = 30, .kind = .calls });
    try g.addEdge(.{ .src = 10, .dst = 40, .kind = .calls });

    return g;
}

test "symbolAt finds exact line match" {
    var g = try buildTestGraph(std.testing.allocator);
    defer g.deinit();

    const results = try symbolAt(&g, "src/main.ts", 10, std.testing.allocator);
    defer std.testing.allocator.free(results);

    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("handleRequest", results[0].name);
    try std.testing.expectEqualStrings("src/main.ts", results[0].file_path);
}

test "symbolAt finds closest symbol before line" {
    var g = try buildTestGraph(std.testing.allocator);
    defer g.deinit();

    // Line 15 is between handleRequest (10) and nothing — should find handleRequest
    const results = try symbolAt(&g, "src/main.ts", 15, std.testing.allocator);
    defer std.testing.allocator.free(results);

    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("handleRequest", results[0].name);
}

test "symbolAt returns empty for unknown file" {
    var g = try buildTestGraph(std.testing.allocator);
    defer g.deinit();

    const results = try symbolAt(&g, "nonexistent.ts", 1, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "findCallers returns in-edges" {
    var g = try buildTestGraph(std.testing.allocator);
    defer g.deinit();

    // handleRequest (20) is called by main (10)
    const callers = try findCallers(&g, 20, std.testing.allocator);
    defer std.testing.allocator.free(callers);

    try std.testing.expectEqual(@as(usize, 1), callers.len);
    try std.testing.expectEqualStrings("main", callers[0].symbol.name);
    try std.testing.expectEqual(EdgeKind.calls, callers[0].edge_kind);
}

test "findCallees returns out-edges" {
    var g = try buildTestGraph(std.testing.allocator);
    defer g.deinit();

    // main (10) calls handleRequest (20) and validate (40)
    const callees = try findCallees(&g, 10, std.testing.allocator);
    defer std.testing.allocator.free(callees);

    try std.testing.expectEqual(@as(usize, 2), callees.len);
}

test "findDependents uses PPR ranking" {
    var g = try buildTestGraph(std.testing.allocator);
    defer g.deinit();

    const deps = try findDependents(&g, 10, 5, std.testing.allocator);
    defer std.testing.allocator.free(deps);

    // Should find dependents ranked by PPR score
    try std.testing.expect(deps.len > 0);
    // Scores should be descending
    for (0..deps.len - 1) |i| {
        try std.testing.expect(deps[i].score >= deps[i + 1].score);
    }
}

test "findCallers on node with no callers returns empty" {
    var g = try buildTestGraph(std.testing.allocator);
    defer g.deinit();

    const callers = try findCallers(&g, 10, std.testing.allocator);
    defer std.testing.allocator.free(callers);

    try std.testing.expectEqual(@as(usize, 0), callers.len);
}

// ── Edge case tests ─────────────────────────────────────────────────────────

test "symbolAt on empty graph returns empty" {
    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();

    const results = try symbolAt(&g, "anything.ts", 1, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "symbolAt with line=0 finds symbol at line 0" {
    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();

    try g.addFile(.{ .id = 1, .path = "f.ts", .language = .typescript, .last_modified = 0, .hash = [_]u8{0} ** 32 });
    try g.addSymbol(.{ .id = 1, .name = "top", .kind = .variable, .file_id = 1, .line = 0, .col = 0, .scope = "" });

    const results = try symbolAt(&g, "f.ts", 0, std.testing.allocator);
    defer std.testing.allocator.free(results);

    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("top", results[0].name);
}

test "symbolAt with line=maxInt returns closest symbol" {
    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();

    try g.addFile(.{ .id = 1, .path = "f.ts", .language = .typescript, .last_modified = 0, .hash = [_]u8{0} ** 32 });
    try g.addSymbol(.{ .id = 1, .name = "last", .kind = .function, .file_id = 1, .line = 999, .col = 0, .scope = "" });

    const results = try symbolAt(&g, "f.ts", std.math.maxInt(u32), std.testing.allocator);
    defer std.testing.allocator.free(results);

    // Should find closest symbol before maxInt — the only symbol at line 999
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("last", results[0].name);
}

test "findCallers on nonexistent node returns empty" {
    var g = try buildTestGraph(std.testing.allocator);
    defer g.deinit();

    // Node 99999 does not exist in the graph
    const callers = try findCallers(&g, 99999, std.testing.allocator);
    defer std.testing.allocator.free(callers);

    try std.testing.expectEqual(@as(usize, 0), callers.len);
}

test "findCallees on node with no callees returns empty" {
    var g = try buildTestGraph(std.testing.allocator);
    defer g.deinit();

    // formatOutput (30) has no outgoing edges
    const callees = try findCallees(&g, 30, std.testing.allocator);
    defer std.testing.allocator.free(callees);

    try std.testing.expectEqual(@as(usize, 0), callees.len);
}

test "findCallees on nonexistent node returns empty" {
    var g = try buildTestGraph(std.testing.allocator);
    defer g.deinit();

    const callees = try findCallees(&g, 99999, std.testing.allocator);
    defer std.testing.allocator.free(callees);

    try std.testing.expectEqual(@as(usize, 0), callees.len);
}

test "findDependents on isolated node returns empty" {
    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();

    try g.addFile(.{ .id = 1, .path = "f.ts", .language = .typescript, .last_modified = 0, .hash = [_]u8{0} ** 32 });
    try g.addSymbol(.{ .id = 1, .name = "lonely", .kind = .function, .file_id = 1, .line = 1, .col = 0, .scope = "" });

    // Node exists but has no edges — PPR should return no dependents
    const deps = try findDependents(&g, 1, 10, std.testing.allocator);
    defer std.testing.allocator.free(deps);

    try std.testing.expectEqual(@as(usize, 0), deps.len);
}

test "findDependents with max_results=0 returns empty" {
    var g = try buildTestGraph(std.testing.allocator);
    defer g.deinit();

    // Requesting 0 results should return empty
    const deps = try findDependents(&g, 10, 0, std.testing.allocator);
    defer std.testing.allocator.free(deps);

    try std.testing.expectEqual(@as(usize, 0), deps.len);
}

test "graph with edges but no matching symbols — findCallers skips missing" {
    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();

    // Add edges referencing symbols that don't exist in the symbol table
    try g.addEdge(.{ .src = 100, .dst = 200, .kind = .calls });
    try g.addEdge(.{ .src = 300, .dst = 200, .kind = .calls });

    // findCallers for node 200 — edges exist but src symbols 100, 300 not in graph
    const callers = try findCallers(&g, 200, std.testing.allocator);
    defer std.testing.allocator.free(callers);

    // Should return empty since the source symbols can't be resolved
    try std.testing.expectEqual(@as(usize, 0), callers.len);
}

test "multiple symbols on same line all returned" {
    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();

    try g.addFile(.{ .id = 1, .path = "f.ts", .language = .typescript, .last_modified = 0, .hash = [_]u8{0} ** 32 });
    // Two symbols at the same line (e.g., destructured assignment)
    try g.addSymbol(.{ .id = 1, .name = "alpha", .kind = .variable, .file_id = 1, .line = 5, .col = 0, .scope = "" });
    try g.addSymbol(.{ .id = 2, .name = "beta", .kind = .variable, .file_id = 1, .line = 5, .col = 10, .scope = "" });

    const results = try symbolAt(&g, "f.ts", 5, std.testing.allocator);
    defer std.testing.allocator.free(results);

    try std.testing.expectEqual(@as(usize, 2), results.len);
}

test "symbolAt closest match prefers nearest line before query" {
    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();

    try g.addFile(.{ .id = 1, .path = "f.ts", .language = .typescript, .last_modified = 0, .hash = [_]u8{0} ** 32 });
    try g.addSymbol(.{ .id = 1, .name = "early", .kind = .function, .file_id = 1, .line = 1, .col = 0, .scope = "" });
    try g.addSymbol(.{ .id = 2, .name = "mid", .kind = .function, .file_id = 1, .line = 50, .col = 0, .scope = "" });
    try g.addSymbol(.{ .id = 3, .name = "late", .kind = .function, .file_id = 1, .line = 100, .col = 0, .scope = "" });

    // Query line 55 — closest before is "mid" at line 50
    const results = try symbolAt(&g, "f.ts", 55, std.testing.allocator);
    defer std.testing.allocator.free(results);

    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("mid", results[0].name);
}

test "symbolAt returns empty when line is before all symbols" {
    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();

    try g.addFile(.{ .id = 1, .path = "f.ts", .language = .typescript, .last_modified = 0, .hash = [_]u8{0} ** 32 });
    try g.addSymbol(.{ .id = 1, .name = "later", .kind = .function, .file_id = 1, .line = 100, .col = 0, .scope = "" });

    // Query line 1 — no symbol at or before line 1 (symbol is at 100)
    const results = try symbolAt(&g, "f.ts", 1, std.testing.allocator);
    defer std.testing.allocator.free(results);

    try std.testing.expectEqual(@as(usize, 0), results.len);
}
