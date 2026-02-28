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
- ストレージ層の見直し（Hive → 要検討）
- HTTP クライアントの見直し（`http` → 要検討）
- 初期スコープは Mastodon + Misskey に絞る（Tumblr 等は除外）
- Widget テストの追加
- L10n はサブモジュールでなく直接管理

## モロヘイヤ連携

### 基本方針

モロヘイヤはサーバーサイドのインフラであり、ユーザーが存在を意識する必要はない。
capsicum はサーバーが提供する API を検出し、利用可能な機能に応じて UI を出し分ける。

### 検出

サーバー接続時に `/api/v1/mulukhiya/diag`（Mastodon）または `/api/mulukhiya/diag`（Misskey）を叩き、モロヘイヤの有無を判定する。
詳細な検出プロトコルはモロヘイヤ側で文書化予定（[capsicum-requirements.md](https://github.com/pooza/mulukhiya-toot-proxy/blob/main/docs/capsicum-requirements.md)）。

### 対応予定の拡張機能

| 機能 | モロヘイヤ側エンドポイント | 優先度 |
|------|--------------------------|--------|
| サーバー情報表示 | `GET /mulukhiya/api/about` | P1 |
| ユーザー設定 | `GET/POST /mulukhiya/api/config` | P2 |
| タグ付け | `POST /mulukhiya/api/status/tags` | P2 |
| ハンドラー一覧 | `GET /mulukhiya/api/admin/handler/list` | P2 |
| お気に入りタグ | `GET /mulukhiya/api/tagging/favorites` | P3 |
| メディアカタログ | `GET /mulukhiya/api/media` | P3 |
| 番組情報 | `GET /mulukhiya/api/program` | P4 |

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
    architecture.md       # アーキテクチャ設計（予定）
    mulukhiya-integration.md  # モロヘイヤ連携仕様（予定）
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

## ドキュメント表記規約

モロヘイヤ側の規約に合わせる:

- **サーバーの呼称**: 「インスタンス」ではなく「サーバー」を使う
- **ファイル参照**: マークダウンリンクにする
