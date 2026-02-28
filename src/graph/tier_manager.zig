// Hybrid Tier Manager — HOT / WARM / COLD tiered storage
//
// Manages graph data across three tiers:
//   HOT  — fully loaded in-memory CodeGraph, instant queries
//   WARM — metadata loaded, graph on standby (fast promote to HOT)
//   COLD — only path known, must deserialize from disk
//
// Access promotes entries toward HOT; idle entries demote toward COLD.
// An adaptive working-set tracker adjusts HOT capacity based on access
// frequency — repos accessed often stay hot longer.

const std = @import("std");
const storage = @import("storage.zig");
const CodeGraph = @import("graph.zig").CodeGraph;

// ── Constants ───────────────────────────────────────────────────────────────

pub const DEFAULT_HOT_CAPACITY: u32 = 4; // max graphs kept fully in memory
pub const DEFAULT_WARM_CAPACITY: u32 = 16; // max metadata-only entries
pub const PROMOTE_THRESHOLD: u32 = 3; // accesses before COLD→WARM promote
pub const DEMOTE_IDLE_MS: i64 = 600_000; // 10 min idle → demote

// ── Tier enum ───────────────────────────────────────────────────────────────

pub const Tier = enum(u8) {
    hot,
    warm,
    cold,
};

// ── Entry ───────────────────────────────────────────────────────────────────

pub const Entry = struct {
    repo_id: u32,
    path: []const u8, // on-disk path to .codegraph/graph.bin
    tier: Tier,
    graph: ?CodeGraph, // non-null only when HOT
    access_count: u32,
    last_access_ms: i64,
    loaded_at_ms: i64, // when promoted to HOT (0 if not)
    symbol_count: u32, // cached metadata (available in WARM+HOT)
    edge_count: u32,
};

// ── TierManager ─────────────────────────────────────────────────────────────

