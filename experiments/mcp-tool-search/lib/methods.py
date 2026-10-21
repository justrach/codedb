"""Local reproductions of Zed-style MCP tool-search approaches."""

from __future__ import annotations

import math
import re
import time
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from typing import Any, Callable, Iterable

VERBS = {
    "create",
    "get",
    "list",
    "update",
    "delete",
    "search",
    "send",
    "add",
    "remove",
    "set",
    "fetch",
    "post",
    "put",
    "run",
    "query",
    "make",
    "open",
    "show",
    "read",
    "write",
    "find",
}

IDENT_SPLIT = re.compile(
    r"[^a-zA-Z0-9]+|(?<=[a-z])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])|(?<=[a-zA-Z])(?=[0-9])|(?<=[0-9])(?=[a-zA-Z])"
)


def split_ident(text: str) -> list[str]:
    parts: list[str] = []
    for raw in IDENT_SPLIT.split(text):
        tok = raw.strip().lower()
        if len(tok) >= 2:
            parts.append(tok)
    return parts


def tokenize(text: str, *, split_idents: bool = True) -> list[str]:
    if not text:
        return []
    if split_idents:
        return split_ident(text)
    return [t for t in re.split(r"[^a-z0-9]+", text.lower()) if len(t) >= 2]


@dataclass
class Ranked:
    tool_id: str
    score: float


class Timer:
    def __init__(self) -> None:
        self.samples_ms: list[float] = []

    def add(self, seconds: float) -> None:
        self.samples_ms.append(seconds * 1000.0)

    def percentile(self, p: float) -> float:
        if not self.samples_ms:
            return 0.0
        xs = sorted(self.samples_ms)
        if len(xs) == 1:
            return xs[0]
        k = (len(xs) - 1) * (p / 100.0)
        f = int(math.floor(k))
        c = int(math.ceil(k))
        if f == c:
            return xs[f]
        return xs[f] * (c - k) + xs[c] * (k - f)


def rrf(rank_lists: list[list[str]], k: int = 60) -> list[Ranked]:
    scores: dict[str, float] = defaultdict(float)
    for ranks in rank_lists:
        for i, tid in enumerate(ranks):
            scores[tid] += 1.0 / (k + i + 1)
    return [Ranked(tid, s) for tid, s in sorted(scores.items(), key=lambda x: -x[1])]


class BM25Index:
    def __init__(self, k1: float = 1.5, b: float = 0.75, plus_delta: float = 0.0) -> None:
        self.k1 = k1
        self.b = b
        self.plus_delta = plus_delta
        self.doc_ids: list[str] = []
        self.tf: list[Counter[str]] = []
        self.dl: list[int] = []
        self.df: Counter[str] = Counter()
        self.avgdl = 0.0
        self.n = 0

    def build(self, docs: list[tuple[str, list[str]]]) -> float:
        t0 = time.perf_counter()
        self.doc_ids = []
        self.tf = []
        self.dl = []
        self.df = Counter()
        for did, tokens in docs:
            self.doc_ids.append(did)
            c = Counter(tokens)
            self.tf.append(c)
            self.dl.append(len(tokens))
            self.df.update(c.keys())
        self.n = len(self.doc_ids)
        self.avgdl = (sum(self.dl) / self.n) if self.n else 0.0
        return time.perf_counter() - t0

    def idf(self, term: str) -> float:
        df = self.df.get(term, 0)
        return math.log(1.0 + (self.n - df + 0.5) / (df + 0.5))

    def score_query(self, q_tokens: list[str], term_weights: dict[str, float] | None = None) -> list[Ranked]:
        scores = [0.0] * self.n
        seen: set[str] = set()
        avgdl = self.avgdl or 1.0
        for term in q_tokens:
            if term in seen:
                continue
            seen.add(term)
            if term not in self.df:
                continue
            idf = self.idf(term)
            w = 1.0 if term_weights is None else term_weights.get(term, 1.0)
            for i, tfmap in enumerate(self.tf):
                tf = tfmap.get(term, 0)
                if tf == 0:
                    continue
                denom = tf + self.k1 * (1.0 - self.b + self.b * self.dl[i] / avgdl)
                scores[i] += w * idf * (tf * (self.k1 + 1.0) / denom + self.plus_delta)
        ranked = [Ranked(self.doc_ids[i], s) for i, s in enumerate(scores) if s > 0]
        ranked.sort(key=lambda r: -r.score)
        return ranked


