---
name: eBPF Observability
slug: ebpf-observability
category: 10-specialized-domains
proficiency: advanced
description: >
  Use eBPF to build zero-instrumentation observability for Kubernetes
  workloads. Covers eBPF fundamentals, Cilium network visibility and
  policy enforcement, Tetragon runtime security tracing, Pixie
  auto-instrumentation for golden-signal metrics and distributed traces,
  custom eBPF programs with libbpf/Go, and performance profiling with
  BPF-based tools.
tags:
  - ebpf
  - cilium
  - tetragon
  - pixie
  - observability
  - network-visibility
  - runtime-security
  - zero-instrumentation
  - kubernetes
status: published
---

## Principles

### What eBPF Is
eBPF (extended Berkeley Packet Filter) is a Linux kernel technology that lets you run sandboxed programs inside the kernel without modifying kernel source or loading kernel modules. eBPF programs are:
- **Verified** by the kernel verifier before loading (memory safe, bounded execution)
- **JIT-compiled** to native machine code (near-zero overhead)
- **Event-driven** — triggered by kernel events: syscalls, tracepoints, kprobes, network packets, perf events

### Why eBPF Changes Observability
Traditional observability requires:
- Code instrumentation (language agents, SDK imports, compile-time changes)
- Sidecar containers or service mesh data planes
- Manual configuration per service

eBPF observability:
- **Zero application changes** — observes at kernel level; language-agnostic
- **Complete visibility** — sees all syscalls, all network traffic, all process events
- **Production-safe** — verified, bounded; no risk of kernel panic
- **Low overhead** — typically < 2% CPU overhead vs 10–15% for language agents

### eBPF Program Types and Use Cases

| Program Type | Kernel Hook | Use Case |
|-------------|-------------|----------|
| `kprobe/kretprobe` | Kernel function entry/exit | Trace syscall arguments and return values |
| `tracepoint` | Stable kernel tracepoints | Process lifecycle, scheduler events |
| `perf_event` | Hardware performance counters | CPU profiling, cache miss tracking |
| `XDP` | Network driver (early packet path) | High-performance packet filtering, DDoS mitigation |
| `TC` (traffic control) | Kernel network stack | Load balancing, network policy |
| `socket` | Socket operations | Service mesh, transparent proxy |
| `LSM` | Linux Security Module hooks | Runtime security enforcement |

### eBPF Data Structures

| Structure | Purpose |
|-----------|---------|
| **Maps** | Shared memory between eBPF programs and userspace (hash, array, ring buffer) |
| **Ring buffer** | High-throughput event streaming from kernel to userspace |
| **Perf buffer** | Per-CPU event buffer (older; ring buffer preferred) |
| **BTF** (BPF Type Format) | Kernel type information for portable eBPF programs |

---

## Implementation Patterns

### Pattern 1 — Cilium: Network Policy and Visibility
```yaml
# Install Cilium with Hubble observability enabled

# cilium/values.yaml (Helm)
cilium:
  hubble:
    enabled: true
    relay:
      enabled: true
    ui:
      enabled: true
    metrics:
      enabled:
        - dns
        - drop
        - tcp
        - flow
        - icmp
        - http
      serviceMonitor:
        enabled: true   # Prometheus scraping

  # Replace kube-proxy with eBPF-based implementation
  kubeProxyReplacement: strict
  k8sServiceHost: "<api-server-host>"
  k8sServicePort: 6443

  # Enable bandwidth manager (eBPF-based QoS)
  bandwidthManager:
    enabled: true
    bbr: true   # BBR congestion control

  # Enable native routing (skip tunnel overhead)
  tunnel: disabled
  autoDirectNodeRoutes: true

---
# CiliumNetworkPolicy — L7-aware (HTTP method + path)
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: payments-ingress-policy
  namespace: payments
spec:
  endpointSelector:
    matchLabels:
      app: payments-service

  ingress:
    # Allow from order-service: only POST /payments and GET /payments/*
    - fromEndpoints:
        - matchLabels:
            app: orders-service
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
          rules:
            http:
              - method: POST
                path: /payments
              - method: GET
                path: /payments/.*
              - method: POST
                path: /payments/.*/capture

    # Allow from monitoring: only GET /metrics
    - fromEndpoints:
        - matchLabels:
            app: prometheus
      toPorts:
        - ports:
            - port: "8080"
          rules:
            http:
              - method: GET
                path: /metrics

  egress:
    # Allow to PostgreSQL only
    - toEndpoints:
        - matchLabels:
            app: postgres
      toPorts:
        - ports:
            - port: "5432"
              protocol: TCP

    # Allow to Stripe API (FQDN-based policy)
    - toFQDNs:
        - matchName: api.stripe.com
      toPorts:
        - ports:
            - port: "443"
              protocol: TCP
```

