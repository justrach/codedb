const std = @import("std");
const Store = @import("store.zig").Store;
const AgentRegistry = @import("agent.zig").AgentRegistry;
const AgentId = @import("agent.zig").AgentId;
const Explorer = @import("explore.zig").Explorer;
const Op = @import("version.zig").Op;
const Language = @import("explore.zig").Language;
const detectLanguage = @import("explore.zig").detectLanguage;
const project_fs = @import("project_fs.zig");

pub const EditRequest = struct {
    path: []const u8,
    agent_id: AgentId,
    op: Op,
    range: ?[2]usize = null,
    after: ?usize = null,
    content: ?[]const u8 = null,
    /// Anchor-based replace (P2, trial/graph-based-codedb): when set, the unique
    /// occurrence of old_string in the file is replaced with new_string by exact
    /// byte splice. Takes precedence over the range/after line ops, and cannot
    /// mis-target surrounding lines the way a whole-block range replace can.
    old_string: ?[]const u8 = null,
    new_string: ?[]const u8 = null,
    if_hash: ?[]const u8 = null,
    dry_run: bool = false,
    /// Create a NEW file at `path` with `content`. codedb_edit otherwise only
    /// edits existing files; with create=true a missing path is authored rather
    /// than erroring, and an existing path returns error.FileExists.
    create: bool = false,
};

