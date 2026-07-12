//! bench_comptime.zig — head-to-head: comptime-specialised vs runtime Regex.
//!
//! Wire shape:  nanoregex_bench_comptime <path> [iters]
//!
//! Reads `path` once, then runs three fixed patterns through both code paths:
//!
//!   1. "hello"   — pure-literal (comptime: needle constant; runtime: memmem)
//!   2. "\\d+"    — single-class (comptime: .rodata table; runtime: dfa+table)
//!   3. "[a-z]+"  — single-class (comptime: .rodata table; runtime: dfa+table)
//!
//! For each pattern we report:
//!   comptime mean, runtime mean, and the ratio (runtime/comptime ≥ 1 = comptime wins).
//!
//! We also accept the bench file path so the same 142 KB fixture used for
//! parity tests can be passed in as the haystack.

const std = @import("std");
const nanoregex = @import("nanoregex");

extern "c" fn write(fd: c_int, ptr: [*]const u8, len: usize) isize;
fn writeAll(fd: c_int, data: []const u8) void {
    var rem = data;
    while (rem.len > 0) {
        const n = write(fd, rem.ptr, rem.len);
        if (n <= 0) return;
        rem = rem[@intCast(n)..];
    }
}

const Timespec = extern struct { tv_sec: i64, tv_nsec: i64 };
extern "c" fn clock_gettime(clk: c_int, ts: *Timespec) c_int;
const CLOCK_MONOTONIC: c_int = 6;
fn nowNs() i128 {
    var ts: Timespec = .{ .tv_sec = 0, .tv_nsec = 0 };
    _ = clock_gettime(CLOCK_MONOTONIC, &ts);
    return @as(i128, ts.tv_sec) * 1_000_000_000 + ts.tv_nsec;
}

extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern "c" fn fclose(stream: *anyopaque) c_int;
extern "c" fn fread(ptr: [*]u8, size: usize, n: usize, stream: *anyopaque) usize;
extern "c" fn fseek(stream: *anyopaque, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: *anyopaque) c_long;
const SEEK_END: c_int = 2;
const SEEK_SET: c_int = 0;

fn readFile(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    var path_buf: [4096]u8 = undefined;
    if (path.len >= path_buf.len) return error.PathTooLong;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(&path_buf);
    const f = fopen(path_z, "rb") orelse return error.OpenFailed;
    defer _ = fclose(f);
    if (fseek(f, 0, SEEK_END) != 0) return error.SeekFailed;
    const size_raw = ftell(f);
    if (size_raw < 0) return error.SizeFailed;
    const size: usize = @intCast(size_raw);
    if (fseek(f, 0, SEEK_SET) != 0) return error.SeekFailed;
    const buf = try alloc.alloc(u8, size);
    errdefer alloc.free(buf);
    const n = fread(buf.ptr, 1, size, f);
    if (n != size) return error.ReadShort;
    return buf;
}

/// Run `findAll` `iters` times and return (mean_ns, match_count).
fn benchRuntime(alloc: std.mem.Allocator, pattern: []const u8, data: []const u8, iters: usize) !struct { mean_ns: f64, count: usize } {
    var r = try nanoregex.Regex.compile(alloc, pattern);
    defer r.deinit();

    // Warm-up.
    var count: usize = 0;
    {
        const ms = try r.findAll(alloc, data);
        count = ms.len;
        for (ms) |*m| @constCast(m).deinit(alloc);
        alloc.free(ms);
    }

    var total_ns: u128 = 0;
    var i: usize = 0;
    while (i < iters) : (i += 1) {
        const t0 = nowNs();
        const ms = try r.findAll(alloc, data);
        const t1 = nowNs();
        total_ns += @intCast(t1 - t0);
        count = ms.len;
        for (ms) |*m| @constCast(m).deinit(alloc);
        alloc.free(ms);
    }
    return .{
        .mean_ns = @as(f64, @floatFromInt(total_ns)) / @as(f64, @floatFromInt(iters)),
        .count = count,
    };
}

fn benchComptimeLiteral(alloc: std.mem.Allocator, data: []const u8, iters: usize) !struct { mean_ns: f64, count: usize } {
    const cx = comptime nanoregex.compileComptime("hello");

    // Warm-up.
    var count: usize = 0;
    {
        const ms = try cx.findAll(alloc, data);
        count = ms.len;
        for (ms) |*m| @constCast(m).deinit(alloc);
        alloc.free(ms);
    }

    var total_ns: u128 = 0;
    var i: usize = 0;
    while (i < iters) : (i += 1) {
        const t0 = nowNs();
        const ms = try cx.findAll(alloc, data);
        const t1 = nowNs();
        total_ns += @intCast(t1 - t0);
        count = ms.len;
        for (ms) |*m| @constCast(m).deinit(alloc);
        alloc.free(ms);
    }
    return .{
        .mean_ns = @as(f64, @floatFromInt(total_ns)) / @as(f64, @floatFromInt(iters)),
        .count = count,
    };
}

