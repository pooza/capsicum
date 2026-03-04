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
- タイムライン表示（ホーム / ローカル / ソーシャル / 連合）+ 無限スクロール + 相対時刻・ハンドル・公開範囲・返信インジケータ・末尾ハッシュタグチップ
- テキスト投稿（公開範囲選択、文字数カウンター）
- 投稿詳細・スレッド表示
- アクションメニュー（お気に入り / ブースト / ブックマーク）
- プリセットサーバーリスト
- 通知一覧（無限スクロール・プルリフレッシュ対応）
- Misskey リアクション（絵文字ピッカー・リアクションチップ表示）
- ストリーミング（WebSocket・Mastodon / Misskey 両対応・自動再接続）

### 未実装（優先度順）

- タイムライン表示の改善
  - 長文の折り畳み（展開/折り畳み切り替え）
  - 末尾ハッシュタグの全タグ表示切り替え（現在は先頭3つのみ）
  - メディア添付サムネイル表示
- メディア添付（画像選択 + アップロード）
- 検索（アカウント・ハッシュタグのみ。全文検索は対象外）
- ユーザープロフィール
- 削除して下書きに戻す
- ブックマークのタイムライン
- お知らせ（サーバーからの告知）
- 引用（Mastodon: quote / Misskey: 引用リノート）
- 予約投稿（Mastodon / Misskey 両対応）
- 下書き（Misskey のみ）
- モロヘイヤ連携

### 実装しない機能

- 投稿の更新（Mastodon）— SNS にふさわしい機能と判断しないため
- 全文検索 — サーバーリソースの制約により対象外。代替として [notestock](https://notestock.osa-p.net) / [f.chomechome](https://f.chomechome.jp) への誘導を行う

## ドキュメント表記規約

モロヘイヤ側の規約に合わせる:

- **サーバーの呼称**: 「インスタンス」ではなく「サーバー」を使う
- **ファイル参照**: マークダウンリンクにする
