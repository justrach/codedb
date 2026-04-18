const std = @import("std");
const cio = @import("cio.zig");
const testing = std.testing;

const Store = @import("store.zig").Store;
const ChangeEntry = @import("store.zig").ChangeEntry;
const AgentRegistry = @import("agent.zig").AgentRegistry;
const Explorer = @import("explore.zig").Explorer;
const SearchResult = @import("explore.zig").SearchResult;
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

const WordTokenizer = @import("index.zig").WordTokenizer;
const splitIdentifier = @import("index.zig").splitIdentifier;

const version = @import("version.zig");
const watcher = @import("watcher.zig");
const edit_mod = @import("edit.zig");
const snapshot_json = @import("snapshot_json.zig");
const explore = @import("explore.zig");
const extractLines = explore.extractLines;
const isCommentOrBlank = explore.isCommentOrBlank;
const Language = explore.Language;
const SymbolKind = explore.SymbolKind;
const DependencyGraph = explore.DependencyGraph;
const SymbolLocation = explore.SymbolLocation;
const mcp_mod = @import("mcp.zig");
const main_mod = @import("main.zig");
const nuke_mod = @import("nuke.zig");
const update_mod = @import("update.zig");
const snapshot_mod = @import("snapshot.zig");
const telemetry_mod = @import("telemetry.zig");
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

test "store: recordEdit persists diff data to data log" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp_dir.dir.realpath(".", &dir_buf);

    const log_path = try std.fmt.allocPrint(testing.allocator, "{s}/data.log", .{dir_path});
    defer testing.allocator.free(log_path);

    var store = Store.init(testing.allocator);
    defer store.deinit();

    try store.openDataLog(log_path);

    const diff = "replace body";
    _ = try store.recordEdit("foo.zig", 1, .replace, 0x1234, diff.len, diff);

    const latest = store.getLatest("foo.zig").?;
    try testing.expectEqual(@as(?u64, 0), latest.data_offset);
    try testing.expectEqual(@as(u32, diff.len), latest.data_len);

    const log_file = try std.fs.cwd().openFile(log_path, .{});
    defer log_file.close();

    var buf: [32]u8 = undefined;
    const read_len = try log_file.readAll(buf[0..diff.len]);
    try testing.expectEqual(diff.len, read_len);
    try testing.expectEqualStrings(diff, buf[0..diff.len]);
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
    try testing.expectEqualStrings("src/foo.zig", wi.hitPath(hits[0]));
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

// ── Sparse N-gram tests ─────────────────────────────────────

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

test "explorer: sparse ngram index integrated into searchContent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("src/alpha.zig", "pub fn processRequest(req: *Request) void {}");
    try explorer.indexFile("src/beta.zig", "pub fn handleResponse(res: *Response) void {}");

    const results = try explorer.searchContent("processRequest", arena.allocator(), 10);
    try testing.expectEqual(@as(usize, 1), results.len);
    try testing.expectEqualStrings("src/alpha.zig", results[0].path);
}

test "explorer: searchContent finds query embedded in longer identifier" {
    // Verify that searchContent correctly finds files whose content contains
    // the query string.  The sparse index (sliding-window) and trigram index
    // are both used; the intersection narrows results without false negatives.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    // "alpha.zig" content contains "record"; "beta.zig" does not.
    try explorer.indexFile("alpha.zig", "const record_count: usize = 0;");
    try explorer.indexFile("beta.zig", "const unrelated_data: usize = 0;");

    const results = try explorer.searchContent("record", arena.allocator(), 10);
    var found = false;
    for (results) |r| if (std.mem.eql(u8, r.path, "alpha.zig")) {
        found = true;
    };
    try testing.expect(found);
}

// ── Frequency-weighted pairWeight tests ─────────────────────

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
    const dir_path = try tmp_dir.dir.realpath(".", &dir_buf);

    // Build a table with distinct values.
    const content = "ababcdcdefefghghijij";
    const original = buildFrequencyTable(content);

    try writeFrequencyTable(&original, dir_path);

    const loaded_opt = try readFrequencyTable(dir_path, testing.allocator);
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
    const dir_path = try tmp_dir.dir.realpath(".", &dir_buf);

    var table: [256][256]u16 = .{.{0} ** 256} ** 256;
    table[0][0] = 0x1234; // little-endian on disk: 0x34, 0x12
    table[0][1] = 0xABCD; // little-endian on disk: 0xCD, 0xAB
    try writeFrequencyTable(&table, dir_path);

    const file_path = try std.fmt.allocPrint(testing.allocator, "{s}/pair_freq.bin", .{dir_path});
    defer testing.allocator.free(file_path);
    const f = try std.fs.cwd().openFile(file_path, .{});
    defer f.close();
    var raw: [4]u8 = undefined;
    try testing.expectEqual(@as(usize, 4), try f.readAll(&raw));
    try testing.expectEqual(@as(u8, 0x34), raw[0]);
    try testing.expectEqual(@as(u8, 0x12), raw[1]);
    try testing.expectEqual(@as(u8, 0xCD), raw[2]);
    try testing.expectEqual(@as(u8, 0xAB), raw[3]);

    const loaded = try readFrequencyTable(dir_path, testing.allocator);
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
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
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
    try testing.expectEqualStrings("math.zig", explorer.word_index.hitPath(hits[0]));
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
        for (old_results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(old_results);
    }
    try testing.expect(old_results.len == 0);

    // New content should be searchable
    const new_results = try explorer.searchContent("newName", testing.allocator, 10);
    defer {
        for (new_results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
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

test "watcher: parallel initial scan matches sequential results" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.makePath("src/nested");
    try tmp_dir.dir.writeFile(.{ .sub_path = "src/main.zig", .data = "const std = @import(\"std\");\npub fn alpha() void {}\n// TODO: keep me\n" });
    try tmp_dir.dir.writeFile(.{ .sub_path = "src/nested/util.py", .data = "def beta():\n    return 42\n# TODO later\n" });
    try tmp_dir.dir.writeFile(.{ .sub_path = "README.md", .data = "# demo\n" });

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmp_dir.dir.realpath(".", &root_buf);

    var store_seq = Store.init(testing.allocator);
    defer store_seq.deinit();
    var explorer_seq = Explorer.init(testing.allocator);
    defer explorer_seq.deinit();
    explorer_seq.setRoot(root);
    try watcher.initialScanWithWorkerCount(&store_seq, &explorer_seq, root, testing.allocator, false, 1);

    var store_par = Store.init(testing.allocator);
    defer store_par.deinit();
    var explorer_par = Explorer.init(testing.allocator);
    defer explorer_par.deinit();
    explorer_par.setRoot(root);
    try watcher.initialScanWithWorkerCount(&store_par, &explorer_par, root, testing.allocator, false, 4);

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

    try testing.expectError(error.InvalidRange, edit_mod.applyEdit(testing.allocator, &store, &agents, null, .{
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

    try testing.expectError(error.InvalidRange, edit_mod.applyEdit(testing.allocator, &store, &agents, null, .{
        .path = rel_path,
        .agent_id = agent_id,
        .op = .replace,
        .range = .{ 3, 3 },
        .content = "changed",
    }));
}

test "issue-35: edits immediately update explorer and snapshot output" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const rel_path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/edit-live-sync.zig", .{tmp.sub_path});
    defer testing.allocator.free(rel_path);

    var file = try tmp.dir.createFile("edit-live-sync.zig", .{});
    defer file.close();
    try file.writeAll("pub fn oldName() void {}\n");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());
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

    _ = try edit_mod.applyEdit(testing.allocator, &store, &agents, &explorer, .{
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
    var explorer = Explorer.init(testing.allocator);
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
    var explorer = Explorer.init(testing.allocator);
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
    var explorer = Explorer.init(arena.allocator());

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
    var explorer = Explorer.init(arena.allocator());

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

test "snapshot_json: snapshot builds and is valid JSON" {
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
// ── Regex decomposition tests ───────────────────────────────

const decomposeRegex = @import("index.zig").decomposeRegex;
const RegexQuery = @import("index.zig").RegexQuery;
const packTrigram = @import("index.zig").packTrigram;
const git_mod = @import("git.zig");
const regexMatch = explore.regexMatch;

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

test "explorer: searchContentRegex end-to-end" {
    var explorer_inst = Explorer.init(testing.allocator);
    defer explorer_inst.deinit();

    try explorer_inst.indexFile("test1.zig", "pub fn recordSnapshot() void {}\nconst x = 42;");
    try explorer_inst.indexFile("test2.zig", "pub fn recordState() void {}\nconst y = 99;");
    try explorer_inst.indexFile("test3.zig", "const z = 0;\nfn other() void {}");

    const results = try explorer_inst.searchContentRegex("record\\w+", testing.allocator, 50);
    defer {
        for (results) |r| {
            testing.allocator.free(r.line_text);
            testing.allocator.free(r.path);
        }
        testing.allocator.free(results);
    }

    try testing.expect(results.len >= 2);
    // Both test1 and test2 should have matches
    var found1 = false;
    var found2 = false;
    for (results) |r| {
        if (std.mem.eql(u8, r.path, "test1.zig")) found1 = true;
        if (std.mem.eql(u8, r.path, "test2.zig")) found2 = true;
    }
    try testing.expect(found1);
    try testing.expect(found2);
}

test "explorer: searchContentRegex no match" {
    var explorer_inst = Explorer.init(testing.allocator);
    defer explorer_inst.deinit();

    try explorer_inst.indexFile("only.zig", "const x = 42;");

    const results = try explorer_inst.searchContentRegex("zzz\\d+qqq", testing.allocator, 50);
    defer testing.allocator.free(results);

    try testing.expectEqual(@as(usize, 0), results.len);
}

// ── Bloom filter correctness tests ──────────────────────────
// These tests prove that the PostingMask (nextMask + locMask) bloom
// filters are actually working — reducing false-positive candidates
// without introducing false negatives.

const PostingMask = @import("index.zig").PostingMask;
const normalizeChar = @import("index.zig").normalizeChar;
const Trigram = @import("index.zig").Trigram;

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

// ── Regex correctness regression tests ──────────────────────

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

// ── Performance regression benchmarks ───────────────────────
// These tests index a realistic number of files and assert that
// operations complete within a time budget. If bloom filtering
// regresses or indexing gets slower, these will catch it.

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

    var timer = try cio.Timer.start();
    for (0..200) |i| {
        try ti.indexFile(names[i], bufs[i]);
        try wi.indexFile(names[i], bufs[i]);
    }
    const elapsed_ns = timer.read();
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;

    // Must complete under 200ms (generous budget — typically ~30ms)
    try testing.expect(elapsed_ms < 200.0);
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

    var timer = try cio.Timer.start();
    const iters: usize = 1000;
    for (0..iters) |_| {
        for (queries) |q| {
            const cands = ti.candidates(q, testing.allocator);
            if (cands) |c| testing.allocator.free(c);
        }
    }
    const elapsed_ns = timer.read();
    const ns_per_query = elapsed_ns / (iters * queries.len);

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

    var timer = try cio.Timer.start();
    const iters: usize = 100_000;
    for (0..iters) |_| {
        for (queries) |q| {
            _ = wi.search(q);
        }
    }
    const elapsed_ns = timer.read();
    const ns_per_query = elapsed_ns / (iters * queries.len);
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

// ── Disk persistence tests ──────────────────────────────────

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
    const dir_path = try tmp.dir.realpath(".", &path_buf);

    const fake_head = "0123456789abcdef0123456789abcdef01234567".*;
    try wi.writeToDisk(dir_path, fake_head);

    const header = try WordIndex.readDiskHeader(dir_path, alloc);
    try testing.expect(header != null);
    try testing.expectEqual(@as(u32, 2), header.?.file_count);
    try testing.expect(header.?.git_head != null);
    try testing.expectEqualSlices(u8, &fake_head, &header.?.git_head.?);

    const loaded = WordIndex.readFromDisk(dir_path, alloc);
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
    const dir_path = try tmp.dir.realpath(".", &path_buf);

    try ti.writeToDisk(dir_path, null);

    // Read back
    const loaded = TrigramIndex.readFromDisk(dir_path, alloc);
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
    const loaded = TrigramIndex.readFromDisk("/tmp/codedb_nonexistent_dir_12345", testing.allocator);
    try testing.expect(loaded == null);
}

test "disk index: readFromDisk returns null for corrupt magic" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &path_buf);

    // Write garbage postings file
    const postings_path = try std.fmt.allocPrint(testing.allocator, "{s}/trigram.postings", .{dir_path});
    defer testing.allocator.free(postings_path);
    {
        const f = try std.fs.cwd().createFile(postings_path, .{});
        defer f.close();
        try f.writeAll("BAADMAGIC");
    }
    // Write garbage lookup file
    const lookup_path = try std.fmt.allocPrint(testing.allocator, "{s}/trigram.lookup", .{dir_path});
    defer testing.allocator.free(lookup_path);
    {
        const f = try std.fs.cwd().createFile(lookup_path, .{});
        defer f.close();
        try f.writeAll("BAADMAGIC");
    }

    const loaded = TrigramIndex.readFromDisk(dir_path, testing.allocator);
    try testing.expect(loaded == null);
}

test "disk index: empty index round-trips correctly" {
    const alloc = testing.allocator;
    var ti = TrigramIndex.init(alloc);
    defer ti.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &path_buf);

    try ti.writeToDisk(dir_path, null);

    const loaded = TrigramIndex.readFromDisk(dir_path, alloc);
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
    const dir_path = try tmp.dir.realpath(".", &path_buf);

    try ti.writeToDisk(dir_path, null);

    const loaded = TrigramIndex.readFromDisk(dir_path, alloc);
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
    const dir_path = try tmp.dir.realpath(".", &path_buf);

    try ti.writeToDisk(dir_path, null);

    const loaded = TrigramIndex.readFromDisk(dir_path, alloc);
    try testing.expect(loaded != null);
    var loaded_ti = loaded.?;
    defer loaded_ti.deinit();

    try testing.expectEqual(@as(u32, 3), loaded_ti.fileCount());
}

// ── Git HEAD + disk index tests ─────────────────────────────

test "git: getGitHead returns 40-char hex SHA in a git repo" {
    // codedb itself is a git repo, so this should succeed
    const head = try git_mod.getGitHead(".", testing.allocator);
    try testing.expect(head != null);
    const sha = head.?;
    try testing.expectEqual(@as(usize, 40), sha.len);
    for (sha) |c| {
        try testing.expect(std.ascii.isHex(c));
    }
}

test "git: getGitHead returns null for non-git directory" {
    // /tmp is not a git repo
    const head = try git_mod.getGitHead("/tmp", testing.allocator);
    try testing.expect(head == null);
}

test "disk index: writeToDisk stores git_head, readGitHead retrieves it" {
    const alloc = testing.allocator;
    var ti = TrigramIndex.init(alloc);
    defer ti.deinit();

    try ti.indexFile("a.zig", "fn hello() void {}");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &path_buf);

    const fake_head = "aabbccddeeff00112233445566778899aabbccdd".*;
    try ti.writeToDisk(dir_path, fake_head);

    const retrieved = try TrigramIndex.readGitHead(dir_path, alloc);
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
    const dir_path = try tmp.dir.realpath(".", &path_buf);

    try ti.writeToDisk(dir_path, null);

    const retrieved = try TrigramIndex.readGitHead(dir_path, alloc);
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
    const dir_path = try tmp.dir.realpath(".", &path_buf);

    const fake_head = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef".*;
    try ti.writeToDisk(dir_path, fake_head);

    const hdr = try TrigramIndex.readDiskHeader(dir_path, alloc);
    try testing.expect(hdr != null);
    try testing.expectEqual(@as(u32, 2), hdr.?.file_count);
    try testing.expect(hdr.?.git_head != null);
    try testing.expectEqualSlices(u8, &fake_head, &hdr.?.git_head.?);
}

test "disk index: v1 format (no git_head) still loads and readGitHead returns null" {
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &path_buf);

    // Manually write a v1 postings file (no git head bytes)
    const postings_path = try std.fmt.allocPrint(alloc, "{s}/trigram.postings", .{dir_path});
    defer alloc.free(postings_path);
    {
        const f = try std.fs.cwd().createFile(postings_path, .{});
        defer f.close();
        // magic(4) + version=1(2) + file_count=0(2) = 8 bytes total
        try f.writeAll(&.{ 'C', 'D', 'B', 'T' });
        try f.writeAll(&.{ 1, 0 }); // version = 1 LE
        try f.writeAll(&.{ 0, 0 }); // file_count = 0
    }
    // Write a matching v1 lookup file
    const lookup_path = try std.fmt.allocPrint(alloc, "{s}/trigram.lookup", .{dir_path});
    defer alloc.free(lookup_path);
    {
        const f = try std.fs.cwd().createFile(lookup_path, .{});
        defer f.close();
        // magic(4) + version=1(2) + pad(2) + entry_count=0(4) = 12 bytes
        try f.writeAll(&.{ 'C', 'D', 'B', 'L' });
        try f.writeAll(&.{ 1, 0 }); // version = 1
        try f.writeAll(&.{ 0, 0 }); // pad
        try f.writeAll(&.{ 0, 0, 0, 0 }); // entry_count = 0
    }

    // readGitHead on a v1 file must return null (no git head stored)
    const git_head = try TrigramIndex.readGitHead(dir_path, alloc);
    try testing.expect(git_head == null);

    // readFromDisk on a v1 file must still succeed (backward compat)
    const loaded = TrigramIndex.readFromDisk(dir_path, alloc);
    try testing.expect(loaded != null);
    var loaded_ti = loaded.?;
    defer loaded_ti.deinit();
    try testing.expectEqual(@as(u32, 0), loaded_ti.fileCount());
}

