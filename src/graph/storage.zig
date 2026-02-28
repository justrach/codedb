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
    // Serialize to in-memory buffer, then write all at once
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc_for_save);
    try serialize(g, buf.writer(alloc_for_save));
    try file.writeAll(buf.items);
}

/// Temporary allocator for saveToFile — uses page_allocator since we
/// don't have access to a caller-provided allocator in the current API.
const alloc_for_save = std.heap.page_allocator;

/// Load a CodeGraph from a file path.
pub fn loadFromFile(path: []const u8, alloc: std.mem.Allocator) !CodeGraph {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    // Read entire file into memory, then deserialize
    const contents = try file.readToEndAlloc(alloc, 256 * 1024 * 1024); // 256MB max
    defer alloc.free(contents);
    var stream = std.io.fixedBufferStream(contents);
    return deserialize(stream.reader(), alloc);
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

// ── Edge case tests ─────────────────────────────────────────────────────────

test "round-trip empty graph has zero counts" {
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
    try std.testing.expectEqual(@as(usize, 0), g2.files.count());
    try std.testing.expectEqual(@as(usize, 0), g2.commits.count());
    // Verify queries on empty graph return null
    try std.testing.expect(g2.getSymbol(1) == null);
    try std.testing.expect(g2.getFile(1) == null);
    try std.testing.expect(g2.getCommit(1) == null);
}

test "round-trip with maximum-length strings (1000+ chars)" {
    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();

    const long_name = "A" ** 1200;
    const long_scope = "B" ** 1500;

    try g.addSymbol(.{
        .id = 1,
        .name = long_name,
        .kind = .function,
        .file_id = 1,
        .line = 1,
        .col = 0,
        .scope = long_scope,
    });

    const long_path = "src/" ++ "deep/" ** 200 ++ "file.zig";
    try g.addFile(.{
        .id = 1,
        .path = long_path,
        .language = .zig,
        .last_modified = 0,
        .hash = [_]u8{0} ** 32,
    });

    const long_author = "C" ** 1000;
    const long_message = "D" ** 2000;
    try g.addCommit(.{
        .id = 1,
        .hash = ("z" ** 40).*,
        .timestamp = 0,
        .author = long_author,
        .message = long_message,
    });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try serialize(&g, buf.writer(std.testing.allocator));

    var stream = std.io.fixedBufferStream(buf.items);
    var g2 = try deserialize(stream.reader(), std.testing.allocator);
    defer g2.deinit();

    const sym = g2.getSymbol(1).?;
    try std.testing.expectEqual(@as(usize, 1200), sym.name.len);
    try std.testing.expectEqualStrings(long_name, sym.name);
    try std.testing.expectEqual(@as(usize, 1500), sym.scope.len);
    try std.testing.expectEqualStrings(long_scope, sym.scope);

    const f = g2.getFile(1).?;
    try std.testing.expectEqualStrings(long_path, f.path);

    const c = g2.getCommit(1).?;
    try std.testing.expectEqualStrings(long_author, c.author);
    try std.testing.expectEqualStrings(long_message, c.message);
}

test "round-trip with special characters in strings (unicode, newlines)" {
    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();

    // Unicode, newlines, tabs, emoji
    const special_name = "fn_\xc3\xa9\xc3\xa0\xc3\xbc_\xe2\x9c\x93\n\ttab";
    const special_scope = "\xe4\xb8\xad\xe6\x96\x87::method\r\n";

    try g.addSymbol(.{
        .id = 1,
        .name = special_name,
        .kind = .class,
        .file_id = 1,
        .line = 1,
        .col = 0,
        .scope = special_scope,
    });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try serialize(&g, buf.writer(std.testing.allocator));

    var stream = std.io.fixedBufferStream(buf.items);
    var g2 = try deserialize(stream.reader(), std.testing.allocator);
    defer g2.deinit();

    const sym = g2.getSymbol(1).?;
    try std.testing.expectEqualStrings(special_name, sym.name);
    try std.testing.expectEqualStrings(special_scope, sym.scope);
}

test "round-trip with null bytes in strings" {
    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();

    const name_with_nulls = "hello\x00world\x00end";
    try g.addSymbol(.{
        .id = 1,
        .name = name_with_nulls,
        .kind = .variable,
        .file_id = 1,
        .line = 1,
        .col = 0,
        .scope = "scope\x00here",
    });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try serialize(&g, buf.writer(std.testing.allocator));

    var stream = std.io.fixedBufferStream(buf.items);
    var g2 = try deserialize(stream.reader(), std.testing.allocator);
    defer g2.deinit();

    const sym = g2.getSymbol(1).?;
    try std.testing.expectEqualStrings(name_with_nulls, sym.name);
    try std.testing.expectEqualStrings("scope\x00here", sym.scope);
}

test "truncated data returns error (incomplete header)" {
    // Only 6 bytes — not enough for the full 24-byte header
    const truncated = "CGDB\x01\x00";
    var stream = std.io.fixedBufferStream(truncated);
    const result = deserialize(stream.reader(), std.testing.allocator);
    try std.testing.expectError(error.EndOfStream, result);
}

test "truncated data in symbol section" {
    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();

    try g.addSymbol(.{ .id = 1, .name = "foo", .kind = .function, .file_id = 10, .line = 42, .col = 8, .scope = "main" });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try serialize(&g, buf.writer(std.testing.allocator));

    // Truncate partway through the symbol data (after header but before symbol ends)
    const truncated = buf.items[0..28]; // header is 24 bytes, only 4 bytes of symbol
    var stream = std.io.fixedBufferStream(truncated);
    const result = deserialize(stream.reader(), std.testing.allocator);
    try std.testing.expectError(error.EndOfStream, result);
}

test "corrupted magic bytes with valid length" {
    // Construct a buffer with wrong magic but otherwise valid header
    var buf: [24]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const w = stream.writer();
    w.writeAll("XGDB") catch unreachable; // wrong magic
    w.writeInt(u32, FORMAT_VERSION, .little) catch unreachable;
    w.writeInt(u32, 0, .little) catch unreachable; // 0 symbols
    w.writeInt(u32, 0, .little) catch unreachable; // 0 files
    w.writeInt(u32, 0, .little) catch unreachable; // 0 commits
    w.writeInt(u32, 0, .little) catch unreachable; // 0 edges

    stream.pos = 0;
    const result = deserialize(stream.reader(), std.testing.allocator);
    try std.testing.expectError(error.InvalidFormat, result);
}

test "version number 0 rejected" {
    var buf: [24]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const w = stream.writer();
    w.writeAll(&MAGIC) catch unreachable;
    w.writeInt(u32, 0, .little) catch unreachable; // version 0
    w.writeInt(u32, 0, .little) catch unreachable;
    w.writeInt(u32, 0, .little) catch unreachable;
    w.writeInt(u32, 0, .little) catch unreachable;
    w.writeInt(u32, 0, .little) catch unreachable;

    stream.pos = 0;
    const result = deserialize(stream.reader(), std.testing.allocator);
    try std.testing.expectError(error.UnsupportedVersion, result);
}

test "version number 255 rejected" {
    var buf: [24]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const w = stream.writer();
    w.writeAll(&MAGIC) catch unreachable;
    w.writeInt(u32, 255, .little) catch unreachable; // version 255
    w.writeInt(u32, 0, .little) catch unreachable;
    w.writeInt(u32, 0, .little) catch unreachable;
    w.writeInt(u32, 0, .little) catch unreachable;
    w.writeInt(u32, 0, .little) catch unreachable;

    stream.pos = 0;
    const result = deserialize(stream.reader(), std.testing.allocator);
    try std.testing.expectError(error.UnsupportedVersion, result);
}

test "round-trip graph with many edges (50+)" {
    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();

    // Add symbols first
    for (0..60) |i| {
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

    // Add 59 edges: 0->1, 1->2, ..., 58->59
    for (0..59) |i| {
        try g.addEdge(.{
            .src = @intCast(i),
            .dst = @intCast(i + 1),
            .kind = .calls,
            .weight = @floatFromInt(i),
        });
    }

    try std.testing.expectEqual(@as(usize, 59), g.edgeCount());

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try serialize(&g, buf.writer(std.testing.allocator));

    var stream = std.io.fixedBufferStream(buf.items);
    var g2 = try deserialize(stream.reader(), std.testing.allocator);
    defer g2.deinit();

    try std.testing.expectEqual(@as(usize, 60), g2.symbolCount());
    try std.testing.expectEqual(@as(usize, 59), g2.edgeCount());

    // Verify first and last edge weights
    const out0 = g2.outEdges(0);
    try std.testing.expectEqual(@as(usize, 1), out0.len);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), out0[0].weight, 1e-6);

    const out58 = g2.outEdges(58);
    try std.testing.expectEqual(@as(usize, 1), out58.len);
    try std.testing.expectApproxEqAbs(@as(f32, 58.0), out58[0].weight, 1e-6);
}

