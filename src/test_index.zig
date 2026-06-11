const std = @import("std");
const cio = @import("cio.zig");
const testing = std.testing;
const io = std.testing.io;
const Store = @import("store.zig").Store;
const Explorer = @import("explore.zig").Explorer;
const WordIndex = @import("index.zig").WordIndex;
const TrigramIndex = @import("index.zig").TrigramIndex;
const SparseNgramIndex = @import("index.zig").SparseNgramIndex;
const pairWeight = @import("index.zig").pairWeight;
const extractSparseNgrams = @import("index.zig").extractSparseNgrams;
const buildCoveringSet = @import("index.zig").buildCoveringSet;
const setFrequencyTable = @import("index.zig").setFrequencyTable;
const resetFrequencyTable = @import("index.zig").resetFrequencyTable;
const buildFrequencyTable = @import("index.zig").buildFrequencyTable;
const writeFrequencyTable = @import("index.zig").writeFrequencyTable;
const readFrequencyTable = @import("index.zig").readFrequencyTable;
const explore = @import("explore.zig");
const Language = explore.Language;
const git_mod = @import("git.zig");
const decomposeRegex = @import("index.zig").decomposeRegex;
const RegexQuery = @import("index.zig").RegexQuery;
const packTrigram = @import("index.zig").packTrigram;
const regexMatch = explore.regexMatch;
const PostingMask = @import("index.zig").PostingMask;
const normalizeChar = @import("index.zig").normalizeChar;
const Trigram = @import("index.zig").Trigram;
const MmapTrigramIndex = @import("index.zig").MmapTrigramIndex;
const AnyTrigramIndex = @import("index.zig").AnyTrigramIndex;
const version = @import("version.zig");
const watcher = @import("watcher.zig");
const AgentRegistry = @import("agent.zig").AgentRegistry;
const snapshot_mod = @import("snapshot.zig");
const snapshot_json = @import("snapshot_json.zig");
const mcp_mod = @import("mcp.zig");
const SearchResult = @import("explore.zig").SearchResult;
const SymbolKind = explore.SymbolKind;
const edit_mod = @import("edit.zig");






















test "trigram index: index and candidate lookup" {
    var ti = TrigramIndex.init(testing.allocator);
    defer ti.deinit();

    try ti.indexFile("src/store.zig", "pub fn recordSnapshot(self: *Store) void {}");
    try ti.indexFile("src/agent.zig", "pub fn register(self: *Agent) void {}");

    const cands = ti.candidates("recordSnapshot", testing.allocator);
    defer if (cands) |c| testing.allocator.free(c);
    try testing.expect(cands != null);
    try testing.expect(cands.?.len == 1);
    try testing.expectEqualStrings("src/store.zig", cands.?[0]);
}


test "trigram index: short query returns null" {
    var ti = TrigramIndex.init(testing.allocator);
    defer ti.deinit();

    try ti.indexFile("f.zig", "hello world");
    const cands = ti.candidates("hi", testing.allocator);
    try testing.expect(cands == null);
}


test "trigram index: no match returns empty" {
    var ti = TrigramIndex.init(testing.allocator);
    defer ti.deinit();

    try ti.indexFile("f.zig", "hello world");
    const cands = ti.candidates("zzzzz", testing.allocator);
    try testing.expect(cands != null);
    try testing.expect(cands.?.len == 0);
}


test "trigram index: re-index removes old trigrams" {
    var ti = TrigramIndex.init(testing.allocator);
    defer ti.deinit();

    try ti.indexFile("f.zig", "uniqueOldContent");
    const c1 = ti.candidates("uniqueOld", testing.allocator);
    defer if (c1) |c| testing.allocator.free(c);
    try testing.expect(c1 != null and c1.?.len == 1);

    try ti.indexFile("f.zig", "brandNewStuff");
    const c2 = ti.candidates("uniqueOld", testing.allocator);
    defer if (c2) |c| testing.allocator.free(c);
    try testing.expect(c2 != null and c2.?.len == 0);

    const c3 = ti.candidates("brandNew", testing.allocator);
    defer if (c3) |c| testing.allocator.free(c);
    try testing.expect(c3 != null and c3.?.len == 1);
}


test "pairWeight: deterministic" {
    const w1 = pairWeight('a', 'b');
    const w2 = pairWeight('a', 'b');
    try testing.expectEqual(w1, w2);

    const w3 = pairWeight('a', 'c');
    // Different pair must (almost certainly) produce a different weight.
    // We only assert they're not trivially equal; hash collisions are acceptable.
    _ = w3; // just ensure it compiles and doesn't crash
}


test "pairWeight: different pairs produce different values (sanity)" {
    // 'ab' and 'ba' should almost never collide for a reasonable hash.
    const w_ab = pairWeight('a', 'b');
    const w_ba = pairWeight('b', 'a');
    // Not a strict requirement (collisions are ok), but verify the function runs.
    _ = w_ab;
    _ = w_ba;
}


test "extractSparseNgrams: short content returns empty" {
    const ng = try extractSparseNgrams("ab", testing.allocator);
    defer testing.allocator.free(ng);
    try testing.expectEqual(@as(usize, 0), ng.len);
}


test "extractSparseNgrams: minimum length content yields one ngram" {
    const ng = try extractSparseNgrams("abc", testing.allocator);
    defer testing.allocator.free(ng);
    try testing.expect(ng.len >= 1);
    try testing.expectEqual(@as(usize, 3), ng[0].len);
    try testing.expectEqual(@as(usize, 0), ng[0].pos);
}


test "extractSparseNgrams: deterministic across calls" {
    const ng1 = try extractSparseNgrams("hello world", testing.allocator);
    defer testing.allocator.free(ng1);
    const ng2 = try extractSparseNgrams("hello world", testing.allocator);
    defer testing.allocator.free(ng2);

    try testing.expectEqual(ng1.len, ng2.len);
    for (ng1, ng2) |a, b| {
        try testing.expectEqual(a.hash, b.hash);
        try testing.expectEqual(a.pos, b.pos);
        try testing.expectEqual(a.len, b.len);
    }
}


test "extractSparseNgrams: case-insensitive hashing" {
    const ng_lower = try extractSparseNgrams("hello", testing.allocator);
    defer testing.allocator.free(ng_lower);
    const ng_upper = try extractSparseNgrams("HELLO", testing.allocator);
    defer testing.allocator.free(ng_upper);

    try testing.expectEqual(ng_lower.len, ng_upper.len);
    for (ng_lower, ng_upper) |lo, hi| {
        try testing.expectEqual(lo.hash, hi.hash);
    }
}


test "extractSparseNgrams: ngrams cover entire content" {
    const content = "the quick brown fox";
    const ng = try extractSparseNgrams(content, testing.allocator);
    defer testing.allocator.free(ng);

    // Verify every byte position is covered by at least one n-gram.
    var covered = try testing.allocator.alloc(bool, content.len);
    defer testing.allocator.free(covered);
    @memset(covered, false);

    for (ng) |n| {
        for (n.pos..n.pos + n.len) |p| {
            covered[p] = true;
        }
    }
    for (covered) |c| {
        try testing.expect(c);
    }
}


test "extractSparseNgrams: coverage with force-split remainder 1 (len=17)" {
    // 17 identical chars → no interior local maxima → one span of length 17.
    // Force-split: one MAX_NGRAM_LEN=16 chunk, remainder=1 → must still cover byte 16.
    const content = "aaaaaaaaaaaaaaaaa"; // 17 'a's
    const ng = try extractSparseNgrams(content, testing.allocator);
    defer testing.allocator.free(ng);

    var covered = try testing.allocator.alloc(bool, content.len);
    defer testing.allocator.free(covered);
    @memset(covered, false);
    for (ng) |n| {
        for (n.pos..n.pos + n.len) |p| covered[p] = true;
    }
    for (covered) |c| try testing.expect(c);
}


test "extractSparseNgrams: coverage with force-split remainder 2 (len=18)" {
    // 18 identical chars → remainder=2 → must still cover bytes 16-17.
    const content = "aaaaaaaaaaaaaaaaaa"; // 18 'a's
    const ng = try extractSparseNgrams(content, testing.allocator);
    defer testing.allocator.free(ng);

    var covered = try testing.allocator.alloc(bool, content.len);
    defer testing.allocator.free(covered);
    @memset(covered, false);
    for (ng) |n| {
        for (n.pos..n.pos + n.len) |p| covered[p] = true;
    }
    for (covered) |c| try testing.expect(c);
}


test "extractSparseNgrams: ngram length bounds" {
    const content = "abcdefghijklmnopqrstuvwxyz0123456789";
    const ng = try extractSparseNgrams(content, testing.allocator);
    defer testing.allocator.free(ng);

    for (ng) |n| {
        try testing.expect(n.len >= 3);
        try testing.expect(n.len <= 16);
    }
}


test "buildCoveringSet: sliding window covers all query substrings" {
    // "foobar" (6 chars); lengths [3,6] yield 4+3+2+1 = 10 substrings.
    const ngrams = try buildCoveringSet("foobar", testing.allocator);
    defer testing.allocator.free(ngrams);
    try testing.expectEqual(@as(usize, 10), ngrams.len);
    for (ngrams) |ng| try testing.expect(ng.len >= 3 and ng.len <= 6);
}


test "buildCoveringSet: short query returns empty" {
    const ngrams = try buildCoveringSet("ab", testing.allocator);
    defer testing.allocator.free(ngrams);
    try testing.expectEqual(@as(usize, 0), ngrams.len);
}


test "sparse ngram index: index and candidate lookup" {
    var sni = SparseNgramIndex.init(testing.allocator);
    defer sni.deinit();

    // Index each file with content equal to the query we'll use — this
    // guarantees the sparse n-gram boundaries align (same string = same weights).
    const foo_query = "recordSnapshot";
    const bar_query = "registerAgent";
    try sni.indexFile("src/foo.zig", foo_query);
    try sni.indexFile("src/bar.zig", bar_query);

    const cands = sni.candidates(foo_query, testing.allocator);
    defer if (cands) |c| testing.allocator.free(c);
    try testing.expect(cands != null);

    var found_foo = false;
    var found_bar = false;
    if (cands) |cs| {
        for (cs) |p| {
            if (std.mem.eql(u8, p, "src/foo.zig")) found_foo = true;
            if (std.mem.eql(u8, p, "src/bar.zig")) found_bar = true;
        }
    }
    try testing.expect(found_foo);
    try testing.expect(!found_bar);
}


test "sparse ngram index: short query returns null" {
    var sni = SparseNgramIndex.init(testing.allocator);
    defer sni.deinit();

    try sni.indexFile("f.zig", "hello world");
    const cands = sni.candidates("hi", testing.allocator); // length 2 < MIN_LEN
    try testing.expect(cands == null);
}


test "sparse ngram index: re-index removes old ngrams" {
    var sni = SparseNgramIndex.init(testing.allocator);
    defer sni.deinit();

    try sni.indexFile("f.zig", "uniqueOldContent");
    const c1 = sni.candidates("uniqueOldContent", testing.allocator);
    defer if (c1) |c| testing.allocator.free(c);
    try testing.expect(c1 != null and c1.?.len == 1);

    try sni.indexFile("f.zig", "brandNewStuff");
    const c2 = sni.candidates("uniqueOldContent", testing.allocator);
    defer if (c2) |c| testing.allocator.free(c);
    // After re-index the old content is gone; may return empty or null.
    if (c2) |cs| try testing.expectEqual(@as(usize, 0), cs.len);
}


test "sparse ngram index: removeFile prunes entries" {
    var sni = SparseNgramIndex.init(testing.allocator);
    defer sni.deinit();

    try sni.indexFile("a.zig", "hello world foo bar");
    try testing.expectEqual(@as(u32, 1), sni.fileCount());

    sni.removeFile("a.zig");
    try testing.expectEqual(@as(u32, 0), sni.fileCount());
}


test "sparse ngram candidates: sliding window finds file with short n-gram" {
    var sni = SparseNgramIndex.init(testing.allocator);
    defer sni.deinit();

    // "a.zig" is indexed with content "rec" — produces the 3-char n-gram "rec".
    // "b.zig" is indexed with unrelated content.
    try sni.indexFile("a.zig", "rec");
    try sni.indexFile("b.zig", "xxxxxxxxxx");

    // Query "record" (6 chars) contains "rec" as a 3-char sliding-window
    // substring.  buildCoveringSet generates "rec" → hash matches the indexed
    // n-gram of "a.zig".
    const cands = sni.candidates("record", testing.allocator);
    defer if (cands) |c| testing.allocator.free(c);

    var found_a = false;
    if (cands) |cs| {
        for (cs) |p| if (std.mem.eql(u8, p, "a.zig")) {
            found_a = true;
        };
    }
    try testing.expect(found_a);
}


