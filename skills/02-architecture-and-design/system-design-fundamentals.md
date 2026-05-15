---
name: System Design Fundamentals
slug: system-design-fundamentals
category: 02-architecture-and-design
proficiency: advanced
description: >
  End-to-end framework for designing scalable, reliable, and maintainable
  distributed systems. Covers capacity estimation, scalability primitives
  (horizontal scaling, sharding, replication), reliability (replication, 
  circuit breakers, bulkheads), consistency models, load balancing, CDN,
  message queues, and how to structure a system design interview or RFC.
tags:
  - system-design
  - scalability
  - reliability
  - cap-theorem
  - sharding
  - replication
  - load-balancing
  - caching
  - consistency
status: published
---

## Principles

### The Three Properties to Optimise
Every design is a negotiation between:
- **Scalability** — can the system handle 10×, 100× more load without redesign?
- **Reliability** — does it stay available when components fail? (hardware, network, software)
- **Maintainability** — can engineers operate, evolve, and debug it over years?

### CAP Theorem (Brewer, 2000)
In the presence of a network **Partition**, a distributed system must choose between:
- **Consistency** (C) — every read returns the most recent write
- **Availability** (A) — every request receives a response (possibly stale)

Network partitions happen. Real systems are CA within a data centre (rare partitions), CP under partitions (banking, inventory), or AP under partitions (shopping cart, DNS, social feeds).

**PACELC extension**: even without partitions (E), there is a trade-off between Latency (L) and Consistency (C). Most systems optimise for low latency at the cost of eventual consistency.

### Consistency Models (weakest to strongest)
| Model | Guarantee | Examples |
|-------|-----------|---------|
| **Eventual** | All replicas converge eventually | DynamoDB default, Cassandra, DNS |
| **Read-your-writes** | A writer always sees its own writes | Session consistency in most databases |
| **Monotonic reads** | A client never reads older data after reading newer | Sticky sessions to same replica |
| **Consistent prefix** | Reads never see out-of-order writes | Cosmos DB prefixed consistency |
| **Bounded staleness** | Reads lag behind leader by at most K versions/time | Cosmos DB bounded staleness |
| **Session** | Read-your-writes + monotonic reads within a session | Azure Cosmos DB, MongoDB sessions |
| **Strong (linearisable)** | All reads/writes appear instantaneous globally | Spanner, single-region PostgreSQL |

### Scalability Primitives

**Vertical scaling** (scale-up): more CPU/RAM on one machine. Simple. Has a ceiling. Downtime risk on upgrades.

**Horizontal scaling** (scale-out): add more instances. Requires statelessness or distributed state management. Elastic: add/remove instances based on load.

**Sharding** (horizontal partitioning): split data across multiple nodes by key. Each node owns a subset.
- Range sharding: `user_id 0–1M → shard-1`, `1M–2M → shard-2`. Hot spots risk.
- Hash sharding: `shard = hash(user_id) % N`. Uniform distribution; range queries harder.
- Consistent hashing: virtual nodes on a ring; minimises data movement when nodes join/leave.

**Replication**: same data on multiple nodes.
- Leader-follower: writes go to leader, reads can go to followers (eventual consistency lag).
- Leader-leader (multi-primary): writes go to any node, conflicts must be resolved.
- Quorum (Raft/Paxos): majority agreement for writes; strong consistency; higher latency.

### Reliability Patterns
- **Replication**: redundant copies tolerate node failures
- **Circuit breaker**: stop calling a failing dependency; fail fast; allow recovery time
- **Bulkhead**: isolate resource pools so one overloaded service can't exhaust all connections
- **Retry with exponential backoff + jitter**: handle transient failures without thundering herd
- **Timeout**: never wait indefinitely; set deadlines at every level
- **Rate limiting**: protect services from overload (upstream abuse or internal runaway jobs)
- **Graceful degradation**: serve reduced functionality when dependencies fail (e.g., serve cached data)
- **Health checks + automatic failover**: route traffic away from unhealthy instances

