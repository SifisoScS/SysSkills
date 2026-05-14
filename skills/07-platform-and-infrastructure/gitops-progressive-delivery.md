---
name: GitOps & Progressive Delivery
slug: gitops-progressive-delivery
category: 07-platform-and-infrastructure
proficiency: advanced
description: >
  Design and operate GitOps delivery pipelines using ArgoCD and Flux, with
  progressive delivery strategies (canary, blue-green, A/B) via Argo Rollouts
  and Flagger. Covers reconciliation loops, drift detection, multi-tenancy,
  ImageAutomation, sync waves, AnalysisTemplates backed by Prometheus, and
  safe automated rollback.
tags:
  - gitops
  - argocd
  - flux
  - progressive-delivery
  - argo-rollouts
  - flagger
  - canary
  - blue-green
  - kubernetes
  - continuous-delivery
  - drift-detection
status: complete
---

## Principles

### GitOps Core Tenets (OpenGitOps v1.0)
1. **Declarative** — desired state expressed as declarative config (Kubernetes manifests, Helm values, Kustomize overlays); no imperative scripts
2. **Versioned and immutable** — Git is the single source of truth; every state change is a commit with author, timestamp, and diff
3. **Pulled automatically** — a software agent (ArgoCD, Flux) continuously pulls desired state and applies it; no push-based `kubectl apply` from CI
4. **Continuously reconciled** — the agent detects drift between live state and desired state and self-heals; alerts when it cannot

### Pull-Based CD vs. Push-Based CD
```
Push (anti-GitOps):                Pull (GitOps):
CI pipeline runs kubectl apply     CI pipeline updates Git only
     ↓                                      ↓
Cluster state depends on CI       Reconciler detects diff → applies
     ↓                                      ↓
Rollback = re-run pipeline        Rollback = git revert (instant)
No drift detection                Drift auto-healed or alerted
```

### Reconciliation Loop
```
┌─────────────────────────────────────────────────┐
│  Git repo (desired state)                       │
│  ├── apps/payments/staging/kustomization.yaml   │
│  └── apps/payments/prod/kustomization.yaml      │
└─────────────────────┬───────────────────────────┘
                      │ poll / webhook
              ┌───────▼────────┐
              │  Reconciler    │  (ArgoCD Application Controller
              │                │   or Flux Kustomization Controller)
              └───────┬────────┘
                      │ compare
         ┌────────────▼────────────────┐
         │  Live cluster state         │
         │  (Deployment, Service, …)   │
         └─────────────────────────────┘
              ↑ drift? → apply patch
              ↑ healthy? → no-op, re-poll in interval
```

### Progressive Delivery
Progressive delivery extends GitOps by controlling **traffic weight** during rollout, using real-time metrics to gate promotion, and triggering automated rollback if SLOs degrade. Strategies:

| Strategy | Traffic Split | Rollback | Best For |
|---|---|---|---|
| **Canary** | Gradual % shift (5→25→50→100) | Instant weight reset | Most cases; low blast radius |
| **Blue-Green** | Instant full cutover after preview | Re-route to old stack | Stateful apps; DB migrations |
| **A/B** | Header/cookie-based routing | Per-variant weight | Feature experimentation |
| **Shadow** | Mirror traffic, compare responses | N/A (no user impact) | Risky algorithmic changes |

### Git Repository Structure Patterns
```
gitops-config/
├── clusters/
│   ├── staging/          # Flux bootstrap / ArgoCD project config
│   └── prod/
├── apps/
│   ├── payments/
│   │   ├── base/         # Kustomize base (Deployment, Service, HPA)
│   │   ├── staging/      # overlay: replica count, resource limits, image tag
│   │   └── prod/         # overlay: PodDisruptionBudget, affinity rules
│   └── _templates/       # shared Kustomize components
├── infrastructure/
│   ├── cert-manager/
│   ├── ingress-nginx/
│   └── monitoring/
└── platform/
    └── namespaces/       # Namespace-as-a-Service bundles
```

---

## Implementation Patterns

### 1. ArgoCD — ApplicationSet
`ApplicationSet` is the cluster-aware template engine. One `ApplicationSet` can manage hundreds of `Application` objects from a single YAML using generators (Git directory, cluster list, pull request, matrix).

