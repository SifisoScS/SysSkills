---
name: "Observability & Telemetry Strategy"
slug: observability-telemetry-strategy
category: "08-quality-testing-observability"
proficiency: Architect
description: "Design and implement comprehensive observability using Metrics, Events, Logs, and Traces (MELT) to achieve full production visibility, rapid incident response, and data-driven improvement. Covers OpenTelemetry instrumentation, SLOs, golden signals, and distributed tracing across event-driven and microservice architectures."
tags: [observability, telemetry, opentelemetry, prometheus, grafana, loki, tempo, tracing, slo, error-budget, golden-signals, structured-logging, distributed-tracing, melt]
status: published
---

# Observability & Telemetry Strategy

## Principles

**Observability Is a Design Property, Not an Afterthought**
A system that is hard to observe in production is a system that is hard to operate, debug, and improve. Observability must be designed in from the start: correlation IDs in every request, structured logs from every service, traces that span every boundary. Retrofitting observability into a running production system is an order of magnitude more expensive than building it in.

**Monitoring Tells You When Something Is Wrong; Observability Tells You Why**
Monitoring checks known failure conditions. Observability lets you ask novel questions about system behaviour without deploying new code. The goal is not to predict every failure mode — it is to build a system whose internal state can be inferred from its external outputs at any time.

**The Golden Signals Are Enough to Start**
Latency, traffic, errors, and saturation cover the failure modes of almost any service. Instrument these four before adding anything else. A team that knows its p99 latency, error rate, request volume, and resource saturation can answer most production questions.

**Context Is King**
A log line without a request ID, service name, and trace ID is nearly useless in a distributed system. A metric without labels for environment, service version, and region tells you something broke but not where. Every piece of telemetry must carry enough context to be correlated with everything else.

**Prefer Open Standards (OpenTelemetry)**
Vendor-specific instrumentation locks you in and fragments your telemetry. OpenTelemetry (OTel) is the CNCF standard for metrics, traces, and logs. Instrument once; route to any backend. This is the only instrumentation approach worth investing in for new systems.

**Design for Unknown Unknowns**
Dashboards answer the questions you thought to ask. High-cardinality, context-rich telemetry lets you answer the questions you did not know to ask. Prefer high-context structured events over low-context metrics for novel incident investigation.

**SLOs Drive Alert Quality**
Alerts should fire when user experience degrades, not when a server metric crosses an arbitrary threshold. Define Service Level Objectives (SLOs) based on user-facing behaviour; alert on error budget burn rate. This eliminates alert fatigue by ensuring every alert represents a real impact on users.

---

## Implementation Patterns

### Pattern 1 — The MELT Stack

**Metrics**: quantitative measurements aggregated over time. Best for dashboards, trending, and SLO tracking. Instrument with Prometheus-compatible counters, gauges, and histograms.

**Events**: discrete occurrences with rich context. Domain events (OrderPlaced), infrastructure events (DeploymentCompleted), security events (AuthFailure). Highest information density; best for root cause analysis.

**Logs**: time-stamped records of what happened. Must be structured (JSON) and carry correlation context (trace ID, request ID, service version). Never use unstructured log lines in distributed systems.

**Traces**: end-to-end record of a request as it flows through multiple services. Shows where time is spent and where errors originate. Essential for debugging distributed systems and event-driven architectures.

All four must share a common correlation ID (trace ID / request ID) to be joinable during incident investigation.

### Pattern 2 — OpenTelemetry Instrumentation Architecture

```
Application (auto-instrumentation + manual spans)
    ↓
OTel Collector (sidecar or gateway)
    ↓ (fan-out)
    ├── Prometheus   (metrics)
    ├── Grafana Tempo (traces)
    └── Grafana Loki  (logs)
                ↓
         Grafana (unified dashboards, alerting)
```

The OTel Collector is the central routing layer. It receives telemetry from all services, processes it (sampling, enrichment, redaction), and fans out to backend stores. Never send telemetry directly from services to backend stores — the Collector decouples instrumentation from storage decisions.

