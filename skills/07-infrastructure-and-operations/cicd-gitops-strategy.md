---
name: "CI/CD & GitOps Strategy"
slug: cicd-gitops-strategy
category: "07-infrastructure-and-operations"
proficiency: Architect
description: "Design and implement modern CI/CD pipelines using GitOps principles for reliable, auditable, and secure deployments. Covers trunk-based development, progressive delivery (canary, blue-green), supply chain security, DORA metrics, and self-service developer platforms."
tags: [cicd, gitops, github-actions, argocd, flux, progressive-delivery, trunk-based-development, iac, terraform, dora-metrics, shift-left, supply-chain-security, argo-rollouts, feature-flags]
status: published
---

# CI/CD & GitOps Strategy

## Principles

**Everything as Code**
Pipelines, infrastructure, deployment configuration, environment promotion rules, and security policies must all live in version control. Manual steps that are not codified are invisible, unrepeatable, and impossible to audit. If it is not in Git, it did not happen.

**Trunk-Based Development**
Long-lived feature branches are the primary cause of integration pain. Merge to trunk (main) daily. Use feature flags to decouple deployment from release. Dark launch features behind flags; activate them independently of deployment. This is the single highest-leverage change a team can make to improve delivery frequency.

**Shift Left on Quality and Security**
Every quality and security check that runs only in a late pipeline stage is feedback that arrives too late to be cheap to fix. Run linting, unit tests, SAST, and dependency scanning on every commit. Make security a property of the build, not a gate before production.

**Progressive Delivery Over Big-Bang Releases**
Deploy to a small percentage of users or traffic before full rollout. Canary deployments, blue-green switches, and traffic splitting with automated analysis let you catch regressions with limited blast radius. A deployment that can be rolled back in 60 seconds is not the same risk as one that cannot.

**Observability of the Delivery Process**
The pipeline is a system. Treat it like one: track deployment frequency, lead time from commit to production, change failure rate, and mean time to restore (DORA metrics). A team that does not measure its delivery pipeline cannot improve it.

**GitOps: Git Is the Source of Truth for Desired State**
The desired state of every environment lives in Git. A GitOps engine (ArgoCD, Flux) continuously reconciles the actual cluster state toward the desired state. No human manually applies manifests. Every change is a pull request, reviewed, and traced to a commit. Drift from the desired state is detected and corrected automatically.

**Security Is Part of the Pipeline, Not After It**
Software Bill of Materials (SBOM), container image signing, dependency vulnerability scanning, and policy-as-code admission control are pipeline responsibilities. A container that reaches production must be signed, scanned, and policy-compliant — enforced automatically, not by manual review.

---

## Implementation Patterns

### Pattern 1 — The Four DORA Metrics (Elite Performance Targets)

| Metric | Elite | High | Medium | Low |
|---|---|---|---|---|
| **Deployment Frequency** | On-demand (multiple/day) | Weekly | Monthly | < Monthly |
| **Lead Time (commit → prod)** | < 1 hour | 1 day–1 week | 1 week–1 month | > 1 month |
| **Change Failure Rate** | < 5% | 5–10% | 10–15% | > 15% |
| **Mean Time to Restore** | < 1 hour | < 1 day | 1 day–1 week | > 1 week |

These are the North Star metrics for delivery performance. Measure them. Display them on a dashboard. Make improving them an explicit engineering objective.

### Pattern 2 — CI Pipeline Structure (GitHub Actions)

Every commit to any branch runs the CI pipeline. The pipeline is the contract between the developer and the codebase:

```
Commit
  ├── [Fast — < 2 min]  Lint + Format check + Unit tests
  ├── [Medium — < 5 min] Build + SAST (Semgrep/CodeQL) + Dependency scan (Trivy/OWASP)
  ├── [Slow — < 15 min]  Integration tests + Contract tests
  └── [On merge to main] Build container image + Sign (Cosign) + Push to registry + Generate SBOM
```

Fail fast: the fastest checks run first. A linting failure should abort the pipeline before the 15-minute integration test suite runs. Every stage runs in parallel within its tier where possible.

### Pattern 3 — GitOps Repository Structure

**Option A — App of Apps (single cluster, smaller teams)**

