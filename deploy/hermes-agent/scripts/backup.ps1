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
# Full usage, parameter docs, and Task Scheduler setup walkthrough live
# in `deploy/hermes-agent/README.md` (the "Backups" section). This
# header sticks to invariants the code itself depends on.

[CmdletBinding()]
param(
    [string]$Container = 'hermes',
    [string]$OutDir    = "$env:USERPROFILE\hermes-backups",
    # Absolute path to the `hermes` entry point inside the container.
    # Hardcoded here (not exported through compose env) because:
    #   - `docker exec` runs without the container's ENTRYPOINT shell init,
    #     so `$PATH` doesn't include venv/bin and a bare `hermes` fails.
    #   - The upstream image's venv path is stable across releases; if it
    #     ever moves, change this default once.
    [string]$HermesBin = '/opt/hermes/.venv/bin/hermes',
    # Retention: how many most-recent backups to keep. Older ones get
    # deleted. 0 disables the sweep entirely.
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
Write-Host "→ docker exec $Container $HermesBin backup -o $inContainerPath" -ForegroundColor DarkGray
docker exec $Container $HermesBin backup -o $inContainerPath
if ($LASTEXITCODE -ne 0) {
    throw "hermes backup failed (exit $LASTEXITCODE)"
}

# 4. Copy out with a timestamped filename, then always clean up the
#    in-container temp zip — even if `docker cp` fails. Without the
#    finally, a transient cp failure leaves /opt/data/backup.zip on the
#    volume; benign because the next run overwrites it, but it bloats
#    `hermes backup`'s own working area unnecessarily.
$ts      = Get-Date -Format 'yyyyMMdd-HHmmss'
$hostDst = Join-Path $OutDir "hermes-$ts.zip"
Write-Host "→ docker cp ${Container}:${inContainerPath} `"$hostDst`"" -ForegroundColor DarkGray
try {
    docker cp "${Container}:${inContainerPath}" "$hostDst"
    if ($LASTEXITCODE -ne 0) {
        throw "docker cp failed (exit $LASTEXITCODE)"
    }
} finally {
    # 2>$null swallows "file not found" if the backup step never produced
    # a zip; nothing to clean up in that case.
    docker exec $Container rm -f $inContainerPath 2>$null | Out-Null
}

# 5. Retention sweep. Sort by LastWriteTime descending, keep first N,
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
