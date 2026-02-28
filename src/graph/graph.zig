// CodeGraph — in-memory code graph backed by an arena allocator.
//
// All strings (symbol names, file paths, etc.) are duped into the arena,
// so deinit() frees everything at once — no per-field cleanup needed.
//
// Bidirectional adjacency: out_edges and in_edges are both maintained on
// addEdge() for efficient forward/backward traversal (needed by PPR).

const std = @import("std");
const types = @import("types.zig");

pub const Symbol = types.Symbol;
pub const File = types.File;
pub const Commit = types.Commit;
pub const Edge = types.Edge;
pub const EdgeKind = types.EdgeKind;
pub const SymbolKind = types.SymbolKind;
pub const Language = types.Language;

pub const CodeGraph = struct {
    symbols: std.AutoHashMap(u64, Symbol),
    files: std.AutoHashMap(u32, File),
    commits: std.AutoHashMap(u32, Commit),
    out_edges: std.AutoHashMap(u64, std.ArrayList(Edge)),
    in_edges: std.AutoHashMap(u64, std.ArrayList(Edge)),
    arena: std.heap.ArenaAllocator,

    pub fn init(backing: std.mem.Allocator) CodeGraph {
        return .{
            .symbols = std.AutoHashMap(u64, Symbol).init(backing),
            .files = std.AutoHashMap(u32, File).init(backing),
            .commits = std.AutoHashMap(u32, Commit).init(backing),
            .out_edges = std.AutoHashMap(u64, std.ArrayList(Edge)).init(backing),
            .in_edges = std.AutoHashMap(u64, std.ArrayList(Edge)).init(backing),
            .arena = std.heap.ArenaAllocator.init(backing),
        };
    }

    pub fn deinit(self: *CodeGraph) void {
        // Free all edge ArrayLists
        var out_it = self.out_edges.valueIterator();
        while (out_it.next()) |list| list.deinit(self.out_edges.allocator);
        var in_it = self.in_edges.valueIterator();
        while (in_it.next()) |list| list.deinit(self.in_edges.allocator);

        self.out_edges.deinit();
        self.in_edges.deinit();
        self.symbols.deinit();
        self.files.deinit();
        self.commits.deinit();
        self.arena.deinit();
    }

    // ── Mutations ───────────────────────────────────────────────────────

    pub fn addSymbol(self: *CodeGraph, sym: Symbol) !void {
        const alloc = self.arena.allocator();
        const name = try alloc.dupe(u8, sym.name);
        const scope = try alloc.dupe(u8, sym.scope);
        try self.symbols.put(sym.id, .{
            .id = sym.id,
            .name = name,
            .kind = sym.kind,
            .file_id = sym.file_id,
            .line = sym.line,
            .col = sym.col,
            .scope = scope,
        });
    }

    pub fn addFile(self: *CodeGraph, file: File) !void {
        const alloc = self.arena.allocator();
        const path = try alloc.dupe(u8, file.path);
        try self.files.put(file.id, .{
            .id = file.id,
            .path = path,
            .language = file.language,
            .last_modified = file.last_modified,
            .hash = file.hash,
        });
    }

    pub fn addCommit(self: *CodeGraph, commit: Commit) !void {
        const alloc = self.arena.allocator();
        const author = try alloc.dupe(u8, commit.author);
        const message = try alloc.dupe(u8, commit.message);
        try self.commits.put(commit.id, .{
            .id = commit.id,
            .hash = commit.hash,
            .timestamp = commit.timestamp,
            .author = author,
            .message = message,
        });
    }

    pub fn addEdge(self: *CodeGraph, edge: Edge) !void {
        const backing = self.out_edges.allocator;

        // out_edges: src → edge
        const out = try self.out_edges.getOrPut(edge.src);
        if (!out.found_existing) out.value_ptr.* = std.ArrayList(Edge).empty;
        try out.value_ptr.append(backing, edge);

        // in_edges: dst → edge
        const in = try self.in_edges.getOrPut(edge.dst);
        if (!in.found_existing) in.value_ptr.* = std.ArrayList(Edge).empty;
        try in.value_ptr.append(backing, edge);
    }

    // ── Queries ─────────────────────────────────────────────────────────

    pub fn getSymbol(self: *const CodeGraph, id: u64) ?Symbol {
        return self.symbols.get(id);
    }

    pub fn getFile(self: *const CodeGraph, id: u32) ?File {
        return self.files.get(id);
    }

    pub fn getCommit(self: *const CodeGraph, id: u32) ?Commit {
        return self.commits.get(id);
    }

    pub fn outEdges(self: *const CodeGraph, node_id: u64) []const Edge {
        const list = self.out_edges.get(node_id) orelse return &.{};
        return list.items;
    }

    pub fn inEdges(self: *const CodeGraph, node_id: u64) []const Edge {
        const list = self.in_edges.get(node_id) orelse return &.{};
        return list.items;
    }

    pub fn outDegree(self: *const CodeGraph, node_id: u64) usize {
        return self.outEdges(node_id).len;
    }

    pub fn symbolCount(self: *const CodeGraph) usize {
        return self.symbols.count();
    }

    pub fn edgeCount(self: *const CodeGraph) usize {
        var total: usize = 0;
        var it = self.out_edges.valueIterator();
        while (it.next()) |list| total += list.items.len;
        return total;
    }
};

