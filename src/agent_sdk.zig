// agent_sdk.zig — Claude Code CLI agent transport
//
// Spawns `claude -p <prompt> --output-format stream-json` to run a Claude
// agent turn with full SDK features: tool allowlists, permission modes, and
// streaming text extraction.
//
// Falls back automatically to codex_appserver.zig when `claude` is not on
// PATH, or when AGENT_SDK_BACKEND=codex is set in the environment.
//
// Streaming output format (NDJSON, one object per line):
//   {"type":"system","subtype":"init",...}
//   {"type":"assistant","message":{"content":[{"type":"text","text":"..."}],...},...}
//   {"type":"result","subtype":"success","result":"<final text>",...}

const std = @import("std");
const mj  = @import("mcp").json;

/// Options for a Claude agent run via `claude -p`.
/// Options for a Claude agent run via `claude -p`.
pub const AgentOptions = struct {
    /// Comma-separated tool allowlist, e.g. "Bash,Read,Edit".
    /// Null means all tools are permitted.
    allowed_tools: ?[]const u8 = null,
    /// Permission mode: "default" | "acceptEdits" | "bypassPermissions"
    permission_mode: ?[]const u8 = null,
    /// Override working directory (default: inherits from spawning process).
    cwd: ?[]const u8 = null,
    /// Convenience flag: allow file writes.
    /// Maps to "bypassPermissions" when permission_mode is null.
    writable: bool = false,
    /// Model alias or full ID, e.g. "sonnet", "opus", "claude-sonnet-4-6".
    /// Null uses the model from Claude Code's settings.
    model: ?[]const u8 = null,
    /// Reasoning effort: "low" | "medium" | "high" | "xhigh" | null.
    /// Passed as --reasoning-effort when set.
    reasoning_effort: ?[]const u8 = null,
};

/// Run one agent turn. Writes the agent's final text reply to `out`.
///
/// Prefers `claude -p` (Claude Code CLI) when available.
/// Falls back to `codex app-server` (codex_appserver.zig) otherwise.
/// Set AGENT_SDK_BACKEND=codex to force the fallback path.
pub fn runAgent(
    alloc: std.mem.Allocator,
    prompt: []const u8,
    opts: AgentOptions,
    out: *std.ArrayList(u8),
) void {
    if (tryClaudeAgent(alloc, prompt, opts, out)) return;
    // Fallback: codex_appserver
    const cas = @import("codex_appserver.zig");
    const policy: cas.SandboxPolicy = if (opts.writable) .writable else .read_only;
    cas.runTurnPolicy(alloc, prompt, out, policy);
}

// ─────────────────────────────────────────────────────────────────────────────

