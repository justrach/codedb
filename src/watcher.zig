const std = @import("std");
const builtin = @import("builtin");
const ContentCache = @import("hot_cache.zig").ContentCache;
const cio = @import("cio.zig");
const Store = @import("store.zig").Store;
const Explorer = @import("explore.zig").Explorer;
const TrigramIndex = @import("index.zig").TrigramIndex;
const WordIndex = @import("index.zig").WordIndex;
const explore_mod = @import("explore.zig");
const git_mod = @import("git.zig");
const project_file = @import("project_file.zig");
const project_path = @import("project_path.zig");

fn nsToMs(ns: i128) f64 {
    return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
}

pub const EventKind = enum(u8) {
    created,
    modified,
    deleted,
};

pub const FsEvent = struct {
    path_buf: [std.fs.max_path_bytes]u8 = undefined,
    path_len: usize,
    kind: EventKind,
    seq: u64,

    pub fn init(src_path: []const u8, kind: EventKind, seq: u64) ?FsEvent {
        // Gracefully skip paths exceeding the max instead of panicking.
        if (src_path.len > std.fs.max_path_bytes) return null;
        var event = FsEvent{
            .path_len = src_path.len,
            .kind = kind,
            .seq = seq,
        };
        @memcpy(event.path_buf[0..src_path.len], src_path);
        return event;
    }

    pub fn path(self: *const FsEvent) []const u8 {
        return self.path_buf[0..self.path_len];
    }
};

pub const EventQueue = struct {
    const CAPACITY = 4096;

    events: [CAPACITY]?FsEvent = @splat(null),
    head: usize = 0,
    tail: usize = 0,
    mu: cio.Mutex = .{},

    pub fn push(self: *EventQueue, event: FsEvent) bool {
        self.mu.lock();
        defer self.mu.unlock();

        const cur_tail = self.tail;
        const next_tail = (cur_tail + 1) % CAPACITY;
        if (next_tail == self.head) return false;
        self.events[cur_tail] = event;
        self.tail = next_tail;
        return true;
    }

    pub fn pop(self: *EventQueue) ?FsEvent {
        self.mu.lock();
        defer self.mu.unlock();

        const cur_head = self.head;
        if (cur_head == self.tail) return null;
        const event = self.events[cur_head];
        self.head = (cur_head + 1) % CAPACITY;
        return event;
    }
};

const FileState = struct {
    mtime: i64, // milliseconds since epoch — cheap stat check
    mtime_ns: i128 = 0, // exact in-process discriminator for rapid rewrites
    ctime_ns: i128 = 0, // catches same-size writes that preserve mtime
    inode: std.posix.ino_t = 0, // catches rename-over-save replacement
    size: u64, // cheap change discriminator before hashing
    hash: u64, // wyhash of content — confirms actual change
    seen: bool, // set during current poll cycle for deletion detection
};

pub const FileMap = std.StringHashMap(FileState);
pub const DirState = struct {
    mtime_ns: i128,
    ctime_ns: i128,
    inode: std.posix.ino_t,
};
pub const DirMap = std.StringHashMap(DirState);
pub const DirtySet = std.StringHashMap(void);
pub var debug_unchanged_full_scans: usize = 0;
pub var debug_unchanged_file_stats: usize = 0;

fn parentRel(path: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| path[0..i] else "";
}

fn joinRel(tmp: std.mem.Allocator, prefix: []const u8, name: []const u8) ![]const u8 {
    if (prefix.len == 0) return name;
    return std.fmt.allocPrint(tmp, "{s}/{s}", .{ prefix, name });
}

fn dirState(io: std.Io, dir: std.Io.Dir, rel: []const u8) ?DirState {
    const st = dir.statFile(io, if (rel.len == 0) "." else rel, .{}) catch return null;
    return .{
        .mtime_ns = st.mtime.nanoseconds,
        .ctime_ns = st.ctime.nanoseconds,
        .inode = st.inode,
    };
}

fn rememberDirState(dirs: *DirMap, persistent: std.mem.Allocator, rel: []const u8, state: DirState) void {
    if (dirs.getPtr(rel)) |slot| {
        slot.* = state;
        return;
    }
    const key = persistent.dupe(u8, rel) catch return;
    dirs.put(key, state) catch persistent.free(key);
}

const InitialScanEntry = struct {
    path: []u8,
    size: u64,
    stat_succeeded: bool,
    skip_trigram: bool,
};

const ParsedScanFile = struct {
    path: []const u8,
    content: []const u8,
    outline: explore_mod.FileOutline,
    skip_trigram: bool,
};

const PersistedScanFile = struct {
    path: []const u8,
    content: []const u8,
    outline: explore_mod.FileOutline,
    skip_trigram: bool,
};

const WorkerParsedResults = struct {
    arena: std.heap.ArenaAllocator,
    items: []?PersistedScanFile = &.{},
    ready: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    word_index_error: ?anyerror = null,
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,

    fn init(backing: std.mem.Allocator) WorkerParsedResults {
        return .{ .arena = std.heap.ArenaAllocator.init(backing) };
    }

    fn prepare(self: *WorkerParsedResults, count: usize) !void {
        self.items = try self.arena.allocator().alloc(?PersistedScanFile, count);
        @memset(self.items, null);
    }

    /// Publish results in entry order. Release/acquire on `ready` makes the slot
    /// visible without a mutex on the common path where the producer is ahead.
    fn publish(self: *WorkerParsedResults, io: std.Io, index: usize, file: ?PersistedScanFile) void {
        self.items[index] = file;
        const ready = index + 1;
        self.ready.store(ready, .release);
        // Wake in batches: waking the main thread for every file turns a fast
        // producer/consumer pair into thousands of kernel context switches.
        if (ready == self.items.len or ready % 64 == 0) {
            self.mutex.lockUncancelable(io);
            self.condition.signal(io);
            self.mutex.unlock(io);
        }
    }

    fn takeReady(self: *WorkerParsedResults, io: std.Io, index: usize) ?PersistedScanFile {
        if (self.ready.load(.acquire) <= index) {
            self.mutex.lockUncancelable(io);
            while (self.ready.load(.acquire) <= index) self.condition.waitUncancelable(io, &self.mutex);
            self.mutex.unlock(io);
        }
        const file = self.items[index];
        self.items[index] = null;
        return file;
    }

    fn deinit(self: *WorkerParsedResults, backing: std.mem.Allocator) void {
        _ = backing;
        for (self.items) |*maybe_file| {
            if (maybe_file.*) |*file| file.outline.deinit();
        }
        self.arena.deinit();
    }
};

/// #635: max file size codedb will read + index (outline/symbol/word). Files up
/// to 1MB also get trigram coverage; 1MB..this cap get outline+word but skip
/// trigram (see effective_skip_trigram); past this cap the file is skipped.
/// Was 512KB, which silently dropped 512KB-1MB source files entirely.
const max_indexed_file_bytes = 2 * 1024 * 1024;

/// #635: byte threshold for the trigram index. Files up to this size get trigram
/// coverage; larger files (up to max_indexed_file_bytes) still get outline+word
/// indexing but skip trigrams to bound memory on large repos. Previously a bare
/// `1024 * 1024` duplicated across seven call sites.
const max_trigram_file_bytes = 1024 * 1024;

/// #635: the single read gate every index path shares. Enforces the size cap and
/// the binary (null-byte) check in one place, so the threshold can't drift across
/// call sites again (the root cause of #635). Returns the file content (allocated
/// in `alloc`), or null when the file must be skipped — over the cap (logged when
/// `warn_oversize`) or binary. `size` is the caller's already-stat'd file size.
fn readIndexableFile(
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
    alloc: std.mem.Allocator,
    size: u64,
    warn_oversize: bool,
) !?[]const u8 {
    if (size > max_indexed_file_bytes) {
        if (warn_oversize)
            // Reachable via codedb_read (disk fallback) but invisible to
            // search/symbol/outline — surface the skip instead of dropping it.
            std.log.warn("codedb: not indexing {s} ({d} bytes > {d} cap) — reachable only via codedb_read", .{ path, size, max_indexed_file_bytes });
        return null;
    }
    const content = try project_file.readAllocNoFollow(io, dir, path, alloc, .limited(max_indexed_file_bytes));
    // Skip binary content (null byte within the first 512 bytes).
    const check_len = @min(content.len, 512);
    if (std.mem.indexOfScalar(u8, content[0..check_len], 0) != null) {
        alloc.free(content);
        return null;
    }
    return content;
}

const skip_dirs = [_][]const u8{
    ".git",
    ".jj",
    ".claude",
    ".codedb",
    "node_modules",
    ".zig-cache",
    "zig-out",
    ".next",
    ".nuxt",
    ".svelte-kit",
    "dist",
    "build",
    ".build",
    ".output",
    "out",
    "__pycache__",
    ".venv",
    ".devenv",
    "venv",
    ".env",
    ".tox",
    ".mypy_cache",
    ".pytest_cache",
    ".ruff_cache",
    "target", // rust, java/maven
    ".gradle",
    ".idea",
    ".vs",
    "vendor", // go, php
    "Pods", // cocoapods
    ".dart_tool",
    ".pub-cache",
    "coverage",
    ".nyc_output",
    ".turbo",
    ".parcel-cache",
    ".cache",
    ".tmp",
    ".temp",
    ".DS_Store",
    "bundle",
    ".bundle",
    ".swc",
    ".terraform",
    ".terragrunt-cache",
    ".serverless",
    "elm-stuff",
    ".stack-work",
    ".cabal-sandbox",
    ".cargo",
    "bower_components",
    "graphify-out", // graphify AST/graph cache
    ".graff",
    ".harness",
};

fn shouldSkip(path: []const u8) bool {
    // Check each path component against skip list
    var rest = path;
    while (true) {
        for (skip_dirs) |skip| {
            if (rest.len >= skip.len and
                std.mem.eql(u8, rest[0..skip.len], skip) and
                (rest.len == skip.len or rest[skip.len] == '/'))
                return true;
        }
        // Advance to next component
        if (std.mem.indexOfScalar(u8, rest, '/')) |sep| {
            rest = rest[sep + 1 ..];
        } else break;
    }
    return false;
}

fn shouldSkipDir(name: []const u8) bool {
    for (skip_dirs) |skip| if (std.mem.eql(u8, name, skip)) return true;
    return false;
}

fn isWithinCanonicalRoot(root: []const u8, candidate: []const u8) bool {
    if (!std.mem.startsWith(u8, candidate, root)) return false;
    if (candidate.len == root.len) return true;
    return root.len > 0 and (isPortablePathSep(root[root.len - 1]) or isPortablePathSep(candidate[root.len]));
}

fn isPortablePathSep(ch: u8) bool {
    return ch == '/' or ch == '\\';
}

/// Return a slash-normalized repository-relative spelling for a canonical
/// target. Windows realPath uses backslashes, but every sensitive-path and
/// skip policy in codedb intentionally consumes portable forward slashes.
fn canonicalTargetRelative(root: []const u8, target: []const u8, normalized: []u8) ?[]const u8 {
    if (!isWithinCanonicalRoot(root, target) or target.len == root.len) return null;
    var start = root.len;
    while (start < target.len and isPortablePathSep(target[start])) start += 1;
    if (start == target.len) return null;
    const rel = target[start..];
    if (rel.len > normalized.len) return null;
    for (rel, normalized[0..rel.len]) |ch, *out| out.* = if (isPortablePathSep(ch)) '/' else ch;
    return normalized[0..rel.len];
}

test "canonical Windows targets are normalized before sensitive policy checks" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const rel = canonicalTargetRelative("C:\\repo", "C:\\repo\\safe\\.ssh\\config", &buf) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("safe/.ssh/config", rel);
    try std.testing.expect(shouldSkipFile(rel));
    try std.testing.expect(canonicalTargetRelative("C:\\repo", "C:\\repo-other\\src", &buf) == null);
}

/// Resolve every candidate under the canonical root and require both its
/// visible path and canonical repo-relative target to satisfy the indexing
/// filters. File symlinks themselves are skipped; this additionally protects
/// regular files reached through an allowed directory symlink.
fn resolvedFileTargetAllowed(io: std.Io, root_dir: std.Io.Dir, canonical_root: []const u8, alias_path: []const u8) bool {
    if (canonical_root.len == 0 or shouldSkip(alias_path) or shouldSkipFile(alias_path)) return false;
    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target_len = root_dir.realPathFile(io, alias_path, &target_buf) catch return false;
    var normalized_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target_rel = canonicalTargetRelative(canonical_root, target_buf[0..target_len], &normalized_buf) orelse return false;
    return !shouldSkip(target_rel) and !shouldSkipFile(target_rel);
}

fn resolvedDirectoryTargetAllowed(io: std.Io, root_dir: std.Io.Dir, canonical_root: []const u8, alias_path: []const u8) bool {
    if (alias_path.len == 0) return canonical_root.len > 0;
    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target_len = root_dir.realPathFile(io, alias_path, &target_buf) catch return false;
    var normalized_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target_rel = canonicalTargetRelative(canonical_root, target_buf[0..target_len], &normalized_buf) orelse return false;
    return !shouldSkip(target_rel) and !shouldSkipFile(target_rel);
}

