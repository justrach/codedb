const std = @import("std");
const cio = @import("cio.zig");

pub const REMOTE_CACHE_TTL_SECONDS: i64 = 7 * 24 * 60 * 60;
pub const MAX_CACHED_REPOS: usize = 50;

pub fn getRemoteCacheDir(alloc: std.mem.Allocator, wiki_slug: []const u8) ?[]u8 {
    const home = cio.posixGetenv("HOME") orelse return null;
    return std.fmt.allocPrint(alloc, "{s}/.codedb/remote-cache/{s}", .{ home, wiki_slug }) catch null;
}

pub fn isCacheFresh(io: std.Io, cache_dir: []const u8, ttl_seconds: i64) bool {
    var snap_buf: [std.fs.max_path_bytes]u8 = undefined;
    const snap_path = std.fmt.bufPrint(&snap_buf, "{s}/codedb.snapshot", .{cache_dir}) catch return false;
    const stat = std.Io.Dir.cwd().statFile(io, snap_path, .{}) catch return false;
    const mtime_ns: i128 = @intCast(stat.mtime.nanoseconds);
    const now_ns = cio.nanoTimestamp();
    const age_s = @divTrunc(now_ns - mtime_ns, std.time.ns_per_s);
    return age_s < ttl_seconds;
}

pub fn isCacheValid(io: std.Io, cache_dir: []const u8) bool {
    var snap_buf: [std.fs.max_path_bytes]u8 = undefined;
    const snap_path = std.fmt.bufPrint(&snap_buf, "{s}/codedb.snapshot", .{cache_dir}) catch return false;
    std.Io.Dir.cwd().access(io, snap_path, .{}) catch return false;
    return true;
}

pub const EnsureResult = enum {
    ready,
    clone_failed,
    index_failed,
    no_github_url,
};

pub fn ensureCached(
    io: std.Io,
    alloc: std.mem.Allocator,
    repo: []const u8,
    wiki_slug: []const u8,
) EnsureResult {
    const cache_dir = getRemoteCacheDir(alloc, wiki_slug) orelse return .clone_failed;
    defer alloc.free(cache_dir);

    if (isCacheValid(io, cache_dir)) return .ready;

    if (std.mem.indexOfScalar(u8, repo, '/') == null) return .no_github_url;

    std.Io.Dir.cwd().createDirPath(io, cache_dir) catch {};

    const clone_url = std.fmt.allocPrint(alloc, "https://github.com/{s}.git", .{repo}) catch return .clone_failed;
    defer alloc.free(clone_url);

    const clone_result = cio.runCapture(.{
        .allocator = alloc,
        .argv = &.{ "git", "clone", "--depth=1", "--quiet", clone_url, cache_dir },
        .max_output_bytes = 4 * 1024,
    }) catch return .clone_failed;
    defer alloc.free(clone_result.stdout);
    defer alloc.free(clone_result.stderr);

    if (clone_result.term.Exited != 0) {
        std.Io.Dir.cwd().deleteTree(io, cache_dir) catch {};
        return .clone_failed;
    }

    const exe_path = std.process.executablePathAlloc(io, alloc) catch return .index_failed;
    defer alloc.free(exe_path);

    var snap_buf: [std.fs.max_path_bytes]u8 = undefined;
    const snap_path = std.fmt.bufPrint(&snap_buf, "{s}/codedb.snapshot", .{cache_dir}) catch return .index_failed;

    const index_result = cio.runCapture(.{
        .allocator = alloc,
        .argv = &.{ exe_path, cache_dir, "snapshot", snap_path },
        .max_output_bytes = 64 * 1024,
    }) catch return .index_failed;
    defer alloc.free(index_result.stdout);
    defer alloc.free(index_result.stderr);

    if (index_result.term.Exited != 0) return .index_failed;

    return .ready;
}

pub fn cleanRemoteCache(io: std.Io, alloc: std.mem.Allocator) !u32 {
    const home = cio.posixGetenv("HOME") orelse return error.NoHome;
    const cache_root = std.fmt.allocPrint(alloc, "{s}/.codedb/remote-cache", .{home}) catch return error.OutOfMemory;
    defer alloc.free(cache_root);

    var dir = std.Io.Dir.cwd().openDir(io, cache_root, .{ .iterate = true }) catch return 0;
    defer dir.close(io);

    var count: u32 = 0;
    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ cache_root, entry.name }) catch continue;
        std.Io.Dir.cwd().deleteTree(io, full_path) catch continue;
        count += 1;
    }
    return count;
}

pub fn cleanStaleEntries(io: std.Io, alloc: std.mem.Allocator, ttl_seconds: i64) !u32 {
    const home = cio.posixGetenv("HOME") orelse return error.NoHome;
    const cache_root = std.fmt.allocPrint(alloc, "{s}/.codedb/remote-cache", .{home}) catch return error.OutOfMemory;
    defer alloc.free(cache_root);

    var dir = std.Io.Dir.cwd().openDir(io, cache_root, .{ .iterate = true }) catch return 0;
    defer dir.close(io);

    var count: u32 = 0;
    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ cache_root, entry.name }) catch continue;
        if (isEntryStale(io, full_path, ttl_seconds)) {
            std.Io.Dir.cwd().deleteTree(io, full_path) catch continue;
            count += 1;
        }
    }
    return count;
}

fn isEntryStale(io: std.Io, cache_dir: []const u8, ttl_seconds: i64) bool {
    var snap_buf: [std.fs.max_path_bytes]u8 = undefined;
    const snap_path = std.fmt.bufPrint(&snap_buf, "{s}/codedb.snapshot", .{cache_dir}) catch return true;
    const stat = std.Io.Dir.cwd().statFile(io, snap_path, .{}) catch return true;
    const mtime_ns: i128 = @intCast(stat.mtime.nanoseconds);
    const now_ns = cio.nanoTimestamp();
    const age_s = @divTrunc(now_ns - mtime_ns, std.time.ns_per_s);
    return age_s > ttl_seconds;
}
