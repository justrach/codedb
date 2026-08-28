//! Thin CLI client → warm daemon proxy + the per-project spawn lock.
const std = @import("std");
const builtin = @import("builtin");
const cio = @import("cio.zig");
const sty = @import("style.zig");
const Store = @import("store.zig").Store;
const Explorer = @import("explore.zig").Explorer;
const Out = @import("out.zig").Out;
const runQuery = @import("query.zig").runQuery;
const watcher = @import("watcher.zig");
const release_info = @import("release_info.zig");
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
//       legacy blob = argv[1..] NUL-joined, e.g. "/proj\0find\0foo"
//       current blob = version marker, semver, then argv fields (all NUL-joined)
//   response (daemon→client): [u8 exit_code][u32 out_len][out_bytes]
const cli_blob_max: u32 = 64 * 1024;
const cli_response_max: u32 = 16 * 1024 * 1024;

fn cliResponseLenAllowed(out_len: u32) bool {
    return out_len <= cli_response_max;
}

fn cliResponseSendAllowed(out_len: usize) bool {
    return out_len <= @as(usize, cli_response_max);
}

test "cli response length cap rejects oversized frames" {
    try std.testing.expect(cliResponseLenAllowed(0));
    try std.testing.expect(cliResponseLenAllowed(cli_response_max));
    try std.testing.expect(!cliResponseLenAllowed(cli_response_max + 1));
    try std.testing.expect(cliResponseSendAllowed(cli_response_max));
    try std.testing.expect(!cliResponseSendAllowed(@as(usize, cli_response_max) + 1));
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
const PIPE_REJECT_REMOTE_CLIENTS: u32 = 0x00000008;
const PROCESS_QUERY_LIMITED_INFORMATION: u32 = 0x00001000;
const TOKEN_QUERY: u32 = 0x0008;
const TokenUser: u32 = 1;

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
extern "kernel32" fn GetNamedPipeServerProcessId(Pipe: win.HANDLE, ServerProcessId: *u32) callconv(.winapi) win.BOOL;
extern "kernel32" fn CreateFileW(
    lpFileName: [*:0]const u16,
    dwDesiredAccess: u32,
    dwShareMode: u32,
    lpSecurityAttributes: ?*anyopaque,
    dwCreationDisposition: u32,
    dwFlagsAndAttributes: u32,
    hTemplateFile: ?win.HANDLE,
) callconv(.winapi) win.HANDLE;
extern "kernel32" fn OpenProcess(dwDesiredAccess: u32, bInheritHandle: win.BOOL, dwProcessId: u32) callconv(.winapi) ?win.HANDLE;
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) win.HANDLE;
extern "kernel32" fn ReadFile(hFile: win.HANDLE, lpBuffer: [*]u8, nNumberOfBytesToRead: u32, lpNumberOfBytesRead: *u32, lpOverlapped: ?*anyopaque) callconv(.winapi) win.BOOL;
extern "kernel32" fn WriteFile(hFile: win.HANDLE, lpBuffer: [*]const u8, nNumberOfBytesToWrite: u32, lpNumberOfBytesWritten: *u32, lpOverlapped: ?*anyopaque) callconv(.winapi) win.BOOL;
extern "kernel32" fn LocalFree(hMem: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "advapi32" fn OpenProcessToken(ProcessHandle: win.HANDLE, DesiredAccess: u32, TokenHandle: *win.HANDLE) callconv(.winapi) win.BOOL;
extern "advapi32" fn GetTokenInformation(TokenHandle: win.HANDLE, TokenInformationClass: u32, TokenInformation: ?*anyopaque, TokenInformationLength: u32, ReturnLength: *u32) callconv(.winapi) win.BOOL;
extern "advapi32" fn EqualSid(pSid1: ?*anyopaque, pSid2: ?*anyopaque) callconv(.winapi) win.BOOL;
extern "advapi32" fn ConvertSidToStringSidA(Sid: ?*anyopaque, StringSid: *?[*:0]u8) callconv(.winapi) win.BOOL;
extern "advapi32" fn ConvertStringSecurityDescriptorToSecurityDescriptorA(
    sddl: [*:0]const u8,
    revision: u32,
    sd: *?*anyopaque,
    sd_size: ?*u32,
) callconv(.winapi) win.BOOL;
extern "advapi32" fn SystemFunction036(RandomBuffer: ?*anyopaque, RandomBufferLength: u32) callconv(.winapi) win.BOOL;

const SID_AND_ATTRIBUTES = extern struct {
    Sid: ?*anyopaque,
    Attributes: u32,
};

const TOKEN_USER = extern struct {
    User: SID_AND_ATTRIBUTES,
};

/// How often a long-lived serve/mcp daemon that lost the CLI socket bind
/// re-attempts it (see cliAcquireListener) — one second, matching the daemons'
/// watchdog cadence and bounded by the previous owner's idle timeout.
const cli_bind_retry_ms: u64 = 1000;

/// #619 handover: wire-protocol sentinel a starting serve/mcp daemon sends to
/// the CURRENT socket owner to ask it to give up the socket right away,
/// instead of the newcomer waiting out the owner's idle timeout / full retry
/// cadence. Any live owner — an auto-spawned cli-daemon or another serve/mcp
/// daemon — honors it unconditionally on receipt (cliServeConn): same-uid
/// access to the socket (chmod 0600) is already the trust boundary for this
/// protocol, so no extra authentication is layered on top. Exported for
/// tests. Chosen so it can never collide with a real request blob, which
/// always starts with a project root path (see cliTryProxy).
pub const cli_yield_sentinel = "\x01codedb-cli-yield-v1\x01";
pub const cli_refresh_sentinel = "\x01codedb-cli-refresh-v1\x01";
const cli_version_marker = "\x01codedb-cli-version-v1\x01";
const cli_versioned_response_flag: u8 = 0x80;
const cli_version_mismatch_code: u8 = 0x7f;

const CliVersionEnvelope = struct {
    argv_blob: []const u8,
    versioned: bool = false,
    compatible: bool = true,
};

fn unwrapCliVersionEnvelope(blob: []const u8) CliVersionEnvelope {
    if (!std.mem.startsWith(u8, blob, cli_version_marker) or
        blob.len <= cli_version_marker.len or blob[cli_version_marker.len] != 0)
    {
        return .{ .argv_blob = blob };
    }
    const version_start = cli_version_marker.len + 1;
    const version_end = std.mem.indexOfScalarPos(u8, blob, version_start, 0) orelse
        return .{ .argv_blob = "", .versioned = true, .compatible = false };
    return .{
        .argv_blob = blob[version_end + 1 ..],
        .versioned = true,
        .compatible = std.mem.eql(u8, blob[version_start..version_end], release_info.semver),
    };
}

test "CLI proxy version envelope preserves legacy requests and rejects stale daemons" {
    const legacy = "/project\x00find\x00main";
    const parsed_legacy = unwrapCliVersionEnvelope(legacy);
    try std.testing.expect(!parsed_legacy.versioned);
    try std.testing.expect(parsed_legacy.compatible);
    try std.testing.expectEqualStrings(legacy, parsed_legacy.argv_blob);

    const current = cli_version_marker ++ "\x00" ++ release_info.semver ++ "\x00/project\x00find\x00main";
    const parsed_current = unwrapCliVersionEnvelope(current);
    try std.testing.expect(parsed_current.versioned);
    try std.testing.expect(parsed_current.compatible);
    try std.testing.expectEqualStrings(legacy, parsed_current.argv_blob);

    const stale = cli_version_marker ++ "\x000.0.0\x00/project\x00find\x00main";
    const parsed_stale = unwrapCliVersionEnvelope(stale);
    try std.testing.expect(parsed_stale.versioned);
    try std.testing.expect(!parsed_stale.compatible);
}

/// Settle delay after sending a yield request before the very next bind
/// attempt: gives the owner a moment to process the sentinel, unbind, and
/// unlink before we retry, without paying the full retry_interval_ms.
const cli_yield_settle_ms: u64 = 20;

/// Build the per-project socket path into `buf`. Stays well under sun_path
/// (104 bytes on macOS / 108 on Linux): "/tmp/codedb-<uid>-<hash16>.sock" is
/// at most ~40 bytes. Returns null only if formatting somehow overflows `buf`.
pub fn cliSocketPath(buf: []u8, abs_root: []const u8) ?[]const u8 {
    const uid = cio.userId();
    const hash = std.hash.Wyhash.hash(0xc0de, abs_root);
    return std.fmt.bufPrint(buf, "/tmp/codedb-{d}-{x:0>16}.sock", .{ uid, hash }) catch null;
}

const cli_pipe_metadata_filename = "cli-daemon.pipe";

fn cliPipeMetadataPath(allocator: std.mem.Allocator, data_dir: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ data_dir, cli_pipe_metadata_filename });
}

