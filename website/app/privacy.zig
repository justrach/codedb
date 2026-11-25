const mer = @import("mer");
const h = mer.h;

pub const meta: mer.Meta = .{
    .title = "Privacy & Telemetry",
    .description = "What data codedb keeps local, how hosted embeddings stay zero-data-retention, and how to opt out.",
};

pub const prerender = true;

const page_node = page();

pub fn render(req: mer.Request) mer.Response {
    return mer.render(req.allocator, page_node);
}

fn page() h.Node {
    return h.div(.{ .class = "docs" }, .{
        h.div(.{ .class = "section-label" }, "Privacy & Telemetry"),
        h.h1(.{ .class = "section-title" }, "Local indexes. Hosted embeddings are zero-data-retention."),

        h.h2(.{}, "What codedb does"),
        h.p(.{}, "codedb is a local code intelligence server. It indexes your codebase on your machine and serves queries over stdio (MCP) or a loopback HTTP server. Indexing, outlines, and file reads stay on the machine. Default hybrid retrieval uses hosted embeddings that are zero-data-retention (ZDR)."),

        h.h2(.{}, "Data that stays local"),
        h.div(.{ .class = "prop-grid" }, .{
            h.div(.{ .class = "prop-card" }, .{
                h.div(.{ .class = "prop-title" }, "Source code"),
                h.div(.{ .class = "prop-desc" }, "Indexed in-process. Hybrid retrieval may send bounded snippets only as part of a ZDR embedding request; semantic=local sends none."),
            }),
            h.div(.{ .class = "prop-card" }, .{
                h.div(.{ .class = "prop-title" }, "File paths"),
                h.div(.{ .class = "prop-desc" }, "Used for local lookups. Hybrid retrieval may send up to 24 relative paths with bounded snippets to the ZDR embedding service."),
            }),
            h.div(.{ .class = "prop-card" }, .{
                h.div(.{ .class = "prop-title" }, "Search queries"),
                h.div(.{ .class = "prop-desc" }, "Processed locally. queries.log stores a SHA-256 of the query, not the raw text, mode 0600."),
            }),
            h.div(.{ .class = "prop-card" }, .{
                h.div(.{ .class = "prop-title" }, "Index data"),
                h.div(.{ .class = "prop-desc" }, "Trigrams, outlines, word index, optional ANN sidecar. Stored under ~/.codedb on this machine."),
            }),
        }),

        h.h2(.{}, "Retrieval: hybrid default, zero-data-retention"),
        h.p(.{}, "codedb_context defaults to semantic=hybrid. Local BM25, trigram, symbol, and graph retrieval always run first. Hybrid then sends the task plus a fixed public calibration string when a local ANN sidecar exists, or the task plus at most 24 locally selected relative paths and bounded snippets otherwise, to embeddings.wiki.codes. The hosted service is zero-data-retention: it does not store the repository, request body, candidate paths, or vectors."),
        h.p(.{}, "Pass semantic=local or --local for an entirely on-device call. Do not set embeddings URLs via MCP arguments."),

        h.h2(.{}, "Telemetry: opt-in, aggregate only"),
        h.p(.{}, "Usage telemetry is off until you set CODEDB_TELEMETRY=1. When enabled, codedb writes aggregate tool-call counts, latency, and startup stats to ~/.codedb/telemetry.ndjson and may sync that file to codedb.codegraff.com/telemetry/ingest. No source code, file contents, file paths, or search queries are collected. CODEDB_NO_TELEMETRY=1 and --no-telemetry still force it off."),

        h.h2(.{}, "Network access"),
        h.p(.{}, "Indexing, outlines, and file reads make zero network requests. Default hybrid retrieval makes one ZDR embedding request to embeddings.wiki.codes. The HTTP server binds 127.0.0.1 only."),
        h.p(.{}, "Installation and opted-in updates fetch release metadata, binaries, checksums, and Ed25519 signatures from GitHub Releases or codedb.codegraff.com. Auto-update is off unless CODEDB_AUTO_UPDATE=1; the in-process updater never re-runs installer side effects."),

        h.h2(.{}, "Website telemetry"),
        h.p(.{}, "This website (codedb.codegraff.com) uses basic analytics to understand traffic patterns. No personal data is collected. No cookies are set. No third-party trackers are loaded."),

        h.h2(.{}, "Snapshots"),
        h.p(.{}, "The codedb_snapshot tool generates a JSON representation of the local index for faster MCP startup. This file is stored locally and is never uploaded."),

        h.h2(.{}, "Open source"),
        h.p(.{}, "codedb is fully open source. You can audit every line of code to verify these claims."),
        h.div(.{ .class = "hero-actions" }, .{
            h.a(.{ .href = "https://github.com/justrach/codedb", .class = "btn" }, "View source on GitHub"),
            h.a(.{ .href = "/quickstart", .class = "btn btn-outline" }, "Get started"),
        }),
    });
}
