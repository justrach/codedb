const std = @import("std");
const graph_mod = @import("src/graph/graph.zig");
const ppr = @import("src/graph/ppr.zig");

pub fn main() !void {
    var g = graph_mod.CodeGraph.init(std.heap.page_allocator);
    defer g.deinit();
    try g.addEdge(.{ .src = 1, .dst = 1, .kind = .calls });
    var scores = try ppr.pprPush(&g, 1, 0.15, ppr.DEFAULT_EPSILON, std.heap.page_allocator);
    defer scores.deinit();
    std.debug.print("count={d}\n", .{scores.count()});
}