pub const TierManager = struct {
    entries: std.AutoHashMap(u32, Entry),
    hot_capacity: u32,
    warm_capacity: u32,
    hot_count: u32,
    warm_count: u32,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) TierManager {
        return .{
            .entries = std.AutoHashMap(u32, Entry).init(alloc),
            .hot_capacity = DEFAULT_HOT_CAPACITY,
            .warm_capacity = DEFAULT_WARM_CAPACITY,
            .hot_count = 0,
            .warm_count = 0,
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *TierManager) void {
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            self.alloc.free(kv.value_ptr.path);
            if (kv.value_ptr.graph) |*g| {
                g.deinit();
            }
        }
        self.entries.deinit();
    }

    /// Register a repo as COLD (path known, not loaded).
    pub fn registerCold(self: *TierManager, repo_id: u32, path: []const u8) !void {
        // Free old entry's path if overwriting an existing registration
        if (self.entries.getPtr(repo_id)) |existing| {
            self.alloc.free(existing.path);
            if (existing.graph) |*g| g.deinit();
            // Adjust tier counts for the entry being replaced
            if (existing.tier == .hot) self.hot_count -= 1;
            if (existing.tier == .warm) self.warm_count -= 1;
        }
        const duped = try self.alloc.dupe(u8, path);
        errdefer self.alloc.free(duped);
        try self.entries.put(repo_id, .{
            .repo_id = repo_id,
            .path = duped,
            .tier = .cold,
            .graph = null,
            .access_count = 0,
            .last_access_ms = 0,
            .loaded_at_ms = 0,
            .symbol_count = 0,
            .edge_count = 0,
        });
    }

    /// Record an access for a repo. Promotes tier if thresholds met.
    /// Returns the current tier after potential promotion.
    pub fn recordAccess(self: *TierManager, repo_id: u32) ?Tier {
        return self.recordAccessAt(repo_id, std.time.milliTimestamp());
    }

    /// Record access with explicit timestamp (for testing).
    pub fn recordAccessAt(self: *TierManager, repo_id: u32, now_ms: i64) ?Tier {
        const entry = self.entries.getPtr(repo_id) orelse return null;
        entry.access_count += 1;
        entry.last_access_ms = now_ms;

        // Check promotion: COLD → WARM after PROMOTE_THRESHOLD accesses
        if (entry.tier == .cold and entry.access_count >= PROMOTE_THRESHOLD) {
            self.promoteToWarm(entry);
        }

        return entry.tier;
    }

    /// Explicitly promote a repo to HOT (load graph into memory).
    /// Evicts least-recently-used HOT entry if at capacity.
    pub fn promoteToHot(self: *TierManager, repo_id: u32) !?*CodeGraph {
        const entry = self.entries.getPtr(repo_id) orelse return null;
        if (entry.tier == .hot) {
            return if (entry.graph) |*g| g else null;
        }

        // Evict if at HOT capacity
        if (self.hot_count >= self.hot_capacity) {
            self.evictLruHot();
        }

        // Load graph from disk
        var graph = storage.loadFromFile(entry.path, self.alloc) catch return null;
        const now = std.time.milliTimestamp();

        entry.symbol_count = @intCast(graph.symbolCount());
        entry.edge_count = @intCast(graph.edgeCount());

        if (entry.tier == .warm) {
            self.warm_count -= 1;
        }
        entry.tier = .hot;
        entry.graph = graph;
        entry.loaded_at_ms = now;
        entry.last_access_ms = now;
        self.hot_count += 1;

        return if (entry.graph) |*g| g else null;
    }

    /// Demote a HOT entry to WARM (free the graph, keep metadata).
    pub fn demoteToWarm(self: *TierManager, repo_id: u32) void {
        const entry = self.entries.getPtr(repo_id) orelse return;
        if (entry.tier != .hot) return;

        if (entry.graph) |*g| {
            // Save metadata before freeing
            entry.symbol_count = @intCast(g.symbolCount());
            entry.edge_count = @intCast(g.edgeCount());
            g.deinit();
        }
        entry.graph = null;
        entry.tier = .warm;
        entry.loaded_at_ms = 0;
        self.hot_count -= 1;
        self.warm_count += 1;
    }

    /// Demote a WARM entry to COLD (clear metadata).
    pub fn demoteToCold(self: *TierManager, repo_id: u32) void {
        const entry = self.entries.getPtr(repo_id) orelse return;
        if (entry.tier == .hot) {
            self.demoteToWarm(repo_id);
            // Re-fetch after demotion
            const e = self.entries.getPtr(repo_id) orelse return;
            e.tier = .cold;
            e.symbol_count = 0;
            e.edge_count = 0;
            self.warm_count -= 1;
        } else if (entry.tier == .warm) {
            entry.tier = .cold;
            entry.symbol_count = 0;
            entry.edge_count = 0;
            self.warm_count -= 1;
        }
    }

    /// Evict idle entries based on time threshold.
    /// Demotes HOT→WARM and WARM→COLD for entries idle longer than `idle_ms`.
    pub fn evictIdle(self: *TierManager, idle_ms: i64) u32 {
        return self.evictIdleAt(idle_ms, std.time.milliTimestamp());
    }

    /// Evict idle entries with explicit timestamp (for testing).
    pub fn evictIdleAt(self: *TierManager, idle_ms: i64, now_ms: i64) u32 {
        var evicted: u32 = 0;
        // Collect keys to demote (can't modify during iteration)
        var to_demote_hot = std.ArrayList(u32).empty;
        defer to_demote_hot.deinit(self.alloc);
        var to_demote_warm = std.ArrayList(u32).empty;
        defer to_demote_warm.deinit(self.alloc);

        var it = self.entries.iterator();
        while (it.next()) |kv| {
            const e = kv.value_ptr;
            if (e.last_access_ms > 0 and (now_ms - e.last_access_ms) > idle_ms) {
                if (e.tier == .hot) {
                    to_demote_hot.append(self.alloc, kv.key_ptr.*) catch continue;
                } else if (e.tier == .warm) {
                    to_demote_warm.append(self.alloc, kv.key_ptr.*) catch continue;
                }
            }
        }

        for (to_demote_hot.items) |rid| {
            self.demoteToWarm(rid);
            evicted += 1;
        }
        for (to_demote_warm.items) |rid| {
            self.demoteToCold(rid);
            evicted += 1;
        }

        return evicted;
    }

    /// Get the current tier for a repo.
    pub fn getTier(self: *const TierManager, repo_id: u32) ?Tier {
        const entry = self.entries.get(repo_id) orelse return null;
        return entry.tier;
    }

    /// Get entry metadata (access count, tier, sizes).
    pub fn getEntry(self: *const TierManager, repo_id: u32) ?Entry {
        return self.entries.get(repo_id);
    }

    /// Get stats about the tier distribution.
    pub fn stats(self: *const TierManager) Stats {
        return .{
            .hot_count = self.hot_count,
            .warm_count = self.warm_count,
            .cold_count = self.totalCount() - self.hot_count - self.warm_count,
            .hot_capacity = self.hot_capacity,
            .warm_capacity = self.warm_capacity,
        };
    }

    pub fn totalCount(self: *const TierManager) u32 {
        return @intCast(self.entries.count());
    }

    // ── Internal ────────────────────────────────────────────────────────────

    fn promoteToWarm(self: *TierManager, entry: *Entry) void {
        if (self.warm_count >= self.warm_capacity) {
            self.evictLruWarm();
        }
        entry.tier = .warm;
        self.warm_count += 1;
    }

    fn evictLruHot(self: *TierManager) void {
        var oldest_ms: i64 = std.math.maxInt(i64);
        var oldest_id: ?u32 = null;

        var it = self.entries.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.tier == .hot and kv.value_ptr.last_access_ms < oldest_ms) {
                oldest_ms = kv.value_ptr.last_access_ms;
                oldest_id = kv.key_ptr.*;
            }
        }

        if (oldest_id) |rid| {
            self.demoteToWarm(rid);
        }
    }

    fn evictLruWarm(self: *TierManager) void {
        var oldest_ms: i64 = std.math.maxInt(i64);
        var oldest_id: ?u32 = null;

        var it = self.entries.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.tier == .warm and kv.value_ptr.last_access_ms < oldest_ms) {
                oldest_ms = kv.value_ptr.last_access_ms;
                oldest_id = kv.key_ptr.*;
            }
        }

        if (oldest_id) |rid| {
            self.demoteToCold(rid);
        }
    }
};

