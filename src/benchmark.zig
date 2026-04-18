/// codedb benchmark — measures indexing speed, query latency, recall, and
const cio = @import("cio.zig");
/// watcher efficiency against a real repository.
///
/// Usage:
///   zig build benchmark -- --root /path/to/repo [--iterations N] [--json]
///
/// Metrics reported:
///   - Initial index time (ms) and peak allocator bytes
///   - Trigram search: avg latency (ns) + hit count per query
///   - Word index:     avg latency (ns) + hit count per query
///   - Symbol search:  avg latency (ns) + hit count per query
///   - Re-index cycle: id_to_path slot reuse (free-list efficiency)
///   - .git/HEAD stat: mtime stability check (gate effectiveness)
const std = @import("std");
const Store = @import("store.zig").Store;
const Explorer = @import("explore.zig").Explorer;
const watcher = @import("watcher.zig");

// ── CLI args ──────────────────────────────────────────────────────────────────

const Args = struct {
    root: []const u8 = ".",
    iterations: usize = 50,
    json: bool = false,
};

fn parseArgs(allocator: std.mem.Allocator) !Args {
    const argv = try cio.argsAlloc(allocator);
    defer cio.argsFree(allocator, argv);
    var out = Args{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--root") and i + 1 < argv.len) {
            i += 1;
            out.root = try allocator.dupe(u8, argv[i]);
        } else if (std.mem.eql(u8, argv[i], "--iterations") and i + 1 < argv.len) {
            i += 1;
            out.iterations = try std.fmt.parseInt(usize, argv[i], 10);
        } else if (std.mem.eql(u8, argv[i], "--json")) {
            out.json = true;
        }
    }
    return out;
}

// ── Result types ─────────────────────────────────────────────────────────────

const QueryResult = struct {
    name: []const u8,
    kind: []const u8,
    hits: usize,
    avg_ns: u64,
};

const ReindexResult = struct {
    cycles: usize,
    files_per_cycle: usize,
    id_to_path_before: usize,
    id_to_path_after: usize,
    free_ids_after: usize,
};

const GitHeadResult = struct {
    stat_stable: bool,
    stat_ns: u64,
};

const BenchResult = struct {
    root: []const u8,
    file_count: u64,
    index_ms: u64,
    queries: []QueryResult,
    reindex: ReindexResult,
    git_head: GitHeadResult,
};

// ── Query benchmarks ──────────────────────────────────────────────────────────

fn benchSearch(explorer: *Explorer, query: []const u8, n: usize, alloc: std.mem.Allocator) !QueryResult {
    var total: u64 = 0;
    var hits: usize = 0;
    for (0..n) |_| {
        var t = try cio.Timer.start();
        const r = try explorer.searchContent(query, alloc, 50);
        total +|= t.read();
        hits = r.len;
        for (r) |e| alloc.free(e.line_text);
        alloc.free(r);
    }
    return .{ .name = query, .kind = "search", .hits = hits, .avg_ns = total / n };
}

fn benchWord(explorer: *Explorer, word: []const u8, n: usize, alloc: std.mem.Allocator) !QueryResult {
    var total: u64 = 0;
    var hits: usize = 0;
    for (0..n) |_| {
        var t = try cio.Timer.start();
        const r = try explorer.searchWord(word, alloc);
        total +|= t.read();
        hits = r.len;
        alloc.free(r);
    }
    return .{ .name = word, .kind = "word", .hits = hits, .avg_ns = total / n };
}

fn benchSymbol(explorer: *Explorer, name: []const u8, n: usize, alloc: std.mem.Allocator) !QueryResult {
    var total: u64 = 0;
    var hits: usize = 0;
    for (0..n) |_| {
        var t = try cio.Timer.start();
        const r = try explorer.findAllSymbols(name, alloc);
        total +|= t.read();
        hits = r.len;
        alloc.free(r);
    }
    return .{ .name = name, .kind = "symbol", .hits = hits, .avg_ns = total / n };
}

// ── Re-index efficiency ───────────────────────────────────────────────────────

