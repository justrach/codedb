// CodeGraph DB — query harness for local/daemon routing
//
// Unified query interface that auto-detects whether the CodeGraph daemon
// is running (paid tier) and routes queries accordingly:
//
//   - Local mode: loads the graph from disk and queries directly (free/trial)
//   - Daemon mode: routes queries through IPC socket (paid tier)
//
// Falls back to local mode if the daemon is unavailable.
// Reuses IPC connections across queries in daemon mode.

const std = @import("std");
const ipc = @import("ipc.zig");
const graph_query = @import("query.zig");
const graph_mod = @import("graph.zig");
const storage = @import("storage.zig");
const ppr_mod = @import("ppr.zig");
const CodeGraph = graph_mod.CodeGraph;

// ── Constants ───────────────────────────────────────────────────────────────

pub const GRAPH_PATH = ".codegraph/graph.bin";
pub const DAEMON_SOCKET_PATH = ipc.SOCKET_PATH; // .codegraph/daemon.sock

// ── Types ───────────────────────────────────────────────────────────────────

pub const QueryMode = enum { local, daemon };

pub const Harness = struct {
    mode: QueryMode,
    socket_fd: ?std.posix.fd_t,
    graph_path: []const u8,
    socket_path: []const u8,
    alloc: std.mem.Allocator,

    /// Initialize a new harness. Detects whether daemon mode is available
    /// and falls back to local mode if not.
    pub fn init(alloc: std.mem.Allocator) Harness {
        return initWithPaths(alloc, GRAPH_PATH, DAEMON_SOCKET_PATH);
    }

    /// Initialize with explicit paths (for testing).
    pub fn initWithPaths(
        alloc: std.mem.Allocator,
        graph_path: []const u8,
        socket_path: []const u8,
    ) Harness {
        var self = Harness{
            .mode = .local,
            .socket_fd = null,
            .graph_path = graph_path,
            .socket_path = socket_path,
            .alloc = alloc,
        };

        // Attempt daemon connection
        self.mode = self.detectMode(socket_path);
        return self;
    }

    /// Clean up resources. Closes daemon connection if open.
    pub fn deinit(self: *Harness) void {
        self.closeSocket();
    }

    fn closeSocket(self: *Harness) void {
        if (self.socket_fd) |fd| {
            std.posix.close(fd);
            self.socket_fd = null;
        }
    }

    /// Detect whether the daemon is available. Tries to connect to the
    /// socket; falls back to local mode if the socket doesn't exist or
    /// connection fails.
    pub fn detectMode(self: *Harness, socket_path: []const u8) QueryMode {
        // Check if daemon socket exists
        std.fs.cwd().access(socket_path, .{}) catch return .local;

        // Try to connect
        const stream = std.net.connectUnixSocket(socket_path) catch return .local;
        self.socket_fd = stream.handle;
        return .daemon;
    }

    /// Ensure we have an active daemon connection. If the connection was
    /// lost, attempt to reconnect. Returns false if reconnection fails.
    fn ensureConnection(self: *Harness) bool {
        if (self.socket_fd != null) return true;

        // Attempt reconnection
        const stream = std.net.connectUnixSocket(self.socket_path) catch return false;
        self.socket_fd = stream.handle;
        return true;
    }

    /// Send a length-prefixed frame over the socket using posix write.
    fn sendFrame(fd: std.posix.fd_t, payload: []const u8) !void {
        const len: u32 = @intCast(payload.len);
        const len_bytes = std.mem.toBytes(std.mem.nativeToLittle(u32, len));
        // Write length prefix
        var written: usize = 0;
        while (written < 4) {
            const n = std.posix.write(fd, len_bytes[written..]) catch return error.DaemonWriteFailed;
            if (n == 0) return error.DaemonWriteFailed;
            written += n;
        }
        // Write payload
        written = 0;
        while (written < payload.len) {
            const n = std.posix.write(fd, payload[written..]) catch return error.DaemonWriteFailed;
            if (n == 0) return error.DaemonWriteFailed;
            written += n;
        }
    }

    /// Read a length-prefixed frame from the socket using posix read.
    fn recvFrame(fd: std.posix.fd_t, alloc: std.mem.Allocator) ![]u8 {
        // Read 4-byte length prefix
        var len_bytes: [4]u8 = undefined;
        var read_total: usize = 0;
        while (read_total < 4) {
            const n = std.posix.read(fd, len_bytes[read_total..]) catch return error.DaemonReadFailed;
            if (n == 0) return error.DaemonReadFailed;
            read_total += n;
        }
        const len = std.mem.littleToNative(u32, std.mem.bytesToValue(u32, &len_bytes));
        if (len > ipc.MAX_FRAME_SIZE) return error.FrameTooLarge;

        // Read payload
        const buf = try alloc.alloc(u8, len);
        errdefer alloc.free(buf);
        read_total = 0;
        while (read_total < len) {
            const n = std.posix.read(fd, buf[read_total..]) catch {
                alloc.free(buf);
                return error.DaemonReadFailed;
            };
            if (n == 0) {
                alloc.free(buf);
                return error.DaemonReadFailed;
            }
            read_total += n;
        }
        return buf;
    }

    /// Execute a query, routing to the appropriate backend.
    /// Falls back from daemon to local if daemon fails.
    fn executeQuery(self: *Harness, request_json: []const u8) ![]u8 {
        if (self.mode == .daemon) {
            if (self.ensureConnection()) {
                if (self.daemonCall(request_json)) |response| {
                    return response;
                } else |_| {
                    // Daemon call failed — fall back to local
                    self.fallbackToLocal();
                }
            } else {
                self.fallbackToLocal();
            }
        }

        // Local mode
        return self.executeLocal(request_json);
    }

    /// Send a request and read a response via the daemon socket.
    fn daemonCall(self: *Harness, request: []const u8) ![]u8 {
        const fd = self.socket_fd orelse return error.DaemonNotConnected;
        try sendFrame(fd, request);
        return recvFrame(fd, self.alloc);
    }

    /// Switch from daemon mode to local mode (e.g. after connection failure).
    fn fallbackToLocal(self: *Harness) void {
        self.closeSocket();
        self.mode = .local;
    }

    /// Execute a query locally by loading the graph from disk.
    fn executeLocal(self: *Harness, request_json: []const u8) ![]u8 {
        var g = storage.loadFromFile(self.graph_path, self.alloc) catch
            return error.GraphNotFound;
        defer g.deinit();

        return self.dispatchLocal(&g, request_json);
    }

    /// Dispatch a JSON request to the appropriate local query function.
    fn dispatchLocal(self: *Harness, g: *CodeGraph, request_json: []const u8) ![]u8 {
        const parsed = std.json.parseFromSlice(
            std.json.Value,
            self.alloc,
            request_json,
            .{},
        ) catch return error.InvalidRequest;
        defer parsed.deinit();

        const root = parsed.value;
        const method_str = switch (root) {
            .object => |obj| blk: {
                const val = obj.get("method") orelse return error.InvalidRequest;
                break :blk switch (val) {
                    .string => |s| s,
                    else => return error.InvalidRequest,
                };
            },
            else => return error.InvalidRequest,
        };

        const method = ipc.parseRequestKind(method_str) orelse
            return error.UnknownMethod;

        const params = switch (root) {
            .object => |obj| obj.get("params"),
            else => null,
        };

        return switch (method) {
            .symbol_at => self.localSymbolAt(g, params),
            .find_callers => self.localFindCallers(g, params),
            .find_callees => self.localFindCallees(g, params),
            .find_dependents => self.localFindDependents(g, params),
            .ping => self.alloc.dupe(u8, "{\"status\":\"ok\",\"mode\":\"local\"}"),
            .shutdown => error.ShutdownRequested,
        };
    }

    // ── Local query implementations ─────────────────────────────────────

    fn localSymbolAt(self: *Harness, g: *CodeGraph, params: ?std.json.Value) ![]u8 {
        const p = params orelse return error.MissingParams;
        const obj = switch (p) {
            .object => |o| o,
            else => return error.MissingParams,
        };

        const file_path = switch (obj.get("file") orelse return error.MissingParams) {
            .string => |s| s,
            else => return error.MissingParams,
        };
        const line: u32 = switch (obj.get("line") orelse return error.MissingParams) {
            .integer => |i| @intCast(@max(i, 0)),
            else => return error.MissingParams,
        };

        const results = try graph_query.symbolAt(g, file_path, line, self.alloc);
        defer self.alloc.free(results);

        return formatSymbolResults(self.alloc, results);
    }

    fn localFindCallers(self: *Harness, g: *CodeGraph, params: ?std.json.Value) ![]u8 {
        const id = try extractSymbolId(params);
        const results = try graph_query.findCallers(g, id, self.alloc);
        defer self.alloc.free(results);
        return formatCallerResults(self.alloc, results);
    }

    fn localFindCallees(self: *Harness, g: *CodeGraph, params: ?std.json.Value) ![]u8 {
        const id = try extractSymbolId(params);
        const results = try graph_query.findCallees(g, id, self.alloc);
        defer self.alloc.free(results);
        return formatCallerResults(self.alloc, results);
    }

    fn localFindDependents(self: *Harness, g: *CodeGraph, params: ?std.json.Value) ![]u8 {
        const id = try extractSymbolId(params);

        const max_results: usize = blk: {
            const p = params orelse break :blk 10;
            switch (p) {
                .object => |obj| {
                    const v = obj.get("max_results") orelse break :blk 10;
                    switch (v) {
                        .integer => |i| break :blk @intCast(@max(i, 1)),
                        else => break :blk 10,
                    }
                },
                else => break :blk 10,
            }
        };

        const results = try graph_query.findDependents(g, id, max_results, self.alloc);
        defer self.alloc.free(results);
        return formatDependentResults(self.alloc, results);
    }

    // ── Public query methods ────────────────────────────────────────────

    /// Query for symbols at a given file path and line number.
    /// Returns JSON response string. Caller owns the returned memory.
    pub fn querySymbolAt(self: *Harness, file_path: []const u8, line: u32) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.alloc);

        try buf.appendSlice(self.alloc, "{\"method\":\"symbol_at\",\"params\":{\"file\":\"");
        try appendEscaped(&buf, self.alloc, file_path);
        try buf.appendSlice(self.alloc, "\",\"line\":");
        var line_buf: [20]u8 = undefined;
        const line_s = try std.fmt.bufPrint(&line_buf, "{d}", .{line});
        try buf.appendSlice(self.alloc, line_s);
        try buf.appendSlice(self.alloc, "}}");

        return self.executeQuery(buf.items);
    }

    /// Query for callers of a symbol. Returns JSON response string.
    /// Caller owns the returned memory.
    pub fn queryCallers(self: *Harness, symbol_id: u64) ![]u8 {
        return self.queryById("find_callers", symbol_id);
    }

    /// Query for callees of a symbol. Returns JSON response string.
    /// Caller owns the returned memory.
    pub fn queryCallees(self: *Harness, symbol_id: u64) ![]u8 {
        return self.queryById("find_callees", symbol_id);
    }

    /// Query for dependents of a symbol. Returns JSON response string.
    /// Caller owns the returned memory.
    pub fn queryDependents(self: *Harness, symbol_id: u64) ![]u8 {
        return self.queryById("find_dependents", symbol_id);
    }

    /// Build and execute a query by symbol ID.
    fn queryById(self: *Harness, method: []const u8, symbol_id: u64) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.alloc);

        try buf.appendSlice(self.alloc, "{\"method\":\"");
        try buf.appendSlice(self.alloc, method);
        try buf.appendSlice(self.alloc, "\",\"params\":{\"symbol_id\":");
        var id_buf: [20]u8 = undefined;
        const id_s = try std.fmt.bufPrint(&id_buf, "{d}", .{symbol_id});
        try buf.appendSlice(self.alloc, id_s);
        try buf.appendSlice(self.alloc, "}}");

        return self.executeQuery(buf.items);
    }

    /// Return the current query mode.
    pub fn getMode(self: *const Harness) QueryMode {
        return self.mode;
    }
};

