---
name: "Secure Authentication & Authorization"
slug: authentication-and-authorization
category: "06-security-and-compliance"
proficiency: Architect
description: "Design and implement modern, Zero Trust-aligned authentication and authorization systems using Passkeys, OAuth 2.1, OIDC, and fine-grained policy engines."
tags: [authentication, authorization, zero-trust, oauth2, oidc, passkeys, jwt, rbac, abac, rebac, opa]
status: published
---

# Secure Authentication & Authorization

## Principles

**Never Trust, Always Verify**
Every request must be authenticated and authorized regardless of network location. Internal services are not implicitly trusted — treat every call as if it comes from an untrusted network.

**Least Privilege + Just-In-Time Access**
Grant only the permissions required for the specific task, scoped to the shortest viable time window. Avoid standing permissions where ephemeral grants can work.

**Assume Breach**
Design authorization controls under the assumption that perimeter defenses have already failed. Authorization must hold even if an attacker is inside the network.

**Defense in Depth**
Layer authentication mechanisms: something you have (device/passkey), something you know (PIN/password), something you are (biometrics). No single control should be the last line of defense.

**Make Secure the Easy Path**
Insecure patterns (long-lived tokens, localStorage, weak session cookies) are often the path of least resistance. Design libraries, SDKs, and scaffolding so that the secure option is also the easiest.

**Continuous Authentication**
Authentication is not a one-time gate at login. Risk signals (device posture, location anomaly, behaviour change) should trigger step-up authentication or session invalidation throughout a session.

---

## Implementation Patterns

### Pattern 1 — Passkeys (WebAuthn) First

Use Passkeys as the primary credential for consumer and internal apps. Passkeys are phishing-resistant, require no password storage, and bind the credential to the device and relying party.

Flow:
1. Registration: browser calls `navigator.credentials.create()` → authenticator generates keypair → public key stored server-side.
2. Authentication: server sends challenge → browser calls `navigator.credentials.get()` → authenticator signs challenge with private key → server verifies signature against stored public key.

Fallback: magic-link email OTP for device recovery; never fall back to passwords once passkeys are in use.

### Pattern 2 — OAuth 2.1 + OIDC for Federated Identity

Use OAuth 2.1 (which eliminates implicit flow and mandates PKCE) for delegated authorization. Use OIDC on top for identity assertion (ID token).

Key requirements:
- Authorization Code flow with PKCE for all client types
- `nonce` in ID token to prevent replay
- Short `access_token` TTL (5–15 min); rotate `refresh_token` on every use
- Validate `iss`, `aud`, `exp`, `nbf`, `iat` on every token

### Pattern 3 — Sender-Constrained Tokens (DPoP / mTLS)

Bearer tokens are reusable by any party that obtains them. Bind tokens to the client that requested them:

- **DPoP (RFC 9449)**: client generates ephemeral keypair per session, sends `DPoP` proof header with each request; server validates proof against `cnf.jkt` claim in token.
- **mTLS**: client certificate thumbprint bound to token via `cnf.x5t#S256` claim.

Use DPoP for browser and mobile clients; mTLS for service-to-service in a service mesh.

### Pattern 4 — Policy-as-Code Authorization

Externalize authorization decisions from application code into a Policy Decision Point (PDP):

```
Application → PDP (OPA / Casbin / Cedar) → policy evaluation → allow / deny
```

Policies are version-controlled, testable, and auditable separately from application code. The application sends an authorization query (subject, action, resource, context); the PDP returns a decision.

### Pattern 5 — Refresh Token Rotation + Revocation

Every refresh token use issues a new refresh token and invalidates the previous one. Detect token reuse: if an already-invalidated refresh token is presented, revoke the entire token family (detect stolen token).

Maintain a revocation list or use short-lived tokens with a token introspection endpoint for real-time validity checks.

---

## Anti-Patterns

