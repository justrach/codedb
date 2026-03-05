// mcp-zig — Client example
//
// Spawns the mcp-zig server and calls its read_file tool.
//
// Usage: zig build run-client -- /path/to/mcp-zig
//        or:  zig-out/bin/mcp-client /path/to/server

const std = @import("std");
const McpClient = @import("client.zig").McpClient;

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    if (args.len < 2) {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        stderr.print(
            \\mcp-client — MCP client example
            \\
            \\Usage: mcp-client <server-path> [tool-name] [args-json]
            \\
            \\Examples:
            \\  mcp-client ./zig-out/bin/mcp-zig
            \\  mcp-client ./zig-out/bin/mcp-zig read_file '{{"path":"README.md"}}'
            \\
        , .{}) catch {};
        return;
    }

    const server_path = args[1];
    const tool_name = if (args.len > 2) args[2] else null;
    const tool_args = if (args.len > 3) args[3] else "{}";

    const stdout = std.fs.File.stdout().deprecatedWriter();

    // Spawn server
    var client = try McpClient.init(alloc, &.{server_path}, null);
    defer client.deinit();

    // Initialize
    stdout.print("→ initialize\n", .{}) catch {};
    const init_result = try client.initialize();
    defer alloc.free(init_result);
    stdout.print("← {s}\n\n", .{init_result}) catch {};

    try client.notifyInitialized();

    // List tools
    stdout.print("→ tools/list\n", .{}) catch {};
    const tools_result = try client.listTools();
    defer alloc.free(tools_result);
    stdout.print("← {s}\n\n", .{tools_result}) catch {};

    // Call tool (if specified)
    if (tool_name) |name| {
        stdout.print("→ tools/call: {s}({s})\n", .{ name, tool_args }) catch {};
        const call_result = try client.callTool(name, tool_args);
        defer alloc.free(call_result);
        stdout.print("← {s}\n", .{call_result}) catch {};
    }

    // Ping
    stdout.print("\n→ ping\n", .{}) catch {};
    const alive = try client.ping();
    stdout.print("← pong: {}\n", .{alive}) catch {};
}
