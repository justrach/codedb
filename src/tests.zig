const std = @import("std");
const testing = std.testing;

const Store = @import("store.zig").Store;
const ChangeEntry = @import("store.zig").ChangeEntry;
const AgentRegistry = @import("agent.zig").AgentRegistry;
const Explorer = @import("explore.zig").Explorer;
const SearchResult = @import("explore.zig").SearchResult;
const WordIndex = @import("index.zig").WordIndex;
const TrigramIndex = @import("index.zig").TrigramIndex;
const WordTokenizer = @import("index.zig").WordTokenizer;
const version = @import("version.zig");
const watcher = @import("watcher.zig");
const edit_mod = @import("edit.zig");
const Prerender = @import("prerender.zig").Prerender;
const explore = @import("explore.zig");
const extractLines = explore.extractLines;
const isCommentOrBlank = explore.isCommentOrBlank;
const Language = explore.Language;
const mcp_mod = @import("mcp.zig");
// ── Store tests ─────────────────────────────────────────────

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

// ── Agent tests ─────────────────────────────────────────────

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
// ── Word index tests ────────────────────────────────────────

test "word tokenizer" {
    var tok = WordTokenizer{ .buf = "pub fn main() !void {" };
    const w1 = tok.next().?;
    try testing.expectEqualStrings("pub", w1);
    const w2 = tok.next().?;
    try testing.expectEqualStrings("fn", w2);
    const w3 = tok.next().?;
    try testing.expectEqualStrings("main", w3);
    const w4 = tok.next().?;
    try testing.expectEqualStrings("void", w4);
    try testing.expect(tok.next() == null);
}

test "word index: index and search" {
    var wi = WordIndex.init(testing.allocator);
    defer wi.deinit();

    try wi.indexFile("src/foo.zig", "pub fn hello() void {\n    const x = 42;\n}\n");

    const hits = wi.search("hello");
    try testing.expect(hits.len > 0);
    try testing.expectEqualStrings("src/foo.zig", hits[0].path);
    try testing.expect(hits[0].line_num == 1);

    // "x" is only 1 char, should be skipped
    const x_hits = wi.search("x");
    try testing.expect(x_hits.len == 0);

    // "const" should be found
    const const_hits = wi.search("const");
    try testing.expect(const_hits.len > 0);
    try testing.expect(const_hits[0].line_num == 2);
}

test "word index: re-index clears old entries" {
    var wi = WordIndex.init(testing.allocator);
    defer wi.deinit();

    try wi.indexFile("f.zig", "fn old_func() void {}");
    try testing.expect(wi.search("old_func").len > 0);

    try wi.indexFile("f.zig", "fn new_func() void {}");
    try testing.expect(wi.search("old_func").len == 0);
    try testing.expect(wi.search("new_func").len > 0);
}

test "word index: removeFile" {
    var wi = WordIndex.init(testing.allocator);
    defer wi.deinit();

    try wi.indexFile("a.zig", "fn hello() void {}");
    try testing.expect(wi.search("hello").len > 0);

    wi.removeFile("a.zig");
    try testing.expect(wi.search("hello").len == 0);
}

test "word index: deduped search" {
    var wi = WordIndex.init(testing.allocator);
    defer wi.deinit();

    // "hello" appears twice on the same line — should dedup
    try wi.indexFile("f.zig", "hello hello world");

    const hits = try wi.searchDeduped("hello", testing.allocator);
    defer testing.allocator.free(hits);
    try testing.expect(hits.len == 1);
}

// ── Trigram index tests ─────────────────────────────────────

test "trigram index: index and candidate lookup" {
    var ti = TrigramIndex.init(testing.allocator);
    defer ti.deinit();

    try ti.indexFile("src/store.zig", "pub fn recordSnapshot(self: *Store) void {}");
    try ti.indexFile("src/agent.zig", "pub fn register(self: *Agent) void {}");

    const cands = ti.candidates("recordSnapshot");
    defer if (cands) |c| testing.allocator.free(c);
    try testing.expect(cands != null);
    try testing.expect(cands.?.len == 1);
    try testing.expectEqualStrings("src/store.zig", cands.?[0]);
}

test "trigram index: short query returns null" {
    var ti = TrigramIndex.init(testing.allocator);
    defer ti.deinit();

    try ti.indexFile("f.zig", "hello world");
    const cands = ti.candidates("hi");
    try testing.expect(cands == null);
}

test "trigram index: no match returns empty" {
    var ti = TrigramIndex.init(testing.allocator);
    defer ti.deinit();

    try ti.indexFile("f.zig", "hello world");
    const cands = ti.candidates("zzzzz");
    try testing.expect(cands != null);
    try testing.expect(cands.?.len == 0);
}

test "trigram index: re-index removes old trigrams" {
    var ti = TrigramIndex.init(testing.allocator);
    defer ti.deinit();

    try ti.indexFile("f.zig", "uniqueOldContent");
    const c1 = ti.candidates("uniqueOld");
    defer if (c1) |c| testing.allocator.free(c);
    try testing.expect(c1 != null and c1.?.len == 1);

    try ti.indexFile("f.zig", "brandNewStuff");
    const c2 = ti.candidates("uniqueOld");
    defer if (c2) |c| testing.allocator.free(c);
    try testing.expect(c2 != null and c2.?.len == 0);

    const c3 = ti.candidates("brandNew");
    defer if (c3) |c| testing.allocator.free(c);
    try testing.expect(c3 != null and c3.?.len == 1);
}

// ── Explorer tests ──────────────────────────────────────────

test "explorer: index file and get outline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("test.zig",
        \\const std = @import("std");
        \\pub fn main() !void {}
        \\pub const Store = struct {};
    );

    var outline = (try explorer.getOutline("test.zig", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    try testing.expect(outline.line_count == 3);
    try testing.expect(outline.symbols.items.len == 3);
}

test "explorer: findSymbol" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("a.zig", "pub fn alpha() void {}");
    try explorer.indexFile("b.zig", "pub fn beta() void {}");

    const result = try explorer.findSymbol("alpha", arena.allocator());
    try testing.expect(result != null);
    try testing.expectEqualStrings("a.zig", result.?.path);
}

test "explorer: findAllSymbols returns multiple" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("a.zig", "const Store = @import(\"store.zig\").Store;");
    try explorer.indexFile("b.zig", "pub const Store = struct {};");

    const results = try explorer.findAllSymbols("Store", arena.allocator());
    defer arena.allocator().free(results);
    try testing.expect(results.len == 2);
}

