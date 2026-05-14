---
name: "API Design Strategy"
slug: api-design-strategy
category: "04-backend-and-services"
proficiency: Architect
description: "Master the design, evolution, and governance of APIs using REST, GraphQL, gRPC, and async patterns. Covers contract-first design, versioning, error handling, security integration, Backend-for-Frontend, and organisation-wide API lifecycle management."
tags: [api-design, rest, graphql, grpc, openapi, asyncapi, bff, versioning, contract-first, api-gateway, problem-details, oauth2, rate-limiting, hypermedia]
status: published
---

# API Design Strategy

## Principles

**An API Is a Product**
An API is a contract with consumers. Breaking it — even for good reasons — costs trust and forces work onto every team that depends on it. Design APIs with the same product discipline you apply to user-facing features: understand the consumer's needs first, design for their use cases, version changes carefully, and deprecate with notice.

**Design for Consumers, Not for the Implementation**
An API that mirrors your internal domain model is easy to build and painful to use. Consumers should not need to understand your aggregates, your database schema, or your service topology. Design the API around the consumer's mental model and use cases; let the implementation map to your domain internally.

**Consistency Over Creativity**
An API with consistent naming conventions, error formats, pagination patterns, and status codes is predictable. Predictability reduces the consumer's cognitive load and the number of support questions. Establish a style guide and enforce it with linting — not code reviews alone.

**Explicit Contracts, Versioned from Day One**
Every API is a public contract the moment it has a consumer. Define it explicitly (OpenAPI, Protobuf, GraphQL schema) before implementation begins. Version it before you need to break it. If you build a v1 API without a versioning strategy, the first breaking change will force a painful retrofit.

**Security and Observability Are Not Optional**
Authentication, authorisation, rate limiting, and structured telemetry must be designed into every API from the first commit. An API deployed without rate limiting invites DoS. An API deployed without structured request logging is undebuggable in production. These are not features to add later.

**Prefer Synchronous for Queries, Asynchronous for Commands**
Queries (read operations) return data immediately — synchronous HTTP is the right model. Commands that trigger long-running work (sending an email, processing a payment, generating a report) should return immediately with a `202 Accepted` and a status endpoint or webhook. Never make consumers wait for work that takes more than a few hundred milliseconds.

---

## Implementation Patterns

### Pattern 1 — REST + OpenAPI (Default for External APIs)

REST over HTTP with an OpenAPI 3.1 specification is the correct default for external, public-facing, and partner APIs. It is the most widely understood style, has the richest tooling ecosystem, and caches well at the HTTP layer.

**Resource naming**:
- Nouns, not verbs: `/orders`, not `/createOrder`
- Plural for collections: `/orders`, `/customers`
- Hierarchy for ownership: `/customers/{id}/orders`
- Query parameters for filtering, sorting, pagination: `/orders?status=pending&sort=created_at:desc&page=2&per_page=50`

**HTTP methods**:
- `GET` — read, idempotent, cacheable
- `POST` — create or trigger an action (non-idempotent)
- `PUT` — full replacement, idempotent
- `PATCH` — partial update (JSON Patch or JSON Merge Patch)
- `DELETE` — remove, idempotent

**Response status codes** — use precisely:
- `200 OK` — success with body
- `201 Created` — resource created; include `Location` header
- `202 Accepted` — async work accepted; include status polling URL
- `204 No Content` — success, no body (DELETE, some PUT)
- `400 Bad Request` — client validation error
- `401 Unauthorized` — not authenticated
- `403 Forbidden` — authenticated but not authorised
- `404 Not Found` — resource does not exist
- `409 Conflict` — state conflict (duplicate, optimistic lock failure)
- `422 Unprocessable Entity` — syntactically valid but semantically invalid
- `429 Too Many Requests` — rate limit exceeded; include `Retry-After`
- `500 Internal Server Error` — unexpected server failure

### Pattern 2 — Problem Details for Error Responses (RFC 9457)

Never return ad-hoc error objects. Use RFC 9457 Problem Details — a standard, machine-readable error format:

```json
{
  "type": "https://api.example.com/problems/insufficient-stock",
  "title": "Insufficient Stock",
  "status": 422,
  "detail": "Product SKU-001 has 3 units available; 10 were requested.",
  "instance": "/orders/ord_abc123",
  "traceId": "4bf92f3577b34da6a3ce929d0e0e4736",
  "extensions": {
    "productId": "SKU-001",
    "available": 3,
    "requested": 10
  }
}
```

