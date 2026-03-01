// CodeGraph DB — Write-Ahead Log (WAL)
//
// Append-only binary log for crash recovery. Every mutation to the
// CodeGraph is first written to the WAL before being applied in memory.
// On recovery, the WAL is replayed against an empty (or checkpoint) graph
// to restore the last consistent state.
//
// Record format (little-endian):
//   [op: u8] [payload...] [crc32: u32]
//
// Op types:
//   0x01 AddSymbol   — full Symbol record
//   0x02 AddFile     — full File record
//   0x03 AddCommit   — full Commit record
//   0x04 AddEdge     — full Edge record
//   0x05 FileInvalidate — file_id:u32 (marks file for re-ingestion)
//   0xFF Checkpoint  — snapshot marker (WAL can be truncated before this)

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

pub const OpType = enum(u8) {
    add_symbol = 0x01,
    add_file = 0x02,
    add_commit = 0x03,
    add_edge = 0x04,
    file_invalidate = 0x05,
    checkpoint = 0xFF,
};

pub const WalWriter = struct {
    buf: std.ArrayList(u8),
    alloc: std.mem.Allocator,
    crc_start: usize = 0,  // tracks start of current record's payload (per-instance, not global)

    pub fn init(alloc: std.mem.Allocator) WalWriter {
        return .{
            .buf = .empty,
            .alloc = alloc,
            .crc_start = 0,
        };
    }

    pub fn deinit(self: *WalWriter) void {
        self.buf.deinit(self.alloc);
    }

    /// Write a WAL record for adding a symbol.
    pub fn logAddSymbol(self: *WalWriter, sym: Symbol) !void {
        try self.beginRecord(.add_symbol);
        try self.writeU64(sym.id);
        try self.writeBytes(sym.name);
        try self.writeU8(@intFromEnum(sym.kind));
        try self.writeU32(sym.file_id);
        try self.writeU32(sym.line);
        try self.writeU16(sym.col);
        try self.writeBytes(sym.scope);
        try self.endRecord();
    }

    /// Write a WAL record for adding a file.
    pub fn logAddFile(self: *WalWriter, file: File) !void {
        try self.beginRecord(.add_file);
        try self.writeU32(file.id);
        try self.writeBytes(file.path);
        try self.writeU8(@intFromEnum(file.language));
        try self.writeI64(file.last_modified);
        try self.writeAll(&file.hash);
        try self.endRecord();
    }

    /// Write a WAL record for adding a commit.
    pub fn logAddCommit(self: *WalWriter, commit: Commit) !void {
        try self.beginRecord(.add_commit);
        try self.writeU32(commit.id);
        try self.writeAll(&commit.hash);
        try self.writeI64(commit.timestamp);
        try self.writeBytes(commit.author);
        try self.writeBytes(commit.message);
        try self.endRecord();
    }

    /// Write a WAL record for adding an edge.
    pub fn logAddEdge(self: *WalWriter, edge: Edge) !void {
        try self.beginRecord(.add_edge);
        try self.writeU64(edge.src);
        try self.writeU64(edge.dst);
        try self.writeU8(@intFromEnum(edge.kind));
        try self.writeAll(&std.mem.toBytes(edge.weight));
        try self.endRecord();
    }

    /// Write a FILE_INVALIDATE record (marks file for re-ingestion).
    pub fn logFileInvalidate(self: *WalWriter, file_id: u32) !void {
        try self.beginRecord(.file_invalidate);
        try self.writeU32(file_id);
        try self.endRecord();
    }

    /// Write a checkpoint marker. WAL can be truncated before this point.
    pub fn logCheckpoint(self: *WalWriter) !void {
        try self.beginRecord(.checkpoint);
        try self.endRecord();
    }

    /// Return the serialized WAL data.
    pub fn data(self: *const WalWriter) []const u8 {
        return self.buf.items;
    }

    /// Reset the WAL buffer (e.g. after flushing to disk).
    pub fn reset(self: *WalWriter) void {
        self.buf.clearRetainingCapacity();
    }


    // ── Internal helpers ────────────────────────────────────────────────

    fn beginRecord(self: *WalWriter, op: OpType) !void {
        try self.buf.append(self.alloc, @intFromEnum(op));
        self.crc_start = self.buf.items.len;
    }

    fn endRecord(self: *WalWriter) !void {
        const payload = self.buf.items[self.crc_start..];
        const crc = std.hash.crc.Crc32.hash(payload);
        try self.buf.appendSlice(self.alloc, &std.mem.toBytes(crc));
    }

    fn writeU8(self: *WalWriter, v: u8) !void {
        try self.buf.append(self.alloc, v);
    }

    fn writeU16(self: *WalWriter, v: u16) !void {
        try self.buf.appendSlice(self.alloc, &std.mem.toBytes(std.mem.nativeToLittle(u16, v)));
    }

    fn writeU32(self: *WalWriter, v: u32) !void {
        try self.buf.appendSlice(self.alloc, &std.mem.toBytes(std.mem.nativeToLittle(u32, v)));
    }

    fn writeU64(self: *WalWriter, v: u64) !void {
        try self.buf.appendSlice(self.alloc, &std.mem.toBytes(std.mem.nativeToLittle(u64, v)));
    }

    fn writeI64(self: *WalWriter, v: i64) !void {
        try self.buf.appendSlice(self.alloc, &std.mem.toBytes(std.mem.nativeToLittle(i64, v)));
    }

    fn writeAll(self: *WalWriter, bytes: []const u8) !void {
        try self.buf.appendSlice(self.alloc, bytes);
    }

    fn writeBytes(self: *WalWriter, bytes: []const u8) !void {
        try self.writeU32(@intCast(bytes.len));
        try self.buf.appendSlice(self.alloc, bytes);
    }
};

