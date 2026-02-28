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
