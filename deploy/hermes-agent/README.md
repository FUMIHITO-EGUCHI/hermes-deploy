# Hermes Agent — Docker Deploy (Windows + Docker Desktop / WSL2)

Thin Docker wrapper around [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent),
shaped for the upstream-intended usage: **one container, Hermes manages
its own state**. The host doesn't carry secrets, doesn't run wrapper
scripts, doesn't bind-mount your code into the container.

For project-level coding work, use your IDE / Claude Code / Codex
directly. Hermes here is a **personal AI hub** for chat, kanban, cron,
and messenger bots (Discord, Telegram, Slack, etc).

---

## What this repo contains

| File                                | Role                                                        |
|-------------------------------------|-------------------------------------------------------------|
| `docker-compose.windows.yml`        | Windows-safe compose (no `network_mode: host`, 127.0.0.1 ports) |
| `.gitignore`                        | Excludes runtime files                                      |
| `README.md`                         | This file                                                   |

Hermes' own state (auth.json, sessions, profiles, skills, kanban DB,
gateway config) lives in a Docker named volume `hermes-data`, managed
entirely by Hermes itself.

---

## Prerequisites

- Windows 11 with Docker Desktop (WSL2 backend, the default)
- `docker --version` ≥ 24
- `git` (any flavor)

```powershell
docker --version
docker compose version
```

---

## First-time install

### 1. Clone upstream Hermes Agent

```powershell
cd C:\Users\$env:USERNAME
git clone https://github.com/NousResearch/hermes-agent.git
cd hermes-agent
```

### 2. Drop in the Windows compose

```powershell
$DEPLOY = "C:\Users\$env:USERNAME\Documents\Git\hermes\deploy\hermes-agent"
Copy-Item "$DEPLOY\docker-compose.windows.yml" .
```

### 3. Build the image (first time only)

```powershell
docker compose -f docker-compose.windows.yml build
```

Takes several minutes — Debian + Python + Node + ffmpeg + browser deps.

### 4. Boot

```powershell
docker compose -f docker-compose.windows.yml up -d
```

Both containers come up:
- `hermes`           — gateway + API server (`:8642`)
- `hermes-dashboard` — Hermes built-in management UI (`:9119`)

### 5. Configure Hermes (one-shot, interactive)

```powershell
# Model + provider wizard
docker exec -it hermes hermes setup

# DeepSeek (static API key)
docker exec -it hermes hermes login deepseek
# Paste your key when prompted.

# Anthropic via Claude Pro/Max subscription (OAuth, browser flow)
docker exec -it hermes hermes login claude

# OpenAI Codex via ChatGPT subscription (device-code, browser flow)
docker exec -it hermes hermes login codex
```

Credentials land in `/opt/data/auth.json` inside the named volume.
**They never touch the host filesystem.** Host has no `.env`, no
plaintext keys, no BW scripts.

### 6. (Optional) Set up messenger gateways

```powershell
docker exec -it hermes hermes gateway setup
```

Interactive wizard for Discord, Telegram, Slack, etc. For Discord:
1. Create a bot at https://discord.com/developers/applications
2. Enable Message Content Intent
3. Copy the bot token, paste when the wizard asks
4. OAuth-invite the bot to your server (or use DM-only)

After setup, restart the gateway to pick up the new platform:
```powershell
docker exec hermes hermes gateway restart
```

---

## Daily use

```powershell
# Interactive chat in a terminal
docker exec -it hermes hermes chat

# Status / logs
docker compose -f docker-compose.windows.yml ps
docker compose -f docker-compose.windows.yml logs -f gateway

# Built-in dashboard (read-only viewer for sessions, skills, etc)
# http://127.0.0.1:9119

# OpenAI-compatible API server (for hermes-desktop, OpenWebUI, etc)
# http://127.0.0.1:8642/v1
# No bearer key required — loopback-only with `--insecure`.

# Stop / restart (containers preserve state in the named volume)
docker compose -f docker-compose.windows.yml restart
docker compose -f docker-compose.windows.yml down

# Re-boot
docker compose -f docker-compose.windows.yml up -d
```

Hermes is designed to be always-on. `restart: unless-stopped` on both
services + Docker Desktop's "start on login" setting = bot is always
reachable from your messenger.

### Pause Hermes during heavy gaming

Idle ≈ 1.4 GB, peak ≈ 5 GB. To free RAM:

