const std = @import("std");
const cio = @import("cio.zig");
const Store = @import("store.zig").Store;
const Explorer = @import("explore.zig").Explorer;
const AgentRegistry = @import("agent.zig").AgentRegistry;
const watcher = @import("watcher.zig");
const mcp = @import("mcp.zig");
const telemetry = @import("telemetry.zig");

const HUGE_FN_COUNT: usize = 3600;
const HUGE_BODY_LINES: usize = 8;
const MANY_DIRS: usize = 40;
const MANY_FILES_PER_DIR: usize = 75;

const CaseResult = struct {
    tool: []const u8,
    avg_latency_ns: u64,
    min_latency_ns: u64,
    response_bytes: usize,
    ops_per_sec: f64,
};

const Case = struct {
    tool: mcp.Tool,
    name: []const u8,
    args_json: []const u8,
    iterations: usize,
    warmup: usize = 1,
    bust_search_cache: bool = false,
    reset_huge: bool = false,
};

const cases = [_]Case{
    .{ .tool = .codedb_search, .name = "edge_search_common", .args_json = "{\"query\":\"hotword\",\"max_results\":20}", .iterations = 25, .bust_search_cache = true },
    .{ .tool = .codedb_search, .name = "edge_search_offset", .args_json = "{\"query\":\"hotword\",\"max_results\":20,\"offset\":400}", .iterations = 25, .bust_search_cache = true },
    .{ .tool = .codedb_search, .name = "edge_search_scope", .args_json = "{\"query\":\"hotword\",\"max_results\":20,\"scope\":true}", .iterations = 25, .bust_search_cache = true },
    .{ .tool = .codedb_search, .name = "edge_search_glob", .args_json = "{\"query\":\"hotword\",\"max_results\":20,\"path_glob\":\"many/**/*.zig\"}", .iterations = 25, .bust_search_cache = true },
    .{ .tool = .codedb_search, .name = "edge_search_regex", .args_json = "{\"query\":\"edgeHandler[A-Za-z]+_39_7[0-4]\",\"regex\":true,\"max_results\":20}", .iterations = 15, .bust_search_cache = true },
    .{ .tool = .codedb_search, .name = "edge_search_ranked", .args_json = "{\"query\":\"shared helper handler\",\"max_results\":20}", .iterations = 25, .bust_search_cache = true },
    .{ .tool = .codedb_search, .name = "edge_search_longline", .args_json = "{\"query\":\"fillpayload\",\"max_results\":20}", .iterations = 15, .bust_search_cache = true },
    .{ .tool = .codedb_search, .name = "edge_search_miss", .args_json = "{\"query\":\"zzqqxxyynotfound\",\"max_results\":20}", .iterations = 25, .bust_search_cache = true },
    .{ .tool = .codedb_symbol, .name = "edge_symbol_exact", .args_json = "{\"name\":\"edgeHandlerAlphaBeta_20_50\"}", .iterations = 50 },
    .{ .tool = .codedb_symbol, .name = "edge_symbol_fuzzy", .args_json = "{\"name\":\"edgeHandlerAlphaBata_20_50\",\"fuzzy\":true}", .iterations = 25 },
    .{ .tool = .codedb_symbol, .name = "edge_symbol_glob", .args_json = "{\"pattern\":\"edgeHandler*_2?_5*\"}", .iterations = 25 },
    .{ .tool = .codedb_callers, .name = "edge_callers_hot", .args_json = "{\"name\":\"sharedHelper\",\"max_results\":50}", .iterations = 15 },
    .{ .tool = .codedb_callpath, .name = "edge_callpath_deep", .args_json = "{\"from\":\"edgeHandlerAlphaBeta_39_74\",\"to\":\"edgeHandlerAlphaBeta_39_0\",\"max_hops\":80}", .iterations = 10 },
    .{ .tool = .codedb_outline, .name = "edge_outline_huge", .args_json = "{\"path\":\"huge.zig\"}", .iterations = 30 },
    .{ .tool = .codedb_read, .name = "edge_read_deep", .args_json = "{\"path\":\"huge.zig\",\"line_start\":40000,\"line_end\":40040}", .iterations = 30 },
    .{ .tool = .codedb_tree, .name = "edge_tree_many", .args_json = "{}", .iterations = 30 },
    .{ .tool = .codedb_ls, .name = "edge_ls_dir", .args_json = "{\"path\":\"many/d39\"}", .iterations = 50 },
    .{ .tool = .codedb_glob, .name = "edge_glob_many", .args_json = "{\"pattern\":\"many/**/*.zig\",\"max_results\":200}", .iterations = 25 },
    .{ .tool = .codedb_find, .name = "edge_find_fuzzy", .args_json = "{\"query\":\"edge_fle_39_74\"}", .iterations = 30 },
    .{ .tool = .codedb_word, .name = "edge_word_hot", .args_json = "{\"word\":\"hotword\"}", .iterations = 25 },
    .{ .tool = .codedb_deps, .name = "edge_deps_trans", .args_json = "{\"path\":\"many/d39/edge_file_39_74.zig\",\"transitive\":true}", .iterations = 25 },
    .{ .tool = .codedb_edit, .name = "edge_edit_huge", .args_json = "{\"path\":\"huge.zig\",\"op\":\"replace\",\"range_start\":3,\"range_end\":3,\"content\":\"    acc +%= hotword + 999; // hotword filler 999\\n\"}", .iterations = 5, .warmup = 0, .reset_huge = true },
};