pub const Stats = struct {
    hot_count: u32,
    warm_count: u32,
    cold_count: u32,
    hot_capacity: u32,
    warm_capacity: u32,
};

// ── Tests ───────────────────────────────────────────────────────────────────

test "register cold entry" {
    var tm = TierManager.init(std.testing.allocator);
    defer tm.deinit();

    try tm.registerCold(1, "/repo/a/graph.bin");
    try std.testing.expectEqual(Tier.cold, tm.getTier(1).?);
    try std.testing.expectEqual(@as(u32, 1), tm.totalCount());
}

test "access promotes cold to warm after threshold" {
    var tm = TierManager.init(std.testing.allocator);
    defer tm.deinit();

    try tm.registerCold(1, "/repo/a/graph.bin");

    // Access below threshold stays cold
    _ = tm.recordAccessAt(1, 1000);
    try std.testing.expectEqual(Tier.cold, tm.getTier(1).?);
    _ = tm.recordAccessAt(1, 2000);
    try std.testing.expectEqual(Tier.cold, tm.getTier(1).?);

    // Third access hits threshold → warm
    _ = tm.recordAccessAt(1, 3000);
    try std.testing.expectEqual(Tier.warm, tm.getTier(1).?);
}

test "demote hot to warm" {
    var tm = TierManager.init(std.testing.allocator);
    defer tm.deinit();

    try tm.registerCold(1, "/repo/a/graph.bin");
    // Manually set to hot for testing (without loading from disk)
    const entry = tm.entries.getPtr(1).?;
    entry.tier = .hot;
    tm.hot_count = 1;

    tm.demoteToWarm(1);
    try std.testing.expectEqual(Tier.warm, tm.getTier(1).?);
    try std.testing.expectEqual(@as(u32, 0), tm.hot_count);
    try std.testing.expectEqual(@as(u32, 1), tm.warm_count);
}

test "demote warm to cold" {
    var tm = TierManager.init(std.testing.allocator);
    defer tm.deinit();

    try tm.registerCold(1, "/repo/a/graph.bin");
    const entry = tm.entries.getPtr(1).?;
    entry.tier = .warm;
    tm.warm_count = 1;

    tm.demoteToCold(1);
    try std.testing.expectEqual(Tier.cold, tm.getTier(1).?);
    try std.testing.expectEqual(@as(u32, 0), tm.warm_count);
}

