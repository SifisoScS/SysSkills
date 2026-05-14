---
name: "Domain-Driven Design Fundamentals"
slug: ddd-fundamentals
category: "02-architecture-and-design"
proficiency: Architect
description: "Master the core principles, patterns, and practices of Domain-Driven Design to build software that accurately reflects complex business domains. Covers strategic DDD (Bounded Contexts, Context Mapping) and tactical DDD (Aggregates, Entities, Value Objects, Domain Events)."
tags: [ddd, domain-driven-design, bounded-context, aggregates, ubiquitous-language, event-storming, cqrs, context-mapping, hexagonal-architecture]
status: published
---

# Domain-Driven Design (DDD) Fundamentals

## Principles

**Ubiquitous Language**
A single, shared language used by both developers and domain experts in conversation, documentation, and code. If the business says "Order", the code says `Order` — not `OrderEntity`, `OrderDTO`, or `OrderRecord`. Divergence between the language of the code and the language of the business is the first sign a model is drifting from reality.

**The Domain Is the Center**
Business logic belongs in the domain model, not in services, controllers, or databases. Infrastructure (persistence, messaging, HTTP) exists to serve the domain — not the other way around. When infrastructure concerns bleed into domain objects, the model becomes impossible to reason about without understanding the whole stack.

**Bounded Contexts as Explicit Boundaries**
Every model is valid within a boundary. The same word ("Account") means different things in the Billing context and the User context. Making boundaries explicit prevents the accidental merging of models that should be kept separate, which is the primary cause of the Big Ball of Mud.

**Model the Domain, Not the Data**
A database table is not a domain model. Designing from the database up produces anemic models — objects with no behavior, just fields and getters. Start with what the domain *does*, not what it *stores*.

**Focus on the Core Domain**
Not all parts of the system deserve the same investment. The Core Domain is the competitive differentiator — the thing that makes the business unique. Supporting subdomains and Generic subdomains (authentication, billing, notifications) can use simpler patterns, off-the-shelf solutions, or be outsourced.

**Collaboration Over Isolation**
DDD is not a solo engineering activity. The model is discovered through sustained conversation between developers and domain experts (product owners, subject-matter experts, operations). A domain model built without domain experts is a guess.

---

## Implementation Patterns

### Strategic DDD

**Bounded Context**
A Bounded Context is the explicit boundary within which a domain model applies. Inside the boundary, the Ubiquitous Language is consistent. Across boundaries, translation is required.

Map your system's Bounded Contexts before writing any code. Each context should align with a team boundary, a deployment unit, or a distinct business capability.

**Context Mapping — Relationship Patterns**

| Pattern | Meaning | When to Use |
|---|---|---|
| Partnership | Two teams co-evolve their models together | Close collaboration, shared release cycle |
| Shared Kernel | Two contexts share a small subset of the model | High coupling acceptable; small, stable shared model |
| Customer-Supplier | Upstream supplies API to downstream; downstream has some influence | Different release cadences; downstream is a known consumer |
| Conformist | Downstream conforms to upstream's model with no negotiation power | Third-party APIs, legacy systems where you have no leverage |
| Anti-Corruption Layer (ACL) | Downstream translates upstream model into its own | Protecting your domain from a foreign or legacy model |
| Open Host Service | Upstream publishes a well-defined protocol for multiple consumers | Shared platform serving many teams |
| Published Language | A shared, well-documented language for integration | Cross-org integration, event schemas |
| Separate Ways | Contexts have no integration | Integration cost exceeds benefit |

**Subdomain Classification**

| Type | Description | Investment Level |
|---|---|---|
| Core Domain | What makes the business unique; competitive advantage | Highest — full DDD, best engineers |
| Supporting Subdomain | Needed but not differentiating | Medium — clean code, simpler patterns |
| Generic Subdomain | Commodity (auth, billing, email) | Low — buy or use open-source |

**Event Storming**
A collaborative workshop technique (Alberto Brandolini) for rapidly modelling a domain using sticky notes on a long wall.

*Big Picture Event Storming*: discover domain events, commands, actors, and system boundaries across the whole business.
*Process Level Event Storming*: zoom into a specific bounded context to model aggregates, policies, and read models.

Workshop flow: Domain Events (orange) → Commands (blue) → Aggregates (yellow) → Policies/Reactions (purple) → Read Models (green) → External Systems (pink).

### Tactical DDD

**Entity**
An object with a unique identity that persists over time. Identity matters more than attribute values. Two `Order` objects with the same items are not the same order if they have different IDs.

