---
name: FinOps & Cost Optimisation
slug: finops-cost-optimisation
category: 07-platform-and-infrastructure
proficiency: advanced
description: >
  Apply FinOps principles to Kubernetes and cloud infrastructure: cost
  allocation with labels and Kubecost/OpenCost, intelligent node provisioning
  with Karpenter (spot/on-demand mix), event-driven autoscaling with KEDA,
  right-sizing with VPA and Goldilocks, Savings Plans strategy, and automated
  cost anomaly detection. Covers the Inform → Optimise → Operate cycle,
  unit-economics metrics, and team chargeback reporting.
tags:
  - finops
  - cost-optimisation
  - karpenter
  - keda
  - vpa
  - kubecost
  - opencost
  - spot-instances
  - autoscaling
  - right-sizing
  - chargeback
  - unit-economics
status: complete
---

## Principles

### The FinOps Framework
FinOps (Financial Operations) is the practice of bringing financial accountability to cloud spend. The FinOps Foundation defines three iterative phases:

```
Inform  →  Optimise  →  Operate
  ↑                         │
  └─────────────────────────┘  (continuous loop)
```

| Phase | Goal | Key Actions |
|---|---|---|
| **Inform** | Visibility and allocation | Tag everything; attribute costs to teams; build dashboards |
| **Optimise** | Reduce waste | Right-size, delete idle, use spot/reserved |
| **Operate** | Continuous governance | Budgets, anomaly alerts, unit economics targets |

### Shared Responsibility Model for Cost
- **Platform team** owns: cluster-level efficiency (node utilisation, Karpenter config, Savings Plans purchasing), cost tooling (Kubecost, dashboards), tagging enforcement
- **Stream-aligned teams** own: their workload right-sizing, idle resource cleanup, application-level efficiency (query optimisation, caching, batch vs real-time trade-offs)
- **Finance/FinOps team** owns: budget setting, chargeback/showback policies, Savings Plans commitment strategy

### Chargeback vs Showback
| Model | Meaning | When to Use |
|---|---|---|
| **Showback** | Teams see their costs; no actual charge | Start here; builds awareness without friction |
| **Chargeback** | Costs deducted from team budget | Mature orgs with strong cost culture; drives behaviour change |
| **Amortised chargeback** | Reserved/Savings Plan discounts shared proportionally | Fair attribution when platform buys commitments on behalf of teams |

### Unit Economics
Track cost per meaningful business unit, not just absolute spend:

```
Cost per active user         = monthly infra cost  / MAU
Cost per transaction         = infra cost           / transactions processed
Cost per GB ingested         = storage + compute    / GB
Cost per API call            = total service cost   / API calls served
```

Unit economics expose whether spend growth is correlated with value growth. Absolute cost rising with proportional revenue growth is healthy; rising cost with flat revenue is a problem.

### Cost Allocation Taxonomy
```
Account / Subscription
└── Environment (prod / staging / dev)
    └── Team / Cost Centre
        └── Service / Application
            └── Component (api / worker / cache)
```

Every Kubernetes resource must carry labels at each layer. Labels flow into cost tools (Kubecost, OpenCost, AWS Cost Explorer) to produce team-level bills.

### Kubernetes Cost Components
```
Total cluster cost
├── Compute  (EC2/GKE nodes)
│   ├── On-demand instances
│   ├── Spot instances (60–90% cheaper, interruptible)
│   └── Reserved / Savings Plans (up to 72% cheaper, 1–3yr commit)
├── Storage  (EBS volumes, EFS, S3)
├── Network  (data transfer, NAT gateway, load balancers)
└── Managed services (RDS, ElastiCache, MSK, …)
```
Compute is typically 60–70% of total; optimising it first gives the highest leverage.

---

## Implementation Patterns

### 1. Karpenter — Intelligent Node Provisioning
Karpenter replaces the Cluster Autoscaler. It provisions the exact node type needed for pending pods (based on resource requests, node selector, affinity) rather than scaling a fixed ASG. Key advantages:
- **Bin-packing** — consolidates workloads onto fewer nodes, terminates underutilised ones
- **Spot diversity** — spreads across many instance types/AZs to reduce interruption impact
- **Disruption budgets** — respects `PodDisruptionBudget` during consolidation
- **Expiry/drift** — replaces nodes on a schedule or when AMI drifts from desired

