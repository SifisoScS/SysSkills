---
name: Secrets Management & Rotation
slug: secrets-management-rotation
category: 06-security-and-compliance
proficiency: advanced
description: >
  Design and operate production secrets management: HashiCorp Vault dynamic
  secrets (database, AWS, PKI), Vault Agent sidecar injection, External Secrets
  Operator provider matrix, zero-downtime secret rotation patterns (shadow
  secret, dual-active), envelope encryption, SOPS for GitOps, secret scanning
  in CI (gitleaks, truffleHog), and break-glass emergency access procedures.
tags:
  - secrets-management
  - vault
  - external-secrets-operator
  - dynamic-secrets
  - secret-rotation
  - pki
  - envelope-encryption
  - sops
  - gitleaks
  - break-glass
status: complete
---

## Principles

### Secret Classification
| Class | Examples | Rotation Frequency | Storage |
|---|---|---|---|
| **Dynamic** | DB credentials, AWS keys (Vault-generated) | Each lease (minutes–hours) | Vault only; never persisted |
| **Long-lived static** | API keys, signing keys, TLS certs | 30–90 days | Vault KV v2 with versioning |
| **Short-lived PKI** | mTLS certs, SSH certificates | Hours (auto-renewed) | Vault PKI engine |
| **Infrastructure** | RDS master password, K8s service account tokens | Automated via ESO + Vault | AWS Secrets Manager / Vault |
| **Git-resident encrypted** | Secrets in GitOps repos | Per-commit; key rotation yearly | SOPS + age/KMS |

### The Secrets Zero Problem
Every secrets management system faces a bootstrap question: the application needs a credential to retrieve its credentials. Solutions in order of security:

1. **Kubernetes Service Account + IRSA/Workload Identity** — pod's SA token exchanged for cloud role; no stored secret at all
2. **Vault Kubernetes Auth** — pod's SA JWT exchanged for Vault token; no pre-shared secret
3. **Vault AppRole** — RoleID (public) + SecretID (single-use, response-wrapped); SecretID is ephemeral
4. **Environment variable injection** — CI/CD injects secrets at deploy time; risk of leaking via process list
5. **Hardcoded credentials** — never acceptable

### Dynamic Secrets vs Static Secrets
```
Static secret lifecycle:
  Create → Store → Rotate (manual or scheduled) → Risk window = entire lifetime

Dynamic secret lifecycle:
  Request → Generate (unique per request) → TTL expires → Auto-revoked
  Risk window = TTL (minutes)
  Compromise = revoke that specific lease, not all credentials
```

Dynamic secrets eliminate the rotation problem: each application instance gets a unique, short-lived credential. A breach exposes only that instance's credential, which auto-expires.

### Envelope Encryption
```
Data Key (DEK) — random, generated per secret, used to encrypt the plaintext
Key Encryption Key (KEK) — stored in KMS (AWS KMS, GCP KMS, Vault Transit)

Encrypt:  plaintext → [DEK] → ciphertext
          DEK       → [KEK] → encrypted_DEK
          Store: { ciphertext, encrypted_DEK }

Decrypt:  encrypted_DEK → [KEK] → DEK
          ciphertext    → [DEK] → plaintext

Benefit: rotating KEK only requires re-encrypting DEK, not re-encrypting all data.
```

### Zero-Downtime Rotation Pattern (Dual-Active / Shadow Secret)
```
Phase 1: Add new credential alongside old (shadow)
  - Old credential: still valid, still in use
  - New credential: created, not yet used

Phase 2: Migrate consumers
  - Deploy new app version that reads new credential
  - Old credential still valid (both active simultaneously)

Phase 3: Revoke old credential
  - All consumers verified using new credential
  - Old credential revoked

Total downtime: zero
```

---

## Implementation Patterns

### 1. Vault Dynamic Database Secrets
Vault generates unique, short-lived PostgreSQL/MySQL credentials per request. When the TTL expires, Vault automatically revokes the credentials (drops the DB user). No human ever sees or stores a database password.

### 2. Vault PKI Engine — Short-Lived Certificates
Vault acts as an intermediate CA. Services request certificates with 24h TTL; cert-manager or Vault Agent auto-renews before expiry. mTLS everywhere with zero-rotation-ceremony overhead.

