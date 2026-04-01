#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: register_codex_mcp.sh /absolute/path/to/codedb" >&2
  exit 1
fi

codedb_bin="$1"

case "$codedb_bin" in
  /*) ;;
  *)
    echo "error: expected an absolute path" >&2
    exit 1
    ;;
esac

if [ ! -x "$codedb_bin" ]; then
  echo "error: binary is not executable: $codedb_bin" >&2
  exit 1
fi

config_dir="${HOME}/.codex"
config="${config_dir}/config.toml"

mkdir -p "$config_dir"

if [ -f "$config" ] && grep -q '\[mcp_servers\.codedb\]' "$config" 2>/dev/null; then
  echo "codedb already registered in $config"
  exit 0
fi

{
  [ -f "$config" ] && [ -s "$config" ] && echo ""
  echo '[mcp_servers.codedb]'
  echo "command = \"$codedb_bin\""
  echo 'args = ["mcp"]'
  echo 'startup_timeout_sec = 30'
} >> "$config"

echo "registered codedb in $config"
