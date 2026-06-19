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
（参照用にローカルクローンを併設している。配置先は開発者の手元で管理）

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

v1.15 の観測性強化（#293）により、iOS のバックグラウンド通知は発火回数 0回で事実上機能していないことが確認された。v1.18 でプッシュ通知リレー（[#52](https://github.com/pooza/capsicum/issues/52)）を実装し、根本解決済み。リレーサーバー（Ruby、Linode、`relay.capsicum.shrieker.net`）の実装は [pooza/capsicum-relay](https://github.com/pooza/capsicum-relay) リポジトリが正本。初期設計判断の経緯は [archive/push-relay-plan.md](archive/push-relay-plan.md) に保存。具体的な課金設計（料金体系・ストア課金統合等）はサポーターサブスク（[#428](https://github.com/pooza/capsicum/issues/428)）の設計検討の中で扱う。

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
    mastodon-46-capsicum-triage.md  # Mastodon 4.6 の API 変更を client 影響でトリアージ（フォーク diff 手順つき）
    misskey-capsicum-api-watch.md  # Misskey 新バージョンの API 変更を client 影響でトリアージ（マイナー毎・daisskey SHA アンカー）
    sync-procedure.md     # セッション開始時の同期手順
    store-release-guide.md  # ストアリリース手順書（運用正本）
    archive/              # 過去の記録（現役運用では参照しない。release-pipeline.md 等）
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

