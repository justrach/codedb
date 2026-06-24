//! Thin CLI client → warm daemon proxy + the per-project spawn lock.
const std = @import("std");
const builtin = @import("builtin");
const cio = @import("cio.zig");
const sty = @import("style.zig");
const Store = @import("store.zig").Store;
const Explorer = @import("explore.zig").Explorer;
const Out = @import("out.zig").Out;
const runQuery = @import("query.zig").runQuery;
const cli_args = @import("cli_args.zig");
const parsePositional = cli_args.parsePositional;
const cliIsQueryCmd = cli_args.cliIsQueryCmd;

// ── Thin CLI client → warm daemon ──────────────────────────────────────────
// When a `codedb <root> serve` or `codedb <root> mcp` daemon is already running
// for a project, a fresh `codedb <root> <query>` invocation can skip the
// per-process snapshot reload by proxying the command to that daemon over a
// per-project Unix-domain socket. The daemon runs the exact same `runQuery`
// rendering against its already-warm Explorer/Store and streams the rendered
// bytes back. If no daemon is listening, the client transparently falls back to
// the cold in-process path.
//
// Transport: blocking std.c (libc) Unix sockets. std.posix dropped the socket
// syscalls in 0.16 and the std.Io.net UnixAddress Reader/Writer surface is
// awkward for a tiny framed request/response, so we go straight to libc here.
// runQuery itself still receives the daemon's real `io` (it reads files through
// it); only the socket bytes move over libc.
//
// Wire protocol (little-endian, length-framed):
//   request  (client→daemon): [u8 color][u32 blob_len][blob]
//       blob = argv[1..] NUL-joined, e.g. "/proj\0find\0foo"
//   response (daemon→client): [u8 exit_code][u32 out_len][out_bytes]
const cli_blob_max: u32 = 64 * 1024;
const cli_response_max: u32 = 16 * 1024 * 1024;
const cli_response_too_large = "error: daemon response too large\n";

fn cliResponseLenAllowed(out_len: u32) bool {
    return out_len <= cli_response_max;
}

test "cli response length cap rejects oversized frames" {
    try std.testing.expect(cliResponseLenAllowed(0));
    try std.testing.expect(cliResponseLenAllowed(cli_response_max));
    try std.testing.expect(!cliResponseLenAllowed(cli_response_max + 1));
}

const win = std.os.windows;
const INVALID_HANDLE_VALUE = win.INVALID_HANDLE_VALUE;
const GENERIC_READ: u32 = 0x80000000;
const GENERIC_WRITE: u32 = 0x40000000;
const OPEN_EXISTING: u32 = 3;
const OPEN_ALWAYS: u32 = 4;
const PIPE_ACCESS_DUPLEX: u32 = 0x00000003;
const PIPE_TYPE_BYTE: u32 = 0x00000000;
const PIPE_READMODE_BYTE: u32 = 0x00000000;
const PIPE_WAIT: u32 = 0x00000000;
const PIPE_UNLIMITED_INSTANCES: u32 = 255;
const FILE_FLAG_FIRST_PIPE_INSTANCE: u32 = 0x00080000;
const SECURITY_SQOS_PRESENT: u32 = 0x00100000;
const SECURITY_IDENTIFICATION: u32 = 0x00010000;
const SDDL_REVISION_1: u32 = 1;

