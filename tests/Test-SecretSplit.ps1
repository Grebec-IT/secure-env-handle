# Tests for the secret splitting logic
# Run from repo root: .\tests\Test-SecretSplit.ps1
#
# Tests the core Split-EnvSecrets function in isolation to verify:
#   - Secret files are FILES (not directories)
#   - Secret values are correct (no trailing newlines, preserves special chars)
#   - .env only contains config entries (no secrets)
#   - Edge cases: empty values, values with =, single-key manifests

$ErrorActionPreference = "Stop"
$passed = 0
$failed = 0
$testName = ""

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

# -- Setup: create temp project structure -----------------------------------
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) "seh-test-$(Get-Random)"
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $testRoot "envs") -Force | Out-Null

Push-Location $testRoot
[System.IO.Directory]::SetCurrentDirectory($testRoot)

# -- The split function under test (extracted from deploy.ps1) ---------------
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

# ===========================================================================
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Secret Split Tests"
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Test root: $testRoot"
Write-Host ""

# -- Test 1: Basic split creates files, not directories ----------------------
Write-Host "[Test 1] Basic split creates files, not directories" -ForegroundColor Cyan

@"
# Config
APP_PORT=8080
LOG_LEVEL=info
# Secrets
POSTGRES_PASSWORD=supersecret
API_TOKEN=tok_abc123
"@ | Set-Content ".env.full" -Encoding UTF8

@"
POSTGRES_PASSWORD
API_TOKEN
"@ | Set-Content "envs\secrets.keys" -Encoding UTF8

$result = Split-EnvSecrets -SourceFile ".env.full" -WriteSecrets $true

Assert-True $result "Split returned true"
Assert-True (Test-Path ".secrets\POSTGRES_PASSWORD" -PathType Leaf) ".secrets\POSTGRES_PASSWORD is a FILE"
Assert-True (Test-Path ".secrets\API_TOKEN" -PathType Leaf) ".secrets\API_TOKEN is a FILE"
Assert-True (-not (Test-Path ".secrets\POSTGRES_PASSWORD" -PathType Container)) ".secrets\POSTGRES_PASSWORD is NOT a directory"
Assert-Equal ([System.IO.File]::ReadAllText(".secrets\POSTGRES_PASSWORD")) "supersecret" "POSTGRES_PASSWORD value correct"
Assert-Equal ([System.IO.File]::ReadAllText(".secrets\API_TOKEN")) "tok_abc123" "API_TOKEN value correct"

# Check .env has config only
$envContent = Get-Content ".env" -Raw
Assert-True ($envContent -match "APP_PORT=8080") ".env contains APP_PORT"
Assert-True ($envContent -match "LOG_LEVEL=info") ".env contains LOG_LEVEL"
Assert-True ($envContent -notmatch "POSTGRES_PASSWORD") ".env does NOT contain POSTGRES_PASSWORD"
Assert-True ($envContent -notmatch "API_TOKEN") ".env does NOT contain API_TOKEN"

# Cleanup
Remove-Item ".secrets" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item ".env" -Force -ErrorAction SilentlyContinue
Remove-Item ".env.full" -Force -ErrorAction SilentlyContinue
Write-Host ""

# -- Test 2: Overwrite stale directories with files --------------------------
Write-Host "[Test 2] Overwrite stale directories with files" -ForegroundColor Cyan

@"
DB_HOST=localhost
SECRET_KEY=mysecretkey
"@ | Set-Content ".env.full" -Encoding UTF8

@"
SECRET_KEY
"@ | Set-Content "envs\secrets.keys" -Encoding UTF8

# Pre-create .secrets/SECRET_KEY as a DIRECTORY (simulating Docker's behavior)
New-Item -ItemType Directory -Path ".secrets\SECRET_KEY" -Force | Out-Null
Assert-True (Test-Path ".secrets\SECRET_KEY" -PathType Container) "Pre-condition: SECRET_KEY is a directory"

$result = Split-EnvSecrets -SourceFile ".env.full" -WriteSecrets $true

