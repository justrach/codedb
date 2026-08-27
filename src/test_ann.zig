const std = @import("std");
const testing = std.testing;
const ann = @import("ann.zig");
const semantic_index = @import("semantic_index.zig");

test "ann: codedb uses the recall-gated 512D search profile" {
    try testing.expectEqual(@as(u32, 48), ann.default_ef_search);
    try testing.expectEqual(@as(usize, 2), ann.default_rerank_multiplier);
}

test "ann: OpenPuffer wrapper finds the exact nearest vector" {
    var index = ann.Index.init(testing.allocator, 4, .{ .seed = 7 });
    defer index.deinit();
    _ = try index.insert(&.{ 1, 0, 0, 0 });
    _ = try index.insert(&.{ 0, 1, 0, 0 });
    _ = try index.insert(&.{ 0, 0, 1, 0 });

    const results = try index.search(&.{ 0.99, 0.01, 0, 0 }, 2, testing.allocator);
    defer testing.allocator.free(results);
    try testing.expectEqual(@as(usize, 2), results.len);
    try testing.expectEqual(@as(u32, 0), results[0].id);
    try testing.expect(results[0].distance < results[1].distance);
}

test "ann: CodeDB 512D row-major embeddings keep stable ids through mmap" {
    if (@import("builtin").os.tag == .windows) return;
    const dimensions: u16 = 512;
    const count: usize = 3;
    var vectors: [count * dimensions]f32 = @splat(0);
    vectors[0 * dimensions + 3] = 1;
    vectors[1 * dimensions + 17] = 1;
    vectors[2 * dimensions + 29] = 1;
    vectors[2 * dimensions + 31] = 0.25;

    var source = ann.Index.init(testing.allocator, dimensions, .{ .seed = 107 });
    defer source.deinit();
    try testing.expectEqual(@as(u32, 0), try source.insertEmbeddingBatch(&vectors, count, dimensions));
    try testing.expectEqual(count, source.len());

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = path_buf[0..try tmp.dir.realPathFile(testing.io, ".", &path_buf)];
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/codedb-512d.hmls", .{dir_path});
    defer testing.allocator.free(path);
    try source.writeSlabs(path);

    var wrong_dimensions = ann.Index.init(testing.allocator, dimensions - 1, .{});
    defer wrong_dimensions.deinit();
    try testing.expectError(error.DimensionMismatch, wrong_dimensions.loadMmap(path));

    const slab_bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .limited(1024 * 1024));
    defer testing.allocator.free(slab_bytes);
    const truncated_path = try std.fmt.allocPrint(testing.allocator, "{s}/codedb-512d-truncated.hmls", .{dir_path});
    defer testing.allocator.free(truncated_path);
    var truncated = try std.Io.Dir.cwd().createFile(testing.io, truncated_path, .{});
    try truncated.writeStreamingAll(testing.io, slab_bytes[0 .. slab_bytes.len - 1]);
    truncated.close(testing.io);
    var truncated_index = ann.Index.init(testing.allocator, dimensions, .{});
    defer truncated_index.deinit();
    try testing.expectError(error.Truncated, truncated_index.loadMmap(truncated_path));

    const qscale_offset: usize = @intCast(std.mem.readInt(u64, slab_bytes[64..72], .little));
    std.mem.writeInt(u32, slab_bytes[qscale_offset..][0..4], @bitCast(std.math.nan(f32)), .little);
    const nan_path = try std.fmt.allocPrint(testing.allocator, "{s}/codedb-512d-nan-scale.hmls", .{dir_path});
    defer testing.allocator.free(nan_path);
    var nan_file = try std.Io.Dir.cwd().createFile(testing.io, nan_path, .{});
    try nan_file.writeStreamingAll(testing.io, slab_bytes);
    nan_file.close(testing.io);
    var nan_index = ann.Index.init(testing.allocator, dimensions, .{});
    defer nan_index.deinit();
    try testing.expectError(error.InvalidVectorValue, nan_index.loadMmap(nan_path));

    var loaded = ann.Index.init(testing.allocator, dimensions, .{});
    defer loaded.deinit();
    try loaded.loadMmap(path);
    try testing.expect(loaded.isMmapBacked());
    try testing.expectEqual(count, loaded.len());
    const query = vectors[2 * dimensions ..][0..dimensions];
    const results = try loaded.search(query, 2, testing.allocator);
    defer testing.allocator.free(results);
    try testing.expectEqual(@as(u32, 2), results[0].id);
}

