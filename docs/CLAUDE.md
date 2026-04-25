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

### 拡張機能の主なエンドポイント

モロヘイヤが提供する拡張 API の主なエンドポイント一覧。個別の実装状態は GitHub Issues が正本。

| 機能 | エンドポイント |
|------|--------------|
| サーバー情報表示 | `GET /mulukhiya/api/about` |
| お気に入りタグ | `GET /mulukhiya/api/tagging/favorites` |
| 番組情報 | `GET /mulukhiya/api/program` |
| エピソードブラウザ | `GET /mulukhiya/api/program/works`, `.../episodes` |
| Annict OAuth | `GET /mulukhiya/api/annict/oauth_uri`, `POST /mulukhiya/api/annict/auth` |
| タグ付け | `POST /mulukhiya/api/status/tags` |
| ユーザー設定 | `GET/POST /mulukhiya/api/config` |
| ハンドラー一覧 | `GET /mulukhiya/api/admin/handler/list` |
| メディアカタログ | `GET /mulukhiya/api/media` |

## UI 設計方針

### 用語統一

capsicum は「最新版を対象にする」方針で開発しており、UI 表示に用いる用語も最新の Mastodon / Misskey に追従する。古い Mastodon で使われていた用語は最新 Mastodon しか知らない新規ユーザーには通じないため、UI・エラーメッセージ・ダイアログ等ユーザー目に触れる文字列では使用しない。

| 旧称 / 別称 | 現在の呼称 | 種別 | 備考 |
|------|-----------|------|------|
| トゥート | 投稿 | 廃止語 | 最新 Mastodon では使われていない |
| 未収載 | ひかえめな公開 | 廃止語 | 最新 Mastodon では使われていない |
| インスタンス | サーバー | 廃止語 | Mastodon / Misskey 共通で廃止 |
| ノート | 投稿 | 統一 | Misskey では現役用語。capsicum では「投稿」に統一 |

「廃止語」は最新版で廃止された用語であり、capsicum でも一切使わない。「統一」は他方の SNS では現役だが、capsicum では UI 一貫性のためにどちらか片方に寄せている用語を指す。

コード内部の識別子（`Instance`, `InstanceProbe` 等）は変更不要。UI に表示する文字列のみ統一する。文字列リテラルをコード全体に散らすと用語の取りこぼしが起きやすいため、[post_scope_display.dart](../packages/capsicum/lib/src/ui/util/post_scope_display.dart) のように中央集約した定数を参照する設計を優先する。

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

### タイムラインの読み込み挙動

タイムラインをスクロール中に一旦読み込みが止まり、少し戻すと再読み込みされる挙動はページネーションの正常な動作であり、不具合ではない。ユーザー報告の表現に引きずられずに判断する。

### モロヘイヤ連携画面の導線

エピソードブラウザはタグセット BottomSheet 内のメニュー項目として配置する（Mastodon 改造版 WebUI と同じ動線）。投稿画面のツールバーに独立したアイコンを置く方式は、ユーザーに発見されにくいため採用しない。

### プッシュ通知

