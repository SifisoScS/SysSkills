---
name: Service Mesh & Network Policies
slug: service-mesh-network-policies
category: 04-backend-and-services
proficiency: advanced
description: >
  Design and operate service mesh infrastructure: Istio mTLS service identity,
  traffic management (VirtualService, DestinationRule, Gateway API HTTPRoute),
  Envoy sidecar vs eBPF ambient mesh (Cilium, Istio Ambient), Kubernetes
  NetworkPolicy for L3/L4 micro-segmentation, Cilium L7 HTTP/gRPC policy,
  egress control, multi-cluster mesh, and mesh-native observability (access
  logs, metrics, distributed traces from the data plane without code changes).
tags:
  - service-mesh
  - istio
  - cilium
  - envoy
  - mtls
  - network-policy
  - ambient-mesh
  - gateway-api
  - zero-trust-network
  - ebpf
status: published
---

## Principles

### 1. The Mesh Moves Cross-Cutting Concerns Out of Application Code
Retry logic, mTLS, circuit breaking, request tracing, and rate limiting
implemented per-service in application code are duplicated across every team,
in every language, at different quality levels. A service mesh implements these
uniformly at the **infrastructure layer** (sidecar proxy or eBPF kernel hook)
without touching application code. The application speaks plain HTTP/gRPC;
the mesh handles the rest.

### 2. mTLS Service Identity Replaces IP-Based Trust
In a traditional cluster, any pod on the network can reach any other pod.
Mutual TLS authenticates *both* sides of every connection using SPIFFE/SPIRE
workload identities tied to Kubernetes ServiceAccounts. Authorisation policies
then express "ServiceAccount A may call ServiceAccount B on path /api/v1/orders"
— not "pod at 10.0.1.5 may reach 10.0.2.3:8080". This is the network layer of
Zero Trust architecture.

### 3. Traffic Management Is Configuration, Not Code
Canary deployments, A/B tests, fault injection, traffic mirroring, and
header-based routing are expressed as Kubernetes custom resources
(`VirtualService`, `HTTPRoute`) applied by the control plane. No code changes,
no redeployment. Teams ship features; the mesh handles progressive delivery.

### 4. Sidecar vs Ambient: Match the Model to the Workload
Sidecar (Istio Envoy proxy per pod) provides per-pod isolation and the richest
feature set but adds ~50 MB memory and ~0.5 ms latency per hop.
**Ambient mesh** (Istio Ambient, Cilium) moves the data plane to a per-node
ztunnel (L4) and optional waypoint proxy (L7) — no sidecar injection, no pod
restart on mesh adoption, ~5 MB overhead per node. Choose sidecar for maximum
policy granularity; choose ambient for large clusters where sidecar overhead
is prohibitive.

### 5. NetworkPolicy Is Deny-by-Default — Enforce It
A Kubernetes cluster without NetworkPolicy allows every pod to reach every
other pod on any port. A **default-deny** NetworkPolicy in every namespace
closes this surface. Only explicitly permitted traffic flows. Combine L3/L4
NetworkPolicy (Calico, Cilium) with mesh L7 AuthorizationPolicy for
defence-in-depth.

---

## Implementation Patterns

### Pattern A: Namespace Isolation + Default Deny
Apply a default-deny NetworkPolicy to every namespace as the baseline. Add
allow rules for specific ingress/egress requirements. This enforces least
privilege at the network layer independently of the mesh.

### Pattern B: SPIFFE Workload Identity + Istio AuthorizationPolicy
Istio assigns each pod a SPIFFE SVID (X.509 certificate) based on its
Kubernetes ServiceAccount. `AuthorizationPolicy` expresses access control in
terms of `principals` (ServiceAccount) and `operations` (HTTP method + path)
rather than IP addresses — policies survive pod restarts and IP changes.

### Pattern C: Progressive Delivery via Traffic Splitting
`VirtualService` weights split traffic between service versions (v1, v2) by
percentage. Combined with `DestinationRule` subsets (pod label selectors),
this enables canary deployment independent of the number of replicas per
version.

### Pattern D: Egress Control with ServiceEntry
By default Istio passes-through unknown external traffic. Enable
`meshConfig.outboundTrafficPolicy: REGISTRY_ONLY` to block all undeclared
egress, then create `ServiceEntry` resources for permitted external endpoints.
This prevents data exfiltration and enforces explicit egress governance.

---

## Anti-Patterns