/// Recursive directory walker that prunes skip_dirs before descending.
/// Unlike std.Io.Dir.walk(), this never enters .git, node_modules, etc.,
/// avoiding the CPU cost of traversing potentially huge directory trees.
pub const FilteredWalker = struct {
    const StackItem = struct {
        dir_handle: std.Io.Dir,
        iter: std.Io.Dir.Iterator,
        through_symlink: bool,
    };

    stack: std.ArrayList(StackItem),
    name_buffer: std.ArrayList(u8),
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_prefix_len: usize = 0,
    ignore_patterns: std.ArrayList([]const u8) = .empty,
    real_root: []const u8 = &.{},
    visited_real_paths: std.StringHashMapUnmanaged(void) = .empty,

    pub const Entry = struct {
        path: []const u8, // relative path — valid until next call to next()
        size: u64,
    };

    pub fn init(io: std.Io, root: std.Io.Dir, allocator: std.mem.Allocator) !FilteredWalker {
        var self = FilteredWalker{
            .stack = .empty,
            .name_buffer = .empty,
            .allocator = allocator,
            .io = io,
        };
        try self.stack.append(allocator, .{
            .dir_handle = root,
            .iter = root.iterate(),
            .through_symlink = false,
        });

        var rr_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (root.realPathFile(io, ".", &rr_buf)) |rr_len| {
            const dup = try allocator.dupe(u8, rr_buf[0..rr_len]);
            self.real_root = dup;
            const seed = try allocator.dupe(u8, rr_buf[0..rr_len]);
            try self.visited_real_paths.put(allocator, seed, {});
        } else |_| {}

        // Load .codedbignore if it exists
        if (project_file.readAllocNoFollow(io, root, ".codedbignore", allocator, .limited(64 * 1024))) |content| {
            defer allocator.free(content);
            var lines = std.mem.splitScalar(u8, content, '\n');
            while (lines.next()) |line| {
                const trimmed = std.mem.trim(u8, line, " \t\r");
                if (trimmed.len == 0 or trimmed[0] == '#') continue;
                const duped = try allocator.dupe(u8, trimmed);
                try self.ignore_patterns.append(allocator, duped);
            }
        } else |_| {}

        // Also load .gitignore patterns (respect git's ignore rules)
        if (project_file.readAllocNoFollow(io, root, ".gitignore", allocator, .limited(64 * 1024))) |content| {
            defer allocator.free(content);
            var lines = std.mem.splitScalar(u8, content, '\n');
            while (lines.next()) |line| {
                const trimmed = std.mem.trim(u8, line, " \t\r");
                if (trimmed.len == 0 or trimmed[0] == '#') continue;
                // Skip negation patterns (!) — too complex for simple matching
                if (trimmed[0] == '!') continue;
                const duped = try allocator.dupe(u8, trimmed);
                try self.ignore_patterns.append(allocator, duped);
            }
        } else |_| {}

        return self;
    }

    pub fn deinit(self: *FilteredWalker) void {
        for (self.stack.items, 0..) |*item, i| {
            if (i > 0) item.dir_handle.close(self.io);
        }
        self.stack.deinit(self.allocator);
        self.name_buffer.deinit(self.allocator);
        for (self.ignore_patterns.items) |p| self.allocator.free(p);
        self.ignore_patterns.deinit(self.allocator);
        var it = self.visited_real_paths.keyIterator();
        while (it.next()) |k| self.allocator.free(k.*);
        self.visited_real_paths.deinit(self.allocator);
        if (self.real_root.len > 0) self.allocator.free(self.real_root);
    }

    fn isIgnored(self: *FilteredWalker, name: []const u8, full_path: []const u8) bool {
        for (self.ignore_patterns.items) |pattern| {
            // Root-anchored pattern (starts with /) — only match at project root
            if (pattern.len > 1 and pattern[0] == '/') {
                const anchored = pattern[1..];
                const clean = if (std.mem.endsWith(u8, anchored, "/")) anchored[0 .. anchored.len - 1] else anchored;
                if (std.mem.eql(u8, full_path, clean) or std.mem.startsWith(u8, full_path, anchored)) return true;
                continue;
            }
            // Directory pattern (ends with /) — match directory names at any depth
            if (std.mem.endsWith(u8, pattern, "/")) {
                const dir_name = pattern[0 .. pattern.len - 1];
                if (std.mem.eql(u8, name, dir_name)) return true;
                continue;
            }
            // Glob suffix match (e.g. *.log)
            if (pattern.len > 1 and pattern[0] == '*') {
                if (std.mem.endsWith(u8, name, pattern[1..])) return true;
                continue;
            }
            // Exact name match (matches at any depth)
            if (std.mem.eql(u8, name, pattern)) return true;
            // Path prefix match (must match at / boundary)
            if (std.mem.startsWith(u8, full_path, pattern) and
                full_path.len > pattern.len and full_path[pattern.len] == '/') return true;
        }
        return false;
    }

    /// Validate the directory object that was actually opened, regardless of
    /// the iterator's pre-open kind. Returns whether its canonical target
    /// differs from the visible path. Claiming every handle closes the race
    /// where a `.directory` entry is replaced by an outside symlink between
    /// iteration and open, and also supplies cycle prevention for all aliases.
    fn claimOpenedDirectory(self: *FilteredWalker, dir: std.Io.Dir, visible_path: []const u8) ?bool {
        if (self.real_root.len == 0) return null;
        var target_buf: [std.fs.max_path_bytes]u8 = undefined;
        const target_len = dir.realPathFile(self.io, ".", &target_buf) catch return null;
        const real_target = target_buf[0..target_len];
        var normalized_buf: [std.fs.max_path_bytes]u8 = undefined;
        const target_rel = canonicalTargetRelative(self.real_root, real_target, &normalized_buf) orelse return null;
        if (shouldSkip(target_rel) or shouldSkipFile(target_rel)) return null;
        const opened_as_alias = !std.mem.eql(u8, target_rel, visible_path);
        // Ordinary directories may also be reachable through a deliberate
        // in-root alias.  Only alias edges participate in cycle suppression;
        // recording every ordinary directory would make whichever spelling is
        // visited first hide the other one.  The root itself is pre-claimed,
        // so an alias back to it is still rejected.
        if (!opened_as_alias) return false;
        const gop = self.visited_real_paths.getOrPut(self.allocator, real_target) catch return null;
        if (gop.found_existing) return null;
        const dup = self.allocator.dupe(u8, real_target) catch {
            _ = self.visited_real_paths.remove(real_target);
            return null;
        };
        gop.key_ptr.* = dup;
        return true;
    }

    pub fn next(self: *FilteredWalker) !?Entry {
        // Trim any filename appended by the previous yield
        self.name_buffer.shrinkRetainingCapacity(self.dir_prefix_len);

        while (self.stack.items.len > 0) {
            const top = &self.stack.items[self.stack.items.len - 1];
            if (try top.iter.next(self.io)) |entry| {
                if (entry.kind == .directory) {
                    if (shouldSkipDir(entry.name)) continue;
                    var visible_buf: [std.fs.max_path_bytes]u8 = undefined;
                    const visible_path = if (self.dir_prefix_len > 0)
                        std.fmt.bufPrint(&visible_buf, "{s}/{s}", .{ self.name_buffer.items[0..self.dir_prefix_len], entry.name }) catch continue
                    else
                        entry.name;
                    // Check .codedbignore patterns
                    if (self.ignore_patterns.items.len > 0) {
                        if (self.isIgnored(entry.name, visible_path)) continue;
                    }
                    const sub = top.dir_handle.openDir(self.io, entry.name, .{ .iterate = true }) catch continue;
                    const opened_as_alias = self.claimOpenedDirectory(sub, visible_path) orelse {
                        sub.close(self.io);
                        continue;
                    };
                    errdefer sub.close(self.io);
                    const saved_len = self.name_buffer.items.len;
                    errdefer self.name_buffer.shrinkRetainingCapacity(saved_len);

                    // Extend the directory prefix in name_buffer
                    if (self.name_buffer.items.len > 0)
                        try self.name_buffer.append(self.allocator, '/');
                    try self.name_buffer.appendSlice(self.allocator, entry.name);
                    self.dir_prefix_len = self.name_buffer.items.len;

                    try self.stack.append(self.allocator, .{
                        .dir_handle = sub,
                        .iter = sub.iterate(),
                        .through_symlink = top.through_symlink or opened_as_alias,
                    });
                    continue;
                }

                if (entry.kind != .file) {
                    if (entry.kind != .sym_link) continue;
                    if (shouldSkipDir(entry.name)) continue;
                    if (self.ignore_patterns.items.len > 0) {
                        var check_buf: [std.fs.max_path_bytes]u8 = undefined;
                        const check_path = if (self.dir_prefix_len > 0)
                            std.fmt.bufPrint(&check_buf, "{s}/{s}", .{ self.name_buffer.items[0..self.dir_prefix_len], entry.name }) catch entry.name
                        else
                            entry.name;
                        if (self.isIgnored(entry.name, check_path)) continue;
                    }
                    // Opening as a directory is also the file-symlink gate:
                    // regular-file targets fail with NotDir and are skipped.
                    // Validate the already-open directory handle so retargeting
                    // the link cannot change the object that will be walked.
                    const sub = top.dir_handle.openDir(self.io, entry.name, .{ .iterate = true }) catch continue;
                    var visible_buf: [std.fs.max_path_bytes]u8 = undefined;
                    const visible_path = if (self.dir_prefix_len > 0)
                        std.fmt.bufPrint(&visible_buf, "{s}/{s}", .{ self.name_buffer.items[0..self.dir_prefix_len], entry.name }) catch {
                            sub.close(self.io);
                            continue;
                        }
                    else
                        entry.name;
                    if (self.claimOpenedDirectory(sub, visible_path) == null) {
                        sub.close(self.io);
                        continue;
                    }
                    errdefer sub.close(self.io);
                    const saved_len_sym = self.name_buffer.items.len;
                    errdefer self.name_buffer.shrinkRetainingCapacity(saved_len_sym);
                    if (self.name_buffer.items.len > 0)
                        try self.name_buffer.append(self.allocator, '/');
                    try self.name_buffer.appendSlice(self.allocator, entry.name);
                    self.dir_prefix_len = self.name_buffer.items.len;
                    try self.stack.append(self.allocator, .{
                        .dir_handle = sub,
                        .iter = sub.iterate(),
                        .through_symlink = true,
                    });
                    continue;
                }

                // This also checks ordinary files reached through an allowed
                // directory symlink, so a safe directory alias cannot expose a
                // sensitive canonical target nested below it.
                if (top.through_symlink and !resolvedFileTargetAllowed(self.io, top.dir_handle, self.real_root, entry.name)) continue;

                // Build full relative path by appending filename
                if (self.dir_prefix_len > 0)
                    try self.name_buffer.append(self.allocator, '/');
                try self.name_buffer.appendSlice(self.allocator, entry.name);

                // Check .codedbignore patterns for files
                if (self.ignore_patterns.items.len > 0 and self.isIgnored(entry.name, self.name_buffer.items)) {
                    self.name_buffer.shrinkRetainingCapacity(self.dir_prefix_len);
                    continue;
                }

                const stable_stat = top.dir_handle.statFile(self.io, entry.name, .{ .follow_symlinks = false }) catch {
                    self.name_buffer.shrinkRetainingCapacity(self.dir_prefix_len);
                    continue;
                };
                if (stable_stat.kind != .file) {
                    self.name_buffer.shrinkRetainingCapacity(self.dir_prefix_len);
                    continue;
                }
                return .{ .path = self.name_buffer.items, .size = stable_stat.size };
            } else {
                // Directory exhausted — pop and restore parent prefix
                if (self.stack.items.len > 1) {
                    var item = self.stack.pop().?;
                    item.dir_handle.close(self.io);
                } else {
                    _ = self.stack.pop();
                }
                if (std.mem.lastIndexOfScalar(u8, self.name_buffer.items[0..self.dir_prefix_len], '/')) |pos| {
                    self.dir_prefix_len = pos;
                } else {
                    self.dir_prefix_len = 0;
                }
                self.name_buffer.shrinkRetainingCapacity(self.dir_prefix_len);
            }
        }
        return null;
    }
};

/// Files beyond this count are indexed without trigrams and land in
/// skip_trigram_files, which tier 3 of searchContent linearly content-scans
/// on every query that falls through the earlier tiers — on a corpus well
/// past the cap that scan dominates zero-hit query latency. The cap bounds
/// trigram-index RSS; CODEDB_TRIGRAM_CAP overrides it for corpora where the
/// memory trade is worth it.
pub fn trigramFileCap() usize {
    const raw = cio.posixGetenv("CODEDB_TRIGRAM_CAP") orelse return 15_000;
    return std.fmt.parseInt(usize, raw, 10) catch 15_000;
}

fn collectInitialScanEntries(io: std.Io, store: *Store, dir: std.Io.Dir, allocator: std.mem.Allocator, skip_trigram: bool) !std.ArrayList(InitialScanEntry) {
    var walker = try FilteredWalker.init(io, dir, allocator);
    defer walker.deinit();

    var entries: std.ArrayList(InitialScanEntry) = .empty;
    errdefer {
        for (entries.items) |entry| allocator.free(entry.path);
        entries.deinit(allocator);
    }

    const max_trigram_files = trigramFileCap();
    // The walker stats each file relative to the stable opened parent handle.
    // Deferring these stats by path would reopen the directory namespace after
    // traversal and let a directory-retarget race inject outside sizes into the
    // Store before content validation.
    while (try walker.next()) |entry| {
        try entries.append(allocator, .{
            .path = try allocator.dupe(u8, entry.path),
            .size = entry.size,
            .stat_succeeded = true,
            .skip_trigram = false, // set after parallel stat fan
        });
    }
    for (entries.items) |entry| {
        _ = try store.recordSnapshot(entry.path, entry.size, 0);
    }
    // Set skip_trigram using serial count (preserves original cap semantics on discovery order).
    var file_count: usize = 0;
    for (entries.items) |*e| {
        file_count += 1;
        e.skip_trigram = skip_trigram or (file_count > max_trigram_files);
    }
    return entries;
}

fn parseInitialScanEntry(
    io: std.Io,
    dir: std.Io.Dir,
    entry: InitialScanEntry,
    content_alloc: std.mem.Allocator,
    parse_alloc: std.mem.Allocator,
) !?ParsedScanFile {
    if (shouldSkipFile(entry.path)) return null;
    const content = (try readIndexableFile(io, dir, entry.path, content_alloc, entry.size, true)) orelse return null;
    errdefer content_alloc.free(content);
    // Threshold for including a file in the trigram index. Bumped from 64KB to
    // 1MB after the search-shootout bench (issue: large code files like
    // ReactFiberCompleteWork.js at 77KB were invisible to substring search,
    // causing agents to miss call sites in them). 1MB covers all reasonable
    // code files; minified/generated bundles past 1MB are correctly skipped.
    const effective_skip_trigram = entry.skip_trigram or (content.len > max_trigram_file_bytes);
    const parsed = try explore_mod.Explorer.parseContentForIndexing(parse_alloc, entry.path, content);
    return .{
        .path = entry.path,
        .content = parsed.content,
        .outline = parsed.outline,
        .skip_trigram = effective_skip_trigram,
    };
}

fn parseInitialScanWorkerEntry(
    io: std.Io,
    results: *WorkerParsedResults,
    dir: std.Io.Dir,
    entry: InitialScanEntry,
    scratch_alloc: std.mem.Allocator,
    word_shard: ?*WordIndex,
) ?PersistedScanFile {
    const persist = results.arena.allocator();
    const parsed = parseInitialScanEntry(io, dir, entry, persist, scratch_alloc) catch return null;
    if (parsed == null) return null;

    var file = parsed.?;
    defer file.outline.deinit();
    var keep_content = false;
    defer if (!keep_content) persist.free(file.content);

    const outline_copy = explore_mod.Explorer.cloneOutlinePackedBorrowingPath(&file.outline, std.heap.c_allocator) catch return null;
    if (word_shard) |ws| {
        if (results.word_index_error == null) {
            ws.indexFile(file.path, file.content) catch |err| {
                results.word_index_error = err;
            };
        }
    }
    keep_content = true;
    return .{
        .path = file.path,
        .content = file.content,
        .outline = outline_copy,
        .skip_trigram = file.skip_trigram,
    };
}

fn initialScanWorker(io: std.Io, results: *WorkerParsedResults, dir: std.Io.Dir, entries: []const InitialScanEntry, word_shard: ?*WordIndex, trigram_shard: ?*TrigramIndex) void {
    // Read content directly into the persistent result arena, while allocating
    // transient parser state in a per-file scratch arena that is reset between
    // files. The final outline uses packed libc-owned storage so the main thread
    // can adopt it as soon as this worker publishes the corresponding slot.
    //
    // When word_shard is set, also build the WordIndex for this chunk in parallel
    // here (lock-free, content is hot) instead of on the serial commit thread.
    // When trigram_shard is set, build trigrams into the private shard so the
    // main thread can merge posting lists in one pass instead of serial indexFile.
    // Files are indexed in chunk order, matching the order commit/mergeShard will
    // assign global doc_ids, so the merged index is identical to the serial path.
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    for (entries, 0..) |entry, index| {
        _ = scratch.reset(.retain_capacity);
        const file = parseInitialScanWorkerEntry(io, results, dir, entry, scratch.allocator(), word_shard);
        if (file) |f| {
            if (trigram_shard) |ts| {
                if (!f.skip_trigram and f.content.len <= max_trigram_file_bytes) {
                    ts.indexFile(f.path, f.content) catch {};
                }
            }
        }
        results.publish(io, index, file);
    }
}