// ── Helpers ─────────────────────────────────────────────────────────────────

fn extractSymbolId(params: ?std.json.Value) !u64 {
    const p = params orelse return error.MissingParams;
    const obj = switch (p) {
        .object => |o| o,
        else => return error.MissingParams,
    };
    const val = obj.get("symbol_id") orelse return error.MissingParams;
    return switch (val) {
        .integer => |i| @intCast(@max(i, 0)),
        else => return error.MissingParams,
    };
}

fn appendEscaped(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(alloc, "\\\""),
            '\\' => try buf.appendSlice(alloc, "\\\\"),
            '\n' => try buf.appendSlice(alloc, "\\n"),
            '\r' => try buf.appendSlice(alloc, "\\r"),
            '\t' => try buf.appendSlice(alloc, "\\t"),
            else => try buf.append(alloc, c),
        }
    }
}

fn formatSymbolResults(alloc: std.mem.Allocator, results: []const graph_query.SymbolResult) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    try buf.appendSlice(alloc, "{\"symbols\":[");
    for (results, 0..) |r, i| {
        if (i > 0) try buf.appendSlice(alloc, ",");
        try appendSymbolJson(&buf, alloc, r);
    }
    try buf.appendSlice(alloc, "]}");

    return alloc.dupe(u8, buf.items);
}

