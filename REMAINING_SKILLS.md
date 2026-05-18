# SysSkills — Skills Backlog

**Library status: COMPLETE — 53/53 skills committed across all categories.**
**All skills delivered. No remaining items.**

Continue by naming a skill or saying "continue" — the AI will follow the sequence.

---

## How to resume

Open this repo in Claude Code and say:
> "Continue building the SysSkills library. We are at skill 33. Next up: [skill name from list below]."

Or just say "continue" and the AI will follow the recommended sequence top-to-bottom.

---

## Remaining Skills (in recommended build order)

### 04 — Backend & Services  *(3 remaining)*

| # | File slug | Title | Key topics |
|---|-----------|-------|------------|
| 34 | `api-security-rate-limiting` | API Security & Rate Limiting | Token bucket, sliding window, fixed window algorithms; Go/TypeScript middleware; Redis-backed distributed rate limiter; OWASP API Security Top 10; JWT validation middleware; API key rotation; request signing (HMAC); bot detection headers |
| 35 | `grpc-protocol-buffers` | gRPC & Protocol Buffers | Proto3 schema design; `buf` toolchain + linting + breaking-change detection; unary / server-stream / client-stream / bidirectional RPCs; interceptor chains (auth, tracing, retry); deadlines & cancellation; gRPC-Web for browsers; health checking protocol; reflection |
| 36 | `async-messaging-patterns` | Async Messaging Patterns | Outbox pattern (transactional inbox/outbox); competing consumers; dead-letter queues + poison-message handling; message deduplication (idempotency keys); fan-out/fan-in; priority queues; RabbitMQ exchange types; SQS FIFO vs Standard; backpressure signals |

---

### 05 — Data & Persistence  *(3 remaining)*

| # | File slug | Title | Key topics |
|---|-----------|-------|------------|
| 37 | `database-internals-query-optimisation` | Database Internals & Query Optimisation | B-tree vs LSM-tree storage engines; MVCC and isolation levels; WAL and crash recovery; `EXPLAIN`/`EXPLAIN ANALYZE`; index types (B-tree, GIN, BRIN, partial, covering); partition pruning; query planner statistics; connection pooling (PgBouncer); vacuum/autovacuum tuning; slow-query triage workflow |
| 38 | `caching-strategies` | Caching Strategies | Redis data structures (string, hash, sorted set, stream, HyperLogLog); cache patterns (cache-aside, write-through, write-behind, read-through); cache stampede prevention (probabilistic early expiry, Lua locks); CDN caching (Cache-Control, Vary, stale-while-revalidate); multi-layer cache hierarchy; eviction policies; Redis Cluster topology |
| 39 | `search-vector-databases` | Search & Vector Databases | Elasticsearch query DSL (bool, nested, agg); index design (mappings, analyzers, sharding); relevance tuning (BM25, function_score); pgvector HNSW index; embedding generation; cosine similarity queries; RAG (Retrieval-Augmented Generation) pipeline; hybrid search (BM25 + vector); Qdrant/Weaviate for pure-vector workloads |

---

### 06 — Security & Compliance  *(2 remaining)*

| # | File slug | Title | Key topics |
|---|-----------|-------|------------|
| 40 | `secrets-management-rotation` | Secrets Management & Rotation | Vault dynamic secrets (DB, AWS, PKI); Vault agent sidecar + injector annotations; External Secrets Operator provider matrix; secret rotation patterns (shadow secret, dual-active); PKI short-lived certs; envelope encryption; SOPS age/KMS; secret scanning (truffleHog, gitleaks) in CI; break-glass procedures |
| 41 | `container-runtime-security` | Container & Runtime Security | Falco rule authoring (syscall + k8s audit rules); OPA/Kyverno runtime policies; gVisor (runsc) kernel sandboxing; Kata Containers VM isolation; seccomp profile generation (docker-slim, `--security-opt`); image hardening (distroless, non-root, read-only FS); CIS Kubernetes Benchmark; NeuVector network-level threat detection |

---

### 02 — Architecture & Design  *(3 remaining)*

| # | File slug | Title | Key topics |
|---|-----------|-------|------------|
| 42 | `hexagonal-clean-architecture` | Hexagonal / Clean Architecture | Ports & adapters; dependency rule (inward-only); use-case layer; domain model isolation; adapter implementations (HTTP, gRPC, Kafka, SQL); testing at each layer without mocks leaking across boundaries; Go / Java / TypeScript project layouts; comparison with layered architecture |
| 43 | `saga-distributed-transactions` | Saga Pattern & Distributed Transactions | Choreography vs orchestration sagas; compensating transactions; Temporal workflow code (Go/TypeScript); failure modes (partial failure, duplicate execution); saga state persistence; idempotency in compensations; comparison with 2PC; Axon Framework saga; outbox integration |
| 44 | `system-design-fundamentals` | System Design Fundamentals | CAP theorem and PACELC; consistency models (linearisable, sequential, eventual, causal); back-of-envelope estimation (QPS, storage, bandwidth); consistent hashing; bloom filters; read/write path design; hot partition mitigation; global-local architecture trade-offs; common interview system designs |

---

### 08 — Quality, Testing & Observability  *(2 remaining)*

