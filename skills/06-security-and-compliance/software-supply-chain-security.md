---
name: Software Supply Chain Security
slug: software-supply-chain-security
category: 06-security-and-compliance
proficiency: advanced
description: >
  Secure the software supply chain end to end: SLSA framework (provenance
  levels 1–3), keyless artifact signing with Sigstore (Cosign/Fulcio/Rekor),
  SBOM generation and attestation (CycloneDX, SPDX), dependency vulnerability
  scanning (Trivy, Grype), dependency confusion and typosquatting mitigations,
  GitHub Actions hardening (SHA-pinned actions, OIDC token signing), Kubernetes
  admission control for signed images (Kyverno, OPA Gatekeeper), VEX documents,
  and OpenSSF Scorecard governance. Covers the full path from source commit to
  verified production deployment.
tags:
  - slsa
  - sigstore
  - cosign
  - sbom
  - cyclonedx
  - spdx
  - trivy
  - supply-chain
  - kyverno
  - openssf
  - provenance
  - dependency-security
status: published
---

## Principles

### 1. Trust Nothing You Did Not Build — Verify Everything You Did
The SolarWinds, XZ Utils, and Log4Shell incidents share a root cause: software
running in production whose integrity was never cryptographically verified.
Every artifact — container image, binary, library — should carry a **signed
provenance attestation** that answers: who built it, from which source commit,
on which build system, and when. Unsigned artifacts are trust on faith.

### 2. SLSA Is a Maturity Model, Not a Binary Checkbox
**Supply-chain Levels for Software Artifacts** (SLSA, pronounced "salsa")
defines four levels of supply chain integrity:
- **SLSA 1**: Build provenance generated (unsigned)
- **SLSA 2**: Hosted build service generates signed provenance
- **SLSA 3**: Build is isolated; provenance is non-forgeable by the build service
- **SLSA 4** *(aspirational)*: Two-party review; hermetic, reproducible builds

Most organisations should target **SLSA 2** for internal services (GitHub Actions
+ Sigstore achieves this today) and **SLSA 3** for artifacts shipped to customers.

