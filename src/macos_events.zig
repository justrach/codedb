//! Recursive notifications for local APFS/HFS projects. Other filesystems and
//! unavailable streams keep the existing bounded kqueue/polling watcher.
const std = @import("std");
const builtin = @import("builtin");
const cio = @import("cio.zig");

const Ref = *anyopaque;
const Context = extern struct { version: isize = 0, info: ?*anyopaque, retain: ?*anyopaque = null, release: ?*anyopaque = null, describe: ?*anyopaque = null };
const Callback = *const fn (Ref, ?*anyopaque, usize, *anyopaque, [*]const u32, [*]const u64) callconv(.c) void;
const Api = struct {
    CFStringCreateWithCString: *const fn (?Ref, [*:0]const u8, u32) callconv(.c) ?Ref,
    CFArrayCreate: *const fn (?Ref, [*]const Ref, isize, ?*const anyopaque) callconv(.c) ?Ref,
    CFRelease: *const fn (Ref) callconv(.c) void,
    FSEventStreamCreate: *const fn (?Ref, Callback, *Context, Ref, u64, f64, u32) callconv(.c) ?Ref,
    FSEventStreamSetDispatchQueue: *const fn (Ref, Ref) callconv(.c) void,
    FSEventStreamStart: *const fn (Ref) callconv(.c) u8,
    FSEventStreamStop: *const fn (Ref) callconv(.c) void,
    FSEventStreamInvalidate: *const fn (Ref) callconv(.c) void,
    FSEventStreamRelease: *const fn (Ref) callconv(.c) void,
};
extern "c" fn dispatch_queue_create([*:0]const u8, ?Ref) ?Ref;
extern "c" fn dispatch_sync_f(Ref, ?*anyopaque, *const fn (?*anyopaque) callconv(.c) void) void;
extern "c" fn dispatch_release(Ref) void;

// Darwin's 64-bit statfs ABI, from sys/mount.h. Restrict the optimization to
// local filesystems whose recursive notification support is known.
const Statfs = extern struct {
    bsize: u32,
    iosize: i32,
    blocks: u64,
    bfree: u64,
    bavail: u64,
    files: u64,
    ffree: u64,
    fsid: [2]i32,
    owner: u32,
    kind: u32,
    flags: u32,
    subtype: u32,
    typename: [16]u8,
    mounted_on: [1024]u8,
    mounted_from: [1024]u8,
    flags_ext: u32,
    reserved: [7]u32,
};
extern "c" fn fstatfs(c_int, *Statfs) c_int;
extern "c" fn @"fstatfs$INODE64"(c_int, *Statfs) c_int;
fn statVolume(fd: c_int, out: *Statfs) c_int {
    return if (builtin.cpu.arch == .x86_64) @"fstatfs$INODE64"(fd, out) else fstatfs(fd, out);
}

pub fn sameVolume(a: std.Io.Dir, b: std.Io.Dir) bool {
    if (comptime builtin.os.tag != .macos) return true;
    var first: Statfs = undefined;
    var second: Statfs = undefined;
    return statVolume(a.handle, &first) == 0 and statVolume(b.handle, &second) == 0 and
        first.flags & 0x1000 != 0 and second.flags & 0x1000 != 0 and std.meta.eql(first.fsid, second.fsid);
}

