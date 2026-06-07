// codedb MCP server — JSON-RPC 2.0 over stdio
const cio = @import("cio.zig");
//
// Exposes codedb's exploration + edit engine as MCP tools.
// Uses mcp-zig for protocol utilities; adds roots support for workspace awareness.

const std = @import("std");
const testing = std.testing;
const mcp_lib = @import("mcp");
const mcpj = mcp_lib.json;
pub const Root = mcp_lib.mcp.Root;
const Store = @import("store.zig").Store;
const explore_mod = @import("explore.zig");
const Explorer = explore_mod.Explorer;
const reader_md = @import("reader_md.zig");
const AgentRegistry = @import("agent.zig").AgentRegistry;
const snapshot_json = @import("snapshot_json.zig");
const watcher = @import("watcher.zig");
const edit_mod = @import("edit.zig");
const linter_mod = @import("linter.zig");
const linter_pref = @import("linter_pref.zig");
const idx = @import("index.zig");
const snapshot_mod = @import("snapshot.zig");
const telemetry_mod = @import("telemetry.zig");
const git_mod = @import("git.zig");
const root_policy = @import("root_policy.zig");
const release_info = @import("release_info.zig");
pub const DeferredScan = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    store: *Store,
    explorer: *Explorer,
    scan_done: *std.atomic.Value(bool),
    shutdown: *std.atomic.Value(bool),
    telem: *telemetry_mod.Telemetry,
    queue: *watcher.EventQueue,
    startup_t0: i64,
    triggered: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    scan_thread: ?std.Thread = null,
    resolved_root: []const u8 = "",
    fallback_cwd: []const u8 = "",
    triggerFn: *const fn (ctx: *DeferredScan, abs_root: []const u8) void,
};

/// Resolve which path to scan from (first indexable root, or cwd fallback) and
/// fire the deferred scan exactly once. Returns true when this call actually
/// fired the trigger; false if it had already fired or no usable path is
/// available. Callers must filter denied paths out of `indexable_roots` first;
/// the `fallback_cwd` path is policy-checked here.
pub fn triggerDeferredScanWithFallback(
    ds: *DeferredScan,
    indexable_roots: []const Root,
    fallback_cwd: []const u8,
) bool {
    var path: []const u8 = "";
    if (indexable_roots.len > 0) {
        const uri_raw = indexable_roots[0].uri;
        path = if (std.mem.startsWith(u8, uri_raw, "file://")) uri_raw[7..] else uri_raw;
    }
    if (path.len == 0 and fallback_cwd.len > 0 and root_policy.isIndexableRoot(fallback_cwd)) {
        path = fallback_cwd;
    }
    if (path.len == 0) return false;
    if (ds.triggered.swap(true, .acq_rel)) return false;
    ds.triggerFn(ds, path);
    return true;
}

// ── Project cache ────────────────────────────────────────────────────────────

const SnapshotCache = struct {
    const MAX_CACHED_BYTES = 16 * 1024 * 1024;

    seq: u64 = std.math.maxInt(u64),
    bytes: ?[]u8 = null,
    mu: cio.Mutex = .{},

    fn deinit(self: *SnapshotCache, alloc: std.mem.Allocator) void {
        if (self.bytes) |bytes| {
            alloc.free(bytes);
            self.bytes = null;
        }
    }

    fn appendIfFresh(self: *SnapshotCache, alloc: std.mem.Allocator, out: *std.ArrayList(u8), seq: u64) bool {
        self.mu.lock();
        defer self.mu.unlock();
        const bytes = self.bytes orelse return false;
        if (self.seq != seq) return false;
        if (out.items.len == 0) {
            // The MCP dispatch buffer is consumed before it is deinitialized,
            // and snapshot cache owns these bytes until cache deinit/replacement.
            // Expose a borrowed view to avoid memcpying multi-hundred-KB snapshots
            // on every warm codedb_snapshot call.
            out.items = bytes;
            out.capacity = 0;
            return true;
        }
        out.appendSlice(alloc, bytes) catch return false;
        return true;
    }

    /// Takes ownership of `fresh` if it becomes the cache entry. If another
    /// caller filled the same seq first, frees `fresh` and appends the winner.
    fn putAndAppend(self: *SnapshotCache, alloc: std.mem.Allocator, out: *std.ArrayList(u8), seq: u64, fresh: []u8) void {
        self.mu.lock();
        defer self.mu.unlock();

        if (fresh.len > MAX_CACHED_BYTES) {
            if (self.bytes) |bytes| {
                alloc.free(bytes);
                self.bytes = null;
            }
            self.seq = std.math.maxInt(u64);
            if (out.items.len == 0) {
                out.* = std.ArrayList(u8).fromOwnedSlice(fresh);
            } else {
                out.appendSlice(alloc, fresh) catch {};
                alloc.free(fresh);
            }
            return;
        }

        if (self.bytes) |bytes| {
            if (self.seq == seq) {
                alloc.free(fresh);
                if (out.items.len == 0) {
                    out.items = bytes;
                    out.capacity = 0;
                } else {
                    out.appendSlice(alloc, bytes) catch {};
                }
                return;
            }
            alloc.free(bytes);
        }

        self.seq = seq;
        self.bytes = fresh;
        if (out.items.len == 0) {
            out.items = fresh;
            out.capacity = 0;
        } else {
            out.appendSlice(alloc, fresh) catch {};
        }
    }
};

const DepsCache = struct {
    seq: u64 = std.math.maxInt(u64),
    path: ?[]u8 = null,
    bytes: ?[]u8 = null,
    mu: cio.Mutex = .{},

    fn deinit(self: *DepsCache, alloc: std.mem.Allocator) void {
        if (self.path) |path| {
            alloc.free(path);
            self.path = null;
        }
        if (self.bytes) |bytes| {
            alloc.free(bytes);
            self.bytes = null;
        }
    }

    fn appendIfFresh(self: *DepsCache, out: *std.ArrayList(u8), seq: u64, path: []const u8) bool {
        self.mu.lock();
        defer self.mu.unlock();

        const cached_path = self.path orelse return false;
        const cached_bytes = self.bytes orelse return false;
        if (self.seq != seq or !std.mem.eql(u8, cached_path, path)) return false;

        // The dispatch buffer is consumed before deinit. Borrowing avoids
        // spending more time copying the tiny deps result than dispatching it.
        if (out.items.len == 0) {
            out.items = cached_bytes;
            out.capacity = 0;
            return true;
        }
        return false;
    }

    fn put(self: *DepsCache, alloc: std.mem.Allocator, seq: u64, path: []const u8, bytes: []const u8) void {
        const owned_path = alloc.dupe(u8, path) catch return;
        const owned_bytes = alloc.dupe(u8, bytes) catch {
            alloc.free(owned_path);
            return;
        };

        self.mu.lock();
        defer self.mu.unlock();

        if (self.path) |old_path| alloc.free(old_path);
        if (self.bytes) |old_bytes| alloc.free(old_bytes);
        self.seq = seq;
        self.path = owned_path;
        self.bytes = owned_bytes;
    }
};

const ProjectCtx = struct {
    explorer: *Explorer,
    store: *Store,
    snapshot_cache: *SnapshotCache,
    deps_cache: *DepsCache,
};

fn getProjectDataDir(allocator: std.mem.Allocator, project_path: []const u8) ?[]u8 {
    const hash = std.hash.Wyhash.hash(0, project_path);
    const home = cio.posixGetenv("HOME") orelse {
        return std.fmt.allocPrint(allocator, "{s}/.codedb", .{project_path}) catch null;
    };

    return std.fmt.allocPrint(allocator, "{s}/.codedb/projects/{x}", .{ home, hash }) catch null;
}

fn loadProjectTrigramFromDiskIfPresent(io: std.Io, explorer: *Explorer, project_path: []const u8, allocator: std.mem.Allocator) void {
    explorer.mu.lockShared();
    const already_loaded = explorer.trigram_index.fileCount() > 0;
    explorer.mu.unlockShared();
    if (already_loaded) return;

    const data_dir = getProjectDataDir(allocator, project_path) orelse return;
    defer allocator.free(data_dir);

    if (idx.MmapTrigramIndex.initFromDisk(io, data_dir, allocator)) |loaded| {
        explorer.mu.lock();
        defer explorer.mu.unlock();
        explorer.trigram_index.deinit();
        explorer.trigram_index = .{ .mmap = loaded };
    } else if (idx.TrigramIndex.readFromDisk(io, data_dir, allocator)) |loaded| {
        explorer.mu.lock();
        defer explorer.mu.unlock();
        explorer.trigram_index.deinit();
        explorer.trigram_index = .{ .heap = loaded };
    }
}

fn loadProjectWordIndexFromDiskIfPresent(io: std.Io, explorer: *Explorer, project_path: []const u8, allocator: std.mem.Allocator) void {
    if (!explorer.wordIndexCanLoadFromDisk()) return;

    const data_dir = getProjectDataDir(allocator, project_path) orelse {
        explorer.disableWordIndexDiskLoad();
        return;
    };
    defer allocator.free(data_dir);

    const header = idx.WordIndex.readDiskHeader(io, data_dir, allocator) catch null orelse {
        explorer.disableWordIndexDiskLoad();
        return;
    };

    explorer.mu.lockShared();
    const current_count = @as(u32, @intCast(explorer.outlines.count()));
    explorer.mu.unlockShared();
    if (header.file_count != current_count) {
        explorer.disableWordIndexDiskLoad();
        return;
    }

    const current_git_head = git_mod.getGitHead(project_path, allocator) catch null;
    const heads_match = blk: {
        if (current_git_head == null and header.git_head == null) break :blk true;
        if (current_git_head == null or header.git_head == null) break :blk false;
        break :blk std.mem.eql(u8, &current_git_head.?, &header.git_head.?);
    };
    if (!heads_match) {
        explorer.disableWordIndexDiskLoad();
        return;
    }

    if (idx.WordIndex.mmapFromDisk(io, data_dir, allocator) orelse idx.WordIndex.readFromDisk(io, data_dir, allocator)) |loaded| {
        explorer.replaceWordIndex(loaded);
    } else {
        explorer.disableWordIndexDiskLoad();
    }
}

fn shouldLoadWordIndexForSearch(args: *const std.json.ObjectMap) bool {
    if (getBool(args, "regex")) return false;
    const query = getStr(args, "query") orelse return false;
    if (query.len < 2 or query.len > 256) return false;

    // Single identifiers (legacy) AND multi-word / natural-language queries
    // (which route to the BM25 ranked path) both resolve through the word
    // index, so allow spaces between terms. Reject other punctuation so plain
    // literal-substring searches still skip the load.
    var saw_word_char = false;
    for (query) |c| {
        const is_word_char =
            (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '_';
        if (!is_word_char and c != ' ') return false;
        if (is_word_char and c != '_') saw_word_char = true;
    }
    return saw_word_char;
}

const ProjectCache = struct {
    const MAX_CACHED = 5;

    const Entry = struct {
        path: []u8,
        explorer: Explorer,
        store: Store,
        snapshot_cache: SnapshotCache,
        deps_cache: DepsCache,
        last_used: i64,
    };

    mu: cio.RwLock,
    alloc: std.mem.Allocator,
    entries: [MAX_CACHED]?*Entry,
    default_path: []const u8,
    default_snapshot_cache: SnapshotCache,
    default_deps_cache: DepsCache,
    content_cache_capacity: u32,
    // External-linter state for this connection (trial/graph-based-codedb).
    // LinterSession.enabled is seeded from the persisted preference in run().
    // The diagnostics cache uses c_allocator (malloc, thread-safe) because a
    // detached worker thread writes to it off the request path.
    linter: linter_mod.LinterSession = .{},
    diag: linter_mod.DiagnosticsCache,

    fn init(alloc_: std.mem.Allocator, default_path_: []const u8, content_cache_capacity_: u32) ProjectCache {
        return .{
            .mu = .{},
            .alloc = alloc_,
            .entries = [_]?*Entry{null} ** MAX_CACHED,
            .default_path = default_path_,
            .default_snapshot_cache = .{},
            .default_deps_cache = .{},
            .content_cache_capacity = content_cache_capacity_,
            .linter = .{},
            .diag = linter_mod.DiagnosticsCache.init(std.heap.c_allocator),
        };
    }

    fn deinit(self: *ProjectCache) void {
        // Drain in-flight linter workers BEFORE freeing anything they touch.
        self.diag.deinit();
        self.default_snapshot_cache.deinit(self.alloc);
        self.default_deps_cache.deinit(self.alloc);
        for (&self.entries) |*slot| {
            if (slot.*) |entry| {
                self.destroyEntry(entry);
                slot.* = null;
            }
        }
    }

    fn destroyEntry(self: *ProjectCache, entry: *Entry) void {
        entry.snapshot_cache.deinit(self.alloc);
        entry.deps_cache.deinit(self.alloc);
        entry.explorer.deinit();
        entry.store.deinit();
        self.alloc.free(entry.path);
        self.alloc.destroy(entry);
    }

    fn invalidate(self: *ProjectCache, path: []const u8) void {
        self.mu.lock();
        defer self.mu.unlock();

        for (&self.entries) |*slot| {
            if (slot.*) |entry| {
                if (std.mem.eql(u8, entry.path, path)) {
                    self.destroyEntry(entry);
                    slot.* = null;
                    return;
                }
            }
        }
    }

    fn get(
        self: *ProjectCache,
        io: std.Io,
        path: ?[]const u8,
        default_exp: *Explorer,
        default_store: *Store,
    ) !ProjectCtx {
        const p = path orelse return ProjectCtx{ .explorer = default_exp, .store = default_store, .snapshot_cache = &self.default_snapshot_cache, .deps_cache = &self.default_deps_cache };
        if (!root_policy.isIndexableRoot(p))
            return error.PathNotAllowed;

        self.mu.lock();
        defer self.mu.unlock();

        const now = cio.milliTimestamp();
        for (&self.entries) |*slot| {
            if (slot.*) |entry| {
                if (std.mem.eql(u8, entry.path, p)) {
                    entry.last_used = now;
                    return ProjectCtx{ .explorer = &entry.explorer, .store = &entry.store, .snapshot_cache = &entry.snapshot_cache, .deps_cache = &entry.deps_cache };
                }
            }
        }

        // Cache miss — load from snapshot
        const new_entry = self.alloc.create(Entry) catch return error.OutOfMemory;
        new_entry.path = self.alloc.dupe(u8, p) catch {
            self.alloc.destroy(new_entry);
            return error.OutOfMemory;
        };
        new_entry.explorer = Explorer.init(self.alloc, self.content_cache_capacity);
        new_entry.explorer.setRoot(io, p);
        new_entry.store = Store.init(self.alloc);
        new_entry.snapshot_cache = .{};
        new_entry.deps_cache = .{};
        new_entry.last_used = now;

        var snap_buf: [std.fs.max_path_bytes]u8 = undefined;
        const snap_path = std.fmt.bufPrint(&snap_buf, "{s}/codedb.snapshot", .{p}) catch {
            new_entry.store.deinit();
            new_entry.explorer.deinit();
            self.alloc.free(new_entry.path);
            self.alloc.destroy(new_entry);
            return error.PathTooLong;
        };

        if (!snapshot_mod.loadSnapshot(io, snap_path, &new_entry.explorer, &new_entry.store, self.alloc)) {
            // Fallback: try central store at ~/.codedb/projects/{hash}/codedb.snapshot
            const hash = std.hash.Wyhash.hash(0, p);
            var central_buf: [std.fs.max_path_bytes]u8 = undefined;
            const loaded_central = blk: {
                const home = cio.posixGetenv("HOME") orelse break :blk false;
                const central = std.fmt.bufPrint(&central_buf, "{s}/.codedb/projects/{x}/codedb.snapshot", .{ home, hash }) catch break :blk false;
                break :blk snapshot_mod.loadSnapshot(io, central, &new_entry.explorer, &new_entry.store, self.alloc);
            };
            if (!loaded_central) {
                new_entry.store.deinit();
                new_entry.explorer.deinit();
                self.alloc.free(new_entry.path);
                self.alloc.destroy(new_entry);
                if (std.mem.eql(u8, p, self.default_path) and default_store.currentSeq() > 0) {
                    return ProjectCtx{ .explorer = default_exp, .store = default_store, .snapshot_cache = &self.default_snapshot_cache, .deps_cache = &self.default_deps_cache };
                }
                return error.SnapshotLoadFailed;
            }
        }

        loadProjectTrigramFromDiskIfPresent(io, &new_entry.explorer, p, self.alloc);

        // Release raw file contents retained by the snapshot load — outlines,
        // trigram index, and word index are sufficient for all query tools.
        const fc = new_entry.explorer.outlines.count();
        if (fc > 1000) {
            new_entry.explorer.releaseContents();
            new_entry.explorer.releaseSecondaryIndexes();
        }

        // Find free slot or evict LRU
        var target_slot: usize = 0;
        var found_free = false;
        for (self.entries, 0..) |slot, i| {
            if (slot == null) {
                target_slot = i;
                found_free = true;
                break;
            }
        }
        if (!found_free) {
            var oldest_i: usize = 0;
            var oldest_t: i64 = self.entries[0].?.last_used;
            for (self.entries[1..], 0..) |slot_opt, j| {
                if (slot_opt.?.last_used < oldest_t) {
                    oldest_t = slot_opt.?.last_used;
                    oldest_i = j + 1;
                }
            }
            const evict = self.entries[oldest_i].?;
            self.destroyEntry(evict);
            target_slot = oldest_i;
        }

        self.entries[target_slot] = new_entry;
        return ProjectCtx{ .explorer = &new_entry.explorer, .store = &new_entry.store, .snapshot_cache = &new_entry.snapshot_cache, .deps_cache = &new_entry.deps_cache };
    }
};

pub const BenchContext = struct {
    cache: ProjectCache,

    pub fn init(alloc: std.mem.Allocator, default_path: []const u8, content_cache_capacity: u32) BenchContext {
        return .{
            .cache = ProjectCache.init(alloc, default_path, content_cache_capacity),
        };
    }

    pub fn deinit(self: *BenchContext) void {
        self.cache.deinit();
    }

    pub fn runDispatch(
        self: *BenchContext,
        io: std.Io,
        alloc: std.mem.Allocator,
        tool: Tool,
        args: *const std.json.ObjectMap,
        out: *std.ArrayList(u8),
        store: *Store,
        explorer: *Explorer,
        agents: *AgentRegistry,
    ) void {
        dispatch(io, alloc, tool, args, out, store, explorer, agents, &self.cache, null, 1);
    }

    pub fn runHandleCall(
        self: *BenchContext,
        io: std.Io,
        alloc: std.mem.Allocator,
        root: *const std.json.ObjectMap,
        stdout: cio.File,
        id: ?std.json.Value,
        store: *Store,
        explorer: *Explorer,
        agents: *AgentRegistry,
        telem: *telemetry_mod.Telemetry,
    ) void {
        handleCall(io, alloc, root, stdout, id, store, explorer, agents, &self.cache, telem, null, 1);
    }

    pub fn runToolCall(
        self: *BenchContext,
        io: std.Io,
        alloc: std.mem.Allocator,
        name: []const u8,
        tool: Tool,
        args: *const std.json.ObjectMap,
        store: *Store,
        explorer: *Explorer,
        agents: *AgentRegistry,
        telem: *telemetry_mod.Telemetry,
    ) struct { dispatch_ns: u64, response_bytes: usize } {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(alloc);

        const t0 = cio.nanoTimestamp();
        dispatch(io, alloc, tool, args, &out, store, explorer, agents, &self.cache, null, 1);
        const elapsed = cio.nanoTimestamp() - t0;

        const is_error = std.mem.startsWith(u8, out.items, "error:");
        telem.recordToolCall(name, elapsed, is_error, out.items.len);

        var summary: std.ArrayList(u8) = .empty;
        defer summary.deinit(alloc);
        summary.ensureTotalCapacity(alloc, 256) catch {};
        summary.appendSlice(alloc, if (is_error) MCP_RED ++ MCP_CROSS ++ " " ++ MCP_RESET else MCP_GREEN ++ MCP_CHECK ++ " " ++ MCP_RESET) catch {};
        summary.appendSlice(alloc, mcpToolIcon(name)) catch {};
        mcpGenerateSummary(alloc, name, args, out.items, is_error, &summary);
        var dur_buf: [96]u8 = undefined;
        summary.appendSlice(alloc, mcpFormatDuration(&dur_buf, elapsed)) catch {};

        var guidance: std.ArrayList(u8) = .empty;
        defer guidance.deinit(alloc);
        mcpGenerateGuidance(alloc, name, args, out.items, is_error, &guidance);

        var result: std.ArrayList(u8) = .empty;
        defer result.deinit(alloc);
        result.ensureTotalCapacity(alloc, out.items.len + summary.items.len + guidance.items.len + 256) catch {};
        result.appendSlice(alloc, "{\"content\":[") catch return .{ .dispatch_ns = @intCast(elapsed), .response_bytes = 0 };

        if (summary.items.len > 0) {
            result.appendSlice(alloc, "{\"type\":\"text\",\"text\":\"") catch return .{ .dispatch_ns = @intCast(elapsed), .response_bytes = result.items.len };
            mcpj.writeEscaped(alloc, &result, summary.items);
            result.appendSlice(alloc, "\"},") catch return .{ .dispatch_ns = @intCast(elapsed), .response_bytes = result.items.len };
        }

        result.appendSlice(alloc, "{\"type\":\"text\",\"text\":\"") catch return .{ .dispatch_ns = @intCast(elapsed), .response_bytes = result.items.len };
        mcpj.writeEscaped(alloc, &result, out.items);
        result.appendSlice(alloc, "\"}") catch return .{ .dispatch_ns = @intCast(elapsed), .response_bytes = result.items.len };

        if (guidance.items.len > 0) {
            result.appendSlice(alloc, ",{\"type\":\"text\",\"text\":\"") catch return .{ .dispatch_ns = @intCast(elapsed), .response_bytes = result.items.len };
            mcpj.writeEscaped(alloc, &result, guidance.items);
            result.appendSlice(alloc, "\"}") catch return .{ .dispatch_ns = @intCast(elapsed), .response_bytes = result.items.len };
        }

        result.appendSlice(alloc, if (is_error) "],\"isError\":true}" else "],\"isError\":false}") catch return .{ .dispatch_ns = @intCast(elapsed), .response_bytes = result.items.len };
        return .{ .dispatch_ns = @intCast(elapsed), .response_bytes = result.items.len };
    }
};

// ── Tool definitions ────────────────────────────────────────────────────────

pub const Tool = enum {
    codedb_tree,
    codedb_outline,
    codedb_symbol,
    codedb_search,
    codedb_word,
    codedb_callers,
    codedb_callpath,
    codedb_hot,
    codedb_deps,
    codedb_read,
    codedb_edit,
    codedb_changes,
    codedb_status,
    codedb_snapshot,
    codedb_bundle,
    codedb_remote,
    codedb_projects,
    codedb_index,
    codedb_find,
    codedb_query,
    codedb_glob,
    codedb_ls,
    codedb_context,
    codedb_diagnostics,
};

pub const tools_list =
    \\{"tools":[
    \\{"name":"codedb_tree","description":"Whole-repo file tree with per-file language, line counts, and symbol counts. Use to orient in an unfamiliar project.","inputSchema":{"type":"object","properties":{"project":{"type":"string","description":"Optional absolute path to a different project (must have codedb.snapshot)"}},"required":[]}},
    \\{"name":"codedb_outline","description":"Symbol outline of one file: functions, structs, enums, imports, consts with line numbers. 4-15x smaller than reading the raw file. Run before codedb_read to find the lines you actually need. Pass skeleton=true for a signature view — each symbol's declaration line with its body elided as '{ … N lines }', so a 2,000-line file collapses to ~one line per symbol.","inputSchema":{"type":"object","properties":{"path":{"type":"string","description":"File path relative to project root"},"compact":{"type":"boolean","description":"Condensed format without detail comments (default: false)"},"skeleton":{"type":"boolean","description":"Signature view: each symbol's declaration line with its body elided as '{ … N lines }'. Lossless at the API surface; codedb_read the range to expand a body (default: false)"},"project":{"type":"string","description":"Optional absolute path to a different project (must have codedb.snapshot)"}},"required":["path"]}},
    \\{"name":"codedb_symbol","description":"Find symbol definitions across the index — exact name, prefix, glob pattern, fuzzy match, or kind filter. Returns file, line, kind, and score. Pass format=json for structured output.","inputSchema":{"type":"object","properties":{"name":{"type":"string","description":"Exact symbol name"},"prefix":{"type":"string","description":"Prefix match (e.g. parse_)"},"pattern":{"type":"string","description":"Glob pattern on symbol name (e.g. *Manager)"},"kind":{"type":"string","description":"Filter by kind: function, struct, interface, class, method, enum"},"fuzzy":{"type":"boolean","description":"Fuzzy/typo-tolerant match when name is set (default: false)"},"body":{"type":"boolean","description":"Include source body for each symbol (default: false)"},"max_results":{"type":"integer","description":"Max results (default: 50, cap 200)"},"format":{"type":"string","description":"Set to json for structured JSON output"},"project":{"type":"string","description":"Optional absolute path to a different project (must have codedb.snapshot)"}},"required":[]}},
    \\{"name":"codedb_search","description":"Substring full-text search across the index (regex if regex=true). For one identifier prefer codedb_word; for a definition prefer codedb_symbol. Pass format=json for structured output with search provenance meta.","inputSchema":{"type":"object","properties":{"query":{"type":"string","description":"Text to search for (substring match, or regex if regex=true)"},"max_results":{"type":"integer","description":"Page size (default: 20, raise to 50 for broad surveys)"},"offset":{"type":"integer","description":"Pagination offset into the ranked results (default: 0). When more results exist, the response ends with a 'more results ... offset=N' line; pass that offset to get the next page."},"scope":{"type":"boolean","description":"Annotate results with enclosing symbol scope (default: false)"},"compact":{"type":"boolean","description":"Skip comment and blank lines in results (default: false)"},"paths_only":{"type":"boolean","description":"Return path:line per result without the matching line text — ~50% fewer tokens per call, useful for broad surveys or for budget-conscious agents (default: false)"},"regex":{"type":"boolean","description":"Treat query as regex pattern (default: false)"},"path_glob":{"type":"string","description":"Filter results to paths matching this glob, e.g. '*.zig', 'src/**/*.zig', or '**/*.{yaml,yml}'. Bare patterns like '*.zig' are auto-promoted to '**/*.zig' to match nested files."},"format":{"type":"string","description":"Set to json for structured JSON output with provenance meta"},"project":{"type":"string","description":"Optional absolute path to a different project (must have codedb.snapshot)"}},"required":["query"]}},
    \\{"name":"codedb_word","description":"Exact-identifier lookup via inverted index — every occurrence of one word, O(1). Use for single identifiers; use codedb_search for substrings or phrases.","inputSchema":{"type":"object","properties":{"word":{"type":"string","description":"Exact word/identifier to look up"},"project":{"type":"string","description":"Optional absolute path to a different project (must have codedb.snapshot)"}},"required":["word"]}},
    \\{"name":"codedb_callers","description":"Find every call site of a named symbol — fuses word-index occurrences with outline scope info. One round-trip vs codedb_word + codedb_outline-per-file. Returns {path, line, snippet, scope_name, scope_kind, scope_lines}. Excludes the symbol's own definition site.","inputSchema":{"type":"object","properties":{"name":{"type":"string","description":"Symbol name (exact identifier match)"},"max_results":{"type":"integer","description":"Maximum call sites to return (default: 30, raise for hot symbols)"},"project":{"type":"string","description":"Optional absolute path to a different project (must have codedb.snapshot)"}},"required":["name"]}},
    \\{"name":"codedb_callpath","description":"Shortest resolved call chain between two symbols via the local call graph (A→…→B). Use after codedb_callers when you need how execution reaches a callee. Returns each hop as path:name@line.","inputSchema":{"type":"object","properties":{"from":{"type":"string","description":"Source symbol name (exact identifier)"},"to":{"type":"string","description":"Target symbol name (exact identifier)"},"max_hops":{"type":"integer","description":"Max call hops to search (default: 12)"},"project":{"type":"string","description":"Optional absolute path to a different project (must have codedb.snapshot)"}},"required":["from","to"]}},
    \\{"name":"codedb_context","description":"Task-shaped composer: pass a natural-language task; returns ONE tight block (keywords used + symbol definitions + ranked files + top file:line snippets). Replaces 3-5 sequential search/word/symbol calls — use for first-touch orientation on a new task. For narrow follow-ups stick with codedb_search/codedb_symbol.","inputSchema":{"type":"object","properties":{"task":{"type":"string","description":"Natural-language task description (3-1024 chars). Include candidate identifiers (camelCase / snake_case) or \"quoted strings\" so the composer can extract keywords."},"project":{"type":"string","description":"Optional absolute path to a different project (must have codedb.snapshot)"}},"required":["task"]}},
    \\{"name":"codedb_diagnostics","description":"Fetch the latest linter diagnostics for a file, produced off the edit path (ruff/biome/etc.) after a recent codedb_edit. Call right after an edit to surface real errors the change may have introduced (undefined names, type/lint issues) on top of codedb's built-in checks. Returns 'no diagnostics available yet' when none are cached or external linters are disabled.","inputSchema":{"type":"object","properties":{"path":{"type":"string","description":"File path to fetch diagnostics for"}},"required":["path"]}},
    \\{"name":"codedb_hot","description":"Most recently modified files in the project, newest first.","inputSchema":{"type":"object","properties":{"limit":{"type":"integer","description":"Number of files to return (default: 10)"},"project":{"type":"string","description":"Optional absolute path to a different project (must have codedb.snapshot)"}},"required":[]}},
    \\{"name":"codedb_deps","description":"Dependency graph: who imports a file (default) or what a file imports (direction=depends_on). Set transitive=true for the full BFS blast radius.","inputSchema":{"type":"object","properties":{"path":{"type":"string","description":"File path to check dependencies for"},"direction":{"type":"string","enum":["imported_by","depends_on"],"description":"imported_by (default): who imports this file. depends_on: what this file imports."},"transitive":{"type":"boolean","description":"Follow dependency chain transitively (default: false)"},"max_depth":{"type":"integer","description":"Max traversal depth for transitive queries (default: unlimited)"},"project":{"type":"string","description":"Optional absolute path to a different project (must have codedb.snapshot)"}},"required":["path"]}},
    \\{"name":"codedb_read","description":"Read file contents, optionally a line range. Run codedb_outline first to pick the range — large files burn tokens fast. Pass if_hash to skip re-reads when the file is unchanged.","inputSchema":{"type":"object","properties":{"path":{"type":"string","description":"File path relative to project root"},"line_start":{"type":"integer","description":"Start line (1-indexed, inclusive). Omit for full file."},"line_end":{"type":"integer","description":"End line (1-indexed, inclusive). Omit to read to EOF."},"if_hash":{"type":"string","description":"Previous content hash. If unchanged, returns short 'unchanged:HASH' response."},"compact":{"type":"boolean","description":"Skip comment and blank lines (default: false)"},"project":{"type":"string","description":"Optional absolute path to a different project (must have codedb.snapshot)"}},"required":["path"]}},
    \\{"name":"codedb_edit","description":"Fallback editor — prefer your own native file-editing tool. codedb is a context/navigation tool, not an editor; reach for codedb_edit only when no native edit capability is available. When you do edit through codedb, op=str_replace with old_string/new_string is safest (old_string must match exactly once) — it cannot mis-target surrounding lines the way a range replace can. Also supports line ops: replace (range), insert (after line), delete (range), and create (author a new file from content). The result includes a syntax-health warning if the edit unbalances delimiters or drops a still-used import — heed it and re-read before continuing. Pass if_hash from the latest codedb_read to reject stale-line edits. Set dry_run=true for a diff preview.","inputSchema":{"type":"object","properties":{"path":{"type":"string","description":"File path to edit"},"op":{"type":"string","enum":["str_replace","replace","insert","delete","create"],"description":"Edit operation. str_replace=anchored (old_string/new_string); replace/delete use range; insert uses after; create=author a NEW file from content (errors if the path already exists)."},"content":{"type":"string","description":"New content (for replace/insert/create)"},"old_string":{"type":"string","description":"For op=str_replace: exact text to find; must occur exactly once in the file."},"new_string":{"type":"string","description":"For op=str_replace: replacement text for old_string."},"range_start":{"type":"integer","description":"Start line number (for replace/delete, 1-indexed)"},"range_end":{"type":"integer","description":"End line number (for replace/delete, 1-indexed)"},"after":{"type":"integer","description":"Insert after this line number (for insert)"},"if_hash":{"type":"string","description":"Hex hash from codedb_read's 'hash:' line. Edit is rejected with HashMismatch if the file has changed since."},"dry_run":{"type":"boolean","description":"If true, return a diff preview without writing. Disk and store are untouched. Default: false."}},"required":["path","op"]}},
    \\{"name":"codedb_changes","description":"Files changed since a given sequence number. Pair with codedb_status to poll for updates.","inputSchema":{"type":"object","properties":{"since":{"type":"integer","description":"Sequence number to get changes since (default: 0)"}},"required":[]}},
    \\{"name":"codedb_status","description":"Current indexed-file count, sequence number, and scan phase.","inputSchema":{"type":"object","properties":{"project":{"type":"string","description":"Optional absolute path to a different project (must have codedb.snapshot)"}},"required":[]}},
    \\{"name":"codedb_snapshot","description":"Pre-rendered JSON snapshot of the entire index — tree, outlines, symbols, deps. For caching or shipping to edge workers.","inputSchema":{"type":"object","properties":{"project":{"type":"string","description":"Optional absolute path to a different project (must have codedb.snapshot)"}},"required":[]}},
    \\{"name":"codedb_bundle","description":"Run up to 20 codedb_* calls in one round-trip. Each op is either MCP-style {\"tool\":\"codedb_search\",\"arguments\":{\"query\":\"Agent\"}} or inline {\"tool\":\"codedb_search\",\"query\":\"Agent\"} — both are accepted. Example: {\"ops\":[{\"tool\":\"codedb_search\",\"arguments\":{\"query\":\"Agent\"}},{\"tool\":\"codedb_outline\",\"arguments\":{\"path\":\"src/main.zig\"}}]}. Best for parallel outline/symbol/search; avoid bundling large codedb_read calls — responses are not size-capped. If a sub-op reports `received keys: []`, the wrapper field is misnamed: use `arguments` (MCP spec), not `args`.","inputSchema":{"type":"object","properties":{"ops":{"type":"array","description":"Sub-tool calls to dispatch (max 20). Each item must have `tool` AND `arguments` (pass `{}` if the sub-tool takes none). Inline args alongside `tool` are still accepted as a fallback.","items":{"type":"object","properties":{"tool":{"type":"string","description":"codedb_* tool name to invoke (e.g. codedb_outline, codedb_symbol, codedb_search, codedb_word, codedb_callers, codedb_read, codedb_deps, codedb_tree, codedb_hot, codedb_status, codedb_changes). Required."},"arguments":{"type":"object","description":"Per-call args matching that tool's inputSchema. Field MUST be named `arguments` (MCP `tools/call` convention) — `args` is silently ignored. Pass `{}` only if the sub-tool takes no arguments. Required."}},"required":["tool","arguments"]}},"project":{"type":"string","description":"Optional absolute path to a different project (must have codedb.snapshot)"}},"required":["ops"]}},
    \\{"name":"codedb_remote","description":"Query indexed public repos via api.wiki.codes. Pass action= one of: tree, outline, search, read, symbol, deps, score, cves, commits, branches, dep-history, policy, actions. Use action=actions first if unsure what a repo supports.","inputSchema":{"type":"object","properties":{"repo":{"type":"string","description":"GitHub repo in owner/repo format (e.g. vercel/next.js) or a raw wiki slug such as chromium."},"action":{"type":"string","enum":["tree","outline","search","read","actions","symbol","policy","deps","score","cves","commits","branches","dep-history"],"description":"What to query from api.wiki.codes: actions, tree, search, outline, read, symbol, policy, deps, score, cves, commits, branches, dep-history."},"query":{"type":"string","description":"Action-specific argument. search: text query. symbol: identifier name. outline: file path."},"path":{"type":"string","description":"For action=read: the file path to fetch."},"lines":{"type":"string","description":"For action=read: line range like '10-60' (1-indexed, inclusive). Omit for full file."},"limit":{"type":"integer","description":"For search/tree/deps/commits/branches/dep-history: cap the number of items returned (server may enforce its own ceiling)."},"offset":{"type":"integer","description":"For tree/deps/commits/branches/dep-history: skip the first N items (pagination)."},"prefix":{"type":"string","description":"For tree: only return paths starting with this prefix (e.g. 'src/')."},"expand":{"type":"boolean","description":"For tree: when true, return the full file list. When false returns a compact directory summary when supported."},"since":{"type":"string","description":"For commits/dep-history: ISO timestamp or commit SHA to start from."},"scope":{"type":"string","enum":["runtime","all"],"description":"For score/cves only. Defaults to runtime; use all to include dev/tooling dependencies."},"backend":{"type":"string","enum":["wiki"],"description":"Deprecated compatibility field. Only 'wiki' is accepted; requests always use api.wiki.codes."}},"required":["repo","action"]}},
    \\{"name":"codedb_projects","description":"List every locally indexed project on this machine: path, data-dir hash, snapshot presence.","inputSchema":{"type":"object","properties":{},"required":[]}},
    \\{"name":"codedb_index","description":"Index a local FOLDER (not a file). Builds outlines, trigrams, word index, and writes codedb.snapshot. After indexing, query it via the project= param on any other tool.","inputSchema":{"type":"object","properties":{"path":{"type":"string","description":"Absolute path to the FOLDER (not a file) to index, e.g. /Users/you/myproject"}},"required":["path"]}},
    \\{"name":"codedb_find","description":"Fuzzy FILE-NAME search ONLY — typo-tolerant subsequence match against indexed file paths. NOT a content/symbol search: 'rerank' will NOT find files containing rerankSignalScore unless the filename itself contains 'rerank'. For symbol lookups use codedb_word/codedb_symbol; for content use codedb_search.","inputSchema":{"type":"object","properties":{"query":{"type":"string","description":"Fuzzy filename query (e.g. 'authmidlware' for auth_middleware.go, 'test_auth', 'main.zig'). Matched against path basenames, not file contents."},"max_results":{"type":"integer","description":"Maximum results to return (default: 10)"},"project":{"type":"string","description":"Optional absolute path to a different project (must have codedb.snapshot)"}},"required":["query"]}},
    \\{"name":"codedb_query","description":"Composable pipeline — chain ops where each step feeds the next. Ops: find, search, filter, deps, outline, read, sort, limit. Replaces multi-call workflows with one request.","inputSchema":{"type":"object","properties":{"pipeline":{"type":"array","items":{"type":"object"},"description":"Array of pipeline steps. Each step has 'op' (find/search/filter/deps/outline/read/sort/limit) and op-specific params. Steps execute in order, each filtering/transforming the file set from the previous step. deps op: {\"op\":\"deps\",\"direction\":\"imported_by|depends_on\",\"transitive\":true,\"max_depth\":3}"},"project":{"type":"string","description":"Optional absolute path to a different project"}},"required":["pipeline"]}},
    \\{"name":"codedb_glob","description":"Match indexed paths against a glob: * (no /), ** (across /), ? (one char), {a,b} alternatives. Sorted lexicographically. Use when you know the path shape; codedb_find for fuzzy names.","inputSchema":{"type":"object","properties":{"pattern":{"type":"string","description":"Glob pattern (e.g. 'src/**/*.zig', '**/*.{yaml,yml}', 'tests/test_*.py')"},"max_results":{"type":"integer","description":"Maximum results to return (default: 200)"},"project":{"type":"string","description":"Optional absolute path to a different project (must have codedb.snapshot)"}},"required":["pattern"]}},
    \\{"name":"codedb_ls","description":"List immediate children of a directory: dirs first (alphabetical), then files with language and line/symbol counts. Drill down level-by-level when codedb_tree is too verbose.","inputSchema":{"type":"object","properties":{"path":{"type":"string","description":"Directory prefix relative to project root. Omit or pass empty string for root."},"project":{"type":"string","description":"Optional absolute path to a different project (must have codedb.snapshot)"}},"required":[]}}
    \\]}
;

/// Build the augmented `tools/list` payload with a discriminated `oneOf` on
/// the codedb_bundle ops items. Each branch pins `tool` to a const sub-tool
/// name and `arguments` to that sub-tool's actual `inputSchema`, so a model
/// emitting a bundle call is forced to populate `arguments` with the right
/// keys for whichever sub-tool it picked. (Stage 2 of issue #437; Stage 1 in
/// #434 added `arguments` to items.required.)
///
/// codedb_bundle (recursive — rejected at handleBundle) and codedb_edit
/// (write op — rejected at handleBundle) are excluded from the oneOf.
///
/// Caller owns returned slice. The intermediate parse and the slices it
/// references are freed before return.
pub const ToolsListOpts = struct {
    bundle_enabled: bool = false,
    discriminated_opt_in: bool = false,
};

/// Build the runtime `tools/list` response. Honors the bundle and
/// discriminated-schema env-var gates that run() reads. Always returns an
/// allocator-owned slice the caller must free.
pub fn buildToolsListResponse(alloc: std.mem.Allocator, opts: ToolsListOpts) ![]u8 {
    if (opts.bundle_enabled and opts.discriminated_opt_in) {
        return buildAugmentedToolsList(alloc);
    }

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var parsed = try std.json.parseFromSlice(std.json.Value, a, tools_list, .{});

    const root_obj = &parsed.value.object;
    const tools_val = root_obj.getPtr("tools") orelse return error.MalformedToolsList;
    if (tools_val.* != .array) return error.MalformedToolsList;

    if (!opts.bundle_enabled) {
        var filtered: std.json.Array = .init(a);
        for (tools_val.array.items) |t| {
            if (t == .object) {
                if (t.object.get("name")) |n| {
                    if (n == .string and std.mem.eql(u8, n.string, "codedb_bundle")) continue;
                }
            }
            try filtered.append(t);
        }
        tools_val.* = .{ .array = filtered };
    }

    const out_in_arena = try std.json.Stringify.valueAlloc(a, parsed.value, .{});
    return try alloc.dupe(u8, out_in_arena);
}

pub fn buildAugmentedToolsList(alloc: std.mem.Allocator) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var parsed = try std.json.parseFromSlice(std.json.Value, a, tools_list, .{});

    const root_obj = &parsed.value.object;
    const tools_val = root_obj.getPtr("tools") orelse return error.MalformedToolsList;
    if (tools_val.* != .array) return error.MalformedToolsList;
    const tools_arr = &tools_val.array;

    // Locate codedb_bundle items, and collect (name, inputSchema) for every
    // other tool to use as oneOf branches.
    var bundle_items_ptr: ?*std.json.Value = null;
    for (tools_arr.items) |*t| {
        if (t.* != .object) continue;
        const name_v = t.object.get("name") orelse continue;
        if (name_v != .string) continue;
        if (!std.mem.eql(u8, name_v.string, "codedb_bundle")) continue;

        const schema = t.object.getPtr("inputSchema") orelse continue;
        if (schema.* != .object) continue;
        const props = schema.object.getPtr("properties") orelse continue;
        if (props.* != .object) continue;
        const ops = props.object.getPtr("ops") orelse continue;
        if (ops.* != .object) continue;
        bundle_items_ptr = ops.object.getPtr("items") orelse continue;
        break;
    }
    if (bundle_items_ptr == null) return error.BundleNotFound;
    const bundle_items = bundle_items_ptr.?;
    if (bundle_items.* != .object) return error.MalformedToolsList;

    var one_of: std.json.Array = .init(a);

    for (tools_arr.items) |t| {
        if (t != .object) continue;
        const sub_name_v = t.object.get("name") orelse continue;
        if (sub_name_v != .string) continue;
        const sub_name = sub_name_v.string;
        if (std.mem.eql(u8, sub_name, "codedb_bundle")) continue;
        if (std.mem.eql(u8, sub_name, "codedb_edit")) continue;
        // issue #441: codedb_projects is dispatcher-rejected in bundle; don't advertise it.
        if (std.mem.eql(u8, sub_name, "codedb_projects")) continue;
        const sub_schema = t.object.get("inputSchema") orelse continue;

        var tool_const: std.json.ObjectMap = .{};
        try tool_const.put(a, "const", .{ .string = sub_name });

        var branch_props: std.json.ObjectMap = .{};
        try branch_props.put(a, "tool", .{ .object = tool_const });
        try branch_props.put(a, "arguments", sub_schema);

        var branch: std.json.ObjectMap = .{};
        try branch.put(a, "properties", .{ .object = branch_props });

        try one_of.append(.{ .object = branch });
    }

    try bundle_items.object.put(a, "oneOf", .{ .array = one_of });
    const augmented_in_arena = try std.json.Stringify.valueAlloc(a, parsed.value, .{});
    return try alloc.dupe(u8, augmented_in_arena);
}


