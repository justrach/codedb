//! Persistent, local code-chunk ANN index for hybrid codedb retrieval.
//!
//! Building is explicit with `codedb <root> semantic-index`, except that a
//! sidecar produced by a former hosted Qwen or Jina default is migrated once
//! in the background when a hybrid query first encounters it. Safe, bounded file
//! chunks are embedded remotely in batches, while the vectors, HNSW graph, and
//! record mapping are written only to codedb's per-project local data dir.
//! Querying sends only the user's bounded query and searches OpenPuffer in
//! process. A missing, stale, malformed, or incompatible sidecar is never an
//! excuse for a CPU embedding fallback.

const std = @import("std");
const builtin = @import("builtin");
const cio = @import("cio.zig");
const Explorer = @import("explore.zig").Explorer;
const Store = @import("store.zig").Store;
const ann = @import("ann.zig");
const semantic = @import("semantic.zig");
const git_mod = @import("git.zig");
const snapshot_mod = @import("snapshot.zig");
const watcher = @import("watcher.zig");

pub const sidecar_name = "semantic-chunks-v3.meta";
pub const slab_file_prefix = "semantic-chunks-v3-";
pub const slab_file_suffix = ".hmls";
pub const max_chunk_card_bytes: usize = 1024;
pub const chunk_source_bytes: usize = 832;
pub const max_chunks_per_file: usize = 256;
// Hosted 100-item batches (2026-09-27, 1,570 chunks): c4=10.7s, c8=5.9s
// against 17.8s for the former 25-item c4 default. Repositories beyond the
// hosted per-minute quota are paced by the index retry backoff instead.
pub const default_parallel_batches: usize = 8;
pub const max_parallel_batches: usize = 8;
pub const default_search_results: usize = 24;
pub const max_records: usize = 250_000;
/// Metadata is copied into heap storage so record paths can borrow from one
/// stable buffer. The HNSW payload itself is mmap-backed; keeping this cap well
/// below the old 256 MiB limit prevents a crafted mapping table from recreating
/// the 650-700 MiB query RSS profile that mmap is meant to avoid.
pub const max_metadata_bytes: usize = 64 * 1024 * 1024;
pub const max_slab_bytes: usize = 1024 * 1024 * 1024;
pub const max_embedding_cache_bytes: usize = 512 * 1024 * 1024;
pub const embedding_cache_name = "semantic-embeddings-v1.cache";
pub const auto_migration_opt_out_env = "CODEDB_NO_AUTO_SEMANTIC_MIGRATION";

const magic = [8]u8{ 'C', 'D', 'B', 'A', 'N', 'N', '0', '3' };
const format_version: u16 = 3;
const header_bytes: usize = 48;

const cache_magic = [8]u8{ 'C', 'D', 'B', 'E', 'M', 'C', '0', '1' };
const cache_format_version: u16 = 1;
const cache_header_bytes: usize = 48;

pub const BuildStats = struct {
    records: usize,
    reused_records: usize = 0,
    files_indexed: usize,
    dimensions: u16,
    model: []const u8,
    file_bytes: usize,
    graph_bytes: usize,
    metadata_bytes: usize,
    vector_payload_bytes: usize,
    text_bytes_sent: usize,
    sensitive_paths_blocked: usize,
    manifest: u64,
    elapsed_ns: u64,
    embedding_wall_ns: u64,
    insertion_ns: u64,
    source_validation_ns: u64,
    parallel_batches: usize,
    vector_space_id: u64,
};

pub const Hit = struct {
    path: []const u8,
    line_start: u32,
    line_end: u32,
    distance: f32,
};

pub const SearchOutput = struct {
    hits: []Hit,
    model: []const u8,
    dimensions: u16,
    records: usize,
    index_bytes: usize,
    text_bytes_sent: usize,
    documents_sent: usize = 2,
    retention: enum { none_by_codedb_policy, custom_endpoint_unverified },
    load_ns: u64,
    embed_ns: u64,
    search_ns: u64,
    mmap_backed: bool,
    cache_hit: bool,
    vector_space_id: u64,

    pub fn deinit(self: *SearchOutput, allocator: std.mem.Allocator) void {
        for (self.hits) |hit| allocator.free(hit.path);
        allocator.free(self.hits);
        allocator.free(self.model);
        self.* = undefined;
    }
};

const Record = struct {
    path: []const u8,
    line_start: u32,
    line_end: u32,
};

const CachedFileState = struct {
    path: []const u8,
    content_hash: u64,
    size: u64,
    line_count: u32,
};

const CardKey = struct {
    lo: u64,
    hi: u64,
};

fn hashChunkCard(card: []const u8) CardKey {
    return .{
        .lo = std.hash.Wyhash.hash(0x4344_4243_484b_3031, card),
        .hi = std.hash.Wyhash.hash(0x4344_4243_484b_3032, card),
    };
}

const Loaded = struct {
    allocator: std.mem.Allocator,
    storage: []u8,
    records: []Record,
    slab_path: []u8,
    slab_bytes: usize,
    model: []const u8,
    dimensions: u16,
    manifest: u64,
    vector_space_id: u64,
    calibration: []f32,
    git_head: ?[40]u8,
    index: ann.Index,
    build_files_storage: ?[]u8 = null,
    build_files: ?[]CachedFileState = null,

    fn loadGraph(self: *Loaded) !void {
        // No copy-in fallback: native Windows mmap is tracked upstream as
        // justrach/openpuffer#25.
        if (comptime builtin.os.tag == .windows) return error.UnsupportedPlatform;
        if (self.index.len() != 0 or self.index.isMmapBacked()) return error.AnnRecordMappingMismatch;
        self.index.loadMmap(self.slab_path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidAnnSidecar,
        };
        if (!self.index.isMmapBacked() or self.index.len() != self.records.len) return error.AnnRecordMappingMismatch;
    }

    fn deinit(self: *Loaded) void {
        self.index.deinit();
        if (self.build_files) |files| self.allocator.free(files);
        if (self.build_files_storage) |buf| self.allocator.free(buf);
        self.allocator.free(self.calibration);
        self.allocator.free(self.slab_path);
        self.allocator.free(self.records);
        self.allocator.free(self.storage);
        self.* = undefined;
    }
};

const FileIdentity = struct {
    inode: std.Io.File.INode,
    size: u64,
    mtime_ns: i96,
    ctime_ns: i96,

    fn eql(a: FileIdentity, b: FileIdentity) bool {
        return a.inode == b.inode and a.size == b.size and a.mtime_ns == b.mtime_ns and a.ctime_ns == b.ctime_ns;
    }
};

const CachedLoaded = struct {
    loaded: Loaded,
    metadata_identity: FileIdentity,
    slab_identity: FileIdentity,
    store_seq: u64,
};

/// One validated immutable semantic sidecar generation per project. Warm
/// searches take the shared lock, so concurrent users can embed and search in
/// parallel. Replacement is transactional under the exclusive lock: a stale,
/// malformed, or concurrently replaced sidecar never evicts the last valid
/// generation and is never queried.
pub const SearchCache = struct {
    mu: cio.RwLock = .{},
    migration_mu: cio.Mutex = .{},
    allocator: std.mem.Allocator,
    cached: ?CachedLoaded = null,
    migration_thread: ?std.Thread = null,
    migration_state: std.atomic.Value(u8) = std.atomic.Value(u8).init(@intFromEnum(MigrationState.idle)),

    pub fn init(allocator: std.mem.Allocator) SearchCache {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *SearchCache) void {
        // A migration borrows the owning Explorer and Store. Join it before
        // ProjectCache tears either one down, and before releasing this cache
        // whose atomic state the worker updates on completion.
        self.migration_mu.lock();
        const migration_thread = self.migration_thread;
        self.migration_thread = null;
        self.migration_mu.unlock();
        if (migration_thread) |thread| thread.join();

        self.mu.lock();
        defer self.mu.unlock();
        if (self.cached) |*cached| cached.loaded.deinit();
        self.cached = null;
    }

    pub fn migrationState(self: *const SearchCache) MigrationState {
        return @enumFromInt(self.migration_state.load(.acquire));
    }
};

pub const MigrationState = enum(u8) {
    idle,
    running,
    succeeded,
    failed,
};

pub const MigrationSchedule = enum {
    not_eligible,
    scheduled,
    in_progress,
};

const MigrationJob = struct {
    io: std.Io,
    cache: *SearchCache,
    explorer: *Explorer,
    store: *Store,
    project_root: []u8,
    data_dir: []u8,

    fn run(self: *MigrationJob) void {
        const allocator = std.heap.page_allocator;
        const result = build(self.io, allocator, self.explorer, self.store, self.project_root, self.data_dir);
        if (result) |stats| {
            self.cache.migration_state.store(@intFromEnum(MigrationState.succeeded), .release);
            std.log.info(
                "semantic sidecar migration committed: {d} chunks from {d} files in {d} ms",
                .{ stats.records, stats.files_indexed, stats.elapsed_ns / std.time.ns_per_ms },
            );
        } else |err| {
            self.cache.migration_state.store(@intFromEnum(MigrationState.failed), .release);
            std.log.warn("semantic sidecar migration failed: {s}", .{@errorName(err)});
        }
        allocator.free(self.project_root);
        allocator.free(self.data_dir);
        allocator.destroy(self);
    }
};

fn createMigrationJob(
    io: std.Io,
    cache: *SearchCache,
    explorer: *Explorer,
    store: *Store,
    project_root: []const u8,
    data_dir: []const u8,
) !*MigrationJob {
    const allocator = std.heap.page_allocator;
    const job = try allocator.create(MigrationJob);
    errdefer allocator.destroy(job);
    const owned_root = try allocator.dupe(u8, project_root);
    errdefer allocator.free(owned_root);
    const owned_data_dir = try allocator.dupe(u8, data_dir);
    errdefer allocator.free(owned_data_dir);
    job.* = .{
        .io = io,
        .cache = cache,
        .explorer = explorer,
        .store = store,
        .project_root = owned_root,
        .data_dir = owned_data_dir,
    };
    return job;
}

fn elapsedNs(since: i128) u64 {
    const now = cio.nanoTimestamp();
    return if (now > since) @intCast(now - since) else 0;
}

fn sidecarPath(allocator: std.mem.Allocator, data_dir: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ data_dir, sidecar_name });
}

fn privateFilePermissions() std.Io.File.Permissions {
    if (comptime builtin.os.tag == .windows) return .default_file;
    return .fromMode(0o600);
}

fn privateDirPermissions() std.Io.File.Permissions {
    if (comptime builtin.os.tag == .windows) return .default_dir;
    return .fromMode(0o700);
}

fn secureDataDir(io: std.Io, data_dir: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, data_dir);
    var dir = try std.Io.Dir.cwd().openDir(io, data_dir, .{ .iterate = true });
    defer dir.close(io);
    try dir.setPermissions(io, privateDirPermissions());
}

fn syncDataDir(io: std.Io, data_dir: []const u8) !void {
    if (comptime builtin.os.tag == .windows) return;
    var dir = try std.Io.Dir.cwd().openDir(io, data_dir, .{});
    defer dir.close(io);
    switch (std.posix.errno(std.posix.system.fsync(dir.handle))) {
        .SUCCESS => {},
        else => return error.AnnDirectorySyncFailed,
    }
}

fn isValidSlabName(name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, slab_file_prefix) or !std.mem.endsWith(u8, name, slab_file_suffix)) return false;
    const middle = name[slab_file_prefix.len .. name.len - slab_file_suffix.len];
    if (middle.len == 0 or middle.len > 80) return false;
    for (middle) |byte| if (!std.ascii.isHex(byte) and byte != '-') return false;
    return true;
}

fn slabPath(allocator: std.mem.Allocator, data_dir: []const u8, slab_name: []const u8) ![]u8 {
    if (!isValidSlabName(slab_name)) return error.InvalidAnnSlabName;
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ data_dir, slab_name });
}

fn fileSize(io: std.Io, path: []const u8) !usize {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    return std.math.cast(usize, stat.size) orelse error.AnnSlabTooLarge;
}

fn fileIdentity(io: std.Io, path: []const u8) !FileIdentity {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{ .follow_symlinks = false });
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file) return error.InvalidAnnSidecar;
    return .{
        .inode = stat.inode,
        .size = stat.size,
        .mtime_ns = stat.mtime.nanoseconds,
        .ctime_ns = stat.ctime.nanoseconds,
    };
}

fn currentSlabName(io: std.Io, allocator: std.mem.Allocator, data_dir: []const u8) !?[]u8 {
    const path = try sidecarPath(allocator, data_dir);
    defer allocator.free(path);
    const storage = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_metadata_bytes)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(storage);
    if (storage.len < header_bytes or !std.mem.eql(u8, storage[0..8], &magic)) return error.InvalidAnnSidecar;
    if (std.mem.readInt(u16, storage[8..10], .little) != format_version) return error.UnsupportedAnnSidecarVersion;
    const model_len: usize = std.mem.readInt(u16, storage[32..34], .little);
    const slab_name_len: usize = std.mem.readInt(u16, storage[34..36], .little);
    const slab_start = std.math.add(usize, header_bytes, model_len) catch return error.InvalidAnnSidecar;
    if (slab_name_len == 0 or slab_start > storage.len or slab_name_len > storage.len - slab_start) return error.TruncatedAnnSidecar;
    const name = storage[slab_start .. slab_start + slab_name_len];
    if (!isValidSlabName(name)) return error.InvalidAnnSlabName;
    return try allocator.dupe(u8, name);
}

