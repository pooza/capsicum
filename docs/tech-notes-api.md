# 技術的知見・落とし穴集 — サーバー API

[tech-notes.md](tech-notes.md) から分けた 1 本（#1184・2026-09-30）。**NodeInfo / Probing・Mastodon・Misskey・モロヘイヤの API で踏んだ罠**を置く。

⚠ **Dart / Flutter 側の実装の罠は [tech-notes.md](tech-notes.md)、ネイティブ / CI の罠は [tech-notes-native.md](tech-notes-native.md)。**行き先の表は tech-notes.md の冒頭にある。

⚠ **新バージョンの API 変更をトリアージする手順は別**（[mastodon-capsicum-api-watch.md](mastodon-capsicum-api-watch.md) / [misskey-capsicum-api-watch.md](misskey-capsicum-api-watch.md)）。⚠ **API にあって capsicum が使っていない機能の棚卸しも別**（[api-gap-inventory.md](api-gap-inventory.md)）。ここには**叩いてみて初めて分かった挙動**だけ置く。

## NodeInfo / Probing

### rel URL の判定

NodeInfo の rel URL は `http://nodeinfo.diaspora.software/ns/schema/2.0` 形式。判定は `contains('nodeinfo/2.')` ではなく `contains('/ns/schema/2.')` でマッチすること。前者は偽陽性を拾う。

## Mastodon API

### メディア ALT（description）は 2 ステップで送る

`POST /api/v1/media` の multipart リクエストに `description` を同梱しても、サーバー実装によっては保存されないことがある（モロヘイヤ経由で発生を確認済み、原因未特定）。WebUI と同じく、アップロード後に `PUT /api/v1/media/:id` で別途 `description` を設定する 2 ステップ方式を採用している。

### 投稿済み ALT の編集は美食丼ステージングの `~/alt_try.sh` で試す（#121）

⚠ **Mastodon の Web UI からは試せない。**Web UI は `X-Mulukhiya-Purpose` を付けないため、nginx 前段の `$status_put_backend` map が **405** で弾く（mulukhiya#4474）。「Web で編集できるのに capsicum でできない」ではなく、**Web からは元々できない**。

検証用の一式が**美食丼ステージング**（`st2.mstdn.b-shock.org`）の `mastodon` ホームに置いてある。**repo からは辿れないので、ここに場所を書いておく**（SSH の接続先ホスト名は chubo2 `docs/infra-servers.md` が正本）。

- `~/alt_try.sh <新しい ALT>` — capsicum と同じ経路（PUT `/api/v1/statuses/:id` + `X-Mulukhiya-Purpose: media_update` + `media_attributes` だけの body）で投げ、応答から ALT / 添付数 / CW / 閲覧注意 / 本文を並べて出す
- `~/.alt_try_token` — 実行用のアクセストークン
- `~/.alt_try_ids` — 1 行目が status id、2 行目が media id

⚠ **見るべきは HTTP 200 ではなく「送っていない項目が残ったか」。**この API は送らなかったパラメータを現状維持ではなく**空で更新**として扱うため、モロヘイヤの補完が効いていないと 200 のまま**添付が全部外れて CW と閲覧注意も消える**（mulukhiya#4589）。出力の「添付 = N 件 / CW / 閲覧注意」がその確認欄。

### ALT 編集の導線が出る条件は版番号ではなく 2 つの and（#121）

client 実装は v1.60 で出荷済みだが、導線は `GET /mulukhiya/api/about` の `config.features.media_update` が `true` のときだけ出る（fail-closed）。このフラグが立つには**両方**が要る:

✅ **2026-08-25 時点では両方とも成立済み**で、Mastodon 3 台は `true` を返す（Misskey 2 台は設計どおり `false`）。以下は条件の説明であって「出ない」の記録ではない。

1. モロヘイヤが刺している **`ginseng-fediverse` 1.8.30 以上**（mulukhiya#4621。モロヘイヤ 5.35.0 の主軸）
2. **各サーバーの `local.yaml` に `/mastodon/capabilities/media_update: true`** を書く opt-in（既定 `false`）

