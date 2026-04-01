#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
import os
import subprocess
import sys
from pathlib import Path


DEFAULT_INPUT = Path(os.path.expanduser("~/.codedb/telemetry.ndjson"))
DEFAULT_SCHEMA = Path(__file__).resolve().parents[1] / "docs" / "telemetry" / "postgres-schema.sql"
COPY_COLUMNS = [
    "timestamp_ms",
    "event_type",
    "tool",
    "latency_ns",
    "error",
    "response_bytes",
    "file_count",
    "total_lines",
    "languages",
    "index_size_bytes",
    "startup_time_ms",
    "version",
    "platform",
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Sync codedb telemetry NDJSON into Postgres.",
    )
    parser.add_argument(
        "input",
        nargs="?",
        default=str(DEFAULT_INPUT),
        help="telemetry NDJSON file to ingest",
    )
    parser.add_argument(
        "--dsn",
        default=os.environ.get("DATABASE_URL"),
        help="Postgres DSN (defaults to DATABASE_URL)",
    )
    parser.add_argument(
        "--schema",
        default=str(DEFAULT_SCHEMA),
        help="schema SQL file to apply before loading",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="print normalized CSV rows instead of loading Postgres",
    )
    return parser.parse_args()


def coerce_timestamp_ms(record: dict[str, object]) -> int:
    value = record.get("timestamp_ms")
    if value is None:
        value = record.get("ts")
        if value is None:
            raise ValueError("missing timestamp")
        value = int(value)
        if value < 1_000_000_000_000:
            value *= 1000
    return int(value)


def coerce_event_type(record: dict[str, object]) -> str:
    value = record.get("event_type") or record.get("ev") or record.get("kind")
    if value is None:
        raise ValueError("missing event type")
    value = str(value)
    if value == "tool":
        return "tool_call"
    if value == "start":
        return "session_start"
    return value


def coerce_bool(record: dict[str, object], *keys: str) -> bool | None:
    for key in keys:
        if key in record:
            value = record[key]
            if value is None:
                return None
            return bool(value)
    return None


def coerce_int(record: dict[str, object], *keys: str) -> int | None:
    for key in keys:
        if key in record:
            value = record[key]
            if value is None:
                return None
            return int(value)
    return None


def format_pg_array(items: list[str]) -> str:
    if not items:
        return "{}"

    escaped = []
    for item in items:
        safe = item.replace("\\", "\\\\").replace('"', '\\"')
        if any(ch in item for ch in ',{}"\\ '):
            escaped.append(f'"{safe}"')
        else:
            escaped.append(safe)
    return "{" + ",".join(escaped) + "}"


def coerce_languages(record: dict[str, object]) -> str | None:
    value = record.get("languages")
    if value is None:
        return None
    if isinstance(value, list):
        items = [str(item) for item in value if str(item)]
    else:
        items = [part.strip() for part in str(value).split(",") if part.strip()]
    return format_pg_array(items)


def normalize(record: dict[str, object]) -> list[object | None]:
    return [
        coerce_timestamp_ms(record),
        coerce_event_type(record),
        record.get("tool"),
        coerce_int(record, "latency_ns", "ns"),
        coerce_bool(record, "error", "err"),
        coerce_int(record, "response_bytes", "bytes"),
        coerce_int(record, "file_count", "files"),
        coerce_int(record, "total_lines", "lines"),
        coerce_languages(record),
        coerce_int(record, "index_size_bytes"),
        coerce_int(record, "startup_time_ms"),
        record.get("version"),
        record.get("platform"),
    ]


def apply_schema(dsn: str, schema: str) -> None:
    subprocess.run(
        ["psql", dsn, "-v", "ON_ERROR_STOP=1", "-f", schema],
        check=True,
    )


def load_rows(dsn: str, rows: list[list[object | None]]) -> None:
    copy_sql = (
        "COPY codedb_events ("
        + ", ".join(COPY_COLUMNS)
        + ") FROM STDIN WITH (FORMAT csv, NULL '')"
    )
    proc = subprocess.Popen(
        ["psql", dsn, "-v", "ON_ERROR_STOP=1", "-c", copy_sql],
        stdin=subprocess.PIPE,
        text=True,
    )
    assert proc.stdin is not None
    writer = csv.writer(proc.stdin)
    for row in rows:
        writer.writerow(["" if value is None else value for value in row])
    proc.stdin.close()
    code = proc.wait()
    if code != 0:
        raise subprocess.CalledProcessError(code, proc.args)


def main() -> int:
    args = parse_args()
    input_path = Path(args.input)
    if not input_path.exists():
        print(f"error: input file not found: {input_path}", file=sys.stderr)
        return 1

    rows: list[list[object | None]] = []
    with input_path.open("r", encoding="utf-8") as fh:
        for line_no, line in enumerate(fh, 1):
            line = line.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError as err:
                print(f"error: line {line_no}: invalid JSON: {err.msg}", file=sys.stderr)
                return 1
            if not isinstance(record, dict):
                print(f"error: line {line_no}: expected JSON object", file=sys.stderr)
                return 1
            rows.append(normalize(record))

    if args.dry_run:
        writer = csv.writer(sys.stdout)
        writer.writerow(COPY_COLUMNS)
        for row in rows:
            writer.writerow(["" if value is None else value for value in row])
        return 0

    if not args.dsn:
        print("error: --dsn or DATABASE_URL is required", file=sys.stderr)
        return 1

    apply_schema(args.dsn, args.schema)
    load_rows(args.dsn, rows)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