test "symbols with extreme line/col values (u32 max, u16 max)" {
    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();

    try g.addSymbol(.{
        .id = 1,
        .name = "extreme",
        .kind = .function,
        .file_id = std.math.maxInt(u32),
        .line = std.math.maxInt(u32),
        .col = std.math.maxInt(u16),
        .scope = "max_scope",
    });

    try g.addSymbol(.{
        .id = 2,
        .name = "zero",
        .kind = .method,
        .file_id = 0,
        .line = 0,
        .col = 0,
        .scope = "",
    });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try serialize(&g, buf.writer(std.testing.allocator));

    var stream = std.io.fixedBufferStream(buf.items);
    var g2 = try deserialize(stream.reader(), std.testing.allocator);
    defer g2.deinit();

    const s1 = g2.getSymbol(1).?;
    try std.testing.expectEqual(std.math.maxInt(u32), s1.file_id);
    try std.testing.expectEqual(std.math.maxInt(u32), s1.line);
    try std.testing.expectEqual(std.math.maxInt(u16), s1.col);

    const s2 = g2.getSymbol(2).?;
    try std.testing.expectEqual(@as(u32, 0), s2.file_id);
    try std.testing.expectEqual(@as(u32, 0), s2.line);
    try std.testing.expectEqual(@as(u16, 0), s2.col);
}