test "evict idle entries" {
    var tm = TierManager.init(std.testing.allocator);
    defer tm.deinit();

    try tm.registerCold(1, "/repo/a/graph.bin");
    try tm.registerCold(2, "/repo/b/graph.bin");

    // Set both to warm with old access times
    const e1 = tm.entries.getPtr(1).?;
    e1.tier = .warm;
    e1.last_access_ms = 1000;
    tm.warm_count += 1;

    const e2 = tm.entries.getPtr(2).?;
    e2.tier = .warm;
    e2.last_access_ms = 5000;
    tm.warm_count += 1;

    // Evict entries idle for more than 2000ms at time 6000
    const evicted = tm.evictIdleAt(2000, 6000);
    try std.testing.expectEqual(@as(u32, 1), evicted); // only entry 1 (idle 5000ms)
    try std.testing.expectEqual(Tier.cold, tm.getTier(1).?);
    try std.testing.expectEqual(Tier.warm, tm.getTier(2).?);
}

test "stats reflect tier distribution" {
    var tm = TierManager.init(std.testing.allocator);
    defer tm.deinit();

    try tm.registerCold(1, "/a");
    try tm.registerCold(2, "/b");
    try tm.registerCold(3, "/c");

    const e2 = tm.entries.getPtr(2).?;
    e2.tier = .warm;
    tm.warm_count = 1;

    const e3 = tm.entries.getPtr(3).?;
    e3.tier = .hot;
    tm.hot_count = 1;

    const s = tm.stats();
    try std.testing.expectEqual(@as(u32, 1), s.hot_count);
    try std.testing.expectEqual(@as(u32, 1), s.warm_count);
    try std.testing.expectEqual(@as(u32, 1), s.cold_count);
}

test "unknown repo returns null" {
    var tm = TierManager.init(std.testing.allocator);
    defer tm.deinit();

    try std.testing.expectEqual(@as(?Tier, null), tm.getTier(999));
    try std.testing.expectEqual(@as(?Tier, null), tm.recordAccessAt(999, 1000));
}

test "warm capacity eviction" {
    var tm = TierManager.init(std.testing.allocator);
    defer tm.deinit();
    tm.warm_capacity = 2;

    try tm.registerCold(1, "/a");
    try tm.registerCold(2, "/b");
    try tm.registerCold(3, "/c");

    // Promote 1 and 2 to warm
    const e1 = tm.entries.getPtr(1).?;
    e1.tier = .warm;
    e1.last_access_ms = 100;
    tm.warm_count += 1;

    const e2 = tm.entries.getPtr(2).?;
    e2.tier = .warm;
    e2.last_access_ms = 200;
    tm.warm_count += 1;

    // Promote 3 to warm — should evict entry 1 (oldest)
    // Simulate by triggering enough accesses
    e1.access_count = 2;
    e2.access_count = 2;
    const e3 = tm.entries.getPtr(3).?;
    e3.access_count = 2;
    _ = tm.recordAccessAt(3, 300); // 3rd access → promotes to warm, evicts LRU

    try std.testing.expectEqual(Tier.cold, tm.getTier(1).?); // evicted
    try std.testing.expectEqual(Tier.warm, tm.getTier(2).?);
    try std.testing.expectEqual(Tier.warm, tm.getTier(3).?);
}

test "constants are reasonable" {
    try std.testing.expectEqual(@as(u32, 4), DEFAULT_HOT_CAPACITY);
    try std.testing.expectEqual(@as(u32, 16), DEFAULT_WARM_CAPACITY);
    try std.testing.expectEqual(@as(u32, 3), PROMOTE_THRESHOLD);
    try std.testing.expectEqual(@as(i64, 600_000), DEMOTE_IDLE_MS);
}

// ── Edge case tests ─────────────────────────────────────────────────────────

test "register same repo twice overwrites" {
    var tm = TierManager.init(std.testing.allocator);
    defer tm.deinit();

    try tm.registerCold(1, "/repo/a/graph.bin");
    try tm.registerCold(1, "/repo/b/graph.bin"); // overwrite

    try std.testing.expectEqual(@as(u32, 1), tm.totalCount());
    try std.testing.expectEqual(Tier.cold, tm.getTier(1).?);

    // Verify the path was updated (can check via getEntry)
    const entry = tm.getEntry(1).?;
    try std.testing.expectEqualStrings("/repo/b/graph.bin", entry.path);
}

