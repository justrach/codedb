// snapshot.zig — Portable `.codedb` artifact writer/reader
//
// Produces a single binary file containing the full indexed state of a repo.
// Any agent can read this file to understand the codebase without re-indexing.
//
// Format (all integers little-endian):
//   Header (52 bytes):
//     magic:         "CDB\x01"  (4 bytes)
//     version:       u16
//     flags:         u16         (reserved)
//     git_head:      [40]u8      (hex SHA or zeroes)
//     section_count: u32
//   Section Table (section_count × 20 bytes):
//     id:     u32    (section type)
//     offset: u64    (byte offset from file start)
//     length: u64    (byte length)
//   Sections:
//     TREE    (1): JSON array of {path, language, line_count, byte_size, symbol_count}
//     OUTLINE (2): legacy JSON object mapping path → [{name, kind, line, detail}]
//     CONTENT (3): for each file: path_len(u16) + path + content_len(u32) + content
//     FREQ    (5): 256×256×u16 LE frequency table
//     META    (6): JSON {file_count, total_bytes, indexed_at, format_version}
//     OUTLINE_STATE (7): binary per-file outline/import metadata for fast warm restore

const std = @import("std");
const explore_mod = @import("explore.zig");
const Explorer = explore_mod.Explorer;
const FileOutline = explore_mod.FileOutline;
const Symbol = explore_mod.Symbol;
const SymbolKind = explore_mod.SymbolKind;
const Language = explore_mod.Language;
const Store = @import("store.zig").Store;
const git_mod = @import("git.zig");

const MAGIC = [4]u8{ 'C', 'D', 'B', 0x01 };
const FORMAT_VERSION: u16 = 2;

pub const SectionId = enum(u32) {
    tree = 1,
    outline = 2,
    content = 3,
    freq_table = 5,
    meta = 6,
    outline_state = 7,
};

const SectionEntry = struct {
    id: u32,
    offset: u64,
    length: u64,
};

