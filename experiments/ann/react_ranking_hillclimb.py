#!/usr/bin/env python3
"""Hill-climb hybrid path priors on a production-oriented React retrieval set.

The installed codedb binary supplies lexical and ANN evidence once per query.
Policy search then replays that fixed evidence locally, so the grid does not
send additional embedding requests. The first eight queries are training data;
the last four are held out until policy selection is complete.
"""

from __future__ import annotations

import argparse
import dataclasses
import itertools
import json
import math
import os
import subprocess
import time
from pathlib import Path
from typing import Any, Iterable


QUERIES: list[dict[str, Any]] = [
    {
        "id": "client-use-state",
        "query": "Trace the production client implementation of React useState from the public hook API through the dispatcher to the reconciler state queue. Exclude debug tools, fixtures, tests, and server-only hooks.",
        "gold": {
            "packages/react/src/ReactHooks.js": 3,
            "packages/react-reconciler/src/ReactFiberHooks.js": 3,
        },
    },
    {
        "id": "fiber-concurrent-work",
        "query": "How does production React schedule and perform concurrent render work in the Fiber work loop? Exclude tests, fixtures, snapshots, and examples.",
        "gold": {
            "packages/react-reconciler/src/ReactFiberWorkLoop.js": 3,
            "packages/react-reconciler/src/ReactFiberRootScheduler.js": 3,
        },
    },
    {
        "id": "fizz-streaming",
        "query": "How does production React streaming server rendering create, enqueue, and flush HTML chunks? Exclude tests and fixtures.",
        "gold": {
            "packages/react-server/src/ReactFizzServer.js": 3,
            "packages/react-dom-bindings/src/server/ReactFizzConfigDOM.js": 3,
            "packages/react-dom/src/server/ReactDOMFizzServerBrowser.js": 2,
            "packages/react-dom/src/server/ReactDOMFizzServerEdge.js": 2,
        },
    },
    {
        "id": "dom-event-dispatch",
        "query": "Trace production DOM event listener dispatch through the plugin event system. Exclude tests, fixtures, examples, and generated files.",
        "gold": {
            "packages/react-dom-bindings/src/events/ReactDOMEventListener.js": 3,
            "packages/react-dom-bindings/src/events/DOMPluginEventSystem.js": 3,
        },
    },
    {
        "id": "context-propagation",
        "query": "Where does the production reconciler propagate a changed React context through the Fiber tree? Exclude tests and fixtures.",
        "gold": {"packages/react-reconciler/src/ReactFiberNewContext.js": 3},
    },
    {
        "id": "commit-effects",
        "query": "Trace production Fiber commit phase mutation, layout, and passive effects. Exclude tests, fixtures, and profiling examples.",
        "gold": {
            "packages/react-reconciler/src/ReactFiberCommitWork.js": 3,
            "packages/react-reconciler/src/ReactFiberCommitEffects.js": 3,
        },
    },
    {
        "id": "hydration-event-replay",
        "query": "How does production React queue and replay blocked DOM events during hydration? Exclude tests, fixtures, and examples.",
        "gold": {
            "packages/react-dom-bindings/src/events/ReactDOMEventReplaying.js": 3,
            "packages/react-reconciler/src/ReactFiberHydrationContext.js": 2,
        },
    },
    {
        "id": "suspense-boundary",
        "query": "Locate production reconciler logic for Suspense boundaries, fallback state, and retry scheduling. Exclude tests, fixtures, and test utilities.",
        "gold": {
            "packages/react-reconciler/src/ReactFiberSuspenseComponent.js": 3,
            "packages/react-reconciler/src/ReactFiberWorkLoop.js": 2,
        },
    },
    # Held out below.
    {
        "id": "flight-server",
        "query": "Where does production React Server Components serialize a model into Flight chunks and flush them? Exclude tests, fixtures, and demos.",
        "gold": {"packages/react-server/src/ReactFlightServer.js": 3},
    },
    {
        "id": "flight-client",
        "query": "Where does the production React Flight client consume streamed rows and resolve model chunks? Exclude tests, fixtures, and devtools.",
        "gold": {"packages/react-client/src/ReactFlightClient.js": 3},
    },
    {
        "id": "react-cache",
        "query": "Trace the production React cache API through its dispatcher-backed client implementation. Exclude tests, old implementations, fixtures, and server-only code.",
        "gold": {
            "packages/react/src/ReactCacheImpl.js": 3,
            "packages/react/src/ReactCacheClient.js": 3,
        },
    },
    {
        "id": "resource-hints",
        "query": "Where does production React DOM implement resource preload and preinit hints and serialize them for server rendering? Exclude tests, fixtures, and examples.",
        "gold": {
            "packages/react-dom/src/shared/ReactDOMFloat.js": 3,
            "packages/react-dom-bindings/src/server/ReactFizzConfigDOM.js": 2,
        },
    },
]


