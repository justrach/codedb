// CodeGraph DB — in-memory hot cache (LRU)
//
// LRU cache for frequently accessed PPR results and symbol lookups.
// Sits in front of the on-disk CodeGraph to avoid repeated deserialization.
//
// Design:
//   - Fixed-capacity LRU with O(1) get/put via HashMap + doubly-linked list
//   - Evicts least-recently-used entry when capacity is exceeded
//   - Cache keys are u64 (symbol IDs, query node IDs, etc.)
//   - Cache values are generic (caller chooses the payload type)
//   - Thread-safety is NOT provided (single-threaded MCP server model)

const std = @import("std");

/// Generic LRU cache with u64 keys and configurable value type.
pub fn LruCache(comptime V: type) type {
    return struct {
        const Self = @This();

        pub const Entry = struct {
            key: u64,
            value: V,
            prev: ?*Entry = null,
            next: ?*Entry = null,
        };

        map: std.AutoHashMap(u64, *Entry),
        pool: std.heap.MemoryPool(Entry),
        capacity: usize,
        len: usize,
        head: ?*Entry, // most recently used
        tail: ?*Entry, // least recently used
        alloc: std.mem.Allocator,

        pub fn init(alloc: std.mem.Allocator, capacity: usize) Self {
            return .{
                .map = std.AutoHashMap(u64, *Entry).init(alloc),
                .pool = std.heap.MemoryPool(Entry).init(alloc),
                .capacity = capacity,
                .len = 0,
                .head = null,
                .tail = null,
                .alloc = alloc,
            };
        }

        pub fn deinit(self: *Self) void {
            self.map.deinit();
            self.pool.deinit();
        }

        /// Get a value by key. Returns null on miss. Promotes to MRU on hit.
        pub fn get(self: *Self, key: u64) ?V {
            const entry = self.map.get(key) orelse return null;
            self.moveToFront(entry);
            return entry.value;
        }

        /// Insert or update a key-value pair. Evicts LRU if at capacity.
        pub fn put(self: *Self, key: u64, value: V) !void {
            if (self.map.get(key)) |entry| {
                // Update existing
                entry.value = value;
                self.moveToFront(entry);
                return;
            }

            // Evict if at capacity
            if (self.len >= self.capacity) {
                self.evictLru();
            }

            // Insert new entry
            const entry = try self.pool.create();
            entry.* = .{ .key = key, .value = value };
            try self.map.put(key, entry);
            self.pushFront(entry);
            self.len += 1;
        }

        /// Remove a specific key from the cache.
        pub fn remove(self: *Self, key: u64) bool {
            const entry = self.map.get(key) orelse return false;
            self.unlink(entry);
            _ = self.map.remove(key);
            self.pool.destroy(entry);
            self.len -= 1;
            return true;
        }

        /// Clear all entries.
        pub fn clear(self: *Self) void {
            self.map.clearAndFree();
            self.pool.deinit();
            self.pool = std.heap.MemoryPool(Entry).init(self.alloc);
            self.head = null;
            self.tail = null;
            self.len = 0;
        }

        /// Number of entries currently in cache.
        pub fn count(self: *const Self) usize {
            return self.len;
        }

        // ── Linked list operations ──────────────────────────────────────

        fn moveToFront(self: *Self, entry: *Entry) void {
            if (self.head == entry) return; // already at front
            self.unlink(entry);
            self.pushFront(entry);
        }

        fn pushFront(self: *Self, entry: *Entry) void {
            entry.prev = null;
            entry.next = self.head;
            if (self.head) |h| h.prev = entry;
            self.head = entry;
            if (self.tail == null) self.tail = entry;
        }

        fn unlink(self: *Self, entry: *Entry) void {
            if (entry.prev) |p| p.next = entry.next else self.head = entry.next;
            if (entry.next) |n| n.prev = entry.prev else self.tail = entry.prev;
            entry.prev = null;
            entry.next = null;
        }

        fn evictLru(self: *Self) void {
            const lru = self.tail orelse return;
            self.unlink(lru);
            _ = self.map.remove(lru.key);
            self.pool.destroy(lru);
            self.len -= 1;
        }
    };
}

// ── Pre-defined cache types ─────────────────────────────────────────────────

/// Cache for PPR score maps (query_node_id → top scores).
pub const PprCache = LruCache([]const ScoredEntry);