/// Write a portable `.codedb` snapshot file.
pub fn writeSnapshot(
    io: std.Io,
    explorer: *Explorer,
    root_path: []const u8,
    output_path: []const u8,
    allocator: std.mem.Allocator,
) !void {
    const rand_suffix = std.crypto.random.int(u64);
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.{x}.tmp", .{ output_path, rand_suffix });
    defer allocator.free(tmp_path);

    var file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{});

    var sections: std.ArrayList(SectionEntry) = .{};
    defer sections.deinit(allocator);

    var fw_buf: [64 * 1024]u8 = undefined;
    var file_writer = file.writer(io, &fw_buf);
    const fw = &file_writer.interface;

    // Reserve space for header + section table (rewritten at end)
    // Header: 52 bytes.  Section table: up to 5 sections × 20 = 100.
    // Round to 256 for alignment.
    const header_reserve: u64 = 256;
    try file_writer.seekTo(header_reserve);

    explorer.mu.lockShared();
    defer explorer.mu.unlockShared();

    // ── Section: META ──
    {
        const offset = file_writer.logicalPos();
        var buf: std.ArrayList(u8) = .{};
        defer buf.deinit(allocator);
        const writer = buf.writer(allocator);
        var total_bytes: u64 = 0;
        var ct_iter = explorer.contents.valueIterator();
        while (ct_iter.next()) |v| total_bytes += v.*.len;
        var file_count_meta: u32 = 0;
        var fc_iter = explorer.outlines.keyIterator();
        while (fc_iter.next()) |k| {
            if (!isSensitivePath(k.*)) file_count_meta += 1;
        }

        const root_hash = std.hash.Wyhash.hash(0, root_path);
        try writer.print(
            \\{{"file_count":{d},"total_bytes":{d},"indexed_at":{d},"format_version":{d},"root_hash":{d}}}
        , .{
            file_count_meta,
            total_bytes,
            std.time.timestamp(),
            FORMAT_VERSION,
            root_hash,
        });
        try fw.writeAll(buf.items);
        try sections.append(allocator, .{ .id = @intFromEnum(SectionId.meta), .offset = offset, .length = buf.items.len });
    }

    // ── Section: TREE ──
    {
        const offset = file_writer.logicalPos();
        var buf: std.ArrayList(u8) = .{};
        defer buf.deinit(allocator);
        const writer = buf.writer(allocator);
        try writer.writeByte('[');
        var first = true;
        var iter = explorer.outlines.iterator();
        while (iter.next()) |entry| {
            if (isSensitivePath(entry.key_ptr.*)) continue;
            if (!first) try writer.writeByte(',');
            first = false;
            const outline = entry.value_ptr;
            try writer.writeAll("{\"path\":\"");
            try writeJsonEscaped(writer, entry.key_ptr.*);
            try writer.print(
                \\","language":"{s}","line_count":{d},"byte_size":{d},"symbol_count":{d}}}
            , .{
                @tagName(outline.language),
                outline.line_count,
                outline.byte_size,
                outline.symbols.items.len,
            });
        }
        try writer.writeByte(']');
        try fw.writeAll(buf.items);
        try sections.append(allocator, .{ .id = @intFromEnum(SectionId.tree), .offset = offset, .length = buf.items.len });
    }

    // ── Section: OUTLINE_STATE ──
    {
        const offset = file_writer.logicalPos();
        var buf: std.ArrayList(u8) = .{};
        defer buf.deinit(allocator);
        const writer = buf.writer(allocator);

        var file_count_buf: [4]u8 = undefined;
        var file_count: u32 = 0;
        var count_iter = explorer.outlines.keyIterator();
        while (count_iter.next()) |key_ptr| {
            if (!isSensitivePath(key_ptr.*)) file_count += 1;
        }
        std.mem.writeInt(u32, &file_count_buf, file_count, .little);
        try writer.writeAll(&file_count_buf);

        var iter = explorer.outlines.iterator();
        while (iter.next()) |entry| {
            if (isSensitivePath(entry.key_ptr.*)) continue;

            const path = entry.key_ptr.*;
            const outline = entry.value_ptr;

            var path_len_buf: [2]u8 = undefined;
            std.mem.writeInt(u16, &path_len_buf, @intCast(path.len), .little);
            try writer.writeAll(&path_len_buf);
            try writer.writeAll(path);

            try writer.writeByte(@intFromEnum(outline.language));

            var line_count_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &line_count_buf, outline.line_count, .little);
            try writer.writeAll(&line_count_buf);

            var byte_size_buf: [8]u8 = undefined;
            std.mem.writeInt(u64, &byte_size_buf, outline.byte_size, .little);
            try writer.writeAll(&byte_size_buf);

            var import_count_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &import_count_buf, @intCast(outline.imports.items.len), .little);
            try writer.writeAll(&import_count_buf);
            for (outline.imports.items) |imp| {
                var import_len_buf: [2]u8 = undefined;
                std.mem.writeInt(u16, &import_len_buf, @intCast(imp.len), .little);
                try writer.writeAll(&import_len_buf);
                try writer.writeAll(imp);
            }

            var symbol_count_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &symbol_count_buf, @intCast(outline.symbols.items.len), .little);
            try writer.writeAll(&symbol_count_buf);
            for (outline.symbols.items) |sym| {
                var name_len_buf: [2]u8 = undefined;
                std.mem.writeInt(u16, &name_len_buf, @intCast(sym.name.len), .little);
                try writer.writeAll(&name_len_buf);
                try writer.writeAll(sym.name);

                try writer.writeByte(@intFromEnum(sym.kind));

                var line_start_buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &line_start_buf, sym.line_start, .little);
                try writer.writeAll(&line_start_buf);

                var line_end_buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &line_end_buf, sym.line_end, .little);
                try writer.writeAll(&line_end_buf);

                if (sym.detail) |detail| {
                    try writer.writeByte(1);
                    var detail_len_buf: [2]u8 = undefined;
                    std.mem.writeInt(u16, &detail_len_buf, @intCast(detail.len), .little);
                    try writer.writeAll(&detail_len_buf);
                    try writer.writeAll(detail);
                } else {
                    try writer.writeByte(0);
                }
            }
        }

        try fw.writeAll(buf.items);
        const end = file_writer.logicalPos();
        try sections.append(allocator, .{ .id = @intFromEnum(SectionId.outline_state), .offset = offset, .length = end - offset });
    }

    // ── Section: CONTENT ──
    {
        const offset = file_writer.logicalPos();
        var ct_iter = explorer.contents.iterator();
        while (ct_iter.next()) |entry| {
            const path = entry.key_ptr.*;
            // Skip sensitive files that may contain secrets
            if (isSensitivePath(path)) continue;
            const content = entry.value_ptr.*;
            var pl_buf: [2]u8 = undefined;
            std.mem.writeInt(u16, &pl_buf, @intCast(path.len), .little);
            try fw.writeAll(&pl_buf);
            try fw.writeAll(path);
            var cl_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &cl_buf, @intCast(content.len), .little);
            try fw.writeAll(&cl_buf);
            try fw.writeAll(content);
        }
        const end = file_writer.logicalPos();
        try sections.append(allocator, .{ .id = @intFromEnum(SectionId.content), .offset = offset, .length = end - offset });
    }

    // ── Section: FREQ TABLE ──
    {
        const offset = file_writer.logicalPos();
        const index_mod = @import("index.zig");
        const table = index_mod.active_pair_freq;
        var row_buf: [256 * 2]u8 = undefined;
        for (table) |row| {
            for (row, 0..) |val, j| {
                std.mem.writeInt(u16, row_buf[j * 2 ..][0..2], val, .little);
            }
            try fw.writeAll(&row_buf);
        }
        const end = file_writer.logicalPos();
        try sections.append(allocator, .{ .id = @intFromEnum(SectionId.freq_table), .offset = offset, .length = end - offset });
    }

    // ── Write header + section table at file start ──
    try file_writer.seekTo(0);

    try fw.writeAll(&MAGIC);
    var ver_buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &ver_buf, FORMAT_VERSION, .little);
    try fw.writeAll(&ver_buf);
    try fw.writeAll(&[2]u8{ 0, 0 }); // flags

    const git_head = git_mod.getGitHead(root_path, allocator) catch null;
    if (git_head) |head| {
        try fw.writeAll(&head);
    } else {
        try fw.writeAll(&([_]u8{0x00} ** 40));
    }

    var sc_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &sc_buf, @intCast(sections.items.len), .little);
    try fw.writeAll(&sc_buf);

    for (sections.items) |sec| {
        var id_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &id_buf, sec.id, .little);
        try fw.writeAll(&id_buf);
        var off_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &off_buf, sec.offset, .little);
        try fw.writeAll(&off_buf);
        var len_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &len_buf, sec.length, .little);
        try fw.writeAll(&len_buf);
    }

    try fw.flush();
    file.close(io);
    file = undefined;
    std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), output_path, io) catch |err| {
        // If rename fails (e.g. output_path is a directory), clean up tmp
        std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
        return err;
    };
}