fn formatCallerResults(alloc: std.mem.Allocator, results: []const graph_query.CallerResult) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    try buf.appendSlice(alloc, "{\"results\":[");
    for (results, 0..) |r, i| {
        if (i > 0) try buf.appendSlice(alloc, ",");
        try appendSymbolJson(&buf, alloc, r.symbol);
        // Replace trailing } with edge info
        _ = buf.pop();
        try buf.appendSlice(alloc, ",\"edge_kind\":\"");
        try buf.appendSlice(alloc, @tagName(r.edge_kind));
        try buf.appendSlice(alloc, "\",\"weight\":");
        var wt_buf: [32]u8 = undefined;
        const wt_s = try std.fmt.bufPrint(&wt_buf, "{d:.4}", .{r.weight});
        try buf.appendSlice(alloc, wt_s);
        try buf.appendSlice(alloc, "}");
    }
    try buf.appendSlice(alloc, "]}");

    return alloc.dupe(u8, buf.items);
}

fn formatDependentResults(alloc: std.mem.Allocator, results: []const ppr_mod.ScoredNode) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    try buf.appendSlice(alloc, "{\"dependents\":[");
    for (results, 0..) |r, i| {
        if (i > 0) try buf.appendSlice(alloc, ",");
        try buf.appendSlice(alloc, "{\"id\":");
        var id_buf: [20]u8 = undefined;
        const id_s = try std.fmt.bufPrint(&id_buf, "{d}", .{r.id});
        try buf.appendSlice(alloc, id_s);
        try buf.appendSlice(alloc, ",\"score\":");
        var score_buf: [32]u8 = undefined;
        const score_s = try std.fmt.bufPrint(&score_buf, "{d:.6}", .{r.score});
        try buf.appendSlice(alloc, score_s);
        try buf.appendSlice(alloc, "}");
    }
    try buf.appendSlice(alloc, "]}");

    return alloc.dupe(u8, buf.items);
}

