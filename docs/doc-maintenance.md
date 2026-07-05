# ドキュメント・メモリの棚卸し手順

**不定期・オンデマンド**で回す整備作業。「ドキュメントの陳腐化を見直して」「棚卸しして」等の指示で実施する。定期トリガー（cron / 毎リリース）は設けない。

放置すると CLAUDE.md / docs / メモリは陳腐化・肥大・配置ミスが溜まる。毎セッション全読される CLAUDE.md とメモリのノイズを下げ、公開／非公開の境界を保つのが目的。

## 配置の原則（正本）

| 置き場 | 公開範囲 | 何を置くか |
|---|---|---|
| `docs/`（GitHub・**公開**） | 公開 | プロジェクトの規約・設計方針・運用手順・再発する技術罠（[tech-notes.md](tech-notes.md)） |
| `MEMORY.md` + `memory/*`（Google Drive 共有・**非公開**） | 全端末で共有・非公開 | Claude 向け作業ルール（feedback）・端末固有値・GitHub / コードから導けない状態や判断経緯 |
| `docs/archive/`（GitHub・公開） | 公開 | 役目を終えた設計書・計画・廃止手順（参照はするが現役運用しない） |

判断の軸:

- **公開境界**: `docs/` は公開リポジトリ。secrets・端末固有値（UDID / Key ID / 個人ディレクトリパス / SDK パス）・特定運用者の私的判断は置かない → memory へ。
- **二重管理禁止**: GitHub Issues / Releases / Milestones が正本の情報を docs / memory に複写しない。
- **メモリはポインタ運用**: 再発する技術罠の正本は docs（tech-notes 等）に置き、memory 側は一行ポインタ＋「なぜ非自明か」だけ残す構成を既定とする。
- **メモリの役割分担**: `MEMORY.md` は Claude 向け作業ルールと端末固有情報のみ。プロジェクトの規約・方針・手順は docs に書く。

## 手順

### 1. CLAUDE.md の陳腐化改善

- 概念部（前半・リリースログを除く）を通読し、基本事実の陳腐化を洗う: 対象プラットフォーム／配布、機能マッピングの「予定／未実装」、バージョン表記、完了済みなのに「将来／当面」と書かれた記述。
- grep シグナル例: `予定|未実装|現時点|当面|将来|Android / iOS|iPad|TestFlight 止め`。
- **必ずコード／GitHub で裏取りしてから直す**。「対応予定 → 実装済み」の判定は adapter の mixin 宣言や Issue の close 状況を確認する。推測で断定しない（[[feedback_pull_before_asserting]] の精神）。
- リリースログの肥大は本手順では触らない。[milestone-transition.md](milestone-transition.md) の「リリースログのトリム」（step 7）で別途処理する。

### 2. メモリ → docs（共有すべき知見の昇格）

- `memory/*.md` を走査し、「全端末＋人間にも有益な一般知識（規約・手順・再発する技術罠）」で、かつ**非公開情報を含まない**ものを抽出する。
- docs の該当箇所へ移す: 技術罠 → [tech-notes.md](tech-notes.md)、手順 → 対応する `*-procedure` / guide、方針 → [CLAUDE.md](CLAUDE.md)。
- 移した後、memory 側は削除するか、一行ポインタ＋非自明ポイントだけ残す（値でなく docs パス参照にする）。
- **昇格しない**: feedback 系（Claude 向け作業ルール）・端末固有値・特定運用者の判断は docs に上げない。

### 3. docs → メモリ（プライベート記述の退避）

- `docs/` を走査し、公開リポジトリに載せるべきでない記述を抽出する: secrets / 鍵 ID、端末固有値（UDID・SDK パス・個人ディレクトリ）、特定運用者の私的判断・経緯。
- `memory/reference_*` か `project_*` へ移し、docs 側は公開して良い一般記述に置換する（「正本は memory 側」のポインタは docs に残してよいが、値そのものは memory に置く）。
- 先例: 端末固有値は `reference_dev_environment_specifics`、secrets 実体の場所は `reference_secrets_env_location`。

### 4. 役目を終えた docs のアーカイブ

- 現役運用しないが履歴・経緯として残す価値がある docs（完了した設計書・計画・廃止された手順）を `docs/archive/` へ移動する。
- 移動後、参照元（CLAUDE.md ほか）のリンクを `archive/` パスへ更新する。ファイル冒頭に「アーカイブ（現役運用では参照しない）」の一行を付ける。
- 完全に無価値なものは削除してよい（GitHub 履歴に残るため復元可能）。

## 実施後

- 変更は docs 修正の commit で残す（memory は Google Drive 同期のため commit 不要）。
- 大きく動かした場合は `MEMORY.md` の索引と関連 `[[リンク]]`、CLAUDE.md のディレクトリ構成・参照リンクの整合を確認する。
