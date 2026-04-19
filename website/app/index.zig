const mer = @import("mer");

pub const meta: mer.Meta = .{
    .title = "codedb — Code intelligence for AI agents. Zig core. Sub-millisecond queries.",
    .description = "Code intelligence server for AI agents. 12 MCP tools, trigram search, dependency graph, sub-millisecond queries. Pure Zig. Zero dependencies.",
};

pub const prerender = true;

pub fn render(req: mer.Request) mer.Response {
    _ = req;
    return .{ .status = .ok, .content_type = .html, .body = html };
}

const html =
    \\<!DOCTYPE html>
    \\<html lang="en">
    \\<head>
    \\  <meta charset="UTF-8">
    \\  <meta name="viewport" content="width=device-width, initial-scale=1.0">
    \\  <title>codedb — Code intelligence for AI agents</title>
    \\  <link rel="preconnect" href="https://fonts.googleapis.com">
    \\  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    \\  <link href="https://fonts.googleapis.com/css2?family=Space+Grotesk:wght@400;500;600;700&family=Inter:wght@400;500;600&family=JetBrains+Mono:wght@400;500&display=swap" rel="stylesheet">
    \\  <style>
    \\    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
    \\
    \\    :root {
    \\      --bg: #f9f8f6;
    \\      --bg2: #f2f0ec;
    \\      --bg3: #e9e5de;
    \\      --text: #0e0d0b;
    \\      --muted: #8a8478;
    \\      --border: #ddd9d2;
    \\      --accent: #3b82f6;
    \\      --accent-dim: rgba(59,130,246,0.12);
    \\      --green: #2d7a3f;
    \\      --dark: #0e0d0b;
    \\      --dark2: #1a1916;
    \\      --dark3: #252320;
    \\      --mono: 'JetBrains Mono', monospace;
    \\      --sans: 'Inter', sans-serif;
    \\      --display: 'Space Grotesk', sans-serif;
    \\    }
    \\
    \\    html { scroll-behavior: smooth; }
    \\    body { background: var(--bg); color: var(--text); font-family: var(--sans); min-height: 100vh; line-height: 1.6; overflow-x: hidden; }
    \\    a { color: inherit; text-decoration: none; }
    \\    code { font-family: var(--mono); font-size: 0.85em; background: var(--bg3); border: 1px solid var(--border); border-radius: 4px; padding: 2px 7px; color: var(--accent); }
    \\    pre { background: var(--bg2); border: 1px solid var(--border); border-radius: 8px; padding: 20px 24px; overflow-x: auto; font-family: var(--mono); font-size: 13px; line-height: 1.7; color: var(--text); margin: 16px 0; }
    \\    pre code { background: none; border: none; padding: 0; font-size: inherit; color: inherit; }
    \\
    \\    /* Nav */
    \\    nav { position: sticky; top: 0; z-index: 100; background: rgba(249,248,246,0.88); backdrop-filter: blur(12px); border-bottom: 1px solid var(--border); }
    \\    .nav-inner { max-width: 900px; margin: 0 auto; padding: 0 32px; display: flex; align-items: center; justify-content: space-between; height: 60px; }
    \\    .wordmark { font-family: var(--display); font-size: 16px; font-weight: 800; letter-spacing: -0.02em; }
    \\    .wordmark em { font-style: normal; color: var(--accent); }
    \\    .nav-links { display: flex; gap: 32px; align-items: center; }
    \\    .nav-links a { font-size: 13px; font-weight: 500; color: var(--muted); letter-spacing: 0.01em; transition: color 0.15s; }
    \\    .nav-links a:hover { color: var(--text); }
    \\    .nav-cta { font-family: var(--display); font-size: 13px !important; font-weight: 700 !important; color: #fff !important; background: var(--accent); padding: 8px 18px; border-radius: 4px; }
    \\    .nav-cta:hover { opacity: 0.88; }
    \\    .nav-burger { display: none; flex-direction: column; gap: 5px; background: none; border: none; cursor: pointer; padding: 4px; }
    \\    .nav-burger span { display: block; width: 22px; height: 2px; background: var(--text); border-radius: 2px; transition: transform 0.2s, opacity 0.2s; }
    \\    .nav-burger.open span:nth-child(1) { transform: translateY(7px) rotate(45deg); }
    \\    .nav-burger.open span:nth-child(2) { opacity: 0; }
    \\    .nav-burger.open span:nth-child(3) { transform: translateY(-7px) rotate(-45deg); }
    \\    @media (max-width: 640px) {
    \\      .nav-burger { display: flex; }
    \\      .nav-links { display: none; flex-direction: column; gap: 0; position: absolute; top: 60px; left: 0; right: 0; background: rgba(249,248,246,0.97); backdrop-filter: blur(12px); border-bottom: 1px solid var(--border); padding: 8px 0; }
    \\      .nav-links.open { display: flex; }
    \\      .nav-links a { padding: 14px 24px; font-size: 15px; }
    \\      .nav-cta { margin: 8px 24px 12px; padding: 12px 20px; border-radius: 4px; text-align: center; }
    \\    }
    \\
    \\    /* Hero */
    \\    .hero { max-width: 900px; margin: 0 auto; padding: 80px 32px 0; }
    \\    .hero-label { font-family: var(--mono); font-size: 11px; font-weight: 500; letter-spacing: 0.14em; text-transform: uppercase; color: var(--accent); margin-bottom: 20px; display: flex; align-items: center; gap: 10px; }
    \\    .hero-label::before { content: ''; display: inline-block; width: 20px; height: 1px; background: var(--accent); }
    \\    .hero-headline { font-family: var(--display); font-size: clamp(36px, 6vw, 64px); font-weight: 800; letter-spacing: -0.04em; line-height: 1.0; color: var(--text); margin-bottom: 16px; }
    \\    .hero-headline .hl { color: var(--accent); }
    \\    .hero-sub { font-size: 18px; color: var(--muted); max-width: 560px; line-height: 1.6; margin-bottom: 32px; }
    \\    .hero-install { background: var(--bg2); border: 1px solid var(--border); border-radius: 8px; padding: 16px 20px; font-family: var(--mono); font-size: 14px; color: var(--text); margin-bottom: 16px; display: flex; align-items: center; gap: 12px; max-width: 560px; overflow-x: auto; }
    \\    .hero-install .prompt { color: var(--accent); user-select: none; }
    \\    .hero-actions { display: flex; gap: 12px; flex-wrap: wrap; margin-bottom: 64px; }
    \\    .btn { display: inline-flex; align-items: center; font-family: var(--display); font-size: 14px; font-weight: 700; padding: 12px 24px; border-radius: 4px; background: var(--accent); color: #fff; transition: opacity 0.15s, transform 0.15s; }
    \\    .btn:hover { opacity: 0.88; transform: translateY(-1px); }
    \\    .btn-outline { background: transparent; border: 1px solid var(--border); color: var(--muted); font-weight: 500; }
    \\    .btn-outline:hover { color: var(--text); border-color: var(--text); transform: none; }
    \\
    \\    /* Stats */
    \\    .stat-row { display: grid; grid-template-columns: repeat(4,1fr); border-top: 1px solid var(--border); max-width: 900px; margin: 0 auto; padding: 0 32px; }
    \\    @media (max-width: 700px) { .stat-row { grid-template-columns: repeat(2,1fr); } }
    \\    .stat-cell { padding: 32px 24px 40px 0; border-right: 1px solid var(--border); }
    \\    .stat-cell:last-child { border-right: none; }
    \\    .stat-val { font-family: var(--display); font-size: clamp(28px, 4vw, 44px); font-weight: 800; letter-spacing: -0.04em; color: var(--text); line-height: 1; margin-bottom: 4px; }
    \\    .stat-val .unit { font-size: 0.45em; font-weight: 600; color: var(--muted); letter-spacing: 0; vertical-align: super; margin-left: 2px; }
    \\    .stat-label { font-family: var(--mono); font-size: 11px; color: var(--muted); letter-spacing: 0.08em; text-transform: uppercase; margin-bottom: 4px; }
    \\    .stat-delta { font-family: var(--mono); font-size: 11px; color: var(--accent); letter-spacing: 0.02em; }
    \\
    \\    /* Sections */
    \\    .section { max-width: 900px; margin: 0 auto; padding: 80px 32px 0; }
    \\    .section-label { font-family: var(--mono); font-size: 11px; font-weight: 500; letter-spacing: 0.12em; text-transform: uppercase; color: var(--accent); margin-bottom: 12px; }
    \\    .section-title { font-family: var(--display); font-size: clamp(22px, 4vw, 36px); font-weight: 700; letter-spacing: -0.02em; margin-bottom: 24px; }
    \\    .section-desc { color: var(--muted); font-size: 15px; max-width: 600px; line-height: 1.7; margin-bottom: 32px; }
    \\
    \\    /* Feature grid */
    \\    .feature-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; margin-bottom: 32px; }
    \\    @media (max-width: 600px) { .feature-grid { grid-template-columns: 1fr; } }
    \\    .feature-card { background: var(--bg2); border: 1px solid var(--border); border-radius: 6px; padding: 20px 22px; }
    \\    .feature-card h3 { font-family: var(--display); font-size: 15px; font-weight: 700; color: var(--text); margin-bottom: 6px; }
    \\    .feature-card p { font-size: 13px; color: var(--muted); line-height: 1.6; }
    \\
    \\    /* Tables */
    \\    .bench-table { width: 100%; border-collapse: collapse; margin: 24px 0; font-size: 13px; }
    \\    .bench-table th { text-align: left; padding: 10px 12px; color: var(--muted); font-family: var(--mono); font-size: 11px; font-weight: 500; text-transform: uppercase; letter-spacing: 0.08em; border-bottom: 1px solid var(--border); }
    \\    .bench-table td { padding: 10px 12px; border-bottom: 1px solid var(--border); font-family: var(--mono); font-size: 12px; }
    \\    .bench-table tr.highlight td { color: var(--accent); font-weight: 600; }
    \\    .bench-table .fast { color: var(--accent); font-weight: 600; }
    \\    .bench-table .na { color: var(--border); }
    \\
    \\    /* Tool list */
    \\    .tool-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 8px; margin: 24px 0; }
    \\    @media (max-width: 600px) { .tool-grid { grid-template-columns: 1fr; } }
    \\    .tool-item { display: flex; align-items: baseline; gap: 10px; padding: 10px 14px; background: var(--bg2); border: 1px solid var(--border); border-radius: 4px; }
    \\    .tool-name { font-family: var(--mono); font-size: 12px; font-weight: 500; color: var(--accent); white-space: nowrap; }
    \\    .tool-desc { font-size: 12px; color: var(--muted); }
    \\
    \\    /* CTA */
    \\    .cta-section { margin: 80px auto 0; max-width: 900px; padding: 48px 32px; }
    \\    .cta-inner { padding: 48px; background: var(--bg2); border: 1px solid var(--border); border-radius: 8px; text-align: center; }
    \\    .cta-title { font-family: var(--display); font-size: 26px; font-weight: 700; letter-spacing: -0.02em; margin-bottom: 12px; }
    \\    .cta-sub { color: var(--muted); font-size: 14px; margin-bottom: 28px; }
    \\
    \\    /* Footer */
    \\    .layout-footer { max-width: 900px; margin: 0 auto; padding: 20px 32px 60px; border-top: 1px solid var(--border); font-size: 12px; color: var(--muted); text-align: center; font-family: var(--mono); letter-spacing: 0.02em; }
    \\    .layout-footer a { color: var(--muted); }
    \\    .layout-footer a:hover { color: var(--text); }
    \\  </style>
    \\</head>
    \\<body>
    \\
    \\<!-- Nav -->
    \\<nav>
    \\  <div class="nav-inner">
    \\    <a href="/" class="wordmark">code<em>db</em></a>
    \\    <button class="nav-burger" id="burger" aria-label="Menu">
    \\      <span></span><span></span><span></span>
    \\    </button>
    \\    <div class="nav-links" id="nav-links">
    \\      <a href="/benchmarks">Benchmarks</a>
    \\      <a href="/v0.2.572" style="color:var(--accent);font-weight:600;">v0.2.572</a>
    \\      <a href="/quickstart">Install</a>
    \\      <a href="https://github.com/justrach/codedb">GitHub</a>
    \\      <a href="/quickstart" class="nav-cta">Get started</a>
    \\    </div>
    \\  </div>
    \\</nav>
    \\
    \\<!-- Hero -->
    \\<div class="hero">
    \\  <div class="hero-label">Code intelligence server</div>
    \\  <div class="hero-headline">
    \\    Code intelligence<br>for <span class="hl">AI agents</span>.
    \\  </div>
    \\  <div class="hero-sub">Sub-millisecond queries. Zero dependencies. Pure Zig. 12 MCP tools that give your agent structural understanding of any codebase.</div>
    \\  <div class="hero-install">
    \\    <span class="prompt">$</span> curl -fsSL https://codedb.codegraff.com/install.sh | bash
    \\  </div>
    \\  <div class="hero-actions">
    \\    <a href="/quickstart" class="btn">Get started</a>
    \\    <a href="https://github.com/justrach/codedb" class="btn btn-outline">GitHub</a>
    \\  </div>
    \\</div>
    \\
    \\<!-- Stats -->
    \\<div class="stat-row">
    \\  <div class="stat-cell">
    \\    <div class="stat-label">Query latency</div>
    \\    <div class="stat-val">0.05<span class="unit">ms</span></div>
    \\    <div class="stat-delta">vs 55ms CLI tools</div>
    \\  </div>
    \\  <div class="stat-cell">
    \\    <div class="stat-label">Token reduction</div>
    \\    <div class="stat-val">1,500<span class="unit">x</span></div>
    \\    <div class="stat-delta">fewer tokens than grep</div>
    \\  </div>
    \\  <div class="stat-cell">
    \\    <div class="stat-label">MCP Tools</div>
    \\    <div class="stat-val">12</div>
    \\    <div class="stat-delta">tree, outline, search, deps...</div>
    \\  </div>
    \\  <div class="stat-cell">
    \\    <div class="stat-label">2M lines indexed</div>
    \\    <div class="stat-val">50<span class="unit">s</span></div>
    \\    <div class="stat-delta">then &lt;2ms incremental</div>
    \\  </div>
    \\</div>
    \\
    \\<!-- What it does -->
    \\<div class="section">
    \\  <div class="section-label">12 MCP tools</div>
    \\  <div class="section-title">Everything an agent needs</div>
    \\  <div class="section-desc">codedb indexes your codebase on startup &mdash; outlines, trigram search, word index, dependency graph &mdash; and serves it all over the Model Context Protocol. Your AI agent gets structural understanding, not raw text.</div>
    \\  <div class="tool-grid">
    \\    <div class="tool-item"><span class="tool-name">codedb_tree</span> <span class="tool-desc">File tree with symbol counts</span></div>
    \\    <div class="tool-item"><span class="tool-name">codedb_outline</span> <span class="tool-desc">Functions, structs, imports</span></div>
    \\    <div class="tool-item"><span class="tool-name">codedb_symbol</span> <span class="tool-desc">Find definitions across codebase</span></div>
    \\    <div class="tool-item"><span class="tool-name">codedb_search</span> <span class="tool-desc">Trigram-accelerated full-text</span></div>
    \\    <div class="tool-item"><span class="tool-name">codedb_word</span> <span class="tool-desc">O(1) inverted word index</span></div>
    \\    <div class="tool-item"><span class="tool-name">codedb_hot</span> <span class="tool-desc">Recently modified files</span></div>
    \\    <div class="tool-item"><span class="tool-name">codedb_deps</span> <span class="tool-desc">Reverse dependency graph</span></div>
    \\    <div class="tool-item"><span class="tool-name">codedb_read</span> <span class="tool-desc">Read file content</span></div>
    \\    <div class="tool-item"><span class="tool-name">codedb_edit</span> <span class="tool-desc">Atomic line-range edits</span></div>
    \\    <div class="tool-item"><span class="tool-name">codedb_changes</span> <span class="tool-desc">Changed files since sequence</span></div>
    \\    <div class="tool-item"><span class="tool-name">codedb_status</span> <span class="tool-desc">Index status and health</span></div>
    \\    <div class="tool-item"><span class="tool-name">codedb_snapshot</span> <span class="tool-desc">Full codebase JSON snapshot</span></div>
    \\  </div>
    \\</div>
    \\
    \\<!-- Features -->
    \\<div class="section">
    \\  <div class="section-label">Why codedb</div>
    \\  <div class="section-title">Index once, query thousands of times</div>
    \\  <div class="feature-grid">
    \\    <div class="feature-card">
    \\      <h3>Trigram search index</h3>
    \\      <p>Pre-built trigram index for instant full-text search. No filesystem scanning on every query.</p>
    \\    </div>
    \\    <div class="feature-card">
    \\      <h3>Structural parsing</h3>
    \\      <p>Extracts functions, structs, imports with line numbers. Zig, Python, TypeScript/JavaScript, Go, Dart, and more.</p>
    \\    </div>
    \\    <div class="feature-card">
    \\      <h3>Dependency graph</h3>
    \\      <p>Reverse dependency tracking &mdash; which files import this file. Navigate the codebase structurally.</p>
    \\    </div>
    \\    <div class="feature-card">
    \\      <h3>Inverted word index</h3>
    \\      <p>O(1) hash lookup for exact identifier matches. Instant symbol discovery across all files.</p>
    \\    </div>
    \\    <div class="feature-card">
    \\      <h3>File watcher</h3>
    \\      <p>Polls every 2s with smart directory filtering. Single-file re-index under 2ms. Always up to date.</p>
    \\    </div>
    \\    <div class="feature-card">
    \\      <h3>Multi-agent support</h3>
    \\      <p>File locking, heartbeats, stale agent reaping. Multiple AI agents on the same codebase, safely.</p>
    \\    </div>
    \\    <div class="feature-card">
    \\      <h3>Zero dependencies</h3>
    \\      <p>Pure Zig. Single binary. No SQLite, no tree-sitter, no runtime. Cross-compiles to macOS + Linux.</p>
    \\    </div>
    \\    <div class="feature-card">
    \\      <h3>Portable snapshots</h3>
    \\      <p>Full codebase snapshot for instant MCP startup. No re-indexing needed when restarting the server.</p>
    \\    </div>
    \\  </div>
    \\</div>
    \\
    \\<!-- Benchmark preview -->
    \\<div class="section">
    \\  <div class="section-label">Benchmarks</div>
    \\  <div class="section-title">Sub-millisecond, every query</div>
    \\  <div class="section-desc">Measured on Apple M4 Pro, 48GB RAM. MCP = pre-indexed warm queries (20 iterations avg).</div>
    \\
    \\  <table class="bench-table">
    \\    <thead>
    \\      <tr><th>Query</th><th>codedb MCP</th><th>codedb CLI</th><th>ast-grep</th><th>ripgrep</th><th>grep</th></tr>
    \\    </thead>
    \\    <tbody>
    \\      <tr class="highlight"><td>File tree</td><td class="fast">0.04 ms</td><td>52.9 ms</td><td class="na">&mdash;</td><td class="na">&mdash;</td><td class="na">&mdash;</td></tr>
    \\      <tr class="highlight"><td>Symbol search</td><td class="fast">0.10 ms</td><td>54.1 ms</td><td>3.2 ms</td><td>6.3 ms</td><td>6.5 ms</td></tr>
    \\      <tr class="highlight"><td>Full-text search</td><td class="fast">0.05 ms</td><td>60.7 ms</td><td>3.2 ms</td><td>5.3 ms</td><td>6.6 ms</td></tr>
    \\      <tr class="highlight"><td>Word index</td><td class="fast">0.04 ms</td><td>59.7 ms</td><td class="na">n/a</td><td>7.2 ms</td><td>6.5 ms</td></tr>
    \\      <tr class="highlight"><td>Structural outline</td><td class="fast">0.05 ms</td><td>53.5 ms</td><td>3.1 ms</td><td class="na">&mdash;</td><td>2.4 ms</td></tr>
    \\      <tr class="highlight"><td>Dependency graph</td><td class="fast">0.05 ms</td><td>2.2 ms</td><td class="na">n/a</td><td class="na">n/a</td><td class="na">n/a</td></tr>
    \\    </tbody>
    \\  </table>
    \\  <p style="font-size:12px;color:var(--muted);font-family:var(--mono);margin-bottom:8px;">codedb repo &mdash; 20 files, 12.6k lines</p>
    \\  <a href="/benchmarks" style="font-size:13px;color:var(--accent);font-weight:500;">See full benchmarks &rarr;</a>
    \\</div>
    \\
    \\<!-- Indexing speed -->
    \\<div class="section">
    \\  <div class="section-label">Indexing</div>
    \\  <div class="section-title">Cold start to ready</div>
    \\  <div class="section-desc">codedb builds all indexes on startup: outlines, trigram, word, dependency graph.</div>
    \\
    \\  <table class="bench-table">
    \\    <thead>
    \\      <tr><th>Repo</th><th>Files</th><th>Lines</th><th>Cold start</th><th>Per file</th></tr>
    \\    </thead>
    \\    <tbody>
    \\      <tr><td>codedb</td><td>20</td><td>12.6k</td><td class="fast">17 ms</td><td>0.85 ms</td></tr>
    \\      <tr><td>merjs</td><td>100</td><td>17.3k</td><td class="fast">16 ms</td><td>0.16 ms</td></tr>
    \\      <tr><td>openclaw</td><td>11,281</td><td>2.29M</td><td class="fast">2.9 s</td><td>6.66 ms</td></tr>
    \\      <tr><td>vitess</td><td>5,028</td><td>2.18M</td><td class="fast">~2 s</td><td>0.40 ms</td></tr>
    \\    </tbody>
    \\  </table>
    \\  <p style="font-size:12px;color:var(--muted);font-family:var(--mono);">After startup, file watcher keeps indexes updated. Single-file re-index: &lt;2ms.</p>
    \\</div>
    \\
    \\<!-- Token efficiency -->
    \\<div class="section">
    \\  <div class="section-label">Token efficiency</div>
    \\  <div class="section-title">1,628x fewer tokens</div>
    \\  <div class="section-desc">codedb returns structured, relevant results &mdash; not raw line dumps. For AI agents, this means dramatically fewer tokens per query.</div>
    \\
    \\  <table class="bench-table">
    \\    <thead>
    \\      <tr><th>Repo</th><th>codedb MCP</th><th>ripgrep / grep</th><th>Reduction</th></tr>
    \\    </thead>
    \\    <tbody>
    \\      <tr class="highlight"><td>codedb (search <code>allocator</code>)</td><td class="fast">~20 tokens</td><td>~32,564 tokens</td><td class="fast">1,628x fewer</td></tr>
    \\      <tr class="highlight"><td>merjs (search <code>allocator</code>)</td><td class="fast">~20 tokens</td><td>~4,007 tokens</td><td class="fast">200x fewer</td></tr>
    \\    </tbody>
    \\  </table>
    \\</div>
    \\
    \\<!-- Feature matrix -->
    \\<div class="section">
    \\  <div class="section-label">Comparison</div>
    \\  <div class="section-title">Feature matrix</div>
    \\
    \\  <div style="overflow-x:auto;">
    \\  <table class="bench-table">
    \\    <thead>
    \\      <tr><th>Feature</th><th>codedb MCP</th><th>ast-grep</th><th>ripgrep</th><th>grep</th><th>ctags</th></tr>
    \\    </thead>
    \\    <tbody>
    \\      <tr><td>Structural parsing</td><td class="fast">Yes</td><td>Yes</td><td>No</td><td>No</td><td>Yes</td></tr>
    \\      <tr><td>Trigram search index</td><td class="fast">Yes</td><td>No</td><td>No</td><td>No</td><td>No</td></tr>
    \\      <tr><td>Inverted word index</td><td class="fast">Yes</td><td>No</td><td>No</td><td>No</td><td>No</td></tr>
    \\      <tr><td>Dependency graph</td><td class="fast">Yes</td><td>No</td><td>No</td><td>No</td><td>No</td></tr>
    \\      <tr><td>Version tracking</td><td class="fast">Yes</td><td>No</td><td>No</td><td>No</td><td>No</td></tr>
    \\      <tr><td>Multi-agent locking</td><td class="fast">Yes</td><td>No</td><td>No</td><td>No</td><td>No</td></tr>
    \\      <tr><td>Pre-indexed (warm)</td><td class="fast">Yes</td><td>No</td><td>No</td><td>No</td><td>No</td></tr>
    \\      <tr><td>MCP protocol</td><td class="fast">Yes</td><td>No</td><td>No</td><td>No</td><td>No</td></tr>
    \\      <tr><td>Full-text search</td><td class="fast">Yes</td><td>Yes</td><td>Yes</td><td>Yes</td><td>No</td></tr>
    \\      <tr><td>Atomic file edits</td><td class="fast">Yes</td><td>Yes</td><td>No</td><td>No</td><td>No</td></tr>
    \\      <tr><td>File watcher</td><td class="fast">Yes</td><td>No</td><td>No</td><td>No</td><td>No</td></tr>
    \\    </tbody>
    \\  </table>
    \\  </div>
    \\</div>
    \\
    \\<!-- CTA -->
    \\<div class="cta-section">
    \\  <div class="cta-inner">
    \\    <div class="cta-title">Give your agent a brain</div>
    \\    <div class="cta-sub">One command. Auto-registers in Claude Code, Codex, Gemini CLI, and Cursor.</div>
    \\    <div class="hero-install" style="margin:0 auto 20px;justify-content:center;">
    \\      <span class="prompt">$</span> curl -fsSL https://codedb.codegraff.com/install.sh | bash
    \\    </div>
    \\    <div style="display:flex;gap:12px;justify-content:center;flex-wrap:wrap;">
    \\      <a href="/quickstart" class="btn">Quick start guide</a>
    \\      <a href="https://github.com/justrach/codedb" class="btn btn-outline">GitHub</a>
    \\    </div>
    \\  </div>
    \\</div>
    \\
    \\<!-- Footer -->
    \\<div class="layout-footer">
    \\  <p>codedb &mdash; code intelligence for AI agents &middot; <a href="https://github.com/justrach/codedb">GitHub</a></p>
    \\</div>
    \\
    \\<script>
    \\(function() {
    \\  var burger = document.getElementById('burger');
    \\  var links = document.getElementById('nav-links');
    \\  burger.addEventListener('click', function() {
    \\    burger.classList.toggle('open');
    \\    links.classList.toggle('open');
    \\  });
    \\  links.querySelectorAll('a').forEach(function(a) {
    \\    a.addEventListener('click', function() {
    \\      burger.classList.remove('open');
    \\      links.classList.remove('open');
    \\    });
    \\  });
    \\})();
    \\</script>
    \\</body>
    \\</html>
;
