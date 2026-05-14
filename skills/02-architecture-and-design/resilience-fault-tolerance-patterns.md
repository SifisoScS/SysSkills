---
name: Resilience & Fault Tolerance Patterns
slug: resilience-fault-tolerance-patterns
category: 02-architecture-and-design
proficiency: advanced
description: >
  Design systems that survive dependency failures without cascading: circuit
  breakers (closed/open/half-open state machine), retry with exponential
  backoff and full jitter, bulkhead isolation (semaphore and thread-pool),
  timeout and deadline propagation, load shedding and adaptive concurrency,
  graceful degradation with fallback strategies, and systematic chaos
  engineering (LitmusChaos, fault injection). Covers Polly (.NET), Go
  resilience primitives, Istio service mesh retry/CB config, and SLO-based
  error budget alerting as the feedback loop for resilience investment.
tags:
  - circuit-breaker
  - retry
  - bulkhead
  - timeout
  - load-shedding
  - chaos-engineering
  - polly
  - istio
  - graceful-degradation
  - error-budget
status: published
---

## Principles

### 1. Every Dependency Will Fail — Design the Failure Path First
The question is never *whether* a downstream service will be unavailable, but
*when* and *for how long*. Before writing the happy path for any external call,
answer: what does this service do when the dependency is slow? When it is down?
When it returns corrupt data? Answering these questions upfront is cheaper than
answering them at 3 AM during an incident.

### 2. Fail Fast, Not Slow — Timeouts Are Mandatory
A missing timeout on an HTTP call, DB query, or message consumer is a latency
timebomb. When the downstream slows, threads (or goroutines) accumulate waiting
for a response that may never arrive. The upstream's thread pool exhausts, and
the failure propagates upward. **Every outbound call must have a deadline.** Set
it to the 99.9th percentile of normal latency × 2, not the default (which is
often infinite).

### 3. Cascading Failure Is Prevented by Isolation, Not Retry
Retrying against a failing downstream adds load at precisely the worst moment.
The **circuit breaker** breaks the retry loop: after N consecutive failures it
opens the circuit, returning a fast failure to callers without hitting the
downstream. The bulkhead limits how much of the system's total capacity any
single dependency can consume — one slow downstream cannot exhaust all threads.

### 4. Retry Must Include Jitter to Avoid Thundering Herds
When 1 000 clients all retry a failed request after exactly 1 second, they
produce a synchronised spike that overwhelms the recovering service.
**Full jitter** (`sleep = random(0, min(cap, base * 2^attempt))`) spreads
retries across the recovery window. Exponential backoff without jitter is still
a thundering herd — just a slower one.

### 5. Chaos Engineering Is Continuous Testing, Not a One-Off Exercise
Resilience guarantees decay as code changes. A fallback wired in Q1 may be
silently broken by a refactor in Q3. Chaos engineering — deliberate, controlled
fault injection in production or staging — continuously verifies that the system
behaves as designed under realistic failure modes. Start with the weakest
dependency (highest failure rate); automate the experiments in CI.

### 6. Error Budgets Make Resilience Investment Objective
An SLO of 99.9 % availability gives 43.8 minutes/month error budget. If a
circuit breaker configuration change consumes 10 minutes of budget in staging,
that is a measurable cost. Framing resilience work as *protecting and restoring
error budget* aligns engineering decisions with business impact.

---

## Implementation Patterns

### Pattern A: Circuit Breaker State Machine
Three states: **Closed** (normal, counts failures), **Open** (fast-fail, no
downstream calls), **Half-Open** (probe with a single test request).
Transitions:
- Closed → Open: consecutive failure count OR failure rate exceeds threshold
- Open → Half-Open: after `resetTimeout` elapses
- Half-Open → Closed: probe request succeeds
- Half-Open → Open: probe request fails

### Pattern B: Retry with Exponential Backoff + Full Jitter
```
attempt 0: immediate
attempt n: sleep = random(0, min(cap, base * 2^n))
```
Use a **retry budget** (max total retries per unit time across the service) to
prevent aggregate retry amplification under widespread failure.

