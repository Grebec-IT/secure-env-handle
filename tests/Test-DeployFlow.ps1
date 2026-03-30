# Simulates the REAL deploy.ps1 flow end-to-end with Docker.
# Does NOT clean up — inspect tests/docker-test/ after running.
#
# Tests the actual failure scenario:
#   1. Docker creates directories for missing mount sources
#   2. Deploy must replace those directories with files
#   3. After docker compose up, files must STILL be files (not dirs)
#
# Run from repo root: .\tests\Test-DeployFlow.ps1

$ErrorActionPreference = "Stop"
$passed = 0
$failed = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if ($Condition) {
        Write-Host "    PASS: $Message" -ForegroundColor Green
        $script:passed++
    } else {
        Write-Host "    FAIL: $Message" -ForegroundColor Red
        $script:failed++
    }
}

function Assert-Equal {
    param([string]$Actual, [string]$Expected, [string]$Message)
    if ($Actual -eq $Expected) {
        Write-Host "    PASS: $Message" -ForegroundColor Green
        $script:passed++
    } else {
        Write-Host "    FAIL: $Message" -ForegroundColor Red
        Write-Host "      Expected: '$Expected'" -ForegroundColor Yellow
        Write-Host "      Actual:   '$Actual'" -ForegroundColor Yellow
        $script:failed++
    }
}

function Show-SecretsState {
    param([string]$Label)
    Write-Host "    --- $Label ---" -ForegroundColor Gray
    if (-not (Test-Path ".secrets")) {
        Write-Host "    .secrets/ does not exist" -ForegroundColor Gray
        return
    }
    foreach ($item in (Get-ChildItem ".secrets" -Force)) {
        $type = if ($item.PSIsContainer) { "DIR " } else { "FILE" }
        $size = if ($item.PSIsContainer) { "(empty dir)" } else { "$($item.Length) bytes" }
        $content = ""
        if (-not $item.PSIsContainer -and $item.Length -lt 200) {
            $content = " = '$([System.IO.File]::ReadAllText($item.FullName))'"
        }
        Write-Host "    $type  $($item.Name)  $size$content" -ForegroundColor Gray
    }
    Write-Host ""
}

# -- The Split function (EXACT copy from deploy.ps1) -----------------------
function Split-EnvSecrets {
    param(
        [string]$SourceFile = ".env.full",
        [bool]$WriteSecrets = $true
    )

    $manifest = Join-Path "envs" "secrets.keys"
    if (-not (Test-Path $manifest)) { return $false }

    $secretKeys = @(Get-Content $manifest |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith("#") })

    if ($secretKeys.Count -eq 0) { return $false }

    $configLines = @()
    $splitCount = 0
    $secretDir = ".secrets"

    if ($WriteSecrets) {
        if (Test-Path $secretDir) { Remove-Item $secretDir -Recurse -Force }
        New-Item -ItemType Directory -Path $secretDir -Force | Out-Null
    }

    $lines = Get-Content $SourceFile
    foreach ($rawLine in $lines) {
        $line = $rawLine.Trim()
        if (-not $line -or $line.StartsWith("#")) {
            $configLines += $rawLine
            continue
        }
        $eqIdx = $line.IndexOf("=")
        if ($eqIdx -le 0) {
            $configLines += $rawLine
            continue
        }
        $key = $line.Substring(0, $eqIdx).Trim()
        $value = $line.Substring($eqIdx + 1).Trim()

        if ($key -in $secretKeys) {
            if ($WriteSecrets) {
                $secretPath = Join-Path $secretDir $key
                if (Test-Path $secretPath -PathType Container) { Remove-Item $secretPath -Recurse -Force }
                [System.IO.File]::WriteAllText($secretPath, $value)
            }
            $splitCount++
        } else {
            $configLines += $rawLine
        }
    }

    $configLines | Set-Content -Path ".env" -Encoding UTF8
    return $true
}

# ---------------------------------------------------------------------------
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Host "SKIP: Docker not installed" -ForegroundColor Yellow; exit 0
}
$ErrorActionPreference = "Continue"
docker info 2>&1 | Out-Null
$ErrorActionPreference = "Stop"
if ($LASTEXITCODE -ne 0) {
    Write-Host "SKIP: Docker not running" -ForegroundColor Yellow; exit 0
}