fn benchReindex(io: std.Io, explorer: *Explorer, root: []const u8, alloc: std.mem.Allocator) !ReindexResult {
    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |p| alloc.free(p);
        paths.deinit(alloc);
    }
    var contents: std.ArrayList([]const u8) = .empty;
    defer {
        for (contents.items) |c| alloc.free(c);
        contents.deinit(alloc);
    }

    // Collect up to 10 small source files with known content
    var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch
        return ReindexResult{ .cycles = 0, .files_per_cycle = 0, .id_to_path_before = 0, .id_to_path_after = 0, .free_ids_after = 0 };
    defer dir.close(io);
    var walker = try dir.walk(alloc);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or paths.items.len >= 10) continue;
        const ext = std.fs.path.extension(entry.path);
        const wanted = [_][]const u8{ ".zig", ".js", ".ts", ".py", ".go", ".c", ".cpp", ".rs" };
        const keep = for (wanted) |e| {
            if (std.mem.eql(u8, ext, e)) break true;
        } else false;
        if (!keep) continue;
        const full = std.fs.path.join(alloc, &.{ root, entry.path }) catch continue;
        defer alloc.free(full);
        const st = std.Io.Dir.cwd().statFile(io, full, .{}) catch continue;
        if (st.size > 128 * 1024) continue;
        const content = std.Io.Dir.cwd().readFileAlloc(io, full, alloc, .limited(128 * 1024)) catch continue;
        try paths.append(alloc, try alloc.dupe(u8, entry.path));
        try contents.append(alloc, content);
    }

    if (paths.items.len == 0) return ReindexResult{
        .cycles = 0,
        .files_per_cycle = 0,
        .id_to_path_before = 0,
        .id_to_path_after = 0,
        .free_ids_after = 0,
    };

    const before = explorer.trigramIdToPathLen();
    const cycles: usize = 5;
    for (0..cycles) |_| {
        for (paths.items, contents.items) |path, content| {
            explorer.indexFile(path, content) catch {};
        }
    }

    return .{
        .cycles = cycles,
        .files_per_cycle = paths.items.len,
        .id_to_path_before = before,
        .id_to_path_after = explorer.trigramIdToPathLen(),
        .free_ids_after = explorer.trigramFreeIdsLen(),
    };
}

// ── Git HEAD mtime check ──────────────────────────────────────────────────────

fn benchGitHead(io: std.Io, root: []const u8) GitHeadResult {
    var root_dir = std.Io.Dir.cwd().openDir(io, root, .{}) catch
        return .{ .stat_stable = false, .stat_ns = 0 };
    defer root_dir.close(io);
    const st0 = root_dir.statFile(io, ".git/HEAD", .{}) catch
        return .{ .stat_stable = false, .stat_ns = 0 };
    var total: u64 = 0;
    var stable = true;
    for (0..5) |_| {
        var d = std.Io.Dir.cwd().openDir(io, root, .{}) catch break;
        defer d.close(io);
        var t = cio.Timer.start() catch break;
        const st = d.statFile(io, ".git/HEAD", .{}) catch break;
        total +|= t.read();
        if (st.mtime.nanoseconds != st0.mtime.nanoseconds) stable = false;
    }
    return .{ .stat_stable = stable, .stat_ns = total / 5 };
}

// ── Formatters ────────────────────────────────────────────────────────────────

fn fmtNs(ns: u64, buf: *[32]u8) []const u8 {
    if (ns < 1_000) return std.fmt.bufPrint(buf, "{d} ns", .{ns}) catch "";
    if (ns < 1_000_000) return std.fmt.bufPrint(buf, "{d:.1} µs", .{@as(f64, @floatFromInt(ns)) / 1e3}) catch "";
    return std.fmt.bufPrint(buf, "{d:.2} ms", .{@as(f64, @floatFromInt(ns)) / 1e6}) catch "";
}

fn fmtBytes(b: usize, buf: *[32]u8) []const u8 {
    if (b < 1024) return std.fmt.bufPrint(buf, "{d} B", .{b}) catch "";
    if (b < 1024 * 1024) return std.fmt.bufPrint(buf, "{d:.1} KB", .{@as(f64, @floatFromInt(b)) / 1024.0}) catch "";
    return std.fmt.bufPrint(buf, "{d:.1} MB", .{@as(f64, @floatFromInt(b)) / (1024.0 * 1024.0)}) catch "";
}

