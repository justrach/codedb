//! Current and peak resident set size.
//!
//! Linux: `/proc/self/status` `VmRSS` (current) and `VmHWM` (peak), in KiB.
//! macOS: `mach_task_basic_info` `resident_size` / `resident_size_max`, in bytes.

const std = @import("std");
const builtin = @import("builtin");

pub const Sample = struct {
    current_kib: u64,
    peak_kib: ?u64 = null,
};

pub fn sampleSelf() ?Sample {
    if (builtin.os.tag == .linux) return linuxSelf();
    if (builtin.os.tag == .macos) return darwinSelf();
    return null;
}

pub fn currentKiB() ?u64 {
    const sample = sampleSelf() orelse return null;
    return sample.current_kib;
}

pub fn currentMiB() ?u64 {
    const kib = currentKiB() orelse return null;
    return kib / 1024;
}

pub fn peakMiB() ?u64 {
    const sample = sampleSelf() orelse return null;
    const kib = sample.peak_kib orelse return null;
    return kib / 1024;
}

pub fn parseLinuxStatus(text: []const u8) ?Sample {
    const current = parseStatusKiB(text, "VmRSS:") orelse return null;
    return .{
        .current_kib = current,
        .peak_kib = parseStatusKiB(text, "VmHWM:"),
    };
}

pub fn parseStatusKiB(text: []const u8, key: []const u8) ?u64 {
    const idx = std.mem.indexOf(u8, text, key) orelse return null;
    var rest = text[idx + key.len ..];
    while (rest.len > 0 and (rest[0] == ' ' or rest[0] == '\t')) rest = rest[1..];
    var end: usize = 0;
    while (end < rest.len and rest[end] >= '0' and rest[end] <= '9') end += 1;
    if (end == 0) return null;
    return std.fmt.parseInt(u64, rest[0..end], 10) catch null;
}

fn linuxSelf() ?Sample {
    const posix = std.posix;
    const linux = std.os.linux;
    const fd = posix.openat(posix.AT.FDCWD, "/proc/self/status", .{ .ACCMODE = .RDONLY }, 0) catch return null;
    defer _ = linux.close(fd);
    var buf: [4096]u8 = undefined;
    const n = linux.read(fd, &buf, buf.len);
    if (posix.errno(n) != .SUCCESS) return null;
    return parseLinuxStatus(buf[0..n]);
}

const mach = if (builtin.os.tag == .macos) struct {
    const MACH_TASK_BASIC_INFO: c_int = 20;
    const Info = extern struct {
        virtual_size: u64,
        resident_size: u64,
        resident_size_max: u64,
        user_seconds: i32,
        user_microseconds: i32,
        system_seconds: i32,
        system_microseconds: i32,
        policy: i32,
        suspend_count: i32,
    };
    extern "c" fn mach_task_self() u32;
    extern "c" fn task_info(task: u32, flavor: c_int, info: *anyopaque, count: *u32) c_int;
} else struct {};

fn darwinSelf() ?Sample {
    if (comptime builtin.os.tag != .macos) return null;
    var info: mach.Info = std.mem.zeroes(mach.Info);
    var count: u32 = @intCast(@sizeOf(mach.Info) / @sizeOf(u32));
    const result = mach.task_info(mach.mach_task_self(), mach.MACH_TASK_BASIC_INFO, @ptrCast(&info), &count);
    if (result != 0) return null;
    return .{
        .current_kib = info.resident_size / 1024,
        .peak_kib = info.resident_size_max / 1024,
    };
}

test "parseLinuxStatus reads VmRSS and VmHWM" {
    const fixture =
        "Name: openpuffer\n" ++
        "VmPeak:   512000 kB\n" ++
        "VmSize:   500000 kB\n" ++
        "VmHWM:   300000 kB\n" ++
        "VmRSS:   291432 kB\n";
    const sample = parseLinuxStatus(fixture) orelse return error.ParseFailed;
    try std.testing.expectEqual(@as(u64, 291432), sample.current_kib);
    try std.testing.expectEqual(@as(u64, 300000), sample.peak_kib.?);
    try std.testing.expectEqual(@as(u64, 284), sample.current_kib / 1024);
}

test "parseLinuxStatus requires VmRSS" {
    try std.testing.expect(parseLinuxStatus("VmHWM:\t10 kB\n") == null);
    try std.testing.expect(parseStatusKiB("VmRSS:\n", "VmRSS:") == null);
}

test "self sample is numeric on supported hosts" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const sample = sampleSelf() orelse return error.RssUnavailable;
    try std.testing.expect(sample.current_kib > 0);
}

test "MiB conversion is floor(kib/1024)" {
    try std.testing.expectEqual(@as(u64, 0), @as(u64, 1023) / 1024);
    try std.testing.expectEqual(@as(u64, 1), @as(u64, 1024) / 1024);
}