fn cliRandomPipeName(buf: []u8) ?[:0]const u8 {
    return cio.bufPrintZ(buf, "\\\\.\\pipe\\codedb-{d}-{x:0>16}-{x:0>16}", .{
        cio.currentProcessId(),
        secureRandomU64(),
        secureRandomU64(),
    }) catch null;
}

fn secureRandomU64() u64 {
    var bytes: [8]u8 = undefined;
    if (SystemFunction036(&bytes, bytes.len) != .FALSE) {
        return std.mem.readInt(u64, &bytes, .little);
    }
    return cio.randU64();
}

const CliPipeMetadata = struct {
    pid: u32,
    pipe_name: []const u8,
};

pub fn parseCliPipeMetadata(text: []const u8) ?CliPipeMetadata {
    var pid: ?u32 = null;
    var pipe_name: ?[]const u8 = null;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (std.mem.startsWith(u8, line, "pid=")) {
            pid = std.fmt.parseInt(u32, line["pid=".len..], 10) catch return null;
        } else if (std.mem.startsWith(u8, line, "pipe=")) {
            const value = line["pipe=".len..];
            if (!std.mem.startsWith(u8, value, "\\\\.\\pipe\\codedb-")) return null;
            pipe_name = value;
        }
    }

    const parsed_pid = pid orelse return null;
    if (parsed_pid == 0) return null;
    return .{ .pid = parsed_pid, .pipe_name = pipe_name orelse return null };
}