// ── MCP Server ──────────────────────────────────────────────────────────────

/// Monotonic timestamp of last MCP request, used for activity accounting.
pub var last_activity: std.atomic.Value(i64) = std.atomic.Value(i64).init(0);

/// How often the watchdog checks whether the MCP client disconnected.
pub const dead_client_poll_ms: u64 = 1000;

pub var stdout_broken: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

// ── Serve-first scan state (issue #207) ─────────────────────────────────────
//
// MCP serves immediately on startup; the file walk + index build runs in a
// background thread. Tools that query the explorer during this window may see
// partial results, so we expose the current scan phase via codedb_status so
// callers can decide whether to retry or proceed with what's available.

pub const ScanState = enum(u8) {
    loading_snapshot = 0,
    walking = 1,
    indexing = 2,
    ready = 3,

    pub fn name(self: ScanState) []const u8 {
        return switch (self) {
            .loading_snapshot => "loading_snapshot",
            .walking => "walking",
            .indexing => "indexing",
            .ready => "ready",
        };
    }
};

var scan_state_atomic: std.atomic.Value(u8) = std.atomic.Value(u8).init(@intFromEnum(ScanState.ready));

pub fn setScanState(s: ScanState) void {
    scan_state_atomic.store(@intFromEnum(s), .release);
}

pub fn getScanState() ScanState {
    return @enumFromInt(scan_state_atomic.load(.acquire));
}

pub var scan_wait_timeout_ms: u64 = 2000;

fn waitForScanReady(timeout_ms: u64) void {
    if (getScanState() == .ready) return;
    const deadline = cio.milliTimestamp() + @as(i64, @intCast(timeout_ms));
    while (getScanState() != .ready) {
        if (cio.milliTimestamp() >= deadline) return;
        cio.sleepMs(25);
    }
}

// ── Session state for MCP protocol ──────────────────────────────────────────

const Session = struct {
    alloc: std.mem.Allocator,
    stdout: cio.File,
    next_id: i64 = 100,
    client_supports_roots: bool = false,
    client_roots_list_changed: bool = false,
    client_name: ?[]const u8 = null,
    pending_roots_id: ?i64 = null,
    roots: std.ArrayList(Root) = .empty,
    deferred_scan: ?*DeferredScan = null,
    /// Per-session advisory-lock owner for codedb_edit (#528 audit). Set to a
    /// distinct registered agent id at session start; defaults to 1 so any path
    /// that constructs a Session without registering still uses __filesystem__.
    edit_agent_id: u64 = 1,

    fn freeRoots(self: *Session) void {
        for (self.roots.items) |r| {
            self.alloc.free(r.uri);
            self.alloc.free(r.name);
        }
        self.roots.clearRetainingCapacity();
    }

    fn deinit(self: *Session) void {
        self.freeRoots();
        self.roots.deinit(self.alloc);
    }
};

pub fn run(
    io: std.Io,
    alloc: std.mem.Allocator,
    store: *Store,
    explorer: *Explorer,
    agents: *AgentRegistry,
    default_path: []const u8,
    content_cache_capacity: u32,
    telem: *telemetry_mod.Telemetry,
    deferred_scan: ?*DeferredScan,
    shutdown: *std.atomic.Value(bool),
) void {
    const stdout = cio.File.stdout();
    const stdin = std.Io.File.stdin();
    last_activity.store(cio.milliTimestamp(), .release);

    var cache = ProjectCache.init(alloc, default_path, content_cache_capacity);
    defer cache.deinit();
    // Seed the external-linter opt-in from the persisted preference. The server
    // never prompts/installs — that happens at install / `codedb update` time.
    cache.linter.enabled = linter_pref.enabledFromPref(linter_pref.read(io, alloc));

    // Build the `tools/list` payload. The discriminated `oneOf` on the
    // codedb_bundle ops items (issue #437) is incompatible with OpenAI's
    // strict-mode tool-schema validator, which rejects `oneOf` outright with
    // "'oneOf' is not permitted" — breaking codex/forgecode and any other
    // OpenAI-Responses-API-backed MCP client. Default to the raw schema (which
    // still has Stage 1's required: ["tool", "arguments"] from #434). Set
    // CODEDB_DISCRIMINATED_SCHEMA=1 to opt back into the augmented oneOf for
    // Anthropic-backed clients that benefit from it.
    //
    // Issue #443: even with all the above, OpenAI clients still emit empty
    // `arguments: {}` for bundle sub-ops because the schema can't bind
    // sub-tool argument shape without `oneOf`. Disable the bundle entirely
    // by default — the dispatcher handler stays so cached-schema clients
    // don't crash, but tools/list no longer advertises it. Set
    // CODEDB_BUNDLE_ENABLED=1 to re-advertise.
    const discriminated_opt_in = blk_opt: {
        const v = cio.posixGetenv("CODEDB_DISCRIMINATED_SCHEMA") orelse break :blk_opt false;
        break :blk_opt std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true");
    };
    const bundle_enabled = blk_be: {
        const v = cio.posixGetenv("CODEDB_BUNDLE_ENABLED") orelse break :blk_be false;
        break :blk_be std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true");
    };
    const tools_list_response: []const u8 = buildToolsListResponse(alloc, .{
        .bundle_enabled = bundle_enabled,
        .discriminated_opt_in = discriminated_opt_in,
    }) catch tools_list;
    defer if (tools_list_response.ptr != tools_list.ptr) alloc.free(tools_list_response);
    var session = Session{
        .alloc = alloc,
        .stdout = stdout,
        .deferred_scan = deferred_scan,
    };
    // #528 audit: give this MCP session a distinct advisory-lock owner so that
    // concurrent edits from separate connections (if a multi-connection MCP
    // transport is added) serialize correctly instead of all sharing the
    // startup __filesystem__ agent. Falls back to 1 (__filesystem__).
    session.edit_agent_id = agents.register("mcp-session") catch 1;
    defer session.deinit();

    var read_buf: [4096]u8 = undefined;
    var stdin_reader = stdin.reader(io, &read_buf);

    while (!stdout_broken.load(.acquire) and !shutdown.load(.acquire)) {
        const msg = mcpj.readLineBuf(alloc, &stdin_reader.interface) orelse break;
        last_activity.store(cio.milliTimestamp(), .release);
        defer alloc.free(msg);

        const input = std.mem.trim(u8, msg, " \t\r");
        if (input.len == 0) continue;

        const parsed = std.json.parseFromSlice(std.json.Value, alloc, input, .{}) catch {
            writeError(alloc, stdout, null, -32700, "Parse error");
            continue;
        };
        defer parsed.deinit();

        if (parsed.value != .object) {
            writeError(alloc, stdout, null, -32600, "Invalid Request");
            continue;
        }

        const root = &parsed.value.object;
        const method_opt = mcpj.getStr(root, "method");
        const has_id = root.contains("id");
        const id = root.get("id");
        const is_notification = !has_id;

        if (method_opt == null) {
            if (has_id) {
                handleResponse(&session, root);
            }
            continue;
        }
        const method = method_opt.?;

        if (mcpj.eql(method, "initialize")) {
            handleInitialize(&session, root, id);
        } else if (mcpj.eql(method, "notifications/initialized")) {
            if (session.client_supports_roots) {
                requestRoots(&session);
            } else if (session.deferred_scan) |ds| {
                // Client won't be sending workspace roots — fire the deferred
                // scan now with the cwd fallback so we don't sit in
                // loading_snapshot waiting for a roots/list reply that never
                // comes.
                const empty_roots: []const Root = &.{};
                _ = triggerDeferredScanWithFallback(ds, empty_roots, ds.fallback_cwd);
            }
        } else if (mcpj.eql(method, "notifications/roots/list_changed")) {
            if (session.client_supports_roots) {
                requestRoots(&session);
            }
        } else if (mcpj.eql(method, "tools/list")) {
            if (!is_notification) writeResult(alloc, stdout, id, tools_list_response);
        } else if (mcpj.eql(method, "tools/call")) {
            handleCall(io, alloc, root, stdout, id, store, explorer, agents, &cache, telem, session.deferred_scan, session.edit_agent_id);
        } else if (mcpj.eql(method, "ping")) {
            if (!is_notification) writeResult(alloc, stdout, id, "{}");
        } else {
            if (!is_notification) writeError(alloc, stdout, id, -32601, "Method not found");
        }
    }
}

fn handleInitialize(s: *Session, root: *const std.json.ObjectMap, id: ?std.json.Value) void {
    caps: {
        const p = root.get("params") orelse break :caps;
        if (p != .object) break :caps;
        const c = p.object.get("capabilities") orelse break :caps;
        if (c != .object) break :caps;
        const r = c.object.get("roots") orelse break :caps;
        if (r != .object) break :caps;
        s.client_supports_roots = true;
        s.client_roots_list_changed = mcpj.getBool(&r.object, "listChanged");
    }
    // Extract client identity for agent registration (#37)
    client_name: {
        const p = root.get("params") orelse break :client_name;
        if (p != .object) break :client_name;
        const ci = p.object.get("clientInfo") orelse break :client_name;
        if (ci != .object) break :client_name;
        if (mcpj.getStr(&ci.object, "name")) |name| {
            s.client_name = name;
        }
    }
    // #505 / #506: negotiate the protocol version with the client.
    // Old versions of opencode/Zed reject a server reply with a NEWER
    // protocolVersion than they sent. Echo the client's version back when
    // we recognize it; otherwise fall back to the latest we support.
    var negotiated: []const u8 = "2025-06-18";
    proto: {
        const p = root.get("params") orelse break :proto;
        if (p != .object) break :proto;
        const requested = mcpj.getStr(&p.object, "protocolVersion") orelse break :proto;
        if (negotiateProtocolVersion(requested)) |v| negotiated = v;
    }
    const init_result = std.fmt.allocPrint(s.alloc,
        \\{{"protocolVersion":"{s}","capabilities":{{"tools":{{"listChanged":false}}}},"serverInfo":{{"name":"codedb","version":"{s}"}},"instructions":"codedb is a code-intelligence and context tool — not your editor. Use it to understand the codebase before you change it: search, symbol/caller lookup, dependency graph, outlines, and codedb_context for task-shaped orientation. Make edits with your own native file tools. codedb_edit is only a fallback for clients with no native editing."}}
    , .{ negotiated, release_info.semver }) catch return;
    defer s.alloc.free(init_result);
    writeResult(s.alloc, s.stdout, id, init_result);
}

/// Versions of the MCP spec this server has been verified against. Listed
/// newest-first because clients that send a newer version than we know
/// should still get our newest known version back, not an old one.
const SUPPORTED_PROTOCOL_VERSIONS = [_][]const u8{
    "2025-06-18",
    "2025-03-26",
    "2024-11-05",
};

/// Pick the protocol version to send back in initialize. Returns the
/// client's requested version if we recognize it, the latest version we
/// know about if the request is newer than that, or null if the request
/// looks malformed and the caller should fall back to a default. See
/// #505 / #506 — older clients (Zed, certain opencode versions) reject
/// a server reply with a protocolVersion they don't understand.
pub fn negotiateProtocolVersion(requested: []const u8) ?[]const u8 {
    if (requested.len == 0) return null;
    for (SUPPORTED_PROTOCOL_VERSIONS) |v| {
        if (std.mem.eql(u8, v, requested)) return v;
    }
    // Unknown version. If it looks like a future date (lex-greater than our
    // latest), reply with our latest. Otherwise reply with our oldest known
    // version so older clients at least get a compatible-shaped response.
    if (std.mem.order(u8, requested, SUPPORTED_PROTOCOL_VERSIONS[0]) == .gt) {
        return SUPPORTED_PROTOCOL_VERSIONS[0];
    }
    return SUPPORTED_PROTOCOL_VERSIONS[SUPPORTED_PROTOCOL_VERSIONS.len - 1];
}

fn requestRoots(s: *Session) void {
    const rid = s.next_id;
    s.next_id += 1;
    s.pending_roots_id = rid;
    writeRequest(s.alloc, s.stdout, rid, "roots/list", "{}");
}

fn handleResponse(s: *Session, root: *const std.json.ObjectMap) void {
    const resp_id_val = root.get("id") orelse return;
    const resp_id: i64 = switch (resp_id_val) {
        .integer => |n| n,
        else => return,
    };
    if (s.pending_roots_id) |pid| {
        if (resp_id == pid) {
            s.pending_roots_id = null;
            if (root.get("error") != null) return;
            const result_val = root.get("result") orelse return;
            if (result_val != .object) return;
            parseRoots(s, &result_val.object);
        }
    }
}

fn parseRoots(s: *Session, result: *const std.json.ObjectMap) void {
    s.freeRoots();
    const roots_val = result.get("roots") orelse return;
    if (roots_val != .array) return;
    for (roots_val.array.items) |item| {
        if (item != .object) continue;
        const obj = item.object;
        const uri_raw = mcpj.getStr(&obj, "uri") orelse continue;
        const name_raw = mcpj.getStr(&obj, "name") orelse "";
        // Strip file:// prefix for policy check
        const path = if (std.mem.startsWith(u8, uri_raw, "file://")) uri_raw[7..] else uri_raw;
        if (!root_policy.isIndexableRoot(path)) {
            std.log.info("codedb mcp: rejected root \"{s}\" (denied by policy)", .{uri_raw});
            continue;
        }
        const uri = s.alloc.dupe(u8, uri_raw) catch continue;
        const name = s.alloc.dupe(u8, name_raw) catch {
            s.alloc.free(uri);
            continue;
        };
        s.roots.append(s.alloc, .{ .uri = uri, .name = name }) catch {
            s.alloc.free(uri);
            s.alloc.free(name);
            continue;
        };
    }
    if (s.deferred_scan) |ds| {
        _ = triggerDeferredScanWithFallback(ds, s.roots.items, ds.fallback_cwd);
    }
}

fn writeRequest(alloc: std.mem.Allocator, stdout: cio.File, id: i64, method: []const u8, params: []const u8) void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    buf.appendSlice(alloc, "{\"jsonrpc\":\"2.0\",\"id\":") catch return;
    var tmp: [32]u8 = undefined;
    const id_str = std.fmt.bufPrint(&tmp, "{d}", .{id}) catch return;
    buf.appendSlice(alloc, id_str) catch return;
    buf.appendSlice(alloc, ",\"method\":\"") catch return;
    buf.appendSlice(alloc, method) catch return;
    buf.appendSlice(alloc, "\",\"params\":") catch return;
    buf.appendSlice(alloc, params) catch return;
    buf.appendSlice(alloc, "}\n") catch return;
    stdout.writeAll(buf.items) catch {
        stdout_broken.store(true, .release);
        return;
    };
}

