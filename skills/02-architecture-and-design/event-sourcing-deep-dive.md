---
name: Event Sourcing Deep Dive
slug: event-sourcing-deep-dive
category: 02-architecture-and-design
proficiency: advanced
description: >
  Production-grade Event Sourcing: immutable event logs as source of truth,
  aggregate stream design, optimistic concurrency, snapshotting strategies,
  projection (read model) construction with catch-up subscriptions, event
  versioning and upcasting, consistency boundaries, process managers, and
  replay/rebuild patterns. Covers PostgreSQL and EventStoreDB as event stores
  and the operational concerns that distinguish toy implementations from
  systems that run in production for years.
tags:
  - event-sourcing
  - event-store
  - projections
  - snapshotting
  - upcasting
  - cqrs
  - ddd
  - eventstore-db
  - postgresql
  - process-manager
status: published
---

## Principles

### 1. The Event Log Is the Source of Truth — State Is Derived
In a traditional system the database holds *current state*; history is at best
an audit log bolted on as an afterthought. In Event Sourcing the **append-only
event log is primary**. Current state is a projection — a left-fold over the
ordered sequence of events:

```
state = events.reduce(apply, initialState)
```

This inversion means you can reconstruct *any past state* by replaying to a
given position, and you can build *new read models* retroactively without
touching the write side.

### 2. One Stream Per Aggregate — Stream ID = Aggregate Identity
Each aggregate instance owns a single, ordered stream identified by its ID
(e.g., `order-7f3a2c`). Events within a stream are **totally ordered** and
carry a monotonically increasing stream position (version). Cross-stream
ordering is **not guaranteed** — if your logic requires it, you need a process
manager or a global event position from the store.

### 3. Optimistic Concurrency Is Built Into the Append Contract
Appending to a stream includes an **expected version**: the caller states what
position the stream was at when it loaded the aggregate. If another writer
advanced the stream between load and append, the store rejects the write with
a conflict error. The caller reloads and retries — no pessimistic locks needed.

### 4. Snapshots Are a Performance Optimisation, Not a Design Primitive
Replaying 50 000 events to hydrate an aggregate is correct but slow. A snapshot
is a serialised aggregate state at a known stream position. On load, seek to
the latest snapshot then replay only the delta. **Snapshots do not replace the
event log** — they are disposable caches. You must be able to delete all
snapshots and rebuild from events at any time.

### 5. Projections Are Eventually Consistent Read Models
A projection subscribes to the event log (from the beginning or from a saved
checkpoint) and folds events into a query-optimised read model (SQL table,
document store, in-memory cache). The write path appends events; the read path
queries projections. They are decoupled in time — accept and design for
**eventual consistency** on the read side.

### 6. Events Are Public API — Versioning Is Mandatory
Once events are written to a durable log they cannot be changed. Systems that
read those events may run versions behind. **Upcasting** (transforming an old
event schema to a new one on read) and **weak schema** (additive changes only,
consumers ignore unknown fields) are the primary versioning strategies. Plan
for both from day one.

---

## Implementation Patterns

### Pattern A: PostgreSQL as Event Store
A relational event store is operationally simple and supports the full contract:
stream-ordered append, optimistic concurrency via version conflict, and
efficient catch-up subscriptions via a global position column.

### Pattern B: Catch-Up Subscription with Durable Checkpointing
A projection reads from a known global position (checkpoint), processes events,
updates the read model, and atomically commits the new checkpoint. On restart
it resumes from the checkpoint. This gives **at-least-once delivery** with
idempotent event handlers providing exactly-once semantics.

### Pattern C: Snapshot Policy
Snapshot after every N events (e.g., N = 200) or when aggregate size exceeds a
threshold. Store snapshots in a separate table keyed by (stream_id, version).
On aggregate load: fetch the most recent snapshot; if none, start from version 0;
then replay events from snapshot_version + 1 to head.

