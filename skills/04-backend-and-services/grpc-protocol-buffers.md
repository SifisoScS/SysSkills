---
name: gRPC & Protocol Buffers
slug: grpc-protocol-buffers
category: 04-backend-and-services
proficiency: advanced
description: >
  Design and implement gRPC services using Protocol Buffers (proto3): schema
  design, the buf toolchain (lint, breaking-change detection, BSR), all four
  RPC streaming modes, interceptor chains (auth, tracing, retry, validation),
  deadlines and cancellation propagation, gRPC-Web for browsers, health
  checking, server reflection, and production patterns for Go and TypeScript.
tags:
  - grpc
  - protobuf
  - proto3
  - buf
  - streaming
  - interceptors
  - service-mesh
  - go
  - typescript
  - rpc
status: complete
---

## Principles

### Why gRPC over REST for Internal Services
| Dimension | REST/JSON | gRPC/Protobuf |
|---|---|---|
| Wire format | Text (JSON) | Binary (Protobuf) — 3–10× smaller |
| Schema | Optional (OpenAPI) | Mandatory (`.proto`) — enforced |
| Code generation | Optional | First-class; clients/servers generated |
| Streaming | Polling or WebSocket | Native 4 streaming modes |
| Multiplexing | HTTP/1.1: head-of-line blocking | HTTP/2: multiplexed streams |
| Breaking-change detection | Runtime | Compile-time + `buf breaking` |
| Browser support | Native | Requires gRPC-Web proxy |

Use gRPC for: service-to-service internal APIs, streaming (logs, events, ML inference), polyglot teams needing a contract-first schema, latency-sensitive paths.
Use REST for: public APIs, browser-native access, simple CRUD without streaming.

### Proto3 Field Rules
- **No `required` fields** — proto3 removed them; all fields are optional with zero defaults
- **Never reuse field numbers** — old numbers are reserved in wire format; reusing causes silent data corruption
- **Use `reserved`** — mark deleted field numbers and names to prevent future reuse
- **Prefer explicit defaults** — proto3 zero values (`0`, `""`, `false`) are indistinguishable from unset; use `google.protobuf.Int32Value` wrapper types or `optional` keyword when "not set" is semantically different from zero
- **Package naming** — `company.domain.version` (e.g., `payments.v1`); affects generated import paths

### Protobuf Schema Evolution (Backward/Forward Compatibility)
| Change | Safe? | Why |
|---|---|---|
| Add new field (new number) | ✅ | Old clients ignore unknown fields |
| Remove field, mark `reserved` | ✅ | Old clients keep old field; new clients ignore it |
| Rename field (same number) | ✅ | Wire format uses numbers, not names |
| Change field type (e.g., `int32` → `int64`) | ⚠️ | Same wire type = silent truncation; different wire type = parse error |
| Reuse a field number | ❌ | Wire conflict; data corruption |
| Change `repeated` to singular | ❌ | Only last element retained |
| Change `oneof` membership | ❌ | Encoding changes |

