const std = @import("std");
const cio = @import("cio.zig");
const testing = std.testing;
const io = std.testing.io;
const Store = @import("store.zig").Store;
const ChangeEntry = @import("store.zig").ChangeEntry;
const AgentRegistry = @import("agent.zig").AgentRegistry;
const Config = @import("config.zig").Config;
const edit_mod = @import("edit.zig");
const explore = @import("explore.zig");
const Explorer = explore.Explorer;
const linter = @import("linter.zig");
const linter_pref = @import("linter_pref.zig");
const ContentCache = @import("hot_cache.zig").ContentCache;


test "store: record and retrieve snapshots" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    const seq1 = try store.recordSnapshot("foo.zig", 100, 0xABC);
    const seq2 = try store.recordSnapshot("bar.zig", 200, 0xDEF);

    try testing.expect(seq1 == 1);
    try testing.expect(seq2 == 2);
    try testing.expect(store.currentSeq() == 2);
}


test "store: getLatest returns most recent version" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    _ = try store.recordSnapshot("foo.zig", 100, 0x111);
    _ = try store.recordSnapshot("foo.zig", 200, 0x222);

    const latest = store.getLatest("foo.zig").?;
    try testing.expect(latest.seq == 2);
    try testing.expect(latest.size == 200);
    try testing.expect(latest.hash == 0x222);
}


test "store: getLatest returns null for unknown file" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try testing.expect(store.getLatest("nope.zig") == null);
}


test "store: changesSince counts correctly" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    _ = try store.recordSnapshot("a.zig", 10, 0);
    _ = try store.recordSnapshot("b.zig", 20, 0);
    _ = try store.recordSnapshot("c.zig", 30, 0);

    try testing.expect(store.changesSince(0) == 3);
    try testing.expect(store.changesSince(1) == 2);
    try testing.expect(store.changesSince(3) == 0);
}


test "store: changesSinceDetailed" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    _ = try store.recordSnapshot("a.zig", 10, 0);
    _ = try store.recordSnapshot("b.zig", 20, 0);
    _ = try store.recordSnapshot("a.zig", 15, 0);

    const changes = try store.changesSinceDetailed(1, testing.allocator);
    defer testing.allocator.free(changes);

    try testing.expect(changes.len == 2); // a.zig and b.zig both changed
}


test "store: recordDelete creates tombstone" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    _ = try store.recordSnapshot("del.zig", 50, 0);
    _ = try store.recordDelete("del.zig", 0);

    const latest = store.getLatest("del.zig").?;
    try testing.expect(latest.op == .tombstone);
    try testing.expect(latest.size == 0);
}


test "store: getAtCursor" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    _ = try store.recordSnapshot("f.zig", 10, 0x10);
    _ = try store.recordSnapshot("f.zig", 20, 0x20);
    _ = try store.recordSnapshot("f.zig", 30, 0x30);

    const at1 = store.getAtCursor("f.zig", 1).?;
    try testing.expect(at1.size == 10);

    const at2 = store.getAtCursor("f.zig", 2).?;
    try testing.expect(at2.size == 20);

    const at3 = store.getAtCursor("f.zig", 99).?;
    try testing.expect(at3.size == 30);
}


test "store: recordEdit persists diff data to data log" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp_dir.dir.realPathFile(io, ".", &dir_buf);
    const dir_path = dir_buf[0..dir_path_len];

    const log_path = try std.fmt.allocPrint(testing.allocator, "{s}/data.log", .{dir_path});
    defer testing.allocator.free(log_path);

    var store = Store.init(testing.allocator);
    defer store.deinit();

    try store.openDataLog(io, log_path);

    const diff = "replace body";
    _ = try store.recordEdit("foo.zig", 1, .replace, 0x1234, diff.len, diff);

    const latest = store.getLatest("foo.zig").?;
    try testing.expectEqual(@as(?u64, 0), latest.data_offset);
    try testing.expectEqual(@as(u32, diff.len), latest.data_len);

    const log_file = try std.Io.Dir.cwd().openFile(io, log_path, .{});
    defer log_file.close(io);

    var buf: [32]u8 = undefined;
    const read_len = try log_file.readPositionalAll(io, buf[0..diff.len], 0);
    try testing.expectEqual(diff.len, read_len);
    try testing.expectEqualStrings(diff, buf[0..diff.len]);
}


test "agent: register and heartbeat" {
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();

    const id = try agents.register("test-agent");
    try testing.expect(id == 1);

    agents.heartbeat(id);
    // No crash = success
}


test "agent: register multiple agents" {
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();

    const a = try agents.register("alpha");
    const b = try agents.register("beta");
    try testing.expect(a == 1);
    try testing.expect(b == 2);
}


test "agent: lock and unlock" {
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();

    const id = try agents.register("locker");

    const got = try agents.tryLock(id, "file.zig", 60_000);
    try testing.expect(got == true);

    agents.releaseLock(id, "file.zig");
}


