---
name: Networking Internals
slug: networking-internals
category: 10-specialized-domains
proficiency: advanced
description: >
  Deep understanding of networking from TCP/IP fundamentals through
  Kubernetes networking, service mesh, and cloud VPC design. Covers
  TCP congestion control, DNS resolution, TLS handshake, Linux network
  stack, iptables/eBPF packet processing, Kubernetes CNI, Service/Ingress,
  mTLS with Istio, and cloud network topology for production workloads.
tags:
  - networking
  - tcp-ip
  - dns
  - tls
  - kubernetes-networking
  - cni
  - service-mesh
  - istio
  - vpc
  - iptables
status: published
---

## Principles

### The Networking Mental Model
Every network operation traverses layers. When something breaks, you trace top-down:
```
Application (HTTP, gRPC, DNS)
  ↓
Transport (TCP, UDP) — reliability, ordering, flow control
  ↓
Network (IP) — routing, addressing
  ↓
Data Link (Ethernet, Wi-Fi) — local delivery, MAC addresses
  ↓
Physical — cables, radio waves
```

In Kubernetes: add virtual layers between each:
```
Pod → veth pair → Linux bridge → iptables/eBPF → host NIC → physical network
```

### TCP: What Engineers Actually Need to Know

**Three-way handshake**: SYN → SYN-ACK → ACK. Adds one RTT before data flows. This is why connection reuse (keep-alive, connection pooling) matters.

**Congestion control**: TCP slows down when it detects packet loss (CUBIC, BBR). Under burst traffic, TCP backs off. This is why UDP is used for real-time applications.

**TIME_WAIT**: after closing a connection, the socket stays in TIME_WAIT for 2×MSL (typically 60s) to handle late packets. High-throughput services can exhaust ephemeral ports. Mitigate with `SO_REUSEADDR`, `TCP_TIMESTAMPS`, or connection pooling.

**Nagle's algorithm**: TCP batches small writes into fewer packets to reduce overhead. Causes 200ms delays for request-response patterns. Disable with `TCP_NODELAY` for low-latency applications (gRPC, Redis).

**Window size**: TCP receiver advertises how much data it can accept. Small window = throughput bottleneck over high-latency links. Tune with `tcp_rmem`/`tcp_wmem`.

### DNS: The Most Misunderstood Protocol

Every hostname lookup is a potential source of latency and failure:
1. Check local cache (OS resolver cache)
2. Check `/etc/hosts`
3. Query configured resolver (e.g., `8.8.8.8`)
4. Resolver queries root → TLD → authoritative nameserver

**TTL matters**: DNS responses have a TTL. Low TTL = fresh but chatty. High TTL = stale but cached. Kubernetes CoreDNS defaults: 30s for in-cluster, 5s for external.

**ndots**: Kubernetes sets `ndots:5` in Pod `/etc/resolv.conf`. A query for `api.stripe.com` triggers 6 DNS queries (appending each cluster search domain) before resolving externally. Use fully qualified names (`api.stripe.com.`) to skip the search path.

### TLS: The Performance Tax

TLS 1.3 (current standard):
```
Client → Server: ClientHello (supported ciphers, key share)
Server → Client: ServerHello + Certificate + Finished (key exchange complete)
Client → Server: Finished
Data flows: 1 RTT (vs 2 RTT for TLS 1.2)
```

0-RTT resumption: subsequent connections resume with session tickets — no additional RTT. Be aware of replay attack risk for non-idempotent requests.

**Certificate pinning**: client verifies the server's public key against a pinned value — extra protection against MITM. Maintenance burden: pins must be updated before cert rotation.

---

## Implementation Patterns

