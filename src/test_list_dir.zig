//! Reachability root for `list_dir` / `gitignore` so `zig build test` runs
//! those blocks without compiling the query/MCP suites.
test {
    _ = @import("list_dir.zig");
    _ = @import("gitignore.zig");
    _ = @import("mcp_list_dir.zig");
}
