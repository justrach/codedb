const std = @import("std");
const compat = @import("compat.zig");
const Store = @import("store.zig").Store;
const Explorer = @import("explore.zig").Explorer;
const explore_mod = @import("explore.zig");
const git_mod = @import("git.zig");
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

    events: [CAPACITY]?FsEvent = [_]?FsEvent{null} ** CAPACITY,
    head: usize = 0,
    tail: usize = 0,
    mu: std.Thread.Mutex = .{},

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
    mtime: i64,   // milliseconds since epoch — cheap stat check
    size: u64,    // cheap change discriminator before hashing
    hash: u64,    // wyhash of content — confirms actual change
    seen: bool,   // set during current poll cycle for deletion detection
};

const FileMap = std.StringHashMap(FileState);

const InitialScanEntry = struct {
    path: []u8,
    skip_trigram: bool,
};

const ParsedScanFile = struct {
    path: []const u8,
    content: []const u8,
    outline: explore_mod.FileOutline,
    skip_trigram: bool,
};

const WorkerParsedResults = struct {
    arena: std.heap.ArenaAllocator,
    items: std.ArrayList(ParsedScanFile),

    fn init(backing: std.mem.Allocator) WorkerParsedResults {
        return .{
            .arena = std.heap.ArenaAllocator.init(backing),
            .items = .{},
        };
    }

    fn deinit(self: *WorkerParsedResults, backing: std.mem.Allocator) void {
        _ = backing;
        self.items.deinit(self.arena.allocator());
        self.arena.deinit();
    }
};

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
    "target",          // rust, java/maven
    ".gradle",
    ".idea",
    ".vs",
    "vendor",          // go, php
    "Pods",            // cocoapods
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
    ".serverless",
    "elm-stuff",
    ".stack-work",
    ".cabal-sandbox",
    ".cargo",
    "bower_components",
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
    for (skip_dirs) |skip| {
        if (std.mem.eql(u8, name, skip)) return true;
    }
    return false;
}