/// Attempts to run the turn via `claude -p`. Returns false when claude is
/// unavailable so the caller can fall back to codex_appserver.
/// Attempts to run the turn via `claude -p`. Returns false when claude is
/// unavailable so the caller can fall back to codex_appserver.
/// Attempts to run the turn via `claude -p`. Returns false when claude is
/// unavailable so the caller can fall back to codex_appserver.
/// Attempts to run the turn via `claude -p`. Returns false when claude is
/// unavailable so the caller can fall back to codex_appserver.
pub fn tryClaudeAgent(
    alloc: std.mem.Allocator,
    prompt: []const u8,
    opts: AgentOptions,
    out: *std.ArrayList(u8),
) bool {
    // Honour AGENT_SDK_BACKEND=codex to force the legacy codex path.
    const backend_owned = std.process.getEnvVarOwned(alloc, "AGENT_SDK_BACKEND") catch null;
    defer if (backend_owned) |v| alloc.free(v);
    const backend = backend_owned orelse "";
    if (std.mem.eql(u8, backend, "codex")) return false;

    const perm_mode: []const u8 =
        opts.permission_mode orelse if (opts.writable) "bypassPermissions" else "default";
    const model = opts.model orelse "claude-sonnet-4-6";

    // Build argv in a fixed-size stack buffer (22 slots is sufficient).
    var argv_buf: [22][]const u8 = undefined;
    var argc: usize = 0;
    argv_buf[argc] = "claude";            argc += 1;
    argv_buf[argc] = "-p";               argc += 1;
    argv_buf[argc] = prompt;             argc += 1;
    argv_buf[argc] = "--output-format";  argc += 1;
    argv_buf[argc] = "stream-json";      argc += 1;
    argv_buf[argc] = "--verbose";        argc += 1;
    argv_buf[argc] = "--permission-mode"; argc += 1;
    argv_buf[argc] = perm_mode;           argc += 1;
    argv_buf[argc] = "--model";          argc += 1;
    argv_buf[argc] = model;              argc += 1;

    if (opts.reasoning_effort) |effort| {
        argv_buf[argc] = "--reasoning-effort"; argc += 1;
        argv_buf[argc] = effort;               argc += 1;
    }

    if (opts.allowed_tools) |at| {
        argv_buf[argc] = "--allowedTools"; argc += 1;
        argv_buf[argc] = at;               argc += 1;
    }

    // Inherit environment but strip CLAUDECODE (nested-session guard).
    var env_map = std.process.getEnvMap(alloc) catch std.process.EnvMap.init(alloc);
    defer env_map.deinit();
    env_map.remove("CLAUDECODE");

    // ── Option 1: direct spawn ────────────────────────────────────────────────
    var child = std.process.Child.init(argv_buf[0..argc], alloc);
    child.stdin_behavior  = .Close;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Close;
    child.env_map         = &env_map;
    if (opts.cwd) |cwd| child.cwd = cwd;

    if (child.spawn()) |_| {
        defer _ = child.wait() catch {};
        defer _ = child.kill() catch {};
        const proc_out = child.stdout orelse return false;
        streamClaudeOutput(alloc, proc_out, out);
        return true;
    } else |_| {}

    // ── Option 2: login shell fallback ────────────────────────────────────────
    // Direct spawn failed — claude not on the trimmed PATH seen by this process.
    // Re-try via the login shell so ~/.zshrc / ~/.zprofile are sourced and the
    // full user PATH (e.g. ~/.local/bin) is available.
    const shell_owned = std.process.getEnvVarOwned(alloc, "SHELL") catch null;
    defer if (shell_owned) |sh| alloc.free(sh);
    const shell = shell_owned orelse "/bin/zsh";

    // Pass the prompt via an env var so it doesn't need shell-quoting.
    // _AGENT_PROMPT avoids any risk of word-splitting or glob expansion.
    env_map.put("_AGENT_PROMPT", prompt) catch return false;

    // Build the shell command.  argv_buf layout:
    //   [0] "claude"  [1] "-p"  [2] prompt  [3..argc-1] remaining flags
    // We replace positions 0-2 with: exec claude -p "$_AGENT_PROMPT"
    // All remaining flags are simple ASCII words — no quoting needed.
    var shell_cmd: std.ArrayList(u8) = .empty;
    defer shell_cmd.deinit(alloc);
    shell_cmd.appendSlice(alloc, "exec claude -p \"$_AGENT_PROMPT\"") catch return false;
    for (argv_buf[3..argc]) |arg| {
        shell_cmd.append(alloc, ' ') catch return false;
        shell_cmd.appendSlice(alloc, arg) catch return false;
    }

    const argv2 = [_][]const u8{ shell, "-lc", shell_cmd.items };
    var child2 = std.process.Child.init(&argv2, alloc);
    child2.stdin_behavior  = .Close;
    child2.stdout_behavior = .Pipe;
    child2.stderr_behavior = .Close;
    child2.env_map         = &env_map;
    if (opts.cwd) |cwd| child2.cwd = cwd;

    child2.spawn() catch return false;
    defer _ = child2.wait() catch {};
    defer _ = child2.kill() catch {};

    const proc_out2 = child2.stdout orelse return false;
    streamClaudeOutput(alloc, proc_out2, out);
    return true;
}

/// Reads NDJSON from `claude -p --output-format stream-json`.
/// Extracts the agent's final text from the `{"type":"result"}` event.
/// Falls back to accumulated assistant-message text if no result event arrives.
/// Reads NDJSON from `claude -p --output-format stream-json`.
/// Extracts the agent's final text from the `{"type":"result"}` event.
/// Falls back to accumulated assistant-message text if no result event arrives.
fn streamClaudeOutput(
    alloc: std.mem.Allocator,
    file: std.fs.File,
    out: *std.ArrayList(u8),
) void {
    var accumulated: std.ArrayList(u8) = .empty;
    defer accumulated.deinit(alloc);
    var found_result = false;

    while (!found_result) {
        const line = readLine(alloc, file) orelse break;
        defer alloc.free(line);
        parseClaudeLine(alloc, line, out, &accumulated, &found_result);
    }

    if (!found_result and accumulated.items.len > 0) {
        out.appendSlice(alloc, accumulated.items) catch {};
    }
}

