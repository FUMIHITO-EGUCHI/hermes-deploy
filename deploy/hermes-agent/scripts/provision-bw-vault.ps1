#Requires -Version 7.0
# provision-bw-vault.ps1 — Bitwarden vault に Hermes 用構造を作成。
#
# 構造:
#   Folder: Hermes
#     ├── Item: Hermes / Provider Keys (Secure Note)
#     │     field: deepseek_api_key   (既存 'DeepSeek API Key' item.login.password を自動 copy)
#     ├── Item: Hermes / Self-Hosted Auth (Secure Note)
#     │     field: api_server_key     (CSPRNG 32B -> 64-char lowercase hex)
#     └── Item: Hermes / OAuth State   (Secure Note)
#           notes: <auth.json raw JSON>  (base64 化せず raw 格納)
#
# Idempotent: 既存 item は New-SecureNote の existence check で skip される
# ため、再実行で上書きされることはない。
#
# 注意 — key 形式を作り直したい場合 (例: 旧 base64url の api_server_key を
# hex に揃えたい等):
#   1. BW vault GUI で対象 item を削除
#   2. このスクリプトを再実行 → 新形式で再生成
#   3. `pwsh start-hermes.ps1` で container を再起動 (新 key を inject)
# step 3 を踏まないと、container 内の旧 API_SERVER_KEY と vault 上の
# 新 key が乖離して bearer 認証が破綻する。
#
# secret 値はプロセス内のみ、ログには length しか出さない。
#
# 設計判断:
#   * bw CLI 2026.x で `--session` / `BW_SESSION` 経路が壊れている
#     (bitwarden/clients#12270)。bw serve の REST API を経由する。
#   * bw serve の起動・unlock・テアダウンは bw-session.psm1 の
#     Start-BwServe / Stop-BwServe / Invoke-BwServeApi / Get-BwServeItem を
#     使う (start-hermes.ps1 / hermes-restore.ps1 と同じヘルパ。重複削減)。
#   * `RandomNumberGenerator.Fill` は .NET 5+ 限定なので PS7 を必須化。
#     PS 5.1 では `MethodNotFoundException` になるのでヘッダの #Requires で
#     早期 fail させる。
#
# 実行 (TTY 必須):
#   pwsh -NoProfile -File scripts/provision-bw-vault.ps1

[CmdletBinding()]
param(
    [string]$SourceDeepSeekItem = 'DeepSeek API Key',
    [string]$FolderName         = 'Hermes',
    [string]$ProviderKeysItem   = 'Hermes / Provider Keys',
    [string]$SelfHostedAuthItem = 'Hermes / Self-Hosted Auth',
    [string]$OAuthStateItem     = 'Hermes / OAuth State',
    [string]$AuthJsonPath       = "$env:USERPROFILE\.hermes\auth.json",
    [int]   $ServePort          = 8087
)

$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\bw-session.psm1" -Force

# ----------------------------------------------------------------------------
# bw serve 起動 + master pw で unlock
# ----------------------------------------------------------------------------

