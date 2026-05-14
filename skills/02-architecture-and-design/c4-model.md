---
name: "C4 Model for Software Architecture"
slug: c4-model
category: "02-architecture-and-design"
proficiency: Architect
description: "Master the C4 Model for diagramming software architecture at four levels of abstraction (Context, Containers, Components, Code). Enables clear communication to technical and non-technical stakeholders while keeping diagrams accurate and maintainable."
tags: [c4-model, architecture, diagrams, structurizr, plantuml, visualization, documentation, diagrams-as-code]
status: published
---

# C4 Model for Software Architecture

## Principles

**Abstraction First**
Different audiences need different levels of detail. A CTO needs the system context; a developer needs the component view. Never show a developer a context diagram and call it done, and never show a business stakeholder a class diagram and expect understanding.

**Strict Hierarchy**
The four levels are not interchangeable. Each level zooms into the previous one. A container diagram shows what runs; a component diagram shows what lives inside one container. Mixing levels in a single diagram destroys clarity.

**Ubiquitous Language**
Use the same terms as the domain and the team. If the team calls something a "Payment Gateway", the diagram says "Payment Gateway" — not "External Financial System Adapter". Diagram labels should be readable without a legend.

**Diagrams as Code (Preferred)**
Diagrams stored as code (Structurizr DSL, PlantUML) live in version control, diff in PRs, and can be regenerated automatically. Diagrams as image files rot: they fall out of sync with reality and nobody updates them.

**Every Diagram Has a Purpose**
Draw only what a specific audience needs to answer a specific question. An unfocused diagram that tries to show everything answers nothing. If you cannot name the question your diagram answers, do not draw it.

**Keep Diagrams Current or Mark Them Disposable**
A stale architecture diagram is worse than no diagram — it actively misleads. Either automate generation from code (Structurizr) or add a last-verified date and mark diagrams that are known approximations.

---

## Implementation Patterns

### The Four Levels

| Level | Audience | Shows | Granularity |
|---|---|---|---|
| **1 — System Context** | Business stakeholders, non-technical | Your system + users + external dependencies | Boxes and arrows, no technology |
| **2 — Container** | Technical leads, operations | Applications, databases, message queues, CDNs — the deployment units | Technology labels per box |
| **3 — Component** | Developers | Major building blocks inside one container, their responsibilities and interactions | Interfaces, services, repositories |
| **4 — Code** | Developers | Classes, interfaces, patterns inside one component | UML class or sequence diagrams |

Draw levels 1 and 2 for every system. Draw level 3 for the containers that are complex or frequently misunderstood. Draw level 4 sparingly — IDEs and code are better at this than diagrams.

### Pattern 1 — Structurizr DSL (Diagrams as Code)

Structurizr DSL defines a workspace: people, systems, containers, and components, then specifies which views to render. One model, multiple views — change the model once and all diagrams update.

```
workspace "SysSkills Platform" {

    model {
        engineer = person "Engineer" "Uses the skills library"
        sysSkills = softwareSystem "SysSkills Platform" "AI-native skills library"
        github = softwareSystem "GitHub" "Source control and CI/CD" "External"

        engineer -> sysSkills "Reads skills, runs tools"
        sysSkills -> github "Stores skill files and ADRs"
    }

    views {
        systemContext sysSkills "Context" {
            include *
            autolayout lr
        }

        styles {
            element "Person" { shape Person }
            element "External" { background #999999 }
        }
    }
}
```

### Pattern 2 — PlantUML + C4-PlantUML

For teams already using PlantUML in Markdown or pipelines, `C4-PlantUML` provides macros that enforce C4 notation without Structurizr.

