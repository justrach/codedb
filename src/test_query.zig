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
const explore = @import("explore.zig");
const Language = explore.Language;
const SymbolKind = explore.SymbolKind;
const mcp_mod = @import("mcp.zig");


const fuzzyScore = @import("explore.zig").fuzzyScore;
const AgentRegistry = @import("agent.zig").AgentRegistry;
const edit_mod = @import("edit.zig");


test "issue-360: edit rejects mismatched if_hash and leaves file untouched" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const rel_path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/edit-if-hash.txt", .{tmp.sub_path});
    defer testing.allocator.free(rel_path);

    const original = "line 1\nline 2\nline 3\n";
    var file = try tmp.dir.createFile(io, "edit-if-hash.txt", .{});
    defer file.close(io);
    try file.writeStreamingAll(io, original);

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    const agent_id = try agents.register("issue-360-agent");

    // A hash value that cannot match any real file content (caller saw a stale read)
    try testing.expectError(error.HashMismatch, edit_mod.applyEdit(io, testing.allocator, &store, &agents, null, .{
        .path = rel_path,
        .agent_id = agent_id,
        .op = .replace,
        .range = .{ 1, 1 },
        .content = "stale-line edit",
        .if_hash = "deadbeef",
    }));

    // File on disk must be unchanged after the rejected edit
    const after_bytes = try std.Io.Dir.cwd().readFileAlloc(io, rel_path, testing.allocator, .limited(10 * 1024));
    defer testing.allocator.free(after_bytes);
    try testing.expectEqualStrings(original, after_bytes);
}


test "issue-360: edit response reports hex hash matching codedb_read" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const rel_path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/edit-hex.txt", .{tmp.sub_path});
    defer testing.allocator.free(rel_path);

    const original = "alpha\nbeta\ngamma\n";
    var file = try tmp.dir.createFile(io, "edit-hex.txt", .{});
    defer file.close(io);
    try file.writeStreamingAll(io, original);

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    const agent_id = try agents.register("issue-360-hex-agent");

    const result = try edit_mod.applyEdit(io, testing.allocator, &store, &agents, null, .{
        .path = rel_path,
        .agent_id = agent_id,
        .op = .replace,
        .range = .{ 2, 2 },
        .content = "BETA",
    });

    // Hash returned matches Wyhash of the new content, hex-formatted same as codedb_read
    const new_bytes = try std.Io.Dir.cwd().readFileAlloc(io, rel_path, testing.allocator, .limited(10 * 1024));
    defer testing.allocator.free(new_bytes);
    const expected_hash = std.hash.Wyhash.hash(0, new_bytes);
    try testing.expectEqual(expected_hash, result.new_hash);
}


test "issue-360: edit dry_run returns diff preview and leaves file untouched" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const rel_path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/edit-dry.txt", .{tmp.sub_path});
    defer testing.allocator.free(rel_path);

    const original = "alpha\nbeta\ngamma\n";
    var file = try tmp.dir.createFile(io, "edit-dry.txt", .{});
    defer file.close(io);
    try file.writeStreamingAll(io, original);

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    const agent_id = try agents.register("issue-360-dry-agent");

    const result = try edit_mod.applyEdit(io, testing.allocator, &store, &agents, null, .{
        .path = rel_path,
        .agent_id = agent_id,
        .op = .replace,
        .range = .{ 2, 2 },
        .content = "BETA",
        .dry_run = true,
    });
    defer if (result.preview) |p| testing.allocator.free(p);

    // File on disk is untouched.
    const after_bytes = try std.Io.Dir.cwd().readFileAlloc(io, rel_path, testing.allocator, .limited(10 * 1024));
    defer testing.allocator.free(after_bytes);
    try testing.expectEqualStrings(original, after_bytes);

    // Store unchanged.
    try testing.expectEqual(@as(u64, 0), store.currentSeq());

    // seq=0 indicates not committed; new_hash is the would-be hash.
    try testing.expectEqual(@as(u64, 0), result.seq);

    // Preview shows both the removed and the added line.
    try testing.expect(result.preview != null);
    const preview = result.preview.?;
    try testing.expect(std.mem.indexOf(u8, preview, "-beta") != null);
    try testing.expect(std.mem.indexOf(u8, preview, "+BETA") != null);
}


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

