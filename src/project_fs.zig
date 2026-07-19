const std = @import("std");

/// An opened parent directory plus the final path component. The directory is
/// reached one component at a time with symlink following disabled, so callers
/// can safely perform the final operation relative to this held handle.
pub const Parent = struct {
    dir: std.Io.Dir,
    basename: []const u8,
    owns_dir: bool,

    pub fn deinit(self: *Parent, io: std.Io) void {
        if (self.owns_dir) self.dir.close(io);
        self.* = undefined;
    }
};

fn isCanonicalRelativePath(path: []const u8) bool {
    if (path.len == 0 or path[0] == '/' or
        std.mem.indexOfScalar(u8, path, 0) != null or
        std.mem.indexOfScalar(u8, path, '\\') != null) return false;

    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        if (component.len == 0 or
            std.mem.eql(u8, component, ".") or
            std.mem.eql(u8, component, "..")) return false;
    }
    return true;
}

/// Resolve only the parent of a project-relative path. Every parent component
/// is opened with no-follow semantics and the final parent handle stays open,
/// preventing a check/open race through a swapped directory symlink.
pub fn openParentNoFollow(io: std.Io, root: std.Io.Dir, path: []const u8) !Parent {
    if (!isCanonicalRelativePath(path)) return error.AccessDenied;

    const separator = std.mem.lastIndexOfScalar(u8, path, '/');
    const basename = if (separator) |index| path[index + 1 ..] else path;
    const parent_path = if (separator) |index| path[0..index] else "";

    var current = root;
    var owns_current = false;
    errdefer if (owns_current) current.close(io);

    var components = std.mem.splitScalar(u8, parent_path, '/');
    while (components.next()) |component| {
        if (component.len == 0) continue;
        const next = try current.openDir(io, component, .{
            .access_sub_paths = true,
            .follow_symlinks = false,
        });
        if (owns_current) current.close(io);
        current = next;
        owns_current = true;
    }

    return .{
        .dir = current,
        .basename = basename,
        .owns_dir = owns_current,
    };
}

/// Open a project-relative regular file without following either parent or
/// final-component symlinks.
pub fn openFileReadNoFollow(io: std.Io, root: std.Io.Dir, path: []const u8) !std.Io.File {
    var parent = try openParentNoFollow(io, root, path);
    defer parent.deinit(io);
    return parent.dir.openFile(io, parent.basename, .{
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    });
}

pub fn readFileAlloc(
    io: std.Io,
    root: std.Io.Dir,
    path: []const u8,
    allocator: std.mem.Allocator,
    limit: std.Io.Limit,
) std.Io.Dir.ReadFileAllocError![]u8 {
    var file = try openFileReadNoFollow(io, root, path);
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return reader.interface.allocRemainingAlignedSentinel(allocator, limit, .of(u8), null) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        error.OutOfMemory, error.StreamTooLong => |e| return e,
    };
}

pub fn readFileAllocFromParent(
    io: std.Io,
    parent: std.Io.Dir,
    basename: []const u8,
    allocator: std.mem.Allocator,
    limit: std.Io.Limit,
) std.Io.Dir.ReadFileAllocError![]u8 {
    var file = try parent.openFile(io, basename, .{
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    });
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return reader.interface.allocRemainingAlignedSentinel(allocator, limit, .of(u8), null) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        error.OutOfMemory, error.StreamTooLong => |e| return e,
    };
}

/// Metadata-only existence check that treats a symlink itself as an existing
/// destination instead of following it.
pub fn entryExistsNoFollow(io: std.Io, parent: std.Io.Dir, basename: []const u8) !bool {
    _ = parent.statFile(io, basename, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

test "project file reads reject final and parent symlinks" {
    const io = std.testing.io;
    var project = std.testing.tmpDir(.{});
    defer project.cleanup();
    var outside = std.testing.tmpDir(.{});
    defer outside.cleanup();

    try project.dir.createDirPath(io, "src/nested");
    try project.dir.writeFile(io, .{ .sub_path = "src/nested/main.zig", .data = "inside\n" });
    try outside.dir.writeFile(io, .{ .sub_path = "secret.zig", .data = "outside\n" });

    const inside = try readFileAlloc(io, project.dir, "src/nested/main.zig", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(inside);
    try std.testing.expectEqualStrings("inside\n", inside);

    var outside_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const outside_path_len = try outside.dir.realPathFile(io, "secret.zig", &outside_path_buf);
    project.dir.symLink(io, outside_path_buf[0..outside_path_len], "alias.zig", .{}) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    if (readFileAlloc(io, project.dir, "alias.zig", std.testing.allocator, .limited(1024))) |unexpected| {
        defer std.testing.allocator.free(unexpected);
        return error.TestUnexpectedResult;
    } else |_| {}

    var outside_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const outside_dir_len = try outside.dir.realPathFile(io, ".", &outside_dir_buf);
    project.dir.symLink(io, outside_dir_buf[0..outside_dir_len], "linked", .{ .is_directory = true }) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    if (readFileAlloc(io, project.dir, "linked/secret.zig", std.testing.allocator, .limited(1024))) |unexpected| {
        defer std.testing.allocator.free(unexpected);
        return error.TestUnexpectedResult;
    } else |_| {}
}
