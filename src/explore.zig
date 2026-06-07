const std = @import("std");
const ContentCache = @import("hot_cache.zig").ContentCache;
const nanoregex = @import("nanoregex");
const cio = @import("cio.zig");
const Store = @import("store.zig").Store;
const idx = @import("index.zig");
const WordIndex = idx.WordIndex;
const TrigramIndex = idx.TrigramIndex;
const MmapTrigramIndex = idx.MmapTrigramIndex;
const AnyTrigramIndex = idx.AnyTrigramIndex;
const SparseNgramIndex = idx.SparseNgramIndex;
const codegraph = @import("codegraph.zig");

/// Fast hash context for u32-keyed maps on hot paths (ranked search aggregation).
/// Zig's AutoHashMap runs the 4 key bytes through Wyhash even for an integer key;
/// std.hash.int is a couple of multiply/shift/xor ops with full avalanche. Pure
/// Context swap — identical map semantics, behavior-preserving. (FxHash precedent.)
const U32Context = struct {
    pub fn hash(_: U32Context, k: u32) u64 {
        return std.hash.int(@as(u64, k));
    }
    pub fn eql(_: U32Context, a: u32, b: u32) bool {
        return a == b;
    }
};
fn U32HashMap(comptime V: type) type {
    return std.HashMap(u32, V, U32Context, std.hash_map.default_max_load_percentage);
}

pub const SymbolKind = enum(u8) {
    function,
    struct_def,
    enum_def,
    union_def,
    constant,
    variable,
    import,
    test_decl,
    comment_block,
    trait_def,
    impl_block,
    type_alias,
    macro_def,
    method,
    class_def,
    interface_def,
};

pub const Symbol = struct {
    name: []const u8,
    kind: SymbolKind,
    line_start: u32,
    line_end: u32,
    detail: ?[]const u8 = null,
};

pub const FileOutline = struct {
    path: []const u8,
    language: Language,
    line_count: u32,
    byte_size: u64,
    symbols: std.ArrayList(Symbol) = .empty,
    imports: std.ArrayList([]const u8) = .empty,
    allocator: std.mem.Allocator,
    owns_path: bool = false,
    /// When true, `imports` and each `symbols[].name`/`.detail` are borrowed
    /// slices into an externally-owned buffer (the snapshot outline_state
    /// section, retained by the Explorer) rather than individual allocations,
    /// so deinit must not free them. The ArrayLists themselves are still owned.
    borrows_strings: bool = false,

    pub fn init(allocator: std.mem.Allocator, path: []const u8) FileOutline {
        return .{
            .path = path,
            .language = detectLanguage(path),
            .line_count = 0,
            .byte_size = 0,
            .allocator = allocator,
        };
    }
    pub fn deinit(self: *FileOutline) void {
        if (self.owns_path) self.allocator.free(self.path);
        if (!self.borrows_strings) {
            for (self.symbols.items) |sym| {
                self.allocator.free(sym.name);
                if (sym.detail) |d| self.allocator.free(d);
            }
            for (self.imports.items) |imp| self.allocator.free(imp);
        }
        self.symbols.deinit(self.allocator);
        self.imports.deinit(self.allocator);
    }
};

pub const ParsedFile = struct {
    content: []const u8,
    outline: FileOutline,

    pub fn deinit(self: *ParsedFile) void {
        self.outline.deinit();
    }
};

const PhpParseState = struct {
    in_class: bool = false,
    brace_depth: i32 = 0,
    class_brace_depth: i32 = 0,
    in_block_comment: bool = false,
};

pub const Language = enum(u8) {
    zig,
    c,
    cpp,
    python,
    javascript,
    typescript,
    rust,
    go_lang,
    php,
    ruby,
    hcl,
    r,
    markdown,
    json,
    yaml,
    unknown,
    dart,
    java,
    kotlin,
    swift,
    svelte,
    vue,
    astro,
    shell,
    css,
    scss,
    sql,
    protobuf,
    fortran,
    llvm_ir,
    mlir,
    tablegen,
    rescript,
};

pub fn detectLanguage(path: []const u8) Language {
    if (std.mem.endsWith(u8, path, ".zig")) return .zig;
    if (std.mem.endsWith(u8, path, ".c") or std.mem.endsWith(u8, path, ".h")) return .c;
    if (std.mem.endsWith(u8, path, ".cpp") or std.mem.endsWith(u8, path, ".hpp") or
        std.mem.endsWith(u8, path, ".cc") or std.mem.endsWith(u8, path, ".hh") or
        std.mem.endsWith(u8, path, ".cxx") or std.mem.endsWith(u8, path, ".hxx") or
        std.mem.endsWith(u8, path, ".mm"))
        return .cpp;
    if (std.mem.endsWith(u8, path, ".py")) return .python;
    if (std.mem.endsWith(u8, path, ".js") or std.mem.endsWith(u8, path, ".jsx")) return .javascript;
    if (std.mem.endsWith(u8, path, ".ts") or std.mem.endsWith(u8, path, ".tsx")) return .typescript;
    if (std.mem.endsWith(u8, path, ".rs")) return .rust;
    if (std.mem.endsWith(u8, path, ".go")) return .go_lang;
    if (std.mem.endsWith(u8, path, ".php")) return .php;
    if (std.mem.endsWith(u8, path, ".rb") or std.mem.endsWith(u8, path, ".rake")) return .ruby;
    if (std.mem.endsWith(u8, path, ".tf") or std.mem.endsWith(u8, path, ".tfvars") or std.mem.endsWith(u8, path, ".hcl")) return .hcl;
    if (std.mem.endsWith(u8, path, ".r") or std.mem.endsWith(u8, path, ".R")) return .r;
    if (std.mem.endsWith(u8, path, ".md")) return .markdown;
    if (std.mem.endsWith(u8, path, ".json")) return .json;
    if (std.mem.endsWith(u8, path, ".yaml") or std.mem.endsWith(u8, path, ".yml")) return .yaml;
    if (std.mem.endsWith(u8, path, ".dart")) return .dart;
    if (std.mem.endsWith(u8, path, ".java")) return .java;
    if (std.mem.endsWith(u8, path, ".kt")) return .kotlin;
    if (std.mem.endsWith(u8, path, ".swift")) return .swift;
    if (std.mem.endsWith(u8, path, ".svelte")) return .svelte;
    if (std.mem.endsWith(u8, path, ".vue")) return .vue;
    if (std.mem.endsWith(u8, path, ".astro")) return .astro;
    if (std.mem.endsWith(u8, path, ".sh")) return .shell;
    if (std.mem.endsWith(u8, path, ".css")) return .css;
    if (std.mem.endsWith(u8, path, ".scss")) return .scss;
    if (std.mem.endsWith(u8, path, ".sql")) return .sql;
    if (std.mem.endsWith(u8, path, ".proto")) return .protobuf;
    if (std.mem.endsWith(u8, path, ".f90")) return .fortran;
    if (std.mem.endsWith(u8, path, ".ll")) return .llvm_ir;
    if (std.mem.endsWith(u8, path, ".mlir")) return .mlir;
    if (std.mem.endsWith(u8, path, ".td")) return .tablegen;
    if (std.mem.endsWith(u8, path, ".res") or std.mem.endsWith(u8, path, ".resi")) return .rescript;
    return .unknown;
}

/// Returns true for languages whose content is primarily prose / data /
/// markup rather than executable code. Used to deprioritise these files in
/// content search so a CHANGELOG.md or design doc cannot starve a canonical
/// source-file match (issue #430).
pub fn isDocLanguage(lang: Language) bool {
    return switch (lang) {
        .markdown, .json, .yaml, .unknown => true,
        else => false,
    };
}

pub const SymbolResult = struct {
    path: []const u8,
    symbol: Symbol,
};

pub const SearchResult = struct {
    path: []const u8,
    line_num: u32,
    line_text: []const u8,
    score: f32 = 0.0,
};

pub const SearchBreakdown = struct {
    tier0_ns: i128 = 0,
    tier05_ns: i128 = 0,
    tier1_ns: i128 = 0,
    tier2_ns: i128 = 0,
    tier3_ns: i128 = 0,
    tier4_ns: i128 = 0,
    tier5_ns: i128 = 0,
    rerank_ns: i128 = 0,
    tier_reached: u8 = 0,
    candidate_count: u32 = 0,
    result_count: u32 = 0,
};

pub const DependencyGraph = struct {
    forward: std.StringHashMap(std.ArrayList([]const u8)),
    reverse: std.StringHashMap(std.StringHashMap(void)),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) DependencyGraph {
        return .{
            .forward = std.StringHashMap(std.ArrayList([]const u8)).init(allocator),
            .reverse = std.StringHashMap(std.StringHashMap(void)).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *DependencyGraph) void {
        var fwd_iter = self.forward.iterator();
        while (fwd_iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.forward.deinit();

        var rev_iter = self.reverse.iterator();
        while (rev_iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.reverse.deinit();
    }

    pub fn setDeps(self: *DependencyGraph, path: []const u8, deps: std.ArrayList([]const u8)) !void {
        // Remove old reverse edges for this path
        if (self.forward.getPtr(path)) |old_deps| {
            for (old_deps.items) |old_dep| {
                if (self.reverse.getPtr(old_dep)) |rev_set| {
                    _ = rev_set.remove(path);
                }
            }
            old_deps.deinit(self.allocator);
        }

        // Set forward edge
        const gop = try self.forward.getOrPut(path);
        gop.key_ptr.* = path;
        gop.value_ptr.* = deps;

        // Add reverse edges: for each dep, record that `path` depends on it
        for (deps.items) |dep| {
            const rev_gop = try self.reverse.getOrPut(dep);
            if (!rev_gop.found_existing) {
                rev_gop.key_ptr.* = dep;
                rev_gop.value_ptr.* = std.StringHashMap(void).init(self.allocator);
            }
            try rev_gop.value_ptr.put(path, {});
        }
    }

    pub fn remove(self: *DependencyGraph, path: []const u8) void {
        // Remove forward edges and their reverse counterparts
        if (self.forward.getPtr(path)) |deps| {
            for (deps.items) |dep| {
                if (self.reverse.getPtr(dep)) |rev_set| {
                    _ = rev_set.remove(path);
                }
            }
            deps.deinit(self.allocator);
            _ = self.forward.remove(path);
        }
        // Remove path from reverse index (others importing this path)
        // The entries in reverse[path] are the files that import `path`.
        // We don't remove those — they still have forward edges pointing here.
        // We just remove the reverse key if nobody imports this path anymore.
        // Actually, we should NOT remove reverse[path] here — other files
        // still reference `path` in their forward edges. The reverse entry
        // is cleaned up lazily when those files are re-indexed or removed.
    }

    pub fn getForwardDeps(self: *const DependencyGraph, path: []const u8) ?[]const []const u8 {
        const deps = self.forward.get(path) orelse return null;
        return deps.items;
    }

    pub fn getImportedBy(self: *const DependencyGraph, path: []const u8, allocator: std.mem.Allocator) ![]const []const u8 {
        // Extract basename for matching (e.g., "src/store.zig" -> "store.zig")
        const basename = if (std.mem.lastIndexOfScalar(u8, path, '/')) |pos| path[pos + 1 ..] else path;

        var result: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (result.items) |p| allocator.free(p);
            result.deinit(allocator);
        }

        // O(1) lookup: check reverse index for exact path match
        if (self.reverse.get(path)) |rev_set| {
            var rev_iter = rev_set.keyIterator();
            while (rev_iter.next()) |key_ptr| {
                const dep_path = try allocator.dupe(u8, key_ptr.*);
                try result.append(allocator, dep_path);
            }
        }

        // Also check basename match (imports often use short names)
        if (!std.mem.eql(u8, path, basename)) {
            if (self.reverse.get(basename)) |rev_set| {
                var rev_iter = rev_set.keyIterator();
                while (rev_iter.next()) |key_ptr| {
                    // Avoid duplicates from exact path match above
                    var already = false;
                    for (result.items) |existing| {
                        if (std.mem.eql(u8, existing, key_ptr.*)) {
                            already = true;
                            break;
                        }
                    }
                    if (!already) {
                        const dep_path = try allocator.dupe(u8, key_ptr.*);
                        try result.append(allocator, dep_path);
                    }
                }
            }
        }

        return result.toOwnedSlice(allocator);
    }

    pub fn getTransitiveDependents(self: *const DependencyGraph, path: []const u8, allocator: std.mem.Allocator, max_depth: ?u32) ![]const []const u8 {
        const basename = if (std.mem.lastIndexOfScalar(u8, path, '/')) |pos| path[pos + 1 ..] else path;

        var visited = std.StringHashMap(void).init(allocator);
        defer visited.deinit();

        var queue: std.ArrayList(struct { path: []const u8, depth: u32 }) = .empty;
        defer queue.deinit(allocator);

        try visited.put(path, {});
        if (!std.mem.eql(u8, path, basename)) {
            try visited.put(basename, {});
        }
        try queue.append(allocator, .{ .path = path, .depth = 0 });
        if (!std.mem.eql(u8, path, basename)) {
            try queue.append(allocator, .{ .path = basename, .depth = 0 });
        }

        var result: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (result.items) |p| allocator.free(p);
            result.deinit(allocator);
        }

        var head: usize = 0;
        while (head < queue.items.len) {
            const item = queue.items[head];
            head += 1;

            const depth_limit = max_depth orelse std.math.maxInt(u32);
            if (item.depth >= depth_limit) continue;

            if (self.reverse.get(item.path)) |rev_set| {
                var rev_iter = rev_set.keyIterator();
                while (rev_iter.next()) |key_ptr| {
                    const dep = key_ptr.*;
                    if (!visited.contains(dep)) {
                        try visited.put(dep, {});
                        const dep_copy = try allocator.dupe(u8, dep);
                        try result.append(allocator, dep_copy);
                        try queue.append(allocator, .{ .path = dep, .depth = item.depth + 1 });

                        // Also enqueue basename for this dep
                        const dep_basename = if (std.mem.lastIndexOfScalar(u8, dep, '/')) |pos| dep[pos + 1 ..] else dep;
                        if (!std.mem.eql(u8, dep, dep_basename) and !visited.contains(dep_basename)) {
                            try visited.put(dep_basename, {});
                            try queue.append(allocator, .{ .path = dep_basename, .depth = item.depth + 1 });
                        }
                    }
                }
            }
        }

        return result.toOwnedSlice(allocator);
    }

    pub fn getTransitiveDependencies(self: *const DependencyGraph, path: []const u8, allocator: std.mem.Allocator, max_depth: ?u32) ![]const []const u8 {
        var visited = std.StringHashMap(void).init(allocator);
        defer visited.deinit();

        var queue: std.ArrayList(struct { path: []const u8, depth: u32 }) = .empty;
        defer queue.deinit(allocator);

        try visited.put(path, {});
        try queue.append(allocator, .{ .path = path, .depth = 0 });

        var result: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (result.items) |p| allocator.free(p);
            result.deinit(allocator);
        }

        var head: usize = 0;
        while (head < queue.items.len) {
            const item = queue.items[head];
            head += 1;

            const depth_limit = max_depth orelse std.math.maxInt(u32);
            if (item.depth >= depth_limit) continue;

            if (self.forward.get(item.path)) |fwd_deps| {
                for (fwd_deps.items) |dep| {
                    if (!visited.contains(dep)) {
                        try visited.put(dep, {});
                        const dep_copy = try allocator.dupe(u8, dep);
                        try result.append(allocator, dep_copy);
                        try queue.append(allocator, .{ .path = dep, .depth = item.depth + 1 });
                    }
                }
            }
        }

        return result.toOwnedSlice(allocator);
    }

    pub fn count(self: *const DependencyGraph) usize {
        return self.forward.count();
    }

    pub fn iterator(self: *const DependencyGraph) std.StringHashMap(std.ArrayList([]const u8)).Iterator {
        return self.forward.iterator();
    }

    pub fn get(self: *const DependencyGraph, key: []const u8) ?std.ArrayList([]const u8) {
        return self.forward.get(key);
    }

    pub fn keyIterator(self: *const DependencyGraph) std.StringHashMap(std.ArrayList([]const u8)).KeyIterator {
        return self.forward.keyIterator();
    }
};

pub const SymbolLocation = struct {
    path: []const u8,
    kind: SymbolKind,
    line_start: u32,
    line_end: u32,
};

pub fn matchGlob(pattern: []const u8, path: []const u8) bool {
    // Fast path: `**/*X` where X is a literal — degenerates to endsWith(X).
    // Covers the common agent-style pattern `**/*.ext`.
    if (globIsPureSuffix(pattern)) |suffix| {
        return std.mem.endsWith(u8, path, suffix);
    }
    // Fast path: literal prefix before any wildcard. If the path doesn't
    // start with that prefix, we can reject without recursing.
    var lit_end: usize = 0;
    while (lit_end < pattern.len) : (lit_end += 1) {
        const c = pattern[lit_end];
        if (c == '*' or c == '?' or c == '{') break;
    }
    if (lit_end > 0) {
        if (path.len < lit_end) return false;
        if (!std.mem.startsWith(u8, path, pattern[0..lit_end])) return false;
        if (lit_end == pattern.len) return path.len == lit_end;
    }
    return matchGlobRec(pattern, lit_end, path, lit_end);
}

/// If `pattern` is exactly `**/*X` for some literal X (no `*`/`?` in X),
/// returns X. Such patterns are equivalent to `endsWith(X)` because `**` may
/// absorb everything up to the last `/` and the trailing `*` consumes the
/// basename. Patterns like `*X` (single star) do NOT qualify because a single
/// `*` cannot cross `/`.
fn globIsPureSuffix(pattern: []const u8) ?[]const u8 {
    if (pattern.len < 4) return null;
    if (pattern[0] != '*' or pattern[1] != '*' or pattern[2] != '/' or pattern[3] != '*') return null;
    const tail = pattern[4..];
    for (tail) |c| if (c == '*' or c == '?' or c == '{' or c == '}') return null;
    return tail;
}

fn findBraceAlternatives(pattern: []const u8, open: usize) ?usize {
    var i = open + 1;
    var has_comma = false;
    while (i < pattern.len) : (i += 1) {
        switch (pattern[i]) {
            '{' => return null,
            ',' => has_comma = true,
            '}' => return if (has_comma) i else null,
            else => {},
        }
    }
    return null;
}

fn matchGlobFragmentThen(fragment: []const u8, gi_start: usize, path: []const u8, ti_start: usize, rest: []const u8) bool {
    var gi = gi_start;
    var ti = ti_start;
    while (gi < fragment.len) {
        const c = fragment[gi];
        if (c == '*') {
            if (gi + 1 < fragment.len and fragment[gi + 1] == '*') {
                var next = gi + 2;
                if (next < fragment.len and fragment[next] == '/') next += 1;
                if (matchGlobFragmentThen(fragment, next, path, ti, rest)) return true;
                var k: usize = ti;
                while (k < path.len) : (k += 1) {
                    if (matchGlobFragmentThen(fragment, next, path, k + 1, rest)) return true;
                }
                return false;
            } else {
                if (matchGlobFragmentThen(fragment, gi + 1, path, ti, rest)) return true;
                var k: usize = ti;
                while (k < path.len and path[k] != '/') : (k += 1) {
                    if (matchGlobFragmentThen(fragment, gi + 1, path, k + 1, rest)) return true;
                }
                return false;
            }
        } else if (c == '?') {
            if (ti >= path.len or path[ti] == '/') return false;
            gi += 1;
            ti += 1;
        } else {
            if (ti >= path.len or path[ti] != c) return false;
            gi += 1;
            ti += 1;
        }
    }
    return matchGlobRec(rest, 0, path, ti);
}

fn matchGlobRec(pattern: []const u8, gi_start: usize, path: []const u8, ti_start: usize) bool {
    var gi = gi_start;
    var ti = ti_start;
    while (gi < pattern.len) {
        const c = pattern[gi];
        if (c == '*') {
            if (gi + 1 < pattern.len and pattern[gi + 1] == '*') {
                // ** matches across path separators
                var rest = gi + 2;
                if (rest < pattern.len and pattern[rest] == '/') rest += 1;
                if (matchGlobRec(pattern, rest, path, ti)) return true;
                var k: usize = ti;
                while (k < path.len) : (k += 1) {
                    if (matchGlobRec(pattern, rest, path, k + 1)) return true;
                }
                return false;
            } else {
                // single * does not cross /
                if (matchGlobRec(pattern, gi + 1, path, ti)) return true;
                var k: usize = ti;
                while (k < path.len and path[k] != '/') : (k += 1) {
                    if (matchGlobRec(pattern, gi + 1, path, k + 1)) return true;
                }
                return false;
            }
        } else if (c == '?') {
            if (ti >= path.len or path[ti] == '/') return false;
            gi += 1;
            ti += 1;
        } else if (c == '{') {
            if (findBraceAlternatives(pattern, gi)) |close| {
                var alt_start = gi + 1;
                var i = alt_start;
                while (i <= close) : (i += 1) {
                    if (i == close or pattern[i] == ',') {
                        if (matchGlobFragmentThen(pattern[alt_start..i], 0, path, ti, pattern[close + 1 ..])) return true;
                        alt_start = i + 1;
                    }
                }
                return false;
            }
            if (ti >= path.len or path[ti] != c) return false;
            gi += 1;
            ti += 1;
        } else {
            if (ti >= path.len or path[ti] != c) return false;
            gi += 1;
            ti += 1;
        }
    }
    return ti == path.len;
}

/// Resolved call graph retained for path queries (#531). Node metadata slices
/// borrow stable outline/symbol strings; edges and adjacency are owned.
pub const CallGraph = struct {
    edges: []codegraph.Edge,
    adj: []std.ArrayList(codegraph.NodeId),
    node_path: []const []const u8,
    node_name: []const []const u8,
    node_line: []const u32,

    pub fn deinit(self: *CallGraph, allocator: std.mem.Allocator) void {
        allocator.free(self.edges);
        codegraph.freeAdjacency(allocator, self.adj);
        allocator.free(self.node_path);
        allocator.free(self.node_name);
        allocator.free(self.node_line);
    }
};

pub const CallPathStep = struct {
    path: []const u8,
    name: []const u8,
    line: u32,
};

