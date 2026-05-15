---
name: Hexagonal & Clean Architecture
slug: hexagonal-clean-architecture
category: 02-architecture-and-design
proficiency: advanced
description: >
  Structure applications around domain logic isolated from infrastructure
  concerns using ports-and-adapters (hexagonal) and layered dependency
  inversion (clean). Covers domain modelling, use-case orchestration,
  adapter implementations, testing strategies, and migration from
  layered monoliths.
tags:
  - hexagonal-architecture
  - clean-architecture
  - domain-driven-design
  - ports-and-adapters
  - dependency-inversion
  - use-cases
  - adapters
  - testability
status: published
---

## Principles

### Core Idea
The application's domain model and business rules are the centre of the universe. All infrastructure — databases, HTTP, message queues, third-party APIs — lives outside the domain and communicates with it through well-defined interfaces (ports). Adapters implement those interfaces for specific technologies.

**Hexagonal architecture** (Alistair Cockburn, 2005): the application has a symmetric ring of ports. Driving ports are called by external actors (HTTP controllers, CLI, tests). Driven ports are called by the application to reach infrastructure (repository, email, payment gateway).

**Clean architecture** (Robert Martin) organises the same idea into concentric rings:
1. **Entities** — enterprise-wide business objects; no framework dependencies
2. **Use cases** — application-specific business rules; orchestrate entities
3. **Interface adapters** — controllers, presenters, gateways; convert between use-case and infrastructure formats
4. **Frameworks & drivers** — web frameworks, ORMs, UI; outermost ring

**The dependency rule**: source code dependencies always point inward. Inner rings know nothing about outer rings.

### Why It Matters
- **Testability**: use cases tested with in-memory fakes; no database or HTTP required
- **Replaceability**: swap PostgreSQL for DynamoDB by writing a new adapter
- **Delay decisions**: defer infrastructure choices until you understand the domain
- **Parallel development**: domain team and infra team work independently once ports are defined

### Key Vocabulary

| Term | Meaning |
|------|---------|
| **Port** | Interface defined by the application (inside the hexagon) |
| **Driving adapter** | Calls the application (e.g., HTTP handler, CLI command, test) |
| **Driven adapter** | Called by the application (e.g., Postgres repo, Stripe client) |
| **Use case / interactor** | Orchestrates domain objects to fulfil one business operation |
| **Domain entity** | Business object with identity, invariants, and behaviour |
| **Value object** | Immutable, identity-less domain concept (Money, Email, OrderId) |
| **Repository port** | Interface for persistence — find/save/delete domain objects |
| **Domain event** | Something that happened in the domain; triggers side effects |

### Invariant: No Outward Leakage
Domain entities must never import framework types (`http.Request`, `gorm.Model`, ORM tags). Use case code must never import concrete infrastructure packages. Violation turns the domain into a ball of mud that can't be unit-tested in isolation.

---

## Implementation Patterns

### Pattern 1 — Canonical Directory Layout (Go)
```
payments-service/
├── cmd/
│   └── server/         # main.go — wires everything, starts HTTP server
├── internal/
│   ├── domain/
│   │   ├── payment/
│   │   │   ├── payment.go        # Payment entity + value objects
│   │   │   ├── events.go         # PaymentCreated, PaymentFailed domain events
│   │   │   └── repository.go     # PaymentRepository port (interface)
│   │   └── account/
│   │       ├── account.go
│   │       └── repository.go
│   ├── application/
│   │   └── payment/
│   │       ├── create_payment.go     # CreatePayment use case
│   │       ├── capture_payment.go    # CapturePayment use case
│   │       └── ports.go              # outbound ports (PaymentGateway, EventPublisher)
│   ├── adapters/
│   │   ├── primary/
│   │   │   ├── http/
│   │   │   │   ├── payment_handler.go
│   │   │   │   └── dto.go            # request/response types — never enter domain
│   │   │   └── grpc/
│   │   │       └── payment_server.go
│   │   └── secondary/
│   │       ├── postgres/
│   │       │   └── payment_repository.go   # implements domain.PaymentRepository
│   │       ├── stripe/
│   │       │   └── gateway.go              # implements application.PaymentGateway
│   │       └── kafka/
│   │           └── event_publisher.go      # implements application.EventPublisher
│   └── config/
│       └── wire.go     # dependency injection / composition root
└── test/
    └── integration/    # adapter tests that hit real infra
```

