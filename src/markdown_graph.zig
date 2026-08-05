//! Conservative Markdown document-link extraction for the local documentation
//! graph. This is intentionally not a complete Markdown parser: it recognizes
//! inline links and wikilinks outside code, normalizes only project-relative
//! Markdown targets, and rejects ambiguous or unsafe destinations.

const std = @import("std");

pub const MAX_LINKS_PER_FILE: usize = 1024;

pub const LinkKind = enum(u8) {
    markdown,
    wikilink,
};

pub const Link = struct {
    target: []const u8,
    kind: LinkKind,
};

pub fn freeLinks(allocator: std.mem.Allocator, links: []const Link) void {
    for (links) |link| allocator.free(link.target);
    allocator.free(links);
}

fn hexNibble(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

fn percentDecode(allocator: std.mem.Allocator, value: []const u8) !?[]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var i: usize = 0;
    while (i < value.len) {
        if (value[i] != '%') {
            if (value[i] == 0 or value[i] == '\\') return null;
            try out.append(allocator, value[i]);
            i += 1;
            continue;
        }
        if (i + 2 >= value.len) return null;
        const hi = hexNibble(value[i + 1]) orelse return null;
        const lo = hexNibble(value[i + 2]) orelse return null;
        const decoded = (hi << 4) | lo;
        if (decoded == 0 or decoded == '\\') return null;
        try out.append(allocator, decoded);
        i += 3;
    }
    return try out.toOwnedSlice(allocator);
}

fn hasExternalScheme(value: []const u8) bool {
    if (std.mem.startsWith(u8, value, "//")) return true;
    for (value, 0..) |c, i| {
        if (c == '/' or c == '#') return false;
        if (c != ':') continue;
        if (i == 0 or !std.ascii.isAlphabetic(value[0])) return false;
        for (value[1..i]) |part| {
            if (!std.ascii.isAlphanumeric(part) and part != '+' and part != '-' and part != '.') return false;
        }
        return true;
    }
    return false;
}