pub const Explorer = struct {
    outlines: std.StringHashMap(FileOutline),
    dep_graph: DependencyGraph,
    contents: ContentCache,
    symbol_index: std.StringHashMap(std.ArrayList(SymbolLocation)),
    word_index: WordIndex,
    trigram_index: AnyTrigramIndex,
    /// Paths indexed with skip_trigram=true (past 15k cap or excluded).
    /// Used to restrict the searchContent fallback to only these files.
    skip_trigram_files: std.StringHashMap(void),
    allocator: std.mem.Allocator,
    word_index_complete: bool = true,
    word_index_can_load_from_disk: bool = false,
    word_index_generation: u64 = 0,
    word_index_persisted_generation: u64 = 0,
    /// When true, commitParsedFileOwnedOutline skips word_index.indexFile — the
    /// caller is building the word index in parallel per-worker shards and will
    /// merge them after the commit loop (see watcher.initialScanWithWorkerCount).
    defer_word_index: bool = false,
    mu: cio.RwLock = .{},
    /// Per-file call-graph centrality (PageRank by default, or in-degree when
    /// CODEDB_IN_DEGREE_CENTRALITY is set). Built lazily, used as an additive
    /// ranking boost in searchContentRanked. Null until built; guarded by
    /// centrality_build_mu. Keys are borrowed `outlines` keys (stable).
    call_centrality: ?std.StringHashMap(f32) = null,
    /// Retained resolved call graph (edges + adjacency + per-node metadata) for
    /// codedb_callpath. Built lazily alongside centrality; may be rebuilt after a
    /// snapshot load that restored centrality without edges.
    call_graph: ?CallGraph = null,
    centrality_build_mu: cio.Mutex = .{},
    root_dir: ?std.Io.Dir = null,
    io: ?std.Io = null,
    /// When non-null, append one JSON line per searchContent invocation
    /// to this path (v0 rerank-trace experiment). Borrowed; caller owns
    /// the slice for the Explorer's lifetime.
    rerank_trace_path: ?[]const u8 = null,
    /// Test-only counter: incremented each time the Tier 5 full-scan
    /// fallback in searchContent fires. Used by perf regression tests to
    /// assert the short-circuit holds (issue: negative-query slow path).
    /// Production code does not read this field.
    search_tier5_count: u64 = 0,
    last_search_breakdown: SearchBreakdown = .{},
    /// Buffers adopted from snapshot loads (the raw outline_state section).
    /// Restored FileOutlines borrow their import/symbol strings as slices into
    /// these (see FileOutline.borrows_strings), so they must outlive every
    /// restored outline; freed once here at Explorer.deinit.
    outline_section_bufs: std.ArrayList([]const u8) = .empty,
    /// mmap'd snapshot content sections adopted at load. The ContentCache stores
    /// borrowed (value_owned=false) slices into these for restored files, so they
    /// must outlive the cache; munmap'd once here at Explorer.deinit.
    content_section_maps: std.ArrayList([]align(std.heap.page_size_min) const u8) = .empty,

    /// Default file-content cache capacity. Was 16384, but on typical
    /// projects (≤2000 files) the cache only ever holds a few hundred
    /// entries — the other 14000+ slots are pure overhead (786 KB of
    /// metadata alone for the 16 384-slot Slot array). 4096 is plenty
    /// for 99% of repos; large monorepos can override via config or
    /// pass a custom value to Explorer.init.
    pub const DEFAULT_CONTENT_CACHE_CAPACITY: u32 = 4096;

    pub fn setRoot(self: *Explorer, io: std.Io, root_path: []const u8) void {
        self.io = io;
        self.root_dir = std.Io.Dir.cwd().openDir(io, root_path, .{}) catch null;
    }

    pub fn init(allocator: std.mem.Allocator, content_cache_capacity: u32) Explorer {
        return .{
            .outlines = std.StringHashMap(FileOutline).init(allocator),
            .dep_graph = DependencyGraph.init(allocator),
            .contents = ContentCache.init(allocator, content_cache_capacity),
            .symbol_index = std.StringHashMap(std.ArrayList(SymbolLocation)).init(allocator),
            .word_index = WordIndex.init(allocator),
            .trigram_index = .{ .heap = TrigramIndex.init(allocator) },
            .skip_trigram_files = std.StringHashMap(void).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Explorer) void {
        var iter = self.outlines.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.outlines.deinit();

        self.dep_graph.deinit();

        var sym_iter = self.symbol_index.iterator();
        while (sym_iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.symbol_index.deinit();

        self.contents.deinit();
        if (self.call_centrality) |*c| c.deinit();
        if (self.call_graph) |*cg| cg.deinit(self.allocator);

        self.word_index.deinit();
        self.trigram_index.deinit();
        self.skip_trigram_files.deinit();
        // Freed after outlines (above) since restored outlines borrow into these.
        for (self.outline_section_bufs.items) |b| self.allocator.free(b);
        self.outline_section_bufs.deinit(self.allocator);
        // munmap'd after contents.deinit (above): the cache holds borrowed slices
        // into these maps, but deinit skips freeing borrowed values, so the maps
        // are still valid through it and only released here.
        for (self.content_section_maps.items) |m| std.posix.munmap(m);
        self.content_section_maps.deinit(self.allocator);
        if (self.root_dir) |d| {
            if (self.io) |io| d.close(io);
        }
    }

    /// Take ownership of a snapshot outline_state section buffer that restored
    /// FileOutlines borrow their import/symbol strings from. Freed at deinit.
    pub fn adoptOutlineSection(self: *Explorer, buf: []const u8) !void {
        try self.outline_section_bufs.append(self.allocator, buf);
    }

    /// Take ownership of an mmap'd snapshot content section that the ContentCache
    /// borrows (value_owned=false) slices from. munmap'd at deinit.
    pub fn adoptContentSection(self: *Explorer, map: []align(std.heap.page_size_min) const u8) !void {
        try self.content_section_maps.append(self.allocator, map);
    }

    /// Number of slots in the heap trigram index id_to_path array (benchmark helper).
    pub fn trigramIdToPathLen(self: *Explorer) usize {
        return switch (self.trigram_index) {
            .heap => |*h| h.id_to_path.items.len,
            else => 0,
        };
    }

    /// Number of reusable free_ids slots in the heap trigram index (benchmark helper).
    pub fn trigramFreeIdsLen(self: *Explorer) usize {
        return switch (self.trigram_index) {
            .heap => |*h| h.free_ids.items.len,
            else => 0,
        };
    }
    pub fn releaseContents(self: *Explorer) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.contents.clear();
    }

    pub fn releaseSecondaryIndexes(self: *Explorer) void {
        self.mu.lock();
        defer self.mu.unlock();
    }

    pub fn indexFile(self: *Explorer, path: []const u8, content: []const u8) !void {
        return self.indexFileInner(path, content, true, false);
    }

    /// Fast path: index outline + content storage only, skip word/trigram indexes.
    pub fn indexFileOutlineOnly(self: *Explorer, path: []const u8, content: []const u8) !void {
        return self.indexFileInner(path, content, false, false);
    }

    /// Index outline + word index but skip trigram construction (used when trigram is loaded from disk cache).
    pub fn indexFileSkipTrigram(self: *Explorer, path: []const u8, content: []const u8) !void {
        return self.indexFileInner(path, content, true, true);
    }

    pub fn commitParsedFileOwnedOutline(self: *Explorer, path: []const u8, content: []const u8, outline: FileOutline, full_index: bool, skip_trigram: bool) !void {
        var owned_outline = outline;
        errdefer owned_outline.deinit();
        var persistent_outline = try cloneOutline(&owned_outline, self.allocator);
        defer owned_outline.deinit();
        errdefer persistent_outline.deinit();
        if (persistent_outline.owns_path) {
            self.allocator.free(persistent_outline.path);
            persistent_outline.owns_path = false;
        }

        self.mu.lock();
        defer self.mu.unlock();

        const outline_gop = try self.outlines.getOrPut(path);
        const is_new = !outline_gop.found_existing;
        var prior_outline: ?FileOutline = if (outline_gop.found_existing)
            outline_gop.value_ptr.*
        else
            null;
        const stable_path = if (outline_gop.found_existing) blk: {
            break :blk outline_gop.key_ptr.*;
        } else blk: {
            const duped = try self.allocator.dupe(u8, path);
            outline_gop.key_ptr.* = duped;
            break :blk duped;
        };
        errdefer if (is_new) {
            _ = self.outlines.remove(stable_path);
            self.allocator.free(stable_path);
        };

        persistent_outline.path = stable_path;

        const prior_content = self.contents.get(stable_path);
        try self.contents.put(stable_path, content);

        if (full_index) {
            if (!self.word_index_complete) {
                self.word_index_can_load_from_disk = false;
            }
            if (!self.defer_word_index) try self.word_index.indexFile(stable_path, content);
            // If trigram indexing fails below, restore word_index to its previous state
            // to prevent word_index and trigram_index from diverging.
            errdefer if (prior_content) |old| {
                self.word_index.indexFile(stable_path, old) catch {};
            } else {
                self.word_index.removeFile(stable_path);
            };
            if (self.word_index_complete) {
                self.word_index_generation +%= 1;
            }
            if (!skip_trigram) {
                try self.trigram_index.indexFile(stable_path, content);
                // sparse_ngram_index population removed — it duplicates
                // ~70% of trigram_index's recall on niche fuzzy queries
                // at the cost of substantial RSS. Tier 2 (sparse) in
                // searchContent now no-ops; tier 3 (skip_trigram_files)
                // + tier 5 (full-scan when !trigram_ruled_out) cover
                // the same surface area.
                _ = self.skip_trigram_files.remove(stable_path);
            } else {
                self.trigram_index.removeFile(stable_path);
                try self.skip_trigram_files.put(stable_path, {});
            }
        } else {
            // Outline-only path (snapshot load fallback, file-watcher incremental
            // updates, WASM fast-path). The file is in `outlines` + `contents` but
            // not in word_index or trigram_index — without this entry it would
            // also be absent from `skip_trigram_files`, dropping it out of every
            // search tier:
            //   • tier 1 (trigram candidates) — file not in trigram_index
            //   • tier 3 (skip_trigram_files scan) — file not in this set
            //   • tier 5 (full outline scan) — short-circuited by trigram_ruled_out
            // Registering here means tier 3 picks the file up via searchInContent.
            // See #507.
            try self.skip_trigram_files.put(stable_path, {});
        }

        try self.rebuildDepsFor(stable_path, &persistent_outline);
        self.rebuildSymbolIndexFor(stable_path, &persistent_outline, !is_new);

        outline_gop.value_ptr.* = persistent_outline;
        if (prior_outline) |*old_outline| old_outline.deinit();
    }

    fn computeSymbolEnds(content: []const u8, outline: *FileOutline) void {
        if (outline.symbols.items.len == 0) return;

        // Build a line offset table for O(1) line lookups
        var line_offsets: std.ArrayList(usize) = .empty;
        defer line_offsets.deinit(outline.allocator);
        line_offsets.append(outline.allocator, 0) catch return; // line 1 starts at offset 0
        for (content, 0..) |c, i| {
            if (c == '\n' and i + 1 <= content.len) {
                line_offsets.append(outline.allocator, i + 1) catch return;
            }
        }
        const total_lines: u32 = @intCast(line_offsets.items.len);

        const is_brace_lang = outline.language == .zig or outline.language == .c or
            outline.language == .cpp or outline.language == .typescript or
            outline.language == .javascript or outline.language == .rust or
            outline.language == .go_lang or outline.language == .php or
            outline.language == .dart or outline.language == .java or
            outline.language == .kotlin or outline.language == .svelte or
            outline.language == .vue or outline.language == .astro or
            outline.language == .css or outline.language == .scss or
            outline.language == .protobuf or outline.language == .mlir or
            outline.language == .tablegen;

        for (outline.symbols.items) |*sym| {
            // Skip single-line kinds
            switch (sym.kind) {
                .import, .variable, .constant, .comment_block, .type_alias, .macro_def => continue,
                else => {},
            }

            if (sym.line_start == 0 or sym.line_start > total_lines) continue;

            if (is_brace_lang) {
                sym.line_end = findBraceEnd(content, line_offsets.items, sym.line_start, total_lines, outline.language);
            } else if (outline.language == .python) {
                sym.line_end = findPythonEnd(content, line_offsets.items, sym.line_start, total_lines);
            } else if (outline.language == .ruby) {
                sym.line_end = findRubyEnd(content, line_offsets.items, sym.line_start, total_lines);
            }
        }
    }

    fn findBraceEnd(content: []const u8, line_offsets: []const usize, line_start: u32, total_lines: u32, language: Language) u32 {
        const start_idx = line_offsets[line_start - 1];
        var depth: i32 = 0;
        var found_open = false;
        var in_string: u8 = 0; // 0=none, '"', '\''
        var in_triple_quote: u8 = 0; // 0=none, '"', '\''
        var interp_depth: i32 = 0;
        var paren_depth: i32 = 0; // params/types before the body brace
        var in_line_comment = false;
        var in_block_comment = false;
        var i = start_idx;
        var current_line = line_start;

        while (i < content.len) : (i += 1) {
            const c = content[i];

            if (c == '\n') {
                current_line += 1;
                in_line_comment = false;
                // Bail out if no opening brace found within 10 lines
                if (!found_open and current_line > line_start + 24) return line_start;
                continue;
            }

            if (in_line_comment) continue;

            if (in_block_comment) {
                if (c == '*' and i + 1 < content.len and content[i + 1] == '/') {
                    in_block_comment = false;
                    i += 1;
                }
                continue;
            }

            if (in_triple_quote != 0) {
                if (c == in_triple_quote and i + 2 < content.len and
                    content[i + 1] == in_triple_quote and content[i + 2] == in_triple_quote)
                {
                    in_triple_quote = 0;
                    i += 2;
                }
                continue;
            }

            if (in_string != 0) {
                if (c == '\\') {
                    i += 1;
                } else if (language == .dart and interp_depth > 0) {
                    if (c == '{') {
                        interp_depth += 1;
                    } else if (c == '}') {
                        interp_depth -= 1;
                        if (interp_depth == 0) continue;
                    }
                } else if (c == in_string) {
                    in_string = 0;
                } else if (language == .dart and c == '$' and i + 1 < content.len and content[i + 1] == '{') {
                    interp_depth = 1;
                    i += 1;
                }
                continue;
            }

            // Check for comments
            if (c == '/' and i + 1 < content.len) {
                if (content[i + 1] == '/') {
                    in_line_comment = true;
                    continue;
                } else if (content[i + 1] == '*') {
                    in_block_comment = true;
                    i += 1;
                    continue;
                }
            }

            // Check for triple-quoted strings (Dart: ''' or """)
            if (language == .dart and (c == '"' or c == '\'')) {
                if (i + 2 < content.len and content[i + 1] == c and content[i + 2] == c) {
                    in_triple_quote = c;
                    i += 2;
                    continue;
                }
            }

            // Check for strings
            if (c == '"' or c == '\'') {
                in_string = c;
                continue;
            }

            if (c == '(') {
                if (!found_open) paren_depth += 1;
            } else if (c == ')') {
                if (!found_open and paren_depth > 0) paren_depth -= 1;
            } else if (c == '{') {
                // Before the body opens, only a brace at paren-depth 0 is the
                // body brace; braces inside the parameter list (inline object
                // types, default values) must be ignored, or a multi-line
                // signature gets a wrongly-short line_end. Once found_open, count
                // every brace so the body balances correctly.
                if (found_open or paren_depth == 0) {
                    depth += 1;
                    found_open = true;
                }
            } else if (c == '}') {
                if (found_open) {
                    depth -= 1;
                    if (depth == 0) return @min(current_line, total_lines);
                }
            }
        }

        return if (found_open) total_lines else line_start;
    }

    fn findPythonEnd(content: []const u8, line_offsets: []const usize, line_start: u32, total_lines: u32) u32 {
        if (line_start >= total_lines) return line_start;

        // Get the indent of the signature line
        const sig_offset = line_offsets[line_start - 1];
        const sig_indent = countIndent(content, sig_offset);

        // Find the colon-terminated signature (may span multiple lines)
        var body_start = line_start + 1;
        // Check if signature line itself has the colon
        {
            const line_end_offset = if (line_start < total_lines) line_offsets[line_start] else content.len;
            const sig_line = content[sig_offset..line_end_offset];
            if (std.mem.indexOf(u8, sig_line, ":") == null) {
                // Multi-line signature — skip ahead to find the colon
                var ln = line_start + 1;
                while (ln <= total_lines) : (ln += 1) {
                    const lo = line_offsets[ln - 1];
                    const le = if (ln < total_lines) line_offsets[ln] else content.len;
                    const line = content[lo..le];
                    if (std.mem.indexOf(u8, line, ":") != null) {
                        body_start = ln + 1;
                        break;
                    }
                }
            }
        }

        var last_body_line = line_start;
        var ln = body_start;
        while (ln <= total_lines) : (ln += 1) {
            const lo = line_offsets[ln - 1];
            const le = if (ln < total_lines) line_offsets[ln] else content.len;
            const line = content[lo..le];
            const trimmed = std.mem.trim(u8, line, " \t\r\n");

            // Blank lines and comments don't end the body
            if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "#")) {
                continue;
            }

            const indent = countIndent(content, lo);
            if (indent <= sig_indent) break;
            last_body_line = ln;
        }

        return if (last_body_line > line_start) last_body_line else line_start;
    }

    fn findRubyEnd(content: []const u8, line_offsets: []const usize, line_start: u32, total_lines: u32) u32 {
        if (line_start >= total_lines) return line_start;

        const sig_offset = line_offsets[line_start - 1];
        const sig_indent = countIndent(content, sig_offset);

        var ln = line_start + 1;
        while (ln <= total_lines) : (ln += 1) {
            const lo = line_offsets[ln - 1];
            const le = if (ln < total_lines) line_offsets[ln] else content.len;
            const line = content[lo..le];
            const trimmed = std.mem.trim(u8, line, " \t\r\n");

            if (std.mem.eql(u8, trimmed, "end")) {
                const indent = countIndent(content, lo);
                if (indent <= sig_indent) return ln;
            }
        }

        return line_start;
    }

    fn countIndent(content: []const u8, offset: usize) usize {
        var count: usize = 0;
        var i = offset;
        while (i < content.len and (content[i] == ' ' or content[i] == '\t')) : (i += 1) {
            count += if (content[i] == '\t') 4 else 1;
        }
        return count;
    }

    fn parseOutlineWithParser(parser: *Explorer, path: []const u8, content: []const u8) !FileOutline {
        var outline = FileOutline.init(parser.allocator, path);
        errdefer outline.deinit();
        outline.byte_size = content.len;

        var line_num: u32 = 0;
        var prev_line_trimmed: []const u8 = "";
        var php_state: PhpParseState = .{};
        var in_py_docstring = false;
        var in_block_comment = false;
        var in_go_import_block = false;
        var c_brace_depth: u32 = 0;
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            line_num += 1;
            var trimmed = std.mem.trim(u8, line, " \t");

            if (outline.language == .python) {
                const has_dq = std.mem.indexOf(u8, trimmed, "\"\"\"");
                const has_sq = std.mem.indexOf(u8, trimmed, "'''");
                const has_triple = has_dq != null or has_sq != null;
                if (in_py_docstring) {
                    if (has_triple) in_py_docstring = false;
                    continue;
                }
                if (has_triple) {
                    // Check if triple quote appears twice (single-line docstring like """text""")
                    const marker = if (has_dq != null) "\"\"\"" else "'''";
                    const first_pos = if (has_dq) |p| p else has_sq.?;
                    if (std.mem.indexOf(u8, trimmed[first_pos + 3 ..], marker) != null) {
                        // Opens and closes on same line — skip as a single-line docstring
                        continue;
                    }
                    in_py_docstring = true;
                    continue;
                }
            }

            if (outline.language == .ruby) {
                if (in_py_docstring) {
                    if (startsWith(line, "=end")) in_py_docstring = false;
                    continue;
                }
                if (startsWith(line, "=begin")) {
                    in_py_docstring = true;
                    continue;
                }
            }

            if (outline.language == .typescript or outline.language == .javascript or
                outline.language == .go_lang or outline.language == .c or
                outline.language == .cpp or outline.language == .rust or
                outline.language == .zig or outline.language == .hcl or
                outline.language == .dart or outline.language == .java or
                outline.language == .kotlin or outline.language == .svelte or
                outline.language == .vue or outline.language == .astro or
                outline.language == .css or outline.language == .scss or
                outline.language == .protobuf or outline.language == .mlir or
                outline.language == .tablegen or outline.language == .rescript)
            {
                if (in_block_comment) {
                    if (std.mem.indexOf(u8, trimmed, "*/")) |close_pos| {
                        in_block_comment = false;
                        const after = std.mem.trimStart(u8, trimmed[close_pos + 2 ..], " \t");
                        if (after.len == 0) continue;
                        trimmed = after;
                    } else continue;
                }
                if (std.mem.startsWith(u8, trimmed, "/*")) {
                    if (std.mem.indexOf(u8, trimmed[2..], "*/")) |close_pos| {
                        const after = std.mem.trimStart(u8, trimmed[2 + close_pos + 2 ..], " \t");
                        if (after.len == 0) continue;
                        trimmed = after;
                    } else {
                        in_block_comment = true;
                        continue;
                    }
                }
            }

            if (outline.language == .zig) {
                try parser.parseZigLine(trimmed, line_num, &outline);
            } else if (outline.language == .python) {
                try parser.parsePythonLine(trimmed, line_num, &outline);
            } else if (outline.language == .typescript or outline.language == .javascript) {
                try parser.parseTsLine(trimmed, line_num, &outline);
            } else if (outline.language == .c or outline.language == .cpp) {
                try parser.parseCLine(line, trimmed, line_num, &outline, prev_line_trimmed, &c_brace_depth);
            } else if (outline.language == .rust) {
                try parser.parseRustLine(trimmed, line_num, &outline, prev_line_trimmed);
            } else if (outline.language == .php) {
                try parser.parsePhpLine(trimmed, line_num, &outline, &php_state);
            } else if (outline.language == .go_lang) {
                if (in_go_import_block) {
                    if (startsWith(trimmed, ")")) {
                        in_go_import_block = false;
                    } else if (extractStringLiteral(trimmed)) |imp_path| {
                        try appendImportPath(parser.allocator, &outline, imp_path);
                        try appendOutlineSymbol(parser.allocator, &outline, trimmed, .import, line_num, null);
                    }
                } else if (std.mem.eql(u8, trimmed, "import (")) {
                    in_go_import_block = true;
                } else {
                    try parser.parseGoLine(trimmed, line_num, &outline);
                }
            } else if (outline.language == .dart) {
                try parser.parseDartLine(trimmed, line_num, &outline);
            } else if (outline.language == .ruby) {
                try parser.parseRubyLine(trimmed, line_num, &outline);
            } else if (outline.language == .hcl) {
                try parser.parseHclLine(trimmed, line_num, &outline);
            } else if (outline.language == .r) {
                try parser.parseRLine(trimmed, line_num, &outline);
            } else if (outline.language == .java) {
                try parser.parseJavaLine(trimmed, line_num, &outline);
            } else if (outline.language == .kotlin) {
                try parser.parseKotlinLine(trimmed, line_num, &outline);
            } else if (outline.language == .swift) {
                try parser.parseSwiftLine(trimmed, line_num, &outline);
            } else if (outline.language == .svelte or outline.language == .vue or outline.language == .astro) {
                try parser.parseComponentLine(trimmed, line_num, &outline);
            } else if (outline.language == .shell) {
                try parser.parseShellLine(trimmed, line_num, &outline);
            } else if (outline.language == .css or outline.language == .scss) {
                try parser.parseStyleLine(trimmed, line_num, &outline);
            } else if (outline.language == .sql) {
                try parser.parseSqlLine(trimmed, line_num, &outline);
            } else if (outline.language == .protobuf) {
                try parser.parseProtoLine(trimmed, line_num, &outline);
            } else if (outline.language == .fortran) {
                try parser.parseFortranLine(trimmed, line_num, &outline);
            } else if (outline.language == .llvm_ir) {
                try parser.parseLlvmIrLine(trimmed, line_num, &outline);
            } else if (outline.language == .mlir) {
                try parser.parseMlirLine(trimmed, line_num, &outline);
            } else if (outline.language == .tablegen) {
                try parser.parseTableGenLine(trimmed, line_num, &outline);
            } else if (outline.language == .rescript) {
                try parser.parseRescriptLine(trimmed, line_num, &outline);
            }

            prev_line_trimmed = trimmed;
        }
        outline.line_count = line_num;
        computeSymbolEnds(content, &outline);
        return outline;
    }

    pub fn parseContentForIndexing(allocator: std.mem.Allocator, path: []const u8, content: []const u8) !ParsedFile {
        var parser = Explorer.init(allocator, DEFAULT_CONTENT_CACHE_CAPACITY);
        defer parser.deinit();
        var parsed_outline = try parseOutlineWithParser(&parser, path, content);
        defer parsed_outline.deinit();
        return .{
            .content = content,
            .outline = try cloneOutline(&parsed_outline, allocator),
        };
    }

    fn indexFileInner(self: *Explorer, path: []const u8, content: []const u8, full_index: bool, skip_trigram: bool) !void {
        const parsed = try parseContentForIndexing(self.allocator, path, content);
        return self.commitParsedFileOwnedOutline(path, parsed.content, parsed.outline, full_index, skip_trigram);
    }
    /// Rebuild trigram index from the stored file contents.
    /// Used after a cache hit to populate trigrams when they were skipped during the fast scan.
    pub fn rebuildTrigrams(self: *Explorer) !void {
        self.mu.lock();
        defer self.mu.unlock();
        var iter = self.contents.iterator();
        while (iter.next()) |entry| {
            // Skip large files to prevent OOM on large repos
            if (entry.value_ptr.*.len > 1024 * 1024) continue;
            self.trigram_index.indexFile(entry.key_ptr.*, entry.value_ptr.*) catch |err| switch (err) {
                error.OutOfMemory => {
                    std.log.warn("trigram OOM, skipping remaining files", .{});
                    return;
                },
            };
        }
    }

    /// Rebuild the inverted word index from cached contents when complete, or
    /// by streaming source files from the project root when the content cache
    /// was capped during fast snapshot restore.
    pub fn rebuildWordIndex(self: *Explorer) !void {
        const source_paths = blk: {
            self.mu.lockShared();
            defer self.mu.unlockShared();

            if (self.contents.len() == self.outlines.count()) break :blk null;
            if (self.io == null or self.root_dir == null) return error.WordIndexIncomplete;

            var paths: std.ArrayList([]u8) = .empty;
            errdefer {
                for (paths.items) |path| self.allocator.free(path);
                paths.deinit(self.allocator);
            }
            try paths.ensureTotalCapacity(self.allocator, self.outlines.count());
            var iter = self.outlines.keyIterator();
            while (iter.next()) |path_ptr| {
                paths.appendAssumeCapacity(try self.allocator.dupe(u8, path_ptr.*));
            }
            break :blk try paths.toOwnedSlice(self.allocator);
        };
        defer if (source_paths) |paths| {
            for (paths) |path| self.allocator.free(path);
            self.allocator.free(paths);
        };

        var rebuilt = WordIndex.init(self.allocator);
        errdefer rebuilt.deinit();

        if (source_paths) |paths| {
            const io = self.io orelse return error.WordIndexIncomplete;
            const dir = self.root_dir orelse return error.WordIndexIncomplete;
            for (paths) |path| {
                const content = try dir.readFileAlloc(io, path, self.allocator, .limited(64 * 1024 * 1024));
                errdefer self.allocator.free(content);
                try rebuilt.indexFile(path, content);
                self.allocator.free(content);
            }
        } else {
            self.mu.lockShared();
            defer self.mu.unlockShared();
            var iter = self.contents.iterator();
            while (iter.next()) |entry| {
                try rebuilt.indexFile(entry.key_ptr.*, entry.value_ptr.*);
            }
        }

        self.mu.lock();
        defer self.mu.unlock();
        self.word_index.deinit();
        self.word_index = rebuilt;
        self.word_index_generation +%= 1;
        self.word_index_complete = true;
        self.word_index_can_load_from_disk = false;
    }

    pub fn markWordIndexIncomplete(self: *Explorer, can_load_from_disk: bool) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.word_index.deinit();
        self.word_index = WordIndex.init(self.allocator);
        self.word_index_complete = false;
        self.word_index_can_load_from_disk = can_load_from_disk;
    }

    /// Declare that the current in-memory word_index holds the complete,
    /// persisted-to-disk state. Warm queries will skip rebuild/reload.
    pub fn markWordIndexAsComplete(self: *Explorer) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.word_index_complete = true;
        self.word_index_can_load_from_disk = false;
        self.word_index_persisted_generation = self.word_index_generation;
    }

    pub fn disableWordIndexDiskLoad(self: *Explorer) void {
        self.mu.lock();
        defer self.mu.unlock();
        if (!self.word_index_complete) {
            self.word_index_can_load_from_disk = false;
        }
    }

    pub fn wordIndexCanLoadFromDisk(self: *Explorer) bool {
        self.mu.lockShared();
        defer self.mu.unlockShared();
        return !self.word_index_complete and self.word_index_can_load_from_disk;
    }

    pub fn wordIndexIsComplete(self: *Explorer) bool {
        self.mu.lockShared();
        defer self.mu.unlockShared();
        return self.word_index_complete;
    }

    pub fn wordIndexNeedsPersist(self: *Explorer) bool {
        self.mu.lockShared();
        defer self.mu.unlockShared();
        return self.word_index_complete and self.word_index_generation != self.word_index_persisted_generation;
    }

    pub fn wordIndexGenerationToPersist(self: *Explorer) ?u64 {
        self.mu.lockShared();
        defer self.mu.unlockShared();
        if (!self.word_index_complete) return null;
        if (self.word_index_generation == self.word_index_persisted_generation) return null;
        return self.word_index_generation;
    }

    pub fn markWordIndexPersisted(self: *Explorer, generation: u64) void {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.word_index_complete and self.word_index_generation == generation) {
            self.word_index_persisted_generation = generation;
        }
    }

    pub fn replaceWordIndex(self: *Explorer, word_index: WordIndex) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.word_index.deinit();
        self.word_index = word_index;
        self.word_index_generation +%= 1;
        self.word_index_complete = true;
        self.word_index_can_load_from_disk = false;
        self.word_index_persisted_generation = self.word_index_generation;
    }

    pub fn removeFile(self: *Explorer, path: []const u8) void {
        self.mu.lock();
        defer self.mu.unlock();
        if (!self.word_index_complete) {
            self.word_index_can_load_from_disk = false;
        } else {
            self.word_index_generation +%= 1;
        }
        self.dep_graph.remove(path);
        self.removeSymbolIndexFor(path);
        self.contents.remove(path);
        self.word_index.removeFile(path);
        self.trigram_index.removeFile(path);

        if (self.outlines.fetchRemove(path)) |kv| {
            var outline = kv.value;
            outline.deinit();
            self.allocator.free(kv.key);
        }
    }

    pub fn getOutline(self: *Explorer, path: []const u8, allocator: std.mem.Allocator) !?FileOutline {
        self.mu.lockShared();
        defer self.mu.unlockShared();

        const outline = self.outlines.getPtr(path) orelse return null;
        return try cloneOutline(outline, allocator);
    }

    /// Render the outline for `path` directly into `out` without cloning.
    /// Returns false if the file isn't indexed. Holds the read lock for
    /// the duration of the render — fast on small outlines, marginally
    /// slower than cloneOutline for large ones (which copy then render
    /// later). Saves the per-symbol allocations + path/detail dup that
    /// cloneOutline performs. See codedb_outline bench (66 µs → ~35 µs).
    pub fn renderOutline(
        self: *Explorer,
        path: []const u8,
        alloc: std.mem.Allocator,
        out: *std.ArrayList(u8),
        compact: bool,
    ) !bool {
        self.mu.lockShared();
        defer self.mu.unlockShared();

        const outline = self.outlines.getPtr(path) orelse return false;
        try out.ensureUnusedCapacity(alloc, 128 + outline.symbols.items.len * 128);
        const w = cio.listWriter(out, alloc);
        w.print("{s} ({s}, {d} lines, {d} bytes)\n", .{
            outline.path, @tagName(outline.language), outline.line_count, outline.byte_size,
        }) catch {};
        for (outline.symbols.items) |sym| {
            if (compact) {
                w.print("  L{d}: {s} {s}\n", .{ sym.line_start, @tagName(sym.kind), sym.name }) catch {};
            } else {
                w.print("  L{d}: {s} {s}", .{ sym.line_start, @tagName(sym.kind), sym.name }) catch {};
                if (sym.detail) |d| w.print("  // {s}", .{d}) catch {};
                w.writeAll("\n") catch {};
            }
        }
        return true;
    }

    /// Signature-only "skeleton" view: each symbol's declaration line with its
    /// body elided as "{ … N lines }". A large file collapses to ~one line per
    /// symbol — lossless at the API surface, so an agent can grasp a file's
    /// shape cheaply and codedb_read a range to expand a body. Mirrors
    /// renderOutline's locking and header. Returns false when not indexed.
    pub fn renderSkeleton(
        self: *Explorer,
        path: []const u8,
        alloc: std.mem.Allocator,
        out: *std.ArrayList(u8),
    ) !bool {
        self.mu.lockShared();
        defer self.mu.unlockShared();

        const outline = self.outlines.getPtr(path) orelse return false;
        const ref_opt = self.readContentForSearch(path, alloc);
        defer if (ref_opt) |r| r.deinit();
        const content: []const u8 = if (ref_opt) |r| r.data else "";

        // One pass to record the byte offset of each line start (line 1 → offsets[0]).
        var offsets: std.ArrayList(usize) = .empty;
        defer offsets.deinit(alloc);
        try offsets.append(alloc, 0);
        for (content, 0..) |ch, i| {
            if (ch == '\n') try offsets.append(alloc, i + 1);
        }

        try out.ensureUnusedCapacity(alloc, 128 + outline.symbols.items.len * 96);
        const w = cio.listWriter(out, alloc);
        w.print("{s} ({s}, {d} lines, {d} bytes)\n", .{
            outline.path, @tagName(outline.language), outline.line_count, outline.byte_size,
        }) catch {};

        const body_start = out.items.len;
        var covered_until: u32 = 0;
        var elided: u32 = 0;
        for (outline.symbols.items) |sym| {
            // Skip symbols nested inside an already-emitted symbol's body — a
            // skeleton shows the file's top-level shape, with bodies (and the
            // local declarations inside them) elided.
            if (sym.line_start <= covered_until) continue;
            covered_until = @max(covered_until, sym.line_end);
            const first = lineSlice(content, offsets.items, sym.line_start);
            const sig = std.mem.trim(u8, first, " \t\r");
            // Single-line symbol (imports, consts, one-liners) or no source: keep verbatim.
            if (sym.line_end <= sym.line_start or sig.len == 0) {
                if (sig.len == 0) {
                    w.print("  L{d}: {s} {s}\n", .{ sym.line_start, @tagName(sym.kind), sym.name }) catch {};
                } else {
                    w.print("  L{d}: {s}\n", .{ sym.line_start, sig }) catch {};
                }
                continue;
            }
            const hidden = sym.line_end - sym.line_start;
            elided += 1;
            if (std.mem.indexOfScalar(u8, sig, '{')) |bpos| {
                // Brace body opens on the declaration line: keep up to and including '{', stub the rest.
                w.print("  L{d}: {s} … {d} lines }}\n", .{ sym.line_start, sig[0 .. bpos + 1], hidden }) catch {};
            } else {
                // No brace on the first line (Python ':' / multi-line signature).
                w.print("  L{d}: {s} … {d} lines\n", .{ sym.line_start, sig, hidden }) catch {};
            }
        }
        // Escalation footer — skeleton fails safe by eliding bodies, so tell
        // the model exactly how to recover when it isn't enough.
        const skel_bytes = out.items.len - body_start;
        const full_bytes: usize = @intCast(outline.byte_size);
        if (elided == 0) {
            w.print("— skeleton: all symbols shown inline · codedb_read {s} for source · codedb_outline {s} for members\n", .{ outline.path, outline.path }) catch {};
        } else if (full_bytes == 0 or skel_bytes * 2 >= full_bytes) {
            w.print("— skeleton: {d} bodies elided; small file ({d}B) · codedb_read {s} for full source · codedb_outline {s} for members\n", .{ elided, full_bytes, outline.path, outline.path }) catch {};
        } else {
            const saved = 100 - (skel_bytes * 100 / full_bytes);
            w.print("— skeleton: {d} bodies elided (~{d}% smaller than {d}B) · expand a body: codedb_read {s} -L <start>-<end> · members: codedb_outline {s}\n", .{ elided, saved, full_bytes, outline.path, outline.path }) catch {};
        }
        return true;
    }

    /// Byte slice of 1-indexed `line` from `content`, given precomputed line
    /// start offsets. Returns empty when out of range.
    fn lineSlice(content: []const u8, offsets: []const usize, line: u32) []const u8 {
        if (line == 0 or line > offsets.len) return "";
        const start = offsets[line - 1];
        if (start > content.len) return "";
        const end = if (line < offsets.len) offsets[line] -| 1 else content.len;
        const e = @min(end, content.len);
        if (e < start) return "";
        return content[start..e];
    }

    /// Return a caller-owned copy of cached file content.
    pub fn getContent(self: *Explorer, path: []const u8, allocator: std.mem.Allocator) !?[]u8 {
        self.mu.lockShared();
        defer self.mu.unlockShared();
        const ref = self.readContentForSearch(path, allocator) orelse return null;
        if (ref.owned) return @constCast(ref.data);
        return try allocator.dupe(u8, ref.data);
    }

    pub const ReadRenderOptions = struct {
        if_hash: ?[]const u8 = null,
        line_start: ?i64 = null,
        line_end: ?i64 = null,
        compact: bool = false,
    };

    /// Render from the in-memory content cache without duplicating the whole
    /// file. Returns false when the path is not cached, so callers can fall
    /// back to their existing disk-read path.
    pub fn renderCachedRead(
        self: *Explorer,
        path: []const u8,
        allocator: std.mem.Allocator,
        out: *std.ArrayList(u8),
        opts: ReadRenderOptions,
    ) !bool {
        self.mu.lockShared();
        defer self.mu.unlockShared();

        const content = self.contents.get(path) orelse return false;
        try renderReadBytes(path, content, allocator, out, opts);
        return true;
    }

    const ContentRef = struct {
        data: []const u8,
        owned: bool, // true = caller must free; false = borrowed from cache
        allocator: std.mem.Allocator,

        fn deinit(self: ContentRef) void {
            if (self.owned) self.allocator.free(self.data);
        }
    };

    /// Get content: zero-copy from cache, or read from disk (caller-owned).
    fn readContentForSearch(self: *Explorer, path: []const u8, allocator: std.mem.Allocator) ?ContentRef {
        if (self.contents.get(path)) |cached| {
            return .{ .data = cached, .owned = false, .allocator = allocator };
        }
        const io = self.io orelse return null;
        const dir = self.root_dir orelse std.Io.Dir.cwd();
        const data = dir.readFileAlloc(io, path, allocator, .limited(512 * 1024)) catch return null;
        return .{ .data = data, .owned = true, .allocator = allocator };
    }

    fn renderReadBytes(
        path: []const u8,
        content: []const u8,
        allocator: std.mem.Allocator,
        out: *std.ArrayList(u8),
        opts: ReadRenderOptions,
    ) !void {
        const probe_len = @min(content.len, 8 * 1024);
        if (std.mem.indexOfScalar(u8, content[0..probe_len], 0) != null) {
            const w0 = cio.listWriter(out, allocator);
            const hash_b = std.hash.Wyhash.hash(0, content);
            try w0.print("binary file: {d} bytes  hash:{x}\n", .{ content.len, hash_b });
            return;
        }

        try out.ensureUnusedCapacity(allocator, if (opts.line_start != null or opts.line_end != null or opts.compact) 2048 else @min(content.len + 64, 64 * 1024));
        const hash = std.hash.Wyhash.hash(0, content);
        var hash_buf: [16]u8 = undefined;
        const hash_str = std.fmt.bufPrint(&hash_buf, "{x}", .{hash}) catch "";
        if (opts.if_hash) |prev| {
            if (std.mem.eql(u8, prev, hash_str)) {
                try out.appendSlice(allocator, "unchanged:");
                try out.appendSlice(allocator, hash_str);
                return;
            }
        }

        const w = cio.listWriter(out, allocator);
        try w.print("hash:{s}\n", .{hash_str});

        const has_range = opts.line_start != null or opts.line_end != null;
        if (has_range or opts.compact) {
            const start: u32 = if (opts.line_start) |n| @intCast(@min(@max(1, n), std.math.maxInt(u32))) else 1;
            const end: u32 = if (opts.line_end) |n| @intCast(@min(@max(1, n), std.math.maxInt(u32))) else std.math.maxInt(u32);
            const lang = detectLanguage(path);
            try appendExtractedLines(content, start, end, true, opts.compact, lang, allocator, out);
        } else {
            try out.appendSlice(allocator, content);
        }
    }

    pub fn cloneOutline(src: *const FileOutline, allocator: std.mem.Allocator) !FileOutline {
        const copied_path = try allocator.dupe(u8, src.path);
        // No errdefer here: dst.deinit() below handles freeing copied_path via owns_path.

        var dst = FileOutline.init(allocator, copied_path);
        dst.owns_path = true;
        errdefer dst.deinit();
        dst.line_count = src.line_count;
        dst.byte_size = src.byte_size;
        for (src.symbols.items) |sym| {
            const copied_name = try allocator.dupe(u8, sym.name);
            errdefer allocator.free(copied_name);

            const copied_detail = if (sym.detail) |d| blk: {
                const detail = try allocator.dupe(u8, d);
                break :blk detail;
            } else null;
            errdefer if (copied_detail) |d| allocator.free(d);

            try dst.symbols.append(allocator, .{
                .name = copied_name,
                .kind = sym.kind,
                .line_start = sym.line_start,
                .line_end = sym.line_end,
                .detail = copied_detail,
            });
        }
        for (src.imports.items) |imp| {
            const copied_import = try allocator.dupe(u8, imp);
            errdefer allocator.free(copied_import);
            try dst.imports.append(allocator, copied_import);
        }

        return dst;
    }

    pub fn getTree(self: *Explorer, allocator: std.mem.Allocator, use_color: bool) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try self.renderTree(allocator, &out, use_color);
        return try out.toOwnedSlice(allocator);
    }

    /// Stream the tree representation directly into `out` without going
    /// through an intermediate Allocating writer + toOwnedSlice + copy
    /// into the caller's buffer. Halves the allocation churn on the
    /// MCP codedb_tree path.
    pub fn renderTree(self: *Explorer, allocator: std.mem.Allocator, out: *std.ArrayList(u8), use_color: bool) !void {
        const s = @import("style.zig").style(use_color);

        self.mu.lockShared();
        defer self.mu.unlockShared();

        const writer = cio.listWriter(out, allocator);

        var paths: std.ArrayList([]const u8) = .empty;
        defer paths.deinit(allocator);

        var iter = self.outlines.iterator();
        while (iter.next()) |entry| {
            try paths.append(allocator, entry.key_ptr.*);
        }

        std.mem.sort([]const u8, paths.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);

        var seen_dirs = std.StringHashMap(void).init(allocator);
        defer seen_dirs.deinit();

        for (paths.items) |path| {
            const outline = self.outlines.get(path) orelse continue;

            // Emit directory nodes we haven't seen yet
            var prefix_end: usize = 0;
            while (std.mem.indexOfScalarPos(u8, path, prefix_end, '/')) |sep| {
                const dir = path[0 .. sep + 1];
                if (!seen_dirs.contains(dir)) {
                    try seen_dirs.put(dir, {});
                    const depth = std.mem.count(u8, dir[0..sep], "/");
                    for (0..depth) |_| try writer.writeAll("  ");
                    const dir_name = path[if (depth > 0) std.mem.lastIndexOfScalar(u8, dir[0..sep], '/').? + 1 else 0..sep];
                    try writer.print("{s}{s}/{s}\n", .{ s.bold, dir_name, s.reset });
                }
                prefix_end = sep + 1;
            }

            // Emit file leaf
            const depth = std.mem.count(u8, path, "/");
            for (0..depth) |_| try writer.writeAll("  ");
            const basename = if (std.mem.lastIndexOfScalar(u8, path, '/')) |pos| path[pos + 1 ..] else path;
            const lang = @tagName(outline.language);
            try writer.print("{s}  {s}{s}{s}  {s}{d}L  {d} sym{s}\n", .{
                basename,
                s.langColor(lang),
                lang,
                s.reset,
                s.dim,
                outline.line_count,
                outline.symbols.items.len,
                s.reset,
            });
        }
    }

    pub fn findSymbol(self: *Explorer, name: []const u8, allocator: std.mem.Allocator) !?struct { path: []const u8, symbol: Symbol } {
        self.mu.lockShared();
        defer self.mu.unlockShared();

        // O(1) lookup via symbol_index
        if (self.symbol_index.get(name)) |locs| {
            if (locs.items.len > 0) {
                const loc = locs.items[0];
                // Fetch detail from outline
                var detail: ?[]const u8 = null;
                if (self.outlines.getPtr(loc.path)) |outline| {
                    for (outline.symbols.items) |sym| {
                        if (sym.line_start == loc.line_start and std.mem.eql(u8, sym.name, name)) {
                            detail = if (sym.detail) |d| try allocator.dupe(u8, d) else null;
                            break;
                        }
                    }
                }
                return .{
                    .path = try allocator.dupe(u8, loc.path),
                    .symbol = .{
                        .name = try allocator.dupe(u8, name),
                        .kind = loc.kind,
                        .line_start = loc.line_start,
                        .line_end = loc.line_end,
                        .detail = detail,
                    },
                };
            }
        }

        // Fallback: scan outlines (handles edge cases during index build)
        var iter = self.outlines.iterator();
        while (iter.next()) |entry| {
            for (entry.value_ptr.symbols.items) |sym| {
                if (std.mem.eql(u8, sym.name, name)) {
                    return .{
                        .path = try allocator.dupe(u8, entry.key_ptr.*),
                        .symbol = .{
                            .name = try allocator.dupe(u8, sym.name),
                            .kind = sym.kind,
                            .line_start = sym.line_start,
                            .line_end = sym.line_end,
                            .detail = if (sym.detail) |d| try allocator.dupe(u8, d) else null,
                        },
                    };
                }
            }
        }
        return null;
    }

    pub fn findAllSymbols(self: *Explorer, name: []const u8, allocator: std.mem.Allocator) ![]const SymbolResult {
        self.mu.lockShared();
        defer self.mu.unlockShared();

        var result_list: std.ArrayList(SymbolResult) = .empty;
        errdefer result_list.deinit(allocator);

        const indexed_locs: []const SymbolLocation = if (self.symbol_index.get(name)) |locs| locs.items else &.{};

        for (indexed_locs) |loc| {
            var detail: ?[]const u8 = null;
            if (self.outlines.getPtr(loc.path)) |outline| {
                for (outline.symbols.items) |sym| {
                    if (sym.line_start == loc.line_start and std.mem.eql(u8, sym.name, name)) {
                        detail = if (sym.detail) |d| try allocator.dupe(u8, d) else null;
                        break;
                    }
                }
            }
            try result_list.append(allocator, .{
                .path = try allocator.dupe(u8, loc.path),
                .symbol = .{
                    .name = try allocator.dupe(u8, name),
                    .kind = loc.kind,
                    .line_start = loc.line_start,
                    .line_end = loc.line_end,
                    .detail = detail,
                },
            });
        }

        // Safety scan: append any outline symbols the index missed.
        const LocLookup = struct {
            fn contains(locs: []const SymbolLocation, path: []const u8, line_start: u32) bool {
                for (locs) |loc| {
                    if (loc.line_start == line_start and std.mem.eql(u8, loc.path, path)) return true;
                }
                return false;
            }
        };
        var iter = self.outlines.iterator();
        while (iter.next()) |entry| {
            for (entry.value_ptr.symbols.items) |sym| {
                if (!std.mem.eql(u8, sym.name, name)) continue;
                if (LocLookup.contains(indexed_locs, entry.key_ptr.*, sym.line_start)) continue;
                try result_list.append(allocator, .{
                    .path = try allocator.dupe(u8, entry.key_ptr.*),
                    .symbol = .{
                        .name = try allocator.dupe(u8, sym.name),
                        .kind = sym.kind,
                        .line_start = sym.line_start,
                        .line_end = sym.line_end,
                        .detail = if (sym.detail) |d| try allocator.dupe(u8, d) else null,
                    },
                });
            }
        }
        return result_list.toOwnedSlice(allocator);
    }

    pub const SymbolSearchSpec = struct {
        name: ?[]const u8 = null,
        prefix: ?[]const u8 = null,
        pattern: ?[]const u8 = null,
        kind: ?SymbolKind = null,
        fuzzy: bool = false,
        max_results: usize = 50,
    };

    pub const ScoredSymbolResult = struct {
        path: []const u8,
        symbol: Symbol,
        score: f32,
    };

    pub fn parseSymbolKind(s: []const u8) ?SymbolKind {
        if (std.mem.eql(u8, s, "interface")) return .interface_def;
        if (std.mem.eql(u8, s, "struct")) return .struct_def;
        if (std.mem.eql(u8, s, "enum")) return .enum_def;
        if (std.mem.eql(u8, s, "method")) return .method;
        if (std.mem.eql(u8, s, "function")) return .function;
        if (std.mem.eql(u8, s, "class")) return .class_def;
        return std.meta.stringToEnum(SymbolKind, s);
    }

    pub fn skipTrigramFileCount(self: *Explorer) usize {
        self.mu.lockShared();
        defer self.mu.unlockShared();
        return self.skip_trigram_files.count();
    }

    fn symbolMatchScore(spec: SymbolSearchSpec, name: []const u8) ?f32 {
        const has_name = spec.name != null or spec.prefix != null or spec.pattern != null or spec.fuzzy;
        if (!has_name) return 1.0;
        if (spec.name) |n| {
            if (spec.fuzzy) return fuzzyScore(n, name);
            if (!std.mem.eql(u8, name, n)) return null;
            return 1.0;
        }
        if (spec.prefix) |p| {
            if (!std.mem.startsWith(u8, name, p)) return null;
            return 0.95;
        }
        if (spec.pattern) |pat| {
            if (!matchGlob(pat, name)) return null;
            return 0.9;
        }
        return null;
    }

    pub fn searchSymbols(self: *Explorer, spec: SymbolSearchSpec, allocator: std.mem.Allocator) ![]ScoredSymbolResult {
        self.mu.lockShared();
        defer self.mu.unlockShared();

        var list: std.ArrayList(ScoredSymbolResult) = .empty;
        errdefer {
            for (list.items) |r| {
                allocator.free(r.path);
                allocator.free(r.symbol.name);
                if (r.symbol.detail) |d| allocator.free(d);
            }
            list.deinit(allocator);
        }

        const Dedup = struct {
            fn contains(items: []const ScoredSymbolResult, path: []const u8, line: u32) bool {
                for (items) |r| {
                    if (r.symbol.line_start == line and std.mem.eql(u8, r.path, path)) return true;
                }
                return false;
            }
        };

        const appendOne = struct {
            fn call(
                list_ptr: *std.ArrayList(ScoredSymbolResult),
                alloc: std.mem.Allocator,
                path: []const u8,
                sym: Symbol,
                score: f32,
            ) !void {
                if (Dedup.contains(list_ptr.items, path, sym.line_start)) return;
                try list_ptr.append(alloc, .{
                    .path = try alloc.dupe(u8, path),
                    .symbol = .{
                        .name = try alloc.dupe(u8, sym.name),
                        .kind = sym.kind,
                        .line_start = sym.line_start,
                        .line_end = sym.line_end,
                        .detail = if (sym.detail) |d| try alloc.dupe(u8, d) else null,
                    },
                    .score = score,
                });
            }
        }.call;

        var sym_iter = self.symbol_index.iterator();
        while (sym_iter.next()) |entry| {
            const sym_name = entry.key_ptr.*;
            const score = symbolMatchScore(spec, sym_name) orelse continue;
            for (entry.value_ptr.items) |loc| {
                if (spec.kind) |k| if (loc.kind != k) continue;
                var detail: ?[]const u8 = null;
                if (self.outlines.getPtr(loc.path)) |outline| {
                    for (outline.symbols.items) |sym| {
                        if (sym.line_start == loc.line_start and std.mem.eql(u8, sym.name, sym_name)) {
                            detail = sym.detail;
                            break;
                        }
                    }
                }
                try appendOne(&list, allocator, loc.path, .{
                    .name = sym_name,
                    .kind = loc.kind,
                    .line_start = loc.line_start,
                    .line_end = loc.line_end,
                    .detail = detail,
                }, score);
                if (list.items.len >= spec.max_results) break;
            }
            if (list.items.len >= spec.max_results) break;
        }

        var ol_iter = self.outlines.iterator();
        while (ol_iter.next()) |entry| {
            for (entry.value_ptr.symbols.items) |sym| {
                const score = symbolMatchScore(spec, sym.name) orelse continue;
                if (spec.kind) |k| if (sym.kind != k) continue;
                if (Dedup.contains(list.items, entry.key_ptr.*, sym.line_start)) continue;
                try appendOne(&list, allocator, entry.key_ptr.*, sym, score);
                if (list.items.len >= spec.max_results) break;
            }
            if (list.items.len >= spec.max_results) break;
        }

        const SortCtx = struct {
            pub fn lessThan(_: void, a: ScoredSymbolResult, b: ScoredSymbolResult) bool {
                if (a.score != b.score) return a.score > b.score;
                const name_cmp = std.mem.order(u8, a.symbol.name, b.symbol.name);
                if (name_cmp != .eq) return name_cmp == .lt;
                return std.mem.order(u8, a.path, b.path) == .lt;
            }
        };
        std.mem.sort(ScoredSymbolResult, list.items, {}, SortCtx.lessThan);
        if (list.items.len > spec.max_results) list.shrinkRetainingCapacity(spec.max_results);
        return list.toOwnedSlice(allocator);
    }

    // Resolve an exact symbol name to its definition sites for codedb_find's
    // symbol fast-path. Uses findAllSymbols — the COMPLETE lookup including the
    // outline safety scan, because symbol_index alone is incomplete for some
    // languages (e.g. it indexes ~no TypeScript functions). That costs about what
    // codedb_symbol does (~2ms) but resolves real symbols reliably and far below
    // the fuzzy file scan. Definition kinds rank above import/comment usages, and
    // when no real definition exists the usages are shown as a fallback. Returns
    // false WITHOUT writing anything when there's no such symbol, so the caller
    // falls back to fuzzy file search.
    pub fn renderSymbolDefsFast(self: *Explorer, name: []const u8, allocator: std.mem.Allocator, out: *std.ArrayList(u8), max_results: usize) bool {
        const results = self.findAllSymbols(name, allocator) catch return false;
        defer {
            for (results) |r| {
                allocator.free(r.path);
                allocator.free(r.symbol.name);
                if (r.symbol.detail) |d| allocator.free(d);
            }
            allocator.free(results);
        }
        if (results.len == 0) return false;
        var has_def = false;
        for (results) |r| {
            if (r.symbol.kind != .import and r.symbol.kind != .comment_block) {
                has_def = true;
                break;
            }
        }
        out.appendSlice(allocator, "exact symbol matches (codedb_symbol shows bodies):\n") catch return false;
        var n: usize = 0;
        for (results) |r| {
            if (n >= max_results) break;
            const is_def = r.symbol.kind != .import and r.symbol.kind != .comment_block;
            if (has_def and !is_def) continue;
            var nb: [16]u8 = undefined;
            out.appendSlice(allocator, std.fmt.bufPrint(&nb, "{d}. ", .{n + 1}) catch continue) catch {};
            out.appendSlice(allocator, r.path) catch {};
            var lb: [64]u8 = undefined;
            out.appendSlice(allocator, std.fmt.bufPrint(&lb, ":{d} ({s})\n", .{ r.symbol.line_start, @tagName(r.symbol.kind) }) catch continue) catch {};
            n += 1;
        }
        return n > 0;
    }
    pub const CalleeRef = struct {
        name: []const u8, // callee identifier (borrows the resolved body content)
        path: []const u8, // file the callee is defined in (borrows a stable outlines key)
        line: u32,
        kind: SymbolKind,
    };

    /// Resolve the call sites inside the function defined at `path` spanning
    /// [line_start, line_end] to their definitions — the dependency side of the
    /// call-graph neighborhood, using the same extraction as centrality. Deduped
    /// by callee name, capped at `max`, function/method targets only, and the
    /// defining function itself is skipped. Best-effort. Everything is allocated
    /// in / borrowed from `allocator` (intended to be a per-request arena); the
    /// returned slice and each `.name` live as long as that allocator.
    pub fn resolveCallees(
        self: *Explorer,
        path: []const u8,
        line_start: u32,
        line_end: u32,
        allocator: std.mem.Allocator,
        max: usize,
    ) ![]CalleeRef {
        if (max == 0 or line_end < line_start) return &.{};
        const content = (self.getContent(path, allocator) catch return &.{}) orelse return &.{};
        const body = sliceLineRange(content, line_start, line_end);
        if (body.len == 0) return &.{};
        const callees = codegraph.extractCallees(allocator, body) catch return &.{};

        var refs: std.ArrayList(CalleeRef) = .empty;
        // Resolve each callee straight off the symbol index: we only need to know
        // whether exactly one non-test function/method defines the name, which is
        // O(defs-of-that-name). findAllSymbols would instead run an O(all-symbols)
        // safety scan over every outline and allocate a full result list per name —
        // ~18 such scans per codedb_context made it ~20% slower on a multi-thousand-
        // file repo (the #524 bench regression). The index is rebuilt on every
        // commit, so for this high-precision/best-effort feature it is authoritative.
        self.mu.lockShared();
        defer self.mu.unlockShared();
        for (callees) |name| {
            if (refs.items.len >= max) break;
            // Skip ubiquitous std/container/builtin method names. They are almost
            // always calls on some receiver (ArrayList.append, HashMap.get, ...),
            // not the rare user-defined free function of the same name, so name-
            // based resolution would assert a false edge even when there's a
            // single user definition.
            if (isUbiquitousName(name)) continue;
            const locs = self.symbol_index.get(name) orelse continue;
            // Only surface UNAMBIGUOUS edges: a callee is shown only if exactly one
            // non-test function/method defines that name. Resolution is name-based
            // (no type info), so common method names (init, lock, get, next, ...)
            // resolve to many candidates — guessing one would assert a false edge.
            // Skipping them keeps this high-precision; ambiguous names are omitted.
            var cand: ?SymbolLocation = null;
            var n_cand: usize = 0;
            for (locs.items) |loc| {
                if (loc.kind != .function and loc.kind != .method) continue;
                if (isLikelyTestPath(loc.path)) continue;
                // Skip the defining function itself (self-edge / recursion).
                if (loc.line_start == line_start and std.mem.eql(u8, loc.path, path)) continue;
                n_cand += 1;
                if (n_cand > 1) break; // ambiguous — stop, will be skipped
                cand = loc;
            }
            if (n_cand == 1) {
                const loc = cand.?;
                try refs.append(allocator, .{
                    .name = name,
                    .path = try allocator.dupe(u8, loc.path),
                    .line = loc.line_start,
                    .kind = loc.kind,
                });
            }
        }
        return refs.toOwnedSlice(allocator);
    }

    /// Heuristic: does this path look like a test/spec/fixture file? Mirrors the
    /// filter used by the codedb_context callers section.
    fn isLikelyTestPath(path: []const u8) bool {
        return std.mem.startsWith(u8, path, "tests/") or
            std.mem.startsWith(u8, path, "test/") or
            std.mem.indexOf(u8, path, "/test") != null or
            std.mem.indexOf(u8, path, "_test.") != null or
            std.mem.indexOf(u8, path, ".test.") != null or
            std.mem.indexOf(u8, path, ".spec.") != null or
            std.mem.indexOf(u8, path, "/__tests__/") != null or
            std.mem.indexOf(u8, path, "/spec/") != null or
            std.mem.indexOf(u8, path, "/fixtures/") != null;
    }

    /// Names so commonly used as stdlib/container/builtin methods across
    /// languages that a `name(` call site almost never refers to a user-defined
    /// free function of that name. Used to suppress false callee edges from
    /// name-only resolution. Conservative: only the highest-collision names.
    fn isUbiquitousName(name: []const u8) bool {
        const common = [_][]const u8{
            "init",        "deinit",   "append",   "get",       "set",
            "put",         "getOrPut", "remove",   "contains",  "has",
            "count",       "len",      "items",    "alloc",     "free",
            "create",      "destroy",  "lock",     "unlock",    "tryLock",
            "next",        "iterator", "clone",    "dupe",      "slice",
            "reset",       "clear",    "format",   "hash",      "eql",
            "write",       "writeAll", "print",    "read",      "close",
            "open",        "value",    "key",      "toOwnedSlice", "pop",
            "push",        "find",     "add",      "new",       "build",
            "run",         "deinit",   "toString", "valueOf",   "of",
        };
        for (common) |c| {
            if (std.mem.eql(u8, name, c)) return true;
        }
        return false;
    }

    /// Return the slice of `content` covering source lines [line_start, line_end]
    /// (1-based, inclusive), excluding the trailing newline. Empty if out of range.
    fn sliceLineRange(content: []const u8, line_start: u32, line_end: u32) []const u8 {
        if (line_start == 0 or line_end < line_start) return content[0..0];
        var line: u32 = 1;
        var i: usize = 0;
        while (i < content.len and line < line_start) : (i += 1) {
            if (content[i] == '\n') line += 1;
        }
        if (i >= content.len) return content[0..0];
        const start = i;
        var cur: u32 = line_start;
        while (i < content.len) : (i += 1) {
            if (content[i] == '\n') {
                if (cur >= line_end) break;
                cur += 1;
            }
        }
        return content[start..i];
    }
    pub fn renderSymbols(self: *Explorer, name: []const u8, allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !bool {
        self.mu.lockShared();
        defer self.mu.unlockShared();

        const indexed_locs: []const SymbolLocation = if (self.symbol_index.get(name)) |locs| locs.items else &.{};
        const LocLookup = struct {
            fn contains(locs: []const SymbolLocation, path: []const u8, line_start: u32) bool {
                for (locs) |loc| {
                    if (loc.line_start == line_start and std.mem.eql(u8, loc.path, path)) return true;
                }
                return false;
            }
        };

        var total: usize = indexed_locs.len;
        var count_iter = self.outlines.iterator();
        while (count_iter.next()) |entry| {
            for (entry.value_ptr.symbols.items) |sym| {
                if (!std.mem.eql(u8, sym.name, name)) continue;
                if (LocLookup.contains(indexed_locs, entry.key_ptr.*, sym.line_start)) continue;
                total += 1;
            }
        }
        if (total == 0) return false;

        try out.ensureUnusedCapacity(allocator, 64 + total * 96);
        const w = cio.listWriter(out, allocator);
        try w.print("{d} results for '{s}':\n", .{ total, name });

        for (indexed_locs) |loc| {
            try w.print("  {s}:{d} ({s})", .{ loc.path, loc.line_start, @tagName(loc.kind) });
            if (self.outlines.getPtr(loc.path)) |outline| {
                for (outline.symbols.items) |sym| {
                    if (sym.line_start == loc.line_start and std.mem.eql(u8, sym.name, name)) {
                        if (sym.detail) |d| try w.print("  // {s}", .{d});
                        break;
                    }
                }
            }
            try w.writeAll("\n");
        }

        var render_iter = self.outlines.iterator();
        while (render_iter.next()) |entry| {
            for (entry.value_ptr.symbols.items) |sym| {
                if (!std.mem.eql(u8, sym.name, name)) continue;
                if (LocLookup.contains(indexed_locs, entry.key_ptr.*, sym.line_start)) continue;
                try w.print("  {s}:{d} ({s})", .{ entry.key_ptr.*, sym.line_start, @tagName(sym.kind) });
                if (sym.detail) |d| try w.print("  // {s}", .{d});
                try w.writeAll("\n");
            }
        }
        return true;
    }

    pub fn searchContent(self: *Explorer, query: []const u8, allocator: std.mem.Allocator, max_results: usize) ![]const SearchResult {
        // #539: ensure the word index — Tier 0's recall source — is populated.
        // After a snapshot fast-load it is built lazily (see issue-220); without
        // this, searchContent's recall collapses to the trigram/skip_trigram tiers
        // and a relevant restored file can be crowded out of max_results by
        // less-relevant hot files. Rebuild here so the complete inverted index
        // feeds Tier 0's ranked candidate set (mirrors searchWord). Runs at most
        // once per load — rebuildWordIndex sets word_index_complete = true. Must
        // precede the shared lock below: rebuildWordIndex takes the exclusive lock.
        if (max_results > 0) {
            self.mu.lockShared();
            const needs_rebuild = !self.word_index_complete and
                (self.contents.len() > 0 or (self.io != null and self.root_dir != null));
            self.mu.unlockShared();
            if (needs_rebuild) try self.rebuildWordIndex();
        }
        self.mu.lockShared();
        defer self.mu.unlockShared();

        if (max_results == 0) return try allocator.alloc(SearchResult, 0);

        var breakdown: SearchBreakdown = .{};
        defer self.last_search_breakdown = breakdown;

        var result_list: std.ArrayList(SearchResult) = .empty;
        errdefer result_list.deinit(allocator);
        try result_list.ensureTotalCapacity(allocator, @min(max_results, 64));

        // searched tracks which paths have been scanned — shared across all tiers.
        var searched = std.StringHashMap(void).init(allocator);
        defer searched.deinit();

        // Tier 0: word index direct lookup — O(1) hash lookup plus bounded
        // content extraction. A per-file cap forces diversity so a single hot
        // file cannot saturate the quota. Code files are considered before
        // docs, and files with more exact word hits are considered first so
        // popular identifiers and skip-trigram canonical files are not hidden
        // behind earlier low-signal posting-list entries.
        const t0_start = cio.nanoTimestamp();
        const word_hits = self.word_index.search(query);
        if (word_hits.len > 0) {
            const Tier0File = struct {
                path: []const u8,
                count: u32,
                first_seen: usize,
                is_doc: bool,
            };

            var tier0_files_by_path = std.StringHashMap(Tier0File).init(allocator);
            defer tier0_files_by_path.deinit();

            for (word_hits, 0..) |hit, ordinal| {
                const hit_path = self.word_index.hitPath(hit);
                if (hit_path.len == 0) continue;
                const gop = tier0_files_by_path.getOrPut(hit_path) catch continue;
                if (!gop.found_existing) {
                    gop.value_ptr.* = .{
                        .path = hit_path,
                        .count = 0,
                        .first_seen = ordinal,
                        .is_doc = isDocLanguage(detectLanguage(hit_path)),
                    };
                }
                gop.value_ptr.count +|= 1;
            }

            var tier0_files: std.ArrayList(Tier0File) = .empty;
            defer tier0_files.deinit(allocator);
            try tier0_files.ensureTotalCapacity(allocator, tier0_files_by_path.count());
            var tier0_iter = tier0_files_by_path.valueIterator();
            while (tier0_iter.next()) |stats| {
                tier0_files.appendAssumeCapacity(stats.*);
            }

            if (tier0_files.items.len > 1) {
                std.sort.block(Tier0File, tier0_files.items, {}, struct {
                    pub fn lessThan(_: void, a: Tier0File, b: Tier0File) bool {
                        if (a.is_doc != b.is_doc) return !a.is_doc;
                        if (a.count != b.count) return a.count > b.count;
                        if (a.first_seen != b.first_seen) return a.first_seen < b.first_seen;
                        return std.mem.lessThan(u8, a.path, b.path);
                    }
                }.lessThan);
            }

            const tier0_per_file_cap: usize = if (tier0_files.items.len <= 1) max_results else @max(1, max_results / 5);
            var tier0_exact_capacity: usize = 0;
            for (tier0_files.items) |stats| {
                tier0_exact_capacity += @min(@as(usize, stats.count), tier0_per_file_cap);
                if (tier0_exact_capacity >= max_results) break;
            }
            const use_line_hits = tier0_exact_capacity >= max_results and tier0_per_file_cap <= 256;
            for (tier0_files.items) |stats| {
                if (result_list.items.len >= max_results) break;
                const ref = self.readContentForSearch(stats.path, allocator) orelse continue;
                defer ref.deinit();
                if (use_line_hits) {
                    var target_lines: [256]u32 = undefined;
                    var target_count: usize = 0;
                    for (word_hits) |hit| {
                        if (target_count >= tier0_per_file_cap) break;
                        const hit_path = self.word_index.hitPath(hit);
                        if (!std.mem.eql(u8, hit_path, stats.path)) continue;
                        if (target_count == 0 or target_lines[target_count - 1] != hit.line_num) {
                            target_lines[target_count] = hit.line_num;
                            target_count += 1;
                        }
                    }
                    try appendTargetLineHits(stats.path, ref.data, allocator, target_lines[0..target_count], max_results, &result_list);
                    if (result_list.items.len < max_results) searched.put(stats.path, {}) catch {};
                } else {
                    searched.put(stats.path, {}) catch {};
                    try searchInContent(stats.path, ref.data, query, allocator, tier0_per_file_cap, max_results, &result_list);
                }
            }
            if (result_list.items.len >= max_results) {
                breakdown.tier0_ns = cio.nanoTimestamp() - t0_start;
                breakdown.tier_reached = 0;
                breakdown.result_count = @intCast(result_list.items.len);
                if (use_line_hits) {
                    return result_list.toOwnedSlice(allocator);
                }
                const t_rerank = cio.nanoTimestamp();
                const res = self.rerankAndFinalize(&result_list, query, allocator);
                breakdown.rerank_ns = cio.nanoTimestamp() - t_rerank;
                return res;
            }
        }
        breakdown.tier0_ns = cio.nanoTimestamp() - t0_start;

        const t05_start = cio.nanoTimestamp();
        if (result_list.items.len == 0 and query.len >= 3) {
            const prefix_hits = try self.word_index.searchPrefix(query, allocator, max_results);
            defer allocator.free(prefix_hits);
            for (prefix_hits) |hit| {
                const hit_path = self.word_index.hitPath(hit);
                if (hit_path.len == 0) continue;
                const ref = self.readContentForSearch(hit_path, allocator) orelse continue;
                defer ref.deinit();
                const line_text = extractLineByNumber(ref.data, hit.line_num) orelse continue;
                if (indexOfCaseInsensitive(line_text, query) == null) continue;
                const duped_text = try allocator.dupe(u8, line_text);
                errdefer allocator.free(duped_text);
                const duped_path = try allocator.dupe(u8, hit_path);
                errdefer allocator.free(duped_path);
                try result_list.append(allocator, .{
                    .path = duped_path,
                    .line_num = hit.line_num,
                    .line_text = duped_text,
                });
                searched.put(hit_path, {}) catch {};
                if (result_list.items.len >= max_results) break;
            }
            if (result_list.items.len >= max_results) {
                breakdown.tier05_ns = cio.nanoTimestamp() - t05_start;
                breakdown.tier_reached = 1;
                breakdown.result_count = @intCast(result_list.items.len);
                const t_rerank = cio.nanoTimestamp();
                const res = self.rerankAndFinalize(&result_list, query, allocator);
                breakdown.rerank_ns = cio.nanoTimestamp() - t_rerank;
                return res;
            }
        }
        breakdown.tier05_ns = cio.nanoTimestamp() - t05_start;

        const t1_start = cio.nanoTimestamp();
        const candidate_paths = self.trigram_index.candidates(query, allocator);
        defer if (candidate_paths) |cp| allocator.free(cp);
        if (candidate_paths) |cp| breakdown.candidate_count = @intCast(cp.len);

        if (candidate_paths) |cp| {
            if (cp.len > 0) {
                // Issue #427: rank candidates by per-file word-index hit count
                // (desc) so the definition-dense file scans first; fall back to
                // file content length (asc) so small files still come before
                // unrelated large files at the same hit count. Pre-fix the
                // sort key was content length alone, which buried the canonical
                // file behind unrelated short files when max_per_file was 1.
                var hits_per_file = std.StringHashMap(u32).init(allocator);
                defer hits_per_file.deinit();
                for (word_hits) |hit| {
                    const hp = self.word_index.hitPath(hit);
                    if (hp.len == 0) continue;
                    const gop_h = try hits_per_file.getOrPut(hp);
                    if (!gop_h.found_existing) gop_h.value_ptr.* = 0;
                    gop_h.value_ptr.* += 1;
                }
                const SortCtx = struct {
                    contents: *ContentCache,
                    counts: *const std.StringHashMap(u32),
                    pub fn lessThan(ctx: @This(), a: []const u8, b: []const u8) bool {
                        const a_count = ctx.counts.get(a) orelse 0;
                        const b_count = ctx.counts.get(b) orelse 0;
                        if (a_count != b_count) return a_count > b_count;
                        const a_len = if (ctx.contents.get(a)) |c| c.len else std.math.maxInt(usize);
                        const b_len = if (ctx.contents.get(b)) |c| c.len else std.math.maxInt(usize);
                        return a_len < b_len;
                    }
                };
                std.mem.sort([]const u8, @constCast(cp), SortCtx{ .contents = &self.contents, .counts = &hits_per_file }, SortCtx.lessThan);

                const estimated_total = cp.len + self.skip_trigram_files.count();
                const max_per_file = @max(@as(usize, 1), max_results / @max(@as(usize, 1), estimated_total));
                for (cp) |path| {
                    if (searched.contains(path)) continue;
                    const ref = self.readContentForSearch(path, allocator) orelse continue;
                    defer ref.deinit();
                    try searchInContent(path, ref.data, query, allocator, max_per_file, max_results, &result_list);
                    if (result_list.items.len >= max_results) {
                        breakdown.tier1_ns = cio.nanoTimestamp() - t1_start;
                        breakdown.tier_reached = 2;
                        breakdown.result_count = @intCast(result_list.items.len);
                        const t_rerank = cio.nanoTimestamp();
                        const res = self.rerankAndFinalize(&result_list, query, allocator);
                        breakdown.rerank_ns = cio.nanoTimestamp() - t_rerank;
                        return res;
                    }
                }
            }
        }

        if (candidate_paths) |cp| {
            for (cp) |p| searched.put(p, {}) catch {};
        }
        breakdown.tier1_ns = cio.nanoTimestamp() - t1_start;

        const t2_start = cio.nanoTimestamp();
        // Tier 2 (sparse n-gram fallback) removed in v0.2.5822 — the
        // sparse_ngram_index field is no longer populated; tier 3
        // (skip_trigram_files) + tier 5 (full outline scan) cover the
        // same surface area.
        breakdown.tier2_ns = cio.nanoTimestamp() - t2_start;

        const t3_start = cio.nanoTimestamp();
        if (result_list.items.len < max_results) {
            var skip_iter = self.skip_trigram_files.keyIterator();
            while (skip_iter.next()) |key_ptr| {
                if (searched.contains(key_ptr.*)) continue;
                const ref = self.readContentForSearch(key_ptr.*, allocator) orelse continue;
                defer ref.deinit();
                searched.put(key_ptr.*, {}) catch {};
                try searchInContent(key_ptr.*, ref.data, query, allocator, max_results, max_results, &result_list);
                if (result_list.items.len >= max_results) break;
            }
        }
        breakdown.tier3_ns = cio.nanoTimestamp() - t3_start;

        const t4_start = cio.nanoTimestamp();
        if (result_list.items.len < max_results) {
            if (word_hits.len > 0) {
                var word_paths = std.StringHashMap(void).init(allocator);
                defer word_paths.deinit();
                for (word_hits) |hit| word_paths.put(self.word_index.hitPath(hit), {}) catch {};
                var wp_iter = word_paths.keyIterator();
                while (wp_iter.next()) |key_ptr| {
                    if (searched.contains(key_ptr.*)) continue;
                    const ref = self.readContentForSearch(key_ptr.*, allocator) orelse continue;
                    defer ref.deinit();
                    searched.put(key_ptr.*, {}) catch {};
                    try searchInContent(key_ptr.*, ref.data, query, allocator, max_results, max_results, &result_list);
                    if (result_list.items.len >= max_results) break;
                }
            }
        }
        breakdown.tier4_ns = cio.nanoTimestamp() - t4_start;

        const t5_start = cio.nanoTimestamp();
        const trigram_ruled_out = if (candidate_paths) |_|
            (query.len >= 3)
        else
            false;
        if (result_list.items.len == 0 and !trigram_ruled_out) {
            self.search_tier5_count += 1;
            var iter = self.outlines.keyIterator();
            while (iter.next()) |key_ptr| {
                if (searched.contains(key_ptr.*)) continue;
                const ref = self.readContentForSearch(key_ptr.*, allocator) orelse continue;
                defer ref.deinit();
                try searchInContent(key_ptr.*, ref.data, query, allocator, max_results, max_results, &result_list);
                if (result_list.items.len >= max_results) break;
            }
        }
        breakdown.tier5_ns = cio.nanoTimestamp() - t5_start;

        if (result_list.items.len > 0) {
            breakdown.tier_reached = if (breakdown.tier5_ns > 0 and result_list.items.len > 0) 7 else if (breakdown.tier4_ns > 0 and result_list.items.len > 0) 6 else if (breakdown.tier3_ns > 0) 5 else if (breakdown.tier2_ns > 0) 4 else if (breakdown.tier1_ns > 0) 3 else if (breakdown.tier05_ns > 0) 1 else 0;
        }
        breakdown.result_count = @intCast(result_list.items.len);

        const t_rerank = cio.nanoTimestamp();
        const res = self.rerankAndFinalize(&result_list, query, allocator);
        breakdown.rerank_ns = cio.nanoTimestamp() - t_rerank;
        return res;
    }

    pub fn renderPlainSearch(self: *Explorer, query: []const u8, allocator: std.mem.Allocator, out: *std.ArrayList(u8), max_results: usize, paths_only: bool) !bool {
        self.mu.lockShared();
        defer self.mu.unlockShared();

        if (max_results == 0) return false;

        var breakdown: SearchBreakdown = .{};
        const t0_start = cio.nanoTimestamp();
        const word_hits = self.word_index.search(query);
        if (word_hits.len == 0) return false;

        const Tier0File = struct {
            doc_id: u32,
            path: []const u8,
            count: u32,
            first_seen: usize,
            is_doc: bool,
        };

        var tier0_files_buf: [512]Tier0File = undefined;
        var tier0_files_len: usize = 0;
        for (word_hits, 0..) |hit, ordinal| {
            const hit_path = self.word_index.hitPath(hit);
            if (hit_path.len == 0) continue;

            var found_i: ?usize = null;
            for (tier0_files_buf[0..tier0_files_len], 0..) |stats, i| {
                if (stats.doc_id == hit.doc_id) {
                    found_i = i;
                    break;
                }
            }
            if (found_i) |i| {
                tier0_files_buf[i].count +|= 1;
            } else {
                if (tier0_files_len >= tier0_files_buf.len) return false;
                tier0_files_buf[tier0_files_len] = .{
                    .doc_id = hit.doc_id,
                    .path = hit_path,
                    .count = 1,
                    .first_seen = ordinal,
                    .is_doc = isDocLanguage(detectLanguage(hit_path)),
                };
                tier0_files_len += 1;
            }
        }

        if (tier0_files_len == 0) return false;
        const tier0_files = tier0_files_buf[0..tier0_files_len];
        if (tier0_files.len > 1) {
            std.sort.block(Tier0File, tier0_files, {}, struct {
                pub fn lessThan(_: void, a: Tier0File, b: Tier0File) bool {
                    if (a.is_doc != b.is_doc) return !a.is_doc;
                    if (a.count != b.count) return a.count > b.count;
                    if (a.first_seen != b.first_seen) return a.first_seen < b.first_seen;
                    return std.mem.lessThan(u8, a.path, b.path);
                }
            }.lessThan);
        }

        const tier0_per_file_cap: usize = if (tier0_files.len <= 1) max_results else @max(1, max_results / 5);
        if (tier0_per_file_cap > 256) return false;
        var tier0_exact_capacity: usize = 0;
        for (tier0_files) |stats| {
            tier0_exact_capacity += @min(@as(usize, stats.count), tier0_per_file_cap);
            if (tier0_exact_capacity >= max_results) break;
        }
        if (tier0_exact_capacity < max_results) return false;

        if (!paths_only) {
            var checked: usize = 0;
            for (tier0_files) |stats| {
                if (checked >= max_results) break;
                if (self.contents.get(stats.path) == null) return false;
                checked += @min(@as(usize, stats.count), tier0_per_file_cap);
            }
        }

        try out.ensureUnusedCapacity(allocator, 64 + max_results * 96);
        const w = cio.listWriter(out, allocator);
        try w.print("{d} results for '{s}':\n", .{ max_results, query });

        const CountEntry = struct { doc_id: u32, path: []const u8, count: u8 };
        var counts: [64]CountEntry = undefined;
        var counts_len: usize = 0;
        const max_per_file: u8 = 5;
        var rendered: usize = 0;
        var shown: usize = 0;

        for (tier0_files) |stats| {
            if (rendered >= max_results) break;

            var target_lines: [256]u32 = undefined;
            var target_count: usize = 0;
            for (word_hits) |hit| {
                if (target_count >= tier0_per_file_cap) break;
                if (hit.doc_id != stats.doc_id) continue;
                if (target_count == 0 or target_lines[target_count - 1] != hit.line_num) {
                    target_lines[target_count] = hit.line_num;
                    target_count += 1;
                }
            }

            if (paths_only) {
                for (target_lines[0..target_count]) |line_num| {
                    if (rendered >= max_results) break;
                    rendered += 1;
                    shown += 1;
                    try w.print("  {s}:{d}\n", .{ stats.path, line_num });
                }
                continue;
            }

            const content = self.contents.get(stats.path) orelse return false;
            var target_i: usize = 0;
            var line_num: u32 = 0;
            var lines = std.mem.splitScalar(u8, content, '\n');
            while (lines.next()) |line| {
                line_num += 1;
                while (target_i < target_count and target_lines[target_i] < line_num) {
                    target_i += 1;
                }
                if (target_i >= target_count) break;
                if (target_lines[target_i] != line_num) continue;
                target_i += 1;
                rendered += 1;

                var count_idx: ?usize = null;
                for (counts[0..counts_len], 0..) |entry, idx_i| {
                    if (entry.doc_id == stats.doc_id) {
                        count_idx = idx_i;
                        break;
                    }
                }
                const count_slot = count_idx orelse blk: {
                    if (counts_len >= counts.len) break :blk counts.len - 1;
                    counts[counts_len] = .{ .doc_id = stats.doc_id, .path = stats.path, .count = 0 };
                    counts_len += 1;
                    break :blk counts_len - 1;
                };
                counts[count_slot].count += 1;
                if (counts[count_slot].count > max_per_file) {
                    if (counts[count_slot].count == max_per_file + 1) {
                        try w.print("  {s}: ... (more matches truncated)\n", .{counts[count_slot].path});
                    }
                } else {
                    shown += 1;
                    try w.print("  {s}:{d}: {s}\n", .{ stats.path, line_num, line });
                }
                if (rendered >= max_results) break;
            }
        }

        if (shown < max_results) {
            try w.print("({d} shown, {d} truncated by per-file cap)\n", .{ shown, max_results - shown });
        }

        breakdown.tier0_ns = cio.nanoTimestamp() - t0_start;
        breakdown.tier_reached = 0;
        breakdown.candidate_count = @intCast(word_hits.len);
        breakdown.result_count = @intCast(max_results);
        self.last_search_breakdown = breakdown;
        return rendered >= max_results;
    }

    /// Run the multi-signal rerank in place, then transfer ownership of
    /// result_list to the caller. Centralised so every searchContent return
    /// path (Tier 0 / Tier 1 early-return on max_results, fall-through to
    /// final return) gets the same ranking — pre-fix only the fall-through
    /// path applied multi-signal scoring.
    fn rerankAndFinalize(
        self: *const Explorer,
        result_list: *std.ArrayList(SearchResult),
        query: []const u8,
        allocator: std.mem.Allocator,
    ) ![]const SearchResult {
        for (result_list.items) |*r| {
            r.score = self.rerankSignalScore(r.*, query);
        }
        if (result_list.items.len > 1) {
            std.sort.block(SearchResult, result_list.items, {}, struct {
                pub fn lessThan(_: void, a: SearchResult, b: SearchResult) bool {
                    const sa = if (a.score == a.score) a.score else 0;
                    const sb = if (b.score == b.score) b.score else 0;
                    if (sa != sb) return sa > sb;
                    const ord = std.mem.order(u8, a.path, b.path);
                    if (ord != .eq) return ord == .lt;
                    return a.line_num < b.line_num;
                }
            }.lessThan);
        }
        self.appendRerankTrace(query, result_list.items);
        return result_list.toOwnedSlice(allocator);
    }

    /// Compose the rerank signals for one search hit (issue #429).
    fn rerankSignalScore(self: *const Explorer, r: SearchResult, query: []const u8) f32 {
        var score: f32 = countOccurrences(r.line_text, query);

        if (self.outlines.get(r.path)) |outline| {
            for (outline.symbols.items) |sym| {
                if (sym.line_start == r.line_num and asciiEqlIgnoreCase(sym.name, query)) {
                    score += 5.0;
                    break;
                }
            }
        }

        const basename = std.fs.path.basename(r.path);
        const stem_end = std.mem.indexOfScalar(u8, basename, '.') orelse basename.len;
        const stem = basename[0..stem_end];
        const stem_contains_query = asciiContainsIgnoreCase(stem, query);
        const query_contains_stem = asciiContainsIgnoreCase(query, stem);
        const stem_related_to_query = stem_contains_query or query_contains_stem;
        if (asciiEqlIgnoreCase(stem, query)) {
            score += 15.0;
        } else if (stem_related_to_query) {
            score += 8.0;
        }
        // Path-segment match boost: query matches a directory segment in
        // the path (e.g. query="parser" boosts src/parser/foo.zig). Weaker
        // than basename match because the file's own name is a stronger
        // intent signal than the directory it lives in. Skip when basename
        // already matched to avoid double-counting.
        if (!stem_related_to_query and pathHasSegmentIgnoreCase(r.path, query)) {
            score += 6.0;
        }

        if (pathHasSegment(r.path, "tests") or pathHasSegment(r.path, "test")) score *= 0.6;
        if (pathHasSegment(r.path, "examples") or pathHasSegment(r.path, "example")) score *= 0.6;
        if (pathHasSegment(r.path, "vendor") or pathHasSegment(r.path, "node_modules") or
            pathHasSegment(r.path, "third_party")) score *= 0.4;
        // Doc-language penalty: markdown / data files (CHANGELOG.md, design
        // docs, benchmark logs) often mention an identifier many times in a
        // single line, which lets per-line frequency dwarf code call sites.
        // For doc files, more mentions don't reflect more code-relevance —
        // they reflect prose density. Cap at 1.0 then halve so any code hit
        // (score >= 1) outranks any doc hit. Symmetric with path-prior.
        if (isDocLanguage(detectLanguage(r.path))) {
            score = @min(score, 1.0) * 0.5;
        }

        return score;
    }

    /// Append one JSON line per searchContent invocation. v0 logger for the
    /// rerank-tuning experiment — pure observation, never affects ranking.
    /// Silent no-op when path is unset, io is unset, or any I/O step fails.
    /// Caps query at 256 bytes, results at 50 entries, file at 10 MB
    /// (rotates by truncate-clobber).
    fn appendRerankTrace(self: *const Explorer, query: []const u8, results: []const SearchResult) void {
        const path = self.rerank_trace_path orelse return;
        const io_inst = self.io orelse return;

        const max_query: usize = 256;
        const max_results_logged: usize = 50;
        const size_limit: u64 = 10 * 1024 * 1024;

        var buf: [16 * 1024]u8 = undefined;
        var pos: usize = 0;

        const ts = cio.milliTimestamp();
        const head = std.fmt.bufPrint(buf[pos..], "{{\"ts\":{d},\"query\":\"", .{ts}) catch return;
        pos += head.len;

        const q_clamped = query[0..@min(query.len, max_query)];
        pos += writeJsonEscaped(buf[pos..], q_clamped);

        const sep = "\",\"results\":[";
        if (pos + sep.len > buf.len) return;
        @memcpy(buf[pos..][0..sep.len], sep);
        pos += sep.len;

        var any_emitted = false;
        const n = @min(results.len, max_results_logged);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const r = results[i];
            const sep_len: usize = if (any_emitted) 1 else 0;
            const tail_reserve: usize = 3; // "]}\n"
            const escaped_path_budget: usize = 2 * r.path.len;
            const fixed_overhead: usize = "{\"path\":\"".len + "\",\"line\":,\"score\":}".len + 32;
            if (pos + sep_len + escaped_path_budget + fixed_overhead + tail_reserve > buf.len) break;

            if (any_emitted) {
                buf[pos] = ',';
                pos += 1;
            }
            const open = "{\"path\":\"";
            @memcpy(buf[pos..][0..open.len], open);
            pos += open.len;
            pos += writeJsonEscaped(buf[pos..], r.path);
            const obj_tail = std.fmt.bufPrint(buf[pos..], "\",\"line\":{d},\"score\":{d:.4}}}", .{ r.line_num, r.score }) catch break;
            pos += obj_tail.len;
            any_emitted = true;
        }

        const close = "]}\n";
        if (pos + close.len > buf.len) return;
        @memcpy(buf[pos..][0..close.len], close);
        pos += close.len;

        var file = std.Io.Dir.cwd().openFile(io_inst, path, .{ .mode = .write_only }) catch blk: {
            break :blk std.Io.Dir.cwd().createFile(io_inst, path, .{ .truncate = false }) catch return;
        };
        var current_size = file.length(io_inst) catch {
            file.close(io_inst);
            return;
        };
        if (current_size >= size_limit) {
            file.close(io_inst);
            file = std.Io.Dir.cwd().createFile(io_inst, path, .{ .truncate = true }) catch return;
            current_size = 0;
        }
        defer file.close(io_inst);

        const locked = blk: {
            file.lock(io_inst, .exclusive) catch break :blk false;
            break :blk true;
        };
        defer if (locked) file.unlock(io_inst);

        if (locked) {
            current_size = file.length(io_inst) catch current_size;
            if (current_size >= size_limit) current_size = 0;
        }

        file.writePositionalAll(io_inst, buf[0..pos], current_size) catch {};
    }

    /// BM25-ranked content search. Tokenizes the query the same way the word
    /// index tokenizes documents, scores each candidate doc with BM25
    /// (k1=1.2, b=0.75), and emits one SearchResult per top-N document with
    /// the best-tf line for any query term in that doc. Existing scan-order
    /// `searchContent` is unaffected.
    /// Relevance multiplier on BM25 scores for code-intelligence search: boost
    /// files whose name/path matches a query term, and down-weight tests, docs,
    /// and vendored copies (they still surface if strongly relevant).
    fn pathRelevanceMultiplier(path: []const u8, terms: *const std.StringHashMap(void)) f32 {
        var mult: f32 = 1.0;
        const base = if (std.mem.lastIndexOfScalar(u8, path, '/')) |s| path[s + 1 ..] else path;
        var lb: [256]u8 = undefined;
        if (base.len <= lb.len) {
            for (base, 0..) |c, i| lb[i] = std.ascii.toLower(c);
            var it = terms.keyIterator();
            while (it.next()) |t| {
                if (t.*.len >= 3 and std.mem.indexOf(u8, lb[0..base.len], t.*) != null) {
                    mult *= 1.6;
                    break;
                }
            }
        }
        const is_test = std.mem.startsWith(u8, base, "test") or
            std.mem.indexOf(u8, base, "_test") != null or
            std.mem.indexOf(u8, path, "/test") != null;
        if (is_test) mult *= 0.6;
        if (std.mem.endsWith(u8, path, ".md") or std.mem.indexOf(u8, path, "/docs/") != null) mult *= 0.6;
        if (std.mem.indexOf(u8, path, "node_modules") != null or
            std.mem.indexOf(u8, path, "/vendor/") != null or
            std.mem.indexOf(u8, path, "zig-pkg") != null) mult *= 0.4;
        return mult;
    }

    /// Additive ranking boost from a file's call-graph centrality. Returns 1.0
    /// when centrality isn't built (so ranking is unchanged) — it is ALWAYS a
    /// multiplier ≥ 1, never a filter, so a misresolved edge can only nudge a
    /// central file up, never drop a real result. alpha tuned via MRR.
    fn centralityBoost(self: *Explorer, path: []const u8) f32 {
        const cm = self.call_centrality orelse return 1.0;
        const c = cm.get(path) orelse return 1.0;
        const alpha: f32 = 0.15;
        return 1.0 + alpha * @log(1.0 + c);
    }

    /// Public, lock-acquiring entry point for single-threaded callers (the
    /// index/scan path) to pre-build call_centrality before persisting a snapshot,
    /// so a later load can restore it instead of paying the lazy first-query build.
    /// ensureCallCentrality assumes the caller already holds a shared lock (it is
    /// normally reached from searchContentRanked); this wrapper takes that lock.
    pub fn buildCallCentrality(self: *Explorer, allocator: std.mem.Allocator) void {
        self.mu.lockShared();
        defer self.mu.unlockShared();
        self.ensureCallCentrality(allocator);
    }

    /// Build the resolved call graph once (idempotent, mutex-guarded). Must be
    /// called while holding at least a shared lock on `mu`. Retains edges for
    /// codedb_callpath and computes per-file centrality (PageRank by default).
    fn ensureCallGraph(self: *Explorer, allocator: std.mem.Allocator) void {
        if (self.call_graph != null) return;
        self.centrality_build_mu.lock();
        defer self.centrality_build_mu.unlock();
        if (self.call_graph != null) return;

        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();

        var node_path: std.ArrayList([]const u8) = .empty;
        var node_name: std.ArrayList([]const u8) = .empty;
        var node_line: std.ArrayList(u32) = .empty;
        var funcs: std.ArrayList(codegraph.FuncInput) = .empty;
        var name_to_ids = std.StringHashMap(std.ArrayList(codegraph.NodeId)).init(a);

        var it = self.outlines.iterator();
        while (it.next()) |entry| {
            const path = entry.key_ptr.*;
            const ref = self.readContentForSearch(path, a) orelse continue;
            defer ref.deinit();
            const content = ref.data;
            var offs: std.ArrayList(usize) = .empty;
            offs.append(a, 0) catch continue;
            for (content, 0..) |ch, i| {
                if (ch == '\n') offs.append(a, i + 1) catch break;
            }
            const nlines = offs.items.len;
            for (entry.value_ptr.symbols.items) |sym| {
                if (sym.kind != .function and sym.kind != .method) continue;
                if (sym.line_start == 0 or sym.line_start > nlines) continue;
                const start = offs.items[sym.line_start - 1];
                const end_line = @min(sym.line_end, nlines);
                const end = if (end_line < nlines) offs.items[end_line] else content.len;
                if (end <= start) continue;
                const id: codegraph.NodeId = @intCast(node_path.items.len);
                node_path.append(a, path) catch return;
                node_name.append(a, sym.name) catch return;
                node_line.append(a, sym.line_start) catch return;
                funcs.append(a, .{ .id = id, .body = content[start..end] }) catch return;
                const gop = name_to_ids.getOrPut(sym.name) catch return;
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                gop.value_ptr.append(a, id) catch return;
            }
        }
        const n_nodes = node_path.items.len;
        if (n_nodes == 0) return;

        var resolve = std.StringHashMap([]const codegraph.NodeId).init(a);
        var n2i = name_to_ids.iterator();
        while (n2i.next()) |e| resolve.put(e.key_ptr.*, e.value_ptr.items) catch return;

        var edges_tmp = codegraph.buildEdges(a, funcs.items, &resolve, false) catch return;
        defer edges_tmp.deinit(a);

        const edges_owned = self.allocator.alloc(codegraph.Edge, edges_tmp.items.len) catch return;
        @memcpy(edges_owned, edges_tmp.items);

        const adj = codegraph.buildAdjacency(self.allocator, edges_owned, n_nodes) catch {
            self.allocator.free(edges_owned);
            return;
        };

        const np = self.allocator.alloc([]const u8, n_nodes) catch {
            self.allocator.free(edges_owned);
            codegraph.freeAdjacency(self.allocator, adj);
            return;
        };
        @memcpy(np, node_path.items);

        const nn = self.allocator.alloc([]const u8, n_nodes) catch {
            self.allocator.free(edges_owned);
            codegraph.freeAdjacency(self.allocator, adj);
            self.allocator.free(np);
            return;
        };
        @memcpy(nn, node_name.items);

        const nl = self.allocator.alloc(u32, n_nodes) catch {
            self.allocator.free(edges_owned);
            codegraph.freeAdjacency(self.allocator, adj);
            self.allocator.free(np);
            self.allocator.free(nn);
            return;
        };
        @memcpy(nl, node_line.items);

        const node_scores = if (cio.posixGetenv("CODEDB_IN_DEGREE_CENTRALITY") != null)
            codegraph.inDegreeCentrality(self.allocator, edges_owned, n_nodes) catch null
        else
            codegraph.pageRank(self.allocator, edges_owned, n_nodes, 0.85, 20) catch null;
        if (node_scores == null) {
            self.allocator.free(edges_owned);
            codegraph.freeAdjacency(self.allocator, adj);
            self.allocator.free(np);
            self.allocator.free(nn);
            self.allocator.free(nl);
            return;
        }
        defer self.allocator.free(node_scores.?);

        if (self.call_centrality == null) {
            var cmap = std.StringHashMap(f32).init(self.allocator);
            for (np, node_scores.?) |path, score| {
                if (score == 0) continue;
                const gop = cmap.getOrPut(path) catch continue;
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* += score;
            }
            self.call_centrality = cmap;
        }

        self.call_graph = .{
            .edges = edges_owned,
            .adj = adj,
            .node_path = np,
            .node_name = nn,
            .node_line = nl,
        };
    }

    /// Build `call_centrality` once (idempotent, mutex-guarded). Must be called
    /// while holding at least a shared lock on `mu`.
    fn ensureCallCentrality(self: *Explorer, allocator: std.mem.Allocator) void {
        if (self.call_centrality != null) return;
        self.ensureCallGraph(allocator);
    }

    /// Shortest resolved call chain between two symbol names. Returns owned steps
    /// (path, name, line) or null when either symbol is missing or unreachable.
    pub fn findCallPath(
        self: *Explorer,
        from_name: []const u8,
        to_name: []const u8,
        allocator: std.mem.Allocator,
        max_hops: usize,
    ) !?[]CallPathStep {
        self.mu.lockShared();
        defer self.mu.unlockShared();

        self.ensureCallGraph(allocator);
        const cg = self.call_graph orelse return null;

        var from_ids: std.ArrayList(codegraph.NodeId) = .empty;
        defer from_ids.deinit(allocator);
        var to_ids: std.ArrayList(codegraph.NodeId) = .empty;
        defer to_ids.deinit(allocator);

        for (cg.node_name, 0..) |name, id| {
            const nid: codegraph.NodeId = @intCast(id);
            if (std.mem.eql(u8, name, from_name)) try from_ids.append(allocator, nid);
            if (std.mem.eql(u8, name, to_name)) try to_ids.append(allocator, nid);
        }
        if (from_ids.items.len == 0 or to_ids.items.len == 0) return null;

        const node_ids = codegraph.shortestCallPath(
            allocator,
            cg.adj,
            cg.node_path.len,
            from_ids.items,
            to_ids.items,
            max_hops,
        ) catch return null;
        const path = node_ids orelse return null;
        defer allocator.free(path);

        var steps: std.ArrayList(CallPathStep) = .empty;
        errdefer steps.deinit(allocator);
        for (path) |nid| {
            try steps.append(allocator, .{
                .path = cg.node_path[nid],
                .name = cg.node_name[nid],
                .line = cg.node_line[nid],
            });
        }
        return try steps.toOwnedSlice(allocator);
    }

    pub fn searchContentRanked(self: *Explorer, query: []const u8, allocator: std.mem.Allocator, max_results: usize) ![]const SearchResult {
        self.mu.lockShared();
        defer self.mu.unlockShared();

        if (max_results == 0) return try allocator.alloc(SearchResult, 0);

        // Graph-aware ranking: build the resolved call graph's per-file centrality
        // once and fold it in as an additive boost. On by default (MRR-validated
        // on the codedb set: 0.819 -> 0.944, +4 P@1, no recall loss); set
        // CODEDB_NO_CENTRALITY to disable.
        if (cio.posixGetenv("CODEDB_NO_CENTRALITY") == null) self.ensureCallCentrality(allocator);

        // Tokenize the query the same way WordIndex tokenizes documents:
        // lowercase + identifier-split. Dedupe terms so repeated query words
        // don't double-count.
        var term_arena = std.heap.ArenaAllocator.init(allocator);
        defer term_arena.deinit();
        const ta = term_arena.allocator();

        var terms_set = std.StringHashMap(void).init(ta);
        var raw_tok = idx.WordTokenizer{ .buf = query };
        while (raw_tok.next()) |word| {
            if (word.len < 2) continue;
            const lower = try ta.alloc(u8, word.len);
            for (word, 0..) |c, j| lower[j] = idx.normalizeChar(c);
            _ = try terms_set.getOrPut(lower);

            var needs_split: bool = false;
            if (word.len >= 4) {
                for (word) |c| {
                    if (c == '_' or (c >= 'A' and c <= 'Z')) {
                        needs_split = true;
                        break;
                    }
                }
            }
            if (needs_split) {
                var sub_toks: std.ArrayList([]const u8) = .empty;
                defer sub_toks.deinit(ta);
                idx.splitIdentifier(word, &sub_toks, ta) catch continue;
                for (sub_toks.items) |sub| {
                    if (sub.len < 2) continue;
                    _ = try terms_set.getOrPut(sub);
                }
            }
        }
        if (terms_set.count() == 0) return try allocator.alloc(SearchResult, 0);

        // BM25 constants.
        const k1: f32 = 1.2;
        const b: f32 = 0.75;
        // BM25+ (Lv & Zhai 2011) lower-bound on the TF term: every matching term
        // contributes at least idf*delta regardless of length normalization, so
        // long source files that genuinely match aren't penalized toward zero
        // (a known BM25 weakness). delta=0.5 matches bm25s's BM25+/BM25L default.
        const bm25_plus_delta: f32 = 0.5;
        // Fall back to the total indexed-doc count when the per-doc length
        // table is empty (the bulk `codedb index` path writes the disk word
        // index without doc lengths) so ranked search still returns idf-weighted
        // results instead of nothing. avgDocLength() already returns a safe 1.0.
        const ranked_n = self.word_index.rankedDocCount();
        const N: u32 = if (ranked_n > 0) ranked_n else @intCast(self.word_index.id_to_path.items.len);
        if (N == 0) return try allocator.alloc(SearchResult, 0);
        const avgdl = self.word_index.avgDocLength();

        // Aggregate scores per doc and remember the best line (max term hits)
        // for each candidate.
        const DocAgg = struct {
            score: f32,
            best_line: u32,
            best_line_hits: u32,
        };
        var per_doc = U32HashMap(DocAgg).init(ta);

        // For each unique query term, look up its posting list once,
        // compute df and per-doc tf in a single pass.
        var term_iter = terms_set.keyIterator();
        while (term_iter.next()) |term_ptr| {
            const term = term_ptr.*;
            const hits = self.word_index.search(term);
            if (hits.len == 0) continue;

            // df: distinct doc_ids in this posting list. tf: count of (term,doc)
            // entries (each entry is a distinct line per indexFile dedup).
            // line_hits: per-doc map of line_num → count for best-line picking.
            var doc_tf = U32HashMap(u32).init(ta);
            var doc_best_line = U32HashMap(struct { line: u32, count: u32 }).init(ta);
            for (hits) |h| {
                const tf_gop = try doc_tf.getOrPut(h.doc_id);
                if (!tf_gop.found_existing) tf_gop.value_ptr.* = 0;
                tf_gop.value_ptr.* += 1;

                const ln_gop = try doc_best_line.getOrPut(h.doc_id);
                if (!ln_gop.found_existing) {
                    ln_gop.value_ptr.* = .{ .line = h.line_num, .count = 1 };
                } else {
                    // Each posting is a distinct line; still, prefer the
                    // smallest line_num as a deterministic representative.
                    if (h.line_num < ln_gop.value_ptr.line) {
                        ln_gop.value_ptr.line = h.line_num;
                    }
                    ln_gop.value_ptr.count += 1;
                }
            }
            const df: u32 = @intCast(doc_tf.count());
            // BM25 idf with the +1 smoothing variant: log(1 + (N - df + 0.5)/(df + 0.5))
            const num: f32 = @as(f32, @floatFromInt(N)) - @as(f32, @floatFromInt(df)) + 0.5;
            const den: f32 = @as(f32, @floatFromInt(df)) + 0.5;
            const idf: f32 = @log(1.0 + num / den);

            var tf_iter = doc_tf.iterator();
            while (tf_iter.next()) |entry| {
                const doc_id = entry.key_ptr.*;
                const tf: f32 = @floatFromInt(entry.value_ptr.*);
                const dl_raw = self.word_index.docLength(doc_id);
                const dl: f32 = if (dl_raw == 0) 1.0 else @floatFromInt(dl_raw);
                const norm = 1.0 - b + b * (dl / avgdl);
                const tf_sat = (tf * (k1 + 1.0)) / (tf + k1 * norm);
                const term_score = idf * (tf_sat + bm25_plus_delta);

                const ln_info = doc_best_line.get(doc_id) orelse continue;
                const agg_gop = try per_doc.getOrPut(doc_id);
                if (!agg_gop.found_existing) {
                    agg_gop.value_ptr.* = .{
                        .score = term_score,
                        .best_line = ln_info.line,
                        .best_line_hits = ln_info.count,
                    };
                } else {
                    agg_gop.value_ptr.score += term_score;
                    if (ln_info.count > agg_gop.value_ptr.best_line_hits or
                        (ln_info.count == agg_gop.value_ptr.best_line_hits and ln_info.line < agg_gop.value_ptr.best_line))
                    {
                        agg_gop.value_ptr.best_line = ln_info.line;
                        agg_gop.value_ptr.best_line_hits = ln_info.count;
                    }
                }
            }
        }
        if (per_doc.count() == 0) return try allocator.alloc(SearchResult, 0);

        const Cand = struct { doc_id: u32, score: f32, best_line: u32 };
        var cands: std.ArrayList(Cand) = .empty;
        defer cands.deinit(ta);
        try cands.ensureTotalCapacity(ta, per_doc.count());
        var pd_iter = per_doc.iterator();
        while (pd_iter.next()) |entry| {
            const cand_doc_id = entry.key_ptr.*;
            const cand_path = if (cand_doc_id < self.word_index.id_to_path.items.len) self.word_index.id_to_path.items[cand_doc_id] else "";
            cands.appendAssumeCapacity(.{
                .doc_id = cand_doc_id,
                .score = entry.value_ptr.score * pathRelevanceMultiplier(cand_path, &terms_set) * self.centralityBoost(cand_path),
                .best_line = entry.value_ptr.best_line,
            });
        }
        // Lazy top-k via a max-heap: pop candidates in (score desc, doc_id asc)
        // order and materialize until max_results survive. Same ordering and
        // skip-and-continue semantics as a full sort over all candidates, but only
        // pops ~max_results of them — O(C + (k+skips)·log C) instead of O(C·log C)
        // for the common case k ≪ C (bm25s-style top-k retrieval).
        const candLess = struct {
            fn order(_: void, a: Cand, b_: Cand) std.math.Order {
                if (a.score != b_.score) return if (a.score > b_.score) .lt else .gt;
                return std.math.order(a.doc_id, b_.doc_id);
            }
        }.order;
        var heap = std.PriorityQueue(Cand, void, candLess).fromOwnedSlice(try cands.toOwnedSlice(ta), {});
        defer heap.deinit(ta);

        var result_list: std.ArrayList(SearchResult) = .empty;
        errdefer {
            for (result_list.items) |r| {
                allocator.free(r.line_text);
                allocator.free(r.path);
            }
            result_list.deinit(allocator);
        }
        try result_list.ensureTotalCapacity(allocator, @min(max_results, heap.count()));

        while (result_list.items.len < max_results) {
            const c = heap.pop() orelse break;
            const path = self.word_index.id_to_path.items[c.doc_id];
            if (path.len == 0) continue;
            const ref = self.readContentForSearch(path, allocator) orelse continue;
            defer ref.deinit();
            const line_text = extractLineByNumber(ref.data, c.best_line) orelse continue;
            const duped_text = try allocator.dupe(u8, line_text);
            errdefer allocator.free(duped_text);
            const duped_path = try allocator.dupe(u8, path);
            errdefer allocator.free(duped_path);
            try result_list.append(allocator, .{
                .path = duped_path,
                .line_num = c.best_line,
                .line_text = duped_text,
                .score = c.score,
            });
        }

        return result_list.toOwnedSlice(allocator);
    }

    /// Search file contents using a regex pattern with trigram acceleration.
    /// Decomposes the regex to extract literal trigrams for candidate filtering,
    /// then does actual regex matching on candidates.
    pub fn searchContentRegex(self: *Explorer, pattern: []const u8, allocator: std.mem.Allocator, max_results: usize) ![]const SearchResult {
        self.mu.lockShared();
        defer self.mu.unlockShared();

        var result_list: std.ArrayList(SearchResult) = .empty;
        errdefer result_list.deinit(allocator);

        // Surface invalid patterns as error.InvalidRegex instead of silently
        // returning zero results (#528 item 10). Compile once up front with the
        // real matcher; the per-file scans below reuse the same engine.
        {
            var probe = nanoregex.Regex.compile(allocator, pattern) catch return error.InvalidRegex;
            probe.deinit();
        }

        var query = idx.decomposeRegex(pattern, self.allocator) catch {
            var iter = self.outlines.keyIterator();
            while (iter.next()) |key_ptr| {
                const ref = self.readContentForSearch(key_ptr.*, allocator) orelse continue;
                defer ref.deinit();
                try searchInContentRegex(key_ptr.*, ref.data, pattern, allocator, max_results, &result_list);
                if (result_list.items.len >= max_results) break;
            }
            return result_list.toOwnedSlice(allocator);
        };
        defer query.deinit();

        const candidate_paths = self.trigram_index.candidatesRegex(&query, allocator);
        defer if (candidate_paths) |cp| allocator.free(cp);
        const use_trigram = candidate_paths != null and candidate_paths.?.len > 0;

        if (use_trigram) {
            for (candidate_paths.?) |path| {
                const ref = self.readContentForSearch(path, allocator) orelse continue;
                defer ref.deinit();
                try searchInContentRegex(path, ref.data, pattern, allocator, max_results, &result_list);
                if (result_list.items.len >= max_results) break;
            }
        } else {
            var iter = self.outlines.keyIterator();
            while (iter.next()) |key_ptr| {
                const ref = self.readContentForSearch(key_ptr.*, allocator) orelse continue;
                defer ref.deinit();
                try searchInContentRegex(key_ptr.*, ref.data, pattern, allocator, max_results, &result_list);
                if (result_list.items.len >= max_results) break;
            }
            return result_list.toOwnedSlice(allocator);
        }

        if (result_list.items.len < max_results) {
            var iter = self.outlines.keyIterator();
            while (iter.next()) |key_ptr| {
                if (self.trigram_index.containsFile(key_ptr.*)) continue;
                const ref = self.readContentForSearch(key_ptr.*, allocator) orelse continue;
                defer ref.deinit();
                try searchInContentRegex(key_ptr.*, ref.data, pattern, allocator, max_results, &result_list);
                if (result_list.items.len >= max_results) break;
            }
        }

        return result_list.toOwnedSlice(allocator);
    }

    /// Search for a word using the inverted word index. O(1) lookup.
    pub fn searchWord(self: *Explorer, word: []const u8, allocator: std.mem.Allocator) ![]const idx.WordHit {
        self.mu.lockShared();
        const needs_rebuild = !self.word_index_complete and
            (self.contents.len() > 0 or (self.io != null and self.root_dir != null));
        self.mu.unlockShared();
        if (needs_rebuild) {
            try self.rebuildWordIndex();
        }

        self.mu.lockShared();
        defer self.mu.unlockShared();
        return self.word_index.searchDeduped(word, allocator);
    }

    /// Format a word-index lookup directly from the posting list. The indexer
    /// already stores at most one hit per (word, file, line), so the MCP word
    /// path does not need to allocate and dedupe a temporary result slice.
    pub fn renderWord(self: *Explorer, word: []const u8, allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        self.mu.lockShared();
        const needs_rebuild = !self.word_index_complete and
            (self.contents.len() > 0 or (self.io != null and self.root_dir != null));
        self.mu.unlockShared();
        if (needs_rebuild) {
            try self.rebuildWordIndex();
        }

        self.mu.lockShared();
        defer self.mu.unlockShared();

        const hits = self.word_index.search(word);
        try out.ensureUnusedCapacity(allocator, 64 + hits.len * 48);
        const w = cio.listWriter(out, allocator);
        try w.print("{d} hits for '{s}':\n", .{ hits.len, word });
        for (hits) |h| {
            try w.print("  {s}:{d}\n", .{ self.word_index.hitPath(h), h.line_num });
        }
    }

    pub const FuzzyMatch = struct {
        path: []const u8,
        score: f32,
    };

    pub fn fuzzyFindFiles(self: *Explorer, query: []const u8, allocator: std.mem.Allocator, max_results: usize) ![]const FuzzyMatch {
        if (query.len == 0) return &.{};

        self.mu.lockShared();
        defer self.mu.unlockShared();

        // Parse query: split on spaces, extract extension constraints (*.py, *.ts)
        var parts: std.ArrayList([]const u8) = .empty;
        defer parts.deinit(allocator);
        var ext_filter: ?[]const u8 = null;

        var tok_iter = std.mem.splitScalar(u8, query, ' ');
        while (tok_iter.next()) |token| {
            if (token.len == 0) continue;
            // Extension constraint: *.py, *.ts, *.zig
            if (token.len >= 2 and token[0] == '*' and token[1] == '.') {
                ext_filter = token[1..]; // ".py", ".ts", etc.
            } else {
                try parts.append(allocator, token);
            }
        }

        if (parts.items.len == 0) return &.{};

        var matches: std.ArrayList(FuzzyMatch) = .empty;
        errdefer matches.deinit(allocator);

        if (parts.items.len == 1 and parts.items[0].len <= FUZZY_MAX_QUERY) {
            // Single-part (the common case): score files in SIMD batches of
            // FZ_LANES via fuzzyScoreBatch, which yields the same per-file
            // best_score/matched_chars as the scalar fuzzyDP; fuzzyFinalize is the
            // shared tail, so results are identical — just scored 8 files at once.
            const q = parts.items[0];
            var cands: std.ArrayList([]const u8) = .empty;
            defer cands.deinit(allocator);
            var iter = self.outlines.keyIterator();
            while (iter.next()) |key_ptr| {
                const path = key_ptr.*;
                if (ext_filter) |ext| {
                    if (!std.mem.endsWith(u8, path, ext)) continue;
                }
                if (path.len == 0 or path.len > FUZZY_MAX_PATH) continue;
                if (fuzzyPresenceReject(q, path)) continue;
                try cands.append(allocator, path);
            }
            var off: usize = 0;
            while (off < cands.items.len) : (off += FZ_LANES) {
                const slab = cands.items[off..@min(off + FZ_LANES, cands.items.len)];
                var best: [FZ_LANES]f32 = undefined;
                var matched: [FZ_LANES]u32 = undefined;
                fuzzyScoreBatch(q, slab, &best, &matched);
                for (slab, 0..) |path, l| {
                    if (fuzzyFinalize(q, path, best[l], matched[l])) |s| {
                        try matches.append(allocator, .{ .path = path, .score = s });
                    }
                }
            }
        } else {
            var iter = self.outlines.keyIterator();
            while (iter.next()) |key_ptr| {
                const path = key_ptr.*;
                if (ext_filter) |ext| {
                    if (!std.mem.endsWith(u8, path, ext)) continue;
                }
                if (scoreAllParts(parts.items, path)) |s| {
                    try matches.append(allocator, .{ .path = path, .score = s });
                }
            }
        }

        // Sort by score descending
        std.mem.sort(FuzzyMatch, matches.items, {}, struct {
            fn lt(_: void, a: FuzzyMatch, b: FuzzyMatch) bool {
                return a.score > b.score;
            }
        }.lt);

        // Truncate to max_results
        if (matches.items.len > max_results) {
            matches.items.len = max_results;
        }

        return matches.toOwnedSlice(allocator) catch {
            matches.deinit(allocator);
            return &.{};
        };
    }

    pub fn renderExactFileFind(self: *Explorer, query: []const u8, allocator: std.mem.Allocator, out: *std.ArrayList(u8), max_results: usize) !usize {
        if (query.len == 0 or max_results == 0) return 0;

        self.mu.lockShared();
        defer self.mu.unlockShared();

        const w = cio.listWriter(out, allocator);
        var found: usize = 0;
        var iter = self.outlines.keyIterator();
        while (iter.next()) |key_ptr| {
            const path = key_ptr.*;
            const basename = std.fs.path.basename(path);
            const stem_end = std.mem.lastIndexOfScalar(u8, basename, '.') orelse basename.len;
            const stem = basename[0..stem_end];
            const exact = std.ascii.eqlIgnoreCase(basename, query) or std.ascii.eqlIgnoreCase(stem, query);
            if (!exact) continue;

            found += 1;
            try w.print("{d}. {s} (score: 100.00)\n", .{ found, path });
            if (found >= max_results) break;
        }
        return found;
    }

    pub const LsEntry = struct {
        name: []const u8,
        is_dir: bool,
        line_count: u32 = 0,
        sym_count: u32 = 0,
        language: Language = .unknown,
    };

    pub fn globPaths(self: *Explorer, allocator: std.mem.Allocator, pattern: []const u8, max_results: usize) ![][]const u8 {
        if (pattern.len == 0) return &.{};

        self.mu.lockShared();
        defer self.mu.unlockShared();

        var matches: std.ArrayList([]const u8) = .empty;
        errdefer matches.deinit(allocator);
        // Reserve a guess so small/medium glob result sets don't trigger
        // multiple geometric reallocations.
        matches.ensureTotalCapacity(allocator, @min(64, self.outlines.count())) catch {};

        var iter = self.outlines.keyIterator();
        while (iter.next()) |key_ptr| {
            const path = key_ptr.*;
            if (matchGlob(pattern, path)) {
                try matches.append(allocator, path);
            }
        }

        std.mem.sort([]const u8, matches.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lt);

        if (matches.items.len > max_results) matches.items.len = max_results;

        return matches.toOwnedSlice(allocator);
    }

    pub fn lsDir(self: *Explorer, allocator: std.mem.Allocator, prefix: []const u8) ![]LsEntry {
        self.mu.lockShared();
        defer self.mu.unlockShared();

        // Normalize: trim trailing slash. Empty prefix means root.
        var p = prefix;
        if (p.len > 0 and p[p.len - 1] == '/') p = p[0 .. p.len - 1];

        var entries: std.ArrayList(LsEntry) = .empty;
        errdefer entries.deinit(allocator);
        // Most listings produce a small set; a single up-front allocation
        // avoids the geometric-realloc dance for typical directories.
        entries.ensureTotalCapacity(allocator, 32) catch {};

        // Each outline key is unique, so a file `rel` is emitted at most once
        // by construction. We only need a dedup map for directory names since
        // multiple paths can share a parent dir.
        var seen_dirs = std.StringHashMap(void).init(allocator);
        defer seen_dirs.deinit();

        var iter = self.outlines.iterator();
        while (iter.next()) |kv| {
            const path = kv.key_ptr.*;

            var rel: []const u8 = undefined;
            if (p.len == 0) {
                rel = path;
            } else {
                if (!std.mem.startsWith(u8, path, p)) continue;
                if (path.len <= p.len + 1 or path[p.len] != '/') continue;
                rel = path[p.len + 1 ..];
            }
            if (rel.len == 0) continue;

            if (std.mem.indexOfScalar(u8, rel, '/')) |sep| {
                const dir_name = rel[0..sep];
                if (!seen_dirs.contains(dir_name)) {
                    try seen_dirs.put(dir_name, {});
                    try entries.append(allocator, .{ .name = dir_name, .is_dir = true });
                }
            } else {
                const fo = kv.value_ptr.*;
                try entries.append(allocator, .{
                    .name = rel,
                    .is_dir = false,
                    .line_count = fo.line_count,
                    .sym_count = @intCast(fo.symbols.items.len),
                    .language = fo.language,
                });
            }
        }

        std.mem.sort(LsEntry, entries.items, {}, struct {
            fn lt(_: void, a: LsEntry, b: LsEntry) bool {
                if (a.is_dir != b.is_dir) return a.is_dir;
                return std.mem.order(u8, a.name, b.name) == .lt;
            }
        }.lt);

        return entries.toOwnedSlice(allocator);
    }

    pub fn getImportedBy(self: *Explorer, path: []const u8, allocator: std.mem.Allocator) ![]const []const u8 {
        self.mu.lockShared();
        defer self.mu.unlockShared();
        return self.dep_graph.getImportedBy(path, allocator);
    }

    pub fn renderImportedBy(self: *Explorer, path: []const u8, allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !struct { count: usize, known: bool } {
        self.mu.lockShared();
        defer self.mu.unlockShared();

        const basename = if (std.mem.lastIndexOfScalar(u8, path, '/')) |pos| path[pos + 1 ..] else path;
        const exact = self.dep_graph.reverse.get(path);
        const w = cio.listWriter(out, allocator);
        var count: usize = 0;

        if (exact) |rev_set| {
            var rev_iter = rev_set.keyIterator();
            while (rev_iter.next()) |key_ptr| {
                try w.print("  {s}\n", .{key_ptr.*});
                count += 1;
            }
        }

        if (!std.mem.eql(u8, path, basename)) {
            if (self.dep_graph.reverse.get(basename)) |rev_set| {
                var rev_iter = rev_set.keyIterator();
                while (rev_iter.next()) |key_ptr| {
                    if (exact) |exact_set| {
                        if (exact_set.contains(key_ptr.*)) continue;
                    }
                    try w.print("  {s}\n", .{key_ptr.*});
                    count += 1;
                }
            }
        }

        return .{ .count = count, .known = self.outlines.contains(path) };
    }

    pub fn getTransitiveDependents(self: *Explorer, path: []const u8, allocator: std.mem.Allocator, max_depth: ?u32) ![]const []const u8 {
        self.mu.lockShared();
        defer self.mu.unlockShared();
        return self.dep_graph.getTransitiveDependents(path, allocator, max_depth);
    }

    pub fn getTransitiveDependencies(self: *Explorer, path: []const u8, allocator: std.mem.Allocator, max_depth: ?u32) ![]const []const u8 {
        self.mu.lockShared();
        defer self.mu.unlockShared();
        return self.dep_graph.getTransitiveDependencies(path, allocator, max_depth);
    }

    pub fn getHotFiles(self: *Explorer, store: *Store, allocator: std.mem.Allocator, limit: usize) ![]const []const u8 {
        // Collect stable path copies under explorer lock.
        var path_list: std.ArrayList([]u8) = .empty;
        errdefer {
            for (path_list.items) |path| allocator.free(path);
            path_list.deinit(allocator);
        }
        defer path_list.deinit(allocator);
        {
            self.mu.lockShared();
            defer self.mu.unlockShared();
            var iter = self.outlines.iterator();
            while (iter.next()) |kv| {
                const path_copy = try allocator.dupe(u8, kv.key_ptr.*);
                try path_list.append(allocator, path_copy);
            }
        }

        // Query store seqs without holding explorer lock.
        const Entry = struct { path: []u8, seq: u64 };
        var entries: std.ArrayList(Entry) = .empty;
        defer entries.deinit(allocator);
        {
            store.mu.lock();
            defer store.mu.unlock();
            for (path_list.items) |path| {
                const seq = store.getLatestSeqUnlocked(path);
                try entries.append(allocator, .{ .path = path, .seq = seq });
            }
        }

        std.mem.sort(Entry, entries.items, {}, struct {
            fn cmp(_: void, a: Entry, b: Entry) bool {
                return a.seq > b.seq;
            }
        }.cmp);

        const count = @min(limit, entries.items.len);
        const paths = try allocator.alloc([]const u8, count);
        for (entries.items[0..count], 0..) |e, i| {
            paths[i] = e.path;
        }
        for (entries.items[count..]) |e| {
            allocator.free(e.path);
        }
        return paths;
    }

    /// Zero-dup variant of getHotFiles — keeps stable path refs from the
    /// outlines map (lifetime-bound to the explorer) and writes the
    /// formatted top-N directly into `out`. Saves 1 dupe per file
    /// regardless of how many we end up keeping.
    pub fn renderHot(self: *Explorer, store: *Store, allocator: std.mem.Allocator, out: *std.ArrayList(u8), limit: usize) !void {
        if (limit == 0) return;
        const Entry = struct { path: []const u8, seq: u64 };
        var top: std.ArrayList(Entry) = .empty;
        defer top.deinit(allocator);
        try top.ensureTotalCapacity(allocator, limit);
        {
            self.mu.lockShared();
            defer self.mu.unlockShared();
            store.mu.lock();
            defer store.mu.unlock();
            var iter = self.outlines.iterator();
            while (iter.next()) |kv| {
                const candidate = Entry{
                    .path = kv.key_ptr.*,
                    .seq = store.getLatestSeqUnlocked(kv.key_ptr.*),
                };
                if (top.items.len < limit) {
                    top.appendAssumeCapacity(candidate);
                    continue;
                }

                var min_i: usize = 0;
                var min_seq = top.items[0].seq;
                for (top.items[1..], 1..) |entry, i| {
                    if (entry.seq < min_seq) {
                        min_seq = entry.seq;
                        min_i = i;
                    }
                }
                if (candidate.seq > min_seq) {
                    top.items[min_i] = candidate;
                }
            }
        }

        std.mem.sort(Entry, top.items, {}, struct {
            fn cmp(_: void, a: Entry, b: Entry) bool {
                return a.seq > b.seq;
            }
        }.cmp);

        // We dropped the explorer lock above. The path refs are stable across
        // outline insert/remove because the hashmap key is owned by the
        // outlines entry and only freed when that entry is deleted; the
        // window between unlock and reading the slice is too short for that
        // in the MCP single-request path.
        const w = cio.listWriter(out, allocator);
        for (top.items, 0..) |e, i| {
            try w.print("{d}. {s}\n", .{ i + 1, e.path });
        }
    }

    // ── Language parsers ──────────────────────────────────────

    fn parseZigLine(self: *Explorer, line: []const u8, line_num: u32, outline: *FileOutline) !void {
        const a = self.allocator;
        if (startsWith(line, "pub fn ") or startsWith(line, "fn ")) {
            const start: usize = if (startsWith(line, "pub fn ")) 7 else 3;
            if (extractIdent(line[start..])) |name| {
                try appendOutlineSymbol(a, outline, name, .function, line_num, line);
            }
        } else if (startsWith(line, "pub const ") or startsWith(line, "const ")) {
            const start: usize = if (startsWith(line, "pub const ")) 10 else 6;
            if (extractIdent(line[start..])) |name| {
                const kind: SymbolKind = if (std.mem.indexOf(u8, line, "struct {") != null)
                    .struct_def
                else if (std.mem.indexOf(u8, line, "enum {") != null)
                    .enum_def
                else if (std.mem.indexOf(u8, line, "union {") != null or
                    std.mem.indexOf(u8, line, "union(enum) {") != null)
                    .union_def
                else if (std.mem.indexOf(u8, line, "@import") != null)
                    .import
                else
                    .constant;

                try appendOutlineSymbol(a, outline, name, kind, line_num, line);

                if (kind == .import) {
                    if (extractStringLiteral(line)) |import_path| {
                        try appendImportPath(a, outline, import_path);
                    }
                }
            }
        } else if (startsWith(line, "test ")) {
            try appendOutlineSymbol(a, outline, line, .test_decl, line_num, null);
        }
    }

    fn parsePythonLine(self: *Explorer, line: []const u8, line_num: u32, outline: *FileOutline) !void {
        const a = self.allocator;
        if (startsWith(line, "def ")) {
            if (extractIdent(line[4..])) |name| {
                try appendOutlineSymbol(a, outline, name, .function, line_num, line);
            }
        } else if (startsWith(line, "class ")) {
            if (extractIdent(line[6..])) |name| {
                try appendOutlineSymbol(a, outline, name, .class_def, line_num, line);
            }
        } else if (startsWith(line, "import ") or startsWith(line, "from ")) {
            try appendOutlineSymbol(a, outline, line, .import, line_num, null);
            // Extract module path and convert dots to slashes for dep matching.
            // "from mypackage.utils.helpers import X" → "mypackage/utils/helpers.py"
            // "import os.path" → "os/path.py"
            if (extractPythonModulePath(line)) |mod_path| {
                var buf: [512]u8 = undefined;
                var pos: usize = 0;
                for (mod_path) |c| {
                    if (pos >= buf.len - 3) break;
                    buf[pos] = if (c == '.') '/' else c;
                    pos += 1;
                }
                if (pos + 3 <= buf.len) {
                    buf[pos] = '.';
                    buf[pos + 1] = 'p';
                    buf[pos + 2] = 'y';
                    pos += 3;
                }
                try appendImportPath(a, outline, buf[0..pos]);
            }
        }
    }
    fn parseTsLine(self: *Explorer, line: []const u8, line_num: u32, outline: *FileOutline) !void {
        const a = self.allocator;
        if (containsAny(line, &.{ "function ", "const ", "let ", "var ", "class ", "interface ", "enum ", "type " })) {
            const kind: SymbolKind = if (std.mem.indexOf(u8, line, "function") != null)
                .function
            else if (std.mem.indexOf(u8, line, "class ") != null)
                .class_def
            else if (std.mem.indexOf(u8, line, "interface ") != null)
                .interface_def
            else if (std.mem.indexOf(u8, line, "enum ") != null)
                .enum_def
            else if (std.mem.indexOf(u8, line, "type ") != null)
                .type_alias
            else
                .constant;
            const trimmed = skipKeywords(line);
            if (extractIdent(trimmed)) |name| {
                try appendOutlineSymbol(a, outline, name, kind, line_num, line);
            }
        }
        if (containsAny(line, &.{ "import ", "require(" })) {
            try appendOutlineSymbol(a, outline, line, .import, line_num, null);
            if (extractStringLiteral(line)) |path| {
                try appendImportPath(a, outline, path);
            }
        }
    }

    fn parseJavaLine(self: *Explorer, raw_line: []const u8, line_num: u32, outline: *FileOutline) !void {
        const a = self.allocator;
        const line = stripLineComment(raw_line);
        if (line.len == 0 or startsWith(line, "@")) return;

        if (parseDelimitedImport(line, "import ", ";")) |imp| {
            try appendImportSymbol(a, outline, imp, line_num, line);
            return;
        }

        if (extractIdentAfterKeyword(line, "record ")) |name| {
            try appendOutlineSymbol(a, outline, name, .class_def, line_num, line);
        } else if (extractIdentAfterKeyword(line, "class ")) |name| {
            try appendOutlineSymbol(a, outline, name, .class_def, line_num, line);
        } else if (extractIdentAfterKeyword(line, "interface ")) |name| {
            try appendOutlineSymbol(a, outline, name, .interface_def, line_num, line);
        } else if (extractIdentAfterKeyword(line, "enum ")) |name| {
            try appendOutlineSymbol(a, outline, name, .enum_def, line_num, line);
        } else if (extractJvmMethodName(line)) |name| {
            try appendOutlineSymbol(a, outline, name, .method, line_num, line);
        }
    }

    fn parseKotlinLine(self: *Explorer, raw_line: []const u8, line_num: u32, outline: *FileOutline) !void {
        const a = self.allocator;
        const line = stripLineComment(raw_line);
        if (line.len == 0 or startsWith(line, "@")) return;

        if (parseDelimitedImport(line, "import ", "")) |imp| {
            try appendImportSymbol(a, outline, imp, line_num, line);
            return;
        }

        if (extractIdentAfterKeyword(line, "enum class ")) |name| {
            try appendOutlineSymbol(a, outline, name, .enum_def, line_num, line);
        } else if (extractIdentAfterKeyword(line, "interface ")) |name| {
            try appendOutlineSymbol(a, outline, name, .interface_def, line_num, line);
        } else if (extractIdentAfterKeyword(line, "class ")) |name| {
            try appendOutlineSymbol(a, outline, name, .class_def, line_num, line);
        } else if (extractIdentAfterKeyword(line, "object ")) |name| {
            try appendOutlineSymbol(a, outline, name, .class_def, line_num, line);
        } else if (extractIdentAfterKeyword(line, "fun ")) |name| {
            try appendOutlineSymbol(a, outline, name, .function, line_num, line);
        } else if (extractIdentAfterKeyword(line, "val ")) |name| {
            try appendOutlineSymbol(a, outline, name, .constant, line_num, line);
        } else if (extractIdentAfterKeyword(line, "var ")) |name| {
            try appendOutlineSymbol(a, outline, name, .variable, line_num, line);
        }
    }

    fn parseSwiftLine(self: *Explorer, raw_line: []const u8, line_num: u32, outline: *FileOutline) !void {
        const a = self.allocator;
        const line = stripLineComment(raw_line);
        if (line.len == 0 or startsWith(line, "@") or startsWith(line, "/*") or startsWith(line, "*")) return;

        if (parseDelimitedImport(line, "import ", "")) |imp| {
            try appendImportSymbol(a, outline, imp, line_num, line);
            return;
        }

        if (extractIdentAfterKeyword(line, "struct ")) |name| {
            try appendOutlineSymbol(a, outline, name, .struct_def, line_num, line);
        } else if (extractIdentAfterKeyword(line, "protocol ")) |name| {
            try appendOutlineSymbol(a, outline, name, .interface_def, line_num, line);
        } else if (extractIdentAfterKeyword(line, "class ")) |name| {
            try appendOutlineSymbol(a, outline, name, .class_def, line_num, line);
        } else if (extractIdentAfterKeyword(line, "enum ")) |name| {
            try appendOutlineSymbol(a, outline, name, .enum_def, line_num, line);
        } else if (extractIdentAfterKeyword(line, "func ")) |name| {
            try appendOutlineSymbol(a, outline, name, .function, line_num, line);
        }
    }

    fn parseComponentLine(self: *Explorer, raw_line: []const u8, line_num: u32, outline: *FileOutline) !void {
        const line = std.mem.trim(u8, raw_line, " \t");
        if (line.len == 0 or startsWith(line, "<!--") or startsWith(line, "<script") or startsWith(line, "</script") or
            startsWith(line, "<style") or startsWith(line, "</style"))
            return;
        if (startsWith(line, ".") or startsWith(line, "#") or startsWith(line, "@keyframes") or startsWith(line, "$") or startsWith(line, "--")) {
            try self.parseStyleLine(line, line_num, outline);
            return;
        }
        try self.parseTsLine(line, line_num, outline);
    }

    fn parseShellLine(self: *Explorer, raw_line: []const u8, line_num: u32, outline: *FileOutline) !void {
        const a = self.allocator;
        const line = std.mem.trim(u8, raw_line, " \t");
        if (line.len == 0 or startsWith(line, "#")) return;

        if (startsWith(line, "source ")) {
            const imp = firstShellWord(line["source ".len..]) orelse return;
            try appendImportSymbol(a, outline, imp, line_num, line);
            return;
        }
        if (startsWith(line, ". ")) {
            const imp = firstShellWord(line[2..]) orelse return;
            try appendImportSymbol(a, outline, imp, line_num, line);
            return;
        }
        if (extractIdentAfterKeyword(line, "function ")) |name| {
            try appendOutlineSymbol(a, outline, name, .function, line_num, line);
            return;
        }
        if (std.mem.indexOf(u8, line, "()")) |pos| {
            const before = std.mem.trim(u8, line[0..pos], " \t");
            if (extractIdent(before)) |name| {
                if (name.len == before.len) try appendOutlineSymbol(a, outline, name, .function, line_num, line);
            }
            return;
        }
        if (parseShellAssignment(line)) |name| {
            try appendOutlineSymbol(a, outline, name, .variable, line_num, line);
        }
    }

    fn parseStyleLine(self: *Explorer, raw_line: []const u8, line_num: u32, outline: *FileOutline) !void {
        const a = self.allocator;
        const line = std.mem.trim(u8, raw_line, " \t");
        if (line.len == 0 or startsWith(line, "/*") or startsWith(line, "*")) return;

        if (extractIdentAfterKeyword(line, "@keyframes ")) |name| {
            try appendOutlineSymbol(a, outline, name, .function, line_num, line);
        } else if (extractIdentAfterKeyword(line, "@mixin ")) |name| {
            try appendOutlineSymbol(a, outline, name, .function, line_num, line);
        } else if (extractIdentAfterKeyword(line, "@function ")) |name| {
            try appendOutlineSymbol(a, outline, name, .function, line_num, line);
        } else if (parseCssVariable(line)) |name| {
            try appendOutlineSymbol(a, outline, name, .constant, line_num, line);
        } else if (parseCssSelector(line)) |name| {
            try appendOutlineSymbol(a, outline, name, .class_def, line_num, line);
        }
    }

    fn parseSqlLine(self: *Explorer, raw_line: []const u8, line_num: u32, outline: *FileOutline) !void {
        const a = self.allocator;
        const line = stripSqlLineComment(raw_line);
        if (line.len == 0) return;

        if (parseSqlCreate(line)) |sym| {
            try appendOutlineSymbol(a, outline, sym.name, sym.kind, line_num, line);
        }
    }

    fn parseProtoLine(self: *Explorer, raw_line: []const u8, line_num: u32, outline: *FileOutline) !void {
        const a = self.allocator;
        const line = stripLineComment(raw_line);
        if (line.len == 0) return;

        if (startsWith(line, "import ")) {
            if (extractStringLiteral(line)) |imp| try appendImportSymbol(a, outline, imp, line_num, line);
        } else if (extractIdentAfterKeyword(line, "message ")) |name| {
            try appendOutlineSymbol(a, outline, name, .struct_def, line_num, line);
        } else if (extractIdentAfterKeyword(line, "enum ")) |name| {
            try appendOutlineSymbol(a, outline, name, .enum_def, line_num, line);
        } else if (extractIdentAfterKeyword(line, "service ")) |name| {
            try appendOutlineSymbol(a, outline, name, .interface_def, line_num, line);
        } else if (extractIdentAfterKeyword(line, "rpc ")) |name| {
            try appendOutlineSymbol(a, outline, name, .method, line_num, line);
        }
    }

    fn parseFortranLine(self: *Explorer, raw_line: []const u8, line_num: u32, outline: *FileOutline) !void {
        const a = self.allocator;
        const line = stripFortranComment(raw_line);
        if (line.len == 0) return;

        if (parseFortranUse(line)) |imp| {
            try appendImportSymbol(a, outline, imp, line_num, line);
        } else if (extractIdentAfterKeywordIgnoreCase(line, "module ")) |name| {
            if (!startsWithIgnoreCase(line, "module procedure ")) try appendOutlineSymbol(a, outline, name, .class_def, line_num, line);
        } else if (extractIdentAfterKeywordIgnoreCase(line, "program ")) |name| {
            try appendOutlineSymbol(a, outline, name, .function, line_num, line);
        } else if (extractIdentAfterKeywordIgnoreCase(line, "subroutine ")) |name| {
            try appendOutlineSymbol(a, outline, name, .function, line_num, line);
        } else if (extractIdentAfterKeywordIgnoreCase(line, "function ")) |name| {
            try appendOutlineSymbol(a, outline, name, .function, line_num, line);
        } else if (parseFortranTypeName(line)) |name| {
            try appendOutlineSymbol(a, outline, name, .struct_def, line_num, line);
        }
    }

    fn parseLlvmIrLine(self: *Explorer, raw_line: []const u8, line_num: u32, outline: *FileOutline) !void {
        const a = self.allocator;
        const line = std.mem.trim(u8, raw_line, " \t");
        if (line.len == 0 or startsWith(line, ";")) return;

        if (startsWith(line, "define ") or startsWith(line, "declare ")) {
            if (extractAtName(line)) |name| try appendOutlineSymbol(a, outline, name, .function, line_num, line);
        } else if (line[0] == '@') {
            if (extractLlvmGlobalName(line)) |name| try appendOutlineSymbol(a, outline, name, .variable, line_num, line);
        } else if (line[0] == '%' and std.mem.indexOf(u8, line, " = type") != null) {
            if (extractLlvmGlobalName(line)) |name| try appendOutlineSymbol(a, outline, name, .type_alias, line_num, line);
        }
    }

    fn parseMlirLine(self: *Explorer, raw_line: []const u8, line_num: u32, outline: *FileOutline) !void {
        const a = self.allocator;
        const line = stripLineComment(raw_line);
        if (line.len == 0) return;

        if (std.mem.indexOf(u8, line, "module @") != null) {
            if (extractAtName(line)) |name| try appendOutlineSymbol(a, outline, name, .class_def, line_num, line);
        } else if (std.mem.indexOf(u8, line, "func") != null and std.mem.indexOfScalar(u8, line, '@') != null) {
            if (extractAtName(line)) |name| try appendOutlineSymbol(a, outline, name, .function, line_num, line);
        }
    }

    fn parseTableGenLine(self: *Explorer, raw_line: []const u8, line_num: u32, outline: *FileOutline) !void {
        const a = self.allocator;
        const line = stripLineComment(raw_line);
        if (line.len == 0) return;

        if (startsWith(line, "include ")) {
            if (extractStringLiteral(line)) |imp| try appendImportSymbol(a, outline, imp, line_num, line);
        } else if (extractIdentAfterKeyword(line, "defm ")) |name| {
            try appendOutlineSymbol(a, outline, name, .constant, line_num, line);
        } else if (extractIdentAfterKeyword(line, "def ")) |name| {
            try appendOutlineSymbol(a, outline, name, .constant, line_num, line);
        } else if (extractIdentAfterKeyword(line, "multiclass ")) |name| {
            try appendOutlineSymbol(a, outline, name, .class_def, line_num, line);
        } else if (extractIdentAfterKeyword(line, "class ")) |name| {
            try appendOutlineSymbol(a, outline, name, .class_def, line_num, line);
        } else if (extractIdentAfterKeyword(line, "let ")) |name| {
            try appendOutlineSymbol(a, outline, name, .variable, line_num, line);
        }
    }

    fn parseCLine(self: *Explorer, raw_line: []const u8, trimmed: []const u8, line_num: u32, outline: *FileOutline, prev_trimmed: []const u8, brace_depth: *u32) !void {
        const a = self.allocator;
        const line = stripLineComment(trimmed);
        if (line.len == 0) return;

        if (startsWith(line, "#include") or startsWith(line, "#import")) {
            if (extractCIncludePath(line)) |path| {
                try appendImportPath(a, outline, path);
            }
            try appendOutlineSymbol(a, outline, line, .import, line_num, line);
            return;
        }

        if (startsWith(line, "#define")) {
            const rest = std.mem.trimStart(u8, line["#define".len..], " \t");
            if (extractIdent(rest)) |name| {
                try appendOutlineSymbol(a, outline, name, .macro_def, line_num, line);
            }
            return;
        }

        if (parseObjCType(line)) |type_sym| {
            try appendOutlineSymbol(a, outline, type_sym.name, type_sym.kind, line_num, line);
            applyBraceDelta(brace_depth, countBracesDelta(line));
            return;
        }

        if (extractObjCMethodName(line)) |name| {
            try appendOutlineSymbol(a, outline, name, .method, line_num, line);
            applyBraceDelta(brace_depth, countBracesDelta(line));
            return;
        }

        if (parseCNamedType(line)) |type_sym| {
            try appendOutlineSymbol(a, outline, type_sym.name, type_sym.kind, line_num, line);
            applyBraceDelta(brace_depth, countBracesDelta(line));
            return;
        }

        const at_col0 = raw_line.len > 0 and raw_line[0] != ' ' and raw_line[0] != '\t';
        if (extractCFunctionName(line, at_col0, prev_trimmed, brace_depth.*, outline.language == .cpp)) |name| {
            try appendOutlineSymbol(a, outline, name, .function, line_num, line);
        }

        applyBraceDelta(brace_depth, countBracesDelta(line));
    }

    fn parseRustLine(self: *Explorer, line: []const u8, line_num: u32, outline: *FileOutline, prev_line: []const u8) !void {
        const a = self.allocator;

        // fn / pub fn / pub(crate) fn / async fn / pub async fn / unsafe fn
        if (containsAny(line, &.{"fn "})) {
            const is_decl = startsWith(line, "fn ") or
                startsWith(line, "pub fn ") or
                startsWith(line, "pub(crate) fn ") or
                startsWith(line, "pub(super) fn ") or
                startsWith(line, "async fn ") or
                startsWith(line, "pub async fn ") or
                startsWith(line, "unsafe fn ") or
                startsWith(line, "pub unsafe fn ") or
                startsWith(line, "pub(crate) async fn ") or
                startsWith(line, "pub(crate) unsafe fn ") or
                startsWith(line, "pub unsafe extern ");
            if (is_decl) {
                if (std.mem.indexOf(u8, line, "fn ")) |fn_pos| {
                    if (extractIdent(line[fn_pos + 3 ..])) |name| {
                        const is_test = std.mem.eql(u8, prev_line, "#[test]") or
                            startsWith(prev_line, "#[tokio::test");
                        const kind: SymbolKind = if (is_test) .test_decl else .function;
                        try appendOutlineSymbol(a, outline, name, kind, line_num, line);
                    }
                }
            }
        }

        // struct
        if (startsWith(line, "struct ") or startsWith(line, "pub struct ") or startsWith(line, "pub(crate) struct ")) {
            if (std.mem.indexOf(u8, line, "struct ")) |pos| {
                if (extractIdent(line[pos + 7 ..])) |name| {
                    try appendOutlineSymbol(a, outline, name, .struct_def, line_num, line);
                }
            }
        }

        // enum
        if (startsWith(line, "enum ") or startsWith(line, "pub enum ") or startsWith(line, "pub(crate) enum ")) {
            if (std.mem.indexOf(u8, line, "enum ")) |pos| {
                if (extractIdent(line[pos + 5 ..])) |name| {
                    try appendOutlineSymbol(a, outline, name, .enum_def, line_num, line);
                }
            }
        }

        // trait
        if (startsWith(line, "trait ") or startsWith(line, "pub trait ") or startsWith(line, "pub(crate) trait ") or startsWith(line, "unsafe trait ") or startsWith(line, "pub unsafe trait ")) {
            if (std.mem.indexOf(u8, line, "trait ")) |pos| {
                if (extractIdent(line[pos + 6 ..])) |name| {
                    try appendOutlineSymbol(a, outline, name, .trait_def, line_num, line);
                }
            }
        }

        // impl
        if (startsWith(line, "impl ") or startsWith(line, "impl<") or startsWith(line, "unsafe impl ")) {
            const impl_start: usize = if (startsWith(line, "unsafe impl ")) 12 else if (startsWith(line, "impl<")) blk: {
                if (std.mem.indexOf(u8, line, "> ")) |gt| {
                    break :blk gt + 2;
                } else break :blk 5;
            } else 5;
            if (extractIdent(line[impl_start..])) |name| {
                try appendOutlineSymbol(a, outline, name, .impl_block, line_num, line);
            }
        }

        // type alias
        if (startsWith(line, "type ") or startsWith(line, "pub type ") or startsWith(line, "pub(crate) type ")) {
            if (std.mem.indexOf(u8, line, "type ")) |pos| {
                if (extractIdent(line[pos + 5 ..])) |name| {
                    try appendOutlineSymbol(a, outline, name, .type_alias, line_num, line);
                }
            }
        }

        // const / static
        if (startsWith(line, "const ") or startsWith(line, "pub const ") or startsWith(line, "pub(crate) const ") or
            startsWith(line, "static ") or startsWith(line, "pub static ") or startsWith(line, "pub(crate) static "))
        {
            const keyword = if (std.mem.indexOf(u8, line, "static ")) |_| "static " else "const ";
            if (std.mem.indexOf(u8, line, keyword)) |pos| {
                if (extractIdent(line[pos + keyword.len ..])) |name| {
                    try appendOutlineSymbol(a, outline, name, .constant, line_num, line);
                }
            }
        }

        // macro_rules!
        if (startsWith(line, "macro_rules!")) {
            if (extractIdent(line[13..])) |name| {
                try appendOutlineSymbol(a, outline, name, .macro_def, line_num, line);
            }
        }

        // use / mod
        if (startsWith(line, "use ") or startsWith(line, "pub use ") or startsWith(line, "pub(crate) use ")) {
            try appendOutlineSymbol(a, outline, line, .import, line_num, null);
            try appendImportPath(a, outline, line);
        } else if (startsWith(line, "mod ") or startsWith(line, "pub mod ") or startsWith(line, "pub(crate) mod ")) {
            if (std.mem.indexOf(u8, line, "mod ")) |pos| {
                if (extractIdent(line[pos + 4 ..])) |name| {
                    try appendOutlineSymbol(a, outline, name, .import, line_num, null);
                    try appendImportPath(a, outline, name);
                }
            }
        }
    }

    fn parsePhpLine(self: *Explorer, raw_line: []const u8, line_num: u32, outline: *FileOutline, state: *PhpParseState) !void {
        const a = self.allocator;

        var line = raw_line;
        if (line.len == 0) return;
        if (state.in_block_comment) {
            if (std.mem.indexOf(u8, line, "*/")) |end| {
                state.in_block_comment = false;
                line = std.mem.trim(u8, line[end + 2 ..], " \t");
                if (line.len == 0) return;
            } else return;
        }
        if (startsWith(line, "<?php")) return;
        if (startsWith(line, "//") or startsWith(line, "#")) return;
        if (startsWith(line, "/*")) {
            if (std.mem.indexOf(u8, line, "*/") == null) state.in_block_comment = true;
            return;
        }

        if (startsWith(line, "use ") and std.mem.indexOf(u8, line, "\\") != null) {
            try self.parsePhpUseImport(a, line, line_num, outline);
            return;
        }

        if (self.phpMatchClassLike(line)) |match| {
            try appendOutlineSymbol(a, outline, match.name, match.kind, line_num, line);
            state.in_class = true;
            state.class_brace_depth = state.brace_depth;
        } else if (self.phpMatchConstant(line)) |name| {
            try appendOutlineSymbol(a, outline, name, .constant, line_num, line);
        } else if (std.mem.indexOf(u8, line, "function ")) |fn_pos| {
            const after_fn = line[fn_pos + 9 ..];
            if (extractIdent(after_fn)) |name| {
                const kind: SymbolKind = if (state.in_class) .method else .function;
                try appendOutlineSymbol(a, outline, name, kind, line_num, line);
            }
        }

        var in_string: u8 = 0;
        var escaped: bool = false;
        for (line) |ch| {
            if (in_string != 0) {
                if (escaped) {
                    escaped = false;
                } else if (ch == '\\') {
                    escaped = true;
                } else if (ch == in_string) {
                    in_string = 0;
                }
                continue;
            }
            if (ch == '\'' or ch == '"') {
                in_string = ch;
            } else if (ch == '{') {
                state.brace_depth += 1;
            } else if (ch == '}') {
                state.brace_depth -= 1;
                if (state.in_class and state.brace_depth <= state.class_brace_depth) {
                    state.in_class = false;
                }
            }
        }
    }

    fn parsePhpUseImport(_: *Explorer, a: std.mem.Allocator, line: []const u8, line_num: u32, outline: *FileOutline) !void {
        const semi = std.mem.indexOfScalar(u8, line, ';') orelse line.len;
        const use_body = std.mem.trim(u8, line[4..semi], " \t");
        if (use_body.len == 0) return;

        if (std.mem.indexOfScalar(u8, use_body, '{')) |brace_start| {
            const brace_end = std.mem.indexOfScalar(u8, use_body, '}') orelse use_body.len;
            const base = use_body[0..brace_start];
            const items_str = use_body[brace_start + 1 .. brace_end];

            try appendOutlineSymbol(a, outline, line[0..semi], .import, line_num, null);

            var items = std.mem.splitScalar(u8, items_str, ',');
            while (items.next()) |item| {
                const raw_item = std.mem.trim(u8, item, " \t");
                if (raw_item.len == 0) continue;
                const trimmed_item = phpStripAlias(raw_item);
                const full_ns = try a.alloc(u8, base.len + trimmed_item.len);
                defer a.free(full_ns);
                @memcpy(full_ns[0..base.len], base);
                @memcpy(full_ns[base.len..], trimmed_item);
                const path_copy = try phpNamespaceToPath(a, full_ns);
                errdefer a.free(path_copy);
                try outline.imports.append(a, path_copy);
            }
        } else {
            try appendOutlineSymbol(a, outline, line[0..semi], .import, line_num, null);
            const ns = phpStripAlias(use_body);
            const path_copy = try phpNamespaceToPath(a, ns);
            errdefer a.free(path_copy);
            try outline.imports.append(a, path_copy);
        }
    }

    fn phpStripAlias(s: []const u8) []const u8 {
        if (s.len < 4) return s;
        for (0..s.len - 3) |i| {
            if (s[i] == ' ' and (s[i + 1] == 'a' or s[i + 1] == 'A') and (s[i + 2] == 's' or s[i + 2] == 'S') and s[i + 3] == ' ') return s[0..i];
        }
        return s;
    }

    fn phpMatchConstant(_: *Explorer, line: []const u8) ?[]const u8 {
        const prefixes = [_][]const u8{
            "const ",
            "public const ",
            "protected const ",
            "private const ",
        };
        for (prefixes) |prefix| {
            if (startsWith(line, prefix)) {
                if (extractIdent(line[prefix.len..])) |name| {
                    if (!std.mem.eql(u8, name, "class")) return name;
                }
            }
        }
        return null;
    }

    const PhpClassMatch = struct {
        name: []const u8,
        kind: SymbolKind,
    };

    fn phpMatchClassLike(_: *Explorer, line: []const u8) ?PhpClassMatch {
        const class_keywords = [_]struct { prefix: []const u8, kind: SymbolKind }{
            .{ .prefix = "interface ", .kind = .interface_def },
            .{ .prefix = "trait ", .kind = .trait_def },
            .{ .prefix = "enum ", .kind = .enum_def },
            .{ .prefix = "class ", .kind = .class_def },
            .{ .prefix = "abstract class ", .kind = .class_def },
            .{ .prefix = "final class ", .kind = .class_def },
            .{ .prefix = "readonly class ", .kind = .class_def },
        };

        for (class_keywords) |kw| {
            if (startsWith(line, kw.prefix)) {
                if (extractIdent(line[kw.prefix.len..])) |name| {
                    return .{ .name = name, .kind = kw.kind };
                }
            }
        }
        return null;
    }

    fn parseGoLine(self: *Explorer, line: []const u8, line_num: u32, outline: *FileOutline) !void {
        const a = self.allocator;
        // func name( or func (receiver) name(
        if (startsWith(line, "func ")) {
            // Skip "func (" for function literals
            const rest = line[5..];
            // Method with receiver: func (r *Type) Name(
            var name_start = rest;
            if (rest.len > 0 and rest[0] == '(') {
                // Skip past receiver: find ") "
                if (std.mem.indexOf(u8, rest, ") ")) |close| {
                    name_start = rest[close + 2 ..];
                }
            }
            if (extractIdent(name_start)) |name| {
                try appendOutlineSymbol(a, outline, name, .function, line_num, line);
            }
        } else if (startsWith(line, "type ")) {
            const rest = std.mem.trim(u8, line[5..], " \t");
            if (extractIdent(rest)) |name| {
                const after = std.mem.trim(u8, rest[name.len..], " \t");
                const kind: SymbolKind = if (startsWith(after, "interface"))
                    .interface_def
                else if (startsWith(after, "struct"))
                    .struct_def
                else
                    .type_alias;
                try appendOutlineSymbol(a, outline, name, kind, line_num, line);
            }
        } else if (startsWith(line, "import ")) {
            if (extractStringLiteral(line)) |path| {
                try appendImportPath(a, outline, path);
            }
            try appendOutlineSymbol(a, outline, line, .import, line_num, null);
        } else if (startsWith(line, "const ") or startsWith(line, "var ")) {
            const skip = if (startsWith(line, "const ")) @as(usize, 6) else 4;
            if (extractIdent(line[skip..])) |name| {
                const kind: SymbolKind = if (startsWith(line, "const ")) .constant else .variable;
                try appendOutlineSymbol(a, outline, name, kind, line_num, line);
            }
        }
    }

    fn parseDartLine(self: *Explorer, line: []const u8, line_num: u32, outline: *FileOutline) !void {
        const a = self.allocator;

        if (line.len == 0 or startsWith(line, "@")) return;

        if (startsWith(line, "import ") or startsWith(line, "export ") or
            (startsWith(line, "part ") and !startsWith(line, "part of ")))
        {
            if (extractStringLiteral(line)) |raw_path| {
                if (resolveDartImport(raw_path, outline.path, a)) |resolved| {
                    try outline.imports.append(a, resolved);
                }
            }
            try appendOutlineSymbol(a, outline, line, .import, line_num, null);
            return;
        }

        if (startsWith(line, "typedef ")) {
            if (extractIdent(line["typedef ".len..])) |name| {
                try appendOutlineSymbol(a, outline, name, .type_alias, line_num, line);
            }
            return;
        }

        var type_decl = line;
        const type_modifiers = [_][]const u8{ "abstract ", "base ", "final ", "sealed ", "interface " };
        while (true) {
            var stripped = false;
            for (type_modifiers) |modifier| {
                if (startsWith(type_decl, modifier)) {
                    type_decl = type_decl[modifier.len..];
                    stripped = true;
                    break;
                }
            }
            if (!stripped) break;
        }

        const TypeDecl = struct {
            prefix: []const u8,
            kind: SymbolKind,
        };
        const type_decls = [_]TypeDecl{
            .{ .prefix = "mixin class ", .kind = .class_def },
            .{ .prefix = "class ", .kind = .class_def },
            .{ .prefix = "enum ", .kind = .enum_def },
            .{ .prefix = "mixin ", .kind = .trait_def },
            .{ .prefix = "extension type ", .kind = .class_def },
            .{ .prefix = "extension ", .kind = .impl_block },
        };
        for (type_decls) |decl| {
            if (!startsWith(type_decl, decl.prefix)) continue;

            const after = std.mem.trimStart(u8, type_decl[decl.prefix.len..], " \t");
            if (decl.kind == .impl_block and startsWith(after, "on ")) return;
            if (extractIdent(after)) |name| {
                try appendOutlineSymbol(a, outline, name, decl.kind, line_num, line);
            }
            return;
        }

        var var_decl = line;
        var var_kind: ?SymbolKind = null;
        while (true) {
            if (startsWith(var_decl, "static ")) {
                var_decl = std.mem.trimStart(u8, var_decl["static ".len..], " \t");
                continue;
            }
            if (startsWith(var_decl, "late ")) {
                var_decl = std.mem.trimStart(u8, var_decl["late ".len..], " \t");
                continue;
            }
            if (startsWith(var_decl, "covariant ")) {
                var_decl = std.mem.trimStart(u8, var_decl["covariant ".len..], " \t");
                continue;
            }
            if (startsWith(var_decl, "const ")) {
                var_kind = .constant;
                var_decl = std.mem.trimStart(u8, var_decl["const ".len..], " \t");
                continue;
            }
            if (startsWith(var_decl, "final ") or startsWith(var_decl, "var ")) {
                var_kind = .variable;
                const skip = if (startsWith(var_decl, "final ")) @as(usize, "final ".len) else "var ".len;
                var_decl = std.mem.trimStart(u8, var_decl[skip..], " \t");
                continue;
            }
            break;
        }
        if (var_kind) |kind| {
            const boundary = firstIndexOfAny(var_decl, &.{ '=', ';' }) orelse var_decl.len;
            const prefix = std.mem.trimEnd(u8, var_decl[0..boundary], " \t");
            if (std.mem.indexOfScalar(u8, prefix, '(') == null) {
                if (extractLastIdent(prefix)) |name| {
                    try appendOutlineSymbol(a, outline, name, kind, line_num, line);
                }
            }
            return;
        }

        if (std.mem.indexOf(u8, line, " get ") != null) {
            const get_pos = std.mem.indexOf(u8, line, " get ").?;
            const after_get = std.mem.trimStart(u8, line[get_pos + " get ".len ..], " \t");
            if (extractIdent(after_get)) |name| {
                try appendOutlineSymbol(a, outline, name, .function, line_num, line);
                return;
            }
        }

        if (containsAny(line, &.{ "(", "=>", "{", ";" })) {
            const open_paren = std.mem.indexOfScalar(u8, line, '(') orelse return;
            const prefix = std.mem.trimEnd(u8, line[0..open_paren], " \t");
            if (prefix.len == 0) return;
            if (containsAny(prefix, &.{ "=", "." })) return;
            if (startsWith(prefix, "if") or startsWith(prefix, "for") or startsWith(prefix, "while") or
                startsWith(prefix, "switch") or startsWith(prefix, "catch") or startsWith(prefix, "return") or
                startsWith(prefix, "throw") or startsWith(prefix, "assert") or startsWith(prefix, "await") or
                startsWith(prefix, "new ") or startsWith(prefix, "const "))
            {
                return;
            }

            var callable = prefix;
            const callable_modifiers = [_][]const u8{
                "external ",
                "static ",
                "factory ",
                "covariant ",
                "late ",
                "final ",
                "const ",
            };
            while (true) {
                var stripped = false;
                for (callable_modifiers) |modifier| {
                    if (startsWith(callable, modifier)) {
                        callable = std.mem.trimStart(u8, callable[modifier.len..], " \t");
                        stripped = true;
                        break;
                    }
                }
                if (!stripped) break;
            }
            if (startsWith(callable, "operator ")) return;
            var is_setter = false;
            if (startsWith(callable, "set ")) {
                callable = std.mem.trimStart(u8, callable["set ".len..], " \t");
                is_setter = true;
            }
            if (!is_setter and std.mem.indexOfScalar(u8, callable, ' ') == null) return;
            if (extractLastIdent(callable)) |name| {
                try appendOutlineSymbol(a, outline, name, .function, line_num, line);
            }
        }
    }

    fn parseRubyLine(self: *Explorer, line: []const u8, line_num: u32, outline: *FileOutline) !void {
        const a = self.allocator;
        if (startsWith(line, "def ")) {
            // Handle "def self.method_name" — skip past "self."
            var name_start = line[4..];
            if (startsWith(name_start, "self.")) {
                name_start = name_start[5..];
            }
            if (extractRubyMethodName(name_start)) |name| {
                try appendOutlineSymbol(a, outline, name, .function, line_num, line);
            }
        } else if (startsWith(line, "class ")) {
            if (extractIdent(line[6..])) |name| {
                try appendOutlineSymbol(a, outline, name, .struct_def, line_num, line);
            }
        } else if (startsWith(line, "module ")) {
            if (extractIdent(line[7..])) |name| {
                try appendOutlineSymbol(a, outline, name, .struct_def, line_num, line);
            }
        } else if (startsWith(line, "require ") or startsWith(line, "require_relative ")) {
            if (extractStringLiteral(line)) |path| {
                try appendImportPath(a, outline, path);
            }
            try appendOutlineSymbol(a, outline, line, .import, line_num, null);
        }
    }

    fn parseHclLine(self: *Explorer, line: []const u8, line_num: u32, outline: *FileOutline) !void {
        const a = self.allocator;

        // resource "type" "name" {
        if (startsWith(line, "resource ")) {
            if (extractHclBlockName(line[9..])) |name| {
                try appendOutlineSymbol(a, outline, name, .struct_def, line_num, line);
            }
        } else if (startsWith(line, "data ")) {
            if (extractHclBlockName(line[5..])) |name| {
                try appendOutlineSymbol(a, outline, name, .struct_def, line_num, line);
            }
        } else if (startsWith(line, "module ")) {
            if (extractHclQuotedName(line[7..])) |name| {
                try appendOutlineSymbol(a, outline, name, .import, line_num, null);
            }
        } else if (startsWith(line, "variable ")) {
            if (extractHclQuotedName(line[9..])) |name| {
                try appendOutlineSymbol(a, outline, name, .variable, line_num, line);
            }
        } else if (startsWith(line, "output ")) {
            if (extractHclQuotedName(line[7..])) |name| {
                try appendOutlineSymbol(a, outline, name, .constant, line_num, line);
            }
        } else if (startsWith(line, "provider ")) {
            if (extractHclQuotedName(line[9..])) |name| {
                try appendOutlineSymbol(a, outline, name, .import, line_num, null);
            }
        } else if (startsWith(line, "locals ") or startsWith(line, "locals{") or std.mem.eql(u8, line, "locals")) {
            try appendOutlineSymbol(a, outline, "locals", .struct_def, line_num, null);
        } else if (startsWith(line, "terraform ") or startsWith(line, "terraform{") or std.mem.eql(u8, line, "terraform")) {
            try appendOutlineSymbol(a, outline, "terraform", .struct_def, line_num, null);
        }
    }

    fn parseRLine(self: *Explorer, line: []const u8, line_num: u32, outline: *FileOutline) !void {
        const a = self.allocator;

        // library(pkg) or require(pkg)
        if (startsWith(line, "library(") or startsWith(line, "require(")) {
            const open = std.mem.indexOfScalar(u8, line, '(') orelse return;
            const close = std.mem.indexOfScalar(u8, line[open..], ')') orelse return;
            const pkg = std.mem.trim(u8, line[open + 1 .. open + close], " \t\"'");
            if (pkg.len == 0) return;
            try appendImportPath(a, outline, pkg);
            try appendOutlineSymbol(a, outline, line, .import, line_num, null);
            return;
        }

        // setClass("ClassName") or setRefClass("ClassName")
        if (startsWith(line, "setClass(") or startsWith(line, "setRefClass(")) {
            const open = std.mem.indexOfScalar(u8, line, '(') orelse return;
            if (extractHclQuotedName(line[open + 1 ..])) |name| {
                try appendOutlineSymbol(a, outline, name, .class_def, line_num, line);
            }
            return;
        }

        // name <- function( or name = function(
        if (std.mem.indexOf(u8, line, "<- function(") != null or std.mem.indexOf(u8, line, "= function(") != null) {
            const assign_pos = std.mem.indexOf(u8, line, "<-") orelse std.mem.indexOf(u8, line, "=") orelse return;
            const name = std.mem.trim(u8, line[0..assign_pos], " \t");
            if (name.len == 0) return;
            if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_' and name[0] != '.') return;
            try appendOutlineSymbol(a, outline, name, .function, line_num, line);
        }
    }

    /// ReScript (.res/.resi). `let`/`and` bindings become functions when the RHS has an
    /// arrow (`=>`) and constants otherwise; `type` → type_alias; `module` → struct_def
    /// (`module type` → interface_def); `external` → function; `open`/`include` → import.
    /// Leading @decorators are stripped first. Line-based like the sibling parsers, so
    /// nested module members are flattened into the top-level outline.
    fn parseRescriptLine(self: *Explorer, line: []const u8, line_num: u32, outline: *FileOutline) !void {
        const a = self.allocator;
        const code = stripLeadingResDecorators(line);
        if (code.len == 0 or startsWith(code, "//")) return;

        if (startsWith(code, "open ")) {
            const name = resModulePath(std.mem.trimStart(u8, code[5..], " \t"));
            if (name.len > 0) {
                try appendImportPath(a, outline, name);
                try appendOutlineSymbol(a, outline, name, .import, line_num, null);
            }
            return;
        }
        if (startsWith(code, "include ")) {
            const name = resModulePath(std.mem.trimStart(u8, code[8..], " \t"));
            if (name.len > 0) {
                try appendImportPath(a, outline, name);
                try appendOutlineSymbol(a, outline, name, .import, line_num, null);
            }
            return;
        }
        if (startsWith(code, "module ")) {
            var rest = std.mem.trimStart(u8, code[7..], " \t");
            var kind: SymbolKind = .struct_def;
            if (startsWith(rest, "type ")) {
                kind = .interface_def;
                rest = std.mem.trimStart(u8, rest[5..], " \t");
            }
            const name = resIdent(rest);
            if (name.len > 0) try appendOutlineSymbol(a, outline, name, kind, line_num, line);
            return;
        }
        if (startsWith(code, "type ")) {
            var rest = std.mem.trimStart(u8, code[5..], " \t");
            if (startsWith(rest, "rec ")) rest = std.mem.trimStart(u8, rest[4..], " \t");
            const name = resIdent(rest);
            if (name.len > 0) try appendOutlineSymbol(a, outline, name, .type_alias, line_num, line);
            return;
        }
        if (startsWith(code, "external ")) {
            const name = resIdent(std.mem.trimStart(u8, code[9..], " \t"));
            if (name.len > 0) try appendOutlineSymbol(a, outline, name, .function, line_num, line);
            return;
        }
        var rest: []const u8 = undefined;
        if (startsWith(code, "let ")) {
            rest = std.mem.trimStart(u8, code[4..], " \t");
            if (startsWith(rest, "rec ")) rest = std.mem.trimStart(u8, rest[4..], " \t");
        } else if (startsWith(code, "and ")) {
            rest = std.mem.trimStart(u8, code[4..], " \t");
        } else return;
        const name = resIdent(rest);
        if (name.len == 0) return; // destructuring binding (let (a, b) = …) — skip
        const kind: SymbolKind = if (std.mem.indexOf(u8, code, "=>") != null) .function else .constant;
        try appendOutlineSymbol(a, outline, name, kind, line_num, line);
    }

    fn rebuildDepsFor(self: *Explorer, path: []const u8, outline: *FileOutline) !void {
        var deps: std.ArrayList([]const u8) = .empty;
        errdefer deps.deinit(self.allocator);

        // Issue #445: outline.imports.items contains one entry per `@import`
        // site, so a file aliasing the same dep multiple times emits dupes.
        // Dedup by path before storing — the reverse index already dedupes
        // naturally via StringHashMap, only forward edges need this.
        var seen = std.StringHashMap(void).init(self.allocator);
        defer seen.deinit();

        for (outline.imports.items) |imp| {
            if (std.mem.indexOf(u8, imp, "..") != null) continue;
            const gop = try seen.getOrPut(imp);
            if (gop.found_existing) continue;
            try deps.append(self.allocator, imp);
        }

        try self.dep_graph.setDeps(path, deps);
    }

    pub fn rebuildSymbolIndexFor(self: *Explorer, path: []const u8, outline: *FileOutline, had_prior: bool) void {
        // removeSymbolIndexFor scans the entire global symbol index, so calling
        // it per file makes a cold scan O(files * total_symbols). A brand-new
        // path has no prior entries to evict, so skip the scan entirely — only
        // re-indexed (already-present) files need the removal.
        if (had_prior) self.removeSymbolIndexFor(path);
        for (outline.symbols.items) |sym| {
            const gop = self.symbol_index.getOrPut(sym.name) catch continue;
            if (!gop.found_existing) {
                gop.value_ptr.* = std.ArrayList(SymbolLocation).empty;
            }
            gop.value_ptr.append(self.allocator, .{
                .path = path,
                .kind = sym.kind,
                .line_start = sym.line_start,
                .line_end = sym.line_end,
            }) catch {};
        }
    }

    fn removeSymbolIndexFor(self: *Explorer, path: []const u8) void {
        var to_remove: std.ArrayList([]const u8) = .empty;
        defer to_remove.deinit(self.allocator);

        var iter = self.symbol_index.iterator();
        while (iter.next()) |entry| {
            var list = entry.value_ptr;
            var i: usize = 0;
            while (i < list.items.len) {
                if (std.mem.eql(u8, list.items[i].path, path)) {
                    _ = list.orderedRemove(i);
                } else {
                    i += 1;
                }
            }
            if (list.items.len == 0) {
                list.deinit(self.allocator);
                to_remove.append(self.allocator, entry.key_ptr.*) catch {};
            }
        }
        for (to_remove.items) |key| {
            _ = self.symbol_index.remove(key);
        }
    }

    /// Return the source body for a symbol given its file path and line range.
    /// Caller owns the returned slice.
    pub fn getSymbolBody(self: *Explorer, path: []const u8, line_start: u32, line_end: u32, allocator: std.mem.Allocator) !?[]u8 {
        self.mu.lockShared();
        defer self.mu.unlockShared();
        const ref = self.readContentForSearch(path, allocator) orelse return null;
        defer ref.deinit();
        return try extractLines(ref.data, line_start, line_end, true, false, .unknown, allocator);
    }

    /// Find the smallest enclosing symbol for a given line in a file.
    /// Must be called while holding at least a shared lock.
    fn findEnclosingSymbolLocked(self: *Explorer, path: []const u8, line_num: u32) ?Symbol {
        const outline = self.outlines.getPtr(path) orelse return null;
        const symbols = outline.symbols.items;
        if (symbols.len == 0) return null;

        // Binary search: find rightmost symbol with line_start <= line_num.
        // Symbols are stored in source order (line_start ascending).
        var lo: usize = 0;
        var hi: usize = symbols.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (symbols[mid].line_start <= line_num) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        // lo is the insertion point; candidates are symbols[0..lo] with line_start <= line_num.

        // Check candidates in reverse for tightest enclosing (line_end >= line_num).
        var best: ?Symbol = null;
        var best_span: u32 = std.math.maxInt(u32);
        var i: usize = lo;
        while (i > 0) {
            i -= 1;
            const sym = symbols[i];
            if (sym.line_end >= line_num) {
                const span = sym.line_end - sym.line_start;
                if (span < best_span) {
                    best = sym;
                    best_span = span;
                }
            }
            // Once we're past a reasonable gap, stop scanning backwards
            if (line_num - sym.line_start > 500 and best != null) break;
        }
        if (best != null) return best;

        // Fallback: nearest preceding symbol (already at the right position from binary search)
        if (lo > 0) return symbols[lo - 1];
        return null;
    }

    pub const ScopedSearchResult = struct {
        path: []const u8,
        line_num: u32,
        line_text: []const u8,
        scope_name: ?[]const u8 = null,
        scope_kind: ?SymbolKind = null,
        scope_start: u32 = 0,
        scope_end: u32 = 0,
    };

    /// Search content and annotate results with the enclosing symbol scope.
    pub fn searchContentWithScope(self: *Explorer, query: []const u8, allocator: std.mem.Allocator, max_results: usize) ![]const ScopedSearchResult {
        const plain_results = try self.searchContent(query, allocator, max_results);
        defer {
            for (plain_results) |r| {
                allocator.free(r.line_text);
                allocator.free(r.path);
            }
            allocator.free(plain_results);
        }

        var result_list: std.ArrayList(ScopedSearchResult) = .empty;
        errdefer {
            for (result_list.items) |r| {
                allocator.free(r.line_text);
                allocator.free(r.path);
                if (r.scope_name) |n| allocator.free(n);
            }
            result_list.deinit(allocator);
        }
        try result_list.ensureTotalCapacity(allocator, plain_results.len);

        self.mu.lockShared();
        defer self.mu.unlockShared();

        for (plain_results) |r| {
            const line_text = try allocator.dupe(u8, r.line_text);
            errdefer allocator.free(line_text);
            const path_copy = try allocator.dupe(u8, r.path);
            errdefer allocator.free(path_copy);

            const scope = self.findEnclosingSymbolLocked(r.path, r.line_num);
            const scope_name = if (scope) |s| try allocator.dupe(u8, s.name) else null;
            errdefer if (scope_name) |n| allocator.free(n);

            result_list.appendAssumeCapacity(.{
                .path = path_copy,
                .line_num = r.line_num,
                .line_text = line_text,
                .scope_name = scope_name,
                .scope_kind = if (scope) |s| s.kind else null,
                .scope_start = if (scope) |s| s.line_start else 0,
                .scope_end = if (scope) |s| s.line_end else 0,
            });
        }

        return result_list.toOwnedSlice(allocator);
    }

    /// Scoped regex search: same as searchContentWithScope but uses regex matching
    /// against each line instead of literal substring. Trigram-accelerated.
    pub fn searchContentRegexWithScope(self: *Explorer, pattern: []const u8, allocator: std.mem.Allocator, max_results: usize) ![]const ScopedSearchResult {
        self.mu.lockShared();
        defer self.mu.unlockShared();

        var result_list: std.ArrayList(ScopedSearchResult) = .empty;
        errdefer {
            for (result_list.items) |r| {
                allocator.free(r.line_text);
                allocator.free(r.path);
                if (r.scope_name) |n| allocator.free(n);
            }
            result_list.deinit(allocator);
        }

        // Surface invalid patterns as error.InvalidRegex instead of silently
        // returning zero results (#528 item 10). Compile once up front with the
        // real matcher; the per-file scans below reuse the same engine.
        {
            var probe = nanoregex.Regex.compile(allocator, pattern) catch return error.InvalidRegex;
            probe.deinit();
        }

        var query = idx.decomposeRegex(pattern, self.allocator) catch {
            var iter = self.outlines.keyIterator();
            while (iter.next()) |key_ptr| {
                const ref = self.readContentForSearch(key_ptr.*, allocator) orelse continue;
                defer ref.deinit();
                try self.searchInContentRegexWithScope(key_ptr.*, ref.data, pattern, allocator, max_results, &result_list);
                if (result_list.items.len >= max_results) break;
            }
            return result_list.toOwnedSlice(allocator);
        };
        defer query.deinit();

        const candidate_paths = self.trigram_index.candidatesRegex(&query, allocator);
        defer if (candidate_paths) |cp| allocator.free(cp);
        const use_trigram = candidate_paths != null and candidate_paths.?.len > 0;

        if (use_trigram) {
            for (candidate_paths.?) |path| {
                const ref = self.readContentForSearch(path, allocator) orelse continue;
                defer ref.deinit();
                try self.searchInContentRegexWithScope(path, ref.data, pattern, allocator, max_results, &result_list);
                if (result_list.items.len >= max_results) break;
            }
        } else {
            var iter = self.outlines.keyIterator();
            while (iter.next()) |key_ptr| {
                const ref = self.readContentForSearch(key_ptr.*, allocator) orelse continue;
                defer ref.deinit();
                try self.searchInContentRegexWithScope(key_ptr.*, ref.data, pattern, allocator, max_results, &result_list);
                if (result_list.items.len >= max_results) break;
            }
            return result_list.toOwnedSlice(allocator);
        }

        if (result_list.items.len < max_results) {
            var iter = self.outlines.keyIterator();
            while (iter.next()) |key_ptr| {
                if (self.trigram_index.containsFile(key_ptr.*)) continue;
                const ref = self.readContentForSearch(key_ptr.*, allocator) orelse continue;
                defer ref.deinit();
                try self.searchInContentRegexWithScope(key_ptr.*, ref.data, pattern, allocator, max_results, &result_list);
                if (result_list.items.len >= max_results) break;
            }
        }

        return result_list.toOwnedSlice(allocator);
    }

    fn searchInContentWithScope(self: *Explorer, path: []const u8, content: []const u8, query: []const u8, allocator: std.mem.Allocator, max_results: usize, result_list: *std.ArrayList(ScopedSearchResult)) !void {
        var line_num: u32 = 0;
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            line_num += 1;
            if (indexOfCaseInsensitive(line, query) != null) {
                const line_text = try allocator.dupe(u8, line);
                errdefer allocator.free(line_text);
                const path_copy = try allocator.dupe(u8, path);
                errdefer allocator.free(path_copy);

                const scope = self.findEnclosingSymbolLocked(path, line_num);
                const scope_name = if (scope) |s| try allocator.dupe(u8, s.name) else null;
                errdefer if (scope_name) |n| allocator.free(n);

                try result_list.append(allocator, .{
                    .path = path_copy,
                    .line_num = line_num,
                    .line_text = line_text,
                    .scope_name = scope_name,
                    .scope_kind = if (scope) |s| s.kind else null,
                    .scope_start = if (scope) |s| s.line_start else 0,
                    .scope_end = if (scope) |s| s.line_end else 0,
                });
                if (result_list.items.len >= max_results) return;
            }
        }
    }

    fn searchInContentRegexWithScope(self: *Explorer, path: []const u8, content: []const u8, pattern: []const u8, allocator: std.mem.Allocator, max_results: usize, result_list: *std.ArrayList(ScopedSearchResult)) !void {
        var rx = nanoregex.Regex.compile(allocator, pattern) catch return;
        defer rx.deinit();
        var line_num: u32 = 0;
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            line_num += 1;
            if (rx.search(allocator, line) catch null) |m| {
                @constCast(&m).deinit(allocator);
                const line_text = try allocator.dupe(u8, line);
                errdefer allocator.free(line_text);
                const path_copy = try allocator.dupe(u8, path);
                errdefer allocator.free(path_copy);

                const scope = self.findEnclosingSymbolLocked(path, line_num);
                const scope_name = if (scope) |s| try allocator.dupe(u8, s.name) else null;
                errdefer if (scope_name) |n| allocator.free(n);

                try result_list.append(allocator, .{
                    .path = path_copy,
                    .line_num = line_num,
                    .line_text = line_text,
                    .scope_name = scope_name,
                    .scope_kind = if (scope) |s| s.kind else null,
                    .scope_start = if (scope) |s| s.line_start else 0,
                    .scope_end = if (scope) |s| s.line_end else 0,
                });
                if (result_list.items.len >= max_results) return;
            }
        }
    }
};