**Value Object**
An object defined entirely by its attributes. Has no identity. Two `Money(100, "USD")` objects are equal. Value Objects should be immutable — create a new one rather than mutating an existing one. Prefer Value Objects over primitive types for domain concepts (`Money`, `Email`, `DateRange`, `Coordinates`).

**Aggregate**
A cluster of Entities and Value Objects treated as a single unit for data changes. One Entity is the Aggregate Root — the only object external code is allowed to hold a reference to. All invariants within an Aggregate are enforced by the Root.

Rules:
- Reference other Aggregates by identity only, never by direct object reference
- One transaction modifies one Aggregate
- Keep Aggregates small — if a transaction always spans two Aggregates, reconsider the boundaries

**Domain Event**
A record that something significant happened in the domain. Named in past tense: `OrderPlaced`, `PaymentFailed`, `UserDeactivated`. Domain Events carry the data that happened; they are not commands. They enable loose coupling between Bounded Contexts and are the foundation for Event Sourcing and CQRS.

**Repository**
An abstraction over persistence for a specific Aggregate. Provides `FindById`, `Save`, and domain-specific query methods. The domain model never knows about the database — the Repository implementation does. One Repository per Aggregate Root.

**Domain Service**
Logic that doesn't naturally belong to any single Entity or Value Object. Stateless. Named as a verb or process: `FundsTransferService`, `PricingCalculator`. If a method takes two Aggregates and coordinates them, it's probably a Domain Service.

**Factory**
Encapsulates the creation logic for complex Aggregates or Entities. Keeps construction out of constructors and makes intent explicit: `Order.createForCustomer(customer, cart)`.

---

## Anti-Patterns

| Anti-Pattern | Why It's Harmful | Fix |
|---|---|---|
| Anemic Domain Model | Business logic scattered across services, utilities, and controllers; domain objects are just data bags | Move behaviour into Entities and Value Objects; enforce invariants in the Aggregate Root |
| God Entity / Massive Aggregate | An `Order` that contains `Customer`, `Payment`, `Shipping`, `Inventory`; every transaction locks the whole thing | Split by invariant boundary; reference other Aggregates by ID |
| Forcing DDD everywhere | CRUD screens for simple config data get full Aggregates, Repositories, and Domain Events — huge overhead for zero benefit | Apply tactical DDD only to the Core Domain; use Transaction Script or Active Record for simple subdomains |
| Ubiquitous Language only in code | The business says "claim" but the code says `PolicyEvent`; developers translate constantly in their heads | Drive language from domain experts; rename code ruthlessly when language drifts |
| Ignoring Context Boundaries | Two teams share a domain model; every change in one breaks the other; the model grows to serve everyone and serves no one | Draw explicit Bounded Context lines; choose a Context Map pattern for each relationship |
| Cross-Aggregate transactions | One database transaction spans three Aggregates to maintain consistency | Use eventual consistency and Domain Events; if truly inseparable, reconsider the Aggregate boundary |
| Repositories that return IQueryable | Persistence concerns leak into the domain; queries can be built anywhere | Return domain objects or typed query results only; no ORM query builders outside the infrastructure layer |

---

## Code Templates

### C# — Value Object Base Class

```csharp
public abstract class ValueObject
{
    protected abstract IEnumerable<object> GetEqualityComponents();

    public override bool Equals(object? obj)
    {
        if (obj is null || obj.GetType() != GetType()) return false;
        return ((ValueObject)obj).GetEqualityComponents()
            .SequenceEqual(GetEqualityComponents());
    }

    public override int GetHashCode() =>
        GetEqualityComponents().Aggregate(1, (hash, obj) =>
            HashCode.Combine(hash, obj?.GetHashCode() ?? 0));

    public static bool operator ==(ValueObject left, ValueObject right) =>
        left?.Equals(right) ?? right is null;

    public static bool operator !=(ValueObject left, ValueObject right) =>
        !(left == right);
}

// Usage
public sealed class Money : ValueObject
{
    public decimal Amount   { get; }
    public string  Currency { get; }

    public Money(decimal amount, string currency)
    {
        if (amount < 0)            throw new ArgumentException("Amount cannot be negative");
        if (string.IsNullOrEmpty(currency)) throw new ArgumentException("Currency required");
        Amount   = amount;
        Currency = currency.ToUpperInvariant();
    }

    public Money Add(Money other)
    {
        if (other.Currency != Currency) throw new InvalidOperationException("Currency mismatch");
        return new Money(Amount + other.Amount, Currency);
    }

    protected override IEnumerable<object> GetEqualityComponents()
    {
        yield return Amount;
        yield return Currency;
    }
}
```

