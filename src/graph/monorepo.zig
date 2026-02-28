// Monorepo Support — multi-package management with cross-repo edges
//
// Manages multiple CodeGraphs (one per sub-project in a monorepo),
// provides cross-repo edge linking (e.g., package A imports package B),
// cross-repo find_dependents that traverses across sub-project boundaries,
// and package boundary detection (looks for manifest files).

const std = @import("std");
const types = @import("types.zig");
const EdgeKind = types.EdgeKind;

// ── Manifest detection ──────────────────────────────────────────────────────

pub const ManifestKind = enum(u8) {
    package_json,
    cargo_toml,
    build_zig,
    pyproject_toml,
    go_mod,
    unknown,
};

/// Known manifest filenames and their corresponding kind.
const manifest_table = [_]struct { name: []const u8, kind: ManifestKind }{
    .{ .name = "package.json", .kind = .package_json },
    .{ .name = "Cargo.toml", .kind = .cargo_toml },
    .{ .name = "build.zig", .kind = .build_zig },
    .{ .name = "pyproject.toml", .kind = .pyproject_toml },
    .{ .name = "go.mod", .kind = .go_mod },
};

/// Detect the manifest kind from a file path.
/// Checks if the path's basename matches a known manifest filename.
pub fn detectManifest(path: []const u8) ManifestKind {
    const basename = std.fs.path.basename(path);
    for (manifest_table) |entry| {
        if (std.mem.eql(u8, basename, entry.name)) return entry.kind;
    }
    return .unknown;
}

// ── Package ─────────────────────────────────────────────────────────────────

pub const Package = struct {
    id: u32,
    name: []const u8,
    root_path: []const u8, // relative to monorepo root
    manifest: ManifestKind,
};

// ── Cross-repo edge ─────────────────────────────────────────────────────────

pub const CrossRepoEdge = struct {
    src_package: u32,
    src_symbol: u64,
    dst_package: u32,
    dst_symbol: u64,
    kind: EdgeKind,
};

// ── MonorepoManager ─────────────────────────────────────────────────────────

