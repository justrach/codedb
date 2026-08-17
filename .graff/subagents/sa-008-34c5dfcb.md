# subagent sa-008-34c5dfcb

- label: Synthesize and recommend
- kind: workflow_task
- status: failed
- elapsed_ms: 170867
- tools: read_file,read_file,read_file,read_file

## task

Synthesize the following findings from the parallel subagents about the codedb cold-scan bottleneck (scan takes 1538ms of 1550ms total for a single-token search). Each finding is labeled with the subagent name. Rank the concrete optimization opportunities by expected impact, implementation risk, and code churn. Recommend the top 1-2 changes to implement next, with exact file/function targets and a rough implementation plan. Keep it actionable and conservative — avoid speculative SIMD unless the data strongly supports it. End with a one-paragraph recommendation.

Results from the previous workflow phase:

### Explore filesystem walk bottleneck
## Summary: cold-scan filesystem walk and parallel stat opportunities

### 1. What is currently serial

`src/watcher.zig:509-531` — `collectInitialScanEntries` runs entirely on the calling thread:

```zig
while (try walker.next()) |entry| {
    const stat = dir.statFile(io, entry.path, .{}) catch continue;   // line 522
    _ = try store.recordSnapshot(entry.path, stat.size, 0);           // line 523
    file_count += 1;
    try entries.append(allocator, .{                                 // line 525-528
        .path = try allocator.dupe(u8, entry.path),
        .skip_trigram = skip_trigram or (file_count > max_trigram_files),
    });
}
```

**Verified cost**: for every file the walker yields, the code pays

1. one `dir.statFile` syscall (`src/watcher.zig:522`);
2. one `store.recordSnapshot` call (`src/watcher.zig:523`);
3. one `entries.append` plus a path duplication.

There is no `std.Thread` usage inside this function, and the directory traversal itself is advanced one entry at a time inside the same loop. So the serial cost scales linearly with file count: `O(N)` stat/record operations performed back-to-back.

### 2. How the directory walk is implemented

`src/watcher.zig:275-496` — `FilteredWalker` is a hand-rolled stack-based DFS:

- State is kept in a `std.ArrayList(StackItem)` where each `StackItem = { dir_handle, iter }` (`src/watcher.zig:276-279`).
- It builds relative paths in a mutable `name_buffer` and tracks the current directory prefix in `dir_prefix_len` (`src/watcher.zig:281-285`).
- It prunes hard-coded skip directories (`skip_dirs`, `shouldSkipDir` at `src/watcher.zig:267`) before descending.
- It loads `.codedbignore` and `.gitignore` patterns and applies them in `isIgnored` (`src/watcher.zig:357-384`).
- It handles symlinked directories carefully: it uses `realPathFile` plus a `visited_real_paths` set to detect cycles and to reject symlinks that escape the project root (`src/watcher.zig:436-460`).
- It yields one `Entry` at a time; the returned `path` is a borrowed slice into `name_buffer` that is only valid until the next `next()` call (`src/watcher.zig:290-292`).

**Crucial for safety**: `FilteredWalker` is **not** thread-safe. It mutates `stack`, `name_buffer`, `dir_prefix_len`, `ignore_patterns`, and `visited_real_paths` on every step, so the traversal must stay single-threaded.

### 3. How the snapshot-load freshness scan already parallelizes stats

`src/snapshot.zig:948-954` — `freshnessScan` is the stat-only worker:

```zig
fn freshnessScan(io: std.Io, snap_mtime: i128, recs: []const LoadRecord, out: []LoadFreshness) void {
    for (recs, out) |record, *fr| {
        const ds = std.Io.Dir.cwd().statFile(io, record.path, .{}) catch continue;
        const ds_mtime: i128 = @intCast(ds.mtime.nanoseconds);
        if (ds_mtime > snap_mtime) fr.stale = true;
    }
}
```

`src/snapshot.zig:1108-1146` — the dispatch in `loadSnapshotFast` is the proven pattern:

- It only parallelizes when there are at least `FRESHNESS_PARALLEL_THRESHOLD = 256` records (`src/snapshot.zig:917`).
- It caps workers at `FRESHNESS_MAX_WORKERS = 4` (`src/snapshot.zig:923`), because the comment notes “statFile is dominated by kernel VFS work, not CPU, so throughput saturates at low concurrency”.
- It splits the records into contiguous chunks and spawns `std.Thread.spawn(.{}, freshnessScan, .{ io, snap_mtime, recs, out })`.
- Each worker writes only into its own disjoint `out` slice, so there is no shared mutable state.
- If a thread spawn fails, it falls back to scanning that chunk inline.

