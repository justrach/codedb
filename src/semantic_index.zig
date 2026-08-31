//! Persistent, local code-chunk ANN index for hybrid codedb retrieval.
//!
//! Building is explicit: `codedb <root> semantic-index`. Safe, bounded file
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
// Hosted-lane hill climbs: 256 chunks (2026-08-26) gave c1=12.4s, c2=9.4s,
// c4=6.1s, c8=16.7s. A 6,713-chunk React subset (2026-08-30) confirmed
// c1=180.8s, c2=98.9s, c4=68.8s, while c8 was aborted after 338s in retry/
// queue contention. Four remains the Pareto point; differently provisioned
// endpoints can still use the explicit override.
pub const default_parallel_batches: usize = 4;
pub const max_parallel_batches: usize = 8;
pub const default_search_results: usize = 24;
pub const max_records: usize = 250_000;
/// Metadata is copied into heap storage so record paths can borrow from one
/// stable buffer. The HNSW payload itself is mmap-backed; keeping this cap well
/// below the old 256 MiB limit prevents a crafted mapping table from recreating
/// the 650-700 MiB query RSS profile that mmap is meant to avoid.
pub const max_metadata_bytes: usize = 64 * 1024 * 1024;
pub const max_slab_bytes: usize = 1024 * 1024 * 1024;

const magic = [8]u8{ 'C', 'D', 'B', 'A', 'N', 'N', '0', '3' };
const format_version: u16 = 3;
const header_bytes: usize = 48;

pub const BuildStats = struct {
    records: usize,
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
    retention: enum { none_by_codedb_policy, custom_endpoint_unverified },
    load_ns: u64,
    embed_ns: u64,
    search_ns: u64,
    mmap_backed: bool,
    cache_hit: bool,
    vector_space_id: u64,
};

const Record = struct {
    path: []const u8,
    line_start: u32,
    line_end: u32,
};

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
    allocator: std.mem.Allocator,
    cached: ?CachedLoaded = null,

    pub fn init(allocator: std.mem.Allocator) SearchCache {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *SearchCache) void {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.cached) |*cached| cached.loaded.deinit();
        self.cached = null;
    }
};

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

