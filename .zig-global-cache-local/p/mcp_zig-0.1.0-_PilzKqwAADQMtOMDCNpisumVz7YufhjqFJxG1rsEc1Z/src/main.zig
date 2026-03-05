// mcp-zig — entry point
//
// Runs the MCP server (JSON-RPC 2.0 over stdio).
// Register in ~/.claude.json:
//
//   "mcpServers": {
//     "my-server": {
//       "command": "/path/to/mcp-zig",
//       "args": []
//     }
//   }

const std = @import("std");
const mcp = @import("mcp.zig");

pub fn main() void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    mcp.run(gpa.allocator());
}
