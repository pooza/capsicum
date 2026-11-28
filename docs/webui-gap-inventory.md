# 棚卸し: WebUI にあって capsicum に無い機能

[#991](https://github.com/pooza/capsicum/issues/991) の成果物。**Mastodon / Misskey の WebUI が持っている面**と capsicum を突き合わせ、拾う / 拾わないを決める。

- 実施日: **2026-09-03**（第 1 巡・層① 完了）
- 基準: **pooza フォーク**（美食丼 = `~/repos/mastodon` の `bshockdon` / ダイスキー = `~/repos/misskey` の `daisskey`）
- 兄弟の棚卸し: [#993](https://github.com/pooza/capsicum/issues/993)（API 基準・完了 → [api-gap-inventory.md](api-gap-inventory.md)）/ [#992](https://github.com/pooza/capsicum/issues/992)（サーバー側に保存された設定・完了 → [server-settings-gap-inventory.md](server-settings-gap-inventory.md)）
- **親 Issue #991 は 2026-09-04 に close 済み**（完了条件＝この計画書を残すところまで、を満たしたため）。残った宿題は §6 のとおり [#1077](https://github.com/pooza/capsicum/issues/1077) へ切り出した

⚠ **この文書はチェックリストではない。**拾うと決めたものは、ここから**最初からマイルストーンを付けた個別 Issue** として切り出す（[#905](https://github.com/pooza/capsicum/issues/905) / [#915](https://github.com/pooza/capsicum/issues/915) で 37 項目が滞留した形の再発防止）。

## 0. なぜ #993 の後にこれをやる価値があるのか（第 1 巡で確定した）

**API 基準の棚卸しと母数が違う。**#993 は「サーバーが提供しているのに capsicum が呼んでいないエンドポイント」を見た。こちらは「**WebUI では 1 画面になっているのに capsicum にその画面が無い**」を見る。

第 1 巡の結果、**#993 の分類 A / B / C のどこにも出てこない項目が 3 件出た**（§3 の A-1 / A-2 / A-3）。3 件とも `config/routes/api.rb` には載っているので #993 の母数には入っていたはずで、**層① の突き合わせで静かに落ちていた**ことになる。⚠ **「API 基準で全数見たから WebUI 基準は要らない」は成り立たない。**

3 件に共通するのは、**capsicum が「付ける」側だけ実装して「見る」側を持っていない**という形:

| | 付ける（実装済み） | 見る（欠落） |
| --- | --- | --- |
| お気に入り | `POST /statuses/:id/favourite` | `GET /favourites` |
| ハッシュタグのフォロー | `POST /tags/:name/follow` | `GET /followed_tags` |
| 引用 | `quotes_count` を読んで**件数を表示している** | `GET /statuses/:id/quotes` |

⚠ **エンドポイント単位で「呼んでいる / 呼んでいない」を数えると、この形は片方が緑なので見落としやすい。**画面単位で見ると「一覧が無い」として一発で出る。これが #991 を独立した棚卸しにしている理由そのものだった。

## 1. 母数と実施範囲

| | 母数 | 除外後 | capsicum |
| --- | --- | --- | --- |
| Mastodon | `app/javascript/mastodon/features/ui/index.jsx` の 67 ルート | 別名ルート・オンボーディング・WebUI ナビ補助を落として **約 45** | `lib/src/router.dart` の **58 ルート** |
| Misskey | `packages/frontend/src/router.definition.ts` の 145 ルート | `admin/*`・設定・認証・ゲーム・開発者向けを落として **約 55** | 同上 |

⚠ **Mastodon の母数は「features/ ディレクトリ 57 個」で測らない。**ディレクトリは `ui/` `navigation_panel/` `standalone/` `picture_in_picture/` のような**構造の入れ物**を含み、機能の数とずれる。ルート定義を正本にする。

⚠ **フォーク固有の画面は両 SNS とも無かった。**Mastodon 側は #993 と同じ結論（routes の diff が空）。Misskey 側はフォークの追加分がタグセット widget（`WidgetTagset.vue`）とデフォルトタグ周りに閉じており、**独立した画面を足していない**。「本家にもあるか / フォーク固有か」の列は全行「本家」で埋まる。

### 層の切り分け（#993 の知見を持ち込む）

#993 でいちばん効いたのは層を分けて回すことだった。WebUI 基準にも同じ構造がある。

| 層 | 見るもの | 第 1 巡の実施状況 |
| --- | --- | --- |
| ① **画面** | WebUI にある画面が capsicum に無い | **両 SNS 全数** |
| ② **画面内の操作** | 画面はあるが、その中の操作が欠けている（閲覧のみ 等） | **部分的** — 「閲覧のみ」パターンだけ追った（§4） |
| ③ **画面内の表示要素** | 画面も操作もあるが、出している情報が欠けている | **未実施**（§6） |

**層① の当たりは「片肺」に、層② の当たりは「閲覧のみ」に集中した。**層③ は #993 の層③ と重なる領域なので、回すなら [#1046](https://github.com/pooza/capsicum/issues/1046) と一緒に見るのが効率的。

## 2. 落とす基準（列挙前に確定）

「WebUI に画面がある」は「capsicum に要る」を意味しない。次に当たるものは母数から落とす。

1. **管理人向け** — Mastodon の `/admin/*`、Misskey の `/admin/*` `/moderation` `/modlog` `/roles` `/relays` 等。#991 の本文で明示的に対象外。
2. **別名ルート** — Mastodon の `/accounts/:id/*` `/users/:acct/*` `/statuses/:id` `/timelines/*` は `/@:acct/*` `/public` 等と同一画面の別パス。1 つに数える。
3. **オンボーディング・ナビ補助** — `/start` `/start/follows` `/start/profile` `/getting-started` `/overview`。capsicum はログイン後すぐタイムラインで、WebUI のような多段導入を持たない設計。
4. **認証・アカウントの生死** — `/oauth/authorize` `/miauth/:session` `/reset-password` `/verify-email` `/signup-complete` `/security` `/account-data`。#993 の落とす基準 3 と同じ理由（クライアントが持つと事故時の責任範囲が広がる）。
5. **クライアント設定・見た目** — Misskey の `/theme*` `/custom-css` `/sounds` `/statusbar` `/navbar` `/emoji-palette` `/plugin*` `/install-extensions` `/preferences`。**capsicum には capsicum の設定画面がある**ので、WebUI の設定項目を移植する話ではない。⚠ サーバー側に保存されていて capsicum が従うべき値は **#992 の領分**なのでここでは判定しない。
6. **開発者向け** — Misskey の `/scratchpad` `/api-console` `/debug` `/preview` `/lookup` `/qr` `/redirect-test` `/registry*`。
7. **ゲーム・統計** — Misskey の `/games` `/reversi*` `/bubble-game` `/clicker`。#993 の分類 C と同じ。
8. **既に #993 で決着済み** — `/directory`（フォロー推薦・人脈の可視化系 → C）/ `/domain_blocks`（連合の可視化 → C）/ `/notifications/requests`（→ #992 へ回送）/ `/explore` `/links/:url`（→ [#1049](https://github.com/pooza/capsicum/issues/1049) トレンド）/ `/deck`（→ [#720](https://github.com/pooza/capsicum/issues/720)）/ `/mute-block` `/blocks` `/mutes`（→ [#1039](https://github.com/pooza/capsicum/issues/1039)）/ `/follow_requests` `/my/follow-requests`（→ [#1040](https://github.com/pooza/capsicum/issues/1040)）/ `/avatar-decoration`（→ [#344](https://github.com/pooza/capsicum/issues/344)）。**再判定しない。**

## 3. 分類 A — 1.x の間に処理すべきもの

**3 件とも起票して v1.63 で出荷した**（[#1070](https://github.com/pooza/capsicum/issues/1070) フォロー中のハッシュタグの一覧 / [#1071](https://github.com/pooza/capsicum/issues/1071) お気に入りの一覧 / [#1072](https://github.com/pooza/capsicum/issues/1072) 引用の一覧）。判定軸は #993 の分類 A と同じ「片肺」。本文（A-1〜A-3）は [archive](archive/webui-gap-inventory-settled.md)。

## 4. 分類 B — 2.0 以降のマイルストーンに載せるもの

層② から出た「閲覧のみ」パターン。B-1 Pages（[#1073](https://github.com/pooza/capsicum/issues/1073)）と B-2 Play の作成・編集（[#1074](https://github.com/pooza/capsicum/issues/1074)）は未割り当ての `on-hold`（[roadmap.md](roadmap.md) 決定済み事項 3 の (4)・(5)）、B-3 フィーチャータグ（[#1075](https://github.com/pooza/capsicum/issues/1075)）は v2.0 で出荷。本文は [archive](archive/webui-gap-inventory-settled.md)。

## 5. 分類 C — 拾わない

**「今は要らない」ではなく「capsicum の役割ではない / 方針に反する」もの。**次の棚卸しで再浮上させないために理由を残す。

| 項目 | 理由 |
| --- | --- |
| Mastodon `/@:acct/tagged/:tagged?`（プロフィール内のタグ絞り込み） | プロフィールを「そのタグの投稿だけ」に絞る機能。**capsicum はタグ TL 側が厚い**（ハッシュタグ TL・タグセット・お気に入りタグ）ので、同じ目的はそちらで足りている。プロフィールに絞り込み UI を足すと画面が重くなる方が損 |
| Misskey `/emojis`（カスタム絵文字カタログ画面） | capsicum は `/api/emojis` を**描画とピッカーのために**既に読んでいる（`misskey/client.dart:836`）。カタログとして眺める画面は実況の道具にならない。⚠ モロヘイヤの**メディアカタログ**（`/media-catalog`）とは別物 |
| Mastodon `/keyboard-shortcuts`（ショートカット一覧画面） | デスクトップのショートカットはメニューバーに露出済みで、**メニューがそのまま一覧の役目を果たしている**。別画面は二重管理 |
| Misskey `/instance-info/:host`（他サーバーの情報） | 連合の可視化。#993 で `instance/peers` / `federation/*` を C にしたのと同じ理由。capsicum の「サーバーの素性を提示する」（[#816](https://github.com/pooza/capsicum/issues/816)）は接続先の 1 台で足りている |
| Misskey `/drive/cleaner` | ドライブの一括整理。capsicum のドライブは**投稿に添付する導線**として持っているもので、容量管理は WebUI の領分 |
| Mastodon `/@:acct/:statusId/reblogs` `/favourites`（投稿単位） | **実装済み**（`post_tile.dart` の `_showRebloggedBy` / `_showFavouritedBy`）。落とすのではなく既済 |

## 6. 未実施・次回の宿題 → **回し終えた**

第 1 巡で残した宿題 4 件は、どれも行き先が決まって消化済み。⚠ **内訳と切り出しの経緯は [archive/webui-gap-inventory-settled.md](archive/webui-gap-inventory-settled.md) へ移した**（2026-10-11）。

- 層③（画面内の表示要素）と、層② の「閲覧のみ」以外の変種 → [#1077](https://github.com/pooza/capsicum/issues/1077) で回した。**結果は §8**。
- Misskey の設定画面に混ざる「サーバー側へ保存される値」→ [#992](https://github.com/pooza/capsicum/issues/992) が引き取った（[server-settings-gap-inventory.md](server-settings-gap-inventory.md)）。
- Mastodon のリモートのみの連合 TL → API 基準の側で扱った（[api-gap-inventory.md](api-gap-inventory.md) §13）。

⚠ **API 基準と WebUI 基準は、同じ回に回しても数え方を 2 通り維持する。**母数の取り方が違い、§0 のとおり片方でしか出ない項目が実際にあった。

## 7. 起票 → **完了（2026-09-03）**

**全 6 件を起票した。**この文書に「まだ起票していないもの」は残っていない。行き先の判断と着手順の記録は [archive/webui-gap-inventory-settled.md](archive/webui-gap-inventory-settled.md)。

- **A 群**（[#1070](https://github.com/pooza/capsicum/issues/1070) フォロー中のハッシュタグの一覧 / [#1071](https://github.com/pooza/capsicum/issues/1071) お気に入りの一覧 / [#1072](https://github.com/pooza/capsicum/issues/1072) 引用の一覧）→ v1.63 で消化した。
- **B 群**（[#1073](https://github.com/pooza/capsicum/issues/1073) Pages / [#1074](https://github.com/pooza/capsicum/issues/1074) Play の作成・編集 / [#1075](https://github.com/pooza/capsicum/issues/1075) フィーチャータグ）→ #1075 は v2.0 で消化した。⚠ **#1073 / #1074 は「閲覧のみ」の族で、未割り当ての `on-hold`**（[roadmap.md](roadmap.md) 決定済み事項 3 の (4)）。

## 8. 層② の変種と層③（2026-10-02・[#1077](https://github.com/pooza/capsicum/issues/1077)）

**§6 の宿題 2 件を回した。**[#1046](https://github.com/pooza/capsicum/issues/1046) と同じ回に回し（母数が重なる）、⚠ **数え方は 2 通り維持した** —— API 基準の結果は [`api-gap-inventory.md`](api-gap-inventory.md) §13 / §14、画面基準はここ。

### 8-0. 回し方

**画面から入った。**capsicum の画面を開き、「この画面でできること」と「WebUI の同じ画面でできること」を突き合わせた。⚠ **層③ は entity のフィールド一覧で測らない**（§6 の注意）—— 画面に出ていない情報を先に挙げ、その出どころを後から API 側で確かめた。

⚠⚠ **成果の性質が #991 の第 1 巡と違う。**層① は「画面が無い」＝**分類 A / B の新しい画面**になったが、層② 変種と層③ は**既にある画面の中の欠け**なので、**ほぼ全部が既存画面への追加**になる。新しい画面は 1 枚も増えない。

### 8-1〜8-3. 変種と層③ の当たり

本文は [archive](archive/webui-gap-inventory-settled.md)。当たりはすべて §8-6 のとおり起票した。

### 8-4. 当たりではなかったもの

⚠ **古いメモを写さず、実物で確かめた。**

| 項目 | なぜ当たりではないか |
| --- | --- |
| **凍結・サイレンス・削除済みアカウントの表示** | ✅ **解決済み。**api-gap archive §9-6 に「凍結・削除済みのアカウントを普通のプロフィールとして表示している」と残っているが、**[#1055](https://github.com/pooza/capsicum/issues/1055) で両 SNS とも読むようになり**（`capsicum_core` の `User.suspended` / `silenced` / `deleted`）、**プロフィール画面に出ている**（`profile_screen.dart:1007`）。⚠ **archive 側の記述は 2026-08-31 時点のもの** |
| 投稿の生テキスト（`/source`） | capsicum は投稿を編集しないので要らない。⚠ モロヘイヤが PUT の補完にサーバー側で使っているのは別の話 |
| `endorsements` / `familiar_followers` / `suggestions` / `annual_reports` / `donation_campaigns` | **分類 C 既判定**（api-gap §5）。再判定しない |
| `/notifications/requests` / `/notifications/policy` | [#992](https://github.com/pooza/capsicum/issues/992) へ回送済み（残りは [#1078](https://github.com/pooza/capsicum/issues/1078)） |

### 8-5. 方法論の知見（次の棚卸しへ）

⚠⚠ **1. 版追従の表の `none` を棚卸しの判定として読まない。**`misskey-capsicum-api-watch.md:153` は `notes/thread-muting/create` を「none（capsicum 無関係・呼んでいない）」としているが、**あれは「その版で変わったか」の判定**。棚卸しでは **「呼んでいない」は落とす理由ではなく見る理由**。この取り違えでスレッドのミュート（両 SNS にある）が 1 件落ちていた（api-gap §13-7）。

⚠⚠ **2. 層① の「全数」でも取りこぼす。**routes に載っているのに層① で落ちた経路が 2 件あった（`notifications/unread_count` / `statuses/:id/mute`）。**どちらも層② の目で経路の中身を読んでいて気付いた。**→ **§0 の主張（母数の取り方が違うと別のものが見える）は、WebUI 基準と API 基準の間だけでなく、API 基準の層①と層②の間でも成り立つ。**

⚠ **3. 「薄い」と見立てたほうを最後に回すと、最も多く出ることがある。**#1046 の優先順位は Mastodon ② を最後尾（「当たりは薄い」）に置いていたが、**★ 8 件でいちばん多かった**。

⚠ **4. 画面を見ないと出ない当たりがある。**「同じ検索画面で notestock だけページングがある」「予約投稿のシートがタグ編集専用」は、**API 側のパラメータ表からは出てこない**。

### 8-6. 分類と起票（2026-10-02）

**拾った 7 件は起票済み**（[#1211](https://github.com/pooza/capsicum/issues/1211) / [#1212](https://github.com/pooza/capsicum/issues/1212) / [#1213](https://github.com/pooza/capsicum/issues/1213) / [#1214](https://github.com/pooza/capsicum/issues/1214) / [#1206](https://github.com/pooza/capsicum/issues/1206) / [#1202](https://github.com/pooza/capsicum/issues/1202) / [#1207](https://github.com/pooza/capsicum/issues/1207)）。表と経緯は [archive](archive/webui-gap-inventory-settled.md)。⚠ **次の棚卸しで再浮上させないため、「拾わない」3 件は理由ごと残す:**

| 項目 | 理由 |
| --- | --- |
| 通知の個別削除・全消し | ⚠ **単独では拾わない。**通知の既読（[#1205](https://github.com/pooza/capsicum/issues/1205)）と未読数（[#1207](https://github.com/pooza/capsicum/issues/1207)）と**同じ画面**なので、あちらを触る回に一緒に見る |
| 投稿の編集履歴 | ⚠ **拾わない。**プリセット 5 台では編集済み投稿がほぼ発生しない |
| プレビューカードの著者 | ⚠ **拾わない。**[#1033](https://github.com/pooza/capsicum/issues/1033) で「カードの大きさを一定にする」と決めており、カードに要素を足す方向を採っていない |