### Pattern 2 — Domain Entity with Invariants (Go)
```go
// internal/domain/payment/payment.go

package payment

import (
	"errors"
	"time"

	"github.com/google/uuid"
)

// Status is a value object — all valid transitions enforced here.
type Status string

const (
	StatusPending   Status = "pending"
	StatusCaptured  Status = "captured"
	StatusFailed    Status = "failed"
	StatusRefunded  Status = "refunded"
)

// Money is a value object — immutable, self-validating.
type Money struct {
	Amount   int64  // minor units (cents)
	Currency string // ISO 4217
}

func NewMoney(amount int64, currency string) (Money, error) {
	if amount < 0 {
		return Money{}, errors.New("money amount cannot be negative")
	}
	if len(currency) != 3 {
		return Money{}, errors.New("currency must be ISO 4217 3-letter code")
	}
	return Money{Amount: amount, Currency: currency}, nil
}

func (m Money) Add(other Money) (Money, error) {
	if m.Currency != other.Currency {
		return Money{}, errors.New("cannot add different currencies")
	}
	return Money{Amount: m.Amount + other.Amount, Currency: m.Currency}, nil
}

// Payment is the aggregate root — owns invariant enforcement.
type Payment struct {
	id          uuid.UUID
	accountID   uuid.UUID
	amount      Money
	status      Status
	capturedAt  *time.Time
	failReason  string
	events      []DomainEvent // uncommitted domain events
	version     int           // optimistic locking
}

// NewPayment is the factory — the only valid way to create a Payment.
func NewPayment(accountID uuid.UUID, amount Money) (*Payment, error) {
	if amount.Amount <= 0 {
		return nil, errors.New("payment amount must be positive")
	}
	p := &Payment{
		id:        uuid.New(),
		accountID: accountID,
		amount:    amount,
		status:    StatusPending,
		version:   0,
	}
	p.record(PaymentCreated{
		PaymentID: p.id,
		AccountID: accountID,
		Amount:    amount,
	})
	return p, nil
}

// Capture transitions status — enforces the state machine.
func (p *Payment) Capture() error {
	if p.status != StatusPending {
		return ErrInvalidTransition{From: p.status, To: StatusCaptured}
	}
	now := time.Now().UTC()
	p.status = StatusCaptured
	p.capturedAt = &now
	p.record(PaymentCaptured{PaymentID: p.id, CapturedAt: now})
	return nil
}

func (p *Payment) Fail(reason string) error {
	if p.status != StatusPending {
		return ErrInvalidTransition{From: p.status, To: StatusFailed}
	}
	p.status = StatusFailed
	p.failReason = reason
	p.record(PaymentFailed{PaymentID: p.id, Reason: reason})
	return nil
}

// Getters — no setters outside the aggregate.
func (p *Payment) ID() uuid.UUID        { return p.id }
func (p *Payment) Amount() Money        { return p.amount }
func (p *Payment) Status() Status       { return p.status }
func (p *Payment) Version() int         { return p.version }
func (p *Payment) AccountID() uuid.UUID { return p.accountID }

func (p *Payment) PopEvents() []DomainEvent {
	evts := p.events
	p.events = nil
	return evts
}

func (p *Payment) record(e DomainEvent) {
	p.events = append(p.events, e)
}

// ErrInvalidTransition is a domain error — no framework imports.
type ErrInvalidTransition struct {
	From Status
	To   Status
}

func (e ErrInvalidTransition) Error() string {
	return string(e.From) + " → " + string(e.To) + " is not a valid transition"
}
```

