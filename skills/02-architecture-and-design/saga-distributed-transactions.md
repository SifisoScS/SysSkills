---
name: Saga & Distributed Transactions
slug: saga-distributed-transactions
category: 02-architecture-and-design
proficiency: advanced
description: >
  Coordinate multi-service business transactions without distributed locks
  using the Saga pattern. Covers choreography-based sagas with domain events,
  orchestration-based sagas with a central coordinator, compensating
  transactions, idempotency, failure isolation, and production tooling
  with Temporal and Kafka.
tags:
  - saga-pattern
  - distributed-transactions
  - choreography
  - orchestration
  - compensating-transactions
  - temporal
  - eventual-consistency
  - idempotency
status: published
---

## Principles

### Why Distributed Transactions Are Hard
In a microservices system, a single business operation (e.g., "place order") spans multiple services — inventory, payment, shipping — each with its own database. The classic two-phase commit (2PC) protocol solves this with a coordinator that locks rows across all participants. In practice, 2PC causes:
- **Lock contention** — rows across services locked for the duration of the protocol (seconds to minutes under failure)
- **Availability coupling** — if any participant is unavailable, the coordinator blocks
- **Scalability ceiling** — distributed locks prevent horizontal scaling

### The Saga Pattern
A saga is a sequence of local transactions, each within a single service's database, with **compensating transactions** that undo completed steps when a later step fails.

```
Place Order Saga:
  1. Reserve Inventory    (compensate: Release Inventory)
  2. Charge Payment       (compensate: Refund Payment)
  3. Create Shipment      (compensate: Cancel Shipment)
  4. Confirm Order        (no compensation — final step)

If step 3 fails:
  → Cancel Shipment (skipped — never ran)
  → Refund Payment  (compensates step 2)
  → Release Inventory (compensates step 1)
```

Sagas provide **ACD** (Atomicity + Consistency + Durability) but not full ACID Isolation. Intermediate states are briefly visible. Isolation is managed with semantic locks, optimistic checks, and careful ordering.

### Two Coordination Styles

| | Choreography | Orchestration |
|---|---|---|
| **Coordinator** | None — each service reacts to events | Central saga orchestrator |
| **Coupling** | Services know domain events, not each other | Services expose commands; orchestrator controls flow |
| **Observability** | Hard — flow is implicit in event chains | Easy — orchestrator state machine is explicit |
| **Complexity** | Low at start, grows with branching | Higher upfront, predictable long-term |
| **Best for** | Simple linear flows (3–4 steps) | Complex flows with branching, timeouts, retries |

### Key Invariants
1. **Every step must have a compensating transaction** (or be pivot/retriable)
2. **Compensating transactions must be idempotent** — called multiple times on retry without side effects
3. **Message delivery is at-least-once** — consumers must deduplicate
4. **Pivot transaction**: the step after which forward progress is guaranteed (no compensation needed)

---

## Implementation Patterns

