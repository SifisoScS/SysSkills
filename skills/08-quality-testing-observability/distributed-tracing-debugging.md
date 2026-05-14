---
name: Distributed Tracing & Debugging
slug: distributed-tracing-debugging
category: 08-quality-testing-observability
proficiency: advanced
description: >
  End-to-end distributed tracing in production: OpenTelemetry trace/span/
  context propagation (W3C TraceContext), head-based and tail-based sampling
  strategies, trace-correlated structured logging, Grafana Tempo with TraceQL,
  Jaeger and Zipkin backends, baggage propagation for cross-service context,
  exemplars linking metrics to traces, and systematic debugging workflows for
  latency anomalies and error cascades across microservice boundaries.
tags:
  - distributed-tracing
  - opentelemetry
  - trace-context
  - sampling
  - grafana-tempo
  - jaeger
  - baggage
  - exemplars
  - tail-based-sampling
  - debugging
status: published
---

## Principles

### 1. A Trace Is a Causal Graph, Not Just a Timeline
A **trace** is a directed acyclic graph of **spans** connected by
parent-child relationships, propagated via context headers across service
boundaries. Each span records start time, duration, service name, operation
name, status, and arbitrary key-value attributes. The root span (no parent)
anchors the entire request lifecycle. Without this causal structure, a
latency spike in service C is invisible to the engineer looking at service A.

### 2. Context Propagation Is the Most Critical Step — and the Easiest to Break
A trace only spans service boundaries if the trace context (`traceparent`
header in W3C TraceContext format) is forwarded by every hop: HTTP clients,
message consumers, async workers, gRPC calls, database clients. A single
hop that drops the header silently breaks the trace at that boundary. Context
propagation must be tested explicitly, not assumed.

### 3. Sampling Is a Trade-Off Between Cost and Coverage
Tracing every request at 100 % is expensive at high QPS. Strategies:
- **Head-based sampling**: decision made at trace entry point; fast, but
  misses interesting errors that look normal at the start
- **Tail-based sampling**: decision deferred until the trace is complete;
  captures all errors and slow traces; requires buffering in the collector
- **Probabilistic sampling** (e.g., 1 %): cheap; misses rare events
- **Rate-limiting sampling**: keep N traces/second regardless of QPS

Production recommendation: **1 % probabilistic + 100 % for errors/slow traces
via tail-based sampling in the OTel Collector**.

### 4. Traces, Metrics, and Logs Must Be Correlated
A Prometheus alert fires → the engineer clicks a metric in Grafana → an
**exemplar** on the metric links to a specific trace ID → the trace shows
which span was slow → the span links to structured logs with the same
`trace_id` field. This three-way correlation is the observability trifecta.
Without it, each signal is useful in isolation but the investigation requires
manual correlation across three disconnected tools.

### 5. Baggage Propagates Business Context, Not Just Technical IDs
W3C Baggage headers carry arbitrary key-value pairs across the entire trace:
tenant ID, user ID, experiment flag, region. Downstream services can read
baggage without being explicitly passed these values in each API call. Use
baggage for cross-cutting observability context; do not use it for
security-sensitive data (baggage is not authenticated).

---

## Implementation Patterns

### Pattern A: OTel SDK Initialisation + Auto-Instrumentation
Initialise the SDK once at process startup with an OTLP exporter pointed at
the OTel Collector. Leverage auto-instrumentation libraries (HTTP, gRPC,
database drivers) for spans without manual instrumentation. Add manual spans
only for domain-significant operations.

### Pattern B: Tail-Based Sampling in the OTel Collector
The collector buffers spans for a configurable window (e.g., 30 s), then
applies policies: keep all traces with `status.code = ERROR`, keep all traces
with latency > 500 ms, sample 1 % of the remainder. This captures every
anomaly while discarding normal traffic.

### Pattern C: Trace-Correlated Structured Logging
Inject `trace_id` and `span_id` into every structured log entry. Log
aggregators (Loki, Elasticsearch) index these fields. Clicking a trace span
in Grafana Tempo executes a Loki query for logs with the same `trace_id` —
no manual cross-referencing.

### Pattern D: Exemplars on Prometheus Metrics
A Prometheus histogram can carry an **exemplar** — a sample data point tagged
with `{traceID=...}`. When the histogram records a slow request, the exemplar
captures the trace ID for that specific request. Grafana renders exemplars as
clickable dots on the histogram, linking directly to Tempo.

---

## Anti-Patterns