// ── Tests ───────────────────────────────────────────────────────────────────

test "init and deinit with no leaks" {
    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();

    try std.testing.expectEqual(@as(usize, 0), g.symbolCount());
    try std.testing.expectEqual(@as(usize, 0), g.edgeCount());
}

test "addSymbol and getSymbol round-trip" {
    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();

    try g.addSymbol(.{
        .id = 42,
        .name = "doStuff",
        .kind = .function,
        .file_id = 1,
        .line = 10,
        .col = 4,
        .scope = "main",
    });

    const sym = g.getSymbol(42).?;
    try std.testing.expectEqualStrings("doStuff", sym.name);
    try std.testing.expectEqual(SymbolKind.function, sym.kind);
    try std.testing.expectEqual(@as(u32, 1), sym.file_id);
    try std.testing.expectEqual(@as(u32, 10), sym.line);
    try std.testing.expectEqual(@as(u16, 4), sym.col);
    try std.testing.expectEqualStrings("main", sym.scope);
}

test "addFile and getFile round-trip" {
    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();

    try g.addFile(.{
        .id = 1,
        .path = "src/main.zig",
        .language = .zig,
        .last_modified = 1700000000,
        .hash = [_]u8{0xAB} ** 32,
    });

    const f = g.getFile(1).?;
    try std.testing.expectEqualStrings("src/main.zig", f.path);
    try std.testing.expectEqual(Language.zig, f.language);
    try std.testing.expectEqual(@as(i64, 1700000000), f.last_modified);
    try std.testing.expectEqual(@as(u8, 0xAB), f.hash[0]);
}

test "addCommit and getCommit round-trip" {
    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();

    try g.addCommit(.{
        .id = 1,
        .hash = "abc123def456abc123def456abc123def456abc1".*, // 40 chars
        .timestamp = 1700000000,
        .author = "alice",
        .message = "initial commit",
    });

    const c = g.getCommit(1).?;
    try std.testing.expectEqualStrings("alice", c.author);
    try std.testing.expectEqualStrings("initial commit", c.message);
    try std.testing.expectEqual(@as(i64, 1700000000), c.timestamp);
}

test "addEdge creates both out and in entries" {
    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();

    try g.addEdge(.{ .src = 1, .dst = 2, .kind = .calls });

    const out = g.outEdges(1);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqual(@as(u64, 2), out[0].dst);
    try std.testing.expectEqual(EdgeKind.calls, out[0].kind);

    const in = g.inEdges(2);
    try std.testing.expectEqual(@as(usize, 1), in.len);
    try std.testing.expectEqual(@as(u64, 1), in[0].src);
}

test "outDegree counts correctly" {
    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();

    try g.addEdge(.{ .src = 1, .dst = 2, .kind = .calls });
    try g.addEdge(.{ .src = 1, .dst = 3, .kind = .imports });
    try g.addEdge(.{ .src = 1, .dst = 4, .kind = .references });

    try std.testing.expectEqual(@as(usize, 3), g.outDegree(1));
    try std.testing.expectEqual(@as(usize, 0), g.outDegree(99));
}

