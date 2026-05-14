---
name: Platform Engineering & Internal Developer Platform
slug: platform-engineering-idp
category: 07-platform-and-infrastructure
proficiency: advanced
description: >
  Design and operate an Internal Developer Platform (IDP) that reduces
  cognitive load for product teams through golden paths, self-service
  infrastructure, software catalogues, and GitOps-driven provisioning.
  Covers Backstage, Crossplane, reusable CI/CD workflows, Helm library
  charts, and platform SLO practices aligned with Team Topologies.
tags:
  - platform-engineering
  - idp
  - backstage
  - crossplane
  - gitops
  - golden-path
  - self-service
  - team-topologies
  - devex
  - helm
  - kubernetes
status: complete
---

## Principles

### What a Platform Is (and Isn't)
A platform is a **self-service product** consumed by internal stream-aligned teams. It is not a gatekeeper, a ticket queue, or a shared-services team that teams must wait on. The platform reduces cognitive load by providing paved roads — opinionated, pre-integrated paths that work out of the box — while leaving escape hatches for teams with legitimate divergent needs.

**Team Topologies framing:**
- **Platform team** → enables stream-aligned teams via X-as-a-Service
- **Stream-aligned teams** → consume platform abstractions to ship features
- **Enabling teams** → temporary coaching/uplift for specific capability gaps
- **Complicated-subsystem teams** → deep specialists (ML, security) exposing services

### Golden Path vs. Paved Road
| Term | Meaning |
|------|---------|
| **Golden path** | The one recommended way to do X (scaffold, deploy, observe) |
| **Paved road** | Multiple valid paths, but some have better tooling/guardrails |
| **Escape hatch** | Supported way to deviate when golden path doesn't fit |

Golden paths reduce the decision surface for teams. Every opinionated default the platform bakes in is one fewer decision each team must make and get right independently.

### Platform as a Product
- Platform team maintains an **internal SLO**: availability, time-to-provision, MTTR for broken paths
- Treat internal developers as customers; run user research, measure DORA metrics per team
- Version platform APIs; deprecate with notice; never break callers silently
- Document golden paths in a **software catalogue** (Backstage, Port, Cortex)

### GitOps Layering
```
Developer commits app code
       ↓
CI golden-path workflow (lint, test, build, sign, push image)
       ↓
CD reconciler (ArgoCD / Flux) diffs desired vs actual cluster state
       ↓
Crossplane / ESO syncs infrastructure & secrets
       ↓
Platform SLO dashboards confirm health
```

### Self-Service Primitives
1. **Software templates** (scaffolding) — new repo with CI, CODEOWNERS, SLOs wired
2. **Environment provisioning** — Crossplane composite resources abstract cloud APIs
3. **Secrets injection** — External Secrets Operator pulls from Vault; teams never touch Vault directly
4. **Observability onboarding** — OTel collector, Prometheus scrape target, Grafana dashboard auto-provisioned
5. **Access management** — RBAC-as-code; teams own their namespace; platform owns cluster-level policies

---

## Implementation Patterns

### 1. Software Catalogue — Backstage
Backstage is the de-facto IDP portal. Core concepts:
- **catalog-info.yaml** — every repo declares its entity (Component, API, Resource, System, Domain)
- **Software templates** — scaffolding wizards that create repos, register entities, and wire CI
- **TechDocs** — docs-as-code rendered from `docs/` inside each repo
- **Plugins** — first-class extension points for CI status, cost, security posture, on-call

Entity ownership model:
```
Domain ──contains──▶ System ──contains──▶ Component
                                           ├── providesAPI
                                           ├── consumesAPI
                                           └── dependsOn Resource
```

### 2. Infrastructure Abstraction — Crossplane
Crossplane extends Kubernetes with CRDs that represent cloud resources. Platform team authors **Compositions** (implementation); product teams consume **Claims** (interface). This mirrors the Kubernetes API machinery product teams already know.

```
ProductTeam creates:  AppEnvironmentClaim { tier: production, region: eu-west-1 }
                              ↓ Crossplane Composition
Platform provisions:  VPC + EKS NodeGroup + RDS + S3 + IAM roles + ExternalSecrets
```

Key concepts:
- **CompositeResourceDefinition (XRD)** — defines the Claim API (openAPIV3Schema)
- **Composition** — maps Claim fields to managed resources via patches
- **Managed Resources** — atomic cloud primitives (e.g., `RDSInstance`, `S3Bucket`)
- **EnvironmentConfigs** — per-env defaults injected into Compositions
- **Composition Functions** — KCL/CUE/Go for logic-heavy transformations

