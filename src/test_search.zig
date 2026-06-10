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
const DependencyGraph = explore.DependencyGraph;
const SymbolLocation = explore.SymbolLocation;
const mcp_mod = @import("mcp.zig");
const AgentRegistry = @import("agent.zig").AgentRegistry;

test "issue-264: early exit at max_results misses valid matches in remaining candidates" {
    // searchContent stops as soon as result_list.items.len >= max_results.
    // The first-indexed file is iterated first (doc_id order).  If it has
    // many matches it fills the quota alone, and later files are never checked.
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
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

test "search: line numbers correct with incremental counting" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

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

test "issue-290: searchContent with hyphen query does not crash" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    try explorer.indexFile("a.zig", "const x = \"test-case\";\n");
    const results = try explorer.searchContent("test-case", testing.allocator, 10);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }
}

test "issue-292: searchContent with pipe query does not crash" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    try explorer.indexFile("a.zig", "const x = \"timestamp|activity|filter\";\n");
    const results = try explorer.searchContent("timestamp|activity|filter", testing.allocator, 5);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }
}

test "issue-292: codedb_search guidance hints regex=true on metachar query" {
    const args_json = "{\"query\":\"timestamp|activity|filter\"}";
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
    defer parsed.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    mcp_mod.mcpGenerateGuidance(testing.allocator, "codedb_search", &parsed.value.object, "", false, &buf);
    try testing.expect(std.mem.indexOf(u8, buf.items, "regex=true") != null);
}

test "issue-292: codedb_search guidance does not warn when regex=true is set" {
    const args_json = "{\"query\":\"timestamp|activity\",\"regex\":true}";
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
    defer parsed.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    mcp_mod.mcpGenerateGuidance(testing.allocator, "codedb_search", &parsed.value.object, "", false, &buf);
    try testing.expect(std.mem.indexOf(u8, buf.items, "regex=true") == null);
}

test "issue-290: codedb_search guidance does not warn on plain hyphen" {
    const args_json = "{\"query\":\"test-case\"}";
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
    defer parsed.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    mcp_mod.mcpGenerateGuidance(testing.allocator, "codedb_search", &parsed.value.object, "", false, &buf);
    try testing.expect(std.mem.indexOf(u8, buf.items, "regex=true") == null);
}

test "issue-363b: fuzzyFindFiles ranks exact basename match above unrelated lib.rs" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();

    // Reproducer from #363: indexing the codegraff workspace, querying 'cli.rs'
    // returned four `lib.rs` files before the actual `crates/forge_main/src/cli.rs`.
    // Path layout matches the user's report.
    try explorer.indexFile("crates/forge_ci/src/lib.rs", "pub fn ci() {}\n");
    try explorer.indexFile("crates/forge_fs/src/lib.rs", "pub fn fs() {}\n");
    try explorer.indexFile("crates/forge_app/src/lib.rs", "pub fn app_lib() {}\n");
    try explorer.indexFile("crates/forge_api/src/lib.rs", "pub fn api() {}\n");
    try explorer.indexFile(
        "crates/forge_main/src/cli.rs",
        "pub fn parse_args() -> Args {\n    Args {}\n}\n",
    );

    const matches = try explorer.fuzzyFindFiles("cli.rs", testing.allocator, 5);
    defer testing.allocator.free(matches);

    try testing.expect(matches.len > 0);
    // Exact-basename match should be #1, not buried below unrelated lib.rs files.
    try testing.expectEqualStrings("crates/forge_main/src/cli.rs", matches[0].path);
}

test "issue-363a: searchContent surfaces source-file matches even when doc files dominate the word index" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();

    // To hit Tier 0 of searchContent (explore.zig:1511-1535) the gate
    // `word_hits.len <= max_results * 2` must hold. We pick small numbers:
    // 4 docs × 4 mentions = 16 hits, then 2 source-file hits = 18 total, with
    // max_results=10 → 18 ≤ 20 ✓ → Tier 0 runs.
    var path_buf: [64]u8 = undefined;
    var content_buf: [1024]u8 = undefined;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const path = try std.fmt.bufPrint(&path_buf, "docs/notes_{d}.md", .{i});
        const content = try std.fmt.bufPrint(
            &content_buf,
            "## Notes {d}\n\n" ++
                "The searchContent function is documented here.\n" ++
                "We discuss searchContent at length.\n" ++
                "Note that searchContent is multi-tier.\n" ++
                "Performance: searchContent is fast.\n",
            .{i},
        );
        try explorer.indexFile(path, content);
    }

    // Index the source file LAST so its word-index hits land at the END of
    // the posting list. Pre-fix, Tier 0 fills the result_list with doc hits
    // and returns before reaching source-file hits.
    try explorer.indexFile(
        "src/explore.zig",
        "pub fn searchContent(self: *Explorer, query: []const u8) !void {\n" ++
            "    // searchContent is the multi-tier text search entrypoint.\n" ++
            "    _ = self;\n" ++
            "    _ = query;\n" ++
            "}\n",
    );

    const results = try explorer.searchContent("searchContent", testing.allocator, 10);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }

    var found_source = false;
    for (results) |r| {
        if (std.mem.eql(u8, r.path, "src/explore.zig")) {
            found_source = true;
            break;
        }
    }
    // The source file MUST appear — it's the canonical match for the
    // identifier. Pre-fix, doc-file hits saturated the 10-result quota in
    // Tier 0 and src/explore.zig was dropped.
    try testing.expect(found_source);
}

test "issue-recall: codedb_search supports path_glob filter" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    try explorer.indexFile("src/main.zig", "received keys foo\n");
    try explorer.indexFile("CHANGELOG.md", "received keys diagnostic\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".", Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer bench_ctx.deinit();

    const args_json =
        \\{"query":"received keys","path_glob":"*.zig"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_search, &parsed.value.object, &out, &store, &explorer, &agents);

    try testing.expect(std.mem.indexOf(u8, out.items, "src/main.zig") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "CHANGELOG.md") == null);
}

test "issue-422: search header count must reflect post-filter visible results" {
    // From the issue: a query whose ONLY match would be displayed instead
    // shows `1 results` then `(0 shown, 1 truncated)` — every match hidden
    // behind a misleading header. Root cause: the header reports the
    // unfiltered `results.len` from the explorer, but path_glob/compact
    // filters can drop items before they reach the renderer, so a "result"
    // that was filtered is mis-labeled as "truncated".
    //
    // Repro shape mirrors the reporter's call: scope=true, compact=true,
    // path_glob limited to a subtree. The match ITSELF is in-glob and not a
    // comment — the bug is purely in the bookkeeping.
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    // Two files: one in the path_glob subtree (the real match), one outside
    // it (a decoy that the explorer would also return for the substring).
    // Without the fix the header counts both, then the renderer drops the
    // out-of-glob one and (because of unrelated bookkeeping) reports the
    // in-glob one as "truncated" too.
    try explorer.indexFile(
        "crates/forge_api/src/forge_api.rs",
        "// header\n// header\n// header\n// header\n// header\n// header\n// header\n// header\n// header\n// header\n// header\n// header\n// header\n// header\n// header\n// header\n// header\n// header\n// header\n// header\n// header\n// header\n// header\npub struct ForgeAPI<S, F> {\n",
    );
    // Decoy match outside the glob — explorer will return it, the renderer
    // must NOT count it toward "truncated".
    try explorer.indexFile("docs/forge_api.md", "struct ForgeAPI is documented here\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".", Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer bench_ctx.deinit();

    const args_json =
        \\{"query":"struct ForgeAPI","max_results":20,"scope":true,"compact":true,"regex":false,"path_glob":"crates/**/*.rs"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_search, &parsed.value.object, &out, &store, &explorer, &agents);

    // The actionable hit must be visible (path + line number).
    try testing.expect(std.mem.indexOf(u8, out.items, "crates/forge_api/src/forge_api.rs") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, ":24:") != null);
    // Out-of-glob decoy must be excluded from the rendered output.
    try testing.expect(std.mem.indexOf(u8, out.items, "docs/forge_api.md") == null);
    // The misleading "(N shown, M truncated)" footer must NOT fire when M
    // is just the count of glob-filtered or compact-filtered items. Those
    // weren't truncated — they were filtered out, and saying "truncated"
    // implies the user could recover them by raising max_results.
    try testing.expect(std.mem.indexOf(u8, out.items, " truncated)") == null);
    // Header count must reflect post-filter visible matches (1), not the
    // raw explorer count (2). Otherwise users see a misleading "2 results"
    // when only 1 matched their glob.
    try testing.expect(std.mem.indexOf(u8, out.items, "1 results for 'struct ForgeAPI'") != null);
}

