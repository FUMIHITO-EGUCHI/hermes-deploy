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
# bw 2026.x で `--session` / `BW_SESSION` が無視される #12270 を踏むため、
# CLI subprocess 経路ではなく bw serve REST API 経由で読み書きする
# (bw-session.psm1 の Start-BwServe / Invoke-BwServeApi / Get-BwServeItem)。
#
# Security invariants:
#   1. master pw / session は bw serve プロセス内に閉じ込め、argv にも env
#      にも漏らさない。
#   2. 復号後の auth.json バイト列は host FS に置かない。stdin で alpine に
#      流し、named volume 内にのみ実体化する。
#   3. JSON バリデーションは pull / push 双方向で実施。

[CmdletBinding(DefaultParameterSetName = 'Pull')]
param(
    [Parameter(ParameterSetName = 'Pull')] [switch]$Pull,
    [Parameter(ParameterSetName = 'Push')] [switch]$Push,
    # 新 3-item 構造の item 名はスラッシュを含むので、旧 ValidatePattern
    # (`'^[A-Za-z0-9 _.\-]+$'`) は使えない。/ を許容しつつシェルメタは
    # 引き続き拒否する。bw API は path-style 解釈をしないので、ここでの
    # validation は「明らかに変な値の早期 fail」目的。
    [ValidatePattern('^[A-Za-z0-9 /_.\-]+$')]
    [string]$BwItem        = 'Hermes / OAuth State',
    [ValidatePattern('^[A-Za-z0-9_-]+$')]
    [string]$VolumeName    = 'hermes-data',
    [ValidatePattern('^[A-Za-z0-9_-]+$')]
    [string]$ContainerName = 'hermes',
    [int]   $BwServePort   = 8087,
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

# -----------------------------------------------------------------------------
# Pull (BW → volume)
# -----------------------------------------------------------------------------
function Invoke-PullFromBw {
    param([pscustomobject]$BwSession)

    Write-Host "=== Pulling auth.json from BW '$BwItem' → volume '$VolumeName' ===" -ForegroundColor Cyan

    $item = Get-BwServeItem -Session $BwSession -Name $BwItem
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
    param([pscustomobject]$BwSession)

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

    # bw serve の PUT /object/item/<id> で item ごと差し替える。secret は
    # HTTP body 経由 (loopback bind のみ) で argv/env に乗らない。
    $item = Get-BwServeItem -Session $BwSession -Name $BwItem
    $item.notes = $authText
    Invoke-BwServeApi -Session $BwSession -Method PUT -Path "/object/item/$($item.id)" -Body $item | Out-Null

    Write-Host "Pushed. BW item '$BwItem' notes updated." -ForegroundColor Green
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

# DefaultParameterSetName は no-arg ケースをカバーするが、`[switch]$Pull` は
# binder で $false に初期化されてしまう。明示的に立て直す。
if ($PSCmdlet.ParameterSetName -eq 'Pull') { $Pull = $true }
if ($PSCmdlet.ParameterSetName -eq 'Push') { $Push = $true }

# bw serve を 1 回起動して unlock し、Pull / Push の操作が終わるまで保持。
Write-Host "Starting bw serve backend..." -ForegroundColor Cyan
$bw = Start-BwServe -Port $BwServePort
try {
    if ($Push) {
        Invoke-PushToBw -BwSession $bw
    } else {
        Invoke-PullFromBw -BwSession $bw
    }
} finally {
    Stop-BwServe -Session $bw
}
