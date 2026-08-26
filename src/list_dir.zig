//! grok-build-style live filesystem listing (`codedb list_dir`).
//!
//! `ls` / `tree` are **index** queries. This command walks the directory
//! itself: depth-1 seed, lazy BFS expand, `.gitignore` + `.git/info/exclude`,
//! 10k-char budget, collapsed subtree summaries. `.git` is omitted. Other
//! dotfiles stay visible but sort after non-dot dirs; files follow dirs.
//! Agent/cache dirs (`.graff`, `node_modules`, …) are listed without
//! descending unless they are the requested path. Keep aligned with
//! codegraff's in-process `codedb list_dir` (src/list_dir.zig there) — #696.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const gitignore = @import("gitignore.zig");
const project_file = @import("project_file.zig");

pub const max_output_chars: usize = 10_000;
pub const max_walk_items: usize = 20_000;
pub const top_k_exts: usize = 3;

const root_truncation_notice =
    \\    ...
    \\
    \\Note: this directory is too large to list fully. Try codedb list_dir on a narrower path, or use codedb search / bash.
;

const walk_truncation_notice =
    \\
    \\Note: there are more than 20000 items in the directory, so not all files may be shown.
;

const Node = struct {
    name: []const u8,
    rel: []const u8,
    is_dir: bool,
    depth: usize,
    parent: ?*Node,
    kids: std.ArrayList(*Node),
    file_count: usize,
    ext: std.StringHashMap(usize),
    expanded: bool,
    filled: bool,
};

fn newNode(arena: Allocator, name: []const u8, rel: []const u8, is_dir: bool, depth: usize, parent: ?*Node) !*Node {
    const n = try arena.create(Node);
    n.* = .{
        .name = name,
        .rel = rel,
        .is_dir = is_dir,
        .depth = depth,
        .parent = parent,
        .kids = .empty,
        .file_count = 0,
        .ext = std.StringHashMap(usize).init(arena),
        .expanded = false,
        .filled = false,
    };
    return n;
}

fn extKey(arena: Allocator, name: []const u8) ![]const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return "no-ext";
    if (dot == 0 or dot + 1 == name.len) return "no-ext";
    const raw = name[dot + 1 ..];
    const out = try arena.alloc(u8, raw.len);
    for (raw, out) |c, *d| d.* = std.ascii.toLower(c);
    return out;
}

fn addFile(arena: Allocator, node: *Node, name: []const u8) !void {
    const key = try extKey(arena, name);
    var p: ?*Node = node;
    while (p) |n| {
        n.file_count += 1;
        const gop = try n.ext.getOrPut(key);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
        p = n.parent;
    }
}

fn join(arena: Allocator, a: []const u8, b: []const u8) ![]const u8 {
    if (a.len == 0) return b;
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ a, b });
}

fn isGitComponent(name: []const u8) bool {
    return std.mem.eql(u8, name, ".git");
}

/// Shown as a directory entry but never descended unless it is the listing
/// root. Subset of watcher skip_dirs: agent scratch and package caches that
/// otherwise eat the 10k/20k budget before `src/`.
fn isCollapseDir(name: []const u8) bool {
    const names = [_][]const u8{
        ".graff",
        ".claude",
        ".codex",
        ".engram",
        ".harness",
        ".audit",
        ".devin",
        "node_modules",
        ".zig-cache",
        "zig-out",
        "__pycache__",
        ".venv",
        "venv",
        ".idea",
        ".pytest_cache",
        ".mypy_cache",
        ".ruff_cache",
        ".next",
        ".turbo",
        ".parcel-cache",
        ".devenv",
    };
    for (names) |n| if (std.mem.eql(u8, name, n)) return true;
    return false;
}

const Walk = struct {
    io: Io,
    arena: Allocator,
    root_dir: Io.Dir,
    root_abs: []const u8,
    rules: std.ArrayList(gitignore.Rule),
    items: usize = 0,
    truncated: bool = false,
};

fn isPortablePathSep(ch: u8) bool {
    return ch == '/' or ch == '\\';
}

fn canonicalRelative(root: []const u8, target: []const u8, normalized: []u8) ?[]const u8 {
    if (!underRoot(target, root)) return null;
    var start = root.len;
    while (start < target.len and isPortablePathSep(target[start])) start += 1;
    const rel = target[start..];
    if (rel.len > normalized.len) return null;
    for (rel, normalized[0..rel.len]) |ch, *out| out.* = if (isPortablePathSep(ch)) '/' else ch;
    return normalized[0..rel.len];
}

