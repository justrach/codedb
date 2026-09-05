"""Shared metrics and corpus validation for real default-hybrid Jina evals."""
import hashlib
import json
import math
from pathlib import Path
import subprocess
import time


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def load_dataset(path, source):
    dataset = json.loads(Path(path).read_text())
    if dataset.get("schema_version") != 1:
        raise ValueError("Unsupported dataset schema")
    head = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()
    if head != dataset["source_revision"]:
        raise ValueError("Source revision differs from the dataset; revalidate labels before running")
    for relative, expected in dataset["corpus_files"].items():
        path = Path(relative)
        if path.is_absolute() or ".." in path.parts or source.resolve() not in (source / path).resolve().parents:
            raise ValueError("Dataset path escapes the source repository")
        if sha256(source / path) != expected:
            raise ValueError(f"Corpus content changed: {relative}")
    ids = set()
    for query in dataset["queries"]:
        if query["id"] in ids:
            raise ValueError("Duplicate query id")
        ids.add(query["id"])
        if query["kind"] not in ("relevant", "unrelated"):
            raise ValueError("Query kind must be relevant or unrelated")
        if query.get("split") not in ("train", "held_out", "diagnostic", "negative_control"):
            raise ValueError("Every query needs an explicit evaluation split")
        if bool(query["gold"]) != (query["kind"] == "relevant"):
            raise ValueError("Only relevant queries may have nonempty gold labels")
        if not set(query["gold"]).issubset(dataset["corpus_files"]):
            raise ValueError("Gold files must exist in the pinned corpus")
        if any(not isinstance(grade, int) or not 1 <= grade <= 3 for grade in query["gold"].values()):
            raise ValueError("Gold grades must be integers from 1 to 3")
    return dataset


def relevance(ranking, gold, k=5):
    if not gold:
        raise ValueError("Unrelated queries must not enter relevance aggregates")
    top = list(dict.fromkeys(ranking))[:k]
    first = next((i for i, path in enumerate(top) if path in gold), None)
    dcg = sum((2 ** gold.get(path, 0) - 1) / math.log2(i + 2) for i, path in enumerate(top))
    ideal = sum((2 ** grade - 1) / math.log2(i + 2) for i, grade in enumerate(sorted(gold.values(), reverse=True)[:k]))
    return {"hit_at_5": int(first is not None), "mrr_at_5": 0 if first is None else 1 / (first + 1),
            "recall_at_5": len(set(top) & set(gold)) / len(gold), "ndcg_at_5": dcg / ideal}

def context(binary, root, environment, query):
    command = [str(binary), str(root), "context", "--json"]
    command.append(query)
    started = time.perf_counter()
    done = subprocess.run(command, env=environment, capture_output=True, text=True, timeout=45)
    duration = (time.perf_counter() - started) * 1000
    if done.returncode:
        raise RuntimeError(f"context exited {done.returncode}")
    payload = json.loads(done.stdout[done.stdout.index("{"):])
    paths = next((list(dict.fromkeys(item["path"] for item in section.get("items", [])))
                  for section in payload.get("sections", []) if section["id"] == "most_relevant_files"), [])
    return {"paths": paths, "wall_ms": duration, "retrieval": payload["retrieval"]}
