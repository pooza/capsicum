# capsicum 開発ガイド

## プロジェクト概要

Flutter ベースの Mastodon / Misskey クライアント。
汎用クライアントとして動作しつつ、[mulukhiya-toot-proxy](https://github.com/pooza/mulukhiya-toot-proxy)（通称モロヘイヤ）導入済みサーバーでは拡張機能が利用可能になる。

- **技術スタック**: Flutter / Dart
- **対象プラットフォーム**: Android / iOS（余力があればタブレット最適化）
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

### Kaiteki から変更する点

- Flutter SDK を stable channel に固定
- ストレージ層の刷新（Hive → flutter_secure_storage + shared_preferences）
- HTTP クライアントの刷新（`http` → dio）
- 初期スコープは Mastodon + Misskey に絞る（Tumblr 等は除外）
- Widget テストの追加
- L10n はサブモジュールでなく直接管理

## モロヘイヤ連携

### 基本方針

モロヘイヤはサーバーサイドのインフラであり、ユーザーが存在を意識する必要はない。
capsicum はサーバーが提供する API を検出し、利用可能な機能に応じて UI を出し分ける。

### 検出

`GET /mulukhiya/api/about` にリクエストし、HTTP 200 + JSON レスポンスが返ればモロヘイヤありと判定する。認証不要でバージョン情報・コントローラ種別も取得できる。
詳細な検出プロトコルや API 仕様の整備依頼はモロヘイヤ側に [capsicum-requirements.md](https://github.com/pooza/mulukhiya-toot-proxy/blob/main/docs/capsicum-requirements.md) として起票済み。

### 対応予定の拡張機能

| 機能 | モロヘイヤ側エンドポイント | 優先度 |
|------|--------------------------|--------|
| サーバー情報表示 | `GET /mulukhiya/api/about` | P1 |
| ユーザー設定 | `GET/POST /mulukhiya/api/config` | P2 |
| タグ付け | `POST /mulukhiya/api/status/tags` | P1 |
| ハンドラー一覧 | `GET /mulukhiya/api/admin/handler/list` | P2 |
| お気に入りタグ | `GET /mulukhiya/api/tagging/favorites` | P3 |
| メディアカタログ | `GET /mulukhiya/api/media` | P3 |
| 番組情報 | `GET /mulukhiya/api/program` | P2 |

## UI 設計方針

### 用語統一

| 旧称 | 現在の呼称 | 備考 |
|------|-----------|------|
| トゥート / ノート | 投稿 | Mastodon / Misskey 共通 |
| インスタンス | サーバー | Mastodon / Misskey 共通 |

コード内部の識別子（`Instance`, `InstanceProbe` 等）は変更不要。UI に表示する文字列のみ統一する。

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

### プッシュ通知

プッシュ通知には、Mastodon の Web Push を APNs/FCM に変換する中継サーバーの運用が必要。インフラコストを抑えるため、当面はプッシュ通知を実装せず、通知一覧のポーリング表示から始める。

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
2. リリース時に `develop` → `main` へ PR を作成しマージ
3. `main` でタグを打ちリリース

## ディレクトリ構成（予定）

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

## 実装ステータス

### 実装済み

- NodeInfo によるサーバー probing（Mastodon/Misskey 自動検出）
- Mastodon OAuth ログイン（OOB コード入力方式）
- Misskey MiAuth ログイン（手動完了ボタン方式）
- セッション永続化・復元（flutter_secure_storage）
- マルチアカウント対応（ドロワーでアカウント切替・追加・ログアウト）
- タイムライン表示（ホーム / ローカル / ソーシャル / 連合）+ 無限スクロール + 相対時刻・ハンドル・公開範囲・返信インジケータ・末尾ハッシュタグチップ・長文折り畳み・タグ展開切替・メディアサムネイル・URL リンク
- テキスト投稿（公開範囲選択、文字数カウンター）
- 投稿詳細・スレッド表示
- アクションメニュー（お気に入り / ブースト / ブックマーク）
- プリセットサーバーリスト
- 通知一覧（無限スクロール・プルリフレッシュ対応）+ バックグラウンドポーリング・ローカル OS 通知
- Misskey リアクション（絵文字ピッカー・リアクションチップ表示）
- ストリーミング（WebSocket・Mastodon / Misskey 両対応・自動再接続）
- メディア添付（画像選択 + アップロード + 説明・センシティブ設定、Mastodon / Misskey 両対応）
- 動画・音声メディアの再生
- 複数画像グリッド表示（5枚以上は +N オーバーレイ）
- 投稿の削除 + 削除して再編集
- 検索（アカウント・ハッシュタグ・URL 解決・全文検索）
- ユーザープロフィール（バナー・アバター・Bio・補足情報・統計・投稿一覧）
- ブックマークのタイムライン（Mastodon: ブックマーク / Misskey: お気に入り）
- お知らせ（サーバーからの告知・既読管理）
- CW（Content Warning）折り畳み表示
- カスタム絵文字のインライン表示（投稿本文・表示名）
- メディア NSFW ぼかし表示（Mastodon / Misskey 両対応）
- メディア ALT バッジ・キャプション表示
- メディア拡大ビューア（PageView + ピンチズーム）
- 投稿のエンゲージメント数表示（リプライ・ブースト・お気に入り）
- CW（Content Warning）投稿対応 + sensitive 自動連動（Mastodon / Misskey 両対応）
- ワードフィルタのタイムライン反映（Mastodon の `filtered` フィールドに基づく hide/warn 表示 + Misskey クライアント側ワードミュート）
- モロヘイヤ連携: タグセット（投稿画面の実況ボタン + 番組選択 BottomSheet）
- モロヘイヤ連携: 削除してタグづけ（削除 + X-Mulukhiya ヘッダー付き再投稿方式、デフォルトタグ保護）
- モロヘイヤ自動検出（ログイン・セッション復元時に `GET /mulukhiya/api/about` で検出）
- モロヘイヤ連携: サーバー固有 UI 反映（投稿ラベル・字数上限・テーマカラー・ローカルTL名を about レスポンスから取得）
- UI / ブランディング整備（スプラッシュ画面・アプリアイコン・About 画面・ログイン画面改善）
- CI（GitHub Actions: dart format + analyze）
- ログインの自動コールバック化（flutter_web_auth_2 によるシングルステップ認証）
- エラーメッセージの汎用化（内部情報を非表示・debugPrint へ出力）
- launchUrl() の URL スキーム検証追加（http/https のみ許可）
- ハッシュタグタイムライン（検索結果・インラインハッシュタグからの遷移対応）
- プレビューカードの表示（Mastodon のみ、メディア添付がない投稿で表示。Misskey は note レスポンスにカード情報を含まず別途 `/api/url` が必要なため v1.2 に先送り）
- 投票（Poll）の表示・投票対応（Mastodon / Misskey 両対応）
- リスト機能（一覧・TL表示）+ タブバー統合
- 投稿本文中ハッシュタグのリンク化
- CJK フォントの日本語ロケール描画修正
- Android 13+ の通知権限リクエスト
- CW 開閉タップ領域の拡大（警告行全体をタップ可能に）
- フォロー・フォロワーリスト表示（プロフィール画面から遷移、無限スクロール対応）
- フォロー・アンフォロー・ミュート・ブロック操作（ミュート期限選択・ブロック確認ダイアログ付き）— 実装済み・未検証
- Android アダプティブアイコンのセーフゾーン対応
- リプライ機能（返信先の引用表示・公開範囲の自動制限・メンション自動挿入）
- IME composing 干渉の軽減（TextField の onChanged 除去）
- 動画アップロード時の 202 非同期処理対応

### リリース計画

#### v0.1（身内テスト版） — 機能実装完了

[#13](https://github.com/pooza/capsicum/issues/13)・[#18](https://github.com/pooza/capsicum/issues/18) とも対応済み。

v0.1.0 リリース済み:

- Android APK: [GitHub Releases v0.1.0](https://github.com/pooza/capsicum/releases/tag/v0.1.0)
- iOS: TestFlight にアップロード済み（App Store Connect API Key 方式）

v0.2.0 リリース済み:

- Android APK: [GitHub Releases v0.2.0](https://github.com/pooza/capsicum/releases/tag/v0.2.0)
- iOS: TestFlight 外部テスター向け Beta App Review 提出済み
- iPhone のみ（iPad 除外）

配布方法:

- **iOS**: TestFlight 外部テスターのみ（内部テスターは本名が相互に見える問題のため不使用）
- **Android**: GitHub Releases にリリース用 APK をアセットとして添付

テスト版配布手順:

1. `pubspec.yaml` の version を確認・更新
2. Android: `flutter build apk --release` → APK を取得
3. iOS: `flutter build ipa --release` → `cd ios && fastlane beta`（TestFlight にアップロード）
4. GitHub で `vX.Y.Z` タグを作成しリリースを作る（`--prerelease` 付き）
5. Android APK をリリースアセットとしてアップロード
6. テスターに GitHub Releases URL（Android）と TestFlight 招待（iOS）を送付

各マシン共通の前提（詳細は [store-release-guide.md](store-release-guide.md) を参照）:

- `~/.config/capsicum/AuthKey_WLS8G4W44L.p8` に App Store Connect API Key を配置
- Xcode → Settings → Accounts で Apple Distribution 証明書を作成
- `gem install fastlane`（rbenv の Ruby を使用）
- Android 署名鍵: `android/key.properties`（git 管理外、手動配置）

#### ストアリリース準備（v1.0 公開前）

詳細手順は [store-release-guide.md](store-release-guide.md) を参照。

- [x] Android 署名鍵の生成（keystore・key.properties・build.gradle.kts）
- [x] iOS App Store Connect でのアプリ作成・証明書設定
- [x] プライバシーポリシーの作成・公開
- [x] ストア掲載情報（説明文・カテゴリ・キーワード等）
- [x] App Store 年齢区分設定（16+）
- [x] App Store スクリーンショット登録
- [x] Fastlane セットアップ（ビルド・アップロード自動化）
- [ ] Google Play Developer アカウント登録（$25）・アプリ作成
- [ ] Google Play IARC レーティング回答
- [ ] Google Play フィーチャーグラフィック（1024x500）
- [ ] Google Play スクリーンショット（最低2枚）

#### v1.0（ストア公開）

身内テスト版に加え、以下を対応してからストア公開する。

- 引用投稿の表示（[#1](https://github.com/pooza/capsicum/issues/1)）
- ~~投票の表示（[#10](https://github.com/pooza/capsicum/issues/10)）~~ — v0.2.0 で対応済み
- ~~リスト機能（一覧・TL表示）（[#19](https://github.com/pooza/capsicum/issues/19)）~~ — v0.2.0 で対応済み
- モロヘイヤ連携: エピソードブラウザ（[#22](https://github.com/pooza/capsicum/issues/22)）
- ~~フォロー・フォロワーリスト（[#28](https://github.com/pooza/capsicum/issues/28)）~~ — 対応済み
- フォロー・アンフォロー・ミュート・ブロック操作（[#29](https://github.com/pooza/capsicum/issues/29)）— 実装済み・未検証
- MFM / HTML / Markdown テキストパーサーの実装（[#39](https://github.com/pooza/capsicum/issues/39)）
- ~~Android アダプティブアイコンのセーフゾーン対応（[#44](https://github.com/pooza/capsicum/issues/44)）~~ — 対応済み
- ~~リプライ機能（[#45](https://github.com/pooza/capsicum/issues/45)）~~ — 対応済み
- ATOK で日本語入力が二重になる（[#54](https://github.com/pooza/capsicum/issues/54)）— Flutter engine レベルの iOS+ATOK 相性問題、テスター環境で未検証
- ~~動画添付で投稿するとエラーになる（[#55](https://github.com/pooza/capsicum/issues/55)）~~ — 修正済み
- 特定の画像が描画されない（[#56](https://github.com/pooza/capsicum/issues/56)）

#### v1.1

- アバターデコレーション表示（[#15](https://github.com/pooza/capsicum/issues/15)）
- タグセット連動アバターデコレーション（[#24](https://github.com/pooza/capsicum/issues/24)）— #15 が前提
- タイムライン既読位置の保存・復元（[#25](https://github.com/pooza/capsicum/issues/25)）
- 予約投稿・下書き保存（[#5](https://github.com/pooza/capsicum/issues/5)）
- ワードフィルタ設定UI（[#7](https://github.com/pooza/capsicum/issues/7)）
- プロフィール編集（[#9](https://github.com/pooza/capsicum/issues/9)）
- ピン留め投稿の表示（[#11](https://github.com/pooza/capsicum/issues/11)）
- リストの作成・編集・削除（[#20](https://github.com/pooza/capsicum/issues/20)）
- 投稿済みメディアの説明（ALT）編集（[#30](https://github.com/pooza/capsicum/issues/30)）
- 横長カスタム絵文字の表示対応（[#40](https://github.com/pooza/capsicum/issues/40)）
- 投稿テキストの選択・コピー（[#57](https://github.com/pooza/capsicum/issues/57)）

#### v1.2

- コマンドトゥート結果の JSON / YAML レンダリング（[#8](https://github.com/pooza/capsicum/issues/8)）
- モロヘイヤ WebUI 機能の対応（[#14](https://github.com/pooza/capsicum/issues/14)）
- Misskey ローカルオンリー投稿対応（[#17](https://github.com/pooza/capsicum/issues/17)）
- Misskey プレビューカード対応（[#41](https://github.com/pooza/capsicum/issues/41)）
- サーバーカスタムリンクの表示（[#26](https://github.com/pooza/capsicum/issues/26)）
- ボットアカウントのバッジ表示（[#33](https://github.com/pooza/capsicum/issues/33)）
- ロールのプロフィール表示（[#34](https://github.com/pooza/capsicum/issues/34)）
- Misskey: チャンネル宛て投稿の識別表示（[#35](https://github.com/pooza/capsicum/issues/35)）
- Misskey: チャンネルタイムライン（[#36](https://github.com/pooza/capsicum/issues/36)）

#### v1.3

- ハッシュタグ・Acct のリンク化（[#46](https://github.com/pooza/capsicum/issues/46)）
- 引用投稿の操作（[#49](https://github.com/pooza/capsicum/issues/49)）
- 複数URLのプレビューカード表示対応（[#42](https://github.com/pooza/capsicum/issues/42)）
- ハッシュタグ・Acct の入力補完（[#47](https://github.com/pooza/capsicum/issues/47)）
- お気に入り・ブーストしたユーザーのリスト表示（[#48](https://github.com/pooza/capsicum/issues/48)）
- プロフィール補足情報の rel=me 認証バッジ表示（[#50](https://github.com/pooza/capsicum/issues/50)）

#### リリース前の定期タスク

- セキュリティレビュー（[#27](https://github.com/pooza/capsicum/issues/27)）— 各マイルストーンの issue をすべて消化した後、リリース直前に毎度実施

### 実装しない機能

- 投稿の更新（Mastodon）— SNS にふさわしい機能と判断しないため

## ドキュメント表記規約

モロヘイヤ側の規約に合わせる:

- **サーバーの呼称**: 「インスタンス」ではなく「サーバー」を使う
- **ファイル参照**: マークダウンリンクにする
