# capsicum 開発ガイド

## プロジェクト概要

Flutter ベースの Mastodon / Misskey クライアント。
汎用クライアントとして動作しつつ、[mulukhiya-toot-proxy](https://github.com/pooza/mulukhiya-toot-proxy)（通称モロヘイヤ）導入済みサーバーでは拡張機能が利用可能になる。

- **技術スタック**: Flutter / Dart
- **対象プラットフォーム**: Android / iOS / iPad / macOS / Windows / Linux
- **配布**: Google Play / App Store / Mac App Store / Microsoft Store / Linux AppImage（直配）
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
| Flash | Play | 統一 | Misskey は **UI 表記が「Play」**（`navbar.ts` / `_play:` ロケール）で、**エンティティ・API 名が `Flash`**（`/api/flash/*`）という食い違いがある。capsicum も同じ使い分けをする（UI は「Play」・コード識別子は `Flash*`） |

「廃止語」は最新版で廃止された用語であり、capsicum でも一切使わない。「統一」は他方の SNS では現役だが、capsicum では UI 一貫性のためにどちらか片方に寄せている用語を指す。

コード内部の識別子（`Instance`, `InstanceProbe` 等）は変更不要。UI に表示する文字列のみ統一する。文字列リテラルをコード全体に散らすと用語の取りこぼしが起きやすいため、[post_scope_display.dart](../packages/capsicum/lib/src/ui/util/post_scope_display.dart) のように中央集約した定数を参照する設計を優先する。

### タグ管理の位置づけ

文末ハッシュタグの管理（削除してタグづけ・お気に入りタグ・タグセット・予約投稿タグ編集等）は、capsicum の根幹にある基本機能であり、リプライ・ブースト・ブックマークと同等に扱う。アニメファンにとって用語管理（キャラ名・作品名のタグ付け）は本質的な活動であり、この日常的なタグ管理ニーズを満たすことは他のクライアントにない capsicum 独自の価値である。品質・信頼性に関する問題は最優先で対応すること。

### アクションメニュー

投稿に対するアクション（お気に入り・ブースト・ブックマーク等）は、タイムライン上にボタンを露出させず、長押しで表示する BottomSheet メニュー内に格納する。誤タップ防止のため。

### ドロワー項目のナビゲーション様式（#805）

左ドロワーから機能を選んだときの遷移様式は、次の基準で使い分ける（一貫性のため明文化）:

- **ボトムシートのクイックチューザ** = 「自分の保存済みの◯◯（チャンネル / クリップ / アンテナ / Play / プロフィールタグ / リスト等）を 1 つ選んで、そのタイムラインへ飛ぶ」用途。頻繁操作を軽く済ませ、ホーム文脈から素早く飛べるようにする。全画面化すると日常操作が一段重くなるため採らない。
- **独立画面（`context.push`）** = そこに滞在する / 管理する行き先（通知・ブックマーク・ドライブ・設定・各種管理 UI 等）。

保存済みショートカットの「作成 / 編集 / メンバー管理」などの管理 UI は、クイックチューザの奥（シート内の導線）または対象画面内に温存する。ドロワー直下の一等地はクイックチューザに割り当てる。

### Mastodon / Misskey 機能マッピング

| 操作 | Mastodon | Misskey | 備考 |
|------|----------|---------|------|
| お気に入り | FavoriteSupport | ―（リアクションで代替） | Misskey は ReactionSupport で対応済み |
| ブックマーク | BookmarkSupport | BookmarkSupport（内部は favorites API） | Misskey の「お気に入り」は意味的にブックマーク相当 |
| ブースト / リノート | repeatPost() | repeatPost()（renote） | ラベルは ReactionSupport の有無で切替 |

- Misskey adapter は `FavoriteSupport` mixin を持たない（リアクションで代替済み）
- Misskey 判定は `adapter is ReactionSupport` で行う

### DM / メッセージの方針

- **Mastodon**（#179）: `GET /api/v1/conversations` で DM 専用タイムラインを実装
- **Misskey**（#248）: DM タイムライン API がない。最近の Misskey では「メッセージ」機能（スレッド形式チャット）が DM の後継と位置づけられており、こちらに対応する。v1.22 で実装完了。追加のバグ修正・enhancement（#442 系列・#449 レンダリング要素反映・#440 push tap 動線・グループチャット #438 等）は v1.25 / v1.28 で消化済み（個別 Issue の対応状況は Milestones が正本）

### タイムラインの読み込み挙動

タイムラインをスクロール中に一旦読み込みが止まり、少し戻すと再読み込みされる挙動はページネーションの正常な動作であり、不具合ではない。ユーザー報告の表現に引きずられずに判断する。

### 公開範囲とタイムラインの考え方

**タイムラインの設計は読む側の責任**とする。「自分と無関係な投稿はノイズだ」という言説は capsicum は採らない。見たくないものを見ないようにする道具（ハッシュタグ TL・リスト・ミュート等）は**読む側に**提供するが、**投稿者を静かにさせる方向の機能・配慮は入れない**。

この帰結として:

- **「TL を汚さないよう投稿者が公開範囲を下げる」を前提にした設計をしない。** 公開範囲は「誰に見えるか」の設定であって、「誰向けの話題か」の表明ではない。**話題の対象を示すのはハッシュタグの仕事**（プリセットサーバーのデフォルトハッシュタグがそれを担っている）。
- 定形投稿・周知系の機能に公開範囲を持たせない（[#767](https://github.com/pooza/capsicum/issues/767) の投稿テンプレートが実例。テンプレートは `id` / `name` / `body` / `cw` だけを持つ）。
- **モロヘイヤがキーワードから多くのタグを自動付与するのは、フィルタのしやすさへの配慮**（デフォルトタグ・辞書タグ・グループタグ等のハンドラー）。タグが多いこと自体が目的ではなく、**読む側にフィルタの取っ手を渡している**。「タグの多い投稿はスパム」という言説はここでも採らない — むしろその立場の人にとってこそフィルタしやすい構造になっている。よって **capsicum 側で「タグが多いのは問題だ」という前提の機能（自動削減・既定での非表示化等）を提案しない**。タグ管理を厚くする方向（[タグ管理の位置づけ](#タグ管理の位置づけ)）が capsicum の役割。

**技術的にも「ひかえめな公開で周知」は成立しない**（Mastodon 4.6 のフォークで実証済み）。`Status::Visibility` の enum は `suffix: :visibility` 付きで、`public_visibility` スコープが拾うのは `public` のみ。ハッシュタグ TL（`TagFeed#get` → `public_scope`）も同じスコープを使うため、**ひかえめな公開の投稿はハッシュタグ TL に出ない**。プリセットサーバーではローカル TL をデフォルトハッシュタグの TL に置換しているので、周知をひかえめな公開で出すと**届けたい相手（フォロワー外の同じサーバーの住人）にこそ届かなくなる**。

「周知だから公開範囲を絞る」系の要望が来た場合、実装する前にこの非対称を説明する。

### モロヘイヤ連携画面の導線

エピソードブラウザはタグセット BottomSheet 内のメニュー項目として配置する（Mastodon 改造版 WebUI と同じ動線）。投稿画面のツールバーに独立したアイコンを置く方式は、ユーザーに発見されにくいため採用しない。

### プッシュ通知

プッシュ通知には、Mastodon の Web Push を APNs/FCM に変換する中継サーバーの運用が必要。capsicum は主に自前サーバー（プリセット登録済み）のユーザー向けに開発されており、プリセットサーバーのユーザーには [pooza/capsicum-relay](https://github.com/pooza/capsicum-relay) 経由で無償でリレーを提供している。外部ユーザー向けの有償提供（[#597](https://github.com/pooza/capsicum/issues/597)・未実装）はそのコスト補填のための仕組みとして構想が残り、投げ銭サブスクと同じ商品 SKU で吸収できる可能性がある。

v1.15 の観測性強化（#293）により、iOS のバックグラウンド通知は発火回数 0回で事実上機能していないことが確認された。v1.18 でプッシュ通知リレー（[#52](https://github.com/pooza/capsicum/issues/52)）を実装し、根本解決済み。リレーサーバー（Ruby、公開ドメイン `relay.capsicum.shrieker.net`）の実装は [pooza/capsicum-relay](https://github.com/pooza/capsicum-relay) リポジトリが正本（ホスト構成・デプロイ手順はインフラノートが正本）。初期設計判断の経緯は [archive/push-relay-plan.md](archive/push-relay-plan.md) に保存。具体的な課金設計（料金体系・ストア課金統合等）はサポーターサブスク（[#428](https://github.com/pooza/capsicum/issues/428)）の設計検討の中で扱う。

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

**「バージョン番号に言及しない」は機能ゲーティングの通知に限った話**である。これは probing ベースで機能を出し分ける（版番号で分岐しない）基本戦略に対応する。一方、**サーバー情報画面**では、サーバーの素性を事実として提示する目的で、nodeinfo の software 名（Mastodon / Misskey / Fedibird 等）と本家 latest リリースへの追従状況（例「Misskey v2025.4.1 · 最新は 2026.6.0」）を表示する（[#816](https://github.com/pooza/capsicum/issues/816)）。これは機能ゲートではなく情報表示で、capsicum が最新の Mastodon / Misskey を対象にする以上「本家名を名乗らない／latest に届かないサーバーは新機能が使えない」ことをユーザーに納得してもらうためのもの。追従判定は nodeinfo の software 名が `mastodon` / `misskey` に完全一致する場合のみ行い、fedibird 等の別ソフトには出さない。設立日表示（[#815](https://github.com/pooza/capsicum/issues/815)、`accounts/1` 近似・account id の snowflake 化 2021-03 に注意）も同じ「サーバーの素性を可視化する」系。

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

### Codex レビューの回し方（open PR）

⚠ **追加コミットではレビューは発火しない。**`@codex review` を PR コメントに書いた時だけ走る（初回は PR 作成 / ready 化で自動）。**rebase / force-push で SHA が変わったときも打ち直す**。

巡回は次の形で止める（2026-08-23 決定）:

| | 対応 |
| --- | --- |
| 初回レビュー | PR 作成時に自動で走る |
| **P1** | 直して `@codex review` で再依頼 |
| **P2** | **直すだけ。再依頼しない** |
| **マージ直前** | severity を問わず **1 回だけ**再依頼（その PR で最後） |

⚠ **締めの 1 回を省かない。**これが無いと「**自分の修正が入れた欠陥を誰も見ない**」経路が残る。#1017 では P2 の修正そのものが退行（`_cancelPendingDraftSave` の移動で自動保存が永久停止）で、次の巡回で見つかった。#1021 では 4 巡目の修正が 5 巡目の穴を作った（宣言側だけ型引数を読み飛ばし、呼び出し側を放置）。

これで **1 PR あたり最大 2 回**に収まる。青天井にしないのは、#1021 が 6 巡かかった一方で**実コードの違反は初回で出尽くしており**、以降は検査そのものの網の細かさを上げる作業だったため（費用対効果が落ちる）。

各コメントは**返信 + 👍 の両方が揃って「完了」**（片方だけでは同期時に未完了と判定される）。判定手順は [sync-procedure.md](sync-procedure.md) の Codex セクションを参照。

### PR マージ後の確認事項

⚠ **マージ後にも指摘が付く。**上の締めの 1 回で拾いきれなかったぶんは、同期手順の Codex セクションで回収する。リリース PR の line comment は別系統なので明示的に数える。

## ディレクトリ構成

```text
capsicum/
  docs/                   # 開発ドキュメント
    CLAUDE.md             # 本ファイル
    architecture.md       # アーキテクチャ設計
    annict-integration.md # Annict 連携機能の説明（モロヘイヤ前提・作品/エピソード検索〜感想投稿）
    tech-notes.md         # 実装の落とし穴・API 固有の注意点
    dev-environment.md    # 開発マシン・検証端末・Sentry 環境
    desktop-plugin-compatibility.md  # デスクトップ対応のプラグイン棚卸し
    flutter-upstream-watch.md  # Flutter 上流バグの追跡（月初に手動で chase・資格情報の満了チェックも相乗り）
    api-gap-inventory.md  # 棚卸し: API にあって capsicum が使っていない機能（#993 の成果物・1.x / 2.0 / 拾わない の分類）
    webui-gap-inventory.md  # 棚卸し: WebUI にあって capsicum に無い機能（#991 の成果物・同じ 3 分類。層①＝画面 / ②＝画面内の操作 / ③＝表示要素）
    server-settings-gap-inventory.md  # 棚卸し: サーバー側に保存された設定の反映漏れ（#992 の成果物・誤爆 0 件の実測記録。⚠ 送らない = サーバー既定が効く、の設計を壊さないための正本）
    mastodon-capsicum-api-watch.md  # Mastodon 新バージョンの API 変更を client 影響でトリアージ（フォーク diff 手順つき・4.6 / 4.7 追従済み）
    misskey-capsicum-api-watch.md  # Misskey 新バージョンの API 変更を client 影響でトリアージ（マイナー毎・daisskey SHA アンカー）
    sync-procedure.md     # セッション開始時の同期手順
    roadmap.md            # 枠の数・各枠の主題・1.x と 2.x の境界（2026-09-04 策定・含有 Issue は Milestones が正本）
    milestone-transition.md  # マイルストーン完了→次着手の移行手順（トリアージ・スコープ確定・サイト更新・バンプ）
    doc-maintenance.md    # ドキュメント/メモリの棚卸し手順（不定期・陳腐化改善・memory↔docs 移送・インフラ記述の infra-note 移設・アーカイブ）
    store-release-guide.md  # ストアリリース手順書（運用正本）
    store-listing.md      # 各ストアの掲載文（提出のたびに参照する現役ドキュメント）
    supporter-subscription-plan.md  # 投げ銭サブスクの商品設計（審査ノートの英文もここ）
    msstore-review-notes-login.md   # Microsoft Store 審査向けのログイン説明（提出のたびに再利用）
    login-troubleshooting.md  # ログインできない報告の切り分け手順
    brand/                # ブランドアセット（アイコン・ロゴ等。v1.53 でルート assets/ から移設）
    archive/              # 過去の記録（現役運用では参照しない。release-log.md / release-pipeline.md 等）
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

マイルストーン完了→次着手の移行時に毎回回す一連の手順（未割り当て Issue のトリアージ・次スコープ確定・ロードマップ調整・capsicum-site 更新・バージョンバンプ）は [milestone-transition.md](milestone-transition.md) に手順化。**枠の数・各枠の主題・1.x と 2.x の境界は [roadmap.md](roadmap.md) が正本**（2026-09-04 策定）。以下は判断規約の正本。

⚠ **1.x と 2.x は並走系列で、境界は「時期」でも「技術的な線」でもない。****メジャーに何を載せるかは製品判断（売りの束ね方）**で、pooza が決める。`v2.0` は [#720](https://github.com/pooza/capsicum/issues/720) デッキ UI + [#597](https://github.com/pooza/capsicum/issues/597) 有償リレー + [#884](https://github.com/pooza/capsicum/issues/884) 画像編集レイヤの **3 本を束ねるメジャーリリース**。⚠ **この枠には「大更新 0〜1 件」の目安を当てない**（容量は通常枠の数倍。実績の最大は v1.0 の 46 件に対し直近の平均は 13 件）。技術規模が決めるのは「点リリースで単独配置するか」と「万一入りきらないとき何から逃がすか（＝ #884）」だけ。⚠ **2026-08-17〜 の「外部要因の発生ベース」運用は v1.65 をもって終了**した。

- **大更新は独立マイルストーンに単独配置**。UI の構造変更・既存モデルの拡張・複数画面への影響などが絡む「大更新」は、他に同規模以上の項目がないマイルストーンに入れる。並走させると設計検討・実装・動作確認がいずれも中途半端になるため
- **規模の測り方は「大更新の数」が主軸**。1 マイルストーンに入れるのは大更新 0〜1 件 + 小粒・中粒 5〜12 件程度を目安とする。件数は目安であって閾値ではない。リリース前レビュー（5 観点）の followup が膨らんだ場合、上限に縛られて後送りするより同一マイルストーンに取り込んで消化する方が望ましい（直前リリースの設計理解が新鮮なうちに直したいため）。**P1（緊急性あり）に加え、極めて容易な P2/P3 も同一マイルストーンで消化する**（数行の bug fix・コメント書き直し・リネーム・型変更等）。それでも入りきらない場合は、(a) リファクタ系を次マイルストーンに送る、(b) 観測性強化系を分離する、のどちらかで調整する
- **マイルストーン未設定は意図的な場合がある**。実現性検討中・Flutter 側の対応待ち・横断的タスクなどで pooza が意図的に未割り当てにしていることがあるため、「トリアージが必要」等と機械的に指摘しない。同期報告では一覧として淡々と列挙するに留める
- **ユーザー要望の振り分け基準**:
  - 不具合 → 可能なら着手中のマイルストーンに入れる
  - 改善要求（小規模）→ 着手中のマイルストーンに入れる
  - 改善要求（中〜大規模）→ 空いている先のマイルストーンに送る
  進行中のリリースを遅らせないバランスを取りつつ、ユーザーの声には必ず何かしらの形で応える

### 大玉の進め方（棚卸し → 分類 → 設計書 → 起票）

v2.0 に集めたメジャー級の大玉と、その種を見つける棚卸し 3 本（[#991](https://github.com/pooza/capsicum/issues/991) WebUI 差分 / [#992](https://github.com/pooza/capsicum/issues/992) サーバー保存設定 / [#993](https://github.com/pooza/capsicum/issues/993) 未使用 API）の回し方（2026-08-25 合意）。

1. **棚卸しは 1 本ずつ回す。**3 本は母数も手法も違うので同時に走らせない。順序は **#993 → #991 → #992**（#993 が最も機械的で当たりが出やすく、その結果が #991 の見方を決めるため）。**3 本とも完了・親 Issue は 3 本とも close 済み**で、次は v2.x のロードマップ（枠の数・各枠の主題・1.x との境界）。

   | 親（close 済み） | 完了日 | 成果物 | 続きの Issue |
   | --- | --- | --- | --- |
   | [#993](https://github.com/pooza/capsicum/issues/993) API 基準 | 2026-08-31 | [api-gap-inventory.md](api-gap-inventory.md) | [#1046](https://github.com/pooza/capsicum/issues/1046) 層②③ の残り |
   | [#991](https://github.com/pooza/capsicum/issues/991) WebUI 基準（層① のみ） | 2026-09-03 | [webui-gap-inventory.md](webui-gap-inventory.md) | [#1077](https://github.com/pooza/capsicum/issues/1077) 層② の変種と層③ |
   | [#992](https://github.com/pooza/capsicum/issues/992) サーバー側設定 | 2026-09-03 | [server-settings-gap-inventory.md](server-settings-gap-inventory.md) | [#1078](https://github.com/pooza/capsicum/issues/1078) 未確認 3 点 / [#1079](https://github.com/pooza/capsicum/issues/1079) preferences の決着 |

   ⚠ **親 Issue の close は「宿題の切り出し」とセットにする。**#991 / #992 は完了後も 2 日ほど open のまま残った（2026-09-04 の同期で検出）。宿題を Issue 本文でなく計画書の「未実施」節に置いたため、**行き先が Issue として見えず close の判断がつかなくなっていた**。完了条件が「計画書を残すところまで」の調査 Issue は、**計画書に残った宿題を Issue へ切り出してから close する**。

   ⚠ **#991 が #993 の後でも価値を出した理由を残す。**#993 の分類 A / B / C のどこにも無い項目が 3 件出た。3 件とも `routes/api.rb` にあるので #993 の母数には入っていたが、**capsicum が「付ける」側だけ実装して「見る」側を持っていない**形（お気に入りは付けられるが一覧できない / タグはフォローできるが一覧できない / 引用数は出しているが一覧できない）だった。**エンドポイント単位で数えると片方が緑なので落ちる。画面単位で見ると「一覧が無い」として一発で出る。**棚卸しは母数の取り方を変えると別のものが見える、という実例。

   ⚠ **#992 では「実害の型」が 1 つ増えた。**本文は実害を「誤爆（投稿）」と「見たくないものが見える（読み方）」の 2 種類で定義していたが、実測で出たのは **「見せたくないものが見えている」という第 3 の型**（本人が非表示にしたプロフィールのタブを capsicum が出していた → [#1076](https://github.com/pooza/capsicum/issues/1076)）。**「隠すべきものは隠す」は本来やってなきゃいけない**ので、意思表示の無視ではなく実装漏れとして扱う（2026-09-03 pooza）。**探すときは「サーバーが強制できない設定」から入ると早い** — 強制できるものはサーバーが既に強制しているので、クライアントが落とせる穴はそこにしか無い。

   ⚠ **#993 でいちばん効いた知見: 層を分けて回すこと。**「① 呼んでいないエンドポイント / ② 呼んでいる経路の未使用パラメータ / ③ 受け取っている entity の未読フィールド」の 3 層で見ると、**当たりの性質が層ごとに違った**。層① から出た 4 件は全部 enhancement（機能の欠落）だったのに対し、**層②③ から出た 3 件は全部 bug**（すでに動いている機能の壊れ方）で、しかも 3 件とも**サーバーがエラーを返さない**ため Sentry にもユーザー報告にも出てこないものだった。**層① だけで終えると、この種類は永久に見つからない。**

   ⚠ **層③ をモデルのフィールド一覧で測ると誤診する。**capsicum は一部の値を型付きモデルを経由せず生の `Map<String, dynamic>` から読んでいる。正しい母数の取り方は [api-gap-inventory.md](api-gap-inventory.md) §1「層③ の測り方」にコマンドごと置いた。
2. **分類は 3 分岐にする** — 「1.x で処理」「2.0 以降」に加えて **「拾わない」を必ず明示し、理由を書く**。棚卸しの母数には方針として実装しないもの（英語対応しない / 投稿の更新しない / Fedibird 低優先 / per-server 対応しない 等）が必ず混じるので、**黙って落とすと次の棚卸しで同じものが再浮上する**。
3. **成果物は `docs/` の計画書 1 本にまとめ、Issue 化は分類が確定してから。**先に起票すると、マイルストーン未定のまま滞留する [#905](https://github.com/pooza/capsicum/issues/905) / [#915](https://github.com/pooza/capsicum/issues/915) の形になる。確定後に **1.x 行きだけを稼働中の枠へ、2.0 行きは v2.0 に据え置き**で起票する。
4. **超大玉は設計書を先に書く。**複数 Issue に分解されることが確実なもの（[#720](https://github.com/pooza/capsicum/issues/720) デッキ UI / [#597](https://github.com/pooza/capsicum/issues/597) 有償リレー）は、Issue に割る前に `docs/` へ設計書を置く。⚠ **[#884](https://github.com/pooza/capsicum/issues/884)（画像編集のレイヤ管理）は対象外** — 投稿フォーム内で閉じるので Issue 本文で足り、設計書にすると逆に重くなる。

設計書の型は既存の 6 本（[archive/push-relay-plan.md](archive/push-relay-plan.md) / [archive/desktop-notification-design.md](archive/desktop-notification-design.md) ほか）に倣い、**`## 決定済み事項` と `## 未決事項` を分ける**。未決を明示的に置けるので「全部決まるまで完成しない」状態で止まらない。⚠ **設計書の効用は分解だけではない** — desktop-notification-design では書いた結果 #476 が不要と判明して close できた。**Issue から始めるとこれができない**。

### コミットの分割方針

コミットはなるべく Issue ごとに分ける。レビュー・revert・cherry-pick の粒度を保つため。同じファイルに複数 Issue の変更が混在して分離できない場合のみ、まとめてよい。

### クロスリファレンス

- capsicum → モロヘイヤ: `pooza/mulukhiya-toot-proxy#XXXX`
- モロヘイヤ → capsicum: `pooza/capsicum#XXXX`

## 運営元

capsicum の運営元は有限会社ビーショック（<https://www.b-shock.co.jp>）。課金（投げ銭サブスクは v1.27 で実装済み・外部ユーザー向け通知リレーの有償提供は構想中）を前提に、商品扱いとする方針。

- サイト運営・問い合わせ窓口・特商法表示は法人名義（capsicum-site / Google Workspace アドレス経由）
- 著作権表記は個人名義のままで問題なし
- **ストア発行元（Apple / Google / Microsoft Store の Seller / Publisher Display Name）は当面個人（小石達也）で 3 ストア整合**。Apple は登録時の Team Prefix 固定の経緯で個人、Google も個人で運用、Microsoft Store も同方針で 2026-05-09 に個人開発者登録 + アプリ予約完了（identity_name=`9AFBB08E.capsicum`、publisher_display_name=`小石達也`）
- 法人化（個人 → 有限会社ビーショックへの 3 ストア一括移行 + Apple は App Transfer 経由）は税務・ブランド要請が顕在化した時点で実施。**サポーターサブスク（[#428](https://github.com/pooza/capsicum/issues/428), v1.27）開始は移行の必須トリガーではない**（税務処理・プライバシー面の判断根拠は非公開メモリ `project_supporter_subscription_individual_entity` が正本）
- 「個人開発のアプリ」「個人発行元のストア配布」と「法人運営のサービス」は法的に矛盾しない（開発 / 配布 / 運営は独立した役割）。ブランド一貫性のみ運用課題として残るが、無料アプリの間は実害なし

### 課金の方向性

当初は「外部ユーザー向けプッシュ通知リレーのコスト補填」を想定していたが、プリセットサーバーの既存ユーザーから「機能差別化なしでよいので投げ銭させてほしい」という要望が先に顕在化したため、サポーターサブスク（[#428](https://github.com/pooza/capsicum/issues/428)）を主軸に設計検討する方針に変更（2026-04-30）。

- 機能差別化なし、装飾レベルの視覚的フィードバック（サポーターバッジ等）にとどめる
- 外部ユーザー向けプッシュ通知リレーの有償提供と同一 SKU で吸収できないか検討
- ストア審査対策（"What does this app do?" で trivial 扱いを避ける）として複数階層・継続性のあるサブスクで構成

v1.27 マイルストーンに単独配置し（大更新のため他項目と並走させず）、商品設計 + 課金経路 + 装飾範囲まで同マイルストーン内で実装・出荷した。並走した自動化系タスク [#544](https://github.com/pooza/capsicum/issues/544)（Microsoft Store Web UI 手動 publish ルート再開）も同マイルストーンで対応済み。Flathub 対応は 2026-05-29 に断念（提出 PR が AI Slop 判定、#604 / #470 とも close）。Linux 配布は AppImage 単独。

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

最新リリース: **v1.63.0**（2026-09-04 タグ、build 179、pubspec 1.63.0+179、リリース PR [#1069](https://github.com/pooza/capsicum/pull/1069)、merge `d99b3b53`）。**大更新なし — 棚卸し 3 本（#993 / #991 / #992）の成果を消化する枠**。**全 5 プラットフォーム公開済み**（2026-09-05 実測）: iOS / macOS とも 1.63.0 が `READY_FOR_SALE`（ASC API のプラットフォーム別 `appStoreState`）/ Android は production track の versionCode 179 が `completed`（Play API）/ Windows は Microsoft Store の現行パッケージが `9AFBB08E.capsicum_1.63.179.0_x64`（displaycatalog）/ Linux AppImage は [GitHub Release v1.63.0](https://github.com/pooza/capsicum/releases/tag/v1.63.0)（Latest）。マイルストーン [#77](https://github.com/pooza/capsicum/milestone/77)。消化（11 件）: [#1039](https://github.com/pooza/capsicum/issues/1039) ブロック・ミュートの一覧と解除（**この枠の主役**）/ [#1040](https://github.com/pooza/capsicum/issues/1040) フォローリクエストの承認・拒否 / [#1041](https://github.com/pooza/capsicum/issues/1041) Misskey の本文検索 / [#1043](https://github.com/pooza/capsicum/issues/1043) 「指名」を選択肢から外す / [#1044](https://github.com/pooza/capsicum/issues/1044) リアクションが黙って ❤️ へ差し替えられる / [#1045](https://github.com/pooza/capsicum/issues/1045) 通知取得でサーバー側の未読が消える / [#1068](https://github.com/pooza/capsicum/issues/1068) CW 内のハッシュタグをクリッカブルに / [#1070](https://github.com/pooza/capsicum/issues/1070) フォロー中のハッシュタグの一覧 / [#1071](https://github.com/pooza/capsicum/issues/1071) お気に入りの一覧 / [#1072](https://github.com/pooza/capsicum/issues/1072) 引用の一覧 / [#1080](https://github.com/pooza/capsicum/issues/1080) 通知の取得が異常に遅い（**ユーザー報告由来**）。**relay は v1.63 で触っていない**（open Issue 0 件・同名マイルストーン無し）。⚠ [#1076](https://github.com/pooza/capsicum/issues/1076) は**起票時点で実装済み**と判明して close、[#1042](https://github.com/pooza/capsicum/issues/1042) は**前提が誤り**（絞る UI がそもそも無い）で v2.0 へ移送。

⚠⚠ **リリース前レビューで 🔴 5 件、うち 4 件がその日に入れた変更由来だった。**5 観点を独立に並列で回した効果が出た回で、**3 件は複数観点が独立に同じ結論**に達している（単一視点なら取りこぼしていた）。逆に**私が「いちばん怪しい」と名指しした箇所は無罪**で、実際の 🔴 は名指ししていなかった箇所から出た。**当たりの見当は外れてよく、母数を広く取るほうが効く。**

⚠⚠ **サーバーの挙動を推測で語らない。**#1043 で「Misskey の指名投稿は `visibleUserIds` を送らないと誰にも届かない」を前提に丸めを実装し、レビューで否定された。サーバーは**返信のときだけ返信先の作者を `visibleUsers` へ自動補完する**ので、**返信は従来どおり届いていた**。しかも `reply.visibility === 'specified'` と異なる visibility の返信は 400 で拒否されるため、**動いていた返信を壊していた**。さらに redraft では**サーバーが弾かないまま DM がフォロワー全員へ出る**形だった。⚠ **`~/repos/misskey` を開けば 5 分で否定できた**（[reference: フォークは運用中のサーバーソフトそのもの](#関連リポジトリ)）。

⚠⚠ **テストが「バグの側」を固定していた事例が 2 件**（is_cat の「通信例外もキャッシュに載る」/ 検索の「rethrow する」）。**テストがあることは正しさの証明にならない。**バグごとテストで固めると、次に直す人がテストを根拠に戻す。

⚠ **Codex は 5 観点レビューが見落とした P1 を出した**（リアクション判定の経路取りこぼし。ピッカーの入口 2 箇所にしか入れておらず、既存チップ・カスタム絵文字・通知タイルが素通しだった）。2 巡目の P1 は誤検出（`following/requests/list` の戻り値の形）で、**フォークのソースを引いて否定した**。⚠ **実在の P1 が出たときだけ再依頼**し、P2 のみなら直すだけにする。

⚠ **ビルドが 22 分かかった原因は DerivedData の肥大**（14G）。内蔵ディスクの空きが 8.7GB まで落ち、`xcodebuild clean` が 502 秒かかっていた。⚠ **Xcode は作業ディレクトリのパスごとに別エントリを作り、古いものを消さない**（6〜8 月のものが 13 個残っていた）。消したら 66M・空き 22G に回復。⚠ **外部ボリュームが遅いせいではない**（小ファイル 5000 件の作成・削除を実測したところ内蔵と差が無かった）。

過去リリースの詳細ログは [archive/release-log.md](archive/release-log.md) に退避した（正本は [GitHub Releases](https://github.com/pooza/capsicum/releases) / Milestones）。マイルストーン移行時のログトリム手順は [milestone-transition.md](milestone-transition.md) を参照。

### デスクトップ対応

macOS / Linux / Windows のデスクトップ環境への展開。動機は、iOS 版を Mac 上で実況用途に使って手応えがあること。v1.21 以降のマイルストーンに組み込み済み（当初は v1.19 → v1.20 → v1.21 と後ろ倒しを重ね、プッシュ通知完成 v1.20 を挟んだ上で着手する並びに落ち着いた）。

1. **第1段階: macOS ネイティブ化（v1.21、土台完成）** — `flutter config --enable-macos-desktop` を有効化し、Apple Developer Team / Apple Development 署名 / App Sandbox / Hardened Runtime / keychain-access-groups の設定を導入。Universal Purchase で iOS と同一 App レコードに紐付け済み。プラグインのデスクトップ対応状況の棚卸し・video_player → media_kit の事前調査もこの段階で完了。ストア配布（.pkg ラップ + fastlane の macOS lane）は [#407](https://github.com/pooza/capsicum/issues/407) で v1.21.x にて対応する
2. **第2段階: バックグラウンド/通知モデルの再設計（v1.23、完了）** — デスクトップにはバックグラウンド更新の概念がないため、通知ポーリング相当の仕組みを抽象化して差し替え可能にした。v1.18 のプッシュ通知リレー完了・v1.19 (#348) での workmanager / iOS BGTask 撤去後、モバイル側は APNs / FCM 一本化済み。v1.23 で `BackgroundTaskScheduler`（#328、Dart `Timer` + 常駐前提のフォールバック実装）/ `MediaPicker`（#329、image_picker + file_selector 統合）/ `NotificationSubsystem`（#330、flutter_local_notifications プラットフォーム差吸収）の各層を導入
3. **第3段階: Linux / Windows 対応（v1.24〜v1.27、完了）** — 第2段階で通知周りが整理され、プラグイン依存の棚卸しが済んでから着手。Linux は **AppImage 単独配布**（v1.24〜。Flathub は [#604](https://github.com/pooza/capsicum/issues/604) で 2026-05-29 断念、以降は AppImage 単独に確定）。Windows は v1.25 で **自己署名 MSIX 直配**（[#423](https://github.com/pooza/capsicum/issues/423)）、v1.27 で **Microsoft Store 公開達成**（[#544](https://github.com/pooza/capsicum/issues/544)、毎リリース Partner Center Web UI から手動 publish）。OAuth は 3 OS とも `flutter_web_auth_2` の localhost callback（port 7099、[`AppConstants.localhostOAuthPort`](../packages/capsicum/lib/src/constants.dart)）に統一。動画再生は media_kit 移行（[#492](https://github.com/pooza/capsicum/issues/492)、v1.30）で Linux / Windows も対応。コード署名証明書取得（[#534](https://github.com/pooza/capsicum/issues/534)）は Store 再署名のため当面不要（IV 証明書取得済みだが capsicum 適用はお蔵入りで close）。Windows push 本配線（[#474](https://github.com/pooza/capsicum/issues/474)）は **v1.40（「Windows 仕上げ」大更新マイルストーン）で出荷済み**（WNS 資格情報の満了は 2028-06-22）。Windows 投げ銭 IAP（[#599](https://github.com/pooza/capsicum/issues/599)）は当初 v1.40 に束ねる想定だったが、x64 実機環境・Partner Center アドオン審査待ちで分離し **v1.43 で出荷済み**（Microsoft Store IAP）。SMTC NowPlaying（[#484](https://github.com/pooza/capsicum/issues/484)）は v1.33 で実装・**実機検証済み**（C++/WinRT メソッドチャンネル。ARM64 Windows でローカル x64 ビルドは ATL 未導入 / jni / crashpad の x64-on-ARM64 で詰まるため、CI windows-release.yml の `capsicum-msix` artifact を gh run download → `Add-AppxPackage` で導入して検証する経路を確立）。実機検証は Linux [#425](https://github.com/pooza/capsicum/issues/425) / macOS [#494](https://github.com/pooza/capsicum/issues/494)。

各マイルストーンの主題・スコープ・個別 Issue 構成は [GitHub Milestones](https://github.com/pooza/capsicum/milestones) が正本（CLAUDE.md には複写しない）。過去の版ごとの主題・消化 Issue・分割の経緯は [archive/release-log.md](archive/release-log.md) と Milestones を参照する。スコープの組み方・過積載時の調整・移行整備の判断規約は「[Issue 管理 › マイルストーン運用](#マイルストーン運用)」節と [milestone-transition.md](milestone-transition.md) を正本とする（**大更新は独立配置**が基本方針）。

Issue [#475](https://github.com/pooza/capsicum/issues/475) (Linux push 方針) の議論で、**desktop 3 OS 共通の「WebSocket streaming → OS ローカル通知」設計** を確定した（2026-05-15、[desktop-notification-design.md](archive/desktop-notification-design.md)）。Mastodon の `user` stream / Misskey の `main` channel に長寿命 WebSocket で接続し、notification / announcement event を `flutter_local_notifications` (libnotify / NSUserNotification / WinRT Toast) に流す経路。アプリ起動中の中間解として 3 OS 共通で機能し、native push（[#468](https://github.com/pooza/capsicum/issues/468) macOS APNs=v1.34 / [#474](https://github.com/pooza/capsicum/issues/474) Windows WNS=v1.40、いずれも実装済み）とは `notification.id` dedup で併存する。実装 issue は [#569](https://github.com/pooza/capsicum/issues/569) として切り出し済み（v1.34 主役、大更新）。本設計の確定により、ポーリング前提だった「お知らせ通知 A 案」(#476) は不要となり close、capsicum-relay 経由の C 案 (#477、v1.29) は mobile 配信を継続して担う構図に整理された。この配送対象は v1.57 で **mobile + macOS + Windows** に広がった（macOS = [#919](https://github.com/pooza/capsicum/issues/919) / capsicum-relay#36 Phase 1、Windows = [#978](https://github.com/pooza/capsicum/issues/978) / relay#36 Phase 2。relay 側はいずれも本番へデプロイ済み）。**Linux だけはネイティブ push の経路自体が無い**ため、お知らせは**アプリ起動中しか届かない**。設定画面はトグルの代わりにその旨を説明する。

配送先を増やすときは **relay の `AnnouncementWorker#deliver` の `case` と capsicum の `deliverableDeviceTypes` が 1 対 1** であること（片方だけ広げると「購読行はあるのに届かない」／「送っても黙って捨てられる」になる）に加え、**payload に載せるフィールドの device_type 差**にも注意する。Windows 宛だけは `announcement_body`（整形済み本文）を足し `announcement_content`（HTML）を落とす — WNS raw の上限 5000B に対して HTML は表示に使われないため。⚠ **この整形本文を全 device_type 共通の payload に足してはいけない**: APNs / FCM は 4KB 上限で、お知らせの payload には degrade で落とせるキーが無く（`ApnsPayload::ENCRYPTED_KEYS` は暗号化 Web Push 由来のキーのみ）、`poll_server` が配送後に `mark_announcement_seen` を打つため **1 通が永久に失われる**（relay PR #43 の Codex P1）。

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

v1.24 リリース直前の Linux 実機検証で判明・対応した、他プラットフォームと挙動が違う部分の **一覧**。各項目の詳細な理由・手順は二重管理を避けるため正本（コード doc コメント / distribution 配下）に集約し、ここでは差分の存在と参照先だけを示す（#509）。

- **OAuth 経路はシステムブラウザ + localhost callback** — 正本は [`AppConstants.localhostOAuthPort`](../packages/capsicum/lib/src/constants.dart)（ポート 7099 固定の理由・3 OS 共通の背景を記載）。Linux / Windows / macOS いずれも `flutter_web_auth_2` の server impl で回避する。
- **AppImage の起動時観測性**（`crashpad_handler` の chmod 補正 / `AppRun` logging wrapper）— 正本は [distribution/linux/appimage/README.md](../distribution/linux/appimage/README.md) と [`build.sh`](../distribution/linux/appimage/build.sh)。
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
- **マイルストーンに載らない集約 Issue を作らない**: 「切り出す価値が出たら切り出す」形のアンブレラは、**マイルストーンが付かないので誰も着手せず放置される**（v1.52 / v1.53 の緑まとめ [#905](https://github.com/pooza/capsicum/issues/905) / [#915](https://github.com/pooza/capsicum/issues/915) で 37 項目が滞留し、2026-08-02 に解体）。束ねること自体は可だが、**束ねたら必ずマイルストーンを付け、「その枠で全部やる」チェックリストとして扱う**。行き先の判断基準は [store-release-guide.md](store-release-guide.md) の「リリース前レビュー」節を正本とする
- **2 回目レビュー（差分レビュー）**: プラットフォーム追加・大更新独立配置マイルストーンに限り、1 回目の修正 commit に起因する新規問題を拾うため 2 回目を回す。対象は 1 回目以降の差分と新規サーフェスのみ。リリース 1 週間前までに完了させ、直前に出た P1 はホットフィックス前提で次リリースに送ってよい（詳細は [store-release-guide.md](store-release-guide.md) §4.0）
- ATOK 二重入力（[#54](https://github.com/pooza/capsicum/issues/54)）は Flutter 側の対応待ち。リリースごとにリリースノートの「既知の不具合」に記載し、Flutter 側の関連 issue の動向を確認する。記載時は回避策も併記する: (1) ATOK の「インライン入力」を OFF にする、(2) インライン入力 ON のままでも ATOK の「従来のカーソル位置入力を使用」を ON にすれば回避可（インライン入力を活かせる分こちらが実用的）、(3) 標準キーボードに切り替える
- マイルストーン未設定の Issue は `no:milestone` フィルタで確認する
- **`Windows` / `Linux` ラベルは「その実機でないと進まない」の目印**（再現確認が起点・修正案の選択が実機の挙動次第）。開発のメインは macOS なので、着手できる端末が限られることを一目で分かるようにするためのもの。3 OS 共通のデスクトップ機能に付ける `desktop` とは別で、`desktop` は macOS でも進められる。拾い方は [dev-environment.md](dev-environment.md) の「その端末で拾う作業の探し方」
- Flutter framework 由来の不具合（capsicum 側で根治不能なもの、`flutter` ラベル付き）は [flutter-upstream-watch.md](flutter-upstream-watch.md) で集中管理し、**月初のセッションで手動 chase** して上流の進捗を巡回する。⚠ **クラウドの schedule routine は 2026-08-21 に廃止した**（4 か月連続で発火しても成果コミットが 1 件も残らず、実務はローカル頼みだった）。**資格情報の満了チェックがこの巡回に相乗りしている**点に注意

### 実装しない機能

- 投稿の更新（Mastodon）— SNS にふさわしい機能と判断しないため

## セッション開始時の同期手順

会話の最初に「進捗を同期してください」等の指示があった場合、[sync-procedure.md](sync-procedure.md) の手順に従う。

作業中にセッションが切れて「続きをやって」と指示された場合は、同期手順は回さず [sync-procedure.md](sync-procedure.md) の「作業中断からの復帰」に従う。

## ドキュメント表記規約

モロヘイヤ側の規約に合わせる:

- **サーバーの呼称**: 「インスタンス」ではなく「サーバー」を使う
- **ファイル参照**: マークダウンリンクにする

### CLAUDE.md の定期見直し

CLAUDE.md はセッション開始時に全文読み込むため、完了済みの情報や歴史的経緯が蓄積するとノイズとなり、重要な設計方針の認識精度が下がる。マイルストーン数回ごとに CLAUDE.md を見直し、完了済み・陳腐化した情報を削除するか外部参照に集約する。具体的な棚卸し手順（陳腐化改善・memory↔docs の移送・インフラ記述の infra-note 移設・役目を終えた docs のアーカイブ）は [doc-maintenance.md](doc-maintenance.md) に手順化してある（不定期・オンデマンド実施）。