pub fn initialScanWithWorkerCount(io: std.Io, store: *Store, explorer: *Explorer, root: []const u8, allocator: std.mem.Allocator, skip_trigram: bool, worker_count: usize) !void {
    const profile = cio.posixGetenv("CODEDB_INDEX_PROFILE") != null;
    const profile_start: i128 = if (profile) cio.nanoTimestamp() else 0;
    explorer.mu.lock();
    const bulk_skip_file_words = explorer.word_index.skip_file_words;
    if (bulk_skip_file_words) explorer.defer_word_index = true;
    explorer.mu.unlock();
    defer if (bulk_skip_file_words) {
        explorer.mu.lock();
        explorer.defer_word_index = false;
        explorer.word_index.skip_file_words = false;
        explorer.mu.unlock();
    };
    var owned_dir: ?std.Io.Dir = null;
    const dir = if (explorer.root_dir) |stable| blk: {
        if (!project_file.rootMatchesPath(io, stable, root)) return error.ProjectRootChanged;
        break :blk stable;
    } else blk: {
        owned_dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
        break :blk owned_dir.?;
    };
    defer if (owned_dir) |owned| owned.close(io);

    var entries = try collectInitialScanEntries(io, store, dir, allocator, skip_trigram);
    const profile_collect_done: i128 = if (profile) cio.nanoTimestamp() else 0;
    defer {
        for (entries.items) |entry| allocator.free(entry.path);
        entries.deinit(allocator);
    }

    if (entries.items.len == 0) return;
    const n_workers = @max(@as(usize, 1), @min(worker_count, entries.items.len));
    if (n_workers == 1) {
        // There is no shard to publish in the serial path; index words inline.
        if (bulk_skip_file_words) {
            explorer.mu.lock();
            explorer.defer_word_index = false;
            explorer.mu.unlock();
        }
        for (entries.items) |entry| {
            {
                var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                defer arena.deinit();
                const parsed = try parseInitialScanEntry(io, dir, entry, arena.allocator(), arena.allocator());
                if (parsed) |file| {
                    const content_hash = std.hash.Wyhash.hash(0, file.content);
                    try explorer.commitParsedFileOwnedOutline(file.path, file.content, file.outline, true, file.skip_trigram);
                    _ = store.refineLatestSnapshotHash(file.path, file.content.len, content_hash);
                }
            }
        }
        if (profile) {
            const now = cio.nanoTimestamp();
            const to_ms = struct {
                fn f(ns: i128) f64 {
                    return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
                }
            }.f;
            std.debug.print("[index-profile] scan files={d} workers=1 total={d:.1}ms collect={d:.1}ms parse_commit={d:.1}ms\n", .{
                entries.items.len,
                to_ms(now - profile_start),
                to_ms(profile_collect_done - profile_start),
                to_ms(now - profile_collect_done),
            });
        }
        return;
    }

    const workers = try allocator.alloc(WorkerParsedResults, n_workers);
    defer allocator.free(workers);
    const threads = try allocator.alloc(std.Thread, n_workers);
    defer allocator.free(threads);
    for (workers) |*worker| worker.* = WorkerParsedResults.init(std.heap.page_allocator);
    var workers_committed: usize = 0;
    defer {
        // Free any workers not yet committed (on error path).
        for (workers[workers_committed..]) |*worker| worker.deinit(allocator);
    }
    var spawned: usize = 0;

    // When the word index is enabled (cold `index`/`mcp` path), build it in
    // parallel per-worker shards backed by each worker's arena, then merge the
    // shards on the main thread after commit. This moves the word-index build —
    // the dominant cost of the otherwise-serial commit loop — into the parallel
    // region. Gated on skip_file_words because shards intentionally omit the
    // per-file word set (file_words), so they only fit the bulk cold-index build
    // (which never needs incremental removeFile); main.zig always sets it. Other
    // paths keep the old serial behavior with zero overhead.
    const use_shards = explorer.word_index.enabled and explorer.word_index.skip_file_words;
    const shards: ?[]WordIndex = if (use_shards) try allocator.alloc(WordIndex, n_workers) else null;
    defer if (shards) |sh| allocator.free(sh);
    var joined: usize = 0;
    errdefer for (threads[joined..spawned]) |thread| thread.join();

    const chunk_size = entries.items.len / n_workers;
    const remainder = entries.items.len % n_workers;
    var offset: usize = 0;
    for (workers, 0..) |*worker, i| {
        const extra: usize = if (i < remainder) 1 else 0;
        const count = chunk_size + extra;
        const chunk = entries.items[offset .. offset + count];
        offset += count;
        try worker.prepare(count);
        var shard_ptr: ?*WordIndex = null;
        if (shards) |sh| {
            sh[i] = WordIndex.init(worker.arena.allocator());
            sh[i].skip_file_words = true;
            shard_ptr = &sh[i];
        }
        threads[i] = try std.Thread.spawn(.{}, initialScanWorker, .{ io, worker, dir, chunk, shard_ptr, null });
        spawned += 1;
    }
    const profile_spawn_done: i128 = if (profile) cio.nanoTimestamp() else 0;
    // Shared Explorer maps remain serial, but consume ready slots while workers
    // continue parsing. Worker/chunk order matches the prior cold-scan semantics
    // for symbol precedence, cache eviction, dependency output, and persistence.
    for (workers) |*worker| {
        for (0..worker.items.len) |item_index| {
            if (worker.takeReady(io, item_index)) |file| {
                const content_hash = std.hash.Wyhash.hash(0, file.content);
                try explorer.commitParsedFileAdoptOutline(file.path, file.content, file.outline, true, file.skip_trigram);
                _ = store.refineLatestSnapshotHash(file.path, file.content.len, content_hash);
            }
        }
    }
    const profile_commit_done: i128 = if (profile) cio.nanoTimestamp() else 0;

    for (threads[0..spawned]) |thread| thread.join();
    joined = spawned;
    const profile_join_done: i128 = if (profile) cio.nanoTimestamp() else 0;
    for (workers) |*worker| {
        if (worker.word_index_error) |err| return err;
    }
    if (shards) |sh| {
        // Queries/status readers use Explorer.mu shared; publish the complete
        // merged word index under one exclusive section so no reader can observe
        // hash-map reallocations or a partially merged document range.
        explorer.mu.lock();
        defer explorer.mu.unlock();
        for (sh) |*shard| try explorer.word_index.mergeShard(shard);
    }
    for (workers) |*worker| {
        worker.deinit(allocator);
        workers_committed += 1;
    }
    if (profile) {
        const now = cio.nanoTimestamp();
        const to_ms = struct {
            fn f(ns: i128) f64 {
                return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
            }
        }.f;
        std.debug.print("[index-profile] scan files={d} workers={d} shards={} total={d:.1}ms collect={d:.1}ms setup_spawn={d:.1}ms parse_commit={d:.1}ms join={d:.1}ms merge_free={d:.1}ms\n", .{
            entries.items.len,
            n_workers,
            use_shards,
            to_ms(now - profile_start),
            to_ms(profile_collect_done - profile_start),
            to_ms(profile_spawn_done - profile_collect_done),
            to_ms(profile_commit_done - profile_spawn_done),
            to_ms(profile_join_done - profile_commit_done),
            to_ms(now - profile_join_done),
        });
    }
}

fn extractTrigramMasks(
    content: []const u8,
    local: *std.AutoHashMap(@import("index.zig").Trigram, @import("index.zig").PostingMask),
) !void {
    if (content.len < 3) return;
    const index_m = @import("index.zig");
    var c0 = content[0];
    var c1 = content[1];
    var c2 = content[2];
    var n0 = index_m.normalizeChar(c0);
    var n1 = index_m.normalizeChar(c1);
    var n2 = index_m.normalizeChar(c2);

    for (0..content.len - 2) |i| {
        const has_next = i + 3 < content.len;
        const c3 = if (has_next) content[i + 3] else 0;
        const n3 = if (has_next) index_m.normalizeChar(c3) else 0;
        if (!((c0 == ' ' or c0 == '\t' or c0 == '\n' or c0 == '\r') and
            (c1 == ' ' or c1 == '\t' or c1 == '\n' or c1 == '\r') and
            (c2 == ' ' or c2 == '\t' or c2 == '\n' or c2 == '\r')))
        {
            const tri = index_m.packTrigram(n0, n1, n2);
            const gop = try local.getOrPut(tri);
            if (!gop.found_existing) gop.value_ptr.* = index_m.PostingMask{};
            gop.value_ptr.loc_mask |= @as(u8, 1) << @intCast(i & 7);
            if (has_next) {
                gop.value_ptr.next_mask |= @as(u8, 1) << @intCast(n3 & 7);
            }
        }
        c0 = c1;
        c1 = c2;
        c2 = c3;
        n0 = n1;
        n1 = n2;
        n2 = n3;
    }
}

// Build a private trigram shard from a chunk of InitialScanEntry items — reads
// each file, extracts trigrams, and inserts postings directly, all on the worker.
// Used by the skip_outlines fast path in initialScanWithTrigrams.
fn readAndBuildTrigramShardWorker(io: std.Io, shard: *TrigramIndex, dir: std.Io.Dir, entries: []const InitialScanEntry, build_error: *?anyerror) void {
    const index_m = @import("index.zig");
    var local = std.AutoHashMap(index_m.Trigram, index_m.PostingMask).init(std.heap.c_allocator);
    defer local.deinit();
    local.ensureTotalCapacity(4096) catch {};
    for (entries) |entry| {
        if (shouldSkipFile(entry.path)) continue;
        const content = (readIndexableFile(io, dir, entry.path, std.heap.c_allocator, entry.size, false) catch continue) orelse continue;
        defer std.heap.c_allocator.free(content);
        if (content.len > max_trigram_file_bytes) continue;
        local.clearRetainingCapacity();
        extractTrigramMasks(content, &local) catch |err| {
            build_error.* = err;
            return;
        };
        shard.insertBulkMapNew(entry.path, &local) catch |err| {
            build_error.* = err;
            return;
        };
    }
}

// Build a private trigram shard from a chunk of (path, content) entries that
// are already in memory. Both extraction and hash/posting insertion happen on
// the worker; the main thread later merges one posting slice per shard+trigram.
const CachedEntry = struct { path: []const u8, content: []const u8 };

fn cachedTrigramBuildWorker(shard: *TrigramIndex, entries: []const CachedEntry, build_error: *?anyerror) void {
    const index_m = @import("index.zig");
    var local = std.AutoHashMap(index_m.Trigram, index_m.PostingMask).init(std.heap.c_allocator);
    defer local.deinit();
    local.ensureTotalCapacity(4096) catch {};
    for (entries) |entry| {
        local.clearRetainingCapacity();
        extractTrigramMasks(entry.content, &local) catch |err| {
            build_error.* = err;
            return;
        };
        shard.insertBulkMapNew(entry.path, &local) catch |err| {
            build_error.* = err;
            return;
        };
    }
}

/// Build a TrigramIndex from contents already in memory, parallelized across
/// `n_workers` threads. Caller owns the returned index (must deinit + destroy).
pub fn buildTrigramsFromCache(
    contents: *ContentCache,
    allocator: std.mem.Allocator,
    trigram_alloc: std.mem.Allocator,
    worker_count: usize,
) !*TrigramIndex {
    const profile = cio.posixGetenv("CODEDB_INDEX_PROFILE") != null;
    const profile_start: i128 = if (profile) cio.nanoTimestamp() else 0;
    var tmp_tri = try trigram_alloc.create(TrigramIndex);
    tmp_tri.* = TrigramIndex.init(trigram_alloc);
    errdefer {
        tmp_tri.deinit();
        trigram_alloc.destroy(tmp_tri);
    }
    tmp_tri.owns_paths = true;
    tmp_tri.index.ensureTotalCapacity(131072) catch {};
    tmp_tri.path_to_id.ensureTotalCapacity(@intCast(@min(contents.count(), 65536))) catch {};

    if (contents.count() == 0) return tmp_tri;

    var entries: std.ArrayList(CachedEntry) = .empty;
    defer entries.deinit(allocator);
    try entries.ensureTotalCapacity(allocator, contents.count());
    var iter = contents.iterator();
    while (iter.next()) |e| {
        if (e.value_ptr.*.len > max_trigram_file_bytes) continue;
        entries.appendAssumeCapacity(.{ .path = e.key_ptr.*, .content = e.value_ptr.* });
    }
    const profile_collect_done: i128 = if (profile) cio.nanoTimestamp() else 0;
    if (entries.items.len == 0) return tmp_tri;

    const n_workers = @max(@as(usize, 1), @min(worker_count, entries.items.len));
    if (n_workers == 1) {
        var build_error: ?anyerror = null;
        cachedTrigramBuildWorker(tmp_tri, entries.items, &build_error);
        if (build_error) |err| return err;
        if (profile) {
            const now = cio.nanoTimestamp();
            std.debug.print("[index-profile] trigram files={d} workers=1 total={d:.1}ms collect={d:.1}ms build={d:.1}ms\n", .{
                entries.items.len,
                nsToMs(now - profile_start),
                nsToMs(profile_collect_done - profile_start),
                nsToMs(now - profile_collect_done),
            });
        }
        return tmp_tri;
    }

    // Shards use c_allocator so no caller-provided allocator is touched from
    // multiple threads. In production the destination uses c_allocator too,
    // allowing mergeBulkShard to transfer first-seen posting lists directly.
    const shards = try allocator.alloc(TrigramIndex, n_workers);
    var shards_initialized: usize = 0;
    var shards_deinitialized: usize = 0;
    defer {
        for (shards[shards_deinitialized..shards_initialized]) |*shard| shard.deinit();
        allocator.free(shards);
    }
    const threads = try allocator.alloc(std.Thread, n_workers);
    defer allocator.free(threads);
    const build_errors = try allocator.alloc(?anyerror, n_workers);
    defer allocator.free(build_errors);
    @memset(build_errors, null);
    var spawned: usize = 0;
    var joined = false;
    errdefer if (!joined) for (threads[0..spawned]) |thread| thread.join();

    const chunk_size = entries.items.len / n_workers;
    const remainder = entries.items.len % n_workers;
    var offset: usize = 0;
    for (shards, 0..) |*shard, i| {
        shard.* = TrigramIndex.init(std.heap.c_allocator);
        shards_initialized += 1;
        const extra: usize = if (i < remainder) 1 else 0;
        const count = chunk_size + extra;
        const chunk = entries.items[offset .. offset + count];
        offset += count;
        shard.index.ensureTotalCapacity(32768) catch {};
        shard.path_to_id.ensureTotalCapacity(@intCast(count)) catch {};
        threads[i] = try std.Thread.spawn(.{}, cachedTrigramBuildWorker, .{ shard, chunk, &build_errors[i] });
        spawned += 1;
    }
    const profile_spawn_done: i128 = if (profile) cio.nanoTimestamp() else 0;
    for (threads[0..spawned]) |thread| thread.join();
    joined = true;
    const profile_build_done: i128 = if (profile) cio.nanoTimestamp() else 0;
    for (build_errors) |maybe_error| {
        if (maybe_error) |err| return err;
    }

    for (shards) |*shard| {
        try tmp_tri.mergeBulkShard(shard);
        shard.deinit();
        shards_deinitialized += 1;
    }
    if (profile) {
        const now = cio.nanoTimestamp();
        std.debug.print("[index-profile] trigram files={d} workers={d} total={d:.1}ms collect={d:.1}ms setup_spawn={d:.1}ms build={d:.1}ms merge_free={d:.1}ms\n", .{
            entries.items.len,
            n_workers,
            nsToMs(now - profile_start),
            nsToMs(profile_collect_done - profile_start),
            nsToMs(profile_spawn_done - profile_collect_done),
            nsToMs(profile_build_done - profile_spawn_done),
            nsToMs(now - profile_build_done),
        });
    }
    return tmp_tri;
}