### Pattern 3 — Ports and Use Case (Go)
```go
// internal/domain/payment/repository.go — INBOUND port (driven)
package payment

import (
	"context"
	"github.com/google/uuid"
)

type Repository interface {
	FindByID(ctx context.Context, id uuid.UUID) (*Payment, error)
	Save(ctx context.Context, p *Payment) error
	FindPendingOlderThan(ctx context.Context, d time.Duration) ([]*Payment, error)
}

// ─────────────────────────────────────────────────────────────────────────────

// internal/application/payment/ports.go — outbound ports used by use cases
package payment

import (
	"context"
	domainpayment "github.com/example/payments/internal/domain/payment"
)

type PaymentGateway interface {
	Authorize(ctx context.Context, p *domainpayment.Payment) (gatewayRef string, err error)
	Capture(ctx context.Context, gatewayRef string, amount domainpayment.Money) error
	Void(ctx context.Context, gatewayRef string) error
}

type EventPublisher interface {
	Publish(ctx context.Context, events []domainpayment.DomainEvent) error
}

// ─────────────────────────────────────────────────────────────────────────────

// internal/application/payment/create_payment.go — use case
package payment

import (
	"context"
	"fmt"
	"github.com/google/uuid"

	domain "github.com/example/payments/internal/domain/payment"
)

type CreatePaymentInput struct {
	AccountID uuid.UUID
	AmountCents int64
	Currency    string
}

type CreatePaymentOutput struct {
	PaymentID  uuid.UUID
	GatewayRef string
}

// CreatePayment is a use case — it orchestrates domain objects and calls ports.
// It has NO knowledge of HTTP, databases, or Stripe.
type CreatePayment struct {
	repo      domain.Repository  // driven port
	gateway   PaymentGateway     // driven port
	publisher EventPublisher     // driven port
}

func NewCreatePayment(repo domain.Repository, gw PaymentGateway, pub EventPublisher) *CreatePayment {
	return &CreatePayment{repo: repo, gateway: gw, publisher: pub}
}

func (uc *CreatePayment) Execute(ctx context.Context, in CreatePaymentInput) (CreatePaymentOutput, error) {
	amount, err := domain.NewMoney(in.AmountCents, in.Currency)
	if err != nil {
		return CreatePaymentOutput{}, fmt.Errorf("invalid amount: %w", err)
	}

	payment, err := domain.NewPayment(in.AccountID, amount)
	if err != nil {
		return CreatePaymentOutput{}, fmt.Errorf("create payment: %w", err)
	}

	ref, err := uc.gateway.Authorize(ctx, payment)
	if err != nil {
		_ = payment.Fail("gateway authorization failed: " + err.Error())
		_ = uc.repo.Save(ctx, payment)
		return CreatePaymentOutput{}, fmt.Errorf("authorize payment: %w", err)
	}

	if err := uc.repo.Save(ctx, payment); err != nil {
		return CreatePaymentOutput{}, fmt.Errorf("save payment: %w", err)
	}

	if err := uc.publisher.Publish(ctx, payment.PopEvents()); err != nil {
		// non-fatal: event publishing failure is retried asynchronously via outbox
		// log warning here in real code
	}

	return CreatePaymentOutput{PaymentID: payment.ID(), GatewayRef: ref}, nil
}
```

