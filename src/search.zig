// gitagent-mcp — Search tool cascade + diff parsing
//
// Provides a "poor man's blast_radius" that works today without CodeDB's
// graph engine. Probes for the best available search tool (zigrep → rg → grep)
// and uses it to find symbol references across the codebase.

const std = @import("std");
const gh  = @import("gh.zig");

// ── Search tool detection ─────────────────────────────────────────────────────

pub const SearchTool = enum { zigrep, rg, grep, none };

var g_mu:    std.Thread.Mutex = .{};
var g_probed: bool            = false;
var g_tool:  SearchTool       = .none;

/// Detect which search tool is available. Cached after first call.
pub fn probe(alloc: std.mem.Allocator) SearchTool {
    g_mu.lock();
    defer g_mu.unlock();
    if (g_probed) return g_tool;

    const candidates = [_][]const []const u8{
        &.{ "zigrep", "--version" },
        &.{ "rg",     "--version" },
        &.{ "grep",   "--version" },
    };
    const tools = [_]SearchTool{ .zigrep, .rg, .grep };

    for (candidates, tools) |argv, tool| {
        const r = gh.run(alloc, argv) catch continue;
        r.deinit(alloc);
        g_tool = tool;
        break;
    }

    g_probed = true;
    return g_tool;
}

/// Name string for JSON output.
pub fn toolName(tool: SearchTool) []const u8 {
    return switch (tool) {
        .zigrep => "zigrep",
        .rg     => "rg",
        .grep   => "grep",
        .none   => "none",
    };
}

/// Search for references to `symbol` across the codebase, excluding `exclude_file`.
/// Returns a list of file paths that reference the symbol.
pub fn searchRefs(
    alloc: std.mem.Allocator,
    tool: SearchTool,
    symbol: []const u8,
    exclude_file: ?[]const u8,
) !std.ArrayList([]const u8) {
    var results: std.ArrayList([]const u8) = .empty;

    if (symbol.len == 0 or tool == .none) return results;

    const argv: []const []const u8 = switch (tool) {
        .zigrep => &.{ "zigrep", "-l", "-w", symbol, "." },
        .rg     => &.{ "rg", "-l", "-F", "-w", symbol, "." },
        .grep   => &.{ "grep", "-rlFw", symbol, "." },
        .none   => return results,
    };

    const r = gh.runWithOutput(alloc, argv) catch |err| {
        // Command launch/allocator failures are real errors.
        return err;
    };
    defer r.deinit(alloc);

    // exit code 1 = no matches for grep/rg/zigrep in this context.
    if (r.exit_code == 1) return results;
    if (r.exit_code != 0) return gh.GhError.Unexpected;

    var seen = std.StringHashMap(void).init(alloc);
    defer seen.deinit();

    var iter = std.mem.splitScalar(u8, std.mem.trim(u8, r.stdout, " \t\n\r"), '\n');
    while (iter.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;

        // Strip leading "./"
        const path = if (std.mem.startsWith(u8, line, "./")) line[2..] else line;
        if (path.len == 0) continue;

        // Skip excluded file
        if (exclude_file) |ef| {
            if (std.mem.eql(u8, path, ef)) continue;
        }

        // Deduplicate
        if (seen.contains(path)) continue;
        seen.put(path, {}) catch continue;

        const owned = alloc.dupe(u8, path) catch continue;
        results.append(alloc, owned) catch {
            alloc.free(owned);
            continue;
        };
    }

    return results;
}

// ── Diff parsing helpers ──────────────────────────────────────────────────────

/// Parse `diff --git a/X b/Y` → returns Y (the destination path).
pub fn extractFilePath(line: []const u8) ?[]const u8 {
    // Find last " b/" — handles paths with spaces
    if (std.mem.lastIndexOf(u8, line, " b/")) |idx| {
        const path = line[idx + 3 ..];
        if (path.len > 0) return path;
    }
    return null;
}

/// Parse `@@ -a,b +c,d @@ fn handleFoo(` → returns `handleFoo`.
/// Extracts the identifier from the function context after the closing `@@`.
pub fn extractHunkSymbol(line: []const u8) ?[]const u8 {
    // Find the closing "@@" (second one)
    const prefix = "@@ ";
    if (!std.mem.startsWith(u8, line, prefix)) return null;

    // Find second @@
    if (std.mem.indexOf(u8, line[3..], "@@")) |rel_idx| {
        const after = line[3 + rel_idx + 2 ..]; // skip past "@@"
        return extractIdentifierFromContext(after);
    }
    return null;
}

