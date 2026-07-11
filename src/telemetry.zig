const std = @import("std");
const cio = @import("cio.zig");
const builtin = @import("builtin");
const explore = @import("explore.zig");
const index = @import("index.zig");

const RING_SIZE = 256;
/// Inline flush cadence. Must be a power of two so the hot path can mask
/// instead of mod. Sized so a busy session still flushes within the
/// background sync window. RING_SIZE / FLUSH_INTERVAL_EVENTS ≥ 4 means
const FLUSH_INTERVAL_EVENTS: u64 = 64;

/// Tiny CAS-based spinlock. record() is the WAL hot path so the lock has
/// to be cheaper than pthread_mutex (~150 ns) and std.Io.Mutex is
/// async-context aware and overkill for an SPSC ring. Uncontended
/// lock+unlock is ~5–10 ns. spinLoopHint keeps power down on the rare
/// contended case (typically only when flush is concurrent with record).
const SpinLock = struct {
    state: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),

    fn lock(self: *SpinLock) void {
        while (self.state.cmpxchgWeak(0, 1, .acquire, .monotonic)) |_| {
            std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *SpinLock) void {
        self.state.store(0, .release);
    }
};
const CLOUD_URL = "https://codedb.codegraff.com/telemetry/ingest";
const VERSION = @import("release_info.zig").semver;
const PLATFORM = std.fmt.comptimePrint("{s}-{s}", .{ @tagName(builtin.os.tag), @tagName(builtin.cpu.arch) });

pub const Event = struct {
    kind: Kind,

    pub const Kind = union(enum) {
        tool_call: struct {
            tool: [32]u8 = @splat(0),
            tool_len: u8 = 0,
            latency_ns: i128,
            err: bool,
            response_bytes: u32,
        },
        session_start: void,
        codebase_stats: struct {
            file_count: u32,
            total_lines: u64,
            language_mask: u32,
            index_size_bytes: u64,
            startup_time_ms: u64,
        },
        search_breakdown: struct {
            tier0_ns: i64,
            tier05_ns: i64,
            tier1_ns: i64,
            tier2_ns: i64,
            tier3_ns: i64,
            tier4_ns: i64,
            tier5_ns: i64,
            rerank_ns: i64,
            tier_reached: u8,
            candidate_count: u32,
            result_count: u32,
        },
    };
};

