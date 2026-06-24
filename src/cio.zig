//! cio.zig — 0.16 stdlib compatibility shim.
//!
//! 0.16 removed std.fs.File.{stdout,stderr,stdin}, cio.Mutex/RwLock,
//! std.time.Timer, std.time.nanoTimestamp, std.process.Child.run, and
//! cio.posixGetenv. This shim wraps libc/pthread primitives so existing
//! call sites continue to work with minimal import-line changes.

const std = @import("std");
const builtin = @import("builtin");

const is_windows = builtin.os.tag == .windows;

// POSIX libc byte-I/O on integer fds. On Windows the CRT spells the same
// primitives with a leading underscore; the cross-platform wrappers below pick
// the right symbol per target. Unreferenced externs are never linked, so the
// posix decls cost nothing on a Windows build and vice-versa.
const posix_libc = struct {
    extern "c" fn write(fd: c_int, ptr: [*]const u8, len: usize) isize;
    extern "c" fn read(fd: c_int, ptr: [*]u8, len: usize) isize;
    extern "c" fn isatty(fd: c_int) c_int;
    extern "c" fn close(fd: c_int) c_int;
    extern "c" fn open(path: [*:0]const u8, oflag: c_int) c_int;
    extern "c" fn pipe(fds: *[2]c_int) c_int;
    extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
    extern "c" fn clock_gettime(id: c_int, ts: *std.c.timespec) c_int;
};
const win_libc = struct {
    extern "c" fn _write(fd: c_int, ptr: [*]const u8, count: c_uint) c_int;
    extern "c" fn _read(fd: c_int, ptr: [*]u8, count: c_uint) c_int;
    extern "c" fn _isatty(fd: c_int) c_int;
    extern "c" fn _close(fd: c_int) c_int;
    extern "c" fn _pipe(fds: *[2]c_int, size: c_uint, mode: c_int) c_int;
    extern "c" fn _putenv_s(name: [*:0]const u8, value: [*:0]const u8) c_int;
    extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
};

fn write(fd: c_int, ptr: [*]const u8, len: usize) isize {
    if (is_windows) return win_libc._write(fd, ptr, @intCast(@min(len, @as(usize, 0x7fff_ffff))));
    return posix_libc.write(fd, ptr, len);
}

fn read(fd: c_int, ptr: [*]u8, len: usize) isize {
    if (is_windows) return win_libc._read(fd, ptr, @intCast(@min(len, @as(usize, 0x7fff_ffff))));
    return posix_libc.read(fd, ptr, len);
}

fn isatty(fd: c_int) c_int {
    return if (is_windows) win_libc._isatty(fd) else posix_libc.isatty(fd);
}

fn close(fd: c_int) c_int {
    return if (is_windows) win_libc._close(fd) else posix_libc.close(fd);
}

fn getenv(name: [*:0]const u8) ?[*:0]const u8 {
    return if (is_windows) win_libc.getenv(name) else posix_libc.getenv(name);
}

/// Ignore SIGPIPE so a closed downstream pipe (`codedb ... | head`) surfaces as
/// a write error instead of killing the process. No-op on Windows — there is no
/// SIGPIPE; a broken pipe is reported through the write call's return value.
pub fn ignoreSigpipe() void {
    if (is_windows) {
        return;
    } else {
        var act: std.posix.Sigaction = .{
            .handler = .{ .handler = std.posix.SIG.IGN },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.PIPE, &act, null);
    }
}

/// Detach a daemonized child from its controlling terminal: start a new
/// session (so it survives the spawning shell / parent CLI) and point
/// stdin/stdout/stderr at /dev/null (so it never holds the terminal open or
/// writes stray bytes to it). Best-effort — every step ignores errors, since a
/// failure here only means the daemon keeps an inherited fd, not that it
/// malfunctions. Called once at cli-daemon startup. On Windows the equivalent
/// detachment is requested at spawn time (DETACHED_PROCESS), so this is a no-op.
pub fn detachFromTerminal() void {
    if (is_windows) {
        return;
    } else {
        _ = std.c.setsid();
        // O_RDWR == 2 on both Darwin and Linux.
        const fd = posix_libc.open("/dev/null", 2);
        if (fd >= 0) {
            _ = std.c.dup2(fd, 0);
            _ = std.c.dup2(fd, 1);
            _ = std.c.dup2(fd, 2);
            if (fd > 2) _ = close(fd);
        }
    }
}

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

