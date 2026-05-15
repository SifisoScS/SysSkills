---
name: Container & Runtime Security
slug: container-runtime-security
category: 06-security-and-compliance
proficiency: advanced
description: >
  Harden containers and Kubernetes workloads at runtime: Falco rule authoring
  for syscall and Kubernetes audit events, OPA/Kyverno admission policies,
  gVisor kernel sandboxing (runsc), Kata Containers VM isolation, seccomp
  profile generation and enforcement, image hardening (distroless, non-root,
  read-only filesystem), CIS Kubernetes Benchmark controls, and NeuVector
  network-level threat detection.
tags:
  - container-security
  - falco
  - kyverno
  - opa
  - gvisor
  - kata-containers
  - seccomp
  - distroless
  - cis-benchmark
  - runtime-security
  - pod-security
status: complete
---

## Principles

### Defence in Depth for Containers
```
Layer 1: Image           Distroless base, no shell, no package manager, non-root
Layer 2: Build           Multi-stage build, pinned digests, SBOM, signed image
Layer 3: Admission       Kyverno/OPA: reject non-compliant workloads at deploy time
Layer 4: Pod Security    seccomp, AppArmor, no privileged, readOnlyRootFilesystem
Layer 5: Runtime         Falco: detect anomalies during execution (unexpected syscalls)
Layer 6: Kernel          gVisor/Kata: isolate container kernel calls from host kernel
Layer 7: Network         NetworkPolicy, Cilium L7, mTLS: limit lateral movement
```
Each layer fails independently. A supply-chain breach bypasses layer 1 but not layers 3–7.

### Container Threat Model
| Threat | Attack vector | Primary control |
|---|---|---|
| **Escape to host** | Privileged container, kernel exploit | gVisor/Kata, no `privileged`, seccomp, Falco |
| **Lateral movement** | Compromised container attacks peers | NetworkPolicy, Falco network rules, mTLS |
| **Data exfiltration** | Outbound data transfer after compromise | Egress NetworkPolicy, Falco network events |
| **Credential theft** | Reading mounted secrets, env vars | Read-only FS, vault agent file mounts, Falco file rules |
| **Privilege escalation** | `sudo`, setuid binaries, capability abuse | `no_new_privs`, drop ALL caps, seccomp, Falco |
| **Malicious process spawn** | Shell spawned from web app (`sh -c`) | Falco process rules, `readOnlyRootFilesystem` |
| **Image tampering** | Pulling unverified or mutated image | Kyverno `verifyImages`, cosign, image digest pinning |

### Seccomp — System Call Filtering
A container's attack surface is the set of syscalls it can make to the kernel. Seccomp (Secure Computing Mode) restricts which syscalls a process may invoke. An unexpected syscall triggers SCMP_ACT_KILL_PROCESS (crash) or SCMP_ACT_ERRNO (error).

```
Default Docker seccomp profile: blocks ~44 of ~350+ syscalls
RuntimeDefault (Kubernetes): similar to Docker default
Custom profile:  blocks all except ~20 syscalls your app actually needs (smallest surface)
```

### Pod Security Standards (Kubernetes 1.25+)
Three built-in policy levels enforced via namespace labels:
| Level | What it blocks |
|---|---|
| `privileged` | Nothing blocked (disable for system namespaces only) |
| `baseline` | Blocks `privileged`, `hostNetwork`, `hostPID`, most dangerous capabilities |
| `restricted` | Everything in baseline + requires non-root, drop ALL caps, seccomp RuntimeDefault, read-only root FS |

Apply at namespace level:
```yaml
labels:
  pod-security.kubernetes.io/enforce: restricted
  pod-security.kubernetes.io/enforce-version: v1.30
```

### gVisor vs Kata Containers
| Dimension | gVisor (runsc) | Kata Containers |
|---|---|---|
| Isolation mechanism | User-space kernel (Go) intercepts syscalls | Lightweight VM (QEMU/Firecracker) |
| Overhead | ~10–15% CPU overhead | ~5–15% slower startup; near-native throughput |
| Kernel attack surface | Eliminated (syscalls never reach host kernel) | Eliminated (separate guest kernel) |
| Compatibility | ~95% of syscalls; some edge cases | Near 100% (real kernel) |
| Best for | Multi-tenant SaaS, untrusted code execution | Regulated workloads needing full kernel, stronger compliance |

