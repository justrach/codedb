//! MCP handler for `codedb_list_dir`. Wired from `mcp.zig` (see
//! `patches/696-mcp-list-dir.patch`) so the 317KB server file stays a
//! 17-line hook.
const std = @import("std");
const list_dir = @import("list_dir.zig");
const Explorer = @import("explore.zig").Explorer;

pub const tool_json =
    \\{"name":"codedb_list_dir","description":"Live BFS directory listing of the filesystem (not the index): honors .gitignore, 10k-character cap, collapsed subtree summaries. Use for any folder including unindexed trees; codedb_ls is indexed children of one directory.","inputSchema":{"type":"object","properties":{"path":{"type":"string","description":"Directory relative to project root. Omit for the project root."},"project":{"type":"string","description":"Optional absolute path to a different project"}},"required":[]}}
;

pub fn handle(io: std.Io, alloc: std.mem.Allocator, path: []const u8, explorer: *Explorer, out: *std.ArrayList(u8)) void {
    const root_dir = explorer.root_dir orelse {
        out.appendSlice(alloc, "error: project root is not configured") catch {};
        return;
    };
    const project_root = explorer.root_path orelse {
        out.appendSlice(alloc, "error: project root is not configured") catch {};
        return;
    };
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const text = list_dir.listUnderRoot(io, arena_state.allocator(), root_dir, project_root, path) catch |err| {
        out.appendSlice(alloc, list_dir.errorText(err)) catch {};
        return;
    };
    out.appendSlice(alloc, text) catch {};
}
