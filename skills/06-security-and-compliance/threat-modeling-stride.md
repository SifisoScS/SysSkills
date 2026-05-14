---
name: "Threat Modeling with STRIDE"
slug: threat-modeling-stride
category: "06-security-and-compliance"
proficiency: Architect
description: "Master systematic threat modeling using the STRIDE methodology to proactively identify, categorise, and mitigate security threats during design and re-engineering. Integrates with C4 diagrams, DDD Bounded Contexts, and ADRs for secure-by-design architectures."
tags: [threat-modeling, stride, security, dread, attack-trees, owasp, secure-by-design, c4-overlay, risk-assessment, security-design]
status: published
---

# Threat Modeling with STRIDE

## Principles

**Threat Modeling Is a Design Activity**
Security threats are cheapest to fix when found during design. Threat modeling on a whiteboard costs an hour; the same finding as a production vulnerability costs weeks of incident response, emergency patching, and reputation repair. Run threat modeling when the architecture is being drawn, not after the code is written.

**Assume Breach**
Design under the assumption that an attacker will eventually get past the perimeter. Ask not just "how do we prevent the attack?" but "what is the blast radius when this control fails?" The goal is to limit damage, detect intrusion fast, and recover quickly — not only to build perfect walls.

**Threats Are Properties of the Architecture, Not Afterthoughts**
A threat is not a checklist item to tick. It is a property of the design: every trust boundary is a potential spoofing or tampering surface; every data flow is a potential information disclosure; every API endpoint is a potential denial of service target. The model is the threat surface.

**Involve Multiple Perspectives**
Security engineers see technical attack vectors. Developers know the codebase's weak points. Operations knows the deployment surface and secrets management. Domain experts know which data is most sensitive. A threat modeling session without all four perspectives will miss threats.

**Document and Track Every Mitigation**
An identified threat with no tracked mitigation is worse than no threat modeling — it creates false assurance. Every significant threat must become either a backlog item (mitigate), an ADR (accept with documented rationale and residual risk), or a monitoring rule (detect).

**Do It Early and Iteratively**
Threat model at project kickoff (new system or new feature), at each significant architecture change, and at each Strangler Fig extraction. The threat model is a living document, not a one-time exercise.

---

## Implementation Patterns

### The STRIDE Framework

STRIDE categorises threats by the security property they violate:

| Letter | Threat | Violated Property | Example | Primary Mitigations |
|---|---|---|---|---|
| **S** | Spoofing | Authentication | Stolen token used to impersonate user | Strong auth (Passkeys/MFA), mTLS, short-lived tokens |
| **T** | Tampering | Integrity | Attacker modifies order amount in transit | TLS, message signing, HMAC, immutable audit log |
| **R** | Repudiation | Non-repudiation | User denies placing an order | Audit logging with tamper-evident storage, digital signatures |
| **I** | Information Disclosure | Confidentiality | API returns full PII in error response | Encryption at rest/transit, least privilege, output sanitisation |
| **D** | Denial of Service | Availability | Bot floods login endpoint | Rate limiting, circuit breakers, autoscaling, WAF |
| **E** | Elevation of Privilege | Authorisation | Regular user accesses admin API | Fine-grained authz (OPA/Cedar), least privilege, defence in depth |

### Pattern 1 — The Four-Question Framework (Microsoft)

Before diving into STRIDE categories, anchor the session:

1. **What are we building?** — Use the C4 container diagram as the starting point
2. **What can go wrong?** — Apply STRIDE to each element and trust boundary
3. **What are we going to do about it?** — Mitigate, accept, or transfer each threat
4. **Did we do a good enough job?** — Validate mitigations are implemented and tested

### Pattern 2 — STRIDE Per Element (Systematic Approach)

Apply STRIDE to each element type in the system:

**External Actors (Users, External Systems)**
- Spoofing: can this actor claim to be someone else?
- Repudiation: can this actor deny their actions?