pub fn initialScanWithTrigrams(
    io: std.Io,
    store: *Store,
    explorer: *Explorer,
    root: []const u8,
    allocator: std.mem.Allocator,
    trigram_alloc: std.mem.Allocator,
    skip_outlines: bool,
) !?*TrigramIndex {
    var owned_dir: ?std.Io.Dir = null;
    const dir = if (explorer.root_dir) |stable| blk: {
        if (!project_file.rootMatchesPath(io, stable, root)) return error.ProjectRootChanged;
        break :blk stable;
    } else blk: {
        owned_dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
        break :blk owned_dir.?;
    };
    defer if (owned_dir) |owned| owned.close(io);

    var entries = try collectInitialScanEntries(io, store, dir, allocator, true);
    defer {
        for (entries.items) |entry| allocator.free(entry.path);
        entries.deinit(allocator);
    }
    if (entries.items.len == 0) return null;

    const cpu_count = std.Thread.getCpuCount() catch 1;
    const n_workers = @max(@as(usize, 1), @min(@as(usize, @intCast(cpu_count)), @min(entries.items.len, 8)));

    // Single-worker fast path
    var tmp_tri = try trigram_alloc.create(TrigramIndex);
    tmp_tri.* = TrigramIndex.init(trigram_alloc);
    tmp_tri.owns_paths = true;
    tmp_tri.index.ensureTotalCapacity(131072) catch {};
    tmp_tri.path_to_id.ensureTotalCapacity(@intCast(@min(entries.items.len, 65536))) catch {};

    if (n_workers == 1) {
        for (entries.items) |entry| {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const parsed = parseInitialScanEntry(io, dir, entry, arena.allocator(), arena.allocator()) catch null;
            if (parsed) |file| {
                if (!skip_outlines) {
                    explorer.commitParsedFileOwnedOutline(file.path, file.content, file.outline, true, true) catch continue;
                }
                if (file.content.len <= max_trigram_file_bytes) {
                    tmp_tri.indexFile(file.path, file.content) catch {};
                }
            }
        }
        return tmp_tri;
    }

    // Shards use c_allocator so no caller-provided allocator is touched from
    // multiple threads. The destination (tmp_tri) uses trigram_alloc, which in
    // practice is also c_allocator, so mergeBulkShard transfers posting lists.
    const shards = try allocator.alloc(TrigramIndex, n_workers);
    var shards_initialized: usize = 0;
    var shards_deinitialized: usize = 0;
    defer {
        for (shards[shards_deinitialized..shards_initialized]) |*shard| shard.deinit();
        allocator.free(shards);
    }
    const threads = try allocator.alloc(std.Thread, n_workers);
    defer allocator.free(threads);
    const build_errors = try allocator.alloc(?anyerror, n_workers);
    defer allocator.free(build_errors);
    @memset(build_errors, null);
    var spawned: usize = 0;
    var joined = false;
    errdefer if (!joined) for (threads[0..spawned]) |thread| thread.join();

    const chunk_size = entries.items.len / n_workers;
    const remainder = entries.items.len % n_workers;

    if (skip_outlines) {
        // Read files + build trigrams into private shards in parallel.
        var offset: usize = 0;
        for (shards, 0..) |*shard, i| {
            shard.* = TrigramIndex.init(std.heap.c_allocator);
            shards_initialized += 1;
            const extra: usize = if (i < remainder) 1 else 0;
            const count = chunk_size + extra;
            const chunk = entries.items[offset .. offset + count];
            offset += count;
            shard.index.ensureTotalCapacity(32768) catch {};
            shard.path_to_id.ensureTotalCapacity(@intCast(count)) catch {};
            threads[i] = try std.Thread.spawn(.{}, readAndBuildTrigramShardWorker, .{ io, shard, dir, chunk, &build_errors[i] });
            spawned += 1;
        }
        for (threads[0..spawned]) |thread| thread.join();
        joined = true;
        for (build_errors) |maybe_error| {
            if (maybe_error) |err| return err;
        }
        for (shards) |*shard| {
            try tmp_tri.mergeBulkShard(shard);
            shard.deinit();
            shards_deinitialized += 1;
        }
    } else {
        // Parse outlines + build trigrams into private shards in parallel.
        const workers = try allocator.alloc(WorkerParsedResults, n_workers);
        defer allocator.free(workers);
        for (workers) |*worker| worker.* = WorkerParsedResults.init(std.heap.page_allocator);
        var workers_committed: usize = 0;
        defer {
            for (workers[workers_committed..]) |*worker| worker.deinit(allocator);
        }

        var offset: usize = 0;
        for (workers, 0..) |*worker, i| {
            shards[i] = TrigramIndex.init(std.heap.c_allocator);
            shards_initialized += 1;
            const extra: usize = if (i < remainder) 1 else 0;
            const count = chunk_size + extra;
            const chunk = entries.items[offset .. offset + count];
            offset += count;
            try worker.prepare(count);
            threads[i] = try std.Thread.spawn(.{}, initialScanWorker, .{ io, worker, dir, chunk, null, &shards[i] });
            spawned += 1;
        }
        // Commit outlines serially while workers may still be parsing. Trigram
        // building happens on the worker threads inside the shards; the main
        // thread only merges completed shards at the end.
        for (workers, 0..) |*worker, wi| {
            for (0..worker.items.len) |item_index| {
                if (worker.takeReady(io, item_index)) |file| {
                    explorer.commitParsedFileAdoptOutline(file.path, file.content, file.outline, true, true) catch continue;
                }
            }
            threads[wi].join();
            worker.deinit(allocator);
            workers_committed += 1;
        }
        joined = true;
        for (shards) |*shard| {
            try tmp_tri.mergeBulkShard(shard);
            shard.deinit();
            shards_deinitialized += 1;
        }
    }
    return tmp_tri;
}

/// Called from main thread to do the initial scan before listening.
pub fn initialScan(io: std.Io, store: *Store, explorer: *Explorer, root: []const u8, allocator: std.mem.Allocator, skip_trigram: bool) !void {
    const worker_count = blk: {
        if (cio.posixGetenv("CODEDB_SCAN_WORKERS")) |raw| {
            const parsed = std.fmt.parseInt(usize, raw, 10) catch 0;
            if (parsed > 0) break :blk parsed;
        }
        const cpu_count = std.Thread.getCpuCount() catch 1;
        break :blk @min(@as(usize, @intCast(cpu_count)), 8);
    };
    try initialScanWithWorkerCount(io, store, explorer, root, allocator, skip_trigram, worker_count);
}

/// Fast index: parse symbols/outline only, skip expensive word+trigram indexes.
fn indexFileOutline(io: std.Io, explorer: *Explorer, dir: std.Io.Dir, path: []const u8, allocator: std.mem.Allocator) !void {
    if (shouldSkipFile(path)) return;
    const stat = try dir.statFile(io, path, .{ .follow_symlinks = false });
    if (stat.kind != .file) return;
    const content = (try readIndexableFile(io, dir, path, allocator, stat.size, false)) orelse return;
    defer allocator.free(content);
    try explorer.indexFileOutlineOnly(path, content);
}

const watch_kqueue = switch (builtin.os.tag) {
    .macos, .ios, .tvos, .watchos, .visionos, .driverkit => true,
    else => false,
};
const watch_inotify = builtin.os.tag == .linux;

fn raiseNofileLimit() void {
    if (builtin.os.tag == .windows) return;
    var lim = std.posix.getrlimit(.NOFILE) catch return;
    if (lim.cur < lim.max) {
        lim.cur = lim.max;
        std.posix.setrlimit(.NOFILE, lim) catch {};
    }
}

