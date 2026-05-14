---
name: Zero-Trust Architecture
slug: zero-trust-architecture
category: 06-security-and-compliance
proficiency: advanced
description: >
  Design and implement Zero Trust architecture across identity, device, network,
  application, and data planes. Covers BeyondCorp principles, NIST SP 800-207,
  Identity-Aware Proxy (IAP) for application access, SPIFFE/SPIRE workload
  identity for service-to-service mTLS, OPA/Cedar policy engines for
  continuous authorization, HashiCorp Vault SSH CA and dynamic secrets for
  privileged access, just-in-time (JIT) access provisioning, device posture
  evaluation, and Kubernetes Zero Trust (no implicit pod-to-pod trust).
  Replaces perimeter-based VPN security with cryptographic identity verification
  at every access decision point.
tags:
  - zero-trust
  - beyondcorp
  - ztna
  - spiffe
  - spire
  - identity-aware-proxy
  - opa
  - vault
  - jit-access
  - device-posture
  - mtls
  - continuous-authorization
status: published
---

## Principles

### 1. The Network Is Always Hostile — Location Grants No Trust
The traditional perimeter model trusts anything inside the corporate network.
Zero Trust rejects this entirely: **an attacker who has compromised one machine
is already inside the perimeter**. Every access request — from any network
location, including internal — must be authenticated, authorised, and verified
against device health before access is granted. The question is not "is this
request from inside the network?" but "can this identity, on this device,
access this resource right now?"

### 2. Identity Is the New Perimeter — for Both Humans and Workloads
Zero Trust has two identity planes:
- **Human identity**: the person's verified identity (SSO/IdP) plus the
  device they are using (MDM posture, certificate)
- **Workload identity**: a cryptographic SPIFFE SVID tied to the service's
  Kubernetes ServiceAccount, not its IP address

Both must be verified on every request. IP addresses are ephemeral and
spoofable; cryptographic certificates bound to a known identity are not.

### 3. Least Privilege Is Dynamic, Not Static
A role that grants "read access to all databases" is not least privilege — it
is a static approximation of least privilege. True least privilege is
**just-in-time (JIT)**: the engineer requests access to a specific database for
a specific reason for a limited time window. The access is approved, granted,
recorded, and automatically revoked. No standing permissions means no
persistent credential to steal.

### 4. Every Access Decision Must Be Logged and Auditable
In a perimeter model, access inside the network is largely invisible. In Zero
Trust, every proxy hop, every policy evaluation, every SSH session, every
database query is logged with the identity of the requester, the device
fingerprint, the resource accessed, and the policy that permitted it. This is
not optional — it is what makes Zero Trust auditable to compliance frameworks
(SOC 2, ISO 27001, FedRAMP).

### 5. Continuous Verification — Not Just at Login
An authenticated session that lasts 8 hours is not Zero Trust — the user's
device may have been compromised 20 minutes after login. Continuous verification
re-evaluates context at every sensitive operation: is the device still healthy?
Has the user's risk score changed? Is the session still within the allowed
time window? Short-lived tokens (15 minute expiry) with silent refresh enforce
this without friction on the user.

---

## Implementation Patterns

### Pattern A: Identity-Aware Proxy (IAP) as the Access Control Plane
All application traffic flows through a proxy that terminates TLS, verifies the
user's identity token (JWT from an IdP), checks device posture against MDM
signals, evaluates the OPA access policy, and only then forwards the request.
The application itself needs no auth logic — it trusts only requests from the
proxy with the verified identity in a header. Google BeyondCorp, Cloudflare
Access, and Pomerium implement this pattern.

### Pattern B: SPIFFE/SPIRE for Workload-to-Workload mTLS
The SPIRE agent running on each Kubernetes node issues short-lived X.509 SVIDs
(SPIFFE Verifiable Identity Documents) to pods based on their ServiceAccount
and namespace. Envoy sidecars (or Cilium) present these certificates on every
outbound connection. The receiving service validates the SVID against the SPIFFE
trust bundle — no static API keys, no IP-based firewall rules.

### Pattern C: OPA Policy Engine for Continuous Authorisation
Access decisions are expressed as Rego policies evaluated by OPA on every
request. Inputs include: the verified identity (from the JWT claims), the
device posture score (from MDM), the resource being accessed, and the time of
day. Policies are version-controlled, tested in CI, and deployed without
application code changes.

