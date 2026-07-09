#!/usr/bin/env python3
"""Pinned def-first ranking eval for codedb_search.

Measures, for a set of symbol-shaped queries, whether the file that actually
DEFINES the symbol ranks at the top of `codedb_search` results. Used to validate
ranking changes (e.g. the def-first boost, PR #665) with a clean A/B.

Why "pinned": codedb indexes the current project and persists a snapshot under
`$HOME/.codedb`. If you eval against the codedb repo itself, editing the ranking
code re-indexes the corpus mid-measurement, so scores drift even with the code
reverted (this sank the first def-first attempt: an apparent 8->7 that was pure
noise). This harness removes the confound:

  * FROZEN corpus  — copied OUT of the repo, never edited, so the index is stable.
  * ISOLATED $HOME — a throwaway dir, wiped per binary, so each build re-indexes
                     the identical bytes from scratch. Only the *binary* differs.

Result: deterministic, so a delta is attributable to the code, not the corpus.

Usage:
    # freeze a corpus from the repo and eval one binary
    python3 scripts/rank-eval.py --binary zig-out/bin/codedb

    # A/B two builds against the SAME frozen corpus
    python3 scripts/rank-eval.py --binary /tmp/codedb.baseline --corpus /tmp/frozen
    python3 scripts/rank-eval.py --binary /tmp/codedb.head     --corpus /tmp/frozen

    # custom gold cases: a JSON list of [query, expected_def_file] pairs
    python3 scripts/rank-eval.py --binary zig-out/bin/codedb --cases mycases.json

Notes:
  * A Debug build is fine — result ORDER is version-independent; only indexing is
    slower. Build once with `zig build` and point --binary at zig-out/bin/codedb.
  * The corpus lands under a temp dir, so CODEDB_ALLOW_TEMP=1 is set for the child
    (codedb refuses to index temp roots by default).
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

# Gold cases: (query, file that defines the symbol). Chosen so several def files
# have a basename that does NOT match the query — the case plain hit-count +
# basename ranking gets wrong, which is exactly what def-first should fix.
DEFAULT_CASES = [
    ("searchContentRanked", "src/explore.zig"),
    ("handleSearch", "src/mcp.zig"),
    ("fileDefinesSymbol", "src/explore.zig"),
    ("renderPlainSearch", "src/explore.zig"),
    ("bumpSearchGen", "src/explore.zig"),
    ("appendMatchLine", "src/mcp.zig"),
    ("centralityBoost", "src/explore.zig"),
    ("rerankAndFinalize", "src/explore.zig"),
    ("ConvergenceGovernor", "src/mcp.zig"),
    ("trimMatchText", "src/mcp.zig"),
]

INIT = ('{"jsonrpc":"2.0","id":0,"method":"initialize","params":'
        '{"protocolVersion":"2024-11-05","capabilities":{},'
        '"clientInfo":{"name":"rank-eval","version":"1"}}}')

# Matches a rendered result line "  <path>:<line>: <text>" (or paths_only form).
_RESULT_RE = re.compile(r"\s*([\w./-]+\.\w+):(\d+):")


def freeze_corpus(repo: Path, dest: Path) -> None:
    """Copy a representative slice of the repo (code + docs + tests) into dest."""
    dest.mkdir(parents=True, exist_ok=True)
    shutil.copytree(repo / "src", dest / "src", dirs_exist_ok=True)
    for extra in ("CHANGELOG.md",):
        src = repo / extra
        if src.exists():
            shutil.copy(src, dest / extra)
    exp = repo / "experiments"
    if exp.exists():
        shutil.copytree(exp, dest / "experiments", dirs_exist_ok=True)


def child_env(home: Path) -> dict:
    env = dict(os.environ)
    env.update({
        "HOME": str(home),            # isolate ~/.codedb so it's per-binary
        "CODEDB_NO_CLI_DAEMON": "1",  # no shared warm daemon — each run is self-contained
        "CODEDB_MCP_LEAN": "1",       # assistant block only; drop the user-audience blocks
        "CODEDB_ALLOW_TEMP": "1",     # the corpus lives under a temp dir
    })
    return env


def prewarm(binary: str, corpus: Path, env: dict) -> None:
    """Build + persist the snapshot once so per-query MCP loads are fast/ready."""
    subprocess.run(["bash", "-c", f"cd {corpus} && {binary} . index"],
                   capture_output=True, text=True, env=env, timeout=180)


def search(binary: str, corpus: Path, env: dict, query: str, max_results: int = 10) -> list:
    """Return the ordered list of result file paths for one codedb_search query.

    The init and the tools/call are SPACED in the pipe: the MCP server loads the
    snapshot asynchronously, so a query fired immediately hits `loading_snapshot`
    and returns 0 results. `sleep 6` between them lets the load finish.
    """
    req = ('{"jsonrpc":"2.0","id":1,"method":"tools/call","params":'
           '{"name":"codedb_search","arguments":{"query":"%s","max_results":%d}}}'
           % (query, max_results))
    script = (f"cd {corpus} && "
              f"{{ printf '%s\\n' {json.dumps(INIT)}; sleep 6; "
              f"printf '%s\\n' {json.dumps(req)}; sleep 2; }} | {binary} mcp 2>/dev/null")
    proc = subprocess.run(["bash", "-c", script], capture_output=True, text=True,
                          env=env, timeout=90)
    hits = []
    for line in proc.stdout.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        if obj.get("id") == 1 and "result" in obj:
            for block in obj["result"]["content"]:
                for tl in block["text"].splitlines():
                    m = _RESULT_RE.match(tl)
                    if m:
                        hits.append(m.group(1))
    return hits


def main() -> int:
    repo = Path(__file__).resolve().parent.parent
    ap = argparse.ArgumentParser(description="Pinned def-first ranking eval for codedb_search.")
    ap.add_argument("--binary", default=str(repo / "zig-out/bin/codedb"),
                    help="codedb binary to eval (default: zig-out/bin/codedb)")
    ap.add_argument("--corpus", default=None,
                    help="frozen corpus dir; if omitted, one is created from the repo under a temp dir")
    ap.add_argument("--cases", default=None,
                    help="JSON file: list of [query, expected_def_file] pairs (default: built-in set)")
    ap.add_argument("--keep", action="store_true", help="keep the temp corpus/home dirs")
    args = ap.parse_args()

    binary = str(Path(args.binary).resolve())
    if not Path(binary).exists():
        print(f"binary not found: {binary} (run `zig build` first)", file=sys.stderr)
        return 2

    cases = DEFAULT_CASES
    if args.cases:
        cases = [tuple(x) for x in json.loads(Path(args.cases).read_text())]

    workdir = Path(tempfile.mkdtemp(prefix="codedb-rankeval-"))
    corpus = Path(args.corpus).resolve() if args.corpus else (workdir / "corpus")
    home = workdir / "home"
    home.mkdir(parents=True, exist_ok=True)
    if not args.corpus:
        freeze_corpus(repo, corpus)

    env = child_env(home)
    # Fresh index for THIS binary: wipe the isolated ~/.codedb, then re-index the
    # (identical) frozen corpus so the only variable across A/B is the binary.
    shutil.rmtree(home / ".codedb", ignore_errors=True)
    prewarm(binary, corpus, env)

    n = len(cases)
    def_1 = top3 = 0
    print(f"corpus={corpus}  binary={binary}")
    for query, expect in cases:
        paths = search(binary, corpus, env, query)
        is1 = paths[:1] == [expect]
        is3 = expect in paths[:3]
        def_1 += is1
        top3 += is3
        pos = paths.index(expect) + 1 if expect in paths else 0
        verdict = "#1" if is1 else ("top3" if is3 else "MISS")
        print(f"  {query:<22} def={expect:<16} first={paths[0] if paths else '-':<20} "
              f"pos={pos or 'MISS':<5} {verdict}")
    print(f"SCORE: def-file-#1 {def_1}/{n} | def-file-top3 {top3}/{n}")

    if not args.keep and not args.corpus:
        shutil.rmtree(workdir, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