```bash
# Hubble CLI — observe live flows with L7 visibility

# Watch all HTTP traffic to/from payments-service
hubble observe \
  --namespace payments \
  --label app=payments-service \
  --type l7 \
  --protocol http \
  --follow

# Output:
# Jul 19 10:23:01.234 [payments/payments-service] to-endpoint
#   orders-service:43212 -> payments-service:8080 POST /payments
#   200 OK 145ms

# Watch dropped flows (policy violations)
hubble observe \
  --namespace payments \
  --verdict DROPPED \
  --follow

# Generate flow metrics in Prometheus format
hubble observe \
  --namespace payments \
  --output json \
  | jq '.flow | {src: .source.labels, dst: .destination.labels, verdict: .verdict}'
```

### Pattern 2 — Tetragon Runtime Security Tracing
```yaml
# Tetragon TracingPolicy — detect and optionally kill suspicious processes

# Detect shell spawned inside a container (like Falco, but eBPF-native)
apiVersion: cilium.io/v1alpha1
kind: TracingPolicy
metadata:
  name: detect-shell-in-container
spec:
  kprobes:
    - call: "sys_execve"
      syscall: true
      args:
        - index: 0
          type: "string"    # filename being executed
      return: false
      selectors:
        # Only trigger for containerised processes (not host namespace)
        - matchNamespaces:
            - namespace: Pid
              operator: NotIn
              values:
                - "host_ns"
          matchArgs:
            - index: 0
              operator: Postfix
              values:
                - "/sh"
                - "/bash"
                - "/zsh"
                - "/dash"
          # Actions: Post (alert only) or Signal (kill the process)
          matchActions:
            - action: Post
              rateLimit: "1/minute"  # avoid flooding
            - action: Signal
              argError: SIGKILL   # SIGKILL if this is severity=critical context

---
# Detect sensitive file access
apiVersion: cilium.io/v1alpha1
kind: TracingPolicy
metadata:
  name: detect-sensitive-file-read
spec:
  kprobes:
    - call: "sys_openat"
      syscall: true
      args:
        - index: 1
          type: "string"    # file path
      selectors:
        - matchArgs:
            - index: 1
              operator: Prefix
              values:
                - "/etc/shadow"
                - "/etc/passwd"
                - "/etc/ssl/private"
                - "/run/secrets"
          matchActions:
            - action: Post

---
# Detect outbound network connections to unexpected destinations
apiVersion: cilium.io/v1alpha1
kind: TracingPolicy
metadata:
  name: detect-unexpected-outbound
spec:
  kprobes:
    - call: "tcp_connect"
      syscall: false
      args:
        - index: 0
          type: "sock"
      selectors:
        - matchArgs:
            - index: 0
              operator: NotDAddr
              values:
                - "10.0.0.0/8"      # cluster CIDR
                - "172.16.0.0/12"
                - "192.168.0.0/16"
          matchActions:
            - action: Post
```