```
gitops-repo/
├── apps/
│   ├── ordering-service/
│   │   ├── base/
│   │   │   ├── deployment.yaml
│   │   │   ├── service.yaml
│   │   │   └── kustomization.yaml
│   │   └── overlays/
│   │       ├── staging/   { kustomization.yaml (patches: image tag, replicas) }
│   │       └── production/{ kustomization.yaml }
│   └── payments-service/
└── infrastructure/
    ├── cert-manager/
    ├── ingress-nginx/
    └── external-secrets/
```

**Option B — Multi-repo (large orgs, independent team deployments)**

- `platform-repo`: shared infrastructure, cluster config, platform tooling (owned by platform team)
- `service-a-repo`: application code + Helm chart / Kustomize overlay (owned by service team)
- ArgoCD `ApplicationSet` generates an ArgoCD `Application` per service repo automatically

### Pattern 4 — Progressive Delivery with Argo Rollouts

```yaml
# rollout.yaml — canary with automated analysis
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: ordering-service
spec:
  replicas: 10
  strategy:
    canary:
      steps:
        - setWeight: 10        # 10% canary traffic
        - pause: { duration: 5m }
        - analysis:
            templates: [{ templateName: success-rate }]
        - setWeight: 50
        - pause: { duration: 5m }
        - analysis:
            templates: [{ templateName: success-rate }]
        - setWeight: 100

---
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: success-rate
spec:
  metrics:
    - name: success-rate
      successCondition: result[0] >= 0.99   # abort if error rate > 1%
      failureLimit: 1
      provider:
        prometheus:
          address: http://prometheus:9090
          query: |
            sum(rate(http_requests_total{app="ordering-service",status!~"5.."}[5m]))
            /
            sum(rate(http_requests_total{app="ordering-service"}[5m]))
```

ArgoCD Rollouts automatically promotes or aborts based on real-time SLO analysis. No human needs to watch the canary — the pipeline watches it.

### Pattern 5 — Supply Chain Security (SLSA Level 2+)

```
Source Control → Build → Sign → Attest → Verify → Deploy
```

**Signing** (Cosign + Sigstore):
```bash
# In CI — sign the built image with the GitHub OIDC token (keyless)
cosign sign --yes ghcr.io/org/ordering-service:${SHA}
```

**SBOM generation** (Syft):
```bash
syft ghcr.io/org/ordering-service:${SHA} -o spdx-json > sbom.json
cosign attest --yes --predicate sbom.json --type spdxjson \
    ghcr.io/org/ordering-service:${SHA}
```

**Admission verification** (Policy controller / Kyverno):
```yaml
# kyverno-policy: require signed and scanned images
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-image-signature
spec:
  validationFailureAction: Enforce
  rules:
    - name: verify-image-signature
      match:
        resources: { kinds: [Pod] }
      verifyImages:
        - imageReferences: ["ghcr.io/org/*"]
          attestors:
            - entries:
                - keyless:
                    subject: "https://github.com/org/*/.github/workflows/*.yml@refs/heads/main"
                    issuer: "https://token.actions.githubusercontent.com"
```

### Pattern 6 — Secret Management (External Secrets Operator)

Never store secrets in Git, even encrypted. Store a reference:

```yaml
# ExternalSecret — references a secret in Azure Key Vault / AWS Secrets Manager / Vault
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: ordering-db-credentials
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: azure-keyvault
    kind: ClusterSecretStore
  target:
    name: ordering-db-secret          # Kubernetes Secret created by ESO
  data:
    - secretKey: connectionString
      remoteRef:
        key: ordering-db-connection-string   # Key Vault secret name
```

The GitOps repo contains only the `ExternalSecret` manifest (safe to commit). The operator fetches the actual secret value at runtime from the vault. Rotation in the vault is reflected automatically at next refresh.

---

## Anti-Patterns