fn handleCall(
    io: std.Io,
    alloc: std.mem.Allocator,
    root: *const std.json.ObjectMap,
    stdout: cio.File,
    id: ?std.json.Value,
    store: *Store,
    explorer: *Explorer,
    agents: *AgentRegistry,
    cache: *ProjectCache,
    telem: *telemetry_mod.Telemetry,
    deferred_scan: ?*DeferredScan,
    edit_agent_id: u64,
) void {
    const is_notification = id == null;

    const params_val = root.get("params") orelse {
        if (!is_notification) writeError(alloc, stdout, id, -32602, "Missing params");
        return;
    };
    if (params_val != .object) {
        if (!is_notification) writeError(alloc, stdout, id, -32602, "params must be object");
        return;
    }
    const params = &params_val.object;

    const name = getStr(params, "name") orelse {
        if (!is_notification) writeError(alloc, stdout, id, -32602, "Missing tool name");
        return;
    };
    var args_value: std.json.Value = .{ .object = .empty };
    var inline_args: std.json.ObjectMap = .empty;
    defer inline_args.deinit(alloc);
    const args = selectDirectCallArgs(alloc, params, &args_value, &inline_args) catch |err| {
        if (!is_notification) writeError(alloc, stdout, id, -32602, switch (err) {
            error.ArgumentsMustBeObject => "arguments must be object",
            error.ArgsMustBeObject => "args must be object",
            error.OutOfMemory => "out of memory",
        });
        return;
    };

    const tool = std.meta.stringToEnum(Tool, name) orelse {
        if (!is_notification) writeError(alloc, stdout, id, -32602, "Unknown tool");
        return;
    };

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    const t0 = cio.nanoTimestamp();
    dispatch(io, alloc, tool, args, &out, store, explorer, agents, cache, deferred_scan, edit_agent_id);
    const elapsed = cio.nanoTimestamp() - t0;

    const is_error = std.mem.startsWith(u8, out.items, "error:");
    telem.recordToolCall(name, elapsed, is_error, out.items.len);

    if (std.mem.eql(u8, name, "codedb_search") or std.mem.eql(u8, name, "codedb_find") or std.mem.eql(u8, name, "codedb_word")) {
        telem.recordSearchBreakdown(explorer.last_search_breakdown);
    }

    // Query + file access tracking WAL
    if (!is_error) {
        if (std.mem.eql(u8, name, "codedb_search") or std.mem.eql(u8, name, "codedb_find") or std.mem.eql(u8, name, "codedb_word")) {
            if (getStr(args, "query") orelse getStr(args, "word")) |q| {
                logQuery(io, name, q, out.items.len, elapsed);
            }
        } else if (std.mem.eql(u8, name, "codedb_read") or std.mem.eql(u8, name, "codedb_outline")) {
            if (getStr(args, "path")) |p| {
                logFileAccess(io, name, p, elapsed);
            }
        }
    }
    if (is_notification) return;

    const lean = mcpLeanMode();

    // Block 1: Human-readable colored summary (ANSI — preview pane always
    // renders it). Skipped in lean mode (agents don't render ANSI; the
    // summary duplicates info that's already in Block 2).
    var summary: std.ArrayList(u8) = .empty;
    defer summary.deinit(alloc);
    if (!lean) {
        summary.ensureTotalCapacity(alloc, 256) catch {};
        summary.appendSlice(alloc, if (is_error) MCP_RED ++ MCP_CROSS ++ " " ++ MCP_RESET else MCP_GREEN ++ MCP_CHECK ++ " " ++ MCP_RESET) catch {};
        summary.appendSlice(alloc, mcpToolIcon(name)) catch {};
        mcpGenerateSummary(alloc, name, args, out.items, is_error, &summary);
        var dur_buf: [96]u8 = undefined;
        summary.appendSlice(alloc, mcpFormatDuration(&dur_buf, elapsed)) catch {};
    }

    // Block 3: Guidance hints. Skipped in lean mode for same reason.
    var guidance: std.ArrayList(u8) = .empty;
    defer guidance.deinit(alloc);
    if (!lean) {
        mcpGenerateGuidance(alloc, name, args, out.items, is_error, &guidance);
    }

    // Assemble MCP content envelope (1 block in lean mode, up to 3 otherwise).
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(alloc);
    result.ensureTotalCapacity(alloc, out.items.len + summary.items.len + guidance.items.len + 256) catch {};
    result.appendSlice(alloc, "{\"content\":[") catch return;

    // Block 1 (summary — audience: user; spec-canonical signal that
    // token-conscious clients can strip)
    if (summary.items.len > 0) {
        result.appendSlice(alloc, "{\"type\":\"text\",\"annotations\":{\"audience\":[\"user\"]},\"text\":\"") catch return;
        mcpj.writeEscaped(alloc, &result, summary.items);
        result.appendSlice(alloc, "\"},") catch return;
    }

    // Block 2 (raw data — audience: assistant; this is what the model
    // actually consumes)
    result.appendSlice(alloc, "{\"type\":\"text\",\"annotations\":{\"audience\":[\"assistant\"]},\"text\":\"") catch return;
    mcpj.writeEscaped(alloc, &result, out.items);
    result.appendSlice(alloc, "\"}") catch return;

    // Block 3 (guidance — audience: user)
    if (guidance.items.len > 0) {
        result.appendSlice(alloc, ",{\"type\":\"text\",\"annotations\":{\"audience\":[\"user\"]},\"text\":\"") catch return;
        mcpj.writeEscaped(alloc, &result, guidance.items);
        result.appendSlice(alloc, "\"}") catch return;
    }

    result.appendSlice(alloc, if (is_error) "],\"isError\":true}" else "],\"isError\":false}") catch return;
    writeResult(alloc, stdout, id, result.items);
}

fn isDirectCallAdminKey(key: []const u8) bool {
    return std.mem.eql(u8, key, "name") or
        std.mem.eql(u8, key, "arguments") or
        std.mem.eql(u8, key, "args") or
        std.mem.eql(u8, key, "_meta") or
        std.mem.eql(u8, key, "task");
}

fn copyDirectInlineArgs(
    alloc: std.mem.Allocator,
    params: *const std.json.ObjectMap,
    inline_args: *std.json.ObjectMap,
) !bool {
    var copied = false;
    var it = params.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (isDirectCallAdminKey(key)) continue;
        try inline_args.put(alloc, key, entry.value_ptr.*);
        copied = true;
    }
    return copied;
}

fn selectDirectCallArgs(
    alloc: std.mem.Allocator,
    params: *const std.json.ObjectMap,
    args_value: *std.json.Value,
    inline_args: *std.json.ObjectMap,
) (error{ ArgumentsMustBeObject, ArgsMustBeObject } || std.mem.Allocator.Error)!*const std.json.ObjectMap {
    if (params.get("arguments")) |arguments_val| {
        if (arguments_val != .object) return error.ArgumentsMustBeObject;
        if (arguments_val.object.count() > 0) {
            args_value.* = arguments_val;
            return &args_value.object;
        }
        if (try copyDirectInlineArgs(alloc, params, inline_args)) return inline_args;
    } else {
        if (try copyDirectInlineArgs(alloc, params, inline_args)) return inline_args;
    }

    if (params.get("args")) |args_val| {
        if (args_val != .object) return error.ArgsMustBeObject;
        args_value.* = args_val;
        return &args_value.object;
    }

    args_value.* = .{ .object = .empty };
    return &args_value.object;
}

fn dispatch(
    io: std.Io,
    alloc: std.mem.Allocator,
    tool: Tool,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
    default_store: *Store,
    default_explorer: *Explorer,
    agents: *AgentRegistry,
    cache: *ProjectCache,
    deferred_scan: ?*DeferredScan,
    edit_agent_id: u64,
) void {
    const project_path = getStr(args, "project");
    const ctx = if (project_path) |path|
        cache.get(io, path, default_explorer, default_store) catch |err| {
            out.appendSlice(alloc, "error: failed to load project: ") catch {};
            out.appendSlice(alloc, @errorName(err)) catch {};
            return;
        }
    else
        ProjectCtx{
            .explorer = default_explorer,
            .store = default_store,
            .snapshot_cache = &cache.default_snapshot_cache,
            .deps_cache = &cache.default_deps_cache,
        };

    if (project_path == null and tool == .codedb_deps and args.count() == 1) {
        const keys = args.keys();
        const values = args.values();
        if (keys.len == 1 and std.mem.eql(u8, keys[0], "path") and values[0] == .string) {
            waitForScanReady(scan_wait_timeout_ms);
            const scan_ready = getScanState() == .ready;
            const seq = if (scan_ready) default_store.currentSeq() else 0;
            if (scan_ready and ctx.deps_cache.appendIfFresh(out, seq, values[0].string)) return;

            handleDepsPathOnly(alloc, values[0].string, out, default_explorer);
            if (scan_ready) {
                ctx.deps_cache.put(alloc, seq, values[0].string, out.items);
            } else {
                appendScanProgressHint(alloc, out, tool);
            }
            return;
        }
    }

    if (toolDependsOnScannedIndex(tool) and project_path == null) {
        waitForScanReady(scan_wait_timeout_ms);
    }

    if (tool == .codedb_word or tool == .codedb_context or (tool == .codedb_search and shouldLoadWordIndexForSearch(args))) {
        const effective_project = project_path orelse cache.default_path;
        loadProjectWordIndexFromDiskIfPresent(io, ctx.explorer, effective_project, alloc);
    }

    switch (tool) {
        .codedb_tree => handleTree(alloc, out, ctx.explorer),
        .codedb_outline => handleOutline(alloc, args, out, ctx.explorer),
        .codedb_symbol => handleSymbol(alloc, args, out, ctx.explorer),
        .codedb_search => handleSearch(alloc, args, out, ctx.explorer),
        .codedb_word => handleWord(alloc, args, out, ctx.explorer),
        .codedb_callers => handleCallers(alloc, args, out, ctx.explorer),
        .codedb_callpath => handleCallpath(alloc, args, out, ctx.explorer),
        .codedb_hot => handleHot(alloc, args, out, ctx.store, ctx.explorer),
        .codedb_deps => handleDeps(alloc, args, out, ctx.explorer),
        .codedb_read => handleRead(io, alloc, args, out, ctx.explorer),
        .codedb_edit => handleEdit(io, alloc, args, out, default_store, default_explorer, agents, cache, edit_agent_id),
        .codedb_changes => handleChanges(alloc, args, out, default_store),
        .codedb_status => handleStatus(alloc, out, ctx.store, ctx.explorer),
        .codedb_snapshot => handleSnapshot(alloc, out, ctx.explorer, ctx.store, ctx.snapshot_cache),
        .codedb_bundle => handleBundle(io, alloc, args, out, ctx.store, ctx.explorer, agents, cache, deferred_scan, edit_agent_id),
        .codedb_remote => handleRemote(alloc, args, out),
        .codedb_projects => handleProjects(io, alloc, out),
        .codedb_index => handleIndex(io, alloc, args, out, cache, default_store, default_explorer, deferred_scan),
        .codedb_find => handleFind(io, alloc, args, out, ctx.explorer),
        .codedb_query => handleQuery(alloc, args, out, ctx.explorer, ctx.store),
        .codedb_glob => handleGlob(alloc, args, out, ctx.explorer),
        .codedb_ls => handleLs(alloc, args, out, ctx.explorer),
        .codedb_context => handleContext(io, alloc, args, out, ctx.explorer, project_path orelse cache.default_path),
        .codedb_diagnostics => handleDiagnostics(alloc, args, out, cache),
    }
    appendScanProgressHint(alloc, out, tool);
}

/// Bug 2: when the initial scan is still running, search/outline/word
/// responses come back as "0 results" or "file not indexed" — agents read
/// these as authoritative. Append a one-line note so the caller knows the
/// result might be incomplete and that retrying is reasonable.
fn appendScanProgressHint(alloc: std.mem.Allocator, out: *std.ArrayList(u8), tool: Tool) void {
    const state = getScanState();
    if (state == .ready) return;
    if (!toolDependsOnScannedIndex(tool)) return;
    const looks_empty =
        std.mem.indexOf(u8, out.items, "0 results for ") != null or
        std.mem.indexOf(u8, out.items, "0 hits for ") != null or
        std.mem.indexOf(u8, out.items, "no results for: ") != null;
    const looks_unindexed = std.mem.indexOf(u8, out.items, "file not indexed") != null;
    if (!(looks_empty or looks_unindexed)) return;
    out.appendSlice(alloc, "\nnote: scan still in progress (state=") catch return;
    out.appendSlice(alloc, state.name()) catch return;
    out.appendSlice(alloc, "); results may be incomplete — retry shortly") catch return;
}

fn toolDependsOnScannedIndex(tool: Tool) bool {
    return switch (tool) {
        .codedb_search, .codedb_word, .codedb_callers, .codedb_callpath, .codedb_outline, .codedb_symbol, .codedb_find, .codedb_glob, .codedb_tree, .codedb_ls, .codedb_deps => true,
        else => false,
    };
}

// ── Tool handlers ───────────────────────────────────────────────────────────

fn handleTree(alloc: std.mem.Allocator, out: *std.ArrayList(u8), explorer: *Explorer) void {
    explorer.renderTree(alloc, out, false) catch {
        out.appendSlice(alloc, "error: failed to get tree") catch {};
    };
}

fn handleOutline(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8), explorer: *Explorer) void {
    const path = getStr(args, "path") orelse {
        out.appendSlice(alloc, "error: missing 'path' argument") catch {};
        appendBundleArgKeysDiagnostic(alloc, out, args);
        return;
    };
    const compact = getBool(args, "compact");
    const skeleton = getBool(args, "skeleton");
    const found = if (skeleton)
        explorer.renderSkeleton(path, alloc, out) catch {
            out.appendSlice(alloc, "error: outline retrieval failed") catch {};
            return;
        }
    else
        explorer.renderOutline(path, alloc, out, compact) catch {
            out.appendSlice(alloc, "error: outline retrieval failed") catch {};
            return;
        };
    if (!found) {
        out.appendSlice(alloc, "error: file not indexed: ") catch {};
        out.appendSlice(alloc, path) catch {};
        appendFuzzyPathSuggestions(alloc, out, explorer, path);
        out.appendSlice(alloc, "\nhint: try codedb_index if the file was added recently\n") catch {};
        return;
    }
}

fn handleSymbol(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8), explorer: *Explorer) void {
    const name = getStr(args, "name");
    const prefix = getStr(args, "prefix");
    const pattern = getStr(args, "pattern");
    const kind_str = getStr(args, "kind");
    const fuzzy = getBool(args, "fuzzy");
    const include_body = getBool(args, "body");
    const json_fmt = wantsJsonFormat(args);

    if (name == null and prefix == null and pattern == null and kind_str == null) {
        if (json_fmt) {
            writeJsonToolError(out, alloc, "codedb_symbol", "missing_query", "need name, prefix, pattern, or kind");
        } else {
            out.appendSlice(alloc, "error: need name, prefix, pattern, or kind") catch {};
        }
        appendBundleArgKeysDiagnostic(alloc, out, args);
        return;
    }

    const kind = if (kind_str) |k| Explorer.parseSymbolKind(k) else null;
    if (kind_str != null and kind == null) {
        if (json_fmt) {
            writeJsonToolError(out, alloc, "codedb_symbol", "invalid_kind", "unknown symbol kind");
        } else {
            out.appendSlice(alloc, "error: unknown symbol kind") catch {};
        }
        return;
    }

    const max_results: usize = if (getInt(args, "max_results")) |n| @intCast(@max(1, @min(n, 200))) else 50;
    const spec = Explorer.SymbolSearchSpec{
        .name = name,
        .prefix = prefix,
        .pattern = pattern,
        .kind = kind,
        .fuzzy = fuzzy,
        .max_results = max_results,
    };

    const results = explorer.searchSymbols(spec, alloc) catch {
        if (json_fmt) {
            writeJsonToolError(out, alloc, "codedb_symbol", "search_failed", "symbol search failed");
        } else {
            out.appendSlice(alloc, "error: search failed") catch {};
        }
        return;
    };
    defer {
        for (results) |r| {
            alloc.free(r.path);
            alloc.free(r.symbol.name);
            if (r.symbol.detail) |d| alloc.free(d);
        }
        alloc.free(results);
    }

    if (json_fmt) {
        out.appendSlice(alloc, "{\"ok\":true,\"tool\":\"codedb_symbol\",\"count\":") catch {};
        var cnt_buf: [16]u8 = undefined;
        const cnt_s = std.fmt.bufPrint(&cnt_buf, "{d}", .{results.len}) catch "0";
        out.appendSlice(alloc, cnt_s) catch {};
        out.appendSlice(alloc, ",\"match_mode\":") catch {};
        appendJsonStr(out, alloc, symbolMatchModeLabel(spec));
        out.appendSlice(alloc, ",\"meta\":{\"index\":\"symbol_index+outline\",\"match_mode\":") catch {};
        appendJsonStr(out, alloc, symbolMatchModeLabel(spec));
        out.append(alloc, '}') catch {};
        out.appendSlice(alloc, ",\"results\":[") catch {};
        for (results, 0..) |r, i| {
            if (i > 0) out.append(alloc, ',') catch {};
            out.appendSlice(alloc, "{\"path\":") catch {};
            appendJsonStr(out, alloc, r.path);
            out.appendSlice(alloc, ",\"line\":") catch {};
            var line_buf: [16]u8 = undefined;
            const line_s = std.fmt.bufPrint(&line_buf, "{d}", .{r.symbol.line_start}) catch "0";
            out.appendSlice(alloc, line_s) catch {};
            out.appendSlice(alloc, ",\"kind\":") catch {};
            appendJsonStr(out, alloc, @tagName(r.symbol.kind));
            out.appendSlice(alloc, ",\"name\":") catch {};
            appendJsonStr(out, alloc, r.symbol.name);
            out.appendSlice(alloc, ",\"score\":") catch {};
            var score_buf: [32]u8 = undefined;
            const score_s = std.fmt.bufPrint(&score_buf, "{d}", .{@as(f64, r.score)}) catch "0";
            out.appendSlice(alloc, score_s) catch {};
            out.appendSlice(alloc, ",\"confidence\":\"indexed\"}") catch {};
        }
        out.appendSlice(alloc, "]}") catch {};
        return;
    }

    if (results.len == 0) {
        out.appendSlice(alloc, "no results") catch {};
        if (name) |n| {
            out.appendSlice(alloc, " for: ") catch {};
            out.appendSlice(alloc, n) catch {};
        }
        return;
    }

    const w = cio.listWriter(out, alloc);
    if (name) |n| {
        w.print("{d} results for '{s}':\n", .{ results.len, n }) catch {};
    } else {
        w.print("{d} symbol results:\n", .{results.len}) catch {};
    }
    for (results) |r| {
        w.print("  {s}:{d} ({s}) {s}", .{ r.path, r.symbol.line_start, @tagName(r.symbol.kind), r.symbol.name }) catch {};
        if (r.symbol.detail) |d| w.print("  // {s}", .{d}) catch {};
        w.writeAll("\n") catch {};
        if (include_body) {
            const body = explorer.getSymbolBody(r.path, r.symbol.line_start, r.symbol.line_end, alloc) catch null;
            if (body) |b| {
                defer alloc.free(b);
                out.appendSlice(alloc, b) catch {};
            }
        }
    }
}

fn handleSearch(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8), explorer: *Explorer) void {
    const query = getStr(args, "query") orelse {
        out.appendSlice(alloc, "error: missing 'query' argument") catch {};
        appendBundleArgKeysDiagnostic(alloc, out, args);
        return;
    };
    // Bug 7: validate args explicitly. Pre-fix: empty query / non-positive
    // max_results all returned "0 results" and the agent thought the search
    // ran with nothing matching, when really the call was malformed.
    if (query.len == 0) {
        out.appendSlice(alloc, "error: empty query — pass a non-empty 'query' string") catch {};
        return;
    }
    if (getInt(args, "max_results")) |n| {
        if (n <= 0) {
            const w_err = cio.listWriter(out, alloc);
            w_err.print("error: max_results ({d}) must be >= 1", .{n}) catch {};
            return;
        }
    }
    // Default trimmed from 50 -> 20 (Nov 2026). Bench data showed the
    // median answer needed <10 results; the extra 40 were paid in tokens
    // every call. Agents that want more can pass max_results explicitly.
    const max_results: usize = if (getInt(args, "max_results")) |n| @intCast(@max(1, @min(n, 10000))) else 20;
    const offset_n: usize = if (getInt(args, "offset")) |n| @intCast(@max(0, @min(n, 100000))) else 0;
    const scope = getBool(args, "scope");
    const compact = getBool(args, "compact");
    const paths_only = getBool(args, "paths_only");
    const is_regex = getBool(args, "regex");
    const path_glob_raw = getStr(args, "path_glob");
    // Auto-promote basename-only patterns ('*.zig') to '**/*.zig' so they match
    // nested files. Without this the matcher rejects 'src/main.zig' because
    // '*' doesn't cross '/' (see explore.zig:matchGlob). Issue surfaced by the
    // recall eval — agents reach for '*.zig' first.
    var pg_buf: [256]u8 = undefined;
    const path_glob: ?[]const u8 = if (path_glob_raw) |g| blk: {
        if (std.mem.indexOfScalar(u8, g, '/') == null and g.len + 3 < pg_buf.len) {
            const promoted = std.fmt.bufPrint(&pg_buf, "**/{s}", .{g}) catch break :blk g;
            break :blk promoted;
        }
        break :blk g;
    } else null;

    const json_fmt = wantsJsonFormat(args);
    if (json_fmt and scope) {
        writeJsonToolError(out, alloc, "codedb_search", "unsupported", "format=json does not support scope=true yet");
        return;
    }
    if (scope and is_regex) {
        const results = explorer.searchContentRegexWithScope(query, alloc, max_results) catch |e| {
            out.appendSlice(alloc, if (e == error.InvalidRegex) "error: invalid regex" else "error: scoped regex search failed") catch {};
            return;
        };
        defer {
            for (results) |r| {
                alloc.free(r.line_text);
                alloc.free(r.path);
                if (r.scope_name) |n| alloc.free(n);
            }
            alloc.free(results);
        }

        // Issue #422: count post-filter results so the header reflects what
        // the user actually sees, not the pre-filter explorer count.
        var visible_total: usize = 0;
        for (results) |r| {
            if (path_glob) |g| if (!globMatch(g, r.path)) continue;
            if (compact and explore_mod.isCommentOrBlank(r.line_text, explore_mod.detectLanguage(r.path))) continue;
            visible_total += 1;
        }

        const w = cio.listWriter(out, alloc);
        w.print("{d} results for '{s}':\n", .{ visible_total, query }) catch {};
        for (results) |r| {
            if (path_glob) |g| if (!globMatch(g, r.path)) continue;
            if (compact and explore_mod.isCommentOrBlank(r.line_text, explore_mod.detectLanguage(r.path))) continue;
            if (paths_only) {
                w.print("  {s}:{d}\n", .{ r.path, r.line_num }) catch {};
            } else if (r.scope_name) |sn| {
                w.print("  {s}:{d}: {s}  [in {s} ({s}, L{d}-L{d})]\n", .{
                    r.path, r.line_num, r.line_text, sn, @tagName(r.scope_kind.?), r.scope_start, r.scope_end,
                }) catch {};
            } else {
                if (paths_only) {
                    w.print("  {s}:{d}\n", .{ r.path, r.line_num }) catch {};
                } else {
                    w.print("  {s}:{d}: {s}\n", .{ r.path, r.line_num, r.line_text }) catch {};
                }
            }
        }
    } else if (scope) {
        const results = explorer.searchContentWithScope(query, alloc, max_results) catch {
            out.appendSlice(alloc, "error: search failed") catch {};
            return;
        };
        defer {
            for (results) |r| {
                alloc.free(r.line_text);
                alloc.free(r.path);
                if (r.scope_name) |n| alloc.free(n);
            }
            alloc.free(results);
        }

        // Issue #422: count post-filter results so the header reflects what
        // the user actually sees, and so the "truncated" footer only fires
        // for per-file-cap truncation — not for glob/compact filtering.
        var visible_total: usize = 0;
        for (results) |r| {
            if (path_glob) |g| if (!globMatch(g, r.path)) continue;
            if (compact and explore_mod.isCommentOrBlank(r.line_text, explore_mod.detectLanguage(r.path))) continue;
            visible_total += 1;
        }

        const w = cio.listWriter(out, alloc);
        w.print("{d} results for '{s}':\n", .{ visible_total, query }) catch {};
        var file_counts = std.StringHashMap(u8).init(alloc);
        defer file_counts.deinit();
        const max_per_file: u8 = 5;
        var shown: usize = 0;
        for (results) |r| {
            if (path_glob) |g| if (!globMatch(g, r.path)) continue;
            if (compact and explore_mod.isCommentOrBlank(r.line_text, explore_mod.detectLanguage(r.path))) continue;
            const gop = file_counts.getOrPut(r.path) catch continue;
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
            if (gop.value_ptr.* > max_per_file) {
                if (gop.value_ptr.* == max_per_file + 1) {
                    w.print("  {s} ... (more matches truncated)\n", .{r.path}) catch {};
                }
                continue;
            }
            if (paths_only) {
                w.print("  {s}:{d}\n", .{ r.path, r.line_num }) catch {};
            } else if (r.scope_name) |sn| {
                w.print("  {s}:{d}: {s}  [in {s} ({s}, L{d}-L{d})]\n", .{
                    r.path, r.line_num, r.line_text, sn, @tagName(r.scope_kind.?), r.scope_start, r.scope_end,
                }) catch {};
            } else {
                if (paths_only) {
                    w.print("  {s}:{d}\n", .{ r.path, r.line_num }) catch {};
                } else {
                    w.print("  {s}:{d}: {s}\n", .{ r.path, r.line_num, r.line_text }) catch {};
                }
            }
            shown += 1;
        }
        if (shown < visible_total) {
            w.print("({d} shown, {d} truncated by per-file cap)\n", .{ shown, visible_total - shown }) catch {};
        }
    } else if (is_regex) {
        const results = explorer.searchContentRegex(query, alloc, max_results) catch |e| {
            out.appendSlice(alloc, if (e == error.InvalidRegex) "error: invalid regex" else "error: regex search failed") catch {};
            return;
        };
        defer {
            for (results) |r| {
                alloc.free(r.line_text);
                alloc.free(r.path);
            }
            alloc.free(results);
        }

        // Issue #422: header reflects post-filter count; "truncated" footer
        // only fires for per-file-cap, not for glob/compact filtering.
        var visible_total: usize = 0;
        for (results) |r| {
            if (path_glob) |g| if (!globMatch(g, r.path)) continue;
            if (compact and explore_mod.isCommentOrBlank(r.line_text, explore_mod.detectLanguage(r.path))) continue;
            visible_total += 1;
        }
        if (json_fmt) {
            writeSearchResultsJson(out, alloc, explorer, query, results, 0, false, paths_only, path_glob, compact);
            return;
        }

        const w = cio.listWriter(out, alloc);
        w.print("{d} results for '{s}':\n", .{ visible_total, query }) catch {};
        var file_counts = std.StringHashMap(u8).init(alloc);
        defer file_counts.deinit();
        const max_per_file: u8 = 5;
        var shown: usize = 0;
        for (results) |r| {
            if (path_glob) |g| if (!globMatch(g, r.path)) continue;
            if (compact and explore_mod.isCommentOrBlank(r.line_text, explore_mod.detectLanguage(r.path))) continue;
            const gop = file_counts.getOrPut(r.path) catch continue;
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
            if (gop.value_ptr.* > max_per_file) {
                if (gop.value_ptr.* == max_per_file + 1) {
                    w.print("  {s}: ... (more matches truncated)\n", .{r.path}) catch {};
                }
                continue;
            }
            if (paths_only) {
                w.print("  {s}:{d}\n", .{ r.path, r.line_num }) catch {};
            } else {
                w.print("  {s}:{d}: {s}\n", .{ r.path, r.line_num, r.line_text }) catch {};
            }
            shown += 1;
        }
        if (shown < visible_total) {
            w.print("({d} shown, {d} truncated by per-file cap)\n", .{ shown, visible_total - shown }) catch {};
        }
    } else {
        if (path_glob == null and !compact) {
            const rendered = explorer.renderPlainSearch(query, alloc, out, max_results, paths_only) catch {
                out.appendSlice(alloc, "error: search failed") catch {};
                return;
            };
            if (rendered) return;
        }

        // Multi-word queries express natural-language / conceptual intent —
        // rank them by BM25 (relevance) instead of raw substring order, which
        // returns nothing for a phrase. Single-token queries keep literal
        // substring matching so exact-identifier lookups still work.
        const multiword = std.mem.indexOfScalar(u8, query, ' ') != null;
        // Over-fetch by `offset` (+1) so we can page into a stable window and
        // detect whether more results exist beyond this page. BM25 ranking is
        // deterministic per query, so the offset is a stable, stateless cursor.
        const fetch_count = @min(offset_n + max_results + 1, 100000);
        const fetched = (if (multiword)
            explorer.searchContentRanked(query, alloc, fetch_count)
        else
            explorer.searchContent(query, alloc, fetch_count)) catch {
            out.appendSlice(alloc, "error: search failed") catch {};
            return;
        };
        defer {
            for (fetched) |r| {
                alloc.free(r.line_text);
                alloc.free(r.path);
            }
            alloc.free(fetched);
        }
        const page_lo = @min(offset_n, fetched.len);
        const page_hi = @min(offset_n + max_results, fetched.len);
        const results = fetched[page_lo..page_hi];
        const has_more = fetched.len > page_hi;
        if (json_fmt) {
            writeSearchResultsJson(out, alloc, explorer, query, results, page_lo, has_more, paths_only, path_glob, compact);
            return;
        }

        // Issue #422: header reflects post-filter count; "truncated" footer
        // only fires for per-file-cap, not for glob/compact filtering.
        const simple_unfiltered = path_glob == null and !compact;
        var visible_total: usize = if (simple_unfiltered) results.len else 0;
        if (!simple_unfiltered) {
            for (results) |r| {
                if (path_glob) |g| if (!globMatch(g, r.path)) continue;
                if (compact and explore_mod.isCommentOrBlank(r.line_text, explore_mod.detectLanguage(r.path))) continue;
                visible_total += 1;
            }
        }

        out.ensureUnusedCapacity(alloc, 2048) catch {};
        const w = cio.listWriter(out, alloc);
        w.print("{d} results for '{s}':\n", .{ visible_total, query }) catch {};
        if (has_more) {
            w.print("  (more results — codedb_search query='{s}' offset={d} for the next page)\n", .{ query, page_hi }) catch {};
        }
        if (simple_unfiltered and results.len <= 64) {
            const CountEntry = struct { path: []const u8, count: u8 };
            var counts: [64]CountEntry = undefined;
            var counts_len: usize = 0;
            const max_per_file: u8 = 5;
            var shown: usize = 0;
            for (results) |r| {
                var idx_opt: ?usize = null;
                for (counts[0..counts_len], 0..) |entry, idx_i| {
                    if (std.mem.eql(u8, entry.path, r.path)) {
                        idx_opt = idx_i;
                        break;
                    }
                }
                const count_idx = idx_opt orelse blk: {
                    counts[counts_len] = .{ .path = r.path, .count = 0 };
                    counts_len += 1;
                    break :blk counts_len - 1;
                };
                counts[count_idx].count += 1;
                if (counts[count_idx].count > max_per_file) {
                    if (counts[count_idx].count == max_per_file + 1) {
                        w.print("  {s}: ... (more matches truncated)\n", .{r.path}) catch {};
                    }
                    continue;
                }
                if (paths_only) {
                    w.print("  {s}:{d}\n", .{ r.path, r.line_num }) catch {};
                } else {
                    w.print("  {s}:{d}: {s}\n", .{ r.path, r.line_num, r.line_text }) catch {};
                }
                shown += 1;
            }
            if (shown < visible_total) {
                w.print("({d} shown, {d} truncated by per-file cap)\n", .{ shown, visible_total - shown }) catch {};
            }
            return;
        }
        var file_counts = std.StringHashMap(u8).init(alloc);
        defer file_counts.deinit();
        const max_per_file: u8 = 5;
        var shown: usize = 0;
        for (results) |r| {
            if (path_glob) |g| if (!globMatch(g, r.path)) continue;
            if (compact and explore_mod.isCommentOrBlank(r.line_text, explore_mod.detectLanguage(r.path))) continue;
            const gop = file_counts.getOrPut(r.path) catch continue;
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
            if (gop.value_ptr.* > max_per_file) {
                if (gop.value_ptr.* == max_per_file + 1) {
                    w.print("  {s}: ... (more matches truncated)\n", .{r.path}) catch {};
                }
                continue;
            }
            if (paths_only) {
                w.print("  {s}:{d}\n", .{ r.path, r.line_num }) catch {};
            } else {
                w.print("  {s}:{d}: {s}\n", .{ r.path, r.line_num, r.line_text }) catch {};
            }
            shown += 1;
        }
        if (shown < visible_total) {
            w.print("({d} shown, {d} truncated by per-file cap)\n", .{ shown, visible_total - shown }) catch {};
        }
    }
}

