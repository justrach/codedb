const std = @import("std");
const cio = @import("cio.zig");
const builtin = @import("builtin");
const sty = @import("style.zig");
const release_info = @import("release_info.zig");

const github_repo = "justrach/codedb";
const default_base_url = "https://codedb.codegraff.com";
const user_agent = "codedb-update";

const Out = struct {
    file: std.fs.File,
    alloc: std.mem.Allocator,

    fn p(self: Out, comptime fmt: []const u8, args: anytype) void {
        const str = std.fmt.allocPrint(self.alloc, fmt, args) catch return;
        defer self.alloc.free(str);
        self.file.writeAll(str) catch {};
    }
};

const VersionSource = enum {
    env,
    github,
    fallback,
};

const ResolvedVersion = struct {
    value: []u8,
    source: VersionSource,
};

pub fn run(stdout: std.fs.File, s: sty.Style, allocator: std.mem.Allocator) void {
    const out = Out{ .file = stdout, .alloc = allocator };

    const resolved = resolveTargetVersion(allocator) catch |err| {
        out.p("{s}✗{s} failed to resolve update target: {s}\n", .{ s.red, s.reset, @errorName(err) });
        std.process.exit(1);
    };
    defer allocator.free(resolved.value);

    const version_order = compareVersions(release_info.semver, resolved.value) catch |err| {
        out.p("{s}✗{s} invalid release version: {s}\n", .{ s.red, s.reset, @errorName(err) });
        std.process.exit(1);
    };

    switch (version_order) {
        .eq => {
            out.p("codedb {s} is already up to date\n", .{release_info.semver});
            return;
        },
        .gt => {
            out.p("{s}✗{s} refusing to replace codedb {s} with older release {s}\n", .{ s.red, s.reset, release_info.semver, resolved.value });
            std.process.exit(1);
        },
        .lt => {},
    }

    const asset_name = assetNameForTarget(builtin.os.tag, builtin.cpu.arch) orelse {
        out.p("{s}✗{s} self-update is unsupported on this platform\n", .{ s.red, s.reset });
        std.process.exit(1);
    };

    out.p("updating codedb {s} -> {s}\n", .{ release_info.semver, resolved.value });
    out.p("  source: {s}\n", .{switch (resolved.source) {
        .env => "CODEDB_VERSION",
        .github => "github releases",
        .fallback => "codedb.codegraff.com/latest.json",
    }});
    out.p("  asset:  {s}\n", .{asset_name});

    const manifest = fetchChecksumsManifest(allocator, resolved.value) catch |err| {
        out.p("{s}✗{s} failed to download checksums for v{s}: {s}\n", .{ s.red, s.reset, resolved.value, @errorName(err) });
        std.process.exit(1);
    };
    defer allocator.free(manifest);

    const expected_hash = checksumForBinary(manifest, asset_name) orelse {
        out.p("{s}✗{s} release v{s} is missing a checksum for {s}\n", .{ s.red, s.reset, resolved.value, asset_name });
        std.process.exit(1);
    };

    const self_path = std.fs.selfExePathAlloc(allocator) catch |err| {
        out.p("{s}✗{s} cannot locate current executable: {s}\n", .{ s.red, s.reset, @errorName(err) });
        std.process.exit(1);
    };
    defer allocator.free(self_path);

    downloadAndReplaceBinary(allocator, resolved.value, asset_name, self_path, expected_hash) catch |err| {
        out.p("{s}✗{s} update failed: {s}\n", .{ s.red, s.reset, @errorName(err) });
        std.process.exit(1);
    };

    out.p("{s}✓{s} updated to codedb {s}\n", .{ s.green, s.reset, resolved.value });
}

pub fn assetNameForTarget(os_tag: std.Target.Os.Tag, arch: std.Target.Cpu.Arch) ?[]const u8 {
    return switch (os_tag) {
        .macos => switch (arch) {
            .aarch64 => "codedb-darwin-arm64",
            .x86_64 => "codedb-darwin-x86_64",
            else => null,
        },
        .linux => switch (arch) {
            .aarch64 => "codedb-linux-arm64",
            .x86_64 => "codedb-linux-x86_64",
            else => null,
        },
        else => null,
    };
}

pub fn compareVersions(current: []const u8, target: []const u8) !std.math.Order {
    var current_it = std.mem.splitScalar(u8, trimVersionPrefix(current), '.');
    var target_it = std.mem.splitScalar(u8, trimVersionPrefix(target), '.');

    while (true) {
        const current_part = current_it.next();
        const target_part = target_it.next();

        if (current_part == null and target_part == null) return .eq;

        const current_num = if (current_part) |part| try parseVersionPart(part) else 0;
        const target_num = if (target_part) |part| try parseVersionPart(part) else 0;

        if (current_num < target_num) return .lt;
        if (current_num > target_num) return .gt;
    }
}

pub fn checksumForBinary(manifest: []const u8, binary_name: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, manifest, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;

        const hash_end = std.mem.indexOfAny(u8, line, " \t") orelse continue;
        const hash = line[0..hash_end];
        var name = std.mem.trimLeft(u8, line[hash_end..], " \t");
        if (name.len == 0) continue;
        if (name[0] == '*') name = name[1..];
        if (std.mem.eql(u8, name, binary_name)) return hash;
    }

    return null;
}

