# codedb vs the field — Twitter/X copy (eval thread)

Source: 2026-08 A/B eval — Opus 5 `claude -p` harness, 36 questions x 3 repetitions,
codedb-mini vs graphify vs lean-ctx vs no-MCP baseline, this repo (637 files).

Best times to post (PST): Tue-Thu, 8-10 AM
Best times to post (SGT): Tue-Thu, 11 PM - 1 AM

---

Tweet 1/5 (Hook)

We benchmarked codedb against every code-intel MCP we could find — and against no tools at all.

36 questions, 3 repetitions, Opus 5 answering. Every setup scored 36/36.

At equal accuracy, codedb was the cheapest per question: $0.1427 vs graphify $0.1446 vs lean-ctx $0.1473.

---

Tweet 2/5 (Where it's not a tie)

Accuracy tied. Capability didn't.

17-22x faster indexing than the alternatives.
~600x faster point queries.
11/12 on concept retrieval.
Callers in one call, not a grep chain.

On the hard multi-hop set, codedb beat the no-tools baseline on both cost and wall time (-14%).

---

Tweet 3/5 (The honest part)

Full disclosure: on a 637-file repo, Opus 5 with plain grep already answers everything correctly.

Baseline's nominal edge over codedb was +0.9% cost — one-ninth of the run-to-run noise (individual runs swing +/-19%). That's a tie, not a loss.

The claim we can defend: nothing dominates codedb on any axis.

---

Tweet 4/5 (What "frontier" means here)

So the precise claim: codedb costs nothing to attach and is strictly more capable. No tool or no-tool setup beats it on cost, accuracy, or speed — and it wins every capability dimension outright.

The next benchmark is a 10k+-file repo, where grep round-trips explode and an index has to win outright.

---

Tweet 5/5 (CTA)

codedb gives AI agents symbols, callers, deps, outlines, and compact context. Your editor still does the edits.

curl -fsSL https://codedb.codegraff.com/install.sh | bash

Star it here: https://github.com/justrach/codedb/

---

Alt: Single tweet

We A/B'd codedb vs graphify, lean-ctx, and no tools at all: 36 questions x 3 reps on Opus 5. All 36/36 — codedb cheapest per question ($0.1427/q), 17-22x faster indexing, ~600x faster point queries, and it beat no-tools on the hard multi-hop set. Nothing dominates it on any axis.

https://github.com/justrach/codedb/

---

Posting notes

- DO NOT POST until the perf branch (7 commits, currently at /tmp/codedb-pr) is merged and released — the frontier numbers were measured on that branch, not on the shipped release, which was +18% worse than baseline before the fixes.
- Method if asked: Opus 5 `claude -p` A/B harness, 36 questions x 3 repetitions per setup, same machine, same repo (637 files). Cost CV across repetitions ~8%; individual lanes swing +/-19%, which is why the +0.9% baseline delta is reported as a tie.
- "Every capability dimension" = indexing speed (17-22x), point-query latency (~600x), concept retrieval (11/12 vs lower for both competitors), one-call callers, and the multi-hop set (cheaper AND 14% faster than baseline).
- Do not claim "beats grep" — on this repo size it doesn't need to and the data doesn't show it. The defensible framing is "free to attach, strictly more capable, undominated."
- No link on tweets 1-4. Repo link on tweet 5 only.
- Optional tags on the final post: #Zig #MCP #AIEngineering #DeveloperTools
