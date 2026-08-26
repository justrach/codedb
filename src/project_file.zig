//! Race-resistant reads of project source files.
//!
//! File symlinks are deliberately unsupported throughout codedb: indexing,
//! search fallbacks, and direct read surfaces must all observe the same view.
//! Opening the final component with `follow_symlinks = false` closes the
//! check/retarget/open race, while `resolve_beneath` keeps resolution anchored
//! to the supplied project directory capability.
const std = @import("std");
const project_path = @import("project_path.zig");
const root_policy = @import("root_policy.zig");

pub const isAllowedPath = project_path.isReadable;

pub fn rootIsAllowed(io: std.Io, dir: std.Io.Dir) bool {
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = dir.realPath(io, &root_buf) catch return false;
    return root_policy.isIndexableRoot(root_buf[0..root_len]);
}

fn isWithinRoot(root: []const u8, candidate: []const u8) bool {
    if (!std.mem.startsWith(u8, candidate, root)) return false;
    if (candidate.len == root.len) return true;
    return root.len > 0 and (std.fs.path.isSep(root[root.len - 1]) or std.fs.path.isSep(candidate[root.len]));
}

fn openValidated(
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
) !std.Io.File {
    if (!isAllowedPath(path)) return error.AccessDenied;
    var file = try dir.openFile(io, path, .{
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    });
    errdefer file.close(io);

    // Validate the object actually opened, not a pre-open realpath. The file
    // handle cannot be retargeted underneath this check, so an allowed-looking
    // directory alias such as `alias -> .ssh` cannot bypass the sensitive-path
    // policy, while safe in-root directory aliases remain usable.
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try dir.realPath(io, &root_buf);
    const root = root_buf[0..root_len];
    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target_len = try file.realPath(io, &target_buf);
    const target = target_buf[0..target_len];
    if (!isWithinRoot(root, target)) return error.AccessDenied;
    var rel_start = root.len;
    while (rel_start < target.len and std.fs.path.isSep(target[rel_start])) rel_start += 1;
    if (rel_start == target.len) return error.AccessDenied;
    var normalized_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rel = target[rel_start..];
    if (rel.len > normalized_buf.len) return error.NameTooLong;
    for (rel, normalized_buf[0..rel.len]) |ch, *normalized| {
        normalized.* = if (std.fs.path.isSep(ch)) '/' else ch;
    }
    if (!isAllowedPath(normalized_buf[0..rel.len])) return error.AccessDenied;

    return file;
}

pub fn statNoFollow(io: std.Io, dir: std.Io.Dir, path: []const u8) !std.Io.File.Stat {
    const file = try openValidated(io, dir, path);
    defer file.close(io);
    return file.stat(io);
}

pub fn readAllocNoFollow(
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
    allocator: std.mem.Allocator,
    limit: std.Io.Limit,
) ![]u8 {
    const file = try openValidated(io, dir, path);
    defer file.close(io);

    var reader = file.reader(io, &.{});
    return reader.interface.allocRemaining(allocator, limit) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        error.OutOfMemory, error.StreamTooLong => |e| return e,
    };
}