### 4. Lowest-risk way to parallelize the cold scan

The safest change is to **keep `FilteredWalker` single-threaded** and add a **two-phase collect + parallel stat** inside `collectInitialScanEntries`, mirroring the `freshnessScan` pattern.

Proposed shape:

1. **Phase 1 — serial walk**: walk with `FilteredWalker` once and collect every yielded relative path into a temporary array, preserving traversal order. Do **not** stat yet.
2. **Phase 2 — parallel stat**: split that array into contiguous chunks and spawn workers (threshold ~256, max 4 workers, `CODEDB_SCAN_WORKERS` override, exactly like `freshnessScan`). Each worker calls `dir.statFile` and then `store.recordSnapshot` for its chunk.
3. **Phase 3 — serial build**: build the final `InitialScanEntry` list in the original walk order, applying the `file_count > max_trigram_files` cap.

Why this is low-risk:

- `FilteredWalker` requires no modification and stays on one thread.
- `store.recordSnapshot` is already thread-safe: `appendVersion` acquires `store.mu` at the top (`src/store.zig:81-82`).
- The workers have no shared mutable output: each worker writes only into a disjoint chunk of a pre-allocated `sizes` / `ok` array, just like `freshnessScan` writes only into its own `out` slice.
- For small trees (`< 256` files) the function can keep the existing serial path unchanged.
- The `CODEDB_SCAN_WORKERS` env var already exists for `initialScan` (`src/watcher.zig:1116`), so the override mechanism can be reused.

### Verified vs. inferred

- **Verified**: `collectInitialScanEntries` is fully serial (`src/watcher.zig:509-531`); `FilteredWalker` is a single-threaded mutable-state DFS (`src/watcher.zig:275-496`); `freshnessScan` already uses chunked parallel stat dispatch (`src/snapshot.zig:948-954`, `1108-1146`); `recordSnapshot` is protected by `st

…[610 chars truncated — full result in the inspect file below]…

ot.zig:948-954` and `1108-1146` — a proven, safe pattern already exists: split records into disjoint chunks and spawn workers for stat-only work, with a 256-file threshold and a 4-worker cap.

### 1 open question

Should the parallel stat phase in `collectInitialScanEntries` also record the snapshot results into the `Store` from the worker threads, or should it only collect `{size, success}` arrays and leave all `recordSnapshot` calls on the main thread to avoid any contention on `store.mu` during the directory walk?

[subagent sa-002-2cd315cd · inspect: .graff/subagents/sa-002-2cd315cd.md]

### Explore trigram extraction inner loop
**Verified from the code**

- The extraction hot path is a single scalar, byte-at-a-time loop duplicated in four places:
  - `TrigramIndex.indexFile` (`src/index.zig:1252–1276`)
  - `TrigramIndex.extractTrigrams` (`src/index.zig:1370–1385`)
  - `watcher.readAndBuildTrigramShardWorker` (`src/watcher.zig:797–815`)
  - `watcher.cachedTrigramBuildWorker` (`src/watcher.zig:836–854`)
  - The same loop also appears in `TrigramIndex.indexFileReuse` (`src/index.zig:1320–1335`).

- Each iteration of the loop does:
  1. Loads three consecutive bytes (`content[i]`, `content[i+1]`, `content[i+2]`) (`src/index.zig:1255–1257`).
  2. Tests whether **all three** are ASCII whitespace (`' '`, `'\t'`, `'\n'`, `'\r'`) using 12 byte comparisons (`src/index.zig:1258–1260`).
  3. Calls `normalizeChar` on each byte — it only lowercases `A–Z` (`src/index.zig:3070–3072`).
  4. Packs the three normalized bytes into a 24-bit `Trigram` (`src/index.zig:1021`).
  5. Inserts or looks up the trigram in a per-file `std.AutoHashMap(Trigram, PostingMask)` (`src/index.zig:1267`, `src/index.zig:1379`, `src/watcher.zig:806/845`).
  6. Updates `loc_mask` and `next_mask` (`src/index.zig:1269–1273`).