test "issue-390: codedb_search scope=true caps matches per file" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();

    // Build a "dominant" file with 20 matches plus several files with 1 match
    // each. Without a per-file cap on the scope=true path, the dominant file
    // alone drowns the response. The plain/regex branches already enforce
    // max_per_file=5 (mcp.zig:1141, 1198), but the scope=true branch does not.
    var dominant_buf: std.ArrayList(u8) = .empty;
    defer dominant_buf.deinit(testing.allocator);
    try dominant_buf.appendSlice(testing.allocator, "pub fn dominant() void {\n");
    for (0..20) |_| try dominant_buf.appendSlice(testing.allocator, "    // FROBNICATE token\n");
    try dominant_buf.appendSlice(testing.allocator, "}\n");
    try explorer.indexFile("src/dominant.zig", dominant_buf.items);
    try explorer.indexFile("src/a.zig", "// FROBNICATE here\npub fn a() void {}\n");
    try explorer.indexFile("src/b.zig", "// FROBNICATE here\npub fn b() void {}\n");
    try explorer.indexFile("src/c.zig", "// FROBNICATE here\npub fn c() void {}\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");
    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".", Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer bench_ctx.deinit();

    const args_json =
        \\{"query":"FROBNICATE","scope":true,"max_results":100}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
    defer parsed.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_search, &parsed.value.object, &out, &store, &explorer, &agents);

    // Count "src/dominant.zig:" occurrences (one per emitted match line).
    var dominant_lines: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, out.items, i, "src/dominant.zig:")) |pos| {
        dominant_lines += 1;
        i = pos + 1;
    }
    // The plain-search per-file cap is 5; scope=true should match. Without
    // any cap, all 20 matches surface and starve the smaller files.
    try testing.expect(dominant_lines <= 5);
    // The other files still surface — the cap shouldn't tank recall, just
    // bound the dominant file's share.
    try testing.expect(std.mem.indexOf(u8, out.items, "src/a.zig:") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "src/b.zig:") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "src/c.zig:") != null);
}

test "issue-391: codedb_callers tool exists" {
    // codedb_callers is the proposed reverse-callgraph tool: given a symbol
    // name, return the call sites across the index. It fuses the existing
    // word index with outline scopes, replacing the multi-step
    // "codedb_word → eyeball → codedb_outline per file" workflow.
    //
    // The minimum surface contract: the Tool enum exposes a codedb_callers
    // variant so dispatch can route to it. Today it does not, so the
    // workflow has to be assembled by hand on the client side.
    try testing.expect(@hasField(mcp_mod.Tool, "codedb_callers"));
}

test "issue-391: codedb_callers returns call sites with scope" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");
    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".", Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer bench_ctx.deinit();

    try explorer.indexFile("def.zig", "pub fn fooBar() void {}\n");
    try explorer.indexFile("a.zig", "pub fn callerA() void {\n    fooBar();\n}\n");
    try explorer.indexFile("b.zig", "pub fn callerB() void {\n    fooBar();\n}\n");

    const args_json =
        \\{"name":"fooBar"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
    defer parsed.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_callers, &parsed.value.object, &out, &store, &explorer, &agents);

    try testing.expect(std.mem.indexOf(u8, out.items, "2 call sites for 'fooBar'") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "a.zig:2") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "b.zig:2") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "callerA") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "callerB") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "def.zig:1") == null);
}

test "issue-391: codedb_callers rejects missing name" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");
    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".", Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer bench_ctx.deinit();

    const args_json =
        \\{}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
    defer parsed.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_callers, &parsed.value.object, &out, &store, &explorer, &agents);

    try testing.expect(std.mem.startsWith(u8, out.items, "error:"));
    try testing.expect(std.mem.indexOf(u8, out.items, "name") != null);
}

test "issue-393: BM25 ranking surfaces high-density file before single-mention file" {
    // Multi-term content queries today return matches in scan order with only
    // a per-line occurrence count tiebreaker (explore.zig:1674-1688). On a
    // large repo this dumps every match with no notion of which *file* is the
    // most relevant — a file that mentions every query term many times ranks
    // identically to one that mentions a single term once.
    //
    // BM25 over the existing trigram + word index would score documents by
    // (per-term tf * idf) with length normalization, so the file densely
    // covering both terms surfaces above the noise file.
    //
    // Minimum surface contract: Explorer exposes `searchContentRanked` which
    // takes a multi-term query and returns results ordered by descending
    // BM25 score across files (highest-scoring document's match comes first).
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    // dense.zig: hits both query terms many times across many lines.
    try explorer.indexFile("src/dense.zig",
        \\pub fn parseTokenStream() void {
        \\    const token = nextToken();
        \\    parseToken(token);
        \\    parseToken(token);
        \\    parseToken(token);
        \\    const stream = parseTokenStream();
        \\    parseTokenStream();
        \\    _ = token;
        \\    _ = stream;
        \\}
    );
    // sparse.zig: mentions one term once, in passing.
    try explorer.indexFile("src/sparse.zig",
        \\pub fn unrelated() void {
        \\    // a passing mention of parse here
        \\    return;
        \\}
    );
    // Noise files dilute df-based scoring; BM25 must still rank dense first.
    try explorer.indexFile("src/noise_a.zig", "pub fn a() void {}\n");
    try explorer.indexFile("src/noise_b.zig", "pub fn b() void {}\n");
    try explorer.indexFile("src/noise_c.zig", "pub fn c() void {}\n");

    try testing.expect(@hasDecl(Explorer, "searchContentRanked"));

    const results = try explorer.searchContentRanked("parse Token", testing.allocator, 16);
    defer {
        for (results) |r| {
            testing.allocator.free(r.line_text);
            testing.allocator.free(r.path);
        }
        testing.allocator.free(results);
    }

    try testing.expect(results.len > 0);
    // Top-ranked result must come from the dense file.
    try testing.expectEqualStrings("src/dense.zig", results[0].path);
    // Score must be populated and strictly positive when ranking is on.
    try testing.expect(results[0].score > 0.0);
    // Results must be sorted by score descending across distinct documents:
    // the first dense.zig score must exceed the first sparse.zig score.
    var dense_score: f32 = -1.0;
    var sparse_score: f32 = -1.0;
    for (results) |r| {
        if (dense_score < 0 and std.mem.eql(u8, r.path, "src/dense.zig")) dense_score = r.score;
        if (sparse_score < 0 and std.mem.eql(u8, r.path, "src/sparse.zig")) sparse_score = r.score;
    }
    if (sparse_score >= 0) {
        try testing.expect(dense_score > sparse_score);
    }
}

test "issue-400: BM25 ranks both-terms file above single-term files" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("both.zig",
        \\pub fn parseToken() void {
        \\    parseToken();
        \\    parseToken();
        \\}
    );
    try explorer.indexFile("only_parse.zig",
        \\pub fn parseFoo() void {
        \\    parse();
        \\}
    );
    try explorer.indexFile("only_token.zig",
        \\pub fn tokenStream() void {
        \\    token();
        \\}
    );

    const results = try explorer.searchContentRanked("parse Token", testing.allocator, 8);
    defer {
        for (results) |r| {
            testing.allocator.free(r.line_text);
            testing.allocator.free(r.path);
        }
        testing.allocator.free(results);
    }
    try testing.expect(results.len > 0);
    try testing.expectEqualStrings("both.zig", results[0].path);
    try testing.expect(results[0].score > 0.0);
}