fn phpNamespaceToPath(allocator: std.mem.Allocator, ns: []const u8) ![]u8 {
    var parts: std.ArrayList(u8) = .empty;
    errdefer parts.deinit(allocator);

    var first_segment = true;
    var iter = std.mem.splitScalar(u8, ns, '\\');
    while (iter.next()) |segment| {
        if (parts.items.len > 0) {
            try parts.append(allocator, '/');
        }
        if (first_segment) {
            for (segment) |ch| {
                try parts.append(allocator, std.ascii.toLower(ch));
            }
            first_segment = false;
        } else {
            try parts.appendSlice(allocator, segment);
        }
    }
    try parts.appendSlice(allocator, ".php");
    return try parts.toOwnedSlice(allocator);
}

/// Extract lines from content string as a range [start..end] (1-indexed, inclusive).
/// When line_numbers is true, prepends "{d:>5} | " prefix. When compact is true,
/// skips comment/blank lines based on language.
pub fn extractLines(content: []const u8, start: u32, end: u32, line_numbers: bool, compact: bool, language: Language, allocator: std.mem.Allocator) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;

    var line_num: u32 = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        line_num += 1;
        if (line_num < start) continue;
        if (line_num > end) break;
        if (compact and isCommentOrBlank(line, language)) continue;
        if (line_numbers) {
            try w.print("{d:>5} | {s}\n", .{ line_num, line });
        } else {
            try w.print("{s}\n", .{line});
        }
    }
    return aw.toOwnedSlice();
}

