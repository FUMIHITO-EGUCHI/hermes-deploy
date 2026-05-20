# bw-session.psm1 — Bitwarden CLI session helper with Windows DPAPI cache.
#
# Why this exists:
#   The Hermes secret-management story revolves around a single Bitwarden
#   item ("Hermes Auth State") that holds the rotating OAuth credentials
#   plus the static API keys. Multiple PS1 scripts in this directory all
#   need a usable BW_SESSION. Without coordination the user gets prompted
#   for the master password every script invocation — unbearable for daily
#   use, and a non-starter for the background sync daemon (Phase 5).
#
#   This module gives every script a single entry point — `Get-BwSession` —
#   that returns a live session key. On first call after a fresh Windows
#   login the user enters their master password once; subsequent calls
#   read a DPAPI-encrypted cache from disk and complete silently.
#
# Threat model for the cache file:
#   - DPAPI CurrentUser scope: only processes running as this Windows user
#     account can decrypt.
#   - An attacker who can run code as this user can already read auth.json
#     out of the named volume via `docker exec`, so the BW session cache
#     does not widen the attack surface meaningfully.
#   - An attacker with disk-only access (offline forensics, stolen drive)
#     cannot decrypt — DPAPI key material is bound to the Windows account.
#   - The cache file ACL is locked to the current user only (no inherited
#     entries) to keep things from drifting back if Codex Sandbox or
#     similar synthetic groups appear later.
#
# Threats NOT mitigated:
#   - **Command-line leakage**: `bw` is never invoked with `--session <key>`
#     on the command line. We always pass via the BW_SESSION env var, which
#     is process-private. (Command-line args are visible via WMI/Sysmon to
#     same-user processes; argv is the wrong channel for secret material.)
#   - **Same-user docker socket access**: a malicious process running as
#     this user can `docker run -v hermes-data:/data alpine cat /data/auth.json`
#     and read every refresh token. Out of scope for this module.
#
# Exposed functions:
#   Get-BwSession   - returns the session key string; unlocks if needed.
#   Clear-BwSession - deletes the cache and `bw lock`s the vault.
#   Get-BwField     - convenience: pulls one custom field out of an item.

$ErrorActionPreference = 'Stop'

# Hoist the assembly import to module load so the cryptography path is
# always primed (and we don't pay Add-Type cost on every call).
Add-Type -AssemblyName System.Security
# PS 7 (Core/.NET 5+) は `System.Security.AccessControl.FileSystemAccessRule`
# / `FileSystemRights` 等を `System.IO.FileSystem.AccessControl` アセンブリへ
# 分離しており、暗黙ロードされない。明示的に Add-Type しないと
# New-RestrictedFile / Save-CachedSession の ACL 構築が
# `Unable to find type [System.IO.FileSystemRights]` で死ぬ。
# WinPS 5.1 では `System.dll` 経由で同型が見えるため Add-Type は no-op。
try { Add-Type -AssemblyName System.IO.FileSystem.AccessControl -ErrorAction Stop } catch {
    # Fallback: 古い .NET / Mono など、当該アセンブリが存在しない環境。
    # ACL 強化は諦め、DPAPI 暗号化 + 親ディレクトリ既定権限に依存。
    Write-Verbose "System.IO.FileSystem.AccessControl unavailable: $_"
}

$script:CacheDir  = Join-Path $env:USERPROFILE '.hermes-cache'
$script:CachePath = Join-Path $script:CacheDir 'bw_session.dpapi'

# Resolve `bw` invocation once per module-load. If a global @bitwarden/cli
# install is present the shim is ~300ms faster per call than `npx -y`
# (which re-resolves the package each time). Falls back to npx so a fresh
# clone still works without a global install step.
# `if` ブロックの戻り値は PowerShell pipeline に流された時点で配列が
# 要素 1 個なら scalar に unwrap される (有名な落とし穴)。`@(...)` も
# `[string[]]` キャストも、`if` の return path を通ると効果が消える。
# 直接代入する形に書き換えて、その後 `[string[]]` で型を固定する。
if (Get-Command bw -ErrorAction SilentlyContinue) {
    [string[]]$script:BwCmd = ,'bw'
} else {
    [string[]]$script:BwCmd = 'npx', '-y', '@bitwarden/cli'
}

function script:Set-ProcEnv {
    param([string]$Name, [string]$Value)
    # `Set-Item env:X $null` does NOT delete the variable on Windows
    # PowerShell 5.1 — it sets it to the empty string. Use the .NET API,
    # which removes the variable entirely when $Value is $null.
    [Environment]::SetEnvironmentVariable($Name, $Value, 'Process')
}

