# OpenClaw × graff × codedb — first baseline

- corpus: `/tmp/openclaw-hillclimb` @ `1c35795`
- model: `codex/5.6-luna`
- codedb: `0.2.5840`

| case | pass | in | cached | out | api | tools | answer |
|---|---|---:|---:|---:|---:|---|---|
| symbol-lan-ipv4 | True | 29617 | 13824 | 78 | 2 | codedb | `src/gateway/net.ts:23` |
| symbol-apply-patch | True | 29578 | 13824 | 57 | 2 | codedb | `src/agents/apply-patch.ts:129` |
| symbol-version-fast-path | True | 29597 | 13824 | 53 | 2 | codedb | `src/entry.ts:102` |
| file-gateway-net | True | 29551 | 13824 | 50 | 2 | codedb | `src/gateway/net.ts` |
| **total** | 4/4 | **118343** | **55296** | **238** | **8** | | |

Uncached input tokens (in - cached): **63047**.

# OpenClaw × graff × codedb — hard suite

- corpus: `/tmp/openclaw-hillclimb` @ `1c35795`
- model: `codex/5.6-luna`
- codedb: `0.2.5840`

| case | pass | in | cached | out | api | tools | answer |
|---|---|---:|---:|---:|---:|---|---|
| task-lan-ipv4 | False | 104529 | 79360 | 476 | 6 | codedb,codedb,codedb,codedb,codedb,read_file,bash | `src/gateway/net.ts:22` |
| task-apply-patch | True | 77377 | 57344 | 196 | 5 | codedb,codedb,codedb,codedb | `src/agents/apply-patch.ts:129` |
| task-version-fast-path | True | 189600 | 156672 | 595 | 9 | codedb,codedb,codedb,bash,bash,read_file,bash,codedb | `src/entry.ts:102` |
| task-file-lan | True | 62244 | 57344 | 198 | 4 | codedb,codedb,codedb | `src/gateway/net.ts` |
| **total** | 3/4 | **433750** | **350720** | **1465** | **24** | | |

Uncached input tokens (in - cached): **83030**.
score=75

# OpenClaw × graff × codedb — hard suite

- corpus: `/tmp/openclaw-hillclimb` @ `1c35795`
- model: `codex/5.6-luna`
- codedb: `0.2.5840`

| case | pass | in | cached | out | api | tools | answer |
|---|---|---:|---:|---:|---:|---|---|
| task-lan-ipv4 | True | 106182 | 80384 | 442 | 6 | load_tool_schemas,load_tool_schemas,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb | `src/gateway/net.ts:23` |
| task-apply-patch | True | 77328 | 71168 | 184 | 5 | codedb,codedb,codedb,codedb | `src/agents/apply-patch.ts:129` |
| task-version-fast-path | True | 111003 | 89088 | 282 | 7 | codedb,codedb,codedb,codedb,read_file,read_file | `src/entry.ts:102` |
| task-file-lan | True | 76823 | 57344 | 197 | 5 | codedb,codedb,codedb,codedb | `src/gateway/net.ts` |
| **total** | 4/4 | **371336** | **297984** | **1105** | **23** | | |

Uncached input tokens (in - cached): **73352**.
score=100

# OpenClaw × graff × codedb — hard suite

- corpus: `/tmp/openclaw-hillclimb` @ `1c35795`
- model: `codex/5.6-luna`
- codedb: `0.2.5841-context-phrase`

| case | pass | in | cached | out | api | tools | answer |
|---|---|---:|---:|---:|---:|---|---|
| task-lan-ipv4 | True | 76958 | 43520 | 180 | 5 | codedb,codedb,codedb,codedb | `src/gateway/net.ts:23` |
| task-apply-patch | True | 77353 | 57344 | 193 | 5 | codedb,codedb,codedb,codedb | `src/agents/apply-patch.ts:129` |
| task-version-fast-path | True | 111843 | 91136 | 368 | 7 | load_tool_schemas,load_tool_schemas,codedb,codedb,codedb,read_file | `src/entry.ts:102` |
| task-file-lan | True | 62125 | 43520 | 152 | 4 | codedb,codedb,codedb | `src/gateway/net.ts` |
| **total** | 4/4 | **328279** | **235520** | **893** | **21** | | |

Uncached input tokens (in - cached): **92759**.
score=100

# OpenClaw × graff × codedb — hard suite

- corpus: `/tmp/openclaw-hillclimb` @ `1c35795`
- model: `codex/5.6-luna`
- codedb: `0.2.5841-context-phrase`

| case | pass | in | cached | out | api | tools | answer |
|---|---|---:|---:|---:|---:|---|---|
| task-lan-ipv4 | True | 140425 | 111104 | 385 | 8 | codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb | `src/gateway/net.ts:23` |
| task-apply-patch | True | 95924 | 74240 | 283 | 6 | codedb,codedb,codedb,codedb,codedb | `src/agents/apply-patch.ts:129` |
| task-version-fast-path | True | 56529 | 33792 | 255 | 3 | codedb,codedb,codedb,codedb,codedb,codedb | `src/entry.ts:102` |
| task-file-lan | True | 77288 | 57344 | 199 | 5 | codedb,codedb,codedb,codedb | `src/gateway/net.ts` |
| **total** | 4/4 | **370166** | **276480** | **1122** | **22** | | |

Uncached input tokens (in - cached): **93686**.
score=100

# OpenClaw × graff × codedb — hard suite

- corpus: `/tmp/openclaw-hillclimb` @ `1c35795`
- model: `codex/5.6-luna`
- codedb: `0.2.5841-context-phrase`

