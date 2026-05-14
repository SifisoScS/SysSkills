---
name: "Event-Driven Architecture & CQRS"
slug: event-driven-architecture-cqrs
category: "02-architecture-and-design"
proficiency: Architect
description: "Master Event-Driven Architecture (EDA), Command Query Responsibility Segregation (CQRS), and Event Sourcing (ES) to build loosely coupled, scalable, and auditable systems that evolve gracefully over time."
tags: [event-driven, cqrs, event-sourcing, saga, outbox-pattern, kafka, rabbitmq, choreography, orchestration, domain-events, eventual-consistency]
status: published
---

# Event-Driven Architecture & CQRS

## Principles

**Commands, Events, and Queries Are Fundamentally Different**
A Command expresses intent: "place this order". An Event records what happened: "order was placed". A Query asks without side effects: "what is the status of order 42". Conflating these three leads to systems where reads trigger writes, state changes are implicit, and reasoning about flow becomes impossible.

**Events Are Immutable Facts**
An event records something that happened in the domain. It cannot be undone, edited, or deleted. To correct a past event, you raise a compensating event. Treating events as mutable destroys the audit trail and breaks consumers that have already processed the original.

**Eventual Consistency Is a Feature**
In a distributed system, insisting on immediate consistency across service boundaries requires distributed transactions — which are slow, fragile, and prone to deadlock. Accepting eventual consistency enables independent scaling, deployment, and failure isolation. Design the UX and business rules to accommodate it rather than fighting it.

**Idempotency Is Non-Negotiable**
Message brokers guarantee at-least-once delivery. Every event consumer must be idempotent: processing the same event twice must produce the same result as processing it once. Use idempotency keys, deduplication tables, or conditional upserts.

**Decouple by Event, Not by API Call**
When Service A calls Service B synchronously, A is coupled to B's availability. When A publishes an event and B reacts to it, A doesn't know B exists. This is the fundamental coupling reduction that makes large systems maintainable. However, choreography without discipline produces invisible distributed logic — trace it, document it, test it.

**The Outbox Pattern Is Required for Reliable Publishing**
Writing to a database and publishing to a broker in a single operation without a distributed transaction means one can succeed and the other can fail. The Outbox pattern solves this by writing the event to a local outbox table in the same transaction as the domain change, then having a relay process publish from the outbox.

---

## Implementation Patterns

### Pattern 1 — CQRS (Command Query Responsibility Segregation)

Separate the write model (Commands → Aggregates → Events) from the read model (Queries → Projections → Read-optimized views).

```
Write side:  Command → Command Handler → Aggregate → Domain Event → Event Store / DB
Read side:   Query  → Query Handler  → Read Model (projection) → Response
```

**Simple CQRS** (single database, separated handlers): command handlers write via the domain model; query handlers read directly from a read-optimized schema or view. No separate data store needed. Appropriate for most applications.

**Advanced CQRS** (separate read store): the read model is a projection maintained by consuming domain events. The read store (Redis, Elasticsearch, denormalized SQL view) is optimized purely for query performance. Appropriate when read and write load profiles diverge significantly.

### Pattern 2 — Event Sourcing

Instead of storing current state, store the sequence of events that produced it. Current state is derived by replaying events. The event log is the source of truth.

```
Aggregate.Apply(OrderPlaced)   → state: Pending
Aggregate.Apply(OrderShipped)  → state: Shipped
Aggregate.Apply(OrderDelivered)→ state: Delivered
```

**When to use**: audit requirements (finance, health, legal), complex domain with event-driven workflows, need for temporal queries ("what was the state at time T?"), CQRS with multiple read model projections from the same event stream.

**Snapshotting**: replay from the beginning is slow for long-lived aggregates. Periodically store a snapshot of the current state and replay only events after the snapshot.

**Event versioning**: events must be versioned when their schema changes. Strategies: upcasting (transform old events to new format on read), versioned event types (`OrderPlacedV2`), additive-only changes (never remove fields).

