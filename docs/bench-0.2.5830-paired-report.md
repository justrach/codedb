# 0.2.5830 paired release benchmark

- Date: 2026-07-12
- Machine: Apple M3 Ultra Mac Studio, 28 cores, 256 GB, macOS 26.5.1
- Production baseline: `dd36e9431925014ee2bed80346669a4afee7e42e` (`v0.2.5829`)
- Pinned parity-harness baseline: `24e89c70d4f9cdaf5542a78d83d1890a42b4a046`
- Candidate: `bc72bfca4f4dcb9316f2f00f0ca78ab18c4e3c74` (tree `2832e31eb08f7695518ad0d6c23967beb268d16b`)
- Compiler: Zig `0.17.0-dev.813+2153f8143`, executable SHA-256 `08abf236d78c05b8520431fbca99903ff98653b2f1cd1c3665a7f8c91247421c`
- Corpus source tree: `e705e2623b28d2456eb9d4934817b79f4de35216`
- Corpus: fixed 21-file set copied from `dd36e94`, plus generated `src/bench_target.zig`; fingerprint `13647708728832762745`
- Order: 20 counterbalanced AB/BA pairs, verified from per-sample pair/order/sequence metadata
- Regression gate: paired median >10% and >50,000 ns
- Parity gate: duration-normalized full JSON-RPC response hash rolled across every measured iteration
- Raw evidence archive: `bench-0.2.5830-paired-samples.tar.gz`, SHA-256 `104edc6875a9d121d2e5a4c1e69c12735f2c60128e48ae384aa8c6cfb950bc24` (attached to the GitHub Release)

Corpus parity: **PASS**

Source/compiler/order provenance: **PASS**

| Tool | Base median | Head median | Paired delta | Abs delta | 95% CI | Head wins | Output parity | Status |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- |
| `codedb_bundle` | 16980 | 12230 | -27.73% | -4790 | [-29.25%, -25.72%] | 20/20 | PASS | OK |
| `codedb_changes` | 2825 | 2830 | +1.77% | +50 | [-1.76%, +3.37%] | 7/20 (1 tie) | PASS | OK |
| `codedb_context` | 110990 | 97730 | -11.89% | -13230 | [-12.55%, -11.13%] | 20/20 | PASS | OK |
| `codedb_deps` | 60 | 60 | +0.00% | +0 | [+0.00%, +20.00%] | 5/20 (6 ties) | PASS | OK |
| `codedb_edit` | 51700 | 50900 | -2.04% | -1100 | [-5.09%, +2.52%] | 12/20 | PASS | OK |
| `codedb_find` | 600 | 590 | -3.27% | -20 | [-7.43%, +3.39%] | 11/20 (1 tie) | PASS | OK |
| `codedb_hot` | 4560 | 3750 | -17.81% | -820 | [-19.48%, -16.70%] | 20/20 | PASS | OK |
| `codedb_outline` | 5280 | 2115 | -59.79% | -3170 | [-60.91%, -59.05%] | 20/20 | PASS | OK |
| `codedb_read` | 14400 | 13630 | -4.81% | -685 | [-6.70%, -3.40%] | 18/20 | PASS | OK |
| `codedb_search` | 9770 | 9885 | +1.60% | +155 | [-1.02%, +2.76%] | 8/20 (1 tie) | PASS | OK |
| `codedb_snapshot` | 31225 | 31200 | -0.24% | -75 | [-0.88%, +0.24%] | 12/20 (1 tie) | SKIP | OK |
| `codedb_status` | 1815 | 1815 | -0.22% | -5 | [-2.69%, +1.91%] | 10/20 (2 ties) | SKIP | OK |
| `codedb_symbol` | 11780 | 2155 | -81.72% | -9625 | [-82.12%, -81.31%] | 20/20 | PASS | OK |
| `codedb_tree` | 5445 | 1780 | -67.60% | -3700 | [-68.49%, -66.73%] | 20/20 | PASS | OK |
| `codedb_word` | 3035 | 1915 | -37.16% | -1135 | [-38.46%, -35.19%] | 20/20 | PASS | OK |

`codedb_snapshot` is exempt because output embeds its temporary destination path. `codedb_status` is exempt because it intentionally exposes cache counters. Both exemptions are declared in the benchmark cases, must match between revisions, and are accepted only through the comparator's explicit tool allowlist.

No single-run minima were used. The confidence intervals are deterministic bootstrap intervals for the paired percentage median.
