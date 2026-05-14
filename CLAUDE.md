# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

---

## What This Repository Is

**SysSkills** is an AI-native skills library — a structured, Markdown-based knowledge base for software architecture, engineering practices, and system design patterns. It is currently in Phase 1: tooling is complete, skill content population is in progress.

Skills live in `skills/` (11 category folders). Each skill is a `.md` file with YAML frontmatter + 8 required sections. The PowerShell tooling manages scaffolding, validation, and documentation generation.

---

## Common Commands

All scripts are run from the `SysSkills/` directory (repo root):

```powershell
# First-time setup — creates folder structure, installs tools via winget
.\Setup-SysSkills.ps1

# Scaffold a new skill (interactive prompts)
.\tools\generators\New-Skill.ps1

# Scaffold non-interactively
.\tools\generators\New-Skill.ps1 -Name "Event Sourcing" -Category 2

# Validate all skill files (quality score 0–100 per file)
.\tools\validators\Validate-Skills.ps1

# Validate a single category
.\tools\validators\Validate-Skills.ps1 -Category "06-security-and-compliance"

# Fail with exit code 1 if any file has errors (use in CI)
.\tools\validators\Validate-Skills.ps1 -FailOnError

# Build standalone HTML index (no Python needed)
.\tools\Build-Docs.ps1 -HtmlOnly

# Build full MkDocs site (requires Python + MkDocs)
.\tools\Build-Docs.ps1

# Live dev server at localhost:8000
.\tools\Build-Docs.ps1 -Serve
```

---

## Skill File Structure

Every skill file must have:

**YAML frontmatter fields** (required — each worth ~5.7 pts toward a 100-pt score):
```yaml
---
name: "Event Sourcing"
slug: event-sourcing
category: "04-backend-and-services"
proficiency: Applied          # Awareness | Applied | Master | Architect
description: "..."
tags: [cqrs, eventing, ddd]
status: draft                 # draft | review | published | deprecated
---
```

**Required sections** (each worth ~7.5 pts, 60 pts total):
- `## Principles` — mental models, core invariants
- `## Implementation Patterns` — how-to, step-by-step
- `## Anti-Patterns` — pitfalls with explanation
- `## Code Templates` — working code in relevant languages
- `## Decision Matrix` — when to use vs alternatives
- `## Proficiency Levels` — what each level looks like in practice
- `## AI Prompts` — ready-made prompts tuned to this skill
- `## References` — case studies, papers, links

A file scoring below 60/100 is considered incomplete.

---

## Skill Categories

| # | Folder | Focus |
|---|---|---|
| 01 | `01-foundations` | CS fundamentals, paradigms, systems thinking |
| 02 | `02-architecture-and-design` | Styles, patterns, trade-offs, ADRs |
| 03 | `03-frontend-and-ux` | Component architecture, performance, a11y |
| 04 | `04-backend-and-services` | API design, orchestration, real-time |
| 05 | `05-data-and-persistence` | Modeling, databases, caching, consistency |
| 06 | `06-security-and-compliance` | Threat modeling, authz, cryptography, Zero Trust |
| 07 | `07-infrastructure-and-operations` | IaC, Kubernetes, observability, platform engineering |
| 08 | `08-quality-testing-observability` | Testing pyramid, SRE, chaos engineering |
| 09 | `09-re-engineering-and-evolution` | Strangler Fig, modernization, tech debt |
| 10 | `10-specialized-domains` | OS, AI/ML, Embedded, Blockchain |
| 11 | `11-cross-cutting` | Documentation, ethics, cost optimization |

---

## Tooling Architecture

- **`New-Skill.ps1`** — generates a slug from the skill name (`ToLower`, spaces→hyphens, strip non-alphanumeric), writes the file to the correct category folder with all 8 sections pre-filled as placeholders.
- **`Validate-Skills.ps1`** — parses YAML frontmatter between `---` delimiters, checks each required field and section, emits per-file scores and an overall library health summary. Uses `Set-StrictMode -Version Latest`.
- **`Build-Docs.ps1`** — auto-generates `mkdocs.yml` from skill metadata and mirrors files into `docs/`; falls back to a single searchable HTML file when Python/MkDocs is unavailable.

---

## Priority Skill Areas (Next to Populate)

Per the project roadmap: Security & Compliance (06), Architecture & Design (02), Re-engineering (09), Operating Systems (10).
