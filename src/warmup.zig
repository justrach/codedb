//! Background warmup for the long-lived server modes (mcp / serve /
//! cli-daemon). Production query logs show the latency tail is lazy work
//! charged to an innocent first query — the word-index rebuild after a
//! snapshot fast-load (50ms–2s) — while 62% of real calls are exact repeats
//! of an earlier (tool, query) pair. This module supplies the two warmers:
//! the index prewarm runs from main.zig (which owns the disk-load helpers),
//! and the query replay here pre-fills the whole-query result caches from
//! the project's queries.log WAL so cross-restart repeats hit at ~µs.
//!
//! Replay deliberately mirrors the MCP codedb_search handler's default path
//! (renderPlainSearch with max_results=10, falling back to searchContentAuto
//! with 11) so the cache keys match what real calls will look up.

const std = @import("std");
const explore = @import("explore.zig");

/// Replay at most this many distinct queries.
pub const max_replay_queries: usize = 16;
/// Read at most this much of the WAL tail (recent activity matters most).
pub const max_log_tail_bytes: usize = 256 * 1024;

/// The MCP search handler's defaults (mcp.zig handleSearch): cache keys
/// include max_results, so replay must use the same numbers.
const default_max_results: usize = 10;
const fallback_fetch_count: usize = 11; // offset 0 + max_results + 1

/// Extract the most frequently repeated codedb_search queries from a
/// queries.log tail (JSONL, one event per line). Malformed lines are
/// skipped. Returns up to `max` queries ordered by descending repeat count,
/// each duped into `allocator`; caller frees each slice and the outer slice.
pub fn topQueries(allocator: std.mem.Allocator, log_bytes: []const u8, max: usize) ![][]u8 {
    var keys: std.ArrayList([]u8) = .empty;
    var counts = std.StringHashMap(u32).init(allocator);
    defer {
        for (keys.items) |k| allocator.free(k);
        keys.deinit(allocator);
        counts.deinit();
    }

    var lines = std.mem.splitScalar(u8, log_bytes, '\n');
    while (lines.next()) |line| {
        // A tail read may begin mid-line; the fragment simply fails to parse
        // and is skipped like any other malformed line.
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => continue,
        };
        const ev = obj.get("ev") orelse continue;
        if (ev != .string or !std.mem.eql(u8, ev.string, "query")) continue;
        const tool = obj.get("tool") orelse continue;
        if (tool != .string or !std.mem.eql(u8, tool.string, "codedb_search")) continue;
        const query = obj.get("query") orelse continue;
        if (query != .string) continue;
        const q = query.string;
        if (q.len == 0 or q.len > 1024) continue;
        const gop = try counts.getOrPut(q);
        if (gop.found_existing) {
            gop.value_ptr.* += 1;
        } else {
            const owned = try allocator.dupe(u8, q);
            errdefer allocator.free(owned);
            try keys.append(allocator, owned);
            gop.key_ptr.* = owned;
            gop.value_ptr.* = 1;
        }
    }

    const n = @min(keys.items.len, max);
    const out = try allocator.alloc([]u8, n);
    errdefer allocator.free(out);
    // Insertion order (keys) breaks count ties; selection by max count keeps
    // it simple — the candidate set is tiny.
    var remaining = std.ArrayList(u32).empty;
    defer remaining.deinit(allocator);
    try remaining.ensureTotalCapacity(allocator, keys.items.len);
    for (keys.items) |k| remaining.appendAssumeCapacity(counts.get(k).?);
    var filled: usize = 0;
    while (filled < n) : (filled += 1) {
        var best: usize = 0;
        var best_count: u32 = 0;
        for (remaining.items, 0..) |c, i| {
            if (c > best_count) {
                best_count = c;
                best = i;
            }
        }
        remaining.items[best] = 0;
        out[filled] = try allocator.dupe(u8, keys.items[best]);
    }
    return out;
}

pub fn freeQueries(allocator: std.mem.Allocator, queries: [][]u8) void {
    for (queries) |q| allocator.free(q);
    allocator.free(queries);
}

/// Replay queries through the same entry points the MCP codedb_search
/// handler uses, populating the plain-render and searchContent result
/// caches (and, via the lazy builds those searches trigger, the word/symbol
/// indexes, call graph, and co-change map). Errors are swallowed — warmup
/// must never take the server down — and `shutdown` is honored between
/// queries.
pub fn replay(explorer: *explore.Explorer, allocator: std.mem.Allocator, queries: []const []const u8, shutdown: *std.atomic.Value(bool)) void {
    for (queries) |q| {
        if (shutdown.load(.acquire)) return;
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        const rendered = explorer.renderPlainSearch(q, allocator, &buf, default_max_results, false) catch false;
        if (!rendered) {
            const res = explorer.searchContentAuto(q, allocator, fallback_fetch_count) catch continue;
            for (res) |r| {
                allocator.free(r.path);
                allocator.free(r.line_text);
            }
            allocator.free(res);
        }
    }
}
