---
name: "Modern Database Selection & Persistence Strategy"
slug: modern-database-selection-strategy
category: "05-data-and-persistence"
proficiency: Architect
description: "Master the selection, combination, and evolution of persistence technologies based on workload characteristics, consistency needs, and domain boundaries. Covers polyglot persistence, CQRS read models, Event Sourcing stores, CDC, caching, and analytics architectures."
tags: [database, persistence, postgresql, polyglot-persistence, cqrs, event-sourcing, redis, kafka, clickhouse, cdc, debezium, data-architecture, cap-theorem, schema-migration]
status: published
---

# Modern Database Selection & Persistence Strategy

## Principles

**Use the Right Tool for the Job (Polyglot Persistence)**
No single database is optimal for every access pattern. A relational store is excellent for transactional integrity; a document store handles flexible schemas; a time-series store handles sensor data; a vector store handles semantic search. Design persistence per Bounded Context, not per organisation.

**Data Model Follows Domain Model**
Do not design your database schema first and derive your domain model from it. Start with the domain model (Aggregates, Value Objects, Domain Events) and choose a persistence strategy that stores and retrieves it efficiently. When the persistence model drives the domain model, you get anemic domain objects and database-shaped business logic.

**Make Consistency Trade-offs Explicit**
Every distributed persistence decision involves CAP theorem trade-offs. Strong consistency (ACID) simplifies reasoning but limits horizontal scale. Eventual consistency enables scale but requires the application to handle transient inconsistency. These trade-offs must be documented (ADR) and visible to the team — never implicit.

**Design for Evolution**
Schemas change. Access patterns change. Data volumes change. Choose persistence technologies with a clear migration path. Prefer additive schema changes. Automate schema migrations. Never deploy schema changes that cannot be rolled back independently of application deployments.

**Observability and Backup/Restore Are Non-Negotiable**
A database without monitoring is a liability. Instrument query latency, connection pool saturation, replication lag, and disk growth from day one. Test your backup restore procedure before you need it, not after.

**Operational Burden Is a Cost**
A specialised database that perfectly fits the workload but requires rare expertise to operate may have a higher total cost than a slightly less optimal choice that the team already knows. Operational complexity compounds — every additional database type in the stack is another failure mode, another runbook, another on-call rotation item.

---

## Implementation Patterns

### Pattern 1 — Technology Selection by Workload

**Relational (PostgreSQL)**
Default choice for most workloads. ACID transactions, foreign keys, rich query planner, JSONB for semi-structured data, full-text search, and extensions (pgvector, PostGIS, TimescaleDB) cover the majority of use cases without introducing operational complexity.

Use when: complex relationships, referential integrity, mixed OLTP queries, evolving schema with migrations, team has relational expertise.

**Document (MongoDB, PostgreSQL JSONB)**
Use when the access pattern is always "fetch the whole document" and the schema varies significantly between records. Avoid when you need cross-document joins or complex aggregations — these are signs the data is relational.

Prefer PostgreSQL JSONB over MongoDB unless you specifically need MongoDB's horizontal sharding at document scale. JSONB gives you document flexibility inside a relational engine with full ACID and SQL.

**Key-Value (Redis, DragonflyDB)**
Cache (read-through, write-through, write-behind), session storage, rate limiting counters, distributed locks, leaderboards, pub/sub for lightweight event notifications. Not a primary store for domain data. TTL-based or event-driven invalidation.

**Wide-Column (Cassandra, ScyllaDB)**
High write throughput, linear horizontal scale, multi-region active-active. Use when write volume exceeds PostgreSQL's single-node capacity and the access pattern is predictable (always query by partition key). Cassandra sacrifices ad-hoc query flexibility for write scale.

**Time-Series (TimescaleDB, InfluxDB)**
Sensor data, metrics, financial tick data, IoT. TimescaleDB is a PostgreSQL extension — you keep SQL and ACID while gaining time-series compression and continuous aggregates.

