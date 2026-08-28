const std = @import("std");
const builtin = @import("builtin");
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
const markdown_graph = @import("markdown_graph.zig");
const git = @import("git.zig");
const project_file = @import("project_file.zig");
const root_policy = @import("root_policy.zig");

pub const DocumentLinkKind = markdown_graph.LinkKind;
pub const DocumentLink = markdown_graph.Link;
pub const MAX_DOCUMENT_LINKS_PER_FILE = markdown_graph.MAX_LINKS_PER_FILE;
pub const isSafeDocumentTarget = markdown_graph.isSafeNormalizedTarget;

const SearchGeneration = if (builtin.cpu.arch == .wasm32) u32 else u64;

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

/// Query-independent path-prior flags shared by the rerankers — a pure
/// function of the path, see classifyPath.
pub const PathClass = struct {
    is_tooling: bool = false,
    is_test: bool = false,
    is_example: bool = false,
    is_vendor: bool = false,
};

/// Classify `path` for the rerank path priors. Pure — the result is cached
/// on FileOutline at init; callers without an outline compute it directly.
pub fn classifyPath(path: []const u8) PathClass {
    var c: PathClass = .{};
    // One tokenize pass over the path instead of one per segment keyword.
    var iter = std.mem.tokenizeAny(u8, path, "/\\");
    while (iter.next()) |seg| {
        // #598: mention-dense tooling files (a bench script repeating the
        // term six times per line) saturate the per-line count and shrug off
        // the ×0.5 path prior — the occurrence BASE is capped for tooling.
        if (std.mem.eql(u8, seg, "bench") or std.mem.eql(u8, seg, "benchmarks") or
            std.mem.eql(u8, seg, "scripts") or std.mem.eql(u8, seg, "website") or
            std.mem.eql(u8, seg, "install")) c.is_tooling = true;
        if (std.mem.eql(u8, seg, "tests") or std.mem.eql(u8, seg, "test")) c.is_test = true;
        if (std.mem.eql(u8, seg, "examples") or std.mem.eql(u8, seg, "example")) c.is_example = true;
        if (std.mem.eql(u8, seg, "vendor") or std.mem.eql(u8, seg, "node_modules") or
            std.mem.eql(u8, seg, "third_party")) c.is_vendor = true;
    }
    // #580: match BM25's pathRelevanceMultiplier — test files identified by
    // BASENAME (tests.zig, test_*.zig, *_tests.zig) are tests even without
    // a test/ directory segment.
    const basename = std.fs.path.basename(path);
    if (std.mem.startsWith(u8, basename, "test") or std.mem.indexOf(u8, basename, "_test") != null) c.is_test = true;
    return c;
}

