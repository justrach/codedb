// CodeGraph DB — on-disk binary format
//
// Adjacency-first layout for fast graph loading:
//
//   [Header]
//   [Symbol blocks...]
//   [File blocks...]
//   [Commit blocks...]
//   [Edge blocks...]
//
// All multi-byte integers are little-endian.
// Variable-length strings are length-prefixed (u32 length + bytes).
// Format version is checked on load to reject incompatible files.

const std = @import("std");
const types = @import("types.zig");
const graph_mod = @import("graph.zig");
const CodeGraph = graph_mod.CodeGraph;
const Symbol = types.Symbol;
const File = types.File;
const Commit = types.Commit;
const Edge = types.Edge;
const SymbolKind = types.SymbolKind;
const EdgeKind = types.EdgeKind;
const Language = types.Language;

pub const FORMAT_VERSION: u32 = 1;
pub const MAGIC: [4]u8 = "CGDB".*;

// ── Serialization ───────────────────────────────────────────────────────────

/// Serialize a CodeGraph to a writer (file, buffer, etc.).
pub fn serialize(g: *const CodeGraph, writer: anytype) !void {
    // Header
    try writer.writeAll(&MAGIC);
    try writer.writeInt(u32, FORMAT_VERSION, .little);
    try writer.writeInt(u32, @intCast(g.symbolCount()), .little);
    try writer.writeInt(u32, @intCast(g.files.count()), .little);
    try writer.writeInt(u32, @intCast(g.commits.count()), .little);
    try writer.writeInt(u32, @intCast(g.edgeCount()), .little);

    // Symbols
    var sym_it = g.symbols.iterator();
    while (sym_it.next()) |entry| {
        const sym = entry.value_ptr.*;
        try writer.writeInt(u64, sym.id, .little);
        try writeBytes(writer, sym.name);
        try writer.writeByte(@intFromEnum(sym.kind));
        try writer.writeInt(u32, sym.file_id, .little);
        try writer.writeInt(u32, sym.line, .little);
        try writer.writeInt(u16, sym.col, .little);
        try writeBytes(writer, sym.scope);
    }

    // Files
    var file_it = g.files.iterator();
    while (file_it.next()) |entry| {
        const f = entry.value_ptr.*;
        try writer.writeInt(u32, f.id, .little);
        try writeBytes(writer, f.path);
        try writer.writeByte(@intFromEnum(f.language));
        try writer.writeInt(i64, f.last_modified, .little);
        try writer.writeAll(&f.hash);
    }

    // Commits
    var commit_it = g.commits.iterator();
    while (commit_it.next()) |entry| {
        const c = entry.value_ptr.*;
        try writer.writeInt(u32, c.id, .little);
        try writer.writeAll(&c.hash);
        try writer.writeInt(i64, c.timestamp, .little);
        try writeBytes(writer, c.author);
        try writeBytes(writer, c.message);
    }

    // Edges (from out_edges adjacency lists)
    var edge_it = g.out_edges.iterator();
    while (edge_it.next()) |entry| {
        for (entry.value_ptr.items) |edge| {
            try writer.writeInt(u64, edge.src, .little);
            try writer.writeInt(u64, edge.dst, .little);
            try writer.writeByte(@intFromEnum(edge.kind));
            try writer.writeAll(&std.mem.toBytes(edge.weight));
        }
    }
}