### 2. KEDA — Event-Driven Autoscaling
KEDA scales `Deployment` / `StatefulSet` / `Job` replicas based on external event sources (Kafka lag, SQS depth, Prometheus query, cron schedule). It scales to zero when idle, eliminating the cost of always-on workers.

### 3. VPA + Goldilocks — Right-Sizing
Vertical Pod Autoscaler (VPA) in `Recommendation` mode observes actual CPU/memory usage and suggests right-sized `requests`/`limits`. Goldilocks wraps VPA in a dashboard, showing the recommended values per namespace/deployment. Teams apply recommendations rather than guessing.

### 4. OpenCost / Kubecost — Cost Allocation
OpenCost is the CNCF-incubating cost allocation engine. Kubecost is the commercial wrapper. Both attribute cluster costs to namespaces, labels, and deployments by combining node pricing (on-demand, spot, reserved rates) with pod resource consumption ratios.

### 5. Spot Instance Handling
Spot instances can be reclaimed with a 2-minute warning. Robust handling requires:
- Karpenter `NodePool` spread across many instance families/sizes
- `PodDisruptionBudget` to maintain minimum availability
- Graceful shutdown hooks (SIGTERM → drain connections → exit within 90s)
- Stateless workloads on spot; stateful (DB, Kafka brokers) on on-demand

### 6. Savings Plans / Reserved Instances
Purchase commitments for the stable **baseline** compute; cover the variable burst with on-demand/spot:
```
Total compute need (p90):  baseline
Spot pool:                  burst above baseline  (no commitment)
Savings Plan commitment:    ≈ p50 of baseline     (1-yr no-upfront)
On-demand buffer:           remainder of baseline  (no commitment)
```

---

## Anti-Patterns

| Anti-Pattern | Why It Fails | Correction |
|---|---|---|
| **No resource requests set** | Scheduler can't bin-pack; nodes over-allocated | Enforce via LimitRange defaults + admission policy |
| **Requests = Limits (hard limits)** | CPU throttling under burst; memory OOMKill | Set requests for scheduling; leave CPU limit unset; set memory limit only |
| **`latest` image tag on prod** | Karpenter can't amortise pull cost; no reproducibility | Immutable tags always |
| **One large instance type** | Poor bin-packing; expensive idle headroom | Karpenter multi-family spread |
| **No cost allocation tags** | Costs unattributable; no team accountability | Enforce tags via AWS Tag Policy + Kyverno label admission |
| **Cluster Autoscaler with fixed node groups** | Slow scale-up (3–5min); poor spot diversity | Migrate to Karpenter |
| **HPA on CPU only for queue workers** | Workers scale on CPU, not queue depth; idle or overloaded | Use KEDA with queue-length scaler |
| **VPA + HPA on same metric** | Conflicting signals; thrashing | VPA in Recommendation mode only if HPA is active on same metric |
| **Spot for stateful workloads** | Data loss on interruption (Kafka broker, DB) | Spot for stateless; on-demand for stateful |
| **Buying 3-yr Reserved all-upfront immediately** | Locks budget before usage patterns are known | Start with 1-yr no-upfront; graduate to 3-yr after 6 months of data |
| **Idle dev clusters running 24/7** | Dev clusters often used <20% of the time | KEDA cron scaler or cluster stop/start schedule for non-prod |

---

## Code Templates

### Template 1 — Karpenter NodePool + EC2NodeClass (Spot/On-Demand)

```yaml
# karpenter/node-class-general.yaml
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: general
spec:
  amiSelectorTerms:
    - alias: al2023@latest          # Amazon Linux 2023, latest patched AMI
  role: KarpenterNodeRole           # IAM role for nodes (IRSA)
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: prod-cluster    # subnets tagged at VPC level
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: prod-cluster
  tags:
    Environment: production
    ManagedBy: karpenter
    CostCentre: platform            # overridden per NodePool via node labels
  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs:
        volumeSize: 50Gi
        volumeType: gp3
        iops: 3000
        throughput: 125
        encrypted: true
        deleteOnTermination: true
  metadataOptions:
    httpTokens: required            # IMDSv2 only
    httpPutResponseHopLimit: 1
```

