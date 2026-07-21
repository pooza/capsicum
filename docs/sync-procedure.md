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
- **Flutter のバージョンが基準と合っているかを確認する**（[#836](https://github.com/pooza/capsicum/issues/836)）。端末が 3 つ以上あり、ズレたまま `flutter pub get` すると `pubspec.lock` が端末間で ping-pong するため、**着いた端末で最初に気付けるようにする**のが目的。正本は CI の pin:

  ```sh
  grep -m1 'flutter-version:' .github/workflows/analyze.yml   # 基準（正本）
  flutter --version | head -1                                  # 手元
  ```

  Windows（`grep` 不在）:

  ```powershell
  Select-String -Path .github\workflows\analyze.yml -Pattern 'flutter-version:' | Select-Object -First 1
  flutter --version | Select-Object -First 1
  ```

  ズレていたら同期報告に「この端末は X、基準は Y」と明記し、[dev-environment.md](dev-environment.md) の「基準版に追従する」手順で揃えてから作業に入る。**揃える前に出た `pubspec.lock` の差分はコミットしない**

## 3. Issue・PR の確認

- `gh issue list --state open --limit 100` — open Issue 一覧（**`--limit 100` を必ず指定**。デフォルト 30 件では古い Issue が取得漏れする）
- `gh pr list --state open` — open PR 一覧
- `gh issue list --state closed --limit 10` — 最近クローズされた Issue（前回同期以降の進捗把握）
- マイルストーン未割り当ての open Issue を一覧として列挙する（割り当てを促す文言は不要）

## 4. ユーザーフィードバックの確認（#capsicum タグ + ダイスキー capsicum チャンネル）

- 美食丼の `#capsicum` タグタイムラインを取得: `curl -s "https://mstdn.b-shock.org/api/v1/timelines/tag/capsicum?limit=20"`
- ダイスキーの capsicum チャンネル（delmulin 固有の capsicum 話題、`channelId=ak31f5utjv`、<https://misskey.delmulin.com/channels/ak31f5utjv>）を取得: `curl -s -X POST https://misskey.delmulin.com/api/channels/timeline -H 'Content-Type: application/json' -d '{"channelId":"ak31f5utjv","limit":20}'`
- バグ報告・機能要望・ユーザーからの質問がないか確認する
- 未起票のバグ報告があれば GitHub Issue を起票する（報告元の投稿 URL を記載）
- 好評・感想は報告のみ（Issue 化不要）

## 5. マイルストーンの状態確認

- ステップ 3 で取得した全 Issue をマイルストーン別に集計し、件数の変動を把握する
- MEMORY.md のマイルストーン構成（件数）が実態と一致しているか確認し、ズレがあれば更新する
- クローズ済みマイルストーンの残 Issue が 0 であることを確認する
- リリース直後の同期では、open マイルストーンの description が実態と乖離していないかも確認する。GitHub Milestones が正本（CLAUDE.md に複写しない方針）のため、description が空・古い場合は同期内で `gh api -X PATCH repos/pooza/capsicum/milestones/{number} -f description="..."` で整える。最低限、(a) 大更新の単独配置か否か、(b) 主な含有 Issue、(c) 並走条件 を 1〜3 行で書く

## 6. Codex レビューコメントの確認

- 最近マージされた PR（`gh pr list --state merged --limit 5`）を取得。**直近リリース PR（`develop` → `main` の merge）も merged にカウントされる**ため、リリース直後の同期では明示的にリリース PR が含まれていることを確認する（過去に #529 を見落としかけた経緯あり）
- 各 PR に対して `gh api repos/pooza/capsicum/pulls/{number}/comments`（line comments）+ `gh api repos/pooza/capsicum/pulls/{number}/reviews`（review 本体）の両方で Codex（`chatgpt-codex-connector[bot]`）のコメントを確認。**line comments と review comments は別 API** で、片方だけ見ると review 本体に書かれた指摘 (P2 レベル等) を取りこぼす
- 各コメントについて以下を判定する:
  1. **未返信** → 指摘内容を確認し、対応が必要か判断。必要なら Issue 起票
  2. **返信済みだがリアクション未付与** → 修正コミットの存在を確認し、+1 リアクションを付与
  3. **返信済み・リアクション済み** → 完了。報告不要
- 判定方法: `gh api repos/pooza/capsicum/pulls/{number}/comments --jq` で全コメントを取得し、Codex コメントの `id` に対する `in_reply_to_id` を持つ返信の有無、および Codex コメントへのリアクション（`reactions`）を確認する

## 7. Sentry の新規イシュー確認

- `sentry-cli --auth-token <調査用トークン> issues list -p capsicum` で未解決イシューを確認（トークンは `~/.sentryclirc` から取得: `awk '/\[auth\]/{getline; print}' ~/.sentryclirc | sed 's/token=//'`）
- 同じトークンで `sentry-cli --auth-token <調査用トークン> issues list -p capsicum-relay` も確認（capsicum-relay#10 で 2026-05-28 から計装開始。Phase A 段階では smoke test 起点で、Phase B 以降で APNs/FCM/socket_loop の本格計装が乗る）
- 各イシューの過去コメント（対応経緯）を確認する: `curl -sH "Authorization: Bearer $TOKEN" https://sentry.io/api/0/issues/{issue_id}/comments/ | python3 -m json.tool`
- 新規・未解決のイシューがあれば内容を確認し、対応が必要か判断する（対応が必要なら GitHub Issue を起票。capsicum-relay 側のイシューは pooza/capsicum-relay リポに起票）
- 判断結果や対応経緯はコメントとして記録する: `curl -sX POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d '{"text":"コメント内容"}' https://sentry.io/api/0/issues/{issue_id}/comments/`
- `$TOKEN` は `~/.sentryclirc` の `[auth]` セクションから取得する（capsicum では `.sentryclirc` がデプロイ用トークンで占有されているため、`awk '/\[auth\]/{getline; print}' ~/.sentryclirc | sed 's/token=//'` で調査用トークンを別途取得する）
- resolved 済みのイシューは報告不要

## 8. 関連リポジトリの同期確認

- **mulukhiya-toot-proxy**: `cd ~/repos/mulukhiya-toot-proxy && git fetch origin` + `git log HEAD..origin/develop --oneline` でリモートとの差分を確認。`docs/capsicum-requirements.md` や `docs/api.md` に変更があれば capsicum 側への影響を判断
- **chubo2**: `cd ~/repos/chubo2 && git fetch origin` + `git log HEAD..origin/main --oneline` で差分を確認。`docs/infra-note.md` に変更があれば MEMORY.md のインフラセクションに反映が必要か判断
- **capsicum-relay**: `cd ~/repos/capsicum-relay && git fetch origin` + `git log HEAD..origin/main --oneline` で差分を確認。Issue / PR は `gh issue list --repo pooza/capsicum-relay --state open --limit 30` / `gh pr list --repo pooza/capsicum-relay --state open` で確認（dependabot PR + security alert もここで拾う、`gh api repos/pooza/capsicum-relay/dependabot/alerts --jq '.[] | select(.state == "open") | "\(.security_advisory.severity) \(.dependency.package.name) fix=\(.security_vulnerability.first_patched_version.identifier)"'`）。リレーサーバー（flauros）のデプロイ管理は Claude 担当（**接続先ホスト・SSH ユーザー・具体的な SSH コマンド列はメモリ `feedback_capsicum_relay_deploy_delegation` が正本**）、main 進行がありサーバー側の HEAD が遅れていたら SSH デプロイ（`git pull && bundle install` → `sudo -n systemctl restart capsicum-relay` → `/health` 確認）まで一連で実行
- **Mastodon / Misskey の現行バージョン確認**: 自前サーバーのソフトウェアは pooza フォークがリリース追従しているため、ローカルの fork を pull すれば現行バージョンを正確に確認できる（推測しない）。
  - Mastodon: `cd ~/repos/mastodon && git pull --ff-only` → `lib/mastodon/version.rb` の major/minor/patch（または `git tag --sort=-creatordate | head` で `vX.Y.Z-bshockdon`）
  - Misskey: `cd ~/repos/misskey && git pull --ff-only` → `package.json` の `version`
  - 前回同期からメジャー/マイナーが上がっていれば、API 変更トリアージ（`docs/mastodon-46-capsicum-triage.md` / `docs/misskey-capsicum-api-watch.md`）の要否を判断し、メモリの「対応方針」系（例 `project_mastodon_46_posture`）の版表記を更新する

## 9. MEMORY.md の更新

- 上記で検出した差分（Issue 状態、マイルストーン件数のズレ、リリース情報等）を反映

## 10. 同期結果の報告

- 現在のブランチ・状態、前回以降にクローズされた Issue、マイルストーン別の残件数、未割り当て Issue 一覧、Sentry 新着イベント、Mastodon / Misskey の現行バージョン、各確認項目の結果をまとめて報告する
