// mcp-zig — MCP client (JSON-RPC 2.0 over stdio to a child process)
//
// Spawns an MCP server as a child process and communicates via stdin/stdout.
// Handles the full lifecycle: initialize → tools/list → tools/call → exit.
//
// Usage:
//   var client = try McpClient.init(alloc, &.{"/path/to/server"}, null);
//   defer client.deinit();
//   try client.initialize();
//   const tools = try client.listTools();
//   const result = try client.callTool("read_file", "{\"path\":\"hello.txt\"}");

const std = @import("std");
const json = @import("json.zig");

pub const McpClient = struct {
    alloc: std.mem.Allocator,
    process: std.process.Child,
    next_id: i64,

    pub fn init(
        alloc: std.mem.Allocator,
        argv: []const []const u8,
        cwd: ?[]const u8,
    ) !McpClient {
        var child = std.process.Child.init(argv, alloc);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        if (cwd) |d| child.cwd = d;
        try child.spawn();
        return .{
            .alloc = alloc,
            .process = child,
            .next_id = 1,
        };
    }

    pub fn deinit(self: *McpClient) void {
        // Close stdin first to signal the server to exit, then wait.
        // Don't close stdout/stderr manually — process.wait() handles cleanup.
        if (self.process.stdin) |*s| {
            s.close();
            self.process.stdin = null;
        }
        _ = self.process.wait() catch {};
    }

    // ── High-level API ──────────────────────────────────────────────────────

    /// Send initialize and wait for response. Returns server info as raw JSON string.
    pub fn initialize(self: *McpClient) ![]u8 {
        const req =
            \\{"jsonrpc":"2.0","id":__ID__,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"mcp-zig-client","version":"1.0.0"}}}
        ;
        return self.sendAndReceive(req);
    }

    /// Send notifications/initialized (no response expected).
    pub fn notifyInitialized(self: *McpClient) !void {
        const msg = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n";
        const stdin = self.process.stdin orelse return error.StdinClosed;
        _ = try stdin.write(msg);
    }

    /// List available tools. Returns raw JSON result string.
    pub fn listTools(self: *McpClient) ![]u8 {
        const req =
            \\{"jsonrpc":"2.0","id":__ID__,"method":"tools/list","params":{}}
        ;
        return self.sendAndReceive(req);
    }

    /// Call a tool by name with JSON arguments string. Returns the tool result text.
    pub fn callTool(self: *McpClient, name: []const u8, args_json: []const u8) ![]u8 {
        // Build request manually to avoid dynamic JSON construction overhead
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.alloc);

        buf.appendSlice(self.alloc, "{\"jsonrpc\":\"2.0\",\"id\":") catch return error.OutOfMemory;
        var id_buf: [20]u8 = undefined;
        const id = self.next_id;
        self.next_id += 1;
        const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{id}) catch return error.OutOfMemory;
        buf.appendSlice(self.alloc, id_str) catch return error.OutOfMemory;
        buf.appendSlice(self.alloc, ",\"method\":\"tools/call\",\"params\":{\"name\":\"") catch return error.OutOfMemory;
        json.writeEscaped(self.alloc, &buf, name);
        buf.appendSlice(self.alloc, "\",\"arguments\":") catch return error.OutOfMemory;
        buf.appendSlice(self.alloc, args_json) catch return error.OutOfMemory;
        buf.appendSlice(self.alloc, "}}\n") catch return error.OutOfMemory;

        const stdin = self.process.stdin orelse return error.StdinClosed;
        _ = try stdin.write(buf.items);

        return self.readResponse();
    }

    /// Send a ping and wait for pong. Returns true if server responds.
    pub fn ping(self: *McpClient) !bool {
        const result = self.sendAndReceive(
            \\{"jsonrpc":"2.0","id":__ID__,"method":"ping","params":{}}
        ) catch return false;
        self.alloc.free(result);
        return true;
    }

    // ── Low-level helpers ────────────────────────────────────────────────────

    fn sendAndReceive(self: *McpClient, template: []const u8) ![]u8 {
        // Replace __ID__ with actual ID
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.alloc);

        const id = self.next_id;
        self.next_id += 1;
        var id_buf: [20]u8 = undefined;
        const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{id}) catch return error.OutOfMemory;

        // Find and replace __ID__
        var i: usize = 0;
        while (i < template.len) {
            if (i + 6 <= template.len and std.mem.eql(u8, template[i .. i + 6], "__ID__")) {
                buf.appendSlice(self.alloc, id_str) catch return error.OutOfMemory;
                i += 6;
            } else {
                buf.append(self.alloc, template[i]) catch return error.OutOfMemory;
                i += 1;
            }
        }
        buf.append(self.alloc, '\n') catch return error.OutOfMemory;

        const stdin = self.process.stdin orelse return error.StdinClosed;
        _ = try stdin.write(buf.items);

        return self.readResponse();
    }

    fn readResponse(self: *McpClient) ![]u8 {
        const stdout = self.process.stdout orelse return error.StdoutClosed;
        const stdout_file = stdout;

        // Read one line (JSON-RPC response)
        var line: std.ArrayList(u8) = .empty;
        var byte_buf: [1]u8 = undefined;
        while (true) {
            const n = try stdout_file.read(&byte_buf);
            if (n == 0) {
                line.deinit(self.alloc);
                return error.ServerClosed;
            }
            if (byte_buf[0] == '\n') break;
            line.append(self.alloc, byte_buf[0]) catch {
                line.deinit(self.alloc);
                return error.OutOfMemory;
            };
            if (line.items.len > json.MAX_LINE) {
                line.deinit(self.alloc);
                return error.ResponseTooLarge;
            }
        }

        return line.toOwnedSlice(self.alloc) catch {
            line.deinit(self.alloc);
            return error.OutOfMemory;
        };
    }
};

// ── Convenience: run a one-shot tool call ────────────────────────────────────

/// Spawn server, initialize, call one tool, return result, clean up.
/// Convenience for scripts that just need a single tool call.
pub fn callOnce(
    alloc: std.mem.Allocator,
    server_argv: []const []const u8,
    tool_name: []const u8,
    args_json: []const u8,
) ![]u8 {
    var client = try McpClient.init(alloc, server_argv, null);
    defer client.deinit();

    const init_result = try client.initialize();
    alloc.free(init_result);
    try client.notifyInitialized();

    return client.callTool(tool_name, args_json);
}
