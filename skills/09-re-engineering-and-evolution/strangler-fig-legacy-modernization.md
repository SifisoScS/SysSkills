---
name: "Strangler Fig Pattern & Legacy Re-engineering Playbook"
slug: strangler-fig-legacy-modernization
category: "09-re-engineering-and-evolution"
proficiency: Architect
description: "Master the Strangler Fig pattern and a complete playbook for safely modernizing legacy systems into modern architectures without big-bang rewrites. Covers incremental extraction, Branch by Abstraction, Dual Write, Feature Flags, and data migration strategies."
tags: [strangler-fig, legacy-modernization, re-engineering, branch-by-abstraction, dual-write, feature-flags, cdc, anti-corruption-layer, migration, monolith-to-microservices]
status: published
---

# Strangler Fig Pattern & Legacy Re-engineering Playbook

## Principles

**Incremental Replacement Over Big Bang**
A big-bang rewrite is the highest-risk strategy available. It freezes feature development on the legacy system, delivers no business value for months or years, and frequently fails when the new system reaches the complexity of the old one. The Strangler Fig replaces the legacy system piece by piece while it continues to run and deliver value.

**Keep the System Working at All Times**
Every migration step must leave the system in a deployable, working state. A migration that breaks production — even temporarily — destroys trust and kills the modernization programme. Design every step so it can be deployed independently and rolled back within minutes.

**Prefer Reversible Changes**
Move traffic gradually. Write to both systems before committing to the new one. Use feature flags to control exposure. If the new system misbehaves, the rollback path must be a configuration change, not an emergency deployment.

**Strangle, Don't Rip Out**
The legacy system is decommissioned by progressively routing its responsibilities to the new system, not by deleting it first and rebuilding later. The strangler layer (facade, proxy, or API gateway) intercepts requests and decides — based on feature flags or routing rules — whether to forward to legacy or new.

**Measure Progress by Business Value Delivered**
Lines of code deleted, services extracted, and endpoints migrated are vanity metrics. Progress is measured by business capabilities running on the new platform, reduction in incident rate, improvement in deployment frequency, and reduction in time-to-change for the migrated domains.

**Organizational Change Is Half the Work**
Legacy systems survive because of processes, knowledge, and team structures built around them. A technical migration without addressing team ownership, deployment practices, and on-call responsibilities will produce a new system with legacy operational patterns.

---

## Implementation Patterns

### Pattern 1 — Strangler Fig (Core)

Named after the strangler fig tree that grows around a host tree and eventually replaces it. The legacy system is the host; the new system grows around it until the host can be removed.

```
Phase 1: Intercept
  Client → Strangler Proxy → Legacy System
  (proxy passes all traffic through; no behaviour change)

Phase 2: Divert (per bounded context)
  Client → Strangler Proxy → [new-service if feature X] OR [Legacy]

Phase 3: Eliminate
  Client → New System (legacy decommissioned for that context)
```

The strangler proxy can be an API Gateway (Kong, AWS API Gateway, NGINX), a Backend for Frontend (BFF), or a thin routing layer you control. It must add negligible latency and be independently deployable.

### Pattern 2 — Branch by Abstraction

When the legacy behaviour is deeply embedded in the codebase (not behind a clear interface), Branch by Abstraction creates the interface first, then migrates the implementation behind it.

```
Step 1: Identify the dependency to replace (e.g. legacy payment processor)
Step 2: Extract an interface/abstraction in front of the current implementation
Step 3: All callers now depend on the abstraction, not the concrete legacy class
Step 4: Build the new implementation behind the same interface
Step 5: Use a feature flag to route calls to old or new implementation
Step 6: Validate new implementation in production under traffic
Step 7: Remove the legacy implementation and the flag
```

This is the internal-code equivalent of Strangler Fig. Use it when you cannot introduce an external proxy layer.

### Pattern 3 — Dual Write with CDC-Based Synchronisation

When the new service needs its own data store but data must remain consistent during transition:

```
Write Path (transition period):
  Command → new service (writes to new DB)
           → also writes to legacy DB (dual write)
           OR
  Debezium CDC on legacy DB → event stream → new DB projection

Read Path:
  Feature flag:
    if new_service_reads_enabled → query new DB
    else                         → query legacy DB
```

Dual write introduces the risk of divergence if one write fails. Prefer CDC (Debezium on PostgreSQL/MySQL) for the legacy→new sync direction: it reads the legacy DB's transaction log and streams changes as events, avoiding coupling new service writes to legacy availability.

