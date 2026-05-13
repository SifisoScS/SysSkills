<#
.SYNOPSIS
    Validate all skill files in the SysSkills library.
.DESCRIPTION
    Scans every .md file under skills/, checks required frontmatter fields,
    required content sections, and reports a per-file quality score plus
    an overall library health summary.
.PARAMETER SkillsRoot
    Path to the skills/ folder. Defaults to two levels up from this script.
.PARAMETER FailOnError
    Exit with code 1 if any file fails validation (useful in CI pipelines).
.PARAMETER Category
    Validate only a specific category folder (e.g. "02-architecture-and-design").
.EXAMPLE
    .\Validate-Skills.ps1
    .\Validate-Skills.ps1 -FailOnError
    .\Validate-Skills.ps1 -Category "06-security-and-compliance"
#>

param(
    [string]$SkillsRoot,
    [switch]$FailOnError,
    [string]$Category
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ====================== RULES ======================

$RequiredFrontmatter = @(
    "name", "slug", "category", "proficiency", "description", "tags", "status"
)

$ValidProficiencies = @("Awareness", "Applied", "Master", "Architect")
$ValidStatuses      = @("draft", "review", "published", "deprecated")

$RequiredSections = @(
    "## Principles",
    "## Implementation Patterns",
    "## Anti-Patterns",
    "## Code Templates",
    "## Decision Matrix",
    "## Proficiency Levels",
    "## AI Prompts",
    "## References"
)

# Each section is worth equal points toward a 100-point score
$SectionWeight     = [math]::Floor(60 / $RequiredSections.Count)
$FrontmatterWeight = [math]::Floor(40 / $RequiredFrontmatter.Count)

# ====================== HELPERS ======================

function Parse-Frontmatter([string[]]$lines) {
    $fm = @{}
    $inBlock = $false
    foreach ($line in $lines) {
        if ($line -eq '---') {
            if (-not $inBlock) { $inBlock = $true; continue }
            else { break }
        }
        if ($inBlock -and $line -match '^(\w[\w-]*):\s*(.*)$') {
            $fm[$Matches[1]] = $Matches[2].Trim('"').Trim("'")
        }
    }
    return $fm
}

function Write-Issue([string]$msg, [string]$severity) {
    $color = switch ($severity) {
        "error"   { "Red" }
        "warning" { "Yellow" }
        default   { "Gray" }
    }
    Write-Host "    [$($severity.ToUpper())] $msg" -ForegroundColor $color
}

# ====================== RESOLVE ROOT ======================

if (-not $SkillsRoot) {
    $SkillsRoot = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) "skills"
}

if (-not (Test-Path $SkillsRoot)) {
    Write-Error "skills/ folder not found at: $SkillsRoot`nPass -SkillsRoot to specify it explicitly."
}

$searchRoot = if ($Category) { Join-Path $SkillsRoot $Category } else { $SkillsRoot }

if (-not (Test-Path $searchRoot)) {
    Write-Error "Category folder not found: $searchRoot"
}

# ====================== SCAN ======================

Write-Host "SysSkills - Skill Validator" -ForegroundColor Cyan
Write-Host "===========================" -ForegroundColor Cyan
Write-Host "Root: $SkillsRoot`n" -ForegroundColor Gray

$files = Get-ChildItem -Path $searchRoot -Filter "*.md" -Recurse | Sort-Object FullName

if ($files.Count -eq 0) {
    Write-Host "No skill files found. Add .md files under skills/ to begin." -ForegroundColor Yellow
    exit 0
}

$results     = @()
$totalErrors = 0