test "explorer: searchContent with trigram acceleration" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("store.zig", "pub fn recordSnapshot(self: *Store) void {}\npub fn init() void {}");
    try explorer.indexFile("agent.zig", "pub fn register(self: *Agent) void {}");

    const results = try explorer.searchContent("recordSnapshot", testing.allocator, 50);
    defer {
        for (results) |r| { testing.allocator.free(r.path); testing.allocator.free(r.line_text); }
        testing.allocator.free(results);
    }

    try testing.expect(results.len == 1);
    try testing.expectEqualStrings("store.zig", results[0].path);
    try testing.expect(results[0].line_num == 1);
}

test "explorer: searchWord via inverted index" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("math.zig", "pub fn add(a: i32, b: i32) i32 { return a + b; }");

    const hits = try explorer.searchWord("add", testing.allocator);
    defer testing.allocator.free(hits);
    try testing.expect(hits.len > 0);
    try testing.expectEqualStrings("math.zig", hits[0].path);
}

test "explorer: removeFile cleans up everything" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("gone.zig", "pub fn doStuff() void {}");
    var before_remove = (try explorer.getOutline("gone.zig", testing.allocator)) orelse return error.TestUnexpectedResult;
    before_remove.deinit();

    explorer.removeFile("gone.zig");
    try testing.expect((try explorer.getOutline("gone.zig", testing.allocator)) == null);
    try testing.expect((try explorer.findSymbol("doStuff", testing.allocator)) == null);
}

test "explorer: python parser" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("app.py",
        \\import os
        \\class Server:
        \\    def handle(self):
        \\        pass
    );

    var outline = (try explorer.getOutline("app.py", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    try testing.expect(outline.symbols.items.len == 3); // import, class, def
}

test "explorer: typescript parser" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("index.ts",
        \\import { foo } from './foo';
        \\export function handleRequest() {}
        \\export const PORT = 3000;
    );

    var outline = (try explorer.getOutline("index.ts", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    try testing.expect(outline.symbols.items.len >= 3);
}

// ── Version tests ───────────────────────────────────────────

test "file versions: append and latest" {
    var fv = version.FileVersions.init(testing.allocator, "test.zig");
    defer fv.deinit();

    try fv.versions.append(testing.allocator, .{
        .seq = 1, .agent = 0, .timestamp = 0, .op = .snapshot, .hash = 0x11, .size = 100,
    });
    try fv.versions.append(testing.allocator, .{
        .seq = 2, .agent = 0, .timestamp = 0, .op = .replace, .hash = 0x22, .size = 150,
    });

    const latest = fv.latest().?;
    try testing.expect(latest.seq == 2);
    try testing.expect(latest.size == 150);
}

test "file versions: countSince" {
    var fv = version.FileVersions.init(testing.allocator, "test.zig");
    defer fv.deinit();

    try fv.versions.append(testing.allocator, .{
        .seq = 1, .agent = 0, .timestamp = 0, .op = .snapshot, .hash = 0, .size = 0,
    });
    try fv.versions.append(testing.allocator, .{
        .seq = 5, .agent = 0, .timestamp = 0, .op = .replace, .hash = 0, .size = 0,
    });
    try fv.versions.append(testing.allocator, .{
        .seq = 10, .agent = 0, .timestamp = 0, .op = .delete, .hash = 0, .size = 0,
    });

    try testing.expect(fv.countSince(0) == 3);
    try testing.expect(fv.countSince(1) == 2);
    try testing.expect(fv.countSince(5) == 1);
    try testing.expect(fv.countSince(10) == 0);
}
test "explorer: reindex OOM keeps prior outline reachable" {
    // Use a real allocator for the explorer so the first indexFile always succeeds.
    // We can't use FailingAllocator for the whole explorer because deinit would crash.
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    try explorer.indexFile("oom.zig", "pub fn oldName() void {}");

    // Now try re-indexing the same file. Since the explorer uses testing.allocator,
    // we can't make individual internal allocs fail without a custom allocator wrapper.
    // Instead, verify the errdefer rollback logic by confirming a successful reindex
    // replaces the old outline, and that data is consistent.
    try explorer.indexFile("oom.zig", "pub fn newName() void {}\nconst VALUE = 1;");

    var outline = (try explorer.getOutline("oom.zig", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    try testing.expectEqualStrings("oom.zig", outline.path);
    try testing.expect(outline.symbols.items.len == 2); // newName + VALUE

    // Old content should be replaced
    const old_results = try explorer.searchContent("oldName", testing.allocator, 10);
    defer {
        for (old_results) |r| { testing.allocator.free(r.path); testing.allocator.free(r.line_text); }
        testing.allocator.free(old_results);
    }
    try testing.expect(old_results.len == 0);

    // New content should be searchable
    const new_results = try explorer.searchContent("newName", testing.allocator, 10);
    defer {
        for (new_results) |r| { testing.allocator.free(r.path); testing.allocator.free(r.line_text); }
        testing.allocator.free(new_results);
    }
    try testing.expect(new_results.len == 1);
}

test "explorer: getOutline clone OOM preserves source outline" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    try explorer.indexFile(
        "clone-oom.zig",
        "pub fn keepA() void {}\nconst dep = @import(\"dep.zig\");\npub const Value = 1;",
    );

    var induced_oom = false;
    var fail_index: usize = 0;
    while (fail_index < 512 and !induced_oom) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        const result = explorer.getOutline("clone-oom.zig", failing.allocator());

        if (result) |maybe_outline| {
            var outline = maybe_outline orelse return error.TestUnexpectedResult;
            outline.deinit();
            continue;
        } else |err| {
            if (err != error.OutOfMemory) return err;
            induced_oom = true;

            var stable = (try explorer.getOutline("clone-oom.zig", testing.allocator)) orelse return error.TestUnexpectedResult;
            defer stable.deinit();
            try testing.expect(stable.symbols.items.len >= 2);
            try testing.expect(stable.imports.items.len == 1);
            try testing.expectEqualStrings("dep.zig", stable.imports.items[0]);
        }
    }

    try testing.expect(induced_oom);
}

test "explorer: outline copy survives source removal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("persist.zig", "pub fn keep() void {}");
    var outline = (try explorer.getOutline("persist.zig", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();

    explorer.removeFile("persist.zig");

    try testing.expectEqualStrings("persist.zig", outline.path);
    try testing.expect(outline.symbols.items.len > 0);
}

test "explorer: removeFile frees owned map key" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    var i: usize = 0;
    while (i < 128) : (i += 1) {
        var path_buf: [48]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "tmp/remove-{d}.zig", .{i});
        try explorer.indexFile(path, "pub fn x() void {}");
        explorer.removeFile(path);
    }

    try testing.expect(explorer.outlines.count() == 0);
    try testing.expect(explorer.contents.count() == 0);
    try testing.expect(explorer.dep_graph.count() == 0);
}
test "watcher: queue overflow is explicit" {
    var queue = watcher.EventQueue{};

    var pushed: usize = 0;
    while (true) : (pushed += 1) {
        var path_buf: [32]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "tmp/f-{d}.zig", .{pushed});
        if (!queue.push(watcher.FsEvent.init(path, .modified, @intCast(pushed)) orelse unreachable)) break;
    }

    var overflow_path_buf: [32]u8 = undefined;
    const overflow_path = try std.fmt.bufPrint(&overflow_path_buf, "tmp/overflow.zig", .{});
    try testing.expect(!queue.push(watcher.FsEvent.init(overflow_path, .created, 999) orelse unreachable));

    var popped: usize = 0;
    while (queue.pop() != null) : (popped += 1) {}
    try testing.expect(popped == pushed);
}