// ── Replay ──────────────────────────────────────────────────────────────────

/// Replay result contains the graph and metadata about the replay.
pub const ReplayResult = struct {
    records_applied: usize,
    checkpoints_seen: usize,
    invalidated_files: std.AutoHashMap(u32, void),

    pub fn deinit(self: *ReplayResult) void {
        self.invalidated_files.deinit();
    }
};

/// Replay WAL records into a CodeGraph. Returns replay metadata.
/// Skips records with invalid CRC (partial writes from crashes).
pub fn replay(wal_data: []const u8, g: *CodeGraph, alloc: std.mem.Allocator) !ReplayResult {
    var result = ReplayResult{
        .records_applied = 0,
        .checkpoints_seen = 0,
        .invalidated_files = std.AutoHashMap(u32, void).init(alloc),
    };
    errdefer result.invalidated_files.deinit();

    var pos: usize = 0;

    while (pos < wal_data.len) {
        const record_start = pos;
        const op_byte = wal_data[pos];
        pos += 1;

        const payload_start = pos;

        // Try to parse the record and find its end
        const parse_result = parseRecord(wal_data, pos, op_byte) catch {
            // Corrupt or truncated record — stop replay (crash recovery)
            break;
        };
        pos = parse_result.end_pos;

        // Verify CRC
        if (pos + 4 > wal_data.len) break;
        const payload = wal_data[payload_start..pos];
        const expected_crc = std.mem.readInt(u32, wal_data[pos..][0..4], .little);
        const actual_crc = std.hash.crc.Crc32.hash(payload);
        pos += 4;

        if (expected_crc != actual_crc) {
            // CRC mismatch — truncated/corrupt, stop replay
            _ = record_start;
            break;
        }

        // Apply the parsed record
        switch (parse_result.action) {
            .add_symbol => |sym| try g.addSymbol(sym),
            .add_file => |f| try g.addFile(f),
            .add_commit => |c| try g.addCommit(c),
            .add_edge => |e| try g.addEdge(e),
            .file_invalidate => |fid| try result.invalidated_files.put(fid, {}),
            .checkpoint => result.checkpoints_seen += 1,
        }

        result.records_applied += 1;
    }

    return result;
}