function script:Invoke-Bw {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$BwArgs,
        # Stdin input — when set, piped to the child process. Used for
        # `bw edit item` payloads that we want to keep out of argv.
        [string]$StdinInput,
        # Extra env vars set for the duration of the call only.
        # NEVER set BW_SESSION via command-line — always through this map.
        [hashtable]$ExtraEnv = @{}
    )

    foreach ($k in $ExtraEnv.Keys) { script:Set-ProcEnv $k $ExtraEnv[$k] }

    $stdoutOut = $null
    $stderrOut = $null
    try {
        # Capture stdout AND stderr separately. Hiding stderr (`2>$null`)
        # was masking real BW CLI errors and training the user to re-enter
        # the master password during transient outages.
        $stderrTmp = [System.IO.Path]::GetTempFileName()
        try {
            # `$script:BwCmd` は `[string[]]` で配列性を保証してあるので
            # 単純な `[0]` / `Select-Object -Skip 1` で扱える。`-Skip 1` は
            # 長さ 1 入力で空配列を返すため [1..0] 逆順 slice の罠は無い。
            $bwExe = $script:BwCmd[0]
            $bwPre = $script:BwCmd | Select-Object -Skip 1
            if ($StdinInput) {
                $stdoutOut = $StdinInput | & $bwExe @bwPre @BwArgs 2>$stderrTmp
            } else {
                $stdoutOut = & $bwExe @bwPre @BwArgs 2>$stderrTmp
            }
            $exit = $LASTEXITCODE
            $stderrOut = (Get-Content $stderrTmp -Raw -ErrorAction SilentlyContinue)
        } finally {
            Remove-Item $stderrTmp -Force -ErrorAction SilentlyContinue
        }

        # Scrub the known session string from captured stderr. Earlier this
        # had a second regex pass against "any 40+ char base64-ish blob",
        # but that over-redacts SHA hashes, JWT fragments, item IDs, and
        # other diagnostic content we'd want to see when debugging. The
        # literal-match pass below is the only place a real leak originates
        # from — BW CLI doesn't print the session anywhere else.
        if ($stderrOut -and $ExtraEnv -and $ExtraEnv.BW_SESSION) {
            $stderrOut = $stderrOut.Replace($ExtraEnv.BW_SESSION, '[REDACTED-SESSION]')
        }

        return [PSCustomObject]@{
            Stdout   = $stdoutOut
            Stderr   = $stderrOut
            ExitCode = $exit
        }
    } finally {
        # Properly REMOVE the env vars (vs setting to empty string). Even
        # the same-shell concurrency window is minimized to the duration
        # of the bw call.
        foreach ($k in $ExtraEnv.Keys) { script:Set-ProcEnv $k $null }
    }
}

function script:New-RestrictedFile {
    param([Parameter(Mandatory)][string]$Path)
    # Create $Path with an ACL containing exactly one ACE — full control
    # for the current user — and inheritance disabled. The file MUST not
    # exist before this call.
    #
    # Two implementation paths:
    #   - .NET 5+ (PowerShell 7.x): atomic create-with-ACL via
    #     FileSystemAclExtensions::Create. Zero window.
    #   - Windows PowerShell 5.1 / .NET Framework: FileSystemAclExtensions
    #     is missing from the BCL, so we create with default ACL then
    #     tighten via the legacy Set-Acl cmdlet (which IS in WinPS 5.1).
    #     A microsecond window exists between create and Set-Acl; it's
    #     materially narrower than the old icacls subprocess pattern and
    #     much narrower than no hardening at all.
    $sid  = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $sid, [System.Security.AccessControl.FileSystemRights]::FullControl,
        [System.Security.AccessControl.AccessControlType]::Allow)
    $acl = New-Object System.Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true, $false)
    $acl.AddAccessRule($rule)

    $extType = [type]::GetType('System.IO.FileSystemAclExtensions, System.IO.FileSystem.AccessControl')

    $stream = $null
    try {
        if ($extType) {
            # Atomic path — .NET Core / PS 7+
            # NOTE: `FileSystemRights` は `System.Security.AccessControl`
            # 名前空間。`System.IO.FileSystemRights` という型は存在しない
            # (PS の暗黙 namespace lookup でも引っかからない) ので必ず
            # 完全修飾。元コードは ``[System.IO.FileSystemRights]::Write``
            # と書いていたため PS7 で atomic create path に入った瞬間に
            # `Unable to find type` で落ちていた。
            $stream = $extType::Create(
                [System.IO.FileInfo]::new($Path),
                [System.IO.FileMode]::CreateNew,
                [System.Security.AccessControl.FileSystemRights]::Write,
                [System.IO.FileShare]::None,
                4096,
                [System.IO.FileOptions]::None,
                $acl)
        } else {
            # WinPS 5.1 fallback. Create + close, apply ACL via Set-Acl
            # (legacy cmdlet — exists on .NET Framework), then re-open
            # for writing. Set-Acl wraps SetSecurityInfo, doesn't need
            # FileSystemAclExtensions.
            $stream = [System.IO.File]::Open($Path,
                [System.IO.FileMode]::CreateNew,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::None)
            $stream.Close()
            $stream = $null
            Set-Acl -Path $Path -AclObject $acl
            $stream = [System.IO.File]::Open($Path,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::None)
        }
    } catch {
        if ($stream) { $stream.Dispose() }
        # If the file was created but ACL-tightening failed, delete it so
        # the next save retries from a clean slate rather than leaving a
        # loose-ACL ciphertext lying around.
        if (Test-Path $Path) { Remove-Item $Path -Force -ErrorAction SilentlyContinue }
        throw
    }
    return $stream
}

