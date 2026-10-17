# フィルタ（キーワードミュート）の管理 UI 設計書（#1047）

✅ **v2.3.0 で実装済み**（#1289 / #1047 / #1290）。⚠ **決定済み事項はいまも効く**（コードのコメントが節番号で参照している）ので archive へは移さない。未来形の記述は書いた当時の計画として読む。

[#1047](https://github.com/pooza/capsicum/issues/1047) を Issue へ分解できる状態にするための設計書。[large-item-workflow.md「大玉の進め方」](large-item-workflow.md) の 4 に従い、`## 決定済み事項` と `## 未決事項` を分ける。

- 作成日: **2026-10-15**（v2.3 の主役。枠の正本は [GitHub Milestone v2.3](https://github.com/pooza/capsicum/milestone/89)）
- 実測は capsicum `develop` の `eefc74d6`、Mastodon フォーク `bshockdon` の `d1b6965379`（4.7.3）、Misskey フォーク `daisskey` の `55e580452a`（2026.10.0）時点
- 事前調査（2026-10-15）で見つけた不具合 [#1288](https://github.com/pooza/capsicum/issues/1288)（正規表現のワードミュートで `/api/i` が落ちる）は同日に直した。**この設計書はその後の状態を前提にする**
- ⚠ **これは画面仕様ではない。**狙いは「Issue 本文の問い 3 つに答える」「難所がどこかを示す」「分解の単位を決める」の 3 点
- **2026-10-15 追記: 未決事項 1〜3 が決着した**（pooza 判断・同日）。入口の名前は **SNS の本来の用語**（Mastodon「フィルター」／Misskey「ワードミュート」）、hide の弱めは **Web と同じ**、Misskey の大文字小文字は **本家に揃える**。→ **Issue へ分解できる状態になった**（決定済み事項 9）

## 結論

⚠⚠ **難所は Issue 本文が立てた問い（2 つのモデルを 1 つに畳むか）ではなく、capsicum が Mastodon のフィルタの「適用先（context）」を見ていないことにある。**

| Issue 本文の前提 | 実測 |
| --- | --- |
| Misskey の `notes/thread-muting/*` と `renote-mute/*` は未使用 | ⚠ **どちらも使っている**（[#1208](https://github.com/pooza/capsicum/issues/1208) / [#1245](https://github.com/pooza/capsicum/issues/1245)）。Misskey で残っているのは `mutedWords` / `hardMutedWords` の書き戻しだけ |
| Misskey に `mutedWords` を書き戻す口があるか不明 | **ある。**`i/update` が `mutedWords` / `hardMutedWords` を受ける（形は `(string[] \| string)[]`・上限は文字数の合計・正規表現は RE2 で検証） |
| Mastodon は「サーバーが判定して結果を返す」 | 半分だけ正しい。**判定（一致）はサーバー、適用（どの画面で伏せるか）はクライアントの責務。**`filtered[].filter.context` に適用先が載って返るが、**capsicum はこれを読まずに全画面で伏せている** |

→ **管理 UI を作る前に、適用の側を直す必要がある。**UI が「通知だけ」と表示しているフィルタがホームでも効く、という嘘が UI を足した瞬間に見えるようになる。逆に、適用を直す仕事は UI が無くても成立する（Web UI で作ったフィルタが正しく効くようになる）。

Issue 本文の問い 3 つへの答え:

| 問い | 答え |
| --- | --- |
| 1. 1 つの機能として見せるか、別物として見せるか | **入口は 1 つ、画面とインターフェースは SNS ごと。畳まない**（決定済み事項 4） |
| 2. Misskey の `mutedWords` を書き戻す口はあるか | **ある**（決定済み事項 1-2） |
| 3. 伏せ方（hide / warn）を管理 UI から確認・調整できるようにするか | **フィルタごとの動作として見せる。伏せ方そのものの設定は作らない**（決定済み事項 7） |

規模は「大更新 1 件」のままだが、**分解すると 3 本**になる（決定済み事項 9）。

---

## 決定済み事項

### 1. 現状の棚卸し（実測）

#### 1-1. Mastodon（4.7.3）

| | 実測 |
| --- | --- |
| API | `api/v2/filters` の index / create / show / update / destroy、`filters/:id/keywords`、`filters/keywords/:id`、`filters/:id/statuses`、`filters/statuses/:id`（`config/routes/api.rb`）。v1 `filters` は 2022-11-14 に非推奨 |
| 受けるパラメータ | `title`（256 字まで）・`context[]`（`home` / `notifications` / `public` / `thread` / `account`・必須）・`filter_action`（**`warn` / `hide` / `blur` の 3 値**）・`expires_in`（秒・空なら無期限）・`keywords_attributes[]`（`keyword`（512 字まで）・`whole_word`・`_destroy`） |
| スコープ | `read:filters` / `write:filters`。capsicum は `read write follow push` を要求しているので含まれる |
| 判定 | サーバー。Status の `filtered[]` に `filter`（`id` / `title` / `context` / `expires_at` / `filter_action`）・`keyword_matches` / `status_matches` が載る。**`context` に関係なく、一致したフィルタをすべて返す**（`custom_filter.rb` の `apply_cached_filters`） |
| 配送 | **ホームの配送（`FeedManager`）も通知の配送（`NotifyService`）も、キーワードフィルタでは落とさない。**通知の `filtered` 列は通知ポリシーの話で別物。⚠ **つまり通知にもフィルタは「載って届く」ので、クライアントが伏せなければ素通りする** |
| Web UI の適用 | `utils/filters.ts` でカラム種別を `context` へ写し、`selectors/index.js` で `blur` はメディアだけに、それ以外は投稿全体に掛ける。**詳細・ブックマーク・お気に入り・検索では `hide` を `warn` に弱める** |

#### 1-2. Misskey（2026.10.0）

| | 実測 |
| --- | --- |
| 読む口 | `i` の `mutedWords` / `hardMutedWords`。形は **`(string[] \| string)[]`**（配列はキーワードの AND、文字列は正規表現 `/pattern/flags`）。`policies.wordMuteLimit` も返る（既定 200） |
| 書く口 | `i/update` の `mutedWords` / `hardMutedWords`。**全置換**（差分ではない）。文字数の合計が `wordMuteLimit` を超えると `TOO_MANY_MUTED_WORDS`、正規表現が RE2 で通らなければ `INVALID_REGEXP`。`mutedWords` を送ると `enableWordMute` が連動する |
| 判定 | **クライアント。**backend は TL の絞り込みに使っていない。本家は `frontend/src/utility/check-word-mute.ts` で note → reply → renote を見る |
| 本家の画面 | 「ミュートとブロック」の中に **ワードミュート（ソフト）とハードワードミュートの 2 段**（`mute-block.vue`）。入力は 1 行 1 条件・空白区切りが AND・`/…/` が正規表現 |

#### 1-3. capsicum の現状

| | 実測 |
| --- | --- |
| モデル | `FilterAction { hide, warn }`（`capsicum_core/lib/src/model/post.dart`）。`Post.filterAction` / `filterTitle` の 2 つだけ。⚠ **適用先を持つ場所が無い** |
| Mastodon の解釈 | `_parseFilterResult`（`mastodon/extensions.dart`）。`hide` が 1 つでもあれば hide、それ以外は warn。**`blur` は warn に落ちる。`context` は読まない** |
| Misskey の解釈 | `MisskeyAdapter._applyWordFilter`。hard → hide、soft → warn、タイトルは設定画面の段の名前（「ハードワードミュート」「ワードミュート」）。畳んだ行は「フィルター:」を付けずタイトルだけを出す（決定済み事項 4 の本来の用語・[#1293](https://github.com/pooza/capsicum/issues/1293)）。`i` で読んだ語を adapter に保持し、[#1185](https://github.com/pooza/capsicum/issues/1185) の TTL で取り直す |
| hide の適用 | `timeline_provider.dart`（5 か所）と `hashtag_provider.dart`。⚠ **通知・スレッド・プロフィール・検索・ブックマーク・お気に入りでは落としていない** |
| warn の表示 | `post_tile.dart` が「フィルタ: {title}／表示する」の 1 行に畳む。**どの画面で見ているかを知らないので、context があっても判定できない** |
| 管理 | `GET /api/v2/filters` を呼ぶコードは無い。`i/update` は `updateI()`（プロフィール編集・[#865](https://github.com/pooza/capsicum/issues/865)）が既にあり、引数を足せば使える |
| 似た画面 | 「ブロックとミュート」`moderation_list_screen.dart`（[#1039](https://github.com/pooza/capsicum/issues/1039)）と「リストの設定」`list_management_screen.dart`（[#1211](https://github.com/pooza/capsicum/issues/1211)）。能力は `capsicum_core/lib/src/social/interfaces/*_support.dart` の `abstract mixin class` で、UI は `adapter is XxxSupport` で出し分ける |

### 2. Mastodon のフィルタは適用先（context）を見て掛ける

⚠⚠ **これが #1047 の前提で、UI より先に入れる**（決定済み事項 9 の Issue 1）。

対応表は Mastodon Web（`utils/filters.ts`）に揃える。capsicum の画面名で書く:

| capsicum の画面 | `context` | 備考 |
| --- | --- | --- |
| ホーム・リスト | `home` | |
| ブックマーク・お気に入り | `home` | `hide` は `warn` に弱める（決着・下記） |
| ローカル・連合・ハッシュタグ TL | `public` | デフォルトハッシュタグで置き換えたローカル TL も `public` |
| 検索（投稿） | `public` | `hide` は `warn` に弱める（決着・下記） |
| 通知 | `notifications` | ⚠ **いまは一切落としていない。**サーバーが落とさないので、ここを見ないと「通知だけ伏せる」フィルタが効かない |
| スレッド（会話） | `thread` | `hide` は `warn` に弱める（決着・下記。開いた本人が読みたい投稿を消さない） |
| プロフィールの投稿 | `account` | |
| デッキのカラム | カラムの種別で上の表どおり | カラム固有の扱いは要らない |

決め方:

- **詳細（スレッド）・ブックマーク・お気に入り・検索では `hide` を `warn` に弱める**（2026-10-15 pooza 判断・未決事項 2。Mastodon Web と同じ）。弱めないと、ブックマークした投稿が一覧から消えて「消えた」と見える
- **一致したフィルタのうち、見ている画面の `context` を含むものだけを採る。**強さは **hide > warn > blur**（warn は本文ごと畳むので、メディアだけをぼかす blur より強い・[#1289](https://github.com/pooza/capsicum/issues/1289) の実装で確定）。タイトルは採ったフィルタの `title` を「、」で連結する（Web と同じ。以前は最初の 1 件しか出さなかった）
- **通知に掛けるのは、他人の投稿が主役の種別だけ**（メンション・引用・編集・購読中の新規投稿。Mastodon Web の `actions/notification_groups.ts` と同じ）。⚠ お気に入り・ブースト・リアクション・投票の通知に付く投稿は**自分の投稿**で、Mastodon は自分の投稿にもフィルタの結果を載せるため、掛けると自分のキーワードで反応の通知が消える。hide は一覧から落とし、warn は本文を畳む。**デスクトップの OS 通知は warn でも出さない**（Web のデスクトップ通知と同じ・畳めないバナーに出さない）
- **`context` は `filtered[].filter.context` から読む。**フィルタ一覧（`GET /api/v2/filters`）を別に引く必要は無い。期限切れのフィルタはサーバーが `filtered` に載せないので、クライアントで期限を見なくてよい
- **Misskey のワードミュートは「全画面」として同じ型に乗せる**（Misskey に適用先の概念が無いため）。判定の型を 1 つにすることで、タイル側は SNS を知らずに済む
- **hide の適用は一覧を持つ側（provider）、warn / blur の描画はタイル側。**hide をタイルで消すと空の行が残り、続き読みの件数も狂う。タイルは「どの画面で描かれているか」を知らないので、**画面の種別を `InheritedWidget`（または Riverpod の scope）で一覧の外側から渡す**。タイルの呼び出し元ごとに引数を通す形にはしない（呼び出し元が多く、デッキでも同じタイルを使うため）
- **ストリーミングで届く投稿にも `filtered` は載る**（2026-10-15 にソースで確認: `push_update_worker.rb` が `StatusCacheHydrator#hydrate(account_id)` で受信者ごとに組み立て、`status_cache_hydrator.rb:61` で `filtered` を入れる）。ライブ取り込みの hide 判定がそのまま効く

モデルの変え方（Issue 1 の中身）:

- `Post.filterAction` / `filterTitle` を、**一致の一覧**（動作・タイトル・適用先の組）に置き換える。読む側は「画面の種別」を渡して解決する
- ⚠ **既存の `filterAction` を読む箇所が 7 か所 + テスト**ある。置き換えで古い期待値が残らないよう、全量を流す（[docs/CLAUDE.md](CLAUDE.md)「振る舞いを変えた回は、テストを部分実行で済ませない」）

### 3. `blur` を動作として持つ

Mastodon 4.7 の `blur` は**メディアだけをぼかし、本文は見せる**（Web の `selectors/index.js`）。capsicum は warn に落として投稿全体を畳んでいるので、作った本人の意図より強い。

- `FilterAction` に `blur` を足し、**閲覧注意のメディアと同じぼかし**を当てる（既存の仕組みを使う。新しい描画は作らない）
- 管理 UI の動作の選択肢は **警告 / 非表示 / メディアをぼかす** の 3 つ。⚠ サーバーが `blur` を知らない版（4.6 以前）では作成が 422 になるので、**作成の失敗をそのまま文言にする**（版で分岐しない —— [product-policy.md](product-policy.md) の対応バージョン方針）
- Misskey に blur は無い（ソフト = 警告・ハード = 非表示の 2 段だけ）

### 4. 1 つの概念に畳まない。入口は 1 つ、画面とインターフェースは SNS ごと

| | Mastodon フィルタ | Misskey ワードミュート |
| --- | --- | --- |
| 単位 | **フィルタ**（名前つき・キーワード複数・適用先・期限・動作） | **行**（キーワードの AND、または正規表現） |
| 動作 | warn / hide / blur をフィルタごとに | ソフト（warn）/ ハード（hide）の **2 つの一覧**に分かれる |
| 適用先 | 5 種類から選ぶ | 無い（全画面） |
| 期限 | ある | 無い |
| 正規表現 | 無い（`whole_word` だけ） | ある |
| 保存 | フィルタ単位の CRUD | **一覧の全置換** |
| 判定 | サーバー | クライアント（capsicum） |

畳むと両方から落ちる: 最小公倍数（キーワード 1 つ → 警告 / 非表示）にすると、**Web UI で作った多キーワードのフィルタや AND の行を capsicum で壊す**。最大公約数にすると、どちらの SNS でも使えない項目が画面に並ぶ。**[#1211](https://github.com/pooza/capsicum/issues/1211)（リストの設定）が 1 つのインターフェースで済んだのは、項目が揃っていたから。ここは揃っていない。**

- インターフェースは 2 本: **`FilterSupport`**（Mastodon・フィルタの一覧 / 作成 / 更新 / 削除）と **`WordMuteSupport`**（Misskey・ソフト / ハードの一覧を読む / 全置換で書く）
- **設定画面の入口は 1 つ**（「ブロックとミュート」の隣）。タップ先で `adapter is FilterSupport` / `is WordMuteSupport` を見て画面を選ぶ。どちらでもないアダプターでは入口を出さない
- **入口の名前は SNS の本来の用語**（2026-10-15 pooza 判断・未決事項 1）: Mastodon のアカウントでは **「フィルター」**（本家の日本語ロケールの表記・長音つき）、Misskey のアカウントでは **「ワードミュート」**。設定画面は現在のアカウントの SNS で項目を出し分けている（Misskey では「フォロー中のハッシュタグ」を隠す）ので、同じ仕組みで名前を変える。⚠ **畳んだタイルの「フィルタ: …」も「フィルター: …」に揃える**（Issue 1 で直す。[product-policy.md](product-policy.md) の用語統一は「最新の Mastodon / Misskey に追従する」なので、本家の表記に合わせる側が正）

### 5. Mastodon の管理画面の形

- **一覧 → 編集**の 2 画面（[#1211](https://github.com/pooza/capsicum/issues/1211) と同じ組み立て）。一覧は `GET /api/v2/filters`（キーワード込みで返る）で、名前・動作・期限・キーワード数を 1 行に。期限切れは薄く出す
- 編集の項目は **名前・キーワード（複数・各行に「単語全体に一致」の切り替え）・適用先（5 つのチェック・capsicum の画面名で説明）・動作（3 択）・期限（なし / 30 分 / 1 時間 / 6 時間 / 12 時間 / 1 日 / 1 週間 —— Web と同じ刻み）**
- 保存は作成が `POST /api/v2/filters`、更新が `PUT /api/v2/filters/:id`。キーワードの増減は `keywords_attributes[]` の `id` / `_destroy` で同じ要求に載せる（`filters/:id/keywords` を別に叩かない）。削除は `DELETE`
- ⚠ **保存しても、読み込み済みの投稿には効かない**（判定はサーバーが取得時に行うため。Web UI も同じ）。画面に「次に読み込んだ投稿から効きます」と 1 行出す。保存後に全タイムラインを引き直す仕組みは作らない
- v1 `filters` は使わない

### 6. Misskey の管理画面の形

- 本家に倣い **ソフト / ハードの 2 段**。各段は複数行のテキスト 1 つで、**1 行 1 条件・空白区切りが AND・`/…/flags` が正規表現**（本家の入力規則をそのまま。利用者が Web で見ている形と揃える）
- 保存は `i/update` に**その段の一覧を丸ごと**送る（`updateI()` に `mutedWords` / `hardMutedWords` を足す）。**応答の `MeDetailed` で adapter の保持語を更新する**（次の TTL まで古い語で判定しないため）
- **上限と正規表現の検証はサーバーに任せ、`TOO_MANY_MUTED_WORDS` / `INVALID_REGEXP` を文言にする。**`policies.wordMuteLimit` を読んで残り文字数を出すのは、要望が出てから
- ⚠ **保存は既に読み込んだ投稿に効かない**（判定が取得時のため）。Mastodon と同じ 1 行を出す
- **キーワードの大文字小文字は本家に揃えて区別する**（2026-10-15 pooza 判断・未決事項 3）。capsicum は従来から区別していなかった（[#1288](https://github.com/pooza/capsicum/issues/1288) でもそのまま）が、UI が付くと「Web で効かない語が capsicum では効く」差が目につく。⚠ **既存の利用者には「いままで伏せていた投稿が出る」変化**なので、Issue 3 のリリースノートに書く

### 7. 入口・導線・伏せ方

- 入口は設定の「ブロックとミュート」の隣。副題は「キーワードで投稿を伏せる」の意
- **伏せたタイル（「フィルタ: …／表示する」）からの導線は付けない。**タップは「表示する」のまま。長押しで設定へ飛ばす案は、何が起きるか見えないので採らない
- デッキでは**現在のアカウント**の設定を開く（[deck-ui-decisions.md](deck-ui-decisions.md) 決定済み事項 15 と同じ・再判定しない）
- **伏せ方（畳む / ぼかす / 消す）を変える設定は作らない。**動作はフィルタごとにサーバーへ保存するものなので、capsicum 側に別の段を作ると「Web と違う見え方」が生まれる。Issue 本文の問い 3 への答え

### 8. この枠で拾わないもの

| 拾わないもの | 理由 |
| --- | --- |
| 投稿単位のフィルタ（`filters/:id/statuses`・投稿メニューの「フィルタへ追加」） | キーワードと別の導線（投稿のメニュー）が要る。要望が出てから別 Issue |
| Mastodon v1 `filters` | 2022 年に非推奨。多キーワードのフィルタを壊す |
| Misskey のサーバーミュート・絵文字ミュート | ワードミュートと別の設定。[#1039](https://github.com/pooza/capsicum/issues/1039) の系統 |
| Mastodon の通知ポリシー（`notifications/policy`） | [server-settings-gap-inventory.md](server-settings-gap-inventory.md) §2 で「読む必要なし」と決着済み |
| 伏せた投稿の集計・「なぜ伏せたか」の詳細（`keyword_matches`） | タイトルで足りる。Web も出していない |

### 9. Issue への分解（案）

| 順 | Issue | 中身 | 規模 |
| --- | --- | --- | --- |
| **1** | [#1289](https://github.com/pooza/capsicum/issues/1289) Mastodon のフィルターの適用先（context）と `blur` を見る | 決定済み事項 2・3。モデルの置き換え・provider の hide・タイルの warn / blur・通知と検索への適用・画面種別の受け渡し | **中**。⚠ 触る場所は多いが型は 1 つ |
| **2** | [#1047](https://github.com/pooza/capsicum/issues/1047) `FilterSupport` と Mastodon の管理画面 | 決定済み事項 5。一覧 / 編集・v2 の CRUD・設定の入口 | **中〜大**（この枠の本体。#1047 自身をこの範囲にした） |
| **3** | [#1290](https://github.com/pooza/capsicum/issues/1290) `WordMuteSupport` と Misskey の管理画面 | 決定済み事項 6。2 段の入力・`updateI()` の拡張・保持語の更新 | **小〜中** |

**2026-10-15 に起票した。**アンブレラは作らない（[docs/CLAUDE.md](CLAUDE.md)「マイルストーンに載らない集約 Issue を作らない」）。#1047 は本体（2）の Issue としてそのまま使う。

- **順序は 1 → 2 → 3。**1 が無いと 2 の UI が嘘をつく。3 は 1 に依存しない（Misskey は全画面）が、入口（2）を共有する
- 1 と 2 を同じ Issue にしない。**1 は UI が無くても価値がある**（Web で作ったフィルタが正しく効く）し、[#1282](https://github.com/pooza/capsicum/issues/1282) と同じ「畳まれているはずのものが見えている」型として単独で検証できる
- ⚠ **設計書から起票した Issue の本文は、着手前に実装と突き合わせる**（[large-item-workflow.md](large-item-workflow.md)「設計書 → 分解 → 実装まで通して分かったこと」）

---

## 未決事項

### 1〜3. 決着済み（2026-10-15 pooza）

書いた当日に決着した。本文は決定済み事項へ移してある: **1. 入口の語**は SNS の本来の用語（決定済み事項 4）、**2. `hide` の弱め**は Web と同じ（決定済み事項 2）、**3. Misskey の大文字小文字**は本家に揃える（決定済み事項 6）。⚠ 1 で「フィルタ」「ワードミュート」「キーワードミュート」の 1 語に揃える案（A〜C）を出したが、**「それぞれの本来の用語」という第 4 の形を pooza が選んだ**。本家と往復する利用者が迷わない側。

### 4. Issue 1 で実測して埋めるもの（2026-10-15 に決着）

- ストリーミングの `update` に `filtered` が載るか → **載る**（決定済み事項 2・ソースで確認）
- 通知一覧で hide を適用したとき、グループ化された通知（[#1048](https://github.com/pooza/capsicum/issues/1048)）の数え方 → **問題にならない。**フィルタを掛けるのはメンション・引用・編集・購読中の新規投稿だけで、Mastodon がグループにまとめるのはお気に入り・ブースト・フォローなので、掛ける種別とまとまる種別が重ならない