pub const EditResult = struct {
    seq: u64,
    new_hash: u64,
    new_size: u64,
    changed: bool = true,
    /// Unified-diff-style preview of the change. Only populated when
    /// `dry_run = true`. Caller owns the slice and must free it.
    preview: ?[]u8 = null,
    /// Advisory post-edit syntax warning (e.g. unbalanced delimiter) or null
    /// when the edited content looks structurally clean. Caller owns the slice
    /// and must free it. (trial/graph-based-codedb)
    health: ?[]u8 = null,
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

    const edit_dir = if (explorer) |exp| exp.root_dir orelse std.Io.Dir.cwd() else std.Io.Dir.cwd();
    var target_parent = try project_fs.openParentNoFollow(io, edit_dir, req.path);
    defer target_parent.deinit(io);

    // Create op (trial/graph-based-codedb): author a NEW file. The write path in
    // finalizeEdit already handles a nonexistent path, so create just skips the
    // read and feeds an empty source. Refuse to clobber an existing file.
    if (req.create) {
        const new_content = req.content orelse return error.MissingContent;
        if (try project_fs.entryExistsNoFollow(io, target_parent.dir, target_parent.basename)) return error.FileExists;
        return try finalizeEdit(io, allocator, target_parent.dir, target_parent.basename, store, agents, explorer, req, "", new_content);
    }

    // Validate required op-specific args BEFORE doing any work that
    // mutates Store.seq or rewrites the file (#401). Anchor-based str_replace
    // (old_string set) uses neither range nor after.
    if (req.old_string == null) {
        switch (req.op) {
            .replace, .delete => if (req.range == null) return error.InvalidRange,
            .insert => if (req.after == null) return error.InvalidRange,
            else => {},
        }
    } else if (req.old_string.?.len == 0) {
        return error.MissingContent;
    }

    const source = try project_fs.readFileAllocFromParent(io, target_parent.dir, target_parent.basename, allocator, .limited(10 * 1024 * 1024));
    defer allocator.free(source);

    if (req.if_hash) |expected_hex| {
        const actual = std.hash.Wyhash.hash(0, source);
        var hash_buf: [16]u8 = undefined;
        const actual_hex = std.fmt.bufPrint(&hash_buf, "{x}", .{actual}) catch return error.HashMismatch;
        if (!std.mem.eql(u8, expected_hex, actual_hex)) return error.HashMismatch;
    }

    // Anchor-based replace (P2): splice the unique occurrence of old_string.
    // Byte-exact, so it cannot mis-target surrounding lines the way a range
    // replace can. old_string must occur exactly once. finalizeEdit handles the
    // no-op (unchanged) case.
    if (req.old_string) |old| {
        const new = req.new_string orelse "";
        const first = std.mem.indexOf(u8, source, old) orelse return error.PatternNotFound;
        if (std.mem.indexOfPos(u8, source, first + old.len, old) != null) return error.PatternNotUnique;
        var b: std.ArrayList(u8) = .empty;
        defer b.deinit(allocator);
        try b.appendSlice(allocator, source[0..first]);
        try b.appendSlice(allocator, new);
        try b.appendSlice(allocator, source[first + old.len ..]);
        const result = try b.toOwnedSlice(allocator);
        defer allocator.free(result);
        return try finalizeEdit(io, allocator, target_parent.dir, target_parent.basename, store, agents, explorer, req, source, result);
    }

    // Fast path #1 (origin/main): a full-file replace with identical content is a no-op.
    if (!req.dry_run and req.op == .replace) {
        const range = req.range.?;
        const new_content = req.content orelse return error.MissingContent;
        if (range[0] == 1 and std.mem.eql(u8, source, new_content) and fileLineCount(source) <= range[1]) {
            const hash = std.hash.Wyhash.hash(0, source);
            const seq = store.currentSeq();
            agents.releaseLock(req.agent_id, req.path);
            return .{
                .seq = seq,
                .new_hash = hash,
                .new_size = source.len,
                .changed = false,
            };
        }
    }

    // Fast path #2 (origin/main): in-place builder for line-range replaces. The
    // actual write goes through finalizeEdit so the syntax-health check runs on
    // replace edits too.
    if (!req.dry_run and req.op == .replace) {
        const range = req.range.?;
        const new_content = req.content orelse return error.MissingContent;
        if (new_content.len > 0) {
            const fast_result = try buildReplaceResultFast(allocator, source, range, new_content);
            defer allocator.free(fast_result);

            if (std.mem.eql(u8, source, fast_result)) {
                const seq = store.currentSeq();
                agents.releaseLock(req.agent_id, req.path);
                return .{
                    .seq = seq,
                    .new_hash = std.hash.Wyhash.hash(0, fast_result),
                    .new_size = fast_result.len,
                    .changed = false,
                };
            }

            return try finalizeEdit(io, allocator, target_parent.dir, target_parent.basename, store, agents, explorer, req, source, fast_result);
        }
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

    return try finalizeEdit(io, allocator, target_parent.dir, target_parent.basename, store, agents, explorer, req, source, result);
}

/// Common tail for applyEdit: hash + post-edit health, then either a dry-run
/// preview or an atomic write + store record + re-index. Releases the file lock
/// on its own return paths; on error the caller's errdefer releases it.
fn finalizeEdit(
    io: std.Io,
    allocator: std.mem.Allocator,
    target_dir: std.Io.Dir,
    target_basename: []const u8,
    store: *Store,
    agents: *AgentRegistry,
    explorer: ?*Explorer,
    req: EditRequest,
    source: []const u8,
    result: []const u8,
) !EditResult {
    const hash: u64 = std.hash.Wyhash.hash(0, result);

    // No-op short-circuit (origin/main): the edit produced identical content,
    // so nothing is written and there is nothing to syntax-check.
    if (!req.dry_run and !req.create and std.mem.eql(u8, source, result)) {
        const seq = store.currentSeq();
        agents.releaseLock(req.agent_id, req.path);
        return .{
            .seq = seq,
            .new_hash = hash,
            .new_size = result.len,
            .changed = false,
        };
    }

    // Post-edit syntax health (trial/graph-based-codedb): advisory delimiter +
    // dropped-import scan so a mis-spliced edit surfaces to the agent.
    const health_msg = try describeHealth(allocator, source, result, detectLanguage(req.path));
    errdefer if (health_msg) |h| allocator.free(h);

    if (req.dry_run) {
        // Preview-only: skip disk write, store record, and explorer indexing.
        // Range/insert/delete ops get a unified-diff preview; anchor edits skip it.
        const preview = if (req.old_string == null) try buildPreview(allocator, source, result, req) else null;
        agents.releaseLock(req.agent_id, req.path);
        return .{
            .seq = 0,
            .new_hash = hash,
            .new_size = result.len,
            .preview = preview,
            .health = health_msg,
        };
    }

    // Use the platform atomic-file primitive rather than a predictable sibling
    // name. A pre-created `<path>.codedb_tmp` symlink could otherwise redirect
    // the write outside the project before the final rename.
    var atomic_file = try target_dir.createFileAtomic(io, target_basename, .{ .replace = !req.create });
    defer atomic_file.deinit(io);
    try atomic_file.file.writeStreamingAll(io, result);
    if (req.create) {
        atomic_file.link(io) catch |err| switch (err) {
            error.PathAlreadyExists => return error.FileExists,
            else => return err,
        };
    } else {
        try atomic_file.replace(io);
    }

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
        .health = health_msg,
    };
}

