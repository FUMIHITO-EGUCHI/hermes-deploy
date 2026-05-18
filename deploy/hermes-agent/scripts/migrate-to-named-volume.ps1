# migrate-to-named-volume.ps1 — One-shot migration of the legacy bind-mount
# layout (${USERPROFILE}/.hermes:/opt/data) to the new named-volume layout
# (hermes-data:/opt/data).
#
# Run once per host. Idempotent: re-running after a successful migration
# detects the volume already populated and exits with a no-op message.
#
# What it does:
#   1. Verify the legacy bind-mount path exists and contains data.
#   2. `docker compose stop` the existing containers (so nothing writes
#      while we copy).
#   3. Create the `hermes-data` named volume.
#   4. Copy every file under ${USERPROFILE}/.hermes/ into the volume,
#      preserving ownership as hermes:hermes (uid 10000).
#   5. Print next-step guidance: re-up with the new compose, then push
#      auth.json to BW so the next-host migration story is complete.
#
# What it does NOT do:
#   - Modify or delete the original bind-mount directory. It stays as a
#     safety backup until you manually decide to remove it. (You can keep
#     it indefinitely as an offline tar source, or `Remove-Item -Recurse`
#     once you've verified everything works.)
#   - Update the compose file. That file is already updated in the repo
#     to reference the named volume; you just need to copy it into your
#     live $HermesDir.
#   - Run `compose up`. That's left to start-hermes.ps1 so the BW key
#     injection flow runs.

[CmdletBinding()]
param(
    [string]$LegacyDataDir = "$env:USERPROFILE\.hermes",
    [string]$VolumeName    = "hermes-data",
    [string]$HermesDir     = "$env:USERPROFILE\hermes-agent",
    [string]$ComposeFile   = "docker-compose.windows.yml"
)

$ErrorActionPreference = 'Stop'

function Test-VolumeReadyToReceive {
    # Two checks: volume doesn't exist yet, OR exists but lacks the
    # completion marker we drop at the end of a successful migration.
    # The marker (not directory-emptiness) is the source of truth so a
    # partially-copied volume isn't mistaken for a finished one.
    $existing = docker volume ls --filter "name=^$VolumeName`$" --format "{{.Name}}" 2>$null
    if ($existing -ne $VolumeName) { return $true }

    # Volume exists — check for completion marker. `2>$null` would mask
    # docker errors, so we keep stderr visible and only suppress the
    # `cat` ENOENT case via `test -f` first.
    $marker = docker run --rm -v "${VolumeName}:/data:ro" alpine sh -c "test -f /data/.migration-complete && echo done || echo pending"
    if ($LASTEXITCODE -ne 0) {
        throw "Could not inspect volume '$VolumeName' (docker run failed). Is Docker Desktop running?"
    }
    $state = ($marker -join '').Trim()
    return ($state -eq 'pending')
}

# -----------------------------------------------------------------------------
# 1. Sanity checks
# -----------------------------------------------------------------------------
if (-not (Test-Path $LegacyDataDir)) {
    throw "Legacy bind-mount dir '$LegacyDataDir' not found. Nothing to migrate."
}
$legacyAuth = Join-Path $LegacyDataDir 'auth.json'
if (-not (Test-Path $legacyAuth)) {
    Write-Warning "$legacyAuth missing — migrating other state but you'll need to log in again."
}

if (-not (Test-VolumeReadyToReceive)) {
    Write-Host "Volume '$VolumeName' already migrated (marker present)." -ForegroundColor Green
    Write-Host "To redo the migration, delete the volume first:"          -ForegroundColor Yellow
    Write-Host "  docker compose -f $HermesDir\$ComposeFile down"          -ForegroundColor Yellow
    Write-Host "  docker volume rm $VolumeName"                            -ForegroundColor Yellow
    Write-Host "  pwsh $PSScriptRoot\migrate-to-named-volume.ps1"          -ForegroundColor Yellow
    return
}

