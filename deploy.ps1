# Deploy script: load env, start Docker containers
# Usage: .\deploy.ps1
#
# Run from: <project>/secure-env-handle-and-deploy/
# Operates on the parent project directory.
#
# Env source priority:
#   1. Existing .env file (allows manual edits)
#   2. DPAPI credential store (envs/{env}.credentials.json)
#   3. Encrypted .age file (asks for passphrase)
#
# When envs/secrets.keys exists, the loaded env is automatically split:
#   - .env contains config-only entries (used by env_file:)
#   - .secrets/KEY files contain secret values (used by secrets: file:)
# Secrets never appear in .env — not even temporarily.

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path $PSScriptRoot -Parent
Set-Location $ProjectRoot
[System.IO.Directory]::SetCurrentDirectory($ProjectRoot)
Add-Type -AssemblyName System.Security

$ProjectName = Split-Path $ProjectRoot -Leaf

# -- Helper: split full env into config + secret files -------------------------
function Split-EnvSecrets {
    param([string]$SourceFile = ".env.full")

    $manifest = Join-Path "envs" "secrets.keys"
    if (-not (Test-Path $manifest)) { return $false }

    $secretKeys = Get-Content $manifest |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith("#") }

    if ($secretKeys.Count -eq 0) { return $false }

    # Parse source file and split
    $configLines = @()
    $splitCount = 0
    $secretDir = ".secrets"
    if (Test-Path $secretDir) { Remove-Item $secretDir -Recurse -Force }
    New-Item -ItemType Directory -Path $secretDir -Force | Out-Null

    Get-Content $SourceFile | ForEach-Object {
        $line = $_.Trim()
        if (-not $line -or $line.StartsWith("#")) {
            $configLines += $_
            return
        }
        $eqIdx = $line.IndexOf("=")
        if ($eqIdx -le 0) {
            $configLines += $_
            return
        }
        $key = $line.Substring(0, $eqIdx).Trim()
        $value = $line.Substring($eqIdx + 1).Trim()

        if ($key -in $secretKeys) {
            # Write secret file (raw value, no trailing newline)
            $secretPath = Join-Path $secretDir $key
            [System.IO.File]::WriteAllText($secretPath, $value)
            $splitCount++
        } else {
            $configLines += $_
        }
    }

    # Write config-only .env — secrets never appear in this file
    $configLines | Set-Content -Path ".env" -Encoding UTF8

    Write-Host "      Secrets: $splitCount key(s) -> .secrets/" -ForegroundColor Cyan
    return $true
}

Write-Host "========================================"
Write-Host "  Deploy: $ProjectName"
Write-Host "========================================"
Write-Host ""

# -- Step 1: Select environment -----------------------------------------
$EnvName = ""
while (-not $EnvName) {
    Write-Host "[1/3] Select environment:" -ForegroundColor Cyan
    Write-Host "  1) dev"
    Write-Host "  2) prod"
    $choice = Read-Host "Choice [1/2]"

    switch ($choice) {
        { $_ -in "1", "dev" }  { $EnvName = "dev" }
        { $_ -in "2", "prod" } { $EnvName = "prod" }
        default {
            Write-Host "Invalid input. Please enter 1 or 2." -ForegroundColor Yellow
        }
    }
}

Write-Host "Selected: $EnvName"
Write-Host ""

# -- Step 2: Load env into .env.full ------------------------------------
# All sources load into .env.full first — secrets never touch .env directly.
Write-Host "[2/3] Loading environment..." -ForegroundColor Cyan

$envLoaded = $false
$fromSource = ""

# Try 1: Existing .env file (highest priority — allows manual edits)
if (Test-Path ".env") {
    Copy-Item ".env" ".env.full" -Force
    $envLoaded = $true
    $fromSource = "existing .env file"
}

# Try 2: DPAPI credential store
$credFile = Join-Path "envs" "$EnvName.credentials.json"
if ((-not $envLoaded) -and (Test-Path $credFile)) {
    $store = Get-Content -Path $credFile -Raw | ConvertFrom-Json
    $lines = @()
    foreach ($prop in ($store.PSObject.Properties | Sort-Object Name)) {
        try {
            $encrypted = [Convert]::FromBase64String($prop.Value)
            $bytes = [Security.Cryptography.ProtectedData]::Unprotect(
                $encrypted, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser
            )
            $value = [Text.Encoding]::UTF8.GetString($bytes)
            $lines += "$($prop.Name)=$value"
        } catch {
            Write-Host "      WARNING: Could not decrypt $($prop.Name)" -ForegroundColor Yellow
        }
    }
    if ($lines.Count -gt 0) {
        $lines | Set-Content -Path ".env.full" -Encoding UTF8
        $envLoaded = $true
        $fromSource = "Credential Manager (DPAPI)"
    }
}