| Anti-Pattern | Why It's Dangerous | Fix |
|---|---|---|
| Long-lived JWTs (`exp` > 1 hour) | Stolen token grants long-lived access; no revocation path | Access tokens ≤ 15 min; use refresh token rotation |
| Storing tokens in `localStorage` | Accessible to any JS on the page (XSS pivot) | Use `httpOnly`, `Secure`, `SameSite=Strict` cookies |
| Implicit OAuth flow | Exposes tokens in URL fragments, browser history, referrer headers | Authorization Code + PKCE for all clients |
| Rolling your own crypto or JWT library | Subtle implementation flaws in signature validation, algorithm confusion | Use audited libraries; validate `alg` header matches expected algorithm explicitly |
| All-or-nothing RBAC with broad roles | "Admin" role grants far more than needed; blast radius of compromise is total | Fine-grained roles or ReBAC; scope permissions to resources not role labels |
| IP-based trust | IP spoofing, VPN, NAT, cloud-egress sharing — IP is not identity | Remove all IP allowlists from trust decisions; use cryptographic identity |
| Storing passwords when passkeys are viable | Passwords are phishable, reused, and require hashing infrastructure | Migrate to passkeys; if passwords must exist, use Argon2id with appropriate cost parameters |
| Symmetric JWT signing (HS256) in distributed systems | All verifying services must share the secret — any compromise breaks everything | Use RS256 or ES256 (asymmetric); distribute only public keys |

---

## Code Templates

### Go — Zero Trust Middleware (DPoP + JWT + OPA)

```go
// middleware/auth.go
func ZeroTrustMiddleware(pdp PolicyClient, keys jwk.Set) func(http.Handler) http.Handler {
    return func(next http.Handler) http.Handler {
        return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
            // 1. Extract and validate DPoP proof
            dpopProof := r.Header.Get("DPoP")
            if err := validateDPoP(dpopProof, r.Method, r.URL.String()); err != nil {
                http.Error(w, "invalid DPoP proof", http.StatusUnauthorized)
                return
            }

            // 2. Parse and validate JWT (sig, exp, iss, aud, cnf.jkt matches DPoP key)
            token := extractBearerToken(r)
            claims, err := validateJWT(token, keys, dpopProof)
            if err != nil {
                http.Error(w, "invalid token", http.StatusUnauthorized)
                return
            }

            // 3. Ask PDP: can this subject perform this action on this resource?
            allowed, err := pdp.IsAllowed(r.Context(), PolicyInput{
                Subject:  claims.Subject,
                Action:   r.Method,
                Resource: r.URL.Path,
                Context:  extractRiskSignals(r),
            })
            if err != nil || !allowed {
                http.Error(w, "forbidden", http.StatusForbidden)
                return
            }

            next.ServeHTTP(w, r.WithContext(withIdentity(r.Context(), claims)))
        })
    }
}
```

### TypeScript — Passkey Registration (WebAuthn / @simplewebauthn/browser)

```typescript
import { startRegistration, startAuthentication } from '@simplewebauthn/browser';

// Registration
async function registerPasskey(email: string): Promise<void> {
    const opts = await fetch('/api/auth/passkey/register/options', {
        method: 'POST',
        body: JSON.stringify({ email }),
        headers: { 'Content-Type': 'application/json' },
    }).then(r => r.json());

    const credential = await startRegistration(opts);

    await fetch('/api/auth/passkey/register/verify', {
        method: 'POST',
        body: JSON.stringify(credential),
        headers: { 'Content-Type': 'application/json' },
    });
}

// Authentication
async function authenticatePasskey(): Promise<void> {
    const opts = await fetch('/api/auth/passkey/authenticate/options', {
        method: 'POST',
    }).then(r => r.json());

    const assertion = await startAuthentication(opts);

    await fetch('/api/auth/passkey/authenticate/verify', {
        method: 'POST',
        body: JSON.stringify(assertion),
        headers: { 'Content-Type': 'application/json' },
    });
}
```

### OPA Policy — Fine-Grained Resource Authorization (Rego)

```rego
package authz

import future.keywords.if
import future.keywords.in

default allow := false

allow if {
    # Subject must have the required role for this resource type
    some role in data.roles[input.subject]
    role in required_roles[input.resource_type][input.action]
}

allow if {
    # Or: subject is the owner of the resource
    data.resources[input.resource_id].owner == input.subject
    input.action in {"read", "update", "delete"}
}

required_roles := {
    "order": {
        "read":   {"viewer", "editor", "admin"},
        "update": {"editor", "admin"},
        "delete": {"admin"},
    },
}
```

---

## Decision Matrix

