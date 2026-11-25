# Release signing

codedb release assets are SHA-256 checksummed **and** Ed25519-signed. Installers
and `codedb update` refuse to replace a binary unless `checksums.sha256.sig`
verifies with the public key compiled into the binary, `install/install.sh`,
`install/install.ps1`, and `npm/scripts/postinstall.js`.

Private keys are never committed.

## Keys

The production public key is `src/release_sign.zig` (`public_key_hex`). The
matching 32-byte seed lives only as GitHub Actions secret
`CODEDB_RELEASE_SIGNING_SEED` (64 hex characters).

Generate a new key:

```bash
python3 scripts/gen-release-signing-key.py
```

Then:

1. Store `CODEDB_RELEASE_SIGNING_SEED` as a repository secret. Do not paste it
   into issues, chat, or git.
2. Replace `public_key_bytes` / `public_key_hex` in `src/release_sign.zig`.
3. Replace the same hex string in `install/install.sh` (`CODEDB_RELEASE_PUBKEY_DEFAULT`),
   `install/install.ps1`, and `npm/scripts/postinstall.js`.
4. Copy `install/install.sh` to `website/app/install_script.sh` and
   `website/dist/install.sh` so the three stay byte-identical.
5. Ship a new binary before relying on the rotated key — older binaries still
   verify with the previous compiled-in key.

## Publishing

`.github/workflows/release-binaries.yml` builds assets, writes
`checksums.sha256`, then runs:

```bash
python3 scripts/sign-release.py \
  --manifest assets/checksums.sha256 \
  --out assets/checksums.sha256.sig \
  --expect-public "$(python3 -c 'from pathlib import Path; import re; t=Path("src/release_sign.zig").read_text(); print(re.search(r\"public_key_hex = \\\"([0-9a-f]+)\\\"\", t).group(1))')"
```

The job fails closed if the secret is missing or does not match the compiled-in
public key. Upload both `checksums.sha256` and `checksums.sha256.sig`.

## macOS

Do **not** strip quarantine with `xattr -c`. Release Darwin binaries are Apple
Developer ID signed and notarized; `install.sh` runs `codesign --verify` on
Mach-O downloads instead.

## Local verification

```bash
python3 scripts/ed25519_pure.py verify \
  "$(grep public_key_hex src/release_sign.zig | cut -d'"' -f2)" \
  checksums.sha256 \
  checksums.sha256.sig
```
