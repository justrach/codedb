#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${CODEDB_URL:-https://codedb.codegraff.com}"
INSTALL_DIR="${CODEDB_DIR:-$HOME/bin}"

# Colors
R='\033[0;31m' G='\033[0;32m' Y='\033[0;33m' B='\033[0;34m'
C='\033[0;36m' W='\033[1;37m' D='\033[0;90m' N='\033[0m'

detect_platform() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"
  case "$os" in
    Darwin) os="darwin" ;;
    Linux)  os="linux" ;;
    MINGW*|MSYS*|CYGWIN*)
      echo ""
      printf "  ${W}codedb installer${N}\n"
      echo ""
      printf "  ${Y}Windows detected${N} — codedb is a native Linux/macOS binary.\n"
      printf "  Run this inside ${G}WSL2${N} instead:\n"
      echo ""
      printf "    ${C}wsl curl -fsSL https://codedb.codegraff.com/install.sh | sh${N}\n"
      echo ""
      exit 0
      ;;
    *) printf "  ${R}Unsupported OS: $os${N}\n" >&2; exit 1 ;;
  esac
  case "$arch" in
    arm64|aarch64) arch="arm64" ;;
    x86_64|amd64)  arch="x86_64" ;;
    *) printf "  ${R}Unsupported arch: $arch${N}\n" >&2; exit 1 ;;
  esac
  echo "${os}-${arch}"
}

