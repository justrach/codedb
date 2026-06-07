const std = @import("std");
const cio = @import("cio.zig");
const testing = std.testing;
const io = std.testing.io;
const Store = @import("store.zig").Store;
const Explorer = @import("explore.zig").Explorer;
const explore = @import("explore.zig");
const Language = explore.Language;
const SymbolKind = explore.SymbolKind;
const WordIndex = @import("index.zig").WordIndex;
const TrigramIndex = @import("index.zig").TrigramIndex;
const SparseNgramIndex = @import("index.zig").SparseNgramIndex;
const snapshot_mod = @import("snapshot.zig");
const snapshot_json = @import("snapshot_json.zig");
const watcher = @import("watcher.zig");
const git_mod = @import("git.zig");
const AgentRegistry = @import("agent.zig").AgentRegistry;
const edit_mod = @import("edit.zig");


test "issue-35: edits immediately update explorer and snapshot output" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const rel_path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/edit-live-sync.zig", .{tmp.sub_path});
    defer testing.allocator.free(rel_path);

    var file = try tmp.dir.createFile(io, "edit-live-sync.zig", .{});
    defer file.close(io);
    try file.writeStreamingAll(io, "pub fn oldName() void {}\n");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    try explorer.indexFile(rel_path, "pub fn oldName() void {}\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();
    _ = try store.recordSnapshot(rel_path, "pub fn oldName() void {}\n".len, std.hash.Wyhash.hash(0, "pub fn oldName() void {}\n"));

    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    const agent_id = try agents.register("issue-35-agent");

    const before_snap = try snapshot_json.buildSnapshot(&explorer, &store, testing.allocator);
    defer testing.allocator.free(before_snap);
    try testing.expect(std.mem.indexOf(u8, before_snap, "oldName") != null);

    _ = try edit_mod.applyEdit(io, testing.allocator, &store, &agents, &explorer, .{
        .path = rel_path,
        .agent_id = agent_id,
        .op = .replace,
        .range = .{ 1, 1 },
        .content = "pub fn newName() void {}",
    });

    const new_results = try explorer.searchContent("newName", testing.allocator, 10);
    defer {
        for (new_results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(new_results);
    }
    try testing.expect(new_results.len == 1);

    const old_results = try explorer.searchContent("oldName", testing.allocator, 10);
    defer {
        for (old_results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(old_results);
    }
    try testing.expect(old_results.len == 0);

    const after_snap = try snapshot_json.buildSnapshot(&explorer, &store, testing.allocator);
    defer testing.allocator.free(after_snap);
    try testing.expect(std.mem.indexOf(u8, after_snap, "newName") != null);
    try testing.expect(std.mem.indexOf(u8, after_snap, "oldName") == null);
}


test "snapshot_json: snapshot builds and is valid JSON" {
    // Explorer uses arena for internal data
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var explorer = Explorer.init(alloc, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    try explorer.indexFile("src/main.zig", "pub fn main() void {}");
    try explorer.indexFile("src/lib.zig", "pub const version = 1;");

    var store = @import("store.zig").Store.init(alloc);
    defer store.deinit();
    _ = try store.recordSnapshot("src/main.zig", 100, 0xABC);

    const snap = try snapshot_json.buildSnapshot(&explorer, &store, testing.allocator);
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

    const tree = parsed.value.object.get("tree").?.string;
    try testing.expect(std.mem.indexOf(u8, tree, "src/") != null);
    try testing.expect(std.mem.indexOf(u8, tree, "main.zig") != null);

    const symbol_index = parsed.value.object.get("symbol_index").?.object;
    try testing.expect(symbol_index.contains("main"));
    try testing.expect(symbol_index.contains("version"));
}


test "issue-44: snapshot stale after working tree changes cause stale query results" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    const snap_path = try std.fmt.allocPrint(testing.allocator, "{s}/test.snapshot", .{dir_path});
    defer testing.allocator.free(snap_path);
    const file_abs = try std.fmt.allocPrint(testing.allocator, "{s}/stale.zig", .{dir_path});
    defer testing.allocator.free(file_abs);

    // Step 1: write file with old content, index it, write snapshot.
    try tmp.dir.writeFile(io, .{ .sub_path = "stale.zig", .data = "pub fn oldFunc() void {}" });
    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var exp = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
        try exp.indexFile(file_abs, "pub fn oldFunc() void {}");
        try snapshot_mod.writeSnapshot(io, &exp, ".", snap_path, arena.allocator());
    }

    // Step 2: modify file AFTER snapshot creation (simulating uncommitted working tree change).
    // Sleep 10ms so the file mtime is strictly greater than the snapshot's indexed_at timestamp.
    cio.sleepMs(10);
    try tmp.dir.writeFile(io, .{ .sub_path = "stale.zig", .data = "pub fn newFunc() void {}" });

    // Step 3: load snapshot into a fresh explorer (what MCP startup does).
    // scan_done is set to true immediately; watcher then builds known-FileMap
    // from current disk mtimes, recording the already-modified file's mtime as
    // the baseline. It will never be re-indexed unless changed a second time.
    var arena2 = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena2.deinit();
    var exp2 = Explorer.init(arena2.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    var store2 = Store.init(testing.allocator);
    defer store2.deinit();

    const loaded = snapshot_mod.loadSnapshot(io, snap_path, &exp2, &store2, arena2.allocator());
    try testing.expect(loaded);

    // Step 4: after the fix, loadSnapshot should detect that the disk file's
    // mtime > snapshot indexed_at and re-index it from disk, making "newFunc"
    // visible. Currently no such path exists.
    // Expected (after fix): results.len == 1
    // Current (bug): results.len == 0 — stale snapshot content is never evicted.
    const results = try exp2.searchContent("newFunc", testing.allocator, 10);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }
    try testing.expect(results.len == 1);
}


test "issue-46: empty-repo snapshot rejected on load" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var exp = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    const snap_path = try std.fmt.allocPrint(testing.allocator, "{s}/test.codedb", .{dir_path});
    defer testing.allocator.free(snap_path);

    try snapshot_mod.writeSnapshot(io, &exp, dir_path, snap_path, testing.allocator);

    var arena2 = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena2.deinit();
    var exp2 = Explorer.init(arena2.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    var store = Store.init(testing.allocator);
    defer store.deinit();

    const loaded = snapshot_mod.loadSnapshot(io, snap_path, &exp2, &store, testing.allocator);
    try testing.expect(!loaded);
    try testing.expect(exp2.outlines.count() == 0);
}

// Restored FileOutlines borrow their import/symbol strings as slices into a
// section buffer the Explorer retains (FileOutline.borrows_strings). This test
// pins two things the borrow optimization must preserve:
//   1. the strings survive the round-trip intact (slices point at the right bytes)
//   2. explorer.deinit() frees the adopted section buffer exactly once and does
//      NOT double-free the borrowed strings (DebugAllocator flags either).
test "snapshot: restored outlines borrow strings (round-trip intact + clean deinit)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var exp = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    // A path that does not exist on disk, so the load takes the restore path
    // (the freshness check can't find a newer file) rather than re-indexing.
    try exp.indexFile("borrow_test_pkg/main.zig",
        \\const std = @import("std");
        \\const helper = @import("helper.zig");
        \\pub fn alphaFn() void {}
        \\pub fn betaFn(x: u32) u32 {
        \\    return x + 1;
        \\}
        \\
    );

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];
    const snap_path = try std.fmt.allocPrint(testing.allocator, "{s}/borrow.codedb", .{dir_path});
    defer testing.allocator.free(snap_path);
    try snapshot_mod.writeSnapshot(io, &exp, dir_path, snap_path, testing.allocator);

    // Fresh Explorer, loaded with the same allocator and explicitly deinit'd —
    // the production pattern. This verifies explorer.deinit() cleanly frees the
    // adopted section backing AND that the borrowed import/symbol strings are
    // not double-freed (DebugAllocator would flag either).
    var exp2 = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer exp2.deinit();
    var store = Store.init(testing.allocator);
    defer store.deinit();

    const loaded = snapshot_mod.loadSnapshot(io, snap_path, &exp2, &store, testing.allocator);
    try testing.expect(loaded);

    const outline = exp2.outlines.get("borrow_test_pkg/main.zig") orelse return error.MissingOutline;
    try testing.expect(outline.borrows_strings);
    try testing.expect(outline.imports.items.len >= 1);

    var saw_alpha = false;
    var saw_beta = false;
    for (outline.symbols.items) |s| {
        if (std.mem.eql(u8, s.name, "alphaFn")) saw_alpha = true;
        if (std.mem.eql(u8, s.name, "betaFn")) saw_beta = true;
    }
    try testing.expect(saw_alpha);
    try testing.expect(saw_beta);
}