/// Read section table from a `.codedb` file.
fn readSectionsFromFile(io: std.Io, file: std.Io.File, allocator: std.mem.Allocator) !?std.AutoHashMap(u32, SectionEntry) {
    var magic_buf: [4]u8 = undefined;
    const n = file.readPositionalAll(io, &magic_buf, 0) catch return null;
    if (n != 4 or !std.mem.eql(u8, &magic_buf, &MAGIC)) return null;

    // offset 4 + 44 = 48: skip version + flags + git_head
    var sc_buf: [4]u8 = undefined;
    const scn = file.readPositionalAll(io, &sc_buf, 48) catch return null;
    if (scn != 4) return null;
    const section_count = std.mem.readInt(u32, &sc_buf, .little);

    var result = std.AutoHashMap(u32, SectionEntry).init(allocator);
    errdefer result.deinit();

    var pos: u64 = 52;
    for (0..section_count) |_| {
        var entry_buf: [20]u8 = undefined;
        const en = file.readPositionalAll(io, &entry_buf, pos) catch return null;
        if (en != 20) return null;
        pos += 20;
        try result.put(
            std.mem.readInt(u32, entry_buf[0..4], .little),
            .{
                .id = std.mem.readInt(u32, entry_buf[0..4], .little),
                .offset = std.mem.readInt(u64, entry_buf[4..12], .little),
                .length = std.mem.readInt(u64, entry_buf[12..20], .little),
            },
        );
    }
    return result;
}

pub fn readSections(io: std.Io, path: []const u8, allocator: std.mem.Allocator) !?std.AutoHashMap(u32, SectionEntry) {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);
    return readSectionsFromFile(io, file, allocator);
}

/// Read a section's raw bytes from a `.codedb` file.
pub fn readSectionBytes(io: std.Io, path: []const u8, section_id: SectionId, allocator: std.mem.Allocator) !?[]u8 {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);

    var sections = try readSectionsFromFile(io, file, allocator) orelse return null;
    defer sections.deinit();

    const entry = sections.get(@intFromEnum(section_id)) orelse return null;
    if (entry.length > 256 * 1024 * 1024) return null; // sanity cap: 256MB

    // Validate section fits within file
    const file_size = file.length(io) catch return null;
    if (entry.offset + entry.length > file_size) return null;

    const buf = try allocator.alloc(u8, @intCast(entry.length));
    errdefer allocator.free(buf);
    const nr = try file.readPositionalAll(io, buf, entry.offset);
    if (nr != buf.len) {
        allocator.free(buf);
        return null;
    }
    return buf;
}