### 2. ArgoCD — Sync Waves and Resource Hooks
Sync waves control ordering within a single sync operation. Hooks (`PreSync`, `Sync`, `PostSync`, `SyncFail`) run Jobs at lifecycle boundaries (e.g., DB migrations before deployment, smoke tests after).

### 3. Flux — Kustomization + HelmRelease
Flux splits responsibilities into small controllers. `Kustomization` reconciles raw/Kustomize manifests; `HelmRelease` manages Helm chart lifecycle; `ImageRepository` + `ImagePolicy` + `ImageUpdateAutomation` handle automated image tag bumps via Git commit.

### 4. Argo Rollouts — Canary with AnalysisTemplate
`Rollout` replaces `Deployment`. The canary strategy defines steps (pause, setWeight, analysis); `AnalysisTemplate` runs Prometheus queries or webhook calls between steps. Failure triggers automatic rollback to the stable ReplicaSet without human intervention.

### 5. Flagger — Metric-Gated Canary with Istio
Flagger watches a `Deployment` and manages `Canary` CRs. It creates primary/canary Deployments, an Istio `VirtualService` for traffic shifting, and periodically queries metrics. If error rate or P99 latency breach thresholds, it rolls back automatically and fires a webhook alert.

### 6. Multi-Tenancy
ArgoCD: `AppProject` per team, scoped source repos, destination namespaces, and resource allow-lists. Flux: separate `Kustomization` objects per tenant with `serviceAccountName` impersonation so each tenant's reconciler only has RBAC for its own namespace.

---

## Anti-Patterns

| Anti-Pattern | Why It Fails | Correction |
|---|---|---|
| **Secrets committed to Git** | Secret sprawl; git history is permanent | External Secrets Operator + Vault; never commit raw Secrets |
| **`kubectl apply` in CI pipeline** | Push-based; no drift detection; credentials in CI | Move to Git commit only in CI; reconciler does the apply |
| **Monorepo with all envs in one branch** | Promotion becomes a merge conflict; no rollback isolation | Separate overlay directories per env in one branch, or separate env branches |
| **Disabling auto-sync for "safety"** | Defeats drift detection; manual syncs create toil | Use `syncOptions: [CreateNamespace=true]` + prune carefully; keep auto-sync on |
| **100% canary in one step** | Not progressive; identical to a normal rollout | Minimum 3–5 steps with analysis between each |
| **Analysis template without baseline** | False positives from traffic ramp-up noise | Compare canary vs stable with `baseline` analysis; use `successCondition` with tolerance |
| **No rollback notification** | Silent rollbacks; team unaware of regressions | Rollout status webhook → Slack/PagerDuty on `Degraded` |
| **Image tag `latest` in GitOps** | Non-deterministic; breaks reproducibility | Always commit immutable digest or semver tag; ban `latest` via Kyverno |
| **One ArgoCD Application per microservice (unmanaged)** | 200 apps = 200 manual YAMLs | Use `ApplicationSet` with Git directory generator |
| **Sync waves misused as deployment ordering** | Cross-app ordering via waves in one Application is fragile | Use App-of-Apps with explicit dependency; waves for within-app ordering only |

---

## Code Templates

### Template 1 — ArgoCD ApplicationSet (Git Directory Generator)

```yaml
# gitops-config/argocd/applicationset-services.yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: services
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: [missingkey=error]

  generators:
    - matrix:
        generators:
          # Generator 1: discover app directories
          - git:
              repoURL: https://github.com/org/gitops-config.git
              revision: HEAD
              directories:
                - path: apps/*/prod          # matches apps/payments/prod, apps/fraud/prod …
              requeueAfterSeconds: 60

          # Generator 2: registered prod clusters
          - clusters:
              selector:
                matchLabels:
                  environment: production

  template:
    metadata:
      # Extract service name from path: apps/payments/prod → payments
      name: "{{index (splitList \"/\" .path.path) 1}}-{{.name}}"
      namespace: argocd
      annotations:
        notifications.argoproj.io/subscribe.on-sync-failed.slack: platform-alerts
        notifications.argoproj.io/subscribe.on-health-degraded.slack: platform-alerts
    spec:
      project: "{{index (splitList \"/\" .path.path) 1}}"    # AppProject per service

      source:
        repoURL: https://github.com/org/gitops-config.git
        targetRevision: HEAD
        path: "{{.path.path}}"

      destination:
        server: "{{.server}}"
        namespace: "{{index (splitList \"/\" .path.path) 1}}"

      syncPolicy:
        automated:
          prune: true
          selfHeal: true
          allowEmpty: false
        syncOptions:
          - CreateNamespace=false       # platform pre-creates namespaces
          - PrunePropagationPolicy=foreground
          - PruneLast=true
          - RespectIgnoreDifferences=true
        retry:
          limit: 3
          backoff:
            duration: 10s
            factor: 2
            maxDuration: 3m

      ignoreDifferences:
        - group: apps
          kind: Deployment
          jsonPointers:
            - /spec/replicas            # HPA manages replicas; ignore ArgoCD drift

      revisionHistoryLimit: 5
```

