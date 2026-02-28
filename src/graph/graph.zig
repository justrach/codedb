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