test "agent: lock contention between agents" {
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();

    const a = try agents.register("agent-a");
    const b = try agents.register("agent-b");

    // A locks the file
    const got_a = try agents.tryLock(a, "shared.zig", 60_000);
    try testing.expect(got_a == true);

    // B should be denied
    const got_b = try agents.tryLock(b, "shared.zig", 60_000);
    try testing.expect(got_b == false);

    // A releases
    agents.releaseLock(a, "shared.zig");

    // B can now lock
    const got_b2 = try agents.tryLock(b, "shared.zig", 60_000);
    try testing.expect(got_b2 == true);
}


test "agent: same-agent relock does not duplicate lock key" {
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();

    const id = try agents.register("agent-relock");

    try testing.expect(try agents.tryLock(id, "shared.zig", 60_000));
    try testing.expect(try agents.tryLock(id, "shared.zig", 60_000));

    const agent = agents.agents.getPtr(id) orelse return error.TestUnexpectedResult;
    try testing.expect(agent.locked_paths.count() == 1);

    agents.releaseLock(id, "shared.zig");
    try testing.expect(agent.locked_paths.count() == 0);
}


test "agent: reapStale frees lock keys and clears map" {
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();

    const id = try agents.register("agent-stale");
    try testing.expect(try agents.tryLock(id, "a.zig", 60_000));
    try testing.expect(try agents.tryLock(id, "b.zig", 60_000));

    const agent = agents.agents.getPtr(id) orelse return error.TestUnexpectedResult;
    agent.last_seen = 0;
    agents.reapStale(0);

    try testing.expect(agent.state == .crashed);
    try testing.expect(agent.locked_paths.count() == 0);
}


test "issue-411: tryLock grants new locks to a crashed agent" {
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();

    const id = try agents.register("zombie");

    // Force the agent into the crashed state via reapStale.
    const a = agents.agents.getPtr(id) orelse return error.TestUnexpectedResult;
    a.last_seen = 0;
    agents.reapStale(0);
    try testing.expectEqual(@as(@TypeOf(a.state), .crashed), a.state);

    // A crashed agent should not be allowed to acquire new advisory locks
    // until it heartbeats back to .active. Today tryLock ignores .state and
    // happily grants the lock — leaving the registry inconsistent (a
    // .crashed agent suddenly holds fresh locks again).
    const got = try agents.tryLock(id, "post-crash.zig", 60_000);
    try testing.expect(got == false);
}

test "issue-528: each MCP session registers a distinct edit-lock owner (not shared agent 1)" {
    // Bug 2 from the #528 audit: codedb_edit hardcoded agent_id=1, so concurrent
    // edits from separate connections all shared the startup __filesystem__ agent
    // and re-entrantly "won" the same-file lock. The MCP server now registers a
    // distinct agent per session and threads it into handleEdit. This guards that
    // registration yields distinct, non-1 owners that mutually exclude on a path.
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();

    const fs = try agents.register("__filesystem__"); // startup agent (id 1)
    const session_a = try agents.register("mcp-session");
    const session_b = try agents.register("mcp-session");

    try testing.expect(session_a != fs);
    try testing.expect(session_b != fs);
    try testing.expect(session_a != session_b);

    // Distinct session owners serialize same-file edits (vs the old shared-id
    // re-entrant grant that let two connections clobber each other).
    try testing.expect(try agents.tryLock(session_a, "x.zig", 60_000));
    try testing.expect(!(try agents.tryLock(session_b, "x.zig", 60_000)));
    agents.releaseLock(session_a, "x.zig");
    try testing.expect(try agents.tryLock(session_b, "x.zig", 60_000));
}


test "issue-401: insert with after=null is a no-op but consumes seq and writes file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const rel_path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/edit-401.txt", .{tmp.sub_path});
    defer testing.allocator.free(rel_path);

    const original = "line 1\nline 2\nline 3\n";
    var file = try tmp.dir.createFile(io, "edit-401.txt", .{});
    defer file.close(io);
    try file.writeStreamingAll(io, original);

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    const agent_id = try agents.register("issue-401-agent");

    // insert without after must not silently succeed and must not consume a seq.
    const res = edit_mod.applyEdit(io, testing.allocator, &store, &agents, null, .{
        .path = rel_path,
        .agent_id = agent_id,
        .op = .insert,
        .after = null,
        .content = "INJECT\n",
    });
    // Either explicit error, or — at minimum — must not increment the store seq
    // for an operation that did nothing.
    if (res) |ok| {
        _ = ok;
        try testing.expectEqual(@as(u64, 0), store.currentSeq());
    } else |_| {
        try testing.expectEqual(@as(u64, 0), store.currentSeq());
    }
}


