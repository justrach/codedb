//! cio.zig — 0.16 stdlib compatibility shim.
//!
//! 0.16 removed std.fs.File.{stdout,stderr,stdin}, cio.Mutex/RwLock,
//! std.time.Timer, std.time.nanoTimestamp, std.process.Child.run, and
//! cio.posixGetenv. This shim wraps libc/pthread primitives so existing
//! call sites continue to work with minimal import-line changes.

const std = @import("std");
const builtin = @import("builtin");

extern "c" fn write(fd: c_int, ptr: [*]const u8, len: usize) isize;
extern "c" fn read(fd: c_int, ptr: [*]u8, len: usize) isize;
extern "c" fn isatty(fd: c_int) c_int;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn clock_gettime(id: c_int, ts: *std.c.timespec) c_int;
extern "c" fn pipe(fds: *[2]c_int) c_int;
extern "c" fn close(fd: c_int) c_int;

const CLOCK_REALTIME: c_int = 0;
const CLOCK_MONOTONIC: c_int = if (builtin.os.tag == .macos) 6 else 1;

// ── Stdio ────────────────────────────────────────────────────────────────

pub const File = struct {
    handle: c_int,

    pub fn stdout() File {
        return .{ .handle = 1 };
    }
    pub fn stderr() File {
        return .{ .handle = 2 };
    }
    pub fn stdin() File {
        return .{ .handle = 0 };
    }

    pub fn isTty(self: File) bool {
        return isatty(self.handle) != 0;
    }

    pub fn writeAll(self: File, data: []const u8) !void {
        var rem = data;
        while (rem.len > 0) {
            const n = write(self.handle, rem.ptr, rem.len);
            if (n <= 0) return error.WriteFailed;
            rem = rem[@intCast(n)..];
        }
    }

    pub fn print(self: File, comptime fmt: []const u8, args: anytype) !void {
        var buf: [8192]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, fmt, args) catch {
            const big = try std.fmt.allocPrint(std.heap.c_allocator, fmt, args);
            defer std.heap.c_allocator.free(big);
            return self.writeAll(big);
        };
        try self.writeAll(s);
    }
};

// ── Threads / Sync ───────────────────────────────────────────────────────

pub const Mutex = struct {
    inner: std.c.pthread_mutex_t = .{},

    pub fn lock(self: *Mutex) void {
        _ = std.c.pthread_mutex_lock(&self.inner);
    }
    pub fn unlock(self: *Mutex) void {
        _ = std.c.pthread_mutex_unlock(&self.inner);
    }
    pub fn tryLock(self: *Mutex) bool {
        return std.c.pthread_mutex_trylock(&self.inner) == .SUCCESS;
    }
};

pub const RwLock = struct {
    inner: std.c.pthread_rwlock_t = .{},

    pub fn lock(self: *RwLock) void {
        _ = std.c.pthread_rwlock_wrlock(&self.inner);
    }
    pub fn unlock(self: *RwLock) void {
        _ = std.c.pthread_rwlock_unlock(&self.inner);
    }
    pub fn lockShared(self: *RwLock) void {
        _ = std.c.pthread_rwlock_rdlock(&self.inner);
    }
    pub fn unlockShared(self: *RwLock) void {
        _ = std.c.pthread_rwlock_unlock(&self.inner);
    }
    pub fn tryLock(self: *RwLock) bool {
        return std.c.pthread_rwlock_trywrlock(&self.inner) == .SUCCESS;
    }
    pub fn tryLockShared(self: *RwLock) bool {
        return std.c.pthread_rwlock_tryrdlock(&self.inner) == .SUCCESS;
    }
};

// ── Time ─────────────────────────────────────────────────────────────────

pub fn nanoTimestamp() i128 {
    var ts: std.c.timespec = undefined;
    _ = clock_gettime(CLOCK_REALTIME, &ts);
    return @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
}

