---
name: SLO & Error Budget Management
slug: slo-error-budget-management
category: 08-quality-testing-observability
proficiency: advanced
description: >
  Define and operate Service Level Objectives, track error budgets, and
  use budget burn rates to drive reliability decisions. Covers SLI
  specification, multi-window burn rate alerting, Prometheus recording
  rules, error budget policies, SLO dashboards, and the feedback loop
  between reliability engineering and feature development.
tags:
  - slo
  - sli
  - sla
  - error-budget
  - burn-rate
  - prometheus
  - alerting
  - reliability
  - observability
status: published
---

## Principles

### The SLO Hierarchy
- **SLA** (Service Level Agreement): a contractual commitment to customers; breach has financial/legal consequences. Set conservatively — often 99.9% when the internal target is 99.95%.
- **SLO** (Service Level Objective): an internal reliability target. The number the engineering team is accountable to. Should be tighter than the SLA.
- **SLI** (Service Level Indicator): a quantitative measure of service behaviour. SLOs are expressed as thresholds on SLIs.

```
SLA  ≤  SLO  ≤  SLI measured value (on a good day)
```

### What Makes a Good SLI
A good SLI measures something the **user cares about**, is **measurable**, and is **actionable**:
- **Availability**: proportion of requests that succeed
- **Latency**: proportion of requests served within a threshold (e.g., < 200ms)
- **Throughput**: events processed per unit time vs target
- **Error rate**: proportion of requests that return an error
- **Freshness**: proportion of time data is within acceptable staleness

Avoid using internal metrics (CPU, memory) as SLIs — they don't correlate directly with user experience.

### Error Budget
```
Error budget = 1 − SLO target

Example: SLO = 99.9% availability over 30 days
Error budget = 0.1% of 30 days = 43.2 minutes of downtime
```
The error budget is **shared capital** between reliability and feature development:
- Budget plentiful → deploy faster, take more risk
- Budget depleted → freeze deployments, focus engineering on reliability
- Budget policy written down → removes ambiguity about what to do when budget is low

### Burn Rate Alerting
A burn rate of `n` means you are consuming your monthly budget `n×` faster than normal.

| Burn Rate | Budget Consumed | Detection Window | Severity |
|-----------|----------------|-----------------|---------|
| 14.4× | 100% in 2 hours | 1h + 5m windows | Page immediately |
| 6× | 100% in 5 days | 6h + 30m windows | Ticket urgent |
| 3× | 100% in 10 days | 3d + 6h windows | Ticket |
| 1× | Normal consumption | — | No alert |

**Multi-window alerting**: use two windows (long + short) to filter noise. Alert fires only when both windows exceed the threshold simultaneously.

### The Error Budget Policy (must be written down)
```
When error budget remaining is:
  > 50%  → No restrictions on deployments
  25–50% → Reduced deployment frequency; risky changes need SRE review
  10–25% → Freeze new features; only reliability work and hotfixes
  < 10%  → Complete deployment freeze; incident review; reliability sprint
  Depleted → Postmortem required before resuming normal velocity
```

---

## Implementation Patterns

