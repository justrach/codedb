const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat.zig");
const explore = @import("explore.zig");
const index = @import("index.zig");

const RING_SIZE = 256;
const CLOUD_URL = "https://codedb.codegraff.com/telemetry/ingest";
const VERSION = "0.2.54";
const PLATFORM = std.fmt.comptimePrint("{s}-{s}", .{ @tagName(builtin.os.tag), @tagName(builtin.cpu.arch) });

pub const Event = struct {
    kind: Kind,

    pub const Kind = union(enum) {
        tool_call: struct {
            tool: [32]u8 = .{0} ** 32,
            tool_len: u8 = 0,
            latency_ns: i128,
            err: bool,
            response_bytes: u32,
        },
        session_start: void,
        codebase_stats: struct {
            file_count: u32,
            total_lines: u64,
            language_mask: u16,
            index_size_bytes: u64,
            startup_time_ms: u64,
        },
    };
};

pub const Telemetry = struct {
    ring: [RING_SIZE]Event = undefined,
    head: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    tail: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    file: ?std.fs.File = null,
    enabled: bool = true,
    buf: [4096]u8 = undefined,
    path_buf: [std.fs.max_path_bytes]u8 = undefined,
    path_len: usize = 0,
    call_count: u32 = 0,
    write_lock: std.Thread.Mutex = .{},

    pub fn init(data_dir: []const u8, allocator: std.mem.Allocator, disabled: bool) Telemetry {
        var self = Telemetry{};

        if (disabled or std.process.hasEnvVarConstant("CODEDB_NO_TELEMETRY")) {
            self.enabled = false;
            return self;
        }

        const path = std.fmt.allocPrint(allocator, "{s}/telemetry.ndjson", .{data_dir}) catch return self;
        defer allocator.free(path);
        if (path.len <= self.path_buf.len) {
            @memcpy(self.path_buf[0..path.len], path);
            self.path_len = path.len;
        }
        self.file = std.fs.cwd().createFile(path, .{ .truncate = false }) catch return self;
        if (self.file) |f| f.seekFromEnd(0) catch {};
        return self;
    }

    pub fn deinit(self: *Telemetry) void {
        if (self.enabled) self.flush();
        if (self.file) |f| f.close();
        self.file = null;
        if (self.enabled) self.syncToCloud();
    }

    pub fn record(self: *Telemetry, kind: Event.Kind) void {
        if (!self.enabled) return;

        self.write_lock.lock();
        const next = self.head.fetchAdd(1, .monotonic);
        const slot = next % RING_SIZE;
        self.ring[slot] = .{
            .kind = kind,
        };
        const tail = self.tail.load(.monotonic);
        if ((next + 1) -% tail > RING_SIZE) {
            self.tail.store((next + 1) -% RING_SIZE, .monotonic);
        }
        self.write_lock.unlock();

        self.call_count += 1;
        if (self.call_count % 3 == 0) {
            self.flush();
        }
        if (self.call_count % 10 == 0) {
            self.syncToCloud();
        }
    }

    pub fn recordSessionStart(self: *Telemetry) void {
        self.record(.{ .session_start = {} });
    }

    pub fn recordToolCall(self: *Telemetry, tool_name: []const u8, latency_ns: i128, is_error: bool, response_bytes: usize) void {
        var tc: Event.Kind = .{ .tool_call = .{
            .latency_ns = latency_ns,
            .err = is_error,
            .response_bytes = @intCast(@min(response_bytes, std.math.maxInt(u32))),
        } };
        const len: u8 = @intCast(@min(tool_name.len, 32));
        @memcpy(tc.tool_call.tool[0..len], tool_name[0..len]);
        tc.tool_call.tool_len = len;
        self.record(tc);
    }

    pub fn recordCodebaseStats(self: *Telemetry, explorer: *explore.Explorer, startup_time_ms: u64) void {
        if (!self.enabled) return;

        explorer.mu.lockShared();
        defer explorer.mu.unlockShared();

        var file_count: u32 = 0;
        var total_lines: u64 = 0;
        var language_mask: u16 = 0;

        var outline_iter = explorer.outlines.iterator();
        while (outline_iter.next()) |entry| {
            file_count +|= 1;
            total_lines +|= entry.value_ptr.line_count;
            const bit_index: u4 = @intCast(@intFromEnum(entry.value_ptr.language));
            language_mask |= @as(u16, 1) << bit_index;
        }

        self.record(.{ .codebase_stats = .{
            .file_count = file_count,
            .total_lines = total_lines,
            .language_mask = language_mask,
            .index_size_bytes = approxIndexSizeBytes(explorer),
            .startup_time_ms = startup_time_ms,
        } });
    }

    pub fn flush(self: *Telemetry) void {
        const f = self.file orelse return;

        self.write_lock.lock();
        defer self.write_lock.unlock();

        const tail = self.tail.load(.monotonic);
        const head = self.head.load(.monotonic);
        if (tail == head) return;

        var i = tail;
        while (i != head) : (i +%= 1) {
            const ev = self.ring[i % RING_SIZE];
            const len = self.formatEvent(&ev) catch continue;
            f.writeAll(self.buf[0..len]) catch continue;
        }
        self.tail.store(head, .monotonic);
    }

    fn syncToCloud(self: *Telemetry) void {
        if (!self.enabled or self.path_len == 0) return;
        const path = self.path_buf[0..self.path_len];

        const stat = compat.dirStatFile(std.fs.cwd(), path) catch return;
        if (stat.size == 0) return;

        // Use argv-based exec (no shell interpolation) to avoid injection
        var data_arg_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
        const data_arg = std.fmt.bufPrint(&data_arg_buf, "@{s}", .{path}) catch return;

        var child = std.process.Child.init(
            &.{ "curl", "-sf", "-X", "POST", CLOUD_URL, "-H", "Content-Type: application/json", "--data-binary", data_arg, "--max-time", "5" },
            std.heap.page_allocator,
        );
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        _ = child.spawnAndWait() catch return;

        // Truncate the file after successful sync
        if (std.fs.cwd().createFile(path, .{ .truncate = true })) |f| {
            f.close();
        } else |_| {}
    }

    pub fn syncWalToCloud(self: *Telemetry, wal_path: ?[]const u8) void {
        if (!self.enabled) return;
        const path = wal_path orelse return;

        const stat = compat.dirStatFile(std.fs.cwd(), path) catch return;
        if (stat.size == 0 or stat.size > 1024 * 1024) return; // skip if empty or >1MB

        // Read WAL, hash sensitive fields, write to temp file for upload
        const data = std.fs.cwd().readFileAlloc(std.heap.page_allocator, path, 1024 * 1024) catch return;
        defer std.heap.page_allocator.free(data);

        // Build sanitized NDJSON: hash query strings and file paths
        var sanitized: std.ArrayList(u8) = .{};
        defer sanitized.deinit(std.heap.page_allocator);
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            if (line.len < 10) continue;
            // Parse minimal fields without a full JSON parser
            // Look for "ev":"query" or "ev":"access" and extract what we need
            if (std.mem.indexOf(u8, line, "\"ev\":\"query\"")) |_| {
                // Extract latency_us and result_bytes, hash the query
                const lat = extractJsonInt(line, "latency_us") orelse continue;
                const rb = extractJsonInt(line, "result_bytes") orelse continue;
                const qh = extractAndHash(line, "query");
                var tool_buf: [32]u8 = undefined;
                const tool = extractJsonStr(line, "tool", &tool_buf) orelse "unknown";
                var buf2: [256]u8 = undefined;
                const entry = std.fmt.bufPrint(&buf2, "{{\"ev\":\"q\",\"t\":\"{s}\",\"qh\":\"{s}\",\"rb\":{d},\"us\":{d}}}\n", .{
                    tool, qh, rb, lat,
                }) catch continue;
                sanitized.appendSlice(std.heap.page_allocator, entry) catch continue;
            } else if (std.mem.indexOf(u8, line, "\"ev\":\"access\"")) |_| {
                const lat = extractJsonInt(line, "latency_us") orelse continue;
                const ph = extractAndHash(line, "path");
                var tool_buf: [32]u8 = undefined;
                const tool = extractJsonStr(line, "tool", &tool_buf) orelse "unknown";
                var buf2: [256]u8 = undefined;
                const entry = std.fmt.bufPrint(&buf2, "{{\"ev\":\"a\",\"t\":\"{s}\",\"ph\":\"{s}\",\"us\":{d}}}\n", .{
                    tool, ph, lat,
                }) catch continue;
                sanitized.appendSlice(std.heap.page_allocator, entry) catch continue;
            }
        }

        if (sanitized.items.len == 0) return;

        // Write to temp file and curl to cloud
        const tmp_path = "/tmp/codedb-wal-sync.jsonl";
        if (std.fs.cwd().createFile(tmp_path, .{ .truncate = true })) |f| {
            f.writeAll(sanitized.items) catch {};
            f.close();
        } else |_| return;

        var child = std.process.Child.init(
            &.{ "curl", "-sf", "-X", "POST", CLOUD_URL, "-H", "Content-Type: application/json", "--data-binary", "@/tmp/codedb-wal-sync.jsonl", "--max-time", "5" },
            std.heap.page_allocator,
        );
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        _ = child.spawnAndWait() catch return;

        // Truncate WAL after successful sync
        if (std.fs.cwd().createFile(path, .{ .truncate = true })) |f| {
            f.close();
        } else |_| {}
    }