# -----------------------------------------------------------------------------
# 2. Stop containers if running (avoid mid-copy writes)
# -----------------------------------------------------------------------------
if (Test-Path "$HermesDir\$ComposeFile") {
    Write-Host "Stopping existing containers (graceful)..." -ForegroundColor Cyan
    Push-Location $HermesDir
    try {
        # `down` so the bind-mount is fully released. `stop` alone would
        # keep the container around with the old mount config; recreating
        # with new mounts then needs `--force-recreate` anyway.
        & docker compose -f $ComposeFile down 2>&1 | Out-String | Write-Host
    } finally { Pop-Location }
} else {
    Write-Host "No compose file at $HermesDir\$ComposeFile — assuming no live containers." -ForegroundColor Yellow
}

# -----------------------------------------------------------------------------
# 3. Create the named volume
# -----------------------------------------------------------------------------
Write-Host "Creating named volume '$VolumeName'..." -ForegroundColor Cyan
docker volume create $VolumeName | Out-Null

# -----------------------------------------------------------------------------
# 4. Copy data in via a staging directory, then atomic-move to the live
#    layout, then drop a completion marker.
#
#    The two-stage approach (staging then move) means an interrupted copy
#    leaves /dest/ without the marker, so Test-VolumeReadyToReceive on
#    the next run still returns "ready" rather than mistaking a partial
#    copy for a finished one.
#
#    Sensitive-file chmod is done IN THE STAGING DIR with explicit checks,
#    so a chmod failure on auth.json is a hard error rather than getting
#    swallowed by a trailing `|| true`.
# -----------------------------------------------------------------------------
Write-Host "Copying $LegacyDataDir → volume '$VolumeName' (staged)..." -ForegroundColor Cyan
$legacyFwd = $LegacyDataDir -replace '\\', '/'
docker run --rm `
    -v "${legacyFwd}:/source:ro" `
    -v "${VolumeName}:/dest" `
    alpine sh -c '
        set -e
        rm -rf /dest/.staging
        mkdir -p /dest/.staging
        cp -a /source/. /dest/.staging/
        chown -R 10000:10000 /dest/.staging
        # Tighten perms on known-sensitive files only if they exist;
        # missing files are OK (fresh installs lack .claude/.credentials.json),
        # but a present-and-chmod-failed case must surface.
        if [ -f /dest/.staging/auth.json ]; then
            chmod 600 /dest/.staging/auth.json
        fi
        if [ -f /dest/.staging/.claude/.credentials.json ]; then
            chmod 600 /dest/.staging/.credentials.json 2>/dev/null || \
            chmod 600 /dest/.staging/.claude/.credentials.json
        fi
        # Atomic-ish promotion: move everything out of staging into /dest.
        # We move each entry separately because /dest is the volume root
        # itself and cant be replaced as a whole.
        cd /dest/.staging && find . -mindepth 1 -maxdepth 1 -exec mv {} /dest/ \;
        rmdir /dest/.staging
        touch /dest/.migration-complete
        chown 10000:10000 /dest/.migration-complete
    '
if ($LASTEXITCODE -ne 0) { throw "Migration copy failed (exit $LASTEXITCODE). Volume left with .staging/ dir for inspection; re-running will retry cleanly." }

# Verify: file count, auth.json size, ownership.
Write-Host ""
Write-Host "Verification:" -ForegroundColor Cyan
docker run --rm -v "${VolumeName}:/data:ro" alpine sh -c "
  echo 'top-level entries:'
  ls -la /data | head -20
  echo ''
  echo 'auth.json:'
  stat -c '  size=%s owner=%U:%G mode=%a' /data/auth.json 2>/dev/null || echo '  (missing)'
"

Write-Host ""
Write-Host "Migration done." -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. Copy the updated compose into your live HermesDir:"
Write-Host "       Copy-Item '$PSScriptRoot\..\docker-compose.windows.yml' '$HermesDir\'"
Write-Host "  2. Boot Hermes via the BW-aware launcher:"
Write-Host "       pwsh $PSScriptRoot\start-hermes.ps1"
Write-Host "  3. Push the volume's auth.json to BW so the next-host story works:"
Write-Host "       pwsh $PSScriptRoot\hermes-restore.ps1 -Push"
Write-Host "  4. (Optional, only after you've verified Hermes is healthy with"
Write-Host "      the new layout) remove the legacy bind-mount data:"
Write-Host "       Remove-Item -Recurse -Force '$LegacyDataDir'"