pub fn milliTimestamp() i64 {
    var ts: std.c.timespec = undefined;
    _ = clock_gettime(CLOCK_REALTIME, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

pub const Timer = struct {
    start_ns: i128,

    pub fn start() !Timer {
        var ts: std.c.timespec = undefined;
        _ = clock_gettime(CLOCK_MONOTONIC, &ts);
        return .{ .start_ns = @as(i128, ts.sec) * 1_000_000_000 + ts.nsec };
    }

    pub fn read(self: *Timer) u64 {
        var ts: std.c.timespec = undefined;
        _ = clock_gettime(CLOCK_MONOTONIC, &ts);
        const now = @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
        return @intCast(now - self.start_ns);
    }

    pub fn lap(self: *Timer) u64 {
        var ts: std.c.timespec = undefined;
        _ = clock_gettime(CLOCK_MONOTONIC, &ts);
        const now = @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
        const delta: u64 = @intCast(now - self.start_ns);
        self.start_ns = now;
        return delta;
    }
};

// ── Environment ──────────────────────────────────────────────────────────

pub fn sleepMs(ms: u64) void {
    var ts: std.c.timespec = .{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * 1_000_000),
    };
    _ = std.c.nanosleep(&ts, null);
}

pub fn posixGetenv(name: []const u8) ?[]const u8 {
    var buf: [256]u8 = undefined;
    if (name.len >= buf.len) return null;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    const ptr = getenv(@ptrCast(&buf)) orelse return null;
    return std.mem.span(ptr);
}

// ── Arguments ────────────────────────────────────────────────────────────

extern "c" fn _NSGetArgc() *c_int;
extern "c" fn _NSGetArgv() *[*][*:0]u8;

/// Shim for cio.argsAlloc (removed in 0.16). Returns a duplicated
/// slice of argv strings owned by the allocator; free with argsFree.
pub fn argsAlloc(alloc: std.mem.Allocator) ![][:0]u8 {
    const argc: usize = @intCast(_NSGetArgc().*);
    const argv = _NSGetArgv().*;
    const out = try alloc.alloc([:0]u8, argc);
    errdefer alloc.free(out);
    var filled: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < filled) : (i += 1) alloc.free(out[i]);
    }
    while (filled < argc) : (filled += 1) {
        const s = std.mem.span(@as([*:0]const u8, argv[filled]));
        const dup = try alloc.allocSentinel(u8, s.len, 0);
        @memcpy(dup[0..s.len], s);
        out[filled] = dup;
    }
    return out;
}

pub fn argsFree(alloc: std.mem.Allocator, args: [][:0]u8) void {
    for (args) |a| alloc.free(a);
    alloc.free(args);
}

// ── ArrayList writer helper (replaces 0.15's ArrayList(u8).writer(alloc)) ────

pub const ListWriter = struct {
    list: *std.ArrayList(u8),
    alloc: std.mem.Allocator,

    pub fn writeAll(self: ListWriter, bytes: []const u8) !void {
        try self.list.appendSlice(self.alloc, bytes);
    }
    pub fn writeByte(self: ListWriter, b: u8) !void {
        try self.list.append(self.alloc, b);
    }
    pub fn writeByteNTimes(self: ListWriter, b: u8, n: usize) !void {
        try self.list.appendNTimes(self.alloc, b, n);
    }
    pub fn writeBytesNTimes(self: ListWriter, bytes: []const u8, n: usize) !void {
        var i: usize = 0;
        while (i < n) : (i += 1) try self.list.appendSlice(self.alloc, bytes);
    }
    pub fn print(self: ListWriter, comptime fmt: []const u8, args: anytype) !void {
        var stack_buf: [8192]u8 = undefined;
        const s = std.fmt.bufPrint(&stack_buf, fmt, args) catch {
            const big = try std.fmt.allocPrint(self.alloc, fmt, args);
            defer self.alloc.free(big);
            try self.list.appendSlice(self.alloc, big);
            return;
        };
        try self.list.appendSlice(self.alloc, s);
    }
};

pub fn listWriter(list: *std.ArrayList(u8), alloc: std.mem.Allocator) ListWriter {
    return .{ .list = list, .alloc = alloc };
}

// ── Subprocess ───────────────────────────────────────────────────────────

pub const CaptureResult = struct {
    stdout: []u8,
    stderr: []u8,
    term: Term,

    pub const Term = union(enum) {
        Exited: u8,
        Signal: u32,
        Stopped: u32,
        Unknown: u32,
    };
};

