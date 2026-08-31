//! Zero-touch, device-bound authentication for the hosted embedding lane.
//!
//! Each CodeDB installation owns an Ed25519 seed stored in a private global
//! credential file. The seed never enters a request. The edge issues a
//! server-signed certificate for the derived public key, and every embedding
//! request proves possession of the seed by signing its method, path, body
//! digest, timestamp, and one-time nonce.

const std = @import("std");
const builtin = @import("builtin");
const cio = @import("cio.zig");
const release_info = @import("release_info.zig");
const project_file = @import("project_file.zig");

const Ed25519 = std.crypto.sign.Ed25519;
const Sha256 = std.crypto.hash.sha2.Sha256;
const b64 = std.base64.url_safe_no_pad;

pub const enrollment_url = "https://embeddings.wiki.codes/v1/codedb/installations";
pub const certificate_verification_key = "ycZkQh7N8gUpjgujqDc6Uuxtu2SNbWKaA9R3JDBP-_0";
pub const credential_file_name = "credentials.json";
pub const renewal_window_seconds: i64 = 24 * 60 * 60;
const max_credential_bytes = 8 * 1024;
const max_certificate_bytes = 2048;

const DiskCredential = struct {
    version: u8 = 1,
    seed: []const u8,
    installation_id: ?[]const u8,
    certificate: ?[]const u8,
    expires_at: i64,
};

