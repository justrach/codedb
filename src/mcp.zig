// codedb2 MCP server — JSON-RPC 2.0 over stdio
//
// Exposes codedb2's exploration + edit engine as MCP tools.
// Register in your MCP config:
//   "codedb": { "command": "/path/to/codedb-mcp", "args": ["/path/to/project"] }

const std = @import("std");
const Store = @import("store.zig").Store;
const explore_mod = @import("explore.zig");
const Explorer = explore_mod.Explorer;
const AgentRegistry = @import("agent.zig").AgentRegistry;
const Prerender = @import("prerender.zig").Prerender;
const watcher = @import("watcher.zig");
const edit_mod = @import("edit.zig");
const idx = @import("index.zig");

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
};

const tools_list =
    \\{"tools":[
    \\{"name":"codedb_tree","description":"Get the full file tree of the indexed codebase with language detection, line counts, and symbol counts per file. Use this first to understand the project structure.","inputSchema":{"type":"object","properties":{},"required":[]}},
    \\{"name":"codedb_outline","description":"Get the structural outline of a file: all functions, structs, enums, imports, constants with line numbers. Like an IDE symbol view.","inputSchema":{"type":"object","properties":{"path":{"type":"string","description":"File path relative to project root"},"compact":{"type":"boolean","description":"Condensed format without detail comments (default: false)"}},"required":["path"]}},
    \\{"name":"codedb_symbol","description":"Find ALL definitions of a symbol name across the entire codebase. Returns every file and line where this symbol is defined. With body=true, includes source code.","inputSchema":{"type":"object","properties":{"name":{"type":"string","description":"Symbol name to search for (exact match)"},"body":{"type":"boolean","description":"Include source body for each symbol (default: false)"}},"required":["name"]}},
    \\{"name":"codedb_search","description":"Full-text search across all indexed files. Uses trigram index for fast substring matching. Returns matching lines with file paths and line numbers. With scope=true, annotates results with the enclosing function/struct. With regex=true, treats the query as a regex pattern and uses trigram decomposition for acceleration.","inputSchema":{"type":"object","properties":{"query":{"type":"string","description":"Text to search for (substring match, or regex if regex=true)"},"max_results":{"type":"integer","description":"Maximum results to return (default: 50)"},"scope":{"type":"boolean","description":"Annotate results with enclosing symbol scope (default: false)"},"compact":{"type":"boolean","description":"Skip comment and blank lines in results (default: false)"},"regex":{"type":"boolean","description":"Treat query as regex pattern (default: false)"}},"required":["query"]}},
    \\{"name":"codedb_word","description":"O(1) word lookup using inverted index. Finds all occurrences of an exact word (identifier) across the codebase. Much faster than search for single-word queries.","inputSchema":{"type":"object","properties":{"word":{"type":"string","description":"Exact word/identifier to look up"}},"required":["word"]}},
    \\{"name":"codedb_hot","description":"Get the most recently modified files in the codebase, ordered by recency. Useful to see what's been actively worked on.","inputSchema":{"type":"object","properties":{"limit":{"type":"integer","description":"Number of files to return (default: 10)"}},"required":[]}},
    \\{"name":"codedb_deps","description":"Get reverse dependencies: which files import/depend on the given file. Useful for impact analysis.","inputSchema":{"type":"object","properties":{"path":{"type":"string","description":"File path to check dependencies for"}},"required":["path"]}},
    \\{"name":"codedb_read","description":"Read file contents from the indexed codebase. Supports line ranges, content hashing for cache validation, and compact output.","inputSchema":{"type":"object","properties":{"path":{"type":"string","description":"File path relative to project root"},"line_start":{"type":"integer","description":"Start line (1-indexed, inclusive). Omit for full file."},"line_end":{"type":"integer","description":"End line (1-indexed, inclusive). Omit to read to EOF."},"if_hash":{"type":"string","description":"Previous content hash. If unchanged, returns short 'unchanged:HASH' response."},"compact":{"type":"boolean","description":"Skip comment and blank lines (default: false)"}},"required":["path"]}},
    \\{"name":"codedb_edit","description":"Apply a line-based edit to a file. Supports replace (range), insert (after line), and delete (range) operations.","inputSchema":{"type":"object","properties":{"path":{"type":"string","description":"File path to edit"},"op":{"type":"string","enum":["replace","insert","delete"],"description":"Edit operation type"},"content":{"type":"string","description":"New content (for replace/insert)"},"range_start":{"type":"integer","description":"Start line number (for replace/delete, 1-indexed)"},"range_end":{"type":"integer","description":"End line number (for replace/delete, 1-indexed)"},"after":{"type":"integer","description":"Insert after this line number (for insert)"}},"required":["path","op"]}},
    \\{"name":"codedb_changes","description":"Get files that changed since a sequence number. Use with codedb_status to poll for changes.","inputSchema":{"type":"object","properties":{"since":{"type":"integer","description":"Sequence number to get changes since (default: 0)"}},"required":[]}},
    \\{"name":"codedb_status","description":"Get current codedb status: number of indexed files and current sequence number.","inputSchema":{"type":"object","properties":{},"required":[]}},
    \\{"name":"codedb_snapshot","description":"Get the full pre-rendered snapshot of the codebase as a single JSON blob. Contains tree, all outlines, symbol index, and dependency graph. Ideal for caching or deploying to edge workers.","inputSchema":{"type":"object","properties":{},"required":[]}},
    \\{"name":"codedb_bundle","description":"Execute multiple read-only intelligence queries in a single call. Combines outline, symbol, search, read, deps, and other indexed operations. Saves round-trips. Max 20 ops.","inputSchema":{"type":"object","properties":{"ops":{"type":"array","items":{"type":"object","properties":{"tool":{"type":"string","description":"Tool name (e.g. codedb_outline, codedb_symbol, codedb_read)"},"arguments":{"type":"object","description":"Tool arguments"}},"required":["tool"]},"description":"Array of tool calls to execute"}},"required":["ops"]}},
    \\{"name":"codedb_remote","description":"Query any GitHub repo via codedb.codegraff.com cloud intelligence. Gets file tree, symbol outlines, or searches code in external repos without cloning. Use when you need to understand a dependency, check an external API, or explore a repo you don't have locally.","inputSchema":{"type":"object","properties":{"repo":{"type":"string","description":"GitHub repo in owner/repo format (e.g. justrach/merjs)"},"action":{"type":"string","enum":["tree","outline","search","meta"],"description":"What to query: tree (file list), outline (symbols), search (text search), meta (repo info)"},"query":{"type":"string","description":"Search query (required when action=search)"}},"required":["repo","action"]}}
    \\]}
