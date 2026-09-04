# 棚卸し: API にあって capsicum が使っていない機能

[#993](https://github.com/pooza/capsicum/issues/993) の成果物。**API 実装だけが先行していて WebUI に出ていない機能**を含めて、サーバーが提供しているのに capsicum が使っていない面を洗い出し、拾う / 拾わないを決める。

- 実施日: **2026-08-25**（宿題 2 件の決着 = **2026-08-31**）
- 基準: **pooza フォーク**（美食丼 = `~/repos/mastodon` の `bshockdon` / ダイスキー = `~/repos/misskey` の `daisskey`）
- 兄弟の棚卸し: #991（WebUI 基準の未実装項目）/ #992（サーバー側に保存された設定）。**本ファイルは #993 の分**で、#991 / #992 は別ファイルになる。

⚠ **この文書はチェックリストではない。**拾うと決めたものは、ここから**最初からマイルストーンを付けた個別 Issue** として切り出す（[#905](https://github.com/pooza/capsicum/issues/905) / [#915](https://github.com/pooza/capsicum/issues/915) で 37 項目が滞留した形の再発防止）。

## 1. 母数と実施範囲

| | 母数 | 除外 | capsicum の使用数 |
| --- | --- | --- | --- |
| Mastodon | `config/routes/api.rb` 391 行 | `config/routes/admin.rb` + `namespace :admin` + `namespace :web`（WebUI 内部） | 約 70 パス |
| Misskey | `endpoints/` 配下 440 ファイル | `admin/` 配下 102 → **338** | **111** |

⚠ **フォーク固有の API は Mastodon 側に存在しなかった。**`git diff upstream/main bshockdon -- config/routes/api.rb` が空。つまり「本家にもあるか / フォーク固有か」の列は全行「本家」で埋まる。capsicum が使っている `collections` / `in_collections` / `quotes` 系も**本家 4.7 の機能**であって美食丼の独自実装ではない。

⚠ **上の「`quotes` 系」の書き方は 2026-09-04 まで不正確だった**（[#1072](https://github.com/pooza/capsicum/issues/1072) で訂正）。当時 capsicum が使っていたのは entity のフィールド（`quotes_count` / `quote`）だけで、**`GET /api/v1/statuses/:id/quotes` エンドポイントは叩いていなかった**。⚠ **この取り違えは棚卸しの母数そのものに効く** — 「使っている」に数えると、一覧が無いことが緑に見えてしまう。**エンドポイントを叩いているのか、entity のフィールドを読んでいるだけなのかを混ぜない。**（エンドポイント自体は v1.63 の #1072 で実装済み。）

### 実施範囲の正直な線引き

**層ごとに深さが違う。**均一に回したわけではないので、次の棚卸しが同じ地点から再開できるように書いておく。

| 層 | Mastodon | Misskey |
| --- | --- | --- |
| ① エンドポイント | **全数**（routes 全行を読んで突き合わせ） | **全数**（338 とカテゴリ別 diff） |
| ② パラメータ | **主要 6 経路 + 通知**（2026-08-31 に追加） | **主要経路のみ**（timeline / 通知。2026-08-31） |
| ③ entity フィールド | **全 8 entity**（2026-08-31 に 6 つ追加） | **Note / User**（2026-08-31） |

結果は §9。⚠ **層② は今も全数ではない。**「capsicum が呼んでいる経路のうち、主要なもの」に絞ってある。

### ⚠ 層③ の測り方（2026-08-31 に誤診しかけた）

**モデルのフィールド一覧で測ると間違える。**capsicum は一部の値を**型付きモデルを経由せず生の `Map<String, dynamic>` から読んでいる**（例: `isMuted` / `isBlocking` / `isFollowing` は `MisskeyUser` に無いが `misskey/adapter.dart:917-920` が生 map から読んでいる）。最初にモデルだけを見て「関係フラグが未読」と判定しかけた。

正しい母数の取り方は **backends 配下で実際に参照している JSON キーの集合**:

```sh
grep -rhoE "\['[a-zA-Z_][a-zA-Z0-9_]*'\]" packages/capsicum_backends/lib/src/misskey/ | tr -d "[']" | sort -u
```

これに `fediverse_objects` の `@JsonKey(name:)` とフィールド名を足したものを、サーバー側スキーマと `comm` で突き合わせる。

## 2. 落とす基準（列挙前に確定）

「エンドポイントがある」は「使う価値がある」を意味しない。次に当たるものは母数から落とす。

1. **管理系** — `admin/*`（両 SNS）。管理画面は棚卸しの対象外（#991 と同じ）。
2. **WebUI 内部専用** — Mastodon `namespace :web`（`web/settings` 等）、`v1_alpha/async_refreshes`、`apps/verify_credentials`、`emails/*`。
3. **認証・アカウント生死** — OAuth、`i/2fa/*`、`i/change-password`、`i/delete-account`、`i/move`、`i/regenerate-token`、`reset-password` 系。**WebUI でやるべきもの**で、クライアントが持つと事故時の責任範囲が広がる。
4. **既存の方針で明示的に採らないもの** — 投稿の更新（CLAUDE.md「実装しない機能」）/ 英語対応（#695）/ Fedibird 固有（低優先）/ サーバー個別対応。
5. **ゲーム・統計** — Misskey `reversi/*`（7）、`bubble-game/*`（2）、`charts/*`（12）、`retention`。
6. **サーバー運営者向け** — `federation/*`、`i/webhooks/*`、`server-info`、`stats`。

これで Mastodon の母数の約 4 割、Misskey の 338 のうち約 90 が落ちる。

## 3. 分類 A — 1.x の間に処理すべきもの

**判定軸は「今あるものが片肺で終わっている」か。**新機能の追加ではなく、**すでに capsicum にある導線の裏返しが欠けている**ものを優先する。1.x は外部要因ベースの運用なので、内部由来のタスクで枠を埋めない前提のもと、**ユーザーが踏むと機能欠落に見えるもの**だけをここに入れた。

### A-1. ブロック・ミュートした相手の一覧が無い（両 SNS）

| | 未使用 |
| --- | --- |
| Mastodon | `GET /api/v1/blocks` / `GET /api/v1/mutes` |
| Misskey | `blocking/list` / `mute/list` |

capsicum は **block / unblock / mute / unmute をすべて実装済み**（`blockAccount` / `muteAccount` ほか）。にもかかわらず**一覧が無い**ので、一度ミュートすると**相手のプロフィールに辿り着く以外に解除する手段が無い**。ミュートは相手が TL に出なくなる操作なので、**解除の導線が構造的に塞がる**（出てこない相手のプロフィールには行けない）。

⚠ **これは「読む側に道具を渡す」という CLAUDE.md の公開範囲・タイムライン方針の中核**にあたる。ミュートを勧める設計をしておいて外し方が無いのは片肺。

### A-2. フォローリクエストを処理できない（両 SNS）

| | 未使用 |
| --- | --- |
| Mastodon | `GET /api/v1/follow_requests` / `POST .../authorize` / `POST .../reject` |
| Misskey | `following/requests/list` / `accept` / `reject` / `cancel` / `sent` |

鍵アカウント（`locked`）のユーザーは、capsicum だけでは**フォロー申請を承認も拒否もできない**。通知の種別としては表示される（`notification_type_display.dart` に型がある）が、そこから先の操作が無い。**capsicum を主クライアントにしている鍵アカウントのユーザーは WebUI を開く必要がある。**

### A-3. Misskey で本文検索ができない

| | 状況 |
| --- | --- |
| Mastodon | `GET /api/v2/search`（`type` 指定つき）を使用 ✅ |
| Misskey | `notes/search` **未使用**。使っているのは `notes/search-by-tag` / `users/search` / `hashtags/search` |

**同じ検索画面が接続先によって別物になっている。**Mastodon では投稿本文が引けるのに、Misskey ではタグとユーザーしか引けない。実況の振り返り（「あのとき何て書いたか」）は capsicum の主用途に近いので、非対称が効く場面が多い。

### A-4. 通知の種別フィルタをサーバー側でやっていない（Mastodon）

`GET /api/v1/notifications` の `types[]` / `exclude_types[]` / `account_id` が未使用（capsicum が渡すのは `max_id` / `since_id` / `limit` だけ）。「すべての通知」画面で種別を絞る場合、**全種別を取ってからクライアントで捨てている**ことになる。絞り込みが強いほど無駄な転送とページングの空振りが増える。

⚠ **これは機能追加ではなくパラメータ 1 個の話**なので、A の中では最も軽い。

### A-5. Misskey のリノート解除（**2026-08-31 確認済み → 起票不要へ格下げ**）

**結論: 現状の実装は正しく、壊れてもいない。**ただし「元投稿を見ているときは解除できない」という制約が残り、それは **Misskey の API 側の制約**なので、素直に `notes/unrenote` を足しても解決しない。以下、確認した事実。

**① 危険な分岐は到達不能。**`post_actions.dart:171` は `unrepeatPost(isOwnRenote ? outerPost : targetPost)` と分岐しており、`isOwnRenote == false` の側は `targetPost`（＝元投稿）を渡す。Misskey の `unrepeatPost` は `client.deleteNote(post.id)`（`misskey/adapter.dart:618`）なので、**もしこの枝に入れば元投稿そのものを削除しにいく**。自分が書いた投稿なら消えてしまう。

しかし到達しない。導線の条件が `canUnrepeat = isOwnRenote || targetPost.reblogged`（`post_tile.dart:1170` / `post_touch_action_row.dart:137`）で、**Misskey の `toCapsicum` は `reblogged` を一度も立てない**（`misskey/extensions.dart:93-` に代入が無く、`Post` の既定値 `false` のまま。`post.dart:65`）。よって Misskey では `canUnrepeat == isOwnRenote` に縮退し、`targetPost` を渡す枝は**構造的に選ばれない**。

⚠ **これは「安全」ではなく「たまたま安全」。**Misskey 側で `reblogged` を埋める変更を入れた瞬間に、この枝が生きて**元投稿の削除**が起きる。`unrepeatPost` の Misskey 実装に「渡ってくるのは自分のリノート note に限る」という前提が**コメントでしか表現されていない**（`post_actions.dart` の doc）。ガードを置くならここ。

**② `notes/unrenote` は「元投稿の id」を取る。**フォークの実体（`packages/backend/src/server/api/endpoints/notes/unrenote.ts`）を読んだ:

```ts
const renotes = await this.notesRepository.findBy({ userId: me.id, renoteId: note.id });
for (const note of renotes) { this.noteDeleteService.delete(..., note); }
```

つまり `noteId` に**元投稿**を渡すと、自分のリノートを全部消してくれる。capsicum が今できない「元投稿を見ているときの解除」に、まさに対応するエンドポイント。

**③ ただし「解除できると知る」手段が無い。**Misskey の Note の JSON Schema（`models/json-schema/note.ts`）が持つのは `renoteId` / `renote` / `renoteCount` だけで、**自己リノート済みを示すフラグが無い**（Mastodon の `reblogged` に相当するものが存在しない）。TL のペイロードからは「この元投稿を自分がリノート済みか」が分からないので、`notes/unrenote` を足しても**トグルの状態が出せない**。判定するには投稿ごとに `notes/renotes` を引く必要があり、TL では非現実的。

**したがって A からは外す。**現状は「自分のリノート行が TL にあるときだけ解除できる」という、API の情報量なりの正しい姿。安く効くとすれば**スレッド / 投稿詳細画面**（対象が 1 件なので `notes/renotes` を 1 回引ける）に限った話で、それは機能追加であって片肺の解消ではない。⚠ **B にも入れない** — 次の棚卸しで再浮上させないため、判断済みとしてここに残す。

## 4. 分類 B — 2.0 以降のマイルストーンに載せるもの

**新しい画面 / 新しい概念を持ち込むもの。**1.x の集約枠には粒度が合わない。

**2026-08-31 に全件 v2.0 で起票済み**（pooza の判断）:

| 項目 | Issue |
| --- | --- |
| フィルタ（キーワードミュート）の管理 UI | [#1047](https://github.com/pooza/capsicum/issues/1047) |
| 通知のグループ化 | [#1048](https://github.com/pooza/capsicum/issues/1048) |
| トレンド | [#1049](https://github.com/pooza/capsicum/issues/1049) |
| Misskey クリップの操作 | [#1050](https://github.com/pooza/capsicum/issues/1050) |
| Misskey チャンネルの操作 | [#1051](https://github.com/pooza/capsicum/issues/1051) |
| Misskey アンテナの管理 | [#1052](https://github.com/pooza/capsicum/issues/1052) |
| Misskey ギャラリー | [#1053](https://github.com/pooza/capsicum/issues/1053) |
| 編集済み投稿の表示 | [#1054](https://github.com/pooza/capsicum/issues/1054) |
| 引っ越し済みアカウントの表示 | [#1055](https://github.com/pooza/capsicum/issues/1055) |
| タグの取得元（§7-2） | [#1056](https://github.com/pooza/capsicum/issues/1056) |

⚠ **#1050 / #1051 / #1052 は「保存済みショートカットの管理 UI をどこに置くか」という同じ設計問題を共有する。**バラバラに作ると UI の流儀が割れるので、**1 つ目を作るときに 3 つ分の型を決める**（各 Issue に相互リンク済み）。

⚠ **#1042（v1.63・通知の種別フィルタ）と #1048（v2.0・通知のグループ化）は同じリクエストに乗る。**#1042 を v1 の `GET /api/v1/notifications` で先に入れると、#1048 で v2 へ移るときに書き直しになりうる。**順序を意識すること。**

| 項目 | Mastodon | Misskey | 備考 |
| --- | --- | --- | --- |
| **フィルタ（キーワードミュート）** | `filters` v1/v2 + `filters/keywords` / `filters/statuses`、Status の `filtered` フィールド | `notes/thread-muting/*`、`renote-mute/*` | ⚠ **capsicum は Status の `filtered` を既に受け取っている**（`status.dart` に `filtered` あり）。つまり**サーバーが「これは伏せろ」と言ってきているのを読んでいる可能性がある**一方、フィルタの管理 UI が無い。CLAUDE.md の「見たくないものを見ないようにする道具は読む側に提供する」に真正面から合致する枠 |
| **通知のグループ化** | `GET /api/v2/notifications`（`group_key` 単位） | `i/notifications-grouped` | **両 SNS に揃っている**。「10 人がお気に入りしました」形式。通知画面の構造変更を伴うので大更新 |
| **トレンド** | `trends/tags` / `trends/links` / `trends/statuses` | `hashtags/trend` | 新しい画面。実況文化圏との相性は要検討（トレンドは全体の話題であって、プリセットサーバーのデフォルトタグ文化とは別軸） |
| **クリップへの投稿追加**（Misskey） | ― | `clips/create` / `clips/add-note` / `clips/remove-note` / `clips/update` / `clips/delete` / `clips/show` | capsicum は**クリップの閲覧だけ**（11 本中 2 本）。作成・追加ができないので「読める整理棚」で止まっている |
| **チャンネルの操作**（Misskey） | ― | 16 本中 14 本未使用（`create` / `update` / `follow` / `favorite` / `search` / `show` / `mute/*` / `owned` ほか） | 同上。閲覧のみ |
| **アンテナの管理**（Misskey） | ― | `antennas/create` / `update` / `delete` / `show` | 同上。閲覧のみ |
| **ギャラリー**（Misskey） | ― | `gallery/*` 9 本中 8 本未使用 | 独立した機能。単独で 1 枠になる規模 |
| **編集済み投稿の表示** | Status の `edited_at` / `GET /api/v1/statuses/:id/history` / `/source` | ― | ⚠ **CLAUDE.md の「実装しない機能: 投稿の更新」とは別物。**あちらは*書く*側の話で、これは**他人が編集した投稿に「編集済み」と分かる印を出す** *読む*側の話。混同しやすいので、起票時に本文へ明記する |
| **アカウントの引っ越し追従** | Account の `moved` | `i/move` は除外だが受け側の表示は別 | 引っ越し済みアカウントの表示。capsicum の Account モデルは `moved` を持たない |

## 5. 分類 C — 拾わない

**「今は要らない」ではなく「capsicum の役割ではない / 方針に反する」もの。**次の棚卸しで再浮上させないために理由を残す。

| 項目 | 理由 |
| --- | --- |
| Mastodon `suggestions` / `directory` / `familiar_followers` / `endorsements` / `accounts/:id/pin`（プロフィール掲載） | **フォロー推薦・人脈の可視化系。**capsicum はプリセットサーバーの住人向けで、発見導線はサーバー文化（デフォルトタグ TL）が担っている。フォロー外アカウントへの導線を積極的に作らない方針とも整合する |
| Mastodon `annual_reports`（年次まとめ） / `donation_campaigns` | サーバー運営者の施策を表示する枠。**美食丼で使っていない** |
| Mastodon `instance/peers` / `peers/search` / `domain_blocks`（ユーザー側） / Misskey `federation/*` | **連合の可視化**はサーバー管理者の関心事。capsicum の「サーバーの素性を提示する」（#816）はソフト名と版だけで足りている |
| Mastodon `emails/*` / `accounts/:id/email_subscriptions` / Account の `email_subscriptions` | メール配信設定。**WebUI の領分** |
| Misskey `reversi/*` / `bubble-game/*` / `charts/*` / `retention` | ゲーム・統計。Play（AiScript）は実装済みだが、あれは**実況の道具**として拾ったもので、ゲーム一般を拾う方針ではない |
| Misskey `i/2fa/*` / `i/change-password` / `i/delete-account` / `i/regenerate-token` / `i/revoke-token` / `i/authorized-apps` | **アカウントの生死に関わる操作。**クライアントが持つと事故時の責任範囲が広がる |
| Misskey `i/webhooks/*` / `i/registry/*` | 開発者向け / 内部ストレージ。`registry` は #992（サーバー側設定）で別途扱う |
| Misskey `i/export-*` / `i/import-*` | サーバー側のデータ書き出し。**capsicum は #857 で独自の設定バックアップを実装済み**で、あちらは端末間移行が目的。サーバーの export はアカウント移行が目的で別物 |
| Mastodon `identity_proofs` | deprecated |
| Mastodon `statuses` index（id 一括取得） / `polls/:id` show | capsicum の取得経路（TL / context）で埋まっており、単独で叩く場面が無い |

## 6. #992 へ回すもの（重複整理）

次は**ユーザー設定**の層なので、#992（サーバー側に保存された設定の反映漏れ）で扱う。ここでは列挙だけして判定しない。

- Mastodon `GET /api/v1/preferences`、Account の `indexable` / `discoverable` / `hide_collections` / `show_media` / `show_media_replies` / `show_featured` / `noindex`
- Mastodon `notifications/policy`（v1 / v2）、`notifications/requests`（通知リクエスト）
- Misskey `i/registry/*`、`roles/*`（ロールによる機能可否）

⚠ **Account の設定系フィールドは capsicum が既に半分読んでいる**（`showMedia` / `showMediaReplies` / `showFeatured` / `hideCollections` / `discoverable` はモデルに存在）。#992 では「読んでいるが UI に反映していない」の側から入るのが早い。

## 7. 未確認・次回の宿題

- **Misskey の層 ②③（パラメータ・entity フィールド）が丸ごと未実施。**338 エンドポイントの JSON Schema を持つので機械的に回せるはずだが、母数が大きいので独立した回にする。
- **Mastodon 層 ③ は Status / Account の 2 entity のみ。**`Notification` / `MediaAttachment` / `PreviewCard` / `Poll` / `List` / `Announcement` は見ていない。
**確認済みになったもの**（2026-08-31）:

- ~~A-5（Misskey のリノート解除）の UI 側の実装確認~~ → 上の A-5 に決着を書いた。**起票不要**。
- ~~Status の `tags` / `mentions` を capsicum が読んでいない点~~ → 下記のとおり確定。**判断待ち**として §7-2 へ移した。

### 7-2. タグの取得元がサーバーの `tags` ではなく描画済み HTML / MFM のパース（→ [#1056](https://github.com/pooza/capsicum/issues/1056)・v2.0）

**2026-08-31 決着。**「基本設計の見直しとしてはぜひやりたいが、**現行実装がバグというわけでもない**ので v2.0 へ割り当てる」（pooza の判断）。

**事実として確定した。**`packages/fediverse_objects/lib/src/mastodon/status.dart` に `tag` / `mention` のフィールドが**そもそも無く**、backends のどこにも `'tags'` を読む箇所が無い。`Post` モデル（`capsicum_core`）にも `tags` / `mentions` は無い。タグは 100% `extractHashtags(content, isHtml:)`（`content_parser.dart:145`）が**本文をパースして**得ている（Mastodon は HTML の `hashtag` ノード、Misskey は MFM）。

非対称になるのは次の点:

- **`tags` はサーバーが正規化した正本**（`name` + `url`）。パースは**描画の見た目**に依存するので、リモートのソフトウェアがハッシュタグをリンクにしない形で連合してくると、サーバーは認識しているのに capsicum は拾えない。
- **大文字小文字の扱い**が、サーバーの正規化とパースの結果で割れうる。
- 逆に、**本文に書いてあるがサーバーがタグと認めていない**文字列をタグとして拾う余地もある（コードブロック内など）。

⚠ **これを「不具合」と断定しない。**実際に取りこぼした報告は無く、プリセットサーバー（Mastodon / Misskey とも pooza フォーク）同士では両者が一致する見込みが高い。一方で **capsicum の根幹はタグ管理**であり、「サーバーが正本を返しているのに読んでいない」という構図自体は棚卸しの結果として正しい。

判断が要るのは「**投稿を読む側のタグ**（タグ TL へ飛ぶ・タグをコピー）の取得元を `tags` に寄せるか」。⚠ **投稿を書く側（末尾ハッシュタグの管理・お気に入りタグ・タグセット）はクライアント側のテキストの話なので無関係**。混同しやすいので分けて扱う。

## 8. 次の一手

**この文書の時点では Issue を起こさない**（分類が確定してから、A → v1.61 または次の 1.x 枠 / B → v2.0 据え置きで起票する、という順序で合意済み）。

起票を提案する順序:

1. **A-1 ブロック・ミュート一覧**（両 SNS・片肺の解消・小〜中粒）
2. **A-2 フォローリクエスト**（両 SNS・機能欠落・中粒）
3. **A-3 Misskey 本文検索**（非対称の解消・小粒）
4. **A-4 通知の種別フィルタ**（パラメータのみ・小粒）
5. ~~A-5 は確認後に判断~~ → **確認済み・起票不要**（2026-08-31）

**B は 2026-08-31 に全件 v2.0 で起票済み**（一覧は §4）。⚠ **これで #993 の分類はすべて Issue になった。**この文書に「まだ起票していないもの」は残っていない。

残る判断は **#1047（フィルタ）を設計書（#720 / #597 と同じ形）に進めるか**。⚠ 両 SNS でモデルが根本的に違う（Mastodon はサーバー判定、Misskey は capsicum が `mutedWords` を読んで端末側で判定）ので、**1 つの UI に畳む設計判断が要る**＝設計書向きの候補として #1047 の本文に書いてある。

### 起票の行き先（2026-08-31 決着）

**A 群は専用の枠 [v1.63](https://github.com/pooza/capsicum/milestone/77) で消化する**（pooza の判断）。

論点はこうだった。CLAUDE.md の「大玉の進め方」§3 は「確定後に **1.x 行きだけを稼働中の枠へ**」と決めているが、稼働中の [v1.62](https://github.com/pooza/capsicum/milestone/76) は**外部要因の発生ベース**の枠として、内部由来の #1034 / #1035 / #1038 を意図的に外して作った。A 群は棚卸し由来なので同じ基準では内部由来にあたり、**入れると同じ回に外した 3 件と扱いが割れる**。

→ **棚卸しの成果は棚卸しの枠で消化する**ことにして、基準の衝突を回避した。

⚠ **v1.63 は「内部由来を入れてよい枠」ではない。**#993 の分類 A として明示的に拾うと決めたものだけが入る。#1034 / #1035 / #1038 をここへ移送しない。

起票済み（2026-08-31）:

| 分類 | Issue | 粒度 |
| --- | --- | --- |
| A-1 | [#1039](https://github.com/pooza/capsicum/issues/1039) ブロック・ミュートの一覧 | 小〜中（**この枠の主役**） |
| A-2 | [#1040](https://github.com/pooza/capsicum/issues/1040) フォローリクエストの承認・拒否 | 中 |
| A-3 | [#1041](https://github.com/pooza/capsicum/issues/1041) Misskey の本文検索 | 小 |
| A-4 | [#1042](https://github.com/pooza/capsicum/issues/1042) 通知の種別フィルタをサーバー側で | 小 |

A-5 は上記のとおり**起票不要**。B は v2.0 据え置きで**未起票**（設計書へ進めるかの判断は別途）。

## 9. 層②③ の結果（2026-08-31）

層① は「呼んでいないエンドポイント」を見る。層②③ は「**呼んでいる経路の中で捨てている情報**」を見るので、性質が違う。実際、層① で出なかった当たりがここで出た。

### 9-1. ★ Misskey の `reactionAcceptance` を読んでいない（リアクションが黙って ❤️ に化ける）

**Note の `reactionAcceptance`（`enum: likeOnly / likeOnlyForRemote / nonSensitiveOnly / nonSensitiveOnlyForLocalLikeOnlyForRemote / null`）が未読。**

サーバー側（`core/ReactionService.ts:125-160`）は、条件に合うと**エラーを返さず、リアクションの中身を差し替える**。`FALLBACK = '❤'`（❤️）:

- `likeOnly` → 何を選んでも ❤️
- `nonSensitiveOnly` + センシティブなカスタム絵文字 → ❤️
- **ロール制限つきの絵文字**（`roleIdsThatCanBeUsedThisEmojiAsReaction`）で権限が無い → ❤️
- 未知の絵文字 → ❤️

capsicum は投稿ごとの受付条件を知らないので、**常に全部入りのピッカーを出す**。ユーザーが選んだ絵文字と違うものが付き、`runReaction` は成功扱いなので**エラーも出ず Sentry にも出ない**（読み直しで TL の表示だけは正しくなるため、ユーザーには「押し間違えた？」に見える）。

⚠ **リノートへのリアクションは別途サーバーがエラーを返す**（`You cannot react to Renote.`）が、capsicum は `targetPost.id`（元投稿）を送っているので**踏まない**（`post_tile.dart:1054` ほか）。

### 9-2. ★ Misskey の `i/notifications` は `markAsRead` の既定が `true`

capsicum が送っているのは `sinceId` / `untilId` / `limit` だけ。**`markAsRead` を明示していないので既定の `true` が効き、取得しただけでサーバー側の未読が消える。**

capsicum は未読をクライアント側で数えているので自分では困らないが、**WebUI を併用しているユーザーは、capsicum のバックグラウンド取得によって WebUI 側の未読バッジが黙って消える**。⚠ **これは capsicum の画面では観測できない**（他クライアントの状態が変わる）ので、報告が来ても原因に辿り着きにくい。

### 9-3. ★ 通知の種別フィルタは両 SNS に揃っている（#1042 の前提が確定）

`i/notifications` の paramDef に **`includeTypes` / `excludeTypes`** が実在した。[#1042](https://github.com/pooza/capsicum/issues/1042) は Mastodon 限定として起票したが、**Misskey にも同じ機能があるので対称に実装できる**。クライアント側の絞り込みをフォールバックとして残す必要は無い。

あわせて Mastodon 側で層② の当たりが 1 つ:**`GET /api/v1/notifications` の `supported_types` が未使用**（`api/v1/notifications_controller.rb:19`）。これを送ると、サーバーは capsicum が知らない通知型に対して **`fallback: { title, summary }`**（人間が読める文言）を返す（`NotificationFallbackConcern`）。送らないと `needs_fallback?` が即 `false` を返すので**永久に来ない**。未知の型が増えたときに「中身のわからない通知」を出さずに済む安全弁。→ **#1042 に追記した。**

### 9-4. ★ `tags` は Misskey も返している（§7-2 の裏付け）

Misskey の Note スキーマにも **`tags`（配列）** があり、こちらも未読。**両 SNS ともサーバーが正規化済みのタグ配列を返しているのに、capsicum は本文のパースだけで済ませている**ことが確定した。§7-2 の判断材料として強くなった。

### 9-5. Misskey `notes/timeline` で捨てているパラメータ

capsicum が送るのは `untilId` / `sinceId` / `limit` / `withFiles`。未使用:

| パラメータ | 既定 | 効き方 |
| --- | --- | --- |
| **`withRenotes`** | `true` | **リノートを TL から外す**。「リノートが多くて読めない」に対する一次的な答えで、クライアント側の間引きより正確 |
| `includeMyRenotes` / `includeRenotedMyNotes` / `includeLocalRenotes` | すべて `true` | リノートの内訳を細かく制御 |
| `allowPartial` | `false` | ⚠ 上流のコメントが **`true is recommended`**（互換のため既定が false）と明記。取得の速度に効く |
| `sinceDate` / `untilDate` | ― | 日時での範囲指定。id ベースのページングでは辿れない範囲を取れる |

### 9-6. 層③ の全体像（数え直した結果）

| entity | 母数 | 読んでいる | 主な未読 |
| --- | --- | --- | --- |
| Misskey Note | 35 | 24 | `reactionAcceptance` ★ / `tags` ★ / `visibleUserIds` / `isHidden` / `mentions` / `uri` / `deletedAt` / `clippedCount` |
| Misskey User | 100 | 32 | 下記 |
| Mastodon Notification | 12 | 8 | `fallback` ★ / `group_key`（B の通知グループ化）/ `moderation_warning` / `report` |
| Mastodon MediaAttachment | 10 | 5 | `meta` / `blurhash` / `remote_url` / `preview_remote_url` / `text_url`(deprecated) |
| Mastodon PreviewCard | 19 | 7 | `width` / `height` / `blurhash` / `published_at` / `authors` / `author_name` / `html` / `embed_url` ほか |
| Mastodon Poll | 10 | 10 | **未読ゼロ** ✅ |
| Mastodon List | 4 | 2 | `replies_policy` / `exclusive` |
| Mastodon Announcement | 13 | 7 | `starts_at` / `ends_at` / `all_day` / `published_at` / `mentions` / `tags` |

⚠ **添付画像の `meta` / `blurhash` は #1032 と同型ではない。**「サーバーが縦横比を返しているのに読んでいない」構図は絵文字（#1032）と同じだが、**添付グリッドは `SizedBox(height: 320 * thumbScale)` の固定高**（`post_tile.dart:3334` 付近）なので、寸法が未知でもレイアウトはずれない。効くのは (a) 読み込み中のプレースホルダ（`blurhash`）、(b) `meta.focus`（フォーカルポイント）に沿った切り抜き、(c) 動画の長さ表示。**不具合ではなく品質項目**なので A ではない。

⚠ **PreviewCard の `width` / `height` も同様に優先度が下がる。**[#1033](https://github.com/pooza/capsicum/issues/1033) で「OGP 画像の有無によらずカードの大きさを一定にする」と決めたばかりで、サーバーの寸法に従う方針を採っていない。

**Misskey User の未読 68 個の内訳:**

- **#1039 / #1040 で使う** — `hasPendingFollowRequestToYou` / `hasPendingFollowRequestFromYou` / `hasPendingReceivedFollowRequest`（フォロー申請の状態）/ `isBlocked`（相手が自分をブロック。capsicum は `isBlocking` だけ読んでいる）/ `isRenoteMuted`
- **アカウントの状態** — `isSilenced` / `isSuspended` / `isDeleted`。⚠ **凍結・削除済みのアカウントを普通のプロフィールとして表示している**
- **プロフィールの項目** — `location` / `birthday` / `lang` / `memo`（自分だけに見えるメモ）/ `achievements` / `instance`（リモートユーザーのサーバー情報）/ `onlineStatus` / `publicReactions` / `pinnedPage`
- **一覧の公開範囲** — `followersVisibility` / `followingVisibility`。⚠ 非公開のときフォロー一覧が空で返るはずで、capsicum は「0 人」と区別できていない可能性がある（未確認）
- **未読フラグ 9 種** — `hasUnreadAnnouncement` / `unreadAnnouncements` / `hasUnreadMentions` / `hasUnreadSpecifiedNotes` / `hasUnreadAntenna` / `hasUnreadChannel` / `hasUnreadChatMessages` / `hasUnreadNotification` / `unreadNotificationsCount`。**サーバーが持っているのに capsicum はクライアント側で数えている**
- **引っ越し** — `movedTo` / `alsoKnownAs`（B 群に既出）
- **→ #992 へ** — `policies`（ロールによる機能可否）/ `notificationRecieveConfig` / `mutedInstances` / `emailNotificationTypes` / `alwaysMarkNsfw` / `autoSensitive` / `carefulBot` / `autoAcceptFollowed` / `noCrawle` / `preventAiLearning` / `injectFeaturedNote` / `hideOnlineStatus` / `receiveAnnouncementEmail` / `followedMessage` / `withReplies` / `notify`
- **拾わない**（§2 の基準どおり） — `email` / `emailVerified` / `twoFactorEnabled` / `usePasswordLessLogin` / `securityKeys` / `securityKeysList` / `twoFactorBackupCodesStock`（認証）/ `moderationNote` / `isAdmin` / `isModerator`（管理）/ `avatarId` / `bannerId` / `pinnedNoteIds` / `lastFetchedAt` / `uri`（内部 id・冗長）

### 9-7. 新しく拾うと判断したもの

**A に足したもの（2026-08-31 に起票・すべて v1.63）:**

| | 内容 | Issue | 根拠 |
| --- | --- | --- | --- |
| **A-6** | Misskey の `reactionAcceptance` を尊重する | [#1044](https://github.com/pooza/capsicum/issues/1044) | 9-1。選んだものと違う結果になり、しかも無言 |
| **A-7** | `i/notifications` に `markAsRead: false` を明示する | [#1045](https://github.com/pooza/capsicum/issues/1045) | 9-2。他クライアントの未読を黙って消す。**1 行**で直る |
| **A-8** | 「指名」投稿に `visibleUserIds` を送る | [#1043](https://github.com/pooza/capsicum/issues/1043) | 10-1。**新規投稿が誰にも届かない**。この枠で唯一の bug |

**既存 Issue へ反映済み:** #1042 に 9-3（Misskey も対称・`supported_types`）を追記した。

**未実施のまま残るもの（正直に）:**

- Misskey の層② は `notes/timeline` / `i/notifications` しか見ていない。**capsicum が呼ぶ 111 経路のうち 2 つ**
- Misskey の層③ は Note / User のみ。`drive-file` / `notification` / `channel` / `clip` / `antenna` / `page` / `flash` / `chat-*` 等は見ていない
- Mastodon の層② は主要 6 経路 + 通知のみ

## 10. 層② 主要経路の結果（2026-08-31・追加分）

capsicum が呼ぶ Misskey の 113 経路のうち、**投稿・タイムライン・アップロードの主要 4 経路**を見た。残りは §11。

### 10-1. ★★ Misskey の「指名」投稿が、新規投稿だと誰にも届かない

**`notes/create` の `visibleUserIds` を capsicum は一度も送っていない**（`visibleUserIds` はリポジトリ全体で 0 ヒット）。一方 `MisskeyCapabilities.supportedScopes` は `PostScope.direct` を含んでおり（`misskey/adapter.dart:72`）、投稿画面に**「指名」が選択肢として出る**（`post_scope_display.dart:38`）。

サーバー側（`core/NoteCreateService.ts:624-636`）はこう動く:

```ts
if (data.visibility === 'specified') {
  if (data.visibleUsers == null) throw new Error('invalid param');
  for (const u of data.visibleUsers) { /* mentionedUsers へ足す */ }
  if (data.reply && !data.visibleUsers.some(x => x.id === data.reply!.userId)) {
    data.visibleUsers.push(/* 返信先を足す */);
  }
}
```

`visibleUsers` は **`visibleUserIds` パラメータと「返信先」からしか作られない**（`notes/create.ts:239` が `ps.visibleUserIds ?? []`、`NoteCreateService.ts:300` が空配列にする）。したがって:

| 操作 | 結果 |
| --- | --- |
| 「指名」で**新規投稿** | `visibleUsers` が空 → **投稿者以外の誰にも見えない** |
| 「指名」で**返信** | 返信先が自動で足される → 届く ✅ |

⚠ **本文に `@alice` と書いても宛先にならない。**上のコードは `visibleUsers` → `mentionedUsers` の一方向で、逆は無い。**Mastodon とは挙動が違う**（Mastodon の `direct` は本文のメンションがそのまま宛先）。この非対称が、同じ「指名 / ダイレクト」ラベルの裏に隠れている。

⚠ **失敗しない。**サーバーはエラーを返さず、投稿は成功する。投稿者の画面には自分の投稿として残るので、**相手に届いていないことに気付けない。**

### 10-2. `notes/create` のその他の未使用パラメータ

| パラメータ | 効き方 |
| --- | --- |
| `reactionAcceptance` | **投稿時にリアクションの受付を制限する。**§9-1 の裏返し（読む側だけでなく書く側も未対応） |
| `noExtractMentions` / `noExtractHashtags` / `noExtractEmojis` | 本文からの自動抽出を止める。⚠ **タグ管理が根幹の capsicum とは相性がある論点**だが、現状の「サーバーに抽出させる」挙動で困っている報告は無い |
| `mediaIds` | `fileIds` の旧名。使う必要なし |

### 10-3. タイムライン系で捨てているパラメータ

`notes/timeline` は §9-5。`users/notes`（プロフィールのタイムライン）も同型:

| パラメータ | 既定 | 効き方 |
| --- | --- | --- |
| `withReplies` | `false` | **プロフィールに返信が出ない。**「この人の発言を全部見たい」に応えられない |
| `withChannelNotes` | `false` | チャンネル投稿がプロフィールに出ない |
| `withRenotes` | `true` | リノートを外せない |
| `withFiles` / `allowPartial` / `sinceDate` / `untilDate` | ― | §9-5 と同じ |

### 10-4. `drive/files/create`

capsicum が送るのは `file` / `comment` / `isSensitive` / `folderId`。未使用は `name`（ファイル名の明示）と `force`（重複チェックの無視）。⚠ **`force` を送らないのは正しい** — Misskey はハッシュで重複排除して既存ファイルを返すので、送らないほうが容量を食わない。`name` も multipart のファイル名で足りている。**ここは当たり無し。**

## 11. 未実施のまま残す範囲（→ [#1046](https://github.com/pooza/capsicum/issues/1046)）

「主要なものだけ進め、残りは別 Issue」という 2026-08-31 の判断に従い、以下は**この文書では扱わない**。続きは [#1046](https://github.com/pooza/capsicum/issues/1046)（v2.0）で回す。

| 層 | 残り |
| --- | --- |
| Misskey ② | 113 経路のうち **109**（chat / clips / antennas / channels / pages / flash / drive folders / lists / following / blocking / mute ほか） |
| Misskey ③ | Note / User 以外の全 entity（`drive-file` / `notification` / `channel` / `clip` / `antenna` / `page` / `flash` / `chat-*` / `emoji` / `role` ほか） |
| Mastodon ② | 主要 6 経路 + 通知 以外 |

⚠ **「見ていない」であって「無かった」ではない。**主要経路だけで ★ が 5 件出ているので、**残りにも同じ密度で当たりがある前提**で扱うこと。