| case | pass | in | cached | out | api | tools | answer |
|---|---|---:|---:|---:|---:|---|---|
| task-lan-ipv4 | True | 94393 | 73216 | 264 | 6 | codedb,codedb,codedb,codedb,read_file | `src/gateway/net.ts:23` |
| task-apply-patch | True | 113269 | 89088 | 395 | 7 | load_tool_schemas,load_tool_schemas,codedb,codedb,codedb,codedb,codedb,codedb | `src/agents/apply-patch.ts:129` |
| task-version-fast-path | True | 119723 | 66560 | 556 | 6 | load_tool_schemas,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb | `src/entry.ts:102` |
| task-file-lan | True | 30037 | 13824 | 122 | 2 | codedb | `src/gateway/net.ts` |
| **total** | 4/4 | **357422** | **242688** | **1337** | **21** | | |

Uncached input tokens (in - cached): **114734**.
score=100

# OpenClaw × graff × codedb — hard suite

- corpus: `/tmp/openclaw-hillclimb` @ `1c35795`
- model: `codex/5.6-luna`
- codedb: `0.2.5841-context-phrase`

| case | pass | in | cached | out | api | tools | answer |
|---|---|---:|---:|---:|---:|---|---|
| task-lan-ipv4 | True | 111037 | 89088 | 334 | 7 | codedb,codedb,codedb,codedb,codedb,codedb | `src/gateway/net.ts:23` |
| task-apply-patch | True | 133627 | 123904 | 488 | 8 | codedb,codedb,codedb,codedb,codedb,codedb,codedb | `src/agents/apply-patch.ts:129` |
| task-version-fast-path | True | 112922 | 103936 | 278 | 7 | codedb,codedb,codedb,read_file,read_file,read_file | `src/entry.ts:101` |
| task-file-lan | True | 77330 | 71168 | 211 | 5 | codedb,codedb,codedb,codedb | `src/gateway/net.ts` |
| **total** | 4/4 | **434916** | **388096** | **1311** | **27** | | |

Uncached input tokens (in - cached): **46820**.
score=100

# OpenClaw hill-climb

- steps: 50  seed=7  keeps=3
- best MRR: 0.8333  p@1=0.75  ranks=[1, 1, 1, 3]
- best knobs: `{"CODEDB_CONTEXT_PHRASE": "1", "CODEDB_CONTEXT_PHRASE_BOOST": "2", "CODEDB_CONTEXT_IDENT_SYMBOLS": "1", "CODEDB_CONTEXT_MAX_CANDIDATES": "7", "CODEDB_CONTEXT_TOP_FILES": "8", "CODEDB_CONTEXT_DEMOTE_TESTS": "1"}`