- `insertBulkMapNew` is the merge phase: it walks the local map and inserts into the shard/global `index`, paying one global hash lookup + one `PostingList.items.append` per unique trigram (`src/index.zig:1437–1447`).

- Workers reuse a local `AutoHashMap` initialized with capacity `4096` (`src/watcher.zig:785–787`); `indexFile` pre-sizes to `max(64, min(content.len/4, 65536))` (`src/index.zig:1249–1250`).

- `extractTrigrams` has no callers in this repo (`codedb callers extractTrigrams` returned 0).

**Inferred: where the CPU cycles are going**

- The dominant cost is the per-position `local.getOrPut` on the generic `AutoHashMap`. It dwarfs the byte loads, packing, and mask updates.
- The secondary costs are the whitespace tests (12 comparisons, one branch per position) and the three branchy `normalizeChar` calls. The comment says pure-whitespace trigrams are about 12% of occurrences (`src/index.zig:1254`).
- The `next_mask` work re-fetches and re-normalizes `content[i+3]` (`src/index.zig:1273`).
- `insertBulkMapNew` is not per-byte; it is per unique trigram. On large files it can become a second hot spot because the global index may be large and `PostingList` can require a sorted insert or append.

**Concrete speed-up options and rough risk/reward**

| Option | What it does | Risk | Expected reward | Why |
|---|---|---|---|---|
| **1. Branchless normalize + whitespace LUT** | Replace `normalizeChar` and the 12 whitespace checks with two 256-byte tables: `norm[c]` and `is_ws[c]`. Loop becomes `if (is_ws[c0] & is_ws[c1] & is_ws[c2]) continue; tri = pack(norm[c0], norm[c1], norm[c2]);` | Low | Low–moderate (~5–15%) | Removes a dozen comparisons and three branchy lowercases per iteration (`src/index.zig:1258–1260`, `3070–3072`). |
| **2. Batched normalize (single pass)** | Build a normalized copy of the buffer once, then read `norm[i]`/`norm[i+1]`/`norm[i+2]` in the trigram loop. | Low | Low–moderate (~5–10%) | Avoids re-reading and re-normalizing each byte three times and eliminates the extra `content[i+3]` normalize (`src/index.zig:1273`). |
| **3. SIMD whitespace / normalize detection** | Use `@Vector`/SSE to classify 16 bytes as whitespace and/or lowercase 16 bytes at once. | Moderate | Low–moderate (~5–15%) | Targets the 12% pure-whitespace skip (`src/index.zig:1254`), but the hashmap is the bottleneck. |
| **4. SIMD trigram packing** | Compute 4–8 packed trigram keys in parallel with vector shuffles. | Moderate | Low (~3–8%) | Packing is already only a few shifts/ORs (`src/index.zig:1021`), so there is less to save. |
| **5. Use assume-capacity insertion after generous pre-sizing** | After sizing the local map to a generous upper bound, skip the generic per-iteration capacity check. | Low | Moderate (~10–20%) | Workers already reuse the map, but they only pre-size to 4096 (`src/watcher.zig:785–787`); `indexFile` sizes better (`src/index.zig:1249–1250`). |
| **6. Custom per-file open-addressing hash table** | Replace `std.AutoHashMap(Trigram, PostingMask)` with a specialized 24-bit-key table storing masks inline. | Moderate | High (~20–40%) | Eliminates the single biggest cost: the generic hashmap per-position operation (`src/index.zig:1267`). |
| **7. Sort/unique instead of per-position hashmap** | Collect `(trigram, pos_mod8, next_norm)` records per position, radix-sort by 24-bit trigram, then compute OR masks in one pass. | Moderate | High on large files (~20–40%) | Bypasses the hashmap entirely, but adds a large auxiliary array and a sort pass. |
| **8. Pre-size global `index` and unchecked insert in `insertBulkMapNew`** | Pre-reserve the shard/global index for the incoming trigram set and avoid the full `getOrPut` dance per unique trigram. | Low–moderate | Moderate (~10–20%) | `insertBulkMapNew` currently pays a full hash lookup per unique trigram (`src/index.zig:1439`). |

The numbers above are profile-free estimates; the safest big wins are (6) or (7), while the safest small wins are (1) and (2).

