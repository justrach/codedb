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
   4. issue-512 regression: direct tools/call accepts inline params when
      arguments is empty, matching codedb_bundle's compatibility fallback.
   5. issue-690 regression: CLI `index` and `codedb_index` refresh a live
      MCP daemon so newly added/deleted files are visible without restart.
   6. Out-of-the-box agent route: a just-added file is visible via
      codedb_outline / codedb_read / codedb_search without codedb_index,
      and the live walker picks up an in-place edit.
   7. Mid-session live watch: same MCP process, in-place edit + new sibling;
      outline/search/read/symbol see the new contents without restart or
      codedb_index. Reports write-to-visible latency.
   8. File-symlink privacy boundary: indexing plus raw MCP, CLI, HTTP, and
      semantic-provider reads reject aliases to outside-root or sensitive data.
Usage:
  python3 scripts/e2e_mcp_test.py [--binary /path/to/codedb] [--project /path/to/project]

Defaults:
  --binary  : zig-out/bin/codedb (build artifact)
  --project : current working directory (the codedb repo itself)
"""
from __future__ import annotations

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import http.client
import json
import os
import socket
import subprocess
import sys
import tempfile
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
                 command: list[str] | None = None,
                 env: dict[str, str] | None = None) -> None:
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
            env=env,
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
        return self.call_tool_params({"name": name, "arguments": args}, timeout=timeout)

    def call_tool_params(self, params: dict[str, Any], timeout: float = 30.0) -> dict[str, Any] | None:
        """Send a tools/call request with raw params and return the response."""
        req_id = self.next_id()
        self.send({
            "jsonrpc": "2.0",
            "id": req_id,
            "method": "tools/call",
            "params": params,
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
    """Poll codedb_status until the scan is ready with at least one outline."""
    import re
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        resp = p.call_tool("codedb_status", {}, timeout=5.0)
        if resp and "result" in resp:
            text = all_tool_text(resp)
            m = re.search(r'\boutlines:\s*(\d+)', text)
            if m and int(m.group(1)) > 0 and "scan: ready" in text:
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

        r = t("no-roots mode cannot read cwd host files")
        direct = tool_text(p.call_tool("codedb_read", {"path": "etc/passwd", "raw": True}))
        pipeline = tool_text(p.call_tool("codedb_query", {
            "pipeline": [{"op": "read", "path": "etc/passwd"}],
        }))
        combined = direct + "\n" + pipeline
        if "root:" in combined or "/bin/" in combined:
            r.fail(f"host file content escaped no-roots mode: {combined[:300]!r}")
        elif "project root is not configured" not in direct or "project root is not configured" not in pipeline:
            r.fail(f"no-roots rejection was not controlled: direct={direct[:160]!r} pipeline={pipeline[:160]!r}")
        else:
            r.ok()

        r = t("process is still alive")
        poll = p.proc.poll()
        if poll is not None:
            r.fail(f"process exited with code {poll}")
        else:
            r.ok()

    finally:
        p.close()

    return results


def run_scenario_4_issue512_direct_inline_args(binary: str, project: str) -> list[TestResult]:
    """
    issue-512: direct tools/call must recover when a client sends arguments: {}
    but places real tool fields inline in params.
    """
    results: list[TestResult] = []

    def t(name: str) -> TestResult:
        r = TestResult(f"[S4] {name}")
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

        r = t("scan completes before inline-arg backtest")
        scan_ok = wait_for_scan(p, timeout=90.0)
        if not scan_ok:
            r.fail("timed out waiting for scan")
            return results
        r.ok()

        r = t("direct tools/call accepts inline path with empty arguments")
        resp = p.call_tool_params({
            "name": "codedb_outline",
            "arguments": {},
            "path": "src/mcp.zig",
        })
        text = tool_text(resp)
        if resp is None:
            r.fail("no response to inline-arg tools/call")
        elif "missing 'path'" in text or "received keys: []" in text:
            r.fail(f"inline path was dropped: {text[:220]!r}")
        elif "src/mcp.zig" not in text and "handleCall" not in text:
            r.fail(f"outline response missing expected file/symbol: {text[:220]!r}")
        else:
            r.ok()

    finally:
        p.close()

    return results


def run_scenario_5_issue690_live_index_refresh(binary: str, project: str) -> list[TestResult]:
    results: list[TestResult] = []

    def t(name: str) -> TestResult:
        r = TestResult(f"[S5] {name}")
        results.append(r)
        return r

    with tempfile.TemporaryDirectory(prefix="codedb-issue-690-", dir=Path(project).parent) as tmp:
        root = Path(tmp)
        (root / "pyproject.toml").write_text("[project]\nname = 'issue-690'\nversion = '0'\n")
        (root / "initial.py").write_text("def initial():\n    return 'initial'\n")
        p = MCPProcess(binary, [], cwd="/", command=[binary, str(root), "mcp", "--no-telemetry"])

        try:
            r = t("initial scan completes")
            if not do_initialize(p, with_roots=False) or not wait_for_scan(p):
                r.fail("MCP server did not become ready")
                return results
            r.ok()

            (root / "cli_added.py").write_text("def cli_added():\n    return 'cli_added'\n")

            r = t("CLI index rebuilds the project")
            index_run = subprocess.run(
                [binary, str(root), "index"],
                capture_output=True,
                text=True,
                env={**os.environ, "CODEDB_NO_AUTO_UPDATE": "1", "CODEDB_NO_TELEMETRY": "1"},
            )
            if index_run.returncode != 0 or "index ready" not in index_run.stdout:
                r.fail(f"index result: code={index_run.returncode} stdout={index_run.stdout[:160]!r}")
                return results
            r.ok()

            r = t("live MCP sees the file after CLI index")
            try:
                outline_text = tool_text(p.call_tool("codedb_outline", {"path": "cli_added.py"}))
            except BrokenPipeError:
                r.fail(f"MCP process exited during refresh: {p.stderr_lines()[-40:]!r}")
                return results
            if "cli_added" not in outline_text or "not indexed" in outline_text:
                r.fail(f"outline stayed stale: {outline_text[:220]!r}")
                return results
            r.ok()

            (root / "tool_added.py").write_text("def tool_added():\n    return 'tool_added'\n")

            r = t("codedb_index rebuilds the project")
            index_resp = p.call_tool("codedb_index", {"path": str(root)})
            index_text = tool_text(index_resp)
            if "indexed:" not in index_text or "error:" in index_text:
                r.fail(f"index response: {index_text[:220]!r}")
                return results
            r.ok()

            r = t("live MCP sees the file after codedb_index")
            outline_text = tool_text(p.call_tool("codedb_outline", {"path": "tool_added.py"}))
            if "tool_added" not in outline_text or "not indexed" in outline_text:
                r.fail(f"outline stayed stale: {outline_text[:220]!r}")
            else:
                r.ok()

            (root / "initial.py").unlink()

            r = t("codedb_index removes deleted files from the live MCP")
            p.call_tool("codedb_index", {"path": str(root)})
            outline_text = tool_text(p.call_tool("codedb_outline", {"path": "initial.py"}))
            if "not indexed" not in outline_text:
                r.fail(f"deleted file stayed indexed: {outline_text[:220]!r}")
            else:
                r.ok()
        finally:
            p.close()

    return results



def wait_until(predicate, timeout: float = 8.0, interval: float = 0.25) -> bool:
    seen, _ = wait_until_ms(predicate, timeout=timeout, interval=interval)
    return seen


def wait_until_ms(predicate, timeout: float = 8.0, interval: float = 0.05) -> tuple[bool, float]:
    start = time.monotonic()
    while True:
        if predicate():
            return True, (time.monotonic() - start) * 1000.0
        elapsed = (time.monotonic() - start) * 1000.0
        if elapsed >= timeout * 1000.0:
            return False, elapsed
        time.sleep(interval)


def run_scenario_6_agent_route_no_index(binary: str, project: str) -> list[TestResult]:
    """Agent path: outline/read index a just-added file; walker sees an edit."""
    results: list[TestResult] = []

    def t(name: str) -> TestResult:
        r = TestResult(f"[S6] {name}")
        results.append(r)
        return r

    with tempfile.TemporaryDirectory(prefix="codedb-agent-route-", dir=Path(project).parent) as tmp:
        root = Path(tmp)
        (root / "pyproject.toml").write_text("[project]\nname = 'agent-route'\nversion = '0'\n")
        (root / "keep.py").write_text("def keep():\n    return 'keep'\n")
        secret_canary = "uppercase_secret_canary_706"
        (root / "PRIVATE_KEY.PEM").write_text(secret_canary)
        p = MCPProcess(binary, [], cwd="/", command=[binary, str(root), "mcp", "--no-telemetry"])

        try:
            r = t("initial scan completes")
            if not do_initialize(p, with_roots=False) or not wait_for_scan(p):
                r.fail("MCP server did not become ready")
                return results
            r.ok()

            r = t("uppercase private-key path is blocked from MCP read")
            read_text = tool_text(p.call_tool("codedb_read", {"path": "PRIVATE_KEY.PEM"}))
            if "access to sensitive file blocked" not in read_text or secret_canary in read_text:
                r.fail(f"sensitive read was not blocked: {read_text[:240]!r}")
                return results
            r.ok()

            r = t("uppercase private-key contents are absent from search")
            search_text = tool_text(p.call_tool("codedb_search", {"query": secret_canary}))
            if not search_text.startswith("0 results") or "PRIVATE_KEY.PEM" in search_text:
                r.fail(f"sensitive file entered the index: {search_text[:240]!r}")
                return results
            r.ok()

            (root / "added.py").write_text("def added_live():\n    return 'added_live'\n")

            r = t("outline indexes a just-added file without codedb_index")
            outline_text = tool_text(p.call_tool("codedb_outline", {"path": "added.py"}))
            if "added_live" not in outline_text or "not indexed" in outline_text or "try codedb_index" in outline_text:
                r.fail(f"outline miss path failed: {outline_text[:240]!r}")
                return results
            r.ok()

            r = t("search sees the file after outline-on-miss")
            search_text = tool_text(p.call_tool("codedb_search", {"query": "added_live"}))
            if "added.py" not in search_text or "added_live" not in search_text:
                r.fail(f"search stayed stale after outline: {search_text[:240]!r}")
                return results
            r.ok()

            r = t("symbol finds the just-added definition without codedb_index")
            symbol_text = tool_text(p.call_tool("codedb_symbol", {"name": "added_live"}))
            if "added.py" not in symbol_text or "added_live" not in symbol_text:
                r.fail(f"symbol stayed stale after outline: {symbol_text[:240]!r}")
                return results
            r.ok()

            r = t("find locates the just-added filename without codedb_index")
            find_text = tool_text(p.call_tool("codedb_find", {"query": "added"}))
            if "added.py" not in find_text:
                r.fail(f"find stayed stale after outline: {find_text[:240]!r}")
                return results
            r.ok()

            (root / "read_added.py").write_text("def read_added():\n    return 'read_added'\n")

            r = t("read indexes a just-added file without codedb_index")
            read_text = tool_text(p.call_tool("codedb_read", {"path": "read_added.py"}))
            if "read_added" not in read_text:
                r.fail(f"read miss path failed: {read_text[:240]!r}")
                return results
            r.ok()

            r = t("search sees the file after read-on-miss")
            search_text = tool_text(p.call_tool("codedb_search", {"query": "read_added"}))
            if "read_added.py" not in search_text or "read_added" not in search_text:
                r.fail(f"search stayed stale after read: {search_text[:240]!r}")
                return results
            r.ok()

            r = t("symbol finds the definition after read-on-miss")
            symbol_text = tool_text(p.call_tool("codedb_symbol", {"name": "read_added"}))
            if "read_added.py" not in symbol_text or "read_added" not in symbol_text:
                r.fail(f"symbol stayed stale after read: {symbol_text[:240]!r}")
                return results
            r.ok()

            (root / "keep.py").write_text("def keep():\n    return 'keep_edited'\n")

            r = t("walker refreshes an in-place edit without codedb_index")
            def edited() -> bool:
                text = tool_text(p.call_tool("codedb_read", {"path": "keep.py"}))
                return "keep_edited" in text

            if not wait_until(edited, timeout=8.0):
                late = tool_text(p.call_tool("codedb_read", {"path": "keep.py"}))
                r.fail(f"walker did not pick up edit: {late[:240]!r}")
                return results
            r.ok()

            r = t("search sees the walker edit without codedb_index")
            def search_edited() -> bool:
                text = tool_text(p.call_tool("codedb_search", {"query": "keep_edited"}))
                return "keep.py" in text and "keep_edited" in text

            if not wait_until(search_edited, timeout=8.0):
                late = tool_text(p.call_tool("codedb_search", {"query": "keep_edited"}))
                r.fail(f"search stayed stale after walker edit: {late[:240]!r}")
            else:
                r.ok()
        finally:
            p.close()

    return results


def run_scenario_7_live_watch_mid_session(binary: str, project: str) -> list[TestResult]:
    """Same MCP process: in-place edit + new sibling become visible without restart."""
    results: list[TestResult] = []

    def t(name: str) -> TestResult:
        r = TestResult(f"[S7] {name}")
        results.append(r)
        return r

    with tempfile.TemporaryDirectory(prefix="codedb-live-watch-", dir=Path(project).parent) as tmp:
        root = Path(tmp)
        (root / "pyproject.toml").write_text("[project]\nname = 'live-watch'\nversion = '0'\n")
        keep = root / "keep.py"
        keep.write_text("def keep():\n    return 'keep'\n")
        p = MCPProcess(binary, [], cwd="/", command=[binary, str(root), "mcp", "--no-telemetry"])

        try:
            r = t("initial scan completes")
            if not do_initialize(p, with_roots=False) or not wait_for_scan(p):
                r.fail("MCP server did not become ready")
                return results
            r.ok()

            baseline = tool_text(p.call_tool("codedb_outline", {"path": "keep.py"}))
            r = t("baseline outline sees keep()")
            if "keep" not in baseline or "not indexed" in baseline:
                r.fail(f"baseline outline missing: {baseline[:220]!r}")
                return results
            r.ok()

            edit_latencies: list[float] = []
            for trial in range(1, 4):
                token = f"keep_live_{trial}_{int(time.time() * 1000) % 100000}"
                keep.write_text(f"def keep():\n    return 'keep'\n\ndef {token}():\n    return {trial}\n")

                def outline_has(expected: str = token) -> bool:
                    text = tool_text(p.call_tool("codedb_outline", {"path": "keep.py"}))
                    return expected in text and "not indexed" not in text

                seen, ms = wait_until_ms(outline_has, timeout=8.0, interval=0.05)
                r = t(f"trial {trial} outline sees in-place edit")
                if not seen:
                    late = tool_text(p.call_tool("codedb_outline", {"path": "keep.py"}))
                    r.fail(f"outline stale after {ms:.0f}ms: {late[:220]!r}")
                    return results
                edit_latencies.append(ms)
                r.ok(f"{ms:.0f}ms")

                r = t(f"trial {trial} search sees in-place edit")
                search_text = tool_text(p.call_tool("codedb_search", {"query": token}))
                if "keep.py" not in search_text or token not in search_text:
                    r.fail(f"search stale: {search_text[:220]!r}")
                    return results
                r.ok()

                r = t(f"trial {trial} read sees in-place edit")
                read_text = tool_text(p.call_tool("codedb_read", {"path": "keep.py"}))
                if token not in read_text:
                    r.fail(f"read stale: {read_text[:220]!r}")
                    return results
                r.ok()

                r = t(f"trial {trial} symbol sees in-place edit")
                symbol_text = tool_text(p.call_tool("codedb_symbol", {"name": token}))
                if "keep.py" not in symbol_text or token not in symbol_text:
                    r.fail(f"symbol stale: {symbol_text[:220]!r}")
                    return results
                r.ok()

            r = t("in-place edit latency (3 trials)")
            r.ok(" / ".join(f"{ms:.0f}ms" for ms in edit_latencies))

            token = f"atomic_live_{int(time.time() * 1000) % 100000}"
            tmp_path = root / "keep.py.tmp"
            tmp_path.write_text(f"def keep():\n    return 'keep'\n\ndef {token}():\n    return 9\n")
            tmp_path.replace(keep)

            def atomic_outline() -> bool:
                text = tool_text(p.call_tool("codedb_outline", {"path": "keep.py"}))
                return token in text and "not indexed" not in text

            seen, ms = wait_until_ms(atomic_outline, timeout=8.0, interval=0.05)
            r = t("atomic rename save visible to outline")
            if not seen:
                late = tool_text(p.call_tool("codedb_outline", {"path": "keep.py"}))
                r.fail(f"atomic save stale after {ms:.0f}ms: {late[:220]!r}")
            else:
                r.ok(f"{ms:.0f}ms")

            sib_token = f"sibling_live_{int(time.time() * 1000) % 100000}"
            (root / "sibling.py").write_text(f"def {sib_token}():\n    return 'sibling'\n")

            def search_sibling() -> bool:
                text = tool_text(p.call_tool("codedb_search", {"query": sib_token}))
                return "sibling.py" in text and sib_token in text

            seen, ms = wait_until_ms(search_sibling, timeout=8.0, interval=0.05)
            r = t("walker search sees new sibling without outline/read")
            if not seen:
                late = tool_text(p.call_tool("codedb_search", {"query": sib_token}))
                r.fail(f"sibling search stale after {ms:.0f}ms: {late[:220]!r}")
                return results
            r.ok(f"{ms:.0f}ms")

            r = t("symbol finds new sibling without codedb_index")
            symbol_text = tool_text(p.call_tool("codedb_symbol", {"name": sib_token}))
            if "sibling.py" not in symbol_text or sib_token not in symbol_text:
                r.fail(f"sibling symbol stale: {symbol_text[:220]!r}")
                return results
            r.ok()

            r = t("outline of sibling after walker (not miss-index first)")
            outline_text = tool_text(p.call_tool("codedb_outline", {"path": "sibling.py"}))
            if sib_token not in outline_text or "not indexed" in outline_text:
                r.fail(f"sibling outline missing: {outline_text[:220]!r}")
            else:
                r.ok()

            r = t("read of sibling after walker")
            read_text = tool_text(p.call_tool("codedb_read", {"path": "sibling.py"}))
            if sib_token not in read_text:
                r.fail(f"sibling read missing: {read_text[:220]!r}")
            else:
                r.ok()
        finally:
            p.close()

    return results


def run_scenario_8_symlink_privacy_boundary(binary: str, project: str) -> list[TestResult]:
    """File aliases must not expose outside-root or sensitive target content."""
    results: list[TestResult] = []

    def t(name: str) -> TestResult:
        r = TestResult(f"[S8] {name}")
        results.append(r)
        return r

    with tempfile.TemporaryDirectory(prefix="codedb-symlink-outside-", dir=Path(project).parent) as outside_tmp, \
         tempfile.TemporaryDirectory(prefix="codedb-symlink-project-", dir=Path(project).parent) as project_tmp:
        outside = Path(outside_tmp)
        root = Path(project_tmp)
        (root / "src").mkdir()
        (root / ".ssh").mkdir()
        (root / "pyproject.toml").write_text("[project]\nname = 'symlink-boundary'\nversion = '0'\n")
        (root / "src" / "target.py").write_text("SAFE_SYMLINK_CANARY = 'safe'\n")
        (root / "src" / "swap.py").write_text("SAFE_SWAP_CANARY = 'safe-before-retarget'\n")
        (root / ".env").write_text("SENSITIVE_SYMLINK_CANARY = 'secret'\n")
        (root / ".ssh" / "config").write_text("SENSITIVE_DIRECTORY_ALIAS_CANARY = 'secret-dir'\n")
        outside_source = outside / "outside.py"
        outside_source.write_text("OUTSIDE_SYMLINK_CANARY = 'outside'\n")
        try:
            (root / "src" / "safe_alias.py").symlink_to("target.py")
            (root / "src" / "sensitive_alias.py").symlink_to("../.env")
            (root / "src" / "outside_alias.py").symlink_to(outside_source)
            (root / "src" / "sensitive_dir_alias").symlink_to("../.ssh", target_is_directory=True)
        except OSError as exc:
            t("symlink fixture supported").ok(f"skipped: {exc}")
            return results

        p = MCPProcess(binary, [], cwd="/", command=[binary, str(root), "mcp", "--no-telemetry"])
        try:
            r = t("initial scan completes")
            if not do_initialize(p, with_roots=False) or not wait_for_scan(p):
                r.fail("MCP server did not become ready")
                return results
            r.ok()

            r = t("cold scan skips every file alias")
            safe_text = tool_text(p.call_tool("codedb_search", {"query": "SAFE_SYMLINK_CANARY", "max_results": 10}))
            outside_text = tool_text(p.call_tool("codedb_search", {"query": "OUTSIDE_SYMLINK_CANARY"}))
            sensitive_text = tool_text(p.call_tool("codedb_search", {"query": "SENSITIVE_SYMLINK_CANARY"}))
            if "SAFE_SYMLINK_CANARY" not in safe_text or "src/target.py" not in safe_text or "src/safe_alias.py" in safe_text:
                r.fail(f"file-alias skip policy was not applied: {safe_text[:220]!r}")
                return results
            if not outside_text.startswith("0 results") or not sensitive_text.startswith("0 results"):
                r.fail(f"unsafe alias was searchable: outside={outside_text[:160]!r} sensitive={sensitive_text[:160]!r}")
                return results
            r.ok()

            r = t("raw MCP reads reject file aliases")
            ordinary_read = tool_text(p.call_tool("codedb_read", {"path": "src/target.py", "raw": True}))
            alias_reads = [
                tool_text(p.call_tool("codedb_read", {"path": path, "raw": True}))
                for path in ("src/safe_alias.py", "src/outside_alias.py", "src/sensitive_alias.py", "src/sensitive_dir_alias/config")
            ]
            leaked = "\n".join(alias_reads)
            if "SAFE_SYMLINK_CANARY" not in ordinary_read:
                r.fail(f"ordinary raw read failed: {ordinary_read[:220]!r}")
                return results
            if any(canary in leaked for canary in (
                "SAFE_SYMLINK_CANARY", "OUTSIDE_SYMLINK_CANARY", "SENSITIVE_SYMLINK_CANARY", "SENSITIVE_DIRECTORY_ALIAS_CANARY",
            )) or not all("error:" in body for body in alias_reads):
                r.fail(f"raw MCP alias read was not rejected: {alias_reads!r}")
                return results
            r.ok()

            r = t("raw MCP and query pipeline reject traversal and sensitive paths")
            direct_denied = [
                tool_text(p.call_tool("codedb_read", {"path": path, "raw": True}))
                for path in (".env", "../outside.py")
            ]
            pipeline_denied = [
                tool_text(p.call_tool("codedb_query", {"pipeline": [{"op": "read", "path": path}]}))
                for path in (".env", "../outside.py", "C:\\outside.py", "src/outside_alias.py", "src/sensitive_alias.py", "src/sensitive_dir_alias/config")
            ]
            denied_text = "\n".join(direct_denied + pipeline_denied)
            if any(canary in denied_text for canary in (
                "OUTSIDE_SYMLINK_CANARY", "SENSITIVE_SYMLINK_CANARY",
            )) or not all("error" in body.lower() for body in direct_denied + pipeline_denied):
                r.fail(f"read policy bypassed: direct={direct_denied!r} pipeline={pipeline_denied!r}")
                return results
            r.ok()

            r = t("absolute-path rescue is anchored to the Explorer root")
            inside_abs = tool_text(p.call_tool("codedb_read", {"path": str(root / "src" / "target.py"), "raw": True}))
            outside_abs = tool_text(p.call_tool("codedb_read", {"path": str(outside_source), "raw": True}))
            if "SAFE_SYMLINK_CANARY" not in inside_abs or "OUTSIDE_SYMLINK_CANARY" in outside_abs or "error:" not in outside_abs:
                r.fail(f"absolute rescue boundary failed: inside={inside_abs[:160]!r} outside={outside_abs[:160]!r}")
                return results
            r.ok()

            (root / "src" / "incremental_safe.py").symlink_to("target.py")
            (root / "src" / "incremental_sensitive.py").symlink_to("../.env")
            (root / "src" / "incremental_outside.py").symlink_to(outside_source)
            r = t("incremental refresh keeps the same boundary")
            index_text = tool_text(p.call_tool("codedb_index", {"path": str(root)}))
            safe_text = tool_text(p.call_tool("codedb_search", {"query": "SAFE_SYMLINK_CANARY", "max_results": 10}))
            outside_text = tool_text(p.call_tool("codedb_search", {"query": "OUTSIDE_SYMLINK_CANARY"}))
            sensitive_text = tool_text(p.call_tool("codedb_search", {"query": "SENSITIVE_SYMLINK_CANARY"}))
            if "error:" in index_text or "SAFE_SYMLINK_CANARY" not in safe_text or "src/incremental_safe.py" in safe_text:
                r.fail(f"incremental file-alias skip failed: index={index_text[:140]!r} search={safe_text[:180]!r}")
                return results
            if not outside_text.startswith("0 results") or not sensitive_text.startswith("0 results"):
                r.fail(f"incremental unsafe alias was searchable: outside={outside_text[:160]!r} sensitive={sensitive_text[:160]!r}")
                return results
            r.ok()
        finally:
            p.close()

        # Retarget a path that was a regular indexed file during the live MCP
        # session. Subsequent cold surfaces and semantic calls must not follow
        # the replacement alias.
        (root / "src" / "swap.py").unlink()
        (root / "src" / "swap.py").symlink_to("../.env")

        home = outside / "home"
        home.mkdir()
        safe_env = {
            **os.environ,
            "HOME": str(home),
            "CODEDB_NO_AUTO_UPDATE": "1",
            "CODEDB_NO_TELEMETRY": "1",
            "CODEDB_NO_CLI_DAEMON": "1",
        }

        r = t("CLI reads reject file aliases")
        ordinary_cli = subprocess.run(
            [binary, str(root), "read", "src/target.py"],
            capture_output=True, text=True, env=safe_env, timeout=30,
        )
        alias_cli = [
            subprocess.run(
                [binary, str(root), "read", path],
                capture_output=True, text=True, env=safe_env, timeout=30,
            )
            for path in ("src/outside_alias.py", "src/sensitive_alias.py", "src/sensitive_dir_alias/config", "src/swap.py", ".env", "../outside.py", "C:\\outside.py")
        ]
        cli_leak = "\n".join(run.stdout + run.stderr for run in alias_cli)
        if ordinary_cli.returncode != 0 or "SAFE_SYMLINK_CANARY" not in ordinary_cli.stdout:
            r.fail(f"ordinary CLI read failed: code={ordinary_cli.returncode} out={ordinary_cli.stdout[:160]!r} err={ordinary_cli.stderr[-160:]!r}")
        elif any(run.returncode == 0 for run in alias_cli) or any(canary in cli_leak for canary in (
            "OUTSIDE_SYMLINK_CANARY", "SENSITIVE_SYMLINK_CANARY",
        )):
            r.fail(f"CLI alias read was not rejected: {[(run.returncode, run.stdout[:100], run.stderr[-100:]) for run in alias_cli]!r}")
        else:
            r.ok()

        # Exercise the actual TCP route, not just its shared reader. Binding a
        # temporary socket first asks the OS for a free loopback port.
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as port_socket:
            port_socket.bind(("127.0.0.1", 0))
            http_port = port_socket.getsockname()[1]
        serve_env = {**safe_env, "CODEDB_PORT": str(http_port)}
        serve_proc = subprocess.Popen(
            [binary, str(root), "serve"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=serve_env,
        )
        try:
            deadline = time.monotonic() + 20
            while True:
                try:
                    health = http.client.HTTPConnection("127.0.0.1", http_port, timeout=1)
                    health.request("GET", "/health")
                    health_response = health.getresponse()
                    health_response.read()
                    health.close()
                    if health_response.status == 200:
                        break
                except OSError:
                    pass
                if serve_proc.poll() is not None or time.monotonic() >= deadline:
                    raise RuntimeError("codedb serve did not become healthy")
                time.sleep(0.1)

            def http_read(path: str) -> tuple[int, str]:
                conn = http.client.HTTPConnection("127.0.0.1", http_port, timeout=5)
                conn.request("GET", f"/file/read?path={path}")
                response = conn.getresponse()
                body = response.read().decode(errors="replace")
                status = response.status
                conn.close()
                return status, body

            ordinary_http = http_read("src/target.py")
            alias_http = [http_read(path) for path in (
                "src/outside_alias.py", "src/sensitive_alias.py", "src/sensitive_dir_alias/config", "../outside.py", "C:%5Coutside.py",
            )]
            direct_sensitive_http = http_read(".env")
            r = t("HTTP reads reject file aliases and sensitive paths")
            http_leak = "\n".join(body for _, body in alias_http)
            if ordinary_http[0] != 200 or "SAFE_SYMLINK_CANARY" not in ordinary_http[1]:
                r.fail(f"ordinary HTTP read failed: {ordinary_http!r}")
            elif any(status not in (403, 404) for status, _ in alias_http) or any(canary in http_leak for canary in (
                "OUTSIDE_SYMLINK_CANARY", "SENSITIVE_SYMLINK_CANARY",
                "SENSITIVE_DIRECTORY_ALIAS_CANARY",
            )):
                r.fail(f"HTTP alias read was not rejected: {alias_http!r}")
            elif direct_sensitive_http[0] != 403 or "SENSITIVE_SYMLINK_CANARY" in direct_sensitive_http[1]:
                r.fail(f"HTTP sensitive-path guard failed: {direct_sensitive_http!r}")
            else:
                r.ok()
        except Exception as exc:
            r = t("HTTP reads reject file aliases and sensitive paths")
            r.fail(str(exc))
        finally:
            serve_proc.terminate()
            try:
                serve_proc.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                serve_proc.kill()
                serve_proc.communicate(timeout=5)

        captured: list[bytes] = []
        captured_lock = threading.Lock()

        class EmbeddingHandler(BaseHTTPRequestHandler):
            def do_POST(self) -> None:  # noqa: N802 - stdlib callback name
                length = int(self.headers.get("Content-Length", "0"))
                body = self.rfile.read(length)
                with captured_lock:
                    captured.append(body)
                payload = json.loads(body)
                inputs = payload.get("input", [])
                if isinstance(inputs, str):
                    inputs = [inputs]
                response = json.dumps({
                    "model": "mock-symlink-model",
                    "data": [
                        {"index": i, "embedding": [1.0] + [0.0] * 63}
                        for i in range(len(inputs))
                    ],
                }).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(response)))
                self.end_headers()
                self.wfile.write(response)

            def log_message(self, format: str, *args: Any) -> None:
                pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), EmbeddingHandler)
        server_thread = threading.Thread(target=server.serve_forever, daemon=True)
        server_thread.start()
        try:
            env = {
                **safe_env,
                "CODEDB_EMBEDDINGS_URL": f"http://127.0.0.1:{server.server_port}/v1/embeddings",
                "CODEDB_EMBEDDINGS_MODEL": "mock-symlink-model",
                "CODEDB_EMBEDDINGS_TOKEN": "mock-token",
                "CODEDB_EMBEDDINGS_DIMENSIONS": "64",
                "CODEDB_EMBEDDINGS_TIMEOUT_MS": "5000",
                "CODEDB_SEMANTIC_INDEX_CONCURRENCY": "1",
            }
            hybrid = MCPProcess(
                binary, [], cwd="/", env=env,
                command=[binary, str(root), "mcp", "--no-telemetry"],
            )
            hybrid_text = ""
            try:
                if do_initialize(hybrid, with_roots=False) and wait_for_scan(hybrid):
                    hybrid_text = tool_text(hybrid.call_tool("codedb_context", {
                        "task": "safe swap target implementation",
                        "semantic": "hybrid",
                        "max_tokens": 1024,
                    }))
            finally:
                hybrid.close()
            semantic_run = subprocess.run(
                [binary, str(root), "semantic-index"],
                capture_output=True,
                text=True,
                env=env,
                timeout=60,
            )
        finally:
            server.shutdown()
            server.server_close()
            server_thread.join(timeout=5)

        r = t("semantic endpoint receives no aliased private content")
        request_text = b"\n".join(captured).decode(errors="replace")
        if not hybrid_text or "error:" in hybrid_text:
            r.fail(f"hybrid exact fallback failed: {hybrid_text[:240]!r}")
        elif semantic_run.returncode != 0 or "semantic ANN ready" not in semantic_run.stdout:
            r.fail(f"semantic-index failed: code={semantic_run.returncode} stdout={semantic_run.stdout[:180]!r} stderr={semantic_run.stderr[-240:]!r}")
        elif "SAFE_SYMLINK_CANARY" not in request_text:
            r.fail("safe indexed content never reached the mock endpoint")
        elif any(secret in request_text for secret in (
            "OUTSIDE_SYMLINK_CANARY",
            "SENSITIVE_SYMLINK_CANARY",
            "SENSITIVE_DIRECTORY_ALIAS_CANARY",
            "safe_alias.py",
            "outside_alias.py",
            "sensitive_alias.py",
            "incremental_safe.py",
            "incremental_outside.py",
            "incremental_sensitive.py",
            "SAFE_SWAP_CANARY",
            "swap.py",
        )):
            r.fail(f"private alias leaked to embedding request: {request_text[:600]!r}")
        else:
            r.ok(f"captured {len(captured)} filtered embedding request(s)")

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

    print(f"\n{CYAN}── Scenario 4: issue-512 direct inline args ──{RESET}")
    all_results += run_scenario_4_issue512_direct_inline_args(binary, project)

    print(f"\n{CYAN}── Scenario 5: issue-690 live index refresh ──{RESET}")
    all_results += run_scenario_5_issue690_live_index_refresh(binary, project)

    print(f"\n{CYAN}── Scenario 6: agent route (outline/read on miss, no codedb_index) ──{RESET}")
    all_results += run_scenario_6_agent_route_no_index(binary, project)

    print(f"\n{CYAN}── Scenario 7: mid-session live watch (same process, no restart) ──{RESET}")
    all_results += run_scenario_7_live_watch_mid_session(binary, project)

    print(f"\n{CYAN}── Scenario 8: file-symlink privacy boundary ──{RESET}")
    all_results += run_scenario_8_symlink_privacy_boundary(binary, project)

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
