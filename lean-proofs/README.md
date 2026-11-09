# CodeDB & OpenPuffer Lean 4 Formal Verification Suite

Self-contained Lean 4 formal proofs modeling the memory-ownership state machines,
cache conservation laws, and search/ANN latency kernels in `codedb` and `vendor/openpuffer`.

## Kernels Verified

1. **[`CodeDB/OpenPufferLifecycle.lean`](CodeDB/OpenPufferLifecycle.lean)** (`vendor/openpuffer/src/hnsw.zig`):
   - `planInsert` descending layer-slice allocation and error rollback (`verified_plan_insert_zero_leaks`, `verified_plan_insert_cube_ok`).
   - `appendRecord` 11-slab atomic length rollback (`verified_append_record_cube_ok`).
   - `commitInsert` / `publishInsert` ownership transfer & `errdefer` cleanup (`verified_commit_insert_always_clean`, `verified_commit_insert_cube_ok`).
2. **[`CodeDB/OpenPufferSearch.lean`](CodeDB/OpenPufferSearch.lean)** (`vendor/openpuffer/src/hnsw.zig`, `vendor/openpuffer/src/vector.zig`):
   - Sparse dirty-word visited reset across HNSW layers (`sparse_visited_membership_equiv`, `legacy_bitset_clear_redundant_work`).
   - `2048`-element stack buffers for query normalization & int8 quantization (`verified_2048_buf_zero_heap_allocs`, `verified_stack_alloc_cube_ok`).
   - Dual-accumulator SIMD dot-product equivalence (`dual_acc_dot_eq_single_acc_cube`).
3. **[`CodeDB/SearchLifecycle.lean`](CodeDB/SearchLifecycle.lean)** (`src/explore.zig`, `src/mcp.zig`):
   - Deep-free `errdefer` on owned `SearchResult` and `SymbolResult` lists (`verified_result_list_zero_leaks`).
   - Zero-copy ownership transfer in `searchContentWithScope` (`verified_scoped_search_saves_2n_allocs`, `verified_scoped_search_memory_clean`).
   - `renderPlainSearch` partial-output buffer rollback & zero-allocation `symbol_index` nudge (`verified_render_plain_buffer_clean_on_bail`, `verified_direct_nudge_exact_output_zero_allocs`).
4. **[`CodeDB/SearchCache.lean`](CodeDB/SearchCache.lean)** (`src/explore.zig`, `src/cio.zig`):
   - Epoch-memoized `rankingEnvFingerprint` and `searchCacheDisabled` (`stepEnvSim_preserves_valid`, `epoch_memo_cuts_100_queries_from_1000_to_10`, `epoch_memo_fp_sound_cube`).
   - Byte-budgeted and count-bounded LRU cache conservation (`verified_cache_conservation_cube_ok`).
   - Post-lazy-init generation capture under `mu.lockShared()` (`post_lazy_gen_capture_hits_without_stale_reads`, `legacy_pre_gen_capture_false_miss_on_lazy_build`, `verified_lazy_gen_cube_ok`).

## Running

```bash
./lean-proofs/verify.sh
```
