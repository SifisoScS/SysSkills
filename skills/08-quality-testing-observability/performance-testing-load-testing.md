---
name: Performance Testing & Load Testing
slug: performance-testing-load-testing
category: 08-quality-testing-observability
proficiency: advanced
description: >
  Design and execute performance tests that validate throughput, latency,
  and reliability under realistic load. Covers k6 scripting (load/stress/
  soak/spike profiles), Gatling simulations, distributed k6 with Kubernetes,
  realistic traffic shaping, threshold-based CI gates, flame graph profiling,
  and continuous performance regression detection.
tags:
  - performance-testing
  - load-testing
  - k6
  - gatling
  - stress-testing
  - soak-testing
  - profiling
  - benchmarking
  - ci-gates
status: published
---

## Principles

### Test Types and When to Use Each

| Test Type | Profile | Purpose |
|-----------|---------|---------|
| **Smoke test** | 1–5 VUs, 1–2 min | Verify script works; baseline sanity |
| **Load test** | Target VUs, 30–60 min | Confirm system meets SLOs at expected traffic |
| **Stress test** | Ramp beyond capacity | Find breaking point; observe failure mode |
| **Soak test** | Sustained load, 2–8 hours | Detect memory leaks, connection pool exhaustion, drift |
| **Spike test** | Sudden 10× burst | Validate autoscaling and graceful degradation |
| **Breakpoint test** | Increase until failure | Establish capacity ceiling for capacity planning |