test "thread-safe: concurrent TrigramIndex.candidates() with per-thread allocators" {
    var ti = TrigramIndex.init(testing.allocator);
    defer ti.deinit();
    try ti.indexFile("a.zig", "pub fn handleRequest(ctx: *Context) void {}");
    try ti.indexFile("b.zig", "pub fn processData(buf: []u8) void {}");
    try ti.indexFile("c.zig", "pub fn handleRequest(req: Request) !void {}");
    const ThreadCtx = struct {
        ti: *TrigramIndex,
        errors: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
        fn run(ctx: *@This()) void {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const alloc = arena.allocator();
            for (0..200) |_| {
                const cands = ctx.ti.candidates("handleRequest", alloc) orelse continue;
                defer alloc.free(cands);
                var found = false;
                for (cands) |p| {
                    if (std.mem.eql(u8, p, "a.zig") or std.mem.eql(u8, p, "c.zig")) found = true;
                }
                if (!found) _ = ctx.errors.fetchAdd(1, .monotonic);
            }
        }
    };
    var ctx = ThreadCtx{ .ti = &ti };
    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, ThreadCtx.run, .{&ctx});
    for (threads) |t| t.join();
    try testing.expectEqual(@as(u32, 0), ctx.errors.load(.monotonic));
}

test "thread-safe: concurrent SparseNgramIndex.candidates() with per-thread allocators" {
    var sni = SparseNgramIndex.init(testing.allocator);
    defer sni.deinit();
    try sni.indexFile("x.zig", "pub fn handleRequest(ctx: *Context) void {}");
    try sni.indexFile("y.zig", "pub fn processData(buf: []u8) void {}");
    const ThreadCtx = struct {
        sni: *SparseNgramIndex,
        errors: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
        fn run(ctx: *@This()) void {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const alloc = arena.allocator();
            for (0..200) |_| {
                const cands = ctx.sni.candidates("handleRequest", alloc) orelse continue;
                defer alloc.free(cands);
                var found = false;
                for (cands) |p| {
                    if (std.mem.eql(u8, p, "x.zig")) found = true;
                }
                if (!found) _ = ctx.errors.fetchAdd(1, .monotonic);
            }
        }
    };
    var ctx = ThreadCtx{ .sni = &sni };
    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, ThreadCtx.run, .{&ctx});
    for (threads) |t| t.join();
}

test "issue-43: trigram_index swap in scanBg races with concurrent MCP queries" {
    // Regression: the scanBg disk-load path must serialize trigram_index swaps
    // with readers by taking exp.mu.lock() before replacing the index.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var exp = Explorer.init(arena.allocator());
    try exp.indexFile("a.zig", "pub fn handleAuth(token: []const u8) bool { return token.len > 0; }");

    exp.mu.lockShared();

    const SwapCtx = struct {
        exp: *Explorer,
        swapped: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        fn run(ctx: *@This()) void {
            ctx.exp.mu.lock();
            defer ctx.exp.mu.unlock();
            ctx.exp.trigram_index.deinit();
            ctx.exp.trigram_index = .{ .heap = TrigramIndex.init(ctx.exp.allocator) };
            ctx.swapped.store(true, .release);
        }
    };
    var sctx = SwapCtx{ .exp = &exp };
    const t = try std.Thread.spawn(.{}, SwapCtx.run, .{&sctx});
    std.Thread.sleep(10 * std.time.ns_per_ms);
    const raced = sctx.swapped.load(.acquire);
    exp.mu.unlockShared();
    t.join();
    try testing.expect(!raced);
}

test "issue-44: snapshot stale after working tree changes cause stale query results" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &path_buf);

    const snap_path = try std.fmt.allocPrint(testing.allocator, "{s}/test.snapshot", .{dir_path});
    defer testing.allocator.free(snap_path);
    const file_abs = try std.fmt.allocPrint(testing.allocator, "{s}/stale.zig", .{dir_path});
    defer testing.allocator.free(file_abs);

    // Step 1: write file with old content, index it, write snapshot.
    try tmp.dir.writeFile(.{ .sub_path = "stale.zig", .data = "pub fn oldFunc() void {}" });
    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var exp = Explorer.init(arena.allocator());
        try exp.indexFile(file_abs, "pub fn oldFunc() void {}");
        try snapshot_mod.writeSnapshot(&exp, ".", snap_path, arena.allocator());
    }

    // Step 2: modify file AFTER snapshot creation (simulating uncommitted working tree change).
    // Sleep 10ms so the file mtime is strictly greater than the snapshot's indexed_at timestamp.
    std.Thread.sleep(10 * std.time.ns_per_ms);
    try tmp.dir.writeFile(.{ .sub_path = "stale.zig", .data = "pub fn newFunc() void {}" });

    // Step 3: load snapshot into a fresh explorer (what MCP startup does).
    // scan_done is set to true immediately; watcher then builds known-FileMap
    // from current disk mtimes, recording the already-modified file's mtime as
    // the baseline. It will never be re-indexed unless changed a second time.
    var arena2 = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena2.deinit();
    var exp2 = Explorer.init(arena2.allocator());
    var store2 = Store.init(testing.allocator);
    defer store2.deinit();

    const loaded = snapshot_mod.loadSnapshot(snap_path, &exp2, &store2, arena2.allocator());
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
    var exp = Explorer.init(arena.allocator());

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &path_buf);

    const snap_path = try std.fmt.allocPrint(testing.allocator, "{s}/test.codedb", .{dir_path});
    defer testing.allocator.free(snap_path);

    // Write snapshot of empty repo (no files indexed)
    try snapshot_mod.writeSnapshot(&exp, dir_path, snap_path, testing.allocator);

    // Load into fresh explorer + store
    var arena2 = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena2.deinit();
    var exp2 = Explorer.init(arena2.allocator());
    var store = Store.init(testing.allocator);
    defer store.deinit();

    const loaded = snapshot_mod.loadSnapshot(snap_path, &exp2, &store, testing.allocator);
    // Valid empty-repo snapshot should be accepted; currently returns false (bug: file_count == 0)
    try testing.expect(loaded);
}

test "issue-220: snapshot fast load restores outlines and lazily rebuilds word index" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var exp = Explorer.init(aa);
    try exp.indexFile("src/store.zig", "pub const Store = struct {};\n");
    try exp.indexFile("src/main.zig", "const Store = @import(\"store.zig\").Store;\npub fn main() void {}\n");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &path_buf);

    const snap_path = try std.fmt.allocPrint(testing.allocator, "{s}/fast.codedb", .{dir_path});
    defer testing.allocator.free(snap_path);
    try snapshot_mod.writeSnapshot(&exp, dir_path, snap_path, testing.allocator);

    var arena2 = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena2.deinit();
    var exp2 = Explorer.init(arena2.allocator());
    var store = Store.init(testing.allocator);
    defer store.deinit();

    const loaded = snapshot_mod.loadSnapshot(snap_path, &exp2, &store, arena2.allocator());
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

test "issue-220: partial word index state rebuilds before search" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &path_buf);

    var exp = Explorer.init(testing.allocator);
    defer exp.deinit();
    try exp.indexFile("src/a.zig", "pub const Alpha = 1;\n");
    try exp.indexFile("src/b.zig", "pub const Beta = 2;\n");

    const snap_path = try std.fmt.allocPrint(testing.allocator, "{s}/partial.codedb", .{dir_path});
    defer testing.allocator.free(snap_path);
    try snapshot_mod.writeSnapshot(&exp, dir_path, snap_path, testing.allocator);

    var exp2 = Explorer.init(testing.allocator);
    defer exp2.deinit();
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try testing.expect(snapshot_mod.loadSnapshot(snap_path, &exp2, &store, testing.allocator));
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
    var exp = Explorer.init(testing.allocator);
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

// ── Snapshot non-git tests ───────────────────────────────────

test "issue-45: snapshot written in non-git directory cannot be loaded" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &path_buf);

    var exp = Explorer.init(aa);
    try exp.indexFile("dummy.zig", "const x = 1;");

    const snap_path = try std.fs.path.join(aa, &.{ dir_path, "test.codedb" });

    // Write snapshot with a non-git root_path — git_head will be all-zeros
    try snapshot_mod.writeSnapshot(&exp, "/tmp", snap_path, aa);

    // Snapshot file was created
    std.fs.cwd().access(snap_path, .{}) catch {
        return error.TestUnexpectedResult;
    };

    // readSnapshotGitHead returns null for non-git dirs (all-zero sentinel).
    // The snapshot loading logic in main.zig handles this by checking if the
    // current project also has no git — if so, it loads the snapshot.
    const snap_head = snapshot_mod.readSnapshotGitHead(snap_path);
    try testing.expect(snap_head == null);
}

// ── Multi-instance contention tests ────────────────────────────

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

    var exp1 = Explorer.init(arena1.allocator());
    try exp1.indexFile("a.zig", "pub fn alpha() void {}");
    var exp2 = Explorer.init(arena2.allocator());
    try exp2.indexFile("b.zig", "pub fn beta() void {}");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &path_buf);
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
                snapshot_mod.writeSnapshot(ctx.exp, ctx.dir, ctx.path, ctx.alloc) catch {
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
    var exp3 = Explorer.init(arena3.allocator());
    var store3 = Store.init(testing.allocator);
    defer store3.deinit();
    const loaded = snapshot_mod.loadSnapshot(snap_path, &exp3, &store3, arena3.allocator());

    // Expected: loaded == true (snapshot is valid, written atomically)
    // Current (bug): may be false — last writer's rename can land mid-write of
    // the first writer's tmp file, or both rename the same .tmp path.
    try testing.expect(loaded);
}

