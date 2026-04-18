const std = @import("std");
const cio = @import("cio.zig");
const Store = @import("store.zig").Store;
const Explorer = @import("explore.zig").Explorer;
const AgentRegistry = @import("agent.zig").AgentRegistry;
const watcher = @import("watcher.zig");
const mcp = @import("mcp.zig");
const telemetry = @import("telemetry.zig");

const ToolBench = struct {
    tool: []const u8,
    avg_latency_ns: u64,
    response_bytes: usize,
    ops_per_sec: f64,
    telemetry_avg_ns: u64,
    telemetry_delta_pct: f64,
};

const Case = struct {
    tool: mcp.Tool,
    name: []const u8,
    args_json: []const u8,
    iterations: usize,
};

const cases = [_]Case{
    .{ .tool = .codedb_tree, .name = "codedb_tree", .args_json = "{}", .iterations = 100 },
    .{ .tool = .codedb_outline, .name = "codedb_outline", .args_json = "{\"path\":\"src/main.zig\"}", .iterations = 100 },
    .{ .tool = .codedb_symbol, .name = "codedb_symbol", .args_json = "{\"name\":\"main\"}", .iterations = 100 },
    .{ .tool = .codedb_search, .name = "codedb_search", .args_json = "{\"query\":\"telemetry\",\"max_results\":10}", .iterations = 100 },
    .{ .tool = .codedb_word, .name = "codedb_word", .args_json = "{\"word\":\"Telemetry\"}", .iterations = 100 },
    .{ .tool = .codedb_hot, .name = "codedb_hot", .args_json = "{\"limit\":10}", .iterations = 100 },
    .{ .tool = .codedb_deps, .name = "codedb_deps", .args_json = "{\"path\":\"src/main.zig\"}", .iterations = 100 },
    .{ .tool = .codedb_read, .name = "codedb_read", .args_json = "{\"path\":\"src/main.zig\",\"line_start\":1,\"line_end\":20}", .iterations = 100 },
    .{ .tool = .codedb_edit, .name = "codedb_edit", .args_json = "{\"path\":\"src/bench_target.zig\",\"op\":\"replace\",\"range_start\":1,\"range_end\":1,\"content\":\"pub const bench_value = 2;\\n\"}", .iterations = 10 },
    .{ .tool = .codedb_changes, .name = "codedb_changes", .args_json = "{\"since\":0}", .iterations = 100 },
    .{ .tool = .codedb_status, .name = "codedb_status", .args_json = "{}", .iterations = 100 },
    .{ .tool = .codedb_snapshot, .name = "codedb_snapshot", .args_json = "{}", .iterations = 20 },
    .{ .tool = .codedb_bundle, .name = "codedb_bundle", .args_json = "{\"ops\":[{\"tool\":\"codedb_outline\",\"arguments\":{\"path\":\"src/main.zig\"}},{\"tool\":\"codedb_search\",\"arguments\":{\"query\":\"telemetry\",\"max_results\":5}},{\"tool\":\"codedb_word\",\"arguments\":{\"word\":\"Telemetry\"}}]}", .iterations = 50 },
    .{ .tool = .codedb_find, .name = "codedb_find", .args_json = "{\"query\":\"main\"}", .iterations = 100 },
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const emit_json = blk: {
        const args = try cio.argsAlloc(allocator);
        defer cio.argsFree(allocator, args);
        for (args[1..]) |arg| {
            if (std.mem.eql(u8, arg, "--json")) break :blk true;
        }
        break :blk false;
    };

    var tmp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_root = try makeTempCorpusDir(io, &tmp_path_buf);
    defer std.Io.Dir.cwd().deleteTree(io, tmp_root) catch {};

    var repo_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const repo_root_len = try std.Io.Dir.cwd().realPathFile(io, ".", &repo_path_buf);
    const repo_root = repo_path_buf[0..repo_root_len];

    try copyCorpus(io, allocator, repo_root, tmp_root);
    try writeBenchTarget(io, tmp_root);

    var store = Store.init(allocator);
    defer store.deinit();

    var explorer = Explorer.init(allocator);
    defer explorer.deinit();

    var agents = AgentRegistry.init(allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    try watcher.initialScan(io, &store, &explorer, tmp_root, allocator, false);

    var bench_ctx = mcp.BenchContext.init(allocator, tmp_root);
    defer bench_ctx.deinit();

    var telem_off = telemetry.Telemetry{ .enabled = false };
    var telem_on = telemetry.Telemetry{ .enabled = true };

    var args_store: [cases.len]std.json.Parsed(std.json.Value) = undefined;
    defer {
        for (&args_store) |*parsed| parsed.deinit();
    }

    for (cases, 0..) |case, idx| {
        args_store[idx] = try std.json.parseFromSlice(std.json.Value, allocator, case.args_json, .{});
    }

    var results: [cases.len]ToolBench = undefined;
    for (cases, 0..) |case, idx| {
        const args = &args_store[idx].value.object;
        const base = try runCase(allocator, &bench_ctx, &store, &explorer, &agents, case, args, &telem_off);
        const with_telem = try runCase(allocator, &bench_ctx, &store, &explorer, &agents, case, args, &telem_on);
        results[idx] = .{
            .tool = case.name,
            .avg_latency_ns = base.avg_latency_ns,
            .response_bytes = base.response_bytes,
            .ops_per_sec = opsPerSec(base.avg_latency_ns),
            .telemetry_avg_ns = with_telem.avg_latency_ns,
            .telemetry_delta_pct = deltaPct(base.avg_latency_ns, with_telem.avg_latency_ns),
        };
    }

    const corpus = summarizeCorpus(&explorer);
    try writeHumanSummary(allocator, cio.File.stderr(), corpus.files, corpus.bytes, &results);
    if (emit_json) {
        try writeJsonSummary(allocator, cio.File.stdout(), repo_root, tmp_root, corpus.files, corpus.bytes, &results);
    }
}

fn runCase(
    allocator: std.mem.Allocator,
    bench_ctx: *mcp.BenchContext,
    store: *Store,
    explorer: *Explorer,
    agents: *AgentRegistry,
    case: Case,
    args: *const std.json.ObjectMap,
    telem: *telemetry.Telemetry,
) !struct { avg_latency_ns: u64, response_bytes: usize } {
    var total_ns: u64 = 0;
    var response_bytes: usize = 0;

    for (0..case.iterations) |_| {
        if (case.tool == .codedb_edit) {
            try resetBenchTarget(explorer, store);
        }

        var timer = try cio.Timer.start();
        response_bytes = bench_ctx.runToolCall(allocator, case.name, case.tool, args, store, explorer, agents, telem);
        const elapsed = timer.read();
        total_ns +|= elapsed;
    }

    return .{
        .avg_latency_ns = @intCast(@divTrunc(total_ns, case.iterations)),
        .response_bytes = response_bytes,
    };
}

fn copyCorpus(io: std.Io, allocator: std.mem.Allocator, repo_root: []const u8, tmp_root: []const u8) !void {
    const files = [_][]const u8{
        "README.md",
        "build.zig",
        "build.zig.zon",
        "src/agent.zig",
        "src/bench.zig",
        "src/edit.zig",
        "src/explore.zig",
        "src/git.zig",
        "src/index.zig",
        "src/lib.zig",
        "src/main.zig",
        "src/mcp.zig",
        "src/root_policy.zig",
        "src/server.zig",
        "src/snapshot.zig",
        "src/snapshot_json.zig",
        "src/store.zig",
        "src/style.zig",
        "src/telemetry.zig",
        "src/version.zig",
        "src/watcher.zig",
    };

    for (files) |rel| {
        const src = try std.fs.path.join(allocator, &.{ repo_root, rel });
        defer allocator.free(src);
        const dst = try std.fs.path.join(allocator, &.{ tmp_root, rel });
        defer allocator.free(dst);

        if (std.fs.path.dirname(dst)) |parent| {
            try std.Io.Dir.cwd().createDirPath(io, parent);
        }

        try std.Io.Dir.copyFile(std.Io.Dir.cwd(), src, std.Io.Dir.cwd(), dst, io, .{});
    }
}


fn makeTempCorpusDir(io: std.Io, buf: *[std.fs.max_path_bytes]u8) ![]const u8 {
    const base = cio.posixGetenv("TMPDIR") orelse "/tmp";
    const ns = cio.nanoTimestamp();
    const seed: u64 = @intCast(@as(u128, @bitCast(ns)) & 0xffff_ffff_ffff_ffff);
    const path = if (base.len > 0 and base[base.len - 1] == '/')
        try std.fmt.bufPrint(buf, "{s}codedb-bench-{x}", .{ base, seed })
    else
        try std.fmt.bufPrint(buf, "{s}/codedb-bench-{x}", .{ base, seed });
    try std.Io.Dir.cwd().createDirPath(io, path);
    return path;
}
fn writeBenchTarget(io: std.Io, tmp_root: []const u8) !void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/src/bench_target.zig", .{tmp_root});
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, "pub const bench_value = 1;\n");
}

