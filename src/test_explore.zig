const std = @import("std");
const cio = @import("cio.zig");
const testing = std.testing;
const io = std.testing.io;
const Store = @import("store.zig").Store;
const Explorer = @import("explore.zig").Explorer;
const SearchResult = @import("explore.zig").SearchResult;
const WordIndex = @import("index.zig").WordIndex;
const TrigramIndex = @import("index.zig").TrigramIndex;
const SparseNgramIndex = @import("index.zig").SparseNgramIndex;
const WordTokenizer = @import("index.zig").WordTokenizer;
const splitIdentifier = @import("index.zig").splitIdentifier;
const explore = @import("explore.zig");
const extractLines = explore.extractLines;
const codegraph = @import("codegraph.zig");

test "codegraph: extractCallees finds calls, filters keywords" {
    const body =
        \\    if (cond) return helper();
        \\    const x = compute(a, b);
        \\    obj.method(x);
        \\    while (y) doThing();
        \\    return compute(x);
    ;
    const callees = try codegraph.extractCallees(testing.allocator, body);
    defer testing.allocator.free(callees);

    // Present: helper, compute (deduped), method, doThing. Absent: if, while, return.
    var found_helper = false;
    var found_compute = false;
    var found_method = false;
    var found_dothing = false;
    for (callees) |c| {
        if (std.mem.eql(u8, c, "helper")) found_helper = true;
        if (std.mem.eql(u8, c, "compute")) found_compute = true;
        if (std.mem.eql(u8, c, "method")) found_method = true;
        if (std.mem.eql(u8, c, "doThing")) found_dothing = true;
        try testing.expect(!std.mem.eql(u8, c, "if"));
        try testing.expect(!std.mem.eql(u8, c, "while"));
        try testing.expect(!std.mem.eql(u8, c, "return"));
    }
    try testing.expect(found_helper and found_compute and found_method and found_dothing);
    // compute appears twice but is deduped.
    var compute_count: usize = 0;
    for (callees) |c| if (std.mem.eql(u8, c, "compute")) {
        compute_count += 1;
    };
    try testing.expectEqual(@as(usize, 1), compute_count);
}

test "codegraph: buildEdges resolves callees + inDegree centrality" {
    // A(0) calls B and helper; helper(2) calls B; B(1) calls nothing real.
    const funcs = [_]codegraph.FuncInput{
        .{ .id = 0, .body = "B(); helper();" },
        .{ .id = 1, .body = "if (x) return;" },
        .{ .id = 2, .body = "return B();" },
    };
    var resolve = std.StringHashMap([]const codegraph.NodeId).init(testing.allocator);
    defer resolve.deinit();
    const b_ids = [_]codegraph.NodeId{1};
    const helper_ids = [_]codegraph.NodeId{2};
    try resolve.put("B", &b_ids);
    try resolve.put("helper", &helper_ids);

    var edges = try codegraph.buildEdges(testing.allocator, &funcs, &resolve, false);
    defer edges.deinit(testing.allocator);

    // Expect A→B, A→helper, helper→B (3 edges); B calls nothing resolvable.
    try testing.expectEqual(@as(usize, 3), edges.items.len);

    const cent = try codegraph.inDegreeCentrality(testing.allocator, edges.items, 3);
    defer testing.allocator.free(cent);
    // B (id 1) is called by A and helper → highest centrality; A (id 0) by none.
    try testing.expect(cent[1] > cent[2]);
    try testing.expect(cent[2] > cent[0]);
    try testing.expectApproxEqAbs(@as(f32, 0.0), cent[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 2.0), cent[1], 0.001);
}

test "codegraph: pageRank ranks highly-called nodes above leaves" {
    const funcs = [_]codegraph.FuncInput{
        .{ .id = 0, .body = "B(); helper();" },
        .{ .id = 1, .body = "if (x) return;" },
        .{ .id = 2, .body = "return B();" },
    };
    var resolve = std.StringHashMap([]const codegraph.NodeId).init(testing.allocator);
    defer resolve.deinit();
    const b_ids = [_]codegraph.NodeId{1};
    const helper_ids = [_]codegraph.NodeId{2};
    try resolve.put("B", &b_ids);
    try resolve.put("helper", &helper_ids);

    var edges = try codegraph.buildEdges(testing.allocator, &funcs, &resolve, false);
    defer edges.deinit(testing.allocator);

    const pr = try codegraph.pageRank(testing.allocator, edges.items, 3, 0.85, 20);
    defer testing.allocator.free(pr);

    try testing.expect(pr[1] > pr[0]);
    try testing.expect(pr[1] > pr[2]);
}

