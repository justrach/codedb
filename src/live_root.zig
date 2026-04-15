const std = @import("std");
const Explorer = @import("explore.zig").Explorer;
const Store = @import("store.zig").Store;
const watcher = @import("watcher.zig");
const snapshot_mod = @import("snapshot.zig");
const root_policy = @import("root_policy.zig");
const git_mod = @import("git.zig");
const index_mod = @import("index.zig");
const TrigramIndex = index_mod.TrigramIndex;
const MmapTrigramIndex = index_mod.MmapTrigramIndex;
const compat = @import("compat.zig");

// ── LiveRoot ────────────────────────────────────────────────
/// A single live-indexed project root with its own watcher.
///
/// Startup roots borrow their Explorer/Store from main.zig and do NOT own
/// the lifecycle of those objects.  Spawned roots own their data.
pub const LiveRoot = struct {
    path: []const u8,

    // Owned resources (for spawned roots)
    owned_explorer: ?Explorer = null,
    owned_store: ?Store = null,

    // Borrowed references (for startup root)
    borrowed_explorer: ?*Explorer = null,
    borrowed_store: ?*Store = null,

    queue: ?*watcher.EventQueue = null,
    watch_thread: ?std.Thread = null,
    scan_thread: ?std.Thread = null,
    shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    scan_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    alloc: std.mem.Allocator,

    /// true for the root passed at process startup (main.zig manages threads)
    is_startup_root: bool = false,

    // ── Accessors ───────────────────────────────────────────
    pub fn explorerPtr(self: *LiveRoot) *Explorer {
        if (self.borrowed_explorer) |e| return e;
        return &self.owned_explorer.?;
    }

    pub fn storePtr(self: *LiveRoot) *Store {
        if (self.borrowed_store) |s| return s;
        return &self.owned_store.?;
    }

    /// Convenience aliases
    pub fn explorer(self: *LiveRoot) *Explorer {
        return self.explorerPtr();
    }
    pub fn store(self: *LiveRoot) *Store {
        return self.storePtr();
    }

    // ── Constructors ────────────────────────────────────────

    /// Wrap the already-running startup explorer/store.
    /// Does NOT own the explorer/store (is_startup_root = true).
    /// Does NOT start threads — main.zig already did.
    pub fn initFromStartup(
        alloc: std.mem.Allocator,
        path: []const u8,
        startup_explorer: *Explorer,
        startup_store: *Store,
    ) LiveRoot {
        return .{
            .path = path,
            .borrowed_explorer = startup_explorer,
            .borrowed_store = startup_store,
            .alloc = alloc,
            .is_startup_root = true,
            .scan_done = std.atomic.Value(bool).init(true),
        };
    }

    /// Create a heap-allocated LiveRoot for a NEW workspace root.
    /// Initialises explorer/store, loads snapshot if available, and spawns
    /// watcher + (optionally) scan threads.
    pub fn initAndSpawn(alloc: std.mem.Allocator, path: []const u8) !*LiveRoot {
        const self = try alloc.create(LiveRoot);
        errdefer alloc.destroy(self);

        const duped_path = try alloc.dupe(u8, path);
        errdefer alloc.free(duped_path);

        self.* = .{
            .path = duped_path,
            .owned_explorer = Explorer.init(alloc),
            .owned_store = Store.init(alloc),
            .alloc = alloc,
        };

        // Set root dir on the explorer so relative file opens work.
        self.explorer().setRoot(duped_path);

        // Attempt snapshot load: try {path}/codedb.snapshot first, then
        // the global ~/.codedb/projects/{hash}/codedb.snapshot fallback.
        const snapshot_loaded = blk: {
            const local_snap = std.fmt.allocPrint(alloc, "{s}/codedb.snapshot", .{duped_path}) catch break :blk false;
            defer alloc.free(local_snap);
            if (snapshot_mod.loadSnapshot(local_snap, self.explorer(), self.store(), alloc))
                break :blk true;

            // Fallback: global data dir
            const global_snap = globalSnapshotPath(alloc, duped_path) catch break :blk false;
            defer alloc.free(global_snap);
            if (snapshot_mod.loadSnapshot(global_snap, self.explorer(), self.store(), alloc))
                break :blk true;

            break :blk false;
        };

        // If snapshot was loaded, try to load trigrams from disk too.
        if (snapshot_loaded) {
            loadTrigramFromDisk(self.explorer(), alloc, duped_path);
        }

        self.scan_done = std.atomic.Value(bool).init(snapshot_loaded);

        // Create event queue
        const queue = try alloc.create(watcher.EventQueue);
        queue.* = watcher.EventQueue{};
        self.queue = queue;

        // Spawn watcher thread
        self.watch_thread = try std.Thread.spawn(.{}, watcher.incrementalLoop, .{
            self.store(),
            self.explorer(),
            queue,
            duped_path,
            &self.shutdown,
            &self.scan_done,
        });

        // If no snapshot, spawn background initial scan
        if (!snapshot_loaded) {
            self.scan_thread = try std.Thread.spawn(.{}, scanWorker, .{
                self.store(),
                self.explorer(),
                duped_path,
                alloc,
                &self.scan_done,
                &self.shutdown,
            });
        }

        return self;
    }

    // ── Teardown ────────────────────────────────────────────
    pub fn deinit(self: *LiveRoot) void {
        if (self.is_startup_root) return; // main.zig manages lifecycle

        // Signal threads to stop
        self.shutdown.store(true, .release);

        if (self.watch_thread) |t| t.join();
        if (self.scan_thread) |t| t.join();

        if (self.owned_explorer != null) {
            var exp = &self.owned_explorer.?;
            exp.deinit();
        }
        if (self.owned_store != null) {
            var st = &self.owned_store.?;
            st.deinit();
        }
        if (self.queue) |q| self.alloc.destroy(q);
        self.alloc.free(self.path);
        self.alloc.destroy(self);
    }

    // ── Internal helpers ────────────────────────────────────

    fn scanWorker(
        st: *Store,
        exp: *Explorer,
        root: []const u8,
        allocator: std.mem.Allocator,
        scan_done: *std.atomic.Value(bool),
        shutdown: *std.atomic.Value(bool),
    ) void {
        watcher.initialScan(st, exp, root, allocator, false) catch |err| {
            std.log.warn("live_root: background scan failed for {s}: {}", .{ root, err });
        };
        if (shutdown.load(.acquire)) {
            scan_done.store(true, .release);
            return;
        }
        scan_done.store(true, .release);
    }
};