fn resetBenchTarget(explorer: *Explorer, store: *Store) !void {
    try explorer.indexFile("src/bench_target.zig", "pub const bench_value = 1;\n");
    _ = try store.recordSnapshot("src/bench_target.zig", "pub const bench_value = 1;\n".len, std.hash.Wyhash.hash(0, "pub const bench_value = 1;\n"));
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

fn writeHumanSummary(allocator: std.mem.Allocator, file: cio.File, file_count: usize, total_bytes: u64, results: []const ToolBench) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    const writer = out.writer(allocator);
    try writer.print("── E2E MCP Tool Benchmarks ({d} files, {d}KB) ──\n", .{ file_count, total_bytes / 1024 });
    try writer.writeAll("Tool              Latency    Size     Ops/sec   TelemetryΔ\n");
    for (results) |result| {
        var latency_buf: [32]u8 = undefined;
        var delta_buf: [32]u8 = undefined;
        try writer.print("{s:<17} {s:<10} {d:<8} {d:>8.0}   {s}\n", .{
            result.tool,
            formatNs(&latency_buf, result.avg_latency_ns),
            result.response_bytes,
            result.ops_per_sec,
            formatPct(&delta_buf, result.telemetry_delta_pct),
        });
    }
    try file.writeAll(out.items);
}