fn deleteReplacedSlab(
    io: std.Io,
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    previous_name: ?[]const u8,
    current_name: []const u8,
) void {
    const name = previous_name orelse return;
    if (std.mem.eql(u8, name, current_name)) return;
    const path = slabPath(allocator, data_dir, name) catch return;
    defer allocator.free(path);
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

fn updateScalar(hasher: *std.hash.Wyhash, value: anytype) void {
    hasher.update(std.mem.asBytes(&value));
}

/// Stable, cheap advisory freshness signature. This intentionally hashes the
/// parsed repository shape rather than every source byte so context queries do
/// not turn into a full-repository read. Git HEAD is checked independently.
pub fn manifestFingerprint(explorer: *Explorer, allocator: std.mem.Allocator) !u64 {
    explorer.mu.lockShared();
    defer explorer.mu.unlockShared();

    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(allocator);
    try paths.ensureTotalCapacity(allocator, explorer.outlines.count());
    var it = explorer.outlines.keyIterator();
    while (it.next()) |path| paths.appendAssumeCapacity(path.*);
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);

    var hash = std.hash.Wyhash.init(0x4344_4241_4e4e_3031);
    for (paths.items) |path| {
        const outline = explorer.outlines.get(path) orelse continue;
        hash.update(path);
        hash.update(&.{0});
        updateScalar(&hash, @intFromEnum(outline.language));
        updateScalar(&hash, outline.line_count);
        updateScalar(&hash, outline.byte_size);
        for (outline.symbols.items) |symbol| {
            updateScalar(&hash, @intFromEnum(symbol.kind));
            updateScalar(&hash, symbol.line_start);
            updateScalar(&hash, symbol.line_end);
            hash.update(symbol.name);
            hash.update(&.{0});
        }
    }
    return hash.final();
}

fn repositoryFingerprint(explorer: *Explorer, store: *Store, allocator: std.mem.Allocator) !u64 {
    const shape = try manifestFingerprint(explorer, allocator);
    const paths = try cloneSortedPaths(explorer, allocator);
    defer {
        for (paths) |path| allocator.free(path);
        allocator.free(paths);
    }
    const content = try store.contentFingerprintForPaths(paths);
    var hash = std.hash.Wyhash.init(0x4344_4252_4550_4f33);
    hash.update(std.mem.asBytes(&shape));
    hash.update(std.mem.asBytes(&content));
    return hash.final();
}

fn cloneSortedPaths(explorer: *Explorer, allocator: std.mem.Allocator) ![][]u8 {
    explorer.mu.lockShared();
    defer explorer.mu.unlockShared();
    const paths = try allocator.alloc([]u8, explorer.outlines.count());
    errdefer allocator.free(paths);
    var filled: usize = 0;
    errdefer for (paths[0..filled]) |path| allocator.free(path);
    var it = explorer.outlines.keyIterator();
    while (it.next()) |path| {
        paths[filled] = try allocator.dupe(u8, path.*);
        filled += 1;
    }
    std.mem.sort([]u8, paths, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    return paths;
}

fn appendAsciiPreview(out: *std.ArrayList(u8), allocator: std.mem.Allocator, bytes: []const u8, limit: usize) !void {
    const remaining = limit -| out.items.len;
    for (bytes[0..@min(bytes.len, remaining)]) |byte| {
        const safe = if (byte == '\n' or byte == '\t' or (byte >= 0x20 and byte < 0x7f)) byte else ' ';
        try out.append(allocator, safe);
    }
}

const Chunk = struct {
    source: []const u8,
    line_start: u32,
    line_end: u32,
};

const ChunkCursor = struct {
    content: []const u8,
    offset: usize = 0,
    line: u32 = 1,

    fn next(self: *ChunkCursor) ?Chunk {
        if (self.offset >= self.content.len) return null;
        const start = self.offset;
        const line_start = self.line;
        var end = @min(start + chunk_source_bytes, self.content.len);
        if (end < self.content.len) {
            if (std.mem.lastIndexOfScalar(u8, self.content[start..end], '\n')) |relative| {
                const line_end_offset = start + relative + 1;
                if (line_end_offset > start + chunk_source_bytes / 3) end = line_end_offset;
            }
        }
        if (end <= start) end = @min(start + 1, self.content.len);
        const source = self.content[start..end];
        var newlines: u32 = 0;
        for (source) |byte| if (byte == '\n') {
            newlines +|= 1;
        };
        const trailing_newline: u32 = if (source.len > 0 and source[source.len - 1] == '\n') 1 else 0;
        const line_end = line_start +| newlines -| trailing_newline;
        self.offset = end;
        self.line +|= newlines;
        return .{ .source = source, .line_start = line_start, .line_end = @max(line_start, line_end) };
    }
};

fn makeChunkCard(
    allocator: std.mem.Allocator,
    path: []const u8,
    language: []const u8,
    chunk: Chunk,
) ![]u8 {
    var card: std.ArrayList(u8) = .empty;
    errdefer card.deinit(allocator);
    const writer = cio.listWriter(&card, allocator);
    writer.print("Code snippet\nPath: {s}\nLanguage: {s}\nLines: {d}-{d}\n", .{
        path,
        language,
        chunk.line_start,
        chunk.line_end,
    }) catch return error.OutOfMemory;
    try appendAsciiPreview(&card, allocator, chunk.source, max_chunk_card_bytes);
    if (card.items.len > max_chunk_card_bytes) card.items.len = max_chunk_card_bytes;
    return try card.toOwnedSlice(allocator);
}

const FlushStats = struct {
    text_bytes: usize,
    records: usize,
    embedding_wall_ns: u64,
    insertion_ns: u64,
};

const BatchWorker = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    inputs: []const []const u8,
    result: ?semantic.EmbeddingBatchResult = null,
    failure: ?anyerror = null,

    fn run(self: *BatchWorker) void {
        self.result = semantic.embedIndexRemoteTexts(self.io, self.allocator, self.inputs) catch |err| {
            self.failure = err;
            return;
        };
    }
};

fn indexConcurrency() usize {
    const raw = cio.posixGetenv("CODEDB_SEMANTIC_INDEX_CONCURRENCY") orelse return default_parallel_batches;
    return @max(1, @min(max_parallel_batches, std.fmt.parseInt(usize, raw, 10) catch default_parallel_batches));
}

fn embeddingBatchCount(card_count: usize) usize {
    return (card_count + semantic.max_index_documents - 1) / semantic.max_index_documents;
}

fn embeddingCachePath(allocator: std.mem.Allocator, data_dir: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ data_dir, embedding_cache_name });
}

fn findBuildFile(files: []const CachedFileState, path: []const u8) ?CachedFileState {
    var lo: usize = 0;
    var hi: usize = files.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        switch (std.mem.order(u8, files[mid].path, path)) {
            .eq => return files[mid],
            .lt => lo = mid + 1,
            .gt => hi = mid,
        }
    }
    return null;
}

fn isFileUnchanged(explorer: *Explorer, store: *Store, bf: CachedFileState) bool {
    const line_count = explorer.outlineLineCount(bf.path) orelse return false;
    if (line_count != bf.line_count) return false;
    const latest = store.getLatest(bf.path) orelse return false;
    if (latest.op == .tombstone) return false;
    return latest.hash == bf.content_hash and latest.size == bf.size;
}

fn writeEmbeddingCache(
    io: std.Io,
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    model: []const u8,
    dimensions: u16,
    manifest: u64,
    vector_space_id: u64,
    calibration: []const f32,
    files: []const CachedFileState,
    keys: []const CardKey,
    vectors: []const f32,
) !void {
    if (model.len == 0 or model.len > std.math.maxInt(u16)) return error.InvalidEmbeddingModel;
    if (dimensions < 64 or dimensions > 4096 or calibration.len != dimensions) return error.InvalidEmbeddingDimensions;
    if (keys.len > max_records or files.len > max_records) return error.InvalidAnnRecordCount;
    const expected_floats = try std.math.mul(usize, keys.len, dimensions);
    if (vectors.len != expected_floats) return error.InvalidEmbeddingBatchShape;

    var files_byte_len: usize = 0;
    for (files) |f| {
        if (f.path.len == 0 or f.path.len > std.math.maxInt(u16) or !semantic.isRemoteCandidatePathAllowed(f.path)) {
            return error.InvalidAnnRecordPath;
        }
        files_byte_len = try std.math.add(usize, files_byte_len, 22 + f.path.len);
    }
    if (files_byte_len > std.math.maxInt(u32)) return error.AnnMetadataTooLarge;

    const final_path = try embeddingCachePath(allocator, data_dir);
    defer allocator.free(final_path);
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.{x}.tmp", .{ final_path, cio.randU64() });
    defer allocator.free(tmp_path);
    errdefer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};

    var file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{ .permissions = privateFilePermissions() });
    var file_open = true;
    defer if (file_open) file.close(io);
    var file_buffer: [256 * 1024]u8 = undefined;
    var writer = file.writer(io, &file_buffer);

    var header: [cache_header_bytes]u8 = @splat(0);
    @memcpy(header[0..8], &cache_magic);
    std.mem.writeInt(u16, header[8..10], cache_format_version, .little);
    std.mem.writeInt(u16, header[10..12], dimensions, .little);
    std.mem.writeInt(u32, header[12..16], @intCast(keys.len), .little);
    std.mem.writeInt(u64, header[16..24], manifest, .little);
    std.mem.writeInt(u64, header[24..32], vector_space_id, .little);
    std.mem.writeInt(u16, header[32..34], @intCast(model.len), .little);
    std.mem.writeInt(u32, header[34..38], @intCast(files.len), .little);
    std.mem.writeInt(u32, header[38..42], @intCast(files_byte_len), .little);
    try writer.interface.writeAll(&header);
    try writer.interface.writeAll(model);
    for (calibration) |value| {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, @bitCast(value), .little);
        try writer.interface.writeAll(&bytes);
    }
    for (files) |f| {
        var len_bytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &len_bytes, @intCast(f.path.len), .little);
        try writer.interface.writeAll(&len_bytes);
        try writer.interface.writeAll(f.path);
        var meta_bytes: [20]u8 = undefined;
        std.mem.writeInt(u64, meta_bytes[0..8], f.content_hash, .little);
        std.mem.writeInt(u64, meta_bytes[8..16], f.size, .little);
        std.mem.writeInt(u32, meta_bytes[16..20], f.line_count, .little);
        try writer.interface.writeAll(&meta_bytes);
    }
    for (keys, 0..) |key, row_index| {
        var key_bytes: [16]u8 = undefined;
        std.mem.writeInt(u64, key_bytes[0..8], key.lo, .little);
        std.mem.writeInt(u64, key_bytes[8..16], key.hi, .little);
        try writer.interface.writeAll(&key_bytes);
        const row = vectors[row_index * @as(usize, dimensions) ..][0..dimensions];
        for (row) |value| {
            var bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, &bytes, @bitCast(value), .little);
            try writer.interface.writeAll(&bytes);
        }
    }
    try writer.interface.flush();
    try file.sync(io);
    file.close(io);
    file_open = false;
    try std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), final_path, io);
}

fn loadEmbeddingCache(
    io: std.Io,
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    config: *const semantic.Config,
    live_calibration: []const f32,
    vec_map: *std.AutoHashMap(CardKey, u32),
    cached_keys: *std.ArrayList(CardKey),
    cached_vectors: *std.ArrayList(f32),
) void {
    const path = embeddingCachePath(allocator, data_dir) catch return;
    defer allocator.free(path);
    const storage = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_embedding_cache_bytes)) catch return;
    defer allocator.free(storage);
    if (storage.len < cache_header_bytes or !std.mem.eql(u8, storage[0..8], &cache_magic)) return;
    var pos: usize = 8;
    const version = take(u16, storage, &pos) catch return;
    if (version != cache_format_version) return;
    const dimensions = take(u16, storage, &pos) catch return;
    const entry_count = take(u32, storage, &pos) catch return;
    _ = take(u64, storage, &pos) catch return; // manifest
    const stored_space_id = take(u64, storage, &pos) catch return;
    const model_len = take(u16, storage, &pos) catch return;
    const file_count = take(u32, storage, &pos) catch return;
    const files_byte_len = take(u32, storage, &pos) catch return;
    pos += 6; // reserved
    if (dimensions != config.dimensions or entry_count == 0 or entry_count > max_records or
        file_count > max_records or !config.matchesVectorSpaceId(stored_space_id)) return;
    const cal_bytes = std.math.mul(usize, dimensions, @sizeOf(f32)) catch return;
    const prefix_needed = std.math.add(usize, model_len, std.math.add(usize, cal_bytes, files_byte_len) catch return) catch return;
    if (pos > storage.len or prefix_needed > storage.len - pos) return;
    const model = storage[pos .. pos + model_len];
    if (!std.mem.eql(u8, model, config.model)) return;
    pos += model_len;

    const stored_cal = allocator.alloc(f32, dimensions) catch return;
    defer allocator.free(stored_cal);
    for (stored_cal) |*val| {
        const bits = take(u32, storage, &pos) catch return;
        val.* = @bitCast(bits);
        if (!std.math.isFinite(val.*)) return;
    }
    const cal_cos = semantic.cosineF32(live_calibration, stored_cal) catch return;
    if (cal_cos < semantic.calibration_min_cosine) return;
    pos += files_byte_len;

    const entry_bytes = std.math.add(usize, 16, cal_bytes) catch return;
    const total_entries_bytes = std.math.mul(usize, entry_count, entry_bytes) catch return;
    if (pos > storage.len or total_entries_bytes != storage.len - pos) return;

    vec_map.ensureTotalCapacity(@intCast(entry_count)) catch return;
    cached_keys.ensureTotalCapacity(allocator, entry_count) catch return;
    cached_vectors.ensureTotalCapacity(allocator, @as(usize, entry_count) * dimensions) catch return;

    const row_buf = allocator.alloc(f32, dimensions) catch return;
    defer allocator.free(row_buf);
    for (0..entry_count) |_| {
        const lo = take(u64, storage, &pos) catch return;
        const hi = take(u64, storage, &pos) catch return;
        var valid_row = true;
        for (row_buf) |*val| {
            const bits = take(u32, storage, &pos) catch return;
            val.* = @bitCast(bits);
            if (!std.math.isFinite(val.*)) valid_row = false;
        }
        if (!valid_row) continue;
        const key = CardKey{ .lo = lo, .hi = hi };
        if (vec_map.contains(key)) continue;
        const idx: u32 = @intCast(cached_keys.items.len);
        cached_keys.append(allocator, key) catch return;
        cached_vectors.appendSlice(allocator, row_buf) catch {
            _ = cached_keys.pop();
            return;
        };
        vec_map.putAssumeCapacity(key, idx);
    }
}

