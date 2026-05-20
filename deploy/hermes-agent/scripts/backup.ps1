# backup.ps1 — snapshot the `hermes-data` named volume to a timestamped tar.gz.
#
# Usage:
#   pwsh ./scripts/backup.ps1                            # default volume + ../backups/
#   pwsh ./scripts/backup.ps1 -OutDir D:\hermes-backups
#   pwsh ./scripts/backup.ps1 -VolumeName custom-data
#   pwsh ./scripts/backup.ps1 -NoStop                    # skip container stop
#
# Why an alpine sidecar (not host-side tar):
#   Named Docker volumes live inside the Docker storage backend (on Windows,
#   the WSL2 VM's ext4 fs). The host PowerShell process cannot read them
#   directly. An alpine container with the volume mounted RO is the standard
#   pattern — see compose.yml's own header comment.
#
# Why bind-mount the output dir (not pipe stdout into a host file):
#   PowerShell's `>` redirection runs through the text pipeline and corrupts
#   binary streams (CRLF / encoding normalization). Bind-mounting $OutDir as
#   /out lets alpine write the .tar.gz directly to the host filesystem with
#   no PowerShell-side interpretation.
#
# Restore on a new host:
#   docker volume create hermes-data
#   docker run --rm -v hermes-data:/data -v ${PWD}:/in:ro alpine `
#     sh -c "cd /data && tar xzf /in/hermes-<ts>.tar.gz"
#   # then `pwsh start-hermes.ps1`

[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z0-9_-]+$')]
    [string]$VolumeName       = 'hermes-data',
    [string]$OutDir           = "$PSScriptRoot\..\backups",
    [string[]]$ContainerNames = @('hermes', 'hermes-dashboard'),
    [switch]$NoStop
)

$ErrorActionPreference = 'Stop'

# Verify the named volume actually exists. Used to be a Test-Path on a
# bind-mount path, which has been wrong since the named-volume migration —
# the script silently tar'd an empty directory and reported success.
$volExists = docker volume ls --filter "name=^$VolumeName`$" --format '{{.Name}}' 2>$null
if (($volExists -join '').Trim() -ne $VolumeName) {
    throw "Named volume '$VolumeName' not found. Has the migration run? See scripts/migrate-to-named-volume.ps1."
}

# Resolve $OutDir to an absolute path: `docker -v` rejects relative paths,
# and creates a literal-named volume if the source doesn't look like a path.
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$OutDirAbs = (Resolve-Path $OutDir).Path

$ts      = Get-Date -Format 'yyyyMMdd-HHmmss'
$outName = "hermes-$ts.tar.gz"
$outFile = Join-Path $OutDirAbs $outName

# Stop the containers for a quiescent snapshot. Hermes' gateway flushes
# pending state on SIGTERM, so 10s of `docker stop` covers the typical
# in-flight OAuth rotation case.
if (-not $NoStop) {
    Write-Host "Stopping containers ($($ContainerNames -join ', ')) for consistent snapshot..." -ForegroundColor Cyan
    docker stop @ContainerNames 2>$null | Out-Null
}

try {
    Write-Host "Archiving volume '$VolumeName' -> $outFile" -ForegroundColor Cyan
    # `cd /data && tar czf /out/<name> .` produces an archive whose entries
    # are relative to the volume root (`./auth.json`, `./skills/`, etc.).
    # Restore extracts back into /data with no surprise prefix.
    docker run --rm `
        -v "${VolumeName}:/data:ro" `
        -v "${OutDirAbs}:/out" `
        alpine sh -c "cd /data && tar czf /out/$outName ." 2>&1 | Out-Host
    if ($LASTEXITCODE -ne 0) {
        if (Test-Path $outFile) { Remove-Item $outFile -Force -ErrorAction SilentlyContinue }
        throw "docker tar pipeline failed (exit $LASTEXITCODE)"
    }

    if (-not (Test-Path $outFile)) {
        throw "Backup file not produced at $outFile (alpine container exited 0 but no output)"
    }
    $sizeMB = [Math]::Round((Get-Item $outFile).Length / 1MB, 2)
    Write-Host "OK: $sizeMB MB written to $outFile" -ForegroundColor Green
} finally {
    if (-not $NoStop) {
        Write-Host "Restarting containers..." -ForegroundColor Cyan
        docker start @ContainerNames 2>$null | Out-Null
    }
}