### 3. Vault Kubernetes Auth + Agent Sidecar
The Vault Agent sidecar (or Agent Injector) handles authentication and secret fetching transparently. Applications read secrets from a mounted file or environment variable — they never talk to Vault directly.

### 4. External Secrets Operator (ESO)
ESO bridges Kubernetes and external secret stores (Vault, AWS Secrets Manager, GCP Secret Manager, Azure Key Vault). Teams declare `ExternalSecret` CRs; ESO syncs and rotates. Applications use standard Kubernetes `Secret` objects.

### 5. SOPS for GitOps
SOPS encrypts specific values in YAML/JSON files using age keys or KMS. The encrypted file is safe to commit to Git. Flux decrypts at reconcile time using the age private key stored as a Kubernetes secret.

### 6. Secret Scanning in CI
Scan every commit and PR for accidentally committed secrets before they reach the main branch. Two complementary tools: `gitleaks` (pattern-based, fast, pre-commit hook) and `truffleHog` (entropy + regex, deeper scan of git history).

---

## Anti-Patterns

| Anti-Pattern | Why It Fails | Correction |
|---|---|---|
| **Secrets in environment variables** | Visible in `/proc/<pid>/environ`, process list, log dumps, child processes | Mount as files via Vault Agent or ESO; read once at startup |
| **Shared database credentials across services** | One breach exposes all services; rotation requires coordinating all consumers | Dynamic secrets: each service instance gets a unique credential |
| **Long TTL on dynamic secrets (days/weeks)** | Reduces benefit of dynamic secrets; extends breach window | DB creds: 1–4 hours max; AWS keys: 15–60 minutes |
| **Storing Vault root token anywhere** | Root token has unrestricted access; loss = full compromise | Generate root token only for break-glass; unseal key shares distributed |
| **Committing `.env` files to Git** | Git history is permanent; rotation doesn't help (history persists) | Add `.env*` to `.gitignore`; use pre-commit secret scanning hook |
| **Manual rotation without dual-active window** | Service outage during rotation (old revoked before new deployed) | Always shadow-secret rotation: add new → migrate → revoke old |
| **Certificate TTL > 90 days** | Long-lived certs; rotation requires downtime or complex coordination | 24h TTL with Vault Agent auto-renewal; cert-manager for Kubernetes |
| **Single unseal key holder** | Single point of failure for Vault unsealing | Shamir's Secret Sharing: N-of-M key shards; store in separate HSMs |
| **No secret scanning in CI** | Secrets leaked in PRs go undetected until breach | `gitleaks` pre-commit hook + `truffleHog` in CI on every PR |
| **ESO pulling from a single Vault namespace** | No blast-radius isolation between teams | Separate Vault namespaces or policies per team; ESO ClusterSecretStore scoped per team |

---

## Code Templates

### Template 1 — Vault Dynamic Database Secrets (HCL + Go)

```hcl
# vault/database.tf — Terraform configuration for Vault database engine

resource "vault_mount" "db" {
  path = "database"
  type = "database"
}

resource "vault_database_secret_backend_connection" "payments_postgres" {
  backend       = vault_mount.db.path
  name          = "payments-postgres"
  allowed_roles = ["payments-readonly", "payments-readwrite", "payments-migrator"]

  postgresql {
    connection_url = "postgresql://{{username}}:{{password}}@postgres.payments.svc.cluster.local:5432/payments"
    username       = "vault_manager"        # dedicated Vault management user
    password       = var.vault_db_password  # initial password only; Vault rotates its own creds
    disable_escaping = false
  }
}

# Read-only role: 1-hour TTL, no write access
resource "vault_database_secret_backend_role" "payments_readonly" {
  backend               = vault_mount.db.path
  name                  = "payments-readonly"
  db_name               = vault_database_secret_backend_connection.payments_postgres.name
  default_ttl           = 3600    # 1 hour
  max_ttl               = 7200    # 2 hours max renewal
  creation_statements   = [
    "CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}' IN ROLE payments_reader;",
  ]
  revocation_statements = [
    "REVOKE ALL ON SCHEMA public FROM \"{{name}}\"; DROP ROLE IF EXISTS \"{{name}}\";",
  ]
}

# Read-write role: 30-minute TTL (tighter window for write access)
resource "vault_database_secret_backend_role" "payments_readwrite" {
  backend             = vault_mount.db.path
  name                = "payments-readwrite"
  db_name             = vault_database_secret_backend_connection.payments_postgres.name
  default_ttl         = 1800   # 30 minutes
  max_ttl             = 3600
  creation_statements = [
    "CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}' IN ROLE payments_writer;",
  ]
  revocation_statements = [
    "REVOKE ALL ON SCHEMA public FROM \"{{name}}\"; DROP ROLE IF EXISTS \"{{name}}\";",
  ]
}

# Vault policy: allow payments service to read its own DB role
resource "vault_policy" "payments_service" {
  name = "payments-service"
  policy = <<EOT
path "database/creds/payments-readonly" {
  capabilities = ["read"]
}
path "database/creds/payments-readwrite" {
  capabilities = ["read"]
}
path "kv/data/payments/*" {
  capabilities = ["read"]
}
EOT
}
```