test "issue-546: searchContentAuto applies the ranker to multi-word queries (CLI parity with MCP)" {
    // #546: `codedb search` runs through runQuery (shared by the cold CLI path and
    // the warm cli-daemon), which always called the UNRANKED searchContent — so
    // multi-word/conceptual CLI queries came back in recall order, never the
    // BM25+centrality order the MCP `search` handler already used. searchContentAuto
    // is the single query-shape-aware entry point both call, so they rank identically:
    // a multi-word query routes to searchContentRanked. (Single tokens keep literal
    // substring matching for exact-identifier lookups — covered elsewhere.)
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    // both.zig covers BOTH query terms; the single-term files are denser lexical
    // hits for one term but less relevant to the two-term query.
    try explorer.indexFile("both.zig",
        \\pub fn parseToken() void {
        \\    parseToken();
        \\    parseToken();
        \\}
    );
    try explorer.indexFile("only_parse.zig",
        \\pub fn parseFoo() void {
        \\    parse();
        \\    parse();
        \\    parse();
        \\}
    );
    try explorer.indexFile("only_token.zig",
        \\pub fn tokenStream() void {
        \\    token();
        \\    token();
        \\}
    );

    // Multi-word query: searchContentAuto must route to the ranker, so the
    // both-terms file ranks first and carries a positive BM25 score (the unranked
    // recall path neither guarantees this order nor populates a score).
    const results = try explorer.searchContentAuto("parse Token", testing.allocator, 8);
    defer {
        for (results) |r| {
            testing.allocator.free(r.line_text);
            testing.allocator.free(r.path);
        }
        testing.allocator.free(results);
    }
    try testing.expect(results.len > 0);
    try testing.expectEqualStrings("both.zig", results[0].path);
    try testing.expect(results[0].score > 0.0);
}

test "issue-546: searchContentRanked rebuilds an incomplete (snapshot-loaded) word index" {
    // #546 root cause: a mmap/disk-loaded word index is recall-ready but not
    // BM25-ready (word_index_complete = false; empty id_to_path / ranked-doc table).
    // searchContent and searchWord lazily rebuild in that state, but
    // searchContentRanked did not — so multi-word ranked search returned NOTHING on
    // a cold CLI / freshly-loaded snapshot even though `word` found hits. This pins
    // the lazy rebuild: markWordIndexIncomplete simulates the post-load state (file
    // contents remain), and ranked search must rebuild and return results instead of
    // collapsing to an empty set.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("both.zig",
        \\pub fn parseToken() void {
        \\    parseToken();
        \\    parseToken();
        \\}
    );
    try explorer.indexFile("only_parse.zig",
        \\pub fn parseFoo() void {
        \\    parse();
        \\}
    );
    try explorer.indexFile("only_token.zig",
        \\pub fn tokenStream() void {
        \\    token();
        \\}
    );

    // Drop the in-memory word index to its post-snapshot-load state: not complete,
    // contents still present. Without the lazy rebuild, searchContentRanked sees
    // N == 0 and returns nothing.
    explorer.markWordIndexIncomplete(false);

    const results = try explorer.searchContentRanked("parse Token", testing.allocator, 8);
    defer {
        for (results) |r| {
            testing.allocator.free(r.line_text);
            testing.allocator.free(r.path);
        }
        testing.allocator.free(results);
    }
    try testing.expect(results.len > 0);
    try testing.expectEqualStrings("both.zig", results[0].path);
}

test "issue-400-bug1: searchContentRanked returns ranked results when skip_file_words=true" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    explorer.word_index.skip_file_words = true;
    try explorer.indexFile("a.zig", "apple banana\n");
    try explorer.indexFile("b.zig", "apple\n");
    const results = try explorer.searchContentRanked("apple", testing.allocator, 10);
    defer {
        for (results) |r| {
            testing.allocator.free(r.line_text);
            testing.allocator.free(r.path);
        }
        testing.allocator.free(results);
    }
    try testing.expect(results.len > 0);
}

test "issue-400-bug2: total_tokens stays consistent across re-index when skip_file_words=true" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    explorer.word_index.skip_file_words = true;
    try explorer.indexFile("a.zig", "one two three four\n");
    try explorer.indexFile("a.zig", "five six seven\n");
    try explorer.indexFile("a.zig", "eight\n");
    try testing.expectEqual(@as(u64, 1), explorer.word_index.total_tokens);
}

test "bm25-recall-a: single-term tf ordering" {
    // 3 docs with identical length but "apple" on different numbers of lines.
    // The index deduplicates per (doc, line), so tf = number of lines with the term.
    // Equal doc lengths mean length normalization is constant; higher tf must rank higher.
    // Each doc has exactly 10 tokens (5 lines x 2 tokens each).
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    // doc1: apple on 1 of 5 lines
    try explorer.indexFile("doc1.txt", "apple filler\nfiller filler\nfiller filler\nfiller filler\nfiller filler");
    // doc2: apple on 5 of 5 lines (max tf)
    try explorer.indexFile("doc2.txt", "apple filler\napple filler\napple filler\napple filler\napple filler");
    // doc3: apple on 2 of 5 lines
    try explorer.indexFile("doc3.txt", "apple filler\napple filler\nfiller filler\nfiller filler\nfiller filler");

    const results = try explorer.searchContentRanked("apple", testing.allocator, 10);
    defer {
        for (results) |r| {
            testing.allocator.free(r.line_text);
            testing.allocator.free(r.path);
        }
        testing.allocator.free(results);
    }

    try testing.expectEqual(@as(usize, 3), results.len);
    try testing.expectEqualStrings("doc2.txt", results[0].path);
    try testing.expectEqualStrings("doc3.txt", results[1].path);
    try testing.expectEqualStrings("doc1.txt", results[2].path);
    try testing.expect(results[0].score > results[1].score);
    try testing.expect(results[1].score > results[2].score);
}

test "bm25-recall-b: both-terms doc beats high-tf single-term doc" {
    // doc1 has apple+banana (both query terms, one occurrence each).
    // doc2 has only apple, but repeated 3x (high tf).
    // doc3 has only banana, once.
    // BM25 sums idf*tf_norm per term: doc1 accumulates two idf contributions
    // while doc2 only gets one -- doc1 must rank first.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("doc1.txt", "apple banana cherry");
    try explorer.indexFile("doc2.txt", "apple apple apple");
    try explorer.indexFile("doc3.txt", "banana date elderberry");

    const results = try explorer.searchContentRanked("apple banana", testing.allocator, 10);
    defer {
        for (results) |r| {
            testing.allocator.free(r.line_text);
            testing.allocator.free(r.path);
        }
        testing.allocator.free(results);
    }

    try testing.expect(results.len >= 2);
    try testing.expectEqualStrings("doc1.txt", results[0].path);
    try testing.expect(results[0].score > 0.0);
    var doc2_score: f32 = -1.0;
    for (results) |r| {
        if (std.mem.eql(u8, r.path, "doc2.txt")) {
            doc2_score = r.score;
            break;
        }
    }
    if (doc2_score >= 0.0) {
        try testing.expect(results[0].score > doc2_score);
    }
}

test "bm25-recall-c: df-saturation -- ubiquitous term has near-zero idf" {
    // "the" appears in all 11 docs -> idf near zero, barely contributes.
    // "unique_marker" appears only in special.txt -> high idf, special.txt ranks first.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("d1.txt", "the quick brown fox");
    try explorer.indexFile("d2.txt", "the lazy dog jumps");
    try explorer.indexFile("d3.txt", "the sun rises east");
    try explorer.indexFile("d4.txt", "the moon shines bright");
    try explorer.indexFile("d5.txt", "the rain in spain");
    try explorer.indexFile("d6.txt", "the cat sat mat");
    try explorer.indexFile("d7.txt", "the wind blows cold");
    try explorer.indexFile("d8.txt", "the tide comes in");
    try explorer.indexFile("d9.txt", "the stars align now");
    try explorer.indexFile("d10.txt", "the clock ticks forward");
    try explorer.indexFile("special.txt", "the unique_marker is here");

    const results = try explorer.searchContentRanked("the unique_marker", testing.allocator, 20);
    defer {
        for (results) |r| {
            testing.allocator.free(r.line_text);
            testing.allocator.free(r.path);
        }
        testing.allocator.free(results);
    }

    try testing.expect(results.len > 0);
    try testing.expectEqualStrings("special.txt", results[0].path);
    if (results.len > 1) {
        try testing.expect(results[0].score > results[1].score);
    }
}

