const mer = @import("mer");

pub const meta: mer.Meta = .{
    .title = "What's New in v0.2.52",
    .description = "36% faster indexing, 59% less CPU, 47% less memory, 21 issues closed.",
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
    \\  <title>What's New — codedb v0.2.52</title>
    \\  <link rel="preconnect" href="https://fonts.googleapis.com">
    \\  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    \\  <link href="https://fonts.googleapis.com/css2?family=Space+Grotesk:wght@400;500;600;700;800&family=Inter:wght@400;500;600&family=JetBrains+Mono:wght@400;500&display=swap" rel="stylesheet">
    \\  <style>
    \\    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
    \\    :root {
    \\      --bg: #f9f8f6; --bg2: #f2f0ec; --bg3: #e9e5de;
    \\      --dark: #0e0d0b; --dark2: #1a1916; --dark3: #252320;
    \\      --text: #0e0d0b; --muted: #8a8478; --border: #ddd9d2;
    \\      --accent: #3b82f6; --accent-dim: rgba(59,130,246,0.15);
    \\      --green: #2d7a3f;
    \\      --mono: 'JetBrains Mono', monospace;
    \\      --sans: 'Inter', sans-serif;
    \\      --display: 'Space Grotesk', sans-serif;
    \\    }
    \\    html { scroll-behavior: smooth; }
    \\    body { background: var(--dark); color: var(--text); font-family: var(--sans); min-height: 100vh; overflow-x: hidden; }
    \\    a { color: inherit; text-decoration: none; }
    \\    nav { position: sticky; top: 0; z-index: 100; background: rgba(14,13,11,0.9); backdrop-filter: blur(12px); border-bottom: 1px solid rgba(255,255,255,0.08); }
    \\    .nav-inner { max-width: 1100px; margin: 0 auto; padding: 0 40px; display: flex; align-items: center; justify-content: space-between; height: 60px; }
    \\    .wordmark { font-family: var(--display); font-size: 16px; font-weight: 800; letter-spacing: -0.02em; color: #fff; }
    \\    .wordmark em { font-style: normal; color: var(--accent); }
    \\    .nav-links { display: flex; gap: 32px; align-items: center; }
    \\    .nav-links a { font-size: 13px; font-weight: 500; color: rgba(255,255,255,0.5); letter-spacing: 0.01em; transition: color 0.15s; }
    \\    .nav-links a:hover { color: #fff; }
    \\    .nav-cta { font-family: var(--display); font-size: 13px !important; font-weight: 700 !important; color: #fff !important; background: var(--accent); padding: 8px 18px; border-radius: 4px; }
    \\    .hero { padding: 80px 40px 0; max-width: 1100px; margin: 0 auto; }
    \\    .hero-label { font-family: var(--mono); font-size: 11px; font-weight: 500; letter-spacing: 0.14em; text-transform: uppercase; color: var(--accent); margin-bottom: 20px; display: flex; align-items: center; gap: 10px; }
    \\    .hero-label::before { content: ''; display: inline-block; width: 20px; height: 1px; background: var(--accent); }
    \\    .hero-headline { font-family: var(--display); font-size: clamp(44px, 7vw, 88px); font-weight: 800; letter-spacing: -0.04em; line-height: 0.95; color: #fff; margin-bottom: 16px; }
    \\    .hero-headline .hl { color: var(--accent); }
    \\    .hero-sub { font-family: var(--mono); font-size: 12px; color: rgba(255,255,255,0.35); letter-spacing: 0.04em; margin-bottom: 64px; }
    \\    .stat-row { display: grid; grid-template-columns: repeat(4,1fr); border-top: 1px solid rgba(255,255,255,0.08); }
    \\    @media (max-width: 700px) { .stat-row { grid-template-columns: repeat(2,1fr); } }
    \\    .stat-cell { padding: 32px 0 40px; border-right: 1px solid rgba(255,255,255,0.08); padding-right: 32px; }
    \\    .stat-cell:last-child { border-right: none; }
    \\    .stat-val { font-family: var(--display); font-size: clamp(32px, 4vw, 52px); font-weight: 800; letter-spacing: -0.04em; color: #fff; line-height: 1; margin-bottom: 4px; }
    \\    .stat-val .unit { font-size: 0.45em; font-weight: 600; color: rgba(255,255,255,0.4); letter-spacing: 0; vertical-align: super; margin-left: 2px; }
    \\    .stat-label { font-family: var(--mono); font-size: 11px; color: rgba(255,255,255,0.4); letter-spacing: 0.08em; text-transform: uppercase; margin-bottom: 8px; }
    \\    .stat-delta { font-family: var(--mono); font-size: 11px; color: var(--accent); letter-spacing: 0.02em; }
    \\    .section { padding: 80px 40px; }
    \\    .section-inner { max-width: 1100px; margin: 0 auto; }
    \\    .section-eyebrow { font-family: var(--mono); font-size: 11px; font-weight: 500; letter-spacing: 0.12em; text-transform: uppercase; color: var(--accent); margin-bottom: 10px; }
    \\    .section-heading { font-family: var(--display); font-size: clamp(22px, 3vw, 32px); font-weight: 800; letter-spacing: -0.025em; margin-bottom: 32px; }
    \\    .chart-row { display: grid; grid-template-columns: 1fr 1fr; gap: 32px; margin: 48px 0; }
    \\    @media (max-width: 700px) { .chart-row { grid-template-columns: 1fr; } }
    \\    .chart-card { background: #fff; border: 1px solid var(--border); border-radius: 8px; padding: 24px; }
    \\    .chart-card h3 { font-family: var(--display); font-size: 15px; font-weight: 700; color: var(--dark); margin-bottom: 16px; }
    \\    .chart-card canvas { width: 100% !important; height: 280px !important; }
    \\    .changes-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 2px; margin-top: 2px; }
    \\    @media (max-width: 700px) { .changes-grid { grid-template-columns: 1fr; } }
    \\    .change-card { background: var(--dark3); padding: 32px; border-radius: 4px; }
    \\    .change-card h3 { font-family: var(--display); font-size: 15px; font-weight: 700; color: #fff; margin-bottom: 8px; }
    \\    .change-card p { font-size: 13px; color: rgba(255,255,255,0.4); line-height: 1.7; font-family: var(--mono); }
    \\    .change-card .tag { display: inline-block; font-family: var(--mono); font-size: 10px; font-weight: 600; padding: 2px 8px; border-radius: 3px; margin-bottom: 12px; }
    \\    .tag-sec { background: rgba(239,68,68,0.15); color: #f87171; }
    \\    .tag-perf { background: rgba(59,130,246,0.15); color: #60a5fa; }
    \\    .tag-fix { background: rgba(251,191,36,0.15); color: #fbbf24; }
    \\    .tag-doc { background: rgba(168,85,247,0.15); color: #c084fc; }
    \\    .install-section { background: var(--dark); padding: 0 40px 100px; }
    \\    .install-inner { max-width: 1100px; margin: 0 auto; border-top: 1px solid rgba(255,255,255,0.08); padding-top: 48px; text-align: center; }
    \\    .install-cmd { font-family: var(--mono); font-size: 15px; color: rgba(255,255,255,0.7); background: var(--dark3); padding: 20px 32px; border-radius: 8px; display: inline-block; margin: 24px 0; border: 1px solid rgba(255,255,255,0.08); }
    \\    .contributors { font-family: var(--mono); font-size: 13px; color: rgba(255,255,255,0.3); margin-top: 32px; }
    \\    .contributors a { color: var(--accent); }
    \\    .layout-footer { padding: 20px 40px; border-top: 1px solid rgba(255,255,255,0.06); font-size: 11px; color: rgba(255,255,255,0.2); text-align: center; font-family: var(--mono); letter-spacing: 0.04em; background: var(--dark); }
    \\    .layout-footer a { color: rgba(255,255,255,0.3); }
    \\    /* Override layout wrapper constraints */
    \\    .layout { max-width: none !important; padding: 0 !important; }
    \\    .stat-row { display: grid !important; grid-template-columns: repeat(4,1fr) !important; }
    \\    @media (max-width: 700px) { .stat-row { grid-template-columns: repeat(2,1fr) !important; } }
    \\  </style>
    \\</head>
    \\<body>
    \\<nav><div class="nav-inner">
    \\  <a href="/" class="wordmark">code<em>db</em></a>
    \\  <div class="nav-links">
    \\    <a href="/benchmarks">Benchmarks</a>
    \\    <a href="/improvements">Improvements</a>
    \\    <a href="/quickstart">Install</a>
    \\    <a href="https://github.com/justrach/codedb">GitHub</a>
    \\    <a href="/quickstart" class="nav-cta">Get started</a>
    \\  </div>
    \\</div></nav>
    \\
    \\<div style="background:var(--dark);">
    \\  <div class="hero">
    \\    <div class="hero-headline">
    \\      <span class="hl">538x</span> faster<br>code search.
    \\    </div>
    \\    <div class="hero-sub">codedb vs ripgrep vs grep on rtk-ai/rtk &nbsp;&middot;&nbsp; 36% faster indexing &nbsp;&middot;&nbsp; 21 issues closed &nbsp;&middot;&nbsp; 7 contributors</div>
    \\    <div class="stat-row">
    \\      <div class="stat-cell">
    \\        <div class="stat-label">Index time</div>
    \\        <div class="stat-val">310<span class="unit">ms</span></div>
    \\        <div class="stat-delta">was 481ms (-36%)</div>
    \\      </div>
    \\      <div class="stat-cell" style="padding-left:32px;">
    \\        <div class="stat-label">CPU usage</div>
    \\        <div class="stat-val">59<span class="unit">%</span></div>
    \\        <div class="stat-delta">less user CPU</div>
    \\      </div>
    \\      <div class="stat-cell" style="padding-left:32px;">
    \\        <div class="stat-label">Memory</div>
    \\        <div class="stat-val">47<span class="unit">%</span></div>
    \\        <div class="stat-delta">less at 40k files</div>
    \\      </div>
    \\      <div class="stat-cell" style="padding-left:32px;">
    \\        <div class="stat-label">Dense search</div>
    \\        <div class="stat-val">63<span class="unit">%</span></div>
    \\        <div class="stat-delta">faster queries</div>
    \\      </div>
    \\    </div>
    \\  </div>
    \\</div>
    \\
    \\<!-- Charts -->
    \\<div class="section" style="background:var(--bg);">
    \\  <div class="section-inner">
    \\    <div class="section-eyebrow">Performance</div>
    \\    <div class="section-heading" style="color:var(--dark);">Before &amp; after on 5,200 files</div>
    \\    <div class="chart-row">
    \\      <div class="chart-card">
    \\        <h3>Indexing time (ms)</h3>
    \\        <canvas id="indexChart"></canvas>
    \\      </div>
    \\      <div class="chart-card">
    \\        <h3>Peak memory (MB)</h3>
    \\        <canvas id="memChart"></canvas>
    \\      </div>
    \\    </div>
    \\    <div class="chart-row">
    \\      <div class="chart-card">
    \\        <h3>Search latency &mdash; dense query (&#181;s)</h3>
    \\        <canvas id="searchChart"></canvas>
    \\      </div>
    \\      <div class="chart-card">
    \\        <h3>CPU time &mdash; user (ms)</h3>
    \\        <canvas id="cpuChart"></canvas>
    \\      </div>
    \\    </div>
    \\  </div>
    \\  </div>
    \\<!-- Benchmark: codedb vs rtk vs ripgrep vs grep -->
    \\<div class="section" style="background:var(--bg2);">
    \\  <div class="section-inner">
    \\    <div class="section-eyebrow">Real-world benchmark</div>
    \\    <div class="section-heading" style="color:var(--dark);">codedb vs rtk vs ripgrep vs grep</div>
    \\    <p style="font-size:14px;color:var(--muted);margin:-16px 0 32px;max-width:700px;line-height:1.7;">Searching for &ldquo;agent&rdquo; across 329 files. <a href="https://github.com/rtk-ai/rtk" style="color:var(--accent);">rtk</a> is a Rust-based code search tool. codedb uses a pre-built trigram index for sub-millisecond queries after a one-time 126ms index.</p>
    \\    <div class="chart-row">
    \\      <div class="chart-card">
    \\        <h3>Search latency (ms, log scale)</h3>
    \\        <canvas id="rtkChart"></canvas>
    \\      </div>
    \\      <div class="chart-card">
    \\        <h3>Speedup vs codedb</h3>
    \\        <canvas id="speedupChart"></canvas>
    \\      </div>
    \\    </div>
    \\    <p style="font-family:var(--mono);font-size:11px;color:var(--muted);margin-top:-16px;">codedb keeps a pre-built trigram index in memory. Other tools scan from disk on every query. Apple M4 Pro, macOS, codedb v0.2.52, rtk 0.1.0, ripgrep 15.1, GNU grep. 5 runs, median.</p>
    \\  </div>
    \\</div>
    \\</div>
    \\<!-- Changes -->
    \\<div class="section" style="background:var(--dark2);">
    \\  <div class="section-inner">
    \\    <div class="section-eyebrow">Changelog</div>
    \\    <div class="section-heading" style="color:#fff;">What changed</div>
    \\    <div class="changes-grid">
    \\      <div class="change-card"><div class="tag tag-sec">security</div><h3>Sensitive file blocking</h3><p>codedb_read and codedb_edit now block .env, credentials, keys, .pem files via MCP tools.</p></div>
    \\      <div class="change-card"><div class="tag tag-sec">security</div><h3>SSRF fix + checksum verification</h3><p>codedb_remote validated against whitelist. Installer now verifies SHA256 checksums after download.</p></div>
    \\      <div class="change-card"><div class="tag tag-perf">performance</div><h3>Integer doc IDs</h3><p>Trigram postings use u32 doc IDs instead of string HashMaps. Sorted merge intersection with zero allocations.</p></div>
    \\      <div class="change-card"><div class="tag tag-perf">performance</div><h3>Batch-accumulate trigrams</h3><p>Local HashMap per file, bulk-insert to global index. Skip whitespace-only trigrams (12% of occurrences).</p></div>
    \\      <div class="change-card"><div class="tag tag-perf">performance</div><h3>Memory optimization</h3><p>Release file contents after indexing. Zero-copy ContentRef for search. 47% less memory at 40k files.</p></div>
    \\      <div class="change-card"><div class="tag tag-fix">fix</div><h3>Python &amp; TypeScript parsers</h3><p>Triple-quote docstrings, block comments, import alias handling. Fixed dependency matching for Python imports.</p></div>
    \\      <div class="change-card"><div class="tag tag-fix">fix</div><h3>MCP reliability</h3><p>10-minute idle timeout. Faster disconnect exit via stdin polling. Singleton PID lock. Fixed crash on exit (duplicate thread join). Linux /bin/bash update.</p></div>
    \\      <div class="change-card"><div class="tag tag-doc">docs</div><h3>16 MCP tools documented</h3><p>Added codedb_bundle, codedb_remote, codedb_projects, codedb_index. CLI commands table in README.</p></div>
    \\    </div>
    \\  </div>
    \\</div>
    \\
    \\<!-- Install -->
    \\<div class="install-section">
    \\  <div class="install-inner">
    \\    <div class="section-heading" style="color:#fff;">Update now</div>
    \\    <div class="install-cmd">curl -fsSL https://codedb.codegraff.com/install.sh | bash</div>
    \\    <p style="font-size:13px;color:rgba(255,255,255,0.3);margin-top:16px;">macOS Apple Silicon (codesigned + notarized) &middot; Linux x86_64 &middot; SHA256 checksums</p>
    \\    <div class="contributors">
    \\      Thanks to <a href="https://github.com/whygee-dev">@whygee-dev</a> &middot;
    \\      <a href="https://github.com/unliftedq">@unliftedq</a> &middot;
    \\      <a href="https://github.com/riccardodm97">@riccardodm97</a> &middot;
    \\      <a href="https://github.com/dezren39">@dezren39</a> &middot;
    \\      <a href="https://github.com/sanderdewijs">@sanderdewijs</a> &middot;
    \\      <a href="https://github.com/burningportra">@burningportra</a> &middot;
    \\      <a href="https://github.com/kenrick-g">@kenrick-g</a>
    \\    </div>
    \\  </div>
    \\</div>
    \\
    \\<footer class="layout-footer">
    \\  codedb &mdash; code intelligence for AI agents &middot; <a href="https://github.com/justrach/codedb">GitHub</a>
    \\</footer>
    \\
    \\<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.0/dist/chart.umd.min.js"></script>
    \\<script>
    \\var barOpts = {indexAxis:'y',responsive:true,maintainAspectRatio:false,plugins:{legend:{display:false}},scales:{x:{grid:{color:'#eee'},ticks:{font:{family:'JetBrains Mono',size:11}}},y:{grid:{display:false},ticks:{font:{family:'Space Grotesk',size:13,weight:600}}}}};
    \\var colors = {old:'rgba(220,210,200,0.7)',new:'rgba(59,130,246,0.85)'};
    \\new Chart(document.getElementById('indexChart'),{type:'bar',data:{labels:['v0.2.3 - 481ms','v0.2.52 - 310ms'],datasets:[{data:[481,310],backgroundColor:[colors.old,colors.new],borderRadius:4,barThickness:36}]},options:barOpts});
    \\new Chart(document.getElementById('memChart'),{type:'bar',data:{labels:['v0.2.3 - 447MB','v0.2.52 - 234MB'],datasets:[{data:[447,234],backgroundColor:[colors.old,colors.new],borderRadius:4,barThickness:36}]},options:barOpts});
    \\new Chart(document.getElementById('searchChart'),{type:'bar',data:{labels:['v0.2.3 - 763us','v0.2.52 - 280us'],datasets:[{data:[763,280],backgroundColor:[colors.old,colors.new],borderRadius:4,barThickness:36}]},options:barOpts});
    \\new Chart(document.getElementById('cpuChart'),{type:'bar',data:{labels:['v0.2.3 - 290ms','v0.2.52 - 120ms'],datasets:[{data:[290,120],backgroundColor:[colors.old,colors.new],borderRadius:4,barThickness:36}]},options:barOpts});
    \\var linOpts = {indexAxis:'y',responsive:true,maintainAspectRatio:false,plugins:{legend:{display:false}},scales:{x:{grid:{color:'#eee'},ticks:{font:{family:'JetBrains Mono',size:11},callback:function(v){return v+'ms';}}},y:{grid:{display:false},ticks:{font:{family:'Space Grotesk',size:12,weight:600}}}}};
    \\var cmpColors = ['rgba(59,130,246,0.85)','rgba(234,88,12,0.6)','rgba(220,210,200,0.6)','rgba(190,180,170,0.6)'];
    \\new Chart(document.getElementById('rtkChart'),{type:'bar',data:{labels:['codedb (0.065ms)','rtk (37ms)','ripgrep (45ms)','grep (80ms)'],datasets:[{data:[0.065,37,45,80],backgroundColor:cmpColors,borderRadius:4,barThickness:28}]},options:linOpts});
    \\new Chart(document.getElementById('speedupChart'),{type:'bar',data:{labels:['grep - 1231x slower','ripgrep - 692x slower','rtk - 569x slower','codedb - baseline'],datasets:[{data:[1231,692,569,1],backgroundColor:['rgba(190,180,170,0.6)','rgba(220,210,200,0.6)','rgba(234,88,12,0.6)','rgba(59,130,246,0.85)'],borderRadius:4,barThickness:28}]},options:{indexAxis:'y',responsive:true,maintainAspectRatio:false,plugins:{legend:{display:false}},scales:{x:{grid:{color:'#eee'},ticks:{font:{family:'JetBrains Mono',size:11},callback:function(v){return v+'x';}}},y:{grid:{display:false},ticks:{font:{family:'Space Grotesk',size:12,weight:600}}}}}});
    \\</script>
    \\</body>
    \\</html>
;