test "Windows canonical paths are slash-normalized before list policy checks" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const rel = canonicalRelative("C:\\repo", "C:\\repo\\safe\\.ssh", &buf) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("safe/.ssh", rel);
    try std.testing.expect(!project_file.isAllowedPath(rel));
    try std.testing.expect(!underRoot("C:\\repo-other\\src", "C:\\repo"));
}

fn openedDirectoryAllowed(w: *Walk, dir: Io.Dir) bool {
    var opened_buf: [std.fs.max_path_bytes]u8 = undefined;
    const opened_len = dir.realPath(w.io, &opened_buf) catch return false;
    var normalized_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target_rel = canonicalRelative(w.root_abs, opened_buf[0..opened_len], &normalized_buf) orelse return false;
    return target_rel.len == 0 or project_file.isAllowedPath(target_rel);
}

fn skip(w: *Walk, abs: []const u8, is_dir: bool) !bool {
    if (isGitComponent(std.fs.path.basename(abs))) return true;
    return gitignore.ignored(w.arena, w.rules.items, w.root_abs, abs, is_dir);
}

fn fill(w: *Walk, node: *Node) !void {
    if (node.filled) return;
    node.filled = true;
    const rel = node.rel;
    const abs = if (rel.len == 0) w.root_abs else try join(w.arena, w.root_abs, rel);
    var owned_dir: ?Io.Dir = null;
    const dir = if (rel.len == 0) w.root_dir else blk: {
        const opened = w.root_dir.openDir(w.io, rel, .{ .iterate = true }) catch return;
        owned_dir = opened;
        break :blk opened;
    };
    defer if (owned_dir) |opened| opened.close(w.io);
    if (!openedDirectoryAllowed(w, dir)) return;

    var names: std.ArrayList(struct { name: []const u8, is_dir: bool }) = .empty;
    var it = dir.iterate();
    var saw_ignore = false;
    while (it.next(w.io) catch null) |ent| {
        const name = try w.arena.dupe(u8, ent.name);
        const child_rel = if (rel.len == 0) name else try join(w.arena, rel, name);
        if (!project_file.isAllowedPath(child_rel)) continue;
        if (std.mem.eql(u8, name, ".gitignore") and rel.len > 0) saw_ignore = true;
        var is_dir = false;
        if (ent.kind == .directory or ent.kind == .sym_link) {
            const child_dir = dir.openDir(w.io, name, .{ .iterate = true }) catch continue;
            defer child_dir.close(w.io);
            if (!openedDirectoryAllowed(w, child_dir)) continue;
            is_dir = true;
        } else if (ent.kind == .file) {
            const st = dir.statFile(w.io, name, .{ .follow_symlinks = false }) catch continue;
            if (st.kind != .file) continue;
        } else continue;
        try names.append(w.arena, .{ .name = name, .is_dir = is_dir });
    }
    if (saw_ignore) {
        const ignore_rel = try join(w.arena, rel, ".gitignore");
        const text = project_file.readAllocNoFollowAtRoot(w.io, w.root_dir, w.root_abs, ignore_rel, w.arena, .limited(64 * 1024)) catch null;
        if (text) |t| {
            const extra = gitignore.parse(w.arena, t, abs) catch &.{};
            w.rules.appendSlice(w.arena, extra) catch {};
        }
    }

    for (names.items) |e| {
        if (isGitComponent(e.name)) continue;
        const child_rel = if (rel.len == 0) e.name else try join(w.arena, rel, e.name);
        const child_abs = try join(w.arena, w.root_abs, child_rel);
        if (try skip(w, child_abs, e.is_dir)) continue;
        const child = try newNode(w.arena, e.name, child_rel, e.is_dir, node.depth + 1, node);
        try node.kids.append(w.arena, child);
        if (!e.is_dir) try addFile(w.arena, node, e.name);
        w.items += 1;
        if (w.items >= max_walk_items) {
            w.truncated = true;
            return;
        }
    }
}

fn nameLess(_: void, a: *Node, b: *Node) bool {
    const an = a.name;
    const bn = b.name;
    const n = @min(an.len, bn.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const ca = std.ascii.toLower(an[i]);
        const cb = std.ascii.toLower(bn[i]);
        if (ca < cb) return true;
        if (ca > cb) return false;
    }
    return an.len < bn.len;
}