/// Read the git HEAD stored in a snapshot file header. Returns null if
/// the file doesn't exist, is invalid, or has an all-zero HEAD.
pub fn readSnapshotGitHead(io: std.Io, path: []const u8) ?[40]u8 {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);

    var magic_buf: [4]u8 = undefined;
    const mn = file.readPositionalAll(io, &magic_buf, 0) catch return null;
    if (mn != 4) return null;
    if (!std.mem.eql(u8, &magic_buf, &MAGIC)) return null;

    // offset 4 + 4 = 8: skip version + flags
    var head_buf: [40]u8 = undefined;
    const hn = file.readPositionalAll(io, &head_buf, 8) catch return null;
    if (hn != 40) return null;

    // Return null for all-zero sentinel (no git HEAD available)
    if (std.mem.allEqual(u8, &head_buf, 0x00)) return null;
    // Also handle legacy 0xFF sentinel from older versions
    if (std.mem.allEqual(u8, &head_buf, 0xFF)) return null;

    return head_buf;
}

/// Load a snapshot into an Explorer. Populates contents, outlines, and
/// rebuilds trigram + sparse n-gram indexes from the loaded content.
/// Returns true on success, false if the snapshot couldn't be loaded.
pub fn loadSnapshot(
    io: std.Io,
    snapshot_path: []const u8,
    explorer: *Explorer,
    store: *@import("store.zig").Store,
    allocator: std.mem.Allocator,
) bool {
    return loadSnapshotValidated(io, snapshot_path, null, explorer, store, allocator);
}

/// Load a snapshot with optional repo identity validation.
/// If `expected_root` is non-null, the snapshot's root_hash must match.
pub fn loadSnapshotValidated(
    io: std.Io,
    snapshot_path: []const u8,
    expected_root: ?[]const u8,
    explorer: *Explorer,
    store: *Store,
    allocator: std.mem.Allocator,
) bool {
    // Clean up stale temp files from previous crashed writers
    cleanupStaleTmpFiles(io, snapshot_path);

    const file = std.Io.Dir.cwd().openFile(io, snapshot_path, .{}) catch return false;
    defer file.close(io);

    // Read section table (validates magic internally) — reuse already-open file (#253)
    var sections = (readSectionsFromFile(io, file, allocator) catch return false) orelse return false;
    defer sections.deinit();

    // Parse META section to get expected file_count and root_hash
    var expected_file_count: ?u32 = null;
    var meta_root_hash: ?u64 = null;
    if (sections.get(@intFromEnum(SectionId.meta))) |meta_entry| {
        if (meta_entry.length <= 256 * 1024 * 1024) blk: {
            const mb = allocator.alloc(u8, @intCast(meta_entry.length)) catch break :blk;
            defer allocator.free(mb);
            const nr = file.readPositionalAll(io, mb, meta_entry.offset) catch break :blk;
            if (nr != mb.len) break :blk;
            if (parseJsonU32(mb, "file_count")) |fc| {
                expected_file_count = fc;
            }
            if (parseJsonU64(mb, "root_hash")) |rh| {
                meta_root_hash = rh;
            }
        }
    }

    // Validate repo identity if requested (issue-41)
    if (expected_root) |root| {
        const expected_hash = std.hash.Wyhash.hash(0, root);
        if (meta_root_hash) |stored_hash| {
            if (stored_hash != expected_hash) return false;
        } else {
            // No root_hash in snapshot — reject if caller requires validation
            return false;
        }
    }

    if (sections.get(@intFromEnum(SectionId.outline_state)) != null) {
        return loadSnapshotFast(io, snapshot_path, expected_file_count, explorer, store, allocator) catch false;
    }

    // Load CONTENT section — this is the core data
    const content_entry = sections.get(@intFromEnum(SectionId.content)) orelse return false;

    // Validate content section fits within actual file size (issue-40: truncation detection)
    const file_stat = file.stat(io) catch return false;
    const file_size = file_stat.size;
    if (content_entry.offset + content_entry.length > file_size) return false;

    var read_pos: u64 = content_entry.offset;
    const snap_mtime: i128 = @intCast(file_stat.mtime.nanoseconds);
    var bytes_read: u64 = 0;
    var file_count: u32 = 0;
    while (bytes_read < content_entry.length) {
        // Read path_len(u16)
        var pl_buf: [2]u8 = undefined;
        const pln = file.readPositionalAll(io, &pl_buf, read_pos) catch return false;
        if (pln != 2) break;
        read_pos += 2;
        const path_len = std.mem.readInt(u16, &pl_buf, .little);
        if (path_len == 0 or path_len > 4096) break; // sanity cap
        bytes_read += 2;

        // Read path
        const path_buf = allocator.alloc(u8, path_len) catch return false;
        defer allocator.free(path_buf);
        const prn = file.readPositionalAll(io, path_buf, read_pos) catch return false;
        if (prn != path_len) break;
        read_pos += path_len;
        bytes_read += path_len;

        // Read content_len(u32)
        var cl_buf: [4]u8 = undefined;
        const cln = file.readPositionalAll(io, &cl_buf, read_pos) catch return false;
        if (cln != 4) break;
        read_pos += 4;
        const content_len = std.mem.readInt(u32, &cl_buf, .little);
        if (content_len > 64 * 1024 * 1024) break; // sanity cap: 64MB per file
        bytes_read += 4;

        // Read content
        const content = allocator.alloc(u8, content_len) catch return false;
        defer allocator.free(content);
        const crn = file.readPositionalAll(io, content, read_pos) catch return false;
        if (crn != content_len) break;
        read_pos += content_len;
        bytes_read += content_len;

        // Re-index from disk if file was modified after the snapshot
        var disk_content: ?[]u8 = null;
        if (snap_mtime > 0) blk: {
            const df = std.Io.Dir.cwd().openFile(io, path_buf, .{}) catch break :blk;
            defer df.close(io);
            const ds = df.stat(io) catch break :blk;
            const ds_mtime: i128 = @intCast(ds.mtime.nanoseconds);
            if (ds_mtime <= snap_mtime) break :blk;
            disk_content = std.Io.Dir.cwd().readFileAlloc(io, path_buf, allocator, .limited(16 * 1024 * 1024)) catch break :blk;
        }
        defer if (disk_content) |dc| allocator.free(dc);
        const effective = if (disk_content) |dc| dc else content;

        // Index into explorer (this dupes path and content internally)
        explorer.indexFile(path_buf, effective) catch continue;

        // Record in store for sequence tracking
        const hash = std.hash.Wyhash.hash(0, effective);
        _ = store.recordSnapshot(path_buf, effective.len, hash) catch {};

        file_count += 1;
    }

    // Validate file_count matches META expectation (issue-40)
    if (expected_file_count) |expected| {
        if (file_count != expected) return false;
    } else if (file_count == 0) {
        // No META and no files loaded — corrupt or empty snapshot
        return false;
    }

    // Load frequency table if present
    if (sections.get(@intFromEnum(SectionId.freq_table))) |freq_entry| {
        if (freq_entry.length == 256 * 256 * 2) {
            const index_mod = @import("index.zig");
            const ft = allocator.create([256][256]u16) catch return file_count > 0;
            var fp: u64 = freq_entry.offset;
            var row_buf: [256 * 2]u8 = undefined;
            for (0..256) |a| {
                const nr = file.readPositionalAll(io, &row_buf, fp) catch {
                    allocator.destroy(ft);
                    return file_count > 0;
                };
                if (nr != 512) {
                    allocator.destroy(ft);
                    return file_count > 0;
                }
                fp += 512;
                for (0..256) |b| {
                    ft[a][b] = std.mem.readInt(u16, row_buf[b * 2 ..][0..2], .little);
                }
            }
            index_mod.setFrequencyTable(ft);
            allocator.destroy(ft);
        }
    }

    return true;
}

