# setup-providers.ps1 — One-shot OAuth login for Hermes Agent subscription providers.
#
# What this does:
#   1. Opens the OpenAI Codex (ChatGPT Plus/Pro) device-code flow inside the
#      Hermes container. You approve in a browser; the refresh token lands in
#      /opt/data/auth.json (= $env:USERPROFILE\.hermes\auth.json on the host).
#   2. Opens the Anthropic Claude Code (Pro/Max subscription) setup-token flow
#      inside the container. You approve in a browser; the refresh token lands
#      in /opt/data/.claude/.credentials.json.
#   3. Verifies both providers report `logged in` to `hermes auth status`.
#
# Why subscription-mode:
#   These flows use your existing ChatGPT / Claude.ai subscription quota
#   instead of per-token API billing. The Hermes daemon (running as uid 10000
#   inside the container) consumes the refresh tokens directly when it routes
#   to gpt-5-codex / claude-sonnet-4-x models. No API server / proxy required.
#
# Prerequisites:
#   - Hermes container (`hermes`) is up. Run start-hermes.ps1 first.
#   - You're logged into ChatGPT Plus/Pro in your default browser.
#   - You're logged into Claude.ai (Pro/Max) in your default browser.
#   - Both flows are interactive — this script uses `docker exec -it` and
#     therefore must be run from a real terminal, NOT a non-TTY context.
#
# Usage:
#   pwsh ./scripts/setup-providers.ps1                # both providers
#   pwsh ./scripts/setup-providers.ps1 -SkipCodex     # claude only
#   pwsh ./scripts/setup-providers.ps1 -SkipClaude    # codex only
#   pwsh ./scripts/setup-providers.ps1 -Status        # just report status, no auth
#
# Re-running is safe: existing valid credentials skip the flow.

[CmdletBinding()]
param(
    [string]$Container = "hermes",
    [switch]$SkipCodex,
    [switch]$SkipClaude,
    [switch]$Status,
    [switch]$Force,
    # Claude has two viable login paths:
    #   - interactive: run `claude auth login --claudeai` inside the container
    #     (needs browser + paste-back; produces a fresh refresh token).
    #   - import     : copy the existing host ~/.claude/.credentials.json into
    #     the Hermes data volume. Fastest when claude is already set up on
    #     the host, but the host's claude and Hermes will then race when
    #     their access tokens rotate (~30-day OAuth refresh).
    #   - auto       : import if a host credentials file exists, else
    #     fall back to interactive. This is the most ergonomic default.
    [ValidateSet('auto','interactive','import','setup-token')]
    [string]$ClaudeMode = 'auto',
    [string]$ClaudeHostFile = "$env:USERPROFILE\.claude\.credentials.json",
    # Named volume that holds /opt/data inside the container. Must match
    # the `volumes:` entry in docker-compose.windows.yml.
    [string]$VolumeName = "hermes-data"
)

$ErrorActionPreference = 'Stop'

function Test-Container {
    $running = docker ps --filter "name=^$Container$" --format "{{.Names}}" 2>$null
    if ($running -ne $Container) {
        throw "Container '$Container' is not running. Run scripts/start-hermes.ps1 first."
    }
}

function Ensure-Ownership {
    # Files created via `docker exec` (default user = root) inside /opt/data
    # become root-owned, which makes them unreadable to the daemon running as
    # uid 10000 (hermes). Defensively re-chown before any auth operation.
    docker exec $Container chown -R hermes:hermes /opt/data 2>$null | Out-Null
}

function Ensure-ClaudeCli {
    $present = docker exec $Container sh -c "command -v claude >/dev/null && echo yes || echo no" 2>$null
    if ($present.Trim() -eq 'yes') { return }
    Write-Host "Installing @anthropic-ai/claude-code in container (one-time)..." -ForegroundColor Cyan
    docker exec $Container npm install -g '@anthropic-ai/claude-code' 2>&1 | Select-Object -Last 3
    if ($LASTEXITCODE -ne 0) { throw "npm install failed (exit $LASTEXITCODE)" }
}

function Test-Tty {
    # docker exec -it requires a TTY. PowerShell over PSRemoting / scheduled
    # task contexts will not have one; fail early with a useful message.
    if (-not [Environment]::UserInteractive) {
        throw "This script needs an interactive terminal (TTY). Run it from a PowerShell window directly."
    }
}

function Get-CodexStatus {
    $out = docker exec $Container /opt/hermes/.venv/bin/hermes auth status openai-codex 2>&1
    return [PSCustomObject]@{
        LoggedIn = ($out -join "`n") -match 'logged in'
        Raw      = ($out -join "`n").Trim()
    }
}

