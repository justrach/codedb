#!/usr/bin/env python3
"""Mine ~100k (task, chunk) pairs via graff+Kimi, then delete cloned repos.

Kimi (logged-in `kimi-for-coding`) only writes symbol-free tasks in batches.
codedb supplies gold spans + BM25 near-misses. Clones live under
/tmp/embed-mine and are removed after each repo unless keep=true.
"""
from __future__ import annotations

import argparse
import json
import os
import random
import re
import shutil
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BIN = Path(os.environ.get("CODEDB_BIN", ROOT / "zig-out" / "bin" / "codedb"))
EMPTY_MCP = ROOT / "experiments" / "openclaw-graff" / "empty-mcp.json"
MINE_ROOT = Path("/tmp/embed-mine")
FILE_RE = re.compile(r"^-\s+(\S+)\s+\(", re.M)
EXPORT_RES = [
    re.compile(r"^export\s+(?:async\s+)?function\s+(\w+)", re.M),
    re.compile(r"^export\s+(?:async\s+)?const\s+(\w+)\s*=", re.M),
    re.compile(r"^export\s+(?:async\s+)?function\s+(\w+)", re.M),
    re.compile(r"^pub\s+(?:async\s+)?fn\s+(\w+)", re.M),
    re.compile(r"^fn\s+(\w+)\s*\(", re.M),
    re.compile(r"^func\s+(\w+)\s*\(", re.M),
    re.compile(r"^(?:async\s+)?def\s+(\w+)\s*\(", re.M),
    re.compile(r"^[A-Za-z_][\w\s\*]*\b(\w+)\s*\([^;]*\)\s*\{", re.M),
]
SKIP_DIR = {
    ".git", "node_modules", "dist", "build", "zig-cache", "vendor", ".venv",
    "target", "__pycache__", ".codedb", "fixtures", "__mocks__",
}
SKIP_FILE_RE = re.compile(r"\.(test|spec|min)\.|__tests__|\.d\.ts$")
SOURCE_EXT = {
    ".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".zig", ".rs", ".go",
    ".py", ".c", ".h", ".cc", ".cpp", ".java", ".kt", ".swift",
}

REPOS = [
    {"name": "openclaw", "path": "/tmp/openclaw-hillclimb", "keep": True, "max_golds": 3200},
    {"name": "react", "path": "/tmp/react-hillclimb", "keep": True, "max_golds": 1400},
    {"name": "express", "url": "https://github.com/expressjs/express", "max_golds": 400},
    {"name": "flask", "url": "https://github.com/pallets/flask", "max_golds": 400},
    {"name": "clap", "url": "https://github.com/clap-rs/clap", "max_golds": 500},
    {"name": "chi", "url": "https://github.com/go-chi/chi", "max_golds": 300},
    {"name": "preact", "url": "https://github.com/preactjs/preact", "max_golds": 400},
    {"name": "fastapi", "url": "https://github.com/fastapi/fastapi", "max_golds": 500},
    {"name": "ripgrep", "url": "https://github.com/BurntSushi/ripgrep", "max_golds": 400},
    {"name": "esbuild", "url": "https://github.com/evanw/esbuild", "max_golds": 500},
    {"name": "svelte", "url": "https://github.com/sveltejs/svelte", "max_golds": 600},
    {"name": "cobra", "url": "https://github.com/spf13/cobra", "max_golds": 300},
    {"name": "uvicorn", "url": "https://github.com/encode/uvicorn", "max_golds": 300},
    {"name": "axum", "url": "https://github.com/tokio-rs/axum", "max_golds": 500},
    {"name": "nextjs", "url": "https://github.com/vercel/next.js", "keep": True, "max_golds": 80},
]


