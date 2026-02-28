// Multi-Tenant Model — per-repo isolation with MRSW concurrency
//
// Each repository gets its own isolated CodeGraph instance with a
// dedicated directory layout:
//
//   .codegraph/
//     repos/
//       <repo-hash>/
//         graph.bin      — serialized CodeGraph
//         wal.log        — write-ahead log
//         meta.json      — repo metadata (path, name, last sync)
//
// Concurrency model: Multiple-Reader Single-Writer (MRSW)
//   - Multiple concurrent reads are allowed
//   - Writes acquire exclusive access
//   - Implemented via a read-write lock (rwlock)

const std = @import("std");

// ── Constants ───────────────────────────────────────────────────────────────

pub const BASE_DIR = ".codegraph/repos";
pub const GRAPH_FILE = "graph.bin";
pub const WAL_FILE = "wal.log";
pub const META_FILE = "meta.json";
pub const MAX_REPOS: u32 = 256;

// ── RepoHandle ──────────────────────────────────────────────────────────────

pub const RepoHandle = struct {
    id: u32,
    name: []const u8,
    path: []const u8, // absolute path to repo root
    dir_hash: [16]u8, // first 16 bytes of path hash for directory name
    readers: u32,
    writer_active: bool,
    last_sync_ms: i64,
};

/// Compute a stable directory hash from a repo path.
pub fn hashRepoPath(path: []const u8) [16]u8 {
    // Use SipHash for fast, collision-resistant hashing
    const full = std.hash.Wyhash.hash(0, path);
    var result: [16]u8 = undefined;
    std.mem.writeInt(u64, result[0..8], full, .little);
    // Second half: hash with different seed for more bits
    const full2 = std.hash.Wyhash.hash(1, path);
    std.mem.writeInt(u64, result[8..16], full2, .little);
    return result;
}

/// Format a dir hash as a hex string for filesystem use.
pub fn hashToHex(hash: [16]u8) [32]u8 {
    const hex = "0123456789abcdef";
    var result: [32]u8 = undefined;
    for (hash, 0..) |byte, i| {
        result[i * 2] = hex[byte >> 4];
        result[i * 2 + 1] = hex[byte & 0x0f];
    }
    return result;
}

// ── TenantManager ───────────────────────────────────────────────────────────