---

## Implementation Patterns

### 1. Falco Rule Authoring
Falco watches syscall events and Kubernetes audit logs in real time. Rules are composed of a condition (boolean expression) and an output (alert message). Rules ship as `FalcoRules` Helm values or CRDs via Falco Operator.

### 2. Kyverno Admission Policies
Kyverno intercepts Kubernetes admission webhooks. `ClusterPolicy` can validate (reject non-compliant), mutate (auto-fix spec), and generate (create companion resources). Preferred over OPA Gatekeeper for Kubernetes-native teams (no Rego).

### 3. gVisor RuntimeClass
Add `RuntimeClass: gvisor` to a Pod spec. Kubernetes schedules the pod to a node where containerd uses `runsc` instead of `runc`. The gVisor kernel (Sentry) handles all syscalls in user space.

### 4. Seccomp Profile Generation
Use `inspektor-gadget seccomp-advisor` or `docker run --security-opt seccomp=unconfined` + `ausyscall` to record the actual syscalls an application makes, then generate a minimal allowlist profile.

### 5. Image Hardening
Distroless images contain only the runtime (JVM, Go binary) and CA certs — no shell, no package manager. Combined with a multi-stage build, the attack surface shrinks dramatically.

### 6. CIS Kubernetes Benchmark
The CIS benchmark provides 100+ controls. Run `kube-bench` to audit the cluster and nodes automatically. Feed results into a Prometheus exporter or SIEM.

---

## Anti-Patterns

| Anti-Pattern | Why It Fails | Correction |
|---|---|---|
| **`privileged: true`** | Container has full root access to host kernel | Never; use specific capabilities instead (e.g., `NET_BIND_SERVICE`) |
| **Running as root (UID 0)** | Root inside container = root on host if escape occurs | `runAsNonRoot: true` + `runAsUser: 65534` (nobody) |
| **`allowPrivilegeEscalation: true`** | `sudo`, setuid binaries can elevate to root | Always `allowPrivilegeEscalation: false` |
| **No `readOnlyRootFilesystem`** | Attacker can write malware to filesystem after initial breach | `readOnlyRootFilesystem: true`; mount `emptyDir` for `/tmp` |
| **`hostPID: true` or `hostNetwork: true`** | Container sees host process list / network namespace | Never in production; system components only |
| **No seccomp profile** | Full syscall surface exposed to kernel | `seccompProfile: {type: RuntimeDefault}` minimum |
| **`CAP_SYS_ADMIN` granted** | Near-equivalent to root; can mount filesystems, modify kernel | Drop ALL caps; add back only what's needed (`NET_BIND_SERVICE` max) |
| **Falco rules with no alert routing** | Events detected but never seen | Falco → Falcosidekick → Slack/PagerDuty/SIEM |
| **Admission policies in `audit` mode forever** | Violations logged but workloads not blocked | Start in `audit`, fix violations within sprint, switch to `enforce` |
| **Distroless without non-root user** | Distroless reduces attack surface but doesn't prevent root execution | `USER nonroot` in Dockerfile OR `runAsUser: 65532` in Pod spec |

---

## Code Templates

### Template 1 — Falco Rules (Syscall + K8s Audit)