### Pattern 1 — SLI Prometheus Recording Rules
```yaml
# prometheus/slo-recording-rules.yaml
# Pre-compute SLI metrics to make dashboard and alert queries fast

apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: payments-slo-recording-rules
  namespace: monitoring
spec:
  groups:

    # ── Availability SLI ──────────────────────────────────────────────────────
    # Good request = HTTP 2xx/3xx (not 4xx client errors, not 5xx server errors)
    # We count 4xx as good (client error, not our fault) except 429 (rate limit = our infra)
    - name: payments.sli.availability
      interval: 30s
      rules:
        - record: job:http_requests_total:rate5m
          expr: |
            sum by (job) (rate(http_requests_total[5m]))

        - record: job:http_requests_errors:rate5m
          expr: |
            sum by (job) (
              rate(http_requests_total{status=~"5..|429"}[5m])
            )

        - record: job:sli_availability:ratio_rate5m
          expr: |
            1 - (
              job:http_requests_errors:rate5m
              / job:http_requests_total:rate5m
            )

        # Multi-window burn rate numerators (needed for alerts)
        - record: job:http_requests_errors:rate1h
          expr: sum by (job) (rate(http_requests_total{status=~"5..|429"}[1h]))
        - record: job:http_requests_total:rate1h
          expr: sum by (job) (rate(http_requests_total[1h]))

        - record: job:http_requests_errors:rate6h
          expr: sum by (job) (rate(http_requests_total{status=~"5..|429"}[6h]))
        - record: job:http_requests_total:rate6h
          expr: sum by (job) (rate(http_requests_total[6h]))

        - record: job:http_requests_errors:rate3d
          expr: sum by (job) (rate(http_requests_total{status=~"5..|429"}[3d]))
        - record: job:http_requests_total:rate3d
          expr: sum by (job) (rate(http_requests_total[3d]))

        - record: job:http_requests_errors:rate30d
          expr: sum by (job) (rate(http_requests_total{status=~"5..|429"}[30d]))
        - record: job:http_requests_total:rate30d
          expr: sum by (job) (rate(http_requests_total[30d]))

    # ── Latency SLI ───────────────────────────────────────────────────────────
    # Good request = served in < 200ms (p99 target)
    - name: payments.sli.latency
      interval: 30s
      rules:
        - record: job:http_request_duration_seconds:p99_rate5m
          expr: |
            histogram_quantile(0.99,
              sum by (job, le) (rate(http_request_duration_seconds_bucket[5m]))
            )

        - record: job:sli_latency:ratio_rate5m
          expr: |
            sum by (job) (
              rate(http_request_duration_seconds_bucket{le="0.2"}[5m])
            )
            / sum by (job) (
              rate(http_request_duration_seconds_count[5m])
            )

        - record: job:sli_latency:ratio_rate1h
          expr: |
            sum by (job) (rate(http_request_duration_seconds_bucket{le="0.2"}[1h]))
            / sum by (job) (rate(http_request_duration_seconds_count[1h]))

        - record: job:sli_latency:ratio_rate6h
          expr: |
            sum by (job) (rate(http_request_duration_seconds_bucket{le="0.2"}[6h]))
            / sum by (job) (rate(http_request_duration_seconds_count[6h]))

    # ── Error Budget Burn Rate ────────────────────────────────────────────────
    - name: payments.error_budget
      interval: 30s
      rules:
        # Availability burn rate over short and long windows
        - record: job:error_budget_burn_rate_availability:1h
          expr: |
            (
              job:http_requests_errors:rate1h
              / job:http_requests_total:rate1h
            ) / (1 - 0.999)   # 0.001 = allowed error rate for 99.9% SLO

        - record: job:error_budget_burn_rate_availability:6h
          expr: |
            (
              job:http_requests_errors:rate6h
              / job:http_requests_total:rate6h
            ) / (1 - 0.999)

        - record: job:error_budget_burn_rate_availability:3d
          expr: |
            (
              job:http_requests_errors:rate3d
              / job:http_requests_total:rate3d
            ) / (1 - 0.999)

        # Remaining error budget (fraction; 1.0 = full, 0 = depleted)
        - record: job:error_budget_remaining:30d
          expr: |
            1 - (
              job:http_requests_errors:rate30d
                / job:http_requests_total:rate30d
            ) / (1 - 0.999)
```

