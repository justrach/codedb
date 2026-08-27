// reader.md — agent-authored, hash-stable codebase map.
//
// On a codedb_context call we look for `.codedb/reader.md` under the project
// root. If found AND the embedded blake2b source_hash still matches the
// current contents of the listed source_files, the file's body is prepended
// to the codedb_context response (giving the agent one-shot orientation
// without 5-10 exploratory search calls).
//
// If missing or stale, codedb emits a "regenerate" hint instead. The agent
// is expected to write a fresh reader.md (see experiments/reader-md/SPEC.md).
//
// This module is intentionally tiny: parse minimal YAML frontmatter, run
// blake2b over sorted source-file contents, no third-party deps.

const std = @import("std");
const project_file = @import("project_file.zig");
const project_path = @import("project_path.zig");

pub const State = enum { ready, stale, missing, malformed };

pub const Reader = struct {
    state: State,
    /// Hash declared in frontmatter (when present).
    declared_hash: ?[]const u8 = null,
    /// Hash freshly computed over current source_files (when present).
    computed_hash: ?[]const u8 = null,
    /// Body (after `---\n` separator) — caller-owned slice into raw.
    body: ?[]const u8 = null,
    /// Validated project-relative source paths. Each string borrows from raw;
    /// the slice itself is caller-owned and freed by free().
    source_files: []const []const u8 = &.{},
    /// Whole file contents (caller frees via free()).
    raw: []const u8 = "",

    pub fn free(self: *Reader, allocator: std.mem.Allocator) void {
        if (self.source_files.len > 0) allocator.free(self.source_files);
        if (self.raw.len > 0) allocator.free(self.raw);
        if (self.declared_hash) |h| allocator.free(h);
        if (self.computed_hash) |h| allocator.free(h);
    }
};

fn isWithinProject(root: []const u8, candidate: []const u8) bool {
    if (!std.mem.startsWith(u8, candidate, root)) return false;
    if (candidate.len == root.len) return true;
    return root.len > 0 and (std.fs.path.isSep(root[root.len - 1]) or std.fs.path.isSep(candidate[root.len]));
}

/// Load and validate `<project_root>/.codedb/reader.md` against the source_files
/// listed in its frontmatter. The blake2b computation matches the canonical
/// Python algorithm from experiments/reader-md/SPEC.md:
///
///   for f in sorted(source_files):
///       h.update(f); h.update(0); h.update(open(f).read()); h.update(0 0)
///   "blake2b:" + hex(h.digest(16))
///
/// Returns a Reader with state=missing if the file doesn't exist, state=malformed
/// if the frontmatter can't be parsed, state=stale if the hash drifted, or
/// state=ready (with body set) if everything checks out.
pub fn load(io: std.Io, allocator: std.mem.Allocator, project_root: []const u8) !Reader {
    var root_dir = std.Io.Dir.cwd().openDir(io, project_root, .{ .follow_symlinks = false }) catch {
        return .{ .state = .missing };
    };
    defer root_dir.close(io);

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = root_dir.realPathFile(io, ".", &root_buf) catch return .{ .state = .missing };
    return loadFromRoot(io, allocator, root_dir, root_buf[0..root_len]);
}