The `type` URI is a stable identifier for the error class — consumers can branch on it. The `instance` URI identifies the specific failing request. The `traceId` links to the distributed trace for support.

### Pattern 3 — gRPC + Protobuf (Internal Service-to-Service)

For internal service-to-service communication where latency and throughput matter:

- **Binary protocol**: Protobuf serialisation is 3–10x smaller than JSON and 5–10x faster to serialise/deserialise
- **Strongly typed contracts**: `.proto` files are the contract; code generation enforces compatibility
- **Streaming**: bidirectional streaming for real-time data flows
- **Deadline propagation**: gRPC propagates timeouts across service boundaries automatically

```protobuf
// order_service.proto
syntax = "proto3";
package ordering.v1;

service OrderService {
    rpc PlaceOrder  (PlaceOrderRequest)    returns (PlaceOrderResponse);
    rpc GetOrder    (GetOrderRequest)      returns (Order);
    rpc StreamOrders(StreamOrdersRequest)  returns (stream Order);
}

message PlaceOrderRequest {
    string customer_id = 1;
    repeated OrderLine lines = 2;
}

message OrderLine {
    string product_id = 1;
    int32  quantity   = 2;
    Money  unit_price = 3;
}

message Money {
    int64  amount_minor = 1;  // e.g. 1099 for $10.99
    string currency     = 2;  // ISO 4217
}
```

Use gRPC for internal APIs. Use REST/OpenAPI for external APIs. Never expose a gRPC endpoint directly to browser clients without a gRPC-Web proxy or transcoding layer.

### Pattern 4 — GraphQL (Complex, Consumer-Driven Queries)

GraphQL is appropriate when:
- Different consumers need different shapes of the same data (mobile vs web vs partner)
- The data is highly relational and consumers need to traverse relationships flexibly
- Over-fetching and under-fetching are genuine problems causing performance issues

Do not use GraphQL as a default. Its power comes with complexity: query depth attacks (use depth limiting), N+1 query problems (use DataLoader), schema evolution (additive-only changes), and lack of HTTP caching for POST-based queries.

**Apollo Federation** for multi-team GraphQL: each team owns a sub-graph; Federation composes them into a unified schema. Each sub-graph is independently deployable and owned by one team.

### Pattern 5 — Backend for Frontend (BFF)

When a frontend needs a specific, aggregated data shape that no single backend service provides, a BFF acts as a composition layer:

```
Mobile App → Mobile BFF → (Order Service, Customer Service, Inventory Service)
Web App    → Web BFF    → (Order Service, Customer Service, Recommendation Service)
```

Each BFF is owned by the frontend team. It aggregates, transforms, and caches data from multiple backend services into the exact shape the frontend needs. It is not a general-purpose API gateway — it serves one specific client type.

### Pattern 6 — API Versioning Strategy

Choose one versioning strategy and enforce it organisation-wide:

| Strategy | Example | Trade-offs |
|---|---|---|
| URL path version | `/api/v1/orders` | Most visible; easy to route; URLs are not stable REST identifiers |
| Request header | `Api-Version: 2026-05-01` | Cleaner URLs; requires client sophistication; harder to test in browser |
| Accept header (content negotiation) | `Accept: application/vnd.example.v2+json` | RESTful; complex for consumers |
| Query parameter | `/orders?version=2` | Easiest to test; pollutes query space |

**Recommendation**: URL path versioning for external/public APIs (most discoverable, easiest for consumers). Header versioning for internal APIs where URL stability matters.

**Versioning rules**:
- Additive changes (new fields, new endpoints) are non-breaking — no version bump required
- Removing fields, renaming fields, changing types, changing semantics — always a new version
- Maintain at least two major versions simultaneously during transition
- Communicate deprecation with `Deprecation` and `Sunset` response headers (RFC 8594)

---

## Anti-Patterns