### 3. Signing Is Only as Strong as the Key Management Behind It
A container signed with a long-lived key stored in CI environment variables is
marginally better than unsigned — the key can be exfiltrated and used to sign
malicious images. **Keyless signing** (Sigstore's Fulcio + Rekor) ties the
signature to the **OIDC identity of the build job** (e.g., a specific GitHub
Actions workflow run), not a static key. The signature is time-stamped in a
public transparency log (Rekor) and expires with the OIDC token — no key to
steal, no key to rotate.

### 4. An SBOM Without Vulnerability Scanning Is a Catalogue, Not a Control
A Software Bill of Materials lists every component and version in an artifact.
Without continuous scanning of that SBOM against vulnerability databases (NVD,
OSV, GitHub Advisories), it provides transparency but no protection. The SBOM
must be machine-readable (CycloneDX JSON or SPDX SBOM), attached as a signed
attestation to the artifact, and scanned by a policy engine on every deployment.

### 5. Dependency Confusion Exploits Trust in Package Name Resolution
An attacker registers a public package with the same name as an internal private
package. Build tools that check public registries before private ones will pull
the malicious public package. Mitigations: scope all internal packages (e.g.,
`@company/` for npm, `company-` prefix for PyPI), configure the package manager
to **only** resolve internal package names from the internal registry, and use
**hash pinning** (lockfiles with content hashes) so no substitution is possible.

---

## Implementation Patterns

### Pattern A: Keyless Cosign Signing in GitHub Actions
The GitHub Actions OIDC token (`id-token: write` permission) is exchanged with
Fulcio for a short-lived signing certificate bound to the workflow's identity
(`repo:org/repo:ref:refs/heads/main`). Cosign signs the artifact digest and
records the signature + certificate in Rekor. Verification checks the Rekor
entry and validates the Fulcio certificate chain — no private key involved.

### Pattern B: SBOM as a First-Class Build Artifact
Generate the SBOM at build time (before the image leaves CI), sign it as an
attestation with `cosign attest`, and store it alongside the image in the
registry. Policy engines (Kyverno) can require the SBOM attestation as a
precondition for deployment — no SBOM means the pod is blocked.

### Pattern C: Dependency Pinning with Hash Verification
Lock files (Go's `go.sum`, npm's `package-lock.json`, Python's
`requirements.txt` with `--require-hashes`) record the content hash of every
dependency. A tampered package changes its hash and breaks the build
immediately. For GitHub Actions workflows, pin every action reference to its
full commit SHA rather than a mutable tag.

### Pattern D: VEX for Reducing Vulnerability Noise
A **Vulnerability Exploitability eXchange** (VEX) document asserts whether a
known CVE is exploitable in a specific product. If a library vulnerability
requires a code path that your service never invokes, a VEX statement of
`not_affected` (with justification) allows scanners to suppress the finding
without ignoring the CVE globally. This reduces scanner noise while maintaining
an auditable record.

---

## Anti-Patterns

| Anti-Pattern | Consequence | Fix |
|---|---|---|
| Pinning GitHub Actions to a mutable tag (`actions/checkout@v4`) | Tag can be moved to a different commit; supply chain compromise | Pin to full commit SHA: `actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683` |
| Long-lived signing keys stored in CI secrets | Key exfiltration signs malicious artifacts with your identity | Use Sigstore keyless signing; OIDC identity is ephemeral per build job |
| SBOM generated after image push | SBOM may not reflect the actual built image; attestation integrity broken | Generate SBOM from the final image digest *before* pushing; attest the digest |
| Dependency scanning only at build time | New CVEs published after build are invisible until next build | Continuous scanning of deployed SBOMs (Trivy operator, Grype in policy engine) |
| `latest` tag in Kubernetes image references | Image changes without deployment; no reproducibility | Pin images to digest (`image@sha256:abc123`); update digest via GitOps PR |
| Internal packages without namespace scoping | Dependency confusion: public package with same name wins | Scope internal npm packages as `@company/*`; configure registry priority |
| Ignoring transitive dependencies in SBOM | Vulnerability in a transitive dep invisible until exploited | Use tools that enumerate full dependency tree (Syft, Trivy SBOM) |
| Trusting the build environment itself | Compromised build runner modifies artifacts after signing | SLSA 3: isolated, ephemeral build environment; provenance generated by the build service, not the user |

---

## Code Templates

### Template 1 — GitHub Actions: SLSA Provenance + Cosign Signing + SBOM
```yaml
# .github/workflows/build-sign-attest.yml
name: Build, Sign, and Attest

on:
  push:
    branches: [main]

permissions:
  contents: read
  packages: write
  id-token: write      # REQUIRED for Sigstore keyless signing (OIDC token)
  attestations: write  # REQUIRED for GitHub's native SBOM attestation API

jobs:
  build-sign:
    runs-on: ubuntu-latest
    outputs:
      image-digest: ${{ steps.build.outputs.digest }}

    steps:
    - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683  # v4.2.2 — SHA-pinned

    - name: Set up Docker Buildx
      uses: docker/setup-buildx-action@c47758b77c9736f4b2ef4073d4d51994fabfe349  # v3.7.1

    - name: Log in to GHCR
      uses: docker/login-action@9780b0c442fbb1117ed29e0efdff1e18412f7567  # v3.3.0
      with:
        registry: ghcr.io
        username: ${{ github.actor }}
        password: ${{ secrets.GITHUB_TOKEN }}

    - name: Build and push container image
      id: build
      uses: docker/build-push-action@4f58ea79222b3b9dc2c8bbdd6debcef730109a75  # v6.9.0
      with:
        context: .
        push: true
        tags: ghcr.io/${{ github.repository }}:${{ github.sha }}
        # Output the image digest for signing
        outputs: type=image,name=ghcr.io/${{ github.repository }},push-by-digest=true,name-canonical=true,push=true

    # ── SLSA Provenance via GitHub's native attestation ───────────────────
    - name: Generate SLSA provenance attestation
      uses: actions/attest-build-provenance@1c608d11d69870c2092266b3f9a6f3abbf17002c  # v1.4.3
      with:
        subject-name:   ghcr.io/${{ github.repository }}
        subject-digest: ${{ steps.build.outputs.digest }}
        push-to-registry: true

    # ── SBOM Generation with Syft ─────────────────────────────────────────
    - name: Generate SBOM (CycloneDX JSON)
      uses: anchore/sbom-action@61119d458adab75f756bc0b9e4bde25725f86a7a  # v0.17.2
      with:
        image:         ghcr.io/${{ github.repository }}@${{ steps.build.outputs.digest }}
        format:        cyclonedx-json
        artifact-name: sbom.cyclonedx.json
        output-file:   ./sbom.cyclonedx.json

    # ── Attach SBOM as signed attestation with Cosign (keyless) ───────────
    - name: Install Cosign
      uses: sigstore/cosign-installer@dc72c7d5c4d10cd6bcb8cf6e3fd625a9e5e537da  # v3.7.0

    - name: Attest SBOM with Cosign (keyless via GitHub OIDC)
      run: |
        cosign attest \
          --predicate ./sbom.cyclonedx.json \
          --type cyclonedx \
          ghcr.io/${{ github.repository }}@${{ steps.build.outputs.digest }}
      env:
        COSIGN_EXPERIMENTAL: "1"   # enables keyless / Rekor transparency log

    # ── Vulnerability scan — fail build on CRITICAL CVEs ─────────────────
    - name: Trivy vulnerability scan
      uses: aquasecurity/trivy-action@915b19bbe73b92a6cf82a1bc12b087c9a19a5fe2  # v0.28.0
      with:
        image-ref:    ghcr.io/${{ github.repository }}@${{ steps.build.outputs.digest }}
        format:       sarif
        output:       trivy-results.sarif
        severity:     CRITICAL,HIGH
        exit-code:    "1"           # fail on CRITICAL findings
        ignore-unfixed: true        # suppress unpatched CVEs (no fix available)

    - name: Upload Trivy SARIF to GitHub Security tab
      uses: github/codeql-action/upload-sarif@v3
      if: always()
      with:
        sarif_file: trivy-results.sarif
```

### Template 2 — Kyverno: Enforce Signed Images + SBOM Attestation
```yaml
# kyverno-verify-image-policy.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-image-signature-and-sbom
  annotations:
    policies.kyverno.io/description: >
      Blocks deployment of any container image that is not signed by
      our CI/CD OIDC identity and does not carry a CycloneDX SBOM attestation.
spec:
  validationFailureAction: Enforce
  background: false        # evaluate only on admission, not background scan
  rules:
  - name: verify-cosign-signature
    match:
      any:
      - resources:
          kinds: [Pod]
          namespaces: [production, staging]
    verifyImages:
    - imageReferences: ["ghcr.io/myorg/*"]
      attestors:
      - count: 1
        entries:
        - keyless:
            # Only accept signatures from our specific GitHub Actions workflow
            subject: "https://github.com/myorg/myrepo/.github/workflows/build-sign-attest.yml@refs/heads/main"
            issuer:  "https://token.actions.githubusercontent.com"
            rekor:
              url: https://rekor.sigstore.dev
      # Also require a CycloneDX SBOM attestation
      attestations:
      - predicateType: https://cyclonedx.org/bom
        attestors:
        - count: 1
          entries:
          - keyless:
              subject: "https://github.com/myorg/myrepo/.github/workflows/build-sign-attest.yml@refs/heads/main"
              issuer:  "https://token.actions.githubusercontent.com"
        conditions:
        - all:
          # Verify SBOM contains required metadata
          - key:   "{{ bomFormat }}"
            operator: Equals
            value: "CycloneDX"

  # Prevent use of `latest` tag — forces digest-pinned images
  - name: disallow-latest-tag
    match:
      any:
      - resources:
          kinds: [Pod]
          namespaces: [production, staging]
    validate:
      message: "Image tag 'latest' is not allowed. Pin images to a specific digest."
      foreach:
      - list: "request.object.spec.containers"
        deny:
          conditions:
            any:
            - key:      "{{ element.image }}"
              operator: Contains
              value:    ":latest"
            - key:      "{{ element.image }}"
              operator: NotContains
              value:    "@sha256:"
```

### Template 3 — Shell: Cosign Verify + SBOM Extract in Deployment Pipeline
```bash
#!/usr/bin/env bash
# verify-before-deploy.sh — run in CD pipeline before kubectl apply
set -euo pipefail

IMAGE="${1:?Usage: $0 <image-digest>}"   # e.g. ghcr.io/myorg/myapp@sha256:abc123
WORKFLOW="https://github.com/myorg/myrepo/.github/workflows/build-sign-attest.yml@refs/heads/main"
ISSUER="https://token.actions.githubusercontent.com"

echo "[1] Verifying Cosign signature..."
cosign verify \
  --certificate-identity  "$WORKFLOW" \
  --certificate-oidc-issuer "$ISSUER" \
  "$IMAGE" | jq '.[0].optional | {Issuer, Subject, GitHub_Workflow_Ref: .["GitHub_Workflow_Ref"]}'

echo "[2] Verifying SBOM attestation..."
cosign verify-attestation \
  --type cyclonedx \
  --certificate-identity  "$WORKFLOW" \
  --certificate-oidc-issuer "$ISSUER" \
  "$IMAGE" | jq '.payload | @base64d | fromjson | .predicate | {bomFormat, specVersion, components: (.components | length)}'

echo "[3] Downloading and scanning SBOM for vulnerabilities..."
cosign verify-attestation \
  --type cyclonedx \
  --certificate-identity  "$WORKFLOW" \
  --certificate-oidc-issuer "$ISSUER" \
  "$IMAGE" \
  | jq -r '.payload | @base64d | fromjson | .predicate' \
  > /tmp/sbom.cyclonedx.json

# Scan the extracted SBOM with Grype
grype sbom:/tmp/sbom.cyclonedx.json \
  --fail-on critical \
  --output table

echo "[4] Verifying SLSA provenance..."
cosign verify-attestation \
  --type slsaprovenance \
  --certificate-identity  "$WORKFLOW" \
  --certificate-oidc-issuer "$ISSUER" \
  "$IMAGE" \
  | jq '.payload | @base64d | fromjson | .predicate | {builder: .builder.id, buildType, invocation: .invocation.configSource}'

echo "All checks passed — safe to deploy $IMAGE"
```

### Template 4 — Go: SBOM Generation with `syft` Library + Dependency Audit
```go
// sbom_audit/main.go — programmatic SBOM generation and CVE cross-reference
package main

import (
    "encoding/json"
    "fmt"
    "os"
    "os/exec"
    "strings"
)

// CycloneDXComponent represents one component in the BOM
type CycloneDXComponent struct {
    Type    string `json:"type"`
    Name    string `json:"name"`
    Version string `json:"version"`
    PURL    string `json:"purl,omitempty"`
}

type CycloneDXBOM struct {
    BOMFormat   string               `json:"bomFormat"`
    SpecVersion string               `json:"specVersion"`
    Components  []CycloneDXComponent `json:"components"`
}

// GenerateSBOM runs syft CLI to produce a CycloneDX JSON SBOM for an image
func GenerateSBOM(imageRef, outputPath string) error {
    cmd := exec.Command("syft",
        imageRef,
        "--output", "cyclonedx-json="+outputPath,
        "--scope", "all-layers",
    )
    cmd.Stdout = os.Stdout
    cmd.Stderr = os.Stderr
    return cmd.Run()
}

// ScanWithGrype runs grype against a SBOM file and returns findings as JSON
func ScanWithGrype(sbomPath string, failOnSeverity string) ([]map[string]any, error) {
    out, err := exec.Command("grype",
        "sbom:"+sbomPath,
        "--output", "json",
        "--fail-on", failOnSeverity,
    ).Output()

    var result struct {
        Matches []map[string]any `json:"matches"`
    }
    if jsonErr := json.Unmarshal(out, &result); jsonErr != nil {
        return nil, jsonErr
    }
    return result.Matches, err   // err non-nil if grype exit code > 0 (findings found)
}

// CheckGoVulnerabilities runs govulncheck for Go module vulnerability analysis
func CheckGoVulnerabilities(modulePath string) error {
    cmd := exec.Command("govulncheck", "./...")
    cmd.Dir = modulePath
    cmd.Stdout = os.Stdout
    cmd.Stderr = os.Stderr
    return cmd.Run()
}

func main() {
    imageRef := os.Args[1]   // e.g. ghcr.io/myorg/myapp@sha256:abc123
    sbomPath := "/tmp/sbom.cyclonedx.json"

    fmt.Println("Generating SBOM...")
    if err := GenerateSBOM(imageRef, sbomPath); err != nil {
        fmt.Fprintf(os.Stderr, "SBOM generation failed: %v\n", err)
        os.Exit(1)
    }

    fmt.Println("Scanning SBOM for vulnerabilities...")
    findings, err := ScanWithGrype(sbomPath, "high")
    if err != nil {
        fmt.Printf("Found %d vulnerability matches\n", len(findings))
        for _, f := range findings {
            vuln := f["vulnerability"].(map[string]any)
            fmt.Printf("  %s (%s) in %s\n",
                vuln["id"], vuln["severity"],
                f["artifact"].(map[string]any)["name"],
            )
        }
        os.Exit(1)
    }
    fmt.Printf("No HIGH/CRITICAL vulnerabilities found. SBOM has %d components.\n",
        countComponents(sbomPath))
}

func countComponents(sbomPath string) int {
    data, _ := os.ReadFile(sbomPath)
    var bom CycloneDXBOM
    json.Unmarshal(data, &bom)
    return len(bom.Components)
}
```

### Template 5 — Python: Dependency Audit — pip-audit + License Compliance
```python
#!/usr/bin/env python3
"""dependency_audit.py — audit Python dependencies for CVEs and licence compliance.
   Integrate into CI to block builds with disallowed licences or known CVEs.
"""
import subprocess
import json
import sys
from pathlib import Path

DISALLOWED_LICENSES = {"GPL-2.0", "GPL-3.0", "AGPL-3.0", "LGPL-2.1"}
BLOCKED_SEVERITIES  = {"critical", "high"}

def run_pip_audit(requirements_file: str) -> list[dict]:
    """Run pip-audit and return vulnerability findings as a list."""
    result = subprocess.run(
        ["pip-audit", "--requirement", requirements_file,
         "--format", "json", "--strict"],
        capture_output=True, text=True
    )
    if not result.stdout.strip():
        return []
    data = json.loads(result.stdout)
    return data.get("dependencies", [])

def run_pip_licenses(requirements_file: str) -> list[dict]:
    """Run pip-licenses to enumerate dependency licences."""
    result = subprocess.run(
        ["pip-licenses", "--format", "json", "--with-urls",
         "--requirements-file", requirements_file],
        capture_output=True, text=True
    )
    return json.loads(result.stdout) if result.stdout.strip() else []

def audit(requirements_file: str = "requirements.txt") -> bool:
    ok = True

    print("=== CVE Audit (pip-audit) ===")
    for dep in run_pip_audit(requirements_file):
        for vuln in dep.get("vulns", []):
            severity = vuln.get("fix_versions", []) and "patched" or "unpatched"
            print(f"  VULN  {dep['name']}=={dep['version']}  "
                  f"{vuln['id']}  aliases={vuln.get('aliases', [])}")
            ok = False   # any CVE = fail

    print("\n=== Licence Compliance ===")
    for pkg in run_pip_licenses(requirements_file):
        licence = pkg.get("License", "UNKNOWN")
        if any(disallowed in licence for disallowed in DISALLOWED_LICENSES):
            print(f"  BLOCKED  {pkg['Name']}=={pkg['Version']}  licence={licence}")
            ok = False
        elif licence == "UNKNOWN":
            print(f"  WARN  {pkg['Name']} has unknown licence — review manually")

    print("\n=== Hash Pinning Check ===")
    req_text = Path(requirements_file).read_text()
    unpinned = [
        line.strip() for line in req_text.splitlines()
        if line.strip() and not line.startswith("#")
        and "--hash=" not in line
        and not line.startswith("-r ")
        and not line.startswith("-c ")
    ]
    if unpinned:
        print("  WARN: The following packages are not hash-pinned:")
        for pkg in unpinned:
            print(f"    {pkg}")
        print("  Run: pip-compile --generate-hashes requirements.in")

    return ok

if __name__ == "__main__":
    req_file = sys.argv[1] if len(sys.argv) > 1 else "requirements.txt"
    sys.exit(0 if audit(req_file) else 1)
```

### Template 6 — Shell: OpenSSF Scorecard + Supply Chain Health Check
```bash
#!/usr/bin/env bash
# supply_chain_health.sh — run OpenSSF Scorecard + additional supply chain checks
# Requires: scorecard CLI, trivy, cosign, gh CLI
set -euo pipefail

REPO="${1:?Usage: $0 <github-org/repo>}"
MIN_SCORE=6.0   # fail if Scorecard < 6.0/10

echo "════════════════════════════════════════════"
echo "  Supply Chain Health: $REPO"
echo "════════════════════════════════════════════"

# ── OpenSSF Scorecard ─────────────────────────────────────────────────────
echo "[1] Running OpenSSF Scorecard..."
scorecard \
  --repo "github.com/$REPO" \
  --format json \
  --checks "Vulnerabilities,Dependency-Update-Tool,Pinned-Dependencies,\
            Branch-Protection,Code-Review,SAST,Token-Permissions,\
            Binary-Artifacts,Security-Policy" \
  | tee /tmp/scorecard.json \
  | jq -r '.checks[] | "\(.score)/10  \(.name)  \(.reason)"' \
  | sort -t'/' -k1 -n

SCORE=$(jq -r '.score' /tmp/scorecard.json)
echo ""
echo "Overall Scorecard: $SCORE / 10"
if (( $(echo "$SCORE < $MIN_SCORE" | bc -l) )); then
  echo "FAIL: Scorecard $SCORE is below minimum $MIN_SCORE"
  exit 1
fi

# ── Check for pinned GitHub Actions ──────────────────────────────────────
echo ""
echo "[2] Checking for unpinned GitHub Actions..."
UNPINNED=$(gh api "repos/$REPO/contents/.github/workflows" \
  --jq '.[].name' \
  | while read -r wf; do
      gh api "repos/$REPO/contents/.github/workflows/$wf" --jq '.content' \
        | base64 -d \
        | grep -E "uses: [^@]+@[^0-9a-f]" || true
    done)

if [[ -n "$UNPINNED" ]]; then
  echo "WARN: Found Actions not pinned to full SHA:"
  echo "$UNPINNED"
fi

# ── Verify latest release artifact is signed ─────────────────────────────
echo ""
echo "[3] Verifying latest container image signature..."
LATEST_TAG=$(gh release view --repo "$REPO" --json tagName --jq '.tagName' 2>/dev/null || echo "")
if [[ -n "$LATEST_TAG" ]]; then
  IMAGE="ghcr.io/$REPO:$LATEST_TAG"
  if cosign verify \
      --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
      --certificate-identity-regexp "https://github.com/$REPO/.*" \
      "$IMAGE" > /dev/null 2>&1; then
    echo "  SIGNED:   $IMAGE"
  else
    echo "  UNSIGNED: $IMAGE — signature verification failed"
  fi
fi

# ── Dependency vulnerability summary ─────────────────────────────────────
echo ""
echo "[4] Scanning latest image for known vulnerabilities..."
if [[ -n "${LATEST_TAG:-}" ]]; then
  trivy image \
    --severity HIGH,CRITICAL \
    --format table \
    --ignore-unfixed \
    "ghcr.io/$REPO:$LATEST_TAG" 2>/dev/null || true
fi

echo ""
echo "Supply chain health check complete."
```

---

## Decision Matrix

| Scenario | Control | Implementation |
|---|---|---|
| Sign container images in CI | Sigstore keyless (Cosign + Fulcio + Rekor) | `cosign sign` with `id-token: write`; no static key |
| Verify signatures before deploy | Kyverno `verifyImages` policy | `ClusterPolicy` with `keyless` attestor + subject/issuer match |
| Generate SBOM | Syft (comprehensive) or Docker `sbom` export | CycloneDX JSON format; attach as `cosign attest --type cyclonedx` |
| Scan dependencies for CVEs | Trivy (containers + filesystem) + Grype (SBOM-focused) | Block on CRITICAL in CI; scan deployed SBOMs continuously |
| Prevent `latest` tag in production | Kyverno `disallow-latest-tag` policy | Deny if image ref doesn't contain `@sha256:` |
| Prevent dependency confusion | Private registry proxy + namespace scoping | `@company/` prefix for npm; `--index-url` for pip; `replace` directives in `go.mod` |
| Govern GitHub Actions security | SHA-pinning + `permissions: read-all` default | `scorecard` check "Pinned-Dependencies"; `step-security/harden-runner` |
| Continuous CVE monitoring in prod | Trivy Operator in Kubernetes | Scans running pod images; publishes findings as `VulnerabilityReport` CRDs |
| Audit dependency licences | `pip-licenses`, `license-checker` (npm), `go-licenses` | Block GPL/AGPL in CI; approve exceptions explicitly |
| SLSA level 2 for open-source releases | GitHub Actions + `actions/attest-build-provenance` | OIDC-backed provenance attached to release assets |

---

## Proficiency Levels

### Novice
- Understands why the SolarWinds and Log4Shell incidents were supply chain attacks
- Knows what an SBOM is and which formats exist (CycloneDX, SPDX)
- Runs `trivy image` against a container; reads the output
- Knows the difference between a mutable image tag and a content-addressed digest

### Intermediate
- Configures Cosign keyless signing in a GitHub Actions pipeline with OIDC
- Generates a CycloneDX SBOM with Syft and attests it to the image registry
- Writes a Kyverno `ClusterPolicy` to enforce signed images in a namespace
- Pins all GitHub Actions to commit SHAs; understands why mutable tags are risky
- Runs OpenSSF Scorecard and interprets the check results
- Configures Dependabot or Renovate for automated dependency patch PRs

### Advanced
- Designs a SLSA 2 build pipeline with non-forgeable provenance for all released artifacts
- Implements Kyverno policies requiring SBOM attestation + signature for production deployments
- Configures Trivy Operator for continuous in-cluster vulnerability scanning with alerting
- Writes VEX documents to suppress non-exploitable CVEs with documented justifications
- Audits dependency licence compliance in CI; blocks GPL/AGPL introduction
- Detects and mitigates dependency confusion risk in private package configuration

### Expert
- Architects organisation-wide supply chain security programme across 50+ repositories
- Achieves SLSA 3 via isolated, ephemeral build environments with hardware-attested provenance
- Implements a private Fulcio CA + Rekor transparency log for air-gapped environments
- Designs a Software Composition Analysis (SCA) policy engine with risk scoring and exception workflow
- Contributes to OpenSSF Scorecard checks or Sigstore toolchain
- Integrates supply chain attestations into compliance reporting (FedRAMP, SOC 2, ISO 27001)

---

## AI Prompts

```
You are a software supply chain security expert. I need to achieve SLSA level 2
for our container images built in GitHub Actions. Walk me through the exact
pipeline configuration: which GitHub permissions to set, how to use Cosign
keyless signing with the GitHub OIDC token, what the Fulcio/Rekor interaction
looks like, and how a consumer verifies the signature. Include the exact
cosign verify command with the correct --certificate-identity flag.
```

```
Acting as a Kubernetes security architect: I want to enforce that no container
in the production namespace can run unless its image is signed by our CI/CD
pipeline and has an attached CycloneDX SBOM attestation. Write the complete
Kyverno ClusterPolicy. Explain what happens when a developer tries to deploy an
image they built locally, and how to handle the exception process for emergencies.
```

```
Explain the dependency confusion attack: how it works, which package managers
are vulnerable, and what an attacker needs to do to execute it. For a company
with internal Python packages hosted on a private PyPI, show the exact pip
configuration (pip.ini / pyproject.toml) and package naming strategy that
eliminates the risk.
```

```
I need to implement continuous vulnerability scanning for 200 running pods in
our Kubernetes cluster. Compare three approaches: (1) Trivy Operator scanning
running images and publishing VulnerabilityReport CRDs, (2) scanning SBOMs
attached to images in the registry, (3) re-scanning at deploy time in the CD
pipeline. Which approach catches the most CVEs? Which has the lowest false
positive rate? How do you handle alert fatigue?
```

```
Design a VEX (Vulnerability Exploitability eXchange) workflow for our
organisation. We have 50 services, each with an SBOM. Trivy reports 300
CVE findings per week, but 80% are in code paths we never execute. How do
we create, sign, and distribute VEX documents? Which VEX format (CSAF, CycloneDX
VEX, OpenVEX) should we use, and how do we integrate VEX with our CI scanner
so approved suppressions are applied automatically?
```

---

## References

- **SLSA framework** — https://slsa.dev — levels, requirements, provenance spec
- **Sigstore** — https://sigstore.dev — Cosign, Fulcio CA, Rekor transparency log
- **Cosign docs** — https://docs.sigstore.dev/cosign/overview/
- **CycloneDX spec** — https://cyclonedx.org/specification/overview/
- **SPDX spec** — https://spdx.dev/specifications/
- **Syft** — https://github.com/anchore/syft — SBOM generation (Anchore)
- **Grype** — https://github.com/anchore/grype — SBOM vulnerability scanner
- **Trivy** — https://trivy.dev — container + filesystem + SBOM scanner (Aqua)
- **Trivy Operator** — https://aquasecurity.github.io/trivy-operator/ — in-cluster continuous scanning
- **Kyverno** — https://kyverno.io — Kubernetes policy engine (image verification)
- **OpenSSF Scorecard** — https://scorecard.dev — supply chain risk scoring
- **OpenSSF Best Practices** — https://bestpractices.coreinfrastructure.org
- **govulncheck** — https://pkg.go.dev/golang.org/x/vuln/cmd/govulncheck — Go vulnerability scanner
- **pip-audit** — https://pypi.org/project/pip-audit/ — Python dependency CVE auditor
- **VEX / OpenVEX** — https://github.com/openvex/spec — exploitability exchange format
- **CISA SBOM guidance** — https://www.cisa.gov/sbom
- **SysSkills cross-reference** — `authentication-and-authorization`, `threat-modeling-stride`,
  `cicd-gitops-strategy`, `kernel-security`, `platform-engineering-idp`
