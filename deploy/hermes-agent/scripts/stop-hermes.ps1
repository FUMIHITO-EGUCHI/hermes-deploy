# stop-hermes.ps1 — Graceful Hermes shutdown with a final auth.json sync
# back to the Bitwarden vault.
#
# Why "graceful":
#   The Hermes daemon rotates OAuth refresh tokens periodically (Codex
#   especially — its access token TTL is short). Each rotation writes the
#   new refresh token to /opt/data/auth.json inside the named volume. If
#   we kill the container without giving it time to flush, AND without
#   running the sync daemon (Phase 6, optional), the volume copy can be
#   ahead of the BW vault copy. That's tolerable for a single host (the
#   volume still has the truth), but on next-host migration BW would
#   serve a stale auth.json and Hermes would refresh-fail.
#
#   This script does the simple, robust thing: stop the container with
#   `docker compose stop` (graceful, no SIGKILL), then push the now-quiet
#   auth.json to BW. By the time `stop` returns, no further rotations
#   can occur — the snapshot we push is the authoritative final state.
#
# Default behavior:
#   - `compose stop` (containers keep their state; restart resumes fast)
#   - push auth.json to BW
#   - DO NOT `bw lock` (the user may have other terminals that depend on
#     the session). Use -LockVault if you want the master pw re-prompted
#     on next BW access.
#   - DO NOT `compose down` (preserves networks; same restart-fast logic)
#
# Pair with `-Down` if you really want to remove the containers; or use
# `start-hermes.ps1` to bring them back up. The named volume persists in
# all cases — only `docker volume rm hermes-data` will erase it.

[CmdletBinding()]
param(
    [string]$HermesDir         = "$env:USERPROFILE\hermes-agent",
    [string]$ComposeFile       = "docker-compose.windows.yml",
    [string]$ContainerName     = "hermes",
    [switch]$SkipPush,         # skip the BW push (e.g. BW offline, will sync later)
    [switch]$Down,             # full `compose down` instead of `compose stop`
    [switch]$LockVault,        # also clear the DPAPI session cache + bw lock
    [switch]$IgnorePushFailure # treat a failed BW push as a warning, not a hard error
)

$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\bw-session.psm1" -Force

Push-Location $HermesDir
try {
    if (-not (Test-Path $ComposeFile)) {
        throw "Compose file not found: $HermesDir\$ComposeFile"
    }

    # 1. Graceful stop. `compose stop` sends SIGTERM, waits for the default
    #    10s grace period, then SIGKILL only if needed. Hermes' gateway
    #    flushes pending rotations on SIGTERM.
    $action = if ($Down) { 'down' } else { 'stop' }
    Write-Host "Running: docker compose -f $ComposeFile $action" -ForegroundColor Cyan
    & docker compose -f $ComposeFile $action
    if ($LASTEXITCODE -ne 0) { throw "docker compose $action failed (exit $LASTEXITCODE)" }
} finally {
    Pop-Location -ErrorAction SilentlyContinue
}

# 2. Push the final auth.json snapshot to BW unless explicitly skipped.
$pushFailed = $false
if ($SkipPush) {
    Write-Host "Skipping BW push (per -SkipPush)." -ForegroundColor Yellow
} else {
    Write-Host "Pushing final auth.json to BW..." -ForegroundColor Cyan
    # Delegate to hermes-restore -Push; that script throws on failure
    # (and $ErrorActionPreference=Stop propagates that as a terminating
    # error). Wrap in try/catch so we can convert to a warning when the
    # caller passes -IgnorePushFailure, OR re-raise / non-zero exit
    # otherwise — silent push failure on stop is a data-loss footgun
    # for the next-host migration story.
    try {
        & "$PSScriptRoot\hermes-restore.ps1" -Push -Force -ContainerName $ContainerName
        if ($LASTEXITCODE -ne 0) { throw "hermes-restore.ps1 -Push returned exit $LASTEXITCODE" }
    } catch {
        $pushFailed = $true
        $msg = "BW push failed: $_. Volume still holds latest auth.json — next start-hermes will work, but a freshly-cloned host won't see the rotated credentials until you re-run hermes-restore.ps1 -Push."
        if ($IgnorePushFailure) {
            Write-Warning $msg
        } else {
            Write-Error $msg
            exit 2
        }
    }
}

# 3. Optionally lock the vault. By default we leave the DPAPI cache in
#    place so other terminals/scripts keep working without re-prompting.
if ($LockVault) {
    Write-Host "Clearing DPAPI session cache and locking the BW vault." -ForegroundColor Cyan
    Clear-BwSession
}

Write-Host "Done." -ForegroundColor Green