;

// ── MCP Server ──────────────────────────────────────────────────────────────

/// Monotonic timestamp of last MCP request, used by idle-exit watchdog.
pub var last_activity: std.atomic.Value(i64) = std.atomic.Value(i64).init(0);

/// How long (ms) the server may sit idle before auto-exiting.
/// Claude Code restarts MCP servers on demand, so this is safe.
pub const idle_timeout_ms: i64 = 5 * 60 * 1000; // 5 minutes

pub fn run(
    alloc: std.mem.Allocator,
    store: *Store,
    explorer: *Explorer,
    agents: *AgentRegistry,
    prerender: *Prerender,
) void {
    const stdout = std.fs.File.stdout();
    const stdin = std.fs.File.stdin();
    last_activity.store(std.time.milliTimestamp(), .release);

    while (true) {
        const msg = readFramedMessage(alloc, stdin) orelse break;
        last_activity.store(std.time.milliTimestamp(), .release);
        defer alloc.free(msg);
        if (msg.len == 0) {
            writeError(alloc, stdout, null, -32700, "Parse error");
            continue;
        }

        const parsed = std.json.parseFromSlice(std.json.Value, alloc, msg, .{}) catch {
            writeError(alloc, stdout, null, -32700, "Parse error");
            continue;
        };
        defer parsed.deinit();

        if (parsed.value != .object) {
            writeError(alloc, stdout, null, -32600, "Invalid Request");
            continue;
        }

        const root = &parsed.value.object;
        const method = getStr(root, "method") orelse {
            writeError(alloc, stdout, null, -32600, "Missing method");
            continue;
        };
        const has_id = root.contains("id");
        const id = root.get("id");
        const is_notification = !has_id;

        if (eql(method, "initialize")) {
            if (!is_notification) {
                writeResult(alloc, stdout, id,
                    \\{"protocolVersion":"2025-03-26","capabilities":{"tools":{"listChanged":false}},"serverInfo":{"name":"codedb2","version":"0.1.0"}}
                );
            }
        } else if (eql(method, "notifications/initialized")) {
            // no response for notifications
        } else if (eql(method, "tools/list")) {
            if (!is_notification) writeResult(alloc, stdout, id, tools_list);
        } else if (eql(method, "tools/call")) {
            handleCall(alloc, root, stdout, id, store, explorer, agents, prerender);
        } else if (eql(method, "ping")) {
            if (!is_notification) writeResult(alloc, stdout, id, "{}");
        } else {
            if (!is_notification) writeError(alloc, stdout, id, -32601, "Method not found");
        }
    }
}

