const std = @import("std");

// ── Inverted word index ─────────────────────────────────────
// Maps word → list of (path, line) hits. O(1) word lookup.

pub const WordHit = struct {
    path: []const u8,
    line_num: u32,
};

pub const WordIndex = struct {
    /// word → hits
    index: std.StringHashMap(std.ArrayList(WordHit)),
    /// path → set of words contributed (for efficient re-index cleanup)
    file_words: std.StringHashMap(std.StringHashMap(void)),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) WordIndex {
        return .{
            .index = std.StringHashMap(std.ArrayList(WordHit)).init(allocator),
            .file_words = std.StringHashMap(std.StringHashMap(void)).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *WordIndex) void {
        // Free hit lists and duped word keys
        var iter = self.index.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.index.deinit();

        // Free per-file word sets
        var fw_iter = self.file_words.iterator();
        while (fw_iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.file_words.deinit();
    }

    /// Remove all index entries for a file (call before re-indexing).
    pub fn removeFile(self: *WordIndex, path: []const u8) void {
        const words_set = self.file_words.getPtr(path) orelse return;

        // For each word this file contributed, remove hits with this path.
        // Prune empty buckets so churn does not leak key/list entries.
        var word_iter = words_set.keyIterator();
        while (word_iter.next()) |word_ptr| {
            if (self.index.getEntry(word_ptr.*)) |entry| {
                const hits = entry.value_ptr;
                var i: usize = 0;
                while (i < hits.items.len) {
                    if (std.mem.eql(u8, hits.items[i].path, path)) {
                        _ = hits.swapRemove(i);
                    } else {
                        i += 1;
                    }
                }
                if (hits.items.len == 0) {
                    const owned_word = entry.key_ptr.*;
                    hits.deinit(self.allocator);
                    _ = self.index.remove(word_ptr.*);
                    self.allocator.free(owned_word);
                }
            }
        }

        words_set.deinit();
        _ = self.file_words.remove(path);
    }


    /// Index a file's content — tokenizes into words and records hits.
    pub fn indexFile(self: *WordIndex, path: []const u8, content: []const u8) !void {
        // Clean up old entries first
        self.removeFile(path);

        var words_set = std.StringHashMap(void).init(self.allocator);
        errdefer words_set.deinit();
        var line_num: u32 = 0;
        var lines = std.mem.splitScalar(u8, content, '\n');

        while (lines.next()) |line| {
            line_num += 1;
            var tok = WordTokenizer{ .buf = line };
            while (tok.next()) |word| {
                if (word.len < 2) continue; // skip single chars

                // Ensure word is in the global index
                const gop = try self.index.getOrPut(word);
                if (!gop.found_existing) {
                    const duped_word = try self.allocator.dupe(u8, word);
                    gop.key_ptr.* = duped_word;
                    gop.value_ptr.* = .{};
                }

                if (gop.value_ptr.items.len > 0) {
                    const last = gop.value_ptr.items[gop.value_ptr.items.len - 1];
                    if (std.mem.eql(u8, last.path, path) and last.line_num == line_num) {
                        // Avoid duplicate hits for repeated words on the same line.
                        const wgop = try words_set.getOrPut(word);
                        if (!wgop.found_existing) wgop.key_ptr.* = gop.key_ptr.*;
                        continue;
                    }
                }

                try gop.value_ptr.append(self.allocator, .{
                    .path = path,
                    .line_num = line_num,
                });

                // Track that this file contributed this word
                const wgop = try words_set.getOrPut(word);
                if (!wgop.found_existing) {
                    // Point to the same key in the index (no extra alloc)
                    wgop.key_ptr.* = gop.key_ptr.*;
                }
            }
        }

        try self.file_words.put(path, words_set);
    }

    /// Look up all hits for a word. O(1) lookup + O(hits) iteration.
    pub fn search(self: *WordIndex, word: []const u8) []const WordHit {
        if (self.index.get(word)) |hits| {
            return hits.items;
        }
        return &.{};
    }

    /// Look up hits, returning results allocated by the caller.
    /// Deduplicates by (path, line_num).
pub fn searchDeduped(self: *WordIndex, word: []const u8, allocator: std.mem.Allocator) ![]const WordHit {
    const hits = self.search(word);
    if (hits.len == 0) return try allocator.alloc(WordHit, 0);
    if (hits.len == 1) {
        var out = try allocator.alloc(WordHit, 1);
        out[0] = hits[0];
        return out;
    }

    const DedupKey = struct { path_ptr: usize, line_num: u32 };
    var seen = std.AutoHashMap(DedupKey, void).init(allocator);
    defer seen.deinit();
    try seen.ensureTotalCapacity(@intCast(hits.len));

    var result: std.ArrayList(WordHit) = .{};
    errdefer result.deinit(allocator);
    try result.ensureTotalCapacity(allocator, hits.len);

    for (hits) |hit| {
        const key = DedupKey{ .path_ptr = @intFromPtr(hit.path.ptr), .line_num = hit.line_num };
        const gop = try seen.getOrPut(key);
        if (!gop.found_existing) {
            result.appendAssumeCapacity(hit);
        }
    }
    return result.toOwnedSlice(allocator);
}
};

// ── Trigram index ───────────────────────────────────────────
// Maps 3-byte sequences → set of file paths.
// Enables fast substring search: extract trigrams from query,
// intersect candidate file sets, then verify with actual match.

pub const Trigram = u24;

fn packTrigram(a: u8, b: u8, c: u8) Trigram {
    return @as(Trigram, a) << 16 | @as(Trigram, b) << 8 | @as(Trigram, c);
}

pub const TrigramIndex = struct {
    /// trigram → set of file paths
    index: std.AutoHashMap(Trigram, std.StringHashMap(void)),
    /// path → list of trigrams contributed (for cleanup)
    file_trigrams: std.StringHashMap(std.ArrayList(Trigram)),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TrigramIndex {
        return .{
            .index = std.AutoHashMap(Trigram, std.StringHashMap(void)).init(allocator),
            .file_trigrams = std.StringHashMap(std.ArrayList(Trigram)).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TrigramIndex) void {
        var iter = self.index.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.index.deinit();

        var ft_iter = self.file_trigrams.iterator();
        while (ft_iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.file_trigrams.deinit();
    }

    pub fn removeFile(self: *TrigramIndex, path: []const u8) void {
        const trigrams = self.file_trigrams.getPtr(path) orelse return;
        for (trigrams.items) |tri| {
            if (self.index.getPtr(tri)) |file_set| {
                _ = file_set.remove(path);
                if (file_set.count() == 0) {
                    file_set.deinit();
                    _ = self.index.remove(tri);
                }
            }
        }
        trigrams.deinit(self.allocator);
        _ = self.file_trigrams.remove(path);
    }

    pub fn indexFile(self: *TrigramIndex, path: []const u8, content: []const u8) !void {
        self.removeFile(path);

        var seen_trigrams = std.AutoHashMap(Trigram, void).init(self.allocator);
        defer seen_trigrams.deinit();

        // Extract unique trigrams from content
        if (content.len >= 3) {
            for (0..content.len - 2) |i| {
                const tri = packTrigram(
                    normalizeChar(content[i]),
                    normalizeChar(content[i + 1]),
                    normalizeChar(content[i + 2]),
                );
                const gop = try seen_trigrams.getOrPut(tri);
                if (!gop.found_existing) {
                    // Add to global index
                    const idx_gop = try self.index.getOrPut(tri);
                    if (!idx_gop.found_existing) {
                        idx_gop.value_ptr.* = std.StringHashMap(void).init(self.allocator);
                    }
                    try idx_gop.value_ptr.put(path, {});
                }
            }
        }

        // Store which trigrams this file contributed
        var tri_list: std.ArrayList(Trigram) = .{};
        errdefer tri_list.deinit(self.allocator);
        var tri_iter = seen_trigrams.keyIterator();
        while (tri_iter.next()) |tri_ptr| {
            try tri_list.append(self.allocator, tri_ptr.*);
        }
        try self.file_trigrams.put(path, tri_list);
    }

    /// Find candidate files that contain ALL trigrams from the query.
pub fn candidates(self: *TrigramIndex, query: []const u8) ?[]const []const u8 {
    if (query.len < 3) return null; // can't use trigrams for short queries

    const tri_count = query.len - 2;

    // Deduplicate query trigrams first so repeated trigrams don't do repeated work.
    var unique = std.AutoHashMap(Trigram, void).init(self.allocator);
    defer unique.deinit();
    unique.ensureTotalCapacity(@intCast(tri_count)) catch return null;
    for (0..tri_count) |i| {
        const tri = packTrigram(
            normalizeChar(query[i]),
            normalizeChar(query[i + 1]),
            normalizeChar(query[i + 2]),
        );
        _ = unique.getOrPut(tri) catch return null;
    }

    var sets: std.ArrayList(*const std.StringHashMap(void)) = .{};
    defer sets.deinit(self.allocator);
    sets.ensureTotalCapacity(self.allocator, unique.count()) catch return null;

    var tri_iter = unique.keyIterator();
    while (tri_iter.next()) |tri_ptr| {
        const file_set = self.index.getPtr(tri_ptr.*) orelse {
            return self.allocator.alloc([]const u8, 0) catch null;
        };
        sets.appendAssumeCapacity(file_set);
    }

    if (sets.items.len == 0) {
        return self.allocator.alloc([]const u8, 0) catch null;
    }

    // Iterate the smallest set and check membership in all others.
    var min_idx: usize = 0;
    var min_count = sets.items[0].count();
    for (sets.items[1..], 1..) |set, i| {
        const count = set.count();
        if (count < min_count) {
            min_count = count;
            min_idx = i;
        }
    }

    var result: std.ArrayList([]const u8) = .{};
    errdefer result.deinit(self.allocator);
    result.ensureTotalCapacity(self.allocator, min_count) catch return null;

    var it = sets.items[min_idx].keyIterator();
    while (it.next()) |path_ptr| {
        var ok = true;
        for (sets.items, 0..) |set, i| {
            if (i == min_idx) continue;
            if (!set.contains(path_ptr.*)) {
                ok = false;
                break;
            }
        }
        if (ok) result.appendAssumeCapacity(path_ptr.*);
    }

    return result.toOwnedSlice(self.allocator) catch {
        result.deinit(self.allocator);
        return null;
    };
}
};

// ── Tokenizer ───────────────────────────────────────────────

pub const WordTokenizer = struct {
    buf: []const u8,
    pos: usize = 0,

    pub fn next(self: *WordTokenizer) ?[]const u8 {
        // Skip non-word chars
        while (self.pos < self.buf.len and !isWordChar(self.buf[self.pos])) {
            self.pos += 1;
        }
        if (self.pos >= self.buf.len) return null;

        const start = self.pos;
        while (self.pos < self.buf.len and isWordChar(self.buf[self.pos])) {
            self.pos += 1;
        }
        return self.buf[start..self.pos];
    }
};

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn normalizeChar(c: u8) u8 {
    // Lowercase for case-insensitive trigram matching
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}
