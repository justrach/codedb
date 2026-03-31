#!/usr/bin/env bash
set -euo pipefail

# --- Configuration ---
VERSION="${RELEASE_VERSION:-${1:-0.1.0}}"
CERT="Developer ID Application: Rachit Pradhan (WWP9DLJ27P)"
REPO="$(cd "$(dirname "$0")" && pwd)"
GITHUB_REPO="justrach/codedb2"
DRY_RUN=false

# Platforms to build
PLATFORMS=(
  "aarch64-macos"
  "x86_64-macos"
  "aarch64-linux"
  "x86_64-linux"
)

# Map zig target → release asset name suffix
platform_suffix() {
  case "$1" in
    aarch64-macos)  echo "darwin-arm64" ;;
    x86_64-macos)   echo "darwin-x86_64" ;;
    aarch64-linux)  echo "linux-arm64" ;;
    x86_64-linux)   echo "linux-x86_64" ;;
    *) echo "$1" ;;
  esac
}

# --- Parse flags ---
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    v*) VERSION="${arg#v}" ;;
    [0-9]*) VERSION="$arg" ;;
  esac
done

TAG="v${VERSION}"

echo "=== codedb Release ${TAG} ==="
echo "  Repo:     $GITHUB_REPO"
echo "  Cert:     $CERT"
echo "  Dry run:  $DRY_RUN"
echo "  Platforms: ${PLATFORMS[*]}"
echo ""

# --- Build for all platforms ---
echo "--- Build (ReleaseFast) ---"
mkdir -p "$REPO/dist"

for plat in "${PLATFORMS[@]}"; do
  suffix="$(platform_suffix "$plat")"
  out="$REPO/dist/codedb-${suffix}"

  if $DRY_RUN; then
    echo "  [dry-run] BUILD codedb-${suffix} (target: $plat)"
    continue
  fi

  echo -n "  BUILD codedb-${suffix} ... "

  # Cross-compile with zig — skip the ad-hoc codesign step for non-native targets
  # by building just the executable, not installing (which triggers codesign)
  if (cd "$REPO" && zig build -Doptimize=ReleaseFast -Dtarget="$plat" 2>&1); then
    cp "$REPO/zig-out/bin/codedb" "$out"
    echo "OK ($(du -h "$out" | cut -f1 | xargs))"
  else
    echo "FAIL"
  fi
done
echo ""

# --- Codesign macOS binaries ---
echo "--- Codesign (macOS only) ---"
for plat in "${PLATFORMS[@]}"; do
  case "$plat" in
    *-macos) ;;
    *) continue ;;
  esac

  suffix="$(platform_suffix "$plat")"
  bin="$REPO/dist/codedb-${suffix}"

  if [ ! -f "$bin" ]; then
    $DRY_RUN && echo "  [dry-run] SIGN codedb-${suffix}" && continue
    echo "  SKIP codedb-${suffix} (no binary)"
    continue
  fi

  if $DRY_RUN; then
    echo "  [dry-run] SIGN codedb-${suffix}"
    continue
  fi

  echo -n "  SIGN codedb-${suffix} ... "
  codesign --force --sign "$CERT" --options runtime "$bin" 2>&1 && echo "OK" || echo "FAIL"
done
echo ""

# --- Notarize macOS binaries ---
echo "--- Notarize (Apple) ---"
for plat in "${PLATFORMS[@]}"; do
  case "$plat" in
    *-macos) ;;
    *) continue ;;
  esac

  suffix="$(platform_suffix "$plat")"
  bin="$REPO/dist/codedb-${suffix}"

  if [ ! -f "$bin" ]; then
    $DRY_RUN && echo "  [dry-run] NOTARIZE codedb-${suffix}" && continue
    continue
  fi

  if $DRY_RUN; then
    echo "  [dry-run] NOTARIZE codedb-${suffix}"
    continue
  fi

  echo -n "  NOTARIZE codedb-${suffix} ... "
  zip -j "/tmp/codedb-${suffix}.zip" "$bin" >/dev/null 2>&1
  xcrun notarytool submit "/tmp/codedb-${suffix}.zip" --keychain-profile "notary" --wait 2>&1 | grep "status:" | tail -1
  rm -f "/tmp/codedb-${suffix}.zip"
done
echo ""

# --- Install locally ---
echo "--- Install to ~/bin/ ---"
LOCAL_BIN="$REPO/dist/codedb-darwin-arm64"
if [ -f "$LOCAL_BIN" ]; then
  if $DRY_RUN; then
    echo "  [dry-run] INSTALL codedb → ~/bin/codedb"
  else
    mkdir -p "$HOME/bin"
    cp "$LOCAL_BIN" "$HOME/bin/codedb"
    echo "  INSTALL codedb → ~/bin/codedb"
  fi
else
  echo "  SKIP (no darwin-arm64 binary)"
fi
echo ""

# --- Create GitHub Release ---
echo "--- GitHub Release: ${TAG} ---"
if $DRY_RUN; then
  echo "  [dry-run] gh release create ${TAG}"
  for f in "$REPO"/dist/codedb-*; do
    [ -f "$f" ] && echo "  [dry-run] UPLOAD $(basename "$f")"
  done
else
  # Create release (or skip if exists)
  if gh release view "$TAG" --repo "$GITHUB_REPO" >/dev/null 2>&1; then
    echo "  Release ${TAG} already exists, uploading assets..."
    # Delete existing assets to re-upload
    for f in "$REPO"/dist/codedb-*; do
      [ -f "$f" ] || continue
      name="$(basename "$f")"
      gh release delete-asset "$TAG" "$name" --repo "$GITHUB_REPO" --yes 2>/dev/null || true
    done
  else
    echo -n "  CREATE ${TAG} ... "
    gh release create "$TAG" \
      --repo "$GITHUB_REPO" \
      --title "codedb ${TAG}" \
      --notes "codedb ${TAG}

## Install
\`\`\`
curl -fsSL https://codedb.codegraff.com/install.sh | sh
\`\`\`

## Assets
| Platform | Asset |
|----------|-------|
| macOS ARM64 (Apple Silicon) | \`codedb-darwin-arm64\` |
| macOS x86_64 (Intel) | \`codedb-darwin-x86_64\` |
| Linux ARM64 | \`codedb-linux-arm64\` |
| Linux x86_64 | \`codedb-linux-x86_64\` |
" && echo "OK"
  fi

  # Upload all binaries
  for f in "$REPO"/dist/codedb-*; do
    [ -f "$f" ] || continue
    name="$(basename "$f")"
    echo -n "  UPLOAD $name ... "
    gh release upload "$TAG" "$f" --repo "$GITHUB_REPO" --clobber 2>&1 && echo "OK" || echo "FAIL"
  done
fi
echo ""

echo "=== Done: ${TAG} ==="
echo "  Binaries: $REPO/dist/"
echo "  Release:  https://github.com/$GITHUB_REPO/releases/tag/${TAG}"
echo "  Install:  curl -fsSL https://codedb.codegraff.com/install.sh | sh"
