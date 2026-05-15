---
name: Caching Strategies
slug: caching-strategies
category: 05-data-and-persistence
proficiency: advanced
description: >
  Design and implement multi-layer caching systems using Redis data structures,
  cache-aside, write-through, write-behind, and read-through patterns. Covers
  cache stampede prevention (probabilistic early expiry, distributed locks),
  CDN caching with Cache-Control and stale-while-revalidate, eviction policies,
  Redis Cluster topology, and cache warming strategies for Go, TypeScript, and Python.
tags:
  - caching
  - redis
  - cdn
  - cache-aside
  - write-through
  - write-behind
  - cache-stampede
  - eviction
  - redis-cluster
  - http-caching
  - multi-layer
status: complete
---

## Principles

### Why Cache
Caches trade memory for latency and throughput. They are useful when:
- **Read-heavy workloads**: same data read many times between writes
- **Expensive computation**: query results, aggregations, rendered HTML
- **Latency SLO**: DB p99 > target; cache p99 < 1 ms for in-process, < 2 ms for Redis
- **Rate limiting downstream systems**: third-party APIs with quotas

Caches are **not** useful when data changes on every read, or when the cost of staleness (serving stale data) exceeds the cost of the DB hit.

### Cache Hierarchy — Latency Reference
```
L1 cache (CPU)            ~1 ns
L2 cache (CPU)            ~4 ns
RAM / in-process cache    ~100 ns     (Go sync.Map, Ristretto, Caffeine)
Redis (same AZ, network)  ~0.5–2 ms
CDN edge PoP              ~5–50 ms    (varies by user geography)
Database (index scan)     ~5–50 ms
Database (full scan)      ~100ms–10s
```

### Cache Patterns

**Cache-Aside (Lazy Loading)**
```
Read:   check cache → HIT: return   MISS: read DB → populate cache → return
Write:  write DB → invalidate cache (or write-through)
```
Application code manages the cache. Most flexible; used for most read caches.

**Read-Through**
```
Read:   check cache → HIT: return   MISS: cache fetches from DB, populates, returns
Write:  application writes to DB only; cache evicts or is invalidated
```
Cache is in the critical path; transparent to application. Used in managed caches (ElastiCache read replicas, DAX).

**Write-Through**
```
Write:  write to cache → write to DB synchronously → return
Read:   always check cache first (high hit rate)
```
Writes are slow (double write); reads are fast. Cache is always consistent. Good for write-once/read-many.

**Write-Behind (Write-Back)**
```
Write:  write to cache → ack client → async flush to DB (batched)
```
Fastest write path; risk of data loss if cache crashes before flush. Use only when some data loss is acceptable (analytics counters, session data).

**Refresh-Ahead**
```
Before TTL expires → proactively refresh from DB in background
Client never sees a cache miss (no latency spike)
```
Requires predicting which keys will be accessed; complex to implement correctly.

### CDN Caching Model
```
Browser                CDN Edge PoP              Origin (your server)
  │                        │                          │
  ├──GET /api/products──▶  │                          │
  │                        ├──MISS──▶  GET /api/products
  │                        │                          │
  │                        │◀──200 + Cache-Control────┤
  │◀──200 (cached)─────────┤  max-age=300             │
  │                        │  s-maxage=3600            │
  │  (next request)        │  stale-while-revalidate=60│
  ├──GET /api/products──▶  │                          │
  │◀──200 (HIT, 0ms)───────┤                          │
```

**Key HTTP cache headers:**
| Header | Meaning |
|---|---|
| `Cache-Control: max-age=N` | Browser caches for N seconds |
| `Cache-Control: s-maxage=N` | CDN caches for N seconds (overrides max-age for CDN) |
| `Cache-Control: no-store` | Never cache (sensitive data) |
| `Cache-Control: no-cache` | Cache stores but revalidates with origin every time |
| `Cache-Control: stale-while-revalidate=N` | Serve stale while refreshing in background |
| `Cache-Control: stale-if-error=N` | Serve stale if origin errors (resilience) |
| `Vary: Accept-Language` | Cache different versions per header value |
| `ETag: "abc123"` | Conditional request: `If-None-Match: "abc123"` → 304 Not Modified |
| `Surrogate-Key` / `Cache-Tag` | CDN-specific tag for bulk purge by business key |