### Latency Numbers to Know (Order of Magnitude)
| Operation | Approximate Latency |
|-----------|-------------------|
| L1 cache reference | 1 ns |
| L2 cache reference | 4 ns |
| RAM access | 100 ns |
| SSD random read | 100 µs |
| HDD random read | 10 ms |
| Same-DC network round trip | 0.5 ms |
| Cross-region network (US–EU) | 75 ms |
| TCP handshake (same DC) | 1 ms |
| Redis GET | 0.5–1 ms |
| PostgreSQL indexed lookup | 1–5 ms |

---

## Implementation Patterns

### Pattern 1 — Capacity Estimation Framework
```
# Back-of-envelope calculation template

## Traffic
Daily active users (DAU):              100M
Average requests per user per day:     10
Total requests/day:                    1B
Peak QPS (assume 3× average):         ~35,000 req/s
Read:Write ratio:                      95:5

## Storage
User record size:                      1 KB
New records/day:                       500K
Storage/day:                           500 MB
Storage/year:                          ~180 GB
With 3× replication:                   ~540 GB

## Bandwidth
Average response size:                 10 KB
Peak outbound bandwidth:               35,000 × 10 KB = 350 MB/s = 2.8 Gbps

## Memory (cache sizing)
Hot data (20% of daily requests):      20% × 35K QPS × 10 KB × 86400 s = large
Typical rule: 20% of data fits in RAM, serves 80% of requests

## Derived constraints
- Need distributed cache (Redis Cluster or Memcached)
- Relational DB can handle ~10K QPS with read replicas
- Beyond ~50K QPS writes: shard or move to NoSQL (Cassandra, DynamoDB)
- CDN needed if bandwidth > 1 Gbps sustained
```

### Pattern 2 — URL Shortener Reference Design (Go)
```go
// Classic system design example — demonstrates most fundamental patterns

// Short URL generation: base62 encoding of an auto-increment ID
// Collision-free, sortable, 6 chars covers 56B URLs (62^6)

package shortener

import (
	"context"
	"errors"
	"math/rand"
	"time"
)

const base62Chars = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

// Encode converts a uint64 ID to a base62 string.
func Encode(id uint64) string {
	if id == 0 {
		return string(base62Chars[0])
	}
	var result []byte
	for id > 0 {
		result = append([]byte{base62Chars[id%62]}, result...)
		id /= 62
	}
	return string(result)
}

// Decode converts a base62 string back to uint64.
func Decode(s string) (uint64, error) {
	var result uint64
	for _, c := range s {
		result *= 62
		idx := indexInBase62(byte(c))
		if idx < 0 {
			return 0, errors.New("invalid character: " + string(c))
		}
		result += uint64(idx)
	}
	return result, nil
}

func indexInBase62(c byte) int {
	for i, ch := range base62Chars {
		if byte(ch) == c {
			return i
		}
	}
	return -1
}

// ─── Service layer ────────────────────────────────────────────────────────────

type URLRecord struct {
	ID          uint64
	ShortCode   string
	OriginalURL string
	CreatedAt   time.Time
	ExpiresAt   *time.Time
	ClickCount  int64
}

type URLShortener struct {
	db    URLRepository
	cache Cache          // Redis — avoid DB lookup on every redirect
	idgen IDGenerator    // distributed ID generator (Snowflake / DB sequence)
}

func (s *URLShortener) Shorten(ctx context.Context, originalURL string) (string, error) {
	// Check if already shortened (content-addressed dedup)
	if existing, err := s.cache.GetByURL(ctx, originalURL); err == nil {
		return existing, nil
	}

	id, err := s.idgen.Next(ctx)
	if err != nil {
		return "", err
	}
	code := Encode(id)

	record := URLRecord{
		ID:          id,
		ShortCode:   code,
		OriginalURL: originalURL,
		CreatedAt:   time.Now().UTC(),
	}
	if err := s.db.Save(ctx, record); err != nil {
		return "", err
	}
	s.cache.Set(ctx, code, originalURL, 24*time.Hour)
	return code, nil
}

func (s *URLShortener) Resolve(ctx context.Context, code string) (string, error) {
	// Cache-aside: check cache first
	if url, err := s.cache.Get(ctx, code); err == nil {
		return url, nil
	}

	record, err := s.db.FindByCode(ctx, code)
	if err != nil {
		return "", err
	}
	if record.ExpiresAt != nil && time.Now().After(*record.ExpiresAt) {
		return "", ErrExpired
	}

	s.cache.Set(ctx, code, record.OriginalURL, 24*time.Hour)
	return record.OriginalURL, nil
}
```

