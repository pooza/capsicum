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
