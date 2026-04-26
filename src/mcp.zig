// codedb MCP server — JSON-RPC 2.0 over stdio
const cio = @import("cio.zig");
//
// Exposes codedb's exploration + edit engine as MCP tools.
// Uses mcp-zig for protocol utilities; adds roots support for workspace awareness.

const std = @import("std");
const testing = std.testing;
const mcp_lib = @import("mcp");
const mcpj = mcp_lib.json;
const Root = mcp_lib.mcp.Root;
const Store = @import("store.zig").Store;
const explore_mod = @import("explore.zig");
const Explorer = explore_mod.Explorer;
const AgentRegistry = @import("agent.zig").AgentRegistry;
const snapshot_json = @import("snapshot_json.zig");
const watcher = @import("watcher.zig");
const edit_mod = @import("edit.zig");
const idx = @import("index.zig");
const snapshot_mod = @import("snapshot.zig");
const telemetry_mod = @import("telemetry.zig");
const git_mod = @import("git.zig");
const root_policy = @import("root_policy.zig");
const release_info = @import("release_info.zig");
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
            out.appendSlice(alloc, fresh) catch {};
            alloc.free(fresh);
            return;
        }

        if (self.bytes) |bytes| {
            if (self.seq == seq) {
                alloc.free(fresh);
                out.appendSlice(alloc, bytes) catch {};
                return;
            }
            alloc.free(bytes);
        }

        self.seq = seq;
        self.bytes = fresh;
        out.appendSlice(alloc, fresh) catch {};
    }
};

const ProjectCtx = struct {
    explorer: *Explorer,
    store: *Store,
    snapshot_cache: *SnapshotCache,
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

    if (idx.WordIndex.readFromDisk(io, data_dir, allocator)) |loaded| {
        explorer.replaceWordIndex(loaded);
    } else {
        explorer.disableWordIndexDiskLoad();
    }
}

