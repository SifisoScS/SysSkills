---
name: Database Internals & Query Optimisation
slug: database-internals-query-optimisation
category: 05-data-and-persistence
proficiency: advanced
description: >
  Understand and exploit PostgreSQL internals for production performance: B-tree
  and LSM-tree storage engines, MVCC isolation levels, WAL and crash recovery,
  EXPLAIN/EXPLAIN ANALYZE plan reading, index types (B-tree, GIN, BRIN, partial,
  covering, expression), partition pruning, autovacuum tuning, connection pooling
  with PgBouncer, and a systematic slow-query triage workflow.
tags:
  - postgresql
  - database-internals
  - query-optimisation
  - mvcc
  - b-tree
  - lsm-tree
  - indexes
  - explain-analyze
  - vacuum
  - pgbouncer
  - partitioning
  - wal
status: complete
---

## Principles

### Storage Engine Taxonomy

**B-tree (PostgreSQL heap + B-tree indexes, MySQL InnoDB)**
```
                    [Root page]
                   /     |     \
           [Internal]  [...]  [Internal]
           /      \              /    \
      [Leaf]    [Leaf]      [Leaf]  [Leaf]
    (row ctids) (row ctids)
```
- Pages (8 KB default in PostgreSQL) are the unit of I/O
- Data rows stored in **heap** pages in arbitrary order; B-tree index stores key → ctid (page, offset) pointers
- Random reads are O(log N); sequential scans O(N)
- Updates: old row version stays in heap (MVCC); new version written; index entries point to new ctid
- Bloat accumulates from dead row versions → requires VACUUM

**LSM-tree (RocksDB, Cassandra, LevelDB, CockroachDB storage layer)**
```
Write → MemTable (in-memory sorted) → SSTable L0 (immutable sorted file on disk)
                                     → compaction → L1 → L2 → …
```
- All writes are sequential (append-only) → very high write throughput
- Reads must check MemTable + bloom filters + multiple SSTable levels → higher read amplification
- Compaction runs in background → occasional write spikes
- Ideal for: write-heavy workloads, time-series, append-only logs

**Choose B-tree (PostgreSQL/MySQL) when:** complex queries, joins, ACID transactions, mixed read/write.
**Choose LSM (Cassandra/RocksDB) when:** high write throughput, wide rows, time-series, linear horizontal scale.

### MVCC — Multi-Version Concurrency Control
PostgreSQL never overwrites a row in place. Every UPDATE creates a new row version (tuple) with updated `xmin`/`xmax` transaction IDs. Readers see a consistent snapshot without taking locks.

```
Transaction T1 starts (xid=100)
  → sees all tuples with xmin ≤ 100 AND (xmax = 0 OR xmax > 100)

T2 updates row R (xid=101):
  → old tuple: xmin=50, xmax=101  (invisible to new readers after T2 commits)
  → new tuple: xmin=101, xmax=0   (visible to readers that started after T2 commits)

T1 still running: still sees old tuple (its snapshot predates T2's commit)
```

**Isolation levels in PostgreSQL:**
| Level | Dirty Read | Non-Repeatable Read | Phantom Read | Implementation |
|---|---|---|---|---|
| Read Uncommitted | ✅ (actually prevented) | ✅ | ✅ | Same as Read Committed in PG |
| Read Committed | ✗ | ✅ | ✅ | New snapshot per statement |
| Repeatable Read | ✗ | ✗ | ✗ (in PG) | Snapshot at TX start |
| Serializable | ✗ | ✗ | ✗ | SSI (predicate locking) |

### WAL — Write-Ahead Log
Every change is written to the WAL (sequential, append-only) before being applied to data pages. On crash recovery, PostgreSQL replays WAL from the last checkpoint.

```
Write path:    WAL buffer → fsync → WAL segment file
                                  → shared buffers (dirty pages)
                                  → background writer → data files
Recovery:      replay WAL from last checkpoint → consistent state
Replication:   WAL stream → standby applies same WAL (physical replication)
               Logical decoding → row-level changes → logical replication / CDC
```

