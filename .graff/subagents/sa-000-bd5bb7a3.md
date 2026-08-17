# subagent sa-000-bd5bb7a3

- label: Probe language edge cases
- kind: subagent
- status: ok
- elapsed_ms: 358400
- tools: codedb,codedb,bash,codedb,codedb,codedb,bash,bash,bash,bash,bash,bash,bash,bash,bash,bash,bash,bash,bash,bash,bash,bash,bash,bash,bash,bash,codedb,codedb,codedb,codedb,bash,bash,bash,bash,bash,bash,codedb,bash,bash,bash,bash,bash,bash

## task

HARD CONSTRAINTS (user, do not violate):
- When discussing this release, describe only the latest unreleased changes just pushed, not v0.2.5837.

Adversarially inspect ONLY origin/main..origin/release/0.2.5833-mcp2026 in the codedb repo (PR #683). Do not edit. Focus on line-comment detection across every language in the switch, strings/escapes, shell # syntax, URLs, SQL/Fortran/LLVM/HCL, and cases where a comment marker appears before or after a real call. Determine whether the implementation can create false positives or false negatives that should block release. Give reproducible examples and file:line evidence. Ignore v0.2.5837.

## report

## Scope

Inspected only `origin/main..origin/release/0.2.5833-mcp2026` for PR #683. No files were edited.

The change filters `codedb_callers` results using:

- `src/mcp.zig:2567-2587` — language check, comment/blank check, prefix extraction, whole-word match.
- `src/mcp.zig:2664-2683` — `hasWholeWordMatchOutsideStrings`.
- `src/mcp.zig:2696-2725` — `lineCodePrefix`.
- `src/mcp.zig:2727-2740` — quote scanner.
- Tests added at `src/test_mcp.zig:3788-3838` cover only Zig trailing comments, a quoted URL, and a mixed string/code line.

## Release-blocking counterexamples

### 1. PHP, Swift, and OCaml are omitted from the comment-marker switch

`lineCodePrefix` falls through to the complete line for these languages:

```text
src/mcp.zig:2697-2704
```

However, they are detected as real languages and are not excluded from caller searches:

```text
src/explore.zig:171-206
src/explore.zig:208-246
src/mcp.zig:2742-2750
```

Reproducible false positives:

```php
// x.php:1
echo 1; // renderX()
```

```swift
// x.swift:1
print("x") // renderX()
```

```ocaml
(* x.ml:1 *)
let x = 1 (* renderX() *)
```

For each, `isCommentOrBlank` returns false because the line starts with code, `lineCodePrefix` returns the whole line, and the whole-word matcher finds `renderX`.

### 2. Mid-line block comments produce both false positives and false negatives

The new switch only recognizes line markers. For C-like languages it includes `//`, but deliberately does not parse `/* ... */`:

```text
src/mcp.zig:2697-2705
src/mcp.zig:2691-2695
```

False positive:

```c
// x.c:1
init(); /* renderX() */
```

The mention is entirely inside a trailing block comment, but the whole line is searched.

False negative when a marker appears inside a block comment before a real call:

```c
// x.c:1
/* explanatory // comment */ renderX();
```

`lineCodePrefix` sees the `//` inside the block comment and truncates the line before the real call.

The same pattern applies to SQL and HCL:

```sql
SELECT 1 /* note -- */; SELECT renderX();
```

```hcl
value = 1 /* note // */ renderX()
```

This directly violates the intended “marker before or after a real call” behavior.

### 3. Backticks are not treated as strings, causing URL-related false negatives

The implementation explicitly does not treat backticks as quote delimiters:

```text
src/mcp.zig:2661-2663
src/mcp.zig:2707-2713
```

That preserves JavaScript template interpolation calls, but breaks when template text contains a URL:

```javascript
// x.js:1
const s = `https://example.test/${renderX()}`;
```

The `//` in `https://` is mistaken for a comment marker. `lineCodePrefix` returns before `${renderX()}`, so the real call is missed.

The same problem occurs with valid Go raw strings:

```go
// x.go:1
s := `https://example.test/`; renderX()
```

The URL’s `//` truncates the line before the real call.

A raw-string-only false positive is also possible:

```go
// x.go:1
s := `renderX()`
```

The line is data, not a call, but backticks are ignored and the whole-word matcher reports it.

### 4. Multiline literals are invisible to the line-local scanner

The implementation is explicitly line-local:

```text
src/mcp.zig:2691-2695
src/mcp.zig:2727-2740
```

A line inside a multiline literal has no quote on that line and is therefore treated as code.

False positive in Python:

```python
# x.py:1
"""
# x.py:2
renderX()
# x.py:3
"""
```

Line 2 is documentation text, but it is not blank or a full-line `#` comment and is reported as a caller.

Equivalent cases exist for Java/Kotlin text blocks, C++ raw strings, Dart triple-quoted strings, shell heredocs, HCL heredocs, and other multiline literal forms.

Shell heredoc example:

```sh
# x.sh:1
cat <<EOF
# x.sh:2
renderX()
# x.sh:3
EOF
```

Line 2 does not execute `renderX`, but the implementation reports it.

### 5. String interpolation calls are incorrectly discarded

`hasWholeWordMatchOutsideStrings` skips the entire quoted span:

```text
src/mcp.zig:2668-2672
```

That misses actual calls embedded in language interpolation syntax.

Python:

```python
# x.py:1
message = f"result: {renderX()}"
```

Shell:

```sh
# x.sh:1
echo "$(renderX)"
```

HCL-style interpolation has the same shape:

```hcl
# x.tf:1
description = "prefix ${renderX()}"
```

These are not ordinary inert string mentions in their respective languages; the interpolation expression executes code. The generic quote scanner cannot distinguish that.

### 6. Quote escaping is language-incorrect for SQL and Fortran

`stringLiteralEnd` only understands backslash escaping:

```text
src/mcp.zig:2729-2739
```

SQL and Fortran escape embedded quotes by doubling them.

SQL false negative:

```sql
-- x.sql:1
SELECT 'It''s --', renderX();
```

The scanner treats the first quote of `''` as the end of the string, then sees the `--` that is actually inside the string and truncates before `renderX()`.

Fortran false negative:

```fortran
! x.f90:1
print *, 'It''s !', renderX()
```

The same bug occurs with `!` inside the Fortran string.

The ordinary URL test added in `src/test_mcp.zig:3808-3821` does not exercise doubled-quote escapes, raw strings, heredocs, interpolation, or multiline state.

### 7. Shell `#` detection is too narrow

The shell special case only accepts a comment marker at column zero or after a space/tab:

```text
src/mcp.zig:2714-2719
```

But shell punctuation can delimit a new word. This is a valid shell comment:

```sh
# x.sh:1
echo hi;# renderX()
```

The implementation sees the preceding `;`, decides `#` is not a comment, and reports `renderX()` as a caller.

The same issue can occur after other shell operators that begin a new word.

## What survived

The narrow cases covered by the added tests do work:

```zig
init(); // renderX()
fetch("https://x", renderX);
foo("msg", renderX);
```

The quote scanner also handles ordinary backslash-escaped quotes reasonably for C-like strings. That is insufficient because the implementation is shared across languages with incompatible string, interpolation, heredoc, raw-string, and comment rules.

## Verdict: **refuted**

The implementation can create both false positives and false negatives in release-supported caller searches. The strongest blockers are:

1. PHP/Swift/OCaml trailing comments are not recognized at all.
2. Block-comment markers can hide a real call or allow a commented mention through.
3. URLs in backtick/raw strings can hide real calls.
4. Multiline literals and heredocs are reported as callers.
5. SQL and Fortran doubled-quote escaping causes real calls after embedded comment text to be missed.

These are reproducible correctness failures across the language switch and should block release.