const FileChangeWatch = struct {
    alloc: std.mem.Allocator,
    active: bool = false,
    armed_files: u32 = 0,
    armed_dirs: u32 = 0,
    kq: i32 = -1,
    inotify_fd: i32 = -1,
    files: std.ArrayList(std.posix.fd_t) = .empty,
    unwatched: std.ArrayList([]u8) = .empty,
    unwatched_dirs: std.ArrayList([]u8) = .empty,
    ident_to_path: std.AutoHashMap(usize, []u8),
    ident_to_dir: std.AutoHashMap(usize, []u8),
    wd_to_dir: std.AutoHashMap(i32, []u8),

    fn init(alloc: std.mem.Allocator) FileChangeWatch {
        return .{
            .alloc = alloc,
            .ident_to_path = .init(alloc),
            .ident_to_dir = .init(alloc),
            .wd_to_dir = .init(alloc),
        };
    }

    fn deinit(self: *FileChangeWatch, io: std.Io) void {
        self.reset(io);
        self.ident_to_path.deinit();
        self.ident_to_dir.deinit();
        self.wd_to_dir.deinit();
        self.files.deinit(self.alloc);
        self.unwatched.deinit(self.alloc);
        self.unwatched_dirs.deinit(self.alloc);
    }

    fn reset(self: *FileChangeWatch, io: std.Io) void {
        _ = io;
        var pit = self.ident_to_path.iterator();
        while (pit.next()) |kv| self.alloc.free(kv.value_ptr.*);
        self.ident_to_path.clearRetainingCapacity();
        var pdit = self.ident_to_dir.iterator();
        while (pdit.next()) |kv| self.alloc.free(kv.value_ptr.*);
        self.ident_to_dir.clearRetainingCapacity();
        var dit = self.wd_to_dir.iterator();
        while (dit.next()) |kv| self.alloc.free(kv.value_ptr.*);
        self.wd_to_dir.clearRetainingCapacity();
        if (comptime watch_kqueue or watch_inotify) {
            for (self.files.items) |fd| cio.closeFd(@intCast(fd));
        }
        self.files.clearRetainingCapacity();
        for (self.unwatched.items) |p| self.alloc.free(p);
        self.unwatched.clearRetainingCapacity();
        for (self.unwatched_dirs.items) |p| self.alloc.free(p);
        self.unwatched_dirs.clearRetainingCapacity();
        if (self.kq >= 0) {
            cio.closeFd(self.kq);
            self.kq = -1;
        }
        if (self.inotify_fd >= 0) {
            cio.closeFd(self.inotify_fd);
            self.inotify_fd = -1;
        }
        self.active = false;
    }

    fn rememberUnwatched(self: *FileChangeWatch, path: []const u8) void {
        for (self.unwatched.items) |existing| if (std.mem.eql(u8, existing, path)) return;
        const duped = self.alloc.dupe(u8, path) catch return;
        self.unwatched.append(self.alloc, duped) catch self.alloc.free(duped);
    }

    fn rememberUnwatchedDir(self: *FileChangeWatch, path: []const u8) void {
        for (self.unwatched_dirs.items) |existing| if (std.mem.eql(u8, existing, path)) return;
        const duped = self.alloc.dupe(u8, path) catch return;
        self.unwatched_dirs.append(self.alloc, duped) catch self.alloc.free(duped);
    }

    fn forgetUnwatchedDir(self: *FileChangeWatch, path: []const u8) void {
        var i: usize = 0;
        while (i < self.unwatched_dirs.items.len) : (i += 1) {
            if (!std.mem.eql(u8, self.unwatched_dirs.items[i], path)) continue;
            self.alloc.free(self.unwatched_dirs.swapRemove(i));
            return;
        }
    }

    fn addUnwatched(self: *const FileChangeWatch, dirty: *DirtySet) void {
        for (self.unwatched.items) |path| {
            dirty.put(path, {}) catch {};
        }
        for (self.unwatched_dirs.items) |path| dirty.put(path, {}) catch {};
    }

    fn arm(self: *FileChangeWatch, io: std.Io, root_dir: std.Io.Dir, known: *const FileMap, dirs: *const DirMap) void {
        self.reset(io);
        self.armed_files = @intCast(known.count());
        self.armed_dirs = @intCast(dirs.count());
        if (comptime watch_kqueue) {
            self.armKqueue(root_dir, known, dirs);
        } else if (comptime watch_inotify) {
            self.armInotify(io, root_dir, dirs);
        }
    }

    fn armKqueue(self: *FileChangeWatch, root_dir: std.Io.Dir, known: *const FileMap, dirs: *const DirMap) void {
        if (comptime !watch_kqueue) return;
        if (known.count() > 32768) return;
        raiseNofileLimit();
        const kq = std.c.kqueue();
        if (kq < 0) return;
        self.kq = kq;
        const vnode_flags = std.c.NOTE.WRITE | std.c.NOTE.DELETE | std.c.NOTE.RENAME | std.c.NOTE.EXTEND;
        // Directories cover the scan-to-arm gap and provide replacement
        // identity before the more numerous per-file watches are installed.
        self.watchKqueueDir(root_dir.handle, "", vnode_flags);
        var dit = dirs.iterator();
        while (dit.next()) |kv| {
            const rel = kv.key_ptr.*;
            if (rel.len == 0) continue;
            self.watchKqueueDir(root_dir.handle, rel, vnode_flags);
        }
        var it = known.iterator();
        while (it.next()) |kv| {
            const path = kv.key_ptr.*;
            self.watchKqueueFile(root_dir.handle, path, vnode_flags);
        }
        if (std.posix.openat(std.posix.AT.FDCWD, "/tmp/codedb-notify", .{ .ACCMODE = .RDONLY, .EVTONLY = true, .CLOEXEC = true }, 0)) |nfd| {
            if (self.addVnode(nfd, std.c.NOTE.WRITE | std.c.NOTE.EXTEND)) {
                self.files.append(self.alloc, nfd) catch cio.closeFd(nfd);
            } else {
                cio.closeFd(nfd);
            }
        } else |_| {}
        self.active = self.ident_to_path.count() > 0 or self.ident_to_dir.count() > 0 or self.unwatched.items.len > 0 or self.unwatched_dirs.items.len > 0;
    }

    fn addKqueueFileWatch(self: *FileChangeWatch, root_fd: std.posix.fd_t, path: []const u8, fflags: u32) ?std.posix.fd_t {
        if (comptime !watch_kqueue) return null;
        const fd = std.posix.openat(root_fd, path, .{ .ACCMODE = .RDONLY, .EVTONLY = true, .CLOEXEC = true }, 0) catch {
            self.rememberUnwatched(path);
            return null;
        };
        if (!self.addVnode(fd, fflags)) {
            cio.closeFd(fd);
            self.rememberUnwatched(path);
            return null;
        }
        const duped = self.alloc.dupe(u8, path) catch {
            cio.closeFd(fd);
            return null;
        };
        self.ident_to_path.put(@intCast(fd), duped) catch {
            self.alloc.free(duped);
            cio.closeFd(fd);
            return null;
        };
        self.files.append(self.alloc, fd) catch {
            if (self.ident_to_path.fetchRemove(@intCast(fd))) |entry| self.alloc.free(entry.value);
            cio.closeFd(fd);
            self.rememberUnwatched(path);
            return null;
        };
        return fd;
    }

    fn watchKqueueFile(self: *FileChangeWatch, root_fd: std.posix.fd_t, path: []const u8, fflags: u32) void {
        _ = self.addKqueueFileWatch(root_fd, path, fflags);
    }

    fn findKqueueFile(self: *const FileChangeWatch, path: []const u8) ?std.posix.fd_t {
        var it = self.ident_to_path.iterator();
        while (it.next()) |kv| {
            if (std.mem.eql(u8, kv.value_ptr.*, path)) return @intCast(kv.key_ptr.*);
        }
        return null;
    }

    fn dropKqueueFile(self: *FileChangeWatch, fd: std.posix.fd_t) void {
        if (comptime !watch_kqueue) return;
        if (self.ident_to_path.fetchRemove(@intCast(fd))) |kv| self.alloc.free(kv.value);
        self.dropKqueueFd(fd);
    }

    fn findKqueueDir(self: *const FileChangeWatch, path: []const u8) ?std.posix.fd_t {
        var it = self.ident_to_dir.iterator();
        while (it.next()) |kv| {
            if (std.mem.eql(u8, kv.value_ptr.*, path)) return @intCast(kv.key_ptr.*);
        }
        return null;
    }

    fn dropKqueueDir(self: *FileChangeWatch, fd: std.posix.fd_t) void {
        if (comptime !watch_kqueue) return;
        if (self.ident_to_dir.fetchRemove(@intCast(fd))) |kv| self.alloc.free(kv.value);
        self.dropKqueueFd(fd);
    }

    fn dropKqueueFd(self: *FileChangeWatch, fd: std.posix.fd_t) void {
        if (comptime !watch_kqueue) return;
        var i: usize = 0;
        while (i < self.files.items.len) {
            if (self.files.items[i] == fd) {
                _ = self.files.swapRemove(i);
                break;
            }
            i += 1;
        }
        cio.closeFd(fd);
    }

    fn hasWatchedDir(self: *const FileChangeWatch, path: []const u8) bool {
        if (comptime watch_kqueue) return self.findKqueueDir(path) != null;
        if (comptime watch_inotify) return self.findInotifyDir(path) != null;
        return false;
    }

    fn pathWithinNonRootDir(path: []const u8, dir: []const u8) bool {
        return dir.len > 0 and path.len > dir.len and path[dir.len] == '/' and std.mem.startsWith(u8, path, dir);
    }

    fn affectedByDirtyDirectory(self: *const FileChangeWatch, dirty: *const DirtySet, path: []const u8) bool {
        var it = dirty.keyIterator();
        while (it.next()) |dirty_path| {
            if (!self.hasWatchedDir(dirty_path.*)) continue;
            if (std.mem.eql(u8, path, dirty_path.*) or pathWithinNonRootDir(path, dirty_path.*)) return true;
        }
        return false;
    }

    fn rememberRearmPath(paths: *std.StringHashMap(void), path: []const u8) void {
        if (paths.contains(path)) return;
        const copy = paths.allocator.dupe(u8, path) catch return;
        paths.put(copy, {}) catch {};
    }

    fn rearmDirty(self: *FileChangeWatch, io: std.Io, root_dir: std.Io.Dir, dirty: *const DirtySet) void {
        if (comptime !watch_kqueue and !watch_inotify) return;
        if (dirty.count() == 0) return;

        var dirs_to_rearm = std.StringHashMap(void).init(dirty.allocator);
        defer dirs_to_rearm.deinit();
        if (comptime watch_kqueue) {
            var it = self.ident_to_dir.iterator();
            while (it.next()) |entry| {
                if (self.affectedByDirtyDirectory(dirty, entry.value_ptr.*)) rememberRearmPath(&dirs_to_rearm, entry.value_ptr.*);
            }
        } else if (comptime watch_inotify) {
            var it = self.wd_to_dir.iterator();
            while (it.next()) |entry| {
                if (self.affectedByDirtyDirectory(dirty, entry.value_ptr.*)) rememberRearmPath(&dirs_to_rearm, entry.value_ptr.*);
            }
        }
        for (self.unwatched_dirs.items) |path| {
            if (dirty.contains(path)) rememberRearmPath(&dirs_to_rearm, path);
        }

        if (comptime watch_kqueue) {
            var files_to_rearm = std.StringHashMap(void).init(dirty.allocator);
            defer files_to_rearm.deinit();
            var files = self.ident_to_path.iterator();
            while (files.next()) |entry| {
                const path = entry.value_ptr.*;
                if (dirty.contains(path) or self.affectedByDirtyDirectory(dirty, path)) rememberRearmPath(&files_to_rearm, path);
            }
            const flags = std.c.NOTE.WRITE | std.c.NOTE.DELETE | std.c.NOTE.RENAME | std.c.NOTE.EXTEND;
            var dirs_it = dirs_to_rearm.keyIterator();
            while (dirs_it.next()) |path| self.rearmKqueueDir(root_dir.handle, path.*, flags);
            var files_it = files_to_rearm.keyIterator();
            while (files_it.next()) |path| self.rearmKqueueFile(root_dir.handle, path.*, flags);
        } else if (comptime watch_inotify) {
            const mask = inotifyDirectoryMask();
            var dirs_it = dirs_to_rearm.keyIterator();
            while (dirs_it.next()) |path| self.rearmInotifyDir(io, root_dir, path.*, mask);
        }
    }

    fn addVnode(self: *FileChangeWatch, fd: std.posix.fd_t, fflags: u32) bool {
        if (comptime !watch_kqueue) return false;
        var ev = std.mem.zeroes(std.c.Kevent);
        ev.ident = @intCast(fd);
        ev.filter = std.c.EVFILT.VNODE;
        ev.flags = std.c.EV.ADD | std.c.EV.CLEAR;
        ev.fflags = fflags;
        const rc = std.c.kevent(self.kq, @ptrCast(&ev), 1, @as([*]std.c.Kevent, @ptrCast(&ev)), 0, null);
        return rc >= 0;
    }

    fn addKqueueDirWatch(self: *FileChangeWatch, root_fd: std.posix.fd_t, rel: []const u8, fflags: u32) ?std.posix.fd_t {
        if (comptime !watch_kqueue) return null;
        const open_rel = if (rel.len == 0) "." else rel;
        const fd = std.posix.openat(root_fd, open_rel, .{ .ACCMODE = .RDONLY, .EVTONLY = true, .CLOEXEC = true, .DIRECTORY = true }, 0) catch {
            self.rememberUnwatchedDir(rel);
            return null;
        };
        if (!self.addVnode(fd, fflags)) {
            cio.closeFd(fd);
            self.rememberUnwatchedDir(rel);
            return null;
        }
        const duped = self.alloc.dupe(u8, rel) catch {
            cio.closeFd(fd);
            self.rememberUnwatchedDir(rel);
            return null;
        };
        self.ident_to_dir.put(@intCast(fd), duped) catch {
            self.alloc.free(duped);
            cio.closeFd(fd);
            self.rememberUnwatchedDir(rel);
            return null;
        };
        self.files.append(self.alloc, fd) catch {
            if (self.ident_to_dir.fetchRemove(@intCast(fd))) |entry| self.alloc.free(entry.value);
            cio.closeFd(fd);
            self.rememberUnwatchedDir(rel);
            return null;
        };
        self.forgetUnwatchedDir(rel);
        return fd;
    }

    fn watchKqueueDir(self: *FileChangeWatch, root_fd: std.posix.fd_t, rel: []const u8, fflags: u32) void {
        _ = self.addKqueueDirWatch(root_fd, rel, fflags);
    }

    fn rearmKqueueDir(self: *FileChangeWatch, root_fd: std.posix.fd_t, rel: []const u8, fflags: u32) void {
        if (comptime !watch_kqueue) return;
        const old_fd = self.findKqueueDir(rel);
        if (self.addKqueueDirWatch(root_fd, rel, fflags) == null) return;
        if (old_fd) |fd| self.dropKqueueDir(fd);
    }

    fn rearmKqueueFile(self: *FileChangeWatch, root_fd: std.posix.fd_t, path: []const u8, fflags: u32) void {
        if (comptime !watch_kqueue) return;
        const old_fd = self.findKqueueFile(path);
        if (self.addKqueueFileWatch(root_fd, path, fflags) == null) return;
        if (old_fd) |fd| self.dropKqueueFile(fd);
    }

    fn inotifyDirectoryMask() u32 {
        return std.os.linux.IN.MODIFY | std.os.linux.IN.CREATE | std.os.linux.IN.DELETE |
            std.os.linux.IN.MOVED_FROM | std.os.linux.IN.MOVED_TO | std.os.linux.IN.ATTRIB |
            std.os.linux.IN.DELETE_SELF | std.os.linux.IN.MOVE_SELF;
    }

    fn armInotify(self: *FileChangeWatch, io: std.Io, root_dir: std.Io.Dir, dirs: *const DirMap) void {
        if (comptime !watch_inotify) return;
        const rc = std.os.linux.inotify_init1(std.os.linux.IN.CLOEXEC);
        if (std.os.linux.errno(rc) != .SUCCESS) return;
        self.inotify_fd = @intCast(rc);
        const mask = inotifyDirectoryMask();
        self.addInotifyWatchDir(root_dir, "", mask);
        var dit = dirs.iterator();
        while (dit.next()) |kv| {
            const rel = kv.key_ptr.*;
            if (rel.len == 0) continue;
            const child = root_dir.openDir(io, rel, .{ .follow_symlinks = false }) catch {
                self.rememberUnwatchedDir(rel);
                continue;
            };
            self.addInotifyWatchDir(child, rel, mask);
            child.close(io);
        }
        _ = self.addInotifyWatch("/tmp/codedb-notify", null, std.os.linux.IN.MODIFY | std.os.linux.IN.CLOSE_WRITE);
        self.active = self.wd_to_dir.count() > 0 or self.unwatched_dirs.items.len > 0;
    }

    fn addInotifyWatchDir(self: *FileChangeWatch, dir: std.Io.Dir, rel: []const u8, mask: u32) void {
        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/proc/self/fd/{d}", .{dir.handle}) catch return;
        if (self.addInotifyWatch(path, rel, mask)) self.forgetUnwatchedDir(rel) else self.rememberUnwatchedDir(rel);
    }

    fn addInotifyWatch(self: *FileChangeWatch, path: []const u8, rel: ?[]const u8, mask: u32) bool {
        if (comptime !watch_inotify) return false;
        const wd = self.rawAddInotifyWatch(path, mask) orelse return false;
        if (rel) |dir_rel| {
            if (!self.rememberInotifyWatch(wd, dir_rel)) {
                self.removeInotifyWatch(wd);
                return false;
            }
        }
        return true;
    }

    fn rawAddInotifyWatch(self: *FileChangeWatch, path: []const u8, mask: u32) ?i32 {
        if (comptime !watch_inotify) return null;
        var zbuf: [std.fs.max_path_bytes]u8 = undefined;
        if (path.len >= zbuf.len) return null;
        @memcpy(zbuf[0..path.len], path);
        zbuf[path.len] = 0;
        const wd_rc = std.os.linux.inotify_add_watch(self.inotify_fd, @ptrCast(&zbuf), mask);
        if (std.os.linux.errno(wd_rc) != .SUCCESS) return null;
        return @intCast(wd_rc);
    }

    fn rememberInotifyWatch(self: *FileChangeWatch, wd: i32, rel: []const u8) bool {
        if (comptime !watch_inotify) return false;
        const duped = self.alloc.dupe(u8, rel) catch return false;
        const slot = self.wd_to_dir.getOrPut(wd) catch {
            self.alloc.free(duped);
            return false;
        };
        if (slot.found_existing) self.alloc.free(slot.value_ptr.*);
        slot.value_ptr.* = duped;
        return true;
    }

    fn findInotifyDir(self: *const FileChangeWatch, rel: []const u8) ?i32 {
        var it = self.wd_to_dir.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.*, rel)) return entry.key_ptr.*;
        }
        return null;
    }

    fn removeInotifyWatch(self: *FileChangeWatch, wd: i32) void {
        if (comptime !watch_inotify) return;
        if (self.wd_to_dir.fetchRemove(wd)) |entry| self.alloc.free(entry.value);
        _ = std.os.linux.inotify_rm_watch(self.inotify_fd, wd);
    }

    fn rearmInotifyDir(self: *FileChangeWatch, io: std.Io, root_dir: std.Io.Dir, rel: []const u8, mask: u32) void {
        if (comptime !watch_inotify) return;
        const old_wd = self.findInotifyDir(rel);
        const dir = if (rel.len == 0) root_dir else root_dir.openDir(io, rel, .{ .follow_symlinks = false }) catch {
            self.rememberUnwatchedDir(rel);
            return;
        };
        defer if (rel.len != 0) dir.close(io);
        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/proc/self/fd/{d}", .{dir.handle}) catch return;
        const new_wd = self.rawAddInotifyWatch(path, mask) orelse {
            self.rememberUnwatchedDir(rel);
            return;
        };
        if (old_wd != null and new_wd == old_wd.?) {
            self.forgetUnwatchedDir(rel);
            return;
        }
        if (!self.rememberInotifyWatch(new_wd, rel)) {
            _ = std.os.linux.inotify_rm_watch(self.inotify_fd, new_wd);
            self.rememberUnwatchedDir(rel);
            return;
        }
        if (old_wd) |wd| self.removeInotifyWatch(wd);
        self.forgetUnwatchedDir(rel);
    }

    fn poll(self: *FileChangeWatch, dirty: *DirtySet, timeout_ms: i32) void {
        if (!self.active) {
            cio.sleepMs(@intCast(timeout_ms));
            return;
        }
        if (comptime watch_kqueue) {
            self.pollKqueue(dirty, timeout_ms);
        } else if (comptime watch_inotify) {
            self.pollInotify(dirty, timeout_ms);
        } else {
            cio.sleepMs(@intCast(timeout_ms));
        }
    }

    fn pollKqueue(self: *FileChangeWatch, dirty: *DirtySet, timeout_ms: i32) void {
        if (comptime !watch_kqueue) return;
        if (self.kq < 0) {
            cio.sleepMs(@intCast(timeout_ms));
            return;
        }
        const ts = std.c.timespec{
            .sec = @divFloor(timeout_ms, 1000),
            .nsec = @intCast(@mod(timeout_ms, 1000) * 1_000_000),
        };
        var events: [64]std.c.Kevent = undefined;
        const n = std.c.kevent(self.kq, @as([*]const std.c.Kevent, @ptrCast(&events)), 0, &events, events.len, &ts);
        if (n <= 0) return;
        var i: usize = 0;
        while (i < @as(usize, @intCast(n))) : (i += 1) {
            if (self.ident_to_path.get(events[i].ident)) |path| {
                const copy = dirty.allocator.dupe(u8, path) catch continue;
                dirty.put(copy, {}) catch {};
            }
            if (self.ident_to_dir.get(events[i].ident)) |path| {
                const copy = dirty.allocator.dupe(u8, path) catch continue;
                dirty.put(copy, {}) catch {};
            }
        }
    }

    fn markAllWatchedDirsDirty(self: *const FileChangeWatch, dirty: *DirtySet) void {
        if (comptime watch_kqueue) {
            var it = self.ident_to_dir.iterator();
            while (it.next()) |entry| {
                const copy = dirty.allocator.dupe(u8, entry.value_ptr.*) catch continue;
                dirty.put(copy, {}) catch {};
            }
        } else if (comptime watch_inotify) {
            var it = self.wd_to_dir.iterator();
            while (it.next()) |entry| {
                const copy = dirty.allocator.dupe(u8, entry.value_ptr.*) catch continue;
                dirty.put(copy, {}) catch {};
            }
        }
    }

    fn pollInotify(self: *FileChangeWatch, dirty: *DirtySet, timeout_ms: i32) void {
        if (comptime !watch_inotify) return;
        if (self.inotify_fd < 0) {
            cio.sleepMs(@intCast(timeout_ms));
            return;
        }
        var pfd = [1]std.posix.pollfd{.{
            .fd = self.inotify_fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        _ = std.posix.poll(&pfd, timeout_ms) catch {};
        if (pfd[0].revents & std.posix.POLL.IN == 0) return;
        var buf: [4096]u8 align(@alignOf(std.os.linux.inotify_event)) = undefined;
        const n = std.posix.read(self.inotify_fd, &buf) catch return;
        var offset: usize = 0;
        while (offset + @sizeOf(std.os.linux.inotify_event) <= n) {
            const ev: *const std.os.linux.inotify_event = @ptrCast(@alignCast(buf[offset..].ptr));
            const ev_size = @sizeOf(std.os.linux.inotify_event) + ev.len;
            if (offset + ev_size > n) break;
            if (ev.mask & std.os.linux.IN.Q_OVERFLOW != 0) {
                self.markAllWatchedDirsDirty(dirty);
                offset += ev_size;
                continue;
            }
            if (self.wd_to_dir.get(ev.wd)) |dir_rel| {
                if (ev.mask & (std.os.linux.IN.DELETE_SELF | std.os.linux.IN.MOVE_SELF | std.os.linux.IN.IGNORED) != 0) {
                    const copy = dirty.allocator.dupe(u8, dir_rel) catch {
                        offset += ev_size;
                        continue;
                    };
                    dirty.put(copy, {}) catch {};
                }
                if (ev.getName()) |name| {
                    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
                    const rel = if (dir_rel.len == 0) name else std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_rel, name }) catch {
                        offset += ev_size;
                        continue;
                    };
                    const copy = dirty.allocator.dupe(u8, rel) catch {
                        offset += ev_size;
                        continue;
                    };
                    dirty.put(copy, {}) catch {};
                }
            }
            offset += ev_size;
        }
    }
};