| # | File slug | Title | Key topics |
|---|-----------|-------|------------|
| 45 | `slo-error-budget-management` | SLOs, Error Budgets & Reliability | SLI/SLO/SLA definitions and hierarchy; error budget policy (feature freeze, reliability sprints); multi-window burn-rate alerts (1h + 6h fast-burn, 3d slow-burn); Prometheus recording rules for error budget remaining; Grafana SLO dashboard; toil measurement; CUJ (Critical User Journey) mapping; Sloth for SLO-as-code |
| 46 | `performance-testing-load-testing` | Performance Testing & Load Testing | k6 scripting (virtual users, scenarios, thresholds, checks); Gatling Scala/Kotlin simulations; Artillery YAML definitions; load vs stress vs soak vs spike testing; percentile analysis (p50/p95/p99); bottleneck identification (CPU, I/O, GC, locks); performance regression CI gates; profiling tools (async-profiler, pprof, py-spy) |

---

### 09 — Re-engineering & Evolution  *(2 remaining)*

| # | File slug | Title | Key topics |
|---|-----------|-------|------------|
| 47 | `database-migration-strategies` | Database Migration Strategies | Expand-contract (parallel-change) pattern; zero-downtime migrations (add column nullable → backfill → add constraint → drop old); Flyway vs Liquibase vs Atlas; blue-green DB cutover; shadow writes for validation; multi-version schema compatibility; schema-change impact on ORM / queries; rollback scripts |
| 48 | `technical-debt-management` | Technical Debt Management | Debt taxonomy (deliberate/inadvertent/reckless/prudent); quantification (time-to-develop vs time-to-work-around); ADR-driven refactoring decisions; strangler fig variants (facade, branch-by-abstraction); tech debt board (visibility, not backlog hell); team agreements on debt budgets; measuring debt velocity; coupling metrics (instability, abstractness) |

---

### 03 — Frontend & UX  *(2 remaining)*

| # | File slug | Title | Key topics |
|---|-----------|-------|------------|
| 49 | `web-performance-optimisation` | Web Performance Optimisation | Core Web Vitals (LCP, INP, CLS) — measurement and fixes; rendering strategies (SSR, SSG, ISR, streaming, partial hydration, islands); bundle optimisation (tree-shaking, code-splitting, dynamic import, preload/prefetch); image optimisation (WebP/AVIF, responsive images, lazy loading); HTTP/2 push vs preload; font loading strategies; performance budget |
| 50 | `state-management-patterns` | Frontend State Management | Local vs server vs global state taxonomy; Redux Toolkit (slices, RTK Query, entity adapters); Zustand/Jotai for lightweight global state; TanStack Query (stale-while-revalidate, optimistic updates, infinite queries); signals (Angular/Preact) vs reactive atoms; state machine UIs (XState); offline-first with IndexedDB + sync |

---

### 10 — Specialised Domains  *(3 remaining)*

| # | File slug | Title | Key topics |
|---|-----------|-------|------------|
| 51 | `ebpf-observability` | eBPF Observability | bpftrace one-liners and scripts; libbpf CO-RE programs; Cilium Hubble network flow visibility; Pixie auto-instrumentation; XDP packet processing; perf_events CPU profiling; BCC tools (execsnoop, biolatency, tcplife); eBPF maps (hash, ring buffer, LRU); kernel vs user-space probes (kprobe, uprobe, USDT); eBPF security (LSM hooks) |
| 52 | `ml-platform-engineering` | ML Platform Engineering | MLflow experiment tracking + model registry; Feast feature store (offline/online store, materialization); KServe `InferenceService` CRD (canary, custom runtimes); Kubeflow Pipelines DAG authoring; training job scheduling (volcano, MCAD); model versioning and A/B serving; drift detection (Evidently); GPU resource management; data lineage |
| 53 | `networking-internals` | Networking Internals | TCP 3-way handshake, congestion control (CUBIC, BBR); TLS 1.3 handshake and 0-RTT; DNS resolution chain (recursive, authoritative, DNSSEC); HTTP/1.1 vs HTTP/2 multiplexing vs HTTP/3 QUIC; socket programming (epoll, io_uring network path); NAT traversal (STUN/TURN); eBPF XDP fast path; network namespace and veth pairs (Kubernetes pod networking) |

---

## Category coverage summary

| Category | Built | Remaining | Total target |
|---|---|---|---|
| 02 Architecture & Design | 7 | 3 (42–44) | 10 |
| 03 Frontend & UX | 2 | 2 (49–50) | 4 |
| 04 Backend & Services | 3 | 3 (34–36) | 6 |
| 05 Data & Persistence | 2 | 3 (37–39) | 5 |
| 06 Security & Compliance | 4 | 2 (40–41) | 6 |
| 07 Platform & Infrastructure | 3 | 0 | 3 |
| 08 Quality & Observability | 3 | 2 (45–46) | 5 |
| 09 Re-engineering & Evolution | 1 | 2 (47–48) | 3 |
| 10 Specialised Domains | 6 | 3 (51–53) | 9 |
| **Total** | **33** | **20** | **53** |

---

## Notes

- All skills follow the same 8-section format: Principles, Implementation Patterns, Anti-Patterns, Code Templates (6 production-ready examples), Decision Matrix, Proficiency Levels (4), AI Prompts (5), References.
- Skills are flat `.md` files — one file per skill, no subdirectories within category folders.
- All git work is local only — never push to remote on company machine.
- Skills in `07-infrastructure-and-operations/` (old path) and `07-platform-and-infrastructure/` (new path) both exist; new skills go to `07-platform-and-infrastructure/`.
