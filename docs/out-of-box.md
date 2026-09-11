# What works without setup, and what still needs it

Status: fixes on the follow-up branch; not released. Tested on Apple Silicon
macOS with a newly downloaded, checksum-verified v0.2.5855 binary and separately
built candidates. This is a first-use/lifecycle investigation, not a ranking
hill climb or a new holdout.

## Short answer

Local text/symbol indexing and MCP startup work on a fresh project. The strongest
repository-wide semantic search does **not** activate automatically: it needs
`codedb <root> semantic-index`, and indexed source edits require another build.
The default fallback was also broken on fresh MCP projects in v0.2.5855.

The earlier 148-question evaluation used prepared sidecars and selected corpus
files. It did not establish out-of-the-box behavior. This investigation clones
the entire pinned Express, Requests and Chi repositories, retaining their other
source files, examples and documentation, without invoking any indexing command
before the first default-hybrid query. The machine's existing device enrollment
is reused; fresh credential enrollment and new operating-system accounts were
not exercised. No API key or model override was supplied for live queries.

## Failures reproduced and repaired

1. **Fresh MCP projects skipped semantic fallback.** The cached ANN loader called
   `fileIdentity` before the metadata loader. Missing metadata escaped as
   `FileNotFound`, while MCP recognized `AnnIndexMissing` as the condition for
   hosted exact reranking. All 56 release queries took this broken path. The
   cached loader now returns the same domain error as uncached search.
2. **A missing graph disabled fallback too.** Both metadata loading's graph-size
   check and generation validation could leak `FileNotFound`. Missing graphs now
   report `InvalidAnnSidecar`, keeping bounded fallback available. A previously
   mapped generation remains owned until safe retirement; stale data is not used
   for new ANN queries.
3. **The installed Claude hook referred editors to a removed tool.** `sed` and
   `awk` could be blocked with a request to use `codedb_edit`, which no longer
   exists. These native tools now pass through the hook. The existing read-tool
   routing is retained.
4. **The installer could proceed without checksum verification.** Missing or
   unusable manifests/hash tools now fail before replacing an existing binary.
   A unique exact asset entry and valid SHA256 digest are required. Downloads use
   an unpredictable temporary file in the target directory and are cleaned up
   on failure. Both website copies are synchronized with the canonical installer.

`CODEDB_NO_INTEGRATIONS=1` allows an isolated binary installation without changing
client, policy, or hook configuration. The live installer test downloaded and
installed the published release into a test prefix. Fixture-based fresh Claude
and Codex registration tests validate the generated configuration while keeping
unrelated MCP entries. The user's active client configuration was not modified.

## Full-repository retrieval results

These are 56 previously observed diagnostic questions, not independent held-out
validation. A first-result miss is distinct from failing to include the expected
file anywhere in the top five.

| Mode | Expected file first | Expected file in top five |
| --- | ---: | ---: |
| Published release, no semantic setup | 24/56 | 43/56 |
| Release plus missing-index error fix, no semantic setup | 24/56 | 43/56 |
| Current follow-up candidate, no semantic setup | 28/56 | 52/56 |
| Release with full-repository ANN explicitly built | 47/56 | 54/56 |
| Existing retrieval candidate with the same full-repository ANN | 50/56 | 56/56 |

The fallback fix restores the documented hosted operation; it does not itself
improve ranking because the fallback strongly preserves lexical order. The
candidate's relevance changes were already on the branch before this inquiry;
no ranking constants, gold labels, or ANN breadth were changed here. The final
fresh-project candidate run uses the default token budget and JSON solely for
measurement. The initial diagnostic used a 12,000-token response budget.

The candidate still misses these expected files in the top five without ANN:

- Express: tests for mounting a sub-application with `app.use`.
- Chi: the implementation that cleans repeated slashes in URL paths.
- Chi: tests for wildcard compression content types.
- Chi: tests for cleaning doubled slashes.

With the full ANN active, all four are found. Other results are still sometimes
ordered poorly: Express trust-proxy conversion and application dispatch,
Requests redirect-method handling, proxy URL tests and case-insensitive mapping
tests, and Chi path-cleaning tests. Requests' proxy-test query still moves from
second to third. Fresh fallback also has individual ranking regressions despite
the aggregate recall gain (Requests first-result count drops from 11 to 9).
The draft retrieval candidate must not be described as regression-free.

Explicit full-repository builds took approximately 20 seconds for Express,
18 seconds for Requests and nine seconds for Chi in this run. These are small
public repositories and short observations, not a promise for large repositories
or other networks. This does not establish out-of-the-box operation on native
Windows; the mmap ANN backend still has a platform restriction in the code.

## Changes, missing indexes, restart and offline behavior

The live lifecycle test starts from `/` using an MCP roots handshake and a new
generated project with no snapshot or sidecar. All eleven checks pass on the
combined runtime:

- Fresh default-hybrid query uses hosted fallback and finds the expected source.
- Explicit indexing activates ANN in the existing session; the second call reuses
  its cache.
- A real source edit is observed by the watcher and invalidates the ANN. The next
  search uses current lexical candidates and hosted fallback.