test "issue-404: applyEdit corrupts CRLF line endings into mixed LF/CRLF" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const rel_path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/edit-404.txt", .{tmp.sub_path});
    defer testing.allocator.free(rel_path);

    // Windows-style CRLF original
    const original = "alpha\r\nbeta\r\ngamma\r\n";
    var file = try tmp.dir.createFile(io, "edit-404.txt", .{});
    defer file.close(io);
    try file.writeStreamingAll(io, original);

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    const agent_id = try agents.register("issue-404-agent");

    // Replace line 1 with new content (no trailing newline in replacement).
    _ = try edit_mod.applyEdit(io, testing.allocator, &store, &agents, null, .{
        .path = rel_path,
        .agent_id = agent_id,
        .op = .replace,
        .range = .{ 1, 1 },
        .content = "ALPHA",
    });

    const after = try std.Io.Dir.cwd().readFileAlloc(io, rel_path, testing.allocator, .limited(10 * 1024));
    defer testing.allocator.free(after);

    // The original file used CRLF line endings. After a single-line replace
    // the file must still be a valid CRLF file: every '\n' must be preceded
    // by '\r'. Currently splitScalar on '\n' leaves the '\r' attached to the
    // *unchanged* lines (e.g. "beta\r"), and the rejoin uses bare "\n", so
    // the new line 1 lacks its CR while the surviving line 2 still has it —
    // mixed line endings.
    var i: usize = 0;
    while (i < after.len) : (i += 1) {
        if (after[i] == '\n') {
            try testing.expect(i > 0);
            try testing.expectEqual(@as(u8, '\r'), after[i - 1]);
        }
    }
}


test "issue-409: replacing whole file with empty content leaves a stray newline" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const rel_path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/edit-409.txt", .{tmp.sub_path});
    defer testing.allocator.free(rel_path);

    // Single-line file with trailing newline.
    const original = "abc\n";
    var file = try tmp.dir.createFile(io, "edit-409.txt", .{});
    defer file.close(io);
    try file.writeStreamingAll(io, original);

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    const agent_id = try agents.register("issue-409-agent");

    // Replace the only line with empty content. The caller's intent is "make
    // this file empty" — content has zero bytes.
    const result = try edit_mod.applyEdit(io, testing.allocator, &store, &agents, null, .{
        .path = rel_path,
        .agent_id = agent_id,
        .op = .replace,
        .range = .{ 1, 1 },
        .content = "",
    });

    const after = try std.Io.Dir.cwd().readFileAlloc(io, rel_path, testing.allocator, .limited(10 * 1024));
    defer testing.allocator.free(after);

    // Expectation: the file is empty. Currently the file ends up as "\n"
    // because applyEdit unconditionally restores the trailing newline that
    // existed in the source, even after the replacement reduced the file
    // to a single empty line.
    try testing.expectEqual(@as(usize, 0), after.len);
    try testing.expectEqual(@as(u64, 0), result.new_size);
}


// ── Post-edit syntax health (trial/graph-based-codedb) ────────────────────

test "edit-health: flags unmatched close from a mis-spliced import edit (httpx-style)" {
    // Faithful to the real codedb httpx break: regenerating a
    // `from x import (...)` block left a duplicate ')' after the close,
    // making httpx/_models.py unparseable (SyntaxError: unmatched ')').
    const broken =
        \\from ._exceptions import (
        \\    CookieConflict,
        \\    DecodingError,
        \\    StreamConsumed,
        \\)
        \\)
        \\x = 1
    ;
    const msg = (try edit_mod.describeHealth(testing.allocator, broken, broken, .python)).?;
    defer testing.allocator.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "unmatched") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "line 6") != null);
}

test "edit-health: flags an unclosed opener (orphaned signature, narwhals-style)" {
    // Faithful to narwhals _sql/expr.py: a regenerated body left the original
    // signature open, so the '(' never closes.
    const broken =
        \\def rolling(
        \\    window_size,
        \\    min_samples,
        \\:
        \\    return window_size
    ;
    const msg = (try edit_mod.describeHealth(testing.allocator, broken, broken, .python)).?;
    defer testing.allocator.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "never closed") != null);
}

test "edit-health: no false positive on balanced python with brackets in strings/comments" {
    const ok =
        \\import re
        \\x = f"{a}({b}"   # a comment with ) and ] and }
        \\s = "a string with ( and { and ["
        \\def g(n):
        \\    return [i for i in range(n)]
    ;
    const msg = try edit_mod.describeHealth(testing.allocator, ok, ok, .python);
    try testing.expect(msg == null);
}

test "edit-health: stays silent on non-code content (unknown language)" {
    const txt = "a note with ( an unbalanced paren which is perfectly fine\n";
    const msg = try edit_mod.describeHealth(testing.allocator, txt, txt, .unknown);
    try testing.expect(msg == null);
}

test "edit-health: applyEdit surfaces a warning when an edit breaks a python file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const rel_path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/health.py", .{tmp.sub_path});
    defer testing.allocator.free(rel_path);

    const original = "import os\n\n\ndef main():\n    return os.getcwd()\n";
    var file = try tmp.dir.createFile(io, "health.py", .{});
    defer file.close(io);
    try file.writeStreamingAll(io, original);

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    const agent_id = try agents.register("edit-health-broken");

    // Insert a stray unbalanced ')' after line 1 — a mis-spliced edit.
    const result = try edit_mod.applyEdit(io, testing.allocator, &store, &agents, null, .{
        .path = rel_path,
        .agent_id = agent_id,
        .op = .insert,
        .after = 1,
        .content = ")",
    });
    defer if (result.health) |h| testing.allocator.free(h);
    try testing.expect(result.health != null);
    try testing.expect(std.mem.indexOf(u8, result.health.?, "unmatched") != null);
}

