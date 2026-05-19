# hermes-on.ps1 — open an interactive Hermes Agent chat scoped to a project
# under the mounted /workspace bind-mount.
#
# Prereq: docker-compose.windows.yml's `gateway.volumes` includes the
# ${HERMES_PROJECTS}:/workspace mount, and the container has been (re)created
# since that mount was added. If not, run:
#   docker compose -f docker-compose.windows.yml up -d --force-recreate
#
# Usage:
#   pwsh ./scripts/hermes-on.ps1 <project>                       # opus 4.7 by default
#   pwsh ./scripts/hermes-on.ps1 <project> -Query "review the diff on this branch"
#   pwsh ./scripts/hermes-on.ps1 <project> -Model gpt-5.5 -Provider openai-codex
#   pwsh ./scripts/hermes-on.ps1 <project> -Worktree              # isolated git worktree
#   pwsh ./scripts/hermes-on.ps1 <project> -AutoRoute             # DeepSeek 親 + Opus/GPT 委譲
#   pwsh ./scripts/hermes-on.ps1 -List                            # show mounted projects
#
# Default skills (normal mode): code-review-and-quality, test-driven-development,
# debugging-and-error-recovery, security-and-hardening, git-workflow-and-versioning.
# Default skill (-AutoRoute):   auto-route-deepseek (slim, single skill).
# Override with -Skills "..." (comma-separated) or -SkipSkills to suppress all.
#
# -AutoRoute mode:
#   親エージェントを DeepSeek-V4 (flash) (provider=deepseek) に切替。プロンプト
#   キャッシュで激安。重い判断は delegate_task で claude-opus-4-7 や
#   gpt-5.5 (openai-codex) に自動委譲する誘導スキル auto-route-deepseek を
#   読み込む。明示的に -Model / -Provider / -Skills を指定すると個別上書き可。

[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(Position = 0, ParameterSetName = 'Run', Mandatory = $true)]
    [string]$Project,

    [Parameter(ParameterSetName = 'List', Mandatory = $true)]
    [switch]$List,

    [string]$Container = 'hermes',
    [string]$Model,
    [string]$Provider,
    [string]$Query,
    [switch]$Worktree,
    [switch]$AcceptHooks,
    [int]$MaxTurns,
    [string]$Skills,
    [switch]$SkipSkills,
    # -AutoRoute: DeepSeek-V4 (flash) を親に据えるコスト最適化モード。
    # 親モデル/Provider/Skills の既定値が AutoRoute 用に切り替わる
    # (ユーザが明示指定したものは上書きしない)。
    [switch]$AutoRoute
)

# Defaults differ between normal and -AutoRoute modes. We can't set
# defaults at the param() block because we want PowerShell's binder to
# tell us whether the user passed -Model explicitly.
$DEFAULT_MODEL_NORMAL    = 'claude-opus-4-7'
$DEFAULT_PROVIDER_NORMAL = 'anthropic'
$DEFAULT_SKILLS_NORMAL   = 'code-review-and-quality,test-driven-development,debugging-and-error-recovery,security-and-hardening,git-workflow-and-versioning'

$DEFAULT_MODEL_AUTOROUTE    = 'deepseek-v4-flash'
$DEFAULT_PROVIDER_AUTOROUTE = 'deepseek'
# AutoRoute 時はルーティング判断に必要な単一スキルだけロード。
# 重い skill set は delegate 先 (Opus/GPT-5.5) の子セッションで個別に
# 引っ張ればよく、親 (DeepSeek) のトークン費を抑える。
$DEFAULT_SKILLS_AUTOROUTE   = 'auto-route-deepseek'
$AUTOROUTE_SKILL_NAME       = 'auto-route-deepseek'

