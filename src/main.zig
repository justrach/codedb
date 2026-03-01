// gitagent-mcp — MCP server (JSON-RPC 2.0 over stdio)
// Protocol: JSON-RPC transport via NDJSON by default, with optional MCP stdio headers.
// Lifecycle: initialize → notifications/initialized → tools/list + tools/call loop.

const std = @import("std");
const mj = @import("mcp").json; // readLine, getStr/Int/Bool, eql, writeEscaped
const tools = @import("tools.zig");
const cache = @import("cache.zig");

const MaxThreadIdLen = 96;
const MaxThreads = 32;
const DefaultThreadId = "default";
const MaxFrameBytes: usize = 1024 * 1024;

const ThreadContext = struct {
    id: [MaxThreadIdLen]u8 = undefined,
    id_len: usize = 0,
    repo_path: ?[]const u8 = null,
};

fn defaultThreadContext() *ThreadContext {
    return &g_thread_contexts[0];
}

var g_thread_contexts: [MaxThreads]ThreadContext = undefined;
var g_thread_count: usize = 0;
var g_use_headers: bool = false;


pub fn main() void {
    const act = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.PIPE, &act, null) catch {};

    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var active_repo = detectRepo(alloc);
    defer if (active_repo) |path| alloc.free(path);
    defer cleanupThreadContexts(alloc);

    if (active_repo) |path| {
        std.posix.chdir(path) catch |err| {
            std.debug.print("[gitagent] warning: chdir({s}) failed: {}\n", .{ path, err });
            alloc.free(path);
            active_repo = null;
        };
        if (active_repo != null) {
            setThreadRepoPath(alloc, getThreadContext(DefaultThreadId), path);
            tools.detectAndUpdateRepo(alloc);
        }
    } else {
        _ = getThreadContext(DefaultThreadId);
    }

    run(alloc, &active_repo);
}

fn cleanupThreadContexts(alloc: std.mem.Allocator) void {
    var i: usize = 0;
    while (i < g_thread_count) : (i += 1) {
        if (g_thread_contexts[i].repo_path) |path| {
            alloc.free(path);
            g_thread_contexts[i].repo_path = null;
        }
    }
}

fn run(alloc: std.mem.Allocator, active_repo: *?[]const u8) void {
    const stdout = std.fs.File.stdout();
    const stdin = std.fs.File.stdin();

    while (true) {
        var message_uses_headers: bool = false;
        const line = readMessage(alloc, stdin, &message_uses_headers) catch |err| {
            switch (err) {
                error.InvalidMessage => {
                    writeError(alloc, stdout, null, -32700, "Invalid message framing");
                    continue;
                },
            }
            break;
        } orelse break;
        g_use_headers = g_use_headers or message_uses_headers;
        defer alloc.free(line);

        const input = std.mem.trim(u8, line, " \t\r\n");
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
        const method = mj.getStr(root, "method") orelse {
            writeError(alloc, stdout, null, -32600, "Missing method");
            continue;
        };
        const id = root.get("id");

        if (mj.eql(method, "initialize")) {
            handleInitialize(alloc, stdout, id);
        } else if (mj.eql(method, "notifications/initialized") or mj.eql(method, "initialized")) {
            // Warm the session cache now that the client is ready.
            cache.prefetch(alloc);
            if (id != null) {
                writeResult(alloc, stdout, id, "null");
            }
        } else if (mj.eql(method, "tools/list")) {
            writeResult(alloc, stdout, id, tools.tools_list);
        } else if (mj.eql(method, "tools/call")) {
            handleCall(alloc, root, active_repo, stdout, id);
        } else if (mj.eql(method, "ping")) {
            writeResult(alloc, stdout, id, "{}");
        } else {
            // Notifications (no id) are silently ignored.
            if (id != null) writeError(alloc, stdout, id, -32601, "Method not found");
        }
    }
}

