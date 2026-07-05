#!/usr/bin/env node
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const https = require("node:https");
const { pipeline } = require("node:stream/promises");

const pkg = require("../package.json");
const VERSION = pkg.version;
const REPO = "justrach/codedb";

const PLATFORM_MAP = {
  "darwin-arm64": "codedb-darwin-arm64",
  "darwin-x64": "codedb-darwin-x86_64",
  "linux-arm64": "codedb-linux-arm64",
  "linux-x64": "codedb-linux-x86_64",
  "win32-x64": "codedb-windows-x86_64.exe",
};

function logErr(msg) {
  process.stderr.write(`[codedeebee postinstall] ${msg}\n`);
}

function log(msg) {
  if (process.env.npm_config_loglevel === "silent") return;
  process.stderr.write(`[codedeebee postinstall] ${msg}\n`);
}

function get(url, redirectsLeft = 5) {
  return new Promise((resolve, reject) => {
    const req = https.get(
      url,
      {
        headers: {
          "User-Agent": `codedeebee-postinstall/${VERSION} node/${process.version}`,
          Accept: "application/octet-stream",
        },
      },
      (res) => {
        const status = res.statusCode || 0;
        if (status >= 300 && status < 400 && res.headers.location) {
          if (redirectsLeft <= 0) {
            res.resume();
            reject(new Error(`too many redirects fetching ${url}`));
            return;
          }
          const next = new URL(res.headers.location, url).toString();
          res.resume();
          resolve(get(next, redirectsLeft - 1));
          return;
        }
        if (status < 200 || status >= 300) {
          res.resume();
          reject(new Error(`HTTP ${status} fetching ${url}`));
          return;
        }
        resolve(res);
      }
    );
    req.on("error", reject);
    req.setTimeout(60_000, () => {
      req.destroy(new Error(`timeout fetching ${url}`));
    });
  });
}

async function fetchText(url) {
  const res = await get(url);
  const chunks = [];
  for await (const chunk of res) chunks.push(chunk);
  return Buffer.concat(chunks).toString("utf8");
}

async function downloadToFile(url, dest) {
  const res = await get(url);
  const hash = crypto.createHash("sha256");
  res.on("data", (chunk) => hash.update(chunk));
  const out = fs.createWriteStream(dest, { mode: 0o755 });
  await pipeline(res, out);
  return hash.digest("hex");
}

async function main() {
  if (process.env.CODEDEEBEE_SKIP_POSTINSTALL === "1") {
    log("CODEDEEBEE_SKIP_POSTINSTALL=1 — skipping binary download");
    return;
  }

  const key = `${process.platform}-${process.arch}`;
  const asset = PLATFORM_MAP[key];
  if (!asset) {
    logErr(
      `unsupported platform/arch: ${key}. Supported: ${Object.keys(PLATFORM_MAP).join(", ")}.\n` +
        `If you want this platform supported, comment on https://github.com/${REPO}/issues/501`
    );
    process.exit(0);
  }

  const tag = `v${VERSION}`;
  const baseUrl = `https://github.com/${REPO}/releases/download/${tag}`;
  const assetUrl = `${baseUrl}/${asset}`;
  const checksumsUrl = `${baseUrl}/checksums.sha256`;

  const vendorDir = path.join(__dirname, "..", "vendor");
  fs.mkdirSync(vendorDir, { recursive: true });
  const destPath = path.join(vendorDir, process.platform === "win32" ? "codedb.exe" : "codedb");
  const tmpPath = `${destPath}.download`;

  log(`platform: ${key} → asset: ${asset}`);
  log(`fetching checksums from ${checksumsUrl}`);

  let expectedHex;
  try {
    const checksums = await fetchText(checksumsUrl);
    for (const line of checksums.split(/\r?\n/)) {
      const m = line.match(/^([0-9a-fA-F]{64})\s+\*?(.+)$/);
      if (m && m[2].trim() === asset) {
        expectedHex = m[1].toLowerCase();
        break;
      }
    }
    if (!expectedHex) {
      logErr(`could not find ${asset} in checksums.sha256 at ${checksumsUrl}`);
      process.exit(1);
    }
  } catch (err) {
    logErr(`failed to fetch checksums: ${err.message}`);
    process.exit(1);
  }

  log(`downloading ${assetUrl}`);
  try {
    if (fs.existsSync(tmpPath)) fs.unlinkSync(tmpPath);
    const actualHex = await downloadToFile(assetUrl, tmpPath);
    if (actualHex !== expectedHex) {
      logErr(
        `checksum mismatch for ${asset}:\n` +
          `  expected ${expectedHex}\n` +
          `  actual   ${actualHex}`
      );
      try {
        fs.unlinkSync(tmpPath);
      } catch {}
      process.exit(1);
    }
    fs.chmodSync(tmpPath, 0o755);
    fs.renameSync(tmpPath, destPath);
    log(`installed: ${destPath}`);
  } catch (err) {
    logErr(`failed to download binary: ${err.message}`);
    try {
      fs.unlinkSync(tmpPath);
    } catch {}
    process.exit(1);
  }
}

main().catch((err) => {
  logErr(`unexpected error: ${err.stack || err.message}`);
  process.exit(1);
});
