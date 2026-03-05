const std = @import("std");
const graph_mod = @import("src/graph/graph.zig");
const ppr = @import("src/graph/ppr.zig");

test "nan edge weight silently blocks propagation" {
    var g = graph_mod.CodeGraph.init(std.testing.allocator);
    defer g.deinit();

    try g.addEdge(.{ .src = 1, .dst = 2, .kind = .calls, .weight = std.math.nan(f32) });
    var scores = try ppr.pprPush(&g, 1, ppr.DEFAULT_ALPHA, ppr.DEFAULT_EPSILON, std.testing.allocator);
    defer scores.deinit();

    const s1 = scores.get(1) orelse 0;
    const s2 = scores.get(2) orelse 0;
    std.debug.print("s1={d}, s2={d}\n", .{ s1, s2 });
    try std.testing.expectApproxEqAbs(@as(f32, ppr.DEFAULT_ALPHA), s1, 1e-4);
    try std.testing.expectEqual(@as(f32, 0.0), s2);
}