/// Deserialize a CodeGraph from a reader.
pub fn deserialize(reader: anytype, alloc: std.mem.Allocator) !CodeGraph {
    // Header
    var magic: [4]u8 = undefined;
    try reader.readNoEof(&magic);
    if (!std.mem.eql(u8, &magic, &MAGIC)) return error.InvalidFormat;

    const version = try reader.readInt(u32, .little);
    if (version != FORMAT_VERSION) return error.UnsupportedVersion;

    const num_symbols = try reader.readInt(u32, .little);
    const num_files = try reader.readInt(u32, .little);
    const num_commits = try reader.readInt(u32, .little);
    const num_edges = try reader.readInt(u32, .little);

    var g = CodeGraph.init(alloc);
    errdefer g.deinit();

    // Symbols
    for (0..num_symbols) |_| {
        const id = try reader.readInt(u64, .little);
        const name = try readBytes(reader, alloc);
        defer alloc.free(name);
        const kind: SymbolKind = @enumFromInt(try reader.readByte());
        const file_id = try reader.readInt(u32, .little);
        const line = try reader.readInt(u32, .little);
        const col = try reader.readInt(u16, .little);
        const scope = try readBytes(reader, alloc);
        defer alloc.free(scope);

        try g.addSymbol(.{
            .id = id,
            .name = name,
            .kind = kind,
            .file_id = file_id,
            .line = line,
            .col = col,
            .scope = scope,
        });
    }

    // Files
    for (0..num_files) |_| {
        const id = try reader.readInt(u32, .little);
        const path = try readBytes(reader, alloc);
        defer alloc.free(path);
        const language: Language = @enumFromInt(try reader.readByte());
        const last_modified = try reader.readInt(i64, .little);
        var hash: [32]u8 = undefined;
        try reader.readNoEof(&hash);

        try g.addFile(.{
            .id = id,
            .path = path,
            .language = language,
            .last_modified = last_modified,
            .hash = hash,
        });
    }

    // Commits
    for (0..num_commits) |_| {
        const id = try reader.readInt(u32, .little);
        var hash: [40]u8 = undefined;
        try reader.readNoEof(&hash);
        const timestamp = try reader.readInt(i64, .little);
        const author = try readBytes(reader, alloc);
        defer alloc.free(author);
        const message = try readBytes(reader, alloc);
        defer alloc.free(message);

        try g.addCommit(.{
            .id = id,
            .hash = hash,
            .timestamp = timestamp,
            .author = author,
            .message = message,
        });
    }

    // Edges
    for (0..num_edges) |_| {
        const src = try reader.readInt(u64, .little);
        const dst = try reader.readInt(u64, .little);
        const kind: EdgeKind = @enumFromInt(try reader.readByte());
        var weight_bytes: [4]u8 = undefined;
        try reader.readNoEof(&weight_bytes);
        const weight: f32 = @bitCast(weight_bytes);

        try g.addEdge(.{
            .src = src,
            .dst = dst,
            .kind = kind,
            .weight = weight,
        });
    }

    return g;
}

// ── File I/O convenience ────────────────────────────────────────────────────

/// Save a CodeGraph to a file path.
pub fn saveToFile(g: *const CodeGraph, path: []const u8) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    var bw = std.io.bufferedWriter(file.writer());
    try serialize(g, bw.writer());
    try bw.flush();
}

/// Load a CodeGraph from a file path.
pub fn loadFromFile(path: []const u8, alloc: std.mem.Allocator) !CodeGraph {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    var br = std.io.bufferedReader(file.reader());
    return deserialize(br.reader(), alloc);
}

// ── Helpers ─────────────────────────────────────────────────────────────────

fn writeBytes(writer: anytype, data: []const u8) !void {
    try writer.writeInt(u32, @intCast(data.len), .little);
    try writer.writeAll(data);
}

fn readBytes(reader: anytype, alloc: std.mem.Allocator) ![]u8 {
    const len = try reader.readInt(u32, .little);
    if (len > 10 * 1024 * 1024) return error.StringTooLarge; // 10MB sanity limit
    const buf = try alloc.alloc(u8, len);
    errdefer alloc.free(buf);
    try reader.readNoEof(buf);
    return buf;
}

// ── Tests ───────────────────────────────────────────────────────────────────

test "serialize and deserialize empty graph" {
    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try serialize(&g, buf.writer(std.testing.allocator));

    var stream = std.io.fixedBufferStream(buf.items);
    var g2 = try deserialize(stream.reader(), std.testing.allocator);
    defer g2.deinit();

    try std.testing.expectEqual(@as(usize, 0), g2.symbolCount());
    try std.testing.expectEqual(@as(usize, 0), g2.edgeCount());
}

test "round-trip symbols" {
    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();

    try g.addSymbol(.{ .id = 1, .name = "foo", .kind = .function, .file_id = 10, .line = 42, .col = 8, .scope = "main" });
    try g.addSymbol(.{ .id = 2, .name = "bar", .kind = .method, .file_id = 10, .line = 99, .col = 12, .scope = "MyClass" });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try serialize(&g, buf.writer(std.testing.allocator));

    var stream = std.io.fixedBufferStream(buf.items);
    var g2 = try deserialize(stream.reader(), std.testing.allocator);
    defer g2.deinit();

    try std.testing.expectEqual(@as(usize, 2), g2.symbolCount());
    const s1 = g2.getSymbol(1).?;
    try std.testing.expectEqualStrings("foo", s1.name);
    try std.testing.expectEqual(SymbolKind.function, s1.kind);
    try std.testing.expectEqual(@as(u32, 42), s1.line);
    try std.testing.expectEqualStrings("main", s1.scope);

    const s2 = g2.getSymbol(2).?;
    try std.testing.expectEqualStrings("bar", s2.name);
    try std.testing.expectEqualStrings("MyClass", s2.scope);
}

