/// WSL1 compatibility layer.
///
/// Zig 0.15's `File.stat()` and `Dir.statFile()` use the `statx` syscall on
/// Linux with no fallback when `ENOSYS` is returned. WSL1 runs kernel 4.4
/// which predates `statx` (added in 4.11), so every stat call fails with
/// `error.Unexpected`.
///
/// This module detects the situation at startup and provides drop-in
/// replacements that go through `fstat`/`fstatat64` instead.
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const linux = std.os.linux;
const fs = std.fs;

/// Cached result of the runtime statx probe.
var statx_supported: enum(u8) { unknown = 0, yes = 1, no = 2 } = .unknown;

/// Probe once whether the running kernel supports `statx`.
fn hasStatx() bool {
    // Fast path: already probed.
    const cached = @atomicLoad(@TypeOf(statx_supported), &statx_supported, .acquire);
    if (cached == .yes) return true;
    if (cached == .no) return false;

    // Probe: call statx on stdin with an empty mask. On kernels that
    // support it this is a cheap no-op; on WSL1 it returns ENOSYS.
    var stx = std.mem.zeroes(linux.Statx);
    const rc = linux.statx(
        // Use AT.FDCWD (-100) with path "." as a safe, always-valid probe target
        linux.AT.FDCWD,
        ".",
        0,
        0,
        &stx,
    );
    const supported: bool = linux.E.init(rc) != .NOSYS;
    @atomicStore(@TypeOf(statx_supported), &statx_supported, if (supported) .yes else .no, .release);
    return supported;
}

/// Stat result matching the fields codedb actually uses (size, mtime).
pub const Stat = struct {
    size: u64,
    mtime: i128,
    kind: fs.File.Kind,
};

/// `File.stat()` replacement that falls back to `fstat` on WSL1.
pub fn fileStat(file: fs.File) fs.File.StatError!Stat {
    if (comptime builtin.os.tag != .linux) {
        const st = try file.stat();
        return .{ .size = st.size, .mtime = st.mtime, .kind = st.kind };
    }

    if (hasStatx()) {
        const st = try file.stat();
        return .{ .size = st.size, .mtime = st.mtime, .kind = st.kind };
    }

    // Fallback: use posix.fstat which calls the fstat64 syscall directly.
    const st = try posix.fstat(file.handle);
    return .{
        .size = @intCast(st.size),
        .mtime = @as(i128, st.mtime().sec) * std.time.ns_per_s + st.mtime().nsec,
        .kind = fileTypeFromMode(st.mode),
    };
}

/// `Dir.statFile()` replacement that falls back to `fstatat` on WSL1.
pub fn dirStatFile(dir: fs.Dir, sub_path: []const u8) (fs.File.OpenError || fs.File.StatError || posix.FStatAtError)!Stat {
    if (comptime builtin.os.tag != .linux) {
        const st = try dir.statFile(sub_path);
        return .{ .size = st.size, .mtime = st.mtime, .kind = st.kind };
    }

    if (hasStatx()) {
        const st = try dir.statFile(sub_path);
        return .{ .size = st.size, .mtime = st.mtime, .kind = st.kind };
    }

    // Fallback: use posix.fstatat which calls fstatat64 directly.
    const st = try posix.fstatat(dir.fd, sub_path, 0);
    return .{
        .size = @intCast(st.size),
        .mtime = @as(i128, st.mtime().sec) * std.time.ns_per_s + st.mtime().nsec,
        .kind = fileTypeFromMode(st.mode),
    };
}

/// `Dir.makePath()` replacement. On WSL1 the stdlib's `makePath` fails
/// because it calls `statFile` (which uses statx) when the directory
/// already exists.  We implement a simple recursive mkdir that tolerates
/// EEXIST without needing stat.
pub fn makePath(dir: fs.Dir, sub_path: []const u8) !void {
    if (comptime builtin.os.tag != .linux) {
        return dir.makePath(sub_path);
    }

    if (hasStatx()) {
        return dir.makePath(sub_path);
    }

    // Simple iterative mkdir: split path by '/' and create each component.
    // Tolerate EEXIST (component already exists).
    var it = try fs.path.componentIterator(sub_path);
    var component = it.first() orelse return;
    while (true) {
        dir.makeDir(component.path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            error.FileNotFound => {
                // Parent doesn't exist yet — should not happen with forward iteration
                // from first component, but handle gracefully.
                return err;
            },
            else => return err,
        };
        component = it.next() orelse return;
    }
}

fn fileTypeFromMode(mode: u32) fs.File.Kind {
    const file_type = mode & 0o170000;
    return switch (file_type) {
        0o040000 => .directory,
        0o100000 => .file,
        0o120000 => .sym_link,
        0o010000 => .named_pipe,
        0o140000 => .unix_domain_socket,
        0o060000 => .block_device,
        0o020000 => .character_device,
        else => .unknown,
    };
}
