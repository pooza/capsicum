# Mastodon capsicum 影響トリアージ

Mastodon の各バージョンの変更のうち、**capsicum（クライアント）に対応が必要なもの**を切り分ける運用。Misskey 版（[misskey-capsicum-api-watch.md](misskey-capsicum-api-watch.md)）の Mastodon 版にあたる。

⚠ **もとは 4.6 専用の一覧（`mastodon-46-capsicum-triage.md`）だった**が、4.7 まで同じ手順で追従したため 2026-08-21 に汎用化・改名した。4.6 の初回トリアージ結果は下の「トリアージ結果（v4.5.9 → v4.6.0）」節にそのまま残してある。

## なぜこの文書があるか

リリースノートは server / Web / admin / client の変更が混在し、散文からは「どれに capsicum 対応が要るか」が見えにくい。capsicum に効くのは**クライアントから見える API の変化だけ**（entity の新フィールド・新エンドポイント・パラメータ変更）なので、**フォークの API コードを直接 diff** して機械的に抽出する。

## 抽出方法（次バージョンでも再利用可）

capsicum の実接続先は美食丼フォーク（`pooza/mastodon`）。**リリースノートではなくフォークのタグ同士を diff** する（`~/repos/mastodon` で fetch 済みなら pull/checkout 不要）:

```bash
cd ~/repos/mastodon
OLD=v4.7.0-bshockdon; NEW=v4.7.1-bshockdon   # 直近は v4.6.6-bshockdon → v4.7.0-bshockdon
# クライアントに効く entity フィールド
git diff $OLD..$NEW -- app/serializers/rest/
# 新規 entity / endpoint
git diff --name-status --diff-filter=A $OLD..$NEW -- app/serializers/rest/ app/controllers/api/
# 新規ルート
git diff $OLD..$NEW -- config/routes/api.rb
# minor 跨ぎでは routes 全体・streaming・フォーク固有のオペ変更も見る（4.7 で追加）
git diff --stat $OLD..$NEW -- config/routes/ streaming/
git diff --name-status $OLD..$NEW | grep -iE 'nginx|mulukhiya|rc\.d'
```

各項目を **none（server/web 専用・無関係）/ passive（additive で自動追従・無害）/ actionable（対応候補）** の3段でトリアージする。

## トリアージ結果（v4.5.9 → v4.6.0）

### 🔴 actionable（対応候補）