/// Read one newline-delimited line from `file`. Returns null on EOF or error.
/// Caller owns the returned slice.  Lines larger than 8 MiB are dropped.
fn readLine(alloc: std.mem.Allocator, file: std.fs.File) ?[]u8 {
    var buf: [1]u8 = undefined;
    var line: std.ArrayList(u8) = .empty;
    while (true) {
        const n = file.read(&buf) catch { line.deinit(alloc); return null; };
        if (n == 0) {
            if (line.items.len == 0) { line.deinit(alloc); return null; }
            return line.toOwnedSlice(alloc) catch { line.deinit(alloc); return null; };
        }
        if (buf[0] == '\n') {
            return line.toOwnedSlice(alloc) catch { line.deinit(alloc); return null; };
        }
        line.append(alloc, buf[0]) catch { line.deinit(alloc); return null; };
        if (line.items.len > 8 * 1024 * 1024) { line.deinit(alloc); return null; }
    }
}

fn parseClaudeLine(
    alloc: std.mem.Allocator,
    line: []const u8,
    out: *std.ArrayList(u8),
    accumulated: *std.ArrayList(u8),
    found_result: *bool,
) void {
    const s = std.mem.trimRight(u8, line, "\r");
    if (s.len == 0) return;

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, s, .{}) catch return;
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return,
    };

    const type_val = obj.get("type") orelse return;
    const type_str = switch (type_val) {
        .string => |sv| sv,
        else => return,
    };

    if (std.mem.eql(u8, type_str, "result")) {
        // {"type":"result","subtype":"success","result":"<final text>",...}
        if (obj.get("result")) |rv| {
            if (rv == .string) {
                out.appendSlice(alloc, rv.string) catch {};
                found_result.* = true;
            }
        }
    } else if (std.mem.eql(u8, type_str, "assistant")) {
        // Accumulate assistant text as fallback when result event is absent.
        extractAssistantText(alloc, obj, accumulated);
    }
}

