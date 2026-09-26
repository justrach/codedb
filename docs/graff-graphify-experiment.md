# Graff + CodeDB versus Graff + Graphify

Follow-up: the [broader repair study](graff-retrieval-study.md) adds eight task
families, a workspace-only baseline, repeated attempts and portable graders.
Its controls differ from this source-understanding pilot; compare each round
within its own protocol.

On 2026-09-11, Grok 4.6 answered the same six source-understanding questions
using each retrieval system. Both produced six correct answers, each with a
source range containing the pre-recorded evidence and independently verified
through the shared source reader. This is a small diagnostic comparison on
previously observed Requests questions, not a new holdout or an overall winner.

| Measurement | CodeDB | Graphify |
| --- | ---: | ---: |
| Correct source-backed answers | 6/6 | 6/6 |
| Retrieval calls | 10 | 21 |
| Shared source reads | 6 | 6 |
| Model calls | 5 | 6 |
| Reported input tokens, including cached input | 48,310 | 89,010 |
| Cached input tokens | 25,344 | 60,928 |
| Output tokens | 2,176 | 2,643 |
| Agent wall time, including MCP startup | 45.3 s | 45.8 s |
| Explicit index build, excluding package installation | 20.4 s | 1.7 s |

The CodeDB arm used the unreleased PR #750 runtime with hosted Jina and local
OpenPuffer ANN. The [Graphify source](https://github.com/Graphify-Labs/graphify/tree/23f2ffaa43fd12f25d9eabe91e6d184b5d89b474)
was pinned to `23f2ffaa43fd12f25d9eabe91e6d184b5d89b474` (package 0.9.58).
Its graph was built through `graphify update`, which extracts code locally
without a model pass. The graphs/indexes were explicitly prepared; these times
and outcomes do not establish first-install or automatic-refresh behavior.

## Controls and verification

Both arms used Graff 0.0.296, `--yolo`, and the route `xai/grok-4.6` through the
same existing subscription login. Full separate Requests clones were pinned to
`dae7ef63b4df6eded86637f251fc4e3a06c3b479`. Questions covered redirect method
changes, streamed partial lines, proxy URL construction, pickle state, proxy
tests and case-insensitive mapping tests. Gold paths and anchors stayed outside
the agent workspaces and were not supplied to the model.

The system prompt and limits were identical: 16 model calls, 40 tool calls,
no subagents, no edits, no web access, at least one retrieval call per question,
and source verification before answering. A shared read-only MCP could read at
most 200 numbered lines from a tracked source file; it provided no search or
listing. Built-in local tools were disabled. Accepted logs contain only the
assigned retrieval server and shared reader. All six cited ranges were actually
read by each agent, and tracked source files stayed unchanged.

The model chose different query rewrites, budgets and follow-up tools in each
arm. The retrieval schemas also differ. Input-token counts include accumulated
history and cache reuse; they are not direct index sizes or dollar costs. This
single paired run cannot establish a latency or cost advantage.

## Failures and extra work exposed

1. **Graff configuration isolation.** Initial runs could import other configured
   MCP servers or auto-connect CodeDB Pro. They were excluded. The accepted runs
   used local configuration, explicit null overrides for imported server names,
   companion opt-outs, and a PATH without companion executables. Connected
   server names were verified before scoring.
2. **Graff/Graphify MCP handshake compatibility.** Graphify's installed SDK
   accepted `server/discover`, then rejected `tools/list` because Graff omitted
   required protocol/client metadata. Graff reported `BadMcpResponse`.
   `GRAFF_MCP_PROBE=0` selected the compatible initialized handshake. This is an
   interoperability failure, not evidence that Graphify's graph search failed.
3. **Graff tool availability during startup.** Nonblocking one-shots did not
   give the model a usable retrieval catalog in the rejected trials. The
   accepted runs used `--json` to wait for MCP startup and `--no-lean` for eager
   schemas. The exact contribution of each catalog layer has not been isolated.
4. **CodeDB definition completeness.** `codedb_explain(name="request_url")`
   returned only the first signature line of a multiline Python method. The
   source reader supplied the missing body. This is a concrete regression case
   for definition-body coverage; it did not make the final answer incorrect.
5. **Graphify retrieval breadth and ambiguity.** All seven `query_graph`
   responses were truncated. The first six broad queries traversed 603–791
   nodes in a 1,253-node graph. Two `get_node` calls were ambiguous across files;
   qualified node IDs resolved them. Graphify reported the ambiguity and
   truncation explicitly, and the agent recovered with further lookups.

No competitor source, ranking policy, installed client or release was changed.
The publication-permission tests completed alongside this experiment are
[documented separately](out-of-box.md#publication-permission-failures).

## Evidence and next experiments

The [portable receipt](../evals/results/2026-09-11-graff-grok-graphify.json) includes
the identical system prompt, questions, answers, citation checks, tool arguments,
counts, timings, hashes, controls and excluded attempts. Raw MCP traces and
setup/runner scripts remain in
`/Users/blackfloofie/tmp/codedb-graphify-experiment`; no credentials are included
in the receipt.

The next useful comparison is a fresh repository with private gold labels,
repeated model runs, and matched graph-relationship questions as well as source
lookups. Add source mutations between queries to compare refresh behavior.
Separately, reproduce the Python definition truncation on a minimal fixture and
make Graff's isolated MCP configuration and modern SDK handshake into protocol
regression tests. These observations do not justify tuning ranking against the
six already observed questions.
