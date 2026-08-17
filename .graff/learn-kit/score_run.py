#!/usr/bin/env python3
"""Recompute behavioral scores from a codegraff.behavior.v1 event stream.

Stdlib-only, mirroring the schema-harness score_trajectories.py contract from
issue #246: every number this prints is derived from the event lines alone, so
the trace itself is the audit. No harness state, run record, or database is
consulted.

Usage:
    python3 scripts/score_run.py .graff/trajectories/<run_id>.jsonl
    python3 scripts/score_run.py --profile replay --baseline baseline_actions.csv \
        --game ft09-0d8bbf25 converted.jsonl

Profiles:
    codegraff  (default) strict Phase 1 producer audit: contiguous seq from 1,
               constant run_id/schema, single first run_started, terminal
               run_finished, dense turns, commitment/mispredict field checks,
               plus (#255) tool_started/tool_finished call_id pairing for the
               opt-in rich kinds (GRAFF_BEHAVIOR_TRACE=full).
    replay     relaxed envelope audit for streams converted from external
               schema-harness trajectories (their turn_started/turn_committed
               carry task fields codegraff does not emit, and vice versa).

With --baseline and --game, completed-level actions are read from action_taken
events (level_up=true closes a level) and scored with the reference RHAE math:
per-level min(115, 100*(baseline/actions)^2), level-index weights, and a
completion cap of 100. A full-history WIN run therefore reproduces the
published schema-harness score exactly.

Exit codes: 0 = audit passed, 1 = audit failed, 2 = usage error.
"""

from __future__ import annotations

import argparse
import csv
import json
import sys
from pathlib import Path

SCHEMA = "codegraff.behavior.v1"
KINDS = {
    "run_started",
    "turn_started",
    "text_delta",
    "tool_started",
    "tool_finished",
    "turn_committed",
    "action_taken",
    "model_mispredicted",
    "run_finished",
}
PER_LEVEL_SCORE_CAP = 115.0
GAME_SCORE_CAP = 100.0


class AuditError(Exception):
    pass


def read_events(path: Path):
    """Yield parsed events. A malformed final line is truncation, not
    corruption: the writer can die mid-line, and consumers must process only
    complete JSON lines."""
    lines = path.read_text(encoding="utf-8").splitlines()
    total = len(lines)
    for index, line in enumerate(lines, start=1):
        if not line.strip():
            if index == total:
                break
            raise AuditError(f"line {index}: blank line inside the stream")
        try:
            event = json.loads(line)
        except json.JSONDecodeError as exc:
            if index == total:
                yield index, None
                return
            raise AuditError(f"line {index}: invalid JSON: {exc}") from exc
        if not isinstance(event, dict):
            raise AuditError(f"line {index}: event must be a JSON object")
        yield index, event