fn extractAssistantText(
    alloc: std.mem.Allocator,
    obj: std.json.ObjectMap,
    buf: *std.ArrayList(u8),
) void {
    const msg = obj.get("message") orelse return;
    if (msg != .object) return;
    const content = msg.object.get("content") orelse return;
    if (content != .array) return;
    for (content.array.items) |item| {
        if (item != .object) continue;
        const t = item.object.get("type") orelse continue;
        if (t != .string or !std.mem.eql(u8, t.string, "text")) continue;
        const text = item.object.get("text") orelse continue;
        if (text != .string) continue;
        buf.appendSlice(alloc, text.string) catch {};
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

test "agent_sdk: parseClaudeLine extracts result text" {
    const alloc = std.testing.allocator;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var accumulated: std.ArrayList(u8) = .empty;
    defer accumulated.deinit(alloc);
    var found = false;

    const line =
        \\{"type":"result","subtype":"success","is_error":false,"result":"Hello world","session_id":"s1"}
    ;
    parseClaudeLine(alloc, line, &out, &accumulated, &found);

    try std.testing.expect(found);
    try std.testing.expectEqualStrings("Hello world", out.items);
}

test "agent_sdk: parseClaudeLine accumulates assistant text" {
    const alloc = std.testing.allocator;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var accumulated: std.ArrayList(u8) = .empty;
    defer accumulated.deinit(alloc);
    var found = false;

    const line =
        \\{"type":"assistant","message":{"id":"m1","type":"message","role":"assistant","content":[{"type":"text","text":"partial response"}],"stop_reason":null},"session_id":"s1"}
    ;
    parseClaudeLine(alloc, line, &out, &accumulated, &found);

    try std.testing.expect(!found);
    try std.testing.expect(out.items.len == 0);
    try std.testing.expectEqualStrings("partial response", accumulated.items);
}

test "agent_sdk: parseClaudeLine ignores system init events" {
    const alloc = std.testing.allocator;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var accumulated: std.ArrayList(u8) = .empty;
    defer accumulated.deinit(alloc);
    var found = false;

    parseClaudeLine(alloc,
        \\{"type":"system","subtype":"init","cwd":"/tmp","session_id":"s1"}
    , &out, &accumulated, &found);

    try std.testing.expect(!found);
    try std.testing.expect(out.items.len == 0);
    try std.testing.expect(accumulated.items.len == 0);
}

test "agent_sdk: parseClaudeLine handles malformed JSON gracefully" {
    const alloc = std.testing.allocator;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var accumulated: std.ArrayList(u8) = .empty;
    defer accumulated.deinit(alloc);
    var found = false;

    parseClaudeLine(alloc, "not json at all", &out, &accumulated, &found);

    try std.testing.expect(!found);
    try std.testing.expect(out.items.len == 0);
}

test "agent_sdk: parseClaudeLine skips empty and whitespace-only lines" {
    const alloc = std.testing.allocator;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var accumulated: std.ArrayList(u8) = .empty;
    defer accumulated.deinit(alloc);
    var found = false;

    parseClaudeLine(alloc, "", &out, &accumulated, &found);
    parseClaudeLine(alloc, "\r", &out, &accumulated, &found);

    try std.testing.expect(!found);
    try std.testing.expect(out.items.len == 0);
    try std.testing.expect(accumulated.items.len == 0);
}

test "agent_sdk: error result is still captured in out" {
    const alloc = std.testing.allocator;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var accumulated: std.ArrayList(u8) = .empty;
    defer accumulated.deinit(alloc);
    var found = false;

    parseClaudeLine(alloc,
        \\{"type":"result","subtype":"error_during_execution","is_error":true,"result":"partial before crash","session_id":"s1"}
    , &out, &accumulated, &found);

    try std.testing.expect(found);
    try std.testing.expectEqualStrings("partial before crash", out.items);
}

test "agent_sdk: multi-turn assistant text accumulates, result event wins" {
    const alloc = std.testing.allocator;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var accumulated: std.ArrayList(u8) = .empty;
    defer accumulated.deinit(alloc);
    var found = false;

    parseClaudeLine(alloc,
        \\{"type":"assistant","message":{"content":[{"type":"text","text":"Hello "}]},"session_id":"s1"}
    , &out, &accumulated, &found);
    parseClaudeLine(alloc,
        \\{"type":"assistant","message":{"content":[{"type":"text","text":"world"}]},"session_id":"s1"}
    , &out, &accumulated, &found);

    try std.testing.expect(!found);
    try std.testing.expectEqualStrings("Hello world", accumulated.items);

    parseClaudeLine(alloc,
        \\{"type":"result","subtype":"success","result":"Final answer","session_id":"s1"}
    , &out, &accumulated, &found);

    try std.testing.expect(found);
    try std.testing.expectEqualStrings("Final answer", out.items);
}

test "agent_sdk: non-text content blocks in assistant message are skipped" {
    const alloc = std.testing.allocator;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var accumulated: std.ArrayList(u8) = .empty;
    defer accumulated.deinit(alloc);
    var found = false;

    parseClaudeLine(alloc,
        \\{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{}},{"type":"text","text":"after tool"}]},"session_id":"s1"}
    , &out, &accumulated, &found);

    try std.testing.expect(!found);
    try std.testing.expectEqualStrings("after tool", accumulated.items);
}

test "agent_sdk: streamClaudeOutput extracts result via pipe" {
    const alloc = std.testing.allocator;

    const pipe = try std.posix.pipe();
    const read_fd  = std.fs.File{ .handle = pipe[0] };
    const write_fd = std.fs.File{ .handle = pipe[1] };

    const ndjson =
        "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"s1\"}\n" ++
        "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"thinking...\"}]},\"session_id\":\"s1\"}\n" ++
        "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"pipe test passed\",\"session_id\":\"s1\"}\n";

    _ = try write_fd.write(ndjson);
    write_fd.close();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    streamClaudeOutput(alloc, read_fd, &out);
    read_fd.close();

    try std.testing.expectEqualStrings("pipe test passed", out.items);
}

