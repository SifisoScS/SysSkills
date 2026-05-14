---
name: "Platform Engineering & Internal Developer Platform"
slug: platform-engineering-idp
category: "07-infrastructure-and-operations"
proficiency: Architect
description: "Design, build, and operate Internal Developer Platforms (IDPs) that enable developer self-service, enforce standards, and reduce cognitive load at organisational scale. Covers golden paths, Backstage developer portals, policy-as-code, environment management, service catalogues, and platform team topology."
tags: [platform-engineering, idp, backstage, golden-path, developer-experience, self-service, crossplane, argocd, policy-as-code, team-topologies, dora, space-framework, service-catalog, scaffolding]
status: published
---

# Platform Engineering & Internal Developer Platform (IDP)

## Principles

**Platform as a Product**
The platform team's customers are developers. An IDP that nobody uses is an expensive failure, regardless of its technical sophistication. Treat the platform like a product: understand developer needs through user research, measure adoption and satisfaction, iterate based on feedback, and maintain a product roadmap. The platform succeeds when developer productivity improves — not when the platform team ships features.

**Self-Service Over Tickets**
Every manual request — "please provision a database", "please add me to this environment", "please create a new service repo" — is a handoff that introduces delay and cognitive overhead. The platform converts these requests into self-service capabilities: a developer fills in a form or runs a command; the infrastructure is provisioned without human intervention. The platform team's goal is to eliminate the ticket queue, not manage it.

**Paved Roads with Clear Escape Hatches**
A golden path is a well-lit, well-tested, well-maintained path for the common case. It should be so easy to follow that choosing it is the default, not a restriction. But complex systems always produce edge cases the golden path does not cover. Provide escape hatches — documented ways to deviate with explicit trade-off awareness — so the platform does not become a constraint on legitimate innovation.

**Opinionated but Not Dictatorial**
The platform has opinions: this is the approved way to create a service, instrument it, deploy it, and monitor it. Opinions reduce cognitive load and prevent every team from reinventing the same wheel with different parts. But opinions must be open to challenge through a defined process (ADR, RFC) when a team's context genuinely requires a different approach.

**Measure Platform Success by Developer Outcomes**
The platform exists to improve developer productivity, satisfaction, and delivery quality. Measure it: DORA metrics (deployment frequency, lead time, MTTR, change failure rate) and SPACE framework metrics (satisfaction, performance, activity, communication, efficiency). Platform adoption rate and developer Net Promoter Score are leading indicators of value.

**The Platform Team Is an Enabling Team**
Team Topologies defines the platform team as an enabling team — one that reduces cognitive load on stream-aligned teams by handling infrastructure, tooling, and cross-cutting concerns. It is not a gatekeeper, not a service desk, and not a centre of excellence that reviews everyone's pull requests. Its job is to make other teams faster.

---

## Implementation Patterns

### Pattern 1 — The IDP Capability Model

A mature IDP provides capabilities across five areas:

**1. Developer Portal (Backstage)**
Service catalogue, onboarding documentation, API specs, runbooks, architecture diagrams, team ownership, and platform status. The single place a developer goes to understand what exists and how to use it.

**2. Self-Service Scaffolding (Golden Path Templates)**
A developer fills in a form (service name, language, team, bounded context) and receives: a pre-configured Git repository, CI/CD pipeline, OTel instrumentation, Dockerfile, Kubernetes manifests, linting config, and a Storybook setup (for frontend). First deployment in under 30 minutes from decision to running service.

**3. Environment Management**
On-demand preview environments for every pull request. Automated staging promotion. Production access restricted to GitOps. Developers never manually apply to production clusters.

**4. Policy and Compliance Automation**
Security scanning, SBOM generation, image signing, and policy-as-code admission control are built into every golden path. Compliance is not a gate before production — it is a property of every build.

**5. Observability and Cost Visibility**
Every service provisioned via the platform arrives pre-instrumented with OpenTelemetry. Each team has a Grafana dashboard with golden signals and SLO burn rate. Cloud cost per service is visible in the developer portal — teams own their spend.

### Pattern 2 — Backstage Developer Portal Architecture