**Key WAL parameters:**
- `wal_level`: `replica` (streaming) or `logical` (CDC / Debezium)
- `synchronous_commit`: `on` (safe, slower) | `off` (async, faster, risk of last few ms loss)
- `checkpoint_completion_target`: spread checkpoint I/O (default 0.9)

### Query Planning — How PostgreSQL Chooses a Plan
1. Parser → parse tree
2. Analyser → semantic analysis, type resolution
3. Rewriter → view expansion, rule application
4. Planner → generates candidate plans, estimates cost using statistics (`pg_statistic`)
5. Executor → executes chosen plan

**Cost model:** `total_cost = cpu_cost × cpu_operator_cost + io_cost × seq_page_cost/random_page_cost`
- `seq_page_cost = 1.0` (baseline)
- `random_page_cost = 4.0` default → tells planner random I/O is 4× more expensive than sequential
- On SSDs: set `random_page_cost = 1.1` — changes index vs sequential scan decisions significantly

---

## Implementation Patterns

### 1. EXPLAIN ANALYZE — Reading Plans
The plan is a tree; each node shows: operation type, estimated vs actual rows, cost, time. Read bottom-up (innermost node executes first).

Key nodes:
- `Seq Scan` — full table scan; good for small tables or high selectivity
- `Index Scan` — follows index to heap; O(log N + K); K random I/Os for K rows
- `Index Only Scan` — all needed columns in index; no heap access; fastest
- `Bitmap Heap Scan` + `Bitmap Index Scan` — batches random I/Os; good for medium selectivity
- `Nested Loop` — outer × inner; good when inner is small or indexed
- `Hash Join` — build hash table on smaller relation; good for large equi-joins
- `Merge Join` — both inputs sorted; good when both are pre-sorted

### 2. Index Strategy
Choose the right index type before adding; wrong type wastes space and maintenance overhead.

### 3. Table Partitioning
Declarative partitioning (range, list, hash) physically splits a table. Queries with partition-key predicates touch only matching partitions (partition pruning). Dramatically reduces scan cost for time-series and tenant-partitioned data.

### 4. Autovacuum Tuning
Autovacuum reclaims dead tuples, updates statistics, and prevents transaction ID wraparound. Default settings are conservative for small databases but too slow for high-churn tables.

### 5. Connection Pooling with PgBouncer
PostgreSQL allocates ~5 MB per connection. A 100-connection pool on a 4-core server is usually optimal; beyond that, context switching hurts throughput. PgBouncer in `transaction` mode multiplexes thousands of application connections onto a small server-side pool.

### 6. Slow-Query Triage Workflow
Systematic approach: identify → isolate → explain → index/rewrite → verify.

---

## Anti-Patterns

| Anti-Pattern | Why It Fails | Correction |
|---|---|---|
| **`SELECT *` in application code** | Fetches unnecessary columns; breaks covering indexes; fragile to schema changes | Explicit column list always |
| **Index on low-cardinality column alone** | B-tree on boolean/status (3 values) used rarely by planner | Partial index (`WHERE status = 'pending'`) or composite index |
| **`LIKE '%foo%'` without full-text index** | Leading wildcard disables B-tree index → seq scan | `pg_trgm` GIN index for substring search |
| **N+1 query pattern** | 1 query for list + N queries for related rows → O(N) round trips | JOIN or batch fetch; DataLoader in GraphQL layer |
| **`random_page_cost = 4.0` on SSD** | Planner avoids indexes when sequential scan looks cheaper | Set `random_page_cost = 1.1` for SSD storage |
| **Missing VACUUM on high-update tables** | Table bloat; full-page writes; planner statistics stale | Tune `autovacuum_vacuum_scale_factor` down for hot tables |
| **Application opens new connection per request** | PostgreSQL process spawn overhead; connection limit exhausted | PgBouncer in transaction mode in front of PostgreSQL |
| **`OFFSET N` for pagination** | PostgreSQL must scan and discard N rows; O(N) cost at each page | Keyset/cursor pagination: `WHERE id > $last_id ORDER BY id LIMIT 20` |
| **`NOT IN (subquery)` with NULLs** | If subquery returns any NULL, `NOT IN` returns no rows | Use `NOT EXISTS` or `LEFT JOIN … WHERE … IS NULL` |
| **Implicit type cast in WHERE clause** | `WHERE user_id = '123'` on integer column → seq scan | Match types exactly; cast explicitly if needed |
| **Single-column index for multi-column WHERE** | Planner can't use single-column index efficiently for AND predicates | Composite index ordered by most-selective column first |