| step | status | mrr | p@1 | ranks | knobs |
|---:|---|---:|---:|---|---|
| 0 | keep | 0.6458 | 0.5 | [1, 3, 1, 4] | `{"CODEDB_CONTEXT_PHRASE": "1", "CODEDB_CONTEXT_PHRASE_BOOST": "2", "CODEDB_CONTEXT_IDENT_SYMBOLS": "1", "CODEDB_CONTEXT_MAX_CANDIDATES": "5", "CODEDB_CONTEXT_TOP_FILES": "5", "CODEDB_CONTEXT_DEMOTE_TESTS": "0"}` |
| 1 | discard | 0.6458 | 0.5 | [1, 3, 1, 4] | `{"CODEDB_CONTEXT_PHRASE": "1", "CODEDB_CONTEXT_PHRASE_BOOST": "3", "CODEDB_CONTEXT_IDENT_SYMBOLS": "1", "CODEDB_CONTEXT_MAX_CANDIDATES": "5", "CODEDB_CONTEXT_TOP_FILES": "5", "CODEDB_CONTEXT_DEMOTE_TESTS": "0"}` |
| 2 | discard | 0.0 | 0.0 | [None, None, None, None] | `{"CODEDB_CONTEXT_PHRASE": "0", "CODEDB_CONTEXT_PHRASE_BOOST": "2", "CODEDB_CONTEXT_IDENT_SYMBOLS": "1", "CODEDB_CONTEXT_MAX_CANDIDATES": "5", "CODEDB_CONTEXT_TOP_FILES": "5", "CODEDB_CONTEXT_DEMOTE_TESTS": "1"}` |
| 3 | discard | 0.0 | 0.0 | [None, None, None, None] | `{"CODEDB_CONTEXT_PHRASE": "0", "CODEDB_CONTEXT_PHRASE_BOOST": "2", "CODEDB_CONTEXT_IDENT_SYMBOLS": "1", "CODEDB_CONTEXT_MAX_CANDIDATES": "5", "CODEDB_CONTEXT_TOP_FILES": "3", "CODEDB_CONTEXT_DEMOTE_TESTS": "0"}` |
| 4 | discard | 0.6458 | 0.5 | [1, 3, 1, 4] | `{"CODEDB_CONTEXT_PHRASE": "1", "CODEDB_CONTEXT_PHRASE_BOOST": "2", "CODEDB_CONTEXT_IDENT_SYMBOLS": "1", "CODEDB_CONTEXT_MAX_CANDIDATES": "4", "CODEDB_CONTEXT_TOP_FILES": "5", "CODEDB_CONTEXT_DEMOTE_TESTS": "0"}` |
| 5 | discard | 0.6458 | 0.5 | [1, 3, 1, 4] | `{"CODEDB_CONTEXT_PHRASE": "1", "CODEDB_CONTEXT_PHRASE_BOOST": "1", "CODEDB_CONTEXT_IDENT_SYMBOLS": "1", "CODEDB_CONTEXT_MAX_CANDIDATES": "5", "CODEDB_CONTEXT_TOP_FILES": "5", "CODEDB_CONTEXT_DEMOTE_TESTS": "0"}` |
| 6 | discard | 0.05 | 0.0 | [None, 5, None, None] | `{"CODEDB_CONTEXT_PHRASE": "0", "CODEDB_CONTEXT_PHRASE_BOOST": "2", "CODEDB_CONTEXT_IDENT_SYMBOLS": "1", "CODEDB_CONTEXT_MAX_CANDIDATES": "7", "CODEDB_CONTEXT_TOP_FILES": "5", "CODEDB_CONTEXT_DEMOTE_TESTS": "0"}` |
| 7 | keep | 0.6667 | 0.5 | [1, 3, 1, 3] | `{"CODEDB_CONTEXT_PHRASE": "1", "CODEDB_CONTEXT_PHRASE_BOOST": "2", "CODEDB_CONTEXT_IDENT_SYMBOLS": "1", "CODEDB_CONTEXT_MAX_CANDIDATES": "5", "CODEDB_CONTEXT_TOP_FILES": "5", "CODEDB_CONTEXT_DEMOTE_TESTS": "1"}` |
| 8 | discard | 0.6667 | 0.5 | [1, 3, 1, 3] | `{"CODEDB_CONTEXT_PHRASE": "1", "CODEDB_CONTEXT_PHRASE_BOOST": "2", "CODEDB_CONTEXT_IDENT_SYMBOLS": "1", "CODEDB_CONTEXT_MAX_CANDIDATES": "3", "CODEDB_CONTEXT_TOP_FILES": "3", "CODEDB_CONTEXT_DEMOTE_TESTS": "1"}` |
| 9 | discard | 0.6667 | 0.5 | [1, 3, 1, 3] | `{"CODEDB_CONTEXT_PHRASE": "1", "CODEDB_CONTEXT_PHRASE_BOOST": "2", "CODEDB_CONTEXT_IDENT_SYMBOLS": "1", "CODEDB_CONTEXT_MAX_CANDIDATES": "5", "CODEDB_CONTEXT_TOP_FILES": "3", "CODEDB_CONTEXT_DEMOTE_TESTS": "1"}` |
| 10 | discard | 0.6667 | 0.5 | [1, 3, 1, 3] | `{"CODEDB_CONTEXT_PHRASE": "1", "CODEDB_CONTEXT_PHRASE_BOOST": "2", "CODEDB_CONTEXT_IDENT_SYMBOLS": "1", "CODEDB_CONTEXT_MAX_CANDIDATES": "3", "CODEDB_CONTEXT_TOP_FILES": "5", "CODEDB_CONTEXT_DEMOTE_TESTS": "1"}` |
| 11 | discard | 0.0 | 0.0 | [None, None, None, None] | `{"CODEDB_CONTEXT_PHRASE": "0", "CODEDB_CONTEXT_PHRASE_BOOST": "2", "CODEDB_CONTEXT_IDENT_SYMBOLS": "1", "CODEDB_CONTEXT_MAX_CANDIDATES": "5", "CODEDB_CONTEXT_TOP_FILES": "3", "CODEDB_CONTEXT_DEMOTE_TESTS": "1"}` |
| 12 | discard | 0.6667 | 0.5 | [1, 3, 1, 3] | `{"CODEDB_CONTEXT_PHRASE": "1", "CODEDB_CONTEXT_PHRASE_BOOST": "2", "CODEDB_CONTEXT_IDENT_SYMBOLS": "1", "CODEDB_CONTEXT_MAX_CANDIDATES": "5", "CODEDB_CONTEXT_TOP_FILES": "3", "CODEDB_CONTEXT_DEMOTE_TESTS": "1"}` |
| 13 | discard | 0.0 | 0.0 | [None, None, None, None] | `{"CODEDB_CONTEXT_PHRASE": "0", "CODEDB_CONTEXT_PHRASE_BOOST": "2", "CODEDB_CONTEXT_IDENT_SYMBOLS": "1", "CODEDB_CONTEXT_MAX_CANDIDATES": "5", "CODEDB_CONTEXT_TOP_FILES": "5", "CODEDB_CONTEXT_DEMOTE_TESTS": "1"}` |
| 14 | discard | 0.0 | 0.0 | [None, None, None, None] | `{"CODEDB_CONTEXT_PHRASE": "0", "CODEDB_CONTEXT_PHRASE_BOOST": "2", "CODEDB_CONTEXT_IDENT_SYMBOLS": "1", "CODEDB_CONTEXT_MAX_CANDIDATES": "5", "CODEDB_CONTEXT_TOP_FILES": "8", "CODEDB_CONTEXT_DEMOTE_TESTS": "1"}` |
| 15 | discard | 0.6667 | 0.5 | [1, 3, 1, 3] | `{"CODEDB_CONTEXT_PHRASE": "1", "CODEDB_CONTEXT_PHRASE_BOOST": "2", "CODEDB_CONTEXT_IDENT_SYMBOLS": "1", "CODEDB_CONTEXT_MAX_CANDIDATES": "4", "CODEDB_CONTEXT_TOP_FILES": "8", "CODEDB_CONTEXT_DEMOTE_TESTS": "1"}` |
| 16 | discard | 0.5417 | 0.25 | [2, 3, 1, 3] | `{"CODEDB_CONTEXT_PHRASE": "1", "CODEDB_CONTEXT_PHRASE_BOOST": "2", "CODEDB_CONTEXT_IDENT_SYMBOLS": "0", "CODEDB_CONTEXT_MAX_CANDIDATES": "4", "CODEDB_CONTEXT_TOP_FILES": "5", "CODEDB_CONTEXT_DEMOTE_TESTS": "1"}` |
| 17 | discard | 0.6458 | 0.5 | [1, 3, 1, 4] | `{"CODEDB_CONTEXT_PHRASE": "1", "CODEDB_CONTEXT_PHRASE_BOOST": "2", "CODEDB_CONTEXT_IDENT_SYMBOLS": "1", "CODEDB_CONTEXT_MAX_CANDIDATES": "5", "CODEDB_CONTEXT_TOP_FILES": "5", "CODEDB_CONTEXT_DEMOTE_TESTS": "0"}` |
| 18 | discard | 0.6667 | 0.5 | [1, 3, 1, 3] | `{"CODEDB_CONTEXT_PHRASE": "1", "CODEDB_CONTEXT_PHRASE_BOOST": "2", "CODEDB_CONTEXT_IDENT_SYMBOLS": "1", "CODEDB_CONTEXT_MAX_CANDIDATES": "5", "CODEDB_CONTEXT_TOP_FILES": "8", "CODEDB_CONTEXT_DEMOTE_TESTS": "1"}` |
| 19 | discard | 0.5833 | 0.25 | [2, 1, 2, 3] | `{"CODEDB_CONTEXT_PHRASE": "1", "CODEDB_CONTEXT_PHRASE_BOOST": "2", "CODEDB_CONTEXT_IDENT_SYMBOLS": "0", "CODEDB_CONTEXT_MAX_CANDIDATES": "7", "CODEDB_CONTEXT_TOP_FILES": "5", "CODEDB_CONTEXT_DEMOTE_TESTS": "1"}` |
| 20 | discard | 0.6667 | 0.5 | [1, 3, 1, 3] | `{"CODEDB_CONTEXT_PHRASE": "1", "CODEDB_CONTEXT_PHRASE_BOOST": "2", "CODEDB_CONTEXT_IDENT_SYMBOLS": "1", "CODEDB_CONTEXT_MAX_CANDIDATES": "5", "CODEDB_CONTEXT_TOP_FILES": "3", "CODEDB_CONTEXT_DEMOTE_TESTS": "1"}` |
| 21 | discard | 0.6667 | 0.5 | [1, 3, 1, 3] | `{"CODEDB_CONTEXT_PHRASE": "1", "CODEDB_CONTEXT_PHRASE_BOOST": "2", "CODEDB_CONTEXT_IDENT_SYMBOLS": "1", "CODEDB_CONTEXT_MAX_CANDIDATES": "5", "CODEDB_CONTEXT_TOP_FILES": "8", "CODEDB_CONTEXT_DEMOTE_TESTS": "1"}` |
| 22 | discard | 0.5417 | 0.25 | [2, 3, 1, 3] | `{"CODEDB_CONTEXT_PHRASE": "1", "CODEDB_CONTEXT_PHRASE_BOOST": "2", "CODEDB_CONTEXT_IDENT_SYMBOLS": "0", "CODEDB_CONTEXT_MAX_CANDIDATES": "5", "CODEDB_CONTEXT_TOP_FILES": "5", "CODEDB_CONTEXT_DEMOTE_TESTS": "1"}` |
| 23 | discard | 0.6667 | 0.5 | [1, 3, 1, 3] | `{"CODEDB_CONTEXT_PHRASE": "1", "CODEDB_CONTEXT_PHRASE_BOOST": "2", "CODEDB_CONTEXT_IDENT_SYMBOLS": "1", "CODEDB_CONTEXT_MAX_CANDIDATES": "3", "CODEDB_CONTEXT_TOP_FILES": "5", "CODEDB_CONTEXT_DEMOTE_TESTS": "1"}` |
| 24 | discard | 0.0 | 0.0 | [None, None, None, None] | `{"CODEDB_CONTEXT_PHRASE": "0", "CODEDB_CONTEXT_PHRASE_BOOST": "2", "CODEDB_CONTEXT_IDENT_SYMBOLS": "1", "CODEDB_CONTEXT_MAX_CANDIDATES": "5", "CODEDB_CONTEXT_TOP_FILES": "8", "CODEDB_CONTEXT_DEMOTE_TESTS": "1"}` |
| 25 | discard | 0.5417 | 0.25 | [2, 3, 1, 3] | `{"CODEDB_CONTEXT_PHRASE": "1", "CODEDB_CONTEXT_PHRASE_BOOST": "2", "CODEDB_CONTEXT_IDENT_SYMBOLS": "0", "CODEDB_CONTEXT_MAX_CANDIDATES": "5", "CODEDB_CONTEXT_TOP_FILES": "8", "CODEDB_CONTEXT_DEMOTE_TESTS": "1"}` |
| 26 | discard | 0.0 | 0.0 | [None, None, None, None] | `{"CODEDB_CONTEXT_PHRASE": "0", "CODEDB_CONTEXT_PHRASE_BOOST": "2", "CODEDB_CONTEXT_IDENT_SYMBOLS": "1", "CODEDB_CONTEXT_MAX_CANDIDATES": "5", "CODEDB_CONTEXT_TOP_FILES": "5", "CODEDB_CONTEXT_DEMOTE_TESTS": "1"}` |
| 27 | discard | 0.6458 | 0.5 | [1, 3, 1, 4] | `{"CODEDB_CONTEXT_PHRASE": "1", "CODEDB_CONTEXT_PHRASE_BOOST": "2", "CODEDB_CONTEXT_IDENT_SYMBOLS": "1", "CODEDB_CONTEXT_MAX_CANDIDATES": "5", "CODEDB_CONTEXT_TOP_FILES": "5", "CODEDB_CONTEXT_DEMOTE_TESTS": "0"}` |
| 28 | discard | 0.6458 | 0.5 | [1, 3, 1, 4] | `{"CODEDB_CONTEXT_PHRASE": "1", "CODEDB_CONTEXT_PHRASE_BOOST": "2", "CODEDB_CONTEXT_IDENT_SYMBOLS": "1", "CODEDB_CONTEXT_MAX_CANDIDATES": "5", "CODEDB_CONTEXT_TOP_FILES": "5", "CODEDB_CONTEXT_DEMOTE_TESTS": "0"}` |
| 29 | keep | 0.8333 | 0.75 | [1, 1, 1, 3] | `{"CODEDB_CONTEXT_PHRASE": "1", "CODEDB_CONTEXT_PHRASE_BOOST": "2", "CODEDB_CONTEXT_IDENT_SYMBOLS": "1", "CODEDB_CONTEXT_MAX_CANDIDATES": "7", "CODEDB_CONTEXT_TOP_FILES": "8", "CODEDB_CONTEXT_DEMOTE_TESTS": "1"}` |
| 30 | discard | 0.8125 | 0.75 | [1, 1, 1, 4] | `{"CODEDB_CONTEXT_PHRASE": "1", "CODEDB_CONTEXT_PHRASE_BOOST": "2", "CODEDB_CONTEXT_IDENT_SYMBOLS": "1", "CODEDB_CONTEXT_MAX_CANDIDATES": "7", "CODEDB_CONTEXT_TOP_FILES": "8", "CODEDB_CONTEXT_DEMOTE_TESTS": "0"}` |
| 31 | discard | 0.6667 | 0.5 | [1, 3, 1, 3] | `{"CODEDB_CONTEXT_PHRASE": "1", "CODEDB_CONTEXT_PHRASE_BOOST": "2", "CODEDB_CONTEXT_IDENT_SYMBOLS": "1", "CODEDB_CONTEXT_MAX_CANDIDATES": "4", "CODEDB_CONTEXT_TOP_FILES": "8", "CODEDB_CONTEXT_DEMOTE_TESTS": "1"}` |
| 32 | discard | 0.8333 | 0.75 | [1, 1, 1, 3] | `{"CODEDB_CONTEXT_PHRASE": "1", "CODEDB_CONTEXT_PHRASE_BOOST": "2", "CODEDB_CONTEXT_IDENT_SYMBOLS": "1", "CODEDB_CONTEXT_MAX_CANDIDATES": "7", "CODEDB_CONTEXT_TOP_FILES": "3", "CODEDB_CONTEXT_DEMOTE_TESTS": "1"}` |
| 33 | discard | 0.0833 | 0.0 | [None, 3, None, None] | `{"CODEDB_CONTEXT_PHRASE": "0", "CODEDB_CONTEXT_PHRASE_BOOST": "2", "CODEDB_CONTEXT_IDENT_SYMBOLS": "1", "CODEDB_CONTEXT_MAX_CANDIDATES": "7", "CODEDB_CONTEXT_TOP_FILES": "8", "CODEDB_CONTEXT_DEMOTE_TESTS": "1"}` |
| 34 | discard | 0.8333 | 0.75 | [1, 1, 1, 3] | `{"CODEDB_CONTEXT_PHRASE": "1", "CODEDB_CONTEXT_PHRASE_BOOST": "1.5", "CODEDB_CONTEXT_IDENT_SYMBOLS": "1", "CODEDB_CONTEXT_MAX_CANDIDATES": "7", "CODEDB_CONTEXT_TOP_FILES": "8", "CODEDB_CONTEXT_DEMOTE_TESTS": "1"}` |
| 35 | discard | 0.6667 | 0.5 | [1, 3, 1, 3] | `{"CODEDB_CONTEXT_PHRASE": "1", "CODEDB_CONTEXT_PHRASE_BOOST": "2", "CODEDB_CONTEXT_IDENT_SYMBOLS": "1", "CODEDB_CONTEXT_MAX_CANDIDATES": "4", "CODEDB_CONTEXT_TOP_FILES": "8", "CODEDB_CONTEXT_DEMOTE_TESTS": "1"}` |
| 36 | discard | 0.7083 | 0.5 | [1, 2, 1, 3] | `{"CODEDB_CONTEXT_PHRASE": "1", "CODEDB_CONTEXT_PHRASE_BOOST": "3", "CODEDB_CONTEXT_IDENT_SYMBOLS": "1", "CODEDB_CONTEXT_MAX_CANDIDATES": "7", "CODEDB_CONTEXT_TOP_FILES": "8", "CODEDB_CONTEXT_DEMOTE_TESTS": "1"}` |
| 37 | discard | 0.8333 | 0.75 | [1, 1, 1, 3] | `{"CODEDB_CONTEXT_PHRASE": "1", "CODEDB_CONTEXT_PHRASE_BOOST": "2", "CODEDB_CONTEXT_IDENT_SYMBOLS": "1", "CODEDB_CONTEXT_MAX_CANDIDATES": "7", "CODEDB_CONTEXT_TOP_FILES": "5", "CODEDB_CONTEXT_DEMOTE_TESTS": "1"}` |
| 38 | discard | 0.6667 | 0.5 | [1, 3, 1, 3] | `{"CODEDB_CONTEXT_PHRASE": "1", "CODEDB_CONTEXT_PHRASE_BOOST": "2", "CODEDB_CONTEXT_IDENT_SYMBOLS": "1", "CODEDB_CONTEXT_MAX_CANDIDATES": "5", "CODEDB_CONTEXT_TOP_FILES": "8", "CODEDB_CONTEXT_DEMOTE_TESTS": "1"}` |
| 39 | discard | 0.8125 | 0.75 | [1, 1, 1, 4] | `{"CODEDB_CONTEXT_PHRASE": "1", "CODEDB_CONTEXT_PHRASE_BOOST": "2", "CODEDB_CONTEXT_IDENT_SYMBOLS": "1", "CODEDB_CONTEXT_MAX_CANDIDATES": "7", "CODEDB_CONTEXT_TOP_FILES": "8", "CODEDB_CONTEXT_DEMOTE_TESTS": "0"}` |
| 40 | discard | 0.8125 | 0.75 | [1, 1, 1, 4] | `{"CODEDB_CONTEXT_PHRASE": "1", "CODEDB_CONTEXT_PHRASE_BOOST": "2", "CODEDB_CONTEXT_IDENT_SYMBOLS": "1", "CODEDB_CONTEXT_MAX_CANDIDATES": "7", "CODEDB_CONTEXT_TOP_FILES": "8", "CODEDB_CONTEXT_DEMOTE_TESTS": "0"}` |
| 41 | discard | 0.8333 | 0.75 | [1, 1, 1, 3] | `{"CODEDB_CONTEXT_PHRASE": "1", "CODEDB_CONTEXT_PHRASE_BOOST": "1", "CODEDB_CONTEXT_IDENT_SYMBOLS": "1", "CODEDB_CONTEXT_MAX_CANDIDATES": "7", "CODEDB_CONTEXT_TOP_FILES": "8", "CODEDB_CONTEXT_DEMOTE_TESTS": "1"}` |
| 42 | discard | 0.8333 | 0.75 | [1, 1, 1, 3] | `{"CODEDB_CONTEXT_PHRASE": "1", "CODEDB_CONTEXT_PHRASE_BOOST": "1.5", "CODEDB_CONTEXT_IDENT_SYMBOLS": "1", "CODEDB_CONTEXT_MAX_CANDIDATES": "7", "CODEDB_CONTEXT_TOP_FILES": "8", "CODEDB_CONTEXT_DEMOTE_TESTS": "1"}` |
| 43 | discard | 0.0833 | 0.0 | [None, 3, None, None] | `{"CODEDB_CONTEXT_PHRASE": "0", "CODEDB_CONTEXT_PHRASE_BOOST": "2", "CODEDB_CONTEXT_IDENT_SYMBOLS": "1", "CODEDB_CONTEXT_MAX_CANDIDATES": "7", "CODEDB_CONTEXT_TOP_FILES": "8", "CODEDB_CONTEXT_DEMOTE_TESTS": "1"}` |
| 44 | discard | 0.5833 | 0.25 | [2, 1, 2, 3] | `{"CODEDB_CONTEXT_PHRASE": "1", "CODEDB_CONTEXT_PHRASE_BOOST": "2", "CODEDB_CONTEXT_IDENT_SYMBOLS": "0", "CODEDB_CONTEXT_MAX_CANDIDATES": "7", "CODEDB_CONTEXT_TOP_FILES": "8", "CODEDB_CONTEXT_DEMOTE_TESTS": "1"}` |
| 45 | discard | 0.6667 | 0.5 | [1, 3, 1, 3] | `{"CODEDB_CONTEXT_PHRASE": "1", "CODEDB_CONTEXT_PHRASE_BOOST": "2", "CODEDB_CONTEXT_IDENT_SYMBOLS": "1", "CODEDB_CONTEXT_MAX_CANDIDATES": "5", "CODEDB_CONTEXT_TOP_FILES": "8", "CODEDB_CONTEXT_DEMOTE_TESTS": "1"}` |
| 46 | discard | 0.8333 | 0.75 | [1, 1, 1, 3] | `{"CODEDB_CONTEXT_PHRASE": "1", "CODEDB_CONTEXT_PHRASE_BOOST": "2", "CODEDB_CONTEXT_IDENT_SYMBOLS": "1", "CODEDB_CONTEXT_MAX_CANDIDATES": "7", "CODEDB_CONTEXT_TOP_FILES": "5", "CODEDB_CONTEXT_DEMOTE_TESTS": "1"}` |
| 47 | discard | 0.8125 | 0.75 | [1, 1, 1, 4] | `{"CODEDB_CONTEXT_PHRASE": "1", "CODEDB_CONTEXT_PHRASE_BOOST": "2", "CODEDB_CONTEXT_IDENT_SYMBOLS": "1", "CODEDB_CONTEXT_MAX_CANDIDATES": "7", "CODEDB_CONTEXT_TOP_FILES": "8", "CODEDB_CONTEXT_DEMOTE_TESTS": "0"}` |
| 48 | discard | 0.8125 | 0.75 | [1, 1, 1, 4] | `{"CODEDB_CONTEXT_PHRASE": "1", "CODEDB_CONTEXT_PHRASE_BOOST": "2", "CODEDB_CONTEXT_IDENT_SYMBOLS": "1", "CODEDB_CONTEXT_MAX_CANDIDATES": "7", "CODEDB_CONTEXT_TOP_FILES": "8", "CODEDB_CONTEXT_DEMOTE_TESTS": "0"}` |
| 49 | discard | 0.6667 | 0.5 | [1, 3, 1, 3] | `{"CODEDB_CONTEXT_PHRASE": "1", "CODEDB_CONTEXT_PHRASE_BOOST": "2", "CODEDB_CONTEXT_IDENT_SYMBOLS": "1", "CODEDB_CONTEXT_MAX_CANDIDATES": "4", "CODEDB_CONTEXT_TOP_FILES": "8", "CODEDB_CONTEXT_DEMOTE_TESTS": "1"}` |
| 50 | discard | 0.6667 | 0.5 | [1, 3, 1, 3] | `{"CODEDB_CONTEXT_PHRASE": "1", "CODEDB_CONTEXT_PHRASE_BOOST": "2", "CODEDB_CONTEXT_IDENT_SYMBOLS": "1", "CODEDB_CONTEXT_MAX_CANDIDATES": "5", "CODEDB_CONTEXT_TOP_FILES": "8", "CODEDB_CONTEXT_DEMOTE_TESTS": "1"}` |