```yaml
# gitops-config/argocd/project-payments.yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: payments
  namespace: argocd
spec:
  description: Payments team services
  sourceRepos:
    - https://github.com/org/gitops-config.git
    - https://github.com/org/payments-service.git
  destinations:
    - namespace: payments
      server: https://kubernetes.default.svc
    - namespace: payments
      server: https://prod-cluster.internal
  clusterResourceWhitelist: []          # no cluster-scoped resources
  namespaceResourceBlacklist:
    - group: ""
      kind: ResourceQuota               # platform team owns quotas
    - group: ""
      kind: LimitRange
  roles:
    - name: payments-developer
      description: Read-only + manual sync
      policies:
        - p, proj:payments:payments-developer, applications, get, payments/*, allow
        - p, proj:payments:payments-developer, applications, sync, payments/*, allow
      groups:
        - payments-team
  syncWindows:
    - kind: allow
      schedule: "0 8 * * 1-5"          # Mon–Fri 08:00 UTC
      duration: 10h
      applications: ["*"]
    - kind: deny
      schedule: "0 18 * * 5"           # Friday 18:00 freeze
      duration: 62h
      applications: ["*-prod"]
```

---

### Template 2 — ArgoCD Sync Waves + Resource Hooks (DB Migration Pattern)

```yaml
# apps/payments/prod/migration-job.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: payments-db-migrate
  annotations:
    argocd.argoproj.io/hook: PreSync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
    argocd.argoproj.io/sync-wave: "-1"    # runs before wave 0 (Deployment)
spec:
  backoffLimit: 0                          # fail fast; block sync on error
  template:
    spec:
      restartPolicy: Never
      serviceAccountName: payments-migrator
      containers:
        - name: migrate
          image: ghcr.io/org/payments-service:$IMAGE_TAG
          command: ["/app/migrate", "up"]
          env:
            - name: DATABASE_URL
              valueFrom:
                secretKeyRef:
                  name: payments-db-conn   # synced by ESO
                  key: connectionString
          resources:
            requests: { cpu: 100m, memory: 128Mi }
            limits:   { memory: 256Mi }
```

```yaml
# apps/payments/prod/deployment.yaml (wave 0 — default)
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payments-service
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  # ... standard Deployment spec

---
# apps/payments/prod/smoke-test-job.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: payments-smoke-test
  annotations:
    argocd.argoproj.io/hook: PostSync
    argocd.argoproj.io/hook-delete-policy: HookSucceeded
    argocd.argoproj.io/sync-wave: "1"
spec:
  backoffLimit: 2
  template:
    spec:
      restartPolicy: OnFailure
      containers:
        - name: smoke
          image: ghcr.io/org/platform-tools:latest
          command:
            - /bin/sh
            - -c
            - |
              set -e
              # Basic health check
              curl -sf http://payments-service.payments.svc.cluster.local/healthz
              # Critical payment path
              curl -sf -X POST http://payments-service.payments.svc.cluster.local/api/v2/payments/validate \
                -H "Content-Type: application/json" \
                -d '{"amount": 1, "currency": "ZAR", "dryRun": true}'
              echo "Smoke tests passed"
```

---

### Template 3 — Flux Kustomization + HelmRelease + ImageUpdateAutomation

