# End-to-end Docker secret file mount test
#
# Verifies that secrets created by the split function are:
#   1. Readable inside a Docker container via /run/secrets/
#   2. Contain the exact expected value (no BOM, no newline, no corruption)
#   3. Survive a redeploy with updated values
#   4. Config env vars from .env are also accessible
#
# Requires: Docker Desktop running
# Run from repo root: .\tests\Test-DockerSecrets.ps1

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
        Write-Host "      Expected hex: $(([System.Text.Encoding]::UTF8.GetBytes($Expected) | ForEach-Object { $_.ToString('X2') }) -join ' ')" -ForegroundColor Yellow
        Write-Host "      Actual hex:   $(([System.Text.Encoding]::UTF8.GetBytes($Actual) | ForEach-Object { $_.ToString('X2') }) -join ' ')" -ForegroundColor Yellow
        $script:failed++
    }
}

# Check Docker
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Host "SKIP: Docker not installed" -ForegroundColor Yellow
    exit 0
}

$ErrorActionPreference = "Continue"
docker info 2>&1 | Out-Null
$ErrorActionPreference = "Stop"
if ($LASTEXITCODE -ne 0) {
    Write-Host "SKIP: Docker not running" -ForegroundColor Yellow
    exit 0
}

$testDir = Join-Path $PSScriptRoot "docker-test"
Push-Location $testDir
[System.IO.Directory]::SetCurrentDirectory($testDir)

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Docker Secret Mount Tests"
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Test dir: $testDir"
Write-Host ""

# Ensure clean state
$ErrorActionPreference = "Continue"
docker compose down 2>&1 | Out-Null
$ErrorActionPreference = "Stop"
if (Test-Path ".secrets") { Remove-Item ".secrets" -Recurse -Force }
if (Test-Path ".env") { Remove-Item ".env" -Force }

# ===========================================================================
# TEST 1: Secrets are readable inside the container
# ===========================================================================
Write-Host "[Test 1] Secrets readable inside container via /run/secrets/" -ForegroundColor Cyan

# Create .env (config only)
@("APP_PORT=9090", "LOG_LEVEL=debug") | Set-Content ".env" -Encoding UTF8

# Create .secrets/ with known values
New-Item -ItemType Directory -Path ".secrets" -Force | Out-Null
[System.IO.File]::WriteAllText((Join-Path ".secrets" "TEST_PASSWORD"), "s3cret_p@ss!")
[System.IO.File]::WriteAllText((Join-Path ".secrets" "TEST_TOKEN"), "tok_abc123")

# Verify files on host first
Assert-True (Test-Path ".secrets\TEST_PASSWORD" -PathType Leaf) "Host: TEST_PASSWORD is a file"
Assert-True (Test-Path ".secrets\TEST_TOKEN" -PathType Leaf) "Host: TEST_TOKEN is a file"

$hostPwBytes = [System.IO.File]::ReadAllBytes((Join-Path ".secrets" "TEST_PASSWORD"))
Write-Host "    Host file: $($hostPwBytes.Count) bytes, hex: $(($hostPwBytes | ForEach-Object { $_.ToString('X2') }) -join ' ')" -ForegroundColor Gray

# Start container
Write-Host "    Starting container..." -ForegroundColor Gray
$ErrorActionPreference = "Continue"
docker compose up -d 2>&1 | Out-Null
$ErrorActionPreference = "Stop"

# Wait for container to be ready
Start-Sleep -Seconds 3

# Read secrets from inside the container
$pwValue = docker compose exec -T secret-reader cat /run/secrets/test_password 2>&1
$tokenValue = docker compose exec -T secret-reader cat /run/secrets/test_token 2>&1

Assert-Equal $pwValue "s3cret_p@ss!" "Container: TEST_PASSWORD value correct"
Assert-Equal $tokenValue "tok_abc123" "Container: TEST_TOKEN value correct"

# Verify no extra bytes (BOM, newline, etc.)
$ErrorActionPreference = "Continue"
$pwLen = docker compose exec -T secret-reader sh -c 'wc -c < /run/secrets/test_password' 2>&1
$ErrorActionPreference = "Stop"
Write-Host "    Container file size: $($pwLen.Trim()) bytes" -ForegroundColor Gray

# Read config env var from inside container
$portValue = docker compose exec -T secret-reader sh -c 'echo $APP_PORT' 2>&1
Assert-Equal $portValue.Trim() "9090" "Container: APP_PORT env var correct"

Write-Host ""

# ===========================================================================
# TEST 2: Secrets survive container restart
# ===========================================================================
Write-Host "[Test 2] Secrets survive container restart" -ForegroundColor Cyan

$ErrorActionPreference = "Continue"
docker compose restart 2>&1 | Out-Null
$ErrorActionPreference = "Stop"
Start-Sleep -Seconds 3

$pwAfterRestart = docker compose exec -T secret-reader cat /run/secrets/test_password 2>&1
Assert-Equal $pwAfterRestart "s3cret_p@ss!" "After restart: TEST_PASSWORD still correct"

Write-Host ""

# ===========================================================================
# TEST 3: Updated secrets are picked up after redeploy
# ===========================================================================
Write-Host "[Test 3] Updated secrets picked up after redeploy" -ForegroundColor Cyan

# Stop containers
$ErrorActionPreference = "Continue"
docker compose down 2>&1 | Out-Null
$ErrorActionPreference = "Stop"

