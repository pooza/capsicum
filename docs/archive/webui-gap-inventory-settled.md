# 棚卸し: WebUI にあって capsicum に無い機能 — 決着した節の記録

> **アーカイブ（現役運用では参照しない）。**[webui-gap-inventory.md](../webui-gap-inventory.md) の §6（宿題）と §7（起票）の本文を、2026-10-11 に移した。宿題は [#1077](https://github.com/pooza/capsicum/issues/1077) で回し終え（本体の §8）、起票した 6 件は行き先が決まっている。**結論は本体側に残してある。**節番号は本体と同じ。

## 6. 未実施・次回の宿題（2026-09-04 に [#1077](https://github.com/pooza/capsicum/issues/1077) へ切り出し済み）

⚠ **この節は行き先が決まっている。**#991 を close するにあたって、下記のうち引き継ぎ先が未定だった 2 件を **[#1077](https://github.com/pooza/capsicum/issues/1077)（v2.0）** に切り出した。残る 2 件は元から他 Issue が引き取っている。

| 宿題 | 行き先 |
| --- | --- |
| **層③（画面内の表示要素）が丸ごと未実施。**「画面も操作もあるが、出している情報が欠けている」層 | **#1077**。⚠ **#993 の層③（entity の未読フィールド）と母数が重なる**ので、[#1046](https://github.com/pooza/capsicum/issues/1046) と同じ回に回す |
| **層② は「閲覧のみ」パターンしか追っていない。**「作成はできるが編集できない」「一覧はあるが並べ替えられない」等の変種は見ていない | **#1077** |
| **Misskey の設定画面（`/settings/*` 相当）を丸ごと落としている。**落とす基準 5 のとおり意図的だが、⚠ **その中にサーバー側へ保存される値が混ざる** | [#992](https://github.com/pooza/capsicum/issues/992) の母数として引き継ぎ済み（#992 も完了。そこから残った未確認分は [#1078](https://github.com/pooza/capsicum/issues/1078)） |
| **Mastodon の `/public/remote`（リモートのみの連合 TL）**は画面ではなくパラメータの差（capsicum は `local` しか送っていない・`mastodon/client.dart:849`） | 層② の話なので [#1046](https://github.com/pooza/capsicum/issues/1046) 側で扱う |

⚠ **#1077 と #1046 は同じ回に回すが、数え方は 2 通り維持する。**API 基準（#1046）と WebUI 基準（#1077）で母数の取り方が違い、§0 のとおり**片方でしか出ない項目が実際にあった**ため。

## 7. 起票（2026-09-03 完了）

**全 6 件を起票した。**この文書に「まだ起票していないもの」は残っていない。

### A 群 → [v1.63](https://github.com/pooza/capsicum/milestone/77)（pooza の判断）

論点は #993 のときと同じだった。v1.63 は「**#993 の棚卸し成果を消化する専用枠**」として作られており、A 群は #991 の成果なので、枠の趣旨を「棚卸し由来」と読むか「#993 の成果」と読むかで行き先が割れる。

→ **趣旨を「棚卸しの成果」へ広げて v1.63 で消化する**ことにした。決め手は **[#1070](https://github.com/pooza/capsicum/issues/1070) が主役の [#1039](https://github.com/pooza/capsicum/issues/1039) と構造が同一**で、設計を流用できること。milestone description も同日に書き換えた。

⚠ **「内部由来を入れてよい枠ではない」は据え置き。**#1034 / #1035 / #1038 は引き続き入れない。広げたのは「棚卸しの出典」であって「入れてよいものの種類」ではない。

| | Issue | 粒度 |
| --- | --- | --- |
| A-2 | [#1070](https://github.com/pooza/capsicum/issues/1070) フォロー中のハッシュタグの一覧 | 小〜中。⚠ **#1039 とまとめて設計する** |
| A-1 | [#1071](https://github.com/pooza/capsicum/issues/1071) お気に入りの一覧 | 小 |
| A-3 | [#1072](https://github.com/pooza/capsicum/issues/1072) 引用の一覧 | 小 |

### B 群 → [v2.0](https://github.com/pooza/capsicum/milestone/65) 据え置き

| | Issue | 粒度 |
| --- | --- | --- |
| B-1 | [#1073](https://github.com/pooza/capsicum/issues/1073) Misskey の Pages を作成・編集 | 中。⚠ **#1050〜#1053 と同じ族**。束ねて型を決める |
| B-2 | [#1074](https://github.com/pooza/capsicum/issues/1074) Misskey の Play を作成・編集 | 大。⚠ **束に混ぜない・分類 C 行きもありうる** |
| B-3 | [#1075](https://github.com/pooza/capsicum/issues/1075) フィーチャータグ | 小〜中。読む側だけ先行の分割あり |

### 着手順の提案（v1.63 内）

1. **#1039 → #1070**（一覧画面の形・解除の導線を揃える。2 件目が安くなる）
2. #1071（ブックマーク画面の隣に 1 枚）
3. #1072（`_showRebloggedBy` と同じ BottomSheet。⚠ **中身はユーザー一覧でなく投稿一覧**なのでそのまま流用はできない）

### #993 側の訂正

- [api-gap-inventory.md](../api-gap-inventory.md) §1 の「capsicum が使っている `collections` / `in_collections` / `quotes` 系」— **`quotes` エンドポイントは使っていない**（§3 の A-3）。次に api-gap-inventory を触る回で直す


---

## §3・§4・§8-1〜8-3・§8-6 の本文（2026-11-28 に本体から移した）

本体（[webui-gap-inventory.md](../webui-gap-inventory.md)）には同じ番号の見出しと結論だけを残してある。

## 3. 分類 A — 1.x の間に処理すべきもの

**判定軸は #993 の分類 A と同じ「片肺」**。すでに capsicum にある導線の裏返しが欠けているもの。⚠ **3 件とも #993 の分類 A / B / C のどこにも出てこない**（grep で確認済み）。

### A-1. ★ お気に入りの一覧が無い（Mastodon）

**capsicum はお気に入りを付けられるが、付けたものを一覧できない。**

- 実装済み: `favouriteStatus` / `unfavouriteStatus`（`mastodon/client.dart:483,489`）。投稿単位の「お気に入りした人」一覧も実装済み（`post_tile.dart:1965` の `_showFavouritedBy`）
- 欠落: **`GET /api/v1/favourites` がリポジトリ全体で 0 ヒット**。お気に入り一覧の画面も無い（`ui/screen/` に該当なし・ドロワーにも項目なし）
- 対して**ブックマークは一覧できる**（`/bookmarks` → `bookmark_screen.dart`）。**同じ「あとで見る」系で片方だけ一覧がある**という非対称になっている

⚠ **「お気に入りタグ」（モロヘイヤの機能）と混同しない。**あちらは投稿に付けるハッシュタグの管理で、Mastodon の favourite とは無関係。用語が衝突しているので Issue 本文では区別を明示する。

⚠ **Misskey には該当しない。**Misskey の「お気に入り」は意味的にブックマーク相当で、capsicum はそちらを `/bookmarks` に寄せている（`docs/CLAUDE.md` の機能マッピング表のとおり）。**Mastodon 単独の片肺。**

### A-2. ★ フォロー中のハッシュタグの一覧が無い（Mastodon）

**capsicum はハッシュタグをフォロー / 解除できるが、フォロー中の一覧が無い。**

- 実装済み: `followHashtag` / `unfollowHashtag`（`mastodon/adapter.dart:1243,1246`）。UI からは `hashtag_timeline_screen.dart:61,63` で呼ばれている
- 欠落: **`GET /api/v1/followed_tags` が 0 ヒット**
- ⚠ **解除の導線が構造的に塞がる。**フォロー解除は「そのタグのタイムラインを開く」経路にしか無いので、**何をフォローしたか忘れると解除できない**。[#1039](https://github.com/pooza/capsicum/issues/1039)（ミュートすると相手が TL から消えるので解除できない）と**まったく同じ構造の問題**

### A-3. 引用の一覧が無い（Mastodon）

**capsicum は引用数を表示しているのに、そこから引用元へ行けない。**

- 実装済み: `quoteCount`（`mastodon/extensions.dart:113`）を読んで投稿に件数を出している。ブースト一覧（`_showRebloggedBy`）・お気に入り一覧（`_showFavouritedBy`）は投稿単位で実装済み
- 欠落: **`/api/v1/statuses/:id/quotes` の呼び出しが 0 ヒット**。ブースト / お気に入りは一覧できるのに**引用だけ数字止まり**
- ⚠ **[api-gap-inventory.md](../api-gap-inventory.md) §1 の「capsicum が使っている `collections` / `in_collections` / `quotes` 系」という記述は不正確。**使っているのは entity のフィールド（`quotes_count` / `quote`）であって、`quotes` **エンドポイントは叩いていない**。#993 の記述はこの回で訂正する

## 4. 分類 B — 2.0 以降のマイルストーンに載せるもの

層② から出た「閲覧のみ」パターン。⚠ **[#1050](https://github.com/pooza/capsicum/issues/1050) クリップ / [#1051](https://github.com/pooza/capsicum/issues/1051) チャンネル / [#1052](https://github.com/pooza/capsicum/issues/1052) アンテナ / [#1053](https://github.com/pooza/capsicum/issues/1053) ギャラリーと完全に同じ形**なのに、#993 では拾われていなかった 2 件。

### B-1. Misskey の Pages を作成・編集できない（＋自分のページ一覧が無い）

- capsicum が呼んでいるのは `pages/featured` / `pages/show` / `pages/like` / `pages/unlike` の 4 本だけ
- サーバー側には `pages/create` / `pages/update` / `pages/delete` / `i/pages`（自分のページ一覧）がある
- ⚠ **他の 4 件より一段欠けている。**クリップ等は「自分の一覧はあるが作成できない」だが、Pages は **`/pages` 画面が `pages/featured`（おすすめ）だけ**で、**自分のページ一覧すら無い**。プロフィールの Pages タブ（`profile_screen.dart:800`）からは辿れるので完全に不可視ではない

### B-2. Misskey の Play を作成・編集できない

- capsicum が呼んでいるのは `flash/featured` / `flash/my` / `flash/show` / `flash/like` / `flash/my-likes` / `flash/unlike`
- サーバー側には `flash/create` / `flash/update` / `flash/delete` / `flash/search` がある
- **自分の一覧（`flash/my`）は実装済み**なので、欠けているのは作成・編集・削除・検索
- ⚠ **AiScript エディタを capsicum に載せる話になるので、4 件の中で最も重い。**[misskey-capsicum-api-watch.md](misskey-capsicum-api-watch.md) の「互換性の基準」（capsicum の評価器は gate で逃がす前提）と噛み合わせる必要がある。**B の中でも単独で判断する**

### B-3. Mastodon のフィーチャータグ（プロフィールに掲載するハッシュタグ）

- サーバー側: `GET/POST/DELETE /api/v1/featured_tags` + `GET /api/v1/accounts/:id/featured_tags`（`config/routes/api.rb:222,264,268`）
- capsicum: **0 ヒット**（読む側・書く側とも無い）
- ⚠ **#993 が C に落とした `endorsements` / `accounts/:id/pin`（プロフィールに他人を掲載）とは別物。**あちらは人脈の可視化で C 相当だが、こちらは**自分のタグの掲載**で、capsicum の主題（タグ管理）に寄っている。ただし**読む側の実装（他人のプロフィールで掲載タグを見る）から入る方が軽い**ので、粒度を分けて起票する


### 8-1. ★ 変種「作成はできるが、あとから変えられない」

| 項目 | 画面 | 変えられないもの |
| --- | --- | --- |
| **予約投稿** | 予約投稿一覧 | ⚠⚠ **予約の時刻。**シートは**タグ編集専用**（`scheduled_posts_screen.dart:140` の `_TagEditorSheet`）で、日時を動かす導線が無い。⚠ Mastodon は `PUT /api/v1/scheduled_statuses/:id` が **`scheduled_at` だけを permit** するので、**時刻変更こそが標準 API でできる唯一の編集**なのに呼んでいない |
| **リスト** | リスト一覧 / メンバー | 返信の扱い・ホームからの排他・公開（Mastodon の `replies_policy` / `exclusive`、Misskey の `isPublic`）。⚠ **作成と改名とメンバーの出し入れだけができる** |
| **引用** | 投稿のメニュー | 引用ポリシー（`PUT /api/v1/statuses/:id/interaction_policy`）。投稿時に `quote_approval_policy` を送るだけで、**あとから締められない** |
| **フォロー** | プロフィール | フォロー時の `withReplies`（Misskey・返信も TL に流すか） |

⚠ **本文・タグの編集を「できない」に数えないこと。**Mastodon の予約投稿は標準 API では本文を編集できず、capsicum がモロヘイヤ経由にしているのは**正しい設計**（`updateScheduledStatusTags`）。⚠⚠ **ただしモロヘイヤが無いサーバーでは「タグ編集にはモロヘイヤが必要です」で止まる** —— **時刻変更なら標準 API で通る**のに、そこへ落ちていない。

### 8-2. ★ 変種「一覧はあるが、その中の操作が無い」

| 項目 | 画面 | 無い操作 |
| --- | --- | --- |
| **DM（会話）** | DM タイムライン | ⚠⚠ **既読・未読・削除。**capsicum は DM を**タイムラインとして**実装しており（`mastodon/adapter.dart:417`・`TimelineType.directMessages`）、`GET /api/v1/conversations` の `unread` を読まず `read` / `unread` / `DELETE` も呼ばない。→ **WebUI の DM 未読が消えない** |
| **通知** | 通知 | 個別削除・全消し（`notifications/:id/dismiss` / `clear`、Misskey の `notifications/flush`）。⚠ **Misskey は既読化そのものが無い**（api-gap §13-5） |
| **引用** | 引用一覧（[#1072](https://github.com/pooza/capsicum/issues/1072)） | 引用の撤回（`POST /api/v1/statuses/:id/quotes/:id/revoke`）。⚠ **引用された側の道具**なので、一覧だけあって撤回が無いのは片肺 |
| **リストのメンバー** | メンバー一覧 | ⚠⚠ **追加読み込み。**`list_members_screen.dart:34` は 1 回しか呼ばず、**Mastodon では 40 人で尻切れ**（api-gap §13-1） |
| **検索** | 検索 | ⚠⚠ **サーバー検索の続き。**同じ画面で **notestock だけ `Link` ヘッダでページングしている**（`_searchNotestock`）のに、サーバー検索は 20 件で止まる |

⚠⚠ **「一覧はあるが並べ替えられない」は 1 件も出なかった。**WebUI 側にも並べ替えの UI がほとんど無い（Misskey のドライブに `sort` があるだけ）ため。⚠ **#1077 の本文が例に挙げていた変種だが、母数に無かった** —— 次の棚卸しで探し直さなくてよい。

### 8-3. ★ 層③ 画面内の表示要素

| 項目 | 画面 | 出ていない情報 | 出どころ |
| --- | --- | --- | --- |
| **お知らせの期間** | お知らせ | **掲載期間**（いつからいつまでのお知らせか）と終日フラグ | `starts_at` / `ends_at` / `all_day` / `published_at` が未読（api-gap archive §9-6・Announcement 13 中 7 読み） |
| **通知の未読数** | 通知バッジ | サーバーが持っている未読数。capsicum はクライアント側で数えている | `notifications/unread_count`（両 SNS・api-gap §13-4） |
| **リストの設定** | リスト一覧 | 返信方針・排他・公開の**現在値**（設定できないだけでなく**見えない**） | `replies_policy` / `exclusive` / `isPublic` が未読 |
| **投稿の編集履歴** | 投稿詳細 | ⚠ **「編集済み ○○」と出しておいて**（`post_tile.dart:620`）、**何がどう変わったかを見る導線が無い** | `GET /api/v1/statuses/:id/history` 未使用 |
| **プレビューカードの著者** | タイムライン | 記事の著者（fedi アカウントへの紐付けを含む） | PreviewCard の `authors` / `author_name` が未読 |

⚠ **「編集履歴」は優先度が低い。**⚠⚠ **プリセット 5 台では編集済み投稿がほぼ発生しない** —— pooza/mastodon は編集の導線をフォークで落としてあり、Misskey は上流に編集機能が無い（[#1054](https://github.com/pooza/capsicum/issues/1054) の close コメントで実測済み）。**踏むのはリモートから流れてくる投稿だけ。**


### 8-6. 分類と起票（2026-10-02）

⚠ **チェックリスト型のアンブレラにしない**方針どおり 1 件 = 1 Issue。**この文書と api-gap 側で重複する項目は api-gap 側の Issue に寄せた**（同じ直し方になるため）。

| | 内容 | 分類・Issue |
| --- | --- | --- |
| 8-1 | リストの設定（返信方針・排他・公開）を見られない / 変えられない（両 SNS）+ フォローの `withReplies` | **拾う** → [#1211](https://github.com/pooza/capsicum/issues/1211)（`enhancement`） |
| 8-1 | 予約投稿の時刻を変更できない | **拾う** → [#1212](https://github.com/pooza/capsicum/issues/1212)（`enhancement`） |
| 8-2 | 引用の撤回・引用ポリシーの事後変更 | **拾う** → [#1213](https://github.com/pooza/capsicum/issues/1213)（`enhancement`） |
| 8-3 | お知らせの掲載期間 | **拾う** → [#1214](https://github.com/pooza/capsicum/issues/1214)（`enhancement`） |
| 8-2 | DM の既読・削除が無い | **拾う** → [#1206](https://github.com/pooza/capsicum/issues/1206)（`bug`・api-gap §13-6 と同じ Issue） |
| 8-2 | リストメンバー / 検索の尻切れ | **拾う** → [#1202](https://github.com/pooza/capsicum/issues/1202)（`bug`・api-gap §13-1 と同じ Issue） |
| 8-3 | 通知の未読数 | **拾う** → [#1207](https://github.com/pooza/capsicum/issues/1207)（api-gap §13-4 と同じ Issue） |
| 8-2 | 通知の個別削除・全消し | ⚠ **拾わない（単独では）** —— 通知の既読（[#1205](https://github.com/pooza/capsicum/issues/1205)）と未読数（[#1207](https://github.com/pooza/capsicum/issues/1207)）と**同じ画面**なので、あちらを触る回に一緒に見る |
| 8-3 | 投稿の編集履歴 | ⚠ **拾わない。**プリセット 5 台では編集済み投稿がほぼ発生しない（8-3 の注）。⚠ **再浮上させないため理由を残す** |
| 8-3 | プレビューカードの著者 | ⚠ **拾わない。**[#1033](https://github.com/pooza/capsicum/issues/1033) で「カードの大きさを一定にする」と決めており、カードに要素を足す方向を採っていない |

⚠ **マイルストーンは付けていない。**⚠⚠ **棚卸し由来 13 件（api-gap §13-13 の 9 件 + ここの 4 件）の枠割りは pooza の判断。**v2.1〜v2.5 は「1 枠 1 大更新」で設計されている（`docs/roadmap.md` 2026-09-30）ので、**まとめて放り込むと枠の設計が壊れる**。

⚠ **この文書の「まだ起票していないもの」は、上の「拾わない」3 件だけ**（理由つきで残している）。