```yaml
# karpenter/nodepool-general.yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: general
spec:
  template:
    metadata:
      labels:
        nodepool: general
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: general

      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: [spot, on-demand]   # prefer spot; fall back to on-demand
        - key: kubernetes.io/arch
          operator: In
          values: [amd64]
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: [c, m, r]           # compute, memory, memory-optimised families
        - key: karpenter.k8s.aws/instance-generation
          operator: Gt
          values: ["3"]               # 4th gen+ only (better price/perf)
        - key: karpenter.k8s.aws/instance-size
          operator: NotIn
          values: [nano, micro, small] # too small for production workloads
        - key: topology.kubernetes.io/zone
          operator: In
          values: [eu-west-1a, eu-west-1b, eu-west-1c]

      expireAfter: 720h               # replace nodes every 30 days (AMI drift)

  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 5m             # wait 5 min before consolidating
    budgets:
      - nodes: "10%"                 # never disrupt more than 10% of nodes at once
      - schedule: "0 18 * * 5"      # Friday 18:00: freeze all disruption
        duration: 62h
        nodes: "0"

  limits:
    cpu: "500"                        # guard rail: max cluster CPU
    memory: 2000Gi

  weight: 10                          # prefer this NodePool over specialised ones
---
# karpenter/nodepool-spot-only.yaml  (for non-critical batch workloads)
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: batch-spot
spec:
  template:
    metadata:
      labels:
        nodepool: batch-spot
      annotations:
        cost-centre: data-platform
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: general
      taints:
        - key: workload-type
          value: batch
          effect: NoSchedule          # only batch pods with toleration land here
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: [spot]              # spot only; save 60–90%
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: [c, m, r, i, d]    # wider family = better spot availability
        - key: karpenter.k8s.aws/instance-cpu
          operator: In
          values: ["4", "8", "16", "32"]
      expireAfter: 168h

  disruption:
    consolidationPolicy: WhenEmpty
    consolidateAfter: 30s

  limits:
    cpu: "200"
    memory: 800Gi
```

---

### Template 2 — KEDA ScaledObjects (Kafka, SQS, Prometheus, Cron)

```yaml
# keda/scaled-object-kafka-worker.yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: payments-consumer
  namespace: payments
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: payments-consumer

  pollingInterval: 15                 # check lag every 15s
  cooldownPeriod: 60                  # wait 60s before scaling down
  minReplicaCount: 1                  # never fully scale to zero (avoid cold start for payments)
  maxReplicaCount: 50

  advanced:
    restoreToOriginalReplicaCount: false
    horizontalPodAutoscalerConfig:
      behavior:
        scaleDown:
          stabilizationWindowSeconds: 120   # don't thrash on transient lag drops
          policies:
            - type: Percent
              value: 25
              periodSeconds: 60
        scaleUp:
          stabilizationWindowSeconds: 0
          policies:
            - type: Percent
              value: 100
              periodSeconds: 30

  triggers:
    - type: kafka
      metadata:
        bootstrapServers: kafka.kafka.svc.cluster.local:9092
        consumerGroup: payments-consumer-group
        topic: payments.initiated
        lagThreshold: "100"           # 1 replica per 100 messages of lag
        offsetResetPolicy: latest
      authenticationRef:
        name: kafka-trigger-auth
---
# keda/scaled-object-sqs-worker.yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: email-dispatcher
  namespace: notifications
spec:
  scaleTargetRef:
    name: email-dispatcher
  minReplicaCount: 0                  # scale to zero when queue empty
  maxReplicaCount: 20
  pollingInterval: 30
  cooldownPeriod: 300
  triggers:
    - type: aws-sqs-queue
      authenticationRef:
        name: aws-irsa-auth
      metadata:
        queueURL: https://sqs.eu-west-1.amazonaws.com/123456789/email-dispatch
        queueLength: "5"              # 1 replica per 5 messages
        awsRegion: eu-west-1
        identityOwner: operator       # use operator IRSA (no static credentials)
---
# keda/scaled-object-prometheus.yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: fraud-scorer
  namespace: fraud
spec:
  scaleTargetRef:
    name: fraud-scorer
  minReplicaCount: 2
  maxReplicaCount: 30
  triggers:
    - type: prometheus
      metadata:
        serverAddress: http://prometheus.monitoring.svc.cluster.local:9090
        metricName: fraud_requests_pending
        threshold: "10"               # 1 replica per 10 pending requests
        query: |
          sum(fraud_scoring_queue_depth{namespace="fraud"})
---
# keda/scaled-object-cron-dev.yaml  (dev cluster cost: scale to 0 off-hours)
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: dev-all-services-cron
  namespace: dev
spec:
  scaleTargetRef:
    name: all-services-placeholder    # use per-deployment ScaledObjects in practice
  minReplicaCount: 0
  maxReplicaCount: 5
  triggers:
    - type: cron
      metadata:
        timezone: Africa/Johannesburg
        start: "0 8 * * 1-5"          # scale up Mon–Fri 08:00 SAST
        end:   "0 18 * * 1-5"         # scale down Mon–Fri 18:00 SAST
        desiredReplicas: "3"
```