fn deinitOutlineStateMap(map: *std.StringHashMap(FileOutline), allocator: std.mem.Allocator) void {
    var iter = map.iterator();
    while (iter.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        entry.value_ptr.deinit();
    }
    map.deinit();
}

fn readSectionInt(comptime T: type, buf: []const u8, cursor: *usize) !T {
    const size = @sizeOf(T);
    if (cursor.* + size > buf.len) return error.InvalidData;
    const value = std.mem.readInt(T, buf[cursor.*..][0..size], .little);
    cursor.* += size;
    return value;
}

fn readSectionByte(buf: []const u8, cursor: *usize) !u8 {
    if (cursor.* >= buf.len) return error.InvalidData;
    const value = buf[cursor.*];
    cursor.* += 1;
    return value;
}

fn readSectionString(buf: []const u8, cursor: *usize, allocator: std.mem.Allocator, max_len: usize) ![]u8 {
    const len = try readSectionInt(u16, buf, cursor);
    if (len > max_len) return error.InvalidData;
    if (cursor.* + len > buf.len) return error.InvalidData;
    const out = try allocator.dupe(u8, buf[cursor.* .. cursor.* + len]);
    cursor.* += len;
    return out;
}

fn loadOutlineStateMap(io: std.Io, snapshot_path: []const u8, allocator: std.mem.Allocator) !std.StringHashMap(FileOutline) {
    const bytes = (try readSectionBytes(io, snapshot_path, .outline_state, allocator)) orelse return error.InvalidData;
    defer allocator.free(bytes);

    var result = std.StringHashMap(FileOutline).init(allocator);
    errdefer deinitOutlineStateMap(&result, allocator);

    var cursor: usize = 0;
    const file_count = try readSectionInt(u32, bytes, &cursor);
    for (0..file_count) |_| {
        const path = try readSectionString(bytes, &cursor, allocator, 4096);
        if (path.len == 0) return error.InvalidData;
        errdefer allocator.free(path);

        var outline = FileOutline.init(allocator, path);
        errdefer outline.deinit();

        const language_raw = try readSectionByte(bytes, &cursor);
        outline.language = std.meta.intToEnum(Language, language_raw) catch return error.InvalidData;
        outline.line_count = try readSectionInt(u32, bytes, &cursor);
        outline.byte_size = try readSectionInt(u64, bytes, &cursor);

        const import_count = try readSectionInt(u32, bytes, &cursor);
        for (0..import_count) |_| {
            const imp = try readSectionString(bytes, &cursor, allocator, 4096);
            errdefer allocator.free(imp);
            try outline.imports.append(allocator, imp);
        }

        const symbol_count = try readSectionInt(u32, bytes, &cursor);
        for (0..symbol_count) |_| {
            const name = try readSectionString(bytes, &cursor, allocator, std.math.maxInt(u16));
            if (name.len == 0) return error.InvalidData;
            errdefer allocator.free(name);

            const kind_raw = try readSectionByte(bytes, &cursor);
            const kind = std.meta.intToEnum(SymbolKind, kind_raw) catch return error.InvalidData;
            const line_start = try readSectionInt(u32, bytes, &cursor);
            const line_end = try readSectionInt(u32, bytes, &cursor);
            const has_detail = try readSectionByte(bytes, &cursor);
            const detail = switch (has_detail) {
                0 => null,
                1 => try readSectionString(bytes, &cursor, allocator, std.math.maxInt(u16)),
                else => return error.InvalidData,
            };
            errdefer if (detail) |d| allocator.free(d);

            try outline.symbols.append(allocator, Symbol{
                .name = name,
                .kind = kind,
                .line_start = line_start,
                .line_end = line_end,
                .detail = detail,
            });
        }

        try result.put(path, outline);
    }

    if (cursor != bytes.len) return error.InvalidData;
    return result;
}