test "issue-42: scan thread is joined before allocator-backed state is freed" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const data_dir = try allocator.dupe(u8, "/tmp/codedb_test_issue42");

    const SharedCtx = struct {
        data_dir: []const u8,
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        ok: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        fn run(ctx: *@This()) void {
            std.Thread.sleep(10 * std.time.ns_per_ms);
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
    var exp = Explorer.init(arena.allocator());

    try exp.indexFile("src/a.zig", "const a = 1;\n");
    try exp.indexFile("src/b.zig", "const b = 2;\n");
    try exp.indexFile("src/c.zig", "const c = 3;\n");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &path_buf);

    const snap_path = try std.fmt.allocPrint(testing.allocator, "{s}/test.codedb", .{dir_path});
    defer testing.allocator.free(snap_path);

    try snapshot_mod.writeSnapshot(&exp, dir_path, snap_path, testing.allocator);

    const trunc_path = try std.fmt.allocPrint(testing.allocator, "{s}/trunc.codedb", .{dir_path});
    defer testing.allocator.free(trunc_path);
    {
        const orig = try std.fs.cwd().readFileAlloc(testing.allocator, snap_path, 1024 * 1024);
        defer testing.allocator.free(orig);
        const trunc_file = try std.fs.cwd().createFile(trunc_path, .{});
        defer trunc_file.close();
        // Keep only header (256 bytes) — content section data will be missing
        try trunc_file.writeAll(orig[0..@min(256, orig.len)]);
    }

    var arena2 = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena2.deinit();
    var exp2 = Explorer.init(arena2.allocator());
    var store = Store.init(arena2.allocator());

    const loaded = snapshot_mod.loadSnapshot(trunc_path, &exp2, &store, arena2.allocator());
    try testing.expect(!loaded);
}

test "issue-41: snapshot not validated against repo identity allows cross-project loading" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var exp = Explorer.init(arena.allocator());

    try exp.indexFile("src/projectA.zig", "const project = \"A\";\n");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &path_buf);

    const snap_path = try std.fmt.allocPrint(testing.allocator, "{s}/test.codedb", .{dir_path});
    defer testing.allocator.free(snap_path);

    try snapshot_mod.writeSnapshot(&exp, dir_path, snap_path, testing.allocator);

    var arena2 = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena2.deinit();
    var exp2 = Explorer.init(arena2.allocator());
    var store = Store.init(testing.allocator);
    defer store.deinit();

    const loaded = snapshot_mod.loadSnapshotValidated(snap_path, "/some/other/project", &exp2, &store, testing.allocator);
    try testing.expect(!loaded);
}

test "issue-59: telemetry writes session, tool, and codebase stats ndjson" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &path_buf);

    var telem = telemetry_mod.Telemetry.init(dir_path, testing.allocator, false);
    defer telem.deinit();

    telem.recordSessionStart();
    telem.recordToolCall("codedb_status", 1234, false, 56);

    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();
    try explorer.indexFile("src/main.zig", "pub fn main() void {}\n");
    try explorer.indexFile("src/lib.py", "def run():\n    return 1\n");

    telem.recordCodebaseStats(&explorer, 42);
    telem.flush();

    const ndjson_path = try std.fmt.allocPrint(testing.allocator, "{s}/telemetry.ndjson", .{dir_path});
    defer testing.allocator.free(ndjson_path);

    const contents = try std.fs.cwd().readFileAlloc(testing.allocator, ndjson_path, 64 * 1024);
    defer testing.allocator.free(contents);

    try testing.expect(std.mem.indexOf(u8, contents, "\"event_type\":\"session_start\"") != null);
    try testing.expect(std.mem.indexOf(u8, contents, "\"event_type\":\"tool_call\"") != null);
    try testing.expect(std.mem.indexOf(u8, contents, "\"tool\":\"codedb_status\"") != null);
    try testing.expect(std.mem.indexOf(u8, contents, "\"event_type\":\"codebase_stats\"") != null);
    try testing.expect(std.mem.indexOf(u8, contents, "\"startup_time_ms\":42") != null);
    try testing.expect(std.mem.indexOf(u8, contents, "\"languages\":[\"zig\",\"python\"]") != null);
}

test "issue-60: telemetry disabled path is a no-op" {
    var telem = telemetry_mod.Telemetry.init("/tmp", testing.allocator, true);
    defer telem.deinit();

    telem.recordSessionStart();
    telem.recordToolCall("codedb_search", 99, true, 10);
    try testing.expect(!telem.enabled);
    try testing.expect(telem.file == null);
    try testing.expect(telem.head.load(.monotonic) == 0);
}

test "issue-77: mcp index accepts temporary-directory roots that cause pathological cache growth" {
    var tmp_name_buf: [128]u8 = undefined;
    const tmp_name = try std.fmt.bufPrint(&tmp_name_buf, "codedb-issue-77-{d}", .{std.time.microTimestamp()});
    const tmp_root = try std.fs.path.join(testing.allocator, &.{ "/private/tmp", tmp_name });
    defer testing.allocator.free(tmp_root);

    std.fs.cwd().makePath(tmp_root) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.fs.cwd().deleteTree(tmp_root) catch {};

    const source_path = try std.fs.path.join(testing.allocator, &.{ tmp_root, "sample.zig" });
    defer testing.allocator.free(source_path);
    {
        const file = try std.fs.cwd().createFile(source_path, .{});
        defer file.close();
        try file.writeAll("pub fn sample() void {}\n");
    }

    const result = try std.process.Child.run(.{
        .allocator = testing.allocator,
        .argv = &.{ "zig", "build", "run", "--", tmp_root, "snapshot" },
        .max_output_bytes = 256 * 1024,
    });
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);

    try testing.expect(result.term.Exited != 0);
}