### Pattern 3 — Outbox Pattern

Guarantees at-least-once event publishing without distributed transactions.

```
Transaction:
  1. Write domain change to domain table
  2. Write event to outbox table (same transaction)
  → both commit or both roll back

Background relay (Debezium CDC or polling):
  3. Read unpublished events from outbox
  4. Publish to message broker
  5. Mark as published
```

Use Debezium (Change Data Capture) on PostgreSQL/MySQL for zero-polling-latency relay. Use a polling relay when CDC infrastructure is unavailable.

### Pattern 4 — Choreography vs Orchestration (Saga Pattern)

For long-running, multi-step business processes that span Bounded Contexts:

**Choreography**: each service reacts to events and emits its own events. No central coordinator. Decoupled but invisible — the flow is distributed across many services.

```
OrderPlaced → InventoryReserved → PaymentProcessed → ShipmentScheduled
                                 ↓ (on failure)
                          PaymentFailed → InventoryReleased
```

**Orchestration (Saga Orchestrator)**: a dedicated process issues commands and reacts to events, coordinating the workflow. The flow is explicit and testable.

```
OrderSaga:
  1. Send ReserveInventory → receive InventoryReserved
  2. Send ProcessPayment  → receive PaymentProcessed
  3. Send ScheduleShipment → receive ShipmentScheduled
  Compensation: on PaymentFailed → Send ReleaseInventory
```

Use choreography for simple, stable flows. Use orchestration for complex flows with multiple compensation paths, where visibility and testability matter.

### Pattern 5 — Event Notification vs Event-Carried State Transfer

**Event Notification**: the event signals that something happened; consumers query back for details if needed. Minimal coupling on event schema; higher query load.

**Event-Carried State Transfer**: the event contains all the data consumers need. Consumers never need to query back. Higher event payload; consumers are more autonomous; avoid tight read coupling.

Choose Event-Carried State Transfer when consumers are in different Bounded Contexts or services. Choose Event Notification when the domain data is sensitive, large, or changes frequently between event publish and consumer read.

---

## Anti-Patterns

| Anti-Pattern | Why It's Harmful | Fix |
|---|---|---|
| Distributed Monolith | Services communicate synchronously for every operation; EDA is cosmetic; failure cascades exactly as in a monolith | Replace synchronous chains with event reactions; accept eventual consistency |
| Event Storms | Every property change emits an event; consumers are overwhelmed; event schema becomes a dump of internal state | Emit only business-meaningful events that domain experts would name |
| Missing Outbox Pattern | Service writes to DB and publishes to broker separately; on crash between the two, events are lost or duplicated inconsistently | Always use the Outbox pattern or a transactional messaging library |
| Mutable Events | Events are edited after publication to fix data errors | Events are immutable facts; issue compensating events; version the schema |
| No Event Versioning Strategy | Schema change breaks all existing consumers | Adopt additive-only changes or upcasting from day one; version event types |
| Overusing Event Sourcing | Every aggregate in the system uses Event Sourcing including simple config entities | Apply Event Sourcing only to aggregates where audit history or temporal queries are required |
| Choreography without tracing | Complex multi-step flow is split across 8 services; when it breaks nobody can follow the thread | Instrument every event with a correlation ID; use distributed tracing (OpenTelemetry) |
| God Event | One `SystemStateChanged` event carries everything; consumers conditionally check fields to decide whether to react | Each event has a single, named business meaning |

---

## Code Templates

### C# — Command, Event, and CQRS Handlers (MediatR style)