⚠ **5.35.0 の `/about` は同名フラグを 2 箇所に持つ。**`.config.features.media_update` と `.config.capabilities.media_update` の両方が返るが、**capsicum が読んでいるのは `features` の側**（`mulukhiya/service.dart` の `about()`）。切り分けで curl を叩くときにパスを取り違えない。

⚠ **モロヘイヤの版が上がるだけでは復活しない。**2 が既定 false なのは、nginx の `$status_put_backend` map が 3 要素キーへ是正済みかをモロヘイヤ側から観測できないため。⚠ **`package.version` からは 1 を区別できない**ので、版番号で判定せず必ずフラグを見る（`attachment_description_edit.dart` の doc も同じことを書いている）。デプロイ時は Mastodon 3 台に 2 の追記が要る（Misskey は常に false）。

### `GET /api/v2/notifications`（束ねた通知）の 4 つの罠（#1048 / #1042）

1. ⚠⚠ **`limit` は「通知の件数」に掛かるのに、返るのは「グループの件数」。**同じ投稿への 20 件のリアクションは `limit: 20` に対して 1 グループで返る。**`groups.length >= limit` で最終ページを判定すると、そこで読み止まる。**判定は「ページが空でなければ続きがありうる」にして、最終ページの次に空の 1 回が走るのを許容する（`NotificationResponse.hasMore`）。⚠ その代わり「カーソルが進まなかったら打ち切る」歯止めが要る（無いと、サーバーが同じページを返し続けたときにスクロールのたびに同じ通知が積まれる）
2. ⚠⚠ **次ページのカーソルは `page_min_id`。**`most_recent_notification_id` を `max_id` に渡すと、**末尾のグループの古いぶんを読み飛ばす**。`group_key` では辿れない（`max_id` / `since_id` は通知 ID を取る）
3. ⚠ **グループに `created_at` が無い。**時刻は `latest_page_notification_at` だけで、しかも `paginated?` が false のとき（`GET /api/v2/notifications/:group_key`）は来ない
4. ⚠ **`sample_account_ids` は同じ相手を複数回含みうる。**通知の `from_account_id` を新しい順に 8 件取ったものなので、フォロー → 解除 → 再フォローのように 1 人が複数の通知を作る種別では重複する。⚠ **`notifications_count` の方は畳まない**（本家 WebUI の「X and N others」も通知の件数を数えている）

⚠ **束ねる種別は Mastodon と Misskey で揃っていない。**Mastodon は `GROUPABLE_NOTIFICATION_TYPES = favourite / reblog / follow / admin.sign_up` を `group_key` で**履歴全体にわたって**束ねる。Misskey の `i/notifications-grouped` は `reaction` / `renote` を**1 ページ内の連続したものだけ**束ねる（`notifications-grouped.ts` のループは直前の通知しか見ない）。⚠ Misskey の `reaction:grouped` / `renote:grouped` は **`user` を持たない**（`reactions[].user` / `users[]` へ移る）。

⚠ **`:grouped` 付きの名前を送信用の型マップへ足さない。**あの表は `excludeTypes` に送る名前の正本でもあり、`reaction:grouped` は Misskey の `notificationTypes` enum に無いので **400 で一覧ごと落ちる**。

### `supported_types` を送っても未知の型が必ず読めるようになるわけではない（#1042）

`GET /api/v1|v2/notifications` に `supported_types[]` を送ると、サーバーは載っていない種別に `fallback: { title, summary }` を付けて返す。⚠ **送らないと `needs_fallback?` が `supported_notification_types.nil?` で即 false を返すので永久に来ない**——ここまでは #993 §9-3 のとおり。

⚠⚠ **ただし文言が入っているのは 6 種別だけ。**`NotificationFallbackConcern#fallback_title` が `case` で名前を持っているのは `severed_relationships` / `moderation_warning` / `admin.sign_up` / `admin.report` / `added_to_collection` / `collection_update`。**本当に新しい種別では `fallback` キーは来るのに `title` も `summary` も null。**さらに `PROPERTIES[type][:baseline]` が true の種別（`quote` / `quoted_update` / `annual_report` 等）には `fallback` 自体が来ない。