### C# — Aggregate Root with Domain Events

```csharp
public abstract class AggregateRoot<TId>
{
    private readonly List<IDomainEvent> _domainEvents = new();

    public TId Id { get; protected set; } = default!;
    public IReadOnlyList<IDomainEvent> DomainEvents => _domainEvents.AsReadOnly();

    protected void Raise(IDomainEvent domainEvent) => _domainEvents.Add(domainEvent);
    public void ClearDomainEvents() => _domainEvents.Clear();
}

// Concrete Aggregate
public sealed class Order : AggregateRoot<OrderId>
{
    private readonly List<OrderLine> _lines = new();

    public CustomerId CustomerId { get; private set; }
    public OrderStatus Status    { get; private set; }
    public Money       Total     => _lines.Aggregate(new Money(0, "USD"), (s, l) => s.Add(l.LineTotal));

    private Order() { }

    public static Order Place(CustomerId customerId, IEnumerable<OrderLine> lines)
    {
        var order = new Order
        {
            Id         = OrderId.New(),
            CustomerId = customerId,
            Status     = OrderStatus.Pending,
        };
        foreach (var line in lines) order._lines.Add(line);

        order.Raise(new OrderPlaced(order.Id, order.CustomerId, order.Total));
        return order;
    }

    public void Cancel(string reason)
    {
        if (Status != OrderStatus.Pending)
            throw new InvalidOperationException("Only pending orders can be cancelled");
        Status = OrderStatus.Cancelled;
        Raise(new OrderCancelled(Id, reason));
    }
}
```

### TypeScript — Repository Interface (Hexagonal Port)

```typescript
// Domain port — no persistence technology visible
export interface OrderRepository {
    findById(id: OrderId): Promise<Order | null>;
    findByCustomer(customerId: CustomerId): Promise<Order[]>;
    save(order: Order): Promise<void>;
}

// Infrastructure adapter — PostgreSQL implementation
export class PostgresOrderRepository implements OrderRepository {
    constructor(private readonly db: Database) {}

    async findById(id: OrderId): Promise<Order | null> {
        const row = await this.db.query(
            'SELECT * FROM orders WHERE id = $1', [id.value]
        );
        return row ? OrderMapper.toDomain(row) : null;
    }

    async save(order: Order): Promise<void> {
        await this.db.query(
            `INSERT INTO orders (id, customer_id, status, total_amount, total_currency)
             VALUES ($1,$2,$3,$4,$5)
             ON CONFLICT (id) DO UPDATE SET status=$3`,
            [order.id.value, order.customerId.value, order.status,
             order.total.amount, order.total.currency]
        );
    }

    async findByCustomer(customerId: CustomerId): Promise<Order[]> {
        const rows = await this.db.query(
            'SELECT * FROM orders WHERE customer_id = $1', [customerId.value]
        );
        return rows.map(OrderMapper.toDomain);
    }
}
```

### Python — Domain Event and Simple Dispatcher

```python
from dataclasses import dataclass, field
from datetime import datetime
from typing import Callable
from uuid import UUID, uuid4

@dataclass(frozen=True)
class DomainEvent:
    event_id: UUID = field(default_factory=uuid4)
    occurred_at: datetime = field(default_factory=datetime.utcnow)

@dataclass(frozen=True)
class OrderPlaced(DomainEvent):
    order_id: UUID = field(default=None)
    customer_id: UUID = field(default=None)
    total_amount: float = field(default=0.0)
    currency: str = field(default="USD")

# Simple in-process event dispatcher
class DomainEventDispatcher:
    def __init__(self):
        self._handlers: dict[type, list[Callable]] = {}

    def register(self, event_type: type, handler: Callable) -> None:
        self._handlers.setdefault(event_type, []).append(handler)

    def dispatch(self, event: DomainEvent) -> None:
        for handler in self._handlers.get(type(event), []):
            handler(event)
```

---

## Decision Matrix