test "ann: CodeDB embedding batch rejects malformed shape and invalid rows" {
    const dimensions: u16 = 512;
    var index = ann.Index.init(testing.allocator, dimensions, .{ .seed = 109 });
    defer index.deinit();
    var row: [dimensions]f32 = @splat(0);
    row[0] = 1;

    try testing.expectError(error.InvalidEmbeddingBatch, index.insertEmbeddingBatch(&row, 0, dimensions));
    try testing.expectError(error.DimensionMismatch, index.insertEmbeddingBatch(&row, 1, dimensions - 1));
    try testing.expectError(error.InvalidEmbeddingBatchShape, index.insertEmbeddingBatch(row[0 .. row.len - 1], 1, dimensions));
    try testing.expectError(error.InvalidEmbeddingBatchShape, index.insertEmbeddingBatch(&row, 2, dimensions));
    row[7] = std.math.nan(f32);
    try testing.expectError(error.InvalidVectorValue, index.insertEmbeddingBatch(&row, 1, dimensions));
    row[7] = std.math.inf(f32);
    try testing.expectError(error.InvalidVectorValue, index.insertEmbeddingBatch(&row, 1, dimensions));
    @memset(&row, 0);
    try testing.expectError(error.ZeroNormVector, index.insertEmbeddingBatch(&row, 1, dimensions));
    try testing.expectEqual(@as(usize, 0), index.len());
}

test "ann: serialized index round-trips without changing the best result" {
    var source = ann.Index.init(testing.allocator, 3, .{ .seed = 11 });
    defer source.deinit();
    _ = try source.insert(&.{ 1, 0, 0 });
    _ = try source.insert(&.{ 0, 1, 0 });
    const bytes = try source.serialize(testing.allocator);
    defer testing.allocator.free(bytes);
    try testing.expectEqual(bytes.len, source.serializedSize());

    var loaded = ann.Index.init(testing.allocator, 3, .{ .seed = 11 });
    defer loaded.deinit();
    try loaded.load(bytes);
    const results = try loaded.search(&.{ 0, 0.9, 0.1 }, 1, testing.allocator);
    defer testing.allocator.free(results);
    try testing.expectEqual(@as(u32, 1), results[0].id);
}

test "ann: payload accounting is checked and dimension aware" {
    try testing.expectEqual(@as(usize, 20_000 * 512 * 5), try ann.vectorPayloadBytes(20_000, 512));
    try testing.expectEqual(@as(usize, 20_000 * 512), try ann.vectorPayloadBytesWithMode(20_000, 512, false));
    try testing.expectError(error.Overflow, ann.vectorPayloadBytes(std.math.maxInt(usize), 512));
}

test "ann: official int8-only library mode omits f32 and remains searchable" {
    var index = ann.Index.init(testing.allocator, 4, .{ .seed = 23, .store_f32 = false });
    defer index.deinit();
    _ = try index.insert(&.{ 1, 0, 0, 0 });
    _ = try index.insert(&.{ 0, 1, 0, 0 });
    try testing.expect(!index.hasStoredF32());
    try testing.expectEqual(@as(usize, 0), index.vectorConst(0).len);
    const results = try index.search(&.{ 0.99, 0.01, 0, 0 }, 1, testing.allocator);
    defer testing.allocator.free(results);
    try testing.expectEqual(@as(u32, 0), results[0].id);
}