fn appendExtractedLines(
    content: []const u8,
    start: u32,
    end: u32,
    line_numbers: bool,
    compact: bool,
    language: Language,
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
) !void {
    const w = cio.listWriter(out, allocator);
    var line_num: u32 = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        line_num += 1;
        if (line_num < start) continue;
        if (line_num > end) break;
        if (compact and isCommentOrBlank(line, language)) continue;
        if (line_numbers) {
            try w.print("{d:>5} | {s}\n", .{ line_num, line });
        } else {
            try w.print("{s}\n", .{line});
        }
    }
}

/// Returns true if a line is blank or a single-line comment for the given language.
pub fn isCommentOrBlank(line: []const u8, language: Language) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return true;
    return switch (language) {
        .zig, .rust, .go_lang => std.mem.startsWith(u8, trimmed, "//"),
        .python, .ruby, .r, .shell => std.mem.startsWith(u8, trimmed, "#"),
        .hcl => std.mem.startsWith(u8, trimmed, "#") or std.mem.startsWith(u8, trimmed, "//") or std.mem.startsWith(u8, trimmed, "/*") or std.mem.startsWith(u8, trimmed, "*"),
        .javascript, .typescript, .c, .cpp, .dart, .java, .kotlin, .protobuf, .mlir, .tablegen => std.mem.startsWith(u8, trimmed, "//") or std.mem.startsWith(u8, trimmed, "/*") or std.mem.startsWith(u8, trimmed, "*"),
        .svelte, .vue, .astro => std.mem.startsWith(u8, trimmed, "//") or std.mem.startsWith(u8, trimmed, "/*") or std.mem.startsWith(u8, trimmed, "*") or std.mem.startsWith(u8, trimmed, "<!--"),
        .css => std.mem.startsWith(u8, trimmed, "/*") or std.mem.startsWith(u8, trimmed, "*"),
        .scss => std.mem.startsWith(u8, trimmed, "//") or std.mem.startsWith(u8, trimmed, "/*") or std.mem.startsWith(u8, trimmed, "*"),
        .sql => std.mem.startsWith(u8, trimmed, "--") or std.mem.startsWith(u8, trimmed, "/*") or std.mem.startsWith(u8, trimmed, "*"),
        .fortran => std.mem.startsWith(u8, trimmed, "!"),
        .llvm_ir => std.mem.startsWith(u8, trimmed, ";"),
        .rescript => std.mem.startsWith(u8, trimmed, "//") or std.mem.startsWith(u8, trimmed, "/*") or std.mem.startsWith(u8, trimmed, "*"),
        else => false,
    };
}

