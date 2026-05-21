#!/usr/bin/env python3
"""
search-shootout: codedb vs SQLite FTS5 (trigram + unicode61) vs lean-ctx

Usage:
    python3 shootout.py --corpus /path/to/corpus [--out results/foo.md]
                        [--skip-leanctx] [--skip-codedb] [--iters N]

Measures, per backend:
    - cold-index wall time
    - on-disk index size
    - per-query p50/p99 warm latency
    - hit count (sanity / recall proxy)

Backend notes:
    codedb        — warm via MCP stdio (one server process, many calls)
    fts5_*        — warm via persistent SQLite connection (one process)
    lean-ctx grep — cold via CLI spawn per call (includes ~700ms binary
                    startup); lean-ctx uses a daemon under the hood for the
                    actual search work, but each `lean-ctx grep` invocation
                    still pays binary startup
"""

import argparse, json, os, re, select, shlex, shutil, sqlite3, subprocess, sys, time
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parent.parent
DEFAULT_CODEDB = shutil.which("codedb") or str(REPO_ROOT / "zig-out/bin/codedb")
DEFAULT_LEANCTX = shutil.which("lean-ctx")
DEFAULT_CODEGRAPH = shutil.which("codegraph")
QUERIES_PATH = HERE / "queries.json"
NL = chr(10)

INDEXABLE_EXTS = {
    ".js", ".jsx", ".ts", ".tsx", ".mjs", ".cjs",
    ".py", ".go", ".rs", ".c", ".h", ".cc", ".cpp", ".hpp", ".zig",
    ".md", ".json", ".css", ".scss", ".html", ".yaml", ".yml", ".toml",
}
SKIP_DIRS = {
    ".git", "node_modules", "dist", "build", ".next", "out",
    "zig-out", ".zig-cache", "__pycache__", "target", ".turbo",
    ".cache", "coverage",
}


def walk_corpus(root):
    for dirpath, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for f in files:
            if Path(f).suffix.lower() in INDEXABLE_EXTS:
                yield Path(dirpath) / f


# ---------------- FTS5 ----------------
def build_fts5(corpus, db_path, tokenizer):
    if db_path.exists():
        db_path.unlink()
    conn = sqlite3.connect(str(db_path))
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    conn.execute(
        "CREATE VIRTUAL TABLE files USING fts5(path, body, tokenize=" + repr(tokenizer) + ")"
    )
    start = time.perf_counter()
    n = 0
    batch = []
    with conn:
        for p in walk_corpus(corpus):
            try:
                body = p.read_text(errors="ignore")
            except Exception:
                continue
            batch.append((str(p.relative_to(corpus)), body))
            n += 1
            if len(batch) >= 200:
                conn.executemany("INSERT INTO files(path, body) VALUES (?, ?)", batch)
                batch.clear()
        if batch:
            conn.executemany("INSERT INTO files(path, body) VALUES (?, ?)", batch)
    elapsed = time.perf_counter() - start
    conn.close()
    return elapsed, n, db_path.stat().st_size


def fts5_match_expr(q):
    safe = q.replace('"', '""')
    return '"' + safe + '"'


def query_fts5(db_path, tokenizer, q, iters):
    conn = sqlite3.connect(str(db_path))
    cur = conn.cursor()
    match = fts5_match_expr(q)
    try:
        cur.execute("SELECT count(*) FROM files WHERE files MATCH ?", (match,))
        count = cur.fetchone()[0]
    except sqlite3.OperationalError:
        conn.close()
        return [], -1
    times = []
    for _ in range(iters):
        s = time.perf_counter()
        cur.execute("SELECT count(*) FROM files WHERE files MATCH ?", (match,))
        cur.fetchone()
        times.append((time.perf_counter() - s) * 1000.0)
    conn.close()
    return times, count