```yaml
# falco/custom-rules.yaml
customRules:
  payments-security.yaml: |-

    # Rule 1: Shell spawned inside a container (common post-exploit action)
    - rule: Shell Spawned in Container
      desc: >
        Detects execution of a shell binary inside a container.
        Legitimate apps should not spawn sh/bash/zsh at runtime.
      condition: >
        spawned_process
        and container
        and not container.image.repository in (allowed_shell_images)
        and proc.name in (shell_binaries)
      output: >
        Shell spawned in container
        (user=%user.name user_loginuid=%user.loginuid
         container=%container.name image=%container.image.repository
         shell=%proc.name parent=%proc.pname cmdline=%proc.cmdline
         pid=%proc.pid evt=%evt.type)
      priority: CRITICAL
      tags: [container, shell, T1059]

    # Rule 2: Unexpected outbound network connection
    - rule: Unexpected Outbound Connection
      desc: Detects connections to external IPs not in the allowed list
      condition: >
        outbound
        and container
        and not fd.sip in (allowed_internal_cidrs)
        and not container.image.repository in (allowed_outbound_images)
      output: >
        Unexpected outbound connection
        (container=%container.name image=%container.image.repository
         dst_ip=%fd.rip dst_port=%fd.rport proto=%fd.l4proto
         proc=%proc.name pid=%proc.pid)
      priority: WARNING
      tags: [network, exfiltration, T1041]

    # Rule 3: Sensitive file read (credentials, keys)
    - rule: Sensitive File Read in Container
      desc: Detects reads of known credential files inside containers
      condition: >
        open_read
        and container
        and fd.name pmatch (/etc/shadow, /root/.ssh/*, /proc/*/environ, /var/run/secrets/*)
        and not proc.name in (allowed_secret_readers)
      output: >
        Sensitive file opened for reading
        (file=%fd.name container=%container.name image=%container.image.repository
         proc=%proc.name user=%user.name pid=%proc.pid)
      priority: HIGH
      tags: [filesystem, credentials, T1552]

    # Rule 4: Kubernetes API server access from unexpected process
    - rule: K8s API Access from Unexpected Process
      desc: Process other than kubectl/helm/operator accessing the K8s API
      condition: >
        outbound
        and container
        and fd.rport = 6443
        and not proc.name in (k8s_client_binaries)
        and not container.image.repository startswith "k8s.gcr.io"
      output: >
        Unexpected K8s API access
        (container=%container.name proc=%proc.name pid=%proc.pid
         image=%container.image.repository)
      priority: HIGH
      tags: [k8s, lateral-movement, T1613]

    # Rule 5: Kubernetes audit — exec into pod (suspicious in production)
    - rule: Exec into Production Pod
      desc: kubectl exec used on a production namespace pod
      condition: >
        ka.verb=create
        and ka.target.resource=pods/exec
        and ka.target.namespace in (prod_namespaces)
      output: >
        kubectl exec on production pod
        (user=%ka.user.name pod=%ka.target.name namespace=%ka.target.namespace
         container=%ka.req.pod.containers.image)
      priority: WARNING
      source: k8s_audit
      tags: [k8s-audit, T1609]

    # Macros and lists
    - macro: shell_binaries
      condition: proc.name in (sh, bash, zsh, dash, fish, ksh, csh, tcsh)

    - list: allowed_shell_images
      items: [debug-tools, busybox-utils]  # images where shells are expected

    - list: allowed_internal_cidrs
      items: ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]

    - list: prod_namespaces
      items: [payments, fraud, notifications, checkout]

    - list: k8s_client_binaries
      items: [kubectl, helm, argocd, flux]

    - list: allowed_secret_readers
      items: [vault-agent, external-secrets]
```

```yaml
# falco/falcosidekick-config.yaml — route alerts to Slack and PagerDuty
config:
  slack:
    webhookurl: ""    # injected via ESO
    channel: "#security-alerts"
    minimumpriority: "warning"
    messageformat: |
      *[Falco Alert]* `{{ .Rule }}`
      *Priority:* `{{ .Priority }}`
      *Container:* `{{ index .OutputFields "container.name" }}`
      *Image:* `{{ index .OutputFields "container.image.repository" }}`
      *Details:* {{ .Output }}

  pagerduty:
    routingkey: ""   # injected via ESO
    minimumpriority: "critical"

  prometheus:
    extralabelsList:
      - rule
      - priority
      - k8s.pod.name
      - k8s.ns.name
```

---

### Template 2 — Kyverno Admission Policies (Pod Security + Image Verification)