test "symbolCount and edgeCount are accurate" {
    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();

    try g.addSymbol(.{ .id = 1, .name = "a", .kind = .function, .file_id = 0, .line = 1, .col = 0, .scope = "" });
    try g.addSymbol(.{ .id = 2, .name = "b", .kind = .method, .file_id = 0, .line = 5, .col = 0, .scope = "" });

    try g.addEdge(.{ .src = 1, .dst = 2, .kind = .calls });
    try g.addEdge(.{ .src = 2, .dst = 1, .kind = .references });

    try std.testing.expectEqual(@as(usize, 2), g.symbolCount());
    try std.testing.expectEqual(@as(usize, 2), g.edgeCount());
}

test "duplicate symbol ID overwrites (put semantics)" {
    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();

    try g.addSymbol(.{ .id = 1, .name = "old", .kind = .function, .file_id = 0, .line = 1, .col = 0, .scope = "" });
    try g.addSymbol(.{ .id = 1, .name = "new", .kind = .method, .file_id = 0, .line = 2, .col = 0, .scope = "" });

    try std.testing.expectEqual(@as(usize, 1), g.symbolCount());
    const sym = g.getSymbol(1).?;
    try std.testing.expectEqualStrings("new", sym.name);
    try std.testing.expectEqual(SymbolKind.method, sym.kind);
}

test "empty graph queries return null/empty/zero" {
    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();

    try std.testing.expectEqual(@as(?Symbol, null), g.getSymbol(999));
    try std.testing.expectEqual(@as(?File, null), g.getFile(999));
    try std.testing.expectEqual(@as(?Commit, null), g.getCommit(999));
    try std.testing.expectEqual(@as(usize, 0), g.outEdges(999).len);
    try std.testing.expectEqual(@as(usize, 0), g.inEdges(999).len);
    try std.testing.expectEqual(@as(usize, 0), g.outDegree(999));
    try std.testing.expectEqual(@as(usize, 0), g.symbolCount());
    try std.testing.expectEqual(@as(usize, 0), g.edgeCount());
}

// ── Edge case tests ─────────────────────────────────────────────────────────

test "add edge to nonexistent nodes — no symbols required" {
    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();

    // Edges can exist between node IDs that have no corresponding Symbol entry
    try g.addEdge(.{ .src = 100, .dst = 200, .kind = .calls });
    try std.testing.expectEqual(@as(usize, 1), g.edgeCount());
    try std.testing.expectEqual(@as(usize, 1), g.outDegree(100));
    // But the symbols themselves don't exist
    try std.testing.expectEqual(@as(?Symbol, null), g.getSymbol(100));
    try std.testing.expectEqual(@as(?Symbol, null), g.getSymbol(200));
}

test "self-loop edge — src equals dst" {
    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();

    try g.addEdge(.{ .src = 1, .dst = 1, .kind = .references });

    // out_edges[1] and in_edges[1] should both contain the same edge
    const out = g.outEdges(1);
    const in = g.inEdges(1);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqual(@as(usize, 1), in.len);
    try std.testing.expectEqual(@as(u64, 1), out[0].src);
    try std.testing.expectEqual(@as(u64, 1), out[0].dst);
    try std.testing.expectEqual(@as(u64, 1), in[0].src);
    try std.testing.expectEqual(@as(u64, 1), in[0].dst);
    try std.testing.expectEqual(@as(usize, 1), g.edgeCount());
}

test "multiple edges between same nodes with different kinds" {
    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();

    try g.addEdge(.{ .src = 1, .dst = 2, .kind = .calls });
    try g.addEdge(.{ .src = 1, .dst = 2, .kind = .references });
    try g.addEdge(.{ .src = 1, .dst = 2, .kind = .imports });

    try std.testing.expectEqual(@as(usize, 3), g.outDegree(1));
    try std.testing.expectEqual(@as(usize, 3), g.edgeCount());

    const out = g.outEdges(1);
    try std.testing.expectEqual(EdgeKind.calls, out[0].kind);
    try std.testing.expectEqual(EdgeKind.references, out[1].kind);
    try std.testing.expectEqual(EdgeKind.imports, out[2].kind);
}

