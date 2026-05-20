# bw-session.psm1 — Bitwarden access helper for hermes-deploy scripts.
#
# Strategy: bw serve (REST API).
#
# Why bw serve and not `bw --session <key>`:
#   bw CLI 2026.x silently ignores both BW_SESSION env and `--session` flag
#   in subprocess calls (bitwarden/clients#12270, #13696) — every bw call
#   re-prompts for the master password despite a valid session key. The
#   serve daemon keeps the unlock state inside a single process address
#   space and is unaffected.
#
# Lifecycle:
#   $bw = Start-BwServe          # spawns bw serve in a background job and
#                                # unlocks the vault via POST /unlock.
#                                # Prompts for the master password unless
#                                # -SecurePassword is supplied.
#   try {
#     $item  = Get-BwServeItem  -Session $bw -Name 'Hermes / Provider Keys'
#     $value = Get-BwServeField -Session $bw -Item 'Hermes / Provider Keys' `
#                               -FieldName 'deepseek_api_key'
#     ...
#   } finally {
#     Stop-BwServe -Session $bw
#   }
#
# Exported functions:
#   Start-BwServe         boot bw serve + unlock; returns a session object.
#   Stop-BwServe          POST /lock + tear down the background job.
#   Invoke-BwServeApi     thin wrapper around Invoke-RestMethod with
#                         success-flag handling.
#   Get-BwServeItem       look up an item by exact name (uses /list).
#   Get-BwServeField      convenience: return one custom-field value.
#   Clear-BwSession       run `bw lock`. Use after long-running ops if you
#                         want the next bw operation to require a fresh
#                         master password.

$ErrorActionPreference = 'Stop'

function Start-BwServe {
    <#
    .SYNOPSIS
        Boot bw serve in a background job and unlock it.
    .PARAMETER Port
        Localhost port to bind. Default 8087.
    .PARAMETER SecurePassword
        Optional pre-supplied master password as a SecureString. If omitted,
        prompts on the TTY via Read-Host -AsSecureString.
    .OUTPUTS
        PSCustomObject with Port, BaseUri, Job — pass to the other functions.
    #>
    [CmdletBinding()]
    param(
        [int]$Port = 8087,
        [int]$StartupTimeoutSec = 30,
        [System.Security.SecureString]$SecurePassword
    )

    $base = "http://localhost:$Port"

    # Reject port collision early. The throw must run AFTER the try/catch
    # block exits — a throw inside try{} is swallowed by the surrounding
    # catch{} that's there to ignore "connection refused".
    $alreadyRunning = $false
    try {
        $r = Invoke-RestMethod -Uri "$base/status" -Method Get -TimeoutSec 2 -ErrorAction Stop
        if ($r.success) { $alreadyRunning = $true }
    } catch {
        # connection refused / 404 = port is free.
    }
    if ($alreadyRunning) {
        throw "Port $Port is already serving a bw instance. Stop it or pass -Port <other>."
    }

    $job = Start-Job -ScriptBlock {
        param($P) & bw serve --port $P --hostname localhost
    } -ArgumentList $Port

    # Readiness poll. /status returns success once the daemon is listening
    # even though the vault is still locked.
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

    # Acquire the master password — either from the caller-supplied
    # SecureString or interactively from the TTY.
    # Track who owns the SecureString so we only dispose what we created.
    # A caller-supplied SecureString belongs to the caller.
    $localPw = -not $PSBoundParameters.ContainsKey('SecurePassword')
    if ($localPw) {
        Write-Host "Unlocking BW vault (REST)..." -ForegroundColor Cyan
        $SecurePassword = Read-Host "Master password" -AsSecureString
    }

    # Convert to plaintext for the JSON body, then zero the BSTR copy.
    # ($pwPlain is a managed string; the GC owns it and we can't zero it,
    # but we minimize the time it's alive.)
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
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
        # Dispose only the locally-created SecureString. A caller-supplied
        # instance is the caller's responsibility.
        if ($localPw -and $SecurePassword) { $SecurePassword.Dispose() }
    }

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
    # serve responses look like { success, data, message }. Returns .data;
    # list endpoints add an extra { object: 'list', data: [...] } wrapper
    # which callers strip with `.data`.
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
    # Exact-name match against the full /list/object/items result.
    # ?search= filtering is unreliable for our use case (no hits when names
    # contain `/`, observed in 2026-05 testing), so we always full-list.
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
    # Convenience for "single field of an item". Callers that need multiple
    # fields from the same item should call Get-BwServeItem once and read
    # `.fields | Where {$_.name -eq 'X'} | % value` themselves.
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

function Clear-BwSession {
    <#
    .SYNOPSIS
        Run `bw lock`. Equivalent to `bw lock` from the command line.
        DPAPI session caching was removed when the subprocess + BW_SESSION
        path stopped working in bw 2026.x; there's no cache to clear.
    #>
    [CmdletBinding()]
    param()
    & bw lock 2>$null | Out-Null
}

Export-ModuleMember -Function `
    Start-BwServe, Stop-BwServe, Invoke-BwServeApi, Get-BwServeItem, Get-BwServeField, Clear-BwSession
