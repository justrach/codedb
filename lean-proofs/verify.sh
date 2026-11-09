#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
LEAN_BIN="${LEAN_BIN:-$(command -v lean || echo "$HOME/.elan/bin/lean")}"

LEAN_PATH=. "$LEAN_BIN" -o CodeDB/OpenPufferLifecycle.olean CodeDB/OpenPufferLifecycle.lean
LEAN_PATH=. "$LEAN_BIN" -o CodeDB/OpenPufferSearch.olean CodeDB/OpenPufferSearch.lean
LEAN_PATH=. "$LEAN_BIN" -o CodeDB/SearchLifecycle.olean CodeDB/SearchLifecycle.lean
LEAN_PATH=. "$LEAN_BIN" -o CodeDB/SearchCache.olean CodeDB/SearchCache.lean
LEAN_PATH=. "$LEAN_BIN" --run Main.lean