### Pattern D: Event Upcasting Registry
Each event type carries a schema version (`"$schema_version": 2`). On
deserialisation an **upcaster chain** transforms v1 → v2 → v3 before the
aggregate sees the event. Upcasters are pure functions — no I/O. Old events
are never rewritten in the store.

### Pattern E: Process Manager (Saga)
A process manager subscribes to events from multiple streams and orchestrates
a long-running workflow by issuing commands. It tracks its own state as events
in its own stream, making it recoverable and inspectable. It is **not** a saga
with compensating transactions — it is a stateful event-driven workflow
coordinator.

---

## Anti-Patterns

| Anti-Pattern | Consequence | Fix |
|---|---|---|
| Storing commands as events (`PlaceOrderCommand`) | Commands can be rejected; events must represent facts that already happened | Events are past tense (`OrderPlaced`); commands are intent |
| Fat events (entire aggregate state in every event) | Defeats the purpose; hides what actually changed; event log becomes an audit of blobs | Events record the minimal delta: only the fields that changed |
| Using the event store as a message broker | Consumers coupling to store internals; ordering guarantees break across streams | Publish events to a broker (Kafka, SNS) *after* appending to the store via Outbox/CDC |
| Synchronous projection update on the write path | Write latency includes projection latency; projection failure blocks command handling | Projections are async; write path only appends to the event log |
| Missing idempotency in event handlers | Reprocessing after restart causes duplicate side-effects (emails, payments) | Handlers deduplicate on event ID or use upsert semantics |
| Sharing a stream across aggregate instances | Unbounded stream growth; optimistic concurrency becomes a hotspot | Strict one-stream-per-aggregate-instance discipline |
| Deleting events for GDPR | Event log integrity broken; all projections that read deleted events diverge | Store PII in an external encryption key vault; delete the key (crypto-shredding) |
| Rebuilding projections against a live store | Replay load spikes impact production writes | Rebuild against a read replica or a snapshot of the store |

---

## Code Templates

### Template 1 — SQL: PostgreSQL Event Store Schema
```sql
-- streams: one row per aggregate instance
CREATE TABLE streams (
    stream_id   TEXT        PRIMARY KEY,
    version     BIGINT      NOT NULL DEFAULT 0,   -- current head version
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- events: append-only event log
CREATE TABLE events (
    global_position BIGSERIAL   PRIMARY KEY,      -- total order across all streams
    stream_id       TEXT        NOT NULL REFERENCES streams(stream_id),
    stream_version  BIGINT      NOT NULL,          -- position within this stream
    event_type      TEXT        NOT NULL,
    schema_version  INT         NOT NULL DEFAULT 1,
    event_id        UUID        NOT NULL DEFAULT gen_random_uuid(),
    correlation_id  UUID,
    causation_id    UUID,
    payload         JSONB       NOT NULL,
    metadata        JSONB       NOT NULL DEFAULT '{}',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (stream_id, stream_version)
);

-- Partial index for efficient catch-up subscription queries
CREATE INDEX idx_events_global_pos ON events (global_position);
CREATE INDEX idx_events_stream     ON events (stream_id, stream_version);

-- snapshots: disposable cache — can be truncated at any time
CREATE TABLE snapshots (
    stream_id       TEXT        NOT NULL,
    stream_version  BIGINT      NOT NULL,
    aggregate_type  TEXT        NOT NULL,
    state           JSONB       NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (stream_id, stream_version)
);

-- projection checkpoints: durable cursor per projection
CREATE TABLE projection_checkpoints (
    projection_name     TEXT    PRIMARY KEY,
    last_global_position BIGINT NOT NULL DEFAULT 0,
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

```sql
-- Append with optimistic concurrency (call from application transaction)
-- Returns new stream_version; raises exception on conflict.
CREATE OR REPLACE FUNCTION append_events(
    p_stream_id       TEXT,
    p_expected_version BIGINT,    -- -1 means "stream must not exist"
    p_events          JSONB       -- array of {event_type, schema_version, payload, metadata}
) RETURNS BIGINT AS $$
DECLARE
    v_current BIGINT;
    v_new     BIGINT;
    v_event   JSONB;
    v_idx     INT := 0;