---

## Code Templates

### Template 1 — EXPLAIN ANALYZE Workflow (SQL + Interpretation)

```sql
-- Step 1: enable timing and buffers for full I/O visibility
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT
    p.id,
    p.amount,
    p.status,
    u.email
FROM payments p
JOIN users u ON u.id = p.user_id
WHERE p.status = 'pending'
  AND p.created_at >= NOW() - INTERVAL '7 days'
ORDER BY p.created_at DESC
LIMIT 50;

/*
Example output to look for:

Limit  (cost=234.56..234.69 rows=50 width=48) (actual time=12.3..12.4 rows=50 loops=1)
  ->  Sort  (cost=234.56..237.12 rows=1024 width=48) (actual time=12.3..12.3 rows=50 loops=1)
        Sort Key: p.created_at DESC
        Sort Method: top-N heapsort  Memory: 29kB          ← good: no disk sort
        ->  Hash Join  (cost=45.12..210.34 rows=1024 width=48) (actual time=2.1..11.8 rows=1024 loops=1)
              Hash Cond: (p.user_id = u.id)
              Buffers: shared hit=234 read=12              ← 'read=12' means disk I/O; 'hit' is cache
              ->  Bitmap Heap Scan on payments p  (cost=8.90..165.20 rows=1024 ...)
                    Recheck Cond: ((status = 'pending') AND (created_at >= ...))
                    Heap Blocks: exact=98
                    ->  BitmapAnd  (cost=8.90..8.90 rows=1024 ...)
                          ->  Bitmap Index Scan on idx_payments_status  ...
                          ->  Bitmap Index Scan on idx_payments_created_at  ...
              ->  Hash  (cost=22.00..22.00 rows=1289 ...)
                    ->  Seq Scan on users u  (cost=0.00..22.00 rows=1289 ...)

WARNING SIGNALS:
  - "Rows Removed by Filter: 45000" → index not selective enough
  - "actual rows=1 / estimated rows=50000" → stale statistics (run ANALYZE)
  - "Sort Method: external merge  Disk: 2048kB" → sort spilling to disk (increase work_mem)
  - "Seq Scan on large_table" → missing index
  - "loops=1000" on inner nested-loop node → N+1 pattern
*/

-- Step 2: identify stale statistics
SELECT
    schemaname,
    tablename,
    n_live_tup,
    n_dead_tup,
    last_analyze,
    last_autoanalyze
FROM pg_stat_user_tables
WHERE tablename = 'payments';

-- Step 3: force statistics refresh if stale
ANALYZE payments;

-- Step 4: check index usage
SELECT
    indexrelname,
    idx_scan,
    idx_tup_read,
    idx_tup_fetch
FROM pg_stat_user_indexes
WHERE relname = 'payments'
ORDER BY idx_scan DESC;

-- Unused indexes waste write overhead and disk space — drop them
SELECT indexrelname FROM pg_stat_user_indexes
WHERE idx_scan = 0 AND schemaname = 'public';
```

---

### Template 2 — Index Design (All Types)