| Anti-Pattern | Consequence | Fix |
|---|---|---|
| No default-deny NetworkPolicy | Any compromised pod can reach any other pod; lateral movement trivial | Apply `NetworkPolicy` default-deny to every namespace at cluster bootstrap |
| Permissive `AuthorizationPolicy` with wildcard principals | All services can call all services; mesh provides observability but no enforcement | Define per-service `AuthorizationPolicy`; deny unless explicitly allowed |
| Istio `passthrough` egress policy | Services freely reach external internet; data exfiltration undetected | Set `outboundTrafficPolicy: REGISTRY_ONLY`; allowlist external hosts with `ServiceEntry` |
| Sidecar injection in system namespaces (`kube-system`) | Istio intercepts critical cluster traffic; DNS and CNI may break | Never inject sidecars into system namespaces; use `istio-injection: disabled` label |
| VirtualService without DestinationRule subsets | Traffic splitting config silently has no effect; all traffic goes to all pods | Always pair `VirtualService` weights with `DestinationRule` subset label selectors |
| Disabling mTLS with `PeerAuthentication: PERMISSIVE` permanently | Plain-text traffic accepted indefinitely; crypto identity not verified | Use `PERMISSIVE` only during migration; flip to `STRICT` once all clients support mTLS |
| Applying L7 policy without waypoint (ambient mode) | L7 `AuthorizationPolicy` on ambient mesh requires a waypoint proxy; silently ignored without one | Deploy a `Gateway` waypoint resource for the namespace before applying L7 ambient policies |

---

## Code Templates

### Template 1 — Istio: mTLS Strict Mode + AuthorizationPolicy
```yaml
# peer-authentication.yaml — enforce mTLS for entire namespace
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default
  namespace: production
spec:
  mtls:
    mode: STRICT       # reject all plain-text; require mTLS from all callers
---
# authz-order-service.yaml — only allow checkout to call order-service
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: order-service-ingress
  namespace: production
spec:
  selector:
    matchLabels:
      app: order-service
  action: ALLOW
  rules:
  - from:
    - source:
        principals:
          # SPIFFE identity: spiffe://<trust-domain>/ns/<ns>/sa/<serviceaccount>
          - "cluster.local/ns/production/sa/checkout-service"
    to:
    - operation:
        methods: ["POST", "GET"]
        paths: ["/api/v1/orders", "/api/v1/orders/*"]
  - from:
    - source:
        principals:
          - "cluster.local/ns/production/sa/admin-service"
    to:
    - operation:
        methods: ["GET"]
        paths: ["/api/v1/orders/*"]
```

### Template 2 — Istio: Canary Traffic Split + Fault Injection
```yaml
# destination-rule-order.yaml — define v1 and v2 subsets
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: order-service
  namespace: production
spec:
  host: order-service
  trafficPolicy:
    connectionPool:
      http: { http2MaxRequests: 200 }
    outlierDetection:
      consecutiveGatewayErrors: 5
      interval: 10s
      baseEjectionTime: 30s
  subsets:
  - name: v1
    labels: { version: v1 }
  - name: v2
    labels: { version: v2 }
---
# virtual-service-order.yaml — 90/10 canary split + fault injection for testing
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: order-service
  namespace: production
spec:
  hosts: [order-service]
  http:
  # Inject a 5 % error rate for canary validation (remove in production)
  - match:
    - headers:
        x-chaos-test: { exact: "true" }
    fault:
      abort:
        percentage: { value: 5.0 }
        httpStatus: 503
    route:
    - destination: { host: order-service, subset: v2 }
  # Main traffic split: 90 % v1, 10 % v2
  - route:
    - destination: { host: order-service, subset: v1 }
      weight: 90
    - destination: { host: order-service, subset: v2 }
      weight: 10
    timeout: 3s
    retries:
      attempts: 2
      perTryTimeout: 1s
      retryOn: "gateway-error,connect-failure,503"
```

### Template 3 — Kubernetes NetworkPolicy: Default Deny + Selective Allow
```yaml
# default-deny-all.yaml — apply to every namespace at bootstrap
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: production
spec:
  podSelector: {}          # selects all pods in namespace
  policyTypes:
  - Ingress
  - Egress
---
# allow-order-service.yaml — allow specific ingress + required egress
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: order-service-policy
  namespace: production
spec:
  podSelector:
    matchLabels:
      app: order-service
  policyTypes:
  - Ingress
  - Egress
  ingress:
  # Accept traffic from checkout-service and ingress controller
  - from:
    - podSelector:
        matchLabels:
          app: checkout-service
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: ingress-nginx
    ports:
    - protocol: TCP
      port: 8080
  egress:
  # Allow DNS (required for service discovery)
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: kube-system
    ports:
    - protocol: UDP
      port: 53
    - protocol: TCP
      port: 53
  # Allow calls to postgres and redis in same namespace
  - to:
    - podSelector:
        matchLabels:
          app: postgres
    ports:
    - { protocol: TCP, port: 5432 }
  - to:
    - podSelector:
        matchLabels:
          app: redis
    ports:
    - { protocol: TCP, port: 6379 }
```