### Pattern C: Bulkhead via Semaphore
Limit concurrent in-flight calls to a specific downstream to a fixed count. If
the semaphore is exhausted, fail immediately (or queue briefly with a short
timeout). This prevents one slow dependency from consuming all goroutines/threads.

### Pattern D: Adaptive Concurrency Limit (TCP-BBR inspired)
Rather than a fixed semaphore, maintain a gradient-based in-flight limit that
shrinks when latency increases (indicating the downstream is under pressure) and
grows when latency is stable. Netflix's **Concurrency Limit** library and Envoy's
**adaptive concurrency filter** implement this.

### Pattern E: Graceful Degradation with Stale Cache Fallback
On circuit open or timeout: serve the last valid cached response, a default
response, or a reduced-feature response. Log the degradation as a business
metric (not just an error count) so product teams see the user impact.

---

## Anti-Patterns

| Anti-Pattern | Consequence | Fix |
|---|---|---|
| No timeout on outbound HTTP calls | Thread pool exhaustion on downstream slowness; full cascade failure | Set connect + read timeout on every client; propagate context deadlines |
| Retry without backoff or jitter | Synchronised retry spike overwhelms recovering service (thundering herd) | Exponential backoff + full jitter; respect `Retry-After` headers |
| Circuit breaker with too-tight thresholds | Opens on first error; healthy service treated as failed | Tune on error *rate* over a rolling window (e.g., > 50 % of last 20 calls) not consecutive count |
| Retrying non-idempotent operations | Duplicate payments, duplicate orders | Only retry `GET`, `PUT`, `DELETE`; treat `POST` as non-retryable unless idempotency key is used |
| Bulkhead larger than thread pool | Semaphore allows more concurrent calls than the pool can service; provides no isolation | Size bulkhead ≤ thread-pool partition allocated to that downstream |
| Circuit breaker without fallback | Open circuit returns 500 to callers — same UX as the failure it protects against | Every circuit must have a defined fallback (cache, default, degraded) |
| Chaos tests only in staging | Staging dependency topology differs from production; failures not realistic | Run chaos experiments in production during off-peak; use feature flags to scope blast radius |
| Treating all errors as retriable | 400 Bad Request, 404 Not Found will never succeed on retry; wastes budget | Only retry 429, 500, 502, 503, 504, and network-level errors; never retry 4xx client errors |

---

## Code Templates

### Template 1 — Go: Circuit Breaker State Machine
```go
package resilience

import (
    "errors"
    "sync"
    "time"
)

type State int

const (
    StateClosed   State = iota // normal operation
    StateOpen                  // fast-fail
    StateHalfOpen              // single probe request allowed
)

var ErrCircuitOpen = errors.New("circuit breaker is open")

type CircuitBreaker struct {
    mu               sync.Mutex
    state            State
    failureCount     int
    successCount     int
    failureThreshold int           // consecutive failures to open
    successThreshold int           // successes in half-open to close
    resetTimeout     time.Duration // time before open → half-open
    lastFailure      time.Time
}

func NewCircuitBreaker(failureThreshold, successThreshold int, resetTimeout time.Duration) *CircuitBreaker {
    return &CircuitBreaker{
        failureThreshold: failureThreshold,
        successThreshold: successThreshold,
        resetTimeout:     resetTimeout,
        state:            StateClosed,
    }
}

func (cb *CircuitBreaker) Allow() (func(success bool), error) {
    cb.mu.Lock()
    defer cb.mu.Unlock()

    switch cb.state {
    case StateOpen:
        if time.Since(cb.lastFailure) >= cb.resetTimeout {
            cb.state = StateHalfOpen
            cb.successCount = 0
        } else {
            return nil, ErrCircuitOpen
        }
    case StateHalfOpen:
        // Only one probe allowed at a time; subsequent callers fast-fail
        if cb.successCount < 0 {  // sentinel: probe in flight
            return nil, ErrCircuitOpen
        }
        cb.successCount = -1  // mark probe in flight
    }

    return cb.record, nil
}

func (cb *CircuitBreaker) record(success bool) {
    cb.mu.Lock()
    defer cb.mu.Unlock()

    if success {
        switch cb.state {
        case StateClosed:
            cb.failureCount = 0
        case StateHalfOpen:
            cb.successCount++
            if cb.successCount >= cb.successThreshold {
                cb.state = StateClosed
                cb.failureCount = 0
                cb.successCount = 0
            }
        }
    } else {
        cb.failureCount++
        cb.lastFailure = time.Now()
        if cb.state == StateHalfOpen || cb.failureCount >= cb.failureThreshold {
            cb.state = StateOpen
            cb.failureCount = 0
            cb.successCount = 0
        }
    }
}

// Execute wraps a function call with circuit-breaker protection.
func (cb *CircuitBreaker) Execute(fn func() error) error {
    done, err := cb.Allow()
    if err != nil {
        return err
    }
    err = fn()
    done(err == nil)
    return err
}
```