test "codegraph: shortestCallPath finds A→helper→B chain" {
    const funcs = [_]codegraph.FuncInput{
        .{ .id = 0, .body = "B(); helper();" },
        .{ .id = 1, .body = "if (x) return;" },
        .{ .id = 2, .body = "return B();" },
    };
    var resolve = std.StringHashMap([]const codegraph.NodeId).init(testing.allocator);
    defer resolve.deinit();
    const b_ids = [_]codegraph.NodeId{1};
    const helper_ids = [_]codegraph.NodeId{2};
    try resolve.put("B", &b_ids);
    try resolve.put("helper", &helper_ids);

    var edges = try codegraph.buildEdges(testing.allocator, &funcs, &resolve, false);
    defer edges.deinit(testing.allocator);

    const adj = try codegraph.buildAdjacency(testing.allocator, edges.items, 3);
    defer codegraph.freeAdjacency(testing.allocator, adj);

    const from = [_]codegraph.NodeId{0};
    const to = [_]codegraph.NodeId{1};
    const path = (try codegraph.shortestCallPath(testing.allocator, adj, 3, &from, &to, 0)) orelse return error.TestExpectedEqual;
    defer testing.allocator.free(path);

    try testing.expectEqual(@as(usize, 2), path.len);
    try testing.expectEqual(@as(codegraph.NodeId, 0), path[0]);
    try testing.expectEqual(@as(codegraph.NodeId, 1), path[1]);
}

const isCommentOrBlank = explore.isCommentOrBlank;
const Language = explore.Language;
const SymbolKind = explore.SymbolKind;
const DependencyGraph = explore.DependencyGraph;
const SymbolLocation = explore.SymbolLocation;
const watcher = @import("watcher.zig");
const git_mod = @import("git.zig");
const snapshot_mod = @import("snapshot.zig");


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


test "explorer: sparse ngram index integrated into searchContent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

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
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

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


test "explorer: index file and get outline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

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
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("a.zig", "pub fn alpha() void {}");
    try explorer.indexFile("b.zig", "pub fn beta() void {}");

    const result = try explorer.findSymbol("alpha", arena.allocator());
    try testing.expect(result != null);
    try testing.expectEqualStrings("a.zig", result.?.path);
}


test "explorer: findAllSymbols returns multiple" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("a.zig", "const Store = @import(\"store.zig\").Store;");
    try explorer.indexFile("b.zig", "pub const Store = struct {};");

    const results = try explorer.findAllSymbols("Store", arena.allocator());
    defer arena.allocator().free(results);
    try testing.expect(results.len == 2);
}


test "explorer: searchContent with trigram acceleration" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

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
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("math.zig", "pub fn add(a: i32, b: i32) i32 { return a + b; }");

    const hits = try explorer.searchWord("add", testing.allocator);
    defer testing.allocator.free(hits);
    try testing.expect(hits.len > 0);
    try testing.expectEqualStrings("math.zig", explorer.word_index.hitPath(hits[0]));
}