### Pattern 3 — Golden Signals per Service

Define these four signals for every service at launch:

| Signal | What to Measure | Prometheus Metric Type |
|---|---|---|
| **Latency** | p50, p95, p99 request duration | Histogram (`http_request_duration_seconds`) |
| **Traffic** | Requests per second (RPS) | Counter (`http_requests_total`) |
| **Errors** | Error rate (4xx/5xx as % of total) | Counter (`http_requests_total{status="5xx"}`) |
| **Saturation** | CPU %, memory %, connection pool usage, queue depth | Gauge |

Dashboard layout: one row per service, four panels per row, one per golden signal. Add a fifth panel for SLO burn rate.

### Pattern 4 — SLO Definition and Error Budgets

**SLI (Service Level Indicator)**: the measured behaviour. Example: "ratio of requests with latency < 200ms".

**SLO (Service Level Objective)**: the target. Example: "99.5% of requests complete in < 200ms over a 30-day window".

**Error Budget**: `1 - SLO`. If SLO is 99.5%, the error budget is 0.5% of requests per month allowed to fail or be slow. When the error budget is exhausted, feature work stops and reliability work begins.

**Alert on burn rate, not threshold**:
- Fast burn (> 14x budget rate for 1 hour): page immediately — budget will be exhausted in < 3 days
- Slow burn (> 2x budget rate for 6 hours): ticket — degraded reliability trend

### Pattern 5 — Distributed Tracing in Event-Driven Systems

Tracing a synchronous HTTP call is straightforward. Event-driven systems require explicit context propagation:

```
Producer: inject trace context into event headers
Consumer: extract trace context from headers and create a child span
```

This creates a causal trace that spans producer, broker, and consumer — making it possible to follow a single business transaction (OrderPlaced → InventoryReserved → PaymentProcessed) across services and time.