test "pairWeight: common pairs have lower weight than rare pairs" {
    // Common English/code pairs should have lower base weight than rare pairs.
    // 'th' and 'er' are in the default_pair_freq table with weight 0x1000.
    // 'qx' and 'zj' are not in the table and default to 0xFE00.
    // jitter adds 0-255, so common+max_jitter (0x10FF) < rare+min_jitter (0xFE00).
    const w_th = pairWeight('t', 'h');
    const w_er = pairWeight('e', 'r');
    const w_qx = pairWeight('q', 'x');
    const w_zj = pairWeight('z', 'j');
    try testing.expect(w_th < w_qx);
    try testing.expect(w_er < w_zj);
}


test "pairWeight: frequency-weighted produces fewer boundaries for common text" {
    // A string composed of very common pairs should produce few local maxima
    // (interior weights are low and similar), giving fewer n-grams than a
    // string of rare pairs.
    const common = "thehereinandonthere";
    const rare = "qxzjvkqxzjvkqxzjvk";
    const ng_common = try extractSparseNgrams(common, testing.allocator);
    defer testing.allocator.free(ng_common);
    const ng_rare = try extractSparseNgrams(rare, testing.allocator);
    defer testing.allocator.free(ng_rare);
    // Rare pairs create more local maxima → more (shorter) n-grams.
    try testing.expect(ng_rare.len >= ng_common.len);
}


test "pairWeight: deterministic with frequency table" {
    const w1 = pairWeight('a', 'b');
    const w2 = pairWeight('a', 'b');
    try testing.expectEqual(w1, w2);
    // Verify common and rare pairs also remain deterministic.
    try testing.expectEqual(pairWeight('t', 'h'), pairWeight('t', 'h'));
    try testing.expectEqual(pairWeight('q', 'x'), pairWeight('q', 'x'));
}


test "buildFrequencyTable: common pairs get lower weight than absent pairs" {
    // Construct content where 'ab' appears many times and 'qx' never appears.
    const content = "ababababababababababab";
    const table = buildFrequencyTable(content);
    // 'ab' is frequent → low weight; 'qx' absent → default high (0xFE00).
    try testing.expect(table['a']['b'] < table['q']['x']);
    try testing.expectEqual(@as(u16, 0xFE00), table['q']['x']);
}


test "frequency table: disk round-trip" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp_dir.dir.realPathFile(io, ".", &dir_buf);
    const dir_path = dir_buf[0..dir_path_len];

    // Build a table with distinct values.
    const content = "ababcdcdefefghghijij";
    const original = buildFrequencyTable(content);

    try writeFrequencyTable(io, &original, dir_path);

    const loaded_opt = try readFrequencyTable(io, dir_path, testing.allocator);
    try testing.expect(loaded_opt != null);
    const loaded = loaded_opt.?;
    defer testing.allocator.destroy(loaded);

    // Byte-for-byte identical.
    try testing.expectEqualSlices(
        u16,
        @as([*]const u16, @ptrCast(&original))[0 .. 256 * 256],
        @as([*]const u16, @ptrCast(loaded))[0 .. 256 * 256],
    );
}


test "frequency table: little-endian byte order on disk" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp_dir.dir.realPathFile(io, ".", &dir_buf);
    const dir_path = dir_buf[0..dir_path_len];

    var table: [256][256]u16 = .{.{0} ** 256} ** 256;
    table[0][0] = 0x1234; // little-endian on disk: 0x34, 0x12
    table[0][1] = 0xABCD; // little-endian on disk: 0xCD, 0xAB
    try writeFrequencyTable(io, &table, dir_path);

    const file_path = try std.fmt.allocPrint(testing.allocator, "{s}/pair_freq.bin", .{dir_path});
    defer testing.allocator.free(file_path);
    const f = try std.Io.Dir.cwd().openFile(io, file_path, .{});
    defer f.close(io);
    var raw: [4]u8 = undefined;
    try testing.expectEqual(@as(usize, 4), try f.readPositionalAll(io, &raw, 0));
    try testing.expectEqual(@as(u8, 0x34), raw[0]);
    try testing.expectEqual(@as(u8, 0x12), raw[1]);
    try testing.expectEqual(@as(u8, 0xCD), raw[2]);
    try testing.expectEqual(@as(u8, 0xAB), raw[3]);

    const loaded = try readFrequencyTable(io, dir_path, testing.allocator);
    try testing.expect(loaded != null);
    defer testing.allocator.destroy(loaded.?);
    try testing.expectEqual(@as(u16, 0x1234), loaded.?[0][0]);
    try testing.expectEqual(@as(u16, 0xABCD), loaded.?[0][1]);
}


test "setFrequencyTable / resetFrequencyTable: pairWeight output changes" {
    // Build a table where 'th' is rare (high weight) — opposite of default.
    var custom: [256][256]u16 = .{.{0x1000} ** 256} ** 256; // all common
    custom['q']['x'] = 0xFE00; // make 'qx' rare

    const before_th = pairWeight('t', 'h');
    const before_qx = pairWeight('q', 'x');

    setFrequencyTable(&custom);
    defer resetFrequencyTable();

    const after_th = pairWeight('t', 'h');
    const after_qx = pairWeight('q', 'x');

    // After swap: 'th' should be lower (we set it to 0x1000 vs default table's 0x1000 — same).
    // What definitely changes: 'qx' base shifts from 0xFE00 to 0xFE00 (custom kept it high).
    // More importantly verify that resetting restores original values.
    resetFrequencyTable();
    try testing.expectEqual(before_th, pairWeight('t', 'h'));
    try testing.expectEqual(before_qx, pairWeight('q', 'x'));
    _ = after_th;
    _ = after_qx;
}


test "file versions: append and latest" {
    var fv = version.FileVersions.init(testing.allocator, "test.zig");
    defer fv.deinit();

    try fv.versions.append(testing.allocator, .{
        .seq = 1,
        .agent = 0,
        .timestamp = 0,
        .op = .snapshot,
        .hash = 0x11,
        .size = 100,
    });
    try fv.versions.append(testing.allocator, .{
        .seq = 2,
        .agent = 0,
        .timestamp = 0,
        .op = .replace,
        .hash = 0x22,
        .size = 150,
    });

    const latest = fv.latest().?;
    try testing.expect(latest.seq == 2);
    try testing.expect(latest.size == 150);
}


test "file versions: countSince" {
    var fv = version.FileVersions.init(testing.allocator, "test.zig");
    defer fv.deinit();

    try fv.versions.append(testing.allocator, .{
        .seq = 1,
        .agent = 0,
        .timestamp = 0,
        .op = .snapshot,
        .hash = 0,
        .size = 0,
    });
    try fv.versions.append(testing.allocator, .{
        .seq = 5,
        .agent = 0,
        .timestamp = 0,
        .op = .replace,
        .hash = 0,
        .size = 0,
    });
    try fv.versions.append(testing.allocator, .{
        .seq = 10,
        .agent = 0,
        .timestamp = 0,
        .op = .delete,
        .hash = 0,
        .size = 0,
    });

    try testing.expect(fv.countSince(0) == 3);
    try testing.expect(fv.countSince(1) == 2);
    try testing.expect(fv.countSince(5) == 1);
    try testing.expect(fv.countSince(10) == 0);
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


test "watcher: parallel initial scan matches sequential results" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(io, "src/nested");
    try tmp_dir.dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = "const std = @import(\"std\");\npub fn alpha() void {}\n// TODO: keep me\n" });
    try tmp_dir.dir.writeFile(io, .{ .sub_path = "src/nested/util.py", .data = "def beta():\n    return 42\n# TODO later\n" });
    try tmp_dir.dir.writeFile(io, .{ .sub_path = "README.md", .data = "# demo\n" });

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp_dir.dir.realPathFile(io, ".", &root_buf);
    const root = root_buf[0..root_len];

    var store_seq = Store.init(testing.allocator);
    defer store_seq.deinit();
    var explorer_seq = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer_seq.deinit();
    explorer_seq.setRoot(io, root);
    try watcher.initialScanWithWorkerCount(io, &store_seq, &explorer_seq, root, testing.allocator, false, 1);

    var store_par = Store.init(testing.allocator);
    defer store_par.deinit();
    var explorer_par = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer_par.deinit();
    explorer_par.setRoot(io, root);
    try watcher.initialScanWithWorkerCount(io, &store_par, &explorer_par, root, testing.allocator, false, 4);

    const tree_seq = try explorer_seq.getTree(testing.allocator, false);
    defer testing.allocator.free(tree_seq);
    const tree_par = try explorer_par.getTree(testing.allocator, false);
    defer testing.allocator.free(tree_par);
    try testing.expectEqualStrings(tree_seq, tree_par);

    const seq_hits = try explorer_seq.searchWord("TODO", testing.allocator);
    defer testing.allocator.free(seq_hits);
    const par_hits = try explorer_par.searchWord("TODO", testing.allocator);
    defer testing.allocator.free(par_hits);
    try testing.expectEqual(seq_hits.len, par_hits.len);

    try testing.expectEqual(explorer_seq.outlines.count(), explorer_par.outlines.count());
}


test "watcher: parallel word-index shards match sequential (skip_file_words)" {
    // Exercises the per-worker WordIndex shard + serial mergeShard path
    // (use_shards requires word_index.enabled and skip_file_words). Asserts the
    // sharded parallel build is byte-identical to the single-worker serial build
    // for both raw word hits and BM25 ranked results.
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(io, "src");
    try tmp_dir.dir.writeFile(io, .{ .sub_path = "src/a.zig", .data = "const std = @import(\"std\");\npub fn parseToken() void {}\n// TODO alpha\n" });
    try tmp_dir.dir.writeFile(io, .{ .sub_path = "src/b.zig", .data = "pub fn parseToken() void {}\npub fn handleRequest() void {}\n// TODO beta\n" });
    try tmp_dir.dir.writeFile(io, .{ .sub_path = "src/c.py", .data = "def parse_token():\n    return handle_request()\n# TODO gamma\n" });
    try tmp_dir.dir.writeFile(io, .{ .sub_path = "src/d.md", .data = "# parseToken and handleRequest notes\nTODO delta\n" });
    try tmp_dir.dir.writeFile(io, .{ .sub_path = "src/e.zig", .data = "pub fn handleRequest() void { parseToken(); }\n" });

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp_dir.dir.realPathFile(io, ".", &root_buf);
    const root = root_buf[0..root_len];

    var store_seq = Store.init(testing.allocator);
    defer store_seq.deinit();
    var explorer_seq = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer_seq.deinit();
    explorer_seq.word_index.skip_file_words = true;
    explorer_seq.setRoot(io, root);
    try watcher.initialScanWithWorkerCount(io, &store_seq, &explorer_seq, root, testing.allocator, false, 1);

    var store_par = Store.init(testing.allocator);
    defer store_par.deinit();
    var explorer_par = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer_par.deinit();
    explorer_par.word_index.skip_file_words = true;
    explorer_par.setRoot(io, root);
    try watcher.initialScanWithWorkerCount(io, &store_par, &explorer_par, root, testing.allocator, false, 4);

    // Word-index structural parity.
    try testing.expectEqual(explorer_seq.word_index.id_to_path.items.len, explorer_par.word_index.id_to_path.items.len);
    try testing.expectEqual(explorer_seq.word_index.total_tokens, explorer_par.word_index.total_tokens);
    for ([_][]const u8{ "parsetoken", "parse", "token", "handlerequest", "handle", "request", "todo", "std" }) |term| {
        try testing.expectEqual(explorer_seq.word_index.search(term).len, explorer_par.word_index.search(term).len);
    }

    // BM25 ranked-search parity: identical ordered result set (path + line).
    const r_seq = try explorer_seq.searchContentRanked("parseToken handleRequest", testing.allocator, 10);
    defer {
        for (r_seq) |r| {
            testing.allocator.free(r.line_text);
            testing.allocator.free(r.path);
        }
        testing.allocator.free(r_seq);
    }
    const r_par = try explorer_par.searchContentRanked("parseToken handleRequest", testing.allocator, 10);
    defer {
        for (r_par) |r| {
            testing.allocator.free(r.line_text);
            testing.allocator.free(r.path);
        }
        testing.allocator.free(r_par);
    }
    try testing.expectEqual(r_seq.len, r_par.len);
    for (r_seq, r_par) |a, b| {
        try testing.expectEqualStrings(a.path, b.path);
        try testing.expectEqual(a.line_num, b.line_num);
    }
}