### Pattern 4 — Adapters (PostgreSQL + HTTP)
```go
// internal/adapters/secondary/postgres/payment_repository.go
package postgres

import (
	"context"
	"database/sql"
	"errors"
	"time"

	"github.com/google/uuid"
	domain "github.com/example/payments/internal/domain/payment"
)

// paymentRow is the ORM/SQL model — never enters the domain.
type paymentRow struct {
	ID          uuid.UUID      `db:"id"`
	AccountID   uuid.UUID      `db:"account_id"`
	AmountCents int64          `db:"amount_cents"`
	Currency    string         `db:"currency"`
	Status      string         `db:"status"`
	CapturedAt  sql.NullTime   `db:"captured_at"`
	FailReason  sql.NullString `db:"fail_reason"`
	Version     int            `db:"version"`
}

type PaymentRepository struct {
	db *sql.DB
}

func NewPaymentRepository(db *sql.DB) *PaymentRepository {
	return &PaymentRepository{db: db}
}

// Implements domain.Repository — the adapter translates between SQL rows and domain objects.
func (r *PaymentRepository) FindByID(ctx context.Context, id uuid.UUID) (*domain.Payment, error) {
	var row paymentRow
	err := r.db.QueryRowContext(ctx,
		`SELECT id, account_id, amount_cents, currency, status, captured_at, fail_reason, version
		 FROM payments WHERE id = $1`, id,
	).Scan(&row.ID, &row.AccountID, &row.AmountCents, &row.Currency,
		&row.Status, &row.CapturedAt, &row.FailReason, &row.Version)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, domain.ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	return reconstitute(row)
}

func (r *PaymentRepository) Save(ctx context.Context, p *domain.Payment) error {
	_, err := r.db.ExecContext(ctx, `
		INSERT INTO payments (id, account_id, amount_cents, currency, status, version)
		VALUES ($1, $2, $3, $4, $5, $6)
		ON CONFLICT (id) DO UPDATE
		  SET status = EXCLUDED.status,
		      captured_at = EXCLUDED.captured_at,
		      fail_reason = EXCLUDED.fail_reason,
		      version = payments.version + 1
		WHERE payments.version = $7`,
		p.ID(), p.AccountID(), p.Amount().Amount, p.Amount().Currency,
		string(p.Status()), p.Version()+1, p.Version(),
	)
	return err
}

func (r *PaymentRepository) FindPendingOlderThan(ctx context.Context, d time.Duration) ([]*domain.Payment, error) {
	rows, err := r.db.QueryContext(ctx,
		`SELECT id, account_id, amount_cents, currency, status, captured_at, fail_reason, version
		 FROM payments WHERE status = 'pending' AND created_at < $1`, time.Now().UTC().Add(-d))
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var payments []*domain.Payment
	for rows.Next() {
		var row paymentRow
		if err := rows.Scan(&row.ID, &row.AccountID, &row.AmountCents, &row.Currency,
			&row.Status, &row.CapturedAt, &row.FailReason, &row.Version); err != nil {
			return nil, err
		}
		p, err := reconstitute(row)
		if err != nil {
			return nil, err
		}
		payments = append(payments, p)
	}
	return payments, rows.Err()
}

// reconstitute rebuilds a domain object from a DB row — uses domain's Reconstitute factory.
func reconstitute(row paymentRow) (*domain.Payment, error) {
	amount, err := domain.NewMoney(row.AmountCents, row.Currency)
	if err != nil {
		return nil, err
	}
	return domain.Reconstitute(domain.ReconstitutionInput{
		ID:         row.ID,
		AccountID:  row.AccountID,
		Amount:     amount,
		Status:     domain.Status(row.Status),
		Version:    row.Version,
	}), nil
}

// ─────────────────────────────────────────────────────────────────────────────

// internal/adapters/primary/http/payment_handler.go
package http

import (
	"encoding/json"
	"net/http"

	"github.com/google/uuid"
	appPayment "github.com/example/payments/internal/application/payment"
)

// createPaymentRequest is a DTO — never enters the domain or use case layer.
type createPaymentRequest struct {
	AccountID   string `json:"account_id"`
	AmountCents int64  `json:"amount_cents"`
	Currency    string `json:"currency"`
}

type createPaymentResponse struct {
	PaymentID  string `json:"payment_id"`
	GatewayRef string `json:"gateway_ref"`
}

type PaymentHandler struct {
	createPayment *appPayment.CreatePayment
}

func NewPaymentHandler(cp *appPayment.CreatePayment) *PaymentHandler {
	return &PaymentHandler{createPayment: cp}
}

func (h *PaymentHandler) Create(w http.ResponseWriter, r *http.Request) {
	var req createPaymentRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "invalid request body", http.StatusBadRequest)
		return
	}

	accountID, err := uuid.Parse(req.AccountID)
	if err != nil {
		http.Error(w, "invalid account_id", http.StatusBadRequest)
		return
	}

	out, err := h.createPayment.Execute(r.Context(), appPayment.CreatePaymentInput{
		AccountID:   accountID,
		AmountCents: req.AmountCents,
		Currency:    req.Currency,
	})
	if err != nil {
		// map domain errors to HTTP status codes here
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	_ = json.NewEncoder(w).Encode(createPaymentResponse{
		PaymentID:  out.PaymentID.String(),
		GatewayRef: out.GatewayRef,
	})
}
```