$testDir = Join-Path $PSScriptRoot "docker-test"
Push-Location $testDir
[System.IO.Directory]::SetCurrentDirectory($testDir)

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Deploy Flow Tests (keeps artifacts)"
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Test dir: $testDir"
Write-Host "  Inspect .secrets/, .env after test!"
Write-Host ""

# Clean slate
$ErrorActionPreference = "Continue"
docker compose down 2>&1 | Out-Null
$ErrorActionPreference = "Stop"
if (Test-Path ".secrets") { Remove-Item ".secrets" -Recurse -Force }
if (Test-Path ".env") { Remove-Item ".env" -Force }
if (Test-Path ".env.full") { Remove-Item ".env.full" -Force }

# Setup manifest
@("TEST_PASSWORD", "TEST_TOKEN") | Set-Content "envs\secrets.keys" -Encoding UTF8

# ===========================================================================
# TEST 1: Docker creates directories when .secrets/ files don't exist
# ===========================================================================
Write-Host "[Test 1] Prove Docker creates directories for missing secrets" -ForegroundColor Cyan

# Create .env (config only) but NO .secrets/ files
@("APP_PORT=8080") | Set-Content ".env" -Encoding UTF8

# Create .secrets/ as empty directory
New-Item -ItemType Directory -Path ".secrets" -Force | Out-Null

Write-Host "    Before docker compose up:" -ForegroundColor Gray
Show-SecretsState "Before"

# Start containers — Docker should create directories for missing files
$ErrorActionPreference = "Continue"
docker compose up -d 2>&1 | Out-Null
$ErrorActionPreference = "Stop"
Start-Sleep -Seconds 3

Show-SecretsState "After docker compose up (no source files)"

# Docker creates directories for missing bind-mount sources
Assert-True (Test-Path ".secrets\TEST_PASSWORD" -PathType Container) "Docker created TEST_PASSWORD as DIRECTORY (expected)"
Assert-True (Test-Path ".secrets\TEST_TOKEN" -PathType Container) "Docker created TEST_TOKEN as DIRECTORY (expected)"

$ErrorActionPreference = "Continue"
docker compose down 2>&1 | Out-Null
$ErrorActionPreference = "Stop"
Write-Host ""

# ===========================================================================
# TEST 2: Split function replaces Docker-created directories with files
# ===========================================================================
Write-Host "[Test 2] Split replaces Docker-created directories with files" -ForegroundColor Cyan

Show-SecretsState "Before split (.secrets/ has directories from Docker)"

# Create .env.full (full content as if loaded from .age or DPAPI)
@("APP_PORT=8080", "TEST_PASSWORD=my_secret_pw", "TEST_TOKEN=tok_999") | Set-Content ".env.full" -Encoding UTF8

# Run split (same as deploy.ps1 does)
$result = Split-EnvSecrets -SourceFile ".env.full" -WriteSecrets $true
Remove-Item ".env.full" -Force

Show-SecretsState "After split"

Assert-True $result "Split returned true"
Assert-True (Test-Path ".secrets\TEST_PASSWORD" -PathType Leaf) "TEST_PASSWORD is now a FILE"
Assert-True (Test-Path ".secrets\TEST_TOKEN" -PathType Leaf) "TEST_TOKEN is now a FILE"
Assert-Equal ([System.IO.File]::ReadAllText(".secrets\TEST_PASSWORD")) "my_secret_pw" "TEST_PASSWORD value correct"
Assert-Equal ([System.IO.File]::ReadAllText(".secrets\TEST_TOKEN")) "tok_999" "TEST_TOKEN value correct"

Write-Host ""

# ===========================================================================
# TEST 3: docker compose up with correct files — verify inside container
# ===========================================================================
Write-Host "[Test 3] docker compose up with correct files" -ForegroundColor Cyan

$ErrorActionPreference = "Continue"
docker compose up -d 2>&1 | Out-Null
$ErrorActionPreference = "Stop"
Start-Sleep -Seconds 3

Show-SecretsState "After docker compose up (with files)"

# Check: are they STILL files? (Docker might have replaced them)
Assert-True (Test-Path ".secrets\TEST_PASSWORD" -PathType Leaf) "STILL a file after docker compose up"
Assert-True (Test-Path ".secrets\TEST_TOKEN" -PathType Leaf) "STILL a file after docker compose up"

# Read from inside container
$pwInContainer = docker compose exec -T secret-reader cat /run/secrets/test_password 2>&1
$tokInContainer = docker compose exec -T secret-reader cat /run/secrets/test_token 2>&1