```
Backstage (React frontend + Node.js backend)
  ├── Software Catalog
  │   ├── catalog-info.yaml per service (owned by service teams, in their repos)
  │   └── Ingests from GitHub/GitLab via discovery
  ├── Scaffolder (golden path templates)
  │   └── Template → creates repo, CI, manifests, registers in catalog
  ├── TechDocs (auto-generated docs from Markdown in repos)
  ├── Plugins
  │   ├── ArgoCD plugin (deployment status)
  │   ├── Grafana plugin (service golden signals)
  │   ├── PagerDuty plugin (on-call ownership)
  │   ├── GitHub Actions plugin (CI status)
  │   └── Cost Insights plugin (cloud spend per service)
  └── Scorecard plugin (quality gates per service)
```

Every service team owns their `catalog-info.yaml`. Backstage discovers it automatically. The catalog is always up to date because the source of truth is the teams' own repositories.

### Pattern 3 — Golden Path Template Design

A golden path template encodes all platform opinions in a reusable scaffold. It should be opinionated on: CI/CD pipeline, OTel instrumentation, linting config, Docker build, Kubernetes base manifests, health check endpoints, and structured logging.

```yaml
# backstage/templates/go-service/template.yaml
apiVersion: scaffolder.backstage.io/v1beta3
kind: Template
metadata:
  name: go-microservice
  title: Go Microservice (Golden Path)
spec:
  parameters:
    - title: Service details
      required: [name, owner, boundedContext]
      properties:
        name:
          type: string
          pattern: "^[a-z][a-z0-9-]{2,30}$"
          description: "Service name (kebab-case)"
        owner:
          type: string
          ui:field: OwnerPicker
        boundedContext:
          type: string
          enum: [ordering, payments, inventory, customers, notifications]
        description:
          type: string

  steps:
    - id: fetch
      action: fetch:template
      input:
        url: ./skeleton
        values:
          name: ${{ parameters.name }}
          owner: ${{ parameters.owner }}

    - id: publish
      action: publish:github
      input:
        repoUrl: github.com?repo=${{ parameters.name }}&owner=org
        defaultBranch: main

    - id: register
      action: catalog:register
      input:
        repoContentsUrl: ${{ steps.publish.output.repoContentsUrl }}
        catalogInfoPath: /catalog-info.yaml

    - id: create-argocd-app
      action: argocd:create-resources
      input:
        appName: ${{ parameters.name }}
        argoInstance: main-cluster
        namespace: ${{ parameters.boundedContext }}
        repoUrl: ${{ steps.publish.output.remoteUrl }}
        path: deploy/overlays/staging
```

### Pattern 4 — Service Scorecard (Quality Gate Visibility)

A scorecard gives every service a quality score across platform dimensions. Teams see their own score and the organisation sees the health of the whole platform.

```yaml
# platform/scorecards/service-scorecard.yaml
checks:
  - id: has-slo
    description: "Service has a defined SLO"
    weight: 20
    query: "catalog.entity.metadata.annotations['slo/target'] != null"

  - id: has-runbook
    description: "Service has a runbook linked in catalog"
    weight: 15
    query: "catalog.entity.metadata.links[?title=='Runbook'] != null"

  - id: has-owner
    description: "Service has a team owner"
    weight: 20
    query: "catalog.entity.spec.owner != null"

  - id: no-critical-cves
    description: "No critical CVEs in last scan"
    weight: 25
    dataSource: security-scan-api

  - id: deployment-frequency
    description: "At least 1 deploy per sprint"
    weight: 20
    dataSource: argocd-metrics
```

Services scoring below 60 appear on a platform health dashboard. The platform team uses this to prioritise enablement work — helping low-scoring teams improve — not to enforce compliance top-down.

### Pattern 5 — Crossplane for Self-Service Infrastructure

Crossplane extends Kubernetes with custom resources for cloud infrastructure. A developer creates a `PostgreSQLInstance` manifest in their GitOps repo; Crossplane provisions the actual RDS/CloudSQL instance and injects credentials via External Secrets.

```yaml
# apps/ordering/infrastructure/database.yaml
apiVersion: platform.example.com/v1alpha1
kind: PostgreSQLInstance
metadata:
  name: ordering-db
  namespace: ordering
spec:
  parameters:
    storageGB: 20
    version: "16"
    tier: standard           # platform-defined tiers: dev / standard / high-availability
  writeConnectionSecretToRef:
    name: ordering-db-credentials   # injected into namespace for app to consume
```

The developer never interacts with the cloud console or the infrastructure team. The platform defines the allowed tiers and enforces them via Crossplane compositions. The developer picks a tier; the platform handles the rest.

