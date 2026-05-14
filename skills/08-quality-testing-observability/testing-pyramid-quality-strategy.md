---
name: "Testing Pyramid & Quality Strategy"
slug: testing-pyramid-quality-strategy
category: "08-quality-testing-observability"
proficiency: Architect
description: "Design and implement a comprehensive quality strategy using the testing pyramid: unit, integration, contract, and end-to-end tests. Covers test architecture for distributed systems, event-driven flows, APIs, and frontends — integrated with CI/CD pipelines and shift-left quality practices."
tags: [testing, quality, testing-pyramid, unit-tests, integration-tests, contract-testing, e2e, tdd, bdd, pact, playwright, vitest, testcontainers, mutation-testing, shift-left, chaos-engineering]
status: published
---

# Testing Pyramid & Quality Strategy

## Principles

**Test Behaviour, Not Implementation**
Tests that assert on internal implementation details (private method calls, internal state, specific collaborator interactions) break every time the code is refactored — even when behaviour is unchanged. Test what the unit does, not how it does it. This is the difference between tests that enable refactoring and tests that prevent it.

**The Pyramid Reflects Cost and Confidence**
Unit tests are cheap to write, fast to run, and precise in their failure messages. End-to-end tests are expensive to write, slow to run, and imprecise when they fail. The pyramid shape — many unit, fewer integration, fewer still E2E — is not a rule but a cost-benefit optimisation. Invert it and you get a slow, brittle test suite that nobody maintains.

**Tests Are a Design Tool**
Writing tests first (TDD) forces you to design APIs from the consumer's perspective. A unit that is hard to test in isolation is a unit with too many dependencies or too much responsibility. Test difficulty is a design smell. Fix the design, not the test strategy.

**Shift Left: Find Defects When They Are Cheapest**
A bug found in unit tests costs minutes to fix. A bug found in staging costs hours. A bug found in production costs days and reputational damage. Every gate added earlier in the pipeline — linting, static analysis, contract tests — pays for itself in reduced late-stage defect cost.

**Fast Feedback Loops Are Non-Negotiable**
A test suite that takes 45 minutes to run will not be run before every commit. A test suite that takes 3 minutes will. Parallelise aggressively. Separate slow tests into a later pipeline stage. Optimise the unit test suite ruthlessly — it should run in under 60 seconds locally.

**Test Confidence, Not Coverage**
100% line coverage with no assertions proves nothing. A test that calls code but does not assert on its output is noise. Coverage is a useful lower bound (untested code is definitely not tested), not an upper bound on quality. Use mutation testing to measure whether your assertions actually catch defects.

---

## Implementation Patterns

### Pattern 1 — The Testing Pyramid (Four Layers)

```
              ┌──────────────┐
              │   E2E Tests  │  ← few, slow, high confidence on critical paths
              │  (Playwright)│
           ┌──┴──────────────┴──┐
           │  Integration Tests  │  ← moderate, real dependencies (DB, broker)
           │  (Testcontainers)   │
        ┌──┴────────────────────┴──┐
        │    Contract Tests        │  ← fast, verify API / event boundaries
        │    (Pact)                │
     ┌──┴──────────────────────────┴──┐
     │        Unit Tests              │  ← many, fast, isolated, precise
     │  (Vitest / Jest / xUnit / Go)  │
     └────────────────────────────────┘
```

**Unit tests**: test a single function, method, or component in isolation. All external dependencies are replaced with fakes or stubs. Run in milliseconds. The foundation of the pyramid.

**Contract tests**: verify that a producer (API or event publisher) and consumer (client or event subscriber) agree on the shape of their interface. Run without either service being deployed. Prevent integration failures caused by schema drift.

**Integration tests**: test a unit with real external dependencies (real database, real message broker, real file system). Use Testcontainers to spin up real dependencies in Docker. Slower than unit tests; more confidence than mocks.

**End-to-end tests**: test complete user journeys through the full deployed application. Run against a real environment. Highest confidence; highest cost. Reserve for critical paths only.

### Pattern 2 — Unit Test Patterns

**Arrange-Act-Assert (AAA)**
Every test follows the same structure:
```
Arrange: set up the system under test and its inputs
Act:     invoke the behaviour
Assert:  verify the outcome
```

