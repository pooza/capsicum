# API 棚卸し — 決着済みの第 1 巡（2026-08-31）

⚠ **[docs/api-gap-inventory.md](../api-gap-inventory.md) から分けたもの。**2026-10-02 に本体が 1 回で読める上限（60KB）へ貼り付いたため、**全件起票済みで決着した第 1 巡の詳細**をここへ移した（[#1184](https://github.com/pooza/capsicum/issues/1184) の規約「その回に削るか分ける」）。

⚠ **結論は本体に 1 行ずつ残してある。**ここは「どう測って、何をどう判断したか」の記録で、**次の棚卸しが同じ地点から再開するために読む**もの。

| この文書が答えるもの | 行き先 |
| --- | --- |
| 2026-08-31 の層②③ 第 1 巡で何が出たか（★ 5 件の詳細） | 下の §9 |
| 層③ の entity 別の未読フィールド一覧（Misskey Note / User・Mastodon 8 entity） | 下の §9-6 |
| 層② 主要経路（Misskey の投稿・TL・アップロード）の結果 | 下の §10 |

⚠ **第 2 巡（2026-09-29〜10-02・#1046 / #1077 を閉じた回）は [api-gap-inventory-round2-settled.md](api-gap-inventory-round2-settled.md) にある。**本体の §11（未実施のまま残す範囲）/ §12（層③ の続き）/ §13（Mastodon ②）/ §14（Misskey ②）の詳細はそちら。

---


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

---

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

⚠⚠ **この前提は誤っていた**（2026-09-04 実測）。capsicum には**種別フィルタの UI がそもそも無く**、「全種別を取ってからクライアントで捨てている」のではなく**絞っていなかった**。パラメータが未使用なのは絞り込みを持っていなかったからで、無駄な転送もページングの空振りも起きていない。[#1042](https://github.com/pooza/capsicum/issues/1042) は「種別フィルタを新機能として作る」に読み替えて v2.0 へ移した。

✅ **実装済み**（2026-09-27・v2.0）。[#1048](https://github.com/pooza/capsicum/issues/1048) と同じ回に、最初から `GET /api/v2/notifications` で作った。⚠ **許可リスト（`types[]`）ではなく拒否リスト（`exclude_types[]`）を送る** — 許可リストにすると capsicum が名前を知らない種別が黙って消え、「絞り込み中だけ新しい通知が来ない」という原因の見えない形で出る。`account_id` は**通していない**（UI 上の要求が無く、Misskey に等価物が無い）。実装上の罠は `tech-notes-api.md`「`supported_types` を送っても未知の型が必ず読めるようになるわけではない」が正本。

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


---

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

---

## 12-2 の決着（2026-10-01・#1187・出荷済み）

#### ✅ 決着（2026-10-01・[#1187](https://github.com/pooza/capsicum/issues/1187)）

**6 種類とも読むようにした。**入れ物は **[#1084](https://github.com/pooza/capsicum/issues/1084) の `severance` / `moderationWarning` と同じ「種別ごとに型付きのフィールドを 1 つ」**（Issue の候補 A）。⚠ **候補 C（sealed class で種別ごとに分ける）は採らない** —— `announcement` / `collection` / `achievement` / `severance` / `moderationWarning` と**既に 5 つ同じ形で積まれている**ので、ここだけ別の形にすると入れ物が 2 種類になる。

| 種別 | 読んだ先 | 画面 |
| --- | --- | --- |
| `roleAssigned` | `Notification.assignedRole`（⚠ `User.roles` と同じ `UserRole` を使い回す） | ロール名 |
| `exportCompleted` | `Notification.export`（`ExportCompletion`） | 「フォローを書き出しました」+ タップでファイルを開く |
| `scheduledNotePostFailed` | `Notification.failedScheduledPost`（`ScheduledPost`） | 失敗した投稿の本文（空なら予約時刻） |
| `chatRoomInvitationReceived` | `Notification.chatInvitation`（既存の `ChatRoomInvitation`） | ルーム名 + タップで招待一覧へ |
| `followRequestAccepted` | `Notification.followRequestMessage` | 添えられた一言 |
| `app` | ⚠⚠ **`fallbackTitle` / `fallbackBody`（#1042 の受け皿）** | 見出し + 本文 |

⚠⚠ **`app` だけ入れ物が違う理由。**#1177 は `app` を `misskeyNotificationTypeMap` に**入れない**と決めた（あの表は絞り込みの候補の正本でもあり、使う機会のほぼ無い種別で選択肢だけが増えるため）。その判断を崩さずに本文を出すため、**未知種別の受け皿である fallback に載せた**。`app` は `NotificationType.other` のままになる。

⚠ **`icon` は読むが使っていない。**通知の行頭は種別アイコンで揃えてあり、`app` だけ別の絵を出すと並びが崩れる。**読んでいることを残すためにモデルには持つ。**

⚠ **`exportCompleted` の導線は 1 往復かかる。**通知には `fileId` しか載らないので、URL を得るには `drive/files/show` が要る（`DriveSupport.getDriveFile` を新設）。⚠⚠ **一覧を描くたびには引かない** —— 通知 1 件につき 1 往復になるので、**タップした時点**で引く。⚠ 書き出したファイルは期限で消えるので、**「無い」は普通の結末**として扱う（黙って何も起きない形にしない）。

⚠ **`scheduledNotePostFailed` の `noteDraft` は予約投稿一覧と同じ `NoteDraft`。**パースを `misskeyScheduledPostFromMap` に寄せた。⚠⚠ **`scheduledAt` は epoch ミリ秒の int**（`createdAt` と形が違う）。⚠ **寄せる前はこのパースにテストが 1 本も無かった**ので、既存の振る舞い（int 以外は落とす・`scheduledAt` を持たない行を落とす）を併せて固定してある。