fn writeJsonSummary(allocator: std.mem.Allocator, file: cio.File, repo_root: []const u8, corpus_root: []const u8, file_count: usize, total_bytes: u64, results: []const ToolBench) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    const writer = out.writer(allocator);
    try writer.print("{{\"repo_root\":\"{s}\",\"corpus_root\":\"{s}\",\"file_count\":{d},\"total_bytes\":{d},\"tools\":[", .{
        repo_root,
        corpus_root,
        file_count,
        total_bytes,
    });
    for (results, 0..) |result, idx| {
        if (idx > 0) try writer.writeByte(',');
        try writer.print("{{\"tool\":\"{s}\",\"avg_latency_ns\":{d},\"response_bytes\":{d},\"ops_per_sec\":{d:.3},\"telemetry_avg_ns\":{d},\"telemetry_delta_pct\":{d:.3}}}", .{
            result.tool,
            result.avg_latency_ns,
            result.response_bytes,
            result.ops_per_sec,
            result.telemetry_avg_ns,
            result.telemetry_delta_pct,
        });
    }
    try writer.writeAll("]}\n");
    try file.writeAll(out.items);
}

fn opsPerSec(avg_latency_ns: u64) f64 {
    if (avg_latency_ns == 0) return 0;
    return @as(f64, 1_000_000_000.0) / @as(f64, @floatFromInt(avg_latency_ns));
}

fn deltaPct(base_ns: u64, with_telem_ns: u64) f64 {
    if (base_ns == 0) return 0;
    const delta = @as(f64, @floatFromInt(with_telem_ns)) - @as(f64, @floatFromInt(base_ns));
    return (delta / @as(f64, @floatFromInt(base_ns))) * 100.0;
}

fn formatNs(buf: []u8, ns: u64) []const u8 {
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

fn formatPct(buf: []u8, pct: f64) []const u8 {
    const abs_pct = @abs(pct);
    return std.fmt.bufPrint(buf, "{d:.2}%", .{abs_pct}) catch "0.00%";
}
