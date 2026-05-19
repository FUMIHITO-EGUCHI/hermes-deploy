# hermes-restore.ps1 — Move /opt/data/auth.json between Bitwarden and the
# `hermes-data` named volume. Two directions:
#
#   -Pull   BW vault  →  volume   (default; fresh install / disaster recovery)
#   -Push   volume    →  BW vault (opt-in; initial migration & shutdown sync)
#
# Bitwarden item / field names match start-hermes.ps1.
#
# Security invariants (post-review):
#   1. BW session is NEVER passed on the command line. Pre-set BW_SESSION
#      via Invoke-BwInternal's ExtraEnv map; the helper unsets it on return.
#   2. The decoded auth.json bytes NEVER touch the host filesystem outside
#      the named volume. We stream base64 through alpine's stdin and let
#      `base64 -d` materialize the plaintext only inside the volume mount.
#   3. JSON is validated both on push AND on pull — symmetric defense
#      against corrupted-vault and corrupted-volume cases.

[CmdletBinding(DefaultParameterSetName = 'Pull')]
param(
    [Parameter(ParameterSetName = 'Pull')] [switch]$Pull,
    [Parameter(ParameterSetName = 'Push')] [switch]$Push,
    # Tight ValidatePattern: BW item names that contain anything beyond
    # printable ASCII (no quoting/shell meta, no slashes, no nulls) cannot
    # be passed in. Defends against `-BwItem '../list/object/items'` style
    # path-traversal abuse if this script were ever wrapped by an
    # untrusted caller.
    [ValidatePattern('^[A-Za-z0-9 _.\-]+$')]
    [string]$BwItem        = "Hermes Auth State",
    [ValidatePattern('^[A-Za-z0-9_-]+$')]
    [string]$VolumeName    = "hermes-data",
    [ValidatePattern('^[A-Za-z0-9_-]+$')]
    [string]$ContainerName = "hermes",
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$BW_FIELD_AUTH_JSON = 'auth_json_b64'

Import-Module "$PSScriptRoot\bw-session.psm1" -Force

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

function Get-BytesSha256 {
    # Direct byte[] → SHA256 hex string, matching `sha256sum` on the
    # container side (which hashes the raw file bytes). Earlier this was
    # `byte[] → UTF-8 string → re-encode → SHA256`, which round-trips
    # cleanly for ASCII JSON but can produce a false mismatch against
    # `sha256sum` if the input contains a BOM or any non-UTF-8 byte. Now
    # both sides hash the same byte sequence.
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
    # `wc -l`/`base64`/`sha256sum` are all in busybox. `2>/dev/null` keeps
    # the noise out; `|| echo missing` flags the absence case explicitly
    # so we don't confuse "empty hash" with "file missing".
    $out = docker run --rm -v "${VolumeName}:/data:ro" alpine sh -c "test -s /data/auth.json && sha256sum /data/auth.json | cut -d' ' -f1 || echo missing" 2>$null
    $h = ($out -join "`n").Trim()
    if (-not $h -or $h -eq 'missing') { return $null }
    return $h
}

function Assert-ValidAuthJson {
    param([byte[]]$Bytes)
    # Refuse to write garbage into either side of the BW⇄volume pipe.
    # Catches stale/corrupt vault fields AND container-side disk bitrot.
    try {
        $json = [Text.Encoding]::UTF8.GetString($Bytes)
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
    Write-Host "=== Pulling auth.json from BW '$BwItem' → volume '$VolumeName' ===" -ForegroundColor Cyan

    $b64 = Get-BwField -Item $BwItem -FieldName $BW_FIELD_AUTH_JSON
    if (-not $b64) {
        throw "BW field '$BW_FIELD_AUTH_JSON' is empty. If this is a fresh BW item, run with -Push first to upload the existing local auth.json."
    }

    # Decode + validate in-memory ONLY. Plaintext bytes never reach the
    # host filesystem — we hand them to alpine via stdin below.
    try { $decoded = [Convert]::FromBase64String($b64) }
    catch { throw "BW field '$BW_FIELD_AUTH_JSON' is not valid base64: $_" }

    Assert-ValidAuthJson -Bytes $decoded

    # Idempotency: compare hash of incoming bytes against volume's current
    # auth.json. Skip the write if identical. Both sides hash raw bytes
    # (no UTF-8 round-trip) so the comparison stays symmetric even if the
    # file ever picks up a BOM or non-UTF-8 byte.
    $incomingHash = Get-BytesSha256 -Bytes $decoded
    $currentHash  = Get-VolumeAuthJsonHash
    if ($currentHash -eq $incomingHash -and -not $Force) {
        Write-Host "Volume already has identical auth.json (sha=$($currentHash.Substring(0,12))...). Nothing to do." -ForegroundColor Green
        return
    }

    docker volume create $VolumeName 2>$null | Out-Null

    # Stream the base64 string into alpine via stdin; alpine decodes
    # directly into /data/auth.json.new, fixes perms, then atomic-moves
    # over the old file. The base64 text on stdin is not a secret on its
    # own (it's encrypted in BW); only the *decoded* bytes are sensitive,
    # and those only ever exist inside the alpine process + the volume.
    $b64 | docker run --rm -i `
        -v "${VolumeName}:/data" `
        alpine sh -c "
            base64 -d > /data/auth.json.new &&
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

    # `base64 -w0` produces a single line — eliminates the "echo MISSING
    # got concatenated into the b64 string" failure mode from the GNU/
    # busybox line-wrap default. `|| echo MISSING` on a separate line is
    # then unambiguous.
    $raw = docker run --rm -v "${VolumeName}:/data:ro" alpine sh -c "
        if [ -s /data/auth.json ]; then
            base64 -w0 /data/auth.json
        else
            echo MISSING
        fi
    " 2>$null
    $b64 = ($raw -join '').Trim()
    if (-not $b64 -or $b64 -eq 'MISSING') {
        throw "Volume '$VolumeName' has no /data/auth.json yet."
    }

    # Validate decoded bytes form valid Hermes auth JSON before push.
    try { $bytes = [Convert]::FromBase64String($b64) }
    catch { throw "Volume auth.json base64 decode failed: $_" }
    Assert-ValidAuthJson -Bytes $bytes

    # Log only — hash the decoded auth.json bytes (matches what
    # `sha256sum /data/auth.json` would print, so an operator can
    # cross-check the push against the volume).
    $hash = (Get-BytesSha256 -Bytes $bytes).Substring(0, 12)
    Write-Host "Will push $($b64.Length) chars of base64 (sha=$hash...) to BW field '$BW_FIELD_AUTH_JSON'." -ForegroundColor Cyan

    if (-not $Force) {
        $confirm = Read-Host "Proceed? [y/N]"
        if ($confirm -ne 'y' -and $confirm -ne 'Y') {
            Write-Host "Aborted." -ForegroundColor Yellow
            return
        }
    }

    # Push via `bw edit item <id>` with the encoded JSON piped through
    # STDIN. Two channels we explicitly avoid:
    #
    #   - argv (the obvious wrong choice): same-user processes harvest it
    #     via WMI / Sysmon / Win32_Process.CommandLine.
    #   - `bw serve` localhost HTTP (the wrong fix attempted in an
    #     earlier round): leaves the entire unlocked vault accessible
    #     to ANY same-user process on a localhost port for the lifetime
    #     of the serve daemon, with no per-request auth in the CLI as
    #     shipped today. Strictly worse than the argv leak.
    #
    # The CLI explicitly documents the stdin form:
    #   `echo 'b64...' | bw edit item <id>`
    # which puts the secret bytes on a process-private pipe handle. Not
    # visible in argv listings; not exposed on any TCP port.
    $session = Get-BwSession

    # Fetch current item (read-only; no secret on argv, so the standard
    # Invoke-BwInternal path is fine).
    $getRes = Invoke-BwInternal -BwArgs @('get', 'item', $BwItem) -ExtraEnv @{ BW_SESSION = $session }
    if ($getRes.ExitCode -ne 0 -or -not $getRes.Stdout) {
        throw "BW item '$BwItem' fetch failed: $($getRes.Stderr)"
    }
    $item = $getRes.Stdout | ConvertFrom-Json

    # Mutate the field in-process.
    $existing = $item.fields | Where-Object { $_.name -eq $BW_FIELD_AUTH_JSON } | Select-Object -First 1
    if ($existing) {
        $existing.value = $b64
    } else {
        # type 1 = "hidden" in BW's field-type enum.
        $newField = [PSCustomObject]@{ name = $BW_FIELD_AUTH_JSON; value = $b64; type = 1 }
        if ($null -eq $item.fields) {
            $item | Add-Member -NotePropertyName fields -NotePropertyValue @($newField) -Force
        } else {
            $item.fields = @($item.fields) + $newField
        }
    }

    # Encode JSON → base64 → push via stdin. The base64 string IS the
    # payload; it travels through the stdin pipe handle which is not
    # observable from WMI / process listings.
    $patchedJson    = $item | ConvertTo-Json -Depth 32 -Compress
    $patchedJsonB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($patchedJson))

    $editRes = Invoke-BwInternal `
        -BwArgs @('edit', 'item', $item.id) `
        -StdinInput $patchedJsonB64 `
        -ExtraEnv @{ BW_SESSION = $session }
    if ($editRes.ExitCode -ne 0) {
        throw "bw edit item failed (exit $($editRes.ExitCode)): $($editRes.Stderr)"
    }

    Write-Host "Pushed. BW item '$BwItem' updated via stdin (no argv exposure of secrets)." -ForegroundColor Green
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

# DefaultParameterSetName covers the no-arg case but `[switch]$Pull` still
# defaults to $false from the binder. Make the intent explicit here.
if ($PSCmdlet.ParameterSetName -eq 'Pull') { $Pull = $true }
if ($PSCmdlet.ParameterSetName -eq 'Push') { $Push = $true }

if ($Push) { Invoke-PushToBw } else { Invoke-PullFromBw }