pub fn main(init: std.process.Init.Minimal) !void {
    cio.setProcessArgs(cio.bootstrapArgs(init.args));
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var emit_json = false;
    var filter: ?[]const u8 = null;
    {
        const args = try cio.argsAlloc(allocator);
        defer cio.argsFree(allocator, args);
        for (args[1..]) |arg| {
            if (std.mem.eql(u8, arg, "--json")) emit_json = true;
            if (std.mem.startsWith(u8, arg, "--filter=")) {
                filter = try allocator.dupe(u8, arg["--filter=".len..]);
            }
        }
    }
    defer if (filter) |f| allocator.free(f);

    var tmp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_root = try makeTempCorpusDir(io, &tmp_path_buf);
    defer std.Io.Dir.cwd().deleteTree(io, tmp_root) catch {};

    var repo_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const repo_root_len = try std.Io.Dir.cwd().realPathFile(io, ".", &repo_path_buf);
    const repo_root = repo_path_buf[0..repo_root_len];

    const huge_content = try genCorpus(io, allocator, tmp_root);
    defer allocator.free(huge_content);

    var store = Store.init(allocator);
    defer store.deinit();

    var explorer = Explorer.init(allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();

    var agents = AgentRegistry.init(allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    const scan_t0 = cio.nanoTimestamp();
    try watcher.initialScan(io, &store, &explorer, tmp_root, allocator, false);
    const scan_ns: u64 = @intCast(cio.nanoTimestamp() - scan_t0);

    var bench_ctx = mcp.BenchContext.init(allocator, tmp_root, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer bench_ctx.deinit();

    try std.process.setCurrentPath(io, tmp_root);
    defer std.process.setCurrentPath(io, repo_root) catch {};

    var telem_off = telemetry.Telemetry{ .enabled = false };

    var args_store: [cases.len]std.json.Parsed(std.json.Value) = undefined;
    for (cases, 0..) |case, idx| {
        args_store[idx] = try std.json.parseFromSlice(std.json.Value, allocator, case.args_json, .{});
    }
    defer {
        for (&args_store) |*parsed| parsed.deinit();
    }

    var results: std.ArrayList(CaseResult) = .empty;
    defer results.deinit(allocator);

    for (cases, 0..) |case, idx| {
        if (filter) |f| {
            if (std.mem.indexOf(u8, case.name, f) == null) continue;
        }
        const args = &args_store[idx].value.object;
        const r = try runCase(io, allocator, &bench_ctx, &store, &explorer, &agents, case, args, &telem_off, huge_content);
        try results.append(allocator, .{
            .tool = case.name,
            .avg_latency_ns = r.avg_latency_ns,
            .min_latency_ns = r.min_latency_ns,
            .response_bytes = r.response_bytes,
            .ops_per_sec = opsPerSec(r.avg_latency_ns),
        });
    }

    const corpus = summarizeCorpus(&explorer);
    try writeHumanSummary(allocator, cio.File.stderr(), corpus.files, corpus.bytes, scan_ns, results.items);
    if (emit_json) {
        try writeJsonSummary(allocator, cio.File.stdout(), repo_root, tmp_root, corpus.files, corpus.bytes, scan_ns, results.items);
    }
}

var bust_flip: bool = false;

fn bustSearchCache(explorer: *Explorer) !void {
    bust_flip = !bust_flip;
    const content = if (bust_flip) "pub const bust_marker = 1;\n" else "pub const bust_marker = 2;\n";
    try explorer.indexFile("bustfile.zig", content);
}

fn resetHuge(explorer: *Explorer, store: *Store, huge_content: []const u8) !void {
    try explorer.indexFile("huge.zig", huge_content);
    _ = try store.recordSnapshot("huge.zig", huge_content.len, std.hash.Wyhash.hash(0, huge_content));
}

fn runCase(
    io: std.Io,
    allocator: std.mem.Allocator,
    bench_ctx: *mcp.BenchContext,
    store: *Store,
    explorer: *Explorer,
    agents: *AgentRegistry,
    case: Case,
    args: *const std.json.ObjectMap,
    telem: *telemetry.Telemetry,
    huge_content: []const u8,
) !struct { avg_latency_ns: u64, min_latency_ns: u64, response_bytes: usize } {
    var total_ns: u64 = 0;
    var min_ns: u64 = std.math.maxInt(u64);
    var response_bytes: usize = 0;

    for (0..case.warmup) |_| {
        if (case.bust_search_cache) try bustSearchCache(explorer);
        if (case.reset_huge) try resetHuge(explorer, store, huge_content);
        _ = bench_ctx.runToolCall(io, allocator, case.name, case.tool, args, store, explorer, agents, telem);
    }

    if (cio.posixGetenv("CODEDB_EDGE_DUMP") != null) {
        var dump_out: std.ArrayList(u8) = .empty;
        defer dump_out.deinit(allocator);
        bench_ctx.runDispatch(io, allocator, case.tool, args, &dump_out, store, explorer, agents);
        cio.File.stderr().writeAll("=== DUMP ") catch {};
        cio.File.stderr().writeAll(case.name) catch {};
        cio.File.stderr().writeAll(" ===\n") catch {};
        cio.File.stderr().writeAll(dump_out.items) catch {};
        cio.File.stderr().writeAll("\n=== END ===\n") catch {};
    }

    for (0..case.iterations) |_| {
        if (case.bust_search_cache) try bustSearchCache(explorer);
        if (case.reset_huge) try resetHuge(explorer, store, huge_content);

        const r = bench_ctx.runToolCall(io, allocator, case.name, case.tool, args, store, explorer, agents, telem);
        total_ns +|= r.dispatch_ns;
        if (r.dispatch_ns < min_ns) min_ns = r.dispatch_ns;
        response_bytes = r.response_bytes;
    }

    return .{
        .avg_latency_ns = @intCast(@divTrunc(total_ns, case.iterations)),
        .min_latency_ns = min_ns,
        .response_bytes = response_bytes,
    };
}

fn genCorpus(io: std.Io, allocator: std.mem.Allocator, tmp_root: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    const w = cio.listWriter(&buf, allocator);

    // huge.zig: ~1.8MB, ~47k lines, 3600 functions. Above the 1MB trigram cap,
    // below the 2MB index cap — lands in the skip-trigram full-scan set.
    try buf.ensureTotalCapacity(allocator, 2_000_000);
    for (0..HUGE_FN_COUNT) |i| {
        try w.print("pub fn edgeHugeFn_{d:0>4}(x: usize) usize {{\n", .{i});
        try w.writeAll("    var acc: usize = x;\n");
        for (0..HUGE_BODY_LINES) |j| {
            try w.print("    acc +%= hotword + {d}; // hotword filler {d}\n", .{ j, i });
        }
        try w.writeAll("    return acc;\n}\n\n");
    }
    try w.writeAll("pub const needleUniqueXyz: usize = 42;\n");
    const huge_content = try allocator.dupe(u8, buf.items);
    errdefer allocator.free(huge_content);
    try writeFileUnder(io, tmp_root, "huge.zig", huge_content);

    // long_line_a.js: ~900KB single line (trigram-indexed).
    // long_line_b.js: ~1.5MB single line (skip-trigram).
    buf.clearRetainingCapacity();
    for (0..12_000) |i| {
        if (i % 50 == 0) {
            try w.print("var fillpayload{d}=hotword;", .{i});
        } else {
            try w.print("var v{d}=payload_chunk_{d}_abcdefghijklmnopqrstuvwxyz0123456789;", .{ i, i });
        }
    }
    try w.writeAll("\n");
    try writeFileUnder(io, tmp_root, "long_line_a.js", buf.items);

    buf.clearRetainingCapacity();
    for (0..20_000) |i| {
        if (i % 50 == 0) {
            try w.print("var fillpayload{d}x=hotword;", .{i});
        } else {
            try w.print("var w{d}=payload_chunk_{d}_abcdefghijklmnopqrstuvwxyz0123456789;", .{ i, i });
        }
    }
    try w.writeAll("\n");
    try writeFileUnder(io, tmp_root, "long_line_b.js", buf.items);

    // many/: 40 dirs x 75 files, an import/call chain within each dir, every
    // file calls sharedHelper (3000 call sites).
    try writeFileUnder(io, tmp_root, "many/shared_helper.zig", "pub fn sharedHelper() void {}\npub const shared_marker: usize = 7;\n");

    var rel_buf: [256]u8 = undefined;
    for (0..MANY_DIRS) |d| {
        for (0..MANY_FILES_PER_DIR) |f| {
            buf.clearRetainingCapacity();
            if (f > 0) {
                try w.print("const dep = @import(\"edge_file_{d}_{d}.zig\");\n", .{ d, f - 1 });
            }
            try w.print("pub fn edgeHandlerAlphaBeta_{d}_{d}() void {{\n", .{ d, f });
            try w.writeAll("    sharedHelper();\n");
            if (f > 0) {
                try w.print("    dep.edgeHandlerAlphaBeta_{d}_{d}();\n", .{ d, f - 1 });
            }
            try w.print("    var local_{d}_{d}: usize = hotword;\n", .{ d, f });
            try w.print("    _ = &local_{d}_{d};\n", .{ d, f });
            try w.writeAll("}\n");
            try w.print("pub const edge_const_{d}_{d}: usize = {d};\n", .{ d, f, d * 100 + f });

            const rel = try std.fmt.bufPrint(&rel_buf, "many/d{d}/edge_file_{d}_{d}.zig", .{ d, d, f });
            try writeFileUnder(io, tmp_root, rel, buf.items);
        }
    }

    return huge_content;
}

fn writeFileUnder(io: std.Io, root: []const u8, rel: []const u8, content: []const u8) !void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ root, rel });
    if (std.fs.path.dirname(path)) |parent| {
        try std.Io.Dir.cwd().createDirPath(io, parent);
    }
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, content);
}

