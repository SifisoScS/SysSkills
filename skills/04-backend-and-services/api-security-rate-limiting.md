---
name: API Security & Rate Limiting
slug: api-security-rate-limiting
category: 04-backend-and-services
proficiency: advanced
description: >
  Secure APIs against the OWASP API Security Top 10 and implement production-grade
  rate limiting using token bucket, sliding window, and fixed window algorithms.
  Covers JWT validation middleware, API key lifecycle management, HMAC request
  signing, Redis-backed distributed rate limiters, bot detection, and DDoS
  mitigation patterns for Go, TypeScript, and Python services.
tags:
  - api-security
  - rate-limiting
  - jwt
  - oauth2
  - hmac
  - owasp
  - token-bucket
  - sliding-window
  - redis
  - middleware
  - bot-detection
status: complete
---

## Principles

### OWASP API Security Top 10 (2023)
| # | Risk | Core Concern |
|---|------|-------------|
| API1 | Broken Object Level Authorization (BOLA) | Horizontal privilege escalation via ID manipulation |
| API2 | Broken Authentication | Weak tokens, no expiry, missing revocation |
| API3 | Broken Object Property Level Authorization | Over-exposing fields; mass assignment |
| API4 | Unrestricted Resource Consumption | No rate limits, no payload size caps, no timeout |
| API5 | Broken Function Level Authorization | Vertical escalation (user calls admin endpoint) |
| API6 | Unrestricted Access to Sensitive Business Flows | No bot/abuse controls on high-value flows |
| API7 | Server-Side Request Forgery (SSRF) | API fetches attacker-controlled URLs |
| API8 | Security Misconfiguration | Default creds, verbose errors, CORS wildcard |
| API9 | Improper Inventory Management | Shadow APIs, deprecated v1 still live |
| API10 | Unsafe Consumption of APIs | Trusting third-party API responses without validation |

### Rate Limiting Algorithms

**Fixed Window**
```
|--- window (60s) ---|--- window (60s) ---|
 ████████████ 100     ████ 40
```
Simple; suffers from burst at window boundary (100 at :59 + 100 at :00 = 200 in 1s).

**Sliding Window Log**
```
Keep timestamps of all requests in last N seconds.
Count = entries in [now - window, now].
```
Accurate; high memory (one entry per request).

**Sliding Window Counter (approximate)**
```
count = prev_window_count × (remaining fraction of prev window) + curr_window_count
```
Low memory; ~0.003% error rate; best balance for production.

**Token Bucket**
```
Tokens refill at rate r/s up to capacity b.
Each request consumes 1 token.
Burst allowed up to b tokens.
```
Allows controlled bursts; natural fit for API clients that batch requests.

**Leaky Bucket**
```
Requests enter a fixed-size queue; processed at constant rate.
Excess requests dropped.
```
Smooths traffic absolutely; no burst tolerance.

### Defence-in-Depth Layers
```
Internet → CDN/WAF (IP rate limit, geo-block, bot challenge)
         → API Gateway (global rate limit, auth, routing)
         → Service mesh (mTLS, per-service policy)
         → Application middleware (per-user/tenant limit, BOLA check)
         → Business logic (operation-specific abuse prevention)
```
No single layer is sufficient. Each layer catches what the previous misses.

### JWT Security Properties
- **Short expiry** (≤15 min access token, ≤24h refresh token) — limits damage window
- **Asymmetric signing** (RS256/ES256) — verification without sharing private key
- **`jti` claim + deny-list** — enables immediate revocation before expiry
- **Audience (`aud`) validation** — prevents token re-use across services
- **`nbf` (not before)** — prevents clock-skew replay in distributed systems

---

## Implementation Patterns

### 1. JWT Validation Middleware
Validate signature, expiry, issuer, audience, and token revocation on every request. Never trust the payload before verifying the signature.

### 2. Redis-Backed Sliding Window Rate Limiter
A Lua script executed atomically in Redis implements the sliding window counter. Lua ensures count + expiry operations are race-free without distributed locks.

### 3. Token Bucket Rate Limiter (in-process)
For single-instance services or when Redis is not available, an in-process token bucket using atomic operations provides accurate per-key limiting.

