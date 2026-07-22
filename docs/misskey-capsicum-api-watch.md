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

# ③ AiScript のバージョンが動いたか（#830 Flash のトリガー）
git diff $OLD..$NEW -- packages/frontend/package.json | grep -i aiscript
```

各項目を **none（server/web/連合内部・無関係）/ passive（probing で自動 degrade・対応不要）/ actionable（対応候補）** の3段で判定。capsicum の Misskey 連携は probing ベースなので passive 比率が高め。

## Flash / AiScript の互換確認（#830）

**①② の API 契約 diff では AiScript の変化を検知できない。** AiScript は API 契約ではないため、`@syuilo/aiscript` が上がって新構文が入っても `autogen/entities.ts` も `endpoint.ts` も 1 行も動かない。capsicum は Flash をネイティブ実行する（評価器は [pooza/aiscript-dart](https://github.com/pooza/aiscript-dart) フォーク）ので、ここは別途、実測で埋める。

```sh
cd ~/repos/capsicum/packages/capsicum
dart run tool/flash_compat_check.dart
```

プリセットサーバーの Flash を取得し、**capsicum が本番で使う `FlashRuntime` そのもの**でパース・実行する。失敗は実際のユーザーが見るのと同じ文言で出る:

| 出力 | 意味と対応 |
| --- | --- |
| この Play を読み込めませんでした | パース失敗。AiScript の言語側が前進した → フォークの追従が必要 |
| この Play が使う機能に capsicum が未対応です | `Ui:` / `Mk:` のバインディング層に実装を足す（未実装の識別子が併記される） |
| この Play の実行でエラーが起きました | 評価器の非互換か、ホスト供給変数の不足。個別に調査 |

最後に、実際に描画されたコンポーネント種別が出る。バインディング層のスコープ確認に使う。

**ハーネスに `Ui:` のスタブを書かないこと。** 本番の `FlashRuntime` と二重管理になり、片方だけ直したときに互換確認が嘘をつく。そのために `FlashRuntime` は Flutter に依存させず、素の `dart run` から駆動できるようにしてある。

**上の ③ で `@syuilo/aiscript` のバージョンが動いていたら、必ずこれを回す。** 動いていなくても、フォークの ref を上げたときは回す。

### スコープ（意図的な限定）

- **プリセットサーバー以外の Flash は対象外。** capsicum が動作を保証するのはプリセットサーバーの利用者に対してであり、未知のサーバーの Flash まで互換性を追う意図はない
- **母数は各サーバーの featured Flash のみ。** 全 Flash を列挙できる未認証 API が存在しない（`/api/flash/my` は認証必須、`/api/flash/search` はクエリ必須）ため。「6/6 pass」は「featured が全部通った」の意であって網羅ではない
- 検体の取得元は `tool/flash_compat_check.dart` の `_hosts`。**プリセットに Misskey サーバーが増えたらここにも足す**（`lib/src/preset_servers.dart` が正本）

### 既知の限界（過信しないこと）

capsicum の評価器は **AiScript 0.16 世代**で、本家現行の 1.2.x より**構文が緩い**。このため:

- **「通った」は「本家と同じ結果になった」を意味しない。** ハーネスは実行が完走したかを見るだけで、出力の一致は検証していない。1.0 では**演算子の優先順位が変更**されており、0.16 で評価すると*エラーにならずに答えだけ変わる*ケースがありうる
- 1.x で追加された構文（`while` / `do-while`、`match` の `case` / `default`、`num#to_hex` 等）を使う Flash は**パース失敗として顕在化する**（こちらは silent ではない）
- 逆方向は安全。0.16 は 1.0 で禁止された「配列の空白区切り」等を許容するため、旧構文の Flash も動く

### トリアージ履歴への記録

各回のトリアージで、daisskey SHA に加えて **確認時点の `@syuilo/aiscript` バージョン**と**ハーネスの結果**を記録する（`harness-verified-versions.yaml` の作法にならい、専用の cron は持たずセッション同期に組み込む）。

## アンカーの取り方（Mastodon との重要な差）

Mastodon は 4.5→4.6 の **GA タグ**が明快な節目だが、Misskey は:

- 「`X.0-alpha.0` へ Bump」commit が**そのマイナーの“終点”**（feature が出揃ってからリリース切り出し時に打つ）。しかも alpha/beta が多段。
- → **バージョン bump commit をアンカーにすると境界が曖昧**。

このため **「前回トリアージした時点の daisskey commit SHA」を本ファイルに記録し、次回は `記録SHA..daisskey` で差分する**。頻度はマイナー（月次）ごとを目安にしつつ、境界はこの SHA で管理する。

## トリアージ履歴

### 2026.6.0 は未トリアージ（2026-07-22 記録・pending）

daisskey が 2026.5.4（`fe064da6`）→ **2026.6.0** に bump 済み。**次回同期で `fe064da6..daisskey` の差分トリアージ（①②③）＋ Flash 互換ハーネスを回す**。v1.50 のユーザー報告（Play スロット描画 #876 / いいね scope #877 / 下書き 400 #879）はこの diff 無しで説明済み（`notes/drafts/create`・`flash/like`・`flash/unlike` は baseline から無変更）だが、2026.6 全体の差分は未確認。

### Flash 互換 baseline: `@syuilo/aiscript` 1.2.1（2026-07-20 記録）

`tool/flash_compat_check.dart` の初回実行。**6 / 6 pass**（ダイスキー 4 + きゅあすきー 2 の featured 全数）。

- 実際に使われている `Ui:C:*` は **container / mfm / postFormButton の 3 つだけ**。`Mk:api` の呼び出しはゼロ
- ホスト供給変数は `CUSTOM_EMOJIS` / `THIS_ID` / `THIS_URL` 程度
- 検体には**言語バージョンの新旧が混在**している。ダイスキーの「ろぐぼチャレンジ(ダイ大版)」と「同 II」は、配列リテラルが空白区切り（1.0 で禁止された旧構文）かカンマ区切りかだけが違う姉妹版で、**0.16 世代の評価器は両方通す**。前者は作者が deprecated としているが、コーパス中で唯一 pre-1.0 構文を踏む検体でもある（サーバー側で featured から外れると、この網が静かに消える点に注意）

### baseline: `fe064da6`（2026.5.4+0、2026-06-18 記録）

初回トリアージ。`7c9942f0`（2026.5.0-alpha.0）..`fe064da6`（2026.5.4）の範囲を確認:

- **`following/list`（新規 endpoint）** — `read:following`、自分のフォロー一覧を Following entity で返す。判定 **⚪ passive**: capsicum は既存のフォロー一覧取得で代替済み。additive な便利版のため起票なし。

→ actionable なし。**次回は `fe064da6..daisskey` から差分する**。

## 関連

- `docs/mastodon-46-capsicum-triage.md`（Mastodon 版）
- インフラ正本は memory `reference_server_forks`（`~/repos/misskey` = ダイスキー本番のフォーク本体）
