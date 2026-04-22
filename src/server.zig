// codedb HTTP server — ported to Zig 0.16 std.Io.net (issue #285).
//
// This restores the port server that upstream stubbed out in commit 56ea465
// (v0.2.578). The route set and JSON response shapes match the pre-0.16
// implementation byte-for-byte; only the transport layer (listen/accept/read/
// write/close) was rewritten against the new `std.Io.net` surface. MCP stdio
// remains the primary entry, but `codedb serve --port` is once again usable
// by external clients that speak HTTP/1.1.

const std = @import("std");
const cio = @import("cio.zig");
const Store = @import("store.zig").Store;
const AgentRegistry = @import("agent.zig").AgentRegistry;
const Explorer = @import("explore.zig").Explorer;
const snapshot_json = @import("snapshot_json.zig");
const watcher = @import("watcher.zig");
const edit_mod = @import("edit.zig");

pub fn serve(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: *Store,
    agents: *AgentRegistry,
    explorer: *Explorer,
    queue: *watcher.EventQueue,
    port: u16,
) !void {
    _ = queue;

    const addr = std.Io.net.IpAddress.parse("127.0.0.1", port) catch unreachable;
    var srv = try addr.listen(io, .{
        .reuse_address = true,
        .mode = .stream,
        .protocol = .tcp,
    });
    defer srv.deinit(io);

    while (true) {
        const stream = srv.accept(io) catch |err| switch (err) {
            error.WouldBlock, error.ConnectionAborted => continue,
            else => return err,
        };
        const ctx = allocator.create(HandlerCtx) catch {
            stream.close(io);
            continue;
        };
        ctx.* = .{
            .io = io,
            .allocator = allocator,
            .store = store,
            .agents = agents,
            .explorer = explorer,
            .stream = stream,
        };
        const t = std.Thread.spawn(.{}, handleThread, .{ctx}) catch {
            stream.close(io);
            allocator.destroy(ctx);
            continue;
        };
        t.detach();
    }
}

const HandlerCtx = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    store: *Store,
    agents: *AgentRegistry,
    explorer: *Explorer,
    stream: std.Io.net.Stream,
};

fn handleThread(ctx: *HandlerCtx) void {
    const io = ctx.io;
    const allocator = ctx.allocator;
    defer {
        ctx.stream.close(io);
        allocator.destroy(ctx);
    }
    handleConnection(io, allocator, ctx.store, ctx.agents, ctx.explorer, ctx.stream);
}

/// Thin wrapper that owns a TCP stream plus a matching `std.Io.Writer` with a
/// small drain buffer. The response helpers below call `writeAll` followed by
/// `flush`, and the buffer is only used so the Io.Writer interface has a place
/// to stage bytes before the vectored drain hits the socket.
const Conn = struct {
    io: std.Io,
    stream: std.Io.net.Stream,
    writer: std.Io.net.Stream.Writer,

    fn init(io: std.Io, stream: std.Io.net.Stream, buf: []u8) Conn {
        return .{
            .io = io,
            .stream = stream,
            .writer = stream.writer(io, buf),
        };
    }

    /// Best-effort flush+write of `bytes`. Silently drops errors — the remote
    /// may have closed; we just want to finish the handler cleanly in that
    /// case so the caller's `defer stream.close(io)` runs.
    fn writeAll(self: *Conn, bytes: []const u8) void {
        self.writer.interface.writeAll(bytes) catch {};
    }

    fn flush(self: *Conn) void {
        self.writer.interface.flush() catch {};
    }
};

