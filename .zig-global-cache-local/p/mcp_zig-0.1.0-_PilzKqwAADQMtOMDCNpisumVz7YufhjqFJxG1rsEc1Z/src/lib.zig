// mcp-zig — public API
//
// Import this module to use mcp-zig as a library:
//
//   const mcp = @import("mcp");
//   const McpClient = mcp.client.McpClient;
//   const Registry = mcp.registry.Registry;
//   const wrapFn = mcp.registry.wrapFn;

pub const mcp = @import("mcp.zig");
pub const json = @import("json.zig");
pub const registry = @import("registry.zig");
pub const client = @import("client.zig");
pub const tools = @import("tools.zig");
