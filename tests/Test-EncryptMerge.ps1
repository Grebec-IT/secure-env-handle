# Tests for encrypt-env merge logic
# Verifies that .env + .secrets/ are correctly merged before encryption.
# Does NOT call age (avoids interactive passphrase prompt).
# Tests the merge logic in isolation.
#
# Run from repo root: .\tests\Test-EncryptMerge.ps1

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

# -- Merge helper (extracted from encrypt-env.ps1 logic) --------------------
function Merge-EnvAndSecrets {
    param([string]$EnvFile = ".env")

    $mergedLines = @(Get-Content $EnvFile)

    if (Test-Path ".secrets") {
        $secretFiles = Get-ChildItem ".secrets" -File -ErrorAction SilentlyContinue
        foreach ($file in $secretFiles) {
            $key = $file.Name
            $value = [System.IO.File]::ReadAllText($file.FullName)
            $mergedLines += "$key=$value"
        }
    }

    return $mergedLines
}

# Setup temp dir
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) "seh-merge-test-$(Get-Random)"
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $testRoot "envs") -Force | Out-Null

Push-Location $testRoot
[System.IO.Directory]::SetCurrentDirectory($testRoot)

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Encrypt Merge Tests"
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Test root: $testRoot"
Write-Host ""

# -- Test 1: Merge includes config + secrets --------------------------------
Write-Host "[Test 1] Merge includes .env config and .secrets/ values" -ForegroundColor Cyan

@("APP_PORT=8080", "LOG_LEVEL=info") | Set-Content ".env" -Encoding UTF8
New-Item -ItemType Directory -Path ".secrets" -Force | Out-Null
[System.IO.File]::WriteAllText((Join-Path ".secrets" "DB_PASSWORD"), "secret123")
[System.IO.File]::WriteAllText((Join-Path ".secrets" "API_KEY"), "tok_xyz")

$merged = Merge-EnvAndSecrets -EnvFile ".env"
$content = $merged -join "`n"

Assert-True ($content -match "APP_PORT=8080") "Merged contains APP_PORT"
Assert-True ($content -match "LOG_LEVEL=info") "Merged contains LOG_LEVEL"
Assert-True ($content -match "DB_PASSWORD=secret123") "Merged contains DB_PASSWORD"
Assert-True ($content -match "API_KEY=tok_xyz") "Merged contains API_KEY"
Assert-True ($merged.Count -ge 4) "Merged has at least 4 lines ($($merged.Count))"

Remove-Item ".secrets" -Recurse -Force
Remove-Item ".env" -Force
Write-Host ""

# -- Test 2: No .secrets/ -> only .env content ------------------------------
Write-Host "[Test 2] No .secrets/ returns only .env content" -ForegroundColor Cyan

@("ONLY_CONFIG=yes", "PORT=3000") | Set-Content ".env" -Encoding UTF8

$merged = Merge-EnvAndSecrets -EnvFile ".env"
$content = $merged -join "`n"

Assert-True ($content -match "ONLY_CONFIG=yes") "Merged contains ONLY_CONFIG"
Assert-True ($content -match "PORT=3000") "Merged contains PORT"
Assert-Equal "$($merged.Count)" "2" "Merged has exactly 2 lines"

Remove-Item ".env" -Force
Write-Host ""

# -- Test 3: Empty .secrets/ dir -> no extra lines --------------------------
Write-Host "[Test 3] Empty .secrets/ directory adds nothing" -ForegroundColor Cyan

@("CONFIG=val") | Set-Content ".env" -Encoding UTF8
New-Item -ItemType Directory -Path ".secrets" -Force | Out-Null

$merged = Merge-EnvAndSecrets -EnvFile ".env"
Assert-Equal "$($merged.Count)" "1" "Merged has exactly 1 line"

Remove-Item ".secrets" -Recurse -Force
Remove-Item ".env" -Force
Write-Host ""

# -- Test 4: Secret with special chars in value -----------------------------
Write-Host "[Test 4] Secret values with special characters" -ForegroundColor Cyan

