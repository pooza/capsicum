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
| チャット | メッセージ | 統一 | Misskey の `/api/chat/*` 由来。capsicum では UI 表記を「メッセージ」に統一（コード識別子は `Chat*` のまま API 命名に追従） |

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
- **Misskey**（#248）: DM タイムライン API がない。最近の Misskey では「メッセージ」機能（スレッド形式チャット）が DM の後継と位置づけられており、こちらに対応する。v1.22 で実装完了。なお Misskey メッセージは現状実験的機能の位置付けで、追加のバグ修正・enhancement（#442 系列、#449 のレンダリング要素反映、#440 push tap 動線、グループチャット #438 等）は v1.22.x ホットフィックスではなく v1.25（Misskey メッセージ改善マイルストーン）に集約して消化する方針。利用状況が増えてホットフィックス級の判断が必要になった場合は別途見直す

### タイムラインの読み込み挙動

タイムラインをスクロール中に一旦読み込みが止まり、少し戻すと再読み込みされる挙動はページネーションの正常な動作であり、不具合ではない。ユーザー報告の表現に引きずられずに判断する。

### モロヘイヤ連携画面の導線

エピソードブラウザはタグセット BottomSheet 内のメニュー項目として配置する（Mastodon 改造版 WebUI と同じ動線）。投稿画面のツールバーに独立したアイコンを置く方式は、ユーザーに発見されにくいため採用しない。

### プッシュ通知

プッシュ通知には、Mastodon の Web Push を APNs/FCM に変換する中継サーバーの運用が必要。capsicum は主に自前サーバー（プリセット登録済み）のユーザー向けに開発されており、プリセットサーバーのユーザーに対しては将来的に無償でリレーを提供する想定である。外部ユーザー向けの有償提供はそのコスト補填のための仕組みとして残り、後述の投げ銭サブスクと同じ商品 SKU で吸収できる可能性がある。