fn shouldLoadWordIndexForSearch(args: *const std.json.ObjectMap) bool {
    if (getBool(args, "regex")) return false;
    const query = getStr(args, "query") orelse return false;
    if (query.len < 2 or query.len > 256) return false;

    var saw_word_char = false;
    for (query) |c| {
        const is_word_char =
            (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '_';
        if (!is_word_char) return false;
        if (c != '_') saw_word_char = true;
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
        last_used: i64,
    };

    mu: cio.RwLock,
    alloc: std.mem.Allocator,
    entries: [MAX_CACHED]?*Entry,
    default_path: []const u8,
    default_snapshot_cache: SnapshotCache,

    fn init(alloc_: std.mem.Allocator, default_path_: []const u8) ProjectCache {
        return .{
            .mu = .{},
            .alloc = alloc_,
            .entries = [_]?*Entry{null} ** MAX_CACHED,
            .default_path = default_path_,
            .default_snapshot_cache = .{},
        };
    }

    fn deinit(self: *ProjectCache) void {
        self.default_snapshot_cache.deinit(self.alloc);
        for (&self.entries) |*slot| {
            if (slot.*) |entry| {
                entry.snapshot_cache.deinit(self.alloc);
                entry.explorer.deinit();
                entry.store.deinit();
                self.alloc.free(entry.path);
                self.alloc.destroy(entry);
                slot.* = null;
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
        const p = path orelse return ProjectCtx{ .explorer = default_exp, .store = default_store, .snapshot_cache = &self.default_snapshot_cache };
        if (std.mem.eql(u8, p, self.default_path))
            return ProjectCtx{ .explorer = default_exp, .store = default_store, .snapshot_cache = &self.default_snapshot_cache };
        if (!root_policy.isIndexableRoot(p))
            return error.PathNotAllowed;

        self.mu.lock();
        defer self.mu.unlock();

        const now = cio.milliTimestamp();
        for (&self.entries) |*slot| {
            if (slot.*) |entry| {
                if (std.mem.eql(u8, entry.path, p)) {
                    entry.last_used = now;
                    return ProjectCtx{ .explorer = &entry.explorer, .store = &entry.store, .snapshot_cache = &entry.snapshot_cache };
                }
            }
        }

        // Cache miss — load from snapshot
        const new_entry = self.alloc.create(Entry) catch return error.OutOfMemory;
        new_entry.path = self.alloc.dupe(u8, p) catch {
            self.alloc.destroy(new_entry);
            return error.OutOfMemory;
        };
        new_entry.explorer = Explorer.init(self.alloc);
        new_entry.explorer.setRoot(io, p);
        new_entry.store = Store.init(self.alloc);
        new_entry.snapshot_cache = .{};
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
            evict.snapshot_cache.deinit(self.alloc);
            evict.explorer.deinit();
            evict.store.deinit();
            self.alloc.free(evict.path);
            self.alloc.destroy(evict);
            target_slot = oldest_i;
        }

        self.entries[target_slot] = new_entry;
        return ProjectCtx{ .explorer = &new_entry.explorer, .store = &new_entry.store, .snapshot_cache = &new_entry.snapshot_cache };
    }
};

pub const BenchContext = struct {
    cache: ProjectCache,

    pub fn init(alloc: std.mem.Allocator, default_path: []const u8) BenchContext {
        return .{
            .cache = ProjectCache.init(alloc, default_path),
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
        dispatch(io, alloc, tool, args, out, store, explorer, agents, &self.cache);
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
        dispatch(io, alloc, tool, args, &out, store, explorer, agents, &self.cache);
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
        mcpGenerateGuidance(alloc, name, args, is_error, &guidance);

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
};

const tools_list =
    \\{"tools":[
    \\{"name":"codedb_tree","description":"Get the full file tree of the indexed codebase with language detection, line counts, and symbol counts per file. Use this first to understand the project structure.","inputSchema":{"type":"object","properties":{"project":{"type":"string","description":"Optional absolute path to a different project (must have codedb.snapshot)"}},"required":[]}},
    \\{"name":"codedb_outline","description":"START HERE. Get the structural outline of a file: all functions, structs, enums, imports, constants with line numbers. Returns 4-15x fewer tokens than reading the raw file. Always use this before codedb_read to understand file structure first.","inputSchema":{"type":"object","properties":{"path":{"type":"string","description":"File path relative to project root"},"compact":{"type":"boolean","description":"Condensed format without detail comments (default: false)"},"project":{"type":"string","description":"Optional absolute path to a different project (must have codedb.snapshot)"}},"required":["path"]}},
    \\{"name":"codedb_symbol","description":"Find where a symbol is defined across the codebase. Returns file, line, and kind (function/struct/import). Use body=true to include source code. Much more precise than search — finds definitions, not just text matches.","inputSchema":{"type":"object","properties":{"name":{"type":"string","description":"Symbol name to search for (exact match)"},"body":{"type":"boolean","description":"Include source body for each symbol (default: false)"},"project":{"type":"string","description":"Optional absolute path to a different project (must have codedb.snapshot)"}},"required":["name"]}},
    \\{"name":"codedb_search","description":"Full-text search across all indexed files. Returns matching lines with file paths and line numbers. Start with max_results=10 for broad queries. Use scope=true to see the enclosing function/struct for each match. For single identifiers, prefer codedb_word (O(1) lookup) or codedb_symbol (definitions only).","inputSchema":{"type":"object","properties":{"query":{"type":"string","description":"Text to search for (substring match, or regex if regex=true)"},"max_results":{"type":"integer","description":"Maximum results to return (default: 50, start with 10 for broad queries)"},"scope":{"type":"boolean","description":"Annotate results with enclosing symbol scope (default: false)"},"compact":{"type":"boolean","description":"Skip comment and blank lines in results (default: false)"},"regex":{"type":"boolean","description":"Treat query as regex pattern (default: false)"},"project":{"type":"string","description":"Optional absolute path to a different project (must have codedb.snapshot)"}},"required":["query"]}},
    \\{"name":"codedb_word","description":"O(1) word lookup using inverted index. Finds all occurrences of an exact word (identifier) across the codebase. Much faster than search for single-word queries.","inputSchema":{"type":"object","properties":{"word":{"type":"string","description":"Exact word/identifier to look up"},"project":{"type":"string","description":"Optional absolute path to a different project (must have codedb.snapshot)"}},"required":["word"]}},
    \\{"name":"codedb_hot","description":"Get the most recently modified files in the codebase, ordered by recency. Useful to see what's been actively worked on.","inputSchema":{"type":"object","properties":{"limit":{"type":"integer","description":"Number of files to return (default: 10)"},"project":{"type":"string","description":"Optional absolute path to a different project (must have codedb.snapshot)"}},"required":[]}},
    \\{"name":"codedb_deps","description":"Dependency graph queries. Default: which files import the given file (reverse deps). Use direction=depends_on for forward deps. Use transitive=true for full blast radius via BFS traversal. O(1) lookups via bidirectional graph index.","inputSchema":{"type":"object","properties":{"path":{"type":"string","description":"File path to check dependencies for"},"direction":{"type":"string","enum":["imported_by","depends_on"],"description":"imported_by (default): who imports this file. depends_on: what this file imports."},"transitive":{"type":"boolean","description":"Follow dependency chain transitively (default: false)"},"max_depth":{"type":"integer","description":"Max traversal depth for transitive queries (default: unlimited)"},"project":{"type":"string","description":"Optional absolute path to a different project (must have codedb.snapshot)"}},"required":["path"]}},
    \\{"name":"codedb_read","description":"Read file contents. IMPORTANT: Use codedb_outline first to find the line numbers you need, then read only that range with line_start/line_end. Avoid reading entire large files — use compact=true to skip comments and blanks. For understanding file structure, codedb_outline is 4-15x more token-efficient.","inputSchema":{"type":"object","properties":{"path":{"type":"string","description":"File path relative to project root"},"line_start":{"type":"integer","description":"Start line (1-indexed, inclusive). Omit for full file."},"line_end":{"type":"integer","description":"End line (1-indexed, inclusive). Omit to read to EOF."},"if_hash":{"type":"string","description":"Previous content hash. If unchanged, returns short 'unchanged:HASH' response."},"compact":{"type":"boolean","description":"Skip comment and blank lines (default: false)"},"project":{"type":"string","description":"Optional absolute path to a different project (must have codedb.snapshot)"}},"required":["path"]}},
    \\{"name":"codedb_edit","description":"Apply a line-based edit to a file. Supports replace (range), insert (after line), and delete (range) operations.","inputSchema":{"type":"object","properties":{"path":{"type":"string","description":"File path to edit"},"op":{"type":"string","enum":["replace","insert","delete"],"description":"Edit operation type"},"content":{"type":"string","description":"New content (for replace/insert)"},"range_start":{"type":"integer","description":"Start line number (for replace/delete, 1-indexed)"},"range_end":{"type":"integer","description":"End line number (for replace/delete, 1-indexed)"},"after":{"type":"integer","description":"Insert after this line number (for insert)"}},"required":["path","op"]}},
    \\{"name":"codedb_changes","description":"Get files that changed since a sequence number. Use with codedb_status to poll for changes.","inputSchema":{"type":"object","properties":{"since":{"type":"integer","description":"Sequence number to get changes since (default: 0)"}},"required":[]}},
    \\{"name":"codedb_status","description":"Get current codedb status: number of indexed files and current sequence number.","inputSchema":{"type":"object","properties":{"project":{"type":"string","description":"Optional absolute path to a different project (must have codedb.snapshot)"}},"required":[]}},
    \\{"name":"codedb_snapshot","description":"Get the full pre-rendered snapshot of the codebase as a single JSON blob. Contains tree, all outlines, symbol index, and dependency graph. Ideal for caching or deploying to edge workers.","inputSchema":{"type":"object","properties":{"project":{"type":"string","description":"Optional absolute path to a different project (must have codedb.snapshot)"}},"required":[]}},
    \\{"name":"codedb_bundle","description":"Batch multiple queries in one call. Max 20 ops. WARNING: Avoid bundling multiple codedb_read calls on large files — use codedb_outline + codedb_symbol instead. Bundle outline+symbol+search, not full file reads. Total response is not size-capped, so large bundles can exceed token limits.","inputSchema":{"type":"object","properties":{"ops":{"type":"array","items":{"type":"object","properties":{"tool":{"type":"string","description":"Tool name (e.g. codedb_outline, codedb_symbol, codedb_read)"},"arguments":{"type":"object","description":"Tool arguments"}},"required":["tool"]},"description":"Array of tool calls to execute"},"project":{"type":"string","description":"Optional absolute path to a different project (must have codedb.snapshot)"}},"required":["ops"]}},
    \\{"name":"codedb_remote","description":"Query any GitHub repo via cloud intelligence. Default backend 'codegraff' (codedb.codegraff.com) gets file tree, symbol outlines, searches, repo meta, and (where supported) file contents via action=read. Backend 'wiki' (api.wiki.codes) fronts the Hetzner parquet router and adds exact-identifier lookup, hot-pin policy, dependency/CVE scoring artifacts, and commit metadata. For huge repos paginate tree with limit/offset/prefix and commits/dep-history with since/limit. Use action=read with path and optional lines='10-60' to fetch file slices.","inputSchema":{"type":"object","properties":{"repo":{"type":"string","description":"GitHub repo in owner/repo format (e.g. justrach/merjs). With backend=wiki, raw wiki slugs such as chromium are also accepted."},"action":{"type":"string","enum":["tree","outline","search","meta","read","symbol","policy","deps","score","cves","commits","branches","dep-history"],"description":"What to query. codegraff backend: tree, outline, search, meta, read. wiki backend: tree, outline, search, symbol, policy, deps, score, cves, commits, branches, dep-history."},"query":{"type":"string","description":"Action-specific argument. search: text query. symbol: identifier name. outline: file path."},"path":{"type":"string","description":"For action=read: the file path to fetch."},"lines":{"type":"string","description":"For action=read: line range like '10-60' (1-indexed, inclusive). Omit for full file."},"limit":{"type":"integer","description":"For tree/commits/dep-history: cap the number of items returned (server may enforce its own ceiling)."},"offset":{"type":"integer","description":"For tree: skip the first N items (pagination)."},"prefix":{"type":"string","description":"For tree: only return paths starting with this prefix (e.g. 'src/')."},"expand":{"type":"boolean","description":"For tree: when true, return the full file list. When false (and the server supports it) returns a compact directory summary."},"since":{"type":"string","description":"For commits/dep-history: ISO timestamp or commit SHA to start from."},"scope":{"type":"string","enum":["runtime","all"],"description":"For wiki score/cves only. Defaults to runtime; use all to include dev/tooling dependencies."},"backend":{"type":"string","enum":["codegraff","wiki"],"description":"Which remote indexer to query. Default: codegraff. Use 'wiki' for api.wiki.codes symbol, policy, dependency, CVE, and history actions."}},"required":["repo","action"]}},
    \\{"name":"codedb_projects","description":"List all locally indexed projects on this machine. Shows project paths, data directory hashes, and whether a snapshot exists. Use to discover what codebases are available.","inputSchema":{"type":"object","properties":{},"required":[]}},
    \\{"name":"codedb_index","description":"Index a local folder on this machine. Scans all source files, builds outlines/trigrams/word indexes, and creates a codedb.snapshot in the target directory. After indexing, the folder is queryable via the project param on any tool.","inputSchema":{"type":"object","properties":{"path":{"type":"string","description":"Absolute path to the folder to index (e.g. /Users/you/myproject)"}},"required":["path"]}},
    \\{"name":"codedb_find","description":"Fuzzy file search — finds files by approximate name. Typo-tolerant subsequence matching with word-boundary and filename bonuses. Use when you know roughly what file you're looking for but not the exact path. Much faster than codedb_tree + manual scan.","inputSchema":{"type":"object","properties":{"query":{"type":"string","description":"Fuzzy search query (e.g. 'authmidlware', 'test_auth', 'main.zig')"},"max_results":{"type":"integer","description":"Maximum results to return (default: 10)"},"project":{"type":"string","description":"Optional absolute path to a different project (must have codedb.snapshot)"}},"required":["query"]}},
    \\{"name":"codedb_query","description":"Composable search pipeline — chain multiple operations where each step feeds the next. Replaces multi-tool workflows with a single call. Pipeline ops: find (fuzzy file search), search (content grep), filter (by extension/path glob), deps (expand via dependency graph), outline (get symbols), read (file contents), sort (by score/path), limit (truncate). Each step operates on the file set from the previous step.","inputSchema":{"type":"object","properties":{"pipeline":{"type":"array","items":{"type":"object"},"description":"Array of pipeline steps. Each step has 'op' (find/search/filter/deps/outline/read/sort/limit) and op-specific params. Steps execute in order, each filtering/transforming the file set from the previous step. deps op: {\"op\":\"deps\",\"direction\":\"imported_by|depends_on\",\"transitive\":true,\"max_depth\":3}"},"project":{"type":"string","description":"Optional absolute path to a different project"}},"required":["pipeline"]}}
    \\]}
;

// ── MCP Server ──────────────────────────────────────────────────────────────

/// Monotonic timestamp of last MCP request, used by idle-exit watchdog.
pub var last_activity: std.atomic.Value(i64) = std.atomic.Value(i64).init(0);

/// How long (ms) the server may sit idle before auto-exiting.
/// Claude Code restarts MCP servers on demand, so this is safe.
pub const idle_timeout_ms: i64 = 60 * 60 * 1000; // 1 hour — allows long debugging sessions; stdin EOF is still detected separately.

/// How often the watchdog checks whether the MCP client disconnected.
pub const dead_client_poll_ms: u64 = 1000;

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
    telem: *telemetry_mod.Telemetry,
) void {
    const stdout = cio.File.stdout();
    const stdin = std.Io.File.stdin();
    last_activity.store(cio.milliTimestamp(), .release);

    var cache = ProjectCache.init(alloc, default_path);
    defer cache.deinit();

    var session = Session{
        .alloc = alloc,
        .stdout = stdout,
    };
    defer session.deinit();

    var read_buf: [4096]u8 = undefined;
    var stdin_reader = stdin.reader(io, &read_buf);

    while (true) {
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
            }
        } else if (mcpj.eql(method, "notifications/roots/list_changed")) {
            if (session.client_supports_roots) {
                requestRoots(&session);
            }
        } else if (mcpj.eql(method, "tools/list")) {
            if (!is_notification) writeResult(alloc, stdout, id, tools_list);
        } else if (mcpj.eql(method, "tools/call")) {
            handleCall(io, alloc, root, stdout, id, store, explorer, agents, &cache, telem);
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
    const init_result = std.fmt.allocPrint(s.alloc,
        \\{{"protocolVersion":"2025-06-18","capabilities":{{"tools":{{"listChanged":false}}}},"serverInfo":{{"name":"codedb","version":"{s}"}}}}
    , .{release_info.semver}) catch return;
    defer s.alloc.free(init_result);
    writeResult(s.alloc, s.stdout, id, init_result);
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
    stdout.writeAll(buf.items) catch {};
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
    var args_value = params.get("arguments") orelse std.json.Value{ .object = .empty };
    if (args_value != .object) {
        if (!is_notification) writeError(alloc, stdout, id, -32602, "arguments must be object");
        return;
    }
    const args = &args_value.object;

    const tool = std.meta.stringToEnum(Tool, name) orelse {
        if (!is_notification) writeError(alloc, stdout, id, -32602, "Unknown tool");
        return;
    };

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    const t0 = cio.nanoTimestamp();
    dispatch(io, alloc, tool, args, &out, store, explorer, agents, cache);
    const elapsed = cio.nanoTimestamp() - t0;

    const is_error = std.mem.startsWith(u8, out.items, "error:");
    telem.recordToolCall(name, elapsed, is_error, out.items.len);

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

    // Block 1: Human-readable colored summary (ANSI — preview pane always renders it)
    var summary: std.ArrayList(u8) = .empty;
    defer summary.deinit(alloc);
    summary.ensureTotalCapacity(alloc, 256) catch {};
    summary.appendSlice(alloc, if (is_error) MCP_RED ++ MCP_CROSS ++ " " ++ MCP_RESET else MCP_GREEN ++ MCP_CHECK ++ " " ++ MCP_RESET) catch {};
    summary.appendSlice(alloc, mcpToolIcon(name)) catch {};
    mcpGenerateSummary(alloc, name, args, out.items, is_error, &summary);
    var dur_buf: [96]u8 = undefined;
    summary.appendSlice(alloc, mcpFormatDuration(&dur_buf, elapsed)) catch {};

    // Block 3: Guidance hints
    var guidance: std.ArrayList(u8) = .empty;
    defer guidance.deinit(alloc);
    mcpGenerateGuidance(alloc, name, args, is_error, &guidance);

    // Assemble 3-block MCP content envelope
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(alloc);
    result.ensureTotalCapacity(alloc, out.items.len + summary.items.len + guidance.items.len + 256) catch {};
    result.appendSlice(alloc, "{\"content\":[") catch return;

    // Block 1 (summary)
    if (summary.items.len > 0) {
        result.appendSlice(alloc, "{\"type\":\"text\",\"text\":\"") catch return;
        mcpj.writeEscaped(alloc, &result, summary.items);
        result.appendSlice(alloc, "\"},") catch return;
    }

    // Block 2 (raw data — no colors, zero extra tokens to model)
    result.appendSlice(alloc, "{\"type\":\"text\",\"text\":\"") catch return;
    mcpj.writeEscaped(alloc, &result, out.items);
    result.appendSlice(alloc, "\"}") catch return;

    // Block 3 (guidance)
    if (guidance.items.len > 0) {
        result.appendSlice(alloc, ",{\"type\":\"text\",\"text\":\"") catch return;
        mcpj.writeEscaped(alloc, &result, guidance.items);
        result.appendSlice(alloc, "\"}") catch return;
    }

    result.appendSlice(alloc, if (is_error) "],\"isError\":true}" else "],\"isError\":false}") catch return;
    writeResult(alloc, stdout, id, result.items);
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
) void {
    const project_path = getStr(args, "project");
    const ctx = cache.get(io, project_path, default_explorer, default_store) catch |err| {
        out.appendSlice(alloc, "error: failed to load project: ") catch {};
        out.appendSlice(alloc, @errorName(err)) catch {};
        return;
    };

    if (tool == .codedb_word or (tool == .codedb_search and shouldLoadWordIndexForSearch(args))) {
        const effective_project = project_path orelse cache.default_path;
        loadProjectWordIndexFromDiskIfPresent(io, ctx.explorer, effective_project, alloc);
    }

    switch (tool) {
        .codedb_tree => handleTree(alloc, out, ctx.explorer),
        .codedb_outline => handleOutline(alloc, args, out, ctx.explorer),
        .codedb_symbol => handleSymbol(alloc, args, out, ctx.explorer),
        .codedb_search => handleSearch(alloc, args, out, ctx.explorer),
        .codedb_word => handleWord(alloc, args, out, ctx.explorer),
        .codedb_hot => handleHot(alloc, args, out, ctx.store, ctx.explorer),
        .codedb_deps => handleDeps(alloc, args, out, ctx.explorer),
        .codedb_read => handleRead(io, alloc, args, out, ctx.explorer),
        .codedb_edit => handleEdit(io, alloc, args, out, default_store, default_explorer, agents),
        .codedb_changes => handleChanges(alloc, args, out, default_store),
        .codedb_status => handleStatus(alloc, out, ctx.store, ctx.explorer),
        .codedb_snapshot => handleSnapshot(alloc, out, ctx.explorer, ctx.store, ctx.snapshot_cache),
        .codedb_bundle => handleBundle(io, alloc, args, out, ctx.store, ctx.explorer, agents, cache),
        .codedb_remote => handleRemote(alloc, args, out),
        .codedb_projects => handleProjects(io, alloc, out),
        .codedb_index => handleIndex(io, alloc, args, out),
        .codedb_find => handleFind(io, alloc, args, out, ctx.explorer),
        .codedb_query => handleQuery(alloc, args, out, ctx.explorer, ctx.store),
    }
}

// ── Tool handlers ───────────────────────────────────────────────────────────

fn handleTree(alloc: std.mem.Allocator, out: *std.ArrayList(u8), explorer: *Explorer) void {
    const tree = explorer.getTree(alloc, false) catch {
        out.appendSlice(alloc, "error: failed to get tree") catch {};
        return;
    };
    defer alloc.free(tree);
    out.appendSlice(alloc, tree) catch {};
}

fn handleOutline(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8), explorer: *Explorer) void {
    const path = getStr(args, "path") orelse {
        out.appendSlice(alloc, "error: missing 'path' argument") catch {};
        return;
    };
    const compact = getBool(args, "compact");
    var outline = explorer.getOutline(path, alloc) catch {
        out.appendSlice(alloc, "error: outline retrieval failed") catch {};
        return;
    } orelse {
        out.appendSlice(alloc, "error: file not indexed: ") catch {};
        out.appendSlice(alloc, path) catch {};
        return;
    };
    defer outline.deinit();
    const w = cio.listWriter(out, alloc);
    w.print("{s} ({s}, {d} lines, {d} bytes)\n", .{
        outline.path, @tagName(outline.language), outline.line_count, outline.byte_size,
    }) catch {};
    for (outline.symbols.items) |sym| {
        if (compact) {
            w.print("  L{d}: {s} {s}\n", .{ sym.line_start, @tagName(sym.kind), sym.name }) catch {};
        } else {
            w.print("  L{d}: {s} {s}", .{ sym.line_start, @tagName(sym.kind), sym.name }) catch {};
            if (sym.detail) |d| w.print("  // {s}", .{d}) catch {};
            w.writeAll("\n") catch {};
        }
    }
}

fn handleSymbol(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8), explorer: *Explorer) void {
    const name = getStr(args, "name") orelse {
        out.appendSlice(alloc, "error: missing 'name' argument") catch {};
        return;
    };
    const include_body = getBool(args, "body");
    const results = explorer.findAllSymbols(name, alloc) catch {
        out.appendSlice(alloc, "error: search failed") catch {};
        return;
    };
    defer alloc.free(results);

    if (results.len == 0) {
        out.appendSlice(alloc, "no results for: ") catch {};
        out.appendSlice(alloc, name) catch {};
        return;
    }

    const w = cio.listWriter(out, alloc);
    w.print("{d} results for '{s}':\n", .{ results.len, name }) catch {};
    for (results) |r| {
        w.print("  {s}:{d} ({s})", .{ r.path, r.symbol.line_start, @tagName(r.symbol.kind) }) catch {};
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
        return;
    };
    const max_results: usize = if (getInt(args, "max_results")) |n| @intCast(@max(1, @min(n, 10000))) else 50;
    const scope = getBool(args, "scope");
    const compact = getBool(args, "compact");
    const is_regex = getBool(args, "regex");

    if (scope) {
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

        const w = cio.listWriter(out, alloc);
        w.print("{d} results for '{s}':\n", .{ results.len, query }) catch {};
        for (results) |r| {
            if (compact and explore_mod.isCommentOrBlank(r.line_text, explore_mod.detectLanguage(r.path))) continue;
            if (r.scope_name) |sn| {
                w.print("  {s}:{d}: {s}  [in {s} ({s}, L{d}-L{d})]\n", .{
                    r.path, r.line_num, r.line_text, sn, @tagName(r.scope_kind.?), r.scope_start, r.scope_end,
                }) catch {};
            } else {
                w.print("  {s}:{d}: {s}\n", .{ r.path, r.line_num, r.line_text }) catch {};
            }
        }
    } else {
        const results = if (is_regex)
            explorer.searchContentRegex(query, alloc, max_results) catch {
                out.appendSlice(alloc, "error: regex search failed") catch {};
                return;
            }
        else
            explorer.searchContent(query, alloc, max_results) catch {
                out.appendSlice(alloc, "error: search failed") catch {};
                return;
            };
        defer {
            for (results) |r| {
                alloc.free(r.line_text);
                alloc.free(r.path);
            }
            alloc.free(results);
        }

        const w = cio.listWriter(out, alloc);
        w.print("{d} results for '{s}':\n", .{ results.len, query }) catch {};
        var file_counts = std.StringHashMap(u8).init(alloc);
        defer file_counts.deinit();
        const max_per_file: u8 = 5;
        var shown: usize = 0;
        for (results) |r| {
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
            w.print("  {s}:{d}: {s}\n", .{ r.path, r.line_num, r.line_text }) catch {};
            shown += 1;
        }
        if (shown < results.len) {
            w.print("({d} shown, {d} truncated)\n", .{ shown, results.len - shown }) catch {};
        }
    }
}

fn handleWord(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8), explorer: *Explorer) void {
    const word = getStr(args, "word") orelse {
        out.appendSlice(alloc, "error: missing 'word' argument") catch {};
        return;
    };
    const hits = explorer.searchWord(word, alloc) catch {
        out.appendSlice(alloc, "error: word search failed") catch {};
        return;
    };
    defer alloc.free(hits);

    const w = cio.listWriter(out, alloc);
    w.print("{d} hits for '{s}':\n", .{ hits.len, word }) catch {};
    explorer.mu.lockShared();
    defer explorer.mu.unlockShared();
    for (hits) |h| {
        w.print("  {s}:{d}\n", .{ explorer.word_index.hitPath(h), h.line_num }) catch {};
    }
}