/// Recursive directory walker that prunes skip_dirs before descending.
/// Unlike std.fs.Dir.walk(), this never enters .git, node_modules, etc.,
/// avoiding the CPU cost of traversing potentially huge directory trees.
const FilteredWalker = struct {
    const StackItem = struct {
        dir_handle: std.fs.Dir,
        iter: std.fs.Dir.Iterator,
    };

    stack: std.ArrayList(StackItem),
    name_buffer: std.ArrayList(u8),
    allocator: std.mem.Allocator,
    dir_prefix_len: usize = 0,
    ignore_patterns: std.ArrayList([]const u8) = .{},

    pub const Entry = struct {
        path: []const u8, // relative path — valid until next call to next()
    };

    pub fn init(root: std.fs.Dir, allocator: std.mem.Allocator) !FilteredWalker {
        var self = FilteredWalker{
            .stack = .{},
            .name_buffer = .{},
            .allocator = allocator,
        };
        try self.stack.append(allocator, .{
            .dir_handle = root,
            .iter = root.iterate(),
        });

        // Load .codedbignore if it exists
        if (root.readFileAlloc(allocator, ".codedbignore", 64 * 1024)) |content| {
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
        if (root.readFileAlloc(allocator, ".gitignore", 64 * 1024)) |content| {
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
            if (i > 0) item.dir_handle.close();
        }
        self.stack.deinit(self.allocator);
        self.name_buffer.deinit(self.allocator);
        for (self.ignore_patterns.items) |p| self.allocator.free(p);
        self.ignore_patterns.deinit(self.allocator);
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
            if (try top.iter.next()) |entry| {
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
                    const sub = top.dir_handle.openDir(entry.name, .{ .iterate = true }) catch continue;

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

                if (entry.kind != .file) continue;

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
                    item.dir_handle.close();
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

fn collectInitialScanEntries(store: *Store, dir: std.fs.Dir, allocator: std.mem.Allocator, skip_trigram: bool) !std.ArrayList(InitialScanEntry) {
    var walker = try FilteredWalker.init(dir, allocator);
    defer walker.deinit();

    var entries: std.ArrayList(InitialScanEntry) = .{};
    errdefer {
        for (entries.items) |entry| allocator.free(entry.path);
        entries.deinit(allocator);
    }

    const max_trigram_files: usize = 15_000;
    var file_count: usize = 0;
    while (try walker.next()) |entry| {
        const stat = compat.dirStatFile(dir, entry.path) catch continue;
        _ = try store.recordSnapshot(entry.path, stat.size, 0);
        file_count += 1;
        try entries.append(allocator, .{
            .path = try allocator.dupe(u8, entry.path),
            .skip_trigram = skip_trigram or (file_count > max_trigram_files),
        });
    }
    return entries;
}

fn parseInitialScanEntry(root: []const u8, entry: InitialScanEntry, arena_alloc: std.mem.Allocator) !?ParsedScanFile {
    if (shouldSkipFile(entry.path)) return null;
    var dir = try std.fs.cwd().openDir(root, .{});
    defer dir.close();
    const file = try dir.openFile(entry.path, .{});
    defer file.close();
    const stat = try compat.fileStat(file);
    if (stat.size > 512 * 1024) return null;
    const content = try file.readToEndAlloc(arena_alloc, 512 * 1024);
    const check_len = @min(content.len, 512);
    for (content[0..check_len]) |c| {
        if (c == 0) return null;
    }
    const effective_skip_trigram = entry.skip_trigram or (content.len > 64 * 1024);
    const parsed = try explore_mod.Explorer.parseContentForIndexing(arena_alloc, entry.path, content);
    return .{
        .path = entry.path,
        .content = parsed.content,
        .outline = parsed.outline,
        .skip_trigram = effective_skip_trigram,
    };
}

fn initialScanWorker(results: *WorkerParsedResults, root: []const u8, entries: []const InitialScanEntry) void {
    const arena_alloc = results.arena.allocator();
    for (entries) |entry| {
        const parsed = parseInitialScanEntry(root, entry, arena_alloc) catch null;
        if (parsed) |file| {
            results.items.append(arena_alloc, file) catch return;
        }
    }
}

pub fn initialScanWithWorkerCount(store: *Store, explorer: *Explorer, root: []const u8, allocator: std.mem.Allocator, skip_trigram: bool, worker_count: usize) !void {
    var dir = try std.fs.cwd().openDir(root, .{ .iterate = true });
    defer dir.close();

    var entries = try collectInitialScanEntries(store, dir, allocator, skip_trigram);
    defer {
        for (entries.items) |entry| allocator.free(entry.path);
        entries.deinit(allocator);
    }

    if (entries.items.len == 0) return;
    const n_workers = @max(@as(usize, 1), @min(worker_count, entries.items.len));
    if (n_workers == 1) {
        for (entries.items) |entry| {
            {
                var arena = std.heap.ArenaAllocator.init(allocator);
                defer arena.deinit();
                const parsed = try parseInitialScanEntry(root, entry, arena.allocator());
                if (parsed) |file| {
                    try explorer.commitParsedFileOwnedOutline(file.path, file.content, file.outline, true, file.skip_trigram);
                }
            }
        }
        return;
    }

    const workers = try allocator.alloc(WorkerParsedResults, n_workers);
    defer {
        for (workers) |*worker| worker.deinit(allocator);
        allocator.free(workers);
    }
    const threads = try allocator.alloc(std.Thread, n_workers);
    defer allocator.free(threads);

    const chunk_size = entries.items.len / n_workers;
    const remainder = entries.items.len % n_workers;
    var offset: usize = 0;
    for (workers, 0..) |*worker, i| {
        worker.* = WorkerParsedResults.init(allocator);
        const extra: usize = if (i < remainder) 1 else 0;
        const count = chunk_size + extra;
        const chunk = entries.items[offset .. offset + count];
        offset += count;
        threads[i] = try std.Thread.spawn(.{}, initialScanWorker, .{ worker, root, chunk });
    }
    for (threads) |thread| thread.join();

    for (workers) |*worker| {
        for (worker.items.items) |file| {
            try explorer.commitParsedFileOwnedOutline(file.path, file.content, file.outline, true, file.skip_trigram);
        }
    }
}

/// Called from main thread to do the initial scan before listening.
pub fn initialScan(store: *Store, explorer: *Explorer, root: []const u8, allocator: std.mem.Allocator, skip_trigram: bool) !void {
    const worker_count = blk: {
        if (std.process.getEnvVarOwned(allocator, "CODEDB_SCAN_WORKERS")) |raw| {
            defer allocator.free(raw);
            const parsed = std.fmt.parseInt(usize, raw, 10) catch 0;
            if (parsed > 0) break :blk parsed;
        } else |_| {}
        const cpu_count = std.Thread.getCpuCount() catch 1;
        break :blk @min(@as(usize, @intCast(cpu_count)), 4);
    };
    try initialScanWithWorkerCount(store, explorer, root, allocator, skip_trigram, worker_count);
}

/// Fast index: parse symbols/outline only, skip expensive word+trigram indexes.
fn indexFileOutline(explorer: *Explorer, dir: std.fs.Dir, path: []const u8, allocator: std.mem.Allocator) !void {
    if (shouldSkipFile(path)) return;
    const file = try dir.openFile(path, .{});
    defer file.close();
    const stat = try compat.fileStat(file);
    if (stat.size > 512 * 1024) return;
    const content = try file.readToEndAlloc(allocator, 512 * 1024);
    defer allocator.free(content);
    const check_len = @min(content.len, 512);
    for (content[0..check_len]) |c| {
        if (c == 0) return;
    }
    try explorer.indexFileOutlineOnly(path, content);
}

/// Background thread: polls for incremental FS changes.
pub fn incrementalLoop(store: *Store, explorer: *Explorer, queue: *EventQueue, root: []const u8, shutdown: *std.atomic.Value(bool), scan_done: *std.atomic.Value(bool)) void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const backing = gpa.allocator();

    // Wait for initial scan to finish before building our known-file snapshot.
    // This prevents double-indexing: initialScan does full indexing, then we
    // only pick up changes that happen after.
    while (!scan_done.load(.acquire)) {
        if (shutdown.load(.acquire)) return;
        std.Thread.sleep(100 * std.time.ns_per_ms);
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
        var dir = std.fs.cwd().openDir(root, .{ .iterate = true }) catch return;
        defer dir.close();
        var walker = FilteredWalker.init(dir, tmp) catch return;
        defer walker.deinit();
        while (walker.next() catch null) |entry| {
            const stat = compat.dirStatFile(dir, entry.path) catch continue;
            const mtime: i64 = @intCast(@divTrunc(stat.mtime, std.time.ns_per_ms));
            const duped = backing.dupe(u8, entry.path) catch continue;
            known.put(duped, .{ .mtime = mtime, .size = stat.size, .hash = 0, .seen = false }) catch backing.free(duped);
        }
    }

    // Track current git HEAD to detect branch switches (#116)
    var last_git_head: ?[40]u8 = git_mod.getGitHead(root, backing) catch null;

    // Cache .git/HEAD mtime so we only fork git rev-parse when the file changes (#254)
    var git_head_mtime: i128 = blk: {
        var root_dir = std.fs.cwd().openDir(root, .{}) catch break :blk -1;
        defer root_dir.close();
        const st = compat.dirStatFile(root_dir, ".git/HEAD") catch break :blk -1;
        break :blk st.mtime;
    };

    while (!shutdown.load(.acquire)) {
        // Check for muonry edit notifications (instant re-index, no 2s delay)
        drainNotifyFile(store, explorer, queue, &known, root, backing);

        // Poll every 2s — gentle on CPU, fast enough to catch saves
        std.Thread.sleep(2 * std.time.ns_per_s);

        // Check if git HEAD changed — stat .git/HEAD mtime first to skip fork+exec (#254)
        var current_head: ?[40]u8 = last_git_head;
        const head_changed = blk: {
            {
                var root_dir = std.fs.cwd().openDir(root, .{}) catch break :blk false;
                defer root_dir.close();
                const st = compat.dirStatFile(root_dir, ".git/HEAD") catch break :blk false;
                if (st.mtime == git_head_mtime) break :blk false;
                git_head_mtime = st.mtime;
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
            var remove_list: std.ArrayList([]const u8) = .{};
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
            var dir = std.fs.cwd().openDir(root, .{ .iterate = true }) catch continue;
            defer dir.close();
            var walker = FilteredWalker.init(dir, tmp) catch continue;
            defer walker.deinit();
            const max_trigram_files: usize = 15_000;
            var file_count: usize = 0;
            while (walker.next() catch null) |entry| {
                const stat = dir.statFile(entry.path) catch continue;
                _ = store.recordSnapshot(entry.path, stat.size, 0) catch {};
                file_count += 1;
                const effective_skip = file_count > max_trigram_files;
                indexFileContent(explorer, dir, entry.path, backing, effective_skip) catch {};
                const mtime: i64 = @intCast(@divTrunc(stat.mtime, std.time.ns_per_ms));
                const duped = backing.dupe(u8, entry.path) catch continue;
                known.put(duped, .{ .mtime = mtime, .size = stat.size, .hash = 0, .seen = false }) catch backing.free(duped);
            }
            continue;
        }

        // Each diff cycle gets its own arena so temporaries are freed
        var cycle_arena = std.heap.ArenaAllocator.init(backing);
        defer cycle_arena.deinit();

        incrementalDiff(store, explorer, queue, &known, root, backing, cycle_arena.allocator()) catch |err| {
            std.log.err("watcher: diff failed: {}", .{err});
        };
    }
}

fn hashFile(dir: std.fs.Dir, path: []const u8, size: u64) !u64 {
    // Returns 0 for intentional skip (large files, filtered extensions).
    // Returns maxInt(u64) on IO error so the value always differs from a valid
    // previously stored hash of 0, preventing a false "content unchanged" conclusion.
    if (shouldSkipFile(path)) return 0;
    const file = dir.openFile(path, .{}) catch return std.math.maxInt(u64);
    defer file.close();
    if (size > 512 * 1024) return 0;

    var hasher = std.hash.Wyhash.init(0);
    var buf: [16 * 1024]u8 = undefined;
    while (true) {
        const n = file.read(&buf) catch return std.math.maxInt(u64);
        if (n == 0) break;
        hasher.update(buf[0..n]);
    }
    return hasher.final();
}

fn pushEventOrWait(queue: *EventQueue, event: FsEvent) void {
    // Preserve prior drop-on-full behavior so producer never stalls permanently.
    _ = queue.push(event);
}


fn incrementalDiff(store: *Store, explorer: *Explorer, queue: *EventQueue, known: *FileMap, root: []const u8, persistent: std.mem.Allocator, tmp: std.mem.Allocator) !void {
    var dir = try std.fs.cwd().openDir(root, .{ .iterate = true });
    defer dir.close();

    // Mark all known files unseen for this cycle.
    var known_iter = known.iterator();
    while (known_iter.next()) |kv| {
        kv.value_ptr.seen = false;
    }

    var walker = try FilteredWalker.init(dir, tmp);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        const stat = compat.dirStatFile(dir, entry.path) catch continue;
        const mtime: i64 = @intCast(@divTrunc(stat.mtime, std.time.ns_per_ms));

        if (known.getEntry(entry.path)) |known_entry| {
            const old = known_entry.value_ptr;
            old.seen = true;

            // Mtime unchanged -> skip (cheap path, no IO)
            if (old.mtime == mtime) continue;

            // Size changed -> definitely changed, skip expensive hash.
            var hash: u64 = 0;
            if (old.size == stat.size) {
                // Same size + changed mtime -> hash to confirm content actually differs.
                hash = hashFile(dir, entry.path, stat.size) catch 0;
            }
            if (old.size == stat.size and hash != 0 and old.hash != 0 and hash == old.hash) {
                // Content identical (e.g. touch, git checkout) -> update metadata only.
                old.mtime = mtime;
                old.size = stat.size;
                continue;
            }

            const seq = try store.recordSnapshot(entry.path, stat.size, hash);
            old.mtime = mtime;
            old.size = stat.size;
            old.hash = hash;
            const stable_path = known_entry.key_ptr.*;
            if (FsEvent.init(stable_path, .modified, seq)) |ev| pushEventOrWait(queue, ev);
            indexFileContent(explorer, dir, stable_path, tmp, false) catch {};
        } else {
            // New files always generate an event, so skip the extra full-file hash pass.
            const duped = try persistent.dupe(u8, entry.path);
            errdefer persistent.free(duped);
            const seq = try store.recordSnapshot(duped, stat.size, 0);
            try known.put(duped, .{ .mtime = mtime, .size = stat.size, .hash = 0, .seen = true });
            if (FsEvent.init(duped, .created, seq)) |ev| pushEventOrWait(queue, ev);
            indexFileContent(explorer, dir, duped, tmp, false) catch {};
        }
    }

    // Detect deleted files
    var to_remove: std.ArrayList([]const u8) = .{};
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
    ".png",  ".jpg",  ".jpeg", ".gif",  ".bmp",  ".ico",  ".icns", ".webp",
    ".svg",  ".ttf",  ".otf",  ".woff", ".woff2", ".eot",
    ".zip",  ".tar",  ".gz",   ".bz2",  ".xz",   ".7z",  ".rar",
    ".pdf",  ".doc",  ".docx", ".xls",  ".xlsx", ".pptx",
    ".mp3",  ".mp4",  ".wav",  ".avi",  ".mov",  ".flv",  ".ogg",  ".webm",
    ".exe",  ".dll",  ".so",   ".dylib", ".o",   ".a",    ".lib",
    ".wasm", ".pyc",  ".pyo",  ".class",
    ".db",   ".sqlite", ".sqlite3",
    ".lock", ".sum",
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
/// Replicates the filter from snapshot.zig so live indexing and snapshots
/// apply the same exclusion rules. Optimized: basename check + early exit.
pub fn isSensitivePath(path: []const u8) bool {
    const basename = if (std.mem.lastIndexOfScalar(u8, path, '/')) |sep| path[sep + 1 ..] else path;
    // Fast path: most source files have extensions like .zig, .ts, .py — none start with '.'
    // or match sensitive patterns. Skip the full check for common cases.
    if (basename.len == 0) return false;
    const first = basename[0];
    // Only check sensitive names if basename starts with '.', 'c', 's', 'i' or has key/cert extension
    if (first != '.' and first != 'c' and first != 's' and first != 'i') {
        // Still need to check extensions and directory patterns
        if (std.mem.endsWith(u8, basename, ".pem") or
            std.mem.endsWith(u8, basename, ".key") or
            std.mem.endsWith(u8, basename, ".p12") or
            std.mem.endsWith(u8, basename, ".pfx") or
            std.mem.endsWith(u8, basename, ".jks")) return true;
        if (std.mem.indexOf(u8, path, ".ssh/") != null or
            std.mem.indexOf(u8, path, ".gnupg/") != null or
            std.mem.indexOf(u8, path, ".aws/") != null) return true;
        return false;
    }
    // .env* wildcard (catches .env, .env.local, .env.production, etc.)
    if (basename.len >= 4 and std.mem.eql(u8, basename[0..4], ".env")) return true;
    // Exact matches
    const sensitive_names = [_][]const u8{
        ".dev.vars", ".npmrc", ".pypirc", ".netrc",
        "credentials.json", "service-account.json",
        "secrets.json", "secrets.yaml", "secrets.yml",
        "id_rsa", "id_ed25519",
    };
    for (sensitive_names) |name| {
        if (std.mem.eql(u8, basename, name)) return true;
    }
    if (std.mem.endsWith(u8, basename, ".pem") or
        std.mem.endsWith(u8, basename, ".key") or
        std.mem.endsWith(u8, basename, ".p12")) return true;
    if (std.mem.indexOf(u8, path, ".ssh/") != null or
        std.mem.indexOf(u8, path, ".gnupg/") != null or
        std.mem.indexOf(u8, path, ".aws/") != null) return true;
    return false;
}

fn indexFileContent(explorer: *Explorer, dir: std.fs.Dir, path: []const u8, allocator: std.mem.Allocator, skip_trigram: bool) !void {
    if (shouldSkipFile(path)) return;
    const file = try dir.openFile(path, .{});
    defer file.close();
    const stat = try compat.fileStat(file);
    // Skip files over 512KB (likely minified bundles or generated)
    if (stat.size > 512 * 1024) return;
    const content = try file.readToEndAlloc(allocator, 512 * 1024);
    defer allocator.free(content);
    // Skip binary content (check first 512 bytes for null bytes)
    const check_len = @min(content.len, 512);
    for (content[0..check_len]) |c| {
        if (c == 0) return;
    }
    // Skip trigram indexing for files > 64KB to prevent OOM on large repos
    const effective_skip_trigram = skip_trigram or (content.len > 64 * 1024);
    if (effective_skip_trigram) {
        try explorer.indexFileSkipTrigram(path, content);
    } else {
        try explorer.indexFile(path, content);
    }
}

// ── muonry interop ───────────────────────────────────────────────────────────
//
// muonry appends changed file paths to /tmp/codedb-notify after each edit.
// We drain this file on every poll cycle and re-index the listed files
// immediately, eliminating the 2s polling delay for muonry-sourced edits.

fn drainNotifyFile(store: *Store, explorer: *Explorer, queue: *EventQueue, known: *FileMap, root: []const u8, alloc: std.mem.Allocator) void {
    // Atomically read + truncate
    const notify_path = "/tmp/codedb-notify";
    const file = std.fs.cwd().openFile(notify_path, .{ .mode = .read_write }) catch return;
    defer file.close();

    const data = file.readToEndAlloc(alloc, 64 * 1024) catch return;
    defer alloc.free(data);
    if (data.len == 0) return;

    // Truncate after reading
    file.seekTo(0) catch return;
    std.posix.ftruncate(file.handle, 0) catch return;

    // Re-index each notified path
    var dir = std.fs.cwd().openDir(root, .{}) catch return;
    defer dir.close();

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const path = std.mem.trim(u8, line, " \t\r");
        if (path.len == 0) continue;

        // Make path relative to root if it's absolute
        const rel = if (std.mem.startsWith(u8, path, root))
            std.mem.trimLeft(u8, path[root.len..], "/")
        else
            path;

        // Skip re-indexing if file hasn't changed since last known state (#228)
        const stat = compat.dirStatFile(dir, rel) catch continue;
        const mtime: i64 = @intCast(@divTrunc(stat.mtime, std.time.ns_per_ms));
        if (known.getPtr(rel)) |existing| {
            if (existing.mtime == mtime and existing.size == stat.size) continue;
        }

        indexFileContent(explorer, dir, rel, alloc, false) catch continue;

        // Update known-file state so incrementalDiff doesn't double-process
        const hash = hashFile(dir, rel, stat.size) catch continue;
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