pub const DeviceCredential = struct {
    allocator: std.mem.Allocator,
    dir_path: []u8,
    seed: [Ed25519.KeyPair.seed_length]u8,
    installation_id: ?[]u8,
    certificate: ?[]u8,
    expires_at: i64,

    pub fn deinit(self: *DeviceCredential) void {
        std.crypto.secureZero(u8, &self.seed);
        self.allocator.free(self.dir_path);
        if (self.installation_id) |value| self.allocator.free(value);
        if (self.certificate) |value| self.allocator.free(value);
        self.* = undefined;
    }

    pub fn needsEnrollment(self: DeviceCredential, now_seconds: i64) bool {
        return self.installation_id == null or self.certificate == null or
            self.expires_at <= now_seconds + renewal_window_seconds;
    }

    pub fn publicKeyBase64(self: DeviceCredential, out: *[b64.Encoder.calcSize(Ed25519.PublicKey.encoded_length)]u8) ![]const u8 {
        const key_pair = try Ed25519.KeyPair.generateDeterministic(self.seed);
        return b64.Encoder.encode(out, &key_pair.public_key.toBytes());
    }

    pub fn enrollmentBody(self: DeviceCredential, io: std.Io, allocator: std.mem.Allocator) ![]u8 {
        const key_pair = try Ed25519.KeyPair.generateDeterministic(self.seed);
        var public_buf: [b64.Encoder.calcSize(Ed25519.PublicKey.encoded_length)]u8 = undefined;
        const public_key = b64.Encoder.encode(&public_buf, &key_pair.public_key.toBytes());
        const timestamp = @divFloor(cio.milliTimestamp(), 1000);
        var nonce_bytes: [16]u8 = undefined;
        io.random(&nonce_bytes);
        var nonce_buf: [b64.Encoder.calcSize(nonce_bytes.len)]u8 = undefined;
        const nonce = b64.Encoder.encode(&nonce_buf, &nonce_bytes);
        const platform = @tagName(builtin.cpu.arch) ++ "-" ++ @tagName(builtin.os.tag);
        const base = try std.fmt.allocPrint(
            allocator,
            "codedb-enrollment-v1\n{d}\n{s}\n{s}\n{s}\n{s}",
            .{ timestamp, nonce, public_key, release_info.semver, platform },
        );
        defer allocator.free(base);
        const signature = try key_pair.sign(base, null);
        var signature_buf: [b64.Encoder.calcSize(Ed25519.Signature.encoded_length)]u8 = undefined;
        const encoded_signature = b64.Encoder.encode(&signature_buf, &signature.toBytes());

        const payload = .{
            .version = @as(u8, 1),
            .public_key = public_key,
            .timestamp = timestamp,
            .nonce = nonce,
            .signature = encoded_signature,
            .client_version = release_info.semver,
            .platform = platform,
        };
        return std.json.Stringify.valueAlloc(allocator, payload, .{});
    }

    pub fn applyEnrollmentResponse(
        self: *DeviceCredential,
        io: std.Io,
        allocator: std.mem.Allocator,
        response: []const u8,
    ) !void {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidDeviceEnrollmentResponse;
        const object = parsed.value.object;
        const version = object.get("version") orelse return error.InvalidDeviceEnrollmentResponse;
        const id_value = object.get("installation_id") orelse return error.InvalidDeviceEnrollmentResponse;
        const certificate_value = object.get("certificate") orelse return error.InvalidDeviceEnrollmentResponse;
        const expires_value = object.get("expires_at") orelse return error.InvalidDeviceEnrollmentResponse;
        if (version != .integer or version.integer != 1 or id_value != .string or
            certificate_value != .string or expires_value != .integer) return error.InvalidDeviceEnrollmentResponse;
        const installation_id = id_value.string;
        const certificate = certificate_value.string;
        const expires_at = expires_value.integer;
        if (!validInstallationId(installation_id) or certificate.len > max_certificate_bytes or
            !std.mem.startsWith(u8, certificate, "cdb_cert_v1.") or
            expires_at <= @divFloor(cio.milliTimestamp(), 1000)) return error.InvalidDeviceEnrollmentResponse;

        var public_buf: [b64.Encoder.calcSize(Ed25519.PublicKey.encoded_length)]u8 = undefined;
        const public_key = try self.publicKeyBase64(&public_buf);
        try verifyServerCertificate(allocator, certificate, installation_id, public_key, expires_at);

        const new_id = try self.allocator.dupe(u8, installation_id);
        errdefer self.allocator.free(new_id);
        const new_certificate = try self.allocator.dupe(u8, certificate);
        errdefer self.allocator.free(new_certificate);
        try writeCredentialAtomic(io, self.dir_path, self.seed, new_id, new_certificate, expires_at, allocator);

        if (self.installation_id) |old| self.allocator.free(old);
        if (self.certificate) |old| self.allocator.free(old);
        self.installation_id = new_id;
        self.certificate = new_certificate;
        self.expires_at = expires_at;
    }

    pub fn requestProof(
        self: DeviceCredential,
        io: std.Io,
        allocator: std.mem.Allocator,
        url: []const u8,
        body: []const u8,
    ) !RequestProof {
        const installation_id = self.installation_id orelse return error.DeviceEnrollmentRequired;
        const certificate = self.certificate orelse return error.DeviceEnrollmentRequired;
        if (self.expires_at <= @divFloor(cio.milliTimestamp(), 1000)) return error.DeviceEnrollmentRequired;

        const uri = std.Uri.parse(url) catch return error.InvalidEmbeddingConfig;
        var path_buf: [2048]u8 = undefined;
        const path = try uri.path.toRaw(&path_buf);
        const signed_path = if (path.len == 0) "/" else path;
        const timestamp = @divFloor(cio.milliTimestamp(), 1000);
        var nonce_bytes: [16]u8 = undefined;
        io.random(&nonce_bytes);
        var nonce_buf: [b64.Encoder.calcSize(nonce_bytes.len)]u8 = undefined;
        const nonce = b64.Encoder.encode(&nonce_buf, &nonce_bytes);

        var digest: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(body, &digest, .{});
        var digest_buf: [b64.Encoder.calcSize(digest.len)]u8 = undefined;
        const body_digest = b64.Encoder.encode(&digest_buf, &digest);
        const base = try requestSignatureBase(
            allocator,
            installation_id,
            timestamp,
            nonce,
            "POST",
            signed_path,
            body_digest,
        );
        defer allocator.free(base);
        const key_pair = try Ed25519.KeyPair.generateDeterministic(self.seed);
        const signature = try key_pair.sign(base, null);
        var signature_buf: [b64.Encoder.calcSize(Ed25519.Signature.encoded_length)]u8 = undefined;
        const encoded_signature = b64.Encoder.encode(&signature_buf, &signature.toBytes());

        const authorization = try std.fmt.allocPrint(allocator, "CodeDB {s}", .{certificate});
        errdefer allocator.free(authorization);
        const timestamp_header = try std.fmt.allocPrint(allocator, "{d}", .{timestamp});
        errdefer allocator.free(timestamp_header);
        const nonce_header = try allocator.dupe(u8, nonce);
        errdefer allocator.free(nonce_header);
        const signature_header = try allocator.dupe(u8, encoded_signature);
        return .{
            .allocator = allocator,
            .authorization = authorization,
            .timestamp = timestamp_header,
            .nonce = nonce_header,
            .signature = signature_header,
        };
    }
};