### Pattern 1 — Choreography Saga with Domain Events (Go + Kafka)
```go
// Order service publishes events; downstream services react independently

// ─── Order Service ───────────────────────────────────────────────────────────

// domain/order/events.go
package order

import (
	"time"
	"github.com/google/uuid"
)

type OrderPlaced struct {
	OrderID    uuid.UUID `json:"order_id"`
	CustomerID uuid.UUID `json:"customer_id"`
	Items      []Item    `json:"items"`
	TotalCents int64     `json:"total_cents"`
	Currency   string    `json:"currency"`
	OccurredAt time.Time `json:"occurred_at"`
}

type OrderCancelled struct {
	OrderID    uuid.UUID `json:"order_id"`
	Reason     string    `json:"reason"`
	OccurredAt time.Time `json:"occurred_at"`
}

// application/place_order.go
package order

import (
	"context"
	"fmt"
	domain "github.com/example/orders/internal/domain/order"
)

type PlaceOrder struct {
	repo      domain.Repository
	publisher EventPublisher
}

func (uc *PlaceOrder) Execute(ctx context.Context, in PlaceOrderInput) (PlaceOrderOutput, error) {
	o, err := domain.NewOrder(in.CustomerID, in.Items)
	if err != nil {
		return PlaceOrderOutput{}, fmt.Errorf("create order: %w", err)
	}

	if err := uc.repo.Save(ctx, o); err != nil {
		return PlaceOrderOutput{}, fmt.Errorf("save order: %w", err)
	}

	// Publish event — inventory and payment services will react
	if err := uc.publisher.Publish(ctx, o.PopEvents()); err != nil {
		return PlaceOrderOutput{}, fmt.Errorf("publish events: %w", err)
	}

	return PlaceOrderOutput{OrderID: o.ID()}, nil
}

// ─── Inventory Service ────────────────────────────────────────────────────────

// Listens to orders.placed, reserves stock, emits InventoryReserved or InventoryFailed

type OrderPlacedHandler struct {
	inventoryRepo InventoryRepository
	publisher     EventPublisher
	idempotency   IdempotencyStore // Redis SET NX
}

func (h *OrderPlacedHandler) Handle(ctx context.Context, evt OrderPlaced) error {
	// Idempotency check — at-least-once delivery; this handler may run multiple times
	key := "inventory:reserve:" + evt.OrderID.String()
	if !h.idempotency.SetIfNotExists(ctx, key, 24*time.Hour) {
		return nil // already processed
	}

	reservation, err := h.inventoryRepo.Reserve(ctx, evt.OrderID, evt.Items)
	if err != nil {
		h.publisher.Publish(ctx, InventoryReservationFailed{
			OrderID: evt.OrderID,
			Reason:  err.Error(),
		})
		return nil // don't retry — failure is a domain outcome, not a system error
	}

	h.publisher.Publish(ctx, InventoryReserved{
		OrderID:       evt.OrderID,
		ReservationID: reservation.ID,
	})
	return nil
}

// ─── Payment Service ──────────────────────────────────────────────────────────

// Listens to inventory.reserved, charges customer, emits PaymentCharged or PaymentFailed

type InventoryReservedHandler struct {
	paymentRepo PaymentRepository
	gateway     PaymentGateway
	publisher   EventPublisher
	idempotency IdempotencyStore
}

func (h *InventoryReservedHandler) Handle(ctx context.Context, evt InventoryReserved) error {
	key := "payment:charge:" + evt.OrderID.String()
	if !h.idempotency.SetIfNotExists(ctx, key, 24*time.Hour) {
		return nil
	}

	// Idempotent gateway call — use order ID as idempotency key
	charge, err := h.gateway.Charge(ctx, PaymentRequest{
		IdempotencyKey: evt.OrderID.String(),
		Amount:         evt.AmountCents,
		Currency:       evt.Currency,
	})
	if err != nil {
		h.publisher.Publish(ctx, PaymentFailed{
			OrderID: evt.OrderID,
			Reason:  err.Error(),
		})
		return nil
	}

	h.publisher.Publish(ctx, PaymentCharged{
		OrderID:   evt.OrderID,
		ChargeRef: charge.ID,
	})
	return nil
}

// ─── Compensation listener in Inventory Service ───────────────────────────────

// Listens to payment.failed → releases reservation (compensating transaction)
type PaymentFailedHandler struct {
	inventoryRepo InventoryRepository
	idempotency   IdempotencyStore
}

func (h *PaymentFailedHandler) Handle(ctx context.Context, evt PaymentFailed) error {
	key := "inventory:release:" + evt.OrderID.String()
	if !h.idempotency.SetIfNotExists(ctx, key, 24*time.Hour) {
		return nil
	}
	return h.inventoryRepo.ReleaseReservation(ctx, evt.OrderID)
}
```