// ── Windows kernel32 (time + sync) ─────────────────────────────────────────
// 0.16's std.time has no nanoTimestamp/Timer and std.Io.Mutex needs an Io, so
// cio talks to the OS directly: pthread + clock_gettime on POSIX, SRWLOCK +
// QueryPerformanceCounter / FILETIME on Windows.
const winsync = if (is_windows) struct {
    const BOOL = std.os.windows.BOOL;
    const DWORD = std.os.windows.DWORD;
    const FILETIME = extern struct { dwLowDateTime: u32, dwHighDateTime: u32 };
    const SRWLOCK = extern struct { ptr: ?*anyopaque = null };
    extern "kernel32" fn GetSystemTimePreciseAsFileTime(lpSystemTimeAsFileTime: *FILETIME) callconv(.winapi) void;
    extern "kernel32" fn QueryPerformanceCounter(lpPerformanceCount: *i64) callconv(.winapi) BOOL;
    extern "kernel32" fn QueryPerformanceFrequency(lpFrequency: *i64) callconv(.winapi) BOOL;
    extern "kernel32" fn Sleep(dwMilliseconds: DWORD) callconv(.winapi) void;
    extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) DWORD;
    extern "kernel32" fn AcquireSRWLockExclusive(l: *SRWLOCK) callconv(.winapi) void;
    extern "kernel32" fn ReleaseSRWLockExclusive(l: *SRWLOCK) callconv(.winapi) void;
    extern "kernel32" fn TryAcquireSRWLockExclusive(l: *SRWLOCK) callconv(.winapi) u8;
    extern "kernel32" fn AcquireSRWLockShared(l: *SRWLOCK) callconv(.winapi) void;
    extern "kernel32" fn ReleaseSRWLockShared(l: *SRWLOCK) callconv(.winapi) void;
    extern "kernel32" fn TryAcquireSRWLockShared(l: *SRWLOCK) callconv(.winapi) u8;
} else struct {};

const CLOCK_REALTIME: c_int = 0;
const CLOCK_MONOTONIC: c_int = if (builtin.os.tag == .macos) 6 else 1;

// ── Threads / Sync ───────────────────────────────────────────────────────
// POSIX: pthread. Windows: SRWLOCK (slim reader/writer lock; zero-init == valid).