```go
// internal/vault/db.go — Go: fetch dynamic DB credentials and auto-renew lease
package vault

import (
	"context"
	"database/sql"
	"fmt"
	"log/slog"
	"time"

	vaultapi "github.com/hashicorp/vault/api"
	_ "github.com/lib/pq"
)

type DynamicDB struct {
	client *vaultapi.Client
	role   string
	dsn    func(user, pass string) string
	db     *sql.DB
	lease  *vaultapi.Secret
}

func NewDynamicDB(client *vaultapi.Client, role, host, dbName string) (*DynamicDB, error) {
	d := &DynamicDB{
		client: client,
		role:   role,
		dsn: func(user, pass string) string {
			return fmt.Sprintf("host=%s dbname=%s user=%s password=%s sslmode=require",
				host, dbName, user, pass)
		},
	}
	if err := d.renew(context.Background()); err != nil {
		return nil, err
	}
	go d.autoRenew()
	return d, nil
}

func (d *DynamicDB) DB() *sql.DB { return d.db }

func (d *DynamicDB) renew(ctx context.Context) error {
	secret, err := d.client.Logical().ReadWithContext(ctx,
		"database/creds/"+d.role)
	if err != nil {
		return fmt.Errorf("vault db creds: %w", err)
	}

	user := secret.Data["username"].(string)
	pass := secret.Data["password"].(string)

	newDB, err := sql.Open("postgres", d.dsn(user, pass))
	if err != nil {
		return err
	}
	if err := newDB.PingContext(ctx); err != nil {
		newDB.Close()
		return err
	}
	newDB.SetMaxOpenConns(20)
	newDB.SetMaxIdleConns(5)
	newDB.SetConnMaxLifetime(time.Duration(secret.LeaseDuration) * time.Second * 9 / 10)

	if d.db != nil {
		d.db.Close() // close old connection pool after replacing
	}
	d.db = newDB
	d.lease = secret
	slog.Info("vault db credentials renewed", "role", d.role, "ttl_s", secret.LeaseDuration)
	return nil
}

func (d *DynamicDB) autoRenew() {
	for {
		ttl := time.Duration(d.lease.LeaseDuration) * time.Second
		// Renew at 80% of TTL to avoid expiry under load
		time.Sleep(ttl * 4 / 5)
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		if err := d.renew(ctx); err != nil {
			slog.Error("vault db credential renewal failed", "err", err)
		}
		cancel()
	}
}
```

---

### Template 2 — Vault PKI Engine (Short-Lived mTLS Certs)

```hcl
# vault/pki.tf

# Intermediate CA — Vault acts as intermediate; root CA is offline HSM
resource "vault_mount" "pki_int" {
  path                      = "pki/int"
  type                      = "pki"
  default_lease_ttl_seconds = 86400      # 24 hours
  max_lease_ttl_seconds     = 2592000    # 30 days
}

# Generate CSR; sign with offline root CA; import signed cert
resource "vault_pki_secret_backend_intermediate_cert_request" "payments" {
  backend     = vault_mount.pki_int.path
  type        = "internal"
  common_name = "Payments Intermediate CA"
  key_type    = "ec"
  key_bits    = 384
}

resource "vault_pki_secret_backend_intermediate_set_signed" "payments" {
  backend     = vault_mount.pki_int.path
  certificate = var.signed_intermediate_cert   # signed by offline root CA
}

# Role: 24h service certificates for payments namespace
resource "vault_pki_secret_backend_role" "payments_service" {
  backend          = vault_mount.pki_int.path
  name             = "payments-service"
  ttl              = "24h"
  max_ttl          = "48h"
  key_type         = "ec"
  key_bits         = 256
  allow_subdomains = true
  allowed_domains  = ["payments.svc.cluster.local"]
  require_cn       = true
  server_flag      = true
  client_flag      = true   # client auth for mTLS
  no_store         = true   # don't store issued certs in Vault (privacy)
}

# cert-manager ClusterIssuer backed by Vault PKI
```