def env() -> dict[str, str]:
    e = os.environ.copy()
    e.update({
        "CODEDB_ALLOW_TEMP": "1",
        "CODEDB_NO_TELEMETRY": "1",
        "CODEDB_NO_CLI_DAEMON": "1",
        "CODEDB_NO_SEARCH_CACHE": "1",
        "CODEDB_CONTEXT_MAX_CANDIDATES": "9",
        "CODEDB_CONTEXT_DEMOTE_TESTS": "1",
        "CODEDB_CONTEXT_TOP_FILES": "9",
        "GRAFF_NO_TELEMETRY": "1",
        "GRAFF_FLEET": "off",
        "GRAFF_LEARN_AUTO": "off",
        "GRAFF_MCP_CONFIG": str(EMPTY_MCP),
        "PATH": str(BIN.parent) + os.pathsep + e.get("PATH", ""),
        "CODEDB_BIN": str(BIN),
    })
    return e


def run(cmd: list[str], cwd: Path | None = None, timeout: int = 120) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd, cwd=cwd, env=env(), text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout,
    )


def ensure_repo(spec: dict) -> Path:
    if spec.get("path"):
        p = Path(spec["path"])
        if not p.is_dir():
            raise FileNotFoundError(p)
        return p
    dest = MINE_ROOT / spec["name"]
    if dest.is_dir() and (dest / ".git").exists():
        return dest
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists():
        shutil.rmtree(dest)
    print(f"  clone {spec['url']} -> {dest}", flush=True)
    proc = run(["git", "clone", "--depth", "1", "--single-branch", spec["url"], str(dest)], timeout=180)
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr[-400:])
    return dest


def iter_source(corpus: Path) -> list[Path]:
    out = []
    for dirpath, dirnames, filenames in os.walk(corpus):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIR and not d.startswith(".")]
        for name in filenames:
            p = Path(dirpath) / name
            if p.suffix not in SOURCE_EXT:
                continue
            rel = str(p.relative_to(corpus))
            if SKIP_FILE_RE.search(rel):
                continue
            out.append(p)
    return out


def first_export(text: str) -> tuple[str, int] | None:
    best: tuple[str, int] | None = None
    for rx in EXPORT_RES:
        m = rx.search(text)
        if not m:
            continue
        line = text.count("\n", 0, m.start()) + 1
        if best is None or line < best[1]:
            best = (m.group(1), line)
    return best


def snippet(text: str, line: int, radius: int = 12) -> str:
    lines = text.splitlines()
    i = max(line - 1, 0)
    start, end = max(i - radius, 0), min(i + radius + 1, len(lines))
    return "\n".join(lines[start:end]), start + 1, end


def collect_golds(corpus: Path, limit: int, rng: random.Random) -> list[dict]:
    files = iter_source(corpus)
    rng.shuffle(files)
    golds = []
    for path in files:
        if len(golds) >= limit:
            break
        try:
            text = path.read_text(errors="replace")
        except OSError:
            continue
        if len(text) < 80 or len(text) > 200_000:
            continue
        hit = first_export(text)
        if not hit:
            continue
        name, line = hit
        if name in {"main", "init", "test", "describe", "it"} or len(name) < 3:
            continue
        body, a, b = snippet(text, line)
        rel = str(path.relative_to(corpus))
        redacted = re.sub(rf"\b{re.escape(name)}\b", "ITEM", body)
        golds.append({
            "path": rel,
            "line": line,
            "symbol": name,
            "span": f"{a}-{b}",
            "text": f"{rel}\t{a}-{b}\n{body}",
            "redacted": redacted[:600],
        })
    return golds


def fallback_task(g: dict) -> str:
    blob = re.sub(r"\bITEM\b", "", g["redacted"])
    words = [w.lower() for w in re.findall(r"[A-Za-z]{4,}", blob)]
    stop = {
        "this", "that", "from", "with", "return", "export", "function", "const",
        "async", "await", "import", "type", "string", "number", "undefined",
        "boolean", "class", "public", "private", "static",
    }
    topic = " ".join(w for w in words if w not in stop)[:90].strip()
    return (
        f"Where is the code that handles {topic or 'this behavior'} implemented? "
        f"Reply with only path:line."
    )