fn handleConnection(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: *Store,
    agents: *AgentRegistry,
    explorer: *Explorer,
    stream: std.Io.net.Stream,
) void {
    var buf: [65536]u8 = undefined;

    var total: usize = 0;
    const first_n = readSome(io, stream, buf[0..]) catch return;
    if (first_n == 0) return;
    total = first_n;

    var write_buf: [4096]u8 = undefined;
    var conn = Conn.init(io, stream, &write_buf);

    // If this is a POST, we may need to drain more bytes until we have the
    // full header block + declared Content-Length body.
    if (std.mem.startsWith(u8, buf[0..total], "POST")) {
        var header_end_opt = std.mem.indexOf(u8, buf[0..total], "\r\n\r\n");
        while (header_end_opt == null and total < buf.len) {
            const extra = readSome(io, stream, buf[total..]) catch {
                respondJson(&conn, "400 Bad Request", "{\"error\":\"invalid request\"}");
                return;
            };
            if (extra == 0) break;
            total += extra;
            header_end_opt = std.mem.indexOf(u8, buf[0..total], "\r\n\r\n");
        }

        const header_end = header_end_opt orelse {
            if (total == buf.len) {
                respondJson(&conn, "413 Payload Too Large", "{\"error\":\"request too large\"}");
            } else {
                respondJson(&conn, "400 Bad Request", "{\"error\":\"malformed headers\"}");
            }
            return;
        };

        const body_start = header_end + 4;
        const headers = buf[0..header_end];
        var content_length: ?usize = null;
        var lines = std.mem.splitSequence(u8, headers, "\r\n");
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const name = std.mem.trim(u8, line[0..colon], " \t");
            const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
            if (std.ascii.eqlIgnoreCase(name, "Content-Length")) {
                content_length = std.fmt.parseInt(usize, value, 10) catch {
                    respondJson(&conn, "400 Bad Request", "{\"error\":\"invalid content-length\"}");
                    return;
                };
                break;
            }
        }

        const body_len = content_length orelse {
            respondJson(&conn, "400 Bad Request", "{\"error\":\"missing content-length\"}");
            return;
        };
        if (body_len > buf.len - body_start) {
            respondJson(&conn, "413 Payload Too Large", "{\"error\":\"request too large\"}");
            return;
        }

        const expected_total = body_start + body_len;
        while (total < expected_total) {
            const extra = readSome(io, stream, buf[total..expected_total]) catch {
                respondJson(&conn, "400 Bad Request", "{\"error\":\"invalid request body\"}");
                return;
            };
            if (extra == 0) {
                respondJson(&conn, "400 Bad Request", "{\"error\":\"truncated request body\"}");
                return;
            }
            total += extra;
        }
        total = expected_total;
    }

    const request = buf[0..total];

    // ── Health ──
    if (std.mem.startsWith(u8, request, "GET /health")) {
        respondJson(&conn, "200 OK", "{\"status\":\"ok\"}");
        return;
    }

    // ── Agent: register ──
    if (std.mem.startsWith(u8, request, "POST /agent/register")) {
        const body = extractBody(request);
        const name = if (body.len > 0) extractJsonString(body, "name") orelse "unnamed" else "unnamed";
        const id = agents.register(name) catch {
            respondJson(&conn, "500 Internal Server Error", "{\"error\":\"register failed\"}");
            return;
        };
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);
        const w = cio.listWriter(&out, allocator);
        w.print("{{\"id\":{d},\"name\":\"", .{id}) catch return;
        writeJsonEscaped(&out, allocator, name) catch return;
        w.writeAll("\"}") catch return;
        respondJson(&conn, "200 OK", out.items);
        return;
    }

    // ── Agent: heartbeat ──
    if (std.mem.startsWith(u8, request, "POST /agent/heartbeat")) {
        const agent_id = extractQueryParamInt(request, "id") orelse {
            respondJson(&conn, "400 Bad Request", "{\"error\":\"missing ?id=\"}");
            return;
        };
        agents.heartbeat(agent_id);
        respondJson(&conn, "200 OK", "{\"ok\":true}");
        return;
    }

    // ── Lock ──
    if (std.mem.startsWith(u8, request, "POST /lock")) {
        const agent_id = extractQueryParamInt(request, "agent") orelse {
            respondJson(&conn, "400 Bad Request", "{\"error\":\"missing ?agent=\"}");
            return;
        };
        const path = extractQueryParam(request, "path") orelse {
            respondJson(&conn, "400 Bad Request", "{\"error\":\"missing ?path=\"}");
            return;
        };
        const got = agents.tryLock(agent_id, path, 30_000) catch {
            respondJson(&conn, "500 Internal Server Error", "{\"error\":\"lock failed\"}");
            return;
        };
        if (got) {
            respondJson(&conn, "200 OK", "{\"locked\":true}");
        } else {
            respondJson(&conn, "409 Conflict", "{\"locked\":false,\"error\":\"file locked by another agent\"}");
        }
        return;
    }

    // ── Unlock ──
    if (std.mem.startsWith(u8, request, "POST /unlock")) {
        const agent_id = extractQueryParamInt(request, "agent") orelse {
            respondJson(&conn, "400 Bad Request", "{\"error\":\"missing ?agent=\"}");
            return;
        };
        const path = extractQueryParam(request, "path") orelse {
            respondJson(&conn, "400 Bad Request", "{\"error\":\"missing ?path=\"}");
            return;
        };
        agents.releaseLock(agent_id, path);
        respondJson(&conn, "200 OK", "{\"unlocked\":true}");
        return;
    }

    // ── Edit ──
    if (std.mem.startsWith(u8, request, "POST /edit")) {
        const body = extractBody(request);
        if (body.len == 0) {
            respondJson(&conn, "400 Bad Request", "{\"error\":\"missing body\"}");
            return;
        }
        const parsed_body = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
            respondJson(&conn, "400 Bad Request", "{\"error\":\"invalid json\"}");
            return;
        };
        defer parsed_body.deinit();
        if (parsed_body.value != .object) {
            respondJson(&conn, "400 Bad Request", "{\"error\":\"body must be object\"}");
            return;
        }

        const body_obj = &parsed_body.value.object;
        const path = jsonString(body_obj, "path") orelse {
            respondJson(&conn, "400 Bad Request", "{\"error\":\"missing path\"}");
            return;
        };
        if (!isPathSafe(path)) {
            respondJson(&conn, "403 Forbidden", "{\"error\":\"path traversal not allowed\"}");
            return;
        }

        const agent_id = jsonU64(body_obj, "agent") orelse {
            respondJson(&conn, "400 Bad Request", "{\"error\":\"missing agent\"}");
            return;
        };

        const op_str = jsonString(body_obj, "op") orelse "replace";
        const op: @import("version.zig").Op = if (std.mem.eql(u8, op_str, "insert"))
            .insert
        else if (std.mem.eql(u8, op_str, "delete"))
            .delete
        else
            .replace;

        var content: ?[]const u8 = null;
        if (body_obj.get("content")) |value| {
            switch (value) {
                .string => |s| content = s,
                .null => {},
                else => {
                    respondJson(&conn, "400 Bad Request", "{\"error\":\"content must be string\"}");
                    return;
                },
            }
        }

        const range_start = jsonU64(body_obj, "range_start");
        const range_end = jsonU64(body_obj, "range_end");
        const after = jsonU64(body_obj, "after");

        var req = edit_mod.EditRequest{
            .path = path,
            .agent_id = agent_id,
            .op = op,
            .content = content,
        };
        if (range_start != null and range_end != null) {
            req.range = .{ @intCast(range_start.?), @intCast(range_end.?) };
        }
        if (after) |a| req.after = @intCast(a);

        const result = edit_mod.applyEdit(io, allocator, store, agents, explorer, req) catch |err| {
            var err_buf: [128]u8 = undefined;
            const err_body = std.fmt.bufPrint(&err_buf, "{{\"error\":\"{s}\"}}", .{@errorName(err)}) catch return;
            const status = switch (err) {
                error.InvalidRange, error.MissingContent => "400 Bad Request",
                error.FileLocked => "409 Conflict",
                error.FileNotFound => "404 Not Found",
                error.AccessDenied => "403 Forbidden",
                else => "500 Internal Server Error",
            };
            respondJson(&conn, status, err_body);
            return;
        };

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);
        const w = cio.listWriter(&out, allocator);
        w.print("{{\"seq\":{d},\"hash\":{d},\"size\":{d}}}", .{ result.seq, result.new_hash, result.new_size }) catch return;
        respondJson(&conn, "200 OK", out.items);
        return;
    }

    // ── File read ──
    if (std.mem.startsWith(u8, request, "GET /file/read")) {
        const path = extractQueryParam(request, "path") orelse {
            respondJson(&conn, "400 Bad Request", "{\"error\":\"missing ?path=\"}");
            return;
        };
        if (!isPathSafe(path)) {
            respondJson(&conn, "403 Forbidden", "{\"error\":\"path traversal not allowed\"}");
            return;
        }
        const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(10 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => {
                respondJson(&conn, "404 Not Found", "{\"error\":\"file not found\"}");
                return;
            },
            else => {
                respondJson(&conn, "500 Internal Server Error", "{\"error\":\"read failed\"}");
                return;
            },
        };
        defer allocator.free(content);

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);
        const w = cio.listWriter(&out, allocator);
        w.writeAll("{\"path\":\"") catch return;
        writeJsonEscaped(&out, allocator, path) catch return;
        w.print("\",\"size\":{d},\"content\":\"", .{content.len}) catch return;
        writeJsonEscaped(&out, allocator, content) catch return;
        w.writeAll("\"}") catch return;
        respondJson(&conn, "200 OK", out.items);
        return;
    }

    // ── Changes since cursor ──
    if (std.mem.startsWith(u8, request, "GET /changes")) {
        const since = extractQueryParamInt(request, "since") orelse 0;
        const changes = store.changesSinceDetailed(since, allocator) catch {
            respondJson(&conn, "500 Internal Server Error", "{\"error\":\"changes query failed\"}");
            return;
        };
        defer allocator.free(changes);

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);
        const w = cio.listWriter(&out, allocator);
        w.print("{{\"since\":{d},\"seq\":{d},\"changes\":[", .{ since, store.currentSeq() }) catch return;
        for (changes, 0..) |c, i| {
            if (i > 0) w.writeAll(",") catch return;
            w.writeAll("{\"path\":\"") catch return;
            writeJsonEscaped(&out, allocator, c.path) catch return;
            w.print("\",\"seq\":{d},\"op\":\"{s}\",\"size\":{d},\"timestamp\":{d}}}", .{
                c.seq, @tagName(c.op), c.size, c.timestamp,
            }) catch return;
        }
        w.writeAll("]}") catch return;
        respondJson(&conn, "200 OK", out.items);
        return;
    }

    // ── Explore: tree ──
    if (std.mem.startsWith(u8, request, "GET /explore/tree")) {
        const tree = explorer.getTree(allocator, false) catch {
            respondJson(&conn, "500 Internal Server Error", "{\"error\":\"tree failed\"}");
            return;
        };
        defer allocator.free(tree);

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);
        const w = cio.listWriter(&out, allocator);
        w.writeAll("{\"tree\":\"") catch return;
        writeJsonEscaped(&out, allocator, tree) catch return;
        w.writeAll("\"}") catch return;
        respondJson(&conn, "200 OK", out.items);
        return;
    }

    // ── Explore: outline ──
    if (std.mem.startsWith(u8, request, "GET /explore/outline")) {
        const path_raw = extractQueryParam(request, "path") orelse {
            respondJson(&conn, "400 Bad Request", "{\"error\":\"missing ?path=\"}");
            return;
        };
        const path = percentDecode(allocator, path_raw) catch {
            respondJson(&conn, "500 Internal Server Error", "{\"error\":\"decode failed\"}");
            return;
        };
        defer allocator.free(path);
        if (!isPathSafe(path)) {
            respondJson(&conn, "403 Forbidden", "{\"error\":\"path traversal not allowed\"}");
            return;
        }
        var outline = explorer.getOutline(path, allocator) catch {
            respondJson(&conn, "500 Internal Server Error", "{\"error\":\"outline failed\"}");
            return;
        } orelse {
            respondJson(&conn, "404 Not Found", "{\"error\":\"file not indexed\"}");
            return;
        };
        defer outline.deinit();
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);
        const w = cio.listWriter(&out, allocator);
        w.writeAll("{\"path\":\"") catch return;
        writeJsonEscaped(&out, allocator, outline.path) catch return;
        w.print("\",\"language\":\"{s}\",\"lines\":{d},\"bytes\":{d},\"symbols\":[", .{
            @tagName(outline.language), outline.line_count, outline.byte_size,
        }) catch return;
        for (outline.symbols.items, 0..) |sym, i| {
            if (i > 0) w.writeAll(",") catch return;
            w.writeAll("{\"name\":\"") catch return;
            writeJsonEscaped(&out, allocator, sym.name) catch return;
            w.print("\",\"kind\":\"{s}\",\"line_start\":{d},\"line_end\":{d}", .{
                @tagName(sym.kind), sym.line_start, sym.line_end,
            }) catch return;
            if (sym.detail) |d| {
                w.writeAll(",\"detail\":\"") catch return;
                writeJsonEscaped(&out, allocator, d) catch return;
                w.writeAll("\"") catch return;
            }
            w.writeAll("}") catch return;
        }
        w.writeAll("]}") catch return;
        respondJson(&conn, "200 OK", out.items);
        return;
    }

    // ── Explore: symbol (find all) ──
    if (std.mem.startsWith(u8, request, "GET /explore/symbol")) {
        const name = extractQueryParam(request, "name") orelse {
            respondJson(&conn, "400 Bad Request", "{\"error\":\"missing ?name=\"}");
            return;
        };
        const results = explorer.findAllSymbols(name, allocator) catch {
            respondJson(&conn, "500 Internal Server Error", "{\"error\":\"search failed\"}");
            return;
        };
        defer allocator.free(results);

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);
        const w = cio.listWriter(&out, allocator);
        w.writeAll("{\"name\":\"") catch return;
        writeJsonEscaped(&out, allocator, name) catch return;
        w.writeAll("\",\"results\":[") catch return;
        for (results, 0..) |r, i| {
            if (i > 0) w.writeAll(",") catch return;
            w.writeAll("{\"path\":\"") catch return;
            writeJsonEscaped(&out, allocator, r.path) catch return;
            w.print("\",\"line\":{d},\"kind\":\"{s}\"", .{
                r.symbol.line_start, @tagName(r.symbol.kind),
            }) catch return;
            if (r.symbol.detail) |d| {
                w.writeAll(",\"detail\":\"") catch return;
                writeJsonEscaped(&out, allocator, d) catch return;
                w.writeAll("\"") catch return;
            }
            w.writeAll("}") catch return;
        }
        w.writeAll("]}") catch return;
        respondJson(&conn, "200 OK", out.items);
        return;
    }

    // ── Explore: hot ──
    if (std.mem.startsWith(u8, request, "GET /explore/hot")) {
        const hot = explorer.getHotFiles(store, allocator, 10) catch {
            respondJson(&conn, "500 Internal Server Error", "{\"error\":\"hot files failed\"}");
            return;
        };
        defer {
            for (hot) |entry| allocator.free(entry);
            allocator.free(hot);
        }
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);
        const w = cio.listWriter(&out, allocator);
        w.writeAll("{\"files\":[") catch return;
        for (hot, 0..) |path, i| {
            if (i > 0) w.writeAll(",") catch return;
            w.writeAll("\"") catch return;
            writeJsonEscaped(&out, allocator, path) catch return;
            w.writeAll("\"") catch return;
        }
        w.writeAll("]}") catch return;
        respondJson(&conn, "200 OK", out.items);
        return;
    }

    // ── Explore: deps ──
    if (std.mem.startsWith(u8, request, "GET /explore/deps")) {
        const path_raw = extractQueryParam(request, "path") orelse {
            respondJson(&conn, "400 Bad Request", "{\"error\":\"missing ?path=\"}");
            return;
        };
        const path = percentDecode(allocator, path_raw) catch {
            respondJson(&conn, "500 Internal Server Error", "{\"error\":\"decode failed\"}");
            return;
        };
        defer allocator.free(path);
        const imported_by = explorer.getImportedBy(path, allocator) catch {
            respondJson(&conn, "500 Internal Server Error", "{\"error\":\"deps failed\"}");
            return;
        };
        defer {
            for (imported_by) |dep| allocator.free(dep);
            allocator.free(imported_by);
        }

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);
        const w = cio.listWriter(&out, allocator);
        w.writeAll("{\"path\":\"") catch return;
        writeJsonEscaped(&out, allocator, path) catch return;
        w.writeAll("\",\"imported_by\":[") catch return;
        for (imported_by, 0..) |dep, i| {
            if (i > 0) w.writeAll(",") catch return;
            w.writeAll("\"") catch return;
            writeJsonEscaped(&out, allocator, dep) catch return;
            w.writeAll("\"") catch return;
        }
        w.writeAll("]}") catch return;
        respondJson(&conn, "200 OK", out.items);
        return;
    }

    // ── Explore: word search (inverted index, O(1) lookup) ──
    if (std.mem.startsWith(u8, request, "GET /explore/word")) {
        const word_raw = extractQueryParam(request, "q") orelse {
            respondJson(&conn, "400 Bad Request", "{\"error\":\"missing ?q=\"}");
            return;
        };
        const word = percentDecode(allocator, word_raw) catch {
            respondJson(&conn, "500 Internal Server Error", "{\"error\":\"decode failed\"}");
            return;
        };
        defer allocator.free(word);
        const hits = explorer.searchWord(word, allocator) catch {
            respondJson(&conn, "500 Internal Server Error", "{\"error\":\"word search failed\"}");
            return;
        };
        defer allocator.free(hits);

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);
        const w = cio.listWriter(&out, allocator);
        w.writeAll("{\"query\":\"") catch return;
        writeJsonEscaped(&out, allocator, word) catch return;
        w.writeAll("\",\"hits\":[") catch return;
        explorer.mu.lockShared();
        defer explorer.mu.unlockShared();
        for (hits, 0..) |h, i| {
            if (i > 0) w.writeAll(",") catch return;
            w.writeAll("{\"path\":\"") catch return;
            writeJsonEscaped(&out, allocator, explorer.word_index.hitPath(h)) catch return;
            w.print("\",\"line\":{d}}}", .{h.line_num}) catch return;
        }
        w.writeAll("]}") catch return;
        respondJson(&conn, "200 OK", out.items);
        return;
    }

    // ── Explore: search (text grep, trigram-accelerated) ──
    if (std.mem.startsWith(u8, request, "GET /explore/search")) {
        const query_raw = extractQueryParam(request, "q") orelse {
            respondJson(&conn, "400 Bad Request", "{\"error\":\"missing ?q=\"}");
            return;
        };
        const query = percentDecode(allocator, query_raw) catch {
            respondJson(&conn, "500 Internal Server Error", "{\"error\":\"decode failed\"}");
            return;
        };
        defer allocator.free(query);
        const results = explorer.searchContent(query, allocator, 50) catch {
            respondJson(&conn, "500 Internal Server Error", "{\"error\":\"search failed\"}");
            return;
        };
        defer {
            for (results) |r| allocator.free(r.line_text);
            allocator.free(results);
        }

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);
        const w = cio.listWriter(&out, allocator);
        w.writeAll("{\"query\":\"") catch return;
        writeJsonEscaped(&out, allocator, query) catch return;
        w.writeAll("\",\"results\":[") catch return;
        for (results, 0..) |r, i| {
            if (i > 0) w.writeAll(",") catch return;
            w.writeAll("{\"path\":\"") catch return;
            writeJsonEscaped(&out, allocator, r.path) catch return;
            w.print("\",\"line\":{d},\"text\":\"", .{r.line_num}) catch return;
            writeJsonEscaped(&out, allocator, r.line_text) catch return;
            w.writeAll("\"}") catch return;
        }
        w.writeAll("]}") catch return;
        respondJson(&conn, "200 OK", out.items);
        return;
    }

    // ── Snapshot ──
    if (std.mem.startsWith(u8, request, "GET /snapshot")) {
        const snap = snapshot_json.buildSnapshot(explorer, store, allocator) catch {
            respondJson(&conn, "500 Internal Server Error", "{\"error\":\"snapshot build failed\"}");
            return;
        };
        defer allocator.free(snap);
        respondJson(&conn, "200 OK", snap);
        return;
    }

    // ── Seq ──
    if (std.mem.startsWith(u8, request, "GET /seq")) {
        var seq_buf: [32]u8 = undefined;
        const body = std.fmt.bufPrint(&seq_buf, "{{\"seq\":{d}}}", .{store.currentSeq()}) catch return;
        respondJson(&conn, "200 OK", body);
        return;
    }

    respondJson(&conn, "404 Not Found", "{\"error\":\"not found\"}");
}