**Graph (Neo4j, AWS Neptune)**
Highly connected data where relationship traversal is the primary query pattern: fraud detection, recommendation engines, identity graphs, knowledge graphs. If fewer than 20% of queries traverse more than 2 hops, PostgreSQL with adjacency lists is simpler.

**Columnar / Analytical (ClickHouse, DuckDB)**
OLAP workloads: aggregations over millions of rows, event analytics, log analysis, business intelligence. Never use for OLTP. ClickHouse for large-scale centralised analytics; DuckDB for in-process analytical queries over files (Parquet, CSV) without infrastructure.

**Vector (pgvector, Qdrant, Pinecone)**
Semantic search, RAG (Retrieval-Augmented Generation), recommendation by embedding similarity. pgvector is the lowest-friction entry point — it adds vector operations to PostgreSQL. Dedicated vector databases (Qdrant) offer better performance at scale and advanced filtering.

### Pattern 2 — Polyglot Persistence Per Bounded Context

Each Bounded Context owns its persistence. Contexts communicate via Domain Events, not shared databases.

```
Order Context       → PostgreSQL (ACID, relational)
Inventory Context   → PostgreSQL + Redis (cache hot stock levels)
Analytics Context   → ClickHouse (event stream from Kafka)
Search Context      → Elasticsearch / pgvector (full-text + semantic)
Session / Auth      → Redis (TTL-based, low latency)
Event Store         → EventStoreDB or PostgreSQL append-only table
```

The shared database anti-pattern (multiple services reading/writing the same tables) is the primary cause of tight coupling in distributed systems. Each service must own its schema and expose data only via its API or Domain Events.

### Pattern 3 — CQRS Read Model Projections

The write model (Aggregate → PostgreSQL) is normalised for integrity. The read model (projection) is denormalised for query performance.

```
Domain Event → Event Handler → Project into Read Store

Example:
OrderPlaced  → update order_summaries (PostgreSQL materialised view or Redis hash)
OrderShipped → update order_summaries.status, add tracking_ref
```

Read stores are disposable and rebuildable by replaying the event stream. Choose the read store technology for the query pattern, not for consistency:
- Dashboard / analytics → ClickHouse projection
- Low-latency API reads → Redis hash or PostgreSQL materialised view
- Full-text search → Elasticsearch index

### Pattern 4 — Schema Migration Strategy

**Expand-Contract (Blue-Green Schema Migration)**
Never deploy a breaking schema change simultaneously with the application change. Use a three-phase approach:
1. *Expand*: add the new column/table (backwards compatible); deploy application that writes to both old and new
2. *Migrate*: backfill data from old to new
3. *Contract*: remove the old column/table after all application versions reading it are retired

Tools: Flyway, Liquibase (version-controlled, repeatable migrations), Atlas (schema-as-code for PostgreSQL/MySQL).

**Zero-Downtime Migrations**
- Adding a nullable column: safe, no lock
- Adding a NOT NULL column: add as nullable, backfill, add NOT NULL constraint with `NOT VALID`, validate separately
- Adding an index: use `CREATE INDEX CONCURRENTLY` in PostgreSQL
- Dropping a column: remove application references first, then drop in a later deployment

### Pattern 5 — Cache Invalidation

**Event-Driven Invalidation (Preferred)**
When a domain event is published (e.g. `OrderUpdated`), a cache invalidation handler deletes or refreshes the relevant cache key. Consistent with the event-driven architecture; no polling or TTL races.

**TTL-Based (Acceptable for Eventually-Consistent Data)**
Cache entries expire after a fixed TTL. Simple to implement; tolerates stale data for the TTL window. Use for reference data that changes infrequently (product catalogue, config).

**Write-Through**
Write to cache and database simultaneously in the application. Cache is always current; adds write latency. Use when reads significantly outnumber writes and cache misses are expensive.