### Pattern D: HashiCorp Vault SSH CA for Zero Standing Privileges
Engineers never have persistent SSH keys. Instead, Vault acts as an SSH
Certificate Authority. An engineer authenticates to Vault (via SSO), requests
a short-lived SSH certificate (valid for 1–4 hours), and uses it to access the
target host. The host trusts Vault's CA public key, not any individual user's
key. Every certificate issuance is logged. After expiry, no access is possible.

### Pattern E: JIT Access with Approval Workflow
For privileged operations (production database access, cluster admin), the
engineer submits a time-bounded access request with a justification. An approval
flow (automated for pre-approved patterns, human for exceptions) grants a
short-lived role binding. After the time window, the binding is automatically
revoked. The entire lifecycle is logged.

---

## Anti-Patterns

| Anti-Pattern | Consequence | Fix |
|---|---|---|
| VPN as Zero Trust ("we have VPN, we're secure") | VPN grants broad network access on authentication; lateral movement trivial once inside | Replace VPN with IAP + ZTNA; access is per-application, not per-network |
| Long-lived service account keys (e.g., GCP SA JSON, AWS IAM keys) | Static credential exfiltration = persistent compromise | Replace with Workload Identity Federation (OIDC) or instance metadata; zero long-lived keys |
| Static SSH keys for engineers or CI/CD | Key compromise = unlimited access until key manually rotated | Vault SSH CA; short-lived certificates; no static keys stored anywhere |
| "Trust but verify" once at login | Compromised session persists for hours after device compromise | Short-lived tokens (15 min); continuous posture re-evaluation; device health in every policy decision |
| Flat Kubernetes network (no NetworkPolicy) | Any pod can reach any other pod; lateral movement after pod escape | Default-deny NetworkPolicy + Cilium L7 + SPIFFE mTLS in service mesh |
| IAP that only checks identity, not device posture | BYOD with compromised personal device bypasses corporate security | Include device certificate (MDM-enrolled) as a required signal in every access policy |
| Standing admin access to production | Admin credentials available 24/7; stolen credentials = catastrophic | JIT access via Vault or Teleport; break-glass emergency only with full audit |
| OPA policies stored only in the application repo | Policy changes require application deployment; slow response to incidents | Deploy OPA as a sidecar or cluster-wide bundle server; policies are a separate deployment unit |

---

## Code Templates