function Get-ClaudeStatus {
    # Three independent signals; any one suffices for Hermes to route via
    # the Claude subscription, because the anthropic adapter resolves a
    # token from this chain at request time:
    #   1. `claude auth status` (the bundled claude CLI's own view).
    #   2. /opt/data/.claude/.credentials.json (the file the adapter reads).
    #   3. Hermes' pooled credentials for the `anthropic` provider — this
    #      is where `hermes auth add anthropic --type api-key` (used by the
    #      `setup-token` mode below) stores the sk-ant-oat01-* token.
    $cliJson = docker exec -u hermes $Container claude auth status --json 2>$null
    if (-not $cliJson) { $cliJson = docker exec -u hermes $Container claude auth status 2>$null }
    $cliLoggedIn = $false
    try {
        $obj = $cliJson | ConvertFrom-Json -ErrorAction Stop
        $cliLoggedIn = [bool]$obj.loggedIn
    } catch { $cliLoggedIn = (($cliJson -join "`n") -match '"loggedIn"\s*:\s*true') }

    docker exec -u hermes $Container test -s /opt/data/.claude/.credentials.json 2>$null | Out-Null
    $fileExists = ($LASTEXITCODE -eq 0)

    $poolOut = docker exec $Container /opt/hermes/.venv/bin/hermes auth list 2>$null
    $poolHas = (($poolOut -join "`n") -match '(?m)^anthropic ')

    return [PSCustomObject]@{
        LoggedIn      = ($cliLoggedIn -or $fileExists -or $poolHas)
        CliLoggedIn   = $cliLoggedIn
        FileExists    = $fileExists
        PoolHasEntry  = $poolHas
        Path          = '/opt/data/.claude/.credentials.json'
    }
}

function Invoke-CodexLogin {
    $st = Get-CodexStatus
    if ($st.LoggedIn -and -not $Force) {
        Write-Host "[codex]  already logged in — skipping (use -Force to redo)" -ForegroundColor Green
        return
    }
    Write-Host ""
    Write-Host "=== OpenAI Codex (ChatGPT Plus/Pro) login ===" -ForegroundColor Cyan
    Write-Host "A device code will be printed below. Open the URL, paste the code,"
    Write-Host "and approve with your ChatGPT account. Hermes will pick up the token"
    Write-Host "automatically when the flow completes."
    Write-Host ""
    # --no-browser: the container can't open a browser on the host anyway.
    # --timeout 900: 15 minutes is plenty for the user to walk through the flow.
    # -u hermes: write the refresh token to /opt/data/auth.json with the right
    #   ownership so the daemon (uid 10000) can read and rotate it.
    docker exec -it -u hermes $Container /opt/hermes/.venv/bin/hermes auth add openai-codex --type oauth --no-browser --timeout 900
    if ($LASTEXITCODE -ne 0) { throw "Codex login failed (exit $LASTEXITCODE)" }
}

function Import-ClaudeFromHost {
    if (-not (Test-Path $ClaudeHostFile)) {
        Write-Warning "Host credentials file not found: $ClaudeHostFile"
        return $false
    }

    # Stream the host's credentials file into the named volume via stdin
    # to a throwaway alpine. Avoids leaving a host bind-mount path
    # exposed (the old layout) or materializing extra plaintext copies on
    # disk (the old `Copy-Item` then in-container chown pattern).
    $bytes = [IO.File]::ReadAllBytes($ClaudeHostFile)
    $b64   = [Convert]::ToBase64String($bytes)

    docker volume create $VolumeName 2>$null | Out-Null
    $b64 | docker run --rm -i `
        -v "${VolumeName}:/data" `
        alpine sh -c "
            mkdir -p /data/.claude &&
            base64 -d > /data/.claude/.credentials.json &&
            chown -R 10000:10000 /data/.claude &&
            chmod 600 /data/.claude/.credentials.json
        "
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Failed to write credentials into volume '$VolumeName' (exit $LASTEXITCODE)"
        return $false
    }

    Write-Host "[claude] imported $ClaudeHostFile → ${VolumeName}:/data/.claude/.credentials.json" -ForegroundColor Green
    Write-Host "         Note: host's claude CLI and Hermes now share the same OAuth refresh token." -ForegroundColor DarkYellow
    Write-Host "         When either rotates (~30-day cadence), re-run with -ClaudeMode import to resync." -ForegroundColor DarkYellow
    return $true
}