fn extractJsonInt(line: []const u8, key: []const u8) ?i64 {
    // Find "key":VALUE pattern
    var search_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&search_buf, "\"{s}\":", .{key}) catch return null;
    const pos = std.mem.indexOf(u8, line, needle) orelse return null;
    const start = pos + needle.len;
    var end = start;
    while (end < line.len and (line[end] >= '0' and line[end] <= '9')) : (end += 1) {}
    if (end == start) return null;
    return std.fmt.parseInt(i64, line[start..end], 10) catch null;
}

fn extractJsonStr(line: []const u8, key: []const u8, out: *[32]u8) ?[]const u8 {
    var search_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&search_buf, "\"{s}\":\"", .{key}) catch return null;
    const pos = std.mem.indexOf(u8, line, needle) orelse return null;
    const start = pos + needle.len;
    const end = std.mem.indexOfScalarPos(u8, line, start, '"') orelse return null;
    const len = @min(end - start, out.len);
    @memcpy(out[0..len], line[start..][0..len]);
    return out[0..len];
}

fn extractAndHash(line: []const u8, key: []const u8) []const u8 {
    var search_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&search_buf, "\"{s}\":\"", .{key}) catch return "0";
    const pos = std.mem.indexOf(u8, line, needle) orelse return "0";
    const start = pos + needle.len;
    const end = std.mem.indexOfScalarPos(u8, line, start, '"') orelse return "0";
    const val = line[start..end];
    const hash = std.hash.Wyhash.hash(0, val);
    // Return hex string via a static buffer (not great but works for logging)
    const S = struct { var hex: [16]u8 = undefined; };
    _ = std.fmt.bufPrint(&S.hex, "{x:0>16}", .{hash}) catch return "0";
    return &S.hex;
}

    fn formatEvent(self: *Telemetry, ev: *const Event) !usize {
        var fbs = std.io.fixedBufferStream(&self.buf);
        const w = fbs.writer();
        try w.print("{{\"timestamp_ms\":{d}", .{std.time.milliTimestamp()});
        switch (ev.kind) {
            .tool_call => |tc| {
                const name = tc.tool[0..tc.tool_len];
                try w.print(",\"event_type\":\"tool_call\",\"tool\":\"{s}\",\"latency_ns\":{d},\"error\":{s},\"response_bytes\":{d}", .{
                    name,
                    @as(i64, @intCast(@min(tc.latency_ns, std.math.maxInt(i64)))),
                    if (tc.err) "true" else "false",
                    tc.response_bytes,
                });
            },
            .session_start => {
                try w.print(",\"event_type\":\"session_start\",\"version\":\"{s}\",\"platform\":\"{s}\"", .{ VERSION, PLATFORM });
            },
            .codebase_stats => |stats| {
                try w.print(",\"event_type\":\"codebase_stats\",\"file_count\":{d},\"total_lines\":{d},\"languages\":[", .{
                    stats.file_count,
                    stats.total_lines,
                });
                try writeLanguages(w, stats.language_mask);
                try w.print("],\"index_size_bytes\":{d},\"startup_time_ms\":{d}", .{
                    stats.index_size_bytes,
                    stats.startup_time_ms,
                });
            },
        }
        try w.writeAll("}\n");
        return fbs.pos;
    }
};