pub fn cliPipeMetadataMatchesOwner(text: []const u8, pid: u32, pipe_name: []const u8) bool {
    const metadata = parseCliPipeMetadata(text) orelse return false;
    return metadata.pid == pid and std.mem.eql(u8, metadata.pipe_name, pipe_name);
}

fn writeCliPipeMetadata(io: std.Io, allocator: std.mem.Allocator, data_dir: []const u8, pid: u32, pipe_name: []const u8) bool {
    const path = cliPipeMetadataPath(allocator, data_dir) catch return false;
    defer allocator.free(path);
    const content = std.fmt.allocPrint(allocator, "pid={d}\npipe={s}\n", .{ pid, pipe_name }) catch return false;
    defer allocator.free(content);
    const f = std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true }) catch return false;
    defer f.close(io);
    f.writePositionalAll(io, content, 0) catch return false;
    return true;
}

fn deleteCliPipeMetadataIfOwner(io: std.Io, allocator: std.mem.Allocator, data_dir: []const u8, pid: u32, pipe_name: []const u8) void {
    const path = cliPipeMetadataPath(allocator, data_dir) catch return;
    defer allocator.free(path);
    const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024)) catch return;
    defer allocator.free(content);
    if (!cliPipeMetadataMatchesOwner(content, pid, pipe_name)) return;
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

fn readCliPipeMetadata(io: std.Io, allocator: std.mem.Allocator, data_dir: []const u8) ?[]u8 {
    const path = cliPipeMetadataPath(allocator, data_dir) catch return null;
    defer allocator.free(path);
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024)) catch null;
}

fn cliPipeMetadataNeedsPublish(io: std.Io, allocator: std.mem.Allocator, data_dir: []const u8, pid: u32, pipe_name: []const u8) bool {
    const content = readCliPipeMetadata(io, allocator, data_dir) orelse return true;
    defer allocator.free(content);
    if (cliPipeMetadataMatchesOwner(content, pid, pipe_name)) return false;
    const metadata = parseCliPipeMetadata(content) orelse return true;
    if (metadata.pid == pid) return true;
    if (builtin.os.tag != .windows) return true;
    return !processUserMatchesCurrent(allocator, metadata.pid);
}

fn cliPipeMetadataMonitor(io: std.Io, allocator: std.mem.Allocator, data_dir: []const u8, pid: u32, pipe_name: []const u8, shutdown: *std.atomic.Value(bool)) void {
    while (!shutdown.load(.acquire)) {
        if (cliPipeMetadataNeedsPublish(io, allocator, data_dir, pid, pipe_name)) {
            if (!writeCliPipeMetadata(io, allocator, data_dir, pid, pipe_name)) {
                std.log.warn("cli-proxy: could not refresh pipe metadata", .{});
            }
        }
        cio.sleepMs(cli_bind_retry_ms);
    }
}