### 4. API Key Lifecycle
Store only hashed API keys (SHA-256); serve the plaintext once on creation. Rotate by issuing a new key with a grace period during which both are valid.

### 5. HMAC Request Signing
Signed requests bind payload + timestamp + path to a secret key. Prevents replay attacks (timestamp window), content tampering, and key exposure (signature is not the key).

### 6. BOLA / Authorisation Middleware
Object-level authorisation must be checked in every handler, not just at the route level. A generic middleware that enforces resource ownership reduces the risk of forgetting.

---

## Anti-Patterns

| Anti-Pattern | Why It Fails | Correction |
|---|---|---|
| **Rate limit on IP only** | Shared IPs (NAT, offices) block legitimate users; attackers rotate IPs | Rate limit on authenticated identity (user ID, API key, tenant) as primary key |
| **JWT verified client-side** | Client can forge claims if signature not checked server-side | Always verify signature + claims server-side on every request |
| **Long-lived JWTs (days/weeks)** | Stolen token usable for entire lifetime | Access token ≤15 min; refresh token with rotation and revocation |
| **Symmetric JWT for multi-service** | Any service that can verify can also forge | Use RS256/ES256; only auth service holds private key |
| **Rate limit in application DB** | DB becomes bottleneck under load; limit defeats itself | Redis with Lua script for atomic, low-latency rate counting |
| **No rate limit on auth endpoints** | Credential stuffing, brute-force | Strict limits on `/login`, `/token`, `/forgot-password` (5 req/min) |
| **Plaintext API keys stored** | DB breach exposes all keys | Store HMAC-SHA256(key); return plaintext once on creation |
| **CORS `Access-Control-Allow-Origin: *`** | Any site can make credentialed cross-origin requests | Explicit allowlist of trusted origins |
| **Verbose error messages** | Stack traces, DB errors reveal internal structure | Generic error codes; detailed logs server-side only |
| **No payload size limit** | Large payloads cause OOM / DoS | Cap at gateway and application layer (e.g., 1 MB for REST JSON) |
| **Missing `aud` validation** | Token issued for service A accepted by service B | Always validate `aud` matches the current service identifier |

---

## Code Templates

### Template 1 — Go JWT Validation Middleware (RS256 + Revocation)

```go
package middleware

import (
	"context"
	"crypto/rsa"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/redis/go-redis/v9"
)

type Claims struct {
	jwt.RegisteredClaims
	UserID   string   `json:"sub"`
	TenantID string   `json:"tid"`
	Roles    []string `json:"roles"`
}

type JWTMiddleware struct {
	publicKey  *rsa.PublicKey
	audience   string
	issuer     string
	revokeList *redis.Client // jti deny-list
}

func NewJWTMiddleware(pubKey *rsa.PublicKey, audience, issuer string, redis *redis.Client) *JWTMiddleware {
	return &JWTMiddleware{publicKey: pubKey, audience: audience, issuer: issuer, revokeList: redis}
}

func (m *JWTMiddleware) Authenticate(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, err := extractBearer(r)
		if err != nil {
			writeError(w, http.StatusUnauthorized, "missing_token")
			return
		}

		claims, err := m.validate(r.Context(), raw)
		if err != nil {
			writeError(w, http.StatusUnauthorized, "invalid_token")
			return
		}

		ctx := context.WithValue(r.Context(), ctxKeyClaims{}, claims)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

func (m *JWTMiddleware) validate(ctx context.Context, raw string) (*Claims, error) {
	token, err := jwt.ParseWithClaims(raw, &Claims{}, func(t *jwt.Token) (any, error) {
		if _, ok := t.Method.(*jwt.SigningMethodRSA); !ok {
			return nil, fmt.Errorf("unexpected signing method: %v", t.Header["alg"])
		}
		return m.publicKey, nil
	},
		jwt.WithAudience(m.audience),
		jwt.WithIssuer(m.issuer),
		jwt.WithExpirationRequired(),
		jwt.WithLeeway(10*time.Second), // clock skew tolerance
	)
	if err != nil {
		return nil, err
	}

	claims, ok := token.Claims.(*Claims)
	if !ok || !token.Valid {
		return nil, errors.New("invalid claims")
	}

	// Check token revocation deny-list (jti)
	if claims.ID != "" {
		revoked, err := m.revokeList.Exists(ctx, "jti:revoked:"+claims.ID).Result()
		if err == nil && revoked > 0 {
			return nil, errors.New("token revoked")
		}
	}

	// Enforce max token age regardless of expiry claim
	if time.Since(claims.IssuedAt.Time) > 15*time.Minute {
		return nil, errors.New("token too old")
	}

	return claims, nil
}

// RevokeToken adds a jti to the deny-list until its natural expiry.
func (m *JWTMiddleware) RevokeToken(ctx context.Context, claims *Claims) error {
	ttl := time.Until(claims.ExpiresAt.Time)
	if ttl <= 0 {
		return nil // already expired
	}
	return m.revokeList.Set(ctx, "jti:revoked:"+claims.ID, 1, ttl).Err()
}

func extractBearer(r *http.Request) (string, error) {
	h := r.Header.Get("Authorization")
	if !strings.HasPrefix(h, "Bearer ") {
		return "", errors.New("no bearer token")
	}
	return strings.TrimPrefix(h, "Bearer "), nil
}

type ctxKeyClaims struct{}

func ClaimsFromContext(ctx context.Context) (*Claims, bool) {
	c, ok := ctx.Value(ctxKeyClaims{}).(*Claims)
	return c, ok
}

func writeError(w http.ResponseWriter, status int, code string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	fmt.Fprintf(w, `{"error":"%s"}`, code)
}
```

