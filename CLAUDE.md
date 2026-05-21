<!-- @template:notice-start -->
> **Note**: このファイルは [`claude-project-template`](https://github.com/FUMIHITO-EGUCHI/claude-project-template) の一部。`sh scripts/init-project.sh` で展開すると、この通知ブロックは削除され、プレースホルダがプロジェクト名・概要に置換される。
<!-- @template:notice-end -->

# <!-- @project:name -->

<!-- @project:description -->

## 技術スタック

- 構成物: `deploy/hermes-agent/docker-compose.windows.yml` (Hermes Agent コンテナ起動定義)
- 実行環境: Windows 11 + Docker Desktop (WSL2 backend)、PowerShell 7
- 言語ランタイム不要: アプリ本体は upstream の Hermes Agent (Python) が container 内で完結。本リポは設定だけを管理

## コマンド

このリポ自体にビルド対象はない。動作確認は変更対象に応じて選ぶ:

| コマンド | 用途 |
|---|---|
| `docker compose -f deploy/hermes-agent/docker-compose.windows.yml config` | compose 設定検証 |
| `docker compose -f deploy/hermes-agent/docker-compose.windows.yml up -d` | compose 起動 |
| `docker exec -it hermes /opt/hermes/.venv/bin/hermes status` | ヘルスチェック |

完了報告前は変更箇所の手動確認 (compose ならコンテナ再起動で立ち上がるか) を行う。

## タスク管理（AI handoff）

タスクは **GitHub Issues + Projects v2** で管理する。

- 作業開始時: Issue を選んで `status: in-progress` ラベルを付ける
- 作業中: Issue コメントに逐次追記。本文は objective / scope / checklist のみ編集
- 完了申請: `status: ready-for-close` ラベル + `## Result` / `## Verification` / `## Changed files` を含むコメント
- **close は人間のみ**。AI は close しない
- commit message は `#<issue>` を必須（雑務は `[skip-issue]`）。`commit-msg` hook が強制
- AI 間 handoff は `docs/handoff/README.md` の雛形に従う
- Issue 作成時に `model:` ラベル（`cheap-ok` / `standard` / `strong-required`）を1つ付与。判断材料は `task.yml` の "強いモデルを要する兆候" チェックボックス

詳細は `docs/handoff/README.md` を参照。AI 実行制御（GitHub Actions ルーティング、`model:` ラベル運用、コスト管理）は `docs/handoff/ai-execution.md`。他 PJ に展開する手順は `docs/handoff/bootstrap.md`。運用ルールの根拠は ADR（`docs/decisions/0002-github-operation-sot.md` / `0003-human-acceptance-and-ai-tutor.md`）。

## ディレクトリ構造

| パス | 役割 |
|---|---|
| `deploy/hermes-agent/docker-compose.windows.yml` | Hermes Agent コンテナ定義 (Windows + Docker Desktop) |
| `deploy/hermes-agent/README.md` | デプロイ・運用手順 |
| `docs/handoff/` | AI handoff（Issue ベース）の運用ガイド |
| `docs/decisions/` | ADR |

## 行動原則

- 3ステップ以上のタスクは、実装前に目的・手順・未確定事項を整理する
- 関連ファイルと既存実装を読まずにコードを書かない
- 変更は小さく保つ
- 不確実な情報は未確認と明示し、公式ドキュメントかソースコードで裏取りする
- Claude の主担当は要件整理、調査、ブラウザデバッグ。大きな実装は Codex へ渡しやすい形に整理する

詳細な path-scoped ルールは `.claude/rules/` を参照。
