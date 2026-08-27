//! Shared gitignore matching for live listings and repository indexing.
//!
//! Subset of git's rules: comments, `!` negation, trailing-`/` directories,
//! leading-`/` (or mid-slash) anchored to the ignore file's directory, `*` / `?`
//! in a path segment, and `**` across segments. A parent directory that wins
//! as ignored hides its children (a `!` on a child does not pierce it).
//! `.git` itself is the walker's job, not this file.

const std = @import("std");
const project_file = @import("project_file.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Rule = struct {
    negated: bool,
    dir_only: bool,
    /// Leading `/` or a `/` in the middle — match from this ignore file's dir.
    anchored: bool,
    pattern: []const u8,
    /// Absolute directory that contained the ignore file (no trailing slash).
    base: []const u8,
};

pub const Verdict = enum { none, ignore, include };

pub fn parse(arena: Allocator, text: []const u8, base: []const u8) ![]Rule {
    var list: std.ArrayList(Rule) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = trim(raw);
        if (line.len == 0 or line[0] == '#') continue;
        try list.append(arena, parseLine(line, base));
    }
    return list.items;
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r");
}

fn parseLine(line: []const u8, base: []const u8) Rule {
    var s = line;
    var negated = false;
    if (s[0] == '!') {
        negated = true;
        s = s[1..];
    }
    var dir_only = false;
    if (s.len > 0 and s[s.len - 1] == '/') {
        dir_only = true;
        s = s[0 .. s.len - 1];
    }
    var anchored = false;
    if (s.len > 0 and s[0] == '/') {
        anchored = true;
        s = s[1..];
    }
    if (std.mem.indexOfScalar(u8, s, '/') != null) anchored = true;
    return .{
        .negated = negated,
        .dir_only = dir_only,
        .anchored = anchored,
        .pattern = s,
        .base = base,
    };
}

fn under(path: []const u8, root: []const u8) bool {
    if (!std.mem.startsWith(u8, path, root)) return false;
    if (path.len == root.len) return true;
    return path[root.len] == '/';
}

/// Path of `abs` relative to `base`, or null when `abs` is not under `base`.
/// The base directory itself yields empty string.
pub fn relTo(abs: []const u8, base: []const u8) ?[]const u8 {
    if (!under(abs, base)) return null;
    if (abs.len == base.len) return "";
    return abs[base.len + 1 ..];
}

fn globSeg(pat: []const u8, s: []const u8) bool {
    if (pat.len == 0) return s.len == 0;
    if (pat[0] == '*') {
        var i: usize = 0;
        while (i <= s.len) : (i += 1) {
            if (globSeg(pat[1..], s[i..])) return true;
        }
        return false;
    }
    if (s.len == 0) return false;
    if (pat[0] == '?' or pat[0] == s[0]) return globSeg(pat[1..], s[1..]);
    return false;
}

const Segment = struct {
    value: []const u8,
    next: usize,
};

fn nextSegment(s: []const u8, start: usize) ?Segment {
    var begin = start;
    while (begin < s.len and s[begin] == '/') begin += 1;
    if (begin >= s.len) return null;
    const end = std.mem.indexOfScalarPos(u8, s, begin, '/') orelse s.len;
    return .{ .value = s[begin..end], .next = end };
}

/// Allocation-free segment matcher. Indexing calls this once per path, so the
/// old split-into-ArrayList implementation accumulated scan-sized scratch
/// allocations when its caller used a long-lived arena.
fn matchSegs(pattern: []const u8, pattern_at: usize, path: []const u8, path_at: usize) bool {
    const pat = nextSegment(pattern, pattern_at) orelse return nextSegment(path, path_at) == null;
    if (std.mem.eql(u8, pat.value, "**")) {
        if (nextSegment(pattern, pat.next) == null) return true;
        if (matchSegs(pattern, pat.next, path, path_at)) return true;
        var cursor = path_at;
        while (nextSegment(path, cursor)) |segment| {
            cursor = segment.next;
            if (matchSegs(pattern, pat.next, path, cursor)) return true;
        }
        return false;
    }
    const part = nextSegment(path, path_at) orelse return false;
    if (!globSeg(pat.value, part.value)) return false;
    return matchSegs(pattern, pat.next, path, part.next);
}