test "issue-518: fuzzy find has a subsequence floor — garbage queries return null" {
    // Long queries whose characters only incidentally overlap a path must not
    // score as confident hits. Before the LCS-ratio floor, the local alignment
    // let a few stray filename matches clear the threshold, so codedb_find
    // returned ranked results for queries that match no filename.
    try testing.expect(fuzzyScore("zzznosuchfilexyz", "notrail.py") == null);
    try testing.expect(fuzzyScore("Widget", "empty.py") == null);
    // Typo-tolerant matches that share most of the query in order still score.
    try testing.expect(fuzzyScore("authmid", "src/auth_middleware.py") != null);
    try testing.expect(fuzzyScore("mian", "src/main.zig") != null);
    try testing.expect(fuzzyScore("auth_midlware", "src/auth_middleware.py") != null);
}


test "issue-163: fuzzyFindFiles via Explorer" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
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
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
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
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
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


test "issue-168: query pipeline find → limit produces file set" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
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
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
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
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
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
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();

    try explorer.indexFile("src/main.zig", "pub fn main() void {}\npub fn helper() void {}\n");

    var outline = (try explorer.getOutline("src/main.zig", testing.allocator)).?;
    defer outline.deinit();
    try testing.expect(outline.symbols.items.len >= 2);
}


test "issue-168: query pipeline chained find → filter narrows results" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
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
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();

    try explorer.indexFile("src/main.zig", "pub fn main() void {}");

    // Search for something that doesn't exist
    const results = try explorer.fuzzyFindFiles("zzzznonexistent", testing.allocator, 10);
    defer testing.allocator.free(results);
    try testing.expectEqual(@as(usize, 0), results.len);
}


test "issue-168: recall — find + filter preserves only matching extension" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
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
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
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
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
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
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
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
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
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


test "auto-retry: delimiter stripping finds results" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();

    try explorer.indexFile("src/auth_middleware.py", "def check(): pass");

    // "authmiddleware" without delimiters should still find auth_middleware
    const results = try explorer.fuzzyFindFiles("authmiddleware", testing.allocator, 10);
    defer testing.allocator.free(results);
    try testing.expect(results.len >= 1);
    try testing.expect(std.mem.indexOf(u8, results[0].path, "auth_middleware") != null);
}


test "per-file truncation: max 5 matches per file in output" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
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


test "issue-359: globPaths matches files by glob pattern" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();

    try explorer.indexFile("src/mcp.zig", "pub fn a() void {}");
    try explorer.indexFile("src/explore.zig", "pub fn b() void {}");
    try explorer.indexFile("src/sub/inner.zig", "pub fn c() void {}");
    try explorer.indexFile("tests/test_main.py", "def t(): pass");
    try explorer.indexFile("README.md", "# readme");

    // ** matches across path separators
    const zigs = try explorer.globPaths(testing.allocator, "src/**/*.zig", 100);
    defer testing.allocator.free(zigs);
    try testing.expectEqual(@as(usize, 3), zigs.len);

    // single * does not cross path separators
    const top_zigs = try explorer.globPaths(testing.allocator, "src/*.zig", 100);
    defer testing.allocator.free(top_zigs);
    try testing.expectEqual(@as(usize, 2), top_zigs.len);

    // top-level extension match
    const md = try explorer.globPaths(testing.allocator, "*.md", 100);
    defer testing.allocator.free(md);
    try testing.expectEqual(@as(usize, 1), md.len);
    try testing.expectEqualStrings("README.md", md[0]);

    // results are sorted
    const all_zigs = try explorer.globPaths(testing.allocator, "**/*.zig", 100);
    defer testing.allocator.free(all_zigs);
    try testing.expect(all_zigs.len >= 2);
    var i: usize = 1;
    while (i < all_zigs.len) : (i += 1) {
        try testing.expect(std.mem.order(u8, all_zigs[i - 1], all_zigs[i]) == .lt);
    }
}


