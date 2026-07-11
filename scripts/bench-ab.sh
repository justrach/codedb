#!/usr/bin/env bash
# Paired, counterbalanced A/B for the gated MCP tool benchmark.
#
#   scripts/bench-ab.sh                    # base = HEAD (uncommitted work)
#   CODEDB_BENCH_PAIRS=20 scripts/bench-ab.sh HEAD~3
#   CODEDB_BENCH_OUT=bench-results scripts/bench-ab.sh origin/release/0.2.5830
#
# Both revisions index the exact same corpus (the base worktree), and every
# parity-enabled tool must emit the same response hash in every pair. Execution
# order alternates AB/BA. The report uses paired medians + bootstrap intervals;
# no single-run minimum is accepted as performance evidence.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
BASE_REF="${1:-HEAD}"
PAIRS="${CODEDB_BENCH_PAIRS:-10}"
if ! [[ "$PAIRS" =~ ^[0-9]+$ ]] || (( PAIRS < 2 )); then
  echo "CODEDB_BENCH_PAIRS must be an integer >= 2" >&2
  exit 2
fi

BASE_SHA="$(git -C "$REPO_ROOT" rev-parse --short "$BASE_REF")"
WT="$HOME/.cache/codedb-bench-ab-$$"
if [[ -n "${CODEDB_BENCH_OUT:-}" ]]; then
  OUT="$CODEDB_BENCH_OUT"
  mkdir -p "$OUT"
  KEEP_OUT=1
else
  OUT="$(mktemp -d "${TMPDIR:-/tmp}/codedb-bench-ab.XXXXXX")"
  KEEP_OUT=0
fi

cleanup() {
  if [[ -d "$WT" ]]; then
    git -C "$REPO_ROOT" worktree remove "$WT" >/dev/null 2>&1 || \
      echo "warning: benchmark worktree remains at $WT" >&2
  fi
  if (( KEEP_OUT == 0 )); then rm -rf "$OUT"; fi
}
trap cleanup EXIT

echo "base:   $BASE_REF ($BASE_SHA) in throwaway worktree"
echo "head:   working tree at $(git -C "$REPO_ROOT" rev-parse --short HEAD)$(git -C "$REPO_ROOT" diff --quiet || echo ' + uncommitted changes')"
echo "pairs:  $PAIRS (AB/BA counterbalanced)"
echo "corpus: base worktree (shared by both revisions)"

git -C "$REPO_ROOT" worktree add --detach "$WT" "$BASE_REF" >/dev/null
if ! grep -q 'corpus_hash' "$WT/src/bench.zig"; then
  echo "base ref lacks paired/parity benchmark schema; choose a base containing the benchmark guardrail commit" >&2
  exit 2
fi

run_sample() {
  local side="$1" pair="$2" cwd
  if [[ "$side" == "base" ]]; then cwd="$WT"; else cwd="$REPO_ROOT"; fi
  echo "pair $pair/$PAIRS: $side" >&2
  (cd "$cwd" && python3 "$REPO_ROOT/scripts/run-bench-json.py" \
    "$OUT/$side-$(printf '%02d' "$pair").json" --corpus-source "$WT" >/dev/null)
}

for ((pair = 1; pair <= PAIRS; pair++)); do
  if (( pair % 2 == 1 )); then
    run_sample base "$pair"
    run_sample head "$pair"
  else
    run_sample head "$pair"
    run_sample base "$pair"
  fi
done

python3 "$REPO_ROOT/scripts/compare-bench-paired.py" "$OUT" \
  --require-parity --threshold-pct 10 --min-abs-ns 50000 \
  --markdown-out "$OUT/report.md"

if (( KEEP_OUT == 1 )); then echo "raw samples: $OUT"; fi
