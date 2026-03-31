const std = @import("std");

const RING_SIZE = 256;

pub const Event = struct {
    ts: i64,
    kind: Kind,

    pub const Kind = union(enum) {
        tool_call: struct {
            tool: [32]u8 = .{0} ** 32,
            tool_len: u8 = 0,
            latency_ns: i128,
            err: bool,
            response_bytes: u32,
        },
        session_start: struct {
            file_count: u32,
            total_lines: u64,
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

    pub fn init(data_dir: []const u8, allocator: std.mem.Allocator) Telemetry {
        var self = Telemetry{};

        if (std.process.hasEnvVarConstant("CODEDB_NO_TELEMETRY")) {
            self.enabled = false;
            return self;
        }

        const path = std.fmt.allocPrint(allocator, "{s}/telemetry.ndjson", .{data_dir}) catch return self;
        defer allocator.free(path);
        self.file = std.fs.cwd().createFile(path, .{ .truncate = false }) catch return self;
        if (self.file) |f| f.seekFromEnd(0) catch {};
        return self;
    }

    pub fn deinit(self: *Telemetry) void {
        if (self.enabled) self.flush();
        if (self.file) |f| f.close();
        self.file = null;
    }

    /// Hot path — no allocation, no syscall, no blocking.
    /// Just copies into the next ring slot.
    pub fn record(self: *Telemetry, kind: Event.Kind) void {
        if (!self.enabled) return;
        const slot = self.head.fetchAdd(1, .monotonic) % RING_SIZE;
        self.ring[slot] = .{
            .ts = std.time.timestamp(),
            .kind = kind,
        };
        // Advance tail if we wrapped (drop oldest)
        const head = self.head.load(.monotonic);
        const tail = self.tail.load(.monotonic);
        if (head -% tail > RING_SIZE) {
            self.tail.store(head -% RING_SIZE, .monotonic);
        }
    }

    /// Convenience for the handleCall hot path.
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

    /// Cold path — called on idle or shutdown. Drains ring to disk.
    pub fn flush(self: *Telemetry) void {
        const f = self.file orelse return;
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

    fn formatEvent(self: *Telemetry, ev: *const Event) !usize {
        var fbs = std.io.fixedBufferStream(&self.buf);
        const w = fbs.writer();
        try w.print("{{\"ts\":{d}", .{ev.ts});
        switch (ev.kind) {
            .tool_call => |tc| {
                const name = tc.tool[0..tc.tool_len];
                try w.print(",\"ev\":\"tool\",\"tool\":\"{s}\",\"ns\":{d},\"err\":{s},\"bytes\":{d}", .{
                    name,
                    @as(i64, @intCast(@min(tc.latency_ns, std.math.maxInt(i64)))),
                    if (tc.err) "true" else "false",
                    tc.response_bytes,
                });
            },
            .session_start => |ss| {
                try w.print(",\"ev\":\"start\",\"files\":{d},\"lines\":{d}", .{
                    ss.file_count,
                    ss.total_lines,
                });
            },
        }
        try w.writeAll("}\n");
        return fbs.pos;
    }
};
