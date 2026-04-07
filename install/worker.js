const GITHUB_REPO = "justrach/codedb";
const FALLBACK_VERSION = "0.2.55";
const INSTALL_SCRIPT_URL = `https://raw.githubusercontent.com/${GITHUB_REPO}/main/install/install.sh`;

export default {
  async fetch(request) {
    const url = new URL(request.url);
    const path = url.pathname;

    // GET / or /install.sh → serve the install script
    if (path === "/" || path === "/install.sh") {
      return serveInstallScript();
    }

    // GET /latest.json → fetch latest release from GitHub
    if (path === "/latest.json") {
      return serveLatestVersion();
    }

    // GET /v{version}/codedb-{platform} → proxy binary from GitHub Release
    const binaryMatch = path.match(/^\/v([^/]+)\/(.+)$/);
    if (binaryMatch) {
      const [, version, assetName] = binaryMatch;
      return proxyReleaseBinary(version, assetName);
    }

    return new Response("not found", { status: 404 });
  },
};

async function serveInstallScript() {
  // Fetch install.sh from the repo (always up to date)
  const resp = await fetch(
    `https://raw.githubusercontent.com/${GITHUB_REPO}/main/install/install.sh`,
    { headers: { "User-Agent": "codedb-worker" } }
  );

  if (!resp.ok) {
    return new Response("failed to fetch install script", { status: 502 });
  }

  const body = await resp.text();
  return new Response(body, {
    headers: {
      "Content-Type": "text/plain; charset=utf-8",
      "Cache-Control": "public, max-age=300",
    },
  });
}

async function serveLatestVersion() {
  const resp = await fetch(
    `https://api.github.com/repos/${GITHUB_REPO}/releases/latest`,
    { headers: { "User-Agent": "codedb-worker", Accept: "application/vnd.github.v3+json" } }
  );

  if (resp.ok) {
    const release = await resp.json();
    const version = release.tag_name.replace(/^v/, "");
    return new Response(JSON.stringify({ version }), {
      headers: {
        "Content-Type": "application/json",
        "Cache-Control": "public, max-age=300",
      },
    });
  }

  // Fallback: hardcoded latest version (update on each release)
  return new Response(JSON.stringify({ version: FALLBACK_VERSION }), {
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "public, max-age=60",
    },
  });
}

async function proxyReleaseBinary(version, assetName) {
  // First, get the release by tag to find the asset download URL
  const tag = `v${version}`;
  const releaseResp = await fetch(
    `https://api.github.com/repos/${GITHUB_REPO}/releases/tags/${tag}`,
    { headers: { "User-Agent": "codedb-worker", Accept: "application/vnd.github.v3+json" } }
  );

  if (!releaseResp.ok) {
    return new Response(`release ${tag} not found`, { status: 404 });
  }

  const release = await releaseResp.json();

  // Find the matching asset
  // Asset names on GitHub: "codedb-darwin-arm64", "codedb-linux-x86_64", etc.
  // If the release just has "codedb" (no platform suffix), try exact match first then bare name
  let asset = release.assets.find((a) => a.name === assetName);
  if (!asset) {
    // Fallback: if only "codedb" exists in release, map to it
    const bare = assetName.replace(/-darwin-arm64|-darwin-x86_64|-linux-arm64|-linux-x86_64/, "");
    asset = release.assets.find((a) => a.name === bare);
  }

  if (!asset) {
    return new Response(
      `asset "${assetName}" not found in release ${tag}\navailable: ${release.assets.map((a) => a.name).join(", ")}`,
      { status: 404 }
    );
  }

  // Proxy the binary from GitHub
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
