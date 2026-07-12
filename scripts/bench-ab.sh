#!/usr/bin/env bash
# Paired, counterbalanced A/B for the gated MCP tool benchmark.
#
#   scripts/bench-ab.sh                    # compare clean committed HEAD in isolated worktrees
#   CODEDB_BENCH_PAIRS=20 scripts/bench-ab.sh HEAD~3
#   CODEDB_BENCH_OUT=bench-results scripts/bench-ab.sh origin/release/0.2.5830
#
# Both revisions index the same fixed 21-file corpus copied from the base
# worktree, and every parity-enabled tool must emit the same response hash. Execution
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
BASE_FULL_SHA="$(git -C "$REPO_ROOT" rev-parse "$BASE_REF")"
HEAD_FULL_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD)"
HEAD_TREE_SHA="$(git -C "$REPO_ROOT" rev-parse 'HEAD^{tree}')"
PAIRED_5829_BASE_SHA="dd36e9431925014ee2bed80346669a4afee7e42e"
PAIRED_5829_SHA="24e89c70d4f9cdaf5542a78d83d1890a42b4a046"
WT="$HOME/.cache/codedb-bench-ab-$$"
BENCH_WT="$WT"
HEAD_WT="$WT-head"
if [[ -n "${CODEDB_BENCH_OUT:-}" ]]; then
  OUT="$CODEDB_BENCH_OUT"
  mkdir -p "$OUT"
  OUT="$(cd "$OUT" && pwd -P)"
  KEEP_OUT=1
else
  OUT="$(mktemp -d "${TMPDIR:-/tmp}/codedb-bench-ab.XXXXXX")"
  KEEP_OUT=0
fi

cleanup() {
  if [[ -d "$HEAD_WT" ]]; then
    git -C "$REPO_ROOT" worktree remove "$HEAD_WT" >/dev/null 2>&1 || \
      echo "warning: benchmark worktree remains at $HEAD_WT" >&2
  fi
  if [[ "$BENCH_WT" != "$WT" && -d "$BENCH_WT" ]]; then
    git -C "$REPO_ROOT" worktree remove "$BENCH_WT" >/dev/null 2>&1 || \
      echo "warning: benchmark worktree remains at $BENCH_WT" >&2
  fi
  if [[ -d "$WT" ]]; then
    git -C "$REPO_ROOT" worktree remove "$WT" >/dev/null 2>&1 || \
      echo "warning: benchmark worktree remains at $WT" >&2
  fi
  if (( KEEP_OUT == 0 )); then rm -rf "$OUT"; fi
}
trap cleanup EXIT

echo "base:   $BASE_REF ($BASE_SHA) in throwaway worktree"
echo "head:   committed $HEAD_FULL_SHA in throwaway worktree"
echo "pairs:  $PAIRS (AB/BA counterbalanced)"
echo "corpus: fixed 21-file set copied from the base worktree"

git -C "$REPO_ROOT" worktree add --detach "$WT" "$BASE_REF" >/dev/null
if ! grep -q 'corpus_hash' "$WT/src/bench.zig"; then
  if [[ "$BASE_FULL_SHA" != "$PAIRED_5829_BASE_SHA" ]]; then
    echo "base ref lacks paired/parity benchmark schema and has no pinned harness" >&2
    exit 2
  fi
  git -C "$REPO_ROOT" cat-file -e "$PAIRED_5829_SHA^{commit}" 2>/dev/null || {
    git -C "$REPO_ROOT" fetch origin bench/v0.2.5829-paired-baseline --depth=1
    [[ "$(git -C "$REPO_ROOT" rev-parse FETCH_HEAD)" == "$PAIRED_5829_SHA" ]]
  }
  git -C "$REPO_ROOT" merge-base --is-ancestor "$BASE_FULL_SHA" "$PAIRED_5829_SHA"
  [[ "$(git -C "$REPO_ROOT" diff --name-only "$BASE_FULL_SHA..$PAIRED_5829_SHA")" == $'src/bench.zig\nsrc/mcp.zig' ]]
  BENCH_WT="$WT-paired"
  git -C "$REPO_ROOT" worktree add --detach "$BENCH_WT" "$PAIRED_5829_SHA" >/dev/null
fi

git -C "$REPO_ROOT" worktree add --detach "$HEAD_WT" "$HEAD_FULL_SHA" >/dev/null

run_sample() {
  local side="$1" pair="$2" order="$3" sequence="$4" cwd production_sha
  if [[ "$side" == "base" ]]; then
    cwd="$BENCH_WT"
    production_sha="$BASE_FULL_SHA"
  else
    cwd="$HEAD_WT"
    production_sha="$HEAD_FULL_SHA"
  fi
  echo "pair $pair/$PAIRS: $side ($order sequence $sequence)" >&2
  (cd "$cwd" && python3 "$HEAD_WT/scripts/run-bench-json.py" \
    --bench-side "$side" --bench-pair "$pair" --bench-order "$order" --bench-sequence "$sequence" \
    --production-source-sha "$production_sha" --corpus-source-sha "$BASE_FULL_SHA" \
    "$OUT/$side-$(printf '%02d' "$pair").json" --corpus-source "$WT" >/dev/null)
}

for ((pair = 1; pair <= PAIRS; pair++)); do
  if (( pair % 2 == 1 )); then
    run_sample base "$pair" AB 1
    run_sample head "$pair" AB 2
  else
    run_sample head "$pair" BA 1
    run_sample base "$pair" BA 2
  fi
done

python3 "$HEAD_WT/scripts/compare-bench-paired.py" "$OUT" \
  --require-parity --require-provenance --allow-parity-skip codedb_snapshot --allow-parity-skip codedb_status \
  --expected-head-sha "$HEAD_FULL_SHA" --expected-head-tree-sha "$HEAD_TREE_SHA" \
  --threshold-pct 10 --min-abs-ns 50000 --markdown-out "$OUT/report.md"

if (( KEEP_OUT == 1 )); then echo "raw samples: $OUT"; fi
