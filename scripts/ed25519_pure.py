#!/usr/bin/env python3
"""Public-domain Ed25519 helpers (RFC 8032). Sign and verify with stdlib only."""
from __future__ import annotations

import hashlib
import os
import sys

b = 256
q = 2**255 - 19
l = 2**252 + 27742317777372353535851937790883648493


def _inv(x: int) -> int:
    return pow(x, q - 2, q)


d = -121665 * _inv(121666) % q
I = pow(2, (q - 1) // 4, q)


def _xrecover(y: int) -> int:
    xx = (y * y - 1) * _inv(d * y * y + 1)
    x = pow(xx, (q + 3) // 8, q)
    if (x * x - xx) % q != 0:
        x = (x * I) % q
    if x % 2:
        x = q - x
    return x


By = 4 * _inv(5)
Bx = _xrecover(By)
B = (Bx % q, By % q, 1, (Bx * By) % q)


def _edwards_add(p1, p2):
    x1, y1, z1, t1 = p1
    x2, y2, z2, t2 = p2
    a = (y1 - x1) * (y2 - x2) % q
    b_ = (y1 + x1) * (y2 + x2) % q
    c = t1 * 2 * d * t2 % q
    dd = z1 * 2 * z2 % q
    e = b_ - a
    f = dd - c
    g = dd + c
    h = b_ + a
    return (e * f % q, g * h % q, f * g % q, e * h % q)


def _scalarmult(p1, s: int):
    q1 = (0, 1, 1, 0)
    while s:
        if s & 1:
            q1 = _edwards_add(q1, p1)
        p1 = _edwards_add(p1, p1)
        s >>= 1
    return q1


def _encodepoint(p1) -> bytes:
    x, y, z, _t = p1
    zi = _inv(z)
    x = (x * zi) % q
    y = (y * zi) % q
    bits = bytearray(y.to_bytes(32, "little"))
    bits[31] ^= (x & 1) << 7
    return bytes(bits)


def _decodepoint(s: bytes):
    y = int.from_bytes(s, "little") & ((1 << 255) - 1)
    x = _xrecover(y)
    if (x & 1) != (s[31] >> 7):
        x = q - x
    p1 = (x, y, 1, x * y % q)
    if not _isoncurve(p1):
        raise ValueError("invalid point")
    return p1


def _isoncurve(p1) -> bool:
    x, y, z, t = p1
    return z % q != 0 and (x * y - z * t) % q == 0 and (y * y - x * x - z * z - d * t * t) % q == 0


def _decodeint(s: bytes) -> int:
    return int.from_bytes(s, "little")


def _hint(m: bytes) -> int:
    return int.from_bytes(hashlib.sha512(m).digest(), "little")


def publickey(seed: bytes) -> bytes:
    if len(seed) != 32:
        raise ValueError("seed must be 32 bytes")
    h = hashlib.sha512(seed).digest()
    a = 2 ** (b - 2) + sum(2**i * ((h[i // 8] >> (i % 8)) & 1) for i in range(3, b - 1))
    return _encodepoint(_scalarmult(B, a))


def signature(message: bytes, seed: bytes, public: bytes | None = None) -> bytes:
    if len(seed) != 32:
        raise ValueError("seed must be 32 bytes")
    h = hashlib.sha512(seed).digest()
    a = 2 ** (b - 2) + sum(2**i * ((h[i // 8] >> (i % 8)) & 1) for i in range(3, b - 1))
    if public is None:
        public = _encodepoint(_scalarmult(B, a))
    r = _hint(h[32:64] + message)
    r_point = _scalarmult(B, r)
    r_bytes = _encodepoint(r_point)
    s = (r + _hint(r_bytes + public + message) * a) % l
    return r_bytes + s.to_bytes(32, "little")


def verify(message: bytes, sig: bytes, public: bytes) -> bool:
    if len(sig) != 64 or len(public) != 32:
        return False
    try:
        r = _decodepoint(sig[:32])
        a = _decodepoint(public)
    except ValueError:
        return False
    s = _decodeint(sig[32:])
    if s >= l:
        return False
    h = _hint(sig[:32] + public + message)
    return _encodepoint(_scalarmult(B, s)) == _encodepoint(_edwards_add(_scalarmult(a, h), r))


def main(argv: list[str]) -> int:
    if len(argv) >= 2 and argv[1] == "gen":
        seed = os.urandom(32)
        pub = publickey(seed)
        sys.stdout.write(f"seed={seed.hex()}\npublic={pub.hex()}\n")
        return 0
    if len(argv) == 5 and argv[1] == "sign":
        seed = bytes.fromhex(argv[2])
        message = PathRead(argv[3])
        sig = signature(message, seed)
        PathWrite(argv[4], sig)
        return 0
    if len(argv) == 5 and argv[1] == "verify":
        public = bytes.fromhex(argv[2])
        message = PathRead(argv[3])
        sig = PathRead(argv[4])
        return 0 if verify(message, sig, public) else 1
    sys.stderr.write(
        "usage:\n"
        "  ed25519_pure.py gen\n"
        "  ed25519_pure.py sign <seed-hex> <message-file> <sig-out>\n"
        "  ed25519_pure.py verify <public-hex> <message-file> <sig-file>\n"
    )
    return 2


def PathRead(path: str) -> bytes:
    with open(path, "rb") as f:
        return f.read()


def PathWrite(path: str, data: bytes) -> None:
    with open(path, "wb") as f:
        f.write(data)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