fn appendSymbolJson(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, r: graph_query.SymbolResult) !void {
    try buf.appendSlice(alloc, "{\"id\":");
    var num_buf: [20]u8 = undefined;
    const id_s = try std.fmt.bufPrint(&num_buf, "{d}", .{r.id});
    try buf.appendSlice(alloc, id_s);
    try buf.appendSlice(alloc, ",\"name\":\"");
    try appendEscaped(buf, alloc, r.name);
    try buf.appendSlice(alloc, "\",\"kind\":\"");
    try buf.appendSlice(alloc, @tagName(r.kind));
    try buf.appendSlice(alloc, "\",\"file\":\"");
    try appendEscaped(buf, alloc, r.file_path);
    try buf.appendSlice(alloc, "\",\"line\":");
    const line_s = try std.fmt.bufPrint(&num_buf, "{d}", .{r.line});
    try buf.appendSlice(alloc, line_s);
    try buf.appendSlice(alloc, ",\"col\":");
    const col_s = try std.fmt.bufPrint(&num_buf, "{d}", .{r.col});
    try buf.appendSlice(alloc, col_s);
    try buf.appendSlice(alloc, ",\"scope\":\"");
    try appendEscaped(buf, alloc, r.scope);
    try buf.appendSlice(alloc, "\"}");
}

