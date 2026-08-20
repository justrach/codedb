#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${CODEDB_URL:-https://codedb.codegraff.com}"
INSTALL_DIR="${CODEDB_DIR:-$HOME/bin}"

# Colors
R='\033[0;31m' G='\033[0;32m' Y='\033[0;33m' B='\033[0;34m'
C='\033[0;36m' W='\033[1;37m' D='\033[0;90m' N='\033[0m'

fetch_latest_version() {
  local version=""

  version="$(curl -fsSL -A 'codedb-installer' \
    "https://api.github.com/repos/justrach/codedb/releases/latest" 2>/dev/null \
    | grep -oE '"tag_name"\s*:\s*"v[^"]*"' \
    | cut -d'"' -f4 \
    | sed 's/^v//')" || true

  if [ -z "$version" ]; then
    version="$(curl -fsSL -A 'codedb-installer' "$BASE_URL/latest.json" 2>/dev/null \
      | grep -oE '"version"\s*:\s*"[^"]*"' \
      | cut -d'"' -f4)" || true
  fi

  printf '%s' "$version"
}

detect_platform() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"
  case "$os" in
    Darwin) os="darwin" ;;
    Linux)  os="linux" ;;
    MINGW*|MSYS*|CYGWIN*)
      # #677: we are inside $(...) — printing guidance or exiting here is
      # swallowed by the subshell. Emit a sentinel for main() instead.
      echo "windows"
      return 0
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

register_codex_policy() {
  local codedb_bin="$1"
  # #680: auto-install the CodeDB-first AGENTS.md policy for Codex sessions.
  # The binary owns the sticky opt-out (marker + removal receipt), so a user's
  # removal survives re-runs and the 24h auto-update. Older binaries without
  # the subcommand skip silently.
  if "$codedb_bin" codex install >/dev/null 2>&1; then
    printf "  ${G}✓${N} codex policy ${D}→ ~/.codex/AGENTS.md (remove: codedb codex uninstall)${N}\n"
  fi
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

register_windsurf_devin() {
  local codedb_bin="$1"
  # Windsurf and Devin both use a standard mcpServers JSON object, so we register
  # codedb directly (additively, like the tools above) rather than through
  # mcpsync. Direct writes only touch the codedb entry — they can't drop a
  # server's nested env/headers — and add no external dependency. Each is
  # registered only when the tool is actually present.
  if ! command -v python3 >/dev/null 2>&1; then
    printf "  ${D}windsurf/devin: skip (python3 not found)${N}\n"
    return
  fi
  if [ -d "$HOME/.codeium/windsurf" ]; then
    _register_json_mcp "$HOME/.codeium/windsurf/mcp_config.json" "$codedb_bin" "windsurf"
  fi
  if [ -d "$HOME/.config/devin" ]; then
    _register_json_mcp "$HOME/.config/devin/config.json" "$codedb_bin" "devin"
  fi
}

_register_json_mcp() {
  local config="$1"
  local codedb_bin="$2"
  local label="$3"
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
d = os.path.dirname(config_path)
if d:
    os.makedirs(d, exist_ok=True)
with open(config_path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PYEOF
  printf "  ${G}✓${N} %-12s ${D}→ %s${N}\n" "$label" "$config"
}

DEEPWIKI_URL="https://mcp.deepwiki.com/mcp"

_register_deepwiki_json() {
  local config="$1"
  local label="$2"
  local entry_json="$3"
  local rc=0
  python3 - "$config" "$entry_json" << 'PYEOF' || rc=$?
import json, sys, os
config_path, entry_json = sys.argv[1], sys.argv[2]
try:
    with open(config_path) as f:
        data = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    data = {}
servers = data.setdefault("mcpServers", {})
if "deepwiki" in servers:
    sys.exit(3)  # already configured — never clobber a user's own entry
servers["deepwiki"] = json.loads(entry_json)
d = os.path.dirname(config_path)
if d:
    os.makedirs(d, exist_ok=True)
with open(config_path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PYEOF
  case "$rc" in
    0) printf "  ${G}✓${N} %-12s ${D}→ %s (+deepwiki)${N}\n" "$label" "$config" ;;
    3) printf "  ${D}%-12s deepwiki already configured → %s${N}\n" "$label" "$config" ;;
    *) printf "  ${Y}%-12s deepwiki registration failed → %s${N}\n" "$label" "$config" ;;
  esac
  return 0
}