class TfidfIndex:
    def __init__(self) -> None:
        self.doc_ids: list[str] = []
        self.tf: list[Counter[str]] = []
        self.df: Counter[str] = Counter()
        self.idf: dict[str, float] = {}
        self.norms: list[float] = []
        self.n = 0

    def build(self, docs: list[tuple[str, list[str]]]) -> float:
        t0 = time.perf_counter()
        self.doc_ids = []
        self.tf = []
        self.df = Counter()
        for did, tokens in docs:
            self.doc_ids.append(did)
            c = Counter(tokens)
            self.tf.append(c)
            self.df.update(c.keys())
        self.n = len(self.doc_ids)
        self.idf = {
            term: math.log((self.n - df + 0.5) / (df + 0.5) + 1.0) for term, df in self.df.items()
        }
        self.norms = []
        for c in self.tf:
            acc = 0.0
            for term, tf in c.items():
                w = (1.0 + math.log(tf)) * self.idf[term]
                acc += w * w
            self.norms.append(math.sqrt(acc) if acc else 1.0)
        return time.perf_counter() - t0

    def score_query(self, q_tokens: list[str]) -> list[Ranked]:
        qtf = Counter(q_tokens)
        qvec: dict[str, float] = {}
        qn = 0.0
        for term, tf in qtf.items():
            if term not in self.idf:
                continue
            w = (1.0 + math.log(tf)) * self.idf[term]
            qvec[term] = w
            qn += w * w
        qn = math.sqrt(qn) if qn else 1.0
        ranked: list[Ranked] = []
        for i, c in enumerate(self.tf):
            dot = 0.0
            for term, qw in qvec.items():
                tf = c.get(term, 0)
                if tf:
                    dot += qw * (1.0 + math.log(tf)) * self.idf[term]
            if dot > 0:
                ranked.append(Ranked(self.doc_ids[i], dot / (self.norms[i] * qn)))
        ranked.sort(key=lambda r: -r.score)
        return ranked


class TrigramIndex:
    def __init__(self) -> None:
        self.doc_ids: list[str] = []
        self.sets: list[set[str]] = []

    def _grams(self, text: str) -> set[str]:
        s = f"  {text.lower()} "
        return {s[i : i + 3] for i in range(len(s) - 2)}

    def build(self, docs: list[tuple[str, str]]) -> float:
        t0 = time.perf_counter()
        self.doc_ids = []
        self.sets = []
        for did, text in docs:
            self.doc_ids.append(did)
            self.sets.append(self._grams(text))
        return time.perf_counter() - t0

    def score_query(self, query: str) -> list[Ranked]:
        q = self._grams(query)
        if not q:
            return []
        ranked: list[Ranked] = []
        for did, grams in zip(self.doc_ids, self.sets):
            inter = len(q & grams)
            if inter:
                ranked.append(Ranked(did, inter / math.sqrt(len(q) * len(grams))))
        ranked.sort(key=lambda r: -r.score)
        return ranked


class HashedEmbedIndex:
    """Fallback local embedding: hashed character n-grams, not a neural model."""

    def __init__(self, dim: int = 256) -> None:
        self.dim = dim
        self.doc_ids: list[str] = []
        self.vecs: list[list[float]] = []

    def _embed(self, text: str) -> list[float]:
        v = [0.0] * self.dim
        s = text.lower()
        for n in (3, 4):
            for i in range(max(0, len(s) - n + 1)):
                h = hash(s[i : i + n])
                v[h % self.dim] += 1.0
                v[(h >> 8) % self.dim] -= 0.35
        nrm = math.sqrt(sum(x * x for x in v)) or 1.0
        return [x / nrm for x in v]

    def build(self, docs: list[tuple[str, str]]) -> float:
        t0 = time.perf_counter()
        self.doc_ids = [d for d, _ in docs]
        self.vecs = [self._embed(text) for _, text in docs]
        return time.perf_counter() - t0

    def score_query(self, query: str) -> list[Ranked]:
        qv = self._embed(query)
        ranked = []
        for did, dv in zip(self.doc_ids, self.vecs):
            score = sum(a * b for a, b in zip(qv, dv))
            if score > 0:
                ranked.append(Ranked(did, score))
        ranked.sort(key=lambda r: -r.score)
        return ranked