```sql
-- ── B-tree indexes ────────────────────────────────────────────────────────────

-- Composite: most selective column first; covers ORDER BY to avoid sort node
CREATE INDEX idx_payments_status_created
    ON payments (status, created_at DESC)
    WHERE status IN ('pending', 'processing');   -- partial: excludes terminal states

-- Covering (INCLUDE): heap fetch eliminated for these queries
CREATE INDEX idx_payments_user_covering
    ON payments (user_id, created_at DESC)
    INCLUDE (amount, status);                    -- index-only scan for common query shape

-- Expression index: enables index on computed values
CREATE INDEX idx_users_email_lower
    ON users (LOWER(email));
-- Query must match exactly: WHERE LOWER(email) = LOWER($1)

-- ── GIN indexes ───────────────────────────────────────────────────────────────

-- Full-text search
ALTER TABLE products ADD COLUMN search_vector tsvector
    GENERATED ALWAYS AS (
        to_tsvector('english', coalesce(name,'') || ' ' || coalesce(description,''))
    ) STORED;
CREATE INDEX idx_products_fts ON products USING GIN (search_vector);
-- Query: WHERE search_vector @@ to_tsquery('english', 'payment & gateway')

-- JSONB containment
CREATE INDEX idx_events_metadata ON events USING GIN (metadata jsonb_path_ops);
-- Query: WHERE metadata @> '{"source": "mobile"}'

-- Array containment
CREATE INDEX idx_posts_tags ON posts USING GIN (tags);
-- Query: WHERE tags @> ARRAY['fintech', 'api']

-- Trigram (pg_trgm) for LIKE/ILIKE substring search
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE INDEX idx_users_name_trgm ON users USING GIN (name gin_trgm_ops);
-- Query: WHERE name ILIKE '%smith%'   ← now uses index

-- ── BRIN indexes ──────────────────────────────────────────────────────────────
-- Best for: naturally ordered append-only columns (timestamps, serial IDs)
-- Very small (one range per block group); fast maintenance; coarse granularity

CREATE INDEX idx_events_created_brin
    ON events USING BRIN (created_at)
    WITH (pages_per_range = 128);
-- Ideal for time-series tables partitioned by month/day

-- ── Hash indexes ──────────────────────────────────────────────────────────────
-- Only equality (=); smaller than B-tree for equality-only lookups
CREATE INDEX idx_sessions_token_hash ON sessions USING HASH (token);
```

---

### Template 3 — Declarative Table Partitioning (Range + Pruning)

```sql
-- Range-partitioned payments table by month
CREATE TABLE payments (
    id          UUID        NOT NULL DEFAULT gen_random_uuid(),
    user_id     UUID        NOT NULL,
    amount      NUMERIC(12,2) NOT NULL,
    status      TEXT        NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
) PARTITION BY RANGE (created_at);

-- Create monthly partitions (automate this in production with pg_partman)
CREATE TABLE payments_2025_01 PARTITION OF payments
    FOR VALUES FROM ('2025-01-01') TO ('2025-02-01');
CREATE TABLE payments_2025_02 PARTITION OF payments
    FOR VALUES FROM ('2025-02-01') TO ('2025-03-01');
-- ... continue for each month

-- Each partition gets its own indexes
CREATE INDEX ON payments_2025_01 (user_id, created_at DESC);
CREATE INDEX ON payments_2025_02 (user_id, created_at DESC);

-- Partition pruning in action: planner touches ONLY 2025-01 partition
EXPLAIN SELECT * FROM payments
WHERE created_at BETWEEN '2025-01-01' AND '2025-01-31'
  AND user_id = $1;
-- Expected: Append → Index Scan on payments_2025_01 (not other partitions)

-- Partition maintenance: detach old partitions for archival (no lock on main table)
ALTER TABLE payments DETACH PARTITION payments_2024_01 CONCURRENTLY;

-- List partitioning for tenant isolation
CREATE TABLE events (
    id        UUID NOT NULL,
    tenant_id TEXT NOT NULL,
    payload   JSONB NOT NULL,
    ts        TIMESTAMPTZ NOT NULL
) PARTITION BY LIST (tenant_id);

CREATE TABLE events_tenant_acme   PARTITION OF events FOR VALUES IN ('acme');
CREATE TABLE events_tenant_globex PARTITION OF events FOR VALUES IN ('globex');
CREATE TABLE events_default       PARTITION OF events DEFAULT; -- catch-all
```