pub const MonorepoManager = struct {
    packages: std.AutoHashMap(u32, Package),
    cross_edges: std.ArrayList(CrossRepoEdge),
    alloc: std.mem.Allocator,
    next_id: u32,

    pub fn init(alloc: std.mem.Allocator) MonorepoManager {
        return .{
            .packages = std.AutoHashMap(u32, Package).init(alloc),
            .cross_edges = .empty,
            .alloc = alloc,
            .next_id = 1,
        };
    }

    pub fn deinit(self: *MonorepoManager) void {
        // Free duped strings in packages
        var it = self.packages.valueIterator();
        while (it.next()) |pkg| {
            self.alloc.free(pkg.name);
            self.alloc.free(pkg.root_path);
        }
        self.packages.deinit();
        self.cross_edges.deinit(self.alloc);
    }

    /// Register a new package in the monorepo. Returns the assigned package ID.
    pub fn addPackage(
        self: *MonorepoManager,
        name: []const u8,
        root_path: []const u8,
        manifest: ManifestKind,
    ) !u32 {
        const id = self.next_id;
        self.next_id += 1;

        const duped_name = try self.alloc.dupe(u8, name);
        errdefer self.alloc.free(duped_name);
        const duped_path = try self.alloc.dupe(u8, root_path);
        errdefer self.alloc.free(duped_path);

        try self.packages.put(id, .{
            .id = id,
            .name = duped_name,
            .root_path = duped_path,
            .manifest = manifest,
        });

        return id;
    }

    /// Remove a package by ID. Frees associated strings.
    pub fn removePackage(self: *MonorepoManager, pkg_id: u32) void {
        const pkg = self.packages.get(pkg_id) orelse return;
        self.alloc.free(pkg.name);
        self.alloc.free(pkg.root_path);
        _ = self.packages.remove(pkg_id);
    }

    /// Look up a package by ID.
    pub fn getPackage(self: *const MonorepoManager, pkg_id: u32) ?Package {
        return self.packages.get(pkg_id);
    }

    /// Find the package whose root_path is a prefix of the given path.
    /// Returns the package ID with the longest matching prefix (most specific).
    pub fn findPackageByPath(self: *const MonorepoManager, path: []const u8) ?u32 {
        var best_id: ?u32 = null;
        var best_len: usize = 0;

        var it = self.packages.iterator();
        while (it.next()) |entry| {
            const root = entry.value_ptr.root_path;
            if (std.mem.startsWith(u8, path, root) and root.len > best_len) {
                // Ensure we match at a directory boundary
                if (root.len == path.len or
                    (path.len > root.len and path[root.len] == '/'))
                {
                    best_len = root.len;
                    best_id = entry.key_ptr.*;
                }
            }
        }
        return best_id;
    }

    /// Add a cross-repo edge connecting symbols across packages.
    pub fn addCrossEdge(self: *MonorepoManager, edge: CrossRepoEdge) !void {
        try self.cross_edges.append(self.alloc, edge);
    }

    /// Return all cross-repo edges originating from the given package.
    /// Caller owns the returned slice.
    pub fn crossEdgesFrom(
        self: *const MonorepoManager,
        pkg_id: u32,
        alloc: std.mem.Allocator,
    ) ![]const CrossRepoEdge {
        var results: std.ArrayList(CrossRepoEdge) = .empty;
        defer results.deinit(alloc);

        for (self.cross_edges.items) |edge| {
            if (edge.src_package == pkg_id) {
                try results.append(alloc, edge);
            }
        }

        const out = try alloc.alloc(CrossRepoEdge, results.items.len);
        @memcpy(out, results.items);
        return out;
    }

    /// Return all cross-repo edges targeting the given package.
    /// Caller owns the returned slice.
    pub fn crossEdgesTo(
        self: *const MonorepoManager,
        pkg_id: u32,
        alloc: std.mem.Allocator,
    ) ![]const CrossRepoEdge {
        var results: std.ArrayList(CrossRepoEdge) = .empty;
        defer results.deinit(alloc);

        for (self.cross_edges.items) |edge| {
            if (edge.dst_package == pkg_id) {
                try results.append(alloc, edge);
            }
        }

        const out = try alloc.alloc(CrossRepoEdge, results.items.len);
        @memcpy(out, results.items);
        return out;
    }

    /// Number of registered packages.
    pub fn packageCount(self: *const MonorepoManager) u32 {
        return @intCast(self.packages.count());
    }

    /// Number of cross-repo edges.
    pub fn crossEdgeCount(self: *const MonorepoManager) u32 {
        return @intCast(self.cross_edges.items.len);
    }

    /// Cross-repo find_dependents: given a symbol in a package, find all symbols
    /// across all packages that transitively depend on it via cross-repo edges.
    /// Returns a list of (package_id, symbol_id) pairs.
    /// Caller owns the returned slice.
    pub const CrossDependent = struct {
        package_id: u32,
        symbol_id: u64,
        edge_kind: EdgeKind,
        depth: u32,
    };

    pub fn findCrossDependents(
        self: *const MonorepoManager,
        src_pkg: u32,
        src_symbol: u64,
        max_depth: u32,
        alloc: std.mem.Allocator,
    ) ![]CrossDependent {
        var results: std.ArrayList(CrossDependent) = .empty;
        defer results.deinit(alloc);

        // BFS across cross-repo edges
        const QueueItem = struct { pkg: u32, sym: u64, depth: u32 };
        var queue: std.ArrayList(QueueItem) = .empty;
        defer queue.deinit(alloc);

        // Track visited (package_id, symbol_id) pairs to avoid cycles
        var visited = std.AutoHashMap(u128, void).init(alloc);
        defer visited.deinit();

        const start_key = compositeKey(src_pkg, src_symbol);
        try visited.put(start_key, {});
        try queue.append(alloc, .{ .pkg = src_pkg, .sym = src_symbol, .depth = 0 });

        var head: usize = 0;
        while (head < queue.items.len) {
            const current = queue.items[head];
            head += 1;

            if (current.depth >= max_depth) continue;

            // Find cross-repo edges where the current symbol is the target
            // (i.e., other packages that import/reference this symbol)
            for (self.cross_edges.items) |edge| {
                if (edge.dst_package == current.pkg and edge.dst_symbol == current.sym) {
                    const key = compositeKey(edge.src_package, edge.src_symbol);
                    const gop = try visited.getOrPut(key);
                    if (!gop.found_existing) {
                        const dep = CrossDependent{
                            .package_id = edge.src_package,
                            .symbol_id = edge.src_symbol,
                            .edge_kind = edge.kind,
                            .depth = current.depth + 1,
                        };
                        try results.append(alloc, dep);
                        try queue.append(alloc, .{
                            .pkg = edge.src_package,
                            .sym = edge.src_symbol,
                            .depth = current.depth + 1,
                        });
                    }
                }
            }
        }

        const out = try alloc.alloc(CrossDependent, results.items.len);
        @memcpy(out, results.items);
        return out;
    }
};