fn matchPattern(arena: Allocator, pattern: []const u8, local: []const u8, anchored: bool) !bool {
    _ = arena;
    if (pattern.len == 0) return false;
    if (anchored) return matchSegs(pattern, 0, local, 0);
    if (matchSegs(pattern, 0, local, 0)) return true;
    var cursor: usize = 0;
    while (nextSegment(local, cursor)) |segment| {
        cursor = segment.next;
        if (matchSegs(pattern, 0, local, cursor)) return true;
    }
    return false;
}

fn ruleHits(arena: Allocator, rule: Rule, abs: []const u8, is_dir: bool) !bool {
    if (rule.dir_only and !is_dir) return false;
    const local = relTo(abs, rule.base) orelse return false;
    if (local.len == 0) return false; // the ignore file's own directory
    return matchPattern(arena, rule.pattern, local, rule.anchored);
}

/// Last matching rule wins.
pub fn verdict(arena: Allocator, rules: []const Rule, abs: []const u8, is_dir: bool) !Verdict {
    var v: Verdict = .none;
    for (rules) |r| {
        if (try ruleHits(arena, r, abs, is_dir)) {
            v = if (r.negated) .include else .ignore;
        }
    }
    return v;
}

/// True when `abs` or a parent under the walk is ignored. `walk_root` stops
/// the parent walk so we do not apply a rule to a path above the listing.
pub fn ignored(arena: Allocator, rules: []const Rule, walk_root: []const u8, abs: []const u8, is_dir: bool) !bool {
    if (!under(abs, walk_root)) return false;
    var start: usize = if (abs.len > walk_root.len) walk_root.len + 1 else abs.len;
    while (start <= abs.len) {
        const slash = if (start >= abs.len) abs.len else (std.mem.indexOfScalarPos(u8, abs, start, '/') orelse abs.len);
        const prefix = abs[0..slash];
        const prefix_dir = slash < abs.len or is_dir;
        const last = slash == abs.len;
        switch (try verdict(arena, rules, prefix, prefix_dir)) {
            .ignore => return true,
            .include => if (last) return false,
            .none => {},
        }
        if (slash == abs.len) break;
        start = slash + 1;
    }
    return false;
}

fn hasGit(io: Io, dir: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const p = std.fmt.bufPrint(&buf, "{s}/.git", .{dir}) catch return false;
    _ = Io.Dir.cwd().statFile(io, p, .{}) catch return false;
    return true;
}

fn parentOf(path: []const u8) ?[]const u8 {
    if (path.len <= 1) return null;
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return null;
    if (slash == 0) return path[0..1];
    return path[0..slash];
}

fn loadFile(io: Io, arena: Allocator, path: []const u8, base: []const u8, out: *std.ArrayList(Rule)) void {
    if (!std.mem.startsWith(u8, path, base) or path.len <= base.len or path[base.len] != '/') return;
    const rel = path[base.len + 1 ..];
    var dir = Io.Dir.cwd().openDir(io, base, .{}) catch return;
    defer dir.close(io);
    // `base` comes from the canonical list root (or one of its canonical
    // parents). Validate the opened handle against that identity so a path
    // retarget between discovery and open cannot re-anchor resolve-beneath to
    // an attacker-controlled directory.
    var opened_buf: [std.fs.max_path_bytes]u8 = undefined;
    const opened_len = dir.realPath(io, &opened_buf) catch return;
    if (!std.mem.eql(u8, opened_buf[0..opened_len], base)) return;
    const text = project_file.readAllocNoFollow(io, dir, rel, arena, .limited(64 * 1024)) catch return;
    const extra = parse(arena, text, base) catch return;
    out.appendSlice(arena, extra) catch {};
}

/// Climb from `abs_root` to the git root (or 32 parents) and load each
/// `.gitignore`, then `.git/info/exclude`. Parent files first so a nested
/// file's later rules win.
pub fn loadClimb(io: Io, arena: Allocator, abs_root: []const u8) ![]Rule {
    var dirs: std.ArrayList([]const u8) = .empty;
    var cur = abs_root;
    var git_root: ?[]const u8 = null;
    var n: usize = 0;
    while (n < 32) : (n += 1) {
        try dirs.append(arena, cur);
        if (hasGit(io, cur)) {
            git_root = cur;
            break;
        }
        cur = parentOf(cur) orelse break;
    }
    // With a git root: parent files first (nested wins). Without one: only
    // the walk root — climbing into /tmp/.gitignore would make listings
    // depend on the host.
    var out: std.ArrayList(Rule) = .empty;
    if (git_root != null) {
        var i: usize = dirs.items.len;
        while (i > 0) {
            i -= 1;
            const d = dirs.items[i];
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const gi = std.fmt.bufPrint(&buf, "{s}/.gitignore", .{d}) catch continue;
            loadFile(io, arena, gi, d, &out);
        }
        if (git_root) |g| {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const ex = std.fmt.bufPrint(&buf, "{s}/.git/info/exclude", .{g}) catch return out.items;
            loadFile(io, arena, ex, g, &out);
        }
    } else {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const gi = std.fmt.bufPrint(&buf, "{s}/.gitignore", .{abs_root}) catch return out.items;
        loadFile(io, arena, gi, abs_root, &out);
    }
    return out.items;
}

