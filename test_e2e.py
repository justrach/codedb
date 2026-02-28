#!/usr/bin/env python3
"""End-to-end test for all 17 gitagent-mcp tools."""
import json, os, subprocess, sys
from pathlib import Path

BINARY = "/Users/rachpradhan/codedb/zig-out/bin/gitagent-mcp"
REPO   = "/Users/rachpradhan/codedb"

class MCP:
    def __init__(self):
        env = {**os.environ, "REPO_PATH": REPO}
        self.proc = subprocess.Popen(
            [BINARY], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, env=env,
        )
        self._n = 0
        self._send({"id": 0, "method": "initialize", "params": {
            "protocolVersion": "2025-03-26", "capabilities": {},
            "clientInfo": {"name": "test", "version": "1"},
        }})
        self._recv()

    def _send(self, obj):
        obj["jsonrpc"] = "2.0"
        self.proc.stdin.write((json.dumps(obj) + "\n").encode())
        self.proc.stdin.flush()

    def _recv(self):
        line = self.proc.stdout.readline()
        if not line: raise RuntimeError("MCP server closed")
        return json.loads(line)

    def call(self, tool, **kwargs):
        self._n += 1
        self._send({"id": self._n, "method": "tools/call",
                    "params": {"name": tool, "arguments": kwargs}})
        resp = self._recv()
        if "error" in resp:
            return {"error": resp["error"].get("message", str(resp["error"]))}
        text = resp["result"]["content"][0]["text"]
        try: return json.loads(text)
        except: return {"error": f"non-JSON: {text[:200]}"}

    def close(self):
        self.proc.stdin.close(); self.proc.wait(timeout=5)

PASSED = []; FAILED = []

def ok(name, detail=""):
    print(f"  \033[32mv\033[0m {name}" + (f"  \033[2m{detail}\033[0m" if detail else ""))
    PASSED.append(name)

def fail(name, reason):
    print(f"  \033[31mx\033[0m {name}  \033[31m{reason}\033[0m")
    FAILED.append(name)

def check(name, result, detail="", **expects):
    if result is None: fail(name, "returned None"); return result
    if isinstance(result, dict) and "error" in result:
        fail(name, result["error"]); return result
    for field, validator in expects.items():
        val = result.get(field) if isinstance(result, dict) else result
        try:
            if callable(validator): assert validator(val), f"{field}={val!r} failed"
            else: assert val == validator, f"{field}: expected {validator!r}, got {val!r}"
        except AssertionError as e:
            fail(name, str(e)); return result
    ok(name, detail); return result