### Pattern 3 — Circuit Breaker Implementation (Go)
```go
// circuit_breaker.go — protects downstream calls from cascading failures

package resilience

import (
	"context"
	"errors"
	"sync"
	"time"
)

type State int

const (
	StateClosed   State = iota // Normal operation
	StateOpen                  // Failing — reject calls immediately
	StateHalfOpen              // Testing recovery — allow one probe
)

var ErrCircuitOpen = errors.New("circuit breaker is open")

type CircuitBreaker struct {
	mu              sync.Mutex
	state           State
	failureCount    int
	successCount    int
	lastFailureTime time.Time

	// Config
	failureThreshold int           // failures before opening
	successThreshold int           // successes in half-open before closing
	timeout          time.Duration // time in open state before trying half-open
}

func NewCircuitBreaker(failureThreshold, successThreshold int, timeout time.Duration) *CircuitBreaker {
	return &CircuitBreaker{
		state:            StateClosed,
		failureThreshold: failureThreshold,
		successThreshold: successThreshold,
		timeout:          timeout,
	}
}

func (cb *CircuitBreaker) Execute(ctx context.Context, fn func(context.Context) error) error {
	cb.mu.Lock()
	state := cb.currentState()
	if state == StateOpen {
		cb.mu.Unlock()
		return ErrCircuitOpen
	}
	cb.mu.Unlock()

	err := fn(ctx)

	cb.mu.Lock()
	defer cb.mu.Unlock()

	if err != nil {
		cb.onFailure()
	} else {
		cb.onSuccess()
	}
	return err
}

func (cb *CircuitBreaker) currentState() State {
	if cb.state == StateOpen {
		if time.Since(cb.lastFailureTime) > cb.timeout {
			cb.state = StateHalfOpen
			cb.successCount = 0
		}
	}
	return cb.state
}

func (cb *CircuitBreaker) onFailure() {
	cb.lastFailureTime = time.Now()
	switch cb.state {
	case StateClosed:
		cb.failureCount++
		if cb.failureCount >= cb.failureThreshold {
			cb.state = StateOpen
		}
	case StateHalfOpen:
		cb.state = StateOpen // one failure in half-open → back to open
	}
}

func (cb *CircuitBreaker) onSuccess() {
	switch cb.state {
	case StateClosed:
		cb.failureCount = 0
	case StateHalfOpen:
		cb.successCount++
		if cb.successCount >= cb.successThreshold {
			cb.state = StateClosed
			cb.failureCount = 0
		}
	}
}

// ─── Usage ────────────────────────────────────────────────────────────────────

type PaymentService struct {
	gateway PaymentGateway
	cb      *CircuitBreaker
}

func (s *PaymentService) Charge(ctx context.Context, req ChargeRequest) (string, error) {
	var chargeRef string
	err := s.cb.Execute(ctx, func(ctx context.Context) error {
		var err error
		chargeRef, err = s.gateway.Charge(ctx, req)
		return err
	})
	return chargeRef, err
}
```