/// Extract an identifier after common definition keywords.
/// Handles: `pub fn`, `fn`, `function`, `def`, `class`, `pub const`, `const`
pub fn extractIdentifierFromContext(ctx: []const u8) ?[]const u8 {
    const trimmed = std.mem.trimLeft(u8, ctx, " \t");
    if (trimmed.len == 0) return null;

    const keywords = [_][]const u8{
        "pub fn ",
        "fn ",
        "function ",
        "def ",
        "class ",
        "pub const ",
        "const ",
    };

    for (keywords) |kw| {
        if (std.mem.startsWith(u8, trimmed, kw)) {
            const rest = trimmed[kw.len..];
            return extractWord(rest);
        }
    }
    return null;
}

/// Extract first word (identifier) from input — stops at `(`, `:`, `{`, ` `, etc.
fn extractWord(input: []const u8) ?[]const u8 {
    if (input.len == 0) return null;
    var end: usize = 0;
    while (end < input.len) : (end += 1) {
        const c = input[end];
        if (c == '(' or c == ':' or c == '{' or c == ' ' or
            c == '\t' or c == '=' or c == '<' or c == '\n' or c == '\r')
            break;
    }
    if (end == 0) return null;
    return input[0..end];
}

// ── Symbol extraction from file content ──────────────────────────────────────

/// Extract definition symbols from source content by scanning each line
/// for definition keywords (fn, def, class, const, etc.).
/// Returns slices into `content` — caller must NOT free `content` while using results.
pub fn extractSymbolsFromContent(
    alloc: std.mem.Allocator,
    content: []const u8,
    max: usize,
) std.ArrayList([]const u8) {
    var result: std.ArrayList([]const u8) = .empty;
    var seen = std.StringHashMap(void).init(alloc);
    defer seen.deinit();

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (result.items.len >= max) break;
        if (extractIdentifierFromContext(line)) |sym| {
            if (!seen.contains(sym)) {
                seen.put(sym, {}) catch continue;
                result.append(alloc, sym) catch continue;
            }
        }
    }

    return result;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "toolName returns correct strings" {
    try std.testing.expectEqualStrings("zigrep", toolName(.zigrep));
    try std.testing.expectEqualStrings("rg",     toolName(.rg));
    try std.testing.expectEqualStrings("grep",   toolName(.grep));
    try std.testing.expectEqualStrings("none",   toolName(.none));
}

test "extractFilePath: standard diff header" {
    const path = extractFilePath("diff --git a/src/tools.zig b/src/tools.zig");
    try std.testing.expectEqualStrings("src/tools.zig", path.?);
}

test "extractFilePath: rename (different a/ and b/)" {
    const path = extractFilePath("diff --git a/old/foo.zig b/new/foo.zig");
    try std.testing.expectEqualStrings("new/foo.zig", path.?);
}

test "extractFilePath: path with spaces" {
    const path = extractFilePath("diff --git a/my dir/file.zig b/my dir/file.zig");
    try std.testing.expectEqualStrings("my dir/file.zig", path.?);
}

test "extractFilePath: not a diff line" {
    try std.testing.expect(extractFilePath("some random line") == null);
    try std.testing.expect(extractFilePath("") == null);
}

test "extractHunkSymbol: zig function" {
    const sym = extractHunkSymbol("@@ -10,5 +10,7 @@ fn handleFoo(");
    try std.testing.expectEqualStrings("handleFoo", sym.?);
}

test "extractHunkSymbol: pub fn" {
    const sym = extractHunkSymbol("@@ -1,3 +1,4 @@ pub fn dispatch(");
    try std.testing.expectEqualStrings("dispatch", sym.?);
}

test "extractHunkSymbol: no function context" {
    // Hunk header with no function after closing @@
    try std.testing.expect(extractHunkSymbol("@@ -1,3 +1,4 @@") == null);
    try std.testing.expect(extractHunkSymbol("@@ -1,3 +1,4 @@   ") == null);
}

test "extractHunkSymbol: not a hunk line" {
    try std.testing.expect(extractHunkSymbol("not a hunk") == null);
    try std.testing.expect(extractHunkSymbol("") == null);
}