**Avoid Cache-Aside Without a Plan**
Cache-aside (lazy loading) is the default pattern but produces thundering herd on cache miss under high load. Add a mutex/lock or use probabilistic early expiration to prevent stampede.

---

## Anti-Patterns

| Anti-Pattern | Why It's Harmful | Fix |
|---|---|---|
| Golden Hammer (one DB for everything) | A relational DB serving OLTP, full-text search, time-series, and analytics is poorly optimised for all of them | Polyglot persistence per Bounded Context; choose the right store for each workload |
| Shared database across services | Schema changes in one service break others; deployments are coupled; no service autonomy | Each service owns its schema; integration via API or Domain Events only |
| Overusing NoSQL because it's modern | Document stores require denormalisation that makes writes complex and consistency hard; often worse than relational for the actual workload | Default to PostgreSQL; reach for NoSQL only when the access pattern specifically requires it |
| No migration strategy | Schema changes deployed in the same step as application changes; rollback is impossible | Expand-Contract migrations; schema and app deployed independently |
| Ignoring operational burden | Three exotic databases chosen for perfect fit; the team cannot operate them; incidents take hours to resolve | Factor in operational expertise and tooling maturity when choosing; prefer boring technology for non-core subdomains |
| Using Redis as a primary store | Redis is in-memory; durability configuration is complex; data loss on restart if misconfigured | Redis is a cache and session store; PostgreSQL is the source of truth |
| No backup restore test | Backups run but have never been restored; the restore procedure is unknown and likely broken | Restore to a staging environment on a schedule; measure RTO and RPO against SLAs |

---

## Code Templates

### PostgreSQL — JSONB Flexible Schema with Indexed Queries

```sql
-- Store semi-structured event metadata alongside structured columns
CREATE TABLE events (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    type        TEXT NOT NULL,
    aggregate_id UUID NOT NULL,
    occurred_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    payload     JSONB NOT NULL
);

-- Index on aggregate for event sourcing replay
CREATE INDEX events_aggregate_idx ON events (aggregate_id, occurred_at);

-- Index specific JSONB path for frequent query
CREATE INDEX events_customer_idx ON events ((payload->>'customer_id'))
    WHERE type = 'OrderPlaced';

-- Query: all orders placed by a customer
SELECT id, occurred_at, payload
FROM   events
WHERE  type = 'OrderPlaced'
  AND  payload->>'customer_id' = $1
ORDER  BY occurred_at;
```

### PostgreSQL — Zero-Downtime NOT NULL Column Migration

```sql
-- Step 1 (Expand): add nullable, deploy app that writes to it
ALTER TABLE orders ADD COLUMN shipping_address_id UUID;

-- Step 2 (Migrate): backfill in batches to avoid long lock
DO $$
DECLARE batch_size INT := 1000;
BEGIN
    LOOP
        UPDATE orders
        SET    shipping_address_id = legacy_address_id
        WHERE  shipping_address_id IS NULL
          AND  legacy_address_id   IS NOT NULL
        LIMIT  batch_size;
        EXIT WHEN NOT FOUND;
        PERFORM pg_sleep(0.05);  -- throttle to avoid I/O spike
    END LOOP;
END $$;

-- Step 3 (Contract): add constraint without full table scan lock
ALTER TABLE orders ADD CONSTRAINT orders_shipping_address_nn
    CHECK (shipping_address_id IS NOT NULL) NOT VALID;
ALTER TABLE orders VALIDATE CONSTRAINT orders_shipping_address_nn;

-- Step 4: drop old column after all app versions no longer reference it
ALTER TABLE orders DROP COLUMN legacy_address_id;
```

### Redis — Event-Driven Cache Invalidation (Go)