pub const TenantManager = struct {
    repos: std.AutoHashMap(u32, RepoHandle),
    path_to_id: std.StringHashMap(u32),
    next_id: u32,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) TenantManager {
        return .{
            .repos = std.AutoHashMap(u32, RepoHandle).init(alloc),
            .path_to_id = std.StringHashMap(u32).init(alloc),
            .next_id = 1,
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *TenantManager) void {
        // Free duped strings
        var it = self.repos.iterator();
        while (it.next()) |kv| {
            self.alloc.free(kv.value_ptr.name);
            self.alloc.free(kv.value_ptr.path);
        }
        self.repos.deinit();
        // path_to_id keys are same pointers as repos.path, already freed
        self.path_to_id.deinit();
    }

    /// Register a new repository. Returns the assigned repo ID.
    pub fn registerRepo(self: *TenantManager, name: []const u8, path: []const u8) !u32 {
        if (self.repos.count() >= MAX_REPOS) return error.TooManyRepos;

        // Check for duplicate path
        if (self.path_to_id.get(path)) |_| return error.DuplicateRepo;

        const id = self.next_id;
        self.next_id += 1;

        const duped_name = try self.alloc.dupe(u8, name);
        errdefer self.alloc.free(duped_name);
        const duped_path = try self.alloc.dupe(u8, path);
        errdefer self.alloc.free(duped_path);

        const handle = RepoHandle{
            .id = id,
            .name = duped_name,
            .path = duped_path,
            .dir_hash = hashRepoPath(path),
            .readers = 0,
            .writer_active = false,
            .last_sync_ms = 0,
        };

        try self.repos.put(id, handle);
        try self.path_to_id.put(duped_path, id);

        return id;
    }

    /// Unregister a repository.
    pub fn unregisterRepo(self: *TenantManager, repo_id: u32) !void {
        const handle = self.repos.get(repo_id) orelse return error.RepoNotFound;
        if (handle.readers > 0 or handle.writer_active) return error.RepoBusy;

        _ = self.path_to_id.remove(handle.path);
        self.alloc.free(handle.name);
        self.alloc.free(handle.path);
        _ = self.repos.remove(repo_id);
    }

    /// Look up a repo by its filesystem path.
    pub fn findByPath(self: *const TenantManager, path: []const u8) ?u32 {
        return self.path_to_id.get(path);
    }

    /// Get a repo handle (read-only).
    pub fn getRepo(self: *const TenantManager, repo_id: u32) ?RepoHandle {
        return self.repos.get(repo_id);
    }

    /// Acquire a read lock. Multiple readers allowed.
    pub fn acquireRead(self: *TenantManager, repo_id: u32) !void {
        const handle = self.repos.getPtr(repo_id) orelse return error.RepoNotFound;
        if (handle.writer_active) return error.WriteLocked;
        handle.readers += 1;
    }

    /// Release a read lock.
    pub fn releaseRead(self: *TenantManager, repo_id: u32) void {
        const handle = self.repos.getPtr(repo_id) orelse return;
        if (handle.readers > 0) handle.readers -= 1;
    }

    /// Acquire an exclusive write lock. Fails if any readers or writer active.
    pub fn acquireWrite(self: *TenantManager, repo_id: u32) !void {
        const handle = self.repos.getPtr(repo_id) orelse return error.RepoNotFound;
        if (handle.writer_active) return error.WriteLocked;
        if (handle.readers > 0) return error.ReadLocked;
        handle.writer_active = true;
    }

    /// Release the write lock.
    pub fn releaseWrite(self: *TenantManager, repo_id: u32) void {
        const handle = self.repos.getPtr(repo_id) orelse return;
        handle.writer_active = false;
    }

    /// Get the data directory path for a repo.
    /// Returns a path like ".codegraph/repos/<hex-hash>".
    /// Caller owns the returned slice.
    pub fn repoDataDir(self: *const TenantManager, repo_id: u32) ![]u8 {
        const handle = self.repos.get(repo_id) orelse return error.RepoNotFound;
        const hex = hashToHex(handle.dir_hash);
        return std.fs.path.join(self.alloc, &.{ BASE_DIR, &hex });
    }

    /// Get the graph file path for a repo. Caller owns the returned slice.
    pub fn repoGraphPath(self: *const TenantManager, repo_id: u32) ![]u8 {
        const dir = try self.repoDataDir(repo_id);
        defer self.alloc.free(dir);
        return std.fs.path.join(self.alloc, &.{ dir, GRAPH_FILE });
    }

    /// Get the WAL file path for a repo. Caller owns the returned slice.
    pub fn repoWalPath(self: *const TenantManager, repo_id: u32) ![]u8 {
        const dir = try self.repoDataDir(repo_id);
        defer self.alloc.free(dir);
        return std.fs.path.join(self.alloc, &.{ dir, WAL_FILE });
    }

    /// Update the last sync timestamp for a repo.
    pub fn markSynced(self: *TenantManager, repo_id: u32, now_ms: i64) void {
        const handle = self.repos.getPtr(repo_id) orelse return;
        handle.last_sync_ms = now_ms;
    }

    /// Total number of registered repos.
    pub fn count(self: *const TenantManager) u32 {
        return @intCast(self.repos.count());
    }

    /// List all repo IDs.
    pub fn listRepoIds(self: *const TenantManager) ![]u32 {
        var ids = try self.alloc.alloc(u32, self.repos.count());
        var i: usize = 0;
        var it = self.repos.iterator();
        while (it.next()) |kv| {
            ids[i] = kv.key_ptr.*;
            i += 1;
        }
        return ids;
    }
};

// ── Tests ───────────────────────────────────────────────────────────────────

test "register and lookup repo" {
    var tm = TenantManager.init(std.testing.allocator);
    defer tm.deinit();

    const id = try tm.registerRepo("my-app", "/home/user/my-app");
    try std.testing.expectEqual(@as(u32, 1), id);
    try std.testing.expectEqual(@as(u32, 1), tm.count());

    const handle = tm.getRepo(id).?;
    try std.testing.expectEqualStrings("my-app", handle.name);
    try std.testing.expectEqualStrings("/home/user/my-app", handle.path);
}

test "find repo by path" {
    var tm = TenantManager.init(std.testing.allocator);
    defer tm.deinit();

    const id = try tm.registerRepo("app", "/repos/app");
    try std.testing.expectEqual(id, tm.findByPath("/repos/app").?);
    try std.testing.expectEqual(@as(?u32, null), tm.findByPath("/repos/other"));
}

test "duplicate path rejected" {
    var tm = TenantManager.init(std.testing.allocator);
    defer tm.deinit();

    _ = try tm.registerRepo("app1", "/repos/shared");
    const result = tm.registerRepo("app2", "/repos/shared");
    try std.testing.expectError(error.DuplicateRepo, result);
}

test "unregister repo" {
    var tm = TenantManager.init(std.testing.allocator);
    defer tm.deinit();

    const id = try tm.registerRepo("app", "/repos/app");
    try tm.unregisterRepo(id);
    try std.testing.expectEqual(@as(u32, 0), tm.count());
    try std.testing.expectEqual(@as(?u32, null), tm.findByPath("/repos/app"));
}

