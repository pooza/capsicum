# capsicum

Mastodon / Misskey 対応の Fediverse クライアントアプリです。コードの大半は [Claude Code](https://claude.ai/claude-code) によって書かれています。

capsicum が提案するのは、アプリ単体の体験ではなく、サーバーとの一体感です。開発者自身が運営するサーバーでは、サーバーサイド拡張との連携により、アニメ実況支援をはじめとした独自機能が利用できます。この一体感こそが capsicum の存在意義です。

どなたでもお使いいただけますが、開発の優先順位は開発者のサーバーのメンバーにとっての利便性が最優先です。外部サーバーのユーザーに対するサポートや、開発者のサーバーで使用していないバージョン・フォークへの対応は保証しません。

## ダウンロード

[![Get it on Google Play](https://img.shields.io/badge/GET_IT_ON-Google_Play-000000?style=for-the-badge&logo=googleplay&logoColor=white)](https://play.google.com/store/apps/details?id=net.shrieker.capsicum)
[![Download on the App Store](https://img.shields.io/badge/Download_on_the-App_Store-000000?style=for-the-badge&logo=apple&logoColor=white)](https://apps.apple.com/jp/app/capsicum/id6760206608)
[![Download on the Mac App Store](https://img.shields.io/badge/Download_on_the-Mac_App_Store-000000?style=for-the-badge&logo=apple&logoColor=white)](https://apps.apple.com/jp/app/capsicum/id6760206608)
[![Linux AppImage](https://img.shields.io/badge/Linux-AppImage-000000?style=for-the-badge&logo=linux&logoColor=white)](https://capsicum.shrieker.net/desktop#linux)
[![Get it from Microsoft](https://img.shields.io/badge/Get_it_from-Microsoft-000000?style=for-the-badge&logo=microsoft&logoColor=white)](https://apps.microsoft.com/detail/9np2gr7m2w6p)

## macOS / Linux / Windows 版について

- **macOS**: App Store からダウンロードできます（iOS / iPadOS と同一の App レコード・Universal Purchase）。Apple silicon / Intel 両対応
- **Linux**: [GitHub Releases](https://github.com/pooza/capsicum/releases) から AppImage（x86_64）を配布。Flathub への提出は断念し、AppImage 単独運用に確定しました。アプリ一覧への統合インストールはワンライナーで完結します（[導入手順](https://capsicum.shrieker.net/desktop#linux)）

  ```bash
  curl -fsSL https://capsicum.shrieker.net/install.sh | bash
  ```

- **Linux の日本語入力（IM）**: GTK IM module の `ibus` / `fcitx5` / `uim` を AppImage に同梱。`ibus-mozc` (開発者環境) と `fcitx5` (外部ユーザー報告) は動作確認済み。`uim` 経路は **未検証 (best-effort)**。動かない場合は [Issue](https://github.com/pooza/capsicum/issues) にご報告ください
- **Windows**: [Microsoft Store](https://apps.microsoft.com/detail/9np2gr7m2w6p) から導入できます（v1.27 で公開）。Windows の公式配布ルートは Microsoft Store 単独です

## モロヘイヤ連携

開発者のサーバーで運用しているサーバーサイド拡張 [mulukhiya-toot-proxy](https://github.com/pooza/mulukhiya-toot-proxy)（モロヘイヤ）と連携し、以下の機能が自動的に有効になります。

- **エピソードブラウザ** — 放送中のアニメからエピソードを選んで実況投稿
- **タグセット** — 作品名・放送枠などのハッシュタグをワンタップで挿入
- **実況支援** — アニメ実況に特化した投稿フロー
- **[Annict 連携](docs/annict-integration.md)** — 視聴後の感想・評価を Annict に直接記録 (ブラウザ切替なしで実況〜感想まで完結)
- **メディアカタログ** — サーバーに投稿されたメディアを一覧・検索できるギャラリー
- **デフォルトハッシュタグ** — プリセットサーバーでは、サーバーが提供するハッシュタグが自動的に投稿に付与されます

## プッシュ通知

Mastodon / Misskey の両方でプッシュ通知を受信できます。バックグラウンドやアプリを閉じている状態でも、通知の種別と内容が個別に表示されます。Mastodon / Misskey サーバーが発行する Web Push を APNs / FCM に変換する専用の中継サーバー（リレー）を経由する方式で、iOS でも実用的に通知が届きます。

Misskey は upstream の仕様上、通常はサードパーティアプリからのプッシュ通知登録ができませんが、プリセットに含まれるモロヘイヤ導入済みサーバー（ダイスキー等）では専用経路で受信できます。

プリセットサーバーのユーザーは、開発者が運営するプッシュ通知リレー経由で無償で利用できます。それ以外のサーバーのユーザーには、インフラ維持費のため月額のサブスクリプション（アプリ内課金・v2.0〜）で提供しています。

## 主な機能

- **デッキ表示**（v2.0〜） — タイムライン・スレッド・プロフィールなどを横に並べて同時に見る、マルチカラムの表示。カラムごとにアカウントを持てるので、複数アカウントを並べて読めます
- **添付画像のレイヤ編集**（v2.0〜） — 投稿する画像に文字やカスタム絵文字のスタンプを重ねる。位置・拡縮・回転・不透明度・重ね順を後から編集でき、下書きにも残ります
- **劇中ワードサジェスト**（v1.35〜） — IME の変換候補に出てこない専門用語（必殺技名・キャラクター名など）を、ひらがなの読みから検索して投稿フォームに挿入。辞書を用意したモロヘイヤ導入サーバーで利用できる独自機能
- **ナウプレ** — 聴いている曲を `#nowplaying` 付きの投稿としてワンアクションで作成。Apple Music や Spotify などの「共有」から作るほか、投稿フォームの ♪ ボタンから再生中の曲を直接取得できます（デスクトップの Linux / Windows は v1.33〜、iPhone / iPad / Mac の Apple Music は v1.37〜）
- **Annict 連携** — 視聴中のアニメに対する実況投稿〜視聴後の感想記録までを capsicum 内で完結 (詳細は [docs/annict-integration.md](docs/annict-integration.md))
- **デスクトップ通知**（v1.34〜） — macOS / Linux / Windows でも、アプリ起動中の WebSocket 接続経由で通知を OS のローカル通知に表示（macOS はネイティブ APNs にも対応）
- 複数サーバー・アカウントの切り替え
- 引用投稿の表示・作成（Mastodon / Misskey）
- Misskey リアクション・クリップ・ドライブ・チャンネル・ページ・Misskey Play
- Misskey メッセージ / グループチャット（スレッド形式チャット・リアクション・ファイル添付）
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
melos run build_runner

# フォーマットチェック
dart format --set-exit-if-changed .

# 静的解析
dart analyze --fatal-infos
```

### 動かす

```bash
tool/dev-run.sh -d macos     # Windows は tool\dev-run.ps1
```

コード生成から `flutter run` までを 1 本で回します。`-d` などの引数はそのまま `flutter run` へ渡ります。オプションの一覧は [tool/README.md](tool/README.md) にあります。手順の詳細と、手で打つときに踏みやすい罠は [docs/dev-environment.md の「`flutter run` の実行手順」](docs/dev-environment.md#flutter-run-の実行手順)にあります。

秘密（`RELAY_SECRET` / `SENTRY_DSN`）と Android の `google-services.json` は**無くても起動します**。使えなくなるのは**プッシュ通知だけ**で、タイムライン・投稿などは影響を受けません（[置かなくても動く](docs/dev-environment.md#置かなくても動く何が使えなくなるかだけ変わる)）。

設計の出発点は [Kaiteki](https://github.com/Kaiteki-Fedi/Kaiteki) の Adapter パターンとモデル構造です。

## ドキュメント

- [開発ガイド](docs/CLAUDE.md) — プロジェクトのルール・ブランチ戦略・Issue とマイルストーンの運用
- [アーキテクチャ](docs/architecture.md) — パッケージ構成・Adapter パターン・デッキ・プッシュ通知の流れ。docs 全体の案内もここにあります
- [プロダクト方針](docs/product-policy.md) — UI の設計方針・対応バージョンの考え方・運営元と課金の方向性
- [ロードマップ](docs/roadmap.md) — マイルストーンの枠と主題（個別の Issue は [GitHub Milestones](https://github.com/pooza/capsicum/milestones) が正本）
- [開発環境](docs/dev-environment.md) — セットアップと `flutter run` の手順
- [落とし穴集](docs/tech-notes.md) — 実装中に踏んだ Flutter / 各種 API の罠
- [ストアリリース](docs/store-release-guide.md) — 署名・fastlane の初回セットアップと配布方針

詳しくは [capsicum.shrieker.net](https://capsicum.shrieker.net) をご覧ください。

## ライセンス

[AGPL-3.0](LICENSE)
