const std = @import("std");
const Store = @import("store.zig").Store;
const AgentRegistry = @import("agent.zig").AgentRegistry;
const Explorer = @import("explore.zig").Explorer;
const Prerender = @import("prerender.zig").Prerender;
const watcher = @import("watcher.zig");
const server = @import("server.zig");
const mcp_server = @import("mcp.zig");

const print = std.debug.print;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var root: []const u8 = undefined;
    var cmd: []const u8 = undefined;
    var cmd_args_start: usize = undefined;

    // Support --mcp flag as alias for `mcp` subcommand (matches muonry convention)
    if (args.len >= 2 and std.mem.eql(u8, args[1], "--mcp")) {
        root = ".";
        cmd = "mcp";
        cmd_args_start = 2;
    } else if (args.len < 2) {
        printUsage();
        std.process.exit(1);
    } else if (isCommand(args[1])) {
        root = ".";
        cmd = args[1];
        cmd_args_start = 2;
    } else if (args.len >= 3) {
        root = args[1];
        cmd = args[2];
        cmd_args_start = 3;
    } else {
        printUsage();
        std.process.exit(1);
    }

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_root = resolveRoot(root, &root_buf) catch {
        print("error: cannot resolve root path: {s}\n", .{root});
        std.process.exit(1);
    };

    const data_dir = try getDataDir(allocator, abs_root);
    defer allocator.free(data_dir);

    var store = Store.init(allocator);
    defer store.deinit();

    const data_log_path = try std.fmt.allocPrint(allocator, "{s}/data.log", .{data_dir});
    defer allocator.free(data_log_path);
    store.openDataLog(data_log_path) catch |err| {
        std.log.warn("could not open data log at {s}: {}", .{ data_log_path, err });
    };

    var explorer = Explorer.init(allocator);
    defer explorer.deinit();
    if (!std.mem.eql(u8, cmd, "mcp")) {
        try watcher.initialScan(&store, &explorer, root, allocator);
    }

    if (std.mem.eql(u8, cmd, "tree")) {
        const tree = try explorer.getTree(allocator);
        defer allocator.free(tree);
        print("{s}", .{tree});
    } else if (std.mem.eql(u8, cmd, "outline")) {
        const path = if (args.len > cmd_args_start) args[cmd_args_start] else {
            print("usage: codedb [root] outline <path>\n", .{});
            std.process.exit(1);
        };
        var outline = explorer.getOutline(path, allocator) catch {
            print("error: failed to load outline for {s}\n", .{path});
            std.process.exit(1);
        } orelse {
            print("not found: {s}\n", .{path});
            return;
        };
        defer outline.deinit();
        print("{s} ({s}, {d} lines)\n", .{
            outline.path, @tagName(outline.language), outline.line_count,
        });
        for (outline.symbols.items) |sym| {
            print("  L{d}: {s} {s}", .{ sym.line_start, @tagName(sym.kind), sym.name });
            if (sym.detail) |d| print("  // {s}", .{d});
            print("\n", .{});
        }
    } else if (std.mem.eql(u8, cmd, "find")) {
        const name = if (args.len > cmd_args_start) args[cmd_args_start] else {
            print("usage: codedb [root] find <symbol>\n", .{});
            std.process.exit(1);
        };
        if (try explorer.findSymbol(name, allocator)) |r| {
            print("{s}:{d} ({s})\n", .{ r.path, r.symbol.line_start, @tagName(r.symbol.kind) });
            if (r.symbol.detail) |d| print("  {s}\n", .{d});
        } else {
            print("not found: {s}\n", .{name});
        }
    } else if (std.mem.eql(u8, cmd, "search")) {
        const query = if (args.len > cmd_args_start) args[cmd_args_start] else {
            print("usage: codedb [root] search <query>\n", .{});
            std.process.exit(1);
        };
        const results = try explorer.searchContent(query, allocator, 50);
        defer {
            for (results) |r| allocator.free(r.line_text);
            allocator.free(results);
        }
        if (results.len == 0) {
            print("no results for: {s}\n", .{query});
        } else {
            for (results) |r| {
                print("{s}:{d}: {s}\n", .{ r.path, r.line_num, r.line_text });
            }
        }
    } else if (std.mem.eql(u8, cmd, "word")) {
        const word = if (args.len > cmd_args_start) args[cmd_args_start] else {
            print("usage: codedb [root] word <identifier>\n", .{});
            std.process.exit(1);
        };
        const hits = try explorer.searchWord(word, allocator);
        defer allocator.free(hits);
        if (hits.len == 0) {
            print("no hits for: {s}\n", .{word});
        } else {
            print("{d} hits for '{s}':\n", .{ hits.len, word });
            for (hits) |h| {
                print("  {s}:{d}\n", .{ h.path, h.line_num });
            }
        }
    } else if (std.mem.eql(u8, cmd, "hot")) {
        const hot = try explorer.getHotFiles(&store, allocator, 10);
        defer {
            for (hot) |path| allocator.free(path);
            allocator.free(hot);
        }
        for (hot) |path| print("{s}\n", .{path});
    } else if (std.mem.eql(u8, cmd, "serve")) {
        const port: u16 = 7719;
        var agents = AgentRegistry.init(allocator);
        defer agents.deinit();
        _ = try agents.register("__filesystem__");

        var prerender = Prerender.init(allocator);
        defer prerender.deinit();

        var shutdown = std.atomic.Value(bool).init(false);
        defer shutdown.store(true, .release);

        var queue = watcher.EventQueue{};
        const watch_thread = try std.Thread.spawn(.{}, watcher.incrementalLoop, .{ &store, &explorer, &queue, root, &prerender, &shutdown });
        defer watch_thread.join();

        const isr_thread = try std.Thread.spawn(.{}, Prerender.isrLoop, .{ &prerender, &explorer, &store, &shutdown });
        defer isr_thread.join();

        const reap_thread = try std.Thread.spawn(.{}, reapLoop, .{ &agents, &shutdown });
        defer reap_thread.join();

        std.log.info("codedb: {d} files indexed, listening on :{d}", .{ store.currentSeq(), port });
        try server.serve(allocator, &store, &agents, &explorer, &queue, port, &prerender);
    } else if (std.mem.eql(u8, cmd, "mcp")) {
        var agents = AgentRegistry.init(allocator);
        defer agents.deinit();
        _ = try agents.register("__filesystem__");

        var prerender = Prerender.init(allocator);
        defer prerender.deinit();

        saveProjectInfo(allocator, data_dir, abs_root) catch {};

        var shutdown = std.atomic.Value(bool).init(false);

        var queue = watcher.EventQueue{};
        const scan_thread = try std.Thread.spawn(.{}, scanBg, .{ &store, &explorer, root, allocator });
        scan_thread.detach();

        const watch_thread = try std.Thread.spawn(.{}, watcher.incrementalLoop, .{ &store, &explorer, &queue, root, &prerender, &shutdown });
        const isr_thread = try std.Thread.spawn(.{}, Prerender.isrLoop, .{ &prerender, &explorer, &store, &shutdown });

        std.log.info("codedb2 mcp: root={s} files={d} data={s}", .{ abs_root, store.currentSeq(), data_dir });
        mcp_server.run(allocator, &store, &explorer, &agents, &prerender);

        // run() returned — stdin closed. Signal threads to stop, then join.
        shutdown.store(true, .release);
        watch_thread.join();
        isr_thread.join();
    } else {
        print("unknown command: {s}\n", .{cmd});
        std.process.exit(1);
    }
}