### Template 1 — Go: Identity-Aware Proxy Middleware
```go
// iap/middleware.go — validates JWT identity + device posture, injects verified claims
package iap

import (
    "context"
    "crypto/tls"
    "encoding/json"
    "fmt"
    "net/http"
    "strings"
    "time"

    "github.com/golang-jwt/jwt/v5"
    "go.opentelemetry.io/otel/attribute"
    "go.opentelemetry.io/otel/trace"
)

type Claims struct {
    jwt.RegisteredClaims
    Email       string   `json:"email"`
    Groups      []string `json:"groups"`
    DeviceID    string   `json:"device_id"`
    DeviceTrust string   `json:"device_trust"` // "managed" | "unmanaged" | "unknown"
    RiskScore   float64  `json:"risk_score"`   // 0.0 (clean) – 1.0 (compromised)
}

type IAPConfig struct {
    JWKSURL         string
    Issuer          string
    Audience        string
    MaxRiskScore    float64 // reject requests above this risk threshold
    RequiredGroups  []string
    DeviceTrustReq  string  // "managed" for high-security apps
}

func Middleware(cfg IAPConfig, policyClient PolicyClient) func(http.Handler) http.Handler {
    keyFunc := buildJWKSKeyFunc(cfg.JWKSURL)

    return func(next http.Handler) http.Handler {
        return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
            span := trace.SpanFromContext(r.Context())

            // 1. Extract and verify JWT
            raw := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
            if raw == "" {
                raw = r.Header.Get("X-Forwarded-User-Token") // set by upstream proxy
            }
            claims, err := parseAndValidateClaims(raw, keyFunc, cfg.Issuer, cfg.Audience)
            if err != nil {
                span.AddEvent("auth.failed", trace.WithAttributes(attribute.String("reason", err.Error())))
                http.Error(w, "Unauthorized", http.StatusUnauthorized)
                return
            }

            // 2. Device posture check
            if cfg.DeviceTrustReq == "managed" && claims.DeviceTrust != "managed" {
                http.Error(w, "Device not managed — enrol in MDM to access this resource", http.StatusForbidden)
                return
            }
            if claims.RiskScore > cfg.MaxRiskScore {
                http.Error(w, "Device risk score too high — contact IT security", http.StatusForbidden)
                return
            }

            // 3. Continuous OPA policy check
            allowed, err := policyClient.Allow(r.Context(), PolicyInput{
                Subject:  claims.Email,
                Groups:   claims.Groups,
                Resource: r.URL.Path,
                Action:   r.Method,
                DeviceID: claims.DeviceID,
                RiskScore: claims.RiskScore,
            })
            if err != nil || !allowed {
                span.AddEvent("policy.denied")
                http.Error(w, "Forbidden", http.StatusForbidden)
                return
            }

            // 4. Inject verified identity into downstream request headers
            r = r.WithContext(context.WithValue(r.Context(), contextKeyIdentity, claims))
            r.Header.Set("X-Verified-User",   claims.Email)
            r.Header.Set("X-Verified-Groups", strings.Join(claims.Groups, ","))
            r.Header.Set("X-Device-ID",        claims.DeviceID)
            // Remove the raw token — downstream apps must not re-validate
            r.Header.Del("Authorization")

            span.SetAttributes(
                attribute.String("user.email",    claims.Email),
                attribute.String("device.id",     claims.DeviceID),
                attribute.Float64("device.risk",  claims.RiskScore),
            )
            next.ServeHTTP(w, r)
        })
    }
}

func parseAndValidateClaims(raw string, keyFunc jwt.Keyfunc, issuer, audience string) (*Claims, error) {
    token, err := jwt.ParseWithClaims(raw, &Claims{}, keyFunc,
        jwt.WithIssuer(issuer),
        jwt.WithAudience(audience),
        jwt.WithExpirationRequired(),
    )
    if err != nil || !token.Valid {
        return nil, fmt.Errorf("invalid token: %w", err)
    }
    claims, ok := token.Claims.(*Claims)
    if !ok {
        return nil, fmt.Errorf("invalid claims type")
    }
    // Reject tokens older than 15 minutes regardless of exp claim
    if time.Since(claims.IssuedAt.Time) > 15*time.Minute {
        return nil, fmt.Errorf("token too old: issued %v ago", time.Since(claims.IssuedAt.Time))
    }
    return claims, nil
}

type contextKey string
const contextKeyIdentity contextKey = "verified_identity"

func IdentityFromContext(ctx context.Context) *Claims {
    v, _ := ctx.Value(contextKeyIdentity).(*Claims)
    return v
}
```

### Template 2 — OPA Rego: Zero Trust Access Policy
```rego
# policies/zero_trust/access.rego
package zero_trust.access

import future.keywords.if
import future.keywords.in

# Default deny — Zero Trust default
default allow := false

# ── Resource classification ────────────────────────────────────────────────
resource_tier := "critical" if {
    glob.match("/admin/**", [], input.resource)
} else := "sensitive" if {
    glob.match("/api/v*/orders/**", [], input.resource)
    glob.match("/api/v*/payments/**", [], input.resource)
} else := "standard"

# ── Allow rule: standard resources ────────────────────────────────────────
allow if {
    resource_tier == "standard"
    is_authenticated
    device_healthy
    input.action in {"GET", "HEAD", "OPTIONS"}
}

# ── Allow rule: sensitive resources ────────────────────────────────────────
allow if {
    resource_tier == "sensitive"
    is_authenticated
    device_managed           # requires MDM-enrolled device
    has_required_group("engineers")
    not session_expired
}

# ── Allow rule: critical resources ────────────────────────────────────────
allow if {
    resource_tier == "critical"
    is_authenticated
    device_managed
    has_required_group("platform-admins")
    jit_access_active        # requires approved JIT session
    not session_expired
    business_hours           # break-glass access during incidents handled separately
}

# ── Helper rules ───────────────────────────────────────────────────────────
is_authenticated if {
    input.subject != ""
    regex.match(`^[^@]+@company\.com$`, input.subject)
}

device_healthy if {
    input.risk_score < 0.3   # low risk score from MDM/EDR
}

device_managed if {
    input.device_trust == "managed"
    device_healthy
}

has_required_group(group) if {
    group in input.groups
}

session_expired if {
    time.now_ns() > (input.issued_at_ns + (15 * 60 * 1000000000))
}

jit_access_active if {
    some grant in data.jit_grants
    grant.subject == input.subject
    grant.resource_pattern != ""
    glob.match(grant.resource_pattern, [], input.resource)
    time.now_ns() >= grant.valid_from_ns
    time.now_ns() <= grant.valid_until_ns
}

business_hours if {
    [hour, _, _] := time.clock([time.now_ns(), "Africa/Johannesburg"])
    hour >= 8
    hour < 18
}

# ── Audit metadata (always returned) ──────────────────────────────────────
reason := msg if {
    not allow
    resource_tier == "critical"
    not jit_access_active
    msg := "Critical resource requires active JIT access grant"
} else := msg if {
    not allow
    not device_managed
    msg := sprintf("Device not managed (trust=%v, risk=%.2f) — enrol in MDM",
                   [input.device_trust, input.risk_score])
} else := "Access granted" if {
    allow
} else := "Access denied by default policy"
```