### Pattern 1 — TCP Socket Tuning (Linux)
```bash
#!/usr/bin/env bash
# scripts/tune-tcp.sh — production TCP stack tuning
# Apply to Kubernetes nodes via DaemonSet or system bootstrap

# ── Increase connection capacity ──────────────────────────────────────────────

# Maximum number of open file descriptors (each connection = 1 fd)
sysctl -w fs.file-max=2097152
echo "* soft nofile 1048576" >> /etc/security/limits.conf
echo "* hard nofile 1048576" >> /etc/security/limits.conf

# Increase socket listen backlog (prevents SYN drops under burst)
sysctl -w net.core.somaxconn=65535
sysctl -w net.ipv4.tcp_max_syn_backlog=65535

# Ephemeral port range — important for high-throughput clients
sysctl -w net.ipv4.ip_local_port_range="1024 65535"

# ── TCP buffer sizes for high-bandwidth/high-latency links ───────────────────

# BDP = Bandwidth × RTT
# 1Gbps × 50ms RTT = 6.25MB — set buffers to at least this
sysctl -w net.core.rmem_max=134217728
sysctl -w net.core.wmem_max=134217728
sysctl -w net.ipv4.tcp_rmem="4096 87380 67108864"
sysctl -w net.ipv4.tcp_wmem="4096 87380 67108864"

# ── TIME_WAIT mitigation ──────────────────────────────────────────────────────

# Allow reuse of TIME_WAIT sockets for new connections
sysctl -w net.ipv4.tcp_tw_reuse=1

# Enable TCP timestamps (required for tw_reuse)
sysctl -w net.ipv4.tcp_timestamps=1

# ── Congestion control ────────────────────────────────────────────────────────

# BBR (Bottleneck Bandwidth and RTT) — better throughput under loss than CUBIC
# Requires kernel 4.9+
sysctl -w net.core.default_qdisc=fq
sysctl -w net.ipv4.tcp_congestion_control=bbr

# ── Connection keepalive ──────────────────────────────────────────────────────

# Detect dead connections faster (15s idle → 3 probes × 5s = 30s to detect)
sysctl -w net.ipv4.tcp_keepalive_time=15
sysctl -w net.ipv4.tcp_keepalive_intvl=5
sysctl -w net.ipv4.tcp_keepalive_probes=3

# ── Persist settings across reboots ──────────────────────────────────────────
cat >> /etc/sysctl.d/99-network-tuning.conf << EOF
fs.file-max = 2097152
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_timestamps = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_keepalive_time = 15
EOF
```

### Pattern 2 — DNS Debugging Toolkit
```bash
#!/usr/bin/env bash
# scripts/dns-debug.sh — systematic DNS debugging in Kubernetes

SERVICE="payments-service"
NAMESPACE="payments"
POD="debug-pod"

echo "=== 1. Check Pod's DNS config ==="
kubectl exec -n $NAMESPACE $POD -- cat /etc/resolv.conf
# Look for: nameserver (CoreDNS IP), search domains, ndots:5

echo "=== 2. Resolve in-cluster service ==="
# FQDN = <service>.<namespace>.svc.cluster.local
kubectl exec -n $NAMESPACE $POD -- \
  nslookup ${SERVICE}.${NAMESPACE}.svc.cluster.local
# Also try without FQDN — watch for extra queries due to ndots

echo "=== 3. Diagnose ndots issue (external hostname) ==="
# Without trailing dot: 6 queries (5 search domains + bare name)
kubectl exec -n $NAMESPACE $POD -- \
  time nslookup api.stripe.com
# With trailing dot (fully qualified): 1 query
kubectl exec -n $NAMESPACE $POD -- \
  time nslookup api.stripe.com.

echo "=== 4. Check CoreDNS logs ==="
kubectl logs -n kube-system \
  -l k8s-app=kube-dns \
  --since=5m \
  | grep -E "NXDOMAIN|SERVFAIL|error"

echo "=== 5. CoreDNS metrics ==="
kubectl exec -n kube-system \
  -l k8s-app=kube-dns -- \
  wget -qO- http://localhost:9153/metrics \
  | grep -E "coredns_dns_request_duration|coredns_cache"

echo "=== 6. Check if service has endpoints ==="
kubectl get endpoints $SERVICE -n $NAMESPACE
# If ENDPOINTS is empty: selector doesn't match pods or pods aren't ready

echo "=== 7. Packet-level DNS trace ==="
kubectl exec -n $NAMESPACE $POD -- \
  tcpdump -i eth0 -nn port 53 -w /tmp/dns.pcap &
kubectl exec -n $NAMESPACE $POD -- \
  curl https://api.stripe.com -o /dev/null
# Ctrl+C, then copy and analyse pcap
```

