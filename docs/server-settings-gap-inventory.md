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

### ⚠ ここが唯一の地雷（すでに踏んでいない）

Mastodon の `post_status_service.rb:73` は

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

## 4. 分類 C — 拾わない

| 項目 | 理由 |
| --- | --- |
| Misskey `alwaysMarkNsfw` / `autoSensitive` / `notificationRecieveConfig`、Mastodon `notifications/policy` | **サーバー側で効いている。**クライアントが読んでも二重判定になるだけ |
| Misskey `i/registry/*` | WebUI のクライアント設定ストア。**capsicum には capsicum の設定がある**（#857 の設定バックアップが端末間移行を担当）。#993 の分類 C と同じ判断 |
| Misskey `roles/*`（ロールによる機能可否） | ⚠ **#993 §6 から回ってきたが、ここでも拾わない。**ロールは**サーバーが強制する**ので、capsicum が先読みして UI を出し分ける必要はない。出し分けないと「押せるが失敗する」になるが、それは**エラー処理の話**であって設定の反映漏れではない |
| テーマ・フォント・カスタム CSS・サウンド・ウィジェット配置（両 SNS） | **#992 の優先順 3 で最初に切り離すと決めてあるもの。**サーバー側に保存されていても capsicum が従う筋合いはない |
| Mastodon `indexable` / `discoverable` / `noindex` | 検索エンジン・ディレクトリへの掲載可否で、**サーバーとサーバー間の話**。⚠ `discoverable` は**既に対応済み**（プロフィール編集のトグル・[#865](https://github.com/pooza/capsicum/issues/865)） |
| Mastodon `attribution_domains` | 記事の著者表示に使うサーバー側の検証情報。クライアントの表示に効かない |

## 5. 未実施・次回の宿題（2026-09-04 に [#1078](https://github.com/pooza/capsicum/issues/1078) へ切り出し済み）

⚠ **3 点とも「無かった」ではなく「見ていない」で終わっている。**#992 を close するにあたり、まとめて **[#1078](https://github.com/pooza/capsicum/issues/1078)（v2.0）** へ切り出した。

- **Misskey の `i/registry` の中身を実データで見ていない。**分類 C としたのは「WebUI のクライアント設定ストアだから」という**性質による判定**で、⚠ **中に投稿の挙動を決める値が紛れていないかは未確認**。ダイスキーの実アカウントで `i/registry/keys` を引けば確定する
- **Mastodon の `source` は `verify_credentials` 経由でしか見ていない。**⚠ 起動時に 1 回読むきりなら、**WebUI で設定を変えても capsicum を再起動するまで古い値のまま**という経路がありうる。反映のタイミングは未確認。⚠ これは「読んでいない」ではなく「**読んだ値が腐る**」型なので、§1 の母数の取り方では原理的に出てこない
- **フォーク固有の設定は両 SNS とも見つからなかった**が、⚠ **モロヘイヤ側のユーザー設定（`GET/POST /mulukhiya/api/config`）は今回の母数に入れていない**。#992 の基準が「Mastodon / Misskey のサーバー側設定」だったため。**モロヘイヤの設定反映は別軸**として扱う

## 6. 起票

- **分類 A（§3-1）→ [#1076](https://github.com/pooza/capsicum/issues/1076)・[v1.63](https://github.com/pooza/capsicum/milestone/77)**。「隠すべきものを隠す」は 1.x で片付ける（pooza 判断）。行き先は #991 分類 A と同じ扱い（棚卸しの成果枠）
- **§3-2（preferences の 3 設定）→ [#1079](https://github.com/pooza/capsicum/issues/1079)・[v2.0](https://github.com/pooza/capsicum/milestone/65)**。⚠ **サーバー設定と端末設定のどちらを優先するかの設計判断が先**で、それを決めずに実装の Issue は書けない。そこで **2026-09-04 に「判断そのものを完了条件とする Issue」として起票した**（[#1049](https://github.com/pooza/capsicum/issues/1049) トレンドと同じ「やる / やらないの決着でよい」型）。⚠ **分類 C 行きもありうる**

⚠ **この棚卸しの母数から「拾わない」と決めたものは §4 に理由付きで残してある。**次の棚卸しで再浮上させないこと。

**棚卸し 3 本はこれで完了。**次は v2.x のロードマップ（枠の数・各枠の主題・1.x との境界）を決める段階へ進む。
