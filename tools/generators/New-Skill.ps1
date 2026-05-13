<#
.SYNOPSIS
    Scaffold a new SysSkills skill entry.
.DESCRIPTION
    Interactively prompts for skill metadata and generates a fully structured
    Markdown skill file in the correct category folder.
.PARAMETER Name
    Skill name (e.g. "Event Sourcing"). If omitted, prompted interactively.
.PARAMETER Category
    Category number 01-11. If omitted, prompted interactively.
.PARAMETER SkillsRoot
    Path to the skills/ folder. Defaults to two levels up from this script.
.EXAMPLE
    .\New-Skill.ps1
    .\New-Skill.ps1 -Name "Event Sourcing" -Category 02
#>

param(
    [string]$Name,
    [ValidateRange(1,11)]
    [int]$Category,
    [string]$SkillsRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ====================== CONFIG ======================

$CategoryMap = [ordered]@{
    1  = "01-foundations"
    2  = "02-architecture-and-design"
    3  = "03-frontend-and-ux"
    4  = "04-backend-and-services"
    5  = "05-data-and-persistence"
    6  = "06-security-and-compliance"
    7  = "07-infrastructure-and-operations"
    8  = "08-quality-testing-observability"
    9  = "09-re-engineering-and-evolution"
    10 = "10-specialized-domains"
    11 = "11-cross-cutting"
}

$ProficiencyLevels = @("Awareness", "Applied", "Master", "Architect")

# ====================== HELPERS ======================

function Get-SlugFromName([string]$input) {
    $input.ToLower() -replace '\s+', '-' -replace '[^a-z0-9\-]', ''
}

function Show-CategoryMenu {
    Write-Host "`nSelect a category:" -ForegroundColor Cyan
    foreach ($key in $CategoryMap.Keys) {
        Write-Host "  [$key] $($CategoryMap[$key])"
    }
    do {
        $choice = Read-Host "Enter number (1-11)"
    } while ($choice -notmatch '^\d+$' -or [int]$choice -lt 1 -or [int]$choice -gt 11)
    return [int]$choice
}

function Show-ProficiencyMenu {
    Write-Host "`nDefault proficiency level:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $ProficiencyLevels.Count; $i++) {
        Write-Host "  [$($i+1)] $($ProficiencyLevels[$i])"
    }
    do {
        $choice = Read-Host "Enter number (1-4)"
    } while ($choice -notmatch '^[1-4]$')
    return $ProficiencyLevels[[int]$choice - 1]
}

# ====================== RESOLVE ROOT ======================

if (-not $SkillsRoot) {
    # Script lives at tools/generators/ — skills/ is two levels up
    $SkillsRoot = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) "skills"
}

if (-not (Test-Path $SkillsRoot)) {
    Write-Error "skills/ folder not found at: $SkillsRoot`nPass -SkillsRoot to specify it explicitly."
}

# ====================== GATHER INPUT ======================

Write-Host "SysSkills - New Skill Generator" -ForegroundColor Cyan
Write-Host "================================" -ForegroundColor Cyan

if (-not $Name) {
    $Name = Read-Host "`nSkill name (e.g. 'Event Sourcing')"
    if ([string]::IsNullOrWhiteSpace($Name)) { Write-Error "Skill name cannot be empty." }
}

if (-not $Category) {
    $Category = Show-CategoryMenu
}

$proficiency = Show-ProficiencyMenu

$description = Read-Host "`nOne-line description"
$tags        = Read-Host "Tags (comma-separated, e.g. patterns,distributed)"

$slug       = Get-SlugFromName $Name
$date       = (Get-Date).ToString("yyyy-MM-dd")
$tagList    = ($tags -split ',') | ForEach-Object { "  - $($_.Trim())" }
$tagsYaml   = $tagList -join "`n"
$categoryDir = $CategoryMap[$Category]
$outputDir  = Join-Path $SkillsRoot $categoryDir
$outputFile = Join-Path $outputDir "$slug.md"

if (Test-Path $outputFile) {
    $overwrite = Read-Host "`n$slug.md already exists. Overwrite? (Y/N)"
    if ($overwrite -notmatch '^[Yy]') { Write-Host "Aborted." -ForegroundColor Yellow; exit }
}

# ====================== GENERATE FILE ======================

$template = @"
---
name: $Name
slug: $slug
category: $categoryDir
proficiency: $proficiency
description: "$description"
tags:
$tagsYaml
created: $date
updated: $date
status: draft
---

# $Name

> $description

---

## Principles & Mental Models

- <!-- Core principle 1 -->
- <!-- Core principle 2 -->
- <!-- Core principle 3 -->

---

## Implementation Patterns

### Pattern 1: <!-- Name -->

```
<!-- Code or pseudo-code example -->
```

**When to use:** <!-- Context -->
**Trade-offs:** <!-- Pros and cons -->

---

## Anti-Patterns & Pitfalls

| Anti-Pattern | Problem | Remedy |
|---|---|---|
| <!-- Name --> | <!-- What goes wrong --> | <!-- How to fix --> |

---

## Code Templates

### <!-- Language / Framework -->

```
<!-- Starter template -->
```

---

## Decision Matrix

| Factor | Option A | Option B | Recommendation |
|---|---|---|---|
| <!-- Factor --> | <!-- A --> | <!-- B --> | <!-- Rec --> |

---

## Proficiency Levels

| Level | What you can do |
|---|---|
| **Awareness** | Understands what $Name is and when it applies |
| **Applied** | Implements $Name in real projects with guidance |
| **Master** | Designs solutions using $Name independently; spots trade-offs |
| **Architect** | Evaluates, adapts, and teaches $Name across org-wide systems |

---

## AI Prompts

```
Explain $Name to a senior engineer in under 200 words, focusing on the core invariant.
```

```
Review this implementation of $Name and identify any anti-patterns: [paste code]
```

```
Compare $Name with [alternative approach] for [specific context].
```

---

## References & Case Studies

- <!-- Link or citation 1 -->
- <!-- Link or citation 2 -->

---

*Status: draft — populate sections and change status to `review` when ready.*
"@

New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
$template | Out-File $outputFile -Encoding UTF8

Write-Host "`nSkill file created:" -ForegroundColor Green
Write-Host "  $outputFile" -ForegroundColor White
Write-Host "`nNext: open the file and populate the placeholder sections." -ForegroundColor Yellow
