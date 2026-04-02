const mer = @import("mer");

pub const meta: mer.Meta = .{
    .title = "Benchmarks",
    .description = "codedb MCP vs CLI vs ast-grep vs ripgrep vs grep — performance benchmarks and feature comparison.",
};

pub const prerender = true;

pub fn render(req: mer.Request) mer.Response {
    _ = req;
    return .{
        .status = .ok,
        .content_type = .html,
        .body = html,
    };
}

const html =
    \\<!DOCTYPE html>
    \\<html lang="en">
    \\<head>
    \\  <meta charset="UTF-8">
    \\  <meta name="viewport" content="width=device-width, initial-scale=1.0">
    \\  <title>Benchmarks — codedb</title>
    \\  <link rel="preconnect" href="https://fonts.googleapis.com">
    \\  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    \\  <link href="https://fonts.googleapis.com/css2?family=Geist:wght@400;500;600;700;800&family=Geist+Mono:wght@400;500&display=swap" rel="stylesheet">
    \\  <script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.0/dist/chart.umd.min.js"></script>
    \\  <style>
    \\    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
    \\    :root {
    \\      --bg: #ffffff; --bg2: #f7faf8; --bg3: #eef5f0;
    \\      --dark: #0a0a0a; --dark2: #111111; --dark3: #1a1a1a;
    \\      --text: #111; --muted: #6b7280; --border: #e0e7e2;
    \\      --accent: #059669; --accent-light: #10b981; --accent-dim: rgba(5,150,105,0.10);
    \\      --green: #059669;
    \\      --mono: 'Geist Mono', ui-monospace, monospace;
    \\      --sans: 'Geist', system-ui, sans-serif;
    \\      --display: 'Geist', system-ui, sans-serif;
    \\    }
    \\    html { scroll-behavior: smooth; }
    \\    body { background: var(--dark); color: var(--text); font-family: var(--sans); min-height: 100vh; overflow-x: hidden; }
    \\    a { color: inherit; text-decoration: none; }
    \\
    \\    /* Nav (dark) */
    \\    nav { position: sticky; top: 0; z-index: 100; background: rgba(10,10,10,0.92); backdrop-filter: blur(16px); border-bottom: 1px solid rgba(255,255,255,0.08); }
    \\    .nav-inner { max-width: 1100px; margin: 0 auto; padding: 0 40px; display: flex; align-items: center; justify-content: space-between; height: 60px; }
    \\    .wordmark { font-family: var(--sans); font-size: 17px; font-weight: 800; letter-spacing: -0.02em; color: #fff; }
    \\    .wordmark em { font-style: normal; color: var(--accent-light); }
    \\    .nav-links { display: flex; gap: 32px; align-items: center; }
    \\    .nav-links a { font-size: 13px; font-weight: 500; color: rgba(255,255,255,0.5); letter-spacing: 0.01em; transition: color 0.15s; }
    \\    .nav-links a:hover { color: #fff; }
    \\    .nav-cta { font-family: var(--sans); font-size: 13px !important; font-weight: 700 !important; color: #fff !important; background: var(--accent); padding: 8px 18px; border-radius: 6px; transition: background 0.15s; }
    \\    .nav-cta:hover { background: #15803d; }
    \\    .nav-burger { display: none; flex-direction: column; gap: 5px; background: none; border: none; cursor: pointer; padding: 4px; }
    \\    .nav-burger span { display: block; width: 22px; height: 2px; background: #fff; border-radius: 2px; transition: transform 0.2s, opacity 0.2s; }
    \\    .nav-burger.open span:nth-child(1) { transform: translateY(7px) rotate(45deg); }
    \\    .nav-burger.open span:nth-child(2) { opacity: 0; }
    \\    .nav-burger.open span:nth-child(3) { transform: translateY(-7px) rotate(-45deg); }
    \\    @media (max-width: 640px) {
    \\      .nav-burger { display: flex; }
    \\      .nav-links { display: none; flex-direction: column; gap: 0; position: absolute; top: 60px; left: 0; right: 0; background: rgba(10,10,10,0.97); backdrop-filter: blur(12px); border-bottom: 1px solid rgba(255,255,255,0.08); padding: 8px 0; }
    \\      .nav-links.open { display: flex; }
    \\      .nav-links a { padding: 14px 24px; font-size: 15px; }
    \\      .nav-cta { margin: 8px 24px 12px; padding: 12px 20px; border-radius: 6px; text-align: center; }
    \\    }
    \\
    \\    /* Hero (dark) */
    \\    .hero { background: var(--dark); padding: 80px 40px 0; max-width: 1100px; margin: 0 auto; }
    \\    .hero-label { font-family: var(--mono); font-size: 11px; font-weight: 600; letter-spacing: 0.16em; text-transform: uppercase; color: var(--accent-light); margin-bottom: 20px; display: flex; align-items: center; gap: 10px; }
    \\    .hero-label::before { content: ''; display: inline-block; width: 20px; height: 1px; background: var(--accent-light); }
    \\    .hero-headline { font-family: var(--sans); font-size: clamp(44px, 7vw, 88px); font-weight: 800; letter-spacing: -0.04em; line-height: 0.95; color: #fff; margin-bottom: 16px; }
    \\    .hero-headline .hl { color: var(--accent-light); }
    \\    .hero-sub { font-family: var(--mono); font-size: 12px; color: rgba(255,255,255,0.35); letter-spacing: 0.04em; margin-bottom: 64px; }
    \\
    \\    /* Stat row */
    \\    .stat-row { display: grid; grid-template-columns: repeat(4,1fr); gap: 16px; padding-bottom: 48px; }
    \\    @media (max-width: 700px) { .stat-row { grid-template-columns: repeat(2,1fr); } }
    \\    .stat-cell { background: rgba(22,163,74,0.06); border: 1px solid rgba(22,163,74,0.15); border-radius: 12px; padding: 28px 24px; text-align: center; }
    \\    .stat-val { font-family: var(--sans); font-size: clamp(32px, 4vw, 48px); font-weight: 800; letter-spacing: -0.04em; color: var(--accent-light); line-height: 1; margin-bottom: 4px; }
    \\    .stat-val .unit { font-size: 0.45em; font-weight: 600; color: rgba(255,255,255,0.4); letter-spacing: 0; vertical-align: super; margin-left: 2px; }
    \\    .stat-label { font-family: var(--mono); font-size: 11px; color: rgba(255,255,255,0.4); letter-spacing: 0.08em; text-transform: uppercase; margin-bottom: 8px; }
    \\    .stat-delta { font-family: var(--mono); font-size: 11px; color: var(--accent-light); letter-spacing: 0.02em; }
    \\
    \\    /* Tables section (white) */
    \\    .tables-section { background: var(--bg); padding: 80px 40px; }
    \\    .tables-inner { max-width: 1100px; margin: 0 auto; }
    \\    .section-eyebrow { font-family: var(--mono); font-size: 11px; font-weight: 600; letter-spacing: 0.14em; text-transform: uppercase; color: var(--accent); margin-bottom: 10px; }
    \\    .section-heading { font-family: var(--sans); font-size: clamp(22px, 3vw, 32px); font-weight: 800; letter-spacing: -0.025em; color: var(--dark); margin-bottom: 32px; }
    \\    .section-sub { font-size: 14px; color: var(--muted); margin-bottom: 32px; max-width: 700px; line-height: 1.7; }
    \\    .bench-table { width: 100%; border-collapse: collapse; margin: 0 0 48px; font-size: 13px; }
    \\    .bench-table th { text-align: left; padding: 10px 12px; color: var(--muted); font-family: var(--mono); font-size: 11px; font-weight: 500; text-transform: uppercase; letter-spacing: 0.08em; border-bottom: 2px solid var(--border); }
    \\    .bench-table td { padding: 10px 12px; border-bottom: 1px solid var(--border); font-family: var(--mono); font-size: 12px; }
    \\    .bench-table .fast { color: var(--accent); font-weight: 600; }
    \\    .bench-table .na { color: #d1d5db; }
    \\    .table-note { font-size: 12px; color: var(--muted); font-family: var(--mono); margin: -36px 0 48px; }
    \\    .chart-row { display: grid; grid-template-columns: 1fr 1fr; gap: 20px; margin: 48px 0; }
    \\    @media (max-width: 700px) { .chart-row { grid-template-columns: 1fr; } }
    \\    .chart-card { background: var(--bg2); border: 1px solid var(--border); border-radius: 12px; padding: 24px; }
    \\    .chart-card h3 { font-family: var(--sans); font-size: 15px; font-weight: 700; color: var(--dark); margin-bottom: 16px; }
    \\    .chart-card canvas { width: 100% !important; height: 280px !important; }
    \\
    \\    /* Feature matrix section */
    \\    .matrix-section { background: var(--bg2); padding: 80px 40px; }
    \\    .matrix-inner { max-width: 1100px; margin: 0 auto; }
    \\    .yes { color: var(--accent); font-weight: 600; }
    \\    .no { color: #d1d5db; }
    \\
    \\    /* Why section (dark) */
    \\    .why-section { background: var(--dark2); padding: 80px 40px; }
    \\    .why-inner { max-width: 1100px; margin: 0 auto; }
    \\    .why-section .section-heading { color: #fff; }
    \\    .why-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 2px; margin-top: 2px; }
    \\    @media (max-width: 700px) { .why-grid { grid-template-columns: 1fr; } }
    \\    .why-card { background: var(--dark3); padding: 32px; border-radius: 8px; }
    \\    .why-card h3 { font-family: var(--sans); font-size: 15px; font-weight: 700; color: #fff; margin-bottom: 8px; }
    \\    .why-card p { font-size: 13px; color: rgba(255,255,255,0.4); line-height: 1.7; font-family: var(--mono); }
    \\
    \\    /* Method + CTA */
    \\    .method-section { background: var(--dark); padding: 0 40px 100px; }
    \\    .method-inner { max-width: 1100px; margin: 0 auto; border-top: 1px solid rgba(255,255,255,0.08); padding-top: 48px; display: flex; gap: 60px; align-items: flex-start; }
    \\    @media (max-width: 700px) { .method-inner { flex-direction: column; gap: 32px; } }
    \\    .method-text { flex: 1; font-size: 13px; color: rgba(255,255,255,0.4); line-height: 1.8; font-family: var(--mono); }
    \\    .method-text strong { color: rgba(255,255,255,0.7); font-weight: 500; }
    \\    .method-text a { color: var(--accent-light); }
    \\    .method-ctas { display: flex; flex-direction: column; gap: 12px; flex-shrink: 0; }
    \\    .btn { display: inline-flex; align-items: center; justify-content: center; font-family: var(--sans); font-size: 14px; font-weight: 700; padding: 13px 28px; border-radius: 8px; background: var(--accent); color: #fff; transition: all 0.2s; white-space: nowrap; }
    \\    .btn:hover { background: #15803d; transform: translateY(-1px); box-shadow: 0 4px 12px rgba(22,163,74,0.25); }
    \\    .btn-ghost { background: transparent; border: 1px solid rgba(255,255,255,0.15); color: rgba(255,255,255,0.6); font-weight: 500; }
    \\    .btn-ghost:hover { border-color: rgba(255,255,255,0.4); color: #fff; transform: none; box-shadow: none; }
    \\    .layout-footer { padding: 20px 40px; border-top: 1px solid rgba(255,255,255,0.06); font-size: 11px; color: rgba(255,255,255,0.2); text-align: center; font-family: var(--mono); letter-spacing: 0.04em; background: var(--dark); max-width: none; }
    \\    .layout-footer a { color: rgba(255,255,255,0.2); }
    \\    .layout-footer a:hover { color: rgba(255,255,255,0.5); }
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
    \\      <a href="/quickstart">Install</a>
    \\      <a href="/privacy">Privacy</a>
    \\      <a href="https://github.com/justrach/codedb">GitHub</a>
    \\      <a href="/quickstart" class="nav-cta">Get started</a>
    \\    </div>
    \\  </div>
    \\</nav>
    \\
    \\<!-- Hero -->
    \\<div style="background:var(--dark);">
    \\  <div class="hero">
    \\    <div class="hero-label">Performance benchmarks</div>
    \\    <div class="hero-headline">
    \\      <span class="hl">1,300x</span> faster<br>than CLI tools.
    \\    </div>
    \\    <div class="hero-sub">Apple M4 Pro &nbsp;&middot;&nbsp; 48GB RAM &nbsp;&middot;&nbsp; pre-indexed MCP queries &nbsp;&middot;&nbsp; 20 iterations avg</div>
    \\    <div class="stat-row">
    \\      <div class="stat-cell">
    \\        <div class="stat-label">MCP query latency</div>
    \\        <div class="stat-val">0.05<span class="unit">ms</span></div>
    \\        <div class="stat-delta">vs 55ms codedb CLI</div>
    \\      </div>
    \\      <div class="stat-cell">
    \\        <div class="stat-label">vs ast-grep</div>
    \\        <div class="stat-val">64<span class="unit">x</span></div>
    \\        <div class="stat-delta">faster than 3.2ms</div>
    \\      </div>
    \\      <div class="stat-cell">
    \\        <div class="stat-label">vs ripgrep</div>
    \\        <div class="stat-val">126<span class="unit">x</span></div>
    \\        <div class="stat-delta">faster than 6.3ms</div>
    \\      </div>
    \\      <div class="stat-cell">
    \\        <div class="stat-label">Token reduction</div>
    \\        <div class="stat-val">1,628<span class="unit">x</span></div>
    \\        <div class="stat-delta">fewer than grep output</div>
    \\      </div>
    \\    </div>
    \\  </div>
    \\</div>
    \\
    \\<!-- Latency tables -->
    \\<div class="tables-section">
    \\  <div class="tables-inner">
    \\    <div class="section-eyebrow">Query latency</div>
    \\    <div class="section-heading">codedb repo (20 files, 12.6k lines)</div>
    \\
    \\    <table class="bench-table">
    \\      <thead>
    \\        <tr><th>Query</th><th>codedb MCP</th><th>codedb CLI</th><th>ast-grep</th><th>ripgrep</th><th>grep</th><th>MCP speedup</th></tr>
    \\      </thead>
    \\      <tbody>
    \\        <tr><td>File tree</td><td class="fast">0.04 ms</td><td>52.9 ms</td><td class="na">&middot;</td><td class="na">&middot;</td><td class="na">&middot;</td><td class="fast">1,253x vs CLI</td></tr>
    \\        <tr><td>Symbol search (<code>init</code>)</td><td class="fast">0.10 ms</td><td>54.1 ms</td><td>3.2 ms</td><td>6.3 ms</td><td>6.5 ms</td><td class="fast">549x vs CLI</td></tr>
    \\        <tr><td>Full-text search (<code>allocator</code>)</td><td class="fast">0.05 ms</td><td>60.7 ms</td><td>3.2 ms</td><td>5.3 ms</td><td>6.6 ms</td><td class="fast">1,340x vs CLI</td></tr>
    \\        <tr><td>Word index (<code>self</code>)</td><td class="fast">0.04 ms</td><td>59.7 ms</td><td class="na">n/a</td><td>7.2 ms</td><td>6.5 ms</td><td class="fast">1,404x vs CLI</td></tr>
    \\        <tr><td>Structural outline</td><td class="fast">0.05 ms</td><td>53.5 ms</td><td>3.1 ms</td><td class="na">&middot;</td><td>2.4 ms</td><td class="fast">1,143x vs CLI</td></tr>
    \\        <tr><td>Dependency graph</td><td class="fast">0.05 ms</td><td>2.2 ms</td><td class="na">n/a</td><td class="na">n/a</td><td class="na">n/a</td><td class="fast">45x vs CLI</td></tr>
    \\      </tbody>
    \\    </table>
    \\
    \\    <div class="section-heading">merjs repo (100 files, 17.3k lines)</div>
    \\
    \\    <table class="bench-table">
    \\      <thead>
    \\        <tr><th>Query</th><th>codedb MCP</th><th>codedb CLI</th><th>ast-grep</th><th>ripgrep</th><th>grep</th><th>MCP speedup</th></tr>
    \\      </thead>
    \\      <tbody>
    \\        <tr><td>File tree</td><td class="fast">0.05 ms</td><td>54.0 ms</td><td class="na">&middot;</td><td class="na">&middot;</td><td class="na">&middot;</td><td class="fast">1,173x vs CLI</td></tr>
    \\        <tr><td>Symbol search (<code>init</code>)</td><td class="fast">0.07 ms</td><td>54.4 ms</td><td>3.4 ms</td><td>6.3 ms</td><td>3.6 ms</td><td class="fast">758x vs CLI</td></tr>
    \\        <tr><td>Full-text search (<code>allocator</code>)</td><td class="fast">0.03 ms</td><td>54.1 ms</td><td>2.9 ms</td><td>5.1 ms</td><td>3.7 ms</td><td class="fast">1,554x vs CLI</td></tr>
    \\        <tr><td>Word index (<code>self</code>)</td><td class="fast">0.04 ms</td><td>54.7 ms</td><td class="na">n/a</td><td>6.3 ms</td><td>4.2 ms</td><td class="fast">1,518x vs CLI</td></tr>
    \\        <tr><td>Structural outline</td><td class="fast">0.04 ms</td><td>54.9 ms</td><td>3.4 ms</td><td class="na">&middot;</td><td>2.5 ms</td><td class="fast">1,243x vs CLI</td></tr>
    \\        <tr><td>Dependency graph</td><td class="fast">0.05 ms</td><td>1.9 ms</td><td class="na">n/a</td><td class="na">n/a</td><td class="na">n/a</td><td class="fast">41x vs CLI</td></tr>
    \\      </tbody>
    \\    </table>
    \\
    \\    <div class="section-eyebrow">Token efficiency</div>
    \\    <div class="section-heading">Structured results, not raw dumps</div>
    \\    <div class="section-sub">codedb returns structured, relevant results. For AI agents, this means dramatically fewer tokens per query compared to grep/ripgrep raw output.</div>
    \\
    \\    <table class="bench-table">
    \\      <thead>
    \\        <tr><th>Repo</th><th>codedb MCP</th><th>ripgrep / grep</th><th>Reduction</th></tr>
    \\      </thead>
    \\      <tbody>
    \\        <tr><td>codedb (search <code>allocator</code>)</td><td class="fast">~20 tokens</td><td>~32,564 tokens</td><td class="fast">1,628x fewer</td></tr>
    \\        <tr><td>merjs (search <code>allocator</code>)</td><td class="fast">~20 tokens</td><td>~4,007 tokens</td><td class="fast">200x fewer</td></tr>
    \\      </tbody>
    \\    </table>
    \\
    \\    <div class="section-eyebrow">Indexing speed</div>
    \\    <div class="section-heading">Cold start to ready</div>
    \\    <div class="section-sub">codedb builds all indexes on startup: outlines, trigram, word, dependency graph. After startup, the file watcher keeps indexes updated. Single-file re-index: &lt;2ms.</div>
    \\
    \\    <table class="bench-table">
    \\      <thead>
    \\        <tr><th>Repo</th><th>Files</th><th>Lines</th><th>Cold start</th><th>Per file</th></tr>
    \\      </thead>
    \\      <tbody>
    \\        <tr><td>codedb</td><td>20</td><td>12.6k</td><td class="fast">17 ms</td><td>0.85 ms</td></tr>
    \\        <tr><td>merjs</td><td>100</td><td>17.3k</td><td class="fast">16 ms</td><td>0.16 ms</td></tr>
    \\        <tr><td>openclaw/openclaw</td><td>11,281</td><td>2.29M</td><td class="fast">75 s</td><td>6.66 ms</td></tr>
    \\        <tr><td>vitessio/vitess</td><td>5,028</td><td>2.18M</td><td class="fast">50 s</td><td>9.95 ms</td></tr>
    \\      </tbody>
    \\    </table>
    \\
    \\    <div class="chart-row">
    \\      <div class="chart-card">
    \\        <h3>Query Latency (ms, log scale)</h3>
    \\        <canvas id="latencyChart"></canvas>
    \\      </div>
    \\      <div class="chart-card">
    \\        <h3>Token Efficiency (search 'allocator')</h3>
    \\        <canvas id="tokenChart"></canvas>
    \\      </div>
    \\    </div>
    \\    <div class="chart-row">
    \\      <div class="chart-card">
    \\        <h3>Indexing Speed by Repo Size</h3>
    \\        <canvas id="indexChart"></canvas>
    \\      </div>
    \\      <div class="chart-card">
    \\        <h3>MCP Speedup vs CLI</h3>
    \\        <canvas id="speedupChart"></canvas>
    \\      </div>
    \\    </div>
    \\  </div>
    \\</div>
    \\
    \\<!-- Feature matrix -->
    \\<div class="matrix-section">
    \\  <div class="matrix-inner">
    \\    <div class="section-eyebrow">Comparison</div>
    \\    <div class="section-heading">Feature matrix</div>
    \\
    \\    <div style="overflow-x:auto;">
    \\    <table class="bench-table">
    \\      <thead>
    \\        <tr><th>Feature</th><th>codedb MCP</th><th>codedb CLI</th><th>ast-grep</th><th>ripgrep</th><th>grep</th><th>ctags</th></tr>
    \\      </thead>
    \\      <tbody>
    \\        <tr><td>Structural parsing</td><td class="yes">Yes</td><td class="yes">Yes</td><td class="yes">Yes</td><td class="no">No</td><td class="no">No</td><td class="yes">Yes</td></tr>
    \\        <tr><td>Trigram search index</td><td class="yes">Yes</td><td class="yes">Yes</td><td class="no">No</td><td class="no">No</td><td class="no">No</td><td class="no">No</td></tr>
    \\        <tr><td>Inverted word index</td><td class="yes">Yes</td><td class="yes">Yes</td><td class="no">No</td><td class="no">No</td><td class="no">No</td><td class="no">No</td></tr>
    \\        <tr><td>Dependency graph</td><td class="yes">Yes</td><td class="yes">Yes</td><td class="no">No</td><td class="no">No</td><td class="no">No</td><td class="no">No</td></tr>
    \\        <tr><td>Version tracking</td><td class="yes">Yes</td><td class="yes">Yes</td><td class="no">No</td><td class="no">No</td><td class="no">No</td><td class="no">No</td></tr>
    \\        <tr><td>Multi-agent locking</td><td class="yes">Yes</td><td class="yes">Yes</td><td class="no">No</td><td class="no">No</td><td class="no">No</td><td class="no">No</td></tr>
    \\        <tr><td>Pre-indexed (warm)</td><td class="yes">Yes</td><td class="no">No</td><td class="no">No</td><td class="no">No</td><td class="no">No</td><td class="no">No</td></tr>
    \\        <tr><td>MCP protocol</td><td class="yes">Yes</td><td class="no">No</td><td class="no">No</td><td class="no">No</td><td class="no">No</td><td class="no">No</td></tr>
    \\        <tr><td>Full-text search</td><td class="yes">Yes</td><td class="yes">Yes</td><td class="yes">Yes</td><td class="yes">Yes</td><td class="yes">Yes</td><td class="no">No</td></tr>
    \\        <tr><td>Atomic file edits</td><td class="yes">Yes</td><td class="yes">Yes</td><td class="yes">Yes</td><td class="no">No</td><td class="no">No</td><td class="no">No</td></tr>
    \\        <tr><td>File watcher</td><td class="yes">Yes</td><td class="yes">Yes</td><td class="no">No</td><td class="no">No</td><td class="no">No</td><td class="no">No</td></tr>
    \\      </tbody>
    \\    </table>
    \\    </div>
    \\  </div>
    \\</div>
    \\
    \\<!-- Why fast -->
    \\<div class="why-section">
    \\  <div class="why-inner">
    \\    <div class="section-eyebrow">Architecture</div>
    \\    <div class="section-heading">Why codedb is fast</div>
    \\    <div class="why-grid">
    \\      <div class="why-card">
    \\        <h3>MCP server</h3>
    \\        <p>Indexes once on startup. All queries hit in-memory data structures with O(1) hash lookups. No filesystem access at query time.</p>
    \\      </div>
    \\      <div class="why-card">
    \\        <h3>CLI tools</h3>
    \\        <p>~55ms process startup + full filesystem scan on every invocation. Even simple queries pay the full cost.</p>
    \\      </div>
    \\      <div class="why-card">
    \\        <h3>ast-grep</h3>
    \\        <p>Re-parses all files through tree-sitter on every call. ~3ms for small repos, scales linearly with codebase size.</p>
    \\      </div>
    \\      <div class="why-card">
    \\        <h3>ripgrep / grep</h3>
    \\        <p>Brute-force scans every file on every call. ~5-7ms for small repos. No structural understanding, no index.</p>
    \\      </div>
    \\    </div>
    \\  </div>
    \\</div>
    \\
    \\<!-- CTA -->
    \\<div class="method-section">
    \\  <div class="method-inner">
    \\    <div class="method-text">
    \\      <strong>Methodology</strong><br><br>
    \\      Apple M4 Pro, 48GB RAM. MCP = pre-indexed warm queries (20 iterations avg).<br>
    \\      CLI and external tools include process startup (3 iterations avg).<br>
    \\      Ground truth verified against Python reference implementation.<br><br>
    \\      <a href="https://github.com/justrach/codedb">View source on GitHub &rarr;</a>
    \\    </div>
    \\    <div class="method-ctas">
    \\      <a href="/quickstart" class="btn">Get started</a>
    \\      <a href="https://github.com/justrach/codedb" class="btn btn-ghost">GitHub</a>
    \\    </div>
    \\  </div>
    \\</div>
    \\
    \\<footer class="layout-footer">
    \\  codedb &middot; code intelligence for AI agents &middot; <a href="https://github.com/justrach/codedb">GitHub</a>
    \\</footer>
    \\
    \\<script>
    \\(function() {
    \\  var burger = document.getElementById('burger');
    \\  var links = document.getElementById('nav-links');
    \\  burger.addEventListener('click', function() { burger.classList.toggle('open'); links.classList.toggle('open'); });
    \\  links.querySelectorAll('a').forEach(function(a) { a.addEventListener('click', function() { burger.classList.remove('open'); links.classList.remove('open'); }); });
    \\
    \\  var green = '#16a34a';
    \\  var greenLight = '#22c55e';
    \\  var gray = '#9ca3af';
    \\  var amber = '#f59e0b';
    \\  var grayDark = '#6b7280';
    \\
    \\  // Latency chart (log scale)
    \\  new Chart(document.getElementById('latencyChart'),{type:'bar',data:{labels:['Tree','Symbol','Search','Word','Outline','Deps'],datasets:[{label:'codedb MCP',data:[0.04,0.10,0.05,0.04,0.05,0.05],backgroundColor:green,borderRadius:4},{label:'ast-grep',data:[3.7,3.2,3.2,null,3.1,null],backgroundColor:amber,borderRadius:4},{label:'ripgrep',data:[null,6.3,5.3,7.2,null,null],backgroundColor:gray,borderRadius:4},{label:'grep',data:[null,6.5,6.6,6.5,2.4,null],backgroundColor:grayDark,borderRadius:4}]},options:{responsive:true,maintainAspectRatio:false,scales:{y:{type:'logarithmic',title:{display:true,text:'ms (log)',font:{family:'system-ui',size:11}},grid:{color:'#e5e7eb'}}},plugins:{legend:{position:'bottom',labels:{font:{family:'system-ui',size:11},usePointStyle:true,pointStyle:'circle',padding:16}}}}});
    \\
    \\  // Token chart
    \\  new Chart(document.getElementById('tokenChart'),{type:'bar',data:{labels:['codedb','merjs'],datasets:[{label:'codedb MCP',data:[20,20],backgroundColor:green,borderRadius:4},{label:'ripgrep/grep',data:[32564,4007],backgroundColor:gray,borderRadius:4}]},options:{responsive:true,maintainAspectRatio:false,scales:{y:{title:{display:true,text:'tokens',font:{family:'system-ui',size:11}},grid:{color:'#e5e7eb'}}},plugins:{legend:{position:'bottom',labels:{font:{family:'system-ui',size:11},usePointStyle:true,pointStyle:'circle',padding:16}}}}});
    \\
    \\  // Indexing chart
    \\  new Chart(document.getElementById('indexChart'),{type:'bar',data:{labels:['codedb\n20 files','merjs\n100 files','openclaw\n11.3k files','vitess\n5k files'],datasets:[{label:'Cold start',data:[0.017,0.016,75,50],backgroundColor:green,borderRadius:4}]},options:{responsive:true,maintainAspectRatio:false,scales:{y:{type:'logarithmic',title:{display:true,text:'seconds (log)',font:{family:'system-ui',size:11}},grid:{color:'#e5e7eb'}}},plugins:{legend:{display:false}}}});
    \\
    \\  // Speedup chart
    \\  new Chart(document.getElementById('speedupChart'),{type:'bar',data:{labels:['Tree','Symbol','Search','Word','Outline','Deps'],datasets:[{label:'MCP vs CLI speedup',data:[1253,549,1340,1404,1143,45],backgroundColor:[green,green,green,green,green,greenLight],borderRadius:4}]},options:{responsive:true,maintainAspectRatio:false,indexAxis:'y',scales:{x:{title:{display:true,text:'speedup (x)',font:{family:'system-ui',size:11}},grid:{color:'#e5e7eb'}}},plugins:{legend:{display:false}}}});
    \\})();
    \\</script>
    \\</body>
    \\</html>
;