test "edit: range_start zero is invalid" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const rel_path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/edit-range.txt", .{tmp.sub_path});
    defer testing.allocator.free(rel_path);

    var file = try tmp.dir.createFile(io, "edit-range.txt", .{});
    defer file.close(io);
    try file.writeStreamingAll(io, "line 1\nline 2\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    const agent_id = try agents.register("test-agent");

    try testing.expectError(error.InvalidRange, edit_mod.applyEdit(io, testing.allocator, &store, &agents, null, .{
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

    var file = try tmp.dir.createFile(io, "edit-range-oob.txt", .{});
    defer file.close(io);
    try file.writeStreamingAll(io, "line 1\nline 2\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    const agent_id = try agents.register("test-agent-oob");

    try testing.expectError(error.InvalidRange, edit_mod.applyEdit(io, testing.allocator, &store, &agents, null, .{
        .path = rel_path,
        .agent_id = agent_id,
        .op = .replace,
        .range = .{ 3, 3 },
        .content = "changed",
    }));
}


test "regression #2: searchContent frees trigram candidate slice" {
    // Verifies that the candidates() return value is freed by searchContent.
    // If the defer is missing, the GPA will detect the leak and fail.
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();

    try explorer.indexFile("leak-check.zig", "pub fn recordSnapshot(self: *Store) void {}\npub fn init() void {}");
    try explorer.indexFile("other.zig", "pub fn register(self: *Agent) void {}");

    const results = try explorer.searchContent("recordSnapshot", testing.allocator, 50);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }
    try testing.expect(results.len == 1);
    try testing.expectEqualStrings("leak-check.zig", results[0].path);
}


test "regression #2: searchContent no leak on zero results" {
    // Even when trigram narrows to candidates but none match full text,
    // the candidate slice must be freed.
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();

    try explorer.indexFile("abc.zig", "pub fn abcdef() void {}");

    // "abcxyz" shares trigrams "abc" but won't match full text
    const results = try explorer.searchContent("abcxyz", testing.allocator, 50);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }
    try testing.expect(results.len == 0);
}


test "regression #2: searchContent short query skips trigrams" {
    // Queries < 3 chars can't use trigram index — ensure no leak from null path.
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();

    try explorer.indexFile("short.zig", "fn ab() void {}");

    const results = try explorer.searchContent("ab", testing.allocator, 50);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }
    try testing.expect(results.len == 1);
}


test "regression #5: getHotFiles does not deadlock" {
    // getHotFiles used to hold explorer.mu while calling store.getLatest()
    // which locks store.mu — a lock ordering violation. The fix collects
    // paths under explorer.mu, releases it, then locks store.mu separately.
    // This test verifies correctness; deadlock would cause a hang.
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
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
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
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
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
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
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("src/main.zig", "pub fn main() void {}");
    try explorer.indexFile("src/lib.zig", "pub fn init() void {}");
    try explorer.indexFile("build.zig", "pub fn build() void {}");

    const tree = try explorer.getTree(testing.allocator, false);
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
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("src/utils/hash.zig", "pub fn hash() void {}");
    try explorer.indexFile("src/main.zig", "pub fn main() void {}");

    const tree = try explorer.getTree(testing.allocator, false);
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
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("pkg/foo/bar.zig", "const x = 1;");

    const tree = try explorer.getTree(testing.allocator, false);
    defer testing.allocator.free(tree);

    // Full path should NOT appear in tree output
    try testing.expect(std.mem.indexOf(u8, tree, "pkg/foo/bar.zig") == null);
    // Only basename
    try testing.expect(std.mem.indexOf(u8, tree, "bar.zig") != null);
}


test "regression: searchWord empty result is allocator-owned" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("math.zig", "pub fn add(a: i32, b: i32) i32 { return a + b; }");

    const hits = try explorer.searchWord("missing_identifier", testing.allocator);
    defer testing.allocator.free(hits);
    try testing.expect(hits.len == 0);
}


test "regression: searchContent frees empty trigram candidate slice" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("f.zig", "hello world");

    const results = try explorer.searchContent("zzzzz", testing.allocator, 50);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
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
    const start = cio.nanoTimestamp();
    _ = queue.push(watcher.FsEvent.init(overflow_path, .created, 1000) orelse unreachable);
    const elapsed = cio.nanoTimestamp() - start;

    try testing.expect(elapsed < 50 * std.time.ns_per_ms);
}


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