### Pattern 2 — Multi-Window Burn Rate Alerts
```yaml
# prometheus/slo-alert-rules.yaml

apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: payments-slo-alerts
  namespace: monitoring
spec:
  groups:
    - name: payments.slo.burnrate
      rules:

        # ── Tier 1: Page immediately (burn rate 14.4×) ────────────────────────
        # Budget exhausted in ~2 hours if sustained
        - alert: PaymentsSLOBurnRateCritical
          expr: |
            job:error_budget_burn_rate_availability:1h{job="payments"} > 14.4
            and
            job:error_budget_burn_rate_availability:5m{job="payments"} > 14.4
          for: 2m
          labels:
            severity: critical
            team: payments-sre
            slo: payments-availability
          annotations:
            summary: "Payments SLO: critical burn rate {{ $value | humanize }}×"
            description: |
              Availability error budget burning at {{ $value | humanize }}× the sustainable rate.
              At this rate the monthly budget is exhausted in ~{{ printf "%.0f" (2 / $value) }} hours.
              Current 1h error ratio: {{ with printf "job:sli_availability:ratio_rate1h{job='payments'}" | query }}{{ . | first | value | humanizePercentage }}{{ end }}
            runbook: https://wiki.internal/runbooks/payments-slo-critical

        # ── Tier 2: Page (burn rate 6×) ───────────────────────────────────────
        # Budget exhausted in ~5 days if sustained
        - alert: PaymentsSLOBurnRateHigh
          expr: |
            job:error_budget_burn_rate_availability:6h{job="payments"} > 6
            and
            job:error_budget_burn_rate_availability:30m{job="payments"} > 6
          for: 15m
          labels:
            severity: warning
            team: payments-sre
            slo: payments-availability
          annotations:
            summary: "Payments SLO: elevated burn rate {{ $value | humanize }}×"
            description: |
              Budget burning at {{ $value | humanize }}× sustainable rate.
              Monthly budget exhausted in ~{{ printf "%.0f" (5 / $value * 6) }} days.
            runbook: https://wiki.internal/runbooks/payments-slo-warning

        # ── Tier 3: Ticket (burn rate 3×) ─────────────────────────────────────
        # Budget exhausted in ~10 days if sustained
        - alert: PaymentsSLOBurnRateModerate
          expr: |
            job:error_budget_burn_rate_availability:3d{job="payments"} > 3
            and
            job:error_budget_burn_rate_availability:6h{job="payments"} > 3
          for: 1h
          labels:
            severity: info
            team: payments-sre
            slo: payments-availability
          annotations:
            summary: "Payments SLO: moderate burn rate {{ $value | humanize }}×"
            description: |
              Budget burning at {{ $value | humanize }}× — review trends and plan reliability work.

        # ── Error budget nearly depleted ──────────────────────────────────────
        - alert: PaymentsErrorBudgetLow
          expr: |
            job:error_budget_remaining:30d{job="payments"} < 0.10
          for: 5m
          labels:
            severity: warning
            team: payments-sre
          annotations:
            summary: "Payments error budget below 10% for current window"
            description: |
              Only {{ $value | humanizePercentage }} of error budget remains for this 30-day window.
              Per error budget policy: freeze non-critical deployments immediately.

        # ── Latency SLO burn rate ─────────────────────────────────────────────
        - alert: PaymentsLatencySLOBurnRateCritical
          expr: |
            (1 - job:sli_latency:ratio_rate1h{job="payments"}) / (1 - 0.95) > 14.4
            and
            (1 - job:sli_latency:ratio_rate5m{job="payments"}) / (1 - 0.95) > 14.4
          for: 2m
          labels:
            severity: critical
            team: payments-sre
          annotations:
            summary: "Payments latency SLO critical burn rate"
            description: "p99 latency SLO burning at critical rate. Check for slow queries or downstream degradation."
```

### Pattern 3 — SLO Dashboard (Grafana JSON panels)
```json
{
  "panels": [
    {
      "title": "30-Day Error Budget Remaining",
      "type": "gauge",
      "targets": [
        {
          "expr": "job:error_budget_remaining:30d{job=\"payments\"} * 100",
          "legendFormat": "Error Budget %"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "percent",
          "min": 0,
          "max": 100,
          "thresholds": {
            "mode": "absolute",
            "steps": [
              { "value": null, "color": "red" },
              { "value": 10, "color": "orange" },
              { "value": 25, "color": "yellow" },
              { "value": 50, "color": "green" }
            ]
          }
        }
      }
    },
    {
      "title": "Availability SLI (5m window)",
      "type": "timeseries",
      "targets": [
        {
          "expr": "job:sli_availability:ratio_rate5m{job=\"payments\"} * 100",
          "legendFormat": "Availability %"
        },
        {
          "expr": "vector(99.9)",
          "legendFormat": "SLO Target (99.9%)"
        }
      ]
    },
    {
      "title": "Error Budget Burn Rate",
      "type": "timeseries",
      "targets": [
        {
          "expr": "job:error_budget_burn_rate_availability:1h{job=\"payments\"}",
          "legendFormat": "Burn Rate 1h"
        },
        {
          "expr": "job:error_budget_burn_rate_availability:6h{job=\"payments\"}",
          "legendFormat": "Burn Rate 6h"
        },
        {
          "expr": "vector(14.4)",
          "legendFormat": "Critical threshold (page)"
        },
        {
          "expr": "vector(6)",
          "legendFormat": "High threshold (warn)"
        }
      ]
    },
    {
      "title": "p99 Latency vs SLO Threshold",
      "type": "timeseries",
      "targets": [
        {
          "expr": "job:http_request_duration_seconds:p99_rate5m{job=\"payments\"} * 1000",
          "legendFormat": "p99 latency (ms)"
        },
        {
          "expr": "vector(200)",
          "legendFormat": "SLO threshold (200ms)"
        }
      ]
    }
  ]
}
```

