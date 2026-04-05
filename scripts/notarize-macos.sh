#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <binary-path>" >&2
  exit 1
fi

binary_path="$1"

: "${APPLE_API_KEY_ID:?APPLE_API_KEY_ID is required}"
: "${APPLE_API_ISSUER_ID:?APPLE_API_ISSUER_ID is required}"
: "${APPLE_API_KEY_BASE64:?APPLE_API_KEY_BASE64 is required}"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/codedb-notary.XXXXXX")"
api_key_path="$tmp_dir/codedb-notary-key.p8"
zip_path="$tmp_dir/$(basename "$binary_path").zip"
export API_KEY_PATH="$api_key_path"

cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

python3 - <<'PY'
import base64
import os
import pathlib

pathlib.Path(os.environ["API_KEY_PATH"]).write_bytes(
    base64.b64decode(os.environ["APPLE_API_KEY_BASE64"])
)
PY

chmod 600 "$api_key_path"
codesign --verify --verbose=2 "$binary_path"
ditto -c -k --keepParent "$binary_path" "$zip_path"
xcrun notarytool submit "$zip_path" \
  --key "$api_key_path" \
  --key-id "$APPLE_API_KEY_ID" \
  --issuer "$APPLE_API_ISSUER_ID" \
  --wait
xcrun stapler staple "$binary_path" || true
spctl --assess --type execute --verbose=4 "$binary_path"