const ParsedAction = union(enum) {
    add_symbol: Symbol,
    add_file: File,
    add_commit: Commit,
    add_edge: Edge,
    file_invalidate: u32,
    checkpoint: void,
};

const ParseResult = struct {
    end_pos: usize,
    action: ParsedAction,
};

fn parseRecord(data: []const u8, start: usize, op_byte: u8) !ParseResult {
    var pos = start;
    const op: OpType = std.meta.intToEnum(OpType, op_byte) catch return error.InvalidOp;

    switch (op) {
        .add_symbol => {
            const id = try readU64(data, &pos);
            const name = try readBytesView(data, &pos);
            if (pos >= data.len) return error.Truncated;
            const kind: SymbolKind = std.meta.intToEnum(SymbolKind, data[pos]) catch return error.InvalidOp;
            pos += 1;
            const file_id = try readU32(data, &pos);
            const line = try readU32(data, &pos);
            const col = try readU16(data, &pos);
            const scope = try readBytesView(data, &pos);

            return .{ .end_pos = pos, .action = .{ .add_symbol = .{
                .id = id,
                .name = name,
                .kind = kind,
                .file_id = file_id,
                .line = line,
                .col = col,
                .scope = scope,
            } } };
        },
        .add_file => {
            const id = try readU32(data, &pos);
            const path = try readBytesView(data, &pos);
            if (pos >= data.len) return error.Truncated;
            const language: Language = @enumFromInt(data[pos]);
            pos += 1;
            const last_modified = try readI64(data, &pos);
            if (pos + 32 > data.len) return error.Truncated;
            var hash: [32]u8 = undefined;
            @memcpy(&hash, data[pos..][0..32]);
            pos += 32;

            return .{ .end_pos = pos, .action = .{ .add_file = .{
                .id = id,
                .path = path,
                .language = language,
                .last_modified = last_modified,
                .hash = hash,
            } } };
        },
        .add_commit => {
            const id = try readU32(data, &pos);
            if (pos + 40 > data.len) return error.Truncated;
            var hash: [40]u8 = undefined;
            @memcpy(&hash, data[pos..][0..40]);
            pos += 40;
            const timestamp = try readI64(data, &pos);
            const author = try readBytesView(data, &pos);
            const message = try readBytesView(data, &pos);

            return .{ .end_pos = pos, .action = .{ .add_commit = .{
                .id = id,
                .hash = hash,
                .timestamp = timestamp,
                .author = author,
                .message = message,
            } } };
        },
        .add_edge => {
            const src = try readU64(data, &pos);
            const dst = try readU64(data, &pos);
            if (pos >= data.len) return error.Truncated;
            const kind: EdgeKind = @enumFromInt(data[pos]);
            pos += 1;
            if (pos + 4 > data.len) return error.Truncated;
            const weight: f32 = @bitCast(data[pos..][0..4].*);
            pos += 4;

            return .{ .end_pos = pos, .action = .{ .add_edge = .{
                .src = src,
                .dst = dst,
                .kind = kind,
                .weight = weight,
            } } };
        },
        .file_invalidate => {
            const file_id = try readU32(data, &pos);
            return .{ .end_pos = pos, .action = .{ .file_invalidate = file_id } };
        },
        .checkpoint => {
            return .{ .end_pos = pos, .action = .checkpoint };
        },
    }
}

// ── Read helpers ────────────────────────────────────────────────────────────

fn readU16(data: []const u8, pos: *usize) !u16 {
    if (pos.* + 2 > data.len) return error.Truncated;
    const v = std.mem.readInt(u16, data[pos.*..][0..2], .little);
    pos.* += 2;
    return v;
}