**Processes / Services**
- Spoofing: can an attacker impersonate this service?
- Tampering: can the service's code or data be modified?
- Information Disclosure: does the service leak data in logs, errors, or responses?
- Denial of Service: can the service be overwhelmed or crashed?
- Elevation of Privilege: can the service be exploited to gain higher permissions?

**Data Stores**
- Tampering: can data be modified without detection?
- Information Disclosure: is the data readable by unauthorised parties?
- Denial of Service: can the store be made unavailable?
- Repudiation: are writes logged for audit purposes?

**Data Flows (between elements)**
- Spoofing: is the source of the flow verified?
- Tampering: is the data protected in transit?
- Information Disclosure: is the channel encrypted?
- Denial of Service: can the channel be flooded?

**Trust Boundaries**
Every line crossing a trust boundary (internet → DMZ, service → database, browser → API) is a high-priority threat surface. Apply full STRIDE at every boundary crossing.

### Pattern 3 — STRIDE on C4 Diagrams (Overlay)

Use the C4 container diagram as the threat modeling canvas:

1. Mark all trust boundaries on the diagram (dashed red lines: public internet / internal network / database tier)
2. Number each data flow
3. For each numbered flow and each element, generate STRIDE threats
4. Annotate the diagram with threat IDs (T001, T002…)
5. Produce a threat register (see Code Templates) linked to diagram elements

This makes the threat model reviewable in pull requests alongside the architecture diagram.

### Pattern 4 — Risk Rating with DREAD

Prioritise threats for mitigation using DREAD scoring (0–3 per dimension, max 15):

| Dimension | Question | 0 | 1 | 2 | 3 |
|---|---|---|---|---|---|
| **D**amage | How bad if exploited? | Minimal | Individual user | Many users | Critical systems |
| **R**eproducibility | How easy to reproduce? | Impossible | Requires special conditions | Always reproducible | Always reproducible with automation |
| **E**xploitability | How easy to launch? | Requires insider access | Requires tools | Simple steps | Browser only |
| **A**ffected Users | How many users affected? | None | Single user | Some users | All users |
| **D**iscoverability | How easy to find? | Impossible | Requires source access | Publicly listed | Top Google result |

Score ≥ 10: High — mitigate immediately  
Score 5–9: Medium — mitigate in current sprint or next  
Score < 5: Low — accept with documentation or monitor

### Pattern 5 — Threat Modeling in the Development Lifecycle

**Greenfield systems**: run a threat modeling session before the first sprint begins. Use the initial C4 container diagram. Update as the architecture evolves.

**Strangler Fig migrations**: run a threat modeling session for each extracted Bounded Context. The migration introduces new trust boundaries (proxy layer, dual-write paths, CDC connections) that create new attack surfaces.

**Feature development**: for any feature that touches authentication, authorisation, data access patterns, or external integrations, run a lightweight STRIDE checklist before implementation.

**Continuous threat modeling**: integrate threat model reviews into the architecture review board; use automated scanners (OWASP Dependency Check, Trivy for containers) to catch known vulnerabilities in dependencies.

---

## Anti-Patterns

| Anti-Pattern | Why It's Harmful | Fix |
|---|---|---|
| One-time threat model at project start | System evolves; threat surface changes; the model becomes stale within months | Treat the threat model as a living document; update at each significant architecture change |
| Security team does it alone | Developers know the code's weak points; operations knows the deployment surface; domain experts know which data matters most | Collaborative workshop with architect, developer, ops, and security |
| No follow-through on mitigations | Threat register grows; nothing is actioned; false assurance | Every threat becomes a backlog item, ADR, or monitoring rule — not just a document entry |
| STRIDE as a bureaucratic checkbox | Teams fill in a template to satisfy a compliance requirement with no real analysis | Use the four-question framework to drive genuine design conversation, not template completion |
| Ignoring human factors | Phishing, social engineering, and insider threats are out of scope | Include human attack vectors; train for phishing; model insider threat for sensitive data stores |
| Over-focusing on external threats | Internal service-to-service calls are implicitly trusted; lateral movement after breach is ignored | Apply Zero Trust; every internal call is an untrusted call; apply STRIDE to internal trust boundaries |
| No threat model for legacy migrations | Strangler Fig proxy and dual-write paths introduce new attack surfaces that are not in the original threat model | Run a threat modeling session at each extraction step of a migration programme |