pub const RequestProof = struct {
    allocator: std.mem.Allocator,
    authorization: []u8,
    timestamp: []u8,
    nonce: []u8,
    signature: []u8,

    pub fn deinit(self: *RequestProof) void {
        self.allocator.free(self.authorization);
        self.allocator.free(self.timestamp);
        self.allocator.free(self.nonce);
        self.allocator.free(self.signature);
        self.* = undefined;
    }
};

pub fn requestSignatureBase(
    allocator: std.mem.Allocator,
    installation_id: []const u8,
    timestamp: i64,
    nonce: []const u8,
    method: []const u8,
    path: []const u8,
    body_digest: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "codedb-request-v1\n{s}\n{d}\n{s}\n{s}\n{s}\n{s}",
        .{ installation_id, timestamp, nonce, method, path, body_digest },
    );
}

pub fn loadOrCreate(io: std.Io, allocator: std.mem.Allocator) !DeviceCredential {
    const home = cio.homeDir() orelse return error.HomeDirectoryUnavailable;
    const dir_path = try std.fmt.allocPrint(allocator, "{s}/.codedb", .{home});
    defer allocator.free(dir_path);
    return loadOrCreateAt(io, allocator, dir_path);
}

pub fn loadOrCreateAt(io: std.Io, allocator: std.mem.Allocator, dir_path: []const u8) !DeviceCredential {
    try std.Io.Dir.cwd().createDirPath(io, dir_path);
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .follow_symlinks = false });
    defer dir.close(io);

    if (try readCredential(io, allocator, dir, dir_path)) |credential| return credential;

    var seed: [Ed25519.KeyPair.seed_length]u8 = undefined;
    io.random(&seed);
    errdefer std.crypto.secureZero(u8, &seed);
    const initial = try stringifyCredential(allocator, seed, null, null, 0);
    defer allocator.free(initial);
    const file = dir.createFile(io, credential_file_name, .{
        .exclusive = true,
        .permissions = privateFilePermissions(),
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.PathAlreadyExists => return (try readCredential(io, allocator, dir, dir_path)) orelse error.InvalidDeviceCredentials,
        else => return err,
    };
    var initial_file_owned = true;
    errdefer if (initial_file_owned) dir.deleteFile(io, credential_file_name) catch {};
    defer file.close(io);
    try file.writeStreamingAll(io, initial);
    try file.sync(io);
    initial_file_owned = false;
    return .{
        .allocator = allocator,
        .dir_path = try allocator.dupe(u8, dir_path),
        .seed = seed,
        .installation_id = null,
        .certificate = null,
        .expires_at = 0,
    };
}