test "issue-359: lsDir returns immediate children with file metadata" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();

    try explorer.indexFile("src/mcp.zig", "pub fn a() void {}");
    try explorer.indexFile("src/explore.zig", "pub fn b() void {}");
    try explorer.indexFile("src/sub/inner.zig", "pub fn c() void {}");
    try explorer.indexFile("tests/test_main.py", "def t(): pass");
    try explorer.indexFile("README.md", "# readme");

    // Top-level: 1 file (README.md) + 2 dirs (src/, tests/)
    const top = try explorer.lsDir(testing.allocator, "");
    defer testing.allocator.free(top);
    try testing.expectEqual(@as(usize, 3), top.len);

    var saw_readme = false;
    var saw_src_dir = false;
    var saw_tests_dir = false;
    for (top) |e| {
        if (std.mem.eql(u8, e.name, "README.md")) {
            try testing.expect(!e.is_dir);
            saw_readme = true;
        }
        if (std.mem.eql(u8, e.name, "src")) {
            try testing.expect(e.is_dir);
            saw_src_dir = true;
        }
        if (std.mem.eql(u8, e.name, "tests")) {
            try testing.expect(e.is_dir);
            saw_tests_dir = true;
        }
    }
    try testing.expect(saw_readme and saw_src_dir and saw_tests_dir);

    // Inside src/: 2 files (mcp.zig, explore.zig) + 1 dir (sub/)
    const src_children = try explorer.lsDir(testing.allocator, "src");
    defer testing.allocator.free(src_children);
    try testing.expectEqual(@as(usize, 3), src_children.len);

    var saw_sub_dir = false;
    var file_count: usize = 0;
    for (src_children) |e| {
        if (e.is_dir) {
            if (std.mem.eql(u8, e.name, "sub")) saw_sub_dir = true;
        } else {
            file_count += 1;
            try testing.expect(e.line_count >= 1);
        }
    }
    try testing.expect(saw_sub_dir);
    try testing.expectEqual(@as(usize, 2), file_count);
}


test "issue-359: mcp.globMatch backtracks across **/* boundary" {
    // Pipeline filter (codedb_query) calls mcp.globMatch on each path. The
    // iterative version forgot the outer ** position when it entered the
    // inner *.zig star, so paths like src/sub/inner.zig were rejected by
    // src/**/*.zig even though they should match.
    try testing.expect(mcp_mod.globMatch("src/**/*.zig", "src/sub/inner.zig"));
    try testing.expect(mcp_mod.globMatch("src/**/*.zig", "src/a/b/c.zig"));

    // Single * still must not cross /.
    try testing.expect(!mcp_mod.globMatch("src/*.zig", "src/sub/inner.zig"));

    // Plain prefix matches still work.
    try testing.expect(mcp_mod.globMatch("src/*.zig", "src/mcp.zig"));
    try testing.expect(!mcp_mod.globMatch("docs/*.md", "src/mcp.zig"));
}


test "issue-511: glob supports brace alternatives" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();

    try explorer.indexFile(".github/workflows/release.yml", "name: release");
    try explorer.indexFile("config.yaml", "name: app");
    try explorer.indexFile("docs/readme.md", "# docs");

    const matches = try explorer.globPaths(testing.allocator, "**/*.{yaml,yml}", 10);
    defer testing.allocator.free(matches);

    try testing.expectEqual(@as(usize, 2), matches.len);
    try testing.expectEqualStrings(".github/workflows/release.yml", matches[0]);
    try testing.expectEqualStrings("config.yaml", matches[1]);

    try testing.expect(mcp_mod.globMatch("src/{mcp,explore}.zig", "src/mcp.zig"));
    try testing.expect(mcp_mod.globMatch("src/{mcp,explore}.zig", "src/explore.zig"));
    try testing.expect(!mcp_mod.globMatch("src/{mcp,explore}.zig", "src/main.zig"));
}