---

### Template 2 — Redis Sliding Window Rate Limiter (Go + Lua)

```go
package ratelimit

import (
	"context"
	"fmt"
	"net/http"
	"strconv"
	"time"

	"github.com/redis/go-redis/v9"
)

// slidingWindowLua counts requests in [now-window, now] using two counters.
// Returns {allowed (0/1), current_count, retry_after_ms}.
var slidingWindowLua = redis.NewScript(`
local key_curr = KEYS[1]
local key_prev = KEYS[2]
local now      = tonumber(ARGV[1])   -- unix ms
local window   = tonumber(ARGV[2])   -- window ms
local limit    = tonumber(ARGV[3])

-- fraction of the previous window still within our sliding window
local prev_ttl = tonumber(redis.call('PTTL', key_prev))
local prev_weight = 0
if prev_ttl > 0 then
    prev_weight = prev_ttl / window
end

local prev_count = tonumber(redis.call('GET', key_prev) or 0)
local curr_count = tonumber(redis.call('GET', key_curr) or 0)

local count = math.floor(prev_count * prev_weight + curr_count)

if count >= limit then
    -- return: blocked, count, retry_after_ms
    return {0, count, math.ceil(prev_ttl > 0 and prev_ttl or window)}
end

-- Increment current window counter
redis.call('INCR', key_curr)
redis.call('PEXPIRE', key_curr, window * 2)   -- keep for two windows
return {1, count + 1, 0}
`)

type SlidingWindowLimiter struct {
	rdb    *redis.Client
	limit  int
	window time.Duration
}

func NewSlidingWindowLimiter(rdb *redis.Client, limit int, window time.Duration) *SlidingWindowLimiter {
	return &SlidingWindowLimiter{rdb: rdb, limit: limit, window: window}
}

type Result struct {
	Allowed    bool
	Count      int
	RetryAfter time.Duration
}

func (l *SlidingWindowLimiter) Allow(ctx context.Context, key string) (Result, error) {
	now := time.Now()
	windowMs := l.window.Milliseconds()

	// Two keys: current window slot and previous window slot
	slot := now.UnixMilli() / windowMs
	keyCurr := fmt.Sprintf("rl:{%s}:%d", key, slot)
	keyPrev := fmt.Sprintf("rl:{%s}:%d", key, slot-1)

	vals, err := slidingWindowLua.Run(ctx, l.rdb,
		[]string{keyCurr, keyPrev},
		now.UnixMilli(), windowMs, l.limit,
	).Int64Slice()
	if err != nil {
		// Fail open: allow request if Redis is unavailable
		return Result{Allowed: true}, err
	}

	return Result{
		Allowed:    vals[0] == 1,
		Count:      int(vals[1]),
		RetryAfter: time.Duration(vals[2]) * time.Millisecond,
	}, nil
}

// Middleware wraps an HTTP handler with per-identity rate limiting.
func (l *SlidingWindowLimiter) Middleware(keyFn func(*http.Request) string) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			key := keyFn(r)
			result, _ := l.Allow(r.Context(), key)

			w.Header().Set("X-RateLimit-Limit", strconv.Itoa(l.limit))
			w.Header().Set("X-RateLimit-Remaining", strconv.Itoa(max(0, l.limit-result.Count)))

			if !result.Allowed {
				w.Header().Set("Retry-After", strconv.Itoa(int(result.RetryAfter.Seconds())))
				w.Header().Set("X-RateLimit-Reset", strconv.FormatInt(
					time.Now().Add(result.RetryAfter).Unix(), 10))
				http.Error(w, `{"error":"rate_limit_exceeded"}`, http.StatusTooManyRequests)
				return
			}

			next.ServeHTTP(w, r)
		})
	}
}

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}
```

