// wasm.zig — WASM entry point for codedb
//
// Exports C-ABI functions that can be called from JavaScript in a
// Cloudflare Worker. Takes file path + content, returns JSON outlines,
// trigram data, and search results.
//
// Memory protocol:
//   JS allocates input buffers via wasm_alloc(), writes data, calls
//   processing functions, reads output from returned pointer, then
//   frees via wasm_free().

const std = @import("std");
const Explorer = @import("explore.zig").Explorer;
const FileOutline = @import("explore.zig").FileOutline;
const TrigramIndex = @import("index.zig").TrigramIndex;
const SparseNgramIndex = @import("index.zig").SparseNgramIndex;
const WordIndex = @import("index.zig").WordIndex;
const normalizeChar = @import("index.zig").normalizeChar;
const packTrigram = @import("index.zig").packTrigram;

const allocator = std.heap.wasm_allocator;

/// Write a JSON-escaped string (without surrounding quotes) to the writer.
fn writeJsonEscaped(writer: anytype, s: []const u8) void {
    for (s) |c| {
        switch (c) {
            '"' => writer.writeAll("\\\"") catch return,
            '\\' => writer.writeAll("\\\\") catch return,
            '\n' => writer.writeAll("\\n") catch return,
            '\r' => writer.writeAll("\\r") catch return,
            '\t' => writer.writeAll("\\t") catch return,
            else => {
                if (c < 0x20) {
                    writer.print("\\u{x:0>4}", .{c}) catch return;
                } else {
                    writer.writeByte(c) catch return;
                }
            },
        }
    }
}

// Persistent explorer instance
var explorer: ?Explorer = null;

fn getExplorer() *Explorer {
    if (explorer == null) {
        explorer = Explorer.init(allocator);
    }
    return &explorer.?;
}

// ── Memory management ──

export fn wasm_alloc(len: usize) ?[*]u8 {
    const slice = allocator.alloc(u8, len) catch return null;
    return slice.ptr;
}

export fn wasm_free(ptr: [*]u8, len: usize) void {
    allocator.free(ptr[0..len]);
}

// ── Core functions ──

/// Index a file into the persistent Explorer.
/// path_ptr/path_len: file path
/// content_ptr/content_len: file content
/// Returns 1 on success, 0 on failure.
export fn wasm_index_file(
    path_ptr: [*]const u8,
    path_len: usize,
    content_ptr: [*]const u8,
    content_len: usize,
) u32 {
    const path = path_ptr[0..path_len];
    const content = content_ptr[0..content_len];
    const exp = getExplorer();
    exp.indexFileOutlineOnly(path, content) catch return 0;
    return 1;
}

/// Get the outline for a file as JSON.
/// Returns pointer to JSON string. Length written to out_len_ptr.
/// Caller must free with wasm_free.
export fn wasm_get_outline(
    path_ptr: [*]const u8,
    path_len: usize,
    out_len_ptr: *usize,
) ?[*]u8 {
    const path = path_ptr[0..path_len];
    const exp = getExplorer();

    const outline_opt = exp.getOutline(path, allocator) catch return null;
    var outline = outline_opt orelse return null;
    defer outline.deinit();

    // Serialize to JSON with proper escaping
    var buf: std.ArrayList(u8) = .empty;
    const writer = buf.writer(allocator);
    writer.writeByte('[') catch return null;
    for (outline.symbols.items, 0..) |sym, i| {
        if (i > 0) writer.writeByte(',') catch return null;
        writer.writeAll("{\"name\":\"") catch return null;
        writeJsonEscaped(writer, sym.name);
        writer.writeAll("\",\"kind\":\"") catch return null;
        writeJsonEscaped(writer, @tagName(sym.kind));
        writer.print("\",\"line\":{d}", .{sym.line_start}) catch return null;
        if (sym.detail) |d| {
            writer.writeAll(",\"detail\":\"") catch return null;
            writeJsonEscaped(writer, d);
            writer.writeByte('"') catch return null;
        }
        writer.writeByte('}') catch return null;
    }
    writer.writeByte(']') catch return null;

    const slice = buf.toOwnedSlice(allocator) catch return null;
    out_len_ptr.* = slice.len;
    return slice.ptr;
}

