const std = @import("std");
const cio = @import("cio.zig");

pub const REMOTE_CACHE_TTL_SECONDS: i64 = 7 * 24 * 60 * 60;
pub const MAX_CACHED_REPOS: usize = 50;

/// Largest GitHub-reported repo size we are willing to pull into ~/.codedb.
/// GitHub reports `size` in KiB. The clone runs inline on the MCP request
/// that triggered the fallback, so an unbounded monorepo would block that
/// request for tens of minutes and write multi-GB with nothing stopping it.
pub const MAX_CLONE_SIZE_KB: u64 = 2 * 1024 * 1024;

/// Records which `owner/repo` populated a cache dir. The wiki slug is lossy —
/// vercel/next.js, vercel/next-js and vercel-next/js all collapse onto
/// "vercel-next-js" — so without this a fresh cache would serve one repo's
/// source labelled as another's.
pub const origin_marker_name = ".codedb-remote-origin";

/// Present while a clone/index is still running. The sweepers leave a marked
/// directory alone until the grace period expires, so a second codedb process
/// cannot deleteTree another one's half-finished work.
pub const inflight_marker_name = ".codedb-remote-inflight";
const INFLIGHT_GRACE_SECONDS: i64 = 60 * 60;

const CLONE_LOW_SPEED_LIMIT = "1000";
const CLONE_LOW_SPEED_TIME = "30";

pub fn getRemoteCacheDir(alloc: std.mem.Allocator, wiki_slug: []const u8) ?[]u8 {
    const home = cio.posixGetenv("HOME") orelse return null;
    return std.fmt.allocPrint(alloc, "{s}/.codedb/remote-cache/{s}", .{ home, wiki_slug }) catch null;
}

fn getCacheRoot(alloc: std.mem.Allocator) ?[]u8 {
    const home = cio.posixGetenv("HOME") orelse return null;
    return std.fmt.allocPrint(alloc, "{s}/.codedb/remote-cache", .{home}) catch null;
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

/// True when `cache_dir` records exactly `repo` as the repository it was
/// cloned from. A cache with no recorded origin never matches, so entries
/// written by older builds are re-cloned once instead of trusted blind.
pub fn cachedOriginMatches(io: std.Io, alloc: std.mem.Allocator, cache_dir: []const u8, repo: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ cache_dir, origin_marker_name }) catch return false;
    const txt = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(4096)) catch return false;
    defer alloc.free(txt);
    return std.mem.eql(u8, std.mem.trim(u8, txt, " \t\r\n"), repo);
}

pub const EnsureResult = enum {
    ready,
    clone_failed,
    index_failed,
    no_github_url,
    too_large,
};