test "edit-health: a clean python edit produces no warning (happy path unchanged)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const rel_path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/clean.py", .{tmp.sub_path});
    defer testing.allocator.free(rel_path);

    const original = "import os\n\n\ndef main():\n    return os.getcwd()\n";
    var file = try tmp.dir.createFile(io, "clean.py", .{});
    defer file.close(io);
    try file.writeStreamingAll(io, original);

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    const agent_id = try agents.register("edit-health-clean");

    // Insert a balanced statement — must not trip the syntax warning.
    const result = try edit_mod.applyEdit(io, testing.allocator, &store, &agents, null, .{
        .path = rel_path,
        .agent_id = agent_id,
        .op = .insert,
        .after = 1,
        .content = "y = (1 + 2) * [3, 4][0]",
    });
    defer if (result.health) |h| testing.allocator.free(h);
    try testing.expect(result.health == null);
}

test "edit-health: flags an import name dropped but still used (narwhals NameError-style)" {
    // Faithful to codedb's narwhals break: a name removed from a `from ... import`
    // while still referenced. Syntactically valid, so only the import scan sees it.
    const before =
        \\from narwhals._utils import (
        \\    no_default,
        \\    unstable,
        \\)
        \\
        \\@unstable
        \\def rolling_min(): ...
    ;
    const after =
        \\from narwhals._utils import (
        \\    no_default,
        \\)
        \\
        \\@unstable
        \\def rolling_min(): ...
    ;
    const msg = (try edit_mod.describeHealth(testing.allocator, before, after, .python)).?;
    defer testing.allocator.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "unstable") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "still used") != null);
}

test "edit-health: dropping an import that is no longer used is clean" {
    const before =
        \\from m import used, gone
        \\
        \\x = used()
    ;
    const after =
        \\from m import used
        \\
        \\x = used()
    ;
    const msg = try edit_mod.describeHealth(testing.allocator, before, after, .python);
    try testing.expect(msg == null);
}

test "edit-health: a name re-imported from another module is not flagged" {
    // `helper` moves from module a to module b — removed from one import,
    // added in another. It is still bound, so must not be flagged.
    const before =
        \\from a import helper, other
        \\
        \\y = helper()
    ;
    const after =
        \\from a import other
        \\from b import helper
        \\
        \\y = helper()
    ;
    const msg = try edit_mod.describeHealth(testing.allocator, before, after, .python);
    try testing.expect(msg == null);
}


// ── Anchor-based str_replace (P2, trial/graph-based-codedb) ───────────────

test "edit-str_replace: anchored replace updates the unique occurrence exactly" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const rel_path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/sr.py", .{tmp.sub_path});
    defer testing.allocator.free(rel_path);

    const original = "def f(x):\n    return x + 1\n";
    var file = try tmp.dir.createFile(io, "sr.py", .{});
    defer file.close(io);
    try file.writeStreamingAll(io, original);

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    const agent_id = try agents.register("sr-1");

    const result = try edit_mod.applyEdit(io, testing.allocator, &store, &agents, null, .{
        .path = rel_path,
        .agent_id = agent_id,
        .op = .replace,
        .old_string = "return x + 1",
        .new_string = "return x + 2",
    });
    defer if (result.health) |h| testing.allocator.free(h);

    const after = try std.Io.Dir.cwd().readFileAlloc(io, rel_path, testing.allocator, .limited(10 * 1024));
    defer testing.allocator.free(after);
    try testing.expect(std.mem.indexOf(u8, after, "return x + 2") != null);
    try testing.expect(std.mem.indexOf(u8, after, "return x + 1") == null);
    try testing.expect(result.health == null);
}

test "edit-str_replace: missing old_string errors and writes nothing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const rel_path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/sr2.py", .{tmp.sub_path});
    defer testing.allocator.free(rel_path);

    var file = try tmp.dir.createFile(io, "sr2.py", .{});
    defer file.close(io);
    try file.writeStreamingAll(io, "a = 1\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    const agent_id = try agents.register("sr-2");

    try testing.expectError(error.PatternNotFound, edit_mod.applyEdit(io, testing.allocator, &store, &agents, null, .{
        .path = rel_path,
        .agent_id = agent_id,
        .op = .replace,
        .old_string = "does not exist",
        .new_string = "x",
    }));
    try testing.expectEqual(@as(u64, 0), store.currentSeq());
}