### Template 4 — Cilium: L7 HTTP Policy (eBPF, no sidecar)
```yaml
# cilium-network-policy-l7.yaml — Cilium L7 policy enforced in eBPF kernel
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: order-service-l7
  namespace: production
spec:
  endpointSelector:
    matchLabels:
      app: order-service
  ingress:
  - fromEndpoints:
    - matchLabels:
        app: checkout-service
    toPorts:
    - ports:
      - port: "8080"
        protocol: TCP
      rules:
        http:
        - method: "POST"
          path: "^/api/v1/orders$"
        - method: "GET"
          path: "^/api/v1/orders/[a-z0-9-]+$"
  egress:
  # Allow egress to Postgres only
  - toEndpoints:
    - matchLabels:
        app: postgres
    toPorts:
    - ports:
      - port: "5432"
        protocol: TCP
  # Allow DNS
  - toEndpoints:
    - matchLabels:
        k8s:io.kubernetes.pod.namespace: kube-system
    toPorts:
    - ports:
      - port: "53"
        protocol: UDP
      rules:
        dns:
        - matchPattern: "*.production.svc.cluster.local"
        - matchPattern: "*.svc.cluster.local"
```

### Template 5 — Istio: Egress ServiceEntry + Gateway
```yaml
# serviceentry-payment-gateway.yaml — allowlist external payment API
apiVersion: networking.istio.io/v1beta1
kind: ServiceEntry
metadata:
  name: payment-gateway-external
  namespace: production
spec:
  hosts:
  - api.payment-provider.com
  ports:
  - number: 443
    name: https
    protocol: HTTPS
  location: MESH_EXTERNAL
  resolution: DNS
---
# egress-gateway.yaml — route external traffic through a dedicated egress node
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: payment-gateway-egress
  namespace: production
spec:
  hosts: [api.payment-provider.com]
  gateways:
  - mesh               # applies to sidecar
  - istio-egressgateway
  tls:
  - match:
    - gateways: [mesh]
      port: 443
      sniHosts: [api.payment-provider.com]
    route:
    - destination:
        host: istio-egressgateway.istio-system.svc.cluster.local
        port: { number: 443 }
  - match:
    - gateways: [istio-egressgateway]
      port: 443
      sniHosts: [api.payment-provider.com]
    route:
    - destination:
        host: api.payment-provider.com
        port: { number: 443 }
```

### Template 6 — Gateway API: HTTPRoute (next-gen Ingress)
```yaml
# gateway.yaml — shared Gateway owned by the platform team
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: shared-gateway
  namespace: istio-ingress
spec:
  gatewayClassName: istio
  listeners:
  - name: https
    port: 443
    protocol: HTTPS
    tls:
      mode: Terminate
      certificateRefs:
      - name: wildcard-tls-cert
    allowedRoutes:
      namespaces:
        from: Selector
        selector:
          matchLabels:
            gateway-access: allowed
---
# httproute-orders.yaml — owned by the orders team; no platform team required
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: orders-route
  namespace: production
spec:
  parentRefs:
  - name: shared-gateway
    namespace: istio-ingress
  hostnames: ["api.company.com"]
  rules:
  - matches:
    - path: { type: PathPrefix, value: /api/v1/orders }
    backendRefs:
    - name: order-service
      port: 8080
      weight: 90
    - name: order-service-v2
      port: 8080
      weight: 10
    filters:
    - type: RequestHeaderModifier
      requestHeaderModifier:
        add:
        - name: x-gateway-version
          value: "2"
```

---

## Decision Matrix

| Requirement | Istio (sidecar) | Cilium (eBPF) | Linkerd | Notes |
|---|---|---|---|---|
| L7 HTTP/gRPC policy | Full support | Full support (CiliumNetworkPolicy) | Full support | All three viable |
| Zero-sidecar overhead | No (sidecar) | Yes (eBPF kernel) | Micro-proxy (rust, ~5 MB) | Cilium lowest overhead |
| mTLS service identity | SPIFFE/SPIRE via Envoy | Wireguard-based or SPIRE | SPIFFE/SPIRE | Istio most mature |
| Multi-cluster mesh | Istio multi-primary | Cilium ClusterMesh | Linkerd multi-cluster | Istio most feature-rich |
| Traffic mirroring / fault injection | VirtualService built-in | Limited | Limited | Istio advantage |
| Existing NetworkPolicy migration | Works alongside | Replaces NetworkPolicy | Works alongside | Cilium replaces L3/L4 CNI |
| Ambient mode (no sidecar) | Istio Ambient (stable 1.22+) | Always ambient | No | Istio Ambient narrowing the gap |
| Learning curve | High (many CRDs) | Medium | Low | Linkerd simplest to start |

