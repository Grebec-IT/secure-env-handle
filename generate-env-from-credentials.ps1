# Generate .env file from DPAPI-encrypted credential store
#
# Usage: .\generate-env-from-credentials.ps1 dev
#        .\generate-env-from-credentials.ps1 prod
#
# Run from: <project>/secure-env-handle-and-deploy/

param(
    [Parameter(Mandatory=$true, Position=0)]
    [ValidateSet("dev", "prod")]
    [string]$EnvName
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path $PSScriptRoot -Parent
Set-Location $ProjectRoot
Add-Type -AssemblyName System.Security

$credFile = Join-Path "envs" "$EnvName.credentials.json"

if (-not (Test-Path $credFile)) {
    Write-Error "$credFile not found. Run store-env-to-credentials.ps1 first."
    exit 1
}

# Read and decrypt each entry
$store = Get-Content -Path $credFile -Raw | ConvertFrom-Json
$lines = @()

foreach ($prop in ($store.PSObject.Properties | Sort-Object Name)) {
    $key = $prop.Name
    try {
        $encrypted = [Convert]::FromBase64String($prop.Value)
        $bytes = [Security.Cryptography.ProtectedData]::Unprotect(
            $encrypted, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        $value = [Text.Encoding]::UTF8.GetString($bytes)
        $lines += "$key=$value"
    } catch {
        Write-Host "  WARNING: Could not decrypt $key (different user/machine?)" -ForegroundColor Yellow
    }
}

if ($lines.Count -eq 0) {
    Write-Error "No entries could be decrypted."
    exit 1
}

# Write .env
$envPath = Join-Path $ProjectRoot ".env"
$lines | Set-Content -Path $envPath -Encoding UTF8

Write-Host ""
Write-Host "Generated .env with $($lines.Count) entries from $credFile" -ForegroundColor Green
Write-Host ""
Write-Host "You can now:"
Write-Host "  - Edit .env manually"
Write-Host "  - Run: docker compose up -d"
Write-Host "  - Store changes back: .\store-env-to-credentials.ps1 $EnvName"
