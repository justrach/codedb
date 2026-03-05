const std = @import("std");
const graph = @import("src/graph/graph.zig");
const ppr = @import("src/graph/ppr.zig");

pub fn main() !void {
    var g = graph.CodeGraph.init(std.heap.page_allocator);
    defer g.deinit();
    try g.addEdge(.{ .src = 1, .dst = 2, .kind = .calls, .weight = 1.0 });
    try g.addEdge(.{ .src = 2, .dst = 1, .kind = .calls, .weight = 1.0 });
    var scores = try ppr.pprPush(&g, 1, 0.0, 1e-4, std.heap.page_allocator);
    defer scores.deinit();
    std.debug.print("count={d}\n", .{scores.count()});
}