test "ann: mmap loader rejects out-of-range neighbor ids" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = path_buf[0..try tmp.dir.realPathFile(io, ".", &path_buf)];
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/corrupt-neighbor.hmls", .{dir_path});
    defer testing.allocator.free(path);

    var source = ann.Index.init(testing.allocator, 64, .{ .seed = 41 });
    defer source.deinit();
    var a: [64]f32 = @splat(0);
    var b: [64]f32 = @splat(0);
    a[0] = 1;
    b[1] = 1;
    _ = try source.insert(&a);
    _ = try source.insert(&b);
    try source.writeSlabs(path);

    var file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
    defer file.close(io);
    var header: [136]u8 = undefined;
    try testing.expectEqual(header.len, try file.readPositionalAll(io, &header, 0));
    const l0_degree_offset = std.mem.readInt(u64, header[88..96], .little);
    const l0_neighbors_offset = std.mem.readInt(u64, header[96..104], .little);
    var degree_bytes: [2]u8 = undefined;
    try testing.expectEqual(degree_bytes.len, try file.readPositionalAll(io, &degree_bytes, l0_degree_offset));
    try testing.expect(std.mem.readInt(u16, &degree_bytes, .little) > 0);
    var invalid_neighbor: [4]u8 = undefined;
    std.mem.writeInt(u32, &invalid_neighbor, std.math.maxInt(u32), .little);
    try file.writePositionalAll(io, &invalid_neighbor, l0_neighbors_offset);
    try file.sync(io);

    var loaded = ann.Index.init(testing.allocator, 64, .{});
    defer loaded.deinit();
    try testing.expectError(error.InvalidNeighborId, loaded.loadMmap(path));
    _ = try loaded.insert(&a);
    const recovered = try loaded.search(&a, 1, testing.allocator);
    defer testing.allocator.free(recovered);
    try testing.expectEqual(@as(u32, 0), recovered[0].id);

    const corrupt = try std.Io.Dir.cwd().readFileAlloc(io, path, testing.allocator, .limited(1024 * 1024));
    defer testing.allocator.free(corrupt);
    var copied = ann.Index.init(testing.allocator, 64, .{});
    defer copied.deinit();
    try testing.expectError(error.InvalidNeighborId, copied.loadSlabsCopy(corrupt));
    _ = try copied.insert(&b);
    const copy_recovered = try copied.search(&b, 1, testing.allocator);
    defer testing.allocator.free(copy_recovered);
    try testing.expectEqual(@as(u32, 0), copy_recovered[0].id);
}