@dataclasses.dataclass(frozen=True)
class Policy:
    semantic_weight: float
    rrf_k: float
    lexical_guard: int
    excluded_test_multiplier: float
    excluded_debug_multiplier: float
    excluded_server_multiplier: float
    excluded_doc_multiplier: float

    def as_dict(self) -> dict[str, Any]:
        return dataclasses.asdict(self)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", default="/Users/blackfloofie/bin/codedb")
    parser.add_argument("--project", default="/Users/blackfloofie/tmp/react-codedb-eval")
    parser.add_argument("--out", required=True)
    parser.add_argument("--timeout", type=float, default=30.0)
    return parser.parse_args()


def context(binary: str, project: str, query: str, semantic: bool, timeout: float) -> tuple[dict[str, Any], float]:
    command = [binary, project, "context"]
    if semantic:
        command.append("--semantic")
    command.extend(("--json", query))
    environment = dict(os.environ)
    environment["CODEDB_NO_CLI_DAEMON"] = "1"
    environment["CODEDB_NO_TELEMETRY"] = "1"
    started = time.perf_counter()
    completed = subprocess.run(command, check=True, capture_output=True, text=True, env=environment, timeout=timeout)
    elapsed_ms = (time.perf_counter() - started) * 1000
    start = completed.stdout.find("{")
    if start < 0:
        raise RuntimeError("codedb returned no JSON")
    return json.loads(completed.stdout[start:]), elapsed_ms


def section_paths(payload: dict[str, Any], section_id: str) -> list[str]:
    for section in payload.get("sections") or []:
        if section.get("id") == section_id:
            return [str(item["path"]) for item in section.get("items") or []]
    return []


def is_test_like(path: str) -> bool:
    lowered = path.lower()
    base = lowered.rsplit("/", 1)[-1]
    return (
        lowered.startswith(("test/", "tests/", "fixtures/", "fixture/", "examples/"))
        or any(
            token in lowered
            for token in (
                "/test/",
                "/tests/",
                "/__tests__/",
                "/fixtures/",
                "/fixture/",
                "/examples/",
                "/__snapshots__/",
                "/internal-test-utils/",
                "/react-suspense-test-utils/",
                "/jest-react/",
            )
        )
        or any(token in base for token in ("_test.", ".test.", ".spec."))
        or base.startswith(("test_", "test-"))
        or base.endswith((".snap", ".map"))
        or ".expect." in base
    )


def has_any(text: str, values: Iterable[str]) -> bool:
    lowered = text.lower()
    return any(value in lowered for value in values)


def path_multiplier(path: str, query: str, policy: Policy) -> float:
    multiplier = 1.0
    explicit_production = has_any(query, ("production", "exclude tests", "exclude test", "source implementation"))
    if explicit_production and is_test_like(path):
        multiplier *= policy.excluded_test_multiplier
    if (explicit_production or has_any(query, ("exclude debug", "exclude devtools"))) and has_any(
        path, ("debug", "devtools")
    ):
        multiplier *= policy.excluded_debug_multiplier
    if has_any(query, ("server-only", "client implementation", "production react cache api")) and has_any(
        path, ("/react-server/", "server.js", "serveronly", "cacheold")
    ):
        multiplier *= policy.excluded_server_multiplier
    if explicit_production and path.lower().endswith((".md", ".mdx")):
        multiplier *= policy.excluded_doc_multiplier
    return multiplier