### Pattern 2 — Orchestration Saga Coordinator (Go)
```go
// saga/order_saga.go — central state machine; owns the saga lifecycle

package saga

import (
	"context"
	"fmt"
	"time"

	"github.com/google/uuid"
)

type OrderSagaState string

const (
	StateStarted              OrderSagaState = "started"
	StateInventoryReserving   OrderSagaState = "inventory_reserving"
	StateInventoryReserved    OrderSagaState = "inventory_reserved"
	StatePaymentCharging      OrderSagaState = "payment_charging"
	StatePaymentCharged       OrderSagaState = "payment_charged"
	StateShipmentCreating     OrderSagaState = "shipment_creating"
	StateCompleted            OrderSagaState = "completed"
	// Compensation states
	StateCompensatingPayment   OrderSagaState = "compensating_payment"
	StateCompensatingInventory OrderSagaState = "compensating_inventory"
	StateFailed                OrderSagaState = "failed"
)

type OrderSaga struct {
	ID        uuid.UUID
	OrderID   uuid.UUID
	State     OrderSagaState
	Steps     []SagaStep
	CreatedAt time.Time
	UpdatedAt time.Time
}

type SagaStep struct {
	Name       string
	Status     string // pending / completed / compensated / failed
	CompletedAt *time.Time
	Error      string
}

// OrderSagaOrchestrator drives the saga by calling participant services directly.
type OrderSagaOrchestrator struct {
	repo      SagaRepository      // persists saga state for crash recovery
	inventory InventoryClient     // gRPC/HTTP client to inventory service
	payment   PaymentClient       // gRPC/HTTP client to payment service
	shipment  ShipmentClient      // gRPC/HTTP client to shipment service
}

func (o *OrderSagaOrchestrator) Start(ctx context.Context, orderID uuid.UUID, items []Item, totalCents int64) error {
	saga := &OrderSaga{
		ID:      uuid.New(),
		OrderID: orderID,
		State:   StateStarted,
		Steps: []SagaStep{
			{Name: "reserve_inventory", Status: "pending"},
			{Name: "charge_payment", Status: "pending"},
			{Name: "create_shipment", Status: "pending"},
		},
		CreatedAt: time.Now().UTC(),
	}
	if err := o.repo.Save(ctx, saga); err != nil {
		return fmt.Errorf("save saga: %w", err)
	}
	return o.execute(ctx, saga, items, totalCents)
}

func (o *OrderSagaOrchestrator) execute(ctx context.Context, saga *OrderSaga, items []Item, totalCents int64) error {
	// Step 1: Reserve Inventory
	saga.State = StateInventoryReserving
	o.repo.Save(ctx, saga)

	reservationID, err := o.inventory.Reserve(ctx, ReserveRequest{
		IdempotencyKey: saga.ID.String() + ":reserve",
		OrderID:        saga.OrderID,
		Items:          items,
	})
	if err != nil {
		return o.compensate(ctx, saga, err, "reserve_inventory")
	}
	saga.State = StateInventoryReserved
	saga.Steps[0].Status = "completed"
	o.repo.Save(ctx, saga)

	// Step 2: Charge Payment
	saga.State = StatePaymentCharging
	o.repo.Save(ctx, saga)

	chargeRef, err := o.payment.Charge(ctx, ChargeRequest{
		IdempotencyKey: saga.ID.String() + ":charge",
		OrderID:        saga.OrderID,
		AmountCents:    totalCents,
	})
	if err != nil {
		return o.compensate(ctx, saga, err, "charge_payment")
	}
	saga.State = StatePaymentCharged
	saga.Steps[1].Status = "completed"
	o.repo.Save(ctx, saga)

	// Step 3: Create Shipment (pivot — after this, forward only)
	saga.State = StateShipmentCreating
	o.repo.Save(ctx, saga)

	_, err = o.shipment.Create(ctx, ShipmentRequest{
		IdempotencyKey: saga.ID.String() + ":shipment",
		OrderID:        saga.OrderID,
		ReservationID:  reservationID,
		ChargeRef:      chargeRef,
	})
	if err != nil {
		// Shipment creation failed: compensate payment and inventory
		return o.compensate(ctx, saga, err, "create_shipment")
	}
	saga.Steps[2].Status = "completed"
	saga.State = StateCompleted
	o.repo.Save(ctx, saga)

	return nil
}

func (o *OrderSagaOrchestrator) compensate(ctx context.Context, saga *OrderSaga, originalErr error, failedStep string) error {
	// Execute compensations in reverse order for completed steps
	for i := len(saga.Steps) - 1; i >= 0; i-- {
		step := saga.Steps[i]
		if step.Status != "completed" {
			continue // not yet executed — skip
		}

		switch step.Name {
		case "charge_payment":
			saga.State = StateCompensatingPayment
			o.repo.Save(ctx, saga)
			if err := o.payment.Refund(ctx, RefundRequest{
				IdempotencyKey: saga.ID.String() + ":refund",
				OrderID:        saga.OrderID,
			}); err != nil {
				// Log and alert — compensation failure requires manual intervention
				// In production: dead-letter queue + ops runbook
			}
			saga.Steps[i].Status = "compensated"

		case "reserve_inventory":
			saga.State = StateCompensatingInventory
			o.repo.Save(ctx, saga)
			if err := o.inventory.Release(ctx, ReleaseRequest{
				IdempotencyKey: saga.ID.String() + ":release",
				OrderID:        saga.OrderID,
			}); err != nil {
				// Log and alert — requires manual intervention
			}
			saga.Steps[i].Status = "compensated"
		}
		o.repo.Save(ctx, saga)
	}

	saga.State = StateFailed
	o.repo.Save(ctx, saga)
	return fmt.Errorf("saga failed at %s: %w", failedStep, originalErr)
}
```