### Template 2 — Go: Retry with Exponential Backoff + Full Jitter
```go
package resilience

import (
    "context"
    "math"
    "math/rand"
    "net/http"
    "time"
)

type RetryConfig struct {
    MaxAttempts int
    BaseDelay   time.Duration
    MaxDelay    time.Duration
    // Predicate determines whether an error is retriable.
    IsRetriable func(err error) bool
}

var DefaultRetryConfig = RetryConfig{
    MaxAttempts: 4,
    BaseDelay:   100 * time.Millisecond,
    MaxDelay:    30 * time.Second,
    IsRetriable: func(err error) bool { return err != nil },
}

// fullJitter implements the "Full Jitter" algorithm from the AWS Architecture Blog.
func fullJitter(attempt int, base, cap time.Duration) time.Duration {
    exp := math.Pow(2, float64(attempt))
    ceiling := math.Min(float64(cap), float64(base)*exp)
    return time.Duration(rand.Int63n(int64(ceiling)))
}

func Retry(ctx context.Context, cfg RetryConfig, fn func(ctx context.Context) error) error {
    var lastErr error
    for attempt := 0; attempt < cfg.MaxAttempts; attempt++ {
        if err := ctx.Err(); err != nil {
            return err  // context cancelled or deadline exceeded
        }
        lastErr = fn(ctx)
        if lastErr == nil {
            return nil
        }
        if !cfg.IsRetriable(lastErr) {
            return lastErr
        }
        if attempt == cfg.MaxAttempts-1 {
            break
        }
        delay := fullJitter(attempt, cfg.BaseDelay, cfg.MaxDelay)
        select {
        case <-ctx.Done():
            return ctx.Err()
        case <-time.After(delay):
        }
    }
    return lastErr
}

// IsHTTPRetriable returns true for transient HTTP status codes.
func IsHTTPRetriable(statusCode int) bool {
    switch statusCode {
    case http.StatusTooManyRequests,
        http.StatusInternalServerError,
        http.StatusBadGateway,
        http.StatusServiceUnavailable,
        http.StatusGatewayTimeout:
        return true
    }
    return false
}
```