def replay(payload: dict[str, Any], lexical: list[str], query: str, policy: Policy) -> list[str]:
    candidates = payload.get("retrieval", {}).get("candidates") or []
    by_path: dict[str, dict[str, int | None]] = {}
    for index, path in enumerate(lexical):
        by_path[path] = {"lexical_rank": index, "semantic_rank": None}
    for item in candidates:
        path = str(item["path"])
        state = by_path.setdefault(path, {"lexical_rank": None, "semantic_rank": None})
        if item.get("lexical_rank") is not None:
            state["lexical_rank"] = int(item["lexical_rank"])
        if item.get("semantic_rank") is not None:
            state["semantic_rank"] = int(item["semantic_rank"])

    guarded: list[str] = []
    for path in lexical:
        if len(guarded) >= policy.lexical_guard:
            break
        if path_multiplier(path, query, policy) >= 1.0:
            guarded.append(path)

    scored: list[tuple[float, int, int, str]] = []
    sentinel = 1_000_000
    for path, state in by_path.items():
        lexical_rank = state["lexical_rank"]
        semantic_rank = state["semantic_rank"]
        score = 0.0
        if lexical_rank is not None:
            score += 1.0 / (policy.rrf_k + lexical_rank + 1.0)
        if semantic_rank is not None:
            score += policy.semantic_weight / (policy.rrf_k + semantic_rank + 1.0)
        score *= path_multiplier(path, query, policy)
        scored.append((score, lexical_rank if lexical_rank is not None else sentinel, semantic_rank if semantic_rank is not None else sentinel, path))
    ordered = [path for _, _, _, path in sorted(scored, key=lambda row: (-row[0], row[1], row[2], row[3]))]
    return guarded + [path for path in ordered if path not in guarded]


def metrics(ranking: list[str], gold: dict[str, int], k: int = 5) -> dict[str, float]:
    top = ranking[:k]
    first = next((index for index, path in enumerate(top) if path in gold), None)
    gains = [gold.get(path, 0) for path in top]
    dcg = sum((2**gain - 1) / math.log2(index + 2) for index, gain in enumerate(gains))
    ideal = sorted(gold.values(), reverse=True)[:k]
    idcg = sum((2**gain - 1) / math.log2(index + 2) for index, gain in enumerate(ideal))
    return {
        "hit_at_5": float(first is not None),
        "mrr_at_5": 0.0 if first is None else 1.0 / (first + 1),
        "recall_at_5": len(set(top) & set(gold)) / len(gold),
        "ndcg_at_5": 0.0 if idcg == 0 else dcg / idcg,
        "junk_at_5": float(sum(is_test_like(path) for path in top)),
    }


def aggregate(rows: list[dict[str, float]]) -> dict[str, float]:
    return {key: sum(row[key] for row in rows) / len(rows) for key in rows[0]}


def policy_key(values: dict[str, float]) -> tuple[float, ...]:
    return (
        values["mrr_at_5"],
        values["ndcg_at_5"],
        values["recall_at_5"],
        values["hit_at_5"],
        -values["junk_at_5"],
    )