```bash
# Monitor Tetragon events in real time
kubectl exec -n kube-system ds/tetragon -c tetragon -- \
  tetra getevents --output compact

# Filter to specific namespace
kubectl exec -n kube-system ds/tetragon -c tetragon -- \
  tetra getevents \
    --namespace payments \
    --output json \
  | jq '.process_exec | {pid: .process.pid, binary: .process.binary, pod: .process.pod.name}'
```

### Pattern 3 — Pixie Auto-Instrumentation (Golden Signals)
```yaml
# Pixie deploys eBPF probes automatically — no app changes required
# Captures HTTP/gRPC golden signals, DB queries, JVM metrics

# Install via Helm
helm install pixie pixie-operator/pixie-operator-chart \
  --namespace pl \
  --create-namespace \
  --set deployKey="${PIXIE_DEPLOY_KEY}" \
  --set clusterName="production"
```

```python
# px/scripts/http_golden_signals.pxl — PxL script for Pixie
# Run in Pixie UI or via CLI: px run -f http_golden_signals.pxl

import px

# Query last 5 minutes of HTTP data captured by eBPF
df = px.DataFrame(table='http_events', start_time='-5m')

# Filter to payments namespace
df = df[df.namespace == 'payments']

# Compute per-service golden signals
df.service = df.ctx['service']
df.latency_ms = df.resp_latency_ns / 1e6

# Error rate: 5xx responses
df.is_error = df.resp_status >= 500

# Aggregate by service
service_df = df.groupby(['service']).agg(
  request_rate=('latency_ms', px.count),
  error_rate=('is_error', px.mean),
  p50_latency=('latency_ms', px.quantiles(0.50)),
  p99_latency=('latency_ms', px.quantiles(0.99)),
)
service_df.request_rate = service_df.request_rate / 300  # requests per second over 5m

px.display(service_df, 'Golden Signals by Service')
```

```python
# px/scripts/db_query_latency.pxl — DB query monitoring without app instrumentation

import px

df = px.DataFrame(table='mysql_events', start_time='-10m')
df = df[df.namespace == 'payments']

# Identify slow queries
df.latency_ms = df.latency_ns / 1e6
df = df[df.latency_ms > 100]  # queries > 100ms

df = df.groupby(['req_body']).agg(
  count=('latency_ms', px.count),
  avg_ms=('latency_ms', px.mean),
  p99_ms=('latency_ms', px.quantiles(0.99)),
)
df = df.sort('p99_ms', descending=True)
px.display(df, 'Slow Queries (p99)')
```

### Pattern 4 — Custom eBPF Program with Go (libbpf + cilium/ebpf)
```go
// bpf/syscall_tracer.go — traces open() syscalls for a target PID
// Requires: github.com/cilium/ebpf

package main

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"

	"github.com/cilium/ebpf"
	"github.com/cilium/ebpf/link"
	"github.com/cilium/ebpf/ringbuf"
	"github.com/cilium/ebpf/rlimit"
)

// Event matches the C struct in the eBPF program
type OpenEvent struct {
	PID      uint32
	Filename [256]byte
}

func main() {
	// Remove memory lock limits (required for eBPF maps)
	if err := rlimit.RemoveMemlock(); err != nil {
		log.Fatalf("remove memlock: %v", err)
	}

	// Load pre-compiled eBPF objects (generated by bpf2go from C source)
	objs := tracerObjects{}
	if err := loadTracerObjects(&objs, nil); err != nil {
		log.Fatalf("load objects: %v", err)
	}
	defer objs.Close()

	// Attach the kprobe to sys_openat
	kp, err := link.Kprobe("sys_openat", objs.TracerPrograms.TraceOpenat, nil)
	if err != nil {
		log.Fatalf("attach kprobe: %v", err)
	}
	defer kp.Close()

	// Open the ring buffer map for reading events
	rd, err := ringbuf.NewReader(objs.TracerMaps.Events)
	if err != nil {
		log.Fatalf("open ringbuf: %v", err)
	}
	defer rd.Close()

	// Handle Ctrl+C
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)

	log.Println("Tracing openat syscalls... Press Ctrl+C to stop.")

	go func() {
		for {
			record, err := rd.Read()
			if err != nil {
				return
			}

			var event OpenEvent
			if err := binary.Read(bytes.NewBuffer(record.RawSample), binary.LittleEndian, &event); err != nil {
				log.Printf("parse event: %v", err)
				continue
			}

			filename := string(bytes.TrimRight(event.Filename[:], "\x00"))
			fmt.Printf("PID %d opened: %s\n", event.PID, filename)
		}
	}()

	<-stop
	log.Println("Detaching probes...")
}
```