---

## Code Templates

### Threat Register (Markdown Table — links to C4 diagram)

```markdown
# Threat Register — Order Service (v1.2)
**System**: SysSkills Platform — Order Bounded Context  
**Diagram**: docs/architecture/02-containers.puml  
**Date**: 2026-05-14  
**Participants**: Sifiso Shezi (architect), [dev], [security]

| ID   | Element       | Flow | STRIDE | Threat Description                              | DREAD | Mitigation                                      | Status   | ADR |
|------|---------------|------|--------|------------------------------------------------|-------|-------------------------------------------------|----------|-----|
| T001 | API Gateway   | F1   | S      | Attacker replays stolen JWT to impersonate user | 11    | Short-lived tokens (15 min) + refresh rotation  | Done     | ADR-0006 |
| T002 | API → DB      | F3   | I      | DB connection string leaked in error logs       | 9     | Structured logging; never log connection strings | Done     | —  |
| T003 | Order Service | —    | D      | Bulk order creation floods DB connection pool   | 8     | Rate limit per user; connection pool max enforced| In progress | — |
| T004 | Event Bus     | F5   | T      | Consumer processes tampered event payload       | 10    | Sign events with HMAC; verify on consume        | Backlog  | — |
| T005 | Outbox Relay  | F6   | E      | Outbox relay process has DB write permissions beyond its scope | 7 | Least-privilege DB role for relay process | Backlog | — |
```

### PowerShell — Threat Register Generator

```powershell
# tools/generators/New-ThreatModel.ps1
param(
    [Parameter(Mandatory)] [string]$SystemName,
    [Parameter(Mandatory)] [string]$BoundedContext
)

$dir  = "docs\threat-models"
$slug = "$SystemName-$BoundedContext".ToLower() -replace '\s+', '-'
$file = "$dir\$slug.md"
$date = Get-Date -Format "yyyy-MM-dd"

New-Item -ItemType Directory -Force $dir | Out-Null

$template = @"
# Threat Model — $SystemName / $BoundedContext

**Date**: $date
**Participants**: [architect], [developer], [security], [ops]
**Diagram**: docs/architecture/[container-diagram].puml

---

## System Decomposition

[Paste or describe the C4 container diagram elements here]

**Trust Boundaries**:
- [ ] Public Internet → API Gateway
- [ ] API Gateway → Internal Services
- [ ] Services → Data Stores
- [ ] Services → External Systems

---

## Threat Register

| ID | Element | Flow | STRIDE | Threat | DREAD | Mitigation | Status | ADR |
|----|---------|------|--------|--------|-------|------------|--------|-----|
| T001 | | | S | | | | Backlog | |
| T002 | | | T | | | | Backlog | |
| T003 | | | R | | | | Backlog | |
| T004 | | | I | | | | Backlog | |
| T005 | | | D | | | | Backlog | |
| T006 | | | E | | | | Backlog | |

---

## STRIDE Checklist (per trust boundary)

### [ ] Spoofing
- Can any actor claim to be another actor or service?
- Are all service-to-service calls authenticated (mTLS / signed tokens)?

### [ ] Tampering
- Is all data signed or integrity-verified in transit?
- Are audit logs immutable?

### [ ] Repudiation
- Is every sensitive action logged with actor identity and timestamp?
- Are logs tamper-evident?

### [ ] Information Disclosure
- Is all sensitive data encrypted at rest and in transit?
- Do error messages reveal internal details?

### [ ] Denial of Service
- Are rate limits applied at API Gateway and service level?
- Are circuit breakers configured for downstream dependencies?

### [ ] Elevation of Privilege
- Does every service run with the minimum required permissions?
- Are admin APIs separated and additionally protected?

---

## Risk Summary

| Severity | Count | Action |
|----------|-------|--------|
| High (DREAD ≥ 10) | 0 | Mitigate before release |
| Medium (5–9)      | 0 | Mitigate this sprint |
| Low (< 5)         | 0 | Accept with documentation |

---

## Mitigations Backlog (linked to ADRs)

| Threat ID | Mitigation | Owner | Sprint | ADR |
|-----------|------------|-------|--------|-----|
| | | | | |
"@

$template | Out-File $file -Encoding UTF8
Write-Host "Created: $file" -ForegroundColor Green
```