fn fileLineCount(source: []const u8) usize {
    if (source.len == 0) return 0;
    var count = std.mem.count(u8, source, "\n");
    if (source[source.len - 1] != '\n') count += 1;
    return count;
}

fn buildReplaceResultFast(
    allocator: std.mem.Allocator,
    source: []const u8,
    range: [2]usize,
    new_content: []const u8,
) ![]u8 {
    if (range[0] == 0 or range[1] < range[0]) return error.InvalidRange;

    const is_crlf = std.mem.indexOf(u8, source, "\r\n") != null;
    const sep: []const u8 = if (is_crlf) "\r\n" else "\n";

    var line_count: usize = 0;
    if (source.len > 0) {
        line_count = std.mem.count(u8, source, "\n");
        if (source[source.len - 1] != '\n') line_count += 1;
    }
    if (range[0] > line_count) return error.InvalidRange;

    var start_off: ?usize = if (range[0] == 1) 0 else null;
    var end_off: ?usize = null;
    var cur_line: usize = 1;
    for (source, 0..) |c, i| {
        if (c != '\n') continue;
        if (cur_line == range[1]) {
            end_off = i + 1;
            break;
        }
        cur_line += 1;
        if (cur_line == range[0] and start_off == null) {
            start_off = i + 1;
        }
    }

    const start = start_off orelse return error.InvalidRange;
    const end = end_off orelse source.len;
    const suffix = source[end..];
    const content_ends_line = new_content.len > 0 and new_content[new_content.len - 1] == '\n';

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, source.len + new_content.len + sep.len);
    try out.appendSlice(allocator, source[0..start]);
    try appendNormalizedReplacement(allocator, &out, new_content, sep);
    if (suffix.len > 0 and !content_ends_line) {
        try out.appendSlice(allocator, sep);
    }
    try out.appendSlice(allocator, suffix);
    return out.toOwnedSlice(allocator);
}

