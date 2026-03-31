# Setup script: clone repos and/or deploy secure-env-handle scripts
#
# Usage: .\init-env-handle.ps1 [-a]
#
# Flags:
#   -a    Always prompt for GitHub organisation (overrides cached value)
#
# Modes:
#   1) Pull Git repos + setup secure-env-handle (server provisioning)
#   2) Setup secure-env-handle only (development / new project init)
#
# Prerequisites:
#   - Git installed
#   - Docker + Docker Compose installed (for deployment)
#   - GitHub fine-grained token with read-only Contents access (mode 1 only)

param(
    [switch]$a
)

$ErrorActionPreference = "Stop"

$Version = "1.6.14"
$defaultOrg = "Grebec-IT"
$configPath = Join-Path $env:USERPROFILE ".secure-env-handle.json"
$targetDir = Get-Location

# -- Helper: run git without PowerShell intercepting stderr ----------------
# Note: token may appear in git error messages (same as bash variant).
# Using Start-Process avoids PowerShell's own error handling, but git's
# stderr still goes to the console. A credential helper would be the
# proper fix, but is out of scope for this setup script.
function Invoke-Git {
    param([string]$Arguments)
    $proc = Start-Process -FilePath "git" -ArgumentList $Arguments -NoNewWindow -Wait -PassThru
    return $proc.ExitCode
}

# -- Helper: deploy env-handle scripts into a project directory ------------
function Install-EnvHandle {
    param([string]$RepoPath, [string]$RepoName)

    $envHandleDir = Join-Path $RepoPath "secure-env-handle-and-deploy"

    # Always fresh download at the pinned version (folder is gitignored)
    if (Test-Path $envHandleDir) {
        Remove-Item $envHandleDir -Recurse -Force
        Write-Host "    env-scripts - removed old copy" -ForegroundColor Yellow
    }

    Write-Host "    env-scripts - downloading v$Version..." -ForegroundColor Cyan
    $archiveUrl = "https://github.com/${org}/secure-env-handle/archive/refs/tags/v${Version}.zip"
    $tempZip = Join-Path $env:TEMP "secure-env-handle-v${Version}.zip"
    $tempExtract = Join-Path $env:TEMP "secure-env-handle-extract"

    try {
        Invoke-WebRequest -Uri $archiveUrl -OutFile $tempZip -UseBasicParsing -ErrorAction Stop
    } catch {
        Write-Host "    env-scripts - FAILED (tag v$Version may not exist)" -ForegroundColor Red
        return
    }

    # Extract and move the inner folder to the target path
    if (Test-Path $tempExtract) { Remove-Item $tempExtract -Recurse -Force }
    Expand-Archive -Path $tempZip -DestinationPath $tempExtract -Force
    $innerDir = Get-ChildItem -Path $tempExtract -Directory | Select-Object -First 1
    Move-Item $innerDir.FullName $envHandleDir
    Remove-Item $tempZip -Force
    Remove-Item $tempExtract -Recurse -Force

    Write-Host "    env-scripts - installed v$Version" -ForegroundColor Green

    # Remove directories that belong to the source repo only
    foreach ($removeDir in @("docs", ".claude", ".github", "tests")) {
        $nested = Join-Path $envHandleDir $removeDir
        if (Test-Path $nested) { Remove-Item $nested -Recurse -Force }
    }

    # Remove files that belong at parent level only
    foreach ($removeFile in @("init-env-handle.ps1", "init-env-handle.sh", "setup-server.ps1", "README.md", "env_handling.md", "LICENSE")) {
        $nested = Join-Path $envHandleDir $removeFile
        if (Test-Path $nested) { Remove-Item $nested -Force }
    }

    # Filter by OS: remove Linux scripts (this .ps1 script only runs on Windows)
    Get-ChildItem (Join-Path $envHandleDir "*.sh") -ErrorAction SilentlyContinue | Remove-Item -Force

    # -- Ensure .gitignore contains required entries -----------------------
    $gitignorePath = Join-Path $RepoPath ".gitignore"
    $requiredEntries = @(".env", ".env.full", "*.credentials.json", "secure-env-handle-and-deploy/", ".secrets/")

    # Read existing entries (if file exists)
    $existingEntries = @()
    if (Test-Path $gitignorePath) {
        $existingEntries = Get-Content $gitignorePath | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
    }

    # Find which entries are missing
    $missingEntries = $requiredEntries | Where-Object { $_ -notin $existingEntries }

    if ($missingEntries.Count -gt 0) {
        Write-Host ""
        Write-Host "    .gitignore - missing entries for secure-env-handle:" -ForegroundColor Yellow
        foreach ($entry in $missingEntries) {
            Write-Host "      + $entry" -ForegroundColor Yellow
        }
        $approve = Read-Host "    Append to .gitignore? [Y/n]"
        if ($approve -ne "n" -and $approve -ne "N") {
            # Add a blank line separator if file exists and doesn't end with newline
            $prefix = ""
            if ((Test-Path $gitignorePath) -and (Get-Content $gitignorePath -Raw) -notmatch '\n$') {
                $prefix = "`n"
            }
            $block = ($prefix + "`n# secure-env-handle`n" + ($missingEntries -join "`n") + "`n")
            Add-Content -Path $gitignorePath -Value $block -NoNewline
            Write-Host "    .gitignore - updated" -ForegroundColor Green
        } else {
            Write-Host "    .gitignore - skipped (manual update needed)" -ForegroundColor Yellow
        }
    } else {
        Write-Host "    .gitignore - already up to date" -ForegroundColor Green
    }
}