→ capsicum にとって実効があるのは **`admin.sign_up` / `admin.report`**（残り 4 つは既知）。**`NotificationType.other` の既定表示は受け皿として残す。**⚠ `fallback.title` / `summary` は **HTML**（`link_to` / `link_to_mention` を通る）。

### 429 に `Retry-After` は付かない。窓が明ける時刻は `X-RateLimit-Reset` だけが持つ（#1103）

⚠⚠ **Mastodon は 429 に `Retry-After` を付けない。**付くのは `X-RateLimit-Limit` / `-Remaining` / `-Reset`（**ISO 8601**）で、窓が明ける時刻を知る手段はこれだけ。⚠ モロヘイヤも **5.39.0〜 透過時にこの 3 本を中継する**（mulukhiya#4775）ので、経由してもしなくても同じ形で来る。

⚠ **読めていても、遅延の計算に使っていなければ意味が無い。**`RateLimitInterceptor` はヘッダを読んでいたのに `_calculateDelay` が `Retry-After` しか見ておらず、**分単位の窓に対して秒単位のバックオフ（合計 1〜7 秒）で 3 回打ち返して尽きていた**。現在の優先順は **`Retry-After` → `X-RateLimit-Reset` → 指数バックオフ**。

⚠ **窓が遠い（60 秒超）ときは待たずに諦める。**Mastodon の窓は 5 分なので、素直に待つと投稿ボタンが数分固まる。⚠⚠ **バックオフへ落とさない** —— 明けていないと分かっているところへ打ち返すのは無駄。

#### 🔴 `X-RateLimit-Reset` を `DateTime.tryParse` に素で通さない

⚠⚠ **`DateTime.tryParse('1790000000')` は null を返さない。**epoch 秒（GitHub 風）を返すサーバーの値が **compact ISO として「西暦 178999 年」に解釈される**（2026-10-01 実測）。

```text
1790000000     -> 178999-11-30 00:00:00.000   ← ⚠⚠ 17 万年後
1790000000000  -> null
2026-10-01T00:00:00Z -> 2026-10-01 00:00:00.000Z
```

そのまま信じると **先回りの待機が事実上永久に返らない**（`remaining` が閾値以下のとき `await Future.delayed(resetAt.difference(now))` に入る）。⚠ **レート制限の窓は長くても時間単位**なので、1 時間より先の値は読めなかったものとして捨てている。

### プロフィール編集の初期値

`GET /api/v1/accounts/verify_credentials` のトップレベル `note` は HTML 化済み。編集画面の初期値に使うと編集時に HTML タグが丸見えになる。`source.note` / `source.fields` を参照すること（プレーンテキストで返る）。

## Misskey API

### サーバーの挙動を推測で語らない — フォークのソースを引く

⚠⚠ **`~/repos/mastodon` / `~/repos/misskey` は運用中のサーバーソフトそのもの。**「送っていないから効かないはず」「送れば通るはず」の類は、**必ず該当の service / controller を開いて確かめる**。

v1.63 で実際に踏んだ（#1043）:

- **誤った前提**: 「Misskey の指名投稿は `visibleUserIds` を送らないと誰にも届かない」→ 公開範囲を `followersOnly` へ丸める実装を入れた
- **実際**: `NoteCreateService` は**返信のときだけ返信先の作者を `visibleUsers` へ自動補完する**ので、`visibleUserIds` を送らなくても**返信は正しく届いていた**
- **被害 1**: `reply.visibility === 'specified' && data.visibility !== 'specified'` は **400 で拒否**される。丸めた結果、**動いていた返信を確実に壊した**
- **被害 2**: redraft には返信関係が無いのでサーバーが弾かず、**DM がフォロワー全員へ出る**形になった（「見せたくないものが見えている」型）

⚠ **コードの見た目からは自然な推測でも、サーバーを読めば 5 分で否定できた。**ソースが手元にあるのに引かなかったのが原因。

同じ回で `notes/search` の `UNAVAILABLE` を「全文検索バックエンド未設定だから」と書いたのも誤り。実際は `RoleService` の **`canSearchNotes` が既定 false というロールポリシー**由来。⚠ **観測される挙動が同じでも、因果を推測で書かない。**

⚠ 逆に、**カーソルの正体（関係レコードの内部 id か、投稿 / User の id か）はソースを引いて全件確認したぶんは 1 件も外していない**。引けば当たる。