fn readCredential(
    io: std.Io,
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
    dir_path: []const u8,
) !?DeviceCredential {
    var file = dir.openFile(io, credential_file_name, .{
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    project_file.prepareNoFollowFile(&file);
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.size > max_credential_bytes) return error.InvalidDeviceCredentials;
    const storage = try allocator.alloc(u8, @intCast(stat.size));
    defer allocator.free(storage);
    if (try file.readPositionalAll(io, storage, 0) != storage.len) return error.InvalidDeviceCredentials;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, storage, .{}) catch
        return error.InvalidDeviceCredentials;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidDeviceCredentials;
    const object = parsed.value.object;
    const version = object.get("version") orelse return error.InvalidDeviceCredentials;
    const seed_value = object.get("seed") orelse return error.InvalidDeviceCredentials;
    const expires_value = object.get("expires_at") orelse return error.InvalidDeviceCredentials;
    if (version != .integer or version.integer != 1 or seed_value != .string or
        expires_value != .integer) return error.InvalidDeviceCredentials;
    var seed: [Ed25519.KeyPair.seed_length]u8 = undefined;
    const decoded_size = b64.Decoder.calcSizeForSlice(seed_value.string) catch return error.InvalidDeviceCredentials;
    if (decoded_size != seed.len) return error.InvalidDeviceCredentials;
    b64.Decoder.decode(&seed, seed_value.string) catch return error.InvalidDeviceCredentials;
    _ = Ed25519.KeyPair.generateDeterministic(seed) catch return error.InvalidDeviceCredentials;

    const id_value = object.get("installation_id");
    const certificate_value = object.get("certificate");
    const installation_id: ?[]u8 = if (id_value == null or id_value.? == .null)
        null
    else if (id_value.? == .string and validInstallationId(id_value.?.string))
        try allocator.dupe(u8, id_value.?.string)
    else
        return error.InvalidDeviceCredentials;
    errdefer if (installation_id) |value| allocator.free(value);
    const certificate: ?[]u8 = if (certificate_value == null or certificate_value.? == .null)
        null
    else if (certificate_value.? == .string and certificate_value.?.string.len <= max_certificate_bytes and
        std.mem.startsWith(u8, certificate_value.?.string, "cdb_cert_v1."))
        try allocator.dupe(u8, certificate_value.?.string)
    else
        return error.InvalidDeviceCredentials;
    errdefer if (certificate) |value| allocator.free(value);
    if ((installation_id == null) != (certificate == null)) return error.InvalidDeviceCredentials;

    return .{
        .allocator = allocator,
        .dir_path = try allocator.dupe(u8, dir_path),
        .seed = seed,
        .installation_id = installation_id,
        .certificate = certificate,
        .expires_at = expires_value.integer,
    };
}

fn stringifyCredential(
    allocator: std.mem.Allocator,
    seed: [Ed25519.KeyPair.seed_length]u8,
    installation_id: ?[]const u8,
    certificate: ?[]const u8,
    expires_at: i64,
) ![]u8 {
    var seed_buf: [b64.Encoder.calcSize(Ed25519.KeyPair.seed_length)]u8 = undefined;
    const encoded_seed = b64.Encoder.encode(&seed_buf, &seed);
    return std.json.Stringify.valueAlloc(allocator, DiskCredential{
        .seed = encoded_seed,
        .installation_id = installation_id,
        .certificate = certificate,
        .expires_at = expires_at,
    }, .{});
}

fn writeCredentialAtomic(
    io: std.Io,
    dir_path: []const u8,
    seed: [Ed25519.KeyPair.seed_length]u8,
    installation_id: []const u8,
    certificate: []const u8,
    expires_at: i64,
    allocator: std.mem.Allocator,
) !void {
    const data = try stringifyCredential(allocator, seed, installation_id, certificate, expires_at);
    defer allocator.free(data);
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .follow_symlinks = false });
    defer dir.close(io);
    const tmp_name = try std.fmt.allocPrint(allocator, "credentials.{x}.tmp", .{cio.randU64()});
    defer allocator.free(tmp_name);
    errdefer dir.deleteFile(io, tmp_name) catch {};
    var file = try dir.createFile(io, tmp_name, .{
        .exclusive = true,
        .permissions = privateFilePermissions(),
        .resolve_beneath = true,
    });
    var open = true;
    defer if (open) file.close(io);
    try file.writeStreamingAll(io, data);
    try file.sync(io);
    file.close(io);
    open = false;
    try dir.rename(tmp_name, dir, credential_file_name, io);
}