def run():
    s = MCP()
    alpha = beta = gamma = None
    branch_name = None; pr_num = None; orig_branch = "main"

    try:
        print("\n[1/5] Read-only tools")

        r = s.call("get_project_state")
        check("get_project_state", r,
              detail=f"{len(r.get('issues',[]))} issues, {len(r.get('open_prs',[]))} PRs",
              issues=lambda x: isinstance(x, list) and len(x) > 0)

        r = s.call("get_next_task")
        if r and isinstance(r, dict) and "number" in r:
            ok("get_next_task", f"#{r['number']} {str(r.get('title',''))[:40]}")
        elif r is None or r == "null":
            ok("get_next_task", "no tasks")
        else:
            fail("get_next_task", str(r))

        r = s.call("get_current_branch")
        orig_branch = r.get("branch", "main") if isinstance(r, dict) else "main"
        check("get_current_branch", r, detail=f"{r.get('branch')}",
              branch=lambda x: isinstance(x, str) and len(x) > 0)

        r = s.call("decompose_feature", feature_description="add full-text search")
        check("decompose_feature", r,
              detail=f"{len(r.get('available_labels',[]))} labels",
              available_labels=lambda x: isinstance(x, list) and len(x) > 0,
              instructions=lambda x: isinstance(x, str))

        print("\n[2/5] Issue management")

        r = s.call("create_issue", title="[TEST] MCP e2e alpha",
                   body="E2E test.", labels=["type:infra"])
        r = check("create_issue", r,
                  detail=f"#{r.get('number')} {r.get('url','')}" if isinstance(r,dict) else "",
                  number=lambda x: x and x > 0)
        if r and "number" in r: alpha = r["number"]

        r = s.call("create_issues_batch", issues=[
            {"title":"[TEST] MCP e2e batch-beta",  "body":"batch 1","labels":["type:infra"]},
            {"title":"[TEST] MCP e2e batch-gamma","body":"batch 2","labels":["type:infra"]},
        ])
        if isinstance(r, list) and len(r)==2 and all(isinstance(i,dict) and i.get("number",0)>0 for i in r):
            beta=r[0]["number"]; gamma=r[1]["number"]
            ok("create_issues_batch", f"#{beta}, #{gamma}")
        else:
            fail("create_issues_batch", f"unexpected: {r}"); beta=gamma=None

        if alpha:
            r = s.call("update_issue", issue_number=alpha,
                       title="[TEST] MCP e2e alpha (updated)", add_labels=["priority:p2"])
            check("update_issue", r, detail=f"#{alpha}", updated=lambda x: x==alpha)

        if alpha and beta and gamma:
            r = s.call("prioritize_issues", issue_numbers=[gamma, beta, alpha])
            check("prioritize_issues", r, detail=str(r.get("prioritized",[])),
                  prioritized=lambda x: isinstance(x,list) and len(x)==3)

        if alpha and beta:
            r = s.call("link_issues", issue_number=alpha, blocks=[beta])
            linked = r.get("linked",[]) if isinstance(r,dict) else []
            if str(beta) in [str(x) for x in linked] or beta in linked:
                ok("link_issues", f"#{alpha} blocks #{beta}")
            else:
                fail("link_issues", f"#{beta} not in {linked}")

        if gamma:
            r = s.call("close_issue", issue_number=gamma)
            check("close_issue", r, detail=f"#{gamma}", closed=lambda x: x==gamma)

        print("\n[3/5] Branch & commit workflow")

        if alpha:
            r = s.call("create_branch", issue_number=alpha, branch_type="fix")
            r = check("create_branch", r,
                      detail=r.get("branch","") if isinstance(r,dict) else "",
                      branch=lambda x: f"fix/{alpha}-" in (x or ""))
            if r and "branch" in r: branch_name = r["branch"]

        if branch_name:
            r = s.call("get_current_branch")
            check("get_current_branch (fix branch)", r, detail=r.get("branch",""),
                  branch=lambda x: x==branch_name, issue_number=lambda x: x==alpha)

            Path(f"{REPO}/.mcp-e2e-test").write_text(f"e2e {branch_name}\n")

            r = s.call("commit_with_context", message="test: MCP e2e smoke commit")
            check("commit_with_context", r,
                  detail=r.get("ref","") if isinstance(r,dict) else "",
                  committed=lambda x: x==True)

            r = s.call("push_branch")
            check("push_branch", r, detail=r.get("branch","") if isinstance(r,dict) else "",
                  pushed=lambda x: x==True)

            r = s.call("list_open_prs")
            if isinstance(r, list): ok("list_open_prs", f"{len(r)} PRs")
            else: fail("list_open_prs", f"not a list: {r}")

            print("\n[4/5] PR tools")

            r = s.call("create_pr",
                       title=f"[TEST] MCP e2e PR #{alpha}",
                       body=f"E2E test PR.\n\nCloses #{alpha}.")
            r = check("create_pr", r,
                      detail=f"#{r.get('number')} {r.get('url','')}" if isinstance(r,dict) else str(r),
                      number=lambda x: x and x > 0)
            if r and isinstance(r,dict): pr_num = r.get("number")

            if pr_num:
                r = s.call("get_pr_status", pr_number=pr_num)
                check("get_pr_status", r,
                      detail=f"state={r.get('state')} mergeable={r.get('mergeable')}",
                      number=lambda x: x==pr_num)

                r = s.call("list_open_prs")
                if isinstance(r,list) and any(p.get("number")==pr_num for p in r):
                    ok("list_open_prs (with PR)", f"PR #{pr_num} in {len(r)} PRs")
                else:
                    fail("list_open_prs (with PR)", f"PR #{pr_num} not found")

                # Inline impact test after PR creation
                r = s.call("review_pr_impact", pr_number=pr_num)
                check("review_pr_impact", r,
                      detail=f"{len(r.get('files_changed',[]))} files, {len(r.get('symbols',[]))} syms, tool={r.get('search_tool','')}",
                      files_changed=lambda x: isinstance(x, list) and len(x) > 0,
                      search_tool=lambda x: x in ("zigrep", "rg", "grep", "none"))

        print("\n[5/5] PR impact analysis")

        if pr_num:
            # Test 1: Valid PR — should return files, symbols, and references
            r_valid = s.call("review_pr_impact", pr_number=pr_num)
            check("review_pr_impact (valid PR)", r_valid,
                  files_changed=lambda x: isinstance(x, list) and len(x) > 0,
                  symbols=lambda x: isinstance(x, list),
                  search_tool=lambda x: x in ("zigrep", "rg", "grep", "none"))

            # Test 2: Non-existent PR — should return error
            r_bad = s.call("review_pr_impact", pr_number=999999)
            if isinstance(r_bad, dict) and "error" in r_bad and isinstance(r_bad["error"], str) and len(r_bad["error"]) > 0:
                ok("review_pr_impact (bad PR)", f"error={r_bad['error'][:40]}")
            else:
                fail("review_pr_impact (bad PR)", f"expected error, got {r_bad}")

            # Test 3: Structure validation — every symbol must have name, file, referenced_by
            if isinstance(r_valid, dict) and isinstance(r_valid.get("symbols"), list):
                valid = True
                for sym in r_valid["symbols"]:
                    if not ("name" in sym and "file" in sym and "referenced_by" in sym):
                        valid = False; break
                if valid:
                    ok("review_pr_impact (schema)", f"{len(r_valid['symbols'])} symbols validated")
                else:
                    fail("review_pr_impact (schema)", "symbol missing required fields")
            else:
                ok("review_pr_impact (schema)", "no symbols to validate")

    finally:
        s.close()
        print("\n-- Cleanup --")
        subprocess.run(["git","-C",REPO,"checkout",orig_branch], capture_output=True)
        if pr_num:
            res = subprocess.run(["gh","pr","close",str(pr_num),"--delete-branch"],
                                 capture_output=True, text=True, cwd=REPO)
            print(f"  PR #{pr_num} closed" + ("" if res.returncode==0 else f" (err: {res.stderr.strip()})"))
        if branch_name:
            subprocess.run(["git","-C",REPO,"branch","-D",branch_name], capture_output=True)
            print(f"  local branch {branch_name} deleted")
        for n in [alpha, beta]:
            if n:
                res = subprocess.run(["gh","issue","close",str(n),"--comment","e2e cleanup"],
                                     capture_output=True, text=True, cwd=REPO)
                print(f"  issue #{n} closed" + ("" if res.returncode==0 else " (already closed)"))
        tf = Path(f"{REPO}/.mcp-e2e-test")
        if tf.exists(): tf.unlink(); print("  removed .mcp-e2e-test")

    print(f"\n{'='*50}")
    print(f"Results: {len(PASSED)}/{len(PASSED)+len(FAILED)} passed")
    if FAILED:
        print("Failed:")
        for f in FAILED: print(f"  - {f}")
    else:
        print("All 17+ tools passed!")
    return len(FAILED) == 0

if __name__ == "__main__":
    sys.exit(0 if run() else 1)
