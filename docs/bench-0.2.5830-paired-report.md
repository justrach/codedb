# 0.2.5830 paired release benchmark

- Date: 2026-07-12
- Machine: Apple M3 Ultra Mac Studio, 28 cores, 256 GB, macOS 26.5.1
- Production baseline: `dd36e9431925014ee2bed80346669a4afee7e42e` (`v0.2.5829`)
- Pinned parity-harness baseline: `24e89c70d4f9cdaf5542a78d83d1890a42b4a046`
- Candidate: `91ecd6e27f2fe7bc5b4ad69641340cd12b39ca11`
- Compiler: Zig `0.17.0-dev.813+2153f8143`, executable SHA-256 `08abf236d78c05b8520431fbca99903ff98653b2f1cd1c3665a7f8c91247421c`
- Corpus source tree: `e705e2623b28d2456eb9d4934817b79f4de35216`
- Corpus: fixed 21-file set copied from `dd36e94`, plus generated `src/bench_target.zig`; fingerprint `13647708728832762745`
- Order: 20 counterbalanced AB/BA pairs, verified from per-sample pair/order/sequence metadata
- Regression gate: paired median >10% and >50,000 ns
- Parity gate: duration-normalized full JSON-RPC response hash rolled across every measured iteration

Corpus parity: **PASS**

Source/compiler/order provenance: **PASS**

| Tool | Base median | Head median | Paired delta | Abs delta | 95% CI | Head wins | Output parity | Status |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- |
| `codedb_bundle` | 18620 | 13360 | -28.42% | -5160 | [-29.76%, -22.57%] | 20/20 | PASS | OK |
| `codedb_changes` | 2965 | 3020 | +0.00% | +0 | [-2.64%, +5.10%] | 9/20 (2 ties) | PASS | OK |
| `codedb_context` | 120150 | 106030 | -11.68% | -13910 | [-14.05%, -9.34%] | 19/20 | PASS | OK |
| `codedb_deps` | 60 | 70 | +25.00% | +15 | [-12.50%, +36.67%] | 8/20 | PASS | NOISE |
| `codedb_edit` | 56400 | 58850 | +3.12% | +1700 | [-7.39%, +11.18%] | 8/20 | PASS | OK |
| `codedb_find` | 640 | 675 | +5.71% | +35 | [-0.75%, +13.38%] | 6/20 (2 ties) | PASS | OK |
| `codedb_hot` | 5150 | 4040 | -22.15% | -1095 | [-25.30%, -16.68%] | 20/20 | PASS | OK |
| `codedb_outline` | 5690 | 2215 | -60.75% | -3475 | [-61.78%, -58.63%] | 20/20 | PASS | OK |
| `codedb_read` | 16325 | 14620 | -6.29% | -985 | [-9.29%, -4.80%] | 15/20 | PASS | OK |
| `codedb_search` | 10790 | 10665 | -1.41% | -150 | [-4.95%, +1.94%] | 13/20 | PASS | OK |
| `codedb_snapshot` | 33800 | 33875 | +0.15% | +50 | [-1.45%, +3.30%] | 9/20 (1 tie) | SKIP | OK |
| `codedb_status` | 1975 | 1935 | -1.70% | -35 | [-4.99%, +3.53%] | 12/20 (1 tie) | SKIP | OK |
| `codedb_symbol` | 12615 | 2285 | -81.97% | -10355 | [-82.38%, -80.91%] | 20/20 | PASS | OK |
| `codedb_tree` | 5915 | 1925 | -67.55% | -3995 | [-68.73%, -65.06%] | 20/20 | PASS | OK |
| `codedb_word` | 3250 | 2035 | -36.89% | -1195 | [-38.77%, -35.65%] | 20/20 | PASS | OK |

`codedb_snapshot` is exempt because output embeds its temporary destination path. `codedb_status` is exempt because it intentionally exposes cache counters. Both exemptions are declared in the benchmark cases, must match between revisions, and are accepted only through the comparator's explicit tool allowlist.

No single-run minima were used. The confidence intervals are deterministic bootstrap intervals for the paired percentage median.