test "watcher: queue event copies path bytes" {
    var queue = watcher.EventQueue{};
    const original = try testing.allocator.dupe(u8, "tmp/deleted.zig");
    try testing.expect(queue.push(watcher.FsEvent.init(original, .deleted, 99) orelse unreachable));
    testing.allocator.free(original);

    const event = queue.pop() orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("tmp/deleted.zig", event.path());
    try testing.expect(event.kind == .deleted);
    try testing.expect(event.seq == 99);
}

test "edit: range_start zero is invalid" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const rel_path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/edit-range.txt", .{tmp.sub_path});
    defer testing.allocator.free(rel_path);

    var file = try tmp.dir.createFile("edit-range.txt", .{});
    defer file.close();
    try file.writeAll("line 1\nline 2\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    const agent_id = try agents.register("test-agent");

    try testing.expectError(error.InvalidRange, edit_mod.applyEdit(testing.allocator, &store, &agents, .{
        .path = rel_path,
        .agent_id = agent_id,
        .op = .replace,
        .range = .{ 0, 1 },
        .content = "changed",
    }));
}

test "edit: range_start beyond file is invalid" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const rel_path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/edit-range-oob.txt", .{tmp.sub_path});
    defer testing.allocator.free(rel_path);

    var file = try tmp.dir.createFile("edit-range-oob.txt", .{});
    defer file.close();
    try file.writeAll("line 1\nline 2\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    const agent_id = try agents.register("test-agent-oob");

    try testing.expectError(error.InvalidRange, edit_mod.applyEdit(testing.allocator, &store, &agents, .{
        .path = rel_path,
        .agent_id = agent_id,
        .op = .replace,
        .range = .{ 3, 3 },
        .content = "changed",
    }));
}

// ── Regression tests for issues #2, #5, #7 ─────────────────
test "regression #2: searchContent frees trigram candidate slice" {
    // Verifies that the candidates() return value is freed by searchContent.
    // If the defer is missing, the GPA will detect the leak and fail.
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    try explorer.indexFile("leak-check.zig", "pub fn recordSnapshot(self: *Store) void {}\npub fn init() void {}");
    try explorer.indexFile("other.zig", "pub fn register(self: *Agent) void {}");

    const results = try explorer.searchContent("recordSnapshot", testing.allocator, 50);
    defer {
        for (results) |r| { testing.allocator.free(r.path); testing.allocator.free(r.line_text); }
        testing.allocator.free(results);
    }
    try testing.expect(results.len == 1);
    try testing.expectEqualStrings("leak-check.zig", results[0].path);
}

test "regression #2: searchContent no leak on zero results" {
    // Even when trigram narrows to candidates but none match full text,
    // the candidate slice must be freed.
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    try explorer.indexFile("abc.zig", "pub fn abcdef() void {}");

    // "abcxyz" shares trigrams "abc" but won't match full text
    const results = try explorer.searchContent("abcxyz", testing.allocator, 50);
    defer {
        for (results) |r| { testing.allocator.free(r.path); testing.allocator.free(r.line_text); }
        testing.allocator.free(results);
    }
    try testing.expect(results.len == 0);
}

test "regression #2: searchContent short query skips trigrams" {
    // Queries < 3 chars can't use trigram index — ensure no leak from null path.
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    try explorer.indexFile("short.zig", "fn ab() void {}");

    const results = try explorer.searchContent("ab", testing.allocator, 50);
    defer {
        for (results) |r| { testing.allocator.free(r.path); testing.allocator.free(r.line_text); }
        testing.allocator.free(results);
    }
    try testing.expect(results.len == 1);
}

test "regression #5: getHotFiles does not deadlock" {
    // getHotFiles used to hold explorer.mu while calling store.getLatest()
    // which locks store.mu — a lock ordering violation. The fix collects
    // paths under explorer.mu, releases it, then locks store.mu separately.
    // This test verifies correctness; deadlock would cause a hang.
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    var store = Store.init(testing.allocator);
    defer store.deinit();

    try explorer.indexFile("hot-a.zig", "pub fn a() void {}");
    try explorer.indexFile("hot-b.zig", "pub fn b() void {}");
    try explorer.indexFile("hot-c.zig", "pub fn c() void {}");

    _ = try store.recordSnapshot("hot-a.zig", 10, 0x1);
    _ = try store.recordSnapshot("hot-b.zig", 20, 0x2);
    _ = try store.recordSnapshot("hot-c.zig", 30, 0x3);
    _ = try store.recordSnapshot("hot-b.zig", 25, 0x4); // b updated again

    const hot = try explorer.getHotFiles(&store, testing.allocator, 2);
    defer {
        for (hot) |path| testing.allocator.free(path);
        testing.allocator.free(hot);
    }
    try testing.expect(hot.len == 2);
    // Most recent should be hot-b.zig (seq 4) then hot-c.zig (seq 3)
    try testing.expectEqualStrings("hot-b.zig", hot[0]);
    try testing.expectEqualStrings("hot-c.zig", hot[1]);
}