pub const RunOptions = struct {
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    max_output_bytes: usize = 50 * 1024 * 1024,
};

extern "c" fn _NSGetEnviron() *[*:null]?[*:0]u8;

/// Shim for std.process.Child.run — fast posix_spawnp path, merges stderr into stdout.
pub fn runCapture(opts: RunOptions) !CaptureResult {
    if (opts.argv.len == 0) return error.EmptyArgv;
    const alloc = opts.allocator;

    const c_argv = try alloc.alloc(?[*:0]const u8, opts.argv.len + 1);
    defer alloc.free(c_argv);
    const arg_bufs = try alloc.alloc([]u8, opts.argv.len);
    defer {
        for (arg_bufs) |b| alloc.free(b);
        alloc.free(arg_bufs);
    }
    for (opts.argv, 0..) |a, i| {
        const buf = try alloc.alloc(u8, a.len + 1);
        @memcpy(buf[0..a.len], a);
        buf[a.len] = 0;
        arg_bufs[i] = buf;
        c_argv[i] = @ptrCast(buf.ptr);
    }
    c_argv[opts.argv.len] = null;
    const c_argv_z: [*:null]const ?[*:0]const u8 = @ptrCast(c_argv.ptr);

    var out_pipe: [2]c_int = .{ -1, -1 };
    if (pipe(&out_pipe) != 0) return error.PipeFailed;
    errdefer {
        if (out_pipe[0] >= 0) _ = close(out_pipe[0]);
        if (out_pipe[1] >= 0) _ = close(out_pipe[1]);
    }

    var fa: std.c.posix_spawn_file_actions_t = undefined;
    if (std.c.posix_spawn_file_actions_init(&fa) != 0) return error.SpawnInitFailed;
    defer _ = std.c.posix_spawn_file_actions_destroy(&fa);

    if (opts.cwd) |cwd| {
        var cwd_buf: [4096]u8 = undefined;
        if (cwd.len >= cwd_buf.len) return error.PathTooLong;
        @memcpy(cwd_buf[0..cwd.len], cwd);
        cwd_buf[cwd.len] = 0;
        if (@hasDecl(std.c, "posix_spawn_file_actions_addchdir_np")) {
            _ = std.c.posix_spawn_file_actions_addchdir_np(&fa, @ptrCast(&cwd_buf));
        } else {
            return error.CwdNotSupported;
        }
    }

    _ = std.c.posix_spawn_file_actions_adddup2(&fa, out_pipe[1], 1);
    _ = std.c.posix_spawn_file_actions_adddup2(&fa, out_pipe[1], 2);
    _ = std.c.posix_spawn_file_actions_addclose(&fa, out_pipe[0]);
    _ = std.c.posix_spawn_file_actions_addclose(&fa, out_pipe[1]);

    const envp: [*:null]const ?[*:0]const u8 = if (builtin.os.tag == .macos)
        @ptrCast(_NSGetEnviron().*)
    else
        @ptrCast(std.c.environ);

    var pid: std.c.pid_t = 0;
    if (std.c.posix_spawnp(&pid, c_argv[0].?, &fa, null, c_argv_z, envp) != 0)
        return error.SpawnFailed;

    _ = close(out_pipe[1]);
    out_pipe[1] = -1;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var chunk: [64 * 1024]u8 = undefined;
    while (out.items.len < opts.max_output_bytes) {
        const want = @min(chunk.len, opts.max_output_bytes - out.items.len);
        const n = read(out_pipe[0], &chunk, want);
        if (n <= 0) break;
        try out.appendSlice(alloc, chunk[0..@intCast(n)]);
    }
    _ = close(out_pipe[0]);
    out_pipe[0] = -1;

    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);

    const term: CaptureResult.Term = if ((status & 0x7f) == 0)
        .{ .Exited = @intCast((status >> 8) & 0xff) }
    else if ((status & 0x7f) != 0x7f)
        .{ .Signal = @intCast(status & 0x7f) }
    else
        .{ .Stopped = @intCast((status >> 8) & 0xff) };

    return .{
        .stdout = try out.toOwnedSlice(alloc),
        .stderr = try alloc.alloc(u8, 0),
        .term = term,
    };
}