Write-Host "Starting bw serve backend..." -ForegroundColor Cyan
$bw = Start-BwServe -Port $ServePort
try {
    # ------------------------------------------------------------------------
    # Step 1: Folder 'Hermes' (idempotent)
    # ------------------------------------------------------------------------
    Write-Host ""
    Write-Host "Step 1: Folder '$FolderName'" -ForegroundColor Cyan

    $folders = (Invoke-BwServeApi -Session $bw -Method GET -Path '/list/object/folders').data
    $existingFolder = $folders | Where-Object { $_.name -eq $FolderName }
    if ($existingFolder) {
        $folderId = $existingFolder.id
        Write-Host "  Folder exists (id: $folderId)" -ForegroundColor Yellow
    } else {
        $created  = Invoke-BwServeApi -Session $bw -Method POST -Path '/object/folder' -Body @{ name = $FolderName }
        $folderId = $created.id
        Write-Host "  Created folder (id: $folderId)" -ForegroundColor Green
    }

    # ------------------------------------------------------------------------
    # Step 2: 既存 'DeepSeek API Key' から API key 取得 (値はローカルのみ)
    # ------------------------------------------------------------------------
    Write-Host ""
    Write-Host "Step 2: Read source '$SourceDeepSeekItem'" -ForegroundColor Cyan
    $src = Get-BwServeItem -Session $bw -Name $SourceDeepSeekItem
    $deepseekValue = $src.login.password
    if (-not $deepseekValue) {
        throw "'$SourceDeepSeekItem' item に login.password が無い (type=$($src.type))"
    }
    Write-Host "  Loaded deepseek_api_key (length: $($deepseekValue.Length))" -ForegroundColor Green

    # ------------------------------------------------------------------------
    # Step 3: api_server_key を CSPRNG で生成
    # ------------------------------------------------------------------------
    Write-Host ""
    Write-Host "Step 3: Generate api_server_key" -ForegroundColor Cyan
    # 32 random bytes → 64-char lowercase hex. base64url substitution was
    # gratuitous: `Authorization: Bearer ...` permits +/= (RFC 6750).
    $rngBytes = [byte[]]::new(32)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($rngBytes)
    $apiServerKey = ([BitConverter]::ToString($rngBytes) -replace '-','').ToLower()
    Write-Host "  Generated api_server_key (length: $($apiServerKey.Length))" -ForegroundColor Green

    # ------------------------------------------------------------------------
    # Step 4: auth.json を raw text として読む (UTF-8)
    # ------------------------------------------------------------------------
    Write-Host ""
    Write-Host "Step 4: Read '$AuthJsonPath'" -ForegroundColor Cyan
    if (-not (Test-Path $AuthJsonPath)) {
        throw "auth.json not found at '$AuthJsonPath'"
    }
    $authText = [IO.File]::ReadAllText($AuthJsonPath, [Text.Encoding]::UTF8)
    Write-Host "  Read auth.json (chars: $($authText.Length))" -ForegroundColor Green

    # ------------------------------------------------------------------------
    # Step 5: Secure Note 3 個を Hermes フォルダ配下に作成 (idempotent)
    # ------------------------------------------------------------------------
    Write-Host ""
    Write-Host "Step 5: Create items under folder '$FolderName'" -ForegroundColor Cyan

    # existence check で使う全 item list は loop 外で 1 回だけ取得
    $allItems = (Invoke-BwServeApi -Session $bw -Method GET -Path '/list/object/items').data

    function New-SecureNote {
        param(
            [string]$Name,
            [hashtable[]]$Fields = @(),
            [string]$Notes       = $null
        )
        $existing = $allItems | Where-Object { $_.name -eq $Name } | Select-Object -First 1
        if ($existing) {
            Write-Host "  Item '$Name' already exists. Skip." -ForegroundColor Yellow
            return
        }
        $fieldObjs = @()
        if ($Fields.Count -gt 0) {
            $fieldObjs = $Fields | ForEach-Object {
                @{ name = $_.name; value = $_.value; type = 1; linkedId = $null }
            }
        }
        $payload = @{
            organizationId = $null
            folderId       = $folderId
            type           = 2                          # Secure Note
            name           = $Name
            notes          = $Notes
            favorite       = $false
            fields         = @($fieldObjs)
            secureNote     = @{ type = 0 }
        }
        Invoke-BwServeApi -Session $bw -Method POST -Path '/object/item' -Body $payload | Out-Null
        $detail = if ($Notes) { "notes-length: $($Notes.Length)" } else { "fields: $($Fields.Count)" }
        Write-Host "  Created item '$Name' ($detail)" -ForegroundColor Green
    }

    New-SecureNote -Name $ProviderKeysItem   -Fields @(@{ name='deepseek_api_key'; value=$deepseekValue })
    New-SecureNote -Name $SelfHostedAuthItem -Fields @(@{ name='api_server_key';   value=$apiServerKey })
    New-SecureNote -Name $OAuthStateItem     -Notes  $authText

    # scrub local secrets (GC 任せにせず明示)
    $deepseekValue = $null
    $apiServerKey  = $null
    $authText      = $null

    Write-Host ""
    Write-Host "Done. 次の手順:" -ForegroundColor Cyan
    Write-Host "  1. pwsh deploy/hermes-agent/scripts/start-hermes.ps1"
    Write-Host "  2. curl http://127.0.0.1:8642/v1/models -H 'Authorization: Bearer <api_server_key>'"
} finally {
    Stop-BwServe -Session $bw
}