pub const Telemetry = struct {
    ring: [RING_SIZE]Event = undefined,
    head: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    tail: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    file: ?std.Io.File = null,
    io: std.Io = undefined,
    write_offset: u64 = 0,
    enabled: bool = true,
    buf: [4096]u8 = undefined,
    path_buf: [std.fs.max_path_bytes]u8 = undefined,
    path_len: usize = 0,
    call_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// Compact spinlock for the WAL ring. Uncontended lock is ~5–10 ns
    /// (single CAS + acquire fence), vs ~100–200 ns for pthread_mutex via
    /// libc on macOS. record() is the only writer except during the
    /// rare flush(), so contention is effectively zero — spinning is
    /// strictly cheaper than the futex/syscall path. See #504-bench.
    write_lock: SpinLock = .{},
    /// Background sync thread (set by startSyncThread). Cloud sync runs on
    /// this thread so it never blocks the tool-call response path.
    sync_thread: ?std.Thread = null,
    /// Signals the background sync thread to exit. Set on deinit.
    should_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// How often the background thread syncs to cloud (seconds). 30s
    /// matches the previous per-10-calls cadence on typical workloads
    /// without ever blocking a tool response.
    sync_interval_seconds: u64 = 30,

    pub fn init(io: std.Io, data_dir: []const u8, allocator: std.mem.Allocator, disabled: bool) Telemetry {
        var self = Telemetry{};
        self.io = io;

        if (disabled or cio.posixGetenv("CODEDB_NO_TELEMETRY") != null) {
            self.enabled = false;
            return self;
        }

        const path = std.fmt.allocPrint(allocator, "{s}/telemetry.ndjson", .{data_dir}) catch return self;
        defer allocator.free(path);
        if (path.len <= self.path_buf.len) {
            @memcpy(self.path_buf[0..path.len], path);
            self.path_len = path.len;
        }
        self.file = std.Io.Dir.cwd().createFile(io, path, .{ .truncate = false }) catch return self;
        if (self.file) |f| {
            self.write_offset = f.length(io) catch 0;
        }
        return self;
    }

    pub fn deinit(self: *Telemetry) void {
        // Signal background sync thread to stop and wait for it before
        // touching shared state (file, write_offset) below.
        self.should_stop.store(true, .release);
        if (self.sync_thread) |th| {
            th.join();
            self.sync_thread = null;
        }
        if (self.enabled) self.flush();
        if (self.file) |f| f.close(self.io);
        self.file = null;
        // Final cloud sync on shutdown — the background thread may have
        // run a sync moments ago, but this guarantees the WAL is uploaded
        // if there are events since the last tick.
        if (self.enabled) self.syncToCloud();
    }

    /// Start the background cloud-sync thread. Call this AFTER the
    /// Telemetry has been placed at its final memory location (init returns
    /// by value, so the thread can't safely take a pointer until then).
    /// No-op when telemetry is disabled or already started.
    pub fn startSyncThread(self: *Telemetry) void {
        if (!self.enabled) return;
        if (self.sync_thread != null) return;
        self.sync_thread = std.Thread.spawn(.{}, syncThreadFn, .{self}) catch return;
    }

    /// Background loop: every `sync_interval_seconds`, call syncToCloud.
    /// Checks should_stop every 100ms so shutdown is responsive (<=100ms
    /// shutdown latency rather than waiting out a full interval).
    fn syncThreadFn(self: *Telemetry) void {
        const tick_ms: u64 = 100;
        const ticks_per_interval: u64 = self.sync_interval_seconds * 1000 / tick_ms;
        while (!self.should_stop.load(.acquire)) {
            var i: u64 = 0;
            while (i < ticks_per_interval) : (i += 1) {
                if (self.should_stop.load(.acquire)) return;
                cio.sleepMs(tick_ms);
            }
            if (self.should_stop.load(.acquire)) return;
            self.syncToCloud();
        }
    }

    pub fn record(self: *Telemetry, kind: Event.Kind) void {
        if (!self.enabled) return;
        // Fast-out when there's no destination configured. Telemetry default
        // initialization (`Telemetry{ .enabled = true }`) leaves file=null,
        // which is the bench harness's "telem_on" — formerly we still paid
        // for the lock + ring-write + atomic update only to drop it on the
        // floor at flush time. Skipping here makes telemetry overhead
        // close to zero for sub-µs tools when no destination is set.
        if (self.file == null) return;

        self.write_lock.lock();
        const next = self.head.fetchAdd(1, .monotonic);
        const slot = next % RING_SIZE;
        self.ring[slot] = .{ .kind = kind };
        const tail = self.tail.load(.monotonic);
        if ((next + 1) -% tail > RING_SIZE) {
            self.tail.store((next + 1) -% RING_SIZE, .monotonic);
        }
        self.write_lock.unlock();

        const count = self.call_count.fetchAdd(1, .monotonic) + 1;
        // Inline flush amortised every FLUSH_INTERVAL_EVENTS events. The
        // sync thread + deinit() also flush, so the on-disk WAL is at
        // most FLUSH_INTERVAL_EVENTS events stale instead of 3 (the
        // previous cadence which fired a writePositionalAll syscall on
        // every sub-µs tool call). See `perf(telemetry)` commit history.
        if (count & (FLUSH_INTERVAL_EVENTS - 1) == 0) {
            self.flush();
        }
    }
    pub fn recordSessionStart(self: *Telemetry) void {
        self.record(.{ .session_start = {} });
    }

    pub fn recordToolCall(self: *Telemetry, tool_name: []const u8, latency_ns: i128, is_error: bool, response_bytes: usize) void {
        if (!self.enabled) return;
        var tc: Event.Kind = .{ .tool_call = .{
            .latency_ns = latency_ns,
            .err = is_error,
            .response_bytes = @intCast(@min(response_bytes, std.math.maxInt(u32))),
        } };
        var len: u8 = @intCast(@min(tool_name.len, 32));
        while (len > 0 and !std.unicode.utf8ValidateSlice(tool_name[0..len])) : (len -= 1) {}
        @memcpy(tc.tool_call.tool[0..len], tool_name[0..len]);
        tc.tool_call.tool_len = len;
        self.record(tc);
    }

    pub fn recordSearchBreakdown(self: *Telemetry, bd: explore.SearchBreakdown) void {
        if (!self.enabled) return;
        const clamp = struct {
            fn f(v: i128) i64 {
                return @intCast(@min(v, std.math.maxInt(i64)));
            }
        }.f;
        self.record(.{ .search_breakdown = .{
            .tier0_ns = clamp(bd.tier0_ns),
            .tier05_ns = clamp(bd.tier05_ns),
            .tier1_ns = clamp(bd.tier1_ns),
            .tier2_ns = clamp(bd.tier2_ns),
            .tier3_ns = clamp(bd.tier3_ns),
            .tier4_ns = clamp(bd.tier4_ns),
            .tier5_ns = clamp(bd.tier5_ns),
            .rerank_ns = clamp(bd.rerank_ns),
            .tier_reached = bd.tier_reached,
            .candidate_count = bd.candidate_count,
            .result_count = bd.result_count,
        } });
    }

    pub fn recordCodebaseStats(self: *Telemetry, explorer: *explore.Explorer, startup_time_ms: u64) void {
        if (!self.enabled) return;

        explorer.mu.lockShared();
        defer explorer.mu.unlockShared();

        var file_count: u32 = 0;
        var total_lines: u64 = 0;
        var language_mask: u32 = 0;

        var outline_iter = explorer.outlines.iterator();
        while (outline_iter.next()) |entry| {
            file_count +|= 1;
            total_lines +|= entry.value_ptr.line_count;
            const bit_index: u5 = @intCast(@intFromEnum(entry.value_ptr.language));
            language_mask |= @as(u32, 1) << bit_index;
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
            f.writePositionalAll(self.io, self.buf[0..len], self.write_offset) catch continue;
            self.write_offset += len;
        }
        self.tail.store(head, .monotonic);
    }

    fn syncToCloud(self: *Telemetry) void {
        if (!self.enabled or self.path_len == 0) return;
        const path = self.path_buf[0..self.path_len];

        const stat = std.Io.Dir.cwd().statFile(self.io, path, .{}) catch return;
        if (stat.size == 0) return;

        // Use argv-based exec (no shell interpolation) to avoid injection
        var data_arg_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
        const data_arg = std.fmt.bufPrint(&data_arg_buf, "@{s}", .{path}) catch return;

        const result = cio.runCapture(.{
            .allocator = std.heap.page_allocator,
            .argv = &.{ "curl", "-sf", "-X", "POST", CLOUD_URL, "-H", "Content-Type: application/json", "--data-binary", data_arg, "--max-time", "5" },
            .max_output_bytes = 4096,
        }) catch return;
        std.heap.page_allocator.free(result.stdout);
        std.heap.page_allocator.free(result.stderr);

        // Truncate the file after successful sync
        if (std.Io.Dir.cwd().createFile(self.io, path, .{ .truncate = true })) |f| {
            f.close(self.io);
            self.write_offset = 0;
        } else |_| {}
    }

    pub fn syncWalToCloud(self: *Telemetry, wal_path: ?[]const u8) void {
        _ = wal_path;
        self.syncToCloud();
    }

    fn formatEvent(self: *Telemetry, ev: *const Event) !usize {
        var stream = std.Io.Writer.fixed(&self.buf);
        const w = &stream;
        try w.print("{{\"timestamp_ms\":{d},\"version\":\"{s}\"", .{ cio.milliTimestamp(), VERSION });
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
                try w.print(",\"event_type\":\"session_start\",\"platform\":\"{s}\"", .{PLATFORM});
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
            .search_breakdown => |sb| {
                try w.print(",\"event_type\":\"search_breakdown\",\"tier0_ns\":{d},\"tier05_ns\":{d},\"tier1_ns\":{d},\"tier2_ns\":{d},\"tier3_ns\":{d},\"tier4_ns\":{d},\"tier5_ns\":{d},\"rerank_ns\":{d},\"tier_reached\":{d},\"candidates\":{d},\"results\":{d}", .{
                    sb.tier0_ns,        sb.tier05_ns,    sb.tier1_ns,
                    sb.tier2_ns,        sb.tier3_ns,     sb.tier4_ns,
                    sb.tier5_ns,        sb.rerank_ns,    sb.tier_reached,
                    sb.candidate_count, sb.result_count,
                });
            },
        }
        try w.writeAll("}\n");
        return w.end;
    }
};