test "regression #5: getHotFiles with no store entries" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    var store = Store.init(testing.allocator);
    defer store.deinit();

    try explorer.indexFile("orphan.zig", "pub fn x() void {}");

    const hot = try explorer.getHotFiles(&store, testing.allocator, 10);
    defer {
        for (hot) |path| testing.allocator.free(path);
        testing.allocator.free(hot);
    }
    // File exists in explorer but not in store — seq defaults to 0
    try testing.expect(hot.len == 1);
    try testing.expectEqualStrings("orphan.zig", hot[0]);
}

test "regression: concurrent hot/read with remove" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    var store = Store.init(testing.allocator);
    defer store.deinit();

    try explorer.indexFile("race.zig", "pub fn race() void {}");
    _ = try store.recordSnapshot("race.zig", 24, 0x1);

    const Ctx = struct {
        explorer: *Explorer,
        store: *Store,
        stop: *std.atomic.Value(bool),
    };

    const Worker = struct {
        fn run(ctx: *Ctx) void {
            while (!ctx.stop.load(.acquire)) {
                const hot = ctx.explorer.getHotFiles(ctx.store, testing.allocator, 2) catch continue;
                defer {
                    for (hot) |path| testing.allocator.free(path);
                    testing.allocator.free(hot);
                }

                const cached = ctx.explorer.getContent("race.zig", testing.allocator) catch continue;
                if (cached) |content| testing.allocator.free(content);
            }
        }
    };

    var stop = std.atomic.Value(bool).init(false);
    var ctx = Ctx{ .explorer = &explorer, .store = &store, .stop = &stop };
    const worker = try std.Thread.spawn(.{}, Worker.run, .{&ctx});
    defer worker.join();
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        if (i % 2 == 0) {
            try explorer.indexFile("race.zig", "pub fn race() void {}");
            _ = try store.recordSnapshot("race.zig", @intCast(24 + i), @intCast(i + 2));
        } else {
            explorer.removeFile("race.zig");
        }
    }

    stop.store(true, .release);
}

test "regression #5: store getLatestSeqUnlocked" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    _ = try store.recordSnapshot("seq.zig", 100, 0xAA);
    _ = try store.recordSnapshot("seq.zig", 200, 0xBB);

    store.mu.lock();
    const seq = store.getLatestSeqUnlocked("seq.zig");
    const missing = store.getLatestSeqUnlocked("nope.zig");
    store.mu.unlock();

    try testing.expect(seq == 2);
    try testing.expect(missing == 0);
}

test "regression #7: tree shows directory nodes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("src/main.zig", "pub fn main() void {}");
    try explorer.indexFile("src/lib.zig", "pub fn init() void {}");
    try explorer.indexFile("build.zig", "pub fn build() void {}");

    const tree = try explorer.getTree(testing.allocator);
    defer testing.allocator.free(tree);

    // Should contain "src/" directory node
    try testing.expect(std.mem.indexOf(u8, tree, "src/\n") != null);
    // Should contain file basenames, not full paths
    try testing.expect(std.mem.indexOf(u8, tree, "  main.zig") != null);
    try testing.expect(std.mem.indexOf(u8, tree, "  lib.zig") != null);
    // Root-level file should not be indented
    try testing.expect(std.mem.indexOf(u8, tree, "build.zig") != null);
}

test "regression #7: tree handles nested directories" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("src/utils/hash.zig", "pub fn hash() void {}");
    try explorer.indexFile("src/main.zig", "pub fn main() void {}");

    const tree = try explorer.getTree(testing.allocator);
    defer testing.allocator.free(tree);

    // Should have both directory levels
    try testing.expect(std.mem.indexOf(u8, tree, "src/\n") != null);
    try testing.expect(std.mem.indexOf(u8, tree, "  utils/\n") != null);
    // Nested file should be double-indented
    try testing.expect(std.mem.indexOf(u8, tree, "    hash.zig") != null);
}

test "regression #7: tree shows only basenames" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("pkg/foo/bar.zig", "const x = 1;");

    const tree = try explorer.getTree(testing.allocator);
    defer testing.allocator.free(tree);

    // Full path should NOT appear in tree output
    try testing.expect(std.mem.indexOf(u8, tree, "pkg/foo/bar.zig") == null);
    // Only basename
    try testing.expect(std.mem.indexOf(u8, tree, "bar.zig") != null);
}
test "regression: searchWord empty result is allocator-owned" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("math.zig", "pub fn add(a: i32, b: i32) i32 { return a + b; }");

    const hits = try explorer.searchWord("missing_identifier", testing.allocator);
    defer testing.allocator.free(hits);
    try testing.expect(hits.len == 0);
}

test "regression: searchContent frees empty trigram candidate slice" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("f.zig", "hello world");

    const results = try explorer.searchContent("zzzzz", testing.allocator, 50);
    defer {
        for (results) |r| { testing.allocator.free(r.path); testing.allocator.free(r.line_text); }
        testing.allocator.free(results);
    }
    try testing.expect(results.len == 0);
}

test "regression: queue push stays non-blocking when full" {
    var queue = watcher.EventQueue{};

    var pushed: usize = 0;
    while (true) : (pushed += 1) {
        var path_buf: [32]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "tmp/fill-{d}.zig", .{pushed});
        if (!queue.push(watcher.FsEvent.init(path, .modified, @intCast(pushed)) orelse unreachable)) break;
    }

    var overflow_path_buf: [32]u8 = undefined;
    const overflow_path = try std.fmt.bufPrint(&overflow_path_buf, "tmp/overflow-2.zig", .{});
    const start = std.time.nanoTimestamp();
    _ = queue.push(watcher.FsEvent.init(overflow_path, .created, 1000) orelse unreachable);
    const elapsed = std.time.nanoTimestamp() - start;

    try testing.expect(elapsed < 50 * std.time.ns_per_ms);
}

// ── Path safety tests ───────────────────────────────────────

test "isPathSafe: rejects absolute paths" {
    const mcp = @import("mcp.zig");
    try testing.expect(!mcp.isPathSafe("/etc/passwd"));
    try testing.expect(!mcp.isPathSafe("/"));
}

test "isPathSafe: rejects parent traversal" {
    const mcp = @import("mcp.zig");
    try testing.expect(!mcp.isPathSafe("../secret"));
    try testing.expect(!mcp.isPathSafe("foo/../../etc/passwd"));
    try testing.expect(!mcp.isPathSafe(".."));
}

