const std = @import("std");
const graph = @import("src/graph/graph.zig");

pub fn main() !void {
    var fail_index: usize = 0;
    while (fail_index < 64) : (fail_index += 1) {
        var fa = std.testing.FailingAllocator.init(std.heap.page_allocator, .{ .fail_index = fail_index });
        var g = graph.CodeGraph.init(fa.allocator());
        defer g.deinit();

        if (g.addEdge(.{ .src = 1, .dst = 2, .kind = .calls, .weight = 1.0 })) |_| {
            continue;
        } else |_| {
            const out_len = g.outEdges(1).len;
            const in_len = g.inEdges(2).len;
            if (out_len != in_len) {
                std.debug.print("mismatch at fail_index={d}: out={d} in={d}\n", .{ fail_index, out_len, in_len });
                return;
            }
        }
    }
    std.debug.print("no mismatch\n", .{});
}
