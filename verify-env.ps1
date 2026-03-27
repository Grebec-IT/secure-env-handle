# Verify that all env storage layers are in sync for a given environment.
#
# Usage: .\verify-env.ps1 <dev|prod>
#
# Compares values across:
#   1. Existing .env file (if present)
#   2. DPAPI credential store (if present, Windows only)
#   3. age-encrypted file (if present — prompts for passphrase)
#
# Reports mismatches, missing keys, and overall sync status.

param(
    [Parameter(Mandatory=$true, Position=0)]
    [ValidateSet("dev", "prod")]
    [string]$EnvName
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Security

$ProjectRoot = Split-Path $PSScriptRoot -Parent
Set-Location $ProjectRoot

$envFile     = ".env"
$credFile    = "envs\$EnvName.credentials.json"
$ageFile     = "envs\$EnvName.env.age"

# -- Helper: parse .env content into a hashtable ----------------------------
function Parse-EnvContent {
    param([string[]]$Lines)
    $entries = @{}
    foreach ($line in $Lines) {
        $trimmed = $line.Trim()
        if ($trimmed -and -not $trimmed.StartsWith("#")) {
            $eqIdx = $trimmed.IndexOf("=")
            if ($eqIdx -gt 0) {
                $key = $trimmed.Substring(0, $eqIdx).Trim()
                $value = $trimmed.Substring($eqIdx + 1).Trim()
                $entries[$key] = $value
            }
        }
    }
    return $entries
}

# ==========================================================================
Write-Host ""
Write-Host "  Verify Env — $EnvName"
Write-Host "  ========================"
Write-Host ""

# -- Detect available layers -----------------------------------------------
$layers = @{}
$layerNames = @()

# Layer 1: .env file
if (Test-Path $envFile) {
    Write-Host "  [found]   .env" -ForegroundColor Green
    $layers["env"] = Parse-EnvContent (Get-Content $envFile)
    $layerNames += "env"
} else {
    Write-Host "  [absent]  .env" -ForegroundColor DarkGray
}

# Layer 2: DPAPI credential store
if (Test-Path $credFile) {
    Write-Host "  [found]   $credFile" -ForegroundColor Green
    $store = Get-Content -Path $credFile -Raw | ConvertFrom-Json
    $dpapiEntries = @{}
    foreach ($prop in $store.PSObject.Properties) {
        try {
            $encrypted = [Convert]::FromBase64String($prop.Value)
            $bytes = [Security.Cryptography.ProtectedData]::Unprotect(
                $encrypted, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser
            )
            $dpapiEntries[$prop.Name] = [Text.Encoding]::UTF8.GetString($bytes)
        } catch {
            $dpapiEntries[$prop.Name] = "<DECRYPT_FAILED>"
        }
    }
    $layers["dpapi"] = $dpapiEntries
    $layerNames += "dpapi"
} else {
    Write-Host "  [absent]  $credFile" -ForegroundColor DarkGray
}

# Layer 3: age-encrypted file
if (Test-Path $ageFile) {
    if (Get-Command age -ErrorAction SilentlyContinue) {
        Write-Host "  [found]   $ageFile — decrypting..." -ForegroundColor Green
        $tempFile = [System.IO.Path]::GetTempFileName()
        try {
            age --decrypt --output $tempFile $ageFile
            if ($LASTEXITCODE -eq 0) {
                $layers["age"] = Parse-EnvContent (Get-Content $tempFile)
                $layerNames += "age"
            } else {
                Write-Host "  [error]   age decryption failed" -ForegroundColor Red
            }
        } catch {
            Write-Host "  [error]   age decryption failed: $_" -ForegroundColor Red
        } finally {
            Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
        }
    } else {
        Write-Host "  [skip]    $ageFile — age not installed" -ForegroundColor Yellow
    }
} else {
    Write-Host "  [absent]  $ageFile" -ForegroundColor DarkGray
}

Write-Host ""

# -- Check we have at least 2 layers to compare ----------------------------
if ($layerNames.Count -lt 2) {
    Write-Host "  Need at least 2 layers to compare. Found $($layerNames.Count)." -ForegroundColor Yellow
    Write-Host ""
    exit 0
}

# -- Collect all keys across layers ----------------------------------------
$allKeys = @{}
foreach ($name in $layerNames) {
    foreach ($key in $layers[$name].Keys) {
        $allKeys[$key] = $true
    }
}
$sortedKeys = $allKeys.Keys | Sort-Object

# -- Compare ---------------------------------------------------------------
$inSync = 0
$outOfSync = 0
$missing = 0

Write-Host "  Key                              " -NoNewline
foreach ($name in $layerNames) {
    Write-Host ("{0,-10}" -f $name) -NoNewline
}
Write-Host ""
Write-Host "  $("-" * 35)" -NoNewline
foreach ($name in $layerNames) {
    Write-Host ("{0,-10}" -f "----------") -NoNewline
}
Write-Host ""

foreach ($key in $sortedKeys) {
    $values = @()
    $present = @()
    $absent = @()

    foreach ($name in $layerNames) {
        if ($layers[$name].ContainsKey($key)) {
            $values += $layers[$name][$key]
            $present += $name
        } else {
            $absent += $name
        }
    }

    # Determine status
    $uniqueValues = $values | Select-Object -Unique

    $displayKey = if ($key.Length -gt 33) { $key.Substring(0, 30) + "..." } else { $key }

    if ($absent.Count -gt 0) {
        # Key missing from one or more layers
        $missing++
        Write-Host ("  {0,-35}" -f $displayKey) -NoNewline
        foreach ($name in $layerNames) {
            if ($layers[$name].ContainsKey($key)) {
                Write-Host ("{0,-10}" -f "ok") -NoNewline -ForegroundColor Green
            } else {
                Write-Host ("{0,-10}" -f "MISSING") -NoNewline -ForegroundColor Yellow
            }
        }
        Write-Host ""
    } elseif ($uniqueValues.Count -eq 1) {
        # All layers have the same value
        $inSync++
        Write-Host ("  {0,-35}" -f $displayKey) -NoNewline
        foreach ($name in $layerNames) {
            Write-Host ("{0,-10}" -f "ok") -NoNewline -ForegroundColor Green
        }
        Write-Host ""
    } else {
        # Values differ
        $outOfSync++
        Write-Host ("  {0,-35}" -f $displayKey) -NoNewline
        # Show first 4 chars of each value for debugging
        foreach ($name in $layerNames) {
            $val = $layers[$name][$key]
            $preview = if ($val.Length -gt 4) { $val.Substring(0, 4) + "..." } else { $val }
            Write-Host ("{0,-10}" -f $preview) -NoNewline -ForegroundColor Red
        }
        Write-Host "  MISMATCH" -ForegroundColor Red
    }
}

# -- Summary ---------------------------------------------------------------
Write-Host ""
Write-Host "  ========================"
Write-Host "  Layers compared: $($layerNames -join ', ')"
Write-Host "  Keys total:      $($sortedKeys.Count)"
Write-Host "  In sync:         $inSync" -ForegroundColor Green
if ($missing -gt 0) {
    Write-Host "  Missing:         $missing" -ForegroundColor Yellow
}
if ($outOfSync -gt 0) {
    Write-Host "  Out of sync:     $outOfSync" -ForegroundColor Red
}

if ($outOfSync -eq 0 -and $missing -eq 0) {
    Write-Host ""
    Write-Host "  All layers are in sync." -ForegroundColor Green
} else {
    Write-Host ""
    if ($outOfSync -gt 0) {
        Write-Host "  WARNING: $outOfSync key(s) have different values across layers." -ForegroundColor Red
        Write-Host "  Re-run store-env-to-credentials.ps1 and encrypt-env.ps1 to fix." -ForegroundColor Yellow
    }
    if ($missing -gt 0) {
        Write-Host "  NOTE: $missing key(s) missing from one or more layers." -ForegroundColor Yellow
    }
}
Write-Host ""
