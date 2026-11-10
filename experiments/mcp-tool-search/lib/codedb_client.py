"""Talk to a long-lived codedb MCP process for tool-catalog search."""

from __future__ import annotations

import json
import os
import re
import subprocess
import threading
import time
from pathlib import Path
from typing import Any


class MCPProcess:
    def __init__(self, binary: str, root: str) -> None:
        env = os.environ.copy()
        env["CODEDB_QUIET"] = "1"
        self.proc = subprocess.Popen(
            [binary, root, "mcp"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            cwd=root,
            env=env,
            text=True,
            bufsize=1,
        )
        self._id = 1
        self._lock = threading.Lock()
        self._lines: list[str] = []
        self._stderr: list[str] = []
        threading.Thread(target=self._read, daemon=True).start()
        threading.Thread(target=self._read_err, daemon=True).start()

    def _read(self) -> None:
        assert self.proc.stdout
        for line in self.proc.stdout:
            line = line.strip()
            if line:
                with self._lock:
                    self._lines.append(line)

    def _read_err(self) -> None:
        assert self.proc.stderr
        for line in self.proc.stderr:
            with self._lock:
                self._stderr.append(line.rstrip())

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
            time.sleep(0.01)
        return None

    def next_id(self) -> int:
        self._id += 1
        return self._id

    def call_tool(self, name: str, args: dict[str, Any], timeout: float = 30.0) -> dict[str, Any] | None:
        req_id = self.next_id()
        self.send(
            {
                "jsonrpc": "2.0",
                "id": req_id,
                "method": "tools/call",
                "params": {"name": name, "arguments": args},
            }
        )
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            msg = self.recv(timeout=1.0)
            if msg is None:
                continue
            if msg.get("id") == req_id:
                return msg
        return None

    def close(self) -> None:
        try:
            if self.proc.stdin:
                self.proc.stdin.close()
        except Exception:
            pass
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()

    def stderr(self) -> str:
        with self._lock:
            return "\n".join(self._stderr[-40:])


def tool_text(resp: dict[str, Any] | None) -> str:
    if not resp:
        return ""
    content = resp.get("result", {}).get("content", [])
    return "\n".join(c.get("text", "") for c in content if isinstance(c, dict))


def initialize(p: MCPProcess) -> bool:
    p.send(
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "mcp-tool-search-harness", "version": "1"},
            },
        }
    )
    resp = p.recv(timeout=15)
    if resp is None or "result" not in resp:
        return False
    p.send({"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}})
    return True


def wait_ready(p: MCPProcess, timeout: float = 90.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        resp = p.call_tool("codedb_status", {}, timeout=8.0)
        text = tool_text(resp)
        m = re.search(r"outlines:\s*(\d+)", text)
        if m and int(m.group(1)) > 0 and "scan: ready" in text:
            return True
        time.sleep(0.4)
    return False


def parse_search_json(text: str) -> list[str]:
    try:
        data = json.loads(text)
    except json.JSONDecodeError:
        paths = []
        for line in text.splitlines():
            m = re.search(r"([A-Za-z0-9_./-]+\.py):\d+", line)
            if m:
                paths.append(m.group(1))
        return paths
    out = []
    for row in data.get("results") or []:
        path = row.get("path")
        if path:
            out.append(path)
    return out


_ID_MAP: dict[str, str] = {}


def load_id_map(corpus: Path) -> None:
    global _ID_MAP
    p = corpus / "id_map.json"
    if p.exists():
        _ID_MAP = json.loads(p.read_text(encoding="utf-8"))


def path_to_id(path: str) -> str:
    base = Path(path).name
    if base in _ID_MAP:
        return _ID_MAP[base]
    if base.endswith(".py"):
        stem = base[:-3]
        if "__" in stem:
            server, name = stem.split("__", 1)
            return f"{server}.{name}"
        return stem
    return base


class CodedbSession:
    def __init__(self, binary: str, corpus: Path) -> None:
        self.binary = binary
        self.corpus = corpus
        load_id_map(corpus)
        self.proc: MCPProcess | None = None
        self.index_s = 0.0
        self.ready = False
        self.error: str | None = None

    def start(self) -> None:
        t0 = time.perf_counter()
        self.proc = MCPProcess(self.binary, str(self.corpus))
        if not initialize(self.proc):
            self.error = "initialize failed: " + self.proc.stderr()
            return
        if not wait_ready(self.proc):
            self.error = "scan not ready: " + self.proc.stderr()
            return
        self.index_s = time.perf_counter() - t0
        self.ready = True

    def close(self) -> None:
        if self.proc:
            self.proc.close()

    def search(self, query: str, max_results: int = 20) -> list[str]:
        assert self.proc
        resp = self.proc.call_tool(
            "codedb_search",
            {"query": query, "max_results": max_results, "format": "json"},
            timeout=20.0,
        )
        return [path_to_id(p) for p in parse_search_json(tool_text(resp))]

    def word(self, word: str) -> list[str]:
        assert self.proc
        resp = self.proc.call_tool("codedb_word", {"word": word}, timeout=15.0)
        text = tool_text(resp)
        ids = []
        for line in text.splitlines():
            m = re.search(r"([A-Za-z0-9_./-]+\.py)", line)
            if m:
                tid = path_to_id(m.group(1))
                if tid not in ids:
                    ids.append(tid)
        return ids

    def symbol(self, name: str, max_results: int = 20) -> list[str]:
        assert self.proc
        resp = self.proc.call_tool(
            "codedb_symbol",
            {"name": name, "max_results": max_results, "format": "json", "fuzzy": True},
            timeout=15.0,
        )
        text = tool_text(resp)
        ids = []
        try:
            data = json.loads(text)
            rows = data.get("results") or data.get("symbols") or []
            if isinstance(rows, list):
                for row in rows:
                    if isinstance(row, dict) and row.get("path"):
                        tid = path_to_id(row["path"])
                        if tid not in ids:
                            ids.append(tid)
        except json.JSONDecodeError:
            for m in re.finditer(r"([A-Za-z0-9_./-]+\.py)", text):
                tid = path_to_id(m.group(1))
                if tid not in ids:
                    ids.append(tid)
        return ids

    def find(self, query: str, max_results: int = 20) -> list[str]:
        assert self.proc
        resp = self.proc.call_tool(
            "codedb_find",
            {"query": query, "max_results": max_results},
            timeout=15.0,
        )
        ids = []
        for m in re.finditer(r"([A-Za-z0-9_./-]+\.py)", tool_text(resp)):
            tid = path_to_id(m.group(1))
            if tid not in ids:
                ids.append(tid)
        return ids
