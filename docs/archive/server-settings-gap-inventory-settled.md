# 棚卸し: サーバー側設定の反映漏れ — 決着した節の記録

> **アーカイブ（現役運用では参照しない）。**[server-settings-gap-inventory.md](../server-settings-gap-inventory.md) の §5（宿題 3 点の確定）と §6（起票）の本文を、2026-10-11 に移した。[#1078](https://github.com/pooza/capsicum/issues/1078) / [#1185](https://github.com/pooza/capsicum/issues/1185) / [#1194](https://github.com/pooza/capsicum/issues/1194) はどれも閉じている。**結論と、いまも守る点は本体側に残してある。**節番号は本体と同じ。

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
