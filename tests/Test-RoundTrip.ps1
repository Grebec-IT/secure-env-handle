# End-to-end round-trip tests for the complete secret lifecycle
#
# Tests that NO entries are lost through:
#   1. Split (.env → .env config + .secrets/)
#   2. Merge + Encrypt + Decrypt (.env + .secrets/ → .age → .env + .secrets/)
#   3. DPAPI store + restore (.env + .secrets/ → credentials.json → .env)
#
# Uses 3 config + 7 secret entries (10 total) to catch off-by-one errors.
# Uses age with key file (not passphrase) to avoid interactive prompts.
#
# Run from repo root: .\tests\Test-RoundTrip.ps1

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Security
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

# -- Parse a KEY=VALUE file into a sorted hashtable --------------------------
function Parse-EnvFile {
    param([string]$Path)
    $result = @{}
    foreach ($rawLine in (Get-Content $Path)) {
        $line = $rawLine.Trim()
        if (-not $line -or $line.StartsWith("#")) { continue }
        $eqIdx = $line.IndexOf("=")
        if ($eqIdx -le 0) { continue }
        $key = $line.Substring(0, $eqIdx).Trim()
        $value = $line.Substring($eqIdx + 1).Trim()
        $result[$key] = $value
    }
    return $result
}

# -- Split function (same logic as deploy.ps1) ------------------------------
function Split-EnvFile {
    param([string]$SourceFile, [string]$ManifestFile, [string]$OutputEnv = ".env", [string]$SecretDir = ".secrets")

    $secretKeys = @(Get-Content $ManifestFile |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith("#") })

    if (Test-Path $SecretDir) { Remove-Item $SecretDir -Recurse -Force }
    New-Item -ItemType Directory -Path $SecretDir -Force | Out-Null

    $configLines = @()
    $splitCount = 0
    foreach ($rawLine in (Get-Content $SourceFile)) {
        $line = $rawLine.Trim()
        if (-not $line -or $line.StartsWith("#")) { $configLines += $rawLine; continue }
        $eqIdx = $line.IndexOf("=")
        if ($eqIdx -le 0) { $configLines += $rawLine; continue }
        $key = $line.Substring(0, $eqIdx).Trim()
        $value = $line.Substring($eqIdx + 1).Trim()

        if ($key -in $secretKeys) {
            $path = Join-Path $SecretDir $key
            if (Test-Path $path -PathType Container) { Remove-Item $path -Recurse -Force }
            [System.IO.File]::WriteAllText($path, $value)
            $splitCount++
        } else {
            $configLines += $rawLine
        }
    }
    $configLines | Set-Content -Path $OutputEnv -Encoding UTF8
    return $splitCount
}

# -- Merge function (same logic as encrypt-env.ps1) -------------------------
function Merge-EnvAndSecrets {
    param([string]$EnvFile = ".env", [string]$SecretDir = ".secrets")
    $mergedLines = @(Get-Content $EnvFile)
    if (Test-Path $SecretDir) {
        foreach ($file in (Get-ChildItem $SecretDir -File)) {
            $key = $file.Name
            $value = [System.IO.File]::ReadAllText($file.FullName)
            $mergedLines += "$key=$value"
        }
    }
    return $mergedLines
}

# -- Check prerequisites ----------------------------------------------------
$hasAge = [bool](Get-Command age -ErrorAction SilentlyContinue)
$hasAgeKeygen = [bool](Get-Command age-keygen -ErrorAction SilentlyContinue)

# -- Setup temp project structure -------------------------------------------
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) "seh-roundtrip-$(Get-Random)"
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $testRoot "envs") -Force | Out-Null

Push-Location $testRoot
[System.IO.Directory]::SetCurrentDirectory($testRoot)

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Round-Trip Tests (3 config + 7 secrets)"
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Test root: $testRoot"
Write-Host "  age installed: $hasAge"
Write-Host ""

