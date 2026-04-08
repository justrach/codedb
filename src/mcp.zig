// codedb MCP server — JSON-RPC 2.0 over stdio
//
// Exposes codedb's exploration + edit engine as MCP tools.
// Uses mcp-zig for protocol utilities; adds roots support for workspace awareness.

const std = @import("std");
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
// ── Project cache ────────────────────────────────────────────────────────────

const ProjectCtx = struct {
    explorer: *Explorer,
    store: *Store,
};

fn getProjectDataDir(allocator: std.mem.Allocator, project_path: []const u8) ?[]u8 {
    const hash = std.hash.Wyhash.hash(0, project_path);
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch {
        return std.fmt.allocPrint(allocator, "{s}/.codedb", .{project_path}) catch null;
    };
    defer allocator.free(home);

    return std.fmt.allocPrint(allocator, "{s}/.codedb/projects/{x}", .{ home, hash }) catch null;
}

fn loadProjectTrigramFromDiskIfPresent(explorer: *Explorer, project_path: []const u8, allocator: std.mem.Allocator) void {
    explorer.mu.lockShared();
    const already_loaded = explorer.trigram_index.fileCount() > 0;
    explorer.mu.unlockShared();
    if (already_loaded) return;

    const data_dir = getProjectDataDir(allocator, project_path) orelse return;
    defer allocator.free(data_dir);

    if (idx.TrigramIndex.readFromDisk(data_dir, allocator)) |loaded| {
        explorer.mu.lock();
        defer explorer.mu.unlock();
        explorer.trigram_index.deinit();
        explorer.trigram_index = loaded;
    }
}

