const std = @import("std");
const Explorer = @import("explore.zig").Explorer;
const Store = @import("store.zig").Store;

pub fn buildSnapshot(explorer: *Explorer, store: *Store, alloc: std.mem.Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    const w = buf.writer(alloc);

    try w.writeAll("{");
    try w.print("\"seq\":{d},", .{store.currentSeq()});

    const tree = try explorer.getTree(alloc, false);
    defer alloc.free(tree);
    try w.writeAll("\"tree\":\"");
    try writeJsonEscaped(alloc, &buf, tree);
    try w.writeAll("\",");

    try w.writeAll("\"outlines\":{");
    {
        explorer.mu.lockShared();
        defer explorer.mu.unlockShared();

        var paths: std.ArrayList([]const u8) = .empty;
        defer paths.deinit(alloc);
        var iter = explorer.outlines.iterator();
        while (iter.next()) |entry| {
            try paths.append(alloc, entry.key_ptr.*);
        }
        std.mem.sort([]const u8, paths.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);

        for (paths.items, 0..) |path, pi| {
            if (pi > 0) try w.writeAll(",");
            try w.writeAll("\"");
            try writeJsonEscaped(alloc, &buf, path);
            try w.writeAll("\":{");

            const outline = explorer.outlines.get(path) orelse continue;
            try w.print("\"language\":\"{s}\",\"lines\":{d},\"bytes\":{d},\"symbols\":[", .{
                @tagName(outline.language), outline.line_count, outline.byte_size,
            });
            for (outline.symbols.items, 0..) |sym, si| {
                if (si > 0) try w.writeAll(",");
                try w.writeAll("{\"name\":\"");
                try writeJsonEscaped(alloc, &buf, sym.name);
                try w.print("\",\"kind\":\"{s}\",\"line_start\":{d},\"line_end\":{d}", .{
                    @tagName(sym.kind), sym.line_start, sym.line_end,
                });
                if (sym.detail) |d| {
                    try w.writeAll(",\"detail\":\"");
                    try writeJsonEscaped(alloc, &buf, d);
                    try w.writeAll("\"");
                }
                try w.writeAll("}");
            }
            try w.writeAll("],\"imports\":[");
            for (outline.imports.items, 0..) |imp, ii| {
                if (ii > 0) try w.writeAll(",");
                try w.writeAll("\"");
                try writeJsonEscaped(alloc, &buf, imp);
                try w.writeAll("\"");
            }
            try w.writeAll("]}");
        }
    }
    try w.writeAll("},");

    try w.writeAll("\"symbol_index\":{");
    {
        explorer.mu.lockShared();
        defer explorer.mu.unlockShared();

        var sym_map = std.StringHashMap(std.ArrayList(SymEntry)).init(alloc);
        defer {
            var si = sym_map.iterator();
            while (si.next()) |e| e.value_ptr.deinit(alloc);
            sym_map.deinit();
        }

        var oiter = explorer.outlines.iterator();
        while (oiter.next()) |entry| {
            for (entry.value_ptr.symbols.items) |sym| {
                const gop = try sym_map.getOrPut(sym.name);
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                try gop.value_ptr.append(alloc, .{
                    .path = entry.key_ptr.*,
                    .line = sym.line_start,
                    .kind = sym.kind,
                });
            }
        }

        var sym_keys: std.ArrayList([]const u8) = .empty;
        defer sym_keys.deinit(alloc);
        var ski = sym_map.iterator();
        while (ski.next()) |e| try sym_keys.append(alloc, e.key_ptr.*);
        std.mem.sort([]const u8, sym_keys.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);

        for (sym_keys.items, 0..) |name, ni| {
            if (ni > 0) try w.writeAll(",");
            try w.writeAll("\"");
            try writeJsonEscaped(alloc, &buf, name);
            try w.writeAll("\":[");
            const locs = sym_map.get(name) orelse continue;
            for (locs.items, 0..) |loc, li| {
                if (li > 0) try w.writeAll(",");
                try w.writeAll("{\"path\":\"");
                try writeJsonEscaped(alloc, &buf, loc.path);
                try w.print("\",\"line\":{d},\"kind\":\"{s}\"}}", .{
                    loc.line, @tagName(loc.kind),
                });
            }
            try w.writeAll("]");
        }
    }
    try w.writeAll("},");

    try w.writeAll("\"dep_graph\":{");
    {
        explorer.mu.lockShared();
        defer explorer.mu.unlockShared();

        var dep_keys: std.ArrayList([]const u8) = .empty;
        defer dep_keys.deinit(alloc);
        var diter = explorer.dep_graph.iterator();
        while (diter.next()) |e| try dep_keys.append(alloc, e.key_ptr.*);
        std.mem.sort([]const u8, dep_keys.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);

        for (dep_keys.items, 0..) |path, di| {
            if (di > 0) try w.writeAll(",");
            try w.writeAll("\"");
            try writeJsonEscaped(alloc, &buf, path);
            try w.writeAll("\":[");
            const deps = explorer.dep_graph.get(path) orelse continue;
            for (deps.items, 0..) |dep, dj| {
                if (dj > 0) try w.writeAll(",");
                try w.writeAll("\"");
                try writeJsonEscaped(alloc, &buf, dep);
                try w.writeAll("\"");
            }
            try w.writeAll("]");
        }
    }
    try w.writeAll("}}");

    return buf.toOwnedSlice(alloc);
}

const SymEntry = struct {
    path: []const u8,
    line: u32,
    kind: @import("explore.zig").SymbolKind,
};

fn writeJsonEscaped(alloc: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(alloc, "\\\""),
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            else => if (c < 0x20) {
                const hex = "0123456789abcdef";
                const esc = [6]u8{ '\\', 'u', '0', '0', hex[c >> 4], hex[c & 0x0f] };
                try out.appendSlice(alloc, &esc);
            } else {
                try out.append(alloc, c);
            },
        }
    }
}
