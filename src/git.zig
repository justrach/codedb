const std = @import("std");
const cio = @import("cio.zig");

const disabled_hooks_config = "core.hooksPath=/codedb-hooks-disabled-do-not-exist";

fn parseGitHead(stdout: []const u8) ?[40]u8 {
    const trimmed = std.mem.trim(u8, stdout, &std.ascii.whitespace);
    if (trimmed.len != 40) return null;
    for (trimmed) |c| if (!std.ascii.isHex(c)) return null;
    var out: [40]u8 = undefined;
    @memcpy(&out, trimmed[0..40]);
    return out;
}

/// Run `git rev-parse HEAD` in `root` and return the 40-char hex SHA.
/// Returns null if `root` is not a git repo, git is unavailable, or HEAD
/// has no commit yet (fresh repo).
pub fn getGitHead(root: []const u8, allocator: std.mem.Allocator) !?[40]u8 {
    const result = cio.runCapture(.{
        .allocator = allocator,
        .argv = &.{ "git", "-c", "core.fsmonitor=false", "-c", disabled_hooks_config, "rev-parse", "HEAD" },
        .cwd = root,
        .max_output_bytes = 256,
    }) catch return null;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| if (code != 0) return null,
        else => return null,
    }

    return parseGitHead(result.stdout);
}

/// Resolve HEAD through an already-open project capability, so a rename and
/// pathname replacement cannot retarget the background branch probe.
pub fn getGitHeadDir(io: std.Io, root_dir: std.Io.Dir, allocator: std.mem.Allocator) !?[40]u8 {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "git", "-c", "core.fsmonitor=false", "-c", disabled_hooks_config, "rev-parse", "HEAD" },
        .cwd = .{ .dir = root_dir },
        .stdout_limit = .limited(256),
        .stderr_limit = .limited(256),
    }) catch return null;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (!result.term.success()) return null;
    return parseGitHead(result.stdout);
}

pub const CoChangePartner = struct {
    path: []const u8,
    count: u32,
};

fn isCommitSha(line: []const u8) bool {
    if (line.len != 40) return false;
    for (line) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

/// Parse `git log --name-only --pretty=format:%H` output into a co-change
/// map: file → strongest co-change partners, by shared-commit count. Pure
/// over the log text. Commits touching more than max_files_per_commit files
/// are skipped (vendor drops and formatting sweeps are co-change noise), as
/// are git-quoted exotic filenames. Caller owns the returned map — free with
/// freeCoChange.
pub fn parseCoChange(
    allocator: std.mem.Allocator,
    log_text: []const u8,
    max_files_per_commit: usize,
    max_partners: usize,
) !std.StringHashMap([]CoChangePartner) {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var pair_counts = std.StringHashMap(u32).init(a);
    var commit_files: std.ArrayList([]const u8) = .empty;

    var lines = std.mem.splitScalar(u8, log_text, '\n');
    var done = false;
    while (!done) {
        const maybe = lines.next();
        if (maybe == null) done = true;
        const line = std.mem.trimEnd(u8, maybe orelse "", "\r");
        if (done or isCommitSha(line)) {
            if (commit_files.items.len >= 2 and commit_files.items.len <= max_files_per_commit) {
                for (commit_files.items, 0..) |fa, i| {
                    for (commit_files.items[i + 1 ..]) |fb| {
                        if (std.mem.eql(u8, fa, fb)) continue;
                        const lo = if (std.mem.lessThan(u8, fa, fb)) fa else fb;
                        const hi = if (std.mem.lessThan(u8, fa, fb)) fb else fa;
                        const key = try std.fmt.allocPrint(a, "{s}\x00{s}", .{ lo, hi });
                        const gop = try pair_counts.getOrPut(key);
                        if (!gop.found_existing) gop.value_ptr.* = 0;
                        gop.value_ptr.* += 1;
                    }
                }
            }
            commit_files.clearRetainingCapacity();
            continue;
        }
        if (line.len == 0) continue;
        if (line[0] == '"') continue;
        try commit_files.append(a, line);
    }

    var per_file = std.StringHashMap(std.ArrayList(CoChangePartner)).init(a);
    var pc_it = pair_counts.iterator();
    while (pc_it.next()) |entry| {
        const key = entry.key_ptr.*;
        const sep = std.mem.indexOfScalar(u8, key, 0) orelse continue;
        const pair = [2][]const u8{ key[0..sep], key[sep + 1 ..] };
        for (pair, 0..) |file, side| {
            const gop = try per_file.getOrPut(file);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(a, .{ .path = pair[1 - side], .count = entry.value_ptr.* });
        }
    }

    var out = std.StringHashMap([]CoChangePartner).init(allocator);
    errdefer freeCoChange(&out, allocator);
    var pf_it = per_file.iterator();
    while (pf_it.next()) |entry| {
        std.mem.sort(CoChangePartner, entry.value_ptr.items, {}, struct {
            fn lt(_: void, x: CoChangePartner, y: CoChangePartner) bool {
                if (x.count != y.count) return x.count > y.count;
                return std.mem.lessThan(u8, x.path, y.path);
            }
        }.lt);
        const n = @min(entry.value_ptr.items.len, max_partners);
        const slice = try allocator.alloc(CoChangePartner, n);
        var filled: usize = 0;
        errdefer {
            for (slice[0..filled]) |p| allocator.free(p.path);
            allocator.free(slice);
        }
        for (entry.value_ptr.items[0..n]) |src| {
            slice[filled] = .{ .path = try allocator.dupe(u8, src.path), .count = src.count };
            filled += 1;
        }
        const owned_key = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(owned_key);
        try out.put(owned_key, slice);
    }
    return out;
}

pub fn freeCoChange(map: *std.StringHashMap([]CoChangePartner), allocator: std.mem.Allocator) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        for (entry.value_ptr.*) |p| allocator.free(p.path);
        allocator.free(entry.value_ptr.*);
        allocator.free(entry.key_ptr.*);
    }
    map.deinit();
}

/// Shell out to git log in `root` and build the co-change map (#550). Null
/// on any failure: not a git repo, git missing, empty history. A shallow
/// clone just yields a sparser map.
pub fn buildCoChange(
    allocator: std.mem.Allocator,
    root: []const u8,
    max_commits: u32,
    max_files_per_commit: usize,
    max_partners: usize,
) ?std.StringHashMap([]CoChangePartner) {
    var nbuf: [16]u8 = undefined;
    const nstr = std.fmt.bufPrint(&nbuf, "{d}", .{max_commits}) catch return null;
    const result = cio.runCapture(.{
        .allocator = allocator,
        .argv = &.{ "git", "-c", "core.fsmonitor=false", "-c", disabled_hooks_config, "log", "--name-only", "--no-merges", "--pretty=format:%H", "-n", nstr },
        .cwd = root,
        .max_output_bytes = 8 * 1024 * 1024,
    }) catch return null;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .Exited => |code| if (code != 0) return null,
        else => return null,
    }
    var map = parseCoChange(allocator, result.stdout, max_files_per_commit, max_partners) catch return null;
    if (map.count() == 0) {
        map.deinit();
        return null;
    }
    return map;
}