test "promote already-HOT repo is no-op (returns graph)" {
    var tm = TierManager.init(std.testing.allocator);
    defer tm.deinit();

    try tm.registerCold(1, "/repo/a/graph.bin");

    // Manually set to hot for testing
    const entry = tm.entries.getPtr(1).?;
    entry.tier = .hot;
    tm.hot_count = 1;

    // promoteToHot on already-hot entry — graph is null so returns null
    // but should not crash or double-count
    const result = try tm.promoteToHot(1);
    try std.testing.expect(result == null); // no actual graph loaded
    try std.testing.expectEqual(@as(u32, 1), tm.hot_count);
    try std.testing.expectEqual(Tier.hot, tm.getTier(1).?);
}

test "demote already-COLD repo is no-op" {
    var tm = TierManager.init(std.testing.allocator);
    defer tm.deinit();

    try tm.registerCold(1, "/repo/a/graph.bin");
    try std.testing.expectEqual(Tier.cold, tm.getTier(1).?);

    // Demote cold → should be no-op
    tm.demoteToCold(1);
    try std.testing.expectEqual(Tier.cold, tm.getTier(1).?);
    try std.testing.expectEqual(@as(u32, 0), tm.warm_count);
    try std.testing.expectEqual(@as(u32, 0), tm.hot_count);
}

test "demote warm to warm via demoteToWarm is no-op" {
    var tm = TierManager.init(std.testing.allocator);
    defer tm.deinit();

    try tm.registerCold(1, "/repo/a/graph.bin");
    const entry = tm.entries.getPtr(1).?;
    entry.tier = .warm;
    tm.warm_count = 1;

    // demoteToWarm only applies to .hot entries
    tm.demoteToWarm(1);
    try std.testing.expectEqual(Tier.warm, tm.getTier(1).?);
    try std.testing.expectEqual(@as(u32, 1), tm.warm_count);
}

test "evict when no entries are idle" {
    var tm = TierManager.init(std.testing.allocator);
    defer tm.deinit();

    try tm.registerCold(1, "/a");
    try tm.registerCold(2, "/b");

    const e1 = tm.entries.getPtr(1).?;
    e1.tier = .warm;
    e1.last_access_ms = 9000; // very recent
    tm.warm_count += 1;

    const e2 = tm.entries.getPtr(2).?;
    e2.tier = .warm;
    e2.last_access_ms = 9500; // very recent
    tm.warm_count += 1;

    // Now = 10000, idle_ms = 2000, so entries idle > 2000ms would be evicted
    // But both entries are recent (idle 1000ms and 500ms)
    const evicted = tm.evictIdleAt(2000, 10000);
    try std.testing.expectEqual(@as(u32, 0), evicted);
    try std.testing.expectEqual(Tier.warm, tm.getTier(1).?);
    try std.testing.expectEqual(Tier.warm, tm.getTier(2).?);
}

test "access nonexistent repo returns null" {
    var tm = TierManager.init(std.testing.allocator);
    defer tm.deinit();

    try std.testing.expectEqual(@as(?Tier, null), tm.recordAccessAt(999, 1000));
    try std.testing.expectEqual(@as(?Tier, null), tm.getTier(0));
    try std.testing.expect(tm.getEntry(42) == null);
}

test "stats on empty manager" {
    var tm = TierManager.init(std.testing.allocator);
    defer tm.deinit();

    const s = tm.stats();
    try std.testing.expectEqual(@as(u32, 0), s.hot_count);
    try std.testing.expectEqual(@as(u32, 0), s.warm_count);
    try std.testing.expectEqual(@as(u32, 0), s.cold_count);
    try std.testing.expectEqual(@as(u32, 0), tm.totalCount());
}

test "register up to max capacity" {
    var tm = TierManager.init(std.testing.allocator);
    defer tm.deinit();

    // Register 50 repos
    for (0..50) |i| {
        try tm.registerCold(@intCast(i), "/repo");
    }

    try std.testing.expectEqual(@as(u32, 50), tm.totalCount());

    const s = tm.stats();
    try std.testing.expectEqual(@as(u32, 50), s.cold_count);
    try std.testing.expectEqual(@as(u32, 0), s.hot_count);
    try std.testing.expectEqual(@as(u32, 0), s.warm_count);
}