fn handleWord(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8), explorer: *Explorer) void {
    const word = getStr(args, "word") orelse {
        out.appendSlice(alloc, "error: missing 'word' argument") catch {};
        appendBundleArgKeysDiagnostic(alloc, out, args);
        return;
    };
    explorer.renderWord(word, alloc, out) catch {
        out.appendSlice(alloc, "error: word search failed") catch {};
        return;
    };
}

fn handleCallers(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8), explorer: *Explorer) void {
    const name = getStr(args, "name") orelse {
        out.appendSlice(alloc, "error: missing 'name' argument") catch {};
        appendBundleArgKeysDiagnostic(alloc, out, args);
        return;
    };
    if (name.len == 0) {
        out.appendSlice(alloc, "error: empty name — pass a non-empty 'name' string") catch {};
        return;
    }
    if (getInt(args, "max_results")) |n| {
        if (n <= 0) {
            const w_err = cio.listWriter(out, alloc);
            w_err.print("error: max_results ({d}) must be >= 1", .{n}) catch {};
            return;
        }
    }
    // Default trimmed from 50 -> 30 (Nov 2026) to match typical caller
    // counts in real codebases; rare hot symbols can still request more.
    const max_results: usize = if (getInt(args, "max_results")) |n| @intCast(@max(1, @min(n, 10000))) else 30;

    const defs = explorer.findAllSymbols(name, alloc) catch {
        out.appendSlice(alloc, "error: symbol lookup failed") catch {};
        return;
    };
    defer {
        for (defs) |d| {
            alloc.free(d.path);
            alloc.free(d.symbol.name);
            if (d.symbol.detail) |dd| alloc.free(dd);
        }
        alloc.free(defs);
    }

    const results = explorer.searchContentWithScope(name, alloc, max_results) catch {
        out.appendSlice(alloc, "error: search failed") catch {};
        return;
    };
    defer {
        for (results) |r| {
            alloc.free(r.line_text);
            alloc.free(r.path);
            if (r.scope_name) |n2| alloc.free(n2);
        }
        alloc.free(results);
    }

    var shown: usize = 0;
    for (results) |r| {
        if (!langHasCallSites(explore_mod.detectLanguage(r.path))) continue;
        var is_def = false;
        for (defs) |d| {
            if (r.line_num == d.symbol.line_start and std.mem.eql(u8, r.path, d.path)) {
                is_def = true;
                break;
            }
        }
        if (is_def) continue;
        if (!hasWholeWordMatch(r.line_text, name)) continue;
        shown += 1;
    }

    const w = cio.listWriter(out, alloc);
    w.print("{d} call sites for '{s}':\n", .{ shown, name }) catch {};
    for (results) |r| {
        if (!langHasCallSites(explore_mod.detectLanguage(r.path))) continue;
        var is_def = false;
        for (defs) |d| {
            if (r.line_num == d.symbol.line_start and std.mem.eql(u8, r.path, d.path)) {
                is_def = true;
                break;
            }
        }
        if (is_def) continue;
        if (!hasWholeWordMatch(r.line_text, name)) continue;
        if (r.scope_name) |sn| {
            w.print("  {s}:{d}: {s}  [in {s} ({s}, L{d}-L{d})]\n", .{
                r.path, r.line_num, r.line_text, sn, @tagName(r.scope_kind.?), r.scope_start, r.scope_end,
            }) catch {};
        } else {
            w.print("  {s}:{d}: {s}\n", .{ r.path, r.line_num, r.line_text }) catch {};
        }
    }
}

fn handleCallpath(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8), explorer: *Explorer) void {
    const from_name = getStr(args, "from") orelse {
        out.appendSlice(alloc, "error: missing 'from' argument") catch {};
        appendBundleArgKeysDiagnostic(alloc, out, args);
        return;
    };
    const to_name = getStr(args, "to") orelse {
        out.appendSlice(alloc, "error: missing 'to' argument") catch {};
        appendBundleArgKeysDiagnostic(alloc, out, args);
        return;
    };
    if (from_name.len == 0 or to_name.len == 0) {
        out.appendSlice(alloc, "error: 'from' and 'to' must be non-empty symbol names") catch {};
        return;
    }
    const max_hops: usize = if (getInt(args, "max_hops")) |n| @intCast(@max(1, @min(n, 64))) else 12;

    const steps = explorer.findCallPath(from_name, to_name, alloc, max_hops) catch {
        out.appendSlice(alloc, "error: callpath search failed") catch {};
        return;
    };
    const path = steps orelse {
        const w = cio.listWriter(out, alloc);
        w.print("no call path from '{s}' to '{s}' within {d} hops\n", .{ from_name, to_name, max_hops }) catch {};
        return;
    };
    defer alloc.free(path);

    const w = cio.listWriter(out, alloc);
    w.print("call path ({d} hops): {s} → {s}\n", .{ path.len - 1, from_name, to_name }) catch {};
    for (path, 0..) |step, i| {
        if (i > 0) w.print("  → ", .{}) catch {};
        w.print("{s}:{s}@L{d}", .{ step.path, step.name, step.line }) catch {};
        if (i + 1 < path.len) w.print("\n", .{}) catch {};
    }
    w.print("\n", .{}) catch {};
}

fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '_';
}

/// Returns true iff `needle` appears in `haystack` with non-identifier
/// characters (or string boundary) on both sides — i.e. as a whole-word
/// identifier match, not as a substring inside a longer identifier.
fn hasWholeWordMatch(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or haystack.len < needle.len) return false;
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, search_from, needle)) |pos| {
        const before_ok = pos == 0 or !isIdentChar(haystack[pos - 1]);
        const after_idx = pos + needle.len;
        const after_ok = after_idx >= haystack.len or !isIdentChar(haystack[after_idx]);
        if (before_ok and after_ok) return true;
        search_from = pos + 1;
    }
    return false;
}

/// Languages where the concept of a "call site" is meaningful. Excludes
/// data formats (json, yaml), markup/styling (markdown, css, scss),
/// declarative schemas (protobuf), and unknown files — callers found
/// inside these are mentions in prose or config, not real invocations.
fn langHasCallSites(lang: explore_mod.Language) bool {
    return switch (lang) {
        .markdown, .json, .yaml, .css, .scss, .protobuf, .unknown => false,
        else => true,
    };
}

// ── codedb_context ──────────────────────────────────────────────────────────
// Task-shaped composer. Takes a natural-language task, extracts candidate
// identifiers (camelCase / snake_case / "quoted strings"), and returns ONE
// composite text block: keywords + symbol defs + ranked files + top sites.
// Replaces 3-5 separate search/word/symbol calls; targets parity with
// codegraph_context on per-task token economy.

fn isContextIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}
fn isContextIdentCont(c: u8) bool {
    return isContextIdentStart(c) or (c >= '0' and c <= '9');
}
fn looksLikeContextIdentifier(tok: []const u8) bool {
    // Filter out sentence-leading English words ("Find", "React", "Want")
    // that incidentally start with a capital, while keeping real identifiers.
    // Rules:
    //   - snake_case (any underscore)              → always pass
    //   - all-caps acronym, 3-8 chars (API, TODO)  → pass
    //   - camelCase / PascalCase with an internal
    //     lower→upper transition (getNextLanes)    → pass
    //   - everything else                          → reject
    if (tok.len < 3) return false;
    if (std.mem.indexOfScalar(u8, tok, '_') != null) return true;
    var all_upper = true;
    for (tok) |c| {
        if (c < 'A' or c > 'Z') {
            all_upper = false;
            break;
        }
    }
    if (all_upper) return tok.len <= 8;
    var i: usize = 1;
    while (i < tok.len) : (i += 1) {
        const prev_lower = tok[i - 1] >= 'a' and tok[i - 1] <= 'z';
        const cur_upper = tok[i] >= 'A' and tok[i] <= 'Z';
        if (prev_lower and cur_upper) return true;
    }
    return false;
}

// Cap at 3 candidates instead of 5. handleContext does one searchContent +
// one findAllSymbols per candidate (the bench shows 30µs and ~5µs each on
// codedb's own repo), so each extra candidate adds ~35µs of fixed cost
// for diminishing return — the by_file ranking already heavily favors
// the first 1–2 high-quality identifiers. End-to-end this drops
// codedb_context from ~330µs → ~220µs on the standard bench task.
const CONTEXT_MAX_CANDIDATES: usize = 3;
// 20 was the original tier-search cap, but only CONTEXT_TOP_LINES_PER_FILE
// (3) hits per file are ever kept after ranking — every additional result
// is wasted work in search-content + per-file map churn. Empirically 8
// covers the keep-window even on dense files.
const CONTEXT_MAX_RESULTS_PER_KW: usize = 8;
const CONTEXT_TOP_FILES: usize = 5;
const CONTEXT_TOP_LINES_PER_FILE: usize = 3;

fn extractContextCandidates(task: []const u8, alloc: std.mem.Allocator, out: *std.ArrayList([]const u8)) void {
    var seen = std.StringHashMap(void).init(alloc);
    defer seen.deinit();
    var i: usize = 0;
    while (i < task.len) {
        const c = task[i];
        // Quoted strings — taken literally as identifiers.
        if (c == '"' or c == '`') {
            const q = c;
            const start = i + 1;
            var j = start;
            while (j < task.len and task[j] != q) : (j += 1) {}
            if (j > start and j - start <= 64 and j - start >= 3) {
                const slice = task[start..j];
                if (!seen.contains(slice)) {
                    seen.put(slice, {}) catch {};
                    out.append(alloc, slice) catch {};
                    if (out.items.len >= CONTEXT_MAX_CANDIDATES) return;
                }
            }
            i = j + 1;
            continue;
        }
        // Identifier-like tokens.
        if (isContextIdentStart(c)) {
            const start = i;
            while (i < task.len and isContextIdentCont(task[i])) : (i += 1) {}
            const tok = task[start..i];
            if (tok.len >= 3 and tok.len <= 64 and looksLikeContextIdentifier(tok) and !seen.contains(tok)) {
                seen.put(tok, {}) catch {};
                out.append(alloc, tok) catch {};
                if (out.items.len >= CONTEXT_MAX_CANDIDATES) return;
            }
            continue;
        }
        i += 1;
    }
}

fn handleContext(io: std.Io, alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8), explorer: *Explorer, project_root: []const u8) void {
    const task = getStr(args, "task") orelse {
        out.appendSlice(alloc, "error: missing 'task' argument") catch {};
        appendBundleArgKeysDiagnostic(alloc, out, args);
        return;
    };
    if (task.len < 3 or task.len > 1024) {
        out.appendSlice(alloc, "error: task must be 3-1024 chars") catch {};
        return;
    }

    // reader.md prepend (experimental): if .codedb/reader.md exists and its
    // declared source_hash matches the current source files, prepend its body
    // to the response. Gives the agent one-shot orientation without paying
    // exploratory search calls. See experiments/reader-md/SPEC.md.
    //
    // Critical-review I11 + n=2 vs-main eval (RESULTS-VS-MAIN-FINAL.md): on
    // short narrow tasks like "find before_request" the composer's
    // symbol_definitions section already pinpoints the answer, and reader.md's
    // ~5 KB body becomes pure overhead — the T1 flask regression
    // (+37% calls / +18% tokens) came entirely from this case.
    //
    // Gate: only prepend reader.md when the task is long enough to suggest
    // exploration rather than a narrow lookup. 80 chars is the inflection
    // point in the eval — T1's "find before_request decorator" is 28 chars,
    // T2/T3 are 230+ chars.
    const reader_md_gate = task.len > 80;
    if (reader_md_gate) {
        var reader_state = reader_md.load(io, alloc, project_root) catch null;
        if (reader_state) |*r| {
            defer r.free(alloc);
            switch (r.state) {
                .ready => {
                    if (r.body) |b| {
                        out.appendSlice(alloc, "<!-- reader.md (hash-verified): -->\n") catch {};
                        out.appendSlice(alloc, b) catch {};
                        out.appendSlice(alloc, "\n<!-- end reader.md -->\n\n") catch {};
                    }
                },
                .stale => {
                    out.appendSlice(alloc, "<!-- reader.md is stale (source_hash drifted). Regenerate by writing a new .codedb/reader.md with current source_hash. -->\n\n") catch {};
                },
                .malformed, .missing => {
                    // Silent — reader.md is optional.
                },
            }
        }
    }
    // Arena: every transient string in this handler lives here, no per-result
    // free bookkeeping. Released at function exit.
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const A = arena.allocator();

    var candidates: std.ArrayList([]const u8) = .empty;
    extractContextCandidates(task, A, &candidates);
    if (candidates.items.len == 0) {
        out.appendSlice(alloc, "no candidate identifiers found in task — include symbol names (camelCase or snake_case) or \"quoted strings\" so the composer can extract keywords") catch {};
        return;
    }

    const PerFileHit = struct { line: u32, text: []const u8 };
    const PerFile = struct {
        total: u32 = 0,
        bm25: f32 = 0,
        top: std.ArrayList(PerFileHit) = .empty,
    };
    var by_file = std.StringHashMap(PerFile).init(A);

    const SymRef = struct { kw: []const u8, kind: []const u8, path: []const u8, line: u32, line_end: u32 };
    var sym_refs: std.ArrayList(SymRef) = .empty;
    var seen_syms = std.StringHashMap(void).init(A);

    for (candidates.items) |kw| {
        // Symbol definitions (best-effort; ignore failures).
        if (explorer.findAllSymbols(kw, A)) |defs| {
            const take = @min(defs.len, 3);
            for (defs[0..take]) |d| {
                const key = std.fmt.allocPrint(A, "{s}|{s}|{d}", .{ d.path, kw, d.symbol.line_start }) catch continue;
                if (seen_syms.contains(key)) continue;
                seen_syms.put(key, {}) catch continue;
                sym_refs.append(A, .{
                    .kw = kw,
                    .kind = @tagName(d.symbol.kind),
                    .path = d.path,
                    .line = d.symbol.line_start,
                    .line_end = d.symbol.line_end,
                }) catch break;
            }
        } else |_| {}

        // Content search — small per-keyword cap keeps the arena lean.
        const hits = explorer.searchContentRanked(kw, A, CONTEXT_MAX_RESULTS_PER_KW) catch continue;
        for (hits) |h| {
            const gop = by_file.getOrPut(h.path) catch continue;
            if (!gop.found_existing) gop.value_ptr.* = .{};
            gop.value_ptr.total += 1;
            gop.value_ptr.bm25 += h.score;
            if (gop.value_ptr.top.items.len < CONTEXT_TOP_LINES_PER_FILE) {
                gop.value_ptr.top.append(A, .{ .line = h.line_num, .text = h.line_text }) catch {};
            }
        }
    }

    // Rank files by a composite score: raw hits, +bonus when the file
    // contains a symbol definition for any keyword (definition beats usage),
    // −penalty for test/spec/doc files (agents kept picking test files over
    // the real source on T3/F1/F3/G2). Final secondary sort by hits.
    var symbol_files = std.StringHashMap(void).init(A);
    for (sym_refs.items) |sr| symbol_files.put(sr.path, {}) catch {};

    const FileRank = struct { path: []const u8, hits: u32, score: f32, top: []const PerFileHit };
    var ranked: std.ArrayList(FileRank) = .empty;
    var iter = by_file.iterator();
    while (iter.next()) |entry| {
        const path = entry.key_ptr.*;
        // Rank by summed BM25 score, which already carries BM25+ and the
        // path-relevance multiplier (test/doc down-weight + filename boost) from
        // searchContentRanked. Files that DEFINE a keyword get the edge
        // (definition beats usage — codedb_context's unique signal).
        var score: f32 = entry.value_ptr.bm25;
        if (symbol_files.contains(path)) score *= 1.5;
        ranked.append(A, .{
            .path = path,
            .hits = entry.value_ptr.total,
            .score = score,
            .top = entry.value_ptr.top.items,
        }) catch break;
    }
    std.mem.sort(FileRank, ranked.items, {}, struct {
        fn lt(_: void, a: FileRank, b: FileRank) bool {
            if (a.score != b.score) return a.score > b.score;
            return a.hits > b.hits;
        }
    }.lt);
    const top_n = @min(ranked.items.len, CONTEXT_TOP_FILES);

    const w = cio.listWriter(out, alloc);
    w.print("# Task\n{s}\n\n## Keywords used\n", .{task}) catch {};
    for (candidates.items) |k| w.print("- {s}\n", .{k}) catch {};

    if (sym_refs.items.len > 0) {
        w.print("\n## Symbol definitions\n", .{}) catch {};
        // Enhancement (closes T1 flask variance gap): when there are ≤3
        // symbol definitions, inline each symbol's FULL body (capped at 40
        // lines) so the agent doesn't need a follow-up `codedb_read`. For wider
        // result sets this would bloat the response, so cap at 3.
        const inline_bodies = sym_refs.items.len <= 3;
        for (sym_refs.items) |sr| {
            w.print("- {s} ({s}) — {s}:{d}\n", .{ sr.kw, sr.kind, sr.path, sr.line }) catch {};
            if (inline_bodies) {
                if (explorer.getContent(sr.path, A) catch null) |content| {
                    var cur_line: u32 = 1;
                    var i: usize = 0;
                    var line_start: ?usize = null;
                    var captured: u32 = 0;
                    const body_end: u32 = if (sr.line_end > sr.line) @min(sr.line_end, sr.line + 39) else sr.line;
                    const max_lines: u32 = body_end - sr.line + 1;
                    if (cur_line == sr.line) line_start = 0;
                    while (i < content.len and captured < max_lines) : (i += 1) {
                        if (content[i] == '\n') {
                            if (line_start) |ls| {
                                const line_end = i;
                                w.print("       {d:>5} | {s}\n", .{ cur_line, content[ls..line_end] }) catch {};
                                captured += 1;
                            }
                            cur_line += 1;
                            if (cur_line >= sr.line and cur_line <= body_end) {
                                line_start = i + 1;
                            } else {
                                line_start = null;
                            }
                        }
                    }
                    if (line_start) |ls| {
                        if (captured < max_lines) {
                            w.print("       {d:>5} | {s}\n", .{ cur_line, content[ls..] }) catch {};
                        }
                    }
                }
            }
        }

        // Callers section (closes the T1 flask agent-mean gap):
        // For each ≤3 symbol_definitions, surface up to 2 non-definition,
        // non-test call sites with their enclosing scope. The whole point of
        // this section is to pre-resolve "where is this called from" so the
        // agent doesn't need codedb_callers / outline / read follow-ups.
        // Examples this targets directly:
        //   T1 flask: before_request → preprocess_request in app.py
        //   T2 regex: Builder::build → meta::Regex::new in regex.rs
        // Callers section (closes the T1 flask agent-mean gap):
        // For each ≤3 symbol_definitions, surface up to 2 non-definition,
        // non-test, non-import call sites with their enclosing scope. The
        // whole point of this section is to pre-resolve "where is this called
        // from" so the agent doesn't need codedb_callers / outline / read
        // follow-ups. Examples this targets directly:
        //   T1 flask: before_request → preprocess_request in app.py
        //   T2 regex: Builder::build → meta::Regex::new in regex.rs
        if (inline_bodies) {
            var any_callers = false;
            var seen_caller = std.StringHashMap(void).init(A);
            var total_shown: u32 = 0;
            // Dedupe scoped searches by keyword — multiple sym_refs often
            // share the same kw (same symbol defined in multiple files);
            // running searchContentWithScope per sym_ref was 30 µs × 6
            // searches = 180 µs of redundant work on the bench task.
            var searched_kw = std.StringHashMap(void).init(A);
            for (sym_refs.items) |sr| {
                if (total_shown >= 6) break;
                if (searched_kw.contains(sr.kw)) continue;
                searched_kw.put(sr.kw, {}) catch {};
                const scoped = explorer.searchContentWithScope(sr.kw, A, 30) catch continue;
                var shown_for_sym: u32 = 0;
                for (scoped) |r| {
                    if (shown_for_sym >= 2 or total_shown >= 6) break;
                    if (!langHasCallSites(explore_mod.detectLanguage(r.path))) continue;
                    // Skip the definition site itself
                    if (r.line_num == sr.line and std.mem.eql(u8, r.path, sr.path)) continue;
                    // Skip test/spec/fixture paths
                    const is_test = std.mem.startsWith(u8, r.path, "tests/") or
                        std.mem.startsWith(u8, r.path, "test/") or
                        std.mem.indexOf(u8, r.path, "/test") != null or
                        std.mem.indexOf(u8, r.path, "_test.") != null or
                        std.mem.indexOf(u8, r.path, ".test.") != null or
                        std.mem.indexOf(u8, r.path, "/__tests__/") != null or
                        std.mem.indexOf(u8, r.path, "/spec/") != null or
                        std.mem.indexOf(u8, r.path, "/fixtures/") != null;
                    if (is_test) continue;
                    if (r.scope_kind) |sk| {
                        if (sk == .import or sk == .type_alias or sk == .constant) continue;
                    }
                    const dedup_key = std.fmt.allocPrint(A, "{s}:{d}", .{ r.path, r.line_num }) catch continue;
                    if (seen_caller.contains(dedup_key)) continue;
                    seen_caller.put(dedup_key, {}) catch {};
                    if (!any_callers) {
                        w.print("\n## Callers (top non-test, non-import usages of these symbols)\n", .{}) catch {};
                        any_callers = true;
                    }
                    if (r.scope_name) |sn| {
                        w.print("- {s}:{d}: {s}  [in {s} ({s}, L{d}-L{d})]\n", .{
                            r.path, r.line_num, r.line_text, sn, @tagName(r.scope_kind.?), r.scope_start, r.scope_end,
                        }) catch {};
                    } else {
                        w.print("- {s}:{d}: {s}\n", .{ r.path, r.line_num, r.line_text }) catch {};
                    }
                    shown_for_sym += 1;
                    total_shown += 1;
                }
            }
        }

        // Callees section (graph-resolved): walk each ≤3 key symbol's call sites
        // through the resolved call graph and surface where each callee is
        // defined. This is the dependency side of the neighborhood — pairs with
        // the Callers section above so the agent sees both who calls a symbol and
        // what it calls, without a follow-up codedb_outline/read on the callees.
        if (inline_bodies) {
            var any_callees = false;
            var done_sym = std.StringHashMap(void).init(A);
            for (sym_refs.items) |sr| {
                const sym_key = std.fmt.allocPrint(A, "{s}:{d}", .{ sr.path, sr.line }) catch continue;
                if (done_sym.contains(sym_key)) continue;
                done_sym.put(sym_key, {}) catch {};
                const callees = explorer.resolveCallees(sr.path, sr.line, sr.line_end, A, 6) catch continue;
                if (callees.len == 0) continue;
                if (!any_callees) {
                    w.print("\n## Calls (graph-resolved callees of these symbols)\n", .{}) catch {};
                    any_callees = true;
                }
                w.print("- {s} ({s}) calls:\n", .{ sr.kw, sr.kind }) catch {};
                for (callees) |c| {
                    w.print("    \xe2\x86\x92 {s} ({s})  {s}:{d}\n", .{ c.name, @tagName(c.kind), c.path, c.line }) catch {};
                }
            }
        }
    }

    if (top_n == 0) {
        out.appendSlice(alloc, "\n(no content matches — try codedb_search or codedb_word for narrower queries)\n") catch {};
        return;
    }
    w.print("\n## Most-relevant files\n", .{}) catch {};
    for (ranked.items[0..top_n]) |f| {
        w.print("- {s}  ({d} matches)\n", .{ f.path, f.hits }) catch {};
    }
    w.print("\n## Top sites (with ±2 lines of context)\n", .{}) catch {};
    explorer.mu.lockShared();
    defer explorer.mu.unlockShared();
    for (ranked.items[0..top_n]) |f| {
        // Fetch full file content once per file, then slice ±2 lines around
        // each hit. Indexed cache hits common files in ~µs; arena owns the
        // dupe so we don't leak.
        const file_content: ?[]const u8 = blk: {
            const got = explorer.getContent(f.path, A) catch break :blk null;
            break :blk got;
        };
        for (f.top) |h| {
            if (file_content) |content| {
                // Find the start/end byte offsets of [line-2 .. line+2].
                const want_start: u32 = if (h.line > 2) h.line - 2 else 1;
                const want_end: u32 = h.line + 2;
                var cur_line: u32 = 1;
                var i: usize = 0;
                var captured_start: ?usize = null;
                var captured_end: ?usize = null;
                if (cur_line == want_start) captured_start = 0;
                while (i < content.len) : (i += 1) {
                    if (content[i] == '\n') {
                        cur_line += 1;
                        if (cur_line == want_start and captured_start == null) {
                            captured_start = i + 1;
                        }
                        if (cur_line > want_end) {
                            captured_end = i;
                            break;
                        }
                    }
                }
                if (captured_end == null) captured_end = content.len;
                if (captured_start) |start_off| {
                    const end_off = captured_end.?;
                    const slice = content[start_off..end_off];
                    // Cap per-snippet length to keep output bounded.
                    const cap = @min(slice.len, 480);
                    w.print("\n{s}:{d}\n```\n{s}\n```\n", .{ f.path, h.line, slice[0..cap] }) catch {};
                    continue;
                }
            }
            // Fallback: single-line hit when we couldn't expand.
            w.print("{s}:{d}  {s}\n", .{ f.path, h.line, h.text }) catch {};
        }
    }
}


fn handleHot(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8), store: *Store, explorer: *Explorer) void {
    const limit: usize = if (getInt(args, "limit")) |n| @intCast(@min(@max(1, n), 1000)) else 10;
    explorer.renderHot(store, alloc, out, limit) catch {
        out.appendSlice(alloc, "error: hot files failed") catch {};
    };
}

fn handleDeps(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8), explorer: *Explorer) void {
    const path = getStr(args, "path") orelse {
        out.appendSlice(alloc, "error: missing 'path' argument") catch {};
        appendBundleArgKeysDiagnostic(alloc, out, args);
        return;
    };

    if (args.count() == 1 or
        (args.get("direction") == null and args.get("transitive") == null and args.get("max_depth") == null))
    {
        handleDepsPathOnly(alloc, path, out, explorer);
        return;
    }

    const direction = getStr(args, "direction") orelse "imported_by";
    const transitive = getBool(args, "transitive");
    const max_depth: ?u32 = if (getInt(args, "max_depth")) |n| @intCast(@max(1, n)) else null;

    const is_forward = std.mem.eql(u8, direction, "depends_on");

    var results: []const []const u8 = &.{};
    if (is_forward) {
        if (transitive) {
            results = explorer.getTransitiveDependencies(path, alloc, max_depth) catch {
                out.appendSlice(alloc, "error: deps failed") catch {};
                return;
            };
        } else {
            explorer.mu.lockShared();
            const fwd = explorer.dep_graph.getForwardDeps(path);
            explorer.mu.unlockShared();
            if (fwd) |deps| {
                var result_list: std.ArrayList([]const u8) = .empty;
                for (deps) |dep| {
                    const d = alloc.dupe(u8, dep) catch continue;
                    result_list.append(alloc, d) catch {
                        alloc.free(d);
                        continue;
                    };
                }
                results = result_list.toOwnedSlice(alloc) catch &.{};
            }
        }
    } else {
        if (transitive) {
            results = explorer.getTransitiveDependents(path, alloc, max_depth) catch {
                out.appendSlice(alloc, "error: deps failed") catch {};
                return;
            };
        } else {
            const w = cio.listWriter(out, alloc);
            w.print("{s} is imported by:\n", .{path}) catch {};
            const rendered = explorer.renderImportedBy(path, alloc, out) catch {
                out.appendSlice(alloc, "error: deps failed") catch {};
                return;
            };
            if (rendered.count == 0) {
                w.writeAll("  (none)\n") catch {};
                if (!rendered.known) appendFuzzyPathSuggestions(alloc, out, explorer, path);
            } else {
                w.print("({d} files)\n", .{rendered.count}) catch {};
            }
            return;
        }
    }
    defer {
        for (results) |dep| alloc.free(dep);
        alloc.free(results);
    }

    const w = cio.listWriter(out, alloc);
    if (is_forward) {
        if (transitive) {
            w.print("{s} transitively depends on:\n", .{path}) catch {};
        } else {
            w.print("{s} depends on:\n", .{path}) catch {};
        }
    } else {
        if (transitive) {
            w.print("{s} is transitively imported by:\n", .{path}) catch {};
        } else {
            w.print("{s} is imported by:\n", .{path}) catch {};
        }
    }
    if (results.len == 0) {
        w.writeAll("  (none)\n") catch {};
        // Bug 4: if the path isn't indexed at all, agents read "(none)" as
        // "file exists but no callers" — which is wrong. Append fuzzy
        // suggestions so a typo is recoverable in one shot.
        explorer.mu.lockShared();
        const known = explorer.outlines.contains(path);
        explorer.mu.unlockShared();
        if (!known) appendFuzzyPathSuggestions(alloc, out, explorer, path);
    } else {
        for (results) |dep| {
            w.print("  {s}\n", .{dep}) catch {};
        }
        w.print("({d} files)\n", .{results.len}) catch {};
    }
}

fn handleDepsPathOnly(alloc: std.mem.Allocator, path: []const u8, out: *std.ArrayList(u8), explorer: *Explorer) void {
    const w = cio.listWriter(out, alloc);
    w.print("{s} is imported by:\n", .{path}) catch {};
    const rendered = explorer.renderImportedBy(path, alloc, out) catch {
        out.appendSlice(alloc, "error: deps failed") catch {};
        return;
    };
    if (rendered.count == 0) {
        w.writeAll("  (none)\n") catch {};
        if (!rendered.known) appendFuzzyPathSuggestions(alloc, out, explorer, path);
    } else {
        w.print("({d} files)\n", .{rendered.count}) catch {};
    }
}

