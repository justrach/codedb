const std = @import("std");
const builtin = @import("builtin");

const AtomicCounter = if (builtin.cpu.arch == .wasm32) u32 else u64;

/// Fixed-capacity CLOCK eviction cache for file contents.
/// Callers must provide external synchronization around get/put/remove/clear;
/// Explorer uses its shared/exclusive mutex for that contract.
/// Keys are always owned (duped on put, freed on eviction/remove/clear/deinit).
/// Values are owned by default (duped on put), but `putBorrowed` stores a value
/// that aliases externally-owned memory (e.g. a retained mmap of the snapshot
/// content section): `value_owned=false` so it is never freed by the cache —
/// the borrowed bytes must outlive the cache (the Explorer munmaps at deinit).
/// Zero dynamic allocation past init (for owned-value puts; borrowed puts don't
/// allocate the value at all).
pub const ContentCache = struct {
    slots: []Slot,
    capacity: u32,
    count_: u32,
    next_generation: u64,
    allocator: std.mem.Allocator,
    hits_: std.atomic.Value(AtomicCounter),
    misses_: std.atomic.Value(AtomicCounter),
    evictions_: std.atomic.Value(AtomicCounter),
    /// Total bytes of cache-owned values (borrowed values are exempt).
    owned_bytes: usize,
    /// CLOCK hand for the global budget sweep (window eviction has its own).
    sweep_hand: u32,
    /// Owned-value byte budget (#596); puts evict cold owned entries to stay under it.
    byte_budget: usize,
    /// Owned values larger than this are not cached at all — search re-reads
    /// from disk on a miss, so refusing oversized values is safe.
    max_entry_bytes: usize,

    // 8-way set-associative: at typical occupancy a full window (the only
    // eviction trigger) is vanishingly rare; probes stay short and contiguous.
    const PROBE_LIMIT: u32 = 8;

    pub const DEFAULT_BYTE_BUDGET: usize = 256 * 1024 * 1024;
    pub const DEFAULT_MAX_ENTRY_BYTES: usize = 8 * 1024 * 1024;

    pub const Slot = struct {
        key_hash: u64,
        key: []const u8,
        value: []const u8,
        generation: u64,
        ref_bit: bool,
        present: bool,
        /// When false, `value` aliases externally-owned memory and the cache
        /// must not free it (the key is always cache-owned regardless).
        value_owned: bool,
    };

    const empty_slot = Slot{
        .key_hash = 0,
        .key = &.{},
        .value = &.{},
        .generation = 0,
        .ref_bit = false,
        .present = false,
        .value_owned = false,
    };

    pub const Stats = struct {
        hits: u64,
        misses: u64,
        evictions: u64,
        count: u32,
        capacity: u32,
        owned_bytes: usize,
    };

    /// capacity must be >= 1. Panics if the allocator cannot provide the slot array.
    /// capacity must be >= 1. Panics if the allocator cannot provide the slot array.
    pub fn init(allocator: std.mem.Allocator, capacity: u32) ContentCache {
        std.debug.assert(capacity >= 1);
        const slots = allocator.alloc(Slot, capacity) catch
            std.debug.panic("ContentCache.init: OOM allocating {d} slots", .{capacity});
        @memset(slots, empty_slot);
        return .{
            .slots = slots,
            .capacity = capacity,
            .count_ = 0,
            .next_generation = 1,
            .allocator = allocator,
            .hits_ = std.atomic.Value(AtomicCounter).init(0),
            .misses_ = std.atomic.Value(AtomicCounter).init(0),
            .evictions_ = std.atomic.Value(AtomicCounter).init(0),
            .owned_bytes = 0,
            .sweep_hand = 0,
            .byte_budget = DEFAULT_BYTE_BUDGET,
            .max_entry_bytes = DEFAULT_MAX_ENTRY_BYTES,
        };
    }

    /// Fallible variant for tests that use testing.allocator (which detects leaks).
    pub fn initAlloc(allocator: std.mem.Allocator, capacity: u32) !ContentCache {
        const slots = try allocator.alloc(Slot, capacity);
        @memset(slots, empty_slot);
        return .{
            .slots = slots,
            .capacity = capacity,
            .count_ = 0,
            .next_generation = 1,
            .allocator = allocator,
            .hits_ = std.atomic.Value(AtomicCounter).init(0),
            .misses_ = std.atomic.Value(AtomicCounter).init(0),
            .evictions_ = std.atomic.Value(AtomicCounter).init(0),
            .owned_bytes = 0,
            .sweep_hand = 0,
            .byte_budget = DEFAULT_BYTE_BUDGET,
            .max_entry_bytes = DEFAULT_MAX_ENTRY_BYTES,
        };
    }

    pub fn deinit(self: *ContentCache) void {
        for (self.slots) |*slot| {
            if (slot.present) {
                self.allocator.free(slot.key);
                if (slot.value_owned) self.allocator.free(slot.value);
            }
        }
        self.allocator.free(self.slots);
    }

    pub const ValueRef = struct {
        value: []const u8,
        generation: u64,
        value_owned: bool,
    };

    pub fn getWithGeneration(self: *ContentCache, key: []const u8) ?ValueRef {
        const h = hashKey(key);
        const base = @as(u32, @truncate(h)) % self.capacity;
        var i: u32 = 0;
        while (i < PROBE_LIMIT) : (i += 1) {
            const slot_idx = (base +% i) % self.capacity;
            const slot = &self.slots[slot_idx];
            if (slot.present and slot.key_hash == h and std.mem.eql(u8, slot.key, key)) {
                slot.ref_bit = true;
                _ = self.hits_.fetchAdd(1, .monotonic);
                return .{ .value = slot.value, .generation = slot.generation, .value_owned = slot.value_owned };
            }
        }
        _ = self.misses_.fetchAdd(1, .monotonic);
        return null;
    }

    pub fn get(self: *ContentCache, key: []const u8) ?[]const u8 {
        const ref = self.getWithGeneration(key) orelse return null;
        return ref.value;
    }

    /// Insert key/value, duping both into the cache allocator. On collision past
    /// the probe limit, evicts a cold slot via CLOCK sweep and frees its memory.
    /// Insert key/value, duping both into the cache allocator. On collision past
    /// the probe limit, evicts a cold slot via CLOCK sweep and frees its memory.
    pub fn put(self: *ContentCache, key: []const u8, value: []const u8) !void {
        return self.putImpl(key, value, true);
    }

    /// Like `put`, but `value` aliases externally-owned memory that outlives the
    /// cache (a retained mmap of the snapshot content section). The value is
    /// stored as-is (no dupe) and is never freed by the cache; the key is still
    /// duped/owned as usual. The caller guarantees `value`'s backing stays valid
    /// for as long as the entry can live (until Explorer.deinit munmaps it).
    /// Borrowed values are exempt from the byte budget.
    pub fn putBorrowed(self: *ContentCache, key: []const u8, value: []const u8) !void {
        return self.putImpl(key, value, false);
    }

    fn takeGeneration(self: *ContentCache) u64 {
        const generation = self.next_generation;
        if (generation == std.math.maxInt(u64)) @panic("ContentCache generation exhausted");
        self.next_generation = generation + 1;
        return generation;
    }

    fn putImpl(self: *ContentCache, key: []const u8, value: []const u8, own: bool) !void {
        if (own and (value.len > self.max_entry_bytes or value.len > self.byte_budget)) {
            // Too large to cache; drop any stale entry for the key so get()
            // cannot serve outdated content. Search re-reads from disk on miss.
            self.remove(key);
            return;
        }
        if (own) self.evictForBudget(value.len);

        const h = hashKey(key);
        const base = @as(u32, @truncate(h)) % self.capacity;

        // Scan the whole window: update an existing entry in place (a hole must
        // not shadow it into a duplicate), otherwise remember the first empty slot.
        var empty_idx: ?u32 = null;
        var i: u32 = 0;
        while (i < PROBE_LIMIT) : (i += 1) {
            const slot_idx = (base +% i) % self.capacity;
            const slot = &self.slots[slot_idx];
            if (slot.present) {
                if (slot.key_hash == h and std.mem.eql(u8, slot.key, key)) {
                    // Compute the new value first so a failed dupe leaves the slot intact.
                    const new_value = if (own) try self.allocator.dupe(u8, value) else value;
                    if (slot.value_owned) {
                        self.owned_bytes -= slot.value.len;
                        self.allocator.free(slot.value);
                    }
                    slot.value = new_value;
                    slot.value_owned = own;
                    slot.generation = self.takeGeneration();
                    if (own) self.owned_bytes += value.len;
                    slot.ref_bit = true;
                    return;
                }
            } else if (empty_idx == null) {
                empty_idx = slot_idx;
            }
        }

        // Window full of other keys — evict in-window (second chance over the
        // probe slots) so the new entry stays reachable by get(). A victim from
        // a global sweep would strand the entry outside its own window.
        const target_idx = empty_idx orelse blk: {
            var victim: ?u32 = null;
            i = 0;
            while (i < PROBE_LIMIT) : (i += 1) {
                const slot_idx = (base +% i) % self.capacity;
                if (!self.slots[slot_idx].ref_bit) {
                    victim = slot_idx;
                    break;
                }
            }
            if (victim == null) {
                i = 0;
                while (i < PROBE_LIMIT) : (i += 1) {
                    self.slots[(base +% i) % self.capacity].ref_bit = false;
                }
                victim = base;
            }
            const slot = &self.slots[victim.?];
            if (slot.value_owned) self.owned_bytes -= slot.value.len;
            self.allocator.free(slot.key);
            if (slot.value_owned) self.allocator.free(slot.value);
            slot.* = empty_slot;
            self.count_ -= 1;
            _ = self.evictions_.fetchAdd(1, .monotonic);
            break :blk victim.?;
        };

        const slot = &self.slots[target_idx];
        const duped_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(duped_key);
        const new_value = if (own) try self.allocator.dupe(u8, value) else value;
        slot.key_hash = h;
        slot.key = duped_key;
        slot.value = new_value;
        slot.value_owned = own;
        slot.generation = self.takeGeneration();
        slot.ref_bit = true;
        slot.present = true;
        if (own) self.owned_bytes += value.len;
        self.count_ += 1;
    }

    /// Evict cold owned entries (global second-chance sweep) until `incoming`
    /// more owned bytes fit the byte budget. Borrowed entries are skipped —
    /// evicting them frees no budget. Holes are safe: get() and putImpl()
    /// always scan the full probe window. Stops when no owned victim remains.
    fn evictForBudget(self: *ContentCache, incoming: usize) void {
        while (self.owned_bytes + incoming > self.byte_budget) {
            var victim: ?u32 = null;
            var scanned: u32 = 0;
            while (scanned < self.capacity * 2) : (scanned += 1) {
                const idx = self.sweep_hand;
                self.sweep_hand = (self.sweep_hand + 1) % self.capacity;
                const slot = &self.slots[idx];
                if (!slot.present or !slot.value_owned) continue;
                if (slot.ref_bit) {
                    slot.ref_bit = false;
                    continue;
                }
                victim = idx;
                break;
            }
            const idx = victim orelse return;
            const slot = &self.slots[idx];
            self.owned_bytes -= slot.value.len;
            self.allocator.free(slot.key);
            self.allocator.free(slot.value);
            slot.* = empty_slot;
            self.count_ -= 1;
            _ = self.evictions_.fetchAdd(1, .monotonic);
        }
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
                if (slot.value_owned) {
                    self.owned_bytes -= slot.value.len;
                    self.allocator.free(slot.value);
                }
                slot.* = empty_slot;
                self.count_ -= 1;
                return;
            }
        }
    }

    pub fn clear(self: *ContentCache) void {
        for (self.slots) |*slot| {
            if (slot.present) {
                self.allocator.free(slot.key);
                if (slot.value_owned) self.allocator.free(slot.value);
                slot.* = empty_slot;
            }
        }
        self.count_ = 0;
        self.owned_bytes = 0;
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
            .owned_bytes = self.owned_bytes,
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

test "ContentCache: generations change when storage is replaced" {
    var cache = try ContentCache.initAlloc(std.testing.allocator, 64);
    defer cache.deinit();

    try cache.put("key", "same");
    const first = cache.getWithGeneration("key").?;
    try std.testing.expect(first.value_owned);
    try cache.put("key", "size");
    const second = cache.getWithGeneration("key").?;
    try std.testing.expect(first.generation != second.generation);
    try std.testing.expectEqualStrings("size", second.value);

    cache.remove("key");
    try cache.put("key", "same");
    const third = cache.getWithGeneration("key").?;
    try std.testing.expect(second.generation != third.generation);

    cache.clear();
    try cache.put("key", "same");
    const fourth = cache.getWithGeneration("key").?;
    try std.testing.expect(third.generation != fourth.generation);
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

test "ContentCache: putBorrowed is zero-copy and never frees the value" {
    var cache = try ContentCache.initAlloc(std.testing.allocator, 64);
    defer cache.deinit();

    // A string literal lives in static memory — if the cache ever tried to free
    // it, the DebugAllocator would detect a bad free / crash.
    const borrowed: []const u8 = "borrowed content not owned by the cache";
    try cache.putBorrowed("k", borrowed);
    const got = cache.get("k").?;
    try std.testing.expectEqual(borrowed.ptr, got.ptr); // aliases, not a copy
    try std.testing.expectEqualStrings(borrowed, got);

    // remove frees the owned key but must leave the borrowed value alone.
    cache.remove("k");
    try std.testing.expect(cache.get("k") == null);
}

test "ContentCache: mixed owned/borrowed — transitions and eviction free correctly" {
    var cache = try ContentCache.initAlloc(std.testing.allocator, 8);
    defer cache.deinit();

    const lit: []const u8 = "literal-borrowed-value";
    try cache.put("a", "heap-duped"); // owned
    try cache.putBorrowed("b", lit); // borrowed
    try std.testing.expectEqualStrings("heap-duped", cache.get("a").?);
    try std.testing.expectEqual(lit.ptr, cache.get("b").?.ptr);

    // owned -> borrowed: the old heap value must be freed, new aliases lit.
    try cache.putBorrowed("a", lit);
    try std.testing.expectEqual(lit.ptr, cache.get("a").?.ptr);
    // borrowed -> owned: the old borrowed (literal) must NOT be freed.
    try cache.put("b", "now-owned");
    try std.testing.expectEqualStrings("now-owned", cache.get("b").?);

    // Capacity pressure with both kinds interleaved: evicting a borrowed slot
    // must skip the free (would crash on the literal); evicting owned frees it.
    var kb: [16]u8 = undefined;
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        const k = std.fmt.bufPrint(&kb, "f{d}", .{i}) catch unreachable;
        if (i % 2 == 0) try cache.putBorrowed(k, lit) else try cache.put(k, "v");
    }
    try std.testing.expect(cache.len() <= 8);
    // No leak (DebugAllocator) and no bad free => the owned/borrowed split holds.
}

test "ContentCache: byte budget evicts owned values until the new value fits" {
    var cache = try ContentCache.initAlloc(std.testing.allocator, 64);
    defer cache.deinit();
    cache.byte_budget = 1000;
    cache.max_entry_bytes = 1000;

    const v300: [300]u8 = @splat('x');
    try cache.put("a", &v300);
    try cache.put("b", &v300);
    try cache.put("c", &v300);
    try std.testing.expectEqual(@as(usize, 900), cache.stats().owned_bytes);

    try cache.put("d", &v300);
    const s = cache.stats();
    try std.testing.expect(s.owned_bytes <= 1000);
    try std.testing.expect(s.evictions >= 1);
    try std.testing.expect(cache.get("d") != null);
}

test "ContentCache: per-entry ceiling refuses oversized values and drops the stale entry" {
    var cache = try ContentCache.initAlloc(std.testing.allocator, 8);
    defer cache.deinit();
    cache.max_entry_bytes = 100;

    try cache.put("k", "small");
    try std.testing.expect(cache.get("k") != null);

    const big: [200]u8 = @splat('y');
    try cache.put("k", &big);
    try std.testing.expect(cache.get("k") == null);
    try std.testing.expectEqual(@as(usize, 0), cache.stats().owned_bytes);
}

test "ContentCache: borrowed values are exempt from the byte budget" {
    var cache = try ContentCache.initAlloc(std.testing.allocator, 8);
    defer cache.deinit();
    cache.byte_budget = 10;

    const big: [1000]u8 = @splat('z');
    try cache.putBorrowed("snap", &big);
    try std.testing.expect(cache.get("snap") != null);
    try std.testing.expectEqual(@as(usize, 0), cache.stats().owned_bytes);
    try std.testing.expectEqual(@as(u64, 0), cache.stats().evictions);

    try cache.put("o", "abcdefgh");
    try std.testing.expect(cache.get("o") != null);
    try std.testing.expect(cache.get("snap") != null);
}

test "ContentCache: owned_bytes accounting tracks update, remove, and clear" {
    var cache = try ContentCache.initAlloc(std.testing.allocator, 8);
    defer cache.deinit();

    try cache.put("k", "0123456789");
    try std.testing.expectEqual(@as(usize, 10), cache.stats().owned_bytes);
    try cache.put("k", "01234");
    try std.testing.expectEqual(@as(usize, 5), cache.stats().owned_bytes);
    try cache.put("j", "012");
    try std.testing.expectEqual(@as(usize, 8), cache.stats().owned_bytes);
    cache.remove("k");
    try std.testing.expectEqual(@as(usize, 3), cache.stats().owned_bytes);
    cache.clear();
    try std.testing.expectEqual(@as(usize, 0), cache.stats().owned_bytes);
}