/// Load project-local ignore policy through an already-established root
/// capability.  MCP/live callers use this form so neither root replacement
/// nor a symlinked ignore file can redirect policy reads outside the project.
pub fn loadProjectRoot(io: Io, arena: Allocator, root_dir: Io.Dir, canonical_root: []const u8) ![]Rule {
    var out: std.ArrayList(Rule) = .empty;
    if (project_file.readAllocNoFollowAtRoot(io, root_dir, canonical_root, ".gitignore", arena, .limited(64 * 1024))) |text| {
        const rules = parse(arena, text, canonical_root) catch &.{};
        try out.appendSlice(arena, rules);
    } else |_| {}

    var git_dir = root_dir.openDir(io, ".git", .{ .follow_symlinks = false }) catch return out.items;
    defer git_dir.close(io);
    var info_dir = git_dir.openDir(io, "info", .{ .follow_symlinks = false }) catch return out.items;
    defer info_dir.close(io);
    const text = project_file.readAllocNoFollow(io, info_dir, "exclude", arena, .limited(64 * 1024)) catch return out.items;
    const rules = parse(arena, text, canonical_root) catch return out.items;
    try out.appendSlice(arena, rules);
    return out.items;
}

test "star and dir-only and negation" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const rules = try parse(a, "*.log\nbuild/\n!keep.log\n", "/work");
    try std.testing.expect(try ignored(a, rules, "/work", "/work/a.log", false));
    try std.testing.expect(!try ignored(a, rules, "/work", "/work/a.zig", false));
    try std.testing.expect(try ignored(a, rules, "/work", "/work/build", true));
    try std.testing.expect(try ignored(a, rules, "/work", "/work/build/x.o", false));
    try std.testing.expect(!try ignored(a, rules, "/work", "/work/keep.log", false));
}

test "rooted pattern does not match nested names" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const rules = try parse(a, "/secret\n", "/work");
    try std.testing.expect(try ignored(a, rules, "/work", "/work/secret", false));
    try std.testing.expect(!try ignored(a, rules, "/work", "/work/sub/secret", false));
}

test "nested ignore file only covers its subtree" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const rules = try parse(a, "*.tmp\n", "/work/src");
    try std.testing.expect(try ignored(a, rules, "/work", "/work/src/x.tmp", false));
    try std.testing.expect(!try ignored(a, rules, "/work", "/work/x.tmp", false));
}

test "without a git root only the walk dir gitignore applies" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    tmp.dir.writeFile(io, .{ .sub_path = ".gitignore", .data = "local.skip\n" }) catch unreachable;
    tmp.dir.writeFile(io, .{ .sub_path = "local.skip", .data = "x" }) catch unreachable;
    tmp.dir.writeFile(io, .{ .sub_path = "keep.txt", .data = "x" }) catch unreachable;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const rules = try loadClimb(io, a, buf[0..n]);
    try std.testing.expect(try ignored(a, rules, buf[0..n], try std.fmt.allocPrint(a, "{s}/local.skip", .{buf[0..n]}), false));
    try std.testing.expect(!try ignored(a, rules, buf[0..n], try std.fmt.allocPrint(a, "{s}/keep.txt", .{buf[0..n]}), false));
}

test "double-star and comments" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const rules = try parse(a, "# hi\n\n**/skip.dat\n", "/work");
    try std.testing.expect(try ignored(a, rules, "/work", "/work/skip.dat", false));
    try std.testing.expect(try ignored(a, rules, "/work", "/work/a/b/skip.dat", false));
    try std.testing.expect(!try ignored(a, rules, "/work", "/work/keep.dat", false));
}