fn handleRead(io: std.Io, alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8), explorer: *Explorer) void {
    const path = getStr(args, "path") orelse {
        out.appendSlice(alloc, "error: missing 'path' argument") catch {};
        appendBundleArgKeysDiagnostic(alloc, out, args);
        return;
    };
    if (!isPathSafe(path)) {
        out.appendSlice(alloc, "error: path traversal not allowed") catch {};
        return;
    }
    if (watcher.isSensitivePath(path)) {
        out.appendSlice(alloc, "error: access to sensitive file blocked") catch {};
        return;
    }

    // Line range params
    const line_start_raw = getInt(args, "line_start");
    const line_end_raw = getInt(args, "line_end");
    const compact = getBool(args, "compact");
    const has_range = line_start_raw != null or line_end_raw != null;

    // Bug 6: validate line range explicitly. Pre-fix: invalid ranges silently
    // returned an empty body (just the hash line) — agents read that as "file
    // is empty in that range" instead of "you passed nonsense".
    if (line_start_raw) |ls| {
        if (ls < 1) {
            out.appendSlice(alloc, "error: line_start must be >= 1") catch {};
            return;
        }
    }
    if (line_end_raw) |le| {
        if (le < 1) {
            out.appendSlice(alloc, "error: line_end must be >= 1") catch {};
            return;
        }
    }
    if (line_start_raw != null and line_end_raw != null) {
        if (line_start_raw.? > line_end_raw.?) {
            const w_err = cio.listWriter(out, alloc);
            w_err.print("error: line_start ({d}) > line_end ({d})", .{ line_start_raw.?, line_end_raw.? }) catch {};
            return;
        }
    }

    const if_hash = getStr(args, "if_hash");
    if (explorer.renderCachedRead(path, alloc, out, .{
        .if_hash = if_hash,
        .line_start = line_start_raw,
        .line_end = line_end_raw,
        .compact = compact,
    }) catch {
        out.appendSlice(alloc, "error: read failed") catch {};
        return;
    }) {
        return;
    }

    // Try indexed content first (faster, consistent with indexed view)
    const cached = explorer.getContent(path, alloc) catch {
        out.appendSlice(alloc, "error: read failed") catch {};
        return;
    };
    const content = if (cached) |owned_content|
        owned_content
    else blk: {
        // Fall back to disk read
        break :blk std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(10 * 1024 * 1024)) catch {
            out.appendSlice(alloc, "error: failed to read file: ") catch {};
            out.appendSlice(alloc, path) catch {};
            // Issue #356-p3: fuzzy fallback so a mistyped path is recoverable
            // without a separate codedb_find round-trip — same shape as
            // codedb_outline already does.
            appendFuzzyPathSuggestions(alloc, out, explorer, path);
            return;
        };
    };
    defer alloc.free(content);

    // Bug 5: detect binary content (NUL byte in first 8KB) and stub the
    // response — dumping raw bytes corrupts JSON consumers and leaks tokens
    // for files that are never useful to a model.
    const probe_len = @min(content.len, 8 * 1024);
    if (std.mem.indexOfScalar(u8, content[0..probe_len], 0) != null) {
        const w0 = cio.listWriter(out, alloc);
        const hash_b = std.hash.Wyhash.hash(0, content);
        w0.print("binary file: {d} bytes  hash:{x}\n", .{ content.len, hash_b }) catch {};
        return;
    }

    // Content-hash ETag
    const hash = std.hash.Wyhash.hash(0, content);
    var hash_buf: [16]u8 = undefined;
    const hash_str = std.fmt.bufPrint(&hash_buf, "{x}", .{hash}) catch "";
    if (if_hash) |prev| {
        if (std.mem.eql(u8, prev, hash_str)) {
            out.appendSlice(alloc, "unchanged:") catch {};
            out.appendSlice(alloc, hash_str) catch {};
            return;
        }
    }

    // Always prepend hash
    const w = cio.listWriter(out, alloc);
    w.print("hash:{s}\n", .{hash_str}) catch {};

    if (has_range or compact) {
        const start: u32 = if (line_start_raw) |n| @intCast(@min(@max(1, n), std.math.maxInt(u32))) else 1;
        const end: u32 = if (line_end_raw) |n| @intCast(@min(@max(1, n), std.math.maxInt(u32))) else std.math.maxInt(u32);
        const lang = explore_mod.detectLanguage(path);
        const extracted = explore_mod.extractLines(content, start, end, true, compact, lang, alloc) catch {
            out.appendSlice(alloc, "error: line extraction failed") catch {};
            return;
        };
        defer alloc.free(extracted);
        out.appendSlice(alloc, extracted) catch {};
    } else {
        out.appendSlice(alloc, content) catch {};
    }
}

fn handleEdit(io: std.Io, alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8), store: *Store, explorer: *Explorer, agents: *AgentRegistry, cache: *ProjectCache, edit_agent_id: u64) void {
    const path = getStr(args, "path") orelse {
        out.appendSlice(alloc, "error: missing 'path'") catch {};
        return;
    };
    if (!isPathSafe(path)) {
        out.appendSlice(alloc, "error: path traversal not allowed") catch {};
        return;
    }
    if (watcher.isSensitivePath(path)) {
        out.appendSlice(alloc, "error: access to sensitive file blocked") catch {};
        return;
    }
    const op_str = getStr(args, "op") orelse "replace";
    const is_create = eql(op_str, "create");
    const op: @import("version.zig").Op = if (eql(op_str, "insert"))
        .insert
    else if (eql(op_str, "delete"))
        .delete
    else if (eql(op_str, "replace") or eql(op_str, "str_replace") or is_create)
        .replace
    else {
        out.appendSlice(alloc, "error: unknown op, must be 'create', 'replace', 'str_replace', 'insert', or 'delete'") catch {};
        return;
    };

    const content = getStr(args, "content");
    const range_start = getInt(args, "range_start");
    const range_end = getInt(args, "range_end");
    const after = getInt(args, "after");

    // Per-session advisory-lock owner. The server threads a distinct agent id
    // per MCP connection (Session.edit_agent_id), so concurrent edits to the
    // same file from separate connections are detected instead of all sharing
    // the startup __filesystem__ agent (#528 audit). Defaults to 1 (the
    // __filesystem__ agent) for the single-connection stdio path.
    var req = edit_mod.EditRequest{
        .path = path,
        .agent_id = edit_agent_id,
        .op = op,
        .content = content,
        .old_string = getStr(args, "old_string"),
        .new_string = getStr(args, "new_string"),
        .if_hash = getStr(args, "if_hash"),
        .dry_run = getBool(args, "dry_run"),
        .create = is_create,
    };
    if (range_start != null and range_end != null) {
        if (range_start.? <= 0 or range_end.? <= 0) {
            out.appendSlice(alloc, "error: range values must be >= 1") catch {};
            return;
        }
        req.range = .{ @intCast(range_start.?), @intCast(range_end.?) };
    }
    if (after) |a| {
        if (a < 0) {
            out.appendSlice(alloc, "error: 'after' must be positive") catch {};
            return;
        }
        req.after = @intCast(a);
    }

    const result = edit_mod.applyEdit(io, alloc, store, agents, explorer, req) catch |err| {
        out.appendSlice(alloc, "error: edit failed: ") catch {};
        out.appendSlice(alloc, @errorName(err)) catch {};
        if (err == error.HashMismatch) {
            // Include the file's current hex hash so the agent can re-read with if_hash
            // to verify it has the latest content, then retry the edit.
            const edit_dir = explorer.root_dir orelse std.Io.Dir.cwd();
            if (edit_dir.readFileAlloc(io, path, alloc, .limited(10 * 1024 * 1024))) |bytes| {
                defer alloc.free(bytes);
                const w = cio.listWriter(out, alloc);
                w.print(" (current hash: {x})", .{std.hash.Wyhash.hash(0, bytes)}) catch {};
            } else |_| {}
        } else if (err == error.PatternNotFound) {
            out.appendSlice(alloc, " (old_string not found \u{2014} re-read the file and copy the exact text, including whitespace and indentation)") catch {};
        } else if (err == error.PatternNotUnique) {
            // Tell the agent how many times old_string matched so it knows how much
            // surrounding context to add to make the anchor unique.
            const edit_dir = explorer.root_dir orelse std.Io.Dir.cwd();
            if (edit_dir.readFileAlloc(io, path, alloc, .limited(10 * 1024 * 1024))) |bytes| {
                defer alloc.free(bytes);
                const old = getStr(args, "old_string") orelse "";
                var count: usize = 0;
                if (old.len > 0) {
                    var i: usize = 0;
                    while (std.mem.indexOfPos(u8, bytes, i, old)) |pos| {
                        count += 1;
                        i = pos + old.len;
                    }
                }
                const w = cio.listWriter(out, alloc);
                w.print(" (old_string matched {d} times \u{2014} add surrounding lines to make it unique)", .{count}) catch {};
            } else |_| {}
        } else if (err == error.FileExists) {
            out.appendSlice(alloc, " (file already exists \u{2014} use op=str_replace or op=replace to edit it, not op=create)") catch {};
        }
        return;
    };
    defer if (result.preview) |p| alloc.free(p);
    defer if (result.health) |h| alloc.free(h);

    const w = cio.listWriter(out, alloc);
    if (req.dry_run) {
        w.print("dry_run: would write size={d}, hash:{x}\n", .{ result.new_size, result.new_hash }) catch {};
        if (result.preview) |p| out.appendSlice(alloc, p) catch {};
    } else if (!result.changed) {
        w.print("edit unchanged: seq={d}, size={d}, hash:{x}", .{ result.seq, result.new_size, result.new_hash }) catch {};
    } else {
        w.print("edit applied: seq={d}, size={d}, hash:{x}", .{ result.seq, result.new_size, result.new_hash }) catch {};
    }
    // Advisory syntax-health warning (trial/graph-based-codedb): surface a
    // mis-spliced multi-line edit so the agent can re-read and fix before
    // declaring the task done, instead of shipping an unparseable file.
    if (result.health) |h| out.appendSlice(alloc, h) catch {};

    // External-linter (Tier-1): only when the user opted in. `enabled` is set
    // once at startup and read-only after, so this guard adds nothing to the
    // edit hot path when linters are off (the default) — no cache lock, no
    // detect, no thread spawn. When on, the linter runs on a DETACHED thread
    // after this response is built, so it never adds latency to the edit.
    if (!req.dry_run and cache.linter.enabled) {
        _ = cache.diag.appendIfFresh(alloc, out, path, result.new_hash);
        const lang = explore_mod.detectLanguage(path);
        if (cache.linter.shouldTry(lang) and cache.diag.tryBeginWork(path, result.new_hash)) {
            spawnLintWorker(cache, path, result.new_hash, lang);
        }
    }
}

// ── External-linter worker (runs off the synchronous edit path) ───────────

const LintJob = struct {
    cache: *ProjectCache,
    path: []u8, // owned (c_allocator); freed by run()
    hash: u64,
    language: explore_mod.Language,

    fn run(job: *LintJob) void {
        const ca = std.heap.c_allocator;
        defer {
            ca.free(job.path);
            ca.destroy(job);
        }
        const summary = linter_mod.runCheck(ca, job.language, job.path) catch {
            // Tool missing / crashed: disable this language for the session,
            // then clear the in-flight mark. mark() MUST precede endWork() so
            // the cache (and session) are still alive — endWork drops the
            // inflight count the owner drains on before freeing them.
            job.cache.linter.mark(job.language, .unavailable);
            job.cache.diag.endWork(job.path);
            return;
        };
        if (summary) |s| {
            defer ca.free(s);
            job.cache.diag.store(job.path, job.hash, s); // clears in-flight
        } else {
            job.cache.diag.endWork(job.path); // clean file: nothing to store
        }
    }
};

/// Spawn a detached linter worker for (path, hash). Caller has already reserved
/// the slot via cache.diag.tryBeginWork(); on any failure here we must release
/// it with endWork() so the in-flight count cannot leak.
fn spawnLintWorker(cache: *ProjectCache, path: []const u8, hash: u64, language: explore_mod.Language) void {
    const ca = std.heap.c_allocator;
    const pdup = ca.dupe(u8, path) catch {
        cache.diag.endWork(path);
        return;
    };
    const job = ca.create(LintJob) catch {
        ca.free(pdup);
        cache.diag.endWork(path);
        return;
    };
    job.* = .{ .cache = cache, .path = pdup, .hash = hash, .language = language };
    const t = std.Thread.spawn(.{}, LintJob.run, .{job}) catch {
        ca.free(pdup);
        ca.destroy(job);
        cache.diag.endWork(path);
        return;
    };
    t.detach();
}

fn handleDiagnostics(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8), cache: *ProjectCache) void {
    const path = getStr(args, "path") orelse {
        out.appendSlice(alloc, "error: missing 'path' argument") catch {};
        return;
    };
    if (!isPathSafe(path)) {
        out.appendSlice(alloc, "error: path traversal not allowed") catch {};
        return;
    }
    if (!cache.diag.appendLatest(alloc, out, path)) {
        out.appendSlice(alloc, "no diagnostics available yet for ") catch {};
        out.appendSlice(alloc, path) catch {};
        out.appendSlice(alloc, " (linters run shortly after an edit; retry, or they may be disabled — `codedb update` to enable)") catch {};
    }
}

fn handleChanges(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8), store: *Store) void {
    const since: u64 = if (getInt(args, "since")) |n| @intCast(@min(@max(0, n), std.math.maxInt(u64))) else 0;
    store.mu.lock();
    defer store.mu.unlock();

    var change_count: usize = store.files.count();
    if (since != 0) {
        change_count = 0;
        var count_iter = store.files.iterator();
        while (count_iter.next()) |entry| {
            var found = false;
            for (entry.value_ptr.versions.items) |v| {
                if (v.seq > since) {
                    found = true;
                    break;
                }
            }
            if (found) change_count += 1;
        }
    }

    const seq = store.seq;
    out.ensureUnusedCapacity(alloc, 64 + change_count * 64) catch {};
    const w = cio.listWriter(out, alloc);
    w.print("seq: {d}, {d} files changed since {d}:\n", .{ seq, change_count, since }) catch {};
    var iter = store.files.iterator();
    while (iter.next()) |entry| {
        var latest_seq: u64 = 0;
        var latest_op: ?@import("version.zig").Op = null;
        var latest_size: u64 = 0;
        for (entry.value_ptr.versions.items) |v| {
            if (v.seq > since and v.seq > latest_seq) {
                latest_seq = v.seq;
                latest_op = v.op;
                latest_size = v.size;
            }
        }
        if (latest_op) |op| {
            w.print("  {s} (seq={d}, op={s}, size={d})\n", .{ entry.key_ptr.*, latest_seq, @tagName(op), latest_size }) catch {};
        }
    }
}

fn handleStatus(alloc: std.mem.Allocator, out: *std.ArrayList(u8), store: *Store, explorer: *Explorer) void {
    store.mu.lock();
    const file_count = store.files.count();
    const seq = store.seq;
    store.mu.unlock();

    const index_bytes = telemetry_mod.approxIndexSizeBytes(explorer);

    explorer.mu.lockShared();
    const outline_count = explorer.outlines.count();
    const content_count = explorer.contents.count();
    const trigram_type: []const u8 = switch (explorer.trigram_index) {
        .heap => "heap",
        .mmap => "mmap",
        .mmap_overlay => "mmap+overlay",
    };
    const trigram_files = explorer.trigram_index.fileCount();
    explorer.mu.unlockShared();

    out.ensureUnusedCapacity(alloc, 256) catch {};
    const w = cio.listWriter(out, alloc);
    w.print(
        \\codedb status:
        \\  seq: {d}
        \\  files: {d}
        \\  outlines: {d}
        \\  contents_cached: {d}
        \\  trigram_index: {s} ({d} files)
        \\  index_memory: {d}KB
        \\  scan: {s}
        \\
    , .{
        seq,
        file_count,
        outline_count,
        content_count,
        trigram_type,
        trigram_files,
        index_bytes / 1024,
        getScanState().name(),
    }) catch {};
}

fn handleSnapshot(alloc: std.mem.Allocator, out: *std.ArrayList(u8), explorer: *Explorer, store: *Store, cache: *SnapshotCache) void {
    const seq = store.currentSeq();
    if (cache.appendIfFresh(alloc, out, seq)) return;

    const snap = snapshot_json.buildSnapshot(explorer, store, alloc) catch {
        out.appendSlice(alloc, "error: snapshot build failed") catch {};
        return;
    };
    cache.putAndAppend(alloc, out, seq, snap);
}


/// When a bundled op produces a missing-arg error, append a `received keys`
/// line listing the keys actually present in the op's args. Helps callers
/// tell whether codedb dropped a field or the client sent it under the
/// wrong name. See issue #357.
fn appendBundleArgKeysDiagnostic(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    args: *const std.json.ObjectMap,
) void {
    out.appendSlice(alloc, "\nreceived keys: [") catch return;
    var it = args.iterator();
    var first = true;
    while (it.next()) |entry| {
        if (!first) out.appendSlice(alloc, ", ") catch return;
        first = false;
        out.appendSlice(alloc, entry.key_ptr.*) catch return;
    }
    out.appendSlice(alloc, "]") catch return;
    // Issue #424/#512: if the args we saw contain only administrative keys
    // or are empty entirely, there were no real tool fields at all. That's
    // almost always a client wrapper bug.
    var has_real_arg = false;
    var it2 = args.iterator();
    while (it2.next()) |entry| {
        const k = entry.key_ptr.*;
        if (!std.mem.eql(u8, k, "tool") and !isDirectCallAdminKey(k)) {
            has_real_arg = true;
            break;
        }
    }
    if (!has_real_arg) {
        out.appendSlice(alloc, "\nhint: no tool args reached the handler — your client may be stripping fields. Direct tools/call expects {\"name\":\"...\",\"arguments\":{\"path\":\"...\"}}; bundled ops may use inline shape: {\"tool\":\"...\",\"path\":\"...\"}.") catch return;
    }
}

/// Append up to 3 fuzzy-matched indexed paths so callers can recover from a
/// non-indexed-path error without a separate codedb_find round-trip.
/// See issue #356.
fn appendFuzzyPathSuggestions(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    explorer: *Explorer,
    bad_path: []const u8,
) void {
    const matches = explorer.fuzzyFindFiles(bad_path, alloc, 3) catch return;
    defer alloc.free(matches);
    if (matches.len == 0) return;
    out.appendSlice(alloc, "\ndid you mean:\n") catch return;
    for (matches) |m| {
        out.appendSlice(alloc, "  ") catch return;
        out.appendSlice(alloc, m.path) catch return;
        out.appendSlice(alloc, "\n") catch return;
    }
}

/// Mark a codedb_query pipeline as having failed at a given step, append the
/// `received keys: [...]` diagnostic when a missing-arg error fired, and
/// emit a `--- partial ---` tail naming the failing step. Prior-step output
/// in `out` is preserved unchanged. See issue #356.
fn finishQueryWithFailure(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    step_i: usize,
    reason: []const u8,
    step_args: ?*const std.json.ObjectMap,
) void {
    if (step_args) |sa| {
        appendBundleArgKeysDiagnostic(alloc, out, sa);
    }
    const w = cio.listWriter(out, alloc);
    w.print("\n--- partial ---\nfailed_at: {d}\nreason: {s}\n", .{ step_i, reason }) catch {};
}

fn handleBundle(
    io: std.Io,
    alloc: std.mem.Allocator,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
    default_store: *Store,
    default_explorer: *Explorer,
    agents: *AgentRegistry,
    cache: *ProjectCache,
    deferred_scan: ?*DeferredScan,
    edit_agent_id: u64,
) void {
    const ops_val = args.get("ops") orelse {
        out.appendSlice(alloc, "error: missing 'ops' argument") catch {};
        appendBundleArgKeysDiagnostic(alloc, out, args);
        return;
    };
    const ops = switch (ops_val) {
        .array => |a| a.items,
        else => {
            out.appendSlice(alloc, "error: 'ops' must be an array") catch {};
            return;
        },
    };
    if (ops.len == 0) {
        out.appendSlice(alloc, "error: 'ops' array is empty") catch {};
        return;
    }
    if (ops.len > 20) {
        out.appendSlice(alloc, "error: max 20 ops per bundle") catch {};
        return;
    }

    const w = cio.listWriter(out, alloc);
    out.ensureUnusedCapacity(alloc, @min(@as(usize, 200 * 1024), 1024 + ops.len * 8192)) catch {};
    // Refresh activity accounting as we start the bundle. Long bundles can
    // include slow sub-ops, many ops, and remote fetches, so each completed
    // sub-op updates the same timestamp. See #278.
    last_activity.store(cio.milliTimestamp(), .release);
    // Bug 11: track per-op outcome so the top-level envelope can flip
    // isError=true when no op succeeded — agents reading the previous
    // success-with-per-op-errors shape took it as "the call ran fine".
    var ok_count: usize = 0;
    var fail_count: usize = 0;
    for (ops, 0..) |op, i| {
        if (op != .object) {
            w.print("--- [{d}] error ---\nerror: op must be an object\n", .{i}) catch {};
            fail_count += 1;
            continue;
        }
        const op_obj = &op.object;
        const tool_name = getStr(op_obj, "tool") orelse {
            if (op_obj.get("tool")) |_| {
                w.print("--- [{d}] error ---\nerror: 'tool' must be a string\n", .{i}) catch {};
            } else {
                w.print("--- [{d}] error ---\nerror: missing 'tool' field\n", .{i}) catch {};
            }
            fail_count += 1;
            continue;
        };

        const tool = std.meta.stringToEnum(Tool, tool_name) orelse {
            w.print("--- [{d}] {s} ---\nerror: unknown tool\n", .{ i, tool_name }) catch {};
            fail_count += 1;
            continue;
        };

        // Reject recursive bundle and write operations
        if (tool == .codedb_bundle) {
            w.print("--- [{d}] {s} ---\nerror: recursive bundle not allowed\n", .{ i, tool_name }) catch {};
            fail_count += 1;
            continue;
        }
        if (tool == .codedb_edit) {
            w.print("--- [{d}] {s} ---\nerror: write operations not allowed in bundle\n", .{ i, tool_name }) catch {};
            fail_count += 1;
            continue;
        }
        if (tool == .codedb_projects) {
            // codedb_projects lists every indexed project machine-wide — a
            // global directory enumeration unrelated to the current repo.
            // Planners that see one such call tend to replay the shape (5x
            // codedb_projects in one bundle), so block it at the dispatcher.
            // It is still callable as a standalone tool for cases where a
            // global listing genuinely is what's wanted.
            w.print("--- [{d}] {s} ---\nerror: codedb_projects not allowed in bundle\n", .{ i, tool_name }) catch {};
            fail_count += 1;
            continue;
        }

        // Extract arguments. Two supported formats:
        //   1) {"tool":"outline", "arguments":{"path":"..."}}  — MCP tools/call style
        //   2) {"tool":"outline", "path":"..."}                 — inline args
        // Issue #424: if `arguments` is present but empty (`{}`), fall
        // through to inline-args mode. Some buggy client wrappers emit
        // empty `arguments` alongside inline args; treating the empty
        // object as authoritative would silently drop the real args.
        var sub_args_val: std.json.Value = undefined;
        var sub_args_ptr: ?*const std.json.ObjectMap = null;
        if (op_obj.get("arguments")) |arguments_val| {
            if (arguments_val != .object) {
                w.print("--- [{d}] {s} ---\nerror: arguments must be object\n", .{ i, tool_name }) catch {};
                fail_count += 1;
                continue;
            }
            if (arguments_val.object.count() == 0) {
                // Empty `arguments` — try inline args at the op level.
                sub_args_ptr = op_obj;
            } else {
                sub_args_val = arguments_val;
                sub_args_ptr = &sub_args_val.object;
            }
        } else {
            // No "arguments" key — use op_obj directly (inline arg format)
            sub_args_ptr = op_obj;
        }
        const sub_args = sub_args_ptr.?;

        var sub_out: std.ArrayList(u8) = .empty;
        defer sub_out.deinit(alloc);
        const sub_reserve: usize = switch (tool) {
            .codedb_outline => 24 * 1024,
            .codedb_search, .codedb_word, .codedb_callers => 4 * 1024,
            .codedb_tree, .codedb_snapshot => 64 * 1024,
            else => 1024,
        };
        sub_out.ensureTotalCapacity(alloc, sub_reserve) catch {};

        dispatch(io, alloc, tool, sub_args, &sub_out, default_store, default_explorer, agents, cache, deferred_scan, edit_agent_id);

        // Check size BEFORE appending to prevent blowout
        if (out.items.len + sub_out.items.len > 200 * 1024) {
            w.print("--- [{d}] {s} ---\nTRUNCATED: adding this result would exceed 200KB. Use codedb_outline + targeted reads instead of full file reads.\n", .{ i, tool_name }) catch {};
            fail_count += 1;
            // Issue #413: surface a per-index marker for every op the bundle
            // dropped after truncation, so callers can correlate by index
            // instead of silently losing ops > i.
            var dropped_idx: usize = i + 1;
            while (dropped_idx < ops.len) : (dropped_idx += 1) {
                w.print("--- [{d}] dropped ---\nOPS_DROPPED: response cap reached; this op was not executed.\n", .{dropped_idx}) catch {};
                fail_count += 1;
            }
            break;
        }

        w.print("--- [{d}] {s} ---\n", .{ i, tool_name }) catch {};
        out.appendSlice(alloc, sub_out.items) catch {};
        // Issue #357 / #423: per-tool handlers already append the
        // `received keys` diagnostic on missing-arg errors, so the bundle
        // wrapper does NOT re-append it. Doing so emits the line twice.
        if (std.mem.startsWith(u8, sub_out.items, "error:")) {
            fail_count += 1;
        } else {
            ok_count += 1;
        }
        w.writeAll("\n") catch {};

        // Per-op activity refresh — see top of this fn.
        last_activity.store(cio.milliTimestamp(), .release);
    }
    // Bug 11: if every op errored, surface that at the envelope level so the
    // outer isError flag flips. Pre-fix the response was "isError:false" with
    // per-op errors buried in the body — agents read it as success.
    if (ok_count == 0 and fail_count > 0) {
        var prefix_buf: [128]u8 = undefined;
        const prefix = std.fmt.bufPrint(&prefix_buf, "error: all {d} bundle op(s) failed\n", .{fail_count}) catch "error: all bundle ops failed\n";
        out.insertSlice(alloc, 0, prefix) catch {};
    }
}

fn isRemoteRepoChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.';
}

fn isRemoteRepoPart(part: []const u8) bool {
    if (part.len == 0) return false;
    if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    for (part) |c| {
        if (!isRemoteRepoChar(c)) return false;
    }
    return true;
}

fn appendSlugChar(out: []u8, len: *usize, c: u8, last_dash: *bool) void {
    const lower = std.ascii.toLower(c);
    if ((lower >= 'a' and lower <= 'z') or (lower >= '0' and lower <= '9')) {
        out[len.*] = lower;
        len.* += 1;
        last_dash.* = false;
    } else if (!last_dash.* and len.* > 0) {
        out[len.*] = '-';
        len.* += 1;
        last_dash.* = true;
    }
}

fn ingestSlugForOwnerRepo(owner: []const u8, repo: []const u8, buf: []u8) ?[]const u8 {
    if (!isRemoteRepoPart(owner) or !isRemoteRepoPart(repo)) return null;

    var len: usize = 0;
    var last_dash = false;
    for (owner) |c| appendSlugChar(buf, &len, c, &last_dash);
    appendSlugChar(buf, &len, '-', &last_dash);
    for (repo) |c| appendSlugChar(buf, &len, c, &last_dash);
    if (len > 0 and buf[len - 1] == '-') len -= 1;
    if (len == 0) return null;
    return buf[0..len];
}

fn wikiSlugForRepo(repo: []const u8, buf: []u8) ?[]const u8 {
    if (repo.len == 0 or repo.len >= buf.len or repo[0] == '/') return null;
    if (std.mem.indexOf(u8, repo, "..") != null or
        std.mem.indexOf(u8, repo, "//") != null)
    {
        return null;
    }

    if (std.mem.indexOfScalar(u8, repo, '/')) |slash_pos| {
        if (std.mem.indexOfScalarPos(u8, repo, slash_pos + 1, '/') != null) return null;
        return ingestSlugForOwnerRepo(repo[0..slash_pos], repo[slash_pos + 1 ..], buf);
    }

    if (!isRemoteRepoPart(repo)) return null;
    @memcpy(buf[0..repo.len], repo);
    return buf[0..repo.len];
}

test "wikiSlugForRepo normalizes owner repo and raw slugs" {
    var buf: [256]u8 = undefined;

    try testing.expectEqualStrings("justrach-codedb", wikiSlugForRepo("justrach/codedb", buf[0..]).?);
    try testing.expectEqualStrings("vercel-next-js", wikiSlugForRepo("vercel/next.js", buf[0..]).?);
    try testing.expectEqualStrings("owner-repo-name", wikiSlugForRepo("OWNER/Repo.Name", buf[0..]).?);
    try testing.expectEqualStrings("chromium", wikiSlugForRepo("chromium", buf[0..]).?);
}

test "remote repo validation rejects traversal and malformed paths" {
    var buf: [256]u8 = undefined;

    try testing.expect(wikiSlugForRepo("chromium", buf[0..]) != null);
    try testing.expect(wikiSlugForRepo("../codedb", buf[0..]) == null);
    try testing.expect(wikiSlugForRepo("justrach//codedb", buf[0..]) == null);
    try testing.expect(wikiSlugForRepo("justrach/codedb/extra", buf[0..]) == null);
}

const RemoteParam = struct { name: []const u8, value: []const u8 };

/// Run `curl -G` against URL with optional query params. Caller frees result.stdout/stderr.
const RemoteResponse = struct {
    captured: cio.CaptureResult,
    /// HTTP status code (0 = curl failed before -w fired / sentinel not found).
    status: u16,
    /// Length of the response body within `captured.stdout`. The body is
    /// `captured.stdout[0..body_len]`; the suffix is the curl status sentinel.
    body_len: usize,
};

const STATUS_SENTINEL = "[CODEDB-STATUS]";

/// Run `curl -G` against URL with optional query params. Captures HTTP status
/// via `-w` and lets non-2xx responses through (no `-f`) so callers can format
/// detailed errors. Caller frees response.captured.stdout/stderr.
fn fetchRemote(
    alloc: std.mem.Allocator,
    url: []const u8,
    params: []const RemoteParam,
) !RemoteResponse {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);

    try argv.append(alloc, "curl");
    try argv.append(alloc, "-s");
    try argv.append(alloc, "--max-time");
    try argv.append(alloc, "30");
    try argv.append(alloc, "-w");
    try argv.append(alloc, "\n" ++ STATUS_SENTINEL ++ "%{http_code}");

    var pair_bufs: std.ArrayList([]u8) = .empty;
    defer {
        for (pair_bufs.items) |b| alloc.free(b);
        pair_bufs.deinit(alloc);
    }

    if (params.len > 0) {
        try argv.append(alloc, "-G");
        try pair_bufs.ensureTotalCapacity(alloc, params.len);
        for (params) |p| {
            const buf = try std.fmt.allocPrint(alloc, "{s}={s}", .{ p.name, p.value });
            try pair_bufs.append(alloc, buf);
            try argv.append(alloc, "--data-urlencode");
            try argv.append(alloc, buf);
        }
    }
    try argv.append(alloc, url);

    const captured = try cio.runCapture(.{ .allocator = alloc, .argv = argv.items });

    var status: u16 = 0;
    var body_len: usize = captured.stdout.len;
    if (std.mem.lastIndexOf(u8, captured.stdout, STATUS_SENTINEL)) |sentinel_idx| {
        const status_str = std.mem.trim(u8, captured.stdout[sentinel_idx + STATUS_SENTINEL.len ..], " \r\n\t");
        status = std.fmt.parseInt(u16, status_str, 10) catch 0;
        // Strip the trailing "\n[CODEDB-STATUS]NNN" from the body view.
        var end = sentinel_idx;
        while (end > 0 and captured.stdout[end - 1] == '\n') end -= 1;
        body_len = end;
    }

    return .{ .captured = captured, .status = status, .body_len = body_len };
}

