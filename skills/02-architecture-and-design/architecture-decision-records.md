---
name: "Architecture Decision Records"
slug: architecture-decision-records
category: "02-architecture-and-design"
proficiency: Architect
description: "Capture, evaluate, and communicate architectural decisions in a lightweight, traceable, and maintainable format. Reduces knowledge loss, supports re-engineering, and keeps teams aligned on the why behind every major technical choice."
tags: [adr, architecture, decision-making, documentation, governance, design-records, madr, rfcs]
status: published
---

# Architecture Decision Records (ADR)

## Principles

**Decisions Are First-Class Artifacts**
An architectural decision is as important as the code it produces. If it is not recorded, it will be rediscovered — expensively — by the next engineer who touches the system.

**Capture the Why, Not Just the What**
Code shows what was built. ADRs exist to record the forces, constraints, and trade-offs that made one option better than the alternatives at that point in time. A future reader needs context, not a summary of what already exists in the codebase.

**Lightweight Over Comprehensive**
ADRs should take minutes to write, not hours. A one-page ADR that gets written beats a five-page document that never does. Prefer concise, structured prose over elaborate templates.

**Decisions Are Immutable, Status Is Not**
Never edit the body of an accepted ADR to reverse a decision. Instead, write a new ADR that supersedes it. The historical record of what was decided and why is the value — preserving it is non-negotiable.

**Make Decisions Visible and Debatable**
ADRs should live in the repository alongside the code, be reviewable in pull requests, and be searchable by anyone on the team. Decisions made in Slack threads, meetings, or email are invisible and will be repeated.

**ADRs Are Living in Status Only**
The text of an ADR is immutable once accepted. Its *status* can change: `Proposed → Accepted → Superseded → Deprecated`. Use status to signal the current standing without rewriting history.

---

## Implementation Patterns

### Pattern 1 — Nygard / MADR Format (Recommended)

The most widely adopted ADR format. Concise, structured, and tool-friendly.

```markdown
# ADR-{number}: {Short noun phrase describing the decision}

## Status
Proposed | Accepted | Superseded by ADR-{n} | Deprecated

## Context
What situation forces this decision? Include business constraints, technical debt,
team skills, regulatory requirements, and any time pressure.

## Decision
The decision we made, stated as a single clear sentence, followed by elaboration.
"We will use X because Y."

## Consequences

### Positive
- ...

### Negative
- ...

### Neutral
- ...

## Alternatives Considered

| Option | Reason Rejected |
|---|---|
| Option A | ... |
| Option B | ... |

## References
- Related ADRs: ADR-{n}
- External: links, RFCs, papers
```

### Pattern 2 — Repository Layout

Store ADRs in the source repository so they version alongside the code they describe.

```
docs/
└── decisions/
    ├── 0001-use-postgresql-as-primary-database.md
    ├── 0002-adopt-event-driven-architecture.md
    ├── 0003-use-typescript-across-all-services.md
    └── README.md      ← index with one-line summary per ADR
```

Naming convention: zero-padded sequential number + hyphenated title. Sequential numbers make ordering unambiguous; descriptive titles make the index scannable without opening files.

### Pattern 3 — ADR Lifecycle Management

```
Draft (in PR review)
  ↓
Proposed (merged, open for team comment)
  ↓
Accepted (decision ratified)
  ↓
Superseded by ADR-{n}   ← preferred over "Deprecated" when replaced by a newer decision
     or
Deprecated              ← no longer relevant, not replaced by a specific record
```

Add a mandatory `supersedes:` field in frontmatter when a new ADR replaces an old one, so tooling can surface the chain.

### Pattern 4 — ADR in Pull Request Workflow

Require an ADR for any PR that:
- Introduces a new dependency or technology
- Changes a cross-service interface or contract
- Reverses or significantly modifies a previous architectural decision
- Has architectural impact that will outlast the current sprint

Add the ADR in the same PR as the code change. Reviewers assess both the decision and the implementation together. The PR description links to the ADR number.

### Pattern 5 — Linking ADRs to Other Artifacts

Connect ADRs to the broader system context:

- **Requirements**: `implements: REQ-042` in frontmatter
- **Risks**: `mitigates: RISK-007` — document when an ADR is a deliberate risk response
- **Code**: inline code comment `// see ADR-0023` at the decision point in the source
- **Architecture diagrams**: annotate C4 or sequence diagrams with the ADR number that drove a boundary or pattern choice