```yaml
# keda/trigger-auth-kafka.yaml
apiVersion: keda.sh/v1alpha1
kind: TriggerAuthentication
metadata:
  name: kafka-trigger-auth
  namespace: payments
spec:
  secretTargetRef:
    - parameter: sasl.username
      name: kafka-credentials        # ESO-synced from Vault
      key: username
    - parameter: sasl.password
      name: kafka-credentials
      key: password
  podIdentity:
    provider: none
---
apiVersion: keda.sh/v1alpha1
kind: TriggerAuthentication
metadata:
  name: aws-irsa-auth
  namespace: notifications
spec:
  podIdentity:
    provider: aws                    # uses pod's IRSA ServiceAccount — no static keys
```

---

### Template 3 — VPA Recommendation Mode + Goldilocks Namespace Config

```yaml
# vpa/vpa-payments.yaml
# Mode: Off = only generate recommendations, never mutate pods
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: payments-service-vpa
  namespace: payments
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: payments-service

  updatePolicy:
    updateMode: "Off"               # recommendation only — never auto-evict

  resourcePolicy:
    containerPolicies:
      - containerName: payments
        minAllowed:
          cpu: 50m
          memory: 64Mi
        maxAllowed:
          cpu: "4"
          memory: 4Gi
        controlledResources: [cpu, memory]
        controlledValues: RequestsAndLimits
```

```yaml
# goldilocks/namespace-enable.yaml
# Label namespace to enable Goldilocks VPA generation for all Deployments
apiVersion: v1
kind: Namespace
metadata:
  name: payments
  labels:
    goldilocks.fairwinds.com/enabled: "true"
```

```bash
#!/bin/bash
# right-sizing-report.sh — pull VPA recommendations for a namespace
# Run after workload has been observed for at least 24h

NAMESPACE=${1:-payments}

echo "=== VPA Recommendations for namespace: $NAMESPACE ==="
echo ""

kubectl get vpa -n "$NAMESPACE" -o json | \
  python3 - <<'PYEOF'
import json, sys

data = json.load(sys.stdin)
for item in data.get("items", []):
    name = item["metadata"]["name"]
    recs = item.get("status", {}).get("recommendation", {}).get("containerRecommendations", [])
    for rec in recs:
        cname = rec["containerName"]
        lower  = rec.get("lowerBound", {})
        target = rec.get("target", {})
        upper  = rec.get("upperBound", {})
        print(f"  {name}/{cname}")
        print(f"    lowerBound : cpu={lower.get('cpu','?'):>8}  memory={lower.get('memory','?'):>10}")
        print(f"    target     : cpu={target.get('cpu','?'):>8}  memory={target.get('memory','?'):>10}  ← apply this")
        print(f"    upperBound : cpu={upper.get('cpu','?'):>8}  memory={upper.get('memory','?'):>10}")
        print()
PYEOF
```

---

### Template 4 — OpenCost Namespace Cost Allocation + Budget Alerts

```yaml
# opencost/opencost-deployment.yaml (abbreviated — use Helm in practice)
# helm install opencost opencost/opencost -n opencost --create-namespace
# Key values:
apiVersion: v1
kind: ConfigMap
metadata:
  name: opencost-config
  namespace: opencost
data:
  AWS_SPOT_DATA_ENABLED: "true"
  AWS_SPOT_DATA_REGION: "eu-west-1"
  AWS_SPOT_DATA_BUCKET: "org-spot-data-feed"    # S3 bucket receiving Spot data feed
  CLOUD_COST_ENABLED: "true"
  CLOUD_COST_MONTH_TO_DATE_INTERVAL: "6"
  EMIT_POD_ANNOTATIONS_METRIC: "true"           # expose pod annotations as metric labels
  EMIT_NAMESPACE_ANNOTATIONS_METRIC: "true"
```

