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
| ① エンドポイント | **全数**（routes 全行を読んで突き合わせ）。⚠ **取りこぼしが 2 件あった**（§13-4 / §13-7） | **全数**（338 とカテゴリ別 diff） |
| ② パラメータ | ✅ **全数**（2026-10-02・§13。capsicum が呼ぶ約 75 経路） | ✅ **分類 B 系以外は全数**（2026-10-02・§12-5 + §14）。残るのは `clips` / `antennas` / `channels` / `pages` / `flash` で、**B の着手回に従属**（§12-6） |
| ③ entity フィールド | **全 8 entity**（2026-08-31 に 6 つ追加） | **Note / User**（2026-08-31）+ `notification` / `drive-file` / `chat-*` / `emoji` / `role`（2026-09-29・§12）。残り 5 entity は **B の着手回に従属**（§12-6） |

結果は §9–10（archive）・§12（層③ 第 1 巡）・§13（Mastodon ②）・§14（Misskey ②）。

⚠⚠ **層② は 2026-10-02 に閉じた。**それまで「capsicum が呼んでいる経路のうち主要なもの」に絞ってあり、⚠ **どの経路を見たのかが記録に残っていなかった**（§13 の冒頭）。**次に層を絞って回すときは、見た経路の一覧を必ず残すこと。**