BEGIN
    -- Lock the stream row to serialise concurrent appends
    SELECT version INTO v_current
    FROM streams WHERE stream_id = p_stream_id FOR UPDATE;

    IF NOT FOUND THEN
        IF p_expected_version <> -1 THEN
            RAISE EXCEPTION 'stream_not_found: %', p_stream_id;
        END IF;
        INSERT INTO streams (stream_id, version) VALUES (p_stream_id, 0);
        v_current := 0;
    END IF;

    IF p_expected_version <> -1 AND v_current <> p_expected_version THEN
        RAISE EXCEPTION 'optimistic_concurrency_conflict: stream=% expected=% actual=%',
            p_stream_id, p_expected_version, v_current;
    END IF;

    v_new := v_current;
    FOR v_event IN SELECT * FROM jsonb_array_elements(p_events) LOOP
        v_new := v_new + 1;
        INSERT INTO events (stream_id, stream_version, event_type, schema_version,
                            payload, metadata, correlation_id, causation_id)
        VALUES (
            p_stream_id, v_new,
            v_event->>'event_type', (v_event->>'schema_version')::int,
            v_event->'payload', COALESCE(v_event->'metadata', '{}'),
            (v_event->>'correlation_id')::uuid,
            (v_event->>'causation_id')::uuid
        );
    END LOOP;

    UPDATE streams SET version = v_new WHERE stream_id = p_stream_id;
    RETURN v_new;
END;
$$ LANGUAGE plpgsql;
```

### Template 2 — C#: Aggregate Base Class with Event Sourcing
```csharp
// EventSourcedAggregate.cs
public abstract class EventSourcedAggregate
{
    private readonly List<object> _uncommittedEvents = new();

    public string StreamId { get; protected init; } = default!;
    public long Version { get; private set; } = -1;  // -1 = new stream

    // Load from history (called by the repository)
    public void LoadFrom(IReadOnlyList<StoredEvent> history)
    {
        foreach (var stored in history)
        {
            ApplyEvent(stored.Payload);
            Version = stored.StreamVersion;
        }
    }

    // Derived classes call this to record an event
    protected void Raise(object @event)
    {
        ApplyEvent(@event);
        _uncommittedEvents.Add(@event);
    }

    // Consume uncommitted events (called by the repository after append)
    public IReadOnlyList<object> DequeueEvents()
    {
        var copy = _uncommittedEvents.ToList();
        _uncommittedEvents.Clear();
        return copy;
    }

    // Dispatcher — each aggregate implements When() overloads
    private void ApplyEvent(object @event) =>
        ((dynamic)this).When((dynamic)@event);
}

// Order aggregate example
public class Order : EventSourcedAggregate
{
    public OrderStatus Status { get; private set; }
    public Money Total { get; private set; } = Money.Zero;
    public List<OrderLine> Lines { get; } = new();

    private Order() {}

    public static Order Place(OrderId id, CustomerId customerId, IReadOnlyList<OrderLine> lines)
    {
        if (!lines.Any()) throw new DomainException("Order must have at least one line");
        var order = new Order { StreamId = $"order-{id}" };
        order.Raise(new OrderPlaced(id, customerId, lines, DateTime.UtcNow));
        return order;
    }

    public void Confirm(PaymentId paymentId)
    {
        if (Status != OrderStatus.Pending)
            throw new DomainException($"Cannot confirm order in status {Status}");
        Raise(new OrderConfirmed(paymentId, DateTime.UtcNow));
    }

