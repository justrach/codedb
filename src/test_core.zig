const std = @import("std");
const cio = @import("cio.zig");
const testing = std.testing;
const io = std.testing.io;
const Store = @import("store.zig").Store;
const bootstrap = @import("bootstrap.zig");
const ChangeEntry = @import("store.zig").ChangeEntry;
const AgentRegistry = @import("agent.zig").AgentRegistry;
const Config = @import("config.zig").Config;
const explore = @import("explore.zig");
const Explorer = explore.Explorer;
const ContentCache = @import("hot_cache.zig").ContentCache;
const git = @import("git.zig");
const builtin = @import("builtin");
const project_file = @import("project_file.zig");

test "project file reads reject final-component symlinks without hiding regular files" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var outside = testing.tmpDir(.{});
    defer outside.cleanup();
    try outside.dir.writeFile(io, .{ .sub_path = "outside.txt", .data = "OUTSIDE_READ_CANARY\n" });
    var outside_buf: [std.fs.max_path_bytes]u8 = undefined;
    const outside_path = outside_buf[0..try outside.dir.realPathFile(io, "outside.txt", &outside_buf)];

    var project = testing.tmpDir(.{});
    defer project.cleanup();
    try project.dir.createDirPath(io, "src");
    try project.dir.createDirPath(io, "real_dir");
    try project.dir.createDirPath(io, ".ssh");
    try project.dir.writeFile(io, .{ .sub_path = "src/ordinary.txt", .data = "ORDINARY_READ_CANARY\n" });
    try project.dir.writeFile(io, .{ .sub_path = "real_dir/inside.txt", .data = "IN_ROOT_DIRECTORY_ALIAS_CANARY\n" });
    try project.dir.writeFile(io, .{ .sub_path = ".ssh/config", .data = "SENSITIVE_DIRECTORY_ALIAS_CANARY\n" });
    try project.dir.writeFile(io, .{ .sub_path = ".env", .data = "SENSITIVE_READ_CANARY\n" });
    var src = try project.dir.openDir(io, "src", .{});
    defer src.close(io);
    src.symLink(io, outside_path, "outside_alias.txt", .{}) catch |err| switch (err) {
        error.AccessDenied => return error.SkipZigTest,
        else => return err,
    };
    try src.symLink(io, "../.env", "sensitive_alias.txt", .{});
    try project.dir.symLink(io, "real_dir", "dir_alias", .{});
    try project.dir.symLink(io, ".ssh", "sensitive_dir_alias", .{});

    const ordinary = try project_file.readAllocNoFollow(io, project.dir, "src/ordinary.txt", testing.allocator, .limited(1024));
    defer testing.allocator.free(ordinary);
    try testing.expectEqualStrings("ORDINARY_READ_CANARY\n", ordinary);

    const through_safe_dir = try project_file.readAllocNoFollow(io, project.dir, "dir_alias/inside.txt", testing.allocator, .limited(1024));
    defer testing.allocator.free(through_safe_dir);
    try testing.expectEqualStrings("IN_ROOT_DIRECTORY_ALIAS_CANARY\n", through_safe_dir);

    for ([_][]const u8{ "src/outside_alias.txt", "src/sensitive_alias.txt", "sensitive_dir_alias/config", ".env", "../outside.txt", "src//ordinary.txt" }) |path| {
        if (project_file.readAllocNoFollow(io, project.dir, path, testing.allocator, .limited(1024))) |unexpected| {
            testing.allocator.free(unexpected);
            return error.TestExpectedError;
        } else |_| {}
    }

    // The policy is applied before cache lookup too: a forged/restored cache
    // entry cannot make a direct or semantic caller recover sensitive bytes.
    var guarded = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer guarded.deinit();
    try guarded.indexFile(".env", "CACHED_SENSITIVE_CANARY\n");
    try testing.expect((try guarded.getContent(".env", testing.allocator)) == null);
}

test "store: record and retrieve snapshots" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    const seq1 = try store.recordSnapshot("foo.zig", 100, 0xABC);
    const seq2 = try store.recordSnapshot("bar.zig", 200, 0xDEF);

    try testing.expect(seq1 == 1);
    try testing.expect(seq2 == 2);
    try testing.expect(store.currentSeq() == 2);
}

test "store: content fingerprint is deterministic and detects same-size edits" {
    var first = Store.init(testing.allocator);
    defer first.deinit();
    _ = try first.recordSnapshot("src/b.zig", 12, 0xBBBB);
    _ = try first.recordSnapshot("src/a.zig", 12, 0xAAAA);
    const before = try first.contentFingerprint(testing.allocator);

    // Insertion order and process-local sequence numbers are deliberately not
    // part of the identity, so a freshly loaded store produces the same value.
    var reordered = Store.init(testing.allocator);
    defer reordered.deinit();
    _ = try reordered.recordSnapshot("src/a.zig", 12, 0xAAAA);
    _ = try reordered.recordSnapshot("src/b.zig", 12, 0xBBBB);
    try testing.expectEqual(before, try reordered.contentFingerprint(testing.allocator));

    // The size stays constant but the watcher hash changes, which must stale a
    // semantic sidecar built from the old source bytes.
    _ = try first.recordSnapshot("src/a.zig", 12, 0xCCCC);
    try testing.expect(before != try first.contentFingerprint(testing.allocator));

    // A transient file that is created and then removed must not change the
    // identity of the final live tree.
    _ = try reordered.recordSnapshot("src/transient.zig", 8, 0xDDDD);
    _ = try reordered.recordDelete("src/transient.zig", 0);
    try testing.expectEqual(before, try reordered.contentFingerprint(testing.allocator));
}