---

### Template 4 — Autovacuum Tuning for High-Churn Tables

```sql
-- View current autovacuum activity
SELECT
    pid,
    datname,
    relname,
    phase,
    heap_blks_scanned,
    heap_blks_vacuumed,
    now() - xact_start AS duration
FROM pg_stat_progress_vacuum
JOIN pg_database ON datid = pg_database.oid;

-- Identify tables needing vacuum tuning
SELECT
    relname,
    n_live_tup,
    n_dead_tup,
    ROUND(100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0), 1) AS dead_pct,
    last_vacuum,
    last_autovacuum,
    autovacuum_count
FROM pg_stat_user_tables
WHERE n_dead_tup > 10000
ORDER BY n_dead_tup DESC;

-- Per-table autovacuum override for high-churn tables
-- Default: vacuum when dead_tup > 20% of table (too slow for large tables)
ALTER TABLE payments SET (
    autovacuum_vacuum_scale_factor     = 0.01,   -- vacuum when 1% dead (not 20%)
    autovacuum_analyze_scale_factor    = 0.005,  -- analyze when 0.5% changed
    autovacuum_vacuum_cost_delay       = 2,      -- ms delay between cost units (lower = faster)
    autovacuum_vacuum_cost_limit       = 400,    -- cost units per round (default 200)
    autovacuum_vacuum_threshold        = 100     -- minimum dead rows before triggering
);

-- For extremely hot tables, trigger vacuum manually during off-peak
VACUUM (ANALYZE, VERBOSE) payments;

-- Prevent transaction ID wraparound: alert when age approaches limit
SELECT
    datname,
    age(datfrozenxid) AS xid_age,
    current_setting('autovacuum_freeze_max_age')::bigint AS freeze_max_age,
    ROUND(100.0 * age(datfrozenxid) /
        current_setting('autovacuum_freeze_max_age')::bigint, 1) AS pct_to_wraparound
FROM pg_database
ORDER BY xid_age DESC;
-- Alert when pct_to_wraparound > 75%

-- Table bloat estimate (without pg_bloat_check extension)
SELECT
    tablename,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS total_size,
    pg_size_pretty(
        pg_total_relation_size(schemaname||'.'||tablename) -
        pg_relation_size(schemaname||'.'||tablename)
    ) AS index_size
FROM pg_tables
WHERE schemaname = 'public'
ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC
LIMIT 20;
```

---

### Template 5 — PgBouncer Connection Pooling Configuration

```ini
# /etc/pgbouncer/pgbouncer.ini

[databases]
# Route all apps to this alias; change backend host/port here without app restart
payments_db = host=postgres-primary.payments.svc.cluster.local
              port=5432
              dbname=payments
              pool_size=20           # server-side connections to PostgreSQL

[pgbouncer]
listen_addr   = 0.0.0.0
listen_port   = 5432
auth_type     = scram-sha-256
auth_file     = /etc/pgbouncer/userlist.txt

# Transaction mode: connection returned to pool after each transaction
# Required for most ORMs; incompatible with session-level features (LISTEN, advisory locks)
pool_mode     = transaction

# Pool sizing: aim for 2-4 server connections per CPU core
default_pool_size   = 20           # server-side connections per db/user pair
max_client_conn     = 5000         # application-facing connections (cheap)
reserve_pool_size   = 5            # emergency connections when pool exhausted
reserve_pool_timeout = 3           # seconds to wait before using reserve pool

# Timeouts
server_connect_timeout  = 10       # fail fast if PostgreSQL unreachable
server_idle_timeout     = 600      # close idle server connection after 10 min
client_idle_timeout     = 3600     # close idle client connection after 1 hr
query_timeout           = 0        # 0 = no limit (set per query via statement_timeout)

# Health: pgbouncer exposes a virtual 'pgbouncer' database for stats
stats_users   = monitoring
log_connections = 0                # disable per-connection logging in production (noise)
log_disconnections = 0

# TLS to PostgreSQL backend
server_tls_sslmode   = require
server_tls_ca_file   = /etc/ssl/certs/ca.crt
```