| Anti-Pattern | Why It's Harmful | Fix |
|---|---|---|
| Manual deployment steps | Unrepeatable, unauditable, source of production incidents; "it works on my machine" at the deployment level | Every deployment step is automated; a human can only trigger, not perform |
| Long-lived feature branches | Integration conflicts accumulate; merges become painful; deployment frequency collapses | Trunk-based development + feature flags; branch lifetime < 1 day |
| Secrets in Git (even encrypted with SOPS) | SOPS keys must be managed, rotated, and secured; secrets in Git are a permanent audit trail risk | External Secrets Operator; secrets live in a vault, references live in Git |
| No automated rollback | A failed deployment requires manual intervention; MTTR measured in hours | Argo Rollouts automated analysis triggers rollback; ArgoCD sync health checks abort on failure |
| Monolithic pipeline (one long sequential script) | A 45-minute pipeline discourages frequent commits; feedback arrives too late | Stage-based: fast checks first; parallel execution within stages; fail fast |
| Treating the pipeline as infrastructure (static, unmaintained) | Pipeline rot: steps added, never removed; unused jobs; security tools outdated | Pipeline code is reviewed with the same rigour as application code; DORA metrics surfaced in sprint reviews |
| No SBOM or image signing | Cannot prove what is in a running container; supply chain attacks go undetected | Sign every image in CI; generate and attest SBOM; verify signature on admission |
| `kubectl apply` run manually | Drift from desired state; no audit trail; impossible to reproduce state from Git | GitOps engine (ArgoCD/Flux) is the only thing that applies to clusters |

---

## Code Templates

### GitHub Actions — Full CI/CD Pipeline

```yaml
# .github/workflows/ci-cd.yml
name: CI/CD

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

env:
  IMAGE: ghcr.io/${{ github.repository }}/ordering-service

jobs:
  lint-test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with: { go-version: '1.22' }
      - run: make lint
      - run: make test-unit

  security-scan:
    runs-on: ubuntu-latest
    needs: lint-test
    steps:
      - uses: actions/checkout@v4
      - name: SAST (Semgrep)
        uses: semgrep/semgrep-action@v1
        with: { config: "p/golang p/owasp-top-ten" }
      - name: Dependency scan (Trivy)
        uses: aquasecurity/trivy-action@master
        with:
          scan-type: fs
          severity: HIGH,CRITICAL
          exit-code: '1'

  integration-test:
    runs-on: ubuntu-latest
    needs: lint-test
    services:
      postgres:
        image: postgres:16
        env: { POSTGRES_PASSWORD: test }
        options: --health-cmd pg_isready
    steps:
      - uses: actions/checkout@v4
      - run: make test-integration

  build-push-sign:
    if: github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    needs: [security-scan, integration-test]
    permissions:
      contents: read
      packages: write
      id-token: write    # for keyless Cosign signing
    steps:
      - uses: actions/checkout@v4

      - name: Build and push container image
        uses: docker/build-push-action@v5
        with:
          push: true
          tags: ${{ env.IMAGE }}:${{ github.sha }},${{ env.IMAGE }}:latest

      - name: Install Cosign
        uses: sigstore/cosign-installer@v3

      - name: Sign image (keyless)
        run: cosign sign --yes ${{ env.IMAGE }}:${{ github.sha }}

      - name: Generate SBOM
        uses: anchore/sbom-action@v0
        with:
          image: ${{ env.IMAGE }}:${{ github.sha }}
          format: spdx-json
          output-file: sbom.spdx.json

      - name: Attest SBOM
        run: |
          cosign attest --yes \
            --predicate sbom.spdx.json \
            --type spdxjson \
            ${{ env.IMAGE }}:${{ github.sha }}

      - name: Update GitOps repo (image tag)
        uses: actions/github-script@v7
        with:
          github-token: ${{ secrets.GITOPS_PAT }}
          script: |
            // Bump image tag in GitOps repo kustomization
            const { execSync } = require('child_process');
            execSync(`
              git clone https://x-access-token:${process.env.GITHUB_TOKEN}@github.com/org/gitops-repo
              cd gitops-repo
              kustomize edit set image ordering-service=${{ env.IMAGE }}:${{ github.sha }}
              git commit -am "ci: bump ordering-service to ${{ github.sha }}"
              git push
            `);
```

### ArgoCD Application — Staging

