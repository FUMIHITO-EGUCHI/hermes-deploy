# Hermes Agent — Portable Deploy (Windows + Docker Desktop / Future VPS)

Self-hosted [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent)
deployment configured for portability: install on the current gaming PC today,
move to a VPS or Mini PC tomorrow with zero config drift.

## Why this layout

Data and config are split into three movable pieces:

| Piece                          | Where                                       | Portable?                |
|--------------------------------|---------------------------------------------|--------------------------|
| `docker-compose.windows.yml`   | Versioned in this repo                      | Yes                      |
| `.env` (non-secret config)     | Local file (gitignored)                     | Manual copy              |
| All secrets (API keys + OAuth) | **Bitwarden vault** (item "Hermes Auth State") | Migrate vault, not files |
| Hermes state (named volume)    | Docker `hermes-data` volume (not on host FS)| Re-seeded from BW vault  |

Secrets never touch the host filesystem: `scripts/start-hermes.ps1` unlocks
Bitwarden via a DPAPI-cached session and pipes the per-boot keys into the
container's process env. The OAuth refresh tokens (Codex device-code,
Anthropic sk-ant-oat01) live in a Docker named volume reachable only via
the docker socket. To stand up a new host: install Docker + BW CLI, run
`hermes-restore.ps1` (BW → volume), then `start-hermes.ps1`. See
**[VPS / Mini PC migration](#vps--mini-pc-migration-with-bw-as-source-of-truth)** below for the full flow.

---

## Prerequisites (Windows host)

- Windows 11 with Docker Desktop installed (WSL2 backend — already the default)
- `docker --version` returns ≥ 24
- `git` (any flavor — Git for Windows, WSL2 git, or GitHub Desktop)
- Optional: PowerShell 7+ for the backup script

Confirm:
```powershell
docker --version
docker compose version
```

---

## First-time install

### 1. Clone the upstream Hermes Agent repo

This is the **build context** — the Dockerfile and source live here.

```powershell
cd C:\Users\$env:USERNAME
git clone https://github.com/NousResearch/hermes-agent.git
cd hermes-agent
```

### 2. Drop in the Windows-safe compose file and env template

Adjust the path to wherever you cloned *this* deploy repo.

```powershell
$DEPLOY = "C:\Users\$env:USERNAME\Documents\Git\hermes\deploy\hermes-agent"
Copy-Item "$DEPLOY\docker-compose.windows.yml" .
Copy-Item "$DEPLOY\.env.template" .env
```

### 3. Fill in `.env`

The template carries no secrets — just `HERMES_DATA` and optional defaults.
For most setups the defaults are fine; just save it as-is.

### 4. Set up the Bitwarden vault item

This deployment uses a **single consolidated BW item** as the source of
truth for every secret. The item layout is hard-coded in the launcher
scripts (changing names means editing the vault, not the scripts):

| Field            | Type   | Holds                                                | Set by                    |
|------------------|--------|------------------------------------------------------|---------------------------|
| `deepseek_api_key` | hidden | DeepSeek `sk-...` key (static)                       | you, once                 |
| `auth_json_b64`  | hidden | base64 of the live `auth.json` (OAuth refresh tokens) | `hermes-restore.ps1 -Push` |

Create it:

1. Open Bitwarden web vault → New item → Type: **Secure Note** → Name: `Hermes Auth State`
2. Add a **custom field**, type **Hidden**, name `deepseek_api_key`, value = your DeepSeek key.
3. (Leave `auth_json_b64` for later — the first `hermes-restore.ps1 -Push` creates it.)
4. Save.

Make sure the Bitwarden CLI is logged in once on this machine:

```powershell
npx -y @bitwarden/cli login        # one-time interactive login
```

The launcher scripts use a DPAPI-encrypted session cache
(`~/.hermes-cache/bw_session.dpapi`), so **you only enter the master
password once per Windows login** — start-hermes, stop-hermes,
hermes-restore, and the optional sync daemon all reuse the cached session
silently. Cache is invalidated on `bw lock`, vault password change, or
explicit `stop-hermes.ps1 -LockVault`.

### 5. (No host data dir needed)

The persistent state lives in a Docker **named volume** (`hermes-data`),
not in `${USERPROFILE}\.hermes`. Compose creates the volume on first
`up`. If you're migrating from the legacy bind-mount layout, see
**[Migration from bind-mount](#migration-from-bind-mount)** below before
running `start-hermes.ps1`.

### 6. Build the image (first time only)

```powershell
cd C:\Users\$env:USERNAME\hermes-agent
docker compose -f docker-compose.windows.yml build
```

The build takes several minutes (Debian + Python + Node + ffmpeg layers).

### 7. Launch with Bitwarden pipeline

```powershell
$DEPLOY = "C:\Users\$env:USERNAME\Documents\Git\hermes\deploy\hermes-agent"
pwsh "$DEPLOY\scripts\start-hermes.ps1"
```

What it does:
1. Unlocks the BW vault (DPAPI cache hit → silent; cache miss → master pw).
2. Pulls `deepseek_api_key` from the "Hermes Auth State" item.
3. Injects as `DEEPSEEK_API_KEY` in the launcher's env.
4. Runs `docker compose up -d` — compose forwards the env into both containers.
5. Warns if the `hermes-data` volume has no `auth.json` (pointing to
   `hermes-restore.ps1` for first-time setup or recovery).
6. Scrubs the host env var on exit. `BW_SESSION` survives so other
   scripts in the same shell stay silent.

Custom vault item:
```powershell
pwsh "$DEPLOY\scripts\start-hermes.ps1" -BwItem "My Custom Vault Entry"
```

### 8. Open the dashboard

http://127.0.0.1:9119  (host-only — not reachable from the LAN)

### 9. Drive the CLI inside the container

```powershell
docker exec -it hermes hermes        # interactive TUI
docker exec -it hermes hermes setup  # model + provider wizard
```

On first `hermes setup`, pick provider **DeepSeek** and model
`deepseek-chat` (V3) or `deepseek-reasoner`. The key is already in the
container's env so no paste needed.

### 10. (Optional) Add ChatGPT / Claude subscription providers

Hermes can also consume your existing **ChatGPT Plus/Pro** and **Claude
Pro/Max** subscription quota instead of (or in addition to) per-token API
billing. One-shot setup:

```powershell
pwsh "$DEPLOY\scripts\setup-providers.ps1"
```

What it does:
1. Runs the OpenAI Codex device-code flow inside the container — opens a URL
   + 8-char code, you approve in your browser with your ChatGPT account.
   Refresh token lands in `~/.hermes/auth.json` (persisted volume).
2. Installs `@anthropic-ai/claude-code` in the container (if missing) and
   runs `claude setup-token` as the `hermes` user — opens a URL, you log
   into Claude.ai and paste back a verification code. Refresh token lands
   in `~/.hermes/.claude/.credentials.json` (persisted volume).
3. Reports status; both should read `OK` afterwards.

Sub-commands:
```powershell
pwsh "$DEPLOY\scripts\setup-providers.ps1" -Status                   # just check, don't auth
pwsh "$DEPLOY\scripts\setup-providers.ps1" -SkipClaude               # codex only
pwsh "$DEPLOY\scripts\setup-providers.ps1" -SkipCodex                # claude only
pwsh "$DEPLOY\scripts\setup-providers.ps1" -Force                    # re-auth even if already logged in
pwsh "$DEPLOY\scripts\setup-providers.ps1" -ClaudeMode interactive   # force the browser flow even if host has creds
pwsh "$DEPLOY\scripts\setup-providers.ps1" -ClaudeMode import        # always copy from host (fail if absent)
```

**Claude login modes (`-ClaudeMode`)**:
- `auto` (default) — if `$env:USERPROFILE\.claude\.credentials.json` exists on the
  host (i.e. you already use Claude Code locally), copy it into the Hermes
  data volume. Otherwise run the interactive `claude auth login --claudeai`.
- `import` — always copy from the host file. Fastest, but the host's Claude
  Code and Hermes will then share the same OAuth refresh token; when either
  client rotates (~30-day cadence) the other's session breaks until you
  re-run `-ClaudeMode import` to resync.
- `interactive` — always run the browser flow. Hermes gets its own refresh
  token, independent of the host's Claude Code.
- `setup-token` — register an existing `sk-ant-oat01-...` long-lived token
  (produced by `claude setup-token`) into Hermes' credential pool. Use this
  when you've already run `claude setup-token` separately and have the
  token string in hand. Hermes auto-detects the `sk-ant-oat*` prefix and
  routes via Bearer + Claude Code beta header (subscription billing, not
  API quota). Stored in `~/.hermes/auth.json` as a pooled credential —
  independent of any host-side `~/.claude/.credentials.json`.

After setup, pick the subscription model as your Hermes default:
```powershell
docker exec -it hermes /opt/hermes/.venv/bin/hermes model
# Anthropic       → claude-opus-4-7 (or claude-sonnet-4-5 etc.)
# OpenAI Codex    → gpt-5.5 (or gpt-5.4-mini, gpt-5.3-codex, ...)
# NOTE: ChatGPT-account Codex does NOT accept gpt-5 / gpt-5-codex / codex-mini.
#       It only accepts gpt-5.x slugs from hermes_cli/codex_models.py.
```

### Step 11. (Optional) Point Hermes at your local code

To let the agent actually read and edit your projects, mount your code root
into the container at `/workspace`. The compose file already declares the
mount; you just need to ensure the source path is right and that the
container has been (re)created since the mount was added.

`.env`:
```dotenv
# Defaults to ${USERPROFILE}/Documents/Git on Windows if unset.
HERMES_PROJECTS="C:/Users/<you>/Documents/Git"
```

Apply (no full rebuild needed — just recreate so the new bind mount is
applied):
```powershell
docker compose -f docker-compose.windows.yml up -d --force-recreate
docker exec hermes ls /workspace        # should list every repo
```

Drop into an interactive chat scoped to one project (assumes that project
has a `CLAUDE.md` / `AGENTS.md` with its conventions):

```powershell
pwsh "$DEPLOY\scripts\hermes-on.ps1" my-project
# or one-shot:
pwsh "$DEPLOY\scripts\hermes-on.ps1" my-project -Query "review the diff on this branch"
# isolated git worktree (lets you fan out parallel agents on the same repo):
pwsh "$DEPLOY\scripts\hermes-on.ps1" my-project -Worktree
# pick a different model:
pwsh "$DEPLOY\scripts\hermes-on.ps1" my-project -Model gpt-5.5 -Provider openai-codex
# list mounted projects:
pwsh "$DEPLOY\scripts\hermes-on.ps1" -List
```

The wrapper preloads a "production-grade" skill bundle by default
(`code-review-and-quality`, `test-driven-development`,
`debugging-and-error-recovery`, `security-and-hardening`,
`git-workflow-and-versioning`). Override with `-Skills "a,b,c"` or suppress
entirely with `-SkipSkills`.

**Caveats:**
- Subscription quotas (e.g. Claude's 5-hour window, Codex's weekly cap) apply
  exactly as they would inside the first-party CLIs.
- Anthropic / OpenAI ToS technically scope these tokens to their first-party
  clients. Hermes presents itself as a compatible client; treat the risk
  envelope the same as you would using any community CLI on the same token.
- The token files in `~/.hermes/auth.json` and `~/.hermes/.claude/` are
  long-lived refresh tokens. They're as sensitive as a logged-in browser
  session — the existing `~/.hermes` permissions (0700) protect them, but
  back them up with the same care you'd give a password manager export.

---

## Migration from bind-mount

Existing installs that use the legacy `${USERPROFILE}/.hermes` bind-mount
need to move state into the new `hermes-data` named volume before
restarting. One-shot:

```powershell
$DEPLOY = "C:\Users\$env:USERNAME\Documents\Git\hermes\deploy\hermes-agent"

# 1. Replace the live compose file with the updated one (the volume
#    declaration was added in this revision).
Copy-Item "$DEPLOY\docker-compose.windows.yml" "$env:USERPROFILE\hermes-agent\"

# 2. Migrate (stops containers, copies ~/.hermes into the named volume).
pwsh "$DEPLOY\scripts\migrate-to-named-volume.ps1"

# 3. Boot via the new launcher.
pwsh "$DEPLOY\scripts\start-hermes.ps1"

# 4. Push the volume's auth.json to BW so the next-host story is complete.
pwsh "$DEPLOY\scripts\hermes-restore.ps1" -Push

# 5. Verify everything works for a day or two, then (optional) delete the
#    legacy bind-mount directory:
Remove-Item -Recurse -Force "$env:USERPROFILE\.hermes"
```

## VPS / Mini PC migration (with BW as source of truth)

On the new host:

```bash
# 1. Install Docker (Linux example)
curl -fsSL https://get.docker.com | sh

# 2. Install Node + Bitwarden CLI + log into BW
sudo apt install -y nodejs npm
npx -y @bitwarden/cli login                       # one-time

# 3. Install PowerShell 7 (the launcher scripts are pwsh-only; Linux's
#    default `bash` doesn't run them). Microsoft ships an apt repo:
sudo apt install -y wget apt-transport-https
source /etc/os-release
wget -q https://packages.microsoft.com/config/ubuntu/$VERSION_ID/packages-microsoft-prod.deb
sudo dpkg -i packages-microsoft-prod.deb
sudo apt update && sudo apt install -y powershell

# 4. Clone this repo (no secrets in it)
git clone https://github.com/<you>/hermes
cd hermes/deploy/hermes-agent
mkdir -p ~/hermes-agent
cp docker-compose.windows.yml ~/hermes-agent/     # or wherever HermesDir is
cp .env.template ~/hermes-agent/.env              # edit HERMES_PROJECTS for Linux paths

# 5. Seed the named volume from BW (auth.json + OAuth refresh tokens).
pwsh ./scripts/hermes-restore.ps1                 # -Pull is the default

# 6. Boot
pwsh ./scripts/start-hermes.ps1
```

No `tar` of the old host's data dir. No `scp` of `auth.json`. BW is the
canonical store; Docker volumes are runtime caches that can be discarded
and re-seeded any time.

**Linux caveat**: the DPAPI session cache is Windows-only (uses
`System.Security.Cryptography.ProtectedData`, which on .NET/Linux throws
PlatformNotSupportedException). On Linux the master-password prompt
therefore fires once per shell that runs a launcher script.

To reduce prompts within a single shell session, unlock once and export
to that shell ONLY:

```bash
# Run interactively; do NOT add to ~/.bashrc or ~/.zshrc — those files
# are usually 644 (world-readable), and even at 600 the session key
# would be visible via /proc/<your-shell-pid>/environ to any same-user
# process for the lifetime of the shell.
read -s -p "BW master password: " BW_PW; echo
export BW_PW
export BW_SESSION=$(npx -y @bitwarden/cli unlock --raw --passwordenv BW_PW)
unset BW_PW
```

(`--passwordenv` reads the password from the named env var — no need to
also pipe it through stdin. The single channel keeps the example
unambiguous across BW CLI versions.)

For a longer-lived cache the right answer is `pass` or `gnome-keyring`
integration — a future change can swap a Linux-native KeyringProvider
into `bw-session.psm1`. PRs welcome.

## Day-to-day operations

```powershell
# Clean stop with auth.json push to BW (preferred over `docker stop`)
pwsh deploy\hermes-agent\scripts\stop-hermes.ps1

# Force a fresh master-pw prompt next time
pwsh deploy\hermes-agent\scripts\stop-hermes.ps1 -LockVault

# Status / logs (no key needed)
docker compose -f docker-compose.windows.yml ps
docker compose -f docker-compose.windows.yml logs -f gateway

# Restart (containers already have env from previous up)
docker compose -f docker-compose.windows.yml restart

# Stop (preserves volumes)
docker compose -f docker-compose.windows.yml down

# Re-launch after `down` — needs the Bitwarden pipeline again
pwsh ..\hermes\deploy\hermes-agent\scripts\start-hermes.ps1

# Upgrade upstream + rebuild
git pull
pwsh ..\hermes\deploy\hermes-agent\scripts\start-hermes.ps1 -Rebuild
```

`~/.hermes` survives `down` and image rebuilds — it lives on the host filesystem.

### Always-on / boot start

Docker Desktop → Settings → General → **Start Docker Desktop when you log in: ON**.
`restart: unless-stopped` in the compose file does the rest.

### RAM footprint

Idle ≈ 1.4 GB, peak ≈ 5 GB. On a 32 GB machine this leaves plenty for gaming.
If you want to stop Hermes during heavy game sessions:

```powershell
docker stop hermes hermes-dashboard
# later: docker start hermes hermes-dashboard
```

---

## Backups

The Hermes state lives in the `hermes-data` Docker named volume — NOT on
the host filesystem. The old `scripts/backup.ps1` (which tar'd
`~/.hermes`) no longer reflects the live data location and is kept only
for legacy bind-mount installs.

Today there are two backup paths, with different purposes:

- **OAuth credentials → Bitwarden vault** (`hermes-restore.ps1 -Push`).
  This is the only thing you need for a new-host bootstrap. Run it after
  every meaningful auth event (initial login, manual rotation, post-stop
  via `stop-hermes.ps1` which calls it for you).
- **Full volume snapshot → archive file**. Useful for full historical
  backups of sessions, memories, skills, etc.:
  ```powershell
  docker run --rm -v hermes-data:/data -v ${PWD}:/backup alpine `
      tar -czf /backup/hermes-data-$(Get-Date -Format yyyyMMdd-HHmmss).tar.gz -C /data .
  ```
  Restoring: `tar -xzf ...` into a freshly-created volume via the same
  pattern in reverse. (Not needed for the common new-host story — only
  if you want every session log to follow you across machines.)

The legacy `scripts/backup.ps1` against `$env:USERPROFILE\.hermes` is
useful only if you haven't yet run `migrate-to-named-volume.ps1`.

---

## Security checklist

- `.env` is gitignored. Verify before any `git add`.
- Dashboard port published to `127.0.0.1` only. Never change to `0.0.0.0`
  without putting an authenticating reverse proxy in front.
- `HERMES_UID=10000` is fine on Windows (UID mapping is irrelevant for Docker
  Desktop). On a Linux host, set `HERMES_UID=$(id -u)` so files on the host
  bind-mount are owned by your user.
- API server (`API_SERVER_*`) is **off by default**. Don't turn it on unless
  you understand the auth model — read `docs/user-guide/api-server.md` in the
  upstream repo first.

---

## Troubleshooting

| Symptom                                 | Fix                                                                 |
|-----------------------------------------|---------------------------------------------------------------------|
| `network_mode: host is not supported`   | You're running upstream's compose, not the Windows one. Use `-f docker-compose.windows.yml`. |
| Dashboard 9119 connection refused        | `docker compose ps` — confirm `dashboard` is `Up`. Check logs.       |
| `Permission denied` on `~/.hermes`      | On Linux only: set `HERMES_UID=$(id -u)` in `.env`, re-up.           |
| OOM during build                        | Docker Desktop → Resources → Memory ≥ 6 GB.                          |
| Container restart loop, `exit 127`      | `entrypoint.sh` got CRLF line endings on clone. See **CRLF fix** below. |
| Other restart loops                     | `docker compose logs gateway` — usually a missing/invalid API key.   |

### CRLF fix (Windows clone gotcha)

Git for Windows ships with `core.autocrlf=true` by default. When you clone
`hermes-agent`, every `.sh` (and many other text files) gets `\r\n` line
endings — the Linux kernel then can't find `/bin/bash\r` and the container
crashes with `exit 127` immediately on start.

Symptom check:
```bash
file /c/Users/$USER/hermes-agent/docker/entrypoint.sh
# bad:  "...with CRLF line terminators"
# good: "...UTF-8 text executable" (no CRLF mention)
```

One-time fix on the existing clone:
```powershell
cd C:\Users\$env:USERNAME\hermes-agent
git config core.autocrlf false
git rm --cached -r . | Out-Null
git reset --hard
# Re-copy deploy files (git reset overwrote them):
$DEPLOY = "C:\Users\$env:USERNAME\Documents\Git\hermes\deploy\hermes-agent"
Copy-Item -Force "$DEPLOY\docker-compose.windows.yml" .
Copy-Item -Force "$DEPLOY\.env.template" .env
# Rebuild:
$env:DEEPSEEK_API_KEY = "dummy"
docker compose -f docker-compose.windows.yml build gateway
```

Permanent (set BEFORE cloning, applies to all future clones on this machine):
```powershell
git config --global core.autocrlf input   # checkout LF, commit LF — safest
```