test "ann: mmap loader rejects a high-layer edge to a node without that layer" {
    if (@import("builtin").os.tag == .windows) return;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = path_buf[0..try tmp.dir.realPathFile(io, ".", &path_buf)];
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/bad-neighbor-layer.hmls", .{dir_path});
    defer testing.allocator.free(path);

    var source = ann.Index.init(testing.allocator, 64, .{ .seed = 43 });
    defer source.deinit();
    for (0..128) |i| {
        var vector: [64]f32 = @splat(0);
        vector[i % vector.len] = 1;
        vector[(i * 11 + 7) % vector.len] += 0.2;
        _ = try source.insert(&vector);
    }
    try source.writeSlabs(path);

    var file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
    defer file.close(io);
    var header: [136]u8 = undefined;
    try testing.expectEqual(header.len, try file.readPositionalAll(io, &header, 0));
    const count: usize = @intCast(std.mem.readInt(u64, header[16..24], .little));
    const m: usize = std.mem.readInt(u32, header[32..36], .little);
    const hi_slots: usize = @intCast(std.mem.readInt(u64, header[48..56], .little));
    const levels_offset = std.mem.readInt(u64, header[56..64], .little);
    const hi_start_offset = std.mem.readInt(u64, header[104..112], .little);
    const hi_degree_offset = std.mem.readInt(u64, header[112..120], .little);
    const hi_neighbors_offset = std.mem.readInt(u64, header[120..128], .little);

    const levels = try testing.allocator.alloc(u32, count);
    defer testing.allocator.free(levels);
    try testing.expectEqual(std.mem.sliceAsBytes(levels).len, try file.readPositionalAll(io, std.mem.sliceAsBytes(levels), levels_offset));
    const hi_starts = try testing.allocator.alloc(u32, count);
    defer testing.allocator.free(hi_starts);
    try testing.expectEqual(std.mem.sliceAsBytes(hi_starts).len, try file.readPositionalAll(io, std.mem.sliceAsBytes(hi_starts), hi_start_offset));
    const hi_degrees = try testing.allocator.alloc(u16, hi_slots);
    defer testing.allocator.free(hi_degrees);
    try testing.expectEqual(std.mem.sliceAsBytes(hi_degrees).len, try file.readPositionalAll(io, std.mem.sliceAsBytes(hi_degrees), hi_degree_offset));

    var level_zero_id: ?u32 = null;
    for (levels, 0..) |level, id| {
        if (level == 0) {
            level_zero_id = @intCast(id);
            break;
        }
    }
    try testing.expect(level_zero_id != null);

    const hi_stride = m + 1;
    var corrupt_offset: ?u64 = null;
    for (levels, 0..) |level, id| {
        if (level == 0) continue;
        const start: usize = hi_starts[id];
        for (0..level) |slot_offset| {
            const slot = start + slot_offset;
            if (hi_degrees[slot] == 0) continue;
            const neighbor_index = slot * hi_stride;
            corrupt_offset = hi_neighbors_offset + @as(u64, @intCast(neighbor_index * @sizeOf(u32)));
            break;
        }
        if (corrupt_offset != null) break;
    }
    try testing.expect(corrupt_offset != null);

    var forged_neighbor: [4]u8 = undefined;
    std.mem.writeInt(u32, &forged_neighbor, level_zero_id.?, .little);
    try file.writePositionalAll(io, &forged_neighbor, corrupt_offset.?);
    try file.sync(io);

    var loaded = ann.Index.init(testing.allocator, 64, .{});
    defer loaded.deinit();
    try testing.expectError(error.InvalidNeighborLayer, loaded.loadMmap(path));
    try testing.expect(!loaded.isMmapBacked());
    try testing.expectEqual(@as(usize, 0), loaded.len());

    // A rejected sidecar leaves a reusable empty index instead of a partially
    // attached mapping, and the following search proves there was no panic.
    var recovery: [64]f32 = @splat(0);
    recovery[3] = 1;
    _ = try loaded.insert(&recovery);
    const recovered = try loaded.search(&recovery, 1, testing.allocator);
    defer testing.allocator.free(recovered);
    try testing.expectEqual(@as(u32, 0), recovered[0].id);
}

test "ann: legacy loader bounds record and layer allocations before use" {
    var source = ann.Index.init(testing.allocator, 3, .{ .seed = 59 });
    defer source.deinit();
    _ = try source.insert(&.{ 1, 0, 0 });
    const valid = try source.serialize(testing.allocator);
    defer testing.allocator.free(valid);

    const huge_count = try testing.allocator.dupe(u8, valid);
    defer testing.allocator.free(huge_count);
    std.mem.writeInt(u64, huge_count[16..24], std.math.maxInt(u64), .little);
    var count_loaded = ann.Index.init(testing.allocator, 3, .{});
    defer count_loaded.deinit();
    try testing.expectError(error.InvalidSlabLayout, count_loaded.load(huge_count));

    const excessive_layers = try testing.allocator.dupe(u8, valid);
    defer testing.allocator.free(excessive_layers);
    const layer_count_offset = 48 + 4 + 4 + 3 * @sizeOf(f32) + 3;
    std.mem.writeInt(u32, excessive_layers[layer_count_offset..][0..4], 66, .little);
    var layer_loaded = ann.Index.init(testing.allocator, 3, .{});
    defer layer_loaded.deinit();
    try testing.expectError(error.InvalidSlabLayout, layer_loaded.load(excessive_layers));
}