### Pattern 4 — Consistent Hashing for Sharding (Go)
```go
// consistent_hash.go — minimises key redistribution when nodes join/leave

package sharding

import (
	"crypto/sha256"
	"encoding/binary"
	"fmt"
	"sort"
	"sync"
)

type ConsistentHash struct {
	mu       sync.RWMutex
	ring     map[uint32]string // hash → node name
	sorted   []uint32          // sorted hash keys for binary search
	replicas int               // virtual nodes per physical node
}

func NewConsistentHash(replicas int) *ConsistentHash {
	return &ConsistentHash{
		ring:     make(map[uint32]string),
		replicas: replicas,
	}
}

func (c *ConsistentHash) AddNode(node string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	for i := 0; i < c.replicas; i++ {
		key := c.hash(fmt.Sprintf("%s:%d", node, i))
		c.ring[key] = node
		c.sorted = append(c.sorted, key)
	}
	sort.Slice(c.sorted, func(i, j int) bool { return c.sorted[i] < c.sorted[j] })
}

func (c *ConsistentHash) RemoveNode(node string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	for i := 0; i < c.replicas; i++ {
		key := c.hash(fmt.Sprintf("%s:%d", node, i))
		delete(c.ring, key)
	}
	// Rebuild sorted slice
	c.sorted = c.sorted[:0]
	for k := range c.ring {
		c.sorted = append(c.sorted, k)
	}
	sort.Slice(c.sorted, func(i, j int) bool { return c.sorted[i] < c.sorted[j] })
}

// Get returns the node responsible for the given key.
func (c *ConsistentHash) Get(key string) string {
	c.mu.RLock()
	defer c.mu.RUnlock()
	if len(c.ring) == 0 {
		return ""
	}
	h := c.hash(key)
	// Binary search for the first node with hash >= h
	idx := sort.Search(len(c.sorted), func(i int) bool { return c.sorted[i] >= h })
	if idx == len(c.sorted) {
		idx = 0 // wrap around
	}
	return c.ring[c.sorted[idx]]
}

func (c *ConsistentHash) hash(key string) uint32 {
	h := sha256.Sum256([]byte(key))
	return binary.BigEndian.Uint32(h[:4])
}

// ─── Example: route cache keys to Redis shards ───────────────────────────────

type ShardedRedisClient struct {
	ch      *ConsistentHash
	clients map[string]RedisClient // node name → client
}

func (s *ShardedRedisClient) Get(ctx context.Context, key string) (string, error) {
	node := s.ch.Get(key)
	return s.clients[node].Get(ctx, key)
}

func (s *ShardedRedisClient) Set(ctx context.Context, key, value string, ttl time.Duration) error {
	node := s.ch.Get(key)
	return s.clients[node].Set(ctx, key, value, ttl)
}
```

### Pattern 5 — Rate Limiter with Token Bucket (Go)
```go
// token_bucket.go — smooth rate limiting with burst allowance

package ratelimit

import (
	"context"
	"sync"
	"time"
)

type TokenBucket struct {
	mu           sync.Mutex
	tokens       float64
	capacity     float64   // max burst size
	refillRate   float64   // tokens per second
	lastRefillAt time.Time
}

func NewTokenBucket(capacity float64, refillRatePerSec float64) *TokenBucket {
	return &TokenBucket{
		tokens:       capacity,
		capacity:     capacity,
		refillRate:   refillRatePerSec,
		lastRefillAt: time.Now(),
	}
}

// Allow returns true if the request is permitted, false if rate limit exceeded.
func (tb *TokenBucket) Allow() bool {
	tb.mu.Lock()
	defer tb.mu.Unlock()

	now := time.Now()
	elapsed := now.Sub(tb.lastRefillAt).Seconds()
	tb.tokens = min(tb.capacity, tb.tokens+elapsed*tb.refillRate)
	tb.lastRefillAt = now

	if tb.tokens >= 1 {
		tb.tokens--
		return true
	}
	return false
}

func min(a, b float64) float64 {
	if a < b {
		return a
	}
	return b
}

// ─── Distributed token bucket via Redis Lua script ───────────────────────────

const tokenBucketLua = `
local key      = KEYS[1]
local capacity = tonumber(ARGV[1])
local rate     = tonumber(ARGV[2])   -- tokens/second
local now      = tonumber(ARGV[3])   -- unix milliseconds

local bucket = redis.call('HMGET', key, 'tokens', 'last_refill')
local tokens     = tonumber(bucket[1]) or capacity
local last_refill = tonumber(bucket[2]) or now

local elapsed = (now - last_refill) / 1000.0
tokens = math.min(capacity, tokens + elapsed * rate)

if tokens >= 1 then
  tokens = tokens - 1
  redis.call('HMSET', key, 'tokens', tokens, 'last_refill', now)
  redis.call('PEXPIRE', key, math.ceil(capacity / rate * 1000) + 1000)
  return {1, math.floor(tokens)}
else
  redis.call('HMSET', key, 'tokens', tokens, 'last_refill', now)
  redis.call('PEXPIRE', key, math.ceil(capacity / rate * 1000) + 1000)
  local retry_after_ms = math.ceil((1 - tokens) / rate * 1000)
  return {0, retry_after_ms}