# OpenClaw × graff × codedb — hard suite

- corpus: `/tmp/openclaw-hillclimb` @ `1c35795`
- model: `codex/5.6-luna`
- codedb: `0.2.5841-context-phrase`

| case | pass | in | cached | out | api | tools | answer |
|---|---|---:|---:|---:|---:|---|---|
| task-lan-ipv4 | True | 77224 | 58368 | 199 | 5 | codedb,codedb,codedb,codedb | `src/gateway/net.ts:23` |
| task-apply-patch | True | 82755 | 58368 | 278 | 5 | codedb,codedb,codedb,codedb,codedb,codedb | `src/agents/apply-patch.ts:129` |
| task-version-fast-path | True | 79310 | 59392 | 211 | 5 | codedb,codedb,codedb,read_file | `src/entry.ts:102` |
| task-file-lan | True | 30068 | 13824 | 61 | 2 | codedb | `src/gateway/net.ts` |
| **total** | 4/4 | **269357** | **189952** | **749** | **17** | | |

Uncached input tokens (in - cached): **79405**.
score=100

# OpenClaw × graff × codedb — hard suite

- corpus: `/tmp/react-hillclimb` @ `eb8feb7`
- model: `codex/5.6-luna`
- codedb: `0.2.5841-cross-repo`