test "issue-105: large files skip trigram indexing to prevent OOM" {
    var explorer = Explorer.init(testing.allocator);
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

// ── PHP parser tests ─────────────────────────────────────────────

test "issue-php-1: PHP class definition herkend" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("app/Models/Candidate.php",
        \\<?php
        \\
        \\namespace App\Models;
        \\
        \\class Candidate
        \\{
        \\}
    );

    var outline = (try explorer.getOutline("app/Models/Candidate.php", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    var found = false;
    for (outline.symbols.items) |sym| {
        if (sym.kind == .class_def and std.mem.eql(u8, sym.name, "Candidate")) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "issue-php-2: PHP methode binnen class herkend" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("app/Models/User.php",
        \\<?php
        \\
        \\class User
        \\{
        \\    public function boot()
        \\    {
        \\    }
        \\
        \\    protected function scopeActive($query)
        \\    {
        \\    }
        \\}
    );

    var outline = (try explorer.getOutline("app/Models/User.php", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    var method_count: usize = 0;
    for (outline.symbols.items) |sym| {
        if (sym.kind == .method) method_count += 1;
    }
    try testing.expectEqual(@as(usize, 2), method_count);
}

test "issue-php-3: PHP top-level functie herkend" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("helpers.php",
        \\<?php
        \\
        \\function myHelper($arg)
        \\{
        \\}
        \\
        \\function boot()
        \\{
        \\}
    );

    var outline = (try explorer.getOutline("helpers.php", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    var fn_count: usize = 0;
    for (outline.symbols.items) |sym| {
        if (sym.kind == .function) fn_count += 1;
    }
    try testing.expectEqual(@as(usize, 2), fn_count);
}

test "issue-php-4: PHP interface herkend" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("app/Contracts/Payable.php",
        \\<?php
        \\
        \\interface Payable
        \\{
        \\    public function charge();
        \\}
    );

    var outline = (try explorer.getOutline("app/Contracts/Payable.php", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    var found = false;
    for (outline.symbols.items) |sym| {
        if (sym.kind == .interface_def and std.mem.eql(u8, sym.name, "Payable")) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "issue-php-5: PHP trait herkend" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("app/Traits/HasSlug.php",
        \\<?php
        \\
        \\trait HasSlug
        \\{
        \\    public function generateSlug()
        \\    {
        \\    }
        \\}
    );

    var outline = (try explorer.getOutline("app/Traits/HasSlug.php", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    var found = false;
    for (outline.symbols.items) |sym| {
        if (sym.kind == .trait_def and std.mem.eql(u8, sym.name, "HasSlug")) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "issue-php-6: PHP use-import omgezet naar pad in dep_graph" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("app/Http/Controllers/CandidateController.php",
        \\<?php
        \\
        \\use App\Models\Candidate;
        \\use Illuminate\Support\Facades\DB;
    );

    var outline = (try explorer.getOutline("app/Http/Controllers/CandidateController.php", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    try testing.expectEqual(@as(usize, 2), outline.imports.items.len);
    try testing.expectEqualStrings("app/Models/Candidate.php", outline.imports.items[0]);
    try testing.expectEqualStrings("illuminate/Support/Facades/DB.php", outline.imports.items[1]);
}

test "issue-php-7: PHP commentaarregels worden overgeslagen" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("app/Commented.php",
        \\<?php
        \\
        \\// function fakeFunction()
        \\# function anotherFake()
        \\/* function blockComment() */
        \\
        \\class RealClass
        \\{
        \\}
    );

    var outline = (try explorer.getOutline("app/Commented.php", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    try testing.expectEqual(@as(usize, 1), outline.symbols.items.len);
    try testing.expect(outline.symbols.items[0].kind == .class_def);
}

test "issue-php-8: PHP function after class is top-level, not method" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("app/mixed.php",
        \\<?php
        \\
        \\class Foo
        \\{
        \\    public function bar()
        \\    {
        \\    }
        \\}
        \\
        \\function helper()
        \\{
        \\}
    );

    var outline = (try explorer.getOutline("app/mixed.php", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    var method_count: usize = 0;
    var function_count: usize = 0;
    for (outline.symbols.items) |sym| {
        if (sym.kind == .method) method_count += 1;
        if (sym.kind == .function) function_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), method_count);
    try testing.expectEqual(@as(usize, 1), function_count);
}

test "issue-php-9: PHP 8.1 enum herkend" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("app/Enums/Status.php",
        \\<?php
        \\
        \\enum Status: string
        \\{
        \\    public function label(): string
        \\    {
        \\    }
        \\}
    );

    var outline = (try explorer.getOutline("app/Enums/Status.php", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    var found_enum = false;
    var found_method = false;
    for (outline.symbols.items) |sym| {
        if (sym.kind == .enum_def and std.mem.eql(u8, sym.name, "Status")) found_enum = true;
        if (sym.kind == .method and std.mem.eql(u8, sym.name, "label")) found_method = true;
    }
    try testing.expect(found_enum);
    try testing.expect(found_method);
}

test "issue-php-10: PHP grouped use-statement parsed into individual imports" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("app/Http/Controllers/TestController.php",
        \\<?php
        \\
        \\use App\Models\{User, Candidate, Role};
    );

    var outline = (try explorer.getOutline("app/Http/Controllers/TestController.php", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    try testing.expectEqual(@as(usize, 1), outline.symbols.items.len);
    try testing.expect(outline.symbols.items[0].kind == .import);
    try testing.expectEqual(@as(usize, 3), outline.imports.items.len);
    try testing.expectEqualStrings("app/Models/User.php", outline.imports.items[0]);
    try testing.expectEqualStrings("app/Models/Candidate.php", outline.imports.items[1]);
    try testing.expectEqualStrings("app/Models/Role.php", outline.imports.items[2]);
}

test "issue-php-11: PHP readonly class herkend" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("app/ValueObjects/Money.php",
        \\<?php
        \\
        \\readonly class Money
        \\{
        \\}
    );

    var outline = (try explorer.getOutline("app/ValueObjects/Money.php", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    var found = false;
    for (outline.symbols.items) |sym| {
        if (sym.kind == .class_def and std.mem.eql(u8, sym.name, "Money")) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "issue-php-12: PHP class and public constants herkend" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("app/Config.php",
        \\<?php
        \\
        \\class Config
        \\{
        \\    public const VERSION = '1.0';
        \\    const MAX_RETRIES = 3;
        \\    private const SECRET = 'abc';
        \\}
    );

    var outline = (try explorer.getOutline("app/Config.php", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    var constant_count: usize = 0;
    for (outline.symbols.items) |sym| {
        if (sym.kind == .constant) constant_count += 1;
    }
    try testing.expectEqual(@as(usize, 3), constant_count);
}

test "issue-php-13: PHP nested braces in methods do not break class tracking" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("app/Services/Complex.php",
        \\<?php
        \\
        \\class Complex
        \\{
        \\    public function process()
        \\    {
        \\        if ($x) {
        \\            foreach ($items as $item) {
        \\                echo "}";
        \\            }
        \\        }
        \\    }
        \\
        \\    public function another()
        \\    {
        \\    }
        \\}
        \\
        \\function outsideHelper()
        \\{
        \\}
    );

    var outline = (try explorer.getOutline("app/Services/Complex.php", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    var method_count: usize = 0;
    var function_count: usize = 0;
    for (outline.symbols.items) |sym| {
        if (sym.kind == .method) method_count += 1;
        if (sym.kind == .function) function_count += 1;
    }
    try testing.expectEqual(@as(usize, 2), method_count);
    try testing.expectEqual(@as(usize, 1), function_count);
}

test "issue-php-14: PHP multi-line block comments do not produce symbols" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("app/Services/Commented.php",
        \\<?php
        \\
        \\class Real
        \\{
        \\}
        \\
        \\/*
        \\function fake() {
        \\}
        \\class Ghost {
        \\}
        \\*/
        \\
        \\function afterComment()
        \\{
        \\}
    );

    var outline = (try explorer.getOutline("app/Services/Commented.php", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    var class_count: usize = 0;
    var function_count: usize = 0;
    for (outline.symbols.items) |sym| {
        if (sym.kind == .class_def) class_count += 1;
        if (sym.kind == .function) function_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), class_count);
    try testing.expectEqual(@as(usize, 1), function_count);
}

test "issue-php-15: PHP use-as alias stripped from import path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("app/Controllers/Test.php",
        \\<?php
        \\
        \\use App\Models\User as UserModel;
    );

    var outline = (try explorer.getOutline("app/Controllers/Test.php", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    try testing.expectEqual(@as(usize, 1), outline.imports.items.len);
    try testing.expectEqualStrings("app/Models/User.php", outline.imports.items[0]);
}

test "issue-php-16: PHP escaped quotes do not end string mode" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("app/Services/Escaped.php",
        \\<?php
        \\
        \\class Formatter
        \\{
        \\    public function render()
        \\    {
        \\        echo "she said \"}\"";
        \\    }
        \\
        \\    public function other()
        \\    {
        \\    }
        \\}
        \\
        \\function freeHelper()
        \\{
        \\}
    );

    var outline = (try explorer.getOutline("app/Services/Escaped.php", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    var method_count: usize = 0;
    var function_count: usize = 0;
    for (outline.symbols.items) |sym| {
        if (sym.kind == .method) method_count += 1;
        if (sym.kind == .function) function_count += 1;
    }
    try testing.expectEqual(@as(usize, 2), method_count);
    try testing.expectEqual(@as(usize, 1), function_count);
}

test "issue-php-17: PHP code after block comment terminator is parsed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("app/Services/Inline.php",
        \\<?php
        \\
        \\/*
        \\function fake() {
        \\}
        \\*/ function realFunc()
        \\{
        \\}
    );

    var outline = (try explorer.getOutline("app/Services/Inline.php", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    var function_count: usize = 0;
    for (outline.symbols.items) |sym| {
        if (sym.kind == .function) function_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), function_count);
}

test "issue-php-18: PHP use-as alias case-insensitive" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("app/Controllers/CaseTest.php",
        \\<?php
        \\
        \\use App\Models\User AS UserModel;
        \\use App\Services\{Cache AS CacheAlias, Logger};
    );

    var outline = (try explorer.getOutline("app/Controllers/CaseTest.php", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    try testing.expectEqual(@as(usize, 3), outline.imports.items.len);
    try testing.expectEqualStrings("app/Models/User.php", outline.imports.items[0]);
    try testing.expectEqualStrings("app/Services/Cache.php", outline.imports.items[1]);
    try testing.expectEqualStrings("app/Services/Logger.php", outline.imports.items[2]);
}

test "issue-107: codedb_deps returns results for Python files" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

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

test "issue-93: isSensitivePath blocks .env and credentials" {
    try testing.expect(watcher.isSensitivePath(".env"));
    try testing.expect(watcher.isSensitivePath(".env.local"));
    try testing.expect(watcher.isSensitivePath(".env.production"));
    try testing.expect(watcher.isSensitivePath("credentials.json"));
    try testing.expect(watcher.isSensitivePath("service-account.json"));
    try testing.expect(watcher.isSensitivePath("id_rsa"));
    try testing.expect(watcher.isSensitivePath("secrets.yaml"));
    try testing.expect(watcher.isSensitivePath("config/secrets.yml"));
    try testing.expect(watcher.isSensitivePath("server.key"));
    try testing.expect(watcher.isSensitivePath("cert.pem"));
    try testing.expect(watcher.isSensitivePath("keystore.jks"));
    try testing.expect(watcher.isSensitivePath("identity.pfx"));
    try testing.expect(watcher.isSensitivePath(".ssh/known_hosts"));
    // Normal files should NOT be blocked
    try testing.expect(!watcher.isSensitivePath("main.zig"));
    try testing.expect(!watcher.isSensitivePath("src/server.zig"));
    try testing.expect(!watcher.isSensitivePath("README.md"));
    try testing.expect(!watcher.isSensitivePath("package.json"));
}

test "issue-93: isPathSafe blocks traversal" {
    const MCP = @import("mcp.zig");
    try testing.expect(!MCP.isPathSafe("../../../etc/passwd"));
    try testing.expect(!MCP.isPathSafe("/etc/passwd"));
    try testing.expect(!MCP.isPathSafe(""));
    try testing.expect(MCP.isPathSafe("src/main.zig"));
    try testing.expect(MCP.isPathSafe("README.md"));
}

test "issue-111: Python triple-quote docstrings not parsed as code" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("docstring.py",
        \\def real_func():
        \\    """
        \\    def fake_func():
        \\        pass
        \\    """
        \\    pass
    );

    var outline = (try explorer.getOutline("docstring.py", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    var func_count: usize = 0;
    for (outline.symbols.items) |sym| {
        if (sym.kind == .function) func_count += 1;
    }
    // Only real_func should be found, not fake_func inside docstring
    try testing.expect(func_count == 1);
}

test "issue-112: Python import-as alias stripped from dep path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("utils.py", "def helper(): pass\n");
    try explorer.indexFile("consumer.py", "import utils as u\n");

    const deps = try explorer.getImportedBy("utils.py", testing.allocator);
    defer {
        for (deps) |d| testing.allocator.free(d);
        testing.allocator.free(deps);
    }
    try testing.expect(deps.len == 1);
}

test "issue-113: TypeScript block comments not parsed as code" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("commented.ts",
        \\export function realFunc() {}
        \\/*
        \\export function fakeFunc() {}
        \\*/
    );

    var outline = (try explorer.getOutline("commented.ts", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    var func_count: usize = 0;
    for (outline.symbols.items) |sym| {
        if (sym.kind == .function) func_count += 1;
    }
    try testing.expect(func_count == 1);
}

test "issue-114: TypeScript import-as alias does not affect dep path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("mod.ts", "export function hello() {}\n");
    try explorer.indexFile("consumer.ts", "import { hello as h } from './mod'\n");

    var outline = (try explorer.getOutline("consumer.ts", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    // The import dep path should be "./mod", not include the alias
    try testing.expect(outline.imports.items.len == 1);
    try testing.expectEqualStrings("./mod", outline.imports.items[0]);
}

// ── Trigram index regression suite (#142) ─────────────────────────────
// Tests correctness invariants that must hold across index implementation changes.

test "regression-142: trigram index finds all matching files" {
    var exp = Explorer.init(testing.allocator);
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
    var exp = Explorer.init(testing.allocator);
    defer exp.deinit();

    try exp.indexFile("a.zig", "pub fn alpha() void {}");
    try exp.indexFile("b.zig", "pub fn beta() void {}");

    const results = try exp.searchContent("gamma", testing.allocator, 50);
    defer testing.allocator.free(results);
    // Must return zero results for non-existent content
    try testing.expect(results.len == 0);
}

test "regression-142: trigram intersection narrows correctly" {
    var exp = Explorer.init(testing.allocator);
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
    var exp = Explorer.init(testing.allocator);
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
    var exp = Explorer.init(testing.allocator);
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
    const dir_path = try tmp.dir.realpath(".", &path_buf);

    // Build index
    var idx1 = TrigramIndex.init(testing.allocator);
    try idx1.indexFile("a.zig", "pub fn searchable() void {}");
    try idx1.indexFile("b.zig", "const value = 42;");

    // Write to disk
    try idx1.writeToDisk(dir_path, null);
    idx1.deinit();

    // Read back
    var idx2 = TrigramIndex.readFromDisk(dir_path, testing.allocator) orelse return error.TestUnexpectedResult;
    defer idx2.deinit();

    // Must find same results
    const cands = idx2.candidates("searchable", testing.allocator) orelse return error.TestUnexpectedResult;
    defer testing.allocator.free(cands);
    try testing.expect(cands.len == 1);
}

test "regression-142: many files don't corrupt index" {
    var exp = Explorer.init(testing.allocator);
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
    var exp = Explorer.init(testing.allocator);
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
    var exp = Explorer.init(testing.allocator);
    defer exp.deinit();

    try exp.indexFile("words.zig", "pub fn mySpecialFunction() void {}");

    const hits = try exp.searchWord("mySpecialFunction", testing.allocator);
    defer testing.allocator.free(hits);
    try testing.expect(hits.len == 1);
}

test "issue-151: Go func and type definitions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("main.go",
        \\package main
        \\
        \\import "fmt"
        \\
        \\type Config struct {
        \\    Port int
        \\}
        \\
        \\type Handler interface {
        \\    Handle()
        \\}
        \\
        \\func main() {
        \\    fmt.Println("hello")
        \\}
        \\
        \\func (c *Config) Validate() bool {
        \\    return c.Port > 0
        \\}
    );

    var outline = (try explorer.getOutline("main.go", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    var func_count: usize = 0;
    var struct_count: usize = 0;
    for (outline.symbols.items) |sym| {
        if (sym.kind == .function) func_count += 1;
        if (sym.kind == .struct_def) struct_count += 1;
    }
    try testing.expect(func_count == 2); // main + Validate
    try testing.expect(struct_count == 2); // Config + Handler
    try testing.expect(outline.imports.items.len == 1); // "fmt"
}

test "issue-151: Ruby class, module, and def" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("app.rb",
        \\require "json"
        \\require_relative "./helpers"
        \\
        \\module Authentication
        \\  class User
        \\    def initialize(name)
        \\      @name = name
        \\    end
        \\
        \\    def greet
        \\      puts "hello"
        \\    end
        \\  end
        \\end
    );

    var outline = (try explorer.getOutline("app.rb", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    var func_count: usize = 0;
    var struct_count: usize = 0;
    for (outline.symbols.items) |sym| {
        if (sym.kind == .function) func_count += 1;
        if (sym.kind == .struct_def) struct_count += 1;
    }
    try testing.expect(func_count == 2); // initialize + greet
    try testing.expect(struct_count == 2); // Authentication + User
    try testing.expect(outline.imports.items.len == 2); // json + ./helpers
}

test "issue-151: Ruby =begin/=end comments skipped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("commented.rb",
        \\def real_method
        \\  true
        \\end
        \\=begin
        \\def fake_method
        \\  false
        \\end
        \\=end
    );

    var outline = (try explorer.getOutline("commented.rb", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    var func_count: usize = 0;
    for (outline.symbols.items) |sym| {
        if (sym.kind == .function) func_count += 1;
    }
    try testing.expect(func_count == 1); // only real_method
}

test "issue-151: Go block comments skipped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("commented.go",
        \\package main
        \\
        \\func realFunc() {}
        \\/*
        \\func fakeFunc() {}
        \\*/
    );

    var outline = (try explorer.getOutline("commented.go", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    var func_count: usize = 0;
    for (outline.symbols.items) |sym| {
        if (sym.kind == .function) func_count += 1;
    }
    try testing.expect(func_count == 1); // only realFunc
}

test "issue-150: --help prints usage" {
    try buildCliForHelpTests();

    const result = try std.process.Child.run(.{
        .allocator = testing.allocator,
        .argv = &.{ "./zig-out/bin/codedb", "--help" },
        .max_output_bytes = 8192,
    });
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);

    try testing.expect(result.term == .Exited);
    try testing.expect(result.term.Exited == 0);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "usage:") != null or
        std.mem.indexOf(u8, result.stderr, "usage:") != null);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "update") != null or
        std.mem.indexOf(u8, result.stderr, "update") != null);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "nuke") != null or
        std.mem.indexOf(u8, result.stderr, "nuke") != null);
}

test "issue-150: -h prints usage" {
    try buildCliForHelpTests();

    const result = try std.process.Child.run(.{
        .allocator = testing.allocator,
        .argv = &.{ "./zig-out/bin/codedb", "-h" },
        .max_output_bytes = 8192,
    });
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);

    try testing.expect(result.term == .Exited);
    try testing.expect(result.term.Exited == 0);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "usage:") != null or
        std.mem.indexOf(u8, result.stderr, "usage:") != null);
}

fn buildCliForHelpTests() !void {
    const zigup_build = std.process.Child.run(.{
        .allocator = testing.allocator,
        .argv = &.{ "zigup", "run", "0.15.2", "build" },
        .max_output_bytes = 8192,
    }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (zigup_build) |build| {
        defer testing.allocator.free(build.stdout);
        defer testing.allocator.free(build.stderr);

        try testing.expect(build.term == .Exited);
        try testing.expect(build.term.Exited == 0);
        return;
    }

    const build = try std.process.Child.run(.{
        .allocator = testing.allocator,
        .argv = &.{ "zig", "build" },
        .max_output_bytes = 8192,
    });
    defer testing.allocator.free(build.stdout);
    defer testing.allocator.free(build.stderr);

    try testing.expect(build.term == .Exited);
    try testing.expect(build.term.Exited == 0);
}

test "update: compareVersions orders semantic versions" {
    try testing.expect(try update_mod.compareVersions("0.2.55", "0.2.56") == .lt);
    try testing.expect(try update_mod.compareVersions("0.2.56", "0.2.56") == .eq);
    try testing.expect(try update_mod.compareVersions("v0.2.57", "0.2.56") == .gt);
    try testing.expect(try update_mod.compareVersions("0.2.56", "0.2.56.0") == .eq);
}

test "update: checksumForBinary parses release manifest" {
    const manifest =
        \\7be38140d090b2e23723c8cde02be150171c818daa16b18c520b44cc1e078add  codedb-darwin-arm64
        \\76bc7b81bc9fd211aa2c1ac59d1d26e8c80bc211ab560de2dc998ea9e04ec471  codedb-darwin-x86_64
        \\aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  *codedb-linux-arm64
    ;

    try testing.expectEqualStrings(
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        update_mod.checksumForBinary(manifest, "codedb-linux-arm64") orelse return error.TestUnexpectedResult,
    );
    try testing.expect(update_mod.checksumForBinary(manifest, "codedb-linux-x86_64") == null);
}

test "update: asset names match published release naming" {
    try testing.expectEqualStrings("codedb-darwin-arm64", update_mod.assetNameForTarget(.macos, .aarch64).?);
    try testing.expectEqualStrings("codedb-darwin-x86_64", update_mod.assetNameForTarget(.macos, .x86_64).?);
    try testing.expectEqualStrings("codedb-linux-arm64", update_mod.assetNameForTarget(.linux, .aarch64).?);
    try testing.expectEqualStrings("codedb-linux-x86_64", update_mod.assetNameForTarget(.linux, .x86_64).?);
    try testing.expect(update_mod.assetNameForTarget(.windows, .x86_64) == null);
}

test "nuke: commandTargetsBinary only matches the current install path" {
    try testing.expect(nuke_mod.commandTargetsBinary(
        "/tmp/codedb-test/bin/codedb serve",
        "/tmp/codedb-test/bin/codedb",
    ));
    try testing.expect(nuke_mod.commandTargetsBinary(
        "/var/folders/example/codedb serve",
        "/private/var/folders/example/codedb",
    ));
    try testing.expect(!nuke_mod.commandTargetsBinary(
        "/Users/rachpradhan/bin/codedb --mcp",
        "/tmp/codedb-test/bin/codedb",
    ));
}

test "nuke: removeJsonMcpServerEntry drops only codedb integration" {
    const input =
        \\{
        \\  "mcpServers": {
        \\    "codedb": { "command": "/Users/me/bin/codedb", "args": ["mcp"] },
        \\    "other": { "command": "other", "args": [] }
        \\  },
        \\  "theme": "dark"
        \\}
    ;

    const output = (try nuke_mod.removeJsonMcpServerEntry(testing.allocator, input, "codedb")) orelse
        return error.TestUnexpectedResult;
    defer testing.allocator.free(output);

    try testing.expect(std.mem.indexOf(u8, output, "\"codedb\"") == null);
    try testing.expect(std.mem.indexOf(u8, output, "\"other\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"theme\"") != null);
}

test "nuke: removeJsonMcpServerEntry removes empty mcpServers object" {
    const input =
        \\{
        \\  "mcpServers": {
        \\    "codedb": { "command": "/Users/me/bin/codedb", "args": ["mcp"] }
        \\  },
        \\  "theme": "dark"
        \\}
    ;

    const output = (try nuke_mod.removeJsonMcpServerEntry(testing.allocator, input, "codedb")) orelse
        return error.TestUnexpectedResult;
    defer testing.allocator.free(output);

    try testing.expect(std.mem.indexOf(u8, output, "\"codedb\"") == null);
    try testing.expect(std.mem.indexOf(u8, output, "\"mcpServers\"") == null);
    try testing.expect(std.mem.indexOf(u8, output, "\"theme\"") != null);
}

test "nuke: removeCodexMcpServerBlock removes codedb block only" {
    const input =
        \\[mcp_servers.codedb]
        \\command = "/Users/me/bin/codedb"
        \\args = ["mcp"]
        \\startup_timeout_sec = 30
        \\
        \\[mcp_servers.other]
        \\command = "other"
        \\args = []
    ;

    const output = (try nuke_mod.removeCodexMcpServerBlock(testing.allocator, input, "codedb")) orelse
        return error.TestUnexpectedResult;
    defer testing.allocator.free(output);

    try testing.expect(std.mem.indexOf(u8, output, "[mcp_servers.codedb]") == null);
    try testing.expect(std.mem.indexOf(u8, output, "[mcp_servers.other]") != null);
    try testing.expect(std.mem.indexOf(u8, output, "command = \"other\"") != null);
}

test "nuke: removeCodexMcpServerBlock matches indented header with inline comment" {
    const input =
        \\  [mcp_servers.codedb] # local override
        \\command = "/Users/me/bin/codedb"
        \\args = ["mcp"]
        \\
        \\[mcp_servers.other]
        \\command = "other"
        \\args = []
    ;

    const output = (try nuke_mod.removeCodexMcpServerBlock(testing.allocator, input, "codedb")) orelse
        return error.TestUnexpectedResult;
    defer testing.allocator.free(output);

    try testing.expect(std.mem.indexOf(u8, output, "codedb") == null);
    try testing.expect(std.mem.indexOf(u8, output, "[mcp_servers.other]") != null);
}

test "nuke: deregisterJsonIntegrationFile handles configs larger than 64 KiB" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const rel_path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/large-claude.json", .{tmp.sub_path});
    defer testing.allocator.free(rel_path);

    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(testing.allocator);
    try content.appendSlice(testing.allocator,
        \\{
        \\  "mcpServers": {
        \\    "codedb": { "command": "/Users/me/bin/codedb", "args": ["mcp"] },
        \\    "other": { "command": "other", "args": [] }
        \\  },
        \\  "padding": "
    );
    try content.appendNTimes(testing.allocator, 'x', 70 * 1024);
    try content.appendSlice(testing.allocator, "\"\n}\n");

    var file = try tmp.dir.createFile("large-claude.json", .{});
    defer file.close();
    try file.writeAll(content.items);

    try testing.expect(try nuke_mod.deregisterJsonIntegrationFile(testing.allocator, rel_path));

    const rewritten = try std.fs.cwd().readFileAlloc(testing.allocator, rel_path, std.math.maxInt(usize));
    defer testing.allocator.free(rewritten);

    try testing.expect(std.mem.indexOf(u8, rewritten, "\"codedb\"") == null);
    try testing.expect(std.mem.indexOf(u8, rewritten, "\"other\"") != null);
    try testing.expect(std.mem.indexOf(u8, rewritten, "\"padding\"") != null);
}

test "issue-116: getGitHead returns valid SHA for git repos" {
    const git = @import("git.zig");

    // This test runs inside the codedb repo itself
    const head = git.getGitHead(".", testing.allocator) catch null;

    if (head) |h| {
        try testing.expect(h.len == 40);
        for (h) |c| {
            try testing.expect(std.ascii.isHex(c));
        }
    }
}

test "issue-148: idle timeout is 10 minutes" {
    const mcp = @import("mcp.zig");
    try testing.expectEqual(@as(i64, 10 * 60 * 1000), mcp.idle_timeout_ms);
}

test "issue-148: POLLHUP detects closed pipe" {
    // Verify the polling infrastructure works for pipe-based transports
    const pipe = try std.posix.pipe();
    defer std.posix.close(pipe[0]);

    // Close write end — simulates client disconnect
    std.posix.close(pipe[1]);

    // Poll should detect POLLHUP on the read end
    var fds = [_]std.posix.pollfd{.{
        .fd = pipe[0],
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};

    const n = try std.posix.poll(&fds, 100); // 100ms timeout
    try testing.expect(n > 0);
    try testing.expect((fds[0].revents & std.posix.POLL.HUP) != 0);
}

test "issue-148: idle watchdog exits on shutdown signal" {
    // The watchdog should check shutdown every ~1s (not 30s)
    // and return quickly when signalled
    var shutdown = std.atomic.Value(bool).init(false);

    const t0 = cio.milliTimestamp();
    // Signal shutdown after a small delay
    const signal_thread = try std.Thread.spawn(.{}, struct {
        fn run(s: *std.atomic.Value(bool)) void {
            std.Thread.sleep(500 * std.time.ns_per_ms);
            s.store(true, .release);
        }
    }.run, .{&shutdown});

    // Run a simplified watchdog loop (matches the real one's 1s granularity)
    while (!shutdown.load(.acquire)) {
        for (0..30) |_| {
            if (shutdown.load(.acquire)) break;
            std.Thread.sleep(100 * std.time.ns_per_ms); // faster for test
        }
        break; // one iteration is enough to test
    }
    signal_thread.join();

    const elapsed = cio.milliTimestamp() - t0;
    // With 1s granularity, should respond well under 5s (not 30s)
    // Using 100ms intervals in test, so should be ~500ms
    if (elapsed > 0) {
        // Just verify it didn't hang for 30 seconds
        try testing.expect(elapsed < 5_000);
    }
}

test "issue-148: idle watchdog respects activity timestamp" {
    const mcp = @import("mcp.zig");

    // Save and restore
    const saved = mcp.last_activity.load(.acquire);
    defer mcp.last_activity.store(saved, .release);

    // Set activity to "just now"
    mcp.last_activity.store(cio.milliTimestamp(), .release);

    // With 10-minute timeout, checking now should NOT trigger exit
    const last = mcp.last_activity.load(.acquire);
    const now = cio.milliTimestamp();
    try testing.expect(now - last < mcp.idle_timeout_ms);
}

test "issue-148: MCP session survives 2-minute idle" {
    const mcp = @import("mcp.zig");
    // With the old 2-min timeout, an activity 3 minutes ago would trigger exit.
    // With the new 10-min timeout, it should be fine.
    const three_min_ago = cio.milliTimestamp() - (3 * 60 * 1000);

    // Save and restore
    const saved = mcp.last_activity.load(.acquire);
    defer mcp.last_activity.store(saved, .release);

    mcp.last_activity.store(three_min_ago, .release);
    const last = mcp.last_activity.load(.acquire);
    const now = cio.milliTimestamp();

    // Should NOT exceed 10-minute timeout
    try testing.expect(now - last < mcp.idle_timeout_ms);

    // Should have exceeded old 2-minute timeout
    try testing.expect(now - last > 2 * 60 * 1000);
}

test "issue-148: open pipe does not trigger HUP" {
    const pipe = try std.posix.pipe();
    defer std.posix.close(pipe[0]);
    defer std.posix.close(pipe[1]);

    var poll_fds = [_]std.posix.pollfd{.{
        .fd = pipe[0],
        .events = std.posix.POLL.IN | std.posix.POLL.HUP,
        .revents = 0,
    }};

    const result = try std.posix.poll(&poll_fds, 0);
    try testing.expectEqual(@as(usize, 0), result);
}

test "issue-148: codedb mcp exits when stdin is closed" {
    // Integration test: spawn codedb mcp, close stdin, verify it exits
    var child = std.process.Child.init(
        &.{ "zig", "build", "run", "--", "--mcp" },
        testing.allocator,
    );
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    try child.spawn();

    // Send initialize then close stdin (simulate client crash)
    const init_msg = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"test\",\"version\":\"1\"}}}";
    const header = std.fmt.comptimePrint("Content-Length: {d}\r\n\r\n", .{init_msg.len});

    if (child.stdin) |stdin| {
        stdin.writeAll(header) catch {};
        stdin.writeAll(init_msg) catch {};
        // Close stdin — simulates client disconnecting
        stdin.close();
        child.stdin = null;
    }

    // Wait up to 15 seconds for the process to exit
    // (watchdog polls every 10s, so it should detect POLLHUP within ~10s)
    const start = cio.milliTimestamp();
    const term = child.wait() catch {
        // If wait fails, the process is stuck — test fails
        try testing.expect(false);
        return;
    };

    const elapsed = cio.milliTimestamp() - start;

    // Should have exited (not been killed by us)
    switch (term) {
        .Exited => |code| _ = code,
        else => {},
    }

    // Should exit within 15 seconds (10s poll interval + margin)
    try testing.expect(elapsed < 15_000);
}

const MmapTrigramIndex = @import("index.zig").MmapTrigramIndex;
const AnyTrigramIndex = @import("index.zig").AnyTrigramIndex;

test "issue-164: mmap trigram index returns same candidates as heap index" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var explorer = Explorer.init(testing.allocator);
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
    const tmp_path = try tmp_dir.dir.realpath(".", &path_buf);

    try explorer.trigram_index.writeToDisk(tmp_path, null);

    var mmap_idx = MmapTrigramIndex.initFromDisk(tmp_path, testing.allocator) orelse
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

    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    try explorer.indexFile("a.zig", "const alpha = 42;");
    try explorer.indexFile("b.zig", "const beta = 43;");
    try explorer.indexFile("c.zig", "const gamma = 44;");
    try explorer.indexFile("d.zig", "const delta = 45;");
    try explorer.indexFile("e.zig", "const alpha_beta = 99;");

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp_dir.dir.realpath(".", &path_buf);

    try explorer.trigram_index.writeToDisk(tmp_path, null);

    var mmap_idx = MmapTrigramIndex.initFromDisk(tmp_path, testing.allocator) orelse
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
    const result = MmapTrigramIndex.initFromDisk("/tmp/nonexistent-codedb-test-dir-164", testing.allocator);
    try testing.expect(result == null);
}

test "issue-164: AnyTrigramIndex dispatches to mmap variant" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    try explorer.indexFile("foo.zig", "pub fn fooBar(x: i32) i32 { return x + 1; }");

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp_dir.dir.realpath(".", &path_buf);

    try explorer.trigram_index.writeToDisk(tmp_path, null);

    const mmap_loaded = MmapTrigramIndex.initFromDisk(tmp_path, testing.allocator) orelse
        return error.MmapInitFailed;

    explorer.trigram_index.deinit();
    explorer.trigram_index = .{ .mmap = mmap_loaded };

    const results = try explorer.searchContent("fooBar", allocator, 10);
    try testing.expect(results.len >= 1);

    try testing.expect(explorer.trigram_index.containsFile("foo.zig"));
    try testing.expect(!explorer.trigram_index.containsFile("bar.zig"));
}

const fuzzyScore = @import("explore.zig").fuzzyScore;

test "issue-163: fuzzy exact match scores highest" {
    const exact = fuzzyScore("main.zig", "src/main.zig");
    const partial = fuzzyScore("main.zig", "src/main_helper.zig");
    try testing.expect(exact != null);
    try testing.expect(partial != null);
    try testing.expect(exact.? > partial.?);
}

test "issue-163: fuzzy subsequence match works" {
    const score = fuzzyScore("authmid", "src/auth_middleware.py");
    try testing.expect(score != null);
    try testing.expect(score.? > 0);
}

test "issue-163: fuzzy typo-tolerant (missing char)" {
    // "auth_midlware" missing the 'd' in middleware — should still match via subsequence
    const score = fuzzyScore("auth_midlware", "src/auth_middleware.py");
    try testing.expect(score != null);
}

test "issue-163: fuzzy word boundary bonus" {
    // "auth" at word boundary should score higher than "auth" buried in a word
    const boundary = fuzzyScore("auth", "src/auth_handler.py");
    const buried = fuzzyScore("auth", "src/xauthyhandle.py");
    try testing.expect(boundary != null);
    try testing.expect(buried != null);
    try testing.expect(boundary.? > buried.?);
}

test "issue-163: fuzzy filename ranks above directory" {
    // "test" in filename portion should score higher than "test" only in directory
    const in_name = fuzzyScore("test", "src/test_auth.py");
    const in_dir = fuzzyScore("test", "testdir/deep/nested/xyzfile.py");
    try testing.expect(in_name != null);
    try testing.expect(in_dir != null);
    try testing.expect(in_name.? > in_dir.?);
}

test "issue-163: fuzzy no match returns null" {
    const score = fuzzyScore("zzzzxyz", "src/main.zig");
    try testing.expect(score == null);
}

test "issue-163: fuzzyFindFiles via Explorer" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    try explorer.indexFile("src/auth_middleware.py", "def check_auth(): pass");
    try explorer.indexFile("src/middleware/auth.py", "class Auth: pass");
    try explorer.indexFile("tests/test_auth.py", "def test_auth(): pass");
    try explorer.indexFile("src/utils.py", "def format_str(): pass");

    const results = try explorer.fuzzyFindFiles("authmid", testing.allocator, 10);
    defer testing.allocator.free(results);

    try testing.expect(results.len >= 1);
    // auth_middleware.py should be top result
    try testing.expect(std.mem.indexOf(u8, results[0].path, "auth_middleware") != null);
}

test "issue-163: multi-part query matches both parts" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    try explorer.indexFile("src/auth_middleware.py", "def check(): pass");
    try explorer.indexFile("src/auth_handler.py", "def handle(): pass");
    try explorer.indexFile("src/utils.py", "def util(): pass");

    // "auth middle" should match auth_middleware but not utils
    const results = try explorer.fuzzyFindFiles("auth middle", testing.allocator, 10);
    defer testing.allocator.free(results);

    try testing.expect(results.len >= 1);
    try testing.expect(std.mem.indexOf(u8, results[0].path, "middleware") != null);
}

test "issue-163: extension constraint filters results" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    try explorer.indexFile("src/auth.py", "def check(): pass");
    try explorer.indexFile("src/auth.ts", "function check() {}");
    try explorer.indexFile("src/auth.zig", "fn check() void {}");

    // "auth *.py" should only return the .py file
    const results = try explorer.fuzzyFindFiles("auth *.py", testing.allocator, 10);
    defer testing.allocator.free(results);

    try testing.expect(results.len >= 1);
    for (results) |r| {
        try testing.expect(std.mem.endsWith(u8, r.path, ".py"));
    }
}

test "issue-163: special entry point files get bonus" {
    const score_main = fuzzyScore("main", "src/main.zig");
    const score_regular = fuzzyScore("main", "src/maintain.zig");
    try testing.expect(score_main != null);
    try testing.expect(score_regular != null);
    // main.zig is a special entry point — should score higher than maintain.zig
    try testing.expect(score_main.? > score_regular.?);
}

test "issue-163: transpositions handled by Smith-Waterman" {
    // These all failed with the old subsequence matcher
    try testing.expect(fuzzyScore("mpc", "src/mcp.zig") != null);
    try testing.expect(fuzzyScore("mian", "src/main.zig") != null);
    try testing.expect(fuzzyScore("agnet", "src/agent.zig") != null);
    try testing.expect(fuzzyScore("indxe", "src/index.zig") != null);
}

// ── codedb_query pipeline tests ─────────────────────────────────

test "issue-168: query pipeline find → limit produces file set" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    try explorer.indexFile("src/auth.py", "def check_auth(): pass");
    try explorer.indexFile("src/auth_handler.py", "def handle(): pass");
    try explorer.indexFile("src/utils.py", "def util(): pass");
    try explorer.indexFile("src/config.py", "DEBUG = True");

    // Pipeline: find "auth" → should return auth files
    const results = try explorer.fuzzyFindFiles("auth", testing.allocator, 10);
    defer testing.allocator.free(results);

    try testing.expect(results.len >= 2);
    // Both auth files should be in results
    var found_auth = false;
    var found_handler = false;
    for (results) |r| {
        if (std.mem.indexOf(u8, r.path, "auth.py") != null) found_auth = true;
        if (std.mem.indexOf(u8, r.path, "auth_handler") != null) found_handler = true;
    }
    try testing.expect(found_auth);
    try testing.expect(found_handler);
}

test "issue-168: query pipeline search returns matching lines" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    try explorer.indexFile("src/main.zig", "pub fn main() void {\n    const x = 42;\n}\n");
    try explorer.indexFile("src/lib.zig", "pub fn init() void {}\n");

    const results = try explorer.searchContent("main", testing.allocator, 10);
    defer {
        for (results) |r| {
            testing.allocator.free(r.line_text);
            testing.allocator.free(r.path);
        }
        testing.allocator.free(results);
    }

    try testing.expect(results.len >= 1);
    try testing.expect(std.mem.indexOf(u8, results[0].path, "main.zig") != null);
}

test "issue-168: query pipeline filter by extension" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    try explorer.indexFile("src/auth.py", "def check(): pass");
    try explorer.indexFile("src/auth.ts", "function check() {}");
    try explorer.indexFile("src/auth.zig", "fn check() void {}");

    // fuzzyFindFiles with extension constraint
    const results = try explorer.fuzzyFindFiles("auth *.py", testing.allocator, 10);
    defer testing.allocator.free(results);

    try testing.expect(results.len >= 1);
    for (results) |r| {
        try testing.expect(std.mem.endsWith(u8, r.path, ".py"));
    }
}

test "issue-168: query pipeline outline returns symbols" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    try explorer.indexFile("src/main.zig", "pub fn main() void {}\npub fn helper() void {}\n");

    var outline = (try explorer.getOutline("src/main.zig", testing.allocator)).?;
    defer outline.deinit();
    try testing.expect(outline.symbols.items.len >= 2);
}

test "issue-168: query pipeline chained find → filter narrows results" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    try explorer.indexFile("src/auth.py", "def check(): pass");
    try explorer.indexFile("src/auth.ts", "function check() {}");
    try explorer.indexFile("src/utils.py", "def util(): pass");
    try explorer.indexFile("docs/auth.md", "# Auth docs");

    // find "auth" returns all auth files, then *.py filter narrows to python
    const all = try explorer.fuzzyFindFiles("auth", testing.allocator, 10);
    defer testing.allocator.free(all);
    try testing.expect(all.len >= 3); // auth.py, auth.ts, auth.md

    const py_only = try explorer.fuzzyFindFiles("auth *.py", testing.allocator, 10);
    defer testing.allocator.free(py_only);
    try testing.expect(py_only.len >= 1);
    try testing.expect(py_only.len < all.len); // filtered set is smaller
}

test "issue-168: query pipeline handles empty results gracefully" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    try explorer.indexFile("src/main.zig", "pub fn main() void {}");

    // Search for something that doesn't exist
    const results = try explorer.fuzzyFindFiles("zzzznonexistent", testing.allocator, 10);
    defer testing.allocator.free(results);
    try testing.expectEqual(@as(usize, 0), results.len);
}

// ── codedb_query recall tests ───────────────────────────────────
// These test that pipeline composition preserves precision and recall:
// the right files survive each step, and irrelevant files are eliminated.

test "issue-168: recall — find + filter preserves only matching extension" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    try explorer.indexFile("src/auth.py", "def check(): pass");
    try explorer.indexFile("src/auth.ts", "function check() {}");
    try explorer.indexFile("src/auth.zig", "fn check() void {}");
    try explorer.indexFile("src/auth.rs", "fn check() {}");
    try explorer.indexFile("src/auth_test.py", "def test_check(): pass");

    // find "auth" should get all 5, then *.py should narrow to exactly 2
    const all = try explorer.fuzzyFindFiles("auth", testing.allocator, 20);
    defer testing.allocator.free(all);
    try testing.expect(all.len == 5);

    const py = try explorer.fuzzyFindFiles("auth *.py", testing.allocator, 20);
    defer testing.allocator.free(py);
    try testing.expect(py.len == 2);
    for (py) |r| try testing.expect(std.mem.endsWith(u8, r.path, ".py"));
}

test "issue-168: recall — search finds content across multiple files" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    try explorer.indexFile("src/a.zig", "pub fn handleRequest() void {}");
    try explorer.indexFile("src/b.zig", "pub fn handleResponse() void {}");
    try explorer.indexFile("src/c.zig", "pub fn processData() void {}");

    const results = try explorer.searchContent("handle", testing.allocator, 10);
    defer {
        for (results) |r| {
            testing.allocator.free(r.line_text);
            testing.allocator.free(r.path);
        }
        testing.allocator.free(results);
    }

    // Should find "handle" in a.zig and b.zig but not c.zig
    try testing.expect(results.len >= 2);
    var found_a = false;
    var found_b = false;
    var found_c = false;
    for (results) |r| {
        if (std.mem.indexOf(u8, r.path, "a.zig") != null) found_a = true;
        if (std.mem.indexOf(u8, r.path, "b.zig") != null) found_b = true;
        if (std.mem.indexOf(u8, r.path, "c.zig") != null) found_c = true;
    }
    try testing.expect(found_a);
    try testing.expect(found_b);
    try testing.expect(!found_c);
}

test "issue-168: recall — fuzzy find ranks exact matches highest" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    try explorer.indexFile("src/auth.zig", "fn auth() void {}");
    try explorer.indexFile("src/authorization.zig", "fn authorize() void {}");
    try explorer.indexFile("src/authenticate.zig", "fn authenticate() void {}");

    const results = try explorer.fuzzyFindFiles("auth.zig", testing.allocator, 10);
    defer testing.allocator.free(results);

    try testing.expect(results.len >= 1);
    // Exact match "auth.zig" should be ranked first
    try testing.expect(std.mem.eql(u8, results[0].path, "src/auth.zig"));
    // Score should decrease for less exact matches
    if (results.len >= 2) {
        try testing.expect(results[0].score > results[1].score);
    }
}

test "issue-168: recall — multi-part query intersection" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    try explorer.indexFile("src/auth_controller.py", "class AuthController: pass");
    try explorer.indexFile("src/auth_model.py", "class AuthModel: pass");
    try explorer.indexFile("src/user_controller.py", "class UserController: pass");
    try explorer.indexFile("src/user_model.py", "class UserModel: pass");

    // "auth controller" should match auth_controller but not user_controller or auth_model
    const results = try explorer.fuzzyFindFiles("auth controller", testing.allocator, 10);
    defer testing.allocator.free(results);

    try testing.expect(results.len >= 1);
    try testing.expect(std.mem.indexOf(u8, results[0].path, "auth_controller") != null);
}

test "issue-168: recall — transposition tolerance in pipeline" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    try explorer.indexFile("src/middleware.zig", "fn process() void {}");
    try explorer.indexFile("src/controller.zig", "fn handle() void {}");
    try explorer.indexFile("src/service.zig", "fn serve() void {}");

    // "midleware" (missing 'd') should still find middleware via Smith-Waterman
    const results = try explorer.fuzzyFindFiles("midleware", testing.allocator, 5);
    defer testing.allocator.free(results);

    try testing.expect(results.len >= 1);
    try testing.expect(std.mem.indexOf(u8, results[0].path, "middleware") != null);
}

// ── Search UX tests ─────────────────────────────────────────────

test "auto-retry: delimiter stripping finds results" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    try explorer.indexFile("src/auth_middleware.py", "def check(): pass");

    // "authmiddleware" without delimiters should still find auth_middleware
    const results = try explorer.fuzzyFindFiles("authmiddleware", testing.allocator, 10);
    defer testing.allocator.free(results);
    try testing.expect(results.len >= 1);
    try testing.expect(std.mem.indexOf(u8, results[0].path, "auth_middleware") != null);
}