test "duplicate edges (same src, dst, kind) accumulate" {
    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();

    try g.addEdge(.{ .src = 1, .dst = 2, .kind = .calls, .weight = 1.0 });
    try g.addEdge(.{ .src = 1, .dst = 2, .kind = .calls, .weight = 2.0 });

    // Both edges are stored (addEdge does not deduplicate)
    try std.testing.expectEqual(@as(usize, 2), g.outDegree(1));
    try std.testing.expectEqual(@as(usize, 2), g.edgeCount());
}

test "very large symbol ID — u64 max" {
    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();

    const max_id = std.math.maxInt(u64);
    try g.addSymbol(.{ .id = max_id, .name = "max_sym", .kind = .constant, .file_id = 0, .line = 0, .col = 0, .scope = "" });

    const sym = g.getSymbol(max_id).?;
    try std.testing.expectEqualStrings("max_sym", sym.name);
    try std.testing.expectEqual(max_id, sym.id);
}

test "symbol with id zero" {
    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();

    try g.addSymbol(.{ .id = 0, .name = "zero", .kind = .function, .file_id = 0, .line = 0, .col = 0, .scope = "" });

    const sym = g.getSymbol(0).?;
    try std.testing.expectEqualStrings("zero", sym.name);
    try std.testing.expectEqual(@as(u64, 0), sym.id);
}

test "add many symbols (150) and verify count" {
    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();

    for (0..150) |i| {
        try g.addSymbol(.{
            .id = @intCast(i),
            .name = "sym",
            .kind = .function,
            .file_id = 0,
            .line = @intCast(i),
            .col = 0,
            .scope = "",
        });
    }

    try std.testing.expectEqual(@as(usize, 150), g.symbolCount());

    // Spot-check a few
    try std.testing.expect(g.getSymbol(0) != null);
    try std.testing.expect(g.getSymbol(74) != null);
    try std.testing.expect(g.getSymbol(149) != null);
    try std.testing.expect(g.getSymbol(150) == null);
}

test "add many edges (200) and verify count" {
    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();

    for (0..200) |i| {
        try g.addEdge(.{
            .src = @intCast(i),
            .dst = @as(u64, @intCast(i)) + 1,
            .kind = .calls,
        });
    }

    try std.testing.expectEqual(@as(usize, 200), g.edgeCount());
}

test "overwrite symbol preserves new data completely" {
    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();

    try g.addSymbol(.{ .id = 5, .name = "original", .kind = .function, .file_id = 1, .line = 10, .col = 5, .scope = "mod_a" });
    try g.addSymbol(.{ .id = 5, .name = "replaced", .kind = .class, .file_id = 2, .line = 20, .col = 10, .scope = "mod_b" });

    const sym = g.getSymbol(5).?;
    try std.testing.expectEqualStrings("replaced", sym.name);
    try std.testing.expectEqual(SymbolKind.class, sym.kind);
    try std.testing.expectEqual(@as(u32, 2), sym.file_id);
    try std.testing.expectEqual(@as(u32, 20), sym.line);
    try std.testing.expectEqual(@as(u16, 10), sym.col);
    try std.testing.expectEqualStrings("mod_b", sym.scope);
}

test "symbol with empty name and scope" {
    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();

    try g.addSymbol(.{ .id = 1, .name = "", .kind = .variable, .file_id = 0, .line = 0, .col = 0, .scope = "" });

    const sym = g.getSymbol(1).?;
    try std.testing.expectEqualStrings("", sym.name);
    try std.testing.expectEqualStrings("", sym.scope);
}

test "file with empty path" {
    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();

    try g.addFile(.{ .id = 1, .path = "", .language = .unknown, .last_modified = 0, .hash = [_]u8{0} ** 32 });

    const f = g.getFile(1).?;
    try std.testing.expectEqualStrings("", f.path);
}

test "commit with empty author and message" {
    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();

    try g.addCommit(.{ .id = 1, .hash = [_]u8{'0'} ** 40, .timestamp = 0, .author = "", .message = "" });

    const c = g.getCommit(1).?;
    try std.testing.expectEqualStrings("", c.author);
    try std.testing.expectEqualStrings("", c.message);
}

