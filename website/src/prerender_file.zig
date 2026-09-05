const std = @import("std");

pub fn openPrerendered(alloc: std.mem.Allocator, root: std.fs.Dir, url_path: []const u8) !std.fs.File {
    const rel = if (std.mem.eql(u8, url_path, "/")) "index" else if (std.mem.startsWith(u8, url_path, "/")) url_path[1..] else url_path;
    if (rel.len == 0 or std.mem.indexOfAny(u8, rel, "\\:\x00%") != null) return error.AccessDenied;
    var parts = std.mem.splitScalar(u8, rel, '/');
    var parent = root.openDir(".", .{ .no_follow = true }) catch return error.AccessDenied;
    defer parent.close();
    var part = parts.next().?;
    while (true) {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.AccessDenied;
        const next = parts.next() orelse break;
        const child = parent.openDir(part, .{ .no_follow = true }) catch return error.AccessDenied;
        parent.close();
        parent = child;
        part = next;
    }
    const name = std.fmt.allocPrint(alloc, "{s}.html", .{part}) catch return error.AccessDenied;
    defer alloc.free(name);
    const fd = std.posix.openat(parent.fd, name, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .NONBLOCK = true, .CLOEXEC = true }, 0) catch return error.AccessDenied;
    const file: std.fs.File = .{ .handle = fd };
    errdefer file.close();

    if ((file.stat() catch return error.AccessDenied).kind != .file) return error.AccessDenied;
    return file;
}

test "security: prerender files stay under dist" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("dist/docs");
    try tmp.dir.writeFile(.{ .sub_path = "outside.html", .data = "secret" });
    try tmp.dir.writeFile(.{ .sub_path = "dist/index.html", .data = "home" });
    try tmp.dir.writeFile(.{ .sub_path = "dist/docs/page.html", .data = "page" });
    var dist = try tmp.dir.openDir("dist", .{});
    defer dist.close();
    try dist.symLink("../outside.html", "link.html", .{});
    for ([_][]const u8{ "/", "/docs/page" }) |path| {
        const file = try openPrerendered(t.allocator, dist, path);
        file.close();
    }
    for ([_][]const u8{ "/../outside", "/docs/../../outside", "/link", "/%2e%2e/outside", "/docs\\../outside" }) |path| {
        try t.expectError(error.AccessDenied, openPrerendered(t.allocator, dist, path));
    }
}