fn handleCall(
    alloc: std.mem.Allocator,
    root: *const std.json.ObjectMap,
    stdout: std.fs.File,
    id: ?std.json.Value,
    store: *Store,
    explorer: *Explorer,
    agents: *AgentRegistry,
    prerender: *Prerender,
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
    dispatch(alloc, tool, args, &out, store, explorer, agents, prerender);
    const elapsed = std.time.nanoTimestamp() - t0;

    if (is_notification) return;

    const is_error = std.mem.startsWith(u8, out.items, "error:");

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
    store: *Store,
    explorer: *Explorer,
    agents: *AgentRegistry,
    prerender: *Prerender,
) void {
    switch (tool) {
        .codedb_tree => handleTree(alloc, out, explorer),
        .codedb_outline => handleOutline(alloc, args, out, explorer),
        .codedb_symbol => handleSymbol(alloc, args, out, explorer),
        .codedb_search => handleSearch(alloc, args, out, explorer),
        .codedb_word => handleWord(alloc, args, out, explorer),
        .codedb_hot => handleHot(alloc, args, out, store, explorer),
        .codedb_deps => handleDeps(alloc, args, out, explorer),
        .codedb_read => handleRead(alloc, args, out, explorer),
        .codedb_edit => handleEdit(alloc, args, out, store, agents),
        .codedb_changes => handleChanges(alloc, args, out, store),
        .codedb_status => handleStatus(alloc, out, store, explorer),
        .codedb_snapshot => handleSnapshot(alloc, out, explorer, store, prerender),
        .codedb_bundle => handleBundle(alloc, args, out, store, explorer, agents, prerender),
        .codedb_remote => handleRemote(alloc, args, out),
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
    const limit: usize = if (getInt(args, "limit")) |n| @intCast(@max(1, n)) else 10;
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
        const start: u32 = if (line_start_raw) |n| @intCast(@max(1, n)) else 1;
        const end: u32 = if (line_end_raw) |n| @intCast(@max(1, n)) else std.math.maxInt(u32);
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

fn handleEdit(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8), store: *Store, agents: *AgentRegistry) void {
    const path = getStr(args, "path") orelse {
        out.appendSlice(alloc, "error: missing 'path'") catch {};
        return;
    };
    if (!isPathSafe(path)) {
        out.appendSlice(alloc, "error: path traversal not allowed") catch {};
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

    const result = edit_mod.applyEdit(alloc, store, agents, req) catch |err| {
        out.appendSlice(alloc, "error: edit failed: ") catch {};
        out.appendSlice(alloc, @errorName(err)) catch {};
        return;
    };

    const w = out.writer(alloc);
    w.print("edit applied: seq={d}, size={d}, hash={d}", .{ result.seq, result.new_size, result.new_hash }) catch {};
}

fn handleChanges(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8), store: *Store) void {
    const since: u64 = if (getInt(args, "since")) |n| @intCast(@max(0, n)) else 0;
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
    w.print("codedb2 status:\n  seq: {d}\n  files: {d}\n", .{
        store.currentSeq(),
        file_count,
    }) catch {};
}

fn handleSnapshot(alloc: std.mem.Allocator, out: *std.ArrayList(u8), explorer: *Explorer, store: *Store, prerender: *Prerender) void {
    const snap = prerender.getSnapshot(explorer, store, alloc) catch {
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
    store: *Store,
    explorer: *Explorer,
    agents: *AgentRegistry,
    prerender: *Prerender,
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

        dispatch(alloc, tool, sub_args, &sub_out, store, explorer, agents, prerender);

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

    // Build URL: https://codedb.codegraff.com/{repo}/{action}?q={query}
    var url_buf: [512]u8 = undefined;
    const query = getStr(args, "query");
    const url = if (std.mem.eql(u8, action, "search"))
        std.fmt.bufPrint(&url_buf, "https://codedb.codegraff.com/{s}/search?q={s}", .{ repo, query orelse "" }) catch {
            out.appendSlice(alloc, "error: URL too long") catch {};
            return;
        }
    else
        std.fmt.bufPrint(&url_buf, "https://codedb.codegraff.com/{s}/{s}", .{ repo, action }) catch {
            out.appendSlice(alloc, "error: URL too long") catch {};
            return;
        };

    // Shell out to curl (simple, works everywhere, avoids Zig HTTP client issues)
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

pub fn isPathSafe(path: []const u8) bool {
    if (path.len == 0) return false;
    if (path[0] == '/') return false;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |component| {
        if (std.mem.eql(u8, component, "..")) return false;
    }
    return true;
}

fn readFramedMessage(alloc: std.mem.Allocator, file: std.fs.File) ?[]u8 {
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(alloc);

    var one: [1]u8 = undefined;
    while (true) {
        const n = file.read(&one) catch return null;
        if (n == 0) {
            if (buf.items.len == 0) return null;
            // EOF mid-line: treat as complete message
            break;
        }
        if (one[0] == '\n') {
            if (buf.items.len == 0) continue; // skip empty lines
            break;
        }
        if (one[0] == '\r') continue; // skip CR
        if (buf.items.len > 16 * 1024 * 1024) {
            // Drain rest of line to prevent framing desync on next call.
            while (true) {
                const nr = file.read(&one) catch break;
                if (nr == 0 or one[0] == '\n') break;
            }
            return null;
        }
        buf.append(alloc, one[0]) catch return null;
    }

    return alloc.dupe(u8, buf.items) catch null;
}

fn writeFramedMessage(alloc: std.mem.Allocator, stdout: std.fs.File, payload: []const u8) void {
    _ = alloc;
    stdout.writeAll(payload) catch return;
    stdout.writeAll("\n") catch return;
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
    writeFramedMessage(alloc, stdout, buf.items);
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
    writeEscaped(alloc, &buf, msg);
    buf.appendSlice(alloc, "\"}}") catch return;
    writeFramedMessage(alloc, stdout, buf.items);
}
fn getStr(obj: *const std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (obj.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

fn getInt(obj: *const std.json.ObjectMap, key: []const u8) ?i64 {
    return switch (obj.get(key) orelse return null) {
        .integer => |n| n,
        else => null,
    };
}

pub fn getBool(obj: *const std.json.ObjectMap, key: []const u8) bool {
    return switch (obj.get(key) orelse return false) {
        .bool => |b| b,
        else => false,
    };
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}


fn appendId(alloc: std.mem.Allocator, buf: *std.ArrayList(u8), id: ?std.json.Value) void {
    if (id) |v| switch (v) {
        .integer => |n| {
            var tmp: [20]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "{d}", .{n}) catch return;
            buf.appendSlice(alloc, s) catch return;
        },
        .string => |s| {
            buf.append(alloc, '"') catch return;
            writeEscaped(alloc, buf, s);
            buf.append(alloc, '"') catch return;
        },
        else => buf.appendSlice(alloc, "null") catch return,
    } else {
        buf.appendSlice(alloc, "null") catch return;
    }
}

fn writeEscaped(alloc: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) void {
    for (s) |c| {
        switch (c) {
            '"' => out.appendSlice(alloc, "\\\"") catch return,
            '\\' => out.appendSlice(alloc, "\\\\") catch return,
            '\n' => out.appendSlice(alloc, "\\n") catch return,
            '\r' => out.appendSlice(alloc, "\\r") catch return,
            '\t' => out.appendSlice(alloc, "\\t") catch return,
            else => if (c < 0x20) {
                const hex = "0123456789abcdef";
                const esc = [6]u8{ '\\', 'u', '0', '0', hex[c >> 4], hex[c & 0x0f] };
                out.appendSlice(alloc, &esc) catch return;
            } else {
                out.append(alloc, c) catch return;
            },
        }
    }
}

// ── MCP UX: 3-block response helpers ────────────────────────────────────────
// Colors are always on — MCP preview pane always renders ANSI. No TTY check.

const MCP_RESET        = "\x1b[0m";
const MCP_BOLD         = "\x1b[1m";
const MCP_DIM          = "\x1b[2m";
const MCP_GREEN        = "\x1b[32m";
const MCP_RED          = "\x1b[31m";
const MCP_CYAN         = "\x1b[36m";
const MCP_YELLOW       = "\x1b[33m";
const MCP_MAGENTA      = "\x1b[35m";
const MCP_BLUE         = "\x1b[34m";
const MCP_BRIGHT_GREEN = "\x1b[92m";

const MCP_CHECK = "\xe2\x9c\x93";    // ✓
const MCP_CROSS = "\xe2\x9c\x97";    // ✗
const MCP_DASH  = " \xe2\x80\x94 "; //  —
const MCP_ARROW = "\xe2\x86\x92 ";  // →
const MCP_DOT   = "\xe2\x80\xa2 ";  // •
const MCP_ZAP   = "\xe2\x9a\xa1";   // ⚡

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
    if (eql(tool_name, "codedb_outline")) return MCP_BLUE    ++ MCP_DOT ++ MCP_RESET;
    if (eql(tool_name, "codedb_symbol"))  return MCP_BLUE    ++ MCP_DOT ++ MCP_RESET;
    if (eql(tool_name, "codedb_read"))    return MCP_BLUE    ++ MCP_DOT ++ MCP_RESET;
    if (eql(tool_name, "codedb_search"))  return MCP_MAGENTA ++ MCP_DOT ++ MCP_RESET;
    if (eql(tool_name, "codedb_word"))    return MCP_CYAN    ++ MCP_DOT ++ MCP_RESET;
    if (eql(tool_name, "codedb_edit"))    return MCP_YELLOW  ++ MCP_DOT ++ MCP_RESET;
    if (eql(tool_name, "codedb_tree"))    return MCP_GREEN   ++ MCP_DOT ++ MCP_RESET;
    if (eql(tool_name, "codedb_hot"))     return MCP_YELLOW  ++ MCP_DOT ++ MCP_RESET;
    if (eql(tool_name, "codedb_deps"))    return MCP_CYAN    ++ MCP_DOT ++ MCP_RESET;
    if (eql(tool_name, "codedb_changes")) return MCP_YELLOW  ++ MCP_DOT ++ MCP_RESET;
    if (eql(tool_name, "codedb_bundle"))  return MCP_MAGENTA ++ MCP_DOT ++ MCP_RESET;
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
