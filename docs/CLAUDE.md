# capsicum 開発ガイド

## プロジェクト概要

Flutter ベースの Mastodon / Misskey クライアント。
汎用クライアントとして動作しつつ、[mulukhiya-toot-proxy](https://github.com/pooza/mulukhiya-toot-proxy)（通称モロヘイヤ）導入済みサーバーでは拡張機能が利用可能になる。

- **技術スタック**: Flutter / Dart
- **対象プラットフォーム**: Android / iOS / iPad
- **配布**: Google Play / App Store
- **利用者**: サーバーの一般ユーザー

## 設計の出発点

アーカイブされた [Kaiteki](https://github.com/Kaiteki-Fedi/Kaiteki) を参考にしている。
ローカルには `/Users/pooza/repos/Kaiteki` に配置。

### Kaiteki から継承する設計

- **Adapter パターン**: `BackendAdapter` + Feature インターフェース（mix-in）による SNS 差異の吸収
- **SharedMastodonAdapter**: Mastodon 派生（Pleroma、Glitch 等）の共通化
- **モデル変換**: `toKaiteki()` extension method による統一ドメインモデルへの変換
- **Probing**: NodeInfo → API endpoint 試行によるサーバー種別の自動検出
- **テキストパーサー**: MFM / HTML / Markdown の Strategy パターン
  - 注意: MFM のリンク記法 `[text](URL)` は、現状の正規表現ベースの URL 抽出だと末尾の `)` が URL の一部として誤認識される。MFM パーサー実装時にこの問題も解消すること
- **モノレポ構成**: core / backends / fediverse_objects / メインアプリの分離

### Kaiteki から変更した点

- Flutter SDK を stable channel に固定
- ストレージ層: Hive → flutter_secure_storage + shared_preferences
- HTTP クライアント: `http` → dio
- 対象 SNS を Mastodon + Misskey に限定
- L10n はサブモジュールでなく直接管理

## モロヘイヤ連携

### 基本方針

モロヘイヤはサーバーサイドのインフラであり、ユーザーが存在を意識する必要はない。
capsicum はサーバーが提供する API を検出し、利用可能な機能に応じて UI を出し分ける。

### 透過プロキシとしての動作

モロヘイヤはリバースプロキシとして動作し、capsicum の API リクエスト（`POST /api/v1/statuses` 等）は透過的にモロヘイヤを経由する。投稿時にハンドラーパイプラインが自動的に処理するため、ハンドラーを動かすために特別な投稿経路（webhook 等）を設計する必要はない。モロヘイヤ連携機能を設計する際は、この透過プロキシが前提であることを常に念頭に置くこと。

### 検出

`GET /mulukhiya/api/about` にリクエストし、HTTP 200 + JSON レスポンスが返ればモロヘイヤありと判定する。認証不要でバージョン情報・コントローラ種別も取得できる。
詳細な検出プロトコルや API 仕様の整備依頼はモロヘイヤ側に [capsicum-requirements.md](https://github.com/pooza/mulukhiya-toot-proxy/blob/main/docs/capsicum-requirements.md) として起票済み。

### 拡張機能の対応状況

| 機能 | モロヘイヤ側エンドポイント | 状態 |
|------|--------------------------|------|
| サーバー情報表示 | `GET /mulukhiya/api/about` | 実装済み |
| お気に入りタグ | `GET /mulukhiya/api/tagging/favorites` | 実装済み |
| 番組情報 | `GET /mulukhiya/api/program` | 実装済み |
| エピソードブラウザ | `GET /mulukhiya/api/program/works`, `.../episodes` | 実装済み |
| Annict OAuth | `GET /mulukhiya/api/annict/oauth_uri`, `POST /mulukhiya/api/annict/auth` | 実装済み |
| タグ付け | `POST /mulukhiya/api/status/tags` | 実装済み |
| ユーザー設定 | `GET/POST /mulukhiya/api/config` | 未実装 |
| ハンドラー一覧 | `GET /mulukhiya/api/admin/handler/list` | 未実装 |
| メディアカタログ | `GET /mulukhiya/api/media` | 未実装（#71） |

## UI 設計方針

### 用語統一

| 旧称 | 現在の呼称 | 備考 |
|------|-----------|------|
| トゥート / ノート | 投稿 | Mastodon / Misskey 共通 |
| インスタンス | サーバー | Mastodon / Misskey 共通 |

コード内部の識別子（`Instance`, `InstanceProbe` 等）は変更不要。UI に表示する文字列のみ統一する。

### タグ管理の位置づけ

文末ハッシュタグの管理（削除してタグづけ・お気に入りタグ・タグセット・予約投稿タグ編集等）は、capsicum の根幹にある基本機能であり、リプライ・ブースト・ブックマークと同等に扱う。アニメファンにとって用語管理（キャラ名・作品名のタグ付け）は本質的な活動であり、この日常的なタグ管理ニーズを満たすことは他のクライアントにない capsicum 独自の価値である。品質・信頼性に関する問題は最優先で対応すること。

### アクションメニュー

投稿に対するアクション（お気に入り・ブースト・ブックマーク等）は、タイムライン上にボタンを露出させず、長押しで表示する BottomSheet メニュー内に格納する。誤タップ防止のため。

### Mastodon / Misskey 機能マッピング

| 操作 | Mastodon | Misskey | 備考 |
|------|----------|---------|------|
| お気に入り | FavoriteSupport | ―（リアクションで代替） | Misskey は ReactionSupport で対応予定 |
| ブックマーク | BookmarkSupport | BookmarkSupport（内部は favorites API） | Misskey の「お気に入り」は意味的にブックマーク相当 |
| ブースト / リノート | repeatPost() | repeatPost()（renote） | ラベルは ReactionSupport の有無で切替 |

- Misskey adapter は `FavoriteSupport` mixin を持たない（リアクション対応時に吸収）
- Misskey 判定は `adapter is ReactionSupport` で行う

### DM / メッセージの方針

- **Mastodon**（#179）: `GET /api/v1/conversations` で DM 専用タイムラインを実装
- **Misskey**（#248）: DM タイムライン API がない。最近の Misskey では「メッセージ」機能（スレッド形式チャット）が DM の後継と位置づけられており、こちらに対応する

### Misskey MiAuth パーミッション管理

新しい Misskey API エンドポイントを利用する場合、`MisskeyAdapter._permissions` リストに該当パーミッションを追加すること。追加を忘れると 403 `PERMISSION_DENIED` になる。また、パーミッション追加は既存のトークンには効かないため、ユーザーは再ログインが必要。

エラー時は「権限がありません。再ログインが必要な場合があります」のようなメッセージを表示すること。

### Misskey API の注意点

- **`users/report-abuse`**: 通報受理時にサーバーが管理者へメール通知を試みる。SMTP 未設定のサーバーでは 500 Internal Error が返るが、これはサーバー側の問題であり capsicum 側の不具合ではない
- **ピン留め投稿**: `/api/users/notes` の `pinned` パラメータは機能しない。`/api/users/show` レスポンスの `pinnedNotes` フィールドから取得する
- **`i/update`**: 空文字列 `""` は 400 エラー。フィールドをクリアするには JSON で明示的に `null` を送信（キー省略は「変更なし」の意味）

### go_router での画面間値受け渡し

`context.push<T>('/route')` + `context.pop(result)` を使う。`Navigator.pop(context, result)` では go_router が戻り値を握りつぶすため使用不可。`showGeneralDialog` のコールバック方式もリビルド時にコールバックが消失するため不可。

### モロヘイヤ連携画面の導線

エピソードブラウザはタグセット BottomSheet 内のメニュー項目として配置する（Mastodon 改造版 WebUI と同じ動線）。投稿画面のツールバーに独立したアイコンを置く方式は、ユーザーに発見されにくいため採用しない。

### プッシュ通知

プッシュ通知には、Mastodon の Web Push を APNs/FCM に変換する中継サーバーの運用が必要。インフラコストを抑えるため、当面はプッシュ通知を実装せず、通知一覧のポーリング表示から始める。

課金方針（#52）:

- **無償**: プリセットサーバー（自前サーバー）のメンバー
- **割引**: モロヘイヤ導入サーバーのメンバー
- **有償**: それ以外の外部ユーザー
- 判定はアカウントの所属サーバーで行う（プリセットリスト + モロヘイヤ検出）
- 中継サーバーのアーキテクチャ・コスト構造の調査、課金手段（アプリ内課金等）の検討が必要

### サポート優先順位

自前のサーバー（美食丼・デルムリン丼・キュアスタ！・ダイスキー）以外では、サーバーログの確認やサーバー側の操作（レートリミット解除等）ができないため、サポートの優先順位を下げる。自前サーバー以外での問題はクライアント側で対処可能な範囲に限定し、サーバー側の問題が疑われる場合は「サーバー管理者に問い合わせてください」等の案内に留める。

## 対応バージョン方針

### 基本戦略: 機能検出（Feature Probing）ベース

バージョン番号による分岐は行わない。サーバーが提供する API エンドポイントを probing し、利用可能な機能に応じて UI を出し分ける。

### フォークに対する方針

capsicum は Mastodon 本家および Misskey 本家の API に対して実装する。フォークに対して個別の互換処理は行わない。本家 API との互換性を維持するのはフォーク側の責任であり、probing の結果として動作するならそのまま使えるが、動作しない場合も capsicum 側では対応しない。

なお、Mastodon フォークが Misskey 互換の API を提供するケースもありうる。この場合も同様に probing の結果に従い、利用可能な機能があればそのまま使う。フォーク固有の対応は行わない。

ただし、自前のサーバー（モロヘイヤ導入済み環境）が提供する独自機能には最大限対応する。capsicum の主目的は自前のインフラとの連携であり、フォーク互換とは別の話である。

### 機能不足時の通知

probing の結果、基本的な機能が欠けているサーバーに対しては「このサーバーは一部の機能に対応していません」旨の通知を表示する。バージョン番号には言及しない。接続自体は拒否せず、利用可能な範囲で動作させる。

### 開発上のターゲット

主な動作確認対象は自前のサーバー（美食丼 / デルムリン丼 / キュアスタ！ / ダイスキー）であり、最新の Mastodon / Misskey に追従している前提で開発する。古いバージョン固有の互換処理やフォーク固有の互換処理は原則として書かない。

## ブランチ戦略

| ブランチ | 目的 |
|----------|------|
| `main` | リリース済み安定版 |
| `develop` | 開発ブランチ。日常の作業はここで行う |

### リリースフロー

1. `develop` で開発・コミット
2. リリース時に `develop` → `main` へ PR を作成
3. CI（`dart format`・`dart analyze`）が通ることを確認してからマージ
4. `main` でタグを打ちリリース

### PR マージ後の確認事項

- Codex（chatgpt-codex-connector[bot]）からのレビューコメントがないか確認する
- 指摘が未対応なら Issue を起票して修正する
- 対応済みなら修正コミット/Issue を参照して返信し、Codex コメントに +1 リアクションをつける
- **返信とリアクションの両方が揃って「完了」**。片方だけでは同期時に未完了と判定される

## ディレクトリ構成

```text
capsicum/
  docs/                   # 開発ドキュメント
    CLAUDE.md             # 本ファイル
    architecture.md       # アーキテクチャ設計
  packages/               # モノレポ構成（Melos）
    capsicum/             # メインアプリ
    capsicum_core/        # ドメインモデル・Adapter インターフェース
    capsicum_backends/    # Mastodon / Misskey API 実装
    fediverse_objects/    # API レスポンスのシリアライズモデル
```

## Issue 管理

- GitHub Issues + Milestones で管理（モロヘイヤと同じ体系）
- 優先度ラベル: P1 〜 P4
- 1 マイルストーンあたり 10 件前後

### 正本ルール

- **Issue のステータス・一覧は GitHub が正本**。CLAUDE.md や MEMORY.md に個別 Issue の一覧・対応済み/未済を複写しない
- リリース計画の確認は `gh issue list --milestone v1.0` 等で GitHub を直接参照する
- CLAUDE.md に書くのは Issue に書けない情報（マイルストーンの方針・運用ルール・設計判断の背景 等）に限定する

### クロスリファレンス

- capsicum → モロヘイヤ: `pooza/mulukhiya-toot-proxy#XXXX`
- モロヘイヤ → capsicum: `pooza/capsicum#XXXX`

## 関連リポジトリ

| リポジトリ | 内容 |
|-----------|------|
| [mulukhiya-toot-proxy](https://github.com/pooza/mulukhiya-toot-proxy) | モロヘイヤ本体。API 仕様の参照元 |
| [mastodon](https://github.com/pooza/mastodon) | Mastodon フォーク（美食丼 / デルムリン丼 / キュアスタ！） |
| [misskey](https://github.com/pooza/misskey) | Misskey フォーク（ダイスキー） |
| [Kaiteki](https://github.com/Kaiteki-Fedi/Kaiteki) | 設計の参考元（アーカイブ済み） |
| [capsicum-site](https://github.com/pooza/capsicum-site) | プロジェクトサイト（`capsicum.shrieker.net`）。GitHub Pages で配信。プライバシーポリシー・子どもの安全基準等 |

## リリース計画

リリース手順・ストア設定の詳細は [store-release-guide.md](store-release-guide.md) を参照。

GitHub Issues のマイルストーン（v1.0 / v1.1 / v1.2 / v1.3 / v1.4 / v1.5 / v1.6 / v1.7 / v1.8 / v1.9 / v1.10 / v1.11 / v1.12 / v1.13 / v1.14 / v1.15）が正本。個別 Issue の一覧・ステータスはここに複写しない。

最新リリース: **v1.12.0**（2026-04-07）。v1.0.0 は 2026-03-14 にストア公開。リリース履歴の詳細は [GitHub Releases](https://github.com/pooza/capsicum/releases) を参照。

今後のマイルストーン:

- **v1.13** — DM・メッセージ + UI 改善 + バグ修正（DM タイムライン・Misskey メッセージ・Misskey ページ・タブ管理統合・確認画面条件・復号エラー対応）
- **v1.14** — 通知統合 + 下書き + ユーザーフィードバック対応（通知・お知らせ統合一覧・お知らせ/通知タブ化・サーバーサイド下書き・通知欄アクション・ナウプレ削除・Android ログイン調査）
- **v1.15** — 連携 + Misskey 猫化（ポイピク連携・メディア API v2・isCat 対応）

運用ルール:

- セキュリティレビュー（[#27](https://github.com/pooza/capsicum/issues/27)）は各マイルストーンの Issue をすべて消化した後、リリース直前に毎度実施する
- ATOK 二重入力（[#54](https://github.com/pooza/capsicum/issues/54)）は Flutter 側の対応待ち。リリースごとにリリースノートの「既知の不具合」に記載し、Flutter 側の関連 issue の動向を確認する
- マイルストーン未設定の Issue は `no:milestone` フィルタで確認する

### 実装しない機能

- 投稿の更新（Mastodon）— SNS にふさわしい機能と判断しないため

## セッション開始時の同期手順

会話の最初に「進捗を同期してください」等の指示があった場合、以下の手順を実行する。

### 1. プロジェクトガイドの読み込み

- `docs/CLAUDE.md` を読む（プロジェクトのルール・構造・履歴の正本）
- インフラノート `/Volumes/extdata/repos/chubo2/docs/infra-note.md` を読む（サーバー構成・デプロイ手順）
- `MEMORY.md` は自動ロードされるので、両者の整合性を意識する

### 2. リモートとの同期・状態確認

- `git fetch origin` — **最初に必ず実行**。リモートが正本であり、ローカルの状態を信用しない
- `git log HEAD..origin/develop --oneline` — リモートに未取り込みのコミットがないか確認。差分があれば pull を検討
- `git log --oneline -10` — 直近のコミット履歴
- `git tag --sort=-creatordate | head -5` — 直近のリリースタグを確認
- `gh release list --limit 5` — 最近の GitHub Releases を確認
- `gh api repos/pooza/capsicum/milestones --jq '.[] | "\(.title) \(.state) \(.closed_at // "open")"'` — マイルストーンの open/closed 状態を確認
- 前回同期時点と比較して新しいリリースがあれば、実装ステータスやリリース計画セクションに反映する

### 3. Issue・PR の確認

- `gh issue list --state open --limit 100` — open Issue 一覧（**`--limit 100` を必ず指定**。デフォルト 30 件では古い Issue が取得漏れする）
- `gh pr list --state open` — open PR 一覧
- `gh issue list --state closed --limit 10` — 最近クローズされた Issue（前回同期以降の進捗把握）
- マイルストーン未割り当ての open Issue を一覧として列挙する（割り当てを促す文言は不要）

### 4. ユーザーフィードバックの確認（#capsicum タグタイムライン）

- 美食丼の `#capsicum` タグタイムラインを取得: `curl -s "https://mstdn.b-shock.org/api/v1/timelines/tag/capsicum?limit=20"`
- バグ報告・機能要望・ユーザーからの質問がないか確認する
- 未起票のバグ報告があれば GitHub Issue を起票する（報告元の投稿 URL を記載）
- 好評・感想は報告のみ（Issue 化不要）

### 5. マイルストーンの状態確認

- ステップ 3 で取得した全 Issue をマイルストーン別に集計し、件数の変動を把握する
- MEMORY.md のマイルストーン構成（件数）が実態と一致しているか確認し、ズレがあれば更新する
- クローズ済みマイルストーンの残 Issue が 0 であることを確認する

### 6. Codex レビューコメントの確認

- 最近マージされた PR（`gh pr list --state merged --limit 5`）を取得
- 各 PR に対して `gh api repos/pooza/capsicum/pulls/{number}/comments` で Codex（`chatgpt-codex-connector[bot]`）のコメントを確認
- 各コメントについて以下を判定する:
  1. **未返信** → 指摘内容を確認し、対応が必要か判断。必要なら Issue 起票
  2. **返信済みだがリアクション未付与** → 修正コミットの存在を確認し、+1 リアクションを付与
  3. **返信済み・リアクション済み** → 完了。報告不要
- 判定方法: `gh api repos/pooza/capsicum/pulls/{number}/comments --jq` で全コメントを取得し、Codex コメントの `id` に対する `in_reply_to_id` を持つ返信の有無、および Codex コメントへのリアクション（`reactions`）を確認する

### 7. Sentry の新規イシュー確認

- `sentry-cli --auth-token <調査用トークン> issues list -p capsicum` で未解決イシューを確認（トークンは `~/.sentryclirc` から取得: `awk '/\[auth\]/{getline; print}' ~/.sentryclirc | sed 's/token=//'`）
- 各イシューの過去コメント（対応経緯）を確認する: `curl -sH "Authorization: Bearer $TOKEN" https://sentry.io/api/0/issues/{issue_id}/comments/ | python3 -m json.tool`
- 新規・未解決のイシューがあれば内容を確認し、対応が必要か判断する（対応が必要なら GitHub Issue を起票）
- 判断結果や対応経緯はコメントとして記録する: `curl -sX POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d '{"text":"コメント内容"}' https://sentry.io/api/0/issues/{issue_id}/comments/`
- `$TOKEN` は `~/.sentryclirc` の `[auth]` セクションから取得する（capsicum では `.sentryclirc` がデプロイ用トークンで占有されているため、`awk '/\[auth\]/{getline; print}' ~/.sentryclirc | sed 's/token=//'` で調査用トークンを別途取得する）
- resolved 済みのイシューは報告不要

### 8. 関連リポジトリの同期確認

- **mulukhiya-toot-proxy**: `cd ~/repos/mulukhiya-toot-proxy && git fetch origin` + `git log HEAD..origin/develop --oneline` でリモートとの差分を確認。`docs/capsicum-requirements.md` や `docs/api.md` に変更があれば capsicum 側への影響を判断
- **chubo2**: `cd ~/repos/chubo2 && git fetch origin` + `git log HEAD..origin/main --oneline` で差分を確認。`docs/infra-note.md` に変更があれば MEMORY.md のインフラセクションに反映が必要か判断

### 9. MEMORY.md の更新

- 上記で検出した差分（Issue 状態、マイルストーン件数のズレ、リリース情報等）を反映

### 10. 同期結果の報告

- 現在のブランチ・状態、前回以降にクローズされた Issue、マイルストーン別の残件数、未割り当て Issue 一覧、Sentry 新着イベント、各確認項目の結果をまとめて報告する

## ドキュメント表記規約

モロヘイヤ側の規約に合わせる:

- **サーバーの呼称**: 「インスタンス」ではなく「サーバー」を使う
- **ファイル参照**: マークダウンリンクにする
