#!/usr/bin/env bash
# A/B the gated MCP tool bench: current working tree vs a base ref.
#
#   scripts/bench-ab.sh              # base = HEAD (measure uncommitted work)
#   scripts/bench-ab.sh HEAD~3       # base = any ref
#   scripts/bench-ab.sh origin/release/0.2.5828
#
# Builds the base ref in a throwaway worktree under $HOME (tests and bench
# misbehave under /tmp roots — see root_policy), runs `zig build bench --
# --json` for both sides on this machine back-to-back, and prints the same
# regression table CI posts on PRs (scripts/compare-bench.py, 10% + 50µs
# thresholds). Only same-machine, same-run deltas are meaningful — never
# compare against a JSON from another day or box.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
BASE_REF="${1:-HEAD}"
BASE_SHA="$(git -C "$REPO_ROOT" rev-parse --short "$BASE_REF")"
WT="$HOME/.cache/codedb-bench-ab-$$"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/codedb-bench-ab.XXXXXX")"

cleanup() {
  git -C "$REPO_ROOT" worktree remove --force "$WT" >/dev/null 2>&1 || true
  rm -rf "$OUT"
}
trap cleanup EXIT

echo "base:  $BASE_REF ($BASE_SHA) in throwaway worktree"
echo "head:  working tree at $(git -C "$REPO_ROOT" rev-parse --short HEAD)$(git -C "$REPO_ROOT" diff --quiet || echo ' + uncommitted changes')"

git -C "$REPO_ROOT" worktree add --detach "$WT" "$BASE_REF" >/dev/null
(cd "$WT" && python3 scripts/run-bench-json.py "$OUT/base.json" >/dev/null)
(cd "$REPO_ROOT" && python3 scripts/run-bench-json.py "$OUT/head.json" >/dev/null)

python3 "$REPO_ROOT/scripts/compare-bench.py" "$OUT/base.json" "$OUT/head.json" \
  --threshold-pct 10 --min-abs-ns 50000