    // Event application — pure state mutation, no side-effects
    private void When(OrderPlaced e)
    {
        Status = OrderStatus.Pending;
        Lines.AddRange(e.Lines);
        Total = e.Lines.Aggregate(Money.Zero, (acc, l) => acc + l.Price * l.Quantity);
    }

    private void When(OrderConfirmed e) => Status = OrderStatus.Confirmed;
}
```

```csharp
// EventStoreRepository.cs — PostgreSQL-backed
public class EventStoreRepository<T> where T : EventSourcedAggregate, new()
{
    private readonly IEventStore _store;
    private readonly ISnapshotStore _snapshots;
    private readonly IEventSerializer _serializer;

    public EventStoreRepository(IEventStore store, ISnapshotStore snapshots,
                                 IEventSerializer serializer)
        => (_store, _snapshots, _serializer) = (store, snapshots, serializer);

    public async Task<T> LoadAsync(string streamId, CancellationToken ct = default)
    {
        var aggregate = new T { StreamId = streamId };
        long fromVersion = 0;

        // Try snapshot first
        var snapshot = await _snapshots.LoadAsync(streamId, ct);
        if (snapshot is not null)
        {
            _serializer.ApplySnapshot(aggregate, snapshot);
            fromVersion = snapshot.StreamVersion + 1;
        }

        var events = await _store.ReadStreamAsync(streamId, fromVersion, ct);
        aggregate.LoadFrom(events);
        return aggregate;
    }

    public async Task SaveAsync(T aggregate, CancellationToken ct = default)
    {
        var uncommitted = aggregate.DequeueEvents();
        if (!uncommitted.Any()) return;

        var storedEvents = uncommitted
            .Select(e => _serializer.Serialize(e))
            .ToList();

        await _store.AppendAsync(aggregate.StreamId, aggregate.Version - uncommitted.Count,
                                  storedEvents, ct);

        // Snapshot policy: every 200 events
        if (aggregate.Version % 200 == 0)
            await _snapshots.SaveAsync(aggregate.StreamId, aggregate.Version,
                                        _serializer.SerializeState(aggregate), ct);
    }
}
```

### Template 3 — TypeScript: Projection Engine with Catch-Up Subscription
```typescript
// projection-engine.ts
import { Pool } from 'pg';

interface StoredEvent {
  globalPosition: bigint;
  streamId: string;
  streamVersion: bigint;
  eventType: string;
  schemaVersion: number;
  eventId: string;
  correlationId: string | null;
  payload: Record<string, unknown>;
  createdAt: Date;
}

type EventHandler<TState> = (
  state: TState,
  event: StoredEvent
) => Promise<TState> | TState;

interface Projection<TState> {
  name: string;
  handlers: Partial<Record<string, EventHandler<TState>>>;
  initialState: () => TState;
  persist: (state: TState, event: StoredEvent, client: Pool) => Promise<void>;
}

async function runCatchUpSubscription<TState>(
  db: Pool,
  projection: Projection<TState>,
  batchSize = 500
): Promise<void> {
  while (true) {
    const { rows: [checkpoint] } = await db.query<{ last_global_position: string }>(
      `SELECT last_global_position FROM projection_checkpoints WHERE projection_name = $1`,
      [projection.name]
    );
    const fromPosition = BigInt(checkpoint?.last_global_position ?? 0);

    const { rows: events } = await db.query<{
      global_position: string; stream_id: string; stream_version: string;
      event_type: string; schema_version: number; event_id: string;
      correlation_id: string | null; payload: Record<string, unknown>; created_at: Date;
    }>(
      `SELECT global_position, stream_id, stream_version, event_type, schema_version,
              event_id, correlation_id, payload, created_at
       FROM events
       WHERE global_position > $1
       ORDER BY global_position ASC
       LIMIT $2`,
      [fromPosition.toString(), batchSize]
    );

    if (events.length === 0) {
      await sleep(100);  // no new events; poll again shortly
      continue;
    }

    for (const row of events) {
      const event: StoredEvent = {
        globalPosition: BigInt(row.global_position),
        streamId: row.stream_id,
        streamVersion: BigInt(row.stream_version),
        eventType: row.event_type,
        schemaVersion: row.schema_version,
        eventId: row.event_id,
        correlationId: row.correlation_id,
        payload: row.payload,
        createdAt: row.created_at,
      };

      const handler = projection.handlers[event.eventType];
      if (handler) {
        const client = await db.connect();
        try {
          await client.query('BEGIN');
          await projection.persist(projection.initialState(), event, db);
          await client.query(
            `INSERT INTO projection_checkpoints (projection_name, last_global_position, updated_at)
             VALUES ($1, $2, now())
             ON CONFLICT (projection_name) DO UPDATE
               SET last_global_position = $2, updated_at = now()`,
            [projection.name, event.globalPosition.toString()]
          );
          await client.query('COMMIT');
        } catch (err) {
          await client.query('ROLLBACK');
          throw err;
        } finally {
          client.release();
        }
      }
    }
  }
}

