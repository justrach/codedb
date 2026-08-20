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
    const score = fuzzyScore("auth_midlware", "src/auth_middleware.py");
    try testing.expect(score != null);
}

test "issue-163: fuzzy word boundary bonus" {
    const boundary = fuzzyScore("auth", "src/auth_handler.py");
    const buried = fuzzyScore("auth", "src/xauthyhandle.py");
    try testing.expect(boundary != null);
    try testing.expect(buried != null);
    try testing.expect(boundary.? > buried.?);
}

test "issue-163: fuzzy filename ranks above directory" {
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
    try testing.expect(fuzzyScore("zzznosuchfilexyz", "notrail.py") == null);
    try testing.expect(fuzzyScore("Widget", "empty.py") == null);
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
    try testing.expect(std.mem.indexOf(u8, results[0].path, "auth_middleware") != null);
}

test {
    _ = @import("list_dir.zig");
    _ = @import("gitignore.zig");
}