fn benchComptimeDigits(alloc: std.mem.Allocator, data: []const u8, iters: usize) !struct { mean_ns: f64, count: usize } {
    const cx = comptime nanoregex.compileComptime("\\d+");

    var count: usize = 0;
    {
        const ms = try cx.findAll(alloc, data);
        count = ms.len;
        for (ms) |*m| @constCast(m).deinit(alloc);
        alloc.free(ms);
    }

    var total_ns: u128 = 0;
    var i: usize = 0;
    while (i < iters) : (i += 1) {
        const t0 = nowNs();
        const ms = try cx.findAll(alloc, data);
        const t1 = nowNs();
        total_ns += @intCast(t1 - t0);
        count = ms.len;
        for (ms) |*m| @constCast(m).deinit(alloc);
        alloc.free(ms);
    }
    return .{
        .mean_ns = @as(f64, @floatFromInt(total_ns)) / @as(f64, @floatFromInt(iters)),
        .count = count,
    };
}

fn benchComptimeLower(alloc: std.mem.Allocator, data: []const u8, iters: usize) !struct { mean_ns: f64, count: usize } {
    const cx = comptime nanoregex.compileComptime("[a-z]+");

    var count: usize = 0;
    {
        const ms = try cx.findAll(alloc, data);
        count = ms.len;
        for (ms) |*m| @constCast(m).deinit(alloc);
        alloc.free(ms);
    }

    var total_ns: u128 = 0;
    var i: usize = 0;
    while (i < iters) : (i += 1) {
        const t0 = nowNs();
        const ms = try cx.findAll(alloc, data);
        const t1 = nowNs();
        total_ns += @intCast(t1 - t0);
        count = ms.len;
        for (ms) |*m| @constCast(m).deinit(alloc);
        alloc.free(ms);
    }
    return .{
        .mean_ns = @as(f64, @floatFromInt(total_ns)) / @as(f64, @floatFromInt(iters)),
        .count = count,
    };
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;

    var args_list: std.ArrayList([]const u8) = .empty;
    defer args_list.deinit(alloc);
    var args_iter = init.minimal.args.iterate();
    while (args_iter.next()) |a| try args_list.append(alloc, a);
    const args = args_list.items;

    if (args.len < 2) {
        writeAll(2, "usage: nanoregex_bench_comptime <path> [iters]\n");
        std.process.exit(2);
    }

    const path = args[1];
    const iters: usize = if (args.len >= 3)
        std.fmt.parseInt(usize, args[2], 10) catch 50
    else
        50;

    const data = readFile(alloc, path) catch |err| {
        var tmp: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&tmp, "read error: {s}\n", .{@errorName(err)}) catch "read error\n";
        writeAll(2, msg);
        std.process.exit(1);
    };
    defer alloc.free(data);

    var hdr: [128]u8 = undefined;
    const hdr_line = std.fmt.bufPrint(&hdr, "nanoregex_bench_comptime  file={s} size={d}KB iters={d}\n", .{
        path, data.len / 1024, iters,
    }) catch "header\n";
    writeAll(1, hdr_line);
    writeAll(1, "pattern          comptime(µs)  runtime(µs)  ratio(rt/ct)\n");
    writeAll(1, "──────────────────────────────────────────────────────────\n");

    // Pattern 1: pure literal "hello"
    {
        const ct = try benchComptimeLiteral(alloc, data, iters);
        const rt = try benchRuntime(alloc, "hello", data, iters);
        const ratio = rt.mean_ns / ct.mean_ns;
        var line: [256]u8 = undefined;
        const s = std.fmt.bufPrint(&line, "\"hello\"          {d:>10.2}    {d:>10.2}     {d:.2}x  (matches={d})\n", .{ ct.mean_ns / 1000.0, rt.mean_ns / 1000.0, ratio, ct.count }) catch "";
        writeAll(1, s);
    }

    // Pattern 2: \d+
    {
        const ct = try benchComptimeDigits(alloc, data, iters);
        const rt = try benchRuntime(alloc, "\\d+", data, iters);
        const ratio = rt.mean_ns / ct.mean_ns;
        var line: [256]u8 = undefined;
        const s = std.fmt.bufPrint(&line, "\"\\d+\"            {d:>10.2}    {d:>10.2}     {d:.2}x  (matches={d})\n", .{ ct.mean_ns / 1000.0, rt.mean_ns / 1000.0, ratio, ct.count }) catch "";
        writeAll(1, s);
    }

    // Pattern 3: [a-z]+
    {
        const ct = try benchComptimeLower(alloc, data, iters);
        const rt = try benchRuntime(alloc, "[a-z]+", data, iters);
        const ratio = rt.mean_ns / ct.mean_ns;
        var line: [256]u8 = undefined;
        const s = std.fmt.bufPrint(&line, "\"[a-z]+\"         {d:>10.2}    {d:>10.2}     {d:.2}x  (matches={d})\n", .{ ct.mean_ns / 1000.0, rt.mean_ns / 1000.0, ratio, ct.count }) catch "";
        writeAll(1, s);
    }
}
