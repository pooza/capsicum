# capsicum

Mastodon / Misskey 対応の Fediverse クライアント（Flutter）。iPhone / iPad / Android に対応しています。

## 特徴

- 複数のサーバー・アカウントを登録して切り替え
- タイムライン閲覧（ホーム / ローカル / 連合 / リスト / ハッシュタグ）と無限スクロール
- テキスト・メディア・投票付き投稿（公開範囲選択、CW 対応）
- リプライ・ブースト・お気に入り・ブックマーク
- Misskey リアクション（絵文字ピッカー付き）
- リアルタイム更新（WebSocket ストリーミング）
- MFM / HTML / カスタム絵文字の描画
- 通知一覧・検索・プロフィール表示
- フォロー / ミュート / ブロック操作
- [mulukhiya-toot-proxy](https://github.com/pooza/mulukhiya-toot-proxy)（モロヘイヤ）連携 — タグセット・エピソードブラウザ等

## 開発

```bash
# 依存関係の取得
melos bs

# コード生成
melos gen

# フォーマットチェック
dart format --set-exit-if-changed .

# 静的解析
dart analyze --fatal-infos
```

コードの大半は [Claude Code](https://claude.ai/claude-code) によって書かれています。設計の出発点は [Kaiteki](https://github.com/Kaiteki-Fedi/Kaiteki) の Adapter パターンとモデル構造です。

## ドキュメント

- [開発ガイド](docs/CLAUDE.md) — 設計方針・実装ステータス・リリース計画
- [ストアリリース手順書](docs/store-release-guide.md) — 署名・Fastlane・ビルド・アップロード手順

## 方針

汎用の Fediverse クライアントですが、開発者自身が運営するサーバーのメンバーの利益を最優先します。外部ユーザーからの要望や、開発者のサーバーで使用していないバージョン・フォークへの対応は保証しません。

詳しくは [capsicum.shrieker.net](https://capsicum.shrieker.net) をご覧ください。

## ライセンス

[AGPL-3.0](LICENSE)