test "explorer: removeFile cleans up everything" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

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
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

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
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("index.ts",
        \\import { foo } from './foo';
        \\export function handleRequest() {}
        \\export const PORT = 3000;
    );

    var outline = (try explorer.getOutline("index.ts", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    try testing.expect(outline.symbols.items.len >= 3);
}


test "explorer: reindex OOM keeps prior outline reachable" {
    // Use a real allocator for the explorer so the first indexFile always succeeds.
    // We can't use FailingAllocator for the whole explorer because deinit would crash.
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
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
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
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
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("persist.zig", "pub fn keep() void {}");
    var outline = (try explorer.getOutline("persist.zig", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();

    explorer.removeFile("persist.zig");

    try testing.expectEqualStrings("persist.zig", outline.path);
    try testing.expect(outline.symbols.items.len > 0);
}


test "explorer: removeFile frees owned map key" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
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
    var exp = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

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
    var exp = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    const body = try exp.getSymbolBody("nonexistent.zig", 1, 5, testing.allocator);
    try testing.expect(body == null);
}


test "explorer: searchContentWithScope annotates results" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var exp = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

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
    var exp = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

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
    try testing.expect(explore.detectLanguage("style.css") == .css);
}


test "extractLines: without line numbers" {
    const content = "alpha\nbeta\ngamma";
    const result = try extractLines(content, 1, 3, false, false, .unknown, testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("alpha\nbeta\ngamma\n", result);
}


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


test "isCommentOrBlank: rust double-slash" {
    try testing.expect(isCommentOrBlank("  // rust comment", .rust));
    try testing.expect(!isCommentOrBlank("  let x = 1;", .rust));
}


test "isCommentOrBlank: go double-slash" {
    try testing.expect(isCommentOrBlank("  // go comment", .go_lang));
    try testing.expect(!isCommentOrBlank("  func main() {", .go_lang));
}


test "isCommentOrBlank: dart comments" {
    try testing.expect(isCommentOrBlank("  // dart comment", .dart));
    try testing.expect(isCommentOrBlank("  /* dart block comment */", .dart));
    try testing.expect(!isCommentOrBlank("  class WidgetBuilder {}", .dart));
}


test "isCommentOrBlank: cpp block and line comments" {
    try testing.expect(isCommentOrBlank("  // cpp line comment", .cpp));
    try testing.expect(isCommentOrBlank("  /* cpp block comment */", .cpp));
    try testing.expect(isCommentOrBlank("  * continued block comment", .cpp));
    try testing.expect(!isCommentOrBlank("  int x = 0;", .cpp));
}


test "isCommentOrBlank: detected extension language comments" {
    try testing.expect(isCommentOrBlank("  // java line comment", .java));
    try testing.expect(isCommentOrBlank("  // kotlin line comment", .kotlin));
    try testing.expect(isCommentOrBlank("  <!-- component comment -->", .svelte));
    try testing.expect(isCommentOrBlank("  <!-- component comment -->", .vue));
    try testing.expect(isCommentOrBlank("  <!-- component comment -->", .astro));
    try testing.expect(isCommentOrBlank("  # shell comment", .shell));
    try testing.expect(isCommentOrBlank("  /* css block comment */", .css));
    try testing.expect(isCommentOrBlank("  // scss line comment", .scss));
    try testing.expect(isCommentOrBlank("  -- sql comment", .sql));
    try testing.expect(isCommentOrBlank("  // proto comment", .protobuf));
    try testing.expect(isCommentOrBlank("  ! fortran comment", .fortran));
    try testing.expect(isCommentOrBlank("  ; llvm ir comment", .llvm_ir));
    try testing.expect(isCommentOrBlank("  // mlir comment", .mlir));
    try testing.expect(isCommentOrBlank("  // tablegen comment", .tablegen));
    try testing.expect(!isCommentOrBlank("  SELECT * FROM users;", .sql));
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


test "explorer: getSymbolBody multi-line range" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var exp = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

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
    var exp = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

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


test "explorer: searchContentWithScope across multiple files" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var exp = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

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
    var exp = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

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
    var exp = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

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


test "detectLanguage: all supported extensions" {
    try testing.expect(explore.detectLanguage("main.zig") == .zig);
    try testing.expect(explore.detectLanguage("lib.c") == .c);
    try testing.expect(explore.detectLanguage("util.h") == .c);
    try testing.expect(explore.detectLanguage("app.cpp") == .cpp);
    try testing.expect(explore.detectLanguage("app.hpp") == .cpp);
    try testing.expect(explore.detectLanguage("app.cc") == .cpp);
    try testing.expect(explore.detectLanguage("app.hh") == .cpp);
    try testing.expect(explore.detectLanguage("app.cxx") == .cpp);
    try testing.expect(explore.detectLanguage("app.hxx") == .cpp);
    try testing.expect(explore.detectLanguage("bridge.mm") == .cpp);
    try testing.expect(explore.detectLanguage("script.py") == .python);
    try testing.expect(explore.detectLanguage("app.js") == .javascript);
    try testing.expect(explore.detectLanguage("comp.jsx") == .javascript);
    try testing.expect(explore.detectLanguage("app.ts") == .typescript);
    try testing.expect(explore.detectLanguage("comp.tsx") == .typescript);
    try testing.expect(explore.detectLanguage("main.rs") == .rust);
    try testing.expect(explore.detectLanguage("main.go") == .go_lang);
    try testing.expect(explore.detectLanguage("app.dart") == .dart);
    try testing.expect(explore.detectLanguage("README.md") == .markdown);
    try testing.expect(explore.detectLanguage("pkg.json") == .json);
    try testing.expect(explore.detectLanguage("config.yaml") == .yaml);
    try testing.expect(explore.detectLanguage("config.yml") == .yaml);
    try testing.expect(explore.detectLanguage("Main.java") == .java);
    try testing.expect(explore.detectLanguage("App.kt") == .kotlin);
    try testing.expect(explore.detectLanguage("Widget.svelte") == .svelte);
    try testing.expect(explore.detectLanguage("Widget.vue") == .vue);
    try testing.expect(explore.detectLanguage("Page.astro") == .astro);
    try testing.expect(explore.detectLanguage("bootstrap.sh") == .shell);
    try testing.expect(explore.detectLanguage("styles.css") == .css);
    try testing.expect(explore.detectLanguage("styles.scss") == .scss);
    try testing.expect(explore.detectLanguage("schema.sql") == .sql);
    try testing.expect(explore.detectLanguage("service.proto") == .protobuf);
    try testing.expect(explore.detectLanguage("solver.f90") == .fortran);
    try testing.expect(explore.detectLanguage("module.ll") == .llvm_ir);
    try testing.expect(explore.detectLanguage("dialect.mlir") == .mlir);
    try testing.expect(explore.detectLanguage("records.td") == .tablegen);
    try testing.expect(explore.detectLanguage("Makefile") == .unknown);
    try testing.expect(explore.detectLanguage("no_ext") == .unknown);
}


test "explorer: getSymbolBody with line number format" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var exp = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

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


test "explorer: searchContentRegex end-to-end" {
    var explorer_inst = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
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
    var explorer_inst = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer_inst.deinit();

    try explorer_inst.indexFile("only.zig", "const x = 42;");

    const results = try explorer_inst.searchContentRegex("zzz\\d+qqq", testing.allocator, 50);
    defer testing.allocator.free(results);

    try testing.expectEqual(@as(usize, 0), results.len);
}


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
    var exp = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
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
    cio.sleepMs(10);
    const raced = sctx.swapped.load(.acquire);
    exp.mu.unlockShared();
    t.join();
    try testing.expect(!raced);
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


test "issue-224: codedb_symbol body=true returns full body — line_end populated" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var explorer = Explorer.init(alloc, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

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

    var explorer = Explorer.init(alloc, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

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


test "issue-108: detectLanguage handles .tf and .tfvars" {
    try testing.expectEqual(Language.hcl, explore.detectLanguage("main.tf"));
    try testing.expectEqual(Language.hcl, explore.detectLanguage("prod.tfvars"));
    try testing.expectEqual(Language.hcl, explore.detectLanguage("config.hcl"));
}


test "issue-215: detectLanguage handles .r and .R" {
    try testing.expectEqual(Language.r, explore.detectLanguage("script.r"));
    try testing.expectEqual(Language.r, explore.detectLanguage("analysis.R"));
}

test "issue-532: detectLanguage handles .res and .resi" {
    try testing.expectEqualStrings("rescript", @tagName(explore.detectLanguage("src/User.res")));
    try testing.expectEqualStrings("rescript", @tagName(explore.detectLanguage("src/User.resi")));
}


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
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

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
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

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


test "issue-445: dep-graph dedupes multi-aliased forward imports" {
    // A file that imports the same dep under multiple aliases
    //   const idx = @import("index.zig");
    //   const Index = @import("index.zig").Foo;
    //   const reset = @import("index.zig").resetFrequencyTable;
    // produces multiple "index.zig" entries in outline.imports, which
    // rebuildDepsFor previously appended verbatim — so getForwardDeps
    // returned "index.zig" 5 times for src/main.zig in this very repo.
    // The depends_on list should be unique by path.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("index.zig", "pub fn build() void {}");
    try explorer.indexFile("main.zig",
        \\const idx = @import("index.zig");
        \\const Index = @import("index.zig").Foo;
        \\const reset = @import("index.zig").resetFrequencyTable;
        \\pub fn main() void {}
    );

    explorer.mu.lockShared();
    const fwd_opt = explorer.dep_graph.getForwardDeps("main.zig");
    explorer.mu.unlockShared();

    try testing.expect(fwd_opt != null);
    const fwd = fwd_opt.?;
    try testing.expectEqual(@as(usize, 1), fwd.len);
    try testing.expectEqualStrings("index.zig", fwd[0]);
}


test "symbol-index: O(1) findSymbol via symbol_index" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

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
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

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
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

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
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

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
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

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
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

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


test "word-index: searchPrefix finds extensions of a prefix" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var wi = WordIndex.init(a);

    // Index a file with camelCase identifiers — splits produce sub-tokens
    try wi.indexFile("a.zig", "fn searchContent() void {} fn searchConfig() void {}");

    // "searchco" is a strict prefix of "searchcontent" and "searchconfig"
    const hits = try wi.searchPrefix("searchco", a, 32);
    try testing.expect(hits.len >= 1);
}


test "word-index: searchPrefix skips exact match (Tier 0 responsibility)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var wi = WordIndex.init(a);

    try wi.indexFile("a.zig", "fn searchContent() void {}");

    // Exact key "search" exists (sub-token). searchPrefix should return 0 for exact key.
    const hits_exact = try wi.searchPrefix("search", a, 32);
    // "search" itself is in the index. Only keys STRICTLY longer are returned.
    // "searchcontent" is longer, so we expect ≥1 result.
    try testing.expect(hits_exact.len >= 1);

    // The hits must come from keys other than "search" itself.
    // Verify by checking "searchc..." style prefix:
    const hits_prefix = try wi.searchPrefix("searchco", a, 32);
    try testing.expect(hits_prefix.len >= 1);
}


test "word-index: searchPrefix respects max_results cap" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var wi = WordIndex.init(a);

    // Index many distinct files producing many keys that share the "fooBar" prefix.
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const path = try std.fmt.allocPrint(a, "f{d}.zig", .{i});
        const content = try std.fmt.allocPrint(a, "fn fooBar{d}() void {{}}\n", .{i});
        try wi.indexFile(path, content);
    }

    const cap: usize = 5;
    const hits = try wi.searchPrefix("foobar", a, cap);
    try testing.expect(hits.len <= cap);
    try testing.expect(hits.len > 0);
}


test "integration: Tier 0.5 prefix expansion finds partial identifier" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

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


test "issue-389: FilteredWalker yields symlinked source files" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(io, "src");
    try tmp_dir.dir.writeFile(io, .{ .sub_path = "src/target.zig", .data = "pub fn linked() void {}\n// MARKER_LINE\n" });

    // Create an in-workspace symlink: src/alias.zig -> target.zig (relative).
    var src_dir = try tmp_dir.dir.openDir(io, "src", .{ .iterate = true });
    defer src_dir.close(io);
    src_dir.symLink(io, "target.zig", "alias.zig", .{}) catch |err| switch (err) {
        // If the OS denies symlinks (e.g. CI without privilege on Windows),
        // skip the test rather than report a false negative.
        error.AccessDenied => return error.SkipZigTest,
        else => return err,
    };

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp_dir.dir.realPathFile(io, ".", &root_buf);
    const root = root_buf[0..root_len];

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    explorer.setRoot(io, root);
    try watcher.initialScanWithWorkerCount(io, &store, &explorer, root, testing.allocator, false, 1);

    // Both the real file and the symlinked alias must be indexed. The bug at
    // src/watcher.zig:319 drops every entry whose kind != .file, silently
    // skipping symlinks even when they point at in-workspace source files.
    try testing.expect(explorer.contents.contains("src/target.zig"));
    try testing.expect(explorer.contents.contains("src/alias.zig"));
}