v1.15 の観測性強化（#293）により、iOS のバックグラウンド通知は発火回数 0回で事実上機能していないことが確認された。v1.18 でプッシュ通知リレー（[#52](https://github.com/pooza/capsicum/issues/52)）を実装し、根本解決済み。リレーサーバー（Ruby、Linode、`relay.capsicum.shrieker.net`）の設計・インフラ詳細は [push-relay-plan.md](push-relay-plan.md) を参照。具体的な課金設計（料金体系・ストア課金統合等）はサポーターサブスク（[#428](https://github.com/pooza/capsicum/issues/428)）の設計検討の中で扱う。

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
    flutter-upstream-watch.md  # Flutter 上流バグの追跡（月次 chase routine と連動）
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
- 1 マイルストーンの規模は「大更新の数」で測る（件数ではなく）。詳細は[マイルストーン運用](#マイルストーン運用)節を参照

### 正本ルール

- **Issue のステータス・一覧は GitHub が正本**。CLAUDE.md や MEMORY.md に個別 Issue の一覧・対応済み/未済を複写しない
- リリース計画の確認は `gh issue list --milestone v1.0` 等で GitHub を直接参照する
- CLAUDE.md に書くのは Issue に書けない情報（マイルストーンの方針・運用ルール・設計判断の背景 等）に限定する

### 起票の規約

- 報告元が Fedi の投稿である場合、本文には **投稿の URL リンクのみ** を記載し、報告者の Fedi アカウント名（`@user@server`）は書かない。`@` は GitHub 上でメンションとして解釈され、Fedi と GitHub のユーザー名が一致するとは限らないため、無関係な GitHub ユーザーへの意図しないメンションになる
- 公開投稿ならリンクを辿れば報告者情報に到達できるので、アカウント名を本文に含める必要はない

### マイルストーン運用

- **大更新は独立マイルストーンに単独配置**。UI の構造変更・既存モデルの拡張・複数画面への影響などが絡む「大更新」は、他に同規模以上の項目がないマイルストーンに入れる。並走させると設計検討・実装・動作確認がいずれも中途半端になるため
- **規模の測り方は「大更新の数」が主軸**。1 マイルストーンに入れるのは大更新 0〜1 件 + 小粒・中粒 5〜12 件程度を目安とする。件数は目安であって閾値ではない。リリース前レビュー（5 観点）の followup が膨らんだ場合、上限に縛られて後送りするより同一マイルストーンに取り込んで消化する方が望ましい（直前リリースの設計理解が新鮮なうちに直したいため）。**P1（緊急性あり）に加え、極めて容易な P2/P3 も同一マイルストーンで消化する**（数行の bug fix・コメント書き直し・リネーム・型変更等）。それでも入りきらない場合は、(a) リファクタ系を次マイルストーンに送る、(b) 観測性強化系を分離する、のどちらかで調整する
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

capsicum の運営元は有限会社ビーショック（<https://www.b-shock.co.jp>）。将来の課金（投げ銭サブスク・通知リレーの有償提供）を見据え、商品扱いとする方針。

- サイト運営・問い合わせ窓口・特商法表示は法人名義（capsicum-site / Google Workspace アドレス経由）
- 著作権表記は個人名義のままで問題なし
- **ストア発行元（Apple / Google / Microsoft Store の Seller / Publisher Display Name）は当面個人（小石達也）で 3 ストア整合**。Apple は登録時の Team Prefix 固定の経緯で個人、Google も個人で運用、Microsoft Store も同方針で 2026-05-09 に個人開発者登録 + アプリ予約完了（identity_name=`9AFBB08E.capsicum`、publisher_display_name=`小石達也`）
- 法人化（個人 → 有限会社ビーショックへの 3 ストア一括移行 + Apple は App Transfer 経由）は税務・ブランド要請が顕在化した時点で実施。**サポーターサブスク（[#428](https://github.com/pooza/capsicum/issues/428), v1.27）開始は移行の必須トリガーではない**（個人事業主収入として処理する選択肢があるため）。pooza さんは本名公開を許容しているので特商法対応のプライバシー側面も移行の必須トリガーにならない
- 「個人開発のアプリ」「個人発行元のストア配布」と「法人運営のサービス」は法的に矛盾しない（開発 / 配布 / 運営は独立した役割）。ブランド一貫性のみ運用課題として残るが、無料アプリの間は実害なし

### 課金の方向性

当初は「外部ユーザー向けプッシュ通知リレーのコスト補填」を想定していたが、プリセットサーバーの既存ユーザーから「機能差別化なしでよいので投げ銭させてほしい」という要望が先に顕在化したため、サポーターサブスク（[#428](https://github.com/pooza/capsicum/issues/428)）を主軸に設計検討する方針に変更（2026-04-30）。

- 機能差別化なし、装飾レベルの視覚的フィードバック（サポーターバッジ等）にとどめる
- 外部ユーザー向けプッシュ通知リレーの有償提供と同一 SKU で吸収できないか検討
- ストア審査対策（"What does this app do?" で trivial 扱いを避ける）として複数階層・継続性のあるサブスクで構成

v1.27 マイルストーンに単独配置（大更新のため他項目と並走させない）。商品設計 + 課金経路 + 装飾範囲の検討も同マイルストーン内で扱う。並走する自動化系タスクとして [#544](https://github.com/pooza/capsicum/issues/544)（Microsoft Store Web UI 手動 publish ルート再開）を同マイルストーンに配置。Flathub manifest 自動更新（[#470](https://github.com/pooza/capsicum/issues/470)）は Flathub 採択待ちのためマイルストーン未定。

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

最新リリース: **v1.28.0**（2026-05-26 タグ、Android 製品版昇格済み・iOS App Store 審査提出済み・macOS TestFlight アップロード済み（Mac App Store 審査提出は pooza 手動運用、Claude スキップ）・Linux AppImage / Windows MSIX 自己署名直配 GitHub Release draft で添付済み・Microsoft Store 提出は pooza が Web UI から手動 publish）は Misskey chat ルーム機能（グループチャット、[#438](https://github.com/pooza/capsicum/issues/438)）を主目的とする大更新単独配置マイルストーン。同居で Misskey Pages 読み取り対応（静的ブロック限定 v1 ビューア、[#186](https://github.com/pooza/capsicum/issues/186)）と Misskey ドライブの複数選択一括移動（[#567](https://github.com/pooza/capsicum/issues/567)）も取り込んだ。あわせて #594「キーボードをしまう」ボタン、#609 Mastodon 投稿フォームの未登録 shortcode 警告、#606 features.media_catalog ゲート、#602 streaming 観測の throttle 分離 + reconnect 上限 UI、#601 timeline ページ取得ループ上限、#600 Mastodon streaming 経由投稿の adminRoleIds 伝播修正、#620 Linux OAuth 既存クライアント救済を消化。リリース前 5 観点レビューを 1 回目 (commits d4a8526〜e8f00d7 の 7 件追従) + 大更新につき 2 回目差分レビューも実施し、黄 3 件 (#601 cap breadcrumb / #186 retry guard / #567 mounted ガード) は閾値以下のため 95df769 でインライン消化、赤 0 件。iOS / macOS は build 81 起点 (v1.27.1 で 80 を消費済み)、Linux / Windows / Android も pubspec 1.28.0+81 で揃えた。

**v1.27.1**（2026-05-23 タグ、Android 製品版昇格済み・iOS App Store 審査提出済み・macOS は TestFlight アップロードのみで Mac App Store 審査未提出（pooza が手動運用）・Windows Microsoft Store 公開済み（2026-05-23 審査通過）・Linux AppImage / Windows MSIX 自己署名直配 GitHub Release publish 済み）は v1.27.0 で混入した [#607](https://github.com/pooza/capsicum/issues/607) (Post.isHtml が enrich / 更新経路で伝播されず、Mastodon 投稿が MFM レンダラに流れて生 HTML タグが露出する不具合、特に連合 Misskey 猫耳ユーザー投稿で TL 表示崩れ) のホットフィックス。`timeline_provider.dart` の `_applyIsCat` / `updatePost` reblog 置換、`post_tile.dart` の `_onMediaDescriptionUpdated` の 3 経路で生 `Post(...)` 再構築を `Post.copyWith` 経由に置換し、`Post.copyWith` に `attachments` 引数を追加して `IsCatEnricher._enrichPost` と同じ安全実装に揃える。Codex line comment による v1.27.0 リリース時の指摘 (PR [#578](https://github.com/pooza/capsicum/pull/578)) が空振り判定で取りこぼされていた経緯あり (再発防止運用は Claude のメモリ `feedback_codex_skip_record_is_operational` に記録)。iOS / macOS は build number 80 で再ビルド (Apple App Store Connect に +79 重複あり)、Linux / Windows / Android は pubspec +79 のまま、Microsoft Store も v1.27.1 で再提出。

**v1.27.0**（2026-05-22 タグ、Linux AppImage / Windows MSIX 直配 (GitHub Release publish 済み)・Android 製品版昇格済み・iOS App Store 公開済み（2026-05-23 審査通過）・macOS Mac App Store 審査提出済み・Windows Microsoft Store 審査提出済み）はサポーターサブスク（投げ銭、[#428](https://github.com/pooza/capsicum/issues/428)）を主目的とする大更新単独配置マイルストーン。iOS / Android に StoreKit / Play Billing の消耗型 IAP 3 SKU（`supporter.tip.small` / `.medium` / `.big`、¥100 / ¥500 / ¥800）を実装。機能差別化なし・装飾のサポーターバッジのみで、`SupporterStatus` 抽象層がローカル保持と将来のサーバー保持（B-4、#596・v1.30）を分離する。あわせて #544 Microsoft Store 公開、#573 スワイプカラム移動の前倒し、#581-#595 の v1.26 出荷機能（Annict 連携・コマンド）まわりのユーザー要望 followup を取り込んだ。リリース前 5 観点レビュー + 大更新につき 2 回目差分レビューを実施し、購入完了処理の赤 1 件（`_onPurchaseUpdates` の例外で `purchaseInProgress` が固着、#298 同型）を 8d85aee で同梱解消、Sentry scrub 漏れの黄 2 件（IAPError / FormatException）を 0b49352 で消化。繰り越しは #600 / #601 / #602。投げ銭の購入導線は iOS / Android のみで、macOS は #598・Windows は #599・Linux は不可。

**v1.26.0**（2026-05-15 タグ、Android 製品版昇格済み・iOS App Store 公開済み・macOS Mac App Store 公開済み（iOS / macOS とも 2026-05-16 審査通過）・Linux AppImage / Windows MSIX 配布 (GitHub Release publish 済み)）。v1.25 / v1.24 のリリース前後 followup 消化 + 古めの enhancement 繰り越し + Windows 配布パイプライン仕上げ (#547 アイコン / #559 ウィンドウ位置記録) + Misskey メッセージ続編 (#560 / #561) + chat_streaming 安定化 (#548 / #552) を取り込んだ。大更新なし。主目的機能は #298 番組表・エピソードブラウザからの Annict 感想投稿で、依存するモロヘイヤ側 Annict 連携 hotfix のリリース後に製品版まで進行。リリース前 5 観点レビューの赤 3 件 + 同梱黄 2 件は 756291f で消化、Codex P1 (#298 連携リトライ中の `_submitting` 固着) は 51c3c97 で同梱解消。純粋リファクタ系 9 件は v1.30 へ overflow 送り。#534 Windows OV cert は v1.27 で #544 Store 公開達成 (2026-05-20) により必須性は消えたが、契約は期限なしで進行中のため on-hold 継続（close ではない）。

v1.25.0（2026-05-12 タグ、Android 製品版昇格済み・iOS App Store 公開済み・macOS Mac App Store 公開済み・Linux AppImage 配布開始・**Windows MSIX 自己署名直配 初回投入**）はデスクトップ展開の第 3 段階として **Windows 初回配布** を実施し、あわせて v1.22 で実装した Misskey メッセージ機能の改善 (大型 followup、#432 / #437-#449 / #455-#456 / #464) と、v1.24.x で重ねた Linux / macOS の followup (#503 / #504 / #527 / #528 / #531 / #538 / #495) を取り込んだ。Windows 配布パイプライン (#423) は MSIX 自己署名 PFX + GitHub Releases 直配で構成 (Microsoft Store は #544 で on-hold)、Parallels VM での実機検証 (#483) で OAuth localhost callback / file picker / メディア添付投稿が成立。リリース前 5 観点レビューの赤判定 2 件 (chat 画面 raw exception 露出 = #460 と同型 chat 版 / `client_secret` の scrub 抜け) は本リリースで同梱解消、黄判定のうち易しい 4 件をインライン消化 + 残り 10 件 (#548-#558, #547) を v1.26 へ送り。

v1.24.4（2026-05-11 タグ、Linux 限定 hotfix 4）は v1.24.0 の Linux AppImage で日本語 IME (ibus-mozc 等) が一切効かない不具合 (#532) について、v1.24.1 / v1.24.2 の二段階の誤診を経て v1.24.3 で真因を解明、v1.24.4 で fcitx5 / uim 経路への immodule 同梱と CI assertion (回帰防止) を追加:

- **v1.24.1** (誤診1): 「bundled libibus と host ibus-daemon の DBus protocol drift」と推定 → そもそも bundled libibus は AppImage に同梱されておらず `rm libibus-1.0.so.*` は no-op だった
- **v1.24.2** ([#535](https://github.com/pooza/capsicum/pull/535)、誤診2): 「CI runner (ubuntu-22.04) に `ibus-gtk3` 未インストールで `im-ibus.so` が同梱されていない」と特定 → workflow に `ibus-gtk3` 追加。im-ibus.so の同梱は必要だが本丸ではなかった。draft Release のまま実機検証で `Loading IM context type 'ibus' failed` を確認 → タグごと削除して仕切り直し
- **v1.24.3** ([#537](https://github.com/pooza/capsicum/pull/537)、真因): bundled libglib (build host ubuntu-22.04 / GLib 2.72) と host libibus (新しい host GLib 2.76+ で追加された `g_task_set_static_name` を要求) の **GLib symbol mismatch**。AppImage 内に build host の `libibus-1.0.so.5` を明示同梱して bundled GLib と整合させる構成に変更 (Flatpak の `runtime 提供 libibus + host ibus-daemon` と同じ方針)。Debian 13 / LXQt / X11 / ibus-mozc の実機で日本語変換が動作することを確認
- **v1.24.4** ([#539](https://github.com/pooza/capsicum/pull/539)、#536): `fcitx5-frontend-gtk3` / `uim-gtk3-immodule` を CI workflow に追加し `im-fcitx5.so` / `im-uim.so` を AppImage に同梱。`build.sh` seal 直前で immodule bundle + `immodules.cache` 登録を mechanical に検証する assertion を追加し、v1.24.1→v1.24.2 で発生した「CI image 構成変化で im-ibus.so が静かに消える」事故を再発時に検出可能にした。fcitx5 / uim は pooza 検証環境外のため best-effort スタンス (動作未確認)。#533 Codex P2 で `metainfo.xml` の `<releases>` を 1.24.4 まで補完

Android / iOS / macOS は v1.24.0+65 のまま再提出しない。`metainfo.xml` の screenshots 追加 / リリース日訂正、`SUBMISSION.md` の Flathub 提出 base ブランチ表記訂正は v1.24.1 で同梱済み。

v1.24.0（2026-05-10 タグ、Android 製品版昇格済み・iOS App Store 公開済み・macOS Mac App Store 公開済み・Linux AppImage 配布開始）は デスクトップ展開の第3段階として **Linux 初回リリース** を実施 — GTK runner ベースの Flutter ネイティブビルドを AppImage 形式で GitHub Releases から即時配布開始（Flathub Phase 5b は同日 [flathub/flathub#8626](https://github.com/flathub/flathub/pull/8626) として申請 PR 提出済み、採択まで 1〜4 週間）。`desktop_webview_window` の native crash (#489 / #496) 回避のため OAuth はシステムブラウザ + localhost callback (port 7099) 構成 (#506 / #507)。`flutter_secure_storage` register race の retry (#488 / #497)、`flutter_local_notifications_linux` の generated_plugin_registrant 抜け (#493)、AppRun の crashpad_handler 起動時検証 (#510)、build.sh patchelf RUNPATH 拡張 (#514) など Linux 初期不具合を一括解消。macOS は実機検証 (#494) 完了、メニューバー About を Drawer の「capsicum について」と統一、Share Extension (#422) 同梱、v1.23.1 hotfix の Keychain Access Group 明示 (#454) を取り込み。リリース前レビュー差分 2 回目 (#513 / #518) 対応も同梱。

v1.23.1（2026-05-09 タグ、macOS App Store 審査提出済み）は v1.23.0+55 が macOS 審査でリジェクト (Guideline 2.1(a)、ログイン後スピナー固着) されたため、Keychain Access Group の `MacOsOptions(groupId:)` 未指定で OAuth トークン書き込みが silent fail する不具合 (#454) と push 登録 UI の本配線まで非表示 (#467) を `release/1.23.1` ブランチ (main から分岐) に cherry-pick して macOS のみ +61 で再提出。iOS / Android は v1.23.0+55 のまま継続。

v1.23.0（2026-05-04 リリース、Android 製品版昇格済み・iOS App Store 審査提出済み）はデスクトップ展開の第2段階として、プラットフォーム抽象化レイヤ **BackgroundTaskScheduler** (#328、workmanager 脱却) / **MediaPicker** (#329、image_picker + file_selector 統合) / **NotificationSubsystem** (#330、flutter_local_notifications プラットフォーム差吸収) を導入。あわせて macOS の通知許可整合 (#404)、entitlements の keychain-access-group 統一 (#397)、ドライブの retry lock 解除バグ (#450) と responsive スクロール (#452) の修正、PushRegistrationStatusSection のリファクタ (#444) を消化。v1.22.0 は 2026-05-02、v1.21.0 は 2026-04-28、v1.0.0 は 2026-03-14 にストア公開。リリース履歴の詳細は [GitHub Releases](https://github.com/pooza/capsicum/releases) を参照。

### デスクトップ対応

macOS / Linux / Windows のデスクトップ環境への展開。動機は、iOS 版を Mac 上で実況用途に使って手応えがあること。v1.21 以降のマイルストーンに組み込み済み（当初は v1.19 → v1.20 → v1.21 と後ろ倒しを重ね、プッシュ通知完成 v1.20 を挟んだ上で着手する並びに落ち着いた）。

1. **第1段階: macOS ネイティブ化（v1.21、土台完成）** — `flutter config --enable-macos-desktop` を有効化し、Apple Developer Team / Apple Development 署名 / App Sandbox / Hardened Runtime / keychain-access-groups の設定を導入。Universal Purchase で iOS と同一 App レコードに紐付け済み。プラグインのデスクトップ対応状況の棚卸し・video_player → media_kit の事前調査もこの段階で完了。ストア配布（.pkg ラップ + fastlane の macOS lane）は [#407](https://github.com/pooza/capsicum/issues/407) で v1.21.x にて対応する
2. **第2段階: バックグラウンド/通知モデルの再設計（v1.23、完了）** — デスクトップにはバックグラウンド更新の概念がないため、通知ポーリング相当の仕組みを抽象化して差し替え可能にした。v1.18 のプッシュ通知リレー完了・v1.19 (#348) での workmanager / iOS BGTask 撤去後、モバイル側は APNs / FCM 一本化済み。v1.23 で `BackgroundTaskScheduler`（#328、Dart `Timer` + 常駐前提のフォールバック実装）/ `MediaPicker`（#329、image_picker + file_selector 統合）/ `NotificationSubsystem`（#330、flutter_local_notifications プラットフォーム差吸収）の各層を導入
3. **第3段階: Linux 対応（v1.24、Linux 配布パイプライン整備済み。Windows は v1.25 で MSIX 自己署名直配を再開、v1.27 で Microsoft Store 公開達成）** — 第2段階で通知周りが整理され、プラグイン依存の棚卸しが済んでから本格着手。Linux の配布形態は Flathub + AppImage（[#424](https://github.com/pooza/capsicum/issues/424)）。flutter create で scaffold 生成 → AppImage / Flatpak ローカルビルド → GitHub Actions Ubuntu runner CI 整備 → Flathub 提出文書化まで完了し、v1.24 リリースで AppImage は GitHub Releases から即座に配布、Flathub は審査制で 1〜4 週間遅れて利用可能化する想定（手順は [store-release-guide.md §4.5](store-release-guide.md) と [packaging/linux/flathub/SUBMISSION.md](../packaging/linux/flathub/SUBMISSION.md)）。Linux 実機検証は [#425](https://github.com/pooza/capsicum/issues/425)、macOS 実機検証は [#494](https://github.com/pooza/capsicum/issues/494) で並走。Windows は **2026-05-12 に v1.25 で再開と確定** — v1.25 時点では Microsoft Store 公開は msstore CLI 自動 publish 経路の詰まり (個人開発者アカウントから Entra ID テナント関連付け UI に到達不可) で保留、AppImage と同様に **GitHub Releases 経由の自己署名 MSIX 直配** で短期に Windows 配布を再開する方針 ([#423](https://github.com/pooza/capsicum/issues/423) / [#483](https://github.com/pooza/capsicum/issues/483))。`feature/423-windows-distribution` ブランチに Phase 1〜4 (Windows scaffold / `msix_config` / `windows-release.yml`) + Phase 5 msstore CLI publish step (secrets 未投入時 skip) を実装済み、develop に再合流して self-signed cert 生成 + MSIX 署名 + GitHub Releases 添付を CI に追加する。配布対象は「証明書 import を厭わない上級ユーザー」と明示。[#474](https://github.com/pooza/capsicum/issues/474) push 本配線・[#484](https://github.com/pooza/capsicum/issues/484) SMTC NowPlaying は ship 必須でないため引き続き on-hold。Microsoft Store 公開は **2026-05-15 に再評価**: msstore CLI 経路の詰まりは「Web UI 手動 publish ルートは Entra ID 関連付け不要」という別経路で迂回可能と判断、[#544](https://github.com/pooza/capsicum/issues/544) を Web UI 手動 publish ルートで v1.27 再開、**2026-05-20 に初回審査通過で Store 公開達成** ([apps.microsoft.com/detail/9np2gr7m2w6p](https://apps.microsoft.com/detail/9np2gr7m2w6p))。msstore CLI 自動 publish は引き続き保留（毎リリース Partner Center Web UI から手動 publish、手順は [store-release-guide.md §4.6](store-release-guide.md) 参照）、自己署名直配 ([#423](https://github.com/pooza/capsicum/issues/423)) は Store 認定中の先行配布・上級者向け補助路線として継続。中期施策の **コード署名証明書取得** ([#534](https://github.com/pooza/capsicum/issues/534)) は Store 経由配布が主ルートになったため当面不要（Store 側で再署名されるため `msix_config.store: false` の self-signed MSIX のまま submit 可）。video_player → media_kit の本移行は v1.21 の TestFlight Internal 検証で video_player が macOS 上で再生・添付・投稿とも問題なく動作することが確認できた（pooza が動画つき投稿で意図的に検証）ため緊急性が下がっており、第3段階の必須スコープからは外す。ただし **Linux は video_player に Linux 実装がなく動画再生不可**（2026-05-10 Debian 13 + AppImage v1.24.0 で「動画を読み込めません」を確認。クラッシュはせず graceful fallback。Windows も video_player_win 棚上げで不可）。macOS は video_player で動作（v1.21 検証済み）。Linux / Windows の動画再生有効化は media_kit 移行 [#492](https://github.com/pooza/capsicum/issues/492) で対応し、v1.30 にアサイン。v1.23 リリース前レビューで挙がった desktop 補修系（macOS Keychain Access Group 明示・FileSelectorMediaPicker の videoGroup 拡張・TimerBackgroundTaskScheduler 堅牢化等）も v1.24 に同居

第1段階と第2段階のあいだに **v1.22: Misskey メッセージ機能対応** を単独配置した（大更新を他の大更新と並走させない方針）。v1.22 として 2026-05-01 にリリース完了。リリース前レビューの黄判定や追加報告から派生したバグ修正・enhancement (#442 系列、#449、#440 など) は v1.22.x ホットフィックスではなく **v1.25**（Misskey メッセージ改善マイルストーン）にまとめて消化する方針 — Misskey メッセージは現状実験的機能の位置付けで、ホットフィックス級の利用状況・致命度には達していないため。グループチャット (#438) は単独機能として **v1.28** に分離。v1.28 は Misskey テーマに一本化し、#438（大更新）+ **Pages 機能の読み取り対応** ([#186](https://github.com/pooza/capsicum/issues/186)、静的ブロック限定 v1、AiScript なし) + ドライブ複数選択一括移動 ([#567](https://github.com/pooza/capsicum/issues/567)) の 3 件構成（2026-05-16 にマイルストーン現実化で確定）。v1.29 は **お知らせ通知 C 案** ([#477](https://github.com/pooza/capsicum/issues/477)、モロヘイヤ + 自前 SNS フォーク + capsicum-relay 経由でプリセットサーバー向け push 配信) を単独配置で復活（2026-05-13 再開、大更新）。v1.30 は大更新なしの集約枠で、desktop 補修・通知・動画再生改善（macOS push 本配線・3 OS 共通通知経路・video_player→media_kit）+ ユーザー要望の UX/メディア改善 + 汎用リファクタ overflow を取り込む（不具合かつユーザー要望のスワイプカラム移動 #573 は v1.27 へ前倒し）。**v1.32**（2026-05-16 新設）は desktop / packaging 系リファクタ overflow を集約（大更新なし）。**v1.34**（2026-05-20 新設）も大更新なしの集約枠で、繰り越し enhancement（#576 等）を起点に構成を追って詰める。これら集約枠は個別 Issue 構成を [GitHub Milestones](https://github.com/pooza/capsicum/milestones) を正本とし、ここには列挙しない。**v1.35**（2026-05-24 新設）は **投稿フォームに劇中ワード / ハッシュタグ / カスタム絵文字のサジェスト機能** ([#614](https://github.com/pooza/capsicum/issues/614)) を単独配置する大更新マイルストーン。投稿フォーム新規 UI レイヤ + モロヘイヤ tagging API（`POST /mulukhiya/api/tagging/tag/search`）/ カスタム絵文字 API 統合が主題のため他の大更新と並走させない。実況時に OS IME に登録がない専門ワード（例: `閃華裂光拳`）を一発で挿入したいユーザー要望が起点。**v1.33**（2026-05-16 新設）は **NowPlaying 横断対応**（#466 NowPlayingProvider 抽象 + Linux MPRIS / #484 Windows SMTC / #570 Spotify ナウプレ + mulukhiya OAuth）— #570 が大更新級のため実質単独配置扱い。既存ナウプレが OS 依存で Linux/Windows 不可な点の横断的代替が目的（#466 は当初 v1.28 合流予定だったが、#438 大更新との二大テーマ並走回避のため分離）。v1.31 は **タイムライン上の各投稿へのタッチ操作対応** ([#565](https://github.com/pooza/capsicum/issues/565)) を単独配置で新設（2026-05-14、大更新）— 誤タッチ防止のため意図的に塞いでいた WebUI 風のタッチ操作を、端末ごと・操作別にオプトインで有効化する。久々に「触り心地そのもの」に効く更新のため大更新として丁寧に扱う。

Issue [#475](https://github.com/pooza/capsicum/issues/475) (Linux push 方針) の議論で、**desktop 3 OS 共通の「WebSocket streaming → OS ローカル通知」設計** を確定した（2026-05-15、[desktop-notification-design.md](desktop-notification-design.md)）。Mastodon の `user` stream / Misskey の `main` channel に長寿命 WebSocket で接続し、notification / announcement event を `flutter_local_notifications` (libnotify / NSUserNotification / WinRT Toast) に流す経路。アプリ起動中の中間解として 3 OS 共通で機能し、将来の native push (#468 macOS APNs / #474 Windows WNS) とは `notification.id` dedup で併存する。実装 issue は [#569](https://github.com/pooza/capsicum/issues/569) として切り出し済み（v1.30、規模中）。本設計の確定により、ポーリング前提だった「お知らせ通知 A 案」(#476) は不要となり close、capsicum-relay 経由の C 案 (#477、v1.29) は mobile 配信を継続して担う構図に整理された。

動機の具体例:

- iOS アプリを Mac で動かす (Designed for iPad) モードだとファイル選択が iOS のドキュメントピッカーになり、Mac のネイティブな Finder ベースの選択ができない。画像・動画添付が実況用途で地味に手間。macOS ネイティブビルドなら `file_selector` / `image_picker` の macOS 実装が NSOpenPanel を出してくれる
- キーボードショートカット・ウィンドウ管理・通知センター連携など、デスクトップ固有の体験も macOS ネイティブなら自然に組める

設計指針（分岐を最小化するためのルール）:

- **UI の分岐軸はプラットフォームではなく画面幅**にする。`Platform.isXxx` は UI 層に基本入れない。iPad で画面が広ければデスクトップと同じレイアウトになるべきだし、デスクトップでウィンドウを狭めたらモバイル風になるべき。Responsive design の単一軸に集約する
- **プラットフォーム固有機能は必ず抽象層を経由**させる。`flutter_local_notifications` を直接呼ばず、`BackgroundTaskScheduler` のようなインターフェースを挟む。第2段階（通知モデル再設計）の主題と噛み合う
- **プラットフォーム定数はテーブル化**。ショートカット・メニュー構成などは1箇所にまとめ、プラットフォームごとにテーブルを差し替える
- **条件付きコンパイル（conditional import）は最後の手段**。使う場合も `lib/src/platform/` のような特定ディレクトリに閉じ込める

配布・ストア・ツールチェーンの方針（macOS は Apple Developer Program を iOS と共用、Linux は Flathub + AppImage、Snap は不採用、Windows は v1.25 で GitHub Releases 経由の自己署名 MSIX 直配を再開し v1.27 で Microsoft Store 公開を達成 ([#544](https://github.com/pooza/capsicum/issues/544)、2026-05-20 審査通過)。以降は Store 経由を主・自己署名直配を補助の 2 系統で運用）、および段階的な実装順序は [release-pipeline.md](release-pipeline.md) を参照。プラグインのデスクトップ対応状況の棚卸しは [desktop-plugin-compatibility.md](desktop-plugin-compatibility.md) にまとめている。第2段階では `BackgroundTaskScheduler`（[#328](https://github.com/pooza/capsicum/issues/328)）/ `MediaPicker`（[#329](https://github.com/pooza/capsicum/issues/329)）/ 通知サブシステム（[#330](https://github.com/pooza/capsicum/issues/330)）の抽象化が主題となる。

macOS の付加機能としては、Music.app 等の「共有」メニューから capsicum に投稿を流す Share Extension の追加（[#422](https://github.com/pooza/capsicum/issues/422)）がある。iOS の Share Extension と同パターンで App Group コンテナ経由 + ナウプレ整形はモロヘイヤ側ハンドラに委譲。desktop 系として **v1.24**（Linux 配布、Windows は保留）に同居でアサイン。

### Linux 固有の差分（v1.24）

v1.24 リリース直前の Linux 実機検証で判明・対応した、他プラットフォームと挙動が違う部分。

- **OAuth 経路はシステムブラウザ + localhost callback**（[`AppConstants.localhostOAuthPort = 7099`](../packages/capsicum/lib/src/constants.dart)）。Linux は `desktop_webview_window` の GLX 系 native crash (#489 / #496) を、Windows は MSIX に `flutter_web_auth_2` の native plugin が同梱されない制約 (#423) を、いずれも `flutter_web_auth_2` の server impl (`useWebview: false`) で回避する。Mastodon は createApplication 時に redirect_uri を完全一致登録するためポート固定。Bitwarden / 1Password 等のパスワードマネージャ統合 (#382 一次動機) も副次的に達成。macOS / iOS / Android は従来通り
- **AppImage の起動時観測性**（[`packaging/linux/appimage/build.sh`](../packaging/linux/appimage/build.sh)）。Flutter (sentry_flutter 同梱) の `crashpad_handler` が release bundle 段階で execute bit 落ち → `chmod +x` 補正。AppImage の `AppRun` を logging wrapper に差し替え `~/.local/share/capsicum/logs/` に stderr/stdout を保存し、デスクトップ起動時の native crash でも GTK / X 警告を残す
- **sentry-native database path 固定**（[`main.dart`](../packages/capsicum/lib/main.dart) の `SentryFlutter.init`）。デフォルトは CWD 直下に `.sentry-native/` を作るため起動経路で場所が変わる。Linux / Windows は `path_provider.getApplicationSupportDirectory()` 経由で OS 規約準拠の app data ディレクトリ (`~/.local/share/capsicum/` / `%LOCALAPPDATA%\Packages\...`) に明示固定
- **flutter_secure_storage の register race 対策**（[`account_storage.dart`](../packages/capsicum/lib/src/service/account_storage.dart) の `_readWithRegisterRetry`）。Linux runner は `gtk_widget_realize` の後に `fl_register_plugins` を呼ぶ Flutter 標準 template で、Splash 起動直後の `restoreSessions` から MissingPluginException が出る race がある。短間隔 retry (50ms × 3) で吸収

詳細は #488 / #489 / #491 / #496 と [desktop-plugin-compatibility.md](desktop-plugin-compatibility.md) の flutter_web_auth_2 行を参照。

制約: モロヘイヤ透過プロキシ前提のためネットワーク層は問題にならない。

運用ルール:

- リリース前レビューは各マイルストーンの Issue をすべて消化した後、リリース直前に毎度実施する。[#27](https://github.com/pooza/capsicum/issues/27) の「セキュリティレビュー」だけでは実害バグを取りこぼすため、以下 5 観点をサブエージェントで並列に走らせる（詳細は [store-release-guide.md](store-release-guide.md) の「リリース前レビュー」節）:
  - セキュリティ（`/security-review` スキル）
  - API 契約（Mastodon / Misskey / モロヘイヤの REST 正確性、アダプター interface 整合）
  - 並行性・ライフサイクル（async 連鎖、Riverpod provider 寿命、dispose、race）
  - エラー処理・観測性（try/catch カバレッジ、Sentry 計装、secrets scrub、UX）
  - コーディングスタイル・規約整合性（用語統一、ハードコーディング、命名の揺れ、重複ロジック、規約違反）
- **レビュー指摘の起票閾値**: コメント書き直し・既に触っている関数内のリネーム・型変更（`Map<String,bool>` → `Set<String>` 等）・隣接ファイルでの軽微な追従等、起票 + ラベル + マイルストーン + 移動 + close の往復コストが修正コストと拮抗する粒度のものは、issue を起こさず P1 修正の commit に直接含めて消化する。本文に「今は緊急性なし」「必要性が顕在化してから対応」と書きたくなる粒度のものは、起票せずレビュー報告内の note として残す（未来に必要になった時点で起票する）
- **2 回目レビュー（差分レビュー）**: プラットフォーム追加・大更新独立配置マイルストーンに限り、1 回目の修正 commit に起因する新規問題を拾うため 2 回目を回す。対象は 1 回目以降の差分と新規サーフェスのみ。リリース 1 週間前までに完了させ、直前に出た P1 はホットフィックス前提で次リリースに送ってよい（詳細は [store-release-guide.md](store-release-guide.md) §4.0）
- ATOK 二重入力（[#54](https://github.com/pooza/capsicum/issues/54)）は Flutter 側の対応待ち。リリースごとにリリースノートの「既知の不具合」に記載し、Flutter 側の関連 issue の動向を確認する
- マイルストーン未設定の Issue は `no:milestone` フィルタで確認する
- Flutter framework 由来の不具合（capsicum 側で根治不能なもの、`flutter` ラベル付き）は [flutter-upstream-watch.md](flutter-upstream-watch.md) で集中管理し、月 1 回の chase routine（毎月 1 日 09:00 JST）で上流の進捗を巡回する

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