test "cli pipe metadata publish decision handles stale owner records" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var io = std.Io.Threaded.init(allocator, .{});
    defer io.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var data_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const data_dir_len = try tmp.dir.realPath(io.io(), &data_dir_buf);
    const data_dir = data_dir_buf[0..data_dir_len];

    const pid: u32 = 4242;
    const pipe_name = "\\\\.\\pipe\\codedb-test-owner";
    const other_pipe_name = "\\\\.\\pipe\\codedb-test-other";

    try std.testing.expect(cliPipeMetadataNeedsPublish(io.io(), allocator, data_dir, pid, pipe_name));
    try std.testing.expect(writeCliPipeMetadata(io.io(), allocator, data_dir, pid, pipe_name));
    try std.testing.expect(!cliPipeMetadataNeedsPublish(io.io(), allocator, data_dir, pid, pipe_name));
    try std.testing.expect(writeCliPipeMetadata(io.io(), allocator, data_dir, pid, other_pipe_name));
    try std.testing.expect(cliPipeMetadataNeedsPublish(io.io(), allocator, data_dir, pid, pipe_name));

    const metadata_path = try cliPipeMetadataPath(allocator, data_dir);
    defer allocator.free(metadata_path);
    const malformed = try std.Io.Dir.cwd().createFile(io.io(), metadata_path, .{ .truncate = true });
    defer malformed.close(io.io());
    try malformed.writePositionalAll(io.io(), "pid=nope\npipe=bad\n", 0);
    try std.testing.expect(cliPipeMetadataNeedsPublish(io.io(), allocator, data_dir, pid, pipe_name));
}

fn windowsPathZ(allocator: std.mem.Allocator, path: []const u8) ?[:0]u16 {
    return std.unicode.utf8ToUtf16LeAllocZ(allocator, path) catch null;
}

const TokenSid = struct {
    bytes: []u8,
    sid: ?*anyopaque,
};

fn tokenSid(allocator: std.mem.Allocator, token: win.HANDLE) ?TokenSid {
    var needed: u32 = 0;
    _ = GetTokenInformation(token, TokenUser, null, 0, &needed);
    if (needed == 0) return null;
    const bytes = allocator.alloc(u8, needed) catch return null;
    if (GetTokenInformation(token, TokenUser, bytes.ptr, needed, &needed) == .FALSE) {
        allocator.free(bytes);
        return null;
    }
    const user: *TOKEN_USER = @ptrCast(@alignCast(bytes.ptr));
    return .{ .bytes = bytes, .sid = user.User.Sid };
}

fn currentUserSidString(allocator: std.mem.Allocator) ?[]u8 {
    var token: win.HANDLE = undefined;
    if (OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token) == .FALSE) return null;
    defer win.CloseHandle(token);

    const sid_info = tokenSid(allocator, token) orelse return null;
    defer allocator.free(sid_info.bytes);

    var sid_z: ?[*:0]u8 = null;
    if (ConvertSidToStringSidA(sid_info.sid, &sid_z) == .FALSE) return null;
    defer _ = LocalFree(sid_z);
    return allocator.dupe(u8, std.mem.span(sid_z.?)) catch null;
}

fn currentUserPipeSddl(allocator: std.mem.Allocator) ?[:0]u8 {
    const sid = currentUserSidString(allocator) orelse return null;
    defer allocator.free(sid);
    const sddl = std.fmt.allocPrint(allocator, "D:P(A;;GA;;;{s})S:(ML;;NW;;;ME)", .{sid}) catch return null;
    defer allocator.free(sddl);
    return allocator.dupeSentinel(u8, sddl, 0) catch null;
}

fn processUserMatchesCurrent(allocator: std.mem.Allocator, pid: u32) bool {
    const process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, .FALSE, pid) orelse return false;
    defer win.CloseHandle(process);

    var process_token: win.HANDLE = undefined;
    if (OpenProcessToken(process, TOKEN_QUERY, &process_token) == .FALSE) return false;
    defer win.CloseHandle(process_token);

    var current_token: win.HANDLE = undefined;
    if (OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &current_token) == .FALSE) return false;
    defer win.CloseHandle(current_token);

    const process_sid = tokenSid(allocator, process_token) orelse return false;
    defer allocator.free(process_sid.bytes);
    const current_sid = tokenSid(allocator, current_token) orelse return false;
    defer allocator.free(current_sid.bytes);

    return EqualSid(process_sid.sid, current_sid.sid) != .FALSE;
}

fn pipeServerTrusted(allocator: std.mem.Allocator, pipe: win.HANDLE, expected_pid: u32) bool {
    var server_pid: u32 = 0;
    if (GetNamedPipeServerProcessId(pipe, &server_pid) == .FALSE) return false;
    if (server_pid == 0 or server_pid != expected_pid) return false;
    return processUserMatchesCurrent(allocator, server_pid);
}