```csharp
// Command (write side — intent)
public record PlaceOrderCommand(CustomerId CustomerId, IReadOnlyList<OrderLineDto> Lines)
    : ICommand<OrderId>;

// Domain Event (immutable fact)
public record OrderPlaced(
    OrderId    OrderId,
    CustomerId CustomerId,
    Money      Total,
    DateTime   OccurredOn) : IDomainEvent;

// Command Handler
public class PlaceOrderCommandHandler : ICommandHandler<PlaceOrderCommand, OrderId>
{
    private readonly IOrderRepository _orders;
    private readonly IUnitOfWork      _uow;

    public PlaceOrderCommandHandler(IOrderRepository orders, IUnitOfWork uow)
        => (_orders, _uow) = (orders, uow);

    public async Task<OrderId> Handle(PlaceOrderCommand cmd, CancellationToken ct)
    {
        var lines = cmd.Lines.Select(l => OrderLine.Create(l.ProductId, l.Qty, l.UnitPrice));
        var order = Order.Place(cmd.CustomerId, lines);
        await _orders.Save(order, ct);
        await _uow.Commit(ct);          // Outbox events committed in same transaction
        return order.Id;
    }
}

// Query Handler (read side — no domain model, direct projection read)
public record GetOrderSummaryQuery(OrderId OrderId) : IQuery<OrderSummaryDto>;

public class GetOrderSummaryHandler : IQueryHandler<GetOrderSummaryQuery, OrderSummaryDto>
{
    private readonly IReadDb _db;
    public GetOrderSummaryHandler(IReadDb db) => _db = db;

    public async Task<OrderSummaryDto> Handle(GetOrderSummaryQuery q, CancellationToken ct) =>
        await _db.QuerySingleAsync<OrderSummaryDto>(
            "SELECT * FROM order_summaries WHERE id = @id", new { id = q.OrderId.Value }, ct)
        ?? throw new NotFoundException(q.OrderId);
}
```

### C# — Outbox Pattern (EF Core)

```csharp
// 1. Outbox table entity
public class OutboxMessage
{
    public Guid     Id          { get; init; } = Guid.NewGuid();
    public string   Type        { get; init; } = string.Empty;
    public string   Payload     { get; init; } = string.Empty;
    public DateTime CreatedAt   { get; init; } = DateTime.UtcNow;
    public DateTime? ProcessedAt { get; set; }
}

// 2. UnitOfWork intercepts domain events and writes to outbox in the same transaction
public class UnitOfWork : IUnitOfWork
{
    private readonly AppDbContext   _ctx;
    private readonly IEventSerializer _serializer;

    public async Task Commit(CancellationToken ct)
    {
        var events = _ctx.ChangeTracker.Entries<AggregateRoot>()
            .SelectMany(e => e.Entity.DomainEvents)
            .ToList();

        foreach (var evt in events)
            _ctx.Set<OutboxMessage>().Add(new OutboxMessage
            {
                Type    = evt.GetType().FullName!,
                Payload = _serializer.Serialize(evt),
            });

        foreach (var agg in _ctx.ChangeTracker.Entries<AggregateRoot>())
            agg.Entity.ClearDomainEvents();

        await _ctx.SaveChangesAsync(ct);   // domain + outbox in one transaction
    }
}

// 3. Background relay publishes outbox messages to the broker
public class OutboxRelay : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            var pending = await _db.Set<OutboxMessage>()
                .Where(m => m.ProcessedAt == null)
                .OrderBy(m => m.CreatedAt)
                .Take(50)
                .ToListAsync(ct);

            foreach (var msg in pending)
            {
                await _broker.PublishAsync(msg.Type, msg.Payload, ct);
                msg.ProcessedAt = DateTime.UtcNow;
            }

            await _db.SaveChangesAsync(ct);
            await Task.Delay(TimeSpan.FromSeconds(2), ct);
        }
    }
}
```

### TypeScript — Event Sourcing Aggregate

