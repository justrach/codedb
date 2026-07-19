#!/usr/bin/env python3
"""Run one command through a CubeSandbox gateway envd endpoint.

The gateway URL and tenant key are supplied explicitly or through
SANDBOX_GATEWAY_URL and SANDBOX_GATEWAY_KEY. Credentials are never printed.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import struct
import sys
import urllib.error
import urllib.request


def connect_frame(payload: dict[str, object]) -> bytes:
    body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    return b"\x00" + struct.pack(">I", len(body)) + body


def iter_connect_messages(data: bytes):
    cursor = 0
    while cursor < len(data):
        if cursor + 5 > len(data):
            raise ValueError("truncated Connect envelope header")
        flags = data[cursor]
        length = struct.unpack(">I", data[cursor + 1 : cursor + 5])[0]
        cursor += 5
        if cursor + length > len(data):
            raise ValueError("truncated Connect envelope payload")
        payload = data[cursor : cursor + length]
        cursor += length
        if flags & 0x02:
            trailer = json.loads(payload or b"{}")
            error = trailer.get("error") if isinstance(trailer, dict) else trailer
            if error:
                raise RuntimeError(json.dumps(error, separators=(",", ":")))
            continue
        if payload:
            yield json.loads(payload)


def decoded_stream(value: object) -> bytes:
    if not isinstance(value, str):
        return b""
    return base64.b64decode(value, validate=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--gateway", default=os.environ.get("SANDBOX_GATEWAY_URL"))
    parser.add_argument("--key", default=os.environ.get("SANDBOX_GATEWAY_KEY"))
    parser.add_argument("--sandbox", required=True)
    parser.add_argument("--cwd", default="/home/user")
    parser.add_argument("command")
    args = parser.parse_args()

    if not args.gateway or not args.key:
        parser.error("gateway and key are required (flags or SANDBOX_GATEWAY_* env)")

    process = {
        "cmd": "/bin/bash",
        "args": ["-l", "-c", args.command],
        "cwd": args.cwd,
        "envs": {},
    }
    request_body = connect_frame({"process": process})
    url = (
        args.gateway.rstrip("/")
        + f"/sandboxes/{args.sandbox}/host/49983/process.Process/Start"
    )
    request = urllib.request.Request(
        url,
        data=request_body,
        headers={
            "X-API-Key": args.key,
            "Content-Type": "application/connect+json",
            "User-Agent": "codedb-benchmark/1.0",
        },
        method="POST",
    )

    try:
        with urllib.request.urlopen(request, timeout=600) as response:
            response_body = response.read()
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        print(f"gateway HTTP {exc.code}: {detail}", file=sys.stderr)
        return 1

    exit_status: str | None = None
    try:
        for message in iter_connect_messages(response_body):
            event = message.get("event", {})
            if not isinstance(event, dict):
                continue
            data = event.get("data", {})
            if isinstance(data, dict):
                stdout = decoded_stream(data.get("stdout"))
                stderr = decoded_stream(data.get("stderr"))
                if stdout:
                    sys.stdout.buffer.write(stdout)
                    sys.stdout.buffer.flush()
                if stderr:
                    sys.stderr.buffer.write(stderr)
                    sys.stderr.buffer.flush()
            end = event.get("end", {})
            if isinstance(end, dict) and isinstance(end.get("status"), str):
                exit_status = end["status"]
    except (ValueError, RuntimeError, json.JSONDecodeError) as exc:
        print(f"invalid envd response: {exc}", file=sys.stderr)
        return 1

    if exit_status not in (None, "exit status 0"):
        print(exit_status, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
