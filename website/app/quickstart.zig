const mer = @import("mer");
const h = mer.h;

pub const meta: mer.Meta = .{
    .title = "Quick Start",
    .description = "Get started with codedb in under 60 seconds. Install, configure MCP, and start querying.",
};

pub const prerender = true;

const page_node = page();

pub fn render(req: mer.Request) mer.Response {
    return mer.render(req.allocator, page_node);
}

fn page() h.Node {
    return h.div(.{ .class = "docs" }, .{
        h.div(.{ .class = "section-label" }, "Quick Start"),
        h.h1(.{ .class = "section-title" }, "Up and running in 60 seconds"),

        h.h2(.{}, "1. Install"),
        h.p(.{}, "On macOS and Linux, the installer downloads a signed codedb binary. Client configs, hooks, and DeepWiki stay off unless you opt in:"),
        h.pre(.{},
            \\curl -fsSL https://codedb.codegraff.com/install.sh | bash
            \\# optional: CODEDB_INSTALL_CLIENTS=1 CODEDB_INSTALL_HOOKS=1
        ),
        h.p(.{}, "On native Windows x86_64, run the signature-verifying installer in PowerShell:"),
        h.pre(.{},
            \\irm https://raw.githubusercontent.com/justrach/codedb/v0.2.5833/install/install.ps1 | iex
        ),
        h.p(.{}, "Supports macOS (ARM64, x86_64), Linux (ARM64, x86_64), and Windows (x86_64). macOS ARM64 binaries are codesigned and notarized."),

        h.h2(.{}, "2. MCP server (recommended)"),
        h.p(.{}, "Add codedb to your MCP client, or pass CODEDB_INSTALL_CLIENTS=1 to the installer. On Windows, configure the client with the absolute path to codedb.exe."),
        h.pre(.{},
            \\# MCP start
            \\codedb mcp /path/to/your/project
        ),
        h.p(.{}, "The MCP server indexes your codebase on startup, then serves all queries over JSON-RPC 2.0 stdio. Sub-millisecond responses, every time."),

        h.h2(.{}, "3. HTTP server"),
        h.p(.{}, "For direct API access or integration with custom tools:"),
        h.pre(.{},
            \\codedb serve /path/to/your/project
            \\# listening on 127.0.0.1:6767 — Host allowlist + loopback token required
        ),

        h.h2(.{}, "4. CLI commands"),
        h.p(.{}, "Quick one-off queries from the terminal:"),
        h.pre(.{},
            \\codedb tree /path/to/project          # file tree with symbol counts
            \\codedb outline src/main.zig           # symbols in a file
            \\codedb find AgentRegistry             # find symbol definitions
            \\codedb search "handleAuth"            # full-text search (trigram)
            \\codedb word Store                     # exact word lookup (O(1))
            \\codedb hot                            # recently modified files
        ),

        h.h2(.{}, "5. Example: agent explores a codebase"),
        h.p(.{}, "Here is how an AI agent uses codedb to understand a project:"),
        h.pre(.{},
            \\# 1. Get the file tree
            \\curl -H "Host: 127.0.0.1" -H "Authorization: Bearer $CODEDB_SERVE_TOKEN" \\
            \\  http://127.0.0.1:6767/explore/tree
            \\# -> src/main.zig      (zig, 55L, 4 symbols)
            \\#    src/store.zig     (zig, 156L, 12 symbols)
            \\#    src/agent.zig     (zig, 135L, 8 symbols)
            \\
            \\# 2. Drill into a file
            \\curl -H "Host: 127.0.0.1" -H "Authorization: Bearer $CODEDB_SERVE_TOKEN" \\
            \\  "http://127.0.0.1:6767/explore/outline?path=src/store.zig"
            \\
            \\# 3. Find a symbol
            \\curl -H "Host: 127.0.0.1" -H "Authorization: Bearer $CODEDB_SERVE_TOKEN" \\
            \\  "http://127.0.0.1:6767/explore/symbol?name=AgentRegistry"
            \\
            \\# 4. Full-text search
            \\curl -H "Host: 127.0.0.1" -H "Authorization: Bearer $CODEDB_SERVE_TOKEN" \\
            \\  "http://127.0.0.1:6767/explore/search?q=handleAuth"
        ),

        h.h2(.{}, "MCP tools reference"),
        h.p(.{}, "Core tools available over the Model Context Protocol:"),
        h.table(.{ .class = "status-table" }, .{
            h.tbody(.{}, .{
                h.tr(.{}, .{ h.td(.{}, .{ h.code(.{}, "codedb_tree") }), h.td(.{}, "Full file tree with language, line counts, symbol counts") }),
                h.tr(.{}, .{ h.td(.{}, .{ h.code(.{}, "codedb_outline") }), h.td(.{}, "Symbols in a file: functions, structs, imports, with line numbers") }),
                h.tr(.{}, .{ h.td(.{}, .{ h.code(.{}, "codedb_symbol") }), h.td(.{}, "Find where a symbol is defined across the codebase") }),
                h.tr(.{}, .{ h.td(.{}, .{ h.code(.{}, "codedb_search") }), h.td(.{}, "Trigram-accelerated full-text search") }),
                h.tr(.{}, .{ h.td(.{}, .{ h.code(.{}, "codedb_word") }), h.td(.{}, "O(1) inverted index word lookup") }),
                h.tr(.{}, .{ h.td(.{}, .{ h.code(.{}, "codedb_hot") }), h.td(.{}, "Most recently modified files") }),
                h.tr(.{}, .{ h.td(.{}, .{ h.code(.{}, "codedb_deps") }), h.td(.{}, "Reverse dependency graph") }),
                h.tr(.{}, .{ h.td(.{}, .{ h.code(.{}, "codedb_read") }), h.td(.{}, "Read file content") }),
                h.tr(.{}, .{ h.td(.{}, .{ h.code(.{}, "codedb_changes") }), h.td(.{}, "Changed files since a sequence number") }),
                h.tr(.{}, .{ h.td(.{}, .{ h.code(.{}, "codedb_status") }), h.td(.{}, "Index status (file count, current sequence)") }),
                h.tr(.{}, .{ h.td(.{}, .{ h.code(.{}, "codedb_snapshot") }), h.td(.{}, "Local JSON snapshot for faster MCP startup; never uploaded") }),
                h.tr(.{}, .{ h.td(.{}, .{ h.code(.{}, "codedb_bundle") }), h.td(.{}, "Batch multiple queries in one call") }),
                h.tr(.{}, .{ h.td(.{}, .{ h.code(.{}, "codedb_projects") }), h.td(.{}, "List all indexed local projects") }),
                h.tr(.{}, .{ h.td(.{}, .{ h.code(.{}, "codedb_index") }), h.td(.{}, "Index a new local folder") }),
            }),
        }),

        h.h2(.{}, "Building from source"),
        h.p(.{}, "Requires Zig 0.15+:"),
        h.pre(.{},
            \\git clone https://github.com/justrach/codedb.git
            \\cd codedb
            \\zig build                              # debug build
            \\zig build -Doptimize=ReleaseFast       # release build
            \\zig build test                         # run tests
        ),

        h.div(.{ .class = "hero-actions" }, .{
            h.a(.{ .href = "/benchmarks", .class = "btn" }, "See benchmarks"),
            h.a(.{ .href = "https://github.com/justrach/codedb", .class = "btn btn-outline" }, "GitHub"),
        }),
    });
}