# -- The canonical test data: 3 config + 7 secrets = 10 entries -------------
$originalEntries = [ordered]@{
    # Config (3)
    APP_PORT         = "8080"
    DB_SCHEMA        = "public"
    LOG_LEVEL        = "info"
    # Secrets (7)
    POSTGRES_PASSWORD           = "pg_s3cret!"
    API_TOKEN                   = "tok_abc123xyz"
    JWT_SECRET                  = "eyJhbGciOiJIUzI1NiJ9"
    SMTP_PASSWORD               = "mail=pass@#"
    REDIS_PASSWORD              = "r3d!s"
    AUTHENTICATOR_PASSWORD      = "auth_pw_456"
    ENCRYPTION_KEY              = "aes-256-key-value"
}

$secretKeyNames = @(
    "POSTGRES_PASSWORD"
    "API_TOKEN"
    "JWT_SECRET"
    "SMTP_PASSWORD"
    "REDIS_PASSWORD"
    "AUTHENTICATOR_PASSWORD"
    "ENCRYPTION_KEY"
)

$configKeyNames = @("APP_PORT", "DB_SCHEMA", "LOG_LEVEL")

# Write the canonical .env.original (all 10 entries in one file)
$originalLines = @()
$originalLines += "# Config"
foreach ($k in $configKeyNames) { $originalLines += "$k=$($originalEntries[$k])" }
$originalLines += ""
$originalLines += "# Secrets"
foreach ($k in $secretKeyNames) { $originalLines += "$k=$($originalEntries[$k])" }
$originalLines | Set-Content ".env.original" -Encoding UTF8

# Write secrets.keys manifest
$secretKeyNames | Set-Content "envs\secrets.keys" -Encoding UTF8

# ===========================================================================
# TEST 1: Split preserves all entries
# ===========================================================================
Write-Host "[Test 1] Split: 10 entries -> 3 config + 7 secret files" -ForegroundColor Cyan

Copy-Item ".env.original" ".env.full" -Force
$splitCount = Split-EnvFile -SourceFile ".env.full" -ManifestFile "envs\secrets.keys"
Remove-Item ".env.full" -Force

Assert-Equal "$splitCount" "7" "Split created 7 secret files"

# Verify .env has exactly 3 config keys
$envEntries = Parse-EnvFile ".env"
Assert-Equal "$($envEntries.Count)" "3" ".env has 3 entries"
foreach ($k in $configKeyNames) {
    Assert-Equal "$($envEntries[$k])" "$($originalEntries[$k])" ".env: $k correct"
}

# Verify .secrets/ has exactly 7 files, all are FILES, all have correct values
$secretFiles = @(Get-ChildItem ".secrets" -File)
Assert-Equal "$($secretFiles.Count)" "7" ".secrets/ has 7 files"
foreach ($k in $secretKeyNames) {
    $path = Join-Path ".secrets" $k
    Assert-True (Test-Path $path -PathType Leaf) ".secrets\$k is a FILE"
    $val = [System.IO.File]::ReadAllText($path)
    Assert-Equal $val $originalEntries[$k] ".secrets\$k value correct"
}

Write-Host ""

# ===========================================================================
# TEST 2: Merge reconstructs all 10 entries
# ===========================================================================
Write-Host "[Test 2] Merge: .env + .secrets/ -> 10 entries" -ForegroundColor Cyan

$merged = Merge-EnvAndSecrets -EnvFile ".env" -SecretDir ".secrets"
$merged | Set-Content ".env.merged" -Encoding UTF8
$mergedEntries = Parse-EnvFile ".env.merged"

Assert-Equal "$($mergedEntries.Count)" "10" "Merged has 10 entries"
foreach ($k in $originalEntries.Keys) {
    Assert-Equal "$($mergedEntries[$k])" "$($originalEntries[$k])" "Merged: $k correct"
}