```go
// On OrderUpdated domain event, invalidate relevant cache keys
func (h *CacheInvalidationHandler) HandleOrderUpdated(ctx context.Context, evt OrderUpdated) error {
    keys := []string{
        fmt.Sprintf("order:%s", evt.OrderID),
        fmt.Sprintf("customer:%s:orders", evt.CustomerID),
        fmt.Sprintf("order:%s:summary", evt.OrderID),
    }
    return h.redis.Del(ctx, keys...).Err()
}

// Read-through cache helper
func (r *OrderReadRepository) FindSummary(ctx context.Context, id OrderID) (*OrderSummary, error) {
    key := fmt.Sprintf("order:%s:summary", id)

    cached, err := r.redis.Get(ctx, key).Bytes()
    if err == nil {
        var summary OrderSummary
        _ = json.Unmarshal(cached, &summary)
        return &summary, nil
    }

    summary, err := r.db.QueryOrderSummary(ctx, id)
    if err != nil { return nil, err }

    data, _ := json.Marshal(summary)
    r.redis.Set(ctx, key, data, 5*time.Minute)
    return summary, nil
}
```

### Flyway — Versioned Migration File Structure

```
db/migrations/
├── V1__create_orders_table.sql
├── V2__add_order_lines.sql
├── V3__add_shipping_address_nullable.sql    ← expand
├── V4__backfill_shipping_address.sql        ← migrate
├── V5__add_shipping_address_constraint.sql  ← contract
└── V6__drop_legacy_address_column.sql       ← cleanup
```

```sql
-- V3__add_shipping_address_nullable.sql
ALTER TABLE orders ADD COLUMN shipping_address_id UUID;

-- V6__drop_legacy_address_column.sql  (deployed after all app instances updated)
ALTER TABLE orders DROP COLUMN legacy_address_id;
```

### ClickHouse — CQRS Read Model for Order Analytics

```sql
-- ClickHouse table for order analytics (populated from Kafka event stream)
CREATE TABLE order_events (
    event_type   LowCardinality(String),
    order_id     UUID,
    customer_id  UUID,
    amount       Decimal(18, 2),
    currency     LowCardinality(String),
    occurred_at  DateTime64(3)
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(occurred_at)
ORDER BY (customer_id, occurred_at);

-- Materialised view: daily revenue per currency
CREATE MATERIALIZED VIEW daily_revenue
ENGINE = SummingMergeTree()
ORDER BY (day, currency)
AS SELECT
    toDate(occurred_at) AS day,
    currency,
    sum(amount)         AS total
FROM order_events
WHERE event_type = 'OrderPlaced'
GROUP BY day, currency;
```

---

## Decision Matrix

| Workload | Primary Store | Supporting Store | Avoid |
|---|---|---|---|
| Transactional business data (orders, accounts) | PostgreSQL | Redis (cache) | MongoDB for relational data |
| Flexible / evolving schema | PostgreSQL JSONB | — | Separate document DB unless truly needed |
| High write throughput + event stream | Kafka + PostgreSQL (append) | ClickHouse (analytics) | Relational DB as event log |
| Full-text + semantic search | pgvector + PostgreSQL FTS | Elasticsearch for large-scale | Elasticsearch for small datasets (operational overhead) |
| OLAP / analytics | ClickHouse or DuckDB | S3 / Parquet | PostgreSQL for aggregations over 100M+ rows |
| Session / ephemeral state | Redis | — | PostgreSQL (write amplification, cleanup overhead) |
| Graph traversal (fraud, recommendations) | Neo4j | PostgreSQL (reference data) | Relational for deep traversals |
| Time-series / IoT / metrics | TimescaleDB | ClickHouse (long-term) | Generic relational without partitioning |
| AI / RAG / semantic similarity | pgvector (small-medium) or Qdrant (large) | PostgreSQL (metadata) | Keyword-only search for semantic queries |

---

## Proficiency Levels

### Awareness
- Can explain the difference between relational, document, key-value, columnar, and graph databases.
- Understands CAP theorem and can give an example of a consistency vs availability trade-off.
- Knows what normalisation and denormalisation mean and when each is appropriate.

