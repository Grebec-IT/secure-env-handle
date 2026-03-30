# Read .env file and store each entry in DPAPI-encrypted credential store
#
# Usage: .\store-env-to-credentials.ps1 dev
#        .\store-env-to-credentials.ps1 prod
#        .\store-env-to-credentials.ps1 dev custom.env
#
# When .secrets/ exists (from a split deploy), secret values are merged
# into the credential store automatically. The store always contains
# the complete set of config + secrets.
#
# Run from: <project>/secure-env-handle-and-deploy/

param(
    [Parameter(Mandatory=$true, Position=0)]
    [ValidateSet("dev", "prod")]
    [string]$EnvName,

    [Parameter(Position=1)]
    [string]$InputFile = ".env"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path $PSScriptRoot -Parent
Push-Location $ProjectRoot
Add-Type -AssemblyName System.Security

if (-not (Test-Path $InputFile)) {
    Write-Error "$InputFile not found in $ProjectRoot"
    exit 1
}

# Parse .env file (skip comments and empty lines)
$entries = @{}
$lines = Get-Content $InputFile
foreach ($rawLine in $lines) {
    $line = $rawLine.Trim()
    if ($line -and -not $line.StartsWith("#")) {
        $eqIdx = $line.IndexOf("=")
        if ($eqIdx -gt 0) {
            $key = $line.Substring(0, $eqIdx).Trim()
            $value = $line.Substring($eqIdx + 1).Trim()
            $entries[$key] = $value
        }
    }
}

# Merge secrets from .secrets/ directory (if present)
if (Test-Path ".secrets") {
    $secretFiles = Get-ChildItem ".secrets" -File -ErrorAction SilentlyContinue
    $secretCount = 0
    foreach ($file in $secretFiles) {
        $key = $file.Name
        $value = [System.IO.File]::ReadAllText($file.FullName)
        $entries[$key] = $value
        $secretCount++
    }
    if ($secretCount -gt 0) {
        Write-Host "Merged: $secretCount secret(s) from .secrets/"
    }
}

if ($entries.Count -eq 0) {
    Write-Error "No entries found in $InputFile"
    exit 1
}

# Encrypt each value with DPAPI and store as base64
$store = @{}
foreach ($key in $entries.Keys) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($entries[$key])
    $encrypted = [Security.Cryptography.ProtectedData]::Protect(
        $bytes, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    $store[$key] = [Convert]::ToBase64String($encrypted)
}

# Save to JSON
$dir = Join-Path $ProjectRoot "envs"
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
$outPath = Join-Path $dir "$EnvName.credentials.json"
$store | ConvertTo-Json | Set-Content -Path $outPath -Encoding UTF8

Write-Host ""
Write-Host "Stored $($entries.Count) entries to $outPath" -ForegroundColor Green
Write-Host ""
Write-Host "Keys stored:"
foreach ($key in ($entries.Keys | Sort-Object)) {
    Write-Host "  $key"
}
Write-Host ""
Write-Host "Values are DPAPI-encrypted (only decryptable by $env:USERNAME on this machine)"

Pop-Location
