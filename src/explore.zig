const std = @import("std");
const Store = @import("store.zig").Store;
const idx = @import("index.zig");
const WordIndex = idx.WordIndex;
const TrigramIndex = idx.TrigramIndex;

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
    symbols: std.ArrayList(Symbol) = .{},
    imports: std.ArrayList([]const u8) = .{},
    imported_by: std.ArrayList([]const u8) = .{},
    allocator: std.mem.Allocator,
    owns_path: bool = false,

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
        for (self.symbols.items) |sym| {
            self.allocator.free(sym.name);
            if (sym.detail) |d| self.allocator.free(d);
        }
        self.symbols.deinit(self.allocator);
        for (self.imports.items) |imp| self.allocator.free(imp);
        self.imports.deinit(self.allocator);
        self.imported_by.deinit(self.allocator);
    }
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
    markdown,
    json,
    yaml,
    unknown,
};

fn detectLanguage(path: []const u8) Language {
    if (std.mem.endsWith(u8, path, ".zig")) return .zig;
    if (std.mem.endsWith(u8, path, ".c") or std.mem.endsWith(u8, path, ".h")) return .c;
    if (std.mem.endsWith(u8, path, ".cpp") or std.mem.endsWith(u8, path, ".hpp")) return .cpp;
    if (std.mem.endsWith(u8, path, ".py")) return .python;
    if (std.mem.endsWith(u8, path, ".js") or std.mem.endsWith(u8, path, ".jsx")) return .javascript;
    if (std.mem.endsWith(u8, path, ".ts") or std.mem.endsWith(u8, path, ".tsx")) return .typescript;
    if (std.mem.endsWith(u8, path, ".rs")) return .rust;
    if (std.mem.endsWith(u8, path, ".go")) return .go_lang;
    if (std.mem.endsWith(u8, path, ".md")) return .markdown;
    if (std.mem.endsWith(u8, path, ".json")) return .json;
    if (std.mem.endsWith(u8, path, ".yaml") or std.mem.endsWith(u8, path, ".yml")) return .yaml;
    return .unknown;
}

pub const SymbolResult = struct {
    path: []const u8,
    symbol: Symbol,
};

pub const SearchResult = struct {
    path: []const u8,
    line_num: u32,
    line_text: []const u8,
};