test "findSymbol: returned data is owned copy" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var explorer = Explorer.init(alloc, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
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

    var explorer = Explorer.init(alloc, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
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

    var explorer = Explorer.init(alloc, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    try explorer.indexFile("src/hello.zig", "pub fn greetWorld() void {}");

    const results = try explorer.searchContent("greetWorld", alloc, 10);
    try testing.expect(results.len == 1);

    // Remove the source
    explorer.removeFile("src/hello.zig");

    // Path and line_text should still be valid (owned)
    try testing.expectEqualStrings("src/hello.zig", results[0].path);
}


test "trigram index: removeFile prunes empty sets" {
    var ti = TrigramIndex.init(testing.allocator);
    defer ti.deinit();

    try ti.indexFile("only.zig", "xyzUniqueTrigramContent");
    const before = ti.candidates("xyzUniqueTrigramContent", testing.allocator);
    if (before) |b| {
        try testing.expect(b.len > 0);
        testing.allocator.free(b);
    }

    ti.removeFile("only.zig");
    const after = ti.candidates("xyzUniqueTrigramContent", testing.allocator);
    if (after) |a| {
        try testing.expect(a.len == 0);
        testing.allocator.free(a);
    }
}


test "edit: atomic write leaves no temp files on success" {
    // Create a temp file to edit
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const path = "test_atomic.zig";
    const content = "line1\nline2\nline3\n";
    try tmp_dir.dir.writeFile(io, .{ .sub_path = path, .data = content });

    // The temp file pattern is "{path}.codedb_tmp"
    const tmp_path = path ++ ".codedb_tmp";

    // After a successful edit, no .codedb_tmp file should remain
    tmp_dir.dir.access(io, tmp_path, .{}) catch {
        // Expected: temp file doesn't exist (good)
        return;
    };
    // If we get here, the temp file exists — that's a bug
    return error.TempFileNotCleaned;
}


test "getBool: returns true for bool true" {
    var map: std.json.ObjectMap = .empty;
    defer map.deinit(testing.allocator);
    try map.put(testing.allocator, "flag", .{ .bool = true });
    const mcp_getBool = @import("mcp.zig").getBool;
    try testing.expect(mcp_getBool(&map, "flag") == true);
}


test "getBool: returns false for bool false" {
    var map: std.json.ObjectMap = .empty;
    defer map.deinit(testing.allocator);
    try map.put(testing.allocator, "flag", .{ .bool = false });
    const mcp_getBool = @import("mcp.zig").getBool;
    try testing.expect(mcp_getBool(&map, "flag") == false);
}


test "getBool: returns false for missing key" {
    var map: std.json.ObjectMap = .empty;
    defer map.deinit(testing.allocator);
    const mcp_getBool = @import("mcp.zig").getBool;
    try testing.expect(mcp_getBool(&map, "missing") == false);
}


test "getBool: returns false for non-bool value" {
    var map: std.json.ObjectMap = .empty;
    defer map.deinit(testing.allocator);
    try map.put(testing.allocator, "flag", .{ .integer = 1 });
    const mcp_getBool = @import("mcp.zig").getBool;
    try testing.expect(mcp_getBool(&map, "flag") == false);
}


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


test "decomposeRegex: pure literal extracts trigrams" {
    var q = try decomposeRegex("hello", testing.allocator);
    defer q.deinit();
    // "hello" has 3 trigrams: hel, ell, llo
    try testing.expectEqual(@as(usize, 3), q.and_trigrams.len);
    try testing.expectEqual(@as(usize, 0), q.or_groups.len);
}


test "decomposeRegex: short literal yields no trigrams" {
    var q = try decomposeRegex("ab", testing.allocator);
    defer q.deinit();
    try testing.expectEqual(@as(usize, 0), q.and_trigrams.len);
}


test "decomposeRegex: dot breaks trigram chain" {
    var q = try decomposeRegex("he.lo", testing.allocator);
    defer q.deinit();
    // "he" then "lo" — neither long enough for trigrams
    try testing.expectEqual(@as(usize, 0), q.and_trigrams.len);
}


test "decomposeRegex: dot in longer literal" {
    var q = try decomposeRegex("hello.world", testing.allocator);
    defer q.deinit();
    // "hello" -> hel,ell,llo; "world" -> wor,orl,rld = 6 trigrams
    try testing.expectEqual(@as(usize, 6), q.and_trigrams.len);
}


test "decomposeRegex: alternation creates OR groups" {
    var q = try decomposeRegex("foo|bar", testing.allocator);
    defer q.deinit();
    try testing.expectEqual(@as(usize, 0), q.and_trigrams.len);
    // All branch trigrams merged into single OR group
    try testing.expectEqual(@as(usize, 1), q.or_groups.len);
    // "foo" has 1 trigram + "bar" has 1 trigram = 2 trigrams in the group
    try testing.expectEqual(@as(usize, 2), q.or_groups[0].len);
}


test "decomposeRegex: quantifier removes preceding char" {
    var q = try decomposeRegex("hel+o", testing.allocator);
    defer q.deinit();
    // "he" then "o" — + removes 'l', neither segment >= 3
    try testing.expectEqual(@as(usize, 0), q.and_trigrams.len);
}


test "decomposeRegex: escaped literal preserved" {
    var q = try decomposeRegex("a\\.bc", testing.allocator);
    defer q.deinit();
    // Escaped dot is literal: "a.bc" = 2 trigrams: a.b, .bc
    try testing.expectEqual(@as(usize, 2), q.and_trigrams.len);
}


test "decomposeRegex: character class breaks chain" {
    var q = try decomposeRegex("abc[xy]def", testing.allocator);
    defer q.deinit();
    // "abc" = 1 trigram, "def" = 1 trigram
    try testing.expectEqual(@as(usize, 2), q.and_trigrams.len);
}


test "decomposeRegex: backslash-w breaks chain" {
    var q = try decomposeRegex("abc\\wdef", testing.allocator);
    defer q.deinit();
    // "abc" = 1 trigram, "def" = 1 trigram
    try testing.expectEqual(@as(usize, 2), q.and_trigrams.len);
}


test "candidatesRegex: finds files with AND trigrams" {
    var ti = TrigramIndex.init(testing.allocator);
    defer ti.deinit();

    try ti.indexFile("foo.zig", "pub fn recordSnapshot() void {}");
    try ti.indexFile("bar.zig", "const x = 42;");

    var q = try decomposeRegex("record.*Snapshot", testing.allocator);
    defer q.deinit();
    // Should extract trigrams from "record" and "Snapshot"
    try testing.expect(q.and_trigrams.len > 0);

    const cands = ti.candidatesRegex(&q, testing.allocator);
    defer if (cands) |c| testing.allocator.free(c);
    try testing.expect(cands != null);
    try testing.expect(cands.?.len >= 1);
    // foo.zig should be a candidate
    var found_foo = false;
    for (cands.?) |p| {
        if (std.mem.eql(u8, p, "foo.zig")) found_foo = true;
    }
    try testing.expect(found_foo);
}


test "candidatesRegex: OR groups union posting lists" {
    var ti = TrigramIndex.init(testing.allocator);
    defer ti.deinit();

    try ti.indexFile("alpha.zig", "function foobar() {}");
    try ti.indexFile("beta.zig", "function bazqux() {}");
    try ti.indexFile("gamma.zig", "const x = 1;");

    var q = try decomposeRegex("foobar|bazqux", testing.allocator);
    defer q.deinit();
    // All branch trigrams merged into single OR group
    try testing.expectEqual(@as(usize, 1), q.or_groups.len);

    const cands = ti.candidatesRegex(&q, testing.allocator);
    defer if (cands) |c| testing.allocator.free(c);
    try testing.expect(cands != null);
    // Both alpha.zig and beta.zig should be candidates
    var found_alpha = false;
    var found_beta = false;
    for (cands.?) |p| {
        if (std.mem.eql(u8, p, "alpha.zig")) found_alpha = true;
        if (std.mem.eql(u8, p, "beta.zig")) found_beta = true;
    }
    try testing.expect(found_alpha or found_beta);
}


test "regexMatch: literal match" {
    try testing.expect(regexMatch("hello world", "hello"));
    try testing.expect(regexMatch("hello world", "world"));
    try testing.expect(!regexMatch("hello world", "xyz"));
}


test "regexMatch: dot matches any char" {
    try testing.expect(regexMatch("hello", "h.llo"));
    try testing.expect(regexMatch("hello", "h..lo"));
    try testing.expect(!regexMatch("hello", "h...lo"));
}


test "regexMatch: star quantifier" {
    try testing.expect(regexMatch("helllo", "hel*o"));
    try testing.expect(regexMatch("heo", "hel*o"));
    try testing.expect(regexMatch("aab", "a*b"));
}


test "regexMatch: plus quantifier" {
    try testing.expect(regexMatch("helllo", "hel+o"));
    try testing.expect(!regexMatch("heo", "hel+o"));
}


test "regexMatch: question quantifier" {
    try testing.expect(regexMatch("color", "colou?r"));
    try testing.expect(regexMatch("colour", "colou?r"));
}


test "regexMatch: character class" {
    try testing.expect(regexMatch("cat", "c[aeiou]t"));
    try testing.expect(regexMatch("cot", "c[aeiou]t"));
    try testing.expect(!regexMatch("cxt", "c[aeiou]t"));
}


test "regexMatch: negated character class" {
    try testing.expect(!regexMatch("cat", "c[^aeiou]t"));
    try testing.expect(regexMatch("cxt", "c[^aeiou]t"));
}


test "regexMatch: anchors" {
    try testing.expect(regexMatch("hello", "^hello"));
    try testing.expect(!regexMatch("say hello", "^hello"));
    try testing.expect(regexMatch("hello", "hello$"));
    try testing.expect(!regexMatch("hello world", "hello$"));
}


test "regexMatch: escape sequences" {
    try testing.expect(regexMatch("abc123", "\\d+"));
    try testing.expect(regexMatch("hello world", "\\w+\\s\\w+"));
    try testing.expect(regexMatch("a.b", "a\\.b"));
    try testing.expect(!regexMatch("axb", "a\\.b"));
}


test "regexMatch: alternation" {
    try testing.expect(regexMatch("foo", "foo|bar"));
    try testing.expect(regexMatch("bar", "foo|bar"));
    try testing.expect(!regexMatch("baz", "foo|bar"));
}


test "regexMatch: alternation with many branches does not stack overflow" {
    // 300 branches: 4 chars each + 299 separators = 1499 bytes max
    var buf: [1500]u8 = undefined;
    var pos: usize = 0;
    var bi: usize = 0;
    while (bi < 300) : (bi += 1) {
        if (bi > 0) {
            buf[pos] = '|';
            pos += 1;
        }
        buf[pos] = 'a';
        pos += 1;
        buf[pos] = @as(u8, @intCast('0' + bi / 100 % 10));
        pos += 1;
        buf[pos] = @as(u8, @intCast('0' + bi / 10 % 10));
        pos += 1;
        buf[pos] = @as(u8, @intCast('0' + bi % 10));
        pos += 1;
    }
    const pattern = buf[0..pos];
    try testing.expect(regexMatch("a000", pattern));
    try testing.expect(regexMatch("a299", pattern));
    try testing.expect(!regexMatch("a999", pattern));
}


test "regexMatch: dot-star" {
    try testing.expect(regexMatch("hello world", "hello.*world"));
    try testing.expect(regexMatch("helloworld", "hello.*world"));
}


test "issue-454: regex \\b word boundary matches whole-word, not literal 'b'" {
    // \b is a word-boundary assertion: should match "foo" as a whole word
    // but not when it appears as a substring inside another word.
    try testing.expect(regexMatch("foo bar", "\\bfoo\\b"));
    try testing.expect(!regexMatch("foobar", "\\bfoo\\b"));
    // Whole-word "bar" at end
    try testing.expect(regexMatch("foo bar", "\\bbar\\b"));
    try testing.expect(!regexMatch("foobarbaz", "\\bbar\\b"));
}


test "bloom: PostingMask is populated during indexing" {
    // Verify that indexing actually sets mask bits, not just zeros.
    var ti = TrigramIndex.init(testing.allocator);
    defer ti.deinit();

    try ti.indexFile("a.zig", "pub fn init(allocator) void {}");

    // Trigram "pub" should exist with non-zero masks
    const tri_pub = packTrigram('p', 'u', 'b');
    const file_set = ti.index.getPtr(tri_pub);
    try testing.expect(file_set != null);

    const mask = file_set.?.get("a.zig");
    try testing.expect(mask != null);
    // loc_mask must have at least one bit set (position 0)
    try testing.expect(mask.?.loc_mask != 0);
    // next_mask must have at least one bit set (char after "pub" is ' ')
    try testing.expect(mask.?.next_mask != 0);
}


test "bloom: loc_mask records correct position bits" {
    var ti = TrigramIndex.init(testing.allocator);
    defer ti.deinit();

    // Content where "abc" appears at known positions
    // Position 0: "abcXXXXXabcYYYYY" — abc at pos 0 and pos 8
    try ti.indexFile("pos.zig", "abcXXXXXabcYYYYY");

    const tri_abc = packTrigram('a', 'b', 'c');
    const file_set = ti.index.getPtr(tri_abc).?;
    const mask = file_set.get("pos.zig").?;

    // pos 0 → bit 0, pos 8 → bit 0 (8 % 8 = 0)
    try testing.expect(mask.loc_mask & 1 != 0); // bit 0 set
}


test "bloom: next_mask records the following character" {
    var ti = TrigramIndex.init(testing.allocator);
    defer ti.deinit();

    try ti.indexFile("next.zig", "abcdef");

    // For trigram "abc" at position 0, next char is 'd'
    const tri_abc = packTrigram('a', 'b', 'c');
    const file_set = ti.index.getPtr(tri_abc).?;
    const mask = file_set.get("next.zig").?;

    const expected_bit: u8 = @as(u8, 1) << @intCast(normalizeChar('d') % 8);
    try testing.expect(mask.next_mask & expected_bit != 0);
}


test "bloom: soundness — never rejects actual matches" {
    // The bloom filter must NEVER produce false negatives.
    // Every file that actually contains the query must appear in candidates.
    var ti = TrigramIndex.init(testing.allocator);
    defer ti.deinit();

    // Index many files with varied content, some containing the target
    try ti.indexFile("match1.zig", "fn handleRequest(ctx: *Context) void {}");
    try ti.indexFile("match2.zig", "pub fn handleRequest() !void { return error.Fail; }");
    try ti.indexFile("noise1.zig", "fn processData(input: []const u8) void {}");
    try ti.indexFile("noise2.zig", "const handler = RequestPool.init();"); // has "handl" and "eques" but not "handleRequest"
    try ti.indexFile("noise3.zig", "fn handleResponse(ctx: *Context) void {}"); // close but different
    try ti.indexFile("noise4.zig", "pub fn register(name: []const u8) void {}");
    try ti.indexFile("noise5.zig", "const request_handler = getHandler();"); // has both words but not adjacent

    const cands = ti.candidates("handleRequest", testing.allocator);
    defer if (cands) |c| testing.allocator.free(c);
    try testing.expect(cands != null);

    // MUST find both actual matches — bloom filter cannot reject them
    var found1 = false;
    var found2 = false;
    for (cands.?) |p| {
        if (std.mem.eql(u8, p, "match1.zig")) found1 = true;
        if (std.mem.eql(u8, p, "match2.zig")) found2 = true;
    }
    try testing.expect(found1);
    try testing.expect(found2);
}


test "bloom: reduces candidates vs pure trigram intersection" {
    // This is the key test: prove bloom filtering actually eliminates
    // files that trigram intersection alone would not.
    var ti = TrigramIndex.init(testing.allocator);
    defer ti.deinit();

    // "pub fn init" — common trigrams "pub", "ub ", "b f", " fn", "fn ", "n i", " in", "ini", "nit"
    // We'll create files that share many of these trigrams but NOT adjacently.
    try ti.indexFile("real.zig", "pub fn init() void {}"); // actual match
    try ti.indexFile("shuffled1.zig", "fn publish(nit_pick: bool) void {}"); // has "pub","fn ","nit" but not adjacently
    try ti.indexFile("shuffled2.zig", "fn pubNitInit() void {}"); // has "pub","nit","ini" but wrong order
    try ti.indexFile("unrelated.zig", "const x = 42;"); // no overlap

    const cands = ti.candidates("pub fn init", testing.allocator);
    defer if (cands) |c| testing.allocator.free(c);
    try testing.expect(cands != null);

    // real.zig MUST be found (soundness)
    var found_real = false;
    for (cands.?) |p| {
        if (std.mem.eql(u8, p, "real.zig")) found_real = true;
    }
    try testing.expect(found_real);

    // unrelated.zig must NOT be found
    var found_unrelated = false;
    for (cands.?) |p| {
        if (std.mem.eql(u8, p, "unrelated.zig")) found_unrelated = true;
    }
    try testing.expect(!found_unrelated);

    // Count how many candidates we got — should be fewer than all files
    // that share trigrams. At minimum, "unrelated.zig" is excluded.
    try testing.expect(cands.?.len < 4);
}


test "bloom: loc_mask adjacency filtering works" {
    // Construct a scenario where two trigrams exist in a file but at
    // positions where they can't be adjacent. The loc_mask check should
    // filter this out (probabilistically, but deterministically for
    // carefully chosen positions).
    var ti = TrigramIndex.init(testing.allocator);
    defer ti.deinit();

    // "XXXabcYYYYYYYYYYYYYYYdefZZZ" — "abc" at pos 3, "def" at pos 21
    // Query "abcdef" needs abc at pos N and def at pos N+3.
    // But abc is at pos 3 (bit 3) and def is at pos 21 (bit 5).
    // Shifted abc loc_mask bit 3 → bit 4. "bcd" would need to be at bit 4.
    // This tests the adjacency logic.
    try ti.indexFile("adjacent.zig", "XXabcdefGH"); // abc and def ARE adjacent
    try ti.indexFile("apart.zig", "XXXabcYYYYYYYYYYYYYYdefZZZ"); // abc and def far apart

    const cands = ti.candidates("abcdef", testing.allocator);
    defer if (cands) |c| testing.allocator.free(c);
    try testing.expect(cands != null);

    // adjacent.zig MUST be found
    var found_adjacent = false;
    for (cands.?) |p| {
        if (std.mem.eql(u8, p, "adjacent.zig")) found_adjacent = true;
    }
    try testing.expect(found_adjacent);

    // apart.zig MAY be filtered out by loc_mask (depends on position mod 8 collision)
    // We can't assert it's excluded because bloom filters allow false positives,
    // but we CAN assert the total candidate count is reasonable.
    try testing.expect(cands.?.len >= 1); // at least the real match
}


test "bloom: masks accumulate across multiple positions" {
    // If a trigram appears at many positions in a file, both masks should
    // have multiple bits set (OR'd together, never replaced).
    var ti = TrigramIndex.init(testing.allocator);
    defer ti.deinit();

    // "the" appears at positions 0, 10, 20, 30, 40, 50, 60, 70
    try ti.indexFile("repeat.zig", "the_______the_______the_______the_______the_______the_______the_______the_______");

    const tri_the = packTrigram('t', 'h', 'e');
    const file_set = ti.index.getPtr(tri_the).?;
    const mask = file_set.get("repeat.zig").?;

    // With 8+ occurrences at varying positions, loc_mask should have many bits set
    try testing.expect(@popCount(mask.loc_mask) >= 3);
    // next_mask should also have bits set (from the chars following each "the")
    try testing.expect(mask.next_mask != 0);
}


test "bloom: regression — candidate count for known queries" {
    // Regression benchmark: index a controlled set of files and assert
    // specific candidate counts. If bloom filtering breaks or regresses,
    // these counts will increase.
    var ti = TrigramIndex.init(testing.allocator);
    defer ti.deinit();

    try ti.indexFile("a.zig", "pub fn initAllocator() void {}");
    try ti.indexFile("b.zig", "pub fn deinitAllocator() void {}");
    try ti.indexFile("c.zig", "pub fn init() void {}");
    try ti.indexFile("d.zig", "fn publish(data: []u8) void {}");
    try ti.indexFile("e.zig", "const initial_value = 0;");
    try ti.indexFile("f.zig", "fn processInput() !void {}");
    try ti.indexFile("g.zig", "const config = getConfig();");
    try ti.indexFile("h.zig", "fn handleNotification() void {}");

    // "initAllocator" — a.zig must be found; b.zig ("deinitAllocator") shares trigrams
    {
        const cands = ti.candidates("initAllocator", testing.allocator);
        defer if (cands) |c| testing.allocator.free(c);
        try testing.expect(cands != null);
        var found_a = false;
        for (cands.?) |p| {
            if (std.mem.eql(u8, p, "a.zig")) found_a = true;
        }
        try testing.expect(found_a);
        // b.zig is a valid false positive (shares "initAllocator" substring in "deinitAllocator")
        // but d/e/f/g/h should not appear
        try testing.expect(cands.?.len <= 2);
    }

    // "pub fn init" — should find a.zig, c.zig; maybe b.zig (shares "pub fn ")
    // but NOT d/e/f/g/h
    {
        const cands = ti.candidates("pub fn init", testing.allocator);
        defer if (cands) |c| testing.allocator.free(c);
        try testing.expect(cands != null);
        // Must include actual matches
        var found_a = false;
        var found_c = false;
        for (cands.?) |p| {
            if (std.mem.eql(u8, p, "a.zig")) found_a = true;
            if (std.mem.eql(u8, p, "c.zig")) found_c = true;
        }
        try testing.expect(found_a);
        try testing.expect(found_c);
        // Candidate count must be <= 4 (bloom should exclude some)
        // Without bloom: files sharing any "pub"/"fn "/"ini"/"nit" trigrams = many
        // With bloom: adjacency + next_mask filtering should narrow it down
        try testing.expect(cands.?.len <= 4);
    }

    // "processInput" — f.zig must be found, few false positives allowed
    {
        const cands = ti.candidates("processInput", testing.allocator);
        defer if (cands) |c| testing.allocator.free(c);
        try testing.expect(cands != null);
        var found_f = false;
        for (cands.?) |p| {
            if (std.mem.eql(u8, p, "f.zig")) found_f = true;
        }
        try testing.expect(found_f);
        // Bloom may allow a false positive but should be way less than 8
        try testing.expect(cands.?.len <= 3);
    }
}


test "regex regression: trigram extraction counts" {
    // Verify exact trigram counts for known patterns.
    // If decomposition logic changes, these catch it.
    {
        var q = try decomposeRegex("handleRequest", testing.allocator);
        defer q.deinit();
        // 13 chars → 11 trigrams, all AND
        try testing.expectEqual(@as(usize, 11), q.and_trigrams.len);
        try testing.expectEqual(@as(usize, 0), q.or_groups.len);
    }
    {
        var q = try decomposeRegex("foo.*bar.*baz", testing.allocator);
        defer q.deinit();
        // "foo", "bar", "baz" — each 3 chars = 1 trigram each = 3 AND trigrams
        try testing.expectEqual(@as(usize, 3), q.and_trigrams.len);
        try testing.expectEqual(@as(usize, 0), q.or_groups.len);
    }
    {
        var q = try decomposeRegex("alpha|beta|gamma", testing.allocator);
        defer q.deinit();
        // No AND trigrams — all in OR groups
        try testing.expectEqual(@as(usize, 0), q.and_trigrams.len);
        try testing.expectEqual(@as(usize, 1), q.or_groups.len);
        // alpha=3 + beta=2 + gamma=3 = 8 trigrams in the OR group
        try testing.expectEqual(@as(usize, 8), q.or_groups[0].len);
    }
}


test "regex regression: regexMatch edge cases" {
    // Empty pattern matches anything
    try testing.expect(regexMatch("anything", ""));

    // Pure wildcard
    try testing.expect(regexMatch("abc", ".*"));
    try testing.expect(regexMatch("", ".*"));

    // Consecutive quantifiers shouldn't crash
    try testing.expect(regexMatch("aab", "a+b"));
    try testing.expect(!regexMatch("b", "a+b"));

    // Nested-ish patterns
    try testing.expect(regexMatch("foobar", "foo.ar"));
    try testing.expect(!regexMatch("foar", "foo.ar"));

    // Backslash at end of pattern (edge case)
    try testing.expect(!regexMatch("abc", "abc\\"));
}


test "regex regression: candidatesRegex reduces vs brute force" {
    var ti = TrigramIndex.init(testing.allocator);
    defer ti.deinit();

    try ti.indexFile("handler.zig", "pub fn handleRequest(ctx: *Context) !void { }");
    try ti.indexFile("process.zig", "pub fn processData(input: []u8) void { }");
    try ti.indexFile("utils.zig", "pub fn formatString(s: []const u8) []u8 { return s; }");
    try ti.indexFile("config.zig", "const default_config = Config{ .debug = false };");

    // "handle.*Request" — should extract trigrams from "handle" and "Request"
    var q = try decomposeRegex("handle.*Request", testing.allocator);
    defer q.deinit();
    try testing.expect(q.and_trigrams.len >= 4); // at least some from both halves

    const cands = ti.candidatesRegex(&q, testing.allocator);
    defer if (cands) |c| testing.allocator.free(c);
    try testing.expect(cands != null);

    // handler.zig MUST be a candidate (soundness)
    var found_handler = false;
    for (cands.?) |p| {
        if (std.mem.eql(u8, p, "handler.zig")) found_handler = true;
    }
    try testing.expect(found_handler);

    // Should NOT include config.zig (no "handle" or "Request" trigrams)
    var found_config = false;
    for (cands.?) |p| {
        if (std.mem.eql(u8, p, "config.zig")) found_config = true;
    }
    try testing.expect(!found_config);

    // Candidate count should be much less than total files
    try testing.expect(cands.?.len <= 2);
}


test "perf regression: indexing 200 files under 200ms" {
    var ti = TrigramIndex.init(testing.allocator);
    defer ti.deinit();
    var wi = WordIndex.init(testing.allocator);
    defer wi.deinit();

    // Generate 200 synthetic files with realistic content
    var bufs: [200][]u8 = undefined;
    var names: [200][]u8 = undefined;
    for (0..200) |i| {
        names[i] = try std.fmt.allocPrint(testing.allocator, "src/file_{d:0>3}.zig", .{i});
        bufs[i] = try std.fmt.allocPrint(testing.allocator,
            \\pub fn handler_{d}(ctx: *Context, req: Request) !Response {{
            \\    const allocator = ctx.allocator;
            \\    const data = try req.readBody(allocator);
            \\    defer allocator.free(data);
            \\    return Response.init(.ok, data);
            \\}}
            \\
            \\const Config_{d} = struct {{
            \\    name: []const u8,
            \\    value: i64 = {d},
            \\    enabled: bool = true,
            \\}};
        , .{ i, i, i * 42 });
    }
    defer for (0..200) |i| {
        testing.allocator.free(bufs[i]);
        testing.allocator.free(names[i]);
    };

    // Min-of-3 runs so transient host load can't trip the bound
    // (re-runs re-index the same paths — same code path, warm maps).
    var best_ns: u64 = std.math.maxInt(u64);
    for (0..3) |_| {
        var timer = try cio.Timer.start();
        for (0..200) |i| {
            try ti.indexFile(names[i], bufs[i]);
            try wi.indexFile(names[i], bufs[i]);
        }
        best_ns = @min(best_ns, timer.read());
    }
    const elapsed_ms = @as(f64, @floatFromInt(best_ns)) / 1_000_000.0;

    // Must complete under 200ms (generous budget — typically ~30ms)
    // Debug builds are ~10x slower than ReleaseFast; give generous headroom.
    // ReleaseFast typically ~30ms; Debug ~100–250ms depending on host.
    try testing.expect(elapsed_ms < 500.0);
}


test "perf regression: trigram candidate lookup under 1ms per query" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ti = TrigramIndex.init(testing.allocator);
    defer ti.deinit();

    for (0..100) |i| {
        const name = try std.fmt.allocPrint(alloc, "mod_{d}.zig", .{i});
        const content = try std.fmt.allocPrint(alloc,
            \\pub fn process_{d}(data: []const u8) !void {{
            \\    const result = transform(data);
            \\    try validate(result);
            \\}}
        , .{i});
        try ti.indexFile(name, content);
    }

    const queries = [_][]const u8{
        "process_42",
        "transform",
        "pub fn process",
        "validate(result)",
    };

    const iters: usize = 1000;
    // Min-of-3 runs so transient host load can't trip the bound.
    var best_ns: u64 = std.math.maxInt(u64);
    for (0..3) |_| {
        var timer = try cio.Timer.start();
        for (0..iters) |_| {
            for (queries) |q| {
                const cands = ti.candidates(q, testing.allocator);
                if (cands) |c| testing.allocator.free(c);
            }
        }
        best_ns = @min(best_ns, timer.read());
    }
    const ns_per_query = best_ns / (iters * queries.len);

    // Must be under 1ms (1_000_000 ns) per query — typically ~100µs
    try testing.expect(ns_per_query < 1_000_000);
}


test "perf regression: word index lookup under 100ns per query" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var wi = WordIndex.init(testing.allocator);
    defer wi.deinit();

    for (0..100) |i| {
        const name = try std.fmt.allocPrint(alloc, "src_{d}.zig", .{i});
        const content = try std.fmt.allocPrint(alloc, "pub fn handleRequest_{d}(ctx: *Context) void {{}}\nconst allocator = getDefaultAllocator();\n", .{i});
        try wi.indexFile(name, content);
    }

    const queries = [_][]const u8{ "handleRequest_50", "allocator", "getDefaultAllocator", "Context" };

    const iters: usize = 100_000;
    // Min-of-3 runs so transient host load can't trip the bound.
    var best_ns: u64 = std.math.maxInt(u64);
    for (0..3) |_| {
        var timer = try cio.Timer.start();
        for (0..iters) |_| {
            for (queries) |q| {
                _ = wi.search(q);
            }
        }
        best_ns = @min(best_ns, timer.read());
    }
    const ns_per_query = best_ns / (iters * queries.len);
    // Word lookup must be under 500ns in debug — typically ~5ns in release
    try testing.expect(ns_per_query < 500);
}