**Top 3 load-bearing facts**

1. The exact same scalar, per-byte, hashmap-insertion loop is duplicated in `indexFile`, `indexFileReuse`, `extractTrigrams`, and the two watcher wor

…[128 chars truncated — full result in the inspect file below]…

the highest upside.
3. The architecture is already two-phase (local accumulation, then global merge), so the next optimization target is the local extraction loop itself, not a missing pipeline change.

**Open question**

Which replacement for the per-position `AutoHashMap` — a small custom open-addressing table, a 24-bit radix-sort/unique pass, or a compact trigram trie/bitset — is fastest for the actual file sizes in this codebase, and does it save enough to justify the extra memory and implementation complexity?

[subagent sa-001-e6506325 · inspect: .graff/subagents/sa-001-e6506325.md]

### Explore worker merge and allocation overhead
## Verified allocation / movement in the cold-scan trigram shard path

### 1. Path-string duplication
- `mergeBulkShard` copies every path into the destination index: `const duped = try self.allocator.dupe(u8, path)` at `src/index.zig:1464`.
- `getOrCreateDocId` only duplicates when `owns_paths` is true (`src/index.zig:1188-1191`). The cold-scan worker shards are created with `TrigramIndex.init(...)` and never set `owns_paths`, so they **borrow** `entry.path` / cache keys. The final destination (`tmp_tri`) sets `owns_paths = true` (`src/watcher.zig:1000` / `src/watcher.zig:879`), so the final copy happens once during merge.
- Therefore each path is allocated once by the scan collector/cache and then copied once more into the final trigram index.

### 2. Posting-list allocation and movement
- `insertBulkMapNew` creates a fresh empty `PostingList` on the first occurrence of a trigram in a shard (`src/index.zig:1441`) and then appends one `DocPosting` per file (`src/index.zig:1443`). There is **no `ensureTotalCapacity`** for the posting array, so the list grows incrementally and may reallocate/copy several times as more files contribute the same trigram.
- `mergeBulkShard` remaps `doc_id`s in place (`src/index.zig:1476`), then:
  - If the trigram key is new and the allocators match, it **transfers** the whole `items` buffer from the source shard to the destination: `gop.value_ptr.items = entry.value_ptr.items; entry.value_ptr.items = .empty;` (`src/index.zig:1481-1484`). This is the existing zero-copy path.
  - Otherwise it falls back to `appendSlice` (`src/index.zig:1487`), copying every posting into the destination array without first reserving capacity.

### 3. Per-file trigram HashMap in workers
- Both `readAndBuildTrigramShardWorker` and `cachedTrigramBuildWorker` create one `std.AutoHashMap(Trigram, PostingMask)` on `std.heap.c_allocator`, pre-size it to 4096 slots, and reuse it across files with `clearRetainingCapacity()` (`src/watcher.zig:785-796` and `src/watcher.zig:829-835`).
- File content is read with `dir.readFileAlloc(..., .limited(max_indexed_file_bytes))` (`src/watcher.zig:188`), so every file gets a fresh heap allocation that is freed after indexing.

### 4. HashMap pre-sizing
- Worker shards pre-size `index` to `32768` and `path_to_id` to the chunk file count (`src/watcher.zig:1053-1054` / `src/watcher.zig:942-943`).
- The destination pre-sizes `index` to `131072` and `path_to_id` to `min(files, 65536)` (`src/watcher.zig:1001-1002` / `src/watcher.zig:880-881`).
- `mergeBulkShard` also pre-grows `id_to_path` and `path_to_id` by the shard’s file count (`src/index.zig:1461-1462`).

### 5. Worker trigram path through `indexFile` still builds `file_trigrams`
- When outlines are enabled, `initialScanWorker` builds trigrams with `indexFile` (`src/watcher.zig:615`), which allocates a per-file `tri_list` and stores it in `file_trigrams` (`src/index.zig:1279-1308`). `mergeBulkShard` never consumes this list; the worker shard is discarded after merge, so that allocation is wasted for the cold-scan bulk path.

---

## Inferred opportunities

