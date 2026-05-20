# backup.ps1 — call Hermes' built-in `hermes backup` inside the container
# and copy the resulting zip out to a host directory. Designed to be
# triggered by Windows Task Scheduler on a weekly cadence.
#
# Why a wrapper at all? The two-step (`docker exec` + `docker cp`) plus
# a deterministic dest path and a retention sweep are awkward to inline
# in a Task Scheduler action's argument string — and Task Scheduler XML
# isn't versionable here. Keep this script tiny: no BW, no env injection,
# no provider logic — just the orchestration glue around `hermes backup`.
#
# Usage:
#   pwsh -NoProfile -File scripts/backup.ps1
#   pwsh -NoProfile -File scripts/backup.ps1 -OutDir D:\hermes-backups -KeepLast 12
#
# Task Scheduler setup (one-time, per host):
#   1. Task Scheduler → Create Basic Task → name "Hermes Weekly Backup"
#   2. Trigger: Weekly (pick a low-activity time)
#   3. Action: Start a program
#        Program: pwsh.exe
#        Arguments: -NoProfile -File "C:\path\to\backup.ps1"
#   4. Conditions → leave "Start only if computer is on AC power" off
#      (desktop has no battery) and "Wake the computer" off.
#   5. Settings → "Run task as soon as possible after a scheduled start
#      is missed" ON (covers reboots through scheduled time).

[CmdletBinding()]
param(
    [string]$Container = 'hermes',
    [string]$OutDir    = "$env:USERPROFILE\hermes-backups",
    # Retention: how many most-recent backups to keep. Older ones get
    # deleted. 0 disables sweep.
    [int]   $KeepLast  = 8
)

$ErrorActionPreference = 'Stop'

# 1. Sanity: container running?
$state = docker inspect -f '{{.State.Running}}' $Container 2>$null
if ($state -ne 'true') {
    throw "Container '$Container' is not running. `docker compose up -d` first."
}

# 2. Make sure dest dir exists. Using -Force creates parents and is a
#    no-op if it already exists.
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# 3. Trigger Hermes' own backup writing into /opt/data (named volume) —
#    this puts the zip on the volume, which `docker cp` can then read.
#    Using a deterministic in-container path so we don't have to grep
#    the command's output for the actual filename.
$inContainerPath = '/opt/data/backup.zip'
Write-Host "→ docker exec $Container hermes backup -o $inContainerPath" -ForegroundColor DarkGray
docker exec $Container /opt/hermes/.venv/bin/hermes backup -o $inContainerPath
if ($LASTEXITCODE -ne 0) {
    throw "hermes backup failed (exit $LASTEXITCODE)"
}

# 4. Copy out with a timestamped filename.
$ts      = Get-Date -Format 'yyyyMMdd-HHmmss'
$hostDst = Join-Path $OutDir "hermes-$ts.zip"
Write-Host "→ docker cp ${Container}:${inContainerPath} `"$hostDst`"" -ForegroundColor DarkGray
docker cp "${Container}:${inContainerPath}" "$hostDst"
if ($LASTEXITCODE -ne 0) {
    throw "docker cp failed (exit $LASTEXITCODE)"
}

# 5. Remove the in-container temp zip so the volume doesn't accumulate
#    historical copies — host filesystem holds the retention chain.
docker exec $Container rm -f $inContainerPath 2>$null | Out-Null

# 6. Retention sweep. Sort by LastWriteTime descending, keep first N,
#    delete the rest.
if ($KeepLast -gt 0) {
    $old = Get-ChildItem -Path $OutDir -Filter 'hermes-*.zip' -File |
        Sort-Object LastWriteTime -Descending |
        Select-Object -Skip $KeepLast
    foreach ($f in $old) {
        Write-Host "  prune: $($f.Name)" -ForegroundColor Yellow
        Remove-Item $f.FullName -Force
    }
}

$size = (Get-Item $hostDst).Length
Write-Host ""
Write-Host "OK. $hostDst ($([math]::Round($size/1MB, 2)) MB)" -ForegroundColor Green
