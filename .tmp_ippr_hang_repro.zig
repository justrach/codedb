const std = @import("std");
const graph_mod = @import("src/graph/graph.zig");
const ippr_mod = @import("src/graph/ppr_incremental.zig");

pub fn main() !void {
    var g = graph_mod.CodeGraph.init(std.heap.page_allocator);
    defer g.deinit();
    try g.addEdge(.{ .src = 1, .dst = 1, .kind = .calls, .weight = 1.0 });

    var ippr = ippr_mod.IncrementalPpr.init(std.heap.page_allocator);
    defer ippr.deinit();
    ippr.alpha = 0.0;
    try ippr.residuals.put(1, 1.0);
    try ippr.deltaUpdate(&g);
    std.debug.print("done\n", .{});
}