/// Search content across all indexed files.
/// Returns JSON results. Length written to out_len_ptr.
/// Caller must free with wasm_free.
export fn wasm_search(
    query_ptr: [*]const u8,
    query_len: usize,
    max_results: u32,
    out_len_ptr: *usize,
) ?[*]u8 {
    const query = query_ptr[0..query_len];
    const exp = getExplorer();

    const results = exp.searchContent(query, allocator, max_results) catch return null;
    defer {
        for (results) |r| {
            allocator.free(r.line_text);
            allocator.free(r.path);
        }
        allocator.free(results);
    }

    // Serialize to JSON
    var buf: std.ArrayList(u8) = .empty;
    const writer = buf.writer(allocator);
    writer.writeByte('[') catch return null;
    for (results, 0..) |r, i| {
        if (i > 0) writer.writeByte(',') catch return null;
        writer.print(
            \\{{"path":"{s}","line_num":{d},"line_text":"
        , .{ r.path, r.line_num }) catch return null;
        // Escape the line text
        for (r.line_text) |c| {
            switch (c) {
                '"' => writer.writeAll("\\\"") catch return null,
                '\\' => writer.writeAll("\\\\") catch return null,
                '\n' => writer.writeAll("\\n") catch return null,
                '\r' => writer.writeAll("\\r") catch return null,
                '\t' => writer.writeAll("\\t") catch return null,
                else => {
                    if (c < 0x20) {
                        writer.print("\\u{x:0>4}", .{c}) catch return null;
                    } else {
                        writer.writeByte(c) catch return null;
                    }
                },
            }
        }
        writer.writeAll("\"}") catch return null;
    }
    writer.writeByte(']') catch return null;

    const slice = buf.toOwnedSlice(allocator) catch return null;
    out_len_ptr.* = slice.len;
    return slice.ptr;
}

/// Get file tree as JSON.
export fn wasm_get_tree(out_len_ptr: *usize) ?[*]u8 {
    const exp = getExplorer();

    var buf: std.ArrayList(u8) = .empty;
    const writer = buf.writer(allocator);
    writer.writeByte('[') catch return null;
    var first = true;
    var iter = exp.outlines.iterator();
    while (iter.next()) |entry| {
        if (!first) writer.writeByte(',') catch return null;
        first = false;
        const outline = entry.value_ptr;
        writer.writeAll("{\"path\":\"") catch return null;
        writeJsonEscaped(writer, entry.key_ptr.*);
        writer.writeAll("\",\"language\":\"") catch return null;
        writeJsonEscaped(writer, @tagName(outline.language));
        writer.print("\",\"line_count\":{d},\"byte_size\":{d},\"symbol_count\":{d}}}", .{
            outline.line_count,
            outline.byte_size,
            outline.symbols.items.len,
        }) catch return null;
    }
    writer.writeByte(']') catch return null;

    const slice = buf.toOwnedSlice(allocator) catch return null;
    out_len_ptr.* = slice.len;
    return slice.ptr;
}

/// Get all outlines as JSON.
export fn wasm_get_all_outlines(out_len_ptr: *usize) ?[*]u8 {
    const exp = getExplorer();

    var buf: std.ArrayList(u8) = .empty;
    const writer = buf.writer(allocator);
    writer.writeByte('{') catch return null;
    var first = true;
    var iter = exp.outlines.iterator();
    while (iter.next()) |entry| {
        if (!first) writer.writeByte(',') catch return null;
        first = false;
        writer.writeByte('"') catch return null;
        writeJsonEscaped(writer, entry.key_ptr.*);
        writer.writeAll("\":[") catch return null;
        for (entry.value_ptr.symbols.items, 0..) |sym, si| {
            if (si > 0) writer.writeByte(',') catch return null;
            writer.writeAll("{\"name\":\"") catch return null;
            writeJsonEscaped(writer, sym.name);
            writer.writeAll("\",\"kind\":\"") catch return null;
            writeJsonEscaped(writer, @tagName(sym.kind));
            writer.print("\",\"line\":{d}", .{sym.line_start}) catch return null;
            if (sym.detail) |d| {
                writer.writeAll(",\"detail\":\"") catch return null;
                writeJsonEscaped(writer, d);
                writer.writeByte('"') catch return null;
            }
            writer.writeByte('}') catch return null;
        }
        writer.writeByte(']') catch return null;
    }
    writer.writeByte('}') catch return null;

    const slice = buf.toOwnedSlice(allocator) catch return null;
    out_len_ptr.* = slice.len;
    return slice.ptr;
}

/// Reset the explorer (clear all indexed data).
export fn wasm_reset() void {
    if (explorer) |*exp| {
        exp.deinit();
        explorer = null;
    }
}

/// Return the number of indexed files.
export fn wasm_file_count() u32 {
    if (explorer) |*exp| {
        return @intCast(exp.outlines.count());
    }
    return 0;
}