### Pattern 3 — Temporal Workflow (Durable Orchestration)
```go
// Temporal handles retries, timeouts, and crash recovery automatically.
// The workflow function is replayed deterministically on failure.

// workflows/order_saga.go
package workflows

import (
	"time"

	"go.temporal.io/sdk/workflow"
	"go.temporal.io/sdk/activity"
)

type PlaceOrderInput struct {
	OrderID     string
	CustomerID  string
	Items       []OrderItem
	TotalCents  int64
	Currency    string
}

// PlaceOrderWorkflow is the saga orchestrator — Temporal guarantees durable execution.
func PlaceOrderWorkflow(ctx workflow.Context, input PlaceOrderInput) error {
	logger := workflow.GetLogger(ctx)

	// Compensation stack — built as we go, executed in reverse on failure
	type compensation struct {
		fn   func(workflow.Context) error
		name string
	}
	var compensations []compensation

	rollback := func(ctx workflow.Context) {
		for i := len(compensations) - 1; i >= 0; i-- {
			c := compensations[i]
			compensationCtx := workflow.WithActivityOptions(ctx, workflow.ActivityOptions{
				StartToCloseTimeout: 30 * time.Second,
				RetryPolicy: &temporal.RetryPolicy{
					MaximumAttempts: 10, // compensations must eventually succeed
				},
			})
			if err := c.fn(compensationCtx); err != nil {
				logger.Error("compensation failed", "step", c.name, "error", err)
				// Temporal will retry; if all retries exhausted → human intervention
			}
		}
	}

	// Activity options for forward steps — retries with exponential backoff
	ao := workflow.ActivityOptions{
		StartToCloseTimeout: 10 * time.Second,
		RetryPolicy: &temporal.RetryPolicy{
			InitialInterval:    time.Second,
			BackoffCoefficient: 2.0,
			MaximumInterval:    30 * time.Second,
			MaximumAttempts:    5,
		},
	}
	actCtx := workflow.WithActivityOptions(ctx, ao)

	// Step 1: Reserve Inventory
	var reservationID string
	if err := workflow.ExecuteActivity(actCtx, ReserveInventoryActivity, ReserveInput{
		OrderID: input.OrderID,
		Items:   input.Items,
	}).Get(actCtx, &reservationID); err != nil {
		// No compensations to run yet — step 1 failed
		return err
	}
	compensations = append(compensations, compensation{
		name: "release_inventory",
		fn: func(ctx workflow.Context) error {
			return workflow.ExecuteActivity(ctx, ReleaseInventoryActivity, ReleaseInput{
				OrderID:       input.OrderID,
				ReservationID: reservationID,
			}).Get(ctx, nil)
		},
	})

	// Step 2: Charge Payment
	var chargeRef string
	if err := workflow.ExecuteActivity(actCtx, ChargePaymentActivity, ChargeInput{
		OrderID:     input.OrderID,
		AmountCents: input.TotalCents,
		Currency:    input.Currency,
	}).Get(actCtx, &chargeRef); err != nil {
		rollback(ctx)
		return err
	}
	compensations = append(compensations, compensation{
		name: "refund_payment",
		fn: func(ctx workflow.Context) error {
			return workflow.ExecuteActivity(ctx, RefundPaymentActivity, RefundInput{
				OrderID:   input.OrderID,
				ChargeRef: chargeRef,
			}).Get(ctx, nil)
		},
	})

	// Step 3: Create Shipment (pivot — after success, no compensation needed)
	if err := workflow.ExecuteActivity(actCtx, CreateShipmentActivity, ShipmentInput{
		OrderID:       input.OrderID,
		ReservationID: reservationID,
		ChargeRef:     chargeRef,
	}).Get(actCtx, nil); err != nil {
		rollback(ctx)
		return err
	}

	// Step 4: Confirm Order (final — idempotent, no compensation)
	return workflow.ExecuteActivity(actCtx, ConfirmOrderActivity, ConfirmInput{
		OrderID: input.OrderID,
	}).Get(actCtx, nil)
}

// ─── Activity implementations ─────────────────────────────────────────────────

// activities/inventory.go
package activities

type InventoryActivities struct {
	client InventoryClient
}

// ReserveInventoryActivity is idempotent — Temporal may call it multiple times on retry.
func (a *InventoryActivities) ReserveInventoryActivity(ctx context.Context, in ReserveInput) (string, error) {
	// Use workflow ID + activity ID as idempotency key
	info := activity.GetInfo(ctx)
	idempotencyKey := info.WorkflowExecution.ID + ":" + info.ActivityID

	return a.client.Reserve(ctx, ReserveRequest{
		IdempotencyKey: idempotencyKey,
		OrderID:        in.OrderID,
		Items:          in.Items,
	})
}

// Temporal worker registration
func RegisterWorker(c client.Client) {
	w := worker.New(c, "order-saga-queue", worker.Options{})
	w.RegisterWorkflow(PlaceOrderWorkflow)

	inv := &InventoryActivities{client: newInventoryClient()}
	pay := &PaymentActivities{client: newPaymentClient()}
	shp := &ShipmentActivities{client: newShipmentClient()}

	w.RegisterActivity(inv.ReserveInventoryActivity)
	w.RegisterActivity(inv.ReleaseInventoryActivity)
	w.RegisterActivity(pay.ChargePaymentActivity)
	w.RegisterActivity(pay.RefundPaymentActivity)
	w.RegisterActivity(shp.CreateShipmentActivity)
	w.RegisterActivity(ConfirmOrderActivity)

	if err := w.Run(worker.InterruptCh()); err != nil {
		log.Fatalf("worker: %v", err)
	}
}
```