| API 変化 | 内容 | Issue |
|---|---|---|
| account `show_media` / `show_media_replies` / `show_featured` | プロフィールのタブ非表示設定への追従 | [#732](https://github.com/pooza/capsicum/issues/732)（v1.44） |
| **Collections 横断**: 新 `/api/v1/collections`(+items / context / in_collections / accounts/:id/collections) ・account `feature_approval` ・status `tagged_collections` ・search `collections` ・notification 新 type **2 種**（`added_to_collection` / `collection_update`、いずれも `collection` キーで `REST::CollectionSerializer` 同梱）・role `collection_limit` ・新 entity Collection / CollectionItem / CollectionWithAccounts / ShallowTag / PartialAccount | キュレーション共有（FEP-7aa9）。**単なる新エンドポイントでなく account / status / search / notification entity に染み出す横断変更**。受信側を分割: 通知描画 [#741](https://github.com/pooza/capsicum/issues/741)（v1.41・前倒し）/ 被フィーチャー操作 [#742](https://github.com/pooza/capsicum/issues/742)（v1.44） | オーナー側 [#722](https://github.com/pooza/capsicum/issues/722)（v1.44） |

### 🟡 actionable（小粒・additive な拾い物）

| API 変化 | 内容 | Issue |
|---|---|---|
| account `avatar_description` / `header_description` | アバター / ヘッダー画像の alt テキスト | [#733](https://github.com/pooza/capsicum/issues/733)（v1.44） |
| relationship `muting_expires_at` | ミュートの有効期限 | [#734](https://github.com/pooza/capsicum/issues/734)（v1.44） |
| custom_emoji `featured` | フィーチャー絵文字（カテゴリ） | [#735](https://github.com/pooza/capsicum/issues/735)（v1.44） |
| 新 `/api/v1/profile`(show / update, avatar / header destroy) + Profile entity | プロフィール編集 v2 専用エンドポイント。現状 `update_credentials` で動作するため移行は任意 | [#736](https://github.com/pooza/capsicum/issues/736)（v1.44） |

### ⚪ passive / none（対応不要）

- **passive（additive・自動追従/degrade 済み）**: notification `fallback` ＋未知 type → 既に `NotificationType.other` へ degrade（[#721](https://github.com/pooza/capsicum/issues/721) で確認）。status `contexts_controller` 新設・preview_card `missing_attribution`。
- **none（server / web / admin / 連合内部・capsicum 無関係）**: instance `wrapstodon`（年間まとめ）/ `/api/v1/donation_campaigns` / account `email_subscriptions` ＋ `/api/v1/accounts/:id/email_subscriptions` / `/api/v1/instance/terms_of_service` / annual_report・report・ip_block 系 / ActivityPub の feature・featured 連合 serializer 群。

## パッチ追従ログ（4.6.x）

⚠ 4.7 以降は下の「4.7 GA トリアージ」節に続く。minor が上がったら `## 4.X GA トリアージ` を足し、その中に patch 追従を書く。

minor 内の patch 更新（自前 3 鯖は pooza が本番へリリース日にデプロイ済み＝**その時点で capsicum は既にその patch と通信している**）。patch でも API 応答や streaming 挙動が動くことがあるため、上と同じ diff 手順で client 影響だけ機械抽出し、結果を 1 行残す（重複確認の防止）。

### v4.6.3 → v4.6.4（2026-07-28 本番適用済み・2026-07-30 トリアージ）

**client 影響なし（capsicum コード変更ゼロ）**。bugfix / security patch。内訳:

- **サーバー側修正で capsicum が恩恵を受けるだけ**: 期限なし投票で投票できなかった不具合（[upstream #39949](https://github.com/mastodon/mastodon/pull/39949)）/「メディアを警告付きで隠す」フィルタの適用漏れ（#39946）。いずれも判定はサーバー側で、capsicum は送る／読むだけ。
- **capsicum の経路でない / 無関係**: Web Push 削除の CSRF 緩和（#39918）は `/api/web/...`（Web UI 用）で `/api/v1/push/subscription` とは別。`verify_credentials` の `follow_requests_count` から suspended 除外（#39858）はフィールド形状不変。引用投稿**編集**まわりの一連の修正（#39837 等）は capsicum が「投稿の更新（Mastodon）」を実装しない方針のため無関係。絵文字検索 / ハッシュタグ autosuggest は Web UI。ActivityPub / Account::Merging は連合内部。
- **フォーク streaming 変更（むしろ有益）**: プリセット鯖のローカル TL（= デフォルトタグ TL）で、ライブ更新にも `public:local → hashtag` リマップを追加（従来リモートのデフォルトタグ投稿が live のローカル firehose から漏れていたのを解消）。**ストリーム名ラベルは `public:local` のままでクライアントプロトコル不変**のため capsicum は変更不要。デルムリン丼・キュアスタ！で有効（美食丼＝デフォルトタグ無しは無効）。

### v4.6.4 → v4.6.5（本番 3 台適用済み・2026-08-08 トリアージ）

**client 影響なし（capsicum コード変更ゼロ）**。`app/serializers/rest/` / `app/controllers/api/` / `config/routes/api.rb` の差分がいずれも**空**で、クライアントから見える entity・エンドポイント・ルートは 1 つも動いていない。内訳:

- **Web UI 専用**: プロフィール画像クロップの oversized アップロード（[upstream #39958](https://github.com/mastodon/mastodon/pull/39958)）/ 絵文字検索リクエストのキャンセル（#39947）。いずれも `app/javascript/` 配下。
- **サーバー / 連合内部**: Collection item 読み取り属性の誤り（#40052）・item 上限の強制（#39969）/ 引用埋め込み処理の typo（#40049）/ `Account::Merging` の AccountWarning 欠落（#39982）/ `process_status_update_service` の添付 4 件上限 typo（#39978）。capsicum は送る／読むだけ。
- **フォークのサーバー設定**: nginx の access ログをマスク付き `combined_masked` へ / `proxy_pass` を `127.0.0.1` 直指定へ / rc.d の pkill パターン限定。加えて **`PUT /api/v1/statuses/:id` の `X-Mulukhiya-Purpose` 分岐を `if` から map へ寄せた**（mulukhiya#4474 の本番反映）。`if` 内の `proxy_pass` が rewrite フェーズを終端せず後段の `return 405` が勝っていた件の修正で、[#121](https://github.com/pooza/capsicum/issues/121)（Mastodon の ALT 編集・v1.57）の on-hold 解除の根拠そのもの。**クライアントプロトコルは不変**。

### v4.6.5 → v4.6.6（本番 3 台適用済み・2026-08-14 トリアージ）

**client 影響なし（capsicum コード変更ゼロ）**。`app/serializers/rest/` ・ `app/controllers/api/` ・ `config/routes/api.rb` の diff がいずれも**完全に空**。クライアントから見える entity・エンドポイント・ルートは 1 つも動いていない。4.6.x 系はこれで打ち止め見込み（次は 4.7）。

## 4.7 先読み（v4.6.6 → v4.7.0-beta.1・upstream 同士・2026-08-14）

**まだベータ・自前サーバ未デプロイ**。GA 前に safe を確定させる方針（memory `project_mastodon_46_posture`）に沿った先読み。upstream に `-bshockdon` タグはまだ無いので upstream `v4.6.6..v4.7.0-beta.1` を diff した。**現時点で破壊的変更なし・capsicum 対応不要**。差分は「無効ハンドル（invalidated username）」対応の一式のみ:

- **passive（additive・新 bool フィールド）**: account に `invalid_handle`（`if: :invalid_handle?`。webfinger で失効した remote アカウントの `! <id>` 化を表す）。未知フィールドとして無視で無害。UI バッジ化は任意の拾い物候補だが**ベータ・低価値のため起票せず様子見**。
- **passive（既存フィールドの値正規化）**: account / status / announcement の `username`（および `acct`）が `pretty_username` / `pretty_acct` 経由になった。**通常アカウントでは値不変**（`pretty_username == username`）。失効ハンドルの稀なアカウントだけ生の `! 123` でなく `123` / `123@handle.invalid` を返すようになり、むしろ表示に優しい。capsicum は受け取った値をそのまま描画するだけで parse も壊れない。
- **passive（条件変更）**: account の `suspended` を出す条件が `suspended?` → `unavailable?` に拡大。フィールド形状（bool）は不変。
- **none（内部リファクタ）**: 新規 `app/controllers/api/v1/accounts/base_controller.rb` は共通基底の抽出でルート追加なし（`config/routes/api.rb` diff 空）。

→ **2026-08-21 に GA / `-bshockdon` タグ化を確認し、上の「v4.6.6 → v4.7.0」節で再確認済み。結論は変わらなかった。**

## 4.7 GA トリアージ（v4.6.6-bshockdon → v4.7.0-bshockdon・本番 3 台適用済み・2026-08-21）

**client 影響なし（capsicum コード変更ゼロ）**。⚠ **上の「4.7 先読み」節（beta.1 時点）の結論がそのまま GA でも成立した** — beta で見た 4 項目以外にクライアント可視の変化は増えていない。フォークのタグ全体では 717 ファイル動いているが、`config/routes/api.rb` の diff は**完全に空**で、`app/serializers/rest/` は 3 ファイル計 +18/-3 行しか動いていない。

- **passive（additive・新 bool フィールド）**: account に `invalid_handle`（`if: :invalid_handle?`）。webfinger で失効した remote アカウントを示す。capsicum は未知フィールドとして無視で無害。
- **passive（条件変更・形状不変）**: account の `suspended` を出す条件が `suspended?` → `unavailable?` へ拡大（`delegate` も追随）。bool のまま。
- **passive（値の正規化）**: account / announcement / status の `username` が `pretty_username` 経由になった。通常アカウントでは値不変で、失効ハンドルの稀なケースだけ生の `! 123` でなく `123` を返す。capsicum は受け取った値をそのまま描画するので parse も壊れない。
- **none（内部リファクタ・ルート追加なし）**: 新規 `app/controllers/api/v1/accounts/base_controller.rb` へ 8 コントローラの共通処理を集約（計 -52/+24 行）。`api/v1/accounts_controller` / `admin/ip_blocks` / `collections` / `collection_items` / `in_collections` の変更もこの整理の一部。
- **none（capsicum 無関係）**: `config/routes/` の差分は `admin.rb` の 2 行のみ（管理画面）。`streaming/` は `package.json` の依存更新だけで**プロトコル不変**。`deprecation_concern` の変更は OpenTelemetry span 属性の付与で、`Deprecation` / `Sunset` ヘッダの形は不変。ActivityPub の完全性証明（`object_integrity_proof` / `multibase`）・FASP・annual_report は連合内部 / server 専用。
- **フォーク固有のオペ変更なし**: nginx / rc.d / モロヘイヤ連携（`X-Mulukhiya-Purpose` の map 等）に差分なし。[#121](https://github.com/pooza/capsicum/issues/121) の経路（4.6.5 で開通済み）は 4.7.0 でも維持されている。

実測（2026-08-21）: 美食丼 / デルムリン丼 / キュアスタ！の `/api/v2/instance` はいずれも `4.7.0`。

⚠ **この時点で書いた「モロヘイヤが 5.33.0 なので #121 はブロック中」は解消済み。**2026-09-01 に美食丼の `GET /mulukhiya/api/about` を引くと `package.version` は `5.35.0`（判定は `.config.features.<flag>` ではなく `.package.version`）。#121 の ALT 編集は **v1.60 で出荷済み**。プリセットで導線が出ないサーバーがあるのは fail-closed が効いている正常な状態で、条件の正本は `tech-notes.md`。

## 関連

- [#721](https://github.com/pooza/capsicum/issues/721) Mastodon 4.6 互換性確認（受動・closed）
- [#121](https://github.com/pooza/capsicum/issues/121) Mastodon の ALT 編集（v1.57・4.6.5-bshockdon の nginx 修正で経路が開通）
- 方針メモは memory `project_mastodon_46_posture`
