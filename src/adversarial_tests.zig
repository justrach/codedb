const std = @import("std");
const testing = std.testing;

const Explorer = @import("explore.zig").Explorer;
const SearchResult = @import("explore.zig").SearchResult;
const ScopedSearchResult = @import("explore.zig").ScopedSearchResult;
const regexMatch = @import("explore.zig").regexMatch;
const WordIndex = @import("index.zig").WordIndex;
const TrigramIndex = @import("index.zig").TrigramIndex;
const SparseNgramIndex = @import("index.zig").SparseNgramIndex;
const pairWeight = @import("index.zig").pairWeight;
const extractSparseNgrams = @import("index.zig").extractSparseNgrams;
const buildCoveringSet = @import("index.zig").buildCoveringSet;
const setFrequencyTable = @import("index.zig").setFrequencyTable;
const resetFrequencyTable = @import("index.zig").resetFrequencyTable;
const decomposeRegex = @import("index.zig").decomposeRegex;
const MAX_NGRAM_LEN = @import("index.zig").MAX_NGRAM_LEN;

// ════════════════════════════════════════════════════════════════════════════
// ADVERSARIAL: Sparse N-gram substring search (#24 verification)
// The core question: does the sparse index find files when the query is a
// SUBSTRING of the file content (not identical to it)?
// ════════════════════════════════════════════════════════════════════════════

test "adversarial: sparse index finds substring in longer content" {
    var sni = SparseNgramIndex.init(testing.allocator);
    defer sni.deinit();

    // Index a file where the query is embedded in a longer string
    try sni.indexFile("app.zig", "pub fn handleRequest(ctx: *Context) !void {}");

    // Query is a substring of the file content
    const cands = sni.candidates("handleRequest", testing.allocator);
    defer if (cands) |c| testing.allocator.free(c);

    // MUST find the file — this is the C1 fix verification
    try testing.expect(cands != null);
    try testing.expect(cands.?.len > 0);

    var found = false;
    for (cands.?) |p| {
        if (std.mem.eql(u8, p, "app.zig")) found = true;
    }
    try testing.expect(found);
}

test "adversarial: sparse index finds short query in long identifier" {
    var sni = SparseNgramIndex.init(testing.allocator);
    defer sni.deinit();

    try sni.indexFile("models.py", "class UserAuthenticationServiceProvider:\n    pass");

    // Search for a substring buried in the middle of a long identifier
    const cands = sni.candidates("Authentication", testing.allocator);
    defer if (cands) |c| testing.allocator.free(c);

    try testing.expect(cands != null);
    try testing.expect(cands.?.len > 0);

    var found = false;
    for (cands.?) |p| {
        if (std.mem.eql(u8, p, "models.py")) found = true;
    }
    try testing.expect(found);
}

test "adversarial: sparse index finds query spanning word boundaries" {
    var sni = SparseNgramIndex.init(testing.allocator);
    defer sni.deinit();

    // The query spans across a space — different pair-weight landscape
    try sni.indexFile("config.json", "{ \"database_host\": \"localhost\", \"database_port\": 5432 }");

    const cands = sni.candidates("database_host", testing.allocator);
    defer if (cands) |c| testing.allocator.free(c);

    try testing.expect(cands != null);
    var found = false;
    for (cands.?) |p| {
        if (std.mem.eql(u8, p, "config.json")) found = true;
    }
    try testing.expect(found);
}

// ════════════════════════════════════════════════════════════════════════════
// ADVERSARIAL: searchContent intersection logic (#25 verification)
// When sparse returns candidates, it intersects with trigram. If a file is in
// trigram but NOT sparse (different boundaries), it's silently dropped.
// ════════════════════════════════════════════════════════════════════════════