extern "kernel32" fn CreateNamedPipeA(
    lpName: [*:0]const u8,
    dwOpenMode: u32,
    dwPipeMode: u32,
    nMaxInstances: u32,
    nOutBufferSize: u32,
    nInBufferSize: u32,
    nDefaultTimeOut: u32,
    lpSecurityAttributes: ?*anyopaque,
) callconv(.winapi) win.HANDLE;
extern "kernel32" fn ConnectNamedPipe(hNamedPipe: win.HANDLE, lpOverlapped: ?*anyopaque) callconv(.winapi) win.BOOL;
extern "kernel32" fn DisconnectNamedPipe(hNamedPipe: win.HANDLE) callconv(.winapi) win.BOOL;
extern "kernel32" fn CreateFileA(
    lpFileName: [*:0]const u8,
    dwDesiredAccess: u32,
    dwShareMode: u32,
    lpSecurityAttributes: ?*anyopaque,
    dwCreationDisposition: u32,
    dwFlagsAndAttributes: u32,
    hTemplateFile: ?win.HANDLE,
) callconv(.winapi) win.HANDLE;
extern "kernel32" fn ReadFile(hFile: win.HANDLE, lpBuffer: [*]u8, nNumberOfBytesToRead: u32, lpNumberOfBytesRead: *u32, lpOverlapped: ?*anyopaque) callconv(.winapi) win.BOOL;
extern "kernel32" fn WriteFile(hFile: win.HANDLE, lpBuffer: [*]const u8, nNumberOfBytesToWrite: u32, lpNumberOfBytesWritten: *u32, lpOverlapped: ?*anyopaque) callconv(.winapi) win.BOOL;
extern "kernel32" fn LocalFree(hMem: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "advapi32" fn ConvertStringSecurityDescriptorToSecurityDescriptorA(
    sddl: [*:0]const u8,
    revision: u32,
    sd: *?*anyopaque,
    sd_size: ?*u32,
) callconv(.winapi) win.BOOL;

/// How often a long-lived serve/mcp daemon that lost the CLI socket bind
/// re-attempts it (see cliAcquireListener) — one second, matching the daemons'
/// watchdog cadence and bounded by the previous owner's idle timeout.
const cli_bind_retry_ms: u64 = 1000;

/// Build the per-project socket path into `buf`. Stays well under sun_path
/// (104 bytes on macOS / 108 on Linux): "/tmp/codedb-<uid>-<hash16>.sock" is
/// at most ~40 bytes. Returns null only if formatting somehow overflows `buf`.
pub fn cliSocketPath(buf: []u8, abs_root: []const u8) ?[]const u8 {
    const uid = cio.userId();
    const hash = std.hash.Wyhash.hash(0xc0de, abs_root);
    return std.fmt.bufPrint(buf, "/tmp/codedb-{d}-{x:0>16}.sock", .{ uid, hash }) catch null;
}

fn cliPipeName(buf: []u8, abs_root: []const u8) ?[:0]const u8 {
    const hash = std.hash.Wyhash.hash(0xc0de, abs_root);
    const user_hash = std.hash.Wyhash.hash(0xc0de, cio.posixGetenv("USERNAME") orelse "");
    return std.fmt.bufPrintZ(buf, "\\\\.\\pipe\\codedb-{x:0>16}-{x:0>16}", .{ hash, user_hash }) catch null;
}

/// Fill a sockaddr.un for `path` (which must be NUL-terminatable into sun_path).
/// Returns the struct plus the byte length to pass to bind/connect. Path is
/// guaranteed short by cliSocketPath, but we guard the copy regardless.
fn cliFillSockaddr(path: []const u8) ?SockAddr {
    var addr: std.c.sockaddr.un = .{ .family = std.c.AF.UNIX, .path = undefined };
    if (path.len + 1 > addr.path.len) return null;
    @memcpy(addr.path[0..path.len], path);
    addr.path[path.len] = 0;
    // sun_len/sun_family + the NUL-terminated path. sizeof works on every
    // platform we ship; the extra trailing bytes are harmless for AF_UNIX.
    const len: std.c.socklen_t = @intCast(@sizeOf(std.c.sockaddr.un));
    return .{ .addr = addr, .len = len };
}

/// Read exactly `buf.len` bytes from a blocking fd, looping over short reads.
/// Returns false on EOF-before-full or a hard error (EINTR is retried).
const CliConn = if (builtin.os.tag == .windows) win.HANDLE else c_int;

fn connRead(conn: CliConn, buf: []u8) ?usize {
    if (builtin.os.tag == .windows) {
        var got: u32 = 0;
        const want: u32 = @intCast(@min(buf.len, std.math.maxInt(u32)));
        if (ReadFile(conn, buf.ptr, want, &got, null) == .FALSE) return null;
        return got;
    }
    while (true) {
        const n = std.c.read(conn, buf.ptr, buf.len);
        if (n >= 0) return @intCast(n);
        if (std.c.errno(n) != .INTR) return null;
    }
}

fn connWrite(conn: CliConn, data: []const u8) ?usize {
    if (builtin.os.tag == .windows) {
        var wrote: u32 = 0;
        const want: u32 = @intCast(@min(data.len, std.math.maxInt(u32)));
        if (WriteFile(conn, data.ptr, want, &wrote, null) == .FALSE) return null;
        return wrote;
    }
    while (true) {
        const n = std.c.write(conn, data.ptr, data.len);
        if (n >= 0) return @intCast(n);
        if (std.c.errno(n) != .INTR) return null;
    }
}

fn cliReadFull(conn: CliConn, buf: []u8) bool {
    var off: usize = 0;
    while (off < buf.len) {
        const n = connRead(conn, buf[off..]) orelse return false;
        if (n == 0) return false;
        off += n;
    }
    return true;
}

/// Write all of `data` to a blocking fd, looping over short/partial writes.
/// Returns false on a hard error (EINTR is retried).
fn cliWriteFull(conn: CliConn, data: []const u8) bool {
    var off: usize = 0;
    while (off < data.len) {
        const n = connWrite(conn, data[off..]) orelse return false;
        if (n == 0) return false;
        off += n;
    }
    return true;
}

/// #592: per-project cli-daemon spawn lock. Open-or-create
/// `<data_dir>/cli-daemon.lock` and take an exclusive non-blocking flock.
/// Returns the fd on success — callers keep it open for the process lifetime
/// (the kernel releases flocks on exit, so crashes never leave a stale lock).
/// Returns null when another process holds the lock or the file can't be
/// opened.
const DaemonLock = if (builtin.os.tag == .windows) win.HANDLE else c_int;

pub fn daemonLockTryAcquire(data_dir: []const u8) ?DaemonLock {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const p = std.fmt.bufPrintZ(&buf, "{s}/cli-daemon.lock", .{data_dir}) catch return null;
    if (builtin.os.tag == .windows) {
        const handle = CreateFileA(p.ptr, GENERIC_READ | GENERIC_WRITE, 0, null, OPEN_ALWAYS, 0, null);
        if (handle == INVALID_HANDLE_VALUE) return null;
        return handle;
    }
    const fd = std.c.open(p.ptr, .{ .ACCMODE = .RDWR, .CREAT = true }, @as(c_uint, 0o600));
    if (fd < 0) return null;
    if (std.c.flock(fd, std.c.LOCK.EX | std.c.LOCK.NB) != 0) {
        _ = std.c.close(fd);
        return null;
    }
    return fd;
}

pub fn daemonLockRelease(lock: DaemonLock) void {
    if (builtin.os.tag == .windows) {
        win.CloseHandle(lock);
        return;
    }
    _ = std.c.flock(lock, std.c.LOCK.UN);
    _ = std.c.close(lock);
}

/// Probe whether the spawn lock is free without keeping it: used by the CLI
/// auto-spawn path so racing cold calls don't fork duplicate daemons.
pub fn daemonLockAvailable(data_dir: []const u8) bool {
    const lock = daemonLockTryAcquire(data_dir) orelse return false;
    daemonLockRelease(lock);
    return true;
}

/// Named sockaddr.un bundle: the struct plus the byte length for bind()/connect().
const SockAddr = struct { addr: std.c.sockaddr.un, len: std.c.socklen_t };

/// One attempt to OWN the project socket: socket() + bind() + chmod 0600 +
/// listen(). Returns the listening fd, or null if the path is already taken or
/// a syscall failed (the fd is closed on any failure). Never unlinks — the
/// caller decides whether a taken path is stale.
fn cliBindListen(sa: SockAddr, sock_path_z: [:0]const u8) ?c_int {
    const fd = std.c.socket(std.c.AF.UNIX, std.c.SOCK.STREAM, 0);
    if (fd < 0) return null;
    var sa_mut = sa;
    if (std.c.bind(fd, @ptrCast(&sa_mut.addr), sa_mut.len) != 0) {
        _ = std.c.close(fd);
        return null;
    }
    // Owner-only perms (0600). Must chmod the path, not fchmod the fd: Darwin
    // ignores fchmod() on a socket fd. Safe before listen() — no client can
    // connect yet. Non-fatal.
    _ = std.c.chmod(sock_path_z.ptr, 0o600);
    if (std.c.listen(fd, 16) != 0) {
        _ = std.c.close(fd);
        return null;
    }
    return fd;
}

/// True if a daemon is actively listening on the socket (a connect succeeds).
/// Lets a retrying daemon tell a live owner apart from a stale node left by a
/// dead daemon, so it never unlinks (steals) a socket that is still in use.
fn cliSocketLive(sa: SockAddr) bool {
    const fd = std.c.socket(std.c.AF.UNIX, std.c.SOCK.STREAM, 0);
    if (fd < 0) return false;
    defer _ = std.c.close(fd);
    var sa_mut = sa;
    return std.c.connect(fd, @ptrCast(&sa_mut.addr), sa_mut.len) == 0;
}

/// Acquire the per-project CLI socket and return a listening fd.
///
/// A stale node left by a dead daemon (bind fails but nothing is listening) is
/// unlinked and rebound at once. When the path is held by a LIVE owner the
/// behavior depends on `retry`:
///   - retry == false (auto-spawned cli-daemon that lost the race): return null
///     immediately so the duplicate exits instead of stealing a live socket.
///   - retry == true (long-lived serve/mcp daemon): keep re-attempting every
///     `retry_interval_ms` until the owner exits and the bind succeeds, so CLI
///     calls stop falling back to a cold re-index once the older owner is gone
///     (#619 — previously the loser disabled its proxy and never retried).
/// Returns null if `shutdown` is set while waiting.
pub fn cliAcquireListener(sock_path: []const u8, retry: bool, retry_interval_ms: u64, shutdown: *std.atomic.Value(bool)) ?c_int {
    var z_buf: [128]u8 = undefined;
    const sock_path_z = std.fmt.bufPrintZ(&z_buf, "{s}", .{sock_path}) catch return null;
    const sa = cliFillSockaddr(sock_path) orelse return null;
    while (true) {
        if (cliBindListen(sa, sock_path_z)) |fd| return fd;
        // Bind failed: the path exists. Clear it only when no one is listening
        // (stale node), never when a live owner still holds it.
        if (!cliSocketLive(sa)) {
            _ = std.c.unlink(sock_path_z.ptr);
            if (cliBindListen(sa, sock_path_z)) |fd| return fd;
        }
        if (!retry) return null;
        if (shutdown.load(.acquire)) return null;
        cio.sleepMs(retry_interval_ms);
    }
}

/// Daemon side. Bind a per-project Unix socket and serve framed query requests
/// against the warm `explorer`/`store`. Runs on its own detached thread so it
/// never blocks the daemon's primary loop. Connections are handled sequentially
/// (CLI calls are infrequent and runQuery already tolerates concurrent reads
/// from the watcher).
///
/// `last_activity_ms` is bumped to the current ms timestamp at the start of
/// every accepted connection so a time-based idle watchdog (cli-daemon) can
/// tell when the socket has gone quiet.
///
/// `retry` selects the lost-bind-race policy (see cliAcquireListener): an
/// auto-spawned cli-daemon passes `false` and gets `shutdown` set so it exits
/// promptly; the long-lived serve/mcp daemons pass `true` and keep reclaiming
/// the socket when the previous owner exits instead of disabling the proxy.
pub fn cliDaemonListen(io: std.Io, allocator: std.mem.Allocator, explorer: *Explorer, store: *Store, abs_root: []const u8, last_activity_ms: *std.atomic.Value(i64), shutdown: *std.atomic.Value(bool), retry: bool) void {
    if (builtin.os.tag == .windows) {
        var name_buf: [256]u8 = undefined;
        const pipe_name = cliPipeName(&name_buf, abs_root) orelse {
            shutdown.store(true, .release);
            return;
        };

        var sd: ?*anyopaque = null;
        if (ConvertStringSecurityDescriptorToSecurityDescriptorA("D:P(A;;GA;;;OW)", SDDL_REVISION_1, &sd, null) == .FALSE) {
            shutdown.store(true, .release);
            return;
        }
        defer _ = LocalFree(sd);
        var sa_pipe: win.SECURITY_ATTRIBUTES = .{
            .nLength = @sizeOf(win.SECURITY_ATTRIBUTES),
            .lpSecurityDescriptor = sd,
            .bInheritHandle = .FALSE,
        };

        while (!shutdown.load(.acquire)) {
            const pipe = CreateNamedPipeA(
                pipe_name.ptr,
                PIPE_ACCESS_DUPLEX | FILE_FLAG_FIRST_PIPE_INSTANCE,
                PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT,
                PIPE_UNLIMITED_INSTANCES,
                cli_blob_max + 5,
                cli_blob_max + 5,
                0,
                &sa_pipe,
            );
            if (pipe == INVALID_HANDLE_VALUE) {
                shutdown.store(true, .release);
                return;
            }
            const connected = ConnectNamedPipe(pipe, null) != .FALSE or win.GetLastError() == .PIPE_CONNECTED;
            if (!connected) {
                win.CloseHandle(pipe);
                continue;
            }
            last_activity_ms.store(cio.milliTimestamp(), .release);
            cliServeConn(io, allocator, explorer, store, abs_root, pipe);
            _ = DisconnectNamedPipe(pipe);
            win.CloseHandle(pipe);
        }
        return;
    }

    cliDaemonListenPosix(io, allocator, explorer, store, abs_root, last_activity_ms, shutdown, retry);
}

fn cliDaemonListenPosix(io: std.Io, allocator: std.mem.Allocator, explorer: *Explorer, store: *Store, abs_root: []const u8, last_activity_ms: *std.atomic.Value(i64), shutdown: *std.atomic.Value(bool), retry: bool) void {
    var path_buf: [128]u8 = undefined;
    const sock_path = cliSocketPath(&path_buf, abs_root) orelse {
        std.log.warn("cli-proxy: could not build socket path", .{});
        shutdown.store(true, .release);
        return;
    };
    var path_z_buf: [128]u8 = undefined;
    const sock_path_z = std.fmt.bufPrintZ(&path_z_buf, "{s}", .{sock_path}) catch {
        shutdown.store(true, .release);
        return;
    };

    // Acquire the socket. A long-lived daemon (retry) waits out the current
    // owner and reclaims it when the owner exits; an auto-spawned duplicate
    // (no retry) gives up at once and exits via the shutdown flag.
    const listenfd = cliAcquireListener(sock_path, retry, cli_bind_retry_ms, shutdown) orelse {
        if (!shutdown.load(.acquire)) {
            std.log.warn("cli-proxy: bind {s} failed — proxy disabled", .{sock_path});
        }
        shutdown.store(true, .release);
        return;
    };
    defer {
        _ = std.c.close(listenfd);
        _ = std.c.unlink(sock_path_z.ptr);
    }

    std.log.info("cli-proxy: listening on {s}", .{sock_path});

    while (true) {
        const conn = std.c.accept(listenfd, null, null);
        if (conn < 0) {
            if (std.c.errno(conn) == .INTR) continue;
            // Listener went bad; stop the loop (daemon still serves its main API).
            return;
        }
        // Record activity for the cli-daemon idle watchdog before serving.
        last_activity_ms.store(cio.milliTimestamp(), .release);
        cliServeConn(io, allocator, explorer, store, abs_root, conn);
        _ = std.c.close(conn);
    }
}

/// Handle one client connection: read the framed request, run the query into a
/// sink buffer via runQuery, and write the framed response.
fn cliServeConn(io: std.Io, allocator: std.mem.Allocator, explorer: *Explorer, store: *Store, abs_root: []const u8, conn: CliConn) void {
    // Header: [u8 color][u32 blob_len]
    var hdr: [5]u8 = undefined;
    if (!cliReadFull(conn, &hdr)) return;
    const color = hdr[0] != 0;
    const blob_len = std.mem.readInt(u32, hdr[1..5], .little);
    if (blob_len == 0 or blob_len > cli_blob_max) {
        cliRespond(conn, 1, "");
        return;
    }

    const blob = allocator.alloc(u8, blob_len) catch {
        cliRespond(conn, 1, "");
        return;
    };
    defer allocator.free(blob);
    if (!cliReadFull(conn, blob)) return;

    // Rebuild argv = ["codedb"] ++ split(blob, '\0'), skipping empty fields.
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    argv.append(allocator, "codedb") catch {
        cliRespond(conn, 1, "");
        return;
    };
    var it = std.mem.splitScalar(u8, blob, 0);
    while (it.next()) |field| {
        if (field.len == 0) continue;
        argv.append(allocator, field) catch {
            cliRespond(conn, 1, "");
            return;
        };
    }

    const parsed = parsePositional(argv.items);
    if (parsed.usage_exit or !cliIsQueryCmd(parsed.cmd)) {
        cliRespond(conn, 1, "");
        return;
    }

    var sink: std.ArrayList(u8) = .empty;
    defer sink.deinit(allocator);
    var out = Out{ .file = cio.File.stdout(), .alloc = allocator, .sink = &sink };
    const s = sty.style(color);
    const code = runQuery(io, allocator, explorer, store, abs_root, parsed.cmd, argv.items, parsed.cmd_args_start, &out, s);
    out.flush();

    cliRespond(conn, code, sink.items);
}

/// Write the framed response [u8 code][u32 out_len][out_bytes] to `conn`.
fn cliRespond(conn: CliConn, code: u8, out_bytes: []const u8) void {
    const response_too_large = out_bytes.len > @as(usize, cli_response_max);
    const bounded_code: u8 = if (response_too_large) 1 else code;
    const bounded_bytes: []const u8 = if (response_too_large) cli_response_too_large else out_bytes;
    var hdr: [5]u8 = undefined;
    hdr[0] = bounded_code;
    std.mem.writeInt(u32, hdr[1..5], @intCast(bounded_bytes.len), .little);
    if (!cliWriteFull(conn, &hdr)) return;
    if (bounded_bytes.len > 0) _ = cliWriteFull(conn, bounded_bytes);
}

/// Client side. If a daemon is listening for this project, proxy the command to
/// it and stream the rendered output to stdout, returning the daemon's exit
/// code. On ANY failure (no daemon, connect refused, short read, oversized
/// response) returns null so the caller falls back to the cold in-process path.
/// `args` is mainImpl's filtered argv (args[0] = program name); we send args[1..].
pub fn cliTryProxy(io: std.Io, allocator: std.mem.Allocator, abs_root: []const u8, args: []const []const u8, color: bool) ?u8 {
    _ = io;
    if (args.len < 2) return null;

    const conn = cliConnect(abs_root) orelse return null;
    defer cliCloseConn(conn);

    // Build the NUL-joined blob from args[1..].
    var blob: std.ArrayList(u8) = .empty;
    defer blob.deinit(allocator);
    for (args[1..], 0..) |a, i| {
        if (i != 0) blob.append(allocator, 0) catch return null;
        blob.appendSlice(allocator, a) catch return null;
    }
    if (blob.items.len == 0 or blob.items.len > cli_blob_max) return null;

    // Request header: [u8 color][u32 blob_len]
    var hdr: [5]u8 = undefined;
    hdr[0] = if (color) 1 else 0;
    std.mem.writeInt(u32, hdr[1..5], @intCast(blob.items.len), .little);
    if (!cliWriteFull(conn, &hdr)) return null;
    if (!cliWriteFull(conn, blob.items)) return null;

    // Response header: [u8 code][u32 out_len]
    var resp_hdr: [5]u8 = undefined;
    if (!cliReadFull(conn, &resp_hdr)) return null;
    const code = resp_hdr[0];
    const out_len = std.mem.readInt(u32, resp_hdr[1..5], .little);
    if (!cliResponseLenAllowed(out_len)) return null;

    if (out_len > 0) {
        const out_bytes = allocator.alloc(u8, out_len) catch return null;
        defer allocator.free(out_bytes);
        if (!cliReadFull(conn, out_bytes)) return null;
        cio.File.stdout().writeAll(out_bytes) catch {};
    }
    return code;
}

fn cliConnect(abs_root: []const u8) ?CliConn {
    if (builtin.os.tag == .windows) {
        var name_buf: [256]u8 = undefined;
        const pipe_name = cliPipeName(&name_buf, abs_root) orelse return null;
        const pipe = CreateFileA(pipe_name.ptr, GENERIC_READ | GENERIC_WRITE, 0, null, OPEN_EXISTING, SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION, null);
        if (pipe == INVALID_HANDLE_VALUE) return null;
        return pipe;
    }
    var path_buf: [128]u8 = undefined;
    const sock_path = cliSocketPath(&path_buf, abs_root) orelse return null;
    const sa = cliFillSockaddr(sock_path) orelse return null;
    const fd = std.c.socket(std.c.AF.UNIX, std.c.SOCK.STREAM, 0);
    if (fd < 0) return null;
    var sa_mut = sa;
    if (std.c.connect(fd, @ptrCast(&sa_mut.addr), sa_mut.len) != 0) {
        _ = std.c.close(fd);
        return null;
    }
    return fd;
}

fn cliCloseConn(conn: CliConn) void {
    if (builtin.os.tag == .windows) {
        win.CloseHandle(conn);
        return;
    }
    _ = std.c.close(conn);
}