fn readU32(data: []const u8, pos: *usize) !u32 {
    if (pos.* + 4 > data.len) return error.Truncated;
    const v = std.mem.readInt(u32, data[pos.*..][0..4], .little);
    pos.* += 4;
    return v;
}

fn readU64(data: []const u8, pos: *usize) !u64 {
    if (pos.* + 8 > data.len) return error.Truncated;
    const v = std.mem.readInt(u64, data[pos.*..][0..8], .little);
    pos.* += 8;
    return v;
}

fn readI64(data: []const u8, pos: *usize) !i64 {
    if (pos.* + 8 > data.len) return error.Truncated;
    const v = std.mem.readInt(i64, data[pos.*..][0..8], .little);
    pos.* += 8;
    return v;
}

/// Zero-copy: returns a slice directly into the WAL data buffer.
/// Safe as long as the WAL data outlives the returned slice (true during replay).
fn readBytesView(data: []const u8, pos: *usize) ![]const u8 {
    const len = try readU32(data, pos);
    if (pos.* + len > data.len) return error.Truncated;
    const slice = data[pos.*..][0..len];
    pos.* += len;
    return slice;
}

// ── Tests ───────────────────────────────────────────────────────────────────

test "WAL write and replay AddSymbol" {
    var w = WalWriter.init(std.testing.allocator);
    defer w.deinit();

    try w.logAddSymbol(.{ .id = 1, .name = "foo", .kind = .function, .file_id = 10, .line = 42, .col = 8, .scope = "main" });

    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();
    var result = try replay(w.data(), &g, std.testing.allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.records_applied);
    const sym = g.getSymbol(1).?;
    try std.testing.expectEqualStrings("foo", sym.name);
    try std.testing.expectEqual(SymbolKind.function, sym.kind);
}

test "WAL write and replay AddFile" {
    var w = WalWriter.init(std.testing.allocator);
    defer w.deinit();

    try w.logAddFile(.{
        .id = 1,
        .path = "src/main.zig",
        .language = .zig,
        .last_modified = 1700000000,
        .hash = [_]u8{0xAB} ** 32,
    });

    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();
    var result = try replay(w.data(), &g, std.testing.allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.records_applied);
    const f = g.getFile(1).?;
    try std.testing.expectEqualStrings("src/main.zig", f.path);
}

test "WAL write and replay AddCommit" {
    var w = WalWriter.init(std.testing.allocator);
    defer w.deinit();

    try w.logAddCommit(.{
        .id = 1,
        .hash = "abc123def456abc123def456abc123def456abc1".*,
        .timestamp = 1700000000,
        .author = "alice",
        .message = "initial commit",
    });

    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();
    var result = try replay(w.data(), &g, std.testing.allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.records_applied);
    const c = g.getCommit(1).?;
    try std.testing.expectEqualStrings("alice", c.author);
}

test "WAL write and replay AddEdge" {
    var w = WalWriter.init(std.testing.allocator);
    defer w.deinit();

    try w.logAddEdge(.{ .src = 1, .dst = 2, .kind = .calls, .weight = 3.14 });

    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();
    var result = try replay(w.data(), &g, std.testing.allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.records_applied);
    const edges = g.outEdges(1);
    try std.testing.expectEqual(@as(usize, 1), edges.len);
    try std.testing.expectApproxEqAbs(@as(f32, 3.14), edges[0].weight, 1e-6);
}

test "WAL FileInvalidate tracked in result" {
    var w = WalWriter.init(std.testing.allocator);
    defer w.deinit();

    try w.logFileInvalidate(42);
    try w.logFileInvalidate(99);

    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();
    var result = try replay(w.data(), &g, std.testing.allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.records_applied);
    try std.testing.expect(result.invalidated_files.get(42) != null);
    try std.testing.expect(result.invalidated_files.get(99) != null);
}