fn kidLess(_: void, a: *Node, b: *Node) bool {
    if (a.is_dir != b.is_dir) return a.is_dir;
    const adot = a.name.len > 0 and a.name[0] == '.';
    const bdot = b.name.len > 0 and b.name[0] == '.';
    if (adot != bdot) return !adot;
    return nameLess({}, a, b);
}

fn sortKids(n: *Node) void {
    std.mem.sort(*Node, n.kids.items, {}, kidLess);
}

fn fillSummaries(w: *Walk, node: *Node) !void {
    for (node.kids.items) |k| {
        if (!k.is_dir or isCollapseDir(k.name)) continue;
        try fill(w, k);
        sortKids(k);
    }
}

fn isSourceExt(ext: []const u8) bool {
    const src = [_][]const u8{
        "zig", "c",  "h",    "cc", "cpp",   "cxx", "hpp",
        "py",  "ts", "tsx",  "js", "jsx",   "mjs", "cjs",
        "go",  "rs", "java", "kt", "swift", "rb",  "php",
        "cs",  "sh", "bash", "md", "toml",
    };
    for (src) |s| if (std.mem.eql(u8, ext, s)) return true;
    return false;
}

fn sourceFiles(n: *Node) usize {
    var total: usize = 0;
    var it = n.ext.iterator();
    while (it.next()) |e| {
        if (isSourceExt(e.key_ptr.*)) total += e.value_ptr.*;
    }
    return total;
}

/// Fat data dumps (.log/.patch/.png/.jsonl) stay as summaries so `src/`
/// can spend the char budget. Source-heavy dirs still expand even when large.
fn preferCollapse(n: *Node) bool {
    if (n.file_count == 0) return false;
    const src = sourceFiles(n);
    if (src * 2 >= n.file_count) return false;
    return n.kids.items.len > 16 or n.file_count > 16;
}

fn expandLess(_: void, a: *Node, b: *Node) bool {
    const as = sourceFiles(a);
    const bs = sourceFiles(b);
    if (as != bs) return as > bs;
    if (a.file_count != b.file_count) return a.file_count < b.file_count;
    return nameLess({}, a, b);
}

fn enqueueExpandable(q: *std.ArrayList(*Node), arena: Allocator, node: *Node) !void {
    const start = q.items.len;
    for (node.kids.items) |k| {
        if (k.is_dir and !isCollapseDir(k.name)) try q.append(arena, k);
    }
    std.mem.sort(*Node, q.items[start..], {}, expandLess);
}

const ExtPair = struct { k: []const u8, n: usize };

fn extLess(_: void, a: ExtPair, b: ExtPair) bool {
    if (a.n != b.n) return a.n > b.n;
    return std.mem.lessThan(u8, a.k, b.k);
}

fn summary(arena: Allocator, n: *Node) ![]const u8 {
    if (n.file_count == 0) return "";
    var pairs: std.ArrayList(ExtPair) = .empty;
    var it = n.ext.iterator();
    while (it.next()) |e| try pairs.append(arena, .{ .k = e.key_ptr.*, .n = e.value_ptr.* });
    std.mem.sort(ExtPair, pairs.items, {}, extLess);
    const take = @min(pairs.items.len, top_k_exts);
    var aw: Io.Writer.Allocating = .init(arena);
    const word: []const u8 = if (n.file_count == 1) "file" else "files";
    try aw.writer.print("[{d} {s} in subtree: ", .{ n.file_count, word });
    var shown: usize = 0;
    for (pairs.items[0..take], 0..) |p, i| {
        if (i > 0) try aw.writer.writeAll(", ");
        if (std.mem.eql(u8, p.k, "no-ext")) {
            try aw.writer.print("{d} *no-ext", .{p.n});
        } else {
            try aw.writer.print("{d} *.{s}", .{ p.n, p.k });
        }
        shown += p.n;
    }
    if (shown < n.file_count) try aw.writer.writeAll(", ...");
    try aw.writer.writeByte(']');
    return aw.writer.buffered();
}

fn writeKidLine(w: *Io.Writer, n: *Node, child: *Node) !void {
    var i: usize = 0;
    while (i < n.depth + 1) : (i += 1) try w.writeAll("  ");
    try w.writeAll("- ");
    try w.writeAll(child.name);
    if (child.is_dir) try w.writeByte('/');
    try w.writeByte('\n');
}

