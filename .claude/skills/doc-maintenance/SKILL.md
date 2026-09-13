---
name: doc-maintenance
description: docs / CLAUDE.md / メモリの棚卸し。「ドキュメントの陳腐化を見直して」「棚卸しして」で回す。陳腐化改善・メモリ→docs の昇格・docs→メモリの退避・インフラ記述の infra-note 移設・役目を終えた docs のアーカイブ。不定期・オンデマンド。
---

# ドキュメント・メモリの棚卸し手順

**不定期・オンデマンド**で回す整備作業。定期トリガー（cron / 毎リリース）は設けない。

⚠⚠ **正本はこのファイル (#1114)。**[docs/doc-maintenance.md](../../../docs/doc-maintenance.md) には**判断の側（配置の原則・メモリは status を持たない）**が残っている。⚠ **こちらは「回す手順」だけ。**どこに何を置くかで迷ったら向こうを読む —— **あれは棚卸しのときだけ効くルールではない**（メモリを 1 本書くたびに効く）ので、手順の中に埋めない。

## 手順

### 1. CLAUDE.md の陳腐化改善

- 概念部（前半・リリースログを除く）を通読し、基本事実の陳腐化を洗う: 対象プラットフォーム／配布、機能マッピングの「予定／未実装」、バージョン表記、完了済みなのに「将来／当面」と書かれた記述。
- grep シグナル例: `予定|未実装|現時点|当面|将来|Android / iOS|iPad|TestFlight 止め`。
- **必ずコード／GitHub で裏取りしてから直す**。「対応予定 → 実装済み」の判定は adapter の mixin 宣言や Issue の close 状況を確認する。推測で断定しない（[[feedback_pull_before_asserting]] の精神）。
- リリースログの肥大は本手順では触らない。[milestone-transition](../milestone-transition/SKILL.md) の「リリースログのトリム」（step 7）で別途処理する。

### 2. メモリ → docs（共有すべき知見の昇格）

- `memory/*.md` を走査し、「全端末＋人間にも有益な一般知識（規約・手順・再発する技術罠）」で、かつ**非公開情報を含まない**ものを抽出する。
- docs の該当箇所へ移す: 技術罠 → [tech-notes.md](../../../docs/tech-notes.md)、**手順 → 対応するスキル（`.claude/skills/<名前>/SKILL.md`・#1114）**、方針 → [CLAUDE.md](../../../docs/CLAUDE.md)。
- 移した後、memory 側は削除するか、一行ポインタ＋非自明ポイントだけ残す（値でなく docs パス参照にする）。
- **昇格しない**: feedback 系（Claude 向け作業ルール）・端末固有値・特定運用者の判断は docs に上げない。

### 3. docs → メモリ（プライベート記述の退避）

- `docs/` を走査し、公開リポジトリに載せるべきでない記述を抽出する: secrets / 鍵 ID、端末固有値（UDID・SDK パス・個人ディレクトリ）、特定運用者の私的判断・経緯。
- `memory/reference_*` か `project_*` へ移し、docs 側は公開して良い一般記述に置換する（「正本は memory 側」のポインタは docs に残してよいが、値そのものは memory に置く）。
- 先例: 端末固有値は `reference_dev_environment_specifics`、secrets 実体の場所は `reference_secrets_env_location`。

### 4. docs → infra-note（インフラ記述の移設）

capsicum は公開リポジトリなので、**サーバーインフラの内部情報を公開 docs に置かない**。共有正本は chubo2（private）の [infra-note.md](https://github.com/pooza/chubo2)（`docs/infra-note.md`）。モロヘイヤ/chubo2 側 `docs/doc-maintenance.md` の「memory → infra-note 昇格」と対になる運用で、あちらが**セッションメモリ**を、こちらが**公開 docs**を入口にする。

- 走査対象（移設候補のシグナル）: 内部 SSH ホスト名（`*.b-shock.local` / SSH 接続先の `*.b-shock.co.jp`、例 `flauros`）・ホスティング業者/プラン（Linode / Nanode / VPS スペック / server の OS 版）・deploy ユーザー名・server 側の `systemctl` / `journalctl` / `nginx` / `certbot` / デプロイコマンド・内部 IP（192.168.x.x）・puma / sqlite 等のサーバー内部。
- 見つけたら infra-note へ移す（既に載っていれば確認のみ。infra-note は非常に手厚いので**大半は「既にある → 公開 docs 側を剥がすだけ」**になる）。公開 docs 側は一般表現に置換する。
- **ポインタの張り方**: 公開 docs から private な infra-note へは直リンクできない。文字列で「chubo2 `docs/infra-note.md` が正本」と書くか、メモリ（例 `feedback_capsicum_relay_deploy_delegation`）経由にする。メモリに逐語コマンドが残っているなら、それも infra-note に寄せてメモリ側はポインタ＋作業上の注意だけにする（二重管理禁止）。
- **移さないもの**: クライアントが接続する公開エンドポイント（`relay.capsicum.shrieker.net` 等）・自前 SNS サーバーの公開ドメイン（`mstdn.b-shock.org` 等）・公開リポジトリで既に開示済みの実装スタック（capsicum-relay の Ruby + Sinatra 等）・Sentry org サブドメイン。
- infra-note は別リポジトリなので変更は**PR にする**（chubo2 の慣習）。冒頭「最終ドキュメント棚卸し」を当日に更新する。

### 5. 役目を終えた docs のアーカイブ

- 現役運用しないが履歴・経緯として残す価値がある docs（完了した設計書・計画・廃止された手順）を `docs/archive/` へ移動する。
- 移動後、参照元（CLAUDE.md ほか）のリンクを `archive/` パスへ更新する。ファイル冒頭に「アーカイブ（現役運用では参照しない）」の一行を付ける。
- 完全に無価値なものは削除してよい（GitHub 履歴に残るため復元可能）。⚠ **現役の運用参照が残っている docs はアーカイブしない**（例: 出荷済み機能の設計ドラフトでも、審査回答文など提出のたび再利用する節があれば docs に残し、冒頭に「実装済み・以下は当時の下書き」バナーを付けて未来形の誤読だけ封じる）。

## 実施後

- 変更は docs 修正の commit で残す（memory は Google Drive 同期のため commit 不要）。infra-note（chubo2）を触った場合はそちらは別途 PR。
- 大きく動かした場合は `MEMORY.md` の索引と関連 `[[リンク]]`、CLAUDE.md のディレクトリ構成・参照リンクの整合を確認する。
