# Graff retrieval comparison fixtures

This bundle supports the [CodeDB study](STUDY.md):
eight Python repair tasks, three tool configurations and two attempts per task.
It preserves the exact inputs, graders and generated repairs rather than
requiring a checkout of an unavailable local CodeGraff revision.

`fixtures-v3.json` contains the source, specification, visible tests, prompt,
editable-file allowlist and external grader for each task. Each file has a
SHA-256 digest. The first three families extend previously observed CodeGraff
regressions; the other five are unchanged distilled tasks from its evaluation
suite. The source labels are provenance, not claims that these are original
upstream integration tests or SWE-bench instances.

The fixture source retains CodeGraff's [full license](CODEGRAFF-LICENSE.txt),
including its additional terms. The bundle records the source repository and
local checkout revision. That revision was not available from the public remote
when checked, so the bundle itself is the reproducible source of record.

## Inspect and grade

Use Python 3.14.3 to match the recorded run; the helper requires Python 3.10 or
newer. No third-party packages are required for materialization or grading.
Run these commands from the CodeDB repository root:

```bash
python3 evals/graff_comparison.py verify
python3 evals/graff_comparison.py list
python3 evals/graff_comparison.py materialize json-stream /tmp/new-json-task
# Let the agent edit only the implementation files in that new directory.
python3 evals/graff_comparison.py grade json-stream /tmp/new-json-task
```

Materialization refuses an existing destination. Only fixture files are placed
there: the external grader, this bundle and the experiment metadata must stay
outside the agent's workspace. Grading executes the visible test and, if it
passes, an external temporary hidden test; tests/specification/facades must
retain their original hashes. This is a local grader, not an execution sandbox.
The frozen input intentionally fails before a repair.

The [measurement receipt](study-v3/results-v3.json) has every attempt, including
failures, token accounting, tool counts, setup time and hashes. The
[saved repairs](study-v3/solutions-v3.json) permit regrading without a model call:

```bash
python3 evals/graff_comparison.py replay json-stream-r2/graphify /tmp/saved-json-task
python3 evals/graff_comparison.py grade json-stream /tmp/saved-json-task
python3 -m unittest discover -s evals -p 'test_graff_comparison*.py'
```

The saved repair example deliberately illustrates a strict grader failure; see
the study's discussion of the whitespace-only JSON-sequence boundary. Public
gold tests are now observed regression material, not future holdouts.

## Exact captured traces

The [trace archive](study-v3/traces-v3.tar.gz) contains **364 byte-exact files**:
352 per-attempt captures for all 48 attempts, six original runner scripts, the
original CodeGraff usage-parser/runner and five experiment metadata files.
The [inventory](study-v3/traces-v3.json) records a SHA-256 digest and byte length
for every member, plus the archive digest. Only archive filesystem headers are
normalized; file contents, timestamps inside logs and original local paths
are unchanged. No trace content has been redacted or reserialized.

```bash
python3 evals/graff_comparison_traces.py verify evals/graff-comparison/study-v3/traces-v3.json
mkdir /tmp/graff-study-traces
tar -xzf evals/graff-comparison/study-v3/traces-v3.tar.gz -C /tmp/graff-study-traces
```

Archive layout:

```text
attempts/<family>-r<repeat>/<arm>/
  workspace.jsonl       # timestamped MCP requests, responses and stderr
  retrieval.jsonl       # same capture for the assigned retrieval server
  answer.txt            # Graff stdout, verbatim
  progress.log          # Graff stderr, including model usage footer
  process.json          # exit code, timeout and wall duration
  grader.log            # external visible/hidden grader output
  result.json           # original collector result, including tool arguments
  setup.log             # explicit index/graph setup output
metadata/               # manifest, freeze, preflight, sensitivity and batch log
runner/                 # original experiment scripts and suite usage parser
```

The baseline has no `retrieval.jsonl` or `setup.log`. The recorder captured MCP
JSON-RPC and CLI output, **not raw provider HTTP traffic or a complete model
conversation transcript**. Those uncaptured traces cannot be reconstructed.
Authentication stores, environment dumps, `.mcp.json` and `.harness` session
configuration are excluded. Credential pattern screening and Gitleaks reported
no findings in the packaged files. Original task-local filesystem paths
remain visible because this is an exact capture.