| Situation | Recommended Approach | Notes |
|---|---|---|
| Complex business logic with many rules | Rich Domain Model + Aggregates + Domain Services | Full tactical DDD pays off here |
| Simple CRUD screens (config, lookup data) | Transaction Script or Active Record | Full DDD is overkill; adds no value |
| Multiple teams on the same product | Separate Bounded Contexts + Context Map | Prevents model collisions; enables team autonomy |
| Integration with external / legacy system | Anti-Corruption Layer | Protects your model from foreign concepts |
| High write/read scalability needs | CQRS + Domain Events (+ Event Sourcing if audit trail needed) | Adds complexity; only justified at scale or with compliance requirements |
| Greenfield with uncertain domain | Event Storming first; model emerges from discovery | Resist upfront class design before domain is understood |
| Legacy rewrite | Identify Core Domain; extract Bounded Contexts using Strangler Fig | DDD provides the target model; strangler provides the migration path |

---

## Proficiency Levels

### Awareness
- Can explain Ubiquitous Language, Bounded Context, and the difference between an Entity and a Value Object.
- Understands why "anemic domain model" is an anti-pattern.
- Can read a Context Map and describe the relationship between two Bounded Contexts.

### Applied
- Implements Entities, Value Objects, Aggregates, Repositories, and Domain Events in a real codebase.
- Facilitates or participates in a Big Picture Event Storming workshop.
- Applies the Anti-Corruption Layer pattern when integrating with an external system.
- Structures code by Bounded Context (vertical slice, hexagonal architecture).

### Master
- Designs and evolves domain models across multiple Bounded Contexts with documented Context Maps.
- Applies strategic DDD: classifies subdomains, chooses context mapping patterns deliberately, manages upstream/downstream relationships.
- Combines DDD with CQRS and Domain Events for complex workflows.
- Identifies when DDD is and is not the right tool; uses simpler patterns for non-core subdomains.

### Architect
- Drives organization-wide DDD adoption: workshops, patterns, review standards, team structure alignment.
- Designs system boundaries so Bounded Contexts align with team topologies and deployment units.
- Makes pragmatic trade-offs between modeling purity and delivery pressure without losing model integrity.
- Uses DDD as the foundation for re-engineering decisions: extracting Bounded Contexts from legacy monoliths, identifying seams for the Strangler Fig pattern.

---

## AI Prompts

**Model a domain concept:**
> I'm building a system for [business domain]. The key concepts mentioned by the business are: [list terms]. Help me identify: which are Entities (need identity), which are Value Objects (defined by attributes), what the Aggregate boundaries should be, and what Domain Events would occur. State your assumptions.

**Review a domain model:**
> Review this domain model for DDD violations. Check: Is there an anemic domain model? Are Aggregate boundaries too large? Does the Ubiquitous Language match business terminology? Are Value Objects being used where primitive types are? [paste class/type definitions]

**Design a Context Map:**
> We have these teams and systems: [list contexts and their responsibilities]. Help me draw a Context Map. For each relationship, suggest the appropriate pattern (Partnership, ACL, Customer-Supplier, etc.) and explain why.

**Facilitate an Event Storming:**
> I need to run a Big Picture Event Storming for [business domain]. Give me: a step-by-step facilitation guide for a 3-hour workshop, what questions to ask to surface Domain Events, how to identify Bounded Context boundaries from the result, and common failure modes to watch for.

**Strangler Fig + DDD:**
> I have a legacy monolith that mixes [describe domains]. I want to extract [specific bounded context] as a separate service. Using DDD, help me: identify the Aggregate boundaries for the new context, define the Anti-Corruption Layer interface, and describe the data migration strategy.

---

## References

**Books (Essential)**
- Eric Evans — *Domain-Driven Design: Tackling Complexity in the Heart of Software* (Blue Book, 2003) — the foundational text
- Vaughn Vernon — *Implementing Domain-Driven Design* (Red Book, 2013) — practical patterns and code
- Vaughn Vernon — *Domain-Driven Design Distilled* (2016) — shorter entry point; start here if new to DDD
- Alberto Brandolini — *Introducing EventStorming* — the definitive Event Storming reference

**Online**
- [DDD Reference](https://www.domainlanguage.com/ddd/reference/) — Eric Evans' pattern summaries (free PDF)
- [Context Mapping Patterns](https://github.com/ddd-crew/context-mapping) — DDD Crew visual reference

**Related Skills**
- `02-architecture-and-design/c4-model` — visualize Bounded Contexts as containers; overlay context map relationships
- `02-architecture-and-design/architecture-decision-records` — document every significant modeling decision as an ADR
- `09-re-engineering-and-evolution/strangler-fig-pattern` — DDD provides the target model; Strangler Fig provides the migration path
- `04-backend-and-services/event-driven-architecture` — Domain Events are the foundation for event-driven and CQRS systems