fn renderKids(arena: Allocator, n: *Node) ![]const u8 {
    var aw: Io.Writer.Allocating = .init(arena);
    for (n.kids.items) |child| {
        try writeKidLine(&aw.writer, n, child);
        if (!child.is_dir) continue;
        if (child.expanded) {
            try aw.writer.writeAll(try renderKids(arena, child));
        } else {
            const sum = try summary(arena, child);
            if (sum.len == 0) continue;
            var i: usize = 0;
            while (i < n.depth + 2) : (i += 1) try aw.writer.writeAll("  ");
            try aw.writer.writeAll(sum);
            try aw.writer.writeByte('\n');
        }
    }
    return aw.writer.buffered();
}

fn truncateRoot(arena: Allocator, root: *Node, budget: usize) ![]const u8 {
    var aw: Io.Writer.Allocating = .init(arena);
    var used: usize = 0;
    for (root.kids.items) |child| {
        var chunk: Io.Writer.Allocating = .init(arena);
        try writeKidLine(&chunk.writer, root, child);
        if (child.is_dir) {
            const sum = try summary(arena, child);
            if (sum.len > 0) {
                try chunk.writer.writeAll("    ");
                try chunk.writer.writeAll(sum);
                try chunk.writer.writeByte('\n');
            }
        }
        const bytes = chunk.writer.buffered();
        if (used + bytes.len > budget) break;
        try aw.writer.writeAll(bytes);
        used += bytes.len;
    }
    try aw.writer.writeAll(root_truncation_notice);
    return aw.writer.buffered();
}

fn budgetExpand(w: *Walk, root: *Node, max_chars: usize) ![]const u8 {
    const arena = w.arena;
    const cutoff: []const u8 = if (w.truncated) walk_truncation_notice else "";
    if (root.kids.items.len == 0) return cutoff;
    root.expanded = true;
    const first = try renderKids(arena, root);
    if (first.len > max_chars) {
        return std.fmt.allocPrint(arena, "{s}{s}", .{ try truncateRoot(arena, root, max_chars), cutoff });
    }
    var remaining = max_chars - first.len;
    var q: std.ArrayList(*Node) = .empty;
    try enqueueExpandable(&q, arena, root);
    var qi: usize = 0;
    while (qi < q.items.len) : (qi += 1) {
        const node = q.items[qi];
        try fill(w, node);
        sortKids(node);
        try fillSummaries(w, node);
        if (preferCollapse(node)) continue;
        node.expanded = true;
        const expanded = try renderKids(arena, node);
        const sum = try summary(arena, node);
        const sum_cost: usize = if (sum.len == 0) 0 else (node.depth + 1) * 2 + sum.len + 1;
        if (expanded.len > remaining + sum_cost) {
            node.expanded = false;
            continue;
        }
        remaining += sum_cost;
        remaining -= expanded.len;
        try enqueueExpandable(&q, arena, node);
    }
    const cut: []const u8 = if (w.truncated) walk_truncation_notice else "";
    return std.fmt.allocPrint(arena, "{s}{s}", .{ try renderKids(arena, root), cut });
}

fn walkTreeRoot(io: Io, arena: Allocator, root_dir: Io.Dir, abs: []const u8) !struct { root: *Node, w: Walk } {
    const climbed = try gitignore.loadProjectRoot(io, arena, root_dir, abs);
    var w: Walk = .{
        .io = io,
        .arena = arena,
        .root_dir = root_dir,
        .root_abs = abs,
        .rules = .empty,
    };
    try w.rules.appendSlice(arena, climbed);
    const root = try newNode(arena, "", "", true, 0, null);
    try fill(&w, root);
    try fillSummaries(&w, root);
    sortKids(root);
    return .{ .root = root, .w = w };
}

fn stripDot(path: []const u8) []const u8 {
    const t = std.mem.trim(u8, path, " \t");
    if (t.len == 0) return ".";
    if (std.mem.eql(u8, t, ".") or std.mem.eql(u8, t, "./")) return ".";
    if (std.mem.startsWith(u8, t, "./")) return t[2..];
    return t;
}