### Template 3 — TypeScript: Bulkhead (Semaphore) + Timeout
```typescript
// bulkhead.ts — limit concurrent in-flight calls to a downstream
export class Bulkhead {
  private inFlight = 0;
  private readonly waitQueue: Array<() => void> = [];

  constructor(
    private readonly maxConcurrent: number,
    private readonly maxQueue: number = 0
  ) {}

  async execute<T>(
    fn: () => Promise<T>,
    timeoutMs: number = 5000
  ): Promise<T> {
    await this.acquire();
    try {
      return await Promise.race([
        fn(),
        new Promise<never>((_, reject) =>
          setTimeout(() => reject(new Error(`Bulkhead timeout after ${timeoutMs}ms`)), timeoutMs)
        ),
      ]);
    } finally {
      this.release();
    }
  }

  private acquire(): Promise<void> {
    if (this.inFlight < this.maxConcurrent) {
      this.inFlight++;
      return Promise.resolve();
    }
    if (this.maxQueue > 0 && this.waitQueue.length < this.maxQueue) {
      return new Promise(resolve => this.waitQueue.push(() => { this.inFlight++; resolve(); }));
    }
    return Promise.reject(new Error('Bulkhead full — request rejected'));
  }

  private release(): void {
    const next = this.waitQueue.shift();
    if (next) {
      next();
    } else {
      this.inFlight--;
    }
  }

  get stats() {
    return { inFlight: this.inFlight, queued: this.waitQueue.length };
  }
}

// Compose circuit breaker + bulkhead + retry for a payment service call:
export class PaymentServiceClient {
  private readonly bulkhead = new Bulkhead(10, 20);  // max 10 concurrent, queue 20
  private readonly cb = new CircuitBreakerTs({ failureRateThreshold: 0.5, windowSize: 20 });

  async charge(orderId: string, amount: number): Promise<ChargeResult> {
    return this.bulkhead.execute(async () => {
      return this.cb.execute(async () => {
        const res = await fetch('/api/payments', {
          method: 'POST',
          body: JSON.stringify({ orderId, amount }),
          signal: AbortSignal.timeout(3000),   // 3 s deadline
        });
        if (!res.ok && isRetriableStatus(res.status)) throw new RetriableError(res.status);
        if (!res.ok) throw new NonRetriableError(res.status);
        return res.json() as Promise<ChargeResult>;
      });
    }, 4000);  // bulkhead timeout slightly longer than inner deadline
  }
}
```

### Template 4 — C#: Polly Resilience Pipeline (Circuit Breaker + Retry + Timeout)
```csharp
// ResiliencePipelines.cs — Polly v8 (Microsoft.Extensions.Resilience)
using Polly;
using Polly.CircuitBreaker;
using Polly.Retry;
using Polly.Timeout;

public static class ResiliencePipelines
{
    public static ResiliencePipeline<HttpResponseMessage> BuildHttpPipeline(
        ILogger logger) =>
        new ResiliencePipelineBuilder<HttpResponseMessage>()
            // 1. Outermost: overall deadline for the entire operation including retries
            .AddTimeout(new TimeoutStrategyOptions
            {
                Timeout = TimeSpan.FromSeconds(10),
                OnTimeout = args =>
                {
                    logger.LogWarning("Overall deadline exceeded for {Op}", args.Context.OperationKey);
                    return ValueTask.CompletedTask;
                },
            })
            // 2. Circuit breaker — sits outside retry so open circuit is not retried
            .AddCircuitBreaker(new CircuitBreakerStrategyOptions<HttpResponseMessage>
            {
                SamplingDuration    = TimeSpan.FromSeconds(30),
                MinimumThroughput   = 10,            // need at least 10 calls before evaluating
                FailureRatio        = 0.5,           // open if 50 % of calls fail
                BreakDuration       = TimeSpan.FromSeconds(15),
                ShouldHandle        = args => ValueTask.FromResult(
                    !args.Outcome.Result?.IsSuccessStatusCode ?? true),
                OnOpened = args =>
                {
                    logger.LogError("Circuit opened for {Op}: {Reason}",
                        args.Context.OperationKey, args.Outcome.Exception?.Message);
                    return ValueTask.CompletedTask;
                },
            })
            // 3. Retry with exponential backoff + jitter — only for retriable status codes
            .AddRetry(new RetryStrategyOptions<HttpResponseMessage>
            {
                MaxRetryAttempts    = 3,
                BackoffType         = DelayBackoffType.Exponential,
                UseJitter           = true,          // full jitter built in
                Delay               = TimeSpan.FromMilliseconds(200),
                MaxDelay            = TimeSpan.FromSeconds(5),
                ShouldHandle        = args => ValueTask.FromResult(
                    args.Outcome.Result?.StatusCode is
                        System.Net.HttpStatusCode.TooManyRequests or
                        System.Net.HttpStatusCode.InternalServerError or
                        System.Net.HttpStatusCode.BadGateway or
                        System.Net.HttpStatusCode.ServiceUnavailable or
                        System.Net.HttpStatusCode.GatewayTimeout
                    || args.Outcome.Exception is HttpRequestException),
                OnRetry = args =>
                {
                    logger.LogWarning("Retry {Attempt} for {Op} after {Delay}",
                        args.AttemptNumber, args.Context.OperationKey, args.RetryDelay);
                    return ValueTask.CompletedTask;
                },
            })
            // 4. Innermost: per-attempt timeout
            .AddTimeout(TimeSpan.FromSeconds(3))
            .Build();
}

// Registration in DI (Program.cs / Startup.cs)
// builder.Services
//     .AddHttpClient<IPaymentClient, PaymentClient>()
//     .AddResilienceHandler("payment", (builder, ctx) =>
//         builder.AddPipeline(ResiliencePipelines.BuildHttpPipeline(
//             ctx.ServiceProvider.GetRequiredService<ILogger<PaymentClient>>())));
```

