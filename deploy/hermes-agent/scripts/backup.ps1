# backup.ps1 — snapshot ~/.hermes to a timestamped tar.gz
#
# Usage:
#   pwsh ./scripts/backup.ps1                    # default: backs up to ./backups/
#   pwsh ./scripts/backup.ps1 -OutDir D:\hermes-backups
#   pwsh ./scripts/backup.ps1 -DataDir C:\custom\.hermes
#
# Notes:
#   - Stops the gateway briefly to avoid mid-write inconsistency, then restarts.
#   - Uses tar (bundled with Windows 10/11 by default).
#   - Restoring on a new machine: extract the tar into the target HERMES_DATA
#     path, then `docker compose up -d`. No DB import required.

param(
    [string]$DataDir = "$env:USERPROFILE\.hermes",
    [string]$OutDir  = "$PSScriptRoot\..\backups",
    [switch]$NoStop
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $DataDir)) {
    Write-Error "Data dir not found: $DataDir"
    exit 1
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$ts      = Get-Date -Format 'yyyyMMdd-HHmmss'
$outFile = Join-Path $OutDir "hermes-$ts.tar.gz"

if (-not $NoStop) {
    Write-Host "Stopping gateway for consistent snapshot..."
    docker stop hermes hermes-dashboard 2>$null | Out-Null
}

try {
    Write-Host "Archiving $DataDir → $outFile"
    # -C parent so the archive contains a single top-level ".hermes" dir
    $parent = Split-Path $DataDir -Parent
    $leaf   = Split-Path $DataDir -Leaf
    tar -czf $outFile -C $parent $leaf
    Write-Host "OK: $((Get-Item $outFile).Length / 1MB) MB written"
} finally {
    if (-not $NoStop) {
        Write-Host "Restarting gateway..."
        docker start hermes hermes-dashboard 2>$null | Out-Null
    }
}