pub const ScoredEntry = struct {
    id: u64,
    score: f32,
};

/// Cache for symbol lookup results.
pub const SymbolCache = LruCache(CachedSymbol);

pub const CachedSymbol = struct {
    name: []const u8,
    kind: u8,
    file_id: u32,
    line: u32,
};

// ── Tests ───────────────────────────────────────────────────────────────────

test "basic put and get" {
    var cache = LruCache(u32).init(std.testing.allocator, 4);
    defer cache.deinit();

    try cache.put(1, 100);
    try cache.put(2, 200);

    try std.testing.expectEqual(@as(?u32, 100), cache.get(1));
    try std.testing.expectEqual(@as(?u32, 200), cache.get(2));
    try std.testing.expectEqual(@as(?u32, null), cache.get(3));
}

test "capacity limit and LRU eviction" {
    var cache = LruCache(u32).init(std.testing.allocator, 3);
    defer cache.deinit();

    try cache.put(1, 10);
    try cache.put(2, 20);
    try cache.put(3, 30);
    try std.testing.expectEqual(@as(usize, 3), cache.count());

    // Adding 4th should evict key 1 (LRU)
    try cache.put(4, 40);
    try std.testing.expectEqual(@as(usize, 3), cache.count());
    try std.testing.expectEqual(@as(?u32, null), cache.get(1));
    try std.testing.expectEqual(@as(?u32, 20), cache.get(2));
    try std.testing.expectEqual(@as(?u32, 30), cache.get(3));
    try std.testing.expectEqual(@as(?u32, 40), cache.get(4));
}

test "get promotes to MRU" {
    var cache = LruCache(u32).init(std.testing.allocator, 3);
    defer cache.deinit();

    try cache.put(1, 10);
    try cache.put(2, 20);
    try cache.put(3, 30);

    // Access key 1 to promote it
    _ = cache.get(1);

    // Now key 2 should be LRU and evicted
    try cache.put(4, 40);
    try std.testing.expectEqual(@as(?u32, 10), cache.get(1)); // promoted, still here
    try std.testing.expectEqual(@as(?u32, null), cache.get(2)); // evicted
    try std.testing.expectEqual(@as(?u32, 30), cache.get(3));
    try std.testing.expectEqual(@as(?u32, 40), cache.get(4));
}

test "put updates existing key" {
    var cache = LruCache(u32).init(std.testing.allocator, 4);
    defer cache.deinit();

    try cache.put(1, 100);
    try cache.put(1, 200);

    try std.testing.expectEqual(@as(usize, 1), cache.count());
    try std.testing.expectEqual(@as(?u32, 200), cache.get(1));
}

test "remove deletes entry" {
    var cache = LruCache(u32).init(std.testing.allocator, 4);
    defer cache.deinit();

    try cache.put(1, 100);
    try cache.put(2, 200);

    try std.testing.expect(cache.remove(1));
    try std.testing.expectEqual(@as(?u32, null), cache.get(1));
    try std.testing.expectEqual(@as(usize, 1), cache.count());

    // Remove non-existent
    try std.testing.expect(!cache.remove(99));
}

test "clear empties cache" {
    var cache = LruCache(u32).init(std.testing.allocator, 4);
    defer cache.deinit();

    try cache.put(1, 100);
    try cache.put(2, 200);
    try cache.put(3, 300);

    cache.clear();
    try std.testing.expectEqual(@as(usize, 0), cache.count());
    try std.testing.expectEqual(@as(?u32, null), cache.get(1));
}

test "capacity of 1" {
    var cache = LruCache(u32).init(std.testing.allocator, 1);
    defer cache.deinit();

    try cache.put(1, 10);
    try std.testing.expectEqual(@as(?u32, 10), cache.get(1));

    try cache.put(2, 20);
    try std.testing.expectEqual(@as(?u32, null), cache.get(1));
    try std.testing.expectEqual(@as(?u32, 20), cache.get(2));
}

test "sequential eviction order" {
    var cache = LruCache(u32).init(std.testing.allocator, 3);
    defer cache.deinit();

    try cache.put(1, 10);
    try cache.put(2, 20);
    try cache.put(3, 30);

    // Evict 1, then 2
    try cache.put(4, 40);
    try std.testing.expectEqual(@as(?u32, null), cache.get(1));

    try cache.put(5, 50);
    try std.testing.expectEqual(@as(?u32, null), cache.get(2));

    // 3, 4, 5 should remain
    try std.testing.expectEqual(@as(?u32, 30), cache.get(3));
    try std.testing.expectEqual(@as(?u32, 40), cache.get(4));
    try std.testing.expectEqual(@as(?u32, 50), cache.get(5));
}