fn handleRemote(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8)) void {
    const repo = getStr(args, "repo") orelse {
        out.appendSlice(alloc, "error: missing 'repo' (e.g. justrach/merjs)") catch {};
        return;
    };
    const action = getStr(args, "action") orelse {
        out.appendSlice(alloc, "error: missing 'action' (actions, tree, outline, search, read, symbol, policy, deps, score, cves, commits, branches, dep-history)") catch {};
        return;
    };

    // api.wiki.codes is the remote backend. Keep backend=wiki as a tolerated
    // compatibility arg, but never route elsewhere.
    if (getStr(args, "backend")) |backend| {
        if (!std.mem.eql(u8, backend, "wiki")) {
            out.appendSlice(alloc, "error: invalid backend, only 'wiki' / api.wiki.codes is supported") catch {};
            return;
        }
    }

    const wiki_actions = [_][]const u8{
        "tree",
        "outline",
        "search",
        "read",
        "symbol",
        "policy",
        "deps",
        "score",
        "cves",
        "commits",
        "branches",
        "dep-history",
        "actions",
    };
    var action_valid = false;
    for (&wiki_actions) |va| {
        if (std.mem.eql(u8, action, va)) {
            action_valid = true;
            break;
        }
    }
    if (!action_valid) {
        out.appendSlice(alloc, "error: action '") catch {};
        out.appendSlice(alloc, action) catch {};
        out.appendSlice(alloc, "' not supported by api.wiki.codes (supports: tree, outline, search, read, symbol, policy, deps, score, cves, commits, branches, dep-history, actions)") catch {};
        return;
    }

    var wiki_slug_buf: [256]u8 = undefined;
    const wiki_slug = wikiSlugForRepo(repo, wiki_slug_buf[0..]) orelse {
        out.appendSlice(alloc, "error: invalid wiki repo, use owner/repo or raw wiki slug (e.g. vercel/next.js or chromium)") catch {};
        return;
    };

    const query = getStr(args, "query");

    // Require a non-empty 'query' for actions that consume it. Sending an
    // empty value silently masked real user mistakes.
    const needs_query = std.mem.eql(u8, action, "search") or
        std.mem.eql(u8, action, "symbol") or
        std.mem.eql(u8, action, "outline");
    if (needs_query and (query == null or query.?.len == 0)) {
        out.appendSlice(alloc, "error: action '") catch {};
        out.appendSlice(alloc, action) catch {};
        if (std.mem.eql(u8, action, "search")) {
            out.appendSlice(alloc, "' requires a non-empty 'query' (the search text)") catch {};
        } else if (std.mem.eql(u8, action, "symbol")) {
            out.appendSlice(alloc, "' requires a non-empty 'query' (the identifier name to look up)") catch {};
        } else {
            out.appendSlice(alloc, "' requires a non-empty 'query' (the file path to outline)") catch {};
        }
        return;
    }

    // 'read' takes the file path via a dedicated `path` arg so the schema is
    // explicit; outline keeps the legacy `query`-as-path overload.
    const path_arg = getStr(args, "path");
    if (std.mem.eql(u8, action, "read") and (path_arg == null or path_arg.?.len == 0)) {
        out.appendSlice(alloc, "error: action 'read' requires a non-empty 'path' (the file path to fetch)") catch {};
        return;
    }

    var scope_value: []const u8 = "runtime";
    if (std.mem.eql(u8, action, "score") or std.mem.eql(u8, action, "cves")) {
        scope_value = getStr(args, "scope") orelse query orelse "runtime";
        if (!std.mem.eql(u8, scope_value, "runtime") and !std.mem.eql(u8, scope_value, "all")) {
            out.appendSlice(alloc, "error: scope must be 'runtime' or 'all'") catch {};
            return;
        }
    }

    var url_buf: [512]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "https://api.wiki.codes/api/{s}/{s}", .{ wiki_slug, action }) catch {
        out.appendSlice(alloc, "error: URL too long") catch {};
        return;
    };

    // Build the URL params list. Action-specific arg first, then optional
    // pagination/filter params. Server is free to ignore unknown keys.
    var int_bufs: [4][32]u8 = undefined;
    var int_slot: usize = 0;
    var params: std.ArrayList(RemoteParam) = .empty;
    defer params.deinit(alloc);

    if (std.mem.eql(u8, action, "search")) {
        if (query) |q| params.append(alloc, .{ .name = "q", .value = q }) catch {};
    } else if (std.mem.eql(u8, action, "symbol")) {
        if (query) |q| params.append(alloc, .{ .name = "name", .value = q }) catch {};
    } else if (std.mem.eql(u8, action, "outline")) {
        if (query) |q| params.append(alloc, .{ .name = "path", .value = q }) catch {};
    } else if (std.mem.eql(u8, action, "read")) {
        if (path_arg) |p| params.append(alloc, .{ .name = "path", .value = p }) catch {};
        if (getStr(args, "lines")) |l| {
            if (l.len > 0) params.append(alloc, .{ .name = "lines", .value = l }) catch {};
        }
    } else if (std.mem.eql(u8, action, "score") or std.mem.eql(u8, action, "cves")) {
        params.append(alloc, .{ .name = "scope", .value = scope_value }) catch {};
    }

    // Optional pagination/filter params. Forward them consistently for every
    // action whose wiki endpoint can page or cap large arrays.
    const takes_limit = std.mem.eql(u8, action, "search") or
        std.mem.eql(u8, action, "tree") or
        std.mem.eql(u8, action, "deps") or
        std.mem.eql(u8, action, "commits") or
        std.mem.eql(u8, action, "branches") or
        std.mem.eql(u8, action, "dep-history");
    const takes_offset = std.mem.eql(u8, action, "tree") or
        std.mem.eql(u8, action, "deps") or
        std.mem.eql(u8, action, "commits") or
        std.mem.eql(u8, action, "branches") or
        std.mem.eql(u8, action, "dep-history");

    if (takes_limit) {
        if (getInt(args, "limit")) |n| {
            const s = std.fmt.bufPrint(int_bufs[int_slot][0..], "{d}", .{@max(0, n)}) catch "0";
            params.append(alloc, .{ .name = "limit", .value = s }) catch {};
            int_slot += 1;
        }
    }
    if (takes_offset) {
        if (getInt(args, "offset")) |n| {
            const s = std.fmt.bufPrint(int_bufs[int_slot][0..], "{d}", .{@max(0, n)}) catch "0";
            params.append(alloc, .{ .name = "offset", .value = s }) catch {};
            int_slot += 1;
        }
    }

    if (std.mem.eql(u8, action, "tree")) {
        if (getStr(args, "prefix")) |v| {
            if (v.len > 0) params.append(alloc, .{ .name = "prefix", .value = v }) catch {};
        }
        if (args.get("expand")) |expand_val| {
            switch (expand_val) {
                .bool => |expand| {
                    if (expand) {
                        params.append(alloc, .{ .name = "expand", .value = "true" }) catch {};
                    } else {
                        params.append(alloc, .{ .name = "summary", .value = "true" }) catch {};
                    }
                },
                else => {},
            }
        }
    } else if (std.mem.eql(u8, action, "commits") or std.mem.eql(u8, action, "dep-history")) {
        if (getStr(args, "since")) |v| {
            if (v.len > 0) params.append(alloc, .{ .name = "since", .value = v }) catch {};
        }
    }

    const remote = fetchRemote(alloc, url, params.items) catch {
        out.appendSlice(alloc, "error: failed to fetch from api.wiki.codes") catch {};
        return;
    };
    defer alloc.free(remote.captured.stdout);
    defer alloc.free(remote.captured.stderr);

    const body = remote.captured.stdout[0..remote.body_len];

    // 2xx = success, anything else gets a status-tagged error so callers can
    // tell 404 (slug missing this artifact) from 5xx (real server bug).
    if (remote.status >= 200 and remote.status < 300) {
        out.appendSlice(alloc, body) catch {};
        return;
    }

    out.appendSlice(alloc, "error: ") catch {};
    out.appendSlice(alloc, "api.wiki.codes") catch {};
    if (remote.status == 0) {
        out.appendSlice(alloc, " transport error for ") catch {};
    } else {
        var status_buf: [8]u8 = undefined;
        const s = std.fmt.bufPrint(&status_buf, "{d}", .{remote.status}) catch "0";
        out.appendSlice(alloc, " HTTP ") catch {};
        out.appendSlice(alloc, s) catch {};
        out.appendSlice(alloc, " for ") catch {};
    }
    out.appendSlice(alloc, wiki_slug) catch {};
    out.appendSlice(alloc, "/") catch {};
    out.appendSlice(alloc, action) catch {};
    if (body.len > 0) {
        out.appendSlice(alloc, " — ") catch {};
        out.appendSlice(alloc, body[0..@min(body.len, 200)]) catch {};
    } else if (remote.captured.stderr.len > 0) {
        out.appendSlice(alloc, " — ") catch {};
        out.appendSlice(alloc, remote.captured.stderr[0..@min(remote.captured.stderr.len, 200)]) catch {};
    }

    // #508: actionable hint based on the HTTP status / Cloudflare body.
    // Distinguishes "service down" (530 + Cloudflare 1033/1034) from
    // "repo or path not indexed" (404) from "rate limited" (429) so
    // agents and humans can decide whether to retry or take a different
    // path (e.g. clone the repo locally) without parsing the raw error.
    appendRemoteErrorHint(alloc, out, remote.status, body);
}

pub fn appendRemoteErrorHint(alloc: std.mem.Allocator, out: *std.ArrayList(u8), status: u16, body: []const u8) void {
    const has_cf_origin_down =
        std.mem.indexOf(u8, body, "error code: 1033") != null or
        std.mem.indexOf(u8, body, "error code: 1034") != null or
        std.mem.indexOf(u8, body, "Argo Tunnel error") != null;

    const hint: ?[]const u8 = switch (status) {
        530 => if (has_cf_origin_down)
            "\n  hint: api.wiki.codes origin is unreachable (Cloudflare). The service is temporarily down — retry in a few minutes, or query the repo locally via `codedb_index` after cloning."
        else
            "\n  hint: upstream returned 530. Retry in a few minutes; if it persists, the repo may not be indexed.",
        404 => "\n  hint: repo or path not indexed by api.wiki.codes. Verify the slug, or clone + `codedb_index` locally.",
        429 => "\n  hint: rate limited by api.wiki.codes. Wait and retry, or batch fewer requests.",
        500, 502, 503 => "\n  hint: upstream server error. Retry — if it persists, the service is having a bad time.",
        504 => "\n  hint: upstream gateway timeout. Retry; the wiki may still be indexing this repo.",
        else => null,
    };
    if (hint) |h| out.appendSlice(alloc, h) catch {};
}

// ── Local project tools ─────────────────────────────────────────────────────

fn handleProjects(io: std.Io, alloc: std.mem.Allocator, out: *std.ArrayList(u8)) void {
    const home = cio.posixGetenv("HOME") orelse {
        out.appendSlice(alloc, "error: cannot read HOME") catch {};
        return;
    };

    const projects_dir = std.fmt.allocPrint(alloc, "{s}/.codedb/projects", .{home}) catch {
        out.appendSlice(alloc, "error: alloc failed") catch {};
        return;
    };
    defer alloc.free(projects_dir);

    var dir = std.Io.Dir.cwd().openDir(io, projects_dir, .{ .iterate = true }) catch {
        out.appendSlice(alloc, "no indexed projects found") catch {};
        return;
    };
    defer dir.close(io);

    var count: u32 = 0;
    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;

        // Read project.txt to get the project path
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const sub_path = std.fmt.bufPrint(&path_buf, "{s}/project.txt", .{entry.name}) catch continue;
        const project_file = dir.openFile(io, sub_path, .{}) catch continue;
        defer project_file.close(io);
        var content_buf: [4096]u8 = undefined;
        const n = project_file.readPositionalAll(io, &content_buf, 0) catch continue;
        if (n == 0) continue;
        const project_path = content_buf[0..n];

        // Check if snapshot exists in the project directory
        var snap_exists = false;
        var snap_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const snap_path = std.fmt.bufPrint(&snap_path_buf, "{s}/codedb.snapshot", .{project_path}) catch project_path;
        if (std.Io.Dir.cwd().access(io, snap_path, .{})) |_| {
            snap_exists = true;
        } else |_| {}

        if (count > 0) out.appendSlice(alloc, "\n") catch {};
        out.appendSlice(alloc, project_path) catch {};
        if (snap_exists) {
            out.appendSlice(alloc, "  [snapshot]") catch {};
        }
        count += 1;
    }

    if (count == 0) {
        out.appendSlice(alloc, "no indexed projects found") catch {};
    }
}

fn handleIndex(
    io: std.Io,
    alloc: std.mem.Allocator,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
    cache: *ProjectCache,
    default_store: *Store,
    default_explorer: *Explorer,
    deferred_scan: ?*DeferredScan,
) void {
    const path = getStr(args, "path") orelse {
        out.appendSlice(alloc, "error: missing 'path'") catch {};
        appendBundleArgKeysDiagnostic(alloc, out, args);
        return;
    };

    // Resolve to absolute path
    var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_len = std.Io.Dir.cwd().realPathFile(io, path, &abs_buf) catch {
        out.appendSlice(alloc, "error: cannot resolve path: ") catch {};
        out.appendSlice(alloc, path) catch {};
        return;
    };
    const abs_path = abs_buf[0..abs_len];
    if (!root_policy.isIndexableRoot(abs_path)) {
        out.appendSlice(alloc, "error: refusing to index temporary root: ") catch {};
        out.appendSlice(alloc, abs_path) catch {};
        return;
    }

    // Verify it's a directory
    var check_dir = std.Io.Dir.cwd().openDir(io, abs_path, .{}) catch {
        out.appendSlice(alloc, "error: not a directory: ") catch {};
        out.appendSlice(alloc, abs_path) catch {};
        return;
    };
    check_dir.close(io);

    // Get the codedb binary path (argv[0] equivalent — use /proc/self or just "codedb")
    // We spawn `codedb <path> snapshot` to create the snapshot
    const exe_path = std.process.executablePathAlloc(io, alloc) catch {
        out.appendSlice(alloc, "error: cannot find codedb binary") catch {};
        return;
    };
    defer alloc.free(exe_path);

    const snapshot_path = std.fmt.allocPrint(alloc, "{s}/codedb.snapshot", .{abs_path}) catch {
        out.appendSlice(alloc, "error: alloc failed") catch {};
        return;
    };
    defer alloc.free(snapshot_path);

    const result = cio.runCapture(.{
        .allocator = alloc,
        .argv = &.{ exe_path, abs_path, "snapshot", snapshot_path },
        .max_output_bytes = 64 * 1024,
    }) catch {
        out.appendSlice(alloc, "error: failed to run indexer") catch {};
        return;
    };
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    if (result.term.Exited != 0) {
        out.appendSlice(alloc, "error: indexing failed for ") catch {};
        out.appendSlice(alloc, abs_path) catch {};
        if (result.stderr.len > 0) {
            out.appendSlice(alloc, " — ") catch {};
            out.appendSlice(alloc, result.stderr[0..@min(result.stderr.len, 300)]) catch {};
        }
        return;
    }

    cache.invalidate(abs_path);
    if (std.mem.eql(u8, abs_path, cache.default_path) and
        default_store.currentSeq() == 0 and
        getScanState() == .loading_snapshot)
    {
        default_explorer.setRoot(io, abs_path);
        if (snapshot_mod.loadSnapshot(io, snapshot_path, default_explorer, default_store, alloc)) {
            loadProjectTrigramFromDiskIfPresent(io, default_explorer, abs_path, alloc);
            if (default_explorer.outlines.count() > 1000) {
                default_explorer.releaseContents();
                default_explorer.releaseSecondaryIndexes();
            }
            setScanState(.ready);
            if (deferred_scan) |ds| {
                ds.resolved_root = cache.default_path;
                ds.triggered.store(true, .release);
                ds.scan_done.store(true, .release);
            }
        }
    }

    out.appendSlice(alloc, "indexed: ") catch {};
    out.appendSlice(alloc, abs_path) catch {};
    if (result.stdout.len > 0) {
        out.appendSlice(alloc, "\n") catch {};
        // Strip ANSI escape sequences
        var i: usize = 0;
        while (i < result.stdout.len) {
            if (result.stdout[i] == 0x1b) {
                i += 1;
                if (i < result.stdout.len and result.stdout[i] == '[') {
                    // CSI sequence: skip until final byte (0x40-0x7E per ECMA-48)
                    i += 1;
                    while (i < result.stdout.len) {
                        const ch = result.stdout[i];
                        i += 1;
                        if (ch >= 0x40 and ch <= 0x7E) break;
                    }
                } else if (i < result.stdout.len) {
                    // Fe sequence (ESC + one byte) — skip
                    i += 1;
                }
                // Lone ESC at end — already skipped by i += 1 above
            } else {
                out.append(alloc, result.stdout[i]) catch {};
                i += 1;
            }
        }
    }
}

// True when `q` is a single compound identifier — camelCase/PascalCase (an
// interior uppercase alongside a lowercase) or snake_case (an underscore) — and
// contains only identifier characters (no space, path separator, glob, dot, or
// colon). These queries are almost always symbol names, not filenames, and are
// exactly the ones that miss the exact-filename fast path and fall into the slow
// fuzzy scan. ALL-CAPS (e.g. README) is excluded so filename-ish tokens stay on
// the fuzzy path.
pub fn looksLikeCompoundIdentifier(q: []const u8) bool {
    if (q.len < 4) return false;
    var inner_upper = false;
    var has_lower = false;
    var has_underscore = false;
    for (q, 0..) |c, i| {
        switch (c) {
            'A'...'Z' => if (i > 0) {
                inner_upper = true;
            },
            'a'...'z' => has_lower = true,
            '_' => has_underscore = true,
            '0'...'9' => {},
            else => return false, // space, '/', '.', '*', '?', ':', etc.
        }
    }
    return (inner_upper and has_lower) or has_underscore;
}

fn handleFind(io: std.Io, alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8), explorer: *Explorer) void {
    // Telemetry showed 71% of codedb_find calls were failing with
    // "missing 'query'" — agents were passing `name`/`path`/`pattern`/`q`
    // instead, misled by the "FILE-NAME search" framing. Accept aliases.
    const query = getStr(args, "query") orelse getStr(args, "name") orelse getStr(args, "path") orelse getStr(args, "pattern") orelse getStr(args, "q") orelse {
        out.appendSlice(alloc, "error: missing 'query' (also accepted: 'name', 'path', 'pattern', 'q')") catch {};
        appendBundleArgKeysDiagnostic(alloc, out, args);
        return;
    };
    if (query.len == 0) {
        out.appendSlice(alloc, "error: empty query") catch {};
        return;
    }

    const max_results: usize = if (args.get("max_results")) |v| switch (v) {
        .integer => |i| @intCast(@max(1, @min(i, 50))),
        else => 10,
    } else 10;

    if (std.mem.indexOfAny(u8, query, " */?") == null) {
        out.ensureUnusedCapacity(alloc, 128) catch {};
        const exact_count = explorer.renderExactFileFind(query, alloc, out, max_results) catch 0;
        if (exact_count > 0) return;
    }

    // Symbol fast-path: a compound identifier (camelCase / snake_case) typed into
    // find is almost always a symbol the caller wants the definition of, not a
    // filename — such queries don't match filenames, so they'd otherwise pay the
    // full fuzzy scan (the slow case). If the symbol index has it, return the def
    // sites (O(1)) and skip the scan; a non-matching identifier falls through to
    // the fuzzy file search below, so legitimate filename searches are unaffected.
    if (looksLikeCompoundIdentifier(query)) {
        out.ensureUnusedCapacity(alloc, 128) catch {};
        if (explorer.renderSymbolDefsFast(query, alloc, out, max_results)) return;
    }
    var matches = explorer.fuzzyFindFiles(query, alloc, max_results) catch {
        out.appendSlice(alloc, "error: search failed") catch {};
        return;
    };
    defer alloc.free(matches);

    // Auto-retry: if no results, try broadening the query
    var broadened_buf: [256]u8 = undefined;
    if (matches.len == 0 and query.len > 3) {
        // Try stripping delimiters: auth_middleware → authmiddleware
        var blen: usize = 0;
        for (query) |c| {
            if (c != '_' and c != '-' and c != '.' and blen < broadened_buf.len) {
                broadened_buf[blen] = c;
                blen += 1;
            }
        }
        if (blen > 0 and blen != query.len) {
            const broadened = broadened_buf[0..blen];
            const retry = explorer.fuzzyFindFiles(broadened, alloc, max_results) catch null;
            if (retry) |r| {
                alloc.free(matches);
                matches = r;
            }
        }
    }
    // Combo-boost: reward files that were previously opened after similar queries
    applyComboBoosts(io, alloc, query, @constCast(matches));

    if (matches.len == 0) {
        out.appendSlice(alloc, "no matches") catch {};
        return;
    }

    for (matches, 1..) |m, rank| {
        var buf: [16]u8 = undefined;
        const rank_str = std.fmt.bufPrint(&buf, "{d}. ", .{rank}) catch continue;
        out.appendSlice(alloc, rank_str) catch {};
        out.appendSlice(alloc, m.path) catch {};
        var score_buf: [32]u8 = undefined;
        const score_str = std.fmt.bufPrint(&score_buf, " (score: {d:.2})\n", .{m.score}) catch continue;
        out.appendSlice(alloc, score_str) catch {};
    }
}

fn handleGlob(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8), explorer: *Explorer) void {
    const pattern = getStr(args, "pattern") orelse {
        out.appendSlice(alloc, "error: missing 'pattern'") catch {};
        appendBundleArgKeysDiagnostic(alloc, out, args);
        return;
    };
    if (pattern.len == 0) {
        out.appendSlice(alloc, "error: empty pattern") catch {};
        return;
    }

    const max_results: usize = if (args.get("max_results")) |v| switch (v) {
        .integer => |i| @intCast(@max(1, @min(i, 5000))),
        else => 200,
    } else 200;

    const matches = explorer.globPaths(alloc, pattern, max_results) catch {
        out.appendSlice(alloc, "error: glob failed") catch {};
        return;
    };
    defer alloc.free(matches);

    if (matches.len == 0) {
        out.appendSlice(alloc, "no matches") catch {};
        return;
    }

    for (matches) |path| {
        out.appendSlice(alloc, path) catch {};
        out.appendSlice(alloc, "\n") catch {};
    }
}

fn handleLs(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8), explorer: *Explorer) void {
    const prefix = getStr(args, "path") orelse "";

    const entries = explorer.lsDir(alloc, prefix) catch {
        out.appendSlice(alloc, "error: ls failed") catch {};
        return;
    };
    defer alloc.free(entries);

    if (entries.len == 0) {
        out.appendSlice(alloc, "no entries") catch {};
        return;
    }

    for (entries) |e| {
        if (e.is_dir) {
            out.appendSlice(alloc, e.name) catch {};
            out.appendSlice(alloc, "/\n") catch {};
        } else {
            out.appendSlice(alloc, e.name) catch {};
            var buf: [64]u8 = undefined;
            const meta = std.fmt.bufPrint(&buf, "  ({s}, {d}L, {d} sym)\n", .{
                @tagName(e.language),
                e.line_count,
                e.sym_count,
            }) catch "\n";
            out.appendSlice(alloc, meta) catch {};
        }
    }
}

/// CLI⇄MCP parity bridge. Serves the read-only navigation tools that `runQuery`
/// doesn't render natively — symbol / callers / deps / glob / ls / context and
/// the fuzzy file-name `file` lookup — by building the MCP argument map and
/// reusing the same handlers against the warm Explorer. Returns the exit code,
/// or null if `cmd` isn't one we handle (caller falls through to its own usage
/// error). The rendered data block is appended to `out`. `root` must be the
/// resolved absolute project root (used to locate the on-disk word index for
/// callers/context).
pub fn runCliTool(
    io: std.Io,
    alloc: std.mem.Allocator,
    explorer: *Explorer,
    root: []const u8,
    cmd: []const u8,
    args: []const []const u8,
    cmd_args_start: usize,
    out: *std.ArrayList(u8),
) ?u8 {
    const pos: ?[]const u8 = if (args.len > cmd_args_start) args[cmd_args_start] else null;
    const out_start = out.items.len;

    var m: std.json.ObjectMap = .empty;
    defer m.deinit(alloc);

    if (std.mem.eql(u8, cmd, "symbol")) {
        const name = pos orelse return cliUsage(alloc, out, "symbol <name> [--body]");
        m.put(alloc, "name", .{ .string = name }) catch return 1;
        for (args[cmd_args_start..]) |a| {
            if (std.mem.eql(u8, a, "--body")) m.put(alloc, "body", .{ .bool = true }) catch {};
        }
        handleSymbol(alloc, &m, out, explorer);
        return finishCli(out, out_start);
    } else if (std.mem.eql(u8, cmd, "callers")) {
        const name = pos orelse return cliUsage(alloc, out, "callers <name>");
        m.put(alloc, "name", .{ .string = name }) catch return 1;
        // handleCallers does a content search (searchContentWithScope), so it
        // needs the trigram — load the MMAP'd trigram (cheap, reclaimable), NOT
        // the heap word index. Keeps the footprint at the MCP level.
        loadProjectTrigramFromDiskIfPresent(io, explorer, root, alloc);
        handleCallers(alloc, &m, out, explorer);
        return finishCli(out, out_start);
    } else if (std.mem.eql(u8, cmd, "callpath")) {
        if (args.len < cmd_args_start + 2) return cliUsage(alloc, out, "callpath <from> <to>");
        m.put(alloc, "from", .{ .string = args[cmd_args_start] }) catch return 1;
        m.put(alloc, "to", .{ .string = args[cmd_args_start + 1] }) catch return 1;
        handleCallpath(alloc, &m, out, explorer);
        return finishCli(out, out_start);
    } else if (std.mem.eql(u8, cmd, "deps")) {
        const da = parseDepsArgs(args, cmd_args_start) catch |e| return cliDepsUsage(alloc, out, e);
        m.put(alloc, "path", .{ .string = da.path }) catch return 1;
        if (da.depends_on) m.put(alloc, "direction", .{ .string = "depends_on" }) catch {};
        if (da.transitive) m.put(alloc, "transitive", .{ .bool = true }) catch {};
        if (da.max_depth) |md| m.put(alloc, "max_depth", .{ .integer = md }) catch {};
        handleDeps(alloc, &m, out, explorer);
        return finishCli(out, out_start);
    } else if (std.mem.eql(u8, cmd, "glob")) {
        const pattern = pos orelse return cliUsage(alloc, out, "glob <pattern>");
        m.put(alloc, "pattern", .{ .string = pattern }) catch return 1;
        handleGlob(alloc, &m, out, explorer);
        return finishCli(out, out_start);
    } else if (std.mem.eql(u8, cmd, "ls")) {
        if (pos) |p| m.put(alloc, "path", .{ .string = p }) catch return 1;
        handleLs(alloc, &m, out, explorer);
        return finishCli(out, out_start);
    } else if (std.mem.eql(u8, cmd, "file")) {
        const query = pos orelse return cliUsage(alloc, out, "file <fuzzy-name>");
        m.put(alloc, "query", .{ .string = query }) catch return 1;
        handleFind(io, alloc, &m, out, explorer);
        return finishCli(out, out_start);
    } else if (std.mem.eql(u8, cmd, "context")) {
        var task: std.ArrayList(u8) = .empty;
        defer task.deinit(alloc);
        var i = cmd_args_start;
        while (i < args.len) : (i += 1) {
            if (i > cmd_args_start) task.append(alloc, ' ') catch {};
            task.appendSlice(alloc, args[i]) catch {};
        }
        if (task.items.len == 0) return cliUsage(alloc, out, "context <task...>");
        m.put(alloc, "task", .{ .string = task.items }) catch return 1;
        loadProjectWordIndexFromDiskIfPresent(io, explorer, root, alloc);
        handleContext(io, alloc, &m, out, explorer, root);
        return finishCli(out, out_start);
    }
    return null;
}

fn cliUsage(alloc: std.mem.Allocator, out: *std.ArrayList(u8), usage: []const u8) u8 {
    out.appendSlice(alloc, "usage: codedb [root] ") catch {};
    out.appendSlice(alloc, usage) catch {};
    out.appendSlice(alloc, "\n") catch {};
    return 1;
}

/// Exit code for a bridged handler: 1 if it appended an `error:`-prefixed
/// message (the same failure marker MCP uses to set `isError` — see the
/// `startsWith(out.items, "error:")` checks elsewhere in this file), else 0.
/// Fixes #528 item 6, where bridged handlers printed `error: …` to stdout but
/// `runCliTool` always reported success, so scripts couldn't detect failures.
/// Zero-result paths (e.g. find's "no matches") use non-`error:` wording and
/// therefore keep exit 0.
pub fn finishCli(out: *std.ArrayList(u8), start: usize) u8 {
    return if (std.mem.startsWith(u8, out.items[start..], "error:")) 1 else 0;
}
/// Parsed `deps` invocation. `max_depth` stays null unless `--max-depth N` was
/// given so the handler keeps its own default for transitive walks.
pub const DepsArgs = struct {
    path: []const u8,
    depends_on: bool = false,
    transitive: bool = false,
    max_depth: ?i64 = null,
};

pub const DepsArgError = error{ MissingPath, UnknownFlag, MissingMaxDepth, BadMaxDepth, ExtraArg };

/// Parse `deps` args. Flags (`--depends-on`, `--transitive`, `--max-depth N`)
/// may appear before or after the path, in any order; the first non-flag token
/// is the path (so `deps --depends-on src/main.zig` no longer misreads the flag
/// as the path). Unknown flags are rejected instead of silently ignored, and
/// `--max-depth` must be a positive integer instead of coercing junk to 1.
/// See issue #528 (items 2, 11).
pub fn parseDepsArgs(args: []const []const u8, start: usize) DepsArgError!DepsArgs {
    var result: DepsArgs = .{ .path = "" };
    var path: ?[]const u8 = null;
    var i = start;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--depends-on")) {
            result.depends_on = true;
        } else if (std.mem.eql(u8, a, "--transitive")) {
            result.transitive = true;
        } else if (std.mem.eql(u8, a, "--max-depth")) {
            if (i + 1 >= args.len) return error.MissingMaxDepth;
            i += 1;
            const n = std.fmt.parseInt(i64, args[i], 10) catch return error.BadMaxDepth;
            if (n < 1) return error.BadMaxDepth;
            result.max_depth = n;
        } else if (a.len > 1 and a[0] == '-' and a[1] == '-') {
            return error.UnknownFlag;
        } else if (path == null) {
            path = a;
        } else {
            return error.ExtraArg;
        }
    }
    result.path = path orelse return error.MissingPath;
    return result;
}

