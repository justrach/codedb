const std = @import("std");
const cio = @import("cio.zig");
const Explorer = @import("explore.zig").Explorer;
const Store = @import("store.zig").Store;

pub fn buildSnapshot(explorer: *Explorer, store: *Store, alloc: std.mem.Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    const w = cio.listWriter(&buf, alloc);

    try w.writeAll("{");
    try w.print("\"seq\":{d},", .{store.currentSeq()});

    {
        explorer.mu.lockShared();
        defer explorer.mu.unlockShared();

        try buf.ensureTotalCapacity(alloc, roughSnapshotCapacity(explorer.outlines.count()));

        var paths: std.ArrayList([]const u8) = .empty;
        defer paths.deinit(alloc);
        try paths.ensureTotalCapacity(alloc, explorer.outlines.count());
        var iter = explorer.outlines.iterator();
        while (iter.next()) |entry| {
            try paths.append(alloc, entry.key_ptr.*);
        }
        std.mem.sort([]const u8, paths.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);

        try w.writeAll("\"tree\":\"");
        try writeTreeJsonEscaped(alloc, &buf, explorer, paths.items);
        try w.writeAll("\",");

        try w.writeAll("\"outlines\":{");
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
        try w.writeAll("},");

        try w.writeAll("\"symbol_index\":{");
        var sym_keys: std.ArrayList([]const u8) = .empty;
        defer sym_keys.deinit(alloc);
        try sym_keys.ensureTotalCapacity(alloc, explorer.symbol_index.count());
        var ski = explorer.symbol_index.iterator();
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
            const locs = explorer.symbol_index.get(name) orelse continue;
            for (locs.items, 0..) |loc, li| {
                if (li > 0) try w.writeAll(",");
                try w.writeAll("{\"path\":\"");
                try writeJsonEscaped(alloc, &buf, loc.path);
                try w.print("\",\"line\":{d},\"kind\":\"{s}\"}}", .{
                    loc.line_start, @tagName(loc.kind),
                });
            }
            try w.writeAll("]");
        }
        try w.writeAll("},");

        try w.writeAll("\"dep_graph\":{");
        var dep_keys: std.ArrayList([]const u8) = .empty;
        defer dep_keys.deinit(alloc);
        try dep_keys.ensureTotalCapacity(alloc, explorer.dep_graph.count());
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
        try w.writeAll("}");
    }
    try w.writeAll("}");

    return buf.toOwnedSlice(alloc);
}

fn roughSnapshotCapacity(file_count: usize) usize {
    const min_capacity: usize = 64 * 1024;
    const max_capacity: usize = 8 * 1024 * 1024;
    const per_file: usize = 32 * 1024;
    if (file_count == 0) return min_capacity;
    if (file_count > max_capacity / per_file) return max_capacity;
    return @max(min_capacity, file_count * per_file);
}

fn writeTreeJsonEscaped(alloc: std.mem.Allocator, out: *std.ArrayList(u8), explorer: *Explorer, paths: []const []const u8) !void {
    const w = cio.listWriter(out, alloc);
    var seen_dirs = std.StringHashMap(void).init(alloc);
    defer seen_dirs.deinit();

    for (paths) |path| {
        const outline = explorer.outlines.get(path) orelse continue;

        var prefix_end: usize = 0;
        while (std.mem.indexOfScalarPos(u8, path, prefix_end, '/')) |sep| {
            const dir = path[0 .. sep + 1];
            if (!seen_dirs.contains(dir)) {
                try seen_dirs.put(dir, {});
                const depth = std.mem.count(u8, dir[0..sep], "/");
                for (0..depth) |_| try w.writeAll("  ");
                const dir_name = path[if (depth > 0) std.mem.lastIndexOfScalar(u8, dir[0..sep], '/').? + 1 else 0..sep];
                try writeJsonEscaped(alloc, out, dir_name);
                try w.writeAll("/\\n");
            }
            prefix_end = sep + 1;
        }

        const depth = std.mem.count(u8, path, "/");
        for (0..depth) |_| try w.writeAll("  ");
        const basename = if (std.mem.lastIndexOfScalar(u8, path, '/')) |pos| path[pos + 1 ..] else path;
        try writeJsonEscaped(alloc, out, basename);
        try w.print("  {s}  {d}L  {d} sym\\n", .{
            @tagName(outline.language),
            outline.line_count,
            outline.symbols.items.len,
        });
    }
}

fn writeJsonEscaped(alloc: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    var start: usize = 0;
    for (s, 0..) |c, i| {
        switch (c) {
            '"' => {
                if (i > start) try out.appendSlice(alloc, s[start..i]);
                try out.appendSlice(alloc, "\\\"");
                start = i + 1;
            },
            '\\' => {
                if (i > start) try out.appendSlice(alloc, s[start..i]);
                try out.appendSlice(alloc, "\\\\");
                start = i + 1;
            },
            '\n' => {
                if (i > start) try out.appendSlice(alloc, s[start..i]);
                try out.appendSlice(alloc, "\\n");
                start = i + 1;
            },
            '\r' => {
                if (i > start) try out.appendSlice(alloc, s[start..i]);
                try out.appendSlice(alloc, "\\r");
                start = i + 1;
            },
            '\t' => {
                if (i > start) try out.appendSlice(alloc, s[start..i]);
                try out.appendSlice(alloc, "\\t");
                start = i + 1;
            },
            else => if (c < 0x20) {
                if (i > start) try out.appendSlice(alloc, s[start..i]);
                const hex = "0123456789abcdef";
                const esc = [6]u8{ '\\', 'u', '0', '0', hex[c >> 4], hex[c & 0x0f] };
                try out.appendSlice(alloc, &esc);
                start = i + 1;
            },
        }
    }
    if (start < s.len) try out.appendSlice(alloc, s[start..]);
}