/// Make `wiki_slug`'s cache dir hold a fresh clone of `repo`. `refreshed` is
/// set when the directory was actually re-created, so callers can drop any
/// snapshot they had mmapped from the previous contents.
pub fn ensureCached(
    io: std.Io,
    alloc: std.mem.Allocator,
    repo: []const u8,
    wiki_slug: []const u8,
    refreshed: *bool,
) EnsureResult {
    refreshed.* = false;

    const cache_dir = getRemoteCacheDir(alloc, wiki_slug) orelse return .clone_failed;
    defer alloc.free(cache_dir);

    if (cachedOriginMatches(io, alloc, cache_dir, repo) and
        isCacheFresh(io, cache_dir, REMOTE_CACHE_TTL_SECONDS)) return .ready;

    if (std.mem.indexOfScalar(u8, repo, '/') == null) return .no_github_url;

    evictIfNeeded(io, alloc, wiki_slug);

    const cache_root = getCacheRoot(alloc) orelse return .clone_failed;
    defer alloc.free(cache_root);
    std.Io.Dir.cwd().createDirPath(io, cache_root) catch {};

    if (repoExceedsCloneBudget(alloc, repo)) return .too_large;

    const tmp_dir = std.fmt.allocPrint(alloc, "{s}.tmp.{d}", .{ cache_dir, @as(u64, @bitCast(cio.milliTimestamp())) }) catch return .clone_failed;
    defer alloc.free(tmp_dir);

    const clone_url = std.fmt.allocPrint(alloc, "https://github.com/{s}.git", .{repo}) catch return .clone_failed;
    defer alloc.free(clone_url);

    const clone_result = cio.runCapture(.{
        .allocator = alloc,
        .argv = &.{
            "git",
            "-c", "http.lowSpeedLimit=" ++ CLONE_LOW_SPEED_LIMIT,
            "-c", "http.lowSpeedTime=" ++ CLONE_LOW_SPEED_TIME,
            "clone", "--depth=1", "--single-branch", "--no-tags", "--quiet",
            clone_url, tmp_dir,
        },
        .max_output_bytes = 4 * 1024,
    }) catch {
        std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};
        return .clone_failed;
    };
    defer alloc.free(clone_result.stdout);
    defer alloc.free(clone_result.stderr);

    if (clone_result.term != .Exited or clone_result.term.Exited != 0) {
        std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};
        return .clone_failed;
    }

    const exe_path = std.process.executablePathAlloc(io, alloc) catch {
        std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};
        return .index_failed;
    };
    defer alloc.free(exe_path);

    // Move the clone into its FINAL location before indexing. The indexer
    // derives its per-project data dir from the root path it is handed
    // (bootstrap.getDataDir hashes the absolute root), so indexing the temp
    // path would orphan a data dir under ~/.codedb/projects that nothing ever
    // reclaims, and hide the word index from the reader, which looks it up
    // under the final path's hash. The in-flight marker keeps the sweepers
    // (and other codedb processes) off the directory until indexing lands.
    std.Io.Dir.cwd().deleteTree(io, cache_dir) catch {};
    std.Io.Dir.cwd().rename(tmp_dir, std.Io.Dir.cwd(), cache_dir, io) catch {
        std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};
        return .clone_failed;
    };
    refreshed.* = true;
    writeMarker(io, cache_dir, inflight_marker_name, "");
    writeMarker(io, cache_dir, origin_marker_name, repo);

    var snap_buf: [std.fs.max_path_bytes]u8 = undefined;
    const snap_path = std.fmt.bufPrint(&snap_buf, "{s}/codedb.snapshot", .{cache_dir}) catch {
        std.Io.Dir.cwd().deleteTree(io, cache_dir) catch {};
        return .index_failed;
    };

    const index_result = cio.runCapture(.{
        .allocator = alloc,
        .argv = &.{ exe_path, cache_dir, "snapshot", snap_path },
        // Generous: a chatty indexer that overruns this gets SIGPIPE'd once
        // the parent stops reading, which would fail an otherwise fine clone.
        .max_output_bytes = 4 * 1024 * 1024,
    }) catch {
        std.Io.Dir.cwd().deleteTree(io, cache_dir) catch {};
        return .index_failed;
    };
    defer alloc.free(index_result.stdout);
    defer alloc.free(index_result.stderr);

    if (index_result.term != .Exited or index_result.term.Exited != 0) {
        std.Io.Dir.cwd().deleteTree(io, cache_dir) catch {};
        return .index_failed;
    }

    deleteMarker(io, cache_dir, inflight_marker_name);
    return .ready;
}

fn writeMarker(io: std.Io, cache_dir: []const u8, name: []const u8, body: []const u8) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ cache_dir, name }) catch return;
    const file = std.Io.Dir.cwd().createFile(io, path, .{}) catch return;
    defer file.close(io);
    file.writeStreamingAll(io, body) catch {};
}

fn deleteMarker(io: std.Io, cache_dir: []const u8, name: []const u8) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ cache_dir, name }) catch return;
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

/// True while `cache_dir` is being cloned/indexed by some codedb process.
pub fn isInflight(io: std.Io, cache_dir: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ cache_dir, inflight_marker_name }) catch return false;
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    const mtime_ns: i128 = @intCast(stat.mtime.nanoseconds);
    const age_s = @divTrunc(cio.nanoTimestamp() - mtime_ns, std.time.ns_per_s);
    return age_s < INFLIGHT_GRACE_SECONDS;
}

/// True for a `<slug>.tmp.<ms>` staging directory young enough to still be an
/// active clone. Sweepers skip those; an abandoned one ages out and is swept.
pub fn isActiveTempEntry(name: []const u8) bool {
    const marker = ".tmp.";
    const at = std.mem.lastIndexOf(u8, name, marker) orelse return false;
    const stamp_str = name[at + marker.len ..];
    if (stamp_str.len == 0) return true;
    const stamp = std.fmt.parseInt(i64, stamp_str, 10) catch return true;
    const age_ms = cio.milliTimestamp() - stamp;
    return age_ms < INFLIGHT_GRACE_SECONDS * std.time.ms_per_s;
}

/// GitHub's repos API reports `size` in KiB. Returns null when the body has
/// no usable size field.
pub fn parseGithubRepoSizeKb(body: []const u8) ?u64 {
    const key = "\"size\"";
    var idx = (std.mem.indexOf(u8, body, key) orelse return null) + key.len;
    while (idx < body.len and (body[idx] == ' ' or body[idx] == ':' or body[idx] == '\t')) : (idx += 1) {}
    var end = idx;
    while (end < body.len and std.ascii.isDigit(body[end])) : (end += 1) {}
    if (end == idx) return null;
    return std.fmt.parseInt(u64, body[idx..end], 10) catch null;
}