test "edit-str_replace: non-unique old_string errors (refuses ambiguous target)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const rel_path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/sr3.py", .{tmp.sub_path});
    defer testing.allocator.free(rel_path);

    var file = try tmp.dir.createFile(io, "sr3.py", .{});
    defer file.close(io);
    try file.writeStreamingAll(io, "x = 1\nx = 1\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    const agent_id = try agents.register("sr-3");

    try testing.expectError(error.PatternNotUnique, edit_mod.applyEdit(io, testing.allocator, &store, &agents, null, .{
        .path = rel_path,
        .agent_id = agent_id,
        .op = .replace,
        .old_string = "x = 1",
        .new_string = "x = 2",
    }));
    try testing.expectEqual(@as(u64, 0), store.currentSeq());
}

test "edit-str_replace: health check still runs on an anchored edit that breaks syntax" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const rel_path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/sr4.py", .{tmp.sub_path});
    defer testing.allocator.free(rel_path);

    var file = try tmp.dir.createFile(io, "sr4.py", .{});
    defer file.close(io);
    try file.writeStreamingAll(io, "y = (1 + 2)\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    const agent_id = try agents.register("sr-4");

    // Drop the closing paren via the anchored replace — health must catch it.
    const result = try edit_mod.applyEdit(io, testing.allocator, &store, &agents, null, .{
        .path = rel_path,
        .agent_id = agent_id,
        .op = .replace,
        .old_string = "(1 + 2)",
        .new_string = "(1 + 2",
    });
    defer if (result.health) |h| testing.allocator.free(h);
    try testing.expect(result.health != null);
    try testing.expect(std.mem.indexOf(u8, result.health.?, "never closed") != null);
}


// ── op=create: author new files (trial/graph-based-codedb) ────────────────

test "edit-create: op=create authors a new file that did not exist" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const rel_path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/created.py", .{tmp.sub_path});
    defer testing.allocator.free(rel_path);

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    const agent_id = try agents.register("cr-1");

    const body = "def hello():\n    return 42\n";
    const result = try edit_mod.applyEdit(io, testing.allocator, &store, &agents, null, .{
        .path = rel_path,
        .agent_id = agent_id,
        .op = .replace,
        .create = true,
        .content = body,
    });
    defer if (result.health) |h| testing.allocator.free(h);

    const after = try std.Io.Dir.cwd().readFileAlloc(io, rel_path, testing.allocator, .limited(10 * 1024));
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(body, after);
    try testing.expect(result.changed);
}

test "edit-create: op=create refuses to clobber an existing file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const rel_path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/exists.py", .{tmp.sub_path});
    defer testing.allocator.free(rel_path);

    var file = try tmp.dir.createFile(io, "exists.py", .{});
    defer file.close(io);
    try file.writeStreamingAll(io, "keep = 1\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    const agent_id = try agents.register("cr-2");

    try testing.expectError(error.FileExists, edit_mod.applyEdit(io, testing.allocator, &store, &agents, null, .{
        .path = rel_path,
        .agent_id = agent_id,
        .op = .replace,
        .create = true,
        .content = "clobber = 2\n",
    }));
    const after = try std.Io.Dir.cwd().readFileAlloc(io, rel_path, testing.allocator, .limited(10 * 1024));
    defer testing.allocator.free(after);
    try testing.expectEqualStrings("keep = 1\n", after);
}


// ── Tier-1 linter registry + session policy (trial/graph-based-codedb) ────

fn argsHaveFileToken(args: []const []const u8) bool {
    for (args) |a| if (std.mem.eql(u8, a, linter.FILE_TOKEN)) return true;
    return false;
}

test "linter: registry maps languages to the expected tools" {
    const py = linter.linterFor(.python).?;
    try testing.expectEqualStrings("ruff", py.tool);
    try testing.expect(py.json);
    try testing.expect(argsHaveFileToken(py.check_args));

    try testing.expectEqualStrings("biome", linter.linterFor(.typescript).?.tool);
    try testing.expectEqualStrings("biome", linter.linterFor(.javascript).?.tool);
    try testing.expectEqualStrings("zig", linter.linterFor(.zig).?.tool); // ast-check, ships with zig
    try testing.expectEqualStrings("cppcheck", linter.linterFor(.c).?.tool);
    try testing.expectEqualStrings("cppcheck", linter.linterFor(.cpp).?.tool);
    try testing.expect(argsHaveFileToken(linter.linterFor(.cpp).?.check_args));
    const sh = linter.linterFor(.shell).?;
    try testing.expectEqualStrings("shellcheck", sh.tool);
    try testing.expect(sh.json);
    try testing.expectEqualStrings("ktlint", linter.linterFor(.kotlin).?.tool);
    try testing.expectEqualStrings("swiftlint", linter.linterFor(.swift).?.tool);

    // Languages without a clean single-file linter fall back to heuristics.
    try testing.expect(linter.linterFor(.rust) == null);
    try testing.expect(linter.linterFor(.java) == null);
    try testing.expect(linter.linterFor(.unknown) == null);
}