test "rapid promote/demote cycles" {
    var tm = TierManager.init(std.testing.allocator);
    defer tm.deinit();

    try tm.registerCold(1, "/repo/a/graph.bin");

    // Manually set to warm
    const entry = tm.entries.getPtr(1).?;
    entry.tier = .warm;
    tm.warm_count = 1;

    // Rapid demote to cold and back to warm
    for (0..10) |_| {
        tm.demoteToCold(1);
        try std.testing.expectEqual(Tier.cold, tm.getTier(1).?);
        try std.testing.expectEqual(@as(u32, 0), tm.warm_count);

        // Simulate re-promotion to warm by manually setting
        const e = tm.entries.getPtr(1).?;
        e.tier = .warm;
        tm.warm_count = 1;
        try std.testing.expectEqual(Tier.warm, tm.getTier(1).?);
    }

    try std.testing.expectEqual(@as(u32, 1), tm.totalCount());
}

test "rapid hot/warm demote cycles" {
    var tm = TierManager.init(std.testing.allocator);
    defer tm.deinit();

    try tm.registerCold(1, "/a");

    for (0..10) |_| {
        // Set to hot manually
        const entry = tm.entries.getPtr(1).?;
        entry.tier = .hot;
        entry.graph = null; // no actual graph, just testing tier tracking
        tm.hot_count += 1;

        // Demote to warm
        tm.demoteToWarm(1);
        try std.testing.expectEqual(Tier.warm, tm.getTier(1).?);
        try std.testing.expectEqual(@as(u32, 0), tm.hot_count);

        // Demote to cold
        tm.demoteToCold(1);
        try std.testing.expectEqual(Tier.cold, tm.getTier(1).?);
        try std.testing.expectEqual(@as(u32, 0), tm.warm_count);
    }
}

test "evict idle demotes hot to warm and warm to cold" {
    var tm = TierManager.init(std.testing.allocator);
    defer tm.deinit();

    try tm.registerCold(1, "/hot_repo");
    try tm.registerCold(2, "/warm_repo");
    try tm.registerCold(3, "/fresh_repo");

    // Set repo 1 to hot with old access
    const e1 = tm.entries.getPtr(1).?;
    e1.tier = .hot;
    e1.last_access_ms = 1000;
    tm.hot_count += 1;

    // Set repo 2 to warm with old access
    const e2 = tm.entries.getPtr(2).?;
    e2.tier = .warm;
    e2.last_access_ms = 1000;
    tm.warm_count += 1;

    // Set repo 3 to warm with recent access
    const e3 = tm.entries.getPtr(3).?;
    e3.tier = .warm;
    e3.last_access_ms = 9000;
    tm.warm_count += 1;

    const evicted = tm.evictIdleAt(5000, 10000);
    try std.testing.expectEqual(@as(u32, 2), evicted); // repos 1 and 2

    try std.testing.expectEqual(Tier.warm, tm.getTier(1).?); // hot → warm
    try std.testing.expectEqual(Tier.cold, tm.getTier(2).?); // warm → cold
    try std.testing.expectEqual(Tier.warm, tm.getTier(3).?); // unchanged
}

test "demote nonexistent repo is no-op" {
    var tm = TierManager.init(std.testing.allocator);
    defer tm.deinit();

    // These should not crash or change any state
    tm.demoteToWarm(999);
    tm.demoteToCold(999);

    try std.testing.expectEqual(@as(u32, 0), tm.totalCount());
    try std.testing.expectEqual(@as(u32, 0), tm.hot_count);
    try std.testing.expectEqual(@as(u32, 0), tm.warm_count);
}

test "access count increments correctly" {
    var tm = TierManager.init(std.testing.allocator);
    defer tm.deinit();

    try tm.registerCold(1, "/a");

    for (0..10) |i| {
        _ = tm.recordAccessAt(1, @intCast(i * 1000));
    }

    const entry = tm.getEntry(1).?;
    try std.testing.expectEqual(@as(u32, 10), entry.access_count);
    try std.testing.expectEqual(@as(i64, 9000), entry.last_access_ms);
}

test "cold entries with zero last_access_ms are not evicted" {
    var tm = TierManager.init(std.testing.allocator);
    defer tm.deinit();

    try tm.registerCold(1, "/a");
    // Cold entry, never accessed (last_access_ms = 0)
    try std.testing.expectEqual(@as(i64, 0), tm.getEntry(1).?.last_access_ms);

    // Should not be evicted (it's already cold, and last_access_ms check: 0 > 0 is false)
    const evicted = tm.evictIdleAt(1, 999999);
    try std.testing.expectEqual(@as(u32, 0), evicted);
}