```yaml
# kubernetes/vault-pki-issuer.yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: vault-pki-issuer
spec:
  vault:
    server: https://vault.vault.svc.cluster.local
    path: pki/int/sign/payments-service
    auth:
      kubernetes:
        mountPath: /v1/auth/kubernetes
        role: cert-manager
        serviceAccountRef:
          name: cert-manager
---
# Certificate: 24h TLS cert for a service, auto-renewed by cert-manager
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: payments-tls
  namespace: payments
spec:
  secretName: payments-tls-cert
  issuerRef:
    name: vault-pki-issuer
    kind: ClusterIssuer
  duration: 24h
  renewBefore: 4h        # renew 4h before expiry
  commonName: payments-service.payments.svc.cluster.local
  dnsNames:
    - payments-service.payments.svc.cluster.local
    - payments-service
  usages:
    - digital signature
    - key encipherment
    - server auth
    - client auth
```

---

### Template 3 — Vault Agent Sidecar Injection (Kubernetes)

```yaml
# kubernetes/deployment-with-vault-agent.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payments-service
  namespace: payments
spec:
  template:
    metadata:
      annotations:
        # Vault Agent Injector annotations — renders secrets to /vault/secrets/
        vault.hashicorp.com/agent-inject: "true"
        vault.hashicorp.com/role: "payments-service"
        vault.hashicorp.com/agent-inject-status: "update"  # re-inject on secret change

        # Dynamic DB credentials — rendered as env-file format
        vault.hashicorp.com/agent-inject-secret-db: "database/creds/payments-readonly"
        vault.hashicorp.com/agent-inject-template-db: |
          {{- with secret "database/creds/payments-readonly" -}}
          DATABASE_USER={{ .Data.username }}
          DATABASE_PASSWORD={{ .Data.password }}
          DATABASE_URL=postgresql://{{ .Data.username }}:{{ .Data.password }}@postgres:5432/payments
          {{- end }}

        # Static KV secret
        vault.hashicorp.com/agent-inject-secret-config: "kv/data/payments/config"
        vault.hashicorp.com/agent-inject-template-config: |
          {{- with secret "kv/data/payments/config" -}}
          STRIPE_WEBHOOK_SECRET={{ .Data.data.stripe_webhook_secret }}
          ENCRYPTION_KEY={{ .Data.data.encryption_key }}
          {{- end }}

        # Pre-populate before main container starts (init container)
        vault.hashicorp.com/agent-pre-populate-only: "false"
        vault.hashicorp.com/agent-pre-populate: "true"
    spec:
      serviceAccountName: payments-service   # Vault auth uses this SA token
      containers:
        - name: payments
          image: ghcr.io/org/payments-service:latest
          command: ["/bin/sh", "-c"]
          args:
            - |
              # Source env-file rendered by Vault Agent
              export $(cat /vault/secrets/db | xargs)
              export $(cat /vault/secrets/config | xargs)
              exec /app/payments-service
          volumeMounts:
            - name: vault-secrets
              mountPath: /vault/secrets
              readOnly: true
```

```hcl
# vault/kubernetes-auth.tf — bind Kubernetes SA to Vault policy

resource "vault_auth_backend" "kubernetes" {
  type = "kubernetes"
}

resource "vault_kubernetes_auth_backend_config" "default" {
  backend            = vault_auth_backend.kubernetes.path
  kubernetes_host    = "https://kubernetes.default.svc"
  # Vault auto-discovers SA JWT and CA cert from mounted files
}

resource "vault_kubernetes_auth_backend_role" "payments_service" {
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "payments-service"
  bound_service_account_names      = ["payments-service"]
  bound_service_account_namespaces = ["payments"]
  token_ttl                        = 3600
  token_policies                   = ["payments-service"]
}
```