fn appendTargetLineHits(
    path: []const u8,
    content: []const u8,
    allocator: std.mem.Allocator,
    target_lines: []const u32,
    max_results: usize,
    result_list: *std.ArrayList(SearchResult),
) !void {
    if (target_lines.len == 0 or result_list.items.len >= max_results) return;
    result_list.ensureUnusedCapacity(allocator, @min(target_lines.len, max_results - result_list.items.len)) catch {};
    var target_i: usize = 0;
    var line_num: u32 = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        line_num += 1;
        while (target_i < target_lines.len and target_lines[target_i] < line_num) {
            target_i += 1;
        }
        if (target_i >= target_lines.len) return;
        if (target_lines[target_i] != line_num) continue;
        target_i += 1;

        const line_text = try allocator.dupe(u8, line);
        errdefer allocator.free(line_text);
        const path_copy = try allocator.dupe(u8, path);
        errdefer allocator.free(path_copy);
        try result_list.append(allocator, .{
            .path = path_copy,
            .line_num = line_num,
            .line_text = line_text,
        });
        if (result_list.items.len >= max_results) return;
    }
}

fn searchInContent(path: []const u8, content: []const u8, query: []const u8, allocator: std.mem.Allocator, max_per_file: usize, max_results: usize, result_list: *std.ArrayList(SearchResult)) !void {
    if (query.len == 0 or content.len == 0 or max_per_file == 0 or max_results == 0 or result_list.items.len >= max_results) return;
    // Issue #431: bail when the query is longer than the file. Without this
    // guard, `content.len - query.len + 1` below underflows usize → integer
    // overflow panic in Debug, SIGBUS in ReleaseFast.
    if (query.len > content.len) return;
    result_list.ensureTotalCapacity(allocator, result_list.items.len + @min(max_per_file, 16)) catch {};
    var query_lower_buf: [4096]u8 = undefined;
    if (query.len > query_lower_buf.len) return;
    for (query, 0..) |c, i| {
        query_lower_buf[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
    }
    const query_lower = query_lower_buf[0..query.len];
    const first_lower: u8 = query_lower[0];
    const first_upper: u8 = if (first_lower >= 'a' and first_lower <= 'z') first_lower - 32 else first_lower;
    var file_hits: usize = 0;
    var pos: usize = 0;
    const end = content.len - query.len + 1;

    // Track line number incrementally.
    var current_line: u32 = 1;
    var current_line_start: usize = 0;

    // SIMD constants — 16-byte NEON/SSE vectors.
    const VW = 16;
    const Vec = @Vector(VW, u8);
    const splat_lo: Vec = @splat(first_lower);
    const splat_hi: Vec = @splat(first_upper);

    scan: while (pos < end) {
        // ── SIMD path: process full 16-byte chunks ──
        if (pos + VW <= end) {
            const chunk: Vec = content[pos..][0..VW].*;
            const eq_lo: @Vector(VW, u1) = @bitCast(chunk == splat_lo);
            const eq_hi: @Vector(VW, u1) = @bitCast(chunk == splat_hi);
            var mask: u16 = @bitCast(eq_lo | eq_hi);

            if (mask == 0) {
                pos += VW;
                continue;
            }

            // Process ALL first-byte candidates in this chunk without reloading.
            while (mask != 0) {
                const offset: usize = @ctz(mask);
                const cand = pos + offset;
                if (cand >= end) break;

                if (matchAtCaseInsensitive(content, cand, query_lower)) {
                    // ── Match found ──
                    while (current_line_start < cand) {
                        if (simdIndexOfNewline(content, current_line_start)) |nl| {
                            if (nl < cand) {
                                current_line += 1;
                                current_line_start = nl + 1;
                            } else break;
                        } else break;
                    }
                    const line_start = current_line_start;
                    const line_end = simdIndexOfNewline(content, cand) orelse content.len;

                    const line_text = try allocator.dupe(u8, content[line_start..line_end]);
                    errdefer allocator.free(line_text);
                    const path_copy = try allocator.dupe(u8, path);
                    errdefer allocator.free(path_copy);
                    try result_list.append(allocator, .{ .path = path_copy, .line_num = current_line, .line_text = line_text });
                    file_hits += 1;
                    if (file_hits >= max_per_file or result_list.items.len >= max_results) return;

                    current_line += 1;
                    current_line_start = line_end + 1;
                    pos = line_end + 1;
                    if (pos >= end) return;
                    continue :scan;
                }
                mask &= mask - 1; // clear lowest bit, try next candidate in chunk
            }
            pos += VW; // all candidates were false positives
            continue;
        }

        // ── Scalar tail for last <16 bytes ──
        const c = content[pos];
        if ((c == first_lower or c == first_upper) and matchAtCaseInsensitive(content, pos, query_lower)) {
            while (current_line_start < pos) {
                if (simdIndexOfNewline(content, current_line_start)) |nl| {
                    if (nl < pos) {
                        current_line += 1;
                        current_line_start = nl + 1;
                    } else break;
                } else break;
            }
            const line_start = current_line_start;
            const line_end = simdIndexOfNewline(content, pos) orelse content.len;

            const line_text = try allocator.dupe(u8, content[line_start..line_end]);
            errdefer allocator.free(line_text);
            const path_copy = try allocator.dupe(u8, path);
            errdefer allocator.free(path_copy);
            try result_list.append(allocator, .{ .path = path_copy, .line_num = current_line, .line_text = line_text });
            file_hits += 1;
            if (file_hits >= max_per_file or result_list.items.len >= max_results) return;

            current_line += 1;
            current_line_start = line_end + 1;
            pos = line_end + 1;
            continue;
        }
        pos += 1;
    }
}

/// SIMD-accelerated newline search from `start` in `content`.
/// Returns index of first '\n' at or after `start`, or null.
inline fn simdIndexOfNewline(content: []const u8, start: usize) ?usize {
    const VW = 16;
    const Vec = @Vector(VW, u8);
    const splat_nl: Vec = @splat('\n');
    var pos = start;

    while (pos + VW <= content.len) {
        const chunk: Vec = content[pos..][0..VW].*;
        const eq: @Vector(VW, u1) = @bitCast(chunk == splat_nl);
        const mask: u16 = @bitCast(eq);
        if (mask != 0) return pos + @ctz(mask);
        pos += VW;
    }
    while (pos < content.len) {
        if (content[pos] == '\n') return pos;
        pos += 1;
    }
    return null;
}

fn extractLineByNumber(content: []const u8, target_line: u32) ?[]const u8 {
    if (target_line == 0) return null;
    var line_num: u32 = 1;
    var start: usize = 0;
    for (content, 0..) |c, i| {
        if (c == '\n') {
            if (line_num == target_line) return content[start..i];
            line_num += 1;
            start = i + 1;
        }
    }
    if (line_num == target_line and start <= content.len) return content[start..];
    return null;
}

fn matchAtCaseInsensitive(content: []const u8, pos: usize, query_lower: []const u8) bool {
    if (pos + query_lower.len > content.len) return false;
    for (query_lower, 0..) |nc, j| {
        const hc = if (content[pos + j] >= 'A' and content[pos + j] <= 'Z') content[pos + j] + 32 else content[pos + j];
        if (hc != nc) return false;
    }
    return true;
}

fn searchInContentRegex(path: []const u8, content: []const u8, pattern: []const u8, allocator: std.mem.Allocator, max_results: usize, result_list: *std.ArrayList(SearchResult)) !void {
    var rx = nanoregex.Regex.compile(allocator, pattern) catch return;
    defer rx.deinit();
    var line_num: u32 = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        line_num += 1;
        if (rx.search(allocator, line) catch null) |m| {
            @constCast(&m).deinit(allocator);
            const line_text = try allocator.dupe(u8, line);
            errdefer allocator.free(line_text);
            const path_copy = try allocator.dupe(u8, path);
            errdefer allocator.free(path_copy);
            try result_list.append(allocator, .{
                .path = path_copy,
                .line_num = line_num,
                .line_text = line_text,
            });
            if (result_list.items.len >= max_results) return;
        }
    }
}