pub fn isSafeNormalizedTarget(value: []const u8) bool {
    if (value.len == 0 or value[0] == '/' or hasExternalScheme(value)) return false;
    if (!std.ascii.endsWithIgnoreCase(value, ".md") and !std.ascii.endsWithIgnoreCase(value, ".markdown")) return false;
    if (std.mem.indexOfAny(u8, value, "\\?#") != null or std.mem.indexOfScalar(u8, value, 0) != null) return false;
    var parts = std.mem.splitScalar(u8, value, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

fn destinationOnly(raw: []const u8, kind: LinkKind) []const u8 {
    var value = std.mem.trim(u8, raw, " \t\r\n");
    if (kind == .wikilink) {
        if (std.mem.indexOfScalar(u8, value, '|')) |alias| value = value[0..alias];
    }
    if (value.len >= 2 and value[0] == '<' and value[value.len - 1] == '>') {
        value = value[1 .. value.len - 1];
    } else if (kind == .markdown) {
        // A whitespace-delimited suffix is an optional Markdown title. Literal
        // spaces in a path must be percent-encoded, which keeps this bounded.
        for (value, 0..) |c, i| {
            if (c == ' ' or c == '\t') {
                value = value[0..i];
                break;
            }
        }
    }
    if (std.mem.indexOfAny(u8, value, "?#")) |suffix| value = value[0..suffix];
    return std.mem.trim(u8, value, " \t\r\n");
}

fn appendComponent(out: *std.ArrayList(u8), allocator: std.mem.Allocator, component: []const u8) !void {
    if (out.items.len > 0) try out.append(allocator, '/');
    try out.appendSlice(allocator, component);
}

fn popComponent(out: *std.ArrayList(u8)) bool {
    if (out.items.len == 0) return false;
    if (std.mem.lastIndexOfScalar(u8, out.items, '/')) |slash| {
        out.shrinkRetainingCapacity(slash);
    } else {
        out.clearRetainingCapacity();
    }
    return true;
}

fn normalizeTarget(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    raw: []const u8,
    kind: LinkKind,
) !?[]const u8 {
    const destination = destinationOnly(raw, kind);
    if (destination.len == 0 or destination[0] == '#' or destination[0] == '/' or hasExternalScheme(destination)) return null;

    const decoded = (try percentDecode(allocator, destination)) orelse return null;
    defer allocator.free(decoded);
    if (decoded.len == 0 or decoded[0] == '/') return null;

    var normalized: std.ArrayList(u8) = .empty;
    defer normalized.deinit(allocator);

    if (std.fs.path.dirname(source_path)) |parent| {
        var base_parts = std.mem.splitScalar(u8, parent, '/');
        while (base_parts.next()) |part| {
            if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
            if (std.mem.eql(u8, part, "..")) {
                if (!popComponent(&normalized)) return null;
            } else {
                try appendComponent(&normalized, allocator, part);
            }
        }
    }

    var target_parts = std.mem.splitScalar(u8, decoded, '/');
    while (target_parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (!popComponent(&normalized)) return null;
            continue;
        }
        try appendComponent(&normalized, allocator, part);
    }
    if (normalized.items.len == 0) return null;

    if (decoded[decoded.len - 1] == '/') {
        try normalized.appendSlice(allocator, "/README.md");
    } else {
        const base = std.fs.path.basename(normalized.items);
        if (std.mem.lastIndexOfScalar(u8, base, '.') == null) {
            try normalized.appendSlice(allocator, ".md");
        } else if (!std.ascii.endsWithIgnoreCase(base, ".md") and !std.ascii.endsWithIgnoreCase(base, ".markdown")) {
            return null;
        }
    }

    if (!isSafeNormalizedTarget(normalized.items) or std.mem.eql(u8, normalized.items, source_path)) return null;
    return try normalized.toOwnedSlice(allocator);
}

fn appendLink(
    allocator: std.mem.Allocator,
    links: *std.ArrayList(Link),
    source_path: []const u8,
    raw: []const u8,
    kind: LinkKind,
) !void {
    if (links.items.len >= MAX_LINKS_PER_FILE) return;
    const target = (try normalizeTarget(allocator, source_path, raw, kind)) orelse return;
    for (links.items) |existing| {
        if (std.mem.eql(u8, existing.target, target)) {
            allocator.free(target);
            return;
        }
    }
    try links.append(allocator, .{ .target = target, .kind = kind });
}

fn findClosingBracket(line: []const u8, start: usize) ?usize {
    var escaped = false;
    var i = start;
    while (i < line.len) : (i += 1) {
        if (escaped) {
            escaped = false;
            continue;
        }
        if (line[i] == '\\') {
            escaped = true;
            continue;
        }
        if (line[i] == ']') return i;
    }
    return null;
}

fn findClosingParen(line: []const u8, start: usize) ?usize {
    var depth: u8 = 1;
    var escaped = false;
    var in_angle = false;
    var i = start;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (escaped) {
            escaped = false;
            continue;
        }
        if (c == '\\') {
            escaped = true;
            continue;
        }
        if (c == '<') in_angle = true;
        if (c == '>') in_angle = false;
        if (in_angle) continue;
        if (c == '(') {
            if (depth == 8) return null;
            depth += 1;
        } else if (c == ')') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

fn fenceMarker(line: []const u8) ?u8 {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    if (trimmed.len < 3) return null;
    if ((trimmed[0] == '`' or trimmed[0] == '~') and trimmed[1] == trimmed[0] and trimmed[2] == trimmed[0]) return trimmed[0];
    return null;
}

/// Extract normalized project-relative Markdown document links. Malformed
/// input is ignored rather than surfaced as an indexing failure.
pub fn extract(allocator: std.mem.Allocator, source_path: []const u8, content: []const u8) ![]Link {
    if (!isSafeNormalizedTarget(source_path)) return try allocator.alloc(Link, 0);
    var links: std.ArrayList(Link) = .empty;
    errdefer {
        for (links.items) |link| allocator.free(link.target);
        links.deinit(allocator);
    }

    var active_fence: ?u8 = null;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (fenceMarker(line)) |marker| {
            if (active_fence == null) {
                active_fence = marker;
            } else if (active_fence.? == marker) {
                active_fence = null;
            }
            continue;
        }
        if (active_fence != null) continue;

        var code_ticks: usize = 0;
        var escaped = false;
        var i: usize = 0;
        while (i < line.len and links.items.len < MAX_LINKS_PER_FILE) {
            const c = line[i];
            if (escaped) {
                escaped = false;
                i += 1;
                continue;
            }
            if (c == '\\') {
                escaped = true;
                i += 1;
                continue;
            }
            if (c == '`') {
                var run: usize = 1;
                while (i + run < line.len and line[i + run] == '`') : (run += 1) {}
                if (code_ticks == 0) {
                    code_ticks = run;
                } else if (code_ticks == run) {
                    code_ticks = 0;
                }
                i += run;
                continue;
            }
            if (code_ticks != 0 or c != '[') {
                i += 1;
                continue;
            }

            if (i + 1 < line.len and line[i + 1] == '[') {
                const tail = line[i + 2 ..];
                if (std.mem.indexOf(u8, tail, "]]")) |relative_end| {
                    const end = i + 2 + relative_end;
                    try appendLink(allocator, &links, source_path, line[i + 2 .. end], .wikilink);
                    i = end + 2;
                    continue;
                }
                i += 2;
                continue;
            }

            if (i > 0 and line[i - 1] == '!') {
                i += 1;
                continue;
            }
            const label_end = findClosingBracket(line, i + 1) orelse {
                i += 1;
                continue;
            };
            var open = label_end + 1;
            while (open < line.len and (line[open] == ' ' or line[open] == '\t')) : (open += 1) {}
            if (open >= line.len or line[open] != '(') {
                i = label_end + 1;
                continue;
            }
            const close = findClosingParen(line, open + 1) orelse {
                i += 1;
                continue;
            };
            try appendLink(allocator, &links, source_path, line[open + 1 .. close], .markdown);
            i = close + 1;
        }
    }

    return try links.toOwnedSlice(allocator);
}

test "issue-685: markdown links are normalized, typed, and deduplicated" {
    const testing = std.testing;
    const content =
        \\[API](../reference/api.md#usage)
        \\[[setup|Setup guide]]
        \\[space](two%20words.md?raw=1)
        \\[chapter](chapter/)
        \\[unicode](überblick.md)
        \\[self](guide.md)
        \\[[setup]]
    ;
    const links = try extract(testing.allocator, "docs/guide.md", content);
    defer freeLinks(testing.allocator, links);

    try testing.expectEqual(@as(usize, 5), links.len);
    try testing.expectEqualStrings("reference/api.md", links[0].target);
    try testing.expectEqual(LinkKind.markdown, links[0].kind);
    try testing.expectEqualStrings("docs/setup.md", links[1].target);
    try testing.expectEqual(LinkKind.wikilink, links[1].kind);
    try testing.expectEqualStrings("docs/two words.md", links[2].target);
    try testing.expectEqualStrings("docs/chapter/README.md", links[3].target);
    try testing.expectEqualStrings("docs/überblick.md", links[4].target);
}

test "issue-685: markdown extraction ignores unsafe malformed and code links" {
    const testing = std.testing;
    const content =
        \\![image](image.md)
        \\[external](https://example.com/a.md)
        \\[protocol](//example.com/a.md)
        \\[absolute](/etc/passwd.md)
        \\[traversal](../../secret.md)
        \\[bad percent](bad%2.md)
        \\[non markdown](asset.png)
        \\`[inline](inline.md)` and ``[double](double.md)``
        \\```zig
        \\[fenced](fenced.md)
        \\```
        \\[[unterminated
    ;
    const links = try extract(testing.allocator, "docs/guide.md", content);
    defer freeLinks(testing.allocator, links);
    try testing.expectEqual(@as(usize, 0), links.len);
}

test "issue-685: malformed links do not suppress later valid links" {
    const testing = std.testing;
    const content =
        \\[[broken [wiki](wiki.md)
        \\[broken label [label](label.md)
        \\[broken](unterminated [destination](destination.md)
    ;
    const links = try extract(testing.allocator, "docs/guide.md", content);
    defer freeLinks(testing.allocator, links);

    try testing.expectEqual(@as(usize, 3), links.len);
    try testing.expectEqualStrings("docs/wiki.md", links[0].target);
    try testing.expectEqualStrings("docs/label.md", links[1].target);
    try testing.expectEqualStrings("docs/destination.md", links[2].target);
}

test "issue-685: unterminated fences and link cap remain bounded" {
    const testing = std.testing;
    const hidden = try extract(testing.allocator, "README.md", "~~~md\n[x](x.md)\n");
    defer freeLinks(testing.allocator, hidden);
    try testing.expectEqual(@as(usize, 0), hidden.len);

    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(testing.allocator);
    const writer = @import("cio.zig").listWriter(&source, testing.allocator);
    for (0..MAX_LINKS_PER_FILE + 8) |i| try writer.print("[x](page-{d}.md)\n", .{i});
    const links = try extract(testing.allocator, "README.md", source.items);
    defer freeLinks(testing.allocator, links);
    try testing.expectEqual(MAX_LINKS_PER_FILE, links.len);
}
