// codedb — Cloudflare Workers fetch handler (static site + install binary proxy)

const GITHUB_REPO = "justrach/codedb";
const FALLBACK_VERSION = "0.2.2";

const securityHeaders = {
  "strict-transport-security": "max-age=63072000; includeSubDomains; preload",
  "x-frame-options": "DENY",
  "x-content-type-options": "nosniff",
  "referrer-policy": "strict-origin-when-cross-origin",
  "cross-origin-opener-policy": "same-origin",
  "permissions-policy": "camera=(), microphone=(), geolocation=()",
};

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const path = url.pathname;

    // /latest.json — GitHub release version
    if (path === "/latest.json") {
      return serveLatestVersion();
    }

    // /v{version}/codedb-{platform} — proxy binary from GitHub Release
    const binaryMatch = path.match(/^\/v([^\/]+)\/(.+)$/);
    if (binaryMatch) {
      const [, version, assetName] = binaryMatch;
      return proxyReleaseBinary(version, assetName);
    }

    // Everything else — try static assets from dist/
    const assetResponse = await env.ASSETS.fetch(request);
    if (assetResponse.status !== 404) {
      const response = new Response(assetResponse.body, assetResponse);
      for (const [k, v] of Object.entries(securityHeaders)) {
        response.headers.set(k, v);
      }
      return response;
    }

    return new Response("Not Found", { status: 404, headers: securityHeaders });
  },
};

async function serveLatestVersion() {
  const resp = await fetch(
    `https://api.github.com/repos/${GITHUB_REPO}/releases/latest`,
    { headers: { "User-Agent": "codedb-worker", Accept: "application/vnd.github.v3+json" } }
  );
  if (resp.ok) {
    const release = await resp.json();
    const version = release.tag_name.replace(/^v/, "");
    return new Response(JSON.stringify({ version }), {
      headers: { "Content-Type": "application/json", "Cache-Control": "public, max-age=300" },
    });
  }
  return new Response(JSON.stringify({ version: FALLBACK_VERSION }), {
    headers: { "Content-Type": "application/json", "Cache-Control": "public, max-age=60" },
  });
}

async function proxyReleaseBinary(version, assetName) {
  const tag = `v${version}`;
  const releaseResp = await fetch(
    `https://api.github.com/repos/${GITHUB_REPO}/releases/tags/${tag}`,
    { headers: { "User-Agent": "codedb-worker", Accept: "application/vnd.github.v3+json" } }
  );
  if (!releaseResp.ok) {
    return new Response(`release ${tag} not found`, { status: 404 });
  }
  const release = await releaseResp.json();
  let asset = release.assets.find((a) => a.name === assetName);
  if (!asset) {
    const bare = assetName.replace(/-darwin-arm64|-darwin-x86_64|-linux-arm64|-linux-x86_64/, "");
    asset = release.assets.find((a) => a.name === bare);
  }
  if (!asset) {
    return new Response(
      `asset "${assetName}" not found in release ${tag}\navailable: ${release.assets.map((a) => a.name).join(", ")}`,
      { status: 404 }
    );
  }
  const binaryResp = await fetch(asset.browser_download_url, {
    headers: { "User-Agent": "codedb-worker" },
    redirect: "follow",
  });
  if (!binaryResp.ok) {
    return new Response("failed to download binary", { status: 502 });
  }
  return new Response(binaryResp.body, {
    headers: {
      "Content-Type": "application/octet-stream",
      "Content-Disposition": `attachment; filename="${assetName}"`,
      "Cache-Control": "public, max-age=86400",
    },
  });
}