### Pattern 4 — Saga State Persistence (PostgreSQL)
```sql
-- Saga state table for crash recovery and observability
CREATE TABLE order_sagas (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id      UUID NOT NULL UNIQUE,
  state         TEXT NOT NULL,
  steps         JSONB NOT NULL DEFAULT '[]',
  started_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  completed_at  TIMESTAMPTZ,
  error         TEXT
);

CREATE INDEX idx_order_sagas_state    ON order_sagas(state);
CREATE INDEX idx_order_sagas_order_id ON order_sagas(order_id);

-- Find in-progress sagas older than 30 minutes (for timeout/recovery job)
SELECT id, order_id, state, started_at
FROM order_sagas
WHERE state NOT IN ('completed', 'failed')
  AND started_at < NOW() - INTERVAL '30 minutes';
```

```go
// saga/repository.go
package saga

import (
	"context"
	"database/sql"
	"encoding/json"
	"time"

	"github.com/google/uuid"
)

type PostgresSagaRepository struct {
	db *sql.DB
}

func (r *PostgresSagaRepository) Save(ctx context.Context, saga *OrderSaga) error {
	stepsJSON, err := json.Marshal(saga.Steps)
	if err != nil {
		return err
	}
	_, err = r.db.ExecContext(ctx, `
		INSERT INTO order_sagas (id, order_id, state, steps, updated_at)
		VALUES ($1, $2, $3, $4, NOW())
		ON CONFLICT (id) DO UPDATE
		  SET state = EXCLUDED.state,
		      steps = EXCLUDED.steps,
		      updated_at = NOW(),
		      completed_at = CASE WHEN EXCLUDED.state IN ('completed', 'failed') THEN NOW() ELSE NULL END,
		      error = EXCLUDED.error`,
		saga.ID, saga.OrderID, string(saga.State), stepsJSON,
	)
	return err
}

func (r *PostgresSagaRepository) FindStuck(ctx context.Context, timeout time.Duration) ([]*OrderSaga, error) {
	rows, err := r.db.QueryContext(ctx, `
		SELECT id, order_id, state, steps FROM order_sagas
		WHERE state NOT IN ('completed', 'failed')
		  AND updated_at < $1`, time.Now().UTC().Add(-timeout))
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var sagas []*OrderSaga
	for rows.Next() {
		var s OrderSaga
		var stepsJSON []byte
		if err := rows.Scan(&s.ID, &s.OrderID, &s.State, &stepsJSON); err != nil {
			return nil, err
		}
		json.Unmarshal(stepsJSON, &s.Steps)
		sagas = append(sagas, &s)
	}
	return sagas, rows.Err()
}
```