### Pattern 5 — Testing with In-Memory Fakes
```go
// test/fakes/payment_repository.go — in-memory fake implementing domain.Repository
package fakes

import (
	"context"
	"sync"
	"time"

	"github.com/google/uuid"
	domain "github.com/example/payments/internal/domain/payment"
)

type InMemoryPaymentRepository struct {
	mu       sync.RWMutex
	payments map[uuid.UUID]*domain.Payment
}

func NewInMemoryPaymentRepository() *InMemoryPaymentRepository {
	return &InMemoryPaymentRepository{payments: make(map[uuid.UUID]*domain.Payment)}
}

func (r *InMemoryPaymentRepository) FindByID(_ context.Context, id uuid.UUID) (*domain.Payment, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	p, ok := r.payments[id]
	if !ok {
		return nil, domain.ErrNotFound
	}
	return p, nil
}

func (r *InMemoryPaymentRepository) Save(_ context.Context, p *domain.Payment) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.payments[p.ID()] = p
	return nil
}

func (r *InMemoryPaymentRepository) FindPendingOlderThan(_ context.Context, d time.Duration) ([]*domain.Payment, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	var out []*domain.Payment
	for _, p := range r.payments {
		if p.Status() == domain.StatusPending {
			out = append(out, p)
		}
	}
	return out, nil
}

// ─────────────────────────────────────────────────────────────────────────────

// test/fakes/payment_gateway.go
package fakes

import (
	"context"
	"fmt"

	domain "github.com/example/payments/internal/domain/payment"
)

type StubPaymentGateway struct {
	ShouldFail  bool
	AuthorizeID string
}

func (g *StubPaymentGateway) Authorize(_ context.Context, p *domain.Payment) (string, error) {
	if g.ShouldFail {
		return "", fmt.Errorf("gateway unavailable")
	}
	ref := "gw-" + p.ID().String()[:8]
	if g.AuthorizeID != "" {
		ref = g.AuthorizeID
	}
	return ref, nil
}
func (g *StubPaymentGateway) Capture(_ context.Context, _ string, _ domain.Money) error { return nil }
func (g *StubPaymentGateway) Void(_ context.Context, _ string) error                    { return nil }

// ─────────────────────────────────────────────────────────────────────────────

// internal/application/payment/create_payment_test.go
package payment_test

import (
	"context"
	"testing"

	"github.com/google/uuid"
	app "github.com/example/payments/internal/application/payment"
	"github.com/example/payments/test/fakes"
)

func TestCreatePayment_Success(t *testing.T) {
	repo := fakes.NewInMemoryPaymentRepository()
	gw := &fakes.StubPaymentGateway{}
	pub := &fakes.NoopEventPublisher{}

	uc := app.NewCreatePayment(repo, gw, pub)
	out, err := uc.Execute(context.Background(), app.CreatePaymentInput{
		AccountID:   uuid.New(),
		AmountCents: 5000,
		Currency:    "USD",
	})

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if out.PaymentID == uuid.Nil {
		t.Error("expected a payment ID")
	}

	saved, _ := repo.FindByID(context.Background(), out.PaymentID)
	if saved.Status() != domain.StatusPending {
		t.Errorf("expected pending, got %s", saved.Status())
	}
}

func TestCreatePayment_GatewayFailure(t *testing.T) {
	repo := fakes.NewInMemoryPaymentRepository()
	gw := &fakes.StubPaymentGateway{ShouldFail: true}
	pub := &fakes.NoopEventPublisher{}

	uc := app.NewCreatePayment(repo, gw, pub)
	_, err := uc.Execute(context.Background(), app.CreatePaymentInput{
		AccountID:   uuid.New(),
		AmountCents: 1000,
		Currency:    "USD",
	})

	if err == nil {
		t.Fatal("expected error from gateway failure")
	}
}

func TestCreatePayment_InvalidCurrency(t *testing.T) {
	repo := fakes.NewInMemoryPaymentRepository()
	gw := &fakes.StubPaymentGateway{}
	pub := &fakes.NoopEventPublisher{}

	uc := app.NewCreatePayment(repo, gw, pub)
	_, err := uc.Execute(context.Background(), app.CreatePaymentInput{
		AccountID:   uuid.New(),
		AmountCents: 1000,
		Currency:    "US",   // invalid — not 3 chars
	})

	if err == nil {
		t.Fatal("expected validation error for invalid currency")
	}
}
```