| Anti-Pattern | Consequence | Fix |
|---|---|---|
| 100 % sampling in production | Trace storage costs 10–50× what metrics cost; collector becomes a bottleneck | Use tail-based sampling: 100 % errors/slow + 1 % normal |
| Propagating `traceparent` but not forwarding it in async workers | Trace broken at message queue boundary; async spans detached from root | Inject `traceparent` into message attributes; extract on consumer side |
| Manual trace ID generation (UUIDs, timestamps) | Not compatible with W3C TraceContext format; third-party tools reject them | Use OTel SDK `TraceId` generation; never generate manually |
| High-cardinality span attributes (user IDs, order IDs as attribute keys) | Index explosion in backend; slow queries; high cost | High-cardinality values go in attribute *values*, never in *keys* |
| No span status set on errors | Sampling policies that filter on `status.code = ERROR` miss these errors | Always call `span.SetStatus(codes.Error, err.Error())` on error paths |
| Tracing only HTTP boundaries | Database queries, cache calls, and async worker latency invisible | Instrument database drivers, Redis clients, and message consumers |
| Single-tenant Collector handling all services | One misconfigured service can overwhelm the Collector pipeline | Per-namespace Collector daemonset with resource limits; or agent→gateway topology |

---

## Code Templates

### Template 1 — Go: OTel SDK Bootstrap + Manual Span
```go
package telemetry

import (
    "context"
    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
    "go.opentelemetry.io/otel/propagation"
    "go.opentelemetry.io/otel/sdk/resource"
    sdktrace "go.opentelemetry.io/otel/sdk/trace"
    semconv "go.opentelemetry.io/otel/semconv/v1.26.0"
    "go.opentelemetry.io/otel/trace"
    "go.opentelemetry.io/otel/codes"
)

func InitTracer(ctx context.Context, serviceName, collectorAddr string) (func(), error) {
    exp, err := otlptracegrpc.New(ctx,
        otlptracegrpc.WithEndpoint(collectorAddr),
        otlptracegrpc.WithInsecure(),   // use TLS in production
    )
    if err != nil {
        return nil, err
    }

    res, _ := resource.New(ctx,
        resource.WithAttributes(
            semconv.ServiceName(serviceName),
            semconv.ServiceVersion("1.0.0"),
            semconv.DeploymentEnvironment("production"),
        ),
    )

    tp := sdktrace.NewTracerProvider(
        sdktrace.WithBatcher(exp),
        sdktrace.WithResource(res),
        // Head-based: sample 10 % locally; tail-based policy in Collector handles the rest
        sdktrace.WithSampler(sdktrace.ParentBased(
            sdktrace.TraceIDRatioBased(0.10),
        )),
    )
    otel.SetTracerProvider(tp)
    // W3C TraceContext + Baggage propagators
    otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
        propagation.TraceContext{},
        propagation.Baggage{},
    ))

    return func() { tp.Shutdown(context.Background()) }, nil
}

var tracer = otel.Tracer("order-service")

func ProcessOrder(ctx context.Context, orderID string) error {
    ctx, span := tracer.Start(ctx, "ProcessOrder",
        trace.WithAttributes(
            semconv.HTTPMethod("POST"),
            attribute.String("order.id", orderID),
        ),
    )
    defer span.End()

    if err := validateOrder(ctx, orderID); err != nil {
        span.SetStatus(codes.Error, err.Error())
        span.RecordError(err)
        return err
    }

    // Child span for downstream call — context carries traceparent
    ctx, dbSpan := tracer.Start(ctx, "db.insert_order")
    err := insertOrderToDB(ctx, orderID)
    dbSpan.SetStatus(statusFromErr(err))
    dbSpan.End()
    return err
}

func statusFromErr(err error) (codes.Code, string) {
    if err != nil {
        return codes.Error, err.Error()
    }
    return codes.Ok, ""
}
```

### Template 2 — TypeScript: OTel Auto-Instrumentation + Trace-Correlated Logger
```typescript
// instrumentation.ts — loaded FIRST via --require flag (Node.js)
import { NodeSDK } from '@opentelemetry/sdk-node';
import { OTLPTraceExporter } from '@opentelemetry/exporter-trace-otlp-grpc';
import { Resource } from '@opentelemetry/resources';
import { SEMRESATTRS_SERVICE_NAME } from '@opentelemetry/semantic-conventions';
import { getNodeAutoInstrumentations } from '@opentelemetry/auto-instrumentations-node';
import { ParentBasedSampler, TraceIdRatioBasedSampler } from '@opentelemetry/sdk-trace-base';

const sdk = new NodeSDK({
  resource: new Resource({ [SEMRESATTRS_SERVICE_NAME]: 'checkout-service' }),
  traceExporter: new OTLPTraceExporter({
    url: process.env.OTEL_EXPORTER_OTLP_ENDPOINT ?? 'http://otel-collector:4317',
  }),
  sampler: new ParentBasedSampler({ root: new TraceIdRatioBasedSampler(0.1) }),
  instrumentations: [getNodeAutoInstrumentations({
    '@opentelemetry/instrumentation-fs': { enabled: false },  // too noisy
  })],
});

sdk.start();
process.on('SIGTERM', () => sdk.shutdown());
```

