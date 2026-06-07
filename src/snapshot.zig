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
const cio = @import("cio.zig");
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
    call_centrality = 8,
    content_hashes = 9,
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
    const rand_suffix = cio.randU64();
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.{x}.tmp", .{ output_path, rand_suffix });
    defer allocator.free(tmp_path);

    var file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{});

    var sections: std.ArrayList(SectionEntry) = .empty;
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
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        const writer = cio.listWriter(&buf, allocator);
        var total_bytes: u64 = 0;
        var outline_size_iter = explorer.outlines.valueIterator();
        while (outline_size_iter.next()) |outline| {
            total_bytes += outline.byte_size;
        }
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
            @divTrunc(cio.nanoTimestamp(), 1_000_000_000),
            FORMAT_VERSION,
            root_hash,
        });
        try fw.writeAll(buf.items);
        try sections.append(allocator, .{ .id = @intFromEnum(SectionId.meta), .offset = offset, .length = buf.items.len });
    }

    // ── Section: TREE ──
    {
        const offset = file_writer.logicalPos();
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        const writer = cio.listWriter(&buf, allocator);
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
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        const writer = cio.listWriter(&buf, allocator);

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
            for (outline.imports.items) |imp_full| {
                const imp = imp_full[0..@min(imp_full.len, std.math.maxInt(u16))];
                var import_len_buf: [2]u8 = undefined;
                std.mem.writeInt(u16, &import_len_buf, @intCast(imp.len), .little);
                try writer.writeAll(&import_len_buf);
                try writer.writeAll(imp);
            }

            var symbol_count_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &symbol_count_buf, @intCast(outline.symbols.items.len), .little);
            try writer.writeAll(&symbol_count_buf);
            for (outline.symbols.items) |sym| {
                // Names from minified/generated files can exceed u16 (65535) —
                // truncate the stored name instead of panicking on @intCast (P0).
                const sym_name = sym.name[0..@min(sym.name.len, std.math.maxInt(u16))];
                var name_len_buf: [2]u8 = undefined;
                std.mem.writeInt(u16, &name_len_buf, @intCast(sym_name.len), .little);
                try writer.writeAll(&name_len_buf);
                try writer.writeAll(sym_name);

                try writer.writeByte(@intFromEnum(sym.kind));

                var line_start_buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &line_start_buf, sym.line_start, .little);
                try writer.writeAll(&line_start_buf);

                var line_end_buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &line_end_buf, sym.line_end, .little);
                try writer.writeAll(&line_end_buf);

                if (sym.detail) |detail_full| {
                    const detail = detail_full[0..@min(detail_full.len, std.math.maxInt(u16))];
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
    // Per-file content hashes, collected in lockstep with the records below and
    // written as a separate CONTENT_HASHES section. The loader records these in
    // the Store version log instead of re-hashing every file's content at load
    // (which also faults in the whole mmap'd content section).
    var content_hashes: std.ArrayList(u64) = .empty;
    defer content_hashes.deinit(allocator);
    {
        const offset = file_writer.logicalPos();
        var root_dir = std.Io.Dir.cwd().openDir(io, root_path, .{}) catch null;
        defer if (root_dir) |*dir| dir.close(io);

        var path_iter = explorer.outlines.keyIterator();
        while (path_iter.next()) |path_ptr| {
            const path = path_ptr.*;
            // Skip sensitive files that may contain secrets
            if (isSensitivePath(path)) continue;
            const cached_content = explorer.contents.get(path);
            if (cached_content) |content| {
                var pl_buf: [2]u8 = undefined;
                std.mem.writeInt(u16, &pl_buf, @intCast(path.len), .little);
                try fw.writeAll(&pl_buf);
                try fw.writeAll(path);
                var cl_buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &cl_buf, @intCast(content.len), .little);
                try fw.writeAll(&cl_buf);
                try fw.writeAll(content);
                try content_hashes.append(allocator, std.hash.Wyhash.hash(0, content));
            } else if (root_dir) |*dir| {
                const disk_content = dir.readFileAlloc(io, path, allocator, .limited(64 * 1024 * 1024)) catch continue;
                errdefer allocator.free(disk_content);

                var pl_buf: [2]u8 = undefined;
                std.mem.writeInt(u16, &pl_buf, @intCast(path.len), .little);
                try fw.writeAll(&pl_buf);
                try fw.writeAll(path);
                var cl_buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &cl_buf, @intCast(disk_content.len), .little);
                try fw.writeAll(&cl_buf);
                try fw.writeAll(disk_content);
                try content_hashes.append(allocator, std.hash.Wyhash.hash(0, disk_content));
                allocator.free(disk_content);
            }
        }
        const end = file_writer.logicalPos();
        try sections.append(allocator, .{ .id = @intFromEnum(SectionId.content), .offset = offset, .length = end - offset });
    }

    // ── Section: CONTENT_HASHES ──
    // u64 Wyhash per content record, in the exact order of the CONTENT section,
    // so the loader can record Store baselines without re-hashing content. An
    // absent section just makes the loader recompute (older snapshots).
    {
        const offset = file_writer.logicalPos();
        for (content_hashes.items) |h| {
            var hbuf: [8]u8 = undefined;
            std.mem.writeInt(u64, &hbuf, h, .little);
            try fw.writeAll(&hbuf);
        }
        const end = file_writer.logicalPos();
        try sections.append(allocator, .{ .id = @intFromEnum(SectionId.content_hashes), .offset = offset, .length = end - offset });
    }

    // ── Section: FREQ TABLE ──
    {
        const offset = file_writer.logicalPos();
        const index_mod = @import("index.zig");
        const table = index_mod.active_pair_freq;
        var bulk_buf: [256 * 256 * 2]u8 = undefined;
        for (table, 0..) |row, a| {
            for (row, 0..) |val, b| {
                std.mem.writeInt(u16, bulk_buf[(a * 256 + b) * 2 ..][0..2], val, .little);
            }
        }
        try fw.writeAll(&bulk_buf);
        const end = file_writer.logicalPos();
        try sections.append(allocator, .{ .id = @intFromEnum(SectionId.freq_table), .offset = offset, .length = end - offset });
    }

    // ── Section: CALL_CENTRALITY ──
    // Per-file weighted call-graph in-degree (path -> f32), so a loaded snapshot
    // can skip the lazy first-query rebuild in ensureCallCentrality. Written only
    // if already built (non-null); an absent/empty section makes the loader fall
    // back to the lazy build — backward compatible with older snapshots. Read
    // under the shared lock held above; never builds here.
    {
        const offset = file_writer.logicalPos();
        const count: u32 = if (explorer.call_centrality) |cm| @intCast(cm.count()) else 0;
        var count_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &count_buf, count, .little);
        try fw.writeAll(&count_buf);
        if (explorer.call_centrality) |cm| {
            var it = cm.iterator();
            while (it.next()) |e| {
                const key = e.key_ptr.*;
                var plen_buf: [2]u8 = undefined;
                std.mem.writeInt(u16, &plen_buf, @intCast(@min(key.len, std.math.maxInt(u16))), .little);
                try fw.writeAll(&plen_buf);
                try fw.writeAll(key[0..@min(key.len, std.math.maxInt(u16))]);
                const bits: u32 = @bitCast(e.value_ptr.*);
                var f_buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &f_buf, bits, .little);
                try fw.writeAll(&f_buf);
            }
        }
        const end = file_writer.logicalPos();
        try sections.append(allocator, .{ .id = @intFromEnum(SectionId.call_centrality), .offset = offset, .length = end - offset });
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
            // statFile (no open/close): only the mtime is needed here.
            const ds = std.Io.Dir.cwd().statFile(io, path_buf, .{}) catch break :blk;
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
    if (file_count == 0) return false;
    if (expected_file_count) |expected| {
        if (file_count != expected) return false;
    }

    // Load frequency table if present
    if (sections.get(@intFromEnum(SectionId.freq_table))) |freq_entry| {
        if (freq_entry.length == 256 * 256 * 2) {
            const index_mod = @import("index.zig");
            const ft = allocator.create([256][256]u16) catch return file_count > 0;
            var bulk_buf: [256 * 256 * 2]u8 = undefined;
            const nr = file.readPositionalAll(io, &bulk_buf, freq_entry.offset) catch {
                allocator.destroy(ft);
                return file_count > 0;
            };
            if (nr != bulk_buf.len) {
                allocator.destroy(ft);
                return file_count > 0;
            }
            for (0..256) |a| {
                for (0..256) |b| {
                    ft[a][b] = std.mem.readInt(u16, bulk_buf[(a * 256 + b) * 2 ..][0..2], .little);
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

/// Like readSectionString but returns a slice that aliases `buf` (no copy, no
/// allocation). Valid only while `buf` is alive — callers that retain the
/// result must keep `buf` alive at least as long (see loadOutlineStateMap).
fn readSectionStringBorrowed(buf: []const u8, cursor: *usize, max_len: usize) ![]const u8 {
    const len = try readSectionInt(u16, buf, cursor);
    if (len > max_len) return error.InvalidData;
    if (cursor.* + len > buf.len) return error.InvalidData;
    const out = buf[cursor.* .. cursor.* + len];
    cursor.* += len;
    return out;
}
/// On success, `backing_out.*` is set to the raw outline_state section buffer
/// and ownership transfers to the caller (the restored FileOutlines borrow
/// their import/symbol strings as slices into it — see FileOutline.borrows_strings).
/// On any error the buffer is freed here and `backing_out.*` is left null.
///
/// The backing buffer is allocated from `backing_allocator` (the Explorer's
/// allocator), NOT `allocator` (the per-load allocator): it is retained by the
/// Explorer and must share its lifetime/allocator. Everything else (the map,
/// keys/paths) uses `allocator` exactly as before.
fn loadOutlineStateMap(io: std.Io, snapshot_path: []const u8, allocator: std.mem.Allocator, backing_allocator: std.mem.Allocator, expected: ?u32, backing_out: *?[]const u8) !std.StringHashMap(FileOutline) {
    backing_out.* = null;
    const bytes = (try readSectionBytes(io, snapshot_path, .outline_state, backing_allocator)) orelse return error.InvalidData;
    // Kept alive on success (handed to backing_out); freed here on any error.
    var release_bytes = true;
    defer if (release_bytes) backing_allocator.free(bytes);

    var result = std.StringHashMap(FileOutline).init(allocator);
    errdefer deinitOutlineStateMap(&result, allocator);
    // Pre-size to the known file count: the map otherwise grows 0 -> ~N with
    // ~log2(N) rehashes, each re-hashing every entry inserted so far.
    if (expected) |e| result.ensureTotalCapacity(e) catch {};

    var cursor: usize = 0;
    const file_count = try readSectionInt(u32, bytes, &cursor);
    for (0..file_count) |_| {
        // `path` is the map key and stays individually owned (deinitOutlineStateMap
        // / Explorer.deinit free it). Only the import/symbol strings are borrowed.
        const path = try readSectionString(bytes, &cursor, allocator, 4096);
        if (path.len == 0) return error.InvalidData;
        errdefer allocator.free(path);

        var outline = FileOutline.init(allocator, path);
        outline.borrows_strings = true;
        errdefer outline.deinit();

        const language_raw = try readSectionByte(bytes, &cursor);
        outline.language = std.enums.fromInt(Language, language_raw) orelse return error.InvalidData;
        outline.line_count = try readSectionInt(u32, bytes, &cursor);
        outline.byte_size = try readSectionInt(u64, bytes, &cursor);

        const import_count = try readSectionInt(u32, bytes, &cursor);
        try outline.imports.ensureTotalCapacity(allocator, import_count);
        for (0..import_count) |_| {
            const imp = try readSectionStringBorrowed(bytes, &cursor, 4096);
            outline.imports.appendAssumeCapacity(imp);
        }

        const symbol_count = try readSectionInt(u32, bytes, &cursor);
        try outline.symbols.ensureTotalCapacity(allocator, symbol_count);
        for (0..symbol_count) |_| {
            const name = try readSectionStringBorrowed(bytes, &cursor, std.math.maxInt(u16));
            if (name.len == 0) return error.InvalidData;

            const kind_raw = try readSectionByte(bytes, &cursor);
            const kind = std.enums.fromInt(SymbolKind, kind_raw) orelse return error.InvalidData;
            const line_start = try readSectionInt(u32, bytes, &cursor);
            const line_end = try readSectionInt(u32, bytes, &cursor);
            const has_detail = try readSectionByte(bytes, &cursor);
            const detail = switch (has_detail) {
                0 => null,
                1 => try readSectionStringBorrowed(bytes, &cursor, std.math.maxInt(u16)),
                else => return error.InvalidData,
            };

            outline.symbols.appendAssumeCapacity(Symbol{
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
    // Success: transfer the backing buffer to the caller.
    backing_out.* = bytes;
    release_bytes = false;
    return result;
}

fn rebuildDepsFromOutline(explorer: *Explorer, path: []const u8, outline: *const FileOutline, allocator: std.mem.Allocator) !void {
    var deps: std.ArrayList([]const u8) = .empty;
    errdefer deps.deinit(allocator);
    try deps.ensureTotalCapacity(allocator, outline.imports.items.len);

    for (outline.imports.items) |imp| {
        if (std.mem.indexOf(u8, imp, "..") != null) continue;
        deps.appendAssumeCapacity(imp);
    }

    try explorer.dep_graph.setDeps(path, deps);
}

fn insertRestoredFile(
    explorer: *Explorer,
    path: []const u8,
    content: []const u8,
    outline: FileOutline,
    allocator: std.mem.Allocator,
    borrow_content: bool,
) !void {
    var restored_outline = outline;
    restored_outline.path = path;

    const outline_gop = try explorer.outlines.getOrPut(path);
    if (outline_gop.found_existing) return error.InvalidData;
    outline_gop.key_ptr.* = path;
    outline_gop.value_ptr.* = restored_outline;

    // When the content was read from an mmap the Explorer has adopted, store a
    // borrowed (zero-copy) cache value; otherwise dupe it as usual.
    if (borrow_content) {
        try explorer.contents.putBorrowed(path, content);
    } else {
        try explorer.contents.put(path, content);
    }

    try rebuildDepsFromOutline(explorer, path, &restored_outline, allocator);

    // Mirror commitParsedFileOwnedOutline (explore.zig:872): symbol_index is built
    // eagerly on every ingest and has NO lazy rebuild trigger. resolveCallees reads
    // it without a fallback (#524 perf note), so restored files must populate it
    // here or call-graph edges into them are lost after a snapshot load. had_prior
    // is false: insertRestoredFile errors above if the path already exists.
    explorer.rebuildSymbolIndexFor(path, &restored_outline, false);

    // Restored files are absent from word_index and trigram_index at load time
    // (both are rebuilt lazily/incrementally). Register the path in
    // skip_trigram_files so searchContent's Tier 3 scans its content; without
    // this the file falls out of every search tier the moment the trigram index
    // is non-empty (Tier 5's full scan is then ruled out). Mirrors the
    // outline-only branch of commitParsedFileOwnedOutline. See #507 / #537.
    try explorer.skip_trigram_files.put(path, {});
}

// Below this many files the per-file freshness stats run on the loading thread:
// spawning workers for a small tree costs more than the stats they save. Setting
// CODEDB_LOAD_WORKERS overrides the worker count (and forces parallelism below the
// threshold) for A/B measurement. Public so a test can size a fixture that
// deterministically exercises the multi-worker path.
pub const FRESHNESS_PARALLEL_THRESHOLD: usize = 256;

// Worker cap for the parallel freshness scan. statFile is dominated by kernel VFS
// work, not CPU, so throughput saturates at low concurrency: a worker sweep over a
// 16k-file tree (20 P-core M3 Ultra, files across 200 dirs) measured freshness
// 14.1ms@1 -> 5.7ms@4 -> 9.5ms@8 -> 13.3ms@12 — a U-curve bottoming at ~4 regardless
// of core count. More workers past that regress (syscall/cache contention), so cap
// low rather than at the CPU count. CODEDB_LOAD_WORKERS overrides for re-tuning.
const FRESHNESS_MAX_WORKERS: usize = 4;

// One parsed CONTENT-section record. `path` and `content` are borrowed slices into
// the mapped content section (alive for the whole load) — never owned here; the
// insert pass copies whatever it keeps.
const LoadRecord = struct {
    path: []const u8,
    content: []const u8,
    stored_hash: ?u64,
};

// Outcome of one file's freshness check: was the on-disk file modified after the
// snapshot? The scan only stats — no content read, no allocation — so workers stay
// pure and trivially thread-safe; the insert pass reads fresh content (sequentially,
// one file at a time) for the rare stale ones.
const LoadFreshness = struct {
    stale: bool = false,
};

// Freshness scan for one chunk of records: statFile each path (one syscall, no
// open/close) and flag it stale when its mtime is newer than the snapshot. Pure
// read-only and allocation-free, so workers run this over disjoint chunks
// concurrently; each writes only its own slice of `out`.
fn freshnessScan(io: std.Io, snap_mtime: i128, recs: []const LoadRecord, out: []LoadFreshness) void {
    for (recs, out) |record, *fr| {
        const ds = std.Io.Dir.cwd().statFile(io, record.path, .{}) catch continue;
        const ds_mtime: i128 = @intCast(ds.mtime.nanoseconds);
        if (ds_mtime > snap_mtime) fr.stale = true;
    }
}

fn loadSnapshotFast(
    io: std.Io,
    snapshot_path: []const u8,
    expected_file_count: ?u32,
    explorer: *Explorer,
    store: *Store,
    allocator: std.mem.Allocator,
) !bool {
    // Optional phase profiler (CODEDB_LOAD_PROFILE): prints a load breakdown to
    // stderr. Near-zero cost when off (one getenv + a few timestamps).
    const prof = cio.posixGetenv("CODEDB_LOAD_PROFILE") != null;
    const t_load0: i128 = if (prof) cio.nanoTimestamp() else 0;
    var fresh_ns: i128 = 0;

    var section_backing: ?[]const u8 = null;
    // backing_allocator = explorer.allocator: the section buffer is retained by
    // the Explorer (outline_section_bufs) and freed via explorer.allocator, so it
    // must be allocated from the same allocator (matters when the per-load
    // allocator differs from the Explorer's, e.g. arena-backed Explorers).
    var outline_states = loadOutlineStateMap(io, snapshot_path, allocator, explorer.allocator, expected_file_count, &section_backing) catch std.StringHashMap(FileOutline).init(allocator);
    defer deinitOutlineStateMap(&outline_states, allocator);

    // Restored outlines borrow their import/symbol strings as slices into this
    // buffer; hand it to the Explorer so it outlives them. If the Explorer can't
    // retain it the borrows would dangle, so free it and abort to a full re-index.
    if (section_backing) |b| {
        explorer.adoptOutlineSection(b) catch {
            explorer.allocator.free(b);
            return false;
        };
    }

    // Pre-size the explorer maps the restore loop fills. Without this they grow
    // 0 -> ~N with ~log2(N) rehashes apiece, each re-inserting every prior entry
    // (an O(N log N) churn over the whole load). The file count is known up front.
    if (expected_file_count) |fc| {
        explorer.outlines.ensureTotalCapacity(fc) catch {};
        explorer.dep_graph.forward.ensureTotalCapacity(fc) catch {};
        explorer.dep_graph.reverse.ensureTotalCapacity(fc) catch {};
    }

    const t_outline: i128 = if (prof) cio.nanoTimestamp() else 0;
    var sections = (try readSections(io, snapshot_path, allocator)) orelse return false;
    defer sections.deinit();

    const content_entry = sections.get(@intFromEnum(SectionId.content)) orelse return false;
    const content_file = std.Io.Dir.cwd().openFile(io, snapshot_path, .{}) catch return false;
    defer content_file.close(io);

    const file_stat = content_file.stat(io) catch return false;
    if (content_entry.offset + content_entry.length > file_stat.size) return false;

    const snap_mtime: i128 = @intCast(file_stat.mtime.nanoseconds);
    var file_count: u32 = 0;
    var word_index_can_load_from_disk = true;

    // Precomputed per-record content hashes (CONTENT_HASHES section), in content
    // order. Lets the restored branch record Store baselines without re-hashing
    // (which would also fault in all content pages). Absent => recompute.
    const content_hashes_buf: ?[]u8 = readSectionBytes(io, snapshot_path, .content_hashes, allocator) catch null;
    defer if (content_hashes_buf) |b| allocator.free(b);

    // Read the content section as one block, then parse records from memory.
    // This replaces ~4 readPositionalAll syscalls per file (path_len, path,
    // content_len, content — ~156k syscalls on a 39k-file repo) with in-memory
    // slicing. Prefer a file-backed mmap (no heap spike — pages are demand-paged
    // and reclaimable); fall back to a heap bulk-read if mmap is unavailable.
    const sec_len: usize = std.math.cast(usize, content_entry.length) orelse return false;
    const sec_base: usize = std.math.cast(usize, content_entry.offset) orelse return false;
    var heap_section: ?[]u8 = null;
    defer if (heap_section) |h| allocator.free(h);
    // When the content comes from an mmap, the Explorer adopts it (munmap'd at its
    // deinit) and the ContentCache borrows zero-copy slices into it — no per-file
    // content dupe. The heap fallback is transient (freed below), so in that case
    // the content is duped into the cache as usual.
    var content_borrowed = false;
    const section: []const u8 = section_blk: {
        const fsize: usize = std.math.cast(usize, file_stat.size) orelse return false;
        if (std.posix.mmap(null, fsize, .{ .READ = true }, .{ .TYPE = .SHARED }, content_file.handle, 0)) |m| {
            if (explorer.adoptContentSection(m)) {
                content_borrowed = true;
                break :section_blk m[sec_base..][0..sec_len];
            } else |_| {
                std.posix.munmap(m);
            }
        } else |_| {}
        const h = allocator.alloc(u8, sec_len) catch return false;
        if ((content_file.readPositionalAll(io, h, content_entry.offset) catch 0) != sec_len) {
            allocator.free(h);
            return false;
        }
        heap_section = h;
        break :section_blk h;
    };

    // ── Pass A: parse the CONTENT section into records (borrowed slices). ──
    // Pure slicing over the mapped section — no per-file allocation. The path and
    // content of each record are slices into `section` (alive for the whole load).
    // The insert pass (Pass C) copies whatever it retains — indexFile*/recordSnapshot
    // dupe the path, the restored branch reuses the OUTLINE_STATE map key — so this
    // drops the old per-record path_buf alloc+memcpy+free (one pair per file).
    var records: std.ArrayList(LoadRecord) = .empty;
    defer records.deinit(allocator);
    if (expected_file_count) |fc| records.ensureTotalCapacity(allocator, fc) catch {};
    {
        var sc: usize = 0; // cursor into `section`
        var rec_idx: usize = 0;
        while (sc < section.len) {
            if (sc + 2 > section.len) break;
            const path_len = std.mem.readInt(u16, section[sc..][0..2], .little);
            sc += 2;
            if (path_len == 0 or path_len > 4096) break;
            if (sc + path_len > section.len) break;
            const path = section[sc..][0..path_len];
            sc += path_len;

            if (sc + 4 > section.len) break;
            const content_len = std.mem.readInt(u32, section[sc..][0..4], .little);
            sc += 4;
            if (content_len > 64 * 1024 * 1024 or sc + content_len > section.len) break;
            const content = section[sc..][0..content_len];
            sc += content_len;

            // Precomputed hash of this record's content, if the snapshot carries it
            // (content order). Lets the restored/outline-only branches record a Store
            // baseline without re-hashing + faulting every page; the changed-file
            // branch re-hashes fresh disk content instead.
            const stored_hash: ?u64 = if (content_hashes_buf) |hb| blk: {
                const off = rec_idx * 8;
                break :blk if (off + 8 <= hb.len) std.mem.readInt(u64, hb[off..][0..8], .little) else null;
            } else null;
            records.append(allocator, .{ .path = path, .content = content, .stored_hash = stored_hash }) catch break;
            rec_idx += 1;
        }
    }

    // ── Pass B: freshness check (parallelized for large trees). ──
    // statFile every record to detect edits made since the snapshot. These are
    // independent, allocation-free per-file syscalls — the dominant load cost once
    // the borrow/mmap work removed the copies — so fan them out across workers, each
    // flagging its own disjoint slice. The insert pass (Pass C) reads fresh content
    // for the flagged files and mutates Explorer/Store single-threaded.
    const fresh_results = allocator.alloc(LoadFreshness, records.items.len) catch return false;
    defer allocator.free(fresh_results);
    for (fresh_results) |*fr| fr.* = .{};

    const t_fresh0: i128 = if (prof) cio.nanoTimestamp() else 0;
    if (snap_mtime > 0 and records.items.len > 0) {
        const want_workers = blk: {
            if (cio.posixGetenv("CODEDB_LOAD_WORKERS")) |raw| {
                const parsed = std.fmt.parseInt(usize, raw, 10) catch 0;
                if (parsed > 0) break :blk parsed;
            }
            if (records.items.len < FRESHNESS_PARALLEL_THRESHOLD) break :blk 1;
            const cpu_count = std.Thread.getCpuCount() catch 1;
            break :blk @min(@as(usize, @intCast(cpu_count)), FRESHNESS_MAX_WORKERS);
        };
        const n_workers = @max(@as(usize, 1), @min(want_workers, records.items.len));
        if (n_workers <= 1) {
            freshnessScan(io, snap_mtime, records.items, fresh_results);
        } else if (allocator.alloc(std.Thread, n_workers)) |threads| {
            defer allocator.free(threads);
            const chunk = records.items.len / n_workers;
            const rem = records.items.len % n_workers;
            var off: usize = 0;
            var spawned: usize = 0;
            var spawn_failed = false;
            for (0..n_workers) |i| {
                const extra: usize = if (i < rem) 1 else 0;
                const start = off;
                off += chunk + extra;
                const recs = records.items[start..off];
                const out = fresh_results[start..off];
                if (spawn_failed) {
                    freshnessScan(io, snap_mtime, recs, out);
                    continue;
                }
                if (std.Thread.spawn(.{}, freshnessScan, .{ io, snap_mtime, recs, out })) |t| {
                    threads[spawned] = t;
                    spawned += 1;
                } else |_| {
                    // Out of threads: scan this chunk (and any remaining) inline.
                    freshnessScan(io, snap_mtime, recs, out);
                    spawn_failed = true;
                }
            }
            for (threads[0..spawned]) |t| t.join();
        } else |_| {
            freshnessScan(io, snap_mtime, records.items, fresh_results);
        }
    }
    if (prof) fresh_ns += cio.nanoTimestamp() - t_fresh0;

    // ── Pass C: insert restored / changed / outline-only files (sequential). ──
    for (records.items, fresh_results) |record, fr| {
        const path = record.path;
        const content = record.content;
        // A file flagged stale was edited after the snapshot: re-read its fresh
        // content from disk and re-index it. Read here (not in the parallel scan) so
        // peak memory is one file's content, not every changed file's at once.
        var disk_content: ?[]u8 = null;
        if (fr.stale) {
            disk_content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024)) catch null;
        }
        defer if (disk_content) |dc| allocator.free(dc);

        if (disk_content) |dc| {
            word_index_can_load_from_disk = false;
            if (outline_states.fetchRemove(path)) |removed| {
                allocator.free(removed.key);
                var stale_outline = removed.value;
                stale_outline.deinit();
            }
            explorer.indexFile(path, dc) catch continue;
            const hash = std.hash.Wyhash.hash(0, dc);
            _ = store.recordSnapshot(path, dc.len, hash) catch {};
        } else if (outline_states.fetchRemove(path)) |removed| {
            insertRestoredFile(explorer, removed.key, content, removed.value, allocator, content_borrowed) catch {
                allocator.free(removed.key);
                var bad_outline = removed.value;
                bad_outline.deinit();
                continue;
            };
            const hash = record.stored_hash orelse std.hash.Wyhash.hash(0, content);
            _ = store.recordSnapshot(removed.key, content.len, hash) catch {};
        } else {
            word_index_can_load_from_disk = false;
            explorer.indexFileOutlineOnly(path, content) catch continue;
            const hash = record.stored_hash orelse std.hash.Wyhash.hash(0, content);
            _ = store.recordSnapshot(path, content.len, hash) catch {};
        }

        file_count += 1;
    }

    if (file_count == 0) return false;
    if (expected_file_count) |expected| {
        if (file_count != expected) return false;
    }

    if (outline_states.count() != 0) return false;

    explorer.markWordIndexIncomplete(word_index_can_load_from_disk);

    if (sections.get(@intFromEnum(SectionId.freq_table))) |freq_entry| {
        if (freq_entry.length == 256 * 256 * 2) {
            const index_mod = @import("index.zig");
            const ft = allocator.create([256][256]u16) catch return file_count > 0;
            const freq_file = std.Io.Dir.cwd().openFile(io, snapshot_path, .{}) catch return file_count > 0;
            defer freq_file.close(io);
            var bulk_buf: [256 * 256 * 2]u8 = undefined;
            const nr = freq_file.readPositionalAll(io, &bulk_buf, freq_entry.offset) catch {
                allocator.destroy(ft);
                return file_count > 0;
            };
            if (nr != bulk_buf.len) {
                allocator.destroy(ft);
                return file_count > 0;
            }
            for (0..256) |a| {
                for (0..256) |b| {
                    ft[a][b] = std.mem.readInt(u16, bulk_buf[(a * 256 + b) * 2 ..][0..2], .little);
                }
            }
            index_mod.setFrequencyTable(ft);
            allocator.destroy(ft);
        }
    }

    // Restore persisted call-graph centrality, if present, so the first ranked
    // search skips the lazy rebuild (ensureCallCentrality's null-check returns
    // early once this is set). Best-effort: any failure just leaves it unbuilt.
    if (sections.get(@intFromEnum(SectionId.call_centrality))) |cc_entry| {
        restoreCallCentrality(io, snapshot_path, cc_entry, explorer, allocator) catch {};
    }

    if (prof) {
        const now = cio.nanoTimestamp();
        const ms = struct {
            fn f(ns: i128) f64 {
                return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
            }
        }.f;
        const outline_ns = t_outline - t_load0;
        const loop_ns = now - t_outline;
        std.debug.print(
            "[load-profile] {d} files  total={d:.1}ms  outline={d:.1}ms  loop={d:.1}ms (freshness={d:.1}ms, rest={d:.1}ms)\n",
            .{ file_count, ms(now - t_load0), ms(outline_ns), ms(loop_ns), ms(fresh_ns), ms(loop_ns - fresh_ns) },
        );
    }

    return true;
}

/// Reconstruct Explorer.call_centrality from a persisted CALL_CENTRALITY section.
/// Keys are taken from the (now-populated) outlines map so they share the same
/// stable, borrowed lifetime as ensureCallCentrality's keys — Explorer.deinit
/// frees them via outlines, never via call_centrality. Files no longer in the
/// outlines (changed/removed since the snapshot) are simply skipped.
fn restoreCallCentrality(
    io: std.Io,
    snapshot_path: []const u8,
    entry: SectionEntry,
    explorer: *Explorer,
    allocator: std.mem.Allocator,
) !void {
    if (entry.length < 4 or entry.length > 256 * 1024 * 1024) return;
    const bytes = try allocator.alloc(u8, entry.length);
    defer allocator.free(bytes);
    const f = try std.Io.Dir.cwd().openFile(io, snapshot_path, .{});
    defer f.close(io);
    if ((try f.readPositionalAll(io, bytes, entry.offset)) != entry.length) return;

    var cursor: usize = 0;
    if (cursor + 4 > bytes.len) return;
    const count = std.mem.readInt(u32, bytes[cursor..][0..4], .little);
    cursor += 4;
    if (count == 0) return;

    var cmap = std.StringHashMap(f32).init(explorer.allocator);
    errdefer cmap.deinit();
    cmap.ensureTotalCapacity(count) catch {};

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (cursor + 2 > bytes.len) break;
        const plen = std.mem.readInt(u16, bytes[cursor..][0..2], .little);
        cursor += 2;
        if (plen == 0 or cursor + plen + 4 > bytes.len) break;
        const path = bytes[cursor .. cursor + plen];
        cursor += plen;
        const bits = std.mem.readInt(u32, bytes[cursor..][0..4], .little);
        cursor += 4;
        const centrality: f32 = @bitCast(bits);
        // Borrow the stable outlines key (don't allocate a new one).
        if (explorer.outlines.getEntry(path)) |e| {
            cmap.put(e.key_ptr.*, centrality) catch {};
        }
    }

    explorer.call_centrality = cmap;
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

/// Returns true for secret/credential paths that must never be persisted to a
/// snapshot or live-indexed. Kept in lockstep with `watcher.isSensitivePath`;
/// the two are parity-tested in test_snapshot.zig ("issue-528: isSensitivePath
/// parity") so any future drift in this security filter fails CI.
pub fn isSensitivePath(path: []const u8) bool {
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

    // Catch .env, .env.anything; do NOT match .envoy, .envrc, .environment, etc.
    if (basename.len >= 4 and std.mem.eql(u8, basename[0..4], ".env") and
        (basename.len == 4 or basename[4] == '.' or basename[4] == '-' or basename[4] == '_')) return true;

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

    const now_ns: i128 = cio.nanoTimestamp();
    const min_age_ns: i128 = @as(i128, std.time.s_per_min) * std.time.ns_per_s;

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        const name = entry.name;
        // Match: starts with basename, ends with .tmp
        if (name.len > basename.len and
            std.mem.startsWith(u8, name, basename) and
            endsWith(name, ".tmp"))
        {
            // Age guard: skip in-flight tmps from concurrent writers.
            // Only delete leftovers crashed processes left behind (>60s old).
            const st = dir.statFile(io, name, .{}) catch continue;
            const m_ns: i128 = @intCast(st.mtime.nanoseconds);
            if (now_ns - m_ns < min_age_ns) continue;
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
    writeProjectCacheSnapshot(io, explorer, root_path, allocator) catch {};
}

pub fn writeProjectCacheSnapshot(
    io: std.Io,
    explorer: *Explorer,
    root_path: []const u8,
    allocator: std.mem.Allocator,
) !void {
    const hash = std.hash.Wyhash.hash(0, root_path);
    const home_raw = cio.posixGetenv("HOME") orelse return;
    const home = allocator.dupe(u8, home_raw) catch return;
    defer allocator.free(home);
    const secondary = std.fmt.allocPrint(allocator, "{s}/.codedb/projects/{x}/codedb.snapshot", .{ home, hash }) catch return;
    defer allocator.free(secondary);

    const dir_path = std.fmt.allocPrint(allocator, "{s}/.codedb/projects/{x}", .{ home, hash }) catch return;
    defer allocator.free(dir_path);
    std.Io.Dir.cwd().createDirPath(io, dir_path) catch {};

    const proj_txt = std.fmt.allocPrint(allocator, "{s}/project.txt", .{dir_path}) catch return;
    defer allocator.free(proj_txt);
    var f = try std.Io.Dir.cwd().createFile(io, proj_txt, .{ .truncate = true });
    f.writeStreamingAll(io, root_path) catch {};
    f.close(io);

    try writeSnapshot(io, explorer, root_path, secondary, allocator);
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