// ── Tests ───────────────────────────────────────────────────────────────────

test "init defaults to local mode when no daemon" {
    var h = Harness.init(std.testing.allocator);
    defer h.deinit();

    try std.testing.expectEqual(QueryMode.local, h.getMode());
    try std.testing.expect(h.socket_fd == null);
}

test "initWithPaths defaults to local for nonexistent socket" {
    var h = Harness.initWithPaths(
        std.testing.allocator,
        "nonexistent/graph.bin",
        "nonexistent/daemon.sock",
    );
    defer h.deinit();

    try std.testing.expectEqual(QueryMode.local, h.getMode());
}

test "detectMode returns local when socket does not exist" {
    var h = Harness{
        .mode = .local,
        .socket_fd = null,
        .graph_path = GRAPH_PATH,
        .socket_path = DAEMON_SOCKET_PATH,
        .alloc = std.testing.allocator,
    };
    defer h.deinit();

    const mode = h.detectMode("nonexistent/daemon.sock");
    try std.testing.expectEqual(QueryMode.local, mode);
}

test "fallbackToLocal switches mode" {
    var h = Harness{
        .mode = .daemon,
        .socket_fd = null,
        .graph_path = GRAPH_PATH,
        .socket_path = DAEMON_SOCKET_PATH,
        .alloc = std.testing.allocator,
    };

    h.fallbackToLocal();
    try std.testing.expectEqual(QueryMode.local, h.mode);
    try std.testing.expect(h.socket_fd == null);
}

test "extractSymbolId parses valid params" {
    const json_str = "{\"symbol_id\":42}";
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        json_str,
        .{},
    );
    defer parsed.deinit();

    const id = try extractSymbolId(parsed.value);
    try std.testing.expectEqual(@as(u64, 42), id);
}

test "extractSymbolId returns error for missing params" {
    try std.testing.expectError(error.MissingParams, extractSymbolId(null));
}

test "appendEscaped handles special characters" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try appendEscaped(&buf, std.testing.allocator, "hello \"world\"\nnewline\\slash");
    try std.testing.expectEqualStrings("hello \\\"world\\\"\\nnewline\\\\slash", buf.items);
}

test "formatSymbolResults produces valid JSON for empty results" {
    const results: []const graph_query.SymbolResult = &.{};
    const json = try formatSymbolResults(std.testing.allocator, results);
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings("{\"symbols\":[]}", json);
}

test "formatCallerResults produces valid JSON for empty results" {
    const results: []const graph_query.CallerResult = &.{};
    const json = try formatCallerResults(std.testing.allocator, results);
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings("{\"results\":[]}", json);
}

test "formatDependentResults produces valid JSON for empty results" {
    const results: []const ppr_mod.ScoredNode = &.{};
    const json = try formatDependentResults(std.testing.allocator, results);
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings("{\"dependents\":[]}", json);
}

