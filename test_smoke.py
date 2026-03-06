#!/usr/bin/env python3
import subprocess, json, sys, time, threading

BINARY = "/tmp/devswarm/zig-out/bin/devswarm"

proc = subprocess.Popen(
    [BINARY],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
)

def send(msg):
    line = json.dumps(msg) + "\n"
    proc.stdin.write(line.encode())
    proc.stdin.flush()

# Drain stderr in background
def drain_stderr():
    for line in proc.stderr:
        sys.stderr.write("[stderr] " + line.decode())
threading.Thread(target=drain_stderr, daemon=True).start()

# Initialize handshake
send({"jsonrpc":"2.0","id":1,"method":"initialize","params":{
    "protocolVersion":"2024-11-05",
    "clientInfo":{"name":"smoke","version":"0.1"},
    "capabilities":{}
}})

line = proc.stdout.readline().decode().strip()
resp = json.loads(line)
print(f"[init] {resp['result']['serverInfo']}")

send({"jsonrpc":"2.0","method":"notifications/initialized"})

# run_agent with haiku
print("\n>> Sending run_agent (haiku, writable)...\n")
send({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{
    "name": "run_agent",
    "arguments": {
        "prompt": "Create a file at /tmp/devswarm_smoke_test.txt containing 'hello from devswarm', then read it back and print its contents, then delete it. Be very brief.",
        "role": "fixer",
        "writable": True,
        "model": "haiku",
    }
}})

print("[waiting for response...]\n")
start = time.time()

while True:
    line = proc.stdout.readline()
    if not line:
        print("[EOF — process ended]")
        break
    line = line.decode().strip()
    if not line:
        continue
    try:
        msg = json.loads(line)
    except:
        print(f"[raw] {line[:200]}")
        continue

    method = msg.get("method", "")
    if method == "notifications/message":
        data = msg.get("params", {}).get("data", "")
        print(f"  NOTIFY  {data}")
    elif msg.get("id") == 2:
        elapsed = time.time() - start
        content = msg.get("result", {}).get("content", [{}])
        text = content[0].get("text", "") if content else str(msg)
        print(f"\n  RESULT  ({elapsed:.1f}s)\n{'='*60}\n{text[:3000]}")
        break
    else:
        print(f"  [msg]   {json.dumps(msg)[:160]}")

proc.terminate()