```python
# python: verify pgbouncer stats via psycopg (connect to 'pgbouncer' pseudo-db)
import psycopg

def pgbouncer_stats(host: str, port: int, password: str) -> list[dict]:
    with psycopg.connect(
        host=host, port=port, dbname="pgbouncer",
        user="monitoring", password=password,
        autocommit=True,
    ) as conn:
        with conn.cursor(row_factory=psycopg.rows.dict_row) as cur:
            cur.execute("SHOW POOLS;")
            return cur.fetchall()

# Key columns in SHOW POOLS:
# cl_active   — clients currently executing a query
# cl_waiting  — clients waiting for a server connection (HIGH = pool too small)
# sv_active   — server connections in use
# sv_idle     — server connections available
# maxwait     — max seconds a client has been waiting (alert if > 1s)
```

---

### Template 6 — Slow-Query Triage Toolkit (SQL)

```sql
-- ── Step 1: find slow queries (requires pg_stat_statements) ──────────────────
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

SELECT
    ROUND(total_exec_time::numeric / calls, 2)  AS avg_ms,
    calls,
    ROUND(total_exec_time::numeric, 0)          AS total_ms,
    rows / calls                                AS avg_rows,
    LEFT(query, 120)                            AS query_preview
FROM pg_stat_statements
WHERE calls > 100
ORDER BY avg_ms DESC
LIMIT 20;

-- Reset stats after tuning to measure improvement cleanly
SELECT pg_stat_statements_reset();

-- ── Step 2: find lock contention ─────────────────────────────────────────────
SELECT
    blocked.pid,
    blocked.query,
    blocking.pid          AS blocking_pid,
    blocking.query        AS blocking_query,
    now() - blocked.query_start AS wait_duration
FROM pg_stat_activity blocked
JOIN pg_stat_activity blocking
    ON blocking.pid = ANY(pg_blocking_pids(blocked.pid))
WHERE blocked.cardinality(pg_blocking_pids(blocked.pid)) > 0;

-- ── Step 3: identify missing indexes (sequential scans on large tables) ───────
SELECT
    relname,
    seq_scan,
    seq_tup_read,
    idx_scan,
    n_live_tup,
    CASE WHEN seq_scan > 0
         THEN ROUND(seq_tup_read::numeric / seq_scan)
         ELSE 0 END AS avg_rows_per_seq_scan
FROM pg_stat_user_tables
WHERE n_live_tup > 10000
  AND seq_scan > idx_scan
ORDER BY seq_tup_read DESC
LIMIT 20;

-- ── Step 4: check bloated indexes ────────────────────────────────────────────
SELECT
    schemaname,
    tablename,
    indexname,
    pg_size_pretty(pg_relation_size(indexrelid)) AS index_size,
    idx_scan,
    idx_tup_read
FROM pg_stat_user_indexes
ORDER BY pg_relation_size(indexrelid) DESC
LIMIT 20;

-- Rebuild bloated index without locking reads/writes
REINDEX INDEX CONCURRENTLY idx_payments_status_created;

-- ── Step 5: key configuration parameters (check current vs recommended) ───────
SELECT name, setting, unit, short_desc
FROM pg_settings
WHERE name IN (
    'shared_buffers',           -- 25% of RAM
    'effective_cache_size',     -- 75% of RAM (planner hint)
    'work_mem',                 -- per-sort/hash; set low globally, high per-session for analytics
    'maintenance_work_mem',     -- for VACUUM, index builds
    'random_page_cost',         -- 1.1 for SSD, 4.0 for spinning disk
    'effective_io_concurrency', -- 200 for SSD, 2 for HDD
    'max_connections',          -- use PgBouncer instead of raising this
    'wal_buffers',              -- 64MB recommended
    'checkpoint_completion_target', -- 0.9
    'max_parallel_workers_per_gather' -- parallel query workers
);

-- ── Step 6: keyset pagination (replace OFFSET) ───────────────────────────────
-- BAD: OFFSET 10000 scans and discards 10000 rows
SELECT id, amount, created_at FROM payments
ORDER BY created_at DESC, id DESC
OFFSET 10000 LIMIT 20;

-- GOOD: keyset cursor — O(log N) regardless of page depth
SELECT id, amount, created_at FROM payments
WHERE (created_at, id) < ($last_created_at, $last_id)  -- pass previous page's last row
ORDER BY created_at DESC, id DESC
LIMIT 20;
-- Requires composite index: CREATE INDEX ON payments (created_at DESC, id DESC);
```