```plantuml
@startuml Context
!include <C4Context>

Person(engineer, "Engineer", "Uses the skills library on any project")
System(sysSkills, "SysSkills Platform", "AI-native skills and architecture library")
System_Ext(github, "GitHub", "Source control, CI/CD, and PR reviews")
System_Ext(mkdocs, "MkDocs Site", "Generated documentation, served locally")

Rel(engineer, sysSkills, "Reads skills, runs validators")
Rel(sysSkills, github, "Stores skill files, ADRs, tooling")
Rel(sysSkills, mkdocs, "Builds and serves docs", "Build-Docs.ps1")

@enduml
```

```plantuml
@startuml Containers
!include <C4Container>

Person(engineer, "Engineer")

System_Boundary(sysSkills, "SysSkills Platform") {
    Container(skillLib, "Skill Library", "Markdown + YAML", "Skills organised in 11 category folders")
    Container(validator, "Validator", "PowerShell", "Scores skill files 0-100")
    Container(generator, "Generator", "PowerShell", "Scaffolds new skill files interactively")
    Container(docSite, "Docs Site", "MkDocs / HTML", "Browsable documentation from skill metadata")
}

System_Ext(github, "GitHub", "Version control and CI")

Rel(engineer, generator, "Runs to scaffold new skills")
Rel(engineer, validator, "Runs to check quality")
Rel(generator, skillLib, "Writes new skill files to")
Rel(validator, skillLib, "Reads and scores")
Rel(docSite, skillLib, "Reads metadata from")
Rel(skillLib, github, "Committed and versioned in")

@enduml
```

### Pattern 3 — Overlay Views

Start with the base C4 model, then create overlay views for specific concerns:

- **Security overlay**: shade trust boundaries and highlight where authentication/authorization occurs
- **Deployment overlay**: map containers to infrastructure (Kubernetes namespace, cloud region, on-prem server)
- **Data flow overlay**: highlight which containers handle PII or sensitive data — useful for GDPR/compliance reviews
- **Failure domain overlay**: draw blast radius boundaries for SRE and chaos engineering planning

Overlays reuse the same model; they only change what is highlighted. In Structurizr this is a filtered or decorated view. In PlantUML it is a separate file that includes the shared model.

### Pattern 4 — C4 in Pull Request Workflow

Treat diagram changes like code changes:
1. Structurizr DSL or PlantUML source lives in `docs/architecture/`
2. A CI step renders diagrams to PNG/SVG on every PR
3. Reviewers see the rendered diff alongside the DSL diff
4. Diagram is never manually exported — the pipeline owns the output

### Pattern 5 — Linking C4 to ADRs

Annotate C4 diagrams with ADR references at the points where decisions shaped the design:

```
Container(db, "PostgreSQL 16", "Database", "Primary data store — see ADR-0042")
Rel(api, db, "Reads/writes", "TCP 5432 — ADR-0042")
```

This connects the visual model to the reasoning behind it and gives readers a path from diagram to decision.

---

## Anti-Patterns

| Anti-Pattern | Why It's Harmful | Fix |
|---|---|---|
| One giant diagram showing everything | Overwhelms every audience; nothing is clear at any abstraction level | Separate views per level; one question per diagram |
| Mixing abstraction levels | A container diagram with class-level detail confuses the audience about what they are looking at | Strict level separation; if something doesn't fit a level, reconsider whether it belongs |
| Exported image files in the repo | Stale within weeks; impossible to diff; nobody updates them | Source in DSL/PlantUML; CI generates images |
| Using C4 only for final documentation | Diagrams are drawn after the fact to describe what was built, not to reason about what to build | Draw level 1 and 2 before implementation begins; use them in design reviews |
| Diagram without a named audience | Trying to serve everyone serves no one | Every diagram file should have a comment: "Audience: X, Question answered: Y" |
| Overloading with UML stereotypes | Obscures the simple box-and-arrow clarity that makes C4 approachable | Stick to C4 notation; use UML only at level 4 where class structure matters |
| Never reviewing diagrams after changes | System evolves; diagrams don't; new engineers are misled | Add diagram review to the definition of done for major feature work |

---

## Code Templates

### Structurizr DSL — Full Workspace Template