**Test doubles taxonomy**:
- **Stub**: returns a fixed value; used to control input to the system under test
- **Fake**: a working implementation with simplified behaviour (in-memory database, fake clock)
- **Mock**: a stub with built-in assertion that verifies it was called correctly
- **Spy**: records calls to a real implementation for later assertion

Prefer Fakes over Mocks. Fakes are reusable across many tests; Mocks couple tests to implementation.

**Test one thing per test**: one logical assertion per test. When a test fails, the name tells you exactly what broke. A test called `it("processes order correctly")` that has 12 assertions tells you something broke, but not what.

### Pattern 3 — Consumer-Driven Contract Testing (Pact)

In a distributed system, a consumer (frontend, downstream service) defines its expectations of a provider (API, event publisher) in a contract. Pact verifies both sides independently — no running services required.

```
Consumer defines contract → Pact Broker stores contract → Provider verifies against it
```

This replaces the need for integrated staging environments to catch schema drift. Contract tests run in seconds, in CI, before any deployment.

**API Contract (HTTP)**:
```
Consumer: OrderDashboard
Interaction: GET /orders/ord_123
  request: { headers: { Authorization: "Bearer ..." } }
  response: { status: 200, body: { id: "ord_123", status: "pending", total: { amountMinor: 1099, currency: "USD" } } }
```

**Event Contract (message)**:
```
Consumer: InventoryService
Event: OrderPlaced
  shape: { orderId: uuid, customerId: uuid, lines: [{ productId: string, quantity: int }] }
```

If the provider changes the `total` field to `amount` without a version bump, the consumer's contract test fails — in CI, before staging, before production.

### Pattern 4 — Integration Testing with Testcontainers

Testcontainers starts real Docker containers for test dependencies (PostgreSQL, Kafka, Redis) that are isolated per test run and torn down automatically. This eliminates the "works against the shared staging database" problem.

```go
// Go — Testcontainers PostgreSQL for integration test
func TestOrderRepository_Save(t *testing.T) {
    ctx := context.Background()

    pgContainer, err := postgres.RunContainer(ctx,
        testcontainers.WithImage("postgres:16"),
        postgres.WithDatabase("orders_test"),
        postgres.WithUsername("test"),
        postgres.WithPassword("test"),
        testcontainers.WithWaitStrategy(
            wait.ForLog("database system is ready to accept connections"),
        ),
    )
    require.NoError(t, err)
    defer pgContainer.Terminate(ctx)

    connStr, _ := pgContainer.ConnectionString(ctx, "sslmode=disable")
    db := setupDatabase(connStr)
    repo := NewOrderRepository(db)

    order := Order.Place(CustomerID("cust_001"), testLines())
    err = repo.Save(ctx, order)

    require.NoError(t, err)
    saved, err := repo.FindById(ctx, order.Id)
    require.NoError(t, err)
    assert.Equal(t, order.Id, saved.Id)
    assert.Equal(t, OrderStatus.Pending, saved.Status)
}
```

### Pattern 5 — End-to-End Testing Strategy (Playwright)

E2E tests cover critical user journeys only — not every permutation. Define a test inventory:

**Tier 1 — Must never break (run on every merge)**:
- User can register and log in
- User can place an order and see confirmation
- User can view order history
- Payment flow completes without error

**Tier 2 — Should not break (run nightly)**:
- Edge cases: empty states, validation errors, session expiry
- Cross-browser critical paths

```typescript
// tests/e2e/orders/place-order.spec.ts
import { test, expect } from '@playwright/test';

test('authenticated user can place an order', async ({ page }) => {
    await page.goto('/login');
    await page.getByLabel('Email').fill('test@example.com');
    await page.getByLabel('Password').fill('test-password');
    await page.getByRole('button', { name: 'Sign in' }).click();
    await expect(page).toHaveURL('/dashboard');

    await page.getByRole('link', { name: 'New Order' }).click();
    await page.getByLabel('Product').selectOption('SKU-001');
    await page.getByLabel('Quantity').fill('2');
    await page.getByRole('button', { name: 'Place Order' }).click();

    // Assert order confirmation
    await expect(page.getByRole('heading', { name: 'Order Confirmed' }))
        .toBeVisible({ timeout: 5000 });
    await expect(page.getByTestId('order-status'))
        .toHaveText('Pending');
});
```