```go
// Wire up the middleware in main.go
func main() {
	rdb := redis.NewClient(&redis.Options{Addr: "redis:6379"})

	// Tier-based limits: anonymous, authenticated user, premium tenant
	anonLimiter  := ratelimit.NewSlidingWindowLimiter(rdb, 20,   time.Minute)
	userLimiter  := ratelimit.NewSlidingWindowLimiter(rdb, 200,  time.Minute)
	tenantLimiter := ratelimit.NewSlidingWindowLimiter(rdb, 5000, time.Minute)

	mux := http.NewServeMux()
	mux.Handle("/api/", http.StripPrefix("/api", apiRouter()))

	// Apply tightest limit globally first, then relax per identity
	handler := anonLimiter.Middleware(func(r *http.Request) string {
		// Prefer authenticated identity; fall back to IP
		if claims, ok := middleware.ClaimsFromContext(r.Context()); ok {
			if claims.TenantID != "" {
				// Check tenant limit separately
				res, _ := tenantLimiter.Allow(r.Context(), "tenant:"+claims.TenantID)
				if !res.Allowed {
					return "blocked"
				}
			}
			return "user:" + claims.UserID
		}
		return "ip:" + r.RemoteAddr
	})(mux)

	http.ListenAndServe(":8080", handler)
}
```

---

### Template 3 — TypeScript API Key Middleware (Hashing + Rotation)

```typescript
// src/middleware/apiKey.ts
import { createHmac, timingSafeEqual } from 'crypto';
import { Request, Response, NextFunction } from 'express';
import { db } from '../db';
import { redis } from '../redis';

interface ApiKey {
  id: string;
  keyHash: string;
  tenantId: string;
  scopes: string[];
  expiresAt: Date | null;
  revokedAt: Date | null;
}

const KEY_PREFIX = 'sk_live_';
const HASH_ALGO  = 'sha256';
const CACHE_TTL  = 60; // seconds — cache validated keys to avoid DB on every request

function hashKey(raw: string): string {
  return createHmac(HASH_ALGO, process.env.API_KEY_HMAC_SECRET!)
    .update(raw)
    .digest('hex');
}

function safeCompare(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  return timingSafeEqual(Buffer.from(a), Buffer.from(b));
}

export async function apiKeyAuth(req: Request, res: Response, next: NextFunction) {
  const raw = req.headers['x-api-key'] as string | undefined;
  if (!raw || !raw.startsWith(KEY_PREFIX)) {
    return res.status(401).json({ error: 'missing_api_key' });
  }

  const hash = hashKey(raw);

  // Check Redis cache first (avoid DB lookup on every request)
  const cacheKey = `apikey:${hash}`;
  const cached = await redis.get(cacheKey);
  let apiKey: ApiKey | null = cached ? JSON.parse(cached) : null;

  if (!apiKey) {
    apiKey = await db<ApiKey>('api_keys')
      .where({ keyHash: hash })
      .whereNull('revokedAt')
      .first() ?? null;

    if (apiKey) {
      await redis.setex(cacheKey, CACHE_TTL, JSON.stringify(apiKey));
    }
  }

  if (!apiKey) {
    return res.status(401).json({ error: 'invalid_api_key' });
  }

  if (apiKey.expiresAt && new Date() > apiKey.expiresAt) {
    return res.status(401).json({ error: 'api_key_expired' });
  }

  req.tenant   = { id: apiKey.tenantId };
  req.apiKeyId = apiKey.id;
  req.scopes   = apiKey.scopes;
  next();
}

// API key issuance — called by key management endpoint
export async function issueApiKey(tenantId: string, scopes: string[], expiresInDays?: number) {
  const raw = KEY_PREFIX + randomBase62(32);
  const hash = hashKey(raw);

  await db('api_keys').insert({
    id:        randomUUID(),
    keyHash:   hash,
    tenantId,
    scopes:    JSON.stringify(scopes),
    expiresAt: expiresInDays
      ? new Date(Date.now() + expiresInDays * 86_400_000)
      : null,
  });

  // Return plaintext exactly once — never stored
  return { key: raw, hint: raw.slice(-4) }; // hint lets users identify key in UI
}

// Rotation: issue new key, old key valid for grace period
export async function rotateApiKey(oldKeyId: string, gracePeriodHours = 24) {
  const old = await db<ApiKey>('api_keys').where({ id: oldKeyId }).first();
  if (!old) throw new Error('key not found');

  const { key: newKey } = await issueApiKey(old.tenantId, old.scopes);

  // Schedule old key revocation after grace period
  await redis.set(
    `apikey:rotation:revoke:${oldKeyId}`,
    '1',
    'EX', gracePeriodHours * 3600,
  );

  return newKey;
}

function randomBase62(length: number): string {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  return Array.from({ length }, () => chars[Math.floor(Math.random() * chars.length)]).join('');
}

function randomUUID(): string {
  return crypto.randomUUID();
}
```