test "issue-359: globPaths recall — every matching path survives at every depth" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();

    // Plant files at varying depths under src/, plus a few outside it.
    const planted = [_][]const u8{
        "src/a.zig",
        "src/b.zig",
        "src/sub/c.zig",
        "src/sub/d.zig",
        "src/sub/deep/e.zig",
        "src/sub/deep/f.zig",
        "src/sub/deep/deeper/g.zig",
        "tests/h.zig",
        "src/notes.md",
        "src/sub/notes.md",
    };
    for (planted) |p| try explorer.indexFile(p, "pub fn x() void {}");

    // src/**/*.zig must reach every depth — this is the case the old
    // iterative matcher silently dropped (single star slot lost the
    // outer ** position when the inner *.zig star ran).
    const all_src_zigs = try explorer.globPaths(testing.allocator, "src/**/*.zig", 100);
    defer testing.allocator.free(all_src_zigs);
    try testing.expectEqual(@as(usize, 7), all_src_zigs.len);

    // Single * does not cross /: only the two top-level src zigs.
    const top = try explorer.globPaths(testing.allocator, "src/*.zig", 100);
    defer testing.allocator.free(top);
    try testing.expectEqual(@as(usize, 2), top.len);

    // **/*.md should find both markdown files no matter their depth.
    const md = try explorer.globPaths(testing.allocator, "**/*.md", 100);
    defer testing.allocator.free(md);
    try testing.expectEqual(@as(usize, 2), md.len);

    // Anchored deep match: src/**/g.zig must find the deepest one only.
    const g = try explorer.globPaths(testing.allocator, "src/**/g.zig", 100);
    defer testing.allocator.free(g);
    try testing.expectEqual(@as(usize, 1), g.len);
    try testing.expectEqualStrings("src/sub/deep/deeper/g.zig", g[0]);

    // Pipeline filter must agree path-for-path with globPaths, since it
    // now routes through the same matcher. Spot-check a few.
    try testing.expect(mcp_mod.globMatch("src/**/*.zig", "src/sub/deep/deeper/g.zig"));
    try testing.expect(mcp_mod.globMatch("**/*.md", "src/sub/notes.md"));
    try testing.expect(!mcp_mod.globMatch("src/**/*.zig", "tests/h.zig"));
}