### Template 3 — HCL: HashiCorp Vault SSH CA + Dynamic Database Secrets
```hcl
# vault/ssh_ca.tf — Vault SSH Certificate Authority for zero standing privileges

resource "vault_mount" "ssh" {
  path = "ssh"
  type = "ssh"
  description = "SSH Certificate Authority — short-lived certs, no static keys"
}

resource "vault_ssh_secret_backend_ca" "main" {
  backend              = vault_mount.ssh.path
  generate_signing_key = true   # Vault generates and owns the CA key pair
}

# Role: engineers can SSH to production hosts for max 4 hours
resource "vault_ssh_secret_backend_role" "engineer_prod" {
  backend                 = vault_mount.ssh.path
  name                    = "engineer-production"
  key_type                = "ca"
  allow_user_certificates = true
  default_user            = "ec2-user"
  allowed_users           = "ec2-user,ubuntu"
  allowed_extensions      = "permit-pty,permit-port-forwarding"
  ttl                     = "4h"
  max_ttl                 = "8h"
  # Certificate extensions — restrict what the cert permits
  default_extensions = {
    "permit-pty"              = ""
    "permit-user-rc"          = ""
  }
}

# Role: CI/CD pipeline gets 5-minute certs (deploy operations only)
resource "vault_ssh_secret_backend_role" "cicd" {
  backend                 = vault_mount.ssh.path
  name                    = "cicd-deploy"
  key_type                = "ca"
  allow_user_certificates = true
  default_user            = "deploy"
  allowed_users           = "deploy"
  ttl                     = "5m"
  max_ttl                 = "5m"
}

# Dynamic database secrets — Vault creates ephemeral DB credentials on demand
resource "vault_database_secrets_mount" "postgres" {
  path = "database"

  postgresql {
    name            = "orders-db"
    plugin_name     = "postgresql-database-plugin"
    connection_url  = "postgresql://{{username}}:{{password}}@postgres:5432/orders"
    username        = var.vault_db_admin_user
    password        = var.vault_db_admin_pass
    allowed_roles   = ["readonly", "readwrite"]
  }
}

resource "vault_database_secret_backend_role" "readonly" {
  backend = vault_database_secrets_mount.postgres.path
  name    = "readonly"
  db_name = "orders-db"
  # Vault creates a real PostgreSQL user with this statement; revokes after TTL
  creation_statements = [
    "CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';",
    "GRANT SELECT ON ALL TABLES IN SCHEMA public TO \"{{name}}\";",
  ]
  revocation_statements = ["DROP ROLE IF EXISTS \"{{name}}\";"]
  default_ttl = "1h"
  max_ttl     = "4h"
}
```

### Template 4 — YAML + Shell: SPIFFE/SPIRE Workload Identity in Kubernetes
```yaml
# spire-server-config.hcl (ConfigMap) — trust domain and node attestation
server {
  bind_address     = "0.0.0.0"
  bind_port        = "8081"
  trust_domain     = "company.internal"
  data_dir         = "/run/spire/data"
  log_level        = "INFO"

  ca_ttl           = "24h"
  default_svid_ttl = "1h"   # SVIDs rotate every hour; short-lived = less blast radius
}

plugins {
  DataStore "sql" { plugin_data { database_type = "sqlite3"
                                   connection_string = "/run/spire/data/datastore.sqlite3" } }

  NodeAttestor "k8s_psat" {   # Kubernetes Projected Service Account Token attestation
    plugin_data {
      clusters = { "k8s-prod" = { service_account_allow_list = ["spire:spire-agent"] } }
    }
  }

  KeyManager "disk" { plugin_data { keys_path = "/run/spire/data/keys.json" } }

  Notifier "k8s_bundle" {     # push CA bundle to Kubernetes ConfigMap for mesh consumption
    plugin_data { namespace = "spire" }
  }
}
```

