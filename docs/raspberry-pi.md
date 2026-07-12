# Raspberry Pi 4 deployment and performance

codedb supports 64-bit Raspberry Pi OS through the generic
`codedb-linux-arm64` release asset. Raspberry Pi 4 is a first-class design
target, but it keeps the same full cache capacities, indexing parallelism,
query warmup, result limits, and retained data as other platforms.

## Install

Use a 64-bit OS, then run the normal installer:

```bash
curl -fsSL https://codedb.codegraff.com/install.sh | bash
```

Recommended hardware for sustained indexing:

- Raspberry Pi 4 with 4 GB RAM or more;
- 64-bit Raspberry Pi OS;
- SSD or fast USB storage for repositories and codedb state;
- adequate cooling to avoid CPU throttling.

A 2 GB Pi can run codedb, but repository contents and indexes are inherently
workload-dependent. This implementation does not shrink caches, disable warmup,
retain fewer projects, release useful data early, or reduce worker counts to fit
an artificial memory target.

## No-tradeoff indexing improvement

The per-file trigram index must retain a list of every unique trigram so updates
and removals can delete postings correctly. Previously, each list grew
geometrically as trigrams were appended. That caused repeated allocator calls,
copying during growth, and unused capacity in the long-lived final list.

The current implementation:

1. finishes the local trigram map;
2. allocates the final list once, at the exact map count;
3. appends one item per map entry through the already-checked-capacity path.

This applies to normal indexing, reusable-map indexing, and insertion of
pre-extracted worker results. It does not change trigram extraction, masks,
postings, ranking, cache behavior, or concurrency.

A 20-pair AB/BA host comparison on the same immutable 641-file corpus measured:

- baseline median initial index: **137 ms**;
- optimized median initial index: **136 ms**;
- paired-median change: **0.73% faster**;
- deterministic bootstrap 95% interval: **0.36%-1.46% faster**;
- optimized wins: **14/20**.

This is a small but measured improvement, not a Raspberry Pi hardware claim.
The main benefit is eliminating geometric-growth allocation churn and retained
capacity slack without taking resources away from query performance.

## Optional Pi 4 CPU-tuned build

The published ARM64 binary is generic so it remains compatible across ARM64
Linux machines. A source build can tune instruction scheduling for the Pi 4's
Cortex-A72 while keeping `ReleaseFast` and all runtime features:

```bash
zig build \
  -Doptimize=ReleaseFast \
  -Dtarget=aarch64-linux-gnu \
  -Dcpu=cortex_a72
```

The resulting binary is `zig-out/bin/codedb`. CPU tuning changes code generation,
not caches or behavior. Do not use the Cortex-A72 build as a general ARM64
release binary; it is specifically for Pi 4-class CPUs.

## Benchmark on the actual Pi

Use the included benchmark to compare the generic and Cortex-A72 builds with
identical runtime resources:

```bash
sudo apt-get install time
CODEDB_PI_BENCH_OUT=zig-out/bench-pi \
  scripts/bench-pi.sh /path/to/representative/project
```

The script:

- builds generic ARM64 and Cortex-A72 `ReleaseFast` binaries;
- leaves caches, workers, warmup, and retention unchanged;
- measures cold and restart wall time with GNU `time -v`;
- records peak RSS for visibility, not as a target to reduce at any cost;
- requires exact tree-output parity between binaries;
- writes raw timing files and `report.md`.

Run several repetitions before drawing conclusions. SD card versus SSD, cooling,
clock throttling, kernel, filesystem, and repository shape can outweigh small
CPU-code-generation gains.

## Operational guidance without performance cuts

- Prefer SSD/USB storage over microSD for large repositories.
- Use snapshots so normal restarts avoid unnecessary full scans.
- Exclude generated build trees and dependency caches only when agents do not
  need them; exclusion changes indexed scope and should be intentional.
- Keep the Pi cooled during sustained scans.
- Avoid running several independent codedb servers for the same repository; use
  codedb's singleton MCP/daemon behavior.
- Measure with the real repository rather than extrapolating from synthetic
  microbenchmarks.