def audit(path: Path, profile: str) -> dict:
    strict = profile == "codegraff"
    run_id = None
    prev_seq = 0
    seq_gaps = 0
    declared_local_dropped = None
    started = False
    finished = False
    truncated_tail = False
    terminal_status = None
    current_turn = 0
    turn_active = False
    turns = 0
    commitments = 0
    committed_turns = set()
    mispredicts = 0
    repair_gaps = []
    open_mispredict_seq = None
    counts: dict[str, int] = {}
    completed_levels: list[int] = []
    level_actions = 0
    total_actions = 0
    final_state = None
    # #255 opt-in rich capture (GRAFF_BEHAVIOR_TRACE=full): tool_started and
    # tool_finished pair by call_id; a finished call with no matching started
    # call is a pairing violation, not a warning.
    open_tool_calls: set[int] = set()
    tool_calls = 0
    tool_errors = 0
    text_deltas = 0

    for line_no, event in read_events(path):
        if event is None:
            truncated_tail = True
            break
        if finished:
            raise AuditError(f"line {line_no}: event after run_finished")

        for field in ("kind", "seq", "ts", "run_id", "schema"):
            if field not in event:
                raise AuditError(f"line {line_no}: missing envelope field {field!r}")
        kind = event["kind"]
        if kind not in KINDS:
            # Real schema-harness traces carry kinds beyond the nine (for
            # example turn_fallback). The reference scorer ignores kinds it
            # does not know; replayed conversions get the same tolerance,
            # while Phase 1 producers stay pinned to the documented set.
            if strict:
                raise AuditError(f"line {line_no}: unknown kind {kind!r}")
        if event["schema"] != SCHEMA:
            raise AuditError(f"line {line_no}: schema {event['schema']!r} != {SCHEMA!r}")
        seq = event["seq"]
        if not isinstance(seq, int) or seq <= prev_seq:
            raise AuditError(f"line {line_no}: seq {seq!r} is not strictly increasing (previous {prev_seq})")
        if seq != prev_seq + 1:
            if strict:
                # Phase 1 producers reserve seq before writing; an event
                # rejected pre-write leaves a gap that run_finished must
                # declare in local_dropped. The reconciliation happens after
                # the stream ends. Replay conversions renumber, so any gap
                # there is corruption.
                seq_gaps += seq - prev_seq - 1
            else:
                raise AuditError(f"line {line_no}: seq {seq!r} breaks contiguity (expected {prev_seq + 1})")
        prev_seq = seq
        if not isinstance(event["ts"], (int, float)):
            raise AuditError(f"line {line_no}: ts must be a number")
        if run_id is None:
            run_id = event["run_id"]
        elif event["run_id"] != run_id:
            raise AuditError(f"line {line_no}: run_id changed mid-stream")

        counts[kind] = counts.get(kind, 0) + 1

        if kind not in KINDS:
            continue
        if kind == "run_started":
            if started:
                raise AuditError(f"line {line_no}: duplicate run_started")
            if strict and seq != 1:
                raise AuditError(f"line {line_no}: run_started must be the first event")
            started = True
        elif kind == "turn_started":
            turn = event.get("turn")
            if not isinstance(turn, int) or turn < 1:
                raise AuditError(f"line {line_no}: turn_started needs a positive integer turn")
            if strict:
                if turn != current_turn + 1:
                    raise AuditError(f"line {line_no}: behavioral turns must be dense (expected {current_turn + 1}, got {turn})")
                parent = event.get("parent_turn")
                if parent != current_turn:
                    raise AuditError(f"line {line_no}: parent_turn {parent!r} != previous turn {current_turn}")
            current_turn = turn
            turn_active = True
            turns += 1
        elif kind == "text_delta":
            text_deltas += 1
            if strict:
                turn = event.get("turn")
                if not isinstance(turn, int) or turn < 1:
                    raise AuditError(f"line {line_no}: text_delta needs a positive integer turn")
                if not turn_active or turn != current_turn:
                    raise AuditError(f"line {line_no}: text_delta outside its active turn")
        elif kind == "tool_started":
            if strict:
                turn = event.get("turn")
                if not isinstance(turn, int) or turn < 1:
                    raise AuditError(f"line {line_no}: tool_started needs a positive integer turn")
                if not turn_active or turn != current_turn:
                    raise AuditError(f"line {line_no}: tool_started outside its active turn")
                call_id = event.get("call_id")
                if not isinstance(call_id, int):
                    raise AuditError(f"line {line_no}: tool_started needs an integer call_id")
                if call_id in open_tool_calls:
                    raise AuditError(f"line {line_no}: duplicate tool_started for call_id {call_id!r}")
                open_tool_calls.add(call_id)
        elif kind == "tool_finished":
            tool_calls += 1
            if event.get("is_error") is True:
                tool_errors += 1
            if strict:
                turn = event.get("turn")
                if not isinstance(turn, int) or turn < 1:
                    raise AuditError(f"line {line_no}: tool_finished needs a positive integer turn")
                if not turn_active or turn != current_turn:
                    raise AuditError(f"line {line_no}: tool_finished outside its active turn")
                call_id = event.get("call_id")
                if not isinstance(call_id, int):
                    raise AuditError(f"line {line_no}: tool_finished needs an integer call_id")
                if call_id not in open_tool_calls:
                    raise AuditError(f"line {line_no}: tool_finished for call_id {call_id!r} has no matching tool_started")
                open_tool_calls.discard(call_id)
        elif kind == "turn_committed":
            commitments += 1
            if open_mispredict_seq is not None:
                repair_gaps.append(seq - open_mispredict_seq)
                open_mispredict_seq = None
            if strict:
                if not turn_active or event.get("turn") != current_turn:
                    raise AuditError(f"line {line_no}: turn_committed outside its active turn")
                if not event.get("commitment_id"):
                    raise AuditError(f"line {line_no}: turn_committed needs a nonempty commitment_id")
            turn = event.get("turn")
            if isinstance(turn, int):
                committed_turns.add(turn)
        elif kind == "model_mispredicted":
            mispredicts += 1
            open_mispredict_seq = seq
            if strict:
                if not turn_active or event.get("turn") != current_turn:
                    raise AuditError(f"line {line_no}: model_mispredicted outside its active turn")
                if not event.get("commitment_id"):
                    raise AuditError(f"line {line_no}: model_mispredicted needs a nonempty commitment_id")
        elif kind == "action_taken":
            total_actions += 1
            level_actions += 1
            if strict:
                turn = event.get("turn")
                if not isinstance(turn, int) or turn < 1:
                    raise AuditError(f"line {line_no}: action_taken needs a positive integer turn")
                if not turn_active or turn != current_turn:
                    raise AuditError(f"line {line_no}: action_taken outside its active turn")
            if event.get("state") is not None:
                final_state = str(event["state"]).upper()
            if event.get("level_up") is True:
                completed_levels.append(level_actions)
                level_actions = 0
        elif kind == "run_finished":
            finished = True
            status = event.get("status")
            state = event.get("state")
            if strict and status not in ("closed", "error"):
                raise AuditError(f"line {line_no}: run_finished status must be closed or error, got {status!r}")
            terminal_status = status
            dropped = event.get("local_dropped")
            if dropped is not None:
                if not isinstance(dropped, int) or dropped < 0:
                    raise AuditError(f"line {line_no}: local_dropped must be a non-negative integer")
                declared_local_dropped = dropped
            if state is not None:
                final_state = str(state).upper()
        elif strict:
            raise AuditError(f"line {line_no}: kind {kind!r} is reserved and not emitted by Phase 1 producers")

    if prev_seq == 0:
        raise AuditError("no events found")
    if strict and not started:
        raise AuditError("stream has no run_started")
    if strict and seq_gaps:
        # Gaps are only legitimate when the terminal event accounts for every
        # one of them; anything else is truncation or tampering.
        if not finished:
            raise AuditError(f"{seq_gaps} seq gap(s) in an incomplete stream")
        if declared_local_dropped != seq_gaps:
            raise AuditError(
                f"{seq_gaps} seq gap(s) but run_finished declares local_dropped={declared_local_dropped}"
            )

    return {
        "run_id": run_id,
        "events": prev_seq,
        "counts": dict(sorted(counts.items())),
        "complete": finished,
        "truncated_tail": truncated_tail,
        "terminal_status": terminal_status,
        "seq_gaps": seq_gaps,
        "local_dropped": declared_local_dropped,
        "turns": turns,
        "commitments": commitments,
        "mispredicts": mispredicts,
        "mispredict_rate": round(mispredicts / commitments, 6) if commitments else None,
        "commitment_coverage": round(len(committed_turns) / turns, 6) if turns else None,
        "mean_repair_gap_events": round(sum(repair_gaps) / len(repair_gaps), 3) if repair_gaps else None,
        "actions": total_actions,
        "completed_level_actions": completed_levels,
        "incomplete_level_actions": level_actions if level_actions else None,
        "final_state": final_state,
        "tool_calls": tool_calls,
        "tool_errors": tool_errors,
        "text_deltas": text_deltas,
    }


