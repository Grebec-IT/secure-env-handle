# First-time server setup: clone repos using a GitHub fine-grained token
#
# Usage: .\setup-server.ps1
#
# This script is meant to be manually copied to the target directory
# before any repos exist. It will:
#   1. Clone selected project repos (using token auth)
#   2. Pull secure-env-handle scripts into each project (public, no auth needed)
#   3. Filter scripts by OS (Windows → .ps1, Linux → .sh)
#
# Prerequisites:
#   - Git installed
#   - Docker + Docker Compose installed
#   - GitHub fine-grained token with read-only Contents access

$ErrorActionPreference = "Stop"

Write-Host "========================================"
Write-Host "  Server Setup: Clone Repos"
Write-Host "========================================"
Write-Host ""

# -- GitHub token -------------------------------------------------------
Write-Host "Enter your GitHub fine-grained token (read-only):"
Write-Host "(from: GitHub > Settings > Developer settings > Fine-grained tokens)"
Write-Host ""
$token = Read-Host -AsSecureString "Token"
$tokenPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($token)
)

if ([string]::IsNullOrWhiteSpace($tokenPlain)) {
    Write-Error "No token provided."
    exit 1
}

$org = "Grebec-IT"
$targetDir = Get-Location
$envHandleRepo = "https://github.com/Grebec-IT/secure-env-handle.git"

# -- Fetch accessible repos from GitHub API -----------------------------
Write-Host ""
Write-Host "Fetching repos your token has access to..."
$headers = @{
    Authorization = "Bearer $tokenPlain"
    Accept = "application/vnd.github+json"
    "X-GitHub-Api-Version" = "2022-11-28"
}

try {
    $allRepos = Invoke-RestMethod -Uri "https://api.github.com/user/repos?per_page=100" -Headers $headers
} catch {
    Write-Error "Failed to list repos. Check your token."
    exit 1
}

# Filter to our org only, exclude secure-env-handle itself
$orgRepos = $allRepos | Where-Object {
    $_.owner.login -eq $org -and $_.name -ne "secure-env-handle"
} | ForEach-Object { $_.name } | Sort-Object

if ($orgRepos.Count -eq 0) {
    Write-Error "No repos found for org $org. Check token permissions."
    exit 1
}

# -- Select repos -------------------------------------------------------
Write-Host ""
Write-Host "Available repos (from token permissions):"
for ($i = 0; $i -lt $orgRepos.Count; $i++) {
    Write-Host "  $($i+1)) $($orgRepos[$i])"
}
Write-Host "  A) All"
Write-Host ""
$selection = Read-Host "Select repos (comma-separated numbers, or A for all)"

if ($selection -eq "A" -or $selection -eq "a") {
    $selectedRepos = $orgRepos
} else {
    $indices = $selection -split "," | ForEach-Object { [int]$_.Trim() - 1 }
    $selectedRepos = $indices | ForEach-Object { $orgRepos[$_] }
}

Write-Host ""
Write-Host "Will clone: $($selectedRepos -join ', ')"
Write-Host "Into: $targetDir"
Write-Host ""

# -- Helper: run git without PowerShell intercepting stderr -------------
function Invoke-Git {
    param([string]$Arguments)
    $proc = Start-Process -FilePath "git" -ArgumentList $Arguments -NoNewWindow -Wait -PassThru
    return $proc.ExitCode
}

# -- Detect OS ----------------------------------------------------------
$isWindows = $env:OS -eq "Windows_NT"

# -- Clone / Pull project repos ----------------------------------------
$cloneUrl = "https://x-access-token:${tokenPlain}@github.com/${org}"

foreach ($repo in $selectedRepos) {
    $repoPath = Join-Path $targetDir $repo

    if (Test-Path $repoPath) {
        Write-Host "  $repo - already exists, pulling..." -ForegroundColor Yellow
        Push-Location $repoPath
        $exit = Invoke-Git "pull --ff-only"
        Pop-Location
        if ($exit -ne 0) {
            Write-Host "  $repo - pull FAILED" -ForegroundColor Red
        } else {
            Write-Host "  $repo - updated" -ForegroundColor Green
        }
    } else {
        Write-Host "  $repo - cloning..." -ForegroundColor Cyan
        $exit = Invoke-Git "clone ${cloneUrl}/${repo}.git ${repoPath}"
        if ($exit -ne 0) {
            Write-Host "  $repo - FAILED" -ForegroundColor Red
            continue
        } else {
            Write-Host "  $repo - cloned" -ForegroundColor Green
        }
    }

    # -- Pull secure-env-handle scripts into project --------------------
    $envHandleDir = Join-Path $repoPath "secure-env-handle-and-deploy"

    if (Test-Path $envHandleDir) {
        Write-Host "    env-scripts - updating..." -ForegroundColor Yellow
        Push-Location $envHandleDir
        $exit = Invoke-Git "pull --ff-only"
        Pop-Location
        if ($exit -ne 0) {
            Write-Host "    env-scripts - update FAILED" -ForegroundColor Red
        } else {
            Write-Host "    env-scripts - updated" -ForegroundColor Green
        }
    } else {
        Write-Host "    env-scripts - cloning..." -ForegroundColor Cyan
        $exit = Invoke-Git "clone ${envHandleRepo} ${envHandleDir}"
        if ($exit -ne 0) {
            Write-Host "    env-scripts - FAILED" -ForegroundColor Red
            continue
        } else {
            Write-Host "    env-scripts - cloned" -ForegroundColor Green
        }
    }

    # Remove setup-server.ps1 from subfolder (belongs at parent level only)
    $nestedSetup = Join-Path $envHandleDir "setup-server.ps1"
    if (Test-Path $nestedSetup) { Remove-Item $nestedSetup -Force }

    # Remove README from subfolder (not needed for operations)
    $nestedReadme = Join-Path $envHandleDir "README.md"
    if (Test-Path $nestedReadme) { Remove-Item $nestedReadme -Force }

    # Filter by OS: remove scripts for the other platform
    if ($isWindows) {
        Get-ChildItem (Join-Path $envHandleDir "*.sh") -ErrorAction SilentlyContinue | Remove-Item -Force
    } else {
        Get-ChildItem (Join-Path $envHandleDir "*.ps1") -ErrorAction SilentlyContinue | Remove-Item -Force
    }
}

# Clear token from memory
$tokenPlain = $null
$cloneUrl = $null
[GC]::Collect()

Write-Host ""
Write-Host "========================================"
Write-Host "  Setup complete" -ForegroundColor Green
Write-Host "========================================"
Write-Host ""
Write-Host "Next steps:"
Write-Host "  cd <project>\secure-env-handle-and-deploy"
Write-Host "  .\deploy.ps1"