test "extractHunkSymbol: python def" {
    const sym = extractHunkSymbol("@@ -5,3 +5,4 @@ def run_tests(");
    try std.testing.expectEqualStrings("run_tests", sym.?);
}

test "extractHunkSymbol: javascript function" {
    const sym = extractHunkSymbol("@@ -5,3 +5,4 @@ function handleClick(");
    try std.testing.expectEqualStrings("handleClick", sym.?);
}

test "extractIdentifierFromContext: pub fn" {
    const id = extractIdentifierFromContext(" pub fn handleFoo(alloc: Allocator)");
    try std.testing.expectEqualStrings("handleFoo", id.?);
}

test "extractIdentifierFromContext: fn" {
    const id = extractIdentifierFromContext("fn writeErr(alloc: Allocator)");
    try std.testing.expectEqualStrings("writeErr", id.?);
}

test "extractIdentifierFromContext: function (JS)" {
    const id = extractIdentifierFromContext("function handleClick(event)");
    try std.testing.expectEqualStrings("handleClick", id.?);
}

test "extractIdentifierFromContext: def (Python)" {
    const id = extractIdentifierFromContext("def run_tests(self):");
    try std.testing.expectEqualStrings("run_tests", id.?);
}

test "extractIdentifierFromContext: class" {
    const id = extractIdentifierFromContext("class MyWidget{");
    try std.testing.expectEqualStrings("MyWidget", id.?);
}

test "extractIdentifierFromContext: pub const" {
    const id = extractIdentifierFromContext("pub const tools_list =");
    try std.testing.expectEqualStrings("tools_list", id.?);
}

test "extractIdentifierFromContext: const" {
    const id = extractIdentifierFromContext("const std = @import");
    try std.testing.expectEqualStrings("std", id.?);
}

test "extractIdentifierFromContext: no keyword" {
    try std.testing.expect(extractIdentifierFromContext("  var x = 5;") == null);
    try std.testing.expect(extractIdentifierFromContext("return true;") == null);
    try std.testing.expect(extractIdentifierFromContext("") == null);
    try std.testing.expect(extractIdentifierFromContext("   ") == null);
}

test "extractIdentifierFromContext: leading whitespace" {
    const id = extractIdentifierFromContext("    fn nested(x: u8) void");
    try std.testing.expectEqualStrings("nested", id.?);
}

test "searchRefs: empty symbol returns empty" {
    const alloc = std.testing.allocator;
    const refs = try searchRefs(alloc, .rg, "", null);
    defer refs.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), refs.items.len);
}

test "searchRefs: none tool returns empty" {
    const alloc = std.testing.allocator;
    const refs = try searchRefs(alloc, .none, "handleFoo", null);
    defer refs.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), refs.items.len);
}

test "extractSymbolsFromContent: mixed definitions" {
    const alloc = std.testing.allocator;
    const content =
        \\pub fn handleFoo(alloc: Allocator) void {
        \\    // body
        \\}
        \\fn helperBar() void {}
        \\const MY_CONST = 42;
        \\def python_func(self):
        \\class Widget {
        \\    var x = 5;
    ;
    var syms = extractSymbolsFromContent(alloc, content, 100);
    defer syms.deinit(alloc);
    // Should find: handleFoo, helperBar, MY_CONST, python_func, Widget (not var x)
    try std.testing.expectEqual(@as(usize, 5), syms.items.len);
    try std.testing.expectEqualStrings("handleFoo", syms.items[0]);
    try std.testing.expectEqualStrings("helperBar", syms.items[1]);
    try std.testing.expectEqualStrings("MY_CONST", syms.items[2]);
    try std.testing.expectEqualStrings("python_func", syms.items[3]);
    try std.testing.expectEqualStrings("Widget", syms.items[4]);
}

test "extractSymbolsFromContent: max cap respected" {
    const alloc = std.testing.allocator;
    const content =
        \\fn alpha() void {}
        \\fn beta() void {}
        \\fn gamma() void {}
        \\fn delta() void {}
    ;
    var syms = extractSymbolsFromContent(alloc, content, 2);
    defer syms.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), syms.items.len);
    try std.testing.expectEqualStrings("alpha", syms.items[0]);
    try std.testing.expectEqualStrings("beta", syms.items[1]);
}
