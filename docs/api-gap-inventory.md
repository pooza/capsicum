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

結果は §9–10（第 1 巡）・§12（層③ の続き）・§13（Mastodon ②）・§14（Misskey ②）。⚠ **どれも結論だけを本体に残し、詳細は archive 側**（第 1 巡 → [api-gap-inventory-settled.md](archive/api-gap-inventory-settled.md) / 第 2 巡 → [api-gap-inventory-round2-settled.md](archive/api-gap-inventory-round2-settled.md)）。

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

## 11. 未実施のまま残す範囲（→ [#1046](https://github.com/pooza/capsicum/issues/1046)）→ [archive へ分けた](archive/api-gap-inventory-round2-settled.md)

「主要なものだけ進め、残りは別 Issue」という 2026-08-31 の判断に従って切り出した範囲。⚠⚠ **2026-10-02 に #1046 を一巡し終えたので、この節は履歴**になった。**いまの到達点は §1 の実施範囲の表**が正本で、残っているのは `clips` / `antennas` / `channels` / `pages` / `flash` だけ（分類 B の着手回に従属・§12-6）。

⚠ **「見ていない」であって「無かった」ではない**という前提は正しかった。**第 1 巡の主要経路だけで ★ 5 件、続きで ★ 2 件（§12）、Mastodon ② で ★ 8 件 + Misskey ② で ★ 2 件（§13 / §14）。**⚠⚠ **いちばん「当たりは薄い」と見立てていた Mastodon ② が最も多く出た**（優先順位の案 4 = 最後尾）。**見立てで順序を決めても、薄いほうを落とさないこと。**

## 12. 層③ の続き 第 1 巡（2026-09-29・[#1046](https://github.com/pooza/capsicum/issues/1046) 優先順 1）→ [archive へ分けた](archive/api-gap-inventory-round2-settled.md)

**Misskey ③ の `notification` / `drive-file` / `chat-*` / `emoji` / `role`。**母数の小さい entity から入って ★ 2 件。

**結論だけ 1 行ずつ残す**（測り方・entity 別の突き合わせ・当たりではなかった範囲は archive 側）:

| | 内容 | 行き先 |
| --- | --- | --- |
| **12-1 ★** | 添付のプレースホルダ情報（`blurhash` / 縦横比）を**両 SNS とも 1 つも読んでいない** → 読み込み時にタイムラインが伸び縮みする | [#1186](https://github.com/pooza/capsicum/issues/1186) |
| **12-2 ★** | 通知の**種別固有フィールド**（`role` / `exportedEntity` / `noteDraft` ほか 6 種）が未読で、[#1177](https://github.com/pooza/capsicum/issues/1177) の種別名だけが出ていた | [#1187](https://github.com/pooza/capsicum/issues/1187)。✅ **2026-10-01 に出荷済み** |
| **12-3** | `drive-file` の `md5` / `size` / `folder` | 小粒・未起票（画面を触る回に） |
| **12-5** | chat 系 23 経路は層②③ とも**取りこぼし 0 件**。① で `chat/messages/search` だけ未呼び出し | [#1188](https://github.com/pooza/capsicum/issues/1188) |
| **12-5-2** | `emoji` / `role` entity は**当たり無し**（`displayOrder` / `isModerator` はどちらも当たりではない理由つきで archive に記録） | — |

⚠ **測り方の罠**: JSON Schema の `properties` / `items` は**スキーマの構文**で、entity のフィールドとは限らない。素朴に拾うと偽陽性になる一方、`drive-file` の `properties` は**本物のフィールド**。→ **型が `object` のものは必ず中を開く**（詳細は archive）。

### 12-6. 残り（第 2 巡以降）

⚠ **この節は live な判断。**

**残り**: `channel` / `clip` / `antenna` / `page` / `flash` の各 entity と、Misskey ② の同名の経路。

⚠⚠ **残っている entity は全部「分類 B と母数が重なる」側に寄った。**`clip` / `antenna` / `channel` は [#1050](https://github.com/pooza/capsicum/issues/1050) / [#1051](https://github.com/pooza/capsicum/issues/1051) / [#1052](https://github.com/pooza/capsicum/issues/1052)、`page` は [#1073](https://github.com/pooza/capsicum/issues/1073)、`flash` は [#1074](https://github.com/pooza/capsicum/issues/1074) で、いずれも**作成・編集 UI を作る回に同じコードを読む**。→ **単独で巡回する価値が薄くなったので、B を着手する回に一緒に見る**（#1046 の優先順位の案 3 を、残り全体へ広げた判断）。

## 13. Mastodon ② の残り（2026-10-02・[#1046](https://github.com/pooza/capsicum/issues/1046) 優先順 4）→ [archive へ分けた](archive/api-gap-inventory-round2-settled.md)

「層① でフォーク固有 API なし・当たりは薄い」という見立てで最後尾に置いていたが、⚠⚠ **薄くなかった**（★ 8 件・うち 2 件は層① の取りこぼし）。

⚠ **母数の取り方を変えた。**§1 の表の「主要 6 経路 + 通知」は**どの 6 本だったかが残っていなかった**ので、**capsicum が呼ぶ Mastodon の全経路（約 75 本）を洗い出して送信パラメータを突き合わせた**。正本は `packages/capsicum_backends/lib/src/mastodon/client.dart` と、フォークの `app/controllers/api/` / `config/routes/api.rb`（v4.7.3-bshockdon）。

**結論だけ 1 行ずつ残す**（経路ごとの permit・サーバー側の既定値・当たりではなかった範囲は archive 側）:

| | 内容 | 行き先 |
| --- | --- | --- |
| **13-1 ★★** | 一覧 3 経路が既定件数で**黙って打ち切られる**（リストメンバー 40 / 予約投稿 20 / 検索 20・ページングも `limit` も送っていない）。⚠ **Misskey 側は打ち切られないので非対称** | [#1202](https://github.com/pooza/capsicum/issues/1202) `bug`・✅ v2.1 で実装（リストは `limit=0` / 予約投稿は `Link` を辿って全件 / 検索は種別ごとの「もっと読む」。⚠ **検索の `offset` は `type` と一緒でないと効かない**） |
| **13-2 ★** | 通報に `forward` を送っておらず、**リモートの利用者を通報しても相手のサーバーに届かない**（`category` / `rule_ids` も未使用） | [#1203](https://github.com/pooza/capsicum/issues/1203)（✅ v2.1 で `forward` を実装・`category` / `rule_ids` は未着手） `bug` |
| **13-3 ★★** | プッシュの購読種別が **7 / 17**（画面は 30 種扱っている）。🔴 重いのは `moderation_warning` / `admin.report` / `quote` / `severed_relationships`。✅ 直しはキーを足すだけ | [#1204](https://github.com/pooza/capsicum/issues/1204) `bug` |
| **13-4 ★** | 未読数を `notifications/unread_count` に訊かずクライアント側で数えている（**両 SNS 対称**）。⚠ **層① の取りこぼしで、層② の目で見たから出た** | [#1207](https://github.com/pooza/capsicum/issues/1207) `enhancement` |
| **13-5 ★** | Misskey だけ既読をサーバーへ返しておらず（`MarkerSupport` が `MastodonAdapter` にしか mixin されていない）、**WebUI の未読が永久に消えない**。⚠ [#1045](https://github.com/pooza/capsicum/issues/1045) の裏返し | [#1205](https://github.com/pooza/capsicum/issues/1205) `bug`・✅ v2.1 で実装（**一覧の先頭が見えたとき**に `mark-all-as-read`。⚠⚠ **取得では触らない**のは #1045 のまま ＝ 「取得では触らない・見たら返す」・2026-10-09 pooza） |
| **13-6 ★** | DM（会話）の `unread` を読まず既読も返さず、削除もできない | [#1206](https://github.com/pooza/capsicum/issues/1206)（✅ v2.1 で実装・DM を開いたら既読 / 投稿メニューから会話を削除。画面は投稿の列のまま） `bug` |
| **13-7 ★** | スレッド（会話）のミュートが**両 SNS に経路があるのに無い** | [#1208](https://github.com/pooza/capsicum/issues/1208) `enhancement` |
| **13-8 ★** | タグ TL の OR（`any[]`）・除外（`none[]`）とリモートのみの連合 TL（`remote`）が使えない。⚠ **タグセットは実況の中心道具** | [#1209](https://github.com/pooza/capsicum/issues/1209) `enhancement` |
| **13-9 ★** | `update_credentials` の書く側が無く、既定の公開範囲・アイコンの ALT などを capsicum から変えられない。⚠ [#1185](https://github.com/pooza/capsicum/issues/1185) / [#1194](https://github.com/pooza/capsicum/issues/1194) の裏返し | [#1210](https://github.com/pooza/capsicum/issues/1210) `enhancement` |
| **13-10** | 「作成はできるが変えられない」4 件（予約投稿の時刻 / 引用の撤回 / 引用ポリシー / リストの返信方針・排他） | [#1077](https://github.com/pooza/capsicum/issues/1077) 側で [#1211](https://github.com/pooza/capsicum/issues/1211) / [#1212](https://github.com/pooza/capsicum/issues/1212) / [#1213](https://github.com/pooza/capsicum/issues/1213) |
| **13-11** | 小粒 10 件（`Idempotency-Key` / `allowed_mentions` / メディアの `focus` / 通知の個別削除 ほか） | 未起票（必要になった画面を触る回に） |
| **13-12** | 当たりではなかった 10 件。⚠⚠ **`accounts/:id/mute` の `notifications` は「送らないほうが安全側」**（未指定は `nil` → サーバーが `true` に倒す） | — |

### 13-7 の方法論（版追従の表を棚卸しの判定に使わない）

⚠ **この節は live な判断。**他の docs から節番号で参照されている（[mastodon-capsicum-api-watch.md](mastodon-capsicum-api-watch.md) / [misskey-capsicum-api-watch.md](misskey-capsicum-api-watch.md)）。

⚠⚠ **`notes/thread-muting/create` は Misskey 版追従の表で「none（capsicum 無関係・呼んでいない）」と判定されていた。**⚠ **あれは「その版で変わったか」の判定**であって棚卸しの判定ではない。**「呼んでいない」は落とす理由ではなく見る理由**なので、**追従表の `none` を棚卸しの結論として読まないこと**（この取り違えで、両 SNS に経路があるスレッドのミュートが母数から 1 件落ちていた）。

### 順序の制約（起票した 9 件のうち 2 組）

⚠ **この節は live な判断。**

- **[#1205](https://github.com/pooza/capsicum/issues/1205)（Misskey の既読）→ [#1207](https://github.com/pooza/capsicum/issues/1207)（未読数）。**⚠⚠ 逆にすると、**サーバー値へ寄せた瞬間に Misskey のバッジが減らなくなる**（capsicum が読んだぶんが既読にならないため）
- **[#1079](https://github.com/pooza/capsicum/issues/1079)（端末側設定との優先関係）→ [#1210](https://github.com/pooza/capsicum/issues/1210)（既定を書く側）。**同じ論点に触れる

## 14. Misskey ② の残り（2026-10-02・B に寄せていない経路だけ）→ [archive へ分けた](archive/api-gap-inventory-round2-settled.md)

§11 の一覧に混ざっていた **`lists` / `following` / `blocking` / `mute` / `drive` は分類 B ではなく実装済みの機能**なので、§13 と同じ回に見た（**母数が重なるから同じ回に回す**、が #1046 / #1077 の前提）。⚠ **狙いは対称性の確認**で、§13 で Mastodon のリスト・フォロー関係に当たりが出たぶんを突き合わせた。

| | 内容 | 行き先 |
| --- | --- | --- |
| **14-1 ★** | `users/lists/update` の `isPublic` を送っておらず**リストを公開できない**。⚠ Mastodon の `replies_policy` / `exclusive` と同族で、**両 SNS でリストの設定項目だけが揃って触れない** | [#1211](https://github.com/pooza/capsicum/issues/1211) |
| **14-2 ★** | `following/create` の `withReplies` を送っておらず、フォロー時に「返信も流す」を選べない。⚠ **フォロー関係ごとのフラグ**で、自分の既定（`User.withReplies`）とは別物 | [#1211](https://github.com/pooza/capsicum/issues/1211) に同梱 |
| **14-3** | `drive/files/update` の `isSensitive`（アップロード時には送っている・あとから切り替えられないだけ） | 小粒・未起票 |
| **14-4** | 当たりではなかった 5 件（`mute/create` の `expiresAt` ほか・すべて送れている） | — |

### 14-5. これで層② は閉じた

| 層 | Mastodon | Misskey |
| --- | --- | --- |
| ② パラメータ | ✅ **全数**（§13・capsicum が呼ぶ約 75 経路） | ✅ **B 系以外は全数**（§12-5 の chat 23 経路 + §14 の `lists` / `following` / `blocking` / `mute` / `drive`）。⚠ 残るのは `clips` / `antennas` / `channels` / `pages` / `flash` で、**作成・編集 UI を作る回に同じコードを読む**（§12-6 の判断） |

⚠ 層② で単独に巡回する価値のある範囲は無くなり、残りは分類 B の着手に従属する。