# ==========================================================================
# Version check (public repo, no auth needed)
# ==========================================================================
Write-Host "========================================"
Write-Host "  Secure Env Handle Setup  v$Version"
Write-Host "========================================"
Write-Host ""

# -- Resolve GitHub organisation silently (for version check) ---------------
$cachedOrg = $null
if (Test-Path $configPath) {
    try { $cachedOrg = (Get-Content $configPath -Raw | ConvertFrom-Json).org } catch { }
}
$org = if ($cachedOrg) { $cachedOrg } else { $defaultOrg }

try {
    $tagsUrl = "https://api.github.com/repos/$org/secure-env-handle/tags?per_page=1"
    $tags = Invoke-RestMethod -Uri $tagsUrl -Headers @{ Accept = "application/vnd.github+json" } -TimeoutSec 5
    if ($tags.Count -gt 0) {
        $latestTag = $tags[0].name -replace '^v', ''
        if ($latestTag -eq $Version) {
            Write-Host "  v$Version (up to date)" -ForegroundColor Green
        } else {
            Write-Host "  WARNING: You are running v$Version, latest is v$latestTag" -ForegroundColor Yellow
            Write-Host ""
            Write-Host "  1) Update script (cannot self-update while running)"
            Write-Host "  2) Continue with current version (v$Version)"
            Write-Host ""
            $versionChoice = Read-Host "Choice [1/2]"

            if ($versionChoice -eq "1") {
                $rawUrl = "https://raw.githubusercontent.com/$org/secure-env-handle/v$latestTag/init-env-handle.ps1"
                $scriptPath = $MyInvocation.MyCommand.Path
                if (-not $scriptPath) { $scriptPath = Join-Path (Get-Location) "init-env-handle.ps1" }
                Write-Host ""
                Write-Host "  Downloading v$latestTag..." -ForegroundColor Cyan
                try {
                    Invoke-WebRequest -Uri $rawUrl -OutFile $scriptPath -UseBasicParsing -ErrorAction Stop
                    Write-Host "  Updated: $scriptPath" -ForegroundColor Green
                    Write-Host "  Restarting..." -ForegroundColor Cyan
                    Write-Host ""
                    & $scriptPath @PSBoundParameters
                    exit $LASTEXITCODE
                } catch {
                    Write-Host "  Download failed: $_" -ForegroundColor Red
                    Write-Host "  Continuing with v$Version..." -ForegroundColor Yellow
                }
            }
            Write-Host ""
            Write-Host "  Continuing with v$Version..." -ForegroundColor Yellow
        }
    }
} catch {
    Write-Host "  Could not check for updates (offline?). Continuing with v$Version." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "  1) Pull Git repos + setup secure-env-handle"
Write-Host "  2) Setup secure-env-handle only (existing projects)"
Write-Host ""
$mode = Read-Host "Choose mode (1 or 2)"

if ($mode -ne "1" -and $mode -ne "2") {
    Write-Error "Invalid selection. Please enter 1 or 2."
    exit 1
}

# ==========================================================================
# MODE 1: Clone repos with token, then deploy env-handle
# ==========================================================================
if ($mode -eq "1") {
    Write-Host ""
    Write-Host "--- Mode 1: Pull Git Repos + Setup ---"
    Write-Host ""

    # -- GitHub organisation -----------------------------------------------
    if ($a -or -not $cachedOrg) {
        $suggestion = if ($cachedOrg) { $cachedOrg } else { $defaultOrg }
        $orgInput = Read-Host "  GitHub organisation [$suggestion]"
        $org = if ([string]::IsNullOrWhiteSpace($orgInput)) { $suggestion } else { $orgInput.Trim() }
        @{ org = $org } | ConvertTo-Json | Set-Content $configPath
    } else {
        Write-Host "  Organisation: $org (use -a to change)" -ForegroundColor DarkGray
    }
    Write-Host ""

    # -- GitHub token ------------------------------------------------------
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

    # -- Fetch accessible repos from GitHub API ----------------------------
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

    # -- Select repos ------------------------------------------------------
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

        Install-EnvHandle -RepoPath $repoPath -RepoName $repo
    }

    # Clear token from memory
    $tokenPlain = $null
    $cloneUrl = $null
    [GC]::Collect()
}