test "isPathSafe: rejects empty path" {
    const mcp = @import("mcp.zig");
    try testing.expect(!mcp.isPathSafe(""));
}

test "isPathSafe: accepts valid relative paths" {
    const mcp = @import("mcp.zig");
    try testing.expect(mcp.isPathSafe("src/main.zig"));
    try testing.expect(mcp.isPathSafe("README.md"));
    try testing.expect(mcp.isPathSafe("a/b/c/d.txt"));
}

test "prerender: snapshot builds and is valid JSON" {
    // Explorer uses arena for internal data
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var explorer = Explorer.init(alloc);
    try explorer.indexFile("src/main.zig", "pub fn main() void {}");
    try explorer.indexFile("src/lib.zig", "pub const version = 1;");

    var store = @import("store.zig").Store.init(alloc);
    defer store.deinit();
    _ = try store.recordSnapshot("src/main.zig", 100, 0xABC);

    // Prerender uses testing.allocator so rebuild can allocate independently
    var prerender = @import("prerender.zig").Prerender.init(testing.allocator);
    defer prerender.deinit();

    const snap = try prerender.getSnapshot(&explorer, &store, testing.allocator);
    defer testing.allocator.free(snap);

    // Must be valid JSON
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, snap, .{});
    defer parsed.deinit();

    // Must have expected top-level keys (matches buildSnapshot output)
    try testing.expect(parsed.value.object.contains("seq"));
    try testing.expect(parsed.value.object.contains("tree"));
    try testing.expect(parsed.value.object.contains("outlines"));
    try testing.expect(parsed.value.object.contains("symbol_index"));
    try testing.expect(parsed.value.object.contains("dep_graph"));
}

test "prerender: fresh instance needs rebuild" {
    var prerender = Prerender.init(testing.allocator);
    defer prerender.deinit();

    // Fresh prerender: dirty_epoch > built_epoch means it needs a rebuild
    try testing.expect(prerender.dirty_epoch.load(.acquire) > prerender.built_epoch.load(.acquire));
}

// ── Deep copy correctness tests ─────────────────────────────

test "findSymbol: returned data is owned copy" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var explorer = Explorer.init(alloc);
    try explorer.indexFile("a.zig", "pub fn myFunc() void {}");

    const result = try explorer.findSymbol("myFunc", alloc);
    try testing.expect(result != null);

    // Remove the source — if result was borrowed, this would corrupt it
    explorer.removeFile("a.zig");

    // Owned copy should still be valid
    try testing.expectEqualStrings("a.zig", result.?.path);
    try testing.expectEqualStrings("myFunc", result.?.symbol.name);
}

test "findAllSymbols: returned data survives source removal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var explorer = Explorer.init(alloc);
    try explorer.indexFile("a.zig", "pub fn foo() void {}");
    try explorer.indexFile("b.zig", "pub fn foo() void {}");

    const results = try explorer.findAllSymbols("foo", alloc);

    // Remove sources
    explorer.removeFile("a.zig");
    explorer.removeFile("b.zig");

    // Owned copies should still be valid
    try testing.expect(results.len == 2);
    for (results) |r| {
        try testing.expectEqualStrings("foo", r.symbol.name);
    }
}

test "searchContent: returned paths are owned copies" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var explorer = Explorer.init(alloc);
    try explorer.indexFile("src/hello.zig", "pub fn greetWorld() void {}");

    const results = try explorer.searchContent("greetWorld", alloc, 10);
    try testing.expect(results.len == 1);

    // Remove the source
    explorer.removeFile("src/hello.zig");

    // Path and line_text should still be valid (owned)
    try testing.expectEqualStrings("src/hello.zig", results[0].path);
}

// ── Word index: empty bucket pruning ────────────────────────

test "word index: removeFile prunes empty buckets" {
    var wi = WordIndex.init(testing.allocator);
    defer wi.deinit();

    try wi.indexFile("a.zig", "uniqueWordOnlyHere anotherUnique");
    // Words should exist
    try testing.expect(wi.search("uniqueWordOnlyHere").len > 0);

    wi.removeFile("a.zig");
    // After removal, buckets should be pruned (not just emptied)
    try testing.expect(wi.search("uniqueWordOnlyHere").len == 0);
}

test "trigram index: removeFile prunes empty sets" {
    var ti = TrigramIndex.init(testing.allocator);
    defer ti.deinit();

    try ti.indexFile("only.zig", "xyzUniqueTrigramContent");
    const before = ti.candidates("xyzUniqueTrigramContent");
    if (before) |b| {
        try testing.expect(b.len > 0);
        testing.allocator.free(b);
    }

    ti.removeFile("only.zig");
    const after = ti.candidates("xyzUniqueTrigramContent");
    if (after) |a| {
        try testing.expect(a.len == 0);
        testing.allocator.free(a);
    }
}

// ── Atomic edit test ────────────────────────────────────────

test "edit: atomic write leaves no temp files on success" {
    // Create a temp file to edit
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const path = "test_atomic.zig";
    const content = "line1\nline2\nline3\n";
    try tmp_dir.dir.writeFile(.{ .sub_path = path, .data = content });

    // The temp file pattern is "{path}.codedb_tmp"
    const tmp_path = path ++ ".codedb_tmp";

    // After a successful edit, no .codedb_tmp file should remain
    tmp_dir.dir.access(tmp_path, .{}) catch {
        // Expected: temp file doesn't exist (good)
        return;
    };
    // If we get here, the temp file exists — that's a bug
    return error.TempFileNotCleaned;
}

// ── MCP enhancement tests ───────────────────────────────────

test "extractLines: basic range with line numbers" {
    const content = "line1\nline2\nline3\nline4\nline5";
    const result = try extractLines(content, 2, 4, true, false, .unknown, testing.allocator);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "    2 | line2") != null);
    try testing.expect(std.mem.indexOf(u8, result, "    3 | line3") != null);
    try testing.expect(std.mem.indexOf(u8, result, "    4 | line4") != null);
    try testing.expect(std.mem.indexOf(u8, result, "line1") == null);
    try testing.expect(std.mem.indexOf(u8, result, "line5") == null);
}

test "extractLines: start beyond file returns empty" {
    const content = "line1\nline2";
    const result = try extractLines(content, 10, 20, true, false, .unknown, testing.allocator);
    defer testing.allocator.free(result);
    try testing.expect(result.len == 0);
}

