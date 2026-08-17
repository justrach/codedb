# Embedding architecture for codedb

Teacher: [moonshotai/Kimi-K3](https://huggingface.co/moonshotai/Kimi-K3)
(2.8T MoE, 104B active, 1M context).
Student: a **~100M MoE code embedder with ~5M active** — K3's sparsity
trick, scaled down so query embed is one short forward.
**Serve that student on a cloud GPU with ZDR** (zero data retention) for
end users. Parallel streams make batch embed / teacher-label cheap.
Bootstrap the (task, chunk) KV pairs from the **codedb harness +
codegraff**, then distill. Judge is still fewer `codedb` calls on more
than one repo.

K3 is the wrong thing to *serve*. It is the right thing to *distill from*.
The 5M-active student is what the ZDR GPU runs.

## Why this exists

codedb already ranks with BM25+ (`k1=1.2`, `b=0.75`, `delta=0.5`),
identifier split, phrase boost, symbol-definition boost, call-graph
centrality, and test-path demote. That stack is fast and lexical. It
loses when the task and the gold file share intent but not the winning
tokens:

- OpenClaw: "gateway bind" outranks `src/gateway/net.ts` for LAN IPv4.
- React: a `flushPassiveEffects()` *call site* outranks the definition.

Knob search cut dual-repo calls 28 → 25. The leftover misses need a
representation that is **not** a bag of query words. A static mean of
term vectors cannot down-weight "gateway" / "bind". A tiny MoE can:
routing picks a different expert mix for "LAN IPv4 selection" than for
"gateway bind", even when those strings share tokens.

## Why Kimi-K3 as the teacher

K3 is Stable LatentMoE: 896 experts, 16 active, 104B active / 2.8T
stored. High search space, cheap per token. That is the recipe we copy,
not the weights.

Use K3 offline only:

- Grade `(task, chunk)` 0–3 (unrelated / mention / implements / definition).
- Write symbol-free paraphrases (same shape as the hard suite).
- Pick BM25 near-misses that look right and are wrong.
- Explicit definition-vs-use pairs (the React miss).

API `kimi-k3` or vLLM/SGLang. Never load K3 inside codedb.

## The student: ~100M stored, ~5M active, high expert count

Not a 5M dense model. Not a static table. A **sparse MoE bi-encoder**:

| | Kimi-K3 (teacher) | student embedder |
|---|---|---|
| Job | generate / grade | embed task ↔ chunk |
| Stored | 2.8T | ~100M |
| Active / token | 104B | **~5M** |
| Experts | 896, top-16 | 64–128, top-2 |
| Hidden | 7168 | 256 |
| Layers | 93 (KDA+MLA) | 6 dense attn + MoE FFN |
| Out | next-token | 256-d L2 vector |

A layout that actually hits the budget:

```
d = 256, L = 6
attn (always on):  4 · d² · L  ≈ 1.6M
expert FFN:        2 · d · 512  = 0.26M each
top-2 · L:         0.26M · 2 · 6 ≈ 3.1M
────────────────────────────────
active             ≈ 4.7M
experts E = 64:    0.26M · 64 · 6 ≈ 100M stored (+ attn + router)
```

That is K3's deal at toy scale: **wide search space** (64 specialists),
**tiny compute** (2 of them fire). Experts can specialize the way the
hill-climb misses split:

- NL-task vs identifier-ish tokens
- definition span vs call site
- path/filename vs body
- "network / bind / listen" vs "LAN / IPv4 / interface"

Shared-weight bi-encoder. Query and chunk go through the same MoE.
Mean-pool + linear → 256-d, L2-normalized. InfoNCE + K3 soft labels +
hard negatives. Temperature ~0.05.

## Graft: freeze Qwen3-Embedding-8B, add the MoE (not LoRA)

Do not pre-train the 100M from noise. Do not LoRA the 8B.
[Qwen3-Embedding-8B](https://huggingface.co/Qwen/Qwen3-Embedding-8B) is
already a code retriever: 36 layers, last-token pool, **MRL 32–4096**
(we take 256), instruction-aware, Apache-2.0. Freeze every Qwen weight.

The thing we train is a **full-rank residual MoE on the vector**:

```
Qwen3-8B (frozen) ─MRL 256─► q
                              │
                    router top-2 / 64 experts
                    E_i: 256 → 512 → 256   (~0.26M each)
                              │
                 out = L2( q + Σ g_i E_i(q) )
```

That is ~5M active, ~17M stored (64×0.26M + router). Not a low-rank
update. Experts can actually rotate "gateway bind" off the LAN gold
because they have a full 256-d residual, not a rank-8 hint.

100k (task, chunk) pairs is the right size for *this* head. The 8B
already did pre-train. We only teach the residual the hill-climb misses.

Two serve modes, same weights:

| mode | query cost | when |
|---|---|---|
| **graft** | 8B + 5M on the ZDR GPU | index + first ship |
| **distill** | 5M-active student only | after the graft beats 25/75 |

Index-time chunks still batch. Instruction:
`Instruct: Retrieve the implementing code span for this question\nQuery:`

Qwen never loads inside the Zig process. `CODEDB_EMBED_URL` hits the
ZDR box that runs frozen 8B + the MoE head.

On Apple Silicon the local box *is* that GPU: M-series unified memory,
4-bit Qwen3-Embedding-8B (~4.3 GB) plus one fused Metal kernel for the
MoE residual (1 threadgroup / row, 256 threads, L1-resident, `math_mode=fast`).
Working set is a few KB. Dispatch cost dominates, so we do **not** split
router / up / down / L2 into four kernels. Bench on M3 Ultra: 256 vecs
in ~2.9 ms (~90k vec/s) at `max_abs_err 2e-7` vs the numpy reference.

The last layer is not another softmax MHA and not LoRA. It is **Polar Diff-Delta**:

- [Diff Transformer](https://arxiv.org/abs/2410.05258) — two softmax maps, subtract; cancels BM25 common-mode ("gateway bind")
- [Gated DeltaNet](https://arxiv.org/abs/2412.06464) — write last-16 Qwen tokens into a 64×64 associative memory
- [Forgetting Attention / FoX](https://arxiv.org/abs/2503.02130) — data-dependent forget on the logits
- Modern Hopfield retrieve from that memory, everything L2 on the sphere

Train: `experiments/embed-distill/metal/train_pdd.py`

Index time: embed each symbol/file-head chunk once **in parallel batches**
on the ZDR GPU, mmap `f16[n, 256]` next to the snapshot, rebuild on the
dirty-set. Query time: one 5M-active forward on the task string
(~20–80 tokens) via the same endpoint, cosine against the BM25 shortlist
of 64. That is milliseconds plus one short HTTPS hop, not a MiniLM-per-chunk walk.

A 5M *dense* transformer is the wrong object: no search space, same
active cost, worse specialists. A static table is cheaper still and
worth an ablation, but it cannot fix "gateway bind" — it is still a bag.

## Units of embedding

Do not embed whole files. Use units codedb already owns:

| unit | source | when |
|---|---|---|
| symbol | `findAllSymbols` span + signature + 8 lines | default |
| file head | first 80 lines + path | no symbols |
| doc hop | markdown title + first paragraph | `document_hops > 0` |

Path is in the text. Query is the raw `codedb_context` task, not the
extracted keywords.

## Where it plugs into codedb

```
score = bm25 + λ_sym * has_def + λ_vec * cosine(q, chunk)
```

`searchContentRanked` still proposes the top 64. Query embed is one
5M-active forward on the task string. Cosine vs the shortlist. Same
skip lists as the walker (no `.env`).

```
CODEDB_CONTEXT_VEC=0|1
CODEDB_CONTEXT_VEC_LAMBDA=1
CODEDB_CONTEXT_VEC_TOP=64
CODEDB_EMBED_URL=https://…          # ZDR GPU, OpenAI-compat /v1/embeddings
CODEDB_EMBED_KEY=…
CODEDB_EMBED_MODEL=codedb-moe-5m
```

Fingerprint those in `rankingEnvFingerprint`.

## Serve: cloud GPU + ZDR

End-user **task strings** go to a GPU that does not retain them.
Chunk vectors are computed at index time in **batched parallel streams**
(32–128 texts / request) and stored next to the snapshot. Query time is
one short batch of 1.

```
index:  chunks ──batch 32──▶ ZDR GPU ──▶ f16[n, 256] mmap
query:  task  ──stream  1──▶ ZDR GPU ──▶ 256-d  ──cosine vs top 64
```

ZDR means: no request logs, no training on customer code, header
`X-Zero-Data-Retention: 1`. Local mmap-only is still the offline / airgap
path. The product default for hosted users is the ZDR endpoint.

Parallel streams are why this is cheap: teacher grades and chunk embeds
are embarrassingly parallel. 16 HTTP workers × 32-wide batches saturate
a single mid GPU without keeping any pair around after the response.

## Bootstrap KV pairs (codedb harness + codegraff)

Do not wait on a labeled corpus. Mine it from the suites we already run:

| k (query) | v (chunk) | seed label | source |
|---|---|---|---|
| hard-suite task | gold span ±12 | 3 | `cases.json` |
| same task | BM25 near-miss file head | 0 | `codedb context` top-9 |
| same task | file graff opened that is not gold | 1 | graff trajectory |
| K3 paraphrase of the task | gold span | 3 | teacher, offline |

Harness: `experiments/embed-distill/`

```
python3 experiments/embed-distill/bootstrap_pairs.py --workers 8
python3 experiments/embed-distill/flatten_kv.py
python3 experiments/embed-distill/label_teacher.py --workers 16   # or --dry-run
python3 experiments/embed-distill/embed_zdr.py --batch 32         # needs CODEDB_EMBED_URL
```

`bootstrap_pairs.py` hits both frozen corpora in parallel. Gold is the
positive; every other `codedb context` hit is a hard negative. Optional
graff pass (same `run.py` as the hill-climb) adds the files the agent
actually opened. That is the bootstrap: no human labels, no leak of
symbol names into the query, same judge as the product.

## Data, so we do not overfit

Train on OpenClaw `@ 1c35795`, React `@ eb8feb7`, and codedb. Hold one
repo out. Keep only if graff+luna **call count drops** on both suites
and score does not fall.

## Ship order

1. Mine KV pairs from the existing harness (this directory). Parallel.
2. Teacher-label in parallel streams (luna now, K3 when the key is set).
3. Distill the 100M/5M-active MoE; serve on a ZDR GPU.
4. `CODEDB_CONTEXT_VEC=1` blend in `handleContext`. Env off = BM25 only.
5. 50-step climb on λ, dual-repo call counts. Must beat 25 / 75.

If step 5 loses, delete the vec. BM25 stays.