// ── Edge case tests ─────────────────────────────────────────────────────────

test "get from empty cache returns null" {
    var cache = LruCache(u32).init(std.testing.allocator, 10);
    defer cache.deinit();

    try std.testing.expectEqual(@as(?u32, null), cache.get(0));
    try std.testing.expectEqual(@as(?u32, null), cache.get(1));
    try std.testing.expectEqual(@as(?u32, null), cache.get(std.math.maxInt(u64)));
    try std.testing.expectEqual(@as(usize, 0), cache.count());
}

test "put same key multiple times updates value each time" {
    var cache = LruCache(u32).init(std.testing.allocator, 4);
    defer cache.deinit();

    try cache.put(1, 100);
    try std.testing.expectEqual(@as(?u32, 100), cache.get(1));
    try std.testing.expectEqual(@as(usize, 1), cache.count());

    try cache.put(1, 200);
    try std.testing.expectEqual(@as(?u32, 200), cache.get(1));
    try std.testing.expectEqual(@as(usize, 1), cache.count());

    try cache.put(1, 300);
    try std.testing.expectEqual(@as(?u32, 300), cache.get(1));
    try std.testing.expectEqual(@as(usize, 1), cache.count());

    // Ensure only one entry exists
    try cache.put(1, 400);
    try std.testing.expectEqual(@as(usize, 1), cache.count());
    try std.testing.expectEqual(@as(?u32, 400), cache.get(1));
}

test "capacity=1 cycling through many keys" {
    var cache = LruCache(u32).init(std.testing.allocator, 1);
    defer cache.deinit();

    // Cycle through 20 different keys — each should evict the previous
    for (0..20) |i| {
        const key: u64 = @intCast(i);
        try cache.put(key, @intCast(i * 10));
        try std.testing.expectEqual(@as(usize, 1), cache.count());
        try std.testing.expectEqual(@as(u32, @intCast(i * 10)), cache.get(key).?);

        // Previous key should be gone
        if (i > 0) {
            try std.testing.expectEqual(@as(?u32, null), cache.get(key - 1));
        }
    }
}

test "put and immediately get returns correct value" {
    var cache = LruCache(u32).init(std.testing.allocator, 4);
    defer cache.deinit();

    try cache.put(42, 9999);
    try std.testing.expectEqual(@as(?u32, 9999), cache.get(42));

    try cache.put(0, 0);
    try std.testing.expectEqual(@as(?u32, 0), cache.get(0));

    try cache.put(std.math.maxInt(u64), std.math.maxInt(u32));
    try std.testing.expectEqual(@as(?u32, std.math.maxInt(u32)), cache.get(std.math.maxInt(u64)));
}

test "remove non-existent key returns false" {
    var cache = LruCache(u32).init(std.testing.allocator, 4);
    defer cache.deinit();

    try std.testing.expect(!cache.remove(1));
    try std.testing.expect(!cache.remove(0));
    try std.testing.expect(!cache.remove(std.math.maxInt(u64)));
    try std.testing.expectEqual(@as(usize, 0), cache.count());
}

test "fill cache exactly to capacity — no eviction needed" {
    var cache = LruCache(u32).init(std.testing.allocator, 5);
    defer cache.deinit();

    try cache.put(1, 10);
    try cache.put(2, 20);
    try cache.put(3, 30);
    try cache.put(4, 40);
    try cache.put(5, 50);

    try std.testing.expectEqual(@as(usize, 5), cache.count());

    // All entries should still be present
    try std.testing.expectEqual(@as(?u32, 10), cache.get(1));
    try std.testing.expectEqual(@as(?u32, 20), cache.get(2));
    try std.testing.expectEqual(@as(?u32, 30), cache.get(3));
    try std.testing.expectEqual(@as(?u32, 40), cache.get(4));
    try std.testing.expectEqual(@as(?u32, 50), cache.get(5));
}

