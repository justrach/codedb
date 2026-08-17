# subagent sa-004-35daddce

- label: Audit index optimization
- kind: subagent
- status: ok
- elapsed_ms: 51692
- tools: bash,bash,bash!,bash,bash,bash,read_file,read_file,bash,codedb,codedb,bash,codedb,codedb,bash_output

## task

Audit the full PR diff origin/release/0.2.5829...61d977c in src/index.zig and src/test_index.zig. Focus on equivalence of rolling trigram logic to prior behavior across malformed/binary input, boundaries, signedness/overflow, incremental indexing, and performance. Do not edit. Return concrete findings with severity and lines; say if no blocker.

## report

## Audit result

**No blocker found.** The rolling trigram implementation is behaviorally equivalent to the prior scalar loop for valid text, malformed UTF-8, and arbitrary binary bytes.

### Findings

#### Low — whitespace-only inputs do extra normalization work
**`src/index.zig:1275-1276`**

`n3` is calculated before determining whether the current trigram is entirely whitespace:

```zig
const c3 = if (has_next) content[i + 3] else 0;
const n3 = if (has_next) normalizeChar(c3) else 0;
```

Previously, pure-whitespace windows executed `continue` before any normalization. Consequently, a whitespace-only file now performs approximately one `normalizeChar` call per window, whereas the prior loop performed none.

This does **not** alter output and is unlikely to be material because `normalizeChar` is a small ASCII range check. Rolling still reduces overlapping loads. However, whitespace-heavy or generated files are a performance corner case not represented by benchmark evidence in these two files.

**Severity:** Low / performance caveat, not a correctness blocker.

## Equivalence attacks performed

- **Boundaries:** Checked lengths 0, 1, 2, exactly 3, final windows, and `has_next` behavior. The guarded `content.len - 2` range cannot underflow, and the terminal sentinel values are shifted only after the final usable window.
- **Malformed/binary input:** All values remain `u8`; normalization only changes ASCII `A`–`Z`. NUL, `0xff`, malformed UTF-8, and other high bytes retain prior behavior.
- **Signedness and masks:**  
  - `i & 7` is equivalent to `i % 8` because `i` is unsigned `usize`.
  - `n3 & 7` is equivalent to `normalizeChar(...) % 8` because `n3` is unsigned `u8`.
  - Both shift counts remain in `0...7`; no signed conversion or shift overflow was introduced.
- **Overflow:** For every loop iteration, `i + 3` is representable. The greatest `i` is `content.len - 3`, making the greatest sum exactly `content.len`.
- **Whitespace handling:** The decision still uses raw bytes `c0..c2`, preserving the exact four-byte whitespace definition and avoiding accidental normalization effects.
- **Incremental/re-index behavior:** Rolling extraction feeds the same local map and leaves removal, document-ID reuse, sorted posting insertion, and `file_trigrams` replacement unchanged. Existing re-index tests also exercise this path.
- **Independent oracle:** `src/test_index.zig:650-667` reproduces the old scalar algorithm, and the test at approximately **lines 669-731** compares exact trigram key counts plus both masks. Fixtures include short boundaries, whitespace-only data, rollover positions, mixed case, NUL, and `0xff`.
- **Test execution:** `zig build test` completed successfully.
- **Diff hygiene:** No `git diff --check` issues were observed.

## Verdict

**Survives.** I found no counterexample that changes trigram keys, `loc_mask`, `next_mask`, or incremental indexing results. The only concrete concern is the low-severity extra normalization work for skipped whitespace windows. A blocker would have required a byte sequence or boundary where the rolling state diverged from direct indexing, or an incremental replacement retaining stale masks; neither is present.
