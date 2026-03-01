// codex_appserver.zig — Codex app-server JSON-RPC 2.0 client
//
// Spawns `codex app-server` inside a login shell so the full user PATH
// (including $HOME/bin, Homebrew, nix, etc.) is inherited regardless of
// how gitagent-mcp itself was launched.  Also resolves the zig tools
// directory once at startup and prepends it explicitly as a second line
// of defence.
//
// Protocol: https://github.com/openai/codex/tree/main/codex-rs/app-server
// Wire format: newline-delimited JSON, `"jsonrpc":"2.0"` header omitted.

const std = @import("std");
const mj  = @import("mcp").json;

// ── Startup: resolve zig tools directory once ─────────────────────────────────
//
// Walks the current process PATH to find zigrep.  Cached after the first
// call so every subsequent runTurnPolicy call is allocation-free here.
const ToolsDir = struct {
    var buf:     [std.fs.max_path_bytes]u8 = undefined;
    var len:     usize = 0;
    var found:   bool  = false;
    var checked: bool  = false;
    var mu:      std.Thread.Mutex = .{};

    /// Returns the directory that contains zigrep, or null if not found.
    /// Thread-safe; resolves at most once.
    fn get() ?[]const u8 {
        mu.lock();
        defer mu.unlock();
        if (checked) return if (found) buf[0..len] else null;
        checked = true;
        const path_env = std.process.getEnvVarOwned(
            std.heap.page_allocator, "PATH",
        ) catch return null;
        defer std.heap.page_allocator.free(path_env);
        var it = std.mem.splitScalar(u8, path_env, ':');
        while (it.next()) |dir| {
            var cbuf: [std.fs.max_path_bytes]u8 = undefined;
            const candidate = std.fmt.bufPrint(
                &cbuf, "{s}/zigrep", .{dir},
            ) catch continue;
            std.fs.accessAbsolute(candidate, .{}) catch continue;
            const n = @min(dir.len, buf.len);
            @memcpy(buf[0..n], dir[0..n]);
            len = n;
            found = true;
            return buf[0..len];
        }
        return null;
    }
};

/// Returns the resolved zig tools bin directory, or empty string if unknown.
/// Exposed so swarm.zig can embed absolute paths in the WRITABLE_PREAMBLE.
pub fn toolsBinDir() []const u8 {
    return ToolsDir.get() orelse "";
}

// ── Public API ────────────────────────────────────────────────────────────────

pub const SandboxPolicy = enum { read_only, writable };

/// Run a single agent turn via `codex app-server`.
/// Blocks until `turn/completed`. Accumulated agent reply is appended to `out`.
pub fn runTurn(
    alloc:  std.mem.Allocator,
    prompt: []const u8,
    out:    *std.ArrayList(u8),
) void {
    runTurnPolicy(alloc, prompt, out, .read_only);
}