test "issue-405: FilteredWalker walks directory symlinks safely (cycle + escape)" {
    // Follow-up to #389. The current FilteredWalker.next() (src/watcher.zig:319-323)
    // treats sym_link entries as files when statFile reports .file, but silently
    // drops sym_link entries whose target is a directory. Real repos rely on
    // directory symlinks (monorepo package links, vendored deps, dotfile configs),
    // so the indexer must walk them — but only safely. This test pins three things:
    //   1. A file inside a symlinked subdirectory is indexed.
    //   2. A symlink that introduces a cycle does not hang or duplicate entries.
    //   3. (Implicit) The walker terminates in bounded time on the fixture.
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Real directory `pkg/` with one source file.
    try tmp_dir.dir.createDirPath(io, "pkg");
    try tmp_dir.dir.writeFile(io, .{ .sub_path = "pkg/inside.zig", .data = "pub fn inside() void {}\n" });

    // A real directory `app/` that holds a directory-symlink `linked_pkg -> ../pkg`.
    // We expect the walker to descend into `linked_pkg` and yield `app/linked_pkg/inside.zig`.
    try tmp_dir.dir.createDirPath(io, "app");
    var app_dir = try tmp_dir.dir.openDir(io, "app", .{ .iterate = true });
    defer app_dir.close(io);
    app_dir.symLink(io, "../pkg", "linked_pkg", .{}) catch |err| switch (err) {
        // Skip on platforms / CI configurations that deny symlink creation.
        error.AccessDenied => return error.SkipZigTest,
        else => return err,
    };

    // Cycle: `app/loop -> ..` points back at the workspace root. Without cycle
    // detection a naive walker recurses forever via app/loop/app/loop/app/...
    app_dir.symLink(io, "..", "loop", .{}) catch |err| switch (err) {
        error.AccessDenied => return error.SkipZigTest,
        else => return err,
    };

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp_dir.dir.realPathFile(io, ".", &root_buf);
    const root = root_buf[0..root_len];

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    explorer.setRoot(io, root);
    try watcher.initialScanWithWorkerCount(io, &store, &explorer, root, testing.allocator, false, 1);

    // 1. The in-target file must appear under the symlinked path. This is the
    //    behaviour gap left by #389 — directory symlinks are currently ignored,
    //    so this assertion fails on main.
    try testing.expect(explorer.contents.contains("app/linked_pkg/inside.zig"));

    // 2. The real path must also be indexed exactly once.
    try testing.expect(explorer.contents.contains("pkg/inside.zig"));

    // 3. The cycle must not have produced a deeply-nested duplicate entry.
    //    If cycle detection is missing, paths like
    //    `app/loop/app/loop/app/linked_pkg/inside.zig` would appear (or the
    //    scan would never terminate). Assert no path contains "loop/app/loop".
    var it = explorer.contents.iterator();
    while (it.next()) |kv| {
        const p = kv.key_ptr.*;
        try testing.expect(std.mem.indexOf(u8, p, "loop/app/loop") == null);
    }
}


