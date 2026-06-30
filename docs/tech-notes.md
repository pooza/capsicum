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

### 外部パッケージの enum への網羅 switch は CI 時限爆弾（dio など）

capsicum の依存は `^` 制約の浮動指定で `pubspec.lock` も `.gitignore` 対象のため、CI は毎回最新版を解決する。外部パッケージが enum に値を足すと、`default:` の無い網羅 switch が `non_exhaustive_switch_statement` でコンパイル不能になり、**ソース無変更のまま CI が突然全滅する**（手元は旧 lock を握っていて再現しない）。v1.42 で dio 5.10.0 の `DioExceptionType.transformTimeout` 追加により `push_relay_client.dart` の網羅 switch が落ち、develop の Analyze / Linux / Windows Release が全滅した。**外部パッケージの enum を switch するときは必ず `default:` を置く**（前方互換）。ローカル analyze が通っても CI と dio 解決バージョンがズレている可能性があるので、CI 失敗時はまず `dart pub upgrade <pkg>` で最新解決に揃えて再現確認する。

### Android 16KB ページサイズ：irondash の precompiled `.so` が 4KB で Play に弾かれる

Google Play は 64bit `.so` の LOAD セグメントが 16KB 整列（`p_align >= 16384`）でないと製品版昇格を `Artifact does not support 16KB page size` で拒否する（2026-06 にハード強制が有効化。それ以前は警告で、同じ 4KB バイナリのまま production に出ていた＝我々の回帰ではなくストア側の締め付け）。v1.42 build 138 で踏んだ。

原因は `irondash_engine_context`（`super_drag_and_drop` → `super_native_extensions` の transitive 依存）。cargokit はデフォルトで **GitHub の precompiled `.so` をダウンロード**して使い、irondash 0.5.5（最新）の precompiled が 4KB 整列・upstream 修正なし（姉妹 super_native_extensions は build.rs に `cargo:rustc-link-arg=-Wl,-z,max-page-size=16384` があり precompiled も 16KB 済み）。**ELF セグメント整列は後から変えられない**ので zipalign 等では直らない。

対処（恒久・コミット済み）: `packages/capsicum/android/cargokit_options.yaml` に `use_precompiled_binaries: false` を置いてローカル Rust ビルドへ切り替え（要 rustup + android ターゲット）、ビルド時に `CARGO_ENCODED_RUSTFLAGS=-Clink-arg=-Wl,-z,max-page-size=16384` を渡して 16KB 整列させる。**stale な gradle daemon は古い環境を握っていてフラグを取りこぼす**ので `./gradlew --stop` してから build。手順・検証の正本は docs/store-release-guide.md §4.2「Android: 16KB ページサイズ対応」。アップロード前に `.so` の `p_align` を必ず検証する。

### 仕様に迷ったらまず本家 Mastodon / Misskey の実装を確認する

ストリーミング・ページネーション・通知など、SNS の挙動に関わる設計判断で迷ったら、推測する前に本家 WebUI の実装を読む癖をつける。手元のフォーク（`~/repos/mastodon` = bshockdon / `~/repos/misskey` = daisskey）に上流コードが入っており、`git fetch` で最新化して確認できる（[server-forks の経緯はメモリ参照]）。capsicum の方が手厚いこともあれば、本家の方が枯れていて正しいこともあるので、まず一次情報を当たる。

実例（ストリーミング再接続、v1.42 #786 調査）: 切断・再接続は不具合ではなく標準的な機構で、本家 WebUI も自動再接続ライブラリを噛ませている。

- **Mastodon**: `@gamestdio/websocket`（指数バックオフ付き自動再接続）。再接続後のギャップは埋めず、TL 先頭に `TIMELINE_GAP`（手動「もっと見る」）を挿すだけ（[reducers/timelines.js の `reconnectTimeline`]）。
- **Misskey**: `reconnecting-websocket`（バックオフ付き自動再接続、misskey-js `streaming.ts`）。再接続時はチャンネルを張り直すのみで、切断中のギャップを能動回収はしない（realtime は prepend 任せ・非 realtime は `fetchNewer` ポーリング）。
- **capsicum**: live 復帰時に since までさかのぼって REST 差分を能動回収（`collectCatchUpGap`）。取りこぼし対策はむしろ両本家より手厚い。#784/#782 の方向性が正しかったことの裏取りにもなった。

## デスクトップ（drag & drop / ネイティブ連携）

### drag-out の重い処理（ダウンロード等）は `dragItemProvider` ではなく virtual file provider に置く

super_drag_and_drop で virtual file を使ってメディアを drag-out する際（#645 メディアビューア画像保存）、ネットワーク取得などの `await` を**ドラッグ開始時の `dragItemProvider`（async）に置くと Windows でドラッグが「できたりできなかったり」**になる。Windows の OLE ドラッグ（`DoDragDrop`）はジェスチャー内で同期的に開始する必要があり、開始前に await が挟まると取得完了までドラッグが始まらず、回線・タイミング次第で起動が間欠的に失敗する。macOS は item provider から後追いでドラッグセッションを開始できるため同じコードでも顕在化せず、プラットフォーム差で気付きにくい。

対策: 取得は `addVirtualFile` の **provider（drop 時に呼ばれる）内で遅延実行**し、`dragItemProvider` は await せず同期で `DragItem` を返す。`addVirtualFile` はそもそも「DL 等で時間がかかる on-demand 生成」を想定した API（パッケージ doc 参照）であり、これが本来の使い方。Dart 共通コードなので macOS も同挙動になる（virtual file の遅延 async は D&D で公式サポート・回帰なし）。差が出るのは低速回線時のみ。実装は [media_viewer_screen.dart](../packages/capsicum/lib/src/ui/screen/media_viewer_screen.dart) の `_DragOutImage`。

### desktop のドラッグ操作はマウス＝即ドラッグ・タッチ＝長押し→持ち上げ

super_drag_and_drop の drag 開始ジェスチャーは入力デバイスで異なる。マウスは長押し不要の即ドラッグ、タッチは長押し→そのまま持ち上げ（スクロール/タップとの誤認回避・iOS/Android と同方式）。タッチ環境で「長押しが要るのか即ドラッグなのか」分かりにくいが仕様。drag-out が動かないという報告は、まずコードでなくこの操作差を疑う。

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

## モロヘイヤ API

### 機能フラグは `.config.features` 配下にある（top-level `.features` ではない）

モロヘイヤ `GET /mulukhiya/api/about` の機能フラグ（`annict` / `word_suggest` / `media_catalog` / `program_editable` / `annict_linked` 等）は、**top-level の `features` ではなく `config.features` の下**にある。サーバー実装は `api_controller.rb` の `about[:config][:features] = about[:config][:features].merge(DynamicFeatures.new(sns).to_h)`。

判定するときは必ず `.config.features.<flag>` を見ること。top-level `.features` を見ると常に空に見えて「フラグが返っていない」と誤判定する。

動的フラグは `DynamicFeatures::REGISTRY` で導出される。例: `word_suggest => PronunciationDictionary.enabled?`（＝ `word_suggest/urls` 設定の有無）。capsicum 側はこのフラグで UI を出し分ける（モロヘイヤは外部 API の癖を吸収して正規化するプロキシで、capsicum は単純なフラグ判定だけを行う方針）。