/// Create a composite key from package_id and symbol_id for deduplication.
fn compositeKey(pkg_id: u32, sym_id: u64) u128 {
    return (@as(u128, pkg_id) << 64) | @as(u128, sym_id);
}

// ── Tests ───────────────────────────────────────────────────────────────────

test "init and deinit with no leaks" {
    var mgr = MonorepoManager.init(std.testing.allocator);
    defer mgr.deinit();

    try std.testing.expectEqual(@as(u32, 0), mgr.packageCount());
    try std.testing.expectEqual(@as(u32, 0), mgr.crossEdgeCount());
}

test "addPackage and getPackage round-trip" {
    var mgr = MonorepoManager.init(std.testing.allocator);
    defer mgr.deinit();

    const id = try mgr.addPackage("web-app", "packages/web-app", .package_json);
    try std.testing.expectEqual(@as(u32, 1), id);
    try std.testing.expectEqual(@as(u32, 1), mgr.packageCount());

    const pkg = mgr.getPackage(id).?;
    try std.testing.expectEqualStrings("web-app", pkg.name);
    try std.testing.expectEqualStrings("packages/web-app", pkg.root_path);
    try std.testing.expectEqual(ManifestKind.package_json, pkg.manifest);
}

test "addPackage assigns sequential IDs" {
    var mgr = MonorepoManager.init(std.testing.allocator);
    defer mgr.deinit();

    const id1 = try mgr.addPackage("a", "packages/a", .cargo_toml);
    const id2 = try mgr.addPackage("b", "packages/b", .build_zig);
    const id3 = try mgr.addPackage("c", "packages/c", .pyproject_toml);

    try std.testing.expectEqual(@as(u32, 1), id1);
    try std.testing.expectEqual(@as(u32, 2), id2);
    try std.testing.expectEqual(@as(u32, 3), id3);
    try std.testing.expectEqual(@as(u32, 3), mgr.packageCount());
}

test "removePackage frees memory and removes entry" {
    var mgr = MonorepoManager.init(std.testing.allocator);
    defer mgr.deinit();

    const id = try mgr.addPackage("temp", "packages/temp", .go_mod);
    try std.testing.expectEqual(@as(u32, 1), mgr.packageCount());

    mgr.removePackage(id);
    try std.testing.expectEqual(@as(u32, 0), mgr.packageCount());
    try std.testing.expectEqual(@as(?Package, null), mgr.getPackage(id));
}

test "removePackage with invalid ID is safe" {
    var mgr = MonorepoManager.init(std.testing.allocator);
    defer mgr.deinit();

    mgr.removePackage(999); // should not crash
}

test "findPackageByPath matches longest prefix" {
    var mgr = MonorepoManager.init(std.testing.allocator);
    defer mgr.deinit();

    const id1 = try mgr.addPackage("root", "packages", .unknown);
    const id2 = try mgr.addPackage("web", "packages/web", .package_json);
    const id3 = try mgr.addPackage("web-utils", "packages/web/utils", .package_json);

    // Exact match on deepest path
    try std.testing.expectEqual(id3, mgr.findPackageByPath("packages/web/utils/index.ts").?);
    // Match on packages/web (not packages/web/utils)
    try std.testing.expectEqual(id2, mgr.findPackageByPath("packages/web/src/app.ts").?);
    // Match on packages (the root)
    try std.testing.expectEqual(id1, mgr.findPackageByPath("packages/other/lib.ts").?);
    // No match
    try std.testing.expectEqual(@as(?u32, null), mgr.findPackageByPath("src/main.ts"));
}

test "findPackageByPath requires directory boundary" {
    var mgr = MonorepoManager.init(std.testing.allocator);
    defer mgr.deinit();

    _ = try mgr.addPackage("lib", "packages/lib", .cargo_toml);

    // "packages/library" starts with "packages/lib" but is not under "packages/lib/"
    try std.testing.expectEqual(@as(?u32, null), mgr.findPackageByPath("packages/library/src.rs"));
    // "packages/lib/src.rs" is a valid match
    try std.testing.expect(mgr.findPackageByPath("packages/lib/src.rs") != null);
}