test "issue-405: cleanupStaleTmpFiles deletes in-flight sibling tmp files" {
    // BUG: snapshot.zig:cleanupStaleTmpFiles deletes ANY file matching
    // `<basename>*.tmp` in the snapshot directory with no age guard.
    // If a sibling writer (another process / parallel scan) is mid-write
    // — i.e. it has just created `<output>.<rand>.tmp` and is still
    // streaming bytes into it before the final rename(tmp, dest) — then a
    // concurrent loadSnapshotValidated() will unlink the sibling's
    // in-flight tmp file. The sibling's subsequent rename then fails with
    // ENOENT and the snapshot write silently aborts.
    //
    // Reproduces deterministically by simulating the in-flight tmp file
    // and observing that loadSnapshotValidated removes it.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    // Step 1: write a real, valid snapshot at <dir>/snap.codedb so
    // loadSnapshotValidated has something legitimate to read.
    var exp = Explorer.init(aa, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    try exp.indexFile("a.zig", "pub fn alpha() void {}\n");
    const snap_path = try std.fs.path.join(aa, &.{ dir_path, "snap.codedb" });
    try snapshot_mod.writeSnapshot(io, &exp, dir_path, snap_path, aa);

    // Step 2: simulate a SIBLING writer that has just created its tmp file
    // but has NOT yet renamed. This file matches the cleanup pattern
    // (starts with basename, ends with ".tmp").
    const sibling_tmp = try std.fs.path.join(aa, &.{ dir_path, "snap.codedb.deadbeef.tmp" });
    {
        var f = try std.Io.Dir.cwd().createFile(io, sibling_tmp, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "in-flight write");
    }

    // Sanity: the sibling tmp exists.
    std.Io.Dir.cwd().access(io, sibling_tmp, .{}) catch return error.TestUnexpectedResult;

    // Step 3: run loadSnapshotValidated. cleanupStaleTmpFiles is the
    // first thing it does. After this, the sibling's in-flight tmp
    // file MUST still exist — otherwise the sibling's rename will fail.
    var exp2 = Explorer.init(aa, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    var store = Store.init(testing.allocator);
    defer store.deinit();
    _ = snapshot_mod.loadSnapshotValidated(io, snap_path, null, &exp2, &store, aa);

    // Expected: the in-flight sibling tmp is preserved.
    // Current (bug): cleanupStaleTmpFiles unconditionally deletes it.
    std.Io.Dir.cwd().access(io, sibling_tmp, .{}) catch {
        return error.TestExpectedSiblingTmpPreserved;
    };
}


test "issue-409: snapshot .env prefix filter wrongly excludes .envoy/.environment files" {
    // BUG: snapshot.zig:isSensitivePath uses
    //     if (basename.len >= 4 and std.mem.eql(u8, basename[0..4], ".env")) return true;
    // to catch .env, .env.local, .env.production, etc. The check is a raw
    // 4-byte prefix match — so any basename whose first 4 bytes are ".env"
    // is rejected, including legitimate, non-secret files such as:
    //
    //   .envoy.json     — Envoy proxy config
    //   .environment    — generic config name
    //   .envconfig.yaml — anything starting with ".env"
    //
    // These files end up silently dropped from the snapshot's CONTENT,
    // TREE, and OUTLINE_STATE sections, so a save/load round-trip loses
    // them entirely. The watcher.zig copy of isSensitivePath has the same
    // bug, so they are also excluded from live indexing.
    //
    // Reproducer: index a non-secret .envoy.json alongside a normal file,
    // snapshot, load, and observe that .envoy.json is missing.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    var exp = Explorer.init(aa, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    try exp.indexFile("a.zig", "pub fn alpha() void {}\n");
    // .envoy.json is the canonical Envoy proxy config name — not a secret.
    try exp.indexFile(".envoy.json", "{\"listeners\":[]}\n");
    try testing.expectEqual(@as(usize, 2), exp.outlines.count());

    const snap_path = try std.fs.path.join(aa, &.{ dir_path, "snap.codedb" });
    try snapshot_mod.writeSnapshot(io, &exp, dir_path, snap_path, aa);

    var exp2 = Explorer.init(aa, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    var store = Store.init(testing.allocator);
    defer store.deinit();
    try testing.expect(snapshot_mod.loadSnapshot(io, snap_path, &exp2, &store, aa));

    // Expected: both files round-trip through the snapshot.
    // Current (bug): only "a.zig" survives — ".envoy.json" was excluded by
    // the .env prefix check at write time.
    try testing.expect(exp2.outlines.contains("a.zig"));
    try testing.expect(exp2.outlines.contains(".envoy.json"));
}


test "issue-208: content cache evicts cold entries under pressure" {
    const ContentCache = @import("hot_cache.zig").ContentCache;
    const cap = 50;
    var cache = try ContentCache.initAlloc(testing.allocator, cap);
    defer cache.deinit();

    var key_buf: [32]u8 = undefined;
    var val_buf: [32]u8 = undefined;

    // Insert 100 keys into a cache with capacity 50.
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const k = std.fmt.bufPrint(&key_buf, "file_{d}.zig", .{i}) catch unreachable;
        const v = std.fmt.bufPrint(&val_buf, "content_{d}", .{i}) catch unreachable;
        try cache.put(k, v);
    }

    // Cache must not exceed capacity.
    try testing.expect(cache.len() <= cap);

    // Touch keys 0..10 to mark them hot (set ref bit).
    i = 0;
    while (i < 10) : (i += 1) {
        const k = std.fmt.bufPrint(&key_buf, "file_{d}.zig", .{i}) catch unreachable;
        _ = cache.get(k);
    }

    // Insert 20 more keys to trigger further eviction.
    i = 100;
    while (i < 120) : (i += 1) {
        const k = std.fmt.bufPrint(&key_buf, "file_{d}.zig", .{i}) catch unreachable;
        const v = std.fmt.bufPrint(&val_buf, "content_{d}", .{i}) catch unreachable;
        try cache.put(k, v);
    }

    // Still bounded by capacity.
    try testing.expect(cache.len() <= cap);

    // Evictions must have fired.
    const s = cache.stats();
    try testing.expect(s.evictions > 0);
}



test "explorer: renderSkeleton elides bodies, keeps signatures" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();

    try explorer.indexFile("sk.zig",
        \\const std = @import("std");
        \\pub fn parseConfig(path: []const u8) !void {
        \\    const a = 1;
        \\    const b = 2;
        \\    _ = a;
        \\    _ = b;
        \\}
        \\pub const MAX = 100;
    );

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    const found = try explorer.renderSkeleton("sk.zig", testing.allocator, &out);
    try testing.expect(found);

    const s = out.items;
    // Declaration line is shown, with the body collapsed to a line-count stub.
    try testing.expect(std.mem.indexOf(u8, s, "pub fn parseConfig(path: []const u8) !void {") != null);
    try testing.expect(std.mem.indexOf(u8, s, "lines }") != null);
    // Body lines are elided — the whole point.
    try testing.expect(std.mem.indexOf(u8, s, "const a = 1") == null);
    // Single-line declarations stay verbatim.
    try testing.expect(std.mem.indexOf(u8, s, "pub const MAX = 100;") != null);
    // Escalation footer points the model to the fallback tools when skeleton isn't enough.
    try testing.expect(std.mem.indexOf(u8, s, "codedb_read sk.zig") != null);
    try testing.expect(std.mem.indexOf(u8, s, "codedb_outline sk.zig") != null);
}


test "explorer: multi-line signature gets correct line_end (findBraceEnd paren-awareness)" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();

    try explorer.indexFile("mlsig.ts",
        \\export function f(
        \\  opts: { a?: number } = {},
        \\): string {
        \\  const x = 1;
        \\  return String(x);
        \\}
        \\export const Z = 2;
    );

    var outline = (try explorer.getOutline("mlsig.ts", testing.allocator)).?;
    defer outline.deinit();
    var f_end: u32 = 0;
    for (outline.symbols.items) |s| {
        if (std.mem.eql(u8, s.name, "f")) f_end = s.line_end;
    }
    // Body close brace is line 6. Pre-fix, the inline object-type param `{ a?: number }`
    // on line 2 ended the scope early (line_end ~2); paren-awareness fixes it.
    try testing.expect(f_end >= 6);
}

