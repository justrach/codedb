// Pre-render engine — Next.js-style build-time pre-computation for codedb2.
//
// At scan time, computes a full JSON snapshot (tree + outlines + symbol index +
// dep graph) and caches it. Queries hit the cached blob in O(1).
// On file changes the snapshot is marked stale and rebuilt in the background (ISR).

const std = @import("std");
const Explorer = @import("explore.zig").Explorer;
const Store = @import("store.zig").Store;

pub const Prerender = struct {
    /// The pre-rendered JSON snapshot (owned, null until first build).
    cached_snapshot: ?[]u8 = null,
    /// Sequence number at which the snapshot was built.
    built_at_seq: u64 = 0,
    /// Monotonic invalidation epoch. Incremented on every change.
    dirty_epoch: std.atomic.Value(u64) = std.atomic.Value(u64).init(1),
    /// Epoch represented by `cached_snapshot`.
    built_epoch: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    allocator: std.mem.Allocator,
    mu: std.Thread.Mutex = .{},
    rebuild_mu: std.Thread.Mutex = .{},
    pub fn init(allocator: std.mem.Allocator) Prerender {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Prerender) void {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.cached_snapshot) |snap| self.allocator.free(snap);
        self.cached_snapshot = null;
    }

    /// Mark the snapshot as stale (called when files change).
pub fn invalidate(self: *Prerender) void {
    _ = self.dirty_epoch.fetchAdd(1, .acq_rel);
}

    /// Get the pre-rendered snapshot, rebuilding if stale.
    /// Returns a slice into the cached blob — valid until next rebuild.
    /// Caller must NOT free the returned slice.
    /// Get the pre-rendered snapshot, rebuilding if stale.
    /// Returns an owned copy that the caller must free with `alloc`.
pub fn getSnapshot(self: *Prerender, explorer: *Explorer, store: *Store, alloc: std.mem.Allocator) ![]u8 {
    const dirty = self.dirty_epoch.load(.acquire);
    const built = self.built_epoch.load(.acquire);

    if (built == dirty) {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.cached_snapshot) |snap| return try alloc.dupe(u8, snap);
    }

    // Rebuild (caches internally), then return a copy.
    const rebuilt = try self.rebuild(explorer, store);
    return try alloc.dupe(u8, rebuilt);
}

pub fn rebuild(self: *Prerender, explorer: *Explorer, store: *Store) ![]const u8 {
    self.rebuild_mu.lock();
    defer self.rebuild_mu.unlock();

    const target_epoch = self.dirty_epoch.load(.acquire);
    if (self.built_epoch.load(.acquire) == target_epoch) {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.cached_snapshot) |snap| return snap;
    }

    const new_snap = try buildSnapshot(explorer, store, self.allocator);
    errdefer self.allocator.free(new_snap);

    self.mu.lock();
    defer self.mu.unlock();
    if (self.cached_snapshot) |old| self.allocator.free(old);
    self.cached_snapshot = new_snap;
    self.built_at_seq = store.currentSeq();
    self.built_epoch.store(target_epoch, .release);
    return new_snap;
}

    /// Background ISR loop: polls for staleness and rebuilds.
pub fn isrLoop(self: *Prerender, explorer: *Explorer, store: *Store, shutdown: *std.atomic.Value(bool)) void {
    while (!shutdown.load(.acquire)) {
        std.Thread.sleep(2 * std.time.ns_per_s);
        const dirty = self.dirty_epoch.load(.acquire);
        const built = self.built_epoch.load(.acquire);
        if (dirty != built) {
            _ = self.rebuild(explorer, store) catch |err| {
                std.log.err("prerender: rebuild failed: {}", .{err});
            };
        }
    }
}
};

/// Build the full snapshot JSON blob from current explorer state.
fn buildSnapshot(explorer: *Explorer, store: *Store, alloc: std.mem.Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(alloc);
    const w = buf.writer(alloc);

    try w.writeAll("{");

    // ── seq ──
    try w.print("\"seq\":{d},", .{store.currentSeq()});

    // ── tree ──
    const tree = try explorer.getTree(alloc);
    defer alloc.free(tree);
    try w.writeAll("\"tree\":\"");
    try writeJsonEscaped(alloc, &buf, tree);
    try w.writeAll("\",");

    // ── outlines ──
    try w.writeAll("\"outlines\":{");
    {
        explorer.mu.lockShared();
        defer explorer.mu.unlockShared();

        // Collect sorted paths for deterministic output
        var paths: std.ArrayList([]const u8) = .{};
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

    // ── symbol_index: name → [{path, line, kind}] ──
    try w.writeAll("\"symbol_index\":{");
    {
        explorer.mu.lockShared();
        defer explorer.mu.unlockShared();

        // Build symbol → locations map
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
                if (!gop.found_existing) gop.value_ptr.* = .{};
                try gop.value_ptr.append(alloc, .{
                    .path = entry.key_ptr.*,
                    .line = sym.line_start,
                    .kind = sym.kind,
                });
            }
        }

        // Sort keys for determinism
        var sym_keys: std.ArrayList([]const u8) = .{};
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

    // ── dep_graph: path → [imported_files] ──
    try w.writeAll("\"dep_graph\":{");
    {
        explorer.mu.lockShared();
        defer explorer.mu.unlockShared();

        var dep_keys: std.ArrayList([]const u8) = .{};
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
