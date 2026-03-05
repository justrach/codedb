const std = @import("std");
const graph = @import("src/graph/graph.zig");

pub fn main() !void {
    var idx: usize = 0;
    while (idx < 40) : (idx += 1) {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        var failing = std.testing.FailingAllocator.init(gpa.allocator(), .{ .fail_index = idx });
        var g = graph.CodeGraph.init(failing.allocator());
        defer g.deinit();

        g.addEdge(.{ .src = 1, .dst = 2, .kind = .calls }) catch |e| {
            if (e != error.OutOfMemory) return e;
            const out_len = g.outEdges(1).len;
            const in_len = g.inEdges(2).len;
            if (out_len != in_len) {
                std.debug.print("partial edge on fail_index={d}: out={d} in={d}\n", .{ idx, out_len, in_len });
                return;
            }
            continue;
        };
    }
    std.debug.print("no partial edge observed\n", .{});
}