# Update secret values
[System.IO.File]::WriteAllText((Join-Path ".secrets" "TEST_PASSWORD"), "new_password_v2")
[System.IO.File]::WriteAllText((Join-Path ".secrets" "TEST_TOKEN"), "tok_updated_456")

# Redeploy
$ErrorActionPreference = "Continue"
docker compose up -d 2>&1 | Out-Null
$ErrorActionPreference = "Stop"
Start-Sleep -Seconds 3

$pwUpdated = docker compose exec -T secret-reader cat /run/secrets/test_password 2>&1
$tokenUpdated = docker compose exec -T secret-reader cat /run/secrets/test_token 2>&1

Assert-Equal $pwUpdated "new_password_v2" "After redeploy: TEST_PASSWORD updated"
Assert-Equal $tokenUpdated "tok_updated_456" "After redeploy: TEST_TOKEN updated"

Write-Host ""

# ===========================================================================
# TEST 4: Full split function → Docker round-trip
# ===========================================================================
Write-Host "[Test 4] Split function output works with Docker" -ForegroundColor Cyan

# Stop containers
$ErrorActionPreference = "Continue"
docker compose down 2>&1 | Out-Null
$ErrorActionPreference = "Stop"

# Create a full .env.full (config + secrets) like decrypt would produce
@(
    "APP_PORT=7070",
    "LOG_LEVEL=warn",
    "TEST_PASSWORD=split_func_pw!",
    "TEST_TOKEN=split_func_tok"
) | Set-Content ".env.full" -Encoding UTF8

# Create secrets.keys manifest
@("TEST_PASSWORD", "TEST_TOKEN") | Set-Content "envs\secrets.keys" -Encoding UTF8

# Run the actual split function (same code as deploy.ps1)
$secretKeys = @(Get-Content "envs\secrets.keys" |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -and -not $_.StartsWith("#") })

if (Test-Path ".secrets") { Remove-Item ".secrets" -Recurse -Force }
New-Item -ItemType Directory -Path ".secrets" -Force | Out-Null

$configLines = @()
foreach ($rawLine in (Get-Content ".env.full")) {
    $line = $rawLine.Trim()
    if (-not $line -or $line.StartsWith("#")) { $configLines += $rawLine; continue }
    $eqIdx = $line.IndexOf("=")
    if ($eqIdx -le 0) { $configLines += $rawLine; continue }
    $key = $line.Substring(0, $eqIdx).Trim()
    $value = $line.Substring($eqIdx + 1)

    if ($key -in $secretKeys) {
        $secretPath = Join-Path ".secrets" $key
        if (Test-Path $secretPath -PathType Container) { Remove-Item $secretPath -Recurse -Force }
        [System.IO.File]::WriteAllText($secretPath, $value)
    } else {
        $configLines += $rawLine
    }
}
$configLines | Set-Content ".env" -Encoding UTF8
Remove-Item ".env.full" -Force

# Verify host files before starting Docker
Assert-True (Test-Path ".secrets\TEST_PASSWORD" -PathType Leaf) "Split: TEST_PASSWORD is a file"
Assert-True (Test-Path ".secrets\TEST_TOKEN" -PathType Leaf) "Split: TEST_TOKEN is a file"

$splitPwBytes = [System.IO.File]::ReadAllBytes((Join-Path ".secrets" "TEST_PASSWORD"))
Write-Host "    Split file: $($splitPwBytes.Count) bytes, content: '$([System.IO.File]::ReadAllText((Join-Path ".secrets" "TEST_PASSWORD")))'" -ForegroundColor Gray

# Start Docker with split output
$ErrorActionPreference = "Continue"
docker compose up -d 2>&1 | Out-Null
$ErrorActionPreference = "Stop"
Start-Sleep -Seconds 3

# Verify inside container
$splitPw = docker compose exec -T secret-reader cat /run/secrets/test_password 2>&1
$splitTok = docker compose exec -T secret-reader cat /run/secrets/test_token 2>&1
$splitPort = docker compose exec -T secret-reader sh -c 'echo $APP_PORT' 2>&1

Assert-Equal $splitPw "split_func_pw!" "Docker after split: TEST_PASSWORD correct"
Assert-Equal $splitTok "split_func_tok" "Docker after split: TEST_TOKEN correct"
Assert-Equal $splitPort.Trim() "7070" "Docker after split: APP_PORT env var correct"

# Verify .env inside container does NOT contain secrets
$envInContainer = docker compose exec -T secret-reader sh -c 'cat /proc/1/environ | tr "\0" "\n" | sort' 2>&1
$envString = $envInContainer -join "`n"
Assert-True ($envString -notmatch "TEST_PASSWORD") "Container env does NOT contain TEST_PASSWORD"
Assert-True ($envString -notmatch "TEST_TOKEN") "Container env does NOT contain TEST_TOKEN"

Write-Host ""

# ===========================================================================
# Cleanup
# ===========================================================================
Write-Host "Cleaning up..." -ForegroundColor Gray
$ErrorActionPreference = "Continue"
docker compose down 2>&1 | Out-Null
$ErrorActionPreference = "Stop"
Remove-Item ".secrets" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item ".env" -Force -ErrorAction SilentlyContinue
Remove-Item ".env.full" -Force -ErrorAction SilentlyContinue
Remove-Item "envs\secrets.keys" -Force -ErrorAction SilentlyContinue

Pop-Location

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Results: $passed passed, $failed failed" -ForegroundColor $(if ($failed -gt 0) { "Red" } else { "Green" })
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

if ($failed -gt 0) { exit 1 }