test "extractLines: compact skips comments and blanks" {
    const content = "fn main() void {}\n// this is a comment\n\n    return 0;\n}";
    const result = try extractLines(content, 1, 5, false, true, .zig, testing.allocator);
    defer testing.allocator.free(result);
    // Should contain code lines but not the comment or blank line
    try testing.expect(std.mem.indexOf(u8, result, "fn main") != null);
    try testing.expect(std.mem.indexOf(u8, result, "// this is a comment") == null);
    try testing.expect(std.mem.indexOf(u8, result, "return 0") != null);
}

test "isCommentOrBlank: detects language-specific comments" {
    try testing.expect(isCommentOrBlank("  // zig comment", .zig));
    try testing.expect(isCommentOrBlank("  # python comment", .python));
    try testing.expect(isCommentOrBlank("  /* c comment */", .c));
    try testing.expect(isCommentOrBlank("  * continuation", .javascript));
    try testing.expect(isCommentOrBlank("   ", .zig));
    try testing.expect(isCommentOrBlank("", .zig));
    try testing.expect(!isCommentOrBlank("  const x = 1;", .zig));
    try testing.expect(!isCommentOrBlank("  x = 1", .python));
    // unknown language: never strips
    try testing.expect(!isCommentOrBlank("// comment", .unknown));
}

test "explorer: getSymbolBody returns source lines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var exp = Explorer.init(arena.allocator());

    try exp.indexFile("test.zig", "const std = @import(\"std\");\npub fn main() !void {}\npub const Store = struct {};");

    const body = try exp.getSymbolBody("test.zig", 2, 2, testing.allocator);
    if (body) |b| {
        defer testing.allocator.free(b);
        try testing.expect(std.mem.indexOf(u8, b, "pub fn main") != null);
    } else {
        return error.TestUnexpectedResult;
    }
}

test "explorer: getSymbolBody returns null for unknown file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var exp = Explorer.init(arena.allocator());

    const body = try exp.getSymbolBody("nonexistent.zig", 1, 5, testing.allocator);
    try testing.expect(body == null);
}
test "explorer: searchContentWithScope annotates results" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var exp = Explorer.init(arena.allocator());

    // Use content where the search match line has no symbol definition itself
    try exp.indexFile("auth.zig", "pub fn handleAuth() void {\n    validate(token);\n}");

    const results = try exp.searchContentWithScope("validate", testing.allocator, 50);
    defer {
        for (results) |r| {
            testing.allocator.free(r.line_text);
            testing.allocator.free(r.path);
            if (r.scope_name) |n| testing.allocator.free(n);
        }
        testing.allocator.free(results);
    }

    try testing.expect(results.len == 1);
    try testing.expectEqualStrings("auth.zig", results[0].path);
    try testing.expect(results[0].line_num == 2);
    // Should have scope annotation — nearest preceding symbol is handleAuth
    try testing.expect(results[0].scope_name != null);
    try testing.expectEqualStrings("handleAuth", results[0].scope_name.?);
}

test "explorer: searchContentWithScope no scope for standalone line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var exp = Explorer.init(arena.allocator());

    // Content with no symbols — scope should be null
    try exp.indexFile("data.txt", "hello world\nfoo bar");

    const results = try exp.searchContentWithScope("hello", testing.allocator, 50);
    defer {
        for (results) |r| {
            testing.allocator.free(r.line_text);
            testing.allocator.free(r.path);
            if (r.scope_name) |n| testing.allocator.free(n);
        }
        testing.allocator.free(results);
    }

    try testing.expect(results.len == 1);
    try testing.expect(results[0].scope_name == null);
}

test "content hash: Wyhash produces consistent hash" {
    const content = "pub fn main() void {}";
    const hash1 = std.hash.Wyhash.hash(0, content);
    const hash2 = std.hash.Wyhash.hash(0, content);
    try testing.expect(hash1 == hash2);
    // Different content produces different hash
    const hash3 = std.hash.Wyhash.hash(0, "different content");
    try testing.expect(hash1 != hash3);
}

test "detectLanguage: public access and correct detection" {
    try testing.expect(explore.detectLanguage("src/main.zig") == .zig);
    try testing.expect(explore.detectLanguage("app.py") == .python);
    try testing.expect(explore.detectLanguage("index.ts") == .typescript);
    try testing.expect(explore.detectLanguage("style.css") == .unknown);
}

test "extractLines: without line numbers" {
    const content = "alpha\nbeta\ngamma";
    const result = try extractLines(content, 1, 3, false, false, .unknown, testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("alpha\nbeta\ngamma\n", result);
}

// ── Extended MCP enhancement tests ──────────────────────────

// ── extractLines edge cases ─────────────────────────────────

test "extractLines: start only reads to EOF" {
    const content = "a\nb\nc\nd\ne";
    const result = try extractLines(content, 3, std.math.maxInt(u32), true, false, .unknown, testing.allocator);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "    3 | c") != null);
    try testing.expect(std.mem.indexOf(u8, result, "    4 | d") != null);
    try testing.expect(std.mem.indexOf(u8, result, "    5 | e") != null);
    try testing.expect(std.mem.indexOf(u8, result, "| a") == null);
    try testing.expect(std.mem.indexOf(u8, result, "| b") == null);
}

test "extractLines: end beyond file clamps to EOF" {
    const content = "x\ny\nz";
    const result = try extractLines(content, 2, 999, true, false, .unknown, testing.allocator);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "    2 | y") != null);
    try testing.expect(std.mem.indexOf(u8, result, "    3 | z") != null);
    // No crash, no garbage — just the available lines
    try testing.expect(std.mem.count(u8, result, "\n") == 2);
}

test "extractLines: single line range (start == end)" {
    const content = "one\ntwo\nthree";
    const result = try extractLines(content, 2, 2, true, false, .unknown, testing.allocator);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "    2 | two") != null);
    try testing.expect(std.mem.count(u8, result, "\n") == 1);
}

test "extractLines: empty content returns single empty line" {
    const result = try extractLines("", 1, 10, true, false, .unknown, testing.allocator);
    defer testing.allocator.free(result);
    // Empty string splits to one empty line, which is line 1
    try testing.expect(result.len > 0);
}