test "round-trip files" {
    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();

    try g.addFile(.{
        .id = 1,
        .path = "src/main.zig",
        .language = .zig,
        .last_modified = 1700000000,
        .hash = [_]u8{0xAB} ** 32,
    });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try serialize(&g, buf.writer(std.testing.allocator));

    var stream = std.io.fixedBufferStream(buf.items);
    var g2 = try deserialize(stream.reader(), std.testing.allocator);
    defer g2.deinit();

    const f = g2.getFile(1).?;
    try std.testing.expectEqualStrings("src/main.zig", f.path);
    try std.testing.expectEqual(Language.zig, f.language);
    try std.testing.expectEqual(@as(i64, 1700000000), f.last_modified);
    try std.testing.expectEqual(@as(u8, 0xAB), f.hash[0]);
}

test "round-trip commits" {
    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();

    try g.addCommit(.{
        .id = 1,
        .hash = "abc123def456abc123def456abc123def456abc1".*,
        .timestamp = 1700000000,
        .author = "alice",
        .message = "initial commit",
    });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try serialize(&g, buf.writer(std.testing.allocator));

    var stream = std.io.fixedBufferStream(buf.items);
    var g2 = try deserialize(stream.reader(), std.testing.allocator);
    defer g2.deinit();

    const c = g2.getCommit(1).?;
    try std.testing.expectEqualStrings("alice", c.author);
    try std.testing.expectEqualStrings("initial commit", c.message);
}

test "round-trip edges with weights" {
    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();

    try g.addEdge(.{ .src = 1, .dst = 2, .kind = .calls, .weight = 3.14 });
    try g.addEdge(.{ .src = 2, .dst = 3, .kind = .imports });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try serialize(&g, buf.writer(std.testing.allocator));

    var stream = std.io.fixedBufferStream(buf.items);
    var g2 = try deserialize(stream.reader(), std.testing.allocator);
    defer g2.deinit();

    try std.testing.expectEqual(@as(usize, 2), g2.edgeCount());

    const out1 = g2.outEdges(1);
    try std.testing.expectEqual(@as(usize, 1), out1.len);
    try std.testing.expectApproxEqAbs(@as(f32, 3.14), out1[0].weight, 1e-6);
    try std.testing.expectEqual(EdgeKind.calls, out1[0].kind);

    const out2 = g2.outEdges(2);
    try std.testing.expectEqual(@as(usize, 1), out2.len);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), out2[0].weight, 1e-6);

    // Bidirectional adjacency restored
    try std.testing.expectEqual(@as(usize, 1), g2.inEdges(2).len);
    try std.testing.expectEqual(@as(usize, 1), g2.inEdges(3).len);
}

test "invalid magic rejected" {
    const bad_data = "BADDxxxxxxxxxx";
    var stream = std.io.fixedBufferStream(bad_data);
    const result = deserialize(stream.reader(), std.testing.allocator);
    try std.testing.expectError(error.InvalidFormat, result);
}

test "unsupported version rejected" {
    var buf: [24]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const w = stream.writer();
    w.writeAll(&MAGIC) catch unreachable;
    w.writeInt(u32, 999, .little) catch unreachable; // bad version
    w.writeInt(u32, 0, .little) catch unreachable;
    w.writeInt(u32, 0, .little) catch unreachable;
    w.writeInt(u32, 0, .little) catch unreachable;
    w.writeInt(u32, 0, .little) catch unreachable;

    stream.pos = 0;
    const result = deserialize(stream.reader(), std.testing.allocator);
    try std.testing.expectError(error.UnsupportedVersion, result);
}

test "full graph round-trip" {
    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();

    try g.addSymbol(.{ .id = 1, .name = "main", .kind = .function, .file_id = 1, .line = 1, .col = 0, .scope = "" });
    try g.addSymbol(.{ .id = 2, .name = "helper", .kind = .function, .file_id = 1, .line = 20, .col = 0, .scope = "" });
    try g.addFile(.{ .id = 1, .path = "src/main.zig", .language = .zig, .last_modified = 1700000000, .hash = [_]u8{0} ** 32 });
    try g.addCommit(.{ .id = 1, .hash = ("a" ** 40).*, .timestamp = 1700000000, .author = "dev", .message = "init" });
    try g.addEdge(.{ .src = 1, .dst = 2, .kind = .calls, .weight = 2.5 });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try serialize(&g, buf.writer(std.testing.allocator));

    var stream = std.io.fixedBufferStream(buf.items);
    var g2 = try deserialize(stream.reader(), std.testing.allocator);
    defer g2.deinit();

    try std.testing.expectEqual(g.symbolCount(), g2.symbolCount());
    try std.testing.expectEqual(g.files.count(), g2.files.count());
    try std.testing.expectEqual(g.commits.count(), g2.commits.count());
    try std.testing.expectEqual(g.edgeCount(), g2.edgeCount());
}
