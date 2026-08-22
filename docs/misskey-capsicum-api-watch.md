# Misskey API watch（capsicum 影響トリアージ）

Misskey の新バージョンで **capsicum（クライアント）に対応が必要な API 変化**を切り分ける運用。Mastodon 版（[mastodon-capsicum-api-watch.md](mastodon-capsicum-api-watch.md)）の Misskey 版にあたる。

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

### 互換性の基準（何を保証し、何を保証しないか）

**「本家 WebUI と厳密に同じ動作」は要件として追わない。** capsicum の評価器は **AiScript 0.16 世代**で、本家現行の 1.2.x に追いついていないため、厳密一致は原理的に達成できない。目標は **capsicum 単体で Play が正常に動くこと**（結果として WebUI と概ね同じように振る舞うと言える水準）に置く。

この前提で、ハーネスが「通った」と言っているのは以下の意味になる:

- **保証する = 完走すること。** ハーネスは実行が完走したかを見る。これは弱点ではなく**意図した検証範囲**である
- **保証しない = 出力が本家と一致すること。** 1.0 では**演算子の優先順位が変更**されており、0.16 で評価すると*エラーにならずに答えだけ変わる*ケースがありうる。ここは基準外として諦める（下の gate で silent 化だけは防いでいる）
- 逆方向は安全。0.16 は 1.0 で禁止された「配列の空白区切り」等を許容するため、旧構文の Flash も動く

**1.x 構文のパース失敗は、厳密には上の基準から外れる。** 1.x で追加された構文（`while` / `do-while`、`match` の `case` / `default`、`num#to_hex` 等）を使う Flash は「この Play を読み込めませんでした」として顕在化し、capsicum 単体で正常動作していない状態にあたる。ただし **現状は許容する**（2026-08-01 判断）— このメッセージは既にユーザーへ提示済みであり、かつ「読めなかった」という情報として無意味ではないため。silent に嘘の結果を出すより望ましい。