---

## Decision Matrix

| Scenario | Recommendation | Rationale |
|---|---|---|
| Large table, query always filters by date range | Range partition by date + BRIN index on date column | Partition pruning limits scan; BRIN tiny for ordered data |
| `LIKE '%keyword%'` search | `pg_trgm` GIN index | Only index type that supports leading-wildcard efficiently |
| Full-text search on multiple columns | `tsvector` GENERATED STORED column + GIN index | Pre-computed; fast; language-aware stemming |
| JSONB field containment query | GIN with `jsonb_path_ops` | Faster than `jsonb_ops` for containment; smaller index |
| Equality-only lookup on UUID/token | Hash index | Smaller than B-tree; equality-only |
| High-cardinality ORDER BY + LIMIT | Composite B-tree index on (filter cols, order col) | Index-ordered scan → stops at LIMIT; no sort node |
| Pagination on large result sets | Keyset cursor (`WHERE (col, id) < ($last, $id)`) | O(log N) constant cost per page; OFFSET is O(N) |
| High UPDATE/DELETE table with bloat | Lower `autovacuum_vacuum_scale_factor` to 0.01 | Default 20% threshold too slow for large hot tables |
| >100 app connections to PostgreSQL | PgBouncer transaction mode | PostgreSQL wastes memory on idle connections; pool multiplexes |
| Query plan wrong due to stale stats | `ANALYZE tablename` + check `random_page_cost` | Planner depends on statistics; SSD needs lower `random_page_cost` |
| Slow join between large tables | `EXPLAIN ANALYZE BUFFERS` → check join type + hash batches | `Batches: N` > 1 means hash spilling to disk; increase `work_mem` |

---

## Proficiency Levels

### Level 1 — Aware
- Understands what an index is and why a full table scan is slow
- Can run `EXPLAIN` (without ANALYZE) and identify Seq Scan vs Index Scan
- Knows that MVCC means readers don't block writers
- Understands the purpose of VACUUM at a conceptual level

### Level 2 — Practitioner
- Reads `EXPLAIN (ANALYZE, BUFFERS)` output: identifies slow nodes, buffer misses, row-estimate errors
- Creates appropriate B-tree indexes (composite, partial, covering) for common query patterns
- Configures per-table autovacuum thresholds for high-churn tables
- Sets up PgBouncer in transaction mode; sizes pools correctly
- Replaces OFFSET pagination with keyset cursors

### Level 3 — Advanced
- Chooses between B-tree, GIN (trigram, FTS, JSONB), BRIN, and Hash indexes for the access pattern
- Designs declarative range/list partitioning with partition pruning verification via `EXPLAIN`
- Tunes `random_page_cost`, `effective_cache_size`, `work_mem` based on storage type and query profile
- Uses `pg_stat_statements` to identify and systematically eliminate top-N slow queries
- Detects and resolves lock contention; understands row-level vs table-level locking
- Writes concurrent index builds and `REINDEX CONCURRENTLY` to avoid downtime