fn appendNormalizedReplacement(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    content: []const u8,
    sep: []const u8,
) !void {
    var first = true;
    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |raw_line| {
        if (!first) try out.appendSlice(allocator, sep);
        first = false;
        const line = if (raw_line.len > 0 and raw_line[raw_line.len - 1] == '\r')
            raw_line[0 .. raw_line.len - 1]
        else
            raw_line;
        try out.appendSlice(allocator, line);
    }
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

// ── Post-edit syntax health check (trial/graph-based-codedb) ──────────────
//
// codedb_edit is a blind line-splice: historically it never checked whether
// the resulting file still parsed. The deep-SWE benchmark showed Sonnet-4.6
// routinely regenerates a multi-line bracketed region (a parenthesized import
// block or a function signature + body) and mis-splices the hunk boundaries,
// leaving an orphaned/duplicated delimiter — shipping a file that does not
// even import. The scan below is a cheap, dependency-free, language-aware
// delimiter-balance pass that surfaces such breaks back to the agent.

const Imbalance = struct {
    line: usize,
    open_char: u8,
    found_char: u8,
    kind: enum { unmatched_close, unclosed_open, mismatched },
};

/// Languages where a ()/[]/{} balance scan is meaningful and low-noise.
/// Deliberately excludes shell (case-pattern `)`), ruby (%w[] / heredocs),
/// sql, css and markup, where false positives would be common.
fn isCheckableCode(lang: Language) bool {
    return switch (lang) {
        .python, .javascript, .typescript, .zig, .c, .cpp, .rust, .go_lang, .java, .kotlin, .swift, .dart, .php => true,
        else => false,
    };
}

/// Scan `content` for the first unbalanced ()/[]/{} delimiter, skipping
/// language-appropriate comments and string / char literals. Advisory only:
/// returns null (stay silent) for unsupported languages or anything it cannot
/// analyse confidently (nesting deeper than the fixed stack).
fn scanDelimiterBalance(content: []const u8, language: Language) ?Imbalance {
    if (!isCheckableCode(language)) return null;

    const py = language == .python;
    const php = language == .php;
    const hash_comments = py or php;
    const slash_comments = !py; // // line + /* */ block for every c-like lang here
    const sq_is_string = py or php or language == .javascript or language == .typescript;
    const backtick = language == .javascript or language == .typescript;
    const zig_lang = language == .zig;

    var stack: [512]struct { ch: u8, line: usize } = undefined;
    var sp: usize = 0;
    var line: usize = 1;
    var i: usize = 0;
    const n = content.len;

    while (i < n) {
        const ch = content[i];
        if (ch == '\n') {
            line += 1;
            i += 1;
            continue;
        }

        // Zig multi-line string: a `\\`-prefixed line runs to EOL with no closer.
        if (zig_lang and ch == '\\' and i + 1 < n and content[i + 1] == '\\') {
            while (i < n and content[i] != '\n') i += 1;
            continue;
        }

        // Line comments.
        if (hash_comments and ch == '#') {
            while (i < n and content[i] != '\n') i += 1;
            continue;
        }
        if (slash_comments and ch == '/' and i + 1 < n and content[i + 1] == '/') {
            while (i < n and content[i] != '\n') i += 1;
            continue;
        }
        // Block comment /* ... */
        if (slash_comments and ch == '/' and i + 1 < n and content[i + 1] == '*') {
            i += 2;
            while (i + 1 < n and !(content[i] == '*' and content[i + 1] == '/')) {
                if (content[i] == '\n') line += 1;
                i += 1;
            }
            i = @min(i + 2, n);
            continue;
        }

        // Triple-quoted Python string.
        if (py and (ch == '"' or ch == '\'') and i + 2 < n and content[i + 1] == ch and content[i + 2] == ch) {
            const q = ch;
            i += 3;
            while (i + 2 < n and !(content[i] == q and content[i + 1] == q and content[i + 2] == q)) {
                if (content[i] == '\n') line += 1;
                if (content[i] == '\\') i += 1;
                i += 1;
            }
            i = @min(i + 3, n);
            continue;
        }

        // Backtick template literal (JS/TS): may span newlines; skip wholesale.
        if (backtick and ch == '`') {
            i += 1;
            while (i < n and content[i] != '`') {
                if (content[i] == '\\') {
                    i += 2;
                    continue;
                }
                if (content[i] == '\n') line += 1;
                i += 1;
            }
            i = @min(i + 1, n);
            continue;
        }

        // Double-quoted string (single line).
        if (ch == '"') {
            i += 1;
            while (i < n and content[i] != '"') {
                if (content[i] == '\\') {
                    i += 2;
                    continue;
                }
                if (content[i] == '\n') break; // unterminated; bail conservatively
                i += 1;
            }
            if (i < n and content[i] == '"') i += 1;
            continue;
        }

        // Single quote: a string (py/php/js/ts) or a char literal (c-family).
        if (ch == '\'') {
            if (sq_is_string) {
                i += 1;
                while (i < n and content[i] != '\'') {
                    if (content[i] == '\\') {
                        i += 2;
                        continue;
                    }
                    if (content[i] == '\n') break;
                    i += 1;
                }
                if (i < n and content[i] == '\'') i += 1;
                continue;
            }
            // Char literal: only consume as a literal if a closing ' is near
            // (<= 12 bytes). Otherwise it is a Rust lifetime (&'a) or a label —
            // leave it as plain punctuation so we do not eat real delimiters.
            var j = i + 1;
            const cap = @min(n, i + 13);
            var closed = false;
            while (j < cap) {
                if (content[j] == '\\') {
                    j += 2;
                    continue;
                }
                if (content[j] == '\'') {
                    closed = true;
                    break;
                }
                if (content[j] == '\n') break;
                j += 1;
            }
            if (closed) {
                i = j + 1;
                continue;
            }
            i += 1;
            continue;
        }

        switch (ch) {
            '(', '[', '{' => {
                if (sp == stack.len) return null; // too deep to analyse; stay silent
                stack[sp] = .{ .ch = ch, .line = line };
                sp += 1;
            },
            ')', ']', '}' => {
                const want: u8 = switch (ch) {
                    ')' => '(',
                    ']' => '[',
                    '}' => '{',
                    else => 0,
                };
                if (sp == 0) return .{ .line = line, .open_char = 0, .found_char = ch, .kind = .unmatched_close };
                if (stack[sp - 1].ch != want) return .{ .line = line, .open_char = stack[sp - 1].ch, .found_char = ch, .kind = .mismatched };
                sp -= 1;
            },
            else => {},
        }
        i += 1;
    }

    if (sp > 0) return .{ .line = stack[sp - 1].line, .open_char = stack[sp - 1].ch, .found_char = 0, .kind = .unclosed_open };
    return null;
}

fn formatImbalance(allocator: std.mem.Allocator, imb: Imbalance) ![]u8 {
    return switch (imb.kind) {
        .unmatched_close => try std.fmt.allocPrint(allocator, "\n⚠ syntax check: unmatched '{c}' at line {d} — this edit may have broken the file; re-read and verify before continuing.", .{ imb.found_char, imb.line }),
        .mismatched => try std.fmt.allocPrint(allocator, "\n⚠ syntax check: '{c}' at line {d} closes the wrong delimiter (open '{c}') — possible broken edit; re-read and verify.", .{ imb.found_char, imb.line, imb.open_char }),
        .unclosed_open => try std.fmt.allocPrint(allocator, "\n⚠ syntax check: '{c}' opened at line {d} is never closed — possible broken edit; re-read and verify.", .{ imb.open_char, imb.line }),
    };
}

// ── Dropped-import scan (P0b, trial/graph-based-codedb) ────────────────────
//
// The other half of the benchmark breakage: an edit that regenerates an import
// block and drops a name that is still referenced — e.g. codedb's narwhals
// patch removed `unstable` / `ExprNode` from a `from ... import (...)` while the
// names were still used, a NameError at import (syntactically valid, so the
// delimiter scan above cannot see it). Compare imports before vs after the edit
// and flag any binding that was removed yet is still used in the file.

const DroppedName = struct { name: []const u8, line: usize };

fn isIdentByte(c: u8, first: bool) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or (!first and c >= '0' and c <= '9');
}