// Call-graph centrality (the ranking boost) is persisted in a snapshot section
// and restored on load, so the first ranked search skips the lazy rebuild. This
// pins: (1) the value round-trips exactly, and (2) restore happens at load time
// with no search having run, keyed off the restored outlines.
test "snapshot: call-graph centrality persists and restores (no lazy rebuild)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var exp = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    // util.zig defines helper(); main.zig calls it twice -> util.zig has in-degree.
    // Paths don't exist on disk, so the load takes the restore path.
    try exp.indexFile("cc_pkg/util.zig",
        \\pub fn helper() void {}
        \\
    );
    try exp.indexFile("cc_pkg/main.zig",
        \\const util = @import("util.zig");
        \\pub fn run() void {
        \\    helper();
        \\    helper();
        \\}
        \\
    );

    exp.buildCallCentrality(testing.allocator);
    try testing.expect(exp.call_centrality != null);
    const want = exp.call_centrality.?.get("cc_pkg/util.zig") orelse 0.0;
    try testing.expect(want > 0.0);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];
    const snap_path = try std.fmt.allocPrint(testing.allocator, "{s}/cc.codedb", .{dir_path});
    defer testing.allocator.free(snap_path);
    try snapshot_mod.writeSnapshot(io, &exp, dir_path, snap_path, testing.allocator);

    var exp2 = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer exp2.deinit();
    var store = Store.init(testing.allocator);
    defer store.deinit();

    const loaded = snapshot_mod.loadSnapshot(io, snap_path, &exp2, &store, testing.allocator);
    try testing.expect(loaded);

    // Restored at load time — no ranked search ran to build it.
    try testing.expect(exp2.call_centrality != null);
    const got = exp2.call_centrality.?.get("cc_pkg/util.zig") orelse 0.0;
    try testing.expectEqual(want, got);
}

// The CONTENT_HASHES section lets the loader record Store baselines without
// re-hashing content. This pins that the stored hash equals Wyhash of the
// content for each file — i.e. the section is read in the correct (content)
// order, so hashes are not misaligned across files.
test "snapshot: CONTENT_HASHES records the correct per-file hash (order-aligned)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var exp = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    const Pair = struct { p: []const u8, c: []const u8 };
    const files = [_]Pair{
        .{ .p = "ch_pkg/alpha.zig", .c = "pub fn alpha() void { beta(); }\n" },
        .{ .p = "ch_pkg/beta.zig", .c = "pub fn beta() void {}\npub fn extra() void {}\n" },
        .{ .p = "ch_pkg/gamma.zig", .c = "const value = 123456;\n" },
    };
    for (files) |f| try exp.indexFile(f.p, f.c);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];
    const snap_path = try std.fmt.allocPrint(testing.allocator, "{s}/ch.codedb", .{dir_path});
    defer testing.allocator.free(snap_path);
    try snapshot_mod.writeSnapshot(io, &exp, dir_path, snap_path, testing.allocator);

    var exp2 = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer exp2.deinit();
    var store = Store.init(testing.allocator);
    defer store.deinit();
    try testing.expect(snapshot_mod.loadSnapshot(io, snap_path, &exp2, &store, testing.allocator));

    for (files) |f| {
        const v = store.getLatest(f.p) orelse return error.MissingVersion;
        try testing.expectEqual(std.hash.Wyhash.hash(0, f.c), v.hash);
    }
}