test "adversarial: searchContent finds match even when sparse and trigram disagree" {
    var exp = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer exp.deinit();

    // Index multiple files containing the same query string
    try exp.indexFile("a.zig", "const foo_bar = 42;");
    try exp.indexFile("b.zig", "fn process() void { const x = foo_bar; }");
    try exp.indexFile("c.zig", "// This file mentions foo_bar in a comment");

    const results = try exp.searchContent("foo_bar", testing.allocator, 50);
    defer {
        for (results) |r| {
            testing.allocator.free(r.line_text);
            testing.allocator.free(r.path);
        }
        testing.allocator.free(results);
    }

    // All three files contain "foo_bar" — ALL must be found
    var found_a = false;
    var found_b = false;
    var found_c = false;
    for (results) |r| {
        if (std.mem.eql(u8, r.path, "a.zig")) found_a = true;
        if (std.mem.eql(u8, r.path, "b.zig")) found_b = true;
        if (std.mem.eql(u8, r.path, "c.zig")) found_c = true;
    }
    try testing.expect(found_a);
    try testing.expect(found_b);
    try testing.expect(found_c);
}

test "adversarial: searchContent finds all matches across many files" {
    var exp = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer exp.deinit();

    // 10 files, all containing the search term in different contexts
    const contexts = [_][]const u8{
        "import { validateToken } from './auth';",
        "function validateToken(tok) { return true; }",
        "const result = validateToken(jwt);",
        "if (!validateToken(token)) throw new Error();",
        "// TODO: validateToken needs rate limiting",
        "type Validator = typeof validateToken;",
        "export default validateToken;",
        "describe('validateToken', () => { it('works'); });",
        "   validateToken   ",
        "validateToken",
    };

    for (contexts, 0..) |content, i| {
        var buf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&buf, "file{d}.ts", .{i}) catch unreachable;
        try exp.indexFile(name, content);
    }

    const results = try exp.searchContent("validateToken", testing.allocator, 50);
    defer {
        for (results) |r| {
            testing.allocator.free(r.line_text);
            testing.allocator.free(r.path);
        }
        testing.allocator.free(results);
    }

    // All 10 files must be found
    try testing.expectEqual(@as(usize, 10), results.len);
}

// ════════════════════════════════════════════════════════════════════════════
// ADVERSARIAL: Degenerate / edge-case content for sparse n-grams
// ════════════════════════════════════════════════════════════════════════════