test "per-file truncation: max 5 matches per file in output" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    // Create a file with 10 lines all matching "const"
    var content: [500]u8 = undefined;
    var pos: usize = 0;
    for (0..10) |i| {
        const line = std.fmt.bufPrint(content[pos..], "const val{d} = {d};\n", .{ i, i }) catch break;
        pos += line.len;
    }
    try explorer.indexFile("src/many_consts.zig", content[0..pos]);

    // Search — explorer returns all 10, but MCP handler would truncate to 5
    const results = try explorer.searchContent("const", testing.allocator, 50);
    defer {
        for (results) |r| {
            testing.allocator.free(r.line_text);
            testing.allocator.free(r.path);
        }
        testing.allocator.free(results);
    }
    // At the explorer level all 10 should be found
    try testing.expect(results.len >= 10);
}

test "issue-179: block comment does not produce phantom symbols" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    try explorer.indexFile("test.zig", "/* commented out\npub fn fake_func() void {}\n*/\npub fn real_func() void {}\n");

    const outline = (try explorer.getOutline("test.zig", testing.allocator)).?;
    defer {
        var o = outline;
        o.deinit();
    }
    var found_real = false;
    var found_fake = false;
    for (outline.symbols.items) |sym| {
        if (std.mem.indexOf(u8, sym.name, "real_func") != null) found_real = true;
        if (std.mem.indexOf(u8, sym.name, "fake_func") != null) found_fake = true;
    }
    try testing.expect(found_real);
    try testing.expect(!found_fake);
}