class DenseEmbedIndex:
    def __init__(self, model_name: str = "BAAI/bge-small-en-v1.5") -> None:
        self.model_name = model_name
        self.doc_ids: list[str] = []
        self.vecs = None
        self.model = None

    def available(self) -> bool:
        try:
            from fastembed import TextEmbedding  # noqa: F401

            return True
        except Exception:
            return False

    def build(self, docs: list[tuple[str, str]]) -> float:
        from fastembed import TextEmbedding
        import numpy as np

        t0 = time.perf_counter()
        self.model = TextEmbedding(model_name=self.model_name)
        self.doc_ids = [d for d, _ in docs]
        texts = [text for _, text in docs]
        mat = np.vstack(list(self.model.embed(texts)))
        norms = np.linalg.norm(mat, axis=1, keepdims=True)
        norms[norms == 0] = 1.0
        self.vecs = mat / norms
        return time.perf_counter() - t0

    def score_query(self, query: str) -> list[Ranked]:
        import numpy as np

        assert self.model is not None and self.vecs is not None
        q = np.vstack(list(self.model.embed([query])))[0]
        n = float(np.linalg.norm(q)) or 1.0
        q = q / n
        sims = self.vecs @ q
        order = np.argsort(-sims)
        ranked = []
        for i in order:
            if sims[i] <= 0:
                break
            ranked.append(Ranked(self.doc_ids[int(i)], float(sims[i])))
        return ranked


@dataclass
class MethodMeta:
    name: str
    needs_model: bool
    needs_api: bool
    notes: str = ""


@dataclass
class MethodResult:
    name: str
    rankings: dict[str, list[str]]
    query_ms: list[float]
    index_s: float
    rss_mb: float | None
    meta: MethodMeta
    skipped: str | None = None


def rss_mb() -> float | None:
    try:
        with open("/proc/self/status", encoding="utf-8") as f:
            for line in f:
                if line.startswith("VmRSS:"):
                    return int(line.split()[1]) / 1024.0
    except OSError:
        return None
    return None


def top_ids(ranked: Iterable[Ranked], k: int = 10) -> list[str]:
    out = []
    for r in ranked:
        if r.tool_id not in out:
            out.append(r.tool_id)
        if len(out) >= k:
            break
    return out