### MiAuth パーミッション

新しい Misskey API エンドポイントを利用する際は `MisskeyAdapter._permissions` リストに該当パーミッションを追加すること。追加漏れは 403 `PERMISSION_DENIED` になる。既存トークンには効かないため、ユーザーは再ログインが必要。v1.2 で `read:channels` / `write:channels` / `write:report-abuse` を追加した経緯がある。

エラー時は「権限がありません。再ログインが必要な場合があります」のようなメッセージを表示する。

#### UI で作れない投稿を API で用意する（検証素材の作り方）

指名投稿・特定の返信構造など、**クライアントの UI では作れない素材**は MiAuth でトークンを取って API で作る。⚠ **Misskey Web が未ログインでも、MiAuth の認可画面は保存済みアカウントを選べる**ので、ブラウザにセッションがあれば足りる。

1. `https://<host>/miauth/<任意の UUID>?permission=write:notes` をブラウザで開いて承認
2. `POST https://<host>/api/miauth/<同じ UUID>/check` でトークンが返る

⚠ debug 版のサーバー選択にはステージングのプリセットが並ぶので、本番に素材を作らない。

### `i/update` は空文字列禁止

フィールドをクリアしたい場合、空文字列 `""` は 400 エラー。JSON で明示的に `null` を送ること。キー省略は「変更なし」の意味になる。

### `sinceId` 単独指定は ASC（古い順）で返る — 下方向ページングが壊れる

Misskey 本家 `QueryService.makePaginationQuery` は **`sinceId` のみ → ASC（古い順）／`sinceId`+`untilId` → DESC／`untilId` のみ → DESC** で並べる。Mastodon は `since_id` 指定でも常に DESC のため挙動が違う。「最古 id を次ページの `maxId` にして下方向へ辿る」DESC 前提のページングを Misskey で `sinceId` 単独で回すと、1 ページ目だけ ASC になって最古側しか拾えず、新しい側を取りこぼす（v1.42 の live 復帰 catch-up #784 でこのバグを踏んだ）。**ギャップを新しい順で全件辿りたいときは `sinceId` を渡さず `maxId`（untilId）のみで DESC 取得し、下端の判定はクライアント側で行う**（`collectCatchUpGap` がこの方式）。両 SNS で DESC に揃うので分岐も消える。

### ピン留め投稿の取得

`/api/users/notes` の `pinned` パラメータは機能しない。`/api/users/show` レスポンスの `pinnedNotes` フィールドから取得すること。

### `users/report-abuse` の 500

通報受理時にサーバーが管理者へメール通知を試みる。SMTP 未設定のサーバーでは 500 Internal Error が返るが、これはサーバー側の問題であり capsicum 側の不具合ではない。

### `/api/sw/register` はサードパーティアプリから叩けない

