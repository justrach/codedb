# macOS watcher CPU: issue #748

Reproduced locally from release commit `4eaca89` (0.2.5854), using
[`repro_watcher_748.py`](../scripts/repro_watcher_748.py). See
[the original report](https://github.com/justrach/codedb/issues/748).

## Reproduction

On macOS, build separate, stable ReleaseFast binaries for the baseline and
candidate. Keep them outside `zig-out`: the unit suite rebuilds that path.

```sh
zig build -Doptimize=ReleaseFast --prefix /absolute/path/to/build
python3 scripts/repro_watcher_748.py \
  --binary /absolute/path/to/build/bin/codedb \
  --seconds 20 --out /absolute/path/to/results.json
```

The runner makes a disposable Git repository under `~/tmp` with 1,200 directories
and 4,800 Python files, beyond the default 1,024-vnode budget. It initializes an
explicit-root MCP server, waits for `scan: ready`, then measures two windows
(twenty seconds each in the release comparison; ten by default): quiet, followed
by creating/deleting a root-level `.lock` file about
every 20ms. It makes no retrieval calls during either window. CPU is the process
CPU-time delta from macOS `ps`, divided by elapsed wall time; 100% is one core.
It asserts that the reported file count and sequence stay unchanged.

A first non-Git scratch run also showed high CPU, but its sequence changed;
that run is excluded from the comparison. The recorded fixture uses Git and
ignores generated snapshot/archive files so those do not muddy the result.

## Diagnosis and patch

The baseline inserts all watch-overflow paths into the actual dirty set on every
event or timeout. That bypasses exact metadata checks and reads/hashes unchanged
files. A kqueue timeout is only a maximum wait: unrelated directory events can
repeat this work continuously.

The patch keeps the descriptor ceiling and changes reconciliation:

- Overflow verification runs on a monotonic two-second cadence. It still
  reads/hashes overflow files, including same-metadata rewrites on coarse or
  remote filesystems. Those invalidations never enter native-event rearming.
- Event bursts are coalesced over 100ms. This is bounded waiting, so continuous
  churn cannot indefinitely postpone a real change.
- The event pass returns immediately for an empty set. A validated, unchanged
  directory outside event ancestry can preserve its descendants without opening
  them when no inherited ignore rules or symlink aliases require the broader walk.
- Empty cached directories participate in the parent index, allowing the first
  file created inside them to become visible.
- Failed directory-watch admissions are retried separately from file dirtiness.
  Root policy metadata is checked even without OS events, including
  `.git/info/exclude`, which lives outside the watched tree.

This is a conservative CPU fix, not the end of watcher optimization. The regular
directory audit remains approximately every two seconds to preserve discovery
of nested ignore-policy changes and aliases. Overflow still requires periodic content
verification; ignore-bearing trees retain conservative traversal. Event passes still
build a parent index in memory, and root directory events must inspect entries.
Each MCP process still owns a watcher. A shared watcher or persistent directory
index is separate follow-up work; increasing the descriptor cap is not the fix.

## Validation

The new issue-748 regression checks zero filesystem work for an empty event pass,
bounded directory opens under skipped-file churn, metadata-only helper behavior,
edits/additions/deletions without OS events, first-file
discovery in an empty directory, and observation of excluded policy changes.
Existing atomic-replacement and sensitive-file tests exercise the event entry
point. The same-metadata rewrite regression from PR #747 covers both file and
parent-directory fallback. The normal suite also covers descriptor bounds and
watch rearming.

Run `zig build test` and the existing MCP end-to-end suite before integration:

```sh
python3 scripts/e2e_mcp_test.py \
  --binary /absolute/path/to/stable/codedb \
  --project /absolute/path/to/codedb
```

Measurements and final validation are recorded below. These are short synthetic
observations on an Apple M4 Pro / macOS 26.6.2, not a general CPU guarantee.


The earlier candidate measured 3.3% quiet / 22.7% churn CPU but omitted periodic
hash verification. That candidate is withdrawn: matching metadata can hide a
rewrite on coarse or remote filesystems. The release measurements below restore
the two-second content verification.

## Release 0.2.5855 results

| Phase | Baseline CPU | Release candidate CPU |
| --- | ---: | ---: |
| Quiet | 6.64% | 6.84% |
| Churn | 99.79% | 23.54% |

Churn CPU fell about 76% in this candidate-then-baseline comparison. Both use
the same generator with 4,800 source files; each held its own reported file
count and sequence unchanged. Total indexed counts differed by one (4,802 versus
4,801); that extra entry was not isolated, so this is not an exact equal-index trial. Churn rates were close: 40.5 versus 40.9
create/delete pairs per second. Quiet CPU differed by 0.20 percentage points
(about 3% relatively); these short synthetic windows do not establish general
performance bounds. Telemetry and automatic updates were disabled in both runs.

Receipts: [baseline](measurements/watcher-748-baseline.json) and
[release candidate](measurements/watcher-748-candidate.json). The candidate is
built from the combined release runtime at `9f4e9e4` (PR #747 plus this patch),
with a stable ReleaseFast binary outside `zig-out`.

Validation on Apple Silicon macOS:

- Unit suite: 33/33 build steps succeeded; 1,415 tests passed, 13 skipped, with
  other groups cached. Includes the same-metadata fallback regression.
- Normal MCP end-to-end suite: 76/76 passed.
- Opt-in lazy lifecycle suite: all six scenarios passed.
- Lazy MCP plus HTTP file-boundary fixture: safe reads and directory aliases
  succeed; sensitive files, file symlinks, and external/traversal paths fail.
- Descriptor regression: 45 descriptors at both 128 and 2,048 files, budget 32.
- Updater resolution: four CLI scenarios and both worker suites passed.

Whitespace checks passed. `zig fmt --check` passes changed Zig files except the
pre-existing reference-array formatting in `src/mcp.zig`, unchanged from the
base; ranking code was left untouched. No installed client binary was replaced.

## Follow-up candidate after 0.2.5855

The release still hashes overflow files periodically. Profiling the larger
9,600-file fixture found approximately 40% churn CPU and 14% quiet CPU. Three
independent clients can multiply that work. This follow-up uses recursive
FSEvents on local APFS/HFS volumes, avoiding per-file overflow polling when the
stream covers the entire admitted tree. It uses the macOS system frameworks;
there is no additional package dependency.

The callback only copies bounded path notifications into a private queue.
Coalesced or dropped history triggers a full content audit. Root/mount changes,
directory aliases, foreign volumes, unsupported filesystems or an unavailable
stream use the existing bounded kqueue/polling path. Set
`CODEDB_NO_FSEVENTS=1` to force that fallback. Directory and ignore-policy audits
still run about every two seconds. Each MCP process still owns its watcher.

Reconciliation also reuses bounded content scratch storage and retains unchanged
subtrees when their identities and inherited ignore-policy metadata agree.
Root and nested policy edits invalidate descendants, including when an ignore
rule is later removed. A regression test uncovered an existing use-after-free
in deletion bookkeeping; the mtime entry is now removed before its borrowed
path is freed. Safe project-handle reads and sensitive-path exclusions remain
in place.

Use the stronger mutation harness alongside the CPU reproducer:

```sh
python3 scripts/stress_watcher_748.py \
  --binary /absolute/path/to/stable/codedb \
  --out "$HOME/tmp/watcher-events.json" --seconds 20
CODEDB_NO_FSEVENTS=1 python3 scripts/stress_watcher_748.py \
  --binary /absolute/path/to/stable/codedb \
  --out "$HOME/tmp/watcher-fallback.json" --seconds 20
```

The harness uses 4,800 source files in 1,200 directories, then checks same-size
edits with restored mtime, removal of old symbols, creation, rename, deletion
and discovery of new nested directories under continuous excluded-file churn.
The unit suite separately covers complete metadata collisions. Output paths
must be new; the runner records the immutable binary hash.

Final ARM64 candidate measurements (20-second windows, one core = 100%):

| Clients / watch budget | Quiet CPU | Churn CPU | Mutation checks |
| --- | ---: | ---: | ---: |
| Three / 32 | 2.00%, 1.50%, 1.35% | 1.80%, 1.70%, 1.75% | 61/61 across all three |
| One / 1,024 | 1.25% | 3.40% | 61/61 |

Index counts and sequences stayed unchanged under excluded churn. All clients
remained alive. These are short synthetic measurements, not general CPU or
memory guarantees. The earlier 9,600-file recursive-event prototype measured
3.15% churn / 2.65% quiet, but the table above is the final candidate's fixture.

Receipts: [recursive events](measurements/watcher-748-followup-final.json) and
[forced fallback](measurements/watcher-748-followup-fallback-final.json).

The final candidate passes the unit suite, 76/76 MCP scenarios and six lazy
startup scenarios. Descriptor counts are 23 at both 128 and 2,048 files with a
budget of 32. The Intel macOS build also starts its recursive stream and detects
an edit under Rosetta. Forcing the fallback also passes all 122 mutation checks
with stable counters (10-second CPU windows: three-client churn 13.19%, 13.09%,
11.79%; single-client churn 13.79%). Linux and Windows cross-builds succeed; they have not
been runtime-tested in this macOS session. This follow-up has not been released,
notarized or installed over a client binary.