test "bm25-recall-d: length normalization favors shorter doc" {
    // short.txt: 5 tokens, one "needle".
    // long.txt: ~50 tokens, one "needle".
    // BM25 with b=0.75 penalizes longer docs; short.txt must rank higher.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("short.txt", "needle alpha beta gamma delta");
    try explorer.indexFile("long.txt", "aa bb cc dd ee ff gg hh ii jj kk ll mm nn oo pp qq rr ss tt uu vv ww xx yy zz " ++
        "aa bb cc dd ee ff gg hh ii jj kk ll mm nn oo pp qq rr ss tt uu vv ww xx needle yy zz");

    const results = try explorer.searchContentRanked("needle", testing.allocator, 10);
    defer {
        for (results) |r| {
            testing.allocator.free(r.line_text);
            testing.allocator.free(r.path);
        }
        testing.allocator.free(results);
    }

    try testing.expectEqual(@as(usize, 2), results.len);
    try testing.expectEqualStrings("short.txt", results[0].path);
    try testing.expect(results[0].score > results[1].score);
}

test "bm25-recall-e: empty and pathological queries return empty without crash" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("file.txt", "some content here");

    {
        const r = try explorer.searchContentRanked("", testing.allocator, 10);
        defer testing.allocator.free(r);
        try testing.expectEqual(@as(usize, 0), r.len);
    }
    {
        const r = try explorer.searchContentRanked("   ", testing.allocator, 10);
        defer testing.allocator.free(r);
        try testing.expectEqual(@as(usize, 0), r.len);
    }
    {
        const r = try explorer.searchContentRanked("nonexistent_xyz_term_99", testing.allocator, 10);
        defer testing.allocator.free(r);
        try testing.expectEqual(@as(usize, 0), r.len);
    }
}

test "bm25-stress: 1000-doc index, common token, max_results cap honored" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();

    var path_buf: [64]u8 = undefined;
    var content_buf: [256]u8 = undefined;
    for (0..1000) |i| {
        const path = std.fmt.bufPrint(&path_buf, "stress/doc{d}.txt", .{i}) catch unreachable;
        const content = std.fmt.bufPrint(&content_buf, "common token alpha beta gamma doc{d} extra filler words here now", .{i}) catch unreachable;
        try explorer.indexFile(path, content);
    }

    const cap = 25;
    const results = try explorer.searchContentRanked("common", testing.allocator, cap);
    defer {
        for (results) |r| {
            testing.allocator.free(r.line_text);
            testing.allocator.free(r.path);
        }
        testing.allocator.free(results);
    }

    try testing.expect(results.len <= cap);
    try testing.expect(results.len > 0);
    for (results) |r| {
        try testing.expect(r.score > 0.0);
    }
    for (1..results.len) |i| {
        try testing.expect(results[i - 1].score >= results[i].score);
    }
}

test "bm25-state-sync: re-index and remove update total_tokens correctly" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();

    try explorer.indexFile("sync.txt", "alpha beta gamma delta epsilon");
    try testing.expectEqual(@as(u64, 5), explorer.word_index.total_tokens);

    try explorer.indexFile("sync.txt", "alpha beta");
    try testing.expectEqual(@as(u64, 2), explorer.word_index.total_tokens);

    explorer.removeFile("sync.txt");
    try testing.expectEqual(@as(u64, 0), explorer.word_index.total_tokens);
}

test "issue-425: codedb_callers excludes substring matches in unrelated identifiers" {
    // handleCallers (mcp.zig:1339) currently calls searchContentWithScope(name)
    // which is a *substring* full-text search. The only de-dup it performs is
    // dropping lines that match the canonical definition of `name` itself.
    // That means a search for "fooBar" returns lines mentioning the unrelated
    // identifier "fooBarExtended" — both its definition site and any reference
    // — as if they were call sites. The fix is a whole-word check on the hit
    // line so substring matches in longer identifiers are excluded.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");
    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".", Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer bench_ctx.deinit();

    try explorer.indexFile("def.zig", "pub fn fooBar() void {}\n");
    // A different symbol whose name contains "fooBar" as a substring.
    try explorer.indexFile("other.zig", "pub fn fooBarExtended() void {}\n");
    // A genuine call site.
    try explorer.indexFile("a.zig", "pub fn callerA() void {\n    fooBar();\n}\n");

    const args_json =
        \\{"name":"fooBar"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
    defer parsed.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_callers, &parsed.value.object, &out, &store, &explorer, &agents);

    // Real call site must still appear.
    try testing.expect(std.mem.indexOf(u8, out.items, "a.zig:2") != null);
    // Substring-only matches in unrelated identifiers must NOT.
    try testing.expect(std.mem.indexOf(u8, out.items, "other.zig") == null);
    try testing.expect(std.mem.indexOf(u8, out.items, "fooBarExtended") == null);
    // Header reports the real count (1), not the inflated count (2).
    try testing.expect(std.mem.indexOf(u8, out.items, "1 call sites for 'fooBar'") != null);
}

test "issue-426: codedb_callers excludes non-code files (markdown, docs)" {
    // handleCallers (mcp.zig:1339) feeds searchContentWithScope across every
    // indexed file regardless of language. Markdown and other documentation
    // files that mention the symbol in prose surface as if they were call
    // sites. The fix is a language gate: skip results from non-code files.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");
    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".", Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer bench_ctx.deinit();

    try explorer.indexFile("def.zig", "pub fn fooBar() void {}\n");
    try explorer.indexFile("a.zig", "pub fn callerA() void {\n    fooBar();\n}\n");
    // Prose mention in a docs file — the identifier appears as a whole
    // word, so this is independent of the substring-match bug (#425):
    // even a perfect whole-word match on a markdown file is still not a
    // call site.
    try explorer.indexFile(
        "docs/notes.md",
        "# Notes\n\nThe fooBar helper is documented here for posterity.\n",
    );

    const args_json =
        \\{"name":"fooBar"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
    defer parsed.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_callers, &parsed.value.object, &out, &store, &explorer, &agents);

    // Real call site present.
    try testing.expect(std.mem.indexOf(u8, out.items, "a.zig:2") != null);
    // Markdown mention must NOT appear as a call site.
    try testing.expect(std.mem.indexOf(u8, out.items, "docs/notes.md") == null);
    // Header reflects the real count.
    try testing.expect(std.mem.indexOf(u8, out.items, "1 call sites for 'fooBar'") != null);
}

test "issue-427: searchContent Tier 1 sort starves the definition-dense file" {
    // searchContent's Tier 1 (explore.zig:1590-1598) sorts trigram candidates
    // by file content length ASCENDING and then applies a per-file cap of
    // max(1, max_results / estimated_total). When several small unrelated
    // files match the query, they each contribute one hit and saturate the
    // result quota before the canonical (large, definition-dense) file is
    // ever scanned — so the file with the most occurrences of the term is
    // missing from the output.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    // 8 small files. Each contains one occurrence of the term as a whole
    // word. They sort first under the length-ascending Tier 1 order.
    const small_count: usize = 8;
    var i: usize = 0;
    while (i < small_count) : (i += 1) {
        var path_buf: [32]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "small_{d}.zig", .{i});
        try explorer.indexFile(path, "fn s() void { _ = widgetX; }\n");
    }

    // Canonical file: many lines mentioning widgetX, padded so its content
    // length is larger than every small file (sort key: content length).
    const canonical_content =
        "fn canonical() void {\n" ++
        "    _ = widgetX;\n" ++
        "    _ = widgetX;\n" ++
        "    _ = widgetX;\n" ++
        "    _ = widgetX;\n" ++
        "    // padding line for content length, to push this file to the\n" ++
        "    // tail of the length-ascending sort. The reranker should still\n" ++
        "    // surface it because it has the most occurrences of the term.\n" ++
        "    _ = 0;\n" ++
        "}\n";
    try explorer.indexFile("canonical.zig", canonical_content);

    // max_results small enough that 8 small files can saturate the quota.
    // word_hits.len = small_count (8) + canonical occurrences (4) = 12.
    // max_results * 2 = 10. 12 > 10 → Tier 0 gate fails → Tier 1 fires.
    const results = try explorer.searchContent("widgetX", testing.allocator, 5);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }

    // The canonical file MUST appear in the result set. Pre-fix it does not:
    // small files fill all 5 slots first under length-asc order, and the
    // early-return at result_list.len >= max_results returns before the
    // canonical file is ever read.
    var found_canonical = false;
    for (results) |r| {
        if (std.mem.eql(u8, r.path, "canonical.zig")) {
            found_canonical = true;
            break;
        }
    }
    try testing.expect(found_canonical);
}

