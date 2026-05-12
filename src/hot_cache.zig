const std = @import("std");

/// Fixed-capacity CLOCK eviction cache for file contents.
/// Keys are owned (duped on put, freed on eviction/remove/clear).
/// Values are owned (duped on put, freed on eviction/remove/clear).
/// Zero dynamic allocation past init.
pub const ContentCache = struct {
    slots: []Slot,
    capacity: u32,
    hand: u32,
    count_: u32,
    allocator: std.mem.Allocator,
    hits_: std.atomic.Value(u64),
    misses_: std.atomic.Value(u64),
    evictions_: std.atomic.Value(u64),

    const PROBE_LIMIT: u32 = 4;

    pub const Slot = struct {
        key_hash: u64,
        key: []const u8,
        value: []const u8,
        ref_bit: bool,
        present: bool,
    };

    const empty_slot = Slot{
        .key_hash = 0,
        .key = &.{},
        .value = &.{},
        .ref_bit = false,
        .present = false,
    };

    pub const Stats = struct {
        hits: u64,
        misses: u64,
        evictions: u64,
        count: u32,
        capacity: u32,
    };

    /// capacity must be >= 1. Panics if the allocator cannot provide the slot array.
    pub fn init(allocator: std.mem.Allocator, capacity: u32) ContentCache {
        std.debug.assert(capacity >= 1);
        const slots = allocator.alloc(Slot, capacity) catch
            std.debug.panic("ContentCache.init: OOM allocating {d} slots", .{capacity});
        @memset(slots, empty_slot);
        return .{
            .slots = slots,
            .capacity = capacity,
            .hand = 0,
            .count_ = 0,
            .allocator = allocator,
            .hits_ = std.atomic.Value(u64).init(0),
            .misses_ = std.atomic.Value(u64).init(0),
            .evictions_ = std.atomic.Value(u64).init(0),
        };
    }

    /// Fallible variant for tests that use testing.allocator (which detects leaks).
    pub fn initAlloc(allocator: std.mem.Allocator, capacity: u32) !ContentCache {
        const slots = try allocator.alloc(Slot, capacity);
        @memset(slots, empty_slot);
        return .{
            .slots = slots,
            .capacity = capacity,
            .hand = 0,
            .count_ = 0,
            .allocator = allocator,
            .hits_ = std.atomic.Value(u64).init(0),
            .misses_ = std.atomic.Value(u64).init(0),
            .evictions_ = std.atomic.Value(u64).init(0),
        };
    }

    pub fn deinit(self: *ContentCache) void {
        for (self.slots) |*slot| {
            if (slot.present) {
                self.allocator.free(slot.key);
                self.allocator.free(slot.value);
            }
        }
        self.allocator.free(self.slots);
    }

    pub fn get(self: *ContentCache, key: []const u8) ?[]const u8 {
        const h = hashKey(key);
        const base = @as(u32, @truncate(h)) % self.capacity;
        var i: u32 = 0;
        while (i < PROBE_LIMIT) : (i += 1) {
            const slot_idx = (base +% i) % self.capacity;
            const slot = &self.slots[slot_idx];
            if (slot.present and slot.key_hash == h and std.mem.eql(u8, slot.key, key)) {
                slot.ref_bit = true;
                _ = self.hits_.fetchAdd(1, .monotonic);
                return slot.value;
            }
            if (!slot.present and slot.key_hash == 0) break;
        }
        _ = self.misses_.fetchAdd(1, .monotonic);
        return null;
    }

    /// Insert key/value. Dups both into the cache allocator.
    /// On collision past probe limit, evicts a cold slot via CLOCK sweep and frees its memory.
    pub fn put(self: *ContentCache, key: []const u8, value: []const u8) !void {
        const h = hashKey(key);
        const base = @as(u32, @truncate(h)) % self.capacity;

        var i: u32 = 0;
        while (i < PROBE_LIMIT) : (i += 1) {
            const slot_idx = (base +% i) % self.capacity;
            const slot = &self.slots[slot_idx];
            if (slot.present and slot.key_hash == h and std.mem.eql(u8, slot.key, key)) {
                const old_value = slot.value;
                slot.value = try self.allocator.dupe(u8, value);
                slot.ref_bit = true;
                self.allocator.free(old_value);
                return;
            }
            if (!slot.present) {
                const duped_key = try self.allocator.dupe(u8, key);
                errdefer self.allocator.free(duped_key);
                const duped_val = try self.allocator.dupe(u8, value);
                slot.key_hash = h;
                slot.key = duped_key;
                slot.value = duped_val;
                slot.ref_bit = true;
                slot.present = true;
                self.count_ += 1;
                return;
            }
        }

        // All probe slots occupied — evict via CLOCK sweep.
        const evict_idx = self.clockEvict();
        const slot = &self.slots[evict_idx];
        if (slot.present) {
            self.allocator.free(slot.key);
            self.allocator.free(slot.value);
            self.count_ -= 1;
            _ = self.evictions_.fetchAdd(1, .monotonic);
        }
        const duped_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(duped_key);
        const duped_val = try self.allocator.dupe(u8, value);
        slot.key_hash = h;
        slot.key = duped_key;
        slot.value = duped_val;
        slot.ref_bit = true;
        slot.present = true;
        self.count_ += 1;
    }

    pub fn remove(self: *ContentCache, key: []const u8) void {
        const h = hashKey(key);
        const base = @as(u32, @truncate(h)) % self.capacity;
        var i: u32 = 0;
        while (i < PROBE_LIMIT) : (i += 1) {
            const slot_idx = (base +% i) % self.capacity;
            const slot = &self.slots[slot_idx];
            if (slot.present and slot.key_hash == h and std.mem.eql(u8, slot.key, key)) {
                self.allocator.free(slot.key);
                self.allocator.free(slot.value);
                slot.* = empty_slot;
                self.count_ -= 1;
                return;
            }
            if (!slot.present and slot.key_hash == 0) return;
        }
    }

    pub fn clear(self: *ContentCache) void {
        for (self.slots) |*slot| {
            if (slot.present) {
                self.allocator.free(slot.key);
                self.allocator.free(slot.value);
                slot.* = empty_slot;
            }
        }
        self.count_ = 0;
        self.hand = 0;
    }

    pub fn len(self: *const ContentCache) u32 {
        return self.count_;
    }

    pub fn count(self: *const ContentCache) u32 {
        return self.count_;
    }

    pub fn contains(self: *ContentCache, key: []const u8) bool {
        return self.get(key) != null;
    }

    pub fn stats(self: *const ContentCache) Stats {
        return .{
            .hits = self.hits_.load(.monotonic),
            .misses = self.misses_.load(.monotonic),
            .evictions = self.evictions_.load(.monotonic),
            .count = self.count_,
            .capacity = self.capacity,
        };
    }

    pub const Iterator = struct {
        cache: *const ContentCache,
        index: u32,

        pub const Entry = struct {
            key_ptr: *const []const u8,
            value_ptr: *const []const u8,
        };

        pub fn next(self: *Iterator) ?Entry {
            while (self.index < self.cache.capacity) {
                const slot = &self.cache.slots[self.index];
                self.index += 1;
                if (slot.present) {
                    return .{
                        .key_ptr = &slot.key,
                        .value_ptr = &slot.value,
                    };
                }
            }
            return null;
        }
    };

    pub fn iterator(self: *const ContentCache) Iterator {
        return .{ .cache = self, .index = 0 };
    }

    fn clockEvict(self: *ContentCache) u32 {
        var sweeps: u32 = 0;
        while (sweeps < self.capacity * 2) : (sweeps += 1) {
            const slot_idx = self.hand % self.capacity;
            self.hand = (self.hand +% 1) % self.capacity;
            const slot = &self.slots[slot_idx];
            if (!slot.present) return slot_idx;
            if (!slot.ref_bit) {
                return slot_idx;
            }
            slot.ref_bit = false;
        }
        const slot_idx = self.hand % self.capacity;
        self.hand = (self.hand +% 1) % self.capacity;
        return slot_idx;
    }

    fn hashKey(key: []const u8) u64 {
        var h: u64 = 14695981039346656037;
        for (key) |b| {
            h ^= b;
            h *%= 1099511628211;
        }
        if (h == 0) h = 1;
        return h;
    }
};