Misskey upstream は [GHSA-7pxq-6xx9-xpgm](https://github.com/misskey-dev/misskey/security/advisories/GHSA-7pxq-6xx9-xpgm)（2023-12）で `/api/sw/register` に `secure: true` を適用しており、MiAuth / OAuth 由来のアクセストークンから叩くと HTTP **400** + `{error: {code: 'ACCESS_DENIED'}}` を返す。`secure: true` は「ブラウザのセッション Cookie（user あり + token なし）のみ許可」の意。

つまり capsicum に限らず **サードパーティアプリは Misskey の Web Push 登録を直接は行えない**。Misskey 純正アプリも `/api/sw/register` は使っておらず、Streaming API 経由の in-app 通知で代替している。

[MisskeyAdapter.subscribePush](../packages/capsicum_backends/lib/src/misskey/adapter.dart) はこの 400 を [PushRegistrationNotSupportedException](../packages/capsicum_core/lib/src/social/interfaces/push_subscription_support.dart) に詰め替え、[PushRegistrationService](../packages/capsicum/lib/src/service/push_registration_service.dart) 側は Sentry への送信をスキップする（再試行しても成功しない仕様制約で、ノイズになるため）。リレー登録のロールバックは通常ルートで実施する。

自前サーバー（ダイスキー等）向けの回避策としては、モロヘイヤにプロキシエンドポイントを生やす or フォークでガードを緩める等の選択肢がある（[#352](https://github.com/pooza/capsicum/issues/352) の follow-up 参照）。

### Play（スロット系）の出目に関する 3 つの現象を混同しない（#896 / #898）

「Play の出目がおかしい」の報告は**別物が 3 つ**あり、混ぜて再調査すると必ず迷子になる。⚠ **`String.hashCode` は JIT・AOT・別プロセスで不変**なので、「プロセスごとに乱数がランダム化される」という説明は**誤り**。ここは何度も疑われるが決着済み。

| # | 現象 | 正体 | 扱い |
| --- | --- | --- | --- |
| 1 | **Web と出目が違う** | engine の忠実度。Misskey 側は seedrandom（RC4 系）で、capsicum の `Math:gen_rng` は当初 `dart:math` の `Random(seed.hashCode)` だった | ✅ [#896](https://github.com/pooza/capsicum/issues/896)（v1.55）で **seedrandom 互換にした**。⚠ **いま食い違うのは、宣言バージョンが 1.0 以上の Play を「このまま実行する」で動かしたときだけ**（本家は 1.x の実行系へ振り分け、乱数が chacha20 になる）。宣言なし / 1.0 未満は一致する |
| 2 | **同じ日でも朝と夕で変わる** | **絵文字インベントリ依存の仕様**（下記） | [#898](https://github.com/pooza/capsicum/issues/898) で決着。**再調査不要** |
| 3 | **特定キャラが出やすい** | Play スクリプト（ユーザースクリプト）側の seed / 選択バイアス | **作者側の話で capsicum の対象外**。engine の初手分布は実測で有意な偏りなし |

2 の機序: スロット系スクリプトのプール構築が `CUSTOM_EMOJIS.filter(cat).map(@(e){random(0 100000)})` の形をしており、**対象カテゴリの絵文字 1 個につきシード付き乱数を 1 回消費する**。したがって件数・順序が変われば PRNG の位置がズレて出目が全変化する（**±1 絵文字で別結果**を実測）。トリガーは**対象カテゴリの非 ignore 絵文字の add / remove / rename だけ**（他カテゴリの追加は `.filter` で落ちるので無影響）。

Web で問題にならないのは、Misskey フロントが絵文字リストを IndexedDB に persist して `fetchCustomEmojis` を throttle しており**プールが凍結される**ため。capsicum は `/api/emojis` をコールドスタートごとに引き直すので、インベントリ変化を即拾う（モバイルは cold start が多く表面化しやすい）。⚠ **凍結すると Web と挙動が変わる**ので、同日変動は仕様として扱う。

⚠ **1 で照合すべき Misskey 側の実装は 1.2.1 ではなく 0.19.0。**Misskey は Play の宣言バージョンで legacy 判定して `@syuilo/aiscript-0-19-0` を動的 import する。capsicum は `/// @1.0.0` 以上を実行せずブラウザへ逃がす（#881 の gate）ので、**capsicum が実行する Play の Web 側実行系は常に 0.19.0** になる。現行 1.2.1 の `CryptoGen` / chacha20 は capsicum が実行しない領域の話。

## モロヘイヤ API

### 機能フラグは `.config.features` 配下にある（top-level `.features` ではない）

モロヘイヤ `GET /mulukhiya/api/about` の機能フラグ（`annict` / `word_suggest` / `media_catalog` / `program_editable` / `annict_linked` 等）は、**top-level の `features` ではなく `config.features` の下**にある。サーバー実装は `api_controller.rb` の `about[:config][:features] = about[:config][:features].merge(DynamicFeatures.new(sns).to_h)`。

判定するときは必ず `.config.features.<flag>` を見ること。top-level `.features` を見ると常に空に見えて「フラグが返っていない」と誤判定する。

動的フラグは `DynamicFeatures::REGISTRY` で導出される。例: `word_suggest => PronunciationDictionary.enabled?`（＝ `word_suggest/urls` 設定の有無）。capsicum 側はこのフラグで UI を出し分ける（モロヘイヤは外部 API の癖を吸収して正規化するプロキシで、capsicum は単純なフラグ判定だけを行う方針）。