```yaml
# kyverno/require-pod-security.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-pod-security-controls
  annotations:
    policies.kyverno.io/title: Require Pod Security Controls
    policies.kyverno.io/description: >
      Enforces restricted Pod Security Standard controls on all workloads.
      Exceptions require explicit annotation and Security team approval.
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: no-privileged
      match:
        any:
          - resources:
              kinds: [Pod]
              namespaces: ["*"]
      exclude:
        any:
          - resources:
              namespaces: [kube-system, karpenter, falco]
      validate:
        message: "Privileged containers are not permitted."
        pattern:
          spec:
            containers:
              - =(securityContext):
                  =(privileged): "false"

    - name: require-non-root
      match:
        any:
          - resources:
              kinds: [Pod]
      exclude:
        any:
          - resources:
              namespaces: [kube-system, karpenter]
      validate:
        message: "Containers must run as non-root. Set runAsNonRoot: true."
        pattern:
          spec:
            securityContext:
              runAsNonRoot: true
            containers:
              - securityContext:
                  allowPrivilegeEscalation: false

    - name: require-readonly-root-fs
      match:
        any:
          - resources:
              kinds: [Pod]
      exclude:
        any:
          - resources:
              namespaces: [kube-system]
      validate:
        message: "Container root filesystem must be read-only."
        pattern:
          spec:
            containers:
              - securityContext:
                  readOnlyRootFilesystem: true

    - name: require-seccomp
      match:
        any:
          - resources:
              kinds: [Pod]
      exclude:
        any:
          - resources:
              namespaces: [kube-system, karpenter]
      validate:
        message: "Pods must use RuntimeDefault or custom seccomp profile."
        anyPattern:
          - spec:
              securityContext:
                seccompProfile:
                  type: RuntimeDefault
          - spec:
              securityContext:
                seccompProfile:
                  type: Localhost

    - name: drop-all-capabilities
      match:
        any:
          - resources:
              kinds: [Pod]
      exclude:
        any:
          - resources:
              namespaces: [kube-system]
      validate:
        message: "All Linux capabilities must be dropped. Add back only what is necessary."
        pattern:
          spec:
            containers:
              - securityContext:
                  capabilities:
                    drop:
                      - ALL
---
# kyverno/verify-images.yaml — reject unverified images (see supply-chain-security skill)
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-image-signatures
spec:
  validationFailureAction: Enforce
  background: false
  rules:
    - name: check-image-signature
      match:
        any:
          - resources:
              kinds: [Pod]
      exclude:
        any:
          - resources:
              namespaces: [kube-system, karpenter]
      verifyImages:
        - imageReferences:
            - "ghcr.io/org/*"
          attestors:
            - entries:
                - keyless:
                    subject: "https://github.com/org/*/.github/workflows/*.yml@refs/heads/main"
                    issuer: "https://token.actions.githubusercontent.com"
          mutateDigest: true       # replace tag with digest for immutability
          verifyDigest: true
---
# kyverno/mutate-add-seccomp.yaml — auto-add seccomp if missing (mutation)
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: add-default-seccomp
spec:
  rules:
    - name: add-seccomp-profile
      match:
        any:
          - resources:
              kinds: [Pod]
      exclude:
        any:
          - resources:
              namespaces: [kube-system]
      mutate:
        patchStrategicMerge:
          spec:
            securityContext:
              +(seccompProfile):
                type: RuntimeDefault
```

---

### Template 3 — gVisor RuntimeClass + Kata Containers

```yaml
# runtime-classes.yaml
---
# gVisor: user-space kernel; good for untrusted/multi-tenant workloads
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: gvisor
handler: runsc            # containerd shim name for gVisor
scheduling:
  nodeSelector:
    sandbox: gvisor       # only schedule on nodes with gVisor installed
  tolerations:
    - key: sandbox
      operator: Equal
      value: gvisor
      effect: NoSchedule
overhead:
  podFixed:
    memory: "64Mi"        # gVisor memory overhead per pod
    cpu: "100m"
---
# Kata Containers: lightweight VM; strongest isolation
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: kata-fc           # Firecracker-backed Kata (fastest VM startup)
handler: kata-fc
scheduling:
  nodeSelector:
    sandbox: kata
overhead:
  podFixed:
    memory: "128Mi"
    cpu: "250m"
```

