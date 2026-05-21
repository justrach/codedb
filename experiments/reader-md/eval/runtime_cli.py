#!/usr/bin/env python3
"""Single-tool CLI wrapper around the experimental codedb v0.2.5815-readermd
build. Spawns the MCP server once per invocation (heavy — meant for sub-agent
use where every tool call goes through this script).

Usage:
    runtime_cli.py <corpus_root> context "<task>"
    runtime_cli.py <corpus_root> search "<query>" [--max=N]
    runtime_cli.py <corpus_root> read <path> [-L FROM-TO]
    runtime_cli.py <corpus_root> word <identifier>
    runtime_cli.py <corpus_root> outline <path>

Designed so the only tool surface a sub-agent needs is `Bash` invoking this
script. Each call is a fresh codedb MCP session; the script returns the raw
content payload to stdout.
"""
import json
import os
import select
import subprocess
import sys
import time

NL = chr(10)
BIN = os.environ.get("CODEDB_BIN", "/tmp/reader-md-exp/zig-out/bin/codedb")


def call(corpus: str, tool: str, args: dict) -> str:
    proc = subprocess.Popen(
        [BIN, corpus, "mcp"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        bufsize=0,
    )
    buf = b""

    def recv(timeout=60):
        nonlocal buf
        deadline = time.time() + timeout
        while time.time() < deadline:
            if select.select([proc.stdout], [], [], 0.1)[0]:
                chunk = os.read(proc.stdout.fileno(), 1 << 16)
                if chunk:
                    buf += chunk
            text = buf.decode(errors="replace")
            while NL in text:
                line, rest = text.split(NL, 1)
                line = line.strip()
                if not line:
                    buf = rest.encode()
                    text = rest
                    continue
                try:
                    obj = json.loads(line)
                    buf = rest.encode()
                    return obj
                except json.JSONDecodeError:
                    buf = rest.encode()
                    text = rest
                    continue
        return None

    def send(o):
        proc.stdin.write((json.dumps(o) + NL).encode())
        proc.stdin.flush()

    send({
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {"protocolVersion": "2024-11-05", "capabilities": {},
                   "clientInfo": {"name": "eval", "version": "1.0"}},
    })
    recv()
    send({"jsonrpc": "2.0", "method": "notifications/initialized"})
    time.sleep(0.2)
    send({
        "jsonrpc": "2.0", "id": 2, "method": "tools/call",
        "params": {"name": tool, "arguments": args},
    })
    resp = recv(timeout=120)
    text = ""
    if resp and "result" in resp:
        for item in resp["result"].get("content", []):
            if item.get("type") == "text":
                text += item["text"]
    proc.terminate()
    try:
        proc.wait(timeout=3)
    except subprocess.TimeoutExpired:
        proc.kill()
    return text


def main():
    if len(sys.argv) < 3:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    corpus = sys.argv[1]
    cmd = sys.argv[2]
    if cmd == "context":
        task = sys.argv[3]
        out = call(corpus, "codedb_context", {"task": task})
    elif cmd == "search":
        query = sys.argv[3]
        max_results = 20
        for a in sys.argv[4:]:
            if a.startswith("--max="):
                max_results = int(a.split("=", 1)[1])
        out = call(corpus, "codedb_search", {"query": query, "max_results": max_results})
    elif cmd == "read":
        path = sys.argv[3]
        args = {"path": path}
        for a in sys.argv[4:]:
            if a == "-L" or a == "--lines":
                pass  # next arg
            elif "-" in a and a.replace("-", "").isdigit():
                lo, hi = a.split("-", 1)
                args["line_start"] = int(lo)
                args["line_end"] = int(hi)
        out = call(corpus, "codedb_read", args)
    elif cmd == "word":
        word = sys.argv[3]
        out = call(corpus, "codedb_word", {"word": word})
    elif cmd == "outline":
        path = sys.argv[3]
        out = call(corpus, "codedb_outline", {"path": path})
    elif cmd == "find":
        name = sys.argv[3]
        out = call(corpus, "codedb_find", {"query": name})
    else:
        print(f"unknown command: {cmd}", file=sys.stderr)
        sys.exit(2)
    print(out, end="")


if __name__ == "__main__":
    main()