fn loadCacheFilesForManifest(io: std.Io, allocator: std.mem.Allocator, data_dir: []const u8, loaded: *Loaded) void {
    const path = embeddingCachePath(allocator, data_dir) catch return;
    defer allocator.free(path);
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return;
    defer file.close(io);

    var header: [cache_header_bytes]u8 = undefined;
    if ((file.readPositionalAll(io, &header, 0) catch return) != cache_header_bytes) return;
    if (!std.mem.eql(u8, header[0..8], &cache_magic)) return;
    if (std.mem.readInt(u16, header[8..10], .little) != cache_format_version) return;
    const dimensions = std.mem.readInt(u16, header[10..12], .little);
    const manifest = std.mem.readInt(u64, header[16..24], .little);
    const model_len: usize = std.mem.readInt(u16, header[32..34], .little);
    const file_count: usize = std.mem.readInt(u32, header[34..38], .little);
    const files_byte_len: usize = std.mem.readInt(u32, header[38..42], .little);
    if (dimensions != loaded.dimensions or manifest == 0 or manifest != loaded.manifest or
        file_count == 0 or file_count > max_records or files_byte_len == 0) return;

    const cal_bytes = std.math.mul(usize, dimensions, @sizeOf(f32)) catch return;
    const files_offset = std.math.add(usize, cache_header_bytes, std.math.add(usize, model_len, cal_bytes) catch return) catch return;
    const prefix_bytes = std.math.add(usize, files_offset, files_byte_len) catch return;
    if (prefix_bytes > max_metadata_bytes) return;

    const storage = allocator.alloc(u8, files_byte_len) catch return;
    errdefer allocator.free(storage);
    const model_buf = allocator.alloc(u8, model_len) catch {
        allocator.free(storage);
        return;
    };
    defer allocator.free(model_buf);
    if ((file.readPositionalAll(io, model_buf, cache_header_bytes) catch {
        allocator.free(storage);
        return;
    }) != model_len) {
        allocator.free(storage);
        return;
    }
    if (!std.mem.eql(u8, model_buf, loaded.model)) {
        allocator.free(storage);
        return;
    }
    if ((file.readPositionalAll(io, storage, files_offset) catch {
        allocator.free(storage);
        return;
    }) != files_byte_len) {
        allocator.free(storage);
        return;
    }

    const files = allocator.alloc(CachedFileState, file_count) catch {
        allocator.free(storage);
        return;
    };
    var pos: usize = 0;
    for (files, 0..) |*f, idx| {
        const path_len = take(u16, storage, &pos) catch {
            allocator.free(files);
            allocator.free(storage);
            return;
        };
        const record_bytes = std.math.add(usize, path_len, 20) catch {
            allocator.free(files);
            allocator.free(storage);
            return;
        };
        if (path_len == 0 or pos > storage.len or record_bytes > storage.len - pos) {
            allocator.free(files);
            allocator.free(storage);
            return;
        }
        const f_path = storage[pos .. pos + path_len];
        if (!semantic.isRemoteCandidatePathAllowed(f_path)) {
            allocator.free(files);
            allocator.free(storage);
            return;
        }
        if (idx > 0 and std.mem.order(u8, files[idx - 1].path, f_path) != .lt) {
            allocator.free(files);
            allocator.free(storage);
            return;
        }
        pos += path_len;
        const content_hash = take(u64, storage, &pos) catch {
            allocator.free(files);
            allocator.free(storage);
            return;
        };
        const size = take(u64, storage, &pos) catch {
            allocator.free(files);
            allocator.free(storage);
            return;
        };
        const line_count = take(u32, storage, &pos) catch {
            allocator.free(files);
            allocator.free(storage);
            return;
        };
        if (line_count == 0) {
            allocator.free(files);
            allocator.free(storage);
            return;
        }
        f.* = .{
            .path = f_path,
            .content_hash = content_hash,
            .size = size,
            .line_count = line_count,
        };
    }
    if (pos != storage.len) {
        allocator.free(files);
        allocator.free(storage);
        return;
    }
    loaded.build_files_storage = storage;
    loaded.build_files = files;
}

const EmbedWaveStats = struct {
    text_bytes: usize,
    records: usize,
    embedding_wall_ns: u64,
};

fn embedMissingWave(
    io: std.Io,
    allocator: std.mem.Allocator,
    config: semantic.Config,
    cards: *std.ArrayList([]u8),
    pending_keys: *std.ArrayList(CardKey),
    vec_map: *std.AutoHashMap(CardKey, u32),
    cached_keys: *std.ArrayList(CardKey),
    cached_vectors: *std.ArrayList(f32),
) !EmbedWaveStats {
    if (cards.items.len == 0) return .{
        .text_bytes = 0,
        .records = 0,
        .embedding_wall_ns = 0,
    };
    if (cards.items.len != pending_keys.items.len) return error.AnnRecordMappingMismatch;
    const batch_count = embeddingBatchCount(cards.items.len);
    if (batch_count > max_parallel_batches) return error.TooManyEmbeddingBatches;
    var input_storage: [max_parallel_batches][semantic.max_index_documents][]const u8 = undefined;
    var workers: [max_parallel_batches]BatchWorker = undefined;
    var threads: [max_parallel_batches]?std.Thread = @splat(null);
    const embedding_started = cio.nanoTimestamp();
    for (0..batch_count) |batch_index| {
        const start = batch_index * semantic.max_index_documents;
        const end = @min(cards.items.len, start + semantic.max_index_documents);
        for (cards.items[start..end], 0..) |card, i| input_storage[batch_index][i] = card;
        workers[batch_index] = .{
            .io = io,
            // Each request runs on its own OS thread. c_allocator is safe for
            // concurrent allocations; callers may supply a non-thread-safe
            // arena/GPA for the surrounding build state.
            .allocator = std.heap.c_allocator,
            .inputs = input_storage[batch_index][0 .. end - start],
        };
        threads[batch_index] = std.Thread.spawn(.{}, BatchWorker.run, .{&workers[batch_index]}) catch null;
        if (threads[batch_index] == null) workers[batch_index].run();
    }
    for (threads[0..batch_count]) |maybe_thread| if (maybe_thread) |thread| thread.join();
    const embedding_wall_ns = elapsedNs(embedding_started);
    defer for (workers[0..batch_count]) |worker| if (worker.result) |embedded| worker.allocator.free(embedded.vectors);
    for (workers[0..batch_count]) |worker| if (worker.failure) |err| return err;

    var text_bytes: usize = 0;
    for (workers[0..batch_count], 0..) |worker, batch_index| {
        const embedded = worker.result orelse return error.MissingEmbeddingBatchResult;
        if (embedded.dimensions != config.dimensions or !std.mem.eql(u8, embedded.model, config.model)) {
            return error.EmbeddingConfigChangedDuringBuild;
        }
        if (embedded.count != worker.inputs.len) return error.InvalidEmbeddingBatchShape;
        text_bytes = try std.math.add(usize, text_bytes, embedded.text_bytes_sent);
        const key_start = batch_index * semantic.max_index_documents;
        for (0..embedded.count) |row_index| {
            const key = pending_keys.items[key_start + row_index];
            if (vec_map.contains(key)) continue;
            const row = embedded.vectors[row_index * @as(usize, embedded.dimensions) ..][0..embedded.dimensions];
            const idx: u32 = @intCast(cached_keys.items.len);
            try cached_keys.append(allocator, key);
            errdefer _ = cached_keys.pop();
            try cached_vectors.appendSlice(allocator, row);
            try vec_map.put(key, idx);
        }
    }
    const records = cards.items.len;
    for (cards.items) |card| allocator.free(card);
    cards.clearRetainingCapacity();
    pending_keys.clearRetainingCapacity();
    return .{
        .text_bytes = text_bytes,
        .records = records,
        .embedding_wall_ns = embedding_wall_ns,
    };
}

fn writeMetadata(
    io: std.Io,
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    model: []const u8,
    dimensions: u16,
    manifest: u64,
    vector_space_id: u64,
    calibration: []const f32,
    git_head: ?[40]u8,
    slab_name: []const u8,
    records: []const Record,
) !usize {
    if (model.len == 0 or model.len > std.math.maxInt(u16)) return error.InvalidEmbeddingModel;
    if (dimensions < 64 or dimensions > 4096 or calibration.len != dimensions) return error.InvalidEmbeddingDimensions;
    if (records.len == 0 or records.len > max_records) return error.InvalidAnnRecordCount;
    if (!isValidSlabName(slab_name) or slab_name.len > std.math.maxInt(u16)) return error.InvalidAnnSlabName;
    for (calibration) |value| if (!std.math.isFinite(value)) return error.InvalidEmbeddingNumber;
    for (records) |record| {
        if (!semantic.isRemoteCandidatePathAllowed(record.path) or record.path.len > std.math.maxInt(u16) or
            record.line_start == 0 or record.line_end < record.line_start) return error.InvalidAnnRecordPath;
    }

    var total = header_bytes;
    total = try std.math.add(usize, total, model.len);
    total = try std.math.add(usize, total, slab_name.len);
    total = try std.math.add(usize, total, if (git_head == null) @as(usize, 0) else 40);
    total = try std.math.add(usize, total, try std.math.mul(usize, calibration.len, @sizeOf(f32)));
    for (records) |record| total = try std.math.add(usize, total, 10 + record.path.len);
    if (total > max_metadata_bytes) return error.AnnMetadataTooLarge;

    const final_path = try sidecarPath(allocator, data_dir);
    defer allocator.free(final_path);
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.{x}.tmp", .{ final_path, cio.randU64() });
    defer allocator.free(tmp_path);
    errdefer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};

    var file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{ .permissions = privateFilePermissions() });
    var file_open = true;
    defer if (file_open) file.close(io);
    var file_buffer: [256 * 1024]u8 = undefined;
    var writer = file.writer(io, &file_buffer);

    var header: [header_bytes]u8 = @splat(0);
    @memcpy(header[0..8], &magic);
    std.mem.writeInt(u16, header[8..10], format_version, .little);
    std.mem.writeInt(u16, header[10..12], dimensions, .little);
    std.mem.writeInt(u32, header[12..16], @intCast(records.len), .little);
    std.mem.writeInt(u64, header[16..24], manifest, .little);
    std.mem.writeInt(u64, header[24..32], vector_space_id, .little);
    std.mem.writeInt(u16, header[32..34], @intCast(model.len), .little);
    std.mem.writeInt(u16, header[34..36], @intCast(slab_name.len), .little);
    header[36] = if (git_head == null) 0 else 40;
    std.mem.writeInt(u32, header[40..44], @intCast(calibration.len), .little);
    try writer.interface.writeAll(&header);
    try writer.interface.writeAll(model);
    try writer.interface.writeAll(slab_name);
    if (git_head) |head| try writer.interface.writeAll(&head);
    for (calibration) |value| {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, @bitCast(value), .little);
        try writer.interface.writeAll(&bytes);
    }
    for (records) |record| {
        var length: [2]u8 = undefined;
        std.mem.writeInt(u16, &length, @intCast(record.path.len), .little);
        try writer.interface.writeAll(&length);
        try writer.interface.writeAll(record.path);
        var lines: [8]u8 = undefined;
        std.mem.writeInt(u32, lines[0..4], record.line_start, .little);
        std.mem.writeInt(u32, lines[4..8], record.line_end, .little);
        try writer.interface.writeAll(&lines);
    }
    try writer.interface.flush();
    try file.sync(io);
    file.close(io);
    file_open = false;
    try std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), final_path, io);
    return total;
}

const PlannedChunk = struct {
    record: Record,
    key: CardKey,
};