test "issue-359/360: retrieval recall — search/word/symbol/fuzzy/glob/deps all return ground truth" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();

    // Flat paths so dep_graph keys (raw import strings) line up with file paths.
    try explorer.indexFile(
        "auth.zig",
        \\const std = @import("std");
        \\
        \\pub fn authenticate(token: []const u8) bool {
        \\    _ = token;
        \\    return true;
        \\}
        \\pub fn validateToken(token: []const u8) bool {
        \\    return authenticate(token);
        \\}
        ,
    );
    try explorer.indexFile(
        "handler.zig",
        \\const auth = @import("auth.zig");
        \\
        \\pub fn handleLogin() void {
        \\    if (auth.authenticate("x")) return;
        \\}
        ,
    );
    try explorer.indexFile(
        "auth_test.zig",
        \\const auth = @import("auth.zig");
        \\
        \\test "auth round-trip" {
        \\    _ = auth.authenticate("x");
        \\}
        ,
    );
    try explorer.indexFile(
        "unrelated.zig",
        \\pub fn formatNumber(n: i64) []const u8 {
        \\    _ = n;
        \\    return "0";
        \\}
        ,
    );
    try explorer.indexFile("README.md", "# project\nauthenticate description here");

    // 1. Full-text search: every file containing `authenticate` must appear.
    {
        const expected = [_][]const u8{ "auth.zig", "handler.zig", "auth_test.zig", "README.md" };
        const results = try explorer.searchContent("authenticate", testing.allocator, 50);
        defer {
            for (results) |r| {
                testing.allocator.free(r.line_text);
                testing.allocator.free(r.path);
            }
            testing.allocator.free(results);
        }
        var seen = std.StringHashMap(void).init(testing.allocator);
        defer seen.deinit();
        for (results) |r| try seen.put(r.path, {});
        for (expected) |e| try testing.expect(seen.contains(e));
        try testing.expect(!seen.contains("unrelated.zig"));
    }

    // 2. Word index: exact token `authenticate` must reach the same 4 files.
    {
        const hits = try explorer.searchWord("authenticate", testing.allocator);
        defer testing.allocator.free(hits);
        var seen = std.StringHashMap(void).init(testing.allocator);
        defer seen.deinit();
        explorer.mu.lockShared();
        defer explorer.mu.unlockShared();
        for (hits) |h| try seen.put(explorer.word_index.hitPath(h), {});
        const expected = [_][]const u8{ "auth.zig", "handler.zig", "auth_test.zig", "README.md" };
        for (expected) |e| try testing.expect(seen.contains(e));
    }

    // 3. Symbol index: `authenticate` is defined once, in auth.zig.
    {
        const results = try explorer.findAllSymbols("authenticate", testing.allocator);
        defer {
            for (results) |r| {
                testing.allocator.free(r.path);
                testing.allocator.free(r.symbol.name);
                if (r.symbol.detail) |d| testing.allocator.free(d);
            }
            testing.allocator.free(results);
        }
        try testing.expect(results.len >= 1);
        var found_def = false;
        for (results) |r| {
            if (std.mem.eql(u8, r.path, "auth.zig")) found_def = true;
        }
        try testing.expect(found_def);
    }

    // 4. Fuzzy file find: query "auth" must reach both auth.zig and auth_test.zig.
    {
        const results = try explorer.fuzzyFindFiles("auth", testing.allocator, 50);
        defer testing.allocator.free(results);
        var seen = std.StringHashMap(void).init(testing.allocator);
        defer seen.deinit();
        for (results) |r| try seen.put(r.path, {});
        try testing.expect(seen.contains("auth.zig"));
        try testing.expect(seen.contains("auth_test.zig"));
    }

    // 5. Glob: `auth*.zig` must include auth.zig and auth_test.zig only.
    {
        const matches = try explorer.globPaths(testing.allocator, "auth*.zig", 50);
        defer testing.allocator.free(matches);
        var found_auth = false;
        var found_test = false;
        for (matches) |m| {
            if (std.mem.eql(u8, m, "auth.zig")) found_auth = true;
            if (std.mem.eql(u8, m, "auth_test.zig")) found_test = true;
            try testing.expect(!std.mem.eql(u8, m, "unrelated.zig"));
            try testing.expect(!std.mem.eql(u8, m, "handler.zig"));
        }
        try testing.expect(found_auth);
        try testing.expect(found_test);
    }

    // 6. Dependency graph: handler.zig and auth_test.zig both import auth.zig.
    {
        const importers = try explorer.getImportedBy("auth.zig", testing.allocator);
        defer {
            for (importers) |p| testing.allocator.free(p);
            testing.allocator.free(importers);
        }
        var saw_handler = false;
        var saw_test = false;
        for (importers) |p| {
            if (std.mem.eql(u8, p, "handler.zig")) saw_handler = true;
            if (std.mem.eql(u8, p, "auth_test.zig")) saw_test = true;
        }
        try testing.expect(saw_handler);
        try testing.expect(saw_test);
    }
}


