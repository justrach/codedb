#!/usr/bin/env bash
set -euo pipefail

# Compare the generic ARM64 release target with a Cortex-A72-tuned build on an
# actual Raspberry Pi 4. Both binaries keep identical caches, worker counts,
# warmup, retained indexes, and runtime behavior.

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
CORPUS="${1:-$ROOT}"
OUT="${CODEDB_PI_BENCH_OUT:-$ROOT/zig-out/bench-pi}"
TIME_BIN="${TIME_BIN:-/usr/bin/time}"

if [[ ! -x "$TIME_BIN" ]]; then
  echo "error: GNU time is required at $TIME_BIN (sudo apt-get install time)" >&2
  exit 1
fi

arch="$(uname -m)"
if [[ "$arch" != "aarch64" && "$arch" != "arm64" ]]; then
  echo "error: run this benchmark on 64-bit ARM Linux, ideally a Raspberry Pi 4" >&2
  exit 1
fi

model="unknown"
if [[ -r /proc/device-tree/model ]]; then
  model="$(tr -d '\0' </proc/device-tree/model)"
fi
if [[ "$model" != *"Raspberry Pi 4"* ]]; then
  echo "warning: detected '$model'; cortex_a72 results are Pi-4-specific" >&2
fi

mkdir -p "$OUT"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/codedb-pi-bench.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

generic_prefix="$tmp/generic"
tuned_prefix="$tmp/cortex-a72"

cd "$ROOT"
zig build -Doptimize=ReleaseFast -Dtarget=aarch64-linux-gnu \
  --prefix "$generic_prefix"
zig build -Doptimize=ReleaseFast -Dtarget=aarch64-linux-gnu -Dcpu=cortex_a72 \
  --prefix "$tuned_prefix"

generic_bin="$generic_prefix/bin/codedb"
tuned_bin="$tuned_prefix/bin/codedb"

run_case() {
  local variant="$1" phase="$2" bin="$3"
  local home="$tmp/$variant-home"
  mkdir -p "$home"
  "$TIME_BIN" -v -o "$OUT/$variant-$phase.time" \
    env HOME="$home" \
        CODEDB_NO_CLI_DAEMON=1 \
        CODEDB_NO_TELEMETRY=1 \
        CODEDB_ALLOW_TEMP=1 \
        "$bin" "$CORPUS" tree >"$OUT/$variant-$phase.stdout"
}

# First call measures cold scan/index startup; the second call measures restart
# behavior with the same isolated home. No production cache or worker knobs are
# changed for either variant.
for phase in cold warm; do
  run_case generic "$phase" "$generic_bin"
  run_case cortex-a72 "$phase" "$tuned_bin"
done

# The CPU target must not alter client-visible results.
for phase in cold warm; do
  cmp "$OUT/generic-$phase.stdout" "$OUT/cortex-a72-$phase.stdout"
done

report="$OUT/report.md"
{
  echo "# Raspberry Pi 4 full-performance benchmark"
  echo
  echo "- model: \`$model\`"
  echo "- architecture: \`$arch\`"
  echo "- corpus: \`$CORPUS\`"
  echo "- Zig: \`$(zig version)\`"
  echo "- output parity: **PASS**"
  echo
  echo "| Build | Phase | Peak RSS (KiB) | Elapsed |"
  echo "|---|---|---:|---:|"
  for variant in generic cortex-a72; do
    for phase in cold warm; do
      file="$OUT/$variant-$phase.time"
      rss="$(sed -n 's/^[[:space:]]*Maximum resident set size (kbytes):[[:space:]]*//p' "$file")"
      elapsed="$(sed -n 's/^[[:space:]]*Elapsed (wall clock) time (h:mm:ss or m:ss):[[:space:]]*//p' "$file")"
      echo "| $variant | $phase | ${rss:-unknown} | ${elapsed:-unknown} |"
    done
  done
  echo
  echo "Both builds use the same full cache capacities, parallel worker counts,"
  echo "warmup behavior, and retained index/content policy. Repeat runs before making"
  echo "claims; storage, cooling, kernel, and corpus shape affect Pi measurements."
} >"$report"

cat "$report"
