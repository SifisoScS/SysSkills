---
name: "Modular Monolith Architecture"
slug: modular-monolith
category: "02-architecture-and-design"
proficiency: Architect
description: "Design, implement, and evolve Modular Monoliths — a single deployable application with strong internal modular boundaries aligned to DDD Bounded Contexts. Delivers microservice-level modularity with significantly lower operational and cognitive complexity."
tags: [modular-monolith, architecture, vertical-slice, bounded-context, hexagonal-architecture, module-autonomy, feature-flags, ddd, clean-architecture, in-process-events]
status: published
---

# Modular Monolith Architecture

## Principles

**Strong Internal Boundaries Over Distribution**
The problems that microservices solve (team autonomy, independent deployment, technology flexibility) stem from enforced boundaries. Those boundaries can exist within a single process. Distribution should be chosen for the capabilities it adds — independent scaling, technology heterogeneity — not as a substitute for good design. A well-bounded monolith is almost always preferable to a poorly-bounded distributed system.

**Vertical Slice Over Horizontal Layer**
Organise code by business capability, not technical concern. A vertical slice owns everything from the HTTP handler to the database query for a specific feature. This aligns code ownership with team ownership, minimises cross-cutting changes, and makes features independently testable and deployable. Horizontal layers (Controllers, Services, Repositories as top-level folders) create coupling across business domains.

**Module Autonomy with Explicit Contracts**
A module is a Bounded Context expressed in code. It owns its data model, its internal logic, and its public interface. Other modules cannot reach inside — they can only call the module's public API (a facade, an event, or a well-typed interface). Enforcement of this boundary must be automatic, not cultural: use access modifiers, assembly boundaries, or package visibility to make accidental coupling a compile error.

**In-Process Before Out-of-Process**
Start with in-process event publication and direct method calls across module facades. Add distribution only when a specific module requires independent scaling, a different technology, or a separate deployment lifecycle. The modular monolith is the correct starting point; microservices are a later optimisation for specific modules that justify the operational cost.

**Single Deployable Until Distribution Is Justified**
One process means one deployment, one rollback, local method calls, ACID transactions across modules when needed, and a single observability context. These are significant advantages. Do not distribute until you have a specific, measured need that justifies the additional operational complexity.

**Coupling Is the Enemy; Measure It**
The defining characteristic of a good modular monolith is low coupling between modules and high cohesion within them. Track coupling over time: the number of cross-module dependencies, the frequency with which a change in one module requires a change in another. A module that everything depends on is a sign the boundary is in the wrong place.

---

## Implementation Patterns

### Pattern 1 — Module Structure (DDD Bounded Context as Module)

Each Bounded Context becomes a module with a strict internal structure:

```
src/
├── Ordering/                          ← Module = Bounded Context
│   ├── Ordering.Module.cs             ← module registration (DI, routes)
│   ├── API/                           ← public facade — the only entry point
│   │   └── OrderingFacade.cs
│   ├── Application/                   ← use cases / command+query handlers
│   │   ├── PlaceOrderCommand.cs
│   │   └── GetOrderSummaryQuery.cs
│   ├── Domain/                        ← Aggregates, Entities, Value Objects, Domain Events
│   │   ├── Order.cs
│   │   └── OrderPlaced.cs
│   └── Infrastructure/                ← persistence, external service adapters
│       ├── OrderRepository.cs
│       └── OrderDbContext.cs
│
├── Inventory/                         ← separate module, same pattern
├── Payments/
├── Notifications/
└── Shared/                            ← shared kernel (use sparingly)
    ├── SharedKernel/
    └── BuildingBlocks/
```

**Rules enforced at build time**:
- Modules never reference each other's internals — only the public `Facade`
- The `Domain` folder never references `Infrastructure` or `Application`
- `Shared/` contains only value types and abstractions that have no owner

### Pattern 2 — Vertical Slice Architecture Within a Module

Within each module, organise by feature, not by layer:

```
Ordering/
└── Application/
    ├── PlaceOrder/
    │   ├── PlaceOrderCommand.cs
    │   ├── PlaceOrderCommandHandler.cs
    │   ├── PlaceOrderValidator.cs
    │   └── PlaceOrderTests.cs          ← test lives with the feature
    ├── CancelOrder/
    │   ├── CancelOrderCommand.cs
    │   └── CancelOrderCommandHandler.cs
    └── GetOrderSummary/
        ├── GetOrderSummaryQuery.cs
        └── GetOrderSummaryHandler.cs
```

Each vertical slice is self-contained. Adding a new feature means adding a new folder — not modifying layers across the entire codebase.

### Pattern 3 — Module Facade (Public API)