```yaml
# CoreDNS ConfigMap tuning — reduce latency for external DNS
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns
  namespace: kube-system
data:
  Corefile: |
    .:53 {
        errors
        health {
           lameduck 5s
        }
        ready

        # Cache: increase TTL for external queries to reduce resolver round trips
        cache {
          success 9984 300    # cache successful responses for 300s (up from default 30s)
          denial  9984 30
        }

        # Negative cache for ndots — cache NXDOMAINs to reduce retry storms
        rewrite name regex (.*)\.payments\.svc\.cluster\.local {1}.payments.svc.cluster.local

        kubernetes cluster.local in-addr.arpa ip6.arpa {
           pods insecure
           fallthrough in-addr.arpa ip6.arpa
           ttl 30
        }

        # Forward external queries to upstream resolver with DNS-over-TLS
        forward . tls://8.8.8.8 tls://8.8.4.4 {
          tls_servername dns.google
          health_check 5s
        }

        prometheus :9153
        loop
        reload
        loadbalance
    }
```

### Pattern 3 — Kubernetes Networking Deep Dive (iptables)
```bash
#!/usr/bin/env bash
# Trace how Kubernetes routes a Pod-to-Service connection via iptables

SERVICE_IP=$(kubectl get svc payments-service -n payments -o jsonpath='{.spec.clusterIP}')
SERVICE_PORT=8080

echo "=== Service VIP: $SERVICE_IP:$SERVICE_PORT ==="
echo "=== iptables NAT chain for this service ==="

# kube-proxy writes DNAT rules for each Service → Pod mapping
iptables -t nat -L KUBE-SERVICES -n --line-numbers \
  | grep $SERVICE_IP

echo ""
echo "=== DNAT endpoint rules ==="
# Find the chain for this service (e.g., KUBE-SVC-XXXXX)
CHAIN=$(iptables -t nat -L KUBE-SERVICES -n \
  | grep $SERVICE_IP \
  | awk '{print $2}')
iptables -t nat -L $CHAIN -n

echo ""
echo "=== Connection tracking ==="
# See active connections to this service
conntrack -L -d $SERVICE_IP 2>/dev/null | head -20
```

```go
// Go: diagnose connection pool exhaustion
// Symptoms: "dial tcp: i/o timeout" or "connection refused" under load

package diag

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"time"
)

// ProbeServiceConnectivity checks if a service is reachable and logs TCP details
func ProbeServiceConnectivity(ctx context.Context, addr string) error {
	dialer := &net.Dialer{
		Timeout:   5 * time.Second,
		KeepAlive: 30 * time.Second,
	}

	start := time.Now()
	conn, err := dialer.DialContext(ctx, "tcp", addr)
	dialDuration := time.Since(start)

	if err != nil {
		return fmt.Errorf("dial %s failed after %v: %w", addr, dialDuration, err)
	}
	defer conn.Close()

	fmt.Printf("Connected to %s in %v (local: %s)\n", addr, dialDuration, conn.LocalAddr())
	return nil
}

// CheckEphemeralPortExhaustion — detect TIME_WAIT port exhaustion
func CheckEphemeralPortExhaustion() {
	// Run: ss -s to see socket statistics
	// Run: ss -tan | grep TIME-WAIT | wc -l
	// If TIME-WAIT count approaches (65535 - 1024 = 64511), exhaustion is near
	// Fix: enable tcp_tw_reuse, use connection pooling, or tune local port range
}

// Correct http.Client for production — with timeouts and transport tuning
func NewHTTPClient() *http.Client {
	transport := &http.Transport{
		// Connection pool settings
		MaxIdleConns:        100,
		MaxIdleConnsPerHost: 20,   // default is 2 — too low for high-RPS services
		MaxConnsPerHost:     0,    // unlimited concurrent connections
		IdleConnTimeout:     90 * time.Second,

		// Disable Nagle's algorithm — critical for request-response patterns
		DialContext: (&net.Dialer{
			Timeout:   5 * time.Second,
			KeepAlive: 30 * time.Second,
		}).DialContext,

		TLSHandshakeTimeout:   10 * time.Second,
		ResponseHeaderTimeout: 10 * time.Second,
		ExpectContinueTimeout: 1 * time.Second,

		// Force HTTP/2 for multiplexed connections
		ForceAttemptHTTP2: true,
	}

	return &http.Client{
		Transport: transport,
		Timeout:   30 * time.Second, // end-to-end timeout
	}
}
```

