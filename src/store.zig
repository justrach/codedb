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
    seq: u64,
    allocator: std.mem.Allocator,
    mu: cio.Mutex = .{},
    data_log: ?std.Io.File = null,
    data_log_pos: u64 = 0,
    io: ?std.Io = null,

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{
            .files = std.StringHashMap(FileVersions).init(allocator),
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
        if (self.data_log) |f| {
            if (self.io) |io| f.close(io);
        }
    }

    pub fn openDataLog(self: *Store, io: std.Io, path: []const u8) !void {
        // Extract parent dir and ensure it exists
        if (std.mem.lastIndexOfScalar(u8, path, '/')) |sep| {
            std.Io.Dir.cwd().createDirPath(io, path[0..sep]) catch {};
        }
        const file = try std.Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = false });
        self.data_log = file;
        self.io = io;
        const sz = try file.length(io);
        self.data_log_pos = sz;
    }

    pub fn recordSnapshot(self: *Store, path: []const u8, size: u64, hash: u64) !u64 {
        return self.appendVersion(path, 0, .snapshot, hash, size, null);
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
            const duped = try self.allocator.dupe(u8, path);
            entry.key_ptr.* = duped;
            entry.value_ptr.* = FileVersions.init(self.allocator, duped);
        }

        var data_offset: ?u64 = null;
        var data_len: u32 = 0;
        if (diff) |d| {
            if (self.data_log) |log| {
                const io = self.io orelse return error.Unexpected;
                // Advisory lock for cross-process safety
                const locked = blk: {
                    log.lock(io, .exclusive) catch break :blk false;
                    break :blk true;
                };
                defer if (locked) log.unlock(io);

                // Re-stat to get current end position (another process may have appended)
                const end_pos = log.length(io) catch return error.Unexpected;
                self.data_log_pos = end_pos;

                data_offset = self.data_log_pos;
                data_len = @intCast(d.len);
                try log.writePositionalAll(io, d, self.data_log_pos);
                self.data_log_pos += d.len;
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

        // Cap version history to prevent unbounded growth
        const max_versions = 100;
        if (entry.value_ptr.versions.items.len > max_versions) {
            const excess = entry.value_ptr.versions.items.len - max_versions;
            // Single-pass O(n) shift: avoids replaceRange allocator overhead
            std.mem.copyForwards(Version, entry.value_ptr.versions.items[0..max_versions], entry.value_ptr.versions.items[excess..]);
            entry.value_ptr.versions.items.len = max_versions;
        }

        return next_seq;
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