fn leadingIdent(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and isIdentByte(s[i], i == 0)) i += 1;
    return s[0..i];
}

/// Add the names a Python import statement binds (handling `as` aliases and
/// dotted modules) into `set`. `seg` is the text after `import`.
fn addBoundNames(set: *std.StringHashMap(void), seg_in: []const u8, dotted: bool) !void {
    var seg = seg_in;
    if (std.mem.indexOfScalar(u8, seg, '#')) |h| seg = seg[0..h];
    if (std.mem.indexOfScalar(u8, seg, ')')) |p| seg = seg[0..p];
    var parts = std.mem.splitScalar(u8, seg, ',');
    while (parts.next()) |part| {
        const t = std.mem.trim(u8, part, " \t\r()");
        if (t.len == 0) continue;
        if (std.mem.indexOf(u8, t, " as ")) |ai| {
            const id = leadingIdent(std.mem.trimStart(u8, t[ai + 4 ..], " \t\r"));
            if (id.len > 0) try set.put(id, {});
        } else if (dotted) {
            // `import a.b.c` binds `a`; leadingIdent stops at '.'.
            const id = leadingIdent(t);
            if (id.len > 0) try set.put(id, {});
        } else {
            const id = leadingIdent(t);
            if (id.len > 0) try set.put(id, {});
        }
    }
}

