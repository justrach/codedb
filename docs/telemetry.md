# Telemetry Data Flow

codedb writes telemetry to `~/.codedb/telemetry.ndjson` only when `CODEDB_TELEMETRY=1` is set. `CODEDB_NO_TELEMETRY=1` and `--no-telemetry` force it off. The file is append-only. On MCP session close, the data is synced to the codedb analytics endpoint (`codedb.codegraff.com/telemetry/ingest`) and the local file is cleared. **No source code, file contents, file paths, or search queries are collected** — only aggregate tool call counts, latency, and startup stats.

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
