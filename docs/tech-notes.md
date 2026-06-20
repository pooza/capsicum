# 技術的知見・落とし穴集

実装中に発見した Flutter / Dart / 各種 API の落とし穴と回避策。コードコメントに残すほどではないが、失うと同じ地雷を踏む知見を集約する。

## Dart / Flutter 一般

### `firstWhere + orElse: () => null` は避ける

`List<dynamic>.firstWhere` に `orElse: () => null` を渡す書き方は型安全でないため、手動 for ループに置換する方が安全。

### `WidgetSpan` 内で `width: double.infinity` は使わない

親 `Text` の制約を超えるレイアウトエラーになる。自然幅（指定なし）で組むこと。

### `Image.network` には `errorBuilder` を付ける

アバター読み込み失敗時（Misskey proxy の 404 等）にバツ印のプレースホルダが出てしまう。`errorBuilder` で必ずフォールバック UI を用意する。

### PostTile の iPad オーバーフロー問題

`Row + Expanded` 構成は iPad の広い画面で `RenderFlex overflow` を原因不明のまま起こすことがある。`Stack + Padding(left: 52) + Positioned` で回避した（v0.3.0）。同様の問題を見たら同じ方針で。

### `go_router` の値受け渡し

`context.push<T>('/route')` + `context.pop(result)` を使う。`Navigator.pop(context, result)` では `go_router` が戻り値を握りつぶす。`showGeneralDialog` のコールバック方式もリビルドで消失するため不可。

### MFM リンク記法の URL 抽出

MFM のリンク記法 `[text](URL)` は、現状の正規表現ベースの URL 抽出だと末尾の `)` が URL の一部として誤認識される。MFM パーサー実装時にこの問題も解消すること。

## 認証フロー

### `flutter_web_auth_2` が Android エミュレータで不安定

`CallbackActivity` 方式でカスタムスキーム (`capsicum://oauth`) を受けるが、Android エミュレータで安定して動作しない。`url_launcher` + OOB（手動コード入力）フォールバックで代替している（[login-troubleshooting.md](login-troubleshooting.md) も参照）。

### デバッグ APK の手動インストール

`flutter build apk --debug` → `adb install` で実機・エミュレータにデバッグ APK を直接導入可能。Flutter の run 経由だと起動できない状況（署名・権限問題等）の切り分けに使える。

### `flutter_secure_storage` の accessibility 変更は既存 Keychain item を取りこぼす

macOS / iOS 実装は `baseQuery` に **必ず `kSecAttrAccessible` を含める**（`read` / `readAll` / `containsKey` / `delete` すべて）。そのため `MacOsOptions` / `IOSOptions(accessibility: ...)` を後から変更すると、**旧 accessibility で書かれた既存 item が新設定からは見えず・消せず・更新できない**。具体的な壊れ方（#643、内部ベータ実機で実証）:

- `write`: `containsKey(新)` が旧 item を検出できず `SecItemAdd` に進み、同一 account/service が既存のため **-25299 (errSecDuplicateItem)**。ログイン成功直後の `saveAccount` で発火して「ログインに失敗しました」になる。
- `delete(新)`: 旧 item にマッチせず no-op。単純な delete+retry でも直らない。
- `readAll(新)`: 旧 item を返さないため、read → delete → re-write 型の migration が**空振り**し、flag だけ立って「移行済み」を詐称する。

対処: 旧 item を列挙・削除する際は **旧 accessibility を per-call options で明示**する（#643 以前の既定は `KeychainAccessibility.unlocked` = `WhenUnlocked`）。migration の `readAll` / `delete` と write リカバリの delete に旧 options を渡し、空振りしていた migration を全員に再実行させるため flag key も `_v2` 等に上げる。`PushKeyStore.migrateAccessibilityIfNeeded`（#392 / #656）も同型実装。なお debug（macOS は sandbox off）では再現せず、内部ベータ実機 + Sentry breadcrumb でしか追えない。

派生注意: 移行で旧 item が「読めるようになる」と、そこに残っていた **stale な値が再利用される**副作用がある。capsicum では古い `client_creds`（`capsicum://oauth` era 登録）が localhost redirect_uri で `invalid_redirect_uri` を招いた。client_creds に redirect_uri を併記し一致時のみ再利用する形で解消。

## NodeInfo / Probing

### rel URL の判定

NodeInfo の rel URL は `http://nodeinfo.diaspora.software/ns/schema/2.0` 形式。判定は `contains('nodeinfo/2.')` ではなく `contains('/ns/schema/2.')` でマッチすること。前者は偽陽性を拾う。