Assert-True $result "Split returned true"
Assert-True (Test-Path ".secrets\SECRET_KEY" -PathType Leaf) "SECRET_KEY is now a FILE (not directory)"
Assert-Equal ([System.IO.File]::ReadAllText(".secrets\SECRET_KEY")) "mysecretkey" "SECRET_KEY value correct"

Remove-Item ".secrets" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item ".env" -Force -ErrorAction SilentlyContinue
Remove-Item ".env.full" -Force -ErrorAction SilentlyContinue
Write-Host ""

# -- Test 3: Value with equals sign -----------------------------------------
Write-Host "[Test 3] Value with equals sign preserved" -ForegroundColor Cyan

@"
DB_URL=postgresql://user:p=ss@host:5432/db
"@ | Set-Content ".env.full" -Encoding UTF8

@"
DB_URL
"@ | Set-Content "envs\secrets.keys" -Encoding UTF8

Split-EnvSecrets -SourceFile ".env.full" -WriteSecrets $true | Out-Null

Assert-True (Test-Path ".secrets\DB_URL" -PathType Leaf) "DB_URL is a file"
Assert-Equal ([System.IO.File]::ReadAllText(".secrets\DB_URL")) "postgresql://user:p=ss@host:5432/db" "Value with = preserved"

Remove-Item ".secrets" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item ".env" -Force -ErrorAction SilentlyContinue
Remove-Item ".env.full" -Force -ErrorAction SilentlyContinue
Write-Host ""

# -- Test 4: Empty value ---------------------------------------------------
Write-Host "[Test 4] Empty value creates empty file" -ForegroundColor Cyan

@"
EMPTY_SECRET=
CONFIG_VAR=hello
"@ | Set-Content ".env.full" -Encoding UTF8

@"
EMPTY_SECRET
"@ | Set-Content "envs\secrets.keys" -Encoding UTF8

Split-EnvSecrets -SourceFile ".env.full" -WriteSecrets $true | Out-Null

Assert-True (Test-Path ".secrets\EMPTY_SECRET" -PathType Leaf) "EMPTY_SECRET is a file"
Assert-Equal ([System.IO.File]::ReadAllText(".secrets\EMPTY_SECRET")) "" "Empty value is empty string"

Remove-Item ".secrets" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item ".env" -Force -ErrorAction SilentlyContinue
Remove-Item ".env.full" -Force -ErrorAction SilentlyContinue
Write-Host ""

# -- Test 5: Single key in manifest (array vs string edge case) --------------
Write-Host "[Test 5] Single key in manifest" -ForegroundColor Cyan

@"
ONLY_SECRET=onlyvalue
ONLY_CONFIG=configval
"@ | Set-Content ".env.full" -Encoding UTF8

@"
ONLY_SECRET
"@ | Set-Content "envs\secrets.keys" -Encoding UTF8

Split-EnvSecrets -SourceFile ".env.full" -WriteSecrets $true | Out-Null

Assert-True (Test-Path ".secrets\ONLY_SECRET" -PathType Leaf) "ONLY_SECRET is a file"
Assert-Equal ([System.IO.File]::ReadAllText(".secrets\ONLY_SECRET")) "onlyvalue" "ONLY_SECRET value correct"
$envContent = Get-Content ".env" -Raw
Assert-True ($envContent -match "ONLY_CONFIG=configval") ".env contains ONLY_CONFIG"
Assert-True ($envContent -notmatch "ONLY_SECRET") ".env does NOT contain ONLY_SECRET"

Remove-Item ".secrets" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item ".env" -Force -ErrorAction SilentlyContinue
Remove-Item ".env.full" -Force -ErrorAction SilentlyContinue
Write-Host ""

# -- Test 6: No manifest → returns false ------------------------------------
Write-Host "[Test 6] No manifest returns false" -ForegroundColor Cyan

@"
KEY=VALUE
"@ | Set-Content ".env.full" -Encoding UTF8

Remove-Item "envs\secrets.keys" -Force -ErrorAction SilentlyContinue

$result = Split-EnvSecrets -SourceFile ".env.full" -WriteSecrets $true
Assert-True (-not $result) "Split returned false (no manifest)"
Assert-True (-not (Test-Path ".secrets")) "No .secrets/ directory created"