test "issue-429-a: searchContent rerank boosts files whose basename matches the query" {
    // Two files, same hit count, same content length. The current rerank
    // (explore.zig:1700-1712) sorts ties by path-asc, so a file named
    // "unrelated.zig" outranks "widgetX.zig" even though the latter's
    // basename matches the query exactly. The basename match is a strong
    // intent signal — the developer is asking about that file's subject.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("src/unrelated.zig", "pub fn process() void { _ = widgetX; }\n");
    try explorer.indexFile("src/widgetX.zig", "pub fn process() void { _ = widgetX; }\n");

    const results = try explorer.searchContent("widgetX", testing.allocator, 10);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }
    try testing.expect(results.len >= 2);
    try testing.expectEqualStrings("src/widgetX.zig", results[0].path);
}

test "issue-429-b: searchContent rerank penalizes test/vendor/examples paths" {
    // Two files, same hit count, same content. Pre-fix the path-asc
    // tiebreaker promotes "examples/sample.zig" (e < s) above
    // "src/sample.zig". Post-fix path priors push code roots above
    // example/test/vendor directories so the source-of-truth lands first.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("examples/sample.zig", "pub fn x() void { _ = someTerm; }\n");
    try explorer.indexFile("src/sample.zig", "pub fn x() void { _ = someTerm; }\n");

    const results = try explorer.searchContent("someTerm", testing.allocator, 10);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }
    try testing.expect(results.len >= 2);
    try testing.expectEqualStrings("src/sample.zig", results[0].path);
}

test "issue-429-c: searchContent rerank boosts lines that are symbol definitions" {
    // Two files. "aaa.zig" has a passing comment mention of `fooSym`. The
    // alphabetically-later "zzz_def.zig" has the actual definition. Both
    // tie on per-line occurrence count. Pre-fix the path-asc tiebreaker
    // promotes the comment mention ("aaa" < "zzz"). Post-fix the rerank
    // recognises that the line in zzz_def.zig is a symbol definition and
    // ranks it first.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("aaa.zig", "// fooSym is referenced here in a comment\n");
    try explorer.indexFile("zzz_def.zig", "pub fn fooSym() void {}\n");

    const results = try explorer.searchContent("fooSym", testing.allocator, 10);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }
    try testing.expect(results.len >= 2);
    try testing.expectEqualStrings("zzz_def.zig", results[0].path);
}

test "issue-430: Tier 0 markdown dominance starves canonical source file" {
    // Tier 0 of searchContent (explore.zig:1525-1554) iterates the word
    // index posting list in insertion order with a per-file cap of
    // max(1, max_results/5). When a handful of markdown documents
    // (CHANGELOG.md, benchmarks/*.md, design docs) each mention the query
    // many times AND happen to appear earlier in the posting list than the
    // canonical source file, they saturate result_list before the source
    // file is reached. The existing #363a fix asserted *presence* with a
    // small corpus; this is the high-density regime where presence still
    // fails because Tier 0 hits max_results before the source file's
    // posting-list entries are processed.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    // 5 markdown files each with 10 mentions of fooBar — indexed FIRST so
    // they land at the head of the posting list. With max_results=50 and
    // per-file cap=10, these 5 files alone fill all 50 slots.
    const md_block = "fooBar mentioned here.\nfooBar mentioned here.\n" ++
        "fooBar mentioned here.\nfooBar mentioned here.\n" ++
        "fooBar mentioned here.\nfooBar mentioned here.\n" ++
        "fooBar mentioned here.\nfooBar mentioned here.\n" ++
        "fooBar mentioned here.\nfooBar mentioned here.\n";
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        var path_buf: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "docs/notes_{d}.md", .{i});
        try explorer.indexFile(path, md_block);
    }

    // Source file with the canonical definition + several real call sites,
    // indexed LAST so its posting-list entries come after the markdown noise.
    try explorer.indexFile("src/foo.zig", "pub fn fooBar() void {}\n" ++
        "pub fn caller1() void { fooBar(); }\n" ++
        "pub fn caller2() void { fooBar(); }\n" ++
        "pub fn caller3() void { fooBar(); }\n");

    const results = try explorer.searchContent("fooBar", testing.allocator, 50);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }

    var found_source = false;
    for (results) |r| {
        if (std.mem.eql(u8, r.path, "src/foo.zig")) {
            found_source = true;
            break;
        }
    }
    // The canonical source file MUST appear in the results. Pre-fix it does
    // not: 5 markdown files × 10 hits = 50 entries fill result_list before
    // the source file is reached, then Tier 0 returns at max_results.
    try testing.expect(found_source);
}

test "issue-431: searchContent does not crash when query is longer than content" {
    // searchInContent (explore.zig:3881) computes
    //   const end = content.len - query.len + 1;
    // without checking that query.len <= content.len. When the query is
    // longer than the file content, the subtraction underflows in usize
    // and the binary panics with integer overflow (or aborts with SIGBUS
    // in ReleaseFast). Reproducer: index a tiny file, search for a query
    // longer than the file's content.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("a.zig", "fn x() void {}\n");

    var q_buf: [256]u8 = undefined;
    @memset(&q_buf, 'a');
    const q = q_buf[0..256];

    const results = try explorer.searchContent(q, testing.allocator, 5);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }
    try testing.expect(results.len == 0);
}

test "issue-429-d: searchContent rerank boosts path-segment match" {
    // Two files, same hit count, same content. The query "parser" appears
    // as a directory segment of one path. Pre-fix the alphabetic tiebreak
    // promotes "src/handlers/foo.zig" (h < p). Post-fix the path-segment
    // match boost surfaces "src/parser/foo.zig" first.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("src/handlers/foo.zig", "// parser is mentioned here\n");
    try explorer.indexFile("src/parser/foo.zig", "// parser is mentioned here\n");

    const results = try explorer.searchContent("parser", testing.allocator, 10);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }
    try testing.expect(results.len >= 2);
    try testing.expectEqualStrings("src/parser/foo.zig", results[0].path);
}

test "issue-429-e: searchContent rerank penalises doc-language files so code beats markdown noise" {
    // CHANGELOG.md and benchmark docs often mention an identifier many times
    // in a single line, which under per-line frequency outscores any single
    // code call site. The reranker now halves doc-language scores so a code
    // call site with one occurrence still wins.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    // Doc file with the identifier mentioned four times on one line —
    // pre-fix this scores 4 on per-line frequency.
    try explorer.indexFile(
        "CHANGELOG.md",
        "# Changelog\n\nfooBar — fooBar fooBar fooBar in the changelog.\n",
    );
    // Code call site with the identifier mentioned once.
    try explorer.indexFile(
        "src/caller.zig",
        "pub fn caller() void {\n    fooBar();\n}\n",
    );

    const results = try explorer.searchContent("fooBar", testing.allocator, 10);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }
    try testing.expect(results.len >= 2);
    try testing.expectEqualStrings("src/caller.zig", results[0].path);
}

test "issue-448-a: rerank boosts basename when query contains stem" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("src/aaa.zig", "// Explorer is mentioned here\n");
    try explorer.indexFile("src/explore.zig", "// Explorer is mentioned here\n");

    const results = try explorer.searchContent("Explorer", testing.allocator, 10);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }

    try testing.expect(results.len >= 2);
    try testing.expectEqualStrings("src/explore.zig", results[0].path);
}