---

### Template 4 — HMAC Request Signing (Go server + TypeScript client)

```go
// server-side: Go HMAC request verification middleware
package middleware

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"time"
)

const (
	signatureHeader  = "X-Signature-SHA256"
	timestampHeader  = "X-Timestamp"
	maxClockSkew     = 5 * time.Minute
)

// HMACAuth validates that the request was signed with the tenant's secret.
// Signature = HMAC-SHA256(secret, "METHOD\nPATH\nTIMESTAMP\nBODY_HEX")
func HMACAuth(secretFn func(tenantID string) ([]byte, error)) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			tenantID := r.Header.Get("X-Tenant-ID")
			sigHex   := r.Header.Get(signatureHeader)
			tsStr    := r.Header.Get(timestampHeader)

			if tenantID == "" || sigHex == "" || tsStr == "" {
				http.Error(w, `{"error":"missing_signature_headers"}`, http.StatusUnauthorized)
				return
			}

			// Validate timestamp (replay prevention)
			tsMs, err := strconv.ParseInt(tsStr, 10, 64)
			if err != nil || time.Since(time.UnixMilli(tsMs)).Abs() > maxClockSkew {
				http.Error(w, `{"error":"timestamp_out_of_range"}`, http.StatusUnauthorized)
				return
			}

			// Read body (re-inject for downstream handlers)
			body, _ := io.ReadAll(io.LimitReader(r.Body, 10<<20)) // 10 MB max
			r.Body = io.NopCloser(bytes.NewReader(body))

			// Reconstruct signed string
			signed := fmt.Sprintf("%s\n%s\n%s\n%x", r.Method, r.URL.RequestURI(), tsStr, body)

			secret, err := secretFn(tenantID)
			if err != nil {
				http.Error(w, `{"error":"unknown_tenant"}`, http.StatusUnauthorized)
				return
			}

			mac := hmac.New(sha256.New, secret)
			mac.Write([]byte(signed))
			expected := hex.EncodeToString(mac.Sum(nil))

			if !hmac.Equal([]byte(sigHex), []byte(expected)) {
				http.Error(w, `{"error":"invalid_signature"}`, http.StatusUnauthorized)
				return
			}

			next.ServeHTTP(w, r)
		})
	}
}
```

