const std = @import("std");
const Store = @import("store.zig").Store;
const AgentRegistry = @import("agent.zig").AgentRegistry;
const AgentId = @import("agent.zig").AgentId;
const Explorer = @import("explore.zig").Explorer;
const Op = @import("version.zig").Op;

pub const EditRequest = struct {
    path: []const u8,
    agent_id: AgentId,
    op: Op,
    range: ?[2]usize = null,
    after: ?usize = null,
    content: ?[]const u8 = null,
    if_hash: ?[]const u8 = null,
    dry_run: bool = false,
};

pub const EditResult = struct {
    seq: u64,
    new_hash: u64,
    new_size: u64,
    /// Unified-diff-style preview of the change. Only populated when
    /// `dry_run = true`. Caller owns the slice and must free it.
    preview: ?[]u8 = null,
};

pub fn applyEdit(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: *Store,
    agents: *AgentRegistry,
    explorer: ?*Explorer,
    req: EditRequest,
) !EditResult {
    const has_lock = try agents.tryLock(req.agent_id, req.path, 30_000);
    if (!has_lock) return error.FileLocked;
    errdefer agents.releaseLock(req.agent_id, req.path);

    // Validate required op-specific args BEFORE doing any work that
    // mutates Store.seq or rewrites the file (#401).
    switch (req.op) {
        .replace, .delete => if (req.range == null) return error.InvalidRange,
        .insert => if (req.after == null) return error.InvalidRange,
        else => {},
    }

    const source = try std.Io.Dir.cwd().readFileAlloc(io, req.path, allocator, .limited(10 * 1024 * 1024));
    defer allocator.free(source);

    if (req.if_hash) |expected_hex| {
        const actual = std.hash.Wyhash.hash(0, source);
        var hash_buf: [16]u8 = undefined;
        const actual_hex = std.fmt.bufPrint(&hash_buf, "{x}", .{actual}) catch return error.HashMismatch;
        if (!std.mem.eql(u8, expected_hex, actual_hex)) return error.HashMismatch;
    }

    // Detect line-ending style: if the file has any "\r\n", treat it as
    // CRLF and rejoin with CRLF (#404). Strip the trailing '\r' from
    // each split chunk so the in-memory representation is uniform.
    const is_crlf = std.mem.indexOf(u8, source, "\r\n") != null;
    const sep: []const u8 = if (is_crlf) "\r\n" else "\n";

    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(allocator);
    var iter = std.mem.splitScalar(u8, source, '\n');
    while (iter.next()) |line| {
        const trimmed = if (is_crlf and line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
        try lines.append(allocator, trimmed);
    }

    // A trailing newline produces an empty final element; don't count it as a line
    const had_trailing_newline = lines.items.len > 0 and lines.items[lines.items.len - 1].len == 0;
    if (had_trailing_newline) {
        _ = lines.pop();
    }

    switch (req.op) {
        .replace => {
            const range = req.range.?;
            if (range[0] == 0 or range[1] < range[0] or range[0] > lines.items.len) return error.InvalidRange;
            const start = range[0] - 1;
            const end = @min(range[1], lines.items.len);
            const new_content = req.content orelse return error.MissingContent;
            var new_lines: std.ArrayList([]const u8) = .empty;
            defer new_lines.deinit(allocator);
            var ni = std.mem.splitScalar(u8, new_content, '\n');
            while (ni.next()) |nl| {
                const trimmed = if (is_crlf and nl.len > 0 and nl[nl.len - 1] == '\r') nl[0 .. nl.len - 1] else nl;
                try new_lines.append(allocator, trimmed);
            }
            try lines.replaceRange(allocator, start, end - start, new_lines.items);
        },
        .insert => {
            const after_line = req.after.?;
            const pos = @min(after_line, lines.items.len);
            const content = req.content orelse return error.MissingContent;
            try lines.insert(allocator, pos, content);
        },
        .delete => {
            const range = req.range.?;
            if (range[0] == 0 or range[1] < range[0] or range[0] > lines.items.len) return error.InvalidRange;
            const start = range[0] - 1;
            const end = @min(range[1], lines.items.len);
            // Remove lines [start..end) by replacing with nothing
            try lines.replaceRange(allocator, start, end - start, &.{});
        },
        else => {},
    }

    // Restore trailing newline if the original file had one — but not when
    // the operation reduced the buffer to truly empty content (#409).
    const result_is_empty = lines.items.len == 0 or (lines.items.len == 1 and lines.items[0].len == 0);
    if (had_trailing_newline and !result_is_empty) {
        try lines.append(allocator, "");
    }

    const result = if (result_is_empty)
        try allocator.dupe(u8, "")
    else
        try std.mem.join(allocator, sep, lines.items);
    defer allocator.free(result);

    const hash: u64 = std.hash.Wyhash.hash(0, result);

    if (req.dry_run) {
        // Preview-only: build a compact diff and skip disk write, store record,
        // and explorer indexing. Caller releases the lock via errdefer/return.
        const preview = try buildPreview(allocator, source, result, req);
        agents.releaseLock(req.agent_id, req.path);
        return .{
            .seq = 0,
            .new_hash = hash,
            .new_size = result.len,
            .preview = preview,
        };
    }

    // Atomic write: write to temp file then rename to prevent corruption on crash
    const dir = std.Io.Dir.cwd();
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.codedb_tmp", .{req.path});
    defer allocator.free(tmp_path);

    {
        const tmp_file = try dir.createFile(io, tmp_path, .{});
        defer tmp_file.close(io);
        try tmp_file.writeStreamingAll(io, result);
    }

    std.Io.Dir.rename(dir, tmp_path, dir, req.path, io) catch |err| {
        // Clean up temp file on rename failure
        dir.deleteFile(io, tmp_path) catch {};
        return err;
    };

    // KNOWN LIMITATION: if recordEdit fails here, the file is already on disk but not
    // in the store. This leaves the disk and store inconsistent. Recovery would require
    // re-reading the file and re-recording, or a crash-recovery scan at startup.
    const seq = try store.recordEdit(req.path, req.agent_id, req.op, hash, result.len, req.content);
    if (explorer) |exp| {
        try exp.indexFile(req.path, result);
    }

    agents.releaseLock(req.agent_id, req.path);

    return .{
        .seq = seq,
        .new_hash = hash,
        .new_size = result.len,
    };
}
/// Build a compact unified-diff-style preview showing the affected range with up
/// to 3 lines of context on each side, removed lines prefixed with `-`, added
/// lines prefixed with `+`. Caller owns the returned slice.
fn buildPreview(
    allocator: std.mem.Allocator,
    before_bytes: []const u8,
    after_bytes: []const u8,
    req: EditRequest,
) ![]u8 {
    const ctx_lines: usize = 3;

    var before_lines: std.ArrayList([]const u8) = .empty;
    defer before_lines.deinit(allocator);
    var bi = std.mem.splitScalar(u8, before_bytes, '\n');
    while (bi.next()) |line| try before_lines.append(allocator, line);
    if (before_lines.items.len > 0 and before_lines.items[before_lines.items.len - 1].len == 0) {
        _ = before_lines.pop();
    }

    var after_lines: std.ArrayList([]const u8) = .empty;
    defer after_lines.deinit(allocator);
    var ai = std.mem.splitScalar(u8, after_bytes, '\n');
    while (ai.next()) |line| try after_lines.append(allocator, line);
    if (after_lines.items.len > 0 and after_lines.items[after_lines.items.len - 1].len == 0) {
        _ = after_lines.pop();
    }

    // Identify the changed range in 1-indexed line numbers (before file).
    var b_start: usize = 1;
    var b_end: usize = before_lines.items.len;
    var a_start: usize = 1;
    switch (req.op) {
        .replace => if (req.range) |r| {
            b_start = r[0];
            b_end = r[1];
            a_start = r[0];
        },
        .delete => if (req.range) |r| {
            b_start = r[0];
            b_end = r[1];
            a_start = r[0];
        },
        .insert => if (req.after) |after| {
            b_start = after + 1;
            b_end = after; // empty before-range
            a_start = after + 1;
        },
        else => {},
    }

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    const ctx_before_start = if (b_start > ctx_lines + 1) b_start - ctx_lines else 1;
    const ctx_after_end = @min(b_end + ctx_lines, before_lines.items.len);

    const before_hunk_len = ctx_after_end -| ctx_before_start + 1;
    const removed: usize = if (req.op == .delete or req.op == .replace) (b_end -| b_start + 1) else 0;
    const before_count = before_lines.items.len;
    const after_count = after_lines.items.len;
    const added_total = if (after_count + removed > before_count) after_count + removed - before_count else 0;
    const after_hunk_len = before_hunk_len -| removed + added_total;

    var hdr_buf: [128]u8 = undefined;
    const hdr = try std.fmt.bufPrint(&hdr_buf, "@@ -{d},{d} +{d},{d} @@\n", .{
        ctx_before_start,
        before_hunk_len,
        ctx_before_start,
        after_hunk_len,
    });
    try buf.appendSlice(allocator, hdr);

    // Leading context (unchanged lines before the change)
    var i: usize = ctx_before_start;
    while (i < b_start and i <= before_lines.items.len) : (i += 1) {
        try buf.append(allocator, ' ');
        try buf.appendSlice(allocator, before_lines.items[i - 1]);
        try buf.append(allocator, '\n');
    }

    // Removed lines from before
    if (req.op == .replace or req.op == .delete) {
        var j: usize = b_start;
        while (j <= b_end and j <= before_lines.items.len) : (j += 1) {
            try buf.append(allocator, '-');
            try buf.appendSlice(allocator, before_lines.items[j - 1]);
            try buf.append(allocator, '\n');
        }
    }

    // Added lines from after (replace + insert)
    if (req.op == .replace or req.op == .insert) {
        const inserted_count: usize = added_total;
        var k: usize = a_start;
        const stop = @min(a_start + inserted_count, after_lines.items.len + 1);
        while (k < stop) : (k += 1) {
            try buf.append(allocator, '+');
            try buf.appendSlice(allocator, after_lines.items[k - 1]);
            try buf.append(allocator, '\n');
        }
    }

    // Trailing context (unchanged lines after the change)
    var t: usize = b_end + 1;
    while (t <= ctx_after_end) : (t += 1) {
        try buf.append(allocator, ' ');
        try buf.appendSlice(allocator, before_lines.items[t - 1]);
        try buf.append(allocator, '\n');
    }

    return buf.toOwnedSlice(allocator);
}