### Template 5 — Istio VirtualService: Retry + Circuit Breaker
```yaml
# virtualservice-payment.yaml — Istio retry policy
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: payment-service
  namespace: production
spec:
  hosts: [payment-service]
  http:
  - route:
    - destination:
        host: payment-service
        port: { number: 8080 }
    timeout: 3s                    # per-request deadline
    retries:
      attempts: 3
      perTryTimeout: 1s
      retryOn: "gateway-error,connect-failure,retriable-4xx,503"
      # retriable-4xx covers 429; 503 covers service unavailable
---
# destinationrule-payment.yaml — Envoy circuit breaker (outlier detection)
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: payment-service
  namespace: production
spec:
  host: payment-service
  trafficPolicy:
    connectionPool:
      http:
        http1MaxPendingRequests: 100    # bulkhead: max queued requests
        http2MaxRequests: 200           # bulkhead: max concurrent requests
      tcp:
        connectTimeout: 500ms
    outlierDetection:
      # Circuit breaker: eject endpoint after 5 consecutive 5xx in 10s
      consecutiveGatewayErrors: 5
      interval: 10s
      baseEjectionTime: 30s            # minimum ejection duration
      maxEjectionPercent: 50           # never eject more than 50% of endpoints
      minHealthPercent: 50
```