### 3. Reusable CI — GitHub Actions Callable Workflows
Platform team publishes `/.github/workflows/` in a central `platform-workflows` repo. Product teams call them with minimal config. This gives the platform team one place to update security scanning, signing, and compliance steps.

### 4. Helm Library Charts
Abstract boilerplate Kubernetes manifests into a library chart that product teams depend on. Teams supply values; the library chart renders Deployment + Service + HPA + PodDisruptionBudget + NetworkPolicy + ServiceMonitor consistently.

### 5. Namespace-as-a-Service
Platform provisions each team a Kubernetes namespace with:
- RBAC (`RoleBinding` to team's OIDC group)
- `ResourceQuota` and `LimitRange`
- Default `NetworkPolicy` (deny-all-ingress, allow-from-same-namespace, allow-from-ingress)
- `ServiceAccount` with IRSA/Workload Identity annotation pre-populated

### 6. External Secrets Operator (ESO)
Teams define `ExternalSecret` CRs pointing to Vault/AWS SSM paths the platform team has granted them access to. ESO syncs the Kubernetes `Secret`. Teams never have Vault credentials; they only interact with Kubernetes-native objects.

---

## Anti-Patterns

| Anti-Pattern | Why It Fails | Correction |
|---|---|---|
| **Platform as gatekeeper** | Teams wait on tickets; DORA metrics collapse | Build self-service APIs; automate approvals |
| **No escape hatch** | Teams work around the platform (shadow IT) | Document supported deviation paths |
| **Big-bang launch** | Platform shipped before developer feedback | Dogfood with one team first; iterate |
| **No platform SLOs** | Reliability regressions go unnoticed | Track p99 scaffold time, provision MTTR |
| **Forcing migration** | Resentment; partial adoption worse than none | Incentivise golden path; never mandate cold-turkey |
| **One-size Composition** | Overcomplicated for simple cases | Tiered abstractions: basic / standard / advanced |
| **Secrets in values.yaml** | Secret sprawl, git history exposure | ESO only; never inject secrets via Helm values |
| **Undocumented escape hatches** | Teams copy-paste without understanding debt | Each escape hatch has a runbook and owner |
| **Platform team owns app SLOs** | Wrong accountability boundary | Platform owns infrastructure SLOs; teams own app SLOs |
| **No versioning of platform APIs** | Silent breaks when Composition changes | Semver XRD versions; deprecation policy |

---

## Code Templates

### Template 1 — Backstage catalog-info.yaml + Software Template

```yaml
# catalog-info.yaml (lives in every repo root)
apiVersion: backstage.io/v1alpha1
kind: Component
metadata:
  name: payments-service
  description: Stripe integration and payment processing
  annotations:
    github.com/project-slug: org/payments-service
    backstage.io/techdocs-ref: dir:.
    argocd/app-name: payments-service-prod
    prometheus.io/rule: payments-service
  tags:
    - java
    - kafka
    - pci
  links:
    - url: https://grafana.internal/d/payments
      title: Grafana Dashboard
      icon: dashboard
spec:
  type: service
  lifecycle: production
  owner: group:payments-team
  system: payment-platform
  dependsOn:
    - resource:default/payments-db
    - component:default/fraud-service
  providesApis:
    - payments-api-v2
```

```yaml
# software-template.yaml (Backstage scaffolder template in platform catalogue)
apiVersion: scaffolder.backstage.io/v1beta3
kind: Template
metadata:
  name: new-service-template
  title: New Microservice (Java / Go / Node)
  description: Golden-path service scaffold with CI, SLOs, and catalogue registration
  tags:
    - recommended
    - golden-path
spec:
  owner: group:platform-team
  type: service

  parameters:
    - title: Service Details
      required: [name, description, owner, language]
      properties:
        name:
          title: Service Name
          type: string
          pattern: '^[a-z][a-z0-9-]{2,39}$'
        description:
          title: Short Description
          type: string
        owner:
          title: Owning Team
          type: string
          ui:field: OwnerPicker
          ui:options:
            catalogFilter:
              kind: Group
        language:
          title: Primary Language
          type: string
          enum: [java, go, typescript]
          enumNames: [Java 21, Go 1.22, Node 20 TypeScript]
    - title: Infrastructure
      properties:
        tier:
          title: Service Tier
          type: string
          enum: [standard, high-availability]
          default: standard
        region:
          title: Primary Region
          type: string
          enum: [eu-west-1, ap-southeast-1]
          default: eu-west-1

  steps:
    - id: fetch-template
      name: Fetch Base Template
      action: fetch:template
      input:
        url: ./skeleton/${{ parameters.language }}
        values:
          name: ${{ parameters.name }}
          description: ${{ parameters.description }}
          owner: ${{ parameters.owner }}
          tier: ${{ parameters.tier }}
          region: ${{ parameters.region }}

    - id: create-repo
      name: Create GitHub Repository
      action: publish:github
      input:
        repoUrl: github.com?owner=org&repo=${{ parameters.name }}
        description: ${{ parameters.description }}
        defaultBranch: main
        repoVisibility: internal
        collaborators:
          - team: ${{ parameters.owner }}
            access: push

    - id: register-catalog
      name: Register in Catalogue
      action: catalog:register
      input:
        repoContentsUrl: ${{ steps['create-repo'].output.repoContentsUrl }}
        catalogInfoPath: /catalog-info.yaml

    - id: create-argocd-app
      name: Create ArgoCD Application
      action: argocd:create-resources
      input:
        appName: ${{ parameters.name }}-prod
        argoInstance: prod-cluster
        namespace: ${{ parameters.name }}
        repoUrl: ${{ steps['create-repo'].output.remoteUrl }}
        labelValue: ${{ parameters.name }}
        path: k8s/overlays/prod

  output:
    links:
      - title: Repository
        url: ${{ steps['create-repo'].output.remoteUrl }}
      - title: Open in Catalogue
        icon: catalog
        entityRef: ${{ steps['register-catalog'].output.entityRef }}
```

---

### Template 2 — Crossplane XRD + Composition (App Environment)

```yaml
# xrd-app-environment.yaml
apiVersion: apiextensions.crossplane.io/v1
kind: CompositeResourceDefinition
metadata:
  name: xappenvironments.platform.company.io
spec:
  group: platform.company.io
  names:
    kind: XAppEnvironment
    plural: xappenvironments
  claimNames:
    kind: AppEnvironment        # what product teams create
    plural: appenvironments
  versions:
    - name: v1alpha1
      served: true
      referenceable: true
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              required: [tier, region, teamName]
              properties:
                tier:
                  type: string
                  enum: [standard, high-availability]
                region:
                  type: string
                  enum: [eu-west-1, ap-southeast-1]
                teamName:
                  type: string
                  pattern: '^[a-z][a-z0-9-]{1,29}$'
                dbStorageGiB:
                  type: integer
                  default: 20
                  minimum: 10
                  maximum: 500
            status:
              type: object
              properties:
                dbEndpoint:
                  type: string
                kubeNamespace:
                  type: string
                ready:
                  type: boolean
```

```yaml
# composition-app-environment.yaml
apiVersion: apiextensions.crossplane.io/v1
kind: Composition
metadata:
  name: app-environment-standard
  labels:
    platform.company.io/tier: standard
spec:
  compositeTypeRef:
    apiVersion: platform.company.io/v1alpha1
    kind: XAppEnvironment
  mode: Pipeline
  pipeline:
    - step: render-resources
      functionRef:
        name: function-kcl          # KCL function for logic-heavy rendering
      input:
        apiVersion: krm.kcl.dev/v1alpha1
        kind: KCLRun
        spec:
          source: |
            import regex
            oxr = option("params").oxr
            team  = oxr.spec.teamName
            region = oxr.spec.region
            storage = oxr.spec.dbStorageGiB

            items = [
              # Kubernetes Namespace
              {
                apiVersion: "kubernetes.crossplane.io/v1alpha2"
                kind: "Object"
                metadata.name: "{}-namespace".format(team)
                spec.forProvider.manifest: {
                  apiVersion: "v1"
                  kind: "Namespace"
                  metadata: {
                    name: team
                    labels: {
                      "platform.company.io/team": team
                      "platform.company.io/managed": "true"
                    }
                  }
                }
              },
              # ResourceQuota
              {
                apiVersion: "kubernetes.crossplane.io/v1alpha2"
                kind: "Object"
                metadata.name: "{}-quota".format(team)
                spec.forProvider.manifest: {
                  apiVersion: "v1"
                  kind: "ResourceQuota"
                  metadata: { name: "team-quota", namespace: team }
                  spec.hard: {
                    "requests.cpu": "8"
                    "requests.memory": "16Gi"
                    "limits.cpu": "16"
                    "limits.memory": "32Gi"
                    "count/pods": "50"
                  }
                }
              },
              # RDS PostgreSQL
              {
                apiVersion: "rds.aws.upbound.io/v1beta1"
                kind: "Instance"
                metadata.name: "{}-db".format(team)
                spec: {
                  forProvider: {
                    region: region
                    dbInstanceClass: "db.t4g.medium"
                    engine: "postgres"
                    engineVersion: "16"
                    allocatedStorage: storage
                    storageEncrypted: True
                    multiAz: False      # patched to True for HA tier
                    deletionProtection: True
                    tags: { "team": team }
                  }
                  writeConnectionSecretToRef: {
                    namespace: "crossplane-system"
                    name: "{}-db-conn".format(team)
                  }
                }
              }
            ]

    - step: automatically-detect-ready
      functionRef:
        name: function-auto-ready
```

```yaml
# Product team creates this Claim (one file, no cloud knowledge needed):
apiVersion: platform.company.io/v1alpha1
kind: AppEnvironment
metadata:
  name: payments-env
  namespace: payments-team
spec:
  tier: standard
  region: eu-west-1
  teamName: payments
  dbStorageGiB: 50
```

---

### Template 3 — GitHub Actions Reusable Golden-Path Workflow

```yaml
# .github/workflows/golden-path-service.yml  (in platform-workflows repo)
name: Golden Path — Service CI/CD

on:
  workflow_call:
    inputs:
      service-name:
        required: true
        type: string
      language:
        required: true
        type: string
        # java | go | typescript
      image-registry:
        required: false
        type: string
        default: ghcr.io/org
      deploy-environment:
        required: false
        type: string
        default: staging
    secrets:
      REGISTRY_TOKEN:
        required: true
      COSIGN_PRIVATE_KEY:
        required: false     # optional: keyless signing used when absent

permissions:
  contents: read
  id-token: write           # OIDC for keyless Cosign
  packages: write
  security-events: write

jobs:
  # ── 1. Language-specific build & test ──────────────────────────────────────
  build-test:
    runs-on: ubuntu-latest
    outputs:
      image-digest: ${{ steps.build.outputs.digest }}
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683  # v4.2.2

      - name: Set up toolchain
        uses: ./.github/actions/setup-${{ inputs.language }}   # platform-published composite action

      - name: Run tests
        run: make test

      - name: SAST scan
        uses: github/codeql-action/analyze@f09c1c0a94de965c15400942ca173b84eddb8b0b  # v3.27.5
        with:
          languages: ${{ inputs.language == 'typescript' && 'javascript' || inputs.language }}

      - name: Build & push image
        id: build
        uses: docker/build-push-action@4f58ea79222b3b9dc2c8bbdd6debcef730109a75  # v6.9.0
        with:
          push: true
          tags: ${{ inputs.image-registry }}/${{ inputs.service-name }}:${{ github.sha }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
          provenance: true
          sbom: true

  # ── 2. Sign + attest ────────────────────────────────────────────────────────
  sign-attest:
    needs: build-test
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683

      - name: Install Cosign
        uses: sigstore/cosign-installer@dc72c7d5c4d10cd6bcb8cf6e3fd625a9e5e537da  # v3.7.0

      - name: Sign image (keyless)
        run: |
          cosign sign --yes \
            ${{ inputs.image-registry }}/${{ inputs.service-name }}@${{ needs.build-test.outputs.image-digest }}

      - name: Generate SBOM
        uses: anchore/sbom-action@fc46e51fd3cb168ffb36cc6b6b12a1cd82b59f9f  # v0.17.9
        with:
          image: ${{ inputs.image-registry }}/${{ inputs.service-name }}@${{ needs.build-test.outputs.image-digest }}
          format: cyclonedx-json
          output-file: sbom.cdx.json

      - name: Attest SBOM
        run: |
          cosign attest --yes \
            --predicate sbom.cdx.json \
            --type cyclonedx \
            ${{ inputs.image-registry }}/${{ inputs.service-name }}@${{ needs.build-test.outputs.image-digest }}

      - name: Vulnerability gate
        uses: anchore/scan-action@7c05671ae9be166aeb155bad2d7df9121823df32  # v5.3.0
        with:
          image: ${{ inputs.image-registry }}/${{ inputs.service-name }}@${{ needs.build-test.outputs.image-digest }}
          fail-build: true
          severity-cutoff: critical

  # ── 3. GitOps promotion ────────────────────────────────────────────────────
  promote:
    needs: sign-attest
    runs-on: ubuntu-latest
    environment: ${{ inputs.deploy-environment }}
    steps:
      - name: Update image tag in GitOps repo
        uses: actions/github-script@60a0d83039c74a4aee543508d2ffcb1c3799cdea  # v7.0.1
        with:
          github-token: ${{ secrets.GITOPS_TOKEN }}
          script: |
            const { data: file } = await github.rest.repos.getContent({
              owner: 'org', repo: 'gitops-config',
              path: `apps/${{ inputs.service-name }}/${{ inputs.deploy-environment }}/kustomization.yaml`
            });
            const content = Buffer.from(file.content, 'base64').toString();
            const updated = content.replace(
              /newTag: .+/,
              `newTag: ${{ github.sha }}`
            );
            await github.rest.repos.createOrUpdateFileContents({
              owner: 'org', repo: 'gitops-config',
              path: `apps/${{ inputs.service-name }}/${{ inputs.deploy-environment }}/kustomization.yaml`,
              message: `chore: promote ${{ inputs.service-name }} to ${{ github.sha }}`,
              content: Buffer.from(updated).toString('base64'),
              sha: file.sha
            });
```

```yaml
# Product team's .github/workflows/ci.yml  (5-line consumer):
name: CI/CD
on:
  push:
    branches: [main]
jobs:
  pipeline:
    uses: org/platform-workflows/.github/workflows/golden-path-service.yml@main
    with:
      service-name: payments-service
      language: go
    secrets:
      REGISTRY_TOKEN: ${{ secrets.REGISTRY_TOKEN }}
```

---

### Template 4 — Helm Library Chart (Platform Base Chart)

```yaml
# charts/platform-service/Chart.yaml
apiVersion: v2
name: platform-service
description: Platform library chart — base templates for all services
type: library
version: 1.4.0
```

```yaml
# charts/platform-service/templates/_deployment.yaml
{{- define "platform-service.deployment" -}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "platform-service.fullname" . }}
  labels: {{ include "platform-service.labels" . | nindent 4 }}
spec:
  replicas: {{ .Values.replicaCount | default 2 }}
  selector:
    matchLabels: {{ include "platform-service.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      labels: {{ include "platform-service.selectorLabels" . | nindent 8 }}
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "{{ .Values.metrics.port | default 9090 }}"
    spec:
      serviceAccountName: {{ include "platform-service.fullname" . }}
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: {{ .Chart.Name }}
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          imagePullPolicy: IfNotPresent
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: [ALL]
          ports:
            - name: http
              containerPort: {{ .Values.service.port | default 8080 }}
            - name: metrics
              containerPort: {{ .Values.metrics.port | default 9090 }}
          env:
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: POD_NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
          {{- with .Values.env }}
          {{- toYaml . | nindent 12 }}
          {{- end }}
          resources: {{ toYaml (.Values.resources | default (include "platform-service.defaultResources" . | fromYaml)) | nindent 12 }}
          livenessProbe:
            httpGet:
              path: {{ .Values.probes.liveness | default "/healthz" }}
              port: http
            initialDelaySeconds: 10
            periodSeconds: 15
          readinessProbe:
            httpGet:
              path: {{ .Values.probes.readiness | default "/readyz" }}
              port: http
            initialDelaySeconds: 5
            periodSeconds: 10
          volumeMounts:
            - name: tmp
              mountPath: /tmp
            {{- with .Values.extraVolumeMounts }}
            {{- toYaml . | nindent 12 }}
            {{- end }}
      volumes:
        - name: tmp
          emptyDir: {}
        {{- with .Values.extraVolumes }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels: {{ include "platform-service.selectorLabels" . | nindent 14 }}
{{- end -}}

{{- define "platform-service.defaultResources" -}}
requests:
  cpu: 100m
  memory: 128Mi
limits:
  memory: 512Mi
{{- end -}}
```

```yaml
# Product team's Chart.yaml (consumer):
apiVersion: v2
name: payments-service
version: 0.1.0
dependencies:
  - name: platform-service
    version: "^1.4.0"
    repository: oci://ghcr.io/org/helm-charts
```

```yaml
# Product team's templates/deployment.yaml (3 lines):
{{- template "platform-service.deployment" . }}
{{- template "platform-service.hpa" . }}
{{- template "platform-service.servicemonitor" . }}
```

---

### Template 5 — Namespace-as-a-Service (Kubernetes RBAC + Policies)

```yaml
# Platform provisions this bundle per team (Kustomize overlay or Crossplane Object)
---
apiVersion: v1
kind: Namespace
metadata:
  name: payments-team
  labels:
    platform.company.io/team: payments
    platform.company.io/cost-centre: "CC-4201"
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.30
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: team-quota
  namespace: payments-team
spec:
  hard:
    requests.cpu: "8"
    requests.memory: 16Gi
    limits.memory: 32Gi
    count/pods: "50"
    count/services: "20"
    persistentvolumeclaims: "10"
---
apiVersion: v1
kind: LimitRange
metadata:
  name: container-defaults
  namespace: payments-team
spec:
  limits:
    - type: Container
      default:
        memory: 256Mi
      defaultRequest:
        cpu: 50m
        memory: 64Mi
      max:
        memory: 4Gi
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: team-developers
  namespace: payments-team
subjects:
  - kind: Group
    name: payments-team           # OIDC group from IdP (Okta/Entra)
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: edit                      # platform ships curated ClusterRoles
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: payments-team
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress-nginx
        - podSelector: {}          # allow within same namespace
  egress:
    - to:
        - namespaceSelector: {}    # allow cross-namespace (DNS etc.)
    - ports:
        - port: 53
          protocol: UDP
---
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: vault-backend
  namespace: payments-team
spec:
  provider:
    vault:
      server: https://vault.internal
      path: secret
      version: v2
      auth:
        kubernetes:
          mountPath: kubernetes
          role: payments-team      # Vault role scoped to this namespace SA
          serviceAccountRef:
            name: external-secrets-sa
```

---

### Template 6 — Backstage Custom Plugin (TypeScript — Deployment Status Panel)

```typescript
// plugins/deployment-status/src/plugin.ts
import { createPlugin, createRoutableExtension } from '@backstage/core-plugin-api';
import { rootRouteRef } from './routes';

export const deploymentStatusPlugin = createPlugin({
  id: 'deployment-status',
  routes: { root: rootRouteRef },
});

export const DeploymentStatusCard = deploymentStatusPlugin.provide(
  createRoutableExtension({
    name: 'DeploymentStatusCard',
    component: () =>
      import('./components/DeploymentStatusCard').then(m => m.DeploymentStatusCard),
    mountPoint: rootRouteRef,
  }),
);
```

```typescript
// plugins/deployment-status/src/components/DeploymentStatusCard.tsx
import React from 'react';
import { useEntity } from '@backstage/plugin-catalog-react';
import { useApi, configApiRef } from '@backstage/core-plugin-api';
import { InfoCard, Progress, StatusOK, StatusError, StatusPending } from '@backstage/core-components';
import { useAsync } from 'react-use';

interface DeploymentInfo {
  environment: string;
  status: 'healthy' | 'degraded' | 'deploying';
  imageTag: string;
  deployedAt: string;
  argoHealth: string;
}

export const DeploymentStatusCard = () => {
  const { entity } = useEntity();
  const config = useApi(configApiRef);
  const backendUrl = config.getString('backend.baseUrl');

  const { value: deployments, loading, error } = useAsync(async (): Promise<DeploymentInfo[]> => {
    const appName = entity.metadata.annotations?.['argocd/app-name'];
    if (!appName) return [];
    const resp = await fetch(
      `${backendUrl}/api/deployment-status/${appName}`,
      { headers: { 'Content-Type': 'application/json' } },
    );
    if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
    return resp.json();
  }, [entity.metadata.name]);

  const statusIcon = (s: DeploymentInfo['status']) => {
    if (s === 'healthy')   return <StatusOK />;
    if (s === 'deploying') return <StatusPending />;
    return <StatusError />;
  };

  if (loading) return <Progress />;
  if (error)   return <InfoCard title="Deployment Status">Error: {error.message}</InfoCard>;

  return (
    <InfoCard title="Deployment Status" noPadding>
      <table style={{ width: '100%', borderCollapse: 'collapse' }}>
        <thead>
          <tr>
            {['Environment', 'Status', 'Image Tag', 'Deployed At'].map(h => (
              <th key={h} style={{ textAlign: 'left', padding: '8px 16px', borderBottom: '1px solid #eee' }}>{h}</th>
            ))}
          </tr>
        </thead>
        <tbody>
          {deployments?.map(d => (
            <tr key={d.environment}>
              <td style={{ padding: '8px 16px' }}>{d.environment}</td>
              <td style={{ padding: '8px 16px' }}>{statusIcon(d.status)} {d.status}</td>
              <td style={{ padding: '8px 16px', fontFamily: 'monospace' }}>{d.imageTag.slice(0, 12)}</td>
              <td style={{ padding: '8px 16px' }}>{new Date(d.deployedAt).toLocaleString()}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </InfoCard>
  );
};
```

```typescript
// plugins/deployment-status/src/backend/router.ts
// Backend plugin — proxies to ArgoCD API, surfaces to frontend
import { Router } from 'express';
import { LoggerService, CacheService } from '@backstage/backend-plugin-api';

export function createRouter(options: { logger: LoggerService; cache: CacheService }): Router {
  const router = Router();

  router.get('/:appName', async (req, res) => {
    const { appName } = req.params;
    const cacheKey = `deployments:${appName}`;

    const cached = await options.cache.get<object[]>(cacheKey);
    if (cached) return res.json(cached);

    const argoCdUrl = process.env.ARGOCD_SERVER_URL;
    const token    = process.env.ARGOCD_AUTH_TOKEN;   // injected via ESO

    const [stagingRes, prodRes] = await Promise.all([
      fetch(`${argoCdUrl}/api/v1/applications/${appName}-staging`, {
        headers: { Authorization: `Bearer ${token}` },
      }),
      fetch(`${argoCdUrl}/api/v1/applications/${appName}-prod`, {
        headers: { Authorization: `Bearer ${token}` },
      }),
    ]);

    const [staging, prod] = await Promise.all([stagingRes.json(), prodRes.json()]);

    const toDeploymentInfo = (app: any, env: string) => ({
      environment: env,
      status: app.status?.health?.status === 'Healthy' ? 'healthy' : 'degraded',
      imageTag: app.status?.summary?.images?.[0]?.split(':')[1] ?? 'unknown',
      deployedAt: app.status?.operationState?.finishedAt ?? '',
      argoHealth: app.status?.health?.status ?? 'Unknown',
    });

    const result = [toDeploymentInfo(staging, 'staging'), toDeploymentInfo(prod, 'production')];

    await options.cache.set(cacheKey, result, { ttl: 30_000 });
    res.json(result);
  });

  return router;
}
```

---

## Decision Matrix

| Scenario | Recommendation | Rationale |
|---|---|---|
| Team needs a new service repo with CI and SLOs | Backstage software template | One-click scaffold; consistent from day one |
| Team needs a managed RDS/S3/IAM stack | Crossplane `AppEnvironment` Claim | Cloud API abstracted; team uses Kubernetes vocabulary |
| Team needs Vault secrets in their namespace | `ExternalSecret` CR pointing to their Vault path | No direct Vault access; ESO handles sync |
| Org has 3 teams, all small | Lightweight IDP (Port or raw Backstage + 2 plugins) | Full Backstage is over-engineered below ~8 teams |
| Org has 20+ teams, 200+ services | Full Backstage + Crossplane + ESO + ArgoCD | Investment justified; cognitive load savings compound |
| Team needs to deviate from golden path | Documented escape hatch with `platform.company.io/unmanaged: "true"` label | Explict opt-out; platform team aware; no silent drift |
| New platform team, no existing IDP | Start with reusable GitHub Actions + Helm library chart | Immediate value; no portal ops burden day one |
| Need to enforce security policies at scale | OPA Gatekeeper / Kyverno on admission | Platform-layer enforcement; teams can't bypass |
| Platform team measuring success | DORA metrics per team + platform SLOs (scaffold p99, provision MTTR) | Developer productivity signal + reliability signal |
| Secrets rotation required | ESO `refreshInterval` + Vault dynamic secrets | Rotation handled outside app lifecycle |

---

## Proficiency Levels

### Level 1 — Aware
- Understands golden paths reduce cognitive load for product teams
- Can consume an existing Backstage template to scaffold a new service
- Knows the difference between a Claim (team-facing) and a Composition (platform-team-facing) in Crossplane
- Can add a `catalog-info.yaml` to an existing repo

### Level 2 — Practitioner
- Maintains and extends existing Backstage software templates
- Writes Crossplane Compositions for straightforward cloud resource bundles (Namespace + DB + S3)
- Builds reusable GitHub Actions callable workflows covering CI → sign → promote
- Configures External Secrets Operator `SecretStore` + `ExternalSecret` for a team
- Measures platform SLOs: scaffold time, provision time, MTTR

### Level 3 — Advanced
- Designs the full IDP platform architecture: Backstage + Crossplane + ESO + GitOps reconciler
- Authors Crossplane Compositions using Functions (KCL/CUE) for multi-resource environments with conditional logic
- Builds Backstage backend plugins that proxy to internal systems (ArgoCD, Grafana, cost APIs)
- Establishes platform versioning and deprecation policies for XRD versions and software templates
- Runs developer experience research; uses DORA metrics to drive platform investment decisions

### Level 4 — Expert
- Operates an IDP at scale (50+ stream-aligned teams, 500+ services)
- Designs multi-cluster Crossplane topologies with per-region EnvironmentConfigs and provider failover
- Implements platform observability: audit trails for every self-service action, blast-radius analysis for platform changes
- Runs platform change management: canary-roll Composition changes without breaking existing Claims
- Contributes to upstream Backstage and Crossplane projects; shapes their roadmaps for enterprise use cases

---

## AI Prompts

**Design a Crossplane Composition**
```
Design a Crossplane Composition named XAppEnvironment that provisions:
[list cloud resources].
Use Composition Functions with KCL for conditional logic.
Expose only [list fields] in the Claim API.
Include status conditions and write connection details to a Secret.
Output: XRD YAML, Composition YAML, and an example Claim.
```

**Generate a Backstage Software Template**
```
Create a Backstage scaffolder template that:
- Asks for: service name, owning team, primary language (go/java/typescript), tier (standard/ha)
- Creates a GitHub repo from a skeleton in ./skeleton/${language}
- Registers the component in the Backstage catalogue
- Creates an ArgoCD Application in the prod cluster
- Outputs links to the repo and catalogue entry
Include parameter validation patterns (e.g., name must be lowercase kebab-case).
```

**Review Platform SLO Coverage**
```
Review this IDP platform and identify gaps in SLO coverage:
[paste platform architecture / tool list].
For each gap, suggest: the metric to track, the data source, the alerting threshold,
and which team (platform vs stream-aligned) is accountable.
Focus on developer-experience SLOs (time-to-value) as well as reliability SLOs.
```

**Golden Path CI Workflow Audit**
```
Audit this GitHub Actions reusable workflow for a golden-path CI/CD pipeline:
[paste workflow YAML].
Check for: hardcoded secrets, unpinned action SHA references, missing OIDC permissions,
missing image signing/attestation steps, missing vulnerability gates, and drift
from SLSA level 2 requirements.
Output a prioritised list of findings with remediation snippets.
```

**Namespace-as-a-Service Bundle**
```
Generate a Kubernetes Namespace-as-a-Service bundle for team [name] that includes:
- Namespace with Pod Security Standards (restricted) and cost-centre label
- ResourceQuota: [cpu/memory/pod limits]
- LimitRange with container defaults
- RoleBinding mapping OIDC group [group-name] to the edit ClusterRole
- Default-deny NetworkPolicy with allowances for ingress-nginx and same-namespace pods
- ExternalSecret pointing to Vault path secret/data/[team]/*
Output as a single multi-document YAML file.
```

---

## References

- **Team Topologies** — Matthew Skelton & Manuel Pais; foundational framing for platform teams
- **Backstage documentation** — `backstage.io/docs` — software templates, plugins, catalogue model
- **Crossplane documentation** — `docs.crossplane.io` — XRDs, Compositions, Composition Functions
- **CNCF Platforms White Paper** — `tag-app-delivery.cncf.io` — maturity model for platform engineering
- **Internal Developer Portal landscape** — Backstage, Port, Cortex, OpsLevel, Humanitec — comparison maintained by CNCF TAG App Delivery
- **External Secrets Operator** — `external-secrets.io` — SecretStore providers, rotation, pushSecrets
- **ArgoCD documentation** — `argo-cd.readthedocs.io` — ApplicationSet, app-of-apps, RBAC
- **Flux documentation** — `fluxcd.io` — alternative GitOps reconciler; stronger multi-tenancy model
- **Helm library charts** — `helm.sh/docs/topics/library-charts` — shared template definitions
- **DORA metrics** — `dora.dev` — deployment frequency, lead time, MTTR, change failure rate
- **GitHub Actions reusable workflows** — `docs.github.com/actions/using-workflows/reusing-workflows`
- **Kustomize** — `kustomize.io` — overlay-based Kubernetes configuration management