```typescript
// logger.ts — injects trace_id and span_id into every log entry
import { context, trace } from '@opentelemetry/api';

function getTraceContext() {
  const span = trace.getActiveSpan();
  if (!span) return {};
  const ctx = span.spanContext();
  return {
    trace_id: ctx.traceId,
    span_id:  ctx.spanId,
    trace_flags: ctx.traceFlags,
  };
}

export const logger = {
  info:  (msg: string, fields?: object) =>
    console.log(JSON.stringify({ level: 'info',  msg, ...getTraceContext(), ...fields, ts: Date.now() })),
  error: (msg: string, fields?: object) =>
    console.log(JSON.stringify({ level: 'error', msg, ...getTraceContext(), ...fields, ts: Date.now() })),
  warn:  (msg: string, fields?: object) =>
    console.log(JSON.stringify({ level: 'warn',  msg, ...getTraceContext(), ...fields, ts: Date.now() })),
};

// Loki query to find all logs for a trace:
// {service="checkout-service"} | json | trace_id="4bf92f3577b34da6a3ce929d0e0e4736"
```

### Template 3 — Go: Baggage Propagation for Tenant Context
```go
package middleware

import (
    "net/http"
    "go.opentelemetry.io/otel/baggage"
    "go.opentelemetry.io/otel/propagation"
    "go.opentelemetry.io/otel"
)

// InjectTenantBaggage adds tenant_id to the trace baggage at the API gateway.
// All downstream services can read it without explicit forwarding.
func InjectTenantBaggage(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        // Extract existing context (traceparent + baggage from upstream)
        prop := otel.GetTextMapPropagator()
        ctx := prop.Extract(r.Context(), propagation.HeaderCarrier(r.Header))

        tenantID := r.Header.Get("X-Tenant-ID")
        if tenantID != "" {
            m, _ := baggage.NewMember("tenant.id", tenantID)
            b, _ := baggage.New(m)
            ctx = baggage.ContextWithBaggage(ctx, b)
        }
        next.ServeHTTP(w, r.WithContext(ctx))
    })
}

// ReadTenantFromBaggage reads tenant_id set by any upstream service.
func ReadTenantFromBaggage(ctx context.Context) string {
    b := baggage.FromContext(ctx)
    return b.Member("tenant.id").Value()
}

// ForwardBaggage injects current baggage into an outgoing HTTP request.
func ForwardBaggage(ctx context.Context, req *http.Request) {
    otel.GetTextMapPropagator().Inject(ctx, propagation.HeaderCarrier(req.Header))
}
```

### Template 4 — OTel Collector: Tail-Based Sampling Configuration
```yaml
# otel-collector-config.yaml
receivers:
  otlp:
    protocols:
      grpc: { endpoint: "0.0.0.0:4317" }
      http: { endpoint: "0.0.0.0:4318" }

processors:
  # Batch before sampling decision to improve efficiency
  batch:
    send_batch_size: 1000
    timeout: 5s

  tail_sampling:
    decision_wait: 30s       # buffer spans for 30 s before deciding
    num_traces: 100000       # max traces held in memory
    expected_new_traces_per_sec: 1000
    policies:
    # Always keep error traces
    - name: errors
      type: status_code
      status_code: { status_codes: [ERROR] }

    # Always keep slow traces (> 500 ms)
    - name: slow-traces
      type: latency
      latency: { threshold_ms: 500 }

    # Keep traces from specific high-value services regardless of outcome
    - name: payment-always
      type: string_attribute
      string_attribute:
        key: service.name
        values: [payment-service]

    # 1 % probabilistic for everything else
    - name: probabilistic-baseline
      type: probabilistic
      probabilistic: { sampling_percentage: 1 }

  # Add resource attributes for backend indexing
  resource:
    attributes:
    - key: deployment.environment
      value: production
      action: upsert

exporters:
  otlp/tempo:
    endpoint: "grafana-tempo:4317"
    tls: { insecure: true }
  prometheusremotewrite:
    endpoint: "http://prometheus:9090/api/v1/write"
  loki:
    endpoint: "http://loki:3100/loki/api/v1/push"

service:
  pipelines:
    traces:
      receivers:  [otlp]
      processors: [batch, tail_sampling, resource]
      exporters:  [otlp/tempo]
    metrics:
      receivers:  [otlp]
      processors: [batch, resource]
      exporters:  [prometheusremotewrite]
    logs:
      receivers:  [otlp]
      processors: [batch, resource]
      exporters:  [loki]
```

