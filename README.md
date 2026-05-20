# hermes-deploy

[NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) を **Windows + Docker** で自己ホストするためのデプロイラッパー。将来的に Linux / ARM (Mini PC / VPS) へ持ち運べるよう、設定とシークレットを Bitwarden に集約する設計。

> 主役は `deploy/hermes-agent/` 配下。詳細は **[`deploy/hermes-agent/README.md`](deploy/hermes-agent/README.md)** に集約してある。本ファイルはリポジトリ全体の入り口。

---

## 何ができるか

- **Bitwarden 経由のシークレット管理** — API キー・OAuth トークン・`auth.json` をすべて BW vault に格納。Windows DPAPI でセッションキャッシュし、マスターパスワード入力は 1 日 1 回程度。
- **双方向同期** — BW vault ↔ Docker named volume (`hermes-data`) を `hermes-restore.ps1 -Pull / -Push` で同期。
- **OAuth プロビジョニング** — Codex (device-code) / Claude PKCE / `sk-ant-oat01-*` setup-token を `setup-providers.ps1` で一括セットアップ。
- **スコープ付きチャット起動** — `hermes-on.ps1 <project>` で `/workspace/<project>` を cwd にした Hermes Agent チャットを開く。`AGENTS.md` / `CLAUDE.md` 自動ロード。
- **AutoRoute モード** — `-AutoRoute` フラグで DeepSeek-V4 (flash) を親エージェントに据え、`delegate_task` で Opus 4.7 / GPT-5.5 に重い判断だけ委譲。プロンプトキャッシュでコスト最適化。
- **ライフサイクル** — `start-hermes.ps1` (起動 + シークレット注入) / `stop-hermes.ps1` (停止 + BW 最終 push)。

---

## クイックスタート

前提: Docker Desktop / PowerShell 7+ / Bitwarden CLI (グローバル or npx)。

```powershell
# 1) リポジトリ取得
git clone https://github.com/FUMIHITO-EGUCHI/hermes-deploy.git
cd hermes-deploy

# 2) .env 作成 (秘密値はここに書かない。BW vault から起動時に注入される)
cp deploy/hermes-agent/.env.template deploy/hermes-agent/.env
# HERMES_DATA / HERMES_PROJECTS だけ自分の環境に合わせる

# 3) 初回 OAuth セットアップ (Bitwarden → vault に書き込み + auth.json を named volume へ展開)
pwsh deploy/hermes-agent/scripts/setup-providers.ps1

# 4) 起動
pwsh deploy/hermes-agent/scripts/start-hermes.ps1

# 5) プロジェクトを指定してチャット (常用)
pwsh deploy/hermes-agent/scripts/hermes-on.ps1 <project>
# DeepSeek-V4 親 + Opus / GPT-5.5 委譲モード:
pwsh deploy/hermes-agent/scripts/hermes-on.ps1 <project> -AutoRoute
```

詳細手順・各オプション・移行ガイドは [`deploy/hermes-agent/README.md`](deploy/hermes-agent/README.md)。

---

## ディレクトリ

| パス | 役割 |
|---|---|
| `deploy/hermes-agent/` | 本リポの主役。compose ファイル + PowerShell スクリプト群 + `auto-route-deepseek` スキル |
| `deploy/hermes-agent/scripts/bw-session.psm1` | Bitwarden CLI ラッパー (DPAPI セッションキャッシュ + stderr base64 redaction) |
| `deploy/hermes-agent/scripts/hermes-on.ps1` | スコープ付きチャット起動 (`-AutoRoute` モード対応) |
| `deploy/hermes-agent/scripts/hermes-restore.ps1` | BW vault ↔ named volume の双方向同期 |
| `deploy/hermes-agent/scripts/setup-providers.ps1` | Codex / Claude OAuth プロビジョニング |
| `deploy/hermes-agent/scripts/start-hermes.ps1` / `stop-hermes.ps1` | ライフサイクル |
| `deploy/hermes-agent/skills/auto-route-deepseek/SKILL.md` | DeepSeek 親エージェント用ルーティング誘導スキル |
| `src/` | TypeScript コア (cost 計算、prompts 構築、Bitwarden 補助、DeepSeek プロバイダ) |
| `test/` | TypeScript コアのテスト |
| `docs/` | ADR / handoff ガイド / セキュリティチェックリスト (テンプレート由来、運用しながら更新中) |
| `.github/` | Issue テンプレ / ラベル / dependabot / セキュリティ CI / Claude AI レビュー (テンプレート由来) |

---

## セキュリティ姿勢

[セキュリティ監査](https://github.com/FUMIHITO-EGUCHI/hermes-deploy/pull/2) 済 (Critical / High 0 件)。主要設計:

- **シークレットは argv に乗せない**: BW_SESSION や OAuth トークンは `Invoke-BwInternal` の `ExtraEnv` 経由でプロセス環境にのみ渡し、終了時に `[Environment]::SetEnvironmentVariable($null, 'Process')` で物理削除。WMI / Process Explorer から見えない。
- **stderr 2 パスレダクション**: BW CLI の stderr を「セッション完全一致 → base64 正規表現」の 2 段で `[REDACTED-*]` に置換してからログ出力。
- **平文をホスト FS に置かない**: `auth.json` の復号バイト列は alpine コンテナの stdin 経由で named volume に直接書き込み。ホストのファイルシステムには一切触れない。
- **JSON バリデーション**: BW push 時も pull 時も `providers` キーの存在をチェック。corrupted vault / corrupted volume の双方向防御。
- **named volume**: bind-mount から `hermes-data` 名前付きボリュームへ移行済。Windows ホストの `CodexSandboxUsers` ACL 経由でのトークン露出を排除。
- **依存ピン**: `package.json` の `overrides` で transitive (koa / multer / node-forge / tmp) を最新版に固定。`npm audit` 0 件。
- **CI**: `.github/workflows/security.yml` で gitleaks / Trivy / shellcheck / semgrep を SHA pin 並列実行。

---

## ガバナンス基盤 (テンプレート由来)

[`FUMIHITO-EGUCHI/claude-project-template`](https://github.com/FUMIHITO-EGUCHI/claude-project-template) から取り込んだ Issue / PR レビュー基盤:

- **`.github/workflows/claude-issue-triage.yml`** — Issue 作成時に `model:` / `type:` / `area:` を自動付与
- **`.github/workflows/claude-pr-review.yml`** — PR 作成時に correctness / readability / architecture / security / performance の 5 軸レビュー + Learning notes
- **`.github/workflows/security.yml`** — gitleaks / Trivy / shellcheck / semgrep
- **`.github/labels.yml`** — `status:` / `model:` / `owner:` / `priority:` / `type:` / `area:` の 6 軸ラベル
- **`scripts/commit-msg`** — `#<issue>` または `[skip-issue]` を commit message に強制
- **`docs/decisions/`** — ADR (Template strategy / Issue SoT / Human acceptance + Learning loop)

運用詳細は [`docs/handoff/README.md`](docs/handoff/README.md) と [`docs/handoff/ai-execution.md`](docs/handoff/ai-execution.md)。

---

## ライセンス

MIT — [LICENSE](LICENSE) 参照。

Hermes Agent (NousResearch) 本体は upstream のライセンスに従う。本リポは **デプロイラッパーのみ** を提供し、Hermes Agent のソースコードは含まない。
