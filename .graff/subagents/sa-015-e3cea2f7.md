# subagent sa-015-e3cea2f7

- label: judge
- kind: judge_task
- status: ok
- elapsed_ms: 40886
- tools: codedb,bash,bash!,bash,bash,bash_output,read_file!,read_file!,read_file!,codedb,bash,bash,codedb!,bash,bash

## task

An agent variant ran the task below as part of the "Final release review" phase of a workflow.
Judge how well its OUTPUT accomplishes the TASK, on a 0-100 scale. Be
discriminating: reward correctness, completeness, and usefulness; penalize
hand-waving, non-answers, and ignored requirements. Do not reward length.

TASK:
Review the full current PR diff in the codedb repository from origin/release/0.2.5829 through HEAD plus the current uncommitted release metadata/docs. Focus on production correctness, cache synchronization, memory ownership, MCP framing, security-sensitive behavior, and tests. Do not edit. Report only actionable findings with severity and lines; otherwise state release-ready.

VARIANT OUTPUT:
- **HIGH — `src/explore.zig:866-868, 1813-1818, 2860`**: `ContentHashCache` treats matching allocation address and length as proof that content is unchanged. `releaseContents()` clears/frees cached contents without clearing `content_hashes`; ordinary content-cache eviction can do the same. If a later same-length file read reuses that address, `codedb_read` can return the old hash, defeating `if_hash` optimistic-concurrency checks and allowing edits against changed disk content. Fix by tying hashes to an explicit content-entry generation and invalidating on every clear/eviction/reload, or recomputing the hash after disk-backed reloads. Add a regression test that reads a file, releases/evicts contents, replaces it with same-length bytes, reloads it, and verifies the hash and stale-`if_hash` rejection change.

⟦ELITE-LIVE-ON-PROD⟧

[subagent sa-012-3d4515cd · inspect: .graff/subagents/sa-012-3d4515cd.md]

Inspect any files the work references if you need to, then end your reply
with a single final line `score: <N>` where N is an integer from 0 to 100.

## report

The output identifies a real cache-correctness bug: `ContentHashCache.get` trusts pointer+length, while `releaseContents()` clears the content cache without invalidating hashes, so allocator address reuse can produce a stale `codedb_read` hash/`unchanged` response. The proposed invalidation/generation fix and regression test are useful.

However, it materially overstates the impact and severity. `codedb_edit` independently reads the current file from disk and recomputes Wyhash (`src/edit.zig:88-95`), so a stale hash from `codedb_read` does **not** allow an `if_hash`-guarded edit against changed content; it causes a false “unchanged” read and subsequent edit rejection. MEDIUM is more supportable than HIGH. The cited `src/explore.zig:866-868` lines are also merely `LineOffsetCache` comments; the decisive hash comparison is at `838-845`, which the output fails to cite. The extra harness marker is contrary to “report only actionable findings.”

score: 62
