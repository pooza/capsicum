# Mastodon 4.6 capsicum 影響トリアージ

Mastodon 4.6（2026-06-18 GA）の新機能のうち、**capsicum（クライアント）に対応が必要なもの**を切り分けた一覧。

## なぜこの文書があるか

リリースノートは server / Web / admin / client の変更が混在し、散文からは「どれに capsicum 対応が要るか」が見えにくい。capsicum に効くのは**クライアントから見える API の変化だけ**（entity の新フィールド・新エンドポイント・パラメータ変更）なので、**フォークの API コードを直接 diff** して機械的に抽出する。

## 抽出方法（次バージョンでも再利用可）

capsicum の実接続先は美食丼フォーク（`pooza/mastodon`）。**リリースノートではなくフォークのタグ同士を diff** する（`~/repos/mastodon` で fetch 済みなら pull/checkout 不要）:

```bash
cd ~/repos/mastodon
OLD=v4.5.9-bshockdon; NEW=v4.6.0-bshockdon   # 次は v4.6.x-bshockdon → v4.7.0-bshockdon 等
# クライアントに効く entity フィールド
git diff $OLD..$NEW -- app/serializers/rest/
# 新規 entity / endpoint
git diff --name-status --diff-filter=A $OLD..$NEW -- app/serializers/rest/ app/controllers/api/
# 新規ルート
git diff $OLD..$NEW -- config/routes/api.rb
```

各項目を **none（server/web 専用・無関係）/ passive（additive で自動追従・無害）/ actionable（対応候補）** の3段でトリアージする。

## トリアージ結果（v4.5.9 → v4.6.0）

### 🔴 actionable（対応候補）

| API 変化 | 内容 | Issue |
|---|---|---|
| account `show_media` / `show_media_replies` / `show_featured` | プロフィールのタブ非表示設定への追従 | [#732](https://github.com/pooza/capsicum/issues/732)（v1.43） |
| **Collections 横断**: 新 `/api/v1/collections`(+items / context / in_collections / accounts/:id/collections) ・account `feature_approval` ・status `tagged_collections` ・search `collections` ・notification 新 `collection` type ・role `collection_limit` ・新 entity Collection / CollectionItem / CollectionWithAccounts / ShallowTag / PartialAccount | キュレーション共有（FEP-7aa9）。**単なる新エンドポイントでなく account / status / search / notification entity に染み出す横断変更** | [#722](https://github.com/pooza/capsicum/issues/722)（v1.43） |

### 🟡 actionable（小粒・additive な拾い物）

| API 変化 | 内容 | Issue |
|---|---|---|
| account `avatar_description` / `header_description` | アバター / ヘッダー画像の alt テキスト | [#733](https://github.com/pooza/capsicum/issues/733)（v1.43） |
| relationship `muting_expires_at` | ミュートの有効期限 | [#734](https://github.com/pooza/capsicum/issues/734)（v1.43） |
| custom_emoji `featured` | フィーチャー絵文字（カテゴリ） | [#735](https://github.com/pooza/capsicum/issues/735)（v1.43） |
| 新 `/api/v1/profile`(show / update, avatar / header destroy) + Profile entity | プロフィール編集 v2 専用エンドポイント。現状 `update_credentials` で動作するため移行は任意 | [#736](https://github.com/pooza/capsicum/issues/736)（v1.43） |

### ⚪ passive / none（対応不要）

- **passive（additive・自動追従/degrade 済み）**: notification `fallback` ＋未知 type → 既に `NotificationType.other` へ degrade（[#721](https://github.com/pooza/capsicum/issues/721) で確認）。status `contexts_controller` 新設・preview_card `missing_attribution`。
- **none（server / web / admin / 連合内部・capsicum 無関係）**: instance `wrapstodon`（年間まとめ）/ `/api/v1/donation_campaigns` / account `email_subscriptions` ＋ `/api/v1/accounts/:id/email_subscriptions` / `/api/v1/instance/terms_of_service` / annual_report・report・ip_block 系 / ActivityPub の feature・featured 連合 serializer 群。

## 関連

- [#721](https://github.com/pooza/capsicum/issues/721) Mastodon 4.6 互換性確認（受動・closed）
- 方針メモは memory `project_mastodon_46_posture`