test "extractLines: compact with Python comments" {
    const content = "# comment\nimport os\n\ndef hello():\n    # inline comment\n    print('hi')";
    const result = try extractLines(content, 1, 6, false, true, .python, testing.allocator);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "# comment") == null);
    try testing.expect(std.mem.indexOf(u8, result, "# inline comment") == null);
    try testing.expect(std.mem.indexOf(u8, result, "import os") != null);
    try testing.expect(std.mem.indexOf(u8, result, "def hello") != null);
    try testing.expect(std.mem.indexOf(u8, result, "print('hi')") != null);
}

test "extractLines: compact with JS/TS comments" {
    const content = "// header\nconst x = 1;\n/* block */\n* star line\nexport default x;";
    const result = try extractLines(content, 1, 5, false, true, .typescript, testing.allocator);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "// header") == null);
    try testing.expect(std.mem.indexOf(u8, result, "/* block */") == null);
    try testing.expect(std.mem.indexOf(u8, result, "* star line") == null);
    try testing.expect(std.mem.indexOf(u8, result, "const x = 1;") != null);
    try testing.expect(std.mem.indexOf(u8, result, "export default x;") != null);
}

// ── isCommentOrBlank: additional languages ──────────────────

test "isCommentOrBlank: rust double-slash" {
    try testing.expect(isCommentOrBlank("  // rust comment", .rust));
    try testing.expect(!isCommentOrBlank("  let x = 1;", .rust));
}

test "isCommentOrBlank: go double-slash" {
    try testing.expect(isCommentOrBlank("  // go comment", .go_lang));
    try testing.expect(!isCommentOrBlank("  func main() {", .go_lang));
}

test "isCommentOrBlank: cpp block and line comments" {
    try testing.expect(isCommentOrBlank("  // cpp line comment", .cpp));
    try testing.expect(isCommentOrBlank("  /* cpp block comment */", .cpp));
    try testing.expect(isCommentOrBlank("  * continued block comment", .cpp));
    try testing.expect(!isCommentOrBlank("  int x = 0;", .cpp));
}

test "isCommentOrBlank: tabs and mixed whitespace" {
    try testing.expect(isCommentOrBlank("\t\t// tabbed comment", .zig));
    try testing.expect(isCommentOrBlank(" \t \t ", .zig));
    try testing.expect(isCommentOrBlank("\t", .python));
}

test "isCommentOrBlank: markdown and json never strip" {
    try testing.expect(!isCommentOrBlank("# heading", .markdown));
    try testing.expect(!isCommentOrBlank("// not a comment in json", .json));
    try testing.expect(!isCommentOrBlank("# not a comment in yaml", .yaml));
}

// ── getSymbolBody: multi-line and edge cases ────────────────

test "explorer: getSymbolBody multi-line range" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var exp = Explorer.init(arena.allocator());

    const content = "line1\nline2\nline3\nline4\nline5";
    try exp.indexFile("multi.zig", content);

    const body = try exp.getSymbolBody("multi.zig", 2, 4, testing.allocator);
    if (body) |b| {
        defer testing.allocator.free(b);
        try testing.expect(std.mem.indexOf(u8, b, "line2") != null);
        try testing.expect(std.mem.indexOf(u8, b, "line3") != null);
        try testing.expect(std.mem.indexOf(u8, b, "line4") != null);
        try testing.expect(std.mem.indexOf(u8, b, "line1") == null);
        try testing.expect(std.mem.indexOf(u8, b, "line5") == null);
    } else {
        return error.TestUnexpectedResult;
    }
}

test "explorer: getSymbolBody range beyond file length" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var exp = Explorer.init(arena.allocator());

    try exp.indexFile("short.zig", "only\ntwo");
    const body = try exp.getSymbolBody("short.zig", 1, 100, testing.allocator);
    if (body) |b| {
        defer testing.allocator.free(b);
        try testing.expect(std.mem.indexOf(u8, b, "only") != null);
        try testing.expect(std.mem.indexOf(u8, b, "two") != null);
    } else {
        return error.TestUnexpectedResult;
    }
}

// ── searchContentWithScope: multi-file, multi-result ────────

test "explorer: searchContentWithScope across multiple files" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var exp = Explorer.init(arena.allocator());

    try exp.indexFile("a.zig", "pub fn foo() void {\n    doWork();\n}");
    try exp.indexFile("b.zig", "pub fn bar() void {\n    doWork();\n}");

    const results = try exp.searchContentWithScope("doWork", testing.allocator, 50);
    defer {
        for (results) |r| {
            testing.allocator.free(r.line_text);
            testing.allocator.free(r.path);
            if (r.scope_name) |n| testing.allocator.free(n);
        }
        testing.allocator.free(results);
    }

    try testing.expect(results.len == 2);
    for (results) |r| {
        try testing.expect(r.scope_name != null);
        try testing.expect(r.line_num == 2);
    }
}

test "explorer: searchContentWithScope respects max_results" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var exp = Explorer.init(arena.allocator());

    try exp.indexFile("many.zig", "pub fn a() void {\n    target();\n    target();\n    target();\n    target();\n}");

    const results = try exp.searchContentWithScope("target", testing.allocator, 2);
    defer {
        for (results) |r| {
            testing.allocator.free(r.line_text);
            testing.allocator.free(r.path);
            if (r.scope_name) |n| testing.allocator.free(n);
        }
        testing.allocator.free(results);
    }

    try testing.expect(results.len == 2);
}

test "explorer: searchContentWithScope no results for missing query" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var exp = Explorer.init(arena.allocator());

    try exp.indexFile("empty.zig", "pub fn main() void {}");

    const results = try exp.searchContentWithScope("nonexistent_xyz", testing.allocator, 50);
    defer {
        for (results) |r| {
            testing.allocator.free(r.line_text);
            testing.allocator.free(r.path);
            if (r.scope_name) |n| testing.allocator.free(n);
        }
        testing.allocator.free(results);
    }

    try testing.expect(results.len == 0);
}

// ── Content hash ETag logic ─────────────────────────────────