fn resolveTargetVersion(allocator: std.mem.Allocator) !ResolvedVersion {
    const explicit = std.process.getEnvVarOwned(allocator, "CODEDB_VERSION") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    if (explicit) |value| {
        return .{ .value = value, .source = .env };
    }

    if (fetchLatestVersionFromGitHub(allocator) catch null) |value| {
        return .{ .value = value, .source = .github };
    }

    if (fetchLatestVersionFromFallback(allocator) catch null) |value| {
        return .{ .value = value, .source = .fallback };
    }

    return error.CouldNotResolveLatestVersion;
}

fn fetchLatestVersionFromGitHub(allocator: std.mem.Allocator) !?[]u8 {
    const response = fetchUrlToMemory(allocator, "https://api.github.com/repos/" ++ github_repo ++ "/releases/latest", 1 * 1024 * 1024) catch return null;
    defer allocator.free(response);
    return parseJsonStringField(allocator, response, "tag_name", true);
}

fn fetchLatestVersionFromFallback(allocator: std.mem.Allocator) !?[]u8 {
    const base_url = try getBaseUrl(allocator);
    defer if (base_url.owned) allocator.free(base_url.value);

    const url = try std.fmt.allocPrint(allocator, "{s}/latest.json", .{base_url.value});
    defer allocator.free(url);

    const response = fetchUrlToMemory(allocator, url, 256 * 1024) catch return null;
    defer allocator.free(response);
    return parseJsonStringField(allocator, response, "version", false);
}

fn fetchChecksumsManifest(allocator: std.mem.Allocator, version: []const u8) ![]u8 {
    const url = try std.fmt.allocPrint(allocator, "https://github.com/{s}/releases/download/v{s}/checksums.sha256", .{ github_repo, version });
    defer allocator.free(url);
    return fetchUrlToMemory(allocator, url, 256 * 1024);
}

fn fetchUrlToMemory(allocator: std.mem.Allocator, url: []const u8, max_output_bytes: usize) ![]u8 {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "curl", "-fsSL", "-A", user_agent, url },
        .max_output_bytes = max_output_bytes,
    });
    defer allocator.free(result.stderr);

    if (result.term != .Exited or result.term.Exited != 0) {
        allocator.free(result.stdout);
        return error.CurlFailed;
    }

    return result.stdout;
}

fn parseJsonStringField(allocator: std.mem.Allocator, json_text: []const u8, field_name: []const u8, trim_v_prefix: bool) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_text, .{}) catch return null;
    defer parsed.deinit();

    if (parsed.value != .object) return null;
    const field = parsed.value.object.get(field_name) orelse return null;
    if (field != .string) return null;

    const value = if (trim_v_prefix) trimVersionPrefix(field.string) else field.string;
    if (value.len == 0) return null;
    return try allocator.dupe(u8, value);
}

fn getBaseUrl(allocator: std.mem.Allocator) !struct { value: []const u8, owned: bool } {
    const env_value = std.process.getEnvVarOwned(allocator, "CODEDB_URL") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    if (env_value) |value| {
        return .{ .value = value, .owned = true };
    }
    return .{ .value = default_base_url, .owned = false };
}

fn trimVersionPrefix(value: []const u8) []const u8 {
    return std.mem.trimLeft(u8, value, "vV");
}

fn parseVersionPart(part: []const u8) !u64 {
    const trimmed = std.mem.trim(u8, part, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidVersion;
    return std.fmt.parseInt(u64, trimmed, 10);
}

fn downloadAndReplaceBinary(allocator: std.mem.Allocator, version: []const u8, asset_name: []const u8, dest_path: []const u8, expected_hash: []const u8) !void {
    const url = try std.fmt.allocPrint(allocator, "https://github.com/{s}/releases/download/v{s}/{s}", .{ github_repo, version, asset_name });
    defer allocator.free(url);

    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp.{d}", .{ dest_path, cio.nanoTimestamp() });
    defer allocator.free(tmp_path);
    errdefer std.fs.deleteFileAbsolute(tmp_path) catch {};

    try downloadToFile(allocator, url, tmp_path);

    const actual_hash = try sha256FileHex(allocator, tmp_path);
    defer allocator.free(actual_hash);
    if (!std.ascii.eqlIgnoreCase(actual_hash, expected_hash)) {
        return error.ChecksumMismatch;
    }

    {
        var tmp_file = try std.fs.openFileAbsolute(tmp_path, .{ .mode = .read_write });
        defer tmp_file.close();
        try tmp_file.chmod(0o755);
    }

    try std.fs.renameAbsolute(tmp_path, dest_path);
}

fn downloadToFile(allocator: std.mem.Allocator, url: []const u8, dest_path: []const u8) !void {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "curl", "-fsSL", "-A", user_agent, url, "-o", dest_path },
        .max_output_bytes = 16 * 1024,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term != .Exited or result.term.Exited != 0) {
        return error.DownloadFailed;
    }
}

fn sha256FileHex(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [16 * 1024]u8 = undefined;
    while (true) {
        const read_len = try file.read(&buf);
        if (read_len == 0) break;
        hasher.update(buf[0..read_len]);
    }

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    const digest_hex = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &digest_hex);
}
