//! Strict conversion of MCP local-file roots to native absolute paths.
//! Root URIs are untrusted protocol input: only `file://` is accepted, percent
//! escapes are decoded once, and traversal/relative spellings are rejected
//! before the filesystem capability constructor sees them.
const std = @import("std");

pub const ParseError = error{
    UnsupportedScheme,
    UnsupportedAuthority,
    InvalidEncoding,
    RelativePath,
    Traversal,
    InvalidPath,
    OutOfMemory,
};

fn hexNibble(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

fn decode(allocator: std.mem.Allocator, encoded: []const u8) ParseError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, encoded.len);
    var i: usize = 0;
    while (i < encoded.len) {
        if (encoded[i] != '%') {
            if (encoded[i] == 0 or encoded[i] == '?' or encoded[i] == '#') return error.InvalidPath;
            out.appendAssumeCapacity(encoded[i]);
            i += 1;
            continue;
        }
        if (i + 2 >= encoded.len) return error.InvalidEncoding;
        const hi = hexNibble(encoded[i + 1]) orelse return error.InvalidEncoding;
        const lo = hexNibble(encoded[i + 2]) orelse return error.InvalidEncoding;
        const value = (hi << 4) | lo;
        if (value == 0 or value == '?' or value == '#') return error.InvalidPath;
        out.appendAssumeCapacity(value);
        i += 3;
    }
    return out.toOwnedSlice(allocator);
}

fn hasTraversal(path: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, path, "/\\");
    while (it.next()) |part| if (std.mem.eql(u8, part, "..")) return true;
    return false;
}

fn isWindowsAbsolute(path: []const u8) bool {
    return path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and (path[2] == '/' or path[2] == '\\');
}

pub fn parseLocalFileUriForOs(
    allocator: std.mem.Allocator,
    uri: []const u8,
    os_tag: std.Target.Os.Tag,
) ParseError![]u8 {
    if (!std.mem.startsWith(u8, uri, "file://")) return error.UnsupportedScheme;
    const remainder = uri[7..];
    const slash = std.mem.indexOfScalar(u8, remainder, '/');
    const authority = if (slash) |at| remainder[0..at] else remainder;
    const encoded_path = if (slash) |at| remainder[at..] else "";

    if (os_tag != .windows and authority.len != 0) return error.UnsupportedAuthority;
    if (os_tag == .windows and authority.len != 0) {
        if (encoded_path.len < 2) return error.RelativePath;
        const decoded = try decode(allocator, encoded_path);
        defer allocator.free(decoded);
        if (hasTraversal(decoded)) return error.Traversal;
        var native = std.ArrayList(u8).empty;
        errdefer native.deinit(allocator);
        try native.appendSlice(allocator, "\\\\");
        try native.appendSlice(allocator, authority);
        for (decoded) |ch| try native.append(allocator, if (ch == '/') '\\' else ch);
        return native.toOwnedSlice(allocator);
    }

    const decoded = try decode(allocator, encoded_path);
    errdefer allocator.free(decoded);
    if (hasTraversal(decoded)) return error.Traversal;
    if (os_tag == .windows) {
        const drive_path = if (decoded.len >= 3 and decoded[0] == '/' and decoded[2] == ':') decoded[1..] else decoded;
        if (!isWindowsAbsolute(drive_path)) return error.RelativePath;
        const native = try allocator.dupe(u8, drive_path);
        for (native) |*ch| if (ch.* == '/') {
            ch.* = '\\';
        };
        allocator.free(decoded);
        return native;
    }
    if (decoded.len == 0 or decoded[0] != '/') return error.RelativePath;
    return decoded;
}

pub fn parseLocalFileUri(allocator: std.mem.Allocator, uri: []const u8) ParseError![]u8 {
    return parseLocalFileUriForOs(allocator, uri, @import("builtin").os.tag);
}

pub fn parseRootReference(allocator: std.mem.Allocator, value: []const u8) ParseError![]u8 {
    if (std.mem.indexOf(u8, value, "://") != null or std.mem.startsWith(u8, value, "file:")) {
        return parseLocalFileUri(allocator, value);
    }
    if (!std.fs.path.isAbsolute(value)) return error.RelativePath;
    if (hasTraversal(value)) return error.Traversal;
    return allocator.dupe(u8, value);
}

test "local file URI parser decodes spaces and rejects unsafe forms" {
    const a = std.testing.allocator;
    const path = try parseLocalFileUriForOs(a, "file:///Users/me/My%20Repo", .macos);
    defer a.free(path);
    try std.testing.expectEqualStrings("/Users/me/My Repo", path);
    try std.testing.expectError(error.UnsupportedScheme, parseLocalFileUriForOs(a, "https://example/repo", .macos));
    try std.testing.expectError(error.UnsupportedAuthority, parseLocalFileUriForOs(a, "file://server/share", .macos));
    try std.testing.expectError(error.Traversal, parseLocalFileUriForOs(a, "file:///Users/me/%2e%2e/.ssh", .macos));
    try std.testing.expectError(error.InvalidEncoding, parseLocalFileUriForOs(a, "file:///bad%2", .macos));
}

test "Windows drive and UNC file URIs convert without POSIX assumptions" {
    const a = std.testing.allocator;
    const drive = try parseLocalFileUriForOs(a, "file:///C:/My%20Repo", .windows);
    defer a.free(drive);
    try std.testing.expectEqualStrings("C:\\My Repo", drive);
    const unc = try parseLocalFileUriForOs(a, "file://server/share/repo", .windows);
    defer a.free(unc);
    try std.testing.expectEqualStrings("\\\\server\\share\\repo", unc);
    try std.testing.expectError(error.RelativePath, parseLocalFileUriForOs(a, "file://relative", .windows));
}
