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

$script:CacheDir  = Join-Path $env:USERPROFILE '.hermes-cache'
$script:CachePath = Join-Path $script:CacheDir 'bw_session.dpapi'

# Resolve `bw` invocation once per module-load. If a global @bitwarden/cli
# install is present the shim is ~300ms faster per call than `npx -y`
# (which re-resolves the package each time). Falls back to npx so a fresh
# clone still works without a global install step.
$script:BwCmd = if (Get-Command bw -ErrorAction SilentlyContinue) {
    @('bw')
} else {
    @('npx', '-y', '@bitwarden/cli')
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
            if ($StdinInput) {
                $stdoutOut = $StdinInput | & $script:BwCmd[0] $script:BwCmd[1..($script:BwCmd.Length - 1)] @BwArgs 2>$stderrTmp
            } else {
                $stdoutOut = & $script:BwCmd[0] $script:BwCmd[1..($script:BwCmd.Length - 1)] @BwArgs 2>$stderrTmp
            }
            $exit = $LASTEXITCODE
            $stderrOut = (Get-Content $stderrTmp -Raw -ErrorAction SilentlyContinue)
        } finally {
            Remove-Item $stderrTmp -Force -ErrorAction SilentlyContinue
        }

        # Scrub session-shaped material from captured stderr before returning.
        # Two passes:
        #   1. Exact match on the known session (if caller passed it via
        #      ExtraEnv) — catches the common case.
        #   2. Regex pass for "looks like a base64 secret" — catches
        #      debug-truncated session prefixes (`session: abcd...`),
        #      other tokens BW might log, and any future leak vector we
        #      haven't thought of. Over-redacts long hashes; that's
        #      acceptable for an error path.
        if ($stderrOut) {
            if ($ExtraEnv -and $ExtraEnv.BW_SESSION) {
                $stderrOut = $stderrOut.Replace($ExtraEnv.BW_SESSION, '[REDACTED-SESSION]')
            }
            # Match BOTH standard base64 (`+/`) AND base64url (`_-`).
            # BW CLI currently only emits the standard form, but JWT
            # fragments / PKCE verifiers / OIDC artifacts in future
            # debug output use base64url — widening the class costs
            # nothing today and prevents a future leak vector.
            $stderrOut = [Regex]::Replace($stderrOut, '[A-Za-z0-9+/_\-]{40,}={0,2}', '[REDACTED-B64]')
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
            $stream = $extType::Create(
                [System.IO.FileInfo]::new($Path),
                [System.IO.FileMode]::CreateNew,
                [System.IO.FileSystemRights]::Write,
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
    $session = & $script:BwCmd[0] $script:BwCmd[1..($script:BwCmd.Length - 1)] unlock --raw
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

Export-ModuleMember -Function Get-BwSession, Clear-BwSession, Get-BwField, Invoke-BwInternal
