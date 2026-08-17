# subagent sa-030-ca07fee2

- label: Review persistence diff
- kind: subagent
- status: ok
- elapsed_ms: 98299
- tools: bash,codedb,codedb,codedb,codedb!,bash!,codedb,codedb,codedb,codedb,codedb,bash,bash,bash,bash,bash,bash,bash,bash_output

## task

Review the uncommitted current diff in the codedb repository, specifically src/index.zig TrigramIndex.writeToDisk and added tests in src/test_index.zig. The change streams lookup entries in 4096-entry batches and builds disk file IDs from id_to_path order to preserve mmap posting sort order. Do not edit files. Look for semantic regressions, resource/lifetime issues, format compatibility issues, test weaknesses, and performance risks. Report only concrete findings ranked by severity, or state no blocking finding.

## report

**High — mmap false negatives when doc IDs are reused.** `src/index.zig:1833` serializes each posting list as-is, but the new doc-id-order file table only preserves disk sort order if every `PostingList` is sorted. `insertExtracted` appends at `src/index.zig:1404` after `removeFile` can reuse a lower doc ID, producing unsorted disk `file_id`s; mmap merge/binary-search then drops valid candidates. Fix `insertExtracted` to use sorted insertion (`getOrAddPosting`), or sort/remap each posting list before writing. Add a persistence+mmap parity test covering remove/reinsert via `insertExtracted`; the added tests only exercise `indexFile`.

⟦ELITE-LIVE-ON-PROD⟧