test "ann: mmap loader rejects graph layouts above the validation RSS budget" {
    if (@import("builtin").os.tag == .windows) return;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = path_buf[0..try tmp.dir.realPathFile(testing.io, ".", &path_buf)];
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/graph-budget.hmls", .{dir_path});
    defer testing.allocator.free(path);

    var source = ann.Index.init(testing.allocator, 64, .{ .seed = 47 });
    defer source.deinit();
    var vector: [64]f32 = @splat(0);
    vector[0] = 1;
    _ = try source.insert(&vector);
    try source.writeSlabs(path);

    var file = try std.Io.Dir.cwd().openFile(testing.io, path, .{ .mode = .read_write });
    defer file.close(testing.io);
    var forged: [8]u8 = undefined;
    const records: u64 = 100_000;
    std.mem.writeInt(u64, &forged, records, .little);
    try file.writePositionalAll(testing.io, &forged, 16);
    std.mem.writeInt(u64, &forged, records * 64, .little);
    try file.writePositionalAll(testing.io, &forged, 48);
    var option: [4]u8 = undefined;
    std.mem.writeInt(u32, &option, 1024, .little);
    try file.writePositionalAll(testing.io, &option, 32);
    std.mem.writeInt(u32, &option, 16, .little);
    try file.writePositionalAll(testing.io, &option, 36);
    try file.sync(testing.io);

    var loaded = ann.Index.init(testing.allocator, 64, .{});
    defer loaded.deinit();
    try testing.expectError(error.GraphValidationBudgetExceeded, loaded.loadMmap(path));
}

test "ann: mmap loader rejects a max layer not owned by the entry point" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = path_buf[0..try tmp.dir.realPathFile(io, ".", &path_buf)];
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/bad-entry-level.hmls", .{dir_path});
    defer testing.allocator.free(path);

    var source = ann.Index.init(testing.allocator, 64, .{ .seed = 61 });
    defer source.deinit();
    var vector: [64]f32 = @splat(0);
    vector[0] = 1;
    _ = try source.insert(&vector);
    try source.writeSlabs(path);

    var file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
    defer file.close(io);
    var forged: [4]u8 = undefined;
    std.mem.writeInt(u32, &forged, 1, .little);
    try file.writePositionalAll(io, &forged, 28);
    try file.sync(io);

    var loaded = ann.Index.init(testing.allocator, 64, .{});
    defer loaded.deinit();
    try testing.expectError(error.InvalidSlabLayout, loaded.loadMmap(path));
}

test "ann: mmap layout round-trips after neighbor slabs cross a page boundary" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = path_buf[0..try tmp.dir.realPathFile(io, ".", &path_buf)];
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/multi-page.hmls", .{dir_path});
    defer testing.allocator.free(path);

    var source = ann.Index.init(testing.allocator, 64, .{ .seed = 53 });
    defer source.deinit();
    for (0..600) |i| {
        var vector: [64]f32 = @splat(0);
        vector[i % vector.len] = 1;
        vector[(i * 7 + 3) % vector.len] += 0.25;
        _ = try source.insert(&vector);
    }
    try source.writeSlabs(path);

    var loaded = ann.Index.init(testing.allocator, 64, .{});
    defer loaded.deinit();
    try loaded.loadMmap(path);
    try testing.expect(loaded.isMmapBacked());
    try testing.expectEqual(@as(usize, 600), loaded.len());
}

test "ann: an indexed repository-shape manifest is deterministic and sensitive" {
    var explorer = @import("explore.zig").Explorer.init(testing.allocator, 1024 * 1024);
    defer explorer.deinit();
    try explorer.indexFile("src/a.zig", "pub fn alpha() void {}\n");
    try explorer.indexFile("src/b.zig", "pub fn beta() void {}\n");
    const before = try semantic_index.manifestFingerprint(&explorer, testing.allocator);
    try testing.expectEqual(before, try semantic_index.manifestFingerprint(&explorer, testing.allocator));
    try explorer.indexFile("src/b.zig", "pub fn betaChanged() void {}\n");
    try testing.expect(before != try semantic_index.manifestFingerprint(&explorer, testing.allocator));
}