register_claude() {
  local codedb_bin="$1"
  local config="$HOME/.claude.json"

  if ! command -v python3 >/dev/null 2>&1; then
    printf "  ${D}claude:  skip (python3 not found)${N}\n"
    return
  fi

  python3 - "$config" "$codedb_bin" << 'PYEOF'
import json, sys, os
config_path, codedb_bin = sys.argv[1], sys.argv[2]
try:
    with open(config_path) as f:
        data = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    data = {}
servers = data.setdefault("mcpServers", {})
servers["codedb"] = {"command": codedb_bin, "args": ["mcp"]}
with open(config_path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PYEOF

  printf "  ${G}✓${N} claude code  ${D}→ $config${N}\n"
}

register_codex() {
  local codedb_bin="$1"
  local config_dir="$HOME/.codex"
  local config="$config_dir/config.toml"

  mkdir -p "$config_dir"

  if [ -f "$config" ] && grep -q '\[mcp_servers\.codedb\]' "$config" 2>/dev/null; then
    printf "  ${G}✓${N} codex        ${D}→ $config (already registered)${N}\n"
    return
  fi

  {
    [ -f "$config" ] && [ -s "$config" ] && echo ""
    echo '[mcp_servers.codedb]'
    echo "command = \"$codedb_bin\""
    echo 'args = ["mcp"]'
    echo 'startup_timeout_sec = 30'
  } >> "$config"

  printf "  ${G}✓${N} codex        ${D}→ $config${N}\n"
}

register_gemini() {
  local codedb_bin="$1"
  local config_dir="$HOME/.gemini"
  local config="$config_dir/settings.json"

  if [ ! -d "$config_dir" ]; then
    return
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    printf "  ${D}gemini:  skip (python3 not found)${N}\n"
    return
  fi

  python3 - "$config" "$codedb_bin" << 'PYEOF'
import json, sys, os
config_path, codedb_bin = sys.argv[1], sys.argv[2]
try:
    with open(config_path) as f:
        data = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    data = {}
servers = data.setdefault("mcpServers", {})
servers["codedb"] = {"command": codedb_bin, "args": ["mcp"]}
with open(config_path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PYEOF

  printf "  ${G}✓${N} gemini cli   ${D}→ $config${N}\n"
}

register_cursor() {
  local codedb_bin="$1"
  local config_dir="$HOME/.cursor"
  local config="$config_dir/mcp.json"

  if [ ! -d "$config_dir" ]; then
    return
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    printf "  ${D}cursor:  skip (python3 not found)${N}\n"
    return
  fi

  python3 - "$config" "$codedb_bin" << 'PYEOF'
import json, sys, os
config_path, codedb_bin = sys.argv[1], sys.argv[2]
try:
    with open(config_path) as f:
        data = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    data = {}
servers = data.setdefault("mcpServers", {})
servers["codedb"] = {"command": codedb_bin, "args": ["mcp"]}
with open(config_path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PYEOF

  printf "  ${G}✓${N} cursor       ${D}→ $config${N}\n"
}

main() {
  local platform version ext=""
  platform="$(detect_platform)"

  echo ""
  printf "  ${W}codedb${N} ${D}installer${N}\n"
  echo ""
  printf "  ${D}platform${N}  $platform\n"

  version="${CODEDB_VERSION:-}"
  if [ -z "$version" ]; then
    version="$(curl -fsSL -A 'codedb-installer' "$BASE_URL/latest.json" | grep -oE '"version"\s*:\s*"[^"]*"' | cut -d'"' -f4)"
  fi
  if [ -z "$version" ]; then
    printf "  ${R}error: could not fetch latest version${N}\n" >&2
    exit 1
  fi
  printf "  ${D}version${N}   v${version}\n"

  [[ "$platform" == windows-* ]] && ext=".exe"

  mkdir -p "$INSTALL_DIR"
  printf "  ${D}install${N}   $INSTALL_DIR\n"
  echo ""

  local url="https://github.com/justrach/codedb/releases/download/v${version}/codedb-${platform}${ext}"
  local checksum_url="https://github.com/justrach/codedb/releases/download/v${version}/checksums.sha256"
  local dest="$INSTALL_DIR/codedb${ext}"

  printf "  ${D}│${N} %-12s " "codedb"
  local tmp="/tmp/codedb.tmp.$$"
  if curl -fsSL -A 'codedb-installer' "$url" -o "$tmp" 2>/dev/null; then
    # Verify checksum if available (#120)
    local expected_hash
    expected_hash="$(curl -fsSL -A 'codedb-installer' "$checksum_url" 2>/dev/null | grep "codedb-${platform}${ext}" | awk '{print $1}')"
    if [ -n "$expected_hash" ]; then
      local actual_hash
      if command -v sha256sum >/dev/null 2>&1; then
        actual_hash="$(sha256sum "$tmp" | awk '{print $1}')"
      elif command -v shasum >/dev/null 2>&1; then
        actual_hash="$(shasum -a 256 "$tmp" | awk '{print $1}')"
      fi
      if [ -n "$actual_hash" ] && [ "$actual_hash" != "$expected_hash" ]; then
        rm -f "$tmp"
        printf "${R}failed${N}\n"
        printf "\n  ${R}error: checksum mismatch — binary may be corrupted${N}\n" >&2
        printf "  ${D}expected: $expected_hash${N}\n" >&2
        printf "  ${D}actual:   $actual_hash${N}\n" >&2
        exit 1
      fi
    fi
    xattr -c "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$dest"
    chmod +x "$dest"
    printf "${G}✓${N}\n"
  else
    printf "${R}failed${N}\n"
    printf "\n  ${R}error: download failed${N}\n" >&2
    printf "  ${D}url: $url${N}\n" >&2
    exit 1
  fi

  echo ""
  printf "  ${G}installed${N} ${D}→ $dest${N}\n"

  # Register MCP server in coding tools
  echo ""
  printf "  ${W}registering integrations${N}\n"
  echo ""
  register_claude "$dest"
  register_codex "$dest"
  register_gemini "$dest"
  register_cursor "$dest"

  # Check PATH
  case ":$PATH:" in
    *":$INSTALL_DIR:"*) ;;
    *)
      echo ""
      printf "  ${Y}add to PATH:${N}\n"
      printf "  ${C}export PATH=\"$INSTALL_DIR:\$PATH\"${N}\n"
      printf "  ${D}(add to ~/.bashrc or ~/.zshrc)${N}\n"
      ;;
  esac

  echo ""
  printf "  ${W}done!${N} run ${C}codedb --help${N} to get started\n"
  echo ""
}

main
