<#
.SYNOPSIS
    Build static documentation for the SysSkills library.
.DESCRIPTION
    Generates a MkDocs-based documentation site from the skills/ folder.
    If MkDocs is not installed, it installs it via pip (Python required).
    Alternatively, generates a standalone HTML index when Python is unavailable.
.PARAMETER RepoRoot
    Path to the repository root. Defaults to the parent of this script's folder.
.PARAMETER Serve
    Start the MkDocs dev server after building (live-reload on file changes).
.PARAMETER OutputDir
    Where to write the built site. Defaults to <RepoRoot>/site.
.PARAMETER HtmlOnly
    Skip MkDocs entirely and just generate a plain HTML index of all skills.
.EXAMPLE
    .\Build-Docs.ps1
    .\Build-Docs.ps1 -Serve
    .\Build-Docs.ps1 -HtmlOnly
#>

param(
    [string]$RepoRoot,
    [switch]$Serve,
    [string]$OutputDir,
    [switch]$HtmlOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ====================== RESOLVE PATHS ======================

if (-not $RepoRoot) {
    $RepoRoot = Split-Path $PSScriptRoot -Parent
}

$SkillsRoot = Join-Path $RepoRoot "skills"
$DocsDir    = Join-Path $RepoRoot "docs"
$MkDocsYml  = Join-Path $RepoRoot "mkdocs.yml"

if (-not $OutputDir) {
    $OutputDir = Join-Path $RepoRoot "site"
}

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

function Get-SkillIndex {
    $index = @{}
    if (-not (Test-Path $SkillsRoot)) { return $index }

    Get-ChildItem $SkillsRoot -Directory | Sort-Object Name | ForEach-Object {
        $cat = $_.Name
        $skills = Get-ChildItem $_.FullName -Filter "*.md" -Recurse | Sort-Object Name
        $index[$cat] = @()
        foreach ($f in $skills) {
            $lines = Get-Content $f.FullName
            $fm    = Parse-Frontmatter $lines
            $index[$cat] += [pscustomobject]@{
                Name        = if ($fm["name"]) { $fm["name"] } else { $f.BaseName }
                Slug        = $f.BaseName
                Description = if ($fm["description"]) { $fm["description"] } else { "" }
                Proficiency = if ($fm["proficiency"]) { $fm["proficiency"] } else { "" }
                Status      = if ($fm["status"]) { $fm["status"] } else { "draft" }
                File        = $f.FullName
                RelPath     = $f.FullName.Replace($RepoRoot + "\", "").Replace("\", "/")
            }
        }
    }
    return $index
}

# ====================== HTML-ONLY PATH ======================

function Build-HtmlIndex {
    Write-Host "Generating standalone HTML index..." -ForegroundColor Cyan

    $index = Get-SkillIndex
    $date  = (Get-Date).ToString("yyyy-MM-dd HH:mm")

    $rows = ""
    $totalSkills = 0
    foreach ($cat in ($index.Keys | Sort-Object)) {
        foreach ($skill in $index[$cat]) {
            $statusBadge = switch ($skill.Status) {
                "published"  { "<span class='badge published'>published</span>" }
                "review"     { "<span class='badge review'>review</span>" }
                "deprecated" { "<span class='badge deprecated'>deprecated</span>" }
                default      { "<span class='badge draft'>draft</span>" }
            }
            $rows += "<tr><td>$cat</td><td><strong>$($skill.Name)</strong></td><td>$($skill.Description)</td><td>$($skill.Proficiency)</td><td>$statusBadge</td></tr>`n"
            $totalSkills++
        }
    }

    if ($rows -eq "") {
        $rows = "<tr><td colspan='5' style='text-align:center;color:#888'>No skills found. Run New-Skill.ps1 to add your first skill.</td></tr>"
    }

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>SysSkills Library</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
         background: #0f1117; color: #e6edf3; line-height: 1.6; }
  header { background: #161b22; border-bottom: 1px solid #30363d;
           padding: 1.5rem 2rem; display: flex; align-items: center; gap: 1rem; }
  header h1 { font-size: 1.5rem; font-weight: 700; color: #58a6ff; }
  header span { color: #8b949e; font-size: 0.9rem; }
  .stats { background: #161b22; padding: 1rem 2rem;
           border-bottom: 1px solid #30363d; color: #8b949e; font-size: 0.85rem; }
  main { padding: 2rem; }
  .search-bar { width: 100%; max-width: 500px; padding: 0.5rem 1rem;
                background: #21262d; border: 1px solid #30363d; border-radius: 6px;
                color: #e6edf3; font-size: 1rem; margin-bottom: 1.5rem; outline: none; }
  .search-bar:focus { border-color: #58a6ff; }
  table { width: 100%; border-collapse: collapse; font-size: 0.9rem; }
  th { background: #21262d; color: #8b949e; font-weight: 600; text-align: left;
       padding: 0.75rem 1rem; border-bottom: 1px solid #30363d; }
  td { padding: 0.75rem 1rem; border-bottom: 1px solid #21262d; vertical-align: top; }
  tr:hover td { background: #161b22; }
  .badge { display: inline-block; padding: 0.15rem 0.5rem; border-radius: 12px;
           font-size: 0.75rem; font-weight: 600; }
  .badge.published  { background: #1a4731; color: #3fb950; }
  .badge.review     { background: #2d2a0b; color: #d29922; }
  .badge.draft      { background: #21262d; color: #8b949e; }
  .badge.deprecated { background: #3d1c1c; color: #f85149; }
  footer { text-align: center; padding: 2rem; color: #484f58; font-size: 0.8rem;
           border-top: 1px solid #21262d; margin-top: 2rem; }
</style>
</head>
<body>
<header>
  <h1>SysSkills</h1>
  <span>Universal Systems Construction Library</span>
</header>
<div class="stats">
  $totalSkills skill(s) across $($index.Count) categories &mdash; generated $date
</div>
<main>
  <input class="search-bar" type="text" id="search" placeholder="Filter skills..." oninput="filterTable()">
  <table id="skillTable">
    <thead>
      <tr><th>Category</th><th>Skill</th><th>Description</th><th>Proficiency</th><th>Status</th></tr>
    </thead>
    <tbody>
$rows
    </tbody>
  </table>
</main>
<footer>SysSkills &mdash; Because great systems are not built by accident.</footer>
<script>
function filterTable() {
  const q = document.getElementById('search').value.toLowerCase();
  document.querySelectorAll('#skillTable tbody tr').forEach(row => {
    row.style.display = row.textContent.toLowerCase().includes(q) ? '' : 'none';
  });
}
</script>
</body>
</html>
"@

    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    $outFile = Join-Path $OutputDir "index.html"
    $html | Out-File $outFile -Encoding UTF8

    Write-Host "HTML index written to: $outFile" -ForegroundColor Green
    Write-Host "Open in browser: start '$outFile'" -ForegroundColor Cyan
    Start-Process $outFile
}

# ====================== MKDOCS HELPERS ======================

function Assert-Python {
    if (-not (Get-Command python -ErrorAction SilentlyContinue) -and
        -not (Get-Command python3 -ErrorAction SilentlyContinue)) {
        return $false
    }
    return $true
}

function Assert-MkDocs {
    if (Get-Command mkdocs -ErrorAction SilentlyContinue) { return $true }
    Write-Host "mkdocs not found. Attempting pip install..." -ForegroundColor Yellow
    $py = if (Get-Command python3 -ErrorAction SilentlyContinue) { "python3" } else { "python" }
    & $py -m pip install mkdocs mkdocs-material --quiet
    return (Get-Command mkdocs -ErrorAction SilentlyContinue) -ne $null
}

function Build-MkDocsNav {
    $index = Get-SkillIndex
    $nav   = "nav:`n  - Home: index.md`n"

    foreach ($cat in ($index.Keys | Sort-Object)) {
        $label = $cat -replace '^\d+-', '' -replace '-', ' '
        $label = (Get-Culture).TextInfo.ToTitleCase($label)
        $nav += "  - $($label):`n"
        foreach ($skill in $index[$cat]) {
            # Mirror file into docs/ for mkdocs
            $destDir = Join-Path $DocsDir $cat
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
            Copy-Item $skill.File (Join-Path $destDir "$($skill.Slug).md") -Force
            $nav += "    - $($skill.Name): $cat/$($skill.Slug).md`n"
        }
    }
    return $nav
}

function Write-MkDocsYml {
    $nav = Build-MkDocsNav

    # Create docs/index.md if missing
    New-Item -ItemType Directory -Path $DocsDir -Force | Out-Null
    $indexMd = Join-Path $DocsDir "index.md"
    if (-not (Test-Path $indexMd)) {
        "# SysSkills`n`nUniversal Systems Construction Library.`n`nBrowse the categories in the navigation panel." |
            Out-File $indexMd -Encoding UTF8
    }

    $yml = @"
site_name: SysSkills
site_description: Universal Systems Construction Skills Library
docs_dir: docs
site_dir: site
theme:
  name: material
  palette:
    - scheme: slate
      primary: indigo
      accent: cyan
  features:
    - navigation.tabs
    - navigation.sections
    - search.suggest
    - content.code.copy
plugins:
  - search
$nav
"@
    $yml | Out-File $MkDocsYml -Encoding UTF8
    Write-Host "mkdocs.yml generated" -ForegroundColor Green
}

# ====================== MAIN ======================

Write-Host "SysSkills - Documentation Builder" -ForegroundColor Cyan
Write-Host "==================================" -ForegroundColor Cyan

if ($HtmlOnly) {
    Build-HtmlIndex
    exit 0
}

if (-not (Assert-Python)) {
    Write-Host "Python not found. Falling back to HTML-only mode." -ForegroundColor Yellow
    Build-HtmlIndex
    exit 0
}

if (-not (Assert-MkDocs)) {
    Write-Host "Could not install mkdocs. Falling back to HTML-only mode." -ForegroundColor Yellow
    Build-HtmlIndex
    exit 0
}

Write-Host "Generating mkdocs.yml from skills/..." -ForegroundColor Cyan
Write-MkDocsYml

Push-Location $RepoRoot
try {
    if ($Serve) {
        Write-Host "`nStarting MkDocs dev server (Ctrl+C to stop)..." -ForegroundColor Cyan
        Write-Host "  http://127.0.0.1:8000" -ForegroundColor White
        mkdocs serve
    } else {
        Write-Host "Building site..." -ForegroundColor Cyan
        mkdocs build --site-dir $OutputDir
        Write-Host "Site built: $OutputDir" -ForegroundColor Green
        Write-Host "Open: start '$OutputDir\index.html'" -ForegroundColor Cyan
    }
} finally {
    Pop-Location
}