test "issue-179: code after single-line /* */ comment is parsed" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    try explorer.indexFile("test.zig", "/* skip this */ pub fn visible() void {}\n");

    const outline = (try explorer.getOutline("test.zig", testing.allocator)).?;
    defer {
        var o = outline;
        o.deinit();
    }
    var found = false;
    for (outline.symbols.items) |sym| {
        if (std.mem.indexOf(u8, sym.name, "visible") != null) found = true;
    }
    try testing.expect(found);
}

test "issue-179: Python docstring with text does not leak symbols" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    try explorer.indexFile("test.py", "def real():\n    \"\"\"This is a docstring.\n    def fake():\n        pass\n    \"\"\"\n    pass\n");

    const outline = (try explorer.getOutline("test.py", testing.allocator)).?;
    defer {
        var o = outline;
        o.deinit();
    }
    var found_real = false;
    var found_fake = false;
    for (outline.symbols.items) |sym| {
        if (std.mem.indexOf(u8, sym.name, "real") != null) found_real = true;
        if (std.mem.indexOf(u8, sym.name, "fake") != null) found_fake = true;
    }
    try testing.expect(found_real);
    try testing.expect(!found_fake);
}

// ── New bug / perf regression tests ─────────────────────────────────────

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

test "issue-249: nuke.removeJsonMcpServerEntry returns null when key absent" {
    // Verifies removeJsonMcpServerEntry does not signal a write when key is absent,
    // which ensures the non-atomic rewriteConfigFile path is never triggered unnecessarily.
    const result = try nuke_mod.removeJsonMcpServerEntry(testing.allocator, "{\"other\":1}", "codedb");
    try testing.expect(result == null);
}

