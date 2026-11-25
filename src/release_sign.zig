//! Compiled-in Ed25519 public key for signed codedb releases.
//!
//! Release publishes sign `checksums.sha256` with the matching private seed
//! (GitHub secret `CODEDB_RELEASE_SIGNING_SEED`). Installers and `codedb update`
//! verify that signature before replacing a binary. Private keys are never
//! committed; see docs/release-signing.md.

const std = @import("std");

const Ed25519 = std.crypto.sign.Ed25519;

/// Raw 32-byte Ed25519 public key for production release signatures.
pub const public_key_bytes: [32]u8 = .{
    0x1a, 0xae, 0xc9, 0xbc, 0x8b, 0xa7, 0x99, 0xa3, 0xdc, 0x01, 0x29, 0xe3, 0xfd, 0xe9, 0x49, 0x56,
    0x7b, 0xc8, 0x49, 0x3b, 0x95, 0x34, 0xaa, 0x60, 0xf0, 0xbf, 0x1a, 0x32, 0xcc, 0x92, 0x1f, 0x20,
};

pub const public_key_hex = "1aaec9bc8ba799a3dc0129e3fde949567bc8493b9534aa60f0bf1a32cc921f20";

pub const signature_length = Ed25519.Signature.encoded_length;

pub fn publicKeyHex() []const u8 {
    return public_key_hex;
}

pub fn parseSignature(raw: []const u8) ?[signature_length]u8 {
    if (raw.len == signature_length) {
        var out: [signature_length]u8 = undefined;
        @memcpy(&out, raw);
        return out;
    }
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == signature_length * 2) {
        var out: [signature_length]u8 = undefined;
        _ = std.fmt.hexToBytes(&out, trimmed) catch return null;
        return out;
    }
    return null;
}

pub fn verifyManifest(manifest: []const u8, signature_raw: []const u8) bool {
    return verifyManifestWithKey(manifest, signature_raw, public_key_bytes);
}

pub fn verifyManifestWithKey(manifest: []const u8, signature_raw: []const u8, public_key: [32]u8) bool {
    const sig_bytes = parseSignature(signature_raw) orelse return false;
    const pk = Ed25519.PublicKey.fromBytes(public_key) catch return false;
    Ed25519.Signature.fromBytes(sig_bytes).verifyStrict(manifest, pk) catch return false;
    return true;
}

pub fn signManifestWithSeed(manifest: []const u8, seed: [Ed25519.KeyPair.seed_length]u8) ![signature_length]u8 {
    const key_pair = try Ed25519.KeyPair.generateDeterministic(seed);
    const signature = try key_pair.sign(manifest, null);
    return signature.toBytes();
}

pub fn publicKeyFromSeed(seed: [Ed25519.KeyPair.seed_length]u8) ![32]u8 {
    const key_pair = try Ed25519.KeyPair.generateDeterministic(seed);
    return key_pair.public_key.toBytes();
}