### Pattern 4 — Feature Flags for Traffic Migration

Feature flags control the percentage of traffic routed to the new system, enabling gradual rollout and instant rollback without deployment.

```
0%  → legacy only      (validation in dev/staging)
5%  → canary           (small production exposure)
25% → early majority   (monitor error rates, latency)
50% → parity check     (compare responses old vs new)
100%→ full cutover
```

Use shadow mode (run both, compare responses, discard new result) before any live traffic moves. Flag off = instant rollback.

### Pattern 5 — Event Interception

For event-driven legacy systems, intercept domain events at the message broker level to feed the new service without modifying the legacy producer.

```
Legacy System → publishes OrderCreated → broker
New Service   ← subscribes to OrderCreated ← broker
                (builds its own read model / reacts independently)
```

The legacy system is unaware the new service exists. The new service bootstraps by replaying historical events (if available) or by a one-time data migration.

### Pattern 6 — The Full Modernization Playbook (7 Phases)

**Phase 1 — Assess**: document the current system with C4 diagrams. Identify pain points, coupling hotspots, and business capabilities. Classify subdomains (Core / Supporting / Generic). Create an ADR capturing the decision to modernize and the chosen approach.

**Phase 2 — Define Target Architecture**: design the target state using DDD Bounded Contexts, C4 container diagram, and Event-Driven integration patterns. Do not attempt to design the full target before starting — the target evolves.

**Phase 3 — Prioritise Extraction Order**: extract the least coupled, highest-value, or most painful context first. Quick wins build team confidence and demonstrate the approach to stakeholders.

**Phase 4 — Build the Strangler Layer**: introduce the proxy/facade. Validate it adds no unacceptable latency. Deploy it routing 100% to legacy (no behaviour change).

**Phase 5 — Incremental Migration**: extract one Bounded Context at a time. For each:
- Build new service with its own data store
- Implement Dual Write or CDC sync
- Shadow mode → canary → full cutover
- Write ADR documenting the migration decision
- Decommission legacy code path after stability period

**Phase 6 — Data Migration**: migrate historical data to the new store. Use a one-time migration script for reference data; use event replay or CDC for transactional data. Validate consistency before cutting reads.

**Phase 7 — Cutover and Decommission**: remove dual-write paths, kill legacy endpoints, drop legacy tables. The strangler layer is removed once nothing routes through it.

---

## Anti-Patterns

| Anti-Pattern | Why It's Harmful | Fix |
|---|---|---|
| Big-bang rewrite | Freezes feature development; delivers zero value during the rewrite; frequently fails at the integration phase | Strangler Fig: replace incrementally while the legacy system stays live |
| Leaving the strangler layer forever | The proxy becomes a permanent dependency with its own bugs, latency, and maintenance burden | Each extracted context removes its routing rule; decommission the proxy when empty |
| Ignoring data consistency during transition | Dual write divergence; new service sees stale data; customers see inconsistent state | Use CDC (Debezium) for legacy→new sync; validate parity before moving reads |
| Extracting the wrong context first | Starting with the most complex, most coupled context; the migration stalls and loses stakeholder support | Start with the least coupled, most painful, or most independently deployable context |
| No rollback plan | Migration step goes wrong in production; rollback requires emergency deployment and hours of downtime | Feature flags make rollback a configuration change; every step is independently deployable |
| Underestimating organizational change | Technical migration succeeds but the team still owns and operates the legacy system alongside the new one | Migrate team ownership, on-call, and deployment practices alongside the code |
| Rebuilding the legacy design | The new service replicates the same coupling, data model, and responsibilities as the legacy code | Use DDD to design the correct Bounded Context boundary; the migration is an opportunity to fix the model |

---

## Code Templates

### Feature Flag — Routing Between Legacy and New Service (Go)

```go
// flags/flags.go
type Flags interface {
    IsEnabled(flag string, userID string) bool
}

// router/order_router.go
func (r *OrderRouter) CreateOrder(ctx context.Context, cmd CreateOrderCmd) (*Order, error) {
    if r.flags.IsEnabled("new-order-service", cmd.UserID) {
        return r.newOrderService.Create(ctx, cmd)
    }
    return r.legacyOrderService.Create(ctx, cmd)
}
```

### Dual Write — Write to Both Stores (C#)