```
workspace "{System Name}" {

    !docs docs/architecture

    model {
        # People
        user = person "End User" "Primary user of the system"
        admin = person "Administrator" "Manages configuration"

        # External systems
        idp = softwareSystem "Identity Provider" "OIDC/OAuth2 provider" "External"
        email = softwareSystem "Email Service" "Transactional email" "External"

        # Our system
        platform = softwareSystem "{System Name}" "Description of what it does" {
            webApp   = container "Web Application" "User-facing SPA" "React / TypeScript"
            api      = container "API Server" "Business logic and data access" "Go"
            db       = container "Database" "Primary data store" "PostgreSQL 16" "Database"
            queue    = container "Message Queue" "Async task processing" "RabbitMQ" "Queue"
            worker   = container "Background Worker" "Processes queued tasks" "Go"
        }

        # Relationships
        user  -> webApp "Uses" "HTTPS"
        admin -> webApp "Manages via" "HTTPS"
        webApp -> api   "Calls" "REST / HTTPS"
        api    -> db    "Reads/writes" "TCP 5432"
        api    -> queue "Publishes events to" "AMQP"
        worker -> queue "Consumes from" "AMQP"
        worker -> db    "Reads/writes" "TCP 5432"
        api    -> idp   "Delegates auth to" "OIDC"
        worker -> email "Sends via" "SMTP/API"
    }

    views {
        systemContext platform "01-SystemContext" "System context for {System Name}" {
            include *
            autolayout lr
        }

        container platform "02-Containers" "Container view for {System Name}" {
            include *
            autolayout lr
        }

        styles {
            element "Person"   { shape Person background #08427b color #ffffff }
            element "Database" { shape Cylinder }
            element "Queue"    { shape Pipe }
            element "External" { background #999999 color #ffffff }
            relationship "Relationship" { dashed false }
        }
    }
}
```

### GitHub Actions — Auto-Render Diagrams on PR

```yaml
# .github/workflows/diagrams.yml
name: Render Architecture Diagrams

on:
  push:
    paths:
      - 'docs/architecture/**'

jobs:
  render:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Render PlantUML diagrams
        uses: cloudbees/plantuml-github-action@master
        with:
          args: -tsvg docs/architecture

      - name: Commit rendered diagrams
        run: |
          git config user.name "github-actions"
          git config user.email "actions@github.com"
          git add docs/architecture/**/*.svg
          git diff --staged --quiet || git commit -m "ci: regenerate architecture diagrams"
          git push
```

### PowerShell — New-C4Diagram scaffold

