<#
.SYNOPSIS
    SysSkills - One-Click Setup & Initialization Script for Windows
.DESCRIPTION
    Sets up the complete SysSkills repository, creates folder structure,
    installs required tools, configures Git, and launches the development environment.
#>

param(
    [string]$TargetPath = "$HOME\Projects\sys-skills",
    [switch]$Force
)

Write-Host "SysSkills - Universal Systems Skills Library Setup" -ForegroundColor Cyan
Write-Host "===================================================" -ForegroundColor Cyan

# ====================== FUNCTIONS ======================
function Test-Admin {
    $currentUser = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $currentUser.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

function Install-Tool {
    param([string]$Name, [string]$Command)
    if (-not (Get-Command $Command -ErrorAction SilentlyContinue)) {
        Write-Host "Installing $Name..." -ForegroundColor Yellow
        try {
            winget install --id $Name --silent | Out-Null
            Write-Host "$Name installed" -ForegroundColor Green
        } catch {
            Write-Warning "Failed to install $Name via winget"
        }
    } else {
        Write-Host "$Name already installed" -ForegroundColor Green
    }
}

# ====================== MAIN SETUP ======================

# Check for Administrator (recommended)
if (-not (Test-Admin)) {
    Write-Warning "Running without Administrator privileges. Some installations may fail."
}

# Create target directory
if (Test-Path $TargetPath) {
    if ($Force) {
        Write-Host "Force mode enabled - cleaning existing folder" -ForegroundColor Yellow
        Remove-Item $TargetPath -Recurse -Force
    } else {
        Write-Host "Target folder already exists: $TargetPath" -ForegroundColor Yellow
        $continue = Read-Host "Continue anyway? (Y/N)"
        if ($continue -notmatch '^[Yy]') { exit }
    }
}

New-Item -ItemType Directory -Path $TargetPath -Force | Out-Null
Set-Location $TargetPath

Write-Host "Working directory: $TargetPath" -ForegroundColor Green

# Install required tools
Write-Host "`nInstalling required tools..." -ForegroundColor Cyan

Install-Tool "Git.Git" "git"
Install-Tool "Microsoft.VisualStudioCode" "code"
Install-Tool "Microsoft.PowerShell" "pwsh"

# Clone or Initialize Repository
if (Test-Path ".git") {
    Write-Host "Repository already initialized. Pulling latest changes..." -ForegroundColor Green
    git pull
} else {
    Write-Host "Cloning SysSkills repository..." -ForegroundColor Cyan
    git clone https://github.com/yourusername/sys-skills.git . 2>$null

    if ($LASTEXITCODE -ne 0) {
        Write-Host "No remote repo found. Initializing new repository..." -ForegroundColor Yellow
        git init
        git branch -M main
    }
}

# Create Full Folder Structure
Write-Host "`nCreating complete folder structure..." -ForegroundColor Cyan

$folders = @(
    "skills/01-foundations",
    "skills/02-architecture-and-design",
    "skills/03-frontend-and-ux",
    "skills/04-backend-and-services",
    "skills/05-data-and-persistence",
    "skills/06-security-and-compliance",
    "skills/07-infrastructure-and-operations",
    "skills/08-quality-testing-observability",
    "skills/09-re-engineering-and-evolution",
    "skills/10-specialized-domains/operating-systems",
    "skills/11-cross-cutting",
    "templates/code",
    "templates/diagrams",
    "templates/prompts",
    "templates/adr",
    "examples/case-studies",
    "schemas",
    "tools/validators",
    "tools/generators",
    "assets/images",
    "docs"
)

foreach ($folder in $folders) {
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
}

Write-Host "Folder structure created" -ForegroundColor Green

# Create README.md
@"
# SysSkills
Universal Systems Construction Skills Library

## Quick Start
1. Run ``Setup-SysSkills.ps1``
2. Explore ``skills/`` folder
3. Open in VS Code

Built for architects and AI agents.
"@ | Out-File README.md -Encoding UTF8

# Create .gitignore
@"
# OS
Thumbs.db
.DS_Store

# Editors
.vscode/
.idea/

# Node
node_modules/
dist/

# Logs
*.log
"@ | Out-File .gitignore -Encoding UTF8

# Create basic skill schema
@"
{
  "`$schema": "http://json-schema.org/draft-07/schema#",
  "title": "SysSkills Skill Definition",
  "type": "object"
}
"@ | Out-File schemas/skill.schema.json -Encoding UTF8

Write-Host "Core files created" -ForegroundColor Green

# Open in VS Code
if (Get-Command code -ErrorAction SilentlyContinue) {
    Write-Host "`nOpening project in Visual Studio Code..." -ForegroundColor Cyan
    code .
}

Write-Host "`nSysSkills setup completed successfully!" -ForegroundColor Magenta
Write-Host "Location: $TargetPath" -ForegroundColor White
Write-Host "`nNext steps:" -ForegroundColor Yellow
Write-Host "   1. Review and customize README.md"
Write-Host "   2. Start populating skills/ folders"
Write-Host "   3. Run 'tools/generators/New-Skill.ps1' (when created) to scaffold new skills"

Start-Sleep -Seconds 3
