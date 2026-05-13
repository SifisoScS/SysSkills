# SysSkills

**Universal Systems Construction Library**

A comprehensive, modular, and AI-native skills library for designing, building, evolving, and re-engineering **any software system** — from web and mobile applications to distributed platforms, cloud-native systems, and full operating systems.

![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)
![Version](https://img.shields.io/badge/version-0.1.0-orange)
![Status](https://img.shields.io/badge/status-in--progress-yellow)

---

## Vision

**SysSkills** captures battle-tested architectural knowledge, engineering practices, security principles, and system design wisdom in a structured, searchable, and executable format.

It serves as the single source of truth for:
- Senior engineers and architects
- Development teams building complex systems
- AI agents and code copilots
- Educational and onboarding programs
- Legacy system modernization initiatives

---

## Quick Start

```powershell
# 1. Run the one-click setup (creates folder structure, installs tools)
.\Setup-SysSkills.ps1

# 2. Scaffold your first skill
.\tools\generators\New-Skill.ps1

# 3. Validate the library
.\tools\validators\Validate-Skills.ps1

# 4. Build and view the docs
.\tools\Build-Docs.ps1 -HtmlOnly
```

> See [HOW-TO-USE.md](HOW-TO-USE.md) for a full project lifecycle guide.

---

## Repository Structure

```
sys-skills/
├── README.md
├── HOW-TO-USE.md                    # Field guide for using SysSkills on projects
├── Setup-SysSkills.ps1              # One-click setup script
├── skills/                          # Core skill library
│   ├── 01-foundations/
│   ├── 02-architecture-and-design/
│   ├── 03-frontend-and-ux/
│   ├── 04-backend-and-services/
│   ├── 05-data-and-persistence/
│   ├── 06-security-and-compliance/
│   ├── 07-infrastructure-and-operations/
│   ├── 08-quality-testing-observability/
│   ├── 09-re-engineering-and-evolution/
│   ├── 10-specialized-domains/
│   └── 11-cross-cutting/
├── templates/                       # Code skeletons, diagrams, ADRs, prompts
├── examples/                        # Case studies and reference projects
├── schemas/                         # JSON schemas and taxonomy
├── docs/                            # Generated documentation source
├── tools/
│   ├── Build-Docs.ps1               # Generates MkDocs site or standalone HTML
│   ├── generators/
│   │   └── New-Skill.ps1            # Interactive skill scaffold generator
│   └── validators/
│       └── Validate-Skills.ps1      # Quality checker and scorer
└── assets/images/
```

---

## Skill Categories

| # | Category | Focus Areas |
|---|---|---|
| 01 | Foundations | CS fundamentals, paradigms, systems thinking |
| 02 | Architecture & Design | Styles, patterns, trade-offs, ADRs |
| 03 | Frontend & User Experience | Component architecture, performance, accessibility |
| 04 | Backend & Services | API design, orchestration, real-time systems |
| 05 | Data & Persistence | Modeling, databases, caching, consistency |
| 06 | Security & Compliance | Threat modeling, authz, cryptography, Zero Trust |
| 07 | Infrastructure & Operations | IaC, Kubernetes, observability, platform engineering |
| 08 | Quality, Testing & Observability | Testing pyramid, SRE practices, chaos engineering |
| 09 | Re-engineering & Evolution | Strangler Fig, modernization, debt management |
| 10 | Specialized Domains | Operating Systems, AI/ML, Embedded, Blockchain |
| 11 | Cross-Cutting Practices | Documentation, ethics, cost optimization |

---

## Skill Structure

Every skill file contains:

- **Metadata** (YAML frontmatter)
- **Principles & Mental Models**
- **Implementation Patterns**
- **Anti-patterns & Pitfalls**
- **Code Templates** (multiple languages)
- **Decision Matrices**
- **Proficiency Levels** — Awareness → Applied → Master → Architect
- **AI Prompts**
- **References & Real-world Case Studies**

---

## Scripts Reference

| Script | Purpose |
|---|---|
| `Setup-SysSkills.ps1` | One-click repo setup — folder structure, tools, Git init |
| `tools\generators\New-Skill.ps1` | Scaffold a new skill interactively |
| `tools\validators\Validate-Skills.ps1` | Score and validate all skill files |
| `tools\Build-Docs.ps1` | Build MkDocs site or standalone HTML index |

---

## Current Status

**Phase 1 (In Progress):** Core taxonomy + tooling complete  
**Next:** Populate high-priority skill areas — Security & Compliance, Architecture & Design, Re-engineering, Operating Systems

---

## Contributing

Preferred contributions:
- New skill entries or expansions
- Real-world case studies
- Code templates and examples
- Improved decision frameworks
- Corrections and updates

---

## License

Licensed under the **Apache License 2.0** — free to use, modify, and distribute in both commercial and open-source projects.

---

*SysSkills — Because great systems are not built by accident.*