```powershell
docker stop hermes hermes-dashboard
# later:
docker start hermes hermes-dashboard
```

---

## Backups

Hermes ships a built-in `hermes backup` command that zips the entire
`/opt/data` (config, skills, sessions, kanban, cron, auth.json) into a
portable archive. The repo includes a thin wrapper, `scripts/backup.ps1`,
that runs it inside the container, copies the zip out to a host
directory, and rotates old backups.

One-shot:
```powershell
pwsh -NoProfile -File deploy\hermes-agent\scripts\backup.ps1
# → writes to %USERPROFILE%\hermes-backups\hermes-<timestamp>.zip
# → keeps the 8 most recent by default
```

Custom path / retention:
```powershell
pwsh -NoProfile -File deploy\hermes-agent\scripts\backup.ps1 `
    -OutDir D:\hermes-backups -KeepLast 12
```

Automate via Windows Task Scheduler:

1. **Task Scheduler** → **Create Basic Task** → name `Hermes Weekly Backup`
2. **Trigger**: Weekly, pick a low-activity time
3. **Action**: Start a program
   - Program: `pwsh.exe`
   - Arguments: `-NoProfile -File "C:\Users\<you>\Documents\Git\hermes\deploy\hermes-agent\scripts\backup.ps1"`
4. **Conditions**: leave "Start only if computer is on AC power" OFF (desktop has no battery)
5. **Settings**: turn ON "Run task as soon as possible after a scheduled start is missed" (covers reboots)

Restore on a fresh host:
```powershell
docker cp ./hermes-YYYYMMDD-HHmmss.zip hermes:/opt/data/restore.zip
docker exec -it hermes /opt/hermes/.venv/bin/hermes import /opt/data/restore.zip
```

---

## Connecting clients

### hermes-desktop (remote mode)

[fathah/hermes-desktop](https://github.com/fathah/hermes-desktop) Electron client.
In remote mode it connects to `http://127.0.0.1:8642/v1` for chat.
Sessions / Profiles / Skills / Persona / Memory / Tools / Gateway tabs
are disabled in remote mode (the API server doesn't expose them in
Hermes 0.14.x — see upstream roadmap). **Chat works fine.**

### OpenWebUI / any OpenAI-compat client

Point at `http://127.0.0.1:8642/v1`. No bearer needed (loopback-only).

### Discord / Telegram / Slack

After `hermes gateway setup`, the bot is always-on. DM it or @mention
in an allowed channel; it responds using whichever model you set as
default.

---

## Browser tooling — stealth Chromium sidecar (optional)

Hermes' `browser_*` tools (web navigation, content extraction, form
filling) need a Chromium engine. By default they spawn the built-in
`agent-browser` headless CLI inside the container — fine for plain
sites, blocked by Cloudflare Turnstile / FingerprintJS / reCAPTCHA.

For protected sites the compose file ships an opt-in
[CloakBrowser](https://github.com/CloakHQ/CloakBrowser) sidecar:
a real Chromium binary with 58 C++ source-level fingerprint patches.
Hermes connects to it via CDP — no code changes needed, the existing
`BROWSER_CDP_URL` override path picks it up.

### Enable

```powershell
$env:BROWSER_CDP_URL = "http://hermes-cloakbrowser:9222"
docker compose -f docker-compose.windows.yml --profile browser up -d
```

The `--profile browser` flag boots the `cloakbrowser` service alongside
gateway/dashboard. First `up -d` pulls ~200 MB (Chromium + Xvfb +
Python wrapper). Subsequent boots reuse the cached image.

Verify:
```powershell
docker compose -f docker-compose.windows.yml ps cloakbrowser
docker exec hermes-cloakbrowser curl -s http://localhost:9222/json/version
```

### Disable

Re-boot without the profile / env:
```powershell
Remove-Item Env:\BROWSER_CDP_URL
docker compose -f docker-compose.windows.yml stop cloakbrowser
docker compose -f docker-compose.windows.yml up -d        # gateway picks up empty env on next restart
```

Hermes falls back to the built-in `agent-browser` headless CLI.

The sidecar uses `restart: "no"` (unlike gateway/dashboard's
`unless-stopped`), so a host reboot leaves it down until you re-run
`up -d --profile browser` — preserving the opt-in guarantee.

### Network exposure

The CDP endpoint at `hermes-cloakbrowser:9222` is unauthenticated, but
not reachable from the host (no `ports:` mapping). It IS reachable from
any other service on the default compose network — current setup is
just gateway/dashboard, both trusted. If you add a third service in the
future that doesn't need browser access (a metrics exporter, a webhook
listener, etc), put it on a separate `networks:` block; CDP can navigate
to arbitrary URLs and read sandboxed local files, so a compromised
sibling service could pivot through it.