test "issue-356-1: codedb_query returns partial results when a step fails" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    try explorer.indexFile("src/main.zig", "pub fn main() void {}\n");
    try explorer.indexFile("src/lib.zig", "pub fn helper() void {}\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".", Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer bench_ctx.deinit();

    // Pipeline: step 0 (find) succeeds, step 1 (search) is missing 'query'.
    // Pre-fix: bails on step 1, dropping step 0's output entirely.
    // Post-fix: returns step 0's matched files + a "--- partial ---" tail
    // naming the failing step.
    const pipe_json =
        \\{"pipeline":[
        \\  {"op":"find","query":"main"},
        \\  {"op":"search"}
        \\]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, pipe_json, .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_query, &parsed.value.object, &out, &store, &explorer, &agents);

    // Step 0's output (file matches) must survive even though step 1 failed.
    try testing.expect(std.mem.indexOf(u8, out.items, "src/main.zig") != null);
    // The partial-results tail must name the failing step so callers can
    // recover instead of guessing what went wrong.
    try testing.expect(std.mem.indexOf(u8, out.items, "--- partial ---") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "failed_at: 1") != null);
}


test "issue-356-2: codedb_outline suggests fuzzy alternatives for non-indexed paths" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    try explorer.indexFile("src/main.zig", "pub fn main() void {}\n");
    try explorer.indexFile("src/mcp.zig", "pub fn mcp() void {}\n");
    try explorer.indexFile("src/explore.zig", "pub fn explore() void {}\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".", Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer bench_ctx.deinit();

    // Outline a path that doesn't index — typo on 'main.zig'.
    const args_json =
        \\{"path":"src/man.zig"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_outline, &parsed.value.object, &out, &store, &explorer, &agents);

    // Pre-fix: bare 'error: file not indexed' with no recovery hint.
    // Post-fix: append fuzzy suggestions so the agent can self-correct.
    try testing.expect(std.mem.indexOf(u8, out.items, "did you mean") != null);
    // src/main.zig is the closest fuzzy match for src/man.zig.
    try testing.expect(std.mem.indexOf(u8, out.items, "src/main.zig") != null);
}


test "issue-356-3: codedb_query surfaces received keys on missing-arg errors" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    try explorer.indexFile("src/main.zig", "pub fn main() void {}\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".", Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer bench_ctx.deinit();

    // Single-step pipeline: search step missing 'query' but provided 'q'
    // (common typo). The error should name the keys actually received so
    // the caller can self-diagnose, mirroring the #357 bundle diagnostic.
    const pipe_json =
        \\{"pipeline":[{"op":"search","q":"main"}]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, pipe_json, .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_query, &parsed.value.object, &out, &store, &explorer, &agents);

    // The legitimate missing-arg error must still appear.
    try testing.expect(std.mem.indexOf(u8, out.items, "search needs 'query'") != null);
    // And the diagnostic must surface what the step actually contained.
    try testing.expect(std.mem.indexOf(u8, out.items, "received keys") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "q") != null);
}


test "issue-356-p2: codedb_outline missing path surfaces received keys" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    try explorer.indexFile("src/main.zig", "pub fn main() void {}\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".", Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer bench_ctx.deinit();

    const args_json =
        \\{"file_path":"src/main.zig"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_outline, &parsed.value.object, &out, &store, &explorer, &agents);

    try testing.expect(std.mem.indexOf(u8, out.items, "missing 'path'") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "received keys") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "file_path") != null);
}


test "issue-356-p2: codedb_symbol missing name surfaces received keys" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    try explorer.indexFile("src/main.zig", "pub fn main() void {}\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".", Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer bench_ctx.deinit();

    const args_json =
        \\{"symbol":"main"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_symbol, &parsed.value.object, &out, &store, &explorer, &agents);

    try testing.expect(std.mem.indexOf(u8, out.items, "need name, prefix, pattern, or kind") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "received keys") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "symbol") != null);
}