```yaml
# opencost/cost-alerts.yaml — Prometheus alerting rules for budget breaches
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: finops-budget-alerts
  namespace: monitoring
  labels:
    prometheus: kube-prometheus
    role: alert-rules
spec:
  groups:
    - name: finops.budget
      interval: 1h
      rules:
        # Alert when a namespace's monthly run-rate exceeds budget
        - alert: NamespaceBudgetExceeded
          expr: |
            (
              sum by (namespace) (
                opencost_namespace_current_total_cost_usd
              ) * 730    # hours in a month → monthly run-rate
            ) > on(namespace) group_left()
            (
              kube_namespace_labels{label_monthly_budget_usd!=""}
              * on(namespace) group_left(label_monthly_budget_usd)
              kube_namespace_labels
              / 1   # placeholder; actual budget from label
            )
          for: 2h
          labels:
            severity: warning
          annotations:
            summary: "Namespace {{ $labels.namespace }} exceeding monthly budget"
            description: "Current monthly run-rate ${{ $value | humanize }} exceeds budget"

        # Alert on week-over-week cost spike > 30%
        - alert: CostSpikeDetected
          expr: |
            (
              sum by (namespace) (
                increase(opencost_namespace_current_total_cost_usd[7d])
              )
            )
            /
            (
              sum by (namespace) (
                increase(opencost_namespace_current_total_cost_usd[7d] offset 7d)
              )
            ) > 1.30
          for: 1h
          labels:
            severity: warning
          annotations:
            summary: "Cost spike in {{ $labels.namespace }}: {{ $value | humanizePercentage }} WoW increase"

        # Alert on idle nodes (< 10% CPU utilisation for 2h)
        - alert: IdleNodeDetected
          expr: |
            (
              sum by (node) (
                rate(node_cpu_seconds_total{mode!="idle"}[10m])
              )
              /
              sum by (node) (
                kube_node_status_allocatable{resource="cpu"}
              )
            ) < 0.10
          for: 2h
          labels:
            severity: info
          annotations:
            summary: "Node {{ $labels.node }} CPU utilisation < 10% for 2h — Karpenter should consolidate"
```

---

### Template 5 — Cost Attribution: Kubernetes Label Policy + AWS Tag Enforcement

```yaml
# kyverno/require-cost-labels.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-cost-labels
  annotations:
    policies.kyverno.io/title: Require Cost Allocation Labels
    policies.kyverno.io/description: >
      All Deployments, StatefulSets, and DaemonSets must carry cost allocation
      labels so Kubecost/OpenCost can attribute spend to teams and services.
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: check-cost-labels
      match:
        any:
          - resources:
              kinds: [Deployment, StatefulSet, DaemonSet]
              namespaces: ["*"]
              operations: [CREATE, UPDATE]
      exclude:
        any:
          - resources:
              namespaces: [kube-system, karpenter, cert-manager, flux-system, argocd]
      validate:
        message: >
          Missing required cost labels. Add:
          platform.company.io/team, platform.company.io/service,
          platform.company.io/cost-centre, platform.company.io/environment
        pattern:
          metadata:
            labels:
              platform.company.io/team: "?*"
              platform.company.io/service: "?*"
              platform.company.io/cost-centre: "?*"
              platform.company.io/environment: "?*"
```

