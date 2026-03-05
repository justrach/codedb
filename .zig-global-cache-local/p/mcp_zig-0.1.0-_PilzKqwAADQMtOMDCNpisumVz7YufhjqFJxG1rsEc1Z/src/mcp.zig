// mcp-zig — MCP server (Model Context Protocol, JSON-RPC 2.0 over stdio)
//
// Protocol: newline-delimited JSON. NO Content-Length headers (unlike LSP).
// Claude Code's ReadBuffer parses one JSON object per line — a single \n
// inside a result would be interpreted as a new (invalid) request.
//
// The critical invariant: every write to stdout is exactly one JSON object
// followed by exactly one \n. `writeResult` enforces this by stripping \n
// from result strings before embedding them.
//
// Lifecycle:
//   1. Claude Code spawns this process with `--mcp` (or however you route it)
//   2. Sends {"jsonrpc":"2.0","id":1,"method":"initialize",...}
//   3. Sends {"jsonrpc":"2.0","method":"notifications/initialized"} (no id)
//   4. Sends tools/list, tools/call as needed
//   5. Process exits when stdin closes

const std = @import("std");
const json = @import("json.zig");
const tools = @import("tools.zig");

pub fn run(alloc: std.mem.Allocator) void {
    const stdout = std.fs.File.stdout();
    const stdin  = std.fs.File.stdin();

    while (true) {
        const line = json.readLine(alloc, stdin) orelse break;
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
        const method = json.getStr(root, "method") orelse {
            writeError(alloc, stdout, null, -32600, "Missing method");
            continue;
        };
        const id = root.get("id"); // null for notifications

        if (json.eql(method, "initialize")) {
            handleInitialize(alloc, stdout, id);
        } else if (json.eql(method, "notifications/initialized")) {
            // notification — no response
        } else if (json.eql(method, "tools/list")) {
            writeResult(alloc, stdout, id, tools.tools_list);
        } else if (json.eql(method, "tools/call")) {
            handleCall(alloc, root, stdout, id);
        } else if (json.eql(method, "ping")) {
            writeResult(alloc, stdout, id, "{}");
        } else {
            if (id != null) writeError(alloc, stdout, id, -32601, "Method not found");
        }
    }
}

// ── initialize ─────────────────────────────────────────────────────────────
//
// Respond with protocol version + server capabilities.
// Change "name" and "version" to match your server.

fn handleInitialize(alloc: std.mem.Allocator, stdout: std.fs.File, id: ?std.json.Value) void {
    writeResult(alloc, stdout, id,
        \\{"protocolVersion":"2025-03-26","capabilities":{"tools":{"listChanged":false}},"serverInfo":{"name":"mcp-zig","version":"1.0.0"}}
    );
}

// ── tools/call ────────────────────────────────────────────────────────────

fn handleCall(
    alloc: std.mem.Allocator,
    root: *const std.json.ObjectMap,
    stdout: std.fs.File,
    id: ?std.json.Value,
) void {
    // Unwrap params
    const params_val = root.get("params") orelse {
        writeError(alloc, stdout, id, -32602, "Missing params"); return;
    };
    if (params_val != .object) {
        writeError(alloc, stdout, id, -32602, "params must be object"); return;
    }
    const params = &params_val.object;

    // Tool name
    const name = json.getStr(params, "name") orelse {
        writeError(alloc, stdout, id, -32602, "Missing tool name"); return;
    };

    // Arguments
    const args_val = params.get("arguments") orelse {
        writeError(alloc, stdout, id, -32602, "Missing arguments"); return;
    };
    if (args_val != .object) {
        writeError(alloc, stdout, id, -32602, "arguments must be object"); return;
    }
    const args = &args_val.object;

    // Dispatch
    const tool = tools.parse(name) orelse {
        writeError(alloc, stdout, id, -32602, "Unknown tool"); return;
    };

    // Run handler → capture output → wrap in MCP content envelope
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    tools.dispatch(alloc, tool, args, &out);

    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(alloc);
    result.appendSlice(alloc, "{\"content\":[{\"type\":\"text\",\"text\":\"") catch return;
    json.writeEscaped(alloc, &result, out.items);
    result.appendSlice(alloc, "\"}],\"isError\":false}") catch return;

    writeResult(alloc, stdout, id, result.items);
}

// ── JSON-RPC 2.0 response writers ──────────────────────────────────────────────

/// Write a JSON-RPC 2.0 result response.
/// IMPORTANT: strips \n and \r from `result` before writing.
/// Zig \\ multiline string literals embed literal newlines; those would break
/// Claude Code's line-delimited ReadBuffer (each line = one JSON-RPC message).
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

    _ = stdout.write(buf.items) catch 0;
}

/// Write a JSON-RPC 2.0 error response.
fn writeError(
    alloc: std.mem.Allocator,
    stdout: std.fs.File,
    id: ?std.json.Value,
    code: i32,
    msg: []const u8,
) void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    buf.appendSlice(alloc, "{\"jsonrpc\":\"2.0\",\"id\":") catch return;
    appendId(alloc, &buf, id);
    buf.appendSlice(alloc, ",\"error\":{\"code\":") catch return;
    var tmp: [12]u8 = undefined;
    const cs = std.fmt.bufPrint(&tmp, "{d}", .{code}) catch return;
    buf.appendSlice(alloc, cs) catch return;
    buf.appendSlice(alloc, ",\"message\":\"") catch return;
    json.writeEscaped(alloc, &buf, msg);
    buf.appendSlice(alloc, "\"}}\n") catch return;

    _ = stdout.write(buf.items) catch 0;
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
            json.writeEscaped(alloc, buf, s);
            buf.append(alloc, '"') catch return;
        },
        else => buf.appendSlice(alloc, "null") catch return,
    } else {
        buf.appendSlice(alloc, "null") catch return;
    }
}
