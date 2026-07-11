# codedb — Agent Instructions

## Project

Zig 0.17.0-dev code intelligence server (pinned to `0.17.0-dev.813+2153f8143`). Tests live in the split `src/test_*.zig` files — one binary per area (see `build.zig`). Build and test with `zig build test`; run a single binary with e.g. `zig build test-index`.

## Rules

### Filing Issues

**Every GitHub issue must include a failing test case.** No exceptions.

When creating an issue:

1. Write a `test "issue-XX: <description>"` block in the matching `src/test_*.zig` file (e.g. `src/test_index.zig` for index bugs) that **fails** on the current `main` branch
2. Verify it fails: `zig build test 2>&1 | grep "issue-XX"`
3. File the issue via `gh issue create` with this structure:
   - **Title:** `<module>: <concise description>`
   - **Body sections:** Problem, Failing Test (the zig test block), Expected, Fix
   - **Labels:** `bug` for defects, `priority:p0` for crashes, `priority:p2` for correctness
4. Commit the failing test on a branch: `issue-XX-failing-test`
5. Do **not** fix the bug in the same commit as the failing test

If you cannot write a failing test, the issue is not well-defined enough to file.

### Test Style

- Use `std.testing` and `testing.allocator`
- Use `std.heap.ArenaAllocator` for Explorer tests
- Always `defer` cleanup (arena.deinit, allocator.free)
- One test per issue, named `test "issue-XX: <short description>"`
- Keep tests minimal — only exercise the specific broken code path

### Code Style

- No comments or documentation changes unless explicitly asked
- Prefer minimal, targeted fixes over refactors
- Follow existing patterns in the module you're editing