The facade is the only surface other modules or the application shell can call:

```csharp
// Ordering/API/OrderingFacade.cs
public interface IOrderingFacade
{
    Task<OrderId>      PlaceOrder(PlaceOrderRequest request, CancellationToken ct);
    Task               CancelOrder(OrderId id, string reason, CancellationToken ct);
    Task<OrderSummary> GetOrderSummary(OrderId id, CancellationToken ct);
}

// Internal implementation — not visible outside the module
internal sealed class OrderingFacade : IOrderingFacade
{
    private readonly IMediator _mediator;
    public OrderingFacade(IMediator mediator) => _mediator = mediator;

    public Task<OrderId> PlaceOrder(PlaceOrderRequest req, CancellationToken ct) =>
        _mediator.Send(new PlaceOrderCommand(req.CustomerId, req.Lines), ct);

    public Task<OrderSummary> GetOrderSummary(OrderId id, CancellationToken ct) =>
        _mediator.Send(new GetOrderSummaryQuery(id), ct);
}
```

The `internal` keyword enforces the boundary at compile time. Only `IOrderingFacade` is `public`. No other module can instantiate or call `OrderingFacade` directly — only through the interface registered in DI.

### Pattern 4 — In-Process Event Bus for Module Integration

When Module A needs to react to something that happened in Module B without direct coupling:

```csharp
// Module B raises a domain event
public class Order : AggregateRoot<OrderId>
{
    public void Place(...)
    {
        // ...
        Raise(new OrderPlaced(Id, CustomerId, Total));
    }
}

// Module A subscribes without knowing about Module B's internals
public class InventoryEventHandler : INotificationHandler<OrderPlaced>
{
    public async Task Handle(OrderPlaced evt, CancellationToken ct)
    {
        await _inventory.ReserveStock(evt.OrderId, evt.Lines, ct);
    }
}
```

In-process events (MediatR `INotification`, or a simple event dispatcher) keep the integration synchronous and transactional. The same Unit of Work that commits the Order also dispatches the event — both succeed or both fail. No broker, no eventual consistency, no distributed transaction required.

Promote an in-process event to a broker-based event only when the subscribing module needs its own deployment lifecycle, its own scaling profile, or needs to span a process boundary.

### Pattern 5 — Module-Level Database Isolation

Each module owns its schema. Even in a single shared database, modules use separate schemas and never join across them:

```sql
-- Ordering module owns this schema
CREATE SCHEMA ordering;
CREATE TABLE ordering.orders (...);
CREATE TABLE ordering.order_lines (...);

-- Inventory module owns this schema — no foreign keys across schemas
CREATE SCHEMA inventory;
CREATE TABLE inventory.stock_reservations (...);
```

If a view of another module's data is needed for a query, it must go through the module's facade (API call) or be derived from events (projection). Direct cross-schema joins are prohibited — they are the persistence equivalent of accessing another module's internals.

When ready to extract a module to a separate service, the schema isolation means the data migration is a well-defined operation, not an archaeology exercise.

### Pattern 6 — Architecture Fitness Functions

Prevent boundary erosion over time with automated checks:

```csharp
// ArchUnit test (C#) — enforces module boundary rules
[Fact]
public void Modules_Should_Not_Reference_Each_Others_Internals()
{
    var result = Types.InAssembly(Assembly.GetAssembly(typeof(Startup)))
        .That().ResideInNamespace("Ordering")
        .ShouldNot().HaveDependencyOn("Inventory.Application")
        .And().ShouldNot().HaveDependencyOn("Inventory.Domain")
        .And().ShouldNot().HaveDependencyOn("Inventory.Infrastructure")
        .GetResult();

    result.IsSuccessful.Should().BeTrue();
}
```

These tests run in CI and fail the build if a developer accidentally adds a cross-module internal reference. The boundary is enforced by the pipeline, not by code reviews alone.

---

## Anti-Patterns

| Anti-Pattern | Why It's Harmful | Fix |
|---|---|---|
| Distributed Monolith | Modules are coupled but deployed separately; every change requires coordinating multiple deployments; failure cascades via synchronous network calls | Enforce loose coupling first; achieve modular monolith quality before distributing |
| Shared database across modules | Schema changes in one module break others; JOIN queries create hidden coupling; modules cannot evolve independently | Separate schema per module (same DB is fine); cross-module data access only through facade APIs or events |
| God Module | One module (often "Common" or "Core") that every other module depends on; changes to it ripple everywhere | Split by business capability; shared abstractions in `BuildingBlocks` should be small and stable value types only |
| Boundary erosion over time | Developers take shortcuts; internal classes become public; modules reference each other's internals; boundaries become fiction | Architecture fitness functions in CI enforce boundaries automatically |
| Using the Modular Monolith label to excuse poor design | No real module boundaries; code is grouped by name only; coupling is identical to a traditional monolith | The test is whether you can extract a module to a separate service in a single sprint without touching other modules |
| Premature extraction to microservices | Module is extracted before it has stable boundaries, stable APIs, or a justification for independent scaling | Stay modular monolith until a specific, measured need justifies distribution; modules with good boundaries extract cleanly when the time comes |