fn armAndCloseGap(
    io: std.Io,
    watch: *FileChangeWatch,
    root_dir: std.Io.Dir,
    store: *Store,
    explorer: *Explorer,
    queue: *EventQueue,
    known: *FileMap,
    dirs: *DirMap,
    root: []const u8,
    persistent: std.mem.Allocator,
) void {
    var pass: usize = 0;
    while (pass < 2) : (pass += 1) {
        watch.arm(io, root_dir, known, dirs);
        var arena = std.heap.ArenaAllocator.init(persistent);
        defer arena.deinit();
        incrementalDiffInner(io, store, explorer, queue, known, dirs, root, persistent, arena.allocator()) catch |err| {
            std.log.err("watcher: post-arm reconcile failed: {}", .{err});
            return;
        };
        if (known.count() == watch.armed_files and dirs.count() == watch.armed_dirs) return;
    }
    watch.arm(io, root_dir, known, dirs);
}

test "file watcher remains pinned to opened root after pathname retarget" {
    if (!(comptime watch_kqueue or watch_inotify)) return;
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "live");
    try tmp.dir.createDirPath(io, "decoy");
    try tmp.dir.writeFile(io, .{ .sub_path = "live/keep.py", .data = "def original():\n    return 1\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "decoy/keep.py", .data = "def decoy():\n    return 1\n" });
    var live_buf: [std.fs.max_path_bytes]u8 = undefined;
    const live_len = try tmp.dir.realPathFile(io, "live", &live_buf);
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    explorer.setRoot(io, live_buf[0..live_len]);
    const root_dir = explorer.root_dir orelse return error.TestUnexpectedResult;
    var known = FileMap.init(testing.allocator);
    defer {
        var it = known.keyIterator();
        while (it.next()) |path| testing.allocator.free(path.*);
        known.deinit();
    }
    const known_key = try testing.allocator.dupe(u8, "keep.py");
    try known.put(known_key, .{ .mtime = 0, .size = 0, .hash = 0, .seen = false });
    var dirs = DirMap.init(testing.allocator);
    defer {
        var it = dirs.keyIterator();
        while (it.next()) |path| testing.allocator.free(path.*);
        dirs.deinit();
    }
    const root_key = try testing.allocator.dupe(u8, "");
    try dirs.put(root_key, .{ .mtime_ns = 0, .ctime_ns = 0, .inode = 0 });
    var watch = FileChangeWatch.init(testing.allocator);
    defer watch.deinit(io);
    watch.arm(io, root_dir, &known, &dirs);
    try testing.expect(watch.active);
    try tmp.dir.rename("live", tmp.dir, "moved", io);
    try tmp.dir.rename("decoy", tmp.dir, "live", io);
    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var dirty = DirtySet.init(arena.allocator());
        defer dirty.deinit();
        watch.poll(&dirty, 100);
    }
    try tmp.dir.writeFile(io, .{ .sub_path = "live/keep.py", .data = "def decoy_changed():\n    return 2\n" });
    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var dirty = DirtySet.init(arena.allocator());
        defer dirty.deinit();
        watch.poll(&dirty, 100);
        try testing.expectEqual(@as(u32, 0), dirty.count());
    }
    try tmp.dir.writeFile(io, .{ .sub_path = "moved/keep.py", .data = "def original_changed():\n    return 3\n" });
    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var dirty = DirtySet.init(arena.allocator());
        defer dirty.deinit();
        watch.poll(&dirty, 1000);
        try testing.expect(dirty.contains("keep.py") or dirty.contains(""));
    }
}

test "directory watches follow repeated equal-count subtree replacements" {
    if (!(comptime watch_kqueue or watch_inotify)) return;
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "project/src/nested");
    try tmp.dir.writeFile(io, .{ .sub_path = "project/src/nested/keep.py", .data = "VALUE = 'initial'\n" });
    var stage_generation: usize = 0;
    while (stage_generation < 30) : (stage_generation += 1) {
        var stage_dir_buf: [48]u8 = undefined;
        const stage_dir = try std.fmt.bufPrint(&stage_dir_buf, "stage-{d}/nested", .{stage_generation});
        try tmp.dir.createDirPath(io, stage_dir);
        var stage_file_buf: [64]u8 = undefined;
        const stage_file = try std.fmt.bufPrint(&stage_file_buf, "stage-{d}/nested/keep.py", .{stage_generation});
        var stage_content_buf: [64]u8 = undefined;
        const stage_content = try std.fmt.bufPrint(&stage_content_buf, "VALUE = 'stage-{d}'\n", .{stage_generation});
        try tmp.dir.writeFile(io, .{ .sub_path = stage_file, .data = stage_content });
    }
    const root_dir = try tmp.dir.openDir(io, "project", .{ .iterate = true, .follow_symlinks = false });
    defer root_dir.close(io);
    var known = FileMap.init(testing.allocator);
    defer {
        var it = known.keyIterator();
        while (it.next()) |path| testing.allocator.free(path.*);
        known.deinit();
    }
    const known_key = try testing.allocator.dupe(u8, "src/nested/keep.py");
    try known.put(known_key, .{ .mtime = 0, .size = 0, .hash = 0, .seen = false });
    var dirs = DirMap.init(testing.allocator);
    defer {
        var it = dirs.keyIterator();
        while (it.next()) |path| testing.allocator.free(path.*);
        dirs.deinit();
    }
    for ([_][]const u8{ "", "src", "src/nested" }) |path| {
        const key = try testing.allocator.dupe(u8, path);
        try dirs.put(key, .{ .mtime_ns = 0, .ctime_ns = 0, .inode = 0 });
    }
    var watch = FileChangeWatch.init(testing.allocator);
    defer watch.deinit(io);
    watch.arm(io, root_dir, &known, &dirs);
    try testing.expect(watch.active);
    const Poll = struct {
        fn untilAny(w: *FileChangeWatch, dirty: *DirtySet, first: []const u8, second: []const u8) !void {
            var attempt: usize = 0;
            while (attempt < 20) : (attempt += 1) {
                w.poll(dirty, 100);
                if (dirty.contains(first) or dirty.contains(second)) return;
            }
            return error.TestExpectedEqual;
        }
    };
    var generation: usize = 0;
    while (generation < 30) : (generation += 1) {
        var stage_buf: [32]u8 = undefined;
        const stage = try std.fmt.bufPrint(&stage_buf, "stage-{d}", .{generation});
        var retired_buf: [32]u8 = undefined;
        const retired = try std.fmt.bufPrint(&retired_buf, "retired-{d}", .{generation});
        try tmp.dir.rename("project/src", tmp.dir, retired, io);
        try tmp.dir.rename(stage, tmp.dir, "project/src", io);
        {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            var dirty = DirtySet.init(arena.allocator());
            defer dirty.deinit();
            try Poll.untilAny(&watch, &dirty, "src", "src");
            watch.rearmDirty(io, root_dir, &dirty);
        }
        var content_buf: [64]u8 = undefined;
        const content = try std.fmt.bufPrint(&content_buf, "VALUE = 'edited-{d}'\n", .{generation});
        try root_dir.writeFile(io, .{ .sub_path = "src/nested/keep.py", .data = content });
        {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            var dirty = DirtySet.init(arena.allocator());
            defer dirty.deinit();
            try Poll.untilAny(&watch, &dirty, "src/nested/keep.py", "src/nested");
            watch.rearmDirty(io, root_dir, &dirty);
        }
    }
    var save: usize = 0;
    while (save < 100) : (save += 1) {
        var content_buf: [64]u8 = undefined;
        const content = try std.fmt.bufPrint(&content_buf, "VALUE = 'save-{d}'\n", .{save});
        try root_dir.writeFile(io, .{ .sub_path = "src/nested/keep.py", .data = content });
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var dirty = DirtySet.init(arena.allocator());
        defer dirty.deinit();
        try Poll.untilAny(&watch, &dirty, "src/nested/keep.py", "src/nested");
        watch.rearmDirty(io, root_dir, &dirty);
    }
}

test "failed directory watch admission retries through dirty reconciliation" {
    if (!(comptime watch_kqueue or watch_inotify)) return;
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root_dir = try tmp.dir.openDir(io, ".", .{ .iterate = true });
    defer root_dir.close(io);
    var known = FileMap.init(testing.allocator);
    defer known.deinit();
    var dirs = DirMap.init(testing.allocator);
    defer {
        var it = dirs.keyIterator();
        while (it.next()) |path| testing.allocator.free(path.*);
        dirs.deinit();
    }
    for ([_][]const u8{ "", "late" }) |path| {
        const key = try testing.allocator.dupe(u8, path);
        try dirs.put(key, .{ .mtime_ns = 0, .ctime_ns = 0, .inode = 0 });
    }
    var watch = FileChangeWatch.init(testing.allocator);
    defer watch.deinit(io);
    watch.arm(io, root_dir, &known, &dirs);
    try testing.expect(watch.active);
    try testing.expectEqual(@as(usize, 1), watch.unwatched_dirs.items.len);
    try testing.expect(!watch.hasWatchedDir("late"));
    try tmp.dir.createDirPath(io, "late");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var dirty = DirtySet.init(arena.allocator());
    defer dirty.deinit();
    watch.addUnwatched(&dirty);
    try testing.expect(dirty.contains("late"));
    watch.rearmDirty(io, root_dir, &dirty);
    try testing.expect(watch.hasWatchedDir("late"));
    try testing.expectEqual(@as(usize, 0), watch.unwatched_dirs.items.len);
    watch.markAllWatchedDirsDirty(&dirty);
    try testing.expect(dirty.contains(""));
    try testing.expect(dirty.contains("late"));
}

/// Background thread: polls for incremental FS changes.
pub fn incrementalLoop(io: std.Io, store: *Store, explorer: *Explorer, queue: *EventQueue, root: []const u8, shutdown: *std.atomic.Value(bool), scan_done: *std.atomic.Value(bool)) void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const backing = gpa.allocator();

    // Wait for initial scan to finish before building our known-file snapshot.
    // This prevents double-indexing: initialScan does full indexing, then we
    // only pick up changes that happen after.
    while (!scan_done.load(.acquire)) {
        if (shutdown.load(.acquire)) return;
        cio.sleepMs(100);
    }
    const stable_root = explorer.root_dir orelse return;

    var known = FileMap.init(backing);
    defer {
        var iter = known.iterator();
        while (iter.next()) |kv| {
            backing.free(kv.key_ptr.*);
        }
        known.deinit();
    }
    var dirs = DirMap.init(backing);
    defer {
        var diter = dirs.iterator();
        while (diter.next()) |kv| backing.free(kv.key_ptr.*);
        dirs.deinit();
    }
    // Seed from the live Explorer, not the current tree. Files that exist
    // on disk but were missing from the snapshot (added before this daemon
    // started) must look new so the first reconcile indexes them. Seeding
    // from a tree walk used to stamp those files as already-known and they
    // stayed invisible until restart (#690).
    seedKnownFromExplorer(store, explorer, &known, backing) catch |err| {
        std.log.warn("watcher: could not seed known files: {}", .{err});
    };
    {
        var boot_arena = std.heap.ArenaAllocator.init(backing);
        defer boot_arena.deinit();
        incrementalDiffInner(io, store, explorer, queue, &known, &dirs, root, backing, boot_arena.allocator()) catch |err| {
            std.log.err("watcher: startup reconcile failed: {}", .{err});
        };
    }

    var watch = FileChangeWatch.init(backing);
    defer watch.deinit(io);
    armAndCloseGap(io, &watch, stable_root, store, explorer, queue, &known, &dirs, root, backing);

    // Track current git HEAD to detect branch switches (#116)
    var last_git_head: ?[40]u8 = git_mod.getGitHeadDir(io, stable_root, backing) catch null;

    // Cache .git/HEAD mtime so we only fork git rev-parse when the file changes (#254)
    var git_head_mtime: i128 = blk: {
        const st = stable_root.statFile(io, ".git/HEAD", .{}) catch break :blk -1;
        break :blk @intCast(st.mtime.nanoseconds);
    };

    while (!shutdown.load(.acquire)) {
        var wait_arena = std.heap.ArenaAllocator.init(backing);
        defer wait_arena.deinit();
        var dirty = DirtySet.init(wait_arena.allocator());

        if (watch.active) {
            watch.poll(&dirty, 2000);
        } else {
            cio.sleepMs(2 * std.time.ns_per_s / 1_000_000);
        }

        drainNotifyFile(io, store, explorer, queue, &known, backing);

        // Check if git HEAD changed — stat .git/HEAD mtime first to skip fork+exec (#254)
        var current_head: ?[40]u8 = last_git_head;
        const head_changed = blk: {
            {
                const st = stable_root.statFile(io, ".git/HEAD", .{}) catch break :blk false;
                const st_mtime: i128 = @intCast(st.mtime.nanoseconds);
                if (st_mtime == git_head_mtime) break :blk false;
                git_head_mtime = st_mtime;
            }
            current_head = git_mod.getGitHeadDir(io, stable_root, backing) catch null;
            if (last_git_head == null and current_head == null) break :blk false;
            if (last_git_head == null or current_head == null) break :blk true;
            break :blk !std.mem.eql(u8, &last_git_head.?, &current_head.?);
        };

        if (head_changed) {
            std.log.info("git HEAD changed — re-scanning", .{});
            last_git_head = current_head;

            // Remove stale files from Explorer that may not exist on the new branch
            var remove_list: std.ArrayList([]const u8) = .empty;
            defer remove_list.deinit(backing);
            var kiter = known.iterator();
            while (kiter.next()) |kv| {
                remove_list.append(backing, kv.key_ptr.*) catch {};
            }
            for (remove_list.items) |path| {
                explorer.removeFile(path);
            }

            // Clear known map
            var kiter2 = known.iterator();
            while (kiter2.next()) |kv| backing.free(kv.key_ptr.*);
            known.clearRetainingCapacity();
            var diter = dirs.iterator();
            while (diter.next()) |kv| backing.free(kv.key_ptr.*);
            dirs.clearRetainingCapacity();

            // Re-scan with trigram cap
            var rescan_arena = std.heap.ArenaAllocator.init(backing);
            defer rescan_arena.deinit();
            const tmp = rescan_arena.allocator();
            const dir = stable_root;
            var walker = FilteredWalker.init(io, dir, tmp) catch continue;
            defer walker.deinit();
            const max_trigram_files = trigramFileCap();
            var file_count: usize = 0;
            while (walker.next() catch null) |entry| {
                _ = store.recordSnapshot(entry.path, entry.size, 0) catch {};
                file_count += 1;
                const effective_skip = file_count > max_trigram_files;
                indexFileContent(io, explorer, dir, entry.path, backing, effective_skip) catch {};
                const stat = project_file.statNoFollow(io, dir, entry.path) catch continue;
                const mtime: i64 = @intCast(@divTrunc(stat.mtime.nanoseconds, std.time.ns_per_ms));
                const duped = backing.dupe(u8, entry.path) catch continue;
                known.put(duped, .{ .mtime = mtime, .size = entry.size, .hash = 0, .seen = false }) catch backing.free(duped);
            }
            armAndCloseGap(io, &watch, stable_root, store, explorer, queue, &known, &dirs, root, backing);
            continue;
        }

        var cycle_arena = std.heap.ArenaAllocator.init(backing);
        defer cycle_arena.deinit();

        if (watch.active) {
            const had_events = dirty.count() > 0;
            watch.addUnwatched(&dirty);
            incrementalDiffDirty(io, store, explorer, queue, &known, &dirs, root, backing, cycle_arena.allocator(), &dirty) catch |err| {
                std.log.err("watcher: diff failed: {}", .{err});
            };
            if (known.count() != watch.armed_files or dirs.count() != watch.armed_dirs) {
                armAndCloseGap(io, &watch, stable_root, store, explorer, queue, &known, &dirs, root, backing);
            } else if (had_events) {
                watch.rearmDirty(io, stable_root, &dirty);
            }
        } else {
            incrementalDiffInner(io, store, explorer, queue, &known, &dirs, root, backing, cycle_arena.allocator()) catch |err| {
                std.log.err("watcher: diff failed: {}", .{err});
            };
            if (known.count() != watch.armed_files or dirs.count() != watch.armed_dirs) {
                armAndCloseGap(io, &watch, stable_root, store, explorer, queue, &known, &dirs, root, backing);
            }
        }
    }
}

