# hermes-deploy

[NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) を **Windows + Docker** で自己ホストするための薄いラッパー。upstream の意図に沿った「Hermes が自分の状態を自分で管理する」設計に倒し、host 側のスクリプトや秘密ストアを最小化。

> 主役は `deploy/hermes-agent/` 配下。詳細は **[`deploy/hermes-agent/README.md`](deploy/hermes-agent/README.md)**。

---

## 何ができるか

- **常駐 Hermes container**: gateway + dashboard 2 サービス、`restart: unless-stopped`
- **多経路アクセス**: OpenAI 互換 API (`:8642/v1`)、Hermes 内蔵 dashboard (`:9119`)、CLI (`docker exec`)、Discord/Telegram/Slack bot (gateway)
- **Hermes 内蔵機能で完結**: provider 認証 (`hermes login`)、backup (`hermes backup`)、messenger 設定 (`hermes gateway setup`)、cron / kanban / skills
- **secret は container 内**: `auth.json` が named volume に閉じ、host filesystem には鍵が一切残らない

---

## クイックスタート

```powershell
# 1) upstream hermes-agent を build context として clone
cd C:\Users\$env:USERNAME
git clone https://github.com/NousResearch/hermes-agent.git
cd hermes-agent

# 2) 本リポの compose を持ち込む
$DEPLOY = "C:\Users\$env:USERNAME\Documents\Git\hermes\deploy\hermes-agent"
Copy-Item "$DEPLOY\docker-compose.windows.yml" .

# 3) build + up
docker compose -f docker-compose.windows.yml build
docker compose -f docker-compose.windows.yml up -d

# 4) 初回設定 (対話式、container 内で完結)
docker exec -it hermes hermes setup
docker exec -it hermes hermes login deepseek   # or claude / codex
docker exec -it hermes hermes gateway setup    # Discord 等を有効化したい時

# 5) 使う
docker exec -it hermes hermes chat             # terminal chat
# http://127.0.0.1:9119                         # 内蔵 dashboard
# http://127.0.0.1:8642/v1                      # OpenAI 互換 API (hermes-desktop 等)
# Discord/Telegram bot — gateway 設定後は messenger から
```

詳細は [`deploy/hermes-agent/README.md`](deploy/hermes-agent/README.md)。

---

## ディレクトリ

| パス | 役割 |
|---|---|
| `deploy/hermes-agent/docker-compose.windows.yml` | Windows-safe compose (127.0.0.1 only ports、named volume) |
| `deploy/hermes-agent/README.md` | デプロイ・運用ドキュメント |
| `docs/` | ADR / handoff ガイド (テンプレート由来、運用しながら更新) |
| `.github/` | Issue テンプレ / ラベル / dependabot / セキュリティ CI / Claude AI レビュー |

---

## セキュリティ姿勢

- **port は loopback only**: `127.0.0.1:8642` (API) / `127.0.0.1:9119` (dashboard)。LAN 不到達
- **secret は container 内**: `auth.json` を named volume に閉じる。host filesystem 経由のトークン露出を排除
- **`--insecure` の使用**: gateway / dashboard は container 内 `0.0.0.0` bind が必須 (Docker port-mapping の制約)。host 側 publish が loopback only なので exposure は限定
- **依存ピン**: `package.json` の `overrides` で transitive (koa / multer / node-forge / tmp) を固定。`npm audit` 0 件
- **CI**: `.github/workflows/security.yml` で gitleaks / Trivy / shellcheck / semgrep を SHA pin 並列実行

---

## ガバナンス基盤 (テンプレート由来)

[`FUMIHITO-EGUCHI/claude-project-template`](https://github.com/FUMIHITO-EGUCHI/claude-project-template) から取り込んだ Issue / PR レビュー基盤:

- **`.github/workflows/claude-issue-triage.yml`** — Issue 作成時に `model:` / `type:` / `area:` を自動付与
- **`.github/workflows/claude-pr-review.yml`** — PR 作成時に correctness / readability / architecture / security / performance の 5 軸レビュー + Learning notes
- **`.github/workflows/security.yml`** — gitleaks / Trivy / shellcheck / semgrep
- **`.github/labels.yml`** — `status:` / `model:` / `owner:` / `priority:` / `type:` / `area:` の 6 軸ラベル
- **`scripts/commit-msg`** — `#<issue>` または `[skip-issue]` を commit message に強制
- **`docs/decisions/`** — ADR (Template strategy / Issue SoT / Human acceptance + Learning loop)

---

## ライセンス

MIT — [LICENSE](LICENSE) 参照。

Hermes Agent (NousResearch) 本体は upstream のライセンスに従う。本リポは **デプロイラッパーのみ** を提供し、Hermes Agent のソースコードは含まない。