### Redis Eviction Policies
When Redis hits `maxmemory`, it evicts keys according to policy:
| Policy | Behaviour | Use When |
|---|---|---|
| `noeviction` | Writes fail; no eviction | Critical data; never accept loss |
| `allkeys-lru` | Evict least-recently-used key from all keys | General-purpose cache |
| `volatile-lru` | LRU on keys with TTL set | Cache + persistent data in same Redis |
| `allkeys-lfu` | Evict least-frequently-used (Redis 4+) | Skewed access patterns |
| `volatile-ttl` | Evict key with soonest expiry | Priority-based expiry |

---

## Implementation Patterns

### 1. Cache-Aside with Stampede Prevention
The thundering herd / cache stampede problem: many requests arrive for the same expired key simultaneously; all miss and hit the DB concurrently.

Three solutions:
- **Probabilistic early expiry (PER)**: recompute slightly before expiry with probability proportional to how close to expiry
- **Distributed mutex** (single-flight): first miss acquires a lock; others wait for the winner's result
- **Background refresh**: a goroutine refreshes the key before it expires; clients always see warm cache

### 2. Redis Data Structures
Use the right structure for the access pattern; wrong structure wastes memory and CPU.

### 3. Redis Cluster Topology
Redis Cluster shards data across 16384 hash slots distributed across N master nodes. Each master has 1–3 replicas. Hash tags `{user:123}` ensure related keys land on the same slot (required for multi-key commands).

### 4. HTTP Cache + CDN Invalidation
Tag cached responses with surrogate keys (Cloudflare Cache-Tag, Fastly Surrogate-Key). Purge by tag on write — O(1) invalidation regardless of how many URLs are affected.

### 5. Cache Warming
Pre-populate the cache on startup or after a purge to avoid thundering herd on cold start.

---

## Anti-Patterns

| Anti-Pattern | Why It Fails | Correction |
|---|---|---|
| **No TTL on cached values** | Stale data served indefinitely; cache grows unbounded | Always set TTL; tune per access pattern |
| **Cache the mutable source of truth** | Cache and DB drift on partial failure | Cache derivative/read values only; DB is source of truth |
| **Same Redis for cache and session** | `noeviction` needed for sessions conflicts with LRU for cache | Separate Redis instances (or separate DB numbers with different policies) |
| **Cache entire large objects** | Memory waste; slow serialisation | Cache only fields needed by callers |
| **No stampede protection on popular keys** | DB spike on TTL expiry of hot keys | PER or distributed mutex on hot keys |
| **Cache invalidation by guessing** | Stale data served; hard to reason about | Event-driven invalidation or write-through |
| **Caching per-user data at CDN** | CDN serves user A's data to user B | `Cache-Control: private` for user-specific; `public` for shared |
| **No `Vary` on content-negotiated responses** | CDN returns wrong language/encoding variant | `Vary: Accept-Language, Accept-Encoding` |
| **`KEYS *` in production Redis** | Blocks Redis for seconds on large keyspaces | Use `SCAN` cursor for iteration |
| **Multi-key commands across cluster slots** | `MGET key1 key2` fails if keys on different slots | Use hash tags `{prefix}:key1` or pipeline single-key commands |
| **Unbounded cache growth with no eviction** | OOM crash | Set `maxmemory` + appropriate policy; monitor `used_memory` |

---

## Code Templates

### Template 1 — Cache-Aside with Probabilistic Early Expiry (Go)