fn readMessage(alloc: std.mem.Allocator, file: std.fs.File, uses_headers: *bool) !?[]u8 {
    while (true) {
        const first = mj.readLine(alloc, file) orelse return null;
        const first_trim = std.mem.trim(u8, first, " \t\r\n");
        if (first_trim.len == 0) {
            alloc.free(first);
            continue;
        }

        if (first_trim[0] == '{' or first_trim[0] == '[') return first;

        uses_headers.* = true;
        var content_length: ?usize = null;
        parseHeaderLen(first_trim, &content_length);

        while (true) {
            const header = mj.readLine(alloc, file) orelse {
                alloc.free(first);
                return error.InvalidMessage;
            };
            const h = std.mem.trim(u8, header, " \t\r\n");
            if (h.len == 0) {
                alloc.free(header);
                break;
            }
            parseHeaderLen(h, &content_length);
            alloc.free(header);
        }

        const len = content_length orelse {
            alloc.free(first);
            return error.InvalidMessage;
        };
        if (len > MaxFrameBytes) {
            alloc.free(first);
            return error.InvalidMessage;
        }

        var body = alloc.alloc(u8, len) catch {
            alloc.free(first);
            return error.InvalidMessage;
        };
        var got: usize = 0;
        while (got < len) {
            const n = file.read(body[got..len]) catch {
                alloc.free(first);
                alloc.free(body);
                return error.InvalidMessage;
            };
            if (n == 0) {
                alloc.free(first);
                alloc.free(body);
                return error.InvalidMessage;
            }
            got += n;
        }

        alloc.free(first);
        return body;
    }
}

fn parseHeaderLen(line: []const u8, content_length: *?usize) void {
    var sep: ?usize = null;
    for (line, 0..) |ch, i| {
        if (ch == ':') {
            sep = i;
            break;
        }
    }
    const sep_idx = sep orelse return;
    const key = std.mem.trim(u8, line[0..sep_idx], " \t");
    if (!std.ascii.eqlIgnoreCase(key, "content-length")) return;

    const val = std.mem.trim(u8, line[sep_idx + 1 ..], " \t\r\n");
    content_length.* = std.fmt.parseUnsigned(usize, val, 10) catch null;
}

fn getThreadContext(thread_id: []const u8) *ThreadContext {
    const id = normalizeThreadId(thread_id);

    for (0..g_thread_count) |i| {
        const ctx = &g_thread_contexts[i];
        if (ctx.id_len == id.len and std.mem.eql(u8, ctx.id[0..ctx.id_len], id)) {
            return ctx;
        }
    }

    if (g_thread_count >= g_thread_contexts.len) {
        return defaultThreadContext();
    }

    const idx = g_thread_count;
    g_thread_count += 1;

    const ctx = &g_thread_contexts[idx];
    const copy_len = @min(id.len, MaxThreadIdLen);
    @memcpy(ctx.id[0..copy_len], id[0..copy_len]);
    ctx.id_len = copy_len;
    ctx.repo_path = null;
    return ctx;
}

fn normalizeThreadId(thread_id: []const u8) []const u8 {
    if (thread_id.len == 0) return DefaultThreadId;
    if (thread_id.len > MaxThreadIdLen) return DefaultThreadId;
    return thread_id;
}

fn setThreadRepoPath(alloc: std.mem.Allocator, ctx: *ThreadContext, repo_path: []const u8) void {
    if (ctx.repo_path) |old| alloc.free(old);
    const owned = alloc.dupe(u8, repo_path) catch return;
    ctx.repo_path = owned;
}