```python
# scripts/finops_report.py — weekly cost report per team using AWS Cost Explorer
# Requires: boto3, pandas. Credentials via IRSA/instance profile — no static keys.
import boto3
import json
from datetime import date, timedelta
from collections import defaultdict

ce = boto3.client("ce", region_name="eu-west-1")

def get_team_costs(start: str, end: str) -> dict[str, float]:
    """Returns {team_name: total_usd} for the given date range."""
    resp = ce.get_cost_and_usage(
        TimePeriod={"Start": start, "End": end},
        Granularity="MONTHLY",
        Filter={
            "Tags": {
                "Key": "platform.company.io/team",
                "MatchOptions": ["PRESENT"],
            }
        },
        GroupBy=[
            {"Type": "TAG", "Key": "platform.company.io/team"},
        ],
        Metrics=["UnblendedCost"],
    )

    team_costs: dict[str, float] = defaultdict(float)
    for period in resp["ResultsByTime"]:
        for group in period["Groups"]:
            tag_value = group["Keys"][0].replace("platform.company.io/team$", "")
            cost = float(group["Metrics"]["UnblendedCost"]["Amount"])
            team_costs[tag_value or "untagged"] += cost
    return dict(team_costs)


def get_savings_opportunities() -> list[dict]:
    """Returns Trusted Advisor / Cost Optimisation Hub recommendations."""
    hub = boto3.client("cost-optimization-hub", region_name="us-east-1")
    recs = []
    paginator = hub.get_paginator("list_recommendations")
    for page in paginator.paginate(
        filter={"implementationEfforts": ["VeryLow", "Low"]},
        orderBy={"dimension": "EstimatedMonthlySavings", "order": "Descending"},
    ):
        for r in page["items"][:20]:  # top 20 easy wins
            recs.append({
                "service": r.get("currentResourceType"),
                "saving_usd": float(r.get("estimatedMonthlySavings", {}).get("value", 0)),
                "effort": r.get("implementationEffort"),
                "action": r.get("recommendationLookbackPeriodInDays"),
                "resource": r.get("currentResourceId", ""),
            })
    return recs


def build_weekly_report() -> str:
    today = date.today()
    start = (today - timedelta(days=today.weekday() + 7)).isoformat()
    end   = (today - timedelta(days=today.weekday())).isoformat()

    costs = get_team_costs(start, end)
    savings = get_savings_opportunities()

    lines = [
        f"# FinOps Weekly Report: {start} → {end}",
        "",
        "## Spend by Team (AWS tagged resources)",
        "",
    ]
    total = sum(costs.values())
    for team, cost in sorted(costs.items(), key=lambda x: -x[1]):
        pct = (cost / total * 100) if total else 0
        lines.append(f"| {team:<30} | ${cost:>10.2f} | {pct:>5.1f}% |")

    lines += [
        f"| {'**TOTAL**':<30} | ${total:>10.2f} | 100.0% |",
        "",
        "## Top Savings Opportunities (Low Effort)",
        "",
        "| Service | Resource | Est. Monthly Saving | Effort |",
        "|---------|----------|---------------------|--------|",
    ]
    for rec in sorted(savings, key=lambda x: -x["saving_usd"])[:10]:
        lines.append(
            f"| {rec['service']} | {rec['resource'][:40]} "
            f"| ${rec['saving_usd']:>8.2f} | {rec['effort']} |"
        )

    return "\n".join(lines)


if __name__ == "__main__":
    print(build_weekly_report())
```

---

### Template 6 — Savings Plans Coverage Dashboard (Prometheus + Grafana)

```yaml
# prometheus/recording-rules-finops.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: finops-recording-rules
  namespace: monitoring
spec:
  groups:
    - name: finops.efficiency
      interval: 5m
      rules:
        # Node CPU utilisation (requested / allocatable)
        - record: finops:node_cpu_utilisation:ratio
          expr: |
            sum by (node, nodepool) (
              kube_pod_container_resource_requests{resource="cpu"}
            )
            /
            sum by (node, nodepool) (
              kube_node_status_allocatable{resource="cpu"}
            )

        # Node memory utilisation
        - record: finops:node_memory_utilisation:ratio
          expr: |
            sum by (node, nodepool) (
              kube_pod_container_resource_requests{resource="memory"}
            )
            /
            sum by (node, nodepool) (
              kube_node_status_allocatable{resource="memory"}
            )

        # Cluster-wide bin-packing efficiency (higher = better utilisation)
        - record: finops:cluster_efficiency:ratio
          expr: |
            min(
              avg(finops:node_cpu_utilisation:ratio),
              avg(finops:node_memory_utilisation:ratio)
            )

        # Cost per namespace (requests-based allocation, not actual billing)
        # Multiply by node hourly cost for dollar estimate
        - record: finops:namespace_cpu_cost_ratio
          expr: |
            sum by (namespace) (
              kube_pod_container_resource_requests{resource="cpu"}
            )
            /
            sum (
              kube_pod_container_resource_requests{resource="cpu"}
            )

        # Spot vs on-demand node ratio
        - record: finops:spot_node_ratio
          expr: |
            count(kube_node_labels{label_karpenter_sh_capacity_type="spot"})
            /
            count(kube_node_labels)
```

