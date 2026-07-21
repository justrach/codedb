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
const path_policy = @import("path_policy.zig");
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
// v3 adds the agent-artifact path policy. Reject older snapshots once so
// excluded prompts/session state cannot be resurrected by a warm restore.
const FORMAT_VERSION: u16 = 3;

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

const SnapshotSource = struct {
    /// Logical project path stored in snapshot sections (borrowed from Explorer).
    path: []const u8,
    /// Canonical project-relative target used for the actual no-follow read.
    resolved_path: ?[]u8,
    inode: std.Io.File.INode = 0,
    size: u64 = 0,
    mtime_ns: i128 = 0,
    ctime_ns: i128 = 0,
};

fn sameSnapshotStat(a: std.Io.File.Stat, b: std.Io.File.Stat) bool {
    return a.kind == b.kind and
        a.inode == b.inode and
        a.size == b.size and
        a.mtime.nanoseconds == b.mtime.nanoseconds and
        a.ctime.nanoseconds == b.ctime.nanoseconds;
}

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
    var file_open = true;
    errdefer {
        if (file_open) file.close(io);
        std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
    }

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

    // Use one validated source set for every section. Besides keeping metadata,
    // outlines, and content counts consistent, resolving aliases once here means
    // a sensitive/outside symlink can never appear in a non-content section.
    var root_dir = try std.Io.Dir.cwd().openDir(io, root_path, .{});
    defer root_dir.close(io);
    var canonical_root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const canonical_root_len = try root_dir.realPathFile(io, ".", &canonical_root_buf);
    const canonical_root = canonical_root_buf[0..canonical_root_len];
    const git_head_before = git_mod.getGitHead(root_path, allocator) catch null;

    var sources: std.ArrayList(SnapshotSource) = .empty;
    defer {
        for (sources.items) |source| if (source.resolved_path) |resolved_path| allocator.free(resolved_path);
        sources.deinit(allocator);
    }
    var source_by_path = std.StringHashMap(usize).init(allocator);
    defer source_by_path.deinit();

    var source_iter = explorer.outlines.keyIterator();
    while (source_iter.next()) |path_ptr| {
        const path = path_ptr.*;
        if (!isSafeIndexedPath(path) or path.len > std.math.maxInt(u16)) continue;

        var resolved_buf: [std.fs.max_path_bytes]u8 = undefined;
        const resolved_len = root_dir.realPathFile(io, path, &resolved_buf) catch {
            // In-memory/embedded callers legitimately snapshot virtual files.
            // They have no disk alias to follow, so retain the already-indexed
            // bytes; physical aliases still take the strict branch below.
            if (explorer.contents.get(path) == null) continue;
            const source_index = sources.items.len;
            try sources.append(allocator, .{ .path = path, .resolved_path = null });
            errdefer _ = sources.pop();
            try source_by_path.put(path, source_index);
            continue;
        };
        const resolved = resolved_buf[0..resolved_len];
        if (resolved.len <= canonical_root.len or
            !std.mem.startsWith(u8, resolved, canonical_root) or
            resolved[canonical_root.len] != '/') continue;
        const target_rel = resolved[canonical_root.len + 1 ..];
        if (!isSafeIndexedPath(target_rel)) continue;

        // Re-open the canonical target without following a final symlink. The
        // handle check makes cache/snapshot input subordinate to the live tree.
        const source_file = root_dir.openFile(io, target_rel, .{
            .allow_directory = false,
            .follow_symlinks = false,
            .resolve_beneath = true,
        }) catch continue;
        const source_stat = source_file.stat(io) catch {
            source_file.close(io);
            continue;
        };
        source_file.close(io);
        if (source_stat.kind != .file or source_stat.size > 64 * 1024 * 1024) continue;

        const owned_target = try allocator.dupe(u8, target_rel);
        errdefer allocator.free(owned_target);
        const source_index = sources.items.len;
        try sources.append(allocator, .{ .path = path, .resolved_path = owned_target });
        errdefer _ = sources.pop();
        try source_by_path.put(path, source_index);
    }

    // ── Section: META ──
    {
        const offset = file_writer.logicalPos();
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        const writer = cio.listWriter(&buf, allocator);
        var total_bytes: u64 = 0;
        for (sources.items) |source| {
            if (explorer.outlines.get(source.path)) |outline| total_bytes += outline.byte_size;
        }
        const file_count_meta: u32 = @intCast(sources.items.len);

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
        try fw.writeByte('[');
        var first = true;
        for (sources.items) |source| {
            const outline = explorer.outlines.get(source.path) orelse continue;
            if (!first) try fw.writeByte(',');
            first = false;
            try fw.writeAll("{\"path\":\"");
            try writeJsonEscaped(fw, source.path);
            try fw.print(
                \\","language":"{s}","line_count":{d},"byte_size":{d},"symbol_count":{d}}}
            , .{
                @tagName(outline.language),
                outline.line_count,
                outline.byte_size,
                outline.symbols.items.len,
            });
        }
        try fw.writeByte(']');
        const end = file_writer.logicalPos();
        try sections.append(allocator, .{ .id = @intFromEnum(SectionId.tree), .offset = offset, .length = end - offset });
    }

    // ── Section: OUTLINE_STATE ──
    {
        const offset = file_writer.logicalPos();

        var file_count_buf: [4]u8 = undefined;
        const file_count: u32 = @intCast(sources.items.len);
        std.mem.writeInt(u32, &file_count_buf, file_count, .little);
        try fw.writeAll(&file_count_buf);

        for (sources.items) |source| {
            const path = source.path;
            const outline = explorer.outlines.get(path) orelse continue;

            var path_len_buf: [2]u8 = undefined;
            std.mem.writeInt(u16, &path_len_buf, @intCast(path.len), .little);
            try fw.writeAll(&path_len_buf);
            try fw.writeAll(path);

            try fw.writeByte(@intFromEnum(outline.language));

            var line_count_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &line_count_buf, outline.line_count, .little);
            try fw.writeAll(&line_count_buf);

            var byte_size_buf: [8]u8 = undefined;
            std.mem.writeInt(u64, &byte_size_buf, outline.byte_size, .little);
            try fw.writeAll(&byte_size_buf);

            var import_count_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &import_count_buf, @intCast(outline.imports.items.len), .little);
            try fw.writeAll(&import_count_buf);
            for (outline.imports.items) |imp_full| {
                const imp = imp_full[0..@min(imp_full.len, std.math.maxInt(u16))];
                var import_len_buf: [2]u8 = undefined;
                std.mem.writeInt(u16, &import_len_buf, @intCast(imp.len), .little);
                try fw.writeAll(&import_len_buf);
                try fw.writeAll(imp);
            }

            var symbol_count_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &symbol_count_buf, @intCast(outline.symbols.items.len), .little);
            try fw.writeAll(&symbol_count_buf);
            for (outline.symbols.items) |sym| {
                // Names from minified/generated files can exceed u16 (65535) —
                // truncate the stored name instead of panicking on @intCast (P0).
                const sym_name = sym.name[0..@min(sym.name.len, std.math.maxInt(u16))];
                var name_len_buf: [2]u8 = undefined;
                std.mem.writeInt(u16, &name_len_buf, @intCast(sym_name.len), .little);
                try fw.writeAll(&name_len_buf);
                try fw.writeAll(sym_name);

                try fw.writeByte(@intFromEnum(sym.kind));

                var line_start_buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &line_start_buf, sym.line_start, .little);
                try fw.writeAll(&line_start_buf);

                var line_end_buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &line_end_buf, sym.line_end, .little);
                try fw.writeAll(&line_end_buf);

                if (sym.detail) |detail_full| {
                    const detail = detail_full[0..@min(detail_full.len, std.math.maxInt(u16))];
                    try fw.writeByte(1);
                    var detail_len_buf: [2]u8 = undefined;
                    std.mem.writeInt(u16, &detail_len_buf, @intCast(detail.len), .little);
                    try fw.writeAll(&detail_len_buf);
                    try fw.writeAll(detail);
                } else {
                    try fw.writeByte(0);
                }
            }
        }

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
        for (sources.items) |*source| {
            // Always snapshot the live file rather than a potentially stale
            // content-cache entry. Stable before/after stats plus a final pass
            // below ensure a concurrently edited tree is never published under
            // the wrong git HEAD.
            var owned_content: ?[]u8 = null;
            defer if (owned_content) |content| allocator.free(content);
            const source_content: []const u8 = if (source.resolved_path) |resolved_path| blk: {
                const source_file = try root_dir.openFile(io, resolved_path, .{
                    .allow_directory = false,
                    .follow_symlinks = false,
                    .resolve_beneath = true,
                });
                defer source_file.close(io);
                const before = try source_file.stat(io);
                if (before.kind != .file or before.size > 64 * 1024 * 1024) return error.SnapshotSourceChanged;

                const disk_content = try allocator.alloc(u8, @intCast(before.size));
                errdefer allocator.free(disk_content);
                if (try source_file.readPositionalAll(io, disk_content, 0) != disk_content.len) return error.SnapshotSourceChanged;
                const after = try source_file.stat(io);
                if (!sameSnapshotStat(before, after)) return error.SnapshotSourceChanged;

                source.inode = after.inode;
                source.size = after.size;
                source.mtime_ns = after.mtime.nanoseconds;
                source.ctime_ns = after.ctime.nanoseconds;
                owned_content = disk_content;
                break :blk disk_content;
            } else explorer.contents.get(source.path) orelse return error.SnapshotSourceChanged;

            var pl_buf: [2]u8 = undefined;
            std.mem.writeInt(u16, &pl_buf, @intCast(source.path.len), .little);
            try fw.writeAll(&pl_buf);
            try fw.writeAll(source.path);
            var cl_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &cl_buf, @intCast(source_content.len), .little);
            try fw.writeAll(&cl_buf);
            try fw.writeAll(source_content);
            try content_hashes.append(allocator, std.hash.Wyhash.hash(0, source_content));
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
        var count: u32 = 0;
        if (explorer.call_centrality) |cm| {
            var count_it = cm.keyIterator();
            while (count_it.next()) |key| if (source_by_path.contains(key.*)) {
                count += 1;
            };
        }
        var count_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &count_buf, count, .little);
        try fw.writeAll(&count_buf);
        if (explorer.call_centrality) |cm| {
            var it = cm.iterator();
            while (it.next()) |e| {
                const key = e.key_ptr.*;
                if (!source_by_path.contains(key)) continue;
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

    if (git_head_before) |head| {
        try fw.writeAll(&head);
    } else {
        try fw.writeAll(&@as([40]u8, @splat(0x00)));
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

    // Validate the complete source set immediately before publishing. This
    // catches edits, alias swaps, and commits that raced the streamed write;
    // the unique temp remains unpublished and is removed by the error defer.
    for (sources.items) |source| {
        const expected_target = source.resolved_path orelse {
            // A virtual source must remain virtual and present in the locked
            // content cache for the duration of the write.
            var appeared_buf: [std.fs.max_path_bytes]u8 = undefined;
            if (root_dir.realPathFile(io, source.path, &appeared_buf)) |_| return error.SnapshotSourceChanged else |_| {}
            if (explorer.contents.get(source.path) == null) return error.SnapshotSourceChanged;
            continue;
        };
        var resolved_buf: [std.fs.max_path_bytes]u8 = undefined;
        const resolved_len = root_dir.realPathFile(io, source.path, &resolved_buf) catch return error.SnapshotSourceChanged;
        const resolved = resolved_buf[0..resolved_len];
        if (resolved.len <= canonical_root.len or
            !std.mem.startsWith(u8, resolved, canonical_root) or
            resolved[canonical_root.len] != '/' or
            !std.mem.eql(u8, resolved[canonical_root.len + 1 ..], expected_target))
        {
            return error.SnapshotSourceChanged;
        }

        const source_file = root_dir.openFile(io, expected_target, .{
            .allow_directory = false,
            .follow_symlinks = false,
            .resolve_beneath = true,
        }) catch return error.SnapshotSourceChanged;
        const source_stat = source_file.stat(io) catch {
            source_file.close(io);
            return error.SnapshotSourceChanged;
        };
        source_file.close(io);
        if (source_stat.kind != .file or
            source_stat.inode != source.inode or
            source_stat.size != source.size or
            source_stat.mtime.nanoseconds != source.mtime_ns or
            source_stat.ctime.nanoseconds != source.ctime_ns)
        {
            return error.SnapshotSourceChanged;
        }
    }
    const git_head_after = git_mod.getGitHead(root_path, allocator) catch null;
    if (!std.meta.eql(git_head_before, git_head_after)) return error.SnapshotSourceChanged;

    file.close(io);
    file_open = false;
    // Atomic rename protects the last good snapshot. The error defer removes
    // the unique partial file if this fails or any streamed section write errs.
    try std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), output_path, io);

    // #625: the snapshot lives inside the project tree — make sure git ignores
    // it so it never pollutes `git status` or gets committed by accident.
    if (isRootSnapshot(output_path, root_path)) {
        ensureGitIgnoresSnapshot(io, root_path, allocator);
    }
}

