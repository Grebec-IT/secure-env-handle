# Decrypt an .age file back to .env
# Usage:
#   .\decrypt-env.ps1 dev          # decrypts envs\dev.env.age → .env (+ .secrets/ if manifest exists)
#   .\decrypt-env.ps1 prod         # decrypts envs\prod.env.age → .env (+ .secrets/ if manifest exists)
#   .\decrypt-env.ps1 dev out.env  # decrypts envs\dev.env.age → out.env (+ .secrets/ if manifest exists)
#   .\decrypt-env.ps1 dev -Full    # decrypts everything into a single .env (no split)
#
# When envs/secrets.keys exists, the output is automatically split:
#   - .env (or OutputFile) contains config-only entries
#   - .secrets/KEY files contain secret values
# Use -Full to skip splitting and write everything to a single file.
#
# Run from: <project>/secure-env-handle-and-deploy/

param(
    [Parameter(Mandatory=$true, Position=0)]
    [ValidateSet("dev", "prod")]
    [string]$EnvName,

    [Parameter(Position=1)]
    [string]$OutputFile = ".env",

    [switch]$Full
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path $PSScriptRoot -Parent
Push-Location $ProjectRoot
[System.IO.Directory]::SetCurrentDirectory($ProjectRoot)

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
    while ($true) {
        $confirm = Read-Host "Continue? [Y/n]"
        if ($confirm -eq "" -or $confirm -in "Y", "y") { break }
        if ($confirm -in "N", "n") {
            Write-Host "Aborted."
            exit 0
        }
        Write-Host "Invalid input. Please enter Y or N." -ForegroundColor Yellow
    }
}

# Check if we should split secrets
$manifest = Join-Path "envs" "secrets.keys"
$shouldSplit = (-not $Full) -and (Test-Path $manifest)

if ($shouldSplit) {
    $secretKeys = @(Get-Content $manifest |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith("#") })
    if ($secretKeys.Count -eq 0) { $shouldSplit = $false }

    # Validate key names (prevent path traversal)
    foreach ($sk in $secretKeys) {
        if ($sk -notmatch '^[A-Za-z0-9_]+$') {
            Write-Error "Invalid key name in secrets.keys: '$sk' (only A-Z, a-z, 0-9, _ allowed)"
            exit 1
        }
    }
}

if ($shouldSplit) {
    # Decrypt to temp file, then split — secrets never touch the output file
    $tempFile = [System.IO.Path]::GetTempFileName()
    try {
        Write-Host "Decrypting: $AgeFile (splitting via envs/secrets.keys)"
        age --decrypt --output $tempFile $AgeFile

        if ($LASTEXITCODE -ne 0) {
            Write-Error "Decryption failed."
            exit 1
        }

        # Split into config (output file) and secrets (.secrets/)
        $configLines = @()
        $splitCount = 0
        $secretDir = ".secrets"
        if (Test-Path $secretDir) { Remove-Item $secretDir -Recurse -Force }
        New-Item -ItemType Directory -Path $secretDir -Force | Out-Null
        # Restrict permissions to current user only
        $acl = Get-Acl $secretDir
        $acl.SetAccessRuleProtection($true, $false)
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            [System.Security.Principal.WindowsIdentity]::GetCurrent().Name, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
        $acl.SetAccessRule($rule)
        Set-Acl $secretDir $acl

        $tempLines = Get-Content $tempFile
        foreach ($rawLine in $tempLines) {
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
            $value = $line.Substring($eqIdx + 1)

            if ($key -in $secretKeys) {
                $secretPath = Join-Path $secretDir $key
                if (Test-Path $secretPath -PathType Container) { Remove-Item $secretPath -Recurse -Force }
                [System.IO.File]::WriteAllText($secretPath, $value)
                $splitCount++
            } else {
                $configLines += $rawLine
            }
        }

        $configLines | Set-Content -Path $OutputFile -Encoding UTF8
    } finally {
        Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
    }

    Write-Host ""
    Write-Host "Decrypted (split mode):" -ForegroundColor Green
    Write-Host "  Config:  $OutputFile"
    Write-Host "  Secrets: $splitCount key(s) -> .secrets/"
    Write-Host ""
    Write-Host "Remember to delete both when done:"
    Write-Host "  Remove-Item $OutputFile"
    Write-Host "  Remove-Item .secrets -Recurse"
} else {
    # No split — write everything to a single file
    Write-Host "Decrypting: $AgeFile -> $OutputFile"
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
}

Pop-Location