### Pattern 5 — Saga Recovery Job (Stuck Saga Detection)
```go
// saga/recovery.go — runs as a separate cron job / Kubernetes CronJob
package saga

import (
	"context"
	"log/slog"
	"time"
)

type RecoveryJob struct {
	repo         SagaRepository
	orchestrator *OrderSagaOrchestrator
	logger       *slog.Logger
}

func (j *RecoveryJob) Run(ctx context.Context) error {
	stuck, err := j.repo.FindStuck(ctx, 30*time.Minute)
	if err != nil {
		return err
	}

	for _, saga := range stuck {
		j.logger.Warn("recovering stuck saga",
			"saga_id", saga.ID,
			"order_id", saga.OrderID,
			"state", saga.State,
		)

		switch saga.State {
		case StateInventoryReserving:
			// Idempotent retry — inventory service returns existing reservation if key matches
			if err := j.orchestrator.retryFromInventory(ctx, saga); err != nil {
				j.logger.Error("recovery failed", "saga_id", saga.ID, "error", err)
			}

		case StatePaymentCharging:
			// Check if charge actually went through (gateway query by idempotency key)
			if err := j.orchestrator.retryFromPayment(ctx, saga); err != nil {
				j.logger.Error("recovery failed", "saga_id", saga.ID, "error", err)
			}

		case StateCompensatingPayment, StateCompensatingInventory:
			// Compensation stuck — retry aggressively, alert on-call if still stuck
			j.logger.Error("compensation stuck — requires investigation",
				"saga_id", saga.ID, "state", saga.State)
		}
	}
	return nil
}
```