fn handleCall(
    alloc: std.mem.Allocator,
    root: *const std.json.ObjectMap,
    active_repo: *?[]const u8,
    stdout: std.fs.File,
    id: ?std.json.Value,
) void {
    var empty_params = std.json.ObjectMap.init(alloc);
    var empty_args = std.json.ObjectMap.init(alloc);
    defer {
        empty_params.deinit();
        empty_args.deinit();
    }

    const params: *const std.json.ObjectMap = blk: {
        if (root.get("params")) |params_val| {
            if (params_val != .object) {
                writeError(alloc, stdout, id, -32602, "params must be object");
                return;
            }
            break :blk &params_val.object;
        }
        break :blk &empty_params;
    };

    const args: *const std.json.ObjectMap = blk: {
        if (params.get("arguments")) |args_val| {
            if (args_val != .object) {
                writeError(alloc, stdout, id, -32602, "arguments must be object");
                return;
            }
            break :blk &args_val.object;
        }
        break :blk &empty_args;
    };

    const thread_ctx = getThreadContext(resolveThreadId(params, args));

    if (resolveRepoFromArgs(params, args)) |repo_path| {
        switchRepo(alloc, active_repo, thread_ctx, id, repo_path, stdout);
    } else if (thread_ctx.repo_path) |thread_repo| {
        if (active_repo.*) |current_repo| {
            if (!std.mem.eql(u8, current_repo, thread_repo)) {
                switchRepo(alloc, active_repo, thread_ctx, id, thread_repo, stdout);
            }
        } else {
            switchRepo(alloc, active_repo, thread_ctx, id, thread_repo, stdout);
        }
    }

    const name = mj.getStr(params, "name") orelse {
        writeError(alloc, stdout, id, -32602, "Missing tool name");
        return;
    };

    const tool = tools.parse(name) orelse {
        writeError(alloc, stdout, id, -32602, "Unknown tool");
        return;
    };

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    tools.dispatch(alloc, tool, args, &out);

    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(alloc);
    result.appendSlice(alloc, "{\"content\":[{\"type\":\"text\",\"text\":\"") catch return;
    mj.writeEscaped(alloc, &result, out.items);
    result.appendSlice(alloc, "\"}],\"isError\":false}") catch return;

    writeResult(alloc, stdout, id, result.items);
}

fn handleInitialize(
    alloc: std.mem.Allocator,
    stdout: std.fs.File,
    id: ?std.json.Value,
) void {
    writeResult(
        alloc,
        stdout,
        id,
        "{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{\"tools\":{\"listChanged\":false}},\"serverInfo\":{\"name\":\"gitagent-mcp\",\"version\":\"0.1.0\"}}",
    );
}

fn resolveThreadId(
    params: *const std.json.ObjectMap,
    args: *const std.json.ObjectMap,
) []const u8 {
    if (params.get("thread_id")) |thread_id| {
        if (thread_id == .string and thread_id.string.len > 0) return thread_id.string;
    }
    if (params.get("threadId")) |thread_id| {
        if (thread_id == .string and thread_id.string.len > 0) return thread_id.string;
    }
    if (args.get("thread_id")) |thread_id| {
        if (thread_id == .string and thread_id.string.len > 0) return thread_id.string;
    }
    if (args.get("threadId")) |thread_id| {
        if (thread_id == .string and thread_id.string.len > 0) return thread_id.string;
    }
    return DefaultThreadId;
}

fn detectRepo(alloc: std.mem.Allocator) ?[]const u8 {
    if (std.process.getEnvVarOwned(alloc, "REPO_PATH")) |path| {
        return path;
    } else |_| {}

    var child = std.process.Child.init(
        &.{ "git", "rev-parse", "--show-toplevel" },
        alloc,
    );
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Close;
    child.stdin_behavior = .Close;

    if (child.spawn()) |_| {
        const stdout = child.stdout orelse return null;
        var buf: [4096]u8 = undefined;
        const n = stdout.read(&buf) catch return null;
        _ = child.wait() catch {};
        return alloc.dupe(u8, std.mem.trim(u8, buf[0..n], " \t\r\n")) catch null;
    } else |_| {
        return null;
    }
}