@("HOST=localhost") | Set-Content ".env" -Encoding UTF8
New-Item -ItemType Directory -Path ".secrets" -Force | Out-Null
[System.IO.File]::WriteAllText((Join-Path ".secrets" "CONN_STR"), "postgresql://user:p@ss=w0rd@host:5432/db")

$merged = Merge-EnvAndSecrets -EnvFile ".env"
$content = $merged -join "`n"

Assert-True ($content -match "CONN_STR=postgresql://user:p@ss=w0rd@host:5432/db") "Special chars preserved in merge"

Remove-Item ".secrets" -Recurse -Force
Remove-Item ".env" -Force
Write-Host ""

# -- Test 5: Round-trip: merge -> write -> split ----------------------------
Write-Host "[Test 5] Round-trip: merge -> split produces original structure" -ForegroundColor Cyan

# Original structure
@("APP_PORT=8080", "DB_SCHEMA=public") | Set-Content ".env" -Encoding UTF8
New-Item -ItemType Directory -Path ".secrets" -Force | Out-Null
[System.IO.File]::WriteAllText((Join-Path ".secrets" "PASSWORD"), "mypass")
[System.IO.File]::WriteAllText((Join-Path ".secrets" "JWT_SECRET"), "jwtsec")
@("PASSWORD", "JWT_SECRET") | Set-Content "envs\secrets.keys" -Encoding UTF8

# Merge (simulating encrypt)
$merged = Merge-EnvAndSecrets -EnvFile ".env"
$merged | Set-Content ".env.full" -Encoding UTF8

# Split (simulating decrypt)
$secretKeys = @(Get-Content "envs\secrets.keys" | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith("#") })
Remove-Item ".secrets" -Recurse -Force
New-Item -ItemType Directory -Path ".secrets" -Force | Out-Null

$configLines = @()
$fullLines = Get-Content ".env.full"
foreach ($rawLine in $fullLines) {
    $line = $rawLine.Trim()
    if (-not $line -or $line.StartsWith("#")) { $configLines += $rawLine; continue }
    $eqIdx = $line.IndexOf("=")
    if ($eqIdx -le 0) { $configLines += $rawLine; continue }
    $key = $line.Substring(0, $eqIdx).Trim()
    $value = $line.Substring($eqIdx + 1)
    if ($key -in $secretKeys) {
        $path = Join-Path ".secrets" $key
        [System.IO.File]::WriteAllText($path, $value)
    } else {
        $configLines += $rawLine
    }
}
$configLines | Set-Content ".env" -Encoding UTF8

# Verify
$envContent = Get-Content ".env" -Raw
Assert-True ($envContent -match "APP_PORT=8080") ".env has APP_PORT"
Assert-True ($envContent -match "DB_SCHEMA=public") ".env has DB_SCHEMA"
Assert-True ($envContent -notmatch "PASSWORD") ".env does NOT have PASSWORD"
Assert-True ($envContent -notmatch "JWT_SECRET") ".env does NOT have JWT_SECRET"
Assert-True (Test-Path (Join-Path ".secrets" "PASSWORD") -PathType Leaf) "PASSWORD is a file"
Assert-True (Test-Path (Join-Path ".secrets" "JWT_SECRET") -PathType Leaf) "JWT_SECRET is a file"
Assert-Equal ([System.IO.File]::ReadAllText((Join-Path ".secrets" "PASSWORD"))) "mypass" "PASSWORD value correct"
Assert-Equal ([System.IO.File]::ReadAllText((Join-Path ".secrets" "JWT_SECRET"))) "jwtsec" "JWT_SECRET value correct"

Write-Host ""

# -- Cleanup ----------------------------------------------------------------
Pop-Location
Remove-Item $testRoot -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Results: $passed passed, $failed failed" -ForegroundColor $(if ($failed -gt 0) { "Red" } else { "Green" })
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

if ($failed -gt 0) { exit 1 }
