const mer = @import("mer");
const h = mer.h;

pub const meta: mer.Meta = .{
    .title = "Privacy & Telemetry",
    .description = "What data codedb collects, how it's used, and how to opt out.",
};

pub const prerender = true;

const page_node = page();

pub fn render(req: mer.Request) mer.Response {
    return mer.render(req.allocator, page_node);
}

fn page() h.Node {
    return h.div(.{ .class = "docs" }, .{
        h.div(.{ .class = "section-label" }, "Privacy & Telemetry"),
        h.h1(.{ .class = "section-title" }, "Your code stays on your machine"),

        h.h2(.{}, "What codedb does"),
        h.p(.{}, "codedb is a local code intelligence server. It indexes your codebase on your machine and serves queries over stdio (MCP) or localhost HTTP. No code, file contents, or query data ever leaves your machine."),

        h.h2(.{}, "Data that stays local"),
        h.div(.{ .class = "prop-grid" }, .{
            h.div(.{ .class = "prop-card" }, .{
                h.div(.{ .class = "prop-title" }, "Source code"),
                h.div(.{ .class = "prop-desc" }, "Never transmitted. All indexing and queries happen in-process."),
            }),
            h.div(.{ .class = "prop-card" }, .{
                h.div(.{ .class = "prop-title" }, "File paths"),
                h.div(.{ .class = "prop-desc" }, "Never transmitted. Used only for local index lookups."),
            }),
            h.div(.{ .class = "prop-card" }, .{
                h.div(.{ .class = "prop-title" }, "Search queries"),
                h.div(.{ .class = "prop-desc" }, "Never transmitted. Processed entirely in local memory."),
            }),
            h.div(.{ .class = "prop-card" }, .{
                h.div(.{ .class = "prop-title" }, "Index data"),
                h.div(.{ .class = "prop-desc" }, "Trigrams, outlines, word index. All stored in local memory only."),
            }),
        }),

        h.h2(.{}, "Network access"),
        h.p(.{}, "codedb makes zero network requests during normal operation. The MCP server communicates over stdio. The HTTP server binds to localhost only."),
        h.p(.{}, "The only network activity is the install script, which downloads the binary from codedb.codegraff.com."),

        h.h2(.{}, "Website telemetry"),
        h.p(.{}, "This website (codedb.codegraff.com) uses basic analytics to understand traffic patterns. No personal data is collected. No cookies are set. No third-party trackers are loaded."),

        h.h2(.{}, "Snapshots"),
        h.p(.{}, "The codedb_snapshot tool generates a JSON representation of your codebase for faster MCP startup. This file is stored locally and is never uploaded anywhere."),

        h.h2(.{}, "Open source"),
        h.p(.{}, "codedb is fully open source. You can audit every line of code to verify these claims."),
        h.div(.{ .class = "hero-actions" }, .{
            h.a(.{ .href = "https://github.com/justrach/codedb", .class = "btn" }, "View source on GitHub"),
            h.a(.{ .href = "/quickstart", .class = "btn btn-outline" }, "Get started"),
        }),
    });
}
