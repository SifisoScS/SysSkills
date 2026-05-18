---
name: Technical Debt Management
slug: technical-debt-management
category: 09-re-engineering-and-evolution
proficiency: advanced
description: >
  Systematically identify, classify, quantify, and pay down technical debt
  without stalling feature delivery. Covers debt taxonomy, cost-of-delay
  estimation, debt tracking in backlogs, incremental refactoring strategies,
  the Boy Scout Rule, strangler fig pattern, and making debt visible to
  non-technical stakeholders.
tags:
  - technical-debt
  - refactoring
  - strangler-fig
  - code-quality
  - architecture-evolution
  - legacy-systems
  - boy-scout-rule
  - cost-of-delay
status: published
---

## Principles

### What Technical Debt Is (and Isn't)
Ward Cunningham's original metaphor: "shipping first-time code is like going into debt. A little debt speeds development so long as it is paid back promptly… The danger occurs when the debt is not repaid."

Technical debt is **not** all bad code. It exists on a spectrum:

| Type | Description | Action |
|------|-------------|--------|
| **Deliberate, prudent** | Conscious shortcut with a ticket to fix | Pay down on schedule |
| **Deliberate, reckless** | "We don't have time for design" | Stop accumulating; fix now |
| **Inadvertent, prudent** | "Now we understand the domain better" | Refactor as you learn |
| **Inadvertent, reckless** | Unknown unknowns; discovered in production | Triage by impact |

### The True Cost of Debt
Debt costs compound:
- **Slower feature development** — engineers spend time understanding complex code
- **Higher defect rate** — tightly coupled code makes regression easier
- **Onboarding friction** — new engineers take longer to be productive
- **Deployment risk** — fear of change leads to deferred releases
- **Context switching** — fires from fragile code interrupt planned work

### Cost of Delay Framework
Before prioritising debt, estimate its cost of delay:
```
Monthly cost of debt item =
  (Hours/month lost to workarounds) × (Engineer hourly cost)
  + (P(incident per month) × avg incident cost)
  + (Sprint velocity lost × business value per sprint point)
```

Items with highest monthly cost relative to fix cost are highest priority.

### Debt vs Feature Capacity
A healthy allocation rule of thumb:
- **70%** planned feature work
- **20%** debt reduction and refactoring
- **10%** infrastructure and tooling

Adjust based on debt severity. If velocity is declining quarter-over-quarter, the 20% may need to be temporarily 40%.

---

## Implementation Patterns

### Pattern 1 — Debt Inventory and Classification System
```markdown
# Technical Debt Register — Payments Service

## How to use this register
- Each item has a category, impact score (1–5), effort score (1–5), and priority
- Priority = Impact × (1 / Effort) — highest numbers tackled first
- Reviewed monthly in tech health meeting
- Items are closed when the code change is merged and verified

---

## Open Items

### DEBT-001: Payment processor client has no retry logic
- **Category**: Reliability
- **Location**: `internal/adapters/secondary/stripe/gateway.go`
- **Description**: HTTP calls to Stripe have no retry on transient failures (429, 5xx).
  Transient errors surface as payment failures to the user.
- **Impact**: 4/5 — customer-facing; causes ~0.2% false payment failures monthly
- **Effort**: 2/5 — add retry with exponential backoff; ~1 day work
- **Priority**: 4 / 2 = **2.0** ← HIGH
- **Monthly cost**: ~$800 in engineering support time + ~$2K in chargebacks
- **Owner**: @alice
- **Target sprint**: Sprint 42

---

### DEBT-002: OrderService directly queries payments database
- **Category**: Architecture
- **Location**: `order-service/src/db/payments_queries.go`
- **Description**: OrderService has a direct read connection to the payments DB,
  bypassing the PaymentsService API. Creates hidden coupling; payments schema
  changes break orders silently.
- **Impact**: 5/5 — cross-service data coupling; high blast radius on schema changes
- **Effort**: 4/5 — requires API endpoint in PaymentsService + migration in OrderService
- **Priority**: 5 / 4 = **1.25** ← MEDIUM (high impact but high effort)
- **Monthly cost**: ~1 sprint delay per payments schema change
- **Owner**: TBD
- **Target sprint**: Q3 planning

---

### DEBT-003: Config loaded at import time (not injectable)
- **Category**: Testability
- **Location**: `internal/config/config.go:12`
- **Description**: `var cfg = loadConfig()` runs at package init — config is a global.
  Tests cannot set different configs without environment variable manipulation.
- **Impact**: 2/5 — affects test reliability; medium pain
- **Effort**: 1/5 — pass config as a struct parameter; 2 hours
- **Priority**: 2 / 1 = **2.0** ← HIGH (quick win)
- **Monthly cost**: ~3h/month in flaky test investigation
- **Owner**: @bob
- **Target sprint**: Sprint 41

---

## Closed Items (last 90 days)

| ID | Description | Closed | Sprint |
|----|-------------|--------|--------|
| DEBT-000 | `PaymentRepository` had N+1 query loop | 2026-04-10 | 39 |
```