---

## Code Templates

### C# — Module Registration (ASP.NET Core)

```csharp
// Ordering/OrderingModule.cs
public static class OrderingModule
{
    public static IServiceCollection AddOrdering(
        this IServiceCollection services,
        IConfiguration config)
    {
        // Register module internals — all internal, invisible outside this call
        services.AddScoped<IOrderingFacade, OrderingFacade>();
        services.AddDbContext<OrderingDbContext>(opt =>
            opt.UseNpgsql(config.GetConnectionString("Ordering")));
        services.AddMediatR(cfg =>
            cfg.RegisterServicesFromAssembly(typeof(OrderingModule).Assembly));

        return services;
    }

    public static IEndpointRouteBuilder MapOrderingEndpoints(
        this IEndpointRouteBuilder routes)
    {
        var group = routes.MapGroup("/api/orders").RequireAuthorization();
        group.MapPost("/",    OrderingEndpoints.PlaceOrder);
        group.MapDelete("/{id}", OrderingEndpoints.CancelOrder);
        group.MapGet("/{id}", OrderingEndpoints.GetOrderSummary);
        return routes;
    }
}

// Program.cs — clean composition root
builder.Services
    .AddOrdering(builder.Configuration)
    .AddInventory(builder.Configuration)
    .AddPayments(builder.Configuration)
    .AddNotifications(builder.Configuration);

app.MapOrderingEndpoints()
   .MapInventoryEndpoints()
   .MapPaymentsEndpoints();
```

### TypeScript / Node.js — Module Barrel with Enforced Public API

```typescript
// src/ordering/index.ts  ← the ONLY public surface of this module
export type { OrderId, OrderSummary, PlaceOrderRequest } from './types';
export { OrderingFacade } from './OrderingFacade';

// Everything else in src/ordering/** is NOT exported — private by convention
// Enforce with ESLint import/no-restricted-paths rule:

// .eslintrc.js
module.exports = {
    rules: {
        'import/no-restricted-paths': ['error', {
            zones: [
                // Inventory cannot import from Ordering internals
                {
                    target: './src/inventory',
                    from: './src/ordering',
                    except: ['./index.ts'],
                    message: 'Import only from the ordering module public API (index.ts)',
                },
            ],
        }],
    },
};
```

### Python — Module Boundary via Package `__all__`

```python
# src/ordering/__init__.py  ← public API
from ordering._facade import OrderingFacade
from ordering._types  import OrderId, OrderSummary, PlaceOrderRequest

__all__ = ["OrderingFacade", "OrderId", "OrderSummary", "PlaceOrderRequest"]

# src/ordering/_facade.py  ← leading underscore = internal by convention
# src/ordering/_domain/  ← internal domain model
# src/ordering/_infra/   ← internal infrastructure
```

### ArchUnit — Go Module Boundary Test

```go
// architecture_test.go
func TestModuleBoundaries(t *testing.T) {
    pkgs, _ := packages.Load(&packages.Config{Mode: packages.NeedImports}, "./...")

    violations := []string{}
    for _, pkg := range pkgs {
        if strings.Contains(pkg.PkgPath, "ordering") {
            for imp := range pkg.Imports {
                // Ordering module must not import Inventory internals
                if strings.Contains(imp, "inventory/application") ||
                   strings.Contains(imp, "inventory/domain") ||
                   strings.Contains(imp, "inventory/infrastructure") {
                    violations = append(violations, fmt.Sprintf("%s imports %s", pkg.PkgPath, imp))
                }
            }
        }
    }

    if len(violations) > 0 {
        t.Fatalf("Module boundary violations:\n%s", strings.Join(violations, "\n"))
    }
}
```

---

## Decision Matrix