// ── Transport helpers ───────────────────────────────────────────

/// Read some bytes from the TCP stream into `dest`. Returns 0 on clean EOF.
/// This is the direct-vtable analogue of the old `conn.stream.read`: no
/// buffered reader state, so each call issues one `netRead` syscall.
fn readSome(io: std.Io, stream: std.Io.net.Stream, dest: []u8) !usize {
    if (dest.len == 0) return 0;
    var iov: [1][]u8 = .{dest};
    const n = try io.vtable.netRead(io.userdata, stream.socket.handle, &iov);
    return n;
}

// ── Response helpers ────────────────────────────────────────────

fn isPathSafe(path: []const u8) bool {
    if (path.len == 0) return false;
    if (path[0] == '/') return false;
    // Block null bytes (path truncation attack).
    if (std.mem.indexOfScalar(u8, path, 0) != null) return false;
    // Block backslash separators so Windows-style `..\..\x` can't bypass the
    // forward-slash `..` check below. Matches mcp.isPathSafe.
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return false;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |component| {
        if (std.mem.eql(u8, component, "..")) return false;
    }
    return true;
}

fn respondJson(conn: *Conn, status: []const u8, body: []const u8) void {
    var hdr_buf: [512]u8 = undefined;
    const hdr = std.fmt.bufPrint(&hdr_buf, "HTTP/1.1 {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ status, body.len }) catch return;
    conn.writeAll(hdr);
    conn.writeAll(body);
    conn.flush();
}

/// Append a JSON-escaped version of `s` to the trailing `out` list.
fn writeJsonEscaped(out: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    for (s) |ch| {
        switch (ch) {
            '"' => try out.appendSlice(alloc, "\\\""),
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            else => {
                if (ch < 0x20) {
                    const hex = "0123456789abcdef";
                    const esc = [6]u8{ '\\', 'u', '0', '0', hex[ch >> 4], hex[ch & 0x0f] };
                    try out.appendSlice(alloc, &esc);
                } else {
                    try out.append(alloc, ch);
                }
            },
        }
    }
}

// ── HTTP parsing helpers ────────────────────────────────────────

fn extractQueryParam(request: []const u8, key: []const u8) ?[]const u8 {
    const first_line_end = std.mem.indexOf(u8, request, "\r\n") orelse request.len;
    const first_line = request[0..first_line_end];

    const q_pos = std.mem.indexOfScalar(u8, first_line, '?') orelse return null;
    const space_pos = std.mem.indexOfScalarPos(u8, first_line, q_pos, ' ') orelse first_line.len;
    const query = first_line[q_pos + 1 .. space_pos];

    var pairs = std.mem.splitScalar(u8, query, '&');
    while (pairs.next()) |pair| {
        if (std.mem.startsWith(u8, pair, key)) {
            if (pair.len > key.len and pair[key.len] == '=') {
                return pair[key.len + 1 ..];
            }
        }
    }
    return null;
}

fn percentDecode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '%' and i + 2 < input.len) {
            const hi = std.fmt.charToDigit(input[i + 1], 16) catch {
                try out.append(allocator, input[i]);
                i += 1;
                continue;
            };
            const lo = std.fmt.charToDigit(input[i + 2], 16) catch {
                try out.append(allocator, input[i]);
                i += 1;
                continue;
            };
            try out.append(allocator, (hi << 4) | lo);
            i += 3;
        } else if (input[i] == '+') {
            try out.append(allocator, ' ');
            i += 1;
        } else {
            try out.append(allocator, input[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

fn extractQueryParamInt(request: []const u8, key: []const u8) ?u64 {
    const val = extractQueryParam(request, key) orelse return null;
    return std.fmt.parseInt(u64, val, 10) catch null;
}

fn extractBody(request: []const u8) []const u8 {
    if (std.mem.indexOf(u8, request, "\r\n\r\n")) |pos| {
        return request[pos + 4 ..];
    }
    return "";
}

fn jsonString(obj: *const std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (obj.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

fn jsonU64(obj: *const std.json.ObjectMap, key: []const u8) ?u64 {
    return switch (obj.get(key) orelse return null) {
        .integer => |n| if (n >= 0) @as(u64, @intCast(n)) else null,
        else => null,
    };
}

fn findUnescapedQuote(s: []const u8, start: usize) ?usize {
    var i = start;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\') {
            i += 1; // skip escaped char
            continue;
        }
        if (s[i] == '"') return i;
    }
    return null;
}

/// Minimal JSON string extractor: finds "key":"value" and returns value.
fn extractJsonString(json: []const u8, key: []const u8) ?[]const u8 {
    // NOTE: This is a naive scanner that does NOT handle JSON escape sequences
    // (e.g. \" inside string values will cause incorrect results). For correct
    // parsing use std.json.parseFromSlice on the full body instead.
    var pos: usize = 0;
    while (pos < json.len) {
        const key_start = std.mem.indexOfPos(u8, json, pos, "\"") orelse return null;
        const key_end = std.mem.indexOfPos(u8, json, key_start + 1, "\"") orelse return null;
        const found_key = json[key_start + 1 .. key_end];

        if (std.mem.eql(u8, found_key, key)) {
            // Skip ":"
            var next = key_end + 1;
            while (next < json.len and (json[next] == ':' or json[next] == ' ')) : (next += 1) {}
            if (next >= json.len or json[next] != '"') return null;
            const val_start = next + 1;
            const val_end = findUnescapedQuote(json, val_start) orelse return null;
            return json[val_start..val_end];
        }
        pos = key_end + 1;
    }
    return null;
}