fn cliDepsUsage(alloc: std.mem.Allocator, out: *std.ArrayList(u8), e: DepsArgError) u8 {
    const msg = switch (e) {
        error.MissingPath => "error: usage: codedb [root] deps <path> [--depends-on] [--transitive] [--max-depth N]",
        error.UnknownFlag => "error: unknown flag for deps (valid: --depends-on, --transitive, --max-depth N)",
        error.MissingMaxDepth, error.BadMaxDepth => "error: --max-depth requires a positive integer",
        error.ExtraArg => "error: unexpected extra argument for deps",
    };
    out.appendSlice(alloc, msg) catch {};
    out.appendSlice(alloc, "\n") catch {};
    return 1;
}

const COMBO_WINDOW_MS: i64 = 5000; // 5 second window between query and file open
const COMBO_BOOST_PER_HIT: f32 = 5.0; // score boost per historical open

fn applyComboBoosts(io: std.Io, alloc: std.mem.Allocator, query: []const u8, matches: []explore_mod.Explorer.FuzzyMatch) void {
    const wal_path = query_log_path orelse return;
    const data = std.Io.Dir.cwd().readFileAlloc(io, wal_path, alloc, .limited(512 * 1024)) catch return;
    defer alloc.free(data);

    // Scan WAL for query→access pairs within COMBO_WINDOW_MS
    var boosts = std.StringHashMap(f32).init(alloc);
    defer boosts.deinit();

    var last_query_ts: i64 = 0;
    var last_query_match = false;

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (line.len < 10) continue;

        if (std.mem.indexOf(u8, line, "\"ev\":\"query\"")) |_| {
            // Check if this query matches the current one (case-insensitive substring)
            var qbuf: [256]u8 = undefined;
            if (extractJsonStrLocal(line, "query", &qbuf)) |logged_query| {
                last_query_match = std.mem.indexOf(u8, logged_query, query) != null or
                    std.mem.indexOf(u8, query, logged_query) != null;
            } else {
                last_query_match = false;
            }
            last_query_ts = extractJsonIntLocal(line, "ts") orelse 0;
        } else if (std.mem.indexOf(u8, line, "\"ev\":\"access\"")) |_| {
            if (!last_query_match) continue;
            const access_ts = extractJsonIntLocal(line, "ts") orelse continue;
            if (access_ts - last_query_ts > COMBO_WINDOW_MS) continue;

            var pbuf: [256]u8 = undefined;
            if (extractJsonStrLocal(line, "path", &pbuf)) |path| {
                const gop = boosts.getOrPut(path) catch continue;
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* += COMBO_BOOST_PER_HIT;
            }
        }
    }

    if (boosts.count() == 0) return;

    // Apply boosts to matching results
    var boosted = false;
    for (matches) |*m| {
        if (boosts.get(m.path)) |boost| {
            m.score += boost;
            boosted = true;
        }
    }

    // Re-sort if any scores changed
    if (boosted) {
        std.mem.sort(explore_mod.Explorer.FuzzyMatch, matches, {}, struct {
            fn lt(_: void, a: explore_mod.Explorer.FuzzyMatch, b: explore_mod.Explorer.FuzzyMatch) bool {
                return a.score > b.score;
            }
        }.lt);
    }
}

fn extractJsonIntLocal(line: []const u8, key: []const u8) ?i64 {
    var search_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&search_buf, "\"{s}\":", .{key}) catch return null;
    const pos = std.mem.indexOf(u8, line, needle) orelse return null;
    const start = pos + needle.len;
    var end = start;
    while (end < line.len and (line[end] >= '0' and line[end] <= '9')) : (end += 1) {}
    if (end == start) return null;
    return std.fmt.parseInt(i64, line[start..end], 10) catch null;
}

fn extractJsonStrLocal(line: []const u8, key: []const u8, out: *[256]u8) ?[]const u8 {
    var search_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&search_buf, "\"{s}\":\"", .{key}) catch return null;
    const pos = std.mem.indexOf(u8, line, needle) orelse return null;
    const start = pos + needle.len;
    const end = std.mem.indexOfScalarPos(u8, line, start, '"') orelse return null;
    const len = @min(end - start, out.len);
    @memcpy(out[0..len], line[start..][0..len]);
    return out[0..len];
}

fn handleQuery(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8), explorer: *Explorer, store: *Store) void {
    _ = store;
    const pipeline_val = args.get("pipeline") orelse {
        out.appendSlice(alloc, "error: missing 'pipeline' array") catch {};
        appendBundleArgKeysDiagnostic(alloc, out, args);
        return;
    };
    const pipeline = switch (pipeline_val) {
        .array => |a| a.items,
        else => {
            out.appendSlice(alloc, "error: 'pipeline' must be an array") catch {};
            return;
        },
    };
    if (pipeline.len == 0 or pipeline.len > 10) {
        out.appendSlice(alloc, "error: pipeline must have 1-10 steps") catch {};
        return;
    }

    var file_set: std.ArrayList([]const u8) = .empty;
    defer file_set.deinit(alloc);
    var have_set = false;
    const w = cio.listWriter(out, alloc);

    // Issue #356-p3: per-stage summary so long pipelines are debuggable
    // without re-parsing the unstructured per-step output above the tail.
    const StageInfo = struct { op: []const u8, files_out: usize };
    var stages: std.ArrayList(StageInfo) = .empty;
    defer stages.deinit(alloc);

    for (pipeline, 0..) |step_val, step_i| {
        if (step_val != .object) {
            w.print("error: step {d} must be object\n", .{step_i}) catch {};
            return;
        }
        const step = &step_val.object;
        const op = getStr(step, "op") orelse blk: {
            // Auto-detect op when 'op' key is missing.
            // query → search, word → word, name → symbol
            if (getStr(step, "query") != null) break :blk "search";
            if (getStr(step, "word") != null)   break :blk "word";
            if (getStr(step, "name") != null)   break :blk "symbol";
            w.print("error: step {d} missing 'op'\n", .{step_i}) catch {};
            finishQueryWithFailure(alloc, out, step_i, "missing 'op'", step);
            return;
        };

        if (std.mem.eql(u8, op, "find")) {
            const query = getStr(step, "query") orelse {
                w.print("error: find needs 'query'\n", .{}) catch {};
                finishQueryWithFailure(alloc, out, step_i, "find needs 'query'", step);
                return;
            };
            const max: usize = if (getInt(step, "max_results")) |n| @intCast(@max(1, @min(n, 200))) else 50;
            const matches = explorer.fuzzyFindFiles(query, alloc, max) catch {
                w.print("error: find failed\n", .{}) catch {};
                return;
            };
            defer alloc.free(matches);
            if (have_set) {
                // Intersect: keep only files from current set that also appear in find results
                var match_set = std.StringHashMap(void).init(alloc);
                defer match_set.deinit();
                for (matches) |m| match_set.put(m.path, {}) catch {};
                var wr: usize = 0;
                for (file_set.items) |p| {
                    if (match_set.contains(p)) {
                        file_set.items[wr] = p;
                        wr += 1;
                    }
                }
                file_set.items.len = wr;
                w.print("{d} files after find intersect\n", .{file_set.items.len}) catch {};
            } else {
                file_set.clearRetainingCapacity();
                w.print("{d} files matched:\n", .{matches.len}) catch {};
                for (matches) |m| {
                    w.print("  {s}\n", .{m.path}) catch {};
                    file_set.append(alloc, m.path) catch {};
                }
                have_set = true;
            }
        } else if (std.mem.eql(u8, op, "search")) {
            const query = getStr(step, "query") orelse {
                w.print("error: search needs 'query'\n", .{}) catch {};
                finishQueryWithFailure(alloc, out, step_i, "search needs 'query'", step);
                return;
            };
            const max: usize = if (getInt(step, "max_results")) |n| @intCast(@max(1, @min(n, 200))) else 50;
            const results = explorer.searchContent(query, alloc, max) catch {
                w.print("error: search failed\n", .{}) catch {};
                return;
            };
            defer {
                for (results) |r| {
                    alloc.free(r.line_text);
                    alloc.free(r.path);
                }
                alloc.free(results);
            }
            if (have_set) {
                // Intersect: only keep files from current set that have search hits
                var hit_set = std.StringHashMap(void).init(alloc);
                defer hit_set.deinit();
                var path_set = std.StringHashMap(void).init(alloc);
                defer path_set.deinit();
                for (file_set.items) |p| path_set.put(p, {}) catch {};
                for (results) |r| {
                    if (path_set.contains(r.path)) {
                        w.print("{s}:{d}: {s}\n", .{ r.path, r.line_num, r.line_text }) catch {};
                        hit_set.put(r.path, {}) catch {};
                    }
                }
                // Narrow file_set to only files that had hits
                var wr: usize = 0;
                for (file_set.items) |p| {
                    if (hit_set.contains(p)) {
                        file_set.items[wr] = p;
                        wr += 1;
                    }
                }
                file_set.items.len = wr;
            } else {
                var seen = std.StringHashMap(void).init(alloc);
                defer seen.deinit();
                file_set.clearRetainingCapacity();
                for (results) |r| {
                    w.print("{s}:{d}: {s}\n", .{ r.path, r.line_num, r.line_text }) catch {};
                    if (!seen.contains(r.path)) {
                        // Dupe path — search results are freed by the defer above,
                        // but file_set must outlive this step for downstream ops
                        const duped = alloc.dupe(u8, r.path) catch continue;
                        seen.put(duped, {}) catch {
                            alloc.free(duped);
                            continue;
                        };
                        file_set.append(alloc, duped) catch {
                            alloc.free(duped);
                            continue;
                        };
                    }
                }
                have_set = true;
            }
        } else if (std.mem.eql(u8, op, "deps")) {
            // Expand file set by adding dependents/dependencies of current files.
            // Accepts optional 'path' for standalone use without a prior seeding step.
            if (!have_set) {
                if (getStr(step, "path")) |p| {
                    const duped = alloc.dupe(u8, p) catch {
                        w.print("error: out of memory\n", .{}) catch {};
                        return;
                    };
                    file_set.append(alloc, duped) catch {
                        alloc.free(duped);
                        w.print("error: out of memory\n", .{}) catch {};
                        return;
                    };
                    have_set = true;
                } else {
                    w.print("error: deps needs prior step or 'path' param\n", .{}) catch {};
                    return;
                }
            }
            const direction = getStr(step, "direction") orelse "imported_by";
            const transitive = getBool(step, "transitive");
            const max_depth_val: ?u32 = if (getInt(step, "max_depth")) |n| @intCast(@max(1, n)) else null;
            const is_forward = std.mem.eql(u8, direction, "depends_on");

            var expanded = std.StringHashMap(void).init(alloc);
            defer expanded.deinit();
            for (file_set.items) |path| expanded.put(path, {}) catch {};

            // Snapshot current file set since we'll append to it
            const current_len = file_set.items.len;
            for (file_set.items[0..current_len]) |path| {
                var deps_result: []const []const u8 = &.{};
                var needs_free = false;

                if (is_forward) {
                    if (transitive) {
                        deps_result = explorer.getTransitiveDependencies(path, alloc, max_depth_val) catch continue;
                        needs_free = true;
                    } else {
                        explorer.mu.lockShared();
                        const fwd = explorer.dep_graph.getForwardDeps(path);
                        explorer.mu.unlockShared();
                        if (fwd) |deps| {
                            var res: std.ArrayList([]const u8) = .empty;
                            for (deps) |dep| {
                                const d = alloc.dupe(u8, dep) catch continue;
                                res.append(alloc, d) catch {
                                    alloc.free(d);
                                    continue;
                                };
                            }
                            deps_result = res.toOwnedSlice(alloc) catch &.{};
                            needs_free = true;
                        }
                    }
                } else {
                    if (transitive) {
                        deps_result = explorer.getTransitiveDependents(path, alloc, max_depth_val) catch continue;
                    } else {
                        deps_result = explorer.getImportedBy(path, alloc) catch continue;
                    }
                    needs_free = true;
                }

                defer if (needs_free) {
                    for (deps_result) |dep| alloc.free(dep);
                    alloc.free(deps_result);
                };

                for (deps_result) |dep| {
                    if (!expanded.contains(dep)) {
                        expanded.put(dep, {}) catch {};
                        file_set.append(alloc, dep) catch {};
                    }
                }
            }
        } else if (std.mem.eql(u8, op, "filter")) {
            if (!have_set) {
                explorer.mu.lockShared();
                var iter = explorer.outlines.keyIterator();
                while (iter.next()) |k| file_set.append(alloc, k.*) catch {};
                explorer.mu.unlockShared();
                have_set = true;
            }
            const ext = getStr(step, "ext");
            const glob_pat = getStr(step, "glob");
            var wr: usize = 0;
            for (file_set.items) |path| {
                var keep = true;
                if (ext) |e| {
                    if (!std.mem.endsWith(u8, path, e)) keep = false;
                }
                if (keep) if (glob_pat) |g| {
                    if (!globMatch(g, path)) keep = false;
                };
                if (keep) {
                    file_set.items[wr] = path;
                    wr += 1;
                }
            }
            file_set.items.len = wr;
        } else if (std.mem.eql(u8, op, "outline")) {
            // Accepts optional 'path' for standalone single-file outline.
            if (!have_set) {
                if (getStr(step, "path")) |p| {
                    const duped = alloc.dupe(u8, p) catch {
                        w.print("error: out of memory\n", .{}) catch {};
                        return;
                    };
                    file_set.append(alloc, duped) catch {
                        alloc.free(duped);
                        w.print("error: out of memory\n", .{}) catch {};
                        return;
                    };
                    have_set = true;
                } else {
                    w.print("error: outline needs prior step or 'path' param\n", .{}) catch {};
                    return;
                }
            }
            for (file_set.items) |path| {
                var outline = explorer.getOutline(path, alloc) catch continue;
                if (outline) |*o| {
                    defer o.deinit();
                    w.print("--- {s} ({s}, {d} sym) ---\n", .{ path, @tagName(o.language), o.symbols.items.len }) catch {};
                    for (o.symbols.items) |sym| w.print("  L{d} {s} {s}\n", .{ sym.line_start, @tagName(sym.kind), sym.name }) catch {};
                }
                if (out.items.len > 100 * 1024) {
                    w.print("... truncated\n", .{}) catch {};
                    break;
                }
            }
        } else if (std.mem.eql(u8, op, "read")) {
            // Accepts optional 'path' for standalone single-file read.
            if (!have_set) {
                if (getStr(step, "path")) |p| {
                    const duped = alloc.dupe(u8, p) catch {
                        w.print("error: out of memory\n", .{}) catch {};
                        return;
                    };
                    file_set.append(alloc, duped) catch {
                        alloc.free(duped);
                        w.print("error: out of memory\n", .{}) catch {};
                        return;
                    };
                    have_set = true;
                } else {
                    w.print("error: read needs prior step or 'path' param\n", .{}) catch {};
                    return;
                }
            }
            const max_lines: usize = if (getInt(step, "lines")) |n| @intCast(@max(1, @min(n, 200))) else 50;
            for (file_set.items) |path| {
                const content = explorer.getContent(path, alloc) catch continue;
                if (content) |data| {
                    defer alloc.free(data);
                    w.print("--- {s} ---\n", .{path}) catch {};
                    var ln: usize = 1;
                    var it = std.mem.splitScalar(u8, data, '\n');
                    while (it.next()) |line| {
                        if (ln > max_lines) {
                            w.print("  ... (truncated)\n", .{}) catch {};
                            break;
                        }
                        w.print("{d:>4}| {s}\n", .{ ln, line }) catch {};
                        ln += 1;
                    }
                }
                if (out.items.len > 100 * 1024) {
                    w.print("... truncated\n", .{}) catch {};
                    break;
                }
            }
        } else if (std.mem.eql(u8, op, "sort")) {
            if (!have_set) {
                w.print("error: sort needs prior step\n", .{}) catch {};
                return;
            }
            const by = getStr(step, "by") orelse "path";
            if (std.mem.eql(u8, by, "path")) {
                std.mem.sort([]const u8, file_set.items, {}, struct {
                    fn lt(_: void, a: []const u8, b: []const u8) bool {
                        return std.mem.order(u8, a, b) == .lt;
                    }
                }.lt);
            }
            // "score" sorting is implicit from find — no re-sort needed
        } else if (std.mem.eql(u8, op, "word")) {
            const word = getStr(step, "word") orelse {
                w.print("error: word needs 'word'\n", .{}) catch {};
                finishQueryWithFailure(alloc, out, step_i, "word needs 'word'", step);
                return;
            };
            const hits = explorer.searchWord(word, alloc) catch {
                w.print("error: word search failed\n", .{}) catch {};
                return;
            };
            defer alloc.free(hits);
            if (have_set) {
                // Intersect: only show hits from files in current set
                var path_set = std.StringHashMap(void).init(alloc);
                defer path_set.deinit();
                var hit_set = std.StringHashMap(void).init(alloc);
                defer hit_set.deinit();
                for (file_set.items) |p| path_set.put(p, {}) catch {};
                explorer.mu.lockShared();
                defer explorer.mu.unlockShared();
                for (hits) |h| {
                    const hp = explorer.word_index.hitPath(h);
                    if (path_set.contains(hp)) {
                        w.print("  {s}:{d}\n", .{ hp, h.line_num }) catch {};
                        hit_set.put(hp, {}) catch {};
                    }
                }
                var wr: usize = 0;
                for (file_set.items) |p| {
                    if (hit_set.contains(p)) {
                        file_set.items[wr] = p;
                        wr += 1;
                    }
                }
                file_set.items.len = wr;
            } else {
                explorer.mu.lockShared();
                defer explorer.mu.unlockShared();
                var seen = std.StringHashMap(void).init(alloc);
                defer seen.deinit();
                w.print("{d} word hits for '{s}':\n", .{ hits.len, word }) catch {};
                file_set.clearRetainingCapacity();
                for (hits) |h| {
                    const hp = explorer.word_index.hitPath(h);
                    w.print("  {s}:{d}\n", .{ hp, h.line_num }) catch {};
                    if (!seen.contains(hp)) {
                        const duped = alloc.dupe(u8, hp) catch continue;
                        seen.put(duped, {}) catch { alloc.free(duped); continue; };
                        file_set.append(alloc, duped) catch { alloc.free(duped); continue; };
                    }
                }
                have_set = true;
            }
        } else if (std.mem.eql(u8, op, "symbol")) {
            const name = getStr(step, "name") orelse {
                w.print("error: symbol needs 'name'\n", .{}) catch {};
                finishQueryWithFailure(alloc, out, step_i, "symbol needs 'name'", step);
                return;
            };
            const results = explorer.findAllSymbols(name, alloc) catch {
                w.print("error: symbol search failed\n", .{}) catch {};
                return;
            };
            defer {
                for (results) |r| {
                    alloc.free(r.path);
                    alloc.free(r.symbol.name);
                    if (r.symbol.detail) |d| alloc.free(d);
                }
                alloc.free(results);
            }
            var seen = std.StringHashMap(void).init(alloc);
            defer seen.deinit();
            w.print("{d} symbols '{s}':\n", .{ results.len, name }) catch {};
            for (results) |r| {
                w.print("  {s}:{d} ({s})\n", .{ r.path, r.symbol.line_start, @tagName(r.symbol.kind) }) catch {};
            }
            if (!have_set) {
                file_set.clearRetainingCapacity();
                for (results) |r| {
                    if (!seen.contains(r.path)) {
                        const duped = alloc.dupe(u8, r.path) catch continue;
                        seen.put(duped, {}) catch { alloc.free(duped); continue; };
                        file_set.append(alloc, duped) catch { alloc.free(duped); continue; };
                    }
                }
                have_set = true;
            }
        } else if (std.mem.eql(u8, op, "limit")) {
            if (!have_set) {
                w.print("error: limit needs prior step\n", .{}) catch {};
                return;
            }
            const n: usize = if (getInt(step, "n")) |i| @intCast(@max(1, @min(i, 100))) else 10;
            if (file_set.items.len > n) file_set.items.len = n;
        } else {
            w.print("error: unknown op '{s}'\n", .{op}) catch {};
            return;
        }
        // Issue #356-p3: track each successfully-completed step.
        stages.append(alloc, .{ .op = op, .files_out = file_set.items.len }) catch {};
    }

    if (out.items.len == 0 and have_set) {
        w.print("{d} files:\n", .{file_set.items.len}) catch {};
        for (file_set.items) |path| w.print("  {s}\n", .{path}) catch {};
    }

    // Issue #356-p3: per-stage summary tail. Lists each completed step's op
    // and outgoing file count so callers can audit a multi-step pipeline at
    // a glance without re-parsing the unstructured output above.
    if (stages.items.len > 0) {
        w.print("\n--- stages ---\n", .{}) catch {};
        for (stages.items, 0..) |s, i| {
            w.print("{d}: {s} ({d} files)\n", .{ i, s.op, s.files_out }) catch {};
        }
    }
}

// Query tracking — append-only WAL in ~/.codedb/projects/<hash>/queries.log
var query_log_path: ?[]const u8 = null;

pub fn setQueryLogPath(path: []const u8) void {
    query_log_path = path;
}

fn escapeJsonStr(input: []const u8, out: *[256]u8) usize {
    var elen: usize = 0;
    for (input) |c| {
        if (elen >= out.len - 1) break;
        if (c == '"') {
            out[elen] = '\'';
            elen += 1;
        } else if (c == '\\') {
            if (elen + 1 < out.len) {
                out[elen] = '\\';
                out[elen + 1] = '\\';
                elen += 2;
            }
        } else if (c == '\n' or c == '\r' or c == '\t') {
            out[elen] = ' ';
            elen += 1;
        } else {
            out[elen] = c;
            elen += 1;
        }
    }
    return elen;
}

fn appendToWal(io: std.Io, line: []const u8) void {
    const path = query_log_path orelse return;
    const file = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .write_only }) catch blk: {
        break :blk std.Io.Dir.cwd().createFile(io, path, .{}) catch return;
    };
    defer file.close(io);
    const end_offset = file.length(io) catch return;
    file.writePositionalAll(io, line, end_offset) catch {};
}

fn logQuery(io: std.Io, tool: []const u8, query: []const u8, result_bytes: usize, latency_ns: i128) void {
    var escaped: [256]u8 = undefined;
    const elen = escapeJsonStr(query, &escaped);
    const latency_us: i64 = @intCast(@divTrunc(latency_ns, 1000));
    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "{{\"ts\":{d},\"ev\":\"query\",\"tool\":\"{s}\",\"query\":\"{s}\",\"result_bytes\":{d},\"latency_us\":{d}}}\n", .{
        cio.milliTimestamp(), tool, escaped[0..elen], result_bytes, latency_us,
    }) catch return;
    appendToWal(io, line);
}

fn logFileAccess(io: std.Io, tool: []const u8, file_path: []const u8, latency_ns: i128) void {
    var escaped: [256]u8 = undefined;
    const elen = escapeJsonStr(file_path, &escaped);
    const latency_us: i64 = @intCast(@divTrunc(latency_ns, 1000));
    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "{{\"ts\":{d},\"ev\":\"access\",\"tool\":\"{s}\",\"path\":\"{s}\",\"latency_us\":{d}}}\n", .{
        cio.milliTimestamp(), tool, escaped[0..elen], latency_us,
    }) catch return;
    appendToWal(io, line);
}
pub fn globMatch(pattern: []const u8, path: []const u8) bool {
    return explore_mod.matchGlob(pattern, path);
}

pub fn isPathSafe(path: []const u8) bool {
    if (path.len == 0) return false;
    if (path[0] == '/') return false;
    // Block null bytes (path truncation attack)
    if (std.mem.indexOfScalar(u8, path, 0) != null) return false;
    // Block backslash separators
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return false;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |component| {
        if (std.mem.eql(u8, component, "..")) return false;
    }
    return true;
}

fn writeResult(alloc: std.mem.Allocator, stdout: cio.File, id: ?std.json.Value, result: []const u8) void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    buf.ensureTotalCapacity(alloc, result.len + 64) catch {};
    buf.appendSlice(alloc, "{\"jsonrpc\":\"2.0\",\"id\":") catch return;
    appendId(alloc, &buf, id);
    buf.appendSlice(alloc, ",\"result\":") catch return;
    // Batch-copy non-newline runs instead of per-byte append.
    var i: usize = 0;
    while (i < result.len) {
        const start = i;
        while (i < result.len and result[i] != '\n' and result[i] != '\r') : (i += 1) {}
        if (i > start) buf.appendSlice(alloc, result[start..i]) catch return;
        if (i < result.len) i += 1;
    }
    buf.appendSlice(alloc, "}\n") catch return;
    stdout.writeAll(buf.items) catch {
        stdout_broken.store(true, .release);
        return;
    };
}

fn writeError(alloc: std.mem.Allocator, stdout: cio.File, id: ?std.json.Value, code: i32, msg: []const u8) void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    buf.appendSlice(alloc, "{\"jsonrpc\":\"2.0\",\"id\":") catch return;
    appendId(alloc, &buf, id);
    buf.appendSlice(alloc, ",\"error\":{\"code\":") catch return;
    var tmp: [12]u8 = undefined;
    const cs = std.fmt.bufPrint(&tmp, "{d}", .{code}) catch return;
    buf.appendSlice(alloc, cs) catch return;
    buf.appendSlice(alloc, ",\"message\":\"") catch return;
    mcpj.writeEscaped(alloc, &buf, msg);
    buf.appendSlice(alloc, "\"}}") catch return;
    stdout.writeAll(buf.items) catch {
        stdout_broken.store(true, .release);
        return;
    };
    stdout.writeAll("\n") catch {
        stdout_broken.store(true, .release);
        return;
    };
}
/// Fast JSON string escaper: batch-copies runs of safe characters via
/// appendSlice instead of the per-byte append in mcpj.writeEscaped.
fn writeEscaped(alloc: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) void {
    var i: usize = 0;
    while (i < s.len) {
        const start = i;
        while (i < s.len) : (i += 1) {
            const c = s[i];
            if (c < 0x20 or c == '"' or c == '\\') break;
        }
        if (i > start) out.appendSlice(alloc, s[start..i]) catch return;
        if (i >= s.len) break;
        const c = s[i];
        switch (c) {
            '"' => out.appendSlice(alloc, "\\\"") catch return,
            '\\' => out.appendSlice(alloc, "\\\\") catch return,
            '\n' => out.appendSlice(alloc, "\\n") catch return,
            '\r' => out.appendSlice(alloc, "\\r") catch return,
            '\t' => out.appendSlice(alloc, "\\t") catch return,
            else => {
                const hex = "0123456789abcdef";
                const esc = [6]u8{ '\\', 'u', '0', '0', hex[c >> 4], hex[c & 0x0f] };
                out.appendSlice(alloc, &esc) catch return;
            },
        }
        i += 1;
    }
}
const getStr = mcpj.getStr;
const getInt = mcpj.getInt;
pub const getBool = mcpj.getBool;

fn wantsJsonFormat(args: *const std.json.ObjectMap) bool {
    const fmt = getStr(args, "format") orelse return false;
    return std.mem.eql(u8, fmt, "json");
}

fn appendJsonStr(out: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) void {
    out.append(alloc, '"') catch return;
    mcpj.writeEscaped(alloc, out, s);
    out.append(alloc, '"') catch return;
}

fn appendJsonKeyStr(out: *std.ArrayList(u8), alloc: std.mem.Allocator, key: []const u8, value: []const u8) void {
    appendJsonStr(out, alloc, key);
    out.append(alloc, ':') catch return;
    appendJsonStr(out, alloc, value);
}

fn appendJsonKeyBool(out: *std.ArrayList(u8), alloc: std.mem.Allocator, key: []const u8, value: bool) void {
    appendJsonStr(out, alloc, key);
    out.appendSlice(alloc, if (value) ":true" else ":false") catch {};
}

fn appendJsonKeyUsize(out: *std.ArrayList(u8), alloc: std.mem.Allocator, key: []const u8, value: usize) void {
    appendJsonStr(out, alloc, key);
    out.append(alloc, ':') catch return;
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return;
    out.appendSlice(alloc, s) catch {};
}

fn appendJsonKeyU8(out: *std.ArrayList(u8), alloc: std.mem.Allocator, key: []const u8, value: u8) void {
    appendJsonStr(out, alloc, key);
    out.append(alloc, ':') catch return;
    var buf: [8]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return;
    out.appendSlice(alloc, s) catch {};
}

fn appendJsonKeyF32(out: *std.ArrayList(u8), alloc: std.mem.Allocator, key: []const u8, value: f32) void {
    appendJsonStr(out, alloc, key);
    out.append(alloc, ':') catch return;
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{@as(f64, value)}) catch return;
    out.appendSlice(alloc, s) catch {};
}

fn writeJsonToolError(out: *std.ArrayList(u8), alloc: std.mem.Allocator, tool: []const u8, code: []const u8, message: []const u8) void {
    out.appendSlice(alloc, "{\"ok\":false,\"tool\":") catch {};
    appendJsonStr(out, alloc, tool);
    out.appendSlice(alloc, ",\"error\":{\"code\":") catch {};
    appendJsonStr(out, alloc, code);
    out.appendSlice(alloc, ",\"message\":") catch {};
    appendJsonStr(out, alloc, message);
    out.appendSlice(alloc, "}}") catch {};
}

fn appendSearchProvenanceMeta(out: *std.ArrayList(u8), alloc: std.mem.Allocator, explorer: *Explorer) void {
    const bd = explorer.last_search_breakdown;
    const skip = explorer.skipTrigramFileCount();
    const recall_complete = skip == 0 or bd.tier_reached >= 5;
    out.appendSlice(alloc, "\"meta\":{") catch {};
    appendJsonKeyStr(out, alloc, "index", "trigram+outline");
    out.appendSlice(alloc, ",") catch {};
    appendJsonKeyU8(out, alloc, "tier_reached", bd.tier_reached);
    out.appendSlice(alloc, ",") catch {};
    appendJsonKeyUsize(out, alloc, "skip_trigram_files", skip);
    out.appendSlice(alloc, ",") catch {};
    appendJsonKeyUsize(out, alloc, "trigram_cap", 15_000);
    out.appendSlice(alloc, ",") catch {};
    appendJsonKeyBool(out, alloc, "recall_complete", recall_complete);
    out.append(alloc, '}') catch {};
}