```powershell
# tools/generators/New-C4Diagram.ps1
param(
    [Parameter(Mandatory)] [string]$SystemName,
    [ValidateSet("context","container","component")] [string]$Level = "context"
)

$dir  = "docs\architecture\$($SystemName.ToLower() -replace '\s+','-')"
$file = "$dir\$Level.puml"
New-Item -ItemType Directory -Force $dir | Out-Null

$header = "# Audience: architects + tech leads | Question: What are the major moving parts of $SystemName?"

$stub = switch ($Level) {
    "context"   { "@startuml Context`n!include <C4Context>`n`nPerson(user, `"User`", `"`")`nSystem(sys, `"$SystemName`", `"`")`n`nRel(user, sys, `"Uses`")`n@enduml" }
    "container" { "@startuml Containers`n!include <C4Container>`n`nSystem_Boundary(sys, `"$SystemName`") {`n    Container(app, `"App`", `"Tech`", `"Desc`")`n}`n@enduml" }
    "component" { "@startuml Components`n!include <C4Component>`n`nContainer_Boundary(app, `"App`") {`n    Component(svc, `"Service`", `"Tech`", `"Desc`")`n}`n@enduml" }
}

"' $header`n$stub" | Out-File $file -Encoding UTF8
Write-Host "Created: $file" -ForegroundColor Green
```

---

## Decision Matrix

| Situation | Recommended Tool | Notes |
|---|---|---|
| Solo / small team | PlantUML + C4-PlantUML macros | Lives in Markdown, renders in GitHub |
| Large org, multiple systems | Structurizr DSL + Structurizr Lite (self-hosted) | One workspace per team, shared model elements |
| Quick design workshop | Excalidraw with C4 shape library | Disposable — export and discard after the meeting |
| Living documentation site | Structurizr + MkDocs integration | Auto-generated from DSL on every merge |
| Compliance / audit trail | Structurizr DSL in Git + rendered SVGs committed | Diagrams are versioned and timestamped |
| Security threat modelling | C4 context/container as base, overlay trust zones | Combine with STRIDE (see threat-modeling skill) |
| Legacy system re-engineering | Before/after container diagrams | Makes the migration scope visible to stakeholders |

---

## Proficiency Levels

### Awareness
- Can explain the four C4 levels and name the target audience for each.
- Can read a C4 diagram and describe what the system does without needing the author to explain it.
- Knows the difference between a container (deployment unit) and a component (building block inside a container).

### Applied
- Creates all four levels for a small-to-medium system using PlantUML or Structurizr.
- Maintains diagrams in version control; updates them when the system changes.
- Chooses the right level for the right audience without prompting.

### Master
- Uses Structurizr DSL to model a large distributed system with multiple bounded contexts.
- Creates overlay views (security, deployment, data flow) from a single shared model.
- Integrates diagram generation into CI/CD pipelines.
- Links C4 diagrams to ADRs, DDD bounded contexts, and threat models.

### Architect
- Establishes C4 as the organization-wide visualization standard with agreed tooling, templates, and governance.
- Builds automated pipelines that regenerate and publish diagrams on every architecture change.
- Trains and coaches teams; reviews diagrams for accuracy, audience fit, and level discipline.
- Uses C4 as the primary communication tool in architecture reviews, RFCs, and stakeholder briefings.

---

## AI Prompts

**Generate a diagram from a description:**
> Write a PlantUML C4 container diagram for this system: [describe system, major components, databases, external dependencies]. Use C4-PlantUML macros. Include a comment at the top naming the audience and the question this diagram answers.

**Review a diagram for quality:**
> Review this C4 diagram for clarity and correctness. Check: Is it a single abstraction level? Is the audience obvious? Are technology labels present on containers? Are relationships labelled with protocol or interaction type? [paste PlantUML or DSL]

**Design an overlay:**
> Take this C4 container diagram and produce a security overlay version that highlights: trust boundaries, where authentication occurs, where data is encrypted in transit and at rest, and which components handle PII. [paste diagram]

**Identify missing diagrams:**
> Given this system description, which C4 levels are missing and would provide the most value to the team? Which audience is currently under-served by the existing diagrams? [paste system description and existing diagram list]

**Convert whiteboard to code:**
> I have this informal architecture description from a whiteboard session: [describe components and connections]. Convert it into a valid Structurizr DSL workspace with a system context view and a container view.

---

## References

**Foundational**
- Simon Brown — [C4 Model](https://c4model.com/) — the definitive reference; read the FAQ before starting
- Simon Brown — *Software Architecture for Developers* (Vol. 2)

**Tooling**
- [Structurizr DSL](https://github.com/structurizr/dsl) — diagrams-as-code workspace definition
- [Structurizr Lite](https://structurizr.com/help/lite) — self-hosted, no account required
- [C4-PlantUML](https://github.com/plantuml-stdlib/C4-PlantUML) — C4 macros for PlantUML
- [IcePanel](https://icepanel.io/) — collaborative C4 diagramming with team annotations

**Related Skills**
- `02-architecture-and-design/architecture-decision-records` — link ADR numbers to diagram elements
- `06-security-and-compliance/authentication-and-authorization` — use C4 security overlay to map auth boundaries
- `09-re-engineering-and-evolution/strangler-fig-pattern` — before/after C4 container diagrams drive re-engineering scope