fn handleHot(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8), store: *Store, explorer: *Explorer) void {
    const limit: usize = if (getInt(args, "limit")) |n| @intCast(@min(@max(1, n), 1000)) else 10;
    const hot = explorer.getHotFiles(store, alloc, limit) catch {
        out.appendSlice(alloc, "error: hot files failed") catch {};
        return;
    };
    defer {
        for (hot) |path| alloc.free(path);
        alloc.free(hot);
    }

    const w = cio.listWriter(out, alloc);
    for (hot, 0..) |path, i| {
        w.print("{d}. {s}\n", .{ i + 1, path }) catch {};
    }
}

fn handleDeps(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8), explorer: *Explorer) void {
    const path = getStr(args, "path") orelse {
        out.appendSlice(alloc, "error: missing 'path' argument") catch {};
        return;
    };
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
            results = explorer.getImportedBy(path, alloc) catch {
                out.appendSlice(alloc, "error: deps failed") catch {};
                return;
            };
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
    } else {
        for (results) |dep| {
            w.print("  {s}\n", .{dep}) catch {};
        }
        w.print("({d} files)\n", .{results.len}) catch {};
    }
}

fn handleRead(io: std.Io, alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8), explorer: *Explorer) void {
    const path = getStr(args, "path") orelse {
        out.appendSlice(alloc, "error: missing 'path' argument") catch {};
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
            return;
        };
    };
    defer alloc.free(content);

    // Content-hash ETag
    const hash = std.hash.Wyhash.hash(0, content);
    var hash_buf: [16]u8 = undefined;
    const hash_str = std.fmt.bufPrint(&hash_buf, "{x}", .{hash}) catch "";
    const if_hash = getStr(args, "if_hash");
    if (if_hash) |prev| {
        if (std.mem.eql(u8, prev, hash_str)) {
            out.appendSlice(alloc, "unchanged:") catch {};
            out.appendSlice(alloc, hash_str) catch {};
            return;
        }
    }

    // Line range params
    const line_start_raw = getInt(args, "line_start");
    const line_end_raw = getInt(args, "line_end");
    const compact = getBool(args, "compact");
    const has_range = line_start_raw != null or line_end_raw != null;

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

