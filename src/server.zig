// codedb HTTP server — DISABLED on 0.16 migration (issue #285).
//
// The legacy HTTP port server (`codedb serve --port`) used std.net which was
// removed in 0.16. MCP stdio mode is the primary entry, so this port is kept
// as a stub that returns an error. When 0.16's std.Io.net stabilizes enough
// to rebuild this, restore from `git show 0.2.578~0:src/server.zig`.

const std = @import("std");
const Store = @import("store.zig").Store;
const AgentRegistry = @import("agent.zig").AgentRegistry;
const Explorer = @import("explore.zig").Explorer;
const watcher = @import("watcher.zig");

pub fn serve(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: *Store,
    agents: *AgentRegistry,
    explorer: *Explorer,
    queue: *watcher.EventQueue,
    port: u16,
) !void {
    _ = io;
    _ = allocator;
    _ = store;
    _ = agents;
    _ = explorer;
    _ = queue;
    _ = port;
    return error.ServerDisabledOn016;
}