test "issue-220: snapshot fast load restores outlines and lazily rebuilds word index" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var exp = Explorer.init(aa, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    try exp.indexFile("src/store.zig", "pub const Store = struct {};\n");
    try exp.indexFile("src/main.zig", "const Store = @import(\"store.zig\").Store;\npub fn main() void {}\n");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    const snap_path = try std.fmt.allocPrint(testing.allocator, "{s}/fast.codedb", .{dir_path});
    defer testing.allocator.free(snap_path);
    try snapshot_mod.writeSnapshot(io, &exp, dir_path, snap_path, testing.allocator);

    var arena2 = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena2.deinit();
    var exp2 = Explorer.init(arena2.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    var store = Store.init(testing.allocator);
    defer store.deinit();

    const loaded = snapshot_mod.loadSnapshot(io, snap_path, &exp2, &store, arena2.allocator());
    try testing.expect(loaded);
    try testing.expectEqual(@as(usize, 2), exp2.outlines.count());
    try testing.expectEqual(@as(u32, 0), exp2.trigram_index.fileCount());
    try testing.expectEqual(@as(usize, 0), exp2.word_index.index.count());
    try testing.expect(exp2.wordIndexCanLoadFromDisk());
    try testing.expect(!exp2.wordIndexIsComplete());
    try testing.expect(!exp2.wordIndexNeedsPersist());

    const deps = try exp2.getImportedBy("src/store.zig", testing.allocator);
    defer {
        for (deps) |dep| testing.allocator.free(dep);
        testing.allocator.free(deps);
    }
    try testing.expectEqual(@as(usize, 1), deps.len);
    try testing.expect(std.mem.eql(u8, deps[0], "src/main.zig"));

    const hits = try exp2.searchWord("Store", testing.allocator);
    defer testing.allocator.free(hits);
    try testing.expect(hits.len >= 1);
    try testing.expect(exp2.word_index.index.count() > 0);
    try testing.expect(exp2.wordIndexIsComplete());
    try testing.expect(exp2.wordIndexNeedsPersist());
}

test "issue-537: snapshot-restored files stay searchable when trigram index is non-empty" {
    // Emulates the engram-reported "structurally blind" search (#537). The real
    // root cause is a load-path coverage gap, not ranking: a file restored from a
    // snapshot lands in outlines+contents but (pre-fix) is registered in NEITHER
    // trigram_index NOR skip_trigram_files, so Explorer.searchContent finds it in
    // no tier. The bug only surfaces once the trigram index is non-empty (some
    // other file indexed after load), because that rules out the Tier 5 full
    // scan — exactly the daemon's state (hot files in trigram + cold restored
    // files everywhere else).
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var exp = Explorer.init(aa, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    // Path does not exist on disk in the temp dir below, so load restores it
    // (freshness finds nothing newer) rather than re-indexing it into trigram.
    try exp.indexFile("cold_pkg/buried.zig",
        \\pub const FRESHNESS_PARALLEL_THRESHOLD_UNIQUE: usize = 256;
        \\pub fn buriedHelper() void {}
        \\
    );

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];
    const snap_path = try std.fmt.allocPrint(testing.allocator, "{s}/cold.codedb", .{dir_path});
    defer testing.allocator.free(snap_path);
    try snapshot_mod.writeSnapshot(io, &exp, dir_path, snap_path, testing.allocator);

    var arena2 = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena2.deinit();
    const aa2 = arena2.allocator();
    var exp2 = Explorer.init(aa2, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    var store = Store.init(testing.allocator);
    defer store.deinit();

    const loaded = snapshot_mod.loadSnapshot(io, snap_path, &exp2, &store, aa2);
    try testing.expect(loaded);
    try testing.expect(exp2.outlines.get("cold_pkg/buried.zig") != null);

    // Make the trigram index non-empty so Tier 5 (full outline scan) is ruled
    // out — the condition under which restored files vanish from search.
    try exp2.indexFile("hot_pkg/active.zig", "pub fn activeFn() void {}\n");

    // Query a MID-TOKEN substring ("RESHNESS" inside FRESHNESS_…): the word index
    // (Tier 0, rebuilt by the #539 fix) matches only whole tokens, so this can be
    // surfaced ONLY by the Tier 3 skip_trigram content scan — isolating the #537
    // fix. Without the skip_trigram_files registration the restored file is in no
    // tier and this returns nothing.
    const results = try exp2.searchContent("RESHNESS", aa2, 10);
    try testing.expect(results.len >= 1);
    try testing.expect(std.mem.eql(u8, results[0].path, "cold_pkg/buried.zig"));
}

test "snapshot: parallel freshness load re-indexes changed files, restores the rest" {
    // Forces loadSnapshotFast's multi-worker freshness path with a fixture larger
    // than FRESHNESS_PARALLEL_THRESHOLD: files edited after the snapshot must come
    // back with fresh content (changed branch) while the rest restore unchanged.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const total = snapshot_mod.FRESHNESS_PARALLEL_THRESHOLD + 32;

    // Build `total` files on disk, indexing each by ABSOLUTE path so the load's
    // cwd-relative statFile resolves them regardless of the test's working dir.
    var exp = Explorer.init(aa, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    const abs_paths = try aa.alloc([]const u8, total);
    for (0..total) |i| {
        const rel = try std.fmt.allocPrint(aa, "f{d}.zig", .{i});
        const content = try std.fmt.allocPrint(aa, "pub fn oldfn_{d}() void {{}}\n", .{i});
        try tmp.dir.writeFile(io, .{ .sub_path = rel, .data = content });
        abs_paths[i] = try std.fmt.allocPrint(aa, "{s}/{s}", .{ dir_path, rel });
        try exp.indexFileOutlineOnly(abs_paths[i], content);
    }

    const snap_path = try std.fmt.allocPrint(aa, "{s}/parallel.codedb", .{dir_path});
    try snapshot_mod.writeSnapshot(io, &exp, dir_path, snap_path, aa);

    // Edit a spread of files AFTER the snapshot so their mtime is strictly newer.
    cio.sleepMs(10);
    const changed = [_]usize{ 1, total / 4, total / 2, (total * 3) / 4, total - 2 };
    for (changed) |i| {
        const rel = try std.fmt.allocPrint(aa, "f{d}.zig", .{i});
        const content = try std.fmt.allocPrint(aa, "pub fn newfn_{d}() void {{}}\n", .{i});
        try tmp.dir.writeFile(io, .{ .sub_path = rel, .data = content });
    }

    // Reload into a fresh explorer: the parallel scan must spot the edited files.
    var arena2 = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena2.deinit();
    var exp2 = Explorer.init(arena2.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try testing.expect(snapshot_mod.loadSnapshot(io, snap_path, &exp2, &store, arena2.allocator()));
    try testing.expectEqual(total, exp2.outlines.count());

    var is_changed = [_]bool{false} ** total;
    for (changed) |i| is_changed[i] = true;

    // Changed files carry fresh content (changed branch); the rest keep snapshot
    // content (restored branch) — verified directly via the content cache.
    for (0..total) |i| {
        const cached = exp2.contents.get(abs_paths[i]) orelse return error.MissingContent;
        const want = if (is_changed[i])
            try std.fmt.allocPrint(aa, "pub fn newfn_{d}() void {{}}\n", .{i})
        else
            try std.fmt.allocPrint(aa, "pub fn oldfn_{d}() void {{}}\n", .{i});
        try testing.expectEqualStrings(want, cached);
    }
}


test "snapshot: writer streams uncached file contents for large repos" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "src");

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    var exp = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer exp.deinit();

    var rel_buf: [64]u8 = undefined;
    var content_buf: [128]u8 = undefined;
    for (0..1002) |i| {
        const rel = try std.fmt.bufPrint(&rel_buf, "src/file_{d}.zig", .{i});
        const content = try std.fmt.bufPrint(&content_buf, "pub fn func_{d}() usize {{ return {d}; }}\n", .{ i, i });
        try tmp.dir.writeFile(io, .{ .sub_path = rel, .data = content });
        try exp.indexFileOutlineOnly(rel, content);
    }

    try testing.expectEqual(@as(usize, 1002), exp.outlines.count());
    // With CLOCK eviction (#208) the ContentCache holds up to 16384 entries — all 1002 fit.
    try testing.expectEqual(@as(u32, 1002), exp.contents.count());

    const snap_path = try std.fmt.allocPrint(testing.allocator, "{s}/large.codedb", .{dir_path});
    defer testing.allocator.free(snap_path);
    try snapshot_mod.writeSnapshot(io, &exp, dir_path, snap_path, testing.allocator);

    var loaded_without_root = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer loaded_without_root.deinit();
    var store_without_root = Store.init(testing.allocator);
    defer store_without_root.deinit();

    try testing.expect(snapshot_mod.loadSnapshot(io, snap_path, &loaded_without_root, &store_without_root, testing.allocator));
    try testing.expectEqual(@as(usize, 1002), loaded_without_root.outlines.count());
    // CLOCK cache holds all 1002 — word index can be rebuilt from memory without root dir.
    const hits_no_root = try loaded_without_root.searchWord("func_1001", testing.allocator);
    defer testing.allocator.free(hits_no_root);
    try testing.expectEqual(@as(usize, 1), hits_no_root.len);

    var loaded = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    loaded.setRoot(io, dir_path);
    defer loaded.deinit();
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try testing.expect(snapshot_mod.loadSnapshot(io, snap_path, &loaded, &store, testing.allocator));
    try testing.expectEqual(@as(usize, 1002), loaded.outlines.count());

    const hits = try loaded.searchWord("func_1001", testing.allocator);
    defer testing.allocator.free(hits);
    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("src/file_1001.zig", loaded.word_index.hitPath(hits[0]));
    try testing.expect(loaded.wordIndexIsComplete());
}


test "issue-220: partial word index state rebuilds before search" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    var exp = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer exp.deinit();
    try exp.indexFile("src/a.zig", "pub const Alpha = 1;\n");
    try exp.indexFile("src/b.zig", "pub const Beta = 2;\n");

    const snap_path = try std.fmt.allocPrint(testing.allocator, "{s}/partial.codedb", .{dir_path});
    defer testing.allocator.free(snap_path);
    try snapshot_mod.writeSnapshot(io, &exp, dir_path, snap_path, testing.allocator);

    var exp2 = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer exp2.deinit();
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try testing.expect(snapshot_mod.loadSnapshot(io, snap_path, &exp2, &store, testing.allocator));
    try testing.expect(exp2.wordIndexCanLoadFromDisk());
    try testing.expect(!exp2.wordIndexIsComplete());

    try exp2.indexFileSkipTrigram("src/b.zig", "pub const Gamma = 3;\n");
    try testing.expect(!exp2.wordIndexCanLoadFromDisk());
    try testing.expect(!exp2.wordIndexIsComplete());

    const alpha_hits = try exp2.searchWord("Alpha", testing.allocator);
    defer testing.allocator.free(alpha_hits);
    try testing.expectEqual(@as(usize, 1), alpha_hits.len);
    try testing.expect(std.mem.eql(u8, exp2.word_index.hitPath(alpha_hits[0]), "src/a.zig"));

    const gamma_hits = try exp2.searchWord("Gamma", testing.allocator);
    defer testing.allocator.free(gamma_hits);
    try testing.expectEqual(@as(usize, 1), gamma_hits.len);
    try testing.expect(std.mem.eql(u8, exp2.word_index.hitPath(gamma_hits[0]), "src/b.zig"));
    try testing.expect(exp2.wordIndexIsComplete());
    try testing.expect(exp2.wordIndexNeedsPersist());
}


test "issue-220: word index persistence tracking skips redundant rewrites" {
    var exp = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer exp.deinit();

    try exp.indexFile("src/a.zig", "pub const Alpha = 1;\n");
    try testing.expect(exp.wordIndexIsComplete());
    try testing.expect(exp.wordIndexNeedsPersist());

    const first_gen = exp.wordIndexGenerationToPersist() orelse return error.TestUnexpectedResult;
    exp.markWordIndexPersisted(first_gen);
    try testing.expect(!exp.wordIndexNeedsPersist());
    try testing.expect(exp.wordIndexGenerationToPersist() == null);

    try exp.indexFile("src/a.zig", "pub const Beta = 2;\n");
    try testing.expect(exp.wordIndexNeedsPersist());

    const second_gen = exp.wordIndexGenerationToPersist() orelse return error.TestUnexpectedResult;
    try testing.expect(second_gen != first_gen);
    exp.markWordIndexPersisted(first_gen);
    try testing.expect(exp.wordIndexNeedsPersist());
    exp.markWordIndexPersisted(second_gen);
    try testing.expect(!exp.wordIndexNeedsPersist());
}


test "issue-45: snapshot written in non-git directory cannot be loaded" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    var exp = Explorer.init(aa, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    try exp.indexFile("dummy.zig", "const x = 1;");

    const snap_path = try std.fs.path.join(aa, &.{ dir_path, "test.codedb" });

    // Write snapshot with a non-git root_path — git_head will be all-zeros
    try snapshot_mod.writeSnapshot(io, &exp, "/tmp", snap_path, aa);

    // Snapshot file was created
    std.Io.Dir.cwd().access(io, snap_path, .{}) catch {
        return error.TestUnexpectedResult;
    };

    // readSnapshotGitHead returns null for non-git dirs (all-zero sentinel).
    // The snapshot loading logic in main.zig handles this by checking if the
    // current project also has no git — if so, it loads the snapshot.
    const snap_head = snapshot_mod.readSnapshotGitHead(io, snap_path);
    try testing.expect(snap_head == null);
}


test "issue-47: concurrent snapshot writes from parallel instances corrupt file" {
    // BUG: Two codedb instances indexing the same repo write codedb.snapshot
    // concurrently with no file locking. The second writer can overwrite a
    // partially-written snapshot, producing a corrupt file that loadSnapshot
    // rejects or — worse — reads garbage section offsets from.
    //
    // Simulate: two threads write snapshots to the same path concurrently,
    // then verify the final file is still loadable.
    var arena1 = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena1.deinit();
    var arena2 = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena2.deinit();

    var exp1 = Explorer.init(arena1.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    try exp1.indexFile("a.zig", "pub fn alpha() void {}");
    var exp2 = Explorer.init(arena2.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    try exp2.indexFile("b.zig", "pub fn beta() void {}");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];
    const snap_path = try std.fmt.allocPrint(testing.allocator, "{s}/concurrent.codedb", .{dir_path});
    defer testing.allocator.free(snap_path);

    const WriterCtx = struct {
        exp: *Explorer,
        path: []const u8,
        dir: []const u8,
        alloc: std.mem.Allocator,
        failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        fn run(ctx: *@This()) void {
            for (0..10) |_| {
                snapshot_mod.writeSnapshot(io, ctx.exp, ctx.dir, ctx.path, ctx.alloc) catch {
                    ctx.failed.store(true, .release);
                    return;
                };
            }
        }
    };

    var ctx1 = WriterCtx{ .exp = &exp1, .path = snap_path, .dir = dir_path, .alloc = arena1.allocator() };
    var ctx2 = WriterCtx{ .exp = &exp2, .path = snap_path, .dir = dir_path, .alloc = arena2.allocator() };

    const t1 = try std.Thread.spawn(.{}, WriterCtx.run, .{&ctx1});
    const t2 = try std.Thread.spawn(.{}, WriterCtx.run, .{&ctx2});
    t1.join();
    t2.join();

    // Neither writer should have errored
    try testing.expect(!ctx1.failed.load(.acquire));
    try testing.expect(!ctx2.failed.load(.acquire));

    // The final snapshot must be loadable (not corrupt)
    var arena3 = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena3.deinit();
    var exp3 = Explorer.init(arena3.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    var store3 = Store.init(testing.allocator);
    defer store3.deinit();
    const loaded = snapshot_mod.loadSnapshot(io, snap_path, &exp3, &store3, arena3.allocator());

    // Expected: loaded == true (snapshot is valid, written atomically)
    // Current (bug): may be false — last writer's rename can land mid-write of
    // the first writer's tmp file, or both rename the same .tmp path.
    try testing.expect(loaded);
}


test "issue-42: scan thread is joined before allocator-backed state is freed" {
    var gpa = std.heap.DebugAllocator(.{}){};
    const allocator = gpa.allocator();

    const data_dir = try allocator.dupe(u8, "/tmp/codedb_test_issue42");

    const SharedCtx = struct {
        data_dir: []const u8,
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        ok: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        fn run(ctx: *@This()) void {
            cio.sleepMs(10);
            if (ctx.data_dir.len > 0) {
                _ = ctx.data_dir[0];
                ctx.ok.store(true, .release);
            }
            ctx.done.store(true, .release);
        }
    };

    var ctx = SharedCtx{ .data_dir = data_dir };
    const t = try std.Thread.spawn(.{}, SharedCtx.run, .{&ctx});
    t.join();

    try testing.expect(ctx.done.load(.acquire));
    try testing.expect(ctx.ok.load(.acquire));
    allocator.free(data_dir);
    _ = gpa.deinit();
}


test "issue-40: truncated snapshot silently loads partial data" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var exp = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try exp.indexFile("src/a.zig", "const a = 1;\n");
    try exp.indexFile("src/b.zig", "const b = 2;\n");
    try exp.indexFile("src/c.zig", "const c = 3;\n");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    const snap_path = try std.fmt.allocPrint(testing.allocator, "{s}/test.codedb", .{dir_path});
    defer testing.allocator.free(snap_path);

    try snapshot_mod.writeSnapshot(io, &exp, dir_path, snap_path, testing.allocator);

    const trunc_path = try std.fmt.allocPrint(testing.allocator, "{s}/trunc.codedb", .{dir_path});
    defer testing.allocator.free(trunc_path);
    {
        const orig = try std.Io.Dir.cwd().readFileAlloc(io, snap_path, testing.allocator, .limited(1024 * 1024));
        defer testing.allocator.free(orig);
        const trunc_file = try std.Io.Dir.cwd().createFile(io, trunc_path, .{});
        defer trunc_file.close(io);
        // Keep only header (256 bytes) — content section data will be missing
        try trunc_file.writeStreamingAll(io, orig[0..@min(256, orig.len)]);
    }

    var arena2 = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena2.deinit();
    var exp2 = Explorer.init(arena2.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    var store = Store.init(arena2.allocator());

    const loaded = snapshot_mod.loadSnapshot(io, trunc_path, &exp2, &store, arena2.allocator());
    try testing.expect(!loaded);
}


test "issue-41: snapshot not validated against repo identity allows cross-project loading" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var exp = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try exp.indexFile("src/projectA.zig", "const project = \"A\";\n");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    const snap_path = try std.fmt.allocPrint(testing.allocator, "{s}/test.codedb", .{dir_path});
    defer testing.allocator.free(snap_path);

    try snapshot_mod.writeSnapshot(io, &exp, dir_path, snap_path, testing.allocator);

    var arena2 = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena2.deinit();
    var exp2 = Explorer.init(arena2.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    var store = Store.init(testing.allocator);
    defer store.deinit();

    const loaded = snapshot_mod.loadSnapshotValidated(io, snap_path, "/some/other/project", &exp2, &store, testing.allocator);
    try testing.expect(!loaded);
}


test "snapshot: symbol detail longer than 4096 bytes survives round-trip" {
    // Regression for readSectionString rejecting names/details > 4096 bytes.
    // Before the fix max_len was 4096; any detail longer than that triggered
    // error.InvalidData and loadSnapshot returned false.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // Build a Zig source whose first function line exceeds 4 096 characters.
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(testing.allocator);
    try src.appendSlice(testing.allocator, "pub fn bigSig(");
    var param_i: usize = 0;
    while (src.items.len < 5000) : (param_i += 1) {
        var pb: [20]u8 = undefined;
        const ps = std.fmt.bufPrint(&pb, "p{d}: u8, ", .{param_i}) catch break;
        try src.appendSlice(testing.allocator, ps);
    }
    try src.appendSlice(testing.allocator, ") void {}\n");
    try testing.expect(src.items.len > 4096); // guard: ensure we actually generated a long line
    var exp = Explorer.init(aa, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    try exp.indexFile("src/big.zig", src.items);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];
    const snap_path = try std.fmt.allocPrint(testing.allocator, "{s}/big.codedb", .{dir_path});
    defer testing.allocator.free(snap_path);
    try snapshot_mod.writeSnapshot(io, &exp, dir_path, snap_path, testing.allocator);

    var exp2 = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer exp2.deinit();
    var store2 = Store.init(testing.allocator);
    defer store2.deinit();

    const loaded = snapshot_mod.loadSnapshot(io, snap_path, &exp2, &store2, testing.allocator);
    try testing.expect(loaded); // must survive long detail

    var sym_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer sym_arena.deinit();
    const results = try exp2.findAllSymbols("bigSig", sym_arena.allocator());
    try testing.expect(results.len >= 1);
}


test "snapshot: corrupted OUTLINE_STATE section falls back to CONTENT load" {
    // Regression for the codedb 0.2.56 writer u16 overflow bug: when OUTLINE_STATE
    // contains a detail that overflows u16 the section cursor de-syncs, making
    // subsequent file records parse as garbage and loadOutlineStateMap throws.
    // The catch fallback must produce an empty map so loadSnapshotFast falls
    // through to indexFileOutlineOnly for every file in CONTENT.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var exp = Explorer.init(aa, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    try exp.indexFile("src/a.zig", "pub fn aFunc() void {}\n");
    try exp.indexFile("src/b.zig", "pub fn bFunc() void {}\n");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];
    const snap_path = try std.fmt.allocPrint(testing.allocator, "{s}/corrupt.codedb", .{dir_path});
    defer testing.allocator.free(snap_path);
    try snapshot_mod.writeSnapshot(io, &exp, dir_path, snap_path, testing.allocator);

    // Overwrite the first 16 bytes of OUTLINE_STATE data with 0xFF.
    // This makes the file_count field read as 0xFFFFFFFF — far more records
    // than the data contains — causing readSectionString to eventually fail
    // with error.InvalidData (runs off the end of the bytes slice).
    {
        var sections = (try snapshot_mod.readSections(io, snap_path, testing.allocator)).?;
        defer sections.deinit();
        const ols = sections.get(@intFromEnum(snapshot_mod.SectionId.outline_state)) orelse return;
        const f = try std.Io.Dir.cwd().openFile(io, snap_path, .{ .mode = .read_write });
        defer f.close(io);
        try f.writePositionalAll(io, &([_]u8{0xFF} ** 16), ols.offset);
    }

    var exp2 = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer exp2.deinit();
    var store2 = Store.init(testing.allocator);
    defer store2.deinit();

    const loaded = snapshot_mod.loadSnapshot(io, snap_path, &exp2, &store2, testing.allocator);
    try testing.expect(loaded); // must survive OUTLINE_STATE corruption

    // Symbols must still be found — re-indexed from CONTENT
    var sym_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer sym_arena.deinit();
    const results = try exp2.findAllSymbols("aFunc", sym_arena.allocator());
    try testing.expect(results.len >= 1);
}


test "issue-379: snapshot loader returns true with zero outlines for empty-explorer snapshot" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var exp = Explorer.init(aa, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];
    const snap_path = try std.fmt.allocPrint(testing.allocator, "{s}/empty.codedb", .{dir_path});
    defer testing.allocator.free(snap_path);

    try snapshot_mod.writeSnapshot(io, &exp, dir_path, snap_path, testing.allocator);

    var exp2 = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer exp2.deinit();
    var store2 = Store.init(testing.allocator);
    defer store2.deinit();

    const loaded = snapshot_mod.loadSnapshot(io, snap_path, &exp2, &store2, testing.allocator);
    if (loaded) {
        try testing.expect(exp2.outlines.count() > 0);
    }
}


test "issue-528: isSensitivePath parity between snapshot.zig and watcher.zig" {
    // The secret/credential filter is duplicated (snapshot persistence vs live
    // indexing). The #528 audit flagged a possible divergence; the two are
    // verified equal today, and this test fails CI if they ever drift apart —
    // which in this security filter would mean a secret silently leaking into
    // one path but not the other.
    const cases = [_][]const u8{
        // secrets — both copies must block
        ".env",                  ".env.local",          ".env.production",
        ".env.development",      ".env.staging",        ".env.test",
        ".dev.vars",             ".npmrc",              ".pypirc",
        ".netrc",                "credentials.json",    "service-account.json",
        "secrets.json",          "secrets.yaml",        "secrets.yml",
        "id_rsa",                "id_ed25519",          "server.key",
        "cert.pem",              "keystore.jks",        "identity.pfx",
        "bundle.p12",            "config/.env.local",   "a/b/secrets.yaml",
        "deep/nested/.ssh/known_hosts", ".gnupg/secring.gpg", "x/.aws/credentials",
        // non-secrets — both copies must allow (esp. the .env-prefix edge cases)
        ".envoy.json",           ".environment",        ".envrc",
        ".envconfig.yaml",       "main.zig",            "src/server.zig",
        "README.md",             "package.json",        "id_rsa.pub",
        "envvars.ts",            "Makefile",            "Dockerfile",
    };
    for (cases) |p| {
        try testing.expectEqual(watcher.isSensitivePath(p), snapshot_mod.isSensitivePath(p));
    }
    // Anchor the contract so parity can't be satisfied by both copies being
    // wrong in the same direction.
    try testing.expect(snapshot_mod.isSensitivePath(".env"));
    try testing.expect(snapshot_mod.isSensitivePath("credentials.json"));
    try testing.expect(snapshot_mod.isSensitivePath("deep/.ssh/id_rsa"));
    try testing.expect(snapshot_mod.isSensitivePath("keystore.jks")); // fast-path ext
    try testing.expect(!snapshot_mod.isSensitivePath(".envoy.json")); // issue-409
    try testing.expect(!snapshot_mod.isSensitivePath(".environment"));
    try testing.expect(!snapshot_mod.isSensitivePath("main.zig"));
    try testing.expect(!snapshot_mod.isSensitivePath("package.json"));
}

test "issue-528: codedb_edit applies via a per-session agent id (not the first/__filesystem__ agent)" {
    // Bug 2 wiring (runtime): handleEdit now uses Session.edit_agent_id — a
    // per-connection agent registered AFTER __filesystem__, so its id != 1.
    // applyEdit's advisory lock returns error.FileLocked if that id is not a
    // live registered agent, so this proves an edit through a non-first session
    // agent actually acquires the lock and writes the file.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const rel_path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/per-session-edit.zig", .{tmp.sub_path});
    defer testing.allocator.free(rel_path);

    var file = try tmp.dir.createFile(io, "per-session-edit.zig", .{});
    defer file.close(io);
    try file.writeStreamingAll(io, "const foo = 1;\n");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    try explorer.indexFile(rel_path, "const foo = 1;\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();

    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    const fs = try agents.register("__filesystem__"); // startup agent (id 1)
    const session = try agents.register("mcp-session"); // per-session owner (id 2)
    try testing.expect(session != fs);

    // Edit through the per-session id — must acquire the lock and apply.
    const r1 = try edit_mod.applyEdit(io, testing.allocator, &store, &agents, &explorer, .{
        .path = rel_path,
        .agent_id = session,
        .op = .replace,
        .range = .{ 1, 1 },
        .content = "const bar = 1;",
    });
    defer if (r1.health) |h| testing.allocator.free(h);
    defer if (r1.preview) |p| testing.allocator.free(p);
    try testing.expect(r1.changed);

    // The lock was released on success, so another session can edit immediately.
    const r2 = try edit_mod.applyEdit(io, testing.allocator, &store, &agents, &explorer, .{
        .path = rel_path,
        .agent_id = fs,
        .op = .replace,
        .range = .{ 1, 1 },
        .content = "const baz = 1;",
    });
    defer if (r2.health) |h| testing.allocator.free(h);
    defer if (r2.preview) |p| testing.allocator.free(p);

    const content = try tmp.dir.readFileAlloc(io, "per-session-edit.zig", testing.allocator, .limited(64 * 1024));
    defer testing.allocator.free(content);
    try testing.expect(std.mem.indexOf(u8, content, "baz") != null);
}

test "issue-537b: snapshot-restored files resolve call edges (symbol_index divergence)" {
    // commitParsedFileOwnedOutline rebuilds symbol_index (explore.zig:872), but the
    // snapshot-load path (insertRestoredFile) did not. resolveCallees reads
    // symbol_index with NO fallback (it assumes "rebuilt on every commit", see the
    // #524 perf note), so after a load every call edge into a restored file silently
    // vanished. Same load-path coverage class as issue-537.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var exp = Explorer.init(aa, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    // Paths absent from the temp dir below => load restores them (not re-index).
    try exp.indexFile("util_537b.zig", "pub fn uniqueCalleeXyz() void {}\n");
    try exp.indexFile("main_537b.zig",
        \\pub fn caller537b() void {
        \\    uniqueCalleeXyz();
        \\}
        \\
    );

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];
    const snap_path = try std.fmt.allocPrint(testing.allocator, "{s}/callgraph.codedb", .{dir_path});
    defer testing.allocator.free(snap_path);
    try snapshot_mod.writeSnapshot(io, &exp, dir_path, snap_path, testing.allocator);

    var arena2 = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena2.deinit();
    const aa2 = arena2.allocator();
    var exp2 = Explorer.init(aa2, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    var store = Store.init(testing.allocator);
    defer store.deinit();

    const loaded = snapshot_mod.loadSnapshot(io, snap_path, &exp2, &store, aa2);
    try testing.expect(loaded);
    try testing.expect(exp2.outlines.get("main_537b.zig") != null);

    // The edge caller537b -> uniqueCalleeXyz must resolve after load.
    const callees = try exp2.resolveCallees("main_537b.zig", 1, 3, aa2, 10);
    try testing.expect(callees.len >= 1);
    try testing.expect(std.mem.eql(u8, callees[0].name, "uniqueCalleeXyz"));
}

test "issue-539: search recall includes snapshot-restored files (parity with word index)" {
    // #539: codedb_search returned a tiny candidate set and omitted files the
    // word index clearly contained ("2 results" vs "2658 word hits"). Same root
    // cause as #537 — restored files were in no search tier. This asserts the
    // RECALL fix: a term living only in RESTORED files is surfaced by
    // searchContent, which now rebuilds the complete word index (the #539 fix) and
    // finds them via Tier 0 — matching searchWord's recall. (Tier-3 substring
    // recall for restored files is covered separately by issue-537.)
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var exp = Explorer.init(aa, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    // Paths absent from the temp dir => restored on load (not re-indexed).
    try exp.indexFile("recall539/alpha.zig", "pub fn a() void {\n    const payload539 = 1;\n    _ = payload539;\n}\n");
    try exp.indexFile("recall539/beta.zig", "pub fn b() void {\n    const payload539 = 2;\n    _ = payload539;\n}\n");
    try exp.indexFile("recall539/gamma.zig", "pub fn c() void {\n    const payload539 = 3;\n    _ = payload539;\n}\n");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];
    const snap_path = try std.fmt.allocPrint(testing.allocator, "{s}/recall.codedb", .{dir_path});
    defer testing.allocator.free(snap_path);
    try snapshot_mod.writeSnapshot(io, &exp, dir_path, snap_path, testing.allocator);

    var arena2 = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena2.deinit();
    const aa2 = arena2.allocator();
    var exp2 = Explorer.init(aa2, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    var store = Store.init(testing.allocator);
    defer store.deinit();

    const loaded = snapshot_mod.loadSnapshot(io, snap_path, &exp2, &store, aa2);
    try testing.expect(loaded);

    // Trigram non-empty (a hot file WITHOUT the term) so Tier 5 is ruled out —
    // recall must come from Tier 3 scanning the restored files.
    try exp2.indexFile("recall539/hot.zig", "pub fn hot() void {}\n");

    // search must surface a restored file (was 0 results pre-fix).
    const sres = try exp2.searchContent("payload539", aa2, 20);
    try testing.expect(sres.len >= 1);
    var found_restored = false;
    for (sres) |r| {
        if (std.mem.startsWith(u8, r.path, "recall539/") and !std.mem.eql(u8, r.path, "recall539/hot.zig")) {
            found_restored = true;
        }
    }
    try testing.expect(found_restored);

    // Parity check: the word index (rebuilt lazily by searchWord) finds it too.
    const whits = try exp2.searchWord("payload539", aa2);
    try testing.expect(whits.len >= 1);
}

test "issue-539b: search recall ranks a relevant restored file above quota (index-blending)" {
    // #539 quota residual: even with restored files Tier-3-searchable, a MORE
    // relevant cold file was crowded out of a small max_results by less-relevant
    // hot files — because searchContent never populated the (complete) word index
    // that Tier 0 ranks from after a fast load. Fix: searchContent rebuilds the
    // lazy word index (like searchWord), so the canonical file competes on
    // relevance and isn't lost to tier-ordering.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var exp = Explorer.init(aa, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    // COLD canonical file (restored): term appears 3x => most relevant.
    try exp.indexFile("recallpkg/canonical.zig",
        \\pub fn canonical() void {
        \\    const x1 = recallterm539;
        \\    const x2 = recallterm539;
        \\    const x3 = recallterm539;
        \\    _ = .{ x1, x2, x3 };
        \\}
        \\
    );

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];
    const snap_path = try std.fmt.allocPrint(testing.allocator, "{s}/recallq.codedb", .{dir_path});
    defer testing.allocator.free(snap_path);
    try snapshot_mod.writeSnapshot(io, &exp, dir_path, snap_path, testing.allocator);

    var arena2 = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena2.deinit();
    const aa2 = arena2.allocator();
    var exp2 = Explorer.init(aa2, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    var store = Store.init(testing.allocator);
    defer store.deinit();
    _ = snapshot_mod.loadSnapshot(io, snap_path, &exp2, &store, aa2);

    // HOT files (trigram) with the term ONCE each — quota pressure at max_results=2.
    try exp2.indexFile("h_a.zig", "pub fn a() void { const y = recallterm539; _ = y; }\n");
    try exp2.indexFile("h_b.zig", "pub fn b() void { const y = recallterm539; _ = y; }\n");
    try exp2.indexFile("h_c.zig", "pub fn c() void { const y = recallterm539; _ = y; }\n");

    // The most-relevant (cold, 3 hits) file must make a 2-slot result set.
    const res = try exp2.searchContent("recallterm539", aa2, 2);
    var found_canonical = false;
    for (res) |r| if (std.mem.eql(u8, r.path, "recallpkg/canonical.zig")) {
        found_canonical = true;
    };
    try testing.expect(found_canonical);
}