```c
// bpf/tracer.c — the eBPF C program (compiled to BPF bytecode by bpf2go)

#include <linux/bpf.h>
#include <linux/ptrace.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>

struct open_event {
    __u32 pid;
    char  filename[256];
};

// Ring buffer map — high-throughput event delivery to userspace
struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, 1 << 24);  // 16MB ring buffer
} events SEC(".maps");

SEC("kprobe/sys_openat")
int trace_openat(struct pt_regs *ctx) {
    struct open_event *e;

    // Reserve space in the ring buffer
    e = bpf_ringbuf_reserve(&events, sizeof(*e), 0);
    if (!e) return 0;  // ring buffer full — drop event

    e->pid = bpf_get_current_pid_tgid() >> 32;

    // Read filename from userspace memory (second argument to openat)
    const char *filename = (const char *)PT_REGS_PARM2(ctx);
    bpf_probe_read_user_str(e->filename, sizeof(e->filename), filename);

    bpf_ringbuf_submit(e, 0);
    return 0;
}

char _license[] SEC("license") = "GPL";
```

### Pattern 5 — eBPF CPU Profiling with Parca (Continuous Profiling)
```yaml
# parca/agent-config.yaml — Parca agent for eBPF-based CPU profiling
# No language agent required — profiles all processes automatically

apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: parca-agent
  namespace: parca
spec:
  selector:
    matchLabels:
      app: parca-agent
  template:
    metadata:
      labels:
        app: parca-agent
    spec:
      hostPID: true       # needed to see all processes
      hostNetwork: true
      containers:
        - name: parca-agent
          image: ghcr.io/parca-dev/parca-agent:v0.31.0
          args:
            - --log-level=info
            - --node=$(NODE_NAME)
            - --remote-store-address=parca.parca.svc.cluster.local:7070
            - --remote-store-insecure
            - --http-address=:7071
            # Sampling rate — CPU overhead scales linearly
            - --sampling-ratio=0.1  # 10% sampling; adjust based on overhead tolerance
          securityContext:
            privileged: true   # required for eBPF program loading
          volumeMounts:
            - name: host-root
              mountPath: /host
              readOnly: true
      volumes:
        - name: host-root
          hostPath:
            path: /
      tolerations:
        - operator: Exists  # run on all nodes including control plane
```

### Pattern 6 — eBPF Metrics Pipeline to Prometheus
```yaml
# Cilium Hubble metrics → Prometheus → Grafana

# PrometheusRule: alert on high drop rate (policy violations)
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: cilium-network-alerts
  namespace: monitoring
spec:
  groups:
    - name: cilium.network
      rules:
        - alert: HighNetworkDropRate
          expr: |
            sum by (namespace, source, destination) (
              rate(hubble_drop_total[5m])
            ) > 10
          for: 2m
          labels:
            severity: warning
          annotations:
            summary: "High packet drop rate from {{ $labels.source }} to {{ $labels.destination }}"
            description: "{{ $value }} drops/second. Possible policy misconfiguration."

        - alert: UnexpectedEgressTraffic
          expr: |
            sum by (namespace, pod) (
              hubble_flows_processed_total{
                verdict="DROPPED",
                direction="egress"
              }
            ) > 0
          for: 1m
          labels:
            severity: warning
          annotations:
            summary: "Unexpected egress traffic blocked from {{ $labels.pod }}"

        - alert: TetragonCriticalEvent
          expr: |
            increase(tetragon_events_total{type="PROCESS_EXEC", binary=~".*(sh|bash|python|nc|ncat)"}[5m]) > 0
          for: 0m
          labels:
            severity: critical
          annotations:
            summary: "Shell/interpreter spawned in container {{ $labels.pod }}"
```