```typescript
// client-side: TypeScript HMAC request signing
import { createHmac } from 'crypto';

interface SignedRequestInit extends RequestInit {
  body?: string;
}

export async function signedFetch(
  url: string,
  tenantId: string,
  secret: string,
  init: SignedRequestInit = {},
): Promise<Response> {
  const method    = (init.method ?? 'GET').toUpperCase();
  const body      = init.body ?? '';
  const timestamp = Date.now().toString();
  const parsedUrl = new URL(url);
  const path      = parsedUrl.pathname + parsedUrl.search;

  const bodyHex = Buffer.from(body).toString('hex');
  const signed  = `${method}\n${path}\n${timestamp}\n${bodyHex}`;

  const signature = createHmac('sha256', secret)
    .update(signed)
    .digest('hex');

  return fetch(url, {
    ...init,
    headers: {
      ...init.headers,
      'Content-Type':       'application/json',
      'X-Tenant-ID':        tenantId,
      'X-Timestamp':        timestamp,
      'X-Signature-SHA256': signature,
    },
    body: body || undefined,
  });
}

// Usage:
// const resp = await signedFetch('https://api.internal/payments', tenantId, secret, {
//   method: 'POST',
//   body: JSON.stringify({ amount: 100, currency: 'ZAR' }),
// });
```

---

### Template 5 — BOLA / Object-Level Authorisation Middleware (Go)

```go
package middleware

import (
	"context"
	"net/http"

	"github.com/go-chi/chi/v5"
)

// ResourceOwner checks that the authenticated user owns the resource in the URL.
// Usage: r.Use(middleware.ResourceOwner("userId", fetchOwnerFn))
type OwnerFetcher func(ctx context.Context, resourceID string) (ownerID string, err error)

func ResourceOwner(urlParam string, fetchOwner OwnerFetcher) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			claims, ok := ClaimsFromContext(r.Context())
			if !ok {
				http.Error(w, `{"error":"unauthenticated"}`, http.StatusUnauthorized)
				return
			}

			resourceID := chi.URLParam(r, urlParam)
			if resourceID == "" {
				next.ServeHTTP(w, r) // no resource ID in path; skip check
				return
			}

			ownerID, err := fetchOwner(r.Context(), resourceID)
			if err != nil {
				http.Error(w, `{"error":"not_found"}`, http.StatusNotFound)
				return
			}

			// Allow resource owner OR admin role
			if ownerID != claims.UserID && !hasRole(claims.Roles, "admin") {
				// Return 404, not 403 — don't reveal resource existence to non-owners
				http.Error(w, `{"error":"not_found"}`, http.StatusNotFound)
				return
			}

			next.ServeHTTP(w, r)
		})
	}
}

// ScopeRequired enforces that an API key or token carries a required scope.
func ScopeRequired(scope string) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			claims, ok := ClaimsFromContext(r.Context())
			if !ok {
				http.Error(w, `{"error":"unauthenticated"}`, http.StatusUnauthorized)
				return
			}
			if !hasRole(claims.Roles, scope) {
				http.Error(w, `{"error":"insufficient_scope"}`, http.StatusForbidden)
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}

func hasRole(roles []string, target string) bool {
	for _, r := range roles {
		if r == target {
			return true
		}
	}
	return false
}
```

---

### Template 6 — Tiered Rate Limit Configuration + Bot Detection Headers

```go
// config/ratelimits.go — centralised tier definitions
package config

import "time"

type RateLimitTier struct {
	RequestsPerMinute int
	BurstMultiplier   float64 // token bucket burst = requests × multiplier
}

var RateLimitTiers = map[string]RateLimitTier{
	"anonymous": {RequestsPerMinute: 20,    BurstMultiplier: 1.0},
	"free":      {RequestsPerMinute: 100,   BurstMultiplier: 1.5},
	"pro":       {RequestsPerMinute: 1_000, BurstMultiplier: 2.0},
	"enterprise":{RequestsPerMinute: 10_000,BurstMultiplier: 3.0},
}

// Stricter limits for high-value / abuse-prone endpoints
var EndpointOverrides = map[string]RateLimitTier{
	"/api/v1/auth/login":          {RequestsPerMinute: 5,  BurstMultiplier: 1.0},
	"/api/v1/auth/forgot-password":{RequestsPerMinute: 3,  BurstMultiplier: 1.0},
	"/api/v1/payments":            {RequestsPerMinute: 30, BurstMultiplier: 1.5},
}

// BotDetection examines request characteristics and returns a risk score 0.0-1.0.
func BotRiskScore(r interface{ Header(string) string }) float64 {
	score := 0.0

	// Missing standard browser headers suggests automated client
	if r.Header("Accept") == "" {
		score += 0.3
	}
	if r.Header("Accept-Language") == "" {
		score += 0.2
	}
	if r.Header("User-Agent") == "" {
		score += 0.4
	}

	// Known bot/scraper user-agent patterns (simplified)
	ua := r.Header("User-Agent")
	botPatterns := []string{"curl/", "python-requests", "Go-http-client", "wget/", "scrapy/"}
	for _, p := range botPatterns {
		if len(ua) >= len(p) && ua[:len(p)] == p {
			score += 0.3
			break
		}
	}

	if score > 1.0 {
		return 1.0
	}
	return score
}
```