| Anti-Pattern | Why It's Harmful | Fix |
|---|---|---|
| Chatty API (too many small requests) | Clients make 10 sequential calls to assemble one screen; each adds latency; mobile networks amplify the problem | Aggregate endpoints or BFF; use GraphQL where consumers need to control fetch shape |
| God endpoint | `POST /process` accepts any payload and does anything depending on a `type` field; impossible to document or version | One endpoint per resource action; use HTTP method semantics |
| Leaking internal domain model | API returns raw database rows or Aggregate internals; every schema refactor breaks consumers | Map domain objects to explicit API DTOs; the API contract is independent of the domain model |
| Inconsistent error format | Service A returns `{"error": "not found"}`, Service B returns `{"message": "404"}`, Service C throws HTML — consumers must handle all three | Problem Details (RFC 9457) organisation-wide; enforce with a linting rule or shared middleware |
| No deprecation policy | Old API versions run indefinitely; breaking changes accumulate; consumers never migrate | `Sunset` header + 6-month notice policy; track consumer usage before sunset; force migration |
| Missing rate limiting | Bot traffic or a runaway client can exhaust server resources; legitimate users are degraded | Rate limiting at the API Gateway layer with per-client and per-endpoint limits; `429` with `Retry-After` |
| Synchronous long-running operations | `POST /reports/generate` blocks for 30 seconds; clients timeout; retries create duplicate work | `202 Accepted` + `Location` header pointing to a status polling endpoint or webhook callback |

---

## Code Templates

### OpenAPI 3.1 — Order API Specification (Contract-First)

```yaml
# api/specs/orders.yaml
openapi: "3.1.0"
info:
  title: Orders API
  version: "1.0.0"
  contact:
    name: Platform Team
    email: platform@example.com

servers:
  - url: https://api.example.com/v1

paths:
  /orders:
    post:
      operationId: placeOrder
      summary: Place a new order
      security:
        - bearerAuth: [orders:write]
      requestBody:
        required: true
        content:
          application/json:
            schema: { $ref: '#/components/schemas/PlaceOrderRequest' }
      responses:
        "201":
          description: Order placed
          headers:
            Location: { schema: { type: string }, description: "URL of the created order" }
          content:
            application/json:
              schema: { $ref: '#/components/schemas/Order' }
        "400": { $ref: '#/components/responses/ValidationError' }
        "422": { $ref: '#/components/responses/BusinessRuleError' }
        "429": { $ref: '#/components/responses/RateLimited' }

  /orders/{orderId}:
    get:
      operationId: getOrder
      parameters:
        - name: orderId
          in: path
          required: true
          schema: { type: string, format: uuid }
      responses:
        "200":
          content:
            application/json:
              schema: { $ref: '#/components/schemas/Order' }
        "404": { $ref: '#/components/responses/NotFound' }

components:
  schemas:
    PlaceOrderRequest:
      type: object
      required: [customerId, lines]
      properties:
        customerId: { type: string, format: uuid }
        lines:
          type: array
          minItems: 1
          items: { $ref: '#/components/schemas/OrderLine' }

    OrderLine:
      type: object
      required: [productId, quantity]
      properties:
        productId: { type: string }
        quantity:  { type: integer, minimum: 1, maximum: 1000 }

    Order:
      type: object
      properties:
        id:         { type: string, format: uuid }
        customerId: { type: string, format: uuid }
        status:     { type: string, enum: [pending, confirmed, shipped, delivered, cancelled] }
        total:      { $ref: '#/components/schemas/Money' }
        createdAt:  { type: string, format: date-time }

    Money:
      type: object
      properties:
        amountMinor: { type: integer, description: "Amount in minor currency unit (e.g. cents)" }
        currency:    { type: string, pattern: "^[A-Z]{3}$" }

  responses:
    ValidationError:
      description: Request validation failed
      content:
        application/problem+json:
          schema: { $ref: '#/components/schemas/ProblemDetails' }
    NotFound:
      description: Resource not found
      content:
        application/problem+json:
          schema: { $ref: '#/components/schemas/ProblemDetails' }
    RateLimited:
      description: Rate limit exceeded
      headers:
        Retry-After: { schema: { type: integer }, description: "Seconds until rate limit resets" }

  securitySchemes:
    bearerAuth:
      type: http
      scheme: bearer
      bearerFormat: JWT
```

### Go — Problem Details Middleware