fn writeLanguages(writer: anytype, language_mask: u32) !void {
    const names = [_][]const u8{
        "zig",
        "c",
        "cpp",
        "python",
        "javascript",
        "typescript",
        "rust",
        "go_lang",
        "php",
        "ruby",
        "hcl",
        "r",
        "markdown",
        "json",
        "yaml",
        "unknown",
        "dart",
        "java",
        "kotlin",
        "svelte",
        "vue",
        "astro",
        "shell",
        "css",
        "scss",
        "sql",
        "protobuf",
        "fortran",
        "llvm_ir",
        "mlir",
        "tablegen",
    };
    var first = true;
    for (names, 0..) |name, idx| {
        const bit_index: u5 = @intCast(idx);
        if ((language_mask & (@as(u32, 1) << bit_index)) == 0) continue;
        if (!first) try writer.writeByte(',');
        first = false;
        try writer.print("\"{s}\"", .{name});
    }
}

pub fn approxIndexSizeBytes(explorer: *const explore.Explorer) u64 {
    // Aggregate-only estimate. Keep this O(1): status and startup telemetry call
    // it on hot paths, and exact allocator accounting would require walking all
    // word/trigram posting lists.
    var total: u64 = 0;

    total +|= @as(u64, @intCast(explorer.word_index.index.count())) * 40;
    total +|= explorer.word_index.total_tokens * @sizeOf(index.WordHit);
    total +|= @as(u64, @intCast(explorer.word_index.file_words.count())) * 128;
    total +|= @as(u64, @intCast(explorer.word_index.doc_lengths.count())) * (@sizeOf(u32) + @sizeOf(u32));
    total +|= @as(u64, @intCast(explorer.word_index.id_to_path.items.len)) * @sizeOf([]const u8);

    switch (explorer.trigram_index) {
        .heap => |heap| {
            total +|= @as(u64, @intCast(heap.index.count())) * 48;
            total +|= @as(u64, @intCast(heap.file_trigrams.count())) * 512;
            total +|= @as(u64, @intCast(heap.id_to_path.items.len)) * @sizeOf([]const u8);
            total +|= @as(u64, @intCast(heap.free_ids.items.len)) * @sizeOf(u32);
        },
        .mmap, .mmap_overlay => {},
    }

    return total;
}