test "overwrite file preserves new data" {
    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();

    try g.addFile(.{ .id = 1, .path = "old.zig", .language = .zig, .last_modified = 100, .hash = [_]u8{0} ** 32 });
    try g.addFile(.{ .id = 1, .path = "new.ts", .language = .typescript, .last_modified = 200, .hash = [_]u8{1} ** 32 });

    const f = g.getFile(1).?;
    try std.testing.expectEqualStrings("new.ts", f.path);
    try std.testing.expectEqual(Language.typescript, f.language);
    try std.testing.expectEqual(@as(i64, 200), f.last_modified);
}

test "overwrite commit preserves new data" {
    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();

    try g.addCommit(.{ .id = 1, .hash = [_]u8{'a'} ** 40, .timestamp = 100, .author = "alice", .message = "first" });
    try g.addCommit(.{ .id = 1, .hash = [_]u8{'b'} ** 40, .timestamp = 200, .author = "bob", .message = "second" });

    const c = g.getCommit(1).?;
    try std.testing.expectEqualStrings("bob", c.author);
    try std.testing.expectEqualStrings("second", c.message);
    try std.testing.expectEqual(@as(i64, 200), c.timestamp);
}

test "edges with max u64 node IDs" {
    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();

    const max = std.math.maxInt(u64);
    try g.addEdge(.{ .src = max, .dst = max - 1, .kind = .calls });

    try std.testing.expectEqual(@as(usize, 1), g.outDegree(max));
    const out = g.outEdges(max);
    try std.testing.expectEqual(max - 1, out[0].dst);
}

test "inEdges returns empty for node with only out-edges" {
    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();

    try g.addEdge(.{ .src = 1, .dst = 2, .kind = .calls });

    // Node 1 has out-edges but no in-edges
    try std.testing.expectEqual(@as(usize, 0), g.inEdges(1).len);
    // Node 2 has in-edges but no out-edges
    try std.testing.expectEqual(@as(usize, 0), g.outEdges(2).len);
}

test "edge with zero weight" {
    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();

    try g.addEdge(.{ .src = 1, .dst = 2, .kind = .calls, .weight = 0.0 });

    const out = g.outEdges(1);
    try std.testing.expectEqual(@as(f32, 0.0), out[0].weight);
}

test "edge with negative weight" {
    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();

    try g.addEdge(.{ .src = 1, .dst = 2, .kind = .calls, .weight = -5.0 });

    const out = g.outEdges(1);
    try std.testing.expectEqual(@as(f32, -5.0), out[0].weight);
}

test "graph with chain topology — verify traversal" {
    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();

    // Chain: 1 → 2 → 3 → 4 → 5
    try g.addEdge(.{ .src = 1, .dst = 2, .kind = .calls });
    try g.addEdge(.{ .src = 2, .dst = 3, .kind = .calls });
    try g.addEdge(.{ .src = 3, .dst = 4, .kind = .calls });
    try g.addEdge(.{ .src = 4, .dst = 5, .kind = .calls });

    try std.testing.expectEqual(@as(usize, 4), g.edgeCount());
    try std.testing.expectEqual(@as(usize, 1), g.outDegree(1));
    try std.testing.expectEqual(@as(usize, 1), g.outDegree(4));
    try std.testing.expectEqual(@as(usize, 0), g.outDegree(5)); // terminal
    try std.testing.expectEqual(@as(usize, 0), g.inEdges(1).len); // root
    try std.testing.expectEqual(@as(usize, 1), g.inEdges(5).len); // terminal has one in-edge
}

test "bidirectional edges between two nodes" {
    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();

    try g.addEdge(.{ .src = 1, .dst = 2, .kind = .calls });
    try g.addEdge(.{ .src = 2, .dst = 1, .kind = .calls });

    try std.testing.expectEqual(@as(usize, 1), g.outDegree(1));
    try std.testing.expectEqual(@as(usize, 1), g.outDegree(2));
    try std.testing.expectEqual(@as(usize, 1), g.inEdges(1).len);
    try std.testing.expectEqual(@as(usize, 1), g.inEdges(2).len);
    try std.testing.expectEqual(@as(usize, 2), g.edgeCount());
}
