# hermes-restore.ps1 — Move /opt/data/auth.json between Bitwarden and the
# `hermes-data` named volume. Two directions:
#
#   -Pull   BW vault  →  volume   (default; fresh install / disaster recovery)
#   -Push   volume    →  BW vault (opt-in; initial migration & shutdown sync)
#
# Storage layout (新 3-item 構造):
#   BW Folder: Hermes
#   ├── Hermes / Provider Keys      (API keys; not touched by this script)
#   ├── Hermes / Self-Hosted Auth   (API server bearer; not touched)
#   └── Hermes / OAuth State        ← this script
#         .notes = raw auth.json (JSON 文字列をそのまま格納、base64 化なし)
#
# Security invariants:
#   1. BW session は argv に乗せない。Invoke-BwInternal の ExtraEnv 経由で渡す。
#   2. 復号後の auth.json バイト列は host FS に置かない。stdin で alpine に流し、
#      named volume 内にのみ実体化する。
#   3. JSON バリデーションは pull / push 双方向で実施。

[CmdletBinding(DefaultParameterSetName = 'Pull')]
param(
    [Parameter(ParameterSetName = 'Pull')] [switch]$Pull,
    [Parameter(ParameterSetName = 'Push')] [switch]$Push,
    [string]$BwItem        = 'Hermes / OAuth State',
    [string]$VolumeName    = 'hermes-data',
    [string]$ContainerName = 'hermes',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\bw-session.psm1" -Force

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

function Get-BytesSha256 {
    # raw byte[] → SHA256 hex。container 側 `sha256sum` と同じバイト列を hash
    # するため UTF-8 round-trip しない (BOM / 非 UTF-8 バイトでも一致する)。
    param([byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($Bytes)) -replace '-', '').ToLower()
    } finally { $sha.Dispose() }
}

function Test-VolumeExists {
    $existing = docker volume ls --filter "name=^$VolumeName`$" --format "{{.Name}}" 2>$null
    return ($existing -eq $VolumeName)
}

function Get-VolumeAuthJsonHash {
    if (-not (Test-VolumeExists)) { return $null }
    $out = docker run --rm -v "${VolumeName}:/data:ro" alpine sh -c "test -s /data/auth.json && sha256sum /data/auth.json | cut -d' ' -f1 || echo missing" 2>$null
    $h = ($out -join "`n").Trim()
    if (-not $h -or $h -eq 'missing') { return $null }
    return $h
}

function Assert-ValidAuthJson {
    param([byte[]]$Bytes)
    # vault / volume 両側の bitrot を防ぐ。
    try {
        $json   = [Text.Encoding]::UTF8.GetString($Bytes)
        $parsed = $json | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "Decoded payload is not valid JSON — refusing to proceed: $_"
    }
    if (-not ($parsed.PSObject.Properties.Name -contains 'providers')) {
        throw "Decoded JSON missing 'providers' key — does not look like a Hermes auth.json."
    }
}

function Get-BwItemObject {
    # BW item を 1 回だけ取得して PSCustomObject で返す。Get-BwField を field
    # 数だけ呼ぶと毎回 server fetch するため、まとめて取得して使い回す。
    param([string]$Name)
    $session = Get-BwSession
    $r = Invoke-BwInternal -BwArgs @('get','item',$Name) -ExtraEnv @{ BW_SESSION = $session }
    if ($r.ExitCode -ne 0 -or -not $r.Stdout) {
        throw "BW item '$Name' fetch failed: $($r.Stderr)"
    }
    return ($r.Stdout | ConvertFrom-Json)
}