fn makeTempCorpusDir(io: std.Io, buf: *[std.fs.max_path_bytes]u8) ![]const u8 {
    const base = cio.posixGetenv("TMPDIR") orelse "/tmp";
    const ns = cio.nanoTimestamp();
    const seed: u64 = @intCast(@as(u128, @bitCast(ns)) & 0xffff_ffff_ffff_ffff);
    const path = if (base.len > 0 and base[base.len - 1] == '/')
        try std.fmt.bufPrint(buf, "{s}codedb-bench-edge-{x}", .{ base, seed })
    else
        try std.fmt.bufPrint(buf, "{s}/codedb-bench-edge-{x}", .{ base, seed });
    try std.Io.Dir.cwd().createDirPath(io, path);
    return path;
}

fn summarizeCorpus(explorer: *Explorer) struct { files: usize, bytes: u64 } {
    explorer.mu.lockShared();
    defer explorer.mu.unlockShared();

    var files: usize = 0;
    var bytes: u64 = 0;
    var iter = explorer.outlines.iterator();
    while (iter.next()) |entry| {
        files += 1;
        bytes +|= entry.value_ptr.byte_size;
    }
    return .{ .files = files, .bytes = bytes };
}

fn writeHumanSummary(allocator: std.mem.Allocator, file: cio.File, file_count: usize, total_bytes: u64, scan_ns: u64, results: []const CaseResult) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    const writer = cio.listWriter(&out, allocator);
    var scan_buf: [32]u8 = undefined;
    try writer.print("── Edge-Case Benchmarks ({d} files, {d}KB, initial scan {s}) ──\n", .{ file_count, total_bytes / 1024, formatNs(&scan_buf, scan_ns) });
    try writer.writeAll("Case                     Avg        Min        Size\n");
    for (results) |result| {
        var avg_buf: [32]u8 = undefined;
        var min_buf: [32]u8 = undefined;
        try writer.print("{s:<24} {s:<10} {s:<10} {d}\n", .{
            result.tool,
            formatNs(&avg_buf, result.avg_latency_ns),
            formatNs(&min_buf, result.min_latency_ns),
            result.response_bytes,
        });
    }
    try file.writeAll(out.items);
}