```yaml
# clusters/prod/flux-system/gotk-sync.yaml
# Generated by: flux bootstrap github --owner=org --repository=gitops-config ...
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: gitops-config
  namespace: flux-system
spec:
  interval: 1m
  url: https://github.com/org/gitops-config
  secretRef:
    name: flux-github-token
  ref:
    branch: main
  ignore: |
    # Ignore CI artefacts
    /.github/
    /docs/
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: infrastructure
  namespace: flux-system
spec:
  interval: 10m
  retryInterval: 1m
  timeout: 5m
  sourceRef:
    kind: GitRepository
    name: gitops-config
  path: ./infrastructure/prod
  prune: true
  wait: true                    # block dependants until all resources are Ready
  healthChecks:
    - apiVersion: apps/v1
      kind: Deployment
      name: ingress-nginx-controller
      namespace: ingress-nginx
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: apps
  namespace: flux-system
spec:
  interval: 5m
  retryInterval: 30s
  sourceRef:
    kind: GitRepository
    name: gitops-config
  path: ./apps/prod
  prune: true
  dependsOn:
    - name: infrastructure      # apps reconcile only after infra is healthy
  decryption:
    provider: sops
    secretRef:
      name: sops-age            # SOPS age key for encrypted secrets in Git
  postBuild:
    substituteFrom:
      - kind: ConfigMap
        name: cluster-vars      # inject cluster-specific values at reconcile time
```

```yaml
# apps/payments/prod/helmrelease.yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: payments-service
  namespace: payments
spec:
  interval: 5m
  chart:
    spec:
      chart: payments-service
      version: ">=1.0.0 <2.0.0"
      sourceRef:
        kind: HelmRepository
        name: org-charts
        namespace: flux-system
      interval: 1m

  install:
    createNamespace: false
    remediation:
      retries: 3
  upgrade:
    cleanupOnFail: true
    remediation:
      retries: 3
      remediateLastFailure: true
      strategy: rollback
  rollback:
    timeout: 5m
    cleanupOnFail: true
  test:
    enable: true                # run `helm test` after install/upgrade
    ignoreFailures: false

  values:
    image:
      repository: ghcr.io/org/payments-service
      tag: "1.3.2"             # updated by ImageUpdateAutomation
    replicaCount: 3
    resources:
      requests: { cpu: 200m, memory: 256Mi }
      limits:   { memory: 512Mi }

  valuesFrom:
    - kind: Secret
      name: payments-helm-values   # injected by ESO; overrides above values
      valuesKey: values.yaml
      optional: true
```

```yaml
# apps/payments/prod/image-update.yaml
# Flux ImageAutomation — auto-commit new semver image tags to Git
apiVersion: image.toolkit.fluxcd.io/v1beta2
kind: ImageRepository
metadata:
  name: payments-service
  namespace: flux-system
spec:
  image: ghcr.io/org/payments-service
  interval: 1m
  secretRef:
    name: ghcr-pull-secret
---
apiVersion: image.toolkit.fluxcd.io/v1beta2
kind: ImagePolicy
metadata:
  name: payments-service
  namespace: flux-system
spec:
  imageRepositoryRef:
    name: payments-service
  policy:
    semver:
      range: ">=1.0.0 <2.0.0"   # only auto-promote patch/minor in 1.x
---
apiVersion: image.toolkit.fluxcd.io/v1beta1
kind: ImageUpdateAutomation
metadata:
  name: flux-image-updates
  namespace: flux-system
spec:
  interval: 5m
  sourceRef:
    kind: GitRepository
    name: gitops-config
  git:
    checkout:
      ref:
        branch: main
    commit:
      author:
        name: Flux Bot
        email: flux@company.io
      messageTemplate: |
        chore(image): update {{range .Updated.Images}}{{.ReflectionResult.Tag}} {{end}}

        Updated images:
        {{range .Updated.Images -}}
        - {{.ImageName}}: {{.NewTag}}
        {{end -}}
    push:
      branch: main
  update:
    strategy: Setters            # updates YAML files using # {"$imagepolicy": "flux-system:payments-service"} markers
```

---

### Template 4 — Argo Rollouts Canary with Prometheus AnalysisTemplate

