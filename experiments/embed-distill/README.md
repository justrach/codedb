# embed-distill — bootstrap KV pairs for the 5M-active MoE

Mine `(task, chunk, label)` with **graff + Kimi**, then delete the clones.
`kimi-for-coding` (flat-rate login) 400s; `kimi-k2.7-code` is the working teacher.

```bash
# ~100k pairs, 14 repos, clones under /tmp/embed-mine are deleted after each repo
python3 experiments/embed-distill/mine_100k.py --target 100000 --graff-workers 4

# cheap codedb-only dump of the 8 hard cases
python3 experiments/embed-distill/bootstrap_pairs.py --workers 8
python3 experiments/embed-distill/flatten_kv.py
```

`kv.100k.jsonl` rows:

```json
{"k": "Where is the logic that converts a redaction pattern…", "v": "src/logging/redact.ts…", "label": 3}
{"k": "…", "v": "<bm25 near-miss file head>", "label": 0}
```

Keep rule is unchanged: dual-repo graff call count must drop below 25 / 75.