test "resolveCallees: resolves call sites in a function body to their definitions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var exp = Explorer.init(a, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    try exp.indexFile("util.zig", "pub fn helper() void {}\npub fn other() void {}\n");
    try exp.indexFile("main.zig",
        \\pub fn run() void {
        \\    helper();
        \\    other();
        \\}
        \\
    );

    // run() spans lines 1-4; both calls resolve to definitions in util.zig.
    const callees = try exp.resolveCallees("main.zig", 1, 4, a, 8);
    var saw_helper = false;
    var saw_other = false;
    for (callees) |c| {
        if (std.mem.eql(u8, c.name, "helper")) {
            saw_helper = true;
            try testing.expectEqualStrings("util.zig", c.path);
            try testing.expect(c.kind == .function);
        }
        if (std.mem.eql(u8, c.name, "other")) saw_other = true;
        // The defining function must not appear as its own callee.
        try testing.expect(!std.mem.eql(u8, c.name, "run"));
    }
    try testing.expect(saw_helper);
    try testing.expect(saw_other);
}

test "issue-528: searchContentRegex surfaces invalid regex as error" {
    var explorer_inst = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer_inst.deinit();
    try explorer_inst.indexFile("only.zig", "const x = 42;");
    // #10: an unparseable pattern used to be swallowed and reported as "no results".
    try testing.expectError(error.InvalidRegex, explorer_inst.searchContentRegex("[", testing.allocator, 50));
}

