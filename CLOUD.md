# Hosted Jina hybrid retrieval handoff

Release 0.2.5853 integrates the validated hosted-Jina retrieval work.
Verify the checkout before changing code: old Qwen/local-default experiments
do not describe this system.

Default hybrid calls the existing hosted Jina embedding service. With a
compatible sidecar it embeds query plus calibration text and searches the local
OpenPuffer mmap index. Missing-sidecar hybrid uses hosted bounded exact
reranking. No embedding model is run locally. Preserve the 4× candidate pool.

Read [ADR 0010](docs/adr/0010-multilingual-datasets-and-test-intent.md) for the
128-question, six-repository suite and current native test-intent improvement.
Anyhow top1 rises 16/20 to 18/20; all other repository top1 scores hold, including
17/20 on the frozen Requests holdout. No per-query rank or recall regressions.
Chi retains one top-five miss; the failure catalog records all unresolved cases.
All six datasets are now observed; future promotion needs another fresh holdout.
No client replacement or cloud deployment occurred. Use stable binary copies
outside zig-out when evaluating. [ADR 0007](docs/adr/0007-current-jina-hybrid-sidecar.md)
records the hosted/default-hybrid architecture and baseline fallback behavior.

The engine owns indexing, ANN persistence and fusion, and device signing.
`codedb-cloud` owns enrollment, certificates, quotas, origin routing and service
deployments. Use the existing device-authentication flow. Shared origin
credentials are not public Worker bearer tokens; never put them in client
code, datasets, logs, or ADRs. [evals/](evals/README.md) is the runnable handoff.