## Mastodon API

### メディア ALT（description）は 2 ステップで送る

`POST /api/v1/media` の multipart リクエストに `description` を同梱しても、サーバー実装によっては保存されないことがある（モロヘイヤ経由で発生を確認済み、原因未特定）。WebUI と同じく、アップロード後に `PUT /api/v1/media/:id` で別途 `description` を設定する 2 ステップ方式を採用している。

### プロフィール編集の初期値

`GET /api/v1/accounts/verify_credentials` のトップレベル `note` は HTML 化済み。編集画面の初期値に使うと編集時に HTML タグが丸見えになる。`source.note` / `source.fields` を参照すること（プレーンテキストで返る）。

## Misskey API

### MiAuth パーミッション

新しい Misskey API エンドポイントを利用する際は `MisskeyAdapter._permissions` リストに該当パーミッションを追加すること。追加漏れは 403 `PERMISSION_DENIED` になる。既存トークンには効かないため、ユーザーは再ログインが必要。v1.2 で `read:channels` / `write:channels` / `write:report-abuse` を追加した経緯がある。

エラー時は「権限がありません。再ログインが必要な場合があります」のようなメッセージを表示する。

### `i/update` は空文字列禁止

フィールドをクリアしたい場合、空文字列 `""` は 400 エラー。JSON で明示的に `null` を送ること。キー省略は「変更なし」の意味になる。

### ピン留め投稿の取得

`/api/users/notes` の `pinned` パラメータは機能しない。`/api/users/show` レスポンスの `pinnedNotes` フィールドから取得すること。

### `users/report-abuse` の 500

通報受理時にサーバーが管理者へメール通知を試みる。SMTP 未設定のサーバーでは 500 Internal Error が返るが、これはサーバー側の問題であり capsicum 側の不具合ではない。

### `/api/sw/register` はサードパーティアプリから叩けない

Misskey upstream は [GHSA-7pxq-6xx9-xpgm](https://github.com/misskey-dev/misskey/security/advisories/GHSA-7pxq-6xx9-xpgm)（2023-12）で `/api/sw/register` に `secure: true` を適用しており、MiAuth / OAuth 由来のアクセストークンから叩くと HTTP **400** + `{error: {code: 'ACCESS_DENIED'}}` を返す。`secure: true` は「ブラウザのセッション Cookie（user あり + token なし）のみ許可」の意。

つまり capsicum に限らず **サードパーティアプリは Misskey の Web Push 登録を直接は行えない**。Misskey 純正アプリも `/api/sw/register` は使っておらず、Streaming API 経由の in-app 通知で代替している。

[MisskeyAdapter.subscribePush](../packages/capsicum_backends/lib/src/misskey/adapter.dart) はこの 400 を [PushRegistrationNotSupportedException](../packages/capsicum_core/lib/src/social/interfaces/push_subscription_support.dart) に詰め替え、[PushRegistrationService](../packages/capsicum/lib/src/service/push_registration_service.dart) 側は Sentry への送信をスキップする（再試行しても成功しない仕様制約で、ノイズになるため）。リレー登録のロールバックは通常ルートで実施する。

自前サーバー（ダイスキー等）向けの回避策としては、モロヘイヤにプロキシエンドポイントを生やす or フォークでガードを緩める等の選択肢がある（[#352](https://github.com/pooza/capsicum/issues/352) の follow-up 参照）。

## モロヘイヤ API

### 機能フラグは `.config.features` 配下にある（top-level `.features` ではない）

モロヘイヤ `GET /mulukhiya/api/about` の機能フラグ（`annict` / `word_suggest` / `media_catalog` / `program_editable` / `annict_linked` 等）は、**top-level の `features` ではなく `config.features` の下**にある。サーバー実装は `api_controller.rb` の `about[:config][:features] = about[:config][:features].merge(DynamicFeatures.new(sns).to_h)`。

判定するときは必ず `.config.features.<flag>` を見ること。top-level `.features` を見ると常に空に見えて「フラグが返っていない」と誤判定する。

動的フラグは `DynamicFeatures::REGISTRY` で導出される。例: `word_suggest => PronunciationDictionary.enabled?`（＝ `word_suggest/urls` 設定の有無）。capsicum 側はこのフラグで UI を出し分ける（モロヘイヤは外部 API の癖を吸収して正規化するプロキシで、capsicum は単純なフラグ判定だけを行う方針）。