- **Pre-size posting lists:** In `insertBulkMapNew`, a new `PostingList` could be created with an initial capacity estimate (e.g., the chunk file count or a small power-of-two) instead of starting empty. In `mergeBulkShard`, calling `ensureUnusedCapacity` before `appendSlice` for existing keys would avoid repeated reallocations when merging multiple shards.
- **Size the local trigram map per file:** The fixed `4096` slot pool is reused, but it is not tuned to the file. Using the `content.len / 4` heuristic already present in `TrigramIndex.indexFile` (`src/index.zig:1249`) per file would reduce both map growth and retained bloat.
- **Avoid `file_trigrams` in worker shards:** The `skip_outlines` path already uses `insertBulkMapNew`, which skips the per-file cleanup list. The outlines path could do the same (or add a `skip_file_trigrams` flag to `indexFile`) to save one `ArrayList(Trigram)` and one `StringHashMap` entry per file.
- **Zero-copy path strings:** The final path copy in `mergeBulkShard` is currently unavoidable because the worker shards borrow their path strings. The already-allocated `entries` path strings are still alive during merge, so a move/transfer of those strings into the final index could eliminate the duplicate copy, but it would require changing the lifetime contract and possibly the `path_to_id` key model.
- **Content buffer pooling / mmap:** `readFileAlloc` per file could be replaced with a reusable buffer pool or `mmap` for files under the cap, removing the per-file allocation/free round-trip.
- **Better hashMap pre-sizing:** `32768` and `131072` are guesses. Sizing from total content bytes, previous index stats, or an exact upper bound (e.g., `|content| - 2` unique trigrams capped by `MAX_POSTINGS`) would reduce rehashing and entry movement.

---

## 3 load-bearing facts

1. **Paths are copied exactly once into the final trigram index** in `mergeBulkShard` (`src/index.zig:1464`), because worker shards borrow paths (`owns_paths=false`) and only the destination owns them.
2. **`mergeBulkShard` already zero-copy transfers whole posting-list buffers** when a trigram key is new and the allocators match (`src/index.zig:1481-1484`), but falls back to copying with `appendSlice` for colliding keys or mismatched allocators (`src/index.zig:1487`).
3. **The worker per-file trigram HashMap is pooled and reused**, but its capacity is fixed at `4096` (`src/watcher.zig:787` / `src/watcher.zig:833`), which may under-size large files or over-size tiny ones.

## 1 open question

Could the final path copy in `mergeBulkShard` be eliminated by moving the already-allocated `entries` path strings into the destination index instead of calling `allocator.dupe`, or would that break the lifetime/ownership assumptions of the content cache and the serial commit loop?

[subagent sa-000-9baa725f · inspect: .graff/subagents/sa-000-9baa725f.md]

### Explore content reading and I/O pattern
## Verified flow

Cold `search` without a matching snapshot hits `bootstrap.zig:468–494`:

- If the git head does not match the on-disk trigram header, it calls `watcher.initialScanWithTrigrams(..., search_skips_outlines)` (`bootstrap.zig:482–483`).
- `search_skips_outlines` is true for single-token queries or `--regex` queries (`bootstrap.zig:477–480`).

In `initialScanWithTrigrams`, the `skip_outlines` branch is at `watcher.zig:1043–1067`:

- It spawns up to `cpu_count` (capped at 8) workers, each running `readAndBuildTrigramShardWorker`.
- Each worker gets a chunk of `InitialScanEntry` items and a private `TrigramIndex`.
- After all workers finish, the main thread merges each shard into `tmp_tri` with `mergeBulkShard`.

`readAndBuildTrigramShardWorker` (`watcher.zig:783–822`) processes each file like this:

1. `shouldSkipFile(entry.path)` – extension filter.
2. `std.Io.Dir.cwd().openDir(io, root, .{})` – re-opens the project directory.
3. `dir.statFile(io, entry.path, .{})` – re-stats the file to get `size`.
4. `readIndexableFile(io, dir, entry.path, std.heap.c_allocator, stat.size, false)` – reads the whole file into a heap buffer.
5. If `content.len > max_trigram_file_bytes` (1 MB), the content is discarded.
6. Otherwise, trigrams are extracted into a local `AutoHashMap` and bulk-inserted with `shard.insertBulkMapNew`.

`readIndexableFile` (`watcher.zig:173–196`) is the shared gate:

- Rejects files whose `size > max_indexed_file_bytes` (2 MB) before reading.
- Calls `dir.readFileAlloc(io, path, alloc, .limited(max_indexed_file_bytes))`.
- Rejects binary files by checking for a null byte in the first 512 bytes.

