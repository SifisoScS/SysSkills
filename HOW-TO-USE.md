# How to Use SysSkills on Any Project

> Your personal field guide — from project kickoff to delivery.

---

## The Core Loop

```
Plan → Build → Validate → Document
```

Run this loop on every project, big or small.

---

## Project Type Cheat Sheet

Pick the categories that apply to your project, then dive into those skill files first.

| Project Type | Categories to Focus On |
|---|---|
| Web Application | 02 Architecture, 03 Frontend, 04 Backend, 05 Data, 06 Security |
| Microservices | 02 Architecture, 04 Backend, 07 Infrastructure, 08 Quality |
| Data Platform | 05 Data, 07 Infrastructure, 08 Quality, 06 Security |
| Mobile App | 03 Frontend, 04 Backend, 06 Security |
| Legacy Modernization | 09 Re-engineering, 02 Architecture, 07 Infrastructure |
| AI / ML System | 10 Specialized Domains, 05 Data, 07 Infrastructure |

---

## Step-by-Step Usage

### 1. Kickoff — Identify What You Need

Browse the `skills/` folder and note which categories apply to your project.
Open each relevant skill file and read:
- **Principles** — the mental model for the topic
- **Decision Matrix** — use this to make early choices before writing code

> Tip: Do this before architecture diagrams or tech stack decisions. The Decision Matrices exist specifically for this moment.

---

### 2. Scaffold a Skill as You Work

Every time your project hits a new pattern, tool, or technical decision — capture it:

```powershell
.\tools\generators\New-Skill.ps1
```

You will be prompted for:
- Skill name (e.g. `Event Sourcing`)
- Category (1–11)
- Proficiency level
- Description and tags

The script drops a fully structured `.md` file into the right `skills/` folder with all sections pre-filled as placeholders. Fill them in as you learn.

**Example flow:**
> Deciding between REST and gRPC?
> Scaffold "API Style Selection" under category 04.
> Fill the Decision Matrix with your trade-offs.
> That decision is now documented and reusable on the next project.

---

### 3. Use Skill Files as AI Context (Claude / any LLM)

Paste a skill file directly into your AI prompt as grounding context.

```
Given this skill reference:
[paste contents of skills/02-architecture-and-design/event-sourcing.md]

Review my implementation below and flag any anti-patterns:
[paste your code]
```

Every skill file has a ready-made **AI Prompts** section at the bottom.
Use those prompts as-is — they are tuned to the skill.

**Useful prompt patterns:**

| Goal | Prompt to use |
|---|---|
| Explain a concept | `Explain [Skill Name] to a senior engineer in under 200 words, focusing on the core invariant.` |
| Review your code | `Review this implementation of [Skill Name] and identify any anti-patterns: [paste code]` |
| Compare options | `Compare [Skill Name] with [alternative] for [your context].` |

---

### 4. Code Reviews — Use Anti-Patterns as a Checklist

Before approving a PR, open the skill file for the relevant pattern.
Run through the **Anti-Patterns & Pitfalls** table line by line.

This turns SysSkills into a living review standard — not just a reference doc.

---

### 5. Validate Your Library Health

Run this regularly — weekly, at sprint end, or as a CI step:

```powershell
# Check all skills
.\tools\validators\Validate-Skills.ps1

# Check a single category
.\tools\validators\Validate-Skills.ps1 -Category "06-security-and-compliance"

# Fail the build if errors exist (CI pipelines)
.\tools\validators\Validate-Skills.ps1 -FailOnError
```

Each file gets a **score out of 100** and a pass / warn / fail status.
A score below 60 means key sections are missing — go back and fill them in.

---

### 6. Build and Share Docs

When onboarding someone, writing a design doc, or handing off a project:

```powershell
# Full MkDocs site (requires Python)
.\tools\Build-Docs.ps1

# Live dev server — share with team at localhost:8000
.\tools\Build-Docs.ps1 -Serve

# Single HTML file, no Python needed — email or open in browser
.\tools\Build-Docs.ps1 -HtmlOnly
```

---

## Full Project Lifecycle Map

```
KICKOFF
  ├── Browse skills/ and identify relevant categories
  ├── Read Decision Matrices for your stack/architecture choices
  └── Scaffold skills for each major decision you make

DESIGN PHASE
  ├── Fill in Decision Matrices (DB choice, API style, auth, caching, etc.)
  ├── Paste skill files into Claude prompts to stress-test decisions
  └── Use Principles sections as design review criteria

BUILD PHASE
  ├── Scaffold new skills as new patterns emerge in the code
  ├── Use AI Prompts from skill files when you need implementation help
  └── Reference Code Templates for boilerplate

REVIEW PHASE
  ├── Use Anti-Patterns tables as PR review checklists
  ├── Run Validate-Skills.ps1 to catch incomplete entries
  └── Update skill statuses: draft → review

DELIVERY / HANDOFF
  ├── Run Build-Docs.ps1 to produce stakeholder documentation
  ├── Mark polished skills as: status: published
  └── Archive project-specific skills for reuse next time
```

---

## Skill Status Meanings

| Status | Meaning |
|---|---|
| `draft` | Scaffolded — placeholders not yet filled |
| `review` | Populated — ready for a second pair of eyes |
| `published` | Verified — safe to use as a reference standard |
| `deprecated` | Outdated — do not use for new decisions |

---

## Scripts Quick Reference

| Script | What it does | Run from |
|---|---|---|
| `Setup-SysSkills.ps1` | One-click repo setup, folder structure, tools install | Repo root |
| `tools\generators\New-Skill.ps1` | Scaffold a new skill file interactively | Repo root |
| `tools\validators\Validate-Skills.ps1` | Score and validate all skill files | Repo root |
| `tools\Build-Docs.ps1` | Build MkDocs site or standalone HTML | Repo root |

---

## The Key Mindset

Do not treat SysSkills as a read-only textbook.

Treat it as a **living decision log** that grows with every project.
Each skill you add makes the next project faster to start, easier to review, and simpler to hand off.

---

*SysSkills — Because great systems are not built by accident.*