pub const Mutex = if (is_windows) struct {
    inner: winsync.SRWLOCK = .{},

    pub fn lock(self: *Mutex) void {
        winsync.AcquireSRWLockExclusive(&self.inner);
    }
    pub fn unlock(self: *Mutex) void {
        winsync.ReleaseSRWLockExclusive(&self.inner);
    }
    pub fn tryLock(self: *Mutex) bool {
        return winsync.TryAcquireSRWLockExclusive(&self.inner) != 0;
    }
} else struct {
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

pub const RwLock = if (is_windows) struct {
    inner: winsync.SRWLOCK = .{},

    pub fn lock(self: *RwLock) void {
        winsync.AcquireSRWLockExclusive(&self.inner);
    }
    pub fn unlock(self: *RwLock) void {
        winsync.ReleaseSRWLockExclusive(&self.inner);
    }
    pub fn lockShared(self: *RwLock) void {
        winsync.AcquireSRWLockShared(&self.inner);
    }
    pub fn unlockShared(self: *RwLock) void {
        winsync.ReleaseSRWLockShared(&self.inner);
    }
    pub fn tryLock(self: *RwLock) bool {
        return winsync.TryAcquireSRWLockExclusive(&self.inner) != 0;
    }
    pub fn tryLockShared(self: *RwLock) bool {
        return winsync.TryAcquireSRWLockShared(&self.inner) != 0;
    }
} else struct {
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

/// Wall-clock nanoseconds since the Unix epoch.
pub fn nanoTimestamp() i128 {
    if (is_windows) {
        var ft: winsync.FILETIME = undefined;
        winsync.GetSystemTimePreciseAsFileTime(&ft);
        // 100-ns ticks since 1601-01-01; shift to the 1970 epoch.
        const ticks: u64 = (@as(u64, ft.dwHighDateTime) << 32) | ft.dwLowDateTime;
        return (@as(i128, ticks) - 116444736000000000) * 100;
    } else {
        var ts: std.c.timespec = undefined;
        _ = posix_libc.clock_gettime(CLOCK_REALTIME, &ts);
        return @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
    }
}

pub fn milliTimestamp() i64 {
    return @intCast(@divTrunc(nanoTimestamp(), 1_000_000));
}

/// Monotonic tick source for Timer (raw counter units, not nanoseconds).
fn monoTicks() u64 {
    if (is_windows) {
        var ctr: i64 = undefined;
        _ = winsync.QueryPerformanceCounter(&ctr);
        return @intCast(ctr);
    } else {
        var ts: std.c.timespec = undefined;
        _ = posix_libc.clock_gettime(CLOCK_MONOTONIC, &ts);
        return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
    }
}

fn ticksToNs(ticks: u64) u64 {
    if (is_windows) {
        var freq: i64 = undefined;
        _ = winsync.QueryPerformanceFrequency(&freq);
        return @intCast(@as(u128, ticks) * 1_000_000_000 / @as(u128, @intCast(freq)));
    } else {
        return ticks; // already nanoseconds
    }
}

pub const Timer = struct {
    start_ticks: u64,

    pub fn start() !Timer {
        return .{ .start_ticks = monoTicks() };
    }

    pub fn read(self: *Timer) u64 {
        return ticksToNs(monoTicks() - self.start_ticks);
    }

    pub fn lap(self: *Timer) u64 {
        const now = monoTicks();
        const delta = ticksToNs(now - self.start_ticks);
        self.start_ticks = now;
        return delta;
    }
};

// ── Environment ──────────────────────────────────────────────────────────

/// Non-cryptographic random u64 mixing nanotime, PID, and thread ID.
/// Replaces `std.crypto.random.int(u64)` (removed in 0.16) for tmp-file
/// suffix collision avoidance. Thread-safe: each thread gets a unique
/// mix per-call even at the same nanosecond.
pub fn randU64() u64 {
    const now: u128 = @bitCast(nanoTimestamp());
    const ns: u64 = @truncate(now);
    const sec: u64 = @truncate(now / 1_000_000_000);
    const tid: u64 = @intCast(std.Thread.getCurrentId());
    const pid: u64 = if (is_windows)
        @intCast(winsync.GetCurrentProcessId())
    else
        @intCast(std.c.getpid());
    // splitmix64-style final mixing to avoid close-timestamp collisions
    var x = ns ^ (sec *% 2) ^ (tid *% (1 << 17)) ^ (pid *% (1 << 23));
    x ^= x >> 33;
    x *%= 0xff51afd7ed558ccd;
    x ^= x >> 33;
    x *%= 0xc4ceb9fe1a85ec53;
    x ^= x >> 33;
    return x;
}

pub fn userId() usize {
    if (is_windows) return 0;
    return @intCast(std.c.getuid());
}

pub fn sleepMs(ms: u64) void {
    if (is_windows) {
        winsync.Sleep(@intCast(@min(ms, @as(u64, std.math.maxInt(u32)))));
    } else {
        var ts: std.c.timespec = .{
            .sec = @intCast(ms / 1000),
            .nsec = @intCast((ms % 1000) * 1_000_000),
        };
        _ = std.c.nanosleep(&ts, null);
    }
}

pub const PipeError = error{PipeFailed};
pub fn makePipe() PipeError![2]c_int {
    var fds: [2]c_int = .{ -1, -1 };
    if (is_windows) {
        // msvcrt _pipe(fds, size, textmode); O_BINARY (0x8000) keeps bytes raw.
        if (win_libc._pipe(&fds, 64 * 1024, 0x8000) != 0) return error.PipeFailed;
    } else {
        if (posix_libc.pipe(&fds) != 0) return error.PipeFailed;
    }
    return fds;
}

pub fn closeFd(fd: c_int) void {
    _ = close(fd);
}

pub fn readFd(fd: c_int, buf: []u8) isize {
    return read(fd, buf.ptr, buf.len);
}

pub fn posixGetenv(name: []const u8) ?[]const u8 {
    var buf: [256]u8 = undefined;
    if (name.len >= buf.len) return null;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    const ptr = getenv(@ptrCast(&buf)) orelse return null;
    return std.mem.span(ptr);
}

/// The user's home directory. POSIX reads $HOME; Windows has no HOME and
/// exposes the equivalent as %USERPROFILE%. Returns a borrowed env slice or
/// null when neither is set.
pub fn homeDir() ?[]const u8 {
    if (posixGetenv("HOME")) |h| return h;
    if (is_windows) {
        if (posixGetenv("USERPROFILE")) |h| return h;
    }
    return null;
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

/// Set an environment variable (libc setenv), visible to subsequent posixGetenv
/// reads in this process. Names ≥256 / values ≥4096 bytes are ignored. Used by
/// CLI opt-in switches that flip in-process policy — e.g. `--allow-temp` sets
/// CODEDB_ALLOW_TEMP (#538) — and by tests.
pub fn posixSetenv(name: []const u8, value: []const u8) void {
    var nbuf: [256]u8 = undefined;
    var vbuf: [4096]u8 = undefined;
    if (name.len >= nbuf.len or value.len >= vbuf.len) return;
    @memcpy(nbuf[0..name.len], name);
    nbuf[name.len] = 0;
    @memcpy(vbuf[0..value.len], value);
    vbuf[value.len] = 0;
    if (is_windows) {
        _ = win_libc._putenv_s(@ptrCast(&nbuf), @ptrCast(&vbuf));
    } else {
        _ = setenv(@ptrCast(&nbuf), @ptrCast(&vbuf), 1);
    }
}

/// Remove an environment variable (libc unsetenv).
pub fn posixUnsetenv(name: []const u8) void {
    var nbuf: [256]u8 = undefined;
    if (name.len >= nbuf.len) return;
    @memcpy(nbuf[0..name.len], name);
    nbuf[name.len] = 0;
    if (is_windows) {
        // _putenv_s with an empty value removes the variable.
        _ = win_libc._putenv_s(@ptrCast(&nbuf), "");
    } else {
        _ = unsetenv(@ptrCast(&nbuf));
    }
}

/// Read one line from stdin (fd 0) into `buf`, trimming trailing CR/LF. Returns
/// null on EOF/error. For interactive CLI prompts only — NEVER call this in the
/// MCP server path, where stdin is the JSON-RPC transport.
pub fn readLine(buf: []u8) ?[]const u8 {
    const n = read(0, buf.ptr, buf.len);
    if (n <= 0) return null;
    return std.mem.trimEnd(u8, buf[0..@intCast(n)], "\r\n");
}

// ── Arguments ────────────────────────────────────────────────────────────

// Darwin: argv lives in __NSGetArgv() (libc, from <crt_externs.h>).
// Linux/other POSIX: 0.16 doesn't expose argv globally — main() must call
// `setProcessArgs(argv_slice)` once at startup to populate `process_args`.
extern "c" fn _NSGetArgc() *c_int;
extern "c" fn _NSGetArgv() *[*][*:0]u8;

var process_args: ?[]const [*:0]const u8 = null;

/// Called once by `pub fn main` to register the argv slice on non-Darwin
/// platforms. No-op on macOS (it reads from `_NSGetArgv` directly).
pub fn setProcessArgs(args: []const [*:0]const u8) void {
    process_args = args;
}

/// Cross-platform argv bootstrap for `pub fn main`. POSIX/macOS already hand
/// the entry point a `[]const [*:0]const u8` vector; Windows hands a WTF-16
/// command line that must be parsed and materialized into the same shape.
/// Returns a slice usable by the fast path and `setProcessArgs`. On Windows the
/// backing allocation lives for the process lifetime (argv is never freed),
/// mirroring how the POSIX vector is owned by the runtime.
pub fn bootstrapArgs(args: std.process.Args) []const [*:0]const u8 {
    if (builtin.os.tag != .windows) return args.vector;

    const alloc = std.heap.page_allocator;
    const slice = args.toSlice(alloc) catch return &[_][*:0]const u8{};
    const out = alloc.alloc([*:0]const u8, slice.len) catch return &[_][*:0]const u8{};
    for (out, slice) |*dst, src| dst.* = src.ptr;
    return out;
}

/// Shim for cio.argsAlloc (removed in 0.16). Returns a duplicated
/// slice of argv strings owned by the allocator; free with argsFree.
pub fn argsAlloc(alloc: std.mem.Allocator) ![][:0]u8 {
    const argc: usize = if (builtin.os.tag == .macos)
        @intCast(_NSGetArgc().*)
    else
        (process_args orelse return error.ProcessArgsNotSet).len;
    const out = try alloc.alloc([:0]u8, argc);
    errdefer alloc.free(out);
    var filled: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < filled) : (i += 1) alloc.free(out[i]);
    }
    while (filled < argc) : (filled += 1) {
        const cstr: [*:0]const u8 = if (builtin.os.tag == .macos)
            _NSGetArgv().*[filled]
        else
            process_args.?[filled];
        const s = std.mem.span(cstr);
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

// posix_spawn family — declared directly via extern "c" so this builds on
// both Darwin and Linux. (std.c.posix_spawnp is gated to .isDarwin() in 0.16
// and would fail to compile on Linux even though glibc/musl provide it.)
const PosixSpawnFileActions = opaque {};
const PosixSpawnAttr = opaque {};
const pid_t = c_int;

extern "c" fn posix_spawnp(
    pid: *pid_t,
    path: [*:0]const u8,
    file_actions: ?*const PosixSpawnFileActions,
    attrp: ?*const PosixSpawnAttr,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
) c_int;
extern "c" fn posix_spawn_file_actions_init(fa: *PosixSpawnFileActions) c_int;
extern "c" fn posix_spawn_file_actions_destroy(fa: *PosixSpawnFileActions) c_int;
extern "c" fn posix_spawn_file_actions_adddup2(fa: *PosixSpawnFileActions, fd: c_int, newfd: c_int) c_int;
extern "c" fn posix_spawn_file_actions_addclose(fa: *PosixSpawnFileActions, fd: c_int) c_int;
extern "c" fn posix_spawn_file_actions_addchdir_np(fa: *PosixSpawnFileActions, path: [*:0]const u8) c_int;
extern "c" fn posix_spawn_file_actions_addopen(fa: *PosixSpawnFileActions, fd: c_int, path: [*:0]const u8, oflag: c_int, mode: c_uint) c_int;
extern "c" fn waitpid(pid: pid_t, status: *c_int, options: c_int) pid_t;

// posix_spawn_file_actions_t is a struct of unknown size on each libc. We
// allocate a generously-sized buffer and cast to the opaque pointer type.
const PosixSpawnFAStorage = [256]u8;

/// Shim for std.process.Child.run — fast posix_spawnp path.
/// Captures stdout and stderr into separate streams (drained concurrently by
/// a background thread to avoid pipe-buffer deadlock when the child writes
/// substantially to either stream).
/// Run `argv` and capture stdout/stderr. POSIX uses a posix_spawnp fast path;
/// Windows falls back to std.process.run with matching output bounds.
pub fn runCapture(opts: RunOptions) !CaptureResult {
    if (is_windows) return runCaptureWindows(opts);
    return runCapturePosix(opts);
}

fn runCaptureWindows(opts: RunOptions) !CaptureResult {
    const alloc = opts.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const result = try std.process.run(alloc, io, .{
        .argv = opts.argv,
        .cwd = if (opts.cwd) |cwd| .{ .path = cwd } else .inherit,
        .stdout_limit = .limited(opts.max_output_bytes),
        .stderr_limit = .limited(opts.max_output_bytes),
    });
    const term: CaptureResult.Term = switch (result.term) {
        .exited => |code| .{ .Exited = code },
        .signal => |sig| .{ .Signal = @intFromEnum(sig) },
        .stopped => |sig| .{ .Stopped = @intFromEnum(sig) },
        .unknown => |code| .{ .Unknown = code },
    };
    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .term = term,
    };
}

fn runCapturePosix(opts: RunOptions) !CaptureResult {
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
    var err_pipe: [2]c_int = .{ -1, -1 };
    if (posix_libc.pipe(&out_pipe) != 0) return error.PipeFailed;
    errdefer {
        if (out_pipe[0] >= 0) _ = close(out_pipe[0]);
        if (out_pipe[1] >= 0) _ = close(out_pipe[1]);
    }
    if (posix_libc.pipe(&err_pipe) != 0) return error.PipeFailed;
    errdefer {
        if (err_pipe[0] >= 0) _ = close(err_pipe[0]);
        if (err_pipe[1] >= 0) _ = close(err_pipe[1]);
    }

    var fa_storage: PosixSpawnFAStorage = undefined;
    const fa: *PosixSpawnFileActions = @ptrCast(&fa_storage);
    if (posix_spawn_file_actions_init(fa) != 0) return error.SpawnInitFailed;
    defer _ = posix_spawn_file_actions_destroy(fa);

    if (opts.cwd) |cwd| {
        var cwd_buf: [4096]u8 = undefined;
        if (cwd.len >= cwd_buf.len) return error.PathTooLong;
        @memcpy(cwd_buf[0..cwd.len], cwd);
        cwd_buf[cwd.len] = 0;
        // posix_spawn_file_actions_addchdir_np is glibc 2.29+ / macOS 10.15+.
        // Returns ENOSYS on older systems — caller treats that as fatal here.
        if (posix_spawn_file_actions_addchdir_np(fa, @ptrCast(&cwd_buf)) != 0) {
            return error.CwdNotSupported;
        }
    }

    _ = posix_spawn_file_actions_adddup2(fa, out_pipe[1], 1);
    _ = posix_spawn_file_actions_adddup2(fa, err_pipe[1], 2);
    _ = posix_spawn_file_actions_addclose(fa, out_pipe[0]);
    _ = posix_spawn_file_actions_addclose(fa, out_pipe[1]);
    _ = posix_spawn_file_actions_addclose(fa, err_pipe[0]);
    _ = posix_spawn_file_actions_addclose(fa, err_pipe[1]);

    const envp: [*:null]const ?[*:0]const u8 = if (builtin.os.tag == .macos)
        @ptrCast(_NSGetEnviron().*)
    else
        @ptrCast(std.c.environ);

    var pid: pid_t = 0;
    if (posix_spawnp(&pid, c_argv[0].?, fa, null, c_argv_z, envp) != 0)
        return error.SpawnFailed;

    _ = close(out_pipe[1]);
    out_pipe[1] = -1;
    _ = close(err_pipe[1]);
    err_pipe[1] = -1;

    // Drain stderr on a background thread so neither pipe can fill up and
    // deadlock the child. Main thread drains stdout.
    const DrainCtx = struct {
        fd: c_int,
        cap: usize,
        alloc: std.mem.Allocator,
        out: std.ArrayList(u8) = .empty,
        err: ?anyerror = null,

        fn run(self: *@This()) void {
            var chunk: [64 * 1024]u8 = undefined;
            while (self.out.items.len < self.cap) {
                const want = @min(chunk.len, self.cap - self.out.items.len);
                const n = read(self.fd, &chunk, want);
                if (n <= 0) break;
                self.out.appendSlice(self.alloc, chunk[0..@intCast(n)]) catch |e| {
                    self.err = e;
                    return;
                };
            }
        }
    };
    var err_ctx: DrainCtx = .{ .fd = err_pipe[0], .cap = opts.max_output_bytes, .alloc = alloc };
    errdefer err_ctx.out.deinit(alloc);
    const err_thread = try std.Thread.spawn(.{}, DrainCtx.run, .{&err_ctx});

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

    err_thread.join();
    _ = close(err_pipe[0]);
    err_pipe[0] = -1;
    if (err_ctx.err) |e| {
        err_ctx.out.deinit(alloc);
        return e;
    }

    var status: c_int = 0;
    _ = waitpid(pid, &status, 0);

    const term: CaptureResult.Term = if ((status & 0x7f) == 0)
        .{ .Exited = @intCast((status >> 8) & 0xff) }
    else if ((status & 0x7f) != 0x7f)
        .{ .Signal = @intCast(status & 0x7f) }
    else
        .{ .Stopped = @intCast((status >> 8) & 0xff) };

    return .{
        .stdout = try out.toOwnedSlice(alloc),
        .stderr = try err_ctx.out.toOwnedSlice(alloc),
        .term = term,
    };
}

/// Fire-and-forget spawn of a detached child (used to launch the warm
/// cli-daemon). POSIX uses posix_spawnp + /dev/null redirection; Windows uses
/// CreateProcessW with detached/no-window flags.
pub fn spawnDetached(allocator: std.mem.Allocator, argv: []const []const u8) void {
    if (is_windows) {
        spawnDetachedWindows(allocator, argv);
        return;
    } else {
        spawnDetachedPosix(allocator, argv);
    }
}

pub fn windowsCommandLine(allocator: std.mem.Allocator, argv: []const []const u8) ?[]u8 {
    var cmd: std.ArrayList(u8) = .empty;
    defer cmd.deinit(allocator);
    for (argv, 0..) |arg, i| {
        if (i != 0) cmd.append(allocator, ' ') catch return null;
        cmd.append(allocator, '"') catch return null;
        var backslashes: usize = 0;
        for (arg) |ch| {
            switch (ch) {
                '\\' => backslashes += 1,
                '"' => {
                    cmd.appendNTimes(allocator, '\\', backslashes * 2 + 1) catch return null;
                    cmd.append(allocator, '"') catch return null;
                    backslashes = 0;
                },
                else => {
                    if (backslashes > 0) {
                        cmd.appendNTimes(allocator, '\\', backslashes) catch return null;
                        backslashes = 0;
                    }
                    cmd.append(allocator, ch) catch return null;
                },
            }
        }
        cmd.appendNTimes(allocator, '\\', backslashes * 2) catch return null;
        cmd.append(allocator, '"') catch return null;
    }
    return cmd.toOwnedSlice(allocator) catch null;
}

fn spawnDetachedWindows(allocator: std.mem.Allocator, argv: []const []const u8) void {
    if (argv.len == 0) return;

    const cmd = windowsCommandLine(allocator, argv) orelse return;
    defer allocator.free(cmd);
    const cmd_w = std.unicode.utf8ToUtf16LeAllocZ(allocator, cmd) catch return;
    defer allocator.free(cmd_w);

    var si: std.os.windows.STARTUPINFOW = std.mem.zeroes(std.os.windows.STARTUPINFOW);
    si.cb = @sizeOf(std.os.windows.STARTUPINFOW);
    var pi: std.os.windows.PROCESS.INFORMATION = undefined;
    const flags: std.os.windows.CreateProcessFlags = .{ .detached_process = true, .create_no_window = true };
    if (std.os.windows.kernel32.CreateProcessW(null, cmd_w.ptr, null, null, .FALSE, flags, null, null, &si, &pi) == .FALSE) return;
    std.os.windows.CloseHandle(pi.hThread);
    std.os.windows.CloseHandle(pi.hProcess);
}

/// Fire-and-forget spawn: posix_spawnp `argv` with stdin/stdout/stderr
/// redirected to /dev/null, and do NOT wait on the child. Used to launch the
/// warm cli-daemon from a cold CLI invocation. The child is expected to
/// setsid() itself; once this CLI process exits the child is reparented to
/// init, so we never reap it (no zombie outlives this short-lived CLI). All
/// failures are swallowed — auto-spawn is best-effort and the cold path still
/// produces correct output regardless.
fn spawnDetachedPosix(allocator: std.mem.Allocator, argv: []const []const u8) void {
    if (argv.len == 0) return;

    const c_argv = allocator.alloc(?[*:0]const u8, argv.len + 1) catch return;
    defer allocator.free(c_argv);
    const arg_bufs = allocator.alloc([]u8, argv.len) catch return;
    var built: usize = 0;
    defer {
        for (arg_bufs[0..built]) |b| allocator.free(b);
        allocator.free(arg_bufs);
    }
    for (argv, 0..) |a, i| {
        const buf = allocator.alloc(u8, a.len + 1) catch return;
        @memcpy(buf[0..a.len], a);
        buf[a.len] = 0;
        arg_bufs[i] = buf;
        built = i + 1;
        c_argv[i] = @ptrCast(buf.ptr);
    }
    c_argv[argv.len] = null;
    const c_argv_z: [*:null]const ?[*:0]const u8 = @ptrCast(c_argv.ptr);

    var fa_storage: PosixSpawnFAStorage = undefined;
    const fa: *PosixSpawnFileActions = @ptrCast(&fa_storage);
    if (posix_spawn_file_actions_init(fa) != 0) return;
    defer _ = posix_spawn_file_actions_destroy(fa);

    // Redirect 0/1/2 to /dev/null so the daemon holds no inherited terminal fds.
    // O_RDWR == 2 on both Darwin and Linux. Errors are non-fatal — the daemon
    // re-redirects to /dev/null itself after setsid() at startup.
    const devnull: [*:0]const u8 = "/dev/null";
    _ = posix_spawn_file_actions_addopen(fa, 0, devnull, 2, 0);
    _ = posix_spawn_file_actions_addopen(fa, 1, devnull, 2, 0);
    _ = posix_spawn_file_actions_addopen(fa, 2, devnull, 2, 0);

    const envp: [*:null]const ?[*:0]const u8 = if (builtin.os.tag == .macos)
        @ptrCast(_NSGetEnviron().*)
    else
        @ptrCast(std.c.environ);

    var pid: pid_t = 0;
    // Fire and forget: no waitpid. The child reparents to init once this CLI
    // exits, so it never becomes a lingering zombie of ours.
    _ = posix_spawnp(&pid, c_argv[0].?, fa, null, c_argv_z, envp);
}

// ── Memory mapping ─────────────────────────────────────────────────────────
// Zero-copy read-only file views. POSIX uses mmap(MAP_SHARED, PROT_READ);
// Windows uses a file-mapping object + MapViewOfFile. Both return a page-aligned
// const slice that must be released with munmap(). `handle` is the platform file
// handle — pass `file.handle` from an opened std.Io.File (fd_t on POSIX,
// windows.HANDLE on Windows; `anytype` keeps the per-target type exact).

pub const MmapError = error{MapFailed};

const winmap = if (is_windows) struct {
    const HANDLE = std.os.windows.HANDLE;
    const DWORD = std.os.windows.DWORD;
    const BOOL = std.os.windows.BOOL;
    const PAGE_READONLY: DWORD = 0x02;
    const FILE_MAP_READ: DWORD = 0x0004;
    extern "kernel32" fn CreateFileMappingW(hFile: HANDLE, lpAttributes: ?*anyopaque, flProtect: DWORD, dwMaximumSizeHigh: DWORD, dwMaximumSizeLow: DWORD, lpName: ?[*:0]const u16) callconv(.winapi) ?HANDLE;
    extern "kernel32" fn MapViewOfFile(hFileMappingObject: HANDLE, dwDesiredAccess: DWORD, dwFileOffsetHigh: DWORD, dwFileOffsetLow: DWORD, dwNumberOfBytesToMap: usize) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn UnmapViewOfFile(lpBaseAddress: *const anyopaque) callconv(.winapi) BOOL;
    extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;
} else struct {};

/// mmap `len` bytes of `handle` read-only. Returns a page-aligned const view.
pub fn mmapReadonly(handle: anytype, len: usize) MmapError![]align(std.heap.page_size_min) const u8 {
    if (is_windows) {
        // A 0 max-size maps the whole file; the view stays valid after the
        // mapping handle is closed, so we close it eagerly.
        const mapping = winmap.CreateFileMappingW(handle, null, winmap.PAGE_READONLY, 0, 0, null) orelse
            return error.MapFailed;
        defer _ = winmap.CloseHandle(mapping);
        const base = winmap.MapViewOfFile(mapping, winmap.FILE_MAP_READ, 0, 0, len) orelse
            return error.MapFailed;
        const ptr: [*]align(std.heap.page_size_min) const u8 = @ptrCast(@alignCast(base));
        return ptr[0..len];
    } else {
        return std.posix.mmap(null, len, .{ .READ = true }, .{ .TYPE = .SHARED }, handle, 0) catch
            return error.MapFailed;
    }
}

/// Release a view previously returned by mmapReadonly.
pub fn munmap(data: []align(std.heap.page_size_min) const u8) void {
    if (is_windows) {
        _ = winmap.UnmapViewOfFile(data.ptr);
    } else {
        std.posix.munmap(data);
    }
}