function script:Save-CachedSession {
    param([string]$Session)
    if (-not (Test-Path $script:CacheDir)) {
        # Apply the same hardened ACL to the directory so nothing inherits
        # loose perms into it later.
        New-Item -ItemType Directory -Force -Path $script:CacheDir | Out-Null
        try {
            $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $sid, [System.Security.AccessControl.FileSystemRights]::FullControl,
                [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit',
                [System.Security.AccessControl.PropagationFlags]::None,
                [System.Security.AccessControl.AccessControlType]::Allow)
            $dirAcl = Get-Acl $script:CacheDir
            $dirAcl.SetAccessRuleProtection($true, $false)
            $dirAcl.AddAccessRule($rule)
            Set-Acl -Path $script:CacheDir -AclObject $dirAcl
        } catch {
            Write-Warning "Failed to harden cache dir ACL: $_"
        }
    }

    $bytes = [System.Security.Cryptography.ProtectedData]::Protect(
        [Text.Encoding]::UTF8.GetBytes($Session),
        $null,
        [Security.Cryptography.DataProtectionScope]::CurrentUser
    )

    # Replace existing file: delete then create with restricted ACL.
    if (Test-Path $script:CachePath) { Remove-Item $script:CachePath -Force }
    $stream = script:New-RestrictedFile -Path $script:CachePath
    try {
        $stream.Write($bytes, 0, $bytes.Length)
    } finally {
        $stream.Dispose()
    }
}