```yaml
# Pod using gVisor sandbox
apiVersion: v1
kind: Pod
metadata:
  name: untrusted-workload
  namespace: sandbox
spec:
  runtimeClassName: gvisor    # ← selects runsc instead of runc
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: app
      image: ghcr.io/org/user-code-runner:latest@sha256:abc123...
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: [ALL]
      resources:
        requests: { cpu: 200m, memory: 256Mi }
        limits:   { memory: 512Mi }
```

---

### Template 4 — Seccomp Profile Generation + Custom Profile

```bash
#!/bin/bash
# scripts/generate-seccomp-profile.sh
# Records actual syscalls made by a container and generates a minimal allowlist profile.
# Requires: inspektor-gadget installed on the cluster

SERVICE=${1:?Usage: generate-seccomp-profile.sh <service-name> <namespace>}
NS=${2:-default}
DURATION=${3:-120}   # seconds to observe

echo "Recording syscalls for $SERVICE in $NS for ${DURATION}s..."

# Use inspektor-gadget seccomp advisor
kubectl gadget advise seccomp-profile \
  --podname "$SERVICE" \
  --namespace "$NS" \
  --timeout "${DURATION}s" \
  --output json > "seccomp-profile-${SERVICE}.json"

echo "Generated: seccomp-profile-${SERVICE}.json"
echo "Review and apply as a Kubernetes SeccompProfile or mount as a local profile."
```

```json
// seccomp-profiles/payments-service.json
// Generated by inspektor-gadget; manually reviewed and tightened
{
  "defaultAction": "SCMP_ACT_ERRNO",
  "architectures": ["SCMP_ARCH_X86_64"],
  "syscalls": [
    {
      "names": [
        "accept4", "bind", "clock_gettime", "close", "connect",
        "epoll_create1", "epoll_ctl", "epoll_wait",
        "exit", "exit_group",
        "fcntl", "fstat", "futex",
        "getdents64", "getpid", "getsockopt",
        "listen", "madvise", "mmap", "mprotect", "munmap",
        "nanosleep", "open", "openat",
        "read", "recvfrom", "recvmsg",
        "rt_sigaction", "rt_sigprocmask", "rt_sigreturn",
        "sched_yield",
        "sendmsg", "sendto", "setsockopt", "shutdown",
        "sigaltstack", "socket", "stat",
        "tgkill", "uname",
        "write", "writev"
      ],
      "action": "SCMP_ACT_ALLOW"
    }
  ]
}
```

```yaml
# Apply as Kubernetes SeccompProfile CRD (requires Security Profiles Operator)
apiVersion: security-profiles-operator.x-k8s.io/v1beta1
kind: SeccompProfile
metadata:
  name: payments-service
  namespace: payments
spec:
  defaultAction: SCMP_ACT_ERRNO
  syscalls:
    - action: SCMP_ACT_ALLOW
      names:
        - accept4
        - bind
        - clock_gettime
        - close
        - connect
        - epoll_create1
        - epoll_ctl
        - epoll_wait
        - exit_group
        - fcntl
        - fstat
        - futex
        - getpid
        - listen
        - madvise
        - mmap
        - mprotect
        - munmap
        - nanosleep
        - openat
        - read
        - recvfrom
        - recvmsg
        - rt_sigaction
        - rt_sigprocmask
        - rt_sigreturn
        - sched_yield
        - sendmsg
        - sendto
        - setsockopt
        - socket
        - tgkill
        - write
        - writev
```

---

### Template 5 — Distroless Image + Hardened Dockerfile

```dockerfile
# Dockerfile — multi-stage build with distroless final image

# Stage 1: build
FROM golang:1.22-alpine AS builder
WORKDIR /build
COPY go.mod go.sum ./
RUN go mod download
COPY . .
# CGO_ENABLED=0: static binary (no libc dep); -ldflags strip debug info
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -ldflags="-s -w -extldflags=-static" \
    -trimpath \
    -o /payments-service ./cmd/payments

# Stage 2: verify binary is static
RUN file /payments-service | grep "statically linked"

# Stage 3: distroless final image
# gcr.io/distroless/static-debian12: ~2 MB; no shell, no package manager
# :nonroot tag: runs as UID 65532 (nonroot) by default
FROM gcr.io/distroless/static-debian12:nonroot AS final

# Copy CA certs (already in distroless)
# Copy binary only
COPY --from=builder --chown=nonroot:nonroot /payments-service /payments-service

# Distroless nonroot image already sets USER nonroot
# Explicitly set for clarity and to document intent
USER nonroot:nonroot

EXPOSE 8080 9090

ENTRYPOINT ["/payments-service"]
```