// Example: OrderSummary projection
const orderSummaryProjection: Projection<void> = {
  name: 'order_summary',
  initialState: () => undefined,
  handlers: {
    OrderPlaced: async (_, event) => {
      // handled in persist
    },
    OrderConfirmed: async (_, event) => {},
  },
  persist: async (_, event, db) => {
    if (event.eventType === 'OrderPlaced') {
      const { orderId, customerId, total } = event.payload as {
        orderId: string; customerId: string; total: number;
      };
      await db.query(
        `INSERT INTO order_summary (order_id, customer_id, total, status, placed_at)
         VALUES ($1, $2, $3, 'pending', $4)
         ON CONFLICT (order_id) DO NOTHING`,
        [orderId, customerId, total, event.createdAt]
      );
    } else if (event.eventType === 'OrderConfirmed') {
      await db.query(
        `UPDATE order_summary SET status = 'confirmed' WHERE order_id = $1`,
        [(event.payload as { orderId: string }).orderId]
      );
    }
  },
};

const sleep = (ms: number) => new Promise(r => setTimeout(r, ms));
```

### Template 4 — Go: Snapshot Store with Threshold Policy
```go
package eventsourcing

import (
    "context"
    "database/sql"
    "encoding/json"
    "fmt"
    "time"
)

const snapshotThreshold = 200

type Snapshot struct {
    StreamID      string
    StreamVersion int64
    AggregateType string
    State         json.RawMessage
    CreatedAt     time.Time
}

type SnapshotStore struct {
    db *sql.DB
}

func NewSnapshotStore(db *sql.DB) *SnapshotStore {
    return &SnapshotStore{db: db}
}

func (s *SnapshotStore) Load(ctx context.Context, streamID string) (*Snapshot, error) {
    row := s.db.QueryRowContext(ctx, `
        SELECT stream_id, stream_version, aggregate_type, state, created_at
        FROM snapshots
        WHERE stream_id = $1
        ORDER BY stream_version DESC
        LIMIT 1`, streamID)

    var snap Snapshot
    err := row.Scan(&snap.StreamID, &snap.StreamVersion,
        &snap.AggregateType, &snap.State, &snap.CreatedAt)
    if err == sql.ErrNoRows {
        return nil, nil
    }
    return &snap, err
}

func (s *SnapshotStore) Save(ctx context.Context, snap *Snapshot) error {
    _, err := s.db.ExecContext(ctx, `
        INSERT INTO snapshots (stream_id, stream_version, aggregate_type, state, created_at)
        VALUES ($1, $2, $3, $4, now())
        ON CONFLICT (stream_id, stream_version) DO NOTHING`,
        snap.StreamID, snap.StreamVersion, snap.AggregateType, snap.State)
    return err
}

