#!/usr/bin/env bash
# parity test harness: zigregex vs python re
#
# Each fixture in $FIXTURES is a 3+ line text file:
#   line 1: regex pattern (raw, no quoting)
#   line 2: flags (comma-separated subset of: i, m, s — empty line if none)
#   line 3+: haystack (joined with \n if multiline)
#
# For each fixture we run python3's re.findall and the zigregex_probe
# binary on the same input. They must produce byte-identical output.
#
# Until exec.zig lands, the matcher is a panic — we tolerate "matcher not
# yet implemented" on the zig side and only verify the python reference
# itself runs. Flip $REQUIRE_MATCH to 1 once the matcher is wired.

set -uo pipefail

PROBE="${1:-}"
FIXTURES="${2:-tests/parity/fixtures}"
REQUIRE_MATCH="${REQUIRE_MATCH:-1}"

if [ -z "$PROBE" ] || [ ! -x "$PROBE" ]; then
    echo "usage: $0 <path-to-zigregex_probe> <fixtures-dir>" >&2
    exit 2
fi

if [ ! -d "$FIXTURES" ]; then
    echo "fixtures dir not found: $FIXTURES" >&2
    exit 2
fi

pass=0
fail=0
skip=0

for f in "$FIXTURES"/*.txt; do
    [ -e "$f" ] || continue
    name=$(basename "$f" .txt)

    pattern=$(sed -n '1p' "$f")
    flags=$(sed -n '2p' "$f")
    haystack=$(sed -n '3,$p' "$f")

    py_out=$(
        PATTERN="$pattern" FLAGS="$flags" HAYSTACK="$haystack" \
        python3 - <<'PY'
import os, re, sys
pattern = os.environ["PATTERN"]
flags_str = os.environ.get("FLAGS", "")
haystack = os.environ["HAYSTACK"]
flag_bits = 0
if "i" in flags_str: flag_bits |= re.IGNORECASE
if "m" in flags_str: flag_bits |= re.MULTILINE
if "s" in flags_str: flag_bits |= re.DOTALL
try:
    pat = re.compile(pattern, flag_bits)
except re.error as e:
    print(f"PARSE_ERROR: {e}")
    sys.exit(0)
for m in pat.finditer(haystack):
    print(f"{m.start()}..{m.end()}\t{m.group(0)}")
PY
    )

    if [ "$REQUIRE_MATCH" != "1" ]; then
        # Phase 1: just verify the python reference computes a result.
        # We don't yet compare against zig output because the matcher
        # panics. Once exec.zig lands, set REQUIRE_MATCH=1.
        skip=$((skip + 1))
        echo "SKIP $name (python ref: $(echo "$py_out" | wc -l | tr -d ' ') lines)"
        continue
    fi

    zig_out=$("$PROBE" "$pattern" "$haystack" "$flags" 2>&1)
    if [ "$py_out" = "$zig_out" ]; then
        pass=$((pass + 1))
        echo "PASS $name"
    else
        fail=$((fail + 1))
        echo "FAIL $name"
        echo "  pattern: $pattern"
        echo "  py:  $(echo "$py_out" | head -5)"
        echo "  zig: $(echo "$zig_out" | head -5)"
    fi
done

echo ""
echo "parity: $pass passed, $fail failed, $skip skipped"
exit $(( fail > 0 ? 1 : 0 ))