fn rebuildDepsFromOutline(explorer: *Explorer, path: []const u8, outline: *const FileOutline, allocator: std.mem.Allocator) !void {
    var deps: std.ArrayList([]const u8) = .{};
    errdefer deps.deinit(allocator);

    for (outline.imports.items) |imp| {
        if (std.mem.indexOf(u8, imp, "..") != null) continue;
        try deps.append(allocator, imp);
    }

    try explorer.dep_graph.setDeps(path, deps);
}

fn insertRestoredFile(
    explorer: *Explorer,
    path: []const u8,
    content: []const u8,
    outline: FileOutline,
    allocator: std.mem.Allocator,
) !void {
    var restored_outline = outline;
    restored_outline.path = path;

    const outline_gop = try explorer.outlines.getOrPut(path);
    if (outline_gop.found_existing) return error.InvalidData;
    outline_gop.key_ptr.* = path;
    outline_gop.value_ptr.* = restored_outline;

    const content_gop = try explorer.contents.getOrPut(path);
    if (content_gop.found_existing) return error.InvalidData;
    content_gop.key_ptr.* = path;
    content_gop.value_ptr.* = content;

    try rebuildDepsFromOutline(explorer, path, &restored_outline, allocator);
}

fn loadSnapshotFast(
    io: std.Io,
    snapshot_path: []const u8,
    expected_file_count: ?u32,
    explorer: *Explorer,
    store: *Store,
    allocator: std.mem.Allocator,
) !bool {
    var outline_states = loadOutlineStateMap(io, snapshot_path, allocator) catch std.StringHashMap(FileOutline).init(allocator);
    defer deinitOutlineStateMap(&outline_states, allocator);

    var sections = (try readSections(io, snapshot_path, allocator)) orelse return false;
    defer sections.deinit();

    const content_entry = sections.get(@intFromEnum(SectionId.content)) orelse return false;
    const content_file = std.Io.Dir.cwd().openFile(io, snapshot_path, .{}) catch return false;
    defer content_file.close(io);

    const file_stat = content_file.stat(io) catch return false;
    if (content_entry.offset + content_entry.length > file_stat.size) return false;

    var read_pos: u64 = content_entry.offset;
    const snap_mtime: i128 = @intCast(file_stat.mtime.nanoseconds);
    var bytes_read: u64 = 0;
    var file_count: u32 = 0;
    var word_index_can_load_from_disk = true;
    while (bytes_read < content_entry.length) {
        var pl_buf: [2]u8 = undefined;
        const pln = content_file.readPositionalAll(io, &pl_buf, read_pos) catch return false;
        if (pln != 2) break;
        read_pos += 2;
        const path_len = std.mem.readInt(u16, &pl_buf, .little);
        if (path_len == 0 or path_len > 4096) break;
        bytes_read += 2;

        const path_buf = allocator.alloc(u8, path_len) catch return false;
        const prn = content_file.readPositionalAll(io, path_buf, read_pos) catch return false;
        if (prn != path_len) {
            allocator.free(path_buf);
            break;
        }
        read_pos += path_len;
        bytes_read += path_len;

        var cl_buf: [4]u8 = undefined;
        const cln = content_file.readPositionalAll(io, &cl_buf, read_pos) catch return false;
        if (cln != 4) {
            allocator.free(path_buf);
            break;
        }
        read_pos += 4;
        const content_len = std.mem.readInt(u32, &cl_buf, .little);
        if (content_len > 64 * 1024 * 1024) {
            allocator.free(path_buf);
            break;
        }
        bytes_read += 4;

        const content = allocator.alloc(u8, content_len) catch return false;
        const crn = content_file.readPositionalAll(io, content, read_pos) catch return false;
        if (crn != content_len) {
            allocator.free(path_buf);
            allocator.free(content);
            break;
        }
        read_pos += content_len;
        bytes_read += content_len;

        var disk_content: ?[]u8 = null;
        if (snap_mtime > 0) blk: {
            const df = std.Io.Dir.cwd().openFile(io, path_buf, .{}) catch break :blk;
            defer df.close(io);
            const ds = df.stat(io) catch break :blk;
            const ds_mtime: i128 = @intCast(ds.mtime.nanoseconds);
            if (ds_mtime <= snap_mtime) break :blk;
            disk_content = std.Io.Dir.cwd().readFileAlloc(io, path_buf, allocator, .limited(16 * 1024 * 1024)) catch break :blk;
        }
        defer if (disk_content) |dc| allocator.free(dc);

        if (disk_content) |dc| {
            word_index_can_load_from_disk = false;
            if (outline_states.fetchRemove(path_buf)) |removed| {
                allocator.free(removed.key);
                var stale_outline = removed.value;
                stale_outline.deinit();
            }

            explorer.indexFileOutlineOnly(path_buf, dc) catch {
                allocator.free(path_buf);
                allocator.free(content);
                continue;
            };
            const hash = std.hash.Wyhash.hash(0, dc);
            _ = store.recordSnapshot(path_buf, dc.len, hash) catch {};
            allocator.free(path_buf);
            allocator.free(content);
        } else if (outline_states.fetchRemove(path_buf)) |removed| {
            allocator.free(path_buf);
            insertRestoredFile(explorer, removed.key, content, removed.value, allocator) catch {
                allocator.free(removed.key);
                var bad_outline = removed.value;
                bad_outline.deinit();
                allocator.free(content);
                continue;
            };
            const hash = std.hash.Wyhash.hash(0, content);
            _ = store.recordSnapshot(removed.key, content.len, hash) catch {};
        } else {
            word_index_can_load_from_disk = false;
            explorer.indexFileOutlineOnly(path_buf, content) catch {
                allocator.free(path_buf);
                allocator.free(content);
                continue;
            };
            const hash = std.hash.Wyhash.hash(0, content);
            _ = store.recordSnapshot(path_buf, content.len, hash) catch {};
            allocator.free(path_buf);
            allocator.free(content);
        }

        file_count += 1;
    }

    if (expected_file_count) |expected| {
        if (file_count != expected) return false;
    } else if (file_count == 0) {
        return false;
    }

    if (outline_states.count() != 0) return false;

    explorer.markWordIndexIncomplete(word_index_can_load_from_disk);

    if (sections.get(@intFromEnum(SectionId.freq_table))) |freq_entry| {
        if (freq_entry.length == 256 * 256 * 2) {
            const index_mod = @import("index.zig");
            const ft = allocator.create([256][256]u16) catch return file_count > 0;
            const freq_file = std.Io.Dir.cwd().openFile(io, snapshot_path, .{}) catch return file_count > 0;
            defer freq_file.close(io);
            var fp: u64 = freq_entry.offset;
            var row_buf: [256 * 2]u8 = undefined;
            for (0..256) |a| {
                const nr = freq_file.readPositionalAll(io, &row_buf, fp) catch {
                    allocator.destroy(ft);
                    return file_count > 0;
                };
                if (nr != 512) {
                    allocator.destroy(ft);
                    return file_count > 0;
                }
                fp += 512;
                for (0..256) |b| {
                    ft[a][b] = std.mem.readInt(u16, row_buf[b * 2 ..][0..2], .little);
                }
            }
            index_mod.setFrequencyTable(ft);
            allocator.destroy(ft);
        }
    }

    return true;
}