// ShouldSnapshot returns true when the aggregate has accumulated
// enough new events since the last snapshot to warrant a new one.
func ShouldSnapshot(currentVersion, snapshotVersion int64) bool {
    if snapshotVersion == 0 {
        return currentVersion >= snapshotThreshold
    }
    return (currentVersion - snapshotVersion) >= snapshotThreshold
}

// PurgeOldSnapshots keeps only the latest N snapshots per stream
// to prevent unbounded growth.
func (s *SnapshotStore) PurgeOld(ctx context.Context, streamID string, keepN int) error {
    _, err := s.db.ExecContext(ctx, `
        DELETE FROM snapshots
        WHERE stream_id = $1
          AND stream_version NOT IN (
              SELECT stream_version FROM snapshots
              WHERE stream_id = $1
              ORDER BY stream_version DESC
              LIMIT $2
          )`, streamID, keepN)
    return err
}

// RebuildFromScratch deletes all snapshots, forcing full event replay.
// Use during schema migrations or after discovering a snapshot bug.
func (s *SnapshotStore) RebuildFromScratch(ctx context.Context, aggregateType string) error {
    _, err := s.db.ExecContext(ctx,
        `DELETE FROM snapshots WHERE aggregate_type = $1`, aggregateType)
    return fmt.Errorf("snapshot rebuild triggered for %s: %w", aggregateType, err)
}
```

### Template 5 — Python: Event Upcaster Registry
```python
# upcasting.py — schema versioning without mutating stored events
from __future__ import annotations
from dataclasses import dataclass, field
from typing import Any, Callable

Upcaster = Callable[[dict[str, Any]], dict[str, Any]]

@dataclass
class UpcasterRegistry:
    """
    Chain of upcasters per event type.
    Upcasters transform old schema versions to the current version on read.
    Events in the store are NEVER modified.
    """
    _chains: dict[str, list[tuple[int, Upcaster]]] = field(default_factory=dict)

    def register(self, event_type: str, from_version: int):
        """Decorator: @registry.register('OrderPlaced', from_version=1)"""
        def decorator(fn: Upcaster) -> Upcaster:
            self._chains.setdefault(event_type, []).append((from_version, fn))
            self._chains[event_type].sort(key=lambda x: x[0])
            return fn
        return decorator

    def upcast(self, event_type: str, schema_version: int,
               payload: dict[str, Any]) -> dict[str, Any]:
        chain = self._chains.get(event_type, [])
        result = dict(payload)
        for (applies_from, upcaster) in chain:
            if schema_version <= applies_from:
                result = upcaster(result)
        return result


registry = UpcasterRegistry()

# v1 OrderPlaced had a flat `total` field (cents int).
# v2 splits it into {amount, currency}.
@registry.register('OrderPlaced', from_version=1)
def upcast_order_placed_v1_to_v2(payload: dict) -> dict:
    payload = dict(payload)
    if 'total' in payload and 'amount' not in payload:
        payload['amount'] = payload.pop('total')
        payload['currency'] = 'ZAR'       # legacy system default
    payload['$schema_version'] = 2
    return payload

# v2 → v3: customerId was a plain int; now a UUID string prefixed with 'cust-'
@registry.register('OrderPlaced', from_version=2)
def upcast_order_placed_v2_to_v3(payload: dict) -> dict:
    payload = dict(payload)
    if isinstance(payload.get('customerId'), int):
        payload['customerId'] = f"cust-{payload['customerId']:08d}"
    payload['$schema_version'] = 3
    return payload


# Usage in event deserialiser
def deserialize_event(row: dict) -> dict:
    event_type     = row['event_type']
    schema_version = row['schema_version']
    payload        = row['payload']          # already parsed JSONB dict
    return registry.upcast(event_type, schema_version, payload)