### Python — DREAD Score Calculator

```python
from dataclasses import dataclass

@dataclass
class Threat:
    id: str
    element: str
    category: str        # S/T/R/I/D/E
    description: str
    damage: int          # 0-3
    reproducibility: int # 0-3
    exploitability: int  # 0-3
    affected_users: int  # 0-3
    discoverability: int # 0-3

    @property
    def dread_score(self) -> int:
        return (self.damage + self.reproducibility + self.exploitability +
                self.affected_users + self.discoverability)

    @property
    def severity(self) -> str:
        if self.dread_score >= 10: return "HIGH"
        if self.dread_score >= 5:  return "MEDIUM"
        return "LOW"

def print_threat_report(threats: list[Threat]) -> None:
    threats_sorted = sorted(threats, key=lambda t: t.dread_score, reverse=True)
    print(f"{'ID':<6} {'Category':<10} {'DREAD':<6} {'Severity':<8} Description")
    print("-" * 80)
    for t in threats_sorted:
        print(f"{t.id:<6} {t.category:<10} {t.dread_score:<6} {t.severity:<8} {t.description[:50]}")

# Example
threats = [
    Threat("T001", "API Gateway", "S", "JWT replay attack",
           damage=2, reproducibility=3, exploitability=2, affected_users=3, discoverability=2),
    Threat("T002", "Outbox Relay", "E", "Over-privileged relay process",
           damage=2, reproducibility=1, exploitability=1, affected_users=2, discoverability=1),
]
print_threat_report(threats)
```

### C4 — Security Overlay Annotation (PlantUML)

```plantuml
@startuml ThreatOverlay
!include <C4Container>

' Mark trust boundaries
Boundary(internet, "Public Internet", "Untrusted") {
    Person(user, "User")
}

Boundary(dmz, "DMZ", "Semi-trusted") {
    Container(gateway, "API Gateway", "Kong", "Rate limiting, JWT validation\n[T001: Spoofing — mitigated]\n[T005: DoS — rate limit applied]")
}

Boundary(internal, "Internal Network", "Trusted — Zero Trust controls applied") {
    Container(orderSvc, "Order Service", "Go", "[T003: DoS — circuit breaker]\n[T004: Tampering — HMAC events]")
    ContainerDb(db, "PostgreSQL", "Database", "[T002: Info Disclosure — encrypted]\n[T006: EoP — least-privilege role]")
}

Rel(user, gateway, "HTTPS/TLS 1.3")
Rel(gateway, orderSvc, "mTLS — ADR-0008")
Rel(orderSvc, db, "TLS — least-privilege role")

@enduml
```

---

## Decision Matrix

| System / Context | Threat Modeling Depth | Frequency | Primary Tools |
|---|---|---|---|
| Greenfield system | Full STRIDE per bounded context + all trust boundaries | Kickoff + each major feature | OWASP Threat Dragon, C4 overlay |
| Legacy re-engineering (Strangler Fig) | STRIDE focused on new proxy layer, dual-write paths, migration surfaces | Each extraction step | C4 before/after + threat register |
| Internal tooling (low sensitivity) | Lightweight STRIDE checklist | Once at design, annual review | Markdown threat register |
| High-security (finance, health, regulated) | STRIDE + Attack Trees + Kill Chain + continuous automated scanning | Continuous + each sprint | Microsoft TMT, attack tree tools, Trivy, Semgrep |
| Microservice API | STRIDE focused on trust boundaries between services | Each new service + interface change | C4 overlay, OPA policy review |
| Third-party / external integration | STRIDE focused on data flows in/out + anti-corruption layer | At integration design | Threat register with data classification |

---

## Proficiency Levels