# param() の `[string]$Foo = "default"` 形式を使うと「ユーザが既定値を
# 受け入れた」ケースと「ユーザが明示的にその値を渡した」ケースの区別が
# 失われる。AutoRoute モード時は既定モデル/プロバイダ/スキルが切り替わる
# が、ユーザが `-Model` を明示指定したらそれを優先したい。
# `$PSBoundParameters.ContainsKey` は呼び出し元が値を渡したかを返すので、
# 「未指定の時だけモード別の既定を当てる」分岐がここで成立する。
if ($AutoRoute) {
    if (-not $PSBoundParameters.ContainsKey('Model'))    { $Model    = $DEFAULT_MODEL_AUTOROUTE }
    if (-not $PSBoundParameters.ContainsKey('Provider')) { $Provider = $DEFAULT_PROVIDER_AUTOROUTE }
    if (-not $PSBoundParameters.ContainsKey('Skills'))   { $Skills   = $DEFAULT_SKILLS_AUTOROUTE }
} else {
    if (-not $PSBoundParameters.ContainsKey('Model'))    { $Model    = $DEFAULT_MODEL_NORMAL }
    if (-not $PSBoundParameters.ContainsKey('Provider')) { $Provider = $DEFAULT_PROVIDER_NORMAL }
    if (-not $PSBoundParameters.ContainsKey('Skills'))   { $Skills   = $DEFAULT_SKILLS_NORMAL }
}

$ErrorActionPreference = 'Stop'

function Get-MountedProjects {
    $raw = docker exec $Container sh -c 'ls -1 /workspace 2>/dev/null' 2>$null
    if ($LASTEXITCODE -ne 0) { return @() }
    # `-split "\r?\n"` defends against Docker Desktop variants that send
    # CRLF over PSRemoting; trim each entry to defend against trailing
    # whitespace.
    return $raw -split "\r?\n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
}

function Test-SafeProjectName {
    # Accept names matching the intersection of "safe-for-shell" and
    # "not a directory traversal token":
    #   - first char must be [A-Za-z0-9_-]  (NOT a leading dot; blocks
    #     `..`, `.git`, `.ssh`, etc. that would either traverse out of
    #     /workspace or land in unexpected places)
    #   - remaining chars are [A-Za-z0-9._-]
    #   - reject the literal `.` and `..` explicitly even though the
    #     first-char rule already covers them, for fail-loud diagnostics
    # This rejects whitespace, ANSI escapes, path separators, glob meta
    # chars — anything that could hijack the Write-Host log below or
    # escape /workspace.
    param([Parameter(Mandatory)][string]$Name)
    if ($Name -in @('.', '..')) { return $false }
    return ($Name -match '^[A-Za-z0-9_-][A-Za-z0-9._-]*$')
}

function Test-WorkspaceMount {
    docker exec $Container test -d /workspace 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Install-AutoRouteSkill {
    # Idempotent: ensures the SKILL.md exists inside the container's user
    # skill directory with the canonical content shipped under
    #   deploy/hermes-agent/skills/auto-route-deepseek/SKILL.md
    # The named volume `hermes-data` persists this across container
    # restarts, so it's a one-shot install per host.
    #
    # Hermes scans /opt/data/skills/<category>/<name>/SKILL.md for user
    # skills (NOT /opt/data/.hermes/skills — that path is for internal
    # bookkeeping and is NOT picked up by `hermes chat -s <name>`).
    # Confirmed by `find /opt/data -name SKILL.md` listing built-in
    # categories like autonomous-ai-agents, apple, etc.
    #
    # We stream the file via `docker exec -i ... sh -c "cat > ..."` instead
    # of `docker cp` to avoid host TEMP file writes and to ensure the
    # resulting file is owned by hermes:hermes (10000:10000) — `docker cp`
    # leaves files root-owned.
    param([string]$Container)

    $hostSkillPath = Join-Path $PSScriptRoot '..\skills\auto-route-deepseek\SKILL.md'
    $hostSkillPath = [System.IO.Path]::GetFullPath($hostSkillPath)
    if (-not (Test-Path $hostSkillPath)) {
        throw "auto-route skill source missing on host: $hostSkillPath"
    }

    $containerSkillDir  = '/opt/data/skills/autonomous-ai-agents/auto-route-deepseek'
    $containerSkillPath = "$containerSkillDir/SKILL.md"

    # Compare host-side SHA256 against container-side SHA256. Reinstall on
    # mismatch so edits to the canonical file propagate without manual ops.
    $hostHash = (Get-FileHash -Algorithm SHA256 -Path $hostSkillPath).Hash.ToLower()
    $containerHashRaw = docker exec -u hermes $Container sh -c "sha256sum $containerSkillPath 2>/dev/null | cut -d' ' -f1" 2>$null
    $containerHash = ($containerHashRaw -join '').Trim().ToLower()

    if ($containerHash -eq $hostHash) {
        return  # already in sync
    }

    Write-Host "Installing $AUTOROUTE_SKILL_NAME skill into container..." -ForegroundColor DarkGray
    docker exec -u hermes $Container sh -c "mkdir -p $containerSkillDir" 2>$null | Out-Null

    # `cat > $containerSkillPath` runs as hermes (because of `-u hermes`),
    # so the resulting file is owned 10000:10000 with default umask
    # (typically 0644). SKILL.md is not a secret — readable perms are fine.
    Get-Content -Raw -Path $hostSkillPath | docker exec -i -u hermes $Container sh -c "cat > $containerSkillPath"
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to write SKILL.md into container (exit $LASTEXITCODE)"
    }
}