### Pattern 6 — Composition Root & Dependency Wiring
```go
// cmd/server/main.go — the only place that imports everything
package main

import (
	"database/sql"
	"log"
	"net/http"
	"os"
	"time"

	_ "github.com/lib/pq"

	"github.com/example/payments/internal/adapters/primary/httphandler"
	postgresadapter "github.com/example/payments/internal/adapters/secondary/postgres"
	stripeadapter "github.com/example/payments/internal/adapters/secondary/stripe"
	kafkaadapter "github.com/example/payments/internal/adapters/secondary/kafka"
	appPayment "github.com/example/payments/internal/application/payment"
)

func main() {
	// Infrastructure — built first, passed inward (never the reverse)
	db, err := sql.Open("postgres", os.Getenv("DATABASE_URL"))
	if err != nil {
		log.Fatalf("db open: %v", err)
	}
	db.SetMaxOpenConns(25)
	db.SetConnMaxLifetime(5 * time.Minute)

	// Secondary adapters (driven ports — implement domain/application interfaces)
	paymentRepo := postgresadapter.NewPaymentRepository(db)
	gateway := stripeadapter.NewGateway(os.Getenv("STRIPE_API_KEY"))
	publisher := kafkaadapter.NewEventPublisher(os.Getenv("KAFKA_BROKERS"))

	// Use cases — pure application logic, wired with adapters
	createPayment := appPayment.NewCreatePayment(paymentRepo, gateway, publisher)
	capturePayment := appPayment.NewCapturePayment(paymentRepo, gateway, publisher)

	// Primary adapters (driving ports — call use cases)
	paymentHandler := httphandler.NewPaymentHandler(createPayment, capturePayment)

	mux := http.NewServeMux()
	mux.HandleFunc("POST /payments", paymentHandler.Create)
	mux.HandleFunc("POST /payments/{id}/capture", paymentHandler.Capture)

	log.Println("listening on :8080")
	if err := http.ListenAndServe(":8080", mux); err != nil {
		log.Fatalf("server: %v", err)
	}
}
```

---

## Anti-Patterns

### 1. Domain Importing Infrastructure
```go
// WRONG — domain entity importing a database package
import "gorm.io/gorm"

type Payment struct {
	gorm.Model          // ORM concerns leak into domain
	Amount float64      `gorm:"column:amount"`
}
```
**Fix**: keep domain structs free of tags and framework types. Use a separate `paymentRow` struct in the adapter for DB mapping.

### 2. Fat Controller / Anemic Domain
```go
// WRONG — business logic in the HTTP handler
func (h *Handler) CreatePayment(w http.ResponseWriter, r *http.Request) {
	// validation, DB calls, gateway calls, status transitions all inline
	if req.Amount <= 0 { ... }
	db.Exec("INSERT INTO payments ...")
	stripe.Charge(...)
	db.Exec("UPDATE payments SET status = 'captured'")
}
```
**Fix**: the handler does only: parse → call use case → write response. All orchestration moves to use cases; all rules move to domain entities.

### 3. Use Case Calling Another Use Case
```go
// WRONG — use cases orchestrating each other create coupling
func (uc *CapturePayment) Execute(ctx context.Context, id uuid.UUID) error {
	notifyUC := NewSendNotification(...)  // ← creates a dependency between use cases
	notifyUC.Execute(ctx, ...)
}
```
**Fix**: publish a domain event from the first use case. A separate event handler / subscriber invokes the notification use case asynchronously.

### 4. Leaking Domain Types Through HTTP DTOs
```go
// WRONG — exposing domain internals in API response
func handler(w http.ResponseWriter, r *http.Request) {
	payment := useCase.Execute(...)
	json.NewEncoder(w).Encode(payment)  // leaks domain struct + private fields
}
```
**Fix**: map use case output to a dedicated DTO struct. Domain changes don't accidentally change the API contract.

### 5. Bypassing Ports with Direct Infrastructure Calls
```go
// WRONG — use case directly importing an infrastructure package
import "github.com/example/payments/internal/adapters/secondary/postgres"

func (uc *CreatePayment) Execute(ctx context.Context, in Input) (Output, error) {
	repo := postgres.NewPaymentRepository(...)  // ← depends on concrete adapter
}
```
**Fix**: use cases receive their dependencies injected through interfaces (ports). They never instantiate adapters.

### 6. Putting Domain Logic in Repositories
```go
// WRONG — business rule in repository
func (r *PostgresRepo) Save(ctx context.Context, p *Payment) error {
	if p.Amount > 10000 {   // ← this is a business rule, not a persistence concern
		return errors.New("payment exceeds limit")
	}
	...
}
```
**Fix**: enforce all business invariants in the domain entity or use case. Repositories only translate between domain objects and storage representations.