| case | pass | in | cached | out | api | tools | answer |
|---|---|---:|---:|---:|---:|---|---|
| task-dom-concurrent-root | False | 42881 | 26112 | 394 | 7 | codedb,codedb,codedb,codedb,bash,read_file | `packages/react-dom/src/client/ReactDOMRoot.js:249` |
| task-scheduler-message-loop | True | 64550 | 47616 | 368 | 8 | codedb,codedb,codedb,codedb,codedb,codedb,bash | `packages/scheduler/src/forks/Scheduler.js:553` |
| task-passive-after-commit | False | 25439 | 14848 | 297 | 4 | codedb,codedb,read_file,read_file | `packages/react-reconciler/src/ReactFiberWorkLoop.js:3815` |
| task-file-hooks-dispatch | True | 17473 | 10240 | 246 | 3 | codedb,codedb | `packages/react-reconciler/src/ReactFiberHooks.js` |
| **total** | 2/4 | **150343** | **98816** | **1305** | **22** | | |

Uncached input tokens (in - cached): **51527**.
score=50

# OpenClaw × graff × codedb — hard suite

- corpus: `/tmp/openclaw-hillclimb` @ `1c35795`
- model: `codex/5.6-luna`
- codedb: `0.2.5841-context-phrase`

| case | pass | in | cached | out | api | tools | answer |
|---|---|---:|---:|---:|---:|---|---|
| task-lan-ipv4 | True | 77311 | 58368 | 170 | 5 | codedb,codedb,codedb,codedb | `src/gateway/net.ts:23` |
| task-apply-patch | False | 139902 | 116224 | 672 | 8 | codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,read_file,read_file | `src/agents/apply-patch.ts:1` |
| task-version-fast-path | True | 171965 | 146944 | 496 | 10 | codedb,codedb,codedb,codedb,codedb,codedb,read_file,read_file,codedb | `src/entry.ts:102` |
| task-file-lan | True | 62447 | 57344 | 159 | 4 | codedb,codedb,codedb | `src/gateway/net.ts` |
| **total** | 3/4 | **451625** | **378880** | **1497** | **27** | | |