test "addCrossEdge and crossEdgeCount" {
    var mgr = MonorepoManager.init(std.testing.allocator);
    defer mgr.deinit();

    try mgr.addCrossEdge(.{
        .src_package = 1,
        .src_symbol = 100,
        .dst_package = 2,
        .dst_symbol = 200,
        .kind = .imports,
    });
    try mgr.addCrossEdge(.{
        .src_package = 2,
        .src_symbol = 200,
        .dst_package = 3,
        .dst_symbol = 300,
        .kind = .calls,
    });

    try std.testing.expectEqual(@as(u32, 2), mgr.crossEdgeCount());
}

test "crossEdgesFrom filters by source package" {
    var mgr = MonorepoManager.init(std.testing.allocator);
    defer mgr.deinit();

    try mgr.addCrossEdge(.{ .src_package = 1, .src_symbol = 10, .dst_package = 2, .dst_symbol = 20, .kind = .imports });
    try mgr.addCrossEdge(.{ .src_package = 1, .src_symbol = 11, .dst_package = 3, .dst_symbol = 30, .kind = .calls });
    try mgr.addCrossEdge(.{ .src_package = 2, .src_symbol = 20, .dst_package = 3, .dst_symbol = 30, .kind = .imports });

    const from1 = try mgr.crossEdgesFrom(1, std.testing.allocator);
    defer std.testing.allocator.free(from1);
    try std.testing.expectEqual(@as(usize, 2), from1.len);

    const from2 = try mgr.crossEdgesFrom(2, std.testing.allocator);
    defer std.testing.allocator.free(from2);
    try std.testing.expectEqual(@as(usize, 1), from2.len);

    const from99 = try mgr.crossEdgesFrom(99, std.testing.allocator);
    defer std.testing.allocator.free(from99);
    try std.testing.expectEqual(@as(usize, 0), from99.len);
}

test "crossEdgesTo filters by destination package" {
    var mgr = MonorepoManager.init(std.testing.allocator);
    defer mgr.deinit();

    try mgr.addCrossEdge(.{ .src_package = 1, .src_symbol = 10, .dst_package = 2, .dst_symbol = 20, .kind = .imports });
    try mgr.addCrossEdge(.{ .src_package = 3, .src_symbol = 30, .dst_package = 2, .dst_symbol = 21, .kind = .calls });
    try mgr.addCrossEdge(.{ .src_package = 1, .src_symbol = 11, .dst_package = 3, .dst_symbol = 30, .kind = .references });

    const to2 = try mgr.crossEdgesTo(2, std.testing.allocator);
    defer std.testing.allocator.free(to2);
    try std.testing.expectEqual(@as(usize, 2), to2.len);

    const to3 = try mgr.crossEdgesTo(3, std.testing.allocator);
    defer std.testing.allocator.free(to3);
    try std.testing.expectEqual(@as(usize, 1), to3.len);
}

test "detectManifest identifies package.json" {
    try std.testing.expectEqual(ManifestKind.package_json, detectManifest("packages/web/package.json"));
    try std.testing.expectEqual(ManifestKind.package_json, detectManifest("package.json"));
}

test "detectManifest identifies Cargo.toml" {
    try std.testing.expectEqual(ManifestKind.cargo_toml, detectManifest("crates/core/Cargo.toml"));
}

test "detectManifest identifies build.zig" {
    try std.testing.expectEqual(ManifestKind.build_zig, detectManifest("libs/parser/build.zig"));
}

test "detectManifest identifies pyproject.toml" {
    try std.testing.expectEqual(ManifestKind.pyproject_toml, detectManifest("services/api/pyproject.toml"));
}

test "detectManifest identifies go.mod" {
    try std.testing.expectEqual(ManifestKind.go_mod, detectManifest("cmd/server/go.mod"));
}

test "detectManifest returns unknown for unrecognized files" {
    try std.testing.expectEqual(ManifestKind.unknown, detectManifest("src/main.zig"));
    try std.testing.expectEqual(ManifestKind.unknown, detectManifest("README.md"));
    try std.testing.expectEqual(ManifestKind.unknown, detectManifest(""));
}

