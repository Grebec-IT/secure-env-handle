# Encrypt a .env file for storage in git
# Usage:
#   .\encrypt-env.ps1 dev          # encrypts ..\.env → ..\envs\dev.env.age
#   .\encrypt-env.ps1 prod         # encrypts ..\.env → ..\envs\prod.env.age
#   .\encrypt-env.ps1 dev my.env   # encrypts ..\my.env → ..\envs\dev.env.age
#
# When .secrets/ exists (from a split deploy), secret values are merged
# back into the encrypted file automatically. The .age file always
# contains the complete set of config + secrets.
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

# Merge .env (config) + .secrets/ (secrets) into a temp file for encryption
$encryptSource = $InputFile
$tempMerged = $null

if (Test-Path ".secrets") {
    $manifest = Join-Path "envs" "secrets.keys"
    $secretFiles = Get-ChildItem ".secrets" -File -ErrorAction SilentlyContinue

    if ($secretFiles -and $secretFiles.Count -gt 0) {
        $tempMerged = [System.IO.Path]::GetTempFileName()
        # Build merged content: .env lines + secret lines
        $mergedLines = @(Get-Content $InputFile)
        $secretCount = 0
        foreach ($file in $secretFiles) {
            $key = $file.Name
            $value = [System.IO.File]::ReadAllText($file.FullName)
            $mergedLines += "$key=$value"
            $secretCount++
        }
        $mergedLines | Set-Content $tempMerged -Encoding UTF8
        $encryptSource = $tempMerged
        Write-Host "Merged: $InputFile + $secretCount secret(s) from .secrets/"
    }
}

Write-Host "Encrypting: -> $Output"

age --passphrase --output $Output $encryptSource

if ($LASTEXITCODE -ne 0) {
    if ($tempMerged -and (Test-Path $tempMerged)) { Remove-Item $tempMerged -Force }
    Write-Error "Encryption failed."
    exit 1
}

if ($tempMerged -and (Test-Path $tempMerged)) { Remove-Item $tempMerged -Force }

Write-Host ""
Write-Host "Encrypted: $Output" -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:"
Write-Host "  git add $Output"
Write-Host "  git commit -m 'Update $EnvName encrypted env'"
Write-Host "  git push"

Pop-Location