test "WAL checkpoint counted" {
    var w = WalWriter.init(std.testing.allocator);
    defer w.deinit();

    try w.logAddSymbol(.{ .id = 1, .name = "a", .kind = .function, .file_id = 0, .line = 1, .col = 0, .scope = "" });
    try w.logCheckpoint();
    try w.logAddSymbol(.{ .id = 2, .name = "b", .kind = .method, .file_id = 0, .line = 2, .col = 0, .scope = "" });

    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();
    var result = try replay(w.data(), &g, std.testing.allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 3), result.records_applied);
    try std.testing.expectEqual(@as(usize, 1), result.checkpoints_seen);
    try std.testing.expectEqual(@as(usize, 2), g.symbolCount());
}

test "WAL multiple records replayed in order" {
    var w = WalWriter.init(std.testing.allocator);
    defer w.deinit();

    try w.logAddSymbol(.{ .id = 1, .name = "a", .kind = .function, .file_id = 0, .line = 1, .col = 0, .scope = "" });
    try w.logAddSymbol(.{ .id = 2, .name = "b", .kind = .method, .file_id = 0, .line = 2, .col = 0, .scope = "" });
    try w.logAddEdge(.{ .src = 1, .dst = 2, .kind = .calls });
    try w.logAddFile(.{ .id = 1, .path = "test.zig", .language = .zig, .last_modified = 0, .hash = [_]u8{0} ** 32 });

    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();
    var result = try replay(w.data(), &g, std.testing.allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 4), result.records_applied);
    try std.testing.expectEqual(@as(usize, 2), g.symbolCount());
    try std.testing.expectEqual(@as(usize, 1), g.edgeCount());
    try std.testing.expect(g.getFile(1) != null);
}

test "WAL corrupt CRC stops replay gracefully" {
    var w = WalWriter.init(std.testing.allocator);
    defer w.deinit();

    try w.logAddSymbol(.{ .id = 1, .name = "a", .kind = .function, .file_id = 0, .line = 1, .col = 0, .scope = "" });
    try w.logAddSymbol(.{ .id = 2, .name = "b", .kind = .method, .file_id = 0, .line = 2, .col = 0, .scope = "" });

    // Corrupt the last byte (CRC of second record)
    var data = try std.testing.allocator.alloc(u8, w.data().len);
    defer std.testing.allocator.free(data);
    @memcpy(data, w.data());
    data[data.len - 1] ^= 0xFF; // flip bits

    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();
    var result = try replay(data, &g, std.testing.allocator);
    defer result.deinit();

    // First record should succeed, second should be rejected
    try std.testing.expectEqual(@as(usize, 1), result.records_applied);
    try std.testing.expectEqual(@as(usize, 1), g.symbolCount());
}

test "WAL empty data replays zero records" {
    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();
    var result = try replay(&.{}, &g, std.testing.allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.records_applied);
}

test "WAL reset clears buffer" {
    var w = WalWriter.init(std.testing.allocator);
    defer w.deinit();

    try w.logAddSymbol(.{ .id = 1, .name = "a", .kind = .function, .file_id = 0, .line = 1, .col = 0, .scope = "" });
    try std.testing.expect(w.data().len > 0);

    w.reset();
    try std.testing.expectEqual(@as(usize, 0), w.data().len);
}

// ── Edge case tests ─────────────────────────────────────────────────────────

test "WAL single record replay" {
    var w = WalWriter.init(std.testing.allocator);
    defer w.deinit();

    try w.logAddFile(.{
        .id = 42,
        .path = "only_file.zig",
        .language = .zig,
        .last_modified = 999,
        .hash = [_]u8{0xCC} ** 32,
    });

    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();
    var result = try replay(w.data(), &g, std.testing.allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.records_applied);
    try std.testing.expectEqual(@as(usize, 0), result.checkpoints_seen);
    const f = g.getFile(42).?;
    try std.testing.expectEqualStrings("only_file.zig", f.path);
    try std.testing.expectEqual(@as(i64, 999), f.last_modified);
}