```csharp
public class DualWriteOrderRepository : IOrderRepository
{
    private readonly IOrderRepository _legacy;
    private readonly IOrderRepository _modern;
    private readonly ILogger          _log;

    public async Task Save(Order order, CancellationToken ct)
    {
        // Write to new store first — it is the source of truth
        await _modern.Save(order, ct);

        // Best-effort write to legacy; log divergence, do not fail the request
        try   { await _legacy.Save(order, ct); }
        catch (Exception ex) { _log.LogError(ex, "Dual-write legacy sync failed for {OrderId}", order.Id); }
    }
}
```

### Debezium CDC — PostgreSQL Outbox Connector Config

```json
{
  "name": "legacy-orders-cdc",
  "config": {
    "connector.class": "io.debezium.connector.postgresql.PostgresConnector",
    "database.hostname": "legacy-db.internal",
    "database.port": "5432",
    "database.user": "debezium_reader",
    "database.dbname": "legacy_orders",
    "database.server.name": "legacy",
    "table.include.list": "public.orders,public.order_lines",
    "plugin.name": "pgoutput",
    "publication.name": "debezium_pub",
    "transforms": "unwrap",
    "transforms.unwrap.type": "io.debezium.transforms.ExtractNewRecordState",
    "transforms.unwrap.drop.tombstones": "false",
    "key.converter": "org.apache.kafka.connect.json.JsonConverter",
    "value.converter": "org.apache.kafka.connect.json.JsonConverter"
  }
}
```

### PowerShell — Migration Progress Tracker

```powershell
# tools/migration/Get-MigrationProgress.ps1
param(
    [string]$LegacyDb   = $env:LEGACY_DB_CONN,
    [string]$ModernDb   = $env:MODERN_DB_CONN
)

$contexts = @(
    @{ Name = "Orders";    LegacyTable = "orders";    ModernTable = "orders"    },
    @{ Name = "Customers"; LegacyTable = "customers"; ModernTable = "customers" },
    @{ Name = "Payments";  LegacyTable = "payments";  ModernTable = "payments"  }
)

foreach ($ctx in $contexts) {
    $legacyCount  = Invoke-Sqlcmd -ConnectionString $LegacyDb `
        -Query "SELECT COUNT(*) AS n FROM $($ctx.LegacyTable)" | Select-Object -Expand n
    $modernCount  = Invoke-Sqlcmd -ConnectionString $ModernDb `
        -Query "SELECT COUNT(*) AS n FROM $($ctx.ModernTable)" | Select-Object -Expand n
    $pct = if ($legacyCount -gt 0) { [math]::Round($modernCount / $legacyCount * 100, 1) } else { 100 }

    $color = if ($pct -ge 100) { "Green" } elseif ($pct -ge 50) { "Yellow" } else { "Red" }
    Write-Host "$($ctx.Name): $modernCount / $legacyCount ($pct%)" -ForegroundColor $color
}
```

### Shadow Mode — Compare Legacy vs New Response (TypeScript middleware)

```typescript
async function shadowCompare(
    req: Request,
    legacyHandler: Handler,
    newHandler: Handler,
    log: Logger,
): Promise<Response> {
    const [legacyRes, newRes] = await Promise.allSettled([
        legacyHandler(req),
        newHandler(req),
    ]);

    if (newRes.status === 'fulfilled' && legacyRes.status === 'fulfilled') {
        const match = deepEqual(legacyRes.value.body, newRes.value.body);
        if (!match) {
            log.warn('shadow_mismatch', {
                path: req.path,
                legacy: legacyRes.value.body,
                modern: newRes.value.body,
            });
        }
    }

    // Always return legacy result during shadow phase
    return legacyRes.status === 'fulfilled'
        ? legacyRes.value
        : Promise.reject(legacyRes.reason);
}
```

---

## Decision Matrix

| Legacy Situation | Recommended Strategy | Risk |
|---|---|---|
| Monolith with identifiable bounded contexts | Strangler Fig per Bounded Context, start with least coupled | Medium |
| Highly coupled "Big Ball of Mud" | Branch by Abstraction first to create seams; then Strangler Fig | High |
| Mainframe / COBOL | Strangler with API facade layer; gradual capability migration | Very High |
| Database-heavy legacy (shared DB) | Dual Write + CDC (Debezium) for data sync during transition | High |
| Simple CRUD monolith, low coupling | Lift-and-shift to new infrastructure; gradual in-place refactor | Low |
| Event-driven legacy with broker | Event interception; new services subscribe alongside legacy | Low–Medium |
| Time-critical delivery pressure | Extract only the most painful context; leave the rest for now | Low (scope-limited) |