```yaml
# apps/payments/prod/rollout.yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: payments-service
  namespace: payments
spec:
  replicas: 10
  selector:
    matchLabels:
      app: payments-service
  template:
    metadata:
      labels:
        app: payments-service
    spec:
      containers:
        - name: payments
          image: ghcr.io/org/payments-service:1.3.2   # {"$imagepolicy": "flux-system:payments-service"}
          ports:
            - containerPort: 8080
          resources:
            requests: { cpu: 200m, memory: 256Mi }
            limits:   { memory: 512Mi }

  strategy:
    canary:
      # Traffic management via Istio
      trafficRouting:
        istio:
          virtualService:
            name: payments-vsvc
            routes: [primary]
          destinationRule:
            name: payments-destrule
            canarySubsetName: canary
            stableSubsetName: stable

      steps:
        - setWeight: 5
        - pause: { duration: 2m }
        - analysis:
            templates:
              - templateName: payments-success-rate
              - templateName: payments-latency-p99
            args:
              - name: service-name
                value: payments-service
              - name: namespace
                value: payments

        - setWeight: 25
        - pause: { duration: 5m }
        - analysis:
            templates:
              - templateName: payments-success-rate
              - templateName: payments-latency-p99
            args:
              - name: service-name
                value: payments-service
              - name: namespace
                value: payments

        - setWeight: 50
        - pause: { duration: 5m }
        - setWeight: 100

      canaryMetadata:
        labels:
          role: canary
      stableMetadata:
        labels:
          role: stable

      antiAffinity:
        preferredDuringSchedulingIgnoredDuringExecution:
          weight: 1

      maxSurge: "25%"
      maxUnavailable: 0

      abortScaleDownDelaySeconds: 30
```

```yaml
# apps/payments/prod/analysis-templates.yaml
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: payments-success-rate
  namespace: payments
spec:
  args:
    - name: service-name
    - name: namespace
  metrics:
    - name: success-rate
      interval: 60s
      count: 5                   # 5 measurements over 5 minutes
      successCondition: result[0] >= 0.995    # 99.5% success rate
      failureLimit: 1
      provider:
        prometheus:
          address: http://prometheus.monitoring.svc.cluster.local:9090
          query: |
            sum(rate(
              http_requests_total{
                namespace="{{args.namespace}}",
                service="{{args.service-name}}",
                role="canary",
                status!~"5.."
              }[5m]
            ))
            /
            sum(rate(
              http_requests_total{
                namespace="{{args.namespace}}",
                service="{{args.service-name}}",
                role="canary"
              }[5m]
            ))
---
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: payments-latency-p99
  namespace: payments
spec:
  args:
    - name: service-name
    - name: namespace
  metrics:
    - name: p99-latency
      interval: 60s
      count: 5
      successCondition: result[0] <= 0.5      # p99 under 500ms
      failureLimit: 1
      provider:
        prometheus:
          address: http://prometheus.monitoring.svc.cluster.local:9090
          query: |
            histogram_quantile(0.99,
              sum by (le) (
                rate(
                  http_request_duration_seconds_bucket{
                    namespace="{{args.namespace}}",
                    service="{{args.service-name}}",
                    role="canary"
                  }[5m]
                )
              )
            )
```

```yaml
# apps/payments/prod/istio-routing.yaml
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: payments-vsvc
  namespace: payments
spec:
  hosts: [payments-service]
  http:
    - name: primary
      route:
        - destination:
            host: payments-service
            subset: stable
          weight: 100
        - destination:
            host: payments-service
            subset: canary
          weight: 0              # Argo Rollouts updates these weights
---
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: payments-destrule
  namespace: payments
spec:
  host: payments-service
  subsets:
    - name: stable
      labels:
        role: stable
    - name: canary
      labels:
        role: canary
```

---

### Template 5 — Argo Rollouts Blue-Green Strategy