---

### Template 4 — External Secrets Operator (Multi-Provider)

```yaml
# eso/cluster-secret-store-vault.yaml
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: vault-backend
spec:
  provider:
    vault:
      server: https://vault.vault.svc.cluster.local
      path: kv
      version: v2
      auth:
        kubernetes:
          mountPath: kubernetes
          role: external-secrets-operator
          serviceAccountRef:
            name: external-secrets
            namespace: external-secrets
---
# eso/cluster-secret-store-aws.yaml
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: aws-secrets-manager
spec:
  provider:
    aws:
      service: SecretsManager
      region: eu-west-1
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets
            namespace: external-secrets
---
# eso/external-secret-payments.yaml
# Team creates this; ESO syncs it to a Kubernetes Secret
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: payments-secrets
  namespace: payments
spec:
  refreshInterval: 5m           # re-sync from Vault every 5 minutes
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: payments-app-secrets  # name of the Kubernetes Secret created
    creationPolicy: Owner
    deletionPolicy: Retain
    template:
      type: Opaque
      data:
        # Compose a connection string from individual Vault fields
        DATABASE_URL: "postgresql://{{ .username }}:{{ .password }}@postgres:5432/payments"
        STRIPE_KEY: "{{ .stripe_api_key }}"
  data:
    - secretKey: username
      remoteRef:
        key: payments/database
        property: username
    - secretKey: password
      remoteRef:
        key: payments/database
        property: password
    - secretKey: stripe_api_key
      remoteRef:
        key: payments/stripe
        property: api_key
---
# eso/push-secret.yaml — write a K8s Secret back to Vault (reverse sync)
apiVersion: external-secrets.io/v1alpha1
kind: PushSecret
metadata:
  name: payments-push-to-vault
  namespace: payments
spec:
  refreshInterval: 10m
  secretStoreRefs:
    - name: vault-backend
      kind: ClusterSecretStore
  selector:
    secret:
      name: payments-generated-key  # K8s Secret to push
  data:
    - match:
        secretKey: api_key
        remoteRef:
          remoteKey: payments/generated
          property: api_key
```

---

### Template 5 — SOPS Encryption for GitOps + Secret Rotation Script

```bash
#!/bin/bash
# scripts/sops-setup.sh — generate age key and configure SOPS for Flux

# Generate age key pair (one per cluster; private key stored as K8s secret)
age-keygen -o age.agekey
# Output: Public key: age1xxxxxxxx...

# Store private key as Flux-readable Kubernetes secret
kubectl create secret generic sops-age \
  --namespace=flux-system \
  --from-file=age.agekey=./age.agekey

# Delete local copy of private key after storing in cluster
shred -u age.agekey

echo "Add public key to .sops.yaml:"
cat <<'EOF'
# .sops.yaml (committed to repo root)
creation_rules:
  - path_regex: .*/secrets/.*\.yaml$
    age: age1xxxxxxxx...    # cluster public key
    encrypted_regex: ^(data|stringData)$   # only encrypt data fields
EOF
```

```yaml
# Example: encrypted secret in GitOps repo (safe to commit)
# Encrypted with: sops --encrypt --in-place secrets/payments-config.yaml
apiVersion: v1
kind: Secret
metadata:
  name: payments-config
  namespace: payments
type: Opaque
stringData:
  stripe_key: ENC[AES256_GCM,data:abc123...,iv:...,tag:...,type:str]
  db_password: ENC[AES256_GCM,data:xyz789...,iv:...,tag:...,type:str]
sops:
  age:
    - recipient: age1xxxxxxxx...
      enc: |
        -----BEGIN AGE ENCRYPTED FILE-----
        ...
        -----END AGE ENCRYPTED FILE-----
  lastmodified: "2025-05-15T10:00:00Z"
  version: 3.8.1
```

