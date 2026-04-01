# Telemetry Data Flow

codedb writes local telemetry to `~/.codedb/telemetry.ndjson` unless `CODEDB_NO_TELEMETRY=1` is set. The file is append-only and stays on disk until an operator syncs it.

The current on-disk format is compact:

- `ts` or `timestamp_ms`
- `ev` or `event_type`
- `tool`, `ns` / `latency_ns`, `err` / `error`, `bytes` / `response_bytes`
- `files` / `file_count`, `lines` / `total_lines`
- optional `languages`, `index_size_bytes`, `startup_time_ms`, `version`, `platform`

`scripts/sync-telemetry.py` normalizes those fields and loads them into Postgres with `COPY`.

## Postgres schema

Use [`docs/telemetry/postgres-schema.sql`](./telemetry/postgres-schema.sql) to create the destination table and indexes.

## Sync

```bash
python3 scripts/sync-telemetry.py --dsn "$DATABASE_URL"
```

For a preview without touching Postgres:

```bash
python3 scripts/sync-telemetry.py --dry-run
```

The sync path stores aggregate usage and performance data only. It does not capture file contents, file paths, or search queries.