### Template 6 — Python: Chaos Fault Injection Decorator
```python
"""chaos.py — lightweight fault injection for integration/chaos tests.
   Wraps any callable to inject latency, errors, or partial failures
   based on environment-controlled probability.
"""
import functools
import os
import random
import time
from typing import Any, Callable, TypeVar

F = TypeVar('F', bound=Callable[..., Any])

def chaos(
    error_rate: float = 0.0,        # probability 0.0–1.0 of raising an error
    latency_ms: float = 0.0,        # fixed extra latency in milliseconds
    latency_jitter_ms: float = 0.0, # random additional latency up to this value
    exception: type[Exception] = RuntimeError,
    enabled_env_var: str = 'CHAOS_ENABLED',
) -> Callable[[F], F]:
    """
    Decorator factory. Faults are only injected when the environment
    variable CHAOS_ENABLED=1 — safe to deploy to production with
    low-probability experiments gated by the env var.

    Usage:
        @chaos(error_rate=0.1, latency_ms=200, latency_jitter_ms=100)
        async def call_payment_service(order_id: str) -> PaymentResult:
            ...
    """
    def decorator(fn: F) -> F:
        @functools.wraps(fn)
        def wrapper(*args: Any, **kwargs: Any) -> Any:
            if os.getenv(enabled_env_var) == '1':
                # Inject latency
                delay = latency_ms + random.uniform(0, latency_jitter_ms)
                if delay > 0:
                    time.sleep(delay / 1000.0)
                # Inject error
                if error_rate > 0 and random.random() < error_rate:
                    raise exception(
                        f"[chaos] Injected {exception.__name__} in {fn.__qualname__}"
                    )
            return fn(*args, **kwargs)
        return wrapper  # type: ignore[return-value]
    return decorator


# Example — test that the payment service caller handles 10 % errors + 200 ms extra latency
@chaos(error_rate=0.1, latency_ms=200, latency_jitter_ms=150)
def call_payment_api(order_id: str, amount: float) -> dict:
    import httpx
    r = httpx.post('http://payment-service/charge',
                   json={'order_id': order_id, 'amount': amount},
                   timeout=3.0)
    r.raise_for_status()
    return r.json()


# LitmusChaos experiment definition (Kubernetes-native chaos)
LITMUS_POD_DELETE_EXPERIMENT = """
apiVersion: litmuschaos.io/v1alpha1
kind: ChaosEngine
metadata:
  name: payment-pod-delete
  namespace: production
spec:
  appinfo:
    appns: production
    applabel: app=payment-service
    appkind: deployment
  chaosServiceAccount: litmus-admin
  experiments:
  - name: pod-delete
    spec:
      components:
        env:
        - name: TOTAL_CHAOS_DURATION
          value: '60'          # seconds
        - name: CHAOS_INTERVAL
          value: '15'          # kill a pod every 15s
        - name: FORCE
          value: 'false'       # graceful termination
        - name: PODS_AFFECTED_PERC
          value: '25'          # kill 25% of pods
"""
```

---

## Decision Matrix

| Failure Scenario | Primary Pattern | Supporting Patterns | Notes |
|---|---|---|---|
| Downstream API intermittently slow | Timeout + retry with jitter | Circuit breaker (protects if slowness persists) | Set per-attempt timeout shorter than overall deadline |
| Downstream API fully down | Circuit breaker (open fast) | Fallback to cache or degraded response | Without CB, all threads block until timeout |
| Burst of requests exceeds downstream capacity | Rate limiting / load shedding | Bulkhead + retry with jitter | `429 Too Many Requests` + `Retry-After` header on the downstream |
| Cascade failure — one dependency takes down the service | Bulkhead isolation | Circuit breaker per downstream | Thread pool partitioned per downstream; failure stays contained |
| Non-idempotent operation (payment charge) | Single attempt + idempotency key | Async with polling / webhook | Never retry blindly; use idempotency key so retry is safe |
| Database connection pool exhaustion | Bulkhead (semaphore on pool checkout) | Timeout on acquire | Pool size = max concurrency the DB can handle, not application threads |
| Deployment: want to validate resilience is working | Chaos engineering (pod delete, latency inject) | Synthetic monitoring | Run during off-peak; define steady-state hypothesis before the experiment |
| Latency-based degradation (brownout, not outage) | Adaptive concurrency limit | Gradient-based circuit breaker (slow calls counted as failures) | Fixed failure count thresholds miss slow-but-not-failing downstreams |

---

## Proficiency Levels

### Novice
- Knows what a circuit breaker is conceptually (Martin Fowler pattern)
- Applies a retry in code; understands why infinite retry is dangerous
- Sets HTTP client timeouts; knows the difference between connect and read timeout
- Can read Polly or resilience4j configuration

### Intermediate
- Implements circuit breaker with correct open/half-open/closed transitions
- Applies exponential backoff + jitter and can explain the thundering herd problem
- Configures Polly pipeline (retry + CB + timeout) with correct layer ordering
- Designs a graceful degradation fallback for a specific service
- Writes integration tests that inject faults to verify the happy-fail path