Uncached input tokens (in - cached): **72745**.
score=75

# OpenClaw × graff × codedb — hard suite

- corpus: `/tmp/react-hillclimb` @ `eb8feb7`
- model: `codex/5.6-luna`
- codedb: `0.2.5841-cross-repo`

| case | pass | in | cached | out | api | tools | answer |
|---|---|---:|---:|---:|---:|---|---|
| task-dom-concurrent-root | False | 17702 | 10240 | 184 | 3 | codedb,read_file | `packages/react-dom/src/client/ReactDOMRoot.js:252` |
| task-scheduler-message-loop | True | 44741 | 32256 | 860 | 6 | codedb,codedb,codedb,codedb,codedb,read_file,bash | `packages/scheduler/src/forks/Scheduler.js:554` |
| task-passive-after-commit | False | 24457 | 19456 | 223 | 4 | codedb,codedb,read_file | `packages/react-reconciler/src/ReactFiberWorkLoop.js:3815` |
| task-file-hooks-dispatch | False | 23383 | 14848 | 192 | 4 | codedb,codedb,codedb | `packages/react-reconciler/src/ReactFiberConcurrentUpdates.js` |
| **total** | 1/4 | **110283** | **76800** | **1459** | **17** | | |

Uncached input tokens (in - cached): **33483**.
score=25