Remove-Item ".env.full" -Force -ErrorAction SilentlyContinue
Write-Host ""

# -- Test 7: Empty manifest → returns false ---------------------------------
Write-Host "[Test 7] Empty manifest returns false" -ForegroundColor Cyan

@"
KEY=VALUE
"@ | Set-Content ".env.full" -Encoding UTF8

@"
# Only comments
# Nothing here
"@ | Set-Content "envs\secrets.keys" -Encoding UTF8

$result = Split-EnvSecrets -SourceFile ".env.full" -WriteSecrets $true
Assert-True (-not $result) "Split returned false (empty manifest)"

Remove-Item ".env.full" -Force -ErrorAction SilentlyContinue
Write-Host ""

# -- Test 8: WriteSecrets=false skips file creation --------------------------
Write-Host "[Test 8] WriteSecrets=false skips .secrets/ creation" -ForegroundColor Cyan

@"
CONFIG=value
SECRET=hidden
"@ | Set-Content ".env.full" -Encoding UTF8

@"
SECRET
"@ | Set-Content "envs\secrets.keys" -Encoding UTF8

$result = Split-EnvSecrets -SourceFile ".env.full" -WriteSecrets $false

Assert-True $result "Split returned true"
Assert-True (-not (Test-Path ".secrets")) "No .secrets/ directory created"
$envContent = Get-Content ".env" -Raw
Assert-True ($envContent -match "CONFIG=value") ".env contains CONFIG"
Assert-True ($envContent -notmatch "SECRET=hidden") ".env does NOT contain SECRET"

Remove-Item ".env" -Force -ErrorAction SilentlyContinue
Remove-Item ".env.full" -Force -ErrorAction SilentlyContinue
Write-Host ""

# -- Test 9: Comments and blank lines preserved in .env ----------------------
Write-Host "[Test 9] Comments and blank lines preserved in .env" -ForegroundColor Cyan

@"
# Database config
DB_HOST=localhost

# App config
APP_PORT=8080
SECRET_KEY=abc123
"@ | Set-Content ".env.full" -Encoding UTF8

@"
SECRET_KEY
"@ | Set-Content "envs\secrets.keys" -Encoding UTF8

Split-EnvSecrets -SourceFile ".env.full" -WriteSecrets $true | Out-Null

$envLines = Get-Content ".env"
Assert-True ($envLines[0] -eq "# Database config") "Comment line 1 preserved"
Assert-True ($envLines[2] -eq "") "Blank line preserved"
Assert-True ($envLines[3] -eq "# App config") "Comment line 2 preserved"

Remove-Item ".secrets" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item ".env" -Force -ErrorAction SilentlyContinue
Remove-Item ".env.full" -Force -ErrorAction SilentlyContinue
Write-Host ""

# -- Test 10: No trailing newline in secret files ----------------------------
Write-Host "[Test 10] No trailing newline in secret files" -ForegroundColor Cyan

@"
PASSWORD=mypass
"@ | Set-Content ".env.full" -Encoding UTF8

@"
PASSWORD
"@ | Set-Content "envs\secrets.keys" -Encoding UTF8

Split-EnvSecrets -SourceFile ".env.full" -WriteSecrets $true | Out-Null

$bytes = [System.IO.File]::ReadAllBytes(".secrets\PASSWORD")
$lastByte = $bytes[$bytes.Length - 1]
Assert-True ($lastByte -ne 10 -and $lastByte -ne 13) "No trailing newline in secret file"
Assert-Equal ([System.IO.File]::ReadAllText(".secrets\PASSWORD")) "mypass" "Value is exactly 'mypass'"

Remove-Item ".secrets" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item ".env" -Force -ErrorAction SilentlyContinue
Remove-Item ".env.full" -Force -ErrorAction SilentlyContinue
Write-Host ""

# -- Cleanup ----------------------------------------------------------------
Pop-Location
Remove-Item $testRoot -Recurse -Force -ErrorAction SilentlyContinue

# -- Summary ----------------------------------------------------------------
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Results: $passed passed, $failed failed" -ForegroundColor $(if ($failed -gt 0) { "Red" } else { "Green" })
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

if ($failed -gt 0) { exit 1 }