---

## Anti-Patterns

| Anti-Pattern | Why It's Harmful | Fix |
|---|---|---|
| Writing ADRs after the fact as documentation theater | Loses the actual decision context; becomes a ratification rubber-stamp | Write ADRs in the PR that implements the decision |
| Editing accepted ADRs to reverse decisions | Destroys the historical record; future readers can't tell what was true when | Write a new superseding ADR; leave the original intact |
| Over-engineering the template | Long templates create friction; engineers avoid writing them | Start with five fields: Status, Context, Decision, Consequences, Alternatives |
| ADRs in a wiki or shared drive | Not versioned with code; diverges; becomes invisible | Store in the repository under `docs/decisions/` |
| Only architects write ADRs | Centralizes knowledge; slows delivery; misses context from implementers | Any engineer can propose an ADR; senior engineers and architects ratify |
| No index or discoverability | ADRs accumulate but nobody reads them | Maintain a `README.md` index; add search tooling (Log4brains, adr-tools) |
| Treating every minor decision as an ADR | ADR fatigue; the signal-to-noise ratio collapses | Reserve ADRs for decisions with lasting architectural impact; use PR comments for smaller choices |

---

## Code Templates

### YAML Frontmatter Extension (Machine-Readable ADRs)

Add structured frontmatter so tooling can index, link, and validate ADRs automatically:

```yaml
---
id: ADR-0042
title: "Use PostgreSQL with JSONB as primary database"
status: accepted          # proposed | accepted | superseded | deprecated
date: 2026-01-15
supersedes: ADR-0031
superseded_by: ~
authors: [sifiso.shezi]
tags: [database, persistence, postgresql]
---
```

### PowerShell — New-ADR Generator

```powershell
# tools/generators/New-ADR.ps1
param(
    [Parameter(Mandatory)]
    [string]$Title
)

$decisionsPath = Resolve-Path "$PSScriptRoot\..\..\docs\decisions"
$existing = Get-ChildItem $decisionsPath -Filter "*.md" | Where-Object { $_.Name -match '^\d+' }
$nextNumber = ($existing.Count + 1).ToString("D4")
$slug = $Title.ToLower() -replace '\s+', '-' -replace '[^a-z0-9\-]', ''
$fileName = "$nextNumber-$slug.md"
$filePath = Join-Path $decisionsPath $fileName
$date = Get-Date -Format "yyyy-MM-dd"

$template = @"
---
id: ADR-$nextNumber
title: "$Title"
status: proposed
date: $date
authors: [$env:USERNAME]
tags: []
---

# ADR-$nextNumber: $Title

## Status
Proposed

## Context


## Decision


## Consequences

### Positive
-

### Negative
-

### Neutral
-

## Alternatives Considered

| Option | Reason Rejected |
|---|---|
| | |

## References
-
"@

$template | Out-File $filePath -Encoding UTF8
Write-Host "Created: $fileName" -ForegroundColor Green
code $filePath
```

### Python — ADR Index Generator

```python
# tools/generators/build_adr_index.py
"""Regenerates docs/decisions/README.md from ADR frontmatter."""
import re
from pathlib import Path

DECISIONS = Path("docs/decisions")
STATUS_ORDER = {"proposed": 0, "accepted": 1, "superseded": 2, "deprecated": 3}

def parse_frontmatter(text: str) -> dict:
    match = re.match(r"^---\n(.*?)\n---", text, re.DOTALL)
    if not match:
        return {}
    fm = {}
    for line in match.group(1).splitlines():
        if ":" in line:
            k, _, v = line.partition(":")
            fm[k.strip()] = v.strip().strip('"')
    return fm

adrs = []
for path in sorted(DECISIONS.glob("*.md")):
    if path.name == "README.md":
        continue
    fm = parse_frontmatter(path.read_text())
    if fm:
        adrs.append((path.name, fm))

lines = ["# Architecture Decision Records\n"]
for name, fm in adrs:
    status = fm.get("status", "unknown")
    title = fm.get("title", name)
    adr_id = fm.get("id", "")
    lines.append(f"- [{adr_id}: {title}]({name}) — `{status}`")

(DECISIONS / "README.md").write_text("\n".join(lines))
print(f"Index updated: {len(adrs)} ADRs")
```