test "round-trip with all edge kinds and special weights" {
    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();

    try g.addEdge(.{ .src = 1, .dst = 2, .kind = .calls, .weight = 0.0 });
    try g.addEdge(.{ .src = 2, .dst = 3, .kind = .imports, .weight = std.math.inf(f32) });
    try g.addEdge(.{ .src = 3, .dst = 4, .kind = .defines, .weight = -1.0 });
    try g.addEdge(.{ .src = 4, .dst = 5, .kind = .modifies, .weight = std.math.floatMin(f32) });
    try g.addEdge(.{ .src = 5, .dst = 6, .kind = .references, .weight = std.math.floatMax(f32) });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try serialize(&g, buf.writer(std.testing.allocator));

    var stream = std.io.fixedBufferStream(buf.items);
    var g2 = try deserialize(stream.reader(), std.testing.allocator);
    defer g2.deinit();

    try std.testing.expectEqual(@as(usize, 5), g2.edgeCount());

    const e1 = g2.outEdges(1);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), e1[0].weight, 1e-6);
    try std.testing.expectEqual(EdgeKind.calls, e1[0].kind);

    const e2 = g2.outEdges(2);
    try std.testing.expect(std.math.isInf(e2[0].weight));

    const e3 = g2.outEdges(3);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), e3[0].weight, 1e-6);
    try std.testing.expectEqual(EdgeKind.defines, e3[0].kind);

    const e5 = g2.outEdges(5);
    try std.testing.expectEqual(EdgeKind.references, e5[0].kind);
}