```yaml
# Kong API Gateway rate limiting plugin config (declarative)
# Attach to a route or service; backed by Redis for multi-instance
_format_version: "3.0"
services:
  - name: payments-api
    url: http://payments-service.payments.svc.cluster.local
    plugins:
      - name: rate-limiting-advanced
        config:
          limit: [1000]
          window_size: [60]
          identifier: consumer
          strategy: sliding
          sync_rate: 10          # sync with Redis every 10 requests
          redis:
            host: redis.redis.svc.cluster.local
            port: 6379
          hide_client_headers: false
          retry_after_jitter_max: 5
      - name: bot-detection
        config:
          allow:
            - curl
          deny:
            - python-requests
            - scrapy
      - name: request-size-limiting
        config:
          allowed_payload_size: 1     # 1 MB max body
      - name: response-transformer
        config:
          remove:
            headers:
              - X-Powered-By
              - Server               # hide server fingerprint
```

---

## Decision Matrix

| Scenario | Recommendation | Rationale |
|---|---|---|
| Single-instance service, low traffic | In-process token bucket (`golang.org/x/time/rate`) | No Redis dependency; simple; sufficient |
| Multi-instance service, shared limits | Redis sliding window with Lua script | Atomic across instances; ~1ms overhead |
| Per-user AND per-tenant limits | Two separate limiters, check tenant first | Tenant limit protects noisy-neighbour; user limit protects fairness |
| Auth endpoints (login, OTP) | Fixed window, very tight (5 req/min) | Brute-force prevention; fixed window acceptable here (worst case 10 req/2 min) |
| Webhook receivers | HMAC request signing | Verify caller identity without shared session; replay prevention via timestamp |
| Public API with API keys | HMAC-SHA256 stored hash + Redis cache validation | No plaintext in DB; cache avoids DB on every request |
| Service-to-service internal API | mTLS (service mesh) + JWT with short expiry | No need for API keys; SPIFFE identity is the principal |
| Mobile / SPA clients | RS256 JWT (asymmetric) + refresh token rotation | Private key never leaves auth server; clients can verify without secrets |
| Need to block a compromised token before expiry | `jti` deny-list in Redis with TTL = token remaining lifetime | O(1) revocation check; entry self-deletes when token would have expired |
| High-volume write endpoint | Leaky bucket (constant rate) + async processing | Smooths write rate; prevents DB overload; client sees 202 Accepted |

---

## Proficiency Levels

### Level 1 — Aware
- Understands JWT structure (header.payload.signature) and why signature verification matters
- Knows the difference between authentication (who are you?) and authorisation (what can you do?)
- Can read the OWASP API Security Top 10 and identify which risks apply to a given API
- Understands rate limiting exists and why 429 Too Many Requests is returned

### Level 2 — Practitioner
- Implements JWT validation middleware (signature, expiry, audience, issuer) in Go or TypeScript
- Configures a Redis-backed rate limiter with per-user keys and correct headers (`X-RateLimit-*`)
- Stores API keys as HMAC-SHA256 hashes; issues plaintext only once
- Implements BOLA checks in route handlers; understands why 404 > 403 for non-owners
- Sets CORS policy to explicit origin allowlist; removes `Server` and `X-Powered-By` headers

### Level 3 — Advanced
- Designs tiered rate limit strategy (anonymous / free / pro / enterprise) with endpoint overrides
- Implements HMAC request signing for webhook verification with replay prevention
- Builds `jti` deny-list for immediate JWT revocation; manages cache TTL correctly
- Configures API gateway plugins (Kong, Nginx, Envoy) for rate limiting, bot detection, payload size limits
- Implements token bucket with burst allowance for clients that legitimately batch requests
- Writes `AnalysisTemplate` (Argo Rollouts) or Prometheus alert for rate-limit-triggered anomalies