### Pattern 6 — Mutation Testing (Test Quality Validation)

Mutation testing modifies the source code in small ways (mutants: flip `>` to `>=`, change `+` to `-`, delete a condition) and runs the test suite against each mutant. If the tests do not catch the mutant (the mutant "survives"), the tests have a gap.

Killed mutant rate of > 80% indicates strong test assertions. Surviving mutants reveal missing assertions.

```bash
# .NET — Stryker mutation testing
dotnet stryker --project Ordering --threshold-high 80 --threshold-low 60

# JavaScript — Stryker
npx stryker run

# Go — gremlins
gremlins unleash --tags integration ./...
```

Run mutation testing on the core domain (Aggregates, Domain Services) where correctness matters most. Do not run on infrastructure adapters — the cost exceeds the value.

---

## Anti-Patterns

| Anti-Pattern | Why It's Harmful | Fix |
|---|---|---|
| Ice cream cone (inverted pyramid) | Many slow E2E tests, few unit tests; suite takes 45 minutes; failures are non-deterministic; nobody runs it | Invert: unit test the logic, E2E test only the critical paths |
| Testing implementation, not behaviour | Tests break on every refactor even when behaviour is unchanged; refactoring becomes feared | Test public interfaces and observable outcomes; mock at architectural boundaries, not internal collaborators |
| Shared mutable test state | Tests pass in isolation but fail in parallel or in sequence; order-dependent test failures | Each test creates and tears down its own state; use Testcontainers for isolated external dependencies |
| Mocking the database | Integration tests use an in-memory fake that does not support transactions, constraints, or real query behaviour; bugs only surface in production | Use Testcontainers with a real database for integration tests |
| 100% coverage as the goal | Teams write trivial tests to hit coverage targets; assertions are weak or absent; mutation score is 20% | Use coverage as a floor (untested code is a risk); use mutation testing to validate assertion quality |
| No contract tests in distributed systems | Schema changes in a provider break consumers silently; only discovered in staging or production | Consumer-driven contract tests (Pact) run in CI before any deployment |
| Flaky E2E tests left unresolved | Flaky tests are ignored or skipped; the suite loses trust; real failures are missed in the noise | Flaky tests are quarantined immediately and fixed within one sprint; never leave a flaky test in the main suite |

---

## Code Templates

### Go — Unit Test with Table-Driven Tests

```go
// domain/money_test.go
func TestMoney_Add(t *testing.T) {
    tests := []struct {
        name    string
        a, b    Money
        want    Money
        wantErr bool
    }{
        {
            name: "adds same currency",
            a:    Money{Amount: 100, Currency: "USD"},
            b:    Money{Amount: 50,  Currency: "USD"},
            want: Money{Amount: 150, Currency: "USD"},
        },
        {
            name:    "rejects different currencies",
            a:       Money{Amount: 100, Currency: "USD"},
            b:       Money{Amount: 50,  Currency: "EUR"},
            wantErr: true,
        },
        {
            name:    "rejects negative amount",
            a:       Money{Amount: -1, Currency: "USD"},
            b:       Money{Amount: 50, Currency: "USD"},
            wantErr: true,
        },
    }

    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            got, err := tt.a.Add(tt.b)
            if tt.wantErr {
                require.Error(t, err)
                return
            }
            require.NoError(t, err)
            assert.Equal(t, tt.want, got)
        })
    }
}
```

### C# — Unit Test with Fake Repository (no mocks)

```csharp
// Fake — reusable across many tests; no mock framework needed
public class FakeOrderRepository : IOrderRepository
{
    private readonly Dictionary<OrderId, Order> _store = new();

    public Task Save(Order order, CancellationToken ct)
    {
        _store[order.Id] = order;
        return Task.CompletedTask;
    }

    public Task<Order?> FindById(OrderId id, CancellationToken ct) =>
        Task.FromResult(_store.TryGetValue(id, out var o) ? o : null);
}

// Test — fast, isolated, no database
public class PlaceOrderCommandHandlerTests
{
    [Fact]
    public async Task Handle_ValidOrder_RaisesOrderPlacedEvent()
    {
        // Arrange
        var repo    = new FakeOrderRepository();
        var uow     = new FakeUnitOfWork();
        var handler = new PlaceOrderCommandHandler(repo, uow);
        var cmd     = new PlaceOrderCommand(
            CustomerId.New(),
            [new OrderLineDto("SKU-001", 2, Money.Of(1099, "USD"))]
        );

        // Act
        var orderId = await handler.Handle(cmd, CancellationToken.None);

        // Assert
        var order = await repo.FindById(orderId, CancellationToken.None);
        order.Should().NotBeNull();
        order!.Status.Should().Be(OrderStatus.Pending);
        order.DomainEvents.Should().ContainSingle(e => e is OrderPlaced);
    }
}
```

