const GITHUB_REPO = "justrach/codedb";
const FALLBACK_VERSION = "0.2.1";
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
  const tag = `v${version}`;
  const assetUrl = `https://github.com/${GITHUB_REPO}/releases/download/${tag}/${assetName}`;

  return new Response(null, {
    status: 302,
    headers: {
      Location: assetUrl,
      "Cache-Control": "public, max-age=300",
    },
  });
}
