# 0.2.5830 paired release benchmark

- Date: 2026-07-12
- Machine: Apple M3 Ultra Mac Studio, 28 cores, 256 GB, macOS 26.5.1
- Production baseline: `dd36e9431925014ee2bed80346669a4afee7e42e` (`v0.2.5829`)
- Pinned parity-harness baseline: `24e89c70d4f9cdaf5542a78d83d1890a42b4a046`
- Candidate: `33ea66c01a1bf017ec2edfdeb8fc436d37e7e78b`
- Compiler: Zig `0.17.0-dev.813+2153f8143` for both binaries
- Corpus: immutable production-baseline worktree shared by both binaries
- Order: 20 counterbalanced AB/BA pairs
- Regression gate: paired median >10% and >50,000 ns
- Parity gate: duration-normalized full JSON-RPC response hash rolled across every measured iteration

Corpus parity: **PASS**

| Tool | Base median | Head median | Paired delta | Abs delta | 95% CI | Head wins | Output parity | Status |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- |
| `codedb_bundle` | 17810 | 13660 | -25.26% | -4510 | [-28.50%, -22.73%] | 20/20 | PASS | OK |
| `codedb_changes` | 2880 | 2945 | +1.54% | +45 | [-1.09%, +3.70%] | 6/20 | PASS | OK |
| `codedb_context` | 114190 | 109220 | -7.06% | -7950 | [-7.90%, -3.96%] | 19/20 | PASS | OK |
| `codedb_deps` | 70 | 70 | +0.00% | +0 | [-15.56%, +18.33%] | 7/20 (5 ties) | PASS | OK |
| `codedb_edit` | 56150 | 56700 | +0.33% | +200 | [-6.32%, +4.35%] | 10/20 | PASS | OK |
| `codedb_find` | 635 | 630 | +0.00% | +0 | [-6.16%, +5.71%] | 9/20 (2 ties) | PASS | OK |
| `codedb_hot` | 4730 | 3870 | -19.18% | -880 | [-21.45%, -16.18%] | 20/20 | PASS | OK |
| `codedb_outline` | 5325 | 2130 | -60.39% | -3200 | [-61.16%, -59.50%] | 20/20 | PASS | OK |
| `codedb_read` | 14910 | 14490 | -2.75% | -400 | [-4.79%, -1.57%] | 15/20 | PASS | OK |
| `codedb_search` | 10180 | 10215 | +0.59% | +65 | [-1.82%, +3.04%] | 8/20 (1 tie) | PASS | OK |
| `codedb_snapshot` | 32075 | 31775 | -1.74% | -550 | [-3.52%, +3.93%] | 12/20 | SKIP | OK |
| `codedb_status` | 1830 | 1905 | +3.75% | +70 | [-2.43%, +5.59%] | 8/20 (1 tie) | SKIP | OK |
| `codedb_symbol` | 11875 | 2225 | -81.63% | -9735 | [-82.11%, -81.11%] | 20/20 | PASS | OK |
| `codedb_tree` | 5670 | 1890 | -66.03% | -3750 | [-68.51%, -65.24%] | 20/20 | PASS | OK |
| `codedb_word` | 3105 | 1920 | -37.54% | -1155 | [-39.28%, -36.71%] | 20/20 | PASS | OK |

`codedb_snapshot` is exempt because output embeds its temporary destination path. `codedb_status` is exempt because it intentionally exposes cache counters. Both exemptions are declared in the benchmark cases and must match between revisions.

No single-run minima were used. The confidence intervals are deterministic bootstrap intervals for the paired percentage median.