### Pattern 4 — Error Budget Policy Enforcement (Go middleware)
```go
// middleware/error_budget_gate.go
// Blocks non-critical deployments when error budget is below threshold

package middleware

import (
	"context"
	"fmt"
	"net/http"
	"strconv"
)

type ErrorBudgetConfig struct {
	MetricsURL  string  // Prometheus query endpoint
	SLOJob      string
	MinBudget   float64 // 0.10 = 10% — block below this
}

// ErrorBudgetGate queries Prometheus and rejects deploy if budget is low.
// Used as a GitHub Actions step or deploy pipeline gate.
func CheckErrorBudget(ctx context.Context, cfg ErrorBudgetConfig) error {
	query := fmt.Sprintf(
		`job:error_budget_remaining:30d{job="%s"}`,
		cfg.SLOJob,
	)

	remaining, err := queryPrometheusScalar(ctx, cfg.MetricsURL, query)
	if err != nil {
		// Fail open — don't block deployments if monitoring is down
		fmt.Printf("WARNING: could not query error budget: %v. Proceeding with deploy.\n", err)
		return nil
	}

	fmt.Printf("Error budget remaining: %.1f%%\n", remaining*100)

	if remaining < cfg.MinBudget {
		return fmt.Errorf(
			"error budget %.1f%% below minimum %.1f%% — deployment blocked per error budget policy. "+
				"Fix reliability issues before deploying new features.",
			remaining*100, cfg.MinBudget*100,
		)
	}
	return nil
}

func queryPrometheusScalar(ctx context.Context, baseURL, query string) (float64, error) {
	url := fmt.Sprintf("%s/api/v1/query?query=%s", baseURL, query)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return 0, err
	}

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()

	var result struct {
		Data struct {
			Result []struct {
				Value [2]interface{} `json:"value"` // [timestamp, value_string]
			} `json:"result"`
		} `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return 0, err
	}
	if len(result.Data.Result) == 0 {
		return 0, fmt.Errorf("no data returned for query: %s", query)
	}

	return strconv.ParseFloat(result.Data.Result[0].Value[1].(string), 64)
}
```

### Pattern 5 — SLO Specification Document
```yaml
# slo/payments-service.yaml — machine-readable SLO spec (OpenSLO format)

apiVersion: openslo/v1
kind: SLO
metadata:
  name: payments-availability
  namespace: payments
spec:
  service: payments-service
  indicator:
    metadata:
      name: payments-http-availability
    spec:
      ratioMetric:
        counter: true
        good:
          metricSource:
            type: Prometheus
            spec:
              query: |
                sum(rate(http_requests_total{
                  job="payments",
                  status!~"5..|429"
                }[{{.Window}}]))
        total:
          metricSource:
            type: Prometheus
            spec:
              query: |
                sum(rate(http_requests_total{job="payments"}[{{.Window}}]))
  budgetingMethod: Occurrences
  objectives:
    - displayName: "99.9% availability"
      target: 0.999
      timeWindow:
        - duration: 30d
          isRolling: true
  alertPolicies:
    - payments-slo-burnrate-policy
---
apiVersion: openslo/v1
kind: SLO
metadata:
  name: payments-latency
  namespace: payments
spec:
  service: payments-service
  indicator:
    metadata:
      name: payments-http-latency
    spec:
      ratioMetric:
        counter: true
        good:
          metricSource:
            type: Prometheus
            spec:
              query: |
                sum(rate(http_request_duration_seconds_bucket{
                  job="payments",
                  le="0.2"
                }[{{.Window}}]))
        total:
          metricSource:
            type: Prometheus
            spec:
              query: |
                sum(rate(http_request_duration_seconds_count{job="payments"}[{{.Window}}]))
  budgetingMethod: Occurrences
  objectives:
    - displayName: "95% of requests < 200ms"
      target: 0.95
      timeWindow:
        - duration: 30d
          isRolling: true
```

### Pattern 6 — Weekly SLO Report (Python)
```python
#!/usr/bin/env python3
"""Weekly SLO report: queries Prometheus, prints budget status per service."""

import json
import sys
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Optional
import urllib.request
import urllib.parse

PROMETHEUS_URL = "http://prometheus.monitoring.svc.cluster.local:9090"