```go
// internal/cache/cache.go
package cache

import (
	"context"
	"encoding/json"
	"errors"
	"math"
	"math/rand"
	"time"

	"github.com/redis/go-redis/v9"
)

type Cache struct {
	rdb *redis.Client
}

func New(rdb *redis.Client) *Cache { return &Cache{rdb: rdb} }

// GetOrSet implements cache-aside with probabilistic early expiry (PER).
// beta controls eagerness of early recompute (1.0 = standard; >1 = more eager).
func (c *Cache) GetOrSet(
	ctx context.Context,
	key string,
	ttl time.Duration,
	beta float64,
	fetch func(ctx context.Context) (any, error),
	dest any,
) error {
	type stored struct {
		Value    json.RawMessage `json:"v"`
		Delta    float64         `json:"d"` // time taken to compute (seconds)
		Expiry   int64           `json:"e"` // unix timestamp of expiry
	}

	raw, err := c.rdb.Get(ctx, key).Bytes()
	if err != nil && !errors.Is(err, redis.Nil) {
		return err
	}

	if err == nil {
		var s stored
		if json.Unmarshal(raw, &s) == nil {
			// Probabilistic early expiry: recompute early with probability
			// proportional to how stale the value is relative to computation cost
			ttlRemaining := time.Until(time.Unix(s.Expiry, 0)).Seconds()
			if ttlRemaining > 0 {
				// PER formula: early recompute if -delta*beta*ln(rand()) > ttl_remaining
				if -s.Delta*beta*math.Log(rand.Float64()) <= ttlRemaining {
					return json.Unmarshal(s.Value, dest) // return cached value
				}
				// else: fall through to recompute (stampede prevention via early refresh)
			}
		}
	}

	// Cache miss (or PER triggered early recompute)
	start := time.Now()
	value, err := fetch(ctx)
	if err != nil {
		return err
	}
	delta := time.Since(start).Seconds()

	valueJSON, err := json.Marshal(value)
	if err != nil {
		return err
	}

	s := stored{
		Value:  valueJSON,
		Delta:  delta,
		Expiry: time.Now().Add(ttl).Unix(),
	}
	sJSON, _ := json.Marshal(s)

	c.rdb.Set(ctx, key, sJSON, ttl)
	return json.Unmarshal(valueJSON, dest)
}

// SingleFlight prevents stampede via distributed mutex: first caller fetches,
// others wait. Uses Redis SET NX as a distributed lock.
func (c *Cache) SingleFlight(
	ctx context.Context,
	key string,
	ttl time.Duration,
	fetch func(ctx context.Context) ([]byte, error),
) ([]byte, error) {
	// Try to get cached value
	if val, err := c.rdb.Get(ctx, key).Bytes(); err == nil {
		return val, nil
	}

	lockKey := "lock:" + key
	for attempts := 0; attempts < 20; attempts++ {
		// Try to acquire lock (SET NX with 5s expiry)
		acquired, err := c.rdb.SetNX(ctx, lockKey, 1, 5*time.Second).Result()
		if err != nil {
			return nil, err
		}

		if acquired {
			defer c.rdb.Del(ctx, lockKey)
			value, err := fetch(ctx)
			if err != nil {
				return nil, err
			}
			c.rdb.Set(ctx, key, value, ttl)
			return value, nil
		}

		// Another goroutine holds the lock — wait and retry
		time.Sleep(50 * time.Millisecond)
		if val, err := c.rdb.Get(ctx, key).Bytes(); err == nil {
			return val, nil // winner populated cache
		}
	}
	// Lock never acquired — fetch directly (fallback)
	return fetch(ctx)
}

// Invalidate deletes a cache key (used after writes)
func (c *Cache) Invalidate(ctx context.Context, keys ...string) error {
	return c.rdb.Del(ctx, keys...).Err()
}
```

---

### Template 2 — Redis Data Structures (Go)