The archive's `result.json` and `grader.log` hashes also match the hashes in the
portable measurement receipt. The original runner source retains machine paths
and references to local configuration, for audit. Use the portable helper for
regrading; a live rerun still needs the isolated configuration described below.
The source suite runner retains the accompanying CodeGraff license.

## Chart typography and regeneration

The chart uses **Gramatika Regular and Bold**, the font used by the related
CodeGraff/zigrepper site. [PNG](study-v3/figures/graff-retrieval-study.png) and
[SVG](study-v3/figures/graff-retrieval-study.svg) are included. SVG lettering is
converted to glyph outlines, so it renders consistently without an installed
font. Font files are not redistributed. The [render receipt](study-v3/figures/render.json)
records the source-font hashes, plotting-script hash and output hashes.

With Matplotlib and your local Gramatika font files installed:

```bash
python3 evals/graff_comparison_plot.py \
  evals/graff-comparison/study-v3/results-v3.json \
  /tmp/graff-study-figures --font-dir /path/to/gramatika-fonts
```

The font directory must contain `Gramatika-Regular` and `Gramatika-Bold` as
TTF or WOFF2 files. WOFF2 input requires FontTools and Brotli and is decompressed
only into temporary rendering files. The original figure used Matplotlib 3.11.0.

## Repeat the live comparison

Regrading is portable. A new live model experiment also requires authenticated
Graff, the pinned retrieval tools and an independently isolated configuration;
the helper does not provision accounts or promise one-command model replay.
Use the exact system prompt, task prompts, versions, limits and launch blocks
in the receipt. Prepare a separate fresh fixture for every arm and repeat.

The recorded setup used `codedb <fixture> semantic-index` with hosted Jina and
local OpenPuffer ANN, or `graphify update <fixture>` for a local AST-only graph.
Start the assigned retrieval MCP server against that root. The baseline has
no retrieval server. Give every arm the same workspace MCP catalog:

| Tool | Contract |
| --- | --- |
| `list_files` | Sorted tracked fixture paths. |
| `search_files(query)` | Case-insensitive literal search, at most 80 matching numbered lines, at most 300 characters per line; query length 1–200. |
| `read_file(path)` | Full tracked file with numbered lines; relative paths contained in the fixture. |
| `write_file(path, content)` | Replace only an implementation file named in the task's editable allowlist. |
| `run_tests` | Run the visible test with the same Python as the external grader; 30-second limit; final 16,000 characters from each output stream. |

Each run used these Graff options (substitute the prompts from the receipt):

```text
--yolo --json --no-lean --model grok-4.6
--subagent-model grok-4.6 --no-subagent-tier
--no-local-tools --no-rlm --no-telemetry --learning-privacy local
--max-model-calls 16 --max-tool-calls 40
--context-limit skill_catalog_bytes=1 --context-limit agents_md_bytes=1
--system-prompt <identical-system-prompt> --timing -p <task-prompt>
```

No subagents were allowed. Each process had a 300-second wall limit. Three arms
ran concurrently within each task/repeat block, with rotated launch order;
blocks ran sequentially. Preserve unsuccessful attempts rather than retrying
until success. These controls differ from the earlier two-arm pilot.

Both `.mcp.json` and `GRAFF_MCP_CONFIG` selected the local catalog. Imported
servers needed explicit null overrides; `GRAFF_NO_PLUGINS=1` alone was
insufficient. Installed companion skills were disabled, and Graff's PATH
excluded companion executables. The existing authentication HOME was retained.
Only the expected server names (`workspace`, optionally `retrieval`) were
accepted. Private imported server names and authentication files are not part
of this bundle.

`GRAFF_MCP_PROBE=0` selected the initialized MCP handshake compatible with the
tested Graphify SDK. Graff updates, adoption, companion auto-connection, web
search and telemetry were disabled, as were CodeDB telemetry and auto-update.
See the [earlier experiment](../../docs/graff-graphify-experiment.md) for the
configuration and handshake failures that motivated these controls. This study
does not demonstrate default installation or default client interoperability.

An experiment with the same private runner layout can export a complete receipt
with `python3 evals/graff_comparison_report.py <run-directory> <new-output-directory>`.
The exporter requires all 48 results, verifies the frozen inputs and runner
hashes, keeps raw transcripts/configuration out of the summary receipt and never
treats missing usage as zero. The separate trace archive preserves the exact
captured logs and runner source described above.