# ---------------- codedb ----------------
class CodedbMCP:
    def __init__(self, bin_path, root):
        # codedb argv order: [root] <command>
        self.proc = subprocess.Popen(
            [bin_path, root, "mcp"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, bufsize=0,
        )
        self.id = 0
        self.buf = b""
        self._init()

    def _send(self, obj):
        line = json.dumps(obj) + NL
        self.proc.stdin.write(line.encode())
        self.proc.stdin.flush()

    def _recv(self, timeout=60):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if select.select([self.proc.stdout], [], [], 0.1)[0]:
                chunk = os.read(self.proc.stdout.fileno(), 1 << 16)
                if chunk:
                    self.buf += chunk
            text = self.buf.decode(errors="replace")
            while NL in text:
                line, rest = text.split(NL, 1)
                line = line.strip()
                if not line:
                    text = rest
                    self.buf = rest.encode()
                    continue
                try:
                    obj = json.loads(line)
                    self.buf = rest.encode()
                    return obj
                except json.JSONDecodeError:
                    text = rest
                    self.buf = rest.encode()
                    continue
        return None

    def _init(self):
        self._send({
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {"protocolVersion": "2024-11-05", "capabilities": {},
                       "clientInfo": {"name": "shootout", "version": "1.0"}}
        })
        self._recv()
        self._send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        time.sleep(0.5)

    def call(self, tool, args):
        self.id += 1
        self._send({
            "jsonrpc": "2.0", "id": self.id, "method": "tools/call",
            "params": {"name": tool, "arguments": args}
        })
        return self._recv()

    def close(self):
        try:
            self.proc.terminate()
            self.proc.wait(timeout=5)
        except Exception:
            self.proc.kill()


class LeanCtxMCP:
    """MCP stdio client for lean-ctx — mirrors CodedbMCP. Lets us compare
    lean-ctx's actual search work without the per-call binary startup cost
    of `lean-ctx grep` invoked from a shell."""
    def __init__(self, bin_path, root):
        # lean-ctx (no args) starts MCP stdio. cwd=root so it picks the project.
        self.proc = subprocess.Popen(
            [bin_path],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, bufsize=0, cwd=root,
        )
        self.id = 0
        self.buf = b""
        self._init()

    def _send(self, obj):
        line = json.dumps(obj) + NL
        self.proc.stdin.write(line.encode())
        self.proc.stdin.flush()

    def _recv(self, timeout=60):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if select.select([self.proc.stdout], [], [], 0.1)[0]:
                chunk = os.read(self.proc.stdout.fileno(), 1 << 16)
                if chunk:
                    self.buf += chunk
            text = self.buf.decode(errors="replace")
            while NL in text:
                line, rest = text.split(NL, 1)
                line = line.strip()
                if not line:
                    text = rest
                    self.buf = rest.encode()
                    continue
                try:
                    obj = json.loads(line)
                    self.buf = rest.encode()
                    return obj
                except json.JSONDecodeError:
                    text = rest
                    self.buf = rest.encode()
                    continue
        return None

    def _init(self):
        self._send({
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {"protocolVersion": "2024-11-05", "capabilities": {},
                       "clientInfo": {"name": "shootout", "version": "1.0"}}
        })
        self._recv()
        self._send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        time.sleep(0.5)

    def call(self, tool, args):
        self.id += 1
        self._send({
            "jsonrpc": "2.0", "id": self.id, "method": "tools/call",
            "params": {"name": tool, "arguments": args}
        })
        return self._recv()

    def close(self):
        try:
            self.proc.terminate()
            self.proc.wait(timeout=5)
        except Exception:
            self.proc.kill()


def leanctx_count_results(resp):
    if not resp or "result" not in resp:
        return 0
    text = ""
    for item in resp["result"].get("content", []):
        if item.get("type") == "text":
            text += item["text"]
    m = re.search(r"(\d+)\s+matches\s+in\s+(\d+)\s+files", text)
    if m:
        return int(m.group(1))
    if "no matches" in text.lower() or text.strip() == "":
        return 0
    return sum(1 for ln in text.splitlines() if ":" in ln)


def query_leanctx_mcp(client, q, iters):
    resp = client.call("ctx_search", {"pattern": q})
    count = leanctx_count_results(resp)
    times = []
    for _ in range(iters):
        s = time.perf_counter()
        client.call("ctx_search", {"pattern": q})
        times.append((time.perf_counter() - s) * 1000.0)
    return times, count


def codedb_count_results(resp):
    if not resp or "result" not in resp:
        return 0
    text = ""
    for item in resp["result"].get("content", []):
        if item.get("type") == "text":
            text += item["text"]
    return sum(1 for ln in text.splitlines()
               if ln.startswith("  ") and ":" in ln)


def query_codedb(client, q, iters):
    resp = client.call("codedb_search", {"query": q})
    count = codedb_count_results(resp)
    times = []
    for _ in range(iters):
        s = time.perf_counter()
        client.call("codedb_search", {"query": q})
        times.append((time.perf_counter() - s) * 1000.0)
    return times, count


def codedb_clean(corpus):
    snapshots = Path.home() / ".codedb/projects"
    if not snapshots.exists():
        return
    for d in list(snapshots.iterdir()):
        if not d.is_dir():
            continue
        for f in d.iterdir():
            try:
                content = f.read_text(errors="ignore")
                if corpus in content:
                    shutil.rmtree(d)
                    break
            except Exception:
                continue


def codedb_cold_index(bin_path, corpus):
    snapshots = Path.home() / ".codedb/projects"
    pre = {p.name for p in snapshots.iterdir()} if snapshots.exists() else set()
    s = time.perf_counter()
    # codedb argv order: [root] <command>
    subprocess.run([bin_path, corpus, "tree"], capture_output=True)
    elapsed = time.perf_counter() - s
    post = {p.name for p in snapshots.iterdir()} if snapshots.exists() else set()
    new = post - pre
    snap_dir = None
    if new:
        snap_dir = snapshots / next(iter(new))
    else:
        if snapshots.exists():
            dirs = sorted((p for p in snapshots.iterdir() if p.is_dir()),
                          key=lambda p: p.stat().st_mtime, reverse=True)
            if dirs:
                snap_dir = dirs[0]
    size = 0
    if snap_dir and snap_dir.exists():
        size = sum(f.stat().st_size for f in snap_dir.rglob("*") if f.is_file())
    return elapsed, size, snap_dir


# ---------------- lean-ctx ----------------
def leanctx_cold_index(bin_path, corpus):
    """lean-ctx index build is async; kick it off then poll status until both
    bm25 and graph indexes report finished (or stay idle long enough that we
    can be confident no build is happening)."""
    # cwd=corpus is required — lean-ctx infers project root from cwd.
    s = time.perf_counter()
    subprocess.run([bin_path, "index", "build"], capture_output=True,
                   cwd=corpus, timeout=60)
    poll_deadline = time.perf_counter() + 600
    while time.perf_counter() < poll_deadline:
        r = subprocess.run([bin_path, "index", "status"],
                           capture_output=True, text=True, cwd=corpus, timeout=30)
        try:
            j = json.loads(r.stdout)
        except Exception:
            break
        states = (j.get("graph_index", {}).get("state"),
                  j.get("bm25_index", {}).get("state"))
        running = any(st in ("running", "indexing", "in_progress")
                      for st in states if st)
        finished = all(st in ("finished", "done", "ready")
                       for st in states if st)
        if finished and not running:
            break
        if not running and time.perf_counter() - s > 8:
            # Idle for 8s — assume nothing further is happening.
            break
        time.sleep(0.5)
    elapsed = time.perf_counter() - s
    candidates = [Path.home() / ".lean-ctx",
                  Path(corpus) / ".lean-ctx"]
    size = 0
    for c in candidates:
        if c.exists():
            size += sum(f.stat().st_size for f in c.rglob("*") if f.is_file())
    return elapsed, size, 0


def query_leanctx(bin_path, q, corpus, iters):
    r = subprocess.run([bin_path, "grep", q],
                       capture_output=True, cwd=corpus, timeout=60)
    text = r.stdout.decode(errors="replace")
    m = re.search(r"(\d+)\s+matches\s+in\s+(\d+)\s+files", text)
    if m:
        out_count = int(m.group(1))
    elif "no matches" in text.lower() or text.strip() == "":
        out_count = 0
    else:
        out_count = sum(1 for ln in text.splitlines() if ":" in ln)
    times = []
    for _ in range(iters):
        s = time.perf_counter()
        subprocess.run([bin_path, "grep", q],
                       capture_output=True, cwd=corpus, timeout=60)
        times.append((time.perf_counter() - s) * 1000.0)
    return times, out_count


# ---------------- codegraph ----------------
class CodegraphMCP:
    """Long-lived `codegraph serve --mcp` process — same shape as CodedbMCP/LeanCtxMCP."""
    def __init__(self, bin_path, root):
        self.proc = subprocess.Popen(
            [bin_path, "serve", "--mcp", "--path", root],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, bufsize=0,
        )
        self.id = 0
        self.buf = b""
        self._init()

    def _send(self, obj):
        line = json.dumps(obj) + NL
        self.proc.stdin.write(line.encode())
        self.proc.stdin.flush()

    def _recv(self, timeout=60):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if select.select([self.proc.stdout], [], [], 0.1)[0]:
                chunk = os.read(self.proc.stdout.fileno(), 1 << 16)
                if chunk:
                    self.buf += chunk
            text = self.buf.decode(errors="replace")
            while NL in text:
                line, rest = text.split(NL, 1)
                line = line.strip()
                if not line:
                    self.buf = rest.encode(); text = rest; continue
                try:
                    obj = json.loads(line)
                    self.buf = rest.encode()
                    return obj
                except json.JSONDecodeError:
                    self.buf = rest.encode(); text = rest; continue
        return None

    def _init(self):
        self._send({
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {"protocolVersion": "2024-11-05", "capabilities": {},
                       "clientInfo": {"name": "shootout", "version": "1.0"}}
        })
        self._recv()
        self._send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        time.sleep(0.5)

    def call(self, tool, args):
        self.id += 1
        self._send({
            "jsonrpc": "2.0", "id": self.id, "method": "tools/call",
            "params": {"name": tool, "arguments": args}
        })
        return self._recv()

    def close(self):
        try:
            self.proc.terminate()
            self.proc.wait(timeout=5)
        except Exception:
            self.proc.kill()


def codegraph_count_results(resp):
    if not resp or "result" not in resp:
        return 0
    text = ""
    for item in resp["result"].get("content", []):
        if item.get("type") == "text":
            text += item["text"]
    count = 0
    for ln in text.splitlines():
        s = ln.strip()
        if not s:
            continue
        if s.startswith("Found ") or s.startswith("No ") or s.startswith("#"):
            continue
        count += 1
    return count


def query_codegraph(client, q, iters):
    resp = client.call("codegraph_search", {"query": q, "limit": 50})
    count = codegraph_count_results(resp)
    times = []
    for _ in range(iters):
        s = time.perf_counter()
        client.call("codegraph_search", {"query": q, "limit": 50})
        times.append((time.perf_counter() - s) * 1000.0)
    return times, count


def codegraph_cold_index(bin_path, corpus):
    """`codegraph init` then `codegraph index` — wall-clock = full cold build."""
    cg_dir = Path(corpus) / ".codegraph"
    if cg_dir.exists():
        shutil.rmtree(cg_dir)
    s = time.perf_counter()
    subprocess.run([bin_path, "init", corpus], capture_output=True, timeout=60)
    subprocess.run([bin_path, "index", corpus], capture_output=True, timeout=600)
    elapsed = time.perf_counter() - s
    size = 0
    if cg_dir.exists():
        size = sum(f.stat().st_size for f in cg_dir.rglob("*") if f.is_file())
    return elapsed, size, cg_dir


# ---------------- stats / report ----------------
def pct(xs, p):
    if not xs:
        return 0.0
    xs = sorted(xs)
    k = (len(xs) - 1) * p
    f = int(k)
    c = min(f + 1, len(xs) - 1)
    return xs[f] + (xs[c] - xs[f]) * (k - f)


def stats(xs):
    """Return min/p50/p95/p99 for a list of samples. All in same unit (ms)."""
    if not xs:
        return {"min": 0.0, "p50": 0.0, "p95": 0.0, "p99": 0.0, "n": 0}
    return {
        "min": min(xs),
        "p50": pct(xs, 0.50),
        "p95": pct(xs, 0.95),
        "p99": pct(xs, 0.99),
        "n": len(xs),
    }


def median(xs):
    if not xs:
        return 0.0
    xs = sorted(xs)
    n = len(xs)
    return xs[n // 2] if n % 2 else (xs[n // 2 - 1] + xs[n // 2]) / 2.0


def merge_session_stats(per_session_stats):
    """Given a list of per-session stats dicts (min/p50/p95/p99), return
    median-of-medians for each percentile. Reduces single-session noise."""
    if not per_session_stats:
        return {"min": 0.0, "p50": 0.0, "p95": 0.0, "p99": 0.0, "sessions": 0}
    return {
        "min": median([s["min"] for s in per_session_stats]),
        "p50": median([s["p50"] for s in per_session_stats]),
        "p95": median([s["p95"] for s in per_session_stats]),
        "p99": median([s["p99"] for s in per_session_stats]),
        "sessions": len(per_session_stats),
    }


def write_report(out, ctx):
    lines = []
    lines.append("# search-shootout — " + ctx["corpus_name"])
    lines.append("")
    lines.append("**Date:** " + time.strftime("%Y-%m-%d %H:%M"))
    lines.append("**Corpus:** `" + ctx["corpus"] + "`")
    lines.append("**Indexed files:** " + "{:,}".format(ctx["file_count"]))
    lines.append("**Corpus bytes:** {:.1f} MB".format(ctx["corpus_bytes"] / 1e6))
    lines.append("**Iterations:** {} warm × {} sessions (median-of-medians)".format(ctx["iters"], ctx.get("sessions", 1)))
    lines.append("")
    lines.append("## Build phase")
    lines.append("")
    lines.append("| Backend | Cold index time | On-disk size |")
    lines.append("|---|---|---|")
    for label, t, sz in ctx["builds"]:
        t_str = "{:.2f}s".format(t) if t is not None else "skipped"
        sz_str = "{:.1f} MB".format(sz / 1e6) if sz else "—"
        lines.append("| {} | {} | {} |".format(label, t_str, sz_str))
    lines.append("")
    lines.append("## Query latency (warm, ms)")
    lines.append("")
    lines.append("> codedb: MCP stdio (one server, many calls).")
    lines.append("> fts5_*: persistent SQLite connection.")
    lines.append("> lean-ctx: per-call CLI spawn (includes ~700ms binary startup).")
    lines.append("> Hit counts are NOT directly comparable across backends — use them as recall sanity (zero vs non-zero).")
    lines.append("")
    cols = ctx["backends"]
    header_parts = ["query", "kind"]
    for b in cols:
        header_parts.extend([f"{b} min", f"{b} p50", f"{b} p95", f"{b} p99", f"{b} hits"])
    lines.append("| " + " | ".join(header_parts) + " |")
    lines.append("|" + "---|" * (2 + 5 * len(cols)))
    for row in ctx["rows"]:
        cells = ["`" + row["q"] + "`", row["kind"]]
        for b in cols:
            d = row["per_backend"].get(b, {})
            for k in ("min", "p50", "p95", "p99"):
                cells.append("{:.2f}".format(d[k]) if d.get(k) is not None else "—")
            cells.append(str(d["hits"]) if d.get("hits") is not None else "—")
        lines.append("| " + " | ".join(cells) + " |")
    lines.append("")

    # Files-list normalized comparison
    if ctx.get("files_list"):
        fl = ctx["files_list"]
        lines.append("## Normalized files-list comparison")
        lines.append("")
        lines.append("Each backend asked the same question: return the SET of files containing the query.")
        lines.append("`agree` is the pairwise Jaccard similarity (1.00 = all backends agree on the set).")
        lines.append("")
        bks = fl["backends"]
        header = ["query"] + [f"{b} files" for b in bks] + ["agree-jaccard"]
        lines.append("| " + " | ".join(header) + " |")
        lines.append("|" + "---|" * len(header))
        for r in fl["rows"]:
            cells = ["`" + r["q"] + "`"]
            for b in bks:
                cells.append(str(r["counts"].get(b, "—")))
            cells.append("{:.3f}".format(r["avg_jaccard"]))
            lines.append("| " + " | ".join(cells) + " |")
        lines.append("")

    out.write_text(NL.join(lines) + NL)


# ---------------- multi-session launcher ----------------
def run_multi_session(args):
    """Spawn args.sessions subprocesses that each run the bench once and
    dump per-query stats to JSON. Aggregate by median-of-medians."""
    import tempfile, copy
    tmp = Path(tempfile.mkdtemp(prefix="shootout-multisession-"))
    session_jsons = []
    print(f"[multi-session] running {args.sessions} sessions in subprocesses...", flush=True)
    for sid in range(1, args.sessions + 1):
        out_json = tmp / f"session-{sid}.json"
        cmd = [
            sys.executable, str(Path(__file__).resolve()),
            "--corpus", str(args.corpus),
            "--iters", str(args.iters),
            "--codedb-bin", args.codedb_bin,
            "--leanctx-bin", args.leanctx_bin,
            "--codegraph-bin", args.codegraph_bin,
            "--sessions", "1",
            "--session-id", str(sid),
            "--out", str(out_json),
        ]
        if args.skip_codedb: cmd.append("--skip-codedb")
        if args.skip_leanctx: cmd.append("--skip-leanctx")
        if args.skip_codegraph: cmd.append("--skip-codegraph")
        if args.skip_fts5: cmd.append("--skip-fts5")
        if args.clean_codedb and sid == 1: cmd.append("--clean-codedb")
        if args.clean_codegraph and sid == 1: cmd.append("--clean-codegraph")
        if args.normalize_files_list: cmd.append("--normalize-files-list")
        print(f"  session {sid}/{args.sessions} ...", flush=True)
        r = subprocess.run(cmd, capture_output=False)
        if r.returncode != 0:
            print(f"  session {sid} failed (exit {r.returncode})", file=sys.stderr)
            continue
        try:
            session_jsons.append(json.loads(out_json.read_text()))
        except Exception as e:
            print(f"  session {sid} json parse failed: {e}", file=sys.stderr)

    if not session_jsons:
        print("no sessions completed successfully", file=sys.stderr)
        sys.exit(1)

    # Aggregate: for each query, collect per-session stats and compute median-of-medians
    print()
    print(f"[aggregate] median-of-medians across {len(session_jsons)} sessions:")
    print()
    backends = session_jsons[0]["backends"]
    header_parts = ["query", "kind"]
    for b in backends:
        header_parts.extend([f"{b} min", f"{b} p50", f"{b} p95", f"{b} p99"])
    print("  " + " | ".join(header_parts))

    by_query = {}
    for sj in session_jsons:
        for row in sj["rows"]:
            q = row["q"]
            by_query.setdefault(q, {"kind": row["kind"], "per_backend": {}})
            for b in backends:
                by_query[q]["per_backend"].setdefault(b, [])
                if b in row["per_backend"]:
                    by_query[q]["per_backend"][b].append(row["per_backend"][b])

    agg_rows = []
    for q, qd in by_query.items():
        row = {"q": q, "kind": qd["kind"], "per_backend": {}}
        for b in backends:
            samples = qd["per_backend"][b]
            if samples:
                row["per_backend"][b] = merge_session_stats(samples)
                row["per_backend"][b]["hits"] = samples[0].get("hits", -1)
        agg_rows.append(row)
        cells = [f"{q[:24]:<24}"]
        for b in backends:
            d = row["per_backend"].get(b, {})
            cells.append(f"{d.get('min', 0):>5.2f}/{d.get('p50', 0):>5.2f}/{d.get('p95', 0):>6.2f}/{d.get('p99', 0):>6.2f}")
        print("  " + " | ".join(cells))

    # Write aggregated report if --out was given
    if args.out:
        ctx = {
            "corpus": str(Path(args.corpus).resolve()),
            "corpus_name": Path(args.corpus).resolve().name,
            "corpus_bytes": session_jsons[0]["corpus_bytes"],
            "file_count": session_jsons[0]["file_count"],
            "iters": args.iters,
            "sessions": len(session_jsons),
            "backends": backends,
            "builds": session_jsons[0]["builds"],
            "rows": agg_rows,
            "files_list": session_jsons[0].get("files_list"),
        }
        out_path = Path(args.out)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        write_report(out_path, ctx)
        print()
        print(f"report: {out_path}")


# ---------------- normalized files-list comparison ----------------
def normalize_codedb_files(bin_path, root, queries):
    """Ask codedb for the file SET containing each query. Uses `codedb word`
    which doesn't have the 50-result display cap that `codedb search` has,
    then dedupes hit paths."""
    out = {}
    for q in queries:
        r = subprocess.run([bin_path, root, "word", q],
                           capture_output=True, text=True, timeout=30,
                           env={**os.environ, "CODEDB_QUIET": "1"})
        paths = set()
        for ln in r.stdout.splitlines():
            ln = ln.strip()
            if ":" in ln and not ln.startswith("✓") and not ln.startswith("✗"):
                # format is "  path:line"; codedb word doesn't print headers in QUIET mode
                paths.add(ln.split(":")[0].strip())
        # word lookup only finds exact-token matches. For substring queries
        # (Fiber, Lane, Suspense) we also need search results. Run search with
        # high max_results as a fallback union to capture substring matches.
        r2 = subprocess.run([bin_path, root, "search", "--paths-only", q],
                            capture_output=True, text=True, timeout=30,
                            env={**os.environ, "CODEDB_QUIET": "1"})
        for ln in r2.stdout.splitlines():
            ln = ln.strip()
            if ":" in ln and not ln.startswith("✓") and not ln.startswith("✗"):
                paths.add(ln.split(":")[0].strip())
        out[q] = paths
    return out


def normalize_fts5_files(db_path, queries):
    """Return set of files per query (from FTS5 trigram)."""
    conn = sqlite3.connect(str(db_path))
    cur = conn.cursor()
    out = {}
    for q in queries:
        match = fts5_match_expr(q)
        try:
            cur.execute("SELECT path FROM files WHERE files MATCH ?", (match,))
            out[q] = {row[0] for row in cur.fetchall()}
        except sqlite3.OperationalError:
            out[q] = set()
    conn.close()
    return out


def normalize_leanctx_files(bin_path, root, queries):
    """Get the full files-list from lean-ctx. `lean-ctx grep` truncates
    display at ~20 lines, but `lean-ctx -c --raw "rg -l <q>"` returns the
    untruncated rg output (rg is lean-ctx's underlying engine)."""
    out = {}
    for q in queries:
        # Use lean-ctx in raw-passthrough mode to invoke rg directly. That
        # gives us the full files-with-matches list — same backend logic
        # lean-ctx's compressed grep uses, just without the display cap.
        r = subprocess.run([bin_path, "-c", "--raw", f"rg -l {shlex.quote(q)}"],
                           capture_output=True, text=True, cwd=root, timeout=60)
        paths = {ln.strip() for ln in r.stdout.splitlines() if ln.strip()}
        out[q] = paths
    return out


def jaccard(a, b):
    if not a and not b:
        return 1.0
    union = a | b
    if not union:
        return 1.0
    return len(a & b) / len(union)


def run_files_list_eval(corpus, codedb_bin, leanctx_bin, fts5_db,
                        fts5_uni_db, queries, skip_codedb, skip_leanctx, skip_fts5):
    """Ask every backend for the set of files containing each query, then
    compute pairwise jaccard similarity."""
    print()
    print("[files-list normalize] each backend returns set of files per query")
    sets = {}
    if not skip_codedb:
        print("  codedb...", flush=True)
        sets["codedb"] = normalize_codedb_files(codedb_bin, str(corpus), [q["q"] for q in queries])
    if not skip_fts5:
        print("  fts5_trigram...", flush=True)
        sets["fts5_tri"] = normalize_fts5_files(fts5_db, [q["q"] for q in queries])
        print("  fts5_unicode61...", flush=True)
        sets["fts5_uni"] = normalize_fts5_files(fts5_uni_db, [q["q"] for q in queries])
    if not skip_leanctx and leanctx_bin:
        print("  lean-ctx...", flush=True)
        sets["leanctx"] = normalize_leanctx_files(leanctx_bin, str(corpus), [q["q"] for q in queries])

    backends = list(sets.keys())
    rows = []
    print()
    print(f"  {'query':<30}" + "".join(f"{b:>14}" for b in backends) + "  agree-jaccard")
    for qd in queries:
        q = qd["q"]
        counts = {b: len(sets[b][q]) for b in backends}
        # Compute average pairwise jaccard
        js = []
        for i, b1 in enumerate(backends):
            for b2 in backends[i+1:]:
                js.append(jaccard(sets[b1][q], sets[b2][q]))
        avg_j = sum(js) / len(js) if js else 1.0
        line = f"  {q[:30]:<30}" + "".join(f"{counts[b]:>14}" for b in backends) + f"  {avg_j:>10.3f}"
        print(line)
        rows.append({"q": q, "counts": counts, "avg_jaccard": avg_j})
    return {"backends": backends, "rows": rows}


# ---------------- main ----------------
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--corpus", required=True)
    ap.add_argument("--out", default=None)
    ap.add_argument("--iters", type=int, default=500)
    ap.add_argument("--codedb-bin", default=str(DEFAULT_CODEDB))
    ap.add_argument("--leanctx-bin", default=DEFAULT_LEANCTX or "")
    ap.add_argument("--skip-codedb", action="store_true")
    ap.add_argument("--skip-leanctx", action="store_true")
    ap.add_argument("--leanctx-cli", action="store_true",
                    help="Use `lean-ctx grep` CLI (per-call spawn) instead of MCP stdio. "
                         "CLI is what scripts feel; MCP is what an agent feels.")
    ap.add_argument("--skip-fts5", action="store_true")
    ap.add_argument("--clean-codedb", action="store_true")
    ap.add_argument("--codegraph-bin", default=DEFAULT_CODEGRAPH or "")
    ap.add_argument("--skip-codegraph", action="store_true")
    ap.add_argument("--clean-codegraph", action="store_true",
                    help="Wipe matching .codegraph/ dir before indexing (forces cold build).")
    ap.add_argument("--sessions", type=int, default=1,
                    help="Run the bench N times in subprocesses; report median-of-medians per query. "
                         "Default 1 (single session). Use --sessions 3 for tighter p99 estimates.")
    ap.add_argument("--session-id", type=int, default=0,
                    help="Internal: this run is session N of M (set by the multi-session launcher).")
    ap.add_argument("--normalize-files-list", action="store_true",
                    help="Run an additional 'files-list' comparison where every backend is asked "
                         "the same question: 'return the set of files containing the query'. "
                         "Reports hit-set jaccard similarity between backends.")
    args = ap.parse_args()

    corpus = Path(args.corpus).resolve()
    if not corpus.exists():
        print("corpus path does not exist: " + str(corpus), file=sys.stderr)
        sys.exit(1)

    # Multi-session mode: spawn N subprocesses, each runs the bench once in
    # isolation. Aggregator collects per-session stats from temp JSON files
    # and reports median-of-medians.
    if args.sessions > 1 and args.session_id == 0:
        return run_multi_session(args)


    queries_doc = json.loads(QUERIES_PATH.read_text())
    queries = queries_doc["queries"]

    files = list(walk_corpus(corpus))
    total_bytes = sum(p.stat().st_size for p in files)
    print("corpus: " + str(corpus))
    print("  indexable files: {:,}, bytes: {:,}".format(len(files), total_bytes))
    print("  iterations per query: {}".format(args.iters))
    print()

    builds = []
    backends = []

    fts5_tri_db = None
    fts5_uni_db = None
    if not args.skip_fts5:
        bench_dir = Path("/tmp/codedb-bench")
        bench_dir.mkdir(exist_ok=True)
        fts5_tri_db = bench_dir / "fts5_trigram.db"
        fts5_uni_db = bench_dir / "fts5_unicode61.db"

        print("[build] fts5_trigram ...", flush=True)
        t, n, sz = build_fts5(corpus, fts5_tri_db, "trigram")
        print("        {:.2f}s, {} docs, {:.1f} MB".format(t, n, sz / 1e6))
        builds.append(("fts5_trigram", t, sz))
        backends.append("fts5_tri")

        print("[build] fts5_unicode61 ...", flush=True)
        t, n, sz = build_fts5(corpus, fts5_uni_db, "unicode61")
        print("        {:.2f}s, {} docs, {:.1f} MB".format(t, n, sz / 1e6))
        builds.append(("fts5_unicode61", t, sz))
        backends.append("fts5_uni")

    codedb_client = None
    if not args.skip_codedb:
        if args.clean_codedb:
            print("[build] codedb (cleaning matching snapshot first) ...", flush=True)
            codedb_clean(str(corpus))
        else:
            print("[build] codedb ...", flush=True)
        t, sz, snap_dir = codedb_cold_index(args.codedb_bin, str(corpus))
        print("        {:.2f}s, ~{:.1f} MB ({})".format(t, sz / 1e6, snap_dir))
        builds.append(("codedb", t, sz))
        backends.append("codedb")
        codedb_client = CodedbMCP(args.codedb_bin, str(corpus))
        # MCP roundtrip baseline: time a no-op tools/list call to measure
        # the floor cost of MCP stdio so we can attribute per-query latency.
        rt_times = []
        for _ in range(args.iters):
            s = time.perf_counter()
            codedb_client.id += 1
            codedb_client._send({"jsonrpc":"2.0","id":codedb_client.id,
                                 "method":"tools/list","params":{}})
            codedb_client._recv()
            rt_times.append((time.perf_counter() - s) * 1000.0)
        print("        mcp roundtrip baseline: p50={:.2f}ms p99={:.2f}ms".format(
            pct(rt_times, 0.5), pct(rt_times, 0.99)))

    leanctx_client = None
    if not args.skip_leanctx and args.leanctx_bin:
        print("[build] lean-ctx ...", flush=True)
        try:
            t, sz, rc = leanctx_cold_index(args.leanctx_bin, str(corpus))
            mode = "cli" if args.leanctx_cli else "mcp"
            print("        {:.2f}s, ~{:.1f} MB (query mode: {})".format(t, sz / 1e6, mode))
            builds.append(("lean-ctx", t, sz))
            backends.append("leanctx")
            if not args.leanctx_cli:
                leanctx_client = LeanCtxMCP(args.leanctx_bin, str(corpus))
        except subprocess.TimeoutExpired:
            print("        TIMED OUT")
            builds.append(("lean-ctx", None, None))
    elif not args.skip_leanctx:
        print("[build] lean-ctx: binary not found, skipping")

    codegraph_client = None
    if not args.skip_codegraph and args.codegraph_bin:
        print("[build] codegraph ...", flush=True)
        try:
            t, sz, cg_dir = codegraph_cold_index(args.codegraph_bin, str(corpus))
            print("        {:.2f}s, ~{:.1f} MB ({})".format(t, sz / 1e6, cg_dir))
            builds.append(("codegraph", t, sz))
            backends.append("codegraph")
            codegraph_client = CodegraphMCP(args.codegraph_bin, str(corpus))
        except subprocess.TimeoutExpired:
            print("        TIMED OUT")
            builds.append(("codegraph", None, None))
    elif not args.skip_codegraph:
        print("[build] codegraph: binary not found, skipping")

    print()
    print("[query]")
    print("  " + " | ".join(["query"] + [b + " min/p50/p95/p99 (hits)" for b in backends]))

    rows = []
    for qd in queries:
        q = qd["q"]
        kind = qd["kind"]
        per_backend = {}
        for b in backends:
            if b == "fts5_tri":
                times, count = query_fts5(fts5_tri_db, "trigram", q, args.iters)
            elif b == "fts5_uni":
                times, count = query_fts5(fts5_uni_db, "unicode61", q, args.iters)
            elif b == "codedb":
                times, count = query_codedb(codedb_client, q, args.iters)
            elif b == "leanctx":
                if leanctx_client is not None:
                    times, count = query_leanctx_mcp(leanctx_client, q, args.iters)
                else:
                    times, count = query_leanctx(args.leanctx_bin, q, str(corpus), args.iters)
            elif b == "codegraph":
                times, count = query_codegraph(codegraph_client, q, args.iters)
            else:
                continue
            s = stats(times)
            s["hits"] = count
            per_backend[b] = s
        rows.append({"q": q, "kind": kind, "per_backend": per_backend})
        cells = ["{:<24}".format(q[:24])]
        for b in backends:
            d = per_backend[b]
            cells.append("{:>5.2f}/{:>5.2f}/{:>6.2f}/{:>6.2f}ms ({:>4})".format(
                d["min"], d["p50"], d["p95"], d["p99"], d["hits"]))
        print("  " + " | ".join(cells))

    if codedb_client:
        codedb_client.close()
    if leanctx_client:
        leanctx_client.close()
    if codegraph_client:
        codegraph_client.close()

    files_list_result = None
    if args.normalize_files_list:
        files_list_result = run_files_list_eval(
            corpus, args.codedb_bin, args.leanctx_bin,
            fts5_tri_db, fts5_uni_db,
            queries, args.skip_codedb, args.skip_leanctx, args.skip_fts5,
        )

    if args.out:
        ctx = {
            "corpus": str(corpus),
            "corpus_name": corpus.name,
            "corpus_bytes": total_bytes,
            "file_count": len(files),
            "iters": args.iters,
            "backends": backends,
            "builds": builds,
            "rows": rows,
            "files_list": files_list_result,
        }
        out_path = Path(args.out)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        if args.session_id > 0:
            # Subprocess mode: emit JSON for the launcher to aggregate
            out_path.write_text(json.dumps(ctx, default=lambda o: list(o) if isinstance(o, set) else None))
        else:
            write_report(out_path, ctx)
        print()
        print("report: " + str(out_path))


if __name__ == "__main__":
    main()
