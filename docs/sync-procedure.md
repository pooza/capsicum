# セッション開始時の同期手順

会話の最初に「進捗を同期してください」等の指示があった場合、以下の手順を実行する。

## 1. プロジェクトガイドの読み込み

- `docs/CLAUDE.md` を読む（プロジェクトのルール・構造・履歴の正本）
- インフラノート `/Volumes/extdata/repos/chubo2/docs/infra-note.md` を読む（サーバー構成・デプロイ手順）
- `MEMORY.md` は自動ロードされるので、両者の整合性を意識する

## 2. リモートとの同期・状態確認

- `git fetch origin` — **最初に必ず実行**。リモートが正本であり、ローカルの状態を信用しない
- `git log HEAD..origin/develop --oneline` — リモートに未取り込みのコミットがないか確認。差分があれば pull を検討
- `git log --oneline -10` — 直近のコミット履歴
- `git tag --sort=-creatordate | head -5` — 直近のリリースタグを確認
- `gh release list --limit 5` — 最近の GitHub Releases を確認
- `gh api repos/pooza/capsicum/milestones --jq '.[] | "\(.title) \(.state) \(.closed_at // "open")"'` — マイルストーンの open/closed 状態を確認
- 前回同期時点と比較して新しいリリースがあれば、実装ステータスやリリース計画セクションに反映する

## 3. Issue・PR の確認

- `gh issue list --state open --limit 100` — open Issue 一覧（**`--limit 100` を必ず指定**。デフォルト 30 件では古い Issue が取得漏れする）
- `gh pr list --state open` — open PR 一覧
- `gh issue list --state closed --limit 10` — 最近クローズされた Issue（前回同期以降の進捗把握）
- マイルストーン未割り当ての open Issue を一覧として列挙する（割り当てを促す文言は不要）

## 4. ユーザーフィードバックの確認（#capsicum タグタイムライン）

- 美食丼の `#capsicum` タグタイムラインを取得: `curl -s "https://mstdn.b-shock.org/api/v1/timelines/tag/capsicum?limit=20"`
- バグ報告・機能要望・ユーザーからの質問がないか確認する
- 未起票のバグ報告があれば GitHub Issue を起票する（報告元の投稿 URL を記載）
- 好評・感想は報告のみ（Issue 化不要）

## 5. マイルストーンの状態確認

- ステップ 3 で取得した全 Issue をマイルストーン別に集計し、件数の変動を把握する
- MEMORY.md のマイルストーン構成（件数）が実態と一致しているか確認し、ズレがあれば更新する
- クローズ済みマイルストーンの残 Issue が 0 であることを確認する

## 6. Codex レビューコメントの確認

- 最近マージされた PR（`gh pr list --state merged --limit 5`）を取得
- 各 PR に対して `gh api repos/pooza/capsicum/pulls/{number}/comments` で Codex（`chatgpt-codex-connector[bot]`）のコメントを確認
- 各コメントについて以下を判定する:
  1. **未返信** → 指摘内容を確認し、対応が必要か判断。必要なら Issue 起票
  2. **返信済みだがリアクション未付与** → 修正コミットの存在を確認し、+1 リアクションを付与
  3. **返信済み・リアクション済み** → 完了。報告不要
- 判定方法: `gh api repos/pooza/capsicum/pulls/{number}/comments --jq` で全コメントを取得し、Codex コメントの `id` に対する `in_reply_to_id` を持つ返信の有無、および Codex コメントへのリアクション（`reactions`）を確認する

## 7. Sentry の新規イシュー確認

- `sentry-cli --auth-token <調査用トークン> issues list -p capsicum` で未解決イシューを確認（トークンは `~/.sentryclirc` から取得: `awk '/\[auth\]/{getline; print}' ~/.sentryclirc | sed 's/token=//'`）
- 各イシューの過去コメント（対応経緯）を確認する: `curl -sH "Authorization: Bearer $TOKEN" https://sentry.io/api/0/issues/{issue_id}/comments/ | python3 -m json.tool`
- 新規・未解決のイシューがあれば内容を確認し、対応が必要か判断する（対応が必要なら GitHub Issue を起票）
- 判断結果や対応経緯はコメントとして記録する: `curl -sX POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d '{"text":"コメント内容"}' https://sentry.io/api/0/issues/{issue_id}/comments/`
- `$TOKEN` は `~/.sentryclirc` の `[auth]` セクションから取得する（capsicum では `.sentryclirc` がデプロイ用トークンで占有されているため、`awk '/\[auth\]/{getline; print}' ~/.sentryclirc | sed 's/token=//'` で調査用トークンを別途取得する）
- resolved 済みのイシューは報告不要

## 8. 関連リポジトリの同期確認

- **mulukhiya-toot-proxy**: `cd ~/repos/mulukhiya-toot-proxy && git fetch origin` + `git log HEAD..origin/develop --oneline` でリモートとの差分を確認。`docs/capsicum-requirements.md` や `docs/api.md` に変更があれば capsicum 側への影響を判断
- **chubo2**: `cd ~/repos/chubo2 && git fetch origin` + `git log HEAD..origin/main --oneline` で差分を確認。`docs/infra-note.md` に変更があれば MEMORY.md のインフラセクションに反映が必要か判断

## 9. MEMORY.md の更新

- 上記で検出した差分（Issue 状態、マイルストーン件数のズレ、リリース情報等）を反映

## 10. 同期結果の報告

- 現在のブランチ・状態、前回以降にクローズされた Issue、マイルストーン別の残件数、未割り当て Issue 一覧、Sentry 新着イベント、各確認項目の結果をまとめて報告する