fn printHuman(allocator: std.mem.Allocator, file: cio.File, r: BenchResult) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    const w = out.writer(allocator);
    try w.print("\n=== codedb benchmark: {s} ===\n\n", .{r.root});
    try w.print("  files indexed : {d}\n", .{r.file_count});
    var tb: [32]u8 = undefined;
    try w.print("  index time    : {s}\n\n", .{fmtNs(r.index_ms * std.time.ns_per_ms, &tb)});

    try w.print("  {s:<28} {s:>10}  {s:>8}  {s}\n", .{ "query", "avg latency", "hits", "kind" });
    try w.print("  {s:-<28} {s:->10}  {s:->8}  {s:-<6}\n", .{ "", "", "", "" });
    for (r.queries) |q| {
        var nb: [32]u8 = undefined;
        try w.print("  {s:<28} {s:>10}  {d:>8}  {s}\n", .{ q.name, fmtNs(q.avg_ns, &nb), q.hits, q.kind });
    }

    try w.print("\n  re-index ({d} cycles × {d} files):\n", .{ r.reindex.cycles, r.reindex.files_per_cycle });
    try w.print("    id_to_path before  : {d}\n", .{r.reindex.id_to_path_before});
    try w.print("    id_to_path after   : {d}\n", .{r.reindex.id_to_path_after});
    try w.print("    free_ids remaining : {d}\n", .{r.reindex.free_ids_after});
    const bounded = r.reindex.id_to_path_after <= r.reindex.id_to_path_before + r.reindex.files_per_cycle + 1;
    try w.print("    id_to_path bounded : {s}\n", .{if (bounded) "yes ✓" else "no — unexpected growth"});

    try w.print("\n  .git/HEAD mtime gate:\n", .{});
    var sb: [32]u8 = undefined;
    try w.print("    stat cost (avg 5x) : {s}\n", .{fmtNs(r.git_head.stat_ns, &sb)});
    try w.print("    mtime stable       : {s}\n\n", .{if (r.git_head.stat_stable) "yes ✓ — getGitHead would be skipped" else "no — HEAD changed during bench"});
    try file.writeAll(out.items);
}

fn printJson(allocator: std.mem.Allocator, file: cio.File, r: BenchResult) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    const w = out.writer(allocator);
    try w.print("{{\"root\":\"{s}\",\"file_count\":{d},\"index_ms\":{d},\"queries\":[", .{
        r.root, r.file_count, r.index_ms,
    });
    for (r.queries, 0..) |q, i| {
        if (i > 0) try w.print(",", .{});
        try w.print("{{\"name\":\"{s}\",\"kind\":\"{s}\",\"hits\":{d},\"avg_ns\":{d}}}", .{
            q.name, q.kind, q.hits, q.avg_ns,
        });
    }
    try w.print("],\"reindex\":{{\"cycles\":{d},\"files_per_cycle\":{d},\"id_to_path_before\":{d},\"id_to_path_after\":{d},\"free_ids\":{d}}},", .{
        r.reindex.cycles,            r.reindex.files_per_cycle,
        r.reindex.id_to_path_before, r.reindex.id_to_path_after,
        r.reindex.free_ids_after,
    });
    try w.print("\"git_head\":{{\"stat_ns\":{d},\"stable\":{}}}}}\n", .{
        r.git_head.stat_ns, r.git_head.stat_stable,
    });
    try file.writeAll(out.items);
}

// ── main ──────────────────────────────────────────────────────────────────────

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const args = try parseArgs(alloc);
    defer if (!std.mem.eql(u8, args.root, ".")) alloc.free(args.root);

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root: []const u8 = blk: {
        const n = std.Io.Dir.cwd().realPathFile(io, args.root, &root_buf) catch break :blk args.root;
        break :blk root_buf[0..n];
    };

    // Index
    var store = Store.init(alloc);
    defer store.deinit();
    var explorer = Explorer.init(alloc);
    defer explorer.deinit();

    var t0 = try cio.Timer.start();
    watcher.initialScan(io, &store, &explorer, root, alloc, false) catch |err| {
        var errbuf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&errbuf, "benchmark: initialScan failed: {}\n", .{err}) catch "benchmark: initialScan failed\n";
        try cio.File.stderr().writeAll(msg);
        return;
    };
    const index_ns = t0.read();

    // Queries
    var qlist: std.ArrayList(QueryResult) = .empty;
    defer qlist.deinit(alloc);

    for ([_][]const u8{ "middleware", "authentication", "webhook", "database", "error" }) |q|
        (qlist.append(alloc, try benchSearch(&explorer, q, args.iterations, alloc)) catch {});
    for ([_][]const u8{ "request", "response", "config", "error" }) |q|
        (qlist.append(alloc, try benchWord(&explorer, q, args.iterations, alloc)) catch {});
    for ([_][]const u8{ "init", "main", "handleRequest", "render" }) |q|
        (qlist.append(alloc, try benchSymbol(&explorer, q, args.iterations, alloc)) catch {});

    const reindex = try benchReindex(io, &explorer, root, alloc);
    const git_head = benchGitHead(io, root);

    const result = BenchResult{
        .root = root,
        .file_count = store.currentSeq(),
        .index_ms = @intCast(@divTrunc(index_ns, std.time.ns_per_ms)),
        .queries = qlist.items,
        .reindex = reindex,
        .git_head = git_head,
    };

    if (args.json) {
        try printJson(alloc, cio.File.stdout(), result);
    } else {
        try printHuman(alloc, cio.File.stderr(), result);
    }
}