test "issue-448-b: rerank symbol definition boost is case-insensitive" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("aaa.zig", "// store is mentioned here\n");
    try explorer.indexFile("zzz.zig", "pub const Store = struct {};\n");

    const results = try explorer.searchContent("store", testing.allocator, 10);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }

    try testing.expect(results.len >= 2);
    try testing.expectEqualStrings("zzz.zig", results[0].path);
}

test "issue-449: popular markdown should not disable Tier 0 code-first behavior" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    const md_block =
        "fooBar mentioned here.\n" ++
        "fooBar mentioned here.\n" ++
        "fooBar mentioned here.\n" ++
        "fooBar mentioned here.\n" ++
        "fooBar mentioned here.\n";

    var i: usize = 0;
    while (i < 10) : (i += 1) {
        var path_buf: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "docs/notes_{d}.md", .{i});
        try explorer.indexFile(path, md_block);
    }

    try explorer.indexFile("src/foo.zig", "pub fn fooBar() void {}\n" ++
        "pub fn caller1() void { fooBar(); }\n" ++
        "pub fn caller2() void { fooBar(); }\n" ++
        "pub fn caller3() void { fooBar(); }\n");

    const results = try explorer.searchContent("fooBar", testing.allocator, 10);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }

    var found_source = false;
    for (results) |r| {
        if (std.mem.eql(u8, r.path, "src/foo.zig")) found_source = true;
    }
    try testing.expect(found_source);
}

test "issue-450: prefix tier respects max_results" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("a.zig", "const abcx = 1;\n");
    try explorer.indexFile("b.zig", "const abcy = 1;\n");
    try explorer.indexFile("c.zig", "const zzabczz = 1;\n");

    const results = try explorer.searchContent("abc", testing.allocator, 2);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }

    try testing.expect(results.len <= 2);
}

test "rerank-trace: appends one JSON line per searchContent when enabled" {
    const tmp_io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp.dir.realPathFile(tmp_io, ".", &path_buf);
    const tmp_path = path_buf[0..tmp_path_len];

    const trace_path = try std.fmt.allocPrint(testing.allocator, "{s}/rerank-traces.jsonl", .{tmp_path});
    defer testing.allocator.free(trace_path);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    explorer.io = tmp_io;
    explorer.rerank_trace_path = trace_path;

    try explorer.indexFile("src/widgetX.zig", "pub fn process() void { _ = widgetX; }\n");
    try explorer.indexFile("src/unrelated.zig", "pub fn process() void { _ = widgetX; }\n");

    const results = try explorer.searchContent("widgetX", testing.allocator, 10);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }
    try testing.expect(results.len >= 2);

    const f = try std.Io.Dir.cwd().openFile(tmp_io, trace_path, .{});
    defer f.close(tmp_io);
    const size = try f.length(tmp_io);
    try testing.expect(size > 0);

    const data = try testing.allocator.alloc(u8, @intCast(size));
    defer testing.allocator.free(data);
    _ = try f.readPositionalAll(tmp_io, data, 0);

    try testing.expectEqual(@as(u8, '\n'), data[data.len - 1]);
    var nl_count: usize = 0;
    for (data) |c| if (c == '\n') {
        nl_count += 1;
    };
    try testing.expectEqual(@as(usize, 1), nl_count);

    try testing.expect(std.mem.indexOf(u8, data, "\"query\":\"widgetX\"") != null);
    try testing.expect(std.mem.indexOf(u8, data, "src/widgetX.zig") != null);
    try testing.expect(std.mem.indexOf(u8, data, "\"results\":[") != null);
}

test "rerank-trace: disabled by default — no file is created" {
    const tmp_io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp.dir.realPathFile(tmp_io, ".", &path_buf);
    const tmp_path = path_buf[0..tmp_path_len];

    const probe_path = try std.fmt.allocPrint(testing.allocator, "{s}/should-not-exist.jsonl", .{tmp_path});
    defer testing.allocator.free(probe_path);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    explorer.io = tmp_io;
    // rerank_trace_path stays null — opt-in only.

    try explorer.indexFile("a.zig", "pub fn t() void { _ = sym; }\n");
    try explorer.indexFile("b.zig", "pub fn t() void { _ = sym; }\n");

    const results = try explorer.searchContent("sym", testing.allocator, 10);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }
    try testing.expect(results.len >= 1);

    const open_err = std.Io.Dir.cwd().openFile(tmp_io, probe_path, .{});
    try testing.expectError(error.FileNotFound, open_err);
}

test "rerank-trace: clobbers when file exceeds size limit" {
    const tmp_io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp.dir.realPathFile(tmp_io, ".", &path_buf);
    const tmp_path = path_buf[0..tmp_path_len];

    const trace_path = try std.fmt.allocPrint(testing.allocator, "{s}/big.jsonl", .{tmp_path});
    defer testing.allocator.free(trace_path);

    {
        const f = try std.Io.Dir.cwd().createFile(tmp_io, trace_path, .{ .truncate = true });
        defer f.close(tmp_io);
        const target_size: u64 = 11 * 1024 * 1024;
        var chunk: [4096]u8 = undefined;
        @memset(&chunk, 'x');
        var written: u64 = 0;
        while (written < target_size) : (written += chunk.len) {
            try f.writePositionalAll(tmp_io, &chunk, written);
        }
    }

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    explorer.io = tmp_io;
    explorer.rerank_trace_path = trace_path;

    try explorer.indexFile("a.zig", "pub fn t() void { _ = sym; }\n");
    try explorer.indexFile("b.zig", "pub fn t() void { _ = sym; }\n");

    const results = try explorer.searchContent("sym", testing.allocator, 10);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }

    const f = try std.Io.Dir.cwd().openFile(tmp_io, trace_path, .{});
    defer f.close(tmp_io);
    const new_size = try f.length(tmp_io);
    try testing.expect(new_size > 0);
    try testing.expect(new_size < 16 * 1024);
}

test "rerank-trace: single-result query records non-zero rerank score" {
    // Pre-fix: rerankAndFinalize only scored when items.len > 1, so a
    // single-result trace logged score=0.0 — misleading for offline analysis
    // because it looked identical to a zero-confidence match. The fix runs
    // scoring unconditionally and only sorts when there's more than one item.
    const tmp_io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp.dir.realPathFile(tmp_io, ".", &path_buf);
    const tmp_path = path_buf[0..tmp_path_len];

    const trace_path = try std.fmt.allocPrint(testing.allocator, "{s}/single.jsonl", .{tmp_path});
    defer testing.allocator.free(trace_path);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    explorer.io = tmp_io;
    explorer.rerank_trace_path = trace_path;

    // Only one file mentions the query — guarantees results.len == 1.
    try explorer.indexFile("src/loneSym.zig", "pub fn loneSym() void {}\n");
    try explorer.indexFile("src/other.zig", "pub fn unrelated() void {}\n");

    const results = try explorer.searchContent("loneSym", testing.allocator, 10);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }
    try testing.expectEqual(@as(usize, 1), results.len);
    // Symbol-def boost (+5) + basename-substring boost (+8) + per-line freq
    // means score is well above zero — verifies scoring actually ran.
    try testing.expect(results[0].score > 1.0);

    const f = try std.Io.Dir.cwd().openFile(tmp_io, trace_path, .{});
    defer f.close(tmp_io);
    const size = try f.length(tmp_io);
    const data = try testing.allocator.alloc(u8, @intCast(size));
    defer testing.allocator.free(data);
    _ = try f.readPositionalAll(tmp_io, data, 0);

    try testing.expect(std.mem.indexOf(u8, data, "\"score\":0.0000") == null);
    try testing.expect(std.mem.indexOf(u8, data, "src/loneSym.zig") != null);
}

