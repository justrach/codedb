#!/usr/bin/env node
// postinstall: uses bundled binary if present, otherwise downloads from GitHub Releases
'use strict';

const https = require('https');
const fs = require('fs');
const path = require('path');
const os = require('os');

const VERSION = require('./package.json').version;
const REPO = 'justrach/codedb';
const BIN_DIR = path.join(__dirname, 'bin');
const BIN_PATH = path.join(BIN_DIR, 'devswarm');

function getPlatformTarget() {
  const arch = os.arch();
  const platform = os.platform();
  if (platform === 'darwin') {
    return arch === 'arm64' ? 'aarch64-macos' : 'x86_64-macos';
  } else if (platform === 'linux') {
    return (arch === 'arm64' || arch === 'aarch64') ? 'aarch64-linux' : 'x86_64-linux';
  }
  throw new Error(`Unsupported platform: ${platform}/${arch}. Build from source: https://github.com/${REPO}`);
}

function download(url, dest) {
  return new Promise((resolve, reject) => {
    const file = fs.createWriteStream(dest);
    const follow = (u) => {
      https.get(u, (res) => {
        if (res.statusCode === 301 || res.statusCode === 302) { follow(res.headers.location); return; }
        if (res.statusCode !== 200) { reject(new Error(`HTTP ${res.statusCode} fetching ${u}`)); return; }
        res.pipe(file);
        file.on('finish', () => file.close(resolve));
      }).on('error', reject);
    };
    follow(url);
  });
}

async function main() {
  const target = getPlatformTarget();
  fs.mkdirSync(BIN_DIR, { recursive: true });

  // Use bundled platform binary if present (CI releases bundle them)
  const bundled = path.join(BIN_DIR, `devswarm-${target}`);
  if (fs.existsSync(bundled)) {
    fs.copyFileSync(bundled, BIN_PATH);
    fs.chmodSync(BIN_PATH, 0o755);
    console.log(`[devswarm] Using bundled ${target} binary.`);
    return;
  }

  // Otherwise download from GitHub Releases
  const url = `https://github.com/${REPO}/releases/download/v${VERSION}/devswarm-${target}`;
  console.log(`[devswarm] Downloading ${target} binary...`);
  await download(url, BIN_PATH);
  fs.chmodSync(BIN_PATH, 0o755);
  console.log(`[devswarm] Installed to ${BIN_PATH}`);
}

main().catch((err) => {
  console.error(`[devswarm] Install failed: ${err.message}`);
  console.error(`Build from source: https://github.com/${REPO}`);
  process.exit(1);
});