fn parseJsonU32(json: []const u8, key: []const u8) ?u32 {
    const val = parseJsonU64(json, key) orelse return null;
    return if (val <= std.math.maxInt(u32)) @intCast(val) else null;
}

fn parseJsonU64(json: []const u8, key: []const u8) ?u64 {
    var i: usize = 0;
    while (i + key.len + 2 <= json.len) : (i += 1) {
        if (json[i] == '"' and
            i + 1 + key.len + 1 <= json.len and
            std.mem.eql(u8, json[i + 1 .. i + 1 + key.len], key) and
            json[i + 1 + key.len] == '"')
        {
            var j = i + 2 + key.len;
            while (j < json.len and (json[j] == ':' or json[j] == ' ')) j += 1;
            const start = j;
            while (j < json.len and json[j] >= '0' and json[j] <= '9') j += 1;
            if (j > start) {
                return std.fmt.parseInt(u64, json[start..j], 10) catch null;
            }
        }
    }
    return null;
}

/// Returns true if a file path looks like it may contain secrets.
/// These files are excluded from snapshots to prevent accidental exposure.
fn isSensitivePath(path: []const u8) bool {
    const sensitive_names = [_][]const u8{
        ".env",
        ".env.local",
        ".env.production",
        ".env.development",
        ".env.staging",
        ".env.test",
        ".dev.vars",
        "credentials.json",
        "service-account.json",
        "secrets.json",
        "secrets.yaml",
        "secrets.yml",
        ".npmrc",
        ".pypirc",
        ".netrc",
        "id_rsa",
        "id_ed25519",
        ".pem",
    };

    // Check exact filename (basename)
    const basename = if (std.mem.lastIndexOfScalar(u8, path, '/')) |sep| path[sep + 1 ..] else path;

    for (sensitive_names) |name| {
        if (std.mem.eql(u8, basename, name)) return true;
    }

    // Check if basename starts with .env (catches .env.anything)
    if (basename.len >= 4 and std.mem.eql(u8, basename[0..4], ".env")) return true;

    // Check extensions
    if (endsWith(basename, ".pem")) return true;
    if (endsWith(basename, ".key")) return true;
    if (endsWith(basename, ".p12")) return true;
    if (endsWith(basename, ".pfx")) return true;
    if (endsWith(basename, ".jks")) return true;

    // Check directory patterns
    if (std.mem.indexOf(u8, path, ".ssh/") != null) return true;
    if (std.mem.indexOf(u8, path, ".gnupg/") != null) return true;
    if (std.mem.indexOf(u8, path, ".aws/") != null) return true;

    return false;
}