/// Render a listing for an already-resolved absolute directory.
pub fn listAbs(io: Io, arena: Allocator, abs: []const u8, display: []const u8) ![]const u8 {
    var root_dir = try Io.Dir.cwd().openDir(io, abs, .{ .iterate = true, .follow_symlinks = false });
    defer root_dir.close(io);
    var walked = try walkTreeRoot(io, arena, root_dir, abs);
    const body = try budgetExpand(&walked.w, walked.root, max_output_chars);
    const trimmed = std.mem.trimEnd(u8, body, "\n");
    if (trimmed.len == 0) return std.fmt.allocPrint(arena, "- {s}/", .{display});
    return std.fmt.allocPrint(arena, "- {s}/\n{s}", .{ display, trimmed });
}

fn pathSafe(path: []const u8) bool {
    if (path.len == 0) return false;
    if (path[0] == '/') return false;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return false;
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return false;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |c| {
        if (std.mem.eql(u8, c, "..")) return false;
    }
    return true;
}

fn underRoot(abs: []const u8, root: []const u8) bool {
    if (!std.mem.startsWith(u8, abs, root)) return false;
    if (abs.len == root.len) return true;
    return root.len > 0 and (isPortablePathSep(root[root.len - 1]) or isPortablePathSep(abs[root.len]));
}

pub const ListError = error{
    NotFound,
    NotADir,
    IsAFile,
    Escape,
    AccessDenied,
};

/// List `rel` under `project_abs`. `rel` of `.` / empty is the project root.
/// Caller owns the returned slice (`arena`).
pub fn listUnder(io: Io, arena: Allocator, project_abs: []const u8, rel: []const u8) ListError![]const u8 {
    var root_dir = Io.Dir.cwd().openDir(io, project_abs, .{ .iterate = true, .follow_symlinks = false }) catch return error.NotFound;
    defer root_dir.close(io);
    return listUnderRoot(io, arena, root_dir, project_abs, rel);
}

pub fn listUnderRoot(io: Io, arena: Allocator, root_dir: Io.Dir, project_abs: []const u8, rel: []const u8) ListError![]const u8 {
    const path = stripDot(rel);
    if (!std.mem.eql(u8, path, ".") and !pathSafe(path)) return error.Escape;
    if (!std.mem.eql(u8, path, ".") and !project_file.isAllowedPath(path)) return error.AccessDenied;

    if (!std.mem.eql(u8, path, ".")) {
        const requested_stat = root_dir.statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return error.NotFound,
            error.AccessDenied => return error.AccessDenied,
            else => return error.NotADir,
        };
        if (requested_stat.kind == .file) return error.IsAFile;
    }

    const opened = if (std.mem.eql(u8, path, ".")) root_dir else root_dir.openDir(io, path, .{ .iterate = true }) catch return error.NotADir;
    defer if (!std.mem.eql(u8, path, ".")) opened.close(io);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = opened.realPath(io, &buf) catch return error.NotADir;
    const abs = buf[0..n];
    if (!underRoot(abs, project_abs)) return error.Escape;
    var normalized_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target_rel = canonicalRelative(project_abs, abs, &normalized_buf) orelse return error.Escape;
    if (target_rel.len != 0 and !project_file.isAllowedPath(target_rel)) return error.AccessDenied;
    var walked = walkTreeRoot(io, arena, root_dir, project_abs) catch return error.NotADir;
    const root = if (std.mem.eql(u8, path, ".")) walked.root else blk: {
        const node = newNode(arena, std.fs.path.basename(path), path, true, 0, null) catch return error.NotFound;
        fill(&walked.w, node) catch return error.NotADir;
        fillSummaries(&walked.w, node) catch return error.NotADir;
        sortKids(node);
        break :blk node;
    };
    const body = budgetExpand(&walked.w, root, max_output_chars) catch return error.NotADir;
    const trimmed = std.mem.trimEnd(u8, body, "\n");
    if (trimmed.len == 0) return std.fmt.allocPrint(arena, "- {s}/", .{path}) catch return error.NotFound;
    return std.fmt.allocPrint(arena, "- {s}/\n{s}", .{ path, trimmed }) catch return error.NotFound;
}

pub fn errorText(err: ListError) []const u8 {
    return switch (err) {
        error.NotFound => "error: path was not found",
        error.IsAFile => "error: path is a file, not a directory",
        error.NotADir => "error: path is not a valid directory",
        error.Escape => "error: path traversal not allowed",
        error.AccessDenied => "error: permission denied",
    };
}