⚠⚠ **層① の「全数」は嘘ではないが取りこぼした。**`GET /api/v1/notifications/unread_count`（§13-4）と `POST /api/v1/statuses/:id/mute`（§13-7）は routes に載っているのに層① で落ちている。**どちらも層② の目で経路の中身を読んでいて気付いた** —— [#1077](https://github.com/pooza/capsicum/issues/1077) の「母数の取り方が違うと別のものが見える」が、API 基準の内側でも成り立つ。

### 層③ の測り方（2026-08-31 に誤診しかけた）

⚠ **モデルのフィールド一覧で測ると間違える。**capsicum は一部の値を**型付きモデルを経由せず生の `Map<String, dynamic>` から読んでいる**（例: `isMuted` / `isBlocking` / `isFollowing` は `MisskeyUser` に無いが `misskey/adapter.dart:917-920` が生 map から読んでいる）。最初にモデルだけを見て「関係フラグが未読」と判定しかけた。

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

## 3. 分類 A — 1.x の間に処理すべきもの（全件決着・[archive へ分けた](archive/api-gap-inventory-settled.md)）

**判定軸は「今あるものが片肺で終わっている」か。**新機能の追加ではなく、**すでに capsicum にある導線の裏返しが欠けている**ものを優先した。

⚠ **2026-10-02 に詳細を archive へ移した**（本体が 60KB へ貼り付いたため・[#1184](https://github.com/pooza/capsicum/issues/1184) の規約）。**全件 v1.63 で決着している。**

| | 内容 | 行き先 |
| --- | --- | --- |
| **A-1** | ブロック・ミュートした相手の一覧が無い（両 SNS）。⚠ **ミュートすると解除の導線が構造的に塞がる** | [#1039](https://github.com/pooza/capsicum/issues/1039) ✅ |
| **A-2** | フォローリクエストを処理できない（両 SNS） | [#1040](https://github.com/pooza/capsicum/issues/1040) ✅ |
| **A-3** | Misskey で本文検索ができない（`notes/search` 未使用）。⚠ 同じ検索画面が接続先で別物になっていた | [#1041](https://github.com/pooza/capsicum/issues/1041) ✅ |
| **A-4** | 通知の種別フィルタ。⚠⚠ **起票時の前提が誤っていた**（「取ってから捨てている」のではなく**絞り込みの UI が無かった**）→ 新機能として読み替え | [#1042](https://github.com/pooza/capsicum/issues/1042) ✅（v2.0・`exclude_types[]` で実装） |
| **A-6** | Misskey の `reactionAcceptance` を尊重する | [#1044](https://github.com/pooza/capsicum/issues/1044) ✅ |
| **A-7** | `i/notifications` に `markAsRead: false` を明示する | [#1045](https://github.com/pooza/capsicum/issues/1045) ✅。⚠⚠ **裏返しが §13-5** |
| **A-8** | 「指名」投稿に `visibleUserIds` を送る | [#1043](https://github.com/pooza/capsicum/issues/1043) ✅ |

### A-5（Misskey のリノート解除）だけは「起票不要」で決着した — 残した地雷が 1 つある

⚠⚠ **この節は「決着済み」だが、消してはいけない地雷を 1 つ抱えている**（下の 🔴）。

**結論は「現状の実装は正しく、壊れてもいない」**（2026-08-31 確認・B にも入れない）。理由は Misskey の Note スキーマに**自己リノート済みを示すフラグが無い**ため（`renoteId` / `renote` / `renoteCount` だけ）で、`notes/unrenote` を足しても**トグルの状態が出せない**。詳細は archive 側。

⚠⚠ **ただし「安全」ではなく「たまたま安全」。**ここだけは本体に残す:

- `post_actions.dart` の `unrepeatPost(isOwnRenote ? outerPost : targetPost)` は、`isOwnRenote == false` の枝で **元投稿**を渡す。Misskey の `unrepeatPost` は `client.deleteNote(post.id)` なので、⚠⚠ **その枝に入ると元投稿そのものを削除しにいく**
- 到達しないのは `canUnrepeat = isOwnRenote || targetPost.reblogged` で、**Misskey の `toCapsicum` が `reblogged` を一度も立てない**から（既定 `false` のまま）
- 🔴 **Misskey 側で `reblogged` を埋める変更を入れた瞬間に、この枝が生きて元投稿の削除が起きる。**前提は `post_actions.dart` の doc コメントでしか表現されていない。**ガードを置くならここ**

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
| **通知のグループ化** | `GET /api/v2/notifications`（`group_key` 単位） | `i/notifications-grouped` | ✅ **実装済み**（2026-09-27・v2.0）。⚠ **束ねる種別は揃っていない** — Mastodon は favourite / reblog / follow を履歴全体で、Misskey は reaction / renote を 1 ページ内の連続したものだけ。罠は `tech-notes-api.md`「`GET /api/v2/notifications`（束ねた通知）の 4 つの罠」が正本 |
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

## 8. 次の一手（2026-08-31 の計画・[archive へ分けた](archive/api-gap-inventory-settled.md)）

⚠ **全部済んだ。**A 群は [v1.63](https://github.com/pooza/capsicum/milestone/77) で消化（[#1039](https://github.com/pooza/capsicum/issues/1039) / [#1040](https://github.com/pooza/capsicum/issues/1040) / [#1041](https://github.com/pooza/capsicum/issues/1041) / [#1042](https://github.com/pooza/capsicum/issues/1042)）、B 群は §4 のとおり v2.0 で全件起票済み。**起票の行き先をなぜ専用枠にしたか**（稼働枠が外部要因ベースで、棚卸し由来を入れると基準が割れる）は archive 側に残してある。

⚠ **v1.63 は「内部由来を入れてよい枠」ではなかった。**#993 の分類 A として明示的に拾うと決めたものだけが入る枠で、#1034 / #1035 / #1038 は移送しない、が同時に決まっている。

## 9–10. 層②③ 第 1 巡の結果（2026-08-31）→ [archive へ分けた](archive/api-gap-inventory-settled.md)

⚠ **2026-10-02 に分けた。**本体が 1 回で読める上限（60KB）へ貼り付いたため、**全件起票済みで決着した第 1 巡の詳細**を [`archive/api-gap-inventory-settled.md`](archive/api-gap-inventory-settled.md) へ移した（[#1184](https://github.com/pooza/capsicum/issues/1184) の規約「budget を足して先送りせず、その回に削るか分ける」）。

**結論だけ 1 行ずつ残す**（詳細・測り方・entity 別の未読フィールド一覧は archive 側）:

| | 内容 | 行き先 |
| --- | --- | --- |
| **9-1 ★** | Misskey の `reactionAcceptance` を読んでおらず、リアクションが**無言で ❤️ に差し替わる** | [#1044](https://github.com/pooza/capsicum/issues/1044) |
| **9-2 ★** | `i/notifications` の `markAsRead` の既定が `true` で、**取得しただけで WebUI の未読が消える** | [#1045](https://github.com/pooza/capsicum/issues/1045)。⚠⚠ **裏返しが §13-5** |
| **9-3 ★** | 通知の種別フィルタは両 SNS に揃っている（`includeTypes` / `excludeTypes`）。Mastodon の `supported_types` も未使用 | [#1042](https://github.com/pooza/capsicum/issues/1042) に反映 |
| **9-4 ★** | `tags` は Misskey も返している（両 SNS ともサーバーの正規化済みタグを使っていない） | [#1056](https://github.com/pooza/capsicum/issues/1056) |
| **9-5** | `notes/timeline` の `withRenotes` / `allowPartial` ほかが未使用 | 小粒・未起票 |
| **9-6** | 層③ の entity 別の母数と未読フィールド（Misskey Note 35/24・User 100/32・Mastodon 8 entity） | ⚠ **表は archive 側。**添付の `meta` / `blurhash` は [#1186](https://github.com/pooza/capsicum/issues/1186) |
| **10-1 ★★** | Misskey の「指名」投稿が、**新規投稿だと誰にも届かない**（`visibleUserIds` 未送信） | [#1043](https://github.com/pooza/capsicum/issues/1043) |
| **10-2〜10-4** | `notes/create` / タイムライン系 / `drive/files/create` の未使用パラメータ | 小粒・未起票 |

⚠ **§9-6 の未読フィールド表は次の棚卸しの母数そのもの**なので、層③ を続けるときは archive 側を開くこと。

## 11. 未実施のまま残す範囲（→ [#1046](https://github.com/pooza/capsicum/issues/1046)）

「主要なものだけ進め、残りは別 Issue」という 2026-08-31 の判断に従って切り出した範囲。⚠⚠ **2026-10-02 に #1046 を一巡し終えたので、この節は履歴**になった。残りの行き先は下の表のとおり。

| 層 | 2026-08-31 時点の残り | いま |
| --- | --- | --- |
| Misskey ② | 113 経路のうち **109** | ✅ **chat 23 経路**（§12-5）+ **`lists` / `following` / `blocking` / `mute` / `drive`**（§14）を見終えた。残る `clips` / `antennas` / `channels` / `pages` / `flash` は **B の着手回に従属**（§12-6） |
| Misskey ③ | Note / User 以外の全 entity | ✅ `notification` / `drive-file` / `chat-*` / `emoji` / `role`（§12）。残る `channel` / `clip` / `antenna` / `page` / `flash` は **B の着手回に従属** |
| Mastodon ② | 主要 6 経路 + 通知 以外 | ✅ **全数**（§13・約 75 経路） |

⚠ **「見ていない」であって「無かった」ではない**という前提は正しかった。**第 1 巡の主要経路だけで ★ 5 件、続きで ★ 2 件（§12）、Mastodon ② で ★ 8 件 + Misskey ② で ★ 2 件（§13 / §14）。**⚠⚠ **いちばん「当たりは薄い」と見立てていた Mastodon ② が最も多く出た**（優先順位の案 4 = 最後尾）。**見立てで順序を決めても、薄いほうを落とさないこと。**

## 12. 層③ の続き 第 1 巡（2026-09-29・[#1046](https://github.com/pooza/capsicum/issues/1046) 優先順 1）

**Misskey ③ の `notification` / `drive-file`。**#1046 の「優先順位の案」1 に従って、母数の小さい 2 entity から入った。⚠ **前提どおり当たりがあった**（★ 2 件）。

### 測り方でつまずいた点（次に回す人へ）

⚠⚠ **JSON Schema のキーワードをフィールドと数えてしまう。**`properties` と `items` はスキーマの構文で、**entity のフィールドではない**ことが多い。素朴に `^\t*name: {` を拾うと両方が「未読フィールド」に化ける。

- `notification` の `items` / `properties` は**すべてスキーマ構文**（配列要素の定義）。⚠ **偽陽性**
- `drive-file` の `properties` は**本物のフィールド**（`width` / `height` / `orientation` / `avgColor` を入れ子で持つ）

→ **入れ子の中身まで開いて、型が `object` のものは必ず中を見る。**

### 12-1. ★ 添付のプレースホルダ情報を**両 SNS とも 1 つも読んでいない**

| | サーバーが返すもの | capsicum |
| --- | --- | --- |
| Misskey `drive-file` | `blurhash` / `properties.width` / `properties.height` / `properties.avgColor` | ❌ **どれも読んでいない** |
| Mastodon `MediaAttachment` | `blurhash` / `meta.original.width` ほか | ❌ **同上**（`mastodon/` 配下でも 0 ヒット） |

`Attachment`（`capsicum_core`）は `id` / `type` / `url` / `previewUrl` / `description` / `name` / `filePath` / `mimeType` / `sensitive` / `folderId` だけで、**縦横比を持つ入れ物が無い**。

⚠ **結果として、読み込み前の高さが決まらない。**画像が届いた瞬間にタイムラインが伸び縮みする（レイアウトシフト）。⚠ **添付のある投稿すべてに毎回効く**ので、頻度は層③ の中で最大。

⚠ **これは「壊れている」ではなく「捨てている」型。**#993 の層②③ が全部 bug だったのとは性質が違い、**品質側の当たり**。

### 12-2. ★ 通知の**種別固有フィールド**を読んでいない（[#1177](https://github.com/pooza/capsicum/issues/1177) の裏返し）

`misskey/extensions.dart` の `MisskeyNotification.toCapsicum` が読むのは **`id` / `type` / `createdAt` / `user` / `note` / `reaction` / `reactions` / `achievement` / `users`** だけ。

⚠⚠ **#1177 で種別名は正しく出るようになったが、その種別の中身は空のまま**という組み合わせになっている:

| 種別 | 捨てているフィールド | 何が出せないか |
| --- | --- | --- |
| `roleAssigned` | `role` | **どのロールが付いたか** |
| `exportCompleted` | `exportedEntity` / `fileId` | **書き出したファイルへの導線**（何を書き出したかも） |
| `scheduledNotePostFailed` | `noteDraft` | ⚠ **どの予約投稿が失敗したか**。#1177 は「失敗した」と読めるところまで |
| `chatRoomInvitationReceived` | `invitation` | **招待に応じる導線** |
| `followRequestAccepted` | `message` | 承認時にサーバーが添えたメッセージ |
| `app` | `body` / `header` / `icon` | ⚠ **アプリ通知の本文そのもの**（見出しだけになる） |

⚠ **`userId` も読んでいないが、これは `user.id` と重複**なので当たりではない。

#### ✅ 決着（2026-10-01・[#1187](https://github.com/pooza/capsicum/issues/1187)・出荷済み）

**6 種類とも読むようにした。**入れ物は [#1084](https://github.com/pooza/capsicum/issues/1084) の `severance` / `moderationWarning` と同じ「種別ごとに型付きのフィールドを 1 つ」。⚠ **`app` だけ fallback（`fallbackTitle` / `fallbackBody`）に載せた** —— #1177 が `app` を `misskeyNotificationTypeMap` に入れないと決めた判断を崩さないため。⚠ **判断の詳細・罠（`exportCompleted` は `drive/files/show` に 1 往復・`scheduledAt` は epoch ミリ秒の int）は [archive](archive/api-gap-inventory-settled.md) 側。**

### 12-3. drive-file のその他（小粒）

`md5`（重複検出）/ `size`（ファイルサイズ表示）/ `folder`（親フォルダの実体）を読んでいない。⚠ **`folderId` は `Attachment` に入れ物があるのに、Misskey のレスポンスからは読んでいない。**

### 12-4. 起票

- **12-1 → [#1186](https://github.com/pooza/capsicum/issues/1186)**（両 SNS・縦横比とプレースホルダ）
- **12-2 → [#1187](https://github.com/pooza/capsicum/issues/1187)**（通知の種別固有フィールド・#1177 の続き）
- **12-3 は起票しない。**⚠ 単体では実害が無く、必要になった画面（ドライブ・アップロード）を触る回に一緒に見るほうが安い

### 12-5. chat 系（#1046 優先順 2）— ⚠ **層② / 層③ は取りこぼし 0 件**

**#1046 の優先順位の案 2（Misskey ② の chat 系）。**capsicum は **23 経路**を呼んでおり、⚠ **「14 経路」という #1046 の見積もりより多い**（`rooms/invitations/*` の 4 本を含む）。

| 層 | 結果 |
| --- | --- |
| **② パラメータ** | ✅ **取りこぼし無し。**`user-timeline` / `room-timeline` / `history` / `create-to-user` / `create-to-room` / `rooms/update` / `rooms/mute` / `rooms/members` とも、送れるものは送っている |
| **③ entity** | ✅ **取りこぼし無し。**`chat-room` は **8/8 一致**。`chat-message` の未読は `fileId` / `fromUserId` / `toUserId` の 3 つだけで、**いずれも入れ子（`file.id` / `fromUser.id` / `toUser.id`）と重複** |
| **① 経路** | ⚠ **2 本呼んでいない**（下） |

⚠ **`sinceDate` / `untilDate`（日付ページング）は送っていないが、当たりではない。**capsicum は ID ページング（`sinceId` / `untilId`）を使っており、**同じことが達成できる**。

⚠⚠ **「見ていない」が「無かった」に変わった範囲。**chat は #248 で実装した機能で、**パラメータの取りこぼしが体験に直結しやすい**という #1046 の見立てだったが、**実際には綺麗だった**。次に回す人はここを再走しなくてよい。

#### 呼んでいない 2 本

- **`chat/messages/search`**（`query` / `limit` / `userId` / `roomId`）— ⚠ **capsicum にメッセージ検索の導線が無い**（chat 系の画面は 8 つあるが検索は無し）。→ [#1188](https://github.com/pooza/capsicum/issues/1188)
- **`chat/messages/show`**（単一メッセージの取得）— ⚠ **当たりではない。**プッシュのタップはスレッドを開く形（#440）なので、単一メッセージを引く必要が無い

### 12-5-2. `emoji` / `role` entity — ⚠ 当たり無し（小粒が 2 つ）

**`EmojiSimple`**: ✅ **7/7 一致**。⚠ **この回（2026-09-29）に [#1081](https://github.com/pooza/capsicum/issues/1081) で `isSensitive` / `localOnly` / `roleIdsThatCanBeUsedThisEmojiAsReaction` を足したばかり**なので、それ以前は 4/7 だった。

**`RoleLite`**: 8 つのうち **5 つ読んでいる**（`id` / `name` / `color` / `iconUrl` / `isAdministrator`）。未読は 3 つ:

| 未読 | 判定 |
| --- | --- |
| `displayOrder` | ⚠ **当たりではない。**サーバーが `UserEntityService` で**降順にソートして返す**ので、capsicum が順序をそのまま使えば表示順は保たれる |
| `isModerator` | ⚠ **当たりではない。**capsicum が特別扱いするのは管理者だけ（アイコンの差し替え）で、モデレータは**素のロールチップとして名前・色・アイコンつきで出る**。表示の選択であって欠落ではない |
| `description` | 小粒。ロールチップに説明を出す導線が無い。⚠ **単体では起票しない** |

⚠ **`isAdmin` の出どころは 2 つある**（`role.isAdministrator` **または**モロヘイヤ由来の `adminRoleIds`）。**モロヘイヤ非導入サーバーでも `isAdministrator` で判定できている**ので、ここに穴は無い。

### 12-6. 残り（第 2 巡以降）

**この回で済んだ**: `notification` / `drive-file`（12-1・12-2）/ `chat-*`（12-5）/ `emoji` / `role`（12-5-2）。

**残り**: `channel` / `clip` / `antenna` / `page` / `flash` の各 entity と、Misskey ② の残り経路・Mastodon ② の残り。

⚠⚠ **残っている entity は全部「分類 B と母数が重なる」側に寄った。**`clip` / `antenna` / `channel` は [#1050](https://github.com/pooza/capsicum/issues/1050) / [#1051](https://github.com/pooza/capsicum/issues/1051) / [#1052](https://github.com/pooza/capsicum/issues/1052)、`page` は [#1073](https://github.com/pooza/capsicum/issues/1073)、`flash` は [#1074](https://github.com/pooza/capsicum/issues/1074) で、いずれも**作成・編集 UI を作る回に同じコードを読む**。→ **単独で巡回する価値が薄くなったので、B を着手する回に一緒に見る**（#1046 の優先順位の案 3 を、残り全体へ広げた判断）。

**単独で残っているのは Mastodon ② の残りだけ**だが、⚠ **層① で「フォーク固有 API なし・当たりは薄い」と分かっている**（優先順位の案 4）。

## 13. Mastodon ② の残り（2026-10-02・[#1046](https://github.com/pooza/capsicum/issues/1046) 優先順 4）

**#1046 の「優先順位の案」4。**「Mastodon 側は層① で*フォーク固有 API なし・当たりは薄い*と分かっているので最後でよい」という見立てで後回しにしてあったが、⚠⚠ **薄くなかった**（★ 8 件・うち 2 件は層① の取りこぼし）。

⚠ **母数の取り方を変えた。**§1 の表には「主要 6 経路 + 通知」と書いてあるが、⚠⚠ **どの 6 本だったかが文書に残っていない。**そこで **capsicum が呼ぶ Mastodon の全経路（約 75 本）を洗い出して送信パラメータを突き合わせた**（既見のぶんも含む。再確認は安い）。正本は `packages/capsicum_backends/lib/src/mastodon/client.dart` と、フォークの `app/controllers/api/` / `config/routes/api.rb`（v4.7.3-bshockdon）。

⚠ **これで層② は両 SNS とも全数になった**（§1 の実施範囲の表を更新済み）。

### 13-1. ★★ 一覧が黙って打ち切られている 3 経路（ページングも `limit` も送っていない）

| 経路 | サーバーの既定 | 見えなくなるもの |
| --- | --- | --- |
| `GET /api/v1/lists/:id/accounts` | **40 件**（`DEFAULT_ACCOUNTS_LIMIT`） | **リストのメンバー 41 人目以降。**⚠ **`limit=0` を送ると全件**（`Api::V1::Lists::AccountsController#unlimited?`） |
| `GET /api/v1/scheduled_statuses` | **20 件**（`DEFAULT_STATUSES_LIMIT`） | 21 件目以降の予約投稿 |
| `GET /api/v2/search` | **20 件**（`Api::V2::SearchController::RESULTS_LIMIT`） | 検索結果の 21 件目以降。⚠ `offset` でページングする |

⚠⚠ **Misskey 側は打ち切られないので非対称。**リストのメンバーは `showList` の `userIds` を全件読み（`misskey/adapter.dart:1407`）、検索は `untilId` 送りで続く。**Mastodon のアカウントだけ画面が尻切れになる。**

⚠ **画面側に追加読み込みが無いので回避もできない。**`list_members_screen.dart:34` は `getListAccounts(listId)` を 1 回だけ、`search_screen.dart:112` は `adapter.search(query)` を 1 回だけ呼ぶ。⚠⚠ **検索画面は notestock（全文検索）だけ `Link` ヘッダで追加読み込みしている**（`_searchNotestock` の `nextUrl`）—— **同じ画面の中で片方にだけページングがある**形。

### 13-2. ★ 通報がリモートのサーバーへ転送されない

`POST /api/v1/reports` の permit は `account_id` / `comment` / `category` / `forward` / `forward_to_domains` / `status_ids` / `collection_ids` / `rule_ids`。capsicum が送るのは `account_id` / `status_ids` / `comment` の 3 つだけ。

- ⚠⚠ **`forward` を送らないので、他サーバーの利用者を通報しても相手のサーバーには届かない。**自分のサーバーのモデレータにしか伝わらない。WebUI は転送の可否を尋ねる
- `category`（`spam` / `legal` / `violation` / `other`）と `rule_ids`（違反したサーバールールの指定）も未使用。⚠ **モデレータが分類し直す手間になる**

### 13-3. ★★ プッシュの購読種別が 7 つしかない（起票後に見立てを訂正）

⚠⚠ **起票時は「フォロー申請だけ」と書いたが、数え直したら 10 種が未購読だった**（[#1204](https://github.com/pooza/capsicum/issues/1204) のコメントが正本）。Mastodon 4.7 の `Notification::PROPERTIES` は **17 種**、capsicum の購読は **7 種**、⚠ **画面（`notification_type_display.dart`）は 30 種を扱っている**。

🔴 未購読のうち重いもの: **`moderation_warning`**（制限・凍結の予告）/ **`admin.report`**（通報が来た・pooza はプリセット 5 台の運営者）/ **`quote`**（引用された・`baseline: true` で全利用者対象）/ `severed_relationships`。⚠ **どれも #1084 / #1072 で画面には出している。**

✅ **直しは軽い**（キーを足すだけ・移行不要）。`registerAllAccounts` が splash で毎起動走り（`splash_screen.dart:89`）、Mastodon の `create` は既存を destroy して作り直すので、**更新後の初回起動で反映される**。

以下は起票時に書いた内容（フォロー申請の部分）。

`POST /api/v1/push/subscription` の `data[alerts]` は **`Notification::TYPES` 全種**を受ける（`params.expect(data: [:policy, alerts: Notification::TYPES])`・⚠ `TYPES` は `PROPERTIES.keys` なので**版で増える**）。capsicum が立てているのは `mention` / `favourite` / `reblog` / `follow` / `poll` / `status` / `update` の 7 つで、⚠⚠ **`follow_request` が無い**。

→ **[#1040](https://github.com/pooza/capsicum/issues/1040) でフォロー申請を処理できるようにしたのに、申請が来たことはプッシュで届かない。**鍵アカウントでは申請に気付く手段が「自分で画面を見る」しかない。

⚠ `data[policy]`（`all` / `followed` / `follower` / `none`）も未使用。**誰からの通知をプッシュするか**をサーバー側で切れる。

### 13-4. ★ 未読数をサーバーに訊いていない（両 SNS 対称）

`GET /api/v1/notifications/unread_count` と `GET /api/v2/notifications/unread_count` が実在する（既定 100・上限 1,000）。capsicum は**どちらも呼んでおらず、クライアント側で数えている**。

⚠⚠ **Misskey の `unreadNotificationsCount`（archive §9-6 で未読と記録）と同じ形**で、**両 SNS ともサーバーが持っている値を使っていない**。

⚠ **これは層① の取りこぼし**（経路そのものを呼んでいない）。**層② の目で見たから出た** —— 通知の経路のパラメータを調べていて `collection do get :unread_count end` に気付いた。⚠ **母数の取り方を変えると別のものが見える**という [#1077](https://github.com/pooza/capsicum/issues/1077) の主張が、API 基準の内側でも成り立った。

### 13-5. ★ Misskey だけ通知の既読がサーバーへ返らない（§9-2 の裏返し）

⚠⚠ **[#1045](https://github.com/pooza/capsicum/issues/1045) で直した穴の反対側。**あちらは「取得しただけで WebUI の未読が消える」を止めるため `markAsRead: false` を明示した。ところが capsicum には**既読を返す経路が Misskey 側に無い**:

| | 既読を返す手段 | capsicum |
| --- | --- | --- |
| Mastodon | `POST /api/v1/markers`（`notifications.last_read_id`） | ✅ **送っている**（`mastodon/adapter.dart:1483`） |
| Misskey | `notifications/mark-all-as-read` / `notifications/flush` | ❌ **どちらも未呼び出し** |

⚠⚠ **`MarkerSupport` が `MastodonAdapter` にしか mixin されていない**（`misskey/adapter.dart:102` の mixin 一覧に無い）。

→ **capsicum だけで通知を読んでいる Misskey 利用者は、WebUI の未読バッジが永久に消えない。**⚠ #1045 で「黙って消える」を止めたぶん、**反対側（永久に消えない）が残った**。⚠ **capsicum の画面では観測できない**（§9-2 と同じ形で、他クライアントの状態の話）。

### 13-6. ★ DM（会話）も既読にならない

`GET /api/v1/conversations` は会話ごとに `unread` を返し、`POST /api/v1/conversations/:id/read` / `unread` / `DELETE` がある。capsicum は **index だけ**を呼び、`last_status` を取り出してタイムラインとして描いている（`mastodon/adapter.dart:417`・`TimelineType.directMessages`）。

- ⚠ **`unread` を読んでいない**ので、capsicum 自身も「未読の会話」を区別できない
- ⚠⚠ **既読を返さない**ので、13-5 と同じく **WebUI の DM 未読が消えない**
- 会話の削除（`DELETE`）も無い

### 13-7. ★ スレッド（会話）のミュートが両 SNS にあるのに無い

| | 経路 |
| --- | --- |
| Mastodon | `POST /api/v1/statuses/:id/mute` / `POST /api/v1/statuses/:id/unmute` |
| Misskey | `notes/thread-muting/create` / `notes/thread-muting/delete` |

⚠ **§4（分類 B）の「フィルタ（キーワードミュート）= [#1047](https://github.com/pooza/capsicum/issues/1047)」の行に Misskey の `notes/thread-muting/*` が混ざっている**が、あれは**キーワードミュートの枠**。スレッドのミュートは**投稿のメニューから 1 スレッドだけ黙らせる**別の道具で、⚠ **Mastodon 側の経路は文書のどこにも出ていない。**

⚠⚠ **`notes/thread-muting/create` は Misskey 版追従の表で「none（capsicum 無関係・呼んでいない）」と判定されている**（`misskey-capsicum-api-watch.md:153`）。⚠ **あれは「その版で変わったか」の判定**であって棚卸しの判定ではない。**「呼んでいない」は落とす理由ではなく見る理由**なので、**追従表の `none` を棚卸しの結論として読まないこと**（この取り違えで 1 件落ちていた）。

### 13-8. ★ リモートのみの連合 TL / タグの OR・除外

- **`GET /api/v1/timelines/public` の `remote`** — [#1077](https://github.com/pooza/capsicum/issues/1077) からの引き継ぎ。`PERMITTED_PARAMS = %i(local remote limit only_media)`。⚠ capsicum は `local` しか送らないので**リモートのみの連合 TL が出せない**。`only_media` も未使用
- **タグ TL の `any[]` / `none[]`** — `TagFeed.new(@tag, ..., any:, all:, none:, local:, remote:, only_media:)`。capsicum のタグセットは **`all[]`（AND）だけ**で、⚠⚠ **OR 検索と除外ができない**。⚠ **タグセットは実況の中心道具**なので効き目が大きい

### 13-9. ★ 既定の公開範囲などを capsicum から変えられない

`PATCH /api/v1/accounts/update_credentials` は `source[privacy]` / `source[sensitive]` / `source[language]` / `source[quote_policy]` を受ける（`Api::V1::Accounts::CredentialsController#user_params`）。capsicum は送っていない。

⚠⚠ **[#1185](https://github.com/pooza/capsicum/issues/1185) / [#1194](https://github.com/pooza/capsicum/issues/1194) の裏返し。**2026-10-01 に**読む側**（サーバーの既定を起動時の値で固定せず毎回読む）を直したが、**書く側が無い**ので **capsicum から既定を変えられない**（WebUI へ行くしかない）。

⚠ 同じ permit の `bot` / `hide_collections` / `indexable` / `attribution_domains` / `avatar_description` / `header_description` も未使用。⚠ **`avatar_description` / `header_description` はアイコンとヘッダーの ALT** なので、[#121](https://github.com/pooza/capsicum/issues/121) で添付の ALT を扱えるようにした流れと揃っていない。

### 13-10. 「作成はできるが変えられない」3 件（→ [#1077](https://github.com/pooza/capsicum/issues/1077) §8 と同じ当たり）

⚠ **WebUI 基準（#1077）の層② 変種と同じものが API 基準でも出た。**判断は #1077 側（`webui-gap-inventory.md` §8）に寄せ、ここでは経路だけ記録する。

| 項目 | 経路 | 要点 |
| --- | --- | --- |
| 予約投稿の時刻変更 | `PUT /api/v1/scheduled_statuses/:id` | ⚠ **permit は `scheduled_at` だけ。**本文・タグの編集は標準 API では**できない**ので、モロヘイヤ経由にしてあるのは正しい |
| 引用の撤回 | `POST /api/v1/statuses/:id/quotes/:id/revoke` | 引用一覧（[#1072](https://github.com/pooza/capsicum/issues/1072)）はあるが撤回できない |
| 引用ポリシーの事後変更 | `PUT /api/v1/statuses/:id/interaction_policy` | capsicum は投稿時に `quote_approval_policy` を送るだけ |
| リストの返信方針・排他 | `POST` / `PUT /api/v1/lists` の `replies_policy` / `exclusive` | ⚠⚠ **archive §9-6 で「List entity の `replies_policy` / `exclusive` が未読」と出ていたのと同じ穴の両側。**`exclusive`（リストに入れた人をホームから隠す）は**ホーム TL の見え方を変える** |

### 13-11. 小粒（単体では起票しない）

| 項目 | 中身 |
| --- | --- |
| `Idempotency-Key` ヘッダ | 投稿の冪等化（サーバーは `request.headers['Idempotency-Key']` を読む）。⚠ **429 の自動再送では二重投稿にならない**（`RateLimitInterceptor` は **429 のときだけ**再送し、429 はサーバーが作っていない）。効くのは**二度押しと手動の再試行** |
| `POST /api/v1/statuses` の `allowed_mentions` | 返信で意図しない相手を巻き込む事故を止める安全弁（送ると `UnexpectedMentionsError` → 422 で止まる） |
| メディアの `focus` / `thumbnail` | フォーカルポイントと動画のカスタムサムネイル（`POST /api/v2/media` / `PUT /api/v1/media/:id` / `media_attributes`）。⚠ `description` は送っている |
| `DELETE /api/v1/media/:id` | 投稿前に外した添付がサーバーに残る |
| `GET /api/v1/accounts/:id/statuses` の `exclude_reblogs` | プロフィールで「リノートを除く」。⚠ `tagged` は分類 C 既判定 |
| `GET /api/v1/accounts/search` の `following` / `offset` | フォロー中だけに絞る / ページング |
| `GET /api/v1/notifications` の `account_id` / `include_filtered` | 「この人からの通知だけ」／通知ポリシーで振り分けたぶんも含める |
| `GET /api/v1/statuses?id[]=` | 複数投稿の一括取得 |
| 通知の個別削除・全消し | `POST /api/v1/notifications/:id/dismiss` / `clear`、Misskey の `notifications/flush`。⚠ **13-4 / 13-5 と同じ通知画面**なので、あちらを触る回に一緒に見る |
| 「通知だけは受け取るミュート」 | 下の 13-12 を参照 |

### 13-12. 当たりではなかったもの（「見ていない」→「無かった」に変わった範囲）

⚠ **次に回す人がここを再走しなくてよいように残す。**

| 項目 | なぜ当たりではないか |
| --- | --- |
| **`POST /api/v1/accounts/:id/mute` の `notifications`** | ⚠⚠ **送らないほうが安全側。**`truthy_param?` は未指定で `false` ではなく **`nil`** を返し（`ActiveModel::Type::Boolean#cast(nil)`）、`Account#mute!` が **`notifications = true if notifications.nil?`** で**通知もミュート**にする（`concerns/account/interactions.rb:78`）。capsicum は `duration` を送っており、こちらは正しい。⚠ 欠けているのは「**通知だけは受け取るミュート**」という選択肢で、小粒 |
| 一覧系の `since_id` / `min_id` | capsicum は `max_id` の下りページングで統一し、前方（新しい側）はストリーミングで埋めている |
| `GET /api/v1/accounts/relationships` の `with_suspended` | 凍結アカウントの関係も返す。capsicum は凍結を特別扱いしていないので今は効かない。⚠ **Misskey の `isSuspended` / `isSilenced` / `isDeleted` 未読（archive §9-6）と同じ論点**なので、**判断はそちらと一緒に** |
| `GET /api/v1/announcements` | **ページングが無い**（`Announcement.published.chronological` を全件返す）。送るものが無い |
| `GET /api/v1/lists` | 同じく全件（`List.where(account: current_account).all`） |
| `GET /api/v1/statuses/:id/context` | パラメータを取らない |
| `GET /api/v2/notifications/:group_key/accounts` | `expand_accounts` を既定の `full` にしているのでアカウントは本体に入っており、別途引く必要が無い |
| `POST /api/v1/statuses` の `scheduled_at` | ✅ **送っている**（`scheduleStatus`） |
| `GET /api/v1/timelines/home` / `list` / `tag` のページング | ✅ `max_id` / `since_id` / `limit` を送っている |

### 13-13. 起票（2026-10-02）

**★ を 9 件起票した。**⚠ **チェックリスト型のアンブレラにしない**方針どおり、1 件 = 1 Issue。

| | 内容 | Issue | 種別 |
| --- | --- | --- | --- |
| 13-1 | 一覧が既定件数で黙って打ち切られる 3 経路 | [#1202](https://github.com/pooza/capsicum/issues/1202) | `bug` |
| 13-2 | 通報がリモートへ転送されない | [#1203](https://github.com/pooza/capsicum/issues/1203) | `bug` |
| 13-3 | フォロー申請のプッシュが来ない | [#1204](https://github.com/pooza/capsicum/issues/1204) | `bug` |
| 13-5 | Misskey の通知既読が返らない | [#1205](https://github.com/pooza/capsicum/issues/1205) | `bug` |
| 13-6 | DM が既読にならず削除もできない | [#1206](https://github.com/pooza/capsicum/issues/1206) | `bug` |
| 13-4 | 未読数をサーバーに訊いていない | [#1207](https://github.com/pooza/capsicum/issues/1207) | `enhancement` |
| 13-7 | スレッドのミュート | [#1208](https://github.com/pooza/capsicum/issues/1208) | `enhancement` |
| 13-8 | タグの OR・除外 / リモートのみの連合 TL | [#1209](https://github.com/pooza/capsicum/issues/1209) | `enhancement` |
| 13-9 | 既定の公開範囲などを書けない | [#1210](https://github.com/pooza/capsicum/issues/1210) | `enhancement` |

⚠ **マイルストーンは付けていない。**棚卸し由来 13 件の枠割りは pooza の判断で、⚠ **v2.1〜v2.5 は「1 枠 1 大更新」で設計されている**ため（`docs/roadmap.md` 2026-09-30）。

⚠ **13-10 / 13-11 / 13-12 は起票しない。**13-10 は #1077 側で起票（[#1211](https://github.com/pooza/capsicum/issues/1211) / [#1212](https://github.com/pooza/capsicum/issues/1212) / [#1213](https://github.com/pooza/capsicum/issues/1213)）、13-11 は**必要になった画面を触る回に一緒に見る**（§12-3 と同じ扱い）、13-12 は**当たりではなかった記録**。

### 順序の制約（起票した 9 件のうち 2 組）

- **[#1205](https://github.com/pooza/capsicum/issues/1205)（Misskey の既読）→ [#1207](https://github.com/pooza/capsicum/issues/1207)（未読数）。**⚠⚠ 逆にすると、**サーバー値へ寄せた瞬間に Misskey のバッジが減らなくなる**（capsicum が読んだぶんが既読にならないため）
- **[#1079](https://github.com/pooza/capsicum/issues/1079)（端末側設定との優先関係）→ [#1210](https://github.com/pooza/capsicum/issues/1210)（既定を書く側）。**同じ論点に触れる

## 14. Misskey ② の残り（2026-10-02・B に寄せていない経路だけ）

**§12-6 で「残りは B を着手する回に一緒に見る」と決めたが、⚠ その判断が当たるのは B 系の経路だけ**（`clips` / `antennas` / `channels` / `pages` / `flash`）。§11 の一覧に混ざっていた **`lists` / `following` / `blocking` / `mute` / `drive` は B ではなく実装済みの機能**なので、§13 と同じ回に見た（**母数が重なるから同じ回に回す**、が #1046 / #1077 の前提）。

⚠ **狙いは対称性の確認。**§13 で Mastodon のリスト・フォロー関係に当たりが出たので、**同じ穴が Misskey 側にあるかを突き合わせた**。

### 14-1. ★ リストを公開できない（Mastodon の `replies_policy` / `exclusive` と同族）

`users/lists/update` の paramDef は `listId` / `name` / **`isPublic`**。capsicum が送るのは `listId` / `name` だけ（`misskey/client.dart:1444`）。

⚠⚠ **両 SNS で「リストを作って名前を変えてメンバーを出し入れする」までは揃っているのに、リストの設定項目だけが揃って触れない**:

| | 触れない設定 |
| --- | --- |
| Mastodon | `replies_policy`（リスト TL に返信を出すか）/ `exclusive`（リストに入れた人をホームから隠す） |
| Misskey | `isPublic`（リストを公開するか） |

⚠ **`users/lists/create` は `name` のみ**なので、作成時には送るものが無い（当たりではない）。公開設定は**作ったあとに変える**形。

### 14-2. ★ フォロー時に「返信も流す」を選べない

`following/create` の paramDef は `userId` / **`withReplies`**。capsicum は `userId` だけ（`misskey/client.dart:281`）。

⚠ **これはフォロー関係ごとのフラグ**で、archive §9-6 で「→ #992 へ」に入れた `User.withReplies`（自分の既定）とは別物。⚠ **Mastodon のリストの `replies_policy` と同じ「返信をどこまで流すか」の族**なので、14-1 と一緒に判断するのが自然。

### 14-3. 小粒（単体では起票しない）

| 項目 | 中身 |
| --- | --- |
| `drive/files/update` の `isSensitive` | ⚠ **アップロード時には送っている**（`drive/files/create`・`misskey/client.dart:360`）。できないのは**あとから切り替える**ことだけ。⚠ Misskey はセンシティブが**ファイル単位**（Mastodon は投稿単位）なので、ドライブ画面を触る回に一緒に見る |

### 14-4. 当たりではなかったもの

| 項目 | なぜ |
| --- | --- |
| `mute/create` の `expiresAt` | ✅ **送っている**（`muteUser(userId, {int? expiresAt})`）。⚠ **Mastodon の `duration` と対称**で、期限付きミュートは両 SNS で通る |
| `mute/list` / `blocking/list` のページング | ✅ `untilId` / `limit` を送っている（⚠ カーソルは関係レコードの id という罠つきで実装済み・#1039） |
| `drive/files` / `drive/folders` のページング | ✅ `folderId` / `sinceId` / `untilId` / `limit` / `type` を送っている |
| `drive/files/update` の `name` / `folderId` / `comment` | ✅ 送っている（⚠ `comment` を**消す**には明示的な null が要る罠は #1005 で解決済み） |
| `following/requests/*` | ✅ `list` / `accept` / `reject` を実装済み（#1040） |

### 14-5. これで層② は閉じた

| 層 | Mastodon | Misskey |
| --- | --- | --- |
| ② パラメータ | ✅ **全数**（§13・capsicum が呼ぶ約 75 経路） | ✅ **B 系以外は全数**（§12-5 の chat 23 経路 + 本節の `lists` / `following` / `blocking` / `mute` / `drive`）。⚠ 残るのは `clips` / `antennas` / `channels` / `pages` / `flash` で、**作成・編集 UI を作る回に同じコードを読む**（§12-6 の判断） |

⚠ **「単独で残っているのは Mastodon ② の残りだけ」（§12-6）はこれで解消した。**層② で単独に巡回する価値のある範囲は無くなり、残りは分類 B の着手に従属する。