```python
#!/usr/bin/env python3
# scripts/rotate_secret.py — zero-downtime dual-active rotation for an API key

import boto3
import time
import requests
import sys

sm = boto3.client("secretsmanager", region_name="eu-west-1")
SECRET_NAME = "payments/stripe-api-key"

def get_current_secret() -> dict:
    return sm.get_secret_value(SecretId=SECRET_NAME)

def put_pending_secret(new_value: str):
    """Store new key alongside old (shadow phase)."""
    current = sm.describe_secret(SecretId=SECRET_NAME)
    sm.put_secret_value(
        SecretId=SECRET_NAME,
        SecretString=new_value,
        VersionStages=["AWSPENDING"],           # shadow stage
    )
    print(f"[1/4] New secret stored as AWSPENDING")

def verify_new_secret(new_value: str) -> bool:
    """Validate new key works before promoting."""
    resp = requests.get(
        "https://api.stripe.com/v1/account",
        auth=(new_value, ""),
        timeout=10,
    )
    return resp.status_code == 200

def promote_secret():
    """Promote AWSPENDING → AWSCURRENT; old version becomes AWSPREVIOUS."""
    version = sm.list_secret_version_ids(SecretId=SECRET_NAME)["Versions"]
    pending = next(v for v in version if "AWSPENDING" in v.get("VersionStages", []))
    sm.update_secret_version_stage(
        SecretId=SECRET_NAME,
        VersionStage="AWSCURRENT",
        MoveToVersionId=pending["VersionId"],
        RemoveFromVersionId=next(
            v["VersionId"] for v in version if "AWSCURRENT" in v.get("VersionStages", [])
        ),
    )
    print("[3/4] AWSPENDING promoted to AWSCURRENT")

def revoke_old():
    """Mark old version DEPRECATED after consumers have migrated."""
    time.sleep(300)  # 5-minute grace period for in-flight requests
    print("[4/4] Old secret version deprecated (AWSPREVIOUS retained for 7 days)")

def rotate(new_api_key: str):
    put_pending_secret(new_api_key)
    print("[2/4] Verifying new secret…")
    if not verify_new_secret(new_api_key):
        print("ERROR: New secret verification failed. Aborting rotation.")
        sys.exit(1)
    promote_secret()
    revoke_old()
    print("Rotation complete with zero downtime.")

if __name__ == "__main__":
    new_key = sys.argv[1]  # passed from secrets manager rotation Lambda or manual
    rotate(new_key)
```

---

### Template 6 — Secret Scanning in CI + Break-Glass Procedure

```yaml
# .github/workflows/secret-scan.yml
name: Secret Scanning

on:
  pull_request:
  push:
    branches: [main]

jobs:
  gitleaks:
    name: gitleaks (fast pattern scan)
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683
        with:
          fetch-depth: 0    # full history for baseline comparison

      - uses: gitleaks/gitleaks-action@v2
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          GITLEAKS_LICENSE: ${{ secrets.GITLEAKS_LICENSE }}
        with:
          config-path: .gitleaks.toml

  trufflehog:
    name: truffleHog (entropy + deep scan)
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683
        with:
          fetch-depth: 0

      - name: Run truffleHog
        uses: trufflesecurity/trufflehog@v3.88.1
        with:
          base: ${{ github.event.repository.default_branch }}
          head: HEAD
          extra_args: --only-verified --fail
```

```toml
# .gitleaks.toml — custom rules for org-specific secret patterns
[extend]
useDefault = true        # include gitleaks built-in rules

[[rules]]
id          = "org-api-key"
description = "Company internal API key"
regex       = '''sk_(live|test)_[0-9a-zA-Z]{32,}'''
tags        = ["key", "api", "company"]

[[rules]]
id          = "vault-token"
description = "HashiCorp Vault token"
regex       = '''hvs\.[0-9A-Za-z_-]{90,}'''
tags        = ["vault", "token"]

[allowlist]
regexes = [
  '''EXAMPLE_KEY_DO_NOT_USE''',
  '''sk_test_placeholder''',
]
paths = [
  '''testdata/''',
  '''docs/''',
]
```