pub fn build(
    io: std.Io,
    allocator: std.mem.Allocator,
    explorer: *Explorer,
    store: *Store,
    project_root: []const u8,
    data_dir: []const u8,
) !BuildStats {
    const started = cio.nanoTimestamp();
    try secureDataDir(io, data_dir);
    const previous_slab_name = currentSlabName(io, allocator, data_dir) catch null;
    defer if (previous_slab_name) |name| allocator.free(name);
    const config = semantic.Config.fromEnv();
    try config.validate();
    const vector_space_id = config.vectorSpaceId();
    const manifest_before = try repositoryFingerprint(explorer, store, allocator);
    const git_head_before = try git_mod.getGitHead(project_root, allocator);
    const paths = try cloneSortedPaths(explorer, allocator);
    defer {
        for (paths) |path| allocator.free(path);
        allocator.free(paths);
    }
    var remote_paths: std.ArrayList([]const u8) = .empty;
    defer remote_paths.deinit(allocator);
    try remote_paths.ensureTotalCapacity(allocator, paths.len);
    for (paths) |path| {
        if (semantic.isRemoteCandidatePathAllowed(path)) remote_paths.appendAssumeCapacity(path);
    }
    const source_content_before = try store.semanticContentFingerprintForPaths(remote_paths.items);
    var embedded_content = Store.semanticContentHasher();

    var index = ann.Index.init(allocator, config.dimensions, .{});
    defer index.deinit();

    const calibration_started = cio.nanoTimestamp();
    const calibration_result = try semantic.embedRemoteTexts(io, allocator, &.{semantic.calibration_text});
    defer allocator.free(calibration_result.vectors);
    if (calibration_result.count != 1 or calibration_result.dimensions != config.dimensions or
        !std.mem.eql(u8, calibration_result.model, config.model)) return error.InvalidEmbeddingCalibration;
    const calibration = calibration_result.vectors[0..config.dimensions];

    var vec_map = std.AutoHashMap(CardKey, u32).init(allocator);
    defer vec_map.deinit();
    var cached_keys: std.ArrayList(CardKey) = .empty;
    defer cached_keys.deinit(allocator);
    var cached_vectors: std.ArrayList(f32) = .empty;
    defer cached_vectors.deinit(allocator);
    loadEmbeddingCache(io, allocator, data_dir, &config, calibration, &vec_map, &cached_keys, &cached_vectors);

    var cards: std.ArrayList([]u8) = .empty;
    defer {
        for (cards.items) |card| allocator.free(card);
        cards.deinit(allocator);
    }
    var pending_keys: std.ArrayList(CardKey) = .empty;
    defer pending_keys.deinit(allocator);
    var queued_keys = std.AutoHashMap(CardKey, void).init(allocator);
    defer queued_keys.deinit();
    var planned_chunks: std.ArrayList(PlannedChunk) = .empty;
    defer planned_chunks.deinit(allocator);
    var indexed_records: std.ArrayList(Record) = .empty;
    defer indexed_records.deinit(allocator);
    var build_files: std.ArrayList(CachedFileState) = .empty;
    defer build_files.deinit(allocator);

    const parallel_batches = indexConcurrency();
    const wave_capacity = parallel_batches * semantic.max_index_documents;
    var text_bytes_sent: usize = calibration_result.text_bytes_sent;
    var embedding_wall_ns: u64 = elapsedNs(calibration_started);
    var reused_records: usize = 0;
    var newly_embedded_records: usize = 0;
    var blocked: usize = 0;
    var files_indexed: usize = 0;
    for (paths) |path| {
        if (!semantic.isRemoteCandidatePathAllowed(path)) {
            blocked += 1;
            continue;
        }
        const content = (try explorer.getContent(path, allocator)) orelse return error.RepositoryChangedDuringAnnBuild;
        defer allocator.free(content);
        const content_hash = std.hash.Wyhash.hash(0, content);
        const content_size: u64 = @intCast(content.len);
        Store.updateSemanticContentFingerprint(
            &embedded_content,
            path,
            content_hash,
            content_size,
        );
        if (content.len == 0) continue;
        var outline = (try explorer.getOutline(path, allocator)) orelse return error.RepositoryChangedDuringAnnBuild;
        defer outline.deinit();
        var cursor = ChunkCursor{ .content = content };
        var chunks_for_file: usize = 0;
        while (chunks_for_file < max_chunks_per_file) : (chunks_for_file += 1) {
            const chunk = cursor.next() orelse break;
            if (planned_chunks.items.len >= max_records) return error.AnnRecordBudgetExceeded;
            const card = try makeChunkCard(allocator, path, @tagName(outline.language), chunk);
            const key = hashChunkCard(card);
            try planned_chunks.append(allocator, .{
                .record = .{
                    .path = path,
                    .line_start = chunk.line_start,
                    .line_end = chunk.line_end,
                },
                .key = key,
            });
            if (vec_map.contains(key) or queued_keys.contains(key)) {
                allocator.free(card);
                reused_records += 1;
                continue;
            }
            if (cards.items.len == wave_capacity) {
                const stats = try embedMissingWave(io, allocator, config, &cards, &pending_keys, &vec_map, &cached_keys, &cached_vectors);
                queued_keys.clearRetainingCapacity();
                text_bytes_sent = try std.math.add(usize, text_bytes_sent, stats.text_bytes);
                embedding_wall_ns = try std.math.add(u64, embedding_wall_ns, stats.embedding_wall_ns);
                newly_embedded_records += stats.records;
            }
            try cards.append(allocator, card);
            try pending_keys.append(allocator, key);
            try queued_keys.put(key, {});
        }
        if (chunks_for_file > 0) {
            files_indexed += 1;
            try build_files.append(allocator, .{
                .path = path,
                .content_hash = content_hash,
                .size = content_size,
                .line_count = @max(1, outline.line_count),
            });
        }
    }
    const final_stats = try embedMissingWave(io, allocator, config, &cards, &pending_keys, &vec_map, &cached_keys, &cached_vectors);
    queued_keys.clearRetainingCapacity();
    text_bytes_sent = try std.math.add(usize, text_bytes_sent, final_stats.text_bytes);
    embedding_wall_ns = try std.math.add(u64, embedding_wall_ns, final_stats.embedding_wall_ns);
    newly_embedded_records += final_stats.records;
    if (planned_chunks.items.len == 0) return error.NoSafeAnnRecords;

    // Persist newly computed chunk vectors before source revalidation so that if
    // HEAD or working tree files moved during a long build, the next build
    // reuses all completed embeddings instead of starting from scratch.
    if (newly_embedded_records > 0) {
        writeEmbeddingCache(
            io,
            allocator,
            data_dir,
            config.model,
            config.dimensions,
            0,
            vector_space_id,
            calibration,
            &.{},
            cached_keys.items,
            cached_vectors.items,
        ) catch {};
    }

    const insertion_started = cio.nanoTimestamp();
    try indexed_records.ensureTotalCapacity(allocator, planned_chunks.items.len);
    var active_keys: std.ArrayList(CardKey) = .empty;
    defer active_keys.deinit(allocator);
    var active_vectors: std.ArrayList(f32) = .empty;
    defer active_vectors.deinit(allocator);
    try active_keys.ensureTotalCapacity(allocator, planned_chunks.items.len);
    try active_vectors.ensureTotalCapacity(allocator, planned_chunks.items.len * @as(usize, config.dimensions));
    var active_seen = std.AutoHashMap(CardKey, void).init(allocator);
    defer active_seen.deinit();

    for (planned_chunks.items) |item| {
        const slot = vec_map.get(item.key) orelse return error.MissingEmbeddingBatchResult;
        const row = cached_vectors.items[@as(usize, slot) * @as(usize, config.dimensions) ..][0..config.dimensions];
        const id = try index.insert(row);
        if (id != indexed_records.items.len) return error.AnnRecordMappingMismatch;
        indexed_records.appendAssumeCapacity(item.record);
        if (!active_seen.contains(item.key)) {
            try active_seen.put(item.key, {});
            active_keys.appendAssumeCapacity(item.key);
            active_vectors.appendSliceAssumeCapacity(row);
        }
    }
    const insertion_ns = elapsedNs(insertion_started);
    if (index.len() == 0) return error.NoSafeAnnRecords;
    if (try index.slabImageSize() > max_slab_bytes) return error.AnnSlabTooLarge;

    const validation_started = cio.nanoTimestamp();
    if (embedded_content.final() != source_content_before) return error.RepositoryChangedDuringAnnBuild;
    const source_root = explorer.root_dir orelse return error.InvalidProjectRoot;
    if (try watcher.liveIndexedContentFingerprint(io, source_root, allocator) != source_content_before) {
        return error.RepositoryChangedDuringAnnBuild;
    }

    const manifest_after = try repositoryFingerprint(explorer, store, allocator);
    if (manifest_after != manifest_before) return error.RepositoryChangedDuringAnnBuild;
    const git_head_after = try git_mod.getGitHead(project_root, allocator);
    if (!headsEqual(git_head_before, git_head_after)) return error.RepositoryChangedDuringAnnBuild;
    const source_validation_ns = elapsedNs(validation_started);

    const slab_name = try std.fmt.allocPrint(allocator, "{s}{x}-{x}-{x}{s}", .{
        slab_file_prefix,
        manifest_after,
        vector_space_id,
        cio.randU64(),
        slab_file_suffix,
    });
    defer allocator.free(slab_name);
    const slab_path = try slabPath(allocator, data_dir, slab_name);
    defer allocator.free(slab_path);
    var slab_referenced = false;
    errdefer if (!slab_referenced) std.Io.Dir.cwd().deleteFile(io, slab_path) catch {};
    try index.writeSlabs(slab_path);
    const slab_bytes = try fileSize(io, slab_path);
    if (slab_bytes > max_slab_bytes) return error.AnnSlabTooLarge;
    var slab_file = try std.Io.Dir.cwd().openFile(io, slab_path, .{ .mode = .read_write });
    defer slab_file.close(io);
    try slab_file.setPermissions(io, privateFilePermissions());

    writeEmbeddingCache(
        io,
        allocator,
        data_dir,
        config.model,
        config.dimensions,
        manifest_after,
        vector_space_id,
        calibration,
        build_files.items,
        active_keys.items,
        active_vectors.items,
    ) catch {};

    const metadata_bytes = try writeMetadata(
        io,
        allocator,
        data_dir,
        config.model,
        config.dimensions,
        manifest_after,
        vector_space_id,
        calibration,
        git_head_after,
        slab_name,
        indexed_records.items,
    );
    // The metadata rename now references this generation. Retain the slab even
    // if the following directory fsync fails; deleting it would turn a durable
    // rename with a transient sync error into a guaranteed broken sidecar.
    slab_referenced = true;
    try syncDataDir(io, data_dir);
    // The metadata rename is the commit point. Only after it succeeds may the
    // previously referenced slab be removed; existing POSIX mmaps stay valid,
    // while platforms that refuse deletion simply retain a harmless cache file.
    deleteReplacedSlab(io, allocator, data_dir, previous_slab_name, slab_name);
    const file_bytes = try std.math.add(usize, metadata_bytes, slab_bytes);
    return .{
        .records = index.len(),
        .reused_records = reused_records,
        .files_indexed = files_indexed,
        .dimensions = config.dimensions,
        .model = config.model,
        .file_bytes = file_bytes,
        .graph_bytes = slab_bytes,
        .metadata_bytes = metadata_bytes,
        .vector_payload_bytes = try ann.vectorPayloadBytes(index.len(), config.dimensions),
        .text_bytes_sent = text_bytes_sent,
        .sensitive_paths_blocked = blocked,
        .manifest = manifest_after,
        .elapsed_ns = elapsedNs(started),
        .embedding_wall_ns = embedding_wall_ns,
        .insertion_ns = insertion_ns,
        .source_validation_ns = source_validation_ns,
        .parallel_batches = parallel_batches,
        .vector_space_id = vector_space_id,
    };
}

fn take(comptime T: type, data: []const u8, pos: *usize) !T {
    const size = @sizeOf(T);
    if (pos.* > data.len or size > data.len - pos.*) return error.TruncatedAnnSidecar;
    const value = std.mem.readInt(T, data[pos.*..][0..size], .little);
    pos.* += size;
    return value;
}

fn loadMetadata(io: std.Io, allocator: std.mem.Allocator, data_dir: []const u8) !Loaded {
    const path = try sidecarPath(allocator, data_dir);
    defer allocator.free(path);
    const storage = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_metadata_bytes)) catch |err| switch (err) {
        error.FileNotFound => return error.AnnIndexMissing,
        else => return err,
    };
    errdefer allocator.free(storage);
    if (storage.len < header_bytes or !std.mem.eql(u8, storage[0..8], &magic)) return error.InvalidAnnSidecar;
    var pos: usize = 8;
    if (try take(u16, storage, &pos) != format_version) return error.UnsupportedAnnSidecarVersion;
    const dimensions = try take(u16, storage, &pos);
    const count = try take(u32, storage, &pos);
    const manifest = try take(u64, storage, &pos);
    const vector_space_id = try take(u64, storage, &pos);
    const model_len = try take(u16, storage, &pos);
    const slab_name_len = try take(u16, storage, &pos);
    if (pos > storage.len or 4 > storage.len - pos) return error.TruncatedAnnSidecar;
    const head_len = storage[pos];
    pos += 4; // head_len + three reserved bytes
    const calibration_count = try take(u32, storage, &pos);
    _ = try take(u32, storage, &pos); // reserved
    if (dimensions < 64 or dimensions > 4096 or count == 0 or count > max_records or
        model_len == 0 or model_len > 256 or calibration_count != dimensions or
        (head_len != 0 and head_len != 40)) return error.InvalidAnnSidecar;
    const fixed_payload = std.math.add(usize, model_len, slab_name_len) catch return error.InvalidAnnSidecar;
    const with_head = std.math.add(usize, fixed_payload, head_len) catch return error.InvalidAnnSidecar;
    const calibration_bytes = std.math.mul(usize, calibration_count, @sizeOf(f32)) catch return error.InvalidAnnSidecar;
    const required = std.math.add(usize, with_head, calibration_bytes) catch return error.InvalidAnnSidecar;
    if (pos > storage.len or required > storage.len - pos) return error.TruncatedAnnSidecar;
    const model = storage[pos .. pos + model_len];
    pos += model_len;
    const slab_name = storage[pos .. pos + slab_name_len];
    if (!isValidSlabName(slab_name)) return error.InvalidAnnSlabName;
    pos += slab_name_len;
    var git_head: ?[40]u8 = null;
    if (head_len == 40) {
        var head: [40]u8 = undefined;
        @memcpy(&head, storage[pos .. pos + 40]);
        git_head = head;
        pos += 40;
    }
    const calibration = try allocator.alloc(f32, calibration_count);
    errdefer allocator.free(calibration);
    for (calibration) |*value| {
        const bits = try take(u32, storage, &pos);
        value.* = @bitCast(bits);
        if (!std.math.isFinite(value.*)) return error.InvalidEmbeddingNumber;
    }
    const minimum_record_bytes: usize = 11; // u16 length + >=1 path + two u32 lines
    if (count > (storage.len - pos) / minimum_record_bytes) return error.TruncatedAnnSidecar;
    const records = try allocator.alloc(Record, count);
    errdefer allocator.free(records);
    for (records) |*record| {
        const path_len = try take(u16, storage, &pos);
        const record_bytes = std.math.add(usize, path_len, 8) catch return error.InvalidAnnSidecar;
        if (path_len == 0 or pos > storage.len or record_bytes > storage.len - pos) return error.TruncatedAnnSidecar;
        const record_path = storage[pos .. pos + path_len];
        if (!semantic.isRemoteCandidatePathAllowed(record_path)) return error.InvalidAnnRecordPath;
        pos += path_len;
        const line_start = try take(u32, storage, &pos);
        const line_end = try take(u32, storage, &pos);
        if (line_start == 0 or line_end < line_start) return error.InvalidAnnRecordPath;
        record.* = .{ .path = record_path, .line_start = line_start, .line_end = line_end };
    }
    if (pos != storage.len) return error.InvalidAnnSidecar;

    const slab_path = try slabPath(allocator, data_dir, slab_name);
    errdefer allocator.free(slab_path);
    const slab_bytes = fileSize(io, slab_path) catch |err| switch (err) {
        error.FileNotFound => return error.InvalidAnnSidecar,
        else => return err,
    };
    if (slab_bytes == 0 or slab_bytes > max_slab_bytes) return error.AnnSlabTooLarge;
    var index = ann.Index.init(allocator, dimensions, .{});
    errdefer index.deinit();
    var loaded = Loaded{
        .allocator = allocator,
        .storage = storage,
        .records = records,
        .slab_path = slab_path,
        .slab_bytes = slab_bytes,
        .model = model,
        .dimensions = dimensions,
        .manifest = manifest,
        .vector_space_id = vector_space_id,
        .calibration = calibration,
        .git_head = git_head,
        .index = index,
    };
    loadCacheFilesForManifest(io, allocator, data_dir, &loaded);
    return loaded;
}