```

### Template 6 — C#: Process Manager (Saga Coordinator)
```csharp
// PaymentProcessManager.cs — coordinates Order + Payment streams
public class PaymentProcessManager : EventSourcedAggregate
{
    public ProcessStatus Status { get; private set; }
    public string OrderId { get; private set; } = default!;
    public string? PaymentId { get; private set; }

    private PaymentProcessManager() { }

    // Factory: start when an order is placed
    public static PaymentProcessManager Start(string orderId, decimal amount)
    {
        var pm = new PaymentProcessManager
        {
            StreamId = $"payment-process-{orderId}"
        };
        pm.Raise(new PaymentProcessStarted(orderId, amount, DateTime.UtcNow));
        return pm;
    }

    // React to external events routed by the process manager host
    public IReadOnlyList<object> Handle(OrderPlaced e)
    {
        if (Status != ProcessStatus.WaitingForPayment) return [];
        // Issue a command — returned to the host which dispatches it
        return [new InitiatePaymentCommand(e.OrderId, e.Total)];
    }

    public void Handle(PaymentSucceeded e)
    {
        if (Status != ProcessStatus.WaitingForPayment) return;
        Raise(new PaymentProcessCompleted(e.PaymentId, DateTime.UtcNow));
    }

    public void Handle(PaymentFailed e)
    {
        if (Status != ProcessStatus.WaitingForPayment) return;
        Raise(new PaymentProcessFailed(e.Reason, DateTime.UtcNow));
        // Could raise a CancelOrderCommand here
    }

    private void When(PaymentProcessStarted e)
    {
        OrderId = e.OrderId;
        Status  = ProcessStatus.WaitingForPayment;
    }

    private void When(PaymentProcessCompleted e)
    {
        PaymentId = e.PaymentId;
        Status    = ProcessStatus.Completed;
    }