```json
// grafana/finops-dashboard-snippet.json (key panels — import into Grafana)
{
  "panels": [
    {
      "title": "Cluster Bin-Packing Efficiency",
      "type": "gauge",
      "targets": [{"expr": "finops:cluster_efficiency:ratio * 100"}],
      "fieldConfig": {
        "defaults": {
          "unit": "percent",
          "thresholds": {
            "steps": [
              {"color": "red",    "value": 0},
              {"color": "yellow", "value": 50},
              {"color": "green",  "value": 70}
            ]
          }
        }
      }
    },
    {
      "title": "Spot Node Ratio",
      "type": "stat",
      "targets": [{"expr": "finops:spot_node_ratio * 100"}],
      "fieldConfig": {"defaults": {"unit": "percent"}}
    },
    {
      "title": "CPU Cost Share by Namespace",
      "type": "piechart",
      "targets": [{
        "expr": "finops:namespace_cpu_cost_ratio * 100",
        "legendFormat": "{{namespace}}"
      }]
    },
    {
      "title": "Node CPU Utilisation Heatmap",
      "type": "heatmap",
      "targets": [{
        "expr": "finops:node_cpu_utilisation:ratio",
        "legendFormat": "{{node}}"
      }]
    }
  ]
}
```

---

## Decision Matrix

| Scenario | Recommendation | Rationale |
|---|---|---|
| Replacing Cluster Autoscaler | Karpenter | Faster scale-up (30s vs 3–5min), spot diversity, bin-packing consolidation |
| Queue consumer workload | KEDA + queue scaler | Scales on actual queue depth, not CPU proxy; scales to zero when idle |
| HTTP workload with CPU signal | HPA on CPU/custom metric | Simple and sufficient; no need for KEDA unless CPU is a bad proxy |
| Memory-hungry ML inference | VPA Recommendation mode + manual apply | HPA can't help; VPA finds right memory request; apply during maintenance window |
| Dev/test workloads off-hours | KEDA cron scaler to 0 | Eliminates idle dev cost; KEDA wakes up on schedule |
| Stable baseline compute (>6mo data) | Compute Savings Plan (1-yr no-upfront) | 30–40% discount; flexible across instance families and regions |
| Short-lived batch jobs | Spot NodePool (Karpenter) + Job retries | 60–90% cheaper; retries handle interruptions transparently |
| Stateful workloads (DB, Kafka) | On-demand + Reserved | Cannot tolerate interruption; reserve for predictable baseline |
| Cost visibility without billing access | OpenCost (open source) on cluster | Namespace/label cost allocation from within cluster; no AWS account access needed |
| Team chargeback at scale | Kubecost Enterprise or AWS Cost Explorer with tags | Full billing integration; reserved/savings plan amortisation; team-level invoices |
| Too many instance types (spot pool) | Karpenter `instance-category: [c,m,r,i,d]` + generation > 3 | Wider pool = lower interruption rate; avoid very old generations |

---

## Proficiency Levels

### Level 1 — Aware
- Understands on-demand vs spot vs reserved pricing models
- Can read Kubecost/OpenCost dashboards and identify the most expensive namespaces
- Knows that resource requests affect scheduling and cost allocation
- Can label a Deployment with cost allocation labels

### Level 2 — Practitioner
- Configures Karpenter `NodePool` with spot/on-demand requirements and instance family diversity
- Writes KEDA `ScaledObject` for Kafka, SQS, and Prometheus triggers including scale-to-zero
- Reads VPA recommendations via Goldilocks and applies right-sized requests/limits
- Sets up Prometheus alerting rules for budget breaches and cost spikes
- Enforces cost labels via Kyverno `ClusterPolicy`

### Level 3 — Advanced
- Designs multi-NodePool Karpenter topology (general, batch-spot, GPU) with workload-specific taints
- Tunes Karpenter disruption budgets and expiry windows for production reliability vs cost trade-off
- Implements full cost allocation pipeline: labels → Kubecost → AWS Cost Explorer tags → team dashboards
- Writes `FinOps recording rules` and Grafana dashboards tracking cluster efficiency and spot ratio
- Runs Savings Plans coverage analysis; models commitment levels using Cost Explorer recommendations
- Builds the Python FinOps weekly report with savings opportunity surfacing

### Level 4 — Expert
- Operates multi-cluster, multi-account FinOps: consolidated billing, CUR (Cost and Usage Report) analysis, cross-account tag inheritance
- Designs unit economics tracking: instruments services to emit business-event counters; joins with billing data to produce cost-per-transaction dashboards
- Implements showback → chargeback migration: works with Finance to define amortisation model for shared infrastructure (Savings Plans, NAT gateways, control plane)
- Runs cost-aware capacity planning: models future spend under growth scenarios; drives Reserved Instance purchasing strategy with 6-month data
- Contributes to OpenCost or Karpenter upstream; shapes internal FinOps policy and governance