def load_baseline(path: Path, game: str) -> tuple[str, list[int]]:
    with path.open(encoding="utf-8", newline="") as handle:
        for row in csv.DictReader(handle):
            if game in (row.get("game", ""), row.get("game_id", "")):
                actions = []
                for index in range(1, 11):
                    value = (row.get(f"level{index}") or "").strip()
                    if value:
                        actions.append(int(value))
                return row.get("game_id", game), actions
    raise AuditError(f"game {game!r} not found in {path}")


def rhae(baseline: list[int], completed: list[int]) -> tuple[list[float], float]:
    if len(completed) > len(baseline):
        raise AuditError(f"completed {len(completed)} levels but the baseline defines {len(baseline)}")
    per_level = []
    for index, human in enumerate(baseline):
        if index < len(completed):
            per_level.append(min((human / completed[index]) ** 2 * 100.0, PER_LEVEL_SCORE_CAP))
        else:
            per_level.append(0.0)
    weights = list(range(1, len(baseline) + 1))
    total_weight = sum(weights)
    raw = sum(score * weight for score, weight in zip(per_level, weights)) / total_weight
    completion_cap = sum(range(1, len(completed) + 1)) / total_weight * GAME_SCORE_CAP
    return per_level, min(raw, completion_cap)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("stream", type=Path, help="codegraff.behavior.v1 JSONL file")
    parser.add_argument("--profile", choices=("codegraff", "replay"), default="codegraff")
    parser.add_argument("--baseline", type=Path, help="schema-harness baseline_actions.csv for RHAE scoring")
    parser.add_argument("--game", help="game or game_id row to score against (with --baseline)")
    args = parser.parse_args()
    if bool(args.baseline) != bool(args.game):
        parser.error("--baseline and --game must be used together")

    try:
        report = audit(args.stream, args.profile)
        if args.baseline:
            game_id, baseline = load_baseline(args.baseline, args.game)
            per_level, score = rhae(baseline, report["completed_level_actions"])
            report["rhae"] = {
                "game_id": game_id,
                "baseline_actions": baseline,
                "per_level_scores": [round(s, 2) for s in per_level],
                "score": round(score, 2),
            }
    except AuditError as exc:
        json.dump({"ok": False, "error": str(exc)}, sys.stdout, indent=2)
        print()
        return 1
    report_out = {"ok": True, **report}
    json.dump(report_out, sys.stdout, indent=2)
    print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
