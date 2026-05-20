# provision-bw-vault.ps1 — Bitwarden vault に Hermes 用構造を作成。
#
# 構造:
#   Folder: Hermes
#     ├── Item: Hermes / Provider Keys (Secure Note)
#     │     field: deepseek_api_key   (既存 'DeepSeek API Key' item.login.password を自動 copy)
#     ├── Item: Hermes / Self-Hosted Auth (Secure Note)
#     │     field: api_server_key     (CSPRNG 32B -> base64url)
#     └── Item: Hermes / OAuth State   (Secure Note)
#           notes: <auth.json raw JSON>  (base64 化せず raw 格納)
#
# Idempotent。secret 値はプロセス内のみ、ログには length しか出さない。
#
# 設計判断 (履歴・調査の結論):
#   * `bw --session <key>` も `BW_SESSION` env も bw CLI 2026.4.1 で `Vault is
#     locked` を返す (bitwarden/clients#12270, #13696)。session を別プロセス
#     に渡す経路は壊れている。
#   * `bw serve` (localhost REST API) は単一プロセス内で unlock 状態を保持
#     するため #12270 を構造的に回避できる。
#   * serve は background job で立て、PowerShell から `Invoke-RestMethod` で叩く。
#   * 認証は POST /unlock { password } 経由、TTY での master pw 入力 1 回。
#     その後 serve は同一プロセス内で session を保持する。
#
# 実行 (TTY 必須 — Read-Host -AsSecureString が master pw を聞く):
#   pwsh -NoProfile -File .local/provision-bw-vault.ps1

[CmdletBinding()]
param(
    [string]$SourceDeepSeekItem = 'DeepSeek API Key',
    [string]$FolderName         = 'Hermes',
    [string]$ProviderKeysItem   = 'Hermes / Provider Keys',
    [string]$SelfHostedAuthItem = 'Hermes / Self-Hosted Auth',
    [string]$OAuthStateItem     = 'Hermes / OAuth State',
    [string]$AuthJsonPath       = "$env:USERPROFILE\.hermes\auth.json",
    [int]   $ServePort          = 8087,
    [int]   $StartupTimeoutSec  = 30
)

$ErrorActionPreference = 'Stop'

$Base = "http://localhost:$ServePort"

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

function Invoke-BwApi {
    # bw serve は `Response` ラッパーで `{ success, data, message }` を返す。
    # success=false の時はメッセージを含めて throw する。
    param(
        [Parameter(Mandatory)][ValidateSet('GET','POST','PUT','DELETE')][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [object]$Body
    )
    $params = @{
        Uri         = "$Base$Path"
        Method      = $Method
        ErrorAction = 'Stop'
    }
    if ($PSBoundParameters.ContainsKey('Body')) {
        $params['Body']        = ($Body | ConvertTo-Json -Depth 20 -Compress)
        $params['ContentType'] = 'application/json'
    }
    $res = Invoke-RestMethod @params
    if (-not $res.success) {
        throw "bw API $Method $Path failed: $($res.message)"
    }
    return $res.data
}

function Wait-ServeReady {
    param([int]$TimeoutSec)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        try {
            $r = Invoke-RestMethod -Uri "$Base/status" -Method Get -TimeoutSec 2 -ErrorAction Stop
            if ($r.success) { return }
        } catch {
            # connection refused / timeout は無視してリトライ
        }
        Start-Sleep -Milliseconds 500
    }
    throw "bw serve did not become ready within $TimeoutSec seconds"
}

# ----------------------------------------------------------------------------
# 1. bw serve を background job で起動
# ----------------------------------------------------------------------------

Write-Host "Starting 'bw serve --port $ServePort'..." -ForegroundColor Cyan

# 既存プロセスをチェック (ポート衝突回避)
try {
    $existing = Invoke-RestMethod -Uri "$Base/status" -Method Get -TimeoutSec 2 -ErrorAction Stop
    if ($existing.success) {
        throw "Port $ServePort is already serving a bw instance. Stop it first or pass -ServePort <other>."
    }
} catch {
    # 404 / connection refused は正常 (これから起動する)
}

$serveJob = Start-Job -ScriptBlock {
    param($Port)
    & bw serve --port $Port --hostname localhost
} -ArgumentList $ServePort