    private void When(PaymentProcessFailed _) =>
        Status = ProcessStatus.Failed;
}
```

---

## Decision Matrix

| Question | Option A | Option B | Guidance |
|---|---|---|---|
| **Event store backend** | PostgreSQL (`append_events` function) | EventStoreDB (native) | PostgreSQL if team already operates it; EventStoreDB for native persistent subscriptions and projections engine |
| **Snapshot threshold** | Every N events (N = 100–500) | Size-based (aggregate JSON > 10 KiB) | Event count is simpler; size-based prevents unbounded snapshots for aggregates with large collections |
| **Projection delivery** | Polling catch-up subscription | Streaming subscription (EventStoreDB persistent sub / Kafka) | Polling works at any scale; streaming reduces latency for near-real-time read models |
| **Event versioning** | Upcasting (transform on read) | Copy-transform (write new events to new stream) | Upcasting preferred — keeps store clean; copy-transform for major breaking schema rewrites |
| **GDPR / data deletion** | Crypto-shredding (delete encryption key) | Tombstone events + projection rebuild | Crypto-shredding is clean; tombstone approach requires all projections to respect tombstones |
| **Projection rebuild strategy** | Replay against read replica | Rebuild into new table, swap alias | Table alias swap gives zero-downtime; requires `CREATE INDEX CONCURRENTLY` support |
| **Consistency boundary** | Aggregate = transaction boundary | Cross-aggregate saga | Never span a transaction across aggregates; use process manager for cross-boundary workflows |
| **When NOT to use Event Sourcing** | CRUD-heavy domain with no audit requirement | Reporting-only data | ES adds operational complexity; teams must understand it; don't apply everywhere |

---

## Proficiency Levels

### Novice
- Understands the concept of event log as source of truth vs mutable state
- Can describe why `OrderPlaced` is valid but `UpdateOrder` is not
- Reads event store tables; writes basic SQL queries against the events table
- Knows that projections are read models derived from events

### Intermediate
- Implements an aggregate with `Raise`/`Apply` pattern and loads from history
- Writes a catch-up subscription with checkpoint persistence
- Applies optimistic concurrency (`expected_version`) and handles conflict retry
- Implements a basic upcaster for a single schema migration
- Deploys PostgreSQL event store schema in production with monitoring

### Advanced
- Designs snapshot policy and purge strategy for long-lived aggregates
- Implements full upcaster registry with chained migrations across 3+ versions
- Builds a process manager coordinating multiple aggregate streams
- Architects zero-downtime projection rebuilds with table-alias swap
- Implements crypto-shredding for GDPR-compliant event stores
- Integrates event publishing to Kafka/SNS via Outbox pattern (no dual-write)

### Expert
- Designs multi-tenant event store with stream-level access control
- Evaluates consistency tradeoffs between aggregate boundaries and business invariants
- Implements custom EventStoreDB projections in JavaScript (built-in engine)
- Architects event store replication, disaster recovery, and cross-region active-active
- Defines organisation-wide event schema governance (AsyncAPI, schema registry)
- Identifies when Event Sourcing adds unjustified complexity and recommends simpler alternatives

---

## AI Prompts

```
You are a DDD and Event Sourcing expert. I have a bank account aggregate with
50 000+ events per account. My aggregate load time is 8 seconds. Design a
complete snapshotting strategy: the data structure, when to snapshot, where
to store it, how to load with snapshot + delta replay, and how to handle the
case where a snapshot was taken with a buggy version of the Apply logic.
```

```
Acting as an Event Sourcing architect: my team stores PII (name, address,
national ID) directly in event payloads. We need to implement GDPR right-to-
erasure. Explain the crypto-shredding pattern end to end: key storage (per
customer or per field), how to encrypt on write, how to decrypt on read,
what happens to projections after key deletion, and operational concerns.
```

```
Compare three event versioning strategies: (1) upcasting, (2) weak schema
with additive-only changes, (3) copy-transform (writing compensating events).
For each: describe the implementation effort, the risk of projection divergence,
and the scenario where it is the right choice. Give a concrete example of an
OrderPlaced event schema evolving from v1 to v3.
```

```
I need to implement a process manager that coordinates an e-commerce checkout:
OrderPlaced → ReserveInventory (sync) → ChargePayment (async) → ConfirmOrder,
with compensating actions if payment fails. Design the process manager as an
event-sourced aggregate: what events does it raise, what commands does it
issue, how does it handle timeouts, and how is it recovered after a crash?
```

```
My Event Sourcing system has a projection that is 2 million events behind
because a bug in the handler caused it to crash in a loop. The projection
feeds the main product search page. Design a zero-downtime rebuild plan:
how to rebuild in parallel, validate correctness, swap the live projection,
and prevent the same bug from causing the same incident again.
```

---

## References

- **Young, Greg** — *CQRS Documents* (original Event Sourcing definition and patterns)
- **Vernon, Vaughn** — *Implementing Domain-Driven Design*, Ch. 8 (Domain Events)
- **Fowler, Martin** — *Event Sourcing* pattern (martinfowler.com)
- **EventStoreDB docs** — https://developers.eventstore.com — persistent subscriptions, projections
- **Marten library** — https://martendb.io — PostgreSQL event store for .NET (Marten v7)
- **Axon Framework** — https://axoniq.io — Java/Kotlin event sourcing framework
- **Eventuate** — https://eventuate.io — microservices event sourcing + sagas
- **AsyncAPI** — https://asyncapi.com — schema registry and governance for events
- **Kleppmann, Martin** — *Designing Data-Intensive Applications*, Ch. 11 (Stream Processing)
- **Richardson, Chris** — *Microservices Patterns*, Ch. 6 (Event Sourcing)
- **NEventStore** — https://github.com/NEventStore — multi-backend .NET event store
- **Crypto-shredding** — GDPR-compliant event sourcing pattern (multiple blog references)
- **SysSkills cross-reference** — `event-driven-architecture-cqrs`, `ddd-fundamentals`,
  `modern-database-selection-strategy`, `observability-telemetry-strategy`