fn collectImportNames(content: []const u8, set: *std.StringHashMap(void)) !void {
    var in_paren = false;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (in_paren) {
            try addBoundNames(set, line, false);
            if (std.mem.indexOfScalar(u8, line, ')') != null) in_paren = false;
            continue;
        }
        if (std.mem.startsWith(u8, line, "from ")) {
            const idx = std.mem.indexOf(u8, line, " import ") orelse continue;
            const rest = line[idx + 8 ..];
            const rest_trimmed = std.mem.trimStart(u8, rest, " \t\r");
            if (std.mem.startsWith(u8, rest_trimmed, "*")) continue; // star import: untrackable
            if (std.mem.indexOfScalar(u8, rest, '(') != null) {
                try addBoundNames(set, rest, false);
                if (std.mem.indexOfScalar(u8, rest, ')') == null) in_paren = true;
            } else {
                try addBoundNames(set, rest, false);
            }
        } else if (std.mem.startsWith(u8, line, "import ")) {
            try addBoundNames(set, line[7..], true);
        }
    }
}

/// First line (1-based) where `name` is used as a whole word in `content`,
/// ignoring comment lines and import lines. null if unused.
fn firstUsageLine(content: []const u8, name: []const u8) ?usize {
    var line: usize = 0;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |raw| {
        line += 1;
        const st = std.mem.trim(u8, raw, " \t\r");
        if (st.len > 0 and st[0] == '#') continue;
        if (std.mem.startsWith(u8, st, "from ") or std.mem.startsWith(u8, st, "import ")) continue;
        var idx: usize = 0;
        while (std.mem.indexOfPos(u8, raw, idx, name)) |p| {
            const before_ok = p == 0 or !isIdentByte(raw[p - 1], false);
            const after_pos = p + name.len;
            const after_ok = after_pos >= raw.len or !isIdentByte(raw[after_pos], false);
            if (before_ok and after_ok) return line;
            idx = p + 1;
        }
    }
    return null;
}

/// Find an import binding removed by the edit that is still referenced in the
/// new file. Python-only for now. The returned name slices into `after_src`.
fn findDroppedImport(allocator: std.mem.Allocator, before: []const u8, after: []const u8, language: Language) !?DroppedName {
    if (language != .python) return null;
    var before_names = std.StringHashMap(void).init(allocator);
    defer before_names.deinit();
    var after_names = std.StringHashMap(void).init(allocator);
    defer after_names.deinit();
    try collectImportNames(before, &before_names);
    try collectImportNames(after, &after_names);

    var it = before_names.keyIterator();
    while (it.next()) |k| {
        const name = k.*;
        if (after_names.contains(name)) continue; // re-imported elsewhere
        if (firstUsageLine(after, name)) |ln| return .{ .name = name, .line = ln };
    }
    return null;
}

/// Returns an owned advisory message describing any post-edit health problem
/// (unbalanced delimiter and/or a dropped-but-used import), or null when the
/// edit looks structurally clean. Caller frees. Exposed for tests.
pub fn describeHealth(allocator: std.mem.Allocator, before: []const u8, after: []const u8, language: Language) !?[]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    if (scanDelimiterBalance(after, language)) |imb| {
        const m = try formatImbalance(allocator, imb);
        defer allocator.free(m);
        try buf.appendSlice(allocator, m);
    }
    if (findDroppedImport(allocator, before, after, language) catch null) |dropped| {
        const m = try std.fmt.allocPrint(allocator, "\n⚠ import check: '{s}' was removed from the imports but is still used at line {d} — this edit likely breaks the module (NameError); re-add the import or revert.", .{ dropped.name, dropped.line });
        defer allocator.free(m);
        try buf.appendSlice(allocator, m);
    }

    if (buf.items.len == 0) {
        buf.deinit(allocator);
        return null;
    }
    return try buf.toOwnedSlice(allocator);
}
