CREATE TABLE IF NOT EXISTS codedb_events (
    id BIGSERIAL PRIMARY KEY,
    timestamp_ms BIGINT NOT NULL,
    event_type TEXT NOT NULL,
    tool TEXT,
    latency_ns BIGINT,
    error BOOLEAN,
    response_bytes INTEGER,
    file_count INTEGER,
    total_lines BIGINT,
    languages TEXT[],
    index_size_bytes BIGINT,
    startup_time_ms BIGINT,
    version TEXT,
    platform TEXT,
    ingested_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_codedb_events_timestamp_ms
    ON codedb_events(timestamp_ms);

CREATE INDEX IF NOT EXISTS idx_codedb_events_tool
    ON codedb_events(tool)
    WHERE tool IS NOT NULL;