fn resolveRepoFromArgs(
    params: *const std.json.ObjectMap,
    args: *const std.json.ObjectMap,
) ?[]const u8 {
    if (mj.getStr(params, "repo_path")) |path| {
        return path;
    }
    if (mj.getStr(params, "repo")) |path| {
        return path;
    }
    if (mj.getStr(params, "working_directory")) |path| {
        return path;
    }

    if (mj.getStr(args, "repo_path")) |path| {
        return path;
    }
    if (mj.getStr(args, "repo")) |path| {
        return path;
    }
    if (mj.getStr(args, "working_directory")) |path| {
        return path;
    }

    return null;
}

fn switchRepo(
    alloc: std.mem.Allocator,
    active_repo: *?[]const u8,
    thread_ctx: *ThreadContext,
    id: ?std.json.Value,
    requested_repo: []const u8,
    stdout: std.fs.File,
) void {
    if (active_repo.*) |current| {
        if (std.mem.eql(u8, current, requested_repo)) {
            setThreadRepoPath(alloc, thread_ctx, requested_repo);
            return;
        }
    }

    std.posix.chdir(requested_repo) catch |err| {
        writeError(alloc, stdout, id, -32602, "Unable to switch repository");
        std.debug.print("[gitagent] warning: chdir({s}) failed: {}\n", .{ requested_repo, err });
        return;
    };

    if (active_repo.*) |old_repo| alloc.free(old_repo);
    active_repo.* = alloc.dupe(u8, requested_repo) catch null;
    setThreadRepoPath(alloc, thread_ctx, requested_repo);

    cache.invalidate();
    cache.prefetch(alloc);
    tools.detectAndUpdateRepo(alloc);
}

// ── JSON-RPC 2.0 writers ──────────────────────────────────────────────────────
//
// Every write is exactly one JSON object followed by \\n.\n
fn writeResult(
    alloc: std.mem.Allocator,
    stdout: std.fs.File,
    id: ?std.json.Value,
    result: []const u8,
) void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    buf.appendSlice(alloc, "{\"jsonrpc\":\"2.0\",\"id\":") catch return writeStaticError(stdout);
    appendId(alloc, &buf, id);
    buf.appendSlice(alloc, ",\"result\":") catch return writeStaticError(stdout);
    for (result) |c| {
        if (c != '\n' and c != '\r') buf.append(alloc, c) catch return writeStaticError(stdout);
    }
    buf.appendSlice(alloc, "}") catch return writeStaticError(stdout);
    writePayload(stdout, buf.items) catch return;
}

fn writeError(
    alloc: std.mem.Allocator,
    stdout: std.fs.File,
    id: ?std.json.Value,
    code: i32,
    msg: []const u8,
) void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    buf.appendSlice(alloc, "{\"jsonrpc\":\"2.0\",\"id\":") catch return writeStaticError(stdout);
    appendId(alloc, &buf, id);
    buf.appendSlice(alloc, ",\"error\":{\"code\":") catch return writeStaticError(stdout);
    var tmp: [12]u8 = undefined;
    const cs = std.fmt.bufPrint(&tmp, "{d}", .{code}) catch return;
    buf.appendSlice(alloc, cs) catch return writeStaticError(stdout);
    buf.appendSlice(alloc, ",\"message\":\"") catch return writeStaticError(stdout);
    mj.writeEscaped(alloc, &buf, msg);
    buf.appendSlice(alloc, "\"}}") catch return writeStaticError(stdout);
    writePayload(stdout, buf.items) catch return;
}

/// Last-resort error when dynamic allocation fails. Uses a static buffer
/// so it never allocates. Ensures the client always gets *some* response.
fn writeStaticError(stdout: std.fs.File) void {
    const msg = "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32603,\"message\":\"Internal error: out of memory\"}}";
    writePayload(stdout, msg) catch {};
}

fn writePayload(stdout: std.fs.File, payload: []const u8) !void {
    if (g_use_headers) {
        const header = try std.fmt.allocPrint(std.heap.page_allocator, "Content-Length: {d}\r\n\r\n", .{payload.len});
        defer std.heap.page_allocator.free(header);
        try stdout.writeAll(header);
        try stdout.writeAll(payload);
        try stdout.writeAll("\r\n");
        return;
    }
    try stdout.writeAll(payload);
    try stdout.writeAll("\n");
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
            mj.writeEscaped(alloc, buf, s);
            buf.append(alloc, '"') catch return;
        },
        else => buf.appendSlice(alloc, "null") catch return,
    } else {
        buf.appendSlice(alloc, "null") catch return;
    }
}

