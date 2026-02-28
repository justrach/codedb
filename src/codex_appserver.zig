// codex_appserver.zig — Codex app-server JSON-RPC 2.0 client
//
// Spawns `codex app-server`, performs the initialize/thread/turn handshake,
// streams `item/agentMessage/delta` notifications into `out`, and returns
// when `turn/completed` is received.
//
// Protocol: https://github.com/openai/codex/tree/main/codex-rs/app-server
// Wire format: newline-delimited JSON, `"jsonrpc":"2.0"` header omitted.

const std = @import("std");
const mj  = @import("mcp").json;

/// Run a single agent turn via `codex app-server`.
/// Blocks until `turn/completed`. Accumulated agent reply is appended to `out`.
pub fn runTurn(
    alloc:  std.mem.Allocator,
    prompt: []const u8,
    out:    *std.ArrayList(u8),
) void {
    const cwd = std.process.getCwdAlloc(alloc) catch {
        appendErr(alloc, out, "could not get cwd");
        return;
    };
    defer alloc.free(cwd);

    var child = std.process.Child.init(&.{"codex", "app-server"}, alloc);
    child.stdin_behavior  = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Close;
    child.spawn() catch {
        appendErr(alloc, out, "could not spawn codex app-server — is codex installed and on PATH?");
        return;
    };
    defer _ = child.wait()  catch {};
    defer _ = child.kill()  catch {};

    const proc_in  = child.stdin  orelse { appendErr(alloc, out, "no stdin pipe");  return; };
    const proc_out = child.stdout orelse { appendErr(alloc, out, "no stdout pipe"); return; };

    // ── 1. initialize ──────────────────────────────────────────────────────
    writeMsg(proc_in,
        \\{"method":"initialize","id":0,"params":{"clientInfo":{"name":"gitagent","title":"gitagent-mcp","version":"0.1.0"}}}
    ) catch { appendErr(alloc, out, "write initialize failed"); return; };

    if (!drainUntilId(alloc, proc_out, 0)) {
        appendErr(alloc, out, "no response to initialize from codex app-server");
        return;
    }

    // ── 2. initialized notification ────────────────────────────────────────
    writeMsg(proc_in,
        \\{"method":"initialized","params":{}}
    ) catch { appendErr(alloc, out, "write initialized failed"); return; };

    // ── 3. thread/start ────────────────────────────────────────────────────
    {
        var msg: std.ArrayList(u8) = .empty;
        defer msg.deinit(alloc);
        msg.appendSlice(alloc,
            \\{"method":"thread/start","id":1,"params":{"approvalPolicy":"never","sandboxPolicy":{"type":"readOnly"},"cwd":"
        ) catch return;
        mj.writeEscaped(alloc, &msg, cwd);
        msg.appendSlice(alloc, "\"}}") catch return;
        writeMsgSlice(proc_in, msg.items) catch { appendErr(alloc, out, "write thread/start failed"); return; };
    }

    const thread_id = readThreadId(alloc, proc_out) orelse {
        appendErr(alloc, out, "thread/start: missing threadId in response");
        return;
    };
    defer alloc.free(thread_id);

    // ── 4. turn/start ──────────────────────────────────────────────────────
    {
        var msg: std.ArrayList(u8) = .empty;
        defer msg.deinit(alloc);
        msg.appendSlice(alloc,
            \\{"method":"turn/start","id":2,"params":{"threadId":"
        ) catch return;
        mj.writeEscaped(alloc, &msg, thread_id);
        msg.appendSlice(alloc, "\",\"input\":[{\"type\":\"text\",\"text\":\"") catch return;
        mj.writeEscaped(alloc, &msg, prompt);
        msg.appendSlice(alloc, "\"}]}}") catch return;
        writeMsgSlice(proc_in, msg.items) catch { appendErr(alloc, out, "write turn/start failed"); return; };
    }

    // ── 5. Stream until turn/completed ────────────────────────────────────
    streamTurn(alloc, proc_out, out);
}

// ── Wire helpers ──────────────────────────────────────────────────────────────

fn writeMsg(file: std.fs.File, comptime s: []const u8) !void {
    try file.writeAll(s ++ "\n");
}

fn writeMsgSlice(file: std.fs.File, s: []const u8) !void {
    try file.writeAll(s);
    try file.writeAll("\n");
}

/// Read one newline-delimited line from a File. Returns owned slice; caller frees.
/// Mirrors mcp-zig json.readLine — byte-by-byte, works on Zig 0.15.
fn readLineAlloc(alloc: std.mem.Allocator, file: std.fs.File) ?[]u8 {
    var buf: [1]u8 = undefined;
    var line: std.ArrayList(u8) = .empty;
    while (true) {
        const n = file.read(&buf) catch { line.deinit(alloc); return null; };
        if (n == 0) {
            if (line.items.len == 0) { line.deinit(alloc); return null; }
            return line.toOwnedSlice(alloc) catch null;
        }
        if (buf[0] == '\n') return line.toOwnedSlice(alloc) catch null;
        line.append(alloc, buf[0]) catch { line.deinit(alloc); return null; };
        if (line.items.len > 4 * 1024 * 1024) { line.deinit(alloc); return null; }
    }
}

// ── Protocol helpers ──────────────────────────────────────────────────────────

/// Discard lines until a JSON-RPC response with `id == target_id` arrives.
fn drainUntilId(alloc: std.mem.Allocator, rd: anytype, target_id: i64) bool {
    while (true) {
        const line = readLineAlloc(alloc, rd) orelse return false;
        defer alloc.free(line);
        const p = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch continue;
        defer p.deinit();
        if (p.value != .object) continue;
        const id_v = p.value.object.get("id") orelse continue;
        const id: i64 = switch (id_v) { .integer => |n| n, else => continue };
        if (id == target_id) return true;
    }
}

/// Read lines until the `id:1` (thread/start) response arrives.
/// Returns an owned copy of `result.thread.id`, or null on failure.
fn readThreadId(alloc: std.mem.Allocator, rd: anytype) ?[]u8 {
    while (true) {
        const line = readLineAlloc(alloc, rd) orelse return null;
        defer alloc.free(line);
        const p = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch continue;
        defer p.deinit();
        if (p.value != .object) continue;
        const obj = &p.value.object;
        // Must be a response (has "id") to request 1.
        const id_v = obj.get("id") orelse continue;
        const id: i64 = switch (id_v) { .integer => |n| n, else => continue };
        if (id != 1) continue;
        // Navigate result.thread.id
        const result = obj.get("result")         orelse continue;
        if (result != .object) continue;
        const thread = result.object.get("thread") orelse continue;
        if (thread != .object) continue;
        const tid    = thread.object.get("id")     orelse continue;
        if (tid != .string) continue;
        return alloc.dupe(u8, tid.string) catch null;
    }
}

/// Read notifications until `turn/completed`. Append `item/agentMessage/delta`
/// text to `out`. On failure, append an error JSON object.
fn streamTurn(alloc: std.mem.Allocator, rd: anytype, out: *std.ArrayList(u8)) void {
    while (true) {
        const line = readLineAlloc(alloc, rd) orelse return;
        defer alloc.free(line);
        const p = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch continue;
        defer p.deinit();
        if (p.value != .object) continue;
        const obj = &p.value.object;

        const method_v = obj.get("method") orelse continue;
        if (method_v != .string) continue;
        const method = method_v.string;

        if (std.mem.eql(u8, method, "item/agentMessage/delta")) {
            // params.delta contains the streamed text chunk.
            const params = obj.get("params") orelse continue;
            if (params != .object) continue;
            const delta = params.object.get("delta") orelse continue;
            if (delta == .string) out.appendSlice(alloc, delta.string) catch {};
            continue;
        }

        if (std.mem.eql(u8, method, "turn/completed")) {
            // Check for failure and surface error message.
            const params = obj.get("params") orelse return;
            if (params != .object) return;
            const turn   = params.object.get("turn")   orelse return;
            if (turn != .object) return;
            const status = turn.object.get("status")   orelse return;
            if (status == .string and std.mem.eql(u8, status.string, "failed")) {
                if (turn.object.get("error")) |err_v| {
                    if (err_v == .object) {
                        if (err_v.object.get("message")) |msg_v| {
                            if (msg_v == .string) appendErr(alloc, out, msg_v.string);
                        }
                    }
                }
            }
            return;
        }
    }
}

// ── Error helper ──────────────────────────────────────────────────────────────

fn appendErr(alloc: std.mem.Allocator, out: *std.ArrayList(u8), msg: []const u8) void {
    out.appendSlice(alloc, "{\"error\":\"") catch return;
    mj.writeEscaped(alloc, out, msg);
    out.appendSlice(alloc, "\"}") catch {};
}