register_deepwiki() {
  # DeepWiki is a free, no-auth REMOTE MCP server (mcp.deepwiki.com) that
  # answers questions about public GitHub repos — a good complement to codedb's
  # local index. Registered additively alongside codedb; an existing "deepwiki"
  # entry is never overwritten. Set CODEDB_INSTALL_DEEPWIKI=0 to opt out.
  # Note: text sent to its tools (e.g. ask_question) leaves the machine.
  if [ "${CODEDB_INSTALL_DEEPWIKI:-1}" = "0" ]; then
    printf "  ${D}deepwiki:  skip (CODEDB_INSTALL_DEEPWIKI=0)${N}\n"
    return
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    printf "  ${D}deepwiki:  skip (python3 not found)${N}\n"
    return
  fi

  # Claude Code: always (mirrors register_claude). Field: type+url.
  _register_deepwiki_json "$HOME/.claude.json" "claude code" \
    "{\"type\":\"http\",\"url\":\"$DEEPWIKI_URL\"}"
  # Gemini CLI: streamable HTTP uses httpUrl.
  if [ -d "$HOME/.gemini" ]; then
    _register_deepwiki_json "$HOME/.gemini/settings.json" "gemini cli" \
      "{\"httpUrl\":\"$DEEPWIKI_URL\"}"
  fi
  # Cursor: standard url field.
  if [ -d "$HOME/.cursor" ]; then
    _register_deepwiki_json "$HOME/.cursor/mcp.json" "cursor" \
      "{\"url\":\"$DEEPWIKI_URL\"}"
  fi
  # Windsurf and Devin: both use serverUrl.
  if [ -d "$HOME/.codeium/windsurf" ]; then
    _register_deepwiki_json "$HOME/.codeium/windsurf/mcp_config.json" "windsurf" \
      "{\"serverUrl\":\"$DEEPWIKI_URL\"}"
  fi
  if [ -d "$HOME/.config/devin" ]; then
    _register_deepwiki_json "$HOME/.config/devin/config.json" "devin" \
      "{\"serverUrl\":\"$DEEPWIKI_URL\"}"
  fi
  # Codex: TOML, url key selects the streamable-HTTP transport.
  local codex_cfg="$HOME/.codex/config.toml"
  if grep -q '\[mcp_servers\.deepwiki\]' "$codex_cfg" 2>/dev/null; then
    printf "  ${D}%-12s deepwiki already configured → %s${N}\n" "codex" "$codex_cfg"
  else
    mkdir -p "$HOME/.codex"
    {
      [ -f "$codex_cfg" ] && [ -s "$codex_cfg" ] && echo "" || true
      echo '[mcp_servers.deepwiki]'
      echo "url = \"$DEEPWIKI_URL\""
    } >> "$codex_cfg"
    printf "  ${G}✓${N} %-12s ${D}→ %s (+deepwiki)${N}\n" "codex" "$codex_cfg"
  fi
  printf "  ${D}note: deepwiki is a third-party remote service — queries sent to its tools leave this machine${N}\n"
}

register_hooks() {
  local codedb_bin="$1"
  local bin_dir prefix share_dir hook_script local_script tmp hooks_url fallback_url

  bin_dir="$(dirname "$codedb_bin")"
  prefix="$(cd "$bin_dir/.." 2>/dev/null && pwd -P || printf '%s/..' "$bin_dir")"
  share_dir="$prefix/share/codedb"
  hook_script="$share_dir/install-hooks.sh"
  mkdir -p "$share_dir"

  local_script=""
  if [ -n "${BASH_SOURCE[0]:-}" ]; then
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P || true)"
    if [ -n "$script_dir" ] && [ -f "$script_dir/install-hooks.sh" ]; then
      local_script="$script_dir/install-hooks.sh"
    fi
  fi

  if [ -n "$local_script" ]; then
    cp "$local_script" "$hook_script"
  else
    tmp="/tmp/codedb-install-hooks.tmp.$$"
    hooks_url="${CODEDB_HOOKS_URL:-https://raw.githubusercontent.com/justrach/codedb/v${version}/install/install-hooks.sh}"
    fallback_url="https://raw.githubusercontent.com/justrach/codedb/main/install/install-hooks.sh"
    if ! curl -fsSL -A 'codedb-installer' "$hooks_url" -o "$tmp" 2>/dev/null; then
      if ! curl -fsSL -A 'codedb-installer' "$fallback_url" -o "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        printf "  ${Y}!${N} hooks        ${D}skip (install-hooks.sh unavailable)${N}\n"
        return
      fi
    fi
    mv -f "$tmp" "$hook_script"
  fi

  chmod +x "$hook_script"
  # A hook-install failure must never fail the whole install — the binary and
  # the MCP registrations are already in place at this point.
  if ! CODEDB_BIN="$codedb_bin" "$hook_script" --codedb-bin "$codedb_bin" >/dev/null 2>&1; then
    printf "  ${Y}!${N} hooks        ${D}skip (install-hooks.sh failed; run: $codedb_bin install-hooks)${N}\n"
    return
  fi
  printf "  ${G}✓${N} hooks        ${D}→ ~/.claude + ~/.codex (helper: $hook_script)${N}\n"
}