### Template 5 — Prometheus: Exemplar-Linked Histogram
```go
// Go: record a histogram observation with a trace ID exemplar
package metrics

import (
    "github.com/prometheus/client_golang/prometheus"
    "go.opentelemetry.io/otel/trace"
    "context"
    "net/http"
    "time"
)

var requestDuration = prometheus.NewHistogramVec(
    prometheus.HistogramOpts{
        Name:    "http_request_duration_seconds",
        Help:    "HTTP request latency with exemplars",
        Buckets: prometheus.DefBuckets,
        // Exemplars enabled automatically when NativeHistograms or standard histogram is used
    },
    []string{"method", "path", "status"},
)

func InstrumentedHandler(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        start := time.Now()
        rw := &responseWriter{ResponseWriter: w, status: 200}
        next.ServeHTTP(rw, r)
        duration := time.Since(start).Seconds()

        // Attach trace ID as exemplar — Grafana renders this as a clickable dot
        span := trace.SpanFromContext(r.Context())
        if span.SpanContext().IsValid() {
            (requestDuration.WithLabelValues(r.Method, r.URL.Path,
                http.StatusText(rw.status)).(prometheus.ExemplarObserver)).
                ObserveWithExemplar(duration, prometheus.Labels{
                    "traceID": span.SpanContext().TraceID().String(),
                })
        } else {
            requestDuration.WithLabelValues(r.Method, r.URL.Path,
                http.StatusText(rw.status)).Observe(duration)
        }
    })
}

type responseWriter struct {
    http.ResponseWriter
    status int
}
func (rw *responseWriter) WriteHeader(code int) {
    rw.status = code
    rw.ResponseWriter.WriteHeader(code)
}
```

### Template 6 — TraceQL: Grafana Tempo Queries for Debugging
```
# TraceQL — Grafana Tempo query language (Tempo 2.0+)

# Find all traces with an error span in the payment-service
{ resource.service.name = "payment-service" && status = error }

# Find slow checkout flows (end-to-end > 2 s)
{ resource.service.name = "checkout-service" && duration > 2s }

# Find traces where a specific order ID appears (attribute search)
{ span.order.id = "ord-7f3a2c" }

# Find traces where payment-service called order-service AND latency > 500 ms
{ resource.service.name = "payment-service" } >> { resource.service.name = "order-service" && duration > 500ms }

# Count of error traces per service in the last 1 hour (metrics from traces)
{ status = error } | rate() by (resource.service.name)

# P99 latency per service
{ } | quantile_over_time(duration, 0.99) by (resource.service.name)
```

```bash
# Query Tempo via HTTP API for traces matching a trace ID
curl -G "http://tempo:3200/api/traces/4bf92f3577b34da6a3ce929d0e0e4736" \
     -H "Accept: application/json" | jq '.batches[].scopeSpans[].spans[] | {name, duration: (.endTimeUnixNano - .startTimeUnixNano)}'

# Loki query to get all logs for a trace (requires trace_id JSON field in logs)
logcli query '{service="order-service"} | json | trace_id="4bf92f3577b34da6a3ce929d0e0e4736"' \
    --limit=200 --since=1h
```

---

## Decision Matrix

| Scenario | Approach | Tools |
|---|---|---|
| New greenfield service | Auto-instrumentation + OTLP to Collector | OTel SDK + auto-instrumentation libraries |
| Legacy service (no code access) | Service mesh tracing (Istio Envoy sidecar injects trace headers) | Istio + Jaeger/Tempo |
| High QPS (> 10k rps) with cost constraint | Tail-based sampling: 100 % errors, 1 % normal | OTel Collector `tail_sampling` processor |
| Debug a latency spike in production | TraceQL: `{ duration > 500ms && resource.service.name = "X" }` | Grafana Tempo |
| Correlate a metric alert to a trace | Prometheus exemplars → Tempo | `ObserveWithExemplar` + Grafana exemplar rendering |
| Multi-language system (Go + Java + Python) | OTel is the standard — one Collector handles all | OTel SDKs across languages; same W3C headers |
| Async messaging (Kafka, RabbitMQ) | Inject `traceparent` into message headers; extract on consumer | OTel messaging instrumentation libraries |
| Tracing a database query breakdown | DB client auto-instrumentation (sqlx, pg, redis) | OTel `database` semantic conventions |