---

## Proficiency Levels

### Novice
- Knows what a service mesh does at a conceptual level
- Understands the difference between `NetworkPolicy` and `AuthorizationPolicy`
- Can read a `VirtualService` and understand what it does
- Knows what mTLS is and why IP-based trust is insufficient

### Intermediate
- Configures Istio `PeerAuthentication` (STRICT mTLS) + `AuthorizationPolicy` for a namespace
- Implements traffic splitting between two service versions with `VirtualService` + `DestinationRule`
- Applies default-deny `NetworkPolicy` to a namespace with selective allow rules
- Uses `istioctl analyze` and Kiali to diagnose mesh configuration issues
- Enables and queries Envoy access logs and mesh-generated Prometheus metrics

### Advanced
- Designs namespace isolation strategy for multi-tenant clusters with Cilium L7 policies
- Configures Istio egress gateway with `ServiceEntry` for external allowlisting
- Implements Gateway API `HTTPRoute` for team-owned ingress without platform dependency
- Deploys Istio Ambient mesh and configures waypoint proxies for L7 policy
- Performs mesh traffic analysis with `istioctl proxy-config` and Envoy admin API

### Expert
- Architects multi-cluster Istio mesh with trust domain federation
- Designs Cilium ClusterMesh for cross-cluster east-west traffic with identity preservation
- Implements custom Envoy filters (`EnvoyFilter` CRD) for bespoke protocol handling
- Defines organisation-wide mesh governance: default policies, allowed exceptions, audit trail
- Evaluates and migrates between mesh implementations (Istio → Ambient, CNI → Cilium)

---

## AI Prompts

```
You are an Istio expert. I have a Kubernetes cluster with 40 microservices.
Currently there is no network isolation — any pod can reach any pod. Design
the step-by-step plan to adopt Istio with mTLS strict mode: installation
approach, namespace-by-namespace migration from PERMISSIVE to STRICT, how to
verify each namespace before flipping, and how to write AuthorizationPolicies
for a service that has 6 callers.
```

```
Acting as a zero-trust network architect: explain how SPIFFE workload
identities eliminate the need for IP-based firewall rules in a Kubernetes
cluster. Show the chain from Kubernetes ServiceAccount → Istio-issued X.509
SVID → mTLS handshake → AuthorizationPolicy principal match. What breaks
if the SPIFFE trust domain is misconfigured?
```

```
Compare Cilium NetworkPolicy (eBPF L7) vs Istio AuthorizationPolicy (Envoy
sidecar L7) for enforcing HTTP path and method restrictions between two
services. When would you use one over the other? What are the failure modes
of each approach?
```

```
My team wants to do canary deployments using Istio traffic splitting without
changing the number of pod replicas. Show the exact VirtualService and
DestinationRule configuration to send 5% of traffic to a v2 Deployment while
keeping v1 at 95%. How do I validate the split is working correctly, and what
is the safe rollback procedure?
```

```
Design an egress control strategy for a multi-tenant SaaS platform on
Kubernetes. Tenants must only be able to reach explicitly approved external
APIs. Show the Istio ServiceEntry + egress Gateway approach and the Cilium
FQDN-based egress policy approach. Compare the operational overhead of
maintaining each allow-list as tenants add new external dependencies.
```

---

## References

- **Istio docs** — https://istio.io/docs — VirtualService, DestinationRule, AuthorizationPolicy
- **Istio Ambient mesh** — https://istio.io/docs/ambient/ — stable from Istio 1.22
- **Cilium docs** — https://docs.cilium.io — NetworkPolicy, L7 policy, ClusterMesh
- **Linkerd docs** — https://linkerd.io/docs — lightweight Rust proxy mesh
- **SPIFFE/SPIRE** — https://spiffe.io — workload identity standard
- **Gateway API** — https://gateway-api.sigs.k8s.io — next-generation Kubernetes Ingress/routing
- **Envoy proxy** — https://www.envoyproxy.io/docs — underlying data plane for Istio/AWS App Mesh
- **Kiali** — https://kiali.io — Istio service mesh observability console
- **Calico** — https://docs.tigera.io/calico — NetworkPolicy with GlobalNetworkPolicy
- **Zero Trust Networks** — Gilman & Barth, O'Reilly 2017
- **SysSkills cross-reference** — `cicd-gitops-strategy`, `kernel-security`,
  `authentication-and-authorization`, `resilience-fault-tolerance-patterns`