def parse_json_array(raw: str) -> list[dict]:
    s = raw.strip()
    if s.startswith("```"):
        s = re.sub(r"^```(?:json)?\s*", "", s)
        s = re.sub(r"\s*```$", "", s)
    start, end = s.find("["), s.rfind("]")
    if start < 0 or end < 0:
        raise ValueError("no json array")
    data = json.loads(s[start : end + 1])
    if not isinstance(data, list):
        raise ValueError("not a list")
    return data


def graff_tasks(batch: list[dict], model: str) -> list[str]:
    payload = [{"id": str(i), "lang_hint": g["path"], "chunk": g["redacted"]} for i, g in enumerate(batch)]
    prompt = (
        "Write one symbol-free locate-the-code task per item.\n"
        "Do not mention identifier names, file names, or line numbers.\n"
        "Ask where the behavior is implemented. Reply with only a JSON array of "
        "{\"id\": \"<same id>\", \"task\": \"...\"}.\n\n"
        + json.dumps(payload, ensure_ascii=False)
    )
    cwd = Path("/tmp/graff-empty")
    cwd.mkdir(exist_ok=True)
    (cwd / ".mcp.json").write_text('{"mcpServers":{}}\n')
    argv = ["graff", "-p", "--yolo", "--no-telemetry", "--no-resume", "--max-model-calls", "1"]
    if model:
        argv.extend(["--model", model])
    argv.append(prompt)
    last_err = ""
    by_id: dict[str, str] = {}
    for attempt in range(3):
        proc = run(argv, cwd=cwd, timeout=90)
        if proc.returncode == 0:
            try:
                by_id = {
                    str(x.get("id")): x.get("task", "")
                    for x in parse_json_array(proc.stdout) if isinstance(x, dict)
                }
                break
            except (ValueError, json.JSONDecodeError) as e:
                last_err = str(e)
        else:
            last_err = (proc.stderr or proc.stdout)[-200:]
        time.sleep(1.5 * (attempt + 1))
    if not by_id and last_err:
        print(f"   graff retry exhausted: {last_err[:120]}", flush=True)
    tasks = []
    for i, g in enumerate(batch):
        task = (by_id.get(str(i)) or "").strip()
        if not task or g["symbol"].lower() in task.lower() or Path(g["path"]).name.lower() in task.lower():
            task = fallback_task(g)
        tasks.append(task)
    return tasks


def context_files(corpus: Path, task: str) -> list[str]:
    proc = run([str(BIN), str(corpus), "context", task], timeout=60)
    section = proc.stdout.split("## Most-relevant files", 1)
    if len(section) < 2:
        return []
    return FILE_RE.findall(section[1].split("## ", 1)[0])


def file_head(corpus: Path, rel: str) -> str:
    path = corpus / rel
    if not path.is_file():
        return ""
    try:
        lines = path.read_text(errors="replace").splitlines()[:40]
    except OSError:
        return ""
    return f"{rel}\t1-{len(lines)}\n" + "\n".join(lines)


def pairs_for(suite: str, corpus: Path, gold: dict, task: str) -> list[dict]:
    ranked = context_files(corpus, task)
    rows = [{
        "k": task,
        "v": gold["text"],
        "label": 3,
        "path": gold["path"],
        "line": gold["line"],
        "kind": "gold",
        "suite": suite,
        "symbol": gold["symbol"],
    }]
    for i, f in enumerate(ranked, 1):
        if f == gold["path"] or f.endswith("/" + gold["path"]):
            continue
        rows.append({
            "k": task,
            "v": file_head(corpus, f),
            "label": 0,
            "path": f,
            "rank": i,
            "kind": "bm25-near-miss",
            "suite": suite,
        })
    return rows