```yaml
# kubernetes/pod-security-context.yaml — full hardened security context
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payments-service
  namespace: payments
spec:
  template:
    spec:
      # Pod-level security
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532              # nonroot user from distroless
        runAsGroup: 65532
        fsGroup: 65532
        seccompProfile:
          type: RuntimeDefault        # or Localhost with custom profile name
        supplementalGroups: []

      # No service account token automount (use explicit ESO secrets instead)
      automountServiceAccountToken: false

      containers:
        - name: payments
          image: ghcr.io/org/payments-service@sha256:abc123...  # digest-pinned
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            runAsUser: 65532
            capabilities:
              drop: [ALL]
              # add: [NET_BIND_SERVICE]   # only if binding port < 1024
          volumeMounts:
            - name: tmp
              mountPath: /tmp
            - name: cache
              mountPath: /app/cache

      volumes:
        - name: tmp
          emptyDir: {}
        - name: cache
          emptyDir:
            sizeLimit: 100Mi
```

---

### Template 6 — CIS Benchmark Audit + NeuVector Network Policy

```bash
#!/bin/bash
# scripts/cis-benchmark.sh — run kube-bench and export results

# Run kube-bench as a Kubernetes Job (runs on each node type)
kubectl apply -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: kube-bench
  namespace: security
spec:
  template:
    spec:
      hostPID: true
      nodeSelector:
        node-role.kubernetes.io/control-plane: ""
      tolerations:
        - key: node-role.kubernetes.io/control-plane
          effect: NoSchedule
      restartPolicy: Never
      containers:
        - name: kube-bench
          image: aquasec/kube-bench:v0.7.3
          command: ["kube-bench", "run", "--targets", "master", "--json"]
          volumeMounts:
            - name: var-lib-kubelet
              mountPath: /var/lib/kubelet
              readOnly: true
            - name: etc-kubernetes
              mountPath: /etc/kubernetes
              readOnly: true
      volumes:
        - name: var-lib-kubelet
          hostPath: { path: /var/lib/kubelet }
        - name: etc-kubernetes
          hostPath: { path: /etc/kubernetes }
EOF

# Wait for completion and extract results
kubectl wait --for=condition=complete job/kube-bench -n security --timeout=120s
kubectl logs -n security job/kube-bench | jq '.Controls[] | {id: .id, text: .text, fail: [.tests[].results[] | select(.status == "FAIL")]}'
```

```yaml
# neuvector/network-rule.yaml — NeuVector application-layer network policy
# NeuVector provides L7 process-level network rules beyond Kubernetes NetworkPolicy
apiVersion: neuvector.com/v1
kind: NvNetworkRule
metadata:
  name: payments-network-rules
  namespace: payments
spec:
  selector:
    app: payments-service
  ingress:
    - selector:
        app: api-gateway
      ports:
        - port: 8080
          protocol: TCP
      action: Allow
  egress:
    - selector:
        app: postgres
      ports:
        - port: 5432
          protocol: TCP
      action: Allow
    - selector:
        app: redis
      ports:
        - port: 6379
          protocol: TCP
      action: Allow
    - cidr: "0.0.0.0/0"    # External: block by default; allow only specific egress
      ports:
        - port: 443
          protocol: TCP
      action: Allow         # Allow HTTPS only for third-party API calls
  processRules:
    - name: "payments-service"
      action: Allow
    - name: "*"             # Block any unexpected process
      action: Deny
```