Assert-Equal $pwInContainer "my_secret_pw" "Container reads correct TEST_PASSWORD"
Assert-Equal $tokInContainer "tok_999" "Container reads correct TEST_TOKEN"

Write-Host ""

# ===========================================================================
# TEST 4: Redeploy WITHOUT refresh — files must stay intact
# ===========================================================================
Write-Host "[Test 4] Redeploy without refresh (WriteSecrets=false)" -ForegroundColor Cyan

# Simulate: new .env.full loaded, but user says N to refresh
@("APP_PORT=9090", "TEST_PASSWORD=UPDATED_pw", "TEST_TOKEN=UPDATED_tok") | Set-Content ".env.full" -Encoding UTF8

# Split with WriteSecrets=false (user said N)
Split-EnvSecrets -SourceFile ".env.full" -WriteSecrets $false | Out-Null
Remove-Item ".env.full" -Force

Show-SecretsState "After split with WriteSecrets=false"

# .secrets/ should still have the OLD values (not updated)
Assert-True (Test-Path ".secrets\TEST_PASSWORD" -PathType Leaf) "TEST_PASSWORD still a file"
Assert-Equal ([System.IO.File]::ReadAllText(".secrets\TEST_PASSWORD")) "my_secret_pw" "TEST_PASSWORD has OLD value (not refreshed)"

# But .env should have new config
$envContent = Get-Content ".env" -Raw
Assert-True ($envContent -match "APP_PORT=9090") ".env has UPDATED APP_PORT"

# docker compose up with new config, old secrets
$ErrorActionPreference = "Continue"
docker compose down 2>&1 | Out-Null
docker compose up -d 2>&1 | Out-Null
$ErrorActionPreference = "Stop"
Start-Sleep -Seconds 3

$pwStillOld = docker compose exec -T secret-reader cat /run/secrets/test_password 2>&1
Assert-Equal $pwStillOld "my_secret_pw" "Container still reads OLD password (no refresh)"

Write-Host ""

# ===========================================================================
# TEST 5: Redeploy WITH refresh — updated values
# ===========================================================================
Write-Host "[Test 5] Redeploy with refresh (WriteSecrets=true)" -ForegroundColor Cyan

$ErrorActionPreference = "Continue"
docker compose down 2>&1 | Out-Null
$ErrorActionPreference = "Stop"

@("APP_PORT=9090", "TEST_PASSWORD=final_password!", "TEST_TOKEN=final_token!") | Set-Content ".env.full" -Encoding UTF8

Split-EnvSecrets -SourceFile ".env.full" -WriteSecrets $true | Out-Null
Remove-Item ".env.full" -Force

Show-SecretsState "After split with WriteSecrets=true (refresh)"

Assert-Equal ([System.IO.File]::ReadAllText(".secrets\TEST_PASSWORD")) "final_password!" "TEST_PASSWORD has NEW value"

$ErrorActionPreference = "Continue"
docker compose up -d 2>&1 | Out-Null
$ErrorActionPreference = "Stop"
Start-Sleep -Seconds 3

$pwFinal = docker compose exec -T secret-reader cat /run/secrets/test_password 2>&1
Assert-Equal $pwFinal "final_password!" "Container reads FINAL password"

Show-SecretsState "Final state (kept for inspection)"

Write-Host ""

# ===========================================================================
# DO NOT CLEAN UP — leave everything for inspection
# ===========================================================================
Write-Host "  Artifacts left in: $testDir" -ForegroundColor Yellow
Write-Host "  Inspect:" -ForegroundColor Yellow
Write-Host "    .secrets\          (should be files, not dirs)" -ForegroundColor Yellow
Write-Host "    .env               (should be config only)" -ForegroundColor Yellow
Write-Host "    docker compose ps  (containers running)" -ForegroundColor Yellow
Write-Host ""
Write-Host "  To clean up manually:" -ForegroundColor Yellow
Write-Host "    docker compose down" -ForegroundColor Yellow
Write-Host "    Remove-Item .secrets -Recurse -Force" -ForegroundColor Yellow
Write-Host "    Remove-Item .env -Force" -ForegroundColor Yellow
Write-Host ""

Pop-Location

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Results: $passed passed, $failed failed" -ForegroundColor $(if ($failed -gt 0) { "Red" } else { "Green" })
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

if ($failed -gt 0) { exit 1 }