fn flushWave(
    io: std.Io,
    allocator: std.mem.Allocator,
    index: *ann.Index,
    config: semantic.Config,
    cards: *std.ArrayList([]u8),
    pending_records: *std.ArrayList(Record),
    indexed_records: *std.ArrayList(Record),
) !FlushStats {
    if (cards.items.len == 0) return .{
        .text_bytes = 0,
        .records = 0,
        .embedding_wall_ns = 0,
        .insertion_ns = 0,
    };
    if (cards.items.len != pending_records.items.len) return error.AnnRecordMappingMismatch;
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
    const insertion_started = cio.nanoTimestamp();
    for (workers[0..batch_count], 0..) |worker, batch_index| {
        const embedded = worker.result orelse return error.MissingEmbeddingBatchResult;
        if (embedded.dimensions != config.dimensions or !std.mem.eql(u8, embedded.model, config.model)) {
            return error.EmbeddingConfigChangedDuringBuild;
        }
        if (embedded.count != worker.inputs.len) return error.InvalidEmbeddingBatchShape;
        text_bytes = try std.math.add(usize, text_bytes, embedded.text_bytes_sent);
        const record_start = batch_index * semantic.max_index_documents;
        const first_id = try index.insertEmbeddingBatch(embedded.vectors, embedded.count, embedded.dimensions);
        if (first_id != indexed_records.items.len) return error.AnnRecordMappingMismatch;
        for (0..embedded.count) |row_index| {
            try indexed_records.append(allocator, pending_records.items[record_start + row_index]);
        }
    }
    const insertion_ns = elapsedNs(insertion_started);
    const records = cards.items.len;
    for (cards.items) |card| allocator.free(card);
    cards.clearRetainingCapacity();
    pending_records.clearRetainingCapacity();
    return .{
        .text_bytes = text_bytes,
        .records = records,
        .embedding_wall_ns = embedding_wall_ns,
        .insertion_ns = insertion_ns,
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
    var cards: std.ArrayList([]u8) = .empty;
    defer {
        for (cards.items) |card| allocator.free(card);
        cards.deinit(allocator);
    }
    var pending_records: std.ArrayList(Record) = .empty;
    defer pending_records.deinit(allocator);
    var indexed_records: std.ArrayList(Record) = .empty;
    defer indexed_records.deinit(allocator);

    const parallel_batches = indexConcurrency();
    const wave_capacity = parallel_batches * semantic.max_index_documents;
    var text_bytes_sent: usize = calibration_result.text_bytes_sent;
    var embedding_wall_ns: u64 = elapsedNs(calibration_started);
    var insertion_ns: u64 = 0;
    var blocked: usize = 0;
    var files_indexed: usize = 0;
    for (paths) |path| {
        if (!semantic.isRemoteCandidatePathAllowed(path)) {
            blocked += 1;
            continue;
        }
        const content = (try explorer.getContent(path, allocator)) orelse return error.RepositoryChangedDuringAnnBuild;
        defer allocator.free(content);
        Store.updateSemanticContentFingerprint(
            &embedded_content,
            path,
            std.hash.Wyhash.hash(0, content),
            @intCast(content.len),
        );
        if (content.len == 0) continue;
        var outline = (try explorer.getOutline(path, allocator)) orelse return error.RepositoryChangedDuringAnnBuild;
        defer outline.deinit();
        var cursor = ChunkCursor{ .content = content };
        var chunks_for_file: usize = 0;
        while (chunks_for_file < max_chunks_per_file) : (chunks_for_file += 1) {
            const chunk = cursor.next() orelse break;
            if (indexed_records.items.len + pending_records.items.len >= max_records) return error.AnnRecordBudgetExceeded;
            if (cards.items.len == wave_capacity) {
                const stats = try flushWave(io, allocator, &index, config, &cards, &pending_records, &indexed_records);
                text_bytes_sent = try std.math.add(usize, text_bytes_sent, stats.text_bytes);
                embedding_wall_ns = try std.math.add(u64, embedding_wall_ns, stats.embedding_wall_ns);
                insertion_ns = try std.math.add(u64, insertion_ns, stats.insertion_ns);
                if (try index.slabImageSize() > max_slab_bytes) return error.AnnSlabTooLarge;
            }
            const card = try makeChunkCard(allocator, path, @tagName(outline.language), chunk);
            try cards.append(allocator, card);
            try pending_records.append(allocator, .{
                .path = path,
                .line_start = chunk.line_start,
                .line_end = chunk.line_end,
            });
        }
        if (chunks_for_file > 0) files_indexed += 1;
    }
    const final_stats = try flushWave(io, allocator, &index, config, &cards, &pending_records, &indexed_records);
    text_bytes_sent = try std.math.add(usize, text_bytes_sent, final_stats.text_bytes);
    embedding_wall_ns = try std.math.add(u64, embedding_wall_ns, final_stats.embedding_wall_ns);
    insertion_ns = try std.math.add(u64, insertion_ns, final_stats.insertion_ns);
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
    const slab_bytes = try fileSize(io, slab_path);
    if (slab_bytes == 0 or slab_bytes > max_slab_bytes) return error.AnnSlabTooLarge;
    var index = ann.Index.init(allocator, dimensions, .{});
    errdefer index.deinit();
    return .{
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

fn validateLoadedConfig(config: *const semantic.Config, loaded: *const Loaded) !void {
    if (config.dimensions != loaded.dimensions) return error.AnnDimensionsMismatch;
    if (!std.mem.eql(u8, config.model, loaded.model)) return error.AnnModelMismatch;
    if (config.vectorSpaceId() != loaded.vector_space_id) return error.AnnVectorSpaceMismatch;
}

fn searchLoaded(
    io: std.Io,
    allocator: std.mem.Allocator,
    loaded: *Loaded,
    task: []const u8,
    k: usize,
    load_ns: u64,
    cache_hit: bool,
) !SearchOutput {
    const embed_started = cio.nanoTimestamp();
    const query = try semantic.embedQueryAndCalibrationRemote(io, allocator, task);
    defer allocator.free(query.vectors);
    const embed_ns = elapsedNs(embed_started);
    if (query.count != 2 or query.dimensions != loaded.dimensions or !std.mem.eql(u8, query.model, loaded.model)) {
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
    var hits: std.ArrayList(Hit) = .empty;
    var seen_paths = std.StringHashMap(void).init(allocator);
    defer seen_paths.deinit();
    errdefer {
        for (hits.items) |hit| allocator.free(hit.path);
        hits.deinit(allocator);
    }
    for (raw) |result| {
        if (result.id >= loaded.records.len) return error.AnnRecordMappingMismatch;
        const record = loaded.records[result.id];
        if (!semantic.isRemoteCandidatePathAllowed(record.path)) continue;
        if (seen_paths.contains(record.path)) continue;
        try seen_paths.put(record.path, {});
        try hits.append(allocator, .{
            .path = try allocator.dupe(u8, record.path),
            .line_start = record.line_start,
            .line_end = record.line_end,
            .distance = result.distance,
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
    const metadata_before = try fileIdentity(io, metadata_path);

    var loaded = try loadMetadata(io, persistent, data_dir);
    errdefer loaded.deinit();
    try validateLoadedConfig(config, &loaded);
    const head_before = try git_mod.getGitHead(project_root, temporary);
    if (!headsEqual(head_before, loaded.git_head)) return error.StaleAnnGitHead;
    const seq_before = store.currentSeq();
    if (try repositoryFingerprint(explorer, store, temporary) != loaded.manifest) return error.StaleAnnManifest;
    try validateRecordLineRanges(explorer, loaded.records);
    if (store.currentSeq() != seq_before) return error.StaleAnnManifest;

    const slab_before = try fileIdentity(io, loaded.slab_path);
    try loaded.loadGraph();
    const metadata_after = try fileIdentity(io, metadata_path);
    const slab_after = try fileIdentity(io, loaded.slab_path);
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
            return searchLoaded(io, allocator, &cached.loaded, task, k, elapsedNs(load_started), true);
        }
    }
    cache.mu.unlockShared();

    cache.mu.lock();
    defer cache.mu.unlock();
    // Another concurrent cold request may have installed the generation while
    // this request waited for the exclusive lock.
    if (cache.cached) |*cached| {
        if (try cachedGenerationCurrent(io, allocator, cached, &config, store, data_dir)) {
            return searchLoaded(io, allocator, &cached.loaded, task, k, elapsedNs(load_started), true);
        }
    }

    const replacement = try loadValidatedGeneration(io, cache.allocator, allocator, &config, explorer, store, project_root, data_dir);
    if (cache.cached) |*old| old.loaded.deinit();
    cache.cached = replacement;
    return searchLoaded(io, allocator, &cache.cached.?.loaded, task, k, elapsedNs(load_started), false);
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
    if (!headsEqual(current_head, loaded.git_head)) return error.StaleAnnGitHead;
    if (try repositoryFingerprint(explorer, store, allocator) != loaded.manifest) return error.StaleAnnManifest;
    // Metadata is attacker-controlled local input. Validate the entire mapping
    // while the index is still empty so a failure remains transactional and no
    // forged line can reach rendering arithmetic.
    try validateRecordLineRanges(explorer, loaded.records);
    try loaded.loadGraph();
    const load_ns = elapsedNs(load_started);
    return searchLoaded(io, allocator, &loaded, task, k, load_ns, false);
}

test "semantic ANN sidecar accepts Jina 512D and rejects a legacy Qwen vector space" {
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
    const results = try restored.index.search(&b, 1, testing.allocator);
    defer testing.allocator.free(results);
    try testing.expectEqual(@as(u32, 1), results[0].id);
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

test "semantic ANN wave uses the public 25-item batch boundary" {
    // This is the hosted-lane Pareto point measured against the production
    // TurboAPI/TEI queue. Raising the default to the supported maximum of 8
    // regressed the 256-chunk end-to-end run from 6.1s to 16.7s. Keep the
    // override for custom endpoints, but make an accidental default drift a
    // release-gating test failure.
    try std.testing.expectEqual(@as(usize, 4), default_parallel_batches);
    try std.testing.expectEqual(@as(usize, 25), semantic.max_index_documents);
    try std.testing.expectEqual(@as(usize, 100), default_parallel_batches * semantic.max_index_documents);
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