For async flows where a response is decoupled from the originating request, use baggage (OTel's key-value propagation) to carry business context (customer ID, order ID) through the entire trace.

### Pattern 6 — Observability During Strangler Fig Migrations

Running legacy and new systems in parallel requires dual instrumentation:

- Instrument both the legacy and new service with OTel using the same service name convention and the same golden signals
- Add a `version` label (`legacy` / `modern`) to all metrics and logs
- Build a migration dashboard: side-by-side golden signals, error rates, and latency for both
- Alert when the new service error rate exceeds the legacy baseline during canary rollout
- Track percentage of traffic on new vs legacy as a migration progress metric

---

## Anti-Patterns

| Anti-Pattern | Why It's Harmful | Fix |
|---|---|---|
| Unstructured log lines | Impossible to query, filter, or correlate in a distributed system | Structured JSON logs with mandatory fields: `trace_id`, `service`, `level`, `message`, `timestamp` |
| Missing correlation IDs | Cannot follow a request or event across service boundaries; each service's logs are an island | Propagate OTel trace context on every request and event; log the trace ID in every log line |
| Alert fatigue | Hundreds of low-value threshold alerts; on-call engineers learn to ignore them | Alert only on SLO burn rate and critical business events; delete all alerts not tied to user impact |
| Log everything without sampling | High-volume services produce TBs of logs; storage costs explode; signal drowns in noise | Head-based or tail-based sampling for traces; log at INFO for normal paths; DEBUG only on error context |
| High-cardinality metrics without sampling | User ID or request ID as a Prometheus label creates millions of time series; crashes the metrics backend | Never use unbounded values as metric labels; use traces for high-cardinality data |
| Treating metrics as the only signal | Metrics tell you *that* something broke; without traces and logs you cannot tell *why* | All four MELT signals are required; instrument traces and logs from day one |
| No observability in event-driven flows | An event is published; something downstream fails; there is no way to trace the causal chain | Propagate OTel context in event headers; create child spans in every consumer |
| Observability only for production | Bugs are found in production because no visibility in staging or during migration | Same instrumentation stack in all environments; shadow traffic and canary deployments need the same signals |

---

## Code Templates

### Go — OpenTelemetry SDK Bootstrap

```go
// telemetry/setup.go
package telemetry

import (
    "context"
    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
    "go.opentelemetry.io/otel/sdk/resource"
    sdktrace "go.opentelemetry.io/otel/sdk/trace"
    semconv "go.opentelemetry.io/otel/semconv/v1.21.0"
)

func SetupOTel(ctx context.Context, serviceName, serviceVersion string) (func(), error) {
    exp, err := otlptracegrpc.New(ctx) // reads OTEL_EXPORTER_OTLP_ENDPOINT from env
    if err != nil {
        return nil, err
    }

    res := resource.NewWithAttributes(
        semconv.SchemaURL,
        semconv.ServiceName(serviceName),
        semconv.ServiceVersion(serviceVersion),
    )

    tp := sdktrace.NewTracerProvider(
        sdktrace.WithBatcher(exp),
        sdktrace.WithResource(res),
        sdktrace.WithSampler(sdktrace.ParentBased(sdktrace.TraceIDRatioBased(0.1))), // 10% sampling
    )
    otel.SetTracerProvider(tp)

    return func() { _ = tp.Shutdown(ctx) }, nil
}

// Usage in HTTP handler
func (h *OrderHandler) CreateOrder(w http.ResponseWriter, r *http.Request) {
    ctx, span := otel.Tracer("order-service").Start(r.Context(), "CreateOrder")
    defer span.End()

    span.SetAttributes(
        attribute.String("customer.id", r.Header.Get("X-Customer-ID")),
    )
    // ... handler logic
}
```

### Go — Structured Logging with Trace Correlation (slog)

```go
// logging/logger.go
package logging

import (
    "context"
    "log/slog"
    "go.opentelemetry.io/otel/trace"
)

// ContextLogger extracts OTel trace context and adds it to every log line
func FromContext(ctx context.Context) *slog.Logger {
    span := trace.SpanFromContext(ctx)
    sc   := span.SpanContext()

    return slog.Default().With(
        slog.String("trace_id", sc.TraceID().String()),
        slog.String("span_id",  sc.SpanID().String()),
    )
}

// Usage
func (s *OrderService) PlaceOrder(ctx context.Context, cmd PlaceOrderCmd) error {
    log := logging.FromContext(ctx)
    log.Info("placing order", "customer_id", cmd.CustomerID, "item_count", len(cmd.Items))

    if err := s.repo.Save(ctx, order); err != nil {
        log.Error("failed to save order", "error", err, "order_id", order.ID)
        return err
    }
    return nil
}
```

### TypeScript — OTel Context Propagation in Kafka Events

```typescript
import { context, propagation, trace } from '@opentelemetry/api';

// Producer: inject trace context into event headers
async function publishOrderPlaced(event: OrderPlaced): Promise<void> {
    const headers: Record<string, string> = {};
    propagation.inject(context.active(), headers); // injects traceparent, tracestate

    await producer.send({
        topic: 'order-events',
        messages: [{
            key:     event.orderId,
            value:   JSON.stringify(event),
            headers: headers,
        }],
    });
}

// Consumer: extract trace context and create child span
async function handleOrderPlaced(message: KafkaMessage): Promise<void> {
    const parentCtx = propagation.extract(context.active(), message.headers ?? {});
    const tracer    = trace.getTracer('inventory-service');

    await context.with(parentCtx, async () => {
        const span = tracer.startSpan('HandleOrderPlaced');
        try {
            const event = JSON.parse(message.value!.toString()) as OrderPlaced;
            await reserveInventory(context.active(), event);
            span.setStatus({ code: SpanStatusCode.OK });
        } catch (err) {
            span.recordException(err as Error);
            span.setStatus({ code: SpanStatusCode.ERROR });
            throw err;
        } finally {
            span.end();
        }
    });
}
```

### Prometheus — Golden Signals Recording Rules

```yaml
# prometheus/rules/golden-signals.yml
groups:
  - name: golden_signals
    interval: 30s
    rules:
      # Error rate per service
      - record: job:http_error_rate:ratio_rate5m
        expr: |
          sum by (job) (rate(http_requests_total{status=~"5.."}[5m]))
          /
          sum by (job) (rate(http_requests_total[5m]))

      # p99 latency per service
      - record: job:http_request_duration_p99:histogram_quantile
        expr: |
          histogram_quantile(0.99,
            sum by (job, le) (rate(http_request_duration_seconds_bucket[5m]))
          )

      # SLO burn rate (fast burn = 14x over 1 hour)
      - record: job:slo_burn_rate:ratio_rate1h
        expr: |
          sum by (job) (rate(http_requests_total{status=~"5.."}[1h]))
          /
          sum by (job) (rate(http_requests_total[1h]))
          / 0.005  # divide by (1 - SLO) = 1 - 0.995
```

### Grafana Alert — SLO Fast Burn

```yaml
# grafana/alerts/slo-fast-burn.yml
apiVersion: 1
groups:
  - name: slo-alerts
    rules:
      - uid: order-svc-fast-burn
        title: "Order Service — SLO Fast Burn"
        condition: C
        data:
          - refId: A
            expr: job:slo_burn_rate:ratio_rate1h{job="order-service"}
        noDataState: NoData
        execErrState: Error
        for: 5m
        annotations:
          summary: "Order service burning error budget at {{ $values.A }}x rate"
          runbook: "https://wiki.internal/runbooks/order-service-errors"
        labels:
          severity: critical
          team: platform
        condition: A > 14   # fast burn threshold
```

### OTel Collector Config — Fan-out to Prometheus, Tempo, Loki

```yaml
# otel-collector/config.yaml
receivers:
  otlp:
    protocols:
      grpc: { endpoint: "0.0.0.0:4317" }
      http: { endpoint: "0.0.0.0:4318" }

processors:
  batch:
    timeout: 5s
    send_batch_size: 1000
  resource:
    attributes:
      - key: deployment.environment
        value: ${ENVIRONMENT}
        action: upsert

exporters:
  prometheusremotewrite:
    endpoint: "http://prometheus:9090/api/v1/write"
  otlp/tempo:
    endpoint: "http://tempo:4317"
    tls: { insecure: true }
  loki:
    endpoint: "http://loki:3100/loki/api/v1/push"
    labels:
      resource: ["service.name", "service.version"]

service:
  pipelines:
    metrics:  { receivers: [otlp], processors: [batch, resource], exporters: [prometheusremotewrite] }
    traces:   { receivers: [otlp], processors: [batch, resource], exporters: [otlp/tempo] }
    logs:     { receivers: [otlp], processors: [batch, resource], exporters: [loki] }
```

---

## Decision Matrix

| Scenario | Recommended Stack | Key Configuration |
|---|---|---|
| New microservices / EDA | OTel SDK + Collector → Prometheus + Tempo + Loki + Grafana | Auto-instrument HTTP/DB; manual spans for domain events |
| Legacy monolith | OTel Java/Python agent (zero-code auto-instrumentation) + same backend | Start with auto-instrumentation; add manual spans for high-value paths |
| Strangler Fig migration | Dual instrumentation; `version` label on all metrics; migration dashboard | Side-by-side golden signals for legacy vs new; alert on new > legacy error rate |
| High-scale (> 10k RPS) | Prometheus + Cortex/Mimir (horizontally scalable); Tempo with object storage | Head-based sampling 5–10%; recording rules for aggregates |
| Frontend-heavy SaaS | OTel Web SDK + Core Web Vitals; RUM (Grafana Faro or Sentry) | Correlate frontend traces to backend spans via `traceparent` header |
| Security / compliance | OTel + tamper-evident audit log (append-only PostgreSQL or WORM storage) | Log all auth events, data access, and admin actions with trace context |
| Regulated environment | Centralised log aggregation with retention policy; encrypted transport | Loki with S3 backend; 90-day minimum retention; log redaction for PII |

---

## Proficiency Levels

### Awareness
- Can explain the difference between monitoring and observability.
- Knows the four MELT signals and the four golden signals.
- Understands what a trace span is and why trace context must be propagated.

### Applied
- Instruments a service with OpenTelemetry: traces, structured logs with trace correlation, and Prometheus-format metrics.
- Deploys an OTel Collector and configures fan-out to Prometheus, Tempo, and Loki.
- Defines SLOs and error budgets for a service; builds a golden signals dashboard in Grafana.
- Configures SLO burn rate alerts (fast and slow burn).

### Master
- Designs end-to-end observability for a distributed event-driven system: trace context propagation through Kafka events, correlation across all services.
- Implements tail-based sampling to capture high-value traces (errors, slow requests) without storing everything.
- Builds migration observability dashboards for Strangler Fig programmes.
- Designs and validates runbooks tied to specific alerts.

### Architect
- Defines organisation-wide observability standards: OTel SDK versions, required instrumentation, mandatory labels/attributes, SLO templates, on-call process, and runbook standards.
- Designs the observability platform: Collector topology, backend storage sizing, retention policies, and cost controls.
- Integrates observability with the security programme: audit log requirements, anomaly detection, and tamper-evident storage.
- Evaluates AI-assisted observability tools (anomaly detection, root cause suggestions) and defines when they are appropriate.

---

## AI Prompts

**Design an observability strategy:**
> Design an observability strategy for this system: [describe services, event-driven flows, databases, expected scale]. Specify: which OTel signals to collect per service, the golden signals for each, the SLO definitions, the OTel Collector topology, and the Grafana dashboard layout.

**Review an observability setup:**
> Review this observability configuration for gaps. Check: Are correlation IDs propagated across all service boundaries and event flows? Are logs structured with trace context? Are alerts SLO-based or threshold-based? Is there high-cardinality label usage in metrics? [paste config or description]

**Write an SLO definition:**
> Define an SLO for this service: [describe service, user-facing behaviour, expected latency, acceptable error rate]. Produce: the SLI formula, the SLO target, the error budget, and the fast-burn and slow-burn alert thresholds in PromQL.

**Instrument an event-driven flow:**
> I have this Kafka-based event flow: [describe producer, topics, consumers]. Write the OTel instrumentation code for producer context injection and consumer context extraction in [Go/TypeScript/Python]. Include span naming conventions and attribute standards.

**Design a migration dashboard:**
> I am running a Strangler Fig migration for [bounded context]. Design a Grafana dashboard that shows: side-by-side golden signals for legacy and new service, error budget burn rate for the new service, percentage of traffic routed to new vs legacy, and a canary health panel. Describe the PromQL queries.

---

## References

**Books**
- Charity Majors, Liz Fong-Jones, George Miranda — *Observability Engineering* (O'Reilly, 2022) — the definitive modern observability reference
- Betsy Beyer et al. — *Site Reliability Engineering* (Google, O'Reilly) — error budgets, SLOs, and SRE practices (free online)

**Standards & Projects**
- [OpenTelemetry](https://opentelemetry.io/) — CNCF standard for metrics, traces, and logs
- [Prometheus](https://prometheus.io/) — metrics collection and alerting
- [Grafana Stack](https://grafana.com/) — Prometheus, Loki (logs), Tempo (traces), unified dashboards

**Articles**
- Google SRE — [SLOs, SLIs, Error Budgets](https://sre.google/sre-book/service-level-objectives/)
- Cindy Sridharan — [Monitoring in the Time of Cloud Native](https://copyconstruct.medium.com/monitoring-in-the-time-of-cloud-native-c87c7a5bfa3e)

**Related Skills**
- `02-architecture-and-design/event-driven-architecture-cqrs` — trace context propagation through event streams is essential for EDA observability
- `06-security-and-compliance/threat-modeling-stride` — security events (auth failures, anomalous access) are observability signals; audit logs are a MELT component
- `09-re-engineering-and-evolution/strangler-fig-legacy-modernization` — migration observability (dual instrumentation, canary dashboards) is a first-class migration concern
- `05-data-and-persistence/modern-database-selection-strategy` — database golden signals (query latency, connection pool saturation, replication lag) are part of the full observability stack