`collectInitialScanEntries` (`watcher.zig:509–531`) already stats every file and records it in the `Store`, but `InitialScanEntry` only stores `path` and `skip_trigram` (`watcher.zig:85–88`), so the worker has no cached size.

---

## Is the current read-then-extract pattern optimal?

No, not for the `skip_outlines` branch, though it is a reasonable simple baseline.

The multi-worker `skip_outlines` branch already avoids the expensive outline parsing and word-index work, but it still:

- Re-opens the project directory and re-stats each file (`watcher.zig:790–792`).
- Reads the full file into a `c_allocator` buffer (`watcher.zig:793`), then throws it away if it is between 1 MB and 2 MB (`watcher.zig:795`).
- Does not bypass outline parsing in the *single-worker* path: `watcher.zig:1004–1018` still calls `parseInitialScanEntry`, which parses outlines via `explore.zig:2004–2016`, even when `skip_outlines` is true.

So there is wasted work: redundant directory opens/stats, wasted reads of 1–2 MB files, and, in the single-worker case, wasted outline parsing.

---

## Could mmap help?

Yes, for this specific use case.

The trigram extraction is read-only: it walks the byte slice once and writes only to a worker-local hashmap. A read-only `mmap` could replace the `readFileAlloc` copy, eliminating the per-file heap allocation and the user-space copy from the kernel page cache. The repo already has the necessary wrapper: `cio.mmapReadonly` (`cio.zig:974–989`) is used today to load persisted indexes (`index.zig:920`, `index.zig:2146`, `index.zig:2163`).

**Likely benefits**

- No `c_allocator` allocation/free per file.
- No copy from kernel page cache into user-space buffer.
- Lower memory churn, especially for many 100 KB–1 MB files.

**Costs and safety issues**

- `mmap` can raise `SIGBUS` if the file is truncated between the `stat` and the access. The current heap read is immune to this because the whole file is copied into a private buffer before extraction.
- On POSIX, `cio.mmapReadonly` uses `MAP_SHARED` (`cio.zig:986`), so concurrent writes by another process would be visible to the indexer; this is probably fine for a cold index, but a `MAP_PRIVATE` variant would be safer.
- On Windows, the file handle must stay valid until the view is unmapped, so the worker would need to keep a `std.Io.File` open for each file, not just close it after `readFileAlloc`.
- Mapping and unmapping each file has its own kernel cost; for very small files (a few KB) the overhead of an `mmap`/`munmap` can approach or exceed that of a small heap allocation.

---

## Could async or batched reads help?

In theory, yes, but the payoff is less clear and the implementation cost is high.

The workers are already I/O-parallel: `initialScanWithTrigrams` uses up to 8 threads, each reading its own chunk. So the cold path is not doing purely serial I/O. Async/batched I/O would help most if:

- The bottleneck is per-file `open`/`stat`/`read`/`close` syscall overhead, or
- The storage has high latency and workers are idle waiting for reads.

However:

- The codebase has no async I/O abstraction today. `cio.zig` exposes synchronous `read`/`write`, pipes, and `mmapReadonly` only.
- Adding portable async I/O (`io_uring` on Linux, `kqueue`/`aio` on macOS, I/OCP on Windows) would be a large, cross-platform change.
- Batched reads would require keeping multiple in-flight buffers alive, increasing peak memory and complicating lifetime/error handling.

For a typical repo on local NVMe/SSD, the current threaded model is probably close enough; async would be a niche optimization for cold-storage or very large file counts.

---

## Safety / memory trade-offs

| Approach | Memory | Safety / complexity |

…[2086 chars truncated — full result in the inspect file below]…

46`, `index.zig:2163`), but it would introduce `SIGBUS`/truncation and file-handle lifetime concerns that the current heap read avoids.

---

## Open question

What is the actual bottleneck in the cold `search` path on the target hardware and OS: is it the per-file heap copy/allocation, the per-file `openDir`/`statFile` overhead, or the raw disk read latency? The answer would tell us whether the biggest payoff comes from mmap, from caching directory handles and sizes in `InitialScanEntry`, or from batching/async reads.

[subagent sa-003-92530aad · inspect: .graff/subagents/sa-003-92530aad.md]

## report

subagent finished without a report
