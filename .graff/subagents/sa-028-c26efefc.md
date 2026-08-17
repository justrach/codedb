# subagent sa-028-c26efefc

- label: Audit persistence path
- kind: subagent
- status: ok
- elapsed_ms: 153396
- tools: codedb,codedb,bash,bash!,bash!,bash,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,bash,bash!,bash,bash,bash,bash,bash

## task

In current codedb repo, inspect TrigramIndex.writeToDisk and readers in src/index.zig after commit 428d8df. Do not edit. Find the next safe, measurable memory/CPU optimization in persistence/load; assess correctness and tests. Exclude redesigns that require format changes unless critical. Return exact locations, recommendation, and risks.

## report

## Verified

- Commit `428d8df` removed the transient `ArrayList(DiskPosting)` and now writes postings in a fixed 4,096-entry batch, but it still retains **all** `LookupEntry`s in `lookup_entries` until the postings file is complete. Each entry is an `extern` 12-byte `{ trigram, offset, count }` record. [`src/index.zig:1712-1717`](src/index.zig#L1712-L1717), [`src/index.zig:1773-1778`](src/index.zig#L1773-L1778), [`src/index.zig:1822-1859`](src/index.zig#L1822-L1859)
- That retained list is later serialized as one byte slice only after the postings file has been flushed and renamed. [`src/index.zig:1862-1894`](src/index.zig#L1862-L1894)
- The exact lookup-entry count is already known before streaming: `trigrams_sorted` is built from every index key and sorted; the current posting loop appends precisely one lookup entry per such trigram. [`src/index.zig:1758-1771`](src/index.zig#L1758-L1771), [`src/index.zig:1825-1855`](src/index.zig#L1825-L1855)
- Readers consume the existing fixed layout—12-byte header plus `entry_count * @sizeOf(LookupEntry)`—and address postings only through each entry’s offset/count. Therefore streaming the same entries in the same sorted order needs **no format/version change**. [`src/index.zig:1958-1964`](src/index.zig#L1958-L1964), [`src/index.zig:1983-2029`](src/index.zig#L1983-L2029); mmap reader: [`src/index.zig:2229-2245`](src/index.zig#L2229-L2245), [`src/index.zig:2264-2284`](src/index.zig#L2264-L2284)
- Normal cold-load paths prefer `MmapTrigramIndex.initFromDisk`; heap `TrigramIndex.readFromDisk` is the fallback. [`src/bootstrap.zig:103-108`](src/bootstrap.zig#L103-L108), [`src/bootstrap.zig:506-514`](src/bootstrap.zig#L506-L514), [`src/background.zig:176-181`](src/background.zig#L176-L181), [`src/mcp.zig:231-236`](src/mcp.zig#L231-L236)
- Existing tests validate heap round-trip candidate equivalence and the new postings-batch boundary (4,097 postings), but not a lookup-entry batching boundary. [`src/test_index.zig:1967-1999`](src/test_index.zig#L1967-L1999), [`src/test_index.zig:2002-2030`](src/test_index.zig#L2002-L2030) Mmap round-trip/candidate behavior is separately covered. [`src/test_index.zig:2516-2555`](src/test_index.zig#L2516-L2555)
- Baseline verification: `zig build test --summary all` passed: **881 passed, 4 skipped**. No files were edited.

## Recommendation — stream the lookup table too

**Change location:** `TrigramIndex.writeToDisk`, primarily [`src/index.zig:1773-1778`](src/index.zig#L1773-L1778), [`src/index.zig:1825-1855`](src/index.zig#L1825-L1855), and [`src/index.zig:1864-1894`](src/index.zig#L1864-L1894).

**Implementation shape (format-preserving):**

1. Keep collecting and sorting `trigrams_sorted`; it supplies deterministic lookup ordering and the header count.
2. Create the lookup temp file/writer before the postings traversal; write its existing 12-byte header with `trigrams_sorted.items.len` as `entry_count`.
3. Replace `lookup_entries.append(...)` with a fixed stack batch such as `[4096]LookupEntry`, flushing `std.mem.sliceAsBytes(...)` to the lookup temp writer when full and once at the tail.
4. Flush/close both temporary files, then retain the current postings-then-lookup rename sequence.

**Why this is the next safe optimization:**

- It completes the memory objective of `428d8df`: peak auxiliary writer memory becomes bounded rather than `O(unique_trigrams)`. The current remaining staging is at least **12 × unique-trigram-count bytes**, plus `ArrayList` capacity headroom/realloc-copy overhead; e.g., one million distinct trigrams means at least ~11.4 MiB of payload before allocator overhead. The replacement needs only a fixed tens-of-KiB batch.
- It also removes `ArrayList` growth/reallocation and the final conversion/write of a large contiguous in-memory table. CPU improvement is measurable during persistence, though it should be benchmarked because batched writes introduce more writer calls than the current one-shot lookup write.
- It changes neither `DiskPosting`, `LookupEntry`, magic/version constants, file ordering, nor reader behavior. [`src/index.zig:1693-1717`](src/index.zig#L1693-L1717), [`src/index.zig:1958-1964`](src/index.zig#L1958-L1964)

## Correctness and test assessment

**Required tests**

1. **New lookup batch-boundary round trip:** construct more unique trigrams than the proposed lookup batch (e.g., 4,097 for a 4,096-entry batch), persist, then validate:
   - heap `TrigramIndex.readFromDisk` sees candidates from entries before, at, and after the boundary; and
   - `MmapTrigramIndex.initFromDisk` returns the same candidates.
   
   This directly covers the new tail/full-batch behavior for both readers, unlike the current 4,097-posting test, whose content is `"abc"` and thus exercises one lookup trigram, not thousands. [`src/test_index.zig:2008-2014`](src/test_index.zig#L2008-L2014)

2. Retain/run existing tests for:
   - ordinary heap candidate round trip, [`src/test_index.zig:1980-1999`](src/test_index.zig#L1980-L1999)
   - postings batch boundary, [`src/test_index.zig:2002-2030`](src/test_index.zig#L2002-L2030)
   - mmap candidate/file-set behavior. [`src/test_index.zig:2540-2554`](src/test_index.zig#L2540-L2554)

3. Add a benchmark/telemetry harness rather than asserting allocator bytes in a unit test:
   - fixture with known unique-trigram cardinality;
   - record peak allocator usage and wall/CPU time for `writeToDisk`;
   - acceptance target: eliminate approximately `12*T` retained bytes (where `T` is unique trigrams), without a material persistence-time regression.

**Risks / safeguards**

- **Header-count mismatch:** direct streaming must write exactly one lookup entry for every sorted trigram. Use `trigrams_sorted.items.len` for the header and maintain/assert a `written_entries` count in debug/test builds. The current logic’s one-entry-per-loop behavior is the invariant to preserve. [`src/index.zig:1825-1855`](src/index.zig#L1825-L1855)
- **`u32` representability:** explicitly reject `trigrams_sorted.items.len > maxInt(u32)` before writing the lookup header. The current `@intCast` at serialization has the same representational requirement but does not make it a deliberate persistence error. [`src/index.zig:1885-1887`](src/index.zig#L1885-L1887)
- **Atomic-pair behavior:** do not rename either final file until both temporary writers are fully flushed/closed. Keep the existing rename order. Note that the current two-file protocol is already not transactionally atomic across both renames; this recommendation should not widen that window. [`src/index.zig:1860-1862`](src/index.zig#L1860-L1862), [`src/index.zig:1891-1894`](src/index.zig#L1891-L1894)
- **CPU trade-off:** avoid one virtual `writeAll` per entry. A fixed lookup batch is required; a 48–64 KiB batch is appropriate to match the existing buffered-writer scale. The expectation of CPU benefit is an inference until benchmarked.

## Secondary, load-side opportunity (not the primary recommendation)

`MmapTrigramIndex` maps the postings file but then duplicates every path from that mapping and later frees every duplicate. [`src/index.zig:2202-2217`](src/index.zig#L2202-L2217), [`src/index.zig:2248-2253`](src/index.zig#L2248-L2253) The path slices could instead borrow `postings_data`, whose lifetime already extends until after `file_set.deinit()` and then `munmap()`. [`src/index.zig:2136-2145`](src/index.zig#L2136-L2145), [`src/index.zig:2248-2253`](src/index.zig#L2248-L2253)

This would eliminate one allocation/copy per indexed path and roughly the aggregate path-byte heap allocation on the common mmap cold-load path. It is format-preserving and safe if deinit stops freeing individual `file_table` elements. I rank it **after** streamed lookup entries because its benefit is proportional to total path bytes, whereas the remaining writer staging is proportional to unique trigrams and is likely larger on codebases with broad trigram diversity. This ranking is an inference; benchmark both on a representative repository before prioritizing further.

## 3 most load-bearing facts

1. `428d8df` streams postings but still materializes `lookup_entries` for every unique trigram. [`src/index.zig:1773-1778`](src/index.zig#L1773-L1778), [`src/index.zig:1851-1855`](src/index.zig#L1851-L1855)
2. The lookup header count is known from the sorted trigram key list, and readers already consume the same fixed entry sequence; lookup streaming needs no format change. [`src/index.zig:1758-1771`](src/index.zig#L1758-L1771), [`src/index.zig:1958-1964`](src/index.zig#L1958-L1964)
3. Production cold starts prefer mmap loading, while heap loading is fallback; any load optimization should target `MmapTrigramIndex` first. [`src/bootstrap.zig:103-108`](src/bootstrap.zig#L103-L108), [`src/background.zig:176-181`](src/background.zig#L176-L181)

## Open question

What are the representative production values for **unique trigram count versus aggregate path bytes** and the measured write/load peak RSS? Those determine whether streamed lookup persistence or mmap path-slice borrowing yields the larger next real-world win.