fn handleEdit(io: std.Io, alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8), store: *Store, explorer: *Explorer, agents: *AgentRegistry) void {
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
    const op: @import("version.zig").Op = if (eql(op_str, "insert"))
        .insert
    else if (eql(op_str, "delete"))
        .delete
    else if (eql(op_str, "replace"))
        .replace
    else {
        out.appendSlice(alloc, "error: unknown op, must be 'replace', 'insert', or 'delete'") catch {};
        return;
    };

    const content = getStr(args, "content");
    const range_start = getInt(args, "range_start");
    const range_end = getInt(args, "range_end");
    const after = getInt(args, "after");

    // Use agent 1 (the __filesystem__ agent registered at startup).
    // TODO: agent_id is hardcoded to 1 — two MCP clients share the same agent_id and
    // could both acquire locks on different files without conflict, but cannot detect
    // concurrent edits to the same file from separate connections.
    var req = edit_mod.EditRequest{
        .path = path,
        .agent_id = 1,
        .op = op,
        .content = content,
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
        return;
    };

    const w = cio.listWriter(out, alloc);
    w.print("edit applied: seq={d}, size={d}, hash={d}", .{ result.seq, result.new_size, result.new_hash }) catch {};
}

fn handleChanges(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8), store: *Store) void {
    const since: u64 = if (getInt(args, "since")) |n| @intCast(@min(@max(0, n), std.math.maxInt(u64))) else 0;
    const changes = store.changesSinceDetailed(since, alloc) catch {
        out.appendSlice(alloc, "error: changes query failed") catch {};
        return;
    };
    defer alloc.free(changes);

    const w = cio.listWriter(out, alloc);
    w.print("seq: {d}, {d} files changed since {d}:\n", .{ store.currentSeq(), changes.len, since }) catch {};
    for (changes) |c| {
        w.print("  {s} (seq={d}, op={s}, size={d})\n", .{ c.path, c.seq, @tagName(c.op), c.size }) catch {};
    }
}