Remove-Item ".env.merged" -Force
Write-Host ""

# ===========================================================================
# TEST 2b: Deploy scenario — existing config-only .env + .secrets/
# This is the EXACT flow that was broken: decrypt-env creates .env (config)
# + .secrets/ (secrets). Then deploy.ps1 loads .env, must merge .secrets/
# back in, split, and end up with the same state. If the merge is missing,
# the split finds 0 secrets and wipes .secrets/.
# ===========================================================================
Write-Host "[Test 2b] Deploy scenario: config-only .env + .secrets/ -> merge -> split" -ForegroundColor Cyan

# State after decrypt-env: .env has config only, .secrets/ has secrets
# (This is already the state from Test 1)
Assert-Equal "$((Parse-EnvFile '.env').Count)" "3" "Pre-condition: .env has 3 config entries"
Assert-Equal "$(@(Get-ChildItem '.secrets' -File).Count)" "7" "Pre-condition: .secrets/ has 7 files"

# Simulate deploy.ps1 "existing .env" loading: merge .env + .secrets/ into .env.full
$deployMergedLines = @(Get-Content ".env")
if (Test-Path ".secrets") {
    foreach ($file in (Get-ChildItem ".secrets" -File -ErrorAction SilentlyContinue)) {
        $deployMergedLines += "$($file.Name)=$([System.IO.File]::ReadAllText($file.FullName))"
    }
}
$deployMergedLines | Set-Content ".env.full" -Encoding UTF8

# Verify .env.full has ALL 10 entries
$fullEntries = Parse-EnvFile ".env.full"
Assert-Equal "$($fullEntries.Count)" "10" ".env.full has all 10 entries after merge"

# Now split (same as deploy does)
$deploySplitCount = Split-EnvFile -SourceFile ".env.full" -ManifestFile "envs\secrets.keys"
Remove-Item ".env.full" -Force

Assert-Equal "$deploySplitCount" "7" "Deploy split: 7 secrets (NOT 0!)"
Assert-Equal "$((Parse-EnvFile '.env').Count)" "3" "After deploy split: .env has 3 config"
Assert-Equal "$(@(Get-ChildItem '.secrets' -File).Count)" "7" "After deploy split: .secrets/ has 7 files"

# Verify every value survived
foreach ($k in $configKeyNames) {
    $envEntries2 = Parse-EnvFile ".env"
    Assert-Equal "$($envEntries2[$k])" "$($originalEntries[$k])" "Deploy scenario: $k (config)"
}
foreach ($k in $secretKeyNames) {
    $val = [System.IO.File]::ReadAllText((Join-Path ".secrets" $k))
    Assert-Equal $val $originalEntries[$k] "Deploy scenario: $k (secret)"
}

Write-Host ""