fn writeJsonSummary(allocator: std.mem.Allocator, file: cio.File, repo_root: []const u8, corpus_root: []const u8, file_count: usize, total_bytes: u64, scan_ns: u64, results: []const CaseResult) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    const writer = cio.listWriter(&out, allocator);
    try writer.print("{{\"repo_root\":\"{s}\",\"corpus_root\":\"{s}\",\"file_count\":{d},\"total_bytes\":{d},\"scan_ns\":{d},\"tools\":[", .{
        repo_root,
        corpus_root,
        file_count,
        total_bytes,
        scan_ns,
    });
    for (results, 0..) |result, idx| {
        if (idx > 0) try writer.writeByte(',');
        try writer.print("{{\"tool\":\"{s}\",\"avg_latency_ns\":{d},\"min_latency_ns\":{d},\"response_bytes\":{d},\"ops_per_sec\":{d:.3}}}", .{
            result.tool,
            result.avg_latency_ns,
            result.min_latency_ns,
            result.response_bytes,
            result.ops_per_sec,
        });
    }
    try writer.writeAll("]}\n");
    try file.writeAll(out.items);
}

fn opsPerSec(avg_latency_ns: u64) f64 {
    if (avg_latency_ns == 0) return 0;
    return @as(f64, 1_000_000_000.0) / @as(f64, @floatFromInt(avg_latency_ns));
}

fn formatNs(buf: []u8, ns: u64) []const u8 {
    if (ns >= std.time.ns_per_s) {
        const whole = ns / std.time.ns_per_s;
        const frac = (ns % std.time.ns_per_s) / 100_000_000;
        return std.fmt.bufPrint(buf, "{d}.{d}s", .{ whole, frac }) catch "0s";
    }
    if (ns >= std.time.ns_per_ms) {
        const whole = ns / std.time.ns_per_ms;
        const frac = (ns % std.time.ns_per_ms) / 100_000;
        return std.fmt.bufPrint(buf, "{d}.{d}ms", .{ whole, frac }) catch "0ms";
    }
    if (ns >= std.time.ns_per_us) {
        const whole = ns / std.time.ns_per_us;
        const frac = (ns % std.time.ns_per_us) / 100;
        return std.fmt.bufPrint(buf, "{d}.{d}us", .{ whole, frac }) catch "0us";
    }
    return std.fmt.bufPrint(buf, "{d}ns", .{ns}) catch "0ns";
}