@dataclass
class SLOStatus:
    service: str
    slo_target: float
    budget_remaining: float
    burn_rate_1h: float
    burn_rate_6h: float
    current_availability: float

    @property
    def budget_pct(self) -> float:
        return self.budget_remaining * 100

    @property
    def status_emoji(self) -> str:
        if self.budget_remaining < 0.10:
            return "CRITICAL"
        if self.budget_remaining < 0.25:
            return "WARNING"
        if self.budget_remaining < 0.50:
            return "CAUTION"
        return "OK"


def query_prometheus(query: str) -> Optional[float]:
    encoded = urllib.parse.quote(query)
    url = f"{PROMETHEUS_URL}/api/v1/query?query={encoded}"
    try:
        with urllib.request.urlopen(url, timeout=10) as resp:
            data = json.loads(resp.read())
            results = data["data"]["result"]
            if not results:
                return None
            return float(results[0]["value"][1])
    except Exception as e:
        print(f"  WARNING: query failed: {e}", file=sys.stderr)
        return None


def get_slo_status(service: str, slo_target: float) -> SLOStatus:
    allowed_error = 1 - slo_target
    job = service

    budget_remaining = query_prometheus(
        f'job:error_budget_remaining:30d{{job="{job}"}}'
    ) or 0.0

    burn_rate_1h = query_prometheus(
        f'job:error_budget_burn_rate_availability:1h{{job="{job}"}}'
    ) or 0.0

    burn_rate_6h = query_prometheus(
        f'job:error_budget_burn_rate_availability:6h{{job="{job}"}}'
    ) or 0.0

    availability = query_prometheus(
        f'job:sli_availability:ratio_rate5m{{job="{job}"}}'
    ) or 0.0

    return SLOStatus(
        service=service,
        slo_target=slo_target,
        budget_remaining=budget_remaining,
        burn_rate_1h=burn_rate_1h,
        burn_rate_6h=burn_rate_6h,
        current_availability=availability,
    )


def print_report(services: list[tuple[str, float]]) -> None:
    now = datetime.now(timezone.utc)
    print(f"\n{'='*60}")
    print(f"  SLO WEEKLY REPORT — {now.strftime('%Y-%m-%d %H:%M UTC')}")
    print(f"{'='*60}\n")

    for service, slo_target in services:
        status = get_slo_status(service, slo_target)
        print(f"[{status.status_emoji}] {status.service}")
        print(f"  SLO target:          {status.slo_target*100:.2f}%")
        print(f"  Current availability:{status.current_availability*100:.3f}%")
        print(f"  Error budget left:   {status.budget_pct:.1f}%")
        print(f"  Burn rate (1h):      {status.burn_rate_1h:.2f}×")
        print(f"  Burn rate (6h):      {status.burn_rate_6h:.2f}×")
        print()

        if status.budget_remaining < 0.10:
            print(f"  ACTION REQUIRED: Deploy freeze in effect per error budget policy.")
        elif status.budget_remaining < 0.25:
            print(f"  ACTION: Review deployment schedule; prioritise reliability work.")
        print()


if __name__ == "__main__":
    services = [
        ("payments", 0.999),
        ("orders", 0.999),
        ("inventory", 0.995),
        ("notifications", 0.99),
    ]
    print_report(services)
```

---

## Anti-Patterns

### 1. Using Infrastructure Metrics as SLIs
```yaml
# WRONG — CPU doesn't measure user experience
- alert: HighCPU
  expr: cpu_usage > 0.8
  annotations:
    summary: "Service is unhealthy"