```yaml
# gitops-repo/argocd/ordering-service-staging.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ordering-service-staging
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/org/gitops-repo
    targetRevision: HEAD
    path: apps/ordering-service/overlays/staging
  destination:
    server: https://kubernetes.default.svc
    namespace: ordering-staging
  syncPolicy:
    automated:
      prune: true        # remove resources no longer in Git
      selfHeal: true     # correct drift automatically
    syncOptions:
      - CreateNamespace=true
    retry:
      limit: 3
      backoff: { duration: 10s, factor: 2 }
```

### Kustomize Overlay — Production (image tag patch)

```yaml
# apps/ordering-service/overlays/production/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../../base

images:
  - name: ordering-service
    newName: ghcr.io/org/ordering-service
    newTag: "abc123def456"    # bumped by CI pipeline

patches:
  - target: { kind: Deployment, name: ordering-service }
    patch: |
      - op: replace
        path: /spec/replicas
        value: 5
  - target: { kind: Deployment, name: ordering-service }
    patch: |
      - op: add
        path: /spec/template/spec/containers/0/resources
        value:
          requests: { cpu: "200m", memory: "256Mi" }
          limits:   { cpu: "500m", memory: "512Mi" }
```

### PowerShell — DORA Metrics from GitHub API

```powershell
# tools/metrics/Get-DoraMetrics.ps1
param(
    [string]$Owner,
    [string]$Repo,
    [string]$Token = $env:GITHUB_TOKEN,
    [int]$DaysBack = 30
)

$headers = @{ Authorization = "Bearer $Token"; Accept = "application/vnd.github+json" }
$since   = (Get-Date).AddDays(-$DaysBack).ToString("yyyy-MM-ddTHH:mm:ssZ")

# Deployment frequency — count successful workflow runs to production
$runs = Invoke-RestMethod `
    "https://api.github.com/repos/$Owner/$Repo/actions/workflows/ci-cd.yml/runs?status=success&created=>$since&per_page=100" `
    -Headers $headers

$deployments   = $runs.workflow_runs | Where-Object { $_.head_branch -eq "main" }
$daysWithDeploy = ($deployments | ForEach-Object { (Get-Date $_.created_at).Date } | Select-Object -Unique).Count
$deployFreq    = [math]::Round($daysWithDeploy / $DaysBack * 100, 1)

Write-Host "=== DORA Metrics ($DaysBack days) ===" -ForegroundColor Cyan
Write-Host "Deployments:          $($deployments.Count)"
Write-Host "Days with deployment: $daysWithDeploy / $DaysBack ($deployFreq%)"
Write-Host "Avg lead time:        [measure from first commit to deploy run — requires commit timestamps]"
```

---

## Decision Matrix

| Scenario | CI Tool | GitOps Engine | Progressive Delivery | Notes |
|---|---|---|---|---|
| Small team / startup | GitHub Actions | ArgoCD | Feature flags only | Simple and powerful; low ops burden |
| Mid-size, Kubernetes-native | GitHub Actions | ArgoCD + Argo Rollouts | Canary with SLO analysis | Add rollouts when deployment risk is real |
| Enterprise / regulated | GitHub Actions or GitLab CI | ArgoCD + Kyverno | Blue-green + policy gates | SBOM, signing, and policy-as-code mandatory |
| Multi-cloud / hybrid infra | GitHub Actions | Flux + Crossplane | Canary per cluster | Flux is lighter weight; Crossplane manages cloud resources via GitOps |
| Legacy monolith Strangler Fig | GitHub Actions | Dual pipelines (legacy + new) | Feature flags for traffic split | Both pipelines visible; migration dashboard in observability stack |
| Air-gapped / on-prem | GitLab CI (self-hosted) | Flux or ArgoCD (self-hosted) | Canary | No public internet dependencies; use internal registries |

---

## Proficiency Levels

### Awareness
- Can explain CI vs CD vs GitOps and the difference between continuous delivery and continuous deployment.
- Knows the four DORA metrics and what elite performance looks like.
- Understands what trunk-based development means and why long-lived feature branches are harmful.

### Applied
- Builds a CI/CD pipeline with GitHub Actions: lint, unit tests, SAST scan, build, and push to a container registry.
- Configures an ArgoCD Application that auto-syncs from a GitOps repository.
- Implements a Kustomize overlay for staging and production environments.
- Configures External Secrets Operator to sync secrets from Azure Key Vault or AWS Secrets Manager.