end
`

type RedisTokenBucket struct {
	rdb      RedisClient
	capacity float64
	rate     float64 // tokens/second
}

func (r *RedisTokenBucket) Allow(ctx context.Context, key string) (allowed bool, retryAfterMs int64, err error) {
	nowMs := time.Now().UnixMilli()
	result, err := r.rdb.Eval(ctx, tokenBucketLua,
		[]string{key},
		r.capacity, r.rate, nowMs,
	)
	if err != nil {
		return true, 0, err // fail open
	}
	vals := result.([]interface{})
	allowed = vals[0].(int64) == 1
	retryAfterMs = vals[1].(int64)
	return
}
```

### Pattern 6 — System Design RFC Template
```markdown
# RFC: [System Name]
**Status**: Draft | Review | Approved | Implemented
**Author**: [name]
**Date**: [date]

## Problem Statement
What problem does this solve? What are the pain points with the current solution?

## Goals
- [ ] Goal 1 (measurable: e.g., "handle 50K req/s at p99 < 100ms")
- [ ] Goal 2
- [ ] Goal 3 (non-goal: out of scope)

## Capacity Estimation
| Metric | Current | Target (1yr) |
|--------|---------|-------------|
| Daily active users | 1M | 10M |
| Peak QPS | 1,000 | 35,000 |
| Data volume/day | 10 GB | 100 GB |
| Storage (3yr) | 10 TB | 100 TB |

## High-Level Architecture
[ASCII diagram or description of components and data flows]

## Component Design
### [Component 1 — e.g., API Layer]
- Technology: Go HTTP service
- Scaling: Horizontal; 10 pods; HPA on CPU 60%
- Availability: N+2 replicas; circuit breaker to downstream
- SLA: p99 < 50ms

### [Component 2 — e.g., Storage]
- Technology: PostgreSQL 15, RDS
- Sharding: None at current scale; hash shard by user_id at 10M users
- Replication: 1 primary + 2 read replicas
- Backup: Daily snapshots + WAL streaming

## Data Model
[Key tables/schemas/indexes]

## API Contract
[Key endpoints; request/response shapes]

## Failure Modes
| Failure | Impact | Mitigation |
|---------|--------|-----------|
| DB primary failure | Writes down ~30s | Auto failover to replica (RDS Multi-AZ) |
| Cache failure | Increased DB load | Cache-aside with DB fallback; circuit breaker |
| Downstream payment API down | Orders stuck | Circuit breaker; async retry queue |

## Trade-offs
- **Chosen**: Eventual consistency for read replicas (saves cost, acceptable for reads)
- **Rejected**: Synchronous replication (higher write latency, unnecessary for this data)

## Open Questions
1. Do we need geo-replication in year 1?
2. Which sharding key minimises hot spots?

## Milestones
| Date | Milestone |
|------|-----------|
| Week 1 | Prototype API + DB schema |
| Week 3 | Load test at target QPS |
| Week 5 | Production rollout (10% traffic) |
```

---

## Anti-Patterns

### 1. Premature Optimisation
Building a distributed cache, message queue, and multi-region replication for a service handling 100 QPS. Start with a single well-tuned database. Scale out only when you hit measured limits.

### 2. Single Point of Failure Without a Plan
A design with a single load balancer, single database, or single region — without addressing what happens when it fails. Every stateful component needs at minimum a failover or recovery story.

### 3. Ignoring the Network
Treating service calls as if they were local function calls — no timeouts, no retries, no circuit breakers. In distributed systems, the network is unreliable. Every outbound call needs a timeout.

### 4. Synchronous Chain of Service Calls
Request A calls B which calls C which calls D. Each link adds latency, and one slow dependency blocks the entire chain. Latency compounds: 3 services at p99 = 50ms each → p99 of chain ≈ 150ms+.

**Fix**: parallelize independent calls. Use async messaging for non-critical side effects.

### 5. Ignoring Consistency Requirements
Assuming eventual consistency is always acceptable. For inventory ("is item in stock?") or payment (double-charge prevention), you need strong consistency or careful idempotency. Model consistency requirements explicitly per operation.