test "unregister busy repo fails" {
    var tm = TenantManager.init(std.testing.allocator);
    defer tm.deinit();

    const id = try tm.registerRepo("app", "/repos/app");
    try tm.acquireRead(id);
    try std.testing.expectError(error.RepoBusy, tm.unregisterRepo(id));
    tm.releaseRead(id);
}

test "MRSW: multiple readers allowed" {
    var tm = TenantManager.init(std.testing.allocator);
    defer tm.deinit();

    const id = try tm.registerRepo("app", "/repos/app");
    try tm.acquireRead(id);
    try tm.acquireRead(id);
    try tm.acquireRead(id);

    const handle = tm.getRepo(id).?;
    try std.testing.expectEqual(@as(u32, 3), handle.readers);

    tm.releaseRead(id);
    tm.releaseRead(id);
    tm.releaseRead(id);
}

test "MRSW: write blocks on readers" {
    var tm = TenantManager.init(std.testing.allocator);
    defer tm.deinit();

    const id = try tm.registerRepo("app", "/repos/app");
    try tm.acquireRead(id);
    try std.testing.expectError(error.ReadLocked, tm.acquireWrite(id));
    tm.releaseRead(id);

    // Now write should work
    try tm.acquireWrite(id);
    tm.releaseWrite(id);
}

test "MRSW: read blocks on writer" {
    var tm = TenantManager.init(std.testing.allocator);
    defer tm.deinit();

    const id = try tm.registerRepo("app", "/repos/app");
    try tm.acquireWrite(id);
    try std.testing.expectError(error.WriteLocked, tm.acquireRead(id));
    tm.releaseWrite(id);
}

test "MRSW: double write blocked" {
    var tm = TenantManager.init(std.testing.allocator);
    defer tm.deinit();

    const id = try tm.registerRepo("app", "/repos/app");
    try tm.acquireWrite(id);
    try std.testing.expectError(error.WriteLocked, tm.acquireWrite(id));
    tm.releaseWrite(id);
}

test "repo data dir uses hash" {
    var tm = TenantManager.init(std.testing.allocator);
    defer tm.deinit();

    const id = try tm.registerRepo("app", "/repos/app");
    const dir = try tm.repoDataDir(id);
    defer std.testing.allocator.free(dir);

    // Should start with base dir
    try std.testing.expect(std.mem.startsWith(u8, dir, BASE_DIR));
}

test "different paths get different hashes" {
    const h1 = hashRepoPath("/repos/app1");
    const h2 = hashRepoPath("/repos/app2");
    try std.testing.expect(!std.mem.eql(u8, &h1, &h2));
}

test "hashToHex produces valid hex" {
    const hash = hashRepoPath("/test");
    const hex = hashToHex(hash);
    for (hex) |c| {
        try std.testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
}

test "markSynced updates timestamp" {
    var tm = TenantManager.init(std.testing.allocator);
    defer tm.deinit();

    const id = try tm.registerRepo("app", "/repos/app");
    tm.markSynced(id, 42000);
    try std.testing.expectEqual(@as(i64, 42000), tm.getRepo(id).?.last_sync_ms);
}

test "listRepoIds returns all ids" {
    var tm = TenantManager.init(std.testing.allocator);
    defer tm.deinit();

    _ = try tm.registerRepo("a", "/a");
    _ = try tm.registerRepo("b", "/b");

    const ids = try tm.listRepoIds();
    defer std.testing.allocator.free(ids);
    try std.testing.expectEqual(@as(usize, 2), ids.len);
}

test "constants are reasonable" {
    try std.testing.expectEqual(@as(u32, 256), MAX_REPOS);
    try std.testing.expectEqualStrings("graph.bin", GRAPH_FILE);
    try std.testing.expectEqualStrings("wal.log", WAL_FILE);
}

// ── Edge case tests ─────────────────────────────────────────────────────────

test "register MAX_REPOS+1 repos returns TooManyRepos" {
    var tm = TenantManager.init(std.testing.allocator);
    defer tm.deinit();

    // Register exactly MAX_REPOS repos
    for (0..MAX_REPOS) |i| {
        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/repo/{d}", .{i}) catch unreachable;
        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "repo-{d}", .{i}) catch unreachable;
        _ = try tm.registerRepo(name, path);
    }
    try std.testing.expectEqual(@as(u32, MAX_REPOS), tm.count());

    // The next registration should fail
    const result = tm.registerRepo("overflow", "/repo/overflow");
    try std.testing.expectError(error.TooManyRepos, result);
}

test "unregister nonexistent repo returns RepoNotFound" {
    var tm = TenantManager.init(std.testing.allocator);
    defer tm.deinit();

    const result = tm.unregisterRepo(999);
    try std.testing.expectError(error.RepoNotFound, result);
}