test "issue-negq: negative-query search short-circuits Tier 5 full scan" {
    // When a query contains trigrams that no indexed file contains (a
    // definitively-negative query), searchContent should return [] without
    // running the Tier 5 full-scan fallback. On the buggy path Tier 5 fires
    // anyway, scanning every outline — measurable as 100ms+ p50 on real
    // codebases (see benchmarks/search-shootout, react corpus).
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    // Index enough files that Tier 5 would be observably wasteful if it ran.
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        var buf: [32]u8 = undefined;
        const path = try std.fmt.bufPrint(&buf, "file_{d}.zig", .{i});
        try explorer.indexFile(path, "fn process() void { _ = thing; }\n");
    }

    // 'zzqqxxnopematch' — trigrams 'zzq','zqq','qqx',... none of which appear
    // in any indexed file. The trigram index can definitively rule this out
    // without any content scan.
    const results = try explorer.searchContent("zzqqxxnopematch", testing.allocator, 10);
    defer {
        for (results) |r| {
            testing.allocator.free(r.line_text);
            testing.allocator.free(r.path);
        }
        testing.allocator.free(results);
    }

    try testing.expectEqual(@as(usize, 0), results.len);
    // The fix: Tier 5 must NOT fire when the trigram index has already
    // ruled out a match. On main this expectation fails (count == 1).
    try testing.expectEqual(@as(u64, 0), explorer.search_tier5_count);
}

test "issue-471a: codedb_find accepts query/name/path/pattern/q aliases" {
    // Real-user telemetry (24h) showed 71% of codedb_find calls failing with
    // "missing 'query'" because agents passed the search term under `name`,
    // `path`, `pattern`, or `q` (misled by the "FILE-NAME search" framing in
    // the tool description). Regression: every common alias must succeed.
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    try explorer.indexFile("src/main.zig", "pub fn main() void {}\n");
    try explorer.indexFile("src/auth_middleware.go", "package auth\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();

    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".", Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer bench_ctx.deinit();

    const aliases = [_][]const u8{ "query", "name", "path", "pattern", "q" };
    for (aliases) |key| {
        const bundle_json = try std.fmt.allocPrint(
            testing.allocator,
            "{{\"ops\":[{{\"tool\":\"codedb_find\",\"arguments\":{{\"{s}\":\"main\"}}}}]}}",
            .{key},
        );
        defer testing.allocator.free(bundle_json);

        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, bundle_json, .{});
        defer parsed.deinit();

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(testing.allocator);
        bench_ctx.runDispatch(io, testing.allocator, .codedb_bundle, &parsed.value.object, &out, &store, &explorer, &agents);

        // Every alias must succeed: no "missing" error, and the matching
        // file must appear in the response.
        if (std.mem.indexOf(u8, out.items, "missing 'query'") != null) {
            std.debug.print("alias '{s}' failed with: {s}\n", .{ key, out.items });
            return error.AliasRejected;
        }
        try testing.expect(std.mem.indexOf(u8, out.items, "main.zig") != null);
    }
}

test "issue-471b: codedb_find error message enumerates accepted aliases" {
    // If an agent calls codedb_find with no recognized key, the error message
    // must enumerate the accepted aliases so the agent can self-correct on
    // the next call instead of repeating the same broken call.
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

    const bundle_json =
        \\{"ops":[{"tool":"codedb_find","arguments":{"bogus":"main"}}]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, bundle_json, .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_bundle, &parsed.value.object, &out, &store, &explorer, &agents);

    // Error must enumerate the alias list so the agent can self-correct.
    try testing.expect(std.mem.indexOf(u8, out.items, "missing 'query'") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "name") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "path") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "pattern") != null);
}

test "issue-451: scope=true search surfaces skip-trigram files" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();

    var i: usize = 0;
    while (i < 12) : (i += 1) {
        var path_buf: [32]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "small_{d}.zig", .{i}) catch unreachable;
        try explorer.indexFile(path, "fn s() void { _ = widgetX; }\n");
    }

    try explorer.indexFileSkipTrigram("canonical.zig",
        \\fn canonical() void {
        \\    _ = widgetX;
        \\    _ = widgetX;
        \\    _ = widgetX;
        \\    _ = widgetX;
        \\    _ = widgetX;
        \\}
        \\
    );

    const results = try explorer.searchContentWithScope("widgetX", testing.allocator, 20);
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
        if (std.mem.eql(u8, r.path, "canonical.zig")) {
            found_canonical = true;
            try testing.expect(r.scope_name != null);
            try testing.expect(std.mem.eql(u8, r.scope_name.?, "canonical"));
        }
    }
    try testing.expect(found_canonical);
}

test "issue-546: searchContent rerank penalizes non-source tooling paths (bench/install/scripts/website)" {
    // Mirror of issue-429-b for first-party tooling directories. Five files,
    // identical content and hit count — only a path prior can separate them.
    // Pre-fix the path-asc tiebreaker puts bench/ first; the implementation
    // under src/ must win.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("bench/sample.zig", "pub fn x() void { _ = coreTerm; }\n");
    try explorer.indexFile("install/sample.zig", "pub fn x() void { _ = coreTerm; }\n");
    try explorer.indexFile("scripts/sample.zig", "pub fn x() void { _ = coreTerm; }\n");
    try explorer.indexFile("website/sample.zig", "pub fn x() void { _ = coreTerm; }\n");
    try explorer.indexFile("src/sample.zig", "pub fn x() void { _ = coreTerm; }\n");

    const results = try explorer.searchContent("coreTerm", testing.allocator, 10);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }
    try testing.expect(results.len >= 5);
    try testing.expectEqualStrings("src/sample.zig", results[0].path);
}

test "issue-560: path_glob page must not be starved by higher-ranked out-of-glob files" {
    // 40 out-of-glob decoys tie the gold file on score; the path-asc
    // tiebreaker ranks lib/ decoys above src/gold.zig, so the gold hit sits
    // beyond the fetched window. Pre-fix the handler fetches
    // offset+max_results+1 ranked results and only THEN applies path_glob —
    // every fetched row is out-of-glob, so the response is '0 results' plus
    // a 'more results' hint even though src/gold.zig matches query and glob.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    var i: usize = 0;
    while (i < 40) : (i += 1) {
        const name = try std.fmt.allocPrint(arena.allocator(), "lib/decoy{d:0>2}.zig", .{i});
        try explorer.indexFile(name, "pub fn x() void { _ = starveTerm; }\n");
    }
    try explorer.indexFile("src/gold.zig", "pub fn x() void { _ = starveTerm; }\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".", Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer bench_ctx.deinit();

    const args_json =
        \\{"query":"starveTerm","path_glob":"src/**","max_results":5}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_search, &parsed.value.object, &out, &store, &explorer, &agents);

    // The in-glob match must be visible.
    try testing.expect(std.mem.indexOf(u8, out.items, "src/gold.zig") != null);
    // And the header must not claim zero results.
    try testing.expect(std.mem.indexOf(u8, out.items, "0 results") == null);
}

test "issue-562: codedb_callers excludes full-line comment mentions" {
    // Live repro: callers of insertRestoredFile reported snapshot.zig:822
    // ('// is false: insertRestoredFile errors above…') and a test-file
    // comment as call sites. A full-line comment is documentation, not a
    // call — it must not be counted or rendered.
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    try explorer.indexFile("src/zlib.zig", "pub fn insertThing() void {}\n");
    try explorer.indexFile("src/caller.zig", "pub fn doIt() void {\n    insertThing();\n}\n");
    try explorer.indexFile("src/noisy.zig", "// insertThing errors above if the path already exists\npub fn unrelated() void {}\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".", Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer bench_ctx.deinit();

    const args_json =
        \\{"name":"insertThing"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_callers, &parsed.value.object, &out, &store, &explorer, &agents);

    // The real call site stays.
    try testing.expect(std.mem.indexOf(u8, out.items, "src/caller.zig:2") != null);
    // The comment mention must not appear as a call site…
    try testing.expect(std.mem.indexOf(u8, out.items, "src/noisy.zig") == null);
    // …and must not inflate the header count.
    try testing.expect(std.mem.indexOf(u8, out.items, "1 call sites for 'insertThing'") != null);
}

test "issue-580: basename test files rank below non-test source for concept queries" {
    // rerankSignalScore's test penalty only matches DIRECTORY segments named
    // test/tests, so files like src/tests.zig or src/widget_tests.zig dodge
    // the ×0.6 entirely (live: 'codedb search snapshot' put src/tests.zig at
    // file-rank 3, above non-test source). BM25's pathRelevanceMultiplier
    // already checks the basename — the scan-rerank path must match it.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    // The test-named file mentions the term more densely (as test files do);
    // without a basename penalty it outranks the implementation line.
    try explorer.indexFile("src/zz_tests.zig", "pub fn x() void { _ = conceptTerm; _ = conceptTerm; _ = conceptTerm; }\n");
    try explorer.indexFile("src/owner.zig", "pub fn x() void { _ = conceptTerm; _ = conceptTerm; }\n");

    const results = try explorer.searchContent("conceptTerm", testing.allocator, 10);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }
    try testing.expect(results.len >= 2);
    try testing.expectEqualStrings("src/owner.zig", results[0].path);
}