v1.27 マイルストーンに単独配置（大更新のため他項目と並走させない）。商品設計 + 課金経路 + 装飾範囲の検討も同マイルストーン内で扱う。並走する自動化系タスクとして [#544](https://github.com/pooza/capsicum/issues/544)（Microsoft Store Web UI 手動 publish ルート再開）を同マイルストーンに配置。Flathub 対応は 2026-05-29 に断念（提出 PR が AI Slop 判定、#604 / #470 とも close）。Linux 配布は AppImage 単独。

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

最新リリース: **v1.38.0**（2026-06-19 タグ、build 121、pubspec 1.38.0+121、リリース PR [#725](https://github.com/pooza/capsicum/pull/725)）。**ナウプレ仕上げ + アカウント信頼性 / TL 修正の実利版・看板機能なし**（当初主役 [#570](https://github.com/pooza/capsicum/issues/570) Spotify ナウプレは Spotify クォータ規約で塩漬け → コードは実装/検証/close 済みだが本番 `spotify_enabled` OFF で出さない）。公開状況: **macOS 以外は全プラットフォーム公開済み** — **Android 製品版公開済み**（versionCode=121、production completed を Play API で確認）/ **iOS App Store 公開済み**（build 121、2026-06-19 公開）/ **Windows Microsoft Store 公開済み**（pooza 手動）/ **Linux AppImage + Windows MSIX 自己署名直配**は CI（windows/linux-release.yml、タグ駆動）でビルド → [GitHub Release v1.38.0](https://github.com/pooza/capsicum/releases/tag/v1.38.0) で publish 済み（Latest、AppImage / MSIX / 署名 .cer 添付）。**macOS Mac App Store のみ審査中**（build 121、pooza 手動提出、temporary-exception 審査 Notes は store-release-guide §4.3）。残りは macOS の審査結果待ちのみ。消化: [#681](https://github.com/pooza/capsicum/issues/681) ナウプレ URL 優先プロバイダ（Apple Music / Spotify、端末共通。設定「表示」へ配置）/ [#729](https://github.com/pooza/capsicum/issues/729) 共有ナウプレも in-app と同じ formatter で整形（公開 `isSingleNowPlayingUrl` + resolve-by-URL）/ [#724](https://github.com/pooza/capsicum/issues/724) supporter backfill 失敗時の再試行抑止（`_uploadToServer` を bool 化し未同期登録を見送り）/ [#730](https://github.com/pooza/capsicum/issues/730) 起動時の一過性ネットワーク失敗を「一斉ログアウト」へ降格せず backoff[2,5,15,30]s で自動再試行 / [#731](https://github.com/pooza/capsicum/issues/731) Android Keystore 復号エラーで secret を即 delete しない（再起動で復帰可）/ [#717](https://github.com/pooza/capsicum/issues/717) 自分の投稿を TL 先頭へ楽観挿入（サーバー伝播待ちの「投稿しても出ない」解消）。あわせて設定整理（ナウプレ URL 優先をアカウント設定→「表示」へ移設・Spotify 連携はアカウント単位なので据え置き・プロフィールのプッシュ登録セクション撤去）。リリース前レビュー（5観点）は赤0、黄/緑を [56bd7f2](https://github.com/pooza/capsicum/commit/56bd7f2) でインライン消化（restore リトライ枯渇を network_exhausted で観測 / account_storage の Keystore code を dedup+tag 化 / `_restoreOne` append 直前の重複ガード / insertOwnPost の doc 明確化）。ステージング Spotify OFF 戻しは mulukhiya [#4417](https://github.com/pooza/mulukhiya-toot-proxy/issues/4417)。pubspec 1.38.0+121。

**v1.37.1**（2026-06-17 タグ、build 120、pubspec 1.37.1+120、PR [#728](https://github.com/pooza/capsicum/pull/728) / release/1.37.1。v1.37.0 リリース後のホットフィックス）。公開状況: **iOS / macOS 含む全プラットフォーム公開済み** — Android 製品版 / iOS App Store / macOS Mac App Store（pooza 確認、2026-06-18 同期）/ Windows Microsoft Store（pooza 手動）/ Linux AppImage + Windows MSIX 自己署名直配は [GitHub Release v1.37.1](https://github.com/pooza/capsicum/releases/tag/v1.37.1) で publish 済み。消化: [#727](https://github.com/pooza/capsicum/issues/727) ナウプレ投稿のメタデータ（Title/Album/Artist）二重化を修正（アプリ内ナウプレ整形 + モロヘイヤ enrich の二重付与が原因。[80e21c2](https://github.com/pooza/capsicum/commit/80e21c2) で URL を `#nowplaying` と別行化 → [99f9d9f](https://github.com/pooza/capsicum/commit/99f9d9f) で共有は従来どおり同一行 `#nowplaying` を維持＝モロヘイヤ enrich 前提）。後続は [#729](https://github.com/pooza/capsicum/issues/729)（共有ナウプレも in-app と同じ formatter で整形）。pubspec 1.37.1+120。

**v1.37.0**（2026-06-16 タグ、**Apple Music ナウプレ（iOS / macOS）**を主役とする大更新単独配置、build 118、PR [#706](https://github.com/pooza/capsicum/pull/706)。v1.37.1 ホットフィックスで上書き）。公開状況: **Android 製品版公開済み**（versionCode=118、production completed を Play API で確認）/ **iOS App Store 公開済み**（build 118、2026-06-17 公開）/ **macOS Mac App Store 公開済み**（build 118、2026-06-17 公開。pooza 手動 MAS 提出 → 審査通過。temporary-exception 審査 Notes は store-release-guide §4.3）/ **Windows Microsoft Store 公開済み**（pooza 手動 publish）/ **Linux AppImage + Windows MSIX 自己署名直配**は [GitHub Release v1.37.0](https://github.com/pooza/capsicum/releases/tag/v1.37.0) で publish 済み。主役は [#668](https://github.com/pooza/capsicum/issues/668) Apple Music ナウプレ pull（iOS=MPMusicPlayerController / macOS=ミュージック.app scripting）。macOS は App Sandbox 下で modern の `automation.apple-events` 単独だとミュージックが addressable と認識されず procNotFound(-600)。`com.apple.security.temporary-exception.apple-events`=["com.apple.Music"] を併用して解決（build 117 実機確認、内部ベータ 109-117 の Sentry で確定）。あわせて [#669](https://github.com/pooza/capsicum/issues/669) enrich（URL なし源に共有 URL 補完）/ [#670](https://github.com/pooza/capsicum/issues/670) タグ末尾規律 / [#703](https://github.com/pooza/capsicum/issues/703)「削除して再編集」で CW/添付/閲覧注意の引き継ぎ + リモートメンション復元 / [#704](https://github.com/pooza/capsicum/issues/704) account secret 喪失の観測性 / [#709](https://github.com/pooza/capsicum/issues/709) 挿入後キャレット / [#695](https://github.com/pooza/capsicum/issues/695) iOS/macOS 英語ローカリゼーション削除 / [#696](https://github.com/pooza/capsicum/issues/696)-[#699](https://github.com/pooza/capsicum/issues/699) v1.36 レビュー followup / [#721](https://github.com/pooza/capsicum/issues/721) Mastodon 4.6 互換確認（受動・破壊的変更なし）を消化。リリース前レビュー（5観点 + 大更新につき自己点検）は赤0（API契約観点の getMaxProfileFields 赤候補は誤判定＝06bebad は存在しない v1 フィールド `?? 4` で常に 4 を返す誤った上限の撤去＝改善と確認）。黄/緑は [63cf26b](https://github.com/pooza/capsicum/commit/63cf26b) でインライン消化（profile 422 の Sentry を構造化シグナル化＝生本文を載せない / getMaxProfileFields コメント事実訂正＝Mastodon は上限を API 露出しない / enrich URL を http/https 限定 / macOS `__scriptItems` 死にコード削除）。構造的黄は [#724](https://github.com/pooza/capsicum/issues/724)（supporter backfill 失敗時の再試行抑止）で v1.38。secrets は iOS App.framework / Android arm64 libapp.so / macOS App.framework で実バイナリ確認、macOS 再署名 `.pkg` は aps-environment=production・temporary-exception 維持・Apple Distribution 署名を確認。pubspec 1.37.0+118。

v1.23〜v1.36 の各リリースは [GitHub Releases](https://github.com/pooza/capsicum/releases) / 各 Issue / マイルストーンが正本。テーマと主要 Issue のみ残す（操作上の落とし穴・レビュー詳細はメモリ `project_v13x_progress` 等と各コミット・Issue に保存）:

- **v1.36.1**（2026-06-12）#700 push 復号失敗ログの scrub 漏れ / #701 連続ログイン時サポーター同期 race のホットフィックス
- **v1.36.0**（2026-06-12）Misskey chat / Pages 続編（[#612](https://github.com/pooza/capsicum/issues/612)・[#613](https://github.com/pooza/capsicum/issues/613) リアクション・添付、[#615](https://github.com/pooza/capsicum/issues/615)・[#617](https://github.com/pooza/capsicum/issues/617) Pages like）+ 投げ銭 macOS 横展開（[#598](https://github.com/pooza/capsicum/issues/598)）+ サポーター状態のサーバー側保持（[#596](https://github.com/pooza/capsicum/issues/596)）。大更新なし
- **v1.35.0**（2026-06-09）投稿フォームの劇中ワードサジェスト（[#614](https://github.com/pooza/capsicum/issues/614)、mulukhiya `GET /word/suggest`）。大更新単独。設計は [archive/compose-suggest-design.md](archive/compose-suggest-design.md)
- **v1.34.0**（2026-06-07）デスクトップ通知本配線（[#569](https://github.com/pooza/capsicum/issues/569) WebSocket → OS ローカル通知 / [#468](https://github.com/pooza/capsicum/issues/468) macOS APNs）。大更新単独。設計は [archive/desktop-notification-design.md](archive/desktop-notification-design.md)
- **v1.33.0**（2026-06-06）desktop ネイティブ NowPlaying（[#466](https://github.com/pooza/capsicum/issues/466) NowPlayingProvider 抽象 + Linux MPRIS / [#484](https://github.com/pooza/capsicum/issues/484) Windows SMTC）。大更新単独。設計は [archive/nowplaying-design.md](archive/nowplaying-design.md)
- **v1.32.0**（2026-06-04）desktop / packaging 系リファクタ集約（15 件）。大更新なし
- **v1.30.0**（2026-05-31）動画再生エンジンの media_kit 移行（[#492](https://github.com/pooza/capsicum/issues/492)、Linux / Windows でも動画・音声再生可能に）。大更新単独
- **v1.29.0**（2026-05-28）お知らせ通知 C 案（[#477](https://github.com/pooza/capsicum/issues/477)）を capsicum-relay 経由で本配線。大更新単独
- **v1.28.1**（2026-05-27）#630 誤投稿 / #631 Pages like cursor / #632 chat thread 並び替えのホットフィックス
- **v1.28.0**（2026-05-26）Misskey グループチャット（[#438](https://github.com/pooza/capsicum/issues/438)）+ Pages 読み取り（[#186](https://github.com/pooza/capsicum/issues/186)）+ ドライブ一括移動（#567）。大更新単独
- **v1.27.1**（2026-05-23）#607 Post.isHtml 伝播漏れ（生 HTML 露出）のホットフィックス
- **v1.27.0**（2026-05-22）サポーターサブスク（投げ銭、[#428](https://github.com/pooza/capsicum/issues/428)）+ Microsoft Store 公開（#544）。大更新単独
- **v1.26.0**（2026-05-15）#298 Annict 感想投稿 + Windows 配布パイプライン仕上げ。大更新なし
- **v1.25.0**（2026-05-12）Windows 初回配布（自己署名 MSIX 直配、[#423](https://github.com/pooza/capsicum/issues/423)）+ Misskey メッセージ改善
- **v1.24.x**（2026-05-10〜11）Linux 初回リリース（AppImage、[#424](https://github.com/pooza/capsicum/issues/424)）。v1.24.1〜v1.24.4 は AppImage の日本語 IME 不能（#532、bundled GLib と host libibus の symbol mismatch）の段階修正
- **v1.23.x**（2026-05-04〜09）デスクトップ第2段階の抽象化層（BackgroundTaskScheduler #328 / MediaPicker #329 / NotificationSubsystem #330）。v1.23.1 は macOS Keychain Access Group 未指定リジェクト（#454）のホットフィックス

v1.22.0（2026-05-02、Misskey メッセージ）・v1.21.0（2026-04-28、macOS ネイティブ土台）・v1.0.0（2026-03-14、初公開）。各リリースの詳細なリリースノート・消化 Issue・公開状況は [GitHub Releases](https://github.com/pooza/capsicum/releases) と各マイルストーンが正本。

### デスクトップ対応

macOS / Linux / Windows のデスクトップ環境への展開。動機は、iOS 版を Mac 上で実況用途に使って手応えがあること。v1.21 以降のマイルストーンに組み込み済み（当初は v1.19 → v1.20 → v1.21 と後ろ倒しを重ね、プッシュ通知完成 v1.20 を挟んだ上で着手する並びに落ち着いた）。

1. **第1段階: macOS ネイティブ化（v1.21、土台完成）** — `flutter config --enable-macos-desktop` を有効化し、Apple Developer Team / Apple Development 署名 / App Sandbox / Hardened Runtime / keychain-access-groups の設定を導入。Universal Purchase で iOS と同一 App レコードに紐付け済み。プラグインのデスクトップ対応状況の棚卸し・video_player → media_kit の事前調査もこの段階で完了。ストア配布（.pkg ラップ + fastlane の macOS lane）は [#407](https://github.com/pooza/capsicum/issues/407) で v1.21.x にて対応する
2. **第2段階: バックグラウンド/通知モデルの再設計（v1.23、完了）** — デスクトップにはバックグラウンド更新の概念がないため、通知ポーリング相当の仕組みを抽象化して差し替え可能にした。v1.18 のプッシュ通知リレー完了・v1.19 (#348) での workmanager / iOS BGTask 撤去後、モバイル側は APNs / FCM 一本化済み。v1.23 で `BackgroundTaskScheduler`（#328、Dart `Timer` + 常駐前提のフォールバック実装）/ `MediaPicker`（#329、image_picker + file_selector 統合）/ `NotificationSubsystem`（#330、flutter_local_notifications プラットフォーム差吸収）の各層を導入
3. **第3段階: Linux / Windows 対応（v1.24〜v1.27、完了）** — 第2段階で通知周りが整理され、プラグイン依存の棚卸しが済んでから着手。Linux は **AppImage 単独配布**（v1.24〜。Flathub は [#604](https://github.com/pooza/capsicum/issues/604) で 2026-05-29 断念、以降は AppImage 単独に確定）。Windows は v1.25 で **自己署名 MSIX 直配**（[#423](https://github.com/pooza/capsicum/issues/423)）、v1.27 で **Microsoft Store 公開達成**（[#544](https://github.com/pooza/capsicum/issues/544)、毎リリース Partner Center Web UI から手動 publish）。OAuth は 3 OS とも `flutter_web_auth_2` の localhost callback（port 7099、[`AppConstants.localhostOAuthPort`](../packages/capsicum/lib/src/constants.dart)）に統一。動画再生は media_kit 移行（[#492](https://github.com/pooza/capsicum/issues/492)、v1.30）で Linux / Windows も対応。コード署名証明書取得（[#534](https://github.com/pooza/capsicum/issues/534)）は Store 再署名のため当面不要（IV 証明書取得済みだが capsicum 適用はお蔵入りで close）。Windows push 本配線（[#474](https://github.com/pooza/capsicum/issues/474)）は Windows の優先度上昇に伴い on-hold 解除し、**v1.40 を「Windows 仕上げ」大更新マイルストーンとして独立配置**（#474 push 本配線 + [#599](https://github.com/pooza/capsicum/issues/599) Windows IAP を束ねる。x64 実機環境が整い両項目を一括検証できるため）。SMTC NowPlaying（[#484](https://github.com/pooza/capsicum/issues/484)）は v1.33 で実装・**実機検証済み**（C++/WinRT メソッドチャンネル。ARM64 Windows でローカル x64 ビルドは ATL 未導入 / jni / crashpad の x64-on-ARM64 で詰まるため、CI windows-release.yml の `capsicum-msix` artifact を gh run download → `Add-AppxPackage` で導入して検証する経路を確立）。実機検証は Linux [#425](https://github.com/pooza/capsicum/issues/425) / macOS [#494](https://github.com/pooza/capsicum/issues/494)。

各マイルストーンの主題・スコープ・個別 Issue 構成は [GitHub Milestones](https://github.com/pooza/capsicum/milestones) が正本（CLAUDE.md には複写しない）。**大更新は独立配置**の方針で進めており、第1段階と第2段階のあいだに **v1.22 Misskey メッセージ機能**を単独配置したのを起点に、v1.28 グループチャット + Pages 読み取り → v1.29 お知らせ通知 → v1.30 media_kit 移行 → v1.31 タイムライン上のタッチ操作 → v1.32 リファクタ集約 → v1.33 NowPlaying（desktop ネイティブ pull。[#466](https://github.com/pooza/capsicum/issues/466) NowPlayingProvider 抽象 + Linux MPRIS / [#484](https://github.com/pooza/capsicum/issues/484) Windows SMTC、設計 [nowplaying-design.md](archive/nowplaying-design.md)）→ **v1.34 desktop 通知本配線（[#569](https://github.com/pooza/capsicum/issues/569) WebSocket → OS ローカル通知 / [#468](https://github.com/pooza/capsicum/issues/468) macOS APNs、設計 [desktop-notification-design.md](archive/desktop-notification-design.md)）** → **v1.35 投稿フォームのサジェスト**（[#614](https://github.com/pooza/capsicum/issues/614)、劇中ワード）→ **v1.36 Misskey chat / Pages 続編 + 投げ銭の macOS 横展開・サーバー側保持**（#599 Windows IAP は環境待ちで未割り当てへ分離）、と進めてきた（各版の要点は上記リリースログ）。今後の主題は **v1.37 Apple Music ナウプレ**（[#668](https://github.com/pooza/capsicum/issues/668)、iOS = MPMusicPlayerController 公開 API / macOS = ミュージック.app scripting。NowPlaying pull を iOS / macOS へ横展開）→ **v1.38 Spotify ナウプレ**（[#570](https://github.com/pooza/capsicum/issues/570)。依存の mulukhiya #4337 OAuth は 2026-06-18 develop マージ + dev04/dev23 ステージング配備済み。capsicum 側実装は ba15046 で develop 着地＝SpotifyNowPlayingProvider を NowPlayingResolver に最優先合成・設定画面に連携セクション・403 失効は再連携導線。実 OAuth 完走は pooza の Spotify Dashboard 設定後にステージング検証）→ **v1.39 ユーザー要望 UX バッチ**（大更新なし。karasu_sue / ore_orue 他の #capsicum 要望を近接消化）→ **v1.40 Windows 仕上げ**（[#474](https://github.com/pooza/capsicum/issues/474) push 本配線 + [#599](https://github.com/pooza/capsicum/issues/599) IAP、大更新独立配置）→ **v1.41 投稿サジェスト拡張・内部UX枠**（大更新なし。v1.39 過積載解消で分離した内部派生 #685/#687/#645/#726）。NowPlaying の pull 横展開は **iOS / macOS では Apple Music を優先・Spotify を 2 番手**とする方針で、大更新独立配置の原則に従い Apple Music（v1.37）と Spotify（v1.38）を別マイルストーンに分離した（2026-06-05）。v1.39 は当初 #474/#599 を含み過積載だったため、2026-06-17 に Windows 仕上げ（#474+#599）を v1.40 へ分離。さらに 2026-06-19、ユーザー要望バッチで再び過積載（19件）になったため、内部由来（#685 サジェスト inline 補完 / #687 辞書 perf / #645 D&D 保存 / #726 グループインジケータ）を新設 **v1.41「投稿サジェスト拡張・内部UX枠」** へ分離し（要望由来は全据え置き・#588 は #714 に統合してクローズ）、既存のメニューバー #712→v1.42 / #713→v1.43 / 集約枠→v1.44 / サーバー判定 #723→v1.45 を 1 つずつ繰り下げた。集約枠の個別 Issue は Milestones を正本とする。

Issue [#475](https://github.com/pooza/capsicum/issues/475) (Linux push 方針) の議論で、**desktop 3 OS 共通の「WebSocket streaming → OS ローカル通知」設計** を確定した（2026-05-15、[desktop-notification-design.md](archive/desktop-notification-design.md)）。Mastodon の `user` stream / Misskey の `main` channel に長寿命 WebSocket で接続し、notification / announcement event を `flutter_local_notifications` (libnotify / NSUserNotification / WinRT Toast) に流す経路。アプリ起動中の中間解として 3 OS 共通で機能し、将来の native push (#468 macOS APNs / #474 Windows WNS) とは `notification.id` dedup で併存する。実装 issue は [#569](https://github.com/pooza/capsicum/issues/569) として切り出し済み（v1.34 主役、大更新）。本設計の確定により、ポーリング前提だった「お知らせ通知 A 案」(#476) は不要となり close、capsicum-relay 経由の C 案 (#477、v1.29) は mobile 配信を継続して担う構図に整理された。

動機の具体例:

- iOS アプリを Mac で動かす (Designed for iPad) モードだとファイル選択が iOS のドキュメントピッカーになり、Mac のネイティブな Finder ベースの選択ができない。画像・動画添付が実況用途で地味に手間。macOS ネイティブビルドなら `file_selector` / `image_picker` の macOS 実装が NSOpenPanel を出してくれる
- キーボードショートカット・ウィンドウ管理・通知センター連携など、デスクトップ固有の体験も macOS ネイティブなら自然に組める

設計指針（分岐を最小化するためのルール）:

- **UI の分岐軸はプラットフォームではなく画面幅**にする。`Platform.isXxx` は UI 層に基本入れない。iPad で画面が広ければデスクトップと同じレイアウトになるべきだし、デスクトップでウィンドウを狭めたらモバイル風になるべき。Responsive design の単一軸に集約する
- **プラットフォーム固有機能は必ず抽象層を経由**させる。`flutter_local_notifications` を直接呼ばず、`BackgroundTaskScheduler` のようなインターフェースを挟む。第2段階（通知モデル再設計）の主題と噛み合う
- **プラットフォーム定数はテーブル化**。ショートカット・メニュー構成などは1箇所にまとめ、プラットフォームごとにテーブルを差し替える
- **条件付きコンパイル（conditional import）は最後の手段**。使う場合も `lib/src/platform/` のような特定ディレクトリに閉じ込める

配布・ストア・ツールチェーンの方針（macOS は Apple Developer Program を iOS と共用、Linux は AppImage 単独（Flathub は 2026-05-29 断念 [#604](https://github.com/pooza/capsicum/issues/604)）、Snap は不採用、Windows は v1.25 で GitHub Releases 経由の自己署名 MSIX 直配を再開し v1.27 で Microsoft Store 公開を達成 ([#544](https://github.com/pooza/capsicum/issues/544)、2026-05-20 審査通過)。以降は Store 経由を主・自己署名直配を補助の 2 系統で運用）、および段階的な実装順序は [release-pipeline.md](archive/release-pipeline.md) を参照。プラグインのデスクトップ対応状況の棚卸しは [desktop-plugin-compatibility.md](desktop-plugin-compatibility.md) にまとめている。第2段階では `BackgroundTaskScheduler`（[#328](https://github.com/pooza/capsicum/issues/328)）/ `MediaPicker`（[#329](https://github.com/pooza/capsicum/issues/329)）/ 通知サブシステム（[#330](https://github.com/pooza/capsicum/issues/330)）の抽象化が主題となる。

macOS の付加機能として、Music.app 等の「共有」メニューから capsicum に投稿を流す Share Extension（[#422](https://github.com/pooza/capsicum/issues/422)）を **v1.24 で同梱済み**。iOS の Share Extension と同パターンで App Group コンテナ経由、共有元（Music.app 等）が渡す URL・テキストをそのまま compose に流し込む。なお NowPlaying の整形そのものは、v1.33 の責務分担見直しで**クライアント（capsicum）側に確定**しており（[nowplaying-design.md](archive/nowplaying-design.md) §責務分担）、モロヘイヤ側に残すのは URL を持たない源向けの enrich（メタデータ → 共有 URL 解決、[mulukhiya #4382](https://github.com/pooza/mulukhiya-toot-proxy/issues/4382)）のみ。旧来の「サーバー側ハンドラへ整形委譲」は廃止方針。

### Linux 固有の差分（v1.24）

v1.24 リリース直前の Linux 実機検証で判明・対応した、他プラットフォームと挙動が違う部分の **一覧**。各項目の詳細な理由・手順は二重管理を避けるため正本（コード doc コメント / packaging 配下）に集約し、ここでは差分の存在と参照先だけを示す（#509）。

- **OAuth 経路はシステムブラウザ + localhost callback** — 正本は [`AppConstants.localhostOAuthPort`](../packages/capsicum/lib/src/constants.dart)（ポート 7099 固定の理由・3 OS 共通の背景を記載）。Linux / Windows / macOS いずれも `flutter_web_auth_2` の server impl で回避する。
- **AppImage の起動時観測性**（`crashpad_handler` の chmod 補正 / `AppRun` logging wrapper）— 正本は [packaging/linux/appimage/README.md](../packaging/linux/appimage/README.md) と [`build.sh`](../packaging/linux/appimage/build.sh)。
- **sentry-native database path 固定** — 正本は [`platform/paths.dart`](../packages/capsicum/lib/src/platform/paths.dart) の `resolveSentryNativeDatabasePath`（AppRun の XDG 解決との対応も記載）。
- **flutter_secure_storage の register race 対策** — 正本は [`account_storage.dart`](../packages/capsicum/lib/src/service/account_storage.dart) の `_readWithRegisterRetry`（短間隔 retry の理由を記載）。

背景 issue は #488 / #489 / #491 / #496、プラグイン対応状況は [desktop-plugin-compatibility.md](desktop-plugin-compatibility.md) の flutter_web_auth_2 行を参照。

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
- ATOK 二重入力（[#54](https://github.com/pooza/capsicum/issues/54)）は Flutter 側の対応待ち。リリースごとにリリースノートの「既知の不具合」に記載し、Flutter 側の関連 issue の動向を確認する。記載時は回避策も併記する: (1) ATOK の「インライン入力」を OFF にする、(2) インライン入力 ON のままでも ATOK の「従来のカーソル位置入力を使用」を ON にすれば回避可（インライン入力を活かせる分こちらが実用的）、(3) 標準キーボードに切り替える
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