### HTTP/2 Multiplexing
gRPC runs over HTTP/2. Multiple RPC streams share one TCP connection. Each stream has an independent flow-control window. Head-of-line blocking (HTTP/1.1's key flaw) is eliminated at the application layer — a slow streaming RPC does not block a fast unary RPC on the same connection.

### Four Streaming Modes
```
Unary:               Client → [request] → Server → [response]
Server streaming:    Client → [request] → Server → [response …]
Client streaming:    Client → [request …] → Server → [response]
Bidirectional:       Client ↔ [request … / response …] → Server
```

---

## Implementation Patterns

### 1. Schema-First with buf
`buf` replaces manual `protoc` invocations. `buf.yaml` defines the module; `buf.gen.yaml` drives code generation; `buf lint` enforces Protobuf style; `buf breaking` detects incompatible API changes against the BSR (Buf Schema Registry) or a git baseline.

### 2. Interceptor Chains
gRPC interceptors are the equivalent of HTTP middleware. Unary and stream interceptors are separate. Chain them: auth → tracing → logging → validation → retry. The chain wraps the handler symmetrically — each interceptor can act before and after the handler.

### 3. Deadlines and Cancellation
Every gRPC call should carry a deadline. When a deadline is exceeded, the context is cancelled and propagated downstream — if service A calls B calls C, all three cancel simultaneously. Never start an operation if `ctx.Err() != nil` on entry.

### 4. Health Checking Protocol
gRPC defines a standard `grpc.health.v1.Health` service. Kubernetes liveness/readiness probes, load balancers, and service meshes use this to drain traffic from unhealthy instances without a custom `/healthz` endpoint per service.

### 5. Server Reflection
`grpc.reflection.v1alpha` allows clients (grpcurl, Evans, BloomRPC) to discover the service schema at runtime without needing the `.proto` file. Enable only in non-production environments or behind auth.

### 6. gRPC-Web
Browsers cannot use HTTP/2 trailers (required by gRPC). gRPC-Web uses a proxy (Envoy or `grpc-web` npm package) that translates between gRPC-Web (HTTP/1.1 compatible) and gRPC. The Protobuf wire format is preserved end-to-end.

---

## Anti-Patterns

| Anti-Pattern | Why It Fails | Correction |
|---|---|---|
| **Reusing field numbers** | Silent wire-format corruption; undetectable at runtime | Mark deleted numbers with `reserved`; `buf breaking` enforces this |
| **No deadlines on client calls** | Cascading latency; hung goroutines accumulate | Always set `context.WithTimeout` before every gRPC call |
| **Passing `context.Background()` through layers** | Deadline and cancellation lost at service boundary | Propagate the incoming request context to downstream calls |
| **Large messages in unary RPC** | gRPC default max message: 4 MB; large payloads fail silently or error | Use server-streaming for large payloads; chunk data |
| **Reflection enabled in production** | Exposes full API schema to anyone who can reach the port | Disable reflection or gate behind internal-network-only policy |
| **No interceptor for auth** | Each handler re-implements auth independently; easy to miss | Centralise auth in a unary + stream interceptor pair |
| **Ignoring gRPC status codes** | Mapping all errors to `INTERNAL`; clients can't retry intelligently | Use semantic codes: `NOT_FOUND`, `ALREADY_EXISTS`, `PERMISSION_DENIED`, `UNAVAILABLE` |
| **Protobuf timestamps as strings** | Time zone ambiguity; no comparison semantics | Use `google.protobuf.Timestamp` |
| **Generated code committed to repo** | Drift between `.proto` and generated code; merge conflicts | Generate in CI from `.proto` sources; `.gitignore` generated files |
| **One giant `.proto` file** | Merge conflicts; slow codegen; unclear ownership | One `.proto` per service or resource type; import shared types from a common package |

---

## Code Templates

### Template 1 — Proto3 Schema + buf Configuration

```protobuf
// proto/payments/v1/payments.proto
syntax = "proto3";

package payments.v1;

import "google/protobuf/timestamp.proto";
import "google/protobuf/wrappers.proto";

option go_package = "github.com/org/payments-service/gen/go/payments/v1;paymentsv1";

// PaymentsService handles payment initiation and status queries.
service PaymentsService {
  // Initiate a payment (unary)
  rpc InitiatePayment(InitiatePaymentRequest) returns (InitiatePaymentResponse);

  // Stream real-time status updates for a payment (server streaming)
  rpc WatchPaymentStatus(WatchPaymentStatusRequest) returns (stream PaymentStatusEvent);

  // Bulk upload payment instructions (client streaming)
  rpc UploadPaymentBatch(stream PaymentInstruction) returns (UploadBatchResponse);

  // Bidirectional: real-time fraud scoring
  rpc StreamFraudScoring(stream FraudScoringRequest) returns (stream FraudScoringResponse);
}

message InitiatePaymentRequest {
  string          idempotency_key = 1; // client-generated; server deduplicates
  string          payer_account   = 2;
  string          payee_account   = 3;
  MonetaryAmount  amount          = 4;
  string          reference       = 5;
}

message InitiatePaymentResponse {
  string                     payment_id  = 1;
  PaymentStatus              status      = 2;
  google.protobuf.Timestamp  created_at  = 3;
}

message WatchPaymentStatusRequest {
  string payment_id = 1;
}

message PaymentStatusEvent {
  string                     payment_id  = 1;
  PaymentStatus              status      = 2;
  google.protobuf.Timestamp  occurred_at = 3;
  string                     reason      = 4; // set on FAILED / REJECTED
}

message PaymentInstruction {
  string         idempotency_key = 1;
  string         payer_account   = 2;
  string         payee_account   = 3;
  MonetaryAmount amount          = 4;
}

message UploadBatchResponse {
  int32 accepted = 1;
  int32 rejected = 2;
  repeated string rejection_reasons = 3;
}

message FraudScoringRequest {
  string         transaction_id = 1;
  MonetaryAmount amount         = 2;
  string         merchant_id    = 3;
  string         device_id      = 4;
}

message FraudScoringResponse {
  string transaction_id = 1;
  double risk_score     = 2;  // 0.0 – 1.0
  bool   block          = 3;
  string reason         = 4;
}

message MonetaryAmount {
  int64  units        = 1; // major units (e.g., Rand)
  int32  nano_units   = 2; // fractional (1 Rand = 10^9 nano_units)
  string currency_code= 3; // ISO 4217: "ZAR", "USD"
}

enum PaymentStatus {
  PAYMENT_STATUS_UNSPECIFIED = 0;
  PAYMENT_STATUS_PENDING     = 1;
  PAYMENT_STATUS_PROCESSING  = 2;
  PAYMENT_STATUS_COMPLETED   = 3;
  PAYMENT_STATUS_FAILED      = 4;
  PAYMENT_STATUS_REJECTED    = 5;
}

// Reserved deleted fields — NEVER reuse these numbers or names
reserved 6, 7;
reserved "legacy_fee", "old_reference";
```

```yaml
# buf.yaml
version: v2
modules:
  - path: proto
deps:
  - buf.build/googleapis/googleapis    # for google.protobuf.* types
lint:
  use:
    - STANDARD
  except:
    - UNARY_RPC               # allow streaming-only services if needed
breaking:
  use:
    - FILE                    # enforce file-level compatibility (field numbers, types)
```

```yaml
# buf.gen.yaml
version: v2
managed:
  enabled: true
  override:
    - file_option: go_package_prefix
      value: github.com/org/payments-service/gen/go
plugins:
  - remote: buf.build/protocolbuffers/go
    out: gen/go
    opt: paths=source_relative
  - remote: buf.build/grpc/go
    out: gen/go
    opt: paths=source_relative
  - remote: buf.build/connectrpc/go    # optional: Connect protocol (REST + gRPC)
    out: gen/go
    opt: paths=source_relative
  # TypeScript (for frontend/BFF)
  - remote: buf.build/protocolbuffers/ts
    out: gen/ts
  - remote: buf.build/grpc/web
    out: gen/ts
    opt: import_style=commonjs+dts,mode=grpcweb
```

```makefile
# Makefile targets
.PHONY: proto-gen proto-lint proto-breaking

proto-gen:
	buf generate

proto-lint:
	buf lint

proto-breaking:
	buf breaking --against '.git#branch=main'   # compare against main branch

proto-push:
	buf push    # push to BSR (Buf Schema Registry) — only in CI
```

---

### Template 2 — Go gRPC Server with Interceptor Chain

```go
// internal/server/server.go
package server

import (
	"context"
	"log/slog"
	"net"
	"time"

	"go.opentelemetry.io/contrib/instrumentation/google.golang.org/grpc/otelgrpc"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/health"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
	"google.golang.org/grpc/keepalive"
	"google.golang.org/grpc/reflection"
	"google.golang.org/grpc/status"

	paymentsv1 "github.com/org/payments-service/gen/go/payments/v1"
)

func New(svc paymentsv1.PaymentsServiceServer, env string) *grpc.Server {
	srv := grpc.NewServer(
		// Interceptor chain: OTel tracing → auth → logging → recovery
		grpc.ChainUnaryInterceptor(
			otelgrpc.UnaryServerInterceptor(),
			authUnaryInterceptor,
			loggingUnaryInterceptor,
			recoveryUnaryInterceptor,
		),
		grpc.ChainStreamInterceptor(
			otelgrpc.StreamServerInterceptor(),
			authStreamInterceptor,
			loggingStreamInterceptor,
		),
		grpc.KeepaliveParams(keepalive.ServerParameters{
			MaxConnectionIdle: 15 * time.Minute,
			Time:              5 * time.Minute,
			Timeout:           20 * time.Second,
		}),
		grpc.KeepaliveEnforcementPolicy(keepalive.EnforcementPolicy{
			MinTime:             5 * time.Second,
			PermitWithoutStream: true,
		}),
		grpc.MaxRecvMsgSize(4 * 1024 * 1024),  // 4 MB
		grpc.MaxSendMsgSize(4 * 1024 * 1024),
	)

	paymentsv1.RegisterPaymentsServiceServer(srv, svc)

	// Standard health service
	hs := health.NewServer()
	hs.SetServingStatus("payments.v1.PaymentsService", healthpb.HealthCheckResponse_SERVING)
	healthpb.RegisterHealthServer(srv, hs)

	// Reflection only in non-production
	if env != "production" {
		reflection.Register(srv)
	}

	return srv
}

func Serve(srv *grpc.Server, addr string) error {
	lis, err := net.Listen("tcp", addr)
	if err != nil {
		return err
	}
	slog.Info("gRPC server listening", "addr", addr)
	return srv.Serve(lis)
}

// ── Interceptors ──────────────────────────────────────────────────────────────

func authUnaryInterceptor(
	ctx context.Context,
	req any,
	info *grpc.UnaryServerInfo,
	handler grpc.UnaryHandler,
) (any, error) {
	if err := validateToken(ctx); err != nil {
		return nil, status.Errorf(codes.Unauthenticated, "auth: %v", err)
	}
	return handler(ctx, req)
}

func authStreamInterceptor(
	srv any,
	ss grpc.ServerStream,
	info *grpc.StreamServerInfo,
	handler grpc.StreamHandler,
) error {
	if err := validateToken(ss.Context()); err != nil {
		return status.Errorf(codes.Unauthenticated, "auth: %v", err)
	}
	return handler(srv, ss)
}

func loggingUnaryInterceptor(
	ctx context.Context,
	req any,
	info *grpc.UnaryServerInfo,
	handler grpc.UnaryHandler,
) (any, error) {
	start := time.Now()
	resp, err := handler(ctx, req)
	code := status.Code(err)
	slog.InfoContext(ctx, "grpc unary",
		"method", info.FullMethod,
		"code", code.String(),
		"duration_ms", time.Since(start).Milliseconds(),
	)
	return resp, err
}

func loggingStreamInterceptor(
	srv any,
	ss grpc.ServerStream,
	info *grpc.StreamServerInfo,
	handler grpc.StreamHandler,
) error {
	start := time.Now()
	err := handler(srv, ss)
	slog.InfoContext(ss.Context(), "grpc stream",
		"method", info.FullMethod,
		"code", status.Code(err).String(),
		"duration_ms", time.Since(start).Milliseconds(),
	)
	return err
}

func recoveryUnaryInterceptor(
	ctx context.Context,
	req any,
	_ *grpc.UnaryServerInfo,
	handler grpc.UnaryHandler,
) (resp any, err error) {
	defer func() {
		if r := recover(); r != nil {
			slog.ErrorContext(ctx, "panic recovered", "panic", r)
			err = status.Errorf(codes.Internal, "internal error")
		}
	}()
	return handler(ctx, req)
}

func validateToken(ctx context.Context) error {
	// Wire up your JWT validator here (see api-security-rate-limiting skill)
	return nil
}
```

---

### Template 3 — Go gRPC Service Implementation (All 4 Streaming Modes)

```go
// internal/payments/service.go
package payments

import (
	"context"
	"io"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/timestamppb"

	paymentsv1 "github.com/org/payments-service/gen/go/payments/v1"
)

type Service struct {
	paymentsv1.UnimplementedPaymentsServiceServer
	repo        PaymentRepository
	fraudClient FraudScorerClient
	events      EventPublisher
}

// ── Unary ─────────────────────────────────────────────────────────────────────

func (s *Service) InitiatePayment(
	ctx context.Context,
	req *paymentsv1.InitiatePaymentRequest,
) (*paymentsv1.InitiatePaymentResponse, error) {
	if req.IdempotencyKey == "" {
		return nil, status.Error(codes.InvalidArgument, "idempotency_key is required")
	}

	// Idempotency: return existing result if key already processed
	if existing, err := s.repo.FindByIdempotencyKey(ctx, req.IdempotencyKey); err == nil {
		return existing, nil
	}

	payment, err := s.repo.Create(ctx, req)
	if err != nil {
		return nil, status.Errorf(codes.Internal, "create payment: %v", err)
	}

	return &paymentsv1.InitiatePaymentResponse{
		PaymentId: payment.ID,
		Status:    paymentsv1.PaymentStatus_PAYMENT_STATUS_PENDING,
		CreatedAt: timestamppb.Now(),
	}, nil
}

// ── Server Streaming ──────────────────────────────────────────────────────────

func (s *Service) WatchPaymentStatus(
	req *paymentsv1.WatchPaymentStatusRequest,
	stream paymentsv1.PaymentsService_WatchPaymentStatusServer,
) error {
	ctx := stream.Context()

	sub, err := s.events.Subscribe(ctx, "payment.status."+req.PaymentId)
	if err != nil {
		return status.Errorf(codes.Internal, "subscribe: %v", err)
	}
	defer sub.Close()

	for {
		select {
		case <-ctx.Done():
			return status.FromContextError(ctx.Err()).Err()

		case event, ok := <-sub.Events():
			if !ok {
				return nil // subscription closed (payment reached terminal state)
			}
			if err := stream.Send(&paymentsv1.PaymentStatusEvent{
				PaymentId:  req.PaymentId,
				Status:     event.Status,
				OccurredAt: timestamppb.New(event.At),
				Reason:     event.Reason,
			}); err != nil {
				return err // client disconnected
			}
		}
	}
}

// ── Client Streaming ──────────────────────────────────────────────────────────

func (s *Service) UploadPaymentBatch(
	stream paymentsv1.PaymentsService_UploadPaymentBatchServer,
) error {
	ctx := stream.Context()
	var accepted, rejected int32
	var rejectionReasons []string

	for {
		instruction, err := stream.Recv()
		if err == io.EOF {
			break // client finished sending
		}
		if err != nil {
			return status.Errorf(codes.Internal, "recv: %v", err)
		}

		// Check deadline before processing each item
		if ctx.Err() != nil {
			return status.FromContextError(ctx.Err()).Err()
		}

		if _, createErr := s.repo.Create(ctx, toInitiateRequest(instruction)); createErr != nil {
			rejected++
			rejectionReasons = append(rejectionReasons, createErr.Error())
		} else {
			accepted++
		}
	}

	return stream.SendAndClose(&paymentsv1.UploadBatchResponse{
		Accepted:         accepted,
		Rejected:         rejected,
		RejectionReasons: rejectionReasons,
	})
}

// ── Bidirectional Streaming ───────────────────────────────────────────────────

func (s *Service) StreamFraudScoring(
	stream paymentsv1.PaymentsService_StreamFraudScoringServer,
) error {
	ctx := stream.Context()

	for {
		req, err := stream.Recv()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
		if ctx.Err() != nil {
			return status.FromContextError(ctx.Err()).Err()
		}

		score, block, reason, err := s.fraudClient.Score(ctx, req)
		if err != nil {
			// Non-fatal: send error response per transaction, keep stream alive
			if err := stream.Send(&paymentsv1.FraudScoringResponse{
				TransactionId: req.TransactionId,
				Reason:        "scoring_unavailable",
			}); err != nil {
				return err
			}
			continue
		}

		if err := stream.Send(&paymentsv1.FraudScoringResponse{
			TransactionId: req.TransactionId,
			RiskScore:     score,
			Block:         block,
			Reason:        reason,
		}); err != nil {
			return err // client gone
		}
	}
}

func toInitiateRequest(i *paymentsv1.PaymentInstruction) *paymentsv1.InitiatePaymentRequest {
	return &paymentsv1.InitiatePaymentRequest{
		IdempotencyKey: i.IdempotencyKey,
		PayerAccount:   i.PayerAccount,
		PayeeAccount:   i.PayeeAccount,
		Amount:         i.Amount,
	}
}
```

---

### Template 4 — Go gRPC Client with Retry + Deadline Interceptor

```go
// internal/client/payments.go
package client

import (
	"context"
	"time"

	grpc_retry "github.com/grpc-ecosystem/go-grpc-middleware/v2/interceptors/retry"
	"go.opentelemetry.io/contrib/instrumentation/google.golang.org/grpc/otelgrpc"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/keepalive"

	paymentsv1 "github.com/org/payments-service/gen/go/payments/v1"
)

const defaultCallTimeout = 5 * time.Second

func NewPaymentsClient(target string) (paymentsv1.PaymentsServiceClient, *grpc.ClientConn, error) {
	retryOpts := []grpc_retry.CallOption{
		grpc_retry.WithBackoff(grpc_retry.BackoffExponentialWithJitter(100*time.Millisecond, 0.1)),
		grpc_retry.WithMax(3),
		grpc_retry.WithCodes(codes.Unavailable, codes.DeadlineExceeded),
	}

	conn, err := grpc.NewClient(target,
		grpc.WithTransportCredentials(insecure.NewCredentials()), // replace with TLS in prod
		grpc.WithChainUnaryInterceptor(
			otelgrpc.UnaryClientInterceptor(),
			deadlineUnaryInterceptor(defaultCallTimeout),
			grpc_retry.UnaryClientInterceptor(retryOpts...),
		),
		grpc.WithChainStreamInterceptor(
			otelgrpc.StreamClientInterceptor(),
			deadlineStreamInterceptor(defaultCallTimeout),
		),
		grpc.WithKeepaliveParams(keepalive.ClientParameters{
			Time:                10 * time.Second,
			Timeout:             3 * time.Second,
			PermitWithoutStream: false,
		}),
	)
	if err != nil {
		return nil, nil, err
	}

	return paymentsv1.NewPaymentsServiceClient(conn), conn, nil
}

// deadlineUnaryInterceptor injects a deadline if the context doesn't already have one.
func deadlineUnaryInterceptor(d time.Duration) grpc.UnaryClientInterceptor {
	return func(
		ctx context.Context,
		method string,
		req, reply any,
		cc *grpc.ClientConn,
		invoker grpc.UnaryInvoker,
		opts ...grpc.CallOption,
	) error {
		if _, ok := ctx.Deadline(); !ok {
			var cancel context.CancelFunc
			ctx, cancel = context.WithTimeout(ctx, d)
			defer cancel()
		}
		return invoker(ctx, method, req, reply, cc, opts...)
	}
}

func deadlineStreamInterceptor(d time.Duration) grpc.StreamClientInterceptor {
	return func(
		ctx context.Context,
		desc *grpc.StreamDesc,
		cc *grpc.ClientConn,
		method string,
		streamer grpc.Streamer,
		opts ...grpc.CallOption,
	) (grpc.ClientStream, error) {
		if _, ok := ctx.Deadline(); !ok {
			var cancel context.CancelFunc
			ctx, cancel = context.WithTimeout(ctx, d)
			defer cancel()
		}
		return streamer(ctx, desc, cc, method, opts...)
	}
}
```

---

### Template 5 — TypeScript gRPC-Web Client (Browser)

```typescript
// src/grpc/paymentsClient.ts
// Uses @bufbuild/connect-web (Connect protocol — works natively in browsers without proxy)
import { createClient } from "@connectrpc/connect";
import { createConnectTransport } from "@connectrpc/connect-web";
import { PaymentsService } from "../gen/ts/payments/v1/payments_connect";
import type {
  InitiatePaymentRequest,
  PaymentStatusEvent,
} from "../gen/ts/payments/v1/payments_pb";

const transport = createConnectTransport({
  baseUrl: "https://api.internal",
  // interceptors run in order for requests, reverse order for responses
  interceptors: [
    (next) => async (req) => {
      const token = await getAccessToken();
      req.header.set("Authorization", `Bearer ${token}`);
      return next(req);
    },
  ],
});

const client = createClient(PaymentsService, transport);

// Unary call
export async function initiatePayment(
  req: InitiatePaymentRequest,
  signal?: AbortSignal,
) {
  return client.initiatePayment(req, { signal, timeoutMs: 10_000 });
}

// Server streaming — async iterable in the browser
export async function* watchPaymentStatus(
  paymentId: string,
  signal?: AbortSignal,
): AsyncGenerator<PaymentStatusEvent> {
  const stream = client.watchPaymentStatus(
    { paymentId },
    { signal },
  );

  for await (const event of stream) {
    yield event;
    if (
      event.status === "PAYMENT_STATUS_COMPLETED" ||
      event.status === "PAYMENT_STATUS_FAILED"
    ) {
      return; // terminal state — stop consuming
    }
  }
}

// Usage in a React component:
// const controller = new AbortController();
// for await (const event of watchPaymentStatus(id, controller.signal)) {
//   setStatus(event.status);
// }
// cleanup: controller.abort();
```

---

### Template 6 — buf CI Pipeline + grpcurl Smoke Test

```yaml
# .github/workflows/proto-checks.yml
name: Protobuf Checks
on:
  pull_request:
    paths: ["proto/**"]

jobs:
  lint-and-breaking:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683
        with:
          fetch-depth: 0              # needed for git baseline breaking check

      - uses: bufbuild/buf-action@v1
        with:
          version: "1.47.2"

      - name: Lint
        run: buf lint

      - name: Breaking change detection
        run: buf breaking --against '.git#branch=main'

      - name: Generate and diff
        run: |
          buf generate
          # Fail if generated code differs from committed gen/ files
          git diff --exit-code gen/

  push-to-bsr:
    if: github.ref == 'refs/heads/main'
    needs: lint-and-breaking
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683
      - uses: bufbuild/buf-action@v1
        with:
          token: ${{ secrets.BUF_TOKEN }}
      - run: buf push --label ${{ github.sha }}
```

```bash
#!/bin/bash
# scripts/grpc-smoke-test.sh — run after deployment to verify gRPC service is reachable

set -euo pipefail

HOST=${GRPC_HOST:-"localhost:9090"}
SERVICE="payments.v1.PaymentsService"

echo "=== gRPC Health Check ==="
grpcurl -plaintext "$HOST" grpc.health.v1.Health/Check

echo ""
echo "=== List Methods (reflection) ==="
grpcurl -plaintext "$HOST" list "$SERVICE"

echo ""
echo "=== Unary Smoke Test: InitiatePayment ==="
grpcurl -plaintext \
  -d '{
    "idempotency_key": "smoke-test-'$(date +%s)'",
    "payer_account":   "ACC-001",
    "payee_account":   "ACC-002",
    "amount": {
      "units": 1,
      "nano_units": 0,
      "currency_code": "ZAR"
    },
    "reference": "smoke test"
  }' \
  "$HOST" "$SERVICE/InitiatePayment"

echo ""
echo "=== Server Streaming: WatchPaymentStatus (3s timeout) ==="
timeout 3 grpcurl -plaintext \
  -d '{"payment_id": "smoke-test-id"}' \
  "$HOST" "$SERVICE/WatchPaymentStatus" || true

echo "Smoke tests passed."
```

---

## Decision Matrix

| Scenario | Recommendation | Rationale |
|---|---|---|
| Service-to-service internal API | gRPC (proto3) | Binary efficiency, generated clients, streaming, deadline propagation |
| Public API consumed by browsers | REST/JSON or Connect protocol | gRPC requires proxy for browsers; REST needs no proxy |
| Real-time event streaming (server → client) | Server-streaming RPC | Native to gRPC; no WebSocket setup; deadline-bounded |
| Bulk data upload (client → server) | Client-streaming RPC | Chunked upload; backpressure via flow control |
| Interactive real-time (e.g., chat, fraud scoring) | Bidirectional streaming | Full-duplex on one HTTP/2 stream |
| Polyglot team (Go + Java + TypeScript + Python) | gRPC + buf BSR | Single `.proto` generates clients for all languages |
| Need schema evolution with breaking-change safety | buf + BSR | `buf breaking` catches incompatible changes in CI |
| Browser client without proxy | Connect protocol (`@connectrpc/connect-web`) | HTTP/1.1 + JSON or binary; no Envoy proxy needed |
| ML model serving (high throughput, large tensors) | gRPC streaming + Protobuf | Avoids JSON serialisation overhead on large float arrays |
| Legacy REST service needs gRPC | grpc-gateway (`protoc-gen-grpc-gateway`) | Generates REST→gRPC transcoding from proto annotations |

---

## Proficiency Levels

### Level 1 — Aware
- Understands why gRPC uses binary (Protobuf) over JSON and how HTTP/2 multiplexing works
- Can read a `.proto` file and understand service/message definitions
- Knows the four streaming modes and when each applies conceptually
- Can run a service with `grpcurl` using reflection

### Level 2 — Practitioner
- Writes proto3 schemas following field numbering, naming, and reserved-field rules
- Configures `buf.yaml` + `buf.gen.yaml`; runs `buf lint` and `buf breaking` in CI
- Implements a unary gRPC service in Go with auth + logging interceptors
- Uses `context.WithTimeout` on every client call; handles `codes.DeadlineExceeded` vs `codes.Unavailable` differently
- Registers the gRPC health service; configures Kubernetes liveness/readiness to use it

### Level 3 — Advanced
- Implements all four streaming modes with correct `ctx.Done()` handling and graceful shutdown
- Chains unary + stream interceptor pairs for auth, OTel tracing, recovery, and retry
- Configures the Connect protocol for browser clients without Envoy proxy
- Designs backwards-compatible proto evolution: `reserved` fields, wrapper types for optional semantics
- Pushes schemas to BSR with CI labels; enforces `buf breaking` against BSR baseline
- Implements client-side retry with exponential backoff + jitter on `UNAVAILABLE` only

### Level 4 — Expert
- Designs a proto schema registry strategy for a large microservices org: module ownership, versioning (`v1`, `v2`), deprecation timelines
- Implements custom load balancing (round-robin, pick-first, custom resolver) for gRPC over service discovery
- Tunes gRPC keepalive parameters for NAT traversal and service mesh environments
- Implements flow control–aware streaming: monitors `grpc.ServerStream.Context()` for backpressure signals; sheds load gracefully
- Contributes gRPC middleware libraries; designs interceptor patterns usable across 50+ services

---

## AI Prompts

**Generate a proto3 schema for a domain**
```
Design a proto3 schema for a [domain] service with the following operations:
- [list of operations: unary / server-streaming / client-streaming / bidi]
- Entities: [list fields and types]

Follow these rules:
- Package name: [company].[domain].v1
- Use google.protobuf.Timestamp for all timestamps
- Use MonetaryAmount message (units int64, nano_units int32, currency_code string) for money
- Prefix all enum values with the enum name (PAYMENT_STATUS_PENDING not just PENDING)
- Add reserved statements for fields that might be removed in future
- Include an idempotency_key on all mutating RPCs

Output: .proto file + buf.yaml + buf.gen.yaml
```

**Write gRPC interceptor chain**
```
Write a Go gRPC interceptor chain (both UnaryServerInterceptor and StreamServerInterceptor)
that implements in order:
1. OpenTelemetry tracing (use otelgrpc)
2. JWT authentication (extract Bearer token from metadata, validate RS256 signature)
3. Structured logging (log method, status code, duration in ms using slog)
4. Panic recovery (return codes.Internal, log stack trace)

Show how to wire these into grpc.NewServer() using ChainUnaryInterceptor and ChainStreamInterceptor.
```

**Implement server-streaming RPC**
```
Implement a Go gRPC server-streaming handler for this proto:
[paste proto service definition]

Requirements:
- Subscribe to an event bus / channel for events
- Select on ctx.Done() and event channel simultaneously
- Return status.FromContextError on cancellation
- Handle backpressure: if Send() returns an error, log and return (client gone)
- Close subscription cleanly in defer
Also write the TypeScript client using @connectrpc/connect-web with async iteration.
```

**Migrate REST service to gRPC**
```
I have a REST API with these endpoints:
[paste OpenAPI spec or list of routes]

Design the equivalent proto3 schema and gRPC service definition.
Map: GET → unary query RPC, POST/PUT → unary mutation RPC,
long-running results → server-streaming RPC, WebSocket → bidirectional RPC.
Highlight any data model changes needed (timestamps, money, enums).
Show how to add grpc-gateway annotations to serve both REST and gRPC from the same server.
```

---

## References

- **Protocol Buffers documentation** — `protobuf.dev` — proto3 language guide, field types, encoding
- **gRPC documentation** — `grpc.io` — concepts, language guides, core concepts
- **buf documentation** — `buf.build/docs` — buf.yaml, buf.gen.yaml, BSR, breaking change rules
- **buf Schema Registry (BSR)** — `buf.build` — hosted schema registry; dependency management
- **`google.golang.org/grpc`** — official Go gRPC library; interceptors, keepalive, health
- **`go-grpc-middleware/v2`** — `github.com/grpc-ecosystem/go-grpc-middleware` — retry, logging, auth interceptors
- **`otelgrpc`** — `go.opentelemetry.io/contrib/instrumentation/google.golang.org/grpc/otelgrpc` — OTel gRPC interceptors
- **Connect protocol** — `connectrpc.com` — gRPC-compatible protocol that works natively in browsers
- **`@connectrpc/connect-web`** — npm TypeScript client for Connect/gRPC-Web in browsers
- **grpcurl** — `github.com/fullstorydev/grpcurl` — CLI tool for gRPC (like curl for HTTP)
- **grpc-gateway** — `github.com/grpc-ecosystem/grpc-gateway` — REST→gRPC transcoding from proto annotations
- **gRPC health checking protocol** — `github.com/grpc/grpc/blob/master/doc/health-checking.md`