/// True when `output_path` is the in-tree project-root snapshot
/// (`{root_path}/codedb.snapshot`), as opposed to the central ~/.codedb store.
pub fn isRootSnapshot(output_path: []const u8, root_path: []const u8) bool {
    if (root_path.len == 0) return false;
    if (!std.mem.startsWith(u8, output_path, root_path)) return false;
    return std.mem.eql(u8, output_path[root_path.len..], "/codedb.snapshot");
}

/// Append `codedb.snapshot` to the repo's `.git/info/exclude` — a local,
/// untracked ignore file — so the in-tree index is invisible to git without
/// touching the user's own `.gitignore`. Best-effort: not-a-git-repo, a git
/// worktree where `.git` is a file, permissions, or any I/O error is silently
/// skipped. Indexing must never fail because of this. Idempotent.
pub fn ensureGitIgnoresSnapshot(io: std.Io, root_path: []const u8, allocator: std.mem.Allocator) void {
    var info_buf: [std.fs.max_path_bytes]u8 = undefined;
    const info_path = std.fmt.bufPrint(&info_buf, "{s}/.git/info", .{root_path}) catch return;
    var info_dir = std.Io.Dir.cwd().openDir(io, info_path, .{}) catch return;
    defer info_dir.close(io);

    const needle = "codedb.snapshot";
    const existing: ?[]u8 = info_dir.readFileAlloc(io, "exclude", allocator, .limited(1024 * 1024)) catch null;
    defer if (existing) |e| allocator.free(e);

    if (existing) |content| {
        var it = std.mem.splitScalar(u8, content, '\n');
        while (it.next()) |line| {
            const t = std.mem.trim(u8, line, " \t\r");
            if (std.mem.eql(u8, t, needle) or std.mem.eql(u8, t, "/codedb.snapshot")) return;
        }
    }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    if (existing) |content| {
        buf.appendSlice(allocator, content) catch return;
        if (content.len > 0 and content[content.len - 1] != '\n') buf.append(allocator, '\n') catch return;
    }
    buf.appendSlice(allocator, needle) catch return;
    buf.append(allocator, '\n') catch return;

    var file = info_dir.createFile(io, "exclude", .{}) catch return;
    defer file.close(io);
    file.writeStreamingAll(io, buf.items) catch return;
}

