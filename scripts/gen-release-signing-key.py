#!/usr/bin/env python3
"""Generate a codedb release-signing Ed25519 seed. Never commit the seed."""
from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from ed25519_pure import publickey  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--out-dir",
        default="-",
        help="Directory to write seed/public hex files, or - for stdout",
    )
    args = parser.parse_args()
    seed = os.urandom(32)
    public = publickey(seed)
    if args.out_dir == "-":
        sys.stdout.write(f"CODEDB_RELEASE_SIGNING_SEED={seed.hex()}\n")
        sys.stdout.write(f"public_key_hex={public.hex()}\n")
        sys.stdout.write(
            "Store the seed as GitHub Actions secret CODEDB_RELEASE_SIGNING_SEED.\n"
            "Replace src/release_sign.zig public_key_bytes and the copies in\n"
            "install/install.sh, install/install.ps1, and npm/scripts/postinstall.js.\n"
            "Never commit the seed.\n"
        )
        return 0
    out = Path(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    seed_path = out / "codedb-release-signing-seed.hex"
    pub_path = out / "codedb-release-signing-pub.hex"
    seed_path.write_text(seed.hex() + "\n")
    os.chmod(seed_path, 0o600)
    pub_path.write_text(public.hex() + "\n")
    sys.stdout.write(f"wrote {seed_path} (0600) and {pub_path}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
