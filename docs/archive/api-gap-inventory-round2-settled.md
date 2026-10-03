# API 棚卸し — 決着済みの第 2 巡（2026-09-29〜10-02）

⚠ **[docs/api-gap-inventory.md](../api-gap-inventory.md) から分けたもの。**2026-10-03 に本体が 1 回で読める上限（60KB）へ再び貼り付いたため、**全件起票済みで決着した第 2 巡の詳細**をここへ移した（[#1184](https://github.com/pooza/capsicum/issues/1184) の規約「budget を足して先送りせず、その回に削るか分ける」）。

⚠ **第 1 巡（2026-08-31）は [api-gap-inventory-settled.md](api-gap-inventory-settled.md) にある。**こちらは **[#1046](https://github.com/pooza/capsicum/issues/1046) / [#1077](https://github.com/pooza/capsicum/issues/1077) を閉じた回**で、層② が両 SNS とも全数になり、★ 13 件（[#1202](https://github.com/pooza/capsicum/issues/1202)〜[#1214](https://github.com/pooza/capsicum/issues/1214)）を起票して終わった。

⚠ **結論は本体に 1 行ずつ残してある。**ここは「どう測って、何をどう判断したか」の記録で、**次の棚卸しが同じ地点から再開するために読む**もの。

| この文書が答えるもの | 行き先 |
| --- | --- |
| 層③ の続き（Misskey の `notification` / `drive-file` / `chat-*` / `emoji` / `role`）で何が出たか | 下の §12 |
| Mastodon ② 全数（約 75 経路）の結果 —— ★ 8 件の詳細と、当たりではなかった範囲 | 下の §13 |
| Misskey ② の残り（`lists` / `following` / `blocking` / `mute` / `drive`）の結果 | 下の §14 |
| 2026-08-31 時点の「未実施のまま残す範囲」がどう消えたか | 下の §11 |

⚠⚠ **当たりではなかった記録（§12-5 / §13-12 / §14-4）を捨てないこと。**「見ていない」が「無かった」に変わった範囲で、**次に回す人が再走しないため**に残してある。

**本体に残した live な判断**: §12-6（残りは分類 B の着手回に一緒に見る）/ §13-7 の方法論（版追従の表の `none` を棚卸しの結論として読まない）/ 起票 9 件の順序の制約。

---

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