| Situation | Architecture | Rationale |
|---|---|---|
| Team ≤ 15, single domain | Modular Monolith | Best fit; simple deployment; full ACID; easy debugging |
| Team > 50, multiple domains, independent release cadences | Microservices (selectively) | Distribution justified by team topology and release independence |
| Complex domain, regulatory requirements | Modular Monolith | Easier auditing, ACID transactions, simpler compliance posture |
| Rapid feature iteration, frequent releases | Modular Monolith + feature flags | Deploy once; release incrementally per module |
| Legacy strangler fig target state | Modular Monolith | Extract one module at a time into a well-bounded monolith; distribute later only if needed |
| Startup / MVP | Monolith (modular from day one) | Avoid premature complexity; build with module structure but don't enforce it rigidly until you understand the domain |
| Extreme independent scaling per capability | Microservices for that specific module | Extract only the module that requires different scaling; keep everything else in the monolith |

---

## Proficiency Levels

### Awareness
- Can explain the differences between a traditional monolith, a modular monolith, a distributed monolith, and microservices.
- Understands what vertical slice architecture means and how it differs from horizontal layering.
- Can name the characteristics of a good module boundary.

### Applied
- Refactors an existing layered monolith into modules with explicit facades and vertical slices.
- Implements in-process event bus for cross-module integration.
- Enforces module boundaries with access modifiers, package visibility, or ESLint/ArchUnit rules.
- Applies separate schema-per-module in a shared database.

### Master
- Designs a full Modular Monolith with DDD Bounded Contexts as modules from scratch.
- Implements architecture fitness functions that enforce module boundaries in CI.
- Designs the transition from Modular Monolith to selective microservice extraction when justified.
- Combines vertical slices, CQRS within modules, and in-process events into a coherent design.

### Architect
- Decides when Modular Monolith is the correct target state for a Strangler Fig migration vs selective microservices vs staying modular.
- Designs the module decomposition strategy: identifies correct Bounded Context boundaries, shared kernel scope, and module ownership per team.
- Establishes module coupling metrics and architecture governance to prevent boundary erosion over time.
- Coaches teams on the difference between a well-designed Modular Monolith and a distributed monolith in disguise.

---

## AI Prompts

**Design a modular structure:**
> I have a [domain description] system currently structured as a traditional layered monolith. Identify the Bounded Contexts, design a module structure, define the public facade interface for each module, and describe the in-process event flows between modules. Map each module to a team if possible.

**Review a module for boundary violations:**
> Review this module structure for boundary violations and coupling problems. Check: Are internal types leaking through the public API? Do modules reference each other's internals? Is there a shared database or cross-schema join? Is there a God Module everything depends on? [paste folder structure and dependency list]

**Design an in-process event flow:**
> Module A needs to react when Module B completes [action]. Design the in-process event flow: the domain event payload, the subscription handler in Module A, and how the Unit of Work ensures both the domain change and the handler run in the same transaction.

**Plan a Strangler Fig to Modular Monolith:**
> I have a legacy monolith described as: [describe]. I want to migrate it to a Modular Monolith as the target state. Design the migration plan: which Bounded Contexts to extract first, what the module facades should look like, how to enforce module boundaries during the transition, and when (if ever) individual modules should be extracted to separate services.

**Write architecture fitness functions:**
> Write architecture fitness function tests (ArchUnit or equivalent for [C#/Java/TypeScript/Go]) that enforce these module boundary rules for this module structure: [describe modules and allowed dependencies]. Tests should fail the build if a developer adds a cross-module internal reference.

---

## References

**Books**
- Sam Newman — *Monolith to Microservices* (O'Reilly, 2019) — Chapter 2 covers Modular Monolith as a migration target and an end state
- Eric Evans — *Domain-Driven Design* (2003) — Bounded Contexts as the conceptual foundation for module boundaries
- Robert C. Martin — *Clean Architecture* (2017) — component cohesion, coupling, and the rationale for strict internal boundaries

**Articles & Talks**
- Simon Brown — [Modular Monoliths](https://www.youtube.com/watch?v=5OjqD-ow8GE) (GOTO 2018) — definitive talk; watch before implementing
- Martin Fowler — [MonolithFirst](https://martinfowler.com/bliki/MonolithFirst.html)
- Kamil Grzybek — [Modular Monolith: A Primer](https://www.kamilgrzybek.com/design/modular-monolith-primer/)

**Reference Implementations**
- [Modular Monolith with DDD (C#)](https://github.com/kgrzybek/modular-monolith-with-ddd) — Kamil Grzybek's full reference implementation

**Related Skills**
- `02-architecture-and-design/ddd-fundamentals` — Bounded Contexts define module boundaries
- `02-architecture-and-design/event-driven-architecture-cqrs` — CQRS within modules; in-process events between modules
- `02-architecture-and-design/architecture-decision-records` — document the decision to use Modular Monolith and each module boundary choice
- `09-re-engineering-and-evolution/strangler-fig-legacy-modernization` — Modular Monolith is the ideal Strangler Fig target state for most systems
