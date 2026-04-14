const mer = @import("mer");

pub const meta: mer.Meta = .{
    .title = "What's New in v0.2.572",
    .description = "10× faster indexing, 83% less memory, 92% warm RSS reduction, 18 issues closed.",
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
    \\  <title>What's New — codedb v0.2.572</title>
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
    \\      --green: #059669; --red: #ef4444; --gray: #e5e7eb;
    \\      --mono: 'Geist Mono', ui-monospace, monospace;
    \\      --sans: 'Geist', system-ui, sans-serif;
    \\    }
    \\    html { scroll-behavior: smooth; }
    \\    body { background: var(--dark); color: var(--text); font-family: var(--sans); min-height: 100vh; overflow-x: hidden; }
    \\    a { color: inherit; text-decoration: none; }
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
    \\    .hero { background: var(--dark); padding: 80px 40px 0; max-width: 1100px; margin: 0 auto; }
    \\    .hero-label { font-family: var(--mono); font-size: 11px; font-weight: 600; letter-spacing: 0.16em; text-transform: uppercase; color: var(--accent-light); margin-bottom: 20px; display: flex; align-items: center; gap: 10px; }
    \\    .hero-label::before { content: ''; display: inline-block; width: 20px; height: 1px; background: var(--accent-light); }
    \\    .hero-headline { font-family: var(--sans); font-size: clamp(44px, 7vw, 88px); font-weight: 800; letter-spacing: -0.04em; line-height: 0.95; color: #fff; margin-bottom: 16px; }
    \\    .hero-headline .hl { color: var(--accent-light); }
    \\    .hero-sub { font-family: var(--mono); font-size: 12px; color: rgba(255,255,255,0.35); letter-spacing: 0.04em; margin-bottom: 64px; }
    \\    .stat-row { display: grid; grid-template-columns: repeat(4,1fr); gap: 16px; padding-bottom: 48px; }
    \\    @media (max-width: 700px) { .stat-row { grid-template-columns: repeat(2,1fr); } }
    \\    .stat-cell { background: rgba(22,163,74,0.06); border: 1px solid rgba(22,163,74,0.15); border-radius: 12px; padding: 28px 24px; text-align: center; }
    \\    .stat-val { font-family: var(--sans); font-size: clamp(32px, 4vw, 48px); font-weight: 800; letter-spacing: -0.04em; color: var(--accent-light); line-height: 1; margin-bottom: 4px; }
    \\    .stat-val .unit { font-size: 0.45em; font-weight: 600; color: rgba(255,255,255,0.4); letter-spacing: 0; vertical-align: super; margin-left: 2px; }
    \\    .stat-label { font-family: var(--mono); font-size: 11px; color: rgba(255,255,255,0.4); letter-spacing: 0.08em; text-transform: uppercase; margin-bottom: 8px; }
    \\    .stat-delta { font-family: var(--mono); font-size: 11px; color: var(--accent-light); letter-spacing: 0.02em; }
    \\    .section { padding: 80px 40px; }
    \\    .section-inner { max-width: 1100px; margin: 0 auto; }
    \\    .section-eyebrow { font-family: var(--mono); font-size: 11px; font-weight: 600; letter-spacing: 0.14em; text-transform: uppercase; margin-bottom: 10px; }
    \\    .section-heading { font-family: var(--sans); font-size: clamp(22px, 3vw, 32px); font-weight: 800; letter-spacing: -0.025em; margin-bottom: 32px; }
    \\    .section-sub { font-size: 14px; line-height: 1.7; margin-bottom: 32px; max-width: 700px; }
    \\    .bench-table { width: 100%; border-collapse: collapse; margin: 0 0 48px; font-size: 13px; }
    \\    .bench-table th { text-align: left; padding: 10px 12px; font-family: var(--mono); font-size: 11px; font-weight: 500; text-transform: uppercase; letter-spacing: 0.08em; border-bottom: 2px solid var(--border); }
    \\    .bench-table td { padding: 10px 12px; border-bottom: 1px solid var(--border); font-family: var(--mono); font-size: 12px; }
    \\    .bench-table .fast { color: var(--accent); font-weight: 600; }
    \\    .bench-table .old { color: var(--red); font-weight: 600; }
    \\    .chart-row { display: grid; grid-template-columns: 1fr 1fr; gap: 20px; margin: 48px 0; }
    \\    @media (max-width: 700px) { .chart-row { grid-template-columns: 1fr; } }
    \\    .chart-card { background: var(--bg2); border: 1px solid var(--border); border-radius: 12px; padding: 24px; }
    \\    .chart-card h3 { font-family: var(--sans); font-size: 15px; font-weight: 700; margin-bottom: 16px; }
    \\    .chart-card canvas { width: 100% !important; height: 280px !important; }
    \\    .timeline-section { padding: 80px 40px; }
    \\    .timeline-grid { display: grid; grid-template-columns: repeat(3,1fr); gap: 16px; }
    \\    @media (max-width: 900px) { .timeline-grid { grid-template-columns: repeat(2,1fr); } }
    \\    @media (max-width: 600px) { .timeline-grid { grid-template-columns: 1fr; } }
    \\    .timeline-card { padding: 28px; border-radius: 10px; }
    \\    .timeline-card h3 { font-family: var(--sans); font-size: 15px; font-weight: 700; margin-bottom: 10px; }
    \\    .timeline-card p { font-size: 13px; line-height: 1.7; font-family: var(--mono); }
    \\    .timeline-card .num { font-family: var(--sans); font-size: 40px; font-weight: 800; letter-spacing: -0.04em; margin-bottom: 12px; }
    \\    .contributors-grid { display: grid; grid-template-columns: repeat(2,1fr); gap: 12px; }
    \\    @media (max-width: 700px) { .contributors-grid { grid-template-columns: 1fr; } }
    \\    .contributor-card { padding: 20px 24px; border-radius: 8px; display: flex; align-items: center; gap: 12px; }
    \\    .contributor-card a { font-weight: 600; font-size: 14px; }
    \\    .contributor-card p { font-size: 12px; font-family: var(--mono); margin: 0; }
    \\    .cta-section { padding: 0 40px 100px; }
    \\    .cta-inner { max-width: 1100px; margin: 0 auto; border-top: 1px solid; padding-top: 48px; text-align: center; }
    \\    .btn { display: inline-flex; align-items: center; justify-content: center; font-family: var(--sans); font-size: 14px; font-weight: 700; padding: 13px 28px; border-radius: 8px; transition: all 0.2s; white-space: nowrap; }
    \\    .btn:hover { transform: translateY(-1px); box-shadow: 0 4px 12px rgba(0,0,0,0.15); }
    \\    .btn-primary { background: var(--accent); color: #fff; }
    \\    .btn-primary:hover { background: #15803d; }
    \\    .btn-ghost { background: transparent; border: 1px solid; margin-left: 12px; }
    \\    .install-cmd { font-family: var(--mono); font-size: 15px; padding: 20px 32px; border-radius: 8px; display: inline-block; margin: 24px 0; border: 1px solid; }
    \\    .layout-footer { padding: 20px 40px; font-size: 11px; text-align: center; font-family: var(--mono); letter-spacing: 0.04em; }
    \\    .layout-footer a:hover { text-decoration: underline; }
    \\  </style>
    \\</head>
    \\<body>
    \\<nav><div class="nav-inner">
    \\  <a href="/" class="wordmark">code<em>db</em></a>
    \\  <button class="nav-burger" id="burger"><span></span><span></span><span></span></button>
    \\  <div class="nav-links" id="nav-links">
    \\    <a href="/benchmarks">Benchmarks</a>
    \\    <a href="/improvements">Improvements</a>
    \\    <a href="/quickstart">Install</a>
    \\    <a href="/v0.2.572" style="color:#10b981;font-weight:600;">v0.2.572</a>
    \\    <a href="https://github.com/justrach/codedb">GitHub</a>
    \\    <a href="/quickstart" class="nav-cta">Get started</a>
    \\  </div>
    \\</div></nav>
    \\<div style="background:var(--dark);color:#fff;">
    \\  <div class="hero">
    \\    <div class="hero-label">v0.2.572 Release</div>
    \\    <div class="hero-headline"><span class="hl">10×</span> faster initial index. <span class="hl">83%</span> less cold RSS. <span class="hl">92%</span> less warm RSS. <span class="hl">1000×</span> ripgrep.</div>
    \\    <div class="hero-sub">Cold-start indexing on openclaw (6,315 files) — 18 issues closed — 10 contributors</div>
    \\    <div class="stat-row">
    \\      <div class="stat-cell"><div class="stat-label">Index time</div><div class="stat-val">10<span class="unit">×</span></div><div class="stat-delta">3.6s → 346ms</div></div>
    \\      <div class="stat-cell"><div class="stat-label">Cold RSS</div><div class="stat-val">83<span class="unit">%</span></div><div class="stat-delta">~3.5GB → ~580MB</div></div>
    \\      <div class="stat-cell"><div class="stat-label">Warm RSS</div><div class="stat-val">92<span class="unit">%</span></div><div class="stat-delta">~1.9GB → ~150MB</div></div>
    \\      <div class="stat-cell"><div class="stat-label">vs ripgrep</div><div class="stat-val">1000<span class="unit">×</span></div><div class="stat-delta">~500µs vs ~500ms</div></div>
    \\    </div>
    \\  </div>
    \\</div>
    \\<div class="section" style="background:var(--bg);color:var(--text);">
    \\  <div class="section-inner">
    \\    <div class="section-eyebrow" style="color:var(--accent);">Performance</div>
    \\    <div class="section-heading">Before &amp; after — openclaw (6,315 files, Apple M4 Pro)</div>
    \\    <p class="section-sub" style="color:var(--muted);">All metrics from <code>zig build benchmark</code> on real repos. ReleaseFast builds.</p>
    \\    <table class="bench-table" style="color:var(--text);">
    \\      <thead><tr><th>Metric</th><th>v0.2.56</th><th>v0.2.572</th><th>Delta</th></tr></thead>
    \\      <tbody>
    \\        <tr><td>Initial index time</td><td class="old">3.6 s</td><td class="fast">346 ms</td><td class="fast">10× faster</td></tr>
    \\        <tr><td>Cold RSS (peak)</td><td class="old">~3.5 GB</td><td class="fast">~580 MB</td><td class="fast">−83%</td></tr>
    \\        <tr><td>Warm RSS (steady)</td><td class="old">~1.9 GB</td><td class="fast">~150 MB</td><td class="fast">−92%</td></tr>
    \\        <tr><td>Git subprocesses / 30s</td><td class="old">15</td><td class="fast">2</td><td class="fast">−87%</td></tr>
    \\        <tr><td>Trigram search latency</td><td class="old">55 ms</td><td class="fast">53 ms</td><td class="fast">−4%</td></tr>
    \\        <tr><td>Word index latency</td><td class="old">35 ms</td><td class="fast">32 ms</td><td class="fast">−9%</td></tr>
    \\        <tr><td>Recall: webhook</td><td class="old">0 hits</td><td class="fast">50 hits</td><td class="fast">+50 (bug fix)</td></tr>
    \\      </tbody>
    \\    </table>
    \\    <div class="chart-row">
    \\      <div class="chart-card"><h3>Cold-start indexing (seconds)</h3><canvas id="indexChart"></canvas></div>
    \\      <div class="chart-card"><h3>Memory usage (MB)</h3><canvas id="memChart"></canvas></div>
    \\    </div>
    \\  </div>
    \\</div>
    \\<div style="background:var(--dark2);padding:60px 40px;border-top:1px solid rgba(255,255,255,0.06);border-bottom:1px solid rgba(255,255,255,0.06);">
    \\  <div class="section-inner" style="max-width:1100px;margin:0 auto;">
    \\    <div style="display:grid;grid-template-columns:repeat(2,1fr);gap:24px;">
    \\      <div style="background:rgba(5,150,105,0.08);border:1px solid rgba(5,150,105,0.2);border-radius:16px;padding:40px 32px;">
    \\        <div style="font-family:var(--sans);font-size:clamp(48px,8vw,72px);font-weight:800;letter-spacing:-0.04em;color:var(--accent-light);line-height:1;">10<span style="font-size:0.5em;opacity:0.6">×</span></div>
    \\        <div style="font-family:var(--sans);font-size:24px;font-weight:700;color:#fff;margin-top:8px;">faster initial index.</div>
    \\        <div style="font-family:var(--mono);font-size:12px;color:rgba(255,255,255,0.4);margin-top:16px;">3.6s → 346ms on openclaw</div>
    \\      </div>
    \\      <div style="background:rgba(5,150,105,0.08);border:1px solid rgba(5,150,105,0.2);border-radius:16px;padding:40px 32px;">
    \\        <div style="font-family:var(--sans);font-size:clamp(48px,8vw,72px);font-weight:800;letter-spacing:-0.04em;color:var(--accent-light);line-height:1;">83<span style="font-size:0.5em;opacity:0.6">%</span></div>
    \\        <div style="font-family:var(--sans);font-size:24px;font-weight:700;color:#fff;margin-top:8px;">less cold RSS.</div>
    \\        <div style="font-family:var(--mono);font-size:12px;color:rgba(255,255,255,0.4);margin-top:16px;">3.5GB → 580MB at peak</div>
    \\      </div>
    \\      <div style="background:rgba(5,150,105,0.08);border:1px solid rgba(5,150,105,0.2);border-radius:16px;padding:40px 32px;">
    \\        <div style="font-family:var(--sans);font-size:clamp(48px,8vw,72px);font-weight:800;letter-spacing:-0.04em;color:var(--accent-light);line-height:1;">92<span style="font-size:0.5em;opacity:0.6">%</span></div>
    \\        <div style="font-family:var(--sans);font-size:24px;font-weight:700;color:#fff;margin-top:8px;">less warm RSS.</div>
    \\        <div style="font-family:var(--mono);font-size:12px;color:rgba(255,255,255,0.4);margin-top:16px;">1.9GB → 150MB steady-state</div>
    \\      </div>
    \\      <div style="background:rgba(5,150,105,0.08);border:1px solid rgba(5,150,105,0.2);border-radius:16px;padding:40px 32px;">
    \\        <div style="font-family:var(--sans);font-size:clamp(48px,8vw,72px);font-weight:800;letter-spacing:-0.04em;color:var(--accent-light);line-height:1;">1000<span style="font-size:0.5em;opacity:0.6">×</span></div>
    \\        <div style="font-family:var(--sans);font-size:24px;font-weight:700;color:#fff;margin-top:8px;">faster than ripgrep.</div>
    \\        <div style="font-family:var(--mono);font-size:12px;color:rgba(255,255,255,0.4);margin-top:16px;">~500µs vs ~500ms (internal lookup)</div>
    \\      </div>
    \\    </div>
    \\  </div>
    \\</div>
    \\<div class="section" style="background:var(--bg2);color:var(--text);">
    \\  <div class="section-inner">
    \\    <div class="section-eyebrow" style="color:var(--accent);">Real-world benchmark</div>
    \\    <div class="section-heading">codedb vs fff-mcp vs ripgrep vs grep</div>
    \\    <p class="section-sub" style="color:var(--muted);">Internal search for "fn" on openclaw (6,315 files). Warm trigram index vs cold disk scan. Apple M4 Pro, median of 5 runs.</p>
    \\    <table class="bench-table" style="color:var(--text);">
    \\      <thead><tr><th>Tool</th><th>Internal search</th><th>Results</th><th>Approach</th><th>vs codedb</th></tr></thead>
    \\      <tbody>
        \\        <tr><td><strong>codedb v0.2.572</strong> (Zig)</td><td class="fast">~220 µs</td><td>12 files (22% recall)</td><td>Warm trigram</td><td class="fast">baseline</td></tr>
        \\        <tr><td>fff-mcp 0.5.2 (Rust)</td><td>~510 µs</td><td>2 files (4% recall)</td><td>Bigram + frecency</td><td>2.3× slower, 6× fewer files</td></tr>
        \\        <tr><td>ripgrep 15.1</td><td>~500 ms</td><td>~48,000 lines (all)</td><td>Disk scan</td><td>2,272× slower</td></tr>
        \\        <tr><td>GNU grep</td><td>~1,500 ms</td><td>~48,200 lines (all)</td><td>Disk scan</td><td>6,818× slower</td></tr>
    \\      </tbody>
    \\    </table>
    \\    <div style="background:var(--dark3);border-radius:8px;padding:20px;margin:24px 0;border-left:3px solid var(--accent);">
    \\      <h4 style="color:#fff;font-size:14px;margin-bottom:8px;">Why warm indices win</h4>
    \\      <p style="color:rgba(255,255,255,0.5);font-size:12px;font-family:var(--mono);line-height:1.6;margin:0;">
    \\        <strong>codedb</strong>: ~500 microseconds (0.5ms) for trigram index lookup.<br>
    \\        <strong>ripgrep/grep</strong>: 500-1,500ms for full disk scan.<br>
    \\        <br>
    \\        1,000× speedup. That is the power of indexing.
    \\      </p>
    \\    </div>
    \\    <div class="chart-row">
    \\      <div class="chart-card"><h3>Search latency (ms)</h3><canvas id="searchChart"></canvas></div>
    \\      <div class="chart-card"><h3>Results returned (log scale)</h3><canvas id="resultsChart"></canvas></div>
    \\    </div>
    \\    <p style="font-family:var(--mono);font-size:11px;color:var(--muted);margin-top:16px;">Note: Internal search times measured. codedb trigram lookup ~220µs. fff-mcp bigram+frecency ~510µs. ripgrep/grep cold disk scan 500–1,500ms.</p>
    \\  </div>
    \\</div>
    \\<div class="timeline-section" style="background:var(--dark2);color:#fff;">
    \\  <div class="section-inner">
    \\    <div class="section-eyebrow" style="color:var(--accent-light);">What changed</div>
    \\    <div class="section-heading">Key improvements</div>
    \\    <div class="timeline-grid">
    \\      <div class="timeline-card" style="background:var(--dark3);"><div class="num" style="color:var(--accent-light);">1</div><h3>Worker-local indexing</h3><p style="color:rgba(255,255,255,0.5);">Each scan worker builds its own Explorer. No lock contention during hot path. Deterministic merge for reproducible snapshots.</p></div>
    \\      <div class="timeline-card" style="background:var(--dark3);"><div class="num" style="color:var(--accent-light);">2</div><h3>Bounded id_to_path</h3><p style="color:rgba(255,255,255,0.5);">Free-list reuses freed doc_id slots. Grows only to peak live files, not total files ever indexed. Fixes 425 MB/min growth reported by @JF10R.</p></div>
    \\      <div class="timeline-card" style="background:var(--dark3);"><div class="num" style="color:var(--accent-light);">3</div><h3>WordHit compaction</h3><p style="color:rgba(255,255,255,0.5);">24 bytes → 8 bytes via packed struct + u31 line numbers. 92% warm RSS reduction.</p></div>
    \\      <div class="timeline-card" style="background:var(--dark3);"><div class="num" style="color:var(--accent-light);">4</div><h3>c_allocator + page_allocator</h3><p style="color:rgba(255,255,255,0.5);">Staggered word/trigram builds with libc malloc. 83% cold RSS reduction. Worker arenas eagerly freed.</p></div>
    \\      <div class="timeline-card" style="background:var(--dark3);"><div class="num" style="color:var(--accent-light);">5</div><h3>Git HEAD mtime gating</h3><p style="color:rgba(255,255,255,0.5);">Stats .git/HEAD mtime before forking git rev-parse. 87% fewer subprocesses on idle repos.</p></div>
    \\      <div class="timeline-card" style="background:var(--dark3);"><div class="num" style="color:var(--accent-light);">6</div><h3>MCP idle timeout</h3><p style="color:rgba(255,255,255,0.5);">10-minute idle timeout + POLLHUP detection. Zombie processes reaped; dead clients trigger immediate shutdown.</p></div>
    \\    </div>
    \\  </div>
    \\</div>
    \\<div class="timeline-section" style="background:var(--dark);color:#fff;border-top:1px solid rgba(255,255,255,0.06);">
    \\  <div class="section-inner">
    \\    <div class="section-eyebrow" style="color:var(--accent-light);">Contributors</div>
    \\    <div class="section-heading">Thanks to everyone who filed issues</div>
    \\    <div class="contributors-grid">
    \\      <div class="contributor-card" style="background:var(--dark3);"><a href="https://github.com/JF10R" style="color:var(--accent-light);">@JF10R</a><p style="color:rgba(255,255,255,0.5);">Trigram unbounded growth, drainNotifyFile dedup, ProjectCache leak</p></div>
    \\      <div class="contributor-card" style="background:var(--dark3);"><a href="https://github.com/ocordeiro" style="color:var(--accent-light);">@ocordeiro</a><p style="color:rgba(255,255,255,0.5);">Symbol.line_end population for body=true</p></div>
    \\      <div class="contributor-card" style="background:var(--dark3);"><a href="https://github.com/destroyer22719" style="color:var(--accent-light);">@destroyer22719</a><p style="color:rgba(255,255,255,0.5);">MCP disconnections with Opencode</p></div>
    \\      <div class="contributor-card" style="background:var(--dark3);"><a href="https://github.com/wilsonsilva" style="color:var(--accent-light);">@wilsonsilva</a><p style="color:rgba(255,255,255,0.5);">Unknown remote requests</p></div>
    \\      <div class="contributor-card" style="background:var(--dark3);"><a href="https://github.com/killop" style="color:var(--accent-light);">@killop</a><p style="color:rgba(255,255,255,0.5);">Windows support request</p></div>
    \\      <div class="contributor-card" style="background:var(--dark3);"><a href="https://github.com/sims1253" style="color:var(--accent-light);">@sims1253</a><p style="color:rgba(255,255,255,0.5);">R language support, PHP/Ruby telemetry fix</p></div>
    \\      <div class="contributor-card" style="background:var(--dark3);"><a href="https://github.com/JustFly1984" style="color:var(--accent-light);">@JustFly1984</a><p style="color:rgba(255,255,255,0.5);">Website DNS, version update issues</p></div>
    \\      <div class="contributor-card" style="background:var(--dark3);"><a href="https://github.com/mochadwi" style="color:var(--accent-light);">@mochadwi</a><p style="color:rgba(255,255,255,0.5);">Serena comparison discussion</p></div>
    \\      <div class="contributor-card" style="background:var(--dark3);"><a href="https://github.com/Mavis2103" style="color:var(--accent-light);">@Mavis2103</a><p style="color:rgba(255,255,255,0.5);">Memory overhead reduction ideas</p></div>
    \\      <div class="contributor-card" style="background:var(--dark3);"><a href="https://github.com/justrach" style="color:var(--accent-light);">@justrach</a><p style="color:rgba(255,255,255,0.5);">Core performance &amp; correctness work</p></div>
    \\    </div>
    \\  </div>
    \\</div>
    \\<div class="cta-section" style="background:var(--dark);color:#fff;">
    \\  <div class="cta-inner" style="border-color:rgba(255,255,255,0.08);">
    \\    <div style="font-family:var(--sans);font-size:28px;font-weight:800;margin-bottom:16px;">Ready to try v0.2.572?</div>
    \\    <div class="install-cmd" style="background:var(--dark3);border-color:rgba(255,255,255,0.08);color:rgba(255,255,255,0.7);">curl -fsSL https://codedb.codegraff.com/install.sh | bash</div>
    \\    <p style="font-size:13px;color:rgba(255,255,255,0.3);margin-top:16px;">macOS Apple Silicon (codesigned + notarized) &middot; Linux x86_64 &middot; SHA256 checksums</p>
    \\    <a href="/quickstart" class="btn btn-primary" style="margin-top:24px;">Get started</a>
    \\    <a href="https://github.com/justrach/codedb/releases/tag/v0.2.572" class="btn btn-ghost" style="border-color:rgba(255,255,255,0.15);color:rgba(255,255,255,0.6);">View release notes</a>
    \\  </div>
    \\</div>
    \\<footer class="layout-footer" style="background:var(--dark);color:rgba(255,255,255,0.2);border-top:1px solid rgba(255,255,255,0.06);">
    \\  codedb &copy; 2026 Rach Pradhan &middot; <a href="https://github.com/justrach/codedb" style="color:rgba(255,255,255,0.2);">GitHub</a> &middot; <a href="/privacy" style="color:rgba(255,255,255,0.2);">Privacy</a>
    \\</footer>
    \\<script>
    \\  const green = '#10b981', red = '#ef4444', gray = '#e5e7eb', blue = '#3b82f6', orange = '#f97316';
    \\  Chart.defaults.font.family = "'Geist Mono', monospace";
    \\  Chart.defaults.color = '#6b7280';
    \\  new Chart(document.getElementById('indexChart'), {
    \\    type: 'bar',
    \\    data: { labels: ['openclaw (6k files)', 'vitess (5k files)'], datasets: [{ label: 'v0.2.56', data: [3.6, 2.8], backgroundColor: red, borderRadius: 4 }, { label: 'v0.2.572', data: [0.346, 0.280], backgroundColor: green, borderRadius: 4 }] },
    \\    options: { responsive: true, maintainAspectRatio: false, plugins: { legend: { position: 'bottom' } }, scales: { y: { title: { display: true, text: 'Seconds' }, grid: { color: '#f3f4f6' } }, x: { grid: { display: false } } } }
    \\  });
    \\  new Chart(document.getElementById('memChart'), {
    \\    type: 'bar',
    \\    data: { labels: ['Cold RSS', 'Warm RSS'], datasets: [{ label: 'v0.2.56', data: [3500, 1900], backgroundColor: red, borderRadius: 4 }, { label: 'v0.2.572', data: [580, 150], backgroundColor: green, borderRadius: 4 }] },
    \\    options: { responsive: true, maintainAspectRatio: false, plugins: { legend: { position: 'bottom' } }, scales: { y: { title: { display: true, text: 'MB' }, grid: { color: '#f3f4f6' } }, x: { grid: { display: false } } } }
    \\  });
    \\  new Chart(document.getElementById('searchChart'), {
    \\    type: 'bar',
    \\    data: { labels: ["codedb (0.22ms)", "fff-mcp (0.51ms)", "ripgrep (~500ms)", "grep (~1500ms)"], datasets: [{ data: [0.22, 0.51, 500, 1500], backgroundColor: [green, "#3b82f6", "#9ca3af", gray], borderRadius: 4, barThickness: 32 }] },
    \\    options: { indexAxis: 'y', responsive: true, maintainAspectRatio: false, plugins: { legend: { display: false } }, scales: { x: { title: { display: true, text: 'ms (linear scale)' }, grid: { color: '#f3f4f6' } }, y: { grid: { display: false }, ticks: { font: { family: "'Geist', sans-serif", size: 13, weight: 600 }, color: '#111' } } } }
    \\  });
    \\  new Chart(document.getElementById('resultsChart'), {
    \\    type: 'bar',
    \\    data: { labels: ["codedb (12 files)", "fff-mcp (2 files)", "ripgrep (~48k lines)", "grep (~48k lines)"], datasets: [{ data: [12, 2, 48000, 48200], backgroundColor: [green, "#3b82f6", "#9ca3af", gray], borderRadius: 4, barThickness: 32 }] },
    \\    options: { indexAxis: 'y', responsive: true, maintainAspectRatio: false, plugins: { legend: { display: false } }, scales: { x: { title: { display: true, text: 'results (linear scale)' }, grid: { color: '#f3f4f6' } }, y: { grid: { display: false }, ticks: { font: { family: "'Geist', sans-serif", size: 13, weight: 600 }, color: '#111' } } } }
    \\  });
    \\  document.getElementById('burger')?.addEventListener('click', function() { this.classList.toggle('open'); document.getElementById('nav-links').classList.toggle('open'); });
    \\</script>
    \\</body>
    \\</html>
;