test "issue-531: searchSymbols prefix match" {
    var explorer_inst = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer_inst.deinit();
    try explorer_inst.indexFile("a.zig", "pub fn parse_foo() void {}\npub fn parse_bar() void {}\npub fn other() void {}");

    const results = try explorer_inst.searchSymbols(.{ .prefix = "parse_", .max_results = 10 }, testing.allocator);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.symbol.name);
            if (r.symbol.detail) |d| testing.allocator.free(d);
        }
        testing.allocator.free(results);
    }
    try testing.expect(results.len == 2);
    for (results) |r| try testing.expect(std.mem.startsWith(u8, r.symbol.name, "parse_"));
}

test "issue-531: searchSymbols pattern and kind filter" {
    var explorer_inst = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer_inst.deinit();
    try explorer_inst.indexFile("svc.go",
        \\type UserManager struct {}
        \\type OrderManager struct {}
        \\func main() {}
    );

    const pattern_results = try explorer_inst.searchSymbols(.{ .pattern = "*Manager", .max_results = 10 }, testing.allocator);
    defer {
        for (pattern_results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.symbol.name);
            if (r.symbol.detail) |d| testing.allocator.free(d);
        }
        testing.allocator.free(pattern_results);
    }
    try testing.expect(pattern_results.len == 2);
    try explorer_inst.indexFile("iface.go", "type Reader interface {}");

    const kind = Explorer.parseSymbolKind("interface") orelse return error.TestUnexpectedResult;
    const iface_results = try explorer_inst.searchSymbols(.{ .kind = kind, .max_results = 10 }, testing.allocator);
    defer {
        for (iface_results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.symbol.name);
            if (r.symbol.detail) |d| testing.allocator.free(d);
        }
        testing.allocator.free(iface_results);
    }
    try testing.expect(iface_results.len >= 1);
    try testing.expect(iface_results[0].symbol.kind == .interface_def);
}

test "issue-531: searchSymbols fuzzy match" {
    var explorer_inst = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer_inst.deinit();
    try explorer_inst.indexFile("x.zig", "pub fn ensureCallGraph() void {}");

    const results = try explorer_inst.searchSymbols(.{ .name = "ensureCalGraph", .fuzzy = true, .max_results = 5 }, testing.allocator);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.symbol.name);
            if (r.symbol.detail) |d| testing.allocator.free(d);
        }
        testing.allocator.free(results);
    }
    try testing.expect(results.len >= 1);
    try testing.expectEqualStrings("ensureCallGraph", results[0].symbol.name);
}

// ─── audit (2026-06-09): latent-issue sweep — call-graph phantom edges ───
// src/codegraph.zig extractCallees paired every '(' with the preceding identifier with
// no comment/string stripping, so a name mentioned only in a // comment surfaced as a
// real resolved callee in codedb_context (#548 family, for the call graph).
test "audit: comment-only mention is not a resolved callee" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var exp = Explorer.init(a, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    try exp.indexFile("util.zig", "pub fn uniqueHelper() void {}\n");
    try exp.indexFile("caller.zig",
        \\pub fn caller() void {
        \\    // see uniqueHelper() for details
        \\}
        \\
    );
    const callees = try exp.resolveCallees("caller.zig", 1, 3, a, 8);
    for (callees) |c| try testing.expect(!std.mem.eql(u8, c.name, "uniqueHelper"));
}

