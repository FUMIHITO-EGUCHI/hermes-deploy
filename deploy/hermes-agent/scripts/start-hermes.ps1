# start-hermes.ps1 — Bitwarden-piped Hermes Agent launcher.
#
# Flow:
#   1. Ensure Bitwarden CLI vault is unlocked (prompt if needed).
#   2. Pull DEEPSEEK_API_KEY out of the vault item (no plaintext file written).
#   3. Inject as process env var; docker compose passes it into the container.
#   4. Clear the host env var on this shell when done.
#
# Usage:
#   pwsh ./scripts/start-hermes.ps1                              # default item "DeepSeek API Key"
#   pwsh ./scripts/start-hermes.ps1 -Item "MyVaultEntry"
#   pwsh ./scripts/start-hermes.ps1 -HermesDir D:\hermes-agent
#
# Prereqs:
#   - Node.js on PATH (npx ships with it).
#   - Bitwarden CLI used via `npx -y @bitwarden/cli` (no global install needed).
#   - `bw login` once: `npx -y @bitwarden/cli login`
#
# Security:
#   - The key never lands on disk in this repo. compose receives it from the
#     parent process env, then forwards it into the container via the
#     `environment:` block in docker-compose.windows.yml.
#   - The container DOES retain the env var in its process env (visible to
#     `docker inspect`). That's a Docker limit, not a script limit.

[CmdletBinding()]
param(
    [string]$Item       = "DeepSeek API Key",
    [string]$FieldName  = "DEEPSEEK_API_KEY",
    [string]$HermesDir  = "$env:USERPROFILE\hermes-agent",
    [string]$ComposeFile = "docker-compose.windows.yml",
    [switch]$Rebuild
)

$ErrorActionPreference = 'Stop'
$Bw = @("npx", "-y", "@bitwarden/cli")

function Invoke-Bw {
    param([string[]]$BwArgs)
    & $Bw[0] $Bw[1..($Bw.Length - 1)] @BwArgs 2>$null
}

# 1. Unlock vault if needed
Write-Host "Checking Bitwarden vault status..." -ForegroundColor Cyan
$statusJson = Invoke-Bw @("status")
if (-not $statusJson) { Write-Error "bw status failed — is Node.js installed and `bw login` done?"; exit 1 }
$status = $statusJson | ConvertFrom-Json

if ($status.status -ne "unlocked") {
    if ($status.status -eq "unauthenticated") {
        Write-Error "Bitwarden not logged in. Run: npx -y @bitwarden/cli login"
        exit 1
    }
    Write-Host "Vault is $($status.status). Unlocking (enter master password)..." -ForegroundColor Yellow
    $session = & $Bw[0] $Bw[1..($Bw.Length - 1)] unlock --raw
    if (-not $session) { Write-Error "Unlock failed."; exit 1 }
    $env:BW_SESSION = $session
}

# 1b. Sync vault — items created on the web are invisible to the CLI until
#     `bw sync` runs. Cheap (~1s) so always do it.
Write-Host "Syncing vault..." -ForegroundColor Cyan
& $Bw[0] $Bw[1..($Bw.Length - 1)] sync --session $env:BW_SESSION 2>&1 | Out-Null

# 2. Fetch key from vault
Write-Host "Fetching '$Item' / field '$FieldName'..." -ForegroundColor Cyan
$itemJson = & $Bw[0] $Bw[1..($Bw.Length - 1)] get item $Item --session $env:BW_SESSION
if (-not $itemJson) { Write-Error "Vault item '$Item' not found."; exit 1 }
$itemObj = $itemJson | ConvertFrom-Json

$apiKey = $null
$field = $itemObj.fields | Where-Object { $_.name -eq $FieldName } | Select-Object -First 1
if ($field) {
    $apiKey = $field.value
} elseif ($itemObj.login.password -like 'sk-*') {
    $apiKey = $itemObj.login.password
}

if (-not $apiKey) {
    Write-Error "Could not extract API key. Tried field '$FieldName' then login.password (sk-* prefix)."
    exit 1
}

$redacted = if ($apiKey.Length -gt 10) { "$($apiKey.Substring(0,4))...$($apiKey.Substring($apiKey.Length-4))" } else { "[redacted]" }
Write-Host "Loaded DEEPSEEK_API_KEY ($redacted)" -ForegroundColor Green

# 3. Inject and launch
$env:DEEPSEEK_API_KEY = $apiKey
try {
    Push-Location $HermesDir
    if (-not (Test-Path $ComposeFile)) {
        Write-Error "Compose file not found: $HermesDir\$ComposeFile"
        exit 1
    }

    $args = @("compose", "-f", $ComposeFile, "up", "-d")
    if ($Rebuild) { $args += "--build" }

    Write-Host "Running: docker $($args -join ' ')" -ForegroundColor Cyan
    & docker @args
    $exit = $LASTEXITCODE

    if ($exit -ne 0) { Write-Error "docker compose up failed (exit $exit)"; exit $exit }

    Write-Host "OK. Dashboard: http://127.0.0.1:9119" -ForegroundColor Green
    Write-Host "Logs:         docker compose -f $ComposeFile logs -f gateway"
    Write-Host "Shell in:     docker exec -it hermes hermes"
} finally {
    Pop-Location -ErrorAction SilentlyContinue
    # 4. Scrub the host env var; the container already has its own copy.
    $env:DEEPSEEK_API_KEY = $null
    # BW_SESSION intentionally kept in this shell so subsequent script runs
    # don't re-prompt. Close the shell or run `bw lock` to invalidate.
}