```yaml
# prometheus/container-security-alerts.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: container-security-alerts
  namespace: monitoring
spec:
  groups:
    - name: container.security
      rules:
        # Falco critical events
        - alert: FalcoCriticalAlert
          expr: increase(falco_events_total{priority="Critical"}[5m]) > 0
          labels:
            severity: critical
          annotations:
            summary: "Falco CRITICAL event: {{ $labels.rule }}"

        # Privileged container running (should never happen with Kyverno enforcing)
        - alert: PrivilegedContainerRunning
          expr: |
            kube_pod_container_info * on(pod, namespace) group_left()
            kube_pod_spec_containers_security_context_privileged == 1
          labels:
            severity: critical
          annotations:
            summary: "Privileged container running: {{ $labels.pod }}/{{ $labels.container }}"

        # Container running as root
        - alert: ContainerRunningAsRoot
          expr: |
            kube_pod_container_status_running == 1
            unless on(pod, namespace, container)
            kube_pod_container_info * on(pod, namespace) group_left()
            (kube_pod_spec_containers_security_context_run_as_non_root == 1)
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Container may be running as root: {{ $labels.namespace }}/{{ $labels.pod }}"

        # Image without digest (mutable tag in use)
        - alert: MutableImageTagInUse
          expr: |
            kube_pod_container_info{image!~".*@sha256:.*"} == 1
          for: 1h
          labels:
            severity: warning
          annotations:
            summary: "Pod using mutable image tag (no digest): {{ $labels.namespace }}/{{ $labels.pod }}"
```

---

## Decision Matrix

| Scenario | Recommendation | Rationale |
|---|---|---|
| Multi-tenant SaaS (users run arbitrary code) | gVisor (`runsc`) runtime class | User-space kernel eliminates host kernel attack surface |
| Regulated workload (PCI, HIPAA) requiring VM isolation | Kata Containers (Firecracker) | Hardware VM boundary; real Linux kernel; audit-friendly |
| Standard production workload | Pod Security Standards (restricted) + RuntimeDefault seccomp | Good baseline; no extra infrastructure |
| Detect post-exploitation in real time | Falco with shell-spawn + outbound connection rules | Syscall-level detection; catches exploits that bypass admission |
| Prevent misconfigured workloads from deploying | Kyverno `Enforce` mode policies | Admission-time gate; fail fast before workload runs |
| Tightest seccomp surface | Custom SeccompProfile from inspektor-gadget recording | Minimal syscall set; kills any unexpected syscall immediately |
| Shrink container image attack surface | Distroless base + static binary + digest pin | No shell, no package manager; < 5 MB final image |
| Audit cluster against CIS benchmark | `kube-bench` as a Kubernetes Job | Automated; maps to CIS controls; CI-integrable |
| L7 process-level network control | NeuVector process rules | Blocks unexpected processes making network calls; beyond NetworkPolicy |
| Secrets in running container (env var exposure) | Vault Agent file mount + `readOnlyRootFilesystem` | Secrets as files, not env vars; Falco rule on `/proc/*/environ` reads |

---

## Proficiency Levels

### Level 1 — Aware
- Understands why running as root in a container is dangerous (escape risk)
- Knows what `privileged: true` means and that it should never be used in production
- Can read a Kyverno policy and understand what it blocks
- Knows Falco detects runtime anomalies via syscall monitoring

### Level 2 — Practitioner
- Applies Pod Security Standards (`restricted`) to namespaces via labels
- Writes Kyverno `ClusterPolicy` to enforce non-root, `readOnlyRootFilesystem`, and capability drops
- Creates Dockerfiles with distroless base images and non-root user
- Configures RuntimeDefault seccomp profile on all pods
- Deploys Falco with built-in rules and routes alerts to Slack via Falcosidekick

### Level 3 — Advanced
- Authors custom Falco rules for application-specific anomalies (unexpected processes, file reads, outbound connections)
- Generates minimal custom seccomp profiles from actual syscall recordings (inspektor-gadget)
- Configures `RuntimeClass` for gVisor or Kata Containers and schedules sensitive workloads accordingly
- Runs `kube-bench` in CI and tracks CIS benchmark pass rates over time
- Implements Kyverno mutation policies to auto-add seccomp profile if absent; verify image signatures