### Awareness
- Can name and explain all six STRIDE categories with one example each.
- Understands what a trust boundary is and why it is a high-priority threat surface.
- Can read a threat register and explain the severity ratings.

### Applied
- Performs STRIDE analysis on a C4 container diagram for a small-to-medium system.
- Produces a threat register with DREAD scores and assigned mitigations.
- Runs `New-ThreatModel.ps1` to scaffold and document a threat model.
- Links identified threats to ADRs and backlog items.

### Master
- Leads threat modeling workshops with cross-functional teams.
- Applies STRIDE per element systematically across large systems with multiple bounded contexts.
- Integrates threat modeling into the development lifecycle: feature design, Strangler Fig migrations, and architecture reviews.
- Extends STRIDE with attack trees for high-risk surfaces (authentication bypass, privilege escalation paths).

### Architect
- Establishes organisation-wide threat modeling practice: tooling standards, process integration, governance, and training.
- Combines STRIDE with MITRE ATT&CK for adversary emulation and red team planning.
- Defines threat modeling requirements for compliance programmes (ISO 27001, SOC 2, PCI DSS).
- Reviews threat models from teams and provides structured feedback on missed threat surfaces and mitigation quality.

---

## AI Prompts

**Generate a threat model from a C4 diagram:**
> Perform a STRIDE threat model on this system based on the following C4 container description: [paste diagram or description]. For each trust boundary and each element, list the STRIDE threats, estimate a DREAD score, and suggest a primary mitigation. Output as a threat register table.

**Review a threat register:**
> Review this threat register for coverage gaps and mitigation quality. Check: Are all trust boundaries covered? Are there any STRIDE categories with no threats identified (likely missed)? Are DREAD scores realistic? Are mitigations specific and actionable? [paste threat register]

**Threat model a migration:**
> I am running a Strangler Fig migration to extract [bounded context] from a legacy monolith. The migration introduces: a new proxy layer, dual-write paths, and a Debezium CDC connection. Produce a STRIDE threat model focused specifically on the migration-specific attack surfaces.

**Write a security ADR from a threat:**
> Threat T004 in our register is: [describe threat]. The chosen mitigation is: [describe mitigation]. Write an ADR documenting the security decision, the threat context, the mitigation approach, the residual risk accepted, and the alternatives considered.

**Prioritise a threat backlog:**
> Here are 12 threats from our threat register with DREAD scores: [paste list]. Recommend a prioritisation order for mitigation, grouping by severity. Flag any threats that should block release. Suggest quick wins that can be mitigated with low effort.

---

## References

**Books**
- Adam Shostack — *Threat Modeling: Designing for Security* (Wiley, 2014) — the definitive practical guide; covers STRIDE, attack trees, and process integration
- Michael Howard & David LeBlanc — *Writing Secure Code* (Microsoft Press) — foundational secure design thinking

**Standards & Frameworks**
- [Microsoft STRIDE Documentation](https://learn.microsoft.com/en-us/azure/security/develop/threat-modeling-tool-threats)
- [OWASP Threat Modeling Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Threat_Modeling_Cheat_Sheet.html)
- [MITRE ATT&CK](https://attack.mitre.org/) — adversary tactics and techniques for advanced threat scenarios

**Tooling**
- [OWASP Threat Dragon](https://owasp.org/www-project-threat-dragon/) — open-source, C4-friendly threat modeling tool
- [Microsoft Threat Modeling Tool](https://learn.microsoft.com/en-us/azure/security/develop/threat-modeling-tool) — STRIDE-native, Windows desktop

**Related Skills**
- `06-security-and-compliance/authentication-and-authorization` — Spoofing and Elevation of Privilege mitigations map directly to the auth skill
- `02-architecture-and-design/c4-model` — C4 container and component diagrams are the starting canvas for every threat model
- `02-architecture-and-design/architecture-decision-records` — every significant threat mitigation decision should be an ADR
- `09-re-engineering-and-evolution/strangler-fig-legacy-modernization` — migration phases introduce new trust boundaries requiring dedicated threat modeling