test "adversarial: extractSparseNgrams on empty content" {
    const result = try extractSparseNgrams("", testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "adversarial: extractSparseNgrams on 1-byte content" {
    const result = try extractSparseNgrams("x", testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "adversarial: extractSparseNgrams on 2-byte content" {
    const result = try extractSparseNgrams("ab", testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "adversarial: extractSparseNgrams on exactly 3-byte content" {
    const result = try extractSparseNgrams("abc", testing.allocator);
    defer testing.allocator.free(result);
    // Must produce at least one n-gram (the full 3-byte string)
    try testing.expect(result.len >= 1);
}

test "adversarial: extractSparseNgrams on all-same-character content" {
    // No pair-weight local maxima possible — all pairs are identical
    const content = "aaaaaaaaaaaaaaaaaaa"; // 19 'a's
    const result = try extractSparseNgrams(content, testing.allocator);
    defer testing.allocator.free(result);

    // Must still produce n-grams that cover the content (force-split)
    try testing.expect(result.len > 0);

    // Verify every byte position is covered by at least one n-gram
    var covered: [19]bool = .{false} ** 19;
    for (result) |ng| {
        for (ng.pos..ng.pos + ng.len) |p| {
            if (p < 19) covered[p] = true;
        }
    }
    for (covered) |c| try testing.expect(c);
}

test "adversarial: extractSparseNgrams on content at MAX_NGRAM_LEN boundary" {
    // Exactly 16 bytes — should produce n-grams without force-split
    const content16 = "abcdefghijklmnop";
    const r16 = try extractSparseNgrams(content16, testing.allocator);
    defer testing.allocator.free(r16);
    try testing.expect(r16.len > 0);

    // 17 bytes — may need force-split
    const content17 = "abcdefghijklmnopq";
    const r17 = try extractSparseNgrams(content17, testing.allocator);
    defer testing.allocator.free(r17);
    try testing.expect(r17.len > 0);

    // All lengths ≤ MAX_NGRAM_LEN
    for (r16) |ng| try testing.expect(ng.len <= MAX_NGRAM_LEN);
    for (r17) |ng| try testing.expect(ng.len <= MAX_NGRAM_LEN);
}

test "adversarial: extractSparseNgrams on binary-like content with null bytes" {
    const content = "hello\x00world\x00\x00\x00binary\x00data";
    const result = try extractSparseNgrams(content, testing.allocator);
    defer testing.allocator.free(result);
    // Should not crash — null bytes are valid input
    try testing.expect(result.len > 0);
}

test "adversarial: extractSparseNgrams on content with high-weight pairs only" {
    // Use characters that are NOT in the frequency table (rare = 0xFE00 base)
    // These should all have similarly high weights, producing many boundaries
    const content = "~`@#$%^&*!?<>{}|";
    const result = try extractSparseNgrams(content, testing.allocator);
    defer testing.allocator.free(result);
    try testing.expect(result.len > 0);
    for (result) |ng| {
        try testing.expect(ng.len >= 3);
        try testing.expect(ng.len <= MAX_NGRAM_LEN);
    }
}

// ════════════════════════════════════════════════════════════════════════════
// ADVERSARIAL: buildCoveringSet sliding window correctness
// ════════════════════════════════════════════════════════════════════════════

test "adversarial: buildCoveringSet generates all expected window sizes" {
    const query = "abcdefgh"; // 8 bytes
    const cover = try buildCoveringSet(query, testing.allocator);
    defer testing.allocator.free(cover);

    // Window sizes 3..8 over 8 bytes:
    // len=3: 6 windows, len=4: 5, len=5: 4, len=6: 3, len=7: 2, len=8: 1
    // Total = 6+5+4+3+2+1 = 21
    try testing.expectEqual(@as(usize, 21), cover.len);
}

test "adversarial: buildCoveringSet on short query returns empty" {
    const c1 = try buildCoveringSet("", testing.allocator);
    defer testing.allocator.free(c1);
    try testing.expectEqual(@as(usize, 0), c1.len);

    const c2 = try buildCoveringSet("ab", testing.allocator);
    defer testing.allocator.free(c2);
    try testing.expectEqual(@as(usize, 0), c2.len);
}

test "adversarial: buildCoveringSet hashes match extractSparseNgrams for 3-byte content" {
    // For a 3-byte string, both functions should produce identical hashes
    const content = "xyz";
    const extracted = try extractSparseNgrams(content, testing.allocator);
    defer testing.allocator.free(extracted);

    const covering = try buildCoveringSet(content, testing.allocator);
    defer testing.allocator.free(covering);

    // The covering set has exactly 1 window of length 3
    try testing.expect(covering.len == 1);

    // Check hash overlap — the 3-byte n-gram from extract must match
    // the 3-byte window from covering
    if (extracted.len > 0) {
        var found_match = false;
        for (extracted) |e| {
            for (covering) |c| {
                if (e.hash == c.hash) found_match = true;
            }
        }
        try testing.expect(found_match);
    }
}

// ════════════════════════════════════════════════════════════════════════════
// ADVERSARIAL: Regex quantifier {n,m} not consumed (#30 verification)
// ════════════════════════════════════════════════════════════════════════════

test "adversarial: {n,m} quantifier does not pollute trigram extraction" {
    const alloc = testing.allocator;
    const packTrigram = @import("index.zig").packTrigram;

    // Pattern: abc{2,5}def — trigrams should come from "ab" and "def", NOT "2,5}"
    var query = try decomposeRegex("abc{2,5}def", alloc);
    defer query.deinit();

    // The AND trigrams should NOT contain any garbage trigrams from "2,5}"
    const bad_trigrams = [_]u24{
        packTrigram('2', ',', '5'),
        packTrigram(',', '5', '}'),
        packTrigram('5', '}', 'd'),
        packTrigram('}', 'd', 'e'),
    };

    for (query.and_trigrams) |tri| {
        for (bad_trigrams) |bad| {
            try testing.expect(tri != bad);
        }
    }
}

test "adversarial: {n} quantifier consumed correctly" {
    const alloc = testing.allocator;
    const packTrigram = @import("index.zig").packTrigram;
    var query = try decomposeRegex("xyz{3}abc", alloc);
    defer query.deinit();

    // Should NOT contain trigrams from "3}a" etc.
    const bad = [_]u24{
        packTrigram('3', '}', 'a'),
        packTrigram('}', 'a', 'b'),
    };
    for (query.and_trigrams) |tri| {
        for (bad) |b| try testing.expect(tri != b);
    }
}

test "adversarial: {n,} quantifier consumed correctly" {
    const alloc = testing.allocator;
    const packTrigram = @import("index.zig").packTrigram;

    var query = try decomposeRegex("foo{2,}bar", alloc);
    defer query.deinit();

    const bad = [_]u24{
        packTrigram('2', ',', '}'),
        packTrigram(',', '}', 'b'),
        packTrigram('}', 'b', 'a'),
    };
    for (query.and_trigrams) |tri| {
        for (bad) |b| try testing.expect(tri != b);
    }
}

// ════════════════════════════════════════════════════════════════════════════
// ADVERSARIAL: regexMatch edge cases
// ════════════════════════════════════════════════════════════════════════════

test "adversarial: regexMatch with nested groups" {
    try testing.expect(regexMatch("foobar", "(foo)(bar)"));
    try testing.expect(regexMatch("foobar", "(foo|baz)(bar|qux)"));
    try testing.expect(!regexMatch("fooqux", "(foo)(bar)"));
}

test "adversarial: regexMatch with escaped special chars" {
    try testing.expect(regexMatch("file.txt", "file\\.txt"));
    try testing.expect(!regexMatch("filextxt", "file\\.txt"));
    try testing.expect(regexMatch("a(b)c", "a\\(b\\)c"));
    try testing.expect(regexMatch("a+b", "a\\+b"));
}

test "adversarial: regexMatch with bracket edge cases" {
    // Literal ] at start of class
    try testing.expect(regexMatch("]", "[]]"));
    // Literal - at end of class
    try testing.expect(regexMatch("-", "[a-]"));
    // Negated class
    try testing.expect(!regexMatch("a", "[^a-z]"));
    try testing.expect(regexMatch("5", "[^a-z]"));
}

test "adversarial: regexMatch empty pattern matches everything" {
    try testing.expect(regexMatch("anything", ""));
    try testing.expect(regexMatch("", ""));
}

test "adversarial: regexMatch with ^ and $ anchors" {
    try testing.expect(regexMatch("hello", "^hello$"));
    try testing.expect(!regexMatch("hello world", "^hello$"));
    try testing.expect(regexMatch("hello world", "^hello"));
    try testing.expect(!regexMatch("say hello", "^hello"));
}

test "adversarial: regexMatch quantifier edge: a* matches empty" {
    try testing.expect(regexMatch("", "a*"));
    try testing.expect(regexMatch("b", "a*b"));
    try testing.expect(regexMatch("aaab", "a*b"));
}

test "adversarial: regexMatch quantifier edge: .+ requires at least one char" {
    try testing.expect(!regexMatch("", "^.+$"));
    try testing.expect(regexMatch("x", "^.+$"));
    try testing.expect(regexMatch("xyz", "^.+$"));
}

test "adversarial: regexMatch with 50 alternation branches does not crash" {
    // Build a pattern like "aaa|bbb|ccc|..." with 50 branches
    var buf: [50 * 4]u8 = undefined;
    var pos: usize = 0;
    for (0..50) |i| {
        if (i > 0) {
            buf[pos] = '|';
            pos += 1;
        }
        const c: u8 = @intCast(65 + (i % 26)); // A-Z cycling
        buf[pos] = c;
        buf[pos + 1] = c;
        buf[pos + 2] = c;
        pos += 3;
    }
    // Should match one of the branches
    try testing.expect(regexMatch("AAA", buf[0..pos]));
    // Should not match something not in any branch
    try testing.expect(!regexMatch("999", buf[0..pos]));
}

// ════════════════════════════════════════════════════════════════════════════
// ADVERSARIAL: rebuildTrigrams must also populate sparse_ngram_index (#27)
// ════════════════════════════════════════════════════════════════════════════

test "adversarial: rebuildTrigrams populates sparse_ngram_index" {
    var exp = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer exp.deinit();

    // Index files with skip_trigram=true (simulates cache-hit startup)
    try exp.indexFileSkipTrigram("a.zig", "pub fn handleRequest(ctx: *Context) !void {}");
    try exp.indexFileSkipTrigram("b.zig", "pub fn processData(buf: []u8) !void {}");

    // At this point, trigram and sparse indexes should be empty
    try testing.expectEqual(@as(u32, 0), exp.trigram_index.fileCount());
    try testing.expectEqual(@as(u32, 0), exp.sparse_ngram_index.fileCount());

    // Rebuild — should populate BOTH indexes
    try exp.rebuildTrigrams();

    try testing.expectEqual(@as(u32, 2), exp.trigram_index.fileCount());
    // THIS is the bug: sparse_ngram_index is NOT rebuilt
    try testing.expectEqual(@as(u32, 2), exp.sparse_ngram_index.fileCount());
}

// ════════════════════════════════════════════════════════════════════════════
// ADVERSARIAL: Explorer end-to-end substring search correctness
// The ultimate test: does the full pipeline find real substrings?
// ════════════════════════════════════════════════════════════════════════════

test "adversarial: Explorer searchContent finds query embedded in larger code" {
    var exp = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer exp.deinit();

    try exp.indexFile("server.go", "package main\n\nfunc handleHTTPRequest(w http.ResponseWriter, r *http.Request) {\n\tlog.Println(\"handling request\")\n}\n");

    const results = try exp.searchContent("handleHTTPRequest", testing.allocator, 50);
    defer {
        for (results) |r| {
            testing.allocator.free(r.line_text);
            testing.allocator.free(r.path);
        }
        testing.allocator.free(results);
    }

    try testing.expect(results.len >= 1);
    try testing.expectEqualStrings("server.go", results[0].path);
}

test "adversarial: Explorer searchContent case-insensitive substring" {
    var exp = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer exp.deinit();

    try exp.indexFile("readme.md", "# Getting Started\nThis project uses DatabaseManager to handle connections.");

    // searchContent is case-sensitive, but sparse n-grams normalize to lowercase.
    // Search for exact case match — must be found.
    const results = try exp.searchContent("DatabaseManager", testing.allocator, 50);
    defer {
        for (results) |r| {
            testing.allocator.free(r.line_text);
            testing.allocator.free(r.path);
        }
        testing.allocator.free(results);
    }

    try testing.expect(results.len >= 1);
}

test "adversarial: Explorer searchContentRegex with {n,m} finds correct results" {
    var exp = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer exp.deinit();

    try exp.indexFile("data.txt", "aaa bbb abbbbc ccc");
    try exp.indexFile("other.txt", "nothing here");

    // Pattern ab{2,4}c should match "abbbbc" in data.txt
    const results = try exp.searchContentRegex("ab{2,4}c", testing.allocator, 50);
    defer {
        for (results) |r| {
            testing.allocator.free(r.line_text);
            testing.allocator.free(r.path);
        }
        testing.allocator.free(results);
    }

    // Should find data.txt but NOT other.txt
    var found_data = false;
    var found_other = false;
    for (results) |r| {
        if (std.mem.eql(u8, r.path, "data.txt")) found_data = true;
        if (std.mem.eql(u8, r.path, "other.txt")) found_other = true;
    }
    try testing.expect(found_data);
    try testing.expect(!found_other);
}

// ════════════════════════════════════════════════════════════════════════════
// ADVERSARIAL: pairWeight edge cases
// ════════════════════════════════════════════════════════════════════════════

test "adversarial: pairWeight is deterministic across calls" {
    const w1 = pairWeight('a', 'b');
    const w2 = pairWeight('a', 'b');
    try testing.expectEqual(w1, w2);
}

test "adversarial: pairWeight null bytes don't crash" {
    _ = pairWeight(0, 0);
    _ = pairWeight(0, 255);
    _ = pairWeight(255, 0);
    _ = pairWeight(255, 255);
}

test "adversarial: pairWeight common pairs have lower weight than rare pairs" {
    // 'th' is in the frequency table with 0x1000 base
    const w_th = pairWeight('t', 'h');
    // 'qx' is NOT in the table — defaults to 0xFE00
    const w_qx = pairWeight('q', 'x');
    try testing.expect(w_th < w_qx);
}

// ════════════════════════════════════════════════════════════════════════════
// ADVERSARIAL: SparseNgramIndex lifecycle stress
// ════════════════════════════════════════════════════════════════════════════

test "adversarial: indexFile then removeFile leaves clean state" {
    var sni = SparseNgramIndex.init(testing.allocator);
    defer sni.deinit();

    try sni.indexFile("temp.zig", "pub fn temporary() void {}");
    try testing.expectEqual(@as(u32, 1), sni.fileCount());

    sni.removeFile("temp.zig");
    try testing.expectEqual(@as(u32, 0), sni.fileCount());

    // Candidates should return null/empty after removal
    const cands = sni.candidates("temporary", testing.allocator);
    defer if (cands) |c| testing.allocator.free(c);
    if (cands) |c| {
        try testing.expectEqual(@as(usize, 0), c.len);
    }
}

test "adversarial: re-indexing same file replaces old data" {
    var sni = SparseNgramIndex.init(testing.allocator);
    defer sni.deinit();

    try sni.indexFile("mutable.zig", "const old_function = 42;");
    try sni.indexFile("mutable.zig", "const new_function = 99;");

    try testing.expectEqual(@as(u32, 1), sni.fileCount());

    // Old content should not be findable
    const old_cands = sni.candidates("old_function", testing.allocator);
    defer if (old_cands) |c| testing.allocator.free(c);
    if (old_cands) |oc| {
        for (oc) |p| {
            try testing.expect(!std.mem.eql(u8, p, "mutable.zig"));
        }
    }
}

test "adversarial: indexFile with very long content doesn't OOM or crash" {
    var sni = SparseNgramIndex.init(testing.allocator);
    defer sni.deinit();

    // 100KB of semi-realistic content
    var content: [100 * 1024]u8 = undefined;
    for (&content, 0..) |*c, i| {
        c.* = @intCast(32 + (i % 95)); // printable ASCII
    }

    try sni.indexFile("big.zig", &content);
    try testing.expectEqual(@as(u32, 1), sni.fileCount());
}

// ════════════════════════════════════════════════════════════════════════════
// ADVERSARIAL: TrigramIndex correctness under adversarial inputs
// ════════════════════════════════════════════════════════════════════════════

test "adversarial: trigram index handles file with all identical trigrams" {
    var ti = TrigramIndex.init(testing.allocator);
    defer ti.deinit();

    // All trigrams are "aaa"
    try ti.indexFile("mono.txt", "aaaaaaaaaaaaaaaaaaaaa");
    const cands = ti.candidates("aaa", testing.allocator);
    defer if (cands) |c| testing.allocator.free(c);

    try testing.expect(cands != null);
    var found = false;
    for (cands.?) |p| {
        if (std.mem.eql(u8, p, "mono.txt")) found = true;
    }
    try testing.expect(found);
}

test "adversarial: trigram index query shorter than 3 chars falls through" {
    var ti = TrigramIndex.init(testing.allocator);
    defer ti.deinit();

    try ti.indexFile("short.txt", "hello world");
    const cands = ti.candidates("hi", testing.allocator);
    // Query too short — should return null (triggering brute force)
    try testing.expect(cands == null);
}

// ════════════════════════════════════════════════════════════════════════════
// ADVERSARIAL: regexMatch pathological patterns
// ════════════════════════════════════════════════════════════════════════════

test "adversarial: regexMatch does not hang on catastrophic backtracking pattern" {
    // Classic catastrophic backtracking: (a+)+b on "aaaaaaaaaaac"
    // Our simple implementation should handle this without hanging
    // because matchQuantified is greedy without full NFA backtracking.
    // But let's verify it terminates quickly.
    const result = regexMatch("aaaaaaaaaaaaaaaaac", "(a+)+b");
    try testing.expect(!result);
}

test "adversarial: regexMatch with deeply nested quantifiers" {
    try testing.expect(regexMatch("aaa", "a*a*a*"));
    try testing.expect(regexMatch("", "a*b*c*"));
    try testing.expect(!regexMatch("d", "^a*b*c*$"));
}

test "adversarial: regexMatch pipe inside character class is literal" {
    // [|] means literal |, not alternation
    try testing.expect(regexMatch("|", "[|]"));
    try testing.expect(regexMatch("a|b", "a[|]b"));
    try testing.expect(!regexMatch("a b", "a[|]b"));
}

test "adversarial: regexMatch \\d \\w \\s escapes" {
    try testing.expect(regexMatch("abc123", "\\w+\\d+"));
    try testing.expect(regexMatch("hello world", "\\w+\\s\\w+"));
    try testing.expect(!regexMatch("hello", "\\d+"));
}

// ════════════════════════════════════════════════════════════════════════════
// ADVERSARIAL: Frequency table round-trip and swap
// ════════════════════════════════════════════════════════════════════════════

test "adversarial: setFrequencyTable changes pairWeight output" {
    const before = pairWeight('a', 'b');

    // Create a custom table where 'a','b' has a very different weight
    var custom: [256][256]u16 = .{.{0x5000} ** 256} ** 256;
    custom['a']['b'] = 0x0100; // very low
    setFrequencyTable(&custom);
    defer resetFrequencyTable();

    const after = pairWeight('a', 'b');
    try testing.expect(before != after);
    // After reset, should go back to original
    resetFrequencyTable();
    const restored = pairWeight('a', 'b');
    try testing.expectEqual(before, restored);
}

// ════════════════════════════════════════════════════════════════════════════
// ADVERSARIAL: Cross-verification — brute force vs indexed search
// For correctness, indexed search must return AT LEAST everything
// that brute force would find (soundness property).
// ════════════════════════════════════════════════════════════════════════════

test "adversarial: indexed search is sound — never misses a brute-force match" {
    var exp = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer exp.deinit();

    const files = [_]struct { name: []const u8, content: []const u8 }{
        .{ .name = "main.rs", .content = "fn main() {\n    println!(\"hello world\");\n    let config = load_config();\n}" },
        .{ .name = "config.rs", .content = "pub fn load_config() -> Config {\n    Config::default()\n}" },
        .{ .name = "utils.rs", .content = "// utility functions\nfn helper() {}\nfn load_config_from_file() {}" },
        .{ .name = "test.rs", .content = "mod tests {\n    use super::*;\n    fn test_load_config() {\n        let c = load_config();\n    }\n}" },
        .{ .name = "readme.md", .content = "# Project\nRun `load_config` to initialize." },
    };

    for (files) |f| try exp.indexFile(f.name, f.content);

    const query = "load_config";

    // Indexed search
    const indexed = try exp.searchContent(query, testing.allocator, 100);
    defer {
        for (indexed) |r| {
            testing.allocator.free(r.line_text);
            testing.allocator.free(r.path);
        }
        testing.allocator.free(indexed);
    }

    // Brute force: manually check which files contain the query
    var brute_count: usize = 0;
    for (files) |f| {
        if (std.mem.indexOf(u8, f.content, query) != null) brute_count += 1;
    }

    // Indexed search must find AT LEAST as many as brute force
    // (it may find more due to multiple matches per file, but never fewer files)
    var indexed_files = std.StringHashMap(void).init(testing.allocator);
    defer indexed_files.deinit();
    for (indexed) |r| {
        try indexed_files.put(r.path, {});
    }

    try testing.expect(indexed_files.count() >= brute_count);

    // Specifically: all 4 files containing "load_config" must be found
    for (files) |f| {
        if (std.mem.indexOf(u8, f.content, query) != null) {
            try testing.expect(indexed_files.contains(f.name));
        }
    }
}
