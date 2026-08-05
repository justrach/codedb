const std = @import("std");
const ContentCache = @import("hot_cache.zig").ContentCache;
const cio = @import("cio.zig");
const Store = @import("store.zig").Store;
const Explorer = @import("explore.zig").Explorer;
const TrigramIndex = @import("index.zig").TrigramIndex;
const WordIndex = @import("index.zig").WordIndex;
const explore_mod = @import("explore.zig");
const git_mod = @import("git.zig");

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
    size: u64, // cheap change discriminator before hashing
    hash: u64, // wyhash of content — confirms actual change
    seen: bool, // set during current poll cycle for deletion detection
};

const FileMap = std.StringHashMap(FileState);

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
    const content = try dir.readFileAlloc(io, path, alloc, .limited(max_indexed_file_bytes));
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

/// Recursive directory walker that prunes skip_dirs before descending.
/// Unlike std.Io.Dir.walk(), this never enters .git, node_modules, etc.,
/// avoiding the CPU cost of traversing potentially huge directory trees.
pub const FilteredWalker = struct {
    const StackItem = struct {
        dir_handle: std.Io.Dir,
        iter: std.Io.Dir.Iterator,
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
        });

        var rr_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (root.realPathFile(io, ".", &rr_buf)) |rr_len| {
            const dup = try allocator.dupe(u8, rr_buf[0..rr_len]);
            self.real_root = dup;
            const seed = try allocator.dupe(u8, rr_buf[0..rr_len]);
            try self.visited_real_paths.put(allocator, seed, {});
        } else |_| {}

        // Load .codedbignore if it exists
        if (root.readFileAlloc(io, ".codedbignore", allocator, .limited(64 * 1024))) |content| {
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
        if (root.readFileAlloc(io, ".gitignore", allocator, .limited(64 * 1024))) |content| {
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

    pub fn next(self: *FilteredWalker) !?Entry {
        // Trim any filename appended by the previous yield
        self.name_buffer.shrinkRetainingCapacity(self.dir_prefix_len);

        while (self.stack.items.len > 0) {
            const top = &self.stack.items[self.stack.items.len - 1];
            if (try top.iter.next(self.io)) |entry| {
                if (entry.kind == .directory) {
                    if (shouldSkipDir(entry.name)) continue;
                    // Check .codedbignore patterns
                    if (self.ignore_patterns.items.len > 0) {
                        // Build full path for prefix matching
                        var check_buf: [std.fs.max_path_bytes]u8 = undefined;
                        const check_path = if (self.dir_prefix_len > 0)
                            std.fmt.bufPrint(&check_buf, "{s}/{s}", .{ self.name_buffer.items[0..self.dir_prefix_len], entry.name }) catch entry.name
                        else
                            entry.name;
                        if (self.isIgnored(entry.name, check_path)) continue;
                    }
                    const sub = top.dir_handle.openDir(self.io, entry.name, .{ .iterate = true }) catch continue;
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
                    });
                    continue;
                }

                if (entry.kind != .file) {
                    if (entry.kind != .sym_link) continue;
                    const target_stat = top.dir_handle.statFile(self.io, entry.name, .{}) catch continue;
                    if (target_stat.kind == .directory) {
                        if (shouldSkipDir(entry.name)) continue;
                        if (self.ignore_patterns.items.len > 0) {
                            var check_buf: [std.fs.max_path_bytes]u8 = undefined;
                            const check_path = if (self.dir_prefix_len > 0)
                                std.fmt.bufPrint(&check_buf, "{s}/{s}", .{ self.name_buffer.items[0..self.dir_prefix_len], entry.name }) catch entry.name
                            else
                                entry.name;
                            if (self.isIgnored(entry.name, check_path)) continue;
                        }
                        var rt_buf: [std.fs.max_path_bytes]u8 = undefined;
                        const rt_len = top.dir_handle.realPathFile(self.io, entry.name, &rt_buf) catch continue;
                        const real_target = rt_buf[0..rt_len];
                        if (self.real_root.len == 0) continue;
                        if (!std.mem.startsWith(u8, real_target, self.real_root)) continue;
                        if (real_target.len != self.real_root.len and real_target[self.real_root.len] != '/') continue;
                        const gop = self.visited_real_paths.getOrPut(self.allocator, real_target) catch continue;
                        if (gop.found_existing) continue;
                        const dup = self.allocator.dupe(u8, real_target) catch {
                            _ = self.visited_real_paths.remove(real_target);
                            continue;
                        };
                        gop.key_ptr.* = dup;
                        const sub = top.dir_handle.openDir(self.io, entry.name, .{ .iterate = true }) catch continue;
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
                        });
                        continue;
                    }
                    if (target_stat.kind != .file) continue;
                }

                // Build full relative path by appending filename
                if (self.dir_prefix_len > 0)
                    try self.name_buffer.append(self.allocator, '/');
                try self.name_buffer.appendSlice(self.allocator, entry.name);

                // Check .codedbignore patterns for files
                if (self.ignore_patterns.items.len > 0 and self.isIgnored(entry.name, self.name_buffer.items)) {
                    self.name_buffer.shrinkRetainingCapacity(self.dir_prefix_len);
                    continue;
                }

                return .{ .path = self.name_buffer.items };
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

// Paths are collected serially first, then stat calls fan out across disjoint
// chunks. Workers only publish size/stat_succeeded into their own entries; the
// caller records snapshots serially in discovery order after every join. That
// keeps sequence assignment deterministic and avoids shared worker error state.
fn statScanForInitial(io: std.Io, dir: std.Io.Dir, recs: []InitialScanEntry) void {
    for (recs) |*record| {
        const ds = dir.statFile(io, record.path, .{}) catch continue;
        record.size = ds.size;
        record.stat_succeeded = true;
    }
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
    // Paths collected serially first (via FilteredWalker, pure walk no stats).
    while (try walker.next()) |entry| {
        try entries.append(allocator, .{
            .path = try allocator.dupe(u8, entry.path),
            .size = 0,
            .stat_succeeded = false,
            .skip_trigram = false, // set after parallel stat fan
        });
    }
    // Stats fan out across disjoint slices; per-stat errors are swallowed. After
    // joining, snapshots are recorded serially so sequence order remains stable
    // and record errors propagate without cross-thread error sharing.
    if (entries.items.len > 0) {
        const want_workers = blk: {
            if (cio.posixGetenv("CODEDB_LOAD_WORKERS")) |raw| {
                const parsed = std.fmt.parseInt(usize, raw, 10) catch 0;
                if (parsed > 0) break :blk parsed;
            }
            if (entries.items.len < 256) break :blk 1;
            const cpu_count = std.Thread.getCpuCount() catch 1;
            break :blk @min(@as(usize, @intCast(cpu_count)), 4);
        };
        const n_workers = @max(@as(usize, 1), @min(want_workers, entries.items.len));
        stat_fan: {
            if (n_workers <= 1) {
                statScanForInitial(io, dir, entries.items);
                break :stat_fan;
            }
            const threads = allocator.alloc(std.Thread, n_workers) catch {
                statScanForInitial(io, dir, entries.items);
                break :stat_fan;
            };
            defer allocator.free(threads);

            const chunk = entries.items.len / n_workers;
            const rem = entries.items.len % n_workers;
            var off: usize = 0;
            var spawned: usize = 0;
            var spawn_failed = false;
            for (0..n_workers) |i| {
                const extra: usize = if (i < rem) 1 else 0;
                const start = off;
                off += chunk + extra;
                const recs = entries.items[start..off];
                if (spawn_failed) {
                    statScanForInitial(io, dir, recs);
                    continue;
                }
                if (std.Thread.spawn(.{}, statScanForInitial, .{ io, dir, recs })) |t| {
                    threads[spawned] = t;
                    spawned += 1;
                } else |_| {
                    statScanForInitial(io, dir, recs);
                    spawn_failed = true;
                }
            }
            for (threads[0..spawned]) |t| t.join();
        }
        for (entries.items) |entry| {
            if (!entry.stat_succeeded) continue;
            _ = try store.recordSnapshot(entry.path, entry.size, 0);
        }
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

fn initialScanWorker(io: std.Io, results: *WorkerParsedResults, root: []const u8, entries: []const InitialScanEntry, word_shard: ?*WordIndex, trigram_shard: ?*TrigramIndex) void {
    const dir = std.Io.Dir.cwd().openDir(io, root, .{}) catch {
        for (0..entries.len) |index| results.publish(io, index, null);
        return;
    };
    defer dir.close(io);

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
    const dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);

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
                    try explorer.commitParsedFileOwnedOutline(file.path, file.content, file.outline, true, file.skip_trigram);
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
        threads[i] = try std.Thread.spawn(.{}, initialScanWorker, .{ io, worker, root, chunk, shard_ptr, null });
        spawned += 1;
    }
    const profile_spawn_done: i128 = if (profile) cio.nanoTimestamp() else 0;
    // Shared Explorer maps remain serial, but consume ready slots while workers
    // continue parsing. Worker/chunk order matches the prior cold-scan semantics
    // for symbol precedence, cache eviction, dependency output, and persistence.
    for (workers) |*worker| {
        for (0..worker.items.len) |item_index| {
            if (worker.takeReady(io, item_index)) |file| {
                try explorer.commitParsedFileAdoptOutline(file.path, file.content, file.outline, true, file.skip_trigram);
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
fn readAndBuildTrigramShardWorker(io: std.Io, shard: *TrigramIndex, root: []const u8, entries: []const InitialScanEntry, build_error: *?anyerror) void {
    const dir = std.Io.Dir.cwd().openDir(io, root, .{}) catch |err| {
        build_error.* = err;
        return;
    };
    defer dir.close(io);

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
    const dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);

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
            threads[i] = try std.Thread.spawn(.{}, readAndBuildTrigramShardWorker, .{ io, shard, root, chunk, &build_errors[i] });
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
            threads[i] = try std.Thread.spawn(.{}, initialScanWorker, .{ io, worker, root, chunk, null, &shards[i] });
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
    const stat = try dir.statFile(io, path, .{});
    const content = (try readIndexableFile(io, dir, path, allocator, stat.size, false)) orelse return;
    defer allocator.free(content);
    try explorer.indexFileOutlineOnly(path, content);
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

    var known = FileMap.init(backing);
    defer {
        var iter = known.iterator();
        while (iter.next()) |kv| {
            backing.free(kv.key_ptr.*);
        }
        known.deinit();
    }
    // Build initial snapshot: stat every file, defer expensive hashing until mtime changes.
    {
        var snap_arena = std.heap.ArenaAllocator.init(backing);
        defer snap_arena.deinit();
        const tmp = snap_arena.allocator();
        const dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return;
        defer dir.close(io);
        var walker = FilteredWalker.init(io, dir, tmp) catch return;
        defer walker.deinit();
        while (walker.next() catch null) |entry| {
            const stat = dir.statFile(io, entry.path, .{}) catch continue;
            const mtime: i64 = @intCast(@divTrunc(stat.mtime.nanoseconds, std.time.ns_per_ms));
            const duped = backing.dupe(u8, entry.path) catch continue;
            known.put(duped, .{ .mtime = mtime, .size = stat.size, .hash = 0, .seen = false }) catch backing.free(duped);
        }
    }

    // Track current git HEAD to detect branch switches (#116)
    var last_git_head: ?[40]u8 = git_mod.getGitHead(root, backing) catch null;

    // Cache .git/HEAD mtime so we only fork git rev-parse when the file changes (#254)
    var git_head_mtime: i128 = blk: {
        const root_dir = std.Io.Dir.cwd().openDir(io, root, .{}) catch break :blk -1;
        defer root_dir.close(io);
        const st = root_dir.statFile(io, ".git/HEAD", .{}) catch break :blk -1;
        break :blk @intCast(st.mtime.nanoseconds);
    };

    while (!shutdown.load(.acquire)) {
        // Check for muonry edit notifications (instant re-index, no 2s delay)
        drainNotifyFile(io, store, explorer, queue, &known, root, backing);

        // Poll every 2s — gentle on CPU, fast enough to catch saves
        cio.sleepMs(2 * std.time.ns_per_s / 1_000_000);

        // Check if git HEAD changed — stat .git/HEAD mtime first to skip fork+exec (#254)
        var current_head: ?[40]u8 = last_git_head;
        const head_changed = blk: {
            {
                const root_dir = std.Io.Dir.cwd().openDir(io, root, .{}) catch break :blk false;
                defer root_dir.close(io);
                const st = root_dir.statFile(io, ".git/HEAD", .{}) catch break :blk false;
                const st_mtime: i128 = @intCast(st.mtime.nanoseconds);
                if (st_mtime == git_head_mtime) break :blk false;
                git_head_mtime = st_mtime;
            }
            current_head = git_mod.getGitHead(root, backing) catch null;
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

            // Re-scan with trigram cap
            var rescan_arena = std.heap.ArenaAllocator.init(backing);
            defer rescan_arena.deinit();
            const tmp = rescan_arena.allocator();
            const dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch continue;
            defer dir.close(io);
            var walker = FilteredWalker.init(io, dir, tmp) catch continue;
            defer walker.deinit();
            const max_trigram_files = trigramFileCap();
            var file_count: usize = 0;
            while (walker.next() catch null) |entry| {
                const stat = dir.statFile(io, entry.path, .{}) catch continue;
                _ = store.recordSnapshot(entry.path, stat.size, 0) catch {};
                file_count += 1;
                const effective_skip = file_count > max_trigram_files;
                indexFileContent(io, explorer, dir, entry.path, backing, effective_skip) catch {};
                const mtime: i64 = @intCast(@divTrunc(stat.mtime.nanoseconds, std.time.ns_per_ms));
                const duped = backing.dupe(u8, entry.path) catch continue;
                known.put(duped, .{ .mtime = mtime, .size = stat.size, .hash = 0, .seen = false }) catch backing.free(duped);
            }
            continue;
        }

        // Each diff cycle gets its own arena so temporaries are freed
        var cycle_arena = std.heap.ArenaAllocator.init(backing);
        defer cycle_arena.deinit();

        incrementalDiff(io, store, explorer, queue, &known, root, backing, cycle_arena.allocator()) catch |err| {
            std.log.err("watcher: diff failed: {}", .{err});
        };
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
    const content = dir.readFileAlloc(io, path, content_arena.allocator(), .limited(max_indexed_file_bytes)) catch return std.math.maxInt(u64);
    const hash = std.hash.Wyhash.hash(0, content);
    indexContentBuffer(explorer, path, content, false) catch {};
    return hash;
}

fn pushEventOrWait(queue: *EventQueue, event: FsEvent) void {
    // Preserve prior drop-on-full behavior so producer never stalls permanently.
    _ = queue.push(event);
}

fn incrementalDiff(io: std.Io, store: *Store, explorer: *Explorer, queue: *EventQueue, known: *FileMap, root: []const u8, persistent: std.mem.Allocator, tmp: std.mem.Allocator) !void {
    const dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);

    // Mark all known files unseen for this cycle.
    var known_iter = known.iterator();
    while (known_iter.next()) |kv| {
        kv.value_ptr.seen = false;
    }

    var walker = try FilteredWalker.init(io, dir, tmp);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        const stat = dir.statFile(io, entry.path, .{}) catch continue;
        const mtime: i64 = @intCast(@divTrunc(stat.mtime.nanoseconds, std.time.ns_per_ms));

        if (known.getEntry(entry.path)) |known_entry| {
            const old = known_entry.value_ptr;
            old.seen = true;

            // Mtime unchanged -> skip (cheap path, no IO)
            if (old.mtime == mtime) continue;

            const stable_path = known_entry.key_ptr.*;

            // Mtime changed: read the file once and reuse the buffer for both the
            // content hash (change detection) and indexing, instead of hashing
            // (full read) and then indexing (a second full read).
            var hash: u64 = 0;
            var content: ?[]const u8 = null;
            var content_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer content_arena.deinit();
            if (!shouldSkipFile(entry.path) and stat.size <= max_indexed_file_bytes) {
                if (dir.readFileAlloc(io, entry.path, content_arena.allocator(), .limited(max_indexed_file_bytes))) |buf| {
                    content = buf;
                    hash = std.hash.Wyhash.hash(0, buf);
                } else |_| {
                    hash = std.math.maxInt(u64); // IO error -> force re-index next cycle
                }
            }

            // Same size + matching prior hash -> content identical (touch, git
            // checkout): update metadata only, no snapshot/event/re-index.
            if (old.size == stat.size and hash != 0 and old.hash != 0 and hash == old.hash) {
                old.mtime = mtime;
                old.size = stat.size;
                continue;
            }

            const seq = try store.recordSnapshot(entry.path, stat.size, hash);
            old.mtime = mtime;
            old.size = stat.size;
            old.hash = hash;
            if (FsEvent.init(stable_path, .modified, seq)) |ev| pushEventOrWait(queue, ev);
            if (content) |buf| indexContentBuffer(explorer, stable_path, buf, false) catch {};
        } else {
            // New files always generate an event, so skip the extra full-file hash pass.
            const duped = try persistent.dupe(u8, entry.path);
            errdefer persistent.free(duped);
            const seq = try store.recordSnapshot(duped, stat.size, 0);
            try known.put(duped, .{ .mtime = mtime, .size = stat.size, .hash = 0, .seen = true });
            if (FsEvent.init(duped, .created, seq)) |ev| pushEventOrWait(queue, ev);
            indexFileContent(io, explorer, dir, duped, tmp, false) catch {};
        }
    }

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
    }
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
    return @import("snapshot.zig").isSensitivePath(path);
}

fn indexFileContent(io: std.Io, explorer: *Explorer, dir: std.Io.Dir, path: []const u8, allocator: std.mem.Allocator, skip_trigram: bool) !void {
    _ = allocator;
    if (shouldSkipFile(path)) return;
    const stat = try dir.statFile(io, path, .{});
    // Use page_allocator arena for content — pages returned to OS immediately
    // via munmap on deinit, eliminating GPA page retention from content churn.
    var content_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer content_arena.deinit();
    const content = (try readIndexableFile(io, dir, path, content_arena.allocator(), stat.size, false)) orelse return;
    try indexContentBuffer(explorer, path, content, skip_trigram);
}

// ── muonry interop ───────────────────────────────────────────────────────────
//
// muonry appends changed file paths to /tmp/codedb-notify after each edit.
// We drain this file on every poll cycle and re-index the listed files
// immediately, eliminating the 2s polling delay for muonry-sourced edits.

fn drainNotifyFile(io: std.Io, store: *Store, explorer: *Explorer, queue: *EventQueue, known: *FileMap, root: []const u8, alloc: std.mem.Allocator) void {
    // Atomically read + truncate
    const notify_path = "/tmp/codedb-notify";
    const file = std.Io.Dir.cwd().openFile(io, notify_path, .{ .mode = .read_write }) catch return;
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
    const dir = std.Io.Dir.cwd().openDir(io, root, .{}) catch return;
    defer dir.close(io);

    var lines = std.mem.splitScalar(u8, data_slice, '\n');
    while (lines.next()) |line| {
        const path = std.mem.trim(u8, line, " \t\r");
        if (path.len == 0) continue;

        // Make path relative to root if it's absolute
        const rel = if (std.mem.startsWith(u8, path, root))
            std.mem.trimStart(u8, path[root.len..], "/")
        else
            path;

        // Skip re-indexing if file hasn't changed since last known state (#228)
        const stat = dir.statFile(io, rel, .{}) catch continue;
        const mtime: i64 = @intCast(@divTrunc(stat.mtime.nanoseconds, std.time.ns_per_ms));
        if (known.getPtr(rel)) |existing| {
            if (existing.mtime == mtime and existing.size == stat.size) continue;
        }

        // Read once: index + hash from the same buffer (previously two separate
        // full reads of the same file per notification).
        const hash = hashAndIndexFile(io, explorer, dir, rel, stat.size);
        if (hash == std.math.maxInt(u64)) continue; // read failed — retry next cycle

        // Update known-file state so incrementalDiff doesn't double-process
        if (known.getPtr(rel)) |existing| {
            existing.mtime = mtime;
            existing.size = stat.size;
            existing.hash = hash;
        }

        // Push event to queue
        if (FsEvent.init(rel, .modified, store.currentSeq())) |ev| {
            _ = queue.push(ev);
        }
    }
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
    explorer.setRoot(io, root);
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

    var queue = EventQueue{};
    var cycle_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer cycle_arena.deinit();
    try incrementalDiff(io, &store, &explorer, &queue, &known, root, testing.allocator, cycle_arena.allocator());

    try testing.expect(!explorer.outlines.contains("docs/b.md"));
    try testing.expect(explorer.outlines.contains("docs/c.md"));
    const links = explorer.document_graph.getForwardDeps("docs/a.md") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 1), links.len);
    try testing.expectEqualStrings("docs/c.md", links[0]);
}
