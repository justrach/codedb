//! MCP handler for `codedb_list_dir`. Wired from `mcp.zig` (see
//! `patches/696-mcp-list-dir.patch`) so the 317KB server file stays a
//! 17-line hook.
const std = @import("std");
const list_dir = @import("list_dir.zig");

pub const tool_json =
    \\{"name":"codedb_list_dir","description":"Live BFS directory listing of the filesystem (not the index): honors .gitignore, 10k-character cap, collapsed subtree summaries. Use for any folder including unindexed trees; codedb_ls is indexed children of one directory.","inputSchema":{"type":"object","properties":{"path":{"type":"string","description":"Directory relative to project root. Omit for the project root."},"project":{"type":"string","description":"Optional absolute path to a different project"}},"required":[]}}
;

pub fn handle(io: std.Io, alloc: std.mem.Allocator, path: []const u8, project_root: []const u8, out: *std.ArrayList(u8)) void {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const text = list_dir.listUnder(io, arena_state.allocator(), project_root, path) catch |err| {
        out.appendSlice(alloc, list_dir.errorText(err)) catch {};
        return;
    };
    out.appendSlice(alloc, text) catch {};
}