test "round-trip with all SymbolKind variants" {
    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();

    const kinds = [_]SymbolKind{ .function, .method, .class, .variable, .constant, .type_def, .interface, .module };
    for (kinds, 0..) |kind, i| {
        try g.addSymbol(.{
            .id = @intCast(i + 1),
            .name = "sym",
            .kind = kind,
            .file_id = 0,
            .line = 0,
            .col = 0,
            .scope = "",
        });
    }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try serialize(&g, buf.writer(std.testing.allocator));

    var stream = std.io.fixedBufferStream(buf.items);
    var g2 = try deserialize(stream.reader(), std.testing.allocator);
    defer g2.deinit();

    try std.testing.expectEqual(@as(usize, 8), g2.symbolCount());
    for (kinds, 0..) |kind, i| {
        const sym = g2.getSymbol(@intCast(i + 1)).?;
        try std.testing.expectEqual(kind, sym.kind);
    }
}

test "round-trip with all Language variants" {
    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();

    const langs = [_]Language{ .typescript, .javascript, .zig, .python, .unknown };
    for (langs, 0..) |lang, i| {
        try g.addFile(.{
            .id = @intCast(i + 1),
            .path = "file",
            .language = lang,
            .last_modified = 0,
            .hash = [_]u8{0} ** 32,
        });
    }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try serialize(&g, buf.writer(std.testing.allocator));

    var stream = std.io.fixedBufferStream(buf.items);
    var g2 = try deserialize(stream.reader(), std.testing.allocator);
    defer g2.deinit();

    for (langs, 0..) |lang, i| {
        const f = g2.getFile(@intCast(i + 1)).?;
        try std.testing.expectEqual(lang, f.language);
    }
}

test "round-trip with extreme timestamps" {
    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();

    try g.addFile(.{
        .id = 1,
        .path = "a.zig",
        .language = .zig,
        .last_modified = std.math.maxInt(i64),
        .hash = [_]u8{0xFF} ** 32,
    });
    try g.addFile(.{
        .id = 2,
        .path = "b.zig",
        .language = .zig,
        .last_modified = std.math.minInt(i64),
        .hash = [_]u8{0} ** 32,
    });
    try g.addCommit(.{
        .id = 1,
        .hash = ("0" ** 40).*,
        .timestamp = std.math.maxInt(i64),
        .author = "",
        .message = "",
    });
    try g.addCommit(.{
        .id = 2,
        .hash = ("F" ** 40).*,
        .timestamp = std.math.minInt(i64),
        .author = "",
        .message = "",
    });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try serialize(&g, buf.writer(std.testing.allocator));

    var stream = std.io.fixedBufferStream(buf.items);
    var g2 = try deserialize(stream.reader(), std.testing.allocator);
    defer g2.deinit();

    try std.testing.expectEqual(std.math.maxInt(i64), g2.getFile(1).?.last_modified);
    try std.testing.expectEqual(std.math.minInt(i64), g2.getFile(2).?.last_modified);
    try std.testing.expectEqual(std.math.maxInt(i64), g2.getCommit(1).?.timestamp);
    try std.testing.expectEqual(std.math.minInt(i64), g2.getCommit(2).?.timestamp);
}

test "round-trip with empty strings everywhere" {
    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();

    try g.addSymbol(.{ .id = 1, .name = "", .kind = .function, .file_id = 0, .line = 0, .col = 0, .scope = "" });
    try g.addFile(.{ .id = 1, .path = "", .language = .unknown, .last_modified = 0, .hash = [_]u8{0} ** 32 });
    try g.addCommit(.{ .id = 1, .hash = (" " ** 40).*, .timestamp = 0, .author = "", .message = "" });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try serialize(&g, buf.writer(std.testing.allocator));

    var stream = std.io.fixedBufferStream(buf.items);
    var g2 = try deserialize(stream.reader(), std.testing.allocator);
    defer g2.deinit();

    try std.testing.expectEqualStrings("", g2.getSymbol(1).?.name);
    try std.testing.expectEqualStrings("", g2.getSymbol(1).?.scope);
    try std.testing.expectEqualStrings("", g2.getFile(1).?.path);
    try std.testing.expectEqualStrings("", g2.getCommit(1).?.author);
    try std.testing.expectEqualStrings("", g2.getCommit(1).?.message);
}
