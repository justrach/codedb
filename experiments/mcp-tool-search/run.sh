#!/usr/bin/env bash
# One-command reproduction of the MCP tool-search experiment.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

PYTHON="${PYTHON:-python3}"
if [[ ! -d .venv ]]; then
  "$PYTHON" -m venv .venv
fi
# shellcheck disable=SC1091
source .venv/bin/activate
python -m pip install -q -U pip
python -m pip install -q -r requirements.txt || true
# Dense embeddings are optional; the harness falls back if this fails.
python -c "import fastembed" 2>/dev/null || python -m pip install -q 'fastembed>=0.4' || true

CODEDB_BIN="${CODEDB_BIN:-$ROOT/bin/codedb}"
if [[ ! -x "$CODEDB_BIN" ]]; then
  mkdir -p "$ROOT/bin"
  VER="${CODEDB_VERSION:-v0.2.5860}"
  URL="https://github.com/justrach/codedb/releases/download/${VER}/codedb-linux-x86_64"
  echo "downloading codedb ${VER}…"
  curl -fsSL -o "$CODEDB_BIN" "$URL"
  chmod +x "$CODEDB_BIN"
fi

python "$ROOT/lib/catalog.py"
python "$ROOT/harness.py" --codedb-bin "$CODEDB_BIN" "$@"
python "$ROOT/cost_eval.py"
python "$ROOT/live_agent.py"
echo "done. see results.md, results/cost.json, results/live_agent.json"