// ─── audit (2026-06-09): latent-issue sweep — failing test for a confirmed bug ───
// src/explore.zig:2418 — searchContent Tier 0 `use_line_hits` fast-path returns before
// rerankAndFinalize, so a high-count non-canonical file outranks the canonical basename
// match (the #537/#448 structural-vs-lexical inversion, reintroduced for small max_results).
test "audit: searchContent tier0 use_line_hits early-return skips rerank basename boost" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("src/other.zig", "widget\nwidget\nwidget\nwidget\nwidget\nwidget\n");
    try explorer.indexFile("src/widget.zig", "const widget = 1;\n");

    const results = try explorer.searchContent("widget", testing.allocator, 2);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }
    try testing.expect(results.len >= 2);
    // RED on main: results[0] == src/other.zig (count 6); canonical basename must win.
    try testing.expectEqualStrings("src/widget.zig", results[0].path);
}

// src/explore.zig renderPlainSearch — the MCP codedb_search fast-path rendered in raw
// hit-count order with no basename prior, so a noise file outranked the canonical match.
test "audit: renderPlainSearch fast-path ranks lexical count over canonical basename" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();

    try explorer.indexFile("src/other.zig", "widget\nwidget\nwidget\nwidget\nwidget\nwidget\n");
    try explorer.indexFile("src/widget.zig", "const widget = 1;\n");

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);

    const rendered = try explorer.renderPlainSearch("widget", testing.allocator, &out, 2, false);
    try testing.expect(rendered);

    const wi = std.mem.indexOf(u8, out.items, "src/widget.zig");
    const oi = std.mem.indexOf(u8, out.items, "src/other.zig");
    try testing.expect(wi != null and oi != null);
    // canonical src/widget.zig must render before the high-count src/other.zig
    try testing.expect(wi.? < oi.?);
}

// src/explore.zig:1659 — readContentForSearch capped disk reads at 512KB while the indexer
// reads up to 64MB, so a word-indexed file >512KB evicted from the content cache was
// invisible to every search tier.
test "audit: searchContent loses a word-indexed file >512KB evicted from the content cache" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(testing.allocator);
    try big.appendSlice(testing.allocator, "fn f() void { _ = widgetzzz; }\n");
    // pad past the old 512KB cap with a few long comment lines — keeps the file
    // >512KB while staying cheap to index (the token we search for is on line 1).
    while (big.items.len < 600 * 1024) {
        try big.appendSlice(testing.allocator, "// ");
        try big.appendNTimes(testing.allocator, 'x', 560);
        try big.appendSlice(testing.allocator, "\n");
    }

    var file = try tmp.dir.createFile(io, "big.zig", .{});
    try file.writeStreamingAll(io, big.items);
    file.close(io);

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPathFile(io, ".", &root_buf);
    const root = root_buf[0..root_len];

    var explorer = Explorer.init(testing.allocator, 1); // capacity 1 forces eviction
    defer explorer.deinit();
    explorer.setRoot(io, root);

    try explorer.indexFile("big.zig", big.items);
    try explorer.indexFile("filler.zig", "fn g() void {}\n");

    try testing.expect(explorer.word_index.search("widgetzzz").len > 0);

    const results = try explorer.searchContent("widgetzzz", testing.allocator, 10);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }
    var found = false;
    for (results) |r| {
        if (std.mem.eql(u8, r.path, "big.zig")) found = true;
    }
    // big.zig must be reachable now that the read cap matches the indexer's 64MB
    try testing.expect(found);
}

// ─── #546 follow-up: cold CLI scan leaves an empty-but-"complete" word index ───
// main.zig's cold non-index scan disables the word index to save memory, but
// word_index_complete defaults to true. Files commit into outlines/contents while
// WordIndex.indexFile silently no-ops, so searchContentRanked trusts the flag,
// skips the lazy rebuild, sees N == 0, and every multi-word CLI search on a cold
// start returns nothing.
test "issue-546: cold CLI scan (word index disabled) still ranks multi-word queries" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    // Mirror the cold CLI scan state (main.zig sets both for non-index commands).
    explorer.word_index.skip_file_words = true;
    explorer.word_index.enabled = false;

    try explorer.indexFile("both.zig",
        \\pub fn parseToken() void {
        \\    parseToken();
        \\    parseToken();
        \\}
    );
    try explorer.indexFile("only_parse.zig",
        \\pub fn parseFoo() void {
        \\    parse();
        \\}
    );

    const results = try explorer.searchContentAuto("parse Token", testing.allocator, 8);
    defer {
        for (results) |r| {
            testing.allocator.free(r.line_text);
            testing.allocator.free(r.path);
        }
        testing.allocator.free(results);
    }
    // RED pre-fix: the empty index claims completeness, no rebuild runs, len == 0.
    try testing.expect(results.len > 0);
    try testing.expectEqualStrings("both.zig", results[0].path);
}

// ─── #569: multi-word `word` queries dead-end — no per-token fallback ───
// `word` looked up the literal phrase in the inverted index, so an agent-shaped
// query like "gateway websocket reconnect" returned zero hits even when every
// token had plentiful hits. Multi-word queries must fall back to per-token
// lookup, ranking files that hit more distinct tokens first.
test "issue-569: multi-word word query falls back to per-token matching" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("src/both.zig", "const gateway = 1;\nconst websocket = 2;\n");
    try explorer.indexFile("src/one.zig", "const gateway = 9;\n");

    // searchWord powers the CLI `word` cmd.
    const hits = try explorer.searchWord("gateway websocket", testing.allocator);
    defer testing.allocator.free(hits);
    try testing.expect(hits.len > 0);
    explorer.mu.lockShared();
    const top = explorer.word_index.hitPath(hits[0]);
    explorer.mu.unlockShared();
    // the file hitting BOTH tokens must outrank the single-token file
    try testing.expectEqualStrings("src/both.zig", top);

    // renderWord powers MCP codedb_word — same files, with the mode noted.
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try explorer.renderWord("gateway websocket", testing.allocator, &out);
    try testing.expect(std.mem.indexOf(u8, out.items, "src/both.zig") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "(tokenized)") != null);
}


test "issue-598: mention-dense tooling files cannot saturate past the path prior" {
    // A bench script repeating the term six times per line scores 6.0×0.5=3.0
    // and shrugs off the tooling-path prior, beating the implementation's 2.0
    // (live: 'capture' put benchmarks/search-shootout/shootout.py in every
    // top-8 slot). Cap the occurrence base for tooling paths BEFORE the
    // stem/symbol boosts so density cannot dominate.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("bench/shootout.py", "captureTerm captureTerm captureTerm captureTerm captureTerm captureTerm\n");
    try explorer.indexFile("src/owner.zig", "pub fn x() void { _ = captureTerm; _ = captureTerm; }\n");

    const results = try explorer.searchContent("captureTerm", testing.allocator, 10);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }
    try testing.expect(results.len >= 2);
    try testing.expectEqualStrings("src/owner.zig", results[0].path);

    // Eponymy must survive the cap: a query that IS the tooling file's stem
    // still ranks that file first (the stem boost applies after the cap).
    var arena2 = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena2.deinit();
    var explorer2 = Explorer.init(arena2.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    try explorer2.indexFile("install/install.sh", "echo install install install\n");
    try explorer2.indexFile("src/setup.zig", "pub fn x() void { _ = install; }\n");

    const results2 = try explorer2.searchContent("install", testing.allocator, 10);
    defer {
        for (results2) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results2);
    }
    try testing.expect(results2.len >= 2);
    try testing.expectEqualStrings("install/install.sh", results2[0].path);
}