```go
// Custom eBPF exporter: expose kernel metrics as Prometheus gauge
// Reads from eBPF maps and exports to /metrics

package main

import (
	"log"
	"net/http"
	"time"

	"github.com/cilium/ebpf"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

var (
	syscallRate = promauto.NewGaugeVec(prometheus.GaugeOpts{
		Name: "ebpf_syscall_rate",
		Help: "Syscall rate per process per second",
	}, []string{"pid", "comm", "syscall"})
)

type SyscallKey struct {
	PID     uint32
	Syscall uint32
}

func main() {
	// Load eBPF objects (generated by bpf2go)
	objs := counterObjects{}
	if err := loadCounterObjects(&objs, nil); err != nil {
		log.Fatalf("load eBPF: %v", err)
	}
	defer objs.Close()

	// Scrape eBPF map every 15 seconds and export as Prometheus metrics
	go func() {
		for {
			var key SyscallKey
			var count uint64
			iter := objs.CounterMaps.SyscallCounts.Iterate()
			for iter.Next(&key, &count) {
				comm := getProcessComm(key.PID)
				syscallName := getSyscallName(key.Syscall)
				syscallRate.WithLabelValues(
					fmt.Sprintf("%d", key.PID),
					comm,
					syscallName,
				).Set(float64(count))
			}
			time.Sleep(15 * time.Second)
		}
	}()

	http.Handle("/metrics", promhttp.Handler())
	log.Fatal(http.ListenAndServe(":9090", nil))
}
```

---

## Anti-Patterns

### 1. Running eBPF Programs Without Memory Limits Configured
eBPF programs require elevated memory limits (`RLIMIT_MEMLOCK`). On older kernels without BPF memcg accounting, eBPF program loading silently fails with `EPERM`.

**Fix**: always call `rlimit.RemoveMemlock()` before loading eBPF objects (cilium/ebpf handles this), or use `BPF_MAP_TYPE_RINGBUF` which uses cgroup-aware memory accounting.

### 2. Privileged Containers for eBPF Without Scoping
Granting `--privileged` to an eBPF tool gives it full root access to the host. Operators set this and forget it.

**Fix**: use the minimum capabilities needed: `CAP_BPF`, `CAP_PERFMON`, `CAP_NET_ADMIN` for network eBPF. Use `hostPID: true` only if process observation is required.

### 3. Using eBPF Perf Buffers Instead of Ring Buffers
`BPF_MAP_TYPE_PERF_EVENT_ARRAY` (perf buffer) has per-CPU allocations and event loss under high throughput. `BPF_MAP_TYPE_RINGBUF` (Linux 5.8+) has global ordering and no loss under typical workloads.

**Fix**: use ring buffer for new programs. Perf buffer only if targeting kernels < 5.8.

### 4. eBPF Program That Blocks Indefinitely
eBPF programs are verified to terminate. Unbounded loops are rejected by the verifier. But programs with deep stack depth or complex pointer chasing can be slow.

**Fix**: the verifier enforces termination — trust it. Keep programs simple; offload complex processing to userspace. Use `bpf_loop()` helper (Linux 5.17+) for bounded iteration.

### 5. Deploying eBPF Tools Without Kernel Version Gate
eBPF features (ring buffer, BTF, CO-RE) require specific kernel versions. Deploying on incompatible kernels silently fails or crashes.

**Fix**: document minimum kernel requirements. Check at startup: `if err := features.HaveMapType(ebpf.RingBuf); err != nil { log.Fatal("kernel too old") }`.

---

## Decision Matrix

