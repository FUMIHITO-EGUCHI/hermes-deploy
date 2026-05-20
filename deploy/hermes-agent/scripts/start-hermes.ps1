# start-hermes.ps1 — Boot the Hermes container with API keys fetched from
# Bitwarden via the bw serve backend.
#
# Why bw serve (not bw --session): bw CLI 2026.x で session env / --session
# が無視される #12270 バグを踏むため、subprocess + session 渡し経路は機能
# しない。bw serve をスクリプト lifecycle 内で start/stop し localhost REST API
# 経由で fetch する。
#
# Responsibility split:
#   - This script ONLY fetches per-boot env-injected keys (DEEPSEEK_API_KEY,
#     API_SERVER_KEY). The OAuth refresh credentials in auth.json live on the
#     `hermes-data` named volume and persist across container restarts —
#     they are NOT touched here.
#   - First-time install / disaster recovery seeds the named volume from
#     Bitwarden via scripts/hermes-restore.ps1.
#   - Graceful shutdown + final BW push goes through scripts/stop-hermes.ps1.
#
# Bitwarden layout (新 3-item 構造、scripts/provision-bw-vault.ps1 で構築):
#   Folder: Hermes
#     ├── Hermes / Provider Keys     (Secure Note)
#     │     field deepseek_api_key   ← この script が読む
#     ├── Hermes / Self-Hosted Auth  (Secure Note)
#     │     field api_server_key     ← この script が読む
#     └── Hermes / OAuth State       (Secure Note)
#           notes = raw auth.json    ← hermes-restore.ps1 が扱う
#
# Usage:
#   pwsh ./scripts/start-hermes.ps1
#   pwsh ./scripts/start-hermes.ps1 -Rebuild

[CmdletBinding()]
param(
    [string]$ProviderKeysItem    = 'Hermes / Provider Keys',
    [string]$SelfHostedAuthItem  = 'Hermes / Self-Hosted Auth',
    [string]$HermesDir           = "$env:USERPROFILE\hermes-agent",
    [string]$ComposeFile         = 'docker-compose.windows.yml',
    [int]   $BwServePort         = 8087,
    [switch]$Rebuild
)

$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\bw-session.psm1" -Force

# 1. bw serve を起動 + master pw で unlock
Write-Host "Starting bw serve backend..." -ForegroundColor Cyan
$bw = Start-BwServe -Port $BwServePort
try {
    # 2. 2 つの item からそれぞれ 1 field 取得
    Write-Host "Fetching '$ProviderKeysItem' / 'deepseek_api_key'..." -ForegroundColor Cyan
    $apiKey = Get-BwServeField -Session $bw -Item $ProviderKeysItem -FieldName 'deepseek_api_key'
    Write-Host "  Loaded DEEPSEEK_API_KEY (length: $($apiKey.Length))" -ForegroundColor Green

    Write-Host "Fetching '$SelfHostedAuthItem' / 'api_server_key'..." -ForegroundColor Cyan
    $apiServerKey = Get-BwServeField -Session $bw -Item $SelfHostedAuthItem -FieldName 'api_server_key'
    Write-Host "  Loaded API_SERVER_KEY (length: $($apiServerKey.Length))" -ForegroundColor Green
} finally {
    # 取得済みなので serve は不要。stop は finally で常に走らせる。
    Stop-BwServe -Session $bw
}

# 3. Inject into env and launch. Compose forwards via `environment:` block.
$env:DEEPSEEK_API_KEY = $apiKey
$env:API_SERVER_KEY   = $apiServerKey
try {
    Push-Location $HermesDir
    if (-not (Test-Path $ComposeFile)) {
        throw "Compose file not found: $HermesDir\$ComposeFile"
    }

    $composeArgs = @('compose', '-f', $ComposeFile, 'up', '-d')
    if ($Rebuild) { $composeArgs += '--build' }

    Write-Host "Running: docker $($composeArgs -join ' ')" -ForegroundColor Cyan
    & docker @composeArgs
    if ($LASTEXITCODE -ne 0) { throw "docker compose up failed (exit $LASTEXITCODE)" }

    # 4. Sanity check: did the volume / bind-mount have auth.json seeded?
    $volProbe = docker exec hermes sh -c "test -s /opt/data/auth.json && echo yes || echo no" 2>$null
    if ($volProbe.Trim() -ne 'yes') {
        Write-Warning "container has no auth.json — OAuth providers (Codex, Anthropic OAuth) will be offline."
        Write-Warning "Run scripts/hermes-restore.ps1 to seed it from the BW vault."
    }

    Write-Host "OK." -ForegroundColor Green
    Write-Host "Dashboard:   http://127.0.0.1:9119"
    Write-Host "API server:  http://127.0.0.1:8642/v1   (bearer: <api_server_key from BW>)"
    Write-Host "Logs:        docker compose -f $ComposeFile logs -f gateway"
    Write-Host "Shell in:    docker exec -it hermes /opt/hermes/.venv/bin/hermes"
    Write-Host "Stop:        pwsh $PSScriptRoot\stop-hermes.ps1"
} finally {
    Pop-Location -ErrorAction SilentlyContinue
}