```bash
#!/bin/bash
# scripts/break-glass.sh — emergency Vault root token generation
# Run only during incident; requires M-of-N unseal key holders present.
# ALL steps are logged and require incident ticket number.

set -euo pipefail
INCIDENT=${1:?Usage: break-glass.sh INCIDENT-XXXX}

echo "=== BREAK-GLASS PROCEDURE: $INCIDENT ==="
echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "Operator:  $(whoami)@$(hostname)"
echo ""
echo "This session is being recorded. Proceeding requires approval from:"
echo "  - Security Lead"
echo "  - VP Engineering"
echo ""
read -p "Approver names (comma-separated): " APPROVERS

# Generate root token using Shamir's unseal process
# Requires N of M key holders to provide their key shard
vault operator generate-root -init

echo ""
echo "Distribute the OTP to key holders. Each holder runs:"
echo "  vault operator generate-root -nonce=<nonce>"
echo ""
echo "After N holders provide shards, run:"
echo "  vault operator generate-root -nonce=<nonce> -decode=<encoded-token> -otp=<otp>"
echo ""
echo "IMPORTANT: After incident resolution:"
echo "  1. Revoke the root token: vault token revoke <root-token>"
echo "  2. Log revocation in incident ticket: $INCIDENT"
echo "  3. Rotate any secrets accessed during the incident"
echo "  4. Run post-incident review within 48 hours"

# Audit log entry
logger -p auth.crit "BREAK-GLASS initiated: incident=$INCIDENT approvers=$APPROVERS operator=$(whoami)"
```

```yaml
# vault/audit-backends.tf — Vault audit logging (all secret access logged)
resource "vault_audit" "file" {
  type = "file"
  path = "file"
  options = {
    file_path   = "/vault/logs/audit.log"
    log_raw     = "false"    # HMAC sensitive fields (don't log plaintext secrets)
    format      = "json"
    mode        = "0600"
  }
}

resource "vault_audit" "syslog" {
  type = "syslog"
  path = "syslog"
  options = {
    tag      = "vault"
    facility = "AUTH"
  }
}
```

---

## Decision Matrix

| Scenario | Recommendation | Rationale |
|---|---|---|
| Service needs a DB connection | Vault dynamic DB secrets + auto-renewing lease | Unique creds per instance; auto-revoke on TTL; no stored password |
| Service needs AWS credentials | Vault AWS secrets engine or IRSA (preferred) | IRSA: zero credential; Vault AWS: fine-grained cross-account access |
| mTLS between services on Kubernetes | Vault PKI + cert-manager CertificateRequest | 24h certs; auto-renewed; no rotation ceremony |
| Secrets in GitOps repo | SOPS + age + Flux decryption | Encrypted in Git; plaintext only in cluster memory at reconcile time |
| Teams need self-service secret access | External Secrets Operator + `ExternalSecret` CR | Teams declare what they need; ESO enforces Vault policies |
| Third-party API key rotation | AWS Secrets Manager rotation Lambda or dual-active Python script | Managed rotation; dual-active prevents downtime |
| Need to detect leaked secrets in PRs | gitleaks pre-commit hook + truffleHog in CI | gitleaks: fast, real-time; truffleHog: entropy, catches obfuscated secrets |
| Emergency cluster access | Break-glass runbook + Vault root token with M-of-N key shards | Audited; time-limited; requires multi-party authorisation |
| Secrets shared across multiple clusters | Vault with cluster-scoped Kubernetes auth roles | Single source of truth; each cluster has its own auth path |
| Sensitive config that changes rarely | Vault KV v2 with versioning | Version history; rollback to previous value; access audit log |

---

## Proficiency Levels

### Level 1 — Aware
- Understands the difference between static and dynamic secrets
- Knows that secrets should never be committed to Git
- Can read a Vault policy and understand what access it grants
- Knows what SOPS is and why encrypted secrets in Git are safer than plaintext

### Level 2 — Practitioner
- Configures Vault Kubernetes auth and creates policies for service accounts
- Uses the Vault Agent Injector (`vault.hashicorp.com/agent-inject` annotations) to mount secrets into pods
- Creates `ExternalSecret` CRs and a `ClusterSecretStore` pointing to Vault or AWS Secrets Manager
- Encrypts YAML secrets with SOPS and configures Flux to decrypt at reconcile time
- Adds `gitleaks` as a pre-commit hook and to CI pipelines

### Level 3 — Advanced
- Configures Vault dynamic DB secrets engine with creation/revocation SQL statements
- Designs Vault PKI intermediate CA for service-to-service mTLS certificates with cert-manager
- Implements zero-downtime rotation: dual-active shadow secret pattern with verification step
- Writes Python/Go secret lease renewal logic with 80% TTL renewal timing
- Configures Vault audit backends; queries audit logs for access patterns
- Designs ESO PushSecret for syncing generated secrets back to Vault