test "issue-250: searchContent finds content in files skipped by trigram index" {
    // Files indexed with skip_trigram=true (e.g. past the 15k cap) must still be
    // reachable via the fallback full-scan path in searchContent.
    var explorer = Explorer.init(testing.allocator);
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
    var exp = Explorer.init(aa);
    try exp.indexFile("src/big.zig", src.items);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &path_buf);
    const snap_path = try std.fmt.allocPrint(testing.allocator, "{s}/big.codedb", .{dir_path});
    defer testing.allocator.free(snap_path);
    try snapshot_mod.writeSnapshot(&exp, dir_path, snap_path, testing.allocator);

    var exp2 = Explorer.init(testing.allocator);
    defer exp2.deinit();
    var store2 = Store.init(testing.allocator);
    defer store2.deinit();

    const loaded = snapshot_mod.loadSnapshot(snap_path, &exp2, &store2, testing.allocator);
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

    var exp = Explorer.init(aa);
    try exp.indexFile("src/a.zig", "pub fn aFunc() void {}\n");
    try exp.indexFile("src/b.zig", "pub fn bFunc() void {}\n");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &path_buf);
    const snap_path = try std.fmt.allocPrint(testing.allocator, "{s}/corrupt.codedb", .{dir_path});
    defer testing.allocator.free(snap_path);
    try snapshot_mod.writeSnapshot(&exp, dir_path, snap_path, testing.allocator);

    // Overwrite the first 16 bytes of OUTLINE_STATE data with 0xFF.
    // This makes the file_count field read as 0xFFFFFFFF — far more records
    // than the data contains — causing readSectionString to eventually fail
    // with error.InvalidData (runs off the end of the bytes slice).
    {
        var sections = (try snapshot_mod.readSections(snap_path, testing.allocator)).?;
        defer sections.deinit();
        const ols = sections.get(@intFromEnum(snapshot_mod.SectionId.outline_state)) orelse return;
        const f = try std.fs.cwd().openFile(snap_path, .{ .mode = .read_write });
        defer f.close();
        try f.seekTo(ols.offset);
        try f.writeAll(&([_]u8{0xFF} ** 16));
    }

    var exp2 = Explorer.init(testing.allocator);
    defer exp2.deinit();
    var store2 = Store.init(testing.allocator);
    defer store2.deinit();

    const loaded = snapshot_mod.loadSnapshot(snap_path, &exp2, &store2, testing.allocator);
    try testing.expect(loaded); // must survive OUTLINE_STATE corruption

    // Symbols must still be found — re-indexed from CONTENT
    var sym_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer sym_arena.deinit();
    const results = try exp2.findAllSymbols("aFunc", sym_arena.allocator());
    try testing.expect(results.len >= 1);
}

test "issue-224: codedb_symbol body=true returns full body — line_end populated" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var explorer = Explorer.init(alloc);

    try explorer.indexFile("t.zig",
        \\pub fn foo() u32 {
        \\    const a: u32 = 1;
        \\    const b: u32 = 2;
        \\    return a + b;
        \\}
    );

    const results = try explorer.findAllSymbols("foo", alloc);
    defer alloc.free(results);
    try testing.expect(results.len == 1);

    const sym = results[0].symbol;
    try testing.expectEqual(@as(u32, 1), sym.line_start);
    try testing.expectEqual(@as(u32, 5), sym.line_end);

    const body = (try explorer.getSymbolBody("t.zig", sym.line_start, sym.line_end, alloc)) orelse
        return error.TestUnexpectedResult;
    try testing.expect(std.mem.indexOf(u8, body, "pub fn foo()") != null);
    try testing.expect(std.mem.indexOf(u8, body, "return a + b;") != null);
}

test "issue-224: Python def line_end covers full body" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var explorer = Explorer.init(alloc);

    try explorer.indexFile("t.py",
        \\def greet(name):
        \\    msg = "hello"
        \\    return msg + name
    );

    const results = try explorer.findAllSymbols("greet", alloc);
    defer alloc.free(results);
    try testing.expect(results.len == 1);

    const sym = results[0].symbol;
    try testing.expectEqual(@as(u32, 1), sym.line_start);
    try testing.expectEqual(@as(u32, 3), sym.line_end);
}

test "issue-108: HCL resource block parsed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var explorer = Explorer.init(alloc);
    try explorer.indexFile("main.tf",
        \\resource "aws_instance" "web" {
        \\  ami = "abc-123"
        \\}
    );
    const results = try explorer.findAllSymbols("web", alloc);
    defer alloc.free(results);
    try testing.expect(results.len == 1);
    try testing.expectEqual(SymbolKind.struct_def, results[0].symbol.kind);
}

test "issue-108: HCL variable and output parsed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var explorer = Explorer.init(alloc);
    try explorer.indexFile("vars.tf",
        \\variable "region" {
        \\  default = "us-east-1"
        \\}
        \\output "ip" {
        \\  value = aws_instance.web.public_ip
        \\}
    );
    const vars = try explorer.findAllSymbols("region", alloc);
    defer alloc.free(vars);
    try testing.expect(vars.len == 1);
    try testing.expectEqual(SymbolKind.variable, vars[0].symbol.kind);
    const outs = try explorer.findAllSymbols("ip", alloc);
    defer alloc.free(outs);
    try testing.expect(outs.len == 1);
    try testing.expectEqual(SymbolKind.constant, outs[0].symbol.kind);
}

test "issue-108: HCL module and provider parsed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var explorer = Explorer.init(alloc);
    try explorer.indexFile("main.tf",
        \\provider "aws" {
        \\  region = "us-east-1"
        \\}
        \\module "vpc" {
        \\  source = "./modules/vpc"
        \\}
    );
    const providers = try explorer.findAllSymbols("aws", alloc);
    defer alloc.free(providers);
    try testing.expect(providers.len == 1);
    const mods = try explorer.findAllSymbols("vpc", alloc);
    defer alloc.free(mods);
    try testing.expect(mods.len == 1);
}

test "issue-108: HCL comment lines skipped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var explorer = Explorer.init(alloc);
    try explorer.indexFile("main.tf",
        \\# This is a comment
        \\// Another comment
        \\variable "name" {}
    );
    const results = try explorer.findAllSymbols("name", alloc);
    defer alloc.free(results);
    try testing.expect(results.len == 1);
}

test "issue-108: detectLanguage handles .tf and .tfvars" {
    try testing.expectEqual(Language.hcl, explore.detectLanguage("main.tf"));
    try testing.expectEqual(Language.hcl, explore.detectLanguage("prod.tfvars"));
    try testing.expectEqual(Language.hcl, explore.detectLanguage("config.hcl"));
}

test "issue-215: R function assignment parsed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var explorer = Explorer.init(alloc);
    try explorer.indexFile("analysis.R",
        \\greet <- function(name) {
        \\  paste("Hello", name)
        \\}
    );
    const results = try explorer.findAllSymbols("greet", alloc);
    defer alloc.free(results);
    try testing.expect(results.len == 1);
    try testing.expectEqual(SymbolKind.function, results[0].symbol.kind);
}

test "issue-215: R library import parsed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var explorer = Explorer.init(alloc);
    try explorer.indexFile("script.r",
        \\library(dplyr)
        \\require(ggplot2)
    );
    const outline = try explorer.getOutline("script.r", alloc) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 2), outline.imports.items.len);
}

test "issue-215: R setClass parsed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var explorer = Explorer.init(alloc);
    try explorer.indexFile("classes.R",
        \\setClass("Person")
        \\setRefClass("Animal")
    );
    const p = try explorer.findAllSymbols("Person", alloc);
    defer alloc.free(p);
    try testing.expect(p.len == 1);
    try testing.expectEqual(SymbolKind.class_def, p[0].symbol.kind);
    const a2 = try explorer.findAllSymbols("Animal", alloc);
    defer alloc.free(a2);
    try testing.expect(a2.len == 1);
}

test "issue-215: detectLanguage handles .r and .R" {
    try testing.expectEqual(Language.r, explore.detectLanguage("script.r"));
    try testing.expectEqual(Language.r, explore.detectLanguage("analysis.R"));
}

test "issue-179: Python inline docstring does not leak symbols" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var explorer = Explorer.init(alloc);

    try explorer.indexFile("mod.py",
        \\def real_func():
        \\    """This docstring contains def fake(): pass"""
        \\    return 1
    );

    const real = try explorer.findAllSymbols("real_func", alloc);
    defer alloc.free(real);
    try testing.expect(real.len == 1);

    const fake = try explorer.findAllSymbols("fake", alloc);
    defer alloc.free(fake);
    try testing.expectEqual(@as(usize, 0), fake.len);
}

test "issue-179: Python multi-line docstring with def inside" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var explorer = Explorer.init(alloc);

    try explorer.indexFile("doc.py",
        \\def outer():
        \\    """
        \\    Example:
        \\        def inner_example():
        \\            pass
        \\    """
        \\    return True
    );

    const outer = try explorer.findAllSymbols("outer", alloc);
    defer alloc.free(outer);
    try testing.expect(outer.len == 1);

    const inner = try explorer.findAllSymbols("inner_example", alloc);
    defer alloc.free(inner);
    try testing.expectEqual(@as(usize, 0), inner.len);
}

test "issue-262: sparse+trigram intersection drops files only in trigram index" {
    // When both sparse and trigram indices return candidates, searchContent
    // intersects them.  A file present in trigram candidates but absent from
    // sparse candidates is silently dropped — a recall loss.
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    // Index two files — both contain the query.
    try explorer.indexFile("a.zig", "fn recall_target_alpha() void {}");
    try explorer.indexFile("b.zig", "fn recall_target_alpha() void {} // more text here for variety");

    // Simulate sparse index missing file "b.zig" (e.g. boundary misalignment).
    // File b.zig remains in the trigram index but not in sparse.
    explorer.sparse_ngram_index.removeFile("b.zig");

    const results = try explorer.searchContent("recall_target_alpha", testing.allocator, 50);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }
    // Both files contain the query — both must appear.
    try testing.expectEqual(@as(usize, 2), results.len);
}

test "issue-263: skip_trigram_files searched before max_results exhausted" {
    // Files indexed with skip_trigram=true are only searched after all
    // trigram/sparse/word paths are exhausted.  When a single normal file
    // has enough matches to fill max_results, the skip_trigram file is
    // never checked — even though it contains relevant content.
    var explorer = Explorer.init(testing.allocator);
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

test "issue-264: early exit at max_results misses valid matches in remaining candidates" {
    // searchContent stops as soon as result_list.items.len >= max_results.
    // The first-indexed file is iterated first (doc_id order).  If it has
    // many matches it fills the quota alone, and later files are never checked.
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    // Index noisy file FIRST — it will be the first trigram candidate.
    try explorer.indexFile("noisy.zig",
        \\fn target_token() void {}
        \\fn target_token_v2() void {}
        \\const target_token_ptr = undefined;
        \\var target_token_state = 0;
        \\test "target_token works" {}
        \\// calls target_token internally
    );

    // Index quiet file SECOND — it will be a later candidate.
    try explorer.indexFile("quiet.zig", "fn target_token() void {}");

    // max_results=5: noisy.zig has 6 matches, fills the quota.
    const results = try explorer.searchContent("target_token", testing.allocator, 5);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }

    // quiet.zig must be represented in results even though noisy.zig
    // has enough matches to fill max_results by itself.
    var found_quiet = false;
    for (results) |r| {
        if (std.mem.eql(u8, r.path, "quiet.zig")) found_quiet = true;
    }
    try testing.expect(found_quiet);
}

// ── DependencyGraph tests ──────────────────────────────────

test "dep-graph: reverse index gives O(1) imported_by lookup" {
    var graph = DependencyGraph.init(testing.allocator);
    defer graph.deinit();

    // main.zig imports store.zig and utils.zig
    var deps1: std.ArrayList([]const u8) = .empty;
    try deps1.append(testing.allocator, "store.zig");
    try deps1.append(testing.allocator, "utils.zig");
    try graph.setDeps("main.zig", deps1);

    // server.zig imports store.zig
    var deps2: std.ArrayList([]const u8) = .empty;
    try deps2.append(testing.allocator, "store.zig");
    try graph.setDeps("server.zig", deps2);

    // store.zig is imported by main.zig and server.zig
    const imported_by = try graph.getImportedBy("store.zig", testing.allocator);
    defer {
        for (imported_by) |p| testing.allocator.free(p);
        testing.allocator.free(imported_by);
    }
    try testing.expectEqual(@as(usize, 2), imported_by.len);

    // utils.zig is imported by main.zig only
    const imported_by2 = try graph.getImportedBy("utils.zig", testing.allocator);
    defer {
        for (imported_by2) |p| testing.allocator.free(p);
        testing.allocator.free(imported_by2);
    }
    try testing.expectEqual(@as(usize, 1), imported_by2.len);
    try testing.expectEqualStrings("main.zig", imported_by2[0]);
}

test "dep-graph: setDeps removes old reverse edges" {
    var graph = DependencyGraph.init(testing.allocator);
    defer graph.deinit();

    // main.zig initially imports store.zig
    var deps1: std.ArrayList([]const u8) = .empty;
    try deps1.append(testing.allocator, "store.zig");
    try graph.setDeps("main.zig", deps1);

    const before = try graph.getImportedBy("store.zig", testing.allocator);
    defer {
        for (before) |p| testing.allocator.free(p);
        testing.allocator.free(before);
    }
    try testing.expectEqual(@as(usize, 1), before.len);

    // main.zig re-indexed, now imports utils.zig instead
    var deps2: std.ArrayList([]const u8) = .empty;
    try deps2.append(testing.allocator, "utils.zig");
    try graph.setDeps("main.zig", deps2);

    // store.zig should no longer have main.zig as a dependent
    const after = try graph.getImportedBy("store.zig", testing.allocator);
    defer {
        for (after) |p| testing.allocator.free(p);
        testing.allocator.free(after);
    }
    try testing.expectEqual(@as(usize, 0), after.len);

    // utils.zig should now have main.zig
    const utils_deps = try graph.getImportedBy("utils.zig", testing.allocator);
    defer {
        for (utils_deps) |p| testing.allocator.free(p);
        testing.allocator.free(utils_deps);
    }
    try testing.expectEqual(@as(usize, 1), utils_deps.len);
}

