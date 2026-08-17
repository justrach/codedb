# subagent sa-005-2f1bdcdf

- label: judge
- kind: judge_task
- status: ok
- elapsed_ms: 18798
- tools: bash,bash

## task

An agent variant ran the task below as part of the "Migration review" phase of a workflow.
Judge how well its OUTPUT accomplishes the TASK, on a 0-100 scale. Be
discriminating: reward correctness, completeness, and usefulness; penalize
hand-waving, non-answers, and ignored requirements. Do not reward length.

TASK:
Audit docs/zig-0.17-migration.md plus README/build.zig.zon/.github workflow changes for accuracy and reproducibility. Check zigup commands, pinned download URLs, Zig 0.17 API recipes, CI consistency, and overlooked old-version references that matter. Do not edit. Report concrete issues by severity.

VARIANT OUTPUT:
udit needs at least YAML and all supported old versions, while excluding historical results and dependency/cache directories deliberately.

---

#### 10. CI runner selection is not fully pinned
**File:** `.github/workflows/bench-regression.yml:14`

`ubuntu-latest` is moving. Benchmark regression results are sensitive to runner image and hardware changes, so this weakens reproducibility and can create false regressions. The release workflow uses `ubuntu-24.04`, which is more consistent. Bench CI should likewise use an explicit runner image, though GitHub-hosted hardware still cannot be perfectly pinned.

---

## Checks that survived attack

- The three pinned Zig archive URLs tested—x86_64 Linux, x86_64 macOS, and aarch64 macOS—currently return HTTP 200.
- The archive naming convention and `/builds/` location are correct for this development snapshot.
- The Linux arm64 release entry intentionally downloads the x86_64 Linux **host compiler** and cross-compiles with `-Dtarget=aarch64-linux`; this is not an archive-selection bug.
- The documented zigup `fetch`, `default`, and `keep` forms match the installed `marler8997/zigup` CLI.
- The main project successfully completed `zig build --summary all` with `0.17.0-dev.813+2153f8143`.
- The reviewed 0.17 recipes—`addPassthruArgs`, `@splat`, `bufPrintSentinel`, `std.Io.Writer.Allocating`, emitted-artifact lazy paths, and public stream reads—are consistent with the pinned compiler and migrated code.
- The vendored `nanoregex` package also declares the same minimum Zig snapshot.

## Final verdict

**Refuted.** The code builds with the stated snapshot and the URLs are live, but the claimed reproducibility is broken by unverified compiler downloads, a release compiler that is independent of the checked-out tag, an incomplete zigup bootstrap, moving-version language in README, duplicated/unused CI pins, and several active old-version requirements.

[subagent sa-002-a8c35981 · inspect: .graff/subagents/sa-002-a8c35981.md]

Inspect any files the work references if you need to, then end your reply
with a single final line `score: <N>` where N is an integer from 0 to 100.

## report

The output is severely truncated: it begins mid-sentence and omits issues 1–9 almost entirely. As presented, it reports only one fully described low-severity issue (`ubuntu-latest`) and a fragment of another. The final verdict references serious findings—unverified downloads, tag/compiler mismatch, incomplete zigup bootstrap, unused pins, and stale version requirements—without giving locations, evidence, or severity in the visible output.

The surviving checks are useful and address several requested areas: archive availability, zigup command validity, build success, API recipe compatibility, cross-compilation intent, and dependency version consistency. The visible runner-pinning observation is also accurate. However, these validations cannot compensate for the missing concrete issue report, especially since the task explicitly requested issues organized by severity.

score: 27