### Level 4 — Expert
- Designs multi-layer defence: CDN WAF → gateway → service mesh → application middleware, each with distinct responsibilities
- Implements adaptive rate limiting: dynamically tightens limits when downstream error rates rise
- Builds credential stuffing detection: cross-user IP analysis, device fingerprinting, velocity checks
- Designs API key federation across microservices: central key registry, distributed cache invalidation, per-service scope enforcement
- Runs red-team exercises against own API; maps OWASP API Security Top 10 to automated test suite

---

## AI Prompts

**Generate a rate limiter for a service**
```
Write a [Go/TypeScript/Python] Redis-backed sliding window rate limiter middleware for
an HTTP service with the following tiers:
- Anonymous: [N] requests per minute
- Authenticated user: [N] requests per minute
- Tenant: [N] requests per minute (checked independently)

Use a Lua script for atomic Redis operations.
Include correct HTTP response headers: X-RateLimit-Limit, X-RateLimit-Remaining,
X-RateLimit-Reset, Retry-After.
Fail open (allow request) if Redis is unavailable.
```

**Audit an API for OWASP API Security Top 10**
```
Audit this API definition / code for OWASP API Security Top 10 (2023) vulnerabilities:
[paste OpenAPI spec or route handler code]

For each finding: identify the OWASP category, describe the specific vulnerability,
provide a code or config remediation snippet, and rate severity (Critical/High/Medium/Low).
Focus especially on: BOLA (object-level auth checks), missing rate limits on auth endpoints,
mass assignment (property-level auth), and CORS misconfiguration.
```

**Write HMAC signing for a webhook**
```
Write server-side HMAC-SHA256 webhook signature verification middleware in [Go/TypeScript]
and the corresponding client-side signing logic.
Signed string: METHOD + "\n" + PATH + "\n" + UNIX_TIMESTAMP_MS + "\n" + HEX(body)
Replay window: ±5 minutes.
Use timing-safe comparison.
Include: how to register the secret per tenant, where to store it, and how to rotate it.
```

**Design API key lifecycle**
```
Design a complete API key lifecycle system for a B2B SaaS API:
- Key format: sk_live_ prefix + 32 random base62 chars
- Storage: HMAC-SHA256 hash only; plaintext returned once
- Scopes: [list your scopes]
- Expiry: optional, configurable per key
- Rotation: new key issued + old key valid for [N] hour grace period
- Revocation: immediate, cache invalidation within 60s
Output: DB schema (SQL), issuance endpoint, rotation endpoint, and validation middleware.
```

**Add JWT revocation**
```
Add immediate JWT revocation to this existing JWT validation middleware:
[paste existing middleware code]

Use Redis as a jti deny-list.
The TTL for each deny-list entry = remaining lifetime of the token (so entries self-expire).
Add a RevokeToken(claims) function that writes to the deny-list.
Ensure the deny-list check happens after signature verification (not before).
```

---

## References

- **OWASP API Security Top 10 (2023)** — `owasp.org/API-Security`
- **RFC 7519 — JSON Web Tokens** — JWT specification; claims, expiry, signing algorithms
- **RFC 6750 — Bearer Token Usage** — Authorization header format
- **RFC 7617 — The 'Basic' HTTP Authentication Scheme** — baseline for comparison
- **`golang-jwt/jwt`** — `github.com/golang-jwt/jwt/v5` — Go JWT library
- **`redis/go-redis`** — `github.com/redis/go-redis/v9` — Go Redis client with scripting support
- **Kong rate-limiting-advanced plugin** — `docs.konghq.com` — sliding window, Redis-backed
- **OWASP Cheat Sheet — REST Security** — `cheatsheetseries.owasp.org`
- **OWASP Cheat Sheet — Authentication** — credential storage, session management
- **`golang.org/x/time/rate`** — in-process token bucket for single-instance services
- **Cloudflare WAF & Rate Limiting** — enterprise-grade layer-7 rate limiting reference
- **Have I Been Pwned API** — credential stuffing: check breach databases during login