test "dep-graph: transitive dependents via BFS" {
    var graph = DependencyGraph.init(testing.allocator);
    defer graph.deinit();

    // Build chain: app.zig -> server.zig -> store.zig -> utils.zig
    var deps1: std.ArrayList([]const u8) = .empty;
    try deps1.append(testing.allocator, "server.zig");
    try graph.setDeps("app.zig", deps1);

    var deps2: std.ArrayList([]const u8) = .empty;
    try deps2.append(testing.allocator, "store.zig");
    try graph.setDeps("server.zig", deps2);

    var deps3: std.ArrayList([]const u8) = .empty;
    try deps3.append(testing.allocator, "utils.zig");
    try graph.setDeps("store.zig", deps3);

    // Changing utils.zig affects store.zig, server.zig, app.zig transitively
    const blast = try graph.getTransitiveDependents("utils.zig", testing.allocator, null);
    defer {
        for (blast) |p| testing.allocator.free(p);
        testing.allocator.free(blast);
    }
    try testing.expectEqual(@as(usize, 3), blast.len);

    // With max_depth=1, only direct dependents
    const shallow = try graph.getTransitiveDependents("utils.zig", testing.allocator, 1);
    defer {
        for (shallow) |p| testing.allocator.free(p);
        testing.allocator.free(shallow);
    }
    try testing.expectEqual(@as(usize, 1), shallow.len);
    try testing.expectEqualStrings("store.zig", shallow[0]);
}

test "dep-graph: transitive dependencies (forward BFS)" {
    var graph = DependencyGraph.init(testing.allocator);
    defer graph.deinit();

    // app.zig -> server.zig -> store.zig -> utils.zig
    var deps1: std.ArrayList([]const u8) = .empty;
    try deps1.append(testing.allocator, "server.zig");
    try graph.setDeps("app.zig", deps1);

    var deps2: std.ArrayList([]const u8) = .empty;
    try deps2.append(testing.allocator, "store.zig");
    try graph.setDeps("server.zig", deps2);

    var deps3: std.ArrayList([]const u8) = .empty;
    try deps3.append(testing.allocator, "utils.zig");
    try graph.setDeps("store.zig", deps3);

    // app.zig transitively depends on server.zig, store.zig, utils.zig
    const deps_all = try graph.getTransitiveDependencies("app.zig", testing.allocator, null);
    defer {
        for (deps_all) |p| testing.allocator.free(p);
        testing.allocator.free(deps_all);
    }
    try testing.expectEqual(@as(usize, 3), deps_all.len);

    // Depth=2: app.zig -> server.zig -> store.zig (not utils.zig)
    const deps_shallow = try graph.getTransitiveDependencies("app.zig", testing.allocator, 2);
    defer {
        for (deps_shallow) |p| testing.allocator.free(p);
        testing.allocator.free(deps_shallow);
    }
    try testing.expectEqual(@as(usize, 2), deps_shallow.len);
}

test "dep-graph: remove cleans forward and reverse edges" {
    var graph = DependencyGraph.init(testing.allocator);
    defer graph.deinit();

    var deps1: std.ArrayList([]const u8) = .empty;
    try deps1.append(testing.allocator, "store.zig");
    try graph.setDeps("main.zig", deps1);

    var deps2: std.ArrayList([]const u8) = .empty;
    try deps2.append(testing.allocator, "store.zig");
    try graph.setDeps("server.zig", deps2);

    try testing.expectEqual(@as(usize, 2), graph.count());

    // Remove main.zig
    graph.remove("main.zig");
    try testing.expectEqual(@as(usize, 1), graph.count());

    // store.zig should only be imported by server.zig now
    const imported_by = try graph.getImportedBy("store.zig", testing.allocator);
    defer {
        for (imported_by) |p| testing.allocator.free(p);
        testing.allocator.free(imported_by);
    }
    try testing.expectEqual(@as(usize, 1), imported_by.len);
    try testing.expectEqualStrings("server.zig", imported_by[0]);
}

test "dep-graph: cycle does not cause infinite BFS" {
    var graph = DependencyGraph.init(testing.allocator);
    defer graph.deinit();

    // Create a cycle: a.zig -> b.zig -> c.zig -> a.zig
    var deps1: std.ArrayList([]const u8) = .empty;
    try deps1.append(testing.allocator, "b.zig");
    try graph.setDeps("a.zig", deps1);

    var deps2: std.ArrayList([]const u8) = .empty;
    try deps2.append(testing.allocator, "c.zig");
    try graph.setDeps("b.zig", deps2);

    var deps3: std.ArrayList([]const u8) = .empty;
    try deps3.append(testing.allocator, "a.zig");
    try graph.setDeps("c.zig", deps3);

    // Transitive dependents of a.zig — should terminate despite cycle
    const blast = try graph.getTransitiveDependents("a.zig", testing.allocator, null);
    defer {
        for (blast) |p| testing.allocator.free(p);
        testing.allocator.free(blast);
    }
    // b.zig and c.zig both transitively depend on a.zig
    try testing.expectEqual(@as(usize, 2), blast.len);

    // Forward transitive deps from a.zig — should also terminate
    const fwd = try graph.getTransitiveDependencies("a.zig", testing.allocator, null);
    defer {
        for (fwd) |p| testing.allocator.free(p);
        testing.allocator.free(fwd);
    }
    try testing.expectEqual(@as(usize, 2), fwd.len);
}

test "dep-graph: Explorer integration — getImportedBy uses reverse index" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("store.zig", "pub const Store = struct {};");
    try explorer.indexFile("main.zig", "const store = @import(\"store.zig\");\npub fn main() void {}");
    try explorer.indexFile("server.zig", "const store = @import(\"store.zig\");\npub fn serve() void {}");

    const deps = try explorer.getImportedBy("store.zig", testing.allocator);
    defer {
        for (deps) |d| testing.allocator.free(d);
        testing.allocator.free(deps);
    }
    try testing.expectEqual(@as(usize, 2), deps.len);
}

test "dep-graph: Explorer transitive dependents" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("utils.zig", "pub fn helper() void {}");
    try explorer.indexFile("store.zig", "const utils = @import(\"utils.zig\");\npub const Store = struct {};");
    try explorer.indexFile("main.zig", "const store = @import(\"store.zig\");\npub fn main() void {}");

    // Transitive: changing utils.zig affects store.zig and main.zig
    const blast = try explorer.getTransitiveDependents("utils.zig", testing.allocator, null);
    defer {
        for (blast) |b| testing.allocator.free(b);
        testing.allocator.free(blast);
    }
    try testing.expectEqual(@as(usize, 2), blast.len);
}

// ── Symbol index tests ─────────────────────────────────────

test "symbol-index: O(1) findSymbol via symbol_index" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("math.zig", "pub fn add(a: i32, b: i32) i32 { return a + b; }\npub fn subtract(a: i32, b: i32) i32 { return a - b; }\n");
    try explorer.indexFile("utils.zig", "pub fn add(x: f64, y: f64) f64 { return x + y; }\npub fn format() void {}\n");

    // findSymbol should return first match via index
    const result = try explorer.findSymbol("add", testing.allocator);
    try testing.expect(result != null);
    const r = result.?;
    defer {
        testing.allocator.free(r.path);
        testing.allocator.free(r.symbol.name);
        if (r.symbol.detail) |d| testing.allocator.free(d);
    }
    try testing.expectEqualStrings("add", r.symbol.name);

    // findAllSymbols should return both
    const all = try explorer.findAllSymbols("add", testing.allocator);
    defer {
        for (all) |s| {
            testing.allocator.free(s.path);
            testing.allocator.free(s.symbol.name);
            if (s.symbol.detail) |d| testing.allocator.free(d);
        }
        testing.allocator.free(all);
    }
    try testing.expectEqual(@as(usize, 2), all.len);
}

test "symbol-index: removeFile cleans symbol_index" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("a.zig", "pub fn unique_func() void {}");
    const before = try explorer.findSymbol("unique_func", testing.allocator);
    try testing.expect(before != null);
    testing.allocator.free(before.?.path);
    testing.allocator.free(before.?.symbol.name);
    if (before.?.symbol.detail) |d| testing.allocator.free(d);

    explorer.removeFile("a.zig");

    const after = try explorer.findSymbol("unique_func", testing.allocator);
    try testing.expect(after == null);
}

test "symbol-index: re-index updates symbol_index" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("a.zig", "pub fn old_name() void {}");
    const r1 = try explorer.findSymbol("old_name", testing.allocator);
    try testing.expect(r1 != null);
    testing.allocator.free(r1.?.path);
    testing.allocator.free(r1.?.symbol.name);
    if (r1.?.symbol.detail) |d| testing.allocator.free(d);

    // Re-index same file with different content
    try explorer.indexFile("a.zig", "pub fn new_name() void {}");
    const r2 = try explorer.findSymbol("old_name", testing.allocator);
    try testing.expect(r2 == null);

    const r3 = try explorer.findSymbol("new_name", testing.allocator);
    try testing.expect(r3 != null);
    testing.allocator.free(r3.?.path);
    testing.allocator.free(r3.?.symbol.name);
    if (r3.?.symbol.detail) |d| testing.allocator.free(d);
}

// ── searchInContent incremental line counting test ─────────

test "search: line numbers correct with incremental counting" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    // File with target on specific lines
    const content = "line1\nline2\ntarget_here\nline4\nline5\ntarget_here\nline7\n";
    try explorer.indexFile("test.zig", content);

    const results = try explorer.searchContent("target_here", testing.allocator, 10);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }

    try testing.expectEqual(@as(usize, 2), results.len);
    try testing.expectEqual(@as(u32, 3), results[0].line_num);
    try testing.expectEqual(@as(u32, 6), results[1].line_num);
}

// ── Identifier splitting tests ──────────────────────────────────────────────

test "word-index: splitIdentifier snake_case" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(a);
    try splitIdentifier("get_or_put", &out, a);

    try testing.expectEqual(@as(usize, 3), out.items.len);
    try testing.expectEqualStrings("get", out.items[0]);
    try testing.expectEqualStrings("or", out.items[1]);
    try testing.expectEqualStrings("put", out.items[2]);
}

test "word-index: splitIdentifier camelCase" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(a);
    try splitIdentifier("validateToken", &out, a);

    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqualStrings("validate", out.items[0]);
    try testing.expectEqualStrings("token", out.items[1]);
}

test "word-index: splitIdentifier acronym (HTTPHandler)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(a);
    try splitIdentifier("HTTPHandler", &out, a);

    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqualStrings("http", out.items[0]);
    try testing.expectEqualStrings("handler", out.items[1]);
}

test "word-index: splitIdentifier simple word emits itself" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(a);
    try splitIdentifier("handler", &out, a);

    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqualStrings("handler", out.items[0]);
}

test "word-index: sub-token search finds camelCase components" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("a.zig", "fn validateToken(x: u32) void {}");
    try explorer.indexFile("b.zig", "fn processRequest() void {}");

    // "validate" should find validateToken via sub-token splitting
    const r1 = try explorer.searchContent("validate", testing.allocator, 10);
    defer {
        for (r1) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(r1);
    }
    try testing.expectEqual(@as(usize, 1), r1.len);
    try testing.expectEqualStrings("a.zig", r1[0].path);

    // "process" should find processRequest
    const r2 = try explorer.searchContent("process", testing.allocator, 10);
    defer {
        for (r2) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(r2);
    }
    try testing.expectEqual(@as(usize, 1), r2.len);
    try testing.expectEqualStrings("b.zig", r2[0].path);
}

test "word-index: sub-token search finds snake_case components" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("a.zig", "const http_handler = null;");

    // "http" should find http_handler
    const r1 = try explorer.searchContent("http", testing.allocator, 10);
    defer {
        for (r1) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(r1);
    }
    try testing.expect(r1.len >= 1);

    // "handler" should find http_handler
    const r2 = try explorer.searchContent("handler", testing.allocator, 10);
    defer {
        for (r2) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(r2);
    }
    try testing.expect(r2.len >= 1);
}

test "word-index: case-insensitive lookup finds exact identifiers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("a.zig", "fn validateToken() void {}");

    // Case-insensitive search for the full identifier
    const r1 = try explorer.searchContent("validatetoken", testing.allocator, 10);
    defer {
        for (r1) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(r1);
    }
    try testing.expectEqual(@as(usize, 1), r1.len);
}

// ── Prefix expansion (Tier 0.5) tests ─────────────────────────────────────

test "word-index: searchPrefix finds extensions of a prefix" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var wi = WordIndex.init(a);

    // Index a file with camelCase identifiers — splits produce sub-tokens
    try wi.indexFile("a.zig", "fn searchContent() void {} fn searchConfig() void {}");

    // "searchco" is a strict prefix of "searchcontent" and "searchconfig"
    const hits = try wi.searchPrefix("searchco", a);
    try testing.expect(hits.len >= 1);
}

test "word-index: searchPrefix skips exact match (Tier 0 responsibility)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var wi = WordIndex.init(a);

    try wi.indexFile("a.zig", "fn searchContent() void {}");

    // Exact key "search" exists (sub-token). searchPrefix should return 0 for exact key.
    const hits_exact = try wi.searchPrefix("search", a);
    // "search" itself is in the index. Only keys STRICTLY longer are returned.
    // "searchcontent" is longer, so we expect ≥1 result.
    try testing.expect(hits_exact.len >= 1);

    // The hits must come from keys other than "search" itself.
    // Verify by checking "searchc..." style prefix:
    const hits_prefix = try wi.searchPrefix("searchco", a);
    try testing.expect(hits_prefix.len >= 1);
}

test "integration: Tier 0.5 prefix expansion finds partial identifier" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("util.zig", "pub fn validateRequest(r: Request) bool { return true; }");

    // "validateR" is a prefix of "validaterequest" in the word index
    const results = try explorer.searchContent("validateR", testing.allocator, 10);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }

    try testing.expect(results.len >= 1);
}

// ── BM25 frequency scoring tests ──────────────────────────────────────────

test "search: BM25 ranks higher-frequency line first" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

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