| Scenario | Recommendation |
|----------|---------------|
| Network policy with L7 visibility | Cilium + CiliumNetworkPolicy + Hubble |
| Runtime security (shell spawn, file access) | Tetragon TracingPolicy |
| Zero-instrumentation HTTP golden signals | Pixie auto-instrumentation |
| CPU profiling without language agent | Parca or Pyroscope with eBPF profiler |
| Custom kernel event tracing | cilium/ebpf library + Go userspace |
| Container network observability | Hubble CLI + Grafana dashboards |
| Replacing kube-proxy | Cilium kubeProxyReplacement=strict |
| DDoS mitigation at line rate | XDP program (drops before kernel stack) |
| Inter-service latency tracking | Pixie PxL scripts or Cilium Hubble |
| Audit syscalls for compliance | Tetragon + Falco for defense-in-depth |

---

## Proficiency Levels

### Novice
- Understands eBPF as a way to observe the Linux kernel without modifying it
- Can deploy Cilium and use Hubble to observe live network flows
- Knows the difference between kprobe, tracepoint, and XDP hooks

### Intermediate
- Writes Cilium L7 network policies and validates them with Hubble
- Deploys Tetragon TracingPolicies for runtime security events
- Uses Pixie PxL scripts to query HTTP golden signals without instrumentation
- Understands ring buffer vs perf buffer trade-offs

### Advanced
- Writes custom eBPF programs in C using libbpf, with Go userspace using cilium/ebpf
- Exports eBPF map data as Prometheus metrics
- Configures continuous profiling with Parca/Pyroscope across all cluster nodes
- Understands eBPF verifier constraints and BTF/CO-RE portability

### Expert
- Designs production eBPF tooling with kernel version compatibility gates
- Writes XDP programs for line-rate packet processing
- Implements custom eBPF-based service mesh data plane
- Contributes to or maintains eBPF projects (Cilium, Tetragon, bpftrace)
- Uses `bpftool` and `bpftrace` for ad-hoc kernel investigation in production

---

## AI Prompts

1. **Cilium policy design**: "I need to write a Cilium L7 network policy for my payments service. It should only accept POST /payments from the orders service and GET /metrics from Prometheus. Block all other ingress. Write the CiliumNetworkPolicy YAML."

2. **Tetragon rule**: "Write a Tetragon TracingPolicy that detects when a process inside a container opens a file matching `/run/secrets/*` and emits an alert. The policy should rate-limit to 1 alert per minute per pod."

3. **Custom eBPF program**: "Write a minimal eBPF C program that counts the number of times each process calls `write()` syscall, stores counts in a BPF hash map, and a Go program that reads the map every 10 seconds and prints the top 5 processes by write count."

4. **Pixie golden signals**: "Write a Pixie PxL script that shows the 5-minute golden signals (request rate, error rate, p50/p99 latency) for all services in the `payments` namespace, sorted by error rate descending."

5. **eBPF debugging**: "My Cilium pods show drop events for traffic from orders-service to payments-service. I expected this to be allowed by my CiliumNetworkPolicy. Walk me through how to diagnose the policy using Hubble CLI."

---

## References

- eBPF.io — official eBPF documentation and learning portal
- Cilium documentation — docs.cilium.io — network policy, Hubble, kubeproxy replacement
- Tetragon documentation — github.com/cilium/tetragon — runtime security
- Pixie documentation — docs.px.dev — auto-instrumentation, PxL scripting
- cilium/ebpf — github.com/cilium/ebpf — Go library for eBPF programs
- Parca — github.com/parca-dev/parca — continuous eBPF profiling
- Brendan Gregg — *BPF Performance Tools* (2019) — definitive eBPF performance reference
- Liz Rice — *Learning eBPF* (O'Reilly, 2023) — hands-on eBPF programming
- bpftrace — github.com/iovisor/bpftrace — ad-hoc eBPF scripting language
- Linux Kernel BPF Documentation — kernel.org/doc/html/latest/bpf
