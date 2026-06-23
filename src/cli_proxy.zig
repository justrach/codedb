//! Thin CLI client → warm daemon proxy + the per-project spawn lock.
const std = @import("std");
const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;
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

/// Build the per-project socket path into `buf`. Stays well under sun_path
/// (104 bytes on macOS / 108 on Linux): "/tmp/codedb-<uid>-<hash16>.sock" is
/// at most ~40 bytes. Returns null only if formatting somehow overflows `buf`.
pub fn cliSocketPath(buf: []u8, abs_root: []const u8) ?[]const u8 {
    const hash = std.hash.Wyhash.hash(0xc0de, abs_root);
    if (is_windows) {
        // The warm-daemon proxy is disabled on Windows; this only needs to
        // produce a stable, compilable path (no getuid()).
        return std.fmt.bufPrint(buf, "codedb-{x:0>16}.sock", .{hash}) catch null;
    } else {
        const uid = std.c.getuid();
        return std.fmt.bufPrint(buf, "/tmp/codedb-{d}-{x:0>16}.sock", .{ uid, hash }) catch null;
    }
}

/// Fill a sockaddr.un for `path` (which must be NUL-terminatable into sun_path).
/// Returns the struct plus the byte length to pass to bind/connect. Path is
/// guaranteed short by cliSocketPath, but we guard the copy regardless.
fn cliFillSockaddr(path: []const u8) ?struct { addr: std.c.sockaddr.un, len: std.c.socklen_t } {
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
fn cliReadFull(fd: c_int, buf: []u8) bool {
    var off: usize = 0;
    while (off < buf.len) {
        const n = std.c.read(fd, buf.ptr + off, buf.len - off);
        if (n > 0) {
            off += @intCast(n);
            continue;
        }
        if (n == 0) return false; // peer closed early
        if (std.c.errno(n) == .INTR) continue;
        return false;
    }
    return true;
}

/// Write all of `data` to a blocking fd, looping over short/partial writes.
/// Returns false on a hard error (EINTR is retried).
fn cliWriteFull(fd: c_int, data: []const u8) bool {
    var off: usize = 0;
    while (off < data.len) {
        const n = std.c.write(fd, data.ptr + off, data.len - off);
        if (n > 0) {
            off += @intCast(n);
            continue;
        }
        if (n < 0 and std.c.errno(n) == .INTR) continue;
        return false;
    }
    return true;
}

/// #592: per-project cli-daemon spawn lock. Open-or-create
/// `<data_dir>/cli-daemon.lock` and take an exclusive non-blocking flock.
/// Returns the fd on success — callers keep it open for the process lifetime
/// (the kernel releases flocks on exit, so crashes never leave a stale lock).
/// Returns null when another process holds the lock or the file can't be
/// opened.
pub fn daemonLockTryAcquire(data_dir: []const u8) ?c_int {
    if (is_windows) {
        return null;
    } else {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const p = std.fmt.bufPrintZ(&buf, "{s}/cli-daemon.lock", .{data_dir}) catch return null;
        const fd = std.c.open(p.ptr, .{ .ACCMODE = .RDWR, .CREAT = true }, @as(c_uint, 0o600));
        if (fd < 0) return null;
        if (std.c.flock(fd, std.c.LOCK.EX | std.c.LOCK.NB) != 0) {
            _ = std.c.close(fd);
            return null;
        }
        return fd;
    }
}

/// Probe whether the spawn lock is free without keeping it: used by the CLI
/// auto-spawn path so racing cold calls don't fork duplicate daemons.
pub fn daemonLockAvailable(data_dir: []const u8) bool {
    if (is_windows) {
        return false;
    } else {
        const fd = daemonLockTryAcquire(data_dir) orelse return false;
        _ = std.c.flock(fd, std.c.LOCK.UN);
        _ = std.c.close(fd);
        return true;
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
/// tell when the socket has gone quiet. `shutdown` is set to true on a fatal
/// bind/listen failure: this lets an auto-spawned cli-daemon that lost the bind
/// race to an already-running daemon exit promptly instead of lingering. The
/// long-lived serve/mcp daemons pass a `shutdown` flag they never watch, so for
/// them a bind failure simply disables the proxy (clients fall back to cold).
pub fn cliDaemonListen(io: std.Io, allocator: std.mem.Allocator, explorer: *Explorer, store: *Store, abs_root: []const u8, last_activity_ms: *std.atomic.Value(i64), shutdown: *std.atomic.Value(bool)) void {
    if (is_windows) {
        // No Unix-socket proxy on Windows; CLI calls run cold in-process.
        return;
    } else {
        cliDaemonListenPosix(io, allocator, explorer, store, abs_root, last_activity_ms, shutdown);
    }
}

fn cliDaemonListenPosix(io: std.Io, allocator: std.mem.Allocator, explorer: *Explorer, store: *Store, abs_root: []const u8, last_activity_ms: *std.atomic.Value(i64), shutdown: *std.atomic.Value(bool)) void {
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

    const sa = cliFillSockaddr(sock_path) orelse {
        shutdown.store(true, .release);
        return;
    };

    // Try to bind; if the path is stale (a dead daemon left it behind) unlink
    // and retry once. listenfd is owned for the lifetime of the daemon.
    var listenfd: c_int = -1;
    var attempt: u8 = 0;
    while (attempt < 2) : (attempt += 1) {
        const fd = std.c.socket(std.c.AF.UNIX, std.c.SOCK.STREAM, 0);
        if (fd < 0) {
            std.log.warn("cli-proxy: socket() failed", .{});
            shutdown.store(true, .release);
            return;
        }
        var sa_mut = sa;
        const rc = std.c.bind(fd, @ptrCast(&sa_mut.addr), sa_mut.len);
        if (rc == 0) {
            listenfd = fd;
            break;
        }
        _ = std.c.close(fd);
        if (attempt == 0) {
            // Stale socket from a previous (now dead) daemon — clear and retry.
            _ = std.c.unlink(sock_path_z.ptr);
            continue;
        }
        // A live daemon already owns this socket (lost the bind race). Signal
        // shutdown so a duplicate auto-spawned cli-daemon exits promptly.
        std.log.warn("cli-proxy: bind {s} failed — proxy disabled", .{sock_path});
        shutdown.store(true, .release);
        return;
    }
    if (listenfd < 0) {
        shutdown.store(true, .release);
        return;
    }
    defer {
        _ = std.c.close(listenfd);
        _ = std.c.unlink(sock_path_z.ptr);
    }

    // Owner-only perms on the socket (0600). Must chmod the path, not fchmod the
    // fd: Darwin ignores fchmod() on a socket fd, leaving the node world-rwx.
    // Safe to do before listen() — no client can connect+use it yet. Non-fatal.
    _ = std.c.chmod(sock_path_z.ptr, 0o600);

    if (std.c.listen(listenfd, 16) != 0) {
        std.log.warn("cli-proxy: listen failed — proxy disabled", .{});
        shutdown.store(true, .release);
        return;
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
fn cliServeConn(io: std.Io, allocator: std.mem.Allocator, explorer: *Explorer, store: *Store, abs_root: []const u8, conn: c_int) void {
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
fn cliRespond(conn: c_int, code: u8, out_bytes: []const u8) void {
    var hdr: [5]u8 = undefined;
    hdr[0] = code;
    std.mem.writeInt(u32, hdr[1..5], @intCast(out_bytes.len), .little);
    if (!cliWriteFull(conn, &hdr)) return;
    if (out_bytes.len > 0) _ = cliWriteFull(conn, out_bytes);
}

/// Client side. If a daemon is listening for this project, proxy the command to
/// it and stream the rendered output to stdout, returning the daemon's exit
/// code. On ANY failure (no daemon, connect refused, short read, oversized
/// response) returns null so the caller falls back to the cold in-process path.
/// `args` is mainImpl's filtered argv (args[0] = program name); we send args[1..].
pub fn cliTryProxy(io: std.Io, allocator: std.mem.Allocator, abs_root: []const u8, args: []const []const u8, color: bool) ?u8 {
    if (is_windows) {
        return null;
    } else {
        return cliTryProxyPosix(io, allocator, abs_root, args, color);
    }
}

fn cliTryProxyPosix(io: std.Io, allocator: std.mem.Allocator, abs_root: []const u8, args: []const []const u8, color: bool) ?u8 {
    _ = io;
    if (args.len < 2) return null;

    var path_buf: [128]u8 = undefined;
    const sock_path = cliSocketPath(&path_buf, abs_root) orelse return null;
    const sa = cliFillSockaddr(sock_path) orelse return null;

    const fd = std.c.socket(std.c.AF.UNIX, std.c.SOCK.STREAM, 0);
    if (fd < 0) return null;
    defer _ = std.c.close(fd);

    var sa_mut = sa;
    if (std.c.connect(fd, @ptrCast(&sa_mut.addr), sa_mut.len) != 0) return null;

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
    if (!cliWriteFull(fd, &hdr)) return null;
    if (!cliWriteFull(fd, blob.items)) return null;

    // Response header: [u8 code][u32 out_len]
    var resp_hdr: [5]u8 = undefined;
    if (!cliReadFull(fd, &resp_hdr)) return null;
    const code = resp_hdr[0];
    const out_len = std.mem.readInt(u32, resp_hdr[1..5], .little);

    if (out_len > 0) {
        const out_bytes = allocator.alloc(u8, out_len) catch return null;
        defer allocator.free(out_bytes);
        if (!cliReadFull(fd, out_bytes)) return null;
        cio.File.stdout().writeAll(out_bytes) catch {};
    }
    return code;
}
