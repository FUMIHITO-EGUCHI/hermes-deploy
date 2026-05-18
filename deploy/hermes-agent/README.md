# Hermes Agent — Portable Deploy (Windows + Docker Desktop / Future VPS)

Self-hosted [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent)
deployment configured for portability: install on the current gaming PC today,
move to a VPS or Mini PC tomorrow with zero config drift.

## Why this layout

Data and config are split into three movable pieces:

| Piece                          | Where                                   | Portable? |
|--------------------------------|-----------------------------------------|-----------|
| `docker-compose.windows.yml`   | Versioned in this repo                  | Yes       |
| `.env` (non-secret config)     | Local file (gitignored)                 | Manual copy |
| API keys (DeepSeek, etc.)      | Bitwarden vault                         | Migrate vault, not file |
| `~/.hermes` (state + skills)   | `C:\Users\<you>\.hermes` (host volume)  | tar.gz transfer |

API keys never touch disk: `scripts/start-hermes.ps1` unlocks Bitwarden and
pipes them into the container's process env at launch. To move to another
machine: copy compose + `.env` + `~/.hermes`, install Docker and Bitwarden
CLI (`npx -y @bitwarden/cli login`), run `start-hermes.ps1`.

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

### 4. Store the DeepSeek key in Bitwarden

Create a vault item (any name; the launcher defaults to `"DeepSeek API Key"`)
with one of the following:

- **Custom field** named `DEEPSEEK_API_KEY` with the key as the value, OR
- **Login password** containing the raw `sk-...` key.

Make sure the Bitwarden CLI is logged in once on this machine:

```powershell
npx -y @bitwarden/cli login        # one-time interactive login
```

### 5. Pre-create the data directory

```powershell
New-Item -ItemType Directory -Force -Path "$env:USERPROFILE\.hermes" | Out-Null
```

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
1. Checks Bitwarden vault status, prompts for master password if locked.
2. Reads `DEEPSEEK_API_KEY` field from the vault item.
3. Injects into the host shell's env (not into any file).
4. Runs `docker compose up -d` — compose forwards the env into both containers.
5. Scrubs the host env var on exit. `BW_SESSION` is kept so re-runs in the
   same shell skip the master-password prompt.

Custom vault item / field:
```powershell
pwsh "$DEPLOY\scripts\start-hermes.ps1" -Item "My DeepSeek Vault Entry" -FieldName "api_key"
```

The first build takes a while (Debian + Python + Node + ffmpeg).

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

---

## Day-to-day operations

```powershell
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

Snapshot the host data dir to a timestamped tar.gz:

```powershell
pwsh .\scripts\backup.ps1
```

This briefly stops the gateway, archives `~/.hermes`, restarts. Output lands in
`./backups/hermes-<timestamp>.tar.gz`. Add to Windows Task Scheduler for daily
runs if you want.

---

## Migrating to a VPS or Mini PC

The whole point of this layout. Three steps on the new machine:

1. **Install Docker** (any Linux: `curl -fsSL https://get.docker.com | sh`).

2. **Move the three pieces:**
   ```bash
   # On Windows: scp the tar.gz, .env, and the compose file
   scp backups/hermes-latest.tar.gz user@vps:~
   scp .env user@vps:~/hermes-deploy/
   scp docker-compose.windows.yml user@vps:~/hermes-deploy/docker-compose.yml

   # On the VPS: restore data dir
   mkdir -p ~/.hermes
   tar -xzf ~/hermes-latest.tar.gz -C ~     # creates ~/.hermes

   # Clone upstream for the build context
   git clone https://github.com/NousResearch/hermes-agent.git
   cp ~/hermes-deploy/docker-compose.yml hermes-agent/
   cp ~/hermes-deploy/.env hermes-agent/
   ```

3. **On Linux you can re-enable `network_mode: host` for fewer hops.** Either
   keep the Windows-safe `ports:` mapping (works fine), or apply this diff:
   ```yaml
   # remove `ports:` blocks
   # add to both services:
   network_mode: host
   ```

That's it. State, memories, skills, conversation history — all carry over.

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
