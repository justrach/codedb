const std = @import("std");
const cio = @import("cio.zig");
const AgentId = @import("agent.zig").AgentId;
const version = @import("version.zig");
const Version = version.Version;
const FileVersions = version.FileVersions;
const Op = version.Op;

pub const ChangeEntry = struct {
    path: []const u8,
    seq: u64,
    op: Op,
    size: u64,
    timestamp: i64,
};

pub const Store = struct {
    files: std.StringHashMap(FileVersions),
    /// Last observed file mtime (ms). Process-local: lets refreshIndex skip
    /// unread files after the first reconcile without changing Version.
    mtimes: std.StringHashMap(i64),
    seq: u64,
    allocator: std.mem.Allocator,
    mu: cio.Mutex = .{},
    data_log: ?std.Io.File = null,
    data_log_pos: u64 = 0,
    io: ?std.Io = null,
    /// Cap per-file version history. Configurable via .codedbrc (#101).
    max_versions: usize = 100,
    /// Compact the diff data log once it exceeds this and at least half of it
    /// is orphaned bytes (#597).
    compact_min: u64 = 16 * 1024 * 1024,
    /// High-water mark for the next compaction check (exponential back-off).
    next_compact_check: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{
            .files = std.StringHashMap(FileVersions).init(allocator),
            .mtimes = std.StringHashMap(i64).init(allocator),
            .seq = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Store) void {
        var iter = self.files.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.path);
            entry.value_ptr.deinit();
        }
        self.files.deinit();
        var miter = self.mtimes.iterator();
        while (miter.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.mtimes.deinit();
        if (self.data_log) |f| {
            if (self.io) |io| f.close(io);
        }
    }

    pub fn openDataLog(self: *Store, io: std.Io, path: []const u8) !void {
        // Extract parent dir and ensure it exists
        if (std.mem.lastIndexOfScalar(u8, path, '/')) |sep| {
            std.Io.Dir.cwd().createDirPath(io, path[0..sep]) catch {};
        }
        // Truncate on open: in-memory index is empty at process start and nothing
        // replays this file, so any pre-existing bytes are unreachable orphans
        // (see #367 — raw edit content would otherwise leak across sessions).
        const file = try std.Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = true });
        self.data_log = file;
        self.io = io;
        self.data_log_pos = 0;
    }

    pub fn recordSnapshot(self: *Store, path: []const u8, size: u64, hash: u64) !u64 {
        return self.appendVersion(path, 0, .snapshot, hash, size, null);
    }

    /// Replace the placeholder identity recorded by the cold stat pass once
    /// the parser worker has read the file. This is deliberately not a new
    /// version/event: initial discovery already advanced `seq`, and consumers
    /// must observe one stable snapshot whose content hash survives reload.
    pub fn refineLatestSnapshotHash(self: *Store, path: []const u8, size: u64, hash: u64) bool {
        if (hash == 0) return false;
        self.mu.lock();
        defer self.mu.unlock();
        const versions = self.files.getPtr(path) orelse return false;
        if (versions.versions.items.len == 0) return false;
        const latest = &versions.versions.items[versions.versions.items.len - 1];
        if (latest.op != .snapshot or latest.size != size or latest.hash != 0) return false;
        latest.hash = hash;
        return true;
    }

    pub fn recordEdit(self: *Store, path: []const u8, agent: AgentId, op: Op, hash: u64, size: u64, diff: ?[]const u8) !u64 {
        return self.appendVersion(path, agent, op, hash, size, diff);
    }

    pub fn recordDelete(self: *Store, path: []const u8, agent: AgentId) !u64 {
        return self.appendVersion(path, agent, .tombstone, 0, 0, null);
    }

    fn appendVersion(self: *Store, path: []const u8, agent: AgentId, op: Op, hash: u64, size: u64, diff: ?[]const u8) !u64 {
        self.mu.lock();
        defer self.mu.unlock();

        self.seq += 1;
        const next_seq = self.seq;

        const entry = try self.files.getOrPut(path);
        if (!entry.found_existing) {
            errdefer self.files.removeByPtr(entry.key_ptr);
            const duped = try self.allocator.dupe(u8, path);
            entry.key_ptr.* = duped;
            entry.value_ptr.* = FileVersions.init(self.allocator, duped);
        }

        var data_offset: ?u64 = null;
        var data_len: u32 = 0;
        if (diff) |d| {
            if (self.data_log) |log| {
                const io = self.io orelse return error.Unexpected;
                // Advisory lock for cross-process safety. If it cannot be
                // acquired, skip the diff persist rather than write unlocked
                // (#597) — the version still records with data_offset = null.
                const locked = blk: {
                    log.lock(io, .exclusive) catch break :blk false;
                    break :blk true;
                };
                if (locked) {
                    defer log.unlock(io);

                    // Re-stat to get current end position (another process may have appended)
                    const end_pos = log.length(io) catch return error.Unexpected;
                    self.data_log_pos = end_pos;

                    data_offset = self.data_log_pos;
                    data_len = @intCast(d.len);
                    try log.writePositionalAll(io, d, self.data_log_pos);
                    self.data_log_pos += d.len;
                }
            }
        }

        try entry.value_ptr.versions.append(self.allocator, .{
            .seq = next_seq,
            .agent = agent,
            .timestamp = cio.milliTimestamp(),
            .op = op,
            .hash = hash,
            .size = size,
            .data_offset = data_offset,
            .data_len = data_len,
        });

        // Cap version history to prevent unbounded growth. User-configurable
        // via .codedbrc (see #101).
        const max_versions = self.max_versions;
        if (entry.value_ptr.versions.items.len > max_versions) {
            const excess = entry.value_ptr.versions.items.len - max_versions;
            // Single-pass O(n) shift: avoids replaceRange allocator overhead
            std.mem.copyForwards(Version, entry.value_ptr.versions.items[0..max_versions], entry.value_ptr.versions.items[excess..]);
            entry.value_ptr.versions.items.len = max_versions;
        }

        self.maybeCompactDataLog();

        return next_seq;
    }

    /// Compact when the data log is past compact_min and at least half of it
    /// is orphaned diff bytes (versions trimmed by max_versions). Checks back
    /// off exponentially so the live-bytes scan stays amortized. Caller must
    /// hold self.mu.
    fn maybeCompactDataLog(self: *Store) void {
        if (self.data_log == null) return;
        if (self.data_log_pos < @max(self.compact_min, self.next_compact_check)) return;
        if (self.liveDataBytes() * 2 <= self.data_log_pos) {
            self.compactDataLog() catch {};
        }
        self.next_compact_check = self.data_log_pos * 2;
    }

    fn liveDataBytes(self: *Store) u64 {
        var total: u64 = 0;
        var iter = self.files.iterator();
        while (iter.next()) |entry| {
            for (entry.value_ptr.versions.items) |v| {
                if (v.data_offset != null) total += v.data_len;
            }
        }
        return total;
    }

    /// Rewrite live diff ranges to the front of the data log, update the
    /// version offsets in place, and truncate the orphaned tail. Ranges are
    /// processed in ascending offset order so data only ever moves down, and
    /// each range is buffered whole before its write, so overlap is safe.
    /// Bailing midway leaves a consistent log (moved versions point at their
    /// new offsets, unmoved at their old ones; nothing truncated yet).
    /// Caller must hold self.mu.
    fn compactDataLog(self: *Store) !void {
        const log = self.data_log orelse return;
        const io = self.io orelse return;

        log.lock(io, .exclusive) catch return;
        defer log.unlock(io);

        var live: std.ArrayList(*Version) = .empty;
        defer live.deinit(self.allocator);
        var iter = self.files.iterator();
        while (iter.next()) |entry| {
            for (entry.value_ptr.versions.items) |*v| {
                if (v.data_offset != null) try live.append(self.allocator, v);
            }
        }
        std.mem.sort(*Version, live.items, {}, struct {
            fn lt(_: void, a: *Version, b: *Version) bool {
                return a.data_offset.? < b.data_offset.?;
            }
        }.lt);

        var write_pos: u64 = 0;
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        for (live.items) |v| {
            const off = v.data_offset.?;
            const len: usize = v.data_len;
            if (off != write_pos) {
                try buf.resize(self.allocator, len);
                if (try log.readPositionalAll(io, buf.items, off) != len) return error.Unexpected;
                try log.writePositionalAll(io, buf.items, write_pos);
                v.data_offset = write_pos;
            }
            write_pos += len;
        }
        try log.setLength(io, write_pos);
        self.data_log_pos = write_pos;
    }

    pub fn noteMtime(self: *Store, path: []const u8, mtime: i64) void {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.mtimes.getPtr(path)) |slot| {
            slot.* = mtime;
            return;
        }
        const key = self.allocator.dupe(u8, path) catch return;
        self.mtimes.put(key, mtime) catch self.allocator.free(key);
    }

    pub fn getMtime(self: *Store, path: []const u8) ?i64 {
        self.mu.lock();
        defer self.mu.unlock();
        return self.mtimes.get(path);
    }

    pub fn forgetMtime(self: *Store, path: []const u8) void {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.mtimes.fetchRemove(path)) |kv| self.allocator.free(kv.key);
    }

    pub fn getLatest(self: *Store, path: []const u8) ?Version {
        self.mu.lock();
        defer self.mu.unlock();
        const fv = self.files.get(path) orelse return null;
        return fv.latest();
    }

    /// Get latest version seq for a path. Caller must hold self.mu.
    pub fn getLatestSeqUnlocked(self: *Store, path: []const u8) u64 {
        const fv = self.files.get(path) orelse return 0;
        const v = fv.latest() orelse return 0;
        return v.seq;
    }

    pub fn getAtCursor(self: *Store, path: []const u8, cursor: u64) ?Version {
        self.mu.lock();
        defer self.mu.unlock();
        const fv = self.files.get(path) orelse return null;
        return fv.atCursor(cursor);
    }

    pub fn changesSince(self: *Store, since: u64) u64 {
        self.mu.lock();
        defer self.mu.unlock();
        var count: u64 = 0;
        var iter = self.files.iterator();
        while (iter.next()) |entry| {
            count += entry.value_ptr.countSince(since);
        }
        return count;
    }

    /// Returns all files changed since `since` seq with one entry per file (latest change).
    /// NOTE: returned `path` fields borrow into the store's internal hash map memory.
    /// Do not use them after any write operation (recordSnapshot/recordEdit/recordDelete)
    /// that may rehash the map and invalidate the pointers.
    pub fn changesSinceDetailed(self: *Store, since: u64, allocator: std.mem.Allocator) ![]const ChangeEntry {
        self.mu.lock();
        defer self.mu.unlock();
        var result: std.ArrayList(ChangeEntry) = .empty;
        errdefer result.deinit(allocator);
        var iter = self.files.iterator();
        while (iter.next()) |entry| {
            const fv = entry.value_ptr;
            var latest_change: ?*const Version = null;
            for (fv.versions.items) |*v| {
                if (v.seq > since) {
                    if (latest_change == null or v.seq > latest_change.?.seq) {
                        latest_change = v;
                    }
                }
            }
            if (latest_change) |v| {
                try result.append(allocator, .{
                    .path = entry.key_ptr.*,
                    .seq = v.seq,
                    .op = v.op,
                    .size = v.size,
                    .timestamp = v.timestamp,
                });
            }
        }
        return result.toOwnedSlice(allocator);
    }

    pub fn currentSeq(self: *Store) u64 {
        self.mu.lock();
        defer self.mu.unlock();
        return self.seq;
    }

    /// Deterministic repository-content identity from the latest watcher/
    /// snapshot hashes. Unlike `seq`, this survives process restarts and
    /// detects same-size uncommitted edits without re-reading every source
    /// file during each semantic query.
    pub fn contentFingerprint(self: *Store, allocator: std.mem.Allocator) !u64 {
        self.mu.lock();
        defer self.mu.unlock();

        var paths: std.ArrayList([]const u8) = .empty;
        defer paths.deinit(allocator);
        try paths.ensureTotalCapacity(allocator, self.files.count());
        var iter = self.files.keyIterator();
        while (iter.next()) |path| paths.appendAssumeCapacity(path.*);
        std.mem.sort([]const u8, paths.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);

        var hash = std.hash.Wyhash.init(0x4344_4253_544f_5245);
        for (paths.items) |path| {
            const versions = self.files.get(path) orelse continue;
            const latest = versions.latest() orelse continue;
            // Fingerprint the live repository state, not its edit history.
            // Explorer shape already drops deleted files, and retaining a
            // tombstone here would make create-then-delete permanently stale
            // an otherwise identical semantic sidecar.
            if (latest.op == .tombstone) continue;
            hash.update(path);
            hash.update(&.{0});
            hash.update(std.mem.asBytes(&latest.hash));
            hash.update(std.mem.asBytes(&latest.size));
            const op: u8 = @intFromEnum(latest.op);
            hash.update(&.{op});
        }
        return hash.final();
    }

    /// Deterministic content identity for an already sorted live path set.
    /// The Store may contain stat-only/skipped records that Explorer never
    /// indexed; semantic freshness must compare exactly the files represented
    /// by its parsed manifest across cold-scan and snapshot-load processes.
    pub fn contentFingerprintForPaths(self: *Store, sorted_paths: anytype) !u64 {
        self.mu.lock();
        defer self.mu.unlock();

        var hash = std.hash.Wyhash.init(0x4344_4253_544f_5245);
        for (sorted_paths) |path| {
            const versions = self.files.get(path) orelse return error.MissingContentIdentity;
            const latest = versions.latest() orelse return error.MissingContentIdentity;
            if (latest.op == .tombstone) return error.MissingContentIdentity;
            hash.update(path);
            hash.update(&.{0});
            hash.update(std.mem.asBytes(&latest.hash));
            hash.update(std.mem.asBytes(&latest.size));
            const op: u8 = @intFromEnum(latest.op);
            hash.update(&.{op});
        }
        return hash.final();
    }

    /// Content-only identity used to compare the indexed Store with a fresh
    /// capability-relative filesystem walk. Unlike the persisted semantic
    /// manifest above, this intentionally excludes the process-local Version
    /// operation: identical repository bytes must compare equal whether they
    /// came from a cold snapshot, a watcher refresh, or a restored snapshot.
    pub fn semanticContentFingerprintForPaths(self: *Store, sorted_paths: anytype) !u64 {
        self.mu.lock();
        defer self.mu.unlock();

        var hash = semanticContentHasher();
        for (sorted_paths) |path| {
            const versions = self.files.get(path) orelse return error.MissingContentIdentity;
            const latest = versions.latest() orelse return error.MissingContentIdentity;
            if (latest.op == .tombstone or latest.hash == 0) return error.MissingContentIdentity;
            updateSemanticContentFingerprint(&hash, path, latest.hash, latest.size);
        }
        return hash.final();
    }

    pub fn semanticContentHasher() std.hash.Wyhash {
        return std.hash.Wyhash.init(0x4344_4253_454d_3031);
    }

    pub fn updateSemanticContentFingerprint(
        hash: *std.hash.Wyhash,
        path: []const u8,
        content_hash: u64,
        size: u64,
    ) void {
        hash.update(path);
        hash.update(&.{0});
        hash.update(std.mem.asBytes(&content_hash));
        hash.update(std.mem.asBytes(&size));
    }

    pub fn listFiles(self: *Store) ![][]const u8 {
        self.mu.lock();
        defer self.mu.unlock();

        var paths: std.ArrayList([]const u8) = .empty;
        var iter = self.files.iterator();
        while (iter.next()) |entry| {
            try paths.append(self.allocator, entry.key_ptr.*);
        }
        return paths.toOwnedSlice(self.allocator);
    }
};