test "querySymbolAt returns error when no graph file" {
    var h = Harness{
        .mode = .local,
        .socket_fd = null,
        .graph_path = "nonexistent/graph.bin",
        .socket_path = DAEMON_SOCKET_PATH,
        .alloc = std.testing.allocator,
    };
    defer h.deinit();

    const result = h.querySymbolAt("src/main.zig", 1);
    try std.testing.expectError(error.GraphNotFound, result);
}

test "queryCallers returns error when no graph file" {
    var h = Harness{
        .mode = .local,
        .socket_fd = null,
        .graph_path = "nonexistent/graph.bin",
        .socket_path = DAEMON_SOCKET_PATH,
        .alloc = std.testing.allocator,
    };
    defer h.deinit();

    const result = h.queryCallers(42);
    try std.testing.expectError(error.GraphNotFound, result);
}

test "queryCallees returns error when no graph file" {
    var h = Harness{
        .mode = .local,
        .socket_fd = null,
        .graph_path = "nonexistent/graph.bin",
        .socket_path = DAEMON_SOCKET_PATH,
        .alloc = std.testing.allocator,
    };
    defer h.deinit();

    const result = h.queryCallees(42);
    try std.testing.expectError(error.GraphNotFound, result);
}

test "queryDependents returns error when no graph file" {
    var h = Harness{
        .mode = .local,
        .socket_fd = null,
        .graph_path = "nonexistent/graph.bin",
        .socket_path = DAEMON_SOCKET_PATH,
        .alloc = std.testing.allocator,
    };
    defer h.deinit();

    const result = h.queryDependents(42);
    try std.testing.expectError(error.GraphNotFound, result);
}

test "local query with in-memory graph via dispatchLocal" {
    // Build a test graph, serialize it, then load via harness dispatch
    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();

    try g.addFile(.{ .id = 1, .path = "src/main.ts", .language = .typescript, .last_modified = 0, .hash = [_]u8{0} ** 32 });
    try g.addSymbol(.{ .id = 10, .name = "main", .kind = .function, .file_id = 1, .line = 1, .col = 0, .scope = "" });
    try g.addSymbol(.{ .id = 20, .name = "handleRequest", .kind = .function, .file_id = 1, .line = 10, .col = 0, .scope = "" });
    try g.addEdge(.{ .src = 10, .dst = 20, .kind = .calls, .weight = 2.0 });

    var h = Harness{
        .mode = .local,
        .socket_fd = null,
        .graph_path = GRAPH_PATH,
        .socket_path = DAEMON_SOCKET_PATH,
        .alloc = std.testing.allocator,
    };
    defer h.deinit();

    // Test symbol_at dispatch
    const sym_result = try h.dispatchLocal(&g, "{\"method\":\"symbol_at\",\"params\":{\"file\":\"src/main.ts\",\"line\":10}}");
    defer std.testing.allocator.free(sym_result);
    // Should contain the symbol name
    try std.testing.expect(std.mem.indexOf(u8, sym_result, "handleRequest") != null);

    // Test find_callers dispatch
    const callers_result = try h.dispatchLocal(&g, "{\"method\":\"find_callers\",\"params\":{\"symbol_id\":20}}");
    defer std.testing.allocator.free(callers_result);
    try std.testing.expect(std.mem.indexOf(u8, callers_result, "main") != null);

    // Test find_callees dispatch
    const callees_result = try h.dispatchLocal(&g, "{\"method\":\"find_callees\",\"params\":{\"symbol_id\":10}}");
    defer std.testing.allocator.free(callees_result);
    try std.testing.expect(std.mem.indexOf(u8, callees_result, "handleRequest") != null);

    // Test ping
    const ping_result = try h.dispatchLocal(&g, "{\"method\":\"ping\",\"params\":{}}");
    defer std.testing.allocator.free(ping_result);
    try std.testing.expectEqualStrings("{\"status\":\"ok\",\"mode\":\"local\"}", ping_result);
}