test "releaseRead more times than acquired does not underflow" {
    var tm = TenantManager.init(std.testing.allocator);
    defer tm.deinit();

    const id = try tm.registerRepo("app", "/repos/app");
    try tm.acquireRead(id);
    // readers = 1

    tm.releaseRead(id);
    // readers = 0

    // Extra release — should not underflow (the guard prevents it)
    tm.releaseRead(id);

    const handle = tm.getRepo(id).?;
    try std.testing.expectEqual(@as(u32, 0), handle.readers);
}

test "concurrent reads followed by write attempt fails" {
    var tm = TenantManager.init(std.testing.allocator);
    defer tm.deinit();

    const id = try tm.registerRepo("app", "/repos/app");
    try tm.acquireRead(id);
    try tm.acquireRead(id);
    try tm.acquireRead(id);

    // Write should fail while readers are active
    try std.testing.expectError(error.ReadLocked, tm.acquireWrite(id));

    // Release all readers
    tm.releaseRead(id);
    tm.releaseRead(id);
    tm.releaseRead(id);

    // Now write should succeed
    try tm.acquireWrite(id);
    tm.releaseWrite(id);
}

test "path lookup after unregister returns null" {
    var tm = TenantManager.init(std.testing.allocator);
    defer tm.deinit();

    const id = try tm.registerRepo("app", "/repos/app");
    try std.testing.expect(tm.findByPath("/repos/app") != null);

    try tm.unregisterRepo(id);
    try std.testing.expectEqual(@as(?u32, null), tm.findByPath("/repos/app"));
}

test "repo with empty name and path" {
    var tm = TenantManager.init(std.testing.allocator);
    defer tm.deinit();

    const id = try tm.registerRepo("", "");
    const handle = tm.getRepo(id).?;
    try std.testing.expectEqualStrings("", handle.name);
    try std.testing.expectEqualStrings("", handle.path);
}

test "multiple markSynced calls update correctly" {
    var tm = TenantManager.init(std.testing.allocator);
    defer tm.deinit();

    const id = try tm.registerRepo("app", "/repos/app");

    tm.markSynced(id, 1000);
    try std.testing.expectEqual(@as(i64, 1000), tm.getRepo(id).?.last_sync_ms);

    tm.markSynced(id, 2000);
    try std.testing.expectEqual(@as(i64, 2000), tm.getRepo(id).?.last_sync_ms);

    tm.markSynced(id, 3000);
    try std.testing.expectEqual(@as(i64, 3000), tm.getRepo(id).?.last_sync_ms);
}

test "markSynced on nonexistent repo is no-op" {
    var tm = TenantManager.init(std.testing.allocator);
    defer tm.deinit();

    // Should not crash — function silently returns
    tm.markSynced(999, 42000);
}

test "listRepoIds on empty manager returns empty" {
    var tm = TenantManager.init(std.testing.allocator);
    defer tm.deinit();

    const ids = try tm.listRepoIds();
    defer std.testing.allocator.free(ids);
    try std.testing.expectEqual(@as(usize, 0), ids.len);
}

test "acquireRead on nonexistent repo returns RepoNotFound" {
    var tm = TenantManager.init(std.testing.allocator);
    defer tm.deinit();

    try std.testing.expectError(error.RepoNotFound, tm.acquireRead(999));
}

test "acquireWrite on nonexistent repo returns RepoNotFound" {
    var tm = TenantManager.init(std.testing.allocator);
    defer tm.deinit();

    try std.testing.expectError(error.RepoNotFound, tm.acquireWrite(999));
}

test "releaseWrite on nonexistent repo is no-op" {
    var tm = TenantManager.init(std.testing.allocator);
    defer tm.deinit();

    // Should not crash
    tm.releaseWrite(999);
}

test "releaseRead on nonexistent repo is no-op" {
    var tm = TenantManager.init(std.testing.allocator);
    defer tm.deinit();

    // Should not crash
    tm.releaseRead(999);
}

test "repoDataDir on nonexistent repo returns error" {
    var tm = TenantManager.init(std.testing.allocator);
    defer tm.deinit();

    try std.testing.expectError(error.RepoNotFound, tm.repoDataDir(999));
}

test "re-register path after unregister succeeds" {
    var tm = TenantManager.init(std.testing.allocator);
    defer tm.deinit();

    const id1 = try tm.registerRepo("app", "/repos/app");
    try tm.unregisterRepo(id1);

    // Same path should now be allowed again
    const id2 = try tm.registerRepo("app-v2", "/repos/app");
    try std.testing.expect(id2 != id1); // new ID assigned
    try std.testing.expectEqualStrings("app-v2", tm.getRepo(id2).?.name);
}