test "store: cold scan refines placeholder hash without publishing an edit" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    _ = try store.recordSnapshot("src/live.zig", 12, 0);
    const sequence = store.currentSeq();
    const placeholder = try store.contentFingerprint(testing.allocator);
    try testing.expect(store.refineLatestSnapshotHash("src/live.zig", 12, 0xCAFE));
    try testing.expectEqual(sequence, store.currentSeq());
    try testing.expect(placeholder != try store.contentFingerprint(testing.allocator));
    try testing.expectEqual(@as(u64, 0xCAFE), store.getLatest("src/live.zig").?.hash);

    // Refuse to overwrite an already authoritative identity or a mismatched
    // stat record; a concurrent watcher update therefore wins safely.
    try testing.expect(!store.refineLatestSnapshotHash("src/live.zig", 12, 0xBEEF));
    _ = try store.recordSnapshot("src/changed.zig", 8, 0);
    try testing.expect(!store.refineLatestSnapshotHash("src/changed.zig", 9, 0xABCD));
}

test "store: path-scoped content identity excludes stat-only records" {
    var with_extra = Store.init(testing.allocator);
    defer with_extra.deinit();
    _ = try with_extra.recordSnapshot("src/a.zig", 12, 0xAAAA);
    _ = try with_extra.recordSnapshot("ignored.bin", 900, 0);

    var parsed_only = Store.init(testing.allocator);
    defer parsed_only.deinit();
    _ = try parsed_only.recordSnapshot("src/a.zig", 12, 0xAAAA);
    const paths = [_][]const u8{"src/a.zig"};
    try testing.expectEqual(
        try parsed_only.contentFingerprintForPaths(&paths),
        try with_extra.contentFingerprintForPaths(&paths),
    );
}

test "semantic-index always forces a live filesystem rescan" {
    try testing.expect(bootstrap.commandForcesRescan("semantic-index"));
    try testing.expect(bootstrap.commandForcesRescan("snapshot"));
    try testing.expect(bootstrap.commandForcesRescan("index"));
    try testing.expect(!bootstrap.commandForcesRescan("context"));
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
    var counts: [64]u8 = @splat(0);
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

test "issue-597: data log compacts orphaned diff ranges and fixes offsets" {
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
    store.max_versions = 2;
    store.compact_min = 1;

    _ = try store.recordEdit("f.zig", 1, .replace, 0x1, 5, "AAAAA");
    _ = try store.recordEdit("f.zig", 1, .replace, 0x2, 5, "BBBBB");
    _ = try store.recordEdit("f.zig", 1, .replace, 0x3, 5, "CCCCC");
    _ = try store.recordEdit("f.zig", 1, .replace, 0x4, 5, "DDDDD");
    // max_versions=2 keeps C and D; A and B are orphaned (10 of 20 bytes),
    // so the post-append check compacts: C -> 0, D -> 5, file truncated to 10.

    const latest = store.getLatest("f.zig").?;
    try testing.expectEqual(@as(?u64, 5), latest.data_offset);
    const prev = store.getAtCursor("f.zig", 3).?;
    try testing.expectEqual(@as(?u64, 0), prev.data_offset);

    const log_file = try std.Io.Dir.cwd().openFile(io, log_path, .{});
    defer log_file.close(io);
    try testing.expectEqual(@as(u64, 10), try log_file.length(io));
    var buf: [5]u8 = undefined;
    _ = try log_file.readPositionalAll(io, &buf, 0);
    try testing.expectEqualStrings("CCCCC", &buf);
    _ = try log_file.readPositionalAll(io, &buf, 5);
    try testing.expectEqualStrings("DDDDD", &buf);
}

test "issue-603: appendVersion failed key dupe leaves a poisoned files entry" {
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1 });
    var store = Store.init(failing.allocator());

    try testing.expectError(error.OutOfMemory, store.recordSnapshot("src/a.zig", 10, 0x1));
    try testing.expectEqual(@as(usize, 0), store.files.count());
    store.deinit();
}

test "issue-550: parseCoChange builds bounded per-file partner lists" {
    const alloc = testing.allocator;
    const log =
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n" ++
        "\n" ++
        "src/a.zig\n" ++
        "src/b.zig\n" ++
        "\n" ++
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n" ++
        "\n" ++
        "src/a.zig\n" ++
        "src/b.zig\n" ++
        "src/c.zig\n" ++
        "\n" ++
        "cccccccccccccccccccccccccccccccccccccccc\n" ++
        "\n" ++
        "src/mega1.zig\n" ++
        "src/mega2.zig\n" ++
        "src/mega3.zig\n" ++
        "src/mega4.zig\n";

    var map = try git.parseCoChange(alloc, log, 3, 8);
    defer git.freeCoChange(&map, alloc);

    const a_partners = map.get("src/a.zig") orelse return testing.expect(false);
    try testing.expectEqual(@as(usize, 2), a_partners.len);
    try testing.expectEqualStrings("src/b.zig", a_partners[0].path);
    try testing.expectEqual(@as(u32, 2), a_partners[0].count);
    try testing.expectEqualStrings("src/c.zig", a_partners[1].path);
    try testing.expectEqual(@as(u32, 1), a_partners[1].count);

    // The 4-file commit exceeds max_files_per_commit=3 — contributes nothing.
    try testing.expect(map.get("src/mega1.zig") == null);

    // max_partners truncates after the count-descending sort.
    var capped = try git.parseCoChange(alloc, log, 3, 1);
    defer git.freeCoChange(&capped, alloc);
    const a_capped = capped.get("src/a.zig") orelse return testing.expect(false);
    try testing.expectEqual(@as(usize, 1), a_capped.len);
    try testing.expectEqualStrings("src/b.zig", a_capped[0].path);
}