pub fn loadFromRoot(io: std.Io, allocator: std.mem.Allocator, root_dir: std.Io.Dir, canonical_root: []const u8) !Reader {
    const raw = project_file.readAllocNoFollowAtRoot(io, root_dir, canonical_root, ".codedb/reader.md", allocator, .limited(64 * 1024)) catch {
        return .{ .state = .missing };
    };
    errdefer allocator.free(raw);

    // Frontmatter shape:
    //   ---\n
    //   key: value\n
    //   source_files:\n
    //     - path/a\n
    //     - path/b\n
    //   ...
    //   ---\n
    //   <body>
    if (!std.mem.startsWith(u8, raw, "---\n")) {
        return .{ .state = .malformed, .raw = raw };
    }
    const after_open = raw[4..];
    const fm_end = std.mem.indexOf(u8, after_open, "\n---\n") orelse {
        return .{ .state = .malformed, .raw = raw };
    };
    const fm = after_open[0..fm_end];
    const body_start = 4 + fm_end + 5;
    const body = if (body_start < raw.len) raw[body_start..] else "";

    // Parse declared source_hash + source_files list.
    var declared_hash_opt: ?[]const u8 = null;
    errdefer if (declared_hash_opt) |h| allocator.free(h);
    var source_files: std.ArrayList([]const u8) = .empty;
    defer source_files.deinit(allocator);

    var in_source_files = false;
    var lines = std.mem.splitScalar(u8, fm, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimEnd(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        // List item under `source_files:`
        if (in_source_files and (std.mem.startsWith(u8, trimmed, "  - ") or std.mem.startsWith(u8, trimmed, "- "))) {
            const after_dash = if (std.mem.startsWith(u8, trimmed, "  - ")) trimmed[4..] else trimmed[2..];
            const path = std.mem.trim(u8, after_dash, " \"'");
            if (path.len > 0) {
                // Use the same normalized-relative and sensitive-name policy
                // as MCP/CLI/HTTP reads; hostile frontmatter cannot widen the
                // repository content boundary.
                if (!project_path.isReadable(path)) {
                    return .{ .state = .malformed, .raw = raw, .declared_hash = declared_hash_opt };
                }
                // P1 fix (review I02): cap source_files at 20 entries. A
                // reader.md is allowed up to 64 KB; without this cap a
                // crafted file could list ~600 entries × 8 MB read each
                // = ~5 GB of allocations on every codedb_context call.
                if (source_files.items.len >= 20) {
                    return .{ .state = .malformed, .raw = raw, .declared_hash = declared_hash_opt };
                }
                try source_files.append(allocator, path);
            }
            continue;
        }
        in_source_files = false;
        // key: value
        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
        const key = std.mem.trim(u8, trimmed[0..colon], " \t");
        const val = std.mem.trim(u8, trimmed[colon + 1 ..], " \t\"'");
        if (std.mem.eql(u8, key, "source_hash")) {
            declared_hash_opt = try allocator.dupe(u8, val);
        } else if (std.mem.eql(u8, key, "source_files")) {
            in_source_files = true;
        } else if (std.mem.eql(u8, key, "loc_actual")) {
            // P2 fix (review I03): enforce loc_budget × 1.2 ceiling per SPEC.
            // The 64 KB raw cap was the only size check before; an agent that
            // ignored the 200-LOC budget could prepend ~1500 lines on every
            // call, inverting the efficiency win on small-context models.
            const loc_actual = std.fmt.parseInt(u32, val, 10) catch continue;
            if (loc_actual > 240) {
                return .{ .state = .malformed, .raw = raw, .declared_hash = declared_hash_opt };
            }
        }
    }

    if (declared_hash_opt == null or source_files.items.len == 0) {
        return .{ .state = .malformed, .raw = raw, .declared_hash = declared_hash_opt };
    }

    // Sort source_files lexicographically — must match Python's sorted().
    std.mem.sort([]const u8, source_files.items, {}, struct {
        pub fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    const stored_source_files = try source_files.toOwnedSlice(allocator);
    errdefer allocator.free(stored_source_files);

    // Resolve each source before reading it. Lexically relative paths can still
    // escape through symlinks, so require the canonical target to remain under
    // the canonical project root and read that checked path.
    // Compute blake2b(16) over: for each f, f.bytes ++ 0x00 ++ file_contents ++ 0x00 0x00
    var h = std.crypto.hash.blake2.Blake2b128.init(.{});
    for (stored_source_files) |rel| {
        var source_buf: [std.fs.max_path_bytes]u8 = undefined;
        const source_len = root_dir.realPathFile(io, rel, &source_buf) catch {
            // Listed file is gone — definitionally stale.
            return .{
                .state = .stale,
                .raw = raw,
                .declared_hash = declared_hash_opt,
                .body = body,
                .source_files = stored_source_files,
            };
        };
        const canonical_source = source_buf[0..source_len];
        if (!isWithinProject(canonical_root, canonical_source)) {
            return .{
                .state = .malformed,
                .raw = raw,
                .declared_hash = declared_hash_opt,
                .body = body,
                .source_files = stored_source_files,
            };
        }
        const data = project_file.readAllocNoFollowAtRoot(io, root_dir, canonical_root, rel, allocator, .limited(8 * 1024 * 1024)) catch {
            return .{
                .state = .stale,
                .raw = raw,
                .declared_hash = declared_hash_opt,
                .body = body,
                .source_files = stored_source_files,
            };
        };
        defer allocator.free(data);
        h.update(rel);
        h.update(&[_]u8{0});
        h.update(data);
        h.update(&[_]u8{ 0, 0 });
    }
    var digest: [16]u8 = undefined;
    h.final(&digest);

    var hex_buf: [40]u8 = undefined;
    const hex_n = std.fmt.bufPrint(&hex_buf, "blake2b:{x}", .{digest}) catch return error.OutOfMemory;
    const computed = try allocator.dupe(u8, hex_n);
    errdefer allocator.free(computed);

    const declared = declared_hash_opt.?;
    const matches = std.mem.eql(u8, declared, computed);

    return .{
        .state = if (matches) .ready else .stale,
        .declared_hash = declared_hash_opt,
        .computed_hash = computed,
        .body = body,
        .source_files = stored_source_files,
        .raw = raw,
    };
}

test "issue-688: missing source_hash is malformed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".codedb");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = ".codedb/reader.md",
        .data = "---\nsource_files:\n  - source.zig\n---\nbody\n",
    });

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPathFile(std.testing.io, ".", &root_buf);
    var reader = try load(std.testing.io, std.testing.allocator, root_buf[0..root_len]);
    defer reader.free(std.testing.allocator);
    try std.testing.expectEqual(State.malformed, reader.state);
}