```yaml
# spire-registration — register order-service workload identity
# Each entry maps a Kubernetes workload to a SPIFFE ID
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterSPIFFEID
metadata:
  name: order-service-identity
spec:
  spiffeIDTemplate: "spiffe://company.internal/ns/{{ .PodMeta.Namespace }}/sa/{{ .PodSpec.ServiceAccountName }}"
  podSelector:
    matchLabels:
      app: order-service
  namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: production
  ttl: 1h
```

```bash
# Verify workload gets an SVID and inspect it
kubectl exec -n production deploy/order-service -- \
  /opt/spire/bin/spire-agent api fetch x509 \
  --socketPath /run/spire/sockets/agent.sock \
  | openssl x509 -noout -text \
  | grep -E "Subject:|URI:|Not After"

# Expected output:
# Subject: C=US, O=SPIRE
# URI:SAN: spiffe://company.internal/ns/production/sa/order-service
# Not After: [1 hour from now]
```

### Template 5 — Python: Continuous Authorisation Middleware (FastAPI)
```python
# zero_trust/continuous_authz.py — re-verify identity + device posture on every request
from __future__ import annotations
import time
import httpx
from functools import wraps
from fastapi import Request, HTTPException, status
from typing import Callable, Any

OPA_URL = "http://opa-sidecar:8181/v1/data/zero_trust/access/allow"

async def evaluate_policy(request: Request, identity: dict) -> tuple[bool, str]:
    """Send the request context to OPA and get an allow/deny decision."""
    async with httpx.AsyncClient(timeout=0.5) as client:
        response = await client.post(OPA_URL, json={
            "input": {
                "subject":       identity["email"],
                "groups":        identity.get("groups", []),
                "resource":      request.url.path,
                "action":        request.method,
                "device_trust":  identity.get("device_trust", "unknown"),
                "device_id":     identity.get("device_id", ""),
                "risk_score":    identity.get("risk_score", 1.0),
                "issued_at_ns":  int(identity["iat"]) * 1_000_000_000,
            }
        })
        result = response.json()
        return result.get("result", False), result.get("reason", "")


def require_zero_trust(resource_hint: str | None = None):
    """
    Decorator for FastAPI route handlers that enforces Zero Trust policy.
    Re-evaluates the policy on EVERY invocation — not just at login.
    """
    def decorator(func: Callable[..., Any]) -> Callable[..., Any]:
        @wraps(func)
        async def wrapper(request: Request, *args: Any, **kwargs: Any) -> Any:
            # Identity is injected by the IAP middleware upstream
            identity = getattr(request.state, "identity", None)
            if not identity:
                raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED,
                                    detail="No verified identity — request must pass through IAP")

            # Re-check token age on every sensitive call (not just at session start)
            token_age_s = time.time() - identity.get("iat", 0)
            if token_age_s > 900:  # 15 minutes
                raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED,
                                    detail="Token expired — re-authenticate")

            # Evaluate OPA policy with full context
            try:
                allowed, reason = await evaluate_policy(request, identity)
            except httpx.TimeoutException:
                # Policy engine unavailable — fail closed (deny access)
                raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                                    detail="Policy engine unavailable — failing closed")

            if not allowed:
                raise HTTPException(
                    status_code=status.HTTP_403_FORBIDDEN,
                    detail=reason or "Access denied by Zero Trust policy",
                    headers={"X-Policy-Reason": reason},
                )
            return await func(request, *args, **kwargs)
        return wrapper
    return decorator


# Usage in a FastAPI route:
# @router.delete("/api/v1/orders/{order_id}")
# @require_zero_trust()
# async def cancel_order(request: Request, order_id: str):
#     identity = request.state.identity
#     return await order_service.cancel(order_id, cancelled_by=identity["email"])
```