fn verifyServerCertificate(
    allocator: std.mem.Allocator,
    certificate: []const u8,
    installation_id: []const u8,
    device_public_key: []const u8,
    expires_at: i64,
) !void {
    var parts = std.mem.splitScalar(u8, certificate, '.');
    if (!std.mem.eql(u8, parts.next() orelse return error.InvalidDeviceCertificate, "cdb_cert_v1"))
        return error.InvalidDeviceCertificate;
    const encoded_payload = parts.next() orelse return error.InvalidDeviceCertificate;
    const encoded_signature = parts.next() orelse return error.InvalidDeviceCertificate;
    if (parts.next() != null) return error.InvalidDeviceCertificate;

    var server_key_bytes: [Ed25519.PublicKey.encoded_length]u8 = undefined;
    if ((b64.Decoder.calcSizeForSlice(certificate_verification_key) catch return error.InvalidDeviceCertificate) != server_key_bytes.len)
        return error.InvalidDeviceCertificate;
    b64.Decoder.decode(&server_key_bytes, certificate_verification_key) catch return error.InvalidDeviceCertificate;
    const server_key = Ed25519.PublicKey.fromBytes(server_key_bytes) catch return error.InvalidDeviceCertificate;
    var signature_bytes: [Ed25519.Signature.encoded_length]u8 = undefined;
    if ((b64.Decoder.calcSizeForSlice(encoded_signature) catch return error.InvalidDeviceCertificate) != signature_bytes.len)
        return error.InvalidDeviceCertificate;
    b64.Decoder.decode(&signature_bytes, encoded_signature) catch return error.InvalidDeviceCertificate;
    Ed25519.Signature.fromBytes(signature_bytes).verifyStrict(encoded_payload, server_key) catch
        return error.InvalidDeviceCertificate;

    const payload_len = b64.Decoder.calcSizeForSlice(encoded_payload) catch return error.InvalidDeviceCertificate;
    if (payload_len > 1024) return error.InvalidDeviceCertificate;
    const payload = try allocator.alloc(u8, payload_len);
    defer allocator.free(payload);
    b64.Decoder.decode(payload, encoded_payload) catch return error.InvalidDeviceCertificate;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch
        return error.InvalidDeviceCertificate;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidDeviceCertificate;
    const object = parsed.value.object;
    const version = object.get("v") orelse return error.InvalidDeviceCertificate;
    const cert_id = object.get("installation_id") orelse return error.InvalidDeviceCertificate;
    const cert_key = object.get("public_key") orelse return error.InvalidDeviceCertificate;
    const cert_expiry = object.get("expires_at") orelse return error.InvalidDeviceCertificate;
    if (version != .integer or version.integer != 1 or cert_id != .string or cert_key != .string or
        cert_expiry != .integer or cert_expiry.integer != expires_at or
        !std.mem.eql(u8, cert_id.string, installation_id) or
        !std.mem.eql(u8, cert_key.string, device_public_key)) return error.InvalidDeviceCertificate;
}

fn validInstallationId(value: []const u8) bool {
    if (value.len != 32) return false;
    for (value) |byte| if (!std.ascii.isHex(byte) or std.ascii.isUpper(byte)) return false;
    return true;
}

fn privateFilePermissions() std.Io.File.Permissions {
    if (comptime builtin.os.tag == .windows) return .default_file;
    return .fromMode(0o600);
}

test "semantic auth creates and reloads one stable device seed" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const path = path_buf[0..path_len];

    var first = try loadOrCreateAt(io, testing.allocator, path);
    defer first.deinit();
    var second = try loadOrCreateAt(io, testing.allocator, path);
    defer second.deinit();
    try testing.expectEqualSlices(u8, &first.seed, &second.seed);
    try testing.expect(first.needsEnrollment(@divFloor(cio.milliTimestamp(), 1000)));
    const stat = try tmp.dir.statFile(io, credential_file_name, .{});
    if (builtin.os.tag != .windows) try testing.expectEqual(@as(u16, 0o600), stat.permissions.toMode() & 0o777);
}

test "semantic auth request base is stable" {
    const base = try requestSignatureBase(
        std.testing.allocator,
        "0123456789abcdef0123456789abcdef",
        1_777_777_777,
        "abcdefghijklmnopqrstuv",
        "POST",
        "/v1/codedb/embeddings",
        "body-digest",
    );
    defer std.testing.allocator.free(base);
    try std.testing.expectEqualStrings(
        "codedb-request-v1\n0123456789abcdef0123456789abcdef\n1777777777\nabcdefghijklmnopqrstuv\nPOST\n/v1/codedb/embeddings\nbody-digest",
        base,
    );
}