### Pattern 6 — Platform Metrics and Developer Experience (SPACE)

Track both delivery performance (DORA) and developer experience (SPACE):

| DORA Metric | Target | Source |
|---|---|---|
| Deployment Frequency | Daily or on-demand | ArgoCD sync events |
| Lead Time | < 1 hour | Commit timestamp → ArgoCD sync |
| Change Failure Rate | < 5% | Rollback / incident rate |
| MTTR | < 1 hour | Incident duration |

| SPACE Dimension | Measure | Source |
|---|---|---|
| **S**atisfaction | Developer NPS (quarterly survey) | Survey tool |
| **P**erformance | PR cycle time, review turnaround | GitHub metrics |
| **A**ctivity | Deploys per team per sprint | ArgoCD |
| **C**ommunication | Platform office hours attendance, documentation views | Backstage analytics |
| **E**fficiency | Time from idea to first deploy (new service) | Scaffolding funnel |

---

## Anti-Patterns

| Anti-Pattern | Why It's Harmful | Fix |
|---|---|---|
| Ivory tower platform (nobody uses it) | The platform team builds what it thinks developers need without talking to developers; adoption is low; teams work around it | Treat the platform as a product; run user research; measure adoption; iterate on developer feedback |
| Ticket-based platform team | The platform team is a bottleneck; developers wait days for database provisioning or environment setup; delivery velocity collapses | Self-service everything; the platform team's job is to build self-service capabilities, not fulfill requests |
| Too much standardisation, no escape hatches | Developers cannot do their work within the golden path constraints; they work around the platform or leave; the platform becomes irrelevant | Define escape hatches with explicit trade-off documentation; make deviation a process, not a prohibition |
| Platform team as infrastructure police | The platform team reviews every team's architecture; this scales to zero; teams become resentful; the platform is a blocker | The platform team is an enabling team; it offers help, not oversight; compliance is automated, not manually reviewed |
| No platform metrics | The platform team cannot justify investment or demonstrate value to leadership; the platform is cut when budgets tighten | Measure DORA improvement correlated with platform adoption; track developer NPS; show cost reduction from self-service |
| Building Backstage before the basics work | Backstage is complex to operate; if CI/CD and GitOps are not stable, Backstage adds noise, not signal | Nail the golden path first; add a portal when you have enough services to make a catalogue valuable |

---

## Code Templates

### Backstage — catalog-info.yaml (Service Descriptor)

```yaml
# catalog-info.yaml (lives in every service repo, owned by the service team)
apiVersion: backstage.io/v1alpha1
kind: Component
metadata:
  name: ordering-service
  description: "Manages order lifecycle for the Ordering bounded context"
  annotations:
    github.com/project-slug: org/ordering-service
    backstage.io/techdocs-ref: dir:.
    argocd/app-name: ordering-service
    grafana/dashboard-selector: "service=ordering-service"
    slo/target: "99.5"
    slo/window: "30d"
  links:
    - url: https://grafana.internal/d/ordering
      title: Dashboard
      icon: dashboard
    - url: https://wiki.internal/runbooks/ordering-service
      title: Runbook
      icon: help
  tags: [go, postgresql, kafka, ordering]
spec:
  type: service
  lifecycle: production
  owner: team-ordering
  system: platform
  dependsOn:
    - resource:default/ordering-db
    - component:default/payments-service
  providesApis:
    - ordering-api-v1
```

### Crossplane — Platform Composition (PostgreSQL Tier Abstraction)

```yaml
# platform/compositions/postgresql.yaml
apiVersion: apiextensions.crossplane.io/v1
kind: Composition
metadata:
  name: postgresql-standard
spec:
  compositeTypeRef:
    apiVersion: platform.example.com/v1alpha1
    kind: PostgreSQLInstance
  resources:
    - name: rds-instance
      base:
        apiVersion: rds.aws.upbound.io/v1beta1
        kind: Instance
        spec:
          forProvider:
            region: eu-west-1
            dbInstanceClass: db.t3.medium     # standard tier
            engine: postgres
            engineVersion: "16"
            skipFinalSnapshot: false
            multiAz: false                    # standard = single-AZ
          providerConfigRef:
            name: aws-provider
      patches:
        - fromFieldPath: spec.parameters.storageGB
          toFieldPath: spec.forProvider.allocatedStorage
        - fromFieldPath: metadata.name
          toFieldPath: spec.forProvider.dbName
```

