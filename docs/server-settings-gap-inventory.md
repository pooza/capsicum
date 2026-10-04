# 棚卸し: サーバー側に保存された設定のうち、capsicum が反映すべきもの

[#992](https://github.com/pooza/capsicum/issues/992) の成果物。ユーザーが WebUI で**既に設定した値**のうち、capsicum も従うべきものを探す。

- 実施日: **2026-09-03**
- 基準: **pooza フォーク**（美食丼 = `~/repos/mastodon` の `bshockdon` / ダイスキー = `~/repos/misskey` の `daisskey`）
- 兄弟の棚卸し: [#993](https://github.com/pooza/capsicum/issues/993)（API 基準・完了 → [api-gap-inventory.md](api-gap-inventory.md)）/ [#991](https://github.com/pooza/capsicum/issues/991)（WebUI 基準・第 1 巡完了 → [webui-gap-inventory.md](webui-gap-inventory.md)）
- **親 Issue #992 は 2026-09-04 に close 済み**（完了条件＝この計画書を残すところまで、を満たしたため）。残った宿題は §5 → [#1078](https://github.com/pooza/capsicum/issues/1078)、§6 の未起票分 → [#1079](https://github.com/pooza/capsicum/issues/1079) へ切り出した

⚠ **この文書はチェックリストではない。**拾うと決めたものは、ここから**最初からマイルストーンを付けた個別 Issue** として切り出す。

## 0. 結論から: 「誤爆」は 0 件・「隠すべきものを隠していない」が 1 件

⚠ **2026-09-03 に pooza の指摘で判定を 1 つ引き上げた。**当初 🟡（実害ではない）としていた §3-1（プロフィールのタブ表示設定を見ていない）を **分類 A（1.x で片付ける）** に上げている。

> **隠すべきものは隠す系は、本来はやってなきゃいけないやつ**

**本人が「出さない」と設定したタブを capsicum が出しているのは、「意思表示の無視」ではなく「実装漏れ」として扱う**という判断。⚠ **この基準は #992 の本文には無かった。**本文は実害を「誤爆（投稿）」と「見たくないものが見える（読み方）」の 2 種類で定義していたが、**「見せたくないものが見えている」という第 3 の型**がある。以後の棚卸しでもこの軸で見る。

指摘を受けて **「隠す」系だけを両 SNS で洗い直した結果は §2-2**。**Misskey 側は全部サーバーが強制していて穴は無く、クライアント責任で残るのは Mastodon のプロフィールタブ 1 件だけ**だった。

### 誤爆（投稿の挙動）については 0 件

⚠ **#992 の本文が立てていた仮説は外れた。**Issue にはこう書いてあった:

> #991（UI の未実装）… 「無い」だけ / **こちら（設定の反映漏れ）… 誤った挙動になる**
> 「デフォルト公開範囲はフォロワーのみ」「メディアは常に閲覧注意」と設定しているのに capsicum が見ていなければ、それは機能不足ではなく**誤爆**。**価値の密度はこちらの方が高いと見ている**

**実測の結果、優先順 1（投稿の挙動）・優先順 2（読み方）とも反映漏れは 0 件だった。**誤爆する経路は 1 本も見つかっていない。

理由は 2 つあり、**どちらも「たまたま」ではない**:

1. **サーバー側が効かせている設定が多い。**Mastodon の `post_status_service.rb` はクライアントが値を送らなければユーザー既定を使う。Misskey の `alwaysMarkNsfw` / `autoSensitive` は `DriveService` がアップロード時に適用する。**クライアントが読む必要がそもそもない。**
2. **capsicum 側が「送らない」を意識して書いている。**下の §1 のとおり、`sensitive` は `draft.sensitive ? true : null` と書かれていて、**false を送るとサーバー既定を上書きしてしまうことを踏まえた形**になっている。

⚠ **この結論は「#992 が無駄だった」という意味ではない。**「誤爆していない」を**推測ではなく実測で確定させた**ことに価値がある。以後「サーバー設定を見ていないのでは」という疑いが出たら、この文書を根拠に切り分けを飛ばせる。

## 1. 優先順 1 — 投稿の挙動を決める設定（反映漏れ 0 件）

| 設定 | サーバーが効かせるか | capsicum | 判定 |
| --- | --- | --- | --- |
| Mastodon デフォルト公開範囲 | ○ `post_status_service.rb:75`（未指定時） | **読んでいる** — `source['privacy']` → `defaultScope`（`mastodon/extensions.dart:70`）→ 投稿画面が初期値に使う（`compose_screen.dart:614`） | ✅ |
| Mastodon 既定の閲覧注意 | ○ `post_status_service.rb:73`（**`nil` のときだけ**） | **送らない** — `sensitive: draft.sensitive ? true : null`（`mastodon/adapter.dart:294`）。`?sensitive` の null-aware element で **null なら body に載らない** | ✅ |
| Mastodon 既定言語 | ○ `post_status_service.rb:268`（`valid_locale_cascade`） | **送らない** — `PostDraft.language` の既定が `null` | ✅ |
| Mastodon 既定の引用ポリシー | ○ `credentials_controller.rb:53` / 未指定時はユーザー設定 | **送らない** — `PostDraft.quoteApprovalPolicy` の既定が `null` | ✅ |
| Misskey デフォルト公開範囲 | ✗（クライアント側の責務） | **読んでいる** — `defaultNoteVisibility` → `defaultScope`（`misskey/extensions.dart:77`） | ✅ |
| Misskey `alwaysMarkNsfw` | ○ `DriveService.ts:609`（アップロード時） | 読んでいない | ✅ **読む必要なし** |
| Misskey `autoSensitive` | ○ `DriveService.ts:614` | 読んでいない | ✅ **読む必要なし** |

### ここが唯一の地雷（すでに踏んでいない）

⚠ Mastodon の `post_status_service.rb:73` は

```ruby
@sensitive = (@options[:sensitive].nil? ? @account.user&.setting_default_sensitive : @options[:sensitive]) || ...
```

**`nil` のときだけ**ユーザー既定にフォールバックする。つまり **`sensitive: false` を明示的に送ると、ユーザーが「常に閲覧注意」に設定していても false が勝つ**。

capsicum は `draft.sensitive ? true : null` と書いてこれを回避している。⚠ **ここを「`sensitive: draft.sensitive` の方が素直だ」とリファクタすると、静かに誤爆が生まれる。**同じ形は `visibility` / `language` / `quote_policy` にもある。**この文書はその再発防止の記録でもある。**

## 2. 優先順 2 — 読み方を決める設定（実害側の反映漏れ 0 件）

| 設定 | サーバーが効かせるか | capsicum | 判定 |
| --- | --- | --- | --- |
| Mastodon フィルタ（キーワードミュート） | △ 判定はサーバー・**適用はクライアント**（Status の `filtered` に結果を載せて返す・`status_serializer.rb:18,147`） | **読んでいる** — `_parseFilterResult(filtered)`（`mastodon/extensions.dart:99`） | ✅ |
| Misskey `mutedWords` / `hardMutedWords` | ✗（クライアント側の責務） | **読んで適用している** — `adapter.dart:210-211` で保持し `480-514` で判定 | ✅ |
| Mastodon 通知ポリシー（`notifications/policy`） | ○ `notify_service.rb:30` の `NotificationPolicy` | 読んでいない | ✅ **読む必要なし** |
| Misskey `notificationRecieveConfig` | ○ `NotificationService.ts:100`（通知生成時） | 読んでいない | ✅ **読む必要なし** |
| Mastodon `hide_collections` | ○ `follower_accounts_controller.rb:25` が空配列を返す | 読んでいない（モデルには存在） | 🟡 §3-2 |

⚠ **[#1047](https://github.com/pooza/capsicum/issues/1047)（フィルタの管理 UI）と混同しない。**あちらは「capsicum からフィルタを**作れない**」という話。**適用されているかどうかは別問題で、こちらは適用されている。**

## 2-2. 「隠すべきものを隠す」系の全数（pooza の指摘で追加した軸）

**「本人が隠すと設定したものを、capsicum が見せていないか」だけを両 SNS で洗った。**判定の分かれ目は **サーバーが強制するか / クライアントが従うしかないか** の 1 点。

| 設定 | サーバーが強制するか | capsicum | 判定 |
| --- | --- | --- | --- |
| Misskey `hideOnlineStatus`（オンライン状態を隠す） | ○ `UserEntityService.ts:375` が `'unknown'` を返す | そもそもオンライン状態を表示していない | ✅ |
| Misskey `publicReactions`（リアクション一覧の公開） | ○ `users/reactions.ts:87` が本人以外を弾く | — | ✅ |
| Misskey `followersVisibility`（フォロワー一覧の公開範囲） | ○ `users/followers.ts:115-120` が `private` / `followers` で一覧を返さない | — | ✅ |
| Misskey `followingVisibility`（フォロー一覧の公開範囲） | ○ `users/following.ts:123-128` で同上 | — | ✅ |
| Mastodon `hide_collections`（フォロー / フォロワーを隠す） | ○ `follower_accounts_controller.rb:25` が空配列を返す | 読んでいない | 🟡 **見せ方だけ問題**（§3-1 に統合） |
| **Mastodon `show_media` / `show_media_replies` / `show_featured`（プロフィールのタブ）** | ✗ **強制できない**（タブの出し分けはクライアントの描画） | **読んでいるが UI に反映していない** | 🔴 **§3-1** |

⚠ **この表がいちばん効く形。**「隠す」系は**サーバーが強制できるものは全部サーバーが強制している**ので、クライアントが落とせる穴は「**サーバーに強制のしようがないもの**」に限られる。プロフィールのタブは**描画の話なのでサーバーには止めようがない** — だから 1 件だけここに残った。

**次に同種を探すときは「サーバーが強制できない設定」から入れば早い。**

## 3. 分類 A — 1.x の間に片付けるもの

### 3-1. 🔴 プロフィールのタブ表示設定を見ていない（Mastodon）

**本人が「出さない」と設定したタブを capsicum が出している。**

- サーバー: `show_media` / `show_media_replies` / `show_featured` は**公開の** account serializer に載る（`account_serializer.rb:12`）。⚠ **本家 Mastodon の機能**（upstream/main にも存在・フォーク固有ではない）
- 意味: locale の説明文が正本 — 「『メディア』は**任意のタブ**で、画像や動画を含む投稿を表示します」（`account_edit.profile_tab.show_media.description`）。つまり**アカウント本人がタブの出し分けを選べる**
- capsicum: モデルまでは読んでいる（`mastodon/extensions.dart:71-73`）が **UI 層で 0 ヒット**。`profile_screen.dart:607-613` は Posts / Media / Gallery / Pages を**無条件に**出している
- ⚠ **投稿自体は公開なので情報漏洩ではない。**ただし **pooza の判断で「本来やってなきゃいけない」側**として扱う（§0）。「意思表示の無視」で済ませない
- **`hide_collections` もここに束ねる**: サーバーが空を返すので漏れは無いが、capsicum は**「本人が隠している」旨を出さずに 0 件に見せている**。同じ「本人の設定に従った見せ方」の問題

⚠ **#993 の §6 が予告していたのはこれ。**「Account の設定系フィールドは capsicum が既に半分読んでいる。#992 では**読んでいるが UI に反映していない**の側から入るのが早い」— 実際その側にだけ残っていた。

## 3-2. 拾うか判断が要るもの（実害ではない）

### 🟡 `GET /api/v1/preferences` を一度も呼んでいない（Mastodon）

**capsicum の唯一の「取得経路すら無い」設定群。**

- `reading:expand:media`（閲覧注意メディアを既定で表示）/ `reading:expand:spoilers`（CW を既定で展開）/ `reading:autoplay:gifs`
- ⚠ **`source` からは取れない。**`/api/v1/preferences` 専用（`preferences_serializer.rb:9-11`）。投稿系（`posting:default:*`）は `source` と重複するので、**この 3 つのためだけに 1 エンドポイント増やす**話になる
- ⚠ **方向が「不便」であって「誤爆」ではない。**サーバーで「常に展開」にしていても capsicum は畳む＝**安全側に倒れている**。#992 の優先順 2 は「未適用だと**見たくないものが見える**」を実害と定義しているので、**逆向き**
- capsicum には端末側の近い設定がある（「画像をぼかす」「すべての画像をぼかす」「MFM のアニメーションを再生」）。⚠ **サーバー設定と端末設定のどちらを優先するかという設計判断が要る**ので、単純な「読んで従う」では済まない。⚠ **capsicum は狭幅・実況用途に最適化された端末側設定を持っている**ので、サーバー設定で上書きすると使い勝手が落ちる可能性がある

#### ✅ 決着: 拾わない（2026-10-04 pooza 承認・[#1079](https://github.com/pooza/capsicum/issues/1079)）

**端末側設定を正とする（Issue の案 1）。**⚠⚠ **再提案しない。**根拠は 3 つで、どれも時間が経っても変わらない性質:

1. ⚠ **方向が「不便」であって「誤爆」ではない。**サーバーで「常に展開」にしていても capsicum は畳む ＝ **安全側に倒れている**。#992 の優先順 2 が実害と定義したのは「未適用だと**見たくないものが見える**」で、ここは**逆向き**
2. ⚠⚠ **Misskey に対応する設定が無い。**従うと決めると**同じ利用者の Mastodon と Misskey で挙動が割れる**。§5-1 が「`i/registry` に従うかは #1079 と同じ判断・**別々に決めない**」と書いたのと同じ結論側へ揃えた
3. ⚠ **端末側設定は狭幅・実況用途に最適化されている。**サーバー設定で上書きすると使い勝手が落ちる

⚠ **この 3 設定のためだけに `/api/v1/preferences` を 1 本増やす**という費用の形も変わらない（`source` からは取れない）。→ **項目としては §4（分類 C）に置く。**実装 Issue は切り出さない。

## 4. 分類 C — 拾わない

| 項目 | 理由 |
| --- | --- |
| Mastodon `GET /api/v1/preferences`（`reading:expand:media` / `reading:expand:spoilers` / `reading:autoplay:gifs`） | **2026-10-04 に「拾わない」で決着**（[#1079](https://github.com/pooza/capsicum/issues/1079)）。⚠ **判断の本文は §3-2** —— 安全側に倒れている / Misskey に対応設定が無い / 端末側設定は狭幅・実況用途に最適化済み |
| Misskey `alwaysMarkNsfw` / `autoSensitive` / `notificationRecieveConfig`、Mastodon `notifications/policy` | **サーバー側で効いている。**クライアントが読んでも二重判定になるだけ |
| Misskey `i/registry/*` | WebUI のクライアント設定ストア。**capsicum には capsicum の設定がある**（#857 の設定バックアップが端末間移行を担当）。#993 の分類 C と同じ判断。⚠⚠ **2026-09-29 に理由を差し替えた。**中に**投稿の挙動を決める値が実在する**（`defaultNoteVisibility` 等）ので「紛れていないから拾わない」は成り立たない。**§5-1 が正本** |
| Misskey `roles/*`（ロールによる機能可否） | ⚠ **#993 §6 から回ってきたが、ここでも拾わない。**ロールは**サーバーが強制する**ので、capsicum が先読みして UI を出し分ける必要はない。出し分けないと「押せるが失敗する」になるが、それは**エラー処理の話**であって設定の反映漏れではない |
| テーマ・フォント・カスタム CSS・サウンド・ウィジェット配置（両 SNS） | **#992 の優先順 3 で最初に切り離すと決めてあるもの。**サーバー側に保存されていても capsicum が従う筋合いはない |
| Mastodon `indexable` / `discoverable` / `noindex` | 検索エンジン・ディレクトリへの掲載可否で、**サーバーとサーバー間の話**。⚠ `discoverable` は**既に対応済み**（プロフィール編集のトグル・[#865](https://github.com/pooza/capsicum/issues/865)） |
| Mastodon `attribution_domains` | 記事の著者表示に使うサーバー側の検証情報。クライアントの表示に効かない |

## 5. 宿題 3 点の確定（2026-09-29・[#1078](https://github.com/pooza/capsicum/issues/1078)）

#992 を close するとき「無かった」ではなく「**見ていない**」で終わっていた 3 点。**それぞれ「拾う / 拾わない」を確定させた。**

⚠⚠ **収穫は 5-2 の 1 件**（`source.privacy` が腐る経路が実在する）。5-1 は**前提が事実として誤っていた**が結論は変わらず、5-3 は拾わない。

### 5-1. Misskey の `i/registry` — ⚠ 前提は誤っていたが、結論は**拾わない**のまま

**#992 は「WebUI のクライアント設定ストアだから」という性質で分類 C にしていた。**⚠⚠ **「投稿の挙動を決める値は紛れていない」という含みは事実として誤り。**

**Misskey 本体のソースで確定した**（`packages/frontend/`・2026.9.1）:

- 設定の定義は `preferences/def.ts`。**`defaultNoteVisibility` / `defaultNoteLocalOnly` / `keepCw` / `rememberNoteVisibility` がここにある** ＝ **投稿の挙動を決める値**
- 同期先は `preferences.ts` の `cloudGet` / `cloudSet` で、**スコープ `['client','preferences','sync']`**。⚠ 同期は**キーごとのオプトイン**なので、registry に入っているとは限らない
- registry へ書く経路は他に `lib/pizzax.ts`（旧ストア）とゲーム 2 本（`drop-and-fusion` / clicker）。ゲームは投稿に効かない

**結論: 拾わない。**⚠ **理由を性質から実質へ差し替える**:

- これは**「サーバーに保存された WebUI のローカル設定」**であって、サーバーが強制する設定ではない。capsicum には capsicum の設定がある（#857 の設定バックアップが端末間移行を担当）
- ⚠ **従うと決めるなら、それは [#1079](https://github.com/pooza/capsicum/issues/1079)（Mastodon の `preferences` に従うか）と同じ判断**。**別々に決めない** —— 片方だけ従うと、同じ利用者の Mastodon と Misskey で挙動が割れる

#### 🔴 ついでに見つかった死にコード

⚠⚠ **`defaultNoteVisibility` は Misskey の API に存在したことが無い。**`packages/backend` / `misskey-js` で 0 ヒット、履歴を `git log -S` で追っても **frontend にしか現れない**。

**にもかかわらず capsicum は読んでいる**: `fediverse_objects` の `MisskeyUser.defaultNoteVisibility` → `misskey/extensions.dart` の `defaultScope: misskeyVisibilityRosetta[defaultNoteVisibility]`。**サーバーが送らないので常に null** ＝ **Misskey アカウントの `User.defaultScope` は必ず null**。

⚠ **実害は無い**（投稿フォームは capsicum 側の既定へ倒れる）。**誤解の元なので、消すか「常に null」と書き残すかを決める必要がある。**→ 5-4 で起票。

**✅ 決着（2026-10-01・[#1185](https://github.com/pooza/capsicum/issues/1185)）: 消した。**`MisskeyUser.defaultNoteVisibility` のフィールドごと落とし、`misskey/extensions.dart` の `defaultScope:` も外した。5-2 で「**サーバー側の設定に従う**」を採った以上、**従う先が存在しない値を写し続ける理由が無い**ため。

⚠ **消した跡には「足し直さない」理由を残した**（`user.dart` と `extensions.dart` の両方）。⚠⚠ **検査は「フィールドが無いこと」ではなく「サーバーが送ってきても写さないこと」で固定した**（`misskey_default_scope_absent_test.dart`）—— フィールドの有無だけ見ると、誰かが足し直したときに黙って復活する。⚠ **`misskeyVisibilityRosetta` 自体は生きている**（投稿の `visibility` 変換で使う）ので、対照群のテストで取り違えを防いでいる。

### 5-2. Mastodon の `source` — 🔴 **腐る。拾う（要修正）**

⚠⚠ **疑っていたとおりだった。**

- `Account.user` を作るのは `account_manager_provider.dart` の `restoreSessions`（**起動時の 1 回だけ**）
- 以後 `user` が差し替わるのは **capsicum 内でプロフィールを編集したとき**（`copyWithUser` の呼び出し元は `profile_edit_screen` の 2 箇所のみ）
- → **Mastodon の WebUI で既定の公開範囲を変えても、capsicum を再起動するまで古い値のまま**

**⚠⚠ `privacy` だけが危ない。**`source` の他の値と非対称になっている:

| `source` の値 | capsicum の扱い | 腐るか |
| --- | --- | --- |
| `privacy` | **読んで `defaultScope` にし、投稿時に `visibility` を明示的に送る** | 🔴 **腐る** |
| `sensitive` / `language` / `quote_policy` | **読まない・送らない**（§1 のとおり、サーバー側の既定に任せる） | ✅ 腐らない（毎回サーバーが最新の既定を当てる） |

⚠⚠ **この表の後半は 2026-10-01 に覆った**（[#1194](https://github.com/pooza/capsicum/issues/1194)）。`language` は**読まずに端末ロケールを送っていた**ので「送らない」が成立しておらず、**WebUI の設定が常に無視されていた**。下の決着を参照。

⚠ **「送らない」ほうが結果的に強かった**、という構図。⚠ **`privacy` を「送らない」に倒せるかは別問題**（capsicum は公開範囲を UI で選ばせるので、選んだ値は送る必要がある。倒せるのは「利用者が触っていないとき」だけ）。

⚠ **窓の長さは端末で違う。**モバイルは OS がアプリを落とすので自然に直るが、**デスクトップは常駐するので何日も古いままになりうる**。

→ **5-4 で起票。**

#### ✅ 決着（2026-10-01・[#1185](https://github.com/pooza/capsicum/issues/1185)）

**「サーバー側の設定に従う。だから新鮮に保つ」を採った**（pooza 判断）。⚠ **これは [#1079](https://github.com/pooza/capsicum/issues/1079)「サーバー側の設定に従うか」への先行回答でもある** —— 候補にあった「直さない（capsicum の既定は capsicum で持つ）」を採ると、現に読んでいる `source.privacy` を**読まなくする＝挙動の削除**になるため、どちらを選んでも #1079 の向きが決まる関係にあった。

実装は `AccountManagerNotifier.refreshCurrentUser()`（フォアグラウンド復帰で `getMyself()` を引き直す）。押さえた点:

- ⚠ **引き直すのは現在アカウント 1 つだけ。**`defaultScope` を読む箇所は 5 つとも `currentAccountProvider`（`compose_screen.dart`）なので、アカウント数ぶんの往復は要らない
- ⚠⚠ **TTL は [`kUserProfileFreshnessTtl`] ＝ 1 分で、`kServerMetadataFreshnessTtl`（1 時間）とは別物。**サーバーのソフトウェア版は月単位でしか動かないが、**既定の公開範囲は利用者がいつでも変えられる**うえ、実害の形が「WebUI で変えて capsicum に戻る」＝復帰の直前に変わるので、1 時間では取りこぼす
- ⚠⚠ **0 にはできない。**デスクトップは**ウィンドウのフォーカスを取り戻すたびに `AppLifecycleState.resumed` が来る**（`inactive` が「前面に無いが可視」の意味・`sky_engine/lib/ui/platform_dispatcher.dart`）ので、TTL を外すと alt-tab のたびに 1 往復する
- ⚠ **TTL は host ではなく `AccountKey` で持つ。**同一 host に複数アカウントがあるとき、片方の取得でもう片方を間引いてはいけない
- ⚠⚠ **`updateCurrentUser` を使ってはいけない。**あれは `state.current` をそのまま書き換えるので、`getMyself()` の await 中にアカウント切替が起きると**切替後の別アカウントへ他人の `user` を書き込む**。key で引き直す（`refreshCurrentServerVersion` と同じ形）。**この壊れ方はテストで固定した**（`account_manager_refresh_user_test.dart`・実際に `updateCurrentUser` へ差し替えて狙ったテストだけが落ちることを確認済み）
- ⚠ **取得に失敗したら既存値を維持する。**一過性の失敗で good な値を捨てると、投稿先が黙って変わる

#### ✅ 残り 3 つも読むようにした（2026-10-01・[#1194](https://github.com/pooza/capsicum/issues/1194)）

> MastodonのWebUIでは、公開範囲のデフォルトを設定するのと同じ画面で、「引用できるユーザー」「言語」に対してもデフォルトも設定できます。これも同様に反映しないと不自然な印象です。（2026-10-01 pooza）

⚠⚠ **上の表の「読まない・送らないほうが結果的に強かった」は、`language` では成立していなかった。**読まずに**端末のロケールを送っていた**ので、WebUI の設定が常に上書きされていた。「送らなければサーバー既定が効く」という逃げが効くのは、**本当に送っていないとき**だけ。

| `source` | 直す前 | 直した後 |
| --- | --- | --- |
| 🔴 `language` | **読まず、端末ロケールを送る**（WebUI の設定が無視される） | **サーバー既定 → 無ければ端末ロケール**。⚠ `setting_default_language` は「サイトの表示言語に合わせる」を選べるので「未設定」が普通に来る（下） |
| `quote_policy` | 読まない・送らない（表示が実態と違う） | 読んでフォームの初期値に。⚠ **知らない値は無視する**（メニューに無い値が選択済みとして残らないように） |
| `sensitive` | 読まない・`false` は送らない | 読んで初期値に + **`false` を明示して送れるようにした**（下） |

##### 「未設定」は null で来るとは限らない（`''` で来る）

⚠⚠ **上の「null が普通に来る」だけでは足りず、空欄で開く不具合を出した**（pooza 報告・`99825675` で修正）。**「サイトの表示言語に合わせる」は `null` ではなく `''` で返る。**

- WebUI の `<select>` は nil の選択肢を `value=""` で出す（`posting_defaults/show.html.haml` の `collection: [nil] + filterable_languages`）
- `UserSettings#[]=` は `''` を `ActiveModel::Type::String` へ type_cast したうえで、**nil でないので保存する**（nil のときだけ `delete` される）
- → `source.language` は `""`。capsicum 側の `serverDefault ?? 端末ロケール` は **`''` を非 null として採用**するので `??` が効かず、**投稿フォームの言語が空欄で開いた**

⚠ **正規化が要るのは `language` だけ。**`user_settings.rb` で `in: %w(...)` の検証を持たず `default: nil` の設定は**これ 1 本だけ**（2026-10-01 にフォークで全数確認）。`privacy` / `quote_policy` は `in:` があるので `''` を保存できない（`ArgumentError`）。

⚠ **畳む向きは Mastodon 自身と同じ。**`valid_locale_cascade(settings['default_language'], locale, I18n.locale)` が利用者のロケールへ倒すので、capsicum で端末ロケールへ倒すのが対応する。

⚠⚠ **教訓: 「未設定」を null でしか検査しなかった。**#1194 の初回で入れた「未設定の言語は null のまま」は、**`''` を素通しする実装でも通る**テストだった。**「未設定」という状態が上流で何通りの表現を持つかを数える**のが先。

##### `sensitive` は「読む」だけでは足りなかった

⚠⚠ **読んで表示するだけでは、トグルが嘘になる。**Mastodon は **`sensitive` を省くとサーバー既定を当てる**（`adapter.dart` が `draft.sensitive ? true : null` で `false` を落としていた）。したがって**既定が true の利用者は、capsicum から閲覧注意を外せない** —— トグルを OFF にしても送られず、サーバーが true を当て直す。

⚠ **常に送る形にはできない。**`source` を返さないサーバーでは、いままで効いていた「サーバー既定に任せる」が壊れる。→ `PostDraft.sensitiveExplicit`（**既定を読めたか、利用者が自分で切り替えたときだけ `false` を明示する**）で分けた。

##### 下書きとの関係

[#1195](https://github.com/pooza/capsicum/issues/1195) で入れた「選んだか / 既定のままか」の集合に `sensitive` も載せた。⚠ **載せないと、自動保存された `sensitive: false` が新しい既定（true）を上書きする**（#1195 と同型の不具合が別のフィールドで再発する）。`language` / `quote_policy` も名前は用意してある。

##### Misskey は対象外

⚠ これらに当たるサーバー側の設定が無い（既定の公開範囲すら API に無く、#1185 で死にコードを消したばかり）。⚠ **Misskey 側で等価を探しに行かない** —— `i/registry` は [#1079](https://github.com/pooza/capsicum/issues/1079) の判断待ちで、そちらに寄せる。

### 5-3. モロヘイヤの `/mulukhiya/api/config` — **拾わない**

**capsicum はこのエンドポイントを一度も呼んでいない**（`GET` / `POST /mulukhiya/api/config` とも 0 ヒット）。中身はハンドラーの有効 / 無効（`config.handler.*.disable`）。

**結論: 拾わない。**理由は **capsicum がハンドラーの出力を予測して見せる UI を持たないから**:

- タグ付けはモロヘイヤが**投稿時にサーバー側で**行う（透過プロキシ）。結果は投稿そのものに現れるので、capsicum が設定を読んでも出し分けるものが無い
- `POST /mulukhiya/api/status/tags` は**プレビューではなく「削除してタグづけ」**（消して付け直す実行 API）。予測ではない

⚠ **条件付きの結論。**「この投稿にはこのタグが付きます」という**プレビューを作るなら、そのときは母数に入る**（ハンドラーが無効なら予測が外れるため）。

### 5-4. 起票（2026-09-29）

- 🔴 **5-2 `source.privacy` が腐る** → [#1185](https://github.com/pooza/capsicum/issues/1185)
- ⚠ **5-1 の死にコード（`defaultNoteVisibility`）** → 同 [#1185](https://github.com/pooza/capsicum/issues/1185) に同梱（どちらも `defaultScope` の出どころの話）
- 5-1 の「registry に従うか」は **[#1079](https://github.com/pooza/capsicum/issues/1079) と同じ判断**として、あちらへ寄せる（Misskey 側の材料を #1079 にコメント済み）

## 6. 起票

- **分類 A（§3-1）→ [#1076](https://github.com/pooza/capsicum/issues/1076)・[v1.63](https://github.com/pooza/capsicum/milestone/77)**。「隠すべきものを隠す」は 1.x で片付ける（pooza 判断）。行き先は #991 分類 A と同じ扱い（棚卸しの成果枠）
- **§3-2（preferences の 3 設定）→ [#1079](https://github.com/pooza/capsicum/issues/1079)・[v2.0](https://github.com/pooza/capsicum/milestone/65)**。⚠ **サーバー設定と端末設定のどちらを優先するかの設計判断が先**で、それを決めずに実装の Issue は書けない。そこで **2026-09-04 に「判断そのものを完了条件とする Issue」として起票した**（[#1049](https://github.com/pooza/capsicum/issues/1049) トレンドと同じ「やる / やらないの決着でよい」型）。⚠ **分類 C 行きもありうる**

⚠ **この棚卸しの母数から「拾わない」と決めたものは §4 に理由付きで残してある。**次の棚卸しで再浮上させないこと。

**棚卸し 3 本はこれで完了。**次は v2.x のロードマップ（枠の数・各枠の主題・1.x との境界）を決める段階へ進む。
