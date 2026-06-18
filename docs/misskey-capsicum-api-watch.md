# Misskey API watch（capsicum 影響トリアージ）

Misskey の新バージョンで **capsicum（クライアント）に対応が必要な API 変化**を切り分ける運用。Mastodon 版（`mastodon-46-capsicum-triage.md`）の Misskey 版にあたる。

## なぜこの文書があるか

リリースノートでは client 影響が見えにくいので、capsicum の実接続先である **ダイスキーのフォーク（`pooza/misskey`・`daisskey` ブランチ）の API コードを直接 diff** して機械抽出する。Misskey は API 契約が自動生成されているため、Mastodon より抽出が楽。

## 抽出方法

```bash
cd ~/repos/misskey
git fetch origin --quiet
OLD=<前回トリアージで記録した daisskey SHA>; NEW=daisskey

# ① 集約 API 契約（これだけで entity フィールド + endpoint の変化を一網打尽）
git diff $OLD..$NEW -- packages/misskey-js/src/autogen/entities.ts packages/misskey-js/src/autogen/endpoint.ts

# ② 裏取り: entity packed schema / 新規エンドポイント
git diff --stat $OLD..$NEW -- packages/backend/src/models/json-schema/
git diff --name-status --diff-filter=A $OLD..$NEW -- packages/backend/src/server/api/endpoints/
```

各項目を **none（server/web/連合内部・無関係）/ passive（probing で自動 degrade・対応不要）/ actionable（対応候補）** の3段で判定。capsicum の Misskey 連携は probing ベースなので passive 比率が高め。

## アンカーの取り方（Mastodon との重要な差）

Mastodon は 4.5→4.6 の **GA タグ**が明快な節目だが、Misskey は:

- 「`X.0-alpha.0` へ Bump」commit が**そのマイナーの“終点”**（feature が出揃ってからリリース切り出し時に打つ）。しかも alpha/beta が多段。
- → **バージョン bump commit をアンカーにすると境界が曖昧**。

このため **「前回トリアージした時点の daisskey commit SHA」を本ファイルに記録し、次回は `記録SHA..daisskey` で差分する**。頻度はマイナー（月次）ごとを目安にしつつ、境界はこの SHA で管理する。

## トリアージ履歴

### baseline: `fe064da6`（2026.5.4+0、2026-06-18 記録）

初回トリアージ。`7c9942f0`（2026.5.0-alpha.0）..`fe064da6`（2026.5.4）の範囲を確認:

- **`following/list`（新規 endpoint）** — `read:following`、自分のフォロー一覧を Following entity で返す。判定 **⚪ passive**: capsicum は既存のフォロー一覧取得で代替済み。additive な便利版のため起票なし。

→ actionable なし。**次回は `fe064da6..daisskey` から差分する**。

## 関連

- `docs/mastodon-46-capsicum-triage.md`（Mastodon 版）
- インフラ正本は memory `reference_server_forks`（`~/repos/misskey` = ダイスキー本番のフォーク本体）