プッシュ通知には、Mastodon の Web Push を APNs/FCM に変換する中継サーバーの運用が必要。capsicum は主に自前サーバー（プリセット登録済み）のユーザー向けに開発されており、プリセットサーバーのユーザーに対しては将来的に無償でリレーを提供する想定である。外部ユーザー向けの有償提供はそのコスト補填のための仕組みであり、[運営元](#運営元) 節の「商品扱いとする方針」の根拠になっている。

v1.15 の観測性強化（#293）により、iOS のバックグラウンド通知は発火回数 0回で事実上機能していないことが確認された。v1.18 でプッシュ通知リレー（[#52](https://github.com/pooza/capsicum/issues/52)）を実装し、根本解決済み。リレーサーバー（Ruby、Linode、`relay.capsicum.shrieker.net`）の設計・インフラ詳細は [push-relay-plan.md](push-relay-plan.md) を参照。具体的な課金設計（料金体系・ストア課金統合等）は、外部ユーザーの一定規模が確認されるまでは保留する。

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

Codex（`chatgpt-codex-connector[bot]`）のレビューコメントを確認し、未対応なら修正・返信・+1 リアクションをつける。**返信とリアクションの両方が揃って「完了」**（片方だけでは同期時に未完了と判定される）。詳細な判定手順は [sync-procedure.md](sync-procedure.md) の Codex セクションを参照。

## ディレクトリ構成

```text
capsicum/
  docs/                   # 開発ドキュメント
    CLAUDE.md             # 本ファイル
    architecture.md       # アーキテクチャ設計
    tech-notes.md         # 実装の落とし穴・API 固有の注意点
    dev-environment.md    # 開発マシン・検証端末・Sentry 環境
    desktop-plugin-compatibility.md  # デスクトップ対応のプラグイン棚卸し
    release-pipeline.md   # リリースパイプライン構想（fastlane + GitHub Actions）
    sync-procedure.md     # セッション開始時の同期手順
    archive/              # 過去の記録（現役運用では参照しない）
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

### 起票の規約

- 報告元が Fedi の投稿である場合、本文には **投稿の URL リンクのみ** を記載し、報告者の Fedi アカウント名（`@user@server`）は書かない。`@` は GitHub 上でメンションとして解釈され、Fedi と GitHub のユーザー名が一致するとは限らないため、無関係な GitHub ユーザーへの意図しないメンションになる
- 公開投稿ならリンクを辿れば報告者情報に到達できるので、アカウント名を本文に含める必要はない

### マイルストーン運用

- **大更新は独立マイルストーンに単独配置**。UI の構造変更・既存モデルの拡張・複数画面への影響などが絡む「大更新」は、他に同規模以上の項目がないマイルストーンに入れる。並走させると設計検討・実装・動作確認がいずれも中途半端になるため。添える項目は小粒な改善のみに限定する
- **マイルストーン未設定は意図的な場合がある**。実現性検討中・Flutter 側の対応待ち・横断的タスクなどで pooza が意図的に未割り当てにしていることがあるため、「トリアージが必要」等と機械的に指摘しない。同期報告では一覧として淡々と列挙するに留める
- **ユーザー要望の振り分け基準**:
  - 不具合 → 可能なら着手中のマイルストーンに入れる
  - 改善要求（小規模）→ 着手中のマイルストーンに入れる
  - 改善要求（中〜大規模）→ 空いている先のマイルストーンに送る
  進行中のリリースを遅らせないバランスを取りつつ、ユーザーの声には必ず何かしらの形で応える

### コミットの分割方針

コミットはなるべく Issue ごとに分ける。レビュー・revert・cherry-pick の粒度を保つため。同じファイルに複数 Issue の変更が混在して分離できない場合のみ、まとめてよい。

### クロスリファレンス

- capsicum → モロヘイヤ: `pooza/mulukhiya-toot-proxy#XXXX`
- モロヘイヤ → capsicum: `pooza/capsicum#XXXX`

## 運営元

capsicum の運営元は有限会社ビーショック（<https://www.b-shock.co.jp>）。将来の課金（通知リレーの有償提供）を見据え、商品扱いとする方針。

- 特商法表示・ストア販売者情報・問い合わせ窓口は法人名義
- 問い合わせは会社サイト経由で Google Workspace 管理のアドレスに届く
- 「個人開発のアプリ」という表現は矛盾しないので OK。著作権表記は個人名義のままで問題なし

具体的な課金設計（料金体系・ストア課金統合・外部決済等）は、外部ユーザーの一定規模が確認されるまでは保留する。capsicum は本来プリセットサーバー（自前サーバー）のユーザー向けのクライアントであり、外部ユーザーの存在が確認された段階で、そのコスト補填のための仕組みとして有償提供を具体化する。

## 自前サーバー

主な動作確認・連携対象。Mastodon / Misskey フォークを運用しており、モロヘイヤ導入済み。

| 呼称 | ドメイン | 種別 | 備考 |
| --- | --- | --- | --- |
| 美食丼 | `mstdn.b-shock.org` | Mastodon | メインの運用サーバー。#capsicum タグ TL の集約先 |
| デルムリン丼 | `mstdn.delmulin.com` | Mastodon | デフォルトハッシュタグ `#delmulin` |
| キュアスタ！ | `precure.ml` | Mastodon | デフォルトハッシュタグ `#precure_fun` |
| きゅあすきー | `mk.precure.fun` | Misskey | デフォルトハッシュタグ `#precure_fun` |
| ダイスキー | `misskey.delmulin.com` | Misskey | デフォルトハッシュタグ `#delmulin` |

上記はログイン画面のプリセットサーバー一覧にも掲載している。デフォルトハッシュタグは、ローカルタイムラインをハッシュタグタイムラインに置換する独自設計で、これらのサーバーでのみ有効。

## 対応対象外のプラットフォーム

- **WSA (Windows Subsystem for Android)**: WSA 自体が不安定で検証環境として成立しない上、Microsoft が 2025-03 にサポート終了済み。テスターからの検証希望報告があっても Issue 化はせず対応対象外とする

## 関連リポジトリ

| リポジトリ | 内容 |
|-----------|------|
| [mulukhiya-toot-proxy](https://github.com/pooza/mulukhiya-toot-proxy) | モロヘイヤ本体。API 仕様の参照元 |
| [mastodon](https://github.com/pooza/mastodon) | Mastodon フォーク（美食丼 / デルムリン丼 / キュアスタ！） |
| [misskey](https://github.com/pooza/misskey) | Misskey フォーク（ダイスキー） |
| [Kaiteki](https://github.com/Kaiteki-Fedi/Kaiteki) | 設計の参考元（アーカイブ済み） |
| [capsicum-relay](https://github.com/pooza/capsicum-relay) | プッシュ通知リレーサーバー（Web Push → APNs / FCM）。Ruby + Sinatra |
| [capsicum-site](https://github.com/pooza/capsicum-site) | プロジェクトサイト（`capsicum.shrieker.net`）。GitHub Pages で配信。プライバシーポリシー・子どもの安全基準等 |

## リリース計画

リリース手順・ストア設定の詳細は [store-release-guide.md](store-release-guide.md) を参照。

[GitHub Milestones](https://github.com/pooza/capsicum/milestones) が正本。各マイルストーンの概要・スコープはマイルストーンの description に記載し、CLAUDE.md には複写しない。個別 Issue の一覧・ステータスも同様。

最新リリース: **v1.20.1**（2026-04-25 リリース、ストア公開済み）。v1.20.0 のプッシュ通知本実装の追補リリース。iOS リリース版で Keychain Access Group が distribution 署名で解決できず NSE が復号鍵を引けない不具合 (#373)、モロヘイヤ v5.19.0 未満サーバーへの Misskey push 登録を notSupported 寄せ (#365)、FCM 一過性エラー (`MISSING_INSTANCEID_SERVICE` / `SERVICE_NOT_AVAILABLE`) のリトライ (#374)、バックグラウンド isolate / NSE 復号失敗の観測性追加 (#366) ほか。リレーサーバ側も同時に v1.20.1 に更新（APNs socket 切断クラッシュ防止・ペイロード上限超過の retry storm 抑止・Content-Encoding 診断ログ）。v1.20.0 は 2026-04-23、v1.0.0 は 2026-03-14 にストア公開。リリース履歴の詳細は [GitHub Releases](https://github.com/pooza/capsicum/releases) を参照。

### デスクトップ対応

macOS / Linux / Windows のデスクトップ環境への展開。動機は、iOS 版を Mac 上で実況用途に使って手応えがあること。v1.21 以降のマイルストーンに組み込み済み（当初は v1.19 → v1.20 → v1.21 と後ろ倒しを重ね、プッシュ通知完成 v1.20 を挟んだ上で着手する並びに落ち着いた）。

1. **第1段階: macOS ネイティブ化（v1.21）** — `flutter config --enable-macos-desktop` による macOS ビルドに移行し、iOS の Mac 実行から卒業する。コスト最小で実況用途に直接効く。プラグインのデスクトップ対応状況の棚卸しも兼ねる。video_player → media_kit の事前調査もここで行う
2. **第2段階: バックグラウンド/通知モデルの再設計（v1.23）** — デスクトップにはバックグラウンド更新の概念がないため、通知ポーリング相当の仕組みを抽象化して差し替え可能にする。v1.18 のプッシュ通知リレー完了・v1.19 (#348) での workmanager / iOS BGTask 撤去後、モバイル側は APNs / FCM 一本化済み。デスクトップ向けには Dart `Timer` + 常駐前提のフォールバック実装を含む `BackgroundTaskScheduler` 層と、`flutter_local_notifications` のデスクトップ対応差分を吸収する層が要る
3. **第3段階: Linux / Windows 対応（v1.24）** — 第2段階で通知周りが整理され、プラグイン依存の棚卸しが済んでから本格着手。配布形態（Linux: Flathub + AppImage、Windows: Microsoft Store）もこの段階で決める。Linux と Windows のどちらを先にやるかは未定。v1.21 で事前調査した video_player → media_kit の本移行もこの段階

第1段階と第2段階のあいだに **v1.22: Misskey メッセージ機能対応** を単独配置する（大更新を他の大更新と並走させない方針）。

動機の具体例:

- iOS アプリを Mac で動かす (Designed for iPad) モードだとファイル選択が iOS のドキュメントピッカーになり、Mac のネイティブな Finder ベースの選択ができない。画像・動画添付が実況用途で地味に手間。macOS ネイティブビルドなら `file_selector` / `image_picker` の macOS 実装が NSOpenPanel を出してくれる
- キーボードショートカット・ウィンドウ管理・通知センター連携など、デスクトップ固有の体験も macOS ネイティブなら自然に組める

設計指針（分岐を最小化するためのルール）:

- **UI の分岐軸はプラットフォームではなく画面幅**にする。`Platform.isXxx` は UI 層に基本入れない。iPad で画面が広ければデスクトップと同じレイアウトになるべきだし、デスクトップでウィンドウを狭めたらモバイル風になるべき。Responsive design の単一軸に集約する
- **プラットフォーム固有機能は必ず抽象層を経由**させる。`flutter_local_notifications` を直接呼ばず、`BackgroundTaskScheduler` のようなインターフェースを挟む。第2段階（通知モデル再設計）の主題と噛み合う
- **プラットフォーム定数はテーブル化**。ショートカット・メニュー構成などは1箇所にまとめ、プラットフォームごとにテーブルを差し替える
- **条件付きコンパイル（conditional import）は最後の手段**。使う場合も `lib/src/platform/` のような特定ディレクトリに閉じ込める

配布・ストア・ツールチェーンの方針（macOS は Apple Developer Program を iOS と共用、Windows は Microsoft Store、Linux は Flathub + AppImage、Snap は不採用）、および段階的な実装順序は [release-pipeline.md](release-pipeline.md) を参照。プラグインのデスクトップ対応状況の棚卸しは [desktop-plugin-compatibility.md](desktop-plugin-compatibility.md) にまとめている。第2段階では `BackgroundTaskScheduler`（[#328](https://github.com/pooza/capsicum/issues/328)）/ `MediaPicker`（[#329](https://github.com/pooza/capsicum/issues/329)）/ 通知サブシステム（[#330](https://github.com/pooza/capsicum/issues/330)）の抽象化が主題となる。

制約: モロヘイヤ透過プロキシ前提のためネットワーク層は問題にならない。

運用ルール:

- リリース前レビューは各マイルストーンの Issue をすべて消化した後、リリース直前に毎度実施する。[#27](https://github.com/pooza/capsicum/issues/27) の「セキュリティレビュー」だけでは実害バグを取りこぼすため、以下 5 観点をサブエージェントで並列に走らせる（詳細は [store-release-guide.md](store-release-guide.md) の「リリース前レビュー」節）:
  - セキュリティ（`/security-review` スキル）
  - API 契約（Mastodon / Misskey / モロヘイヤの REST 正確性、アダプター interface 整合）
  - 並行性・ライフサイクル（async 連鎖、Riverpod provider 寿命、dispose、race）
  - エラー処理・観測性（try/catch カバレッジ、Sentry 計装、secrets scrub、UX）
  - コーディングスタイル・規約整合性（用語統一、ハードコーディング、命名の揺れ、重複ロジック、規約違反）
- ATOK 二重入力（[#54](https://github.com/pooza/capsicum/issues/54)）は Flutter 側の対応待ち。リリースごとにリリースノートの「既知の不具合」に記載し、Flutter 側の関連 issue の動向を確認する
- マイルストーン未設定の Issue は `no:milestone` フィルタで確認する

### 実装しない機能

- 投稿の更新（Mastodon）— SNS にふさわしい機能と判断しないため

## セッション開始時の同期手順

会話の最初に「進捗を同期してください」等の指示があった場合、[sync-procedure.md](sync-procedure.md) の手順に従う。

## ドキュメント表記規約

モロヘイヤ側の規約に合わせる:

- **サーバーの呼称**: 「インスタンス」ではなく「サーバー」を使う
- **ファイル参照**: マークダウンリンクにする

### CLAUDE.md の定期見直し

CLAUDE.md はセッション開始時に全文読み込むため、完了済みの情報や歴史的経緯が蓄積するとノイズとなり、重要な設計方針の認識精度が下がる。マイルストーン数回ごとに CLAUDE.md を見直し、完了済み・陳腐化した情報を削除するか外部参照に集約する。