```yaml
# apps/checkout/prod/rollout-bluegreen.yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: checkout-service
  namespace: checkout
spec:
  replicas: 6
  selector:
    matchLabels:
      app: checkout-service
  template:
    metadata:
      labels:
        app: checkout-service
    spec:
      containers:
        - name: checkout
          image: ghcr.io/org/checkout-service:2.1.0
          ports:
            - containerPort: 8080

  strategy:
    blueGreen:
      # Service that routes live traffic (switches on promotion)
      activeService: checkout-active
      # Service that routes preview traffic (for pre-promotion tests)
      previewService: checkout-preview

      autoPromotionEnabled: false        # require manual or analysis promotion
      autoPromotionSeconds: 0

      prePromotionAnalysis:
        templates:
          - templateName: checkout-integration-test
        args:
          - name: service-endpoint
            value: http://checkout-preview.checkout.svc.cluster.local

      postPromotionAnalysis:
        templates:
          - templateName: payments-success-rate
        args:
          - name: service-name
            value: checkout-service
          - name: namespace
            value: checkout

      scaleDownDelaySeconds: 300         # keep old (blue) stack for 5 min after promotion
      previewReplicaCount: 3             # spin up 3 green replicas for preview
      abortScaleDownDelaySeconds: 30
---
apiVersion: v1
kind: Service
metadata:
  name: checkout-active
  namespace: checkout
spec:
  selector:
    app: checkout-service               # Rollout controller adds rollouts-pod-template-hash
  ports:
    - port: 80
      targetPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: checkout-preview
  namespace: checkout
spec:
  selector:
    app: checkout-service
  ports:
    - port: 80
      targetPort: 8080
---
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: checkout-integration-test
  namespace: checkout
spec:
  args:
    - name: service-endpoint
  metrics:
    - name: integration-test
      provider:
        job:
          spec:
            backoffLimit: 0
            template:
              spec:
                restartPolicy: Never
                containers:
                  - name: test
                    image: ghcr.io/org/platform-tools:latest
                    command:
                      - /bin/sh
                      - -c
                      - |
                        set -e
                        # Run integration test suite against preview stack
                        curl -sf {{args.service-endpoint}}/healthz
                        # Add your integration test binary here
                        echo "Integration tests passed"
```

---

### Template 6 — Flagger Canary with Istio + Slack Notifications

```yaml
# apps/fraud/prod/flagger-canary.yaml
apiVersion: flagger.app/v1beta1
kind: Canary
metadata:
  name: fraud-service
  namespace: fraud
spec:
  # Flagger watches this Deployment and creates fraud-service-primary + fraud-service-canary
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: fraud-service

  progressDeadlineSeconds: 600    # fail if not promoted within 10 min
  revertOnDeletion: true

  service:
    port: 80
    targetPort: 8080
    gateways:
      - istio-system/public-gateway
    hosts:
      - fraud.internal
    trafficPolicy:
      tls:
        mode: ISTIO_MUTUAL
    retries:
      attempts: 3
      perTryTimeout: 2s
      retryOn: gateway-error,connect-failure,retriable-4xx

  # Traffic analysis configuration
  analysis:
    interval: 1m                  # evaluate metrics every minute
    threshold: 5                  # allow 5 failed checks before rollback
    maxWeight: 50                 # never send more than 50% to canary
    stepWeight: 10                # increase by 10% each interval
    stepWeightPromotion: 100      # jump to 100% on promotion

    metrics:
      - name: request-success-rate
        # built-in Flagger metric using Prometheus
        thresholdRange:
          min: 99
        interval: 1m

      - name: request-duration
        thresholdRange:
          max: 500                # p99 < 500ms
        interval: 1m

      - name: fraud-detection-accuracy
        # custom metric: our business-critical SLO
        templateRef:
          name: fraud-accuracy
          namespace: fraud
        thresholdRange:
          min: 0.95               # 95% accuracy maintained
        interval: 2m

    webhooks:
      - name: load-test
        type: rollout
        url: http://flagger-loadtester.flagger-system/
        timeout: 5s
        metadata:
          cmd: "hey -z 1m -q 10 -c 2 http://fraud-service-canary.fraud/"

      - name: acceptance-test
        type: pre-rollout
        url: http://flagger-loadtester.flagger-system/
        timeout: 30s
        metadata:
          type: bash
          cmd: |
            curl -sf http://fraud-service-canary.fraud/healthz &&
            curl -sf -X POST http://fraud-service-canary.fraud/api/v1/score \
              -H 'Content-Type: application/json' \
              -d '{"transaction_id":"smoke-test","amount":1.00}'

      - name: notify-slack
        type: confirm-promotion
        url: http://flagger-loadtester.flagger-system/gate/approve
        metadata:
          slack_channel: fraud-deployments

    alerts:
      - name: "fraud-service canary"
        severity: warn
        providerRef:
          name: slack-platform
          namespace: flagger-system
---
apiVersion: flagger.app/v1beta1
kind: MetricTemplate
metadata:
  name: fraud-accuracy
  namespace: fraud
spec:
  provider:
    type: prometheus
    address: http://prometheus.monitoring.svc.cluster.local:9090
  query: |
    sum(rate(fraud_detection_correct_total{namespace="fraud",pod=~"fraud-service-canary-.*"}[2m]))
    /
    sum(rate(fraud_detection_total{namespace="fraud",pod=~"fraud-service-canary-.*"}[2m]))
```