### Template 6 — Terraform: Cloudflare Zero Trust Access Application
```hcl
# cloudflare_ztna.tf — Cloudflare Access (ZTNA) for internal app without VPN

# Identity provider — company SSO (OIDC)
resource "cloudflare_access_identity_provider" "company_sso" {
  account_id = var.cloudflare_account_id
  name       = "Company SSO"
  type       = "oidc"
  config {
    client_id            = var.sso_client_id
    client_secret        = var.sso_client_secret
    auth_url             = "https://sso.company.com/oauth/authorize"
    token_url            = "https://sso.company.com/oauth/token"
    certs_url            = "https://sso.company.com/.well-known/jwks.json"
    scopes               = ["openid", "email", "profile", "groups"]
    email_claim_name     = "email"
    groups_attribute_name = "groups"
  }
}

# Device posture check — require Warp client (MDM-managed device)
resource "cloudflare_device_posture_rule" "require_warp" {
  account_id  = var.cloudflare_account_id
  name        = "Warp Client Active"
  type        = "warp"
  description = "Require Cloudflare WARP client (MDM-managed device)"
  schedule    = "5m"    # re-evaluate posture every 5 minutes
  expiration  = "15m"   # posture result expires after 15 minutes
}

# Access policy — group membership + managed device
resource "cloudflare_access_policy" "engineers_managed_device" {
  account_id     = var.cloudflare_account_id
  name           = "Engineers with Managed Device"
  decision       = "allow"
  precedence     = 1

  include {
    group = [cloudflare_access_group.engineers.id]
  }
  require {
    device_posture = [cloudflare_device_posture_rule.require_warp.id]
  }
  exclude {
    email_domain = ["contractor.external.com"]  # contractors use separate policy
  }
}

# Protected application — internal order management dashboard
resource "cloudflare_access_application" "order_dashboard" {
  account_id             = var.cloudflare_account_id
  name                   = "Order Management Dashboard"
  domain                 = "orders-internal.company.com"
  type                   = "self_hosted"
  session_duration       = "15m"         # short session — re-auth every 15 min
  auto_redirect_to_identity = true
  http_only_cookie_attribute = true
  same_site_cookie_attribute = "strict"

  cors_headers {
    allowed_methods = ["GET", "POST"]
    allowed_origins = ["https://orders-internal.company.com"]
    allow_credentials = true
    max_age = 300
  }
}

resource "cloudflare_access_application_policy_association" "order_dashboard" {
  account_id     = var.cloudflare_account_id
  application_id = cloudflare_access_application.order_dashboard.id
  policy_id      = cloudflare_access_policy.engineers_managed_device.id
  precedence     = 1
}
```

---

## Decision Matrix

| Scenario | Zero Trust Control | Implementation |
|---|---|---|
| Replace VPN for remote employee access | ZTNA via IAP (Cloudflare Access, Pomerium, Google IAP) | Per-application access; identity + device posture; no network-level access |
| Service-to-service authentication in K8s | SPIFFE/SPIRE SVIDs + mTLS (Istio/Cilium) | Cryptographic workload identity; no API keys; auto-rotated certificates |
| Engineer SSH to production | Vault SSH CA with short-lived certificates | 1–4 h cert TTL; no standing key; full audit in Vault audit log |
| Database access for engineers | Vault dynamic secrets (PostgreSQL role) | Ephemeral username/password; auto-revoked after TTL; no shared credentials |
| Privileged operations (prod cluster admin) | JIT access workflow + approval + Vault | Time-bounded role; auto-revocation; break-glass emergency procedure |
| Application authorisation (not just authn) | OPA sidecar with Rego policies | Policy-as-code; version-controlled; continuous evaluation per request |
| Continuous device health verification | MDM posture in every policy evaluation | Device trust signal from Jamf/Intune fed into OPA/IAP on every request |
| Third-party/contractor access | Separate IdP integration + stricter posture policy | Contractors on separate ZTNA policy; more restrictive session duration; no MFA bypass |
| Lateral movement prevention post-breach | Default-deny NetworkPolicy + SPIFFE mTLS + OPA L7 | Even internal attacker cannot reach services without valid workload identity |

---

## Proficiency Levels

### Novice
- Understands why "inside the network = trusted" is a flawed assumption
- Knows the five Zero Trust pillars: Identity, Device, Network, Application, Data
- Can describe NIST SP 800-207 Zero Trust tenets at a high level
- Understands the difference between authentication (who are you) and authorisation (what can you do)

