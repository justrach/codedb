const std = @import("std");
const cio = @import("cio.zig");
const sty = @import("style.zig");

pub const Out = struct {
    file: cio.File,
    alloc: std.mem.Allocator,
    buf: [65536]u8 = undefined,
    used: usize = 0,
    // When set, flush() appends here instead of writing to `file`. Lets a warm
    // daemon capture a command's full rendered output (run via runQuery) and frame
    // it back to a CLI client over a socket — reusing the exact rendering the cold
    // CLI uses. null for the normal stdout path.
    sink: ?*std.ArrayList(u8) = null,

    pub fn p(self: *Out, comptime fmt: []const u8, args: anytype) void {
        // Fast path: format directly into the remaining buffer window.
        const remaining = self.buf[self.used..];
        if (std.fmt.bufPrint(remaining, fmt, args)) |s| {
            self.used += s.len;
            return;
        } else |_| {}
        // Either doesn't fit OR remaining is too small. Flush, retry from start.
        self.flush();
        if (std.fmt.bufPrint(&self.buf, fmt, args)) |s| {
            self.used = s.len;
            return;
        } else |_| {}
        // Single message larger than 64KB — fall back to one-shot heap alloc.
        const big = std.fmt.allocPrint(self.alloc, fmt, args) catch return;
        defer self.alloc.free(big);
        if (self.sink) |snk| {
            snk.appendSlice(self.alloc, big) catch {};
        } else {
            self.file.writeAll(big) catch {};
        }
    }

    pub fn flush(self: *Out) void {
        if (self.used == 0) return;
        if (self.sink) |snk| {
            snk.appendSlice(self.alloc, self.buf[0..self.used]) catch {};
        } else {
            self.file.writeAll(self.buf[0..self.used]) catch {};
        }
        self.used = 0;
    }

    /// Print + flush + exit. `std.process.exit(_)` skips the deferred
    /// `out.flush()`, which used to silently swallow usage and error
    /// messages on any failure path — `codedb` with no args printed
    /// nothing and just exited 1 (#504). Use this anywhere we'd
    /// otherwise call exit() directly after writing user-facing output.
    pub fn exitWithFlush(self: *Out, code: u8) noreturn {
        self.flush();
        std.process.exit(code);
    }
};

pub fn printUsage(out: *Out, s: sty.Style) void {
    out.p(
        \\
        \\{s}codedb{s}  code intelligence server
        \\
        \\  {s}usage:{s} codedb [root] <command> [args...]
        \\
        \\  {s}commands:{s}
        \\    {s}tree{s}                      show file tree with language and symbol counts
        \\    {s}outline{s} {s}<path>{s}         list all symbols in a file
        \\    {s}find{s}    {s}<name>{s}         find where a symbol is defined
        \\    {s}search{s}  {s}<query>{s}        full-text search (trigram, case-insensitive)
        \\    {s}word{s}    {s}<identifier>{s}   exact word lookup via inverted index
        \\    {s}read{s}    {s}<path>{s}         file contents (optionally -L FROM-TO, --compact)
        \\
    , .{
        s.bold, s.reset,
        s.dim,  s.reset,
        s.dim,  s.reset,
        s.cyan, s.reset,
        s.cyan, s.reset,
        s.dim,  s.reset,
        s.cyan, s.reset,
        s.dim,  s.reset,
        s.cyan, s.reset,
        s.dim,  s.reset,
        s.cyan, s.reset,
        s.dim,  s.reset,
        s.cyan, s.reset,
        s.dim,  s.reset,
    });
    out.p(
        \\    {s}hot{s}                       recently modified files
        \\    {s}status{s}                    index size, store seq, and index state
        \\    {s}symbol{s}  <name>            where a symbol is defined (all matches; --body for source)
        \\    {s}callers{s}  <name>           every call site of a symbol
        \\    {s}deps{s}  <path>              dependency graph (--depends-on, --transitive, --max-depth N)
        \\    {s}glob{s}  <pattern>           match indexed paths by glob
        \\    {s}ls{s}  [path]                list a directory's indexed children
        \\    {s}list_dir{s}  [path]          live BFS listing (gitignore, 10k cap; not the index)
        \\
    , .{
        s.cyan, s.reset,
        s.cyan, s.reset,
        s.cyan, s.reset,
        s.cyan, s.reset,
        s.cyan, s.reset,
        s.cyan, s.reset,
        s.cyan, s.reset,
        s.cyan, s.reset,
    });
    out.p(
        \\    {s}file{s}  <fuzzy-name>        fuzzy file-name search
        \\    {s}context{s}  <task...>        task-shaped orientation bundle
        \\    {s}explain{s}  <name>           definition body + callers (alias: around)
        \\    {s}callpath{s} <from> <to>      shortest resolved call chain (alias: path)
        \\    {s}serve{s}                     HTTP daemon on :6767
        \\    {s}mcp{s}                       JSON-RPC/MCP server over stdio
        \\    {s}update{s}                    self-update to the latest verified release
        \\    {s}nuke{s}                      uninstall codedb, clear caches, and deregister integrations
        \\    {s}codex{s}                     CodeDB-first Codex setup (install|uninstall|verify)
        \\
    , .{
        s.cyan, s.reset,
        s.cyan, s.reset,
        s.cyan, s.reset,
        s.cyan, s.reset,
        s.cyan, s.reset,
        s.cyan, s.reset,
        s.cyan, s.reset,
        s.cyan, s.reset,
        s.cyan, s.reset,
    });
    out.p(
        \\  {s}options:{s}
        \\    {s}--no-telemetry{s}             disable usage telemetry (or set CODEDB_NO_TELEMETRY)
        \\    {s}--config-file <path>{s}       load config overrides from <path> (default: ./.codedbrc)
        \\
        \\  If root is omitted, uses current working directory.
        \\  Data stored in {s}~/.codedb/projects/<hash>/{s}
        \\
        \\  exit codes: 0 = success (incl. a valid query that finds nothing),
        \\              1 = usage error, invalid input, or operational failure.
        \\
        \\
    , .{
        s.dim,  s.reset,
        s.cyan, s.reset,
        s.cyan, s.reset,
        s.dim,  s.reset,
    });
}