function script:Read-CachedSession {
    if (-not (Test-Path $script:CachePath)) { return $null }
    try {
        $bytes = [IO.File]::ReadAllBytes($script:CachePath)
        $plain = [System.Security.Cryptography.ProtectedData]::Unprotect(
            $bytes, $null,
            [Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        return [Text.Encoding]::UTF8.GetString($plain)
    } catch {
        # Cache corrupted, machine SID changed, or DPAPI key store missing.
        return $null
    }
}

function script:Test-SessionAlive {
    param([string]$Session)
    if (-not $Session) { return $false }
    $r = script:Invoke-Bw -BwArgs @('status') -ExtraEnv @{ BW_SESSION = $Session }
    if ($r.ExitCode -ne 0 -or -not $r.Stdout) { return $false }
    try {
        return (($r.Stdout | ConvertFrom-Json -ErrorAction Stop).status -eq 'unlocked')
    } catch { return $false }
}

function Get-BwSession {
    <#
    .SYNOPSIS
        Returns a live Bitwarden CLI session key, unlocking the vault if
        the DPAPI cache is empty or stale.
    .OUTPUTS
        String — session key suitable for the BW_SESSION env var. NEVER
        pass it on the command line; always via env.
    #>
    [CmdletBinding()]
    param(
        [switch]$ForceUnlock
    )

    if (-not $ForceUnlock) {
        $cached = script:Read-CachedSession
        if ($cached -and (script:Test-SessionAlive $cached)) {
            return $cached
        }
    }

    $r = script:Invoke-Bw -BwArgs @('status')
    if ($r.ExitCode -ne 0) {
        throw "bw status failed (exit $($r.ExitCode)): $($r.Stderr)"
    }
    $status = ($r.Stdout | ConvertFrom-Json).status
    if ($status -eq 'unauthenticated') {
        throw "Bitwarden CLI is not logged in. Run: $($script:BwCmd -join ' ') login"
    }

    Write-Host "Bitwarden vault locked. Enter master password to unlock:" -ForegroundColor Yellow
    # Interactive unlock — read directly with the user at the TTY. Output
    # is the raw session key on stdout; do NOT capture stderr into the
    # variable here or the master-password prompt is invisible.
    $bwExe = $script:BwCmd[0]
    $bwPre = $script:BwCmd | Select-Object -Skip 1
    $session = & $bwExe @bwPre unlock --raw
    if (-not $session -or $LASTEXITCODE -ne 0) {
        throw "bw unlock failed"
    }

    # Sync once on fresh unlock so newly-created items on the web vault
    # are visible to subsequent get calls.
    script:Invoke-Bw -BwArgs @('sync') -ExtraEnv @{ BW_SESSION = $session } | Out-Null

    script:Save-CachedSession $session
    return $session
}

function Clear-BwSession {
    <#
    .SYNOPSIS
        Deletes the DPAPI cache and `bw lock`s the vault. Forces the next
        Get-BwSession call to prompt for the master password.
    #>
    [CmdletBinding()]
    param()
    if (Test-Path $script:CachePath) { Remove-Item $script:CachePath -Force }
    script:Invoke-Bw -BwArgs @('lock') | Out-Null
}

function Get-BwField {
    <#
    .SYNOPSIS
        Fetches one custom field from a Bitwarden item by name. Login
        password and notes are not searched — only the `fields[]` array.
    .PARAMETER Item
        BW item name or ID.
    .PARAMETER FieldName
        The `name` attribute of the desired custom field.
    .OUTPUTS
        String value. Throws if the item is missing OR the field is missing,
        with a list of available field names to ease typo debugging.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Item,
        [Parameter(Mandatory)][string]$FieldName
    )
    $session = Get-BwSession
    $r = script:Invoke-Bw -BwArgs @('get', 'item', $Item) -ExtraEnv @{ BW_SESSION = $session }
    if ($r.ExitCode -ne 0 -or -not $r.Stdout) {
        throw "Bitwarden item '$Item' not found: $($r.Stderr)"
    }
    $obj = $r.Stdout | ConvertFrom-Json
    $field = $obj.fields | Where-Object { $_.name -eq $FieldName } | Select-Object -First 1
    if (-not $field) {
        $available = ($obj.fields | ForEach-Object { $_.name }) -join ', '
        throw "Field '$FieldName' not found in '$Item'. Available: [$available]"
    }
    return $field.value
}

# Internal helper exposed for the rare callers that need to perform a
# read-only `bw get` (e.g. hermes-restore.ps1's fetch-then-mutate flow).
# Kept thin so the BW session/env hygiene stays in one place.
function Invoke-BwInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$BwArgs,
        [string]$StdinInput,
        [hashtable]$ExtraEnv = @{}
    )
    return script:Invoke-Bw -BwArgs $BwArgs -StdinInput $StdinInput -ExtraEnv $ExtraEnv
}

# -----------------------------------------------------------------------------
# bw serve backend
#
# bw CLI 2026.x で `bw --session <key>` / `BW_SESSION` env が無視される既知
# バグ (bitwarden/clients#12270) を踏むため、subprocess + session 渡しの経路は
# もう機能しない。代替として bw serve (localhost REST API) を script lifecycle
# 内で start/stop する形に統合する。
#
# 利用パターン:
#   $s = Start-BwServe
#   try {
#     $deepseek = Get-BwServeField -Session $s -Item 'X' -FieldName 'k'
#     ...
#   } finally {
#     Stop-BwServe -Session $s
#   }
# -----------------------------------------------------------------------------