### Pattern 4 — Istio mTLS and Traffic Management
```yaml
# Istio: enforce strict mTLS between all services in the mesh

# PeerAuthentication — require mTLS for all pods in namespace
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default
  namespace: payments
spec:
  mtls:
    mode: STRICT   # reject any plaintext connections

---
# DestinationRule — configure circuit breaking and connection pool per service
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: payments-service
  namespace: payments
spec:
  host: payments-service.payments.svc.cluster.local
  trafficPolicy:
    connectionPool:
      tcp:
        maxConnections: 100           # max TCP connections per Envoy
        connectTimeout: 5s
        tcpKeepalive:
          time: 7200s
          interval: 75s
      http:
        http2MaxRequests: 1000        # max concurrent HTTP/2 streams
        maxRequestsPerConnection: 100 # force connection rotation (avoids hot connection)
        maxRetries: 3
        idleTimeout: 90s
    circuitBreaker:
      consecutiveGatewayErrors: 5    # open circuit after 5 consecutive 5xx
      interval: 10s                   # evaluation window
      baseEjectionTime: 30s           # eject unhealthy host for 30s
      maxEjectionPercent: 50          # never eject more than 50% of hosts

---
# VirtualService — retry and timeout policies
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: payments-service
  namespace: payments
spec:
  hosts:
    - payments-service.payments.svc.cluster.local
  http:
    - route:
        - destination:
            host: payments-service.payments.svc.cluster.local
      timeout: 10s          # total request timeout
      retries:
        attempts: 3
        perTryTimeout: 3s   # individual attempt timeout
        retryOn: "gateway-error,connect-failure,retriable-4xx"
        retryRemoteLocalities: true  # don't retry on same failing host
```

### Pattern 5 — Cloud VPC Network Design (AWS)
```hcl
# terraform/vpc.tf — production VPC with proper network segmentation

# ── VPC ───────────────────────────────────────────────────────────────────────

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = { Name = "production" }
}

# ── Subnets: 3 tiers × 3 AZs ─────────────────────────────────────────────────

# Public subnets — load balancers, NAT gateways, bastion hosts ONLY
resource "aws_subnet" "public" {
  count             = 3
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.${count.index}.0/24"
  availability_zone = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = false  # never auto-assign public IPs

  tags = { Name = "public-${count.index}", Tier = "public" }
}

# Private subnets — application workloads (EKS nodes, ECS tasks)
resource "aws_subnet" "private" {
  count             = 3
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.${count.index + 10}.0/24"
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = { Name = "private-${count.index}", Tier = "private" }
}

# Isolated subnets — databases, caches (NO internet access, no NAT)
resource "aws_subnet" "isolated" {
  count             = 3
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.${count.index + 20}.0/24"
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = { Name = "isolated-${count.index}", Tier = "isolated" }
}

# ── Routing ───────────────────────────────────────────────────────────────────

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
}

resource "aws_nat_gateway" "main" {
  count         = 3   # one per AZ — high availability
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
}

# Private subnets route to NAT gateway in same AZ (avoids cross-AZ charges)
resource "aws_route_table" "private" {
  count  = 3
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[count.index].id
  }
}

# Isolated subnets — local routing only, no default route
resource "aws_route_table" "isolated" {
  vpc_id = aws_vpc.main.id
  # No default route — isolated subnets cannot reach internet
}

# ── Security groups ───────────────────────────────────────────────────────────

resource "aws_security_group" "alb" {
  name   = "alb-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }
}

resource "aws_security_group" "app" {
  name   = "app-sg"
  vpc_id = aws_vpc.main.id

  # Only accept traffic from ALB
  ingress {
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
  # Allow outbound to DB subnet
  egress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.db.id]
  }
}

resource "aws_security_group" "db" {
  name   = "db-sg"
  vpc_id = aws_vpc.main.id

  # Only accept traffic from app tier
  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }
}
```

