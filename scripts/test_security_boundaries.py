"""Live MCP/HTTP regression checks for project-file boundaries."""
import http.client
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
from unittest.mock import patch
from e2e_mcp_test import MCPProcess, do_initialize, wait_for_scan, all_tool_text

binary = str(Path(sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/codedb").resolve())
with tempfile.TemporaryDirectory(prefix="codedb-security-") as directory:
    base = Path(directory)
    root = base / "repo"
    root.mkdir()
    (root / "pyproject.toml").write_text("[project]\nname = 'security-control'\nversion = '0'\n")
    (root / "safe.py").write_text("def control(): return 'PUBLIC_CONTROL'\n")
    (root / ".env").write_text("TOKEN=PRIVATE_MARKER_4821\n")
    (base / "outside.py").write_text("PRIVATE_MARKER_4821\n")
    (root / "sources").mkdir()
    (root / "sources" / "nested.py").write_text("PUBLIC_CONTROL\n")
    (root / "alias").symlink_to("sources", target_is_directory=True)
    (root / "alias.py").symlink_to("safe.py")
    (root / "escape.py").symlink_to("../outside.py")
    (root / "secret.py").symlink_to(".env")
    env = {"HOME": str(base / "home"), "CODEDB_ALLOW_TEMP": "1", "CODEDB_NO_CLI_DAEMON": "1"}
    with patch.dict(os.environ, env):
        p = MCPProcess(binary, [], cwd="/", command=[binary, str(root), "mcp", "--no-telemetry"])
        try:
            assert do_initialize(p, with_roots=False) and wait_for_scan(p)
            for path in ["safe.py", "alias/nested.py"]:
                response = p.call_tool("codedb_query", {"pipeline": [{"op": "read", "path": path}]})
                assert "PUBLIC_CONTROL" in all_tool_text(response), response
            for path in ["../outside.py", str(base / "outside.py"), ".env", "escape.py", "secret.py", "alias.py"]:
                response = p.call_tool("codedb_query", {"pipeline": [{"op": "read", "path": path}]})
                assert response is not None and "PRIVATE_MARKER_4821" not in all_tool_text(response), response
            response = p.call_tool("codedb_search", {"query": "PRIVATE_MARKER_4821"})
            assert response is not None and "0 results" in all_tool_text(response), response
        finally:
            p.close()
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        server_env = dict(os.environ, CODEDB_PORT=str(port))
        proc = subprocess.Popen([binary, str(root), "serve", "--no-telemetry"], env=server_env,
                                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            for _ in range(200):
                try:
                    with socket.create_connection(("127.0.0.1", port), timeout=.2):
                        break
                except OSError:
                    assert proc.poll() is None, "HTTP server exited"
                    time.sleep(.05)
            for path in ["safe.py", "alias/nested.py", "alias.py", ".env", "escape.py", "secret.py", "../outside.py"]:
                conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
                conn.request("GET", "/file/read?path=" + path)
                response = conn.getresponse()
                data = response.read().decode()
                conn.close()
                if path in ["safe.py", "alias/nested.py"]:
                    assert response.status == 200 and "PUBLIC_CONTROL" in data, data
                else:
                    assert response.status != 200 and "PRIVATE_MARKER_4821" not in data, data
        finally:
            proc.terminate()
            proc.wait(timeout=10)
print("PASS: MCP indexing/query and HTTP reject escapes and secrets; ordinary and in-root alias reads succeed")