test "issue-356-p2: codedb_search missing query surfaces received keys" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    try explorer.indexFile("src/main.zig", "pub fn main() void {}\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".", Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer bench_ctx.deinit();

    const args_json =
        \\{"q":"main"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_search, &parsed.value.object, &out, &store, &explorer, &agents);

    try testing.expect(std.mem.indexOf(u8, out.items, "missing 'query'") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "received keys") != null);
}


test "issue-356-p2: codedb_word missing word surfaces received keys" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    try explorer.indexFile("src/main.zig", "pub fn main() void {}\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".", Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer bench_ctx.deinit();

    const args_json =
        \\{"w":"main"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_word, &parsed.value.object, &out, &store, &explorer, &agents);

    try testing.expect(std.mem.indexOf(u8, out.items, "missing 'word'") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "received keys") != null);
}


test "issue-356-p2: codedb_read missing path surfaces received keys" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    try explorer.indexFile("src/main.zig", "pub fn main() void {}\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".", Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer bench_ctx.deinit();

    const args_json =
        \\{"file":"src/main.zig"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_read, &parsed.value.object, &out, &store, &explorer, &agents);

    try testing.expect(std.mem.indexOf(u8, out.items, "missing 'path'") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "received keys") != null);
}


test "issue-356-p2: codedb_deps missing path surfaces received keys" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    try explorer.indexFile("src/main.zig", "pub fn main() void {}\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".", Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer bench_ctx.deinit();

    const args_json =
        \\{"target":"src/main.zig"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_deps, &parsed.value.object, &out, &store, &explorer, &agents);

    try testing.expect(std.mem.indexOf(u8, out.items, "missing 'path'") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "received keys") != null);
}


test "issue-356-p3: codedb_query emits per-stage summary tail on success" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    try explorer.indexFile("src/main.zig", "pub fn main() void {}\n");
    try explorer.indexFile("src/lib.zig", "pub fn helper() void {}\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".", Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer bench_ctx.deinit();

    // Two-step pipeline that succeeds. Phase 3 emits a summary tail so
    // callers can see which step did what without re-parsing the
    // unstructured per-step output above it.
    const pipe_json =
        \\{"pipeline":[
        \\  {"op":"find","query":"main"},
        \\  {"op":"sort","by":"path"}
        \\]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, pipe_json, .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_query, &parsed.value.object, &out, &store, &explorer, &agents);

    // Stage summary appears at the end of a successful pipeline.
    try testing.expect(std.mem.indexOf(u8, out.items, "--- stages ---") != null);
    // Lists each step with op and outgoing file count.
    try testing.expect(std.mem.indexOf(u8, out.items, "0: find") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "1: sort") != null);
}


test "issue-356-p3: codedb_outline includes actionable hint when parser fails" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    try explorer.indexFile("src/main.zig", "pub fn main() void {}\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".", Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer bench_ctx.deinit();

    // Outline a path that's NOT indexed (no setRoot, so disk read won't
    // help either). The "file not indexed" error already gets fuzzy
    // suggestions from phase 1. This test pins that the hint format is
    // actionable — specifically that a 'try codedb_index' suggestion
    // appears so users know how to recover from a stale index.
    const args_json =
        \\{"path":"src/notindexed.zig"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_outline, &parsed.value.object, &out, &store, &explorer, &agents);

    try testing.expect(std.mem.indexOf(u8, out.items, "file not indexed") != null);
    // Phase 3 adds a 'codedb_index' hint so callers know how to recover
    // from a stale index in addition to the 'did you mean' suggestions.
    try testing.expect(std.mem.indexOf(u8, out.items, "codedb_index") != null);
}


