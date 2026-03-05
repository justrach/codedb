const std = @import("std");
const graph = @import("src/graph/graph.zig");

pub fn main() !void {
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        var failing = std.testing.FailingAllocator.init(std.heap.page_allocator, .{ .fail_index = i });
        var g = graph.CodeGraph.init(failing.allocator());
        defer g.deinit();

        const res = g.addEdge(.{ .src = 1, .dst = 2, .kind = .calls, .weight = 1.0 });
        if (res) |_| {
            continue;
        } else |err| switch (err) {
            error.OutOfMemory => {
                const out_len = g.outEdges(1).len;
                const in_len = g.inEdges(2).len;
                if (out_len != in_len) {
                    std.debug.print("INCONSISTENT fail_index={d} out={d} in={d}\n", .{ i, out_len, in_len });
                    return;
                }
            },
            else => return err,
        }
    }
    std.debug.print("NO_INCONSISTENCY\n", .{});
}
