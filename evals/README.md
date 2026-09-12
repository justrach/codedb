# Live Jina hybrid accuracy evaluations

Start with [ADR 0010](../docs/adr/0010-multilingual-datasets-and-test-intent.md) and its
[trial ledger](results/2026-09-05-jina-round3-trials.tsv). The target is accurate
default hybrid retrieval using hosted Jina and CodeDB's OpenPuffer mmap sidecar.

`jina_hybrid_live.py` creates a corpus from pinned source files, checks hashes,
measures missing-sidecar fallback, builds/verifies the Jina sidecar, and measures
default queries. `--build-only` prepares a new holdout without opening queries.
`jina_sidecar_compare.py` compares actual binaries in persistent MCP sessions
against the same sidecar with live hosted embeddings on every request.
`jina_eval.py` contains corpus validation and file-relevance metrics.

Build baseline and candidate with `zig build -Doptimize=ReleaseFast`. Use Python
3's standard library and a source checkout matching the dataset's commit and
file hashes. The sidecar preparation explicitly embeds the listed public files.
Use a fresh indexable scratch directory and a new report name for every run:

```bash
python3 evals/jina_hybrid_live.py \
  --binary /absolute/path/to/candidate \
  --source /absolute/path/to/pinned/express \
  --dataset evals/datasets/express-jina-accuracy-heldout-v1.json \
  --work-dir /absolute/path/to/new/scratch \
  --build-only --out /absolute/path/to/new-corpus.json
python3 evals/jina_sidecar_compare.py \
  --baseline /absolute/path/to/baseline --candidate /absolute/path/to/candidate \
  --dataset evals/datasets/express-jina-accuracy-heldout-v1.json \
  --corpus-report /absolute/path/to/new-corpus.json \
  --split held_out --repeats 3 --out /absolute/path/to/new-results.json
```

For a new untouched holdout, create a freeze JSON before opening results with
`baseline_sha256`, `candidate_sha256`, and `dataset_sha256` (SHA-256 file hashes),
and pass `--freeze /absolute/path/to/freeze.json` to the comparison. The saved
freeze applies only to the recorded binaries, not arbitrary rebuilds. Reports
are immutable. Source fixture paths are machine-specific; rebuild corpora using
the pinned public dataset instead of assuming saved scratch directories exist.

The OpenClaw dataset's train and held_out positives have both been used for
32-question development runs (`--split all --repeats 2`). Express was fresh only
for the frozen run in ADR 0008; it is now a regression set too. Do not report
repeated calls as extra independent questions. Inspect individual regressions
alongside aggregate NDCG@5, recall@5 and correct-file-first rates. A successful
runner exit proves execution, not an accuracy acceptance threshold.

No credentials, vectors, or source snippets are logged. Provider failures and
fallback calls cannot count as successful sidecar accuracy samples. Dataset
queries, relative paths, binary hashes and retrieval provenance are retained.
ADRs 0001–0006 and older Qwen/offline runners, where present, are historical
wrong-target work and must not govern the current integration.

## Explore the follow-up data

`followup_report.py` verifies the frozen receipt against its raw report hashes,
checks every repeated rank, and exports a portable view of all 148 observed
questions. It retains the original 128-question cohort separately from the
later 20-question ItsDangerous holdout. It also produces 11 observed comparison
cases pairing each expected file with the competing first result. These are
development diagnostics, not new holdout evidence or a trained reranker.

```bash
python3 evals/followup_report.py \
  --summary evals/results/2026-09-11-followup-summary.json \
  --latency-dir /absolute/path/to/latency-diagnostic \
  --out /absolute/path/to/new-report.json \
  --dashboard-out /absolute/path/to/new-dashboard.html
python3 -m unittest discover -s evals -p test_followup_report.py
```

The optional dashboard is a conversation visualization fragment with local
filters and expandable query/lane evidence. It contains only the report data;
it makes no network requests. Both output names must be new. Omit
`--latency-dir` when only inspecting the frozen accuracy run. Raw report paths
come from the input receipt and must exist on the machine running the exporter.

For latency diagnosis, both compared binaries must expose `ann_embed_ns` in
the context retrieval metadata. The value already measured by the ANN layer
includes the remote embedding operation, transport, decoding and bounded retry.
Zero on a non-ANN response does not mean a free remote request: the exporter
rejects fallback samples, and missing timing fields are never treated as zero.
The diagnostic compares warm samples separately from cold generation loading.
It computes wall-minus-embedding per sample before taking percentiles; that
remainder includes scheduling and MCP overhead, so it is not pure local CPU time.
All >10% increases remain visible with absolute millisecond differences.

The dashboard's accuracy counts remain from the original frozen binaries, even
when a later timing run is supplied. It separately records timing-run rank
changes and binary hashes. Another ranking change requires a new frozen holdout;
none of these seven repositories is fresh anymore.

For round 2, use `flask-jina-accuracy-heldout-v1.json` and the Flask source
revision pinned in that dataset with the same commands above. Flask was fresh
only for the saved round-2 freeze; future runs are regressions. To reconstruct
the ADR 0008 comparison source, apply `patches/adr0008-baseline.patch` in a clean
b72db9b worktree with `git apply`, then build ReleaseFast. Corpus files are hash
checked before comparison. Binary paths may be relative to the launching cwd;
missing scratch parent directories are created automatically. Results report
individual ranking regressions as well as top-five recall regressions.

The unit suite can rebuild `zig-out/bin/codedb` in debug mode. Before running
quality comparisons, copy each ReleaseFast binary outside the build output,
freeze those copies, and use them for all MCP processes. Do not evaluate a path
that another build may replace. The runner checks binary hashes again at exit
and marks an intervening replacement as a failed run.

## Graff repair comparison

The [48-attempt study](graff-comparison/STUDY.md) compares CodeDB,
Graphify and workspace-only Graff on eight Python task families using Grok 4.6.
It includes strict grader results, a specification-ambiguity sensitivity check,
token accounting and model API cost equivalents. It is a diagnostic study of
small fixtures, not a large-repository benchmark or a first-install test.

The [frozen bundle and replay instructions](graff-comparison/README.md) include
every input, external grader and saved repair. Run the helper checks with:

```bash
python3 -m unittest discover -s evals -p 'test_graff_comparison*.py'
```

## Six-repository batch suite

See the [dataset inventory](datasets/README.md), [suite manifest](suites/jina-accuracy-round3.json),
and [failure catalog](results/2026-09-05-jina-round3-failure-catalog.json).
Prepare each new corpus with jina_hybrid_live.py --build-only using the source
revision and files pinned in its dataset. Replace the manifest's corpus-report
paths for your own prepared fixtures. Then run the development group:

```bash
python3 evals/jina_accuracy_suite.py \
  --baseline /absolute/path/to/stable-baseline \
  --candidate /absolute/path/to/stable-candidate \
  --out-dir /absolute/path/to/new-development-results --repeats 2
```

Use --repos chi,anyhow for a subset. The holdout group requires --group holdout,
--freeze /absolute/path/to/new-freeze.json and a new output directory. Requests
was fresh only for the saved round-3 freeze; that field now records historical
partitioning. Do not repeatedly tune on it. To reconstruct the ADR 0009 baseline,
apply patches/adr0009-baseline.patch in a clean b72db9b worktree and build
ReleaseFast. No local embedding model or training process is required.