test "dispatchLocal returns error for invalid JSON" {
    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();

    var h = Harness{
        .mode = .local,
        .socket_fd = null,
        .graph_path = GRAPH_PATH,
        .socket_path = DAEMON_SOCKET_PATH,
        .alloc = std.testing.allocator,
    };
    defer h.deinit();

    const result = h.dispatchLocal(&g, "not valid json");
    try std.testing.expectError(error.InvalidRequest, result);
}

test "dispatchLocal returns error for unknown method" {
    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();

    var h = Harness{
        .mode = .local,
        .socket_fd = null,
        .graph_path = GRAPH_PATH,
        .socket_path = DAEMON_SOCKET_PATH,
        .alloc = std.testing.allocator,
    };
    defer h.deinit();

    const result = h.dispatchLocal(&g, "{\"method\":\"unknown_method\",\"params\":{}}");
    try std.testing.expectError(error.UnknownMethod, result);
}

test "getMode returns current mode" {
    const h = Harness{
        .mode = .local,
        .socket_fd = null,
        .graph_path = GRAPH_PATH,
        .socket_path = DAEMON_SOCKET_PATH,
        .alloc = std.testing.allocator,
    };

    try std.testing.expectEqual(QueryMode.local, h.getMode());
}

// ── Edge case tests ─────────────────────────────────────────────────────────

test "dispatchLocal with missing params returns MissingParams" {
    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();

    var h = Harness{
        .mode = .local,
        .socket_fd = null,
        .graph_path = GRAPH_PATH,
        .socket_path = DAEMON_SOCKET_PATH,
        .alloc = std.testing.allocator,
    };
    defer h.deinit();

    // symbol_at without params
    const result1 = h.dispatchLocal(&g, "{\"method\":\"symbol_at\"}");
    try std.testing.expectError(error.MissingParams, result1);

    // find_callers without symbol_id
    const result2 = h.dispatchLocal(&g, "{\"method\":\"find_callers\",\"params\":{}}");
    try std.testing.expectError(error.MissingParams, result2);

    // find_callees without symbol_id
    const result3 = h.dispatchLocal(&g, "{\"method\":\"find_callees\",\"params\":{}}");
    try std.testing.expectError(error.MissingParams, result3);

    // find_dependents without symbol_id
    const result4 = h.dispatchLocal(&g, "{\"method\":\"find_dependents\",\"params\":{}}");
    try std.testing.expectError(error.MissingParams, result4);
}

test "dispatchLocal shutdown returns ShutdownRequested" {
    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();

    var h = Harness{
        .mode = .local,
        .socket_fd = null,
        .graph_path = GRAPH_PATH,
        .socket_path = DAEMON_SOCKET_PATH,
        .alloc = std.testing.allocator,
    };
    defer h.deinit();

    const result = h.dispatchLocal(&g, "{\"method\":\"shutdown\",\"params\":{}}");
    try std.testing.expectError(error.ShutdownRequested, result);
}

test "dispatchLocal with empty JSON object returns InvalidRequest" {
    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();

    var h = Harness{
        .mode = .local,
        .socket_fd = null,
        .graph_path = GRAPH_PATH,
        .socket_path = DAEMON_SOCKET_PATH,
        .alloc = std.testing.allocator,
    };
    defer h.deinit();

    // No "method" key
    const result = h.dispatchLocal(&g, "{}");
    try std.testing.expectError(error.InvalidRequest, result);
}

test "dispatchLocal with array JSON returns InvalidRequest" {
    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();

    var h = Harness{
        .mode = .local,
        .socket_fd = null,
        .graph_path = GRAPH_PATH,
        .socket_path = DAEMON_SOCKET_PATH,
        .alloc = std.testing.allocator,
    };
    defer h.deinit();

    const result = h.dispatchLocal(&g, "[1,2,3]");
    try std.testing.expectError(error.InvalidRequest, result);
}