- An explicit rebuild activates the new generation without restarting MCP.
- Missing graph, missing metadata and corrupt metadata each fall back safely.
- Restart loads the rebuilt ANN.
- An unreachable custom provider leaves useful local results; explicit
  `semantic=local` does not need that provider.

The fixture's `.env` path is excluded from results and transmitted-candidate
provenance. The full unit suite's existing sensitive-path and traversal tests
remain part of validation. The test uses generated non-private source and does
not claim that source-bearing default hybrid requests work offline.

## Remaining product decision

Automatic build and refresh are not implemented by these fixes. They would
remove the manual setup gap, but also make repository-wide source-chunk uploads
automatic instead of explicitly requested. The default remains unchanged pending a product decision about
repository-wide automatic uploads. A future implementation needs visible build state, bounded and
deduplicated background work, safe cancellation, change detection, retry/backoff,
and the current transactional validation before publishing a generation.

These results support that lifecycle work rather than further tuning against a
prepared miniature corpus. Existing queries are regression cases; a new ranking
policy still requires a new frozen holdout. No client replacement, release,
notarization, or hosted deployment occurred in this investigation.

## Reproduce

Use fresh output paths, a full local clone matching the dataset revision, and
a stable ReleaseFast binary outside `zig-out`:

```bash
python3 evals/fresh_project_probe.py \
  --binary /absolute/path/to/codedb \
  --source /absolute/path/to/full/express \
  --dataset evals/datasets/express-jina-accuracy-heldout-v1.json \
  --root "$HOME/tmp/new-express-fixture" --out /absolute/path/to/new-report.json

# Use another new root/report and --build-semantic for the setup comparison.
python3 scripts/test_semantic_lifecycle.py \
  --binary /absolute/path/to/codedb \
  --root "$HOME/tmp/new-lifecycle-fixture" --out /absolute/path/to/new-lifecycle.json
python3 scripts/test_installer_safety.py
zig build test
python3 scripts/e2e_mcp_test.py --binary /absolute/path/to/codedb --project /absolute/path/to/codedb/source
```

Raw outcomes remain in `/Users/blackfloofie/tmp/codedb-out-of-box-evidence`.
The [portable receipt](../evals/results/2026-09-11-out-of-box.json) records hashes,
query outcomes, limits and validation. The initial lifecycle attempts exposed a
test wait that matched a not-found message and then the missing-graph defect;
both failures are retained in the raw evidence, and neither counts as a pass.

## Repeatable failure injection

`scripts/test_semantic_faults.py` adds 24 checks using a loopback HTTP fixture.
It runs without credentials or an external embedding service. Its synthetic
vectors exercise transport and index lifecycle contracts, not relevance.

| Failure or lifecycle event | Required behavior |
| --- | --- |
| HTTP 401, 429 and 503 | Keep local results and recover in the same session when the provider recovers. |
| Invalid JSON, dimensions, duplicate rows, model identity, non-finite or zero vectors | Reject the response; preserve local search. |
| Slow response or a slow retry | Finish within the bounded request budget, with scheduling tolerance in the test. |
| One dropped connection; repeated dropped connections | Recover with one retry; stop after two attempts if both fail. |
| Exhausted chunk-embedding retries | Leave the existing metadata and graph byte-for-byte unchanged and searchable. |
| A transient build rate limit | Complete the build after a bounded retry. |
| Three MCP clients querying during a paused rebuild | Serve the previous valid generation, then validate and adopt the replacement. |
| A killed build during embedding | Keep the prior generation usable. |
| Source content changes during embedding | Reject publication, preserve prior bytes, and allow a subsequent fresh build. |
| Sensitive fixture files | Never include their marker in any captured query or build request. |
| Explicit local mode | Send zero embedding requests. |

The suite found that a connection closed before its response could produce
`HttpConnectionClosing`, bypassing the existing transient retry. That error now
receives the same single retry inside the original deadline. The unchanged
before-fix binary fails the new dropped-connection case; the fixed binary passes
it. Authentication rejection, rate limiting, malformed vectors and TLS failures
are not added to the interactive retry list. No ranking policy changes here.

Run it with new paths (the validated fixture root included spaces and Unicode):

```bash
python3 scripts/test_semantic_faults.py \
  --binary /absolute/path/to/stable/codedb \
  --root "$HOME/tmp/new-semantic-fault-fixture" \
  --out /absolute/path/to/semantic-faults.json
```

The macOS PR workflow runs this suite and uploads its JSON report. The
[local verification receipt](../evals/results/2026-09-11-semantic-faults.json)
keeps the failing before-fix result, final checks, binary hashes and validation.
A local pass does not establish that the GitHub-hosted run has passed.

Further coverage should prioritize fresh-account enrollment and expired-device
authentication in a disposable account, Linux/native Windows runtime behavior,
disk-full or permission failures at the metadata commit point, and interruption
during slab writing. The current kill test interrupts embedding before file
publication; it does not simulate power loss. Large repositories need sustained
memory/descriptor and concurrent-change tests. Future relevance changes need a
new frozen holdout; the loopback vectors provide no evidence of ranking quality.