### Level 4 — Expert
- Designs defence-in-depth container security architecture across all 7 layers
- Operates Falco at scale: custom rule libraries, alert correlation, false-positive tuning, performance impact management
- Tunes seccomp profiles for high-performance services (avoid SIGSYS overhead on hot paths)
- Integrates NeuVector or Cilium Tetragon for process-level network policy enforcement
- Runs red-team container escape exercises; validates detection coverage with Falco alert mapping to MITRE ATT&CK

---

## AI Prompts

**Write Falco rules for an application**
```
Write Falco rules for a [web app / ML inference service / data pipeline] that detect:
1. Shell spawned inside the container
2. Unexpected outbound connections to external IPs (allowlist: [internal CIDR ranges])
3. Reads of sensitive files: /proc/*/environ, /var/run/secrets/*, /etc/shadow
4. Unexpected process spawned (only [process names] are expected)
5. kubectl exec into the pod's namespace in production

For each rule: condition, output with useful fields (container, process, file, IP),
priority, and MITRE ATT&CK tag.
Also write the Falcosidekick config to route CRITICAL to PagerDuty and WARNING to Slack.
```

**Harden a Kubernetes Deployment**
```
Review and harden this Kubernetes Deployment for a production environment:
[paste Deployment YAML]

Apply all restricted Pod Security Standard controls:
- runAsNonRoot, runAsUser (use distroless UID if distroless image)
- allowPrivilegeEscalation: false
- readOnlyRootFilesystem: true; add emptyDir volumes where needed
- capabilities: drop ALL; add back only [list needed capabilities]
- seccompProfile: RuntimeDefault
- automountServiceAccountToken: false (if service account not needed)
- Image: replace tag with digest

Output: hardened Deployment YAML with inline comments explaining each change.
```

**Generate a Kyverno policy**
```
Write a Kyverno ClusterPolicy that [validates / mutates / generates]:
[describe the policy goal — e.g., "all Deployments must have resource limits",
"auto-add cost labels if missing", "reject images from non-org registries"]

Include:
- validationFailureAction: Enforce (not audit — explain when to use audit first)
- Appropriate match/exclude for system namespaces (kube-system, karpenter, etc.)
- A meaningful error message
- Test: how to verify the policy works with kubectl dry-run or kyverno test
```

**Design a container image hardening standard**
```
Define a container image hardening standard for our organisation covering:
1. Base image selection (distroless vs alpine vs ubi-minimal — trade-offs)
2. Multi-stage build requirements
3. Non-root user requirement (Dockerfile USER + Pod securityContext)
4. Image digest pinning in Kubernetes manifests
5. SBOM generation and attestation (Syft + cosign)
6. Vulnerability scanning gate in CI (Trivy severity threshold)
7. Image signing (keyless cosign)
8. Registry: only pull from [internal registry / GHCR / ECR]

Output: Dockerfile template, Kyverno policy, and CI workflow snippet.
```

---

## References

- **Falco documentation** — `falco.org/docs` — rules, conditions, output, plugins, Falcosidekick
- **Falco rules library** — `github.com/falcosecurity/rules` — community rule sets
- **Kyverno documentation** — `kyverno.io/docs` — policies, mutation, generation, image verification
- **gVisor documentation** — `gvisor.dev/docs` — RuntimeClass, containerd shim, compatibility
- **Kata Containers** — `katacontainers.io` — Firecracker/QEMU backends, RuntimeClass
- **Pod Security Standards** — `kubernetes.io/docs/concepts/security/pod-security-standards`
- **Security Profiles Operator** — `github.com/kubernetes-sigs/security-profiles-operator` — SeccompProfile CRD
- **inspektor-gadget** — `inspektor-gadget.io` — syscall recording for seccomp profile generation
- **CIS Kubernetes Benchmark** — `cisecurity.org` — control framework; kube-bench automates checks
- **kube-bench** — `github.com/aquasecurity/kube-bench` — CIS benchmark auditing tool
- **NeuVector** — `neuvector.com` — L7 container network security, process-level policy
- **Cilium Tetragon** — `tetragon.io` — eBPF-based security observability and enforcement
- **Distroless images** — `github.com/GoogleContainerTools/distroless` — minimal base images
- **MITRE ATT&CK for Containers** — `attack.mitre.org/matrices/enterprise/containers` — threat taxonomy