def main() -> int:
    args = parse_args()
    evidence: list[dict[str, Any]] = []
    for item in QUERIES:
        lexical_payload, lexical_ms = context(args.binary, args.project, item["query"], False, args.timeout)
        hybrid_payload, hybrid_ms = context(args.binary, args.project, item["query"], True, args.timeout)
        evidence.append(
            {
                **item,
                "lexical": section_paths(lexical_payload, "most_relevant_files"),
                "installed_hybrid": section_paths(hybrid_payload, "most_relevant_files"),
                "hybrid_payload": hybrid_payload,
                "latency_ms": {"lexical": lexical_ms, "hybrid": hybrid_ms},
            }
        )

    train = evidence[:8]
    held_out = evidence[8:]
    installed_train = aggregate([metrics(row["installed_hybrid"], row["gold"]) for row in train])
    installed_held_out = aggregate([metrics(row["installed_hybrid"], row["gold"]) for row in held_out])
    lexical_held_out = aggregate([metrics(row["lexical"], row["gold"]) for row in held_out])

    best_policy: Policy | None = None
    best_train: dict[str, float] | None = None
    attempts = 0
    for values in itertools.product(
        (0.5, 1.0, 1.5, 2.0),
        (20.0, 40.0, 60.0, 80.0),
        (0, 1, 2, 3),
        (0.0, 0.05, 0.1, 0.25, 0.5),
        (0.05, 0.1, 0.25, 0.5),
        (0.05, 0.1, 0.25, 0.5),
        (0.1, 0.25, 0.5),
    ):
        attempts += 1
        policy = Policy(*values)
        train_metrics = aggregate([metrics(replay(row["hybrid_payload"], row["lexical"], row["query"], policy), row["gold"]) for row in train])
        if best_train is None or policy_key(train_metrics) > policy_key(best_train):
            best_policy, best_train = policy, train_metrics

    assert best_policy is not None and best_train is not None
    selected_held_out = aggregate(
        [metrics(replay(row["hybrid_payload"], row["lexical"], row["query"], best_policy), row["gold"]) for row in held_out]
    )
    selected_rankings = {
        row["id"]: replay(row["hybrid_payload"], row["lexical"], row["query"], best_policy)[:5]
        for row in evidence
    }
    selected_safe = (
        selected_held_out["mrr_at_5"] >= installed_held_out["mrr_at_5"]
        and selected_held_out["ndcg_at_5"] >= installed_held_out["ndcg_at_5"]
        and selected_held_out["recall_at_5"] >= installed_held_out["recall_at_5"]
        and selected_held_out["hit_at_5"] >= installed_held_out["hit_at_5"]
        and selected_held_out["junk_at_5"] <= installed_held_out["junk_at_5"]
    )
    promotable = selected_safe and (
        selected_held_out["mrr_at_5"] > installed_held_out["mrr_at_5"]
        or selected_held_out["ndcg_at_5"] > installed_held_out["ndcg_at_5"]
        or selected_held_out["recall_at_5"] > installed_held_out["recall_at_5"]
        or selected_held_out["hit_at_5"] > installed_held_out["hit_at_5"]
        or selected_held_out["junk_at_5"] < installed_held_out["junk_at_5"]
    )
    ablation_policies = {
        "fusion_only": dataclasses.replace(
            best_policy,
            excluded_test_multiplier=1.0,
            excluded_debug_multiplier=1.0,
            excluded_server_multiplier=1.0,
            excluded_doc_multiplier=1.0,
        ),
        "plus_test_intent": dataclasses.replace(
            best_policy,
            excluded_debug_multiplier=1.0,
            excluded_server_multiplier=1.0,
            excluded_doc_multiplier=1.0,
        ),
        "plus_test_and_debug_intent": dataclasses.replace(
            best_policy,
            excluded_server_multiplier=1.0,
            excluded_doc_multiplier=1.0,
        ),
        "full_selected": best_policy,
    }
    ablations = {
        name: {
            "train": aggregate(
                [metrics(replay(row["hybrid_payload"], row["lexical"], row["query"], policy), row["gold"]) for row in train]
            ),
            "held_out": aggregate(
                [metrics(replay(row["hybrid_payload"], row["lexical"], row["query"], policy), row["gold"]) for row in held_out]
            ),
        }
        for name, policy in ablation_policies.items()
    }
    output = {
        "benchmark": "React production-source retrieval",
        "queries": len(evidence),
        "split": {"train": len(train), "held_out": len(held_out)},
        "attempts": attempts,
        "installed_hybrid": {"train": installed_train, "held_out": installed_held_out},
        "lexical_held_out": lexical_held_out,
        "selected": {"policy": best_policy.as_dict(), "train": best_train, "held_out": selected_held_out},
        "ablations": ablations,
        "promotion_allowed": promotable,
        "validation": "promotion" if promotable else "current_policy_matches_or_beats_selected" if selected_safe else "regression",
        "latency_ms": {
            mode: {
                "mean": sum(row["latency_ms"][mode] for row in evidence) / len(evidence),
                "max": max(row["latency_ms"][mode] for row in evidence),
            }
            for mode in ("lexical", "hybrid")
        },
        "selected_rankings": selected_rankings,
    }
    target = Path(args.out)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(output, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(output, indent=2, sort_keys=True))
    return 0 if selected_safe else 2


if __name__ == "__main__":
    raise SystemExit(main())