### TypeScript — Vitest Unit Test (React Component)

```tsx
// features/orders/components/OrderStatusBadge.test.tsx
import { render, screen } from '@testing-library/react';
import { describe, it, expect } from 'vitest';
import { OrderStatusBadge } from './OrderStatusBadge';

describe('OrderStatusBadge', () => {
    it.each([
        ['pending',   'Pending',   'badge--warning'],
        ['shipped',   'Shipped',   'badge--info'],
        ['delivered', 'Delivered', 'badge--success'],
        ['cancelled', 'Cancelled', 'badge--error'],
    ])('renders %s status correctly', (status, label, className) => {
        render(<OrderStatusBadge status={status as OrderStatus} />);

        const badge = screen.getByRole('status');
        expect(badge).toHaveTextContent(label);
        expect(badge).toHaveClass(className);
    });

    it('is accessible — has role and aria-label', () => {
        render(<OrderStatusBadge status="pending" />);
        expect(screen.getByRole('status')).toBeInTheDocument();
    });
});
```

### GitHub Actions — Pipeline Stage Separation

```yaml
# .github/workflows/quality.yml
name: Quality Gates

on: [push, pull_request]

jobs:
  unit-tests:
    runs-on: ubuntu-latest
    timeout-minutes: 5        # fail fast if tests hang
    steps:
      - uses: actions/checkout@v4
      - run: make test-unit   # must complete in < 60s

  contract-tests:
    runs-on: ubuntu-latest
    needs: unit-tests
    steps:
      - uses: actions/checkout@v4
      - run: make test-contract   # Pact consumer tests
      - name: Publish pacts to broker
        run: npx pact-broker publish ./pacts --broker-base-url ${{ vars.PACT_BROKER_URL }}

  integration-tests:
    runs-on: ubuntu-latest
    needs: unit-tests
    steps:
      - uses: actions/checkout@v4
      - run: make test-integration   # Testcontainers — needs Docker

  e2e-tests:
    runs-on: ubuntu-latest
    needs: [contract-tests, integration-tests]
    steps:
      - uses: actions/checkout@v4
      - run: npx playwright install --with-deps
      - run: make test-e2e
      - uses: actions/upload-artifact@v4
        if: failure()
        with:
          name: playwright-report
          path: playwright-report/

  mutation-tests:
    runs-on: ubuntu-latest
    needs: unit-tests
    if: github.ref == 'refs/heads/main'   # run on merge only — expensive
    steps:
      - uses: actions/checkout@v4
      - run: dotnet stryker --threshold-break 60
```

---

## Decision Matrix

| Context | Test Focus | Tools | Notes |
|---|---|---|---|
| Domain logic (Aggregates, Services) | Unit tests + mutation testing | xUnit/Vitest/Go testing + Stryker/Gremlins | Highest ROI; test every invariant and edge case |
| Repository / persistence layer | Integration tests (Testcontainers) | Testcontainers + real DB | Never mock the database |
| REST API endpoints | Integration tests (in-process HTTP) + contract tests | Pact, SuperTest, httptest | Test the HTTP contract, not just the handler |
| Event publisher / consumer | Contract tests (message Pact) | Pact for messages | Catch schema drift before deployment |
| Frontend components | Unit tests (RTL) + visual regression | Vitest + RTL + Storybook + Chromatic | Behaviour tests, not snapshot tests |
| Critical user journeys | E2E tests (tier 1 only) | Playwright | < 20 tests; fast, deterministic, non-flaky |
| Legacy code (no tests) | Characterisation tests first | Any framework | Lock in current behaviour before refactoring |
| Distributed system resilience | Chaos engineering | Chaos Monkey, Gremlin, Toxiproxy | Inject failures; validate SLO holds |

---

## Proficiency Levels