fn writeSearchResultsJson(
    out: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    explorer: *Explorer,
    query: []const u8,
    results: []const explore_mod.SearchResult,
    offset: usize,
    has_more: bool,
    paths_only: bool,
    path_glob: ?[]const u8,
    compact: bool,
) void {
    var visible: usize = 0;
    for (results) |r| {
        if (path_glob) |g| if (!globMatch(g, r.path)) continue;
        if (compact and explore_mod.isCommentOrBlank(r.line_text, explore_mod.detectLanguage(r.path))) continue;
        visible += 1;
    }

    out.appendSlice(alloc, "{\"ok\":true,\"tool\":\"codedb_search\",\"query\":") catch {};
    appendJsonStr(out, alloc, query);
    out.appendSlice(alloc, ",\"count\":") catch {};
    var cnt_buf: [16]u8 = undefined;
    const cnt_s = std.fmt.bufPrint(&cnt_buf, "{d}", .{visible}) catch "0";
    out.appendSlice(alloc, cnt_s) catch {};
    out.appendSlice(alloc, ",") catch {};
    appendSearchProvenanceMeta(out, alloc, explorer);
    if (has_more) {
        out.appendSlice(alloc, ",\"has_more\":true,\"next_offset\":") catch {};
        var off_buf: [16]u8 = undefined;
        const off_s = std.fmt.bufPrint(&off_buf, "{d}", .{offset + results.len}) catch "0";
        out.appendSlice(alloc, off_s) catch {};
    }
    out.appendSlice(alloc, ",\"results\":[") catch {};
    var first = true;
    for (results) |r| {
        if (path_glob) |g| if (!globMatch(g, r.path)) continue;
        if (compact and explore_mod.isCommentOrBlank(r.line_text, explore_mod.detectLanguage(r.path))) continue;
        if (!first) out.append(alloc, ',') catch {} else first = false;
        out.appendSlice(alloc, "{\"path\":") catch {};
        appendJsonStr(out, alloc, r.path);
        out.appendSlice(alloc, ",\"line\":") catch {};
        var line_buf: [16]u8 = undefined;
        const line_s = std.fmt.bufPrint(&line_buf, "{d}", .{r.line_num}) catch "0";
        out.appendSlice(alloc, line_s) catch {};
        if (!paths_only) {
            out.appendSlice(alloc, ",\"text\":") catch {};
            appendJsonStr(out, alloc, r.line_text);
            out.appendSlice(alloc, ",\"score\":") catch {};
            var score_buf: [32]u8 = undefined;
            const score_s = std.fmt.bufPrint(&score_buf, "{d}", .{@as(f64, r.score)}) catch "0";
            out.appendSlice(alloc, score_s) catch {};
            out.appendSlice(alloc, ",\"confidence\":\"ranked\"") catch {};
        }
        out.append(alloc, '}') catch {};
    }
    out.appendSlice(alloc, "]}") catch {};
}

fn symbolMatchModeLabel(spec: Explorer.SymbolSearchSpec) []const u8 {
    if (spec.fuzzy and spec.name != null) return "fuzzy";
    if (spec.prefix != null) return "prefix";
    if (spec.pattern != null) return "pattern";
    if (spec.kind != null and spec.name == null and spec.prefix == null and spec.pattern == null) return "kind";
    return "exact";
}
const eql = mcpj.eql;

pub fn appendId(alloc: std.mem.Allocator, buf: *std.ArrayList(u8), id: ?std.json.Value) void {
    if (id) |v| switch (v) {
        .integer => |n| {
            var tmp: [20]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "{d}", .{n}) catch return;
            buf.appendSlice(alloc, s) catch return;
        },
        .string => |s| {
            buf.append(alloc, '"') catch return;
            mcpj.writeEscaped(alloc, buf, s);
            buf.append(alloc, '"') catch return;
        },
        .float => |f| {
            var tmp: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "{d}", .{f}) catch return;
            buf.appendSlice(alloc, s) catch return;
        },
        .number_string => |s| {
            buf.appendSlice(alloc, s) catch return;
        },
        else => buf.appendSlice(alloc, "null") catch return,
    } else {
        buf.appendSlice(alloc, "null") catch return;
    }
}

// ── MCP UX: 3-block response helpers ────────────────────────────────────────
// Colors are always on — MCP preview pane always renders ANSI. No TTY check.

var mcp_lean_mode_cached: ?bool = null;

/// True when CODEDB_MCP_LEAN is set (any non-empty value). Cached on first
/// read. When true, MCP responses omit Block 1 (colored summary header) and
/// Block 3 (guidance hints) — emitting only Block 2 (raw data). Saves
/// tokens for agent consumers that can't render ANSI and don't need the
/// hints.
fn mcpLeanMode() bool {
    if (mcp_lean_mode_cached) |v| return v;
    const v = cio.posixGetenv("CODEDB_MCP_LEAN") orelse {
        mcp_lean_mode_cached = false;
        return false;
    };
    const enabled = v.len > 0 and !std.mem.eql(u8, v, "0") and !std.mem.eql(u8, v, "false");
    mcp_lean_mode_cached = enabled;
    return enabled;
}

const MCP_RESET = "\x1b[0m";
const MCP_BOLD = "\x1b[1m";
const MCP_DIM = "\x1b[2m";
const MCP_GREEN = "\x1b[32m";
const MCP_RED = "\x1b[31m";
const MCP_CYAN = "\x1b[36m";
const MCP_YELLOW = "\x1b[33m";
const MCP_MAGENTA = "\x1b[35m";
const MCP_BLUE = "\x1b[34m";
const MCP_BRIGHT_GREEN = "\x1b[92m";

const MCP_CHECK = "\xe2\x9c\x93"; // ✓
const MCP_CROSS = "\xe2\x9c\x97"; // ✗
const MCP_DASH = " \xe2\x80\x94 "; //  —
const MCP_ARROW = "\xe2\x86\x92 "; // →
const MCP_DOT = "\xe2\x80\xa2 "; // •
const MCP_ZAP = "\xe2\x9a\xa1"; // ⚡

fn mcpFormatDuration(buf: []u8, ns: i128) []const u8 {
    if (ns <= 0) return "";
    const uns: u64 = @intCast(@min(ns, std.math.maxInt(u64)));
    if (uns < 1_000) {
        return std.fmt.bufPrint(buf, "  " ++ MCP_CYAN ++ MCP_ZAP ++ " {d}ns" ++ MCP_RESET, .{uns}) catch "";
    } else if (uns < 1_000_000) {
        const us = uns / 1_000;
        const frac = (uns % 1_000) / 100;
        return std.fmt.bufPrint(buf, "  " ++ MCP_CYAN ++ MCP_ZAP ++ " {d}.{d}\xc2\xb5s" ++ MCP_RESET, .{ us, frac }) catch "";
    } else if (uns < 1_000_000_000) {
        const ms = uns / 1_000_000;
        const frac = (uns % 1_000_000) / 100_000;
        if (ms < 10) {
            return std.fmt.bufPrint(buf, "  " ++ MCP_BRIGHT_GREEN ++ MCP_ZAP ++ " {d}.{d}ms" ++ MCP_RESET, .{ ms, frac }) catch "";
        } else if (ms < 100) {
            return std.fmt.bufPrint(buf, "  " ++ MCP_GREEN ++ "{d}.{d}ms" ++ MCP_RESET, .{ ms, frac }) catch "";
        } else {
            return std.fmt.bufPrint(buf, "  " ++ MCP_BLUE ++ "{d}.{d}ms" ++ MCP_RESET, .{ ms, frac }) catch "";
        }
    } else {
        const s = uns / 1_000_000_000;
        const frac = (uns % 1_000_000_000) / 100_000_000;
        return std.fmt.bufPrint(buf, "  " ++ MCP_YELLOW ++ "{d}.{d}s" ++ MCP_RESET, .{ s, frac }) catch "";
    }
}

fn mcpToolIcon(tool_name: []const u8) []const u8 {
    if (eql(tool_name, "codedb_outline")) return MCP_BLUE ++ MCP_DOT ++ MCP_RESET;
    if (eql(tool_name, "codedb_symbol")) return MCP_BLUE ++ MCP_DOT ++ MCP_RESET;
    if (eql(tool_name, "codedb_read")) return MCP_BLUE ++ MCP_DOT ++ MCP_RESET;
    if (eql(tool_name, "codedb_search")) return MCP_MAGENTA ++ MCP_DOT ++ MCP_RESET;
    if (eql(tool_name, "codedb_word")) return MCP_CYAN ++ MCP_DOT ++ MCP_RESET;
    if (eql(tool_name, "codedb_edit")) return MCP_YELLOW ++ MCP_DOT ++ MCP_RESET;
    if (eql(tool_name, "codedb_tree")) return MCP_GREEN ++ MCP_DOT ++ MCP_RESET;
    if (eql(tool_name, "codedb_hot")) return MCP_YELLOW ++ MCP_DOT ++ MCP_RESET;
    if (eql(tool_name, "codedb_deps")) return MCP_CYAN ++ MCP_DOT ++ MCP_RESET;
    if (eql(tool_name, "codedb_changes")) return MCP_YELLOW ++ MCP_DOT ++ MCP_RESET;
    if (eql(tool_name, "codedb_bundle")) return MCP_MAGENTA ++ MCP_DOT ++ MCP_RESET;
    return MCP_DIM ++ MCP_DOT ++ MCP_RESET;
}

fn mcpPathBasename(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |pos| return path[pos + 1 ..];
    return path;
}

fn mcpPathParent(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |pos| return path[0..pos];
    return "";
}

fn mcpAppendPath(alloc: std.mem.Allocator, buf: *std.ArrayList(u8), path: []const u8) void {
    const name = mcpPathBasename(path);
    const parent = mcpPathParent(path);
    if (parent.len > 0) {
        buf.appendSlice(alloc, MCP_DIM) catch {};
        buf.appendSlice(alloc, parent) catch {};
        buf.appendSlice(alloc, "/" ++ MCP_RESET) catch {};
    }
    buf.appendSlice(alloc, MCP_BOLD) catch {};
    buf.appendSlice(alloc, name) catch {};
    buf.appendSlice(alloc, MCP_RESET) catch {};
}

pub fn mcpGenerateSummary(
    alloc: std.mem.Allocator,
    tool_name: []const u8,
    args: *const std.json.ObjectMap,
    output: []const u8,
    is_error: bool,
    buf: *std.ArrayList(u8),
) void {
    // Readable label: strip "codedb_" prefix
    const label = if (std.mem.indexOf(u8, tool_name, "_")) |i| tool_name[i + 1 ..] else tool_name;
    buf.appendSlice(alloc, MCP_BOLD) catch {};
    buf.appendSlice(alloc, label) catch {};
    buf.appendSlice(alloc, MCP_RESET) catch {};

    if (is_error) {
        const msg = if (std.mem.startsWith(u8, output, "error: ")) output[7..] else output;
        const end = std.mem.indexOfScalar(u8, msg, '\n') orelse msg.len;
        buf.appendSlice(alloc, MCP_DASH ++ MCP_RED) catch {};
        buf.appendSlice(alloc, msg[0..end]) catch {};
        buf.appendSlice(alloc, MCP_RESET) catch {};
        // Issue #367-dx: surface the received-keys diagnostic inline so clients
        // that only render content[0] (the TTY summary block) still see it.
        if (std.mem.indexOf(u8, output, "received keys: [")) |s| {
            const kstart = s + "received keys: [".len;
            if (std.mem.indexOfScalarPos(u8, output, kstart, ']')) |kend| {
                buf.appendSlice(alloc, "  " ++ MCP_DIM ++ "(received: [") catch {};
                buf.appendSlice(alloc, output[kstart..kend]) catch {};
                buf.appendSlice(alloc, "])" ++ MCP_RESET) catch {};
            }
        }
        return;
    }

    if (eql(tool_name, "codedb_search") or eql(tool_name, "codedb_word")) {
        const q = getStr(args, "query") orelse getStr(args, "word") orelse "";
        // First line: "N results for 'q':\n" or "N hits for 'w':\n"
        const nl = std.mem.indexOfScalar(u8, output, '\n') orelse output.len;
        const sp = std.mem.indexOfScalar(u8, output[0..nl], ' ') orelse nl;
        buf.appendSlice(alloc, "  " ++ MCP_BOLD ++ "'") catch {};
        buf.appendSlice(alloc, q) catch {};
        buf.appendSlice(alloc, "'" ++ MCP_RESET ++ MCP_DASH ++ MCP_CYAN ++ MCP_BOLD) catch {};
        buf.appendSlice(alloc, output[0..sp]) catch {};
        buf.appendSlice(alloc, MCP_RESET) catch {};
        buf.appendSlice(alloc, if (eql(tool_name, "codedb_search")) " results" else " hits") catch {};
        if (getBool(args, "scope")) {
            buf.appendSlice(alloc, MCP_DIM ++ "  (scoped)" ++ MCP_RESET) catch {};
        }
    } else if (eql(tool_name, "codedb_outline")) {
        const path = getStr(args, "path") orelse "";
        buf.appendSlice(alloc, "  ") catch {};
        mcpAppendPath(alloc, buf, path);
        // Parse meta from first line: "path (lang, N lines, N bytes)"
        if (std.mem.indexOfScalar(u8, output, '(')) |lp| {
            if (std.mem.indexOfScalarPos(u8, output, lp, ')')) |rp| {
                buf.appendSlice(alloc, MCP_DASH ++ MCP_DIM) catch {};
                buf.appendSlice(alloc, output[lp + 1 .. rp]) catch {};
                buf.appendSlice(alloc, MCP_RESET) catch {};
            }
        }
    } else if (eql(tool_name, "codedb_symbol")) {
        const sym_name = getStr(args, "name") orelse "";
        buf.appendSlice(alloc, MCP_DASH ++ MCP_MAGENTA ++ "fn " ++ MCP_RESET ++ MCP_BOLD) catch {};
        buf.appendSlice(alloc, sym_name) catch {};
        buf.appendSlice(alloc, MCP_RESET) catch {};
    } else if (eql(tool_name, "codedb_tree")) {
        var file_count: usize = 0;
        var it = std.mem.splitScalar(u8, output, '\n');
        while (it.next()) |line| {
            const t = std.mem.trim(u8, line, " ");
            if (t.len > 0 and !std.mem.endsWith(u8, t, "/")) file_count += 1;
        }
        var tmp: [32]u8 = undefined;
        buf.appendSlice(alloc, "  " ++ MCP_CYAN ++ MCP_BOLD) catch {};
        buf.appendSlice(alloc, std.fmt.bufPrint(&tmp, "{d}", .{file_count}) catch "?") catch {};
        buf.appendSlice(alloc, MCP_RESET ++ " files") catch {};
    } else if (eql(tool_name, "codedb_read") or eql(tool_name, "codedb_deps")) {
        const path = getStr(args, "path") orelse "";
        buf.appendSlice(alloc, "  ") catch {};
        mcpAppendPath(alloc, buf, path);
    } else if (eql(tool_name, "codedb_edit")) {
        const path = getStr(args, "path") orelse "";
        buf.appendSlice(alloc, "  ") catch {};
        mcpAppendPath(alloc, buf, path);
    } else if (eql(tool_name, "codedb_hot")) {
        var count: usize = 0;
        var it = std.mem.splitScalar(u8, output, '\n');
        while (it.next()) |line| {
            if (std.mem.trim(u8, line, " ").len > 0) count += 1;
        }
        var tmp: [32]u8 = undefined;
        buf.appendSlice(alloc, "  " ++ MCP_CYAN ++ MCP_BOLD) catch {};
        buf.appendSlice(alloc, std.fmt.bufPrint(&tmp, "{d}", .{count}) catch "?") catch {};
        buf.appendSlice(alloc, MCP_RESET ++ " files") catch {};
    } else if (eql(tool_name, "codedb_status")) {
        var files_str: []const u8 = "?";
        var seq_str: []const u8 = "?";
        if (std.mem.indexOf(u8, output, "files: ")) |i| {
            const after = output[i + 7 ..];
            files_str = after[0 .. std.mem.indexOfScalar(u8, after, '\n') orelse after.len];
        }
        if (std.mem.indexOf(u8, output, "seq: ")) |i| {
            const after = output[i + 5 ..];
            seq_str = after[0 .. std.mem.indexOfScalar(u8, after, '\n') orelse after.len];
        }
        buf.appendSlice(alloc, "  " ++ MCP_CYAN ++ MCP_BOLD) catch {};
        buf.appendSlice(alloc, files_str) catch {};
        buf.appendSlice(alloc, MCP_RESET ++ " files" ++ MCP_DASH ++ MCP_DIM ++ "seq ") catch {};
        buf.appendSlice(alloc, seq_str) catch {};
        buf.appendSlice(alloc, MCP_RESET) catch {};
    } else if (eql(tool_name, "codedb_changes")) {
        if (getInt(args, "since")) |since| {
            var tmp: [32]u8 = undefined;
            buf.appendSlice(alloc, "  " ++ MCP_DIM ++ "since seq ") catch {};
            buf.appendSlice(alloc, std.fmt.bufPrint(&tmp, "{d}", .{since}) catch "0") catch {};
            buf.appendSlice(alloc, MCP_RESET) catch {};
        }
    } else if (eql(tool_name, "codedb_bundle")) {
        const path = getStr(args, "path") orelse "";
        if (path.len > 0) {
            buf.appendSlice(alloc, "  ") catch {};
            mcpAppendPath(alloc, buf, path);
        }
    }
    // codedb_snapshot, codedb_status: label + timer is enough
}

pub fn mcpGenerateGuidance(
    alloc: std.mem.Allocator,
    tool_name: []const u8,
    args: *const std.json.ObjectMap,
    output: []const u8,
    is_error: bool,
    buf: *std.ArrayList(u8),
) void {
    if (is_error) {
        if (eql(tool_name, "codedb_outline") or eql(tool_name, "codedb_read") or eql(tool_name, "codedb_deps")) {
            buf.appendSlice(alloc, MCP_DIM ++ "hint: use codedb_tree to verify file paths" ++ MCP_RESET) catch {};
        } else if (eql(tool_name, "codedb_edit")) {
            buf.appendSlice(alloc, MCP_DIM ++ "hint: use codedb_outline to verify structure before editing" ++ MCP_RESET) catch {};
        }
        return;
    }
    if (eql(tool_name, "codedb_tree")) {
        buf.appendSlice(alloc, MCP_DIM ++ MCP_ARROW ++ "next: codedb_outline path=<file> to inspect symbols" ++ MCP_RESET) catch {};
    } else if (eql(tool_name, "codedb_outline")) {
        buf.appendSlice(alloc, MCP_DIM ++ MCP_ARROW ++ "next: codedb_symbol name=<fn> body=true for a symbol's full source in one call" ++ MCP_RESET) catch {};
    } else if (eql(tool_name, "codedb_symbol")) {
        // Bug 8: don't tell the agent to "edit this symbol" when the lookup
        // returned 0 results — there's nothing to edit. Hint at codedb_search
        // instead so they can broaden the lookup.
        if (std.mem.startsWith(u8, output, "no results for:")) {
            buf.appendSlice(alloc, MCP_DIM ++ "hint: try codedb_search query=<name> to find references — symbol not defined" ++ MCP_RESET) catch {};
        } else if (getBool(args, "body")) {
            buf.appendSlice(alloc, MCP_DIM ++ MCP_ARROW ++ "next: codedb_callers name=<fn> for call sites, then edit with your native tool" ++ MCP_RESET) catch {};
        } else {
            buf.appendSlice(alloc, MCP_DIM ++ MCP_ARROW ++ "next: codedb_symbol name=<fn> body=true to see the source" ++ MCP_RESET) catch {};
        }
    } else if (eql(tool_name, "codedb_search")) {
        const has_regex_meta = blk: {
            if (getBool(args, "regex")) break :blk false;
            const q = getStr(args, "query") orelse break :blk false;
            for (q) |c| switch (c) {
                '|', '(', ')', '[', ']', '?', '+', '*', '^', '$' => break :blk true,
                else => {},
            };
            break :blk false;
        };
        if (has_regex_meta) {
            buf.appendSlice(alloc, MCP_DIM ++ MCP_ARROW ++ "hint: query has regex metachars but regex=false; matched as literal — pass regex=true for OR/grouping" ++ MCP_RESET) catch {};
        } else if (!getBool(args, "scope")) {
            buf.appendSlice(alloc, MCP_DIM ++ MCP_ARROW ++ "next: add scope=true to see enclosing functions" ++ MCP_RESET) catch {};
        }
    } else if (eql(tool_name, "codedb_word")) {
        buf.appendSlice(alloc, MCP_DIM ++ MCP_ARROW ++ "next: codedb_outline on a result file for full context" ++ MCP_RESET) catch {};
    } else if (eql(tool_name, "codedb_callers")) {
        buf.appendSlice(alloc, MCP_DIM ++ MCP_ARROW ++ "next: codedb_callpath from=<caller> to=<callee> for the shortest call chain" ++ MCP_RESET) catch {};
    } else if (eql(tool_name, "codedb_callpath")) {
        if (std.mem.startsWith(u8, output, "call path")) {
            buf.appendSlice(alloc, MCP_DIM ++ MCP_ARROW ++ "next: codedb_read path=<hop-file> line_start=<line> to expand a hop" ++ MCP_RESET) catch {};
        }
    } else if (eql(tool_name, "codedb_edit")) {
        buf.appendSlice(alloc, MCP_DIM ++ MCP_ARROW ++ "next: codedb_changes to verify edits" ++ MCP_RESET) catch {};
    } else if (eql(tool_name, "codedb_hot")) {
        buf.appendSlice(alloc, MCP_DIM ++ MCP_ARROW ++ "next: codedb_outline on a hot file to see recent changes" ++ MCP_RESET) catch {};
    }
}

test "issue-258: cached project reads use the project root after contents are released" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{
        .sub_path = "src/main.zig",
        .data = "const project = \"secondary\";\n",
    });

    var project_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const project_path_len = try tmp.dir.realPathFile(io, ".", &project_path_buf);
    const project_path = project_path_buf[0..project_path_len];

    var snapshot_src = Explorer.init(testing.allocator, explore_mod.Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer snapshot_src.deinit();
    snapshot_src.setRoot(io, project_path);
    try snapshot_src.indexFile("src/main.zig", "const project = \"secondary\";\n");

    const snap_path = try std.fmt.allocPrint(testing.allocator, "{s}/codedb.snapshot", .{project_path});
    defer testing.allocator.free(snap_path);
    try snapshot_mod.writeSnapshot(io, &snapshot_src, project_path, snap_path, testing.allocator);

    var default_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const default_path_len = try std.Io.Dir.cwd().realPathFile(io, ".", &default_path_buf);
    const default_path = default_path_buf[0..default_path_len];

    var default_explorer = Explorer.init(testing.allocator, explore_mod.Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer default_explorer.deinit();
    var default_store = Store.init(testing.allocator);
    defer default_store.deinit();

    var cache = ProjectCache.init(testing.allocator, default_path, explore_mod.Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer cache.deinit();

    const ctx = try cache.get(io, project_path, &default_explorer, &default_store);
    ctx.explorer.releaseContents();

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"path\":\"src/main.zig\"}", .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    handleRead(io, testing.allocator, &parsed.value.object, &out, ctx.explorer);

    try testing.expect(std.mem.indexOf(u8, out.items, "const project = \"secondary\";") != null);
}

test "ProjectCache loads project from central snapshot cache" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{
        .sub_path = "src/main.zig",
        .data = "pub fn cachedProject() void {}\n",
    });

    var project_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const project_path_len = try tmp.dir.realPathFile(io, ".", &project_path_buf);
    const project_path = project_path_buf[0..project_path_len];

    const data_dir = getProjectDataDir(testing.allocator, project_path) orelse return error.OutOfMemory;
    defer testing.allocator.free(data_dir);
    const central_snapshot = try std.fmt.allocPrint(testing.allocator, "{s}/codedb.snapshot", .{data_dir});
    defer testing.allocator.free(central_snapshot);
    const project_txt = try std.fmt.allocPrint(testing.allocator, "{s}/project.txt", .{data_dir});
    defer testing.allocator.free(project_txt);
    defer {
        std.Io.Dir.cwd().deleteFile(io, central_snapshot) catch {};
        std.Io.Dir.cwd().deleteFile(io, project_txt) catch {};
        std.Io.Dir.cwd().deleteDir(io, data_dir) catch {};
    }

    var snapshot_src = Explorer.init(testing.allocator, explore_mod.Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer snapshot_src.deinit();
    snapshot_src.setRoot(io, project_path);
    try snapshot_src.indexFile("src/main.zig", "pub fn cachedProject() void {}\n");
    try snapshot_mod.writeProjectCacheSnapshot(io, &snapshot_src, project_path, testing.allocator);

    const root_snapshot = try std.fmt.allocPrint(testing.allocator, "{s}/codedb.snapshot", .{project_path});
    defer testing.allocator.free(root_snapshot);
    if (std.Io.Dir.cwd().access(io, root_snapshot, .{})) |_| {
        return error.UnexpectedRootSnapshot;
    } else |_| {}

    var default_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const default_path_len = try std.Io.Dir.cwd().realPathFile(io, ".", &default_path_buf);
    const default_path = default_path_buf[0..default_path_len];

    var default_explorer = Explorer.init(testing.allocator, explore_mod.Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer default_explorer.deinit();
    var default_store = Store.init(testing.allocator);
    defer default_store.deinit();

    var cache = ProjectCache.init(testing.allocator, default_path, explore_mod.Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer cache.deinit();

    const ctx = try cache.get(io, project_path, &default_explorer, &default_store);
    try testing.expect(ctx.explorer.outlines.contains("src/main.zig"));
}

test "issue-353: explicit default project loads snapshot when default explorer is empty" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{
        .sub_path = "src/main.zig",
        .data = "pub fn issue353() void {}\n",
    });

    var project_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const project_path_len = try tmp.dir.realPathFile(io, ".", &project_path_buf);
    const project_path = project_path_buf[0..project_path_len];

    const data_dir = getProjectDataDir(testing.allocator, project_path) orelse return error.OutOfMemory;
    defer testing.allocator.free(data_dir);
    const central_snapshot = try std.fmt.allocPrint(testing.allocator, "{s}/codedb.snapshot", .{data_dir});
    defer testing.allocator.free(central_snapshot);
    const project_txt = try std.fmt.allocPrint(testing.allocator, "{s}/project.txt", .{data_dir});
    defer testing.allocator.free(project_txt);
    defer {
        std.Io.Dir.cwd().deleteFile(io, central_snapshot) catch {};
        std.Io.Dir.cwd().deleteFile(io, project_txt) catch {};
        std.Io.Dir.cwd().deleteDir(io, data_dir) catch {};
    }

    var snapshot_src = Explorer.init(testing.allocator, explore_mod.Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer snapshot_src.deinit();
    snapshot_src.setRoot(io, project_path);
    try snapshot_src.indexFile("src/main.zig", "pub fn issue353() void {}\n");
    try snapshot_mod.writeProjectCacheSnapshot(io, &snapshot_src, project_path, testing.allocator);

    var default_explorer = Explorer.init(testing.allocator, explore_mod.Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer default_explorer.deinit();
    default_explorer.setRoot(io, project_path);
    var default_store = Store.init(testing.allocator);
    defer default_store.deinit();

    var cache = ProjectCache.init(testing.allocator, project_path, explore_mod.Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer cache.deinit();

    const ctx = try cache.get(io, project_path, &default_explorer, &default_store);
    try testing.expect(ctx.explorer != &default_explorer);
    try testing.expect(ctx.explorer.outlines.contains("src/main.zig"));
    try testing.expectEqual(@as(u64, 0), default_store.currentSeq());
}

test "issue-353: project cache invalidation reloads newly written snapshots" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "src");

    var project_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const project_path_len = try tmp.dir.realPathFile(io, ".", &project_path_buf);
    const project_path = project_path_buf[0..project_path_len];

    const data_dir = getProjectDataDir(testing.allocator, project_path) orelse return error.OutOfMemory;
    defer testing.allocator.free(data_dir);
    const central_snapshot = try std.fmt.allocPrint(testing.allocator, "{s}/codedb.snapshot", .{data_dir});
    defer testing.allocator.free(central_snapshot);
    const project_txt = try std.fmt.allocPrint(testing.allocator, "{s}/project.txt", .{data_dir});
    defer testing.allocator.free(project_txt);
    defer {
        std.Io.Dir.cwd().deleteFile(io, central_snapshot) catch {};
        std.Io.Dir.cwd().deleteFile(io, project_txt) catch {};
        std.Io.Dir.cwd().deleteDir(io, data_dir) catch {};
    }

    var snapshot_src = Explorer.init(testing.allocator, explore_mod.Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer snapshot_src.deinit();
    snapshot_src.setRoot(io, project_path);
    try snapshot_src.indexFile("src/old.zig", "pub fn oldSymbol() void {}\n");
    try snapshot_mod.writeProjectCacheSnapshot(io, &snapshot_src, project_path, testing.allocator);

    var default_explorer = Explorer.init(testing.allocator, explore_mod.Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer default_explorer.deinit();
    var default_store = Store.init(testing.allocator);
    defer default_store.deinit();

    var cache = ProjectCache.init(testing.allocator, "/Users/example/default", explore_mod.Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer cache.deinit();

    const old_ctx = try cache.get(io, project_path, &default_explorer, &default_store);
    try testing.expect(old_ctx.explorer.outlines.contains("src/old.zig"));

    var snapshot_next = Explorer.init(testing.allocator, explore_mod.Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer snapshot_next.deinit();
    snapshot_next.setRoot(io, project_path);
    try snapshot_next.indexFile("src/new.zig", "pub fn newSymbol() void {}\n");
    try snapshot_mod.writeProjectCacheSnapshot(io, &snapshot_next, project_path, testing.allocator);

    cache.invalidate(project_path);

    const new_ctx = try cache.get(io, project_path, &default_explorer, &default_store);
    try testing.expect(!new_ctx.explorer.outlines.contains("src/old.zig"));
    try testing.expect(new_ctx.explorer.outlines.contains("src/new.zig"));
}

test "codedb_snapshot cache reuses output until store seq changes" {
    const io = testing.io;
    const alloc = testing.allocator;

    var explorer = Explorer.init(alloc, explore_mod.Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    try explorer.indexFile("src/main.zig", "pub fn main() void {}\n");

    var store = Store.init(alloc);
    defer store.deinit();
    _ = try store.recordSnapshot("src/main.zig", "pub fn main() void {}\n".len, 0xabc);

    var agents = AgentRegistry.init(alloc);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    var bench_ctx = BenchContext.init(alloc, ".", explore_mod.Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer bench_ctx.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, "{}", .{});
    defer parsed.deinit();
    const args = &parsed.value.object;

    var first: std.ArrayList(u8) = .empty;
    defer first.deinit(alloc);
    bench_ctx.runDispatch(io, alloc, .codedb_snapshot, args, &first, &store, &explorer, &agents);

    var second: std.ArrayList(u8) = .empty;
    defer second.deinit(alloc);
    bench_ctx.runDispatch(io, alloc, .codedb_snapshot, args, &second, &store, &explorer, &agents);
    try testing.expectEqualStrings(first.items, second.items);

    try explorer.indexFile("src/main.zig", "pub fn changed() void {}\n");
    _ = try store.recordSnapshot("src/main.zig", "pub fn changed() void {}\n".len, 0xdef);

    var third: std.ArrayList(u8) = .empty;
    defer third.deinit(alloc);
    bench_ctx.runDispatch(io, alloc, .codedb_snapshot, args, &third, &store, &explorer, &agents);
    try testing.expect(std.mem.indexOf(u8, third.items, "changed") != null);
    try testing.expect(!std.mem.eql(u8, first.items, third.items));
}