### Pattern 6 — Network Debugging Toolkit
```bash
#!/usr/bin/env bash
# Systematic network debugging checklist for Kubernetes workloads

SERVICE="payments-service"
NAMESPACE="payments"
POD=$(kubectl get pod -n $NAMESPACE -l app=$SERVICE -o name | head -1)

echo "=== Connectivity Tests ==="

# 1. Pod-to-Pod direct (bypasses Service and iptables)
TARGET_POD_IP=$(kubectl get pod -n $NAMESPACE -l app=$SERVICE \
  -o jsonpath='{.items[0].status.podIP}')
kubectl exec -n $NAMESPACE $POD -- \
  wget -qO- --timeout=5 http://${TARGET_POD_IP}:8080/health
echo "Pod-to-Pod: $?"

# 2. Pod-to-Service (via kube-proxy iptables rules)
kubectl exec -n $NAMESPACE $POD -- \
  wget -qO- --timeout=5 http://${SERVICE}.${NAMESPACE}.svc.cluster.local:8080/health
echo "Pod-to-Service: $?"

# 3. External connectivity (tests NAT gateway + security groups)
kubectl exec -n $NAMESPACE $POD -- \
  wget -qO- --timeout=10 https://api.stripe.com/v1/charges \
  -H "Authorization: Bearer sk_test_fake"
echo "External HTTPS: $?"  # Expect 401, not connection refused

echo "=== Network Policy Check ==="
kubectl describe networkpolicy -n $NAMESPACE

echo "=== Pod Networking ==="
kubectl exec -n $NAMESPACE $POD -- ip addr
kubectl exec -n $NAMESPACE $POD -- ip route
kubectl exec -n $NAMESPACE $POD -- cat /etc/resolv.conf

echo "=== Service Endpoints ==="
kubectl get endpoints $SERVICE -n $NAMESPACE -o wide

echo "=== Recent Network Events ==="
kubectl get events -n $NAMESPACE \
  --field-selector reason=NetworkNotReady,reason=FailedToCreateRoute \
  --sort-by='.lastTimestamp'

echo "=== Packet Capture (5s) ==="
kubectl exec -n $NAMESPACE $POD -- \
  tcpdump -i eth0 -nn -c 50 -w - 2>/dev/null | tcpdump -r - -nn 2>/dev/null
```

---

## Anti-Patterns

### 1. Default Go HTTP Client (No Timeouts)
```go
// WRONG — no timeout; hangs forever if server stops responding
resp, err := http.Get("http://payments-service:8080/payments")
```
**Fix**: always set timeouts on `http.Client` and `http.Transport`. Use `context.WithTimeout` for per-request deadlines.

### 2. ndots:5 DNS Latency on External Calls
A Pod calling `api.stripe.com` with the default `ndots:5` setting triggers 6 DNS queries before resolving. Each query is a round trip to CoreDNS.

**Fix**: use fully qualified domain names (`api.stripe.com.`) for external hosts, or reduce `ndots` to `ndots:2` in your Pod spec's `dnsConfig`.

### 3. Security Groups Allow 0.0.0.0/0 Ingress
Opening all inbound traffic to reduce friction during development. Left in production.

**Fix**: all SG rules should be source-specific. App tier accepts only from ALB SG. DB tier accepts only from app tier SG.

### 4. Single-AZ NAT Gateway
Using one NAT gateway for all private subnets. If the AZ fails, all outbound internet access fails.

**Fix**: one NAT gateway per AZ; route each AZ's private subnet to its local NAT gateway.

### 5. Plaintext Service-to-Service in Production
Kubernetes Services communicate over plaintext by default. Any workload in the cluster can observe traffic.

**Fix**: Istio or Cilium with mTLS mode `STRICT`. Certificate rotation is automated — no operational burden.

### 6. MaxIdleConnsPerHost=2 (Default Go HTTP)
Go's default `http.Transport` allows only 2 idle connections per host. A service making 100 concurrent requests creates 98 new TCP connections — triggering TLS handshakes, SYN round trips, and CPU overhead.

**Fix**: set `MaxIdleConnsPerHost` to at least `QPS × avg_latency_seconds × 1.5` for expected peak traffic.