---

## Decision Matrix

| Scenario | Recommendation |
|----------|---------------|
| Greenfield service with non-trivial domain | Full hexagonal — domain → application → adapters |
| CRUD-only microservice with no business rules | Standard layered (controller → service → repo); hexagonal overhead not justified |
| Adding domain logic to an existing layered monolith | Introduce ports incrementally for the complex subdomain; don't migrate everything |
| Multiple delivery mechanisms (HTTP + gRPC + CLI) | Hexagonal shines — same use cases, different primary adapters |
| Swapping infrastructure (e.g., Postgres → DynamoDB) | Hexagonal — write new secondary adapter; zero domain changes |
| High-frequency trading / latency-critical path | Evaluate indirection cost; may need to collapse layers in hot path |
| Shared domain across bounded contexts | Define separate hexagons per bounded context; use ACL adapters at context boundaries |
| Team < 3 engineers, startup MVP | Consider simpler structure; introduce hexagonal if/when domain complexity grows |
| Complex domain (payments, insurance, ERP) | Hexagonal + DDD — entities, aggregates, domain events pay off |
| Microservices talking to each other | Each service is its own hexagon; inter-service calls happen through secondary port adapters |

---

## Proficiency Levels

### Novice
- Understands the layered architecture concept (controller → service → repository)
- Can identify why putting SQL in controllers is a problem
- Knows what an interface is and how it enables testability

### Intermediate
- Can define domain entities with private fields and factory methods
- Writes use cases that call ports (interfaces), not concrete adapters
- Builds in-memory fakes for unit tests
- Understands the dependency rule: inner rings never import outer rings

### Advanced
- Designs aggregate roots with proper invariant enforcement and optimistic locking
- Implements the reconstitution pattern to separate persistence from construction
- Publishes domain events from aggregates; event handlers as separate use cases
- Structures bounded contexts as independent hexagons with ACL adapters at boundaries
- Migrates existing layered code to hexagonal incrementally, subdomain by subdomain

### Expert
- Applies hexagonal architecture at the module/service boundary: each bounded context is a deployable hexagon with versioned ports
- Combines with CQRS: separate write model (domain + use cases) from read model (optimised query adapters)
- Enforces architecture fitness functions (ArchUnit / Go `internal` package restrictions) in CI
- Designs the composition root for large systems using DI containers while keeping the domain framework-free
- Identifies when to deviate (latency-critical paths, simple CRUD) and documents the trade-off explicitly

---

## AI Prompts

1. **Domain model review**: "Review this Go domain entity for architecture violations: does it leak infrastructure concerns? Does it enforce all invariants via factory methods and state-transition methods? Does it expose only getters, never setters?"

2. **Port design**: "I have this use case that needs to send an email, fetch exchange rates, and persist a payment. Help me define the minimum set of driven ports (interfaces) it needs, with correct naming conventions and method signatures."

3. **Adapter completeness**: "Here is my domain repository interface and my PostgreSQL adapter. Check that every interface method is correctly implemented, that the reconstitution logic is complete, and that no domain types leak into SQL query code."

4. **Migration strategy**: "I have a layered Node.js service (Express → service class → Sequelize) with business logic spread across controllers and service methods. Propose a step-by-step migration plan to hexagonal architecture with zero downtime and testable increments."

5. **Test coverage design**: "For this use case, generate a complete set of unit tests using in-memory fakes that cover: the happy path, each error branch, invalid input, and a concurrent-save scenario. No database or HTTP server should be required."

---

## References

- Alistair Cockburn — *Hexagonal Architecture* (original 2005 article, alistair.cockburn.us)
- Robert C. Martin — *Clean Architecture: A Craftsman's Guide to Software Structure and Design* (2017)
- Vaughn Vernon — *Implementing Domain-Driven Design* (2013) — aggregates, domain events, bounded contexts
- Eric Evans — *Domain-Driven Design: Tackling Complexity in the Heart of Software* (2003)
- Netflix Tech Blog — *Ready for changes with Hexagonal Architecture*
- Go `internal` package visibility — enforces package-level dependency rules at compile time
- ArchUnit (Java) / `go-arch-lint` — automated architecture fitness functions in CI