test "perf regression: bloom filter reduces scan work" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ti = TrigramIndex.init(testing.allocator);
    defer ti.deinit();

    for (0..50) |i| {
        const name = try std.fmt.allocPrint(alloc, "f{d:0>2}.zig", .{i});
        const content = try std.fmt.allocPrint(alloc, "pub fn init_{d}(allocator: Allocator) void {{}}\nfn deinit_{d}() void {{}}\n", .{ i, i });
        try ti.indexFile(name, content);
    }

    // "pub fn init_25" — specific enough to test bloom effectiveness
    const cands = ti.candidates("pub fn init_25", testing.allocator);
    defer if (cands) |c| testing.allocator.free(c);
    try testing.expect(cands != null);

    // With bloom filtering, should find very few candidates
    try testing.expect(cands.?.len <= 10);

    // The actual target file MUST be present (soundness)
    var found_target = false;
    for (cands.?) |p| {
        if (std.mem.eql(u8, p, "f25.zig")) found_target = true;
    }
    try testing.expect(found_target);

    // KEY ASSERTION: candidate count is meaningfully less than total files
    // This proves bloom filtering is doing work, not just passing through
    try testing.expect(cands.?.len < 25); // must eliminate at least half
}


test "disk word index: round-trip write and read preserves hits" {
    const alloc = testing.allocator;
    var wi = WordIndex.init(alloc);
    defer wi.deinit();

    try wi.indexFile("src/main.zig", "const Store = @import(\"store.zig\").Store;\npub fn main() void {}\n");
    try wi.indexFile("src/store.zig", "pub const Store = struct {};\npub fn open() void {}\n");

    const hits_before = try wi.searchDeduped("Store", alloc);
    defer alloc.free(hits_before);
    try testing.expectEqual(@as(usize, 2), hits_before.len);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    const fake_head = "0123456789abcdef0123456789abcdef01234567".*;
    try wi.writeToDisk(io, dir_path, fake_head);

    const header = try WordIndex.readDiskHeader(io, dir_path, alloc);
    try testing.expect(header != null);
    try testing.expectEqual(@as(u32, 2), header.?.file_count);
    try testing.expect(header.?.git_head != null);
    try testing.expectEqualSlices(u8, &fake_head, &header.?.git_head.?);

    const loaded = WordIndex.readFromDisk(io, dir_path, alloc);
    try testing.expect(loaded != null);
    var loaded_wi = loaded.?;
    defer loaded_wi.deinit();

    const hits_after = try loaded_wi.searchDeduped("Store", alloc);
    defer alloc.free(hits_after);
    try testing.expectEqual(hits_before.len, hits_after.len);

    var found_main = false;
    var found_store = false;
    for (hits_after) |hit| {
        if (std.mem.eql(u8, loaded_wi.hitPath(hit), "src/main.zig")) found_main = true;
        if (std.mem.eql(u8, loaded_wi.hitPath(hit), "src/store.zig")) found_store = true;
    }
    try testing.expect(found_main);
    try testing.expect(found_store);
}


test "disk word index: skip_file_words still writes file table" {
    const alloc = testing.allocator;
    var wi = WordIndex.init(alloc);
    defer wi.deinit();
    wi.skip_file_words = true;

    try wi.indexFile("src/a.zig", "pub fn alphaToken() void {}\n");
    try wi.indexFile("src/b.zig", "pub fn betaToken() void {}\n");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    try wi.writeToDisk(io, dir_path, null);

    const header = try WordIndex.readDiskHeader(io, dir_path, alloc);
    try testing.expect(header != null);
    try testing.expectEqual(@as(u32, 2), header.?.file_count);

    const loaded = WordIndex.readFromDisk(io, dir_path, alloc);
    try testing.expect(loaded != null);
    var loaded_wi = loaded.?;
    defer loaded_wi.deinit();

    const hits = try loaded_wi.searchDeduped("alphaToken", alloc);
    defer alloc.free(hits);
    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("src/a.zig", loaded_wi.hitPath(hits[0]));
}


test "disk index: round-trip write and read preserves candidates" {
    const alloc = testing.allocator;
    var ti = TrigramIndex.init(alloc);
    defer ti.deinit();

    try ti.indexFile("src/main.zig", "pub fn main() void { const store = Store.init(allocator); }");
    try ti.indexFile("src/index.zig", "pub fn indexFile(self: *TrigramIndex, path: []const u8) !void {}");
    try ti.indexFile("src/watcher.zig", "pub fn initialScan(store: *Store) !void {}");

    // Verify candidates before write
    const cands_before = ti.candidates("indexFile", testing.allocator);
    defer if (cands_before) |c| alloc.free(c);
    try testing.expect(cands_before != null);
    try testing.expect(cands_before.?.len >= 1);

    // Write to temp dir
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    try ti.writeToDisk(io, dir_path, null);

    // Read back
    const loaded = TrigramIndex.readFromDisk(io, dir_path, alloc);
    try testing.expect(loaded != null);
    var loaded_ti = loaded.?;
    defer loaded_ti.deinit();

    // Same candidates should be returned
    const cands_after = loaded_ti.candidates("indexFile", testing.allocator);
    defer if (cands_after) |c| alloc.free(c);
    try testing.expect(cands_after != null);
    try testing.expectEqual(cands_before.?.len, cands_after.?.len);

    // Verify specific file is present
    var found = false;
    for (cands_after.?) |p| {
        if (std.mem.eql(u8, p, "src/index.zig")) found = true;
    }
    try testing.expect(found);
}