```go
// middleware/problem_details.go
type ProblemDetails struct {
    Type     string         `json:"type"`
    Title    string         `json:"title"`
    Status   int            `json:"status"`
    Detail   string         `json:"detail,omitempty"`
    Instance string         `json:"instance,omitempty"`
    TraceID  string         `json:"traceId,omitempty"`
    Extra    map[string]any `json:"-"`
}

func (p ProblemDetails) MarshalJSON() ([]byte, error) {
    type Alias ProblemDetails
    merged := map[string]any{}
    b, _ := json.Marshal(Alias(p))
    _ = json.Unmarshal(b, &merged)
    for k, v := range p.Extra {
        merged[k] = v
    }
    return json.Marshal(merged)
}

func WriteProblem(w http.ResponseWriter, r *http.Request, p ProblemDetails) {
    span := trace.SpanFromContext(r.Context())
    p.TraceID  = span.SpanContext().TraceID().String()
    p.Instance = r.URL.Path

    w.Header().Set("Content-Type", "application/problem+json")
    w.WriteHeader(p.Status)
    _ = json.NewEncoder(w).Encode(p)
}

// Usage
func (h *OrderHandler) PlaceOrder(w http.ResponseWriter, r *http.Request) {
    var req PlaceOrderRequest
    if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
        WriteProblem(w, r, ProblemDetails{
            Type:   "https://api.example.com/problems/invalid-request",
            Title:  "Invalid Request",
            Status: http.StatusBadRequest,
            Detail: err.Error(),
        })
        return
    }
    // ...
}
```

### TypeScript — Rate Limiting Middleware (Express)

```typescript
import rateLimit from 'express-rate-limit';
import { Request, Response } from 'express';

// Per-user rate limit (requires auth middleware to run first)
export const orderRateLimit = rateLimit({
    windowMs: 60 * 1000,    // 1 minute
    max: 20,                 // 20 requests per user per minute
    keyGenerator: (req: Request) => req.user?.id ?? req.ip,
    handler: (req: Request, res: Response) => {
        res.status(429)
           .set('Retry-After', '60')
           .json({
               type:   'https://api.example.com/problems/rate-limit-exceeded',
               title:  'Rate Limit Exceeded',
               status: 429,
               detail: 'You have exceeded 20 requests per minute.',
           });
    },
    standardHeaders: true,   // sends RateLimit-* headers
    legacyHeaders: false,
});
```

### C# — Async Command Acceptance Pattern (202 + Status Endpoint)

```csharp
// Returns 202 immediately; processing happens in background
[HttpPost("reports")]
public async Task<IActionResult> GenerateReport([FromBody] GenerateReportRequest req)
{
    var jobId = await _jobQueue.Enqueue(new GenerateReportJob(req));

    return AcceptedAtRoute(
        routeName: "GetReportStatus",
        routeValues: new { jobId },
        value: new { jobId, status = "queued" }
    );
    // Location: /reports/jobs/{jobId}
}

// Polling endpoint for async job status
[HttpGet("reports/jobs/{jobId}", Name = "GetReportStatus")]
public async Task<IActionResult> GetReportStatus(Guid jobId)
{
    var job = await _jobStore.Find(jobId);
    if (job is null) return NotFound();

    return job.Status switch
    {
        JobStatus.Queued     => Ok(new { status = "queued" }),
        JobStatus.Processing => Ok(new { status = "processing", progress = job.Progress }),
        JobStatus.Completed  => Ok(new { status = "completed", resultUrl = job.ResultUrl }),
        JobStatus.Failed     => UnprocessableEntity(new ProblemDetails
        {
            Type   = "https://api.example.com/problems/report-generation-failed",
            Title  = "Report Generation Failed",
            Status = 422,
            Detail = job.ErrorMessage,
        }),
        _ => StatusCode(500),
    };
}
```

---

## Decision Matrix

| Use Case | Style | Versioning | Notes |
|---|---|---|---|
| Public / partner API | REST + OpenAPI 3.1 | URL path (`/v1/`) | Contract-first; publish to developer portal |
| Internal service-to-service | gRPC + Protobuf | Protobuf field numbering (additive) | Code-generate clients; propagate deadlines |
| Consumer-driven flexible queries | GraphQL (+ Apollo Federation at scale) | Additive schema changes only | Use DataLoader for N+1; depth limiting |
| Mobile / web frontend data aggregation | BFF (REST or GraphQL) | URL path | Owned by frontend team; not shared |
| Async / event-driven integration | AsyncAPI + webhooks | Event schema versioning | Additive-only event changes |
| Long-running operations | REST + `202 Accepted` + polling / webhook | Same as parent API | Never block the HTTP connection |
| Real-time streams | gRPC streaming or WebSocket (via API Gateway) | gRPC field numbering | Define back-pressure strategy |