fn resetThreadState(alloc: std.mem.Allocator) void {
    for (&g_thread_contexts) |*ctx| {
        if (ctx.repo_path) |old| alloc.free(old);
        ctx.* = .{};
    }
    g_thread_count = 0;
}

test "thread context keeps separate sessions by id" {
    const alloc = std.testing.allocator;
    resetThreadState(alloc);

    const a = getThreadContext("thread-a");
    const b = getThreadContext("thread-a");
    const c = getThreadContext("thread-b");

    try std.testing.expect(a == b);
    try std.testing.expect(a != c);
    try std.testing.expectEqualStrings("thread-a", a.id[0..a.id_len]);
    try std.testing.expectEqualStrings("thread-b", c.id[0..c.id_len]);
}

test "resolveThreadId reads params first, then args, then default" {
    const alloc = std.testing.allocator;

    var params = std.json.ObjectMap.init(alloc);
    defer params.deinit();
    var args = std.json.ObjectMap.init(alloc);
    defer args.deinit();

    try args.put("thread_id", .{ .string = "from-args" });
    try std.testing.expectEqualStrings("from-args", resolveThreadId(&params, &args));

    try params.put("threadId", .{ .string = "from-params-camel" });
    try std.testing.expectEqualStrings("from-params-camel", resolveThreadId(&params, &args));

    params.clearRetainingCapacity();
    try params.put("thread_id", .{ .string = "from-params-snake" });
    try std.testing.expectEqualStrings("from-params-snake", resolveThreadId(&params, &args));
}

test "normalizeThreadId rejects empty and oversized ids" {
    const long = [_]u8{ 'x' } ** (MaxThreadIdLen + 1);
    try std.testing.expectEqualStrings(DefaultThreadId, normalizeThreadId(""));
    try std.testing.expectEqualStrings(DefaultThreadId, normalizeThreadId(&long));
    try std.testing.expectEqualStrings("abc", normalizeThreadId("abc"));
}

test "resolveRepoFromArgs supports repo_path, repo, and working_directory" {
    const alloc = std.testing.allocator;

    var args = std.json.ObjectMap.init(alloc);
    defer args.deinit();
    var params = std.json.ObjectMap.init(alloc);
    defer params.deinit();

    try args.put("repo", "repo-a");
    try std.testing.expectEqualStrings("repo-a", resolveRepoFromArgs(&params, &args).?);

    args.clearRetainingCapacity();
    try args.put("repo_path", "repo-b");
    try std.testing.expectEqualStrings("repo-b", resolveRepoFromArgs(&params, &args).?);

    args.clearRetainingCapacity();
    try args.put("repo_path", "repo-b");
    try std.testing.expectEqualStrings("repo-b", resolveRepoFromArgs(&params, &args).?);

    args.clearRetainingCapacity();
    try args.put("working_directory", "repo-c");
    try std.testing.expectEqualStrings("repo-c", resolveRepoFromArgs(&params, &args).?);

    params.put("repo", "repo-p") catch return;
    try std.testing.expectEqualStrings("repo-p", resolveRepoFromArgs(&params, &args).?);
}

test "thread table full falls back to default thread context" {
    const alloc = std.testing.allocator;
    resetThreadState(alloc);
    defer resetThreadState(alloc);

    var buf: [32]u8 = undefined;
    for (0..MaxThreads) |i| {
        const name = std.fmt.bufPrint(&buf, "thread-{d}", .{i}) catch unreachable;
        _ = getThreadContext(name);
    }

    const overflow_thread = getThreadContext("overflow");
    try std.testing.expect(overflow_thread == defaultThreadContext());
}