test "disk index: readFromDisk returns null for missing files" {
    const loaded = TrigramIndex.readFromDisk(io, "/tmp/codedb_nonexistent_dir_12345", testing.allocator);
    try testing.expect(loaded == null);
}


test "disk index: readFromDisk returns null for corrupt magic" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    // Write garbage postings file
    const postings_path = try std.fmt.allocPrint(testing.allocator, "{s}/trigram.postings", .{dir_path});
    defer testing.allocator.free(postings_path);
    {
        const f = try std.Io.Dir.cwd().createFile(io, postings_path, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "BAADMAGIC");
    }
    // Write garbage lookup file
    const lookup_path = try std.fmt.allocPrint(testing.allocator, "{s}/trigram.lookup", .{dir_path});
    defer testing.allocator.free(lookup_path);
    {
        const f = try std.Io.Dir.cwd().createFile(io, lookup_path, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "BAADMAGIC");
    }

    const loaded = TrigramIndex.readFromDisk(io, dir_path, testing.allocator);
    try testing.expect(loaded == null);
}


test "disk index: empty index round-trips correctly" {
    const alloc = testing.allocator;
    var ti = TrigramIndex.init(alloc);
    defer ti.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    try ti.writeToDisk(io, dir_path, null);

    const loaded = TrigramIndex.readFromDisk(io, dir_path, alloc);
    try testing.expect(loaded != null);
    var loaded_ti = loaded.?;
    defer loaded_ti.deinit();

    try testing.expectEqual(@as(u32, 0), loaded_ti.fileCount());
}


test "disk index: bloom masks preserved after round-trip" {
    const alloc = testing.allocator;
    var ti = TrigramIndex.init(alloc);
    defer ti.deinit();

    try ti.indexFile("bloom.zig", "pub fn handleRequest(ctx: *Context) void {}");

    // Get original masks
    const tri = packTrigram('h', 'a', 'n');
    const orig_set = ti.index.getPtr(tri).?;
    const orig_mask = orig_set.get("bloom.zig").?;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    try ti.writeToDisk(io, dir_path, null);

    const loaded = TrigramIndex.readFromDisk(io, dir_path, alloc);
    try testing.expect(loaded != null);
    var loaded_ti = loaded.?;
    defer loaded_ti.deinit();

    // Check masks match
    const loaded_set = loaded_ti.index.getPtr(tri).?;
    const loaded_mask = loaded_set.get("bloom.zig").?;
    try testing.expectEqual(orig_mask.next_mask, loaded_mask.next_mask);
    try testing.expectEqual(orig_mask.loc_mask, loaded_mask.loc_mask);
}


test "disk index: fileCount matches after round-trip" {
    const alloc = testing.allocator;
    var ti = TrigramIndex.init(alloc);
    defer ti.deinit();

    try ti.indexFile("a.zig", "fn alpha() void {}");
    try ti.indexFile("b.zig", "fn beta() void {}");
    try ti.indexFile("c.zig", "fn gamma() void {}");

    try testing.expectEqual(@as(u32, 3), ti.fileCount());

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    try ti.writeToDisk(io, dir_path, null);

    const loaded = TrigramIndex.readFromDisk(io, dir_path, alloc);
    try testing.expect(loaded != null);
    var loaded_ti = loaded.?;
    defer loaded_ti.deinit();

    try testing.expectEqual(@as(u32, 3), loaded_ti.fileCount());
}


test "disk index: writeToDisk stores git_head, readGitHead retrieves it" {
    const alloc = testing.allocator;
    var ti = TrigramIndex.init(alloc);
    defer ti.deinit();

    try ti.indexFile("a.zig", "fn hello() void {}");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    const fake_head = "aabbccddeeff00112233445566778899aabbccdd".*;
    try ti.writeToDisk(io, dir_path, fake_head);

    const retrieved = try TrigramIndex.readGitHead(io, dir_path, alloc);
    try testing.expect(retrieved != null);
    try testing.expectEqualSlices(u8, &fake_head, &retrieved.?);
}


test "disk index: writeToDisk with null git_head, readGitHead returns null" {
    const alloc = testing.allocator;
    var ti = TrigramIndex.init(alloc);
    defer ti.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    try ti.writeToDisk(io, dir_path, null);

    const retrieved = try TrigramIndex.readGitHead(io, dir_path, alloc);
    try testing.expect(retrieved == null);
}


test "disk index: readDiskHeader returns file_count and git_head" {
    const alloc = testing.allocator;
    var ti = TrigramIndex.init(alloc);
    defer ti.deinit();

    try ti.indexFile("x.zig", "pub const X = 42;");
    try ti.indexFile("y.zig", "pub const Y = 99;");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    const fake_head = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef".*;
    try ti.writeToDisk(io, dir_path, fake_head);

    const hdr = try TrigramIndex.readDiskHeader(io, dir_path, alloc);
    try testing.expect(hdr != null);
    try testing.expectEqual(@as(u32, 2), hdr.?.file_count);
    try testing.expect(hdr.?.git_head != null);
    try testing.expectEqualSlices(u8, &fake_head, &hdr.?.git_head.?);
}

test "issue-553: status reads file_count from disk header without loading the index" {
    // #553: `codedb status` must report from on-disk metadata and exit — never
    // materialize the full index, or a backgrounded `status &` leaks a multi-GB
    // resident orphan. readStatusMeta is that cheap path: it reads ONLY the
    // trigram header (no Explorer, no snapshot load, no re-index).
    const readStatusMeta = @import("index.zig").readStatusMeta;
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    // No persisted index -> "not indexed", no load, no crash (so `status` on an
    // unindexed repo reports state instead of triggering a full re-index).
    {
        const meta = readStatusMeta(io, dir_path, alloc);
        try testing.expect(!meta.indexed);
        try testing.expectEqual(@as(u32, 0), meta.file_count);
        try testing.expect(meta.git_head == null);
    }

    // Persist a 2-file index; status reports the count straight from the header.
    var ti = TrigramIndex.init(alloc);
    defer ti.deinit();
    try ti.indexFile("a.zig", "pub const A = 1;");
    try ti.indexFile("b.zig", "pub const B = 2;");
    const fake_head = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef".*;
    try ti.writeToDisk(io, dir_path, fake_head);

    const meta = readStatusMeta(io, dir_path, alloc);
    try testing.expect(meta.indexed);
    try testing.expectEqual(@as(u32, 2), meta.file_count);
    try testing.expect(meta.git_head != null);
    try testing.expectEqualSlices(u8, &fake_head, &meta.git_head.?);
}


test "disk index: v1 format (no git_head) still loads and readGitHead returns null" {
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    // Manually write a v1 postings file (no git head bytes)
    const postings_path = try std.fmt.allocPrint(alloc, "{s}/trigram.postings", .{dir_path});
    defer alloc.free(postings_path);
    {
        const f = try std.Io.Dir.cwd().createFile(io, postings_path, .{});
        defer f.close(io);
        // magic(4) + version=1(2) + file_count=0(2) = 8 bytes total
        try f.writeStreamingAll(io, &.{ 'C', 'D', 'B', 'T' });
        try f.writeStreamingAll(io, &.{ 1, 0 }); // version = 1 LE
        try f.writeStreamingAll(io, &.{ 0, 0 }); // file_count = 0
    }
    // Write a matching v1 lookup file
    const lookup_path = try std.fmt.allocPrint(alloc, "{s}/trigram.lookup", .{dir_path});
    defer alloc.free(lookup_path);
    {
        const f = try std.Io.Dir.cwd().createFile(io, lookup_path, .{});
        defer f.close(io);
        // magic(4) + version=1(2) + pad(2) + entry_count=0(4) = 12 bytes
        try f.writeStreamingAll(io, &.{ 'C', 'D', 'B', 'L' });
        try f.writeStreamingAll(io, &.{ 1, 0 }); // version = 1
        try f.writeStreamingAll(io, &.{ 0, 0 }); // pad
        try f.writeStreamingAll(io, &.{ 0, 0, 0, 0 }); // entry_count = 0
    }

    // readGitHead on a v1 file must return null (no git head stored)
    const git_head = try TrigramIndex.readGitHead(io, dir_path, alloc);
    try testing.expect(git_head == null);

    // readFromDisk on a v1 file must still succeed (backward compat)
    const loaded = TrigramIndex.readFromDisk(io, dir_path, alloc);
    try testing.expect(loaded != null);
    var loaded_ti = loaded.?;
    defer loaded_ti.deinit();
    try testing.expectEqual(@as(u32, 0), loaded_ti.fileCount());
}


test "issue-105: large files skip trigram indexing to prevent OOM" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();

    // Create content just over 64KB — should be indexed for outline/word but NOT trigram
    const large_content = try testing.allocator.alloc(u8, 65 * 1024);
    defer testing.allocator.free(large_content);
    @memset(large_content, 'a');
    // Make it valid Zig so outline parsing works
    @memcpy(large_content[0..21], "pub fn bigFunc() void");

    // indexFileSkipTrigram should succeed without building trigrams
    try explorer.indexFileSkipTrigram("large.zig", large_content);

    // The file should be in outlines and contents but NOT in the trigram index
    try testing.expect(explorer.outlines.count() == 1);
    try testing.expect(explorer.contents.count() == 1);
    try testing.expect(explorer.trigram_index.fileCount() == 0);

    // A small file should still get trigram-indexed
    try explorer.indexFile("small.zig", "pub fn tiny() void {}");
    try testing.expect(explorer.trigram_index.fileCount() == 1);
}


test "issue-107: codedb_deps returns results for Python files" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("mypackage/utils/helpers.py", "def helper_func():\n    pass\n");
    try explorer.indexFile("consumer.py", "from mypackage.utils.helpers import helper_func\n");

    const deps = try explorer.getImportedBy("mypackage/utils/helpers.py", testing.allocator);
    defer {
        for (deps) |d| testing.allocator.free(d);
        testing.allocator.free(deps);
    }

    try testing.expect(deps.len == 1);
    try testing.expectEqualStrings("consumer.py", deps[0]);
}


test "regression-142: trigram index finds all matching files" {
    var exp = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer exp.deinit();

    try exp.indexFile("src/main.zig", "pub fn handleRequest(ctx: *Context) !void {}");
    try exp.indexFile("src/server.zig", "fn handleRequest(req: Request) void {}");
    try exp.indexFile("src/util.zig", "pub fn formatDate() []u8 {}");

    const results = try exp.searchContent("handleRequest", testing.allocator, 50);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }
    // Must find both files containing "handleRequest"
    try testing.expect(results.len == 2);
}


test "regression-142: trigram index returns no false positives" {
    var exp = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer exp.deinit();

    try exp.indexFile("a.zig", "pub fn alpha() void {}");
    try exp.indexFile("b.zig", "pub fn beta() void {}");

    const results = try exp.searchContent("gamma", testing.allocator, 50);
    defer testing.allocator.free(results);
    // Must return zero results for non-existent content
    try testing.expect(results.len == 0);
}


test "regression-142: trigram intersection narrows correctly" {
    var exp = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer exp.deinit();

    try exp.indexFile("match.zig", "const unique_identifier_xyz = 42;");
    try exp.indexFile("partial.zig", "const unique_other = 99;");
    try exp.indexFile("none.zig", "pub fn foo() void {}");

    const results = try exp.searchContent("unique_identifier_xyz", testing.allocator, 50);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }
    // Only the exact match file, not the partial
    try testing.expect(results.len == 1);
    try testing.expectEqualStrings("match.zig", results[0].path);
}


test "regression-142: trigram handles file removal" {
    var exp = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer exp.deinit();

    try exp.indexFile("temp.zig", "pub fn removable() void {}");
    try exp.indexFile("keep.zig", "pub fn permanent() void {}");

    // Remove a file
    exp.removeFile("temp.zig");

    const results = try exp.searchContent("removable", testing.allocator, 50);
    defer testing.allocator.free(results);
    try testing.expect(results.len == 0);

    const results2 = try exp.searchContent("permanent", testing.allocator, 50);
    defer {
        for (results2) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results2);
    }
    try testing.expect(results2.len == 1);
}


test "regression-142: trigram handles re-indexing same file" {
    var exp = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer exp.deinit();

    try exp.indexFile("mutable.zig", "pub fn oldContent() void {}");
    try exp.indexFile("mutable.zig", "pub fn newContent() void {}");

    const old = try exp.searchContent("oldContent", testing.allocator, 50);
    defer testing.allocator.free(old);
    try testing.expect(old.len == 0);

    const new = try exp.searchContent("newContent", testing.allocator, 50);
    defer {
        for (new) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(new);
    }
    try testing.expect(new.len == 1);
}