fn endsWith(s: []const u8, suffix: []const u8) bool {
    if (s.len < suffix.len) return false;
    return std.mem.eql(u8, s[s.len - suffix.len ..], suffix);
}

fn cleanupStaleTmpFiles(io: std.Io, output_path: []const u8) void {
    // Derive parent directory and basename from output_path
    const sep = std.mem.lastIndexOfScalar(u8, output_path, '/');
    const dir_path = if (sep) |s| output_path[0..s] else ".";
    const basename = if (sep) |s| output_path[s + 1 ..] else output_path;

    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        const name = entry.name;
        // Match: starts with basename, ends with .tmp
        if (name.len > basename.len and
            std.mem.startsWith(u8, name, basename) and
            endsWith(name, ".tmp"))
        {
            dir.deleteFile(io, name) catch {};
        }
    }
}

pub fn writeSnapshotDual(
    io: std.Io,
    explorer: *Explorer,
    root_path: []const u8,
    output_path: []const u8,
    allocator: std.mem.Allocator,
) !void {
    try writeSnapshot(io, explorer, root_path, output_path, allocator);

    const hash = std.hash.Wyhash.hash(0, root_path);
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch return;
    defer allocator.free(home);
    const secondary = std.fmt.allocPrint(allocator, "{s}/.codedb/projects/{x}/codedb.snapshot", .{ home, hash }) catch return;
    defer allocator.free(secondary);

    const dir_path = std.fmt.allocPrint(allocator, "{s}/.codedb/projects/{x}", .{ home, hash }) catch return;
    defer allocator.free(dir_path);
    std.Io.Dir.cwd().createDirPath(io, dir_path) catch {};

    const proj_txt = std.fmt.allocPrint(allocator, "{s}/project.txt", .{dir_path}) catch return;
    defer allocator.free(proj_txt);
    if (std.Io.Dir.cwd().createFile(io, proj_txt, .{})) |f| {
        f.writeStreamingAll(io, root_path) catch {};
        f.close(io);
    } else |_| {}

    writeSnapshot(io, explorer, root_path, secondary, allocator) catch {};
}

fn writeJsonEscaped(writer: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => if (c < 0x20) {
                const hex = "0123456789abcdef";
                const esc = [6]u8{ '\\', 'u', '0', '0', hex[c >> 4], hex[c & 0x0f] };
                try writer.writeAll(&esc);
            } else {
                try writer.writeByte(c);
            },
        }
    }
}
