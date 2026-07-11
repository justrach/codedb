//! Single-file regex benchmark.
//!
//! Wire shape:  nanoregex_bench <pattern> <path> [iters]
//!
//! Reads `path` into memory once, then runs `r.findAll` against it `iters`
//! times (default 20). Prints mean per-iteration time + match count so the
//! comparison script can diff us against python re and zig-regex on the
//! exact same input.
//!
//! We measure findAll only — not parse/compile — because the latter is a
//! one-shot cost the user pays once per CLI invocation, while findAll
//! dominates real workloads (walks across thousands of files).

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

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;

    var args_list: std.ArrayList([]const u8) = .empty;
    defer args_list.deinit(alloc);
    var args_iter = init.minimal.args.iterate();
    while (args_iter.next()) |a| try args_list.append(alloc, a);
    const args = args_list.items;
    if (args.len < 3) {
        writeAll(2, "usage: nanoregex_bench <pattern> <path> [iters]\n");
        std.process.exit(2);
    }

    const pattern = args[1];
    const path = args[2];
    const iters: usize = if (args.len >= 4)
        std.fmt.parseInt(usize, args[3], 10) catch 20
    else
        20;

    // Read the whole file. Using libc fopen+fread to avoid the std.fs API
    // churn in 0.16 — this binary is throwaway so the simplest path wins.
    const data = readFile(alloc, path) catch |err| {
        var tmp: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&tmp, "read error: {s}\n", .{@errorName(err)}) catch "read error\n";
        writeAll(2, msg);
        std.process.exit(1);
    };
    defer alloc.free(data);

    var r = nanoregex.Regex.compile(alloc, pattern) catch |err| {
        var tmp: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&tmp, "parse error: {s}\n", .{@errorName(err)}) catch "parse error\n";
        writeAll(2, msg);
        std.process.exit(1);
    };
    defer r.deinit();

    var total_ns: u128 = 0;
    var match_count: usize = 0;

    // One untimed warm-up so JIT-like effects don't bias the first sample.
    {
        const ms = r.findAll(alloc, data) catch {
            writeAll(2, "engine error during warm-up\n");
            std.process.exit(1);
        };
        match_count = ms.len;
        for (ms) |*m| @constCast(m).deinit(alloc);
        alloc.free(ms);
    }

    var iter: usize = 0;
    while (iter < iters) : (iter += 1) {
        const start_ns = nowNs();
        const ms = r.findAll(alloc, data) catch {
            writeAll(2, "engine error in timed loop\n");
            std.process.exit(1);
        };
        const end_ns = nowNs();
        total_ns += @intCast(end_ns - start_ns);
        match_count = ms.len;
        for (ms) |*m| @constCast(m).deinit(alloc);
        alloc.free(ms);
    }

    const mean_ms: f64 = @as(f64, @floatFromInt(total_ns)) / @as(f64, @floatFromInt(iters)) / 1_000_000.0;

    var out_buf: [256]u8 = undefined;
    const line = std.fmt.bufPrint(&out_buf, "nanoregex: matches={d} mean={d:.3}ms ({d}KB, {d} iters)\n", .{
        match_count,
        mean_ms,
        data.len / 1024,
        iters,
    }) catch return;
    writeAll(1, line);
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