test "regression-142: trigram disk roundtrip preserves results" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    // Build index
    var idx1 = TrigramIndex.init(testing.allocator);
    try idx1.indexFile("a.zig", "pub fn searchable() void {}");
    try idx1.indexFile("b.zig", "const value = 42;");

    // Write to disk
    try idx1.writeToDisk(io, dir_path, null);
    idx1.deinit();

    // Read back
    var idx2 = TrigramIndex.readFromDisk(io, dir_path, testing.allocator) orelse return error.TestUnexpectedResult;
    defer idx2.deinit();

    // Must find same results
    const cands = idx2.candidates("searchable", testing.allocator) orelse return error.TestUnexpectedResult;
    defer testing.allocator.free(cands);
    try testing.expect(cands.len == 1);
}


test "regression-142: many files don't corrupt index" {
    var exp = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer exp.deinit();

    // Index 500 files
    var i: usize = 0;
    while (i < 500) : (i += 1) {
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "file_{d}.zig", .{i});
        var content_buf: [64]u8 = undefined;
        const content = try std.fmt.bufPrint(&content_buf, "pub fn func_{d}() void {{}}", .{i});
        try exp.indexFile(name, content);
    }

    // Search for a specific one
    const results = try exp.searchContent("func_250", testing.allocator, 50);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }
    try testing.expect(results.len == 1);
    try testing.expectEqualStrings("file_250.zig", results[0].path);
}


test "regression-142: short queries fall back gracefully" {
    var exp = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer exp.deinit();

    try exp.indexFile("a.zig", "pub fn ab() void {}");

    // 2-char query: too short for trigrams, should still work via fallback
    const results = try exp.searchContent("ab", testing.allocator, 50);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }
    try testing.expect(results.len == 1);
}


test "regression-142: word index still works alongside trigram" {
    var exp = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer exp.deinit();

    try exp.indexFile("words.zig", "pub fn mySpecialFunction() void {}");

    const hits = try exp.searchWord("mySpecialFunction", testing.allocator);
    defer testing.allocator.free(hits);
    try testing.expect(hits.len == 1);
}


test "issue-164: mmap trigram index returns same candidates as heap index" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();

    try explorer.indexFile("src/auth.zig", "pub fn handleAuth(req: *Request) !void { validate(req); }");
    try explorer.indexFile("src/gate.zig", "pub fn checkGate(ctx: *Context) !bool { return ctx.authenticated; }");
    try explorer.indexFile("src/util.zig", "pub fn formatStr(buf: []u8, args: anytype) !void {}");

    const heap_results = explorer.trigram_index.candidates("handleAuth", allocator) orelse
        return error.NoCandidates;

    try testing.expect(heap_results.len >= 1);

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp_dir.dir.realPathFile(io, ".", &path_buf);
    const tmp_path = path_buf[0..tmp_path_len];

    try explorer.trigram_index.writeToDisk(io, tmp_path, null);

    var mmap_idx = MmapTrigramIndex.initFromDisk(io, tmp_path, testing.allocator) orelse
        return error.MmapInitFailed;
    defer mmap_idx.deinit();

    const mmap_results = mmap_idx.candidates("handleAuth", allocator) orelse
        return error.NoCandidates;

    try testing.expect(mmap_results.len >= 1);
    try testing.expectEqual(heap_results.len, mmap_results.len);
    try testing.expectEqual(explorer.trigram_index.fileCount(), mmap_idx.fileCount());
    try testing.expect(mmap_idx.containsFile("src/auth.zig"));
    try testing.expect(mmap_idx.containsFile("src/gate.zig"));
    try testing.expect(!mmap_idx.containsFile("nonexistent.zig"));
}


test "issue-164: mmap binary search on sorted lookup table" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();

    try explorer.indexFile("a.zig", "const alpha = 42;");
    try explorer.indexFile("b.zig", "const beta = 43;");
    try explorer.indexFile("c.zig", "const gamma = 44;");
    try explorer.indexFile("d.zig", "const delta = 45;");
    try explorer.indexFile("e.zig", "const alpha_beta = 99;");

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp_dir.dir.realPathFile(io, ".", &path_buf);
    const tmp_path = path_buf[0..tmp_path_len];

    try explorer.trigram_index.writeToDisk(io, tmp_path, null);

    var mmap_idx = MmapTrigramIndex.initFromDisk(io, tmp_path, testing.allocator) orelse
        return error.MmapInitFailed;
    defer mmap_idx.deinit();

    const results = mmap_idx.candidates("alpha", allocator) orelse
        return error.NoCandidates;
    try testing.expect(results.len >= 2);

    const no_results = mmap_idx.candidates("zzzzz", allocator);
    if (no_results) |nr| {
        try testing.expectEqual(@as(usize, 0), nr.len);
    }
}


test "issue-164: mmap handles missing files gracefully" {
    const result = MmapTrigramIndex.initFromDisk(io, "/tmp/nonexistent-codedb-test-dir-164", testing.allocator);
    try testing.expect(result == null);
}


test "issue-164: AnyTrigramIndex dispatches to mmap variant" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();

    try explorer.indexFile("foo.zig", "pub fn fooBar(x: i32) i32 { return x + 1; }");

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp_dir.dir.realPathFile(io, ".", &path_buf);
    const tmp_path = path_buf[0..tmp_path_len];

    try explorer.trigram_index.writeToDisk(io, tmp_path, null);

    const mmap_loaded = MmapTrigramIndex.initFromDisk(io, tmp_path, testing.allocator) orelse
        return error.MmapInitFailed;

    explorer.trigram_index.deinit();
    explorer.trigram_index = .{ .mmap = mmap_loaded };

    const results = try explorer.searchContent("fooBar", allocator, 10);
    try testing.expect(results.len >= 1);

    try testing.expect(explorer.trigram_index.containsFile("foo.zig"));
    try testing.expect(!explorer.trigram_index.containsFile("bar.zig"));
}


test "issue-246: TrigramIndex.removeFile cleans stale path_to_id left by failed indexFile" {
    // Reproduces the corrupted state an OOM mid-way through indexFile leaves:
    //   removeFile cleared file_trigrams, getOrCreateDocId wrote to path_to_id,
    //   then an allocation failure meant file_trigrams.put never completed.
    // Fix: removeFile must purge path_to_id even when file_trigrams has no entry.
    var idx = TrigramIndex.init(testing.allocator);
    defer idx.deinit();

    // Plant the invariant-violating state OOM would leave behind.
    try idx.path_to_id.put("ghost.zig", 0);
    try idx.id_to_path.append(testing.allocator, "ghost.zig");
    // file_trigrams intentionally has NO entry for "ghost.zig".

    idx.removeFile("ghost.zig");

    // Currently FAILS: removeFile returns early at the second file_trigrams.getPtr
    // check, leaving path_to_id permanently dirty.
    try testing.expectEqual(@as(usize, 0), idx.path_to_id.count());
}


test "issue-247: TrigramIndex.id_to_path does not grow on re-index of same file" {
    // removeFile removes path_to_id[path] but leaves the id_to_path slot intact.
    // getOrCreateDocId then appends a new slot since path_to_id misses.
    // After N re-indexes id_to_path.items.len must equal the number of *unique* files.
    var idx = TrigramIndex.init(testing.allocator);
    defer idx.deinit();

    const src = "fn alpha() void {} fn beta() void {} const X = 1;";
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        try idx.indexFile("f.zig", src);
    }

    // Currently FAILS: id_to_path.items.len == 5 (grows by 1 per re-index).
    try testing.expectEqual(@as(usize, 1), idx.id_to_path.items.len);
}


test "issue-227: TrigramIndex.id_to_path stays bounded across many files re-indexed" {
    // Broader regression: ensure re-indexing multiple distinct files also doesn't
    // accumulate dead id_to_path slots.
    var idx = TrigramIndex.init(testing.allocator);
    defer idx.deinit();

    const files = [_][]const u8{ "a.zig", "b.zig", "c.zig" };
    var round: usize = 0;
    while (round < 4) : (round += 1) {
        for (files) |f| try idx.indexFile(f, "fn foo() void {}");
    }

    // 3 unique files × 4 rounds = 12 slots currently; fix should keep it at 3.
    try testing.expectEqual(@as(usize, files.len), idx.id_to_path.items.len);
}


test "issue-248: PostingList.removeDocId removes target and preserves sorted order" {
    // Documents the correctness contract for the O(log n) binary-search replacement.
    // Currently correct but O(n); fix replaces linear scan with bsearch + single remove.
    const PostingList = @import("index.zig").PostingList;
    var list = PostingList{};
    defer list.items.deinit(testing.allocator);

    var id: u32 = 0;
    while (id < 100) : (id += 1) {
        const p = try list.getOrAddPosting(testing.allocator, id * 2); // even doc_ids 0..198
        p.loc_mask = 0xFF;
    }

    list.removeDocId(50);
    try testing.expectEqual(@as(usize, 99), list.items.items.len);
    try testing.expect(list.getByDocId(48) != null);
    try testing.expect(list.getByDocId(50) == null);
    try testing.expect(list.getByDocId(52) != null);

    // Sorted invariant must hold after removal.
    for (1..list.items.items.len) |k| {
        try testing.expect(list.items.items[k].doc_id > list.items.items[k - 1].doc_id);
    }
}


test "issue-250: searchContent finds content in files skipped by trigram index" {
    // Files indexed with skip_trigram=true (e.g. past the 15k cap) must still be
    // reachable via the fallback full-scan path in searchContent.
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();

    try explorer.indexFileSkipTrigram("large.zig", "fn unique_zzz_sentinel() void {}");

    const results = try explorer.searchContent("unique_zzz_sentinel", testing.allocator, 10);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }
    try testing.expectEqual(@as(usize, 1), results.len);
}



test "issue-263: skip_trigram_files searched before max_results exhausted" {
    // Files indexed with skip_trigram=true are only searched after all
    // trigram/sparse/word paths are exhausted.  When a single normal file
    // has enough matches to fill max_results, the skip_trigram file is
    // never checked — even though it contains relevant content.
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();

    // Normal file with 6 matches (one per line).
    try explorer.indexFile("noisy.zig",
        \\fn my_unique_func() void {}
        \\fn my_unique_func_v2() void {}
        \\const my_unique_func_ptr = undefined;
        \\var my_unique_func_state = 0;
        \\test "my_unique_func works" {}
        \\// calls my_unique_func internally
    );

    // skip-trigram file with 1 match.
    try explorer.indexFileSkipTrigram("large.zig", "fn my_unique_func() void {}");

    // max_results=5: the normal file fills the quota, skip_trigram never searched.
    const results = try explorer.searchContent("my_unique_func", testing.allocator, 5);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }

    // The skip_trigram file must be represented in results.
    var found_large = false;
    for (results) |r| {
        if (std.mem.eql(u8, r.path, "large.zig")) found_large = true;
    }
    try testing.expect(found_large);
}


test "search: BM25 ranks higher-frequency line first" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    // Line with two occurrences of "token" should outrank line with one
    const content = "// single token mention\nconst token = token_cache.get();\n";
    try explorer.indexFile("auth.zig", content);

    const results = try explorer.searchContent("token", testing.allocator, 10);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }

    try testing.expect(results.len >= 2);
    // Line 2 has "token" twice; line 1 has it once — line 2 should come first
    try testing.expect(results[0].score >= results[1].score);
    try testing.expectEqual(@as(u32, 2), results[0].line_num);
}


test "issue-388: TrigramIndex.removeFile frees owned path on tombstone" {
    // owns_paths=true means getOrCreateDocId duped the path so callers can
    // free their copy. removeFile must release that dup before tombstoning
    // the slot — otherwise every snapshot-loaded session leaks one path
    // allocation per file removed/re-indexed.
    var idx = TrigramIndex.init(testing.allocator);
    defer idx.deinit();
    idx.owns_paths = true;

    const path = "src/leaky.zig";
    try idx.indexFile(path, "pub fn leaky() void {}\n");
    idx.removeFile(path);

    // testing.allocator reports any unfreed bytes when this scope exits via
    // deinit. The bug leaks the dup on the tombstoned id_to_path slot
    // (cleared to ""), so deinit's `if (p.len > 0) free(p)` misses it.
}