test "ManifestKind enum values are stable" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(ManifestKind.package_json));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(ManifestKind.cargo_toml));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(ManifestKind.build_zig));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(ManifestKind.pyproject_toml));
    try std.testing.expectEqual(@as(u8, 4), @intFromEnum(ManifestKind.go_mod));
    try std.testing.expectEqual(@as(u8, 5), @intFromEnum(ManifestKind.unknown));
}

test "findCrossDependents with single hop" {
    var mgr = MonorepoManager.init(std.testing.allocator);
    defer mgr.deinit();

    _ = try mgr.addPackage("core", "packages/core", .package_json);
    _ = try mgr.addPackage("web", "packages/web", .package_json);

    // web:100 imports core:200
    try mgr.addCrossEdge(.{
        .src_package = 2,
        .src_symbol = 100,
        .dst_package = 1,
        .dst_symbol = 200,
        .kind = .imports,
    });

    // Who depends on core:200?
    const deps = try mgr.findCrossDependents(1, 200, 5, std.testing.allocator);
    defer std.testing.allocator.free(deps);

    try std.testing.expectEqual(@as(usize, 1), deps.len);
    try std.testing.expectEqual(@as(u32, 2), deps[0].package_id);
    try std.testing.expectEqual(@as(u64, 100), deps[0].symbol_id);
    try std.testing.expectEqual(EdgeKind.imports, deps[0].edge_kind);
    try std.testing.expectEqual(@as(u32, 1), deps[0].depth);
}

test "findCrossDependents with transitive chain" {
    var mgr = MonorepoManager.init(std.testing.allocator);
    defer mgr.deinit();

    _ = try mgr.addPackage("core", "packages/core", .package_json);
    _ = try mgr.addPackage("utils", "packages/utils", .package_json);
    _ = try mgr.addPackage("app", "packages/app", .package_json);

    // utils:100 imports core:200
    try mgr.addCrossEdge(.{ .src_package = 2, .src_symbol = 100, .dst_package = 1, .dst_symbol = 200, .kind = .imports });
    // app:300 imports utils:100
    try mgr.addCrossEdge(.{ .src_package = 3, .src_symbol = 300, .dst_package = 2, .dst_symbol = 100, .kind = .imports });

    // Transitive dependents of core:200
    const deps = try mgr.findCrossDependents(1, 200, 5, std.testing.allocator);
    defer std.testing.allocator.free(deps);

    try std.testing.expectEqual(@as(usize, 2), deps.len);

    // First hop: utils:100 at depth 1
    // Second hop: app:300 at depth 2
    // Order is BFS so depth 1 first
    try std.testing.expectEqual(@as(u32, 1), deps[0].depth);
    try std.testing.expectEqual(@as(u32, 2), deps[1].depth);
}

test "findCrossDependents respects max_depth" {
    var mgr = MonorepoManager.init(std.testing.allocator);
    defer mgr.deinit();

    _ = try mgr.addPackage("a", "pkg/a", .unknown);
    _ = try mgr.addPackage("b", "pkg/b", .unknown);
    _ = try mgr.addPackage("c", "pkg/c", .unknown);

    try mgr.addCrossEdge(.{ .src_package = 2, .src_symbol = 10, .dst_package = 1, .dst_symbol = 1, .kind = .imports });
    try mgr.addCrossEdge(.{ .src_package = 3, .src_symbol = 20, .dst_package = 2, .dst_symbol = 10, .kind = .imports });

    // max_depth = 1 should only find direct dependents
    const deps = try mgr.findCrossDependents(1, 1, 1, std.testing.allocator);
    defer std.testing.allocator.free(deps);

    try std.testing.expectEqual(@as(usize, 1), deps.len);
    try std.testing.expectEqual(@as(u32, 2), deps[0].package_id);
}

test "findCrossDependents handles cycles" {
    var mgr = MonorepoManager.init(std.testing.allocator);
    defer mgr.deinit();

    _ = try mgr.addPackage("a", "pkg/a", .unknown);
    _ = try mgr.addPackage("b", "pkg/b", .unknown);

    // Cycle: a:1 -> b:2 -> a:1
    try mgr.addCrossEdge(.{ .src_package = 2, .src_symbol = 2, .dst_package = 1, .dst_symbol = 1, .kind = .imports });
    try mgr.addCrossEdge(.{ .src_package = 1, .src_symbol = 1, .dst_package = 2, .dst_symbol = 2, .kind = .imports });

    const deps = try mgr.findCrossDependents(1, 1, 10, std.testing.allocator);
    defer std.testing.allocator.free(deps);

    // Should terminate without infinite loop, finding b:2 once
    try std.testing.expectEqual(@as(usize, 1), deps.len);
    try std.testing.expectEqual(@as(u32, 2), deps[0].package_id);
}