| Requirement | Recommended | Alternative | Avoid |
|---|---|---|---|
| Consumer web / mobile app | Passkeys + OAuth 2.1 PKCE | Magic link OTP | Password-only login |
| Internal enterprise SSO | OIDC + SAML bridge (if legacy IdP) | Keycloak / ZITADEL | Custom session cookies |
| Service-to-service (cloud) | mTLS + short-lived service tokens | OAuth 2.0 Client Credentials | Static API keys |
| Service-to-service (on-prem) | mTLS via service mesh (Istio/Linkerd) | JWT with asymmetric signing | Shared secrets |
| High-security (finance/health) | Passkeys + hardware key (YubiKey) + DPoP | FIDO2 + step-up MFA | SMS OTP |
| Fine-grained resource authorization | OPA / Cedar / Casbin (ReBAC/ABAC) | Custom middleware rules | Broad role checks in SQL queries |
| Multi-tenant SaaS | OIDC per tenant + organization claims | Auth0 / Okta with org feature | Shared user table with tenant_id filter |

---

## Proficiency Levels

### Awareness
- Can explain OAuth2 authorization code flow, the difference between authentication and authorization, and why JWTs expire.
- Knows OWASP Broken Authentication vulnerabilities by name.
- Can integrate a pre-built auth library (NextAuth, Passport.js) without customization.

### Applied
- Implements PKCE flow from scratch; configures short-lived tokens with refresh rotation.
- Sets secure cookie attributes (`httpOnly`, `Secure`, `SameSite`), understands CSRF trade-offs.
- Configures MFA; integrates an OIDC provider (Keycloak, Auth0) into a web application.
- Writes RBAC middleware that enforces role checks at route level.

### Master
- Designs token issuance and validation architecture across multiple microservices with asymmetric JWT signing.
- Implements refresh token rotation with reuse detection and family revocation.
- Integrates DPoP or mTLS for sender-constrained tokens.
- Deploys OPA as a sidecar or centralized PDP; writes and tests Rego policies.
- Understands WebAuthn ceremony in detail (challenge binding, authenticator attestation, credential storage).

### Architect
- Designs enterprise-wide Zero Trust identity fabric: continuous authentication, risk-adaptive step-up, cross-domain federation, policy-as-code governance.
- Makes and documents security vs UX vs performance trade-off decisions (e.g., token TTL vs revocation latency).
- Defines identity standards across teams: token formats, signing key rotation schedules, PDP deployment topology.
- Evaluates and selects identity platforms (Ory, ZITADEL, Keycloak, commercial) against organizational compliance requirements (SOC 2, ISO 27001, NIST 800-63-4).

---

## AI Prompts

**Explain the concept:**
> Explain Zero Trust authentication to a senior engineer in under 200 words, focusing on the core invariant and why perimeter-based trust fails.

**Review an implementation:**
> Review this JWT validation middleware for security flaws. Pay particular attention to algorithm confusion attacks, missing claim validation, and token replay vectors: [paste code]

**Compare options:**
> Compare Passkeys (WebAuthn) vs Magic Links vs TOTP for a B2C e-commerce app with 500k users. Consider phishing resistance, account recovery complexity, and adoption friction.

**Design a system:**
> Design an authorization architecture for a multi-tenant SaaS platform where each tenant can define custom roles. The system must support resource-level permissions (not just route-level), be auditable, and not require application redeployment when policies change.

**Threat model:**
> Threat model the OAuth 2.1 authorization code flow for a single-page application. Identify the top 3 attack vectors specific to SPAs and recommend mitigations for each.

---

## References

**Standards & Specifications**
- [WebAuthn Level 3 — W3C Specification](https://www.w3.org/TR/webauthn-3/)
- [OAuth 2.1 Draft — IETF](https://datatracker.ietf.org/doc/html/draft-ietf-oauth-v2-1)
- [RFC 9449 — DPoP (Demonstrating Proof of Possession)](https://datatracker.ietf.org/doc/html/rfc9449)
- [NIST SP 800-63-4 — Digital Identity Guidelines](https://pages.nist.gov/800-63-4/)
- [NIST SP 800-207 — Zero Trust Architecture](https://doi.org/10.6028/NIST.SP.800-207)

**Compliance Mappings**
- OWASP ASVS 4.0 — V2 (Authentication), V3 (Session Management), V4 (Access Control)
- CIS Controls v8 — Control 5 (Account Management), Control 6 (Access Control Management)

**Tools & Libraries**
- [Open Policy Agent (OPA)](https://www.openpolicyagent.org/) — policy-as-code PDP
- [Keycloak](https://www.keycloak.org/) / [ZITADEL](https://zitadel.com/) — open-source OIDC providers
- [@simplewebauthn/browser + server](https://simplewebauthn.dev/) — WebAuthn library (TypeScript)
- [go-jose](https://github.com/go-jose/go-jose) — JWT/JWK library for Go
- [Casbin](https://casbin.org/) — authorization library supporting RBAC, ABAC, ReBAC
