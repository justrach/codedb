const std = @import("std");
const mer = @import("mer");

pub fn wrap(allocator: std.mem.Allocator, path: []const u8, body: []const u8, meta: mer.Meta) []const u8 {
    const title = if (meta.title.len > 0) meta.title else if (std.mem.eql(u8, path, "/")) "Home" else if (path.len > 1) path[1..] else "codedb";
    const desc = if (meta.description.len > 0) meta.description else "Code intelligence server for AI agents. Zig core. MCP native. Zero dependencies.";

    var buf: std.ArrayList(u8) = .{};
    const w = buf.writer(allocator);

    w.writeAll(
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\<head>
        \\  <meta charset="UTF-8">
        \\  <meta name="viewport" content="width=device-width, initial-scale=1.0">
        \\  <link rel="preconnect" href="https://fonts.googleapis.com">
        \\  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
        \\  <link href="https://fonts.googleapis.com/css2?family=Geist:wght@400;500;600;700;800&family=Geist+Mono:wght@400;500&display=swap" rel="stylesheet">
        \\
    ) catch return body;

    w.print("  <title>{s} — codedb</title>\n", .{title}) catch return body;
    w.print("  <meta name=\"description\" content=\"{s}\">\n", .{desc}) catch return body;
    w.writeAll(
        \\  <meta name="robots" content="index, follow">
        \\  <meta property="og:type" content="website">
        \\  <meta property="og:site_name" content="codedb">
        \\  <meta name="twitter:card" content="summary_large_image">
        \\  <meta name="twitter:site" content="@justrach">
        \\  <script type="application/ld+json">{"@context":"https://schema.org","@type":"SoftwareApplication","name":"codedb","description":"Code intelligence server for AI agents. Zig core. MCP native. Sub-millisecond queries.","applicationCategory":"DeveloperApplication","operatingSystem":"Linux, macOS","offers":{"@type":"Offer","price":"0","priceCurrency":"USD"},"url":"https://codedb.codegraff.com"}</script>
        \\
    ) catch return body;

    w.writeAll(
        \\  <style>
        \\    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
        \\    :root {
        \\      --bg: #ffffff; --bg2: #f7faf8; --bg3: #eef5f0;
        \\      --text: #111; --muted: #6b7280; --border: #e0e7e2;
        \\      --accent: #059669; --accent-light: #10b981; --accent-dim: rgba(5,150,105,0.10);
        \\      --green: #059669;
        \\      --mono: 'Geist Mono', ui-monospace, monospace;
        \\      --sans: 'Geist', system-ui, sans-serif;
        \\      --display: 'Geist', system-ui, sans-serif;
        \\    }
        \\    html { scroll-behavior: smooth; }
        \\    body { background: var(--bg); color: var(--text); font-family: var(--sans); min-height: 100vh; line-height: 1.6; overflow-x: hidden; }
        \\    a { color: inherit; text-decoration: none; }
        \\    code { font-family: var(--mono); font-size: 0.85em; background: var(--bg3); border: 1px solid var(--border); border-radius: 4px; padding: 2px 7px; color: var(--accent); }
        \\    pre { background: var(--bg2); border: 1px solid var(--border); border-radius: 8px; padding: 20px 24px; overflow-x: auto; font-family: var(--mono); font-size: 13px; line-height: 1.7; color: var(--text); margin: 16px 0; }
        \\    pre code { background: none; border: none; padding: 0; font-size: inherit; color: inherit; }
        \\
        \\    /* Nav */
        \\    nav { position: sticky; top: 0; z-index: 100; background: rgba(255,255,255,0.92); backdrop-filter: blur(16px); border-bottom: 1px solid var(--border); }
        \\    .nav-inner { max-width: 1060px; margin: 0 auto; padding: 0 32px; display: flex; align-items: center; justify-content: space-between; height: 60px; }
        \\    .wordmark { font-family: var(--sans); font-size: 17px; font-weight: 800; letter-spacing: -0.02em; }
        \\    .wordmark em { font-style: normal; color: var(--accent); }
        \\    .nav-links { display: flex; gap: 32px; align-items: center; }
        \\    .nav-links a { font-size: 13px; font-weight: 500; color: var(--muted); letter-spacing: 0.01em; transition: color 0.15s; }
        \\    .nav-links a:hover { color: var(--text); }
        \\    .nav-cta { font-family: var(--sans); font-size: 13px !important; font-weight: 700 !important; color: #fff !important; background: var(--accent); padding: 8px 18px; border-radius: 6px; transition: background 0.15s; }
        \\    .nav-cta:hover { background: #15803d; }
        \\    .nav-burger { display: none; flex-direction: column; gap: 5px; background: none; border: none; cursor: pointer; padding: 4px; }
        \\    .nav-burger span { display: block; width: 22px; height: 2px; background: var(--text); border-radius: 2px; transition: transform 0.2s, opacity 0.2s; }
        \\    .nav-burger.open span:nth-child(1) { transform: translateY(7px) rotate(45deg); }
        \\    .nav-burger.open span:nth-child(2) { opacity: 0; }
        \\    .nav-burger.open span:nth-child(3) { transform: translateY(-7px) rotate(-45deg); }
        \\    @media (max-width: 640px) {
        \\      .nav-burger { display: flex; }
        \\      .nav-links { display: none; flex-direction: column; gap: 0; position: absolute; top: 60px; left: 0; right: 0; background: rgba(255,255,255,0.97); backdrop-filter: blur(12px); border-bottom: 1px solid var(--border); padding: 8px 0; }
        \\      .nav-links.open { display: flex; }
        \\      .nav-links a { padding: 14px 24px; font-size: 15px; }
        \\      .nav-cta { margin: 8px 24px 12px; padding: 12px 20px; border-radius: 6px; text-align: center; }
        \\    }
        \\
        \\    /* Layout */
        \\    .layout { max-width: 1060px; margin: 0 auto; padding: 56px 32px 96px; }
        \\    @media (max-width: 640px) { .layout { padding: 40px 20px 72px; } }
        \\
        \\    /* Docs content */
        \\    .docs h1 { font-family: var(--sans); font-size: clamp(26px, 4vw, 40px); font-weight: 800; letter-spacing: -0.025em; margin-bottom: 8px; }
        \\    .docs h2 { font-family: var(--sans); font-size: 20px; font-weight: 700; letter-spacing: -0.01em; margin: 48px 0 12px; padding-top: 48px; border-top: 1px solid var(--border); }
        \\    .docs h2:first-of-type { margin-top: 32px; border-top: none; padding-top: 0; }
        \\    .docs p { color: var(--muted); font-size: 15px; margin-bottom: 16px; line-height: 1.7; }
        \\    .docs ul, .docs ol { color: var(--muted); font-size: 15px; margin: 12px 0 16px 20px; line-height: 1.8; }
        \\    .section-label { font-family: var(--mono); font-size: 11px; font-weight: 600; letter-spacing: 0.14em; text-transform: uppercase; color: var(--accent); margin-bottom: 12px; }
        \\    .section-title { font-family: var(--sans); font-size: clamp(22px, 4vw, 36px); font-weight: 700; letter-spacing: -0.02em; margin-bottom: 24px; }
        \\    .hero-actions { display: flex; gap: 12px; flex-wrap: wrap; margin-top: 24px; }
        \\    .btn { display: inline-flex; align-items: center; font-family: var(--sans); font-size: 14px; font-weight: 700; padding: 12px 24px; border-radius: 8px; background: var(--accent); color: #fff; transition: all 0.2s; }
        \\    .btn:hover { background: #15803d; transform: translateY(-1px); box-shadow: 0 4px 12px rgba(22,163,74,0.25); }
        \\    .btn-outline { background: transparent; border: 1px solid var(--border); color: var(--muted); font-weight: 500; }
        \\    .btn-outline:hover { color: var(--text); border-color: var(--accent); background: var(--accent-dim); transform: none; box-shadow: none; }
        \\    .badge { display: inline-flex; align-items: center; font-family: var(--mono); font-size: 11px; padding: 3px 10px; border-radius: 99px; border: 1px solid var(--border); color: var(--muted); letter-spacing: 0.06em; }
        \\    .badge-green { border-color: rgba(22,163,74,0.3); color: var(--green); background: rgba(22,163,74,0.06); }
        \\    .badge-blue { border-color: rgba(22,163,74,0.3); color: var(--accent); background: rgba(22,163,74,0.08); }
        \\    .status-table { width: 100%; border-collapse: collapse; font-size: 14px; margin: 20px 0; }
        \\    .status-table td { padding: 10px 12px; border-bottom: 1px solid var(--border); }
        \\    .ok { color: var(--green); }
        \\    .wip { color: var(--accent); }
        \\    .bench-table { width: 100%; border-collapse: collapse; margin: 24px 0; font-size: 14px; }
        \\    .bench-table th { text-align: left; padding: 10px 16px; color: var(--muted); font-family: var(--mono); font-size: 11px; font-weight: 500; text-transform: uppercase; letter-spacing: 0.08em; border-bottom: 2px solid var(--border); }
        \\    .bench-table td { padding: 12px 16px; border-bottom: 1px solid var(--border); }
        \\    .bench-table tr.highlight td { color: var(--accent); font-weight: 600; }
        \\    .cta-section { margin: 80px 0 0; padding: 48px; background: var(--bg2); border: 1px solid var(--border); border-radius: 12px; text-align: center; }
        \\    .cta-title { font-family: var(--sans); font-size: 26px; font-weight: 700; letter-spacing: -0.02em; margin-bottom: 12px; }
        \\    .cta-sub { color: var(--muted); font-size: 14px; margin-bottom: 28px; }
        \\    .layout-footer { margin-top: 80px; padding-top: 20px; border-top: 1px solid var(--border); font-size: 12px; color: var(--muted); text-align: center; font-family: var(--mono); letter-spacing: 0.02em; }
        \\    .layout-footer a { color: var(--muted); }
        \\    .layout-footer a:hover { color: var(--accent); }
        \\    .prop-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; margin: 16px 0 8px; }
        \\    @media (max-width: 600px) { .prop-grid { grid-template-columns: 1fr; } }
        \\    .prop-card { background: var(--bg2); border: 1px solid var(--border); border-radius: 10px; padding: 16px 18px; }
        \\    .prop-title { font-family: var(--sans); font-size: 14px; font-weight: 700; color: var(--text); margin-bottom: 6px; }
        \\    .prop-desc { font-size: 13px; color: var(--muted); line-height: 1.6; }
        \\  </style>
        \\
    ) catch return body;

    if (meta.extra_head) |extra| {
        w.writeAll(extra) catch {};
        w.writeAll("\n") catch {};
    }

    w.writeAll(
        \\</head>
        \\<body>
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
        \\<div class="layout">
        \\
    ) catch return body;

    w.writeAll(body) catch return body;

    w.writeAll(
        \\
        \\  <footer class="layout-footer">
        \\    <p>codedb &middot; code intelligence for AI agents &middot; <a href="https://github.com/justrach/codedb">GitHub</a></p>
        \\  </footer>
        \\</div>
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
    ) catch return body;

    return buf.items;
}