test "ContentCache: basic get/put/remove" {
    var cache = try ContentCache.initAlloc(std.testing.allocator, 64);
    defer cache.deinit();

    try cache.put("foo", "bar");
    try std.testing.expectEqualStrings("bar", cache.get("foo").?);
    try std.testing.expect(cache.get("missing") == null);

    cache.remove("foo");
    try std.testing.expect(cache.get("foo") == null);
    try std.testing.expectEqual(@as(u32, 0), cache.len());
}

test "ContentCache: put updates existing key in place" {
    var cache = try ContentCache.initAlloc(std.testing.allocator, 64);
    defer cache.deinit();

    try cache.put("key", "v1");
    try cache.put("key", "v2");
    try std.testing.expectEqualStrings("v2", cache.get("key").?);
    try std.testing.expectEqual(@as(u32, 1), cache.len());
}

test "ContentCache: clear drops all entries" {
    var cache = try ContentCache.initAlloc(std.testing.allocator, 64);
    defer cache.deinit();

    try cache.put("a", "1");
    try cache.put("b", "2");
    cache.clear();
    try std.testing.expectEqual(@as(u32, 0), cache.len());
    try std.testing.expect(cache.get("a") == null);
}

test "ContentCache: iterator visits all present entries" {
    var cache = try ContentCache.initAlloc(std.testing.allocator, 64);
    defer cache.deinit();

    try cache.put("x", "1");
    try cache.put("y", "2");
    try cache.put("z", "3");

    var count: usize = 0;
    var iter = cache.iterator();
    while (iter.next()) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 3), count);
}

test "ContentCache: eviction fires under capacity pressure" {
    const cap = 50;
    var cache = try ContentCache.initAlloc(std.testing.allocator, cap);
    defer cache.deinit();

    var key_buf: [32]u8 = undefined;
    var val_buf: [32]u8 = undefined;
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const k = std.fmt.bufPrint(&key_buf, "file_{d}.zig", .{i}) catch unreachable;
        const v = std.fmt.bufPrint(&val_buf, "content_{d}", .{i}) catch unreachable;
        try cache.put(k, v);
    }
    try std.testing.expect(cache.len() <= cap);
    const s = cache.stats();
    try std.testing.expect(s.evictions > 0);
}