/// Read section table from a `.codedb` file.
fn readSectionsFromFile(io: std.Io, file: std.Io.File, allocator: std.mem.Allocator) !?std.AutoHashMap(u32, SectionEntry) {
    var magic_buf: [4]u8 = undefined;
    const n = file.readPositionalAll(io, &magic_buf, 0) catch return null;
    if (n != 4 or !std.mem.eql(u8, &magic_buf, &MAGIC)) return null;

    var version_buf: [2]u8 = undefined;
    const vn = file.readPositionalAll(io, &version_buf, 4) catch return null;
    if (vn != 2 or std.mem.readInt(u16, &version_buf, .little) != FORMAT_VERSION) return null;

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

/// Validate every CONTENT record before the legacy streaming loader mutates
/// Explorer/Store. Returns the record count, or null for malformed/unsafe
/// input. Current snapshots normally use the fast loader; this keeps a crafted
/// v3 file without OUTLINE_STATE from bypassing the same path policy.
fn preflightContentRecords(io: std.Io, file: std.Io.File, entry: SectionEntry) ?u32 {
    var pos = entry.offset;
    var remaining = entry.length;
    var count: u32 = 0;
    var path_buf: [4096]u8 = undefined;

    while (remaining > 0) {
        if (remaining < 2) return null;
        var pl_buf: [2]u8 = undefined;
        if ((file.readPositionalAll(io, &pl_buf, pos) catch return null) != 2) return null;
        const path_len = std.mem.readInt(u16, &pl_buf, .little);
        if (path_len == 0 or path_len > path_buf.len) return null;
        pos += 2;
        remaining -= 2;
        if (remaining < @as(u64, path_len) + 4) return null;
        const path = path_buf[0..path_len];
        if ((file.readPositionalAll(io, path, pos) catch return null) != path_len) return null;
        if (!isSafeIndexedPath(path)) return null;
        pos += path_len;
        remaining -= path_len;

        var cl_buf: [4]u8 = undefined;
        if ((file.readPositionalAll(io, &cl_buf, pos) catch return null) != 4) return null;
        const content_len = std.mem.readInt(u32, &cl_buf, .little);
        if (content_len > 64 * 1024 * 1024) return null;
        pos += 4;
        remaining -= 4;
        if (remaining < content_len) return null;
        pos += content_len;
        remaining -= content_len;
        count +|= 1;
    }
    return count;
}

fn resolvedProjectFileIsSafe(io: std.Io, dir: std.Io.Dir, root: []const u8, path: []const u8) bool {
    _ = root;
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = dir.realPathFile(io, ".", &root_buf) catch return false;
    const canonical_root = root_buf[0..root_len];
    var resolved_buf: [std.fs.max_path_bytes]u8 = undefined;
    const resolved_len = dir.realPathFile(io, path, &resolved_buf) catch return false;
    const resolved = resolved_buf[0..resolved_len];
    if (!std.mem.startsWith(u8, resolved, canonical_root)) return false;
    if (resolved.len == canonical_root.len or resolved[canonical_root.len] != '/') return false;
    const target_rel = resolved[canonical_root.len + 1 ..];
    return isSafeIndexedPath(target_rel);
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
        return loadSnapshotFast(io, snapshot_path, expected_root, expected_file_count, explorer, store, allocator) catch false;
    }

    // Load CONTENT section — this is the core data
    const content_entry = sections.get(@intFromEnum(SectionId.content)) orelse return false;

    // Validate content section fits within actual file size (issue-40: truncation detection)
    const file_stat = file.stat(io) catch return false;
    const file_size = file_stat.size;
    if (content_entry.offset + content_entry.length > file_size) return false;

    const preflight_count = preflightContentRecords(io, file, content_entry) orelse return false;
    if (preflight_count == 0) return false;
    if (expected_file_count) |expected| {
        if (preflight_count != expected) return false;
    }

    var project_dir: ?std.Io.Dir = if (expected_root) |root|
        std.Io.Dir.cwd().openDir(io, root, .{}) catch null
    else
        null;
    defer if (project_dir) |*dir| dir.close(io);

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
        if (!isSafeIndexedPath(path_buf)) return false;
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
        if (snap_mtime > 0 and expected_root != null and project_dir != null) blk: {
            const root = expected_root.?;
            const dir = project_dir.?;
            if (!resolvedProjectFileIsSafe(io, dir, root, path_buf)) break :blk;
            // statFile (no open/close): only the mtime is needed here.
            const ds = dir.statFile(io, path_buf, .{}) catch break :blk;
            const ds_mtime: i128 = @intCast(ds.mtime.nanoseconds);
            if (ds_mtime <= snap_mtime) break :blk;
            disk_content = dir.readFileAlloc(io, path_buf, allocator, .limited(16 * 1024 * 1024)) catch break :blk;
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
        errdefer allocator.free(path);
        if (!isSafeIndexedPath(path)) return error.InvalidData;

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
            const imp = try readSectionStringBorrowed(bytes, &cursor, std.math.maxInt(u16));
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
            outline.name_len_mask |= explore_mod.FileOutline.nameLenBit(name.len);
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

    // Dedup like Explorer.rebuildDepsFor: a file importing the same module more
    // than once (e.g. ../foo for both a type and a value) must not produce
    // duplicate forward edges, so a snapshot-restored graph matches a fresh one.
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    for (outline.imports.items) |imp| {
        // Same resolution as Explorer.rebuildDepsFor: relative specifiers
        // resolve to repo paths so restored deps match a freshly-indexed graph.
        const dep = (try explore_mod.resolveDependencyKey(&explorer.dep_graph, outline.path, imp, allocator)) orelse continue;
        const gop = try seen.getOrPut(dep);
        if (gop.found_existing) continue;
        deps.appendAssumeCapacity(dep);
    }

    try explorer.dep_graph.setDeps(path, deps);
}

// Process max-RSS in bytes (macOS getrusage reports bytes; Linux reports KiB).
// Profiler-only: attribution of load-phase memory growth, not a public API.
fn loadMaxRssBytes() u64 {
    if (@import("builtin").os.tag == .windows) {
        // getrusage is POSIX-only; RSS profiling is unavailable on Windows.
        return 0;
    } else {
        var ru: std.c.rusage = undefined;
        if (std.c.getrusage(0, &ru) != 0) return 0;
        const raw: u64 = @intCast(@max(0, ru.maxrss));
        return if (@import("builtin").os.tag == .linux) raw * 1024 else raw;
    }
}
// Written only when `load_prof` is set by loadSnapshotFast; the loader is
// single-threaded so plain vars are safe.
var load_prof: bool = false;
var prof_content_ns: i128 = 0;
var prof_deps_ns: i128 = 0;
var prof_symidx_ns: i128 = 0;

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
    const t_content: i128 = if (load_prof) cio.nanoTimestamp() else 0;
    if (borrow_content) {
        try explorer.contents.putBorrowed(path, content);
    } else {
        try explorer.contents.put(path, content);
    }
    if (load_prof) prof_content_ns += cio.nanoTimestamp() - t_content;

    const t_deps: i128 = if (load_prof) cio.nanoTimestamp() else 0;
    try rebuildDepsFromOutline(explorer, path, &restored_outline, allocator);
    if (load_prof) prof_deps_ns += cio.nanoTimestamp() - t_deps;

    // Mirror commitParsedFileOwnedOutline (explore.zig:872): symbol_index is built
    // eagerly on every ingest and has NO lazy rebuild trigger. resolveCallees reads
    // it without a fallback (#524 perf note), so restored files must populate it
    // here or call-graph edges into them are lost after a snapshot load. had_prior
    // is false: insertRestoredFile errors above if the path already exists.
    const t_symidx: i128 = if (load_prof) cio.nanoTimestamp() else 0;
    explorer.rebuildSymbolIndexFor(path, &restored_outline, false);
    if (load_prof) prof_symidx_ns += cio.nanoTimestamp() - t_symidx;

    // Restored files are absent from word_index and trigram_index at load time
    // (both are rebuilt lazily/incrementally). Register the path in
    // skip_trigram_files so searchContent's Tier 3 scans its content; without
    // this the file falls out of every search tier the moment the trigram index
    // is non-empty (Tier 5's full scan is then ruled out). Mirrors the
    // outline-only branch of commitParsedFileOwnedOutline. See #507 / #537.
    // Bypasses putSkipTrigram (no content-derived bloom is computed on this
    // fast-load path), so its null-bloom bookkeeping is mirrored by hand:
    // skip_bloom_null_count must count this entry or the tier-3/tier-5
    // union short-circuit in searchContentUncached could wrongly treat a
    // restored file's content as covered by the union.
    try explorer.skip_trigram_files.put(path, null);
    explorer.skip_bloom_null_count += 1;
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
fn freshnessScan(io: std.Io, root: ?[]const u8, snap_mtime: i128, recs: []const LoadRecord, out: []LoadFreshness) void {
    const project_root = root orelse return;
    var dir = std.Io.Dir.cwd().openDir(io, project_root, .{}) catch return;
    defer dir.close(io);
    for (recs, out) |record, *fr| {
        if (!resolvedProjectFileIsSafe(io, dir, project_root, record.path)) continue;
        const ds = dir.statFile(io, record.path, .{}) catch continue;
        const ds_mtime: i128 = @intCast(ds.mtime.nanoseconds);
        if (ds_mtime > snap_mtime) fr.stale = true;
    }
}

fn loadSnapshotFast(
    io: std.Io,
    snapshot_path: []const u8,
    expected_root: ?[]const u8,
    expected_file_count: ?u32,
    explorer: *Explorer,
    store: *Store,
    allocator: std.mem.Allocator,
) !bool {
    // Optional phase profiler (CODEDB_LOAD_PROFILE): prints a load breakdown to
    // stderr. Near-zero cost when off (one getenv + a few timestamps).
    const prof = cio.posixGetenv("CODEDB_LOAD_PROFILE") != null;
    load_prof = prof;
    prof_content_ns = 0;
    prof_deps_ns = 0;
    prof_symidx_ns = 0;
    const rss0: u64 = if (prof) loadMaxRssBytes() else 0;
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

    const rss_outline: u64 = if (prof) loadMaxRssBytes() else 0;
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
        if (cio.mmapReadonly(content_file.handle, fsize)) |m| {
            if (explorer.adoptContentSection(m)) {
                content_borrowed = true;
                break :section_blk m[sec_base..][0..sec_len];
            } else |_| {
                cio.munmap(m);
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
            if (sc + 2 > section.len) return false;
            const path_len = std.mem.readInt(u16, section[sc..][0..2], .little);
            sc += 2;
            if (path_len == 0 or path_len > 4096) return false;
            if (sc + path_len > section.len) return false;
            const path = section[sc..][0..path_len];
            sc += path_len;
            if (!isSafeIndexedPath(path)) return false;

            if (sc + 4 > section.len) return false;
            const content_len = std.mem.readInt(u32, section[sc..][0..4], .little);
            sc += 4;
            if (content_len > 64 * 1024 * 1024 or sc + content_len > section.len) return false;
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
            records.append(allocator, .{ .path = path, .content = content, .stored_hash = stored_hash }) catch return false;
            rec_idx += 1;
        }
    }
    if (records.items.len == 0) return false;
    if (expected_file_count) |expected| {
        if (records.items.len != expected) return false;
    }

    // Borrowed mmap slices cost no content bytes, so retain the whole restored
    // set instead of letting the small daemon default (4096 slots) evict large
    // repositories during Pass C. Four slots per file keeps the fixed 8-probe
    // windows sparse while adding only slot metadata, not duplicate contents.
    if (content_borrowed) {
        const wanted_slots = std.math.mul(usize, records.items.len, 4) catch return false;
        if (wanted_slots > std.math.maxInt(u32)) return false;
        explorer.contents.ensureCapacity(@intCast(@max(@as(usize, 1), wanted_slots))) catch return false;
    }

    const rss_recs: u64 = if (prof) loadMaxRssBytes() else 0;
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
            freshnessScan(io, expected_root, snap_mtime, records.items, fresh_results);
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
                    freshnessScan(io, expected_root, snap_mtime, recs, out);
                    continue;
                }
                if (std.Thread.spawn(.{}, freshnessScan, .{ io, expected_root, snap_mtime, recs, out })) |t| {
                    threads[spawned] = t;
                    spawned += 1;
                } else |_| {
                    // Out of threads: scan this chunk (and any remaining) inline.
                    freshnessScan(io, expected_root, snap_mtime, recs, out);
                    spawn_failed = true;
                }
            }
            for (threads[0..spawned]) |t| t.join();
        } else |_| {
            freshnessScan(io, expected_root, snap_mtime, records.items, fresh_results);
        }
    }
    if (prof) fresh_ns += cio.nanoTimestamp() - t_fresh0;
    const rss_fresh: u64 = if (prof) loadMaxRssBytes() else 0;
    // ── Pass C: insert restored / changed / outline-only files (sequential). ──
    // #564: defer the global symbol index — Pass C's per-file rebuilds become
    // no-ops and ensureSymbolIndex builds it from outlines on first
    // symbol/caller/callpath use. Plain search never needs it, so one-shot
    // CLI queries skip the inserts and their heap entirely.
    explorer.markSymbolIndexIncomplete();
    var insert_ns: i128 = 0;
    var store_ns: i128 = 0;
    var project_dir: ?std.Io.Dir = if (expected_root) |root|
        std.Io.Dir.cwd().openDir(io, root, .{}) catch null
    else
        null;
    defer if (project_dir) |*dir| dir.close(io);
    for (records.items, fresh_results) |record, fr| {
        const path = record.path;
        const content = record.content;
        // A file flagged stale was edited after the snapshot: re-read its fresh
        // content from disk and re-index it. Read here (not in the parallel scan) so
        // peak memory is one file's content, not every changed file's at once.
        var disk_content: ?[]u8 = null;
        if (fr.stale and project_dir != null) {
            disk_content = project_dir.?.readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024)) catch null;
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
            const t_ins: i128 = if (prof) cio.nanoTimestamp() else 0;
            insertRestoredFile(explorer, removed.key, content, removed.value, allocator, content_borrowed) catch {
                allocator.free(removed.key);
                var bad_outline = removed.value;
                bad_outline.deinit();
                continue;
            };
            if (prof) insert_ns += cio.nanoTimestamp() - t_ins;
            const hash = record.stored_hash orelse std.hash.Wyhash.hash(0, content);
            const t_st: i128 = if (prof) cio.nanoTimestamp() else 0;
            _ = store.recordSnapshot(removed.key, content.len, hash) catch {};
            if (prof) store_ns += cio.nanoTimestamp() - t_st;
        } else {
            word_index_can_load_from_disk = false;
            explorer.indexFileOutlineOnly(path, content) catch continue;
            const hash = record.stored_hash orelse std.hash.Wyhash.hash(0, content);
            _ = store.recordSnapshot(path, content.len, hash) catch {};
        }

        file_count += 1;
    }

    const rss_insert: u64 = if (prof) loadMaxRssBytes() else 0;
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
        std.debug.print(
            "[load-profile]   insert={d:.1}ms (content={d:.1}ms, deps={d:.1}ms, symidx={d:.1}ms, other={d:.1}ms)  store={d:.1}ms\n",
            .{ ms(insert_ns), ms(prof_content_ns), ms(prof_deps_ns), ms(prof_symidx_ns), ms(insert_ns - prof_content_ns - prof_deps_ns - prof_symidx_ns), ms(store_ns) },
        );
        const mb = struct {
            fn f(b: u64) f64 {
                return @as(f64, @floatFromInt(b)) / (1024.0 * 1024.0);
            }
        }.f;
        const rss_end = loadMaxRssBytes();
        std.debug.print(
            "[load-profile]   maxrss: start={d:.1}MB +outline={d:.1}MB +records={d:.1}MB +freshness={d:.1}MB +insert={d:.1}MB +tail={d:.1}MB end={d:.1}MB\n",
            .{ mb(rss0), mb(rss_outline -| rss0), mb(rss_recs -| rss_outline), mb(rss_fresh -| rss_recs), mb(rss_insert -| rss_fresh), mb(rss_end -| rss_insert), mb(rss_end) },
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

/// A path admitted to a snapshot/index must be a canonical project-relative
/// path. Snapshot files are cache inputs, not trusted authority: rejecting
/// traversal and generated/sensitive state here prevents a crafted cache from
/// turning freshness checks into outside-project reads.
pub const isSafeIndexedPath = path_policy.isSafeIndexedPath;

/// Returns true for secret/credential paths that must never be persisted to a
/// snapshot or live-indexed. Single implementation of this security filter;
/// `watcher.isSensitivePath` delegates here (parity-tested in test_snapshot.zig
/// "issue-528: isSensitivePath parity").
pub const isSensitivePath = path_policy.isSensitivePath;
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
    // The project-cache copy is the same bytes — clone the file just written
    // instead of re-running the whole serialization (which re-reads and
    // re-hashes every file when contents were released, and forks git
    // rev-parse a second time). writeSnapshot already did tmp+rename, so
    // output_path is complete; the copy goes through its own tmp+rename to
    // keep the secondary crash-safe. Sharing one indexed_at/git_head between
    // the two copies is more correct than the old double-serialize, which
    // could capture different values.
    copyToProjectCache(io, root_path, output_path, allocator) catch {};
}