---

## Decision Matrix

| Scenario | Recommendation |
|----------|---------------|
| High TIME_WAIT count | Enable `tcp_tw_reuse`; use connection pooling |
| DNS latency on external calls | Use FQDN with trailing dot; reduce `ndots` in dnsConfig |
| Service not reachable | Check endpoints (selector match), NetworkPolicy, SG |
| Pod-to-Pod works but Service doesn't | kube-proxy issue; check iptables rules |
| mTLS between services | Istio PeerAuthentication + DestinationRule |
| Circuit breaking between services | Istio DestinationRule + outlier detection |
| Cross-AZ network cost | Route to local NAT/AZ; use AZ-local service endpoints |
| DB reachable from internet | Isolated subnet + no default route + SG allows only app tier |
| Connection pool exhaustion | Increase MaxIdleConnsPerHost; tune pool size to match load |
| TLS cert rotation automation | cert-manager + Vault PKI; Istio auto-rotates mesh certs |

---

## Proficiency Levels

### Novice
- Understands TCP handshake, IP addressing, and basic routing
- Knows what DNS does and why TTL matters
- Can use `kubectl exec -- curl/wget/nslookup` to debug in-cluster connectivity

### Intermediate
- Debugs Kubernetes service connectivity (endpoints, NetworkPolicy, kube-proxy)
- Understands ndots and FQDN DNS optimisation
- Configures security groups with least-privilege rules
- Knows when to tune `http.Transport` settings (connection pooling, timeouts)

### Advanced
- Reads iptables NAT rules to trace kube-proxy packet paths
- Designs multi-AZ VPC with proper subnet tiers and routing
- Configures Istio for mTLS, circuit breaking, and traffic management
- Tunes Linux TCP stack for high-throughput workloads (BBR, buffer sizes)
- Diagnoses TIME_WAIT exhaustion and latency spikes with `ss`, `tcpdump`, `conntrack`

### Expert
- Designs custom CNI or eBPF-based networking (Cilium without iptables)
- Implements multi-region network topology with Transit Gateway and Direct Connect
- Analyses packet captures at depth; identifies TLS issues, TCP retransmits, PMTUD blackholes
- Designs for network-level resilience: chaos engineering on network paths, failure injection
- Contributes to or operates Kubernetes networking components (kube-proxy, CoreDNS, CNI plugins)

---

## AI Prompts

1. **DNS debugging**: "My Go service is getting 50ms latency on every external API call to `api.stripe.com`. I'm running in Kubernetes. How do I diagnose and fix DNS-related latency issues? Include the commands to run."

2. **TCP tuning**: "My payment service handles 50K req/s with p99 < 20ms. During load tests I see TCP connection timeouts and `i/o timeout` errors. What Linux TCP parameters should I tune and why?"

3. **VPC design**: "Design a 3-tier VPC for a Kubernetes application on AWS with public (load balancers), private (EKS nodes), and isolated (RDS PostgreSQL) subnets. Include security group rules and routing."

4. **Istio configuration**: "Configure Istio for my payments service: enforce mTLS in STRICT mode, set a 10s request timeout, add retries for `gateway-error`, and configure circuit breaking to eject pods after 5 consecutive errors."

5. **Connectivity debugging**: "My orders-service can't reach payments-service in Kubernetes. Pod-to-Pod direct connection works. Give me a systematic debugging checklist from DNS through iptables."

---

## References

- Brendan Gregg — *Systems Performance* (2020) — Linux network stack analysis
- Wireshark documentation — packet capture and analysis
- Kubernetes Networking documentation — kubernetes.io/docs/concepts/services-networking
- Istio documentation — istio.io/docs — traffic management, security
- Cilium documentation — docs.cilium.io — eBPF-based networking
- AWS VPC documentation — VPC design best practices
- Cloudflare Blog — TCP BBR deployment, DNS-over-HTTPS
- Thomas Graf — *The Future of Linux Networking: eBPF and XDP* (KubeCon 2019)
- RFC 793 (TCP), RFC 1035 (DNS), RFC 8446 (TLS 1.3)
- `man 7 tcp` — Linux TCP socket options (authoritative reference for tuning)