```typescript
type OrderEvent = OrderPlaced | OrderShipped | OrderCancelled;

interface OrderPlaced  { type: 'OrderPlaced';  orderId: string; customerId: string; total: number }
interface OrderShipped { type: 'OrderShipped'; orderId: string; trackingRef: string }
interface OrderCancelled { type: 'OrderCancelled'; orderId: string; reason: string }

class Order {
    private _id!: string;
    private _status!: 'Pending' | 'Shipped' | 'Cancelled';
    private _version = 0;
    private _uncommitted: OrderEvent[] = [];

    static reconstitute(events: OrderEvent[]): Order {
        const order = new Order();
        events.forEach(e => order.apply(e));
        return order;
    }

    static place(orderId: string, customerId: string, total: number): Order {
        const order = new Order();
        order.raise({ type: 'OrderPlaced', orderId, customerId, total });
        return order;
    }

    ship(trackingRef: string): void {
        if (this._status !== 'Pending') throw new Error('Only pending orders can be shipped');
        this.raise({ type: 'OrderShipped', orderId: this._id, trackingRef });
    }

    get uncommittedEvents(): OrderEvent[] { return [...this._uncommitted]; }
    get version(): number { return this._version; }

    markCommitted(): void { this._uncommitted = []; }

    private raise(event: OrderEvent): void {
        this.apply(event);
        this._uncommitted.push(event);
    }

    private apply(event: OrderEvent): void {
        this._version++;
        switch (event.type) {
            case 'OrderPlaced':   this._id = event.orderId; this._status = 'Pending';    break;
            case 'OrderShipped':  this._status = 'Shipped';                              break;
            case 'OrderCancelled':this._status = 'Cancelled';                            break;
        }
    }
}
```

### Kafka — Producer / Consumer (Go)

```go
// Producer — publish domain event
func PublishOrderPlaced(producer *kafka.Producer, event OrderPlaced) error {
    payload, err := json.Marshal(event)
    if err != nil {
        return err
    }
    return producer.Produce(&kafka.Message{
        TopicPartition: kafka.TopicPartition{Topic: &ordersTopic, Partition: kafka.PartitionAny},
        Key:            []byte(event.OrderID),   // key = aggregate ID → ordering per aggregate
        Value:          payload,
        Headers: []kafka.Header{
            {Key: "event-type",    Value: []byte("OrderPlaced")},
            {Key: "event-version", Value: []byte("1")},
            {Key: "correlation-id",Value: []byte(event.CorrelationID)},
        },
    }, nil)
}

// Consumer — idempotent handler
func handleOrderPlaced(ctx context.Context, msg *kafka.Message, db *sql.DB) error {
    var event OrderPlaced
    if err := json.Unmarshal(msg.Value, &event); err != nil {
        return err
    }
    _, err := db.ExecContext(ctx, `
        INSERT INTO processed_events (event_id) VALUES ($1)
        ON CONFLICT DO NOTHING`,  // idempotency guard
        event.EventID,
    )
    if err != nil {
        return err  // duplicate → skip downstream processing
    }
    return processOrder(ctx, event, db)
}
```

---

## Decision Matrix

| Scenario | Recommended Approach | Avoid |
|---|---|---|
| Simple CRUD, low complexity | Traditional layered architecture | Full CQRS + ES adds no value |
| Complex write logic, simple reads | CQRS with shared database, separate handlers | Separate read store is premature |
| Read load much higher than write | CQRS with dedicated read model (Redis / Elasticsearch) | Single model under query pressure |
| Full audit trail required | Event Sourcing | Append-only event log with snapshots |
| Long-running cross-context workflow | Saga (orchestration for complex, choreography for simple) | Synchronous chain across services |
| Reliable event publishing | Outbox Pattern + CDC relay (Debezium) | Fire-and-forget publish |
| Real-time UI updates | EDA + WebSocket/SSE subscription to projections | Polling every second |
| High-throughput ordered streams | Kafka (partition by aggregate ID) | RabbitMQ for strict ordering at scale |

---

## Proficiency Levels

### Awareness
- Can explain the difference between a Command, an Event, and a Query.
- Understands the basic CQRS split: write side vs read side.
- Knows what eventual consistency means and can give an example of where it is acceptable.

### Applied
- Implements CQRS with a shared database in a bounded context.
- Publishes and consumes domain events using a message broker (Kafka, RabbitMQ, or Azure Service Bus).
- Implements the Outbox pattern to guarantee event delivery.
- Writes idempotent event consumers with deduplication.

