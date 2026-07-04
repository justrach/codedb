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
      echo ""
      printf "  ${W}codedb installer${N}\n"
      echo ""
      printf "  ${Y}Windows detected${N} — codedb is a native Linux/macOS binary.\n"
      printf "  Run this inside ${G}WSL2${N} instead:\n"
      echo ""
      printf "    ${C}wsl curl -fsSL https://codedb.codegraff.com/install.sh | bash${N}\n"
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

register_hooks() {
  if ! command -v python3 >/dev/null 2>&1; then
    printf "  ${D}hooks:   skip (python3 not found)${N}\n"
    return
  fi
  python3 << 'PYEOF'
import json, os, stat

home = os.path.expanduser("~")
hooks_dir = os.path.join(home, ".claude", "hooks")
settings_path = os.path.join(home, ".claude", "settings.json")
os.makedirs(hooks_dir, exist_ok=True)

scripts = {
    "codedb-block-legacy.sh": r'''#!/bin/bash
command -v jq >/dev/null 2>&1 || exit 0
command -v codedb >/dev/null 2>&1 || exit 0
INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
STRIPPED=$(echo "$CMD" | sed -E 's/^[[:space:]]*(env|sudo|command|builtin|exec|nohup)[[:space:]]+//')
STRIPPED=$(echo "$STRIPPED" | sed -E 's/^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+//')
FIRST=$(echo "$STRIPPED" | awk '{print $1}')
case "$FIRST" in
  grep|rg|egrep|fgrep) echo "BLOCKED: Use mcp__codedb__codedb_search instead of $FIRST. If codedb MCP is not connected, use Bash directly." >&2; exit 2 ;;
  cat) echo "BLOCKED: Use mcp__codedb__codedb_read instead of cat. If codedb MCP is not connected, use Bash directly." >&2; exit 2 ;;
  head|tail) echo "BLOCKED: Use mcp__codedb__codedb_read with line_start/line_end instead of $FIRST. If codedb MCP is not connected, use Bash directly." >&2; exit 2 ;;
  sed|awk) echo "BLOCKED: Use mcp__codedb__codedb_edit instead of $FIRST. If codedb MCP is not connected, use Bash directly." >&2; exit 2 ;;
  find) echo "BLOCKED: Use mcp__codedb__codedb_find or mcp__codedb__codedb_glob instead of find. If codedb MCP is not connected, use Bash directly." >&2; exit 2 ;;
esac
exit 0
''',
    "codedb-warmup.sh": r'''#!/bin/bash
command -v codedb >/dev/null 2>&1 || exit 0
codedb . status >/dev/null 2>&1 &
exit 0
''',
}

for name, content in scripts.items():
    path = os.path.join(hooks_dir, name)
    with open(path, "w") as f:
        f.write(content)
    os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

try:
    with open(settings_path) as f:
        data = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    data = {}

hooks = data.setdefault("hooks", {})

# Merge codedb hooks without clobbering existing hooks from other tools.
# If a competing legacy-tools hook is already registered for the same
# event/matcher (e.g. muonry's block-legacy-tools.sh), insert codedb's
# entry at the FRONT of the list so its redirect wins the race; otherwise
# append. Re-runs will also reshuffle an already-registered codedb hook
# to the front if a competitor has appeared since the previous install.
COMPETITOR_MARKERS = ("block-legacy-tools", "muonry", "zigrep", "zigread")

def merge_hook(event, new_entry):
    existing = hooks.get(event, [])
    cmd = new_entry["hooks"][0]["command"]
    matcher = new_entry.get("matcher", "")
    competes = any(
        e.get("matcher", "") == matcher
        and any(any(m in h.get("command", "") for m in COMPETITOR_MARKERS) for h in e.get("hooks", []))
        for e in existing
    )
    idx = None
    for i, e in enumerate(existing):
        if any(cmd in h.get("command", "") for h in e.get("hooks", [])):
            idx = i
            break
    if idx is not None:
        if competes and idx != 0:
            existing.insert(0, existing.pop(idx))
            hooks[event] = existing
        return
    if competes:
        existing.insert(0, new_entry)
    else:
        existing.append(new_entry)
    hooks[event] = existing

merge_hook("PreToolUse", {"matcher": "Bash", "hooks": [{"type": "command", "command": "$HOME/.claude/hooks/codedb-block-legacy.sh"}]})
merge_hook("SessionStart", {"matcher": "", "hooks": [{"type": "command", "command": "$HOME/.claude/hooks/codedb-warmup.sh"}]})

# Auto-allow codedb's own MCP tools so callers aren't prompted for every
# codedb_* call. Purely additive — we add only the codedb-scoped rule and
# never touch other servers' permissions. The "mcp__codedb__*" form (literal
# server prefix + tool glob) is the syntax Claude Code's permission validator
# accepts; a bare "mcp__*" is rejected and silently skipped.
perms = data.setdefault("permissions", {})
allow = perms.setdefault("allow", [])
if isinstance(allow, list) and "mcp__codedb__*" not in allow:
    allow.append("mcp__codedb__*")
with open(settings_path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PYEOF
  printf "  ${G}✓${N} hooks        ${D}→ ~/.claude/hooks/ + settings.json${N}\n"
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
    local checksum_text expected_hash checksum_notice=""
    checksum_text="$(curl -fsSL -A 'codedb-installer' "$checksum_url" 2>/dev/null || true)"
    expected_hash="$(printf '%s\n' "$checksum_text" | awk "/codedb-${platform}${ext}\$/ { print \$1 }")"
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

  # Register MCP server in coding tools
  echo ""
  printf "  ${W}registering integrations${N}\n"
  echo ""
  register_claude "$dest"
  register_codex "$dest"
  register_gemini "$dest"
  register_cursor "$dest"
  register_windsurf_devin "$dest"
  register_hooks
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
