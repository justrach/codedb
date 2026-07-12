# Raspberry Pi deployment

codedb publishes a generic 64-bit ARM Linux binary and includes an opt-in
resource profile for Raspberry Pi-class systems. The primary design target is a
Raspberry Pi 4 running a 64-bit OS with 2-4 GB RAM.

## Requirements

- Raspberry Pi 4 or newer recommended
- 64-bit Raspberry Pi OS or another aarch64 Linux distribution
- 2 GB RAM minimum; 4 GB recommended for large repositories
- SSD or fast USB storage recommended for large indexes and snapshots

The release asset is `codedb-linux-arm64`. The normal installer selects it on
64-bit ARM Linux:

```bash
curl -fsSL https://codedb.codegraff.com/install.sh | bash
```

## Enable the Pi resource profile

Set this before starting codedb:

```bash
export CODEDB_RESOURCE_PROFILE=pi
codedb /path/to/project mcp
```

For an MCP client, put the variable in the server configuration so every codedb
process receives it:

```json
{
  "codedb": {
    "command": "codedb",
    "args": ["/path/to/project", "mcp"],
    "env": {
      "CODEDB_RESOURCE_PROFILE": "pi"
    }
  }
}
```

The aliases `raspberry-pi` and `low-memory` select the same profile.

## What the profile changes

| Resource | Default | Pi profile |
|---|---:|---:|
| Parallel indexing/freshness workers | up to 4-8 by phase | up to 2 |
| Line-offset cache | 16 MiB | 4 MiB |
| Search-result caches | 4 MiB each | 1 MiB each |
| Plain rendered-search cache | 4 MiB | 1 MiB |
| Tree cache | up to 16 MiB per plain/color entry | up to 4 MiB per entry |
| Outline and word-render caches | 16 MiB each | 4 MiB each |
| MCP snapshot-response cache | 16 MiB | 4 MiB |
| Non-default project contexts | 5 | 2 |
| Resident file contents | retained for repositories up to 1,000 files | released after persisted indexes are ready |
| Query/index warmup | enabled | skipped |

The known response/read cache ceilings fall from roughly **108 MiB to 27 MiB**.
This is not total process RSS: file contents, symbols, word/trigram indexes,
snapshots, allocator state, and request buffers remain workload-dependent.

The profile does not change ranking, parser behavior, path security, sensitive
file filtering, telemetry behavior, result caps, or MCP schemas. Smaller caches
may rebuild results more often, and two-worker indexing can take longer than
four-worker indexing. Output remains the same. The development gate compares
full benchmark response hashes between default and Pi profiles; all 15 measured
tools matched on the fixed corpus.

## Worker override

To trade more startup speed for memory—or reduce memory further—set an explicit
global worker cap:

```bash
CODEDB_RESOURCE_PROFILE=pi CODEDB_WORKER_LIMIT=1 codedb /path/to/project mcp
```

`CODEDB_WORKER_LIMIT` applies to initial scanning, trigram/frequency builds, and
snapshot freshness checks. The existing `CODEDB_SCAN_WORKERS` variable remains
a phase-specific override for the initial scanner.

## Measure on the actual Pi

CPU, SD-card/SSD speed, kernel, filesystem, cooling, and repository shape all
matter. Run the included cold/warm peak-RSS probe on the target device:

```bash
CODEDB_PI_BENCH_OUT=zig-out/bench-pi \
  scripts/bench-pi.sh /path/to/representative/project
```

The script builds `ReleaseFast`, runs default and Pi profiles with isolated
homes, and writes GNU `time -v` output plus `report.md`. Install GNU time first
if needed:

```bash
sudo apt-get install time
```

For release-quality claims, repeat runs on an immutable corpus and report the
Pi model, RAM, storage, cooling, OS/kernel, Zig version, and whether the run was
cold or snapshot-backed.

## Practical Pi guidance

- Prefer a 64-bit OS; the published ARM binary is aarch64.
- Keep repositories and codedb state on SSD/USB storage when possible.
- Exclude generated build trees, dependency caches, and vendored artifacts that
  agents do not need to search.
- Keep a small zram/swap safety margin, but do not treat swap as a replacement
  for enough RAM.
- Use snapshots so restarts avoid full rescans.
- Monitor thermals during sustained indexing; CPU throttling can dominate
  benchmark results.