---

## Decision Matrix

| Situation | Recommendation | Notes |
|---|---|---|
| Small team, single repo | Markdown files in `docs/decisions/`, no tooling | Simplest viable approach |
| Multi-repo / multiple teams | Log4brains or adr-tools with CI-generated site | Enables cross-repo linking and a browsable history |
| Regulated environment (finance, health) | YAML frontmatter + automated status validation in CI | Supports audit trails and compliance reporting |
| Decision reversal | New superseding ADR, original left intact | Never edit accepted ADRs |
| Minor implementation choice | PR comment or commit message — not an ADR | Reserve ADRs for lasting architectural impact |
| Need to find what drove a past design | Search by tag, component, or date in the ADR index | Index generation (Pattern 5) pays off here |
| Onboarding a new team member | ADR reading list by component, sorted by date | The ADR log is the fastest path to understanding why the system looks the way it does |

---

## Proficiency Levels

### Awareness
- Can explain what an ADR is, why it exists, and how it differs from inline code comments or wiki pages.
- Knows the standard Nygard template (Context, Decision, Consequences).
- Can read an existing ADR and explain the decision it documents.

### Applied
- Writes clear, concise ADRs for day-to-day decisions in a PR workflow.
- Maintains the correct ADR lifecycle (Proposed → Accepted → Superseded); never edits accepted records.
- Uses adr-tools or Log4brains to manage a growing ADR repository.
- Links ADRs to related records and to decision points in source code.

### Master
- Establishes ADR practice across a team: template, lifecycle, PR requirements, index maintenance.
- Reviews ADRs from teammates and gives structured feedback on context quality and consequence completeness.
- Integrates ADR generation and validation into CI pipelines.
- Uses the ADR log to identify architectural drift and drive re-engineering decisions.

### Architect
- Designs organization-wide ADR governance: template standards, mandatory triggers, quality gates, tooling selection.
- Uses ADRs as input to architecture fitness functions — measures how well the system reflects its recorded decisions.
- Coaches teams on decision-making quality, not just documentation format.
- Builds the ADR corpus as institutional memory that survives team turnover.

---

## AI Prompts

**Write an ADR from a description:**
> Write an ADR using the MADR format for this decision: [describe the decision, the context, and the alternatives you considered]. Include realistic consequences — both positive and negative.

**Review an ADR for quality:**
> Review this ADR for clarity and completeness. Check: Is the context specific enough? Does the decision statement name a single, concrete choice? Are the consequences realistic? Are meaningful alternatives listed with reasons for rejection? [paste ADR]

**Identify missing ADRs from a codebase:**
> Given this list of dependencies and architecture patterns in our codebase, which decisions likely lack ADRs and should be backfilled? [paste dependency list or architecture description]

**Evaluate whether to write an ADR:**
> I'm about to make this technical change: [describe change]. Should this be an ADR or is a PR comment sufficient? Criteria: lasting architectural impact, cross-cutting concern, reversal cost, team alignment needed.

**Supersede an existing ADR:**
> I need to reverse ADR-0031 (PostgreSQL as primary database) in favour of CockroachDB for geo-distributed requirements. Write a new superseding ADR that: references the original, explains the new forces, states the new decision clearly, and documents what must change in the system.

---

## References

**Foundational Reading**
- Michael Nygard — [Documenting Architecture Decisions](https://cognitect.com/blog/2011/11/15/documenting-architecture-decisions) (original post, 2011)
- MADR (Markdown Any Decision Records) — [adr.github.io/madr](https://adr.github.io/madr/)

**Tooling**
- [adr-tools](https://github.com/npryce/adr-tools) — CLI for creating and linking Nygard-style ADRs
- [Log4brains](https://github.com/thomvaill/log4brains) — ADR knowledge base with browsable static site output

**Related Skills**
- `02-architecture-and-design/domain-driven-design` — DDD bounded contexts often drive ADRs on service boundaries
- `09-re-engineering-and-evolution/strangler-fig-pattern` — ADRs are essential for tracking modernization decisions over time
- `06-security-and-compliance/authentication-and-authorization` — see ADR-style decision matrix for auth stack selection