---

## Proficiency Levels

### Awareness
- Can explain the Strangler Fig metaphor and why big-bang rewrites fail.
- Understands the difference between Strangler Fig and Branch by Abstraction.
- Knows what a feature flag is and how it enables rollback.

### Applied
- Implements Strangler Fig on a single bounded context extraction: builds the proxy, migrates traffic with feature flags, validates parity, decommissions the legacy path.
- Implements Dual Write for data consistency during a transition.
- Sets up CDC with Debezium to sync a legacy database to a new service's store.

### Master
- Designs and executes large-scale modernization programs spanning multiple bounded contexts and teams.
- Combines Strangler Fig, Branch by Abstraction, Feature Flags, and Event Interception in a single migration programme.
- Manages data consistency across the transition period; designs rollback procedures for each extraction step.
- Uses C4 before/after diagrams, ADRs, and a migration backlog to keep the programme visible and aligned.

### Architect
- Leads enterprise legacy transformation initiatives: defines strategy, migration roadmap, risk management, team ownership transitions, and success metrics.
- Decides when to modernize vs retire vs tolerate legacy systems based on business value and technical risk.
- Coaches teams on the playbook; reviews extraction plans for technical and organizational risk.
- Uses DDD to design the correct target Bounded Context model — ensuring the new system is not a replica of the legacy design.

---

## AI Prompts

**Assess a legacy system for modernization:**
> I have a legacy system described as follows: [describe system, technologies, team, pain points]. Help me: classify the subdomains (Core / Supporting / Generic), identify the Bounded Contexts that are candidates for extraction, recommend an extraction order (least coupled first), and flag the top 3 migration risks.

**Design a migration step:**
> I want to extract the [named context] from this monolith. The current system: [describe relevant parts]. Design the extraction plan: the strangler proxy setup, the data migration approach, the dual-write or CDC strategy, the feature flag rollout plan, and the rollback procedure.

**Review a migration plan:**
> Review this legacy modernization plan for anti-patterns and missing risk mitigations. Check: Is it incremental? Is there a rollback plan for each step? Is data consistency addressed? Is the extraction order justified? Are team ownership changes included? [paste plan]

**Write a migration ADR:**
> Write an ADR for this migration decision: we are extracting [bounded context] from our legacy monolith using the Strangler Fig pattern because [reasons]. Include: context, decision, consequences (positive/negative), alternatives considered (big-bang rewrite, stay on monolith), and references to the related C4 diagrams.

**Estimate migration complexity:**
> Given this legacy codebase description: [describe coupling, database usage, external dependencies, team size]. Estimate: how many bounded context extractions are likely, what the high-risk migrations are, what CDC or dual-write complexity looks like, and a rough phasing (quarters) for the programme.

---

## References

**Books**
- Sam Newman — *Monolith to Microservices* (O'Reilly, 2019) — definitive practical guide; covers Strangler Fig, Branch by Abstraction, data decomposition
- Michael Feathers — *Working Effectively with Legacy Code* (Prentice Hall, 2004) — seam identification, Branch by Abstraction at code level
- Martin Fowler — *Refactoring: Improving the Design of Existing Code* (2nd ed.) — foundational techniques for safe incremental change

**Articles**
- Martin Fowler — [Strangler Fig Application](https://martinfowler.com/bliki/StranglerFigApplication.html)
- Martin Fowler — [Branch by Abstraction](https://martinfowler.com/bliki/BranchByAbstraction.html)

**Tooling**
- [Debezium](https://debezium.io/) — CDC for PostgreSQL, MySQL, SQL Server, MongoDB
- [Unleash](https://www.getunleash.io/) — open-source feature flag platform
- [LaunchDarkly](https://launchdarkly.com/) — managed feature flags with percentage rollout and targeting

**Related Skills**
- `02-architecture-and-design/ddd-fundamentals` — DDD provides the target Bounded Context model
- `02-architecture-and-design/c4-model` — before/after container diagrams make migration scope visible
- `02-architecture-and-design/architecture-decision-records` — document every extraction decision as an ADR
- `02-architecture-and-design/event-driven-architecture-cqrs` — EDA enables loose coupling during transition; event interception is a key migration pattern