function Start-BwServe {
    <#
    .SYNOPSIS
        Boot bw serve in a background job and unlock it via POST /unlock.
        Returns a session object: { Port, BaseUri, Job }.
    .PARAMETER Port
        Port to bind (default 8087). If already in use, throws.
    #>
    [CmdletBinding()]
    param([int]$Port = 8087, [int]$StartupTimeoutSec = 30)

    $base = "http://localhost:$Port"

    # ポート衝突チェック (既存 bw serve があれば早期 fail)。
    # 直前のバージョンは `throw` を try ブロック内で出していたため、続く
    # catch{} (connection refused を握りつぶす意図) に飲まれて衝突を
    # 検出できなかった。フラグで try を抜けてから throw する。
    $alreadyRunning = $false
    try {
        $existing = Invoke-RestMethod -Uri "$base/status" -Method Get -TimeoutSec 2 -ErrorAction Stop
        if ($existing.success) { $alreadyRunning = $true }
    } catch {
        # connection refused は期待動作 (これから起動する)
    }
    if ($alreadyRunning) {
        throw "Port $Port is already serving a bw instance. Stop it or pass -Port <other>."
    }

    $job = Start-Job -ScriptBlock {
        param($P) & bw serve --port $P --hostname localhost
    } -ArgumentList $Port

    # readiness wait
    $deadline = (Get-Date).AddSeconds($StartupTimeoutSec)
    $ready = $false
    while ((Get-Date) -lt $deadline) {
        try {
            $r = Invoke-RestMethod -Uri "$base/status" -Method Get -TimeoutSec 2 -ErrorAction Stop
            if ($r.success) { $ready = $true; break }
        } catch {}
        Start-Sleep -Milliseconds 500
    }
    if (-not $ready) {
        Stop-Job $job -ErrorAction SilentlyContinue
        Remove-Job $job -Force -ErrorAction SilentlyContinue
        throw "bw serve did not become ready within $StartupTimeoutSec seconds"
    }

    # POST /unlock — master pw を SecureString 経由で受け取り、pinned bytes
    # として渡す。$pwPlain は ZeroFreeBSTR で消去。
    Write-Host "Unlocking BW vault (REST)..." -ForegroundColor Cyan
    $securePw = Read-Host "Master password" -AsSecureString
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePw)
    try {
        $pwPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        $body = @{ password = $pwPlain } | ConvertTo-Json -Compress
        $resp = Invoke-RestMethod -Uri "$base/unlock" -Method Post -Body $body -ContentType 'application/json' -ErrorAction Stop
        if (-not $resp.success) {
            throw "bw /unlock failed: $($resp.message)"
        }
    } catch {
        Stop-Job $job -ErrorAction SilentlyContinue
        Remove-Job $job -Force -ErrorAction SilentlyContinue
        throw
    } finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        $pwPlain = $null
        $securePw.Dispose()
    }

    # sync once
    Invoke-RestMethod -Uri "$base/sync" -Method Post -ErrorAction SilentlyContinue | Out-Null

    return [pscustomobject]@{
        Port    = $Port
        BaseUri = $base
        Job     = $job
    }
}

function Stop-BwServe {
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Session)
    try {
        Invoke-RestMethod -Uri "$($Session.BaseUri)/lock" -Method Post -TimeoutSec 5 -ErrorAction SilentlyContinue | Out-Null
    } catch {}
    if ($Session.Job) {
        Stop-Job $Session.Job -ErrorAction SilentlyContinue | Out-Null
        Remove-Job $Session.Job -Force -ErrorAction SilentlyContinue | Out-Null
    }
}

function Invoke-BwServeApi {
    # serve の REST response wrapper: { success, data, message }。
    # success=false で throw、list endpoint は data の入れ子 { object, data }
    # を 1 段剥がす責務は呼び出し側 (data 構造が item か list か文脈依存)。
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [Parameter(Mandatory)][ValidateSet('GET','POST','PUT','DELETE')][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [object]$Body
    )
    $params = @{
        Uri         = "$($Session.BaseUri)$Path"
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

function Get-BwServeItem {
    # item 名で完全一致検索 (全 list filter)。`/list/object/items?search=`
    # 経由は環境によって hit しないため使わない。
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [Parameter(Mandatory)][string]$Name
    )
    $list = (Invoke-BwServeApi -Session $Session -Method GET -Path '/list/object/items').data
    $item = $list | Where-Object { $_.name -eq $Name } | Select-Object -First 1
    if (-not $item) {
        throw "BW item '$Name' not found"
    }
    return $item
}

function Get-BwServeField {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [Parameter(Mandatory)][string]$Item,
        [Parameter(Mandatory)][string]$FieldName
    )
    $obj = Get-BwServeItem -Session $Session -Name $Item
    $field = $obj.fields | Where-Object { $_.name -eq $FieldName } | Select-Object -First 1
    if (-not $field) {
        $available = ($obj.fields | ForEach-Object { $_.name }) -join ', '
        throw "Field '$FieldName' not found in '$Item'. Available: [$available]"
    }
    return $field.value
}

Export-ModuleMember -Function `
    Get-BwSession, Clear-BwSession, Get-BwField, Invoke-BwInternal, `
    Start-BwServe, Stop-BwServe, Invoke-BwServeApi, Get-BwServeItem, Get-BwServeField