/// Pre-clone size budget. Fails OPEN — when GitHub cannot be asked we take the
/// clone rather than refusing a repo that is probably small.
fn repoExceedsCloneBudget(alloc: std.mem.Allocator, repo: []const u8) bool {
    const url = std.fmt.allocPrint(alloc, "https://api.github.com/repos/{s}", .{repo}) catch return false;
    defer alloc.free(url);

    const res = cio.runCapture(.{
        .allocator = alloc,
        .argv = &.{ "curl", "-fsSL", "--max-time", "10", "-A", "codedb", url },
        .max_output_bytes = 256 * 1024,
    }) catch return false;
    defer alloc.free(res.stdout);
    defer alloc.free(res.stderr);

    if (res.term != .Exited or res.term.Exited != 0) return false;
    const size_kb = parseGithubRepoSizeKb(res.stdout) orelse return false;
    return size_kb > MAX_CLONE_SIZE_KB;
}

fn evictIfNeeded(io: std.Io, alloc: std.mem.Allocator, skip_slug: []const u8) void {
    _ = cleanStaleEntries(io, alloc, REMOTE_CACHE_TTL_SECONDS) catch 0;

    const cache_root = getCacheRoot(alloc) orelse return;
    defer alloc.free(cache_root);

    var dir = std.Io.Dir.cwd().openDir(io, cache_root, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var count: usize = 0;
    var iter_count = dir.iterate();
    while (iter_count.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        if (isActiveTempEntry(entry.name)) continue;
        count += 1;
    }

    if (count < MAX_CACHED_REPOS) return;

    var oldest_name: ?[]u8 = null;
    var oldest_mtime: i128 = std.math.maxInt(i128);
    var iter_find = dir.iterate();
    while (iter_find.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        if (std.mem.eql(u8, entry.name, skip_slug)) continue;
        if (isActiveTempEntry(entry.name)) continue;
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ cache_root, entry.name }) catch continue;
        if (isInflight(io, full_path)) continue;
        var snap_buf: [std.fs.max_path_bytes]u8 = undefined;
        const snap_path = std.fmt.bufPrint(&snap_buf, "{s}/codedb.snapshot", .{full_path}) catch continue;
        const stat = std.Io.Dir.cwd().statFile(io, snap_path, .{}) catch continue;
        const mtime_ns: i128 = @intCast(stat.mtime.nanoseconds);
        if (mtime_ns < oldest_mtime) {
            oldest_mtime = mtime_ns;
            if (oldest_name) |n| alloc.free(n);
            oldest_name = alloc.dupe(u8, entry.name) catch null;
        }
    }

    if (oldest_name) |name| {
        defer alloc.free(name);
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ cache_root, name }) catch return;
        std.Io.Dir.cwd().deleteTree(io, full_path) catch {};
    }
}

pub fn cleanRemoteCache(io: std.Io, alloc: std.mem.Allocator) !u32 {
    const cache_root = getCacheRoot(alloc) orelse return error.NoHome;
    defer alloc.free(cache_root);

    var dir = std.Io.Dir.cwd().openDir(io, cache_root, .{ .iterate = true }) catch return 0;
    defer dir.close(io);

    var count: u32 = 0;
    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        if (isActiveTempEntry(entry.name)) continue;
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ cache_root, entry.name }) catch continue;
        if (isInflight(io, full_path)) continue;
        std.Io.Dir.cwd().deleteTree(io, full_path) catch continue;
        count += 1;
    }
    return count;
}

pub fn cleanStaleEntries(io: std.Io, alloc: std.mem.Allocator, ttl_seconds: i64) !u32 {
    const cache_root = getCacheRoot(alloc) orelse return error.NoHome;
    defer alloc.free(cache_root);

    var dir = std.Io.Dir.cwd().openDir(io, cache_root, .{ .iterate = true }) catch return 0;
    defer dir.close(io);

    var count: u32 = 0;
    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        // Never touch another process's in-flight clone: it legitimately has
        // no snapshot yet, and deleting it mid-index yields a truncated tree
        // that gets served as authoritative for the whole TTL.
        if (isActiveTempEntry(entry.name)) continue;
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
    if (isInflight(io, cache_dir)) return false;
    var snap_buf: [std.fs.max_path_bytes]u8 = undefined;
    const snap_path = std.fmt.bufPrint(&snap_buf, "{s}/codedb.snapshot", .{cache_dir}) catch return true;
    const stat = std.Io.Dir.cwd().statFile(io, snap_path, .{}) catch return true;
    const mtime_ns: i128 = @intCast(stat.mtime.nanoseconds);
    const age_s = @divTrunc(cio.nanoTimestamp() - mtime_ns, std.time.ns_per_s);
    return age_s > ttl_seconds;
}