### License & scope notes

- **Wrapper**: MIT — fine to copy / fork.
- **Binary**: royalty-free for personal + commercial use, NOT
  redistributable. We use the official `cloakhq/cloakbrowser` image
  unmodified, which is the permitted path. Do not rebuild / fork the
  image without reading
  [BINARY-LICENSE.md](https://github.com/CloakHQ/CloakBrowser/blob/main/BINARY-LICENSE.md).
- **Ethics**: bypassing bot detection is grey area for the target
  sites' ToS. Hermes does not enforce that; you do. Reserve this for
  pages you have a legitimate reason to access.

---

## Security posture

- All published ports bound to `127.0.0.1`. LAN cannot reach the
  container directly.
- Credentials live in the named volume (`/var/lib/docker/volumes/hermes-data/`
  on Linux; inside the WSL2 VM's ext4 on Windows + Docker Desktop).
  Not accessible to host user-level processes; reachable only via the
  docker socket.
- The dashboard process serves API keys to its UI — this is why we bind
  loopback-only. Never publish 9119 to LAN without a auth proxy.
- For remote access (mobile, other LAN devices): SSH tunnel into
  loopback, or wrap with Tailscale, or run the messenger bot path.

---

## Troubleshooting

| Symptom                                  | Fix                                                                 |
|------------------------------------------|---------------------------------------------------------------------|
| `network_mode: host is not supported`    | You're running upstream's `docker-compose.yml`. Use `-f docker-compose.windows.yml`. |
| Container restart loop, `exit 127`       | `entrypoint.sh` has CRLF line endings. See **CRLF fix** below.       |
| Other restart loops                      | `docker compose logs gateway` — usually a missing or invalid provider credential. Run `hermes login <provider>` again. |
| OOM during build                         | Docker Desktop → Resources → Memory ≥ 6 GB.                          |
| `--insecure` warning in logs             | Expected. The flag is required because we bind 0.0.0.0 inside the container; host exposure is loopback-only via `ports:`. |
| Dashboard 9119 connection refused        | `docker compose ps` — confirm `dashboard` is `Up`. Check logs.       |

### CRLF fix (Windows clone gotcha)

Git for Windows ships with `core.autocrlf=true`. When you clone
`hermes-agent` on Windows, every `.sh` gets `\r\n` line endings — the
container then can't find `/bin/bash\r` and crashes with `exit 127`.

```powershell
cd C:\Users\$env:USERNAME\hermes-agent
git config core.autocrlf false
git rm --cached -r . | Out-Null
git reset --hard
# Re-copy the deploy compose (git reset overwrote it):
Copy-Item -Force "$DEPLOY\docker-compose.windows.yml" .
docker compose -f docker-compose.windows.yml build gateway
```

Permanent (set before cloning, applies to all future clones):
```powershell
git config --global core.autocrlf input   # checkout LF, commit LF
```

---

## Why no host scripts / no Bitwarden / no /workspace mount?

Earlier iterations of this deploy layered:
- a Bitwarden vault as the single source of truth for credentials,
- a `start-hermes.ps1` launcher that unlocked BW and injected env vars,
- a `/workspace` bind-mount + `hermes-on.ps1` per-project chat scoper.

Those layers solved problems Hermes already solves internally:
- Hermes has its own credential pool (`hermes auth`, `hermes login`,
  `auth.json` with OAuth refresh + rotation).
- Hermes has its own backup/restore (`hermes backup` / `hermes import`).
- Hermes has its own messenger gateway for "reach the agent from
  anywhere" (no need for a remote chat client wrapper).

For our single-user, single-host setup, doubling those concerns was net
negative — more code to maintain, two places that could disagree,
extra startup steps. This deploy is now a thin wrapper: just enough
glue to make `docker compose up` work on Windows + Docker Desktop, and
let Hermes do everything else.

If you need cross-host migration: `hermes backup` → copy zip → `hermes
import` on the new host. That's the upstream path.