fn copyToProjectCache(io: std.Io, root_path: []const u8, primary_path: []const u8, allocator: std.mem.Allocator) !void {
    const hash = std.hash.Wyhash.hash(0, root_path);
    const home_raw = cio.homeDir() orelse return;
    const home = allocator.dupe(u8, home_raw) catch return;
    defer allocator.free(home);
    const dir_path = std.fmt.allocPrint(allocator, "{s}/.codedb/projects/{x}", .{ home, hash }) catch return;
    defer allocator.free(dir_path);
    std.Io.Dir.cwd().createDirPath(io, dir_path) catch {};

    const proj_txt = std.fmt.allocPrint(allocator, "{s}/project.txt", .{dir_path}) catch return;
    defer allocator.free(proj_txt);
    var f = try std.Io.Dir.cwd().createFile(io, proj_txt, .{ .truncate = true });
    f.writeStreamingAll(io, root_path) catch {};
    f.close(io);

    const tmp = std.fmt.allocPrint(allocator, "{s}/codedb.snapshot.{x}.tmp", .{ dir_path, cio.randU64() }) catch return;
    defer allocator.free(tmp);
    const secondary = std.fmt.allocPrint(allocator, "{s}/codedb.snapshot", .{dir_path}) catch return;
    defer allocator.free(secondary);
    errdefer std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
    try std.Io.Dir.copyFile(std.Io.Dir.cwd(), primary_path, std.Io.Dir.cwd(), tmp, io, .{});
    try std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), secondary, io);
}

pub fn writeProjectCacheSnapshot(
    io: std.Io,
    explorer: *Explorer,
    root_path: []const u8,
    allocator: std.mem.Allocator,
) !void {
    const hash = std.hash.Wyhash.hash(0, root_path);
    const home_raw = cio.homeDir() orelse return;
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