```
**Fix**: SLIs measure what users experience. Use request success rate, latency, and throughput — not CPU, memory, or thread pool size (those are symptoms to investigate, not SLOs to commit to).

### 2. SLO Target Too High (chasing 100%)
Setting 99.99% SLO when the service genuinely needs maintenance windows and deploys during business hours. No budget left means no feature development and unsustainable on-call pressure.

**Fix**: set the SLO at a level the team can defend with current reliability work. Start at 99.5%, earn the budget to invest in reliability, then raise it.

### 3. No Error Budget Policy
Teams measure error budget but have no written policy for what to do when it's low. Budget depletes, teams continue deploying features, incidents accumulate.

**Fix**: write the policy before you need it. Get leadership sign-off. Automate the gate (deploy pipeline checks budget before proceeding).

### 4. Alerting on Every SLO Violation Individually
Alerting when a single request fails, or when p99 spikes for 30 seconds. Leads to alert fatigue; on-call ignores alerts.

**Fix**: burn rate alerts with multi-window confirmation. Alert only when the rate of budget consumption is materially high and sustained.

### 5. SLOs Without User Journey Coverage
Setting availability SLOs on individual microservices but not on the end-to-end user journey (checkout, login). A service can be 100% available individually while the user journey is broken due to inter-service issues.

**Fix**: add synthetic monitoring probes (Blackbox Exporter, Playwright e2e tests) that exercise critical user journeys and feed into SLIs.

### 6. Treating SLOs as a Once-Per-Year Exercise
SLOs defined, forgotten, never reviewed. Service evolves, SLO becomes stale.

**Fix**: quarterly SLO review: is the target still right? Is the SLI measuring the right thing? Has user expectation changed?

---

## Decision Matrix

| Scenario | Recommendation |
|----------|---------------|
| New service, no history | Set initial SLO conservatively (e.g., 99.5%); tighten after 3 months of data |
| Mission-critical (payments, auth) | 99.9%+ SLO; multi-window burn rate alerts; strict error budget policy |
| Internal tooling | Softer SLO (99%); weekly rather than paged alerts |
| SLO breach root cause unknown | Burn rate tells you severity; traces/logs tell you cause — both needed |
| Microservice with dependency failures | SLO should exclude failures caused by dependencies outside team's control |
| Need to reduce on-call noise | Move from threshold alerts to burn rate alerts; require multi-window confirmation |
| Leadership asks for reliability metrics | Error budget report (% remaining) is more actionable than raw availability number |
| Feature freeze discussion | Error budget policy makes the decision data-driven, not political |
| Multiple SLOs for one service | Prioritise: availability first, latency second; separate burn rate alerts per SLO |
| Synthetic vs real-user monitoring | Synthetics for baseline; RUM (real user monitoring) for true user experience |

---

## Proficiency Levels

### Novice
- Understands the difference between SLA, SLO, and SLI
- Knows that error budget = 1 − SLO target
- Can read a burn rate gauge and understand what it means

### Intermediate
- Writes Prometheus recording rules for availability and latency SLIs
- Implements multi-window burn rate alerts (critical/warning/info tiers)
- Builds a Grafana dashboard showing error budget remaining and burn rate
- Understands why multi-window alerting reduces false positives

### Advanced
- Authors the error budget policy and gets leadership sign-off
- Implements deploy pipeline gates that check error budget before proceeding
- Designs SLIs for user journeys with synthetic probes
- Conducts quarterly SLO reviews; adjusts targets based on data
- Distinguishes between symptom-based alerts (burn rate) and cause-based diagnostics (traces)

### Expert
- Designs SLOs across a dependency graph; computes composite error budgets
- Implements adaptive burn rate thresholds based on service criticality
- Runs SLO-driven capacity planning: forecasts when budget will deplete given current growth
- Builds the feedback loop between error budget policy and engineering team OKRs
- Uses error budget as a lever in postmortem culture: "what reliability work would restore this budget?"

---

## AI Prompts

1. **SLI definition**: "I'm building SLOs for a payment processing API. Suggest the 3 most important SLIs, their measurement approach, and how each relates to user impact."

2. **Burn rate calculation**: "My SLO is 99.9% availability over 30 days. The service is currently returning errors at 2% rate. What is the burn rate? How long until the budget is exhausted? Which alert tier should fire?"

3. **Alert rule review**: "Review these Prometheus alert rules for SLO burn rate. Are the thresholds correct for a 99.9% SLO? Are the windows appropriate? Will these alerts be noisy or miss real incidents?"

4. **Error budget policy**: "Draft an error budget policy for my team. We ship 3–4 times per week. Our SLO is 99.9% availability. What should happen at each budget level?"

5. **SLO review**: "My service has been at 99.95% availability for 6 months — consistently better than the 99.9% SLO. Should I raise the SLO? What are the risks of raising it? What data should inform the decision?"

---

## References

- Google SRE Book — *Service Level Objectives* chapter (sre.google/sre-book/service-level-objectives)
- Google SRE Workbook — *Alerting on SLOs* (multi-window burn rate methodology)
- Alex Hidalgo — *Implementing Service Level Objectives* (O'Reilly, 2020)
- OpenSLO specification — github.com/openslo/openslo
- Sloth — SLO-as-code generator for Prometheus (github.com/slok/sloth)
- Pyrra — SLO monitoring tool for Kubernetes (github.com/pyrra-dev/pyrra)
- Nobl9 — commercial SLO platform
- Prometheus `histogram_quantile` documentation — correct use for latency SLIs