### Intermediate
- Configures an IAP (Cloudflare Access, Pomerium) to protect an internal application
- Writes OPA Rego policies for resource-level access control with device posture inputs
- Sets up Vault SSH CA; issues and verifies short-lived SSH certificates
- Configures SPIFFE/SPIRE ClusterSPIFFEID for Kubernetes workload identity
- Implements JWT validation middleware with device trust and risk score checks

### Advanced
- Designs a full Zero Trust architecture for a 500-person organisation across all five pillars
- Implements JIT access workflows with Vault dynamic secrets and approval automation
- Writes comprehensive OPA policy suites with unit tests (`opa test`)
- Configures SPIRE federation across multiple clusters/cloud providers
- Integrates device posture signals from MDM (Jamf, Intune) into the policy engine
- Builds a Zero Trust access audit pipeline (every access decision → SIEM)

### Expert
- Architects Zero Trust for a regulated environment (FedRAMP High, PCI-DSS Level 1)
- Designs a private Fulcio CA + SPIRE federation for air-gapped environments
- Implements Cedar (AWS's policy language) as an alternative to OPA for access decisions
- Defines and enforces a Zero Trust maturity model across an engineering organisation
- Contributes to SPIFFE/SPIRE, OPA, or Sigstore open-source toolchain
- Evaluates and migrates from legacy PAM solutions (CyberArk) to modern JIT workflows

---

## AI Prompts

```
You are a Zero Trust architecture expert. Our company has 300 engineers
accessing production systems via a traditional VPN. The security team wants
to migrate to Zero Trust. Design the migration plan: which systems to protect
first, how to run VPN and ZTNA in parallel during transition, what identity
provider integration is needed, how to incorporate device posture from our
Jamf MDM, and what the user experience looks like post-migration.
```

```
Acting as an OPA policy architect: I need to write a Rego policy for an
internal API that has three resource tiers (public, internal, admin). Access
rules are: public = authenticated users, internal = engineering group +
managed device, admin = platform-admins group + active JIT grant + business
hours. Show the complete policy module with tests using opa test, including
test cases for each allow and deny scenario.
```

```
Explain SPIFFE/SPIRE workload identity end to end in Kubernetes: how the
SPIRE agent attests the node, how pods get their SVID via the workload API,
how Envoy presents the SVID on outbound connections, and how the receiving
service validates the certificate. What happens when an SVID expires, and
how does rotation work without downtime?
```

```
I want to eliminate all static SSH keys and long-lived cloud credentials
from our 50-engineer team. Design a Vault-based privileged access solution:
Vault SSH CA configuration for Linux host access, Vault AWS secrets engine
for temporary IAM credentials, approval workflow for production access, and
how to handle emergency break-glass access when Vault is unavailable.
```

```
Compare OPA (Open Policy Agent with Rego) and Cedar (AWS's policy language)
for implementing Zero Trust access policies. What are the expressiveness
differences, the performance characteristics, the ecosystem maturity, and
the operational model? For a company already on AWS with IAM Identity Center,
which should they choose and why?
```

---

## References

- **NIST SP 800-207** — Zero Trust Architecture (nist.gov) — the definitive specification
- **Google BeyondCorp** — https://cloud.google.com/beyondcorp — original enterprise Zero Trust reference
- **SPIFFE/SPIRE** — https://spiffe.io; https://github.com/spiffe/spire — workload identity standard
- **HashiCorp Vault** — https://developer.hashicorp.com/vault — SSH CA, dynamic secrets, PKI
- **OPA (Open Policy Agent)** — https://www.openpolicyagent.org — policy engine + Rego language
- **Cedar policy language** — https://www.cedarpolicy.com — AWS open-source policy language
- **Pomerium** — https://www.pomerium.com — open-source IAP / ZTNA gateway
- **Cloudflare Zero Trust** — https://developers.cloudflare.com/cloudflare-one/ — ZTNA, Access
- **Teleport** — https://goteleport.com — SSH/K8s/DB access with certificate-based auth + audit
- **CISA Zero Trust Maturity Model** — https://www.cisa.gov/zero-trust-maturity-model
- **Ward, Evan** — *Zero Trust Networks* (O'Reilly, 2nd ed.) — Gilman & Barth
- **SysSkills cross-reference** — `authentication-and-authorization`, `kernel-security`,
  `service-mesh-network-policies`, `software-supply-chain-security`, `threat-modeling-stride`