```go
// internal/cache/structures.go — production Redis data structure patterns
package cache

import (
	"context"
	"time"

	"github.com/redis/go-redis/v9"
)

// ── Sorted Set: leaderboard / rate-limit sliding window ──────────────────────

type Leaderboard struct{ rdb *redis.Client }

func (l *Leaderboard) AddScore(ctx context.Context, board, member string, delta float64) error {
	return l.rdb.ZIncrBy(ctx, board, delta, member).Err()
}

func (l *Leaderboard) TopN(ctx context.Context, board string, n int) ([]redis.Z, error) {
	return l.rdb.ZRevRangeWithScores(ctx, board, 0, int64(n-1)).Result()
}

func (l *Leaderboard) Rank(ctx context.Context, board, member string) (int64, error) {
	return l.rdb.ZRevRank(ctx, board, member).Result()
}

// ── Hash: object storage with field-level updates ────────────────────────────

type UserCache struct{ rdb *redis.Client }

func (u *UserCache) Set(ctx context.Context, userID string, fields map[string]any, ttl time.Duration) error {
	key := "user:" + userID
	pipe := u.rdb.Pipeline()
	pipe.HMSet(ctx, key, fields)
	pipe.Expire(ctx, key, ttl)
	_, err := pipe.Exec(ctx)
	return err
}

func (u *UserCache) GetField(ctx context.Context, userID, field string) (string, error) {
	return u.rdb.HGet(ctx, "user:"+userID, field).Result()
}

func (u *UserCache) IncrField(ctx context.Context, userID, field string) (int64, error) {
	return u.rdb.HIncrBy(ctx, "user:"+userID, field, 1).Result()
}

// ── Stream: reliable event queue with consumer groups ────────────────────────

type EventStream struct{ rdb *redis.Client }

func (s *EventStream) Publish(ctx context.Context, stream string, fields map[string]any) (string, error) {
	return s.rdb.XAdd(ctx, &redis.XAddArgs{
		Stream: stream,
		MaxLen: 10_000, // cap stream length
		Approx: true,   // ~10k (faster than exact)
		Values: fields,
	}).Result()
}

func (s *EventStream) Consume(
	ctx context.Context,
	stream, group, consumer string,
	count int64,
) ([]redis.XMessage, error) {
	// Create group if not exists
	s.rdb.XGroupCreateMkStream(ctx, stream, group, "0")

	entries, err := s.rdb.XReadGroup(ctx, &redis.XReadGroupArgs{
		Group:    group,
		Consumer: consumer,
		Streams:  []string{stream, ">"},
		Count:    count,
		Block:    2 * time.Second,
	}).Result()
	if err != nil || len(entries) == 0 {
		return nil, err
	}
	return entries[0].Messages, nil
}

func (s *EventStream) Ack(ctx context.Context, stream, group string, ids ...string) error {
	return s.rdb.XAck(ctx, stream, group, ids...).Err()
}

// ── HyperLogLog: cardinality estimation (O(1) memory) ────────────────────────

type UniqueVisitors struct{ rdb *redis.Client }

func (u *UniqueVisitors) Track(ctx context.Context, date, userID string) error {
	return u.rdb.PFAdd(ctx, "uv:"+date, userID).Err()
}

func (u *UniqueVisitors) Count(ctx context.Context, dates ...string) (int64, error) {
	keys := make([]string, len(dates))
	for i, d := range dates {
		keys[i] = "uv:" + d
	}
	return u.rdb.PFCount(ctx, keys...).Result()
}

// ── Bit operations: feature flags / user activity ────────────────────────────

type ActivityBitmap struct{ rdb *redis.Client }

// Record that userID was active on dayOfYear (0-365)
func (a *ActivityBitmap) SetActive(ctx context.Context, year int, userID int64, dayOfYear int) error {
	key := fmt.Sprintf("activity:%d:%d", year, userID)
	return a.rdb.SetBit(ctx, key, int64(dayOfYear), 1).Err()
}

func (a *ActivityBitmap) DaysActive(ctx context.Context, year int, userID int64) (int64, error) {
	key := fmt.Sprintf("activity:%d:%d", year, userID)
	return a.rdb.BitCount(ctx, key, nil).Result()
}
```

---

### Template 3 — Write-Through + Write-Behind Cache (TypeScript)