### Pattern 2 — Debt Tracking as GitHub Issues with Labels
```yaml
# .github/ISSUE_TEMPLATE/technical-debt.yml
name: Technical Debt
description: Record a technical debt item for tracking and prioritisation
title: "[DEBT] "
labels: ["technical-debt"]
body:
  - type: dropdown
    id: category
    attributes:
      label: Category
      options:
        - Reliability
        - Performance
        - Testability
        - Architecture
        - Security
        - Observability
        - Documentation
    validations:
      required: true

  - type: textarea
    id: description
    attributes:
      label: Description
      description: What is the problem? Where is it? What does it prevent?
    validations:
      required: true

  - type: dropdown
    id: impact
    attributes:
      label: Impact (1=trivial, 5=business-critical)
      options: ["1", "2", "3", "4", "5"]
    validations:
      required: true

  - type: dropdown
    id: effort
    attributes:
      label: Effort to fix (1=hours, 5=weeks)
      options: ["1", "2", "3", "4", "5"]
    validations:
      required: true

  - type: input
    id: monthly_cost
    attributes:
      label: Estimated monthly cost
      description: "Engineering hours × rate + incident probability × incident cost"
      placeholder: "$500/month in support time"

  - type: input
    id: location
    attributes:
      label: Code location
      placeholder: "internal/adapters/secondary/stripe/gateway.go:45"
```

### Pattern 3 — Boy Scout Rule (Incremental Refactoring in PRs)
```go
// BEFORE — messy function encountered while adding new feature
// (found in payments/service.go while implementing capture endpoint)

func ProcessPayment(ctx context.Context, req interface{}) (interface{}, error) {
	// TODO: this is terrible, fix someday
	r := req.(map[string]interface{})
	amt := r["amount"].(float64)
	cur := r["currency"].(string)
	acc := r["account_id"].(string)
	if amt <= 0 {
		return nil, fmt.Errorf("bad amount")
	}
	// 80 more lines of inline business logic...
	db, _ := sql.Open("postgres", os.Getenv("DB"))
	row := db.QueryRow("SELECT * FROM accounts WHERE id = $1", acc)
	// ...
}
```

```go
// AFTER — Boy Scout Rule: leave it cleaner than you found it
// Refactored as part of the PR that added the capture endpoint
// Scope: only clean up what you touched; don't rewrite the whole file

type ProcessPaymentRequest struct {
	AccountID string  `json:"account_id"`
	Amount    float64 `json:"amount"`
	Currency  string  `json:"currency"`
}

type ProcessPaymentResponse struct {
	PaymentID string `json:"payment_id"`
}

// ProcessPayment now has proper types, separated concerns, and is testable.
// The DB call moved to the repository (done as a follow-up DEBT-003 item).
func (s *PaymentService) ProcessPayment(ctx context.Context, req ProcessPaymentRequest) (ProcessPaymentResponse, error) {
	if req.Amount <= 0 {
		return ProcessPaymentResponse{}, ErrInvalidAmount
	}

	amount, err := domain.NewMoney(int64(req.Amount*100), req.Currency)
	if err != nil {
		return ProcessPaymentResponse{}, fmt.Errorf("invalid money: %w", err)
	}

	accountID, err := uuid.Parse(req.AccountID)
	if err != nil {
		return ProcessPaymentResponse{}, fmt.Errorf("invalid account_id: %w", err)
	}

	return s.createPayment.Execute(ctx, application.CreatePaymentInput{
		AccountID:   accountID,
		AmountCents: amount.Amount,
		Currency:    amount.Currency,
	})
}
```