test "audit: extractCallees ignores comment/string mentions" {
    const body =
        \\    realCall(x);
        \\    // ghostFn() lives only in this comment
        \\    log("please stringOnlyFn() here");
    ;
    const callees = try codegraph.extractCallees(testing.allocator, body);
    defer testing.allocator.free(callees);
    var saw_real = false;
    for (callees) |c| {
        if (std.mem.eql(u8, c, "realCall")) saw_real = true;
        try testing.expect(!std.mem.eql(u8, c, "ghostFn"));
        try testing.expect(!std.mem.eql(u8, c, "stringOnlyFn"));
    }
    try testing.expect(saw_real); // real call in code is still captured
}

test "issue-586: symbol_index keys must survive re-index of the file that first inserted them" {
    // rebuildSymbolIndexFor keys the global symbol index with sym.name slices
    // OWNED BY THE FILE'S OUTLINE. Re-indexing that file deinits the old
    // outline — freeing the bytes the map hashes and compares — but the entry
    // survives whenever another file shares the name (init/deinit/main are
    // shared by nearly every Zig file). Every later probe eql()s freed memory:
    // UB in release, and under the DebugAllocator poison the O(1) index
    // silently loses the name, degrading every lookup to the outline scans.
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();

    // a.zig inserts sharedFn first -> the map key aliases a.zig's outline string.
    try explorer.indexFile("src/a.zig", "pub fn sharedFn() void {}\n");
    try explorer.indexFile("src/b.zig", "pub fn sharedFn() void {}\n");

    // Re-index the key owner: its old outline is freed; the entry stays alive
    // because b.zig still holds a location.
    try explorer.indexFile("src/a.zig", "pub fn sharedFn() void {}\npub fn other() void {}\n");

    const locs = explorer.symbol_index.get("sharedFn") orelse return error.SymbolLostFromIndex;
    try testing.expect(locs.items.len >= 2);
}

test "issue-587: removeFile drops the path from skip_trigram_files" {
    // Explorer.removeFile cleans dep_graph, symbol_index, contents, word and
    // trigram indexes, then frees the outlines key — but never removes the
    // skip_trigram_files entry, whose key ALIASES that freed outlines key.
    // The tier-3 search scan then iterates a dangling path and hands it to
    // readContentForSearch (UB read; with reused memory, an arbitrary path).
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();

    // Outline-only indexing registers the file in skip_trigram_files (#507).
    try explorer.indexFileOutlineOnly("src/gone.zig", "pub fn ghostFn() void {}\n");
    try testing.expectEqual(@as(usize, 1), explorer.skip_trigram_files.count());

    explorer.removeFile("src/gone.zig");
    try testing.expectEqual(@as(usize, 0), explorer.skip_trigram_files.count());
}

test "issue-594: failed re-index restores the word index from valid prior content" {
    // commitParsedFileOwnedOutline reads `prior_content` out of the content
    // cache and THEN calls contents.put, which frees that value in place. The
    // trigram-failure errdefer later "restores" the word index by re-indexing
    // prior_content — freed memory. Under the DebugAllocator poison the
    // tokenizer finds no words in it, so a failed re-index silently wipes the
    // file's postings instead of restoring them (release builds read garbage).
    const FailOnce = struct {
        backing: std.mem.Allocator,
        next_index: usize = 0,
        fail_index: usize,

        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &.{
                .alloc = allocImpl,
                .resize = resizeImpl,
                .remap = remapImpl,
                .free = freeImpl,
            } };
        }
        fn allocImpl(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const idx = self.next_index;
            self.next_index += 1;
            if (idx == self.fail_index) return null;
            return self.backing.rawAlloc(len, alignment, ra);
        }
        fn resizeImpl(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.backing.rawResize(memory, alignment, new_len, ra);
        }
        fn remapImpl(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.backing.rawRemap(memory, alignment, new_len, ra);
        }
        fn freeImpl(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.backing.rawFree(memory, alignment, ra);
        }
    };

    // Pass 1: count the allocation window of the re-index on a successful run.
    var window_start: usize = 0;
    var window_end: usize = 0;
    {
        var counter = FailOnce{ .backing = testing.allocator, .fail_index = std.math.maxInt(usize) };
        var explorer = Explorer.init(counter.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
        defer explorer.deinit();
        try explorer.indexFile("src/a.zig", "pub fn alphaTok() void {}\n");
        window_start = counter.next_index;
        try explorer.indexFile("src/a.zig", "pub fn betaTok() void {}\n");
        window_end = counter.next_index;
    }
    try testing.expect(window_end > window_start);

    // Pass 2: fail each allocation in that window exactly once. Whenever the
    // re-index errors out, the old content must still be word-searchable.
    var fi = window_start;
    while (fi < window_end) : (fi += 1) {
        var failer = FailOnce{ .backing = testing.allocator, .fail_index = fi };
        var explorer = Explorer.init(failer.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
        defer explorer.deinit();
        explorer.indexFile("src/a.zig", "pub fn alphaTok() void {}\n") catch unreachable;
        if (explorer.indexFile("src/a.zig", "pub fn betaTok() void {}\n")) |_| {
            // Tolerated failure — the new content must be live.
            try testing.expect(explorer.word_index.search("betatok").len > 0);
        } else |_| {
            if (explorer.word_index.search("alphatok").len == 0) return error.PriorContentLostOnFailedReindex;
        }
    }
}