# OpenClaw × graff × codedb — hard suite

- corpus: `/tmp/openclaw-hillclimb` @ `1c35795`
- model: `codex/5.6-luna`
- codedb: `0.2.5841-context-phrase`

| case | pass | in | cached | out | api | tools | answer |
|---|---|---:|---:|---:|---:|---|---|
| task-lan-ipv4 | True | 75857 | 57344 | 220 | 5 | codedb,codedb,codedb,read_file | `src/gateway/net.ts:23` |
| task-apply-patch | True | 165398 | 139264 | 476 | 9 | codedb,codedb,codedb,read_file,bash,read_file,codedb,codedb | `src/agents/apply-patch.ts:129` |
| task-version-fast-path | True | 82617 | 62464 | 386 | 5 | codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb,codedb | `src/entry.ts:102` |
| task-file-lan | True | 61021 | 42496 | 184 | 4 | codedb,codedb,codedb | `src/gateway/net.ts` |
| **total** | 4/4 | **384893** | **301568** | **1266** | **23** | | |

Uncached input tokens (in - cached): **83325**.
score=100

# OpenClaw × graff × codedb — hard suite

- corpus: `/tmp/react-hillclimb` @ `eb8feb7`
- model: `codex/5.6-luna`
- codedb: `0.2.5841-cross-repo`

