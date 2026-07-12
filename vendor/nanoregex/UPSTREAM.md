# Vendored source provenance

This directory is vendored from [`justrach/nanoregex`](https://github.com/justrach/nanoregex) at commit:

```text
736b46703454d5f37d3e46164fc91354386bb29c
```

It was the dependency previously pinned by codedb's `build.zig.zon`. The local changes are limited to Zig `0.17.0-dev.813+2153f8143` compatibility: removed repetition syntax was replaced with typed `@splat`, the package minimum was updated, and the touched build/source files were canonicalized by that Zig snapshot's formatter (format-only whitespace/layout changes). Keep the upstream MIT `LICENSE` file when updating this copy.

To verify after an update:

```bash
cd vendor/nanoregex
zig build test-all
zig build parity
```