# Try 3: Encrypted .age file
if (-not $envLoaded) {
    $ageFile = Join-Path "envs" "$EnvName.env.age"
    if (Test-Path $ageFile) {
        if (-not (Get-Command age -ErrorAction SilentlyContinue)) {
            Write-Error "age not found. Install with: winget install FiloSottile.age"
            exit 1
        }
        Write-Host "      No .env or credential store found. Decrypting $ageFile..."
        age --decrypt --output .env.full $ageFile
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Decryption failed."
            exit 1
        }
        $envLoaded = $true
        $fromSource = "age-encrypted file"
    }
}

if (-not $envLoaded) {
    Write-Error "No env source found. Create a .env file, run store-env-to-credentials.ps1, or encrypt-env.ps1 first."
    exit 1
}

Write-Host "      Loaded from: $fromSource" -ForegroundColor Green

# Split .env.full → .env (config) + .secrets/ (secrets)
$secretsSplit = Split-EnvSecrets -SourceFile ".env.full"
if (-not $secretsSplit) {
    # No secrets manifest — full content becomes .env
    Move-Item ".env.full" ".env" -Force
}
Write-Host ""

# -- Step 3: Start containers -------------------------------------------
Write-Host "[3/3] Starting Docker containers..." -ForegroundColor Cyan
docker compose up --build -d

if ($LASTEXITCODE -ne 0) {
    Write-Error "docker compose failed."
    exit 1
}

Write-Host ""
Write-Host "      Containers running:"
docker compose ps
Write-Host ""

# -- Cleanup: save to credential store if not already there -------------
if ($fromSource -ne "Credential Manager (DPAPI)") {
    Write-Host "Save to Windows Credential Manager for next deploy? (no passphrase needed next time)"
    $doSave = $null
    while ($null -eq $doSave) {
        $save = Read-Host "[Y/n]"
        if ($save -eq "" -or $save -in "Y", "y") { $doSave = $true }
        elseif ($save -in "N", "n") { $doSave = $false }
        else { Write-Host "Invalid input. Please enter Y or N." -ForegroundColor Yellow }
    }
    if ($doSave) {
        # Read full env (from .env.full which has all entries including secrets)
        $envSource = if (Test-Path ".env.full") { ".env.full" } else { ".env" }
        $entries = @{}
        Get-Content $envSource | ForEach-Object {
            $line = $_.Trim()
            if ($line -and -not $line.StartsWith("#")) {
                $eqIdx = $line.IndexOf("=")
                if ($eqIdx -gt 0) {
                    $key = $line.Substring(0, $eqIdx).Trim()
                    $value = $line.Substring($eqIdx + 1).Trim()
                    $bytes = [Text.Encoding]::UTF8.GetBytes($value)
                    $encrypted = [Security.Cryptography.ProtectedData]::Protect(
                        $bytes, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser
                    )
                    $entries[$key] = [Convert]::ToBase64String($encrypted)
                }
            }
        }
        $dir = Join-Path $ProjectRoot "envs"
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $entries | ConvertTo-Json | Set-Content -Path $credFile -Encoding UTF8
        Write-Host "      Saved $($entries.Count) entries to credential store." -ForegroundColor Green
    }
}

# Delete .env (credentials are in DPAPI or user chose to keep)
if (Test-Path ".env") {
    if ($fromSource -eq "Credential Manager (DPAPI)") {
        Remove-Item .env -Force
        Write-Host "      .env deleted (loaded from credential store)." -ForegroundColor Green
    } else {
        Write-Host ""
        Write-Host "Delete .env from disk?"
        while ($true) {
            $del = Read-Host "[Y/n]"
            if ($del -eq "" -or $del -in "Y", "y") {
                Remove-Item .env -Force
                Write-Host "      .env deleted." -ForegroundColor Green
                break
            }
            if ($del -in "N", "n") { break }
            Write-Host "Invalid input. Please enter Y or N." -ForegroundColor Yellow
        }
    }
}

# Clean up intermediate file
if (Test-Path ".env.full") { Remove-Item ".env.full" -Force }

# .secrets/ persists — Docker Compose bind-mounts these into containers.
# Cleaned up on 'docker compose down' via env-run.
if ($secretsSplit) {
    Write-Host "      .secrets/ kept (required by running containers)." -ForegroundColor Cyan
}

Write-Host ""
Write-Host "========================================"
Write-Host "  Deploy complete: $EnvName" -ForegroundColor Green
Write-Host "========================================"