### Awareness
- Can explain the testing pyramid and why the shape matters.
- Knows the difference between a unit test and an integration test.
- Understands what contract testing solves in a distributed system.

### Applied
- Writes unit tests using AAA structure with table-driven cases.
- Implements integration tests with Testcontainers for real database dependencies.
- Writes accessible Playwright E2E tests for Tier 1 critical paths.
- Configures pipeline stage separation: unit → integration → E2E with fail-fast gates.

### Master
- Implements consumer-driven contract tests (Pact) for HTTP APIs and event schemas.
- Uses mutation testing to validate assertion quality on the core domain.
- Diagnoses and resolves flaky E2E tests; implements retry strategies and test isolation.
- Designs a test architecture for an event-driven system: unit tests for domain logic, contract tests for event schemas, integration tests for consumer handlers.

### Architect
- Defines organisation-wide quality strategy: pyramid targets per layer, contract testing governance, flaky test SLA, mutation score thresholds, and chaos engineering programme.
- Integrates quality gates into CI/CD: coverage floor, mutation threshold, contract verification, E2E gate before production.
- Coaches teams on TDD adoption; reviews test architectures for pyramid health and anti-pattern resolution.
- Designs the testing strategy for legacy Strangler Fig migrations: characterisation tests on legacy behaviour, contract tests on the new API surface, parallel-run comparison tests during traffic migration.

---

## AI Prompts

**Design a test strategy:**
> Design a testing strategy for this system: [describe architecture, key components, distributed or monolith, CI/CD pipeline]. Specify: what to test at each pyramid layer, which tools to use, how to handle external dependencies, and what the pipeline stage separation should look like.

**Review a test suite for anti-patterns:**
> Review this test suite for quality anti-patterns. Check: Is the pyramid inverted (more E2E than unit)? Are implementation details being tested instead of behaviour? Is the database being mocked? Are there assertions or just coverage? Are there flaky tests? [paste test examples or describe suite structure]

**Write contract tests:**
> Write a Pact consumer contract test for this interaction: Consumer [name] calls Provider [name] with [describe request]. The expected response is [describe response shape]. Include both the consumer test and the provider verification setup.

**Diagnose flaky tests:**
> This E2E test fails intermittently: [paste test code and failure log]. Identify the most likely causes of flakiness (timing, shared state, network, ordering dependency) and provide specific fixes for each.

**Test an event-driven flow:**
> I have this event-driven flow: [Producer A publishes OrderPlaced → Consumer B reserves inventory → Consumer C processes payment]. Design the test strategy: what to unit test, what contract to define between A and B and between A and C, and what integration test to write for each consumer handler. Include tool recommendations.

---

## References

**Books**
- Kent Beck — *Test-Driven Development: By Example* (Addison-Wesley, 2002) — TDD origins and philosophy
- Gerard Meszaros — *xUnit Test Patterns* (Addison-Wesley, 2007) — the definitive reference on test doubles, fixtures, and patterns
- Vladimir Khorikov — *Unit Testing: Principles, Practices, and Patterns* (Manning, 2020) — modern take; covers output-based vs state-based vs communication-based testing

**Tools**
- [Pact](https://docs.pact.io/) — consumer-driven contract testing for HTTP and messages
- [Testcontainers](https://testcontainers.com/) — real Docker-based dependencies for integration tests (Java, Go, .NET, Node, Python)
- [Playwright](https://playwright.dev/) — E2E testing for web; cross-browser, reliable, trace viewer
- [Stryker Mutator](https://stryker-mutator.io/) — mutation testing for JavaScript/TypeScript, C#, Scala
- [Toxiproxy](https://github.com/Shopify/toxiproxy) — TCP proxy for simulating network failure in integration tests

**Related Skills**
- `07-infrastructure-and-operations/cicd-gitops-strategy` — pipeline stage separation gates quality layers; contract test publication to Pact Broker is a CI step
- `08-quality-testing-observability/observability-telemetry-strategy` — production is the final test environment; observability is the feedback loop after deployment
- `09-re-engineering-and-evolution/strangler-fig-legacy-modernization` — characterisation tests lock in legacy behaviour before migration; contract tests verify the new API surface
- `02-architecture-and-design/ddd-fundamentals` — unit test the domain model; domain events are the natural assertion boundary for aggregate tests