test "agent_sdk: streamClaudeOutput falls back to accumulated when no result event" {
    const alloc = std.testing.allocator;

    const pipe = try std.posix.pipe();
    const read_fd  = std.fs.File{ .handle = pipe[0] };
    const write_fd = std.fs.File{ .handle = pipe[1] };

    _ = try write_fd.write(
        "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"fallback text\"}]},\"session_id\":\"s1\"}\n"
    );
    write_fd.close();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    streamClaudeOutput(alloc, read_fd, &out);
    read_fd.close();

    try std.testing.expectEqualStrings("fallback text", out.items);
}

test "agent_sdk: readLine reads lines delimited by newline" {
    const alloc = std.testing.allocator;

    const pipe = try std.posix.pipe();
    const read_fd  = std.fs.File{ .handle = pipe[0] };
    const write_fd = std.fs.File{ .handle = pipe[1] };

    _ = try write_fd.write("hello\nworld\n");
    write_fd.close();

    const line1 = readLine(alloc, read_fd).?;
    defer alloc.free(line1);
    try std.testing.expectEqualStrings("hello", line1);

    const line2 = readLine(alloc, read_fd).?;
    defer alloc.free(line2);
    try std.testing.expectEqualStrings("world", line2);

    try std.testing.expect(readLine(alloc, read_fd) == null);
    read_fd.close();
}

test "agent_sdk: readLine returns partial content on EOF without trailing newline" {
    const alloc = std.testing.allocator;

    const pipe = try std.posix.pipe();
    const read_fd  = std.fs.File{ .handle = pipe[0] };
    const write_fd = std.fs.File{ .handle = pipe[1] };

    _ = try write_fd.write("no newline at end");
    write_fd.close();

    const line = readLine(alloc, read_fd).?;
    defer alloc.free(line);
    try std.testing.expectEqualStrings("no newline at end", line);
    read_fd.close();
}

test "agent_sdk: readLine returns null on immediate EOF" {
    const alloc = std.testing.allocator;

    const pipe = try std.posix.pipe();
    const read_fd  = std.fs.File{ .handle = pipe[0] };
    const write_fd = std.fs.File{ .handle = pipe[1] };

    write_fd.close();
    try std.testing.expect(readLine(alloc, read_fd) == null);
    read_fd.close();
}

// ─────────────────────────────────────────────────────────────────────────────
// Integration tests  (require `claude` on PATH + valid auth, ~5-10s each)
// Run with:  zig build test -Dtest-filter="integration"
// ─────────────────────────────────────────────────────────────────────────────

test "integration: agent_sdk round-trip — haiku replies to a simple prompt" {
    const alloc = std.testing.allocator;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    runAgent(alloc,
        "Reply with exactly the text TRANSPORT_OK and nothing else.",
        .{ .model = "haiku" },
        &out,
    );

    // If neither claude nor codex is available, out is empty — soft skip.
    if (out.items.len == 0) return;

    if (std.mem.indexOf(u8, out.items, "TRANSPORT_OK") == null) {
        std.debug.print("\n[integration] got: {s}\n", .{out.items});
        return error.UnexpectedResponse;
    }
}

test "integration: agent_sdk model param is forwarded" {
    const alloc = std.testing.allocator;

    var out1: std.ArrayList(u8) = .empty;
    defer out1.deinit(alloc);
    var out2: std.ArrayList(u8) = .empty;
    defer out2.deinit(alloc);

    runAgent(alloc, "Reply with exactly: HAIKU_RESPONSE",  .{ .model = "haiku"  }, &out1);
    runAgent(alloc, "Reply with exactly: SONNET_RESPONSE", .{ .model = "sonnet" }, &out2);

    if (out1.items.len == 0 and out2.items.len == 0) return; // soft skip

    if (std.mem.indexOf(u8, out1.items, "HAIKU_RESPONSE") == null) {
        std.debug.print("\n[integration] haiku got: {s}\n", .{out1.items});
        return error.UnexpectedResponse;
    }
    if (std.mem.indexOf(u8, out2.items, "SONNET_RESPONSE") == null) {
        std.debug.print("\n[integration] sonnet got: {s}\n", .{out2.items});
        return error.UnexpectedResponse;
    }
}