### What to Measure
- **Throughput**: requests/second the system can sustain
- **Latency percentiles**: p50, p90, p95, p99 — never just average (averages hide tail latency)
- **Error rate**: % of requests returning errors under load
- **Resource utilisation**: CPU, memory, connection pool usage at peak
- **Saturation point**: the load level at which latency starts to degrade non-linearly (Little's Law)

### Little's Law
```
L = λ × W
L = number of concurrent requests in the system
λ = arrival rate (requests/second)
W = average response time (seconds)

Implication: if response time doubles under load, you need 2× the concurrency to maintain the same throughput.
```

### Performance Test Environment Rules
1. Test in an environment that mirrors production (same instance sizes, same network topology)
2. Isolate the system under test — don't share DB with other services during the test
3. Warm the system before measuring (JIT compilation, connection pool fill, cache warm-up)
4. Run at least 3 iterations; discard the first; report median across runs
5. Establish a baseline before any change; compare delta — not absolute values

---

## Implementation Patterns

### Pattern 1 — k6 Load Test Script (Full Suite)
```javascript
// tests/performance/payments-load-test.js
// Run: k6 run --out json=results.json tests/performance/payments-load-test.js

import http from 'k6/http';
import { check, group, sleep } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';
import { randomIntBetween } from 'https://jslib.k6.io/k6-utils/1.4.0/index.js';

// ── Custom metrics ────────────────────────────────────────────────────────────
const paymentSuccessRate = new Rate('payment_success_rate');
const paymentCreationDuration = new Trend('payment_creation_duration', true);
const paymentErrors = new Counter('payment_errors');

// ── Load profile — ramp-up, sustained, ramp-down ─────────────────────────────
export const options = {
  scenarios: {
    // Normal load test: ramp to 200 VUs, hold 30 minutes, ramp down
    load_test: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '5m',  target: 50  },  // warm-up
        { duration: '10m', target: 200 },  // ramp to target
        { duration: '30m', target: 200 },  // sustained load
        { duration: '5m',  target: 0   },  // ramp down
      ],
      gracefulRampDown: '30s',
    },
  },

  // Thresholds — test FAILS if any are breached (CI gate)
  thresholds: {
    http_req_duration: [
      'p(95)<500',   // 95% of requests under 500ms
      'p(99)<1000',  // 99% of requests under 1s
    ],
    http_req_failed: ['rate<0.01'],           // < 1% error rate
    payment_success_rate: ['rate>0.99'],      // > 99% payment success
    payment_creation_duration: ['p(99)<800'], // custom: p99 < 800ms
  },

  // Output for Prometheus remote write (k6 → Grafana)
  ext: {
    loadimpact: {
      projectID: 3478592,
    },
  },
};

// ── Test data ─────────────────────────────────────────────────────────────────
const BASE_URL = __ENV.BASE_URL || 'http://payments-service:8080';
const CURRENCIES = ['USD', 'EUR', 'GBP', 'ZAR'];

function getAuthToken() {
  // In a real test: obtain a JWT from the auth service once per VU
  return `Bearer ${__ENV.API_TOKEN}`;
}

// ── Scenario functions ────────────────────────────────────────────────────────

// Called once per VU at startup — set up session state
export function setup() {
  // Warm the cache with a few requests before measuring
  for (let i = 0; i < 5; i++) {
    http.get(`${BASE_URL}/health`);
  }
  return { startTime: Date.now() };
}

// Main VU function — called repeatedly for each virtual user
export default function () {
  const headers = {
    'Content-Type': 'application/json',
    Authorization: getAuthToken(),
  };

  group('create payment', () => {
    const payload = JSON.stringify({
      account_id: `acc-${randomIntBetween(1, 10000)}`,
      amount_cents: randomIntBetween(100, 100000),
      currency: CURRENCIES[randomIntBetween(0, CURRENCIES.length - 1)],
    });

    const start = Date.now();
    const res = http.post(`${BASE_URL}/payments`, payload, { headers, timeout: '10s' });
    const duration = Date.now() - start;

    paymentCreationDuration.add(duration);

    const success = check(res, {
      'status is 201': (r) => r.status === 201,
      'response has payment_id': (r) => {
        try {
          return JSON.parse(r.body).payment_id !== undefined;
        } catch {
          return false;
        }
      },
      'response time < 500ms': () => duration < 500,
    });

    paymentSuccessRate.add(success);
    if (!success) {
      paymentErrors.add(1);
      console.error(`Payment failed: ${res.status} — ${res.body?.substring(0, 200)}`);
    }
  });

  // Simulate realistic think time between user actions
  sleep(randomIntBetween(1, 3));

  group('read payment', () => {
    // Read a random recent payment (simulates dashboard polling)
    const paymentId = `pay-${randomIntBetween(1, 50000)}`;
    const res = http.get(`${BASE_URL}/payments/${paymentId}`, { headers });
    check(res, {
      'read status 200 or 404': (r) => r.status === 200 || r.status === 404,
    });
  });
}

// ── Stress test variant ───────────────────────────────────────────────────────
// Run with: k6 run -e SCENARIO=stress tests/performance/payments-load-test.js
export const stressOptions = {
  scenarios: {
    stress: {
      executor: 'ramping-vus',
      stages: [
        { duration: '5m',  target: 100 },
        { duration: '5m',  target: 200 },
        { duration: '5m',  target: 400 },  // 2× expected peak
        { duration: '5m',  target: 800 },  // 4× — will likely break
        { duration: '5m',  target: 0   },
      ],
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.10'],   // stress test: tolerate up to 10% errors
  },
};
```

### Pattern 2 — k6 Spike & Soak Test Profiles
```javascript
// tests/performance/spike-test.js — validates autoscaling under burst traffic

import http from 'k6/http';
import { check, sleep } from 'k6';

export const options = {
  scenarios: {
    spike: {
      executor: 'ramping-arrival-rate',
      startRate: 10,         // 10 req/s baseline
      timeUnit: '1s',
      preAllocatedVUs: 50,
      maxVUs: 500,
      stages: [
        { duration: '2m',  target: 10  },  // baseline
        { duration: '30s', target: 200 },  // spike: 20× burst in 30s
        { duration: '3m',  target: 200 },  // sustain spike
        { duration: '30s', target: 10  },  // return to baseline
        { duration: '2m',  target: 10  },  // verify recovery
      ],
    },
  },
  thresholds: {
    http_req_duration: ['p(95)<2000'],  // spike: allow p95 up to 2s
    http_req_failed:   ['rate<0.05'],   // max 5% errors during spike
  },
};

export default function () {
  const BASE_URL = __ENV.BASE_URL || 'http://payments-service:8080';
  const res = http.get(`${BASE_URL}/health`);
  check(res, { 'healthy': (r) => r.status === 200 });
  sleep(0.1);
}

// ─────────────────────────────────────────────────────────────────────────────

// tests/performance/soak-test.js — 4-hour soak to detect memory/connection leaks

export const soakOptions = {
  scenarios: {
    soak: {
      executor: 'constant-vus',
      vus: 100,        // moderate steady load
      duration: '4h',
    },
  },
  thresholds: {
    // In soak tests, watch for latency DRIFT — does p99 increase over time?
    http_req_duration: ['p(99)<1000'],
    http_req_failed:   ['rate<0.005'], // stricter error budget for long-running
  },
};
```

### Pattern 3 — Distributed k6 on Kubernetes
```yaml
# kubernetes/k6-load-test-job.yaml
# Runs k6 in distributed mode: 1 master + N workers

apiVersion: k6.io/v1alpha1
kind: TestRun
metadata:
  name: payments-load-test
  namespace: performance
spec:
  parallelism: 5          # 5 worker pods — 5× the VU capacity
  script:
    configMap:
      name: payments-k6-script
      file: payments-load-test.js
  arguments: "--out experimental-prometheus-rw"
  runner:
    image: grafana/k6:0.52.0
    resources:
      requests: { cpu: 500m, memory: 512Mi }
      limits:   { cpu: 2,    memory: 1Gi  }
    env:
      - name: BASE_URL
        value: "http://payments-service.payments.svc.cluster.local:8080"
      - name: API_TOKEN
        valueFrom:
          secretKeyRef:
            name: k6-test-secrets
            key: api-token
      - name: K6_PROMETHEUS_RW_SERVER_URL
        value: "http://prometheus-pushgateway.monitoring.svc.cluster.local:9091"
  separate: false   # all workers co-ordinated by operator
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: payments-k6-script
  namespace: performance
data:
  payments-load-test.js: |
    # content of the k6 script above (embed or mount from CI)
```

### Pattern 4 — CI Performance Gate (GitHub Actions)
```yaml
# .github/workflows/performance-gate.yml
name: Performance Gate

on:
  pull_request:
    branches: [main]
  schedule:
    - cron: '0 2 * * *'   # nightly soak test

jobs:
  smoke-test:
    name: Smoke Test (PR gate)
    runs-on: ubuntu-latest
    if: github.event_name == 'pull_request'
    services:
      payments:
        image: ${{ github.sha }}
        ports: ['8080:8080']
        env:
          DATABASE_URL: ${{ secrets.TEST_DATABASE_URL }}
    steps:
      - uses: actions/checkout@v4
      - uses: grafana/setup-k6-action@v1
        with:
          k6-version: '0.52.0'

      - name: Run smoke test
        run: |
          k6 run \
            --vus 5 \
            --duration 2m \
            --out json=smoke-results.json \
            -e BASE_URL=http://localhost:8080 \
            tests/performance/payments-load-test.js

      - name: Upload results
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: k6-smoke-results
          path: smoke-results.json

      - name: Check thresholds
        run: |
          # k6 exits with code 99 if any threshold is breached
          # The previous step already enforces this — but we also parse JSON
          python3 scripts/check_perf_regression.py smoke-results.json

  load-test:
    name: Load Test (nightly)
    runs-on: ubuntu-latest
    if: github.event_name == 'schedule'
    environment: performance
    steps:
      - uses: actions/checkout@v4
      - uses: grafana/setup-k6-action@v1

      - name: Run load test against staging
        run: |
          k6 run \
            --out json=load-results.json \
            -e BASE_URL=${{ vars.STAGING_URL }} \
            -e API_TOKEN=${{ secrets.PERF_API_TOKEN }} \
            tests/performance/payments-load-test.js
        # k6 exits non-zero if thresholds fail — job fails, blocks next deploy

      - name: Publish results to Grafana
        if: always()
        run: |
          python3 scripts/publish_perf_results.py \
            --results load-results.json \
            --grafana-url ${{ vars.GRAFANA_URL }} \
            --api-key ${{ secrets.GRAFANA_API_KEY }}
```

### Pattern 5 — Performance Regression Checker (Python)
```python
#!/usr/bin/env python3
"""Parse k6 JSON output and detect regressions against a stored baseline."""

import json
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

BASELINE_FILE = Path("tests/performance/baseline.json")

@dataclass
class PerformanceSummary:
    p95_ms: float
    p99_ms: float
    avg_ms: float
    error_rate: float
    rps: float

    def to_dict(self) -> dict:
        return {
            "p95_ms": self.p95_ms,
            "p99_ms": self.p99_ms,
            "avg_ms": self.avg_ms,
            "error_rate": self.error_rate,
            "rps": self.rps,
        }


def parse_k6_results(path: str) -> PerformanceSummary:
    """Parse k6 --out json results file (one JSON object per line)."""
    metrics: dict = {}

    with open(path) as f:
        for line in f:
            obj = json.loads(line.strip())
            if obj.get("type") == "Point":
                metric = obj["metric"]
                if metric not in metrics:
                    metrics[metric] = []
                metrics[metric].append(obj["data"]["value"])

    def percentile(values: list[float], p: float) -> float:
        if not values:
            return 0.0
        sorted_vals = sorted(values)
        idx = int(len(sorted_vals) * p / 100)
        return sorted_vals[min(idx, len(sorted_vals) - 1)]

    durations = metrics.get("http_req_duration", [])
    failures = metrics.get("http_req_failed", [])
    iterations = metrics.get("iterations", [])

    return PerformanceSummary(
        p95_ms=percentile(durations, 95),
        p99_ms=percentile(durations, 99),
        avg_ms=sum(durations) / len(durations) if durations else 0,
        error_rate=sum(failures) / len(failures) if failures else 0,
        rps=len(iterations) / 120 if iterations else 0,  # assume 2min smoke test
    )


def check_regression(current: PerformanceSummary, baseline: Optional[PerformanceSummary]) -> list[str]:
    issues = []
    if baseline is None:
        print("No baseline found — saving current as baseline.")
        return issues

    REGRESSION_THRESHOLD = 1.20  # 20% worse than baseline = regression

    checks = [
        ("p95_ms",     current.p95_ms,     baseline.p95_ms,     500.0),
        ("p99_ms",     current.p99_ms,     baseline.p99_ms,     1000.0),
        ("error_rate", current.error_rate, baseline.error_rate, 0.01),
    ]

    for name, cur, base, hard_limit in checks:
        if cur > hard_limit:
            issues.append(f"  FAIL {name} = {cur:.1f} exceeds hard limit {hard_limit}")
        elif base > 0 and cur > base * REGRESSION_THRESHOLD:
            issues.append(
                f"  REGRESSION {name}: {cur:.1f} is {((cur/base)-1)*100:.1f}% worse than baseline {base:.1f}"
            )
        else:
            print(f"  OK {name}: {cur:.1f} (baseline: {base:.1f})")

    return issues


def main():
    if len(sys.argv) < 2:
        print("Usage: check_perf_regression.py <results.json>", file=sys.stderr)
        sys.exit(1)

    current = parse_k6_results(sys.argv[1])
    print(f"\nPerformance Summary:")
    print(f"  p95:        {current.p95_ms:.1f} ms")
    print(f"  p99:        {current.p99_ms:.1f} ms")
    print(f"  avg:        {current.avg_ms:.1f} ms")
    print(f"  error rate: {current.error_rate*100:.2f}%")
    print(f"  RPS:        {current.rps:.1f}\n")

    baseline = None
    if BASELINE_FILE.exists():
        data = json.loads(BASELINE_FILE.read_text())
        baseline = PerformanceSummary(**data)

    issues = check_regression(current, baseline)

    if issues:
        print("\nPerformance issues detected:")
        for issue in issues:
            print(issue)
        sys.exit(1)

    # Update baseline on clean run in main branch
    if "--update-baseline" in sys.argv:
        BASELINE_FILE.write_text(json.dumps(current.to_dict(), indent=2))
        print(f"\nBaseline updated: {BASELINE_FILE}")

    print("\nAll performance checks passed.")


if __name__ == "__main__":
    main()
```

### Pattern 6 — Flame Graph Profiling (Go pprof + async-profiler)
```go
// Enable pprof endpoints in your Go service for profiling under load

package main

import (
	"log"
	"net/http"
	_ "net/http/pprof"  // registers /debug/pprof/* handlers
	"os"
)

func main() {
	// Expose pprof on a separate port (never expose publicly)
	if os.Getenv("ENABLE_PPROF") == "true" {
		go func() {
			log.Println("pprof listening on :6060")
			log.Fatal(http.ListenAndServe("localhost:6060", nil))
		}()
	}

	// ... rest of service startup
}
```

```bash
#!/usr/bin/env bash
# scripts/profile-under-load.sh
# Run load test and capture CPU + memory profiles simultaneously

SERVICE_HOST=${1:-localhost}
SERVICE_PORT=${2:-8080}
PPROF_PORT=${3:-6060}
DURATION=${4:-60}

echo "Starting load test + profiling for ${DURATION}s..."

# 1. Start k6 load in background
k6 run \
  --vus 50 \
  --duration "${DURATION}s" \
  -e BASE_URL="http://${SERVICE_HOST}:${SERVICE_PORT}" \
  tests/performance/payments-load-test.js &
K6_PID=$!

# 2. Wait for load to ramp (10s)
sleep 10

# 3. Capture CPU profile during peak load (30s)
echo "Capturing CPU profile..."
curl -s "http://${SERVICE_HOST}:${PPROF_PORT}/debug/pprof/profile?seconds=30" \
  -o profiles/cpu-$(date +%Y%m%d-%H%M%S).pb.gz

# 4. Capture memory (heap) profile
echo "Capturing heap profile..."
curl -s "http://${SERVICE_HOST}:${PPROF_PORT}/debug/pprof/heap" \
  -o profiles/heap-$(date +%Y%m%d-%H%M%S).pb.gz

# 5. Capture goroutine profile (look for goroutine leaks in soak tests)
echo "Capturing goroutine profile..."
curl -s "http://${SERVICE_HOST}:${PPROF_PORT}/debug/pprof/goroutine" \
  -o profiles/goroutines-$(date +%Y%m%d-%H%M%S).pb.gz

wait $K6_PID

echo ""
echo "Profiles saved to profiles/. Analyse with:"
echo "  go tool pprof -http=:8081 profiles/cpu-*.pb.gz"
echo "  go tool pprof -http=:8082 profiles/heap-*.pb.gz"
echo ""
echo "For flame graphs:"
echo "  go tool pprof -flame profiles/cpu-*.pb.gz"
```

```bash
# Continuous profiling: send profiles to Pyroscope (open-source) for ongoing visibility
# Add to your Go service — zero overhead, <1% CPU

# go get github.com/grafana/pyroscope-go

import "github.com/grafana/pyroscope-go"

pyroscope.Start(pyroscope.Config{
    ApplicationName: "payments-service",
    ServerAddress:   "http://pyroscope.monitoring.svc.cluster.local:4040",
    Logger:          pyroscope.StandardLogger,
    ProfileTypes: []pyroscope.ProfileType{
        pyroscope.ProfileCPU,
        pyroscope.ProfileAllocObjects,
        pyroscope.ProfileAllocSpace,
        pyroscope.ProfileInuseObjects,
        pyroscope.ProfileInuseSpace,
    },
    Tags: map[string]string{
        "version":     os.Getenv("APP_VERSION"),
        "environment": os.Getenv("ENVIRONMENT"),
    },
})
```

---

## Anti-Patterns

### 1. Testing with Unrealistic Traffic Patterns
All VUs hit the same endpoint with the same payload. Real traffic has variance: different accounts, different amounts, realistic think times.

**Fix**: randomise keys, amounts, and currencies. Use realistic think times (`sleep(randomIntBetween(1, 3))`). Model traffic as a mix of reads and writes matching the production ratio.

### 2. Measuring Average Latency
Average hides the worst 1–5% of requests. A system with p50 = 50ms and p99 = 5000ms has average ≈ 100ms, which looks fine, but 1 in 100 users waits 5 seconds.

**Fix**: always report p95 and p99. Set SLO thresholds on percentiles, not averages.

### 3. Running Load Tests in Production
Load tests generate synthetic traffic that competes with real users, pollutes analytics, and risks data corruption.

**Fix**: dedicated performance environment that mirrors production sizing. Use test account IDs/data that can be cleaned up.

### 4. Ignoring Warm-Up
First 30–60 seconds of a test skew results: JVM JIT compilation, connection pool filling, DNS caching. These inflated latencies don't represent steady-state performance.

**Fix**: 5-minute warm-up stage before measuring. In k6, use a ramp-up stage and exclude its data from threshold evaluation.

### 5. No Baseline — Comparing Against "Feels Fast"
Teams run a load test once and say "looks good." On the next run after a code change, they have no reference point to detect regression.

**Fix**: store baseline results in the repo. Automated regression checker compares every run against the baseline; fails CI if latency increases > 20%.

### 6. Load Testing the Load Generator
Running k6 with too many VUs on an underpowered machine. The load generator itself becomes the bottleneck — you're testing the test tool, not the service.

**Fix**: monitor k6 CPU/memory during the test. Distribute k6 across multiple pods in Kubernetes when testing at high RPS.

---

## Decision Matrix

| Scenario | Recommendation |
|----------|---------------|
| Pre-deploy validation | Smoke test (5 VUs, 2 min) in CI pipeline |
| Feature release validation | Load test at 2× current peak for 30+ min in staging |
| Capacity planning | Breakpoint test to find ceiling; add 50% headroom |
| Suspected memory leak | Soak test 4–8 hours; watch RSS and goroutine count |
| Autoscaling validation | Spike test: sudden 10× burst, verify scale-out < 60s |
| Post-incident prevention | Add load test for the specific failure scenario as regression test |
| Finding hot code paths | pprof CPU profile under load → flame graph |
| Database query performance | Profile with `EXPLAIN ANALYZE` + trace correlation in Jaeger |
| Third-party API bottleneck | Stub the dependency in load test; measure without it to isolate |
| Multi-region latency | Run k6 from AWS regions matching user geography |

---

## Proficiency Levels

### Novice
- Understands the difference between load, stress, spike, and soak tests
- Can run a basic k6 script and interpret the summary output
- Knows why p99 matters more than average latency

### Intermediate
- Writes k6 scripts with realistic traffic patterns (randomised data, think times, groups)
- Sets k6 thresholds that enforce SLOs as CI gates
- Compares results against a stored baseline to detect regressions
- Knows when to use each test type (load vs stress vs soak vs spike)

### Advanced
- Distributes k6 across Kubernetes workers for high-RPS tests
- Captures pprof CPU/heap profiles under load and interprets flame graphs
- Designs the full performance testing strategy for a new service
- Integrates continuous profiling (Pyroscope) alongside metrics
- Writes a performance regression report that guides engineering priorities

### Expert
- Builds a performance testing pipeline that runs nightly and auto-files tickets on regression
- Models realistic traffic using production trace samples (Jaeger/OpenTelemetry replay)
- Applies queueing theory (Little's Law, M/M/1) to predict capacity requirements
- Identifies non-obvious bottlenecks: GC pressure, syscall overhead, Nagle's algorithm, kernel scheduling
- Designs chaos + performance experiments: what is the latency impact of a node failure at peak load?

---

## AI Prompts

1. **Script review**: "Review this k6 script for a payment API. Is the traffic pattern realistic? Are the thresholds appropriate for a 99.9% SLO? What's missing?"

2. **Threshold design**: "My payment service has SLOs of p95 < 200ms and p99 < 500ms. Write k6 threshold rules that enforce these, plus a burn rate calculation showing how a 5% error rate during a 30-min load test affects the monthly error budget."

3. **Flame graph interpretation**: "Here is a Go pprof CPU flame graph from a load test. The service was handling 1000 req/s with p99 = 800ms. Identify the top 3 hotspots and suggest optimisations."

4. **Soak test analysis**: "My soak test ran for 4 hours. p99 latency was 120ms at hour 1, 250ms at hour 2, 450ms at hour 3. Goroutine count grew from 500 to 4000. What is causing this and how do I diagnose it?"

5. **CI strategy**: "Design a tiered performance testing strategy for our CI/CD pipeline: smoke test on every PR, load test on merge to main, weekly soak. What should each test check, how long should it run, and what should fail the build?"

---

## References

- k6 documentation — k6.io/docs — scripting, executors, thresholds, distributed execution
- k6 Operator — github.com/grafana/k6-operator — Kubernetes-native distributed k6
- Gatling documentation — gatling.io — Scala/Java-based load testing for JVM services
- Go pprof documentation — pkg.go.dev/net/http/pprof
- Pyroscope — github.com/grafana/pyroscope — continuous profiling
- Brendan Gregg — *Systems Performance* (2020) — flame graphs, profiling methodology
- Gil Tene — *How NOT to measure latency* (talk) — why averages are misleading
- USL (Universal Scalability Law) — Neil Gunther — modelling scalability limits