```yaml
# flagger-system/notification-providers.yaml
apiVersion: notification.toolkit.fluxcd.io/v1beta3
kind: Provider
metadata:
  name: slack-platform
  namespace: flagger-system
spec:
  type: slack
  channel: platform-alerts
  secretRef:
    name: slack-webhook          # ESO-synced from Vault
---
apiVersion: flagger.app/v1beta1
kind: AlertProvider
metadata:
  name: slack-platform
  namespace: flagger-system
spec:
  type: slack
  channel: platform-alerts
  webhookURL:
    secretRef:
      name: slack-webhook
      key: url
```

---

## Decision Matrix

| Scenario | Recommendation | Rationale |
|---|---|---|
| Greenfield Kubernetes platform, small team | Flux | Lower operational overhead; no additional UI to maintain |
| Platform with many teams needing UI, RBAC, SSO | ArgoCD | Mature UI, `AppProject` isolation, OIDC SSO out of the box |
| Need automated image tag promotion to Git | Flux ImageUpdateAutomation | Built-in; ArgoCD requires external tooling (Argo CD Image Updater) |
| Multi-cluster fleet (10+ clusters) | ArgoCD with `ApplicationSet` cluster generator | Single control plane manages N clusters from one pane |
| Stateful app with DB migrations | Blue-green + PreSync hook Job | Instant cutover after migrations; old stack available for fast rollback |
| Stateless HTTP service, risk-averse org | Canary + Prometheus AnalysisTemplate | Gradual traffic shift with automated metric gates |
| Need A/B testing with user segmentation | Argo Rollouts + header-based routing | Fine-grained traffic split by header/cookie values |
| App team wants zero GitOps knowledge | Flagger watching existing Deployment | Teams keep standard Deployments; Flagger wraps automatically |
| Secrets in Git required (air-gapped) | Flux + SOPS with age encryption | SOPS encrypts secrets in Git; Flux decrypts at reconcile time |
| Need to freeze deploys on Fridays | ArgoCD `syncWindows` (deny Fri 18:00 → Mon 08:00) | Declarative deploy windows without CI changes |
| Enforce image signing before deploy | Kyverno `ClusterPolicy` + `verifyImages` | Admission-time gate; rejects unsigned images before Rollout starts |

---

## Proficiency Levels

### Level 1 — Aware
- Understands GitOps pull model vs push-based CD
- Can read an ArgoCD `Application` YAML and understand what it deploys and where
- Knows the difference between canary and blue-green at a conceptual level
- Can monitor a Rollout's progress in the Argo Rollouts dashboard or via `kubectl argo rollouts status`

### Level 2 — Practitioner
- Writes ArgoCD `Application` YAMLs and Kustomize overlays for staging/prod environments
- Configures Flux `Kustomization` + `HelmRelease` with `dependsOn` ordering
- Converts an existing `Deployment` to an Argo `Rollout` with a basic canary strategy
- Writes a simple `AnalysisTemplate` querying Prometheus success rate
- Configures `ImageUpdateAutomation` for patch-version auto-promotion

### Level 3 — Advanced
- Designs multi-team GitOps repo structures with `ApplicationSet` and `AppProject` isolation
- Authors complex `AnalysisTemplates` (custom business metrics, webhook-backed analysis Jobs)
- Configures Flagger with custom `MetricTemplate` and pre/post-rollout webhook gates
- Implements blue-green with `prePromotionAnalysis` + `postPromotionAnalysis`
- Manages Flux multi-tenancy with per-tenant `Kustomization` service account impersonation
- Tunes sync windows, retry policies, and health checks for production reliability

### Level 4 — Expert
- Operates ArgoCD at scale: ApplicationSet matrix generators, sharding for 1000+ apps, HA ArgoCD with multiple application controllers
- Designs progressive delivery for stateful services: Rollout-aware Helm hooks, PVC migration, DB schema compatibility gates
- Implements full GitOps audit trail: every cluster state change is a Git commit with author; compliance exports from Git log
- Contributes Flagger custom metric providers or Argo Rollouts plugins
- Runs chaos experiments on the reconciler itself (network partition between controller and API server) to validate recovery behaviour