### Applied
- Chooses and configures the appropriate primary store for a bounded context.
- Designs PostgreSQL schemas with appropriate indexes, constraints, and JSONB usage.
- Implements a Redis caching layer with TTL-based or event-driven invalidation.
- Writes Flyway/Liquibase migrations using the Expand-Contract pattern.

### Master
- Designs polyglot persistence architectures: the right store per context, clear data ownership boundaries, no shared databases.
- Implements CQRS read model projections from domain event streams into multiple store types.
- Sets up CDC with Debezium for legacy data migration and event-driven sync.
- Designs and validates backup/restore procedures; measures RTO and RPO.

### Architect
- Defines organization-wide data strategy: store selection standards, schema migration governance, operational runbook requirements, data sovereignty and compliance controls.
- Balances operational complexity against performance and fit: avoids exotic technology choices for non-core subdomains.
- Evolves the data architecture roadmap alongside the system: plans migration from shared legacy databases to owned-per-service stores.
- Reviews data architecture for security: encryption at rest and in transit per data classification, access control per store, audit logging for sensitive data.

---

## AI Prompts

**Select a database for a use case:**
> I'm designing the persistence layer for this bounded context: [describe domain, access patterns, consistency needs, expected scale]. Recommend a primary store and any supporting stores, with justification. Flag any operational concerns.

**Review a data architecture:**
> Review this persistence architecture for anti-patterns. Check: Are any databases shared across service boundaries? Is the store choice appropriate for the access pattern? Is there a schema migration strategy? Is caching invalidation strategy defined? Is there a backup/restore plan? [paste architecture description or C4 diagram]

**Design a schema migration:**
> I need to migrate this PostgreSQL table: [describe current schema and desired change]. Produce an Expand-Contract migration plan: the SQL for each step, how to deploy each step independently, and what to validate before the Contract step.

**Design a CQRS read model:**
> I have this event stream: [list domain events with fields]. I need to support these read queries: [list queries with latency requirements]. For each query, recommend a read model store, the projection logic from events, and the eventual consistency strategy for the UI.

**Evaluate polyglot complexity:**
> Our system currently uses PostgreSQL, Redis, Elasticsearch, MongoDB, and ClickHouse. Evaluate whether this stack is justified or over-engineered for this workload: [describe workloads]. Recommend consolidation where appropriate and flag operational risks.

---

## References

**Books**
- Martin Kleppmann — *Designing Data-Intensive Applications* (O'Reilly, 2017) — the definitive reference; covers replication, partitioning, consistency, stream processing
- Chris Richardson — *Microservices Patterns* (Manning, 2018) — data ownership, Saga, CQRS, event sourcing from a persistence perspective

**Key Concepts**
- [CAP Theorem](https://www.infoq.com/articles/cap-twelve-years-later-how-the-rules-have-changed/) — Eric Brewer's revisit (2012); read before any distributed DB decision
- [PACELC Model](https://en.wikipedia.org/wiki/PACELC_theorem) — extends CAP with latency trade-offs; more useful for practical decisions

**Tooling**
- [Flyway](https://flywaydb.org/) / [Liquibase](https://www.liquibase.org/) — SQL-based version-controlled migrations
- [Atlas](https://atlasgo.io/) — schema-as-code for PostgreSQL, MySQL, SQLite
- [Debezium](https://debezium.io/) — CDC for PostgreSQL, MySQL, SQL Server, MongoDB
- [pgvector](https://github.com/pgvector/pgvector) — vector similarity search extension for PostgreSQL

**Related Skills**
- `02-architecture-and-design/ddd-fundamentals` — Aggregates define persistence unit boundaries; data model follows domain model
- `02-architecture-and-design/event-driven-architecture-cqrs` — CQRS read models and Event Sourcing stores are persistence patterns
- `09-re-engineering-and-evolution/strangler-fig-legacy-modernization` — CDC and Dual Write are the data migration engine for incremental re-engineering
- `06-security-and-compliance/authentication-and-authorization` — per-store access control, encryption at rest, and audit logging requirements
