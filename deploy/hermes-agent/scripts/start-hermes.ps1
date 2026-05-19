# start-hermes.ps1 — Boot the Hermes container with API keys fetched from
# Bitwarden via the shared session helper.
#
# Responsibility split (Phase-3 redesign):
#   - This script ONLY fetches per-boot env-injected keys (DEEPSEEK_API_KEY
#     etc.). The OAuth refresh credentials in auth.json live on the
#     `hermes-data` named volume and persist across container restarts —
#     they are NOT touched here.
#   - First-time install / disaster recovery seeds the named volume from
#     Bitwarden via scripts/hermes-restore.ps1.
#   - Graceful shutdown + final BW push goes through scripts/stop-hermes.ps1.
#
# Bitwarden item layout (single consolidated item):
#   Name : "Hermes Auth State"  (overridable via -BwItem)
#   Type : Secure Note
#   Custom fields (all hidden type):
#     deepseek_api_key   : sk-...                    (this script reads)
#     auth_json_b64      : base64 of /opt/data/auth.json  (restore/sync read)
#
# Usage:
#   pwsh ./scripts/start-hermes.ps1
#   pwsh ./scripts/start-hermes.ps1 -Rebuild
#   pwsh ./scripts/start-hermes.ps1 -BwItem "My Custom Vault Entry"

[CmdletBinding()]
param(
    [string]$BwItem      = "Hermes Auth State",
    [string]$HermesDir   = "$env:USERPROFILE\hermes-agent",
    [string]$ComposeFile = "docker-compose.windows.yml",
    [switch]$Rebuild
)

$ErrorActionPreference = 'Stop'

# Constants — field names are pinned, not parametric. Changing them means
# also editing the BW vault item, so a parameter would just invite drift.
$BW_FIELD_DEEPSEEK = 'deepseek_api_key'

Import-Module "$PSScriptRoot\bw-session.psm1" -Force

# 1. Unlock vault (cache-hit silent / cache-miss prompts master password).
Write-Host "Checking Bitwarden vault..." -ForegroundColor Cyan
$session = Get-BwSession
$env:BW_SESSION = $session

# 2. Fetch the one key this script needs. Older runs of start-hermes used
#    to pull the entire item and dig out one field; with Get-BwField the
#    intent is explicit and the rest of the item stays in BW's memory.
Write-Host "Fetching '$BwItem' / '$BW_FIELD_DEEPSEEK'..." -ForegroundColor Cyan
$apiKey = Get-BwField -Item $BwItem -FieldName $BW_FIELD_DEEPSEEK
if (-not $apiKey) {
    throw "Field '$BW_FIELD_DEEPSEEK' missing or empty in BW item '$BwItem'."
}

$redacted = if ($apiKey.Length -gt 8) {
    # Only show last 4. The `sk-` prefix is a constant and the first 4
    # chars add no signal but increase shoulder-surfing surface area.
    "...$($apiKey.Substring($apiKey.Length-4))"
} else { "[redacted]" }
Write-Host "Loaded DEEPSEEK_API_KEY ($redacted, $($apiKey.Length) chars)" -ForegroundColor Green

# 3. Inject into env and launch. Compose forwards via `environment:` block.
$env:DEEPSEEK_API_KEY = $apiKey
try {
    Push-Location $HermesDir
    if (-not (Test-Path $ComposeFile)) {
        throw "Compose file not found: $HermesDir\$ComposeFile"
    }

    $composeArgs = @("compose", "-f", $ComposeFile, "up", "-d")
    if ($Rebuild) { $composeArgs += "--build" }

    Write-Host "Running: docker $($composeArgs -join ' ')" -ForegroundColor Cyan
    & docker @composeArgs
    if ($LASTEXITCODE -ne 0) { throw "docker compose up failed (exit $LASTEXITCODE)" }

    # 4. Sanity check: did the named volume get auth.json seeded? If not,
    #    Hermes will start with no OAuth providers configured — surface a
    #    clear hint pointing to hermes-restore.ps1 instead of letting the
    #    user wonder why anthropic/codex appear logged-out.
    $volProbe = docker run --rm -v hermes-data:/data alpine sh -c "test -s /data/auth.json && echo yes || echo no" 2>$null
    if ($volProbe.Trim() -ne 'yes') {
        Write-Warning "hermes-data volume has no auth.json — OAuth providers (Codex, Anthropic OAuth) will be offline."
        Write-Warning "Run scripts/hermes-restore.ps1 to seed the volume from the BW vault."
    }

    Write-Host "OK. Dashboard: http://127.0.0.1:9119" -ForegroundColor Green
    Write-Host "Logs:         docker compose -f $ComposeFile logs -f gateway"
    Write-Host "Shell in:     docker exec -it hermes /opt/hermes/.venv/bin/hermes"
    Write-Host "Stop cleanly: pwsh $PSScriptRoot\stop-hermes.ps1"
} finally {
    Pop-Location -ErrorAction SilentlyContinue
    # Container has its own env copy; scrub the host shell var so a later
    # `printenv` or screen-share doesn't leak it. `$env:X = $null` keeps
    # the variable present with empty value on PS 5.1 — use the .NET API
    # to actually remove it from the process env block.
    [Environment]::SetEnvironmentVariable('DEEPSEEK_API_KEY', $null, 'Process')
    # BW_SESSION も scrub: DPAPI キャッシュが次回起動の沈黙役を担うので、
    # シェル変数として残し続ける利得はほぼなく、`printenv`・Process
    # Explorer・子プロセスへの継承で覗かれる微小リスクのほうが大きい。
    # `$env:X = $null` は PS 5.1 だと空値で残ってしまうので .NET API で
    # プロセス環境ブロックから物理的に削除する。
    [Environment]::SetEnvironmentVariable('BW_SESSION', $null, 'Process')
}