```typescript
// src/cache/writePatterns.ts
import { createClient, RedisClientType } from "redis";

const redis: RedisClientType = createClient({ url: "redis://redis:6379" });

// ── Write-Through: update cache and DB atomically ────────────────────────────
export async function writeThroughUpdate<T extends { id: string }>(
  key: string,
  entity: T,
  ttlSeconds: number,
  persistToDB: (entity: T) => Promise<void>,
): Promise<void> {
  // Write to cache first (optimistic); rollback on DB failure
  const prev = await redis.get(key);
  await redis.setEx(key, ttlSeconds, JSON.stringify(entity));

  try {
    await persistToDB(entity);
  } catch (err) {
    // Rollback cache to previous state
    if (prev) {
      await redis.setEx(key, ttlSeconds, prev);
    } else {
      await redis.del(key);
    }
    throw err;
  }
}

// ── Write-Behind: buffer writes, flush in batches ─────────────────────────────
class WriteBehindBuffer<T> {
  private buffer = new Map<string, { entity: T; dirtyAt: number }>();
  private flushTimer: NodeJS.Timeout | null = null;

  constructor(
    private readonly persist: (batch: T[]) => Promise<void>,
    private readonly maxBatchSize = 100,
    private readonly flushIntervalMs = 500,
  ) {}

  write(key: string, entity: T): void {
    this.buffer.set(key, { entity, dirtyAt: Date.now() });
    if (this.buffer.size >= this.maxBatchSize) {
      this.flush();
    } else if (!this.flushTimer) {
      this.flushTimer = setTimeout(() => this.flush(), this.flushIntervalMs);
    }
  }

  private async flush(): Promise<void> {
    if (this.flushTimer) { clearTimeout(this.flushTimer); this.flushTimer = null; }
    if (this.buffer.size === 0) return;

    const batch = [...this.buffer.values()].map(v => v.entity);
    this.buffer.clear();

    try {
      await this.persist(batch);
    } catch (err) {
      console.error("Write-behind flush failed", err);
      // In production: dead-letter the failed batch, alert on-call
    }
  }

  async shutdown(): Promise<void> {
    if (this.flushTimer) { clearTimeout(this.flushTimer); this.flushTimer = null; }
    await this.flush(); // drain on graceful shutdown
  }
}

// ── Cache invalidation via event ─────────────────────────────────────────────
export async function invalidatePattern(pattern: string): Promise<number> {
  let cursor = 0;
  let deleted = 0;
  do {
    const result = await redis.scan(cursor, { MATCH: pattern, COUNT: 100 });
    cursor = result.cursor;
    if (result.keys.length > 0) {
      await redis.del(result.keys);
      deleted += result.keys.length;
    }
  } while (cursor !== 0);
  return deleted;
}
```

---

### Template 4 — CDN Cache Headers + Surrogate Key Invalidation (Go)

```go
// internal/http/cacheHeaders.go
package httputil

import (
	"fmt"
	"net/http"
	"strings"
	"time"
)

// CachePublic sets CDN-cacheable headers for shared resources.
// surrogateTags are used for bulk CDN purge by business key (Cloudflare Cache-Tag).
func CachePublic(w http.ResponseWriter, maxAge, sMaxAge time.Duration, surrogateTags ...string) {
	w.Header().Set("Cache-Control", fmt.Sprintf(
		"public, max-age=%d, s-maxage=%d, stale-while-revalidate=60, stale-if-error=86400",
		int(maxAge.Seconds()),
		int(sMaxAge.Seconds()),
	))
	if len(surrogateTags) > 0 {
		w.Header().Set("Cache-Tag", strings.Join(surrogateTags, ","))       // Cloudflare
		w.Header().Set("Surrogate-Key", strings.Join(surrogateTags, " "))   // Fastly / Varnish
	}
}

// CachePrivate sets headers for user-specific responses that CDN must not cache.
func CachePrivate(w http.ResponseWriter, maxAge time.Duration) {
	w.Header().Set("Cache-Control", fmt.Sprintf("private, max-age=%d", int(maxAge.Seconds())))
}

// NoCache prevents all caching (for sensitive or always-fresh endpoints).
func NoCache(w http.ResponseWriter) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Pragma", "no-cache")
}

// ETag generates a weak ETag from a version/hash string and handles conditional requests.
// Returns true if the response was served as 304 Not Modified (caller should return).
func ETag(w http.ResponseWriter, r *http.Request, etag string) bool {
	weakETag := `W/"` + etag + `"`
	w.Header().Set("ETag", weakETag)
	if r.Header.Get("If-None-Match") == weakETag {
		w.WriteHeader(http.StatusNotModified)
		return true
	}
	return false
}
```

```go
// internal/cdn/purge.go — Cloudflare Cache-Tag bulk purge
package cdn

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
)

// PurgeByTags purges all Cloudflare edge cache entries matching any of the given tags.
// Tags must have been set via the Cache-Tag response header.
func PurgeByTags(ctx context.Context, tags []string) error {
	zoneID := os.Getenv("CLOUDFLARE_ZONE_ID")
	apiToken := os.Getenv("CLOUDFLARE_API_TOKEN") // injected via ESO/IRSA

	body, _ := json.Marshal(map[string]any{"tags": tags})
	req, _ := http.NewRequestWithContext(ctx,
		http.MethodPost,
		fmt.Sprintf("https://api.cloudflare.com/client/v4/zones/%s/purge_cache", zoneID),
		bytes.NewReader(body),
	)
	req.Header.Set("Authorization", "Bearer "+apiToken)
	req.Header.Set("Content-Type", "application/json")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("cloudflare purge failed: HTTP %d", resp.StatusCode)
	}
	return nil
}

// Usage: on product update, purge all pages that showed this product
// cdn.PurgeByTags(ctx, []string{"product:123", "category:electronics"})
```

