# capsicum

Mastodon / Misskey 対応の Fediverse クライアントアプリです。コードの大半は [Claude Code](https://claude.ai/claude-code) によって書かれています。

capsicum が提案するのは、アプリ単体の体験ではなく、サーバーとの一体感です。開発者自身が運営するサーバーでは、サーバーサイド拡張との連携により、アニメ実況支援をはじめとした独自機能が利用できます。この一体感こそが capsicum の存在意義です。

どなたでもお使いいただけますが、開発の優先順位は開発者のサーバーのメンバーにとっての利便性が最優先です。外部サーバーのユーザーに対するサポートや、開発者のサーバーで使用していないバージョン・フォークへの対応は保証しません。

## ダウンロード

[![Get it on Google Play](https://img.shields.io/badge/GET_IT_ON-Google_Play-000000?style=for-the-badge&logo=googleplay&logoColor=white)](https://play.google.com/store/apps/details?id=net.shrieker.capsicum)
[![Download on the App Store](https://img.shields.io/badge/Download_on_the-App_Store-000000?style=for-the-badge&logo=apple&logoColor=white)](https://apps.apple.com/jp/app/capsicum/id6760206608)

## モロヘイヤ連携

開発者のサーバーで運用しているサーバーサイド拡張 [mulukhiya-toot-proxy](https://github.com/pooza/mulukhiya-toot-proxy)（モロヘイヤ）と連携し、以下の機能が自動的に有効になります。

- **エピソードブラウザ** — 放送中のアニメからエピソードを選んで実況投稿
- **タグセット** — 作品名・放送枠などのハッシュタグをワンタップで挿入
- **実況支援** — アニメ実況に特化した投稿フロー
- **メディアカタログ** — サーバーに投稿されたメディアを一覧・検索できるギャラリー
- **デフォルトハッシュタグ** — プリセットサーバーでは、サーバーが提供するハッシュタグが自動的に投稿に付与されます

## プッシュ通知

Mastodon / Misskey の両方でプッシュ通知を受信できます。バックグラウンドやアプリを閉じている状態でも、通知の種別と内容が個別に表示されます。Mastodon / Misskey サーバーが発行する Web Push を APNs / FCM に変換する専用の中継サーバー（リレー）を経由する方式で、iOS でも実用的に通知が届きます。

Misskey は upstream の仕様上、通常はサードパーティアプリからのプッシュ通知登録ができませんが、プリセットに含まれるモロヘイヤ導入済みサーバー（ダイスキー等）では専用経路で受信できます。

プリセットサーバーのユーザーは、開発者が運営するリレー経由で無償で利用できます。それ以外のサーバーのユーザーには、インフラ維持費のため将来的に有償での提供を予定しています。

## 主な機能

- **ナウプレ共有** — Apple Music や Spotify などの「共有」から capsicum を選ぶだけで、`#nowplaying` 付きの投稿を作成
- 複数サーバー・アカウントの切り替え
- 引用投稿の表示・作成（Mastodon / Misskey）
- Misskey リアクション・クリップ・ドライブ・チャンネル・Misskey Play
- アンケート作成・投票
- 予約投稿・投稿の翻訳・言語選択
- 絵文字ピッカー・カスタム絵文字・MFM 描画
- ハッシュタグフォロー・タブ固定
- テーマカラー・フォントサイズ・表示カスタマイズ（絶対時間・画像ぼかし・投稿前確認）
- リアルタイム更新（WebSocket ストリーミング）

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

設計の出発点は [Kaiteki](https://github.com/Kaiteki-Fedi/Kaiteki) の Adapter パターンとモデル構造です。

## ドキュメント

- [開発ガイド](docs/CLAUDE.md) — 設計方針・実装ステータス・リリース計画
- [ストアリリース手順書](docs/store-release-guide.md) — 署名・Fastlane・ビルド・アップロード手順

詳しくは [capsicum.shrieker.net](https://capsicum.shrieker.net) をご覧ください。

## ライセンス

[AGPL-3.0](LICENSE)
