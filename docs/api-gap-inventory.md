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

### 実施範囲の正直な線引き

**層ごとに深さが違う。**均一に回したわけではないので、次の棚卸しが同じ地点から再開できるように書いておく。

| 層 | Mastodon | Misskey |
| --- | --- | --- |
| ① エンドポイント | **全数**（routes 全行を読んで突き合わせ） | **全数**（338 とカテゴリ別 diff） |
| ② パラメータ | **主要 6 経路のみ**（statuses / notifications / accounts.statuses / timelines / search / tag） | **未実施** |
| ③ entity フィールド | **Status / Account の 2 つのみ** | **未実施** |

⚠ **②③ の未実施ぶんは「無かった」ではなく「見ていない」。**Misskey の ②③ は次回以降の宿題として残る。ただし #993 の期待値設定（「Mastodon 側が主」）どおり、Misskey は API と WebUI が同時に育つため **API 先行機能という意味での当たりは実際に出ていない** — 出たのは「capsicum が実装していないだけ」の普通の未実装で、これは #991 の担当範囲と重なる。

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

### 7-2. タグの取得元がサーバーの `tags` ではなく描画済み HTML / MFM のパース（要判断）

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

B は v2.0 に据え置き、**フィルタと通知グループ化のどちらかを次の大更新の候補**として設計書（#720 / #597 と同じ形）に進める判断を仰ぐ。

### 起票のタイミングで詰まっている点（2026-08-31 追記）

**A 群の行き先が、運用モードと噛み合っていない。**

- CLAUDE.md の「大玉の進め方」§3 は「確定後に **1.x 行きだけを稼働中の枠へ**」と決めている。
- 一方 1.x は**外部要因の発生ベース運用**で、稼働中の v1.62 は「**内部由来のタスクで枠を埋めない**」を明示した枠として作った（#1034 / #1035 / #1038 を意図的に外している）。
- A 群（A-1 〜 A-4）は**ユーザー報告ではなく棚卸し由来**なので、この基準では内部由来にあたる。

つまり **A 群を v1.62 に入れると、同じ回に外したばかりの #1034 / #1035 / #1038 との扱いが割れる。**どちらかを選ぶ必要がある:

1. **A 群専用の枠（v1.63 等）を別に立てる** — 棚卸しの成果は棚卸しの枠で消化する。v1.62（外部要因）と混ぜないので基準が割れない。
2. **A 群も未割り当てで置き、外部要因が来たときに引き上げる** — #1034 と同じ扱い。⚠ ただし A-1（ミュート解除の導線が無い）は**踏んだユーザーが報告できない**性質（相手が TL から消えるので気付きにくい）なので、報告待ちが機能しない可能性がある。
3. **A-1 だけ例外として v1.62 へ入れる** — 「機能欠落に見える」度合いが突出しているため。

⚠ **この判断は pooza に仰ぐ。**Claude 側で決めない。