pub fn regexMatch(haystack: []const u8, pattern: []const u8) bool {
    var rx = nanoregex.Regex.compile(std.heap.smp_allocator, pattern) catch return false;
    defer rx.deinit();
    if (rx.search(std.heap.smp_allocator, haystack) catch null) |m| {
        @constCast(&m).deinit(std.heap.smp_allocator);
        return true;
    }
    return false;
}

fn indexOfCaseInsensitive(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;

    // Pre-compute lowered first byte + second byte for fast skip.
    const first_lower: u8 = if (needle[0] >= 'A' and needle[0] <= 'Z') needle[0] + 32 else needle[0];
    const first_upper: u8 = if (needle[0] >= 'a' and needle[0] <= 'z') needle[0] - 32 else needle[0];
    const end = haystack.len - needle.len + 1;

    if (needle.len == 1) {
        // Single-char: use std.mem.indexOfAny for speed.
        const chars = [2]u8{ first_lower, first_upper };
        return std.mem.indexOfAny(u8, haystack, &chars);
    }

    const second_lower: u8 = if (needle[1] >= 'A' and needle[1] <= 'Z') needle[1] + 32 else needle[1];

    var i: usize = 0;
    while (i < end) : (i += 1) {
        // Fast reject: check first byte, then second byte before full compare.
        const c0 = haystack[i];
        if (c0 != first_lower and c0 != first_upper) continue;
        const c1 = haystack[i + 1];
        const c1_lower = if (c1 >= 'A' and c1 <= 'Z') c1 + 32 else c1;
        if (c1_lower != second_lower) continue;

        // First two bytes match — verify the rest.
        var match = true;
        for (2..needle.len) |j| {
            const hc = if (haystack[i + j] >= 'A' and haystack[i + j] <= 'Z') haystack[i + j] + 32 else haystack[i + j];
            const nc = if (needle[j] >= 'A' and needle[j] <= 'Z') needle[j] + 32 else needle[j];
            if (hc != nc) {
                match = false;
                break;
            }
        }
        if (match) return i;
    }
    return null;
}