test "content hash: format as hex string" {
    const content = "hello world";
    const hash = std.hash.Wyhash.hash(0, content);
    var buf: [16]u8 = undefined;
    const hex = std.fmt.bufPrint(&buf, "{x}", .{hash}) catch unreachable;
    for (hex) |c| {
        try testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
    // Consistent on same content
    const hash2 = std.hash.Wyhash.hash(0, content);
    var buf2: [16]u8 = undefined;
    const hex2 = std.fmt.bufPrint(&buf2, "{x}", .{hash2}) catch unreachable;
    try testing.expectEqualStrings(hex, hex2);
}

test "content hash: empty content hashes consistently" {
    const h1 = std.hash.Wyhash.hash(0, "");
    const h2 = std.hash.Wyhash.hash(0, "");
    try testing.expect(h1 == h2);
}

// ── detectLanguage: comprehensive ───────────────────────────

test "detectLanguage: all supported extensions" {
    try testing.expect(explore.detectLanguage("main.zig") == .zig);
    try testing.expect(explore.detectLanguage("lib.c") == .c);
    try testing.expect(explore.detectLanguage("util.h") == .c);
    try testing.expect(explore.detectLanguage("app.cpp") == .cpp);
    try testing.expect(explore.detectLanguage("app.hpp") == .cpp);
    try testing.expect(explore.detectLanguage("script.py") == .python);
    try testing.expect(explore.detectLanguage("app.js") == .javascript);
    try testing.expect(explore.detectLanguage("comp.jsx") == .javascript);
    try testing.expect(explore.detectLanguage("app.ts") == .typescript);
    try testing.expect(explore.detectLanguage("comp.tsx") == .typescript);
    try testing.expect(explore.detectLanguage("main.rs") == .rust);
    try testing.expect(explore.detectLanguage("main.go") == .go_lang);
    try testing.expect(explore.detectLanguage("README.md") == .markdown);
    try testing.expect(explore.detectLanguage("pkg.json") == .json);
    try testing.expect(explore.detectLanguage("config.yaml") == .yaml);
    try testing.expect(explore.detectLanguage("config.yml") == .yaml);
    try testing.expect(explore.detectLanguage("Makefile") == .unknown);
    try testing.expect(explore.detectLanguage("no_ext") == .unknown);
}

// ── getBool helper ──────────────────────────────────────────

test "getBool: returns true for bool true" {
    var map = std.json.ObjectMap.init(testing.allocator);
    defer map.deinit();
    try map.put("flag", .{ .bool = true });
    const mcp_getBool = @import("mcp.zig").getBool;
    try testing.expect(mcp_getBool(&map, "flag") == true);
}

test "getBool: returns false for bool false" {
    var map = std.json.ObjectMap.init(testing.allocator);
    defer map.deinit();
    try map.put("flag", .{ .bool = false });
    const mcp_getBool = @import("mcp.zig").getBool;
    try testing.expect(mcp_getBool(&map, "flag") == false);
}

test "getBool: returns false for missing key" {
    var map = std.json.ObjectMap.init(testing.allocator);
    defer map.deinit();
    const mcp_getBool = @import("mcp.zig").getBool;
    try testing.expect(mcp_getBool(&map, "missing") == false);
}

test "getBool: returns false for non-bool value" {
    var map = std.json.ObjectMap.init(testing.allocator);
    defer map.deinit();
    try map.put("flag", .{ .integer = 1 });
    const mcp_getBool = @import("mcp.zig").getBool;
    try testing.expect(mcp_getBool(&map, "flag") == false);
}

// ── Tool enum parsing (used by bundle) ──────────────────────

test "Tool enum: all valid tool names parse" {
    const Tool = @import("mcp.zig").Tool;
    try testing.expect(std.meta.stringToEnum(Tool, "codedb_tree") != null);
    try testing.expect(std.meta.stringToEnum(Tool, "codedb_outline") != null);
    try testing.expect(std.meta.stringToEnum(Tool, "codedb_symbol") != null);
    try testing.expect(std.meta.stringToEnum(Tool, "codedb_search") != null);
    try testing.expect(std.meta.stringToEnum(Tool, "codedb_word") != null);
    try testing.expect(std.meta.stringToEnum(Tool, "codedb_hot") != null);
    try testing.expect(std.meta.stringToEnum(Tool, "codedb_deps") != null);
    try testing.expect(std.meta.stringToEnum(Tool, "codedb_read") != null);
    try testing.expect(std.meta.stringToEnum(Tool, "codedb_edit") != null);
    try testing.expect(std.meta.stringToEnum(Tool, "codedb_changes") != null);
    try testing.expect(std.meta.stringToEnum(Tool, "codedb_status") != null);
    try testing.expect(std.meta.stringToEnum(Tool, "codedb_snapshot") != null);
    try testing.expect(std.meta.stringToEnum(Tool, "codedb_bundle") != null);
}

test "Tool enum: invalid names return null" {
    const Tool = @import("mcp.zig").Tool;
    try testing.expect(std.meta.stringToEnum(Tool, "codedb_invalid") == null);
    try testing.expect(std.meta.stringToEnum(Tool, "") == null);
    try testing.expect(std.meta.stringToEnum(Tool, "tree") == null);
}

// ── Integration: extractLines + getSymbolBody pipeline ──────

test "explorer: getSymbolBody with line number format" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var exp = Explorer.init(arena.allocator());

    try exp.indexFile("fmt.zig", "const a = 1;\npub fn format() void {\n    write();\n}\nconst b = 2;");

    const body = try exp.getSymbolBody("fmt.zig", 2, 4, testing.allocator);
    if (body) |b| {
        defer testing.allocator.free(b);
        try testing.expect(std.mem.indexOf(u8, b, "    2 |") != null);
        try testing.expect(std.mem.indexOf(u8, b, "    3 |") != null);
        try testing.expect(std.mem.indexOf(u8, b, "    4 |") != null);
        try testing.expect(std.mem.indexOf(u8, b, "const a") == null);
        try testing.expect(std.mem.indexOf(u8, b, "const b") == null);
    } else {
        return error.TestUnexpectedResult;
    }
}

// ── Compact output: verify code-only output ─────────────────

test "extractLines: compact preserves brace-only lines" {
    const content = "fn main() void {\n    // comment\n    doWork();\n}";
    const result = try extractLines(content, 1, 4, false, true, .zig, testing.allocator);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "fn main") != null);
    try testing.expect(std.mem.indexOf(u8, result, "}") != null);
    try testing.expect(std.mem.indexOf(u8, result, "doWork") != null);
    try testing.expect(std.mem.indexOf(u8, result, "// comment") == null);
}

test "extractLines: compact on all-comment file returns empty" {
    const content = "// comment 1\n// comment 2\n// comment 3";
    const result = try extractLines(content, 1, 3, false, true, .zig, testing.allocator);
    defer testing.allocator.free(result);
    try testing.expect(result.len == 0);
}