fn load(io: std.Io, allocator: std.mem.Allocator, data_dir: []const u8) !Loaded {
    var loaded = try loadMetadata(io, allocator, data_dir);
    errdefer loaded.deinit();
    try loaded.loadGraph();
    return loaded;
}

/// Validate and mmap a persisted sidecar without issuing an embedding request.
/// Used by release smoke/RSS tooling and intentionally returns no record paths.
pub fn validateSidecar(io: std.Io, allocator: std.mem.Allocator, data_dir: []const u8) !void {
    var loaded = try load(io, allocator, data_dir);
    defer loaded.deinit();
}

fn headsEqual(a: ?[40]u8, b: ?[40]u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, &a.?, &b.?);
}

/// Validate every untrusted metadata range against the current live outline
/// before mmaping or searching the graph. Records produced by the builder are
/// grouped by path, so retaining the previous count avoids repeated locks on
/// the common multi-chunk-per-file path without allocating attacker-sized
/// validation state.
fn validateRecordLineRanges(explorer: *Explorer, records: []const Record) !void {
    var previous_path: []const u8 = "";
    var previous_line_count: u32 = 0;
    for (records) |record| {
        if (!std.mem.eql(u8, record.path, previous_path)) {
            previous_line_count = explorer.outlineLineCount(record.path) orelse return error.InvalidAnnRecordPath;
            previous_path = record.path;
        }
        if (record.line_start == 0 or record.line_start > previous_line_count or
            record.line_end < record.line_start or record.line_end > previous_line_count)
        {
            return error.InvalidAnnRecordPath;
        }
    }
}

fn validateStaleRecordLineRanges(
    explorer: *Explorer,
    store: *Store,
    records: []const Record,
    build_files: []const CachedFileState,
) !void {
    var previous_path: []const u8 = "";
    var previous_line_count: u32 = 0;
    var previous_unchanged = false;
    var unchanged_records: usize = 0;
    for (records) |record| {
        if (!std.mem.eql(u8, record.path, previous_path)) {
            const bf = findBuildFile(build_files, record.path) orelse return error.InvalidAnnRecordPath;
            previous_line_count = bf.line_count;
            previous_unchanged = isFileUnchanged(explorer, store, bf);
            previous_path = record.path;
        }
        if (record.line_start == 0 or record.line_start > previous_line_count or
            record.line_end < record.line_start or record.line_end > previous_line_count)
        {
            return error.InvalidAnnRecordPath;
        }
        if (previous_unchanged) unchanged_records += 1;
    }
    if (unchanged_records == 0) return error.StaleAnnManifest;
}

fn validateGenerationFreshness(
    temporary: std.mem.Allocator,
    explorer: *Explorer,
    store: *Store,
    current_head: ?[40]u8,
    loaded: *const Loaded,
) !void {
    const current_manifest = try repositoryFingerprint(explorer, store, temporary);
    if (current_manifest == loaded.manifest) {
        if (!headsEqual(current_head, loaded.git_head) and loaded.build_files == null) {
            return error.StaleAnnGitHead;
        }
        try validateRecordLineRanges(explorer, loaded.records);
        return;
    }
    const build_files = loaded.build_files orelse {
        if (!headsEqual(current_head, loaded.git_head)) return error.StaleAnnGitHead;
        return error.StaleAnnManifest;
    };
    try validateStaleRecordLineRanges(explorer, store, loaded.records, build_files);
}

fn validateLoadedConfig(config: *const semantic.Config, loaded: *const Loaded) !void {
    if (config.dimensions != loaded.dimensions) return error.AnnDimensionsMismatch;
    if (!std.mem.eql(u8, config.model, loaded.model)) return error.AnnModelMismatch;
    if (!config.matchesVectorSpaceId(loaded.vector_space_id)) return error.AnnVectorSpaceMismatch;
}

fn isLegacyHostedVectorSpace(
    current: *const semantic.Config,
    stored_model: []const u8,
    stored_dimensions: u16,
    stored_vector_space_id: u64,
) bool {
    // Only exact former hosted-default vector spaces may auto-migrate.
    // Custom endpoints, model overrides and altered metadata remain explicit.
    if (!std.mem.eql(u8, current.url, semantic.default_url) or
        !std.mem.eql(u8, current.model, semantic.default_model) or
        current.dimensions != semantic.default_dimensions or
        stored_dimensions != semantic.default_dimensions or
        (!std.mem.eql(u8, stored_model, semantic.legacy_qwen_model) and
            !std.mem.eql(u8, stored_model, semantic.jina_model)))
    {
        return false;
    }
    const legacy = semantic.Config{
        .url = semantic.default_url,
        .model = stored_model,
        .token = null,
        .dimensions = semantic.default_dimensions,
        .timeout_ms = semantic.default_timeout_ms,
    };
    return legacy.matchesVectorSpaceId(stored_vector_space_id);
}

/// Schedule a single transactional former-default-to-hosted sidecar migration owned by
/// `cache`. The old generation stays referenced until build() atomically
/// publishes the validated replacement. The exact semantic fallback can serve
/// the triggering request while this worker runs.
pub fn scheduleLegacyHostedMigration(
    io: std.Io,
    cache: *SearchCache,
    explorer: *Explorer,
    store: *Store,
    project_root: []const u8,
    data_dir: []const u8,
) MigrationSchedule {
    if (comptime builtin.os.tag == .windows) return .not_eligible;
    if (cio.posixGetenv(auto_migration_opt_out_env) != null) return .not_eligible;

    const config = semantic.Config.fromEnv();
    config.validate() catch return .not_eligible;
    var loaded = loadMetadata(io, std.heap.page_allocator, data_dir) catch return .not_eligible;
    defer loaded.deinit();
    if (!isLegacyHostedVectorSpace(&config, loaded.model, loaded.dimensions, loaded.vector_space_id)) {
        return .not_eligible;
    }

    cache.migration_mu.lock();
    defer cache.migration_mu.unlock();
    switch (cache.migrationState()) {
        .running => return .in_progress,
        .idle => {},
        .succeeded, .failed => return .not_eligible,
    }

    const allocator = std.heap.page_allocator;
    const job = createMigrationJob(io, cache, explorer, store, project_root, data_dir) catch return .not_eligible;

    cache.migration_state.store(@intFromEnum(MigrationState.running), .release);
    cache.migration_thread = std.Thread.spawn(.{}, MigrationJob.run, .{job}) catch {
        cache.migration_state.store(@intFromEnum(MigrationState.failed), .release);
        allocator.free(job.project_root);
        allocator.free(job.data_dir);
        allocator.destroy(job);
        return .not_eligible;
    };
    return .scheduled;
}

fn collectStaleDeltaChunks(
    allocator: std.mem.Allocator,
    explorer: *Explorer,
    store: *Store,
    build_files: []const CachedFileState,
    task_len: usize,
    delta_cards: *std.ArrayList([]u8),
    delta_records: *std.ArrayList(Record),
    owned_paths: *std.ArrayList([]u8),
) !void {
    const max_delta_cards = semantic.max_documents - 2;
    const base_bytes = task_len + semantic.calibration_text.len;
    var used_bytes = base_bytes;

    const paths = try cloneSortedPaths(explorer, allocator);
    defer {
        for (paths) |p| allocator.free(p);
        allocator.free(paths);
    }
    for (paths) |path| {
        if (delta_cards.items.len >= max_delta_cards) break;
        if (!semantic.isRemoteCandidatePathAllowed(path)) continue;
        if (findBuildFile(build_files, path)) |bf| {
            if (isFileUnchanged(explorer, store, bf)) continue;
        }
        const content = (explorer.getContent(path, allocator) catch null) orelse continue;
        defer allocator.free(content);
        if (content.len == 0) continue;
        var outline = (explorer.getOutline(path, allocator) catch null) orelse continue;
        defer outline.deinit();

        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);
        try owned_paths.append(allocator, owned_path);

        var cursor = ChunkCursor{ .content = content };
        var chunks_for_file: usize = 0;
        while (chunks_for_file < max_chunks_per_file and delta_cards.items.len < max_delta_cards) : (chunks_for_file += 1) {
            const chunk = cursor.next() orelse break;
            const card = try makeChunkCard(allocator, owned_path, @tagName(outline.language), chunk);
            if (used_bytes + card.len > semantic.max_batch_text_bytes) {
                allocator.free(card);
                return;
            }
            used_bytes += card.len;
            try delta_cards.append(allocator, card);
            errdefer _ = delta_cards.pop();
            try delta_records.append(allocator, .{
                .path = owned_path,
                .line_start = chunk.line_start,
                .line_end = chunk.line_end,
            });
        }
    }
}

fn searchLoaded(
    io: std.Io,
    allocator: std.mem.Allocator,
    explorer: *Explorer,
    store: *Store,
    loaded: *Loaded,
    task: []const u8,
    k: usize,
    load_ns: u64,
    cache_hit: bool,
) !SearchOutput {
    const is_stale = (try repositoryFingerprint(explorer, store, allocator)) != loaded.manifest;
    var delta_cards: std.ArrayList([]u8) = .empty;
    defer {
        for (delta_cards.items) |card| allocator.free(card);
        delta_cards.deinit(allocator);
    }
    var delta_records: std.ArrayList(Record) = .empty;
    defer delta_records.deinit(allocator);
    var owned_delta_paths: std.ArrayList([]u8) = .empty;
    defer {
        for (owned_delta_paths.items) |p| allocator.free(p);
        owned_delta_paths.deinit(allocator);
    }

    if (is_stale) {
        const build_files = loaded.build_files orelse return error.StaleAnnManifest;
        try validateStaleRecordLineRanges(explorer, store, loaded.records, build_files);
        try collectStaleDeltaChunks(
            allocator,
            explorer,
            store,
            build_files,
            task.len,
            &delta_cards,
            &delta_records,
            &owned_delta_paths,
        );
    }

    const embed_started = cio.nanoTimestamp();
    const query = try semantic.embedQueryCalibrationAndCardsRemote(io, allocator, task, delta_cards.items);
    defer allocator.free(query.vectors);
    const embed_ns = elapsedNs(embed_started);
    const expected_count = 2 + delta_cards.items.len;
    if (query.count != expected_count or query.dimensions != loaded.dimensions or !std.mem.eql(u8, query.model, loaded.model)) {
        return error.AnnQueryEmbeddingMismatch;
    }
    const query_vector = query.vectors[0..loaded.dimensions];
    const calibration_vector = query.vectors[loaded.dimensions..][0..loaded.dimensions];
    if (try semantic.cosineF32(calibration_vector, loaded.calibration) < semantic.calibration_min_cosine) {
        return error.AnnVectorSpaceCalibrationMismatch;
    }

    const search_started = cio.nanoTimestamp();
    const expanded_k = std.math.mul(usize, k, 4) catch k;
    const raw = try loaded.index.search(query_vector, @min(@max(k, expanded_k), loaded.records.len), allocator);
    defer allocator.free(raw);
    const search_ns = elapsedNs(search_started);

    var candidates: std.ArrayList(Hit) = .empty;
    defer candidates.deinit(allocator);
    for (raw) |result| {
        if (result.id >= loaded.records.len) return error.AnnRecordMappingMismatch;
        const record = loaded.records[result.id];
        if (!semantic.isRemoteCandidatePathAllowed(record.path)) continue;
        if (is_stale) {
            const build_files = loaded.build_files orelse continue;
            const bf = findBuildFile(build_files, record.path) orelse continue;
            if (!isFileUnchanged(explorer, store, bf)) continue;
        }
        try candidates.append(allocator, .{
            .path = record.path,
            .line_start = record.line_start,
            .line_end = record.line_end,
            .distance = result.distance,
        });
    }
    for (delta_records.items, 0..) |record, idx| {
        const chunk_vector = query.vectors[(2 + idx) * @as(usize, loaded.dimensions) ..][0..loaded.dimensions];
        const cosine = try semantic.cosineF32(query_vector, chunk_vector);
        try candidates.append(allocator, .{
            .path = record.path,
            .line_start = record.line_start,
            .line_end = record.line_end,
            .distance = 1.0 - cosine,
        });
    }
    if (delta_records.items.len > 0) {
        std.mem.sort(Hit, candidates.items, {}, struct {
            fn lt(_: void, a: Hit, b: Hit) bool {
                if (a.distance != b.distance) return a.distance < b.distance;
                return std.mem.lessThan(u8, a.path, b.path);
            }
        }.lt);
    }

    var hits: std.ArrayList(Hit) = .empty;
    var seen_paths = std.StringHashMap(void).init(allocator);
    defer seen_paths.deinit();
    errdefer {
        for (hits.items) |hit| allocator.free(hit.path);
        hits.deinit(allocator);
    }
    for (candidates.items) |candidate| {
        if (seen_paths.contains(candidate.path)) continue;
        try seen_paths.put(candidate.path, {});
        try hits.append(allocator, .{
            .path = try allocator.dupe(u8, candidate.path),
            .line_start = candidate.line_start,
            .line_end = candidate.line_end,
            .distance = candidate.distance,
        });
        if (hits.items.len == k) break;
    }
    return .{
        .hits = try hits.toOwnedSlice(allocator),
        .model = try allocator.dupe(u8, loaded.model),
        .dimensions = loaded.dimensions,
        .records = loaded.records.len,
        .index_bytes = try std.math.add(usize, loaded.storage.len, loaded.slab_bytes),
        .text_bytes_sent = query.text_bytes_sent,
        .documents_sent = expected_count,
        .retention = switch (query.retention) {
            .none_by_codedb_policy => .none_by_codedb_policy,
            .custom_endpoint_unverified => .custom_endpoint_unverified,
        },
        .load_ns = load_ns,
        .embed_ns = embed_ns,
        .search_ns = search_ns,
        .mmap_backed = loaded.index.isMmapBacked(),
        .cache_hit = cache_hit,
        .vector_space_id = loaded.vector_space_id,
    };
}