---

### Template 5 — Redis Cluster Configuration + Hash Tags (Go)

```go
// internal/cache/cluster.go
package cache

import (
	"context"
	"github.com/redis/go-redis/v9"
)

// NewCluster returns a Redis Cluster client.
// All nodes in the cluster are discovered automatically from the seed addresses.
func NewCluster(addrs []string) *redis.ClusterClient {
	return redis.NewClusterClient(&redis.ClusterOptions{
		Addrs:    addrs,
		// Route read commands to replicas (reduce master load)
		ReadOnly: true,
		RouteByLatency: true,

		PoolSize:        20,
		MinIdleConns:    5,
		ConnMaxIdleTime: 5 * 60 * 1e9, // 5 minutes

		// Retry on MOVED/ASK redirects (cluster rebalancing)
		MaxRedirects: 3,
	})
}

// HashTagKey ensures two related keys land on the same cluster slot.
// Redis uses only the content inside {} for slot calculation.
// Example: {user:123}:profile and {user:123}:prefs are co-located.
func HashTagKey(namespace, id, suffix string) string {
	return fmt.Sprintf("{%s:%s}:%s", namespace, id, suffix)
}

// MultiGet fetches multiple keys in the same hash-tag group atomically (MGET).
// All keys must share the same hash tag to be on the same slot.
func MultiGet(ctx context.Context, rdb *redis.ClusterClient, keys ...string) ([]any, error) {
	return rdb.MGet(ctx, keys...).Result()
}

// Pipeline multiple commands to same slot
func GetUserProfile(ctx context.Context, rdb *redis.ClusterClient, userID string) (profile, prefs string, err error) {
	profileKey := HashTagKey("user", userID, "profile")
	prefsKey   := HashTagKey("user", userID, "prefs")

	pipe := rdb.Pipeline()
	profileCmd := pipe.Get(ctx, profileKey)
	prefsCmd   := pipe.Get(ctx, prefsKey)
	_, err = pipe.Exec(ctx)
	if err != nil && err != redis.Nil {
		return "", "", err
	}

	profile, _ = profileCmd.Result()
	prefs, _ = prefsCmd.Result()
	return profile, prefs, nil
}
```

---

### Template 6 — Cache Warming + Monitoring (Python)

```python
# scripts/cache_warm.py — pre-populate cache after deployment or cold start
import asyncio
import json
import aioredis
import asyncpg
from typing import AsyncGenerator

REDIS_URL = "redis://redis:6379"
PG_DSN    = "postgresql://app:secret@postgres:5432/payments"
BATCH     = 100
TTL       = 3600  # 1 hour

async def warm_product_cache():
    redis = await aioredis.from_url(REDIS_URL, decode_responses=True)
    pg    = await asyncpg.connect(PG_DSN)

    try:
        async with pg.transaction():
            cursor = pg.cursor(
                "SELECT id, name, price, category FROM products WHERE active = true",
                prefetch=BATCH,
            )
            pipe_count = 0
            pipe = redis.pipeline(transaction=False)

            async for row in cursor:
                key   = f"product:{row['id']}"
                value = json.dumps(dict(row))
                pipe.setex(key, TTL, value)
                pipe_count += 1

                if pipe_count >= BATCH:
                    await pipe.execute()
                    pipe = redis.pipeline(transaction=False)
                    pipe_count = 0
                    print(f"Warmed {BATCH} products…")

            if pipe_count > 0:
                await pipe.execute()

        print("Cache warming complete")
    finally:
        await redis.aclose()
        await pg.close()


async def cache_health_metrics():
    """Emit Redis cache metrics for Prometheus scraping."""
    redis = await aioredis.from_url(REDIS_URL)
    info  = await redis.info("all")

    # Key metrics to export
    metrics = {
        "redis_used_memory_bytes":      info["used_memory"],
        "redis_maxmemory_bytes":        info.get("maxmemory", 0),
        "redis_keyspace_hits_total":    info["keyspace_hits"],
        "redis_keyspace_misses_total":  info["keyspace_misses"],
        "redis_evicted_keys_total":     info["evicted_keys"],
        "redis_connected_clients":      info["connected_clients"],
        "redis_blocked_clients":        info["blocked_clients"],
        "redis_rdb_last_save_seconds":  info["rdb_last_bgsave_time_sec"],
    }

    # Cache hit rate
    hits   = info["keyspace_hits"]
    misses = info["keyspace_misses"]
    total  = hits + misses
    hit_rate = hits / total if total > 0 else 0
    metrics["redis_cache_hit_rate"] = hit_rate

    print(f"Cache hit rate: {hit_rate:.1%}")
    if hit_rate < 0.80:
        print("WARNING: Cache hit rate below 80% — consider warming or increasing TTL")

    memory_pct = info["used_memory"] / info.get("maxmemory", 1) * 100 if info.get("maxmemory") else 0
    if memory_pct > 85:
        print(f"WARNING: Redis memory at {memory_pct:.0f}% — risk of eviction")

    await redis.aclose()
    return metrics


if __name__ == "__main__":
    asyncio.run(warm_product_cache())
```