test "issue-688: source symlink outside project is malformed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "project/.codedb");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "outside.zig", .data = "secret\n" });
    var project_dir = try tmp.dir.openDir(std.testing.io, "project", .{});
    defer project_dir.close(std.testing.io);
    project_dir.symLink(std.testing.io, "../outside.zig", "escape.zig", .{}) catch |err| switch (err) {
        error.AccessDenied => return error.SkipZigTest,
        else => return err,
    };
    try project_dir.writeFile(std.testing.io, .{
        .sub_path = ".codedb/reader.md",
        .data = "---\nsource_hash: blake2b:00000000000000000000000000000000\nsource_files:\n  - escape.zig\n---\nbody\n",
    });

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try project_dir.realPathFile(std.testing.io, ".", &root_buf);
    var reader = try load(std.testing.io, std.testing.allocator, root_buf[0..root_len]);
    defer reader.free(std.testing.allocator);
    try std.testing.expectEqual(State.malformed, reader.state);
}

test "reader file symlink is not followed" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "project/.codedb");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "outside-reader.md", .data = "---\nsource_hash: x\nsource_files:\n  - source.zig\n---\nSECRET_READER_BODY\n" });
    var project_dir = try tmp.dir.openDir(std.testing.io, "project", .{});
    defer project_dir.close(std.testing.io);
    project_dir.symLink(std.testing.io, "../../outside-reader.md", ".codedb/reader.md", .{}) catch |err| switch (err) {
        error.AccessDenied => return error.SkipZigTest,
        else => return err,
    };
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try project_dir.realPathFile(std.testing.io, ".", &root_buf)];
    var reader = try load(std.testing.io, std.testing.allocator, root);
    defer reader.free(std.testing.allocator);
    try std.testing.expectEqual(State.missing, reader.state);
    try std.testing.expect(std.mem.indexOf(u8, reader.raw, "SECRET_READER_BODY") == null);
}

test "reader declared sensitive source is malformed without reading it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".codedb");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".env", .data = "DECLARED_SOURCE_SECRET\n" });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = ".codedb/reader.md",
        .data = "---\nsource_hash: blake2b:00000000000000000000000000000000\nsource_files:\n  - .env\n---\nbody\n",
    });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPathFile(std.testing.io, ".", &root_buf)];
    var reader = try load(std.testing.io, std.testing.allocator, root);
    defer reader.free(std.testing.allocator);
    try std.testing.expectEqual(State.malformed, reader.state);
    try std.testing.expect(reader.computed_hash == null);
}

test "blake2b: byte-for-byte parity with canonical Python algorithm" {
    // Lock the hash-protocol contract against drift. The golden digest below
    // was produced by:
    //
    //   python3 -c "
    //   import hashlib
    //   h = hashlib.blake2b(digest_size=16)
    //   h.update(b'a.txt'); h.update(b'\0')
    //   h.update(b'hello'); h.update(b'\0\0')
    //   print(h.hexdigest())"
    //   # → 3768d3b5cda868e1d504d5c0417f7818
    //
    // If Zig's `{x}` formatting for [N]u8 ever changes, or if std.crypto's
    // Blake2b128 disagrees with Python's blake2b(digest_size=16), this test
    // catches it before every reader.md silently goes stale.
    var h = std.crypto.hash.blake2.Blake2b128.init(.{});
    h.update("a.txt");
    h.update(&[_]u8{0});
    h.update("hello");
    h.update(&[_]u8{ 0, 0 });
    var digest: [16]u8 = undefined;
    h.final(&digest);
    var hex_buf: [32]u8 = undefined;
    const hex = std.fmt.bufPrint(&hex_buf, "{x}", .{digest}) catch unreachable;
    try std.testing.expectEqualStrings("3768d3b5cda868e1d504d5c0417f7818", hex);
}