test "clear already-empty cache" {
    var cache = LruCache(u32).init(std.testing.allocator, 4);
    defer cache.deinit();

    // Clear when empty
    cache.clear();
    try std.testing.expectEqual(@as(usize, 0), cache.count());
    try std.testing.expectEqual(@as(?u32, null), cache.get(1));

    // Clear again
    cache.clear();
    try std.testing.expectEqual(@as(usize, 0), cache.count());

    // Should still work after double clear
    try cache.put(1, 100);
    try std.testing.expectEqual(@as(?u32, 100), cache.get(1));
    try std.testing.expectEqual(@as(usize, 1), cache.count());
}

test "remove then re-add same key" {
    var cache = LruCache(u32).init(std.testing.allocator, 4);
    defer cache.deinit();

    try cache.put(1, 100);
    try std.testing.expect(cache.remove(1));
    try std.testing.expectEqual(@as(?u32, null), cache.get(1));
    try std.testing.expectEqual(@as(usize, 0), cache.count());

    try cache.put(1, 200);
    try std.testing.expectEqual(@as(?u32, 200), cache.get(1));
    try std.testing.expectEqual(@as(usize, 1), cache.count());
}

test "put update promotes to MRU (prevents eviction)" {
    var cache = LruCache(u32).init(std.testing.allocator, 3);
    defer cache.deinit();

    try cache.put(1, 10);
    try cache.put(2, 20);
    try cache.put(3, 30);

    // Update key 1 — should promote it to MRU
    try cache.put(1, 11);

    // Add key 4 — should evict key 2 (now LRU), not key 1
    try cache.put(4, 40);
    try std.testing.expectEqual(@as(?u32, 11), cache.get(1)); // updated and promoted
    try std.testing.expectEqual(@as(?u32, null), cache.get(2)); // evicted
    try std.testing.expectEqual(@as(?u32, 30), cache.get(3));
    try std.testing.expectEqual(@as(?u32, 40), cache.get(4));
}

test "remove head entry" {
    var cache = LruCache(u32).init(std.testing.allocator, 4);
    defer cache.deinit();

    try cache.put(1, 10);
    try cache.put(2, 20);
    try cache.put(3, 30); // 3 is head (MRU)

    try std.testing.expect(cache.remove(3)); // remove head
    try std.testing.expectEqual(@as(usize, 2), cache.count());
    try std.testing.expectEqual(@as(?u32, null), cache.get(3));
    try std.testing.expectEqual(@as(?u32, 10), cache.get(1));
    try std.testing.expectEqual(@as(?u32, 20), cache.get(2));
}

test "remove tail entry" {
    var cache = LruCache(u32).init(std.testing.allocator, 4);
    defer cache.deinit();

    try cache.put(1, 10); // 1 is tail (LRU)
    try cache.put(2, 20);
    try cache.put(3, 30);

    try std.testing.expect(cache.remove(1)); // remove tail
    try std.testing.expectEqual(@as(usize, 2), cache.count());
    try std.testing.expectEqual(@as(?u32, null), cache.get(1));
    try std.testing.expectEqual(@as(?u32, 20), cache.get(2));
    try std.testing.expectEqual(@as(?u32, 30), cache.get(3));
}

test "remove middle entry" {
    var cache = LruCache(u32).init(std.testing.allocator, 4);
    defer cache.deinit();

    try cache.put(1, 10);
    try cache.put(2, 20); // middle
    try cache.put(3, 30);

    try std.testing.expect(cache.remove(2)); // remove middle
    try std.testing.expectEqual(@as(usize, 2), cache.count());
    try std.testing.expectEqual(@as(?u32, null), cache.get(2));
    try std.testing.expectEqual(@as(?u32, 10), cache.get(1));
    try std.testing.expectEqual(@as(?u32, 30), cache.get(3));

    // Eviction still works after removing middle
    try cache.put(4, 40);
    try cache.put(5, 50);
    try std.testing.expectEqual(@as(usize, 4), cache.count());
}

test "large number of operations stress test" {
    var cache = LruCache(u32).init(std.testing.allocator, 10);
    defer cache.deinit();

    // Insert 100 keys into a cache of size 10
    for (0..100) |i| {
        try cache.put(@intCast(i), @intCast(i));
    }

    // Only last 10 should remain
    try std.testing.expectEqual(@as(usize, 10), cache.count());

    for (0..90) |i| {
        try std.testing.expectEqual(@as(?u32, null), cache.get(@intCast(i)));
    }
    for (90..100) |i| {
        try std.testing.expectEqual(@as(u32, @intCast(i)), cache.get(@intCast(i)).?);
    }
}
