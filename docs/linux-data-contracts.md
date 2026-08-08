# Linux Data Plane Contracts — Valkey + DuckDB

Draft per user decision 2026-08-08. Spec 14.1 TODOs: Valkey key layout / eviction + pub/sub, DuckDB analytical schema.

## Valkey (hiredis) — hot state, cache

All keys under `tessera:` prefix. TTLs are best-effort; Postgres is source of truth so cache may be rebuilt.

| Key | Type | TTL | Writer | Description |
|---|---|---|---|---|
| `tessera:session:{sid}` | Hash | 30m | DataLayer | Active chat session: `model`, `provider`, `updatedAt`, `msgCount`. Used for concurrent chat Run locks. |
| `tessera:chat:{sid}:recent` | List (LPUSH/LTRIM 100) | 1h | KnowledgeSync / ChatView | Recent message IDs for quick history without Postgres round-trip. |
| `tessera:run:{runId}` | String (JSON) | 1h | DataLayer | Run lock: `status` running/completed, `pid`. `SET NX` for mutual exclusion. |
| `tessera:model:{id}:meta` | Hash | 6h | Capacity/MoE | Model metadata LRU: `name`, `path`, `size`, `quant`. |
| `tessera:trace:{sid}` | String | 24h | TraceStore | Recent trace file offset for tailing. |
| `tessera:provider:{id}:budget` | String (int) | 5m | Provider | Token budget window counter, `INCR` + `EXPIRE`. |
| `tessera:pubsub:agent` | PubSub channel | — | AgentLoop | `PUBLISH` progress events `{runId, step, msg}`; UI subscribes via `SUBSCRIBE`. |

Eviction: `maxmemory-policy allkeys-lru`, `maxmemory 256mb` (Flatpak default; host may override via `TESSERA_VALKEY_URL`).

Read-through/write-through rule (DataLayer):
- Chat/session reads: `GET` → on miss, `SELECT` Postgres, then `SETEX`.
- Writes: `SET` + `PQexec` in same worker thread; if Valkey down, return `CacheDegraded` but keep Postgres write.

## DuckDB — analytical, columnar

On-disk at `XDG_DATA_HOME/tessera/tessera.duckdb`, opened in-process via `duckdb_open`. No writable canonical store — ETL from Postgres + JSONL traces.

### Tables

```sql
CREATE TABLE token_usage (
    ts TIMESTAMP,
    model TEXT,
    provider TEXT,
    prompt_tokens INTEGER,
    completion_tokens INTEGER,
    total_tokens INTEGER
);

CREATE TABLE run_stats (
    run_id TEXT PRIMARY KEY,
    model TEXT,
    status TEXT, -- completed, failed
    started_at TIMESTAMP,
    finished_at TIMESTAMP,
    duration_ms INTEGER
);

CREATE TABLE traces (
    sid TEXT,
    ts TIMESTAMP,
    kind TEXT, -- runtime, chat
    payload JSON
);

CREATE TABLE graph_analytics (
    entity_type TEXT,
    count INTEGER,
    updated_at TIMESTAMP
);
```

ETL: `DataLayer::duckdb_exec("INSERT INTO token_usage ...")` called from `AgentLoop` after each turn; `TraceStore::appendRuntime` also fans out to DuckDB via `duckdb_exec`. Queries for charts (`learning/Surface.cpp`) use `SELECT date_trunc('day', ts), sum(total_tokens) FROM token_usage GROUP BY 1`.

### Migration

DuckDB file versioned by `PRAGMA version`; on open, `CREATE TABLE IF NOT EXISTS`. Postgres remains source of truth — DuckDB may be rebuilt by replaying `token_usage` from Postgres `graph_receipts` where `receipt_type='token'`.

## Embedded Postgres

Default data dir `XDG_DATA_HOME/tessera/pgdata` (e.g. `~/.local/share/tessera/pgdata`). Flatpak ships `postgresql` module; on first run `initdb -D $XDG_DATA_HOME/tessera/pgdata` + `pg_ctl -D ... start`. External override via `TESSERA_POSTGRES_URL` (or `DATABASE_URL`) takes precedence — see `DataLayer::connect()` embedded-first probe.

## Open questions still deferred

- Exact `pg_hba.conf` for embedded (trust vs scram-sha-256, default `tessera:tessera` for dev).
- Valkey ACL for Flatpak vs host.
- NPU reuses same contracts, no new keys.