| case | pass | in | cached | out | api | tools | answer |
|---|---|---:|---:|---:|---:|---|---|
| task-dom-concurrent-root | False | 31027 | 21504 | 266 | 5 | codedb,codedb,codedb,read_file | `packages/react-dom/src/client/ReactDOMRoot.js:239` |
| task-scheduler-message-loop | True | 31155 | 25088 | 176 | 5 | codedb,codedb,codedb,read_file | `packages/scheduler/src/forks/Scheduler.js:553` |
| task-passive-after-commit | False | 25910 | 21504 | 195 | 4 | codedb,codedb,read_file | `packages/react-reconciler/src/ReactFiberWorkLoop.js:3815` |
| task-file-hooks-dispatch | True | 11414 | 4608 | 112 | 2 | codedb | `packages/react-reconciler/src/ReactFiberHooks.js` |
| **total** | 2/4 | **99506** | **72704** | **749** | **16** | | |

Uncached input tokens (in - cached): **26802**.
score=50

# OpenClaw × graff × codedb — hard suite

- corpus: `/tmp/openclaw-hillclimb` @ `1c35795`
- model: `codex/5.6-luna`
- codedb: `0.2.5841-context-phrase`

| case | pass | in | cached | out | api | tools | answer |
|---|---|---:|---:|---:|---:|---|---|
| task-lan-ipv4 | True | 94839 | 74240 | 249 | 6 | codedb,codedb,codedb,codedb,read_file | `src/gateway/net.ts:23` |
| task-apply-patch | True | 60932 | 55296 | 186 | 4 | codedb,codedb,codedb | `src/agents/apply-patch.ts:129` |
| task-version-fast-path | True | 115407 | 91136 | 270 | 7 | codedb,codedb,codedb,codedb,read_file,codedb | `src/entry.ts:102` |
| task-file-lan | True | 45997 | 41472 | 154 | 3 | codedb,codedb | `src/gateway/net.ts` |
| **total** | 4/4 | **317175** | **262144** | **859** | **20** | | |

Uncached input tokens (in - cached): **55031**.
score=100

# OpenClaw × graff × codedb — hard suite

- corpus: `/tmp/react-hillclimb` @ `eb8feb7`
- model: `codex/5.6-luna`
- codedb: `0.2.5841-cross-repo`

| case | pass | in | cached | out | api | tools | answer |
|---|---|---:|---:|---:|---:|---|---|
| task-dom-concurrent-root | False | 42810 | 31744 | 350 | 7 | codedb,codedb,codedb,codedb,bash,read_file | `packages/react-dom/src/client/ReactDOMRoot.js:252` |
| task-scheduler-message-loop | True | 25370 | 15872 | 142 | 4 | codedb,codedb,read_file | `packages/scheduler/src/forks/Scheduler.js:553` |
| task-passive-after-commit | False | 18741 | 9216 | 153 | 3 | codedb,read_file | `packages/react-reconciler/src/ReactFiberWorkLoop.js:3815` |
| task-file-hooks-dispatch | True | 36049 | 26112 | 314 | 6 | codedb,codedb,codedb,codedb,codedb | `packages/react-reconciler/src/ReactFiberHooks.js` |
| **total** | 2/4 | **122970** | **82944** | **959** | **20** | | |

Uncached input tokens (in - cached): **40026**.
score=50

# OpenClaw × graff × codedb — hard suite

- corpus: `/tmp/openclaw-hillclimb` @ `1c35795`
- model: `codex/5.6-luna`
- codedb: `0.2.5841-context-phrase`

| case | pass | in | cached | out | api | tools | answer |
|---|---|---:|---:|---:|---:|---|---|
| task-lan-ipv4 | True | 93827 | 88064 | 232 | 6 | codedb,codedb,codedb,codedb,codedb | `src/gateway/net.ts:23` |
| task-apply-patch | True | 31151 | 13824 | 110 | 2 | codedb,codedb,codedb | `src/agents/apply-patch.ts:129` |
| task-version-fast-path | True | 63721 | 58368 | 273 | 4 | codedb,codedb,codedb,codedb,read_file | `src/entry.ts:102` |
| task-file-lan | True | 45020 | 27648 | 117 | 3 | codedb,codedb | `src/gateway/net.ts` |
| **total** | 4/4 | **233719** | **187904** | **732** | **15** | | |

Uncached input tokens (in - cached): **45815**.
score=100

# OpenClaw × graff × codedb — hard suite

- corpus: `/tmp/react-hillclimb` @ `eb8feb7`
- model: `codex/5.6-luna`
- codedb: `0.2.5841-cross-repo`

| case | pass | in | cached | out | api | tools | answer |
|---|---|---:|---:|---:|---:|---|---|
| task-dom-concurrent-root | False | 25208 | 15872 | 221 | 4 | codedb,codedb,read_file | `packages/react-dom/src/client/ReactDOMRoot.js:239` |
| task-scheduler-message-loop | True | 31158 | 20480 | 204 | 5 | codedb,codedb,codedb,read_file | `packages/scheduler/src/forks/Scheduler.js:553` |
| task-passive-after-commit | False | 18623 | 5632 | 146 | 3 | codedb,read_file | `packages/react-reconciler/src/ReactFiberRootScheduler.js:546` |
| task-file-hooks-dispatch | True | 35347 | 30720 | 319 | 6 | codedb,codedb,codedb,codedb,codedb | `packages/react-reconciler/src/ReactFiberHooks.js` |
| **total** | 2/4 | **110336** | **72704** | **890** | **18** | | |

Uncached input tokens (in - cached): **37632**.
score=50