fn cachedGenerationCurrent(
    io: std.Io,
    allocator: std.mem.Allocator,
    cached: *const CachedLoaded,
    config: *const semantic.Config,
    store: *Store,
    data_dir: []const u8,
) !bool {
    const metadata_path = try sidecarPath(allocator, data_dir);
    defer allocator.free(metadata_path);
    const metadata_identity = fileIdentity(io, metadata_path) catch return false;
    if (!metadata_identity.eql(cached.metadata_identity)) return false;
    const slab_identity = fileIdentity(io, cached.loaded.slab_path) catch return false;
    if (!slab_identity.eql(cached.slab_identity)) return false;
    try validateLoadedConfig(config, &cached.loaded);
    // The cold/reload path validates Git HEAD, the exact repository content
    // fingerprint, and every record range together. Warm reuse is then keyed
    // by Store sequence: a checkout that changes indexed content advances the
    // watcher sequence, while a commit-only HEAD update with identical content
    // cannot invalidate the chunk mapping. This avoids a fork+exec on every
    // query without weakening content freshness.
    return store.currentSeq() == cached.store_seq;
}

fn loadValidatedGeneration(
    io: std.Io,
    persistent: std.mem.Allocator,
    temporary: std.mem.Allocator,
    config: *const semantic.Config,
    explorer: *Explorer,
    store: *Store,
    project_root: []const u8,
    data_dir: []const u8,
) !CachedLoaded {
    const metadata_path = try sidecarPath(temporary, data_dir);
    defer temporary.free(metadata_path);
    const metadata_before = fileIdentity(io, metadata_path) catch |err| switch (err) {
        error.FileNotFound => return error.AnnIndexMissing,
        else => return err,
    };

    var loaded = try loadMetadata(io, persistent, data_dir);
    errdefer loaded.deinit();
    try validateLoadedConfig(config, &loaded);
    const head_before = try git_mod.getGitHead(project_root, temporary);
    const seq_before = store.currentSeq();
    try validateGenerationFreshness(temporary, explorer, store, head_before, &loaded);
    if (store.currentSeq() != seq_before) return error.StaleAnnManifest;

    const slab_before = fileIdentity(io, loaded.slab_path) catch |err| switch (err) {
        error.FileNotFound => return error.InvalidAnnSidecar,
        else => return err,
    };
    try loaded.loadGraph();
    const metadata_after = fileIdentity(io, metadata_path) catch |err| switch (err) {
        error.FileNotFound => return error.AnnSidecarChangedDuringLoad,
        else => return err,
    };
    const slab_after = fileIdentity(io, loaded.slab_path) catch |err| switch (err) {
        error.FileNotFound => return error.AnnSidecarChangedDuringLoad,
        else => return err,
    };
    if (!metadata_before.eql(metadata_after) or !slab_before.eql(slab_after)) return error.AnnSidecarChangedDuringLoad;
    const head_after = try git_mod.getGitHead(project_root, temporary);
    if (!headsEqual(head_before, head_after)) return error.StaleAnnGitHead;
    const seq_after = store.currentSeq();
    if (seq_after != seq_before) return error.StaleAnnManifest;

    return .{
        .loaded = loaded,
        .metadata_identity = metadata_after,
        .slab_identity = slab_after,
        .store_seq = seq_after,
    };
}

/// Reuse a fully validated mmap generation for warm MCP queries. The fast
/// path still checks both sidecar file identities, repository sequence, model,
/// dimensions, and vector-space identity before any remote query embedding is
/// issued. Git HEAD, content fingerprint, and record ranges are revalidated
/// transactionally whenever that warm identity changes.
pub fn searchCached(
    io: std.Io,
    allocator: std.mem.Allocator,
    cache: *SearchCache,
    explorer: *Explorer,
    store: *Store,
    project_root: []const u8,
    data_dir: []const u8,
    task: []const u8,
    k: usize,
) !SearchOutput {
    const config = semantic.Config.fromEnv();
    try config.validate();
    const load_started = cio.nanoTimestamp();

    cache.mu.lockShared();
    if (cache.cached) |*cached| {
        const current = cachedGenerationCurrent(io, allocator, cached, &config, store, data_dir) catch |err| {
            cache.mu.unlockShared();
            return err;
        };
        if (current) {
            defer cache.mu.unlockShared();
            return searchLoaded(io, allocator, explorer, store, &cached.loaded, task, k, elapsedNs(load_started), true);
        }
    }
    cache.mu.unlockShared();

    cache.mu.lock();
    defer cache.mu.unlock();
    // Another concurrent cold request may have installed the generation while
    // this request waited for the exclusive lock.
    if (cache.cached) |*cached| {
        if (try cachedGenerationCurrent(io, allocator, cached, &config, store, data_dir)) {
            return searchLoaded(io, allocator, explorer, store, &cached.loaded, task, k, elapsedNs(load_started), true);
        }
    }

    const replacement = try loadValidatedGeneration(io, cache.allocator, allocator, &config, explorer, store, project_root, data_dir);
    if (cache.cached) |*old| old.loaded.deinit();
    cache.cached = replacement;
    return searchLoaded(io, allocator, explorer, store, &cache.cached.?.loaded, task, k, elapsedNs(load_started), false);
}

pub fn search(
    io: std.Io,
    allocator: std.mem.Allocator,
    explorer: *Explorer,
    store: *Store,
    project_root: []const u8,
    data_dir: []const u8,
    task: []const u8,
    k: usize,
) !SearchOutput {
    const config = semantic.Config.fromEnv();
    try config.validate();
    const load_started = cio.nanoTimestamp();
    var loaded = try loadMetadata(io, allocator, data_dir);
    defer loaded.deinit();

    try validateLoadedConfig(&config, &loaded);
    const current_head = try git_mod.getGitHead(project_root, allocator);
    // Metadata is attacker-controlled local input. Validate the entire mapping
    // while the index is still empty so a failure remains transactional and no
    // forged line can reach rendering arithmetic.
    try validateGenerationFreshness(allocator, explorer, store, current_head, &loaded);
    try loaded.loadGraph();
    const load_ns = elapsedNs(load_started);
    return searchLoaded(io, allocator, explorer, store, &loaded, task, k, load_ns, false);
}

test "semantic ANN sidecar accepts hosted 512D and migrates exact prior hosted spaces" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = path_buf[0..try tmp.dir.realPathFile(io, ".", &path_buf)];

    var source = ann.Index.init(testing.allocator, ann.default_dimensions, .{ .seed = 19 });
    defer source.deinit();
    var a: [ann.default_dimensions]f32 = @splat(0);
    var b: [ann.default_dimensions]f32 = @splat(0);
    a[0] = 1;
    b[1] = 1;
    _ = try source.insert(&a);
    _ = try source.insert(&b);
    const slab_name = "semantic-chunks-v3-a-b-c.hmls";
    const slab_path = try slabPath(testing.allocator, dir_path, slab_name);
    defer testing.allocator.free(slab_path);
    try source.writeSlabs(slab_path);
    var calibration: [ann.default_dimensions]f32 = @splat(0);
    calibration[3] = 1;
    const config = semantic.Config{
        .url = semantic.default_url,
        .model = semantic.default_model,
        .token = null,
        .dimensions = ann.default_dimensions,
        .timeout_ms = semantic.default_timeout_ms,
    };
    const vector_space_id = config.vectorSpaceId();
    _ = try writeMetadata(io, testing.allocator, dir_path, semantic.default_model, ann.default_dimensions, 1234, vector_space_id, &calibration, null, slab_name, &.{
        .{ .path = "src/a.zig", .line_start = 1, .line_end = 2 },
        .{ .path = "src/b.zig", .line_start = 8, .line_end = 12 },
    });

    var restored = try load(io, testing.allocator, dir_path);
    defer restored.deinit();
    try testing.expect(restored.index.isMmapBacked());
    try testing.expectEqual(@as(usize, 2), restored.records.len);
    try testing.expectEqualStrings("src/b.zig", restored.records[1].path);
    try testing.expectEqual(@as(u32, 8), restored.records[1].line_start);
    try testing.expectEqual(@as(u64, 1234), restored.manifest);
    try testing.expectEqual(vector_space_id, restored.vector_space_id);
    try testing.expectEqual(ann.default_dimensions, restored.dimensions);
    try testing.expectEqualStrings(semantic.default_model, restored.model);
    try testing.expectEqualSlices(f32, &calibration, restored.calibration);
    try validateLoadedConfig(&config, &restored);
    var legacy_config = config;
    legacy_config.model = semantic.legacy_qwen_model;
    try testing.expectError(error.AnnModelMismatch, validateLoadedConfig(&legacy_config, &restored));
    try testing.expect(isLegacyHostedVectorSpace(
        &config,
        semantic.legacy_qwen_model,
        semantic.default_dimensions,
        legacy_config.vectorSpaceId(),
    ));
    var jina_config = config;
    jina_config.model = semantic.jina_model;
    try testing.expect(isLegacyHostedVectorSpace(
        &config,
        semantic.jina_model,
        semantic.default_dimensions,
        jina_config.vectorSpaceId(),
    ));
    try testing.expect(!isLegacyHostedVectorSpace(
        &config,
        semantic.default_model,
        semantic.default_dimensions,
        config.vectorSpaceId(),
    ));
    var custom_current = config;
    custom_current.url = "http://localhost:8080/v1/embeddings";
    try testing.expect(!isLegacyHostedVectorSpace(
        &custom_current,
        semantic.legacy_qwen_model,
        semantic.default_dimensions,
        legacy_config.vectorSpaceId(),
    ));
    try testing.expect(!isLegacyHostedVectorSpace(
        &config,
        semantic.legacy_qwen_model,
        semantic.default_dimensions,
        legacy_config.vectorSpaceId() ^ 1,
    ));
    const results = try restored.index.search(&b, 1, testing.allocator);
    defer testing.allocator.free(results);
    try testing.expectEqual(@as(u32, 1), results[0].id);

    if (builtin.os.tag != .windows and
        std.mem.eql(u8, config.url, semantic.default_url) and
        std.mem.eql(u8, config.model, semantic.default_model))
    {
        // Repoint metadata at the exact former hosted default, then prove that
        // an already-running migration is recognized without launching a
        // duplicate worker or touching the Explorer/Store arguments.
        _ = try writeMetadata(
            io,
            testing.allocator,
            dir_path,
            semantic.jina_model,
            semantic.default_dimensions,
            1234,
            jina_config.vectorSpaceId(),
            &calibration,
            null,
            slab_name,
            &.{
                .{ .path = "src/a.zig", .line_start = 1, .line_end = 2 },
                .{ .path = "src/b.zig", .line_start = 8, .line_end = 12 },
            },
        );
        var cache = SearchCache.init(testing.allocator);
        defer cache.deinit();
        cache.migration_state.store(@intFromEnum(MigrationState.running), .release);
        var explorer = Explorer.init(testing.allocator, 1024);
        defer explorer.deinit();
        var store = Store.init(testing.allocator);
        defer store.deinit();
        try testing.expectEqual(
            MigrationSchedule.in_progress,
            scheduleLegacyHostedMigration(io, &cache, &explorer, &store, dir_path, dir_path),
        );
        try testing.expect(cache.migration_thread == null);
    }
}

test "semantic search cache joins its migration worker before destruction" {
    const testing = std.testing;
    var finished = std.atomic.Value(bool).init(false);
    var cache = SearchCache.init(testing.allocator);
    cache.migration_state.store(@intFromEnum(MigrationState.running), .release);
    cache.migration_thread = try std.Thread.spawn(.{}, struct {
        fn run(done: *std.atomic.Value(bool)) void {
            cio.sleepMs(20);
            done.store(true, .release);
        }
    }.run, .{&finished});
    cache.deinit();
    try testing.expect(finished.load(.acquire));
}

test "semantic repository fingerprint survives cold scan snapshot reload" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "src");
    var source = try tmp.dir.createFile(io, "src/live.zig", .{});
    try source.writeStreamingAll(io, "pub fn live() void {}\n");
    source.close(io);
    // Stat-only/non-indexed Store entries must not perturb a manifest of the
    // live parsed outline set.
    var empty = try tmp.dir.createFile(io, "empty.bin", .{});
    empty.close(io);

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPathFile(io, ".", &root_buf)];
    var first_explorer = Explorer.init(testing.allocator, 1024 * 1024);
    defer first_explorer.deinit();
    var first_store = Store.init(testing.allocator);
    defer first_store.deinit();
    try watcher.initialScan(io, &first_store, &first_explorer, root, testing.allocator, true);
    const before = try repositoryFingerprint(&first_explorer, &first_store, testing.allocator);

    const snapshot_path = try std.fmt.allocPrint(testing.allocator, "{s}/roundtrip.snapshot", .{root});
    defer testing.allocator.free(snapshot_path);
    try snapshot_mod.writeSnapshot(io, &first_explorer, root, snapshot_path, testing.allocator);

    var restored_explorer = Explorer.init(testing.allocator, 1024 * 1024);
    defer restored_explorer.deinit();
    var restored_store = Store.init(testing.allocator);
    defer restored_store.deinit();
    try testing.expect(snapshot_mod.loadSnapshot(io, snapshot_path, &restored_explorer, &restored_store, testing.allocator));
    try testing.expectEqual(before, try repositoryFingerprint(&restored_explorer, &restored_store, testing.allocator));
}

test "semantic ANN sidecar refuses sensitive record mappings" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = path_buf[0..try tmp.dir.realPathFile(io, ".", &path_buf)];
    var source = ann.Index.init(testing.allocator, 64, .{});
    defer source.deinit();
    var vector: [64]f32 = @splat(0);
    vector[0] = 1;
    _ = try source.insert(&vector);
    var calibration: [64]f32 = @splat(0);
    calibration[0] = 1;
    try testing.expectError(
        error.InvalidAnnRecordPath,
        writeMetadata(io, testing.allocator, dir_path, "test-model", 64, 0, 1, &calibration, null, "semantic-chunks-v3-a.hmls", &.{.{ .path = ".env", .line_start = 1, .line_end = 1 }}),
    );
    try testing.expectError(
        error.InvalidAnnRecordPath,
        writeMetadata(io, testing.allocator, dir_path, "test-model", 64, 0, 1, &calibration, null, "semantic-chunks-v3-a.hmls", &.{.{ .path = "PRIVATE_KEY.PEM", .line_start = 1, .line_end = 1 }}),
    );
}