# ===========================================================================
# TEST 3: age encrypt → decrypt round-trip (if age + age-keygen available)
# ===========================================================================
if ($hasAge -and $hasAgeKeygen) {
    Write-Host "[Test 3] age round-trip: merge -> encrypt -> decrypt -> split" -ForegroundColor Cyan

    # Generate a key pair (no passphrase prompt needed)
    $keyFile = Join-Path $testRoot "test-key.txt"
    $ErrorActionPreference = "Continue"
    age-keygen -o $keyFile 2>&1 | Out-Null
    $ErrorActionPreference = "Stop"
    $recipient = (Get-Content $keyFile | Where-Object { $_ -match "public key: (age1\S+)" } | ForEach-Object { if ($_ -match "age1\S+") { $Matches[0] } })

    # Merge into temp file
    $merged = Merge-EnvAndSecrets -EnvFile ".env" -SecretDir ".secrets"
    $merged | Set-Content ".env.pre-encrypt" -Encoding UTF8

    # Count entries before encrypt
    $beforeEntries = Parse-EnvFile ".env.pre-encrypt"
    Assert-Equal "$($beforeEntries.Count)" "10" "Before encrypt: 10 entries"

    # Encrypt with age (key-based, not passphrase)
    age -r $recipient -o "envs\dev.env.age" ".env.pre-encrypt"
    Remove-Item ".env.pre-encrypt" -Force

    Assert-True (Test-Path "envs\dev.env.age") ".age file created"

    # Decrypt
    age -d -i $keyFile -o ".env.decrypted" "envs\dev.env.age"

    # Count entries after decrypt
    $afterEntries = Parse-EnvFile ".env.decrypted"
    Assert-Equal "$($afterEntries.Count)" "10" "After decrypt: 10 entries"

    # Verify every single entry
    foreach ($k in $originalEntries.Keys) {
        Assert-Equal "$($afterEntries[$k])" "$($originalEntries[$k])" "age round-trip: $k"
    }

    # Now split the decrypted file and verify
    $splitCount = Split-EnvFile -SourceFile ".env.decrypted" -ManifestFile "envs\secrets.keys"
    Remove-Item ".env.decrypted" -Force

    Assert-Equal "$splitCount" "7" "Split after decrypt: 7 secrets"

    $envAfter = Parse-EnvFile ".env"
    Assert-Equal "$($envAfter.Count)" "3" ".env after decrypt+split: 3 config"

    $secretFilesAfter = @(Get-ChildItem ".secrets" -File)
    Assert-Equal "$($secretFilesAfter.Count)" "7" ".secrets/ after decrypt+split: 7 files"

    foreach ($k in $secretKeyNames) {
        $val = [System.IO.File]::ReadAllText((Join-Path ".secrets" $k))
        Assert-Equal $val $originalEntries[$k] "age round-trip split: $k"
    }

    Remove-Item "envs\dev.env.age" -Force -ErrorAction SilentlyContinue
    Remove-Item $keyFile -Force
    Write-Host ""
} else {
    Write-Host "[Test 3] SKIP: age/age-keygen not installed" -ForegroundColor Yellow
    Write-Host ""
}

# ===========================================================================
# TEST 4: DPAPI store → generate round-trip
# ===========================================================================
Write-Host "[Test 4] DPAPI round-trip: store -> generate -> compare" -ForegroundColor Cyan

# Build complete entries (config from .env + secrets from .secrets/)
$storeEntries = @{}
foreach ($rawLine in (Get-Content ".env")) {
    $line = $rawLine.Trim()
    if (-not $line -or $line.StartsWith("#")) { continue }
    $eqIdx = $line.IndexOf("=")
    if ($eqIdx -le 0) { continue }
    $key = $line.Substring(0, $eqIdx).Trim()
    $value = $line.Substring($eqIdx + 1).Trim()
    $storeEntries[$key] = $value
}
# Merge secrets
foreach ($file in (Get-ChildItem ".secrets" -File)) {
    $storeEntries[$file.Name] = [System.IO.File]::ReadAllText($file.FullName)
}

Assert-Equal "$($storeEntries.Count)" "10" "DPAPI input: 10 entries"

# Encrypt each value with DPAPI
$dpapiStore = @{}
foreach ($key in $storeEntries.Keys) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($storeEntries[$key])
    $encrypted = [Security.Cryptography.ProtectedData]::Protect(
        $bytes, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    $dpapiStore[$key] = [Convert]::ToBase64String($encrypted)
}
$dpapiStore | ConvertTo-Json | Set-Content "envs\dev.credentials.json" -Encoding UTF8