foreach ($file in $files) {
    $relPath = $file.FullName.Replace($SkillsRoot, "skills")
    Write-Host $relPath -ForegroundColor White

    $lines   = Get-Content $file.FullName
    $content = $lines -join "`n"
    $issues  = @()
    $score   = 0

    # --- Frontmatter ---
    $fm = Parse-Frontmatter $lines

    foreach ($field in $RequiredFrontmatter) {
        if ($fm.ContainsKey($field) -and -not [string]::IsNullOrWhiteSpace($fm[$field])) {
            $score += $FrontmatterWeight
        } else {
            $issues += [pscustomobject]@{ Msg = "Missing frontmatter field: '$field'"; Severity = "error" }
        }
    }

    if ($fm.ContainsKey("proficiency") -and $fm["proficiency"] -notin $ValidProficiencies) {
        $issues += [pscustomobject]@{
            Msg      = "Invalid proficiency '$($fm["proficiency"])'. Must be one of: $($ValidProficiencies -join ', ')"
            Severity = "error"
        }
    }

    if ($fm.ContainsKey("status") -and $fm["status"] -notin $ValidStatuses) {
        $issues += [pscustomobject]@{
            Msg      = "Invalid status '$($fm["status"])'. Must be one of: $($ValidStatuses -join ', ')"
            Severity = "error"
        }
    }

    # --- Sections ---
    foreach ($section in $RequiredSections) {
        if ($content -match [regex]::Escape($section)) {
            $score += $SectionWeight
        } else {
            $issues += [pscustomobject]@{ Msg = "Missing section: '$section'"; Severity = "warning" }
        }
    }

    # --- Placeholder check (warns if draft markers left in non-draft files) ---
    if ($fm["status"] -ne "draft" -and $content -match '<!--') {
        $issues += [pscustomobject]@{
            Msg      = "Status is '$($fm["status"])' but file still contains <!-- --> placeholders"
            Severity = "warning"
        }
    }

    # Clamp score
    $score = [math]::Min($score, 100)

    $status = if ($issues | Where-Object Severity -eq "error") { "FAIL" }
              elseif ($issues | Where-Object Severity -eq "warning") { "WARN" }
              else { "PASS" }

    $statusColor = switch ($status) {
        "PASS" { "Green" }
        "WARN" { "Yellow" }
        "FAIL" { "Red" }
    }

    Write-Host "  Status: $status   Score: $score/100" -ForegroundColor $statusColor

    foreach ($issue in $issues) {
        Write-Issue $issue.Msg $issue.Severity
    }

    $errorCount = ($issues | Where-Object Severity -eq "error").Count
    $totalErrors += $errorCount

    $results += [pscustomobject]@{
        File    = $relPath
        Status  = $status
        Score   = $score
        Errors  = $errorCount
        Warnings = ($issues | Where-Object Severity -eq "warning").Count
    }

    Write-Host ""
}

# ====================== SUMMARY ======================

$passed   = ($results | Where-Object Status -eq "PASS").Count
$warned   = ($results | Where-Object Status -eq "WARN").Count
$failed   = ($results | Where-Object Status -eq "FAIL").Count
$avgScore = if ($results.Count -gt 0) { [math]::Round(($results | Measure-Object Score -Average).Average, 1) } else { 0 }

Write-Host "===============================" -ForegroundColor Cyan
Write-Host "SUMMARY" -ForegroundColor Cyan
Write-Host "===============================" -ForegroundColor Cyan
Write-Host "  Files scanned : $($results.Count)"
Write-Host "  Passed        : $passed"  -ForegroundColor Green
Write-Host "  Warnings      : $warned"  -ForegroundColor Yellow
Write-Host "  Failed        : $failed"  -ForegroundColor Red
Write-Host "  Avg score     : $avgScore / 100"
Write-Host ""

if ($results.Count -gt 0) {
    Write-Host "Top files by score:" -ForegroundColor Cyan
    $results | Sort-Object Score -Descending | Select-Object -First 5 |
        ForEach-Object { Write-Host "  $($_.Score)/100  $($_.File)" }
}

if ($FailOnError -and $totalErrors -gt 0) {
    Write-Host "`nValidation failed with $totalErrors error(s)." -ForegroundColor Red
    exit 1
}