# -----------------------------------------------------------------------------
# Pull (BW → volume)
# -----------------------------------------------------------------------------
function Invoke-PullFromBw {
    Write-Host "=== Pulling auth.json from BW '$BwItem' → volume '$VolumeName' ===" -ForegroundColor Cyan

    $item = Get-BwItemObject -Name $BwItem
    $authText = $item.notes
    if (-not $authText) {
        throw "BW item '$BwItem' notes is empty. -Push first to upload the existing local auth.json."
    }

    # validate + hash
    $decoded = [Text.Encoding]::UTF8.GetBytes($authText)
    Assert-ValidAuthJson -Bytes $decoded

    # idempotency: skip write if identical
    $incomingHash = Get-BytesSha256 -Bytes $decoded
    $currentHash  = Get-VolumeAuthJsonHash
    if ($currentHash -eq $incomingHash -and -not $Force) {
        Write-Host "Volume already has identical auth.json (sha=$($currentHash.Substring(0,12))...). Nothing to do." -ForegroundColor Green
        return
    }

    docker volume create $VolumeName 2>$null | Out-Null

    # raw JSON を stdin で alpine に流す → named volume に書き込む。
    # plaintext は alpine プロセス内と volume にしか存在しない。
    $authText | docker run --rm -i `
        -v "${VolumeName}:/data" `
        alpine sh -c "
            cat > /data/auth.json.new &&
            chown 10000:10000 /data/auth.json.new &&
            chmod 600 /data/auth.json.new &&
            mv /data/auth.json.new /data/auth.json
        "
    if ($LASTEXITCODE -ne 0) { throw "Streaming auth.json into volume failed (exit $LASTEXITCODE)" }

    Write-Host "Wrote auth.json (sha=$($incomingHash.Substring(0,12))...) to $VolumeName as hermes:hermes 0600." -ForegroundColor Green

    $running = docker ps --filter "name=^${ContainerName}`$" --format "{{.Names}}" 2>$null
    if ($running -eq $ContainerName) {
        Write-Host "Note: '$ContainerName' is running. Restart so the new credentials take effect:" -ForegroundColor Yellow
        Write-Host "      docker restart $ContainerName" -ForegroundColor Yellow
    }
}

# -----------------------------------------------------------------------------
# Push (volume → BW)
# -----------------------------------------------------------------------------
function Invoke-PushToBw {
    Write-Host "=== Pushing volume '$VolumeName' auth.json → BW '$BwItem' ===" -ForegroundColor Cyan

    if (-not (Test-VolumeExists)) { throw "Volume '$VolumeName' does not exist. Nothing to push." }

    # raw JSON を alpine 経由で取得 (base64 wrap なし)
    $raw = docker run --rm -v "${VolumeName}:/data:ro" alpine sh -c "
        if [ -s /data/auth.json ]; then
            cat /data/auth.json
        else
            echo MISSING
        fi
    " 2>$null
    $authText = ($raw -join "`n").TrimEnd("`n")
    if (-not $authText -or $authText -eq 'MISSING') {
        throw "Volume '$VolumeName' has no /data/auth.json yet."
    }

    # validate
    $bytes = [Text.Encoding]::UTF8.GetBytes($authText)
    Assert-ValidAuthJson -Bytes $bytes

    # logging only — operator が cross-check 用に使える
    $hash = (Get-BytesSha256 -Bytes $bytes).Substring(0, 12)
    Write-Host "Will push $($authText.Length) chars of JSON (sha=$hash...) to BW item '$BwItem' notes." -ForegroundColor Cyan

    if (-not $Force) {
        $confirm = Read-Host "Proceed? [y/N]"
        if ($confirm -ne 'y' -and $confirm -ne 'Y') {
            Write-Host "Aborted." -ForegroundColor Yellow
            return
        }
    }

    # bw edit item は payload を base64 化して stdin から食わせる。secret は
    # argv に乗らない。`bw serve` は localhost HTTP に貼り付くため、同一ユーザ
    # の他プロセスから無認証アクセス可能 → script 起動の最小権限 stdin 経由が筋。
    $item = Get-BwItemObject -Name $BwItem
    $item.notes = $authText

    $session = Get-BwSession
    $patchedJson    = $item | ConvertTo-Json -Depth 32 -Compress
    $patchedJsonB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($patchedJson))

    $editRes = Invoke-BwInternal `
        -BwArgs @('edit', 'item', $item.id) `
        -StdinInput $patchedJsonB64 `
        -ExtraEnv @{ BW_SESSION = $session }
    if ($editRes.ExitCode -ne 0) {
        throw "bw edit item failed (exit $($editRes.ExitCode)): $($editRes.Stderr)"
    }

    Write-Host "Pushed. BW item '$BwItem' notes updated via stdin." -ForegroundColor Green
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

# DefaultParameterSetName は no-arg ケースをカバーするが、`[switch]$Pull` は
# binder で $false に初期化されてしまう。明示的に立て直す。
if ($PSCmdlet.ParameterSetName -eq 'Pull') { $Pull = $true }
if ($PSCmdlet.ParameterSetName -eq 'Push') { $Push = $true }

if ($Push) { Invoke-PushToBw } else { Invoke-PullFromBw }