### Pattern 4 — Strangler Fig Pattern (Incremental Legacy Migration)
```go
// Replacing a legacy payment processor integration incrementally.
// New code wraps the old; traffic shifts gradually via feature flag.

// strangler/payment_processor_router.go

package strangler

import (
	"context"
	"os"
)

// PaymentProcessorRouter routes to old or new implementation based on flag.
// Once new processor handles 100% of traffic and is proven stable, delete this file
// and the old implementation.
type PaymentProcessorRouter struct {
	legacy PaymentProcessor  // old Stripe v2 client
	modern PaymentProcessor  // new Stripe v3 client with retry + circuit breaker
	flags  FeatureFlags
}

func NewPaymentProcessorRouter(legacy, modern PaymentProcessor, flags FeatureFlags) *PaymentProcessorRouter {
	return &PaymentProcessorRouter{legacy: legacy, modern: modern, flags: flags}
}

// Charge routes to the appropriate implementation.
// Migration path: 0% → 10% → 50% → 100% new, with rollback capability.
func (r *PaymentProcessorRouter) Charge(ctx context.Context, req ChargeRequest) (ChargeResponse, error) {
	if r.flags.IsEnabled(ctx, "payments.use-new-processor") {
		resp, err := r.modern.Charge(ctx, req)
		if err != nil {
			// Shadow mode option: on new failure, fall back to legacy and log divergence
			// Useful during initial rollout to build confidence
			if r.flags.IsEnabled(ctx, "payments.processor-fallback-on-error") {
				return r.legacy.Charge(ctx, req)
			}
		}
		return resp, err
	}
	return r.legacy.Charge(ctx, req)
}

// Verify runs both implementations and compares results (shadow mode).
// Use during the parallel-run phase to validate the new implementation.
func (r *PaymentProcessorRouter) VerifyShadow(ctx context.Context, req ChargeRequest) (ChargeResponse, error) {
	legacyResp, legacyErr := r.legacy.Charge(ctx, req)
	modernResp, modernErr := r.modern.Charge(ctx, req)

	if legacyErr == nil && modernErr != nil {
		// Log divergence — modern fails where legacy succeeds
		logDivergence("charge", req, legacyResp, modernResp, legacyErr, modernErr)
	} else if legacyErr == nil && modernErr == nil {
		if legacyResp.ChargeID != modernResp.ChargeID {
			// Different outcomes — investigate
			logDivergence("charge", req, legacyResp, modernResp, nil, nil)
		}
	}

	// Return legacy result during shadow mode — safe, production traffic unaffected
	return legacyResp, legacyErr
}
```

```go
// Migration checklist for strangler fig:
//
// Week 1:  Shadow mode — run both, return legacy, log divergences
// Week 2:  5% production traffic → modern, 95% → legacy (canary)
// Week 3:  25% → modern after canary metrics look healthy
// Week 4:  100% → modern
// Week 6:  Delete legacy code and the router after two stable weeks
//
// Rollback at any point: flip feature flag back to 0%
```

### Pattern 5 — Static Analysis Debt Dashboard (Go + SonarQube-style metrics)
```go
// scripts/debt-report.go — generate a debt report from static analysis

package main

import (
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"strings"
)

type DebtItem struct {
	File    string
	Line    int
	Kind    string // TODO, FIXME, HACK, XXX
	Message string
}

func scanForDebtComments(root string) ([]DebtItem, error) {
	var items []DebtItem
	markers := []string{"TODO", "FIXME", "HACK", "XXX", "DEBT"}

	err := filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err != nil || info.IsDir() || !strings.HasSuffix(path, ".go") {
			return err
		}

		fset := token.NewFileSet()
		f, err := parser.ParseFile(fset, path, nil, parser.ParseComments)
		if err != nil {
			return nil // skip unparseable files
		}

		for _, cg := range f.Comments {
			for _, c := range cg.List {
				text := strings.TrimSpace(strings.TrimPrefix(c.Text, "//"))
				for _, marker := range markers {
					if strings.HasPrefix(strings.ToUpper(text), marker) {
						pos := fset.Position(c.Pos())
						items = append(items, DebtItem{
							File:    path,
							Line:    pos.Line,
							Kind:    marker,
							Message: text,
						})
					}
				}
			}
		}
		return nil
	})
	return items, err
}

func main() {
	root := "."
	if len(os.Args) > 1 {
		root = os.Args[1]
	}

	items, err := scanForDebtComments(root)
	if err != nil {
		fmt.Fprintf(os.Stderr, "scan error: %v\n", err)
		os.Exit(1)
	}

	counts := map[string]int{}
	for _, item := range items {
		counts[item.Kind]++
	}

	fmt.Printf("\n=== Technical Debt Report ===\n")
	fmt.Printf("Total debt comments: %d\n\n", len(items))
	for kind, count := range counts {
		fmt.Printf("  %-8s %d\n", kind+":", count)
	}

	fmt.Printf("\nTop items:\n")
	shown := 0
	for _, item := range items {
		if item.Kind == "FIXME" || item.Kind == "HACK" || item.Kind == "DEBT" {
			fmt.Printf("  %s:%d — %s\n", item.File, item.Line, item.Message)
			shown++
			if shown >= 20 {
				break
			}
		}
	}
}
```