try {
    Wait-ServeReady -TimeoutSec $StartupTimeoutSec
    Write-Host "  bw serve ready on $Base" -ForegroundColor Green

    # ------------------------------------------------------------------------
    # 2. master pw で unlock (POST /unlock)
    # ------------------------------------------------------------------------
    Write-Host ""
    Write-Host "Unlocking vault via REST..." -ForegroundColor Cyan
    $securePw = Read-Host "Master password" -AsSecureString
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePw)
    try {
        $pwPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        Invoke-BwApi -Method POST -Path '/unlock' -Body @{ password = $pwPlain } | Out-Null
    } finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        $pwPlain = $null
        $securePw.Dispose()
    }
    Write-Host "  Vault unlocked" -ForegroundColor Green

    # sync して最新化
    Invoke-BwApi -Method POST -Path '/sync' | Out-Null

    # ------------------------------------------------------------------------
    # 3. Folder 'Hermes' 作成 (idempotent)
    # ------------------------------------------------------------------------
    Write-Host ""
    Write-Host "Step 1: Folder '$FolderName'" -ForegroundColor Cyan
    # bw serve の list レスポンスは入れ子: { success, data: { object: 'list', data: [...] } }
    # Invoke-BwApi が外側の .data を返すので、ここでさらに .data を chain する。
    $folders = (Invoke-BwApi -Method GET -Path '/list/object/folders').data
    $existingFolder = $folders | Where-Object { $_.name -eq $FolderName }
    if ($existingFolder) {
        $folderId = $existingFolder.id
        Write-Host "  Folder exists (id: $folderId)" -ForegroundColor Yellow
    } else {
        $created = Invoke-BwApi -Method POST -Path '/object/folder' -Body @{ name = $FolderName }
        $folderId = $created.id
        Write-Host "  Created folder (id: $folderId)" -ForegroundColor Green
    }

    # ------------------------------------------------------------------------
    # 4. 既存 DeepSeek key を copy 元として取得 (値はローカルのみ)
    # ------------------------------------------------------------------------
    Write-Host ""
    Write-Host "Step 2: Read source '$SourceDeepSeekItem'" -ForegroundColor Cyan
    # `search=` query は環境によって hit しないケースがあった
    # (invisible char in name, folder filter, organization 配下など)。
    # 全 item を取って完全一致 → partial match (`-like '*DeepSeek*'`) の
    # 順でフォールバックする。一意に絞れない時は候補を列挙して abort。
    $allItems = (Invoke-BwApi -Method GET -Path '/list/object/items').data
    $exact = $allItems | Where-Object { $_.name -eq $SourceDeepSeekItem }
    if ($exact.Count -eq 1) {
        $src = $exact[0]
    } else {
        $partial = $allItems | Where-Object { $_.name -like '*DeepSeek*' -or $_.name -like '*Deepseek*' -or $_.name -like '*deepseek*' }
        if ($partial.Count -eq 0) {
            $sample = ($allItems | Select-Object -First 10 | ForEach-Object { $_.name }) -join ', '
            throw "'$SourceDeepSeekItem' not found (exact match: $($exact.Count), partial 'DeepSeek': 0). Total items: $($allItems.Count). Sample names: $sample"
        }
        if ($partial.Count -gt 1) {
            $names = ($partial | ForEach-Object { "'$($_.name)'" }) -join ', '
            throw "Multiple items match 'DeepSeek' partial: $names. Pass -SourceDeepSeekItem with exact name"
        }
        $src = $partial[0]
        Write-Host "  Exact name miss; using partial match '$($src.name)'" -ForegroundColor Yellow
    }
    $deepseekValue = $src.login.password
    if (-not $deepseekValue) {
        throw "'$($src.name)' item に login.password が無い (type=$($src.type))"
    }
    Write-Host "  Loaded deepseek_api_key (length: $($deepseekValue.Length))" -ForegroundColor Green

    # ------------------------------------------------------------------------
    # 5. api_server_key を CSPRNG で生成
    # ------------------------------------------------------------------------
    Write-Host ""
    Write-Host "Step 3: Generate api_server_key" -ForegroundColor Cyan
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rngBytes = New-Object byte[] 32
        $rng.GetBytes($rngBytes)
    } finally { $rng.Dispose() }
    $apiServerKey = ([Convert]::ToBase64String($rngBytes)) -replace '\+','-' -replace '/','_' -replace '=$',''
    Write-Host "  Generated api_server_key (length: $($apiServerKey.Length))" -ForegroundColor Green

    # ------------------------------------------------------------------------
    # 6. auth.json を raw text として読む (UTF-8)
    #    base64 化は不要: BW notes は multi-line text として完全 raw 保存され、
    #    docker exec stdin も binary-safe。base64 にしても security 上の
    #    obfuscation 効果はゼロ (reverse 容易)、size +33%、step +2 (encode+decode)。
    # ------------------------------------------------------------------------
    Write-Host ""
    Write-Host "Step 4: Read '$AuthJsonPath'" -ForegroundColor Cyan
    if (-not (Test-Path $AuthJsonPath)) {
        throw "auth.json not found at '$AuthJsonPath'"
    }
    $authText = [IO.File]::ReadAllText($AuthJsonPath, [Text.Encoding]::UTF8)
    Write-Host "  Read auth.json (chars: $($authText.Length))" -ForegroundColor Green

    # ------------------------------------------------------------------------
    # 7. Secure Note 3 個を作成
    #    bw create command の payload schema: { type:2, name, folderId, fields:[...], secureNote:{type:0}, ... }
    #    REST API でも同じ。
    # ------------------------------------------------------------------------
    Write-Host ""
    Write-Host "Step 5: Create items under folder '$FolderName'" -ForegroundColor Cyan

    function New-SecureNote {
        param(
            [string]$Name,
            # 大きい payload (5000 chars 超) は fields 上限を超えるため $Notes 経由。
            # 小さい secret は custom field (hidden type) で個別管理しやすい。
            [hashtable[]]$Fields = @(),
            [string]$Notes       = $null
        )
        # search query は使わず全 list から完全一致で existence check
        # (search が hit しない問題の予防)。
        $allItems2 = (Invoke-BwApi -Method GET -Path '/list/object/items').data
        $existing = $allItems2 | Where-Object { $_.name -eq $Name } | Select-Object -First 1
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
            type           = 2
            name           = $Name
            notes          = $Notes
            favorite       = $false
            fields         = @($fieldObjs)
            secureNote     = @{ type = 0 }
        }
        Invoke-BwApi -Method POST -Path '/object/item' -Body $payload | Out-Null
        $detail = if ($Notes) {
            "notes-length: $($Notes.Length)"
        } else {
            "fields: $($Fields.Count)"
        }
        Write-Host "  Created item '$Name' ($detail)" -ForegroundColor Green
    }

    New-SecureNote -Name $ProviderKeysItem   -Fields @(@{ name='deepseek_api_key'; value=$deepseekValue })
    New-SecureNote -Name $SelfHostedAuthItem -Fields @(@{ name='api_server_key';   value=$apiServerKey })
    # OAuth State は auth.json を raw JSON のまま notes に格納する。
    # 読み出し側 (hermes-restore.ps1) は `bw get item <id>` の .notes を
    # そのまま `/opt/data/auth.json` に書き出すだけで OK。
    New-SecureNote -Name $OAuthStateItem     -Notes $authText

    # scrub
    $deepseekValue = $null
    $apiServerKey  = $null
    $authText      = $null

    Write-Host ""
    Write-Host "Done." -ForegroundColor Green
    Write-Host "次の手順:" -ForegroundColor Cyan
    Write-Host "  1. start-hermes.ps1 / hermes-restore.ps1 を新 item 構造に合わせて改修"
    Write-Host "  2. pwsh deploy/hermes-agent/scripts/start-hermes.ps1"
    Write-Host "  3. curl http://127.0.0.1:8642/v1/models -H 'Authorization: Bearer <api_server_key>'"
} finally {
    Write-Host ""
    Write-Host "Stopping bw serve..." -ForegroundColor Cyan
    try {
        Invoke-RestMethod -Uri "$Base/lock" -Method Post -TimeoutSec 5 -ErrorAction SilentlyContinue | Out-Null
    } catch {}
    Stop-Job $serveJob -ErrorAction SilentlyContinue | Out-Null
    Remove-Job $serveJob -Force -ErrorAction SilentlyContinue | Out-Null
}