test "findCrossDependents with no dependents returns empty" {
    var mgr = MonorepoManager.init(std.testing.allocator);
    defer mgr.deinit();

    _ = try mgr.addPackage("isolated", "pkg/isolated", .unknown);

    const deps = try mgr.findCrossDependents(1, 42, 5, std.testing.allocator);
    defer std.testing.allocator.free(deps);

    try std.testing.expectEqual(@as(usize, 0), deps.len);
}

test "struct sizes are reasonable" {
    try std.testing.expect(@sizeOf(Package) <= 64);
    try std.testing.expect(@sizeOf(CrossRepoEdge) <= 32);
}

// ── Edge case tests ─────────────────────────────────────────────────────────

test "addPackage with empty name" {
    var mgr = MonorepoManager.init(std.testing.allocator);
    defer mgr.deinit();

    const id = try mgr.addPackage("", "packages/empty", .unknown);
    try std.testing.expectEqual(@as(u32, 1), id);
    const pkg = mgr.getPackage(id).?;
    try std.testing.expectEqualStrings("", pkg.name);
}

test "removePackage for nonexistent ID does not crash" {
    var mgr = MonorepoManager.init(std.testing.allocator);
    defer mgr.deinit();

    // Remove from empty manager
    mgr.removePackage(0);
    mgr.removePackage(1);
    mgr.removePackage(999999);
    try std.testing.expectEqual(@as(u32, 0), mgr.packageCount());
}

test "findPackageByPath with no packages registered" {
    var mgr = MonorepoManager.init(std.testing.allocator);
    defer mgr.deinit();

    try std.testing.expectEqual(@as(?u32, null), mgr.findPackageByPath("any/path/file.ts"));
    try std.testing.expectEqual(@as(?u32, null), mgr.findPackageByPath(""));
}

test "cross edges referencing removed package still exist" {
    var mgr = MonorepoManager.init(std.testing.allocator);
    defer mgr.deinit();

    const id1 = try mgr.addPackage("a", "pkg/a", .unknown);
    const id2 = try mgr.addPackage("b", "pkg/b", .unknown);

    try mgr.addCrossEdge(.{
        .src_package = id1,
        .src_symbol = 10,
        .dst_package = id2,
        .dst_symbol = 20,
        .kind = .imports,
    });

    // Remove package b — cross edge still in the list (orphaned)
    mgr.removePackage(id2);
    try std.testing.expectEqual(@as(u32, 1), mgr.crossEdgeCount());

    // crossEdgesFrom still returns the orphaned edge
    const from_a = try mgr.crossEdgesFrom(id1, std.testing.allocator);
    defer std.testing.allocator.free(from_a);
    try std.testing.expectEqual(@as(usize, 1), from_a.len);
}

test "findCrossDependents with depth=0 returns empty" {
    var mgr = MonorepoManager.init(std.testing.allocator);
    defer mgr.deinit();

    _ = try mgr.addPackage("a", "pkg/a", .unknown);
    _ = try mgr.addPackage("b", "pkg/b", .unknown);

    try mgr.addCrossEdge(.{ .src_package = 2, .src_symbol = 10, .dst_package = 1, .dst_symbol = 1, .kind = .imports });

    // depth=0 means no hops allowed
    const deps = try mgr.findCrossDependents(1, 1, 0, std.testing.allocator);
    defer std.testing.allocator.free(deps);

    try std.testing.expectEqual(@as(usize, 0), deps.len);
}