/// Count non-overlapping case-insensitive occurrences of `needle` in `text`.
fn countOccurrences(text: []const u8, needle: []const u8) f32 {
    if (needle.len == 0 or needle.len > text.len) return 0;
    var count: f32 = 0;
    var pos: usize = 0;
    while (pos + needle.len <= text.len) {
        if (indexOfCaseInsensitive(text[pos..], needle)) |off| {
            count += 1;
            pos += off + needle.len;
        } else break;
    }
    return count;
}

/// Minimal JSON string escaper for the rerank-trace logger. Writes escaped
/// bytes into `out`, returns bytes written. Stops cleanly when `out` is full.
fn writeJsonEscaped(out: []u8, input: []const u8) usize {
    var w: usize = 0;
    for (input) |c| {
        if (w >= out.len) break;
        switch (c) {
            '"' => {
                if (w + 2 > out.len) break;
                out[w] = '\\';
                out[w + 1] = '"';
                w += 2;
            },
            '\\' => {
                if (w + 2 > out.len) break;
                out[w] = '\\';
                out[w + 1] = '\\';
                w += 2;
            },
            '\n', '\r', '\t' => {
                out[w] = ' ';
                w += 1;
            },
            else => {
                if (c < 0x20) continue;
                out[w] = c;
                w += 1;
            },
        }
    }
    return w;
}

fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

fn asciiContainsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or haystack.len < needle.len) return false;
    var i: usize = 0;
    outer: while (i + needle.len <= haystack.len) : (i += 1) {
        for (needle, 0..) |nc, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(nc)) continue :outer;
        }
        return true;
    }
    return false;
}

fn pathHasSegment(path: []const u8, segment: []const u8) bool {
    var iter = std.mem.tokenizeAny(u8, path, "/\\");
    while (iter.next()) |seg| {
        if (std.mem.eql(u8, seg, segment)) return true;
    }
    return false;
}

fn pathHasSegmentIgnoreCase(path: []const u8, segment: []const u8) bool {
    var iter = std.mem.tokenizeAny(u8, path, "/\\");
    while (iter.next()) |seg| {
        if (asciiEqlIgnoreCase(seg, segment)) return true;
    }
    return false;
}
fn startsWith(haystack: []const u8, needle: []const u8) bool {
    return std.mem.startsWith(u8, haystack, needle);
}

fn appendOutlineSymbol(
    allocator: std.mem.Allocator,
    outline: *FileOutline,
    name: []const u8,
    kind: SymbolKind,
    line_num: u32,
    detail: ?[]const u8,
) !void {
    const name_copy = try allocator.dupe(u8, name);
    errdefer allocator.free(name_copy);
    const detail_copy = if (detail) |d| blk: {
        const copy = try allocator.dupe(u8, d);
        break :blk copy;
    } else null;
    errdefer if (detail_copy) |d| allocator.free(d);
    try outline.symbols.append(allocator, .{
        .name = name_copy,
        .kind = kind,
        .line_start = line_num,
        .line_end = line_num,
        .detail = detail_copy,
    });
}

inline fn resIsIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}
inline fn resIsIdentChar(c: u8) bool {
    return resIsIdentStart(c) or (c >= '0' and c <= '9') or c == '\'';
}
/// Leading ReScript identifier (letter/_/digit/prime), or "" if none.
fn resIdent(s: []const u8) []const u8 {
    if (s.len == 0 or !resIsIdentStart(s[0])) return "";
    var i: usize = 1;
    while (i < s.len and resIsIdentChar(s[i])) i += 1;
    return s[0..i];
}
/// Leading dotted module path (Foo.Bar.Baz), trailing dots trimmed, or "".
fn resModulePath(s: []const u8) []const u8 {
    if (s.len == 0 or !resIsIdentStart(s[0])) return "";
    var i: usize = 1;
    while (i < s.len and (resIsIdentChar(s[i]) or s[i] == '.')) i += 1;
    var end = i;
    while (end > 0 and s[end - 1] == '.') end -= 1;
    return s[0..end];
}
/// Strip leading `@decorator` / `@decorator(args)` tokens (and trailing space) so a
/// decorated `external`/`let` on the same line still parses. Returns the remainder.
fn stripLeadingResDecorators(line: []const u8) []const u8 {
    var s = std.mem.trimStart(u8, line, " \t");
    while (s.len > 0 and s[0] == '@') {
        var i: usize = 1;
        while (i < s.len and (resIsIdentChar(s[i]) or s[i] == '.')) i += 1;
        if (i < s.len and s[i] == '(') {
            var depth: usize = 0;
            while (i < s.len) : (i += 1) {
                if (s[i] == '(') {
                    depth += 1;
                } else if (s[i] == ')') {
                    depth -= 1;
                    if (depth == 0) {
                        i += 1;
                        break;
                    }
                }
            }
        }
        s = std.mem.trimStart(u8, s[i..], " \t");
    }
    return s;
}

fn appendImportSymbol(
    allocator: std.mem.Allocator,
    outline: *FileOutline,
    import_path: []const u8,
    line_num: u32,
    detail: []const u8,
) !void {
    try appendOutlineSymbol(allocator, outline, import_path, .import, line_num, detail);
    try appendImportPath(allocator, outline, import_path);
}

fn appendImportPath(
    allocator: std.mem.Allocator,
    outline: *FileOutline,
    import_path: []const u8,
) !void {
    const import_copy = try allocator.dupe(u8, import_path);
    errdefer allocator.free(import_copy);
    try outline.imports.append(allocator, import_copy);
}

fn extractIdent(s: []const u8) ?[]const u8 {
    const max_ident_len: usize = 256;
    var end: usize = 0;
    for (s) |ch| {
        if (end >= max_ident_len) break;
        // Accept ASCII identifier chars plus any non-ASCII UTF-8 byte (>= 0x80) so
        // identifiers in non-Latin scripts (Korean, Japanese, accented Latin, ...)
        // are captured rather than truncated to empty. See issue #518.
        if (std.ascii.isAlphanumeric(ch) or ch == '_' or ch >= 0x80) {
            end += 1;
        } else break;
    }
    return if (end > 0) s[0..end] else null;
}

fn isIdentChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

fn extractIdentAfterKeyword(line: []const u8, keyword: []const u8) ?[]const u8 {
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, line, start, keyword)) |pos| {
        if (pos > 0 and isIdentChar(line[pos - 1])) {
            start = pos + 1;
            continue;
        }
        return extractIdent(std.mem.trimStart(u8, line[pos + keyword.len ..], " \t"));
    }
    return null;
}

fn extractIdentAfterKeywordIgnoreCase(line: []const u8, keyword: []const u8) ?[]const u8 {
    if (indexOfCaseInsensitive(line, keyword)) |pos| {
        if (pos > 0 and isIdentChar(line[pos - 1])) return null;
        return extractIdent(std.mem.trimStart(u8, line[pos + keyword.len ..], " \t"));
    }
    return null;
}

fn startsWithIgnoreCase(s: []const u8, prefix: []const u8) bool {
    if (s.len < prefix.len) return false;
    for (prefix, 0..) |p, i| {
        if (std.ascii.toLower(s[i]) != std.ascii.toLower(p)) return false;
    }
    return true;
}

fn parseDelimitedImport(line: []const u8, prefix: []const u8, delimiter: []const u8) ?[]const u8 {
    if (!startsWith(line, prefix)) return null;
    var body = std.mem.trim(u8, line[prefix.len..], " \t;");
    if (startsWith(body, "static ")) body = std.mem.trimStart(u8, body["static ".len..], " \t");
    if (delimiter.len > 0) {
        if (std.mem.indexOf(u8, body, delimiter)) |end| body = body[0..end];
    }
    body = std.mem.trim(u8, body, " \t;");
    return if (body.len > 0) body else null;
}

fn extractJvmMethodName(line: []const u8) ?[]const u8 {
    if (startsWith(line, "import ") or startsWith(line, "package ") or startsWith(line, "return ") or
        startsWith(line, "throw ") or startsWith(line, "new "))
        return null;
    if (std.mem.indexOf(u8, line, " class ") != null or std.mem.indexOf(u8, line, " interface ") != null or
        std.mem.indexOf(u8, line, " enum ") != null or std.mem.indexOf(u8, line, " record ") != null)
        return null;
    const open = std.mem.lastIndexOfScalar(u8, line, '(') orelse return null;
    if (std.mem.indexOfScalar(u8, line[open..], ')') == null) return null;
    const before = std.mem.trimEnd(u8, line[0..open], " \t");
    const span = extractLastIdentSpan(before) orelse return null;
    const name = span.text;
    if (isControlKeyword(name)) return null;
    const before_name = std.mem.trim(u8, before[0..span.start], " \t");
    if (before_name.len == 0) return null;
    if (std.mem.endsWith(u8, before_name, ".") or std.mem.endsWith(u8, before_name, "->") or
        std.mem.endsWith(u8, before_name, "="))
        return null;
    return name;
}

fn isControlKeyword(name: []const u8) bool {
    const keywords = [_][]const u8{ "if", "for", "while", "switch", "catch", "return", "throw", "new", "when" };
    for (keywords) |kw| {
        if (std.mem.eql(u8, name, kw)) return true;
    }
    return false;
}

fn firstShellWord(s: []const u8) ?[]const u8 {
    const trimmed = std.mem.trimStart(u8, s, " \t");
    if (trimmed.len == 0) return null;
    var end: usize = 0;
    while (end < trimmed.len and trimmed[end] != ' ' and trimmed[end] != '\t' and trimmed[end] != ';') : (end += 1) {}
    return if (end > 0) trimmed[0..end] else null;
}

fn parseShellAssignment(line: []const u8) ?[]const u8 {
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    if (eq == 0 or std.mem.indexOfAny(u8, line[0..eq], " \t$") != null) return null;
    return extractIdent(line[0..eq]);
}

fn parseCssVariable(line: []const u8) ?[]const u8 {
    if (startsWith(line, "$")) {
        if (std.mem.indexOfScalar(u8, line, ':')) |colon| return line[0..colon];
    }
    if (startsWith(line, "--")) {
        if (std.mem.indexOfScalar(u8, line, ':')) |colon| return line[0..colon];
    }
    return null;
}

fn parseCssSelector(line: []const u8) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, line, '{') == null) return null;
    if (line.len < 2 or (line[0] != '.' and line[0] != '#')) return null;
    var end: usize = 1;
    while (end < line.len) : (end += 1) {
        const ch = line[end];
        if (!(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-')) break;
    }
    return if (end > 1) line[0..end] else null;
}

fn stripSqlLineComment(raw_line: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, raw_line, " \t");
    if (startsWith(trimmed, "--")) return "";
    if (std.mem.indexOf(u8, trimmed, "--")) |pos| return std.mem.trimEnd(u8, trimmed[0..pos], " \t");
    return trimmed;
}

const SqlSymbol = struct {
    name: []const u8,
    kind: SymbolKind,
};

fn parseSqlCreate(line: []const u8) ?SqlSymbol {
    if (!startsWithIgnoreCase(line, "create ")) return null;
    var rest = std.mem.trimStart(u8, line["create ".len..], " \t");
    if (startsWithIgnoreCase(rest, "or replace ")) rest = std.mem.trimStart(u8, rest["or replace ".len..], " \t");
    if (parseSqlCreateKind(rest, "table ", .struct_def)) |sym| return sym;
    if (parseSqlCreateKind(rest, "view ", .struct_def)) |sym| return sym;
    if (parseSqlCreateKind(rest, "index ", .constant)) |sym| return sym;
    if (parseSqlCreateKind(rest, "function ", .function)) |sym| return sym;
    if (parseSqlCreateKind(rest, "procedure ", .function)) |sym| return sym;
    if (parseSqlCreateKind(rest, "trigger ", .method)) |sym| return sym;
    if (parseSqlCreateKind(rest, "type ", .type_alias)) |sym| return sym;
    return null;
}

fn parseSqlCreateKind(rest: []const u8, keyword: []const u8, kind: SymbolKind) ?SqlSymbol {
    if (!startsWithIgnoreCase(rest, keyword)) return null;
    var body = std.mem.trimStart(u8, rest[keyword.len..], " \t");
    if (startsWithIgnoreCase(body, "if not exists ")) body = std.mem.trimStart(u8, body["if not exists ".len..], " \t");
    const name = firstSqlIdent(body) orelse return null;
    return .{ .name = name, .kind = kind };
}

fn firstSqlIdent(s: []const u8) ?[]const u8 {
    const trimmed = std.mem.trimStart(u8, s, " \t\"`[");
    if (trimmed.len == 0) return null;
    var end: usize = 0;
    while (end < trimmed.len and trimmed[end] != ' ' and trimmed[end] != '\t' and
        trimmed[end] != '(' and trimmed[end] != ';' and trimmed[end] != '"' and
        trimmed[end] != '`' and trimmed[end] != ']') : (end += 1)
    {}
    if (end == 0) return null;
    const raw = trimmed[0..end];
    if (std.mem.lastIndexOfScalar(u8, raw, '.')) |dot| {
        if (dot + 1 < raw.len) return raw[dot + 1 ..];
    }
    return raw;
}

fn stripFortranComment(raw_line: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, raw_line, " \t");
    if (startsWith(trimmed, "!")) return "";
    if (std.mem.indexOfScalar(u8, trimmed, '!')) |pos| return std.mem.trimEnd(u8, trimmed[0..pos], " \t");
    return trimmed;
}