### Master
- Designs progressive delivery with Argo Rollouts: canary steps with Prometheus-based automated analysis and rollback.
- Implements supply chain security: image signing (Cosign), SBOM generation, and Kyverno policy enforcement on admission.
- Designs a GitOps repository structure for multi-service, multi-environment deployment.
- Measures and tracks DORA metrics; identifies and removes deployment bottlenecks.

### Architect
- Defines organisation-wide CI/CD platform: tooling standards, pipeline templates (golden path), security controls (SLSA level), and developer self-service onboarding.
- Designs the environment promotion strategy: staging → production gates, approval workflows, and automated regression guards.
- Integrates CI/CD governance with the security programme: SBOM policy, CVE SLA (critical vulnerabilities must be patched within N hours), and pipeline as a compliance control.
- Coaches teams on DORA metrics improvement; removes organisational impediments to deployment frequency.

---

## AI Prompts

**Design a CI/CD pipeline:**
> Design a GitHub Actions CI/CD pipeline for this service: [describe language, test types, container-based deployment]. Include: fast/medium/slow stage separation, SAST and dependency scanning, container build and signing, SBOM generation, and a GitOps image tag update step. Output the full YAML.

**Review a pipeline for security gaps:**
> Review this CI/CD pipeline configuration for supply chain security gaps. Check: Are secrets stored in Git? Is the container image signed? Is there a dependency vulnerability scan? Are pipeline permissions scoped to least privilege? Is there an automated rollback mechanism? [paste pipeline YAML]

**Design a GitOps structure:**
> Design a GitOps repository structure for this system: [describe services, environments (dev/staging/prod), team ownership]. Choose between mono-repo and multi-repo, specify the Kustomize overlay structure, and describe how ArgoCD ApplicationSets generate Applications per service.

**Design a progressive delivery strategy:**
> Design a canary deployment strategy for [service name] using Argo Rollouts. The service has a Prometheus golden signals setup. Define: the canary step percentages, pause durations, the AnalysisTemplate PromQL query, the abort condition, and what happens on automatic rollback.

**Improve DORA metrics:**
> Our team's current DORA metrics are: deployment frequency = biweekly, lead time = 1 week, change failure rate = 15%, MTTR = 2 days. Identify the top 3 changes we should make to reach high-performance levels. Prioritise by impact-to-effort ratio.

---

## References

**Books**
- Nicole Forsgren, Jez Humble, Gene Kim — *Accelerate: Building and Scaling High Performing Technology Organizations* (IT Revolution, 2018) — the source for DORA metrics and research-backed delivery practices
- Jez Humble & David Farley — *Continuous Delivery* (Addison-Wesley, 2010) — foundational principles; deployment pipeline patterns

**Standards & Frameworks**
- [OpenGitOps Principles](https://opengitops.dev/) — GitOps principles v1.0
- [SLSA Framework](https://slsa.dev/) — supply chain security levels
- [DORA Research](https://dora.dev/) — annual State of DevOps report

**Tooling**
- [ArgoCD](https://argo-cd.readthedocs.io/) — GitOps continuous delivery for Kubernetes
- [Argo Rollouts](https://argoproj.github.io/rollouts/) — progressive delivery with canary and blue-green
- [Cosign / Sigstore](https://docs.sigstore.dev/) — keyless container image signing
- [External Secrets Operator](https://external-secrets.io/) — sync secrets from vaults into Kubernetes
- [Kyverno](https://kyverno.io/) — Kubernetes-native policy engine

**Related Skills**
- `09-re-engineering-and-evolution/strangler-fig-legacy-modernization` — dual CI/CD pipelines run in parallel during Strangler Fig migrations; feature flags control traffic split
- `08-quality-testing-observability/observability-telemetry-strategy` — DORA metrics are an observability concern; pipeline telemetry and canary SLO analysis use the same Prometheus stack
- `06-security-and-compliance/threat-modeling-stride` — the CI/CD pipeline is an attack surface; STRIDE the supply chain (dependency injection, build server compromise, registry poisoning)
- `02-architecture-and-design/architecture-decision-records` — document GitOps tooling choices, progressive delivery strategy, and environment promotion policy as ADRs