/// Run a single agent turn via `codex app-server` inside a login shell.
/// Blocks until `turn/completed`. Accumulated agent reply is appended to `out`.
pub fn runTurnPolicy(
    alloc:  std.mem.Allocator,
    prompt: []const u8,
    out:    *std.ArrayList(u8),
    policy: SandboxPolicy,
) void {
    const cwd = std.process.getCwdAlloc(alloc) catch {
        appendErr(alloc, out, "could not get cwd");
        return;
    };
    defer alloc.free(cwd);

    // Build env: full current environment with the resolved zig tools dir
    // prepended to PATH (option 1).  If ToolsDir.get() returns null the env
    // is still forwarded as-is — HOME is present so codex finds its config.
    var env_map = std.process.getEnvMap(alloc) catch std.process.EnvMap.init(alloc);
    defer env_map.deinit();
    if (ToolsDir.get()) |tools_dir| {
        const old_path = env_map.get("PATH") orelse "/usr/local/bin:/usr/bin:/bin";
        const new_path = std.fmt.allocPrint(
            alloc, "{s}:{s}", .{ tools_dir, old_path },
        ) catch null;
        if (new_path) |np| {
            defer alloc.free(np);
            env_map.put("PATH", np) catch {};
        }
    }

    // ── Option 1: direct spawn ────────────────────────────────────────────
    // Spawn `codex app-server` directly.  Fast path — no shell overhead.
    var child = std.process.Child.init(&.{ "codex", "app-server" }, alloc);
    child.stdin_behavior  = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Close;
    child.env_map         = &env_map;

    const spawned = child.spawn();
    if (spawned) |_| {
        // Option 1 succeeded — run the turn normally.
        runTurn_(&child, alloc, cwd, prompt, policy, out);
        return;
    } else |_| {}

    // ── Option 2: login shell fallback ────────────────────────────────────
    // Direct spawn failed (codex not on current PATH).  Retry via the login
    // shell so .zshrc/.bash_profile are sourced and the full user PATH is
    // available.  `exec` replaces the shell with codex so our stdio pipes
    // attach directly.
    const shell = std.process.getEnvVarOwned(alloc, "SHELL") catch
        alloc.dupe(u8, "/bin/zsh") catch {
            appendErr(alloc, out, "could not spawn codex app-server — is codex on PATH?");
            return;
        };
    defer alloc.free(shell);

    const argv2 = [_][]const u8{ shell, "-lc", "exec codex app-server" };
    var child2 = std.process.Child.init(&argv2, alloc);
    child2.stdin_behavior  = .Pipe;
    child2.stdout_behavior = .Pipe;
    child2.stderr_behavior = .Close;
    child2.env_map         = &env_map;
    child2.spawn() catch {
        appendErr(alloc, out, "could not spawn codex app-server via login shell — is codex installed?");
        return;
    };
    runTurn_(&child2, alloc, cwd, prompt, policy, out);
}

/// Shared turn logic once a child process is spawned.
fn runTurn_(
    child:  *std.process.Child,
    alloc:  std.mem.Allocator,
    cwd:    []const u8,
    prompt: []const u8,
    policy: SandboxPolicy,
    out:    *std.ArrayList(u8),
) void {
    defer _ = child.wait() catch {};
    defer _ = child.kill() catch {};

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
        const policy_json: []const u8 = switch (policy) {
            .read_only => "{\"type\":\"readOnly\"}",
            .writable  => "{\"type\":\"unrestricted\"}",
        };
        var msg: std.ArrayList(u8) = .empty;
        defer msg.deinit(alloc);
        msg.appendSlice(alloc,
            \\{"method":"thread/start","id":1,"params":{"approvalPolicy":"never","sandboxPolicy":
        ) catch return;
        msg.appendSlice(alloc, policy_json) catch return;
        msg.appendSlice(alloc, ",\"cwd\":\"") catch return;
        mj.writeEscaped(alloc, &msg, cwd);
        msg.appendSlice(alloc, "\"}}") catch return;
        writeMsgSlice(proc_in, msg.items) catch {
            appendErr(alloc, out, "write thread/start failed"); return;
        };
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
        writeMsgSlice(proc_in, msg.items) catch {
            appendErr(alloc, out, "write turn/start failed"); return;
        };
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

fn readThreadId(alloc: std.mem.Allocator, rd: anytype) ?[]u8 {
    while (true) {
        const line = readLineAlloc(alloc, rd) orelse return null;
        defer alloc.free(line);
        const p = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch continue;
        defer p.deinit();
        if (p.value != .object) continue;
        const obj = &p.value.object;
        const id_v = obj.get("id") orelse continue;
        const id: i64 = switch (id_v) { .integer => |n| n, else => continue };
        if (id != 1) continue;
        const result = obj.get("result")          orelse continue;
        if (result != .object) continue;
        const thread = result.object.get("thread") orelse continue;
        if (thread != .object) continue;
        const tid    = thread.object.get("id")     orelse continue;
        if (tid != .string) continue;
        return alloc.dupe(u8, tid.string) catch null;
    }
}

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
            const params = obj.get("params") orelse continue;
            if (params != .object) continue;
            const delta = params.object.get("delta") orelse continue;
            if (delta == .string) out.appendSlice(alloc, delta.string) catch {};
            continue;
        }

        if (std.mem.eql(u8, method, "turn/completed")) {
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