fn tmpAbs(io: Io, tmp: *std.testing.TmpDir, buf: *[std.fs.max_path_bytes]u8) ![]const u8 {
    const n = try tmp.dir.realPath(io, buf);
    return buf[0..n];
}

test "issue-696: lists files and dirs, hides gitignore and .git" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    tmp.dir.writeFile(io, .{ .sub_path = ".gitignore", .data = "skip.log\nbuild/\n" }) catch unreachable;
    tmp.dir.writeFile(io, .{ .sub_path = "keep.zig", .data = "x" }) catch unreachable;
    tmp.dir.writeFile(io, .{ .sub_path = "skip.log", .data = "x" }) catch unreachable;
    tmp.dir.createDirPath(io, "build") catch unreachable;
    tmp.dir.writeFile(io, .{ .sub_path = "build/a.o", .data = "x" }) catch unreachable;
    tmp.dir.createDirPath(io, ".git/objects") catch unreachable;
    tmp.dir.writeFile(io, .{ .sub_path = ".git/HEAD", .data = "ref\n" }) catch unreachable;
    tmp.dir.createDirPath(io, ".github") catch unreachable;
    tmp.dir.writeFile(io, .{ .sub_path = ".github/ci.yml", .data = "x" }) catch unreachable;

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = try tmpAbs(io, &tmp, &buf);
    const out = try listAbs(io, arena_state.allocator(), abs, ".");
    try std.testing.expect(std.mem.indexOf(u8, out, "keep.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, ".github") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "skip.log") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "build") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, ".git/") == null);
}

test "fat sibling collapses; later sibling still listed" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    tmp.dir.createDirPath(io, "aaa") catch unreachable;
    var i: usize = 0;
    while (i < 800) : (i += 1) {
        var name: [48]u8 = undefined;
        const n = std.fmt.bufPrint(&name, "aaa/file_with_a_longer_name_{d:0>3}.zig", .{i}) catch unreachable;
        tmp.dir.writeFile(io, .{ .sub_path = n, .data = "x" }) catch unreachable;
    }
    tmp.dir.createDirPath(io, "zzz") catch unreachable;
    tmp.dir.writeFile(io, .{ .sub_path = "zzz/tail.md", .data = "x" }) catch unreachable;

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = try tmpAbs(io, &tmp, &buf);
    const out = try listAbs(io, arena_state.allocator(), abs, "root");
    try std.testing.expect(std.mem.indexOf(u8, out, "- aaa/") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "- zzz/") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "files in subtree") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "*.zig") != null);
    try std.testing.expect(out.len < max_output_chars + root_truncation_notice.len + 64);
}

test "listUnder refuses a file and an escaped path" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    tmp.dir.writeFile(io, .{ .sub_path = "only.txt", .data = "x" }) catch unreachable;
    tmp.dir.createDirPath(io, "sub") catch unreachable;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = try tmpAbs(io, &tmp, &buf);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try std.testing.expectError(error.IsAFile, listUnder(io, a, abs, "only.txt"));
    try std.testing.expectError(error.Escape, listUnder(io, a, abs, "../outside"));
    const listing = try listUnder(io, a, abs, ".");
    try std.testing.expect(std.mem.indexOf(u8, listing, "only.txt") != null);
    const nested = try listUnder(io, a, abs, "sub");
    try std.testing.expectEqualStrings("- sub/", nested);
}