### Python — Platform CLI Scaffolding (Cookiecutter alternative)

```python
#!/usr/bin/env python3
# platform/cli/new_service.py
"""Platform CLI — create a new service from the golden path template."""
import subprocess, sys, re
from pathlib import Path

def slugify(name: str) -> str:
    return re.sub(r'[^a-z0-9-]', '', name.lower().replace(' ', '-'))

def new_service(name: str, owner: str, language: str = "go") -> None:
    slug = slugify(name)
    template = f"gh:org/platform-templates//services/{language}"

    print(f"Creating service: {slug} (owner: {owner})")
    subprocess.run([
        "cookiecutter", template,
        "--no-input",
        f"service_name={slug}",
        f"team_owner={owner}",
        f"description=New {language} service for the {owner} team",
    ], check=True)

    # Auto-register in Backstage catalog
    subprocess.run([
        "gh", "repo", "create", f"org/{slug}",
        "--public", "--source", slug, "--push",
    ], check=True)

    print(f"""
✓ Service created: {slug}
✓ Repository: github.com/org/{slug}
✓ Pipeline: .github/workflows/ci-cd.yml
✓ GitOps: ArgoCD app will auto-sync from apps/{slug}/
✓ Catalog: catalog-info.yaml registered in Backstage

Next: clone the repo and start building.
    """)

if __name__ == "__main__":
    new_service(name=sys.argv[1], owner=sys.argv[2])
```

### PowerShell — Platform Health Dashboard (DORA from ArgoCD + GitHub)

```powershell
# platform/metrics/Get-PlatformHealth.ps1
param(
    [string]$ArgoCDServer = $env:ARGOCD_SERVER,
    [string]$ArgoCDToken  = $env:ARGOCD_TOKEN,
    [string]$GitHubOrg    = $env:GITHUB_ORG,
    [string]$GitHubToken  = $env:GITHUB_TOKEN,
    [int]   $DaysBack     = 30
)

$since = (Get-Date).AddDays(-$DaysBack).ToString("yyyy-MM-ddTHH:mm:ssZ")

# 1. Deployment frequency from ArgoCD sync history
$headers = @{ Authorization = "Bearer $ArgoCDToken" }
$apps = Invoke-RestMethod "$ArgoCDServer/api/v1/applications" -Headers $headers
$deployCount = ($apps.items | ForEach-Object {
    Invoke-RestMethod "$ArgoCDServer/api/v1/applications/$($_.metadata.name)/resource-tree" -Headers $headers
}).Count

# 2. Lead time from GitHub Actions — commit to successful deploy workflow
$ghHeaders = @{ Authorization = "Bearer $GitHubToken" }
$repos = Invoke-RestMethod "https://api.github.com/orgs/$GitHubOrg/repos?per_page=100" -Headers $ghHeaders

$scores = [PSCustomObject]@{
    TotalDeployments = $deployCount
    Period           = "$DaysBack days"
    DeployFrequency  = "$([math]::Round($deployCount / $DaysBack, 1)) / day"
}

Write-Host "=== Platform Health Report ===" -ForegroundColor Cyan
$scores | Format-List
Write-Host "(Connect to Grafana for full DORA + SPACE dashboard)" -ForegroundColor Gray
```

---

## Decision Matrix

| Org Size / Maturity | Recommended Approach | Key Tooling | Priority |
|---|---|---|---|
| < 20 engineers | Lightweight golden path: GitHub Actions templates + shared Kustomize base | GitHub Actions, ArgoCD | Get CI/CD and GitOps right first |
| 20–100 engineers | Backstage portal + Crossplane self-service + scorecard | Backstage, Crossplane, ArgoCD | Self-service and catalogue |
| 100+ engineers | Full IDP: portal + scaffolding + policy + cost visibility + DORA dashboard | Full stack above + OPA/Kyverno, Cost Insights | Governance and developer experience |
| Regulated (finance, health) | IDP with mandatory policy gates, audit trail, and SBOM in catalogue | Kyverno + Sigstore + Pact Broker + audit logging | Compliance automation |
| Legacy modernisation programme | Platform-supported Strangler Fig: migration templates, dual-pipeline golden path, before/after C4 in catalogue | Backstage + custom migration templates | Migration visibility and enablement |

---

## Proficiency Levels

### Awareness
- Can explain the difference between traditional DevOps (everyone owns their own pipeline) and Platform Engineering (centralised paved roads).
- Understands what a golden path is and what a developer portal provides.
- Knows the four DORA metrics and can explain the SPACE framework.

