# capsicum

Mastodon / Misskey 対応の Fediverse クライアントアプリです。iPhone / iPad / Android に対応しています。

## ダウンロード

<a href="https://play.google.com/store/apps/details?id=net.shrieker.capsicum"><img alt="Google Play で手に入れよう" src="https://play.google.com/intl/ja/badges/static/images/badges/ja_badge_web_generic.png" height="80"></a>

iOS 版は App Store 審査中です。

## 特徴

- 複数のサーバー・アカウントを登録して切り替え
- タイムライン閲覧（ホーム / ローカル / 連合 / リスト / ハッシュタグ）と無限スクロール
- テキスト・メディア・投票付き投稿（公開範囲選択、CW 対応、絵文字ピッカー、言語選択）
- リプライ・ブースト・お気に入り・ブックマーク
- 投稿の翻訳（Mastodon / Misskey）
- 投稿削除・削除して再編集・引用投稿
- Misskey リアクション（絵文字ピッカー付き）・Misskey Play・クリップ・ドライブ
- ハッシュタグフォロー・ハッシュタグタイムライン・タブ固定
- リアルタイム更新（WebSocket ストリーミング）
- MFM / HTML / カスタム絵文字 / プレビューカードの描画
- 通知一覧・検索・プロフィール表示・編集
- リスト管理・フォロー / フォロワー一覧・ミュート / ブロック操作
- 予約投稿・アンケート作成・チャンネル（Misskey）
- テーマカラー・フォントサイズ・タブ順序のカスタマイズ
- NSFW ぼかし・ワードフィルタ
- [mulukhiya-toot-proxy](https://github.com/pooza/mulukhiya-toot-proxy)（モロヘイヤ）連携 — タグセット・エピソードブラウザ・絵文字パレットインポート等

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
