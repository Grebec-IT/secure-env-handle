# Encrypt a .env file for storage in git
# Usage:
#   .\encrypt-env.ps1 dev          # encrypts ..\.env → ..\envs\dev.env.age
#   .\encrypt-env.ps1 prod         # encrypts ..\.env → ..\envs\prod.env.age
#   .\encrypt-env.ps1 dev my.env   # encrypts ..\my.env → ..\envs\dev.env.age
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
Set-Location $ProjectRoot

if (-not (Test-Path $InputFile)) {
    Write-Error "$InputFile not found in $ProjectRoot"
    exit 1
}

if (-not (Get-Command age -ErrorAction SilentlyContinue)) {
    Write-Error "age not found. Install with: winget install FiloSottile.age"
    exit 1
}

New-Item -ItemType Directory -Path "envs" -Force | Out-Null
$Output = "envs\$EnvName.env.age"

Write-Host "Encrypting: $InputFile -> $Output"
Write-Host "Enter a passphrase (save this in PasswordDepot):"
Write-Host ""

age --passphrase --output $Output $InputFile

if ($LASTEXITCODE -ne 0) {
    Write-Error "Encryption failed."
    exit 1
}

Write-Host ""
Write-Host "Encrypted: $Output" -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:"
Write-Host "  git add $Output"
Write-Host "  git commit -m 'Update $EnvName encrypted env'"
Write-Host "  git push"