```yaml
# prometheus/redis-alerts.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: redis-cache-alerts
  namespace: monitoring
spec:
  groups:
    - name: redis.cache
      rules:
        - alert: RedisCacheHitRateLow
          expr: |
            rate(redis_keyspace_hits_total[5m])
            /
            (rate(redis_keyspace_hits_total[5m]) + rate(redis_keyspace_misses_total[5m]))
            < 0.75
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "Redis cache hit rate {{ $value | humanizePercentage }} below 75%"

        - alert: RedisMemoryHigh
          expr: |
            redis_memory_used_bytes / redis_memory_max_bytes > 0.85
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Redis memory {{ $value | humanizePercentage }} of maxmemory"

        - alert: RedisEvictionSpiking
          expr: increase(redis_evicted_keys_total[5m]) > 1000
          for: 2m
          labels:
            severity: warning
          annotations:
            summary: "Redis evicting >1000 keys/5m — cache thrashing or maxmemory too low"
```

---

## Decision Matrix

| Scenario | Recommendation | Rationale |
|---|---|---|
| Read-heavy reference data (products, config) | Cache-aside + TTL + CDN s-maxage | Multiple cache layers; CDN absorbs global read load |
| User-specific data (profile, settings) | Cache-aside + `Cache-Control: private` | Cannot be cached at CDN; Redis for app-layer caching |
| Counter (page views, likes) | Redis INCR with periodic DB flush | Atomic in-memory counter; batch persist to avoid write amplification |
| Session storage | Redis Hash with TTL (no eviction policy) | Fast; TTL-based expiry; must not be evicted unexpectedly |
| Leaderboard / ranking | Redis Sorted Set (ZADD/ZREVRANGE) | O(log N) insertion; O(log N + K) range query |
| Distributed rate limiting | Redis Sorted Set or Lua sliding window | Atomic, multi-instance safe |
| Substring/fuzzy search results | Cache with pg_trgm GIN + Redis cache-aside | DB does the search; Redis caches hot queries |
| Hot key stampede (viral content) | Probabilistic early expiry or read-through with background refresh | Prevents thundering herd on TTL expiry |
| Large payloads (>512 KB) | Claim-check to S3 + Redis stores pointer | Redis not optimised for large blobs |
| Multi-DC active/active | Redis active-active (CRDT) via Redis Enterprise | Eventual consistency across DCs; standard Redis Cluster is single-DC |

---

## Proficiency Levels

### Level 1 — Aware
- Understands cache-aside pattern and TTL
- Knows the difference between `Cache-Control: public` and `private`
- Can add a Redis `GET`/`SET` call to a service and understand why it's faster than a DB query
- Recognises that stale data is a risk and that cache invalidation is hard

### Level 2 — Practitioner
- Implements cache-aside with Redis in Go/TypeScript/Python with proper TTL and error handling (fail-open)
- Sets appropriate `Cache-Control` headers for CDN caching; uses `ETag` for conditional requests
- Chooses correct Redis data structure for the access pattern (string vs hash vs sorted set)
- Detects and measures cache hit rate; sets `maxmemory` and `allkeys-lru` eviction policy
- Uses `SCAN` instead of `KEYS *`; understands why hash tags are needed for Redis Cluster