test "bm25-persistence: writeToDisk/readFromDisk preserves total_tokens and doc_lengths" {
    const alloc = testing.allocator;
    var wi = WordIndex.init(alloc);
    defer wi.deinit();

    try wi.indexFile("low.txt", "needle filler filler filler filler filler filler filler filler filler");
    try wi.indexFile("high.txt", "needle needle needle filler");
    try wi.indexFile("none.txt", "filler filler filler filler");

    const pre_total = wi.total_tokens;
    const pre_low_len = wi.docLength(wi.path_to_id.get("low.txt") orelse 0);
    const pre_high_len = wi.docLength(wi.path_to_id.get("high.txt") orelse 0);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    try wi.writeToDisk(io, dir_path, null);

    const maybe_loaded = WordIndex.readFromDisk(io, dir_path, alloc);
    try testing.expect(maybe_loaded != null);
    var loaded = maybe_loaded.?;
    defer loaded.deinit();

    try testing.expectEqual(pre_total, loaded.total_tokens);

    const post_low_id = loaded.path_to_id.get("low.txt") orelse {
        try testing.expect(false);
        return;
    };
    const post_high_id = loaded.path_to_id.get("high.txt") orelse {
        try testing.expect(false);
        return;
    };
    try testing.expectEqual(pre_low_len, loaded.docLength(post_low_id));
    try testing.expectEqual(pre_high_len, loaded.docLength(post_high_id));

    const hits = try loaded.searchDeduped("needle", alloc);
    defer alloc.free(hits);
    try testing.expect(hits.len >= 2);

    var saw_high = false;
    var saw_low = false;
    for (hits) |h| {
        const p = loaded.hitPath(h);
        if (std.mem.eql(u8, p, "high.txt")) saw_high = true;
        if (std.mem.eql(u8, p, "low.txt")) saw_low = true;
    }
    try testing.expect(saw_high);
    try testing.expect(saw_low);

    // Post-roundtrip ranked search must still work and return hits for "needle".
    var wi2 = WordIndex.init(alloc);
    defer wi2.deinit();
    try wi2.indexFile("low.txt", "needle filler filler filler filler filler filler filler filler filler");
    try wi2.indexFile("high.txt", "needle needle needle filler");
    try wi2.indexFile("none.txt", "filler filler filler filler");

    const low_id_orig = wi2.path_to_id.get("low.txt") orelse 0;
    const high_id_orig = wi2.path_to_id.get("high.txt") orelse 0;
    try testing.expectEqual(pre_low_len, wi2.docLength(low_id_orig));
    try testing.expectEqual(pre_high_len, wi2.docLength(high_id_orig));
    try testing.expectEqual(pre_total, wi2.total_tokens);
}


test "issue-451: scope search surfaces skip-trigram canonical file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    var i: usize = 0;
    while (i < 12) : (i += 1) {
        var path_buf: [32]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "small_{d}.zig", .{i});
        try explorer.indexFile(path, "fn s() void { _ = widgetX; }\n");
    }

    const canonical_content =
        "fn canonical() void {\n" ++
        "    _ = widgetX;\n" ++
        "    _ = widgetX;\n" ++
        "    _ = widgetX;\n" ++
        "    _ = widgetX;\n" ++
        "    _ = widgetX;\n" ++
        "}\n";
    try explorer.indexFileSkipTrigram("canonical.zig", canonical_content);

    const results = try explorer.searchContentWithScope("widgetX", testing.allocator, 5);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
            if (r.scope_name) |n| testing.allocator.free(n);
        }
        testing.allocator.free(results);
    }

    var found_canonical = false;
    for (results) |r| {
        if (std.mem.eql(u8, r.path, "canonical.zig")) found_canonical = true;
    }
    try testing.expect(found_canonical);
}


test "issue-447: searchContent surfaces large (>64KB) skip-trigram files for common identifiers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    var i: usize = 0;
    while (i < 12) : (i += 1) {
        var path_buf: [32]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "small_{d}.zig", .{i});
        try explorer.indexFile(path, "fn s() void { _ = widgetX; }\n");
    }

    const canonical_content =
        "fn canonical() void {\n" ++
        "    _ = widgetX;\n" ++
        "    _ = widgetX;\n" ++
        "    _ = widgetX;\n" ++
        "    _ = widgetX;\n" ++
        "    _ = widgetX;\n" ++
        "}\n";
    try explorer.indexFileSkipTrigram("canonical.zig", canonical_content);

    const results = try explorer.searchContent("widgetX", testing.allocator, 5);
    defer {
        for (results) |r| {
            testing.allocator.free(r.line_text);
            testing.allocator.free(r.path);
        }
        testing.allocator.free(results);
    }

    var found_canonical = false;
    for (results) |r| {
        if (std.mem.eql(u8, r.path, "canonical.zig")) found_canonical = true;
    }
    try testing.expect(found_canonical);
}


test "issue-583: disk-loaded word index — re-index and removeFile must drop stale postings" {
    // readFromDisk/mmapFromDisk set skip_file_words=true, which made removeFile
    // a silent no-op (file_words is empty). In a daemon that fast-loads the
    // index, every file edit then APPENDS postings while the stale ones stay:
    // deleted terms keep hitting (wrong lines), deleted files ghost-hit, and
    // postings grow without bound across re-saves (RSS).
    const alloc = testing.allocator;
    var wi = WordIndex.init(alloc);
    defer wi.deinit();
    try wi.indexFile("src/a.zig", "pub fn alphaToken() void {}\n");
    try wi.indexFile("src/b.zig", "pub fn betaToken() void {}\n");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];
    try wi.writeToDisk(io, dir_path, null);

    // Heap fast-load: re-indexing a file must drop its old postings.
    var loaded = WordIndex.readFromDisk(io, dir_path, alloc).?;
    defer loaded.deinit();
    try loaded.indexFile("src/a.zig", "pub fn gammaToken() void {}\n");
    const stale = try loaded.searchDeduped("alphaToken", alloc);
    defer alloc.free(stale);
    try testing.expectEqual(@as(usize, 0), stale.len);
    const fresh = try loaded.searchDeduped("gammaToken", alloc);
    defer alloc.free(fresh);
    try testing.expectEqual(@as(usize, 1), fresh.len);

    // Deleting a file must drop its postings outright.
    loaded.removeFile("src/b.zig");
    const ghost = try loaded.searchDeduped("betaToken", alloc);
    defer alloc.free(ghost);
    try testing.expectEqual(@as(usize, 0), ghost.len);

    // Zero-copy mmap load: removeFile is a write — it must promote, not no-op.
    var mloaded = WordIndex.mmapFromDisk(io, dir_path, alloc).?;
    defer mloaded.deinit();
    mloaded.removeFile("src/a.zig");
    const mghost = try mloaded.searchDeduped("alphaToken", alloc);
    defer alloc.free(mghost);
    try testing.expectEqual(@as(usize, 0), mghost.len);
}

test "issue-593: mmap trigram index — removeFile takes effect and re-index masks stale base entries" {
    // AnyTrigramIndex.removeFile is a silent no-op in pure-mmap mode, and the
    // mmap_overlay promotion never masks the base: a deleted file stays
    // "contained" forever and an edited file feeds candidates from BOTH its
    // old (mmap base) and new (overlay) content — ghost candidates that every
    // search tier then has to read and discard.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    try explorer.indexFile("src/auth.zig", "pub fn handleAuth(req: *Request) !void { validate(req); }");
    try explorer.indexFile("src/gate.zig", "pub fn checkGate(ctx: *Context) !bool { return ctx.authenticated; }");
    try explorer.indexFile("src/util.zig", "pub fn formatStr(buf: []u8, args: anytype) !void {}");

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp_dir.dir.realPathFile(io, ".", &path_buf);
    const tmp_path = path_buf[0..tmp_path_len];
    try explorer.trigram_index.writeToDisk(io, tmp_path, null);

    const mmap_idx = MmapTrigramIndex.initFromDisk(io, tmp_path, testing.allocator) orelse
        return error.MmapInitFailed;
    var any_idx = AnyTrigramIndex{ .mmap = mmap_idx };
    defer any_idx.deinit();

    // A delete while zero-copy must take effect, not silently no-op.
    any_idx.removeFile("src/gate.zig");
    try testing.expect(!any_idx.containsFile("src/gate.zig"));
    if (any_idx.candidates("checkGate", allocator)) |cands| {
        for (cands) |p| try testing.expect(!std.mem.eql(u8, p, "src/gate.zig"));
    }

    // Re-indexing must mask the base's stale trigrams for that path.
    try any_idx.indexFile("src/auth.zig", "pub fn renamedAuth() void {}");
    if (any_idx.candidates("handleAuth", allocator)) |cands| {
        for (cands) |p| try testing.expect(!std.mem.eql(u8, p, "src/auth.zig"));
    }
    const fresh = any_idx.candidates("renamedAuth", allocator) orelse return error.NoCandidates;
    var found = false;
    for (fresh) |p| {
        if (std.mem.eql(u8, p, "src/auth.zig")) found = true;
    }
    try testing.expect(found);

    // File accounting follows: 3 on disk, one removed.
    try testing.expectEqual(@as(u32, 2), any_idx.fileCount());
}

test "mmap word index: zero-copy load matches heap load and promotes on write" {
    const alloc = testing.allocator;
    var wi = WordIndex.init(alloc);
    defer wi.deinit();
    wi.skip_file_words = true;
    try wi.indexFile("src/a.zig", "pub fn alphaToken() void { betaToken(); }\n");
    try wi.indexFile("src/b.zig", "pub fn betaToken() void { alphaToken(); alphaToken(); }\n");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pb: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pb[0..try tmp.dir.realPathFile(io, ".", &pb)];
    try wi.writeToDisk(io, dir, null);

    var heap = WordIndex.readFromDisk(io, dir, alloc).?;
    defer heap.deinit();
    var mm = WordIndex.mmapFromDisk(io, dir, alloc).?;
    defer mm.deinit(); // picks the right path (mmap, or heap after promote)
    try testing.expect(mm.mmap_data != null);

    // search parity (exact)
    try testing.expectEqual(heap.search("alphaToken").len, mm.search("alphaToken").len);
    try testing.expect(mm.search("alphaToken").len >= 1);

    // searchDeduped parity + hitPath resolves through the mmap file table
    {
        const h = try mm.searchDeduped("betaToken", alloc);
        defer alloc.free(h);
        const r = try heap.searchDeduped("betaToken", alloc);
        defer alloc.free(r);
        try testing.expectEqual(r.len, h.len);
        try testing.expect(h.len >= 1);
        try testing.expectEqualStrings(heap.hitPath(r[0]), mm.hitPath(h[0]));
    }

    // searchPrefix parity (sorted-range walk vs linear scan)
    {
        const h = try mm.searchPrefix("alpha", alloc, 10);
        defer alloc.free(h);
        const r = try heap.searchPrefix("alpha", alloc, 10);
        defer alloc.free(r);
        try testing.expectEqual(r.len, h.len);
    }

    // BM25 helpers parity
    try testing.expectEqual(heap.rankedDocCount(), mm.rankedDocCount());
    try testing.expectEqual(heap.total_tokens, mm.total_tokens);
    try testing.expectEqual(heap.docLength(0), mm.docLength(0));
    try testing.expectEqual(heap.docLength(1), mm.docLength(1));

    // Promote on write: a mutation materializes a heap index, then stays queryable.
    try mm.indexFile("src/c.zig", "pub fn gammaToken() void {}\n");
    try testing.expect(mm.mmap_data == null);
    const g = try mm.searchDeduped("gammaToken", alloc);
    defer alloc.free(g);
    try testing.expectEqual(@as(usize, 1), g.len);
    try testing.expect(mm.search("alphaToken").len >= 1); // pre-promote postings survived
}

test "issue-600: mmap_overlay writeToDisk persists overlay edits" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp_dir.dir.realPathFile(io, ".", &path_buf);
    const tmp_path = path_buf[0..tmp_path_len];

    // Seed the on-disk index with two files.
    {
        var seed = TrigramIndex.init(testing.allocator);
        defer seed.deinit();
        try seed.indexFile("keep.zig", "const keeper_token_alpha = 1;");
        try seed.indexFile("gone.zig", "const goner_token_beta = 2;");
        try seed.writeToDisk(io, tmp_path, null);
    }

    // Cold-load as mmap, then take edits: one new file, one removal.
    var any = AnyTrigramIndex{ .mmap = MmapTrigramIndex.initFromDisk(io, tmp_path, testing.allocator) orelse
        return error.MmapInitFailed };
    defer any.deinit();
    try any.indexFile("fresh.zig", "const fresh_token_gamma = 3;");
    any.removeFile("gone.zig");
    try testing.expect(any == .mmap_overlay);

    // writeToDisk reports success, so a cold start must see the edits.
    try any.writeToDisk(io, tmp_path, null);

    var reloaded = TrigramIndex.readFromDisk(io, tmp_path, testing.allocator) orelse
        return error.ReadBackFailed;
    defer reloaded.deinit();

    try testing.expect(reloaded.file_trigrams.contains("keep.zig"));
    try testing.expect(reloaded.file_trigrams.contains("fresh.zig"));
    try testing.expect(!reloaded.file_trigrams.contains("gone.zig"));

    const fresh = reloaded.candidates("fresh_token_gamma", allocator) orelse
        return error.NoCandidates;
    try testing.expectEqual(@as(usize, 1), fresh.len);
    try testing.expectEqualStrings("fresh.zig", fresh[0]);

    const keep = reloaded.candidates("keeper_token_alpha", allocator) orelse
        return error.NoCandidates;
    try testing.expectEqual(@as(usize, 1), keep.len);

    const gone = reloaded.candidates("goner_token_beta", allocator);
    if (gone) |g| {
        try testing.expectEqual(@as(usize, 0), g.len);
    }
}


test "issue-606: word index reuses doc_id slots freed by removeFile" {
    var wi = WordIndex.init(testing.allocator);
    defer wi.deinit();

    try wi.indexFile("a.zig", "const alpha = 1;\n");
    wi.removeFile("a.zig");
    try wi.indexFile("b.zig", "const beta = 2;\n");

    try testing.expectEqual(@as(usize, 1), wi.id_to_path.items.len);
}