fn pipeRetryDelayMs(failures: u32) u64 {
    const capped: u64 = @min(@as(u64, failures), 50);
    return 100 * capped;
}

fn shouldLogPipeRetry(failures: u32) bool {
    return failures == 1 or failures % 50 == 0;
}

fn createCliPipeInstance(pipe_name: [:0]const u8, first_instance: bool, sa_pipe: *win.SECURITY_ATTRIBUTES) win.HANDLE {
    const first_flag: u32 = if (first_instance) FILE_FLAG_FIRST_PIPE_INSTANCE else 0;
    return CreateNamedPipeA(
        pipe_name.ptr,
        PIPE_ACCESS_DUPLEX | first_flag,
        PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
        PIPE_UNLIMITED_INSTANCES,
        cli_blob_max + 5,
        cli_blob_max + 5,
        0,
        sa_pipe,
    );
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
    const p = cio.bufPrintZ(&buf, "{s}/cli-daemon.lock", .{data_dir}) catch return null;
    if (builtin.os.tag == .windows) {
        const path_w = windowsPathZ(std.heap.page_allocator, p) orelse return null;
        defer std.heap.page_allocator.free(path_w);
        const handle = CreateFileW(path_w.ptr, GENERIC_READ | GENERIC_WRITE, 0, null, OPEN_ALWAYS, 0, null);
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

/// #619 handover: connect to a LIVE owner and send the yield sentinel
/// (best-effort — a write failure just means we fall back to the normal
/// retry cadence). Does not wait for or read the owner's response: the
/// owner closes and unlinks the socket synchronously before it ever gets a
/// chance to write one, so waiting on a reply here would just be a way to
/// hang against a buggy or hostile peer for no benefit.
fn cliSendYieldRequest(sa: SockAddr) void {
    const fd = std.c.socket(std.c.AF.UNIX, std.c.SOCK.STREAM, 0);
    if (fd < 0) return;
    defer _ = std.c.close(fd);
    var sa_mut = sa;
    if (std.c.connect(fd, @ptrCast(&sa_mut.addr), sa_mut.len) != 0) return;
    var hdr: [5]u8 = undefined;
    hdr[0] = 0;
    std.mem.writeInt(u32, hdr[1..5], @intCast(cli_yield_sentinel.len), .little);
    if (!cliWriteFull(fd, &hdr)) return;
    _ = cliWriteFull(fd, cli_yield_sentinel);
}

/// Acquire the per-project CLI socket and return a listening fd.
///
/// A stale node left by a dead daemon (bind fails but nothing is listening) is
/// unlinked and rebound at once. When the path is held by a LIVE owner the
/// behavior depends on `retry`:
///   - retry == false (auto-spawned cli-daemon that lost the race): return null
///     immediately so the duplicate exits instead of stealing a live socket.
///   - retry == true (long-lived serve/mcp daemon): send the owner a one-shot
///     yield request (#619 handover — see cli_yield_sentinel) so a live owner
///     gives the socket up right away instead of us waiting out its idle
///     timeout, then keep re-attempting every `retry_interval_ms` until the
///     bind succeeds. The request is sent at most once per call so two
///     daemons racing to start can't ping-pong signals back and forth.
/// Returns null if `shutdown` is set while waiting.
pub fn cliAcquireListener(sock_path: []const u8, retry: bool, retry_interval_ms: u64, shutdown: *std.atomic.Value(bool)) ?c_int {
    var z_buf: [128]u8 = undefined;
    const sock_path_z = cio.bufPrintZ(&z_buf, "{s}", .{sock_path}) catch return null;
    const sa = cliFillSockaddr(sock_path) orelse return null;
    var yield_sent = false;
    while (true) {
        if (cliBindListen(sa, sock_path_z)) |fd| return fd;
        // Bind failed: the path exists. Clear it only when no one is listening
        // (stale node), never when a live owner still holds it.
        if (!cliSocketLive(sa)) {
            _ = std.c.unlink(sock_path_z.ptr);
            if (cliBindListen(sa, sock_path_z)) |fd| return fd;
        } else if (retry and !yield_sent) {
            yield_sent = true;
            cliSendYieldRequest(sa);
            cio.sleepMs(cli_yield_settle_ms);
            continue;
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
pub fn cliDaemonListen(io: std.Io, allocator: std.mem.Allocator, explorer: *Explorer, store: *Store, abs_root: []const u8, data_dir: []const u8, last_activity_ms: *std.atomic.Value(i64), shutdown: *std.atomic.Value(bool), retry: bool) void {
    if (builtin.os.tag == .windows) {
        var name_buf: [256]u8 = undefined;

        const sddl = currentUserPipeSddl(allocator) orelse {
            shutdown.store(true, .release);
            return;
        };
        defer allocator.free(sddl);
        var sd: ?*anyopaque = null;
        if (ConvertStringSecurityDescriptorToSecurityDescriptorA(sddl.ptr, SDDL_REVISION_1, &sd, null) == .FALSE) {
            shutdown.store(true, .release);
            return;
        }
        defer _ = LocalFree(sd);
        var sa_pipe: win.SECURITY_ATTRIBUTES = .{
            .nLength = @sizeOf(win.SECURITY_ATTRIBUTES),
            .lpSecurityDescriptor = sd,
            .bInheritHandle = .FALSE,
        };

        var pipe_name: ?[:0]const u8 = null;
        var listening_pipe: ?win.HANDLE = null;
        var metadata_written = false;
        var retry_failures: u32 = 0;
        var first_pipe_instance = true;
        const listener_pid = cio.currentProcessId();
        var metadata_monitor_thread: ?std.Thread = null;
        defer if (listening_pipe) |pipe| win.CloseHandle(pipe);
        defer if (metadata_written and pipe_name != null) deleteCliPipeMetadataIfOwner(io, allocator, data_dir, listener_pid, pipe_name.?);
        defer if (metadata_monitor_thread) |thread| thread.join();

        while (!shutdown.load(.acquire)) {
            if (pipe_name == null) {
                pipe_name = cliRandomPipeName(&name_buf) orelse {
                    shutdown.store(true, .release);
                    return;
                };
            }
            if (listening_pipe == null) {
                const new_pipe = createCliPipeInstance(pipe_name.?, first_pipe_instance, &sa_pipe);
                if (new_pipe == INVALID_HANDLE_VALUE) {
                    if (!metadata_written) pipe_name = null;
                    retry_failures = retry_failures +| 1;
                    if (shouldLogPipeRetry(retry_failures)) {
                        std.log.warn("cli-proxy: CreateNamedPipe failed {d} time(s); retrying", .{retry_failures});
                    }
                    cio.sleepMs(pipeRetryDelayMs(retry_failures));
                    continue;
                }
                listening_pipe = new_pipe;
                first_pipe_instance = false;
            }
            if (!metadata_written) {
                if (!writeCliPipeMetadata(io, allocator, data_dir, listener_pid, pipe_name.?)) {
                    win.CloseHandle(listening_pipe.?);
                    listening_pipe = null;
                    pipe_name = null;
                    first_pipe_instance = true;
                    retry_failures = retry_failures +| 1;
                    if (shouldLogPipeRetry(retry_failures)) {
                        std.log.warn("cli-proxy: could not publish pipe metadata {d} time(s); retrying", .{retry_failures});
                    }
                    cio.sleepMs(pipeRetryDelayMs(retry_failures));
                    continue;
                }
                metadata_written = true;
                retry_failures = 0;
                if (retry and metadata_monitor_thread == null) {
                    if (std.Thread.spawn(.{}, cliPipeMetadataMonitor, .{ io, allocator, data_dir, listener_pid, pipe_name.?, shutdown })) |thread| {
                        metadata_monitor_thread = thread;
                    } else |err| {
                        std.log.warn("cli-proxy: could not start pipe metadata monitor: {s}", .{@errorName(err)});
                    }
                }
            } else {
                retry_failures = 0;
            }
            const pipe = listening_pipe.?;
            listening_pipe = null;
            const connected = ConnectNamedPipe(pipe, null) != .FALSE or win.GetLastError() == .PIPE_CONNECTED;
            if (!connected) {
                win.CloseHandle(pipe);
                continue;
            }
            const next_pipe = createCliPipeInstance(pipe_name.?, false, &sa_pipe);
            if (next_pipe != INVALID_HANDLE_VALUE) {
                listening_pipe = next_pipe;
                retry_failures = 0;
            } else {
                retry_failures = retry_failures +| 1;
                if (shouldLogPipeRetry(retry_failures)) {
                    std.log.warn("cli-proxy: CreateNamedPipe replacement failed {d} time(s); retrying", .{retry_failures});
                }
            }
            last_activity_ms.store(cio.milliTimestamp(), .release);
            _ = cliServeConn(io, allocator, explorer, store, abs_root, pipe);
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
    const sock_path_z = cio.bufPrintZ(&path_z_buf, "{s}", .{sock_path}) catch {
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
        const yield_requested = cliServeConn(io, allocator, explorer, store, abs_root, conn);
        _ = std.c.close(conn);
        if (yield_requested) {
            // #619 handover: give the socket up right away. The `defer`
            // above closes the listener and unlinks the path so the
            // requesting daemon's next bind attempt succeeds; `shutdown` is
            // set so any caller watching it (e.g. the cli-daemon idle
            // watchdog) treats this exactly like a lost bind race.
            shutdown.store(true, .release);
            return;
        }
    }
}

/// Handle one client connection: read the framed request, run the query into a
/// sink buffer via runQuery, and write the framed response.
///
/// Returns true when the request was the #619 yield sentinel (see
/// cli_yield_sentinel): the caller must then stop listening and give the
/// socket up so the requesting daemon can take over.
fn cliServeConn(io: std.Io, allocator: std.mem.Allocator, explorer: *Explorer, store: *Store, abs_root: []const u8, conn: CliConn) bool {
    // Header: [u8 color][u32 blob_len]
    var hdr: [5]u8 = undefined;
    if (!cliReadFull(conn, &hdr)) return false;
    const color = hdr[0] != 0;
    const blob_len = std.mem.readInt(u32, hdr[1..5], .little);
    if (blob_len == 0 or blob_len > cli_blob_max) {
        cliRespond(conn, 1, "");
        return false;
    }

    const blob = allocator.alloc(u8, blob_len) catch {
        cliRespond(conn, 1, "");
        return false;
    };
    defer allocator.free(blob);
    if (!cliReadFull(conn, blob)) return false;

    // #619 handover: a starting serve/mcp daemon asking us to give up the
    // socket. Ack and tell the caller to stop listening — no query dispatch.
    if (std.mem.eql(u8, blob, cli_yield_sentinel)) {
        cliRespond(conn, 0, "");
        return true;
    }
    if (std.mem.eql(u8, blob, cli_refresh_sentinel)) {
        watcher.refreshIndex(io, store, explorer, abs_root, allocator) catch {
            cliRespond(conn, 1, "");
            return false;
        };
        cliRespond(conn, 0, "");
        return false;
    }

    // New clients identify their binary version before argv. Legacy clients
    // remain valid, while a version mismatch makes this daemon relinquish the
    // socket so an updated binary cannot keep proxying to stale query logic.
    const envelope = unwrapCliVersionEnvelope(blob);
    const argv_blob = envelope.argv_blob;
    const versioned = envelope.versioned;
    if (versioned) {
        if (!envelope.compatible) {
            cliRespond(conn, cli_versioned_response_flag | cli_version_mismatch_code, "");
            return true;
        }
        if (argv_blob.len == 0) {
            cliRespond(conn, cli_versioned_response_flag | 1, "");
            return false;
        }
    }

    // Rebuild argv = ["codedb"] ++ split(blob, '\0'), skipping empty fields.
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    argv.append(allocator, "codedb") catch {
        cliRespond(conn, 1, "");
        return false;
    };
    var it = std.mem.splitScalar(u8, argv_blob, 0);
    while (it.next()) |field| {
        if (field.len == 0) continue;
        argv.append(allocator, field) catch {
            cliRespond(conn, 1, "");
            return false;
        };
    }

    const parsed = parsePositional(argv.items);
    if (parsed.usage_exit or !cliIsQueryCmd(parsed.cmd)) {
        cliRespond(conn, (if (versioned) cli_versioned_response_flag else 0) | 1, "");
        return false;
    }

    var sink: std.ArrayList(u8) = .empty;
    defer sink.deinit(allocator);
    var out = Out{ .file = cio.File.stdout(), .alloc = allocator, .sink = &sink };
    const s = sty.style(color);
    const code = runQuery(io, allocator, explorer, store, abs_root, parsed.cmd, argv.items, parsed.cmd_args_start, &out, s);
    out.flush();

    cliRespond(conn, (if (versioned) cli_versioned_response_flag else 0) | code, sink.items);
    return false;
}

/// Write the framed response [u8 code][u32 out_len][out_bytes] to `conn`.
fn cliRespond(conn: CliConn, code: u8, out_bytes: []const u8) void {
    if (!cliResponseSendAllowed(out_bytes.len)) return;
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
pub fn cliTryProxy(io: std.Io, allocator: std.mem.Allocator, abs_root: []const u8, data_dir: ?[]const u8, args: []const []const u8, color: bool) ?u8 {
    if (args.len < 2) return null;

    var maybe_conn: ?CliConn = cliConnect(io, allocator, abs_root, data_dir) orelse return null;
    defer if (maybe_conn) |conn| cliCloseConn(conn);
    const conn = maybe_conn.?;

    // Build a versioned, NUL-joined blob. A current daemon acknowledges the
    // envelope in the response code; an old daemon cannot, so its output is
    // discarded and the command safely falls back to the current process.
    var blob: std.ArrayList(u8) = .empty;
    defer blob.deinit(allocator);
    blob.appendSlice(allocator, cli_version_marker) catch return null;
    blob.append(allocator, 0) catch return null;
    blob.appendSlice(allocator, release_info.semver) catch return null;
    for (args[1..]) |a| {
        blob.append(allocator, 0) catch return null;
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
    const wire_code = resp_hdr[0];
    const out_len = std.mem.readInt(u32, resp_hdr[1..5], .little);
    if (!cliResponseLenAllowed(out_len)) return null;

    const out_bytes = if (out_len > 0) blk: {
        const out_bytes = allocator.alloc(u8, out_len) catch return null;
        if (!cliReadFull(conn, out_bytes)) return null;
        break :blk out_bytes;
    } else null;
    defer if (out_bytes) |bytes| allocator.free(bytes);

    if (wire_code & cli_versioned_response_flag == 0) {
        // An older daemon served the version envelope as if it were argv. Close
        // this connection before asking it to yield: listeners are sequential.
        cliCloseConn(conn);
        maybe_conn = null;
        cliRequestYield(io, allocator, abs_root, data_dir);
        cio.sleepMs(cli_yield_settle_ms);
        return null;
    }
    const code = wire_code & ~cli_versioned_response_flag;
    if (code == cli_version_mismatch_code) {
        cio.sleepMs(cli_yield_settle_ms);
        return null;
    }
    if (out_bytes) |bytes| cio.File.stdout().writeAll(bytes) catch {};
    return code;
}

fn cliRequestYield(io: std.Io, allocator: std.mem.Allocator, abs_root: []const u8, data_dir: ?[]const u8) void {
    const conn = cliConnect(io, allocator, abs_root, data_dir) orelse return;
    defer cliCloseConn(conn);
    var hdr: [5]u8 = undefined;
    hdr[0] = 0;
    std.mem.writeInt(u32, hdr[1..5], @intCast(cli_yield_sentinel.len), .little);
    if (!cliWriteFull(conn, &hdr)) return;
    _ = cliWriteFull(conn, cli_yield_sentinel);
}

pub fn cliNotifyRefresh(io: std.Io, allocator: std.mem.Allocator, abs_root: []const u8, data_dir: ?[]const u8) ?bool {
    const conn = cliConnect(io, allocator, abs_root, data_dir) orelse return null;
    defer cliCloseConn(conn);

    var hdr: [5]u8 = undefined;
    hdr[0] = 0;
    std.mem.writeInt(u32, hdr[1..5], @intCast(cli_refresh_sentinel.len), .little);
    if (!cliWriteFull(conn, &hdr) or !cliWriteFull(conn, cli_refresh_sentinel)) return false;

    var resp_hdr: [5]u8 = undefined;
    if (!cliReadFull(conn, &resp_hdr)) return false;
    const out_len = std.mem.readInt(u32, resp_hdr[1..5], .little);
    if (!cliResponseLenAllowed(out_len)) return false;
    if (out_len > 0) {
        const response = allocator.alloc(u8, out_len) catch return false;
        defer allocator.free(response);
        if (!cliReadFull(conn, response)) return false;
    }
    return resp_hdr[0] == 0;
}

fn cliConnect(io: std.Io, allocator: std.mem.Allocator, abs_root: []const u8, data_dir: ?[]const u8) ?CliConn {
    if (builtin.os.tag == .windows) {
        const dir = data_dir orelse return null;
        const metadata_text = readCliPipeMetadata(io, allocator, dir) orelse return null;
        defer allocator.free(metadata_text);
        const metadata = parseCliPipeMetadata(metadata_text) orelse return null;
        const pipe_name_w = windowsPathZ(allocator, metadata.pipe_name) orelse return null;
        defer allocator.free(pipe_name_w);
        const pipe = CreateFileW(pipe_name_w.ptr, GENERIC_READ | GENERIC_WRITE, 0, null, OPEN_EXISTING, SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION, null);
        if (pipe == INVALID_HANDLE_VALUE) return null;
        if (!pipeServerTrusted(allocator, pipe, metadata.pid)) {
            win.CloseHandle(pipe);
            return null;
        }
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