pub const Stream = struct {
    alloc: std.mem.Allocator,
    cf: std.DynLib,
    fs: std.DynLib,
    api: Api,
    stream: Ref,
    dispatch: Ref,
    root_string: Ref,
    roots: Ref,
    root: [:0]u8,
    mu: cio.Mutex = .{},
    pending: std.StringHashMap(void),
    rescan: bool = false,
    fallback: bool = false,

    pub fn create(alloc: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !?*Stream {
        if (comptime builtin.os.tag != .macos) return null;
        if (cio.posixGetenv("CODEDB_NO_FSEVENTS") != null) return null;
        var stat: Statfs = undefined;
        if (statVolume(dir.handle, &stat) != 0 or stat.flags & 0x1000 == 0) return null; // MNT_LOCAL
        const kind = std.mem.sliceTo(&stat.typename, 0);
        if (!std.mem.eql(u8, kind, "apfs") and !std.mem.eql(u8, kind, "hfs")) return null;
        var root_buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try dir.realPath(io, &root_buf);
        const root = try alloc.dupeSentinel(u8, root_buf[0..n], 0);
        errdefer alloc.free(root);
        var cf = try std.DynLib.open("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation");
        errdefer cf.close();
        var fs = try std.DynLib.open("/System/Library/Frameworks/CoreServices.framework/Frameworks/FSEvents.framework/FSEvents");
        errdefer fs.close();
        var api: Api = undefined;
        inline for (@typeInfo(Api).@"struct".field_names, @typeInfo(Api).@"struct".field_types) |field_name, field_type| {
            const lib = if (comptime std.mem.startsWith(u8, field_name, "CF")) &cf else &fs;
            @field(api, field_name) = lib.lookup(field_type, field_name) orelse return error.MissingFSEventsSymbol;
        }
        const string = api.CFStringCreateWithCString(null, root, 0x08000100) orelse return error.OutOfMemory;
        errdefer api.CFRelease(string);
        // Keep string alive explicitly: this array intentionally has no callbacks.
        const roots = api.CFArrayCreate(null, &.{string}, 1, null) orelse return error.OutOfMemory;
        errdefer api.CFRelease(roots);
        const queue = dispatch_queue_create("codedb.filesystem", null) orelse return error.OutOfMemory;
        errdefer dispatch_release(queue);
        const self = try alloc.create(Stream);
        errdefer alloc.destroy(self);
        self.* = .{ .alloc = alloc, .cf = cf, .fs = fs, .api = api, .stream = undefined, .dispatch = queue, .root_string = string, .roots = roots, .root = root, .pending = .init(alloc) };
        errdefer {
            var keys = self.pending.keyIterator();
            while (keys.next()) |key| alloc.free(key.*);
            self.pending.deinit();
        }
        var context: Context = .{ .info = self };
        // SinceNow; NoDefer | WatchRoot | FileEvents. Coalesced/dropped history
        // always requests a full content audit rather than assuming completeness.
        const stream = api.FSEventStreamCreate(null, receive, &context, roots, std.math.maxInt(u64), 0.1, 0x16) orelse return error.FSEventsUnavailable;
        self.stream = stream;
        errdefer api.FSEventStreamRelease(stream);
        api.FSEventStreamSetDispatchQueue(stream, queue);
        if (api.FSEventStreamStart(stream) == 0) {
            api.FSEventStreamInvalidate(stream);
            dispatch_sync_f(queue, null, barrier);
            return error.FSEventsUnavailable;
        }
        return self;
    }

    fn barrier(_: ?*anyopaque) callconv(.c) void {}

    pub fn destroy(self: *Stream) void {
        if (comptime builtin.os.tag != .macos) return;
        self.api.FSEventStreamStop(self.stream);
        self.api.FSEventStreamInvalidate(self.stream);
        // Drain this private serial queue before freeing callback context.
        dispatch_sync_f(self.dispatch, null, barrier);
        self.api.FSEventStreamRelease(self.stream);
        dispatch_release(self.dispatch);
        var it = self.pending.keyIterator();
        while (it.next()) |key| self.alloc.free(key.*);
        self.pending.deinit();
        self.api.CFRelease(self.roots);
        self.api.CFRelease(self.root_string);
        self.cf.close();
        self.fs.close();
        self.alloc.free(self.root);
        const alloc = self.alloc;
        alloc.destroy(self);
    }

    fn receive(_: Ref, info: ?*anyopaque, count: usize, paths_raw: *anyopaque, flags: [*]const u32, _: [*]const u64) callconv(.c) void {
        const self: *Stream = @ptrCast(@alignCast(info.?));
        const paths: [*]const [*:0]const u8 = @ptrCast(@alignCast(paths_raw));
        self.mu.lock();
        defer self.mu.unlock();
        for (0..count) |i| {
            if (flags[i] & 0xe0 != 0) self.fallback = true; // root/mount changes
            if (flags[i] & 0x0f != 0) self.rescan = true; // dropped/coalesced history
            const full = std.mem.span(paths[i]);
            if (!std.mem.startsWith(u8, full, self.root)) {
                self.rescan = true;
                continue;
            }
            const suffix = full[self.root.len..];
            if (suffix.len > 0 and suffix[0] != '/') {
                self.rescan = true;
                continue;
            }
            const rel = std.mem.trim(u8, suffix, "/");
            if (self.pending.contains(rel)) continue;
            if (self.pending.count() >= 2048) {
                self.rescan = true;
                continue;
            }
            const copy = self.alloc.dupe(u8, rel) catch {
                self.rescan = true;
                continue;
            };
            self.pending.put(copy, {}) catch {
                self.alloc.free(copy);
                self.rescan = true;
            };
        }
    }

    pub const Drain = struct { rescan: bool, fallback: bool };
    pub fn drain(self: *Stream, dirty: *std.StringHashMap(void)) Drain {
        self.mu.lock();
        defer self.mu.unlock();
        var it = self.pending.keyIterator();
        while (it.next()) |key| {
            if (dirty.contains(key.*)) {
                self.alloc.free(key.*);
                continue;
            }
            const copy = dirty.allocator.dupe(u8, key.*) catch {
                self.rescan = true;
                self.alloc.free(key.*);
                continue;
            };
            dirty.put(copy, {}) catch {
                dirty.allocator.free(copy);
                self.rescan = true;
            };
            self.alloc.free(key.*);
        }
        self.pending.clearRetainingCapacity();
        const result: Drain = .{ .rescan = self.rescan, .fallback = self.fallback };
        self.rescan = false;
        return result;
    }
};

test "recursive events coalesce paths and surface dropped history and root changes" {
    const t = std.testing;
    var stream: Stream = undefined;
    stream.alloc = t.allocator;
    stream.root = @constCast("/project");
    stream.mu = .{};
    stream.pending = .init(t.allocator);
    stream.rescan = false;
    stream.fallback = false;
    defer {
        var it = stream.pending.keyIterator();
        while (it.next()) |key| t.allocator.free(key.*);
        stream.pending.deinit();
    }
    var dirty = std.StringHashMap(void).init(t.allocator);
    defer {
        var it = dirty.keyIterator();
        while (it.next()) |key| t.allocator.free(key.*);
        dirty.deinit();
    }
    const paths = [_][*:0]const u8{ "/project/src/a.py", "/project/src/a.py" };
    Stream.receive(undefined, &stream, paths.len, @ptrCast(@constCast(&paths)), &.{ 0x1000, 0x1000 }, &.{ 1, 2 });
    try t.expectEqual(@as(u32, 1), stream.pending.count());
    const first = stream.drain(&dirty);
    try t.expect(!first.rescan and !first.fallback);
    try t.expect(dirty.contains("src/a.py"));
    // Draining a duplicate into a nonempty dirty set must not leak its key.
    Stream.receive(undefined, &stream, 1, @ptrCast(@constCast(&paths)), &.{0x1}, &.{3});
    try t.expect(stream.drain(&dirty).rescan);
    Stream.receive(undefined, &stream, 1, @ptrCast(@constCast(&paths)), &.{0x20}, &.{4});
    try t.expect(stream.drain(&dirty).fallback);
    stream.fallback = false;
    const outside = [_][*:0]const u8{"/project-other/private.py"};
    Stream.receive(undefined, &stream, 1, @ptrCast(@constCast(&outside)), &.{0}, &.{5});
    try t.expect(stream.drain(&dirty).rescan);
    try t.expectEqual(@as(u32, 1), dirty.count());
}
