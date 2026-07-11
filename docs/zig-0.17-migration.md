# Migrating a Zig project to 0.17.0-dev with zigup

This guide records the migration process used for codedb and is intended to be reusable in other Zig repositories.

The tested compiler is:

```text
0.17.0-dev.813+2153f8143
```

Zig development snapshots are moving targets. Pin the full version (including the build metadata) in CI and local setup while migrating. Upgrade to a newer snapshot deliberately, rerun the full matrix, and update the pin only after it passes.

## 1. Establish a baseline

Before changing compilers:

```bash
git status --short
zig version
zig build
zig build test
```

Record existing failures and preserve unrelated working-tree changes. If the project has benchmarks, capture the benchmark-critical results before migration so regressions can be compared against a real baseline.

## 2. Install and select the compiler with zigup

This guide uses [`marler8997/zigup`](https://github.com/marler8997/zigup), not an unrelated tool with a similar name. On a clean machine, install a pinned zigup release from its [release assets](https://github.com/marler8997/zigup/releases), verify the downloaded asset against the checksum recorded by your organization, put the binary on `PATH`, and confirm `zigup help` works. Avoid piping a remote installer directly into a shell.

Install/select the exact compiler used by codedb:

```bash
zigup fetch 0.17.0-dev.813+2153f8143
zigup default 0.17.0-dev.813+2153f8143
zigup keep 0.17.0-dev.813+2153f8143
zig version
```

`zigup default` displays the selected version when called without an argument. `zigup keep` is optional; it only prevents a later `zigup clean` from deleting the pinned compiler. Do not use `zigup --version`: zigup treats positional input as a requested Zig version rather than exposing that conventional flag.

For exploratory work, `zigup master` selects the latest development compiler. Do not use a moving `master` selection in CI or release automation.

In CI, download the exact host archive from `https://ziglang.org/builds/`, verify a repository-pinned SHA-256 before extraction, and assert that `zig version` equals the pin. A versioned URL alone does not protect a privileged release job from replaced or compromised bytes.

## 3. Pin the package minimum

Update `build.zig.zon`:

```zig
.{
    // ...
    .minimum_zig_version = "0.17.0-dev.813+2153f8143",
}
```

A full development build pin makes the tested compiler explicit. If a library intentionally supports a wider range of 0.17 snapshots, lower the minimum only after testing the oldest claimed snapshot.

## 4. Migrate the build graph first

Run `zig build` and fix `build.zig` errors before source errors. Zig configures dependency build scripts too, so an incompatible transitive `build.zig` can stop the build before your own source is compiled.

### Forward arguments with `addPassthruArgs`

The `Build.args` field was removed.

Before:

```zig
const run = b.addRunArtifact(exe);
if (b.args) |args| run.addArgs(args);
```

After:

```zig
const run = b.addRunArtifact(exe);
run.addPassthruArgs();
```

This preserves commands such as:

```bash
zig build run -- --help
```

Apply the same change to benchmark and utility run steps.

### Use lazy paths instead of `getInstallPath`

`b.getInstallPath` was removed. Prefer artifact and lazy-path APIs so the build graph can track dependencies.

For a command that operates on the compiled executable:

```zig
const command = b.addSystemCommand(&.{ "tool", "--flag" });
command.addFileArg(exe.getEmittedBin());
install_artifact.step.dependOn(&command.step);
```

For codesigning, codedb signs the emitted artifact and makes installation depend on the signing step. Avoid constructing `zig-out` paths manually because `--prefix` and cross-target installation can change them.

## 5. Replace removed repetition syntax

The `value ** count` array/string repetition syntax is gone. Use `@splat` with a result type supplied by the destination.

### Arrays

Before:

```zig
var flags: [256]bool = [_]bool{false} ** 256;
var matrix: [256][256]u64 = .{.{0} ** 256} ** 256;
```

After:

```zig
var flags: [256]bool = @splat(false);
var matrix: [256][256]u64 = @splat(@splat(0));
```

### Repeated byte data

Before:

```zig
const payload = "x" ** 300;
consume(payload);
```

After:

```zig
const payload: [300]u8 = @splat('x');
consume(&payload);
```

Zig 0.17 no longer implicitly coerces an array value to a slice in this case; use `&payload` when the callee expects `[]const u8`.

### Inline fixed buffers

Give `@splat` an explicit array type when no destination type is available:

```zig
try writer.writeAll(&@as([40]u8, @splat(0)));
```

A useful first-pass search is:

```bash
grep -R -n ' \*\* ' src --include='*.zig'
```

Review matches rather than replacing blindly: glob documentation and comments legitimately contain `**`.

## 6. Replace `bufPrintZ`

`std.fmt.bufPrintZ` became `std.fmt.bufPrintSentinel`:

```zig
const path_z = try std.fmt.bufPrintSentinel(&buf, "{s}", .{path}, 0);
```

For a large codebase, a compatibility helper keeps the migration focused:

```zig
pub fn bufPrintZ(
    buf: []u8,
    comptime fmt: []const u8,
    args: anytype,
) std.fmt.BufPrintError![:0]u8 {
    return std.fmt.bufPrintSentinel(buf, fmt, args, 0);
}
```

Call sites can then move to the helper without changing their return types.

## 7. Stop calling unstable I/O vtable fields directly

The direct `io.vtable.netRead` field is no longer available. Use the public stream operation:

Before:

```zig
var iov: [1][]u8 = .{dest};
const n = try io.vtable.netRead(io.userdata, stream.socket.handle, &iov);
```

After:

```zig
var iov: [1][]u8 = .{dest};
const n = try stream.read(io, &iov);
```

The public method routes through `Io.operate` and remains compatible with the selected backend. Treat direct vtable access as an implementation detail unless the standard library explicitly documents it as public API.

## 8. Update allocating writers and freestanding targets

The unmanaged `ArrayList(u8).writer(allocator)` helper is no longer available. Use `std.Io.Writer.Allocating` when the output is fundamentally a byte stream:

```zig
var out: std.Io.Writer.Allocating = .init(allocator);
defer out.deinit();
const writer = &out.writer;
try writer.print("value={d}", .{value});
const bytes = try out.toOwnedSlice();
```

`toOwnedSlice()` resets the allocating writer, so the deferred `deinit()` is safe after ownership transfers.

Compile every freestanding/WASM target separately. A native build can hide target-specific problems:

- baseline `wasm32` supports atomic integers only up to 32 bits in this toolchain; use 32-bit counters/generations when wraparound is acceptable, or explicitly choose and validate a WebAssembly threads/atomics target;
- guard filesystem, subprocess, environment, mmap, clock, and pthread paths with `builtin.os.tag == .freestanding`;
- provide no-op locks only where the target is intentionally single-threaded;
- avoid reaching `std.posix` or libc declarations from exported WASM call graphs.

Use a larger reference trace to locate an unexpected host-only dependency:

```bash
zig build wasm -freference-trace=20
```

## 9. Audit every dependency

A project is not migrated if a clean checkout still depends on a package whose build script or source requires an older compiler.

For each dependency:

1. Run its own tests under the pinned compiler.
2. Prefer an upstream 0.17-compatible release or immutable commit.
3. If no compatible release exists, temporarily vendor or fork it.
4. Preserve its license and source history/attribution.
5. Point `build.zig.zon` at the reproducible source, not a patched local cache.
6. Add the vendored directory to the root package's `.paths` if releases must include it.

Example local dependency:

```zig
.dependencies = .{
    .some_library = .{
        .path = "vendor/some-library",
    },
},
.paths = .{
    "src",
    "vendor/some-library",
    "build.zig",
    "build.zig.zon",
},
```

Never treat edits inside `.zig-cache`, a global package cache, or an ignored dependency cache as the final fix. They make only one workstation pass.

For codedb, `nanoregex` is vendored until its upstream package is 0.17-compatible. The previous `mcp-zig` dependency supplied only small protocol-neutral JSON helpers and a root value type, so those helpers were moved into codedb instead of retaining a second server-framework dependency.

## 10. Format narrowly while iterating

During the error-fixing loop, format only touched files:

```bash
zig fmt build.zig build.zig.zon src/file_you_changed.zig
```

A new Zig formatter can produce repository-wide canonical-format changes. Run `zig fmt src` only when that churn is intentional, and review the diff separately from semantic migration changes.

## 11. Verify in layers

Use a narrow-to-wide loop:

```bash
# Build graph and main executable
zig build

# Individual project steps while iterating
zig build test-core
zig build test-mcp

# Full unit suite
zig build test

# Optional targets your project publishes
zig build wasm
zig build -Doptimize=ReleaseFast
```

For codedb, MCP changes also require:

```bash
zig build test
python3 scripts/e2e_mcp_test.py \
    --binary zig-out/bin/codedb \
    --project "$PWD"
```

The E2E suite checks root handshakes, normal explicit-root startup, and no-roots-client behavior. Run target/platform CI after local verification, especially Windows and cross-compiled release targets whose code may be skipped on the host.

## 12. Diagnose nested build failures

Tests that invoke `zig build` may report only that a child process exited nonzero. Run the nested command directly to expose the compiler diagnostic:

```bash
zig build
zig build test-mcp
```

Also check for stale assumptions in test helpers, CI images, release workflows, editor configuration, and documentation. Search for the old version string and removed API names:

```bash
grep -R -n '0\.16\|b\.args\|getInstallPath\|bufPrintZ\|vtable\.netRead' \
    --include='*.zig' --include='*.zon' --include='*.md' .
```

## Completion checklist

- [ ] Exact Zig development snapshot selected and recorded
- [ ] `build.zig.zon` minimum updated
- [ ] Build graph compiles without deprecated/removed APIs
- [ ] Source repetition syntax migrated to `@splat`
- [ ] Sentinel formatting calls migrated
- [ ] Public I/O operations replace direct vtable access
- [ ] Every dependency builds from a clean, reproducible source
- [ ] `zig build` passes
- [ ] `zig build test` passes
- [ ] Optional targets and release modes pass
- [ ] Project-specific E2E tests pass
- [ ] CI, README, and contributor setup reference the pinned compiler
- [ ] Diff reviewed for unrelated formatter churn and pre-existing work preserved

## codedb 0.2.5829 implementation record

This section records the concrete release changes behind the reusable guidance
above. It is intentionally explicit so a future compiler upgrade can distinguish
compatibility edits from retrieval-sensitive performance work.

### Toolchain, build, and release automation

| Area | Files | Change |
|---|---|---|
| Compiler/package pin | `build.zig.zon`, `README.md`, `.github/copilot-instructions.md`, `docs/agents.md` | Require the exact tested `0.17.0-dev.813+2153f8143` snapshot. |
| Build graph | `build.zig` | Replace removed argument and install-path APIs, keep benchmark argument forwarding, and preserve codesign/install dependencies through emitted lazy paths. |
| CI and releases | `.github/workflows/bench-regression.yml`, `.github/workflows/release-binaries.yml` | Download verified pinned compilers and assert `zig version`. Release targets use the 0.17 snapshot; transition benchmarks select 0.16 or 0.17 from each revision's `minimum_zig_version` so the cross-compiler regression gate cannot silently skip its base. |
| Dependencies | `build.zig.zon`, `vendor/nanoregex/`, `src/mcp_json.zig` | Vendor the compatible regex implementation and internalize the small JSON protocol helpers formerly taken from `mcp-zig`. |

### Runtime compatibility inventory

- `src/cio.zig` adapts sentinel formatting and Zig I/O entry points while
  retaining POSIX/Windows behavior.
- `src/main.zig`, `src/cli_proxy.zig`, `src/commands.zig`, `src/server.zig`, and
  `src/mcp.zig` adapt argv and stream handling. Parsed arguments borrow the
  process-lifetime bootstrap argv; they are not retained beyond that lifetime.
- `src/explore.zig`, `src/hot_cache.zig`, `src/codegraph.zig`,
  `src/snapshot.zig`, and `src/telemetry.zig` use target-compatible atomics,
  writers, and host-operation guards. Freestanding/WASM builds do not enter
  filesystem, process, telemetry, or mmap paths.
- Removed repetition syntax was converted to typed `@splat` expressions across
  runtime and tests. Large fixtures that only encoded compiler-stress behavior
  were reduced or removed where Zig 0.17 no longer accepts the old construct;
  retrieval assertions were retained in focused suites.
- `src/wasm.zig` uses a 32-bit generation on baseline `wasm32` and keeps native
  64-bit generations elsewhere, preserving cache-invalidation behavior within
  each target's supported atomic widths.

### Performance changes and invariants

1. **Exact-word deduplication (`src/index.zig`).** Valid posting lists are sorted
   by `(doc_id, line_num)`, so `searchDeduped` writes directly into one
   caller-owned allocation and removes adjacent duplicates. It detects any
   ordering break before returning and reruns the complete list through the old
   hash-dedup contract. The fallback preserves first-occurrence ordering for
   malformed, legacy, and incrementally fragmented data.
2. **Tier-0 document aggregation (`src/explore.zig`).** A nondecreasing posting
   list guarantees one contiguous run per document, allowing direct result
   construction without a slots array or hash map. Nonmonotonic lists use the
   defensive pre-migration aggregation path. Scores, line selection, ranking,
   and caps are not changed.
3. **Word-index lock lifetime (`src/explore.zig`).** The common completed-index
   path keeps its original shared lock. Only an incomplete index releases the
   lock for exclusive rebuild and reacquires it before lookup.
4. **Release startup (`src/main.zig`).** Debug keeps the 64MB worker-stack
   trampoline. Optimized builds run the measured approximately 190KB frame on
   the process stack, removing worker creation/join overhead. Mainstream native
   process stacks have ample headroom; constrained-stack targets should retain
   or reintroduce the trampoline after target-specific validation.
5. **Worker directory reuse (`src/watcher.zig`).** Initial-scan and trigram-shard
   workers open the project root once and pass the directory handle through file
   reads instead of reopening it per file. Every worker closes its own handle;
   root-open failures follow the existing null-result/error publication paths.
6. **Rolling trigram extraction (`src/watcher.zig`).** Shared extraction rolls
   `c0..c3` and normalized `n0..n3`, loading and normalizing each incoming byte
   once. It preserves whitespace-triple suppression, case folding, location and
   following-character masks, and the no-next-byte boundary on the final
   trigram.
7. **Persistence invariants (`src/index.zig`).** Trigram posting insertion keeps
   doc IDs sorted after ID reuse, and disk remapping follows ascending in-memory
   IDs. Streamed writes preserve mmap merge/binary-search ordering requirements.

### Reproducible A/B result

Baseline and candidate:

- baseline: clean `428d8df`, Zig 0.16.0, native arm64 `ReleaseFast`;
- candidate: Zig 0.17 migration plus the optimizations above, compiler
  `0.17.0-dev.813+2153f8143`, native arm64 `ReleaseFast`;
- corpus: immutable 631-file `git archive` of the baseline, outside the working
  repository;
- direct queries: 20 alternating A/B pairs, 200 iterations per query;
- CLI: Hyperfine, 5 warmups, 40 measured runs, isolated `HOME` and cache,
  `CODEDB_ALLOW_TEMP=1`, `CODEDB_NO_CLI_DAEMON=1`, and
  `CODEDB_NO_TELEMETRY=1`.

| Layer | Zig 0.16.0 | Zig 0.17 optimized | Result |
|---|---:|---:|---:|
| Cold single-token CLI | 127.0 ± 26.0ms | 105.7 ± 10.7ms | 1.20× faster |
| Warm snapshot CLI | 117.2 ± 27.8ms | 102.8 ± 13.3ms | 1.14× faster |
| Exact-word geometric mean | — | — | 3.217× faster |
| All direct queries geometric mean | — | — | 1.405× faster |
| Search-only geometric mean | — | — | 1.007× faster |
| Symbol geometric mean | — | — | 1.013× faster |
| Generic full initial scan, median | 166ms | 169ms | 1.8% slower |

Hyperfine identified outliers in both CLI samples, so means are reported with
standard deviation and should not be interpreted as deterministic single-run
latency. Direct-query hit counts were asserted equal. The generic initial-scan
gap is dominated by parse plus serial commit; changing that ownership/pipeline
is a separate, higher-risk project rather than a compatibility migration.

### Retrieval-parity gates

The release requires all of the following before tagging:

- exact ordered output parity between grouped Tier-0 postings and semantically
  equivalent fragmented postings that force the defensive fallback;
- duplicate suppression for naturally built and malformed/non-adjacent word
  postings, including first-occurrence order;
- exact trigram candidate and posting-mask parity between canonical extraction
  and worker-sharded rolling extraction, including 3-byte input, whitespace,
  mixed case, location-bit rollover, and final `next_mask` boundaries;
- sequential/parallel initial scan and word-shard parity;
- heap, persisted, and mmap trigram candidate parity after file removal/doc-ID
  reuse;
- lazy word-index rebuild parity with an eagerly complete index;
- the full Zig test suite and MCP E2E scenarios from the project instructions.

These are retrieval-quality checks, not only crash or hit-count checks: ordered
paths, line numbers/text, scores where applicable, candidate sets, and mask
metadata must remain equal.