# ==========================================================================
# MODE 2: Setup secure-env-handle only (for existing subdirectories)
# ==========================================================================
if ($mode -eq "2") {
    Write-Host ""
    Write-Host "--- Mode 2: Setup Secure Env Handle Only ---"
    Write-Host ""

    # List subdirectories (exclude hidden dirs like .git)
    $subdirs = Get-ChildItem -Path $targetDir -Directory |
        Where-Object { $_.Name -notmatch '^\.' -and $_.Name -ne "secure-env-handle" } |
        Sort-Object Name

    if ($subdirs.Count -eq 0) {
        Write-Error "No project subdirectories found in $targetDir."
        exit 1
    }

    Write-Host "Available projects:"
    for ($i = 0; $i -lt $subdirs.Count; $i++) {
        Write-Host "  $($i+1)) $($subdirs[$i].Name)"
    }
    Write-Host "  A) All"
    Write-Host ""
    $selection = Read-Host "Select projects (comma-separated numbers, or A for all)"

    if ($selection -eq "A" -or $selection -eq "a") {
        $selectedDirs = $subdirs
    } else {
        $indices = $selection -split "," | ForEach-Object { [int]$_.Trim() - 1 }
        $selectedDirs = $indices | ForEach-Object { $subdirs[$_] }
    }

    Write-Host ""
    Write-Host "Will setup env-handle in: $($selectedDirs.Name -join ', ')"
    Write-Host ""

    foreach ($dir in $selectedDirs) {
        Write-Host "  $($dir.Name):" -ForegroundColor Cyan
        Install-EnvHandle -RepoPath $dir.FullName -RepoName $dir.Name
    }
}

# ==========================================================================
Write-Host ""
Write-Host "========================================"
Write-Host "  Setup complete" -ForegroundColor Green
Write-Host "========================================"
Write-Host ""
Write-Host "Next steps:"
Write-Host "  cd <project>\secure-env-handle-and-deploy"
Write-Host "  .\deploy.ps1"