**基準の見直しトリガーは `aiscript-dart` が最新 AiScript に追従したとき。** ただし upstream の [LeadRDRK/aiscript-dart](https://github.com/LeadRDRK/aiscript-dart) は **最終コミットが 2023-09-22**（v0.6.0 / `Core:v` 0.16.0）で以後停止しており、追従の見込みは薄い（2026-08-01 確認）。自前で 0.16 → 1.2 を埋めるのは評価器の作り直しに近い規模になるため、当面は下の gate を維持する運用とする。

**silent 差異への gate（#881, v1.52）**: 上記「優先順位変化で silent に別結果」を踏まないよう、Play 実行前に**宣言 AiScript バージョンを見て gate する**。スクリプト先頭の `/// @<version>` 注釈（`Parser.getLangVersion`）が **1.0.0 以上**なら、本家の legacy/modern 振り分け（本家は 1.0.0 未満・宣言なしを legacy 実行系に回す）に倣って capsicum は評価せず「ブラウザで開く」へ degrade する（`FlashRuntime.isScriptLangUnsupported` → `flash_view_screen.dart` の `_start`）。宣言なし・0.x・解釈不能な書式は従来どおり 0.16 相当で実行する（正当な旧 Play を誤ってブロックしない）。degrade は仕様どおりの分岐であり失敗ではないので Sentry には流さない。featured 6/6 は現状 1.0.0 未満のため実際には踏まない見込み。

### トリアージ履歴への記録

各回のトリアージで、daisskey SHA に加えて **確認時点の `@syuilo/aiscript` バージョン**と**ハーネスの結果**を記録する（`harness-verified-versions.yaml` の作法にならい、専用の cron は持たずセッション同期に組み込む）。

## アンカーの取り方（Mastodon との重要な差）

Mastodon は 4.5→4.6 の **GA タグ**が明快な節目だが、Misskey は:

- 「`X.0-alpha.0` へ Bump」commit が**そのマイナーの“終点”**（feature が出揃ってからリリース切り出し時に打つ）。しかも alpha/beta が多段。
- → **バージョン bump commit をアンカーにすると境界が曖昧**。

このため **「前回トリアージした時点の daisskey commit SHA」を本ファイルに記録し、次回は `記録SHA..daisskey` で差分する**。頻度はマイナー（月次）ごとを目安にしつつ、境界はこの SHA で管理する。

### 本番適用の間合い（triage を焦らない根拠）

daisskey（ダイスキー本番のフォーク本体）への**本番適用**は、**Misskey リリースの安定性を用心して、リリースの 2〜3 日後や直近の週末に上げることが多い**（最近は安定しているが慣習として）。**これは準備不足による遅れではなく、あえて本番投入を遅らせる運用判断**である点に注意。**準備（ステージング適用）はむしろ早く回しており、その気なら当日適用も可能**。

そのため beta は本番より先に手元へ来ている。ステージング適用中の beta は **`origin/merge/<version>-beta.N`** ブランチとして fetch できる（例: `origin/merge/2026.7.0-beta.1`）。**API 契約の diff（①②）は本番昇格を待たずにこの ref から前倒しで回せる**（`<記録SHA>..origin/merge/<version>-beta.N`）。前倒しトリアージの狙いは、Mastodon 同様「本番昇格より前に actionable な API 変更を潰しておく」こと。

一方 **Flash 互換ハーネスは preset の本番サーバーを叩く**ため、beta の Flash 挙動まではカバーしない。ハーネスは daisskey 昇格後に回すのが確実。

**ステージング（dev27 = `st2.misskey.delmulin.com`）に Play を置いてもハーネスの前倒しにはならない**（2026-08-01 確認）。理由は 2 段階ある。

1. **現状は検体ゼロ。** API 自体には到達でき `api/meta` はステージング側の新バージョンを返すが、連合隔離でコンテンツを持たないため `api/flash/featured` が 0 件になる。しかも featured の条件は `likedCount > 0` かつ `visibility = public`（`FlashService.featured`）なので、Play を複製するだけでは載らず**いいねを 1 つ以上つける**必要がある。
2. **仮に複製しても結果が変わらない。** ハーネスが検証しているのは **Play スクリプトそのもの**であって、サーバーのバージョンではない。取得した AiScript をローカルの `FlashRuntime` で実行するだけで、サーバー側の実行系は一切関与しない。ステージングに本番と同じ Play を置けば、**本番で回したのと同じ結果が出るだけ**である。

したがってステージングで前倒しできるのは **API 契約の diff（①②）まで**。**③ で `@syuilo/aiscript` の据え置きを確認できていれば、ハーネスは本番昇格の前後どちらで回しても同じ**と考えてよい。

サーバーの AiScript が上がったときに動くのも、評価器そのものではなく **gate の側**である。上がった結果として新構文の Play が新規に書かれても、`/// @1.0.0` 以上を宣言していれば gate がブラウザへ逃がすため、capsicum 単体としては正常動作のままになる（[互換性の基準](#互換性の基準何を保証し何を保証しないか)）。**追従の圧力は「評価器を最新に上げること」ではなく「gate が正しく効くこと」に掛かる**。

ただしステージングに検体を固定する運用には別の価値がある — 本番の featured は**いいね数の変動で入れ替わりうる**ため、下の「Flash 互換 baseline」に書いたとおり pre-1.0 構文の検体が静かに消えることがある。これを防ぎたい場合は、ステージングではなく**ハーネス側に flash ID の直接指定経路を足す**方が確実（`flash/show` は `requireCredential: false` なので未認証で引ける）。

ノード名とホスト名の対応は infra-note（`~/repos/chubo2/docs/infra-note.md`）が正本。Play の動作保証範囲はプリセットの Misskey 2 サーバー（ダイスキー / きゅあすきー）。

判定の既定は保守的に **daisskey（本番）を diff の相手**とし、triage が due になるのは daisskey が動いたとき。前倒しは「やる価値がある版のとき」に beta ref で任意に実施する。

対して **Mastodon（美食丼ほか）はリリース当日〜遅くとも翌日に本番適用**する運用（[project_mastodon_46_posture] メモリの「pooza は本番をリリース日に必ずデプロイする」に対応）。Mastodon は本番投入そのものが早い／Misskey は準備は早いが本番投入を用心して遅らせる、という**運用スタイルの差**であって、どちらも「本家 GA より前に互換の目星をつけておける」点は共通。

## トリアージ履歴

### baseline: `9d6b7d05de`（2026.7.0、2026-08-01 記録）

`589d4ece`（2026.6.0）..`daisskey`（2026.7.0+0）の差分トリアージ。**beta.1 の先読み時点から追加はなく、GA の内容は先読みと同一**だった。

- **`admin/unset-mfa`（新規 endpoint）** — 判定 **none**: 管理者がユーザーの MFA を解除する admin API。capsicum は無関係。beta.1 で先読み済み。
- entity の変化は `AdminUnsetMfaRequest` の型 export 1 行のみ（上記 endpoint に付随）・packed json-schema 変化なし・`@syuilo/aiscript` は 1.2.1 で据え置き。

Flash 互換ハーネス: **6 / 6 pass**（ダイスキー 4 + きゅあすきー 2）。描画コンポーネントは container / mfm / postFormButton で baseline から不変。**ただし実行時点のプリセット本番は 2026.6.0**だった。`@syuilo/aiscript` が据え置きで **Flash の言語世代が動く圧力がない**ため、昇格後の再実施は不要と判断する。**ダイスキー本番は 2026-08-07 の同期で `2026.7.0+0` への昇格を確認済み**（判断どおりハーネスは再実施していない）。

→ actionable なし。**API 契約側は 2026.7.0 の本番適用をそのまま通してよい**。次回は `9d6b7d05de..daisskey` から差分する。

### 前倒し: `2026.7.0-beta.1`（ステージング先読み・2026-07-22 記録）

本番昇格を待たず、ステージング適用中の beta を `589d4ece`（本番 2026.6.0）..`origin/merge/2026.7.0-beta.1` で先読み。**先読みなので基準アンカーは `589d4ece` のまま据え置き**（次回の本番 diff の相手は引き続き daisskey）。

- **`admin/unset-mfa`（新規 endpoint）** — 判定 **none**: 管理者がユーザーの MFA を解除する admin API。capsicum は無関係。
- entity フィールド変化なし・packed json-schema 変化なし・`@syuilo/aiscript` は 1.2.1 据え置き。
- Flash 互換ハーネスは preset 本番サーバー（2026.6.0）依存のため beta 分は未実施。daisskey が 2026.7 に昇格したら回す。

→ **beta.1 時点で actionable なし**。ただし beta.1 は途中段階のため GA までに追加が入りうる。**daisskey が 2026.7 に昇格したら `589d4ece..daisskey` で再確認**（前倒しは昇格判断を早めるための下見であって、確定 triage の代替ではない）。

### baseline: `589d4ece`（2026.6.0、2026-07-22 記録）

`fe064da6`（2026.5.4）..`589d4ece`（2026.6.0）の差分トリアージ。**endpoint 3 本追加のみ・entity フィールド変化なし・packed json-schema 変化なし・`@syuilo/aiscript` は 1.2.1 で据え置き**。

- **`admin/queue/pause` / `admin/queue/resume`（新規 endpoint）** — 判定 **none**: サーバー管理者用のジョブキュー操作。capsicum は無関係。
- **`antennas/remove-note`（新規 endpoint）** — 判定 **⚪ passive**: アンテナのタイムラインから個別ノートを外す additive な操作。capsicum はアンテナ TL を読むのみで、この除去導線は未提供でも degrade 不要（probing で自動的に非提供）。将来のエンハンス候補にとどめ起票なし。

Flash 互換ハーネス（`@syuilo/aiscript` 1.2.1 据え置き）: **6 / 6 pass**（ダイスキー 4 + きゅあすきー 2 の featured 全数）。描画コンポーネントは container / mfm / postFormButton で baseline から不変。

v1.50 のユーザー報告（Play スロット描画 #876 / いいね scope #877 / 下書き 400 #879）は、いずれもこの diff とは無関係（`notes/drafts/create`・`flash/like`・`flash/unlike` は baseline から無変更）であることを再確認。

→ actionable なし。**次回は `589d4ece..daisskey` から差分する**。

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

- `docs/mastodon-capsicum-api-watch.md`（Mastodon 版）
- インフラ正本は memory `reference_server_forks`（`~/repos/misskey` = ダイスキー本番のフォーク本体）