test "linter: session fallback is sticky — a failed language is never retried" {
    var session = linter.LinterSession{ .enabled = true };
    // Opted-in session: python is worth trying, unknown is not (no tool).
    try testing.expectEqual(linter.LinterStatus.unknown, session.status(.python));
    try testing.expect(session.shouldTry(.python));
    try testing.expect(!session.shouldTry(.unknown));
    try testing.expect(!session.shouldTry(.rust));

    // Once a tool is missing / failed / crashed, the language is ruled out for
    // the rest of the session and we silently use the Tier-0 heuristics.
    session.mark(.python, .unavailable);
    try testing.expectEqual(linter.LinterStatus.unavailable, session.status(.python));
    try testing.expect(!session.shouldTry(.python));

    // A different language is unaffected.
    try testing.expect(session.shouldTry(.typescript));
}

test "linter: a disabled session never tries the external linter (preference off)" {
    // Default: the user has not opted in, so codedb uses only Tier-0 heuristics.
    var session = linter.LinterSession{};
    try testing.expect(!session.shouldTry(.python));
    try testing.expect(!session.shouldTry(.typescript));
    // Enabling flips it on for supported languages only.
    session.enabled = true;
    try testing.expect(session.shouldTry(.python));
    try testing.expect(!session.shouldTry(.rust));
}

test "linter: toolOnPath returns false for a non-existent executable" {
    try testing.expect(!linter.toolOnPath(testing.allocator, "codedb_definitely_not_a_real_tool_zzz"));
}


// ── Linter opt-in preference persistence (trial/graph-based-codedb) ───────

test "linter-pref: parseBody maps tokens to the three states" {
    try testing.expectEqual(linter_pref.Pref.on, linter_pref.parseBody("on\n"));
    try testing.expectEqual(linter_pref.Pref.on, linter_pref.parseBody("  on  "));
    try testing.expectEqual(linter_pref.Pref.off, linter_pref.parseBody("off\n"));
    try testing.expectEqual(linter_pref.Pref.unset, linter_pref.parseBody(""));
    try testing.expectEqual(linter_pref.Pref.unset, linter_pref.parseBody("garbage"));
    try testing.expect(linter_pref.enabledFromPref(.on));
    try testing.expect(!linter_pref.enabledFromPref(.off));
    try testing.expect(!linter_pref.enabledFromPref(.unset));
}

test "linter-pref: write then read round-trips on/off; missing file is unset" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/linter_optin", .{tmp.sub_path});
    defer testing.allocator.free(path);

    // Missing file -> unset (heuristics-only default).
    try testing.expectEqual(linter_pref.Pref.unset, linter_pref.readAt(io, path));

    linter_pref.writeAt(io, path, .on);
    try testing.expectEqual(linter_pref.Pref.on, linter_pref.readAt(io, path));

    linter_pref.writeAt(io, path, .off);
    try testing.expectEqual(linter_pref.Pref.off, linter_pref.readAt(io, path));

    // Writing unset is a no-op — the prior value remains.
    linter_pref.writeAt(io, path, .unset);
    try testing.expectEqual(linter_pref.Pref.off, linter_pref.readAt(io, path));
}


// ── Linter execution + output parsing (trial/graph-based-codedb) ──────────

test "linter: installFor returns installers for installable tools, null for toolchain langs" {
    try testing.expectEqualStrings("uv", linter.installFor(.python).?[0]);
    try testing.expectEqualStrings("ruff", linter.installFor(.python).?[3]);
    try testing.expectEqualStrings("npm", linter.installFor(.typescript).?[0]);
    try testing.expectEqualStrings("brew", linter.installFor(.shell).?[0]);
    try testing.expectEqualStrings("shellcheck", linter.installFor(.shell).?[2]);
    try testing.expectEqualStrings("cppcheck", linter.installFor(.c).?[2]);
    // zig/go/ruby/php ship with their toolchains -> nothing to install
    try testing.expect(linter.installFor(.zig) == null);
    try testing.expect(linter.installFor(.go_lang) == null);
}

test "linter: appendFirstLineStripped drops ANSI codes and stops at first line" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    // Mirrors `zig ast-check` output: bold + colour escapes, multi-line.
    const s = "\x1b[1mfile.zig:2:16: \x1b[31merror:\x1b[0m expected ';'\x1b[0m\n    const x = 1\n";
    try linter.appendFirstLineStripped(testing.allocator, &buf, s, 120);
    try testing.expectEqualStrings("file.zig:2:16: error: expected ';'", buf.items);
}

test "linter: summarizeShellcheckJson renders SC codes and treats [] as clean" {
    try testing.expect((try linter.summarizeShellcheckJson(testing.allocator, "[]")) == null);

    const json =
        \\[{"file":"x.sh","line":3,"column":4,"level":"warning","code":2154,"message":"bar is referenced but not assigned."}]
    ;
    const msg = (try linter.summarizeShellcheckJson(testing.allocator, json)).?;
    defer testing.allocator.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "shellcheck 1 issue") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "SC2154") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "L3") != null);
}

test "linter: summarizeRuffJson builds a summary and treats [] as clean" {
    try testing.expect((try linter.summarizeRuffJson(testing.allocator, "[]")) == null);

    const json =
        \\[{"code":"F821","message":"Undefined name x","location":{"row":109,"column":5},"filename":"a.py"},
        \\ {"code":"E501","message":"line too long","location":{"row":4,"column":1},"filename":"a.py"}]
    ;
    const msg = (try linter.summarizeRuffJson(testing.allocator, json)).?;
    defer testing.allocator.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "ruff 2 issues") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "F821") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "L109") != null);
}