if (-not (Test-WorkspaceMount)) {
    Write-Error @"
Container '$Container' has no /workspace mount.

Add this to docker-compose.windows.yml gateway.volumes:
  - "`${HERMES_PROJECTS:-`${USERPROFILE}/Documents/Git}:/workspace:rw"

Then recreate the container:
  docker compose -f docker-compose.windows.yml up -d --force-recreate
"@
}

if ($List) {
    $projects = Get-MountedProjects
    if (-not $projects) {
        Write-Host "No projects found under /workspace inside container '$Container'." -ForegroundColor Yellow
        return
    }
    Write-Host "Projects mounted at /workspace:" -ForegroundColor Cyan
    $projects | ForEach-Object { Write-Host "  $_" }
    return
}

# Validate project name shape BEFORE consulting the container. Rejecting
# unsafe names early prevents `Write-Host` injection of control characters
# via project directory names containing ANSI escapes or newlines.
if (-not (Test-SafeProjectName $Project)) {
    throw "Project name '$Project' contains characters outside [A-Za-z0-9._-]. Rename the directory or pass a safe name."
}

# Validate project exists under /workspace.
$projects = Get-MountedProjects
if ($projects -notcontains $Project) {
    $hint = if ($projects) { "Available: $($projects -join ', ')" } else { '(none mounted)' }
    throw "Project '$Project' not found under /workspace. $hint"
}

# AutoRoute mode requires the routing skill to be available in the
# container's user skill directory before `hermes chat -s auto-route-deepseek`
# can resolve it.
if ($AutoRoute -and -not $SkipSkills -and ($Skills -split ',' | ForEach-Object { $_.Trim() }) -contains $AUTOROUTE_SKILL_NAME) {
    Install-AutoRouteSkill -Container $Container
}

# Assemble hermes chat invocation.
$hermesArgs = @(
    'chat',
    '-m', $Model,
    '--provider', $Provider
)
if ($Query)       { $hermesArgs += @('-q', $Query) }
if ($Worktree)    { $hermesArgs += '--worktree' }
if ($AcceptHooks) { $hermesArgs += '--accept-hooks' }
if ($MaxTurns)    { $hermesArgs += @('--max-turns', $MaxTurns) }
if (-not $SkipSkills -and $Skills) { $hermesArgs += @('-s', $Skills) }

$workdir = "/workspace/$Project"

# Interactive (-it) when no -Query; non-interactive (-i) for one-shot piping.
$execMode = if ($Query) { '-i' } else { '-it' }

Write-Host "→ docker exec $execMode -u hermes -w $workdir $Container hermes $($hermesArgs -join ' ')" -ForegroundColor DarkGray
docker exec $execMode -u hermes -w $workdir $Container /opt/hermes/.venv/bin/hermes @hermesArgs
exit $LASTEXITCODE