test "semantic ANN metadata rejects traversal and oversized record counts before allocation" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = path_buf[0..try tmp.dir.realPathFile(io, ".", &path_buf)];
    var calibration: [64]f32 = @splat(0);
    calibration[0] = 1;
    try testing.expectError(
        error.InvalidAnnSlabName,
        writeMetadata(io, testing.allocator, dir_path, "test-model", 64, 0, 1, &calibration, null, "../outside.hmls", &.{.{ .path = "src/a.zig", .line_start = 1, .line_end = 1 }}),
    );

    var index = ann.Index.init(testing.allocator, 64, .{});
    defer index.deinit();
    _ = try index.insert(&calibration);
    const slab_name = "semantic-chunks-v3-c0a7-9aa4d.hmls";
    const slab_path = try slabPath(testing.allocator, dir_path, slab_name);
    defer testing.allocator.free(slab_path);
    try index.writeSlabs(slab_path);
    _ = try writeMetadata(io, testing.allocator, dir_path, "test-model", 64, 0, 1, &calibration, null, slab_name, &.{.{ .path = "src/a.zig", .line_start = 1, .line_end = 1 }});

    const metadata_path = try sidecarPath(testing.allocator, dir_path);
    defer testing.allocator.free(metadata_path);
    var metadata_file = try std.Io.Dir.cwd().openFile(io, metadata_path, .{ .mode = .read_write });
    defer metadata_file.close(io);
    var forged_count: [4]u8 = undefined;
    std.mem.writeInt(u32, &forged_count, max_records, .little);
    try metadata_file.writePositionalAll(io, &forged_count, 12);
    try metadata_file.sync(io);
    try testing.expectError(error.TruncatedAnnSidecar, load(io, testing.allocator, dir_path));
}

test "semantic ANN rejects forged overflow line ranges before mmap or hits" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = path_buf[0..try tmp.dir.realPathFile(io, ".", &path_buf)];

    const source_path = "src/overflow.zig";
    const content = "pub fn bounded() void {}\n";
    var explorer = Explorer.init(testing.allocator, 1024 * 1024);
    defer explorer.deinit();
    try explorer.indexFile(source_path, content);
    var store = Store.init(testing.allocator);
    defer store.deinit();
    _ = try store.recordSnapshot(source_path, content.len, std.hash.Wyhash.hash(0, content));

    const config = semantic.Config.fromEnv();
    try config.validate();
    const calibration = try testing.allocator.alloc(f32, config.dimensions);
    defer testing.allocator.free(calibration);
    @memset(calibration, 0);
    calibration[0] = 1;

    var index = ann.Index.init(testing.allocator, config.dimensions, .{});
    defer index.deinit();
    _ = try index.insert(calibration);
    const slab_name = "semantic-chunks-v3-dead-beef.hmls";
    const slab_path = try slabPath(testing.allocator, dir_path, slab_name);
    defer testing.allocator.free(slab_path);
    try index.writeSlabs(slab_path);
    const manifest = try repositoryFingerprint(&explorer, &store, testing.allocator);
    const current_head = try git_mod.getGitHead(dir_path, testing.allocator);
    _ = try writeMetadata(
        io,
        testing.allocator,
        dir_path,
        config.model,
        config.dimensions,
        manifest,
        config.vectorSpaceId(),
        calibration,
        current_head,
        slab_name,
        &.{.{ .path = source_path, .line_start = 1, .line_end = 1 }},
    );

    const metadata_path = try sidecarPath(testing.allocator, dir_path);
    defer testing.allocator.free(metadata_path);
    const metadata = try std.Io.Dir.cwd().readFileAlloc(io, metadata_path, testing.allocator, .limited(max_metadata_bytes));
    defer testing.allocator.free(metadata);
    const record_path_offset = std.mem.indexOf(u8, metadata, source_path) orelse return error.MissingFixtureRecord;
    const line_offset = record_path_offset + source_path.len;
    var forged_lines: [8]u8 = undefined;
    std.mem.writeInt(u32, forged_lines[0..4], std.math.maxInt(u32), .little);
    std.mem.writeInt(u32, forged_lines[4..8], std.math.maxInt(u32), .little);
    var metadata_file = try std.Io.Dir.cwd().openFile(io, metadata_path, .{ .mode = .read_write });
    try metadata_file.writePositionalAll(io, &forged_lines, line_offset);
    try metadata_file.sync(io);
    metadata_file.close(io);

    // Loading the raw metadata succeeds because the range is structurally
    // ordered. Live-outline validation must reject it while the graph remains
    // unattached, so neither safe nor ReleaseFast can reach line+2 wrapping.
    var loaded = try loadMetadata(io, testing.allocator, dir_path);
    defer loaded.deinit();
    try testing.expectError(error.InvalidAnnRecordPath, validateRecordLineRanges(&explorer, loaded.records));
    try testing.expect(!loaded.index.isMmapBacked());
    try testing.expectEqual(@as(usize, 0), loaded.index.len());

    try testing.expectError(
        error.InvalidAnnRecordPath,
        search(io, testing.allocator, &explorer, &store, dir_path, dir_path, "find bounded implementation", 5),
    );
}

test "semantic ANN metadata and data directory use private permissions" {
    if (builtin.os.tag == .windows) return;
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = path_buf[0..try tmp.dir.realPathFile(io, ".", &path_buf)];
    try secureDataDir(io, dir_path);
    var calibration: [64]f32 = @splat(0);
    calibration[0] = 1;
    const slab_name = "semantic-chunks-v3-fee1-dead.hmls";
    const slab_path = try slabPath(testing.allocator, dir_path, slab_name);
    defer testing.allocator.free(slab_path);
    var source = ann.Index.init(testing.allocator, 64, .{});
    defer source.deinit();
    _ = try source.insert(&calibration);
    try source.writeSlabs(slab_path);
    _ = try writeMetadata(io, testing.allocator, dir_path, "test-model", 64, 0, 1, &calibration, null, slab_name, &.{.{ .path = "src/a.zig", .line_start = 1, .line_end = 1 }});
    const metadata_path = try sidecarPath(testing.allocator, dir_path);
    defer testing.allocator.free(metadata_path);
    var metadata_file = try std.Io.Dir.cwd().openFile(io, metadata_path, .{});
    defer metadata_file.close(io);
    const metadata_stat = try metadata_file.stat(io);
    try testing.expectEqual(@as(std.posix.mode_t, 0o600), metadata_stat.permissions.toMode() & 0o777);
    var slab_file = try std.Io.Dir.cwd().openFile(io, slab_path, .{});
    defer slab_file.close(io);
    const slab_stat = try slab_file.stat(io);
    try testing.expectEqual(@as(std.posix.mode_t, 0o600), slab_stat.permissions.toMode() & 0o777);
    var data_dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer data_dir.close(io);
    const dir_stat = try data_dir.stat(io);
    try testing.expectEqual(@as(std.posix.mode_t, 0o700), dir_stat.permissions.toMode() & 0o777);
}

test "semantic ANN replacement removes only the previously referenced slab" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = path_buf[0..try tmp.dir.realPathFile(io, ".", &path_buf)];
    const old_name = "semantic-chunks-v3-aaa-bbb.hmls";
    const new_name = "semantic-chunks-v3-ccc-ddd.hmls";
    const old_path = try slabPath(testing.allocator, dir_path, old_name);
    defer testing.allocator.free(old_path);
    const new_path = try slabPath(testing.allocator, dir_path, new_name);
    defer testing.allocator.free(new_path);
    var old_file = try std.Io.Dir.cwd().createFile(io, old_path, .{});
    old_file.close(io);
    var new_file = try std.Io.Dir.cwd().createFile(io, new_path, .{});
    new_file.close(io);
    var calibration: [64]f32 = @splat(0);
    calibration[0] = 1;
    _ = try writeMetadata(io, testing.allocator, dir_path, "test-model", 64, 0, 1, &calibration, null, old_name, &.{.{ .path = "src/a.zig", .line_start = 1, .line_end = 1 }});
    const previous = (try currentSlabName(io, testing.allocator, dir_path)).?;
    defer testing.allocator.free(previous);
    try testing.expectEqualStrings(old_name, previous);
    _ = try writeMetadata(io, testing.allocator, dir_path, "test-model", 64, 0, 1, &calibration, null, new_name, &.{.{ .path = "src/a.zig", .line_start = 1, .line_end = 1 }});
    deleteReplacedSlab(io, testing.allocator, dir_path, previous, new_name);
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, old_path, .{}));
    try std.Io.Dir.cwd().access(io, new_path, .{});
}

test "semantic ANN wave uses the hosted 100-item batch boundary" {
    // Hosted batches carry 100 items with eight in flight (800-item waves).
    // Keep the override for custom endpoints, but make an accidental default
    // drift a release-gating test failure.
    try std.testing.expectEqual(@as(usize, 8), default_parallel_batches);
    try std.testing.expectEqual(@as(usize, 100), semantic.max_index_documents);
    try std.testing.expectEqual(@as(usize, 800), default_parallel_batches * semantic.max_index_documents);
    try std.testing.expectEqual(@as(usize, 1), embeddingBatchCount(semantic.max_index_documents));
    try std.testing.expectEqual(@as(usize, 2), embeddingBatchCount(semantic.max_index_documents + 1));
    try std.testing.expectEqual(
        max_parallel_batches,
        embeddingBatchCount(max_parallel_batches * semantic.max_index_documents),
    );
}

test "semantic ANN rejects stale content before mmaping the graph" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = path_buf[0..try tmp.dir.realPathFile(io, ".", &path_buf)];

    const config = semantic.Config.fromEnv();
    try config.validate();
    const calibration = try testing.allocator.alloc(f32, config.dimensions);
    defer testing.allocator.free(calibration);
    @memset(calibration, 0);
    calibration[0] = 1;
    const slab_name = "semantic-chunks-v3-dead-bad.hmls";
    const bad_slab_path = try slabPath(testing.allocator, dir_path, slab_name);
    defer testing.allocator.free(bad_slab_path);
    var bad_slab = try std.Io.Dir.cwd().createFile(io, bad_slab_path, .{ .permissions = privateFilePermissions() });
    try bad_slab.writeStreamingAll(io, "x");
    try bad_slab.sync(io);
    bad_slab.close(io);
    const current_head = try git_mod.getGitHead(dir_path, testing.allocator);
    _ = try writeMetadata(
        io,
        testing.allocator,
        dir_path,
        config.model,
        config.dimensions,
        std.math.maxInt(u64),
        config.vectorSpaceId(),
        calibration,
        current_head,
        slab_name,
        &.{.{ .path = "src/a.zig", .line_start = 1, .line_end = 1 }},
    );

    var explorer = Explorer.init(testing.allocator, 1024 * 1024);
    defer explorer.deinit();
    const content = "pub fn alpha() void {}\n";
    try explorer.indexFile("src/a.zig", content);
    var store = Store.init(testing.allocator);
    defer store.deinit();
    _ = try store.recordSnapshot("src/a.zig", content.len, std.hash.Wyhash.hash(0, content));
    try testing.expectError(
        error.StaleAnnManifest,
        search(io, testing.allocator, &explorer, &store, dir_path, dir_path, "find alpha implementation", 5),
    );
}

test "semantic ANN warm generation invalidates on repository sequence and sidecar identity" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "src");
    var source_file = try tmp.dir.createFile(io, "src/a.zig", .{});
    const content = "pub fn alpha() void {}\n";
    try source_file.writeStreamingAll(io, content);
    source_file.close(io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = path_buf[0..try tmp.dir.realPathFile(io, ".", &path_buf)];
    var explorer = Explorer.init(testing.allocator, 1024 * 1024);
    defer explorer.deinit();
    try explorer.setRoot(io, dir_path);
    try explorer.indexFile("src/a.zig", content);
    var store = Store.init(testing.allocator);
    defer store.deinit();
    _ = try store.recordSnapshot("src/a.zig", content.len, std.hash.Wyhash.hash(0, content));

    const config = semantic.Config.fromEnv();
    try config.validate();
    const calibration = try testing.allocator.alloc(f32, config.dimensions);
    defer testing.allocator.free(calibration);
    @memset(calibration, 0);
    calibration[0] = 1;
    var source = ann.Index.init(testing.allocator, config.dimensions, .{ .seed = 41 });
    defer source.deinit();
    _ = try source.insert(calibration);
    const slab_name = "semantic-chunks-v3-ca-ce.hmls";
    const slab_path = try slabPath(testing.allocator, dir_path, slab_name);
    defer testing.allocator.free(slab_path);
    try source.writeSlabs(slab_path);
    const manifest = try repositoryFingerprint(&explorer, &store, testing.allocator);
    const current_head = try git_mod.getGitHead(dir_path, testing.allocator);
    _ = try writeMetadata(
        io,
        testing.allocator,
        dir_path,
        config.model,
        config.dimensions,
        manifest,
        config.vectorSpaceId(),
        calibration,
        current_head,
        slab_name,
        &.{.{ .path = "src/a.zig", .line_start = 1, .line_end = 1 }},
    );

    const cached = try loadValidatedGeneration(
        io,
        testing.allocator,
        testing.allocator,
        &config,
        &explorer,
        &store,
        dir_path,
        dir_path,
    );
    var cache = SearchCache.init(testing.allocator);
    defer cache.deinit();
    cache.cached = cached;
    try testing.expect(try cachedGenerationCurrent(io, testing.allocator, &cache.cached.?, &config, &store, dir_path));

    // Even a content-equivalent Store update must force full freshness
    // revalidation before this generation can be reused.
    _ = try store.recordSnapshot("src/a.zig", content.len, std.hash.Wyhash.hash(0, content));
    try testing.expect(!try cachedGenerationCurrent(io, testing.allocator, &cache.cached.?, &config, &store, dir_path));

    cache.cached.?.store_seq = store.currentSeq();
    const metadata_path = try sidecarPath(testing.allocator, dir_path);
    defer testing.allocator.free(metadata_path);
    var metadata_file = try std.Io.Dir.cwd().openFile(io, metadata_path, .{ .mode = .read_write });
    defer metadata_file.close(io);
    try metadata_file.writePositionalAll(io, "X", 0);
    try metadata_file.sync(io);
    try testing.expect(!try cachedGenerationCurrent(io, testing.allocator, &cache.cached.?, &config, &store, dir_path));
    try testing.expectError(
        error.InvalidAnnSidecar,
        searchCached(io, testing.allocator, &cache, &explorer, &store, dir_path, dir_path, "find alpha", 1),
    );
    // Failed replacement is transactional: the previously validated mapping
    // remains owned and can be retired safely on cache destruction.
    try testing.expect(cache.cached != null);
    try testing.expect(cache.cached.?.loaded.index.isMmapBacked());
}