def mine_repo(spec: dict, out: Path, model: str, batch_size: int, graff_workers: int, ctx_workers: int, target_left: int) -> int:
    name = spec["name"]
    corpus = ensure_repo(spec)
    print(f"-- {name} {corpus}", flush=True)
    run([str(BIN), str(corpus), "status"], timeout=900)
    rng = random.Random(11 + len(name))
    golds = collect_golds(corpus, min(spec.get("max_golds", 400), max(target_left, 1)), rng)
    print(f"   golds={len(golds)}", flush=True)
    tasks = [""] * len(golds)
    if spec.get("no_graff"):
        for i, g in enumerate(golds):
            tasks[i] = fallback_task(g)
        print(f"   fallback tasks={len(tasks)}", flush=True)
    else:
        batches = [golds[i : i + batch_size] for i in range(0, len(golds), batch_size)]
        offsets = list(range(0, len(golds), batch_size))

        def write_batch(bi: int) -> tuple[int, list[str]]:
            return bi, graff_tasks(batches[bi], model)

        with ThreadPoolExecutor(max_workers=graff_workers) as pool:
            futs = [pool.submit(write_batch, i) for i in range(len(batches))]
            for n, fut in enumerate(as_completed(futs), 1):
                try:
                    bi, ts = fut.result()
                    for j, t in enumerate(ts):
                        tasks[offsets[bi] + j] = t
                except Exception as e:
                    print(f"   graff batch fail: {type(e).__name__}: {e}", flush=True)
                if n % 5 == 0 or n == len(batches):
                    print(f"   kimi {n}/{len(batches)}", flush=True)

    wrote = 0
    with ThreadPoolExecutor(max_workers=ctx_workers) as pool:
        futs = {
            pool.submit(pairs_for, name, corpus, g, t or f"Where is this {name} behavior implemented?"): i
            for i, (g, t) in enumerate(zip(golds, tasks))
        }
        with out.open("a") as fh:
            for n, fut in enumerate(as_completed(futs), 1):
                try:
                    rows = fut.result()
                except Exception:
                    continue
                for row in rows:
                    fh.write(json.dumps(row, ensure_ascii=False) + "\n")
                    wrote += 1
                if n % 50 == 0 or n == len(futs):
                    print(f"   ctx {n}/{len(futs)} kv+={wrote}", flush=True)
    if not spec.get("keep"):
        print(f"   delete {corpus}", flush=True)
        shutil.rmtree(corpus, ignore_errors=True)
    return wrote


def count_lines(path: Path) -> int:
    if not path.exists():
        return 0
    return sum(1 for _ in path.open())


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", type=Path, default=Path(__file__).with_name("kv.100k.jsonl"))
    ap.add_argument("--target", type=int, default=100_000)
    ap.add_argument("--model", default=os.environ.get("GRAFF_MODEL", ""), help="empty = inherit graff saved seating (codegraff/kimi-k3)")
    ap.add_argument("--batch", type=int, default=8)
    ap.add_argument("--graff-workers", type=int, default=4)
    ap.add_argument("--ctx-workers", type=int, default=10)
    ap.add_argument("--repos", nargs="*", default=[r["name"] for r in REPOS])
    ap.add_argument("--max-golds", type=int, default=0, help="cap golds per repo (0 = spec default)")
    ap.add_argument("--reset", action="store_true")
    ap.add_argument("--no-graff", action="store_true", help="use heuristic tasks; skip Kimi")
    ap.add_argument("--keep-root", action="store_true", help="do not delete /tmp/embed-mine")
    args = ap.parse_args()
    if args.reset and args.out.exists():
        args.out.unlink()
    have = count_lines(args.out)
    print(f"start have={have} target={args.target} model={args.model}", flush=True)
    by_name = {r["name"]: r for r in REPOS}
    for name in args.repos:
        have = count_lines(args.out)
        if have >= args.target:
            break
        spec = dict(by_name[name])
        if args.max_golds:
            spec["max_golds"] = args.max_golds
        if args.no_graff:
            spec["no_graff"] = True
        n = mine_repo(spec, args.out, args.model, args.batch, args.graff_workers, args.ctx_workers, args.target - have)
        print(f"== {name} wrote {n} total={count_lines(args.out)}", flush=True)
    if MINE_ROOT.exists() and not args.keep_root:
        shutil.rmtree(MINE_ROOT, ignore_errors=True)
        print(f"deleted {MINE_ROOT}", flush=True)
    print(f"done {args.out} pairs={count_lines(args.out)}")


if __name__ == "__main__":
    main()