/// Index already-read file content: skip binary (a null byte in the first 512
/// bytes), then index with or without trigrams by size. The single place that
/// turns a text buffer into index entries — shared by indexFileContent and
/// hashAndIndexFile so the binary + trigram rules live in one spot.
fn indexContentBuffer(explorer: *Explorer, path: []const u8, content: []const u8, skip_trigram: bool) !void {
    const check_len = @min(content.len, 512);
    if (std.mem.indexOfScalar(u8, content[0..check_len], 0) != null) return; // binary
    const effective_skip_trigram = skip_trigram or (content.len > max_trigram_file_bytes);
    if (effective_skip_trigram) {
        try explorer.indexFileSkipTrigram(path, content);
    } else {
        try explorer.indexFile(path, content);
    }
}

/// Read a file once and reuse the buffer for both change detection and indexing.
/// The live-update paths (incrementalDiff, drainNotifyFile) previously hashed and
/// indexed in two separate full reads of a changed file — disk read twice,
/// up to 2× max_indexed_file_bytes of IO after #635 widened the cap. This reads
/// once. Returns the content hash to store for future change detection: 0 when the
/// file is skipped (filtered or over the cap), maxInt(u64) on IO error (always
/// differs from a stored hash, forcing a re-read next cycle). Binary files are
/// hashed but not indexed, matching the prior hash-then-index split behavior.
/// `size` is the caller's already-stat'd size, so there is no extra stat here.
fn hashAndIndexFile(io: std.Io, explorer: *Explorer, dir: std.Io.Dir, path: []const u8, size: u64) u64 {
    if (shouldSkipFile(path)) return 0;
    if (size > max_indexed_file_bytes) return 0;
    var content_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer content_arena.deinit();
    const content = project_file.readAllocNoFollow(io, dir, path, content_arena.allocator(), .limited(max_indexed_file_bytes)) catch return std.math.maxInt(u64);
    const hash = std.hash.Wyhash.hash(0, content);
    indexContentBuffer(explorer, path, content, false) catch {};
    return hash;
}

fn pushEventOrWait(queue: *EventQueue, event: FsEvent) void {
    // Preserve prior drop-on-full behavior so producer never stalls permanently.
    _ = queue.push(event);
}

fn incrementalDiff(io: std.Io, store: *Store, explorer: *Explorer, queue: *EventQueue, known: *FileMap, root: []const u8, persistent: std.mem.Allocator, tmp: std.mem.Allocator) !void {
    try incrementalDiffInner(io, store, explorer, queue, known, null, root, persistent, tmp);
}

pub fn incrementalDiffInner(
    io: std.Io,
    store: *Store,
    explorer: *Explorer,
    queue: *EventQueue,
    known: *FileMap,
    dirs: ?*DirMap,
    root: []const u8,
    persistent: std.mem.Allocator,
    tmp: std.mem.Allocator,
) !void {
    return incrementalDiffDirty(io, store, explorer, queue, known, dirs, root, persistent, tmp, null);
}

pub fn incrementalDiffDirty(
    io: std.Io,
    store: *Store,
    explorer: *Explorer,
    queue: *EventQueue,
    known: *FileMap,
    dirs: ?*DirMap,
    root: []const u8,
    persistent: std.mem.Allocator,
    tmp: std.mem.Allocator,
    dirty: ?*const DirtySet,
) !void {
    _ = root;
    const dir = explorer.root_dir orelse return error.ProjectRootUnavailable;

    // Mark all known files unseen for this cycle.
    var known_iter = known.iterator();
    while (known_iter.next()) |kv| {
        kv.value_ptr.seen = false;
    }

    var ignore = try FilteredWalker.init(io, dir, tmp);
    defer ignore.deinit();
    const parents = try buildParentIndex(known, tmp);
    try walkRel(io, store, explorer, queue, known, dirs, &ignore, dir, "", persistent, tmp, &parents, dirty, false);

    // Detect deleted files
    var to_remove: std.ArrayList([]const u8) = .empty;
    defer to_remove.deinit(tmp);

    var iter = known.iterator();
    while (iter.next()) |kv| {
        if (!kv.value_ptr.seen) {
            try to_remove.append(tmp, kv.key_ptr.*);
        }
    }
    for (to_remove.items) |path| {
        const seq = store.recordDelete(path, 0) catch continue;
        explorer.removeFile(path);
        if (known.fetchRemove(path)) |kv| {
            if (FsEvent.init(kv.key, .deleted, seq)) |ev| pushEventOrWait(queue, ev);
            persistent.free(kv.key);
        }
        store.forgetMtime(path);
    }
}

fn applyKnownFile(
    io: std.Io,
    store: *Store,
    explorer: *Explorer,
    queue: *EventQueue,
    known: *FileMap,
    dir: std.Io.Dir,
    logical_path: []const u8,
    read_path: []const u8,
    stat: std.Io.Dir.Stat,
    force_read: bool,
) !void {
    const known_entry = known.getEntry(logical_path) orelse return;
    const old = known_entry.value_ptr;
    old.seen = true;
    const mtime: i64 = @intCast(@divTrunc(stat.mtime.nanoseconds, std.time.ns_per_ms));
    const exact_metadata_matches = old.mtime_ns != 0 and old.mtime_ns == stat.mtime.nanoseconds and old.ctime_ns == stat.ctime.nanoseconds and old.inode == stat.inode and old.size == stat.size;
    if (!force_read and exact_metadata_matches) {
        store.noteMtime(logical_path, mtime);
        return;
    }
    if (!force_read and old.mtime_ns == 0 and old.mtime == mtime and old.size == stat.size) {
        old.mtime_ns = stat.mtime.nanoseconds;
        old.ctime_ns = stat.ctime.nanoseconds;
        old.inode = stat.inode;
        store.noteMtime(logical_path, mtime);
        return;
    }

    const stable_path = known_entry.key_ptr.*;
    var hash: u64 = 0;
    var content: ?[]const u8 = null;
    var content_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer content_arena.deinit();
    if (!shouldSkipFile(logical_path) and stat.size <= max_indexed_file_bytes) {
        if (project_file.readAllocNoFollow(io, dir, read_path, content_arena.allocator(), .limited(max_indexed_file_bytes))) |buf| {
            content = buf;
            hash = std.hash.Wyhash.hash(0, buf);
        } else |_| {
            hash = std.math.maxInt(u64);
        }
    }

    if (old.size == stat.size and hash != 0 and old.hash != 0 and hash == old.hash) {
        old.mtime = mtime;
        old.mtime_ns = stat.mtime.nanoseconds;
        old.ctime_ns = stat.ctime.nanoseconds;
        old.inode = stat.inode;
        old.size = stat.size;
        store.noteMtime(logical_path, mtime);
        return;
    }

    const seq = try store.recordSnapshot(logical_path, stat.size, hash);
    old.mtime = mtime;
    old.mtime_ns = stat.mtime.nanoseconds;
    old.ctime_ns = stat.ctime.nanoseconds;
    old.inode = stat.inode;
    old.size = stat.size;
    old.hash = hash;
    store.noteMtime(logical_path, mtime);
    if (FsEvent.init(stable_path, .modified, seq)) |ev| pushEventOrWait(queue, ev);
    if (content) |buf| indexContentBuffer(explorer, stable_path, buf, false) catch {};
}

const ParentIndex = struct {
    files: std.StringHashMap(std.ArrayList([]const u8)),
    child_dirs: std.StringHashMap(std.StringHashMap(void)),
};

fn buildParentIndex(known: *const FileMap, tmp: std.mem.Allocator) !ParentIndex {
    var files = std.StringHashMap(std.ArrayList([]const u8)).init(tmp);
    var child_dirs = std.StringHashMap(std.StringHashMap(void)).init(tmp);
    var it = known.iterator();
    while (it.next()) |kv| {
        const path = kv.key_ptr.*;
        const parent = parentRel(path);
        {
            const gop = try files.getOrPut(parent);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(tmp, path);
        }
        var dir_path = parent;
        while (dir_path.len > 0) {
            const grand = parentRel(dir_path);
            const name = if (std.mem.lastIndexOfScalar(u8, dir_path, '/')) |i|
                dir_path[i + 1 ..]
            else
                dir_path;
            const gop = try child_dirs.getOrPut(grand);
            if (!gop.found_existing) gop.value_ptr.* = std.StringHashMap(void).init(tmp);
            try gop.value_ptr.put(name, {});
            dir_path = grand;
        }
    }
    return .{ .files = files, .child_dirs = child_dirs };
}

fn dirtyForcesDirectoryScan(dirty: ?*const DirtySet, known: *const FileMap, prefix: []const u8) bool {
    const set = dirty orelse return false;
    if (set.get(prefix) != null) return true;
    var it = set.keyIterator();
    while (it.next()) |path| {
        if (path.len == 0 or known.get(path.*) != null) continue;
        if (std.mem.eql(u8, parentRel(path.*), prefix)) return true;
    }
    return false;
}

fn dirtyForcesFileRead(dirty: ?*const DirtySet, prefix: []const u8, path: []const u8) bool {
    const set = dirty orelse return false;
    return set.get(prefix) != null or set.get(path) != null;
}

fn walkRel(
    io: std.Io,
    store: *Store,
    explorer: *Explorer,
    queue: *EventQueue,
    known: *FileMap,
    dirs: ?*DirMap,
    ignore: *FilteredWalker,
    dir: std.Io.Dir,
    prefix: []const u8,
    persistent: std.mem.Allocator,
    tmp: std.mem.Allocator,
    parents: *const ParentIndex,
    dirty: ?*const DirtySet,
    through_symlink: bool,
) !void {
    // Open once, then validate the actual handle before observing its mtime,
    // identity, names, or sizes. Iterator kind and a pre-open realpath are
    // both racy; the full identity tuple also catches atomic directory swaps.
    const listing = if (prefix.len == 0)
        dir
    else
        dir.openDir(io, prefix, .{ .iterate = true }) catch return;
    defer if (prefix.len != 0) listing.close(io);
    var effective_through_symlink = through_symlink;
    if (prefix.len != 0) {
        const opened_as_alias = ignore.claimOpenedDirectory(listing, prefix) orelse return;
        effective_through_symlink = effective_through_symlink or opened_as_alias;
    }

    const current_dir_state = dirState(io, listing, "");
    const cached_dir_state = if (dirs) |d| d.get(prefix) else null;
    const force_scan = dirtyForcesDirectoryScan(dirty, known, prefix);
    const dir_unchanged = !force_scan and current_dir_state != null and cached_dir_state != null and std.meta.eql(current_dir_state.?, cached_dir_state.?);

    if (dir_unchanged) {
        if (parents.files.get(prefix)) |file_list| {
            for (file_list.items) |path| {
                if (dirty) |d| {
                    if (d.get(path) == null) {
                        if (known.getPtr(path)) |st| st.seen = true;
                        continue;
                    }
                }
                debug_unchanged_file_stats += 1;
                const local_name = std.fs.path.basename(path);
                if (effective_through_symlink and !resolvedFileTargetAllowed(io, listing, ignore.real_root, local_name)) continue;
                const stat = listing.statFile(io, local_name, .{ .follow_symlinks = false }) catch continue;
                if (stat.kind != .file) continue;
                try applyKnownFile(io, store, explorer, queue, known, listing, path, local_name, stat, dirtyForcesFileRead(dirty, prefix, path));
            }
        }
        if (parents.child_dirs.get(prefix)) |children| {
            var cit = children.keyIterator();
            while (cit.next()) |name| {
                if (shouldSkipDir(name.*)) continue;
                const child = try joinRel(tmp, prefix, name.*);
                if (ignore.ignore_patterns.items.len > 0 and ignore.isIgnored(name.*, child)) continue;
                const child_stat = listing.statFile(io, name.*, .{ .follow_symlinks = false }) catch continue;
                if (child_stat.kind != .directory and child_stat.kind != .sym_link) continue;
                const child_through_symlink = effective_through_symlink or child_stat.kind == .sym_link;
                try walkRel(io, store, explorer, queue, known, dirs, ignore, dir, child, persistent, tmp, parents, dirty, child_through_symlink);
            }
        }
        return;
    }

    var it = listing.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .directory or entry.kind == .sym_link) {
            const child_through_symlink = effective_through_symlink or entry.kind == .sym_link;
            if (entry.kind == .sym_link and !resolvedDirectoryTargetAllowed(io, listing, ignore.real_root, entry.name)) continue;
            if (shouldSkipDir(entry.name)) continue;
            const child = try joinRel(tmp, prefix, entry.name);
            if (ignore.ignore_patterns.items.len > 0 and ignore.isIgnored(entry.name, child)) continue;
            try walkRel(io, store, explorer, queue, known, dirs, ignore, dir, child, persistent, tmp, parents, dirty, child_through_symlink);
            continue;
        }

        if (entry.kind != .file) continue;

        const rel = try joinRel(tmp, prefix, entry.name);
        if (ignore.ignore_patterns.items.len > 0 and ignore.isIgnored(entry.name, rel)) continue;
        if (shouldSkipFile(rel)) continue;
        if (effective_through_symlink and !resolvedFileTargetAllowed(io, listing, ignore.real_root, entry.name)) continue;
        const stat = listing.statFile(io, entry.name, .{ .follow_symlinks = false }) catch continue;
        if (stat.kind != .file) continue;
        if (known.getEntry(rel)) |known_entry| {
            try applyKnownFile(io, store, explorer, queue, known, listing, known_entry.key_ptr.*, entry.name, stat, dirtyForcesFileRead(dirty, prefix, rel));
        } else {
            const mtime: i64 = @intCast(@divTrunc(stat.mtime.nanoseconds, std.time.ns_per_ms));
            const duped = try persistent.dupe(u8, rel);
            errdefer persistent.free(duped);
            const seq = try store.recordSnapshot(duped, stat.size, 0);
            try known.put(duped, .{ .mtime = mtime, .size = stat.size, .hash = 0, .seen = true });
            store.noteMtime(duped, mtime);
            if (FsEvent.init(duped, .created, seq)) |ev| pushEventOrWait(queue, ev);
            indexFileContentAt(io, explorer, listing, entry.name, duped, tmp, false) catch {};
        }
    }

    if (dirs) |dir_map| {
        if (current_dir_state) |state| rememberDirState(dir_map, persistent, prefix, state);
    }
}

fn seedKnownFromExplorer(store: *Store, explorer: *Explorer, known: *FileMap, allocator: std.mem.Allocator) !void {
    {
        explorer.mu.lockShared();
        defer explorer.mu.unlockShared();
        var iter = explorer.outlines.keyIterator();
        while (iter.next()) |path| {
            const copy = try allocator.dupe(u8, path.*);
            errdefer allocator.free(copy);
            try known.put(copy, .{ .mtime = 0, .size = 0, .hash = 0, .seen = false });
        }
    }

    // Seed size/hash from the store's latest version so unchanged files hit
    // the metadata-only shortcut in incrementalDiff instead of being
    // re-recorded and re-parsed on every explicit refresh. mtime comes from
    // the process-local store cache after the first reconcile so later
    // refreshes can skip unread files whose stat mtime still matches.
    var seed_iter = known.iterator();
    while (seed_iter.next()) |kv| {
        if (store.getLatest(kv.key_ptr.*)) |v| {
            kv.value_ptr.size = v.size;
            kv.value_ptr.hash = v.hash;
        }
        if (store.getMtime(kv.key_ptr.*)) |mt| kv.value_ptr.mtime = mt;
    }
}