```yaml
# .github/workflows/debt-report.yml — weekly debt trend report
name: Debt Report
on:
  schedule:
    - cron: '0 9 * * 1'   # every Monday at 9am

jobs:
  report:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Run debt scanner
        run: go run scripts/debt-report.go ./internal > debt-report.txt

      - name: Upload debt report
        uses: actions/upload-artifact@v4
        with:
          name: debt-report-${{ github.run_number }}
          path: debt-report.txt

      - name: Check debt trend
        run: |
          CURRENT=$(grep "Total debt comments:" debt-report.txt | awk '{print $NF}')
          echo "Debt comment count: ${CURRENT}"
          # In practice: compare against stored baseline and fail if increased significantly
```

### Pattern 6 — Debt Review in Sprint Ceremonies
```markdown
# Tech Health Review — Sprint 42 (15 min agenda)

## Metrics snapshot
| Metric | This Sprint | Last Sprint | Trend |
|--------|-------------|-------------|-------|
| Deploy frequency | 8 | 6 | ↑ improving |
| Change failure rate | 4% | 7% | ↑ improving |
| MTTR | 22 min | 45 min | ↑ improving |
| Open debt items | 14 | 17 | ↑ improving |
| TODO/FIXME count | 89 | 94 | ↑ improving |
| Code coverage | 74% | 71% | ↑ improving |

## Debt closed this sprint
- DEBT-003: Config now injectable — @bob (2h actual vs 1h estimated)
- DEBT-005: Remove duplicate payment status enum — @carol (30min)

## Debt added this sprint (Boy Scout Rule breaches)
- DEBT-009: Payment export CSV uses reflection — @dave (created item, not fixed yet)

## Discussion: Should DEBT-002 (cross-DB query) block Q3 features?
- Current monthly cost: ~1 sprint day per payments schema change
- Fix effort: 1 sprint (4 devs, 1 week)
- Proposal: dedicate 20% of sprint 43–44 to this item
- Decision: yes — @alice owns

## Next sprint debt allocation
- 20% capacity = 4 story points reserved for DEBT-001 (retry logic, @alice)
- DEBT-009 stays as tech debt item for sprint 44
```

---

## Anti-Patterns

### 1. Debt as a Dumping Ground for Everything Uncomfortable
Adding every code smell, stylistic disagreement, and minor inconsistency to the debt register. The register becomes noise; genuinely expensive items get lost.

**Fix**: only track debt items with a measurable cost — slows velocity, causes incidents, blocks other work, or takes > 2h to fix.

### 2. "We'll Fix It Later" Without a Ticket
Saying "we'll refactor this after the release" without creating a tracked item. The debt is invisible to planning and never gets scheduled.

**Fix**: Boy Scout Rule + mandatory debt ticket before closing any PR that introduces deliberate shortcuts.

### 3. Big-Bang Rewrites
"We're going to rewrite the entire payment service in the new architecture over the next 6 months." Big-bang rewrites almost always exceed estimates, deliver no value during the rewrite, and often replicate the original debt in new code.

**Fix**: strangler fig — replace functionality incrementally while the old system still runs. Deliver value continuously.

### 4. Debt Management Without Business Framing
Presenting debt to stakeholders as "we need to clean up the code." This competes poorly with features in prioritisation.

**Fix**: frame debt in business terms. "DEBT-002 costs us 1 sprint delay every time we change the payment schema — roughly $12K/year in engineering time. Fixing it costs $8K once."

### 5. Paying Down Debt That Doesn't Matter
Spending sprints on minor code style issues or perfectly functional but unfashionable code while high-impact debt items go unaddressed.