pub const FileOutline = struct {
    path: []const u8,
    language: Language,
    line_count: u32,
    byte_size: u64,
    symbols: std.ArrayList(Symbol) = .empty,
    imports: std.ArrayList([]const u8) = .empty,
    document_links: std.ArrayList(DocumentLink) = .empty,
    allocator: std.mem.Allocator,
    owns_path: bool = false,
    /// When true, `imports`, `document_links[].target`, and each
    /// `symbols[].name`/`.detail` are borrowed slices into an externally-owned buffer (the snapshot outline_state
    /// section, retained by the Explorer) rather than individual allocations,
    /// so deinit must not free them. The ArrayLists themselves are still owned.
    borrows_strings: bool = false,
    /// Optional packed backing for borrowed symbol/import strings. Worker-built
    /// outlines use one allocation instead of one malloc per string; snapshot
    /// outlines borrow external state and leave this null.
    owned_string_storage: ?[]u8 = null,
    /// Bitmask of symbol-name lengths present (bit min(len, 63)). A
    /// conservative superset — never cleared on symbol removal — that lets
    /// per-query definition scans (fileDefinesSymbol, pathRerankFacts) skip
    /// the whole symbol list when no name could match the query's length.
    /// Every site that appends to `symbols` must OR in the new name's bit.
    name_len_mask: u64 = 0,
    /// Query-independent path-prior classification (issue #429 signals),
    /// computed once at init — pure function of `path`, so reranks can read
    /// it instead of re-tokenizing the path on every query.
    path_class: PathClass = .{},

    pub fn nameLenBit(len: usize) u64 {
        return @as(u64, 1) << @as(u6, @intCast(@min(len, 63)));
    }

    pub fn init(allocator: std.mem.Allocator, path: []const u8) FileOutline {
        return .{
            .path = path,
            .language = detectLanguage(path),
            .line_count = 0,
            .byte_size = 0,
            .allocator = allocator,
            .path_class = classifyPath(path),
        };
    }
    pub fn deinit(self: *FileOutline) void {
        if (self.owns_path) self.allocator.free(self.path);
        if (self.owned_string_storage) |storage| {
            self.allocator.free(storage);
        } else if (!self.borrows_strings) {
            for (self.symbols.items) |sym| {
                self.allocator.free(sym.name);
                if (sym.detail) |d| self.allocator.free(d);
            }
            for (self.imports.items) |imp| self.allocator.free(imp);
            for (self.document_links.items) |link| self.allocator.free(link.target);
        }
        self.symbols.deinit(self.allocator);
        self.imports.deinit(self.allocator);
        self.document_links.deinit(self.allocator);
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
    ocaml,
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
    if (std.mem.endsWith(u8, path, ".ml") or std.mem.endsWith(u8, path, ".mli")) return .ocaml;
    return .unknown;
}

/// Resolution boundary for the approximate call graph. Closely interoperable
/// source families share a group; unrelated languages never resolve one
/// another's same-named functions.
fn callGraphLanguageGroup(language: Language) u8 {
    return switch (language) {
        .c, .cpp => 1,
        .javascript, .typescript, .svelte, .vue, .astro => 2,
        .java, .kotlin => 3,
        else => 16 + @as(u8, @intFromEnum(language)),
    };
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
    /// True when the results were served from the whole-query result cache.
    /// The tier/candidate/result fields then describe the search that
    /// PRODUCED the cached entry; the *_ns timings are zeroed because the
    /// hit did not pay them.
    cache_hit: bool = false,
};

pub const DependencyGraph = struct {
    forward: std.StringHashMap(std.ArrayList([]const u8)),
    reverse: std.StringHashMap(std.StringHashMap(void)),
    allocator: std.mem.Allocator,
    /// Owns the resolved dependency strings the graph creates (e.g. relative
    /// imports normalized to repo paths). Raw specifiers handed in by callers
    /// are still borrowed; only graph-minted strings live here. Freed after the
    /// maps in deinit, so map keys/values never outlive their backing bytes.
    str_arena: std.heap.ArenaAllocator,
    /// Dedup map for interned strings: resolved path -> its single arena-owned
    /// copy. Re-resolving the same import (e.g. on every watcher reindex) reuses
    /// that copy instead of growing the arena by a fresh allocation each time.
    interned: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator) DependencyGraph {
        return .{
            .forward = std.StringHashMap(std.ArrayList([]const u8)).init(allocator),
            .reverse = std.StringHashMap(std.StringHashMap(void)).init(allocator),
            .allocator = allocator,
            .str_arena = std.heap.ArenaAllocator.init(allocator),
            .interned = std.StringHashMap([]const u8).init(allocator),
        };
    }

    /// Intern a string into the graph-owned arena, returning a slice valid for
    /// the lifetime of the graph. Repeated calls with the same content return
    /// the same slice, so re-indexing a file does not leak a fresh copy per
    /// import. Use for resolved paths that have no other owner.
    pub fn internString(self: *DependencyGraph, s: []const u8) ![]const u8 {
        if (self.interned.get(s)) |existing| return existing;
        const owned = try self.str_arena.allocator().dupe(u8, s);
        try self.interned.put(owned, owned);
        return owned;
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

        // The interned map's keys/values live in str_arena; free the map
        // structure, then the arena (which forward/reverse also borrow from).
        self.interned.deinit();
        self.str_arena.deinit();
    }

    pub fn setDeps(self: *DependencyGraph, path: []const u8, deps: std.ArrayList([]const u8)) !void {
        // Remove old reverse edges for this path
        if (self.forward.getPtr(path)) |old_deps| {
            for (old_deps.items) |old_dep| {
                var remove_reverse_key = false;
                if (self.reverse.getPtr(old_dep)) |rev_set| {
                    _ = rev_set.remove(path);
                    remove_reverse_key = rev_set.count() == 0;
                }
                if (remove_reverse_key) {
                    if (self.reverse.fetchRemove(old_dep)) |removed| {
                        var rev_set = removed.value;
                        rev_set.deinit();
                    }
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
                var remove_reverse_key = false;
                if (self.reverse.getPtr(dep)) |rev_set| {
                    _ = rev_set.remove(path);
                    remove_reverse_key = rev_set.count() == 0;
                }
                if (remove_reverse_key) {
                    if (self.reverse.fetchRemove(dep)) |removed| {
                        var rev_set = removed.value;
                        rev_set.deinit();
                    }
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
        return self.getImportedByFiltered(path, allocator, true);
    }

    pub fn getImportedByFiltered(self: *const DependencyGraph, path: []const u8, allocator: std.mem.Allocator, allow_basename: bool) ![]const []const u8 {
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

        // Basename fallback (imports often use short names). Skipped when the basename is
        // ambiguous across indexed files (allow_basename=false): a bare `import conf`
        // can't be attributed to a specific same-basename file (a/conf.py vs b/conf.py).
        if (allow_basename and !std.mem.eql(u8, path, basename)) {
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

    /// Exact-path BFS with both depth and result caps. Documentation traversal
    /// uses this instead of the import graph's historically unbounded helpers.
    pub fn getTransitiveBounded(
        self: *const DependencyGraph,
        path: []const u8,
        allocator: std.mem.Allocator,
        max_depth: u32,
        max_results: usize,
        forward: bool,
    ) ![]const []const u8 {
        var visited = std.StringHashMap(void).init(allocator);
        defer visited.deinit();
        var queue: std.ArrayList(struct { path: []const u8, depth: u32 }) = .empty;
        defer queue.deinit(allocator);
        var result: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (result.items) |item| allocator.free(item);
            result.deinit(allocator);
        }

        try visited.put(path, {});
        try queue.append(allocator, .{ .path = path, .depth = 0 });
        var head: usize = 0;
        while (head < queue.items.len and result.items.len < max_results) {
            const item = queue.items[head];
            head += 1;
            if (item.depth >= max_depth) continue;

            if (forward) {
                const deps = self.forward.get(item.path) orelse continue;
                for (deps.items) |dep| {
                    if (visited.contains(dep)) continue;
                    try visited.put(dep, {});
                    const copy = try allocator.dupe(u8, dep);
                    result.append(allocator, copy) catch |err| {
                        allocator.free(copy);
                        return err;
                    };
                    if (result.items.len >= max_results) break;
                    try queue.append(allocator, .{ .path = dep, .depth = item.depth + 1 });
                }
            } else {
                const dependents = self.reverse.get(item.path) orelse continue;
                var iter = dependents.keyIterator();
                while (iter.next()) |key_ptr| {
                    const dep = key_ptr.*;
                    if (visited.contains(dep)) continue;
                    try visited.put(dep, {});
                    const copy = try allocator.dupe(u8, dep);
                    result.append(allocator, copy) catch |err| {
                        allocator.free(copy);
                        return err;
                    };
                    if (result.items.len >= max_results) break;
                    try queue.append(allocator, .{ .path = dep, .depth = item.depth + 1 });
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

fn symbolNavigationKindPriority(kind: SymbolKind) i32 {
    return switch (kind) {
        .function, .method => 100,
        .struct_def, .class_def, .interface_def, .enum_def, .union_def, .trait_def => 90,
        .impl_block => 80,
        .type_alias, .macro_def => 70,
        .constant => 60,
        .variable => 50,
        .test_decl => 10,
        .import, .comment_block => -1000,
    };
}

fn symbolNavigationPriority(name: []const u8, path: []const u8, kind: SymbolKind) i32 {
    var score = symbolNavigationKindPriority(kind);
    const class = classifyPath(path);
    if (class.is_vendor) score -= 1200;
    if (class.is_test) score -= 800;
    if (class.is_example) score -= 500;
    if (class.is_tooling) score -= 400;

    // Mixed-language repositories commonly keep executable-looking probes in
    // these directories. They are useful definitions, but poor default
    // navigation targets when production definitions of the same name exist.
    var segments = std.mem.tokenizeAny(u8, path, "/\\");
    while (segments.next()) |segment| {
        if (std.ascii.eqlIgnoreCase(segment, "experiments") or
            std.ascii.eqlIgnoreCase(segment, "experiment") or
            std.ascii.eqlIgnoreCase(segment, "e2e") or
            std.ascii.eqlIgnoreCase(segment, "fixtures") or
            std.ascii.eqlIgnoreCase(segment, "fixture") or
            std.ascii.eqlIgnoreCase(segment, "generated"))
        {
            score -= 700;
            break;
        }
    }

    const basename = std.fs.path.basename(path);
    const dot = std.mem.lastIndexOfScalar(u8, basename, '.') orelse basename.len;
    const stem = basename[0..dot];
    const eponymous = std.ascii.eqlIgnoreCase(stem, name);
    if (eponymous) score += 400;
    if (std.mem.startsWith(u8, path, "src/")) score += 120 else if (std.mem.indexOfScalar(u8, path, '/') == null) score += 80;

    // `main` is the one generic name with a cross-language package-entrypoint
    // convention. Keep this narrow; other common names remain visibly
    // ambiguous rather than acquiring hard-coded language preferences.
    if (eponymous and std.ascii.eqlIgnoreCase(name, "main")) {
        if (std.mem.startsWith(u8, path, "src/")) {
            score += 400;
        } else if (std.mem.indexOfScalar(u8, path, '/') == null) {
            score += 350;
        } else if (pathHasSegmentIgnoreCase(path, "cmd")) {
            score += 300;
        }
    }
    return score;
}

fn symbolNavigationBefore(
    name: []const u8,
    a_path: []const u8,
    a_kind: SymbolKind,
    a_line: u32,
    b_path: []const u8,
    b_kind: SymbolKind,
    b_line: u32,
) bool {
    const ap = symbolNavigationPriority(name, a_path, a_kind);
    const bp = symbolNavigationPriority(name, b_path, b_kind);
    if (ap != bp) return ap > bp;
    const path_order = std.mem.order(u8, a_path, b_path);
    if (path_order != .eq) return path_order == .lt;
    return a_line < b_line;
}

fn symbolNavigationLocationBefore(name: []const u8, a: SymbolLocation, b: SymbolLocation) bool {
    return symbolNavigationBefore(name, a.path, a.kind, a.line_start, b.path, b.kind, b.line_start);
}

fn symbolNavigationResultBefore(a: SymbolResult, b: SymbolResult) bool {
    const name_order = std.mem.order(u8, a.symbol.name, b.symbol.name);
    if (name_order != .eq) return name_order == .lt;
    return symbolNavigationBefore(a.symbol.name, a.path, a.symbol.kind, a.symbol.line_start, b.path, b.symbol.kind, b.symbol.line_start);
}

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
    radj: []std.ArrayList(codegraph.NodeId),
    node_path: []const []const u8,
    node_name: []const []const u8,
    node_line: []const u32,

    pub fn deinit(self: *CallGraph, allocator: std.mem.Allocator) void {
        allocator.free(self.edges);
        codegraph.freeAdjacency(allocator, self.adj);
        codegraph.freeAdjacency(allocator, self.radj);
        for (self.node_path) |p| allocator.free(p);
        allocator.free(self.node_path);
        for (self.node_name) |n| allocator.free(n);
        allocator.free(self.node_name);
        allocator.free(self.node_line);
    }
};

pub const CallPathStep = struct {
    path: []const u8,
    name: []const u8,
    line: u32,
};

/// rVSM file-size prior (BugLocator — Zhou et al., ICSE 2012). IR-based fault
/// localization shows the file a commit / bug report targets skews LARGE (core
/// files), yet codedb's ranking penalizes long docs. This is an opt-in EXPERIMENT
/// (research.md / todo.md P0): favor big *code* files via a multiplier on the
/// rerank score. Off unless CODEDB_RVSM_SIZE_PRIOR is set; amp/slope tunable via
/// CODEDB_RVSM_AMP (default 0.5) and CODEDB_RVSM_K (default 1.0). Size is the
/// file's line_count (always present on the search path; word-index doc lengths
/// are not — `search` runs with the word index disabled), normalized to the
/// corpus average over code files. Doc-language files are excluded (multiplier
/// 1.0) so a giant CHANGELOG can't ride the prior over the real code gold.
const RvsmSizePrior = struct {
    enabled: bool = false,
    amp: f32 = 0.5,
    k: f32 = 1.0,
    avg_lines: f32 = 1.0,

    fn envF32(name: []const u8, default_val: f32) f32 {
        const v = cio.posixGetenv(name) orelse return default_val;
        return std.fmt.parseFloat(f32, std.mem.trim(u8, v, " \t\r\n")) catch default_val;
    }

    fn fromEnv(ex: *const Explorer) RvsmSizePrior {
        if (cio.posixGetenv("CODEDB_RVSM_SIZE_PRIOR") == null) return .{};
        var total: u64 = 0;
        var n: u64 = 0;
        var it = ex.outlines.valueIterator();
        while (it.next()) |o| {
            if (o.line_count > 0 and !isDocLanguage(o.language)) {
                total += o.line_count;
                n += 1;
            }
        }
        const avg: f32 = if (n == 0) 1.0 else @as(f32, @floatFromInt(total)) / @as(f32, @floatFromInt(n));
        return .{
            .enabled = true,
            .amp = envF32("CODEDB_RVSM_AMP", 0.5),
            .k = envF32("CODEDB_RVSM_K", 1.0),
            .avg_lines = avg,
        };
    }

    /// Multiplier centered at 1.0 for an average-length code file:
    /// 1 + amp·tanh(k·(line_count/avg − 1)), in (1−amp, 1+amp). Monotonic in size.
    fn multiplier(self: RvsmSizePrior, ex: *const Explorer, path: []const u8) f32 {
        if (!self.enabled) return 1.0;
        const o = ex.outlines.get(path) orelse return 1.0;
        if (o.line_count == 0 or isDocLanguage(o.language)) return 1.0;
        const x = @as(f32, @floatFromInt(o.line_count)) / self.avg_lines;
        return 1.0 + self.amp * std.math.tanh(self.k * (x - 1.0));
    }
};

/// File-frequency lexical penalty: down-weight files the query matches on MANY
/// lines. A file the query saturates is usually a dispatcher, registry,
/// re-export, or changelog — not the implementation the searcher wants, which is
/// typically the file *named* after the concept (already lifted by the
/// eponymy/stem boost in rerankSignalScore). This is codedb's analog of engram's
/// learned negative-lexical weight (LEARNED_W lexical = -2). ON by default at amp
/// 0.8 (tuned on the swe-lite retrieval sweep: 0.8 lifted a buried gold with no
/// regressions, 0.95 over-penalized symbol-owner files whose gold is legitimately
/// saturated). Disable with CODEDB_LEX_FREQ_PENALTY=0; override strength with
/// CODEDB_LEX_FREQ_AMP. The multiplier is 1.0 for the least-matched file and
/// 1-amp for the most-matched, linear in normalized match-line count — it only
/// reorders among comparably-scored files and rarely overturns a strong
/// eponymy/symbol hit.
const LexFreqPenalty = struct {
    enabled: bool = true,
    amp: f32 = 0.8,

    fn fromEnv() LexFreqPenalty {
        if (cio.posixGetenv("CODEDB_LEX_FREQ_PENALTY")) |v| {
            if (std.mem.eql(u8, v, "0") or std.ascii.eqlIgnoreCase(v, "false") or std.ascii.eqlIgnoreCase(v, "off"))
                return .{ .enabled = false };
        }
        return .{ .enabled = true, .amp = RvsmSizePrior.envF32("CODEDB_LEX_FREQ_AMP", 0.8) };
    }

    /// cnt = match-line count for this file; max_count = the largest such count
    /// in the result set. Returns 1.0 when disabled or when every file ties
    /// (max_count <= 1) — nothing to discriminate.
    fn multiplier(self: LexFreqPenalty, cnt: u32, max_count: u32) f32 {
        if (!self.enabled or max_count <= 1) return 1.0;
        const norm = @as(f32, @floatFromInt(cnt - 1)) / @as(f32, @floatFromInt(max_count - 1));
        return 1.0 - self.amp * norm;
    }
};

/// Per-file content hashes for cached reads. Entries are keyed by path and
/// validated against the content-cache entry generation; mutation paths also
/// invalidate explicitly so allocator reuse cannot serve a stale `if_hash` result.
const ContentHashCache = struct {
    const Entry = struct {
        content_generation: u64,
        hash: u64,
    };

    map: std.StringHashMap(Entry),
    mu: cio.Mutex = .{},

    fn init(allocator: std.mem.Allocator) ContentHashCache {
        return .{ .map = std.StringHashMap(Entry).init(allocator) };
    }

    fn deinit(self: *ContentHashCache) void {
        var iter = self.map.keyIterator();
        while (iter.next()) |key| self.map.allocator.free(key.*);
        self.map.deinit();
    }

    fn get(self: *ContentHashCache, path: []const u8, content: []const u8, content_generation: u64, cacheable: bool) u64 {
        if (!cacheable) return std.hash.Wyhash.hash(0, content);
        self.mu.lock();
        defer self.mu.unlock();
        if (self.map.getPtr(path)) |entry| {
            if (entry.content_generation == content_generation) return entry.hash;
            const hash = std.hash.Wyhash.hash(0, content);
            entry.* = .{ .content_generation = content_generation, .hash = hash };
            return hash;
        }

        const hash = std.hash.Wyhash.hash(0, content);
        const key = self.map.allocator.dupe(u8, path) catch return hash;
        self.map.put(key, .{ .content_generation = content_generation, .hash = hash }) catch {
            self.map.allocator.free(key);
        };
        return hash;
    }

    fn clear(self: *ContentHashCache) void {
        self.mu.lock();
        defer self.mu.unlock();
        var iter = self.map.keyIterator();
        while (iter.next()) |key| self.map.allocator.free(key.*);
        self.map.clearRetainingCapacity();
    }

    fn invalidate(self: *ContentHashCache, path: []const u8) void {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.map.fetchRemove(path)) |removed| self.map.allocator.free(removed.key);
    }
};

/// Per-file newline-offset tables so Tier 0's line-number → line-text lookups
/// skip rescanning file bytes on every query. Entries self-validate against
/// the content slice (ptr+len) they were built from and are invalidated on
/// reindex/remove. Guarded by its own mutex because searchContent runs under
/// the Explorer's SHARED lock — concurrent readers may build entries.
const LineOffsetCache = struct {
    const Entry = struct {
        content_ptr: usize,
        content_len: usize,
        offsets: []u32,
    };
    pub const Span = struct {
        line: u32,
        start: usize,
        end: usize,
    };

    map: std.StringHashMap(Entry),
    mu: cio.Mutex = .{},
    total_bytes: usize = 0,

    const MAX_BYTES: usize = 16 * 1024 * 1024;

    fn init(allocator: std.mem.Allocator) LineOffsetCache {
        return .{ .map = std.StringHashMap(Entry).init(allocator) };
    }

    fn deinit(self: *LineOffsetCache) void {
        var iter = self.map.iterator();
        while (iter.next()) |e| {
            self.map.allocator.free(e.key_ptr.*);
            self.map.allocator.free(e.value_ptr.offsets);
        }
        self.map.deinit();
    }

    fn clearLocked(self: *LineOffsetCache) void {
        var iter = self.map.iterator();
        while (iter.next()) |e| {
            self.map.allocator.free(e.key_ptr.*);
            self.map.allocator.free(e.value_ptr.offsets);
        }
        self.map.clearRetainingCapacity();
        self.total_bytes = 0;
    }

    fn clear(self: *LineOffsetCache) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.clearLocked();
    }

    fn invalidate(self: *LineOffsetCache, path: []const u8) void {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.map.fetchRemove(path)) |kv| {
            self.total_bytes -= kv.value.offsets.len * @sizeOf(u32);
            self.map.allocator.free(kv.key);
            self.map.allocator.free(kv.value.offsets);
        }
    }

    fn buildOffsets(allocator: std.mem.Allocator, content: []const u8) ?[]u32 {
        var offsets: std.ArrayList(u32) = .empty;
        offsets.ensureTotalCapacity(allocator, @max(16, content.len / 32)) catch return null;
        offsets.appendAssumeCapacity(0);
        var pos: usize = 0;
        while (std.mem.indexOfScalarPos(u8, content, pos, '\n')) |nl| {
            pos = nl + 1;
            offsets.append(allocator, @intCast(pos)) catch {
                offsets.deinit(allocator);
                return null;
            };
        }
        return offsets.toOwnedSlice(allocator) catch {
            offsets.deinit(allocator);
            return null;
        };
    }

    /// Return the current offset table for `path`, rebuilding stale entries.
    /// Caller must hold `mu`.
    fn offsetsForLocked(self: *LineOffsetCache, path: []const u8, content: []const u8) ?[]const u32 {
        if (self.map.getPtr(path)) |entry| {
            if (entry.content_ptr == @intFromPtr(content.ptr) and entry.content_len == content.len) {
                return entry.offsets;
            }
            const fresh = buildOffsets(self.map.allocator, content) orelse return null;
            self.total_bytes -= entry.offsets.len * @sizeOf(u32);
            self.map.allocator.free(entry.offsets);
            entry.* = .{ .content_ptr = @intFromPtr(content.ptr), .content_len = content.len, .offsets = fresh };
            self.total_bytes += fresh.len * @sizeOf(u32);
            return fresh;
        }

        const fresh = buildOffsets(self.map.allocator, content) orelse return null;
        const key = self.map.allocator.dupe(u8, path) catch {
            self.map.allocator.free(fresh);
            return null;
        };
        self.map.put(key, .{ .content_ptr = @intFromPtr(content.ptr), .content_len = content.len, .offsets = fresh }) catch {
            self.map.allocator.free(fresh);
            self.map.allocator.free(key);
            return null;
        };
        self.total_bytes += fresh.len * @sizeOf(u32);
        return fresh;
    }

    /// Resolve ascending 1-based `target_lines` to byte spans in `content`,
    /// building (and caching) the offset table for `path` on first touch.
    /// Span semantics match std.mem.splitScalar(content, '\n'): a line ends
    /// before its '\n'; the final line ends at content.len. Returns the
    /// number of spans filled, or null when the table cannot be built (OOM)
    /// — the caller falls back to the scanning path.
    fn lineSpans(self: *LineOffsetCache, path: []const u8, content: []const u8, target_lines: []const u32, spans: []Span) ?usize {
        self.mu.lock();
        defer self.mu.unlock();
        const offsets = self.offsetsForLocked(path, content) orelse return null;

        var n: usize = 0;
        for (target_lines) |ln| {
            if (n >= spans.len) break;
            if (ln == 0 or ln > offsets.len) continue;
            const start: usize = offsets[ln - 1];
            const end: usize = if (ln < offsets.len) offsets[ln] - 1 else content.len;
            spans[n] = .{ .line = ln, .start = start, .end = end };
            n += 1;
        }

        if (self.total_bytes > MAX_BYTES) self.clearLocked();
        return n;
    }

    /// Render a contiguous line range without scanning bytes before `start`.
    /// Returns false only when the offset table could not be allocated.
    fn appendRange(
        self: *LineOffsetCache,
        path: []const u8,
        content: []const u8,
        start: u32,
        end: u32,
        compact: bool,
        language: Language,
        line_prefix: []const u8,
        allocator: std.mem.Allocator,
        out: *std.ArrayList(u8),
    ) !bool {
        self.mu.lock();
        defer self.mu.unlock();
        const offsets = self.offsetsForLocked(path, content) orelse return false;
        if (start == 0 or start > offsets.len or end < start) return true;

        const last: u32 = @intCast(@min(@as(usize, end), offsets.len));
        const writer = cio.listWriter(out, allocator);
        var line_num = start;
        while (line_num <= last) : (line_num += 1) {
            const byte_start: usize = offsets[line_num - 1];
            const byte_end: usize = if (line_num < offsets.len) offsets[line_num] - 1 else content.len;
            const line = content[byte_start..byte_end];
            if (compact and isCommentOrBlank(line, language)) continue;
            try writer.print("{s}{d:>5} | {s}\n", .{ line_prefix, line_num, line });
        }
        if (self.total_bytes > MAX_BYTES) self.clearLocked();
        return true;
    }
};

/// Whole-query result cache for searchContent: agents re-issue identical
/// searches constantly, and a hit copies the cached results into the
/// caller's allocator instead of re-running the search tiers. An entry is
/// served only when BOTH its generation (Explorer.search_gen, bumped by
/// every mutation that can change results: indexing, removal, word-index
/// rebuilds, and the lazy symbol-index / call-graph / co-change builds) and
/// its env fingerprint (the ranking kill-switch variables) still match — so
/// a hit can never observe state a fresh search would not have produced.
/// CODEDB_NO_SEARCH_CACHE=1 disables it entirely (the repo benchmark sets
/// this so its per-query numbers keep measuring uncached searches).
const SearchResultCache = struct {
    const CachedResult = struct {
        path: []u8,
        line_num: u32,
        line_text: []u8,
        score: f32,
    };
    const Entry = struct {
        query: []u8,
        max_results: usize,
        gen: u64,
        env_fp: u64,
        results: []CachedResult,
        /// Breakdown of the search that produced the entry (timings zeroed,
        /// cache_hit set), restored into last_search_breakdown on a hit so
        /// telemetry and the MCP provenance meta describe the results
        /// actually served instead of whatever search ran last.
        breakdown: SearchBreakdown,
        bytes: usize,
        last_used: u64,
    };

    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    mu: cio.Mutex = .{},
    tick: u64 = 0,
    total_bytes: usize = 0,
    /// Test-visible counters; production code does not read them.
    hits: u64 = 0,
    misses: u64 = 0,

    const MAX_ENTRIES: usize = 64;
    const MAX_BYTES: usize = 4 * 1024 * 1024;
    /// One entry may not claim more than a quarter of the byte budget.
    const MAX_ENTRY_BYTES: usize = MAX_BYTES / 4;

    fn init(allocator: std.mem.Allocator) SearchResultCache {
        return .{ .allocator = allocator };
    }

    fn freeEntry(self: *SearchResultCache, e: *Entry) void {
        self.allocator.free(e.query);
        for (e.results) |r| {
            self.allocator.free(r.path);
            self.allocator.free(r.line_text);
        }
        self.allocator.free(e.results);
    }

    fn deinit(self: *SearchResultCache) void {
        for (self.entries.items) |*e| self.freeEntry(e);
        self.entries.deinit(self.allocator);
    }

    /// On hit, returns results duped into `out_allocator` (caller owns each
    /// path/line_text and the slice, same contract as a fresh search) and
    /// writes the producing search's breakdown to `out_breakdown`. A stale
    /// same-key entry is dropped so the slot can refill.
    fn get(self: *SearchResultCache, query: []const u8, max_results: usize, gen: u64, env_fp: u64, out_allocator: std.mem.Allocator, out_breakdown: *SearchBreakdown) ?[]const SearchResult {
        self.mu.lock();
        defer self.mu.unlock();
        var i: usize = 0;
        while (i < self.entries.items.len) : (i += 1) {
            const e = &self.entries.items[i];
            if (e.max_results != max_results or !std.mem.eql(u8, e.query, query)) continue;
            if (e.gen != gen or e.env_fp != env_fp) {
                var dead = self.entries.swapRemove(i);
                self.total_bytes -= dead.bytes;
                self.freeEntry(&dead);
                self.misses += 1;
                return null;
            }
            const out = out_allocator.alloc(SearchResult, e.results.len) catch return null;
            var n: usize = 0;
            for (e.results) |r| {
                const p = out_allocator.dupe(u8, r.path) catch break;
                const t = out_allocator.dupe(u8, r.line_text) catch {
                    out_allocator.free(p);
                    break;
                };
                out[n] = .{ .path = p, .line_num = r.line_num, .line_text = t, .score = r.score };
                n += 1;
            }
            if (n != e.results.len) {
                // OOM mid-copy: release and fall through to a fresh search.
                for (out[0..n]) |r| {
                    out_allocator.free(r.path);
                    out_allocator.free(r.line_text);
                }
                out_allocator.free(out);
                return null;
            }
            self.tick += 1;
            e.last_used = self.tick;
            self.hits += 1;
            out_breakdown.* = e.breakdown;
            return out;
        }
        self.misses += 1;
        return null;
    }

    /// Copies `results` into cache-owned memory. Any OOM just skips caching.
    fn put(self: *SearchResultCache, query: []const u8, max_results: usize, gen: u64, env_fp: u64, results: []const SearchResult, breakdown: SearchBreakdown) void {
        var bytes: usize = query.len + @sizeOf(Entry);
        for (results) |r| bytes += r.path.len + r.line_text.len + @sizeOf(CachedResult);
        if (bytes > MAX_ENTRY_BYTES) return;

        const owned = self.allocator.alloc(CachedResult, results.len) catch return;
        var n: usize = 0;
        for (results) |r| {
            const p = self.allocator.dupe(u8, r.path) catch break;
            const t = self.allocator.dupe(u8, r.line_text) catch {
                self.allocator.free(p);
                break;
            };
            owned[n] = .{ .path = p, .line_num = r.line_num, .line_text = t, .score = r.score };
            n += 1;
        }
        const query_copy = if (n == results.len) self.allocator.dupe(u8, query) catch null else null;
        if (query_copy == null) {
            for (owned[0..n]) |r| {
                self.allocator.free(r.path);
                self.allocator.free(r.line_text);
            }
            self.allocator.free(owned);
            return;
        }

        self.mu.lock();
        defer self.mu.unlock();
        // Replace any existing same-key entry (it was a miss or stale).
        var i: usize = 0;
        while (i < self.entries.items.len) {
            const e = &self.entries.items[i];
            if (e.max_results == max_results and std.mem.eql(u8, e.query, query)) {
                var dead = self.entries.swapRemove(i);
                self.total_bytes -= dead.bytes;
                self.freeEntry(&dead);
                continue;
            }
            i += 1;
        }
        // Evict least-recently-used entries until the new one fits.
        while (self.entries.items.len >= MAX_ENTRIES or
            (self.entries.items.len > 0 and self.total_bytes + bytes > MAX_BYTES))
        {
            var lru: usize = 0;
            for (self.entries.items, 0..) |e, j| {
                if (e.last_used < self.entries.items[lru].last_used) lru = j;
            }
            var dead = self.entries.swapRemove(lru);
            self.total_bytes -= dead.bytes;
            self.freeEntry(&dead);
        }
        self.tick += 1;
        self.entries.append(self.allocator, .{
            .query = query_copy.?,
            .max_results = max_results,
            .gen = gen,
            .env_fp = env_fp,
            .results = owned,
            .breakdown = sanitizeCachedBreakdown(breakdown),
            .bytes = bytes,
            .last_used = self.tick,
        }) catch {
            self.allocator.free(query_copy.?);
            for (owned) |r| {
                self.allocator.free(r.path);
                self.allocator.free(r.line_text);
            }
            self.allocator.free(owned);
            return;
        };
        self.total_bytes += bytes;
    }
};

/// Keep the producing search's provenance (tier/candidate/result counts) but
/// zero the timings a hit never pays, and mark it as a hit. Stored at put
/// time so a cache hit can restore an honest last_search_breakdown.
fn sanitizeCachedBreakdown(bd: SearchBreakdown) SearchBreakdown {
    return .{
        .tier_reached = bd.tier_reached,
        .candidate_count = bd.candidate_count,
        .result_count = bd.result_count,
        .cache_hit = true,
    };
}

/// Rendered-output sibling of SearchResultCache for renderPlainSearch — the
/// MCP fast path renders straight to text and never reaches searchContent,
/// so it gets its own (query, max_results, paths_only) → bytes cache with
/// identical generation + env-fingerprint validation and LRU discipline.
const PlainRenderCache = struct {
    const Entry = struct {
        query: []u8,
        max_results: usize,
        paths_only: bool,
        gen: u64,
        env_fp: u64,
        bytes: []u8,
        /// See SearchResultCache.Entry.breakdown.
        breakdown: SearchBreakdown,
        last_used: u64,
    };

    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    mu: cio.Mutex = .{},
    tick: u64 = 0,
    total_bytes: usize = 0,
    /// Test-visible counters; production code does not read them.
    hits: u64 = 0,
    misses: u64 = 0,

    const MAX_ENTRIES: usize = 64;
    const MAX_BYTES: usize = 4 * 1024 * 1024;
    const MAX_ENTRY_BYTES: usize = MAX_BYTES / 4;

    fn init(allocator: std.mem.Allocator) PlainRenderCache {
        return .{ .allocator = allocator };
    }

    fn freeEntry(self: *PlainRenderCache, e: *Entry) void {
        self.allocator.free(e.query);
        self.allocator.free(e.bytes);
    }

    fn deinit(self: *PlainRenderCache) void {
        for (self.entries.items) |*e| self.freeEntry(e);
        self.entries.deinit(self.allocator);
    }

    /// On hit, appends the cached rendering to `out`, writes the producing
    /// search's breakdown to `out_breakdown`, and returns true.
    fn render(self: *PlainRenderCache, query: []const u8, max_results: usize, paths_only: bool, gen: u64, env_fp: u64, out_allocator: std.mem.Allocator, out: *std.ArrayList(u8), out_breakdown: *SearchBreakdown) bool {
        self.mu.lock();
        defer self.mu.unlock();
        var i: usize = 0;
        while (i < self.entries.items.len) : (i += 1) {
            const e = &self.entries.items[i];
            if (e.max_results != max_results or e.paths_only != paths_only or !std.mem.eql(u8, e.query, query)) continue;
            if (e.gen != gen or e.env_fp != env_fp) {
                var dead = self.entries.swapRemove(i);
                self.total_bytes -= dead.bytes.len;
                self.freeEntry(&dead);
                self.misses += 1;
                return false;
            }
            out.appendSlice(out_allocator, e.bytes) catch return false;
            self.tick += 1;
            e.last_used = self.tick;
            self.hits += 1;
            out_breakdown.* = e.breakdown;
            return true;
        }
        self.misses += 1;
        return false;
    }

    /// Copies `bytes` into cache-owned memory. Any OOM just skips caching.
    fn put(self: *PlainRenderCache, query: []const u8, max_results: usize, paths_only: bool, gen: u64, env_fp: u64, bytes: []const u8, breakdown: SearchBreakdown) void {
        if (bytes.len > MAX_ENTRY_BYTES) return;
        const bytes_copy = self.allocator.dupe(u8, bytes) catch return;
        const query_copy = self.allocator.dupe(u8, query) catch {
            self.allocator.free(bytes_copy);
            return;
        };

        self.mu.lock();
        defer self.mu.unlock();
        var i: usize = 0;
        while (i < self.entries.items.len) {
            const e = &self.entries.items[i];
            if (e.max_results == max_results and e.paths_only == paths_only and std.mem.eql(u8, e.query, query)) {
                var dead = self.entries.swapRemove(i);
                self.total_bytes -= dead.bytes.len;
                self.freeEntry(&dead);
                continue;
            }
            i += 1;
        }
        while (self.entries.items.len >= MAX_ENTRIES or
            (self.entries.items.len > 0 and self.total_bytes + bytes_copy.len > MAX_BYTES))
        {
            var lru: usize = 0;
            for (self.entries.items, 0..) |e, j| {
                if (e.last_used < self.entries.items[lru].last_used) lru = j;
            }
            var dead = self.entries.swapRemove(lru);
            self.total_bytes -= dead.bytes.len;
            self.freeEntry(&dead);
        }
        self.tick += 1;
        self.entries.append(self.allocator, .{
            .query = query_copy,
            .max_results = max_results,
            .paths_only = paths_only,
            .gen = gen,
            .env_fp = env_fp,
            .bytes = bytes_copy,
            .breakdown = sanitizeCachedBreakdown(breakdown),
            .last_used = self.tick,
        }) catch {
            self.allocator.free(query_copy);
            self.allocator.free(bytes_copy);
            return;
        };
        self.total_bytes += bytes_copy.len;
    }
};

pub const FuzzyFileMatch = struct {
    path: []const u8,
    score: f32,
};

/// Generation-keyed cache for fuzzy file scoring. Paths borrow stable outline
/// keys; callers receive a copied match array so combo boosts remain per-call.
const FuzzyFileCache = struct {
    const Entry = struct {
        query: []u8,
        max_results: usize,
        gen: SearchGeneration,
        matches: []FuzzyFileMatch,
        last_used: u64,
    };

    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    mu: cio.Mutex = .{},
    tick: u64 = 0,

    const MAX_ENTRIES: usize = 32;

    fn init(allocator: std.mem.Allocator) FuzzyFileCache {
        return .{ .allocator = allocator };
    }

    fn freeEntry(self: *FuzzyFileCache, entry: *Entry) void {
        self.allocator.free(entry.query);
        self.allocator.free(entry.matches);
    }

    fn deinit(self: *FuzzyFileCache) void {
        for (self.entries.items) |*entry| self.freeEntry(entry);
        self.entries.deinit(self.allocator);
    }

    fn get(self: *FuzzyFileCache, query: []const u8, max_results: usize, gen: SearchGeneration, out_allocator: std.mem.Allocator) ?[]FuzzyFileMatch {
        self.mu.lock();
        defer self.mu.unlock();
        for (self.entries.items) |*entry| {
            if (entry.max_results != max_results or entry.gen != gen or !std.mem.eql(u8, entry.query, query)) continue;
            const copy = out_allocator.dupe(FuzzyFileMatch, entry.matches) catch return null;
            self.tick += 1;
            entry.last_used = self.tick;
            return copy;
        }
        return null;
    }

    fn put(self: *FuzzyFileCache, query: []const u8, max_results: usize, gen: SearchGeneration, matches: []const FuzzyFileMatch) void {
        const query_copy = self.allocator.dupe(u8, query) catch return;
        const matches_copy = self.allocator.dupe(FuzzyFileMatch, matches) catch {
            self.allocator.free(query_copy);
            return;
        };
        self.mu.lock();
        defer self.mu.unlock();
        var i: usize = 0;
        while (i < self.entries.items.len) {
            const entry = &self.entries.items[i];
            if (entry.max_results == max_results and std.mem.eql(u8, entry.query, query)) {
                var dead = self.entries.swapRemove(i);
                self.freeEntry(&dead);
                continue;
            }
            i += 1;
        }
        if (self.entries.items.len >= MAX_ENTRIES) {
            var lru: usize = 0;
            for (self.entries.items, 0..) |entry, index| {
                if (entry.last_used < self.entries.items[lru].last_used) lru = index;
            }
            var dead = self.entries.swapRemove(lru);
            self.freeEntry(&dead);
        }
        self.tick += 1;
        self.entries.append(self.allocator, .{
            .query = query_copy,
            .max_results = max_results,
            .gen = gen,
            .matches = matches_copy,
            .last_used = self.tick,
        }) catch {
            self.allocator.free(query_copy);
            self.allocator.free(matches_copy);
        };
    }
};

/// Generation-keyed render cache for `codedb_tree`. Tree construction sorts every
/// indexed path and rebuilds the directory set, while the result changes only on
/// an Explorer mutation. Keep separate plain/color entries and copy cached bytes
/// directly into the caller's response buffer.
const TreeRenderCache = struct {
    const Entry = struct {
        gen: SearchGeneration,
        bytes: []u8,
    };

    allocator: std.mem.Allocator,
    entries: [2]?Entry = .{ null, null },
    mu: cio.Mutex = .{},

    fn init(allocator: std.mem.Allocator) TreeRenderCache {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *TreeRenderCache) void {
        for (&self.entries) |*entry| {
            if (entry.*) |e| self.allocator.free(e.bytes);
            entry.* = null;
        }
    }

    fn render(self: *TreeRenderCache, gen: SearchGeneration, use_color: bool, out_allocator: std.mem.Allocator, out: *std.ArrayList(u8)) bool {
        self.mu.lock();
        defer self.mu.unlock();
        const index: usize = @intFromBool(use_color);
        const entry = self.entries[index] orelse return false;
        if (entry.gen != gen) return false;
        out.appendSlice(out_allocator, entry.bytes) catch return false;
        return true;
    }

    fn put(self: *TreeRenderCache, gen: SearchGeneration, use_color: bool, bytes: []const u8) void {
        if (bytes.len > 16 * 1024 * 1024) return;
        const copy = self.allocator.dupe(u8, bytes) catch return;
        self.mu.lock();
        defer self.mu.unlock();
        const index: usize = @intFromBool(use_color);
        if (self.entries[index]) |old| self.allocator.free(old.bytes);
        self.entries[index] = .{ .gen = gen, .bytes = copy };
    }
};

/// Small generation-keyed cache for rendered outlines. Large outlines are
/// expensive to format repeatedly but cheap to copy into an MCP response.
const OutlineRenderCache = struct {
    const Entry = struct {
        path: []u8,
        compact: bool,
        gen: SearchGeneration,
        bytes: []u8,
        last_used: u64,
    };

    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    mu: cio.Mutex = .{},
    tick: u64 = 0,
    total_bytes: usize = 0,

    const MAX_ENTRIES: usize = 32;
    const MAX_BYTES: usize = 16 * 1024 * 1024;
    const MAX_ENTRY_BYTES: usize = 4 * 1024 * 1024;

    fn init(allocator: std.mem.Allocator) OutlineRenderCache {
        return .{ .allocator = allocator };
    }

    fn freeEntry(self: *OutlineRenderCache, entry: *Entry) void {
        self.allocator.free(entry.path);
        self.allocator.free(entry.bytes);
    }

    fn deinit(self: *OutlineRenderCache) void {
        for (self.entries.items) |*entry| self.freeEntry(entry);
        self.entries.deinit(self.allocator);
    }

    fn render(self: *OutlineRenderCache, path: []const u8, compact: bool, gen: SearchGeneration, out_allocator: std.mem.Allocator, out: *std.ArrayList(u8)) bool {
        self.mu.lock();
        defer self.mu.unlock();
        for (self.entries.items) |*entry| {
            if (entry.compact != compact or entry.gen != gen or !std.mem.eql(u8, entry.path, path)) continue;
            out.appendSlice(out_allocator, entry.bytes) catch return false;
            self.tick += 1;
            entry.last_used = self.tick;
            return true;
        }
        return false;
    }

    fn put(self: *OutlineRenderCache, path: []const u8, compact: bool, gen: SearchGeneration, bytes: []const u8) void {
        if (bytes.len > MAX_ENTRY_BYTES) return;
        const path_copy = self.allocator.dupe(u8, path) catch return;
        const bytes_copy = self.allocator.dupe(u8, bytes) catch {
            self.allocator.free(path_copy);
            return;
        };

        self.mu.lock();
        defer self.mu.unlock();
        var i: usize = 0;
        while (i < self.entries.items.len) {
            const entry = &self.entries.items[i];
            if (entry.compact == compact and std.mem.eql(u8, entry.path, path)) {
                var dead = self.entries.swapRemove(i);
                self.total_bytes -= dead.bytes.len;
                self.freeEntry(&dead);
                continue;
            }
            i += 1;
        }
        while (self.entries.items.len >= MAX_ENTRIES or
            (self.entries.items.len > 0 and self.total_bytes + bytes_copy.len > MAX_BYTES))
        {
            var lru: usize = 0;
            for (self.entries.items, 0..) |entry, index| {
                if (entry.last_used < self.entries.items[lru].last_used) lru = index;
            }
            var dead = self.entries.swapRemove(lru);
            self.total_bytes -= dead.bytes.len;
            self.freeEntry(&dead);
        }
        self.tick += 1;
        self.entries.append(self.allocator, .{
            .path = path_copy,
            .compact = compact,
            .gen = gen,
            .bytes = bytes_copy,
            .last_used = self.tick,
        }) catch {
            self.allocator.free(path_copy);
            self.allocator.free(bytes_copy);
            return;
        };
        self.total_bytes += bytes_copy.len;
    }
};

/// Fingerprint of the env kill-switches that change ranking/search output —
/// part of the SearchResultCache key so toggling one (tests do this
/// mid-process) can never serve results computed under the other setting.
fn rankingEnvFingerprint() u64 {
    var h = std.hash.Wyhash.init(0x5eed);
    inline for ([_][]const u8{
        "CODEDB_NO_CENTRALITY",
        "CODEDB_NO_GRAPH_DISTANCE",
        "CODEDB_NO_COCHANGE",
        "CODEDB_LEX_FREQ_PENALTY",
        "CODEDB_LEX_FREQ_AMP",
        "CODEDB_RVSM_SIZE_PRIOR",
        "CODEDB_RVSM_AMP",
        "CODEDB_RVSM_K",
        "CODEDB_IN_DEGREE_CENTRALITY",
    }) |name| {
        h.update(name);
        if (cio.posixGetenv(name)) |v| h.update(v) else h.update(&[_]u8{0});
    }
    return h.final();
}

pub const Explorer = struct {
    outlines: std.StringHashMap(FileOutline),
    dep_graph: DependencyGraph,
    /// Markdown-to-Markdown links are kept separate from language imports so
    /// callers can preserve edge type and apply tighter traversal bounds.
    document_graph: DependencyGraph,
    contents: ContentCache,
    content_hashes: ContentHashCache,
    line_offsets: LineOffsetCache,
    symbol_index: std.StringHashMap(std.ArrayList(SymbolLocation)),
    /// False after a snapshot fast-load until ensureSymbolIndex runs (#564).
    symbol_index_complete: bool,
    /// Inverted split-name token → def_token_names indices for the NL→symbol
    /// bridge in searchContentRanked. Built lazily once per search generation
    /// (ensureDefTokenIndex), so the per-query bridge costs a few hash lookups
    /// instead of a full symbol-index sweep. Keys and names are owned copies.
    def_token_index: std.StringHashMap(std.ArrayList(u32)),
    def_token_names: std.ArrayList([]const u8) = .empty,
    def_token_gen: ?SearchGeneration = null,
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
    /// Retained call graph (edges + adjacency + per-node metadata). Ranking
    /// first builds the historical fast approximate graph; codedb_callpath
    /// upgrades it in place to strict scoped/import-aware resolution.
    call_graph: ?CallGraph = null,
    /// Ranking uses the historical fast approximate graph. User-visible
    /// callpaths upgrade it in place to strict scoped/import-aware resolution.
    call_graph_exact: bool = false,
    centrality_build_mu: cio.Mutex = .{},
    root_dir: ?std.Io.Dir = null,
    /// Absolute project root path (duped in setRoot) — needed to shell out to
    /// git for the co-change map (#550).
    root_path: ?[]const u8 = null,
    /// file → strongest git co-change partners (#550). Built lazily from
    /// `git log --name-only`; null until built (or unavailable: no root, not
    /// a repo). Guarded by cochange_build_mu; attempted-flag stops re-shelling
    /// when git is absent.
    co_change: ?std.StringHashMap([]git.CoChangePartner) = null,
    co_change_attempted: bool = false,
    cochange_build_mu: cio.Mutex = .{},
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
    /// Whole-query result cache for searchContent, validated against
    /// search_gen + the ranking-env fingerprint (see SearchResultCache).
    search_cache: SearchResultCache,
    /// Separate instance for searchContentRanked (BM25 path): the two
    /// functions return DIFFERENT results for the same (query, max_results)
    /// key, so they must never share entries.
    ranked_cache: SearchResultCache,
    /// Rendered-output cache for renderPlainSearch (same validation).
    plain_render_cache: PlainRenderCache,
    /// Rendered tree output, keyed by mutation generation and color mode.
    tree_render_cache: TreeRenderCache,
    /// Rendered outlines, keyed by path, compact mode, and mutation generation.
    outline_render_cache: OutlineRenderCache,
    /// Fuzzy file-score results, keyed by query, limit, and mutation generation.
    fuzzy_file_cache: FuzzyFileCache,
    /// Rendered exact-word postings, using an independent path-keyed LRU.
    word_render_cache: OutlineRenderCache,
    /// Bumped (atomically — searches run under the SHARED lock) by every
    /// mutation that can change search results; see bumpSearchGen callers.
    search_gen: std.atomic.Value(SearchGeneration) = std.atomic.Value(SearchGeneration).init(0),
    /// Buffers adopted from snapshot loads (the raw outline_state section).
    /// Restored FileOutlines borrow their import/symbol strings as slices into
    /// these (see FileOutline.borrows_strings), so they must outlive every
    /// restored outline; freed once here at Explorer.deinit.
    outline_section_bufs: std.ArrayList([]const u8) = .empty,
    /// mmap'd snapshot content sections adopted at load. The ContentCache stores
    /// borrowed (value_owned=false) slices into these for restored files, so they
    /// must outlive the cache; munmap'd once here at Explorer.deinit.
    content_section_maps: std.ArrayList([]align(std.heap.page_size_min) const u8) = .empty,
    /// A snapshot-backed MCP can serve before the watcher's initial diff has
    /// reconciled edits made after the snapshot. ANN freshness waits for this
    /// one bounded startup phase only; genuine stale sidecars never trigger a
    /// second full tree walk from the query path.
    startup_reconcile_expected: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    startup_reconcile_complete: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Default file-content cache capacity. Was 16384, but on typical
    /// projects (≤2000 files) the cache only ever holds a few hundred
    /// entries — the other 14000+ slots are pure overhead (786 KB of
    /// metadata alone for the 16 384-slot Slot array). 4096 is plenty
    /// for 99% of repos; large monorepos can override via config or
    /// pass a custom value to Explorer.init.
    pub const DEFAULT_CONTENT_CACHE_CAPACITY: u32 = 4096;

    pub fn expectStartupReconcile(self: *Explorer) void {
        self.startup_reconcile_complete.store(false, .release);
        self.startup_reconcile_expected.store(true, .release);
    }

    pub fn finishStartupReconcile(self: *Explorer) void {
        self.startup_reconcile_complete.store(true, .release);
    }

    pub fn startupReconcilePending(self: *const Explorer) bool {
        return self.startup_reconcile_expected.load(.acquire) and
            !self.startup_reconcile_complete.load(.acquire);
    }

    test "ANN startup freshness waits only for an expected watcher reconcile" {
        var explorer = Explorer.init(std.testing.allocator, 1024 * 1024);
        defer explorer.deinit();
        try std.testing.expect(!explorer.startupReconcilePending());
        explorer.expectStartupReconcile();
        try std.testing.expect(explorer.startupReconcilePending());
        explorer.finishStartupReconcile();
        try std.testing.expect(!explorer.startupReconcilePending());
    }

    /// Establish the project root as one validated filesystem capability.
    /// The final component is never followed, temp-project admission is
    /// checked through the opened handle, and replacement is transactional:
    /// a failed call leaves the previous root intact.
    pub fn setRoot(self: *Explorer, io: std.Io, root_path: []const u8) !void {
        if (!root_policy.isAbsoluteRootRequest(root_path)) return error.PathNotAllowed;
        const new_dir = try std.Io.Dir.cwd().openDir(io, root_path, .{ .follow_symlinks = false, .iterate = true });
        errdefer new_dir.close(io);

        var canonical_buf: [std.fs.max_path_bytes]u8 = undefined;
        const canonical_len = try new_dir.realPathFile(io, ".", &canonical_buf);
        const canonical = canonical_buf[0..canonical_len];
        if (!root_policy.isAdmissibleRootDir(io, new_dir, canonical)) return error.PathNotAllowed;
        const new_path = try self.allocator.dupe(u8, canonical);

        const old_dir = self.root_dir;
        const old_path = self.root_path;
        self.io = io;
        self.root_dir = new_dir;
        self.root_path = new_path;
        if (old_dir) |dir| dir.close(io);
        if (old_path) |path| self.allocator.free(path);
    }

    test "setRoot establishes one no-follow capability and swaps transactionally" {
        const testing = std.testing;
        const test_io = testing.io;
        var first = testing.tmpDir(.{});
        defer first.cleanup();
        var second = testing.tmpDir(.{});
        defer second.cleanup();
        try first.dir.writeFile(test_io, .{ .sub_path = "build.zig", .data = "// marker\n" });
        try second.dir.writeFile(test_io, .{ .sub_path = "build.zig", .data = "// marker\n" });

        var first_buf: [std.fs.max_path_bytes]u8 = undefined;
        const first_len = try first.dir.realPathFile(test_io, ".", &first_buf);
        var second_buf: [std.fs.max_path_bytes]u8 = undefined;
        const second_len = try second.dir.realPathFile(test_io, ".", &second_buf);

        var explorer = Explorer.init(testing.allocator, 4);
        defer explorer.deinit();
        try explorer.setRoot(test_io, first_buf[0..first_len]);
        var root_iter = explorer.root_dir.?.iterate();
        var saw_marker = false;
        while (try root_iter.next(test_io)) |entry| {
            if (std.mem.eql(u8, entry.name, "build.zig")) saw_marker = true;
        }
        try testing.expect(saw_marker);
        const retired = explorer.root_dir.?;
        try explorer.setRoot(test_io, second_buf[0..second_len]);
        if (comptime builtin.os.tag != .windows) {
            const rc = std.posix.system.fcntl(retired.handle, std.posix.F.GETFD, @as(usize, 0));
            try testing.expectEqual(std.posix.E.BADF, std.posix.errno(rc));
        }
        try testing.expectEqualStrings(second_buf[0..second_len], explorer.root_path.?);

        try first.dir.symLink(test_io, second_buf[0..second_len], "retarget", .{});
        const alias = try std.fmt.allocPrint(testing.allocator, "{s}/retarget", .{first_buf[0..first_len]});
        defer testing.allocator.free(alias);
        if (explorer.setRoot(test_io, alias)) |_| return error.TestUnexpectedResult else |_| {}
        try testing.expectEqualStrings(second_buf[0..second_len], explorer.root_path.?);
        try testing.expectError(error.PathNotAllowed, explorer.setRoot(test_io, "relative/project"));
    }

    pub fn init(allocator: std.mem.Allocator, content_cache_capacity: u32) Explorer {
        return initFallible(allocator, content_cache_capacity) catch
            std.debug.panic("Explorer.init: OOM allocating {d} content cache slots", .{content_cache_capacity});
    }

    fn initFallible(allocator: std.mem.Allocator, content_cache_capacity: u32) !Explorer {
        return .{
            .outlines = std.StringHashMap(FileOutline).init(allocator),
            .dep_graph = DependencyGraph.init(allocator),
            .document_graph = DependencyGraph.init(allocator),
            .contents = try ContentCache.initAlloc(allocator, content_cache_capacity),
            .content_hashes = ContentHashCache.init(allocator),
            .line_offsets = LineOffsetCache.init(allocator),
            .search_cache = SearchResultCache.init(allocator),
            .ranked_cache = SearchResultCache.init(allocator),
            .plain_render_cache = PlainRenderCache.init(allocator),
            .tree_render_cache = TreeRenderCache.init(allocator),
            .outline_render_cache = OutlineRenderCache.init(allocator),
            .fuzzy_file_cache = FuzzyFileCache.init(allocator),
            .word_render_cache = OutlineRenderCache.init(allocator),
            .symbol_index = std.StringHashMap(std.ArrayList(SymbolLocation)).init(allocator),
            .symbol_index_complete = true,
            .def_token_index = std.StringHashMap(std.ArrayList(u32)).init(allocator),
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
        self.document_graph.deinit();

        var sym_iter = self.symbol_index.iterator();
        while (sym_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.symbol_index.deinit();

        self.clearDefTokenIndexLocked();
        self.def_token_index.deinit();
        self.def_token_names.deinit(self.allocator);

        self.contents.deinit();
        self.content_hashes.deinit();
        self.line_offsets.deinit();
        self.search_cache.deinit();
        self.ranked_cache.deinit();
        self.plain_render_cache.deinit();
        self.tree_render_cache.deinit();
        self.outline_render_cache.deinit();
        self.fuzzy_file_cache.deinit();
        self.word_render_cache.deinit();
        if (self.call_centrality) |*c| c.deinit();
        if (self.call_graph) |*cg| cg.deinit(self.allocator);
        if (self.co_change) |*cc| git.freeCoChange(cc, self.allocator);
        if (self.root_path) |p| self.allocator.free(p);

        self.word_index.deinit();
        self.trigram_index.deinit();
        self.skip_trigram_files.deinit();
        // Freed after outlines (above) since restored outlines borrow into these.
        for (self.outline_section_bufs.items) |b| self.allocator.free(b);
        self.outline_section_bufs.deinit(self.allocator);
        // munmap'd after contents.deinit (above): the cache holds borrowed slices
        // into these maps, but deinit skips freeing borrowed values, so the maps
        // are still valid through it and only released here.
        for (self.content_section_maps.items) |m| cio.munmap(m);
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
        self.content_hashes.clear();
        self.line_offsets.clear();
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
        // The parsed outline is always consumed, including when cloning fails.
        defer owned_outline.deinit();
        const persistent_outline = try cloneOutlineBorrowingPath(&owned_outline, self.allocator);
        return self.commitParsedFileAdoptOutline(path, content, persistent_outline, full_index, skip_trigram);
    }

    /// Commit an outline whose strings and list storage already have a lifetime
    /// independent of the parser/worker that produced it. Ownership is consumed
    /// on both success and error. The outline path may be borrowed: commit rebinds
    /// it to the stable key owned by `self.outlines` before publishing it.
    pub fn commitParsedFileAdoptOutline(self: *Explorer, path: []const u8, content: []const u8, outline: FileOutline, full_index: bool, skip_trigram: bool) !void {
        var persistent_outline = outline;
        errdefer persistent_outline.deinit();

        self.mu.lock();
        defer self.mu.unlock();
        self.bumpSearchGen();
        if (self.call_graph) |*cg| {
            cg.deinit(self.allocator);
            self.call_graph = null;
            self.call_graph_exact = false;
        }
        if (self.call_centrality) |*cc| {
            cc.deinit();
            self.call_centrality = null;
        }

        const outline_gop = try self.outlines.getOrPut(path);
        const is_new = !outline_gop.found_existing;
        var new_stable_path: ?[]const u8 = null;
        errdefer if (is_new) {
            _ = self.outlines.remove(new_stable_path orelse path);
            if (new_stable_path) |owned_path| self.allocator.free(owned_path);
        };
        var prior_outline: ?FileOutline = if (outline_gop.found_existing)
            outline_gop.value_ptr.*
        else
            null;
        const stable_path = if (outline_gop.found_existing) blk: {
            break :blk outline_gop.key_ptr.*;
        } else blk: {
            const duped = try self.allocator.dupe(u8, path);
            new_stable_path = duped;
            outline_gop.key_ptr.* = duped;
            break :blk duped;
        };

        if (persistent_outline.owns_path) {
            persistent_outline.allocator.free(persistent_outline.path);
            persistent_outline.owns_path = false;
        }
        persistent_outline.path = stable_path;

        const prior_content = self.contents.get(stable_path);
        // Any failure below must put the word index back the way it was —
        // indexFile wipes the old postings before adding new ones, and search
        // serves whatever the postings say. prior_content stays valid through
        // every fallible step because contents.put runs last.
        errdefer if (full_index and !self.defer_word_index) {
            if (prior_content) |old| {
                self.word_index.indexFile(stable_path, old) catch {};
            } else {
                self.word_index.removeFile(stable_path);
            }
        };

        if (full_index) {
            // A disabled word index (cold CLI scan keeps it off to save memory)
            // can't absorb this file, so it no longer reflects the indexed set —
            // ranked/BM25 readers must lazy-rebuild instead of trusting it (#546).
            if (!self.word_index.enabled) self.word_index_complete = false;
            if (!self.word_index_complete) {
                self.word_index_can_load_from_disk = false;
            }
            if (!self.defer_word_index) try self.word_index.indexFile(stable_path, content);
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
        try self.rebuildDocumentDepsFor(stable_path, &persistent_outline);
        if (is_new and persistent_outline.language == .markdown) {
            try self.refreshDocumentLinksTo(stable_path);
        }
        self.rebuildSymbolIndexFor(stable_path, &persistent_outline, !is_new);

        // Last fallible step: put frees the prior cache value in place, so it
        // must run only once nothing after it can still need prior_content.
        try self.contents.put(stable_path, content);
        self.content_hashes.invalidate(stable_path);
        self.line_offsets.invalidate(stable_path);

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
            outline.language == .kotlin or outline.language == .swift or
            outline.language == .svelte or
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
        var ocaml_comment_depth: u32 = 0;
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

            // OCaml nested (* ... *) block comments. Comment delimiters are ignored
            // inside string and char literals so that `let pattern = "(*"` does not
            // throw the scanner out of sync (PR review).
            if (outline.language == .ocaml) {
                if (ocaml_comment_depth > 0) {
                    // We're inside a multi-line comment — scan for closers
                    var i: usize = 0;
                    var in_string: u8 = 0;
                    while (i + 1 < trimmed.len) : (i += 1) {
                        const c = trimmed[i];
                        if (in_string != 0) {
                            if (c == '\\' and i + 1 < trimmed.len) {
                                i += 1;
                            } else if (c == in_string) {
                                in_string = 0;
                            }
                            continue;
                        }
                        if (c == '"' or c == '\'') {
                            in_string = c;
                            continue;
                        }
                        if (std.mem.startsWith(u8, trimmed[i..], "(*")) {
                            ocaml_comment_depth += 1;
                            i += 1;
                        } else if (std.mem.startsWith(u8, trimmed[i..], "*)")) {
                            if (ocaml_comment_depth > 0) ocaml_comment_depth -= 1;
                            i += 1;
                        }
                    }
                    if (ocaml_comment_depth > 0) continue;
                    // Depth reached zero mid-line — keep text after the last *)
                    // Find the last *) in the line
                    if (std.mem.lastIndexOf(u8, trimmed, "*)")) |close_pos| {
                        const after = std.mem.trimStart(u8, trimmed[close_pos + 2 ..], " \t");
                        if (after.len == 0) continue;
                        trimmed = after;
                    } else continue;
                } else {
                    // Not currently in a comment — scan for openers
                    var i: usize = 0;
                    var in_string: u8 = 0;
                    while (i + 1 < trimmed.len) : (i += 1) {
                        const c = trimmed[i];
                        if (in_string != 0) {
                            if (c == '\\' and i + 1 < trimmed.len) {
                                i += 1;
                            } else if (c == in_string) {
                                in_string = 0;
                            }
                            continue;
                        }
                        if (c == '"' or c == '\'') {
                            in_string = c;
                            continue;
                        }
                        if (std.mem.startsWith(u8, trimmed[i..], "(*")) {
                            ocaml_comment_depth += 1;
                            i += 1;
                        } else if (std.mem.startsWith(u8, trimmed[i..], "*)")) {
                            if (ocaml_comment_depth > 0) ocaml_comment_depth -= 1;
                            i += 1;
                        }
                    }
                    if (ocaml_comment_depth > 0) {
                        // Comment opened but not closed on this line.
                        // Check if there's material before the first (*.
                        if (std.mem.indexOf(u8, trimmed, "(*")) |open_pos| {
                            const before = std.mem.trimEnd(u8, trimmed[0..open_pos], " \t");
                            if (before.len == 0) continue;
                            trimmed = before;
                        } else continue;
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
            } else if (outline.language == .ocaml) {
                try parser.parseOcamlLine(trimmed, line_num, &outline);
            }

            prev_line_trimmed = trimmed;
        }
        outline.line_count = line_num;
        if (outline.language == .markdown) {
            const links = try markdown_graph.extract(parser.allocator, path, content);
            outline.document_links.appendSlice(parser.allocator, links) catch |err| {
                markdown_graph.freeLinks(parser.allocator, links);
                return err;
            };
            parser.allocator.free(links);
        }
        computeSymbolEnds(content, &outline);
        return outline;
    }

    pub fn parseContentForIndexing(allocator: std.mem.Allocator, path: []const u8, content: []const u8) !ParsedFile {
        // A parser shell only carries the allocator into the parse methods: a
        // 1-slot cache keeps the per-file cost flat, and OOM here must surface
        // as an error, not ContentCache.init's daemon-killing panic.
        var parser = try Explorer.initFallible(allocator, 1);
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

    /// Invalidate the searchContent result cache. Called by every mutation
    /// that can change what a search returns — file commits/removals, index
    /// rebuilds, and the one-shot lazy ranking-signal builds (symbol index,
    /// call graph, co-change). Atomic because the lazy builds run under the
    /// SHARED lock.
    ///
    /// Ordering invariant: never bump BEFORE a mutation outside the
    /// exclusive lock — a search could load the new generation, win the
    /// shared lock, and cache pre-mutation results under the post-mutation
    /// generation. Bump while holding the exclusive lock, or (for the lazy
    /// shared-lock builds) only after the mutation is visible.
    fn bumpSearchGen(self: *Explorer) void {
        _ = self.search_gen.fetchAdd(1, .release);
    }
    /// Remove every skip_trigram_files entry the current trigram index
    /// covers. Caller must hold the EXCLUSIVE lock. Snapshot restore parks
    /// every file in the skip set (#507/#537 — it cannot know what a disk
    /// trigram index covers), so without this reconciliation tier 3
    /// content-scans the ENTIRE project on each fall-through query even
    /// though the loaded index already answers for those files. Keys are
    /// borrowed from `outlines`, so removal never frees.
    fn pruneSkipTrigramLocked(self: *Explorer) void {
        var to_remove: std.ArrayList([]const u8) = .empty;
        defer to_remove.deinit(self.allocator);
        var it = self.skip_trigram_files.keyIterator();
        while (it.next()) |k| {
            if (self.trigram_index.containsFile(k.*)) to_remove.append(self.allocator, k.*) catch break;
        }
        for (to_remove.items) |k| _ = self.skip_trigram_files.remove(k);
    }

    /// Swap in a trigram index (disk mmap load / post-scan build) and
    /// reconcile the skip set with what it covers. Every external
    /// trigram_index replacement must go through here — a bare swap leaves
    /// stale skip_trigram_files entries (see pruneSkipTrigramLocked).
    pub fn adoptTrigramIndex(self: *Explorer, new_index: AnyTrigramIndex) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.bumpSearchGen();
        self.trigram_index.deinit();
        self.trigram_index = new_index;
        self.pruneSkipTrigramLocked();
    }

    /// Adopt a disk-loaded mmap trigram as the BASE index, keeping any files
    /// already trigram-indexed in the current heap index (snapshot freshness
    /// reindex touches changed files BEFORE the disk load runs) as a masked
    /// overlay so their newer content wins. Replaces the `fileCount() > 0`
    /// early-return that let a single reindexed file block the disk load
    /// entirely — leaving tier 3 to content-scan the whole project on every
    /// fall-through query.
    pub fn adoptTrigramBase(self: *Explorer, base: idx.MmapTrigramIndex) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.bumpSearchGen();
        switch (self.trigram_index) {
            .heap => |heap_copy| {
                if (heap_copy.fileCount() == 0) {
                    var old = heap_copy;
                    old.deinit();
                    self.trigram_index = .{ .mmap = base };
                } else {
                    self.trigram_index = .{ .mmap_overlay = .{
                        .base = base,
                        .overlay = heap_copy,
                        .masked = std.StringHashMap(void).init(self.allocator),
                    } };
                    var it = self.trigram_index.mmap_overlay.overlay.file_trigrams.keyIterator();
                    while (it.next()) |k| self.trigram_index.mmap_overlay.mask(k.*);
                }
            },
            .mmap, .mmap_overlay => {
                // Already disk-backed — nothing to gain from a second base.
                var dupe_base = base;
                dupe_base.deinit();
            },
        }
        self.pruneSkipTrigramLocked();
    }

    /// Rebuild trigram index from the stored file contents.
    /// Used after a cache hit to populate trigrams when they were skipped during the fast scan.
    pub fn rebuildTrigrams(self: *Explorer) !void {
        self.mu.lock();
        defer self.mu.unlock();
        self.bumpSearchGen();
        var iter = self.contents.iterator();
        while (iter.next()) |entry| {
            // Skip large files to prevent OOM on large repos
            if (entry.value_ptr.*.len > 1024 * 1024) continue;
            self.trigram_index.indexFile(entry.key_ptr.*, entry.value_ptr.*) catch |err| switch (err) {
                error.OutOfMemory => {
                    std.log.warn("trigram OOM, skipping remaining files", .{});
                    self.pruneSkipTrigramLocked();
                    return;
                },
            };
        }
        self.pruneSkipTrigramLocked();
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
            const canonical_root = self.root_path orelse return error.WordIndexIncomplete;
            for (paths) |path| {
                const content = try project_file.readAllocNoFollowAtRoot(io, dir, canonical_root, path, self.allocator, .limited(64 * 1024 * 1024));
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
        self.bumpSearchGen();
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

    /// Snapshot fast-load defers the global symbol index — plain content
    /// search never reads it, so one-shot CLI queries skip ~symbols-per-file
    /// map inserts and their heap (#564). rebuildSymbolIndexFor no-ops while
    /// incomplete; ensureSymbolIndex builds it on first symbol/caller use.
    pub fn markSymbolIndexIncomplete(self: *Explorer) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.symbol_index_complete = false;
    }

    /// Build the global symbol index from outlines if a snapshot fast-load
    /// deferred it (#564). Cheap when complete (one flag check). Mirrors the
    /// lazy word-index rebuild: call BEFORE taking the shared lock — this
    /// takes the exclusive lock itself.
    pub fn ensureSymbolIndex(self: *Explorer) void {
        self.mu.lockShared();
        const incomplete = !self.symbol_index_complete;
        self.mu.unlockShared();
        if (!incomplete) return;
        self.mu.lock();
        defer self.mu.unlock();
        if (self.symbol_index_complete) return;
        self.bumpSearchGen();
        // Rebuild from scratch: entries indexed BEFORE the index was marked
        // incomplete would otherwise be duplicated by the loop below (it
        // passes had_prior=false, which skips per-file eviction). The index
        // is authoritative once complete — lookups no longer outline-scan —
        // so it must hold exactly one entry per live symbol.
        var sym_iter = self.symbol_index.iterator();
        while (sym_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.symbol_index.clearRetainingCapacity();
        self.symbol_index_complete = true;
        var it = self.outlines.iterator();
        while (it.next()) |entry| {
            self.rebuildSymbolIndexFor(entry.key_ptr.*, entry.value_ptr, false);
        }
    }

    /// Free the NL→symbol bridge token cache. Caller holds the exclusive
    /// lock (or is deinit).
    fn clearDefTokenIndexLocked(self: *Explorer) void {
        var it = self.def_token_index.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.def_token_index.clearRetainingCapacity();
        for (self.def_token_names.items) |n| self.allocator.free(n);
        self.def_token_names.clearRetainingCapacity();
        self.def_token_gen = null;
    }

    /// Build the inverted split-name token index for the NL→symbol bridge if
    /// it is missing or from an older search generation. Cheap when fresh
    /// (one gen check). Call BEFORE taking the shared lock — this takes the
    /// exclusive lock itself (after ensureSymbolIndex). On mid-build OOM the
    /// generation stays unset and the bridge falls back to its direct sweep.
    pub fn ensureDefTokenIndex(self: *Explorer) void {
        self.ensureSymbolIndex();
        self.mu.lockShared();
        const fresh = self.def_token_gen != null and self.def_token_gen.? == self.search_gen.load(.acquire);
        self.mu.unlockShared();
        if (fresh) return;
        self.mu.lock();
        defer self.mu.unlock();
        const gen = self.search_gen.load(.acquire);
        if (self.def_token_gen != null and self.def_token_gen.? == gen) return;
        self.clearDefTokenIndexLocked();
        var split_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer split_arena.deinit();
        const sa = split_arena.allocator();
        var sym_it = self.symbol_index.iterator();
        while (sym_it.next()) |se| {
            const sym_name = se.key_ptr.*;
            if (sym_name.len < 5) continue;
            var subs: std.ArrayList([]const u8) = .empty;
            idx.splitIdentifier(sym_name, &subs, sa) catch continue;
            if (subs.items.len < 2) continue;
            const name_copy = self.allocator.dupe(u8, sym_name) catch return;
            const sym_id: u32 = @intCast(self.def_token_names.items.len);
            self.def_token_names.append(self.allocator, name_copy) catch {
                self.allocator.free(name_copy);
                return;
            };
            for (subs.items, 0..) |sub, i| {
                var dup = false;
                for (subs.items[0..i]) |prev| {
                    if (std.mem.eql(u8, prev, sub)) {
                        dup = true;
                        break;
                    }
                }
                if (dup) continue;
                if (self.def_token_index.getPtr(sub)) |list| {
                    list.append(self.allocator, sym_id) catch return;
                } else {
                    const key_copy = self.allocator.dupe(u8, sub) catch return;
                    var list: std.ArrayList(u32) = .empty;
                    list.append(self.allocator, sym_id) catch {
                        self.allocator.free(key_copy);
                        return;
                    };
                    self.def_token_index.put(key_copy, list) catch {
                        self.allocator.free(key_copy);
                        var l = list;
                        l.deinit(self.allocator);
                        return;
                    };
                }
            }
        }
        self.def_token_gen = gen;
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
        self.bumpSearchGen();
        if (!self.word_index_complete) {
            self.word_index_can_load_from_disk = false;
        } else {
            self.word_index_generation +%= 1;
        }
        self.dep_graph.remove(path);
        self.document_graph.remove(path);
        self.removeSymbolIndexFor(path);
        _ = self.skip_trigram_files.remove(path);
        self.contents.remove(path);
        self.content_hashes.invalidate(path);
        self.line_offsets.invalidate(path);
        self.word_index.removeFile(path);
        self.trigram_index.removeFile(path);

        if (self.outlines.fetchRemove(path)) |kv| {
            const removed_markdown = kv.value.language == .markdown;
            var outline = kv.value;
            outline.deinit();
            if (removed_markdown) self.refreshDocumentLinksTo(kv.key) catch {};
            self.allocator.free(kv.key);
        }
    }

    pub fn getOutline(self: *Explorer, path: []const u8, allocator: std.mem.Allocator) !?FileOutline {
        self.mu.lockShared();
        defer self.mu.unlockShared();

        const outline = self.outlines.getPtr(path) orelse return null;
        return try cloneOutline(outline, allocator);
    }

    /// Return the live indexed line count without cloning the outline. This is
    /// used to validate untrusted semantic sidecar ranges before they become
    /// retrieval hits.
    pub fn outlineLineCount(self: *Explorer, path: []const u8) ?u32 {
        self.mu.lockShared();
        defer self.mu.unlockShared();
        const outline = self.outlines.getPtr(path) orelse return null;
        return outline.line_count;
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

        const gen = self.search_gen.load(.acquire);
        if (self.outline_render_cache.render(path, compact, gen, alloc, out)) return true;
        const render_start = out.items.len;

        const outline = self.outlines.getPtr(path) orelse return false;
        try out.ensureUnusedCapacity(alloc, 128 + outline.symbols.items.len * 128);
        const w = cio.listWriter(out, alloc);
        w.print("{s} ({s}, {d} lines)\n", .{
            outline.path, @tagName(outline.language), outline.line_count,
        }) catch {};
        // Consecutive imports collapse into one summary line: each import used
        // to print as `L5: import import collections` (kind tag + verbatim
        // statement, ~26% of outline bytes on import-heavy files) and import
        // lines are never call/edit targets — the line numbers carry no value.
        const syms = outline.symbols.items;
        var i: usize = 0;
        while (i < syms.len) {
            const sym = syms[i];
            if (sym.kind == .import) {
                var count: usize = 0;
                var names_len: usize = 0;
                var truncated = false;
                var first = true;
                w.writeAll("  imports: ") catch {};
                while (i < syms.len and syms[i].kind == .import) : (i += 1) {
                    count += 1;
                    if (names_len > 160) {
                        truncated = true;
                        continue;
                    }
                    if (!first) {
                        w.writeAll(", ") catch {};
                        names_len += 2;
                    }
                    first = false;
                    w.writeAll(syms[i].name) catch {};
                    names_len += syms[i].name.len;
                }
                if (truncated) w.writeAll(", …") catch {};
                w.print("  (x{d})\n", .{count}) catch {};
                continue;
            }
            if (compact) {
                w.print("  L{d}: {s} {s}\n", .{ sym.line_start, @tagName(sym.kind), sym.name }) catch {};
            } else {
                w.print("  L{d}: {s} {s}", .{ sym.line_start, @tagName(sym.kind), sym.name }) catch {};
                if (sym.detail) |d| w.print("  // {s}", .{d}) catch {};
                w.writeAll("\n") catch {};
            }
            i += 1;
        }
        self.outline_render_cache.put(path, compact, gen, out.items[render_start..]);
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

    /// Whether the current project index already contains this relative path.
    /// This is intentionally metadata-only: direct reads still validate the
    /// live file handle before serving cached bytes.
    pub fn hasIndexedPath(self: *Explorer, path: []const u8) bool {
        self.mu.lockShared();
        defer self.mu.unlockShared();
        return self.outlines.contains(path);
    }

    pub const LineSpan = LineOffsetCache.Span;

    /// Borrow the canonical cached bytes for `path`. Caller must hold `mu`
    /// (shared) — the slice is only valid while the lock is held.
    pub fn cachedContentLocked(self: *Explorer, path: []const u8) ?[]const u8 {
        return self.contents.get(path);
    }

    /// Resolve 1-based `target_lines` of `path` to byte spans in `content`
    /// via the line-offset cache (#611). Pass the canonical cached bytes
    /// (stable pointer) so the table survives across calls. Returns the
    /// filled count, or null when the table can't be built (OOM) — callers
    /// fall back to scanning.
    pub fn lineSpansFor(self: *Explorer, path: []const u8, content: []const u8, target_lines: []const u32, spans: []LineSpan) ?usize {
        return self.line_offsets.lineSpans(path, content, target_lines, spans);
    }

    /// Append a contiguous line range without copying cached content or scanning
    /// from byte zero. A cache miss retains the prior disk-read fallback.
    pub fn appendLineRange(self: *Explorer, path: []const u8, start: u32, end: u32, line_prefix: []const u8, allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !bool {
        self.mu.lockShared();
        defer self.mu.unlockShared();
        const content_ref = self.readContentForSearch(path, allocator) orelse return false;
        defer content_ref.deinit();
        if (content_ref.owned) {
            try appendExtractedLines(content_ref.data, start, end, true, false, .unknown, line_prefix, allocator, out);
            return true;
        }
        return self.line_offsets.appendRange(path, content_ref.data, start, end, false, .unknown, line_prefix, allocator, out);
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
        if (!project_file.isAllowedPath(path)) return false;
        self.mu.lockShared();
        defer self.mu.unlockShared();

        const content_ref = self.contents.getWithGeneration(path) orelse return false;
        const hash = self.content_hashes.get(path, content_ref.value, content_ref.generation, content_ref.value_owned);
        try self.renderReadBytes(path, content_ref.value, hash, allocator, out, opts);
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
        if (!project_file.isAllowedPath(path)) return null;
        if (self.contents.get(path)) |cached| {
            return .{ .data = cached, .owned = false, .allocator = allocator };
        }
        if (builtin.os.tag == .freestanding) return null;
        const io = self.io orelse return null;
        const dir = self.root_dir orelse return null;
        const canonical_root = self.root_path orelse return null;
        const data = project_file.readAllocNoFollowAtRoot(io, dir, canonical_root, path, allocator, .limited(64 * 1024 * 1024)) catch return null;
        return .{ .data = data, .owned = true, .allocator = allocator };
    }

    /// Issue #626: nudge agents toward codedb_outline when they pull a whole
    /// large file with no range — the grep+cat habit reads entire files and
    /// burns tokens. Returns a static one-liner, or null for small files.
    pub fn fullFileReadHint(content: []const u8) ?[]const u8 {
        var lines: usize = 1;
        for (content) |c| {
            if (c == '\n') lines += 1;
        }
        if (lines < 400) return null;
        return "↪ whole-file read: codedb_outline maps this file 4-15x smaller — get the structure, pick a line range, then codedb_read just that range.\n";
    }

    /// Token guard for rangeless full-file reads: past a point a whole-file
    /// dump is never the right payload — tool results persist in the agent
    /// transcript and re-bill on every subsequent model call (a 150 KB dump
    /// costs ~37k tokens × the rest of the session). Cap only pathological
    /// dumps (64 KB ≈ 1,500 lines) — tighter caps measurably backfire: agents
    /// route around the tool and burn far more on extra round-trips.
    pub const full_read_cap = 64 * 1024;

    pub fn appendCappedFullFile(allocator: std.mem.Allocator, out: *std.ArrayList(u8), content: []const u8) !void {
        if (content.len <= full_read_cap) {
            try out.appendSlice(allocator, content);
            return;
        }
        try out.appendSlice(allocator, content[0..full_read_cap]);
        var elided: usize = 0;
        for (content[full_read_cap..]) |ch| {
            if (ch == '\n') elided += 1;
        }
        const w = cio.listWriter(out, allocator);
        try w.print("\n… [{d} more lines elided ({d} bytes total) — run codedb_outline on this file, then codedb_read with line_start/line_end for the slice you need]\n", .{ elided, content.len });
    }

    fn renderReadBytes(
        self: *Explorer,
        path: []const u8,
        content: []const u8,
        hash: u64,
        allocator: std.mem.Allocator,
        out: *std.ArrayList(u8),
        opts: ReadRenderOptions,
    ) !void {
        const probe_len = @min(content.len, 8 * 1024);
        if (std.mem.indexOfScalar(u8, content[0..probe_len], 0) != null) {
            const w0 = cio.listWriter(out, allocator);
            try w0.print("binary file: {d} bytes  hash:{x}\n", .{ content.len, hash });
            return;
        }

        try out.ensureUnusedCapacity(allocator, if (opts.line_start != null or opts.line_end != null or opts.compact) 2048 else @min(content.len + 64, 64 * 1024));
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
            if (!try self.line_offsets.appendRange(path, content, start, end, opts.compact, lang, "", allocator, out)) {
                try appendExtractedLines(content, start, end, true, opts.compact, lang, "", allocator, out);
            }
        } else {
            if (fullFileReadHint(content)) |hint| try out.appendSlice(allocator, hint);
            try appendCappedFullFile(allocator, out, content);
        }
    }

    pub fn cloneOutline(src: *const FileOutline, allocator: std.mem.Allocator) !FileOutline {
        return cloneOutlineImpl(src, allocator, true);
    }

    /// Deep-copy an outline's symbols/imports while borrowing its path. This is
    /// useful when the caller will immediately rebind the clone to a stable path,
    /// avoiding an allocate/copy/free cycle for the temporary path.
    pub fn cloneOutlineBorrowingPath(src: *const FileOutline, allocator: std.mem.Allocator) !FileOutline {
        return cloneOutlineImpl(src, allocator, false);
    }

    /// Deep-copy an outline into exact-sized arrays plus one packed allocation
    /// for all symbol/import strings. The resulting path is borrowed. This keeps
    /// cross-thread malloc traffic bounded to at most three allocations per file.
    pub fn cloneOutlinePackedBorrowingPath(src: *const FileOutline, allocator: std.mem.Allocator) !FileOutline {
        var string_bytes: usize = 0;
        for (src.symbols.items) |sym| {
            if (sym.name.len > std.math.maxInt(usize) - string_bytes) return error.OutOfMemory;
            string_bytes += sym.name.len;
            if (sym.detail) |detail| {
                if (detail.len > std.math.maxInt(usize) - string_bytes) return error.OutOfMemory;
                string_bytes += detail.len;
            }
        }
        for (src.imports.items) |imp| {
            if (imp.len > std.math.maxInt(usize) - string_bytes) return error.OutOfMemory;
            string_bytes += imp.len;
        }
        for (src.document_links.items) |link| {
            if (link.target.len > std.math.maxInt(usize) - string_bytes) return error.OutOfMemory;
            string_bytes += link.target.len;
        }

        var dst = FileOutline.init(allocator, src.path);
        errdefer dst.deinit();
        dst.language = src.language;
        dst.line_count = src.line_count;
        dst.byte_size = src.byte_size;
        dst.name_len_mask = src.name_len_mask;
        dst.path_class = src.path_class;

        const storage = try allocator.alloc(u8, string_bytes);
        dst.owned_string_storage = storage;
        dst.borrows_strings = true;
        try dst.symbols.ensureTotalCapacity(allocator, src.symbols.items.len);
        try dst.imports.ensureTotalCapacity(allocator, src.imports.items.len);
        try dst.document_links.ensureTotalCapacity(allocator, src.document_links.items.len);

        var cursor: usize = 0;
        for (src.symbols.items) |sym| {
            const copied_name = storage[cursor .. cursor + sym.name.len];
            @memcpy(copied_name, sym.name);
            cursor += sym.name.len;
            const copied_detail: ?[]const u8 = if (sym.detail) |detail| blk: {
                const copied = storage[cursor .. cursor + detail.len];
                @memcpy(copied, detail);
                cursor += detail.len;
                break :blk copied;
            } else null;
            dst.symbols.appendAssumeCapacity(.{
                .name = copied_name,
                .kind = sym.kind,
                .line_start = sym.line_start,
                .line_end = sym.line_end,
                .detail = copied_detail,
            });
        }
        for (src.imports.items) |imp| {
            const copied_import = storage[cursor .. cursor + imp.len];
            @memcpy(copied_import, imp);
            cursor += imp.len;
            dst.imports.appendAssumeCapacity(copied_import);
        }
        for (src.document_links.items) |link| {
            const copied_target = storage[cursor .. cursor + link.target.len];
            @memcpy(copied_target, link.target);
            cursor += link.target.len;
            dst.document_links.appendAssumeCapacity(.{ .target = copied_target, .kind = link.kind });
        }
        std.debug.assert(cursor == string_bytes);
        return dst;
    }

    fn cloneOutlineImpl(src: *const FileOutline, allocator: std.mem.Allocator, copy_path: bool) !FileOutline {
        var dst = FileOutline.init(allocator, src.path);
        errdefer dst.deinit();
        if (copy_path) {
            dst.path = try allocator.dupe(u8, src.path);
            dst.owns_path = true;
        }
        dst.language = src.language;
        dst.line_count = src.line_count;
        dst.byte_size = src.byte_size;
        dst.name_len_mask = src.name_len_mask;
        dst.path_class = src.path_class;

        try dst.symbols.ensureTotalCapacity(allocator, src.symbols.items.len);
        try dst.imports.ensureTotalCapacity(allocator, src.imports.items.len);
        try dst.document_links.ensureTotalCapacity(allocator, src.document_links.items.len);
        for (src.symbols.items) |sym| {
            const copied_name = try allocator.dupe(u8, sym.name);
            errdefer allocator.free(copied_name);

            const copied_detail = if (sym.detail) |d| blk: {
                const detail = try allocator.dupe(u8, d);
                break :blk detail;
            } else null;
            errdefer if (copied_detail) |d| allocator.free(d);

            dst.symbols.appendAssumeCapacity(.{
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
            dst.imports.appendAssumeCapacity(copied_import);
        }
        for (src.document_links.items) |link| {
            const copied_target = try allocator.dupe(u8, link.target);
            errdefer allocator.free(copied_target);
            dst.document_links.appendAssumeCapacity(.{ .target = copied_target, .kind = link.kind });
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
        self.mu.lockShared();
        defer self.mu.unlockShared();

        const gen = self.search_gen.load(.acquire);
        if (self.tree_render_cache.render(gen, use_color, allocator, out)) return;
        const render_start = out.items.len;
        const s = @import("style.zig").style(use_color);

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

        // Token guard (two-pass): files with no symbols and dot-paths are pure
        // noise for agents — measured 86% of tree bytes on a large repo
        // (174 KB, of which 150 KB is 0-symbol files under .graff/, docs/,
        // fixtures). Filter them, keep one summary line for discoverability.
        // If the repo has NOTHING but such files (docs-only), show everything
        // rather than an empty tree.
        var keep = std.ArrayList(bool).empty;
        defer keep.deinit(allocator);
        var kept_dirs = std.StringHashMap(void).init(allocator);
        defer kept_dirs.deinit();
        var shown: usize = 0;
        for (paths.items) |path| {
            const outline = self.outlines.get(path) orelse {
                try keep.append(allocator, false);
                continue;
            };
            const dotpath = path[0] == '.' or std.mem.indexOf(u8, path, "/.") != null;
            const k = !dotpath and outline.symbols.items.len > 0;
            try keep.append(allocator, k);
            if (k) {
                shown += 1;
                var prefix_end: usize = 0;
                while (std.mem.indexOfScalarPos(u8, path, prefix_end, '/')) |sep| {
                    try kept_dirs.put(path[0 .. sep + 1], {});
                    prefix_end = sep + 1;
                }
            }
        }
        const filter_active = shown > 0;
        var omitted: usize = 0;

        for (paths.items, 0..) |path, pi| {
            const outline = self.outlines.get(path) orelse continue;
            if (filter_active and !keep.items[pi]) {
                omitted += 1;
                continue;
            }

            // Emit directory nodes we haven't seen yet
            var prefix_end: usize = 0;
            while (std.mem.indexOfScalarPos(u8, path, prefix_end, '/')) |sep| {
                const dir = path[0 .. sep + 1];
                if (filter_active and !kept_dirs.contains(dir)) {
                    prefix_end = sep + 1;
                    continue;
                }
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
        if (filter_active and omitted > 0) {
            try writer.print("{s}… +{d} non-code files omitted (no symbols or dotfiles){s}\n", .{ s.dim, omitted, s.reset });
        }
        self.tree_render_cache.put(gen, use_color, out.items[render_start..]);
    }

    pub fn findSymbol(self: *Explorer, name: []const u8, allocator: std.mem.Allocator) !?struct { path: []const u8, symbol: Symbol } {
        self.ensureSymbolIndex();
        self.mu.lockShared();
        defer self.mu.unlockShared();

        // O(1) lookup via symbol_index
        if (self.symbol_index.get(name)) |locs| {
            if (locs.items.len > 0) {
                // The hash lookup is O(1); choose deterministically among the
                // definitions of this name instead of inheriting scan/commit
                // order from the symbol-index append list. This is O(k) in the
                // number of exact-name collisions, never O(all symbols).
                var loc = locs.items[0];
                for (locs.items[1..]) |candidate| {
                    if (symbolNavigationLocationBefore(name, candidate, loc)) loc = candidate;
                }
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

        // Fallback: scan outlines, only while the symbol index is incomplete
        // (see findAllSymbols for the invariant). When complete, a miss in
        // the index IS the answer — the scan was an O(files × symbols) "no"
        // on every missing-symbol lookup.
        if (!self.symbol_index_complete) {
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
        }
        return null;
    }

    pub fn findAllSymbols(self: *Explorer, name: []const u8, allocator: std.mem.Allocator) ![]const SymbolResult {
        self.ensureSymbolIndex();
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

        // Safety scan: append any outline symbols the index missed. Only
        // needed while the index is incomplete (fast-snapshot restore marks
        // it so; ensureSymbolIndex above normally rebuilds it first) — when
        // complete, commits (rebuildSymbolIndexFor) and removals
        // (removeSymbolIndexFor) keep it authoritative, and this scan is
        // O(files × symbols) of pure overhead (~6ms on a 20k-file corpus).
        if (!self.symbol_index_complete) {
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
        rank_policy: SymbolRankPolicy = .structural,
    };

    pub const SymbolRankPolicy = enum {
        /// Stable low-level order: match score, name, path, line.
        structural,
        /// Opinionated navigation order for resolving an exact common name.
        navigation,
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
        self.ensureSymbolIndex();
        self.mu.lockShared();
        defer self.mu.unlockShared();

        const Candidate = struct {
            path: []const u8,
            symbol: Symbol,
            score: f32,
            navigation_priority: i32,
        };

        var candidates: std.ArrayList(Candidate) = .empty;
        defer candidates.deinit(allocator);

        const Dedup = struct {
            fn contains(items: []const Candidate, path: []const u8, line: u32) bool {
                for (items) |r| {
                    if (r.symbol.line_start == line and std.mem.eql(u8, r.path, path)) return true;
                }
                return false;
            }
        };

        const SortCtx = struct {
            // Total order: score desc, optional navigation priority, then name,
            // path, line. line_start is the final tiebreak — without it,
            // same-name symbols in one file compared equal and their order fell
            // out of hash-map iteration.
            pub fn lessThan(_: void, a: Candidate, b: Candidate) bool {
                if (a.score != b.score) return a.score > b.score;
                if (a.navigation_priority != b.navigation_priority) return a.navigation_priority > b.navigation_priority;
                const name_cmp = std.mem.order(u8, a.symbol.name, b.symbol.name);
                if (name_cmp != .eq) return name_cmp == .lt;
                const path_cmp = std.mem.order(u8, a.path, b.path);
                if (path_cmp != .eq) return path_cmp == .lt;
                return a.symbol.line_start < b.symbol.line_start;
            }

            fn candidateBefore(a: Candidate, b: Candidate) bool {
                return lessThan({}, a, b);
            }
        };

        const freeOne = struct {
            fn call(alloc: std.mem.Allocator, r: ScoredSymbolResult) void {
                alloc.free(r.path);
                alloc.free(r.symbol.name);
                if (r.symbol.detail) |d| alloc.free(d);
            }
        }.call;

        const cloneOne = struct {
            fn call(alloc: std.mem.Allocator, candidate: Candidate) !ScoredSymbolResult {
                const path_copy = try alloc.dupe(u8, candidate.path);
                errdefer alloc.free(path_copy);
                const name_copy = try alloc.dupe(u8, candidate.symbol.name);
                errdefer alloc.free(name_copy);
                var detail_copy: ?[]u8 = null;
                errdefer if (detail_copy) |d| alloc.free(d);
                if (candidate.symbol.detail) |d| {
                    detail_copy = try alloc.dupe(u8, d);
                }
                return .{
                    .path = path_copy,
                    .symbol = .{
                        .name = name_copy,
                        .kind = candidate.symbol.kind,
                        .line_start = candidate.symbol.line_start,
                        .line_end = candidate.symbol.line_end,
                        .detail = detail_copy,
                    },
                    .score = candidate.score,
                };
            }
        }.call;

        const appendOne = struct {
            fn call(
                list_ptr: *std.ArrayList(Candidate),
                alloc: std.mem.Allocator,
                max_results: usize,
                path: []const u8,
                sym: Symbol,
                score: f32,
                rank_policy: SymbolRankPolicy,
            ) !void {
                if (max_results == 0) return;
                if (Dedup.contains(list_ptr.items, path, sym.line_start)) return;
                const candidate: Candidate = .{
                    .path = path,
                    .symbol = sym,
                    .score = score,
                    .navigation_priority = if (rank_policy == .navigation)
                        symbolNavigationPriority(sym.name, path, sym.kind)
                    else
                        0,
                };
                if (list_ptr.items.len >= max_results and
                    !SortCtx.candidateBefore(candidate, list_ptr.items[list_ptr.items.len - 1]))
                {
                    return;
                }

                // The list is kept sorted at all times, so placing the new
                // candidate is a binary search + insert (O(log K) compares +
                // O(K) moves) instead of the previous full re-sort per
                // accepted insert (O(K log K) compares). Ties are impossible:
                // the sort key ends in (path, line) and same-(path, line)
                // candidates are deduped above.
                var lo: usize = 0;
                var hi: usize = list_ptr.items.len;
                while (lo < hi) {
                    const mid = lo + (hi - lo) / 2;
                    if (SortCtx.candidateBefore(candidate, list_ptr.items[mid])) {
                        hi = mid;
                    } else {
                        lo = mid + 1;
                    }
                }
                if (list_ptr.items.len >= max_results) {
                    _ = list_ptr.pop();
                }
                try list_ptr.insert(alloc, lo, candidate);
            }
        }.call;

        if (spec.fuzzy and spec.name != null) {
            const q = spec.name.?;
            if (q.len > 0 and q.len <= FUZZY_MAX_QUERY) {
                const FuzzCand = struct {
                    name: []const u8,
                    locs: []const SymbolLocation,
                };
                var fuzz_cands: std.ArrayList(FuzzCand) = .empty;
                defer fuzz_cands.deinit(allocator);
                var sym_iter = self.symbol_index.iterator();
                while (sym_iter.next()) |entry| {
                    const sym_name = entry.key_ptr.*;
                    if (sym_name.len == 0 or sym_name.len > FUZZY_MAX_PATH) continue;
                    if (fuzzyPresenceReject(q, sym_name)) continue;
                    try fuzz_cands.append(allocator, .{ .name = sym_name, .locs = entry.value_ptr.items });
                }
                var off: usize = 0;
                while (off < fuzz_cands.items.len) : (off += FZ_LANES) {
                    const slab = fuzz_cands.items[off..@min(off + FZ_LANES, fuzz_cands.items.len)];
                    var names: [FZ_LANES][]const u8 = undefined;
                    for (slab, 0..) |fc, l| names[l] = fc.name;
                    var best: [FZ_LANES]f32 = undefined;
                    var matched: [FZ_LANES]u32 = undefined;
                    fuzzyScoreBatch(q, names[0..slab.len], &best, &matched);
                    for (slab, 0..) |fc, l| {
                        const score = fuzzyFinalize(q, fc.name, best[l], matched[l]) orelse continue;
                        for (fc.locs) |loc| {
                            if (spec.kind) |k| if (loc.kind != k) continue;
                            var detail: ?[]const u8 = null;
                            if (self.outlines.getPtr(loc.path)) |outline| {
                                for (outline.symbols.items) |sym| {
                                    if (sym.line_start == loc.line_start and std.mem.eql(u8, sym.name, fc.name)) {
                                        detail = sym.detail;
                                        break;
                                    }
                                }
                            }
                            try appendOne(&candidates, allocator, spec.max_results, loc.path, .{
                                .name = fc.name,
                                .kind = loc.kind,
                                .line_start = loc.line_start,
                                .line_end = loc.line_end,
                                .detail = detail,
                            }, score, spec.rank_policy);
                        }
                    }
                }
            }
        } else if (spec.name != null and spec.prefix == null and spec.pattern == null) {
            // Exact names are already hash-indexed. Avoid scanning and scoring
            // every distinct symbol name for the overwhelmingly common MCP form
            // `{ "name": "..." }`. Opinionated navigation suppresses
            // import/comment rows when at least one real definition exists;
            // structural codedb_symbol order and membership stay unchanged.
            const sym_name = spec.name.?;
            if (self.symbol_index.get(sym_name)) |locs| {
                var has_navigation_def = false;
                if (spec.rank_policy == .navigation) {
                    for (locs.items) |loc| {
                        if (loc.kind != .import and loc.kind != .comment_block) {
                            has_navigation_def = true;
                            break;
                        }
                    }
                }
                for (locs.items) |loc| {
                    if (spec.kind) |k| if (loc.kind != k) continue;
                    if (has_navigation_def and (loc.kind == .import or loc.kind == .comment_block)) continue;
                    var detail: ?[]const u8 = null;
                    if (self.outlines.getPtr(loc.path)) |outline| {
                        for (outline.symbols.items) |sym| {
                            if (sym.line_start == loc.line_start and std.mem.eql(u8, sym.name, sym_name)) {
                                detail = sym.detail;
                                break;
                            }
                        }
                    }
                    try appendOne(&candidates, allocator, spec.max_results, loc.path, .{
                        .name = sym_name,
                        .kind = loc.kind,
                        .line_start = loc.line_start,
                        .line_end = loc.line_end,
                        .detail = detail,
                    }, 1.0, spec.rank_policy);
                }
            }
        } else {
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
                    try appendOne(&candidates, allocator, spec.max_results, loc.path, .{
                        .name = sym_name,
                        .kind = loc.kind,
                        .line_start = loc.line_start,
                        .line_end = loc.line_end,
                        .detail = detail,
                    }, score, spec.rank_policy);
                }
            }
        }

        if (!self.symbol_index_complete) {
            var ol_iter = self.outlines.iterator();
            while (ol_iter.next()) |entry| {
                for (entry.value_ptr.symbols.items) |sym| {
                    const score = symbolMatchScore(spec, sym.name) orelse continue;
                    if (spec.kind) |k| if (sym.kind != k) continue;
                    if (Dedup.contains(candidates.items, entry.key_ptr.*, sym.line_start)) continue;
                    try appendOne(&candidates, allocator, spec.max_results, entry.key_ptr.*, sym, score, spec.rank_policy);
                }
            }
        }

        // candidates is kept sorted by appendOne — no final sort needed.
        const results = try allocator.alloc(ScoredSymbolResult, candidates.items.len);
        errdefer allocator.free(results);
        var result_len: usize = 0;
        errdefer {
            for (results[0..result_len]) |r| freeOne(allocator, r);
        }
        for (candidates.items) |candidate| {
            results[result_len] = try cloneOne(allocator, candidate);
            result_len += 1;
        }
        return results;
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
        std.mem.sort(SymbolResult, @constCast(results), {}, struct {
            fn lessThan(_: void, a: SymbolResult, b: SymbolResult) bool {
                return symbolNavigationResultBefore(a, b);
            }
        }.lessThan);
        var has_def = false;
        for (results) |r| {
            if (r.symbol.kind != .import and r.symbol.kind != .comment_block) {
                has_def = true;
                break;
            }
        }
        var total: usize = 0;
        for (results) |r| {
            const is_def = r.symbol.kind != .import and r.symbol.kind != .comment_block;
            if (!has_def or is_def) total += 1;
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
        if (total > n) {
            var tb: [128]u8 = undefined;
            out.appendSlice(allocator, std.fmt.bufPrint(&tb, "… {d} more exact symbol matches truncated (raise max_results or use codedb_symbol)\n", .{total - n}) catch return n > 0) catch {};
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
        self.ensureSymbolIndex();
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
        for (callees) |callee| {
            const name = callee.name;
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
            "init",   "deinit",   "append",   "get",          "set",
            "put",    "getOrPut", "remove",   "contains",     "has",
            "count",  "len",      "items",    "alloc",        "free",
            "create", "destroy",  "lock",     "unlock",       "tryLock",
            "next",   "iterator", "clone",    "dupe",         "slice",
            "reset",  "clear",    "format",   "hash",         "eql",
            "write",  "writeAll", "print",    "read",         "close",
            "open",   "value",    "key",      "toOwnedSlice", "pop",
            "push",   "find",     "add",      "new",          "build",
            "run",    "deinit",   "toString", "valueOf",      "of",
        };
        for (common) |c| if (std.mem.eql(u8, name, c)) return true;
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
        self.ensureSymbolIndex();
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
        // Safety scans (count + render below) are only needed while the
        // symbol index is incomplete — see findAllSymbols for the invariant.
        // When complete they were two O(files × symbols) passes per call.
        const scan_outlines = !self.symbol_index_complete;

        var total: usize = indexed_locs.len;
        if (scan_outlines) {
            var count_iter = self.outlines.iterator();
            while (count_iter.next()) |entry| {
                for (entry.value_ptr.symbols.items) |sym| {
                    if (!std.mem.eql(u8, sym.name, name)) continue;
                    if (LocLookup.contains(indexed_locs, entry.key_ptr.*, sym.line_start)) continue;
                    total += 1;
                }
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

        if (scan_outlines) {
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
        }
        return true;
    }

    pub fn searchContent(self: *Explorer, query: []const u8, allocator: std.mem.Allocator, max_results: usize) ![]const SearchResult {
        // Result-cache front door: a hit copies the cached results into the
        // caller's allocator (same ownership contract as a fresh search).
        // The generation is read BEFORE the search runs, so any concurrent
        // mutation makes the stored entry stale immediately — conservative
        // in the safe direction. Lazy builds during a query's FIRST run bump
        // the generation mid-search; that entry just never hits and the next
        // run stores a valid one.
        const cacheable = max_results > 0 and query.len > 0 and query.len <= 1024 and
            cio.posixGetenv("CODEDB_NO_SEARCH_CACHE") == null;
        if (!cacheable) return self.searchContentUncached(query, allocator, max_results);
        const gen = self.search_gen.load(.acquire);
        const env_fp = rankingEnvFingerprint();
        if (self.search_cache.get(query, max_results, gen, env_fp, allocator, &self.last_search_breakdown)) |hit| return hit;
        const res = try self.searchContentUncached(query, allocator, max_results);
        self.search_cache.put(query, max_results, gen, env_fp, res, self.last_search_breakdown);
        return res;
    }

    fn searchContentUncached(self: *Explorer, query: []const u8, allocator: std.mem.Allocator, max_results: usize) ![]const SearchResult {
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
        // #550: the graph-distance gate in rerankAndFinalize reads
        // symbol_index, which a snapshot fast-load defers (#564). Identifier-
        // shaped queries ensure it here, pre-shared-lock — ensureSymbolIndex
        // takes the exclusive lock itself.
        if (max_results > 0 and queryNamesIdentifier(query) and
            cio.posixGetenv("CODEDB_NO_CENTRALITY") == null and
            cio.posixGetenv("CODEDB_NO_GRAPH_DISTANCE") == null)
        {
            self.ensureSymbolIndex();
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
        // file cannot saturate the quota. Files that DEFINE a symbol named by
        // the query are considered first (#546: mention-dense test files used
        // to eat the whole file budget, so the defining file never even became
        // a candidate for the reranker), then code before docs, then files
        // with more exact word hits so popular identifiers and skip-trigram
        // canonical files are not hidden behind low-signal posting entries.
        const t0_start = cio.nanoTimestamp();
        const word_hits = self.word_index.search(query);
        if (word_hits.len > 0) {
            const Tier0File = struct {
                path: []const u8,
                doc_id: u32,
                count: u32,
                first_seen: usize,
                // One past the ordinal of this file's last hit. Together with
                // first_seen it bounds the file's posting run, so per-file
                // target-line collection slices word_hits[first_seen..hits_end]
                // instead of filtering the whole hit list per file. The
                // doc_id filter stays, so the bounds are correct even if a
                // file's hits were ever non-contiguous.
                hits_end: usize,
                is_doc: bool,
                defines: bool,
            };

            // Candidates append straight into this array; deduplication maps
            // doc_id → array index. Small doc tables get a direct-address
            // slot array (one indexed load per lookup, no hashing at all);
            // big tables — or queries too small to amortize the memset —
            // fall back to a u32-keyed hash map. SLOT_NONE = unseen,
            // SLOT_INVALID = doc checked and skipped (freed doc_id slot).
            var tier0_files: std.ArrayList(Tier0File) = .empty;
            defer tier0_files.deinit(allocator);
            try tier0_files.ensureTotalCapacity(allocator, @min(word_hits.len, 1024));

            const SLOT_NONE = std.math.maxInt(u32);
            const SLOT_INVALID = SLOT_NONE - 1;
            const ndocs = self.word_index.id_to_path.items.len;

            // Fresh and persisted indexes keep postings in nondecreasing doc-id
            // order, which guarantees one contiguous run per document. That is
            // the overwhelmingly common read path, so avoid allocating and
            // populating a dedup table for it. Incremental swap-removal from an
            // older/mutated index can fragment a document into multiple runs;
            // detect any ordering break and retain the defensive table below.
            var postings_grouped = true;
            var previous_doc = word_hits[0].doc_id;
            for (word_hits[1..]) |hit| {
                if (hit.doc_id < previous_doc) {
                    postings_grouped = false;
                    break;
                }
                previous_doc = hit.doc_id;
            }

            const use_slots = !postings_grouped and ndocs > 0 and (ndocs <= 4096 or (ndocs <= 65536 and word_hits.len >= 512));
            var slots: []u32 = &.{};
            defer if (slots.len > 0) allocator.free(slots);
            var idx_by_doc = std.AutoHashMap(u32, u32).init(allocator);
            defer idx_by_doc.deinit();
            if (use_slots) {
                slots = try allocator.alloc(u32, ndocs);
                @memset(slots, SLOT_NONE);
            } else if (!postings_grouped) {
                idx_by_doc.ensureTotalCapacity(@intCast(@min(word_hits.len, 1024))) catch {};
            }

            // Postings for one file are appended contiguously (indexFile
            // processes whole files), so the hit list decomposes into runs of
            // one doc_id each — group run-at-a-time: scan to the run boundary
            // first, then touch the slot table and the entry ONCE per run
            // instead of once per hit. Indices (not pointers) into
            // tier0_files stay valid across array growth.
            var run_start: usize = 0;
            while (run_start < word_hits.len) {
                const doc_id = word_hits[run_start].doc_id;
                var run_end = run_start + 1;
                while (run_end < word_hits.len and word_hits[run_end].doc_id == doc_id) run_end += 1;
                defer run_start = run_end;

                var cur: u32 = blk: {
                    if (postings_grouped) break :blk SLOT_NONE;
                    if (use_slots) {
                        if (doc_id >= ndocs) break :blk SLOT_INVALID;
                        break :blk slots[doc_id];
                    }
                    break :blk idx_by_doc.get(doc_id) orelse SLOT_NONE;
                };
                if (cur == SLOT_NONE) {
                    const hit_path = self.word_index.hitPath(word_hits[run_start]);
                    if (hit_path.len == 0) {
                        cur = SLOT_INVALID;
                    } else {
                        // One outline fetch serves both signals: language is
                        // detectLanguage(path) computed at outline init, and
                        // the defines scan is gated by the symbol-name-length
                        // mask — the old shape hashed the path twice
                        // (detectLanguage + fileDefinesSymbol's own get).
                        // Files with no outline never define (same as
                        // fileDefinesSymbol's `orelse return false`).
                        var is_doc = false;
                        var defines = false;
                        if (self.outlines.get(hit_path)) |o| {
                            is_doc = isDocLanguage(o.language);
                            if (!is_doc and o.name_len_mask & FileOutline.nameLenBit(query.len) != 0) {
                                for (o.symbols.items) |sym| {
                                    if (asciiEqlIgnoreCase(sym.name, query)) {
                                        defines = true;
                                        break;
                                    }
                                }
                            }
                        } else {
                            is_doc = isDocLanguage(detectLanguage(hit_path));
                        }
                        cur = @intCast(tier0_files.items.len);
                        tier0_files.append(allocator, .{
                            .path = hit_path,
                            .doc_id = doc_id,
                            .count = 0,
                            .first_seen = run_start,
                            .hits_end = run_end,
                            .is_doc = is_doc,
                            .defines = defines,
                        }) catch {
                            cur = SLOT_INVALID;
                        };
                    }
                    if (!postings_grouped) {
                        if (use_slots) {
                            if (doc_id < ndocs) slots[doc_id] = cur;
                        } else {
                            idx_by_doc.put(doc_id, cur) catch {};
                        }
                    }
                }
                if (cur != SLOT_INVALID) {
                    const e = &tier0_files.items[cur];
                    e.count +|= @intCast(@min(run_end - run_start, std.math.maxInt(u32)));
                    e.hits_end = run_end;
                }
            }

            // Sort plain u64 keys instead of the 48-byte structs. The old
            // comparator (is_doc asc, defines desc, count desc, first_seen
            // asc, path asc) packs losslessly: entries were appended in
            // first-seen order, so the array index doubles as the first_seen
            // tiebreak (unique per file — the path tiebreak was unreachable)
            // AND addresses the entry after sorting. count saturates at
            // 2^30−1; beyond that ties fall to first_seen, same as before.
            var tier0_order: std.ArrayList(u64) = .empty;
            defer tier0_order.deinit(allocator);
            try tier0_order.ensureTotalCapacity(allocator, tier0_files.items.len);
            for (tier0_files.items, 0..) |stats, i| {
                const cnt: u64 = @min(stats.count, (1 << 30) - 1);
                const key = (@as(u64, @intFromBool(stats.is_doc)) << 63) |
                    (@as(u64, @intFromBool(!stats.defines)) << 62) |
                    ((((1 << 30) - 1) - cnt) << 32) |
                    @as(u64, @as(u32, @intCast(i)));
                tier0_order.appendAssumeCapacity(key);
            }
            if (tier0_order.items.len > 1) {
                std.sort.pdq(u64, tier0_order.items, {}, std.sort.asc(u64));
            }
            const tier0_per_file_cap: usize = if (tier0_files.items.len <= 1) max_results else @max(1, max_results / 5);
            var tier0_exact_capacity: usize = 0;
            for (tier0_order.items) |key| {
                tier0_exact_capacity += @min(@as(usize, tier0_files.items[@as(u32, @truncate(key))].count), tier0_per_file_cap);
                if (tier0_exact_capacity >= max_results) break;
            }
            const use_line_hits = tier0_exact_capacity >= max_results and tier0_per_file_cap <= 256;
            for (tier0_order.items) |key| {
                const stats = tier0_files.items[@as(u32, @truncate(key))];
                if (result_list.items.len >= max_results) break;
                const ref = self.readContentForSearch(stats.path, allocator) orelse continue;
                defer ref.deinit();
                if (use_line_hits) {
                    var target_lines: [256]u32 = undefined;
                    var target_count: usize = 0;
                    for (word_hits[stats.first_seen..stats.hits_end]) |hit| {
                        if (target_count >= tier0_per_file_cap) break;
                        if (hit.doc_id != stats.doc_id) continue;
                        if (target_count == 0 or target_lines[target_count - 1] != hit.line_num) {
                            target_lines[target_count] = hit.line_num;
                            target_count += 1;
                        }
                    }
                    var spans: [256]LineOffsetCache.Span = undefined;
                    if (self.line_offsets.lineSpans(stats.path, ref.data, target_lines[0..target_count], &spans)) |n_spans| {
                        result_list.ensureUnusedCapacity(allocator, @min(n_spans, max_results - result_list.items.len)) catch {};
                        for (spans[0..n_spans]) |sp| {
                            if (result_list.items.len >= max_results) break;
                            const line_text = try allocator.dupe(u8, ref.data[sp.start..sp.end]);
                            errdefer allocator.free(line_text);
                            const path_copy = try allocator.dupe(u8, stats.path);
                            errdefer allocator.free(path_copy);
                            try result_list.append(allocator, .{ .path = path_copy, .line_num = sp.line, .line_text = line_text });
                        }
                    } else {
                        try appendTargetLineHits(stats.path, ref.data, allocator, target_lines[0..target_count], max_results, &result_list);
                    }
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
                hits_per_file.ensureTotalCapacity(@intCast(@min(word_hits.len, 1024))) catch {};
                // Same contiguous-posting decomposition as Tier 0's grouping:
                // the hit list is runs of one doc_id each, so hitPath + the
                // string getOrPut run once per file run, not per hit.
                var hpf_run_start: usize = 0;
                while (hpf_run_start < word_hits.len) {
                    const hpf_doc = word_hits[hpf_run_start].doc_id;
                    var hpf_run_end = hpf_run_start + 1;
                    while (hpf_run_end < word_hits.len and word_hits[hpf_run_end].doc_id == hpf_doc) hpf_run_end += 1;
                    defer hpf_run_start = hpf_run_end;

                    const hp = self.word_index.hitPath(word_hits[hpf_run_start]);
                    if (hp.len == 0) continue;
                    const gop_h = try hits_per_file.getOrPut(hp);
                    if (!gop_h.found_existing) gop_h.value_ptr.* = 0;
                    gop_h.value_ptr.* += @intCast(@min(hpf_run_end - hpf_run_start, std.math.maxInt(u32)));
                }
                const SortKey = struct { count: u32, len: usize, path: []const u8 };
                var sort_keys = try allocator.alloc(SortKey, cp.len);
                defer allocator.free(sort_keys);
                for (cp, 0..) |p, i| {
                    const cnt = hits_per_file.get(p) orelse 0;
                    const clen = if (self.contents.get(p)) |c| c.len else std.math.maxInt(usize);
                    sort_keys[i] = .{ .count = cnt, .len = clen, .path = p };
                }
                const SortCtx = struct {
                    pub fn lessThan(_: void, a: SortKey, b: SortKey) bool {
                        if (a.count != b.count) return a.count > b.count;
                        return a.len < b.len;
                    }
                };
                std.mem.sort(SortKey, sort_keys, {}, SortCtx.lessThan);
                const cp_mut = @constCast(cp);
                for (sort_keys, 0..) |sk, i| cp_mut[i] = sk.path;

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

    /// Trim a source line for search output: strip leading ASCII indentation
    /// (the line number already locates it) and cap length, to cut agent output
    /// tokens. Mirrors mcp.zig's trimMatchText (MAX 200 bytes, UTF-8-safe cut).
    fn trimSearchLine(line: []const u8) struct { text: []const u8, truncated: bool } {
        var t = line;
        while (t.len > 0 and (t[0] == ' ' or t[0] == '\t')) t = t[1..];
        const MAX: usize = 200;
        if (t.len <= MAX) return .{ .text = t, .truncated = false };
        var cut: usize = MAX;
        while (cut > 0 and (t[cut] & 0xC0) == 0x80) cut -= 1;
        return .{ .text = t[0..cut], .truncated = true };
    }

    pub fn renderPlainSearch(self: *Explorer, query: []const u8, allocator: std.mem.Allocator, out: *std.ArrayList(u8), max_results: usize, paths_only: bool) !bool {
        // Rendered-output cache front door — same generation discipline as
        // searchContent's cache (see that wrapper for the staleness
        // reasoning). Only successful renders (rendered == true) are stored;
        // a false return falls through to searchContentAuto, which caches
        // through searchContent itself.
        const cacheable = max_results > 0 and query.len > 0 and query.len <= 1024 and
            cio.posixGetenv("CODEDB_NO_SEARCH_CACHE") == null;
        const cache_gen = self.search_gen.load(.acquire);
        const cache_fp = if (cacheable) rankingEnvFingerprint() else 0;
        if (cacheable and self.plain_render_cache.render(query, max_results, paths_only, cache_gen, cache_fp, allocator, out, &self.last_search_breakdown)) return true;
        const out_start = out.items.len;

        const rendered = try self.renderPlainSearchUncached(query, allocator, out, max_results, paths_only);
        if (rendered and cacheable) {
            self.plain_render_cache.put(query, max_results, paths_only, cache_gen, cache_fp, out.items[out_start..], self.last_search_breakdown);
        }
        return rendered;
    }

    fn renderPlainSearchUncached(self: *Explorer, query: []const u8, allocator: std.mem.Allocator, out: *std.ArrayList(u8), max_results: usize, paths_only: bool) !bool {
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
            // One past the ordinal of this file's last hit — bounds the
            // file's posting run for the per-file target-line collection
            // below (the doc_id filter stays, so the bounds are correct even
            // if a file's hits were ever non-contiguous).
            hits_end: usize,
            is_doc: bool,
            defines: bool,
        };

        var tier0_files_buf: [512]Tier0File = undefined;
        var tier0_files_len: usize = 0;
        // Direct-address doc_id → entry-index slots replace the linear rescan
        // (O(unique files²) on high-frequency words). Same gating as
        // searchContent's grouping; when the table is too big to amortize the
        // memset, the rescan path below still handles dedup.
        const SLOT_NONE = std.math.maxInt(u32);
        const ndocs = self.word_index.id_to_path.items.len;
        const use_slots = ndocs > 0 and (ndocs <= 4096 or (ndocs <= 65536 and word_hits.len >= 512));
        var slots: []u32 = &.{};
        defer if (slots.len > 0) allocator.free(slots);
        if (use_slots) {
            slots = allocator.alloc(u32, ndocs) catch &.{};
            if (slots.len > 0) @memset(slots, SLOT_NONE);
        }
        // Postings for one file are appended contiguously (indexFile
        // processes whole files), so the hit list decomposes into runs of one
        // doc_id each — group run-at-a-time: scan to the run boundary first,
        // then touch the slots/rescan and the entry ONCE per run.
        var run_start: usize = 0;
        while (run_start < word_hits.len) {
            const doc_id = word_hits[run_start].doc_id;
            var run_end = run_start + 1;
            while (run_end < word_hits.len and word_hits[run_end].doc_id == doc_id) run_end += 1;
            defer run_start = run_end;

            const hit_path = self.word_index.hitPath(word_hits[run_start]);
            if (hit_path.len == 0) continue;

            var found_i: ?usize = null;
            if (slots.len > 0) {
                if (doc_id < slots.len and slots[doc_id] != SLOT_NONE) found_i = slots[doc_id];
            } else {
                for (tier0_files_buf[0..tier0_files_len], 0..) |stats, i| {
                    if (stats.doc_id == doc_id) {
                        found_i = i;
                        break;
                    }
                }
            }
            const run_count: u32 = @intCast(@min(run_end - run_start, std.math.maxInt(u32)));
            if (found_i) |i| {
                tier0_files_buf[i].count +|= run_count;
                tier0_files_buf[i].hits_end = run_end;
            } else {
                if (tier0_files_len >= tier0_files_buf.len) return false;
                if (slots.len > 0 and doc_id < slots.len) slots[doc_id] = @intCast(tier0_files_len);
                tier0_files_buf[tier0_files_len] = .{
                    .doc_id = doc_id,
                    .path = hit_path,
                    .count = run_count,
                    .first_seen = run_start,
                    .hits_end = run_end,
                    .is_doc = isDocLanguage(detectLanguage(hit_path)),
                    .defines = self.fileDefinesSymbol(hit_path, query),
                };
                tier0_files_len += 1;
            }
        }

        if (tier0_files_len == 0) return false;
        const tier0_files = tier0_files_buf[0..tier0_files_len];
        if (tier0_files.len > 1) {
            const RankCtx = struct {
                priors: []const f32,
                files: []const Tier0File,
                // Path-prior portion of rerankSignalScore: the canonical-file signals
                // (basename-stem match, path segment) and demotion penalties. Without it
                // this fast-path rendered in raw hit-count order, so a high-frequency
                // non-canonical file outranked the canonical basename match.
                // Computed ONCE per file into `priors` — the old shape
                // recomputed both priors (basename + ~10 path-segment scans)
                // inside the comparator on every comparison.
                fn prior(path: []const u8, q: []const u8) f32 {
                    const base = std.fs.path.basename(path);
                    const stem_end = std.mem.indexOfScalar(u8, base, '.') orelse base.len;
                    const stem = base[0..stem_end];
                    var s: f32 = 0;
                    if (asciiEqlIgnoreCase(stem, q)) {
                        s += 15.0;
                    } else if (asciiContainsIgnoreCase(stem, q) or asciiContainsIgnoreCase(q, stem)) {
                        s += 8.0;
                    } else if (pathHasSegmentIgnoreCase(path, q)) {
                        s += 6.0;
                    }
                    if (pathHasSegment(path, "tests") or pathHasSegment(path, "test")) s *= 0.6;
                    if (pathHasSegment(path, "examples") or pathHasSegment(path, "example")) s *= 0.6;
                    if (pathHasSegment(path, "vendor") or pathHasSegment(path, "node_modules") or
                        pathHasSegment(path, "third_party")) s *= 0.4;
                    return s;
                }
                pub fn lessThan(ctx: @This(), ai: u32, bi: u32) bool {
                    const pa = ctx.priors[ai];
                    const pb = ctx.priors[bi];
                    if (pa != pb) return pa > pb;
                    const a = ctx.files[ai];
                    const b = ctx.files[bi];
                    if (a.is_doc != b.is_doc) return !a.is_doc;
                    if (a.count != b.count) return a.count > b.count;
                    if (a.first_seen != b.first_seen) return a.first_seen < b.first_seen;
                    return std.mem.lessThan(u8, a.path, b.path);
                }
            };
            var priors_buf: [512]f32 = undefined;
            var order_buf: [512]u32 = undefined;
            for (tier0_files, 0..) |stats, i| {
                var pr = RankCtx.prior(stats.path, query);
                if (stats.defines) pr += 20.0; // float the actual definition above mentions
                priors_buf[i] = pr;
                order_buf[i] = @intCast(i);
            }
            const order = order_buf[0..tier0_files.len];
            std.sort.pdq(u32, order, RankCtx{ .priors = priors_buf[0..tier0_files.len], .files = tier0_files }, RankCtx.lessThan);
            // Apply the permutation back into the value buffer so the render
            // loops below keep iterating tier0_files directly.
            var sorted_buf: [512]Tier0File = undefined;
            for (order, 0..) |src, dst| sorted_buf[dst] = tier0_files[src];
            @memcpy(tier0_files, sorted_buf[0..tier0_files.len]);
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
            for (word_hits[stats.first_seen..stats.hits_end]) |hit| {
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
            var spans: [256]LineOffsetCache.Span = undefined;
            // OOM building the offset table → bail to the full searchContent
            // path (caller falls through), which renders the same results.
            const n_spans = self.line_offsets.lineSpans(stats.path, content, target_lines[0..target_count], &spans) orelse return false;
            // Def-line-first: within a file that defines the query symbol, render the
            // definition line(s) before mere mentions — stable-moves matching spans to
            // the front (reorders the OUTPUT spans, not lineSpans' sorted input).
            if (stats.defines) {
                if (self.outlines.get(stats.path)) |outline| {
                    var def_w: usize = 0;
                    var i: usize = 0;
                    while (i < n_spans) : (i += 1) {
                        var is_def = false;
                        for (outline.symbols.items) |sym| {
                            if (sym.line_start == spans[i].line and asciiEqlIgnoreCase(sym.name, query)) {
                                is_def = true;
                                break;
                            }
                        }
                        if (is_def) {
                            const tmp = spans[i];
                            var j: usize = i;
                            while (j > def_w) : (j -= 1) spans[j] = spans[j - 1];
                            spans[def_w] = tmp;
                            def_w += 1;
                        }
                    }
                }
            }
            for (spans[0..n_spans]) |line_span| {
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
                    const mt = trimSearchLine(content[line_span.start..line_span.end]);
                    if (mt.truncated) {
                        try w.print("  {s}:{d}: {s}…\n", .{ stats.path, line_span.line, mt.text });
                    } else {
                        try w.print("  {s}:{d}: {s}\n", .{ stats.path, line_span.line, mt.text });
                    }
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
        self: *Explorer,
        result_list: *std.ArrayList(SearchResult),
        query: []const u8,
        allocator: std.mem.Allocator,
    ) ![]const SearchResult {
        const sp = RvsmSizePrior.fromEnv(self);
        const lfp = LexFreqPenalty.fromEnv();

        // The file-frequency penalty (engram's negative-lexical signal) needs the
        // per-file match-line count across the whole result set, so tally it up
        // front. Built only when the experiment is enabled — zero cost otherwise.
        var file_hit_counts = std.StringHashMap(u32).init(allocator);
        defer file_hit_counts.deinit();
        var max_file_hits: u32 = 0;
        if (lfp.enabled) {
            // Results arrive grouped by file, so the consecutive-path fast
            // path turns one string getOrPut per result into one per unique
            // file. The cached pointer is only dereferenced immediately after
            // being (re)set, so it cannot dangle across a rehash.
            var last_path: []const u8 = "";
            var last_count: ?*u32 = null;
            for (result_list.items) |r| {
                if (last_count) |cnt| {
                    if (std.mem.eql(u8, r.path, last_path)) {
                        cnt.* += 1;
                        if (cnt.* > max_file_hits) max_file_hits = cnt.*;
                        continue;
                    }
                }
                const gop = try file_hit_counts.getOrPut(r.path);
                gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
                if (gop.value_ptr.* > max_file_hits) max_file_hits = gop.value_ptr.*;
                last_path = r.path;
                last_count = gop.value_ptr;
            }
        }
        // #550: a single-token query that exactly names a known symbol gets the
        // call-graph distance boost here too (the multi-word BM25 path applies
        // it in searchContentRanked). The symbol_index gate keeps plain word
        // queries from ever paying for a graph build.
        var gd_arena = std.heap.ArenaAllocator.init(allocator);
        defer gd_arena.deinit();
        var graph_dist: ?std.StringHashMap(u8) = null;
        if (cio.posixGetenv("CODEDB_NO_CENTRALITY") == null and
            cio.posixGetenv("CODEDB_NO_GRAPH_DISTANCE") == null and
            (self.call_graph != null or self.symbol_index.contains(query)))
        {
            self.ensureCallGraph(allocator);
            const ga = gd_arena.allocator();
            var gd_terms = std.StringHashMap(void).init(ga);
            gd_terms.put(query, {}) catch {};
            graph_dist = self.queryGraphDistances(&gd_terms, ga);
        }

        // Per-unique-path rerank facts, computed ONCE per path instead of per
        // result — every path-level signal (outline definition scan, path
        // priors, boost multipliers) is identical for all hits in the same
        // file. `defines` feeds the co-change seeds (#550 signal 2: seeds are
        // the result files that DEFINE the queried symbol, so plain word
        // queries never trigger the one-time `git log` shell-out).
        // Results arrive grouped by file (every tier emits per-file), so a
        // consecutive-path fast path resolves most results with one
        // std.mem.eql instead of a string hash + probe.
        var facts_by_path = std.StringHashMap(PathRerankFacts).init(allocator);
        defer facts_by_path.deinit();
        {
            var last_path: []const u8 = "";
            for (result_list.items) |r| {
                if (last_path.len > 0 and std.mem.eql(u8, r.path, last_path)) continue;
                last_path = r.path;
                const gop = facts_by_path.getOrPut(r.path) catch continue;
                if (gop.found_existing) continue;
                gop.value_ptr.* = self.pathRerankFacts(r.path, query);
            }
        }

        var cc_seeds = std.StringHashMap(void).init(allocator);
        defer cc_seeds.deinit();
        if (cio.posixGetenv("CODEDB_NO_COCHANGE") == null) {
            var facts_iter = facts_by_path.iterator();
            while (facts_iter.next()) |entry| {
                if (entry.value_ptr.defines) cc_seeds.put(entry.key_ptr.*, {}) catch {};
            }
            if (cc_seeds.count() > 0) self.ensureCoChange();
        }

        // The boost multipliers depend on graph_dist / cc_seeds / the hit
        // tally, so they fill in a second pass over the deduped path set.
        var boosts_iter = facts_by_path.iterator();
        while (boosts_iter.next()) |entry| {
            const path = entry.key_ptr.*;
            entry.value_ptr.gd = graphDistanceBoost(graph_dist, path);
            entry.value_ptr.cc = self.coChangeBoost(&cc_seeds, path);
            if (lfp.enabled) entry.value_ptr.lfp_mult = lfp.multiplier(file_hit_counts.get(path) orelse 1, max_file_hits);
            if (sp.enabled) entry.value_ptr.sp_mult = sp.multiplier(self, path);
        }

        // Same consecutive-path memoization as the facts pass. Holding a
        // pointer (instead of copying the ~120-byte facts struct per result)
        // is safe: the map is not mutated anywhere in this loop.
        const no_facts = PathRerankFacts{};
        var score_last_path: []const u8 = "";
        var score_last_facts: *const PathRerankFacts = &no_facts;
        for (result_list.items) |*r| {
            if (score_last_path.len == 0 or !std.mem.eql(u8, r.path, score_last_path)) {
                score_last_facts = facts_by_path.getPtr(r.path) orelse &no_facts;
                score_last_path = r.path;
            }
            const facts = score_last_facts;
            const def_line_match = blk: {
                for (facts.def_lines[0..facts.def_count]) |ln| {
                    if (ln == r.line_num) break :blk true;
                }
                if (facts.def_overflow) {
                    if (self.outlines.get(r.path)) |outline| {
                        for (outline.symbols.items) |sym| {
                            if (sym.line_start == r.line_num and asciiEqlIgnoreCase(sym.name, query)) break :blk true;
                        }
                    }
                }
                break :blk false;
            };
            var score: f32 = countOccurrences(r.line_text, query);
            if (facts.is_tooling) score = @min(score, 2.0);
            if (def_line_match) score += 5.0;
            score += facts.add_boost;
            if (facts.is_test) score *= 0.6;
            if (facts.is_example) score *= 0.6;
            if (facts.is_tooling) score *= 0.5;
            if (facts.is_vendor) score *= 0.4;
            // Doc-language penalty: markdown / data files (CHANGELOG.md, design
            // docs, benchmark logs) often mention an identifier many times in a
            // single line, which lets per-line frequency dwarf code call sites.
            // For doc files, more mentions don't reflect more code-relevance —
            // they reflect prose density. Cap at 1.0 then halve so any code hit
            // (score >= 1) outranks any doc hit. Symmetric with path-prior.
            if (facts.is_doc) score = @min(score, 1.0) * 0.5;
            score *= facts.gd;
            score *= facts.cc;
            score *= facts.lfp_mult;
            score *= facts.sp_mult;
            r.score = score;
        }
        if (result_list.items.len > 1) {
            // The (score desc, path asc, line asc) order sorts via one
            // precomputed u64 key per result — score as order-isomorphic
            // descending bits, path as its lexicographic rank among the
            // unique result paths — with line_num as the in-comparator
            // tiebreak. No string compares or 40-byte struct moves inside
            // the sort loop; the permutation applies in one scratch pass.
            var unique_paths: std.ArrayList([]const u8) = .empty;
            defer unique_paths.deinit(allocator);
            try unique_paths.ensureTotalCapacity(allocator, facts_by_path.count());
            var path_iter = facts_by_path.keyIterator();
            while (path_iter.next()) |k| unique_paths.appendAssumeCapacity(k.*);
            std.sort.pdq([]const u8, unique_paths.items, {}, struct {
                pub fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.lessThan(u8, a, b);
                }
            }.lessThan);
            for (unique_paths.items, 0..) |p, rank| {
                if (facts_by_path.getPtr(p)) |f| f.path_rank = @intCast(rank);
            }

            const keys = try allocator.alloc(u64, result_list.items.len);
            defer allocator.free(keys);
            const order = try allocator.alloc(u32, result_list.items.len);
            defer allocator.free(order);
            {
                var lp: []const u8 = "";
                var lrank: u32 = std.math.maxInt(u32);
                for (result_list.items, 0..) |r, ri| {
                    if (lp.len == 0 or !std.mem.eql(u8, r.path, lp)) {
                        lrank = if (facts_by_path.getPtr(r.path)) |f| f.path_rank else std.math.maxInt(u32);
                        lp = r.path;
                    }
                    keys[ri] = (@as(u64, scoreDescBits(r.score)) << 32) | lrank;
                    order[ri] = @intCast(ri);
                }
            }
            const SortCtx = struct {
                keys: []const u64,
                items: []const SearchResult,
                pub fn lessThan(ctx: @This(), a: u32, b: u32) bool {
                    if (ctx.keys[a] != ctx.keys[b]) return ctx.keys[a] < ctx.keys[b];
                    return ctx.items[a].line_num < ctx.items[b].line_num;
                }
            };
            std.sort.pdq(u32, order, SortCtx{ .keys = keys, .items = result_list.items }, SortCtx.lessThan);
            const scratch = try allocator.alloc(SearchResult, result_list.items.len);
            defer allocator.free(scratch);
            @memcpy(scratch, result_list.items);
            for (order, 0..) |src, dst| result_list.items[dst] = scratch[src];
        }
        self.appendRerankTrace(query, result_list.items);
        return result_list.toOwnedSlice(allocator);
    }

    /// Path-level rerank signals (issue #429), computed once per UNIQUE path
    /// by rerankAndFinalize — every field here is identical for all hits in
    /// the same file, so recomputing per result (the pre-fix shape) only
    /// burned time. Per-result composition stays in rerankAndFinalize.
    const PathRerankFacts = struct {
        defines: bool = false,
        def_lines: [16]u32 = undefined,
        def_count: u8 = 0,
        def_overflow: bool = false,
        is_tooling: bool = false,
        is_test: bool = false,
        is_example: bool = false,
        is_vendor: bool = false,
        is_doc: bool = false,
        add_boost: f32 = 0,
        gd: f32 = 1,
        cc: f32 = 1,
        lfp_mult: f32 = 1,
        sp_mult: f32 = 1,
        /// Lexicographic rank of this path among the result set's unique
        /// paths — assigned by rerankAndFinalize just before the final sort
        /// so the sort key replaces per-comparison string compares.
        path_rank: u32 = 0,
    };

    /// Map a score to bits whose UNSIGNED ascending order equals descending
    /// float order — the standard sign-flip trick, with NaN collapsed to 0
    /// and -0.0 to +0.0 so it ties exactly like the float comparator it
    /// replaces (`if (sa != sb) return sa > sb` with NaN already mapped).
    fn scoreDescBits(score: f32) u32 {
        var v: f32 = if (score == score) score else 0;
        if (v == 0) v = 0;
        const b: u32 = @bitCast(v);
        const asc: u32 = if (b & 0x8000_0000 != 0) ~b else b | 0x8000_0000;
        return ~asc;
    }

    fn pathRerankFacts(self: *const Explorer, path: []const u8, query: []const u8) PathRerankFacts {
        var facts: PathRerankFacts = .{};

        // Symbol-definition facts from the outline: which lines start a
        // symbol named exactly like the query (case-insensitive). Feeds the
        // +5 definition-line boost and the co-change seed set (#550).
        // Path-prior classification (#598 tooling cap, #580 test detection,
        // example/vendor demotion) is query-independent — read it from the
        // outline, where it was computed once at init; only paths with no
        // outline (not indexed) classify on the fly.
        var class: PathClass = .{};
        var is_doc_lang: bool = undefined;
        if (self.outlines.get(path)) |outline| {
            class = outline.path_class;
            is_doc_lang = isDocLanguage(outline.language);
            if (outline.name_len_mask & FileOutline.nameLenBit(query.len) != 0) {
                for (outline.symbols.items) |sym| {
                    if (!asciiEqlIgnoreCase(sym.name, query)) continue;
                    facts.defines = true;
                    if (facts.def_count < facts.def_lines.len) {
                        facts.def_lines[facts.def_count] = sym.line_start;
                        facts.def_count += 1;
                    } else {
                        facts.def_overflow = true;
                    }
                }
            }
        } else {
            class = classifyPath(path);
            is_doc_lang = isDocLanguage(detectLanguage(path));
        }
        facts.is_tooling = class.is_tooling;
        facts.is_test = class.is_test;
        facts.is_example = class.is_example;
        facts.is_vendor = class.is_vendor;
        facts.is_doc = is_doc_lang;

        const basename = std.fs.path.basename(path);
        const stem_end = std.mem.indexOfScalar(u8, basename, '.') orelse basename.len;
        const stem = basename[0..stem_end];
        const stem_contains_query = asciiContainsIgnoreCase(stem, query);
        const query_contains_stem = asciiContainsIgnoreCase(query, stem);
        const stem_related_to_query = stem_contains_query or query_contains_stem;
        if (asciiEqlIgnoreCase(stem, query)) {
            facts.add_boost += 15.0;
        } else if (stem_related_to_query) {
            facts.add_boost += 8.0;
        }
        // Path-segment match boost: query matches a directory segment in
        // the path (e.g. query="parser" boosts src/parser/foo.zig). Weaker
        // than basename match because the file's own name is a stronger
        // intent signal than the directory it lives in. Skip when basename
        // already matched to avoid double-counting.
        if (!stem_related_to_query and pathHasSegmentIgnoreCase(path, query)) {
            facts.add_boost += 6.0;
        }

        return facts;
    }

    /// Append one JSON line per searchContent invocation. v0 logger for the
    /// rerank-tuning experiment — pure observation, never affects ranking.
    /// Silent no-op when path is unset, io is unset, or any I/O step fails.
    /// Caps query at 256 bytes, results at 50 entries, file at 10 MB
    /// (rotates by truncate-clobber).
    fn appendRerankTrace(self: *const Explorer, query: []const u8, results: []const SearchResult) void {
        if (builtin.os.tag == .freestanding) return;
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

        // Windows requires read access on the handle for length(), even though
        // the trace path only appends with positional writes.
        var file = std.Io.Dir.cwd().createFile(io_inst, path, .{ .read = true, .truncate = false }) catch return;
        var current_size = file.length(io_inst) catch {
            file.close(io_inst);
            return;
        };
        if (current_size >= size_limit) {
            file.close(io_inst);
            file = std.Io.Dir.cwd().createFile(io_inst, path, .{ .read = true, .truncate = true }) catch return;
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
        // Machine artifacts: run logs and record files match almost any
        // multi-word query (giant JSON lines) and buried real source in the
        // 2026-08 agent eval — a bench .log outranked src/snapshot.zig for
        // "snapshot serialization". They are records, not code.
        if (std.mem.endsWith(u8, path, ".log") or
            std.mem.endsWith(u8, path, ".jsonl") or
            std.mem.endsWith(u8, path, ".ndjson")) mult *= 0.25;
        if (std.mem.indexOf(u8, path, "/bench/") != null or
            std.mem.startsWith(u8, path, "bench/") or
            std.mem.indexOf(u8, path, "/benchmarks/") != null or
            std.mem.startsWith(u8, path, "benchmarks/")) mult *= 0.5;
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

    /// Query-specific call-graph distance (#550): BFS outward — callers and
    /// callees — from every function whose name equals a query term, recording
    /// each reached file's minimum hop distance. Arena-allocated; null when no
    /// graph is built or no term names a symbol, so ranking is unchanged.
    fn queryGraphDistances(self: *Explorer, terms: *const std.StringHashMap(void), ta: std.mem.Allocator) ?std.StringHashMap(u8) {
        const cg = self.call_graph orelse return null;
        const n = cg.node_name.len;
        if (n == 0) return null;
        const max_hops: u8 = 3;
        const unseen: u8 = std.math.maxInt(u8);

        const dist = ta.alloc(u8, n) catch return null;
        @memset(dist, unseen);

        var queue: std.ArrayList(codegraph.NodeId) = .empty;
        for (cg.node_name, 0..) |name, nid| {
            if (name.len < 3) continue;
            var it = terms.keyIterator();
            while (it.next()) |t| {
                if (asciiEqlIgnoreCase(name, t.*)) {
                    dist[nid] = 0;
                    queue.append(ta, @intCast(nid)) catch return null;
                    break;
                }
            }
        }
        if (queue.items.len == 0) return null;

        // adj is forward-only (callees); cg.radj (prebuilt once in
        // ensureCallGraph) makes the walk undirected so callers of a matched
        // symbol count as near too.

        var head: usize = 0;
        while (head < queue.items.len) : (head += 1) {
            const nid = queue.items[head];
            const d = dist[nid];
            if (d >= max_hops) continue;
            for (cg.adj[nid].items) |nb| {
                if (dist[nb] != unseen) continue;
                dist[nb] = d + 1;
                queue.append(ta, nb) catch return null;
            }
            for (cg.radj[nid].items) |nb| {
                if (dist[nb] != unseen) continue;
                dist[nb] = d + 1;
                queue.append(ta, nb) catch return null;
            }
        }

        var file_dist = std.StringHashMap(u8).init(ta);
        for (queue.items) |nid| {
            const gop = file_dist.getOrPut(cg.node_path[nid]) catch return null;
            if (!gop.found_existing or gop.value_ptr.* > dist[nid]) gop.value_ptr.* = dist[nid];
        }
        return file_dist;
    }

    /// Boost for files within a few call hops of a symbol the query names,
    /// halving per hop: 0 hops ×1.5, 1 ×1.25, 2 ×1.125, 3 ×1.0625. Like
    /// centralityBoost it is always ≥ 1 — never a filter — and 1.0 whenever
    /// the distance signal is off, so ranking degrades to the status quo.
    fn graphDistanceBoost(file_dist: ?std.StringHashMap(u8), path: []const u8) f32 {
        const m = file_dist orelse return 1.0;
        const d = m.get(path) orelse return 1.0;
        const gamma: f32 = 0.5;
        return 1.0 + gamma / @as(f32, @floatFromInt(@as(u32, 1) << @intCast(d)));
    }

    /// True when a query token looks like a code identifier (camelCase or
    /// snake_case) — the same shape heuristic the ranked tokenizer uses to
    /// split identifiers. Gates symbol-index and call-graph work so plain
    /// natural-language words never pay for either.
    fn queryNamesIdentifier(query: []const u8) bool {
        for (query) |c| {
            if (c == '_' or (c >= 'A' and c <= 'Z')) return true;
        }
        return false;
    }

    /// True when `path`'s outline defines a symbol named `name` (any kind,
    /// case-insensitive). Outline-based so it works on snapshot fast-loads
    /// where symbol_index is deferred (#564).
    fn fileDefinesSymbol(self: *const Explorer, path: []const u8, name: []const u8) bool {
        const outline = self.outlines.get(path) orelse return false;
        if (outline.name_len_mask & FileOutline.nameLenBit(name.len) == 0) return false;
        for (outline.symbols.items) |sym| {
            if (asciiEqlIgnoreCase(sym.name, name)) return true;
        }
        return false;
    }

    /// Build the git co-change map once (#550): `git log --name-only` over
    /// the last 500 commits, mega-commits (>32 files) skipped, top 8 partners
    /// per file. Needs root_path (setRoot); silently unavailable outside a
    /// git repo — the attempted flag stops re-shelling. Mirrors
    /// ensureCallGraph: call while holding at least a shared lock on `mu`.
    fn ensureCoChange(self: *Explorer) void {
        if (builtin.os.tag == .freestanding) return;
        if (self.co_change != null or self.co_change_attempted) return;
        self.cochange_build_mu.lock();
        defer self.cochange_build_mu.unlock();
        if (self.co_change != null or self.co_change_attempted) return;
        self.co_change_attempted = true;
        const root = self.root_path orelse return;
        self.co_change = git.buildCoChange(self.allocator, root, 500, 32, 8);
        // The co-change boost just became available: results cached before
        // the build could differ from a fresh search.
        if (self.co_change != null) self.bumpSearchGen();
    }

    /// Boost for files that historically change together with the files
    /// defining the queried symbol — git co-change, the temporal sibling of
    /// graphDistanceBoost (#550). Always ≥ 1, never a filter; 1.0 when the
    /// map or seeds are absent. Two shared commits is the noise floor;
    /// strength saturates at eight (×1.25).
    fn coChangeBoost(self: *const Explorer, seeds: *const std.StringHashMap(void), path: []const u8) f32 {
        const cc = self.co_change orelse return 1.0;
        if (seeds.count() == 0) return 1.0;
        if (seeds.contains(path)) return 1.0;
        var best: u32 = 0;
        var it = seeds.keyIterator();
        while (it.next()) |s| {
            const partners = cc.get(s.*) orelse continue;
            for (partners) |p| {
                if (p.count > best and std.mem.eql(u8, p.path, path)) best = p.count;
            }
        }
        if (best < 2) return 1.0;
        const strength = @min(@as(f32, @floatFromInt(best)) / 8.0, 1.0);
        return 1.0 + 0.25 * strength;
    }

    /// Public, lock-acquiring entry point for single-threaded callers (the
    /// index/scan path) to pre-build call_centrality before persisting a snapshot,
    /// so a later load can restore it instead of paying the lazy first-query build.
    /// ensureCallCentrality assumes the caller already holds a shared lock (it is
    /// normally reached from searchContentRanked); this wrapper takes that lock.
    pub fn buildCallCentrality(self: *Explorer, allocator: std.mem.Allocator) void {
        self.ensureSymbolIndex();
        self.mu.lockShared();
        defer self.mu.unlockShared();
        self.ensureCallCentrality(allocator);
    }

    fn appendCallGraphZigImportBinding(
        bindings: *std.ArrayList(codegraph.ImportBinding),
        allocator: std.mem.Allocator,
        alias: []const u8,
        target_path: []const u8,
    ) !void {
        for (bindings.items) |binding| {
            if (std.mem.eql(u8, binding.alias, alias) and
                std.mem.eql(u8, binding.target_path, target_path)) return;
        }
        try bindings.append(allocator, .{ .alias = alias, .target_path = target_path });
    }

    /// Resolve one literal Zig source import declared by `alias` in `outline`.
    /// Duplicate declarations with different targets are malformed/ambiguous and
    /// intentionally do not produce a graph fact.
    fn callGraphZigImportedPath(
        self: *Explorer,
        outline: *const FileOutline,
        top_level_import_lines: *const U32HashMap(void),
        alias: []const u8,
        require_public: bool,
        allocator: std.mem.Allocator,
    ) ?[]const u8 {
        if (outline.language != .zig) return null;
        var found: ?[]const u8 = null;
        for (outline.symbols.items) |sym| {
            if (sym.kind != .import or !std.mem.eql(u8, sym.name, alias)) continue;
            if (!top_level_import_lines.contains(sym.line_start)) continue;
            const detail = sym.detail orelse continue;
            if (require_public and !std.mem.startsWith(u8, std.mem.trim(u8, detail, " \t"), "pub ")) continue;
            const raw_path = extractStringLiteral(detail) orelse continue;
            // Package imports such as `std`, `builtin`, and named modules do not
            // identify an indexed file. Resolution is deliberately limited to
            // concrete Zig source imports.
            if (!std.mem.endsWith(u8, raw_path, ".zig") or std.fs.path.isAbsolute(raw_path)) continue;
            const target_path = resolveRelativeImportPath(outline.path, raw_path, allocator) orelse continue;
            if (!self.outlines.contains(target_path)) continue;
            if (found) |prior| {
                if (!std.mem.eql(u8, prior, target_path)) return null;
            } else {
                found = target_path;
            }
        }
        return found;
    }

    /// One lexical pass records lines whose `@import` token itself occurs at
    /// file scope. Using the token depth (rather than the declaration's line)
    /// also rejects `const S = struct { const x = @import(...); };` on line 1.
    /// The resulting set is reused for every import in the file, avoiding the
    /// former O(imports * file_bytes) prefix rescans on cold graph builds.
    fn zigTopLevelImportLines(
        content: []const u8,
        outline: *const FileOutline,
        allocator: std.mem.Allocator,
    ) !U32HashMap(void) {
        var lines = U32HashMap(void).init(allocator);
        errdefer lines.deinit();
        var last_import_line: u32 = 0;
        for (outline.symbols.items) |sym| {
            if (sym.kind == .import) last_import_line = @max(last_import_line, sym.line_start);
        }
        if (last_import_line == 0) return lines;
        var brace_depth: usize = 0;
        var block_comment_depth: usize = 0;
        var string_quote: u8 = 0;
        var escaped = false;
        var line: u32 = 1;
        var only_whitespace = true;
        var i: usize = 0;
        while (i < content.len and line <= last_import_line) : (i += 1) {
            const c = content[i];
            if (c == '\n') {
                line += 1;
                only_whitespace = true;
                string_quote = 0;
                escaped = false;
                continue;
            }
            if (block_comment_depth > 0) {
                if (c == '/' and i + 1 < content.len and content[i + 1] == '*') {
                    block_comment_depth += 1;
                    i += 1;
                } else if (c == '*' and i + 1 < content.len and content[i + 1] == '/') {
                    block_comment_depth -= 1;
                    i += 1;
                }
                continue;
            }
            if (string_quote != 0) {
                if (escaped) {
                    escaped = false;
                } else if (c == '\\') {
                    escaped = true;
                } else if (c == string_quote) {
                    string_quote = 0;
                }
                continue;
            }
            if (only_whitespace and (c == ' ' or c == '\t' or c == '\r')) continue;
            if (only_whitespace and c == '\\' and i + 1 < content.len and content[i + 1] == '\\') {
                while (i + 1 < content.len and content[i + 1] != '\n') i += 1;
                continue;
            }
            only_whitespace = false;
            if (c == '/' and i + 1 < content.len) {
                if (content[i + 1] == '/') {
                    while (i + 1 < content.len and content[i + 1] != '\n') i += 1;
                    continue;
                }
                if (content[i + 1] == '*') {
                    block_comment_depth = 1;
                    i += 1;
                    continue;
                }
            }
            if (c == '"' or c == '\'') {
                string_quote = c;
            } else if (brace_depth == 0 and c == '@' and
                std.mem.startsWith(u8, content[i..], "@import") and
                (i + 7 == content.len or !isIdentChar(content[i + 7])))
            {
                try lines.put(line, {});
            } else if (c == '{') {
                brace_depth += 1;
            } else if (c == '}' and brace_depth > 0) {
                brace_depth -= 1;
            }
        }
        return lines;
    }

    fn callGraphImportTarget(bindings: []const codegraph.ImportBinding, alias: []const u8) ?[]const u8 {
        for (bindings) |binding| {
            if (std.mem.eql(u8, binding.alias, alias)) return binding.target_path;
        }
        return null;
    }

    fn hasNestedZigImportQualifier(content: []const u8, bindings: []const codegraph.ImportBinding) bool {
        if (bindings.len == 0) return false;
        var search_from: usize = 0;
        while (std.mem.indexOfScalarPos(u8, content, search_from, '.')) |dot| {
            search_from = dot + 1;
            var root_start = dot;
            while (root_start > 0 and isIdentChar(content[root_start - 1])) root_start -= 1;
            if (root_start == dot) continue;
            if (callGraphImportTarget(bindings, content[root_start..dot]) == null) continue;
            var segment_end = dot + 1;
            const segment_start = segment_end;
            while (segment_end < content.len and isIdentChar(content[segment_end])) segment_end += 1;
            if (segment_end > segment_start and segment_end < content.len and content[segment_end] == '.') return true;
        }
        return false;
    }

    /// Build the narrow module-alias facts used by the call graph for Zig.
    /// Zig file imports are relative even without a leading `./`, unlike the
    /// generic dependency resolver, so resolve them against the importing file.
    /// Nested re-export chains are added later from the already-extracted
    /// function callees, so cold graph construction never scans a file twice.
    fn callGraphZigImportBindings(
        self: *Explorer,
        outline: *const FileOutline,
        content: []const u8,
        allocator: std.mem.Allocator,
    ) ![]const codegraph.ImportBinding {
        if (outline.language != .zig) return &.{};
        var bindings: std.ArrayList(codegraph.ImportBinding) = .empty;
        errdefer bindings.deinit(allocator);
        var top_level_import_lines = try zigTopLevelImportLines(content, outline, allocator);
        defer top_level_import_lines.deinit();
        for (outline.symbols.items) |sym| {
            if (sym.kind != .import) continue;
            const target_path = self.callGraphZigImportedPath(outline, &top_level_import_lines, sym.name, false, allocator) orelse continue;
            try appendCallGraphZigImportBinding(&bindings, allocator, sym.name, target_path);
        }

        return bindings.toOwnedSlice(allocator);
    }

    fn extendCallGraphZigImportBindings(
        self: *Explorer,
        bindings: *std.ArrayList(codegraph.ImportBinding),
        calls: []const codegraph.Callee,
        allocator: std.mem.Allocator,
    ) !void {
        for (calls) |callee| {
            const qualifier = callee.qualifier orelse continue;
            var segments = std.mem.splitScalar(u8, qualifier, '.');
            const root_alias = segments.next() orelse continue;
            var target_path = callGraphImportTarget(bindings.items, root_alias) orelse continue;
            var prefix_end = root_alias.len;
            while (segments.next()) |segment| {
                prefix_end += 1 + segment.len;
                const prefix = qualifier[0..prefix_end];
                if (callGraphImportTarget(bindings.items, prefix)) |cached| {
                    target_path = cached;
                    continue;
                }
                const target_outline = self.outlines.getPtr(target_path) orelse break;
                const target_ref = self.readContentForSearch(target_path, allocator) orelse break;
                var target_import_lines = zigTopLevelImportLines(target_ref.data, target_outline, allocator) catch {
                    target_ref.deinit();
                    break;
                };
                const next_path = self.callGraphZigImportedPath(
                    target_outline,
                    &target_import_lines,
                    segment,
                    true,
                    allocator,
                );
                target_import_lines.deinit();
                target_ref.deinit();
                target_path = next_path orelse break;
                try appendCallGraphZigImportBinding(bindings, allocator, prefix, target_path);
            }
        }
    }

    /// Build the resolved call graph once (idempotent, mutex-guarded). Must be
    /// called while holding at least a shared lock on `mu`. Retains edges for
    /// codedb_callpath and computes per-file centrality (PageRank by default).
    fn ensureCallGraphMode(self: *Explorer, allocator: std.mem.Allocator, exact: bool) void {
        if (self.call_graph != null and (!exact or self.call_graph_exact)) return;
        // #564: never build (and cache) a graph from a deferred symbol index —
        // resolveCallees would see no definitions and the empty graph would be
        // cached forever. Callers that need the graph ensureSymbolIndex first;
        // ranking paths just skip the boost until then.
        if (!self.symbol_index_complete) return;
        self.centrality_build_mu.lock();
        defer self.centrality_build_mu.unlock();
        if (self.call_graph != null and (!exact or self.call_graph_exact)) return;
        if (exact) {
            if (self.call_graph) |*cg| cg.deinit(self.allocator);
            self.call_graph = null;
            self.call_graph_exact = false;
        }

        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();

        var node_path: std.ArrayList([]const u8) = .empty;
        var node_name: std.ArrayList([]const u8) = .empty;
        var node_line: std.ArrayList(u32) = .empty;
        var node_language_group: std.ArrayList(u8) = .empty;
        var funcs: std.ArrayList(codegraph.FuncInput) = .empty;
        var name_to_ids = std.StringHashMap(std.ArrayList(codegraph.NodeId)).init(a);

        var it = self.outlines.iterator();
        while (it.next()) |entry| {
            const path = entry.key_ptr.*;
            const ref = self.readContentForSearch(path, a) orelse continue;
            defer ref.deinit();
            const content = ref.data;
            const direct_import_bindings = if (exact)
                self.callGraphZigImportBindings(entry.value_ptr, content, a) catch &.{}
            else
                &.{};
            var import_bindings: std.ArrayList(codegraph.ImportBinding) = .empty;
            import_bindings.appendSlice(a, direct_import_bindings) catch return;
            const file_func_start = funcs.items.len;
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
                const body = content[start..end];
                const is_zig = exact and entry.value_ptr.language == .zig;
                const has_thread_spawn = is_zig and std.mem.indexOf(u8, body, "std.Thread.spawn") != null;
                const id: codegraph.NodeId = @intCast(node_path.items.len);
                node_path.append(a, path) catch return;
                node_name.append(a, sym.name) catch return;
                node_line.append(a, sym.line_start) catch return;
                node_language_group.append(a, callGraphLanguageGroup(detectLanguage(path))) catch return;
                funcs.append(a, .{
                    .id = id,
                    .body = body,
                    .path = path,
                    .skip_zig_multiline_strings = is_zig and std.mem.indexOf(u8, body, "\\\\") != null,
                    .extract_zig_thread_spawn_callbacks = has_thread_spawn,
                }) catch return;
                const gop = name_to_ids.getOrPut(sym.name) catch return;
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                gop.value_ptr.append(a, id) catch return;
            }
            for (funcs.items[file_func_start..]) |*func| func.imports = import_bindings.items;
        }
        const n_nodes = node_path.items.len;
        if (n_nodes == 0) return;

        var resolve = std.StringHashMap([]const codegraph.NodeId).init(a);
        var n2i = name_to_ids.iterator();
        while (n2i.next()) |e| resolve.put(e.key_ptr.*, e.value_ptr.items) catch return;

        if (exact) {
            // Only the uncommon nested receiver shape needs a preparatory
            // extraction; all other exact edges stream directly from bodies.
            for (funcs.items) |*func| {
                if (!hasNestedZigImportQualifier(func.body, func.imports)) continue;
                const calls = codegraph.extractResolvableCallees(
                    a,
                    func.body,
                    func.skip_zig_multiline_strings,
                    func.imports,
                    &resolve,
                ) catch return;
                func.preextracted_callees = calls;

                const callbacks: ?[]const codegraph.Callee = if (func.extract_zig_thread_spawn_callbacks)
                    codegraph.extractZigThreadSpawnCallbacks(a, func.body) catch return
                else
                    null;
                func.preextracted_thread_callbacks = callbacks;

                var enriched: std.ArrayList(codegraph.ImportBinding) = .empty;
                enriched.appendSlice(a, func.imports) catch return;
                self.extendCallGraphZigImportBindings(&enriched, calls, a) catch return;
                if (callbacks) |items| self.extendCallGraphZigImportBindings(&enriched, items, a) catch return;
                func.imports = enriched.items;
            }
        }

        var edges_tmp = if (exact)
            codegraph.buildEdgesScoped(
                a,
                funcs.items,
                &resolve,
                node_path.items,
                node_language_group.items,
                false,
            ) catch return
        else
            codegraph.buildEdgesApproximate(
                a,
                funcs.items,
                &resolve,
                node_language_group.items,
                false,
            ) catch return;
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
        var np_filled: usize = 0;
        for (node_path.items, 0..) |p, i| {
            np[i] = self.allocator.dupe(u8, p) catch {
                for (np[0..np_filled]) |s| self.allocator.free(s);
                self.allocator.free(np);
                self.allocator.free(edges_owned);
                codegraph.freeAdjacency(self.allocator, adj);
                return;
            };
            np_filled += 1;
        }

        const nn = self.allocator.alloc([]const u8, n_nodes) catch {
            for (np) |s| self.allocator.free(s);
            self.allocator.free(np);
            self.allocator.free(edges_owned);
            codegraph.freeAdjacency(self.allocator, adj);
            return;
        };
        var nn_filled: usize = 0;
        for (node_name.items, 0..) |nm, i| {
            nn[i] = self.allocator.dupe(u8, nm) catch {
                for (nn[0..nn_filled]) |s| self.allocator.free(s);
                self.allocator.free(nn);
                for (np) |s| self.allocator.free(s);
                self.allocator.free(np);
                self.allocator.free(edges_owned);
                codegraph.freeAdjacency(self.allocator, adj);
                return;
            };
            nn_filled += 1;
        }

        const nl = self.allocator.alloc(u32, n_nodes) catch {
            self.allocator.free(edges_owned);
            codegraph.freeAdjacency(self.allocator, adj);
            for (np) |s| self.allocator.free(s);
            self.allocator.free(np);
            for (nn) |s| self.allocator.free(s);
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
            for (np) |s| self.allocator.free(s);
            self.allocator.free(np);
            for (nn) |s| self.allocator.free(s);
            self.allocator.free(nn);
            self.allocator.free(nl);
            return;
        }
        defer self.allocator.free(node_scores.?);

        // Reverse adjacency, built once beside `adj`: queryGraphDistances
        // used to rebuild it from the edge list on every scored search
        // (O(E) list allocs per query — ~43% of an uncached ranked search).
        const radj_opt: ?[]std.ArrayList(codegraph.NodeId) = blk: {
            const lists = self.allocator.alloc(std.ArrayList(codegraph.NodeId), n_nodes) catch break :blk null;
            for (lists) |*l| l.* = .empty;
            for (edges_owned) |e| {
                if (e.from < n_nodes and e.to < n_nodes) {
                    lists[e.to].append(self.allocator, e.from) catch {
                        codegraph.freeAdjacency(self.allocator, lists);
                        break :blk null;
                    };
                }
            }
            break :blk lists;
        };
        const radj = radj_opt orelse {
            self.allocator.free(edges_owned);
            codegraph.freeAdjacency(self.allocator, adj);
            for (np) |s| self.allocator.free(s);
            self.allocator.free(np);
            for (nn) |s| self.allocator.free(s);
            self.allocator.free(nn);
            self.allocator.free(nl);
            return;
        };

        if (self.call_centrality == null) {
            var cmap = std.StringHashMap(f32).init(self.allocator);
            for (node_path.items, node_scores.?) |path, score| {
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
            .radj = radj,
            .node_path = np,
            .node_name = nn,
            .node_line = nl,
        };
        self.call_graph_exact = exact;
        // The graph-distance boost gate (`call_graph != null`) just flipped:
        // results cached before the build could differ from a fresh search.
        self.bumpSearchGen();
    }

    fn ensureCallGraph(self: *Explorer, allocator: std.mem.Allocator) void {
        self.ensureCallGraphMode(allocator, false);
    }

    fn ensureExactCallGraph(self: *Explorer, allocator: std.mem.Allocator) void {
        self.ensureCallGraphMode(allocator, true);
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
        return self.findCallPathScoped(from_name, null, to_name, null, allocator, max_hops);
    }

    /// Return every call-graph node that matches a symbol name, optionally
    /// narrowed to an exact project-relative path. Callers use this to make an
    /// ambiguous bare endpoint explicit instead of silently choosing whichever
    /// unrelated pair happens to be shortest.
    pub fn findCallPathCandidates(
        self: *Explorer,
        name: []const u8,
        path: ?[]const u8,
        allocator: std.mem.Allocator,
    ) ![]CallPathStep {
        self.ensureSymbolIndex();
        self.mu.lockShared();
        defer self.mu.unlockShared();

        self.ensureExactCallGraph(allocator);
        const cg = self.call_graph orelse return try allocator.alloc(CallPathStep, 0);

        var candidates: std.ArrayList(CallPathStep) = .empty;
        errdefer candidates.deinit(allocator);
        for (cg.node_name, 0..) |node_name, id| {
            if (!std.mem.eql(u8, node_name, name)) continue;
            if (path) |selected_path| {
                if (!std.mem.eql(u8, cg.node_path[id], selected_path)) continue;
            }
            try candidates.append(allocator, .{
                .path = cg.node_path[id],
                .name = node_name,
                .line = cg.node_line[id],
            });
        }
        return try candidates.toOwnedSlice(allocator);
    }

    /// Shortest resolved call chain with optional exact project-relative
    /// endpoint paths. The public name-only method above preserves existing
    /// callers; interactive surfaces should first inspect candidates and ask
    /// for a path when a bare name is ambiguous.
    pub fn findCallPathScoped(
        self: *Explorer,
        from_name: []const u8,
        from_path: ?[]const u8,
        to_name: []const u8,
        to_path: ?[]const u8,
        allocator: std.mem.Allocator,
        max_hops: usize,
    ) !?[]CallPathStep {
        self.ensureSymbolIndex();
        self.mu.lockShared();
        defer self.mu.unlockShared();

        self.ensureExactCallGraph(allocator);
        const cg = self.call_graph orelse return null;

        var from_ids: std.ArrayList(codegraph.NodeId) = .empty;
        defer from_ids.deinit(allocator);
        var to_ids: std.ArrayList(codegraph.NodeId) = .empty;
        defer to_ids.deinit(allocator);

        for (cg.node_name, 0..) |name, id| {
            const nid: codegraph.NodeId = @intCast(id);
            if (std.mem.eql(u8, name, from_name) and (from_path == null or std.mem.eql(u8, cg.node_path[id], from_path.?))) {
                try from_ids.append(allocator, nid);
            }
            if (std.mem.eql(u8, name, to_name) and (to_path == null or std.mem.eql(u8, cg.node_path[id], to_path.?))) {
                try to_ids.append(allocator, nid);
            }
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
        // Result-cache front door — same discipline as searchContent's
        // wrapper (gen read BEFORE the search; see that comment), but a
        // SEPARATE cache instance: the BM25 ranking returns different
        // results than searchContent for the same (query, max_results) key.
        const cacheable = max_results > 0 and query.len > 0 and query.len <= 1024 and
            cio.posixGetenv("CODEDB_NO_SEARCH_CACHE") == null;
        if (!cacheable) return self.searchContentRankedUncached(query, allocator, max_results);
        const gen = self.search_gen.load(.acquire);
        const env_fp = rankingEnvFingerprint();
        if (self.ranked_cache.get(query, max_results, gen, env_fp, allocator, &self.last_search_breakdown)) |hit| return hit;
        const res = try self.searchContentRankedUncached(query, allocator, max_results);
        self.ranked_cache.put(query, max_results, gen, env_fp, res, .{ .result_count = @intCast(@min(res.len, std.math.maxInt(u32))) });
        return res;
    }

    fn searchContentRankedUncached(self: *Explorer, query: []const u8, allocator: std.mem.Allocator, max_results: usize) ![]const SearchResult {
        // #546: BM25 reads the word index's id_to_path + ranked-doc table, which a
        // mmap/disk-loaded index lacks until rebuilt (word_index_complete = false).
        // The recall readers (searchContent, searchWord, renderWord) already trigger
        // this lazy rebuild; searchContentRanked did not — so ranked search returned
        // nothing on a cold CLI / freshly-loaded snapshot (the index served `word`,
        // but here N collapsed to 0). Rebuild before the shared lock, matching the
        // siblings — rebuildWordIndex takes the exclusive lock.
        if (max_results > 0) {
            self.mu.lockShared();
            const needs_rebuild = !self.word_index_complete and
                (self.contents.len() > 0 or (self.io != null and self.root_dir != null));
            self.mu.unlockShared();
            if (needs_rebuild) try self.rebuildWordIndex();
        }
        // #550: the graph-distance gate below reads symbol_index, which a
        // snapshot fast-load defers (#564). Identifier-shaped queries ensure it
        // here, pre-shared-lock — ensureSymbolIndex takes the exclusive lock.
        // Multi-word queries need it too: the NL→symbol bridge below matches
        // query words against split definition names.
        if (max_results > 0 and (queryNamesIdentifier(query) or
            std.mem.indexOfScalar(u8, query, ' ') != null) and
            cio.posixGetenv("CODEDB_NO_CENTRALITY") == null and
            cio.posixGetenv("CODEDB_NO_GRAPH_DISTANCE") == null)
        {
            self.ensureSymbolIndex();
            if (std.mem.indexOfScalar(u8, query, ' ') != null) self.ensureDefTokenIndex();
        }
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

        // #550: query-specific call-graph distance — boost files within a few
        // call hops of the symbols the query names. Build the graph only when a
        // raw query token exactly names a known symbol, so NL-only queries on a
        // cold CLI never pay for it; once built (warm daemon, callpath, or a
        // prior symbol-shaped query) the distances are computed from any seed.
        // CODEDB_NO_CENTRALITY disables both graph signals (ensureCallGraph
        // would repopulate call_centrality); CODEDB_NO_GRAPH_DISTANCE just this one.
        var graph_dist: ?std.StringHashMap(u8) = null;
        if (cio.posixGetenv("CODEDB_NO_CENTRALITY") == null and
            cio.posixGetenv("CODEDB_NO_GRAPH_DISTANCE") == null)
        {
            if (self.call_graph == null) {
                var gate_tok = idx.WordTokenizer{ .buf = query };
                while (gate_tok.next()) |w| {
                    if (self.symbol_index.contains(w)) {
                        self.ensureCallGraph(allocator);
                        break;
                    }
                }
            }
            graph_dist = self.queryGraphDistances(&terms_set, ta);
        }

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
            var doc_best_line = U32HashMap(struct { line: u32, count: u32 }).init(ta);
            for (hits) |h| {
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
            const df: u32 = @intCast(doc_best_line.count());
            // BM25 idf with the +1 smoothing variant: log(1 + (N - df + 0.5)/(df + 0.5))
            const num: f32 = @as(f32, @floatFromInt(N)) - @as(f32, @floatFromInt(df)) + 0.5;
            const den: f32 = @as(f32, @floatFromInt(df)) + 0.5;
            const idf: f32 = @log(1.0 + num / den);

            var tf_iter = doc_best_line.iterator();
            while (tf_iter.next()) |entry| {
                const doc_id = entry.key_ptr.*;
                const tf: f32 = @floatFromInt(entry.value_ptr.count);
                const dl_raw = self.word_index.docLength(doc_id);
                const dl: f32 = if (dl_raw == 0) 1.0 else @floatFromInt(dl_raw);
                const norm = 1.0 - b + b * (dl / avgdl);
                const tf_sat = (tf * (k1 + 1.0)) / (tf + k1 * norm);
                const term_score = idf * (tf_sat + bm25_plus_delta);

                const ln_info = entry.value_ptr.*;
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

        // #550 signal 2: git co-change. Seeds are the candidate files that
        // DEFINE a query-named symbol; without seeds the one-time `git log`
        // shell-out never happens.
        var cc_seeds = std.StringHashMap(void).init(ta);
        if (cio.posixGetenv("CODEDB_NO_COCHANGE") == null) {
            var seed_iter = per_doc.iterator();
            while (seed_iter.next()) |entry| {
                const doc_id = entry.key_ptr.*;
                const p = if (doc_id < self.word_index.id_to_path.items.len) self.word_index.id_to_path.items[doc_id] else "";
                if (p.len == 0 or cc_seeds.contains(p)) continue;
                var t_it = terms_set.keyIterator();
                while (t_it.next()) |t| {
                    if (self.fileDefinesSymbol(p, t.*)) {
                        cc_seeds.put(p, {}) catch {};
                        break;
                    }
                }
            }
            if (cc_seeds.count() > 0) self.ensureCoChange();
        }

        // NL→symbol bridge: a multi-word query whose terms cover ≥2 words of
        // a defined symbol's split name almost certainly seeks that
        // definition ("lazy symbol index rebuild" → ensureSymbolIndex).
        // Boost the defining file and point its best line at the definition,
        // so concept phrasing surfaces definitions instead of the
        // highest-word-count comment line. Query terms and splitIdentifier
        // sub-tokens are both lowercased, so plain eql matches.
        const DefOverlap = struct { overlap: u32, line: u32 };
        var def_overlap = std.StringHashMap(DefOverlap).init(ta);
        if (terms_set.count() >= 2 and self.symbol_index_complete) {
            if (self.def_token_gen != null and self.def_token_gen.? == self.search_gen.load(.acquire)) {
                // Fast path: count per-symbol term overlap through the
                // inverted token index instead of sweeping every symbol.
                var counts = std.AutoHashMap(u32, u32).init(ta);
                var t_it = terms_set.keyIterator();
                while (t_it.next()) |t| {
                    const list = self.def_token_index.get(t.*) orelse continue;
                    for (list.items) |sym_id| {
                        const gop = counts.getOrPut(sym_id) catch continue;
                        if (!gop.found_existing) gop.value_ptr.* = 0;
                        gop.value_ptr.* += 1;
                    }
                }
                var c_it = counts.iterator();
                while (c_it.next()) |ce| {
                    if (ce.value_ptr.* < 2) continue;
                    const locs = self.symbol_index.get(self.def_token_names.items[ce.key_ptr.*]) orelse continue;
                    for (locs.items) |loc| {
                        const gop = def_overlap.getOrPut(loc.path) catch continue;
                        if (!gop.found_existing or ce.value_ptr.* > gop.value_ptr.overlap) {
                            gop.value_ptr.* = .{ .overlap = ce.value_ptr.*, .line = loc.line_start };
                        }
                    }
                }
            } else {
                // Token cache stale (env-gated pre-pass skipped it, or an
                // index mutation raced): sweep the symbol index directly.
                var sym_it = self.symbol_index.iterator();
                while (sym_it.next()) |se| {
                    const sym_name = se.key_ptr.*;
                    if (sym_name.len < 5) continue;
                    var subs: std.ArrayList([]const u8) = .empty;
                    defer subs.deinit(ta);
                    idx.splitIdentifier(sym_name, &subs, ta) catch continue;
                    if (subs.items.len < 2) continue;
                    var overlap: u32 = 0;
                    var ov_it = terms_set.keyIterator();
                    while (ov_it.next()) |t| {
                        for (subs.items) |sub| {
                            if (std.mem.eql(u8, sub, t.*)) {
                                overlap += 1;
                                break;
                            }
                        }
                    }
                    if (overlap < 2) continue;
                    for (se.value_ptr.items) |loc| {
                        const gop = def_overlap.getOrPut(loc.path) catch continue;
                        if (!gop.found_existing or overlap > gop.value_ptr.overlap) {
                            gop.value_ptr.* = .{ .overlap = overlap, .line = loc.line_start };
                        }
                    }
                }
            }
        }

        const Cand = struct { doc_id: u32, score: f32, best_line: u32 };
        var cands: std.ArrayList(Cand) = .empty;
        defer cands.deinit(ta);
        try cands.ensureTotalCapacity(ta, per_doc.count());
        var pd_iter = per_doc.iterator();
        while (pd_iter.next()) |entry| {
            const cand_doc_id = entry.key_ptr.*;
            const cand_path = if (cand_doc_id < self.word_index.id_to_path.items.len) self.word_index.id_to_path.items[cand_doc_id] else "";
            var cand_score = entry.value_ptr.score *
                pathRelevanceMultiplier(cand_path, &terms_set) *
                self.centralityBoost(cand_path) *
                graphDistanceBoost(graph_dist, cand_path) *
                self.coChangeBoost(&cc_seeds, cand_path);
            var cand_best_line = entry.value_ptr.best_line;
            if (def_overlap.get(cand_path)) |dh| {
                cand_score *= 1.0 + 0.6 * @as(f32, @floatFromInt(dh.overlap));
                cand_best_line = dh.line;
            }
            cands.appendAssumeCapacity(.{
                .doc_id = cand_doc_id,
                .score = cand_score,
                .best_line = cand_best_line,
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
            // Resolve the hit line via the line-offset cache (O(log n)) with
            // the scan-from-zero extractLineByNumber as fallback — the same
            // swap the exact-recall tiers made in #611 and the context sites
            // phase made in #646. On real repos this was up to max_results
            // whole-file walks per ranked query.
            var span1: [1]LineOffsetCache.Span = undefined;
            const lines1 = [1]u32{c.best_line};
            const line_text = blk: {
                if (self.line_offsets.lineSpans(path, ref.data, lines1[0..], span1[0..])) |n| {
                    if (n == 1) break :blk ref.data[span1[0].start..span1[0].end];
                    break :blk null;
                }
                break :blk extractLineByNumber(ref.data, c.best_line);
            } orelse continue;
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

    /// Query-shape-aware search shared by the CLI (`runQuery`, used by both the
    /// cold path and the warm cli-daemon) and the MCP `search` handler so the two
    /// rank identically. A multi-word query expresses conceptual/NL intent and
    /// routes to BM25 + centrality (`searchContentRanked`); a single token keeps
    /// literal substring matching (`searchContent`) so exact-identifier lookups
    /// still work. #546: the CLI path previously always called the unranked
    /// `searchContent`, so multi-word CLI/daemon searches never reached the ranker.
    pub fn searchContentAuto(self: *Explorer, query: []const u8, allocator: std.mem.Allocator, max_results: usize) ![]const SearchResult {
        const multiword = std.mem.indexOfScalar(u8, query, ' ') != null;
        return if (multiword)
            self.searchContentRanked(query, allocator, max_results)
        else
            self.searchContent(query, allocator, max_results);
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
        var shared_locked = true;
        defer if (shared_locked) self.mu.unlockShared();

        const needs_rebuild = !self.word_index_complete and
            (self.contents.len() > 0 or (self.io != null and self.root_dir != null));
        if (needs_rebuild) {
            self.mu.unlockShared();
            shared_locked = false;
            try self.rebuildWordIndex();
            self.mu.lockShared();
            shared_locked = true;
        }
        // #569: a multi-word query can never be a single index token — fall back
        // to per-token matching so phrase-shaped queries don't silently dead-end.
        if (std.mem.indexOfScalar(u8, word, ' ') != null) {
            return self.searchWordTokensLocked(word, allocator);
        }
        return self.word_index.searchDeduped(word, allocator);
    }

    /// Per-token fallback for a whitespace-separated query (#569): each distinct
    /// token is looked up in the word index and files are ranked by how many
    /// distinct tokens they hit, then total hits, then path. Returns one
    /// representative hit (lowest matching line) per file, allocated for the
    /// caller. Caller must hold the shared lock.
    fn searchWordTokensLocked(self: *Explorer, query: []const u8, allocator: std.mem.Allocator) ![]const idx.WordHit {
        var scratch = std.heap.ArenaAllocator.init(allocator);
        defer scratch.deinit();
        const sa = scratch.allocator();

        const Agg = struct { distinct: u32, total: u32, line: u32, last_token: u32 };
        var per_doc = U32HashMap(Agg).init(sa);

        var seen_tokens = std.StringHashMap(void).init(sa);
        var token_serial: u32 = 0;
        var tok = idx.WordTokenizer{ .buf = query };
        while (tok.next()) |raw| {
            if (raw.len < 2) continue;
            const lower = try sa.alloc(u8, raw.len);
            for (raw, 0..) |c, i| lower[i] = idx.normalizeChar(c);
            const tok_gop = try seen_tokens.getOrPut(lower);
            if (tok_gop.found_existing) continue;
            token_serial += 1;
            for (self.word_index.search(lower)) |h| {
                const gop = try per_doc.getOrPut(h.doc_id);
                if (!gop.found_existing) {
                    gop.value_ptr.* = .{ .distinct = 1, .total = 1, .line = h.line_num, .last_token = token_serial };
                } else {
                    gop.value_ptr.total += 1;
                    if (gop.value_ptr.last_token != token_serial) {
                        gop.value_ptr.distinct += 1;
                        gop.value_ptr.last_token = token_serial;
                    }
                    if (h.line_num < gop.value_ptr.line) gop.value_ptr.line = h.line_num;
                }
            }
        }
        if (per_doc.count() == 0) return try allocator.alloc(idx.WordHit, 0);

        const Ranked = struct { doc_id: u32, distinct: u32, total: u32, line: u32 };
        const ranked = try sa.alloc(Ranked, per_doc.count());
        var it = per_doc.iterator();
        var n: usize = 0;
        while (it.next()) |e| : (n += 1) {
            ranked[n] = .{ .doc_id = e.key_ptr.*, .distinct = e.value_ptr.distinct, .total = e.value_ptr.total, .line = e.value_ptr.line };
        }
        const SortCtx = struct {
            wi: *const idx.WordIndex,
            fn lessThan(ctx: @This(), a: Ranked, b: Ranked) bool {
                if (a.distinct != b.distinct) return a.distinct > b.distinct;
                if (a.total != b.total) return a.total > b.total;
                const pa = ctx.wi.hitPath(.{ .doc_id = a.doc_id, .line_num = 0 });
                const pb = ctx.wi.hitPath(.{ .doc_id = b.doc_id, .line_num = 0 });
                return std.mem.lessThan(u8, pa, pb);
            }
        };
        std.mem.sort(Ranked, ranked, SortCtx{ .wi = &self.word_index }, SortCtx.lessThan);

        const out_hits = try allocator.alloc(idx.WordHit, ranked.len);
        for (ranked, 0..) |r, i| out_hits[i] = .{ .doc_id = r.doc_id, .line_num = r.line };
        return out_hits;
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

        // #569: multi-word queries fall back to per-token matching — one line
        // per file, files hitting more distinct tokens first.
        if (std.mem.indexOfScalar(u8, word, ' ') != null) {
            const hits = try self.searchWordTokensLocked(word, allocator);
            defer allocator.free(hits);
            try out.ensureUnusedCapacity(allocator, 64 + hits.len * 48);
            const w = cio.listWriter(out, allocator);
            try w.print("{d} hits for '{s}' (tokenized):\n", .{ hits.len, word });
            for (hits) |h| {
                try w.print("  {s}:{d}\n", .{ self.word_index.hitPath(h), h.line_num });
            }
            return;
        }

        const gen = self.search_gen.load(.acquire);
        if (self.word_render_cache.render(word, false, gen, allocator, out)) return;
        const render_start = out.items.len;
        const hits = self.word_index.search(word);
        try out.ensureUnusedCapacity(allocator, 64 + hits.len * 48);
        const w = cio.listWriter(out, allocator);
        try w.print("{d} hits for '{s}':\n", .{ hits.len, word });
        for (hits) |h| {
            try w.print("  {s}:{d}\n", .{ self.word_index.hitPath(h), h.line_num });
        }
        self.word_render_cache.put(word, false, gen, out.items[render_start..]);
    }

    pub const FuzzyMatch = FuzzyFileMatch;

    pub fn fuzzyFindFiles(self: *Explorer, query: []const u8, allocator: std.mem.Allocator, max_results: usize) ![]const FuzzyMatch {
        if (query.len == 0) return &.{};

        self.mu.lockShared();
        defer self.mu.unlockShared();
        const gen = self.search_gen.load(.acquire);
        if (self.fuzzy_file_cache.get(query, max_results, gen, allocator)) |cached| return cached;

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

        const result = matches.toOwnedSlice(allocator) catch {
            matches.deinit(allocator);
            return &.{};
        };
        self.fuzzy_file_cache.put(query, max_results, gen, result);
        return result;
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
        // A bare import resolved only by basename is ambiguous when 2+ indexed files
        // share that basename; disable the basename fallback in that case so it is not
        // attributed to every same-basename file (e.g. a/conf.py and b/conf.py).
        const basename = if (std.mem.lastIndexOfScalar(u8, path, '/')) |pos| path[pos + 1 ..] else path;
        var basename_count: usize = 0;
        var it = self.outlines.keyIterator();
        while (it.next()) |k| {
            const kb = if (std.mem.lastIndexOfScalar(u8, k.*, '/')) |p| k.*[p + 1 ..] else k.*;
            if (std.mem.eql(u8, kb, basename)) basename_count += 1;
        }
        return self.dep_graph.getImportedByFiltered(path, allocator, basename_count <= 1);
    }

    pub fn renderImportedBy(self: *Explorer, path: []const u8, allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !struct { count: usize, known: bool } {
        self.mu.lockShared();
        defer self.mu.unlockShared();

        const basename = if (std.mem.lastIndexOfScalar(u8, path, '/')) |pos| path[pos + 1 ..] else path;
        // #588: mirror getImportedBy — a bare import resolved only by basename
        // is ambiguous when 2+ indexed files share the basename; skip the
        // fallback rather than attribute it to every candidate.
        var basename_count: usize = 0;
        var bit = self.outlines.keyIterator();
        while (bit.next()) |k| {
            const kb = if (std.mem.lastIndexOfScalar(u8, k.*, '/')) |p| k.*[p + 1 ..] else k.*;
            if (std.mem.eql(u8, kb, basename)) basename_count += 1;
        }
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

        if (basename_count <= 1 and !std.mem.eql(u8, path, basename)) {
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
            if (startsWith(line, "from ")) {
                // "from mypackage.utils import X" -> mypackage/utils.py (single module dep)
                if (extractPythonModulePath(line)) |mod_path| {
                    try appendPythonModuleDep(a, outline, mod_path);
                }
            } else {
                // "import a, b.c, d as e" -- record one dep per comma-separated module.
                const rest = std.mem.trimStart(u8, line[7..], " \t");
                var it = std.mem.splitScalar(u8, rest, ',');
                while (it.next()) |raw| {
                    var mod = std.mem.trim(u8, raw, " \t");
                    if (std.mem.indexOf(u8, mod, " as ")) |as_pos| mod = std.mem.trimEnd(u8, mod[0..as_pos], " \t");
                    if (std.mem.indexOfScalar(u8, mod, ' ')) |sp| mod = mod[0..sp];
                    if (mod.len == 0 or mod[0] == '.') continue;
                    try appendPythonModuleDep(a, outline, mod);
                }
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
        if (startsWith(line, "import ") or containsAny(line, &.{"require("})) {
            try appendOutlineSymbol(a, outline, line, .import, line_num, null);
            if (extractStringLiteral(line)) |path| {
                try appendImportPath(a, outline, path);
            }
        } else if (startsWith(line, "} from ") or
            (startsWith(line, "export ") and containsAny(line, &.{ " from \"", " from '" })))
        {
            // Closing line of a multi-line import/export, e.g.
            //   import {
            //     a, b,
            //   } from "../mod.ts";
            // or a re-export like `export * from "./x.ts"`. The `from "..."`
            // clause lands on a line that does not contain "import ", so without
            // this branch the path is dropped (only single-line imports were
            // captured). Gated on these concrete shapes so arbitrary `from "..."`
            // inside strings/comments (e.g. SQL `select * from "users"`) is not
            // mistaken for a dependency.
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
        } else if (swiftSpecialMethodName(line)) |name| {
            try appendOutlineSymbol(a, outline, name, .method, line_num, line);
        }
    }

    /// Swift initializers are declarations, but unlike ordinary methods their
    /// identifier is the language keyword itself. Keep them in the outline as
    /// methods so constructor lookups and call-graph bodies behave like other
    /// member functions. The prefix guard rejects expression uses such as
    /// `super.init()` and `value = Type.init`.
    fn swiftSpecialMethodName(line: []const u8) ?[]const u8 {
        const names = [_][]const u8{ "deinit", "init" };
        for (names) |name| {
            var search_from: usize = 0;
            while (std.mem.indexOfPos(u8, line, search_from, name)) |pos| {
                search_from = pos + name.len;
                if (pos > 0 and isIdentChar(line[pos - 1])) continue;
                const after_name = pos + name.len;
                if (after_name < line.len and isIdentChar(line[after_name])) continue;
                if (!isSwiftDeclarationPrefix(line[0..pos])) continue;

                var cursor = after_name;
                if (std.mem.eql(u8, name, "init") and cursor < line.len and
                    (line[cursor] == '?' or line[cursor] == '!')) cursor += 1;
                while (cursor < line.len and (line[cursor] == ' ' or line[cursor] == '\t')) cursor += 1;
                if (std.mem.eql(u8, name, "init")) {
                    if (cursor < line.len and line[cursor] == '(') return name;
                } else if (cursor >= line.len or line[cursor] == '{') {
                    return name;
                }
            }
        }
        return null;
    }

    fn isSwiftDeclarationPrefix(prefix: []const u8) bool {
        for (prefix) |ch| {
            // Modifiers and attributes are fine; punctuation that starts an
            // expression is not. This deliberately remains permissive for
            // future Swift modifiers.
            if (ch == '.' or ch == '=' or ch == '(' or ch == ')' or ch == ';') return false;
        }
        return true;
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

    /// OCaml (.ml / .mli).
    /// `open`/`include` → import; `module` → struct_def, `module type` → interface_def;
    /// `type` → type_alias; `external` → function; `exception` → enum_def;
    /// `val` → function (.mli value signature); `let`/`and` → function (→ present in line
    /// or RHS starts with `fun `/`function`) else constant.
    /// Leading attributes ([@@...], [@...], [@@@...]) are stripped first.
    fn parseOcamlLine(self: *Explorer, line: []const u8, line_num: u32, outline: *FileOutline) !void {
        const a = self.allocator;
        const code = stripLeadingOcamlAttributes(line);
        if (code.len == 0) return;

        if (startsWith(code, "open ")) {
            const name = ocamlModulePath(std.mem.trimStart(u8, code[5..], " \t"));
            if (name.len > 0) {
                try appendImportPath(a, outline, name);
                try appendOutlineSymbol(a, outline, name, .import, line_num, null);
            }
            return;
        }
        if (startsWith(code, "include ")) {
            const name = ocamlModulePath(std.mem.trimStart(u8, code[8..], " \t"));
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
            const name = ocamlIdent(rest);
            if (name.len > 0) try appendOutlineSymbol(a, outline, name, kind, line_num, line);
            return;
        }
        if (startsWith(code, "type ")) {
            var rest = std.mem.trimStart(u8, code[5..], " \t");
            if (startsWith(rest, "rec ")) rest = std.mem.trimStart(u8, rest[4..], " \t");
            const name = ocamlIdent(rest);
            if (name.len > 0) try appendOutlineSymbol(a, outline, name, .type_alias, line_num, line);
            return;
        }
        if (startsWith(code, "external ")) {
            const name = ocamlIdent(std.mem.trimStart(u8, code[9..], " \t"));
            if (name.len > 0) try appendOutlineSymbol(a, outline, name, .function, line_num, line);
            return;
        }
        if (startsWith(code, "exception ")) {
            const name = ocamlIdent(std.mem.trimStart(u8, code[10..], " \t"));
            if (name.len > 0) try appendOutlineSymbol(a, outline, name, .enum_def, line_num, line);
            return;
        }
        if (startsWith(code, "val ")) {
            // .mli value signature
            const name = ocamlIdent(std.mem.trimStart(u8, code[4..], " \t"));
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
        const name = ocamlIdent(rest);
        if (name.len == 0) return;
        // Heuristic: if the line contains ->, or the RHS after = begins with fun / function, treat as function.
        const kind: SymbolKind = if (std.mem.indexOf(u8, code, "->") != null) .function else blk: {
            if (std.mem.indexOfScalar(u8, code, '=')) |eq_pos| {
                const rhs = std.mem.trimStart(u8, code[eq_pos + 1 ..], " \t");
                if (startsWith(rhs, "fun ") or startsWith(rhs, "function")) break :blk .function;
            }
            break :blk .constant;
        };
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
            const dep = (try resolveDependencyKey(&self.dep_graph, outline.path, imp, self.allocator)) orelse continue;
            const gop = try seen.getOrPut(dep);
            if (gop.found_existing) continue;
            try deps.append(self.allocator, dep);
        }

        try self.dep_graph.setDeps(path, deps);
    }

    fn rebuildDocumentDepsFor(self: *Explorer, path: []const u8, outline: *const FileOutline) !void {
        var deps: std.ArrayList([]const u8) = .empty;
        errdefer deps.deinit(self.allocator);
        try deps.ensureTotalCapacity(self.allocator, outline.document_links.items.len);

        var seen = std.StringHashMap(void).init(self.allocator);
        defer seen.deinit();

        for (outline.document_links.items) |link| {
            // Extraction already rejects absolute and out-of-root paths. Keep
            // only exact, case-sensitive targets that are currently indexed.
            if (!self.outlines.contains(link.target)) continue;
            const stable_target = try self.document_graph.internString(link.target);
            const gop = try seen.getOrPut(stable_target);
            if (gop.found_existing) continue;
            deps.appendAssumeCapacity(stable_target);
        }

        const stable_path = try self.document_graph.internString(path);
        try self.document_graph.setDeps(stable_path, deps);
    }

    fn refreshDocumentLinksTo(self: *Explorer, target: []const u8) !void {
        var iter = self.outlines.iterator();
        while (iter.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, target)) continue;
            const outline = entry.value_ptr;
            if (outline.language != .markdown) continue;
            for (outline.document_links.items) |link| {
                if (!std.mem.eql(u8, link.target, target)) continue;
                try self.rebuildDocumentDepsFor(entry.key_ptr.*, outline);
                break;
            }
        }
    }

    /// Rebuild after bulk restore, where source files may have been inserted
    /// before their exact Markdown targets existed in the outline map.
    pub fn rebuildDocumentGraph(self: *Explorer) !void {
        self.document_graph.deinit();
        self.document_graph = DependencyGraph.init(self.allocator);
        var iter = self.outlines.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.language != .markdown) continue;
            try self.rebuildDocumentDepsFor(entry.key_ptr.*, entry.value_ptr);
        }
    }

    pub fn rebuildSymbolIndexFor(self: *Explorer, path: []const u8, outline: *FileOutline, had_prior: bool) void {
        // #564: while the index is deferred (snapshot fast-load), per-file
        // rebuilds are wasted work — ensureSymbolIndex rebuilds everything from
        // outlines on first use. ensureSymbolIndex flips the flag back BEFORE
        // calling this, so its own rebuild passes the guard.
        if (!self.symbol_index_complete) return;
        // removeSymbolIndexFor scans the entire global symbol index, so calling
        // it per file makes a cold scan O(files * total_symbols). A brand-new
        // path has no prior entries to evict, so skip the scan entirely — only
        // re-indexed (already-present) files need the removal.
        if (had_prior) self.removeSymbolIndexFor(path);
        for (outline.symbols.items) |sym| {
            const gop = self.symbol_index.getOrPut(sym.name) catch continue;
            if (!gop.found_existing) {
                // The map owns its keys: sym.name belongs to the outline and
                // dies with it on re-index, while shared-name entries survive.
                const owned = self.allocator.dupe(u8, sym.name) catch {
                    _ = self.symbol_index.remove(sym.name);
                    continue;
                };
                gop.key_ptr.* = owned;
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
                // Deinit only at actual removal below: ArrayList.deinit poisons
                // the in-map value, so a failed append here must leave a VALID
                // (empty) list behind, not a landmine for the next iteration.
                to_remove.append(self.allocator, entry.key_ptr.*) catch {};
            }
        }
        for (to_remove.items) |key| {
            if (self.symbol_index.fetchRemove(key)) |kv| {
                var hits = kv.value;
                hits.deinit(self.allocator);
                self.allocator.free(kv.key);
            }
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
    line_prefix: []const u8,
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
            try w.print("{s}{d:>5} | {s}\n", .{ line_prefix, line_num, line });
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
        .ocaml => std.mem.startsWith(u8, trimmed, "(*"),
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
    // Anchor the scan on the needle's RAREST byte (see code_char_freq) — for
    // common-first-letter words this cuts verify calls by an order of
    // magnitude versus always anchoring on byte 0. A match starting at s has
    // its anchor at s + anchor, so candidate positions live in
    // [anchor, end + anchor).
    var anchor: usize = 0;
    var anchor_rarity: u8 = std.math.maxInt(u8);
    for (query_lower, 0..) |c, j| {
        if (code_char_freq[c] < anchor_rarity) {
            anchor_rarity = code_char_freq[c];
            anchor = j;
        }
    }
    const anchor_lower: u8 = query_lower[anchor];
    const anchor_upper: u8 = if (anchor_lower >= 'a' and anchor_lower <= 'z') anchor_lower - 32 else anchor_lower;
    var file_hits: usize = 0;
    const end = content.len - query.len + 1;
    const scan_end = end + anchor;
    var pos: usize = anchor;

    // Track line number incrementally.
    var current_line: u32 = 1;
    var current_line_start: usize = 0;

    // SIMD constants — 32-byte vectors (2x NEON / 1x AVX2 per compare).
    const VW = 32;
    const Vec = @Vector(VW, u8);
    const splat_lo: Vec = @splat(anchor_lower);
    const splat_hi: Vec = @splat(anchor_upper);

    scan: while (pos < scan_end) {
        // ── SIMD path: process full chunks ──
        if (pos + VW <= scan_end) {
            const chunk: Vec = content[pos..][0..VW].*;
            const eq_lo: @Vector(VW, u1) = @bitCast(chunk == splat_lo);
            const eq_hi: @Vector(VW, u1) = @bitCast(chunk == splat_hi);
            var mask: u32 = @bitCast(eq_lo | eq_hi);

            if (mask == 0) {
                pos += VW;
                continue;
            }

            // Process ALL anchor candidates in this chunk without reloading.
            while (mask != 0) {
                const offset: usize = @ctz(mask);
                const cand = pos + offset;
                if (cand >= scan_end) break;
                const start = cand - anchor;

                if (matchAtCaseInsensitive(content, start, query_lower)) {
                    // ── Match found ──
                    while (current_line_start < start) {
                        if (simdIndexOfNewline(content, current_line_start)) |nl| {
                            if (nl < start) {
                                current_line += 1;
                                current_line_start = nl + 1;
                            } else break;
                        } else break;
                    }
                    const line_start = current_line_start;
                    const line_end = simdIndexOfNewline(content, start) orelse content.len;

                    const line_text = try allocator.dupe(u8, content[line_start..line_end]);
                    errdefer allocator.free(line_text);
                    const path_copy = try allocator.dupe(u8, path);
                    errdefer allocator.free(path_copy);
                    try result_list.append(allocator, .{ .path = path_copy, .line_num = current_line, .line_text = line_text });
                    file_hits += 1;
                    if (file_hits >= max_per_file or result_list.items.len >= max_results) return;

                    current_line += 1;
                    current_line_start = line_end + 1;
                    // One result per line: the next match must START after
                    // the line, so its anchor sits at least `anchor` later.
                    pos = line_end + 1 + anchor;
                    if (pos >= scan_end) return;
                    continue :scan;
                }
                mask &= mask - 1; // clear lowest bit, try next candidate in chunk
            }
            pos += VW; // all candidates were false positives
            continue;
        }

        // ── Scalar tail for the last <VW bytes ──
        const c = content[pos];
        if (c == anchor_lower or c == anchor_upper) {
            const start = pos - anchor;
            if (matchAtCaseInsensitive(content, start, query_lower)) {
                while (current_line_start < start) {
                    if (simdIndexOfNewline(content, current_line_start)) |nl| {
                        if (nl < start) {
                            current_line += 1;
                            current_line_start = nl + 1;
                        } else break;
                    } else break;
                }
                const line_start = current_line_start;
                const line_end = simdIndexOfNewline(content, start) orelse content.len;

                const line_text = try allocator.dupe(u8, content[line_start..line_end]);
                errdefer allocator.free(line_text);
                const path_copy = try allocator.dupe(u8, path);
                errdefer allocator.free(path_copy);
                try result_list.append(allocator, .{ .path = path_copy, .line_num = current_line, .line_text = line_text });
                file_hits += 1;
                if (file_hits >= max_per_file or result_list.items.len >= max_results) return;

                current_line += 1;
                current_line_start = line_end + 1;
                pos = line_end + 1 + anchor;
                continue;
            }
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

/// Rough frequency of each lowercase byte in source code, used only to pick
/// the SIMD anchor inside indexOfCaseInsensitive — lower is rarer. Anchor
/// choice never affects correctness, only how often candidates verify.
const code_char_freq: [256]u8 = blk: {
    var t: [256]u8 = @splat(3);
    const ranks = "zqjxkvbywgpfmucdlhrsnioate";
    for (ranks, 0..) |c, i| t[c] = @intCast(i + 4);
    for ('0'..'9' + 1) |c| t[c] = 5;
    t['_'] = 20;
    t['.'] = 14;
    break :blk t;
};

fn indexOfCaseInsensitive(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;

    const end = haystack.len - needle.len + 1;

    if (needle.len == 1) {
        const c = needle[0];
        const lower: u8 = if (c >= 'A' and c <= 'Z') c + 32 else c;
        const upper: u8 = if (lower >= 'a' and lower <= 'z') lower - 32 else lower;
        const chars = [2]u8{ lower, upper };
        return std.mem.indexOfAny(u8, haystack, &chars);
    }

    // Jump between candidates of the needle's RAREST byte with the
    // vectorized indexOfAnyPos instead of walking byte-by-byte — content
    // scans (searchInContent, Tier 1 candidate verification) spend most of
    // their time here, and anchoring on a rare letter (a 'k' or 'x') rather
    // than position 0 keeps the verify rate low for common-first-letter words.
    var anchor: usize = 0;
    var anchor_freq: u8 = std.math.maxInt(u8);
    for (needle, 0..) |c, j| {
        const cl: u8 = if (c >= 'A' and c <= 'Z') c + 32 else c;
        if (code_char_freq[cl] < anchor_freq) {
            anchor_freq = code_char_freq[cl];
            anchor = j;
        }
    }
    const ac = needle[anchor];
    const anchor_lower: u8 = if (ac >= 'A' and ac <= 'Z') ac + 32 else ac;
    const anchor_upper: u8 = if (anchor_lower >= 'a' and anchor_lower <= 'z') anchor_lower - 32 else anchor_lower;
    const anchor_chars = [2]u8{ anchor_lower, anchor_upper };

    // A match starting at s puts the anchor at s + anchor, so anchor
    // candidates live in [anchor, end + anchor).
    const scan = haystack[0 .. end - 1 + anchor + 1];
    var i: usize = anchor;
    while (std.mem.indexOfAnyPos(u8, scan, i, &anchor_chars)) |pos| {
        i = pos + 1;
        const start = pos - anchor;
        var match = true;
        for (needle, 0..) |nc0, j| {
            const hc = haystack[start + j];
            const hl: u8 = if (hc >= 'A' and hc <= 'Z') hc + 32 else hc;
            const nl: u8 = if (nc0 >= 'A' and nc0 <= 'Z') nc0 + 32 else nc0;
            if (hl != nl) {
                match = false;
                break;
            }
        }
        if (match) return start;
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
    while (iter.next()) |seg| if (std.mem.eql(u8, seg, segment)) return true;
    return false;
}

fn pathHasSegmentIgnoreCase(path: []const u8, segment: []const u8) bool {
    var iter = std.mem.tokenizeAny(u8, path, "/\\");
    while (iter.next()) |seg| if (asciiEqlIgnoreCase(seg, segment)) return true;
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
    outline.name_len_mask |= FileOutline.nameLenBit(name_copy.len);
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

inline fn ocamlIsIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}
inline fn ocamlIsIdentChar(c: u8) bool {
    return ocamlIsIdentStart(c) or (c >= '0' and c <= '9') or c == '\'';
}
/// Leading OCaml identifier (letter/_/digit/prime), or "" if none.
fn ocamlIdent(s: []const u8) []const u8 {
    if (s.len == 0 or !ocamlIsIdentStart(s[0])) return "";
    var i: usize = 1;
    while (i < s.len and ocamlIsIdentChar(s[i])) i += 1;
    return s[0..i];
}
/// Leading dotted module path (Foo.Bar.Baz), trailing dots trimmed, or "".
fn ocamlModulePath(s: []const u8) []const u8 {
    if (s.len == 0 or !ocamlIsIdentStart(s[0])) return "";
    var i: usize = 1;
    while (i < s.len and (ocamlIsIdentChar(s[i]) or s[i] == '.')) i += 1;
    var end = i;
    while (end > 0 and s[end - 1] == '.') end -= 1;
    return s[0..end];
}
/// Strip leading OCaml attributes ([@@...], [@...], [@@@...]) and trailing space.
fn stripLeadingOcamlAttributes(line: []const u8) []const u8 {
    var s = std.mem.trimStart(u8, line, " \t");
    while (s.len > 0 and s[0] == '[') {
        // Check for attribute forms: [@@, [@@@, [@ (with at least one @ after [)
        const after_bracket = s[1..];
        if (after_bracket.len == 0) break;
        if (after_bracket[0] != '@') break;
        // Walk past the closing ]
        var i: usize = 2;
        while (i < s.len and s[i] != ']') i += 1;
        if (i >= s.len) break; // unclosed — bail out
        s = std.mem.trimStart(u8, s[i + 1 ..], " \t");
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
    // Strip a trailing `as <alias>` (Kotlin/Swift aliased import: `import X as Y`) so the
    // dep key is the imported path X, not "X as Y".
    if (std.mem.indexOf(u8, body, " as ")) |as_pos| body = body[0..as_pos];
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
    for (keywords) |kw| if (std.mem.eql(u8, name, kw)) return true;
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
    for (keywords) |kw| if (std.mem.eql(u8, s, kw)) return true;
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
    // `parts` holds borrowed slices into `path`; free the list on every path
    // (success included). Previously errdefer-only, which leaked on success.
    defer parts.deinit(allocator);

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

fn isRelativeImport(spec: []const u8) bool {
    return std.mem.startsWith(u8, spec, "./") or std.mem.startsWith(u8, spec, "../");
}

/// File extension of a path including the leading dot (".ts"), or null if the
/// final segment has none. A leading-dot file (".env") counts as no extension.
fn pathExtension(path: []const u8) ?[]const u8 {
    const base = if (std.mem.lastIndexOfScalar(u8, path, '/')) |s| path[s + 1 ..] else path;
    if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| {
        if (dot > 0) return base[dot..];
    }
    return null;
}

/// Resolve a relative import specifier (`./` or `../`) against the importing
/// file's path into a repo-rooted path, e.g.
///   ("daemon/src/role/role-driver.ts", "../bus/x.ts") -> "daemon/src/bus/x.ts"
/// Returns null if the path escapes the repo root or allocation fails. The
/// caller owns the returned slice (allocated with `allocator`).
fn resolveRelativeImportPath(file_path: []const u8, raw: []const u8, allocator: std.mem.Allocator) ?[]const u8 {
    const dir = if (std.mem.lastIndexOfScalar(u8, file_path, '/')) |sep|
        file_path[0..sep]
    else
        ".";
    const joined = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, raw }) catch return null;
    defer allocator.free(joined);
    return normalizePath(joined, allocator);
}

/// Map a raw import specifier to the dependency key the graph should store:
///   - relative (./ ../) specifiers resolve to repo paths, interned in the
///     graph arena (so they outlive the call without mutating outline.imports);
///   - any other specifier containing ".." can't map to a repo path -> null (skip);
///   - everything else is returned as-is (borrowed from the caller).
/// Shared by Explorer.rebuildDepsFor and the snapshot restore path so the two
/// never diverge. `tmp_allocator` is only used for transient resolution scratch.
pub fn resolveDependencyKey(
    dep_graph: *DependencyGraph,
    importer_path: []const u8,
    spec: []const u8,
    tmp_allocator: std.mem.Allocator,
) !?[]const u8 {
    if (isRelativeImport(spec)) {
        const tmp = resolveRelativeImportPath(importer_path, spec, tmp_allocator) orelse return null;
        defer tmp_allocator.free(tmp);
        // Extensionless imports ("../foo") are common in TS/JS. The resolved
        // path then has no extension and won't match the indexed file
        // ("dir/foo.ts"). Assume the importer's own extension (TS importing TS,
        // JS importing JS) so the key lines up with the real file. Specifiers
        // that already carry an extension are left as-is.
        if (pathExtension(tmp) == null) {
            if (pathExtension(importer_path)) |ext| {
                const with_ext = std.fmt.allocPrint(tmp_allocator, "{s}{s}", .{ tmp, ext }) catch
                    return try dep_graph.internString(tmp);
                defer tmp_allocator.free(with_ext);
                return try dep_graph.internString(with_ext);
            }
        }
        return try dep_graph.internString(tmp);
    }
    if (std.mem.indexOf(u8, spec, "..") != null) return null;
    return spec;
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
    for (needles) |needle| if (std.mem.indexOf(u8, s, needle) != null) return true;
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
        // "from module.path import ..." -- extract up to " import"
        if (std.mem.indexOf(u8, rest, " import")) |imp_pos| {
            const mod = std.mem.trimEnd(u8, rest[0..imp_pos], " \t");
            if (mod.len > 0) return mod;
        }
        return null;
    } else if (startsWith(line, "import ")) {
        const rest = std.mem.trimStart(u8, line[7..], " \t");
        // "import os.path" or "import foo" -- take up to comma or space
        var end: usize = 0;
        while (end < rest.len and rest[end] != ' ' and rest[end] != ',' and rest[end] != '\t') : (end += 1) {}
        if (end > 0) return rest[0..end];
        return null;
    }
    return null;
}

// Convert a Python module path (`os.path`, `mypackage.utils`) to a repo-style dep key
// (`os/path.py`) and record it on the outline. Shared by the `from` branch and the
// comma-split `import a, b` branch in parsePythonLine.
fn appendPythonModuleDep(a: std.mem.Allocator, outline: *FileOutline, mod_path: []const u8) !void {
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
    for (specials) |s| if (std.mem.eql(u8, filename, s)) return true;
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
    var present: [256]bool = @splat(false);
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
    var lens: [FZ_LANES]usize = @splat(0);
    var len_arr: [FZ_LANES]u32 = @splat(0);
    var fname_arr: [FZ_LANES]u32 = @splat(0);
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
        var lo: [FZ_LANES]u8 = @splat(0);
        var orig: [FZ_LANES]u8 = @splat(0);
        var wbf: [FZ_LANES]bool = @splat(false);
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