fn loadProjectWordIndexFromDiskIfPresent(explorer: *Explorer, project_path: []const u8, allocator: std.mem.Allocator) void {
    if (!explorer.wordIndexCanLoadFromDisk()) return;

    const data_dir = getProjectDataDir(allocator, project_path) orelse {
        explorer.disableWordIndexDiskLoad();
        return;
    };
    defer allocator.free(data_dir);

    const header = idx.WordIndex.readDiskHeader(data_dir, allocator) catch null orelse {
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

    if (idx.WordIndex.readFromDisk(data_dir, allocator)) |loaded| {
        explorer.replaceWordIndex(loaded);
    } else {
        explorer.disableWordIndexDiskLoad();
    }
}

const ProjectCache = struct {
    const MAX_CACHED = 5;

    const Entry = struct {
        path: []u8,
        explorer: Explorer,
        store: Store,
        last_used: i64,
    };

    mu: std.Thread.RwLock,
    alloc: std.mem.Allocator,
    entries: [MAX_CACHED]?*Entry,
    default_path: []const u8,

    fn init(alloc_: std.mem.Allocator, default_path_: []const u8) ProjectCache {
        return .{
            .mu = .{},
            .alloc = alloc_,
            .entries = [_]?*Entry{null} ** MAX_CACHED,
            .default_path = default_path_,
        };
    }

    fn deinit(self: *ProjectCache) void {
        for (&self.entries) |*slot| {
            if (slot.*) |entry| {
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
        path: ?[]const u8,
        default_exp: *Explorer,
        default_store: *Store,
    ) !ProjectCtx {
        const p = path orelse return ProjectCtx{ .explorer = default_exp, .store = default_store };
        if (std.mem.eql(u8, p, self.default_path))
            return ProjectCtx{ .explorer = default_exp, .store = default_store };
        if (!root_policy.isIndexableRoot(p))
            return error.PathNotAllowed;

        self.mu.lock();
        defer self.mu.unlock();

        const now = std.time.milliTimestamp();
        for (&self.entries) |*slot| {
            if (slot.*) |entry| {
                if (std.mem.eql(u8, entry.path, p)) {
                    entry.last_used = now;
                    return ProjectCtx{ .explorer = &entry.explorer, .store = &entry.store };
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
        new_entry.store = Store.init(self.alloc);
        new_entry.last_used = now;

        var snap_buf: [std.fs.max_path_bytes]u8 = undefined;
        const snap_path = std.fmt.bufPrint(&snap_buf, "{s}/codedb.snapshot", .{p}) catch {
            new_entry.store.deinit();
            new_entry.explorer.deinit();
            self.alloc.free(new_entry.path);
            self.alloc.destroy(new_entry);
            return error.PathTooLong;
        };

        if (!snapshot_mod.loadSnapshot(snap_path, &new_entry.explorer, &new_entry.store, self.alloc)) {
            // Fallback: try central store at ~/.codedb/projects/{hash}/codedb.snapshot
            const hash = std.hash.Wyhash.hash(0, p);
            var central_buf: [std.fs.max_path_bytes]u8 = undefined;
            const loaded_central = blk: {
                const home = std.process.getEnvVarOwned(self.alloc, "HOME") catch break :blk false;
                defer self.alloc.free(home);
                const central = std.fmt.bufPrint(&central_buf, "{s}/.codedb/projects/{x}/codedb.snapshot", .{ home, hash }) catch break :blk false;
                break :blk snapshot_mod.loadSnapshot(central, &new_entry.explorer, &new_entry.store, self.alloc);
            };
            if (!loaded_central) {
                new_entry.store.deinit();
                new_entry.explorer.deinit();
                self.alloc.free(new_entry.path);
                self.alloc.destroy(new_entry);
                return error.SnapshotLoadFailed;
            }
        }

        loadProjectTrigramFromDiskIfPresent(&new_entry.explorer, p, self.alloc);

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
            evict.explorer.deinit();
            evict.store.deinit();
            self.alloc.free(evict.path);
            self.alloc.destroy(evict);
            target_slot = oldest_i;
        }

        self.entries[target_slot] = new_entry;
        return ProjectCtx{ .explorer = &new_entry.explorer, .store = &new_entry.store };
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
        alloc: std.mem.Allocator,
        tool: Tool,
        args: *const std.json.ObjectMap,
        out: *std.ArrayList(u8),
        store: *Store,
        explorer: *Explorer,
        agents: *AgentRegistry,
    ) void {
        dispatch(alloc, tool, args, out, store, explorer, agents, &self.cache);
    }

    pub fn runToolCall(
        self: *BenchContext,
        alloc: std.mem.Allocator,
        name: []const u8,
        tool: Tool,
        args: *const std.json.ObjectMap,
        store: *Store,
        explorer: *Explorer,
        agents: *AgentRegistry,
        telem: *telemetry_mod.Telemetry,
    ) usize {
        var out: std.ArrayList(u8) = .{};
        defer out.deinit(alloc);

        const t0 = std.time.nanoTimestamp();
        dispatch(alloc, tool, args, &out, store, explorer, agents, &self.cache);
        const elapsed = std.time.nanoTimestamp() - t0;

        const is_error = std.mem.startsWith(u8, out.items, "error:");
        telem.recordToolCall(name, elapsed, is_error, out.items.len);

        var summary: std.ArrayList(u8) = .{};
        defer summary.deinit(alloc);
        summary.appendSlice(alloc, if (is_error) MCP_RED ++ MCP_CROSS ++ " " ++ MCP_RESET else MCP_GREEN ++ MCP_CHECK ++ " " ++ MCP_RESET) catch {};
        summary.appendSlice(alloc, mcpToolIcon(name)) catch {};
        mcpGenerateSummary(alloc, name, args, out.items, is_error, &summary);
        var dur_buf: [96]u8 = undefined;
        summary.appendSlice(alloc, mcpFormatDuration(&dur_buf, elapsed)) catch {};

        var guidance: std.ArrayList(u8) = .{};
        defer guidance.deinit(alloc);
        mcpGenerateGuidance(alloc, name, args, is_error, &guidance);

        var result: std.ArrayList(u8) = .{};
        defer result.deinit(alloc);
        result.appendSlice(alloc, "{\"content\":[") catch return 0;

        if (summary.items.len > 0) {
            result.appendSlice(alloc, "{\"type\":\"text\",\"text\":\"") catch return result.items.len;
            writeEscaped(alloc, &result, summary.items);
            result.appendSlice(alloc, "\"},") catch return result.items.len;
        }

        result.appendSlice(alloc, "{\"type\":\"text\",\"text\":\"") catch return result.items.len;
        writeEscaped(alloc, &result, out.items);
        result.appendSlice(alloc, "\"}") catch return result.items.len;

        if (guidance.items.len > 0) {
            result.appendSlice(alloc, ",{\"type\":\"text\",\"text\":\"") catch return result.items.len;
            writeEscaped(alloc, &result, guidance.items);
            result.appendSlice(alloc, "\"}") catch return result.items.len;
        }

        result.appendSlice(alloc, if (is_error) "],\"isError\":true}" else "],\"isError\":false}") catch return result.items.len;
        return result.items.len;
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
};

const tools_list =
    \\{"tools":[
    \\{"name":"codedb_tree","description":"Get the full file tree of the indexed codebase with language detection, line counts, and symbol counts per file. Use this first to understand the project structure.","inputSchema":{"type":"object","properties":{"project":{"type":"string","description":"Optional absolute path to a different project (must have codedb.snapshot)"}},"required":[]}},
    \\{"name":"codedb_outline","description":"START HERE. Get the structural outline of a file: all functions, structs, enums, imports, constants with line numbers. Returns 4-15x fewer tokens than reading the raw file. Always use this before codedb_read to understand file structure first.","inputSchema":{"type":"object","properties":{"path":{"type":"string","description":"File path relative to project root"},"compact":{"type":"boolean","description":"Condensed format without detail comments (default: false)"},"project":{"type":"string","description":"Optional absolute path to a different project (must have codedb.snapshot)"}},"required":["path"]}},
    \\{"name":"codedb_symbol","description":"Find where a symbol is defined across the codebase. Returns file, line, and kind (function/struct/import). Use body=true to include source code. Much more precise than search — finds definitions, not just text matches.","inputSchema":{"type":"object","properties":{"name":{"type":"string","description":"Symbol name to search for (exact match)"},"body":{"type":"boolean","description":"Include source body for each symbol (default: false)"},"project":{"type":"string","description":"Optional absolute path to a different project (must have codedb.snapshot)"}},"required":["name"]}},
    \\{"name":"codedb_search","description":"Full-text search across all indexed files. Returns matching lines with file paths and line numbers. Start with max_results=10 for broad queries. Use scope=true to see the enclosing function/struct for each match. For single identifiers, prefer codedb_word (O(1) lookup) or codedb_symbol (definitions only).","inputSchema":{"type":"object","properties":{"query":{"type":"string","description":"Text to search for (substring match, or regex if regex=true)"},"max_results":{"type":"integer","description":"Maximum results to return (default: 50, start with 10 for broad queries)"},"scope":{"type":"boolean","description":"Annotate results with enclosing symbol scope (default: false)"},"compact":{"type":"boolean","description":"Skip comment and blank lines in results (default: false)"},"regex":{"type":"boolean","description":"Treat query as regex pattern (default: false)"},"project":{"type":"string","description":"Optional absolute path to a different project (must have codedb.snapshot)"}},"required":["query"]}},
    \\{"name":"codedb_word","description":"O(1) word lookup using inverted index. Finds all occurrences of an exact word (identifier) across the codebase. Much faster than search for single-word queries.","inputSchema":{"type":"object","properties":{"word":{"type":"string","description":"Exact word/identifier to look up"},"project":{"type":"string","description":"Optional absolute path to a different project (must have codedb.snapshot)"}},"required":["word"]}},
    \\{"name":"codedb_hot","description":"Get the most recently modified files in the codebase, ordered by recency. Useful to see what's been actively worked on.","inputSchema":{"type":"object","properties":{"limit":{"type":"integer","description":"Number of files to return (default: 10)"},"project":{"type":"string","description":"Optional absolute path to a different project (must have codedb.snapshot)"}},"required":[]}},
    \\{"name":"codedb_deps","description":"Get reverse dependencies: which files import/depend on the given file. Useful for impact analysis.","inputSchema":{"type":"object","properties":{"path":{"type":"string","description":"File path to check dependencies for"},"project":{"type":"string","description":"Optional absolute path to a different project (must have codedb.snapshot)"}},"required":["path"]}},
    \\{"name":"codedb_read","description":"Read file contents. IMPORTANT: Use codedb_outline first to find the line numbers you need, then read only that range with line_start/line_end. Avoid reading entire large files — use compact=true to skip comments and blanks. For understanding file structure, codedb_outline is 4-15x more token-efficient.","inputSchema":{"type":"object","properties":{"path":{"type":"string","description":"File path relative to project root"},"line_start":{"type":"integer","description":"Start line (1-indexed, inclusive). Omit for full file."},"line_end":{"type":"integer","description":"End line (1-indexed, inclusive). Omit to read to EOF."},"if_hash":{"type":"string","description":"Previous content hash. If unchanged, returns short 'unchanged:HASH' response."},"compact":{"type":"boolean","description":"Skip comment and blank lines (default: false)"},"project":{"type":"string","description":"Optional absolute path to a different project (must have codedb.snapshot)"}},"required":["path"]}},
    \\{"name":"codedb_edit","description":"Apply a line-based edit to a file. Supports replace (range), insert (after line), and delete (range) operations.","inputSchema":{"type":"object","properties":{"path":{"type":"string","description":"File path to edit"},"op":{"type":"string","enum":["replace","insert","delete"],"description":"Edit operation type"},"content":{"type":"string","description":"New content (for replace/insert)"},"range_start":{"type":"integer","description":"Start line number (for replace/delete, 1-indexed)"},"range_end":{"type":"integer","description":"End line number (for replace/delete, 1-indexed)"},"after":{"type":"integer","description":"Insert after this line number (for insert)"}},"required":["path","op"]}},
    \\{"name":"codedb_changes","description":"Get files that changed since a sequence number. Use with codedb_status to poll for changes.","inputSchema":{"type":"object","properties":{"since":{"type":"integer","description":"Sequence number to get changes since (default: 0)"}},"required":[]}},
    \\{"name":"codedb_status","description":"Get current codedb status: number of indexed files and current sequence number.","inputSchema":{"type":"object","properties":{"project":{"type":"string","description":"Optional absolute path to a different project (must have codedb.snapshot)"}},"required":[]}},
    \\{"name":"codedb_snapshot","description":"Get the full pre-rendered snapshot of the codebase as a single JSON blob. Contains tree, all outlines, symbol index, and dependency graph. Ideal for caching or deploying to edge workers.","inputSchema":{"type":"object","properties":{"project":{"type":"string","description":"Optional absolute path to a different project (must have codedb.snapshot)"}},"required":[]}},
    \\{"name":"codedb_bundle","description":"Batch multiple queries in one call. Max 20 ops. WARNING: Avoid bundling multiple codedb_read calls on large files — use codedb_outline + codedb_symbol instead. Bundle outline+symbol+search, not full file reads. Total response is not size-capped, so large bundles can exceed token limits.","inputSchema":{"type":"object","properties":{"ops":{"type":"array","items":{"type":"object","properties":{"tool":{"type":"string","description":"Tool name (e.g. codedb_outline, codedb_symbol, codedb_read)"},"arguments":{"type":"object","description":"Tool arguments"}},"required":["tool"]},"description":"Array of tool calls to execute"},"project":{"type":"string","description":"Optional absolute path to a different project (must have codedb.snapshot)"}},"required":["ops"]}},
    \\{"name":"codedb_remote","description":"Query any GitHub repo via codedb.codegraff.com cloud intelligence. Gets file tree, symbol outlines, or searches code in external repos without cloning. Use when you need to understand a dependency, check an external API, or explore a repo you don't have locally.","inputSchema":{"type":"object","properties":{"repo":{"type":"string","description":"GitHub repo in owner/repo format (e.g. justrach/merjs)"},"action":{"type":"string","enum":["tree","outline","search","meta"],"description":"What to query: tree (file list), outline (symbols), search (text search), meta (repo info)"},"query":{"type":"string","description":"Search query (required when action=search)"}},"required":["repo","action"]}},
    \\{"name":"codedb_projects","description":"List all locally indexed projects on this machine. Shows project paths, data directory hashes, and whether a snapshot exists. Use to discover what codebases are available.","inputSchema":{"type":"object","properties":{},"required":[]}},
    \\{"name":"codedb_index","description":"Index a local folder on this machine. Scans all source files, builds outlines/trigrams/word indexes, and creates a codedb.snapshot in the target directory. After indexing, the folder is queryable via the project param on any tool.","inputSchema":{"type":"object","properties":{"path":{"type":"string","description":"Absolute path to the folder to index (e.g. /Users/you/myproject)"}},"required":["path"]}}
    \\]}
;

// ── MCP Server ──────────────────────────────────────────────────────────────

/// Monotonic timestamp of last MCP request, used by idle-exit watchdog.
pub var last_activity: std.atomic.Value(i64) = std.atomic.Value(i64).init(0);

/// How long (ms) the server may sit idle before auto-exiting.
/// Claude Code restarts MCP servers on demand, so this is safe.
pub const idle_timeout_ms: i64 = 10 * 60 * 1000; // 10 minutes — allows long debugging sessions; stdin EOF exits immediately

// ── Session state for MCP protocol ──────────────────────────────────────────

const Session = struct {
    alloc: std.mem.Allocator,
    stdout: std.fs.File,
    next_id: i64 = 100,
    client_supports_roots: bool = false,
    client_roots_list_changed: bool = false,
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
    alloc: std.mem.Allocator,
    store: *Store,
    explorer: *Explorer,
    agents: *AgentRegistry,
    default_path: []const u8,
    telem: *telemetry_mod.Telemetry,
) void {
    const stdout = std.fs.File.stdout();
    const stdin = std.fs.File.stdin();
    last_activity.store(std.time.milliTimestamp(), .release);

    var cache = ProjectCache.init(alloc, default_path);
    defer cache.deinit();

    var session = Session{
        .alloc = alloc,
        .stdout = stdout,
    };
    defer session.deinit();

    while (true) {
        const msg = mcpj.readLine(alloc, stdin) orelse break;
        last_activity.store(std.time.milliTimestamp(), .release);
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
            handleCall(alloc, root, stdout, id, store, explorer, agents, &cache, telem);
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
    writeResult(s.alloc, s.stdout, id,
        \\{"protocolVersion":"2025-06-18","capabilities":{"tools":{"listChanged":false}},"serverInfo":{"name":"codedb","version":"0.2.3"}}
    );
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

fn writeRequest(alloc: std.mem.Allocator, stdout: std.fs.File, id: i64, method: []const u8, params: []const u8) void {
    var buf: std.ArrayList(u8) = .{};
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
    alloc: std.mem.Allocator,
    root: *const std.json.ObjectMap,
    stdout: std.fs.File,
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
    var args_value = params.get("arguments") orelse std.json.Value{ .object = std.json.ObjectMap.init(alloc) };
    if (args_value != .object) {
        if (!is_notification) writeError(alloc, stdout, id, -32602, "arguments must be object");
        return;
    }
    const args = &args_value.object;

    const tool = std.meta.stringToEnum(Tool, name) orelse {
        if (!is_notification) writeError(alloc, stdout, id, -32602, "Unknown tool");
        return;
    };

    var out: std.ArrayList(u8) = .{};
    defer out.deinit(alloc);

    const t0 = std.time.nanoTimestamp();
    dispatch(alloc, tool, args, &out, store, explorer, agents, cache);
    const elapsed = std.time.nanoTimestamp() - t0;

    const is_error = std.mem.startsWith(u8, out.items, "error:");
    telem.recordToolCall(name, elapsed, is_error, out.items.len);
    if (is_notification) return;

    // Block 1: Human-readable colored summary (ANSI — preview pane always renders it)
    var summary: std.ArrayList(u8) = .{};
    defer summary.deinit(alloc);
    summary.appendSlice(alloc, if (is_error) MCP_RED ++ MCP_CROSS ++ " " ++ MCP_RESET else MCP_GREEN ++ MCP_CHECK ++ " " ++ MCP_RESET) catch {};
    summary.appendSlice(alloc, mcpToolIcon(name)) catch {};
    mcpGenerateSummary(alloc, name, args, out.items, is_error, &summary);
    var dur_buf: [96]u8 = undefined;
    summary.appendSlice(alloc, mcpFormatDuration(&dur_buf, elapsed)) catch {};

    // Block 3: Guidance hints
    var guidance: std.ArrayList(u8) = .{};
    defer guidance.deinit(alloc);
    mcpGenerateGuidance(alloc, name, args, is_error, &guidance);

    // Assemble 3-block MCP content envelope
    var result: std.ArrayList(u8) = .{};
    defer result.deinit(alloc);
    result.appendSlice(alloc, "{\"content\":[") catch return;

    // Block 1 (summary)
    if (summary.items.len > 0) {
        result.appendSlice(alloc, "{\"type\":\"text\",\"text\":\"") catch return;
        writeEscaped(alloc, &result, summary.items);
        result.appendSlice(alloc, "\"},") catch return;
    }

    // Block 2 (raw data — no colors, zero extra tokens to model)
    result.appendSlice(alloc, "{\"type\":\"text\",\"text\":\"") catch return;
    writeEscaped(alloc, &result, out.items);
    result.appendSlice(alloc, "\"}") catch return;

    // Block 3 (guidance)
    if (guidance.items.len > 0) {
        result.appendSlice(alloc, ",{\"type\":\"text\",\"text\":\"") catch return;
        writeEscaped(alloc, &result, guidance.items);
        result.appendSlice(alloc, "\"}") catch return;
    }

    result.appendSlice(alloc, if (is_error) "],\"isError\":true}" else "],\"isError\":false}") catch return;
    writeResult(alloc, stdout, id, result.items);
}

fn dispatch(
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
    const ctx = cache.get(project_path, default_explorer, default_store) catch |err| {
        out.appendSlice(alloc, "error: failed to load project: ") catch {};
        out.appendSlice(alloc, @errorName(err)) catch {};
        return;
    };

    if (tool == .codedb_word) {
        const effective_project = project_path orelse cache.default_path;
        loadProjectWordIndexFromDiskIfPresent(ctx.explorer, effective_project, alloc);
    }

    switch (tool) {
        .codedb_tree => handleTree(alloc, out, ctx.explorer),
        .codedb_outline => handleOutline(alloc, args, out, ctx.explorer),
        .codedb_symbol => handleSymbol(alloc, args, out, ctx.explorer),
        .codedb_search => handleSearch(alloc, args, out, ctx.explorer),
        .codedb_word => handleWord(alloc, args, out, ctx.explorer),
        .codedb_hot => handleHot(alloc, args, out, ctx.store, ctx.explorer),
        .codedb_deps => handleDeps(alloc, args, out, ctx.explorer),
        .codedb_read => handleRead(alloc, args, out, ctx.explorer),
        .codedb_edit => handleEdit(alloc, args, out, default_store, default_explorer, agents),
        .codedb_changes => handleChanges(alloc, args, out, default_store),
        .codedb_status => handleStatus(alloc, out, ctx.store, ctx.explorer),
        .codedb_snapshot => handleSnapshot(alloc, out, ctx.explorer, ctx.store),
        .codedb_bundle => handleBundle(alloc, args, out, ctx.store, ctx.explorer, agents, cache),
        .codedb_remote => handleRemote(alloc, args, out),
        .codedb_projects => handleProjects(alloc, out),
        .codedb_index => handleIndex(alloc, args, out),
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
    const w = out.writer(alloc);
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

    const w = out.writer(alloc);
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

        const w = out.writer(alloc);
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

        const w = out.writer(alloc);
        w.print("{d} results for '{s}':\n", .{ results.len, query }) catch {};
        for (results) |r| {
            if (compact and explore_mod.isCommentOrBlank(r.line_text, explore_mod.detectLanguage(r.path))) continue;
            w.print("  {s}:{d}: {s}\n", .{ r.path, r.line_num, r.line_text }) catch {};
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

    const w = out.writer(alloc);
    w.print("{d} hits for '{s}':\n", .{ hits.len, word }) catch {};
    for (hits) |h| {
        w.print("  {s}:{d}\n", .{ h.path, h.line_num }) catch {};
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

    const w = out.writer(alloc);
    for (hot, 0..) |path, i| {
        w.print("{d}. {s}\n", .{ i + 1, path }) catch {};
    }
}

fn handleDeps(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8), explorer: *Explorer) void {
    const path = getStr(args, "path") orelse {
        out.appendSlice(alloc, "error: missing 'path' argument") catch {};
        return;
    };
    const imported_by = explorer.getImportedBy(path, alloc) catch {
        out.appendSlice(alloc, "error: deps failed") catch {};
        return;
    };
    defer {
        for (imported_by) |dep| alloc.free(dep);
        alloc.free(imported_by);
    }

    const w = out.writer(alloc);
    w.print("{s} is imported by:\n", .{path}) catch {};
    if (imported_by.len == 0) {
        w.writeAll("  (no dependents found)\n") catch {};
    } else {
        for (imported_by) |dep| {
            w.print("  {s}\n", .{dep}) catch {};
        }
    }
}

fn handleRead(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8), explorer: *Explorer) void {
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
        const file = std.fs.cwd().openFile(path, .{}) catch {
            out.appendSlice(alloc, "error: file not found: ") catch {};
            out.appendSlice(alloc, path) catch {};
            return;
        };
        defer file.close();
        break :blk file.readToEndAlloc(alloc, 10 * 1024 * 1024) catch {
            out.appendSlice(alloc, "error: failed to read file") catch {};
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
    const w = out.writer(alloc);
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

fn handleEdit(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8), store: *Store, explorer: *Explorer, agents: *AgentRegistry) void {
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

    const result = edit_mod.applyEdit(alloc, store, agents, explorer, req) catch |err| {
        out.appendSlice(alloc, "error: edit failed: ") catch {};
        out.appendSlice(alloc, @errorName(err)) catch {};
        return;
    };

    const w = out.writer(alloc);
    w.print("edit applied: seq={d}, size={d}, hash={d}", .{ result.seq, result.new_size, result.new_hash }) catch {};
}

fn handleChanges(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8), store: *Store) void {
    const since: u64 = if (getInt(args, "since")) |n| @intCast(@min(@max(0, n), std.math.maxInt(u64))) else 0;
    const changes = store.changesSinceDetailed(since, alloc) catch {
        out.appendSlice(alloc, "error: changes query failed") catch {};
        return;
    };
    defer alloc.free(changes);

    const w = out.writer(alloc);
    w.print("seq: {d}, {d} files changed since {d}:\n", .{ store.currentSeq(), changes.len, since }) catch {};
    for (changes) |c| {
        w.print("  {s} (seq={d}, op={s}, size={d})\n", .{ c.path, c.seq, @tagName(c.op), c.size }) catch {};
    }
}

fn handleStatus(alloc: std.mem.Allocator, out: *std.ArrayList(u8), store: *Store, explorer: *Explorer) void {
    _ = explorer;
    store.mu.lock();
    const file_count = store.files.count();
    store.mu.unlock();
    const w = out.writer(alloc);
    w.print("codedb status:\n  seq: {d}\n  files: {d}\n", .{
        store.currentSeq(),
        file_count,
    }) catch {};
}

fn handleSnapshot(alloc: std.mem.Allocator, out: *std.ArrayList(u8), explorer: *Explorer, store: *Store) void {
    const snap = snapshot_json.buildSnapshot(explorer, store, alloc) catch {
        out.appendSlice(alloc, "error: snapshot build failed") catch {};
        return;
    };
    defer alloc.free(snap);
    out.appendSlice(alloc, snap) catch {};
}

fn handleBundle(
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

    const w = out.writer(alloc);
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

        var empty_args = std.json.ObjectMap.init(alloc);
        defer empty_args.deinit();
        var sub_args_val = op_obj.get("arguments") orelse std.json.Value{ .object = empty_args };
        if (sub_args_val != .object) {
            w.print("--- [{d}] {s} ---\nerror: arguments must be object\n", .{ i, tool_name }) catch {};
            continue;
        }
        const sub_args = &sub_args_val.object;

        var sub_out: std.ArrayList(u8) = .{};
        defer sub_out.deinit(alloc);

        dispatch(alloc, tool, sub_args, &sub_out, default_store, default_explorer, agents, cache);

        // Check size BEFORE appending to prevent blowout
        if (out.items.len + sub_out.items.len > 200 * 1024) {
            w.print("--- [{d}] {s} ---\nTRUNCATED: adding this result would exceed 200KB. Use codedb_outline + targeted reads instead of full file reads.\n", .{ i, tool_name }) catch {};
            break;
        }

        w.print("--- [{d}] {s} ---\n", .{ i, tool_name }) catch {};
        out.appendSlice(alloc, sub_out.items) catch {};
        w.writeAll("\n") catch {};
    }
}

fn handleRemote(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8)) void {
    const repo = getStr(args, "repo") orelse {
        out.appendSlice(alloc, "error: missing 'repo' (e.g. justrach/merjs)") catch {};
        return;
    };
    const action = getStr(args, "action") orelse {
        out.appendSlice(alloc, "error: missing 'action' (tree, outline, search, meta)") catch {};
        return;
    };
    // Validate action against whitelist to prevent SSRF/path injection
    const valid_actions = [_][]const u8{ "tree", "outline", "search", "meta" };
    var action_valid = false;
    for (valid_actions) |va| {
        if (std.mem.eql(u8, action, va)) {
            action_valid = true;
            break;
        }
    }
    if (!action_valid) {
        out.appendSlice(alloc, "error: invalid action, must be one of: tree, outline, search, meta") catch {};
        return;
    }

    // Validate repo format: must be "owner/name" with no path traversal
    if (std.mem.indexOf(u8, repo, "..") != null or
        std.mem.indexOf(u8, repo, "//") != null or
        repo[0] == '/' or
        std.mem.indexOfScalar(u8, repo, '/') == null)
    {
        out.appendSlice(alloc, "error: invalid repo format, use owner/repo (e.g. justrach/merjs)") catch {};
        return;
    }
    // Ensure exactly one slash (owner/repo, not owner/repo/extra/path)
    const slash_pos = std.mem.indexOfScalar(u8, repo, '/').?;
    if (std.mem.indexOfScalarPos(u8, repo, slash_pos + 1, '/') != null) {
        out.appendSlice(alloc, "error: invalid repo format, use owner/repo (e.g. justrach/merjs)") catch {};
        return;
    }

    // Build URL and curl args
    var url_buf: [512]u8 = undefined;
    const query = getStr(args, "query");

    if (std.mem.eql(u8, action, "search")) {
        const base_url = std.fmt.bufPrint(&url_buf, "https://codedb.codegraff.com/{s}/search", .{repo}) catch {
            out.appendSlice(alloc, "error: URL too long") catch {};
            return;
        };
        var q_buf: [256]u8 = undefined;
        const q_param = std.fmt.bufPrint(&q_buf, "q={s}", .{query orelse ""}) catch {
            out.appendSlice(alloc, "error: query too long") catch {};
            return;
        };
        // -G + --data-urlencode lets curl handle encoding spaces etc.
        const result = std.process.Child.run(.{
            .allocator = alloc,
            .argv = &.{ "curl", "-sf", "--max-time", "30", "-G", "--data-urlencode", q_param, base_url },
        }) catch {
            out.appendSlice(alloc, "error: failed to fetch from codedb.codegraff.com") catch {};
            return;
        };
        defer alloc.free(result.stdout);
        defer alloc.free(result.stderr);
        if (result.term.Exited != 0) {
            out.appendSlice(alloc, "error: codedb.codegraff.com returned error for ") catch {};
            out.appendSlice(alloc, repo) catch {};
            out.appendSlice(alloc, "/search") catch {};
            return;
        }
        out.appendSlice(alloc, result.stdout) catch {};
        return;
    }

    const url = std.fmt.bufPrint(&url_buf, "https://codedb.codegraff.com/{s}/{s}", .{ repo, action }) catch {
        out.appendSlice(alloc, "error: URL too long") catch {};
        return;
    };

    const result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "curl", "-sf", "--max-time", "30", url },
    }) catch {
        out.appendSlice(alloc, "error: failed to fetch from codedb.codegraff.com") catch {};
        return;
    };
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    if (result.term.Exited != 0) {
        out.appendSlice(alloc, "error: codedb.codegraff.com returned error for ") catch {};
        out.appendSlice(alloc, repo) catch {};
        out.appendSlice(alloc, "/") catch {};
        out.appendSlice(alloc, action) catch {};
        if (result.stderr.len > 0) {
            out.appendSlice(alloc, " — ") catch {};
            out.appendSlice(alloc, result.stderr[0..@min(result.stderr.len, 200)]) catch {};
        }
        return;
    }

    out.appendSlice(alloc, result.stdout) catch {};
}

// ── Local project tools ─────────────────────────────────────────────────────

fn handleProjects(alloc: std.mem.Allocator, out: *std.ArrayList(u8)) void {
    const home = std.process.getEnvVarOwned(alloc, "HOME") catch {
        out.appendSlice(alloc, "error: cannot read HOME") catch {};
        return;
    };
    defer alloc.free(home);

    const projects_dir = std.fmt.allocPrint(alloc, "{s}/.codedb/projects", .{home}) catch {
        out.appendSlice(alloc, "error: alloc failed") catch {};
        return;
    };
    defer alloc.free(projects_dir);

    var dir = std.fs.cwd().openDir(projects_dir, .{ .iterate = true }) catch {
        out.appendSlice(alloc, "no indexed projects found") catch {};
        return;
    };
    defer dir.close();

    var count: u32 = 0;
    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .directory) continue;

        // Read project.txt to get the project path
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const sub_path = std.fmt.bufPrint(&path_buf, "{s}/project.txt", .{entry.name}) catch continue;
        const project_file = dir.openFile(sub_path, .{}) catch continue;
        defer project_file.close();
        var content_buf: [4096]u8 = undefined;
        const n = project_file.readAll(&content_buf) catch continue;
        if (n == 0) continue;
        const project_path = content_buf[0..n];

        // Check if snapshot exists in the project directory
        var snap_exists = false;
        var snap_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const snap_path = std.fmt.bufPrint(&snap_path_buf, "{s}/codedb.snapshot", .{project_path}) catch project_path;
        if (std.fs.cwd().access(snap_path, .{})) |_| {
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

fn handleIndex(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8)) void {
    const path = getStr(args, "path") orelse {
        out.appendSlice(alloc, "error: missing 'path'") catch {};
        return;
    };

    // Resolve to absolute path
    var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_path = std.fs.cwd().realpath(path, &abs_buf) catch {
        out.appendSlice(alloc, "error: cannot resolve path: ") catch {};
        out.appendSlice(alloc, path) catch {};
        return;
    };
    if (!root_policy.isIndexableRoot(abs_path)) {
        out.appendSlice(alloc, "error: refusing to index temporary root: ") catch {};
        out.appendSlice(alloc, abs_path) catch {};
        return;
    }

    // Verify it's a directory
    var check_dir = std.fs.cwd().openDir(abs_path, .{}) catch {
        out.appendSlice(alloc, "error: not a directory: ") catch {};
        out.appendSlice(alloc, abs_path) catch {};
        return;
    };
    check_dir.close();

    // Get the codedb binary path (argv[0] equivalent — use /proc/self or just "codedb")
    // We spawn `codedb <path> snapshot` to create the snapshot
    const exe_path = std.fs.selfExePathAlloc(alloc) catch {
        out.appendSlice(alloc, "error: cannot find codedb binary") catch {};
        return;
    };
    defer alloc.free(exe_path);

    const result = std.process.Child.run(.{
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
        // Strip ANSI color codes from stdout for clean MCP output
        for (result.stdout) |c| {
            if (c == 0x1b) {
                // Skip ESC sequences — handled below
            } else {
                out.append(alloc, c) catch {};
            }
        }
    }
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

fn writeResult(alloc: std.mem.Allocator, stdout: std.fs.File, id: ?std.json.Value, result: []const u8) void {
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(alloc);
    buf.appendSlice(alloc, "{\"jsonrpc\":\"2.0\",\"id\":") catch return;
    appendId(alloc, &buf, id);
    buf.appendSlice(alloc, ",\"result\":") catch return;
    for (result) |c| {
        if (c != '\n' and c != '\r') buf.append(alloc, c) catch return;
    }
    buf.appendSlice(alloc, "}") catch return;
    stdout.writeAll(buf.items) catch return;
    stdout.writeAll("\n") catch return;
}

fn writeError(alloc: std.mem.Allocator, stdout: std.fs.File, id: ?std.json.Value, code: i32, msg: []const u8) void {
    var buf: std.ArrayList(u8) = .{};
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

const getStr = mcpj.getStr;
const getInt = mcpj.getInt;
pub const getBool = mcpj.getBool;
const eql = mcpj.eql;
const writeEscaped = mcpj.writeEscaped;

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

fn mcpGenerateGuidance(
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
        if (!getBool(args, "scope")) {
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