class CatalogSearch:
    def __init__(self, tools: list[dict[str, Any]]) -> None:
        self.tools = tools
        self.by_id = {t["id"]: t for t in tools}
        self.aliases: dict[str, str] = {}
        for t in tools:
            for a in t.get("aliases") or [t["server"]]:
                self.aliases[a.lower()] = t["server"]

    def fields(self, t: dict[str, Any]) -> dict[str, str]:
        return {
            "name": t["name"],
            "server": t["server"] + " " + " ".join(t.get("aliases") or []),
            "description": t["description"],
            "params": " ".join(t.get("params") or []),
            "full": f"{t['server']} {t['name']} {t['description']} {' '.join(t.get('params') or [])}",
        }

    def query_term_weights(self, tokens: list[str]) -> dict[str, float]:
        w = {}
        for tok in tokens:
            w[tok] = 0.25 if tok in VERBS else 1.0
        return w

    def namespace_boost(self, query: str, tool_id: str, score: float) -> float:
        t = self.by_id[tool_id]
        q = query.lower()
        for alias in t.get("aliases") or [t["server"]]:
            if alias.lower() in q:
                return score * 1.35
        return score

    def run_all(self, queries: list[dict[str, Any]], *, want_dense: bool = True) -> list[MethodResult]:
        results: list[MethodResult] = []
        full_docs = [(t["id"], tokenize(self.fields(t)["full"])) for t in self.tools]
        name_docs = [(t["id"], tokenize(t["name"])) for t in self.tools]
        desc_docs = [(t["id"], tokenize(t["description"])) for t in self.tools]
        field_docs = {
            "name": [(t["id"], tokenize(self.fields(t)["name"])) for t in self.tools],
            "server": [(t["id"], tokenize(self.fields(t)["server"])) for t in self.tools],
            "description": [(t["id"], tokenize(self.fields(t)["description"])) for t in self.tools],
            "params": [(t["id"], tokenize(self.fields(t)["params"])) for t in self.tools],
        }
        texts = [(t["id"], self.fields(t)["full"]) for t in self.tools]

        def eval_method(
            name: str,
            index_s: float,
            scorer: Callable[[dict[str, Any]], list[Ranked]],
            meta: MethodMeta,
        ) -> MethodResult:
            rankings: dict[str, list[str]] = {}
            qms: list[float] = []
            before = rss_mb()
            for q in queries:
                t0 = time.perf_counter()
                ranked = scorer(q)
                qms.append((time.perf_counter() - t0) * 1000.0)
                rankings[q["id"]] = top_ids(ranked, 10)
            after = rss_mb()
            rss = None
            if before is not None and after is not None:
                rss = max(0.0, after - before) if after >= before else after
            return MethodResult(name, rankings, qms, index_s, rss, meta)

        # 1. name exact / substring
        def name_exact(q: dict[str, Any]) -> list[Ranked]:
            needle = re.sub(r"[^a-z0-9_]+", "", q["query"].lower())
            out = []
            for t in self.tools:
                compact = re.sub(r"[^a-z0-9_]+", "", t["name"].lower())
                if compact == needle or t["name"].lower() == q["query"].lower():
                    out.append(Ranked(t["id"], 2.0))
                elif needle and needle in compact:
                    out.append(Ranked(t["id"], 1.0))
            out.sort(key=lambda r: -r.score)
            return out

        results.append(
            eval_method(
                "name_exact_substr",
                0.0,
                name_exact,
                MethodMeta("name_exact_substr", False, False, "exact/substring on tool name"),
            )
        )

        def boolean_and(q: dict[str, Any]) -> list[Ranked]:
            toks = tokenize(q["query"])
            if not toks:
                return []
            out = []
            for tid, tokens in full_docs:
                bag = set(tokens)
                if all(t in bag for t in toks):
                    out.append(Ranked(tid, float(len(toks))))
            return out

        results.append(
            eval_method("boolean_and", 0.0, boolean_and, MethodMeta("boolean_and", False, False, "all query tokens must match"))
        )

        def boolean_or(q: dict[str, Any]) -> list[Ranked]:
            toks = tokenize(q["query"])
            out = []
            for tid, tokens in full_docs:
                bag = set(tokens)
                hit = sum(1 for t in toks if t in bag)
                if hit:
                    out.append(Ranked(tid, float(hit)))
            out.sort(key=lambda r: -r.score)
            return out

        results.append(
            eval_method("boolean_or", 0.0, boolean_or, MethodMeta("boolean_or", False, False, "token overlap count"))
        )

        bm25 = BM25Index()
        t_bm25 = bm25.build(full_docs)

        def plain_bm25(q: dict[str, Any]) -> list[Ranked]:
            return bm25.score_query(tokenize(q["query"], split_idents=False))

        results.append(
            eval_method(
                "bm25_plain",
                t_bm25,
                plain_bm25,
                MethodMeta("bm25_plain", False, False, "Okapi BM25, split on non-alnum only"),
            )
        )

        def bm25_ident(q: dict[str, Any]) -> list[Ranked]:
            return bm25.score_query(tokenize(q["query"], split_idents=True))

        results.append(
            eval_method(
                "bm25_ident_split",
                t_bm25,
                bm25_ident,
                MethodMeta("bm25_ident_split", False, False, "BM25 + identifier splitting"),
            )
        )

        bm25_name = BM25Index()
        t_name = bm25_name.build(name_docs)
        results.append(
            eval_method(
                "bm25_name_only",
                t_name,
                lambda q: bm25_name.score_query(tokenize(q["query"])),
                MethodMeta("bm25_name_only", False, False, "BM25 over tool name field"),
            )
        )

        bm25_desc = BM25Index()
        t_desc = bm25_desc.build(desc_docs)
        results.append(
            eval_method(
                "bm25_desc_only",
                t_desc,
                lambda q: bm25_desc.score_query(tokenize(q["query"])),
                MethodMeta("bm25_desc_only", False, False, "BM25 over description field"),
            )
        )

        field_indexes = {}
        t_fields = 0.0
        for fname, docs in field_docs.items():
            ix = BM25Index()
            t_fields += ix.build(docs)
            field_indexes[fname] = ix
        field_w = {"name": 3.0, "server": 2.2, "description": 1.0, "params": 0.45}

        def weighted_bm25(q: dict[str, Any]) -> list[Ranked]:
            toks = tokenize(q["query"])
            tw = self.query_term_weights(toks)
            scores: dict[str, float] = defaultdict(float)
            for fname, ix in field_indexes.items():
                for r in ix.score_query(toks, tw):
                    scores[r.tool_id] += field_w[fname] * r.score
            ranked = [Ranked(tid, self.namespace_boost(q["query"], tid, s)) for tid, s in scores.items()]
            ranked.sort(key=lambda r: -r.score)
            return ranked

        results.append(
            eval_method(
                "bm25_weighted",
                t_fields,
                weighted_bm25,
                MethodMeta(
                    "bm25_weighted",
                    False,
                    False,
                    "Zed-like: field BM25 + ident split + verb downweight + name/namespace boosts",
                ),
            )
        )

        tfidf = TfidfIndex()
        t_tfidf = tfidf.build(full_docs)
        results.append(
            eval_method(
                "tfidf",
                t_tfidf,
                lambda q: tfidf.score_query(tokenize(q["query"])),
                MethodMeta("tfidf", False, False, "cosine TF-IDF"),
            )
        )

        def bm25_tfidf_hybrid(q: dict[str, Any]) -> list[Ranked]:
            toks = tokenize(q["query"])
            b = {r.tool_id: r.score for r in bm25.score_query(toks)}
            t = {r.tool_id: r.score for r in tfidf.score_query(toks)}
            ids = set(b) | set(t)
            def norm(m: dict[str, float]) -> dict[str, float]:
                mx = max(m.values()) if m else 1.0
                return {k: v / mx for k, v in m.items()} if mx else m
            bn, tn = norm(b), norm(t)
            ranked = [Ranked(i, 0.2 * bn.get(i, 0.0) + 0.8 * tn.get(i, 0.0)) for i in ids]
            ranked.sort(key=lambda r: -r.score)
            return ranked

        results.append(
            eval_method(
                "bm25_tfidf_hybrid",
                t_bm25 + t_tfidf,
                bm25_tfidf_hybrid,
                MethodMeta("bm25_tfidf_hybrid", False, False, "StackOne-style 20/80 BM25+TF-IDF"),
            )
        )

        tri = TrigramIndex()
        t_tri = tri.build(texts)
        results.append(
            eval_method(
                "char_trigram",
                t_tri,
                lambda q: tri.score_query(q["query"]),
                MethodMeta("char_trigram", False, False, "character trigram cosine — local analog of codedb trigrams"),
            )
        )

        hashed = HashedEmbedIndex()
        t_hash = hashed.build(texts)
        results.append(
            eval_method(
                "hashed_ngram_embed",
                t_hash,
                lambda q: hashed.score_query(q["query"]),
                MethodMeta("hashed_ngram_embed", False, False, "fallback sparse hashed n-gram embedding, not neural"),
            )
        )

        def hybrid_rrf(a: Callable[[dict[str, Any]], list[Ranked]], b: Callable[[dict[str, Any]], list[Ranked]]):
            def inner(q: dict[str, Any]) -> list[Ranked]:
                return rrf([top_ids(a(q), 50), top_ids(b(q), 50)])
            return inner

        results.append(
            eval_method(
                "hybrid_rrf_bm25_trigram",
                t_bm25 + t_tri,
                hybrid_rrf(lambda q: bm25.score_query(tokenize(q["query"])), lambda q: tri.score_query(q["query"])),
                MethodMeta("hybrid_rrf_bm25_trigram", False, False, "RRF of BM25 + char trigram"),
            )
        )
        results.append(
            eval_method(
                "hybrid_rrf_weighted_trigram",
                t_fields + t_tri,
                hybrid_rrf(weighted_bm25, lambda q: tri.score_query(q["query"])),
                MethodMeta("hybrid_rrf_weighted_trigram", False, False, "RRF of weighted BM25 + char trigram"),
            )
        )
        results.append(
            eval_method(
                "hybrid_rrf_weighted_hashed",
                t_fields + t_hash,
                hybrid_rrf(weighted_bm25, lambda q: hashed.score_query(q["query"])),
                MethodMeta("hybrid_rrf_weighted_hashed", False, False, "RRF of weighted BM25 + hashed embedding"),
            )
        )

        def decision_router(q: dict[str, Any]) -> list[Ranked]:
            toks = tokenize(q["query"])
            compact = re.sub(r"[^a-z0-9]+", "", q["query"].lower())
            looks_ident = " " not in q["query"].strip() and ( "_" in q["query"] or any(c.isupper() for c in q["query"]))
            if looks_ident or compact in {re.sub(r"[^a-z0-9]+", "", t["name"].lower()) for t in self.tools}:
                return name_exact(q) or weighted_bm25(q)
            return weighted_bm25(q)

        results.append(
            eval_method(
                "decision_heuristic",
                t_fields,
                decision_router,
                MethodMeta(
                    "decision_heuristic",
                    False,
                    False,
                    "rule-based router (identifier → name match, else weighted BM25); not a trained decision model",
                ),
            )
        )

        def rewrite_bm25(q: dict[str, Any]) -> list[Ranked]:
            text = q["query"]
            repl = {
                "ticket": "issue",
                "pr": "pull request",
                "mr": "merge request",
                "repo": "repository",
                "sms": "sms message",
                "on call": "oncall",
                "k8s": "kubernetes",
            }
            low = text.lower()
            for a, b in repl.items():
                low = re.sub(rf"\b{re.escape(a)}\b", b, low)
            return weighted_bm25({"query": low, "id": q["id"]})

        results.append(
            eval_method(
                "query_rewrite_weighted_bm25",
                t_fields,
                rewrite_bm25,
                MethodMeta("query_rewrite_weighted_bm25", False, False, "tiny synonym rewrite then weighted BM25 (not an LLM)"),
            )
        )

        def rerank_overlap(q: dict[str, Any]) -> list[Ranked]:
            base = weighted_bm25(q)[:20]
            qtok = set(tokenize(q["query"]))
            reranked = []
            for r in base:
                t = self.by_id[r.tool_id]
                bag = set(tokenize(self.fields(t)["full"]))
                overlap = len(qtok & bag) / (len(qtok) or 1)
                rare = sum(1 for tok in qtok if tok not in VERBS and tok in bag)
                reranked.append(Ranked(r.tool_id, r.score + 2.0 * overlap + 1.5 * rare))
            reranked.sort(key=lambda x: -x.score)
            return reranked

        results.append(
            eval_method(
                "lexical_rerank_weighted_top20",
                t_fields,
                rerank_overlap,
                MethodMeta("lexical_rerank_weighted_top20", False, False, "lexical overlap rerank of weighted BM25 top-20; not a cross-encoder"),
            )
        )

        dense = DenseEmbedIndex()
        if want_dense and dense.available():
            try:
                t_dense = dense.build(texts)

                def dense_score(q: dict[str, Any]) -> list[Ranked]:
                    return dense.score_query(q["query"])

                results.append(
                    eval_method(
                        "embed_bge_small",
                        t_dense,
                        dense_score,
                        MethodMeta("embed_bge_small", True, False, "fastembed BAAI/bge-small-en-v1.5"),
                    )
                )
                results.append(
                    eval_method(
                        "hybrid_rrf_bm25_embed",
                        t_bm25 + t_dense,
                        hybrid_rrf(lambda q: bm25.score_query(tokenize(q["query"])), dense_score),
                        MethodMeta("hybrid_rrf_bm25_embed", True, False, "RRF BM25 + bge-small"),
                    )
                )
                results.append(
                    eval_method(
                        "hybrid_rrf_weighted_embed",
                        t_fields + t_dense,
                        hybrid_rrf(weighted_bm25, dense_score),
                        MethodMeta("hybrid_rrf_weighted_embed", True, False, "RRF weighted BM25 + bge-small"),
                    )
                )
                results.append(
                    eval_method(
                        "hybrid_rrf_trigram_embed",
                        t_tri + t_dense,
                        hybrid_rrf(lambda q: tri.score_query(q["query"]), dense_score),
                        MethodMeta("hybrid_rrf_trigram_embed", True, False, "RRF char-trigram + bge-small"),
                    )
                )
            except Exception as exc:
                results.append(
                    MethodResult(
                        "embed_bge_small",
                        {},
                        [],
                        0.0,
                        None,
                        MethodMeta("embed_bge_small", True, False, "fastembed failed"),
                        skipped=str(exc),
                    )
                )
        else:
            results.append(
                MethodResult(
                    "embed_bge_small",
                    {},
                    [],
                    0.0,
                    None,
                    MethodMeta("embed_bge_small", True, False, "fastembed not installed"),
                    skipped="fastembed not installed",
                )
            )

        return results