### Level 3 — Advanced
- Implements stampede prevention: probabilistic early expiry and distributed single-flight mutex
- Designs write-through and write-behind patterns with failure handling and graceful shutdown drain
- Configures CDN surrogate keys for event-driven cache purge on entity update
- Implements Redis Cluster with hash-tag co-location for multi-key operations
- Writes cache warming scripts; instruments hit rate, memory pressure, and eviction alerts

### Level 4 — Expert
- Designs multi-layer caching architecture: in-process (Ristretto/Caffeine) → Redis → CDN → origin
- Operates Redis at scale: Cluster topology design, slot rebalancing, rolling upgrades, memory sizing
- Implements Redis persistence strategy: RDB snapshots vs AOF for durability vs performance trade-off
- Tunes TCP keepalive and connection pool parameters for Redis Cluster under network partitions
- Designs cache invalidation event bus: every write emits an invalidation event consumed by all cache layers

---

## AI Prompts

**Design a caching strategy for a service**
```
Design a caching strategy for this service:
- Read/write ratio: [reads:writes]
- Data characteristics: [user-specific / shared / time-series / reference]
- Acceptable staleness: [seconds / minutes / never]
- Current DB p99 latency: [Xms]
- Traffic: [N] requests/second peak

Recommend: cache pattern (cache-aside / write-through / write-behind),
Redis data structure, TTL, eviction policy, stampede prevention approach,
and CDN headers if applicable.
Include: cache key design, invalidation strategy, and monitoring metrics.
```

**Implement cache stampede prevention**
```
Implement cache stampede prevention for a high-traffic endpoint in [Go/TypeScript/Python]
that caches [data type] with TTL=[N seconds].
Peak traffic: [N] req/s to this endpoint.

Implement both approaches:
1. Probabilistic early expiry (PER) — explain the beta parameter
2. Distributed single-flight mutex using Redis SET NX

For each: show the full implementation including error handling, timeout, and
fallback if Redis is unavailable (fail-open).
```

**Write Redis data structure for a use case**
```
I need to implement [leaderboard / activity tracking / unique visitor counting /
rate limiting / event queue with consumer groups] using Redis.

Show:
- The Redis data structure to use and why
- The key design (with hash tags if Redis Cluster is used)
- Go/TypeScript/Python code for read, write, and expiry management
- Memory estimate for [N] entries
- Any limitations (max size, precision trade-offs)
```

**Design CDN caching for an API**
```
Design HTTP caching headers for this API:
[paste route list with descriptions of what data they return]

For each route specify:
- Cache-Control directive (public/private, max-age, s-maxage, stale-while-revalidate)
- Whether to use ETag and how to generate it
- Surrogate-Key / Cache-Tag for CDN purge
- Vary header if content-negotiated

Also write the CDN purge logic: which tags to purge on [entity] create/update/delete.
```

---

## References

- **Redis documentation** — `redis.io/docs` — commands, data structures, cluster, persistence, eviction
- **"Designing Data-Intensive Applications"** — Kleppmann; Chapter 5 covers replication and caching trade-offs
- **Redis Cluster specification** — `redis.io/docs/reference/cluster-spec` — hash slots, failover, resharding
- **`go-redis/v9`** — `github.com/redis/go-redis` — Go Redis client with Cluster, Pipeline, Lua script support
- **`redis-py`** — `github.com/redis/redis-py` — Python Redis client
- **Ristretto** — `github.com/dgraph-io/ristretto` — high-performance in-process Go cache (TinyLFU eviction)
- **Caffeine** — Java in-process cache (W-TinyLFU); reference for eviction policy design
- **Probabilistic early expiry** — Vattani, Chiusano, Marchetti-Spaccamela (2015) — original PER paper
- **MDN — HTTP caching** — `developer.mozilla.org/en-US/docs/Web/HTTP/Caching` — headers reference
- **Cloudflare Cache-Tag** — `developers.cloudflare.com/cache/how-to/purge-cache/purge-by-tags`
- **Fastly Surrogate-Key** — `developer.fastly.com/reference/http/http-headers/Surrogate-Key`
- **`aioredis`** — async Python Redis client for high-concurrency warming scripts