test "linter: summarizeBiomeJson uses categories and treats empty diagnostics as clean" {
    try testing.expect((try linter.summarizeBiomeJson(testing.allocator, "{\"diagnostics\":[]}")) == null);

    const json =
        \\{"diagnostics":[{"category":"lint/correctness/noUndeclaredVariables"}]}
    ;
    const msg = (try linter.summarizeBiomeJson(testing.allocator, json)).?;
    defer testing.allocator.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "biome 1 issue") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "noUndeclaredVariables") != null);
}

test "linter: runCheck errors NoLinter for a language with no registered tool" {
    try testing.expectError(error.NoLinter, linter.runCheck(testing.allocator, .rust, "/tmp/x.rs"));
}

test "linter: the interactive prompt entrypoint compiles (analysis guard)" {
    // maybePromptAndInstall is reached only from the exe (update.zig), so the
    // test build would otherwise skip analysing it (Zig is lazy). Reference it
    // so a compile error there fails `zig build test`, not just the CLI build.
    _ = &linter.maybePromptAndInstall;
    _ = &linter.nanobrewPath;
    _ = &cio.readLine;
}


// ── Diagnostics cache (trial/graph-based-codedb) ──────────────────────────

test "diag-cache: store + appendIfFresh matches on (path,hash), misses otherwise" {
    var c = linter.DiagnosticsCache.init(testing.allocator);
    defer c.deinit();
    c.store("a.py", 111, "ruff 1 issue - F821 at L9");

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try testing.expect(c.appendIfFresh(testing.allocator, &out, "a.py", 111));
    try testing.expect(std.mem.indexOf(u8, out.items, "F821") != null);
    out.clearRetainingCapacity();
    try testing.expect(!c.appendIfFresh(testing.allocator, &out, "a.py", 999)); // wrong hash
    try testing.expect(!c.appendIfFresh(testing.allocator, &out, "b.py", 111)); // wrong path
}

test "diag-cache: appendLatest returns the newest summary for a path" {
    var c = linter.DiagnosticsCache.init(testing.allocator);
    defer c.deinit();
    c.store("a.py", 1, "first");
    c.store("a.py", 2, "second");
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try testing.expect(c.appendLatest(testing.allocator, &out, "a.py"));
    try testing.expectEqualStrings("second", out.items);
}

test "diag-cache: tryBeginWork coalesces per path and skips fresh content" {
    var c = linter.DiagnosticsCache.init(testing.allocator);
    defer c.deinit();
    try testing.expect(c.tryBeginWork("a.py", 1)); // first -> spawn
    try testing.expect(!c.tryBeginWork("a.py", 1)); // already pending -> skip
    try testing.expect(!c.tryBeginWork("a.py", 2)); // same path pending -> skip
    try testing.expect(c.tryBeginWork("b.py", 1)); // different path -> spawn
    c.endWork("a.py"); // a.py worker failed
    try testing.expect(c.tryBeginWork("a.py", 1)); // can spawn again
    c.store("a.py", 1, "done"); // result for (a.py,1); clears pending
    try testing.expect(!c.tryBeginWork("a.py", 1)); // fresh same-content -> skip
    try testing.expect(c.tryBeginWork("a.py", 2)); // different content -> spawn
    // zero out in-flight so deinit's drain returns immediately.
    c.endWork("a.py");
    c.endWork("b.py");
}

test "diag-cache: eviction stays bounded and leak-free past MAX entries" {
    var c = linter.DiagnosticsCache.init(testing.allocator);
    defer c.deinit();
    var i: usize = 0;
    while (i < linter.DiagnosticsCache.MAX + 5) : (i += 1) {
        var pbuf: [32]u8 = undefined;
        const p = std.fmt.bufPrint(&pbuf, "f{d}.py", .{i}) catch unreachable;
        c.store(p, i, "x"); // testing.allocator fails the test on any leak
    }
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    var pbuf: [32]u8 = undefined;
    const last = std.fmt.bufPrint(&pbuf, "f{d}.py", .{linter.DiagnosticsCache.MAX + 4}) catch unreachable;
    try testing.expect(c.appendLatest(testing.allocator, &out, last)); // newest retained
}


test "issue-101: Store.max_versions is configurable (caps per-file history)" {
    // Default cap is 100. After setting max_versions = 3, writing 5 versions
    // of the same file must leave exactly 3 in-memory.
    var store = Store.init(testing.allocator);
    defer store.deinit();

    store.max_versions = 3;

    _ = try store.recordSnapshot("foo.zig", 10, 0x111);
    _ = try store.recordSnapshot("foo.zig", 20, 0x222);
    _ = try store.recordSnapshot("foo.zig", 30, 0x333);
    _ = try store.recordSnapshot("foo.zig", 40, 0x444);
    _ = try store.recordSnapshot("foo.zig", 50, 0x555);

    const entry = store.files.get("foo.zig") orelse return error.MissingFile;
    try testing.expectEqual(@as(usize, 3), entry.versions.items.len);
    // Oldest two dropped — newest survives.
    try testing.expectEqual(@as(u64, 0x555), entry.versions.items[2].hash);
}