fn isCommand(arg: []const u8) bool {
    const commands = [_][]const u8{ "tree", "outline", "find", "search", "word", "hot", "serve", "mcp" };
    for (commands) |c| {
        if (std.mem.eql(u8, arg, c)) return true;
    }
    return false;
}

fn resolveRoot(root: []const u8, buf: *[std.fs.max_path_bytes]u8) ![]const u8 {
    if (std.mem.eql(u8, root, ".")) {
        return std.fs.cwd().realpath(".", buf) catch return error.ResolveFailed;
    }
    return std.fs.cwd().realpath(root, buf) catch return error.ResolveFailed;
}

fn getDataDir(allocator: std.mem.Allocator, abs_root: []const u8) ![]u8 {
    const hash = std.hash.Wyhash.hash(0, abs_root);
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch {
        return std.fmt.allocPrint(allocator, "{s}/.codedb", .{abs_root});
    };
    defer allocator.free(home);
    const dir = try std.fmt.allocPrint(allocator, "{s}/.codedb/projects/{x}", .{ home, hash });
    std.fs.cwd().makePath(dir) catch |err| {
        std.log.warn("could not create data dir {s}: {}", .{ dir, err });
    };
    return dir;
}

fn saveProjectInfo(allocator: std.mem.Allocator, data_dir: []const u8, abs_root: []const u8) !void {
    const info_path = try std.fmt.allocPrint(allocator, "{s}/project.txt", .{data_dir});
    defer allocator.free(info_path);
    const file = try std.fs.cwd().createFile(info_path, .{});
    defer file.close();
    try file.writeAll(abs_root);
}

fn printUsage() void {
    print(
        \\usage: codedb [root] <command> [args...]
        \\
        \\If root is omitted, uses current working directory.
        \\
        \\commands:
        \\  tree                        show file tree with symbols
        \\  outline <path>              show symbols in a file
        \\  find <name>                 find where a symbol is defined
        \\  search <query>              full-text search (case-insensitive)
        \\  word <identifier>           exact word lookup (inverted index)
        \\  hot                         recently modified files
        \\  serve                       start HTTP daemon on :7719
        \\  mcp                         start MCP server (JSON-RPC over stdio)
        \\
        \\Data is stored in ~/.codedb/projects/<hash>/ per project.
        \\
    , .{});
}

fn reapLoop(agents: *AgentRegistry, shutdown: *std.atomic.Value(bool)) void {
    while (!shutdown.load(.acquire)) {
        std.Thread.sleep(5 * std.time.ns_per_s);
        agents.reapStale(30_000);
    }
}

fn scanBg(store: *Store, explorer: *Explorer, root: []const u8, allocator: std.mem.Allocator) void {
    watcher.initialScan(store, explorer, root, allocator) catch |err| {
        std.log.warn("background scan failed: {}", .{err});
    };
}