### Level 4 — Expert
- Designs multi-datacenter Vault HA topology (Raft storage, performance replication, DR replication)
- Implements Vault namespaces for multi-tenant secrets isolation with cross-namespace policies
- Operates Vault Shamir's Secret Sharing unseal process; designs HSM-backed auto-unseal
- Builds custom Vault secrets plugins for proprietary credential systems
- Designs secrets posture management: automated discovery of unrotated secrets, entropy analysis, blast-radius mapping

---

## AI Prompts

**Configure Vault dynamic secrets for a database**
```
Configure HashiCorp Vault dynamic secrets for [PostgreSQL/MySQL/MongoDB]
with the following requirements:
- Database host: [host]
- Application role: [readonly / readwrite]
- TTL: [N hours] default, [N hours] max
- Vault Kubernetes auth bound to ServiceAccount [name] in namespace [ns]

Provide:
1. Terraform HCL: vault_mount, vault_database_secret_backend_connection,
   vault_database_secret_backend_role (with creation + revocation SQL)
2. Vault policy allowing the service to read credentials
3. Go code: fetch credentials, open sql.DB, auto-renew at 80% TTL
4. Test: verify credentials work and expire after TTL
```

**Set up External Secrets Operator**
```
Configure External Secrets Operator to sync secrets from [Vault / AWS Secrets Manager]
to Kubernetes namespace [ns] for service [name].

Secrets needed:
[list: secret-key → vault-path/property or ASM secret name]

Provide:
1. ClusterSecretStore with [Vault Kubernetes auth / AWS IRSA] authentication
2. ExternalSecret CR that composes DATABASE_URL from username + password fields
3. Deployment annotation or volume mount to consume the synced Secret
4. Prometheus alert: ESO sync failure for more than 10 minutes
```

**Implement zero-downtime secret rotation**
```
Design and implement a zero-downtime rotation procedure for [API key / DB password /
TLS certificate] using the dual-active (shadow secret) pattern.

Phases:
1. Generate new credential
2. Validate new credential works
3. Deploy consumers reading new credential (how long to wait?)
4. Revoke old credential

Provide:
- Python or Go rotation script with verification step
- How to handle in-flight requests using old credential during migration
- Rollback procedure if new credential fails verification
- Monitoring: how to confirm all consumers have migrated to new credential
```

**Audit secrets exposure**
```
Audit our current secrets handling for these services: [list]
Against these risks:
1. Secrets in environment variables (visible in /proc)
2. Secrets in container image layers
3. Long-lived static credentials (TTL > 90 days)
4. Shared credentials across multiple services
5. Missing audit logging on secret access
6. No rotation procedure documented
7. Secrets accessible to more services than needed (over-privileged Vault policy)

For each finding: severity, evidence to check, and remediation steps.
```

---

## References

- **HashiCorp Vault documentation** — `developer.hashicorp.com/vault` — auth methods, secrets engines, policies
- **Vault Agent** — `developer.hashicorp.com/vault/docs/agent-and-proxy/agent` — sidecar injection, templates
- **External Secrets Operator** — `external-secrets.io/docs` — provider matrix, ExternalSecret, PushSecret
- **cert-manager** — `cert-manager.io/docs` — Vault issuer, Certificate CRD, auto-renewal
- **SOPS** — `github.com/getsops/sops` — age/KMS/PGP encryption for YAML/JSON/ENV files
- **age** — `github.com/FiloSottile/age` — modern encryption tool used with SOPS
- **gitleaks** — `github.com/gitleaks/gitleaks` — secret scanning; pre-commit hook; CI action
- **truffleHog** — `github.com/trufflesecurity/trufflehog` — entropy + regex; deep git history scan
- **AWS Secrets Manager rotation** — `docs.aws.amazon.com/secretsmanager/latest/userguide/rotating-secrets.html`
- **Vault Kubernetes auth** — `developer.hashicorp.com/vault/docs/auth/kubernetes`
- **NIST SP 800-57** — Key management recommendations (key lifetimes, rotation periods)
- **`vault/api` Go client** — `github.com/hashicorp/vault/api` — programmatic Vault interaction