test "issue-356-p3: codedb_read appends fuzzy suggestions when path is unreadable" {
    const tmp_io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(tmp_io, "src");
    try tmp.dir.writeFile(tmp_io, .{
        .sub_path = "src/main.zig",
        .data = "pub fn main() void {}\n",
    });

    var project_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const project_path_len = try tmp.dir.realPathFile(tmp_io, ".", &project_path_buf);
    const project_path = project_path_buf[0..project_path_len];

    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    explorer.setRoot(tmp_io, project_path);
    try explorer.indexFile("src/main.zig", "pub fn main() void {}\n");
    try explorer.indexFile("src/lib.zig", "pub fn helper() void {}\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, project_path, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer bench_ctx.deinit();

    // Read a non-indexed, non-existent path. Pre-fix: bare 'failed to read file'.
    // Post-fix: append fuzzy suggestions like outline already does.
    const args_json =
        \\{"path":"src/man.zig"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_read, &parsed.value.object, &out, &store, &explorer, &agents);

    try testing.expect(std.mem.indexOf(u8, out.items, "failed to read file") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "did you mean") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "src/main.zig") != null);
}


test "issue-558: codedb_query filter must filter (or error) — never silently pass every file" {
    // Live repro: [{find},{filter,"pattern":"src/index.zig"},{limit,n:3}]
    // returned all 50 find results — filter only reads 'ext'/'glob', so an
    // unrecognized param silently no-ops, and find prints its full list
    // eagerly so downstream filter/limit never affect the rendered output.
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    try explorer.indexFile("src/auth.py", "def check(): pass");
    try explorer.indexFile("src/auth.ts", "function check() {}");
    try explorer.indexFile("docs/auth.md", "# auth docs");

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".", Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer bench_ctx.deinit();

    const pipe_json =
        \\{"pipeline":[
        \\  {"op":"find","query":"auth"},
        \\  {"op":"filter","pattern":"*.py"},
        \\  {"op":"limit","n":10}
        \\]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, pipe_json, .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_query, &parsed.value.object, &out, &store, &explorer, &agents);

    // The surviving file must be listed in the final output…
    try testing.expect(std.mem.indexOf(u8, out.items, "src/auth.py") != null);
    // …and filtered-out files must not be listed as results.
    try testing.expect(std.mem.indexOf(u8, out.items, "src/auth.ts") == null);
    try testing.expect(std.mem.indexOf(u8, out.items, "docs/auth.md") == null);

    // A filter step with no recognized param must error, not pass everything.
    const bad_json =
        \\{"pipeline":[
        \\  {"op":"find","query":"auth"},
        \\  {"op":"filter","match":"*.py"}
        \\]}
    ;
    const bad_parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, bad_json, .{});
    defer bad_parsed.deinit();

    var bad_out: std.ArrayList(u8) = .empty;
    defer bad_out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_query, &bad_parsed.value.object, &bad_out, &store, &explorer, &agents);

    try testing.expect(std.mem.indexOf(u8, bad_out.items, "error: filter needs") != null);
}

// ─── audit (2026-06-09): latent-issue sweep — memory safety ───
// src/mcp.zig deps op appended freed dependency strings into file_set (use-after-free)
// and leaked the seed string. testing.allocator catches both (poisoned read + leak).
test "audit: codedb_query deps op does not use freed dependency strings" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    try explorer.indexFile("auth.zig", "const std = @import(\"std\");\npub fn authenticate() bool { return true; }\n");
    try explorer.indexFile("handler.zig", "const auth = @import(\"auth.zig\");\npub fn handleLogin() void { _ = auth.authenticate(); }\n");
    try explorer.indexFile("auth_test.zig", "const auth = @import(\"auth.zig\");\ntest \"x\" { _ = auth.authenticate(); }\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");
    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".", Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer bench_ctx.deinit();

    const pipe_json =
        \\{"pipeline":[{"op":"deps","path":"auth.zig","direction":"imported_by"}]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, pipe_json, .{});
    defer parsed.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_query, &parsed.value.object, &out, &store, &explorer, &agents);

    try testing.expect(std.mem.indexOf(u8, out.items, "handler.zig") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "auth_test.zig") != null);
}