---

## Proficiency Levels

### Awareness
- Can explain the trade-offs between REST, GraphQL, and gRPC.
- Knows when to use `200 vs 201 vs 202 vs 204 vs 422 vs 409`.
- Understands what Problem Details (RFC 9457) is and why it exists.

### Applied
- Designs and implements a REST API with an OpenAPI 3.1 spec (contract-first).
- Implements consistent Problem Details error responses and rate limiting.
- Applies URL versioning with deprecation headers.
- Designs a BFF for a specific frontend client.

### Master
- Designs API strategies across multiple bounded contexts: which style per context, how versioning governance works, how APIs surface in a developer portal.
- Implements gRPC service definitions with Protobuf and generates clients in multiple languages.
- Designs a GraphQL schema with Apollo Federation for multi-team ownership.
- Implements the `202 Accepted` async pattern with polling and webhook delivery.

### Architect
- Defines organisation-wide API governance: style guide, linting rules, versioning policy, deprecation notice periods, developer portal standards.
- Evaluates and selects API gateway and service mesh tooling.
- Designs the API lifecycle: how APIs are proposed (ADR), designed (contract-first), reviewed, published, versioned, deprecated, and retired.
- Integrates API design with DDD (API boundaries = Bounded Context boundaries), security (OAuth2 scopes per context), and observability (golden signals per API endpoint).

---

## AI Prompts

**Design an API from a domain description:**
> Design a REST API for this bounded context: [describe domain, operations, consumers]. Produce an OpenAPI 3.1 spec skeleton with: resource names, HTTP methods, status codes, request/response schemas (with Money represented as minor units + currency), and Problem Details error responses.

**Choose an API style:**
> For this use case: [describe consumers, data relationships, latency requirements, team structure]. Compare REST vs GraphQL vs gRPC and recommend the best style with justification. Include trade-offs specific to this context.

**Review an API design:**
> Review this API design for violations of REST conventions, consistency issues, and security gaps. Check: resource naming (nouns not verbs), HTTP method semantics, status code precision, error format (Problem Details), versioning strategy, rate limiting, and auth scope definition. [paste OpenAPI spec or endpoint list]

**Design a versioning strategy:**
> Our API currently has 3 consumers on v1. We need to make these breaking changes: [list changes]. Design a versioning strategy: which versioning style to use, how to communicate the deprecation, what the transition period should be, and what the sunset notice looks like.

**Design an async API:**
> I need to design an API endpoint for this long-running operation: [describe operation, expected duration, consumer type]. Design: the synchronous acceptance response (202 + Location), the status polling endpoint, the webhook callback option, and the error handling for partial failures.

---

## References

**Books**
- JJ Geewax — *API Design Patterns* (Manning, 2021) — comprehensive patterns for resource design, versioning, long-running operations
- Leonard Richardson & Mike Amundsen — *RESTful Web APIs* (O'Reilly, 2013) — hypermedia, resource design, HTTP semantics

**Standards**
- [OpenAPI 3.1 Specification](https://spec.openapis.org/oas/v3.1.0)
- [RFC 9457 — Problem Details for HTTP APIs](https://www.rfc-editor.org/rfc/rfc9457)
- [RFC 8594 — Sunset HTTP Header](https://www.rfc-editor.org/rfc/rfc8594)
- [AsyncAPI 3.0](https://www.asyncapi.com/docs/reference/specification/v3.0.0) — async API specification standard
- [gRPC Best Practices](https://grpc.io/docs/guides/performance/)

**Tooling**
- [Spectral](https://stoplight.io/open-source/spectral) — OpenAPI linting and style guide enforcement
- [Buf](https://buf.build/) — Protobuf linting, breaking change detection, and code generation
- [Apollo Studio](https://www.apollographql.com/docs/studio/) — GraphQL schema registry and governance

**Related Skills**
- `02-architecture-and-design/ddd-fundamentals` — API boundaries should align with Bounded Context boundaries
- `02-architecture-and-design/modular-monolith` — module facades become API contracts; BFF per frontend is a module
- `06-security-and-compliance/authentication-and-authorization` — OAuth2 scopes map to API operations; every endpoint needs an authorisation decision
- `08-quality-testing-observability/observability-telemetry-strategy` — golden signals (latency, traffic, errors, saturation) per API endpoint; trace context in every request