### Advanced
- Designs bulkhead strategy across all downstream dependencies in a service
- Configures Istio `DestinationRule` outlier detection and `VirtualService` retry policies
- Implements adaptive concurrency limits; understands gradient-based CB approaches
- Runs chaos experiments with LitmusChaos: pod delete, network partition, latency inject
- Defines and monitors error budget consumption rates as a resilience feedback loop
- Identifies non-idempotent operations and designs idempotency key patterns

### Expert
- Architects organisation-wide resilience strategy across 50+ services with standardised libraries
- Designs chaos experiments that span multiple services (failure of A while B is degraded)
- Implements request hedging (parallel redundant requests, cancel slower) for p99 latency reduction
- Evaluates and tunes adaptive flow control (TCP BBR-inspired, token bucket, AIMD)
- Contributes to service mesh resilience configuration governance and default policy templates
- Defines SLO-aligned error budget burn rate alerts that trigger resilience investment decisions

---

## AI Prompts

```
You are a resilience engineering expert. My Go microservice calls three
downstream HTTP services: UserService, InventoryService, and PaymentService.
Design the full resilience stack for each call: timeout values, retry policy
(including which HTTP status codes to retry), circuit breaker thresholds, and
bulkhead sizing. Show the exact Go code using a circuit breaker + retry
composition and explain how the pipeline ordering matters.
```

```
Acting as a chaos engineering lead: I want to run our first chaos experiment
on the order processing service in production. The hypothesis is: "If the
PaymentService is unavailable, orders continue to be accepted and queued,
with users seeing a 'payment pending' state." Walk me through the experiment
design: steady-state definition, fault injection mechanism (LitmusChaos),
blast radius control, success criteria, and rollback plan.
```

```
Explain the difference between a circuit breaker based on consecutive error
count vs one based on error rate over a sliding window. Give a concrete
scenario where consecutive-count opens prematurely and one where it fails to
open when it should. What are the correct thresholds for a service handling
500 requests per second with an expected 0.5% baseline error rate?
```

```
My .NET service uses Polly for resilience. I have a bug: the circuit breaker
opens for 400 Bad Request errors (client errors from bad input), which causes
the circuit to open on normal traffic. Show me the corrected Polly v8 pipeline
configuration with a ShouldHandle predicate that only counts 5xx and network
errors, and explain why the layer ordering (timeout → CB → retry → per-attempt
timeout) is important.
```

```
Design the resilience strategy for a checkout service that must call
PaymentService (not idempotent), InventoryService (idempotent), and
NotificationService (fire-and-forget). For each: should it retry, how,
with what fallback, and what does the circuit breaker configuration look like?
Consider that a double-charge is a critical business failure.
```

---

## References

- **Nygard, Michael T.** — *Release It! Design and Deploy Production-Ready Software*, 2nd ed. — original circuit breaker and bulkhead patterns
- **Fowler, Martin** — *CircuitBreaker* pattern (martinfowler.com)
- **AWS Architecture Blog** — "Exponential Backoff And Jitter" (full jitter algorithm)
- **Polly docs** — https://github.com/App-vNext/Polly — .NET resilience library (v8)
- **resilience4j** — https://resilience4j.readme.io — Java/Kotlin resilience library
- **Go circuit breaker** — https://github.com/sony/gobreaker or https://github.com/afex/hystrix-go
- **Istio traffic management** — https://istio.io/docs/concepts/traffic-management/
- **Netflix Concurrency Limits** — https://github.com/Netflix/concurrency-limits
- **LitmusChaos** — https://litmuschaos.io — Kubernetes-native chaos engineering
- **Chaos Monkey** — https://netflix.github.io/chaosmonkey/
- **Principles of Chaos Engineering** — https://principlesofchaos.org
- **Kleppmann, Martin** — *Designing Data-Intensive Applications*, Ch. 8 (Distributed Systems Trouble)
- **Google SRE Book** — Ch. 21 (Handling Overload), Ch. 22 (Cascading Failures)
- **SysSkills cross-reference** — `observability-telemetry-strategy`, `api-design-strategy`,
  `cicd-gitops-strategy`, `event-driven-architecture-cqrs`
