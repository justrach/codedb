//! Canonical policy for paths that may address repository source content.
const std = @import("std");

pub fn isNormalizedRelative(path: []const u8) bool {
    if (path.len == 0 or path.len > 4096 or std.fs.path.isAbsolute(path)) return false;
    if (std.mem.indexOfScalar(u8, path, 0) != null or
        std.mem.indexOfScalar(u8, path, '\\') != null or
        std.mem.indexOfScalar(u8, path, ':') != null) return false;

    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return false;
    }
    return true;
}

fn endsWithIgnoreCase(value: []const u8, suffix: []const u8) bool {
    if (value.len < suffix.len) return false;
    return std.ascii.eqlIgnoreCase(value[value.len - suffix.len ..], suffix);
}

fn hasSensitiveExtension(basename: []const u8) bool {
    const extensions = [_][]const u8{ ".env", ".pem", ".key", ".p12", ".pfx", ".jks" };
    for (extensions) |extension| {
        if (endsWithIgnoreCase(basename, extension)) return true;
    }
    return false;
}

fn hasSensitiveDirectory(path: []const u8) bool {
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        if (std.ascii.eqlIgnoreCase(component, ".ssh") or
            std.ascii.eqlIgnoreCase(component, ".gnupg") or
            std.ascii.eqlIgnoreCase(component, ".aws")) return true;
    }
    return false;
}

pub fn isSensitive(path: []const u8) bool {
    const basename = if (std.mem.lastIndexOfScalar(u8, path, '/')) |sep| path[sep + 1 ..] else path;
    if (basename.len == 0) return false;
    const first = std.ascii.toLower(basename[0]);
    if (first != '.' and first != 'c' and first != 's' and first != 'i') {
        if (hasSensitiveExtension(basename)) return true;
        return hasSensitiveDirectory(path);
    }
    if (basename.len >= 4 and std.ascii.eqlIgnoreCase(basename[0..4], ".env") and
        (basename.len == 4 or basename[4] == '.' or basename[4] == '-' or basename[4] == '_')) return true;
    const sensitive_names = [_][]const u8{
        ".dev.vars",        ".npmrc",               ".pypirc",      ".netrc",
        "credentials.json", "service-account.json", "secrets.json", "secrets.yaml",
        "secrets.yml",      "id_rsa",               "id_ed25519",   ".git-credentials",
        "id_ecdsa",         "id_dsa",               "id_ecdsa_sk",  "id_ed25519_sk",
    };
    for (sensitive_names) |name| {
        if (std.ascii.eqlIgnoreCase(basename, name)) return true;
    }
    if (hasSensitiveExtension(basename)) return true;
    return hasSensitiveDirectory(path);
}

pub fn isReadable(path: []const u8) bool {
    return isNormalizedRelative(path) and !isSensitive(path);
}
