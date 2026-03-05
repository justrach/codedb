const std = @import("std");
const graph = @import("src/graph/graph.zig");
const ppr = @import("src/graph/ppr.zig");

pub fn main() !void {
    var g = graph.CodeGraph.init(std.heap.page_allocator);
    defer g.deinit();

    try g.addEdge(.{ .src = 1, .dst = 2, .kind = .calls, .weight = 2.0 });
    try g.addEdge(.{ .src = 1, .dst = 3, .kind = .calls, .weight = -1.0 });

    var scores = try ppr.pprPush(&g, 1, ppr.DEFAULT_ALPHA, ppr.DEFAULT_EPSILON, std.heap.page_allocator);
    defer scores.deinit();

    std.debug.print("s1={d:.6} s2={d:.6} s3={d:.6}\n", .{ scores.get(1) orelse 0, scores.get(2) orelse 0, scores.get(3) orelse 0 });
}