pub const Explorer = struct {
    outlines: std.StringHashMap(FileOutline),
    dep_graph: std.StringHashMap(std.ArrayList([]const u8)),
    contents: std.StringHashMap([]const u8),
    word_index: WordIndex,
    trigram_index: TrigramIndex,
    allocator: std.mem.Allocator,
    mu: std.Thread.RwLock = .{},

    pub fn init(allocator: std.mem.Allocator) Explorer {
        return .{
            .outlines = std.StringHashMap(FileOutline).init(allocator),
            .dep_graph = std.StringHashMap(std.ArrayList([]const u8)).init(allocator),
            .contents = std.StringHashMap([]const u8).init(allocator),
            .word_index = WordIndex.init(allocator),
            .trigram_index = TrigramIndex.init(allocator),
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

        var dep_iter = self.dep_graph.iterator();
        while (dep_iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.dep_graph.deinit();

        var content_iter = self.contents.iterator();
        while (content_iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.contents.deinit();

        self.word_index.deinit();
        self.trigram_index.deinit();
    }
    pub fn indexFile(self: *Explorer, path: []const u8, content: []const u8) !void {
        return self.indexFileInner(path, content, true);
    }

    /// Fast path: index outline + content storage only, skip word/trigram indexes.
    /// Used during initial scan for speed. Search indexes are built lazily on first query.
    pub fn indexFileOutlineOnly(self: *Explorer, path: []const u8, content: []const u8) !void {
        return self.indexFileInner(path, content, false);
    }

fn indexFileInner(self: *Explorer, path: []const u8, content: []const u8, full_index: bool) !void {
    // Parse outline outside the global explorer write lock.
    // This keeps HTTP/MCP readers from being blocked on line-by-line parsing.
    var outline = FileOutline.init(self.allocator, path);
    errdefer outline.deinit();
    outline.byte_size = content.len;

    var line_num: u32 = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        line_num += 1;
        const trimmed = std.mem.trim(u8, line, " \t");

        if (outline.language == .zig) {
            try self.parseZigLine(trimmed, line_num, &outline);
        } else if (outline.language == .python) {
            try self.parsePythonLine(trimmed, line_num, &outline);
        } else if (outline.language == .typescript or outline.language == .javascript) {
            try self.parseTsLine(trimmed, line_num, &outline);
        }
    }
    outline.line_count = line_num;

    self.mu.lock();
    defer self.mu.unlock();

    // Reuse existing key if file was already indexed, else dupe.
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
    // If we added a new entry but later fail, remove it so the map stays consistent.
    errdefer if (is_new) {
        _ = self.outlines.remove(stable_path);
        self.allocator.free(stable_path);
    };

    // Ensure outline path uses the stable map key.
    outline.path = stable_path;

    const duped_content = try self.allocator.dupe(u8, content);
    errdefer self.allocator.free(duped_content);
    const content_gop = try self.contents.getOrPut(stable_path);
    var prior_content: ?[]const u8 = null;
    if (content_gop.found_existing) {
        prior_content = content_gop.value_ptr.*;
    } else {
        content_gop.key_ptr.* = stable_path;
    }
    content_gop.value_ptr.* = duped_content;
    errdefer {
        if (content_gop.found_existing) {
            content_gop.value_ptr.* = prior_content.?;
        } else {
            _ = self.contents.remove(stable_path);
        }
    }

    // Build search indexes.
    if (full_index) {
        try self.word_index.indexFile(stable_path, content);
        try self.trigram_index.indexFile(stable_path, content);
    }

    try self.rebuildDepsFor(stable_path, &outline);

    outline_gop.value_ptr.* = outline;
    if (prior_content) |old_content| {
        self.allocator.free(old_content);
    }
    if (prior_outline) |*old_outline| {
        old_outline.deinit();
    }
}

    pub fn removeFile(self: *Explorer, path: []const u8) void {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.dep_graph.getPtr(path)) |deps| {
            deps.deinit(self.allocator);
            _ = self.dep_graph.remove(path);
        }
        if (self.contents.getPtr(path)) |content| {
            self.allocator.free(content.*);
            _ = self.contents.remove(path);
        }
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

    /// Return a caller-owned copy of cached file content.
pub fn getContent(self: *Explorer, path: []const u8, allocator: std.mem.Allocator) !?[]u8 {
    self.mu.lockShared();
    defer self.mu.unlockShared();

    const content = self.contents.get(path) orelse return null;
    return try allocator.dupe(u8, content);
}

fn cloneOutline(src: *const FileOutline, allocator: std.mem.Allocator) !FileOutline {
    const copied_path = try allocator.dupe(u8, src.path);
    errdefer allocator.free(copied_path);

    var dst = FileOutline.init(allocator, copied_path);
    dst.owns_path = true;
    errdefer dst.deinit();
    dst.language = src.language;
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

pub fn getTree(self: *Explorer, allocator: std.mem.Allocator) ![]u8 {
    self.mu.lockShared();
    defer self.mu.unlockShared();

    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    var paths: std.ArrayList([]const u8) = .{};
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

    // Track which directories we've already printed
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
                try writer.print("{s}/\n", .{path[if (depth > 0) std.mem.lastIndexOfScalar(u8, dir[0..sep], '/').? + 1 else 0 .. sep]});
            }
            prefix_end = sep + 1;
        }

        // Emit file leaf
        const depth = std.mem.count(u8, path, "/");
        for (0..depth) |_| try writer.writeAll("  ");
        const basename = if (std.mem.lastIndexOfScalar(u8, path, '/')) |pos| path[pos + 1 ..] else path;

        try writer.print("{s}  ({s}, {d}L, {d} symbols)\n", .{
            basename,
            @tagName(outline.language),
            outline.line_count,
            outline.symbols.items.len,
        });
    }

    return buf.toOwnedSlice(allocator);
}

    pub fn findSymbol(self: *Explorer, name: []const u8) !?struct { path: []const u8, symbol: Symbol } {
        self.mu.lockShared();
        defer self.mu.unlockShared();

        var iter = self.outlines.iterator();
        while (iter.next()) |entry| {
            for (entry.value_ptr.symbols.items) |sym| {
                if (std.mem.eql(u8, sym.name, name)) {
                    return .{ .path = entry.key_ptr.*, .symbol = sym };
                }
            }
        }
        return null;
    }

    pub fn findAllSymbols(self: *Explorer, name: []const u8, allocator: std.mem.Allocator) ![]const SymbolResult {
        self.mu.lockShared();
        defer self.mu.unlockShared();

        var result_list: std.ArrayList(SymbolResult) = .{};
        errdefer result_list.deinit(allocator);
        var iter = self.outlines.iterator();
        while (iter.next()) |entry| {
            for (entry.value_ptr.symbols.items) |sym| {
                if (std.mem.eql(u8, sym.name, name)) {
                    try result_list.append(allocator, .{ .path = entry.key_ptr.*, .symbol = sym });
                }
            }
        }
        return result_list.toOwnedSlice(allocator);
    }

    pub fn searchContent(self: *Explorer, query: []const u8, allocator: std.mem.Allocator, max_results: usize) ![]const SearchResult {
        self.mu.lockShared();
        defer self.mu.unlockShared();

        var result_list: std.ArrayList(SearchResult) = .{};
        errdefer result_list.deinit(allocator);
        // Try trigram index to narrow candidates (queries >= 3 chars)
        const candidate_paths = self.trigram_index.candidates(query);
        defer if (candidate_paths) |cp| self.allocator.free(cp);
        const use_trigram = candidate_paths != null and candidate_paths.?.len > 0;

        if (use_trigram) {
            // Only scan candidate files
            for (candidate_paths.?) |path| {
                const content = self.contents.get(path) orelse continue;
                try searchInContent(path, content, query, allocator, max_results, &result_list);
                if (result_list.items.len >= max_results) break;
            }
        } else {
            // Brute force (short query or no trigram hits)
            var iter = self.contents.iterator();
            while (iter.next()) |entry| {
                try searchInContent(entry.key_ptr.*, entry.value_ptr.*, query, allocator, max_results, &result_list);
                if (result_list.items.len >= max_results) break;
            }
        }

        return result_list.toOwnedSlice(allocator);
    }

    /// Search for a word using the inverted word index. O(1) lookup.
    pub fn searchWord(self: *Explorer, word: []const u8, allocator: std.mem.Allocator) ![]const idx.WordHit {
        self.mu.lockShared();
        defer self.mu.unlockShared();
        return self.word_index.searchDeduped(word, allocator);
    }

pub fn getImportedBy(self: *Explorer, path: []const u8, allocator: std.mem.Allocator) ![]const []const u8 {
    self.mu.lockShared();
    defer self.mu.unlockShared();

    // Extract basename for matching against raw import strings
    // e.g., "src/store.zig" -> "store.zig"
    const basename = if (std.mem.lastIndexOfScalar(u8, path, '/')) |pos| path[pos + 1 ..] else path;

    var result: std.ArrayList([]const u8) = .{};
    errdefer {
        for (result.items) |p| allocator.free(p);
        result.deinit(allocator);
    }

    var iter = self.dep_graph.iterator();
    while (iter.next()) |entry| {
        for (entry.value_ptr.items) |dep| {
            if (std.mem.eql(u8, dep, path) or std.mem.eql(u8, dep, basename)) {
                const dep_path = try allocator.dupe(u8, entry.key_ptr.*);
                try result.append(allocator, dep_path);
                break;
            }
        }
    }
    return result.toOwnedSlice(allocator);
}

pub fn getHotFiles(self: *Explorer, store: *Store, allocator: std.mem.Allocator, limit: usize) ![]const []const u8 {
    // Collect stable path copies under explorer lock.
    var path_list: std.ArrayList([]u8) = .{};
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
    var entries: std.ArrayList(Entry) = .{};
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
    // ── Language parsers ──────────────────────────────────────

    fn parseZigLine(self: *Explorer, line: []const u8, line_num: u32, outline: *FileOutline) !void {
        const a = self.allocator;
        if (startsWith(line, "pub fn ") or startsWith(line, "fn ")) {
            const start: usize = if (startsWith(line, "pub fn ")) 7 else 3;
            if (extractIdent(line[start..])) |name| {
                const name_copy = try a.dupe(u8, name);
                errdefer a.free(name_copy);
                const detail_copy = try a.dupe(u8, line);
                errdefer a.free(detail_copy);
                try outline.symbols.append(a, .{
                    .name = name_copy,
                    .kind = .function,
                    .line_start = line_num,
                    .line_end = line_num,
                    .detail = detail_copy,
                });
            }
        } else if (startsWith(line, "pub const ") or startsWith(line, "const ")) {
            const start: usize = if (startsWith(line, "pub const ")) 10 else 6;
            if (extractIdent(line[start..])) |name| {
                const kind: SymbolKind = if (std.mem.indexOf(u8, line, "struct") != null)
                    .struct_def
                else if (std.mem.indexOf(u8, line, "enum") != null)
                    .enum_def
                else if (std.mem.indexOf(u8, line, "union") != null)
                    .union_def
                else if (std.mem.indexOf(u8, line, "@import") != null)
                    .import
                else
                    .constant;

                const name_copy = try a.dupe(u8, name);
                errdefer a.free(name_copy);
                const detail_copy = try a.dupe(u8, line);
                errdefer a.free(detail_copy);
                try outline.symbols.append(a, .{
                    .name = name_copy,
                    .kind = kind,
                    .line_start = line_num,
                    .line_end = line_num,
                    .detail = detail_copy,
                });

                if (kind == .import) {
                    if (extractStringLiteral(line)) |import_path| {
                        const import_copy = try a.dupe(u8, import_path);
                        errdefer a.free(import_copy);
                        try outline.imports.append(a, import_copy);
                    }
                }
            }
        } else if (startsWith(line, "test ")) {
            const name_copy = try a.dupe(u8, line);
            errdefer a.free(name_copy);
            try outline.symbols.append(a, .{
                .name = name_copy,
                .kind = .test_decl,
                .line_start = line_num,
                .line_end = line_num,
            });
        }
    }

    fn parsePythonLine(self: *Explorer, line: []const u8, line_num: u32, outline: *FileOutline) !void {
        const a = self.allocator;
        if (startsWith(line, "def ")) {
            if (extractIdent(line[4..])) |name| {
                const name_copy = try a.dupe(u8, name);
                errdefer a.free(name_copy);
                const detail_copy = try a.dupe(u8, line);
                errdefer a.free(detail_copy);
                try outline.symbols.append(a, .{
                    .name = name_copy,
                    .kind = .function,
                    .line_start = line_num,
                    .line_end = line_num,
                    .detail = detail_copy,
                });
            }
        } else if (startsWith(line, "class ")) {
            if (extractIdent(line[6..])) |name| {
                const name_copy = try a.dupe(u8, name);
                errdefer a.free(name_copy);
                const detail_copy = try a.dupe(u8, line);
                errdefer a.free(detail_copy);
                try outline.symbols.append(a, .{
                    .name = name_copy,
                    .kind = .struct_def,
                    .line_start = line_num,
                    .line_end = line_num,
                    .detail = detail_copy,
                });
            }
        } else if (startsWith(line, "import ") or startsWith(line, "from ")) {
            const symbol_copy = try a.dupe(u8, line);
            errdefer a.free(symbol_copy);
            try outline.symbols.append(a, .{
                .name = symbol_copy,
                .kind = .import,
                .line_start = line_num,
                .line_end = line_num,
            });
            const import_copy = try a.dupe(u8, line);
            errdefer a.free(import_copy);
            try outline.imports.append(a, import_copy);
        }
    }

    fn parseTsLine(self: *Explorer, line: []const u8, line_num: u32, outline: *FileOutline) !void {
        const a = self.allocator;
        if (containsAny(line, &.{ "function ", "const ", "export function ", "export const " })) {
            const kind: SymbolKind = if (std.mem.indexOf(u8, line, "function") != null) .function else .constant;
            const trimmed = skipKeywords(line);
            if (extractIdent(trimmed)) |name| {
                const name_copy = try a.dupe(u8, name);
                errdefer a.free(name_copy);
                const detail_copy = try a.dupe(u8, line);
                errdefer a.free(detail_copy);
                try outline.symbols.append(a, .{
                    .name = name_copy,
                    .kind = kind,
                    .line_start = line_num,
                    .line_end = line_num,
                    .detail = detail_copy,
                });
            }
        }
        if (containsAny(line, &.{ "import ", "require(" })) {
            const symbol_copy = try a.dupe(u8, line);
            errdefer a.free(symbol_copy);
            try outline.symbols.append(a, .{
                .name = symbol_copy,
                .kind = .import,
                .line_start = line_num,
                .line_end = line_num,
            });
            if (extractStringLiteral(line)) |path| {
                const import_copy = try a.dupe(u8, path);
                errdefer a.free(import_copy);
                try outline.imports.append(a, import_copy);
            }
        }
    }

fn rebuildDepsFor(self: *Explorer, path: []const u8, outline: *FileOutline) !void {
    var deps: std.ArrayList([]const u8) = .{};
    errdefer deps.deinit(self.allocator);

    for (outline.imports.items) |imp| {
        try deps.append(self.allocator, imp);
    }

    const gop = try self.dep_graph.getOrPut(path);
    if (gop.found_existing) {
        var old = gop.value_ptr.*;
        gop.value_ptr.* = deps;
        old.deinit(self.allocator);
    } else {
        gop.key_ptr.* = path;
        gop.value_ptr.* = deps;
    }
}
};

fn searchInContent(path: []const u8, content: []const u8, query: []const u8, allocator: std.mem.Allocator, max_results: usize, result_list: *std.ArrayList(SearchResult)) !void {
    var line_num: u32 = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        line_num += 1;
        if (indexOfCaseInsensitive(line, query) != null) {
            const line_text = try allocator.dupe(u8, line);
            errdefer allocator.free(line_text);
            try result_list.append(allocator, .{
                .path = path,
                .line_num = line_num,
                .line_text = line_text,
            });
            if (result_list.items.len >= max_results) return;
        }
    }
}

fn indexOfCaseInsensitive(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;
    for (0..haystack.len - needle.len + 1) |i| {
        var match = true;
        for (0..needle.len) |j| {
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

fn startsWith(haystack: []const u8, needle: []const u8) bool {
    return std.mem.startsWith(u8, haystack, needle);
}

fn extractIdent(s: []const u8) ?[]const u8 {
    var end: usize = 0;
    for (s) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '_') {
            end += 1;
        } else break;
    }
    return if (end > 0) s[0..end] else null;
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

fn containsAny(s: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (std.mem.indexOf(u8, s, needle) != null) return true;
    }
    return false;
}

fn skipKeywords(s: []const u8) []const u8 {
    const keywords = [_][]const u8{ "export ", "async ", "function ", "const ", "let ", "var " };
    var result = s;
    for (keywords) |kw| {
        if (std.mem.startsWith(u8, result, kw)) {
            result = result[kw.len..];
        }
    }
    return result;
}