test "WAL truncated record stops replay gracefully" {
    var w = WalWriter.init(std.testing.allocator);
    defer w.deinit();

    try w.logAddSymbol(.{ .id = 1, .name = "good", .kind = .function, .file_id = 0, .line = 1, .col = 0, .scope = "" });
    try w.logAddSymbol(.{ .id = 2, .name = "truncated", .kind = .method, .file_id = 0, .line = 2, .col = 0, .scope = "" });

    // Truncate mid-way through the second record
    const full_data = w.data();
    const truncated_len = full_data.len - 10; // cut off last 10 bytes
    const data = try std.testing.allocator.alloc(u8, truncated_len);
    defer std.testing.allocator.free(data);
    @memcpy(data, full_data[0..truncated_len]);

    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();
    var result = try replay(data, &g, std.testing.allocator);
    defer result.deinit();

    // First record succeeds, second is truncated — stops
    try std.testing.expectEqual(@as(usize, 1), result.records_applied);
    try std.testing.expectEqual(@as(usize, 1), g.symbolCount());
    try std.testing.expectEqualStrings("good", g.getSymbol(1).?.name);
}

test "WAL multiple checkpoints in sequence" {
    var w = WalWriter.init(std.testing.allocator);
    defer w.deinit();

    try w.logCheckpoint();
    try w.logCheckpoint();
    try w.logCheckpoint();
    try w.logAddSymbol(.{ .id = 1, .name = "after_checkpoints", .kind = .function, .file_id = 0, .line = 1, .col = 0, .scope = "" });
    try w.logCheckpoint();

    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();
    var result = try replay(w.data(), &g, std.testing.allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 5), result.records_applied);
    try std.testing.expectEqual(@as(usize, 4), result.checkpoints_seen);
    try std.testing.expectEqual(@as(usize, 1), g.symbolCount());
}

test "WAL FILE_INVALIDATE for nonexistent file" {
    var w = WalWriter.init(std.testing.allocator);
    defer w.deinit();

    // Invalidate files that were never added to the graph
    try w.logFileInvalidate(99999);
    try w.logFileInvalidate(0);
    try w.logFileInvalidate(std.math.maxInt(u32));

    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();
    var result = try replay(w.data(), &g, std.testing.allocator);
    defer result.deinit();

    // All three should be applied (invalidation is just metadata tracking)
    try std.testing.expectEqual(@as(usize, 3), result.records_applied);
    try std.testing.expect(result.invalidated_files.get(99999) != null);
    try std.testing.expect(result.invalidated_files.get(0) != null);
    try std.testing.expect(result.invalidated_files.get(std.math.maxInt(u32)) != null);

    // Graph itself should be empty
    try std.testing.expectEqual(@as(usize, 0), g.symbolCount());
    try std.testing.expect(g.getFile(99999) == null);
}

test "WAL very long symbol names" {
    var w = WalWriter.init(std.testing.allocator);
    defer w.deinit();

    const long_name = "x" ** 5000;
    const long_scope = "y" ** 3000;

    try w.logAddSymbol(.{
        .id = 1,
        .name = long_name,
        .kind = .function,
        .file_id = 0,
        .line = 1,
        .col = 0,
        .scope = long_scope,
    });

    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();
    var result = try replay(w.data(), &g, std.testing.allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.records_applied);
    const sym = g.getSymbol(1).?;
    try std.testing.expectEqual(@as(usize, 5000), sym.name.len);
    try std.testing.expectEqual(@as(usize, 3000), sym.scope.len);
}