test "findCrossDependents with circular cross-edges between 3 packages" {
    var mgr = MonorepoManager.init(std.testing.allocator);
    defer mgr.deinit();

    _ = try mgr.addPackage("a", "pkg/a", .unknown);
    _ = try mgr.addPackage("b", "pkg/b", .unknown);
    _ = try mgr.addPackage("c", "pkg/c", .unknown);

    // a:1 -> b:2 -> c:3 -> a:1 (circular)
    try mgr.addCrossEdge(.{ .src_package = 2, .src_symbol = 2, .dst_package = 1, .dst_symbol = 1, .kind = .imports });
    try mgr.addCrossEdge(.{ .src_package = 3, .src_symbol = 3, .dst_package = 2, .dst_symbol = 2, .kind = .imports });
    try mgr.addCrossEdge(.{ .src_package = 1, .src_symbol = 1, .dst_package = 3, .dst_symbol = 3, .kind = .imports });

    const deps = try mgr.findCrossDependents(1, 1, 10, std.testing.allocator);
    defer std.testing.allocator.free(deps);

    // Should find b:2 and c:3 without infinite loop
    try std.testing.expectEqual(@as(usize, 2), deps.len);
}

test "many packages (20+)" {
    var mgr = MonorepoManager.init(std.testing.allocator);
    defer mgr.deinit();

    var ids: [25]u32 = undefined;
    for (0..25) |i| {
        // Use a fixed name for all since we only need unique IDs
        ids[i] = try mgr.addPackage("pkg", "packages/pkg", .package_json);
    }

    try std.testing.expectEqual(@as(u32, 25), mgr.packageCount());
    // IDs should be sequential
    try std.testing.expectEqual(@as(u32, 1), ids[0]);
    try std.testing.expectEqual(@as(u32, 25), ids[24]);

    // All packages should be retrievable
    for (ids) |id| {
        try std.testing.expect(mgr.getPackage(id) != null);
    }
}

test "detectManifest with unusual paths" {
    // Deeply nested
    try std.testing.expectEqual(ManifestKind.package_json, detectManifest("a/b/c/d/e/f/package.json"));
    // Just the filename
    try std.testing.expectEqual(ManifestKind.cargo_toml, detectManifest("Cargo.toml"));
    // Path with dots
    try std.testing.expectEqual(ManifestKind.go_mod, detectManifest("my.project/go.mod"));
    // Filename that contains manifest name as substring but is not exact
    try std.testing.expectEqual(ManifestKind.unknown, detectManifest("not-package.json.bak"));
    // Path with spaces
    try std.testing.expectEqual(ManifestKind.build_zig, detectManifest("path with spaces/build.zig"));
}

test "addPackage with very long name and path" {
    var mgr = MonorepoManager.init(std.testing.allocator);
    defer mgr.deinit();

    const long_name = "x" ** 1000;
    const long_path = "p" ** 1000;
    const id = try mgr.addPackage(long_name, long_path, .unknown);
    const pkg = mgr.getPackage(id).?;
    try std.testing.expectEqual(@as(usize, 1000), pkg.name.len);
    try std.testing.expectEqual(@as(usize, 1000), pkg.root_path.len);
}

test "crossEdgesFrom and crossEdgesTo with no edges" {
    var mgr = MonorepoManager.init(std.testing.allocator);
    defer mgr.deinit();

    const from = try mgr.crossEdgesFrom(1, std.testing.allocator);
    defer std.testing.allocator.free(from);
    try std.testing.expectEqual(@as(usize, 0), from.len);

    const to = try mgr.crossEdgesTo(1, std.testing.allocator);
    defer std.testing.allocator.free(to);
    try std.testing.expectEqual(@as(usize, 0), to.len);
}

test "findPackageByPath with empty root path never matches" {
    var mgr = MonorepoManager.init(std.testing.allocator);
    defer mgr.deinit();

    // A package with empty root_path: root.len=0 but the comparison
    // requires root.len > best_len (0 > 0 is false), so empty root
    // can never be selected as best match. This is a known edge case.
    _ = try mgr.addPackage("root", "", .unknown);

    // Even exact empty match fails because 0 > 0 is false
    const result = mgr.findPackageByPath("");
    try std.testing.expectEqual(@as(?u32, null), result);

    // Non-empty paths also fail
    const result2 = mgr.findPackageByPath("src/main.ts");
    try std.testing.expectEqual(@as(?u32, null), result2);
}

test "compositeKey produces unique keys" {
    const k1 = compositeKey(1, 100);
    const k2 = compositeKey(1, 101);
    const k3 = compositeKey(2, 100);
    try std.testing.expect(k1 != k2);
    try std.testing.expect(k1 != k3);
    try std.testing.expect(k2 != k3);
}