fn handleStatus(alloc: std.mem.Allocator, out: *std.ArrayList(u8), store: *Store, explorer: *Explorer) void {
    store.mu.lock();
    const file_count = store.files.count();
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
        store.currentSeq(),
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

fn handleBundle(
    io: std.Io,
    alloc: std.mem.Allocator,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
    default_store: *Store,
    default_explorer: *Explorer,
    agents: *AgentRegistry,
    cache: *ProjectCache,
) void {
    const ops_val = args.get("ops") orelse {
        out.appendSlice(alloc, "error: missing 'ops' argument") catch {};
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
    // Refresh the idle clock as we start the bundle — long bundles (slow
    // sub-ops, many ops, remote fetches) would otherwise leave
    // `last_activity` frozen at message-arrival time, and the watchdog
    // would close stdin mid-processing. Repeated inside the loop so each
    // completed sub-op keeps us marked active. See #278.
    last_activity.store(cio.milliTimestamp(), .release);
    for (ops, 0..) |op, i| {
        if (op != .object) {
            w.print("--- [{d}] error ---\nop must be an object\n", .{i}) catch {};
            continue;
        }
        const op_obj = &op.object;
        const tool_name = getStr(op_obj, "tool") orelse {
            w.print("--- [{d}] error ---\nmissing 'tool' field\n", .{i}) catch {};
            continue;
        };

        const tool = std.meta.stringToEnum(Tool, tool_name) orelse {
            w.print("--- [{d}] {s} ---\nerror: unknown tool\n", .{ i, tool_name }) catch {};
            continue;
        };

        // Reject recursive bundle and write operations
        if (tool == .codedb_bundle) {
            w.print("--- [{d}] {s} ---\nerror: recursive bundle not allowed\n", .{ i, tool_name }) catch {};
            continue;
        }
        if (tool == .codedb_edit) {
            w.print("--- [{d}] {s} ---\nerror: write operations not allowed in bundle\n", .{ i, tool_name }) catch {};
            continue;
        }

        var empty_args: std.json.ObjectMap = .empty;
        defer empty_args.deinit(alloc);
        var sub_args_val = op_obj.get("arguments") orelse std.json.Value{ .object = empty_args };
        if (sub_args_val != .object) {
            w.print("--- [{d}] {s} ---\nerror: arguments must be object\n", .{ i, tool_name }) catch {};
            continue;
        }
        const sub_args = &sub_args_val.object;

        var sub_out: std.ArrayList(u8) = .empty;
        defer sub_out.deinit(alloc);

        dispatch(io, alloc, tool, sub_args, &sub_out, default_store, default_explorer, agents, cache);

        // Check size BEFORE appending to prevent blowout
        if (out.items.len + sub_out.items.len > 200 * 1024) {
            w.print("--- [{d}] {s} ---\nTRUNCATED: adding this result would exceed 200KB. Use codedb_outline + targeted reads instead of full file reads.\n", .{ i, tool_name }) catch {};
            break;
        }

        w.print("--- [{d}] {s} ---\n", .{ i, tool_name }) catch {};
        out.appendSlice(alloc, sub_out.items) catch {};
        w.writeAll("\n") catch {};

        // Per-op activity refresh — see top of this fn.
        last_activity.store(cio.milliTimestamp(), .release);
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

fn isCodegraffRepo(repo: []const u8) bool {
    if (repo.len == 0 or repo[0] == '/') return false;
    if (std.mem.indexOf(u8, repo, "..") != null or
        std.mem.indexOf(u8, repo, "//") != null)
    {
        return false;
    }
    const slash_pos = std.mem.indexOfScalar(u8, repo, '/') orelse return false;
    if (std.mem.indexOfScalarPos(u8, repo, slash_pos + 1, '/') != null) return false;
    return isRemoteRepoPart(repo[0..slash_pos]) and isRemoteRepoPart(repo[slash_pos + 1 ..]);
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
        if (!isRemoteRepoPart(repo[0..slash_pos]) or !isRemoteRepoPart(repo[slash_pos + 1 ..])) return null;

        @memcpy(buf[0..repo.len], repo);
        buf[slash_pos] = '-';
        return buf[0..repo.len];
    }

    if (!isRemoteRepoPart(repo)) return null;
    @memcpy(buf[0..repo.len], repo);
    return buf[0..repo.len];
}

test "wikiSlugForRepo normalizes owner repo and raw slugs" {
    var buf: [256]u8 = undefined;

    try testing.expectEqualStrings("justrach-codedb", wikiSlugForRepo("justrach/codedb", buf[0..]).?);
    try testing.expectEqualStrings("vercel-next.js", wikiSlugForRepo("vercel/next.js", buf[0..]).?);
    try testing.expectEqualStrings("chromium", wikiSlugForRepo("chromium", buf[0..]).?);
}

test "remote repo validation rejects traversal and malformed paths" {
    var buf: [256]u8 = undefined;

    try testing.expect(isCodegraffRepo("justrach/codedb"));
    try testing.expect(!isCodegraffRepo("chromium"));
    try testing.expect(!isCodegraffRepo("../codedb"));
    try testing.expect(!isCodegraffRepo("justrach//codedb"));
    try testing.expect(!isCodegraffRepo("justrach/codedb/extra"));

    try testing.expect(wikiSlugForRepo("chromium", buf[0..]) != null);
    try testing.expect(wikiSlugForRepo("../codedb", buf[0..]) == null);
    try testing.expect(wikiSlugForRepo("justrach//codedb", buf[0..]) == null);
    try testing.expect(wikiSlugForRepo("justrach/codedb/extra", buf[0..]) == null);
}

const RemoteParam = struct { name: []const u8, value: []const u8 };

/// Run `curl -G` against URL with optional query params. Caller frees result.stdout/stderr.
fn fetchRemote(
    alloc: std.mem.Allocator,
    url: []const u8,
    params: []const RemoteParam,
) !cio.CaptureResult {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);

    try argv.append(alloc, "curl");
    try argv.append(alloc, "-sf");
    try argv.append(alloc, "--max-time");
    try argv.append(alloc, "30");

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

    return cio.runCapture(.{ .allocator = alloc, .argv = argv.items });
}

fn handleRemote(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8)) void {
    const repo = getStr(args, "repo") orelse {
        out.appendSlice(alloc, "error: missing 'repo' (e.g. justrach/merjs)") catch {};
        return;
    };
    const action = getStr(args, "action") orelse {
        out.appendSlice(alloc, "error: missing 'action' (tree, outline, search, meta, read, symbol, policy, deps, score, cves, commits, branches, dep-history)") catch {};
        return;
    };

    // Backend selection: default preserves existing behavior. "wiki" routes
    // directly to api.wiki.codes, which fronts the Hetzner parquet router and
    // exposes code intelligence plus compact dependency/security artifacts.
    const backend = getStr(args, "backend") orelse "codegraff";
    const is_wiki = std.mem.eql(u8, backend, "wiki");
    const is_codegraff = std.mem.eql(u8, backend, "codegraff");
    if (!is_wiki and !is_codegraff) {
        out.appendSlice(alloc, "error: invalid backend, must be one of: codegraff, wiki") catch {};
        return;
    }

    // Per-backend action allowlists. Wiki adds symbol/security/history
    // artifacts and drops meta; codegraff adds 'read' for line-range fetches.
    const codegraff_actions = [_][]const u8{ "tree", "outline", "search", "meta", "read" };
    const wiki_actions = [_][]const u8{
        "tree",
        "outline",
        "search",
        "symbol",
        "policy",
        "deps",
        "score",
        "cves",
        "commits",
        "branches",
        "dep-history",
    };
    const allowed: []const []const u8 = if (is_wiki) &wiki_actions else &codegraff_actions;
    var action_valid = false;
    for (allowed) |va| {
        if (std.mem.eql(u8, action, va)) {
            action_valid = true;
            break;
        }
    }
    if (!action_valid) {
        out.appendSlice(alloc, "error: action '") catch {};
        out.appendSlice(alloc, action) catch {};
        out.appendSlice(alloc, "' not supported on backend '") catch {};
        out.appendSlice(alloc, backend) catch {};
        out.appendSlice(alloc, "' (") catch {};
        if (is_wiki) {
            out.appendSlice(alloc, "wiki supports: tree, outline, search, symbol, policy, deps, score, cves, commits, branches, dep-history)") catch {};
        } else {
            out.appendSlice(alloc, "codegraff supports: tree, outline, search, meta, read)") catch {};
        }
        return;
    }

    var wiki_slug_buf: [256]u8 = undefined;
    var wiki_slug: []const u8 = "";
    if (is_wiki) {
        wiki_slug = wikiSlugForRepo(repo, wiki_slug_buf[0..]) orelse {
            out.appendSlice(alloc, "error: invalid wiki repo, use owner/repo or raw wiki slug (e.g. justrach/codedb or chromium)") catch {};
            return;
        };
    } else if (!isCodegraffRepo(repo)) {
        out.appendSlice(alloc, "error: invalid repo format, use owner/repo (e.g. justrach/merjs)") catch {};
        return;
    }

    const query = getStr(args, "query");

    // Require a non-empty 'query' for actions that consume it. Sending an
    // empty value silently masked real user mistakes.
    const needs_query = std.mem.eql(u8, action, "search") or
        (is_wiki and (std.mem.eql(u8, action, "symbol") or std.mem.eql(u8, action, "outline")));
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
    const url = if (is_wiki)
        std.fmt.bufPrint(&url_buf, "https://api.wiki.codes/api/{s}/{s}", .{ wiki_slug, action }) catch {
            out.appendSlice(alloc, "error: URL too long") catch {};
            return;
        }
    else
        std.fmt.bufPrint(&url_buf, "https://codedb.codegraff.com/{s}/{s}", .{ repo, action }) catch {
            out.appendSlice(alloc, "error: URL too long") catch {};
            return;
        };

    // Build the URL params list. Action-specific arg first, then optional
    // pagination/filter params. Server is free to ignore unknown keys.
    var int_bufs: [3][32]u8 = undefined;
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

    // Optional pagination/filter params. Server may not yet handle these;
    // they're forwarded so they take effect transparently when it does.
    if (std.mem.eql(u8, action, "tree")) {
        if (getInt(args, "limit")) |n| {
            const s = std.fmt.bufPrint(int_bufs[int_slot][0..], "{d}", .{n}) catch "0";
            params.append(alloc, .{ .name = "limit", .value = s }) catch {};
            int_slot += 1;
        }
        if (getInt(args, "offset")) |n| {
            const s = std.fmt.bufPrint(int_bufs[int_slot][0..], "{d}", .{n}) catch "0";
            params.append(alloc, .{ .name = "offset", .value = s }) catch {};
            int_slot += 1;
        }
        if (getStr(args, "prefix")) |v| {
            if (v.len > 0) params.append(alloc, .{ .name = "prefix", .value = v }) catch {};
        }
        if (getBool(args, "expand")) {
            params.append(alloc, .{ .name = "expand", .value = "true" }) catch {};
        }
    } else if (std.mem.eql(u8, action, "commits") or std.mem.eql(u8, action, "dep-history")) {
        if (getInt(args, "limit")) |n| {
            const s = std.fmt.bufPrint(int_bufs[int_slot][0..], "{d}", .{n}) catch "0";
            params.append(alloc, .{ .name = "limit", .value = s }) catch {};
            int_slot += 1;
        }
        if (getStr(args, "since")) |v| {
            if (v.len > 0) params.append(alloc, .{ .name = "since", .value = v }) catch {};
        }
    }

    const captured = fetchRemote(alloc, url, params.items) catch {
        if (is_wiki) {
            out.appendSlice(alloc, "error: failed to fetch from api.wiki.codes") catch {};
        } else {
            out.appendSlice(alloc, "error: failed to fetch from codedb.codegraff.com") catch {};
        }
        return;
    };
    defer alloc.free(captured.stdout);
    defer alloc.free(captured.stderr);

    if (captured.term != .Exited or captured.term.Exited != 0) {
        const host_label: []const u8 = if (is_wiki) "api.wiki.codes" else "codedb.codegraff.com";
        const path_slug: []const u8 = if (is_wiki) wiki_slug else repo;
        out.appendSlice(alloc, "error: ") catch {};
        out.appendSlice(alloc, host_label) catch {};
        out.appendSlice(alloc, " returned error for ") catch {};
        out.appendSlice(alloc, path_slug) catch {};
        out.appendSlice(alloc, "/") catch {};
        out.appendSlice(alloc, action) catch {};
        if (captured.stderr.len > 0) {
            out.appendSlice(alloc, " — ") catch {};
            out.appendSlice(alloc, captured.stderr[0..@min(captured.stderr.len, 200)]) catch {};
        }
        return;
    }

    out.appendSlice(alloc, captured.stdout) catch {};
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

fn handleIndex(io: std.Io, alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8)) void {
    const path = getStr(args, "path") orelse {
        out.appendSlice(alloc, "error: missing 'path'") catch {};
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

    const result = cio.runCapture(.{
        .allocator = alloc,
        .argv = &.{ exe_path, abs_path, "snapshot" },
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

fn handleFind(io: std.Io, alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8), explorer: *Explorer) void {
    const query = getStr(args, "query") orelse {
        out.appendSlice(alloc, "error: missing 'query'") catch {};
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

    for (pipeline, 0..) |step_val, step_i| {
        if (step_val != .object) {
            w.print("error: step {d} must be object\n", .{step_i}) catch {};
            return;
        }
        const step = &step_val.object;
        const op = getStr(step, "op") orelse {
            w.print("error: step {d} missing 'op'\n", .{step_i}) catch {};
            return;
        };

        if (std.mem.eql(u8, op, "find")) {
            const query = getStr(step, "query") orelse {
                w.print("error: find needs 'query'\n", .{}) catch {};
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
            } else {
                file_set.clearRetainingCapacity();
                for (matches) |m| file_set.append(alloc, m.path) catch {};
                have_set = true;
            }
        } else if (std.mem.eql(u8, op, "search")) {
            const query = getStr(step, "query") orelse {
                w.print("error: search needs 'query'\n", .{}) catch {};
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
            // Expand file set by adding dependents/dependencies of current files
            if (!have_set) {
                w.print("error: deps needs prior step\n", .{}) catch {};
                return;
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
            if (!have_set) {
                w.print("error: outline needs prior step\n", .{}) catch {};
                return;
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
            if (!have_set) {
                w.print("error: read needs prior step\n", .{}) catch {};
                return;
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
        } else if (std.mem.eql(u8, op, "limit")) {
            const n: usize = if (getInt(step, "n")) |i| @intCast(@max(1, @min(i, 100))) else 10;
            if (file_set.items.len > n) file_set.items.len = n;
        } else {
            w.print("error: unknown op '{s}'\n", .{op}) catch {};
            return;
        }
    }

    if (out.items.len == 0 and have_set) {
        w.print("{d} files:\n", .{file_set.items.len}) catch {};
        for (file_set.items) |path| w.print("  {s}\n", .{path}) catch {};
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
fn globMatch(pattern: []const u8, path: []const u8) bool {
    var pi: usize = 0;
    var gi: usize = 0;
    var star_g: ?usize = null;
    var star_p: usize = 0;

    while (pi < path.len) {
        if (gi < pattern.len and (pattern[gi] == path[pi] or (pattern[gi] == '?' and path[pi] != '/'))) {
            gi += 1;
            pi += 1;
        } else if (gi < pattern.len and pattern[gi] == '*') {
            // Check for ** (matches across path separators)
            if (gi + 1 < pattern.len and pattern[gi + 1] == '*') {
                // ** matches everything including /
                star_g = gi;
                star_p = pi;
                gi += 2;
                if (gi < pattern.len and pattern[gi] == '/') gi += 1; // skip trailing /
            } else {
                // * matches everything except /
                star_g = gi;
                star_p = pi;
                gi += 1;
            }
        } else if (star_g != null) {
            gi = star_g.? + 1;
            if (gi < pattern.len and pattern[gi - 1] == '*' and pattern[gi] == '*') {
                gi += 1;
                if (gi < pattern.len and pattern[gi] == '/') gi += 1;
            }
            star_p += 1;
            pi = star_p;
            // Single * must not cross /
            if (pattern[star_g.?] == '*' and (star_g.? + 1 >= pattern.len or pattern[star_g.? + 1] != '*')) {
                if (pi > 0 and path[pi - 1] == '/') return false;
            }
        } else {
            return false;
        }
    }
    while (gi < pattern.len and pattern[gi] == '*') : (gi += 1) {}
    return gi == pattern.len;
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
    stdout.writeAll(buf.items) catch return;
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
    stdout.writeAll(buf.items) catch return;
    stdout.writeAll("\n") catch return;
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
const eql = mcpj.eql;

fn appendId(alloc: std.mem.Allocator, buf: *std.ArrayList(u8), id: ?std.json.Value) void {
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
        else => buf.appendSlice(alloc, "null") catch return,
    } else {
        buf.appendSlice(alloc, "null") catch return;
    }
}

// ── MCP UX: 3-block response helpers ────────────────────────────────────────
// Colors are always on — MCP preview pane always renders ANSI. No TTY check.

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

fn mcpGenerateSummary(
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
        buf.appendSlice(alloc, MCP_DIM ++ MCP_ARROW ++ "next: codedb_symbol name=<fn> to read a function body" ++ MCP_RESET) catch {};
    } else if (eql(tool_name, "codedb_symbol")) {
        buf.appendSlice(alloc, MCP_DIM ++ MCP_ARROW ++ "next: codedb_edit to modify this symbol" ++ MCP_RESET) catch {};
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

    var snapshot_src = Explorer.init(testing.allocator);
    defer snapshot_src.deinit();
    snapshot_src.setRoot(io, project_path);
    try snapshot_src.indexFile("src/main.zig", "const project = \"secondary\";\n");

    const snap_path = try std.fmt.allocPrint(testing.allocator, "{s}/codedb.snapshot", .{project_path});
    defer testing.allocator.free(snap_path);
    try snapshot_mod.writeSnapshot(io, &snapshot_src, project_path, snap_path, testing.allocator);

    var default_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const default_path_len = try std.Io.Dir.cwd().realPathFile(io, ".", &default_path_buf);
    const default_path = default_path_buf[0..default_path_len];

    var default_explorer = Explorer.init(testing.allocator);
    defer default_explorer.deinit();
    var default_store = Store.init(testing.allocator);
    defer default_store.deinit();

    var cache = ProjectCache.init(testing.allocator, default_path);
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

test "codedb_snapshot cache reuses output until store seq changes" {
    const io = testing.io;
    const alloc = testing.allocator;

    var explorer = Explorer.init(alloc);
    defer explorer.deinit();
    try explorer.indexFile("src/main.zig", "pub fn main() void {}\n");

    var store = Store.init(alloc);
    defer store.deinit();
    _ = try store.recordSnapshot("src/main.zig", "pub fn main() void {}\n".len, 0xabc);

    var agents = AgentRegistry.init(alloc);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    var bench_ctx = BenchContext.init(alloc, ".");
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