### Level 4 — Expert
- Designs physical data layout: table storage parameters, fillfactor for hot-update tables, CLUSTER for correlated scans
- Implements logical replication for zero-downtime major version upgrades (pglogical, built-in logical replication)
- Tunes WAL for throughput vs durability trade-off: `synchronous_commit`, `wal_compression`, `wal_writer_delay`
- Performs deep query plan analysis: forces plans with `enable_hashjoin`, `enable_seqscan` to test hypotheses
- Operates PostgreSQL at scale: connection pooler topology (PgBouncer + Pgpool-II), read replica routing, table inheritance vs declarative partitioning trade-offs

---

## AI Prompts

**Read and fix an EXPLAIN ANALYZE plan**
```
Analyse this PostgreSQL EXPLAIN (ANALYZE, BUFFERS) output and identify:
1. The bottleneck node (highest actual time, most buffer reads)
2. Whether row estimates match actuals (stale statistics?)
3. Missing indexes that would change the plan
4. Sort spills to disk (look for "external merge")
5. N+1 patterns (inner node loops >> 1)

For each finding: explain the cause and provide the SQL fix (CREATE INDEX,
ANALYZE, config change, or query rewrite).

[paste EXPLAIN ANALYZE output]
```

**Design indexes for a query workload**
```
Given these 5 most-frequent queries against the [table_name] table:
[paste queries]

And this table definition:
[paste CREATE TABLE]

Recommend indexes for each query. For each index:
- Type (B-tree / GIN / BRIN / Hash)
- Columns and order
- Partial filter if applicable
- INCLUDE columns for covering index
- Whether it helps multiple queries (reduce total index count)

Also flag any queries that cannot be fixed with indexes and need a rewrite.
```

**Tune autovacuum for a high-churn table**
```
This table has these characteristics:
- Row count: [N]
- UPDATE rate: [N] rows/second
- DELETE rate: [N] rows/second
- Current last_autovacuum: [timestamp or NULL]
- Dead tuple count: [N]

Recommend:
1. ALTER TABLE … SET (autovacuum_* = …) parameters with values and justification
2. Whether to run VACUUM ANALYZE manually now
3. A Prometheus alert rule for dead tuple ratio > 20%
4. pg_stat_statements query to monitor this table's vacuum health
```

**Right-size PgBouncer pool**
```
My PostgreSQL server has [N] CPU cores and [X GB] RAM.
My application has [N] instances, each opening up to [N] connections.
Queries are mostly OLTP (< 10ms), with occasional analytics queries (< 5s).

Recommend:
1. PgBouncer pool_mode (transaction vs session — justify)
2. default_pool_size per database/user pair
3. max_client_conn
4. reserve_pool_size
5. Any per-database overrides for the analytics workload
6. The key metrics to monitor in SHOW POOLS to detect pool starvation
```

---

## References

- **PostgreSQL documentation** — `postgresql.org/docs` — indexes, partitioning, autovacuum, WAL, MVCC
- **"PostgreSQL: Up and Running"** — O'Reilly; practical internals reference
- **"Database Internals"** — Alex Petrov; deep B-tree and LSM-tree internals, consensus, distributed storage
- **`pg_stat_statements`** — `postgresql.org/docs/current/pgstatstatements.html` — query performance tracking
- **EXPLAIN Depesz** — `explain.depesz.com` — paste EXPLAIN ANALYZE output for visual analysis
- **PgBouncer documentation** — `pgbouncer.org` — pool modes, sizing, auth, TLS
- **pg_partman** — `github.com/pgpartman/pg_partman` — automated partition creation and maintenance
- **`pg_trgm`** — PostgreSQL built-in trigram extension for fuzzy/substring search
- **Postgres Wiki — Slow Query Questions** — `wiki.postgresql.org/wiki/Slow_Query_Questions`
- **pganalyze** — `pganalyze.com` — commercial query analysis, index advisor, vacuum monitoring
- **"Use the Index, Luke"** — `use-the-index-luke.com` — free book on SQL index design across RDBMS
