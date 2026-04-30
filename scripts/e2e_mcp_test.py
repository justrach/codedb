#!/usr/bin/env python3
"""
E2E MCP test harness for codedb.

Scenarios covered:
  1. issue-346 regression: spawn from cwd=/, complete MCP handshake via roots, wait
     for scan to finish, verify core tools return real data from the project.
  2. Normal mode: spawn with explicit --root <path>, verify scan runs immediately
     and tools return data without needing a roots handshake.
  3. No-roots client: spawn from cwd=/, client declares no roots capability, MCP
     stays alive and tools respond gracefully (0 files, no crash).

Usage:
  python3 scripts/e2e_mcp_test.py [--binary /path/to/codedb] [--project /path/to/project]

Defaults:
  --binary  : zig-out/bin/codedb (build artifact)
  --project : current working directory (the codedb repo itself)
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Any


# ── ANSI colours ──────────────────────────────────────────────────────────────

GREEN = "\033[32m"
RED = "\033[31m"
YELLOW = "\033[33m"
CYAN = "\033[36m"
BOLD = "\033[1m"
RESET = "\033[0m"

PASS = f"{GREEN}PASS{RESET}"
FAIL = f"{RED}FAIL{RESET}"
SKIP = f"{YELLOW}SKIP{RESET}"


# ── MCP subprocess wrapper ────────────────────────────────────────────────────

class MCPProcess:
    """Wraps a codedb mcp subprocess; sends/receives JSON-RPC over stdio."""

    def __init__(self, binary: str, args: list[str], cwd: str,
                 command: list[str] | None = None) -> None:
        """
        command: full argv override (default: [binary, "mcp"] + args).
        Use command=[binary, root, "mcp"] for explicit-root invocation.
        """
        argv = command if command is not None else [binary, "mcp"] + args
        self.proc = subprocess.Popen(
            argv,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            cwd=cwd,
            text=True,
            bufsize=1,
        )
        self._id = 1
        self._lock = threading.Lock()
        self._lines: list[str] = []
        self._stderr_lines: list[str] = []
        self._reader = threading.Thread(target=self._read_loop, daemon=True)
        self._reader.start()
        self._stderr_reader = threading.Thread(target=self._stderr_loop, daemon=True)
        self._stderr_reader.start()

    def _read_loop(self) -> None:
        assert self.proc.stdout
        for line in self.proc.stdout:
            line = line.strip()
            if line:
                with self._lock:
                    self._lines.append(line)

    def _stderr_loop(self) -> None:
        assert self.proc.stderr
        for line in self.proc.stderr:
            with self._lock:
                self._stderr_lines.append(line.rstrip())

    def send(self, msg: dict[str, Any]) -> None:
        assert self.proc.stdin
        self.proc.stdin.write(json.dumps(msg) + "\n")
        self.proc.stdin.flush()

    def recv(self, timeout: float = 10.0) -> dict[str, Any] | None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            with self._lock:
                if self._lines:
                    return json.loads(self._lines.pop(0))
            time.sleep(0.02)
        return None

    def recv_method(self, method: str, timeout: float = 10.0) -> dict[str, Any] | None:
        """Wait for a message with a specific 'method' field (server→client request)."""
        deadline = time.monotonic() + timeout
        buf: list[str] = []
        while time.monotonic() < deadline:
            with self._lock:
                remaining = list(self._lines)
                self._lines.clear()
            for raw in remaining:
                msg = json.loads(raw)
                if msg.get("method") == method:
                    with self._lock:
                        self._lines = buf + self._lines  # put others back
                    return msg
                buf.append(raw)
            with self._lock:
                self._lines = buf + self._lines
            buf = []
            time.sleep(0.02)
        return None

    def next_id(self) -> int:
        self._id += 1
        return self._id

    def call_tool(self, name: str, args: dict[str, Any], timeout: float = 30.0) -> dict[str, Any] | None:
        """Send a tools/call request and return the response."""
        req_id = self.next_id()
        self.send({
            "jsonrpc": "2.0",
            "id": req_id,
            "method": "tools/call",
            "params": {"name": name, "arguments": args},
        })
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            msg = self.recv(timeout=1.0)
            if msg is None:
                continue
            if msg.get("id") == req_id:
                return msg
        return None

    def stderr_lines(self) -> list[str]:
        with self._lock:
            return list(self._stderr_lines)

    def close(self) -> None:
        try:
            assert self.proc.stdin
            self.proc.stdin.close()
        except Exception:
            pass
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()


# ── Helpers ───────────────────────────────────────────────────────────────────

def do_initialize(p: MCPProcess, with_roots: bool = True) -> bool:
    """Send initialize + initialized. Returns True if server replied."""
    capabilities: dict[str, Any] = {}
    if with_roots:
        capabilities["roots"] = {"listChanged": True}

    p.send({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "protocolVersion": "2024-11-05",
            "capabilities": capabilities,
            "clientInfo": {"name": "e2e-test", "version": "1"},
        },
    })
    resp = p.recv(timeout=10)
    if resp is None or "result" not in resp:
        return False
    p.send({"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}})
    return True


def reply_roots(p: MCPProcess, project_path: str, timeout: float = 5.0) -> bool:
    """
    Wait for the server's roots/list request, reply with project_path.
    Returns True if the request arrived and we replied.
    """
    req = p.recv_method("roots/list", timeout=timeout)
    if req is None:
        return False
    p.send({
        "jsonrpc": "2.0",
        "id": req["id"],
        "result": {
            "roots": [{"uri": f"file://{project_path}", "name": "project"}],
        },
    })
    return True


def all_tool_text(resp: dict[str, Any] | None) -> str:
    """Concatenate all content[*].text from a tools/call response."""
    if resp is None:
        return ""
    content = resp.get("result", {}).get("content", [])
    return "\n".join(c.get("text", "") for c in content if isinstance(c, dict))


def wait_for_scan(p: MCPProcess, timeout: float = 60.0) -> bool:
    """Poll codedb_status until outlines > 0 (full scan + outline pass done) or timeout."""
    import re
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        resp = p.call_tool("codedb_status", {}, timeout=5.0)
        if resp and "result" in resp:
            text = all_tool_text(resp)
            m = re.search(r'\boutlines:\s*(\d+)', text)
            if m and int(m.group(1)) > 0:
                return True
        time.sleep(1.0)
    return False


def tool_text(resp: dict[str, Any] | None) -> str:
    """Return all content text joined — use all_tool_text directly for assertions."""
    return all_tool_text(resp)


# ── Test cases ────────────────────────────────────────────────────────────────

class TestResult:
    def __init__(self, name: str) -> None:
        self.name = name
        self.passed = False
        self.message = ""

    def ok(self, msg: str = "") -> "TestResult":
        self.passed = True
        self.message = msg
        return self

    def fail(self, msg: str) -> "TestResult":
        self.passed = False
        self.message = msg
        return self


def run_scenario_1_issue346_regression(binary: str, project: str) -> list[TestResult]:
    """
    issue-346: spawn from cwd=/, roots handshake delivers real path, tools work.
    """
    results: list[TestResult] = []

    def t(name: str) -> TestResult:
        r = TestResult(f"[S1] {name}")
        results.append(r)
        return r

    p = MCPProcess(binary, [], cwd="/")

    try:
        r = t("initialize does not crash (no transport-closed)")
        ok = do_initialize(p, with_roots=True)
        if not ok:
            r.fail("no initialize response — transport closed")
            return results
        r.ok()

        r = t("server sends roots/list request")
        got_roots_req = reply_roots(p, project, timeout=5.0)
        if not got_roots_req:
            r.fail("server never sent roots/list request")
        else:
            r.ok()

        r = t("scan completes and files > 0")
        scan_ok = wait_for_scan(p, timeout=90.0)
        if not scan_ok:
            r.fail("timed out waiting for scan (files stayed at 0)")
        else:
            r.ok()

        r = t("codedb_tree returns non-empty result")
        resp = p.call_tool("codedb_tree", {})
        text = tool_text(resp)
        if not text or len(text) < 20:
            r.fail(f"tree response too short: {text!r}")
        else:
            r.ok(f"{len(text)} chars")

        r = t("codedb_search finds 'DeferredScan' in project")
        resp = p.call_tool("codedb_search", {"query": "DeferredScan", "max_results": 5})
        text = tool_text(resp)
        if "DeferredScan" not in text:
            r.fail(f"DeferredScan not found in search results: {text[:200]!r}")
        else:
            r.ok()

        r = t("codedb_hot returns recent files")
        resp = p.call_tool("codedb_hot", {"limit": 5})
        text = tool_text(resp)
        if not text or len(text) < 10:
            r.fail(f"hot response empty: {text!r}")
        else:
            r.ok(f"{len(text)} chars")

        r = t("codedb_outline works on src/mcp.zig")
        resp = p.call_tool("codedb_outline", {"path": "src/mcp.zig"})
        text = tool_text(resp)
        if "run" not in text and "DeferredScan" not in text:
            r.fail(f"outline missing expected symbols: {text[:200]!r}")
        else:
            r.ok()

        r = t("codedb_symbol finds 'DeferredScan'")
        resp = p.call_tool("codedb_symbol", {"name": "DeferredScan"})
        text = tool_text(resp)
        if "DeferredScan" not in text:
            r.fail(f"symbol lookup returned: {text[:200]!r}")
        else:
            r.ok()

    finally:
        p.close()

    return results


def run_scenario_2_normal_mode(binary: str, project: str) -> list[TestResult]:
    """
    Normal mode: explicit positional root (`codedb <project> mcp`), scan runs immediately,
    no roots handshake needed.
    """
    results: list[TestResult] = []

    def t(name: str) -> TestResult:
        r = TestResult(f"[S2] {name}")
        results.append(r)
        return r

    p = MCPProcess(binary, [], cwd="/", command=[binary, project, "mcp"])

    try:
        r = t("initialize succeeds")
        ok = do_initialize(p, with_roots=False)
        if not ok:
            r.fail("no initialize response")
            return results
        r.ok()

        r = t("server does NOT send roots/list (scan is immediate)")
        # Give 2 seconds — if no roots/list arrives, that's correct for explicit-root mode
        req = p.recv_method("roots/list", timeout=2.0)
        if req is not None:
            r.fail("server sent roots/list even though root was explicit — unexpected")
        else:
            r.ok("no roots/list request (correct)")

        r = t("scan completes without roots handshake")
        scan_ok = wait_for_scan(p, timeout=90.0)
        if not scan_ok:
            r.fail("timed out waiting for scan")
        else:
            r.ok()

        r = t("codedb_search works")
        resp = p.call_tool("codedb_search", {"query": "isIndexableRoot", "max_results": 3})
        text = tool_text(resp)
        if "isIndexableRoot" not in text:
            r.fail(f"search result: {text[:200]!r}")
        else:
            r.ok()

    finally:
        p.close()

    return results


def run_scenario_3_no_roots_client(binary: str) -> list[TestResult]:
    """
    No-roots client: spawn from cwd=/, no roots capability, MCP stays alive, tools
    respond gracefully with 0 files (no crash, no transport-closed).
    """
    results: list[TestResult] = []

    def t(name: str) -> TestResult:
        r = TestResult(f"[S3] {name}")
        results.append(r)
        return r

    p = MCPProcess(binary, [], cwd="/")

    try:
        r = t("initialize succeeds with no roots capability")
        ok = do_initialize(p, with_roots=False)
        if not ok:
            r.fail("no initialize response — transport closed")
            return results
        r.ok()

        r = t("server does NOT send roots/list")
        req = p.recv_method("roots/list", timeout=3.0)
        if req is not None:
            r.fail("server sent roots/list to a client with no roots capability")
        else:
            r.ok("correctly skipped roots/list")

        r = t("codedb_status responds (0 files is fine)")
        resp = p.call_tool("codedb_status", {})
        if resp is None or "result" not in resp:
            r.fail("codedb_status did not respond")
        else:
            r.ok(f"responded: {tool_text(resp)[:80]}")

        r = t("codedb_search responds (may return empty)")
        resp = p.call_tool("codedb_search", {"query": "anything", "max_results": 5})
        if resp is None:
            r.fail("no response to codedb_search — server may have crashed")
        else:
            r.ok("responded (empty results expected)")

        r = t("process is still alive")
        poll = p.proc.poll()
        if poll is not None:
            r.fail(f"process exited with code {poll}")
        else:
            r.ok()

    finally:
        p.close()

    return results


# ── Runner ────────────────────────────────────────────────────────────────────

def main() -> int:
    parser = argparse.ArgumentParser(description="codedb MCP E2E test harness")
    parser.add_argument("--binary", default="zig-out/bin/codedb",
                        help="Path to codedb binary (default: zig-out/bin/codedb)")
    parser.add_argument("--project", default=os.getcwd(),
                        help="Absolute path to project to index (default: cwd)")
    args = parser.parse_args()

    binary = str(Path(args.binary).resolve())
    project = str(Path(args.project).resolve())

    if not Path(binary).exists():
        print(f"{RED}ERROR:{RESET} binary not found: {binary}")
        print("Run `zig build` first, or pass --binary /path/to/codedb")
        return 1

    print(f"\n{BOLD}codedb MCP E2E test harness{RESET}")
    print(f"  binary : {binary}")
    print(f"  project: {project}\n")

    all_results: list[TestResult] = []

    print(f"{CYAN}── Scenario 1: issue-346 regression (spawn from /, roots handshake) ──{RESET}")
    all_results += run_scenario_1_issue346_regression(binary, project)

    print(f"\n{CYAN}── Scenario 2: normal mode (explicit --root) ──{RESET}")
    all_results += run_scenario_2_normal_mode(binary, project)

    print(f"\n{CYAN}── Scenario 3: no-roots client (spawn from /, no scan) ──{RESET}")
    all_results += run_scenario_3_no_roots_client(binary)

    print()
    passed = 0
    failed = 0
    for r in all_results:
        status = PASS if r.passed else FAIL
        detail = f"  {r.message}" if r.message else ""
        print(f"  {status}  {r.name}{detail}")
        if r.passed:
            passed += 1
        else:
            failed += 1

    print(f"\n{BOLD}Results: {passed}/{len(all_results)} passed{RESET}")
    if failed:
        print(f"{RED}{failed} test(s) failed.{RESET}")
        return 1
    print(f"{GREEN}All tests passed.{RESET}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
