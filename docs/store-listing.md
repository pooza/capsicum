# ストア掲載情報

## アプリ名

capsicum

## 短い説明文（80文字以内）

Fediverse クライアント。複数サーバー・アカウントに対応。

## App Store サブタイトル（30文字以内）

Fediverse クライアント

## App Store プロモーションテキスト

分散型SNSを、ひとつのアプリで。

## 詳細な説明文

capsicum は、Mastodon / Misskey 対応の Fediverse クライアントアプリです。

capsicum is a Japanese-only app.
There is no English localization, and an English version is not planned. The interface, in-app text, documentation, and support are all provided in Japanese only. Please take this into account before downloading.

capsicum が提案するのは、アプリ単体の体験ではなく、サーバーとの一体感です。開発者自身が運営するサーバーでは、サーバーサイド拡張との連携により、アニメ実況支援をはじめとした独自機能が利用できます。この一体感こそが capsicum の存在意義です。

どなたでもお使いいただけますが、開発の優先順位は開発者のサーバーのメンバーにとっての利便性が最優先です。外部サーバーのユーザーに対するサポートや、開発者のサーバーで使用していないバージョン・フォークへの対応は保証しません。

◆ モロヘイヤ連携（mulukhiya-toot-proxy）

開発者のサーバーで運用しているサーバーサイド拡張「モロヘイヤ」と連携し、以下の機能が自動的に有効になります。

- エピソードブラウザ — 放送中のアニメからエピソードを選んで実況投稿
- タグセット — 作品名・放送枠などのハッシュタグをワンタップで挿入
- 実況支援 — アニメ実況に特化した投稿フロー
- Annict 連携 — 視聴後の感想・評価を Annict に直接記録（ブラウザ切替なしで実況〜感想まで完結）
- デフォルトハッシュタグ — プリセットサーバーでは、サーバーが提供するハッシュタグが自動的に投稿に付与されます

◆ プッシュ通知

Mastodon / Misskey の両方でプッシュ通知を受信できます。バックグラウンドやアプリを閉じている状態でも、通知の種別と内容が個別に表示されます。

Misskey は upstream の仕様上、通常サードパーティアプリからは通知登録ができませんが、プリセットに含まれるモロヘイヤ導入済みサーバー（ダイスキー等）では専用経路でプッシュ通知を受け取れます。

プリセットサーバーのユーザーは、開発者が運営する中継サーバー経由で無償で利用できます。それ以外のサーバーのユーザーには、インフラ維持費のため将来的に有償での提供を予定しています。

◆ 主な機能

- ナウプレ共有 — Apple Music や Spotify など、再生アプリの「共有」から capsicum を選ぶだけで `#nowplaying` 付きの投稿を作成
- Annict 連携 — 視聴中のアニメに対する実況投稿〜視聴後の感想記録までを capsicum 内で完結
- 劇中ワードサジェスト — IME の変換候補に出ない専門ワード（必殺技名・キャラ名など）を、ひらがな読みから補完。アニメ実況の即時入力を支援
- 複数サーバー・アカウントの切り替え
- 引用投稿の表示・作成（Mastodon / Misskey）
- Misskey リアクション・クリップ・ドライブ・チャンネル・ページ・メッセージ・Misskey Play
- アンケート作成・投票
- 予約投稿・投稿の翻訳・言語選択
- 絵文字ピッカー・カスタム絵文字・MFM 描画
- ハッシュタグフォロー・タブ固定
- テーマカラー・フォントサイズ・表示カスタマイズ（絶対時間・画像ぼかし・投稿前確認）
- リアルタイム更新（WebSocket ストリーミング）
- サポーター（投げ銭）— 開発を応援できる投げ銭機能

コードの大半は Claude Code によって書かれています。

capsicum はオープンソース（AGPL-3.0）です。
https://capsicum.shrieker.net

## カテゴリ

ソーシャルネットワーキング

## App Store キーワード（100文字以内）

Mastodon,Misskey,Fediverse,SNS,分散型,マストドン,ミスキー,ソーシャル

## 年齢レーティング

ユーザー生成コンテンツを含む SNS クライアント
- Google Play: IARC で「ユーザー生成コンテンツあり」と回答
- App Store: 17+（無制限のウェブアクセス / ユーザー生成コンテンツ）

## プライバシーポリシー URL

https://capsicum.shrieker.net/privacy-policy

## マーケティング URL（App Store）/ ウェブサイト（Google Play）

https://capsicum.shrieker.net

## サポート URL

https://github.com/pooza/capsicum/issues

## 英語ローカライズなしの注記（#695・暫定）

App Store / Google Play / Microsoft Store の英語（en-US）説明文に、以下の注記を掲載する。英語表示で見つけた利用者に、日本語専用であることを明示するための暫定対応。v1.37 で en-US ローカライズ宣言自体を削除する（#695）までのつなぎ。

App Store ぶんはバージョン提出時のみ反映できるため v1.36.1 提出に同梱する。Google Play / Microsoft Store は随時反映可。

> capsicum is a Japanese-only app.
> There is no English localization, and an English version is not planned. The interface, in-app text, documentation, and support are all provided in Japanese only. Please take this into account before downloading.