// ── LiveRootManager ─────────────────────────────────────────
/// Manages up to MAX_ROOTS LiveRoots (1 startup + up to 7 workspace roots).
pub const LiveRootManager = struct {
    const MAX_ROOTS: usize = 8;

    roots: [MAX_ROOTS]?*LiveRoot = [_]?*LiveRoot{null} ** MAX_ROOTS,
    startup_root: LiveRoot,
    startup_path: []const u8,
    mu: std.Thread.RwLock = .{},
    alloc: std.mem.Allocator,

    pub fn init(
        alloc: std.mem.Allocator,
        startup_path: []const u8,
        startup_explorer: *Explorer,
        startup_store: *Store,
    ) LiveRootManager {
        return .{
            .startup_root = LiveRoot.initFromStartup(alloc, startup_path, startup_explorer, startup_store),
            .startup_path = startup_path,
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *LiveRootManager) void {
        self.mu.lock();
        defer self.mu.unlock();
        for (&self.roots) |*slot| {
            if (slot.*) |root| {
                root.deinit();
                slot.* = null;
            }
        }
    }

    /// Returns the startup root.
    pub fn getStartup(self: *LiveRootManager) *LiveRoot {
        return &self.startup_root;
    }

    /// Given an absolute path (or null for default), find the matching LiveRoot.
    /// Falls back to startup root if no match is found.
    pub fn resolve(self: *LiveRootManager, path: ?[]const u8) *LiveRoot {
        const p = path orelse return &self.startup_root;
        if (std.mem.eql(u8, p, self.startup_path)) return &self.startup_root;

        self.mu.lockShared();
        defer self.mu.unlockShared();

        // Find the best (longest prefix) match among registered roots.
        var best: ?*LiveRoot = null;
        var best_len: usize = 0;
        for (self.roots) |maybe_root| {
            const root = maybe_root orelse continue;
            if (isPathPrefixOf(root.path, p) and root.path.len > best_len) {
                best = root;
                best_len = root.path.len;
            }
        }
        // Also check startup root as a prefix match
        if (isPathPrefixOf(self.startup_path, p) and self.startup_path.len > best_len) {
            return &self.startup_root;
        }
        return best orelse &self.startup_root;
    }

    /// Add a new workspace root (called when roots/list_changed adds a root).
    /// Skips if path == startup_path, already exists, or slots are full.
    pub fn addRoot(self: *LiveRootManager, path: []const u8) !void {
        if (std.mem.eql(u8, path, self.startup_path)) return;
        if (!root_policy.isIndexableRoot(path)) return;

        self.mu.lock();
        defer self.mu.unlock();

        // Check if already registered
        for (self.roots) |maybe_root| {
            const root = maybe_root orelse continue;
            if (std.mem.eql(u8, root.path, path)) return;
        }

        // Find a free slot
        for (&self.roots) |*slot| {
            if (slot.* == null) {
                slot.* = try LiveRoot.initAndSpawn(self.alloc, path);
                return;
            }
        }

        // All slots full — skip for now (future: evict LRU)
        std.log.warn("live_root: all {d} root slots occupied, cannot add {s}", .{ MAX_ROOTS, path });
    }

    /// Remove a workspace root (never removes startup).
    pub fn removeRoot(self: *LiveRootManager, path: []const u8) void {
        if (std.mem.eql(u8, path, self.startup_path)) return;

        self.mu.lock();
        defer self.mu.unlock();

        for (&self.roots) |*slot| {
            if (slot.*) |root| {
                if (std.mem.eql(u8, root.path, path)) {
                    root.deinit();
                    slot.* = null;
                    return;
                }
            }
        }
    }

    /// Reconcile roots list from MCP `roots/list` response.
    /// Adds roots in new_roots that don't exist, removes non-startup roots
    /// that aren't in new_roots.
    pub fn syncRoots(self: *LiveRootManager, new_roots: []const []const u8) void {
        // Phase 1: Remove roots not in the new list (skip startup)
        {
            self.mu.lock();
            defer self.mu.unlock();
            for (&self.roots) |*slot| {
                if (slot.*) |root| {
                    if (!containsPath(new_roots, root.path)) {
                        root.deinit();
                        slot.* = null;
                    }
                }
            }
        }

        // Phase 2: Add new roots (addRoot acquires lock internally)
        for (new_roots) |r| {
            self.addRoot(r) catch |err| {
                std.log.warn("live_root: failed to add root {s}: {}", .{ r, err });
            };
        }
    }

    /// Returns startup_path.
    pub fn defaultPath(self: *LiveRootManager) []const u8 {
        return self.startup_path;
    }
};

// ── Module-private helpers ──────────────────────────────────

/// Returns true if `prefix` is a path prefix of `full_path`.
/// i.e. full_path starts with prefix and the next char is '/' or end-of-string.
fn isPathPrefixOf(prefix: []const u8, full_path: []const u8) bool {
    if (!std.mem.startsWith(u8, full_path, prefix)) return false;
    return full_path.len == prefix.len or full_path[prefix.len] == '/';
}

/// Check whether `paths` contains `target`.
fn containsPath(paths: []const []const u8, target: []const u8) bool {
    for (paths) |p| {
        if (std.mem.eql(u8, p, target)) return true;
    }
    return false;
}

/// Build the global snapshot fallback path:
/// ~/.codedb/projects/{hash}/codedb.snapshot
fn globalSnapshotPath(alloc: std.mem.Allocator, root_path: []const u8) ![]u8 {
    const hash = std.hash.Wyhash.hash(0, root_path);
    const home = try std.process.getEnvVarOwned(alloc, "HOME");
    defer alloc.free(home);
    return std.fmt.allocPrint(alloc, "{s}/.codedb/projects/{x}/codedb.snapshot", .{ home, hash });
}

/// Build the global data directory path:
/// ~/.codedb/projects/{hash}
fn globalDataDir(alloc: std.mem.Allocator, root_path: []const u8) ![]u8 {
    const hash = std.hash.Wyhash.hash(0, root_path);
    const home = try std.process.getEnvVarOwned(alloc, "HOME");
    defer alloc.free(home);
    return std.fmt.allocPrint(alloc, "{s}/.codedb/projects/{x}", .{ home, hash });
}

/// Try to load trigram index from disk (mmap first, then heap fallback).
fn loadTrigramFromDisk(exp: *Explorer, alloc: std.mem.Allocator, root_path: []const u8) void {
    exp.mu.lockShared();
    const already_loaded = exp.trigram_index.fileCount() > 0;
    exp.mu.unlockShared();
    if (already_loaded) return;

    const data_dir = globalDataDir(alloc, root_path) catch return;
    defer alloc.free(data_dir);

    if (MmapTrigramIndex.initFromDisk(data_dir, alloc)) |loaded| {
        exp.mu.lock();
        defer exp.mu.unlock();
        exp.trigram_index.deinit();
        exp.trigram_index = .{ .mmap = loaded };
    } else if (TrigramIndex.readFromDisk(data_dir, alloc)) |loaded| {
        exp.mu.lock();
        defer exp.mu.unlock();
        exp.trigram_index.deinit();
        exp.trigram_index = .{ .heap = loaded };
    }
}

// ── Tests ───────────────────────────────────────────────────

test "isPathPrefixOf basic" {
    const testing = std.testing;
    try testing.expect(isPathPrefixOf("/foo/bar", "/foo/bar"));
    try testing.expect(isPathPrefixOf("/foo/bar", "/foo/bar/baz"));
    try testing.expect(!isPathPrefixOf("/foo/bar", "/foo/barbaz"));
    try testing.expect(!isPathPrefixOf("/foo/bar", "/other"));
}

test "containsPath" {
    const testing = std.testing;
    const paths = [_][]const u8{ "/a", "/b/c", "/d" };
    try testing.expect(containsPath(&paths, "/a"));
    try testing.expect(containsPath(&paths, "/b/c"));
    try testing.expect(!containsPath(&paths, "/x"));
}
