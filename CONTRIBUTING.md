# Contributing

Thanks for contributing to codedb.

This codebase moves quickly and spans Zig, benchmarks, and generated native artifacts. Small, current, issue-linked PRs are much easier to review and much less likely to regress behavior.

## Ground Rules

1. Every PR must be tied to an issue.
2. Rebase onto current `main` before requesting final review.
3. Keep PRs tightly scoped.
4. Do not commit generated artifacts.
5. Do not mix unrelated lockfile churn into bug-fix or perf PRs.

If a branch goes stale, close it and open a smaller replacement instead of accreting more changes onto the old PR.

## PR Requirements

Every PR description should include:

- linked issue number
- summary of the exact change
- files or subsystems touched
- tests run
- failing test, xfail, or exact repro that demonstrated the problem before the fix
- passing rerun of that same test or repro after the fix
- nearby non-regression checks proving the change did not just move the bug
- whether the branch was rebased onto current `main`
- whether any generated files, lockfiles, or benchmarks changed
- explicit confirmation that the submission matches `CONTRIBUTING.md`

If a PR does not map cleanly to an issue, open the issue first.

## Red-To-Green Rule

For bug fixes, compatibility fixes, runtime fixes, and perf regressions:

1. show the failing test, xfail, or exact repro first
2. make the code change
3. rerun the same test or repro and show it passing
4. run the closest neighboring tests to prove the fix did not just move the bug

If there is no failing test yet, write one first unless the failure is impossible to encode cleanly.

Examples of acceptable proof in a PR:

- `before`: `tests/test_async_handlers.py` showing the real remaining failure
- `after`: the same file rerun cleanly with updated expectations
- nearby guard: the closest compatibility or parity suite still passing

Or:

- `before`: exact `curl`, request, or benchmark command and failing output
- `after`: the same command with corrected output
- nearby guard: targeted tests proving adjacent behavior still works

## Scope Rules

Good PR scope:

- one bug fix
- one benchmark methodology fix
- one small perf change
- one docs-only clarification

Bad PR scope:

- runtime change + unrelated refactor
- perf tweak + dependency upgrade
- feature work + generated `.zig-cache` / `zig-out` output
- benchmark change + marketing/docs rewrite + lockfile churn

If a reviewer cannot explain the PR in one sentence, it is probably too large.

Default rule: keep each PR under **500 changed lines** total unless there is a clear reason not to. If a larger PR is unavoidable, call that out explicitly in the PR body and justify why it was not split.

## Rebase Policy

Before requesting review on any non-trivial PR:

```bash
git fetch origin
git rebase origin/main
```

Why this matters:

- stale cleanup PRs can delete code that is no longer dead
- stale bug-fix PRs often miss newer behavior in `main`
- stale perf PRs become impossible to evaluate fairly

If rebasing reveals unrelated conflicts, split the PR.

## CI Before Review

For runtime, compatibility, middleware, security, and perf-sensitive changes, run the narrowest relevant local checks before requesting review and include the commands/results in the PR body.

At minimum:

- the exact failing repro or test from before the fix
- the passing rerun after the fix
- the closest neighboring non-regression checks

If the branch changes behavior that normally goes through GitHub Actions, do not request final review until the branch-level CI signal is green or any remaining failures are clearly explained in the PR description.

## Generated Files

Do not commit generated or local-build artifacts, including:

- `.zig-cache/`
- `zig-out/`
- `.dylib`, `.so`, `.o`
- local benchmark artifacts/logs unless the PR is explicitly about publishing benchmark evidence

If a file is generated during local builds, add or update `.gitignore` instead of committing it.

## Tests

At minimum, run the narrowest relevant tests for the code you changed.

Examples:

```bash
zig build test
```

For fixes, do not just say "tests passed".

Show:

- the failing command before the fix
- the passing command after the fix
- at least one neighboring or regression-guard command

If you changed benchmarks:

- state whether the run was local or CI
- include exact machine/environment details
- do not mix local Apple Silicon numbers with GitHub Actions Ubuntu numbers

## Benchmark PRs

Benchmark-related PRs must say:

- what layer is being measured
  - driver-only
  - HTTP-only
  - end-to-end HTTP+DB
- whether caches are on or off
- whether numbers are cold-start or warmed steady-state
- number of runs
- whether values are single-run or median
- exact machine or CI environment

Do not publish cached results as uncached DB performance.

## Review Expectations

Reviewers will push back on:

- stale branches
- unrelated file churn
- generated artifacts
- oversized PRs
- missing issue links
- claims that do not match the changed code

That is process, not hostility.

The easiest way to get a fast review is:

1. open an issue
2. make a small branch
3. rebase onto `main`
4. keep the diff narrow
5. include exact tests and rationale