function Invoke-ClaudeLogin {
    $st = Get-ClaudeStatus
    if ($st.LoggedIn -and -not $Force) {
        Write-Host "[claude] credentials already present at $($st.Path) — skipping (use -Force to redo)" -ForegroundColor Green
        return
    }

    # Mode selection. `auto` prefers import (no interactive flow needed)
    # whenever the host has a usable credentials file.
    $mode = $ClaudeMode
    if ($mode -eq 'auto') {
        if (Test-Path $ClaudeHostFile) { $mode = 'import' } else { $mode = 'interactive' }
    }

    if ($mode -eq 'import') {
        $ok = Import-ClaudeFromHost
        if ($ok) { return }
        Write-Warning "Falling back to interactive login because import failed."
    }

    if ($mode -eq 'setup-token') {
        Write-Host ""
        Write-Host "=== Register existing setup-token (sk-ant-oat01-...) ===" -ForegroundColor Cyan
        Write-Host "Paste your token at the prompt below. Hermes detects the sk-ant-oat*"
        Write-Host "prefix automatically and routes via Bearer + Claude Code beta header,"
        Write-Host "i.e. it bills against your Claude subscription, not the API quota."
        Write-Host ""
        docker exec -it -u hermes $Container /opt/hermes/.venv/bin/hermes auth add anthropic --type api-key
        if ($LASTEXITCODE -ne 0) { throw "hermes auth add anthropic failed (exit $LASTEXITCODE)" }
        return
    }

    Write-Host ""
    Write-Host "=== Anthropic Claude Code (Pro/Max subscription) login ===" -ForegroundColor Cyan
    Write-Host "A URL will print. Open it in your browser, log in with your"
    Write-Host "Claude.ai (Pro/Max) account, then paste the verification code"
    Write-Host "back into the prompt below."
    Write-Host ""
    # Run as the hermes user (uid 10000) so HOME=/opt/data and the credentials
    # file lands on the persistent volume with the right ownership for the
    # Hermes daemon to read.
    #
    # `claude auth login --claudeai` is the current idiomatic flow for the
    # Claude.ai subscription. `setup-token` is a legacy path that the CLI
    # 2.1.x still ships but the help text describes as long-lived tokens,
    # which is the wrong shape for Hermes' refresh-and-rotate loop.
    docker exec -it -u hermes $Container claude auth login --claudeai
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "claude auth login exited $LASTEXITCODE — trying legacy setup-token fallback"
        docker exec -it -u hermes $Container claude setup-token
        if ($LASTEXITCODE -ne 0) { throw "claude login failed via both auth login and setup-token" }
    }

    # Post-login: verify Hermes can actually see the credentials. Newer
    # claude CLI versions experimented with libsecret-only storage on Linux;
    # if the JSON file isn't where Hermes expects, surface that loudly.
    $post = Get-ClaudeStatus
    if ($post.CliLoggedIn -and -not $post.FileExists) {
        Write-Warning "claude CLI reports logged in but $($post.Path) is missing."
        Write-Warning "Hermes' anthropic adapter reads that file directly — it won't see this credential."
        Write-Host "Locations searched on disk:" -ForegroundColor Yellow
        docker exec -u hermes $Container sh -c "find /opt/data -maxdepth 3 -name '*credentials*' -o -name '.claude.json' 2>/dev/null"
    }
}

function Show-Status {
    Write-Host ""
    Write-Host "=== Provider status ===" -ForegroundColor Cyan
    $codex  = Get-CodexStatus
    $claude = Get-ClaudeStatus
    $codexMark  = if ($codex.LoggedIn)  { 'OK ' } else { 'NO ' }
    $claudeMark = if ($claude.LoggedIn) { 'OK ' } else { 'NO ' }
    $codexColor  = if ($codex.LoggedIn)  { 'Green' } else { 'Yellow' }
    $claudeColor = if ($claude.LoggedIn) { 'Green' } else { 'Yellow' }
    Write-Host "  [$codexMark] openai-codex  $($codex.Raw)" -ForegroundColor $codexColor
    $claudeDetail = "cli=$($claude.CliLoggedIn) file=$($claude.FileExists) pool=$($claude.PoolHasEntry)"
    Write-Host "  [$claudeMark] anthropic     $claudeDetail" -ForegroundColor $claudeColor
    Write-Host ""
    Write-Host "Dashboard: http://127.0.0.1:9119/env (Provider Logins (OAuth) section)"
    Write-Host "Pick default model:  docker exec -it $Container /opt/hermes/.venv/bin/hermes model"
}

Test-Container
Ensure-Ownership
if ($Status) { Show-Status; return }
Test-Tty

if (-not $SkipCodex)  { Invoke-CodexLogin }
if (-not $SkipClaude) {
    Ensure-ClaudeCli
    Invoke-ClaudeLogin
}

Ensure-Ownership
Show-Status