### Applied
- Creates a Backstage `catalog-info.yaml` for a service and contributes it to the platform catalogue.
- Uses a golden path template to scaffold a new service end-to-end.
- Builds a basic GitHub Actions reusable workflow that encodes platform CI/CD opinions.
- Instruments a service with the platform's OTel configuration and verifies it appears in Grafana.

### Master
- Designs and builds a golden path template: scaffolding, CI/CD, OTel pre-instrumentation, base Kubernetes manifests, and Backstage registration.
- Configures Backstage plugins: ArgoCD deployment status, Grafana golden signals, GitHub Actions CI status.
- Implements Crossplane compositions for self-service database and queue provisioning.
- Designs and publishes a service scorecard; runs a platform health review with team leads.

### Architect
- Defines platform strategy: capability roadmap, team topology (stream-aligned vs platform), adoption metrics, and funding justification.
- Evaluates build vs buy for each platform capability; knows when Backstage is the right choice and when a simpler internal portal suffices.
- Aligns the platform with the organisation's compliance programme: which gates are mandatory, which are advisory, how audit evidence is produced automatically.
- Designs the platform for a Strangler Fig migration programme: golden path templates for new services, dual-pipeline support for migrating services, and catalogue visibility of migration progress.

---

## AI Prompts

**Design an IDP for a team:**
> Design an Internal Developer Platform for this organisation: [describe team size, tech stack, current pain points, cloud provider, regulated/unregulated]. Specify: the five capability areas to prioritise, the tooling stack, the golden path for a new service, and the metrics to track success. Identify the first thing to build.

**Review a platform design:**
> Review this IDP design for anti-patterns. Check: Is there a self-service path for the most common requests? Does the platform team act as an enabling team or a gatekeeper? Are golden paths opinionated enough to reduce cognitive load? Is there a feedback mechanism from developers? [paste design]

**Write a Backstage template:**
> Write a Backstage scaffolder template for a new [Go/TypeScript/C#] service. The template should: prompt for service name, team owner, and bounded context; create a GitHub repository from a skeleton; register the service in the Backstage catalogue; create an ArgoCD application for staging; and output the repository URL.

**Design a scorecard:**
> Design a platform scorecard for our services. We want to measure: SLO definition, runbook existence, owner assignment, critical CVE absence, and deployment frequency. For each check, specify the data source, the weight, and the threshold for pass/warn/fail. Output as a Backstage scorecard YAML.

**Measure platform ROI:**
> I need to justify investment in a platform engineering team to leadership. Design a measurement framework that: connects platform adoption to DORA metric improvement, quantifies time saved by self-service (vs ticket-based), and tracks developer satisfaction over time. Identify the data sources and reporting cadence.

---

## References

**Books**
- Matthew Skelton & Manuel Pais — *Team Topologies* (IT Revolution, 2019) — defines the platform team role, enabling team model, and cognitive load reduction
- Nicole Forsgren et al. — *Accelerate* (IT Revolution, 2018) — DORA metrics and research-backed platform value

**Frameworks**
- [SPACE Framework](https://queue.acm.org/detail.cfm?id=3454124) — developer productivity dimensions (ACM Queue, 2021)
- [CNCF Platforms White Paper](https://tag-app-delivery.cncf.io/whitepapers/platforms/) — platform engineering definition and capability model

**Tooling**
- [Backstage](https://backstage.io/) — open-source developer portal by Spotify; service catalogue, scaffolding, TechDocs
- [Crossplane](https://www.crossplane.io/) — Kubernetes-native infrastructure self-service and composition
- [Port](https://www.getport.io/) — managed developer portal alternative to self-hosted Backstage

**Related Skills**
- `07-infrastructure-and-operations/cicd-gitops-strategy` — the platform's golden path encodes CI/CD and GitOps standards; ArgoCD is a core platform capability
- `08-quality-testing-observability/observability-telemetry-strategy` — every service provisioned via the golden path arrives pre-instrumented; the platform owns the OTel Collector topology
- `09-re-engineering-and-evolution/strangler-fig-legacy-modernization` — the platform provides migration templates and dual-pipeline support for Strangler Fig programmes
- `06-security-and-compliance/threat-modeling-stride` — the CI/CD pipeline is a supply chain attack surface; policy-as-code in the platform is the automated mitigation
