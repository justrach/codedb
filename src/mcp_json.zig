//! Small JSON-RPC helpers used by codedb's MCP transport.
//!
//! These were formerly supplied by mcp-zig. Keeping the protocol-neutral
//! helpers local avoids coupling codedb's build to a second server framework.

const std = @import("std");

pub const MAX_LINE = 1024 * 1024;

/// Read one newline-terminated message from a buffered reader.
/// The caller owns the returned slice.
pub fn readLineBuf(alloc: std.mem.Allocator, reader: *std.Io.Reader) ?[]u8 {
    var line: std.ArrayList(u8) = .empty;
    while (true) {
        const byte = reader.takeByte() catch {
            if (line.items.len == 0) {
                line.deinit(alloc);
                return null;
            }
            return line.toOwnedSlice(alloc) catch null;
        };
        if (byte == '\n') return line.toOwnedSlice(alloc) catch null;
        line.append(alloc, byte) catch {
            line.deinit(alloc);
            return null;
        };
        if (line.items.len > MAX_LINE) {
            line.deinit(alloc);
            return null;
        }
    }
}

pub fn getStr(obj: *const std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (obj.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

pub fn getInt(obj: *const std.json.ObjectMap, key: []const u8) ?i64 {
    return switch (obj.get(key) orelse return null) {
        .integer => |n| n,
        else => null,
    };
}

pub fn getBool(obj: *const std.json.ObjectMap, key: []const u8) bool {
    return switch (obj.get(key) orelse return false) {
        .bool => |b| b,
        else => false,
    };
}

pub fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Append a JSON-escaped string without adding surrounding quotes.
pub fn writeEscaped(alloc: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) void {
    const Vec = @Vector(16, u8);
    var i: usize = 0;

    while (i < s.len) {
        const start = i;
        while (i + 16 <= s.len) {
            const chunk: Vec = s[i..][0..16].*;
            const lo = chunk < @as(Vec, @splat(@as(u8, 0x20)));
            const dq = chunk == @as(Vec, @splat(@as(u8, '"')));
            const bs = chunk == @as(Vec, @splat(@as(u8, '\\')));
            if (@reduce(.Or, lo | dq | bs)) break;
            i += 16;
        }
        while (i < s.len) : (i += 1) {
            const c = s[i];
            if (c < 0x20 or c == '"' or c == '\\') break;
        }

        if (i > start) out.appendSlice(alloc, s[start..i]) catch return;
        if (i >= s.len) break;

        const c = s[i];
        switch (c) {
            '"' => out.appendSlice(alloc, "\\\"") catch return,
            '\\' => out.appendSlice(alloc, "\\\\") catch return,
            '\n' => out.appendSlice(alloc, "\\n") catch return,
            '\r' => out.appendSlice(alloc, "\\r") catch return,
            '\t' => out.appendSlice(alloc, "\\t") catch return,
            else => {
                const hex = "0123456789abcdef";
                const escaped = [6]u8{ '\\', 'u', '0', '0', hex[c >> 4], hex[c & 0x0f] };
                out.appendSlice(alloc, &escaped) catch return;
            },
        }
        i += 1;
    }
}