---

## AI Prompts

**Design a Karpenter NodePool topology**
```
Design a Karpenter NodePool topology for a production Kubernetes cluster with:
- General workloads: mix of spot/on-demand, c/m/r instance families, 4th gen+
- Batch/ML workloads: spot-only, larger instances (8–64 vCPU), taint-isolated
- Stateful workloads (Kafka, Redis): on-demand only, io-optimised families
- GPU inference: spot g5/p4 instances, separate NodePool with nvidia.com/gpu taint

For each NodePool include: EC2NodeClass reference, requirements, disruption policy,
and expiry. Include a disruption budget that prevents >10% node churn simultaneously.
Output: EC2NodeClass YAML + 4 NodePool YAMLs.
```

**Write KEDA ScaledObjects for a service**
```
Write KEDA ScaledObjects for:
1. A Kafka consumer in namespace [ns], consumer group [cg], topic [topic],
   scale 1 replica per [N] messages of lag, min [x] max [y] replicas
2. An SQS worker in namespace [ns], queue URL [url], region [region],
   scale to zero when empty, max [y] replicas
3. A cron-based dev environment in namespace dev that scales to 0 at 18:00 SAST
   and back to [n] at 08:00 SAST Mon–Fri

Use IRSA (podIdentity: aws) for AWS triggers — no static credentials.
Include TriggerAuthentication objects where needed.
```

**Audit Kubernetes resource requests for waste**
```
Audit these Deployment resource request/limit configurations for waste and
right-sizing opportunities. For each, classify as: over-provisioned,
under-provisioned, or missing, and suggest corrected values.
[paste kubectl get deployments -o yaml output or Goldilocks screenshot]

Also flag: any Deployment with CPU limit set (causes throttling), any without
memory limit (OOMKill risk), and any running HPA + VPA on the same metric.
```

**Model Savings Plan commitment level**
```
I have the following AWS compute usage data over the past 6 months:
[paste Cost Explorer on-demand spend by week]

Recommend a Compute Savings Plan commitment level using this logic:
- Baseline = p50 of weekly on-demand spend converted to hourly commitment
- Cover baseline with 1-yr no-upfront Compute Savings Plan
- Leave burst above baseline as on-demand
- Estimate annual saving vs current all-on-demand spend
Show the calculation and the recommended hourly commitment amount in USD.
```

**Generate a FinOps cost allocation report**
```
Write a Python script that queries AWS Cost Explorer and produces a weekly
Markdown report showing:
1. Spend by team (grouped by tag platform.company.io/team)
2. Week-over-week change per team
3. Top 10 savings opportunities from Cost Optimisation Hub (low effort only)
4. Cluster efficiency metrics from Prometheus (CPU and memory bin-packing ratio)

Use boto3 with IRSA (no static keys). Format output as a Markdown table
suitable for posting to Slack via a webhook.
```

---

## References

- **FinOps Foundation** — `finops.org` — framework, personas, maturity model, FinOps certified practitioner
- **Karpenter documentation** — `karpenter.sh` — NodePool, EC2NodeClass, disruption policies, migration from Cluster Autoscaler
- **KEDA documentation** — `keda.sh` — scalers catalogue (Kafka, SQS, Prometheus, cron, 60+ others), TriggerAuthentication
- **OpenCost documentation** — `opencost.io` — CNCF cost allocation engine; Prometheus metrics reference
- **Kubecost documentation** — `kubecost.com` — enterprise cost allocation, savings insights, request right-sizing
- **Goldilocks** — `github.com/FairwindsOps/goldilocks` — VPA recommendation dashboard
- **Vertical Pod Autoscaler** — `github.com/kubernetes/autoscaler/tree/master/vertical-pod-autoscaler`
- **AWS Compute Savings Plans** — AWS documentation; flexible commitment model across EC2, Fargate, Lambda
- **AWS Cost Optimisation Hub** — `docs.aws.amazon.com/cost-management/latest/userguide/cos-hub.html`
- **AWS Spot Instance Advisor** — `aws.amazon.com/ec2/spot/instance-advisor` — interruption frequency by instance type
- **Kubernetes resource management** — `kubernetes.io/docs/concepts/configuration/manage-resources-containers`
- **DORA metrics** — `dora.dev` — deployment frequency correlates with cost efficiency (fewer big deployments = less wasted compute)