### Pattern 6 — Saga Monitoring & Alerting (Prometheus + Kubernetes CronJob)
```yaml
# kubernetes/saga-recovery-cronjob.yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: saga-recovery
  namespace: orders
spec:
  schedule: "*/5 * * * *"   # every 5 minutes
  concurrencyPolicy: Forbid  # don't run if previous is still running
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: OnFailure
          containers:
            - name: recovery
              image: orders-service:latest
              command: ["./orders-service", "saga-recovery"]
              env:
                - name: DATABASE_URL
                  valueFrom:
                    secretKeyRef:
                      name: orders-db-secret
                      key: url
              resources:
                requests: { cpu: 50m, memory: 64Mi }
                limits:   { cpu: 200m, memory: 128Mi }
---
# Prometheus alert rules
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: saga-alerts
  namespace: orders
spec:
  groups:
    - name: saga.rules
      rules:
        - alert: SagaStuckForTooLong
          expr: |
            (time() - saga_started_at_seconds{state!~"completed|failed"}) > 1800
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Saga {{ $labels.saga_id }} stuck in state {{ $labels.state }}"
            description: "Saga has been in state {{ $labels.state }} for {{ $value | humanizeDuration }}"

        - alert: SagaCompensationFailing
          expr: |
            increase(saga_compensation_failures_total[10m]) > 0
          for: 1m
          labels:
            severity: critical
          annotations:
            summary: "Saga compensation failures detected"
            description: "{{ $value }} compensation failures in last 10 minutes — manual intervention may be required"

        - alert: HighSagaFailureRate
          expr: |
            rate(saga_completed_total{outcome="failed"}[5m])
            / rate(saga_completed_total[5m]) > 0.05
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Saga failure rate above 5%"
```

---

## Anti-Patterns

### 1. Missing Idempotency in Compensating Transactions
```go
// WRONG — compensation not idempotent; double-refund on retry
func (a *PaymentActivities) RefundPaymentActivity(ctx context.Context, in RefundInput) error {
	return a.gateway.Refund(ctx, in.ChargeRef, in.Amount)  // no idempotency key
}
```
**Fix**: always include an idempotency key derived from the saga ID + step name. Most payment gateways and services accept an `Idempotency-Key` header.

### 2. Saga Step That Is Not Idempotent
```go
// WRONG — emits a duplicate notification if activity retried
func (a *NotifyActivities) SendConfirmationEmail(ctx context.Context, in NotifyInput) error {
	return a.emailClient.Send(ctx, in.CustomerEmail, "Order confirmed!")
}
```
**Fix**: record the notification in the DB before sending; check if already sent on retry. Or use an idempotency store keyed on saga ID + step.

### 3. Long-Running Saga Without Timeouts
```go
// WRONG — saga can wait forever for an external payment callback
func PlaceOrderWorkflow(ctx workflow.Context, in PlaceOrderInput) error {
	// Waiting for webhook from payment provider — no timeout
	var result PaymentResult
	workflow.GetSignalChannel(ctx, "payment-result").Receive(ctx, &result)
}
```
**Fix**: always set a `workflow.WithTimeout` or a timer-based cancellation. Cancel and compensate if the timeout elapses.

### 4. Saga Without State Persistence
```go
// WRONG — saga state held only in memory; crashes lose all progress
type InMemorySagaOrchestrator struct {
	inProgress map[uuid.UUID]*SagaState  // lost on restart
}
```
**Fix**: every state transition is persisted before proceeding. On restart, query for in-progress sagas and resume from the last durable state.

### 5. Using 2PC Instead of Saga for Cross-Service Operations
Attempting `BEGIN` across two service databases via a shared coordinator will create distributed locks that block scaling and reduce availability. Use the saga pattern and accept that intermediate states are briefly visible.

### 6. Treating Compensation as an Afterthought
Defining compensating transactions after building all forward steps leads to gaps: some steps have no compensation, or compensations are not idempotent. Design compensation for every step at the same time as the step itself.