fn writeLanguages(writer: anytype, language_mask: u16) !void {
    const names = [_][]const u8{
        "zig",
        "c",
        "cpp",
        "python",
        "javascript",
        "typescript",
        "rust",
        "go_lang",
        "markdown",
        "json",
        "yaml",
        "unknown",
    };
    var first = true;
    for (names, 0..) |name, idx| {
        const bit_index: u4 = @intCast(idx);
        if ((language_mask & (@as(u16, 1) << bit_index)) == 0) continue;
        if (!first) try writer.writeByte(',');
        first = false;
        try writer.print("\"{s}\"", .{name});
    }
}

pub fn approxIndexSizeBytes(explorer: *const explore.Explorer) u64 {
    var total: u64 = 0;

    var word_iter = explorer.word_index.index.iterator();
    while (word_iter.next()) |entry| {
        total +|= entry.key_ptr.*.len;
        total +|= entry.value_ptr.items.len * @sizeOf(@TypeOf(entry.value_ptr.items[0]));
    }

    var file_words_iter = explorer.word_index.file_words.iterator();
    while (file_words_iter.next()) |entry| {
        total +|= entry.value_ptr.count() * @sizeOf(usize);
    }

    switch (explorer.trigram_index) {
        .heap => |*h| {
            var trigram_iter = h.index.iterator();
            while (trigram_iter.next()) |entry| {
                total +|= @sizeOf(@TypeOf(entry.key_ptr.*));
                total +|= entry.value_ptr.count() * (@sizeOf(usize) + @sizeOf(index.PostingMask));
            }

            var file_trigrams_iter = h.file_trigrams.iterator();
            while (file_trigrams_iter.next()) |entry| {
                total +|= entry.value_ptr.items.len * @sizeOf(@TypeOf(entry.value_ptr.items[0]));
            }
        },
        .mmap => {},
        .mmap_overlay => |*mo| {
            var trigram_iter = mo.overlay.index.iterator();
            while (trigram_iter.next()) |entry| {
                total +|= @sizeOf(@TypeOf(entry.key_ptr.*));
                total +|= entry.value_ptr.count() * (@sizeOf(usize) + @sizeOf(index.PostingMask));
            }
        },
    }

    var sparse_iter = explorer.sparse_ngram_index.index.iterator();
    while (sparse_iter.next()) |entry| {
        total +|= @sizeOf(@TypeOf(entry.key_ptr.*));
        total +|= entry.value_ptr.count() * @sizeOf(usize);
    }

    var file_sparse_iter = explorer.sparse_ngram_index.file_ngrams.iterator();
    while (file_sparse_iter.next()) |entry| {
        total +|= entry.value_ptr.items.len * @sizeOf(@TypeOf(entry.value_ptr.items[0]));
    }

    return total;
}