test "listUnderRoot filters sensitive names and sensitive directory aliases" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "safe.txt", .data = "ok" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".env", .data = "SECRET=x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "private_key.pem", .data = "key" });
    try tmp.dir.createDirPath(io, ".ssh");
    try tmp.dir.writeFile(io, .{ .sub_path = ".ssh/config", .data = "secret" });
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = "pub fn main() void {}" });
    tmp.dir.symLink(io, ".ssh", "aliasdir", .{}) catch |err| switch (err) {
        error.AccessDenied => return error.SkipZigTest,
        else => return err,
    };
    try tmp.dir.symLink(io, "src", "safealias", .{});

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPathFile(io, ".", &root_buf);
    const root = root_buf[0..root_len];
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const listing = try listUnderRoot(io, arena_state.allocator(), tmp.dir, root, ".");
    try std.testing.expect(std.mem.indexOf(u8, listing, "safe.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, listing, "safealias/") != null);
    try std.testing.expect(std.mem.indexOf(u8, listing, ".env") == null);
    try std.testing.expect(std.mem.indexOf(u8, listing, "private_key.pem") == null);
    try std.testing.expect(std.mem.indexOf(u8, listing, ".ssh") == null);
    try std.testing.expect(std.mem.indexOf(u8, listing, "aliasdir") == null);
    try std.testing.expectError(error.AccessDenied, listUnderRoot(io, arena_state.allocator(), tmp.dir, root, ".ssh"));
    try std.testing.expectError(error.AccessDenied, listUnderRoot(io, arena_state.allocator(), tmp.dir, root, "aliasdir"));
    const safe_alias = try listUnderRoot(io, arena_state.allocator(), tmp.dir, root, "safealias");
    try std.testing.expect(std.mem.indexOf(u8, safe_alias, "main.zig") != null);
}

test "empty directory is a header only" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = try tmpAbs(io, &tmp, &buf);
    const out = try listAbs(io, arena_state.allocator(), abs, "empty");
    try std.testing.expectEqualStrings("- empty/", out);
}

test "dirs first, non-dot dirs before dot dirs, then files" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    tmp.dir.createDirPath(io, "src") catch unreachable;
    tmp.dir.writeFile(io, .{ .sub_path = "src/keep.zig", .data = "x" }) catch unreachable;
    tmp.dir.createDirPath(io, ".github") catch unreachable;
    tmp.dir.writeFile(io, .{ .sub_path = ".github/ci.yml", .data = "x" }) catch unreachable;
    tmp.dir.writeFile(io, .{ .sub_path = "README.md", .data = "x" }) catch unreachable;

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = try tmpAbs(io, &tmp, &buf);
    const out = try listAbs(io, arena_state.allocator(), abs, ".");
    const src_at = std.mem.indexOf(u8, out, "- src/") orelse return error.MissingSrc;
    const gh_at = std.mem.indexOf(u8, out, "- .github/") orelse return error.MissingGithub;
    const readme_at = std.mem.indexOf(u8, out, "- README.md") orelse return error.MissingReadme;
    try std.testing.expect(src_at < gh_at);
    try std.testing.expect(gh_at < readme_at);
}

test "collapse .graff without walking it; explicit path still lists inner files" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    tmp.dir.createDirPath(io, "src") catch unreachable;
    tmp.dir.writeFile(io, .{ .sub_path = "src/keep.zig", .data = "x" }) catch unreachable;
    tmp.dir.createDirPath(io, ".graff/behavior") catch unreachable;
    tmp.dir.writeFile(io, .{ .sub_path = ".graff/noise.jsonl", .data = "x" }) catch unreachable;
    tmp.dir.writeFile(io, .{ .sub_path = ".graff/behavior/trace.jsonl", .data = "x" }) catch unreachable;
    tmp.dir.writeFile(io, .{ .sub_path = "README.md", .data = "x" }) catch unreachable;

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = try tmpAbs(io, &tmp, &buf);
    const a = arena_state.allocator();
    const out = try listAbs(io, a, abs, ".");
    try std.testing.expect(std.mem.indexOf(u8, out, "- src/") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "keep.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "- .graff/") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "noise.jsonl") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "trace.jsonl") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "20000 items") == null);

    const inner = try listUnder(io, a, abs, ".graff");
    try std.testing.expect(std.mem.indexOf(u8, inner, "noise.jsonl") != null);
    try std.testing.expect(std.mem.indexOf(u8, inner, "- behavior/") != null);
}

test "fat data dir stays collapsed so a source sibling expands" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    tmp.dir.createDirPath(io, "src") catch unreachable;
    tmp.dir.writeFile(io, .{ .sub_path = "src/keep.zig", .data = "x" }) catch unreachable;
    tmp.dir.createDirPath(io, "results") catch unreachable;
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        var name: [48]u8 = undefined;
        const n = std.fmt.bufPrint(&name, "results/run_{d:0>2}.log", .{i}) catch unreachable;
        tmp.dir.writeFile(io, .{ .sub_path = n, .data = "x" }) catch unreachable;
    }

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = try tmpAbs(io, &tmp, &buf);
    const out = try listAbs(io, arena_state.allocator(), abs, ".");
    try std.testing.expect(std.mem.indexOf(u8, out, "keep.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "- results/") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "files in subtree") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "run_00.log") == null);
}