/// Index one on-disk file that the live Explorer has not seen yet.
/// Used by codedb_outline so agents get the file instead of a codedb_index hint.
pub fn indexMissingFile(io: std.Io, store: ?*Store, explorer: *Explorer, path: []const u8) bool {
    if (path.len == 0 or path[0] == '/') return false;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return false;
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return false;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |component| {
        if (std.mem.eql(u8, component, "..")) return false;
    }
    if (shouldSkipFile(path)) return false;
    const root_dir = explorer.root_dir orelse return false;
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = root_dir.realPathFile(io, ".", &root_buf) catch return false;
    if (!resolvedFileTargetAllowed(io, root_dir, root_buf[0..root_len], path)) return false;
    const stat = root_dir.statFile(io, path, .{ .follow_symlinks = false }) catch return false;
    if (stat.kind != .file) return false;
    if (stat.size > max_indexed_file_bytes) return false;
    indexFileContent(io, explorer, root_dir, path, explorer.allocator, false) catch return false;
    const mtime: i64 = @intCast(@divTrunc(stat.mtime.nanoseconds, std.time.ns_per_ms));
    if (store) |s| {
        _ = s.recordSnapshot(path, stat.size, 0) catch {};
        s.noteMtime(path, mtime);
    }
    return true;
}

pub fn refreshIndex(io: std.Io, store: *Store, explorer: *Explorer, root: []const u8, allocator: std.mem.Allocator) !void {
    var known = FileMap.init(allocator);
    defer {
        var iter = known.keyIterator();
        while (iter.next()) |path| allocator.free(path.*);
        known.deinit();
    }

    try seedKnownFromExplorer(store, explorer, &known, allocator);

    const queue = try allocator.create(EventQueue);
    defer allocator.destroy(queue);
    queue.* = EventQueue{};
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    try incrementalDiff(io, store, explorer, queue, &known, root, allocator, arena.allocator());
}

const skip_extensions = [_][]const u8{
    ".png",     ".jpg",  ".jpeg", ".gif",  ".bmp",   ".ico",   ".icns",  ".webp",
    ".svg",     ".ttf",  ".otf",  ".woff", ".woff2", ".eot",   ".zip",   ".tar",
    ".gz",      ".bz2",  ".xz",   ".7z",   ".rar",   ".pdf",   ".doc",   ".docx",
    ".xls",     ".xlsx", ".pptx", ".mp3",  ".mp4",   ".wav",   ".avi",   ".mov",
    ".flv",     ".ogg",  ".webm", ".exe",  ".dll",   ".so",    ".dylib", ".o",
    ".a",       ".lib",  ".wasm", ".pyc",  ".pyo",   ".class", ".db",    ".sqlite",
    ".sqlite3", ".lock", ".sum",
};

fn shouldSkipFile(path: []const u8) bool {
    for (skip_extensions) |ext| {
        if (std.mem.endsWith(u8, path, ext)) return true;
    }
    // Skip dotfiles like .DS_Store, .gitignore etc at any depth
    if (std.mem.endsWith(u8, path, ".DS_Store")) return true;
    // Skip sensitive files (.env, credentials, keys) — same rules as snapshot filtering
    if (isSensitivePath(path)) return true;
    return false;
}

/// Check if a path refers to a sensitive file (secrets, keys, credentials).
/// Delegates to snapshot.zig so live indexing and snapshots apply the same
/// exclusion rules from a single implementation.
pub fn isSensitivePath(path: []const u8) bool {
    return project_path.isSensitive(path);
}

fn indexFileContent(io: std.Io, explorer: *Explorer, dir: std.Io.Dir, path: []const u8, allocator: std.mem.Allocator, skip_trigram: bool) !void {
    return indexFileContentAt(io, explorer, dir, path, path, allocator, skip_trigram);
}

fn indexFileContentAt(
    io: std.Io,
    explorer: *Explorer,
    dir: std.Io.Dir,
    read_path: []const u8,
    logical_path: []const u8,
    allocator: std.mem.Allocator,
    skip_trigram: bool,
) !void {
    _ = allocator;
    if (shouldSkipFile(logical_path)) return;
    const stat = try dir.statFile(io, read_path, .{ .follow_symlinks = false });
    if (stat.kind != .file) return;
    // Use page_allocator arena for content — pages returned to OS immediately
    // via munmap on deinit, eliminating GPA page retention from content churn.
    var content_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer content_arena.deinit();
    const content = (try readIndexableFile(io, dir, read_path, content_arena.allocator(), stat.size, false)) orelse return;
    try indexContentBuffer(explorer, logical_path, content, skip_trigram);
}

// ── muonry interop ───────────────────────────────────────────────────────────
//
// muonry appends changed file paths to /tmp/codedb-notify after each edit.
// We drain this file on every poll cycle and re-index the listed files
// immediately, eliminating the 2s polling delay for muonry-sourced edits.

fn drainNotifyFile(io: std.Io, store: *Store, explorer: *Explorer, queue: *EventQueue, known: *FileMap, alloc: std.mem.Allocator) void {
    drainNotifyFileFrom(io, store, explorer, queue, known, alloc, std.Io.Dir.cwd(), "/tmp/codedb-notify");
}

fn drainNotifyFileFrom(
    io: std.Io,
    store: *Store,
    explorer: *Explorer,
    queue: *EventQueue,
    known: *FileMap,
    alloc: std.mem.Allocator,
    notify_dir: std.Io.Dir,
    notify_path: []const u8,
) void {
    // Atomically read + truncate.
    const file = notify_dir.openFile(io, notify_path, .{ .mode = .read_write }) catch return;
    defer file.close(io);

    const file_len = file.length(io) catch return;
    if (file_len == 0) return;
    const cap: u64 = 64 * 1024;
    const read_len: usize = @intCast(@min(file_len, cap));
    const data = alloc.alloc(u8, read_len) catch return;
    defer alloc.free(data);
    const n = file.readPositionalAll(io, data, 0) catch return;
    if (n == 0) return;
    const data_slice = data[0..n];

    // Truncate after reading
    file.setLength(io, 0) catch return;

    // Re-index each notified path
    const dir = explorer.root_dir orelse return;
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = dir.realPathFile(io, ".", &root_buf) catch return;
    const root = root_buf[0..root_len];

    var lines = std.mem.splitScalar(u8, data_slice, '\n');
    while (lines.next()) |line| {
        const path = std.mem.trim(u8, line, " \t\r");
        if (path.len == 0) continue;

        // Make path relative to root if it's absolute
        const rel = if (std.fs.path.isAbsolute(path)) blk: {
            if (!isWithinCanonicalRoot(root, path) or path.len == root.len) continue;
            break :blk std.mem.trimStart(u8, path[root.len..], "/");
        } else path;
        if (shouldSkipFile(rel)) continue;
        if (!resolvedFileTargetAllowed(io, dir, root, rel)) continue;

        // Skip re-indexing if file hasn't changed since last known state (#228)
        const stat = dir.statFile(io, rel, .{ .follow_symlinks = false }) catch continue;
        if (stat.kind != .file) continue;
        const mtime: i64 = @intCast(@divTrunc(stat.mtime.nanoseconds, std.time.ns_per_ms));
        if (known.getPtr(rel)) |existing| {
            if (existing.mtime_ns != 0 and existing.mtime_ns == stat.mtime.nanoseconds and existing.ctime_ns == stat.ctime.nanoseconds and existing.inode == stat.inode and existing.size == stat.size) continue;
        }

        // Read once: index + hash from the same buffer (previously two separate
        // full reads of the same file per notification).
        const hash = hashAndIndexFile(io, explorer, dir, rel, stat.size);
        if (hash == std.math.maxInt(u64)) continue; // read failed — retry next cycle

        // Update known-file state so incrementalDiff doesn't double-process
        if (known.getPtr(rel)) |existing| {
            existing.mtime = mtime;
            existing.mtime_ns = stat.mtime.nanoseconds;
            existing.ctime_ns = stat.ctime.nanoseconds;
            existing.inode = stat.inode;
            existing.size = stat.size;
            existing.hash = hash;
            existing.seen = true;
        }
        store.noteMtime(rel, mtime);

        // Push event to queue
        if (FsEvent.init(rel, .modified, store.currentSeq())) |ev| {
            _ = queue.push(ev);
        }
    }
}

test "notify drain uses exact metadata and refreshes the live fingerprint" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const old_content = "OLD_VALUE = 111\n";
    const new_content = "NEW_VALUE = 222\n";
    try testing.expectEqual(old_content.len, new_content.len);
    try tmp.dir.writeFile(io, .{ .sub_path = "keep.py", .data = old_content });
    try tmp.dir.writeFile(io, .{ .sub_path = "notify", .data = "" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPathFile(io, ".", &root_buf);
    const root = root_buf[0..root_len];
    const store = try testing.allocator.create(Store);
    defer testing.allocator.destroy(store);
    store.* = Store.init(testing.allocator);
    defer store.deinit();
    const explorer = try testing.allocator.create(Explorer);
    defer testing.allocator.destroy(explorer);
    explorer.* = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    explorer.setRoot(io, root);
    const stable_root = explorer.root_dir orelse return error.TestUnexpectedResult;
    try indexFileContent(io, explorer, stable_root, "keep.py", testing.allocator, false);
    const old_stat = try stable_root.statFile(io, "keep.py", .{ .follow_symlinks = false });
    var known = FileMap.init(testing.allocator);
    defer {
        var it = known.keyIterator();
        while (it.next()) |path| testing.allocator.free(path.*);
        known.deinit();
    }
    const key = try testing.allocator.dupe(u8, "keep.py");
    try known.put(key, .{
        .mtime = @intCast(@divTrunc(old_stat.mtime.nanoseconds, std.time.ns_per_ms)),
        .mtime_ns = old_stat.mtime.nanoseconds,
        .ctime_ns = old_stat.ctime.nanoseconds,
        .inode = old_stat.inode,
        .size = old_stat.size,
        .hash = std.hash.Wyhash.hash(0, old_content),
        .seen = true,
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "keep.py", .data = new_content });
    const new_stat = try stable_root.statFile(io, "keep.py", .{ .follow_symlinks = false });
    (known.getPtr("keep.py") orelse return error.TestUnexpectedResult).mtime =
        @intCast(@divTrunc(new_stat.mtime.nanoseconds, std.time.ns_per_ms));
    try tmp.dir.writeFile(io, .{ .sub_path = "notify", .data = "keep.py\n" });
    const queue = try testing.allocator.create(EventQueue);
    defer testing.allocator.destroy(queue);
    queue.* = .{};
    drainNotifyFileFrom(io, store, explorer, queue, &known, testing.allocator, tmp.dir, "notify");
    const refreshed = known.getPtr("keep.py") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(new_stat.mtime.nanoseconds, refreshed.mtime_ns);
    try testing.expectEqual(new_stat.ctime.nanoseconds, refreshed.ctime_ns);
    try testing.expectEqual(new_stat.inode, refreshed.inode);
    try testing.expectEqual(std.hash.Wyhash.hash(0, new_content), refreshed.hash);
    const new_hits = try explorer.searchContent("NEW_VALUE", testing.allocator, 10);
    defer {
        for (new_hits) |hit| {
            testing.allocator.free(hit.line_text);
            testing.allocator.free(hit.path);
        }
        testing.allocator.free(new_hits);
    }
    try testing.expectEqual(@as(usize, 1), new_hits.len);
    const old_hits = try explorer.searchContent("OLD_VALUE", testing.allocator, 10);
    defer {
        for (old_hits) |hit| {
            testing.allocator.free(hit.line_text);
            testing.allocator.free(hit.path);
        }
        testing.allocator.free(old_hits);
    }
    try testing.expectEqual(@as(usize, 0), old_hits.len);
}

test "issue-685: watcher diff updates document edges for modify add and delete" {
    const testing = std.testing;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "docs");
    try tmp.dir.writeFile(io, .{ .sub_path = "docs/a.md", .data = "[B](b.md)\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "docs/b.md", .data = "# B\n" });

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPathFile(io, ".", &root_buf);
    const root = root_buf[0..root_len];

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    try explorer.setRoot(io, root);
    try initialScanWithWorkerCount(io, &store, &explorer, root, testing.allocator, false, 1);
    try testing.expectEqual(@as(usize, 1), explorer.document_graph.getForwardDeps("docs/a.md").?.len);

    var known = FileMap.init(testing.allocator);
    defer {
        var iter = known.keyIterator();
        while (iter.next()) |path| testing.allocator.free(path.*);
        known.deinit();
    }
    var root_dir = try std.Io.Dir.cwd().openDir(io, root, .{});
    defer root_dir.close(io);
    for ([_][]const u8{ "docs/a.md", "docs/b.md" }) |path| {
        const stat = try root_dir.statFile(io, path, .{});
        const content = try root_dir.readFileAlloc(io, path, testing.allocator, .limited(max_indexed_file_bytes));
        defer testing.allocator.free(content);
        const owned_path = try testing.allocator.dupe(u8, path);
        try known.put(owned_path, .{
            .mtime = @intCast(@divTrunc(stat.mtime.nanoseconds, std.time.ns_per_ms)),
            .size = stat.size,
            .hash = std.hash.Wyhash.hash(0, content),
            .seen = true,
        });
    }

    cio.sleepMs(10);
    try tmp.dir.writeFile(io, .{ .sub_path = "docs/a.md", .data = "[C](c.md)\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "docs/c.md", .data = "# C\n" });
    try tmp.dir.deleteFile(io, "docs/b.md");

    const queue = try testing.allocator.create(EventQueue);
    defer testing.allocator.destroy(queue);
    queue.* = .{};
    var cycle_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer cycle_arena.deinit();
    try incrementalDiff(io, &store, &explorer, queue, &known, root, testing.allocator, cycle_arena.allocator());

    try testing.expect(!explorer.outlines.contains("docs/b.md"));
    try testing.expect(explorer.outlines.contains("docs/c.md"));
    const links = explorer.document_graph.getForwardDeps("docs/a.md") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 1), links.len);
    try testing.expectEqualStrings("docs/c.md", links[0]);
}

test "dir-mtime prune still stats known files and notices new siblings" {
    const testing = std.testing;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/a.py", .data = "def a():\n    return 1\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/b.py", .data = "def b():\n    return 1\n" });

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPathFile(io, ".", &root_buf);
    const root = root_buf[0..root_len];

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    try explorer.setRoot(io, root);

    var known = FileMap.init(testing.allocator);
    defer {
        var iter = known.keyIterator();
        while (iter.next()) |path| testing.allocator.free(path.*);
        known.deinit();
    }
    var dirs = DirMap.init(testing.allocator);
    defer {
        var iter = dirs.keyIterator();
        while (iter.next()) |path| testing.allocator.free(path.*);
        dirs.deinit();
    }

    const queue = try testing.allocator.create(EventQueue);
    defer testing.allocator.destroy(queue);
    queue.* = .{};
    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        try incrementalDiffInner(io, &store, &explorer, queue, &known, &dirs, root, testing.allocator, arena.allocator());
    }
    try testing.expect(explorer.outlines.contains("src/a.py"));
    try testing.expect(explorer.outlines.contains("src/b.py"));
    const first_seq = store.currentSeq();

    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        try incrementalDiffInner(io, &store, &explorer, queue, &known, &dirs, root, testing.allocator, arena.allocator());
    }
    try testing.expectEqual(first_seq, store.currentSeq());

    cio.sleepMs(10);
    try tmp.dir.writeFile(io, .{ .sub_path = "src/a.py", .data = "def a_changed():\n    return 2\n" });
    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        try incrementalDiffInner(io, &store, &explorer, queue, &known, &dirs, root, testing.allocator, arena.allocator());
    }
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try testing.expect(try explorer.renderOutline("src/a.py", testing.allocator, &out, false));
    try testing.expect(std.mem.indexOf(u8, out.items, "a_changed") != null);

    cio.sleepMs(10);
    try tmp.dir.writeFile(io, .{ .sub_path = "src/c.py", .data = "def c():\n    return 3\n" });
    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        try incrementalDiffInner(io, &store, &explorer, queue, &known, &dirs, root, testing.allocator, arena.allocator());
    }
    try testing.expect(explorer.outlines.contains("src/c.py"));
}