test "semantic build live fingerprint catches unreconciled repository edits" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "src");
    var source = try tmp.dir.createFile(io, "src/live.zig", .{});
    try source.writeStreamingAll(io, "pub fn before() void {}\n");
    source.close(io);
    var ignored = try tmp.dir.createFile(io, ".env", .{});
    try ignored.writeStreamingAll(io, "TEST_ONLY_NOT_A_SECRET=1\n");
    ignored.close(io);

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPathFile(io, ".", &root_buf)];
    var explorer = Explorer.init(testing.allocator, 1024 * 1024);
    defer explorer.deinit();
    try explorer.setRoot(io, root);
    var store = Store.init(testing.allocator);
    defer store.deinit();
    try watcher.initialScan(io, &store, &explorer, root, testing.allocator, true);

    const paths = try cloneSortedPaths(&explorer, testing.allocator);
    defer {
        for (paths) |path| testing.allocator.free(path);
        testing.allocator.free(paths);
    }
    const indexed = try store.semanticContentFingerprintForPaths(paths);
    try testing.expectEqual(indexed, try watcher.liveIndexedContentFingerprint(io, explorer.root_dir.?, testing.allocator));

    var ignored_changed = try tmp.dir.createFile(io, ".env", .{ .truncate = true });
    try ignored_changed.writeStreamingAll(io, "TEST_ONLY_NOT_A_SECRET=2\n");
    ignored_changed.close(io);
    try testing.expectEqual(indexed, try watcher.liveIndexedContentFingerprint(io, explorer.root_dir.?, testing.allocator));

    var changed = try tmp.dir.createFile(io, "src/live.zig", .{ .truncate = true });
    try changed.writeStreamingAll(io, "pub fn after() void {}\n");
    changed.close(io);
    try testing.expect(indexed != try watcher.liveIndexedContentFingerprint(io, explorer.root_dir.?, testing.allocator));
}

test "issue-775: semantic ANN tolerates stale index on file edits and reuses cached embeddings on rebuild" {
    const testing = std.testing;
    const io = testing.io;

    const EnvGuard = struct {
        name: []const u8,
        had_prev: bool,
        prev_len: usize,
        prev: [1024]u8,

        fn save(name: []const u8) @This() {
            var g = @This(){ .name = name, .had_prev = false, .prev_len = 0, .prev = undefined };
            if (cio.posixGetenv(name)) |val| {
                if (val.len <= g.prev.len) {
                    @memcpy(g.prev[0..val.len], val);
                    g.prev_len = val.len;
                    g.had_prev = true;
                }
            }
            return g;
        }

        fn restore(self: *const @This()) void {
            if (self.had_prev) cio.posixSetenv(self.name, self.prev[0..self.prev_len]) else cio.posixUnsetenv(self.name);
        }
    };

    const g_url = EnvGuard.save("CODEDB_EMBEDDINGS_URL");
    defer g_url.restore();
    const g_model = EnvGuard.save("CODEDB_EMBEDDINGS_MODEL");
    defer g_model.restore();
    const g_token = EnvGuard.save("CODEDB_EMBEDDINGS_TOKEN");
    defer g_token.restore();
    const g_dims = EnvGuard.save("CODEDB_EMBEDDINGS_DIMENSIONS");
    defer g_dims.restore();
    const g_timeout = EnvGuard.save("CODEDB_EMBEDDINGS_TIMEOUT_MS");
    defer g_timeout.restore();
    const g_space = EnvGuard.save("CODEDB_EMBEDDINGS_SPACE_ID");
    defer g_space.restore();

    const SemanticMockServer = struct {
        server: *std.Io.net.Server,
        expected_requests: usize,
        last_batch_inputs: usize = 0,
        failure: ?anyerror = null,

        fn contentLength(headers: []const u8) !usize {
            var lines = std.mem.splitSequence(u8, headers, "\r\n");
            while (lines.next()) |line| {
                const prefix = "content-length:";
                if (line.len >= prefix.len and std.ascii.eqlIgnoreCase(line[0..prefix.len], prefix)) {
                    return std.fmt.parseInt(usize, std.mem.trim(u8, line[prefix.len..], " \t"), 10);
                }
            }
            return error.MissingContentLength;
        }

        fn activeDimForText(text: []const u8) usize {
            if (std.mem.eql(u8, text, semantic.calibration_text)) return 0;
            if (std.mem.indexOf(u8, text, "alpha") != null) return 1;
            if (std.mem.indexOf(u8, text, "beta_v1") != null) return 2;
            if (std.mem.indexOf(u8, text, "beta_v2") != null) return 3;
            if (std.mem.indexOf(u8, text, "gamma") != null) return 4;
            return 5;
        }

        fn run(self: *@This()) void {
            var served: usize = 0;
            var head_probes: usize = 0;
            while (served < self.expected_requests) {
                const stream = self.server.accept(io) catch |err| {
                    self.failure = err;
                    return;
                };
                defer stream.close(io);

                var req_buf: [65536]u8 = undefined;
                var req_len: usize = 0;
                var is_head_probe = false;
                var body_slice: []const u8 = &.{};
                while (req_len < req_buf.len) {
                    var iov = [1][]u8{req_buf[req_len..]};
                    const read_res = stream.readWithControl(io, &iov, &.{}) catch |err| {
                        self.failure = err;
                        return;
                    };
                    const n = read_res.data_len;
                    if (n == 0) break;
                    req_len += n;
                    const header_end = std.mem.indexOf(u8, req_buf[0..req_len], "\r\n\r\n") orelse continue;
                    if (std.mem.startsWith(u8, req_buf[0..header_end], "HEAD / HTTP/1.1\r\n")) {
                        is_head_probe = true;
                        break;
                    }
                    const content_len = contentLength(req_buf[0..header_end]) catch |err| {
                        self.failure = err;
                        return;
                    };
                    if (req_len >= header_end + 4 + content_len) {
                        body_slice = req_buf[header_end + 4 .. header_end + 4 + content_len];
                        break;
                    }
                }
                if (is_head_probe) {
                    head_probes += 1;
                    if (head_probes > 8) {
                        self.failure = error.TooManyHeadProbes;
                        return;
                    }
                    continue;
                }

                var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                defer arena.deinit();
                const a = arena.allocator();
                const Req = struct { input: []const []const u8 };
                const parsed = std.json.parseFromSliceLeaky(Req, a, body_slice, .{ .ignore_unknown_fields = true }) catch |err| {
                    self.failure = err;
                    return;
                };
                self.last_batch_inputs = parsed.input.len;

                var resp: std.ArrayList(u8) = .empty;
                const w = cio.listWriter(&resp, a);
                w.writeAll("{\"model\":\"mock-model\",\"data\":[") catch return;
                for (parsed.input, 0..) |inp, idx| {
                    if (idx > 0) w.writeByte(',') catch return;
                    w.print("{{\"index\":{d},\"embedding\":[", .{idx}) catch return;
                    const hot = activeDimForText(inp);
                    for (0..64) |d| {
                        if (d > 0) w.writeByte(',') catch return;
                        w.writeAll(if (d == hot) "1" else "0") catch return;
                    }
                    w.writeAll("]}") catch return;
                }
                w.writeAll("]}") catch return;

                var writer_buf: [4096]u8 = undefined;
                var writer = stream.writer(io, &writer_buf);
                var header_buf: [256]u8 = undefined;
                const header = std.fmt.bufPrint(
                    &header_buf,
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
                    .{resp.items.len},
                ) catch return;
                writer.interface.writeAll(header) catch return;
                writer.interface.writeAll(resp.items) catch return;
                writer.interface.flush() catch return;
                served += 1;
            }
        }
    };

    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try addr.listen(io, .{ .reuse_address = true, .mode = .stream, .protocol = .tcp });
    defer server.deinit(io);
    var url_buf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/v1/embeddings", .{server.socket.address.getPort()});
    cio.posixSetenv("CODEDB_EMBEDDINGS_URL", url);
    cio.posixSetenv("CODEDB_EMBEDDINGS_MODEL", "mock-model");
    cio.posixSetenv("CODEDB_EMBEDDINGS_TOKEN", "mock-token");
    cio.posixSetenv("CODEDB_EMBEDDINGS_DIMENSIONS", "64");
    cio.posixSetenv("CODEDB_EMBEDDINGS_TIMEOUT_MS", "2000");
    cio.posixUnsetenv("CODEDB_EMBEDDINGS_SPACE_ID");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.createDirPath(io, "data");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/alpha.zig", .data = "pub fn alpha() void {}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/beta.zig", .data = "pub fn beta_v1() void {}\n" });

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_path = root_buf[0..try tmp.dir.realPathFile(io, ".", &root_buf)];
    var data_buf: [std.fs.max_path_bytes]u8 = undefined;
    const data_path = data_buf[0..try tmp.dir.realPathFile(io, "data", &data_buf)];

    var explorer = Explorer.init(testing.allocator, 1024 * 1024);
    defer explorer.deinit();
    try explorer.setRoot(io, root_path);
    var store = Store.init(testing.allocator);
    defer store.deinit();
    try watcher.initialScan(io, &store, &explorer, root_path, testing.allocator, true);

    // 1. Initial build: 1 calibration request + 1 wave request (2 chunks).
    {
        var mock = SemanticMockServer{ .server = &server, .expected_requests = 2 };
        const thread = try std.Thread.spawn(.{}, SemanticMockServer.run, .{&mock});
        const stats1 = build(io, testing.allocator, &explorer, &store, root_path, data_path) catch |err| {
            thread.join();
            return err;
        };
        thread.join();
        if (mock.failure) |err| return err;
        try testing.expectEqual(@as(usize, 2), stats1.records);
        try testing.expectEqual(@as(usize, 0), stats1.reused_records);
        try testing.expectEqual(@as(usize, 2), mock.last_batch_inputs);
    }

    // 2. Edit src/beta.zig and add src/gamma.zig WITHOUT rebuilding the ANN index.
    const beta_v2_src = "pub fn beta_v2() void {}\n";
    const gamma_src = "pub fn gamma() void {}\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "src/beta.zig", .data = beta_v2_src });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/gamma.zig", .data = gamma_src });
    try explorer.indexFile("src/beta.zig", beta_v2_src);
    _ = try store.recordSnapshot("src/beta.zig", beta_v2_src.len, std.hash.Wyhash.hash(0, beta_v2_src));
    try explorer.indexFile("src/gamma.zig", gamma_src);
    _ = try store.recordSnapshot("src/gamma.zig", gamma_src.len, std.hash.Wyhash.hash(0, gamma_src));

    // 3. Stale-ANN query tolerance:
    //    - "find alpha" hits unchanged src/alpha.zig from HNSW (score 0.0).
    //    - "find beta_v2" hits edited src/beta.zig via delta embedding in the same request (score 0.0).
    //    - "find gamma" hits new src/gamma.zig via delta embedding in the same request (score 0.0).
    //    - "find beta_v1" does NOT hit stale beta_v1 from HNSW (old HNSW node for src/beta.zig is excluded).
    {
        var mock = SemanticMockServer{ .server = &server, .expected_requests = 4 };
        const thread = try std.Thread.spawn(.{}, SemanticMockServer.run, .{&mock});
        var cache = SearchCache.init(testing.allocator);
        defer cache.deinit();

        var res_alpha = searchCached(io, testing.allocator, &cache, &explorer, &store, root_path, data_path, "find alpha", 5) catch |err| {
            thread.join();
            return err;
        };
        defer res_alpha.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 4), res_alpha.documents_sent);
        try testing.expect(res_alpha.hits.len >= 1);
        try testing.expectEqualStrings("src/alpha.zig", res_alpha.hits[0].path);
        try testing.expectApproxEqAbs(@as(f32, 0.0), res_alpha.hits[0].distance, 0.0001);

        var res_beta2 = searchCached(io, testing.allocator, &cache, &explorer, &store, root_path, data_path, "find beta_v2", 5) catch |err| {
            thread.join();
            return err;
        };
        defer res_beta2.deinit(testing.allocator);
        try testing.expect(res_beta2.hits.len >= 1);
        try testing.expectEqualStrings("src/beta.zig", res_beta2.hits[0].path);
        try testing.expectApproxEqAbs(@as(f32, 0.0), res_beta2.hits[0].distance, 0.0001);

        var res_gamma = searchCached(io, testing.allocator, &cache, &explorer, &store, root_path, data_path, "find gamma", 5) catch |err| {
            thread.join();
            return err;
        };
        defer res_gamma.deinit(testing.allocator);
        try testing.expect(res_gamma.hits.len >= 1);
        try testing.expectEqualStrings("src/gamma.zig", res_gamma.hits[0].path);
        try testing.expectApproxEqAbs(@as(f32, 0.0), res_gamma.hits[0].distance, 0.0001);

        var res_beta1 = searchCached(io, testing.allocator, &cache, &explorer, &store, root_path, data_path, "find beta_v1", 5) catch |err| {
            thread.join();
            return err;
        };
        defer res_beta1.deinit(testing.allocator);
        for (res_beta1.hits) |h| {
            try testing.expect(h.distance > 0.5);
        }

        thread.join();
        if (mock.failure) |err| return err;
    }

    // 4. Incremental rebuild: reuses src/alpha.zig from semantic-embeddings-v1.cache
    //    and embeds only the 2 changed/new chunks (src/beta.zig and src/gamma.zig).
    {
        var mock = SemanticMockServer{ .server = &server, .expected_requests = 2 };
        const thread = try std.Thread.spawn(.{}, SemanticMockServer.run, .{&mock});
        const stats2 = build(io, testing.allocator, &explorer, &store, root_path, data_path) catch |err| {
            thread.join();
            return err;
        };
        thread.join();
        if (mock.failure) |err| return err;
        try testing.expectEqual(@as(usize, 3), stats2.records);
        try testing.expectEqual(@as(usize, 1), stats2.reused_records);
        try testing.expectEqual(@as(usize, 2), mock.last_batch_inputs);
    }
}