---

## Proficiency Levels

### Novice
- Understands what a trace ID is and why it links requests across services
- Can read a Jaeger/Tempo waterfall view; identifies the slowest span
- Knows the difference between a trace, a span, and a log
- Adds `trace_id` to log lines manually

### Intermediate
- Initialises OTel SDK with OTLP exporter; uses auto-instrumentation
- Propagates `traceparent` header in HTTP clients and message producers
- Creates manual spans for domain operations with meaningful attributes and status
- Configures tail-based sampling in the OTel Collector
- Writes TraceQL queries in Grafana Tempo to find slow or failing traces

### Advanced
- Implements exemplars linking Prometheus metrics to specific Tempo traces
- Propagates W3C Baggage for tenant/user context across service boundaries
- Designs OTel Collector pipeline: agent → gateway topology with sampling policies
- Correlates traces, metrics, and Loki logs in a single Grafana dashboard
- Instruments Kafka consumers and producers with OTel messaging semantics
- Debugs broken context propagation across service boundaries

### Expert
- Designs organisation-wide tracing strategy: SDK versions, sampling budget, backend sizing
- Implements custom OTel Collector processors for business-specific span enrichment
- Architects multi-tenant tracing isolation (per-tenant sampling, per-tenant Tempo tenant)
- Performs trace-driven capacity planning: identifies hot paths from trace cardinality data
- Contributes to OTel semantic conventions or instrumentation libraries
- Integrates continuous profiling (Pyroscope/Parca) with traces for CPU/memory correlation

---

## AI Prompts

```
You are an OpenTelemetry expert. I have a Go microservice using net/http that
calls a PostgreSQL database and a Redis cache. Walk me through instrumenting
it with OTel: SDK initialisation, which auto-instrumentation libraries to use,
how to add manual spans for business operations, how to ensure trace_id appears
in every structured log line, and how to test that context propagation is
working end to end.
```

```
Acting as a distributed systems debugger: I have a trace showing a checkout
request taking 3.2 seconds end-to-end. The trace waterfall shows: API gateway
(50 ms) → checkout-service (3100 ms) → order-service (80 ms) + payment-service
(70 ms). The 3100 ms is in checkout-service itself. What are the five most
likely causes of this latency, and what additional span attributes or child
spans would I add to diagnose which one it is?
```

```
Explain the difference between head-based and tail-based sampling for
distributed tracing. For a service handling 50,000 requests per second where
0.1% of requests result in errors and 0.5% are slow (> 500 ms), design a
sampling strategy that captures 100% of errors and slow traces while keeping
storage costs proportional to a 1% overall sample rate. Show the OTel
Collector tail_sampling configuration.
```

```
I want to link Prometheus alert → Grafana dashboard → Tempo trace → Loki logs
in a single investigation flow with no manual copy-pasting of trace IDs.
Describe the exact configuration needed: how exemplars work in Prometheus
histograms, how Grafana Tempo is configured as a data source with exemplar
support, and how Loki is configured to allow trace_id-based log lookups.
```

```
My trace shows that context propagation breaks when messages pass through
Kafka. The producer's span ends at the Kafka write; the consumer starts a new
root span with no parent. Show the exact Go code to inject traceparent into
Kafka message headers on the producer side and extract it on the consumer side
using OpenTelemetry's messaging instrumentation conventions.
```

---

## References

- **OpenTelemetry docs** — https://opentelemetry.io/docs/
- **W3C TraceContext** — https://www.w3.org/TR/trace-context/ — `traceparent` header spec
- **W3C Baggage** — https://www.w3.org/TR/baggage/
- **Grafana Tempo** — https://grafana.com/docs/tempo/; TraceQL reference
- **Jaeger** — https://www.jaegertracing.io/docs/
- **OTel Collector** — https://opentelemetry.io/docs/collector/ — tail sampling processor
- **Prometheus Exemplars** — https://prometheus.io/docs/prometheus/latest/feature_flags/#exemplars-storage
- **OTel Semantic Conventions** — https://opentelemetry.io/docs/specs/semconv/
- **Gregg, Brendan** — *Systems Performance*, Ch. 2 (Methodologies) — USE/RED methods
- **Sridharan, Cindy** — *Distributed Systems Observability* (O'Reilly, free PDF)
- **Loki LogQL** — https://grafana.com/docs/loki/latest/logql/
- **SysSkills cross-reference** — `observability-telemetry-strategy`, `api-design-strategy`,
  `resilience-fault-tolerance-patterns`, `event-driven-architecture-cqrs`