### 6. Hotspot Keys in Sharded Systems
Sharding by a key with skewed access patterns — e.g., a celebrity user's posts all go to shard 3, which becomes the hot shard. Use composite keys or random jitter to spread load.

---

## Decision Matrix

| Scenario | Recommendation |
|----------|---------------|
| < 10K QPS, single region | Single database + cache; no sharding needed |
| 10–100K QPS reads | Add read replicas + distributed cache (Redis) |
| 100K+ QPS reads | Shard reads; consider CDN for static/semi-static content |
| High write throughput (> 10K writes/s) | Shard by key; consider Cassandra/DynamoDB for write-heavy |
| Strong consistency required | Single-leader replication + synchronous replication; avoid multi-primary |
| Eventual consistency acceptable | Leader-follower with async replication; higher availability |
| Cross-region low latency reads | Multi-region with regional read replicas or CDN |
| Cross-region writes | Multi-primary (high complexity); or route all writes to one region |
| Protect against cascade failures | Circuit breaker + bulkhead + timeout at every service boundary |
| Need to burst capacity quickly | Stateless services + horizontal pod autoscaler + pre-warmed capacity |
| Data with natural time-based access | Partition by time; archive/delete old partitions |
| Irregular / unpredictable traffic | Auto-scaling with floor capacity; load shedding with queue depth limit |

---

## Proficiency Levels

### Novice
- Understands client-server model, request-response, and stateless HTTP
- Knows what a load balancer and CDN do
- Can identify obvious single points of failure
- Knows that caching reduces database load

### Intermediate
- Can estimate capacity (QPS, storage, bandwidth) from requirements
- Understands CAP theorem trade-offs and can choose CP vs AP for a given use case
- Designs horizontally scalable stateless services with a shared cache
- Implements circuit breakers and retry with backoff
- Can draw a coherent high-level architecture diagram

### Advanced
- Designs sharding strategies; chooses hash vs range vs consistent hashing
- Handles cross-cutting concerns: distributed tracing, idempotency, rate limiting
- Models failure modes explicitly and mitigates each
- Knows when to use async messaging vs synchronous calls
- Can estimate cost (compute, storage, bandwidth) and make cost-aware trade-offs

### Expert
- Designs globally distributed systems with geo-routing and multi-region failover
- Applies formal consistency models (linearisability, causal consistency) and maps to technologies
- Identifies non-obvious bottlenecks: serialisation overhead, GC pressure, network MTU, TCP slow start
- Designs for operability: feature flags, gradual rollouts, observability hooks, capacity forecasting
- Writes RFCs that turn into production systems with minimal rework

---

## AI Prompts

1. **Capacity estimation**: "Given 50M DAU, each user sends 5 messages/day and reads a feed of 20 items/day. Help me estimate: peak QPS (read + write), daily storage growth, bandwidth at peak, and whether I need sharding in year 1."

2. **Architecture review**: "Review my design: a single PostgreSQL database, Redis cache, and Go HTTP service behind an ALB. It handles 5K QPS today and must reach 50K QPS in 18 months. What breaks first and what should I change?"

3. **Trade-off analysis**: "I need to decide between strong consistency (single-leader Postgres with synchronous replication) and eventual consistency (Postgres + read replicas with async replication) for my user balance reads. Help me reason through the trade-offs."

4. **Failure mode analysis**: "List the top 5 failure modes for my architecture: [describe architecture]. For each, what is the blast radius, and what is the mitigation?"

5. **RFC review**: "Review this RFC for a URL shortening service. Does it address scalability, reliability, consistency model, and failure modes? What's missing?"

---

## References

- Martin Kleppmann — *Designing Data-Intensive Applications* (2017) — the definitive reference
- Alex Xu — *System Design Interview* Vol 1 & 2 — practical worked examples
- CAP Theorem — Eric Brewer (PODC 2000 keynote)
- PACELC Theorem — Daniel Abadi (2012)
- Google SRE Book — *Site Reliability Engineering* (sre.google/sre-book)
- AWS Architecture Center — reference architectures and whitepapers
- Cloudflare Blog — load balancing, anycast, consistent hashing in production
- Netflix Tech Blog — Hystrix (circuit breaker), Chaos Engineering principles