test "WAL replay order matters — add file then symbol referencing it" {
    var w = WalWriter.init(std.testing.allocator);
    defer w.deinit();

    // Add file first
    try w.logAddFile(.{
        .id = 10,
        .path = "src/lib.zig",
        .language = .zig,
        .last_modified = 1000,
        .hash = [_]u8{0} ** 32,
    });

    // Then add symbol referencing that file
    try w.logAddSymbol(.{
        .id = 1,
        .name = "init",
        .kind = .function,
        .file_id = 10,
        .line = 5,
        .col = 4,
        .scope = "lib",
    });

    // Then add edge referencing that symbol
    try w.logAddEdge(.{ .src = 1, .dst = 1, .kind = .references, .weight = 1.0 });

    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();
    var result = try replay(w.data(), &g, std.testing.allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 3), result.records_applied);
    // Verify all were added correctly
    const f = g.getFile(10).?;
    try std.testing.expectEqualStrings("src/lib.zig", f.path);
    const sym = g.getSymbol(1).?;
    try std.testing.expectEqual(@as(u32, 10), sym.file_id);
    try std.testing.expectEqual(@as(usize, 1), g.edgeCount());
}

test "WAL corrupt CRC in first record stops all replay" {
    var w = WalWriter.init(std.testing.allocator);
    defer w.deinit();

    try w.logAddSymbol(.{ .id = 1, .name = "a", .kind = .function, .file_id = 0, .line = 1, .col = 0, .scope = "" });

    var data = try std.testing.allocator.alloc(u8, w.data().len);
    defer std.testing.allocator.free(data);
    @memcpy(data, w.data());
    // Corrupt the CRC (last 4 bytes of the record)
    data[data.len - 1] ^= 0xFF;

    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();
    var result = try replay(data, &g, std.testing.allocator);
    defer result.deinit();

    // No records should be applied
    try std.testing.expectEqual(@as(usize, 0), result.records_applied);
    try std.testing.expectEqual(@as(usize, 0), g.symbolCount());
}

test "WAL replay with all record types interleaved" {
    var w = WalWriter.init(std.testing.allocator);
    defer w.deinit();

    try w.logAddFile(.{ .id = 1, .path = "f.zig", .language = .zig, .last_modified = 0, .hash = [_]u8{0} ** 32 });
    try w.logAddSymbol(.{ .id = 1, .name = "s1", .kind = .function, .file_id = 1, .line = 1, .col = 0, .scope = "" });
    try w.logAddCommit(.{ .id = 1, .hash = ("a" ** 40).*, .timestamp = 100, .author = "dev", .message = "msg" });
    try w.logAddEdge(.{ .src = 1, .dst = 1, .kind = .calls, .weight = 2.0 });
    try w.logFileInvalidate(1);
    try w.logCheckpoint();

    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();
    var result = try replay(w.data(), &g, std.testing.allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 6), result.records_applied);
    try std.testing.expectEqual(@as(usize, 1), result.checkpoints_seen);
    try std.testing.expect(result.invalidated_files.get(1) != null);
    try std.testing.expect(g.getFile(1) != null);
    try std.testing.expect(g.getSymbol(1) != null);
    try std.testing.expect(g.getCommit(1) != null);
    try std.testing.expectEqual(@as(usize, 1), g.edgeCount());
}

test "WAL write, reset, write produces only second batch" {
    var w = WalWriter.init(std.testing.allocator);
    defer w.deinit();

    try w.logAddSymbol(.{ .id = 1, .name = "first", .kind = .function, .file_id = 0, .line = 1, .col = 0, .scope = "" });
    w.reset();

    try w.logAddSymbol(.{ .id = 2, .name = "second", .kind = .method, .file_id = 0, .line = 2, .col = 0, .scope = "" });

    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();
    var result = try replay(w.data(), &g, std.testing.allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.records_applied);
    try std.testing.expect(g.getSymbol(1) == null); // first was reset away
    try std.testing.expectEqualStrings("second", g.getSymbol(2).?.name);
}

test "WAL single byte of garbage produces zero records" {
    const garbage = [_]u8{0x42};
    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();
    var result = try replay(&garbage, &g, std.testing.allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.records_applied);
}
