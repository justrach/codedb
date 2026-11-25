#!/usr/bin/env python3
"""Sign checksums.sha256 with the codedb release Ed25519 seed."""
from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from ed25519_pure import publickey, signature, verify  # noqa: E402


def load_seed(args: argparse.Namespace) -> bytes:
    if args.seed:
        return bytes.fromhex(args.seed.strip())
    env_name = args.key_env
    value = os.environ.get(env_name, "").strip()
    if not value:
        raise SystemExit(f"missing {env_name}; refusing to publish an unsigned manifest")
    if value.startswith("-----"):
        raise SystemExit(f"{env_name} must be 64 hex characters (32-byte seed), not PEM")
    return bytes.fromhex(value)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True, help="Path to checksums.sha256")
    parser.add_argument("--out", required=True, help="Path to write checksums.sha256.sig")
    parser.add_argument("--key-env", default="CODEDB_RELEASE_SIGNING_SEED")
    parser.add_argument("--seed", default="", help="32-byte seed as hex (tests only)")
    parser.add_argument("--expect-public", default="", help="Optional public key hex to check")
    args = parser.parse_args()

    seed = load_seed(args)
    if len(seed) != 32:
        raise SystemExit("release seed must be 32 bytes")
    public = publickey(seed)
    if args.expect_public and public.hex() != args.expect_public.strip().lower():
        raise SystemExit("signing seed does not match the compiled-in public key")
    message = Path(args.manifest).read_bytes()
    sig = signature(message, seed, public)
    if not verify(message, sig, public):
        raise SystemExit("produced signature failed self-check")
    Path(args.out).write_bytes(sig)
    sys.stdout.write(f"signed {args.manifest} -> {args.out} ({len(sig)} bytes)\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