print_hook_notes() {
  local codedb_bin="$1"

  echo ""
  printf "  ${W}mcp command${N}\n"
  printf "  ${C}$codedb_bin mcp${N}\n"
}

main() {
  local platform version ext=""
  platform="$(detect_platform)"

  # #677: detect_platform runs in a command substitution, so it cannot print
  # to the user or stop the script itself — handle Windows here, before any
  # download is attempted.
  if [ "$platform" = "windows" ]; then
    echo ""
    printf "  ${W}codedb installer${N}\n"
    echo ""
    printf "  ${Y}Windows detected${N} — codedb has a native Windows x86_64 binary.\n"
    printf "  This Bash installer is for macOS/Linux. Run this in PowerShell:\n"
    echo ""
    printf "    ${C}irm https://raw.githubusercontent.com/justrach/codedb/v0.2.5833/install/install.ps1 | iex${N}\n"
    echo ""
    printf "  Use ${G}WSL2${N} only if you want the Linux binary inside WSL.\n"
    echo ""
    exit 0
  fi

  echo ""
  printf "  ${W}codedb${N} ${D}installer${N}\n"
  echo ""
  printf "  ${D}platform${N}  $platform\n"

  version="${CODEDB_VERSION:-}"
  if [ -z "$version" ]; then
    version="$(fetch_latest_version)"
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
    # Verify checksum when the release publishes a checksum manifest.
    local checksum_text expected_hash checksum_notice="" actual_hash=""
    checksum_text="$(curl -fsSL -A 'codedb-installer' "$checksum_url" 2>/dev/null || true)"
    expected_hash="$(printf '%s\n' "$checksum_text" | awk "/codedb-${platform}${ext}\$/ { print \$1 }")"
    if [ -n "$expected_hash" ]; then
      if command -v sha256sum >/dev/null 2>&1; then
        actual_hash="$(sha256sum "$tmp" | awk '{print $1}')"
      elif command -v shasum >/dev/null 2>&1; then
        actual_hash="$(shasum -a 256 "$tmp" | awk '{print $1}')"
      fi
      if [ -z "$actual_hash" ]; then
        # No hashing tool on PATH. Never silently install an unverified
        # binary — say so in the same place the skipped-manifest case does.
        checksum_notice="  ${Y}warning:${N} checksum NOT verified — neither sha256sum nor shasum is on PATH\n"
      elif [ "$actual_hash" != "$expected_hash" ]; then
        rm -f "$tmp"
        printf "${R}failed${N}\n"
        printf "\n  ${R}error: checksum mismatch — binary may be corrupted${N}\n" >&2
        printf "  ${D}expected: $expected_hash${N}\n" >&2
        printf "  ${D}actual:   $actual_hash${N}\n" >&2
        exit 1
      fi
    else
      checksum_notice="  ${Y}warning:${N} checksum verification skipped (checksums.sha256 unavailable)\n"
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
  if [ -n "$checksum_notice" ]; then
    printf "$checksum_notice"
  fi
  printf "  ${D}claude hook opt-out: CODEDB_NO_HOOKS=1 skips this run; CODEDB_PERSIST_NO_HOOKS=1 or touch ~/.codedb/no-hooks makes it permanent (rm ~/.codedb/no-hooks re-enables)${N}\n"

  # Register MCP server in coding tools
  echo ""
  printf "  ${W}registering integrations${N}\n"
  echo ""
  register_claude "$dest"
  register_codex "$dest"
  register_codex_policy "$dest"
  register_gemini "$dest"
  register_cursor "$dest"
  register_windsurf_devin "$dest"
  register_deepwiki
  register_hooks "$dest"
  print_hook_notes "$dest"

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
