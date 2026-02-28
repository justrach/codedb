// gitagent-mcp — MCP server (JSON-RPC 2.0 over stdio)
//
// Protocol: newline-delimited JSON. One object per line — never embed \n in output.
// Lifecycle: initialize → notifications/initialized → tools/list + tools/call loop.
//
// Register in ~/.claude.json:
//   "mcpServers": {
//     "gitagent": {
//       "command": "/path/to/gitagent-mcp",
//       "args": [],
//       "env": { "REPO_PATH": "/path/to/your/repo" }
//     }
//   }

const std   = @import("std");
const mj    = @import("mcp").json; // readLine, getStr/Int/Bool, eql, writeEscaped
const tools = @import("tools.zig");
const cache = @import("cache.zig");

pub fn main() void {
    // Ignore SIGPIPE so broken-pipe writes return error.BrokenPipe
    // instead of killing the server process.
    const act = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.PIPE, &act, null);

    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // chdir to REPO_PATH so all git/gh subprocesses operate on the right repo.
    const repo_path = std.process.getEnvVarOwned(alloc, "REPO_PATH") catch null;
    if (repo_path) |path| {
        defer alloc.free(path);
        std.posix.chdir(path) catch |err| {
            std.debug.print("[gitagent] warning: chdir({s}) failed: {}\n", .{ path, err });
        };
    }

    run(alloc);
}

fn run(alloc: std.mem.Allocator) void {
    const stdout = std.fs.File.stdout();
    const stdin  = std.fs.File.stdin();

    while (true) {
        const line = mj.readLine(alloc, stdin) orelse break;
        defer alloc.free(line);

        const input = std.mem.trim(u8, line, " \t\r");
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

        const root   = &parsed.value.object;
        const method = mj.getStr(root, "method") orelse {
            writeError(alloc, stdout, null, -32600, "Missing method");
            continue;
        };
        const id = root.get("id");

        if (mj.eql(method, "initialize")) {
            handleInitialize(alloc, stdout, id);
        } else if (mj.eql(method, "notifications/initialized")) {
            // Warm the session cache now that the client is ready.
            // Runs gh label list + milestones — 2 calls, <500ms.
            cache.prefetch(alloc);
        } else if (mj.eql(method, "tools/list")) {
            writeResult(alloc, stdout, id, tools.tools_list);
        } else if (mj.eql(method, "tools/call")) {
            handleCall(alloc, root, stdout, id);
        } else if (mj.eql(method, "ping")) {
            writeResult(alloc, stdout, id, "{}");
        } else {
            // Notifications (no id) are silently ignored.
            if (id != null) writeError(alloc, stdout, id, -32601, "Method not found");
        }
    }
}

// ── initialize ────────────────────────────────────────────────────────────────

fn handleInitialize(alloc: std.mem.Allocator, stdout: std.fs.File, id: ?std.json.Value) void {
    writeResult(alloc, stdout, id,
        \\{"protocolVersion":"2025-03-26","capabilities":{"tools":{"listChanged":false}},"serverInfo":{"name":"gitagent-mcp","version":"0.1.0"}}
    );
}

// ── tools/call ────────────────────────────────────────────────────────────────

fn handleCall(
    alloc: std.mem.Allocator,
    root: *const std.json.ObjectMap,
    stdout: std.fs.File,
    id: ?std.json.Value,
) void {
    const params_val = root.get("params") orelse {
        writeError(alloc, stdout, id, -32602, "Missing params");
        return;
    };
    if (params_val != .object) {
        writeError(alloc, stdout, id, -32602, "params must be object");
        return;
    }
    const params = &params_val.object;

    const name = mj.getStr(params, "name") orelse {
        writeError(alloc, stdout, id, -32602, "Missing tool name");
        return;
    };

    // arguments is required per MCP spec; tools with no params receive {}
    const args_val = params.get("arguments") orelse {
        writeError(alloc, stdout, id, -32602, "Missing arguments");
        return;
    };
    if (args_val != .object) {
        writeError(alloc, stdout, id, -32602, "arguments must be object");
        return;
    }
    const args = &args_val.object;

    const tool = tools.parse(name) orelse {
        writeError(alloc, stdout, id, -32602, "Unknown tool");
        return;
    };

    // Dispatch → handler writes plain text/JSON to `out`
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    tools.dispatch(alloc, tool, args, &out);

    // Wrap in MCP content envelope
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(alloc);
    result.appendSlice(alloc, "{\"content\":[{\"type\":\"text\",\"text\":\"") catch {
        writeError(alloc, stdout, id, -32603, "Internal error: out of memory");
        return;
    };
    mj.writeEscaped(alloc, &result, out.items);
    result.appendSlice(alloc, "\"}],\"isError\":false}") catch {
        writeError(alloc, stdout, id, -32603, "Internal error: out of memory");
        return;
    };

    writeResult(alloc, stdout, id, result.items);
}

// ── JSON-RPC 2.0 writers ──────────────────────────────────────────────────────
//
// Every write is exactly one JSON object followed by \n.
// writeResult strips \n/\r from result to satisfy the line-delimited protocol.

fn writeResult(
    alloc: std.mem.Allocator,
    stdout: std.fs.File,
    id: ?std.json.Value,
    result: []const u8,
) void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    buf.appendSlice(alloc, "{\"jsonrpc\":\"2.0\",\"id\":") catch return;
    appendId(alloc, &buf, id);
    buf.appendSlice(alloc, ",\"result\":") catch return;
    for (result) |c| {
        if (c != '\n' and c != '\r') buf.append(alloc, c) catch return;
    }
    buf.appendSlice(alloc, "}\n") catch return;
    stdout.writeAll(buf.items) catch {};
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
    buf.appendSlice(alloc, "\"}}\n") catch return writeStaticError(stdout);
    stdout.writeAll(buf.items) catch {};
}

/// Last-resort error when dynamic allocation fails. Uses a static buffer
/// so it never allocates. Ensures the client always gets *some* response.
fn writeStaticError(stdout: std.fs.File) void {
    const msg = "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32603,\"message\":\"Internal error: out of memory\"}}\n";
    stdout.writeAll(msg) catch {};
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

test {
    _ = @import("graph/types.zig");
    _ = @import("graph/graph.zig");
    _ = @import("graph/edge_weights.zig");
    _ = @import("graph/ppr.zig");
    _ = @import("graph/storage.zig");
    _ = @import("graph/wal.zig");
    _ = @import("graph/hot_cache.zig");
    _ = @import("graph/query.zig");
    _ = @import("graph/ipc.zig");
    _ = @import("graph/harness.zig");
    _ = @import("graph/ingest.zig");
    _ = @import("auth.zig");
    _ = @import("rate_limit.zig");
    _ = @import("graph/tier_manager.zig");
    _ = @import("graph/tenant.zig");
    _ = @import("graph/watcher.zig");
}