**Fix**: use the impact/effort scoring model. Prioritise by monthly cost, not by code aesthetics.

### 6. Never Saying No to New Debt
Allowing every deadline shortcut without push-back. Teams optimise for short-term velocity and accumulate debt faster than they pay it down.

**Fix**: debt budget — the team has a fixed "debt balance" they're allowed to carry. New deliberate debt requires retiring an existing item first, or explicit sign-off from tech lead.

---

## Decision Matrix

| Scenario | Recommendation |
|----------|---------------|
| Minor code smell in file you're editing | Fix it now (Boy Scout Rule) — 10 min, no ticket needed |
| Known shortcut taken under deadline | Create debt ticket before merging; estimate fix effort |
| Velocity declining QoQ with no explanation | Audit debt register; likely untracked accumulated debt |
| Cross-cutting architectural debt | Strangler fig migration with feature flags; never big-bang rewrite |
| Stakeholder asks to freeze all debt work | Reframe as cost: show monthly cost of each item; let them decide |
| Team disagrees on debt priority | Use impact × effort scoring; let data drive, not opinion |
| Large refactor opportunity in sprint | Timebox; use incremental approach; merge small PRs, not one giant PR |
| Debt causes incident | Move to P0; fix before any feature work resumes |
| New team member stuck in complex code | That area is a debt priority — poor onboarding is a measurable cost |
| Tech debt in a service being decommissioned | Don't pay it down — accelerate the decommission instead |

---

## Proficiency Levels

### Novice
- Understands that technical debt has a cost — it slows development over time
- Knows to create a ticket when taking a shortcut under deadline
- Applies the Boy Scout Rule to leave code better than they found it

### Intermediate
- Classifies debt by type (reliability, architecture, testability, performance)
- Uses impact/effort scoring to prioritise the debt register
- Implements incremental refactoring without big-bang rewrites
- Presents debt to stakeholders in business cost terms

### Advanced
- Applies the strangler fig pattern to replace legacy systems incrementally
- Maintains a debt register with monthly cost estimates
- Runs tech health reviews that feed into sprint planning with a fixed debt capacity
- Uses static analysis tools to track and trend debt comment counts
- Designs the debt policy: when new debt is acceptable, what requires sign-off

### Expert
- Measures the compound effect of debt on team velocity using DORA metrics
- Designs organisation-wide debt governance: debt budgets, cross-team debt visibility
- Applies formal refactoring patterns (Mikado Method) to safely unwind deeply coupled debt
- Influences hiring and team structure based on debt hotspots
- Uses architecture fitness functions to prevent debt accumulation in CI

---

## AI Prompts

1. **Debt identification**: "Review this Go service and identify the top 5 technical debt items by impact. For each, estimate the monthly cost and fix effort, and suggest a priority order."

2. **Cost framing**: "I need to convince my product manager to allocate 20% of next sprint to technical debt. DEBT-002 (cross-DB coupling) slows us by 1 day per schema change. We do 2 schema changes per sprint. Help me frame this as a business case."

3. **Strangler fig design**: "I have a legacy payment processor integration that's 3000 lines of untested code. I need to replace it with a new implementation that has retry logic and circuit breaking. Design a strangler fig migration strategy with a feature flag rollout plan."

4. **Debt register review**: "Review my debt register. Which items have the highest priority using impact/effort scoring? Are there any items that seem mis-categorised or missing key information?"

5. **Refactoring plan**: "This function is 200 lines, mixes 3 concerns, and has no tests. I need to refactor it without breaking production. What's the safest incremental approach using the Boy Scout Rule?"

---

## References

- Ward Cunningham — *The WyCash Portfolio Management System* (1992) — original debt metaphor
- Martin Fowler — *TechnicalDebt* (martinfowler.com) — debt quadrant model
- Michael Feathers — *Working Effectively with Legacy Code* (2004) — seam points, safe refactoring
- Martin Fowler — *Refactoring: Improving the Design of Existing Code* (2nd ed., 2018)
- Martin Fowler — *StranglerFigApplication* (martinfowler.com)
- Mikado Method — Ola Ellnestam & Daniel Brolund — graph-based refactoring technique
- DORA Metrics — accelerate.info — deploy frequency, change failure rate, MTTR
- SonarQube / SonarCloud — static analysis and debt tracking tooling