test "protocol: readMessage accepts line-delimited JSON" {
    const alloc = std.testing.allocator;
    var fds = try std.posix.pipe();
    defer std.posix.close(fds[0]);
    defer std.posix.close(fds[1]);

    var writer = std.fs.File{ .handle = fds[1] };
    var reader = std.fs.File{ .handle = fds[0] };

    const payload = "{\"jsonrpc\":\"2.0\",\"method\":\"ping\"}\n";
    try writer.writeAll(payload);
    try writer.close();

    var uses_headers = false;
    const line = readMessage(alloc, reader, &uses_headers) orelse
        return error.TestExpectedRead;
    defer alloc.free(line);

    try std.testing.expect(!uses_headers);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"method\":\"ping\"}", line);
}

test "protocol: readMessage accepts header-framed JSON" {
    const alloc = std.testing.allocator;
    var fds = try std.posix.pipe();
    defer std.posix.close(fds[0]);
    defer std.posix.close(fds[1]);

    var writer = std.fs.File{ .handle = fds[1] };
    var reader = std.fs.File{ .handle = fds[0] };

    const body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{}}";
    const frame = try std.fmt.allocPrint(
        alloc,
        "Content-Length: {d}\r\n\r\n{s}",
        .{ body.len, body },
    );
    defer alloc.free(frame);
    try writer.writeAll(frame);
    try writer.close();

    var uses_headers = false;
    const read = readMessage(alloc, reader, &uses_headers) orelse
        return error.TestExpectedRead;
    defer alloc.free(read);

    try std.testing.expect(uses_headers);
    try std.testing.expectEqualStrings(body, read);
}

test "protocol: parseHeaderLen accepts uppercase/lowercase header names" {
    var length: ?usize = null;
    parseHeaderLen("Content-Length:  42  ", &length);
    try std.testing.expectEqual(@as(?usize, 42), length);

    length = null;
    parseHeaderLen("content-length: 13", &length);
    try std.testing.expectEqual(@as(?usize, 13), length);
}

test "protocol: writePayload emits selected framing mode" {
    const alloc = std.testing.allocator;
    const old_mode = g_use_headers;
    defer g_use_headers = old_mode;

    const payload = "hello";

    {
        var fds = try std.posix.pipe();
        defer std.posix.close(fds[0]);
        defer std.posix.close(fds[1]);

        var writer = std.fs.File{ .handle = fds[1] };
        var reader = std.fs.File{ .handle = fds[0] };

        g_use_headers = false;
        try writePayload(writer, payload);
        try writer.close();

        var got = std.ArrayList(u8).empty;
        defer got.deinit(alloc);
        var buf: [128]u8 = undefined;
        while (true) {
            const n = try reader.read(&buf);
            if (n == 0) break;
            try got.appendSlice(alloc, buf[0..n]);
        }
        try std.testing.expect(std.mem.endsWith(u8, got.items, "\n"));
        try std.testing.expect(std.mem.startsWith(u8, got.items, payload));
    }

    {
        var fds = try std.posix.pipe();
        defer std.posix.close(fds[0]);
        defer std.posix.close(fds[1]);

        var writer = std.fs.File{ .handle = fds[1] };
        var reader = std.fs.File{ .handle = fds[0] };

        g_use_headers = true;
        try writePayload(writer, payload);
        try writer.close();

        var got = std.ArrayList(u8).empty;
        defer got.deinit(alloc);
        var buf: [128]u8 = undefined;
        while (true) {
            const n = try reader.read(&buf);
            if (n == 0) break;
            try got.appendSlice(alloc, buf[0..n]);
        }
        try std.testing.expect(std.mem.startsWith(u8, got.items, "Content-Length: 5\r\n\r\n"));
        try std.testing.expect(std.mem.endsWith(u8, got.items, "\r\n"));
        try std.testing.expect(std.mem.containsAtLeast(u8, got.items, 1, payload));
    }
}