---

## AI Prompts

**Design an ApplicationSet for multi-env multi-cluster**
```
Design an ArgoCD ApplicationSet that:
- Uses a matrix generator combining a Git directory generator (discovers apps/*/prod)
  and a cluster list generator (label: environment=production)
- Names each Application as {service}-{cluster-name}
- Scopes each Application to an AppProject named after the service
- Enables auto-sync with prune and selfHeal
- Ignores /spec/replicas drift (HPA-managed)
- Adds Slack notification annotations for sync-failed and health-degraded events
Output: ApplicationSet YAML + example AppProject YAML
```

**Write an Argo Rollouts canary with Prometheus gates**
```
Write an Argo Rollouts Canary Rollout for service [name] that:
- Uses Istio VirtualService/DestinationRule for traffic splitting
- Steps: 5% → analysis → 25% → analysis → 50% → analysis → 100%
- Each analysis step checks: HTTP success rate >= 99.5% and p99 latency <= [Xms]
  over 5 one-minute intervals using Prometheus
- On analysis failure: automatic rollback, scale down canary within 30s
- Notify Slack channel [channel] on rollback
Output: Rollout YAML, AnalysisTemplate(s) YAML, VirtualService YAML, DestinationRule YAML
```

**Convert Deployment to Flagger Canary**
```
I have a standard Kubernetes Deployment named [name] in namespace [ns].
Convert it to a Flagger-managed Canary that:
- Uses Istio traffic splitting with max 50% to canary, step 10% per 1m interval
- Checks built-in success-rate (>= 99%) and request-duration (p99 <= 300ms)
- Runs a load test webhook via flagger-loadtester during rollout
- Sends Slack alerts on rollback and promotion
- Includes a custom MetricTemplate querying [Prometheus metric expression]
Output: Canary YAML, MetricTemplate YAML, AlertProvider YAML
```

**Audit GitOps repo for security gaps**
```
Audit this GitOps repository structure and ArgoCD configuration for security gaps:
[paste directory listing and sample Application/AppProject YAMLs]
Check for: plaintext secrets, missing AppProject source/destination restrictions,
overly broad RBAC, unsigned images, missing sync windows for prod, absence of
admission policies (Kyverno/OPA) enforcing image signing, and ApplicationSets
that could be abused to deploy to unauthorized namespaces.
Provide a prioritised finding list with remediation YAMLs.
```

**Design a rollback runbook**
```
Write a runbook for rolling back a failed progressive delivery deployment in this setup:
- Reconciler: [ArgoCD / Flux]
- Delivery tool: [Argo Rollouts / Flagger]
- Git repo: [org/gitops-config]
- Service: [name], namespace: [ns]
Cover: detecting the failure signal, aborting the rollout, reverting the Git commit,
forcing a reconciler sync, verifying rollback, and post-incident Git hygiene.
Include the exact kubectl / argocd / flux CLI commands.
```

---

## References

- **OpenGitOps principles** — `opengitops.dev` — vendor-neutral GitOps spec
- **ArgoCD documentation** — `argo-cd.readthedocs.io` — ApplicationSet, AppProject, sync waves, notifications
- **Flux documentation** — `fluxcd.io` — Kustomization, HelmRelease, ImageAutomation, multi-tenancy, SOPS
- **Argo Rollouts documentation** — `argoproj.github.io/argo-rollouts` — canary, blue-green, AnalysisTemplate, traffic routing plugins
- **Flagger documentation** — `docs.flagger.app` — Canary CRD, MetricTemplate, webhook gates, Istio/nginx/Linkerd integrations
- **Progressive Delivery** — blog series by Weaveworks (original term coined by James Governor)
- **DORA metrics** — `dora.dev` — deployment frequency, lead time for changes (primary GitOps improvement signals)
- **Kustomize** — `kustomize.io` — bases, overlays, components, replacements
- **SOPS** — `github.com/getsops/sops` — encrypted secrets in Git (age, PGP, AWS KMS, Vault Transit)
- **External Secrets Operator** — `external-secrets.io` — complements GitOps; keeps secrets out of Git entirely
- **Kyverno** — `kyverno.io` — admission-time image verification policy, enforcing GitOps invariants
- **Argo CD Image Updater** — `argocd-image-updater.readthedocs.io` — image automation for ArgoCD (Flux alternative)
