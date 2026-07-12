#!/bin/sh
set -eu

# Raspberry Pi cold/warm startup + peak-RSS probe.
# Run this on the target Pi so kernel, storage, and ARM CPU effects are real.

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
CORPUS=${1:-$REPO_ROOT}
OUT=${CODEDB_PI_BENCH_OUT:-$REPO_ROOT/zig-out/bench-pi}
TIME_BIN=${TIME_BIN:-/usr/bin/time}

if [ ! -x "$TIME_BIN" ]; then
  echo "error: GNU time is required at $TIME_BIN (apt install time)" >&2
  exit 1
fi

mkdir -p "$OUT"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/codedb-pi-bench.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

ARCH=$(uname -m)
if [ "$ARCH" != aarch64 ] && [ "$ARCH" != arm64 ]; then
  echo "warning: $ARCH is not a 64-bit Raspberry Pi architecture; results are diagnostic only" >&2
fi

cd "$REPO_ROOT"
zig build -Doptimize=ReleaseFast
BIN=$REPO_ROOT/zig-out/bin/codedb

run_case() {
  profile=$1
  phase=$2
  home=$TMP/$profile-home
  mkdir -p "$home"
  time_file=$OUT/$profile-$phase.time
  stdout_file=$OUT/$profile-$phase.stdout

  if [ "$profile" = pi ]; then
    resource_profile=pi
  else
    resource_profile=default
  fi

  "$TIME_BIN" -v -o "$time_file" \
    env HOME="$home" \
        CODEDB_RESOURCE_PROFILE="$resource_profile" \
        CODEDB_NO_CLI_DAEMON=1 \
        CODEDB_NO_TELEMETRY=1 \
        CODEDB_ALLOW_TEMP=1 \
        "$BIN" "$CORPUS" tree >"$stdout_file"
}

# The first invocation scans/indexes. The second reuses persisted state where
# available, approximating normal MCP restarts on the same project.
for profile in default pi; do
  run_case "$profile" cold
  run_case "$profile" warm
done

report=$OUT/report.md
{
  echo "# Raspberry Pi resource-profile benchmark"
  echo
  echo "- architecture: \`$ARCH\`"
  echo "- corpus: \`$CORPUS\`"
  echo "- binary: \`$BIN\`"
  echo "- Zig: \`$(zig version)\`"
  echo
  echo "| Profile | Phase | Peak RSS (KiB) | Elapsed |"
  echo "|---|---|---:|---:|"
  for profile in default pi; do
    for phase in cold warm; do
      file=$OUT/$profile-$phase.time
      rss=$(sed -n 's/^[[:space:]]*Maximum resident set size (kbytes):[[:space:]]*//p' "$file")
      elapsed=$(sed -n 's/^[[:space:]]*Elapsed (wall clock) time (h:mm:ss or m:ss):[[:space:]]*//p' "$file")
      echo "| $profile | $phase | ${rss:-unknown} | ${elapsed:-unknown} |"
    done
  done
  echo
  echo "The \`pi\` profile caps parallel index phases at two workers, reduces the known"
  echo "response/read cache ceiling from about 108 MiB to about 27 MiB, retains"
  echo "two non-default project contexts instead of five, and releases file contents"
  echo "after persisted indexes are ready. Output correctness should be verified"
  echo "separately with the normal test and MCP parity suites."
} >"$report"

cat "$report"
