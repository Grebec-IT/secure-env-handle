# General-purpose env runner: load env, execute command, clean up
#
# Usage:
#   .\env-run.ps1 dev "docker compose up --build -d"
#   .\env-run.ps1 dev "docker compose run --rm app pytest"
#   .\env-run.ps1 dev "docker compose exec app bash"
#   .\env-run.ps1 dev "docker compose down -v"
#
# Run from: <project>/secure-env-handle-and-deploy/
# Operates on the parent project directory.
#
# Env source priority (same as deploy.ps1):
#   1. Existing .env file (allows manual edits)
#   2. DPAPI credential store (envs/{env}.credentials.json)
#   3. Encrypted .age file (asks for passphrase)
#
# Safety: commands containing "migrate" or data-destructive operations
# require typing a confirmation word before execution.

param(
    [Parameter(Mandatory=$true, Position=0)]
    [ValidateSet("dev", "prod")]
    [string]$EnvName,

    [Parameter(Mandatory=$true, Position=1)]
    [string]$Command
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path $PSScriptRoot -Parent
Set-Location $ProjectRoot
Add-Type -AssemblyName System.Security

$ProjectName = Split-Path $ProjectRoot -Leaf

# -- Helper: split .env into config + secret files -------------------------
function Split-EnvSecrets {
    $manifest = Join-Path "envs" "secrets.keys"
    if (-not (Test-Path $manifest)) { return $false }

    $secretKeys = Get-Content $manifest |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith("#") }

    if ($secretKeys.Count -eq 0) { return $false }

    # Backup full .env before splitting
    Copy-Item ".env" ".env.full" -Force

    # Parse .env
    $configLines = @()
    $splitCount = 0
    $secretDir = ".secrets"
    if (-not (Test-Path $secretDir)) { New-Item -ItemType Directory -Path $secretDir -Force | Out-Null }

    Get-Content ".env" | ForEach-Object {
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
            $secretPath = Join-Path $secretDir $key
            [System.IO.File]::WriteAllText($secretPath, $value)
            $splitCount++
        } else {
            $configLines += $_
        }
    }

    $configLines | Set-Content -Path ".env" -Encoding UTF8

    Write-Host "  Secrets: $splitCount key(s) -> .secrets/" -ForegroundColor Cyan
    return $true
}

Write-Host "========================================"
Write-Host "  Run: $ProjectName ($EnvName)"
Write-Host "========================================"
Write-Host ""
Write-Host "  Command: $Command"
Write-Host ""

# -- Safety: confirm destructive commands -----------------------------------
$cmdLower = $Command.ToLower()

if ($cmdLower -match 'migrate') {
    Write-Host "  WARNING: This command involves a migration." -ForegroundColor Yellow
    Write-Host ""
    $confirm = Read-Host "  Type 'migrate' to confirm"
    if ($confirm -ne "migrate") {
        Write-Host "  Aborted." -ForegroundColor Red
        exit 1
    }
    Write-Host ""
}

if ($cmdLower -match 'down\s+.*(-v\b|--volumes)|volume\s+(rm|prune)|system\s+prune|\breset\b') {
    Write-Host "  WARNING: This command will destroy data." -ForegroundColor Red
    Write-Host ""
    $confirm = Read-Host "  Type 'reset' to confirm"
    if ($confirm -ne "reset") {
        Write-Host "  Aborted." -ForegroundColor Red
        exit 1
    }
    Write-Host ""
}

# -- Load .env (same priority as deploy.ps1) --------------------------------
Write-Host "Loading environment..." -ForegroundColor Cyan

$envCreated = $false
$fromSource = ""

# Try 1: Existing .env file (highest priority — allows manual edits)
if (Test-Path ".env") {
    $fromSource = "existing .env file"
}

# Try 2: DPAPI credential store
$credFile = Join-Path "envs" "$EnvName.credentials.json"
if ((-not $fromSource) -and (Test-Path $credFile)) {
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
            Write-Host "  WARNING: Could not decrypt $($prop.Name)" -ForegroundColor Yellow
        }
    }
    if ($lines.Count -gt 0) {
        $lines | Set-Content -Path ".env" -Encoding UTF8
        $envCreated = $true
        $fromSource = "Credential Manager (DPAPI)"
    }
}

# Try 3: Encrypted .age file
if (-not $fromSource) {
    $ageFile = Join-Path "envs" "$EnvName.env.age"
    if (Test-Path $ageFile) {
        if (-not (Get-Command age -ErrorAction SilentlyContinue)) {
            Write-Error "age not found. Install with: winget install FiloSottile.age"
            exit 1
        }
        Write-Host "  No .env or credential store found. Decrypting $ageFile..."
        Write-Host "  Enter passphrase:"
        age --decrypt --output .env $ageFile
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Decryption failed."
            exit 1
        }
        $envCreated = $true
        $fromSource = "age-encrypted file"
    }
}

if (-not $fromSource) {
    Write-Error "No env source found. Create a .env file, run store-env-to-credentials.ps1, or encrypt-env.ps1 first."
    exit 1
}

Write-Host "  Loaded from: $fromSource" -ForegroundColor Green

# Split secrets if manifest exists
$secretsSplit = Split-EnvSecrets
Write-Host ""

# -- Execute command ---------------------------------------------------------
Write-Host "Running..." -ForegroundColor Cyan
Write-Host ""

$commandExit = 0
try {
    Invoke-Expression $Command
    if ($LASTEXITCODE) { $commandExit = $LASTEXITCODE }
} catch {
    Write-Host ""
    Write-Host "  Command failed: $_" -ForegroundColor Red
    $commandExit = 1
} finally {
    # Clean up .env only if we created it (from DPAPI or age)
    if ($envCreated -and (Test-Path ".env")) {
        Remove-Item .env -Force
        Write-Host ""
        Write-Host "  .env deleted." -ForegroundColor Green
    }
    # Clean up secret files and backup
    if (Test-Path ".env.full") { Remove-Item ".env.full" -Force }
    if ($secretsSplit -and (Test-Path ".secrets")) {
        Remove-Item ".secrets" -Recurse -Force
        Write-Host "  .secrets/ deleted." -ForegroundColor Green
    }
}

Write-Host ""
if ($commandExit -eq 0) {
    Write-Host "========================================"
    Write-Host "  Done ($EnvName)" -ForegroundColor Green
    Write-Host "========================================"
} else {
    Write-Host "========================================"
    Write-Host "  Failed (exit: $commandExit)" -ForegroundColor Red
    Write-Host "========================================"
    exit $commandExit
}