test "issue-102: Explorer.init capacity flows to ContentCache" {
    // Verifies that the capacity arg to Explorer.init actually sets the
    // ContentCache capacity — the bug that issue-102 was filed for.
    var explorer = Explorer.init(testing.allocator, 8);
    defer explorer.deinit();

    try testing.expectEqual(@as(u32, 8), explorer.contents.capacity);
}


test "issue-101+102: .codedbrc max_cached threads through to ContentCache capacity" {
    // End-to-end: parse a .codedbrc body, construct Explorer with the parsed
    // max_cached, verify the ContentCache capacity matches.
    const body =
        \\# test config
        \\max_versions = 7
        \\max_cached = 32
        \\
    ;
    const cfg = try Config.parse(body);
    try testing.expectEqual(@as(usize, 7), cfg.max_versions);
    try testing.expectEqual(@as(u32, 32), cfg.max_cached);

    var store = Store.init(testing.allocator);
    defer store.deinit();
    store.max_versions = cfg.max_versions;

    var explorer = Explorer.init(testing.allocator, cfg.max_cached);
    defer explorer.deinit();

    try testing.expectEqual(@as(usize, 7), store.max_versions);
    try testing.expectEqual(@as(u32, 32), explorer.contents.capacity);
}


test "issue-584: ContentCache probe-window — overflow inserts, holes, and duplicate keys" {
    // putImpl's overflow path evicts via a global CLOCK hand, so the new entry
    // lands OUTSIDE the key's 4-slot probe window: get() can never find it.
    // The entry's bytes (file contents, up to 64MB each) sit stranded in the
    // cache while every lookup for that key re-reads from disk. Holes left by
    // remove() also break lookups for in-window entries (`key_hash == 0`
    // early-break) and let put() insert a duplicate copy of a key it already
    // holds. All three violate the probe-window invariant.
    const fnvBase = struct {
        fn base(key: []const u8, cap: u32) u32 {
            var h: u64 = 14695981039346656037;
            for (key) |b| {
                h ^= b;
                h *%= 1099511628211;
            }
            if (h == 0) h = 1;
            return @as(u32, @truncate(h)) % cap;
        }
    }.base;

    // Collect 5 keys sharing one probe-window base in [1, 60] (slot 0 stays
    // outside the window, no wraparound).
    var bufs: [5][16]u8 = undefined;
    var lens: [5]usize = undefined;
    var nkeys: usize = 0;
    var counts = [_]u8{0} ** 64;
    var pick: u32 = 0;
    var i: usize = 0;
    while (i < 4096) : (i += 1) {
        var tmp: [16]u8 = undefined;
        const k = std.fmt.bufPrint(&tmp, "k{d}", .{i}) catch unreachable;
        const b = fnvBase(k, 64);
        if (b < 1 or b > 60) continue;
        counts[b] += 1;
        if (counts[b] >= 5) {
            pick = b;
            break;
        }
    }
    try testing.expect(pick != 0);
    i = 0;
    while (i < 4096 and nkeys < 5) : (i += 1) {
        var tmp: [16]u8 = undefined;
        const k = std.fmt.bufPrint(&tmp, "k{d}", .{i}) catch unreachable;
        if (fnvBase(k, 64) == pick) {
            @memcpy(bufs[nkeys][0..k.len], k);
            lens[nkeys] = k.len;
            nkeys += 1;
        }
    }
    try testing.expectEqual(@as(usize, 5), nkeys);
    const k0 = bufs[0][0..lens[0]];
    const k1 = bufs[1][0..lens[1]];
    const k2 = bufs[2][0..lens[2]];
    const k3 = bufs[3][0..lens[3]];
    const k4 = bufs[4][0..lens[4]];

    // 1) Overflow insert must stay retrievable from its own probe window.
    {
        var cache = try ContentCache.initAlloc(testing.allocator, 64);
        defer cache.deinit();
        try cache.put(k0, "v0");
        try cache.put(k1, "v1");
        try cache.put(k2, "v2");
        try cache.put(k3, "v3");
        try cache.put(k4, "v4"); // window full -> eviction path
        try testing.expect(cache.get(k4) != null);
    }

    // 2) A hole left by remove() must not hide in-window entries behind it.
    // 3) Re-putting such an entry must not create a duplicate copy.
    {
        var cache = try ContentCache.initAlloc(testing.allocator, 64);
        defer cache.deinit();
        try cache.put(k0, "v0");
        try cache.put(k1, "v1");
        try cache.put(k2, "v2");
        cache.remove(k1); // hole between k0 and k2
        try testing.expect(cache.get(k2) != null);
        try cache.put(k2, "v2b");
        try testing.expectEqual(@as(u32, 2), cache.len());
    }
}
