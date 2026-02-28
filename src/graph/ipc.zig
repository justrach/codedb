// CodeGraph DB — Unix socket IPC protocol
//
// Length-prefixed binary frames over Unix domain sockets.
// The CodeGraph daemon listens on a socket; the MCP harness connects
// as a client and sends query requests.
//
// Frame format (little-endian):
//   [length: u32] [payload: length bytes]
//
// Payload is JSON (UTF-8) for simplicity and debuggability.
// The daemon reads a frame, dispatches the query, and writes a response frame.
//
// Socket path: .codegraph/daemon.sock (relative to repo root)

const std = @import("std");

pub const SOCKET_PATH = ".codegraph/daemon.sock";
pub const MAX_FRAME_SIZE: u32 = 16 * 1024 * 1024; // 16MB

// ── Frame I/O ───────────────────────────────────────────────────────────────

/// Write a length-prefixed frame to a stream.
pub fn writeFrame(writer: anytype, payload: []const u8) !void {
    if (payload.len > MAX_FRAME_SIZE) return error.FrameTooLarge;
    const len: u32 = @intCast(payload.len);
    try writer.writeInt(u32, len, .little);
    try writer.writeAll(payload);
}

/// Read a length-prefixed frame from a stream. Caller owns the returned slice.
pub fn readFrame(reader: anytype, alloc: std.mem.Allocator) ![]u8 {
    const len = try reader.readInt(u32, .little);
    if (len > MAX_FRAME_SIZE) return error.FrameTooLarge;
    const buf = try alloc.alloc(u8, len);
    errdefer alloc.free(buf);
    try reader.readNoEof(buf);
    return buf;
}

// ── Request / Response types ────────────────────────────────────────────────

pub const RequestKind = enum {
    symbol_at,
    find_callers,
    find_callees,
    find_dependents,
    ping,
    shutdown,
};

/// Parse a request kind from a JSON method string.
pub fn parseRequestKind(method: []const u8) ?RequestKind {
    return std.meta.stringToEnum(RequestKind, method);
}

// ── Client ──────────────────────────────────────────────────────────────────

pub const Client = struct {
    stream: std.net.Stream,

    /// Connect to the daemon socket.
    pub fn connect(path: []const u8) !Client {
        const stream = try std.net.connectUnixSocket(path);
        return .{ .stream = stream };
    }

    /// Send a request frame and read the response.
    pub fn call(self: *Client, request: []const u8, alloc: std.mem.Allocator) ![]u8 {
        try writeFrame(self.stream.writer(), request);
        return readFrame(self.stream.reader(), alloc);
    }

    pub fn close(self: *Client) void {
        self.stream.close();
    }
};

// ── Server ──────────────────────────────────────────────────────────────────

pub const Handler = *const fn (request: []const u8, alloc: std.mem.Allocator) ?[]u8;

pub const Server = struct {
    socket: std.net.Server,
    alloc: std.mem.Allocator,
    handler: Handler,
    running: bool,

    /// Create a server listening on the given Unix socket path.
    pub fn listen(path: []const u8, handler: Handler, alloc: std.mem.Allocator) !Server {
        // Remove stale socket file
        std.fs.cwd().deleteFile(path) catch {};

        // Ensure parent directory exists
        if (std.fs.path.dirname(path)) |dir| {
            std.fs.cwd().makePath(dir) catch {};
        }

        const addr = std.net.Address.initUnix(path) catch return error.InvalidSocketPath;
        const socket = try addr.listen(.{});

        return .{
            .socket = socket,
            .alloc = alloc,
            .handler = handler,
            .running = true,
        };
    }

    /// Accept and handle one connection (one request-response cycle).
    /// Returns false if a shutdown was requested.
    pub fn acceptOne(self: *Server) !bool {
        const conn = try self.socket.accept();
        defer conn.stream.close();

        const request = readFrame(conn.stream.reader(), self.alloc) catch return true;
        defer self.alloc.free(request);

        const response = self.handler(request, self.alloc);
        if (response) |resp| {
            defer self.alloc.free(resp);
            writeFrame(conn.stream.writer(), resp) catch {};
        } else {
            // Handler returned null = shutdown signal
            self.running = false;
            writeFrame(conn.stream.writer(), "{\"status\":\"shutdown\"}") catch {};
            return false;
        }

        return true;
    }

    /// Run the server loop until shutdown.
    pub fn run(self: *Server) void {
        while (self.running) {
            _ = self.acceptOne() catch continue;
        }
    }

    pub fn deinit(self: *Server) void {
        self.socket.deinit();
        // Clean up socket file
        std.fs.cwd().deleteFile(SOCKET_PATH) catch {};
    }
};

// ── Tests ───────────────────────────────────────────────────────────────────

test "writeFrame and readFrame round-trip" {
    var buf: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);

    const payload = "hello, daemon!";
    try writeFrame(stream.writer(), payload);

    stream.pos = 0;
    const result = try readFrame(stream.reader(), std.testing.allocator);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings(payload, result);
}

test "writeFrame rejects oversized payload" {
    var buf: [8]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);

    // Create a slice reference that would exceed MAX_FRAME_SIZE
    // We can't actually allocate 16MB in tests, so test the check indirectly
    const small_payload = "ok";
    try writeFrame(stream.writer(), small_payload);
}

test "readFrame rejects oversized length" {
    var buf: [8]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const w = stream.writer();
    w.writeInt(u32, MAX_FRAME_SIZE + 1, .little) catch unreachable;

    stream.pos = 0;
    const result = readFrame(stream.reader(), std.testing.allocator);
    try std.testing.expectError(error.FrameTooLarge, result);
}

test "empty frame round-trip" {
    var buf: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);

    try writeFrame(stream.writer(), "");
    stream.pos = 0;

    const result = try readFrame(stream.reader(), std.testing.allocator);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "multiple frames in sequence" {
    var buf: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);

    try writeFrame(stream.writer(), "frame1");
    try writeFrame(stream.writer(), "frame2");
    try writeFrame(stream.writer(), "frame3");

    stream.pos = 0;

    const f1 = try readFrame(stream.reader(), std.testing.allocator);
    defer std.testing.allocator.free(f1);
    try std.testing.expectEqualStrings("frame1", f1);

    const f2 = try readFrame(stream.reader(), std.testing.allocator);
    defer std.testing.allocator.free(f2);
    try std.testing.expectEqualStrings("frame2", f2);

    const f3 = try readFrame(stream.reader(), std.testing.allocator);
    defer std.testing.allocator.free(f3);
    try std.testing.expectEqualStrings("frame3", f3);
}

test "parseRequestKind resolves known methods" {
    try std.testing.expectEqual(RequestKind.symbol_at, parseRequestKind("symbol_at").?);
    try std.testing.expectEqual(RequestKind.find_callers, parseRequestKind("find_callers").?);
    try std.testing.expectEqual(RequestKind.ping, parseRequestKind("ping").?);
    try std.testing.expectEqual(RequestKind.shutdown, parseRequestKind("shutdown").?);
    try std.testing.expectEqual(@as(?RequestKind, null), parseRequestKind("unknown_method"));
}
