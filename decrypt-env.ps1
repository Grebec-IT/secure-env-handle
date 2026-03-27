# Decrypt an .age file back to .env
# Usage:
#   .\decrypt-env.ps1 dev          # decrypts ..\envs\dev.env.age → ..\.env
#   .\decrypt-env.ps1 prod         # decrypts ..\envs\prod.env.age → ..\.env
#   .\decrypt-env.ps1 dev out.env  # decrypts ..\envs\dev.env.age → ..\out.env
#
# Run from: <project>/secure-env-handle-and-deploy/

param(
    [Parameter(Mandatory=$true, Position=0)]
    [ValidateSet("dev", "prod")]
    [string]$EnvName,

    [Parameter(Position=1)]
    [string]$OutputFile = ".env"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path $PSScriptRoot -Parent
Set-Location $ProjectRoot

$AgeFile = "envs\$EnvName.env.age"

if (-not (Test-Path $AgeFile)) {
    Write-Error "$AgeFile not found. Encrypt first with: .\encrypt-env.ps1 $EnvName"
    exit 1
}

if (-not (Get-Command age -ErrorAction SilentlyContinue)) {
    Write-Error "age not found. Install with: winget install FiloSottile.age"
    exit 1
}

if (Test-Path $OutputFile) {
    Write-Host "WARNING: $OutputFile already exists and will be overwritten." -ForegroundColor Yellow
    $confirm = Read-Host "Continue? [Y/n]"
    if ($confirm -eq "n" -or $confirm -eq "N") {
        Write-Host "Aborted."
        exit 0
    }
}

Write-Host "Decrypting: $AgeFile -> $OutputFile"
Write-Host "Enter passphrase:"
Write-Host ""

age --decrypt --output $OutputFile $AgeFile

if ($LASTEXITCODE -ne 0) {
    Write-Error "Decryption failed."
    exit 1
}

Write-Host ""
Write-Host "Decrypted: $OutputFile" -ForegroundColor Green
Write-Host ""
Write-Host "Remember to delete $OutputFile when done:"
Write-Host "  Remove-Item $OutputFile"