# Read back and decrypt
$restored = Get-Content "envs\dev.credentials.json" -Raw | ConvertFrom-Json
$restoredEntries = @{}
foreach ($prop in $restored.PSObject.Properties) {
    $encrypted = [Convert]::FromBase64String($prop.Value)
    $bytes = [Security.Cryptography.ProtectedData]::Unprotect(
        $encrypted, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    $restoredEntries[$prop.Name] = [Text.Encoding]::UTF8.GetString($bytes)
}

Assert-Equal "$($restoredEntries.Count)" "10" "DPAPI restored: 10 entries"

foreach ($k in $originalEntries.Keys) {
    Assert-Equal "$($restoredEntries[$k])" "$($originalEntries[$k])" "DPAPI round-trip: $k"
}

Remove-Item "envs\dev.credentials.json" -Force
Write-Host ""

# ===========================================================================
# TEST 5: Full lifecycle: original -> split -> merge -> encrypt -> decrypt -> split -> compare
# ===========================================================================
if ($hasAge -and $hasAgeKeygen) {
    Write-Host "[Test 5] Full lifecycle: original -> split -> encrypt -> decrypt -> split -> compare" -ForegroundColor Cyan

    # Start fresh from original
    Remove-Item ".env" -Force -ErrorAction SilentlyContinue
    Remove-Item ".secrets" -Recurse -Force -ErrorAction SilentlyContinue

    # Step 1: Split original into .env + .secrets/
    Copy-Item ".env.original" ".env.full" -Force
    Split-EnvFile -SourceFile ".env.full" -ManifestFile "envs\secrets.keys" | Out-Null
    Remove-Item ".env.full" -Force

    # Step 2: Merge .env + .secrets/ (same as encrypt-env does)
    $merged = Merge-EnvAndSecrets
    $merged | Set-Content ".env.for-encrypt" -Encoding UTF8

    # Step 3: Encrypt
    $keyFile = Join-Path $testRoot "test-key2.txt"
    $ErrorActionPreference = "Continue"
    age-keygen -o $keyFile 2>&1 | Out-Null
    $ErrorActionPreference = "Stop"
    $recipient = (Get-Content $keyFile | Where-Object { $_ -match "public key: (age1\S+)" } | ForEach-Object { if ($_ -match "age1\S+") { $Matches[0] } })
    age -r $recipient -o "envs\dev.env.age" ".env.for-encrypt"
    Remove-Item ".env.for-encrypt" -Force

    # Step 4: Wipe local state (simulate production server)
    Remove-Item ".env" -Force
    Remove-Item ".secrets" -Recurse -Force

    # Step 5: Decrypt
    age -d -i $keyFile -o ".env.full" "envs\dev.env.age"

    # Step 6: Split
    $finalSplitCount = Split-EnvFile -SourceFile ".env.full" -ManifestFile "envs\secrets.keys"
    Remove-Item ".env.full" -Force

    # Step 7: Verify everything survived
    $finalEnv = Parse-EnvFile ".env"
    $finalSecretFiles = @(Get-ChildItem ".secrets" -File)

    Assert-Equal "$($finalEnv.Count)" "3" "Final .env: 3 config entries"
    Assert-Equal "$($finalSecretFiles.Count)" "7" "Final .secrets/: 7 files"
    Assert-Equal "$finalSplitCount" "7" "Final split count: 7"

    foreach ($k in $configKeyNames) {
        Assert-Equal "$($finalEnv[$k])" "$($originalEntries[$k])" "Full lifecycle: $k (config)"
    }
    foreach ($k in $secretKeyNames) {
        $val = [System.IO.File]::ReadAllText((Join-Path ".secrets" $k))
        Assert-Equal $val $originalEntries[$k] "Full lifecycle: $k (secret)"
    }

    Remove-Item "envs\dev.env.age", $keyFile -Force -ErrorAction SilentlyContinue
    Write-Host ""
} else {
    Write-Host "[Test 5] SKIP: age/age-keygen not installed" -ForegroundColor Yellow
    Write-Host ""
}

# -- Cleanup ----------------------------------------------------------------
Pop-Location
Remove-Item $testRoot -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Results: $passed passed, $failed failed" -ForegroundColor $(if ($failed -gt 0) { "Red" } else { "Green" })
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

if ($failed -gt 0) { exit 1 }