### Master
- Designs complex event-driven flows with explicit Saga patterns (choreography and orchestration).
- Implements Event Sourcing with snapshotting and event versioning/upcasting.
- Instruments event flows with distributed tracing (OpenTelemetry correlation IDs).
- Identifies when CQRS and Event Sourcing add value vs when they add unnecessary complexity.

### Architect
- Designs enterprise-grade EDA platforms: topic design, consumer group strategy, dead-letter queues, ordering guarantees, and schema registry (Avro/Protobuf).
- Defines event versioning governance across teams.
- Makes pragmatic trade-offs between synchronous and event-driven styles based on consistency, latency, and operational complexity requirements.
- Combines EDA with DDD, CQRS, and Event Sourcing as a coherent architectural style for the Core Domain.

---

## AI Prompts

**Design an event-driven flow:**
> Design an event-driven workflow for this business process: [describe process spanning multiple services]. Produce: a list of Domain Events with their payloads, a sequence diagram showing the flow, which services are producers and consumers, and whether choreography or an orchestrated Saga is more appropriate.

**Review an EDA design:**
> Review this event-driven architecture design for anti-patterns. Check: Are events named as past-tense business facts? Is the Outbox pattern used for publishing? Are consumers idempotent? Is there a correlation ID strategy? Are there any synchronous call chains disguised as events? [paste design or diagram]

**Choose a message broker:**
> Compare Kafka vs RabbitMQ vs Azure Service Bus for this use case: [describe throughput, ordering requirements, consumer count, cloud environment]. Recommend one with justification and flag any trade-offs.

**Design CQRS read models:**
> I have this write model: [describe aggregates and events]. Design the read models (projections) needed to support these queries: [list queries]. For each read model: suggest the storage technology, the projection logic from events, and how to handle eventual consistency in the UI.

**Debug a lost event:**
> My event-driven system is losing events intermittently. The producer writes to PostgreSQL and then publishes to Kafka. Help me: identify the most likely failure points, explain how the Outbox pattern would fix this, and outline the Debezium CDC setup required.

---

## References

**Books**
- Adam Bellemare — *Building Event-Driven Microservices* (O'Reilly, 2020)
- Vaughn Vernon — *Implementing Domain-Driven Design* — Chapters on Domain Events and CQRS
- Chris Richardson — *Microservices Patterns* (Manning, 2018) — Saga, Outbox, CQRS patterns

**Articles**
- Martin Fowler — [CQRS](https://martinfowler.com/bliki/CQRS.html)
- Martin Fowler — [Event Sourcing](https://martinfowler.com/eaaDev/EventSourcing.html)
- Udi Dahan — [Clarified CQRS](https://udidahan.com/2009/12/09/clarified-cqrs/)
- Chris Richardson — [Pattern: Saga](https://microservices.io/patterns/data/saga.html)
- Chris Richardson — [Pattern: Transactional Outbox](https://microservices.io/patterns/data/transactional-outbox.html)

**Tooling**
- [Apache Kafka](https://kafka.apache.org/) — high-throughput distributed event streaming
- [Debezium](https://debezium.io/) — CDC-based Outbox relay for PostgreSQL/MySQL
- [EventStoreDB](https://www.eventstore.com/) — purpose-built Event Sourcing database
- [MassTransit](https://masstransit.io/) — .NET message bus with built-in Saga and Outbox support

**Related Skills**
- `02-architecture-and-design/ddd-fundamentals` — Domain Events are the origin of the event stream
- `02-architecture-and-design/architecture-decision-records` — document the decision to adopt EDA and CQRS as an ADR
- `09-re-engineering-and-evolution/strangler-fig-pattern` — EDA enables incremental migration; events decouple legacy from new services
- `05-data-and-persistence/event-sourcing-and-projections` — persistence patterns for Event Sourcing stores and read model projections