---

## Decision Matrix

| Scenario | Recommendation |
|----------|---------------|
| 2–3 service transaction, linear, no branching | Choreography saga with domain events |
| 4+ steps, conditional branching, parallel steps | Orchestration saga or Temporal workflow |
| Steps with long waits (webhooks, human approval) | Temporal with signal channels + timeout timers |
| Need full audit trail of saga state changes | Persist saga state + steps in dedicated table |
| High reliability requirement (payment/billing) | Temporal — built-in retries, crash recovery, and history |
| Simple refund/cancel without new steps | Implement as standalone idempotent operation, not saga |
| Event-driven system already using Kafka/SNS | Choreography — event bus already in place |
| Need visibility into in-flight sagas | Orchestration — state machine is observable; add Prometheus metrics |
| Compensations might fail permanently | Dead-letter queue + runbook + on-call alert for manual intervention |
| Multi-tenancy with per-tenant isolation | Namespace sagas by tenant ID; Temporal supports multi-namespace |

---

## Proficiency Levels

### Novice
- Understands why distributed 2PC is problematic (locking, availability coupling)
- Knows the saga definition: local transactions with compensating transactions
- Can identify forward steps and their compensations for a simple flow

### Intermediate
- Implements choreography saga with idempotent event handlers
- Understands the difference between retriable and compensatable failures
- Persists saga state to survive crashes; can resume from last durable checkpoint
- Adds idempotency keys to all external service calls

### Advanced
- Implements orchestration saga with a state machine; handles all compensation paths
- Uses Temporal for durable execution with retries, signals, and timeouts
- Designs the pivot transaction and ensures forward-only handling after it
- Implements a saga recovery job for stuck sagas; monitors with Prometheus alerts
- Handles partially-completed compensations (failed compensation → alert → runbook)

### Expert
- Designs saga boundaries across bounded contexts: knows where to start/stop a saga
- Combines choreography and orchestration within the same system — simple flows use events, complex flows use Temporal
- Applies semantic locking (soft locks on domain objects) to reduce visibility of intermediate states
- Handles cascading sagas (saga A triggers saga B); tracks parent-child relationships
- Designs saga replay and re-hydration for audit and debugging in production

---

## AI Prompts

1. **Saga design review**: "Review this saga: I have steps Reserve→Charge→Ship→Confirm. Which step is the pivot transaction? Is every non-pivot step covered by a compensating transaction? Are any compensations missing or non-idempotent?"

2. **Choreography vs orchestration**: "I'm designing a 5-step saga involving inventory, payment, shipping, notification, and loyalty points. Some steps can run in parallel. Should I use choreography or orchestration? What are the trade-offs for my specific scenario?"

3. **Temporal workflow**: "Convert this Go saga orchestrator to a Temporal workflow. Ensure all activities are idempotent, use proper retry policies for forward steps vs compensations, and add signal handling for a webhook from the payment provider."

4. **Idempotency audit**: "Review my saga step implementations and identify any that are not idempotent. Suggest idempotency key strategies for each."

5. **Stuck saga recovery**: "Design a recovery strategy for sagas that get stuck mid-execution. What should the recovery job do for each possible stuck state? When should it retry vs alert humans?"

---

## References

- Hector Garcia-Molina & Kenneth Salem — *Sagas* (1987 paper) — original Saga definition
- Chris Richardson — *Microservices Patterns* (2018) — chapters on sagas, choreography, orchestration
- Temporal.io documentation — *Workflows, Activities, and Retries*
- Martin Fowler — *ProcessManager* pattern (martinfowler.com)
- Amazon Builder's Library — *Avoiding insurmountable queue backlogs* — idempotency at scale
- Bernd Rücker — *Practical Process Automation* (2021) — BPMN-based workflow orchestration
- Saga pattern with Axon Framework (Java) — reference implementation