test "dispatchLocal symbol_at on empty graph returns empty symbols" {
    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();

    var h = Harness{
        .mode = .local,
        .socket_fd = null,
        .graph_path = GRAPH_PATH,
        .socket_path = DAEMON_SOCKET_PATH,
        .alloc = std.testing.allocator,
    };
    defer h.deinit();

    const result = try h.dispatchLocal(&g, "{\"method\":\"symbol_at\",\"params\":{\"file\":\"anything.ts\",\"line\":1}}");
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("{\"symbols\":[]}", result);
}

test "dispatchLocal find_callers on empty graph returns empty results" {
    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();

    var h = Harness{
        .mode = .local,
        .socket_fd = null,
        .graph_path = GRAPH_PATH,
        .socket_path = DAEMON_SOCKET_PATH,
        .alloc = std.testing.allocator,
    };
    defer h.deinit();

    const result = try h.dispatchLocal(&g, "{\"method\":\"find_callers\",\"params\":{\"symbol_id\":999}}");
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("{\"results\":[]}", result);
}

test "dispatchLocal find_callees on empty graph returns empty results" {
    var g = CodeGraph.init(std.testing.allocator);
    defer g.deinit();

    var h = Harness{
        .mode = .local,
        .socket_fd = null,
        .graph_path = GRAPH_PATH,
        .socket_path = DAEMON_SOCKET_PATH,
        .alloc = std.testing.allocator,
    };
    defer h.deinit();

    const result = try h.dispatchLocal(&g, "{\"method\":\"find_callees\",\"params\":{\"symbol_id\":999}}");
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("{\"results\":[]}", result);
}

test "mode detection with nonexistent socket path defaults to local" {
    var h = Harness{
        .mode = .daemon,
        .socket_fd = null,
        .graph_path = GRAPH_PATH,
        .socket_path = DAEMON_SOCKET_PATH,
        .alloc = std.testing.allocator,
    };
    defer h.deinit();

    const mode = h.detectMode("/tmp/definitely_nonexistent_socket_path_12345.sock");
    try std.testing.expectEqual(QueryMode.local, mode);
}

test "fallbackToLocal from daemon with null socket_fd" {
    var h = Harness{
        .mode = .daemon,
        .socket_fd = null,
        .graph_path = GRAPH_PATH,
        .socket_path = DAEMON_SOCKET_PATH,
        .alloc = std.testing.allocator,
    };

    h.fallbackToLocal();
    try std.testing.expectEqual(QueryMode.local, h.mode);
    try std.testing.expect(h.socket_fd == null);
}

test "appendEscaped with empty string" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try appendEscaped(&buf, std.testing.allocator, "");
    try std.testing.expectEqual(@as(usize, 0), buf.items.len);
}

test "appendEscaped with tab and carriage return" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try appendEscaped(&buf, std.testing.allocator, "\t\r");
    try std.testing.expectEqualStrings("\\t\\r", buf.items);
}

test "formatSymbolResults with multiple results produces valid JSON" {
    const results = &[_]graph_query.SymbolResult{
        .{ .id = 1, .name = "foo", .kind = .function, .file_path = "a.ts", .line = 1, .col = 0, .scope = "" },
        .{ .id = 2, .name = "bar", .kind = .method, .file_path = "b.ts", .line = 5, .col = 3, .scope = "Cls" },
    };
    const json = try formatSymbolResults(std.testing.allocator, results);
    defer std.testing.allocator.free(json);

    // Should be valid JSON with two entries
    try std.testing.expect(std.mem.indexOf(u8, json, "\"foo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"bar\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"symbols\":[") != null);
}

test "extractSymbolId with non-object params returns MissingParams" {
    const json_str = "\"just_a_string\"";
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        json_str,
        .{},
    );
    defer parsed.deinit();

    try std.testing.expectError(error.MissingParams, extractSymbolId(parsed.value));
}

test "extractSymbolId with non-integer symbol_id returns MissingParams" {
    const json_str = "{\"symbol_id\":\"not_a_number\"}";
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        json_str,
        .{},
    );
    defer parsed.deinit();

    try std.testing.expectError(error.MissingParams, extractSymbolId(parsed.value));
}