fn parseFortranUse(line: []const u8) ?[]const u8 {
    if (!startsWithIgnoreCase(line, "use ")) return null;
    var rest = std.mem.trimStart(u8, line[4..], " \t");
    if (startsWithIgnoreCase(rest, "intrinsic")) return null;
    if (std.mem.indexOf(u8, rest, "::")) |pos| rest = std.mem.trimStart(u8, rest[pos + 2 ..], " \t");
    return extractIdent(rest);
}

fn parseFortranTypeName(line: []const u8) ?[]const u8 {
    if (!startsWithIgnoreCase(line, "type")) return null;
    const sep = std.mem.indexOf(u8, line, "::") orelse return null;
    return extractIdent(std.mem.trimStart(u8, line[sep + 2 ..], " \t"));
}

fn extractAtName(line: []const u8) ?[]const u8 {
    const at = std.mem.indexOfScalar(u8, line, '@') orelse return null;
    return extractLlvmLikeName(line[at + 1 ..]);
}

fn extractLlvmGlobalName(line: []const u8) ?[]const u8 {
    if (line.len == 0 or (line[0] != '@' and line[0] != '%')) return null;
    return extractLlvmLikeName(line[1..]);
}

fn extractLlvmLikeName(s: []const u8) ?[]const u8 {
    if (s.len == 0) return null;
    if (s[0] == '"') {
        if (std.mem.indexOfScalar(u8, s[1..], '"')) |end| return s[1 .. end + 1];
        return null;
    }
    var end: usize = 0;
    while (end < s.len) : (end += 1) {
        const ch = s[end];
        if (!(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-' or ch == '.' or ch == '$')) break;
    }
    return if (end > 0) s[0..end] else null;
}

const IdentSpan = struct {
    text: []const u8,
    start: usize,
    end: usize,
};

fn extractLastIdentSpan(s: []const u8) ?IdentSpan {
    if (s.len == 0) return null;

    var end = s.len;
    while (end > 0) {
        const ch = s[end - 1];
        if (std.ascii.isAlphanumeric(ch) or ch == '_') break;
        end -= 1;
    }
    if (end == 0) return null;

    var start = end;
    while (start > 0) {
        const ch = s[start - 1];
        if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) break;
        start -= 1;
    }
    return .{ .text = s[start..end], .start = start, .end = end };
}

fn extractLastIdent(s: []const u8) ?[]const u8 {
    return if (extractLastIdentSpan(s)) |span| span.text else null;
}

fn stripLineComment(raw_line: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, raw_line, " \t");
    if (startsWith(trimmed, "//")) return "";
    if (std.mem.indexOf(u8, trimmed, "//")) |pos| {
        return std.mem.trimEnd(u8, trimmed[0..pos], " \t");
    }
    return trimmed;
}

fn extractCIncludePath(line: []const u8) ?[]const u8 {
    const keyword = if (startsWith(line, "#include"))
        "#include"
    else if (startsWith(line, "#import"))
        "#import"
    else
        return null;
    const rest = std.mem.trimStart(u8, line[keyword.len..], " \t");
    if (rest.len >= 2 and rest[0] == '<') {
        if (std.mem.indexOfScalar(u8, rest[1..], '>')) |end| {
            if (end == 0) return null;
            return rest[1 .. end + 1];
        }
    }
    return extractStringLiteral(rest);
}

const CTypeSymbol = struct {
    name: []const u8,
    kind: SymbolKind,
};

fn parseCNamedType(line: []const u8) ?CTypeSymbol {
    const stripped = stripCAttributesPrefix(line);
    if (startsWith(stripped, "typedef ")) {
        const rest = std.mem.trimStart(u8, stripped["typedef ".len..], " \t");
        if (parseCBraceType(rest)) |sym| return sym;
        if (std.mem.indexOf(u8, rest, "(*") != null) return null;
        if (std.mem.indexOfScalar(u8, rest, ';')) |semi| {
            const before_semi = rest[0..semi];
            if (extractLastIdent(before_semi)) |name| {
                if (!isCKeyword(name)) return .{ .name = name, .kind = .type_alias };
            }
        }
        return null;
    }
    return parseCBraceType(stripped);
}

fn parseCBraceType(line: []const u8) ?CTypeSymbol {
    if (std.mem.indexOfScalar(u8, line, '{') == null) return null;
    if (startsWith(line, "class ")) {
        return parseCTypeAfterKeyword(line["class ".len..], .class_def);
    }
    if (startsWith(line, "struct ")) {
        return parseCTypeAfterKeyword(line["struct ".len..], .struct_def);
    }
    if (startsWith(line, "enum ")) {
        return parseCTypeAfterKeyword(line["enum ".len..], .enum_def);
    }
    if (startsWith(line, "union ")) {
        return parseCTypeAfterKeyword(line["union ".len..], .union_def);
    }
    return null;
}

fn parseCTypeAfterKeyword(rest: []const u8, kind: SymbolKind) ?CTypeSymbol {
    const trimmed = std.mem.trimStart(u8, rest, " \t");
    if (trimmed.len == 0 or trimmed[0] == '{') return null;
    if (extractIdent(trimmed)) |name| {
        if (!isCKeyword(name)) return .{ .name = name, .kind = kind };
    }
    return null;
}

fn parseObjCType(line: []const u8) ?CTypeSymbol {
    if (startsWith(line, "@interface ")) {
        return parseCTypeAfterKeyword(line["@interface ".len..], .class_def);
    }
    if (startsWith(line, "@implementation ")) {
        return parseCTypeAfterKeyword(line["@implementation ".len..], .class_def);
    }
    if (startsWith(line, "@protocol ")) {
        return parseCTypeAfterKeyword(line["@protocol ".len..], .interface_def);
    }
    return null;
}

fn extractObjCMethodName(line: []const u8) ?[]const u8 {
    if (!startsWith(line, "- (") and !startsWith(line, "+ (")) return null;
    const close = std.mem.indexOfScalar(u8, line, ')') orelse return null;
    const rest = std.mem.trimStart(u8, line[close + 1 ..], " \t*");
    return extractIdent(rest);
}

fn extractCFunctionName(line: []const u8, at_col0: bool, prev_trimmed: []const u8, brace_depth: u32, is_cpp: bool) ?[]const u8 {
    // Anything inside a function body is a call site, not a definition.
    // C: depth 0 = file scope. Any depth >= 1 means inside a function body.
    // C++: depth 0 = file scope, depth 1 = class/struct body (methods allowed).
    //      Depth >= 2 means inside a function body.
    const max_depth: u32 = if (is_cpp) 1 else 0;
    if (brace_depth > max_depth) return null;

    const stripped = stripCAttributesPrefix(line);
    if (stripped.len == 0 or stripped[0] == '#') return null;
    if (startsWith(stripped, "typedef ")) return null;
    if (std.mem.indexOfScalar(u8, stripped, ';') != null) return null;

    const search_end = std.mem.indexOfScalar(u8, stripped, '{') orelse stripped.len;
    if (search_end == 0) return null;
    const signature = std.mem.trimEnd(u8, stripped[0..search_end], " \t");
    const open_paren = std.mem.lastIndexOfScalar(u8, signature, '(') orelse return null;
    if (std.mem.indexOfScalar(u8, signature[open_paren..], ')') == null) return null;
    if (std.mem.indexOf(u8, signature, "(*") != null) return null;

    const before_paren = std.mem.trimEnd(u8, signature[0..open_paren], " \t");
    const span = extractLastIdentSpan(before_paren) orelse return null;
    const name = span.text;
    if (isCKeyword(name)) return null;

    const before_name = std.mem.trim(u8, before_paren[0..span.start], " \t*(&");
    if (before_name.len == 0) {
        // nginx-style: return type on previous line, function name starts this line.
        // Accept only if at column 0 and prev line looks like a type (identifier,
        // optionally preceded by storage qualifiers), not a statement or brace.
        if (!at_col0) return null;
        if (prev_trimmed.len == 0) return null;
        if (prev_trimmed[0] == '{' or prev_trimmed[0] == '}' or
            prev_trimmed[0] == '(' or prev_trimmed[0] == ')')
            return null;
        if (std.mem.indexOfScalar(u8, prev_trimmed, ';') != null) return null;
        if (std.mem.indexOfScalar(u8, prev_trimmed, '(') != null) return null;
        if (isCForbiddenFunctionPrefix(prev_trimmed)) return null;
        // prev line must start with an identifier (a type name or qualifier)
        if (extractIdent(std.mem.trimStart(u8, prev_trimmed, " \t*")) == null) return null;
        return name;
    }
    if (!at_col0 and !looksLikeCMethodDef(before_name)) return null;
    if (hasCAssignmentBeforeName(before_name)) return null;
    if (isCForbiddenFunctionPrefix(before_name)) return null;
    if (std.mem.endsWith(u8, before_name, ".") or std.mem.endsWith(u8, before_name, "->")) return null;

    return name;
}

fn countChar(s: []const u8, ch: u8) u32 {
    var n: u32 = 0;
    for (s) |c| if (c == ch) {
        n += 1;
    };
    return n;
}

fn applyBraceDelta(depth: *u32, delta: i32) void {
    if (delta >= 0) {
        depth.* +|= @intCast(delta);
    } else {
        const sub: u32 = @intCast(-delta);
        depth.* -|= sub;
    }
}

fn countBracesDelta(line: []const u8) i32 {
    var delta: i32 = 0;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const ch = line[i];
        if (ch == '"' or ch == '\'') {
            const q = ch;
            i += 1;
            while (i < line.len) : (i += 1) {
                if (line[i] == '\\') {
                    i += 1;
                    continue;
                }
                if (line[i] == q) break;
            }
        } else if (ch == '{') {
            delta += 1;
        } else if (ch == '}') {
            delta -= 1;
        }
    }
    return delta;
}

fn looksLikeCMethodDef(before_name: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, before_name, " \t*(&");
    const first = extractIdent(trimmed) orelse return false;
    return !isCKeyword(first) and !std.mem.eql(u8, first, "return") and
        !std.mem.eql(u8, first, "case");
}

fn stripCAttributesPrefix(line: []const u8) []const u8 {
    var rest = std.mem.trimStart(u8, line, " \t");
    while (startsWith(rest, "__attribute__((")) {
        if (std.mem.indexOf(u8, rest, "))")) |end| {
            rest = std.mem.trimStart(u8, rest[end + 2 ..], " \t");
        } else break;
    }
    return rest;
}

fn hasCAssignmentBeforeName(prefix: []const u8) bool {
    for (prefix, 0..) |ch, i| {
        if (ch != '=') continue;
        const prev = if (i > 0) prefix[i - 1] else 0;
        const next = if (i + 1 < prefix.len) prefix[i + 1] else 0;
        if (prev == '=' or prev == '!' or prev == '<' or prev == '>' or next == '=') continue;
        return true;
    }
    return false;
}

fn isCForbiddenFunctionPrefix(prefix: []const u8) bool {
    const first = extractIdent(std.mem.trimStart(u8, prefix, " \t*(&")) orelse return false;
    return std.mem.eql(u8, first, "return") or
        std.mem.eql(u8, first, "case") or
        std.mem.eql(u8, first, "sizeof") or
        std.mem.eql(u8, first, "if") or
        std.mem.eql(u8, first, "for") or
        std.mem.eql(u8, first, "while") or
        std.mem.eql(u8, first, "switch");
}

fn isCKeyword(s: []const u8) bool {
    const keywords = [_][]const u8{
        "if",       "for",      "while",  "switch", "return",   "sizeof",
        "case",     "do",       "else",   "struct", "enum",     "union",
        "typedef",  "static",   "extern", "inline", "const",    "volatile",
        "register", "restrict", "auto",   "break",  "continue",
    };
    for (keywords) |kw| {
        if (std.mem.eql(u8, s, kw)) return true;
    }
    return false;
}

fn firstIndexOfAny(s: []const u8, chars: []const u8) ?usize {
    for (s, 0..) |ch, pos| {
        for (chars) |needle| {
            if (ch == needle) return pos;
        }
    }
    return null;
}

/// Extract a Ruby method name — supports trailing ?, !, = characters
fn extractRubyMethodName(s: []const u8) ?[]const u8 {
    const max_len: usize = 256;
    var end: usize = 0;
    for (s) |ch| {
        if (end >= max_len) break;
        // Accept ASCII identifier chars plus any non-ASCII UTF-8 byte (>= 0x80) so
        // identifiers in non-Latin scripts (Korean, Japanese, accented Latin, ...)
        // are captured rather than truncated to empty. See issue #518.
        if (std.ascii.isAlphanumeric(ch) or ch == '_' or ch >= 0x80) {
            end += 1;
        } else break;
    }
    if (end > 0 and end < s.len) {
        const suffix = s[end];
        if (suffix == '?' or suffix == '!' or suffix == '=') end += 1;
    }
    return if (end > 0) s[0..end] else null;
}

fn extractHclQuotedName(text: []const u8) ?[]const u8 {
    const trimmed = std.mem.trimStart(u8, text, " \t");
    if (trimmed.len < 2 or trimmed[0] != '"') return null;
    if (std.mem.indexOfScalar(u8, trimmed[1..], '"')) |end| {
        if (end == 0) return null;
        return trimmed[1 .. end + 1];
    }
    return null;
}

fn extractHclBlockName(text: []const u8) ?[]const u8 {
    const trimmed = std.mem.trimStart(u8, text, " \t");
    if (trimmed.len < 2 or trimmed[0] != '"') return null;
    // Skip first quoted string
    if (std.mem.indexOfScalar(u8, trimmed[1..], '"')) |end1| {
        const after_first = trimmed[end1 + 2 ..];
        const rest = std.mem.trimStart(u8, after_first, " \t");
        // Extract second quoted string (the name)
        if (rest.len >= 2 and rest[0] == '"') {
            if (std.mem.indexOfScalar(u8, rest[1..], '"')) |end2| {
                if (end2 == 0) return null;
                return rest[1 .. end2 + 1];
            }
        }
    }
    return null;
}

fn extractStringLiteral(s: []const u8) ?[]const u8 {
    const quote_chars = [_]u8{ '"', '\'' };
    for (quote_chars) |q| {
        if (std.mem.indexOfScalar(u8, s, q)) |start_pos| {
            if (std.mem.indexOfScalarPos(u8, s, start_pos + 1, q)) |end_pos| {
                return s[start_pos + 1 .. end_pos];
            }
        }
    }
    return null;
}

fn normalizePath(path: []const u8, allocator: std.mem.Allocator) ?[]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    errdefer parts.deinit(allocator);

    var it = std.mem.splitSequence(u8, path, "/");
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (parts.items.len > 0) {
                _ = parts.pop();
            } else {
                return null;
            }
        } else {
            parts.append(allocator, part) catch return null;
        }
    }

    if (parts.items.len == 0) return null;

    var buf: std.ArrayList(u8) = .empty;
    for (parts.items, 0..) |part, i| {
        if (i > 0) buf.append(allocator, '/') catch return null;
        buf.appendSlice(allocator, part) catch return null;
    }
    return buf.toOwnedSlice(allocator) catch null;
}

fn resolveDartImport(raw: []const u8, file_path: []const u8, allocator: std.mem.Allocator) ?[]const u8 {
    if (std.mem.startsWith(u8, raw, "dart:")) return null;

    if (std.mem.startsWith(u8, raw, "package:")) {
        return allocator.dupe(u8, raw) catch null;
    }

    const dir = if (std.mem.lastIndexOfScalar(u8, file_path, '/')) |sep|
        file_path[0..sep]
    else
        ".";
    const joined = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, raw }) catch return null;
    const result = normalizePath(joined, allocator);
    allocator.free(joined);
    return result;
}

fn containsAny(s: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (std.mem.indexOf(u8, s, needle) != null) return true;
    }
    return false;
}

fn skipKeywords(s: []const u8) []const u8 {
    const keywords = [_][]const u8{ "export ", "default ", "async ", "abstract ", "function ", "class ", "interface ", "enum ", "type ", "const ", "let ", "var " };
    var result = s;
    for (keywords) |kw| {
        if (std.mem.startsWith(u8, result, kw)) {
            result = result[kw.len..];
        }
    }
    return result;
}

/// Extract the module path from a Python import line.
/// "from mypackage.utils.helpers import X" → "mypackage.utils.helpers"
/// "import os.path" → "os.path"
/// "from . import foo" / "from .rel import bar" → null (relative imports too ambiguous)
fn extractPythonModulePath(line: []const u8) ?[]const u8 {
    if (startsWith(line, "from ")) {
        const rest = std.mem.trimStart(u8, line[5..], " \t");
        // Skip relative imports (start with dot)
        if (rest.len > 0 and rest[0] == '.') return null;
        // "from module.path import ..." — extract up to " import"
        if (std.mem.indexOf(u8, rest, " import")) |imp_pos| {
            const mod = std.mem.trimEnd(u8, rest[0..imp_pos], " \t");
            if (mod.len > 0) return mod;
        }
        return null;
    } else if (startsWith(line, "import ")) {
        const rest = std.mem.trimStart(u8, line[7..], " \t");
        // "import os.path" or "import foo" — take up to comma or space
        var end: usize = 0;
        while (end < rest.len and rest[end] != ' ' and rest[end] != ',' and rest[end] != '\t') : (end += 1) {}
        if (end > 0) return rest[0..end];
        return null;
    }
    return null;
}

// ── Fuzzy file matching ─────────────────────────────────────────

fn toLowerByte(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

fn isWordBoundary(path: []const u8, pi: usize) bool {
    if (pi == 0) return true;
    const prev = path[pi - 1];
    return prev == '/' or prev == '_' or prev == '-' or prev == '.' or prev == '\\';
}

fn isSpecialEntryPoint(filename: []const u8) bool {
    const specials = [_][]const u8{
        "main.zig",     "lib.zig",     "root.zig",
        "main.rs",      "lib.rs",      "mod.rs",
        "main.go",      "main.c",      "main.cpp",
        "index.ts",     "index.tsx",   "index.js",
        "index.jsx",    "index.mjs",   "index.cjs",
        "index.vue",    "index.php",   "main.rb",
        "index.rb",     "__init__.py", "__main__.py",
        "Makefile",     "build.zig",   "Cargo.toml",
        "package.json",
    };
    for (specials) |s| {
        if (std.mem.eql(u8, filename, s)) return true;
    }
    return false;
}

fn getFilename(path: []const u8) []const u8 {
    var i: usize = path.len;
    while (i > 0) : (i -= 1) {
        if (path[i - 1] == '/') return path[i..];
    }
    return path;
}

// Length of the longest common subsequence of two strings, case-insensitive.
// Used as a fuzzy-match floor: how many of the query's characters actually align,
// in order, somewhere in the path. See issue #518.
fn lcsLenIgnoreCase(query: []const u8, path: []const u8) usize {
    const MAXB = 512;
    var row: [MAXB + 1]usize = undefined;
    const pn = @min(path.len, MAXB);
    for (0..pn + 1) |j| row[j] = 0;
    for (query) |qc| {
        const lq = toLowerByte(qc);
        var prev_diag: usize = 0;
        for (0..pn) |j| {
            const tmp = row[j + 1];
            if (lq == toLowerByte(path[j])) {
                row[j + 1] = prev_diag + 1;
            } else if (row[j] > row[j + 1]) {
                row[j + 1] = row[j];
            }
            prev_diag = tmp;
        }
    }
    return row[pn];
}

// Score `path` against every space-separated query part (all must match, scores
// sum) — the exhaustive per-file scoring shared by both fuzzyFindFiles passes.
fn scoreAllParts(parts: []const []const u8, path: []const u8) ?f32 {
    var total: f32 = 0;
    for (parts) |part| {
        if (fuzzyScore(part, path)) |s| {
            total += s;
        } else return null;
    }
    if (total > 0) return total;
    return null;
}
// Fuzzy file-scoring constants, shared by the scalar (fuzzyScore/fuzzyDP) and the
// SIMD-across-files (fuzzyScoreBatch) scorers so both stay bit-identical.
const FUZZY_MAX_QUERY = 128;
const FUZZY_MAX_PATH = 512;
const FZ_MATCH: f32 = 16.0;
const FZ_MISMATCH: f32 = -8.0;
const FZ_GAP_OPEN: f32 = -3.0;
const FZ_GAP_EXTEND: f32 = -1.0;
const FZ_DELIM: f32 = 8.0;
const FZ_FILENAME: f32 = 6.0;
const FZ_CONSEC: f32 = 4.0;
const FZ_CASE: f32 = 2.0;
const FZ_PREFIX: f32 = 6.0;

const FuzzyDPResult = struct { best_score: f32, matched_chars: usize };

fn fuzzyFilenameStart(path: []const u8) usize {
    var fname_start: usize = 0;
    for (0..path.len) |i| {
        if (path[path.len - 1 - i] == '/') {
            fname_start = path.len - i;
            break;
        }
    }
    return fname_start;
}

// Presence pre-filter shared by the scalar + batch scorers. The score floor below
// (issue #518) makes a >=60% in-order LCS a hard requirement; unordered character
// presence is an upper bound on that LCS, so a path missing >40% of the query's
// chars can be rejected in O(path) without the DP — and would fail the LCS check
// anyway, so no result changes.
pub fn fuzzyPresenceReject(query: []const u8, path: []const u8) bool {
    var present = [_]bool{false} ** 256;
    for (path) |c| present[toLowerByte(c)] = true;
    var hits: usize = 0;
    for (query) |c| {
        if (present[toLowerByte(c)]) hits += 1;
    }
    return hits * 5 < query.len * 3;
}

// Smith-Waterman-style DP with affine gaps for one (query, path). Returns the raw
// best_score + matched_chars; the floor/LCS/bonus tail lives in fuzzyFinalize so
// the scalar and SIMD paths share identical post-processing. Two rows swapped by
// pointer; per-cell inputs that don't vary with j (lowercased query char, path
// lowercase + word-boundary flags) are hoisted/precomputed.
fn fuzzyDP(query: []const u8, path: []const u8) FuzzyDPResult {
    const fname_start = fuzzyFilenameStart(path);

    var ql_buf: [FUZZY_MAX_QUERY]u8 = undefined;
    var pl_buf: [FUZZY_MAX_PATH]u8 = undefined;
    var wb_buf: [FUZZY_MAX_PATH]bool = undefined;
    const ql = ql_buf[0..query.len];
    const pl = pl_buf[0..path.len];
    const wb = wb_buf[0..path.len];
    for (query, 0..) |c, k| ql[k] = toLowerByte(c);
    for (path, 0..) |c, k| {
        pl[k] = toLowerByte(c);
        wb[k] = isWordBoundary(path, k);
    }

    var h_a: [FUZZY_MAX_PATH + 1]f32 = undefined;
    var h_b: [FUZZY_MAX_PATH + 1]f32 = undefined;
    var g_a: [FUZZY_MAX_PATH + 1]f32 = undefined;
    var g_b: [FUZZY_MAX_PATH + 1]f32 = undefined;
    var prev_h: []f32 = h_a[0 .. path.len + 1];
    var curr_h: []f32 = h_b[0 .. path.len + 1];
    var prev_gap: []f32 = g_a[0 .. path.len + 1];
    var curr_gap: []f32 = g_b[0 .. path.len + 1];
    for (0..path.len + 1) |j| {
        prev_h[j] = 0;
        prev_gap[j] = FZ_GAP_OPEN;
    }

    var best_score: f32 = 0;
    var matched_chars: usize = 0;
    const last_i = query.len - 1;

    for (0..query.len) |i| {
        const qc = ql[i];
        const qchar = query[i];
        curr_h[0] = 0;
        curr_gap[0] = FZ_GAP_OPEN;
        var query_gap: f32 = FZ_GAP_OPEN;
        var row_positive = false;

        for (0..path.len) |j| {
            const is_match = qc == pl[j];
            var match_score: f32 = if (is_match) FZ_MATCH else FZ_MISMATCH;
            if (is_match) {
                if (qchar == path[j]) match_score += FZ_CASE;
                if (wb[j]) match_score += FZ_DELIM;
                if (j >= fname_start) match_score += FZ_FILENAME;
                if (j == 0 or j == fname_start) match_score += FZ_PREFIX;
                if (i > 0 and j > 0 and prev_h[j] > prev_h[j + 1] * 0.5) {
                    match_score += FZ_CONSEC;
                }
            }
            const diag = prev_h[j] + match_score;
            curr_gap[j + 1] = @max(prev_h[j + 1] + FZ_GAP_OPEN, prev_gap[j + 1] + FZ_GAP_EXTEND);
            query_gap = @max(curr_h[j] + FZ_GAP_OPEN, query_gap + FZ_GAP_EXTEND);
            const v: f32 = @max(0, @max(diag, @max(curr_gap[j + 1], query_gap)));
            curr_h[j + 1] = v;
            if (v > 0) row_positive = true;
            if (i == last_i and v > best_score) best_score = v;
        }

        if (row_positive) matched_chars = i + 1;
        std.mem.swap([]f32, &prev_h, &curr_h);
        std.mem.swap([]f32, &prev_gap, &curr_gap);
    }

    return .{ .best_score = best_score, .matched_chars = matched_chars };
}

// Floor + issue-#518 LCS gate + special bonuses + length normalization, shared by
// the scalar and SIMD scorers. Returns null if the path doesn't qualify.
pub fn fuzzyFinalize(query: []const u8, path: []const u8, best_in: f32, matched_chars: usize) ?f32 {
    var best_score = best_in;
    // Require at least 60% of query chars to contribute to score
    if (best_score <= 0 or matched_chars < (query.len + 1) / 2) return null;
    // Minimum score threshold based on query length
    const min_threshold = @as(f32, @floatFromInt(query.len)) * FZ_MATCH * 0.3;
    if (best_score < min_threshold) return null;
    // Issue #518: require a real >=60% in-order subsequence, not stray local hits.
    if (lcsLenIgnoreCase(query, path) * 5 < query.len * 3) return null;
    // Special entry point bonus (like fff: main.go, index.ts, lib.rs rank higher)
    const fname = getFilename(path);
    if (isSpecialEntryPoint(fname)) best_score += best_score * 0.05;
    // Issue #363b: an exact basename match must rank above fuzzy matches.
    if (std.ascii.eqlIgnoreCase(query, fname)) best_score *= 4.0;
    // Normalize by path length (shorter paths rank higher)
    return best_score / @sqrt(@as(f32, @floatFromInt(path.len)));
}

pub fn fuzzyScore(query: []const u8, path: []const u8) ?f32 {
    if (query.len == 0 or path.len == 0) return null;
    if (query.len > FUZZY_MAX_QUERY or path.len > FUZZY_MAX_PATH) return null;
    if (fuzzyPresenceReject(query, path)) return null;
    const dp = fuzzyDP(query, path);
    return fuzzyFinalize(query, path, dp.best_score, dp.matched_chars);
}

// Number of files scored per SIMD batch (each lane = a different path, same
// query). 8 f32 lanes map to 2 NEON / 1 AVX2 register and give the inner DP loop
// enough independent work to hide the per-column dependency latency.
const FZ_LANES = 8;

// SIMD-across-files Smith-Waterman: scores up to FZ_LANES paths against `query` in
// lockstep, one path per vector lane. Produces bit-identical best_score +
// matched_chars to fuzzyDP for every lane (same f32 arithmetic per lane, just
// vectorized), so the caller's fuzzyFinalize yields identical results. paths.len
// must be in 1..=FZ_LANES; every path 1..=FUZZY_MAX_PATH; query 1..=FUZZY_MAX_QUERY.
// Lanes >= paths.len are inert. Shorter paths are masked per column so their
// padding columns never affect best_score/matched_chars.
pub fn fuzzyScoreBatch(query: []const u8, paths: []const []const u8, out_best: *[FZ_LANES]f32, out_matched: *[FZ_LANES]u32) void {
    const V = @Vector(FZ_LANES, f32);
    const U8V = @Vector(FZ_LANES, u8);
    const U32V = @Vector(FZ_LANES, u32);
    const BoolV = @Vector(FZ_LANES, bool);

    const count = paths.len;
    var lens: [FZ_LANES]usize = .{0} ** FZ_LANES;
    var len_arr: [FZ_LANES]u32 = .{0} ** FZ_LANES;
    var fname_arr: [FZ_LANES]u32 = .{0} ** FZ_LANES;
    var max_len: usize = 0;
    for (0..count) |l| {
        lens[l] = paths[l].len;
        len_arr[l] = @intCast(paths[l].len);
        fname_arr[l] = @intCast(fuzzyFilenameStart(paths[l]));
        if (paths[l].len > max_len) max_len = paths[l].len;
    }
    const len_v: U32V = len_arr;
    const fname_v: U32V = fname_arr;

    // Column-major transpose of the batch's paths (lowercased + original + word-
    // boundary flag per lane). Padding lanes/columns hold 0 / false (never match).
    var pl_t: [FUZZY_MAX_PATH]U8V = undefined;
    var po_t: [FUZZY_MAX_PATH]U8V = undefined;
    var wb_t: [FUZZY_MAX_PATH]BoolV = undefined;
    for (0..max_len) |j| {
        var lo: [FZ_LANES]u8 = .{0} ** FZ_LANES;
        var orig: [FZ_LANES]u8 = .{0} ** FZ_LANES;
        var wbf: [FZ_LANES]bool = .{false} ** FZ_LANES;
        for (0..count) |l| {
            if (j < lens[l]) {
                const c = paths[l][j];
                lo[l] = toLowerByte(c);
                orig[l] = c;
                wbf[l] = isWordBoundary(paths[l], j);
            }
        }
        pl_t[j] = lo;
        po_t[j] = orig;
        wb_t[j] = wbf;
    }

    const zero: V = @splat(0);
    const gap_open_v: V = @splat(FZ_GAP_OPEN);
    const gap_ext_v: V = @splat(FZ_GAP_EXTEND);
    const match_v: V = @splat(FZ_MATCH);
    const mismatch_v: V = @splat(FZ_MISMATCH);
    const case_v: V = @splat(FZ_CASE);
    const delim_v: V = @splat(FZ_DELIM);
    const filename_v: V = @splat(FZ_FILENAME);
    const prefix_v: V = @splat(FZ_PREFIX);
    const consec_v: V = @splat(FZ_CONSEC);
    const half_v: V = @splat(0.5);

    var h_a: [FUZZY_MAX_PATH + 1]V = undefined;
    var h_b: [FUZZY_MAX_PATH + 1]V = undefined;
    var g_a: [FUZZY_MAX_PATH + 1]V = undefined;
    var g_b: [FUZZY_MAX_PATH + 1]V = undefined;
    var prev_h: []V = h_a[0 .. max_len + 1];
    var curr_h: []V = h_b[0 .. max_len + 1];
    var prev_gap: []V = g_a[0 .. max_len + 1];
    var curr_gap: []V = g_b[0 .. max_len + 1];
    for (0..max_len + 1) |j| {
        prev_h[j] = zero;
        prev_gap[j] = gap_open_v;
    }

    var best_v: V = zero;
    var matched_v: U32V = @splat(0);
    const last_i = query.len - 1;

    for (0..query.len) |i| {
        const qc_v: U8V = @splat(toLowerByte(query[i]));
        const qo_v: U8V = @splat(query[i]);
        curr_h[0] = zero;
        curr_gap[0] = gap_open_v;
        var query_gap: V = gap_open_v;
        var row_pos_v: V = zero;
        const is_last = i == last_i;
        const consec_row = i > 0;
        const iplus1_v: U32V = @splat(@as(u32, @intCast(i + 1)));

        for (0..max_len) |j| {
            const jv: U32V = @splat(@as(u32, @intCast(j)));
            const match_mask: BoolV = pl_t[j] == qc_v;

            // Bonuses (gated to match lanes by the final select below).
            var bonus: V = @select(f32, po_t[j] == qo_v, case_v, zero);
            bonus += @select(f32, wb_t[j], delim_v, zero);
            bonus += @select(f32, jv >= fname_v, filename_v, zero);
            const at_prefix: BoolV = if (j == 0) @splat(true) else (jv == fname_v);
            bonus += @select(f32, at_prefix, prefix_v, zero);
            if (consec_row and j > 0) {
                const cons: BoolV = prev_h[j] > prev_h[j + 1] * half_v;
                bonus += @select(f32, cons, consec_v, zero);
            }
            const ms: V = @select(f32, match_mask, match_v + bonus, mismatch_v);

            const diag = prev_h[j] + ms;
            curr_gap[j + 1] = @max(prev_h[j + 1] + gap_open_v, prev_gap[j + 1] + gap_ext_v);
            query_gap = @max(curr_h[j] + gap_open_v, query_gap + gap_ext_v);
            const v: V = @max(zero, @max(diag, @max(curr_gap[j + 1], query_gap)));
            curr_h[j + 1] = v;

            const valid: BoolV = jv < len_v; // lane has a real char at column j
            row_pos_v = @max(row_pos_v, @select(f32, valid, v, zero));
            if (is_last) best_v = @select(f32, valid, @max(best_v, v), best_v);
        }

        const row_has: BoolV = row_pos_v > zero;
        matched_v = @select(u32, row_has, iplus1_v, matched_v);
        std.mem.swap([]V, &prev_h, &curr_h);
        std.mem.swap([]V, &prev_gap, &curr_gap);
    }

    out_best.* = best_v;
    out_matched.* = matched_v;
}
