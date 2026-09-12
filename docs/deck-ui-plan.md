# デッキ表示 設計スパイク（#720）

[#720](https://github.com/pooza/capsicum/issues/720)（アカウントに依存せず複数カラムを並べて表示する）を「着手可否を判断できる状態」へ動かすための **feasibility spike**。

- 作成日: **2026-09-06**（同日中に未決事項 1 / 7 / 8 まで決着。⚠ **フェーズ 1 の Issue 分解を止める未知は残っていない**）
- **2026-09-12 追記**: 未決事項 **2（カラムの購読モデル）を決着**（[#1086](https://github.com/pooza/capsicum/issues/1086)）。⚠ **決定の要は「接続方式を今決めない」**——`StreamSupport` をキー付きにすると、1 ソケット多重化かカラムごとソケットかは実装の内部事情に落ちる
- ⚠ **これは詳細 UI 仕様ではない。**Issue の[方針コメント（2026-07-16）](https://github.com/pooza/capsicum/issues/720)が定めたとおり、狙いは 3 点（現アーキの前提棚卸し / デッキが壊す境界 / 段階性と規模の見立て）に絞る。中身が流動的な段階で画面仕様を書くと陳腐化する
- 位置づけの正本は [roadmap.md](roadmap.md)「未決事項 1」、型の正本は [CLAUDE.md「大玉の進め方」](CLAUDE.md#大玉の進め方棚卸し--分類--設計書--起票)
- 実測はすべて `develop` の `565cce06`（1.64.0+180）時点

## 結論

**加算的に載る。土台の一気差し替えは要らない。ただしメジャー相当という判定は維持する。**

| 問い | 答え |
| --- | --- |
| 現構造の上に**加算的に**載せられるか | **載せられる。**カラム＝独立した購読ユニットという見方は現構造と整合する。既存のタブ構造を捨てる必要はない |
| 土台の一気差し替えか | **違う。**既存タブ UI と共存する漸進導入ができる（段階性の節） |
| メジャーか大更新か | ⚠ **メジャーのまま。**降格しない。理由は「壊れる境界」の B-1（1 アカウント 1 ソケット）と B-2（アカウント singleton が 87 ファイルに拡散）の 2 つで、**どちらも UI の外側にある** |
| v1.x へ降格できるか | **できない。**上記 2 件はどちらも点リリースの粒度に収まらない |

⚠ **いちばん重要な発見: 難所は UI ではなく「アカウントの解決」と「streaming の単数保持」にある。**「複数カラムを並べる」というレイアウトの話は、実は最も安い部分だった。

⚠⚠ **不可避のコストは B-1（1 アカウント 1 ソケット・後勝ち）のほう。**アカウントを 1 つに固定した「安い版」でも、**2 カラム目を購読した瞬間に 1 本目のライブが無音で止まる**ので逃げられない。一方 B-2（アカウントの解決）は、**Riverpod のスコープ上書きで UI 62 ファイルが無改修になる**（1-7・**2026-09-06 に実測で確認済み**・未決事項 7）。

→ ⚠ **「シングルアカウントに妥協して規模を落とす」は割に合わない。**最も重い B-1 は残り、**しかも #720 の要望（SubwayTooter 風＝カラムごとに別アカウント）には答えられない**（2026-09-06 pooza）。

### ⚠⚠ 決定（2026-09-06 pooza）

> 割に合わない選択肢をえらぶ合理性はない。ここは決定ですね。

**#720 は「カラムごとにアカウントが違えられる」マルチアカウント版で作る。**シングルアカウント版は代案として検討しない。

- **フェーズ 1 単独でのリリースは可**（下ごしらえとして意味がある）。⚠ **ただしそれで #720 を close しない**
- ⚠ **この決定を「規模が入りきらない」を理由に再判定しない。**逃がす順序は [roadmap.md](roadmap.md)「決定済み事項 3」が正本で、**#720 は逃がさない対象**

---

## 決定済み事項

### 1. 現アーキの前提棚卸し

#### 1-1. 「現在のアカウント」は singleton だが、**アダプタは既にアカウント別に生きている**

`Account` は自分の `adapter` / `mulukhiya` を持ち（[`model/account.dart`](../packages/capsicum/lib/src/model/account.dart)）、`AccountManagerState.accounts` にログイン済み全アカウントが**それぞれ生きたアダプタを持ったまま並んでいる**。singleton なのは `current` という**選択**だけで、他アカウントが眠っているわけではない。

```dart
// account_manager_provider.dart:1326
final currentAdapterProvider = Provider<DecentralizedBackendAdapter?>((ref) {
  return ref.watch(currentAccountProvider)?.adapter;
});
```

⚠ **これは大きな追い風。**「デッキのためにアカウントごとのセッションを保持する層」を新設する必要が無い。既にある。

一方で、この 3 つの便利 provider（`currentAccountProvider` / `currentAdapterProvider` / `currentMulukhiyaProvider`）の参照は広い:

| | 実測 |
| --- | --- |
| 参照箇所 | **423 箇所** |
| 参照ファイル | **87 ファイル** |
| 最多 | `compose_screen.dart` 48 / `post_tile.dart` 27 / `profile_screen.dart` 25 |

（アプリ全体は 65 画面・187,019 行）

#### 1-2. 「選択中のタブ」は singleton だが、**参照は 5 ファイルに集中している**

```dart
// timeline_provider.dart:18
final selectedTabProvider = StateProvider<TabType>(
  (ref) => const TimelineTab(TimelineType.home),
);
```

| | 実測 |
| --- | --- |
| `selectedTabProvider` の参照 | **29 箇所 / 5 ファイル** |
| 内訳 | `home_screen.dart` 19 / `home_menu.dart` 3 / `timeline_provider.dart` 3 / `tab_selection_provider.dart` 3 / `visible_timeline.dart` 1 |

⚠⚠ **1-1 と 1-2 の非対称がこの spike の中心的な発見。**「選択中のタブ」＝ 5 ファイル、「現在のアカウント」＝ 87 ファイル。**デッキのコストは前者ではなく後者に乗っている。**

層別の内訳（後述 1-7 で効く）:

| 層 | ファイル数 |
| --- | --- |
| **UI（screen + widget）** | **62** |
| provider | 22 |
| service / util / main | 3 |

⚠ **「単一アカウントのマルチカラム」と「マルチアカウントのマルチカラム」は規模が違う。**#720 の題は後者（「アカウントに依存せず」）なので逃げられない。⚠ **ただし差が「1 桁」かどうかは、この 62 ファイルを手で書き換えるかどうかで決まる**（1-7）。

#### 1-3. TL provider は 4 系統あり、family キーの持ち方が揃っていない

| provider | 定義 | family キー | streaming |
| --- | --- | --- | --- |
| `timelineProvider` | [timeline_provider.dart:1942](../packages/capsicum/lib/src/provider/timeline_provider.dart) | ⚠ **family 無し（グローバル singleton）** | **有** |
| `hashtagTimelineProvider` | [hashtag_provider.dart:126](../packages/capsicum/lib/src/provider/hashtag_provider.dart) | `String`（タグ spec のみ） | 無 |
| `listTimelineProvider` | [list_provider.dart:98](../packages/capsicum/lib/src/provider/list_provider.dart) | `String`（list id のみ） | 無 |
| `channelTimelineProvider` | [channel_provider.dart:88](../packages/capsicum/lib/src/provider/channel_provider.dart) | `String`（channel id のみ） | 無 |

⚠ **3 つの family はどれもキーに「どのアカウントか」を含んでいない。**現状これで正しいのは、**同時に生きているアカウントが 1 つしかないから**。provider は `autoDispose` で、アカウント切替＝ build 再実行で作り直される。

⚠ **`TimelineType` を扱う本線 TL だけが family を持っていない**のは、「タブは 1 つしか選ばれない」前提の裏返し。カラム化の第一歩はここを family 化することになる。

⚠ **カラムの同一性は `(AccountKey, TabType)` で表せる。**[`TabType`](../packages/capsicum_core/lib/src/model/tab_type.dart) は既に sealed class + `toKey()` / `fromKey()` の可逆シリアライズを持ち、**アカウントに依存していない**。`AccountKey.toStorageKey()`（`misskey://user@host` 形式）と連結すれば、そのままカラム ID・永続化キー・provider の family キーに使える。**新しい概念を発明せずに済む。**

#### 1-4. ⚠⚠ streaming は「1 アカウント 1 ソケット・後勝ち」

**これが最大の技術的ブロッカー。**

```dart
// misskey/adapter.dart:1863（mastodon/adapter.dart:1399 も同型）
Stream<Post> streamTimeline(TimelineType type, {...}) {
  _streaming?.dispose();          // ⚠ 前の購読を殺す
  ...
  _streaming = MisskeyStreaming(...);
  return _streaming!.connect(type).map(_applyWordFilter);
}
```

アダプタは `MisskeyStreaming? _streaming` を**単数フィールド**で持つ（misskey:131 / mastodon:124）。`MisskeyStreaming` 側も `_channel` / `_currentType` / `_subscriptionId` を単数で持ち、`connect()` が前の `StreamController` を閉じる。

→ **同じアカウントで 2 本目の TL を購読すると 1 本目が黙って止まる。**デッキは「同一アカウントで home と local を並べる」が基本形なので、**現状のままでは 1 カラムしかライブにならない**。

⚠ **プロトコル側の制約ではない。**Misskey の `/streaming` は `connect` メッセージに `id` を付けて 1 ソケットで複数チャンネルを多重化できる設計で、実装が `_subscriptionId` を 1 つしか持っていないだけ。Mastodon 側は現状 `?stream=<name>` を URL に載せる形（streaming.dart:104）なのでソケットを分けるか、`subscribe` メッセージ方式へ移す必要がある。

⚠ **ハッシュタグ / リスト / チャンネルの各 TL は、そもそも streaming を張っていない**（[hashtag_provider.dart:31](../packages/capsicum/lib/src/provider/hashtag_provider.dart) のコメントに明記）。**デッキの主役はまさにこの 3 種**（タグ TL を何本も並べるのが実況用途）なので、⚠ **「並べたのに動かない」を避けるならライブ購読の新規実装が要る**。現状は「タブを切り替えたら再取得」で成立していた。

#### 1-5. 起動時キャッシュは 1 スロットしかない

[`TimelineCache`](../packages/capsicum/lib/src/service/timeline_cache.dart) は**単一ファイル**に `contextKey` 付きで 1 本ぶんの生 JSON を保存し、`load(contextKey)` はキーが違えば捨てる。デッキで N カラムを先出しするなら N スロット要る。

⚠ **ただし「先出しを 1 カラムに限る」で回避できる。**#890 の狙いは起動体感なので、**フォーカスされたカラムだけ先出しする**なら現構造のまま通る。

#### 1-6. ⚠ 先例がある — `unifiedNotificationProvider` は既に全アカウント fan-out している

```dart
// unified_notification_provider.dart:56
final accounts = ref.watch(accountManagerProvider).accounts;
final supported = accounts.where((a) => a.adapter is NotificationSupport)...
for (final account in supported) {
  ... await (account.adapter as NotificationSupport)...   // ⚠ current* を使わない
}
```

**「全アカウントを watch し、`account.adapter` を直に使い、結果を逐次マージする」形が既に出荷済みで動いている**（#862 で逐次描画化まで済み）。

⚠⚠ **デッキはこのパターンの一般化であって、新しい設計ではない。**これは feasibility の判断材料として重い — **同じ構造がこのコードベースで既に 1 回成立している**。

#### 1-7. ⚠⚠ B-2 の 62 ファイルは、書き換えずに済む可能性がある（Riverpod のスコープ上書き）

**「87 ファイル」という数字を額面どおり受け取ると、マルチアカウント版のコストを過大に見積もる。**

現状の実測:

- `flutter_riverpod: ^2.6.1`
- `ProviderScope` は [main.dart:478](../packages/capsicum/lib/main.dart) の**ルート 1 つだけ**。ネストしたスコープは存在しない
- `dependencies: [...]` を宣言している provider は**ゼロ**

→ **スコープ機構を 1 度も使っていない。**つまり「使えないと分かっている」のではなく、**まだ試していない**。

**仮説**: カラムを `ProviderScope(overrides: [currentAccountProvider.overrideWithValue(columnAccount)])` で包み、`currentAdapterProvider` / `currentMulukhiyaProvider` に `dependencies: [currentAccountProvider]` を宣言する。すると:

| 層 | 必要な変更 |
| --- | --- |
| **UI 62 ファイル** | ⚠ **ゼロ。**`ref.read(currentAdapterProvider)` のまま、**そのカラムのアカウントのアダプタが返る** |
| provider 22 ファイル | `dependencies:` の宣言（1 ファイルにつき数行） |
| カラム側 | スコープで包む 1 箇所 |

⚠⚠ **これが成り立つなら、B-2 の性質が「87 ファイルの書き換え」から「22 の宣言 + 1 つの規約」へ変わる。**マルチアカウント版とシングルアカウント版のコスト差が大きく縮む。

⚠ **ただし、これは未検証の仮説。**プロトタイプで確かめる必要がある（未決事項 7）。特に:

- **Riverpod 2.x の scoped provider は `dependencies:` の宣言漏れが silent failure になる。**宣言し忘れた provider は**ルートスコープの値を読む** = **黙って「現在のアカウント」として動く**。⚠⚠ **これは #1061 / #1063 / #1035-C 群と同じ「壊れていても緑」の形**で、このプロジェクトが直近 3 リリース連続で踏んでいる型そのもの
- `autoDispose` + ネストスコープ + `AsyncNotifierProvider` の組み合わせは 2.x で挙動が細かい
- ⚠ **provider でない global（`TimelineCache` の static / アダプタが抱える `_streaming` / `_isCatCache`）はスコープに参加しない。**B-1 はこの手段では 1mm も解決しない

⚠ **silent failure は機械で止められる。**「`provider/` 配下で `current*Provider` を参照するファイルは、対応する `dependencies:` を宣言していること」を走査するテストで足りる。**このプロジェクトには既に同型の検査が 11 本ある**（`reaction_acceptance_coverage_test.dart` / `bottom_inset_guard_test.dart` / `phase_tag_literal_guard_test.dart` ほか）。⚠ **人手の「全部見たつもり」に頼らない形が既に idiom になっている**ので、新しい規律を持ち込むわけではない。

---

### 2. デッキが壊す境界

現構造のどこが破綻するか。severity 順。

| | 境界 | 何が起きるか | 重さ |
| --- | --- | --- | --- |
| **B-1** | **1 アカウント 1 ソケット**（1-4） | 2 本目のカラムを購読した瞬間に 1 本目のライブが止まる。**しかも無音**（例外にならない） | 🔴 大 |
| **B-2** | **`current*` を読む 87 ファイル**（1-1） | **アカウント B のカラムに出ている投稿を、アカウント A としてお気に入り / ブースト / 返信してしまう。**`post_tile.dart` だけで 12 のアクション地点が `ref.read(currentAdapterProvider)` を読んでいる。⚠ **スコープ上書きが効けば UI 62 ファイルは無改修になりうる**（1-7）。その場合コストは 🟠 中へ下がるが、**silent failure の検査が必須条件**になる | 🔴 大（1-7 次第で中） |
| **B-3** | **`readVisibleTimelines`**（[visible_timeline.dart:159](../packages/capsicum/lib/src/ui/util/visible_timeline.dart)） | 「表示中の TL」を `selectedTabProvider` **単数**から解決している。デッキでは可視 TL が N 本になり、#887 の保証（**ブロック / ミュートした相手が見えているどの TL からも消える**）が N-1 本で破れる | 🟠 中 |
| **B-4** | **family キーにアカウントが無い**（1-3） | 2 アカウントで**同じタグ**のカラムを並べると、同一 provider インスタンスを共有して**片方のサーバーの投稿がもう片方に混ざる** | 🟠 中 |
| **B-5** | **タグ / リスト / チャンネルに streaming が無い**（1-4） | デッキの主用途で「並べたけど更新されない」 | 🟠 中 |
| **B-6** | **起動キャッシュ 1 スロット**（1-5） | N カラムの先出し不可 | 🟢 小（回避可） |
| **B-7** | **`TimelineCache.clear()` が全体を消す** | `removePostsByUser` がブロック時にキャッシュを丸ごと捨てる。カラム別スロットにすると「どれを捨てるか」の判断が要る | 🟢 小 |

⚠⚠ **B-2 がいちばん危ない。**B-1 は「動かない」なのでユーザーが気づくが、**B-2 は「間違ったアカウントとして成功する」**。しかも [feedback: 隠すべきものを隠していないのは実害] の第 3 の型（見せたくないものが見えている）に隣接する — 別アカウントの identity で操作が外部に出る。

⚠ **B-2 は機械で止められる形をしている。**#1044 の `effectiveReaction()` と同じく、**アダプタの解決を 1 箇所に寄せて `current*` の直読みをテストで禁止する**（`reaction_acceptance_coverage_test.dart` と同型の走査テスト）。87 ファイルを人手で「全部見たつもり」になるのは、v1.63 で 2 回失敗した形そのもの。

⚠⚠ **ただし B-2 は「解くべき問題」であって「必ず 87 ファイルを触る問題」ではない。**1-7 のスコープ上書きが成り立てば、UI 62 ファイルは無改修のまま**正しいアカウントで動く**。**どちらの手段でも、silent failure を機械で止める検査は必須**（手段によって検査の対象が変わるだけ）。

⚠⚠ **B-1 と B-2 は独立していない。**B-2 をスコープで解いても **B-1 はアダプタが抱える単数フィールドの話なので何も動かない**。⚠ **したがって「安い版」を選んでも B-1 は逃げられない** — シングルアカウントでも 2 カラム目で 1 本目のライブが止まるため。**B-1 はどの案でも不可避の共通コスト。**

⚠ **B-3 は「デッキにおける『表示中』とは何か」という設計判断を含む**ので、機械的な置き換えでは済まない（未決事項 3）。

---

### 3. 段階性と規模の見立て

**3 段階。境界は 1-2 の非対称（タブ singleton 5 ファイル vs アカウント singleton 87 ファイル）に沿って引く。**

#### フェーズ 1: 単一アカウントのマルチカラム（土台）

- `timelineProvider` を `(AccountKey, TabType)` の family へ（1-3）
- 既存 3 family のキーに `AccountKey` を足す（B-4）
- カラム列の状態・永続化（`TabType.toKey()` + `AccountKey.toStorageKey()` の連結で済む）
- 横スクロールのカラムコンテナ。**既存のタブ UI は残したまま、狭幅では従来どおり 1 カラム**
- ⚠ **ナビゲーションを横軸から降ろす**（デッキ表示時は常駐ドロワーを出さない）— **成立条件であって付随変更ではない**。根拠は未決事項 8 の表（900px でカラムが 2→1 に落ちる）
- B-1 の解消（streaming の多重化）— ⚠ **ここが実装の山**

⚠ **この段階で `current*` には触らない。**アカウントは 1 つのままなので B-2 は発生しない。**フェーズ 1 だけで「タグ TL を 3 本並べる」という実況用途の大半が成立する。**

⚠⚠ **ただしフェーズ 1 は #720 の答えにならない**（2026-09-06 pooza）。**「SubwayTooter のような」と言った要望者が求めているのは、カラムごとにアカウントが違えること**であって、カラムが複数あることではない。SubwayTooter はカラムとアカウントの紐付けが設計の核にある。

→ **フェーズ 1 は「安い代案」ではなく「フェーズ 2 の下ごしらえ」。**単独でリリースしてもよいが、**それで #720 を close してはいけない。**⚠ **要望者の期待とズレたまま「対応済み」にすると、[feedback: 打ち切り済みユーザー報告] とは逆の、「応えたつもりで応えていない」形になる。**

#### フェーズ 2: カラムごとのアカウント束縛（＝ #720 が本当に求めているもの）

- カラムが `AccountKey` を持ち、その配下の描画・アクションが**そのアカウントのアダプタ**を使う
- B-2 の解消。⚠ **2026-09-06 の実測で案 S に決定**（未決事項 7）:
  - **案 S（スコープ）** ← **採用**: カラムを `ProviderScope` で包み `currentAccountProvider` を上書き（1-7）。**UI 62 ファイル無改修**、provider 22 に `dependencies:` を宣言、保険として走査テスト
  - ~~案 F（明示）~~: `current*` の直読みをカラム文脈から解決する入口へ寄せ、呼び出し側を書き換える案。**案 S が成立したので採らない**
- `unifiedNotificationProvider`（1-6）のパターンを一般化する

⚠ **当初は「案 S は安いが silent failure、案 F は高いが compile error」というトレードオフだと見ていたが、実測でこの前提が崩れた。**Riverpod 2.6.1 は宣言漏れを **debug で AssertionError にする**（直し方つき）。**安いほうが同時に安全**だったので、選択の余地が無くなった。⚠ **release では assert が消える**ので走査テストは残すが、**成立条件ではなく保険**。

#### フェーズ 3: 仕上げ

- B-5（タグ / リスト / チャンネルの live 購読）
- B-3 の再定義（#887 の保証をデッキで何にするか）
- B-6 / B-7、デッキ構成のバックアップ同梱

#### 規模

⚠ **Issue 数の見積もりは出せる段階ではないが、下限は言える。**フェーズ 1 だけで「provider の family 化 + streaming の多重化 + カラムコンテナ + 永続化」の 4 本に割れ、streaming の多重化は Mastodon / Misskey で別実装になるため単独で 1 枠ぶんある。**フェーズ 1〜3 で最低 12〜15 Issue、フェーズ 2 の手段（案 S / 案 F）次第で増える。**

⚠⚠ **重心はフェーズ 1 にある。**当初は「マルチアカウント対応（フェーズ 2）が本体で、フェーズ 1 は下ごしらえ」と見ていたが、1-7 の見立てが正しければ逆になる。**不可避なのは B-1（streaming の多重化・どの案でも逃げられない）で、B-2 は手段次第で大きく縮む。**

⚠ **したがって「安い版（シングルアカウント）で妥協して規模を落とす」という選択は、実は割に合わない。**削れるのはフェーズ 2 のぶんだけで、**最も重い B-1 は残る**うえに、**#720 の要望には答えられない**。

⚠ **[roadmap.md](roadmap.md)「決定済み事項 3」の閾値（大玉の分解後に v2.0 全体が v1.0 の 46 件を超えるなら分割）に対して、#720 単独で 15 件前後を占める見込み。**#597 の設計書が出た時点で合算して判断する。

⚠ **メジャー判定は維持する。**B-1 / B-2 はどちらも UI ではなくデータ経路の話で、点リリースの粒度に収まらない。

---

### 4. カラムキーの形（2026-09-12 決定・[#1087](https://github.com/pooza/capsicum/issues/1087) / [#1088](https://github.com/pooza/capsicum/issues/1088) / [#1091](https://github.com/pooza/capsicum/issues/1091) の共通前提）

1-3 で「カラムの同一性は `(AccountKey, TabType)` で表せる」と書いたが、**実装に落とすと 1 つ罠がある。**

#### 4-1. ⚠⚠ `TabType.toKey()` は永続化キーに使えない（`==` と一致しない）

```dart
// tab_type.dart
class ListTab extends TabType {
  @override
  String toKey() => name != null ? 'list:$id:$name' : 'list:$id';   // ⚠ 表示名が入る

  @override
  bool operator ==(Object other) => other is ListTab && id == other.id;  // ⚠ id だけ
  @override
  int get hashCode => id.hashCode;
}
```

**`toKey()` は表示名を含むのに、`==` / `hashCode` は id しか見ていない。**`ChannelTab` も同型。

→ ⚠⚠ **サーバー側でリスト名を変えると、同じカラムなのにキーだけ別物になる。**カラム ID・キャッシュのスロット名・永続化キーに `toKey()` の文字列をそのまま使うと、**リネームした瞬間にカラムの並び順・設定・キャッシュが「別のカラムのもの」になって消える。**

⚠ **今これが表面化していないのは、既存の永続化が必ず `TabType.fromKey()` で値に戻してから `==` で比較しているから**（`preferences_provider.dart:484-493` のタブ表示設定）。**文字列そのものを同一性として使っている箇所が現状 1 つも無い。**デッキはそれを始める最初の機能になる。

#### 4-2. 決定

| 用途 | 何を使うか |
| --- | --- |
| **provider の family キー** | **値のまま**（`(AccountKey, TabType)` の record）。⚠ `TabType.==` は id ベースなので**これが正しい** |
| **永続化・キャッシュのスロット名・カラム ID** | ⚠ **正規化した文字列**（`list:<id>` / `channel:<id>` — **表示名を落とす**）。`TabType` に `toIdentityKey()` を足し、**`toKey()` は既存の用途のまま触らない**（後方互換） |
| **カラムのラベル** | 実行時に解決する。⚠ **キーに混ぜない** |

#### 4-3. ⚠ 既に同じ形の文字列がある — `timelineContextKey`

```dart
// timeline_provider.dart:50
String? timelineContextKey(AccountKey? accountKey, String kind) =>
    accountKey == null ? null : '${accountKey.toStorageKey()}|$kind';
```

**`<アカウント>|<種別>` は、まさにカラムキーの形をしている**（#758 で TL の文脈照合のために入ったもの）。⚠ **`kind` の語彙だけが `TabType.toKey()` と揃っていない**（`tl:home` 対 `timeline:home`、`tag:` 対 `hashtag:`）。**カラムキーはこの関数の `kind` に `toIdentityKey()` を渡す形に寄せる**と、family キー・キャッシュのスロット・#1086 の streaming キーが 1 本の式に揃う。

⚠ **寄せると起動キャッシュのキーが 1 回変わる**（`tl:home` → `timeline:home`）。**実害は「初回だけ先出しが効かない」**だけ（#890 のキャッシュは load 時にキー不一致なら捨てる）。

---

### 5. カラムの生死と購読の生死を分ける（2026-09-12 決定・[#1087](https://github.com/pooza/capsicum/issues/1087)）

未決事項 2-B（**可視カラムのみ live・ただし状態は保持**）を実装に落とすと、**「provider を生かしたまま、購読だけ切る」**が要る。現状はこの 2 つが分かれていない。

#### 5-1. ⚠ 購読の開始は build() の副作用になっている

```dart
// timeline_provider.dart:816-818（build の末尾）
if (adapter is StreamSupport && ref.read(streamingEnabledProvider)) {
  _startStreaming(adapter as StreamSupport, type);
}
```

外から止められるのは `streamingEnabledProvider`（**全 ON / 全 OFF の 1 個だけ**）。⚠ **カラム単位の live / not-live という概念が無い。**

#### 5-2. ⚠⚠ 可視性を `ref.watch` で見てはいけない（#904 の再発）

同じ罠を 1 度踏んでおり、**理由がコードのコメントに残っている**:

> 初期判定は read で行う。watch すると、トグル切替が build() 全体（REST 再フェッチ・スクロール位置リセット・`_pendingPosts.clear` 等）を誘発し、可視のスクロールジャンプを起こす (#904)。切替の張り/解除は build() 側の listen。
> — `timeline_provider.dart:811-815`

→ ⚠⚠ **カラムの可視性を `build()` で watch すると、横スクロールのたびに全カラムが REST から取り直され、スクロール位置が飛ぶ。**

**決定: 可視性は `streamingEnabledProvider` と同じ経路に乗せる**（`timeline_provider.dart:674-689` の `ref.listen`）。**張り / 解除だけを listen で行い、build は 1 度も再実行しない。**

```dart
// build() 側（既存の listen の隣に置く）
ref.listen(columnLiveProvider(key), (_, live) {
  live ? _startStreaming(streamAdapter, type) : _stopStreaming(streamAdapter);
});
```

⚠ **猶予（2-B の「画面外に出た瞬間に切らない」）も `columnLiveProvider` の側に置く。**notifier に猶予を持たせると、**同じ遅延が 2 か所（可視判定とカラム）に散る**。

#### 5-3. `autoDispose` は変えない（#1087 の注意書きどおり）

**カラムを生かす責務はデッキコンテナ側に置く** — 列に存在するカラムのウィジェットが watch を保つ限り、`autoDispose` は発火しない。⚠ **横スクロールのコンテナは既定で画面外の子を捨てる**ので、**カラムは明示的に生かす**（#1092 の要件）。

→ **「列から削除する = provider も破棄される」**が自然な対応になり、破棄の条件を別に発明しなくて済む。

---

### 6. カラム列の編集は「タブ管理」の一般化（2026-09-12 決定・[#1093](https://github.com/pooza/capsicum/issues/1093)）

#### 6-1. 先例がそのままある

| | 現行（タブ） | デッキ（カラム） |
| --- | --- | --- |
| モデル | `TabConfigEntry(tab, visible)` の **順序つきリスト** | `(AccountKey, TabType)` の順序つきリスト |
| 永続化 | `List<String>`（`preferences_provider.dart:484-493`。非表示は `!` 接頭辞） | 同型（キーは 4-2 の `toIdentityKey()`） |
| 編集 UI | `tab_management_sheet.dart` の **`ReorderableListView`**（並べ替え + 表示/非表示） | 同型（+ 追加 / 削除） |

⚠ **新しい UI パターンを持ち込まない。**「並べ替えできるリスト」は既にこのアプリの idiom。

#### 6-2. ⚠⚠ 決定的な差: カラムは**重複できる**

**タブは `TabType` の集合**で、`==` が id ベースなので同じタブを 2 枚持てない。**カラム列は同じ `(AccountKey, TabType)` を 2 本置けてよい**（参考実装もそう）。

→ **「列の要素」と「provider の同一性」を分ける**:

| | 何で識別するか |
| --- | --- |
| **列の要素（並べ替え・削除の対象・Widget の key）** | ⚠ **列内の安定 ID**（追加時に採番）。⚠ **index を使わない**（並べ替えで意味が変わる） |
| **provider の family キー（中身）** | `(AccountKey, TabType)`。⚠ **重複カラムは同じインスタンスを共有する** — 購読も 1 本で済み、メモリも 1 本 |

#### 6-3. ⚠⚠ 削除時に `disconnect` を明示的に呼んではいけない

重複カラムが provider を共有する以上、**「1 本消したら購読も落とす」は間違い**（もう 1 本が無音で止まる。B-1 と同じ壊れ方）。

**正しくは何もしない。**列から消える → watch が減る → **最後の 1 本が消えたときだけ `autoDispose` が発火**し、既存の `ref.onDispose`（`timeline_provider.dart:666-672`）が `disposeStream(key)` を呼ぶ。⚠ **参照カウントを自前で持たない。**

⚠ **#1093 の本文にあった「削除時にそのカラムの購読を確実に落とす（#1089 / #1090 の個別 `disconnect` を使う）」は、この決定で誤りになったので訂正した。**

---

### 7. デッキ時のナビゲーションと AppBar（2026-09-12 決定・[#1094](https://github.com/pooza/capsicum/issues/1094)）

#### 7-1. 常駐ドロワーはデッキ時だけ出さない（採用）

#1094 が挙げていた 2 案のうち、**「常駐ドロワーをデッキ時だけオーバーレイへ戻す」**を採る。判定は `home_screen.dart:574` の 1 行（`width >= 900`）にデッキ判定を足すだけで閉じる。

⚠ **もう一方の「カラム選択を上下のストリップへ移す」は今はやらない。**1 カラムまで狭まったときの行き来は **#1092 の snap ページャで足りる可能性がある**ので、**実機で測ってから足す**（先回りで UI を増やさない）。

#### 7-2. ⚠⚠ AppBar は「アカウント 1 つ・タブ 1 本」を前提に組んである

```dart
// home_screen.dart:613-692
title: …UserAvatar(account.user) + 表示名 + サーバーバッジ…        // ⚠ 現在のアカウント
actions: [
  if (ref.watch(selectedTabProvider) case TimelineTab(:final type) …)
    const _StreamStatusIndicator(),                                // ⚠ 選択中タブの接続状態
```

⚠⚠ **接続インジケータをデッキで画面共通の AppBar に 1 個だけ置くと、[#793](https://github.com/pooza/capsicum/issues/793) の再発になる。**#793 はまさに「**表示中の内容と無関係な裏のホーム購読状態を出していた**」を直した回で、コメントに経緯が残っている（`home_screen.dart:681-687`）。デッキでは購読が N 本あるので、**1 個のインジケータはどれの状態でもない**。

**決定: 接続インジケータはカラムのヘッダーへ降ろす。**⚠ **未決事項 2-C（カラムごとにソケットを分ける）と噛み合っている** — カラムごとに独立した接続状態が取れるので、**カラム単位のインジケータが素直に作れる**。

⚠ **アカウント表示も同じ。**フェーズ 2 でカラムごとにアカウントが変わると、AppBar のアバターは何も指さなくなる。**カラムヘッダーにアカウントを出す**（フェーズ 1 の時点では全カラム同じアカウントなので実害は無いが、**ヘッダーの置き場だけ先に作っておく**）。

---

## 参考実装: SubwayTooter（2026-09-06 にソースを実読）

⚠ **推測で語らないための実読。**[tateisu/SubwayTooter](https://github.com/tateisu/SubwayTooter)（Kotlin / Apache-2.0 / 最終 push 2025-11-30）は #720 が名指しした参考元。**狭幅の扱いに直接の答えを持っていた。**

⚠ **参照は設計の参考に留める**（[Kaiteki](https://github.com/Kaiteki-Fedi/Kaiteki) と同じ扱い）。コードは持ち込まない。

### 1. ⚠⚠ 狭幅モードは存在しない。同じ 1 つの部品が 1 カラムにも N カラムにもなる

- 本体は **横向き `RecyclerView`（`LinearLayoutManager.HORIZONTAL`）+ `GravitySnapHelper`**（`ActMainTabletViews.kt`）
- 幅に応じて**見えるカラム数が変わるだけ**で、1 カラムになったときは snap が効いて**そのままページャとして振る舞う**

→ ⚠⚠ **未決事項 1 の (a) と (c) は「同じ設計の両端」であって、選ぶものではなかった。**「広幅専用にするか、狭幅ではスワイプにするか」という問いの立て方自体が誤りで、**正しくは (b)（カラム幅を可変にする）1 案しかない。**

### 2. ⚠⚠ 最小カラム幅は **300dp**。capsicum の想定の半分

`ActMainColumns.kt` の `resizeColumnWidth()`（既定値は `ActMain.COLUMN_WIDTH_MIN_DP = 300`、**ユーザー設定で 100dp まで下げられる**）:

```kotlin
if (screenWidth < columnWMin * 2) {
    nScreenColumn = 1; columnW = screenWidth        // 2 本入らないなら 1 カラム
} else {
    nScreenColumn = screenWidth / columnWMin        // 最小幅から表示数を決める
    if (columnCount < nScreenColumn) nScreenColumn = columnCount
    columnW = screenWidth / nScreenColumn           // 余りは各カラムへ均等配分
    columnW = min(columnW, columnWMin * 1.5)        // ⚠ 上限 1.5 倍
}
```

既定 300dp での実際の挙動:

| 幅 | カラム数 | 各カラム |
| --- | --- | --- |
| 599px | 1 | 599 |
| **600px** | **2** | 300 |
| **800px**（pooza の常用域） | **2** | 400 |
| 900px | 3 | 300 |
| 1200px | 4 | 300 |

⚠⚠ **pooza の常用幅（800px 未満〜900px）で 2 カラム入る。**capsicum は今 **1 カラム ≒ 600px** を前提にしているので、**衝突の実体は「デッキ vs 狭幅」ではなく「capsicum のカラムが太すぎる」だった。**

⚠ **`columnW` に 1.5 倍の上限があるのが効いている。**広い画面では**カラムを太くせず本数を増やす**。デッキの価値（同時に見える本数）が画面幅に素直に比例する。

### 3. ⚠⚠ ナビゲーションに横の画素を 1px も使っていない

`act_main.xml` の構造:

```text
DrawerLayout                     ← ⚠ ドロワーは常駐せずオーバーレイ
└ 縦 LinearLayout
  ├ rvPager (match_parent)       ← カラムの横スクロール本体
  └ 高さ 48dp の横バー
    ├ ハンバーガー 48dp
    ├ svColumnStrip              ← ⚠ カラム選択は「横スクロールするアイコン列」
    └ 投稿ボタン 48dp
```

⚠⚠ **カラム選択 UI が縦 48dp のフッターに載っていて、横幅を消費しない。**

対して capsicum は **900px 以上でドロワーを 304px 常駐**させている（`home_screen.dart:574`。閾値の根拠が「本文 600 + ドロワー 304」）。⚠ **デッキではこの 304px がカラムと直接取り合う。**800px なら**ドロワーだけで幅の 38%** を占める。

→ ⚠ **デッキ導入時は、ナビゲーションを横軸から降ろす必要がある。**常駐ドロワーをデッキ時だけオーバーレイに戻すか、カラム選択を上下いずれかのストリップへ移すか。**これはレイアウトの都合ではなく、狭幅で成り立たせるための必須条件。**

### 4. capsicum に持ち込めない / 検証が要る差分

- ⚠ **capsicum の投稿タイルが 300dp で読めるかは未検証**（未決事項 8）。SubwayTooter の行より capsicum のタイルは要素が多い可能性がある
- ⚠ **横長カスタム絵文字との相互作用。**capsicum は絵文字幅に固定倍率 cap を置かず**利用可能幅で頭打ち**にする方針（[#858](https://github.com/pooza/capsicum/issues/858)）で、ダイスキーには横長絵文字が定常的に流入する。**カラムが細くなるほど縮小率が上がる**ので、狭カラムでの見え方を実機で見る必要がある
- ⚠ **プレビューカードの高さが動的に変わる問題**（[#1032](https://github.com/pooza/capsicum/issues/1032) / [#1033](https://github.com/pooza/capsicum/issues/1033)）は**カラムが細いほど折り返しが増えて悪化する**方向。デッキ着手前に片付いていることが望ましい

---

## 未決事項

### 1. ~~狭幅運用とデッキは正面から衝突する~~ → **2026-09-06 に決着（下の §参考実装 を参照）**

⚠ **当初「最も答えを要する問い」として 3 案を並べたが、SubwayTooter のソースを読んで解消した。**(a) 広幅専用 / (c) 狭幅はスワイプ切替 は**同じ設計の両端**であって選択肢ではなく、実際の答えは (b)（カラム幅を可変にする）だった。経緯と根拠は「参考実装: SubwayTooter」節に移した。

**残る問いは 1 つだけ**: ⚠ **capsicum の投稿タイルが読める最小幅は実測何 px か。**SubwayTooter の既定は 300dp だが、capsicum のタイルがそれで成立するかは測っていない（未決事項 8）。

<details><summary>当初の 3 案（記録として残す）</summary>

- デッキの価値は複数カラムを**同時に見る**ことにある
- 一方 capsicum は **1 カラム ≒ 600px** を前提に組んである（[home_screen.dart:574](../packages/capsicum/lib/src/ui/screen/home_screen.dart) の閾値 900px = 本文 600 + ドロワー 304 という根拠つき）
- ⚠ **pooza の実況スタイルは動画アプリとの横並びで、capsicum の幅は普段から 900/800px 未満**（メモリ `project_desktop_split_screen_usage`。「狭幅で成り立つことが前提」は要件として明記されている）

→ **2 カラムを常時見るには最低 1200〜1500px 要る。#720 の second stakeholder は pooza 本人**（[Issue の需要シグナル更新](https://github.com/pooza/capsicum/issues/720)）**だが、その pooza の日常の窓幅ではカラムが 1 本しか入らない。**

考えられる出口（**どれを採るかは製品判断なので pooza が決める**）:

| | 案 | 含意 |
| --- | --- | --- |
| a | **デッキは広幅専用機能**と割り切る | 狭幅では従来タブ。⚠ pooza 自身の日常では使われない機能になる |
| b | **カラム幅を可変にする**（狭幅でも 2 本入る密度） | 1 カラム 600px の前提を崩す。post_tile の可読性の再設計が要る |
| c | **狭幅では「カラムをスワイプで切り替える」形**（＝実質タブ + カラム状態の保持） | ⚠ **実は現状のタブとの差が「状態を保持し続けるか」だけになる。**B-1 の解消だけで大半の価値が出る可能性がある |

⚠⚠ **c が正しかった場合、#720 の規模は大幅に下がる。**「複数カラムを同時表示」ではなく「**複数の TL を同時にライブで保持し、切り替えても状態が消えない**」が本質だったことになり、フェーズ 1 の streaming 多重化 + provider family 化までで足りる。**この確認を飛ばすと、使われないレイアウトを作りうる。**

</details>

### 2. ~~カラムの購読モデル（コストの上限）~~ → **2026-09-12 に決着（[#1086](https://github.com/pooza/capsicum/issues/1086)）**

⚠⚠ **いちばん効いた発見: 「1 ソケット多重化か・カラムごとにソケットか」は、今決める必要が無い。**

`StreamSupport` を**カラムキー付き**にすれば、接続方式は実装の内部事情に落ちる。決めるのは**購読の範囲**（下の 2-B）だけでよい。

#### 2-A. 購読の抽象をキー付きにする（決定）

現行の [`stream_support.dart:25-35`](../packages/capsicum_core/lib/src/social/interfaces/stream_support.dart) は **単数前提**:

```dart
Stream<Post> streamTimeline(TimelineType type, {...});
void disposeStream();                                  // 引数なし＝「唯一の接続」を閉じる
```

→ **カラムキーを通す形へ変える**（`streamTimeline(key, type, …)` / `disposeStream(key)`）。キーは `(AccountKey, TabType)` で、どちらも可逆シリアライズを既に持っている（`AccountKey.toStorageKey()` / `tab_type.dart:20-22`）。

⚠ **これで [#1090](https://github.com/pooza/capsicum/issues/1090) が抱えていた二択（ソケット分割 vs `subscribe` 方式）は設計判断でなくなる。**上位から見えるのは「キー → Stream」だけなので、**あとから内部だけ差し替えられる**。

#### 2-B. 購読は可視カラムのみ live（決定・2026-09-12 pooza）

**画面に映っているカラムだけ接続し、画面外は猶予を置いて切る。**カラムの**状態は保持**し、戻ってきたら既存の `_catchUpSinceTop()`（`timeline_provider.dart:1320-1324`・#781）で埋める。

- ⚠ **接続数の上限が画面幅で決まる**のが要点。カラム数はユーザーが決める（3〜10）が、同時接続は**画面に入る本数**（狭幅 1・広幅 3〜4）で頭打ちになる
- ⚠ **切るのは「画面外に出た瞬間」ではない。**横スクロールのたびに張り直すと**再接続の嵐を自分で作る**ので、猶予を置いて LRU で保持する（保持上限は「画面に入る最大カラム数 + 1〜2」）
- ⚠⚠ **代償: 画面外の列に「新着あり」を出せない。**デッキの売り（隣の列の動きが見える）は**可視カラムで成立している**ので損なわれないが、狭幅のスワイプ切替では「裏の列に新着」が出せない。**これを出したくなったら 2-B を見直す**（購読方式ではなく購読範囲の変更になる）
- **モバイルのバックグラウンドは全切断**。⚠ **現状すでに維持する仕組みが無い**（`didChangeAppLifecycleState` は streaming に触っていない・`main.dart:1246-1251` / `home_screen.dart:141-163`）。バックグラウンドの通知は Push（APNs / FCM）、デスクトップは常駐 + WebSocket という既存の役割分担をそのまま引き継ぐ

#### 2-C. 初期実装は「カラムごとに 1 ソケット」（決定・技術判断）

2-A により**後から変えられる**ので、安いほうから入る。

| | カラムごとにソケット（**採用**） | 1 アカウント 1 ソケットで多重化 |
| --- | --- | --- |
| Misskey | `_chatRoomStreamings`（`misskey/adapter.dart:136, 2487-2519`）が**キー付きレジストリの先例**。そのまま拡張できる | `connect` に `id` は既に送っているが、`_onMessage` が `body['id']` を見ていない（`misskey/streaming.dart:145` と `:173-181`）。ルーティングの新規実装 |
| Mastodon | ⚠ **無改修。**現行の `?stream=<name>` 方式（`mastodon/streaming.dart:101-107`）のまま複数張るだけ | ⚠⚠ **全面書き換え。**`subscribe` / `unsubscribe` フレームは**コードに 1 箇所も無い** |
| 障害の粒度 | **カラムごとに独立。**1 本落ちても他は生きる。UI のインジケータ（`TimelineState.streamConnectionState`）は family 化でそのまま合う | ⚠ **1 本落ちると全カラムが同時に落ちる。**状態の粒度を作り直す必要がある |
| 接続数 | 可視カラム数（2-B で上限が付く） | 1 |

⚠ **Mastodon 公式は「1 本の WS に `subscribe` で複数 stream」を想定している**ので、接続数が実測で問題になったら 2-A の抽象の下で `subscribe` 方式へ差し替える。**そのときも上位（provider / UI）は無改修。**

⚠⚠ **テストの防壁が無い状態で入る。**`MisskeyStreaming` / `MastodonStreaming` の接続・`connect` フレームを固定するテストは**存在しない**（あるのは `streaming_backoff_test`（計算のみ）と `*_notification_streaming_test`（パースのみ））。#1089 / #1090 の完了条件にある「**2 本購読して 1 本目にイベントが来続ける**」は、**この空白を埋める最初のテストになる**。

#### ⚠ 残る観測点

- 再接続イベント（`timeline.stream.disconnected` / `reconnect_exhausted`・CAPSICUM-37 / 36 / 3D / 25）は**可視カラム数ぶんに増える**。`_catchUpSinceTop()` の REST 呼び出しも同じ倍率で増える
- ユーザー向けの逃げ道は現状 `streamingEnabledProvider` の**全 ON / 全 OFF だけ**（`preferences_provider.dart:1095-1102`）。カラム単位の live トグルは無い。**要るかは出してから測る**
- 先例として、**全ルーム常時購読を接続数とバッテリーを理由に諦めた判断が既にある**（`chat_thread_list_screen.dart:38-43`。「復帰時に再 fetch」の妥協ラインを採った）。2-B はこれと同じ形

### 3. #887 の保証をデッキでどう定義するか（B-3）

「ブロックした相手が**見えているどの TL からも消える**」は安全のための保証。デッキでは:

- **可視カラム全部**に適用するのか
- **同一アカウントのカラム全部**か（別アカウントのカラムには別のブロック関係がある）
- ⚠ **アカウント A でブロックした相手は、アカウント B のカラムには依然として出る**のが**正しい**。これは仕様として明示しないと「消えないバグ」に見える

### 4. モバイルでデッキを出すか

Issue の題は「SubwayTooter 風」で、SubwayTooter は Android のデッキ。⚠ しかし capsicum の設計指針は「**UI の分岐軸はプラットフォームではなく画面幅**」（[CLAUDE.md](CLAUDE.md#デスクトップ対応)）なので、**「モバイルだから出さない」という切り方は規約に反する**。未決事項 1 の c 案はこことも噛み合う。

### 5. デッキ構成の永続化とバックアップ互換

- カラム列は `TabType.toKey()` + `AccountKey.toStorageKey()` で表現できる（1-3）ので**形式は難しくない**
- ⚠ **設定バックアップ（#959 系）に含めるかは別問題。**デッキ構成はアカウント参照を含むので、別端末へ復元したときに**存在しないアカウントを指すカラム**が生じる。落とし方（黙って消す / プレースホルダを出す）が未決

### 7. ~~案 S（スコープ上書き）が本当に成立するか~~ → **2026-09-06 に実測して決着。案 S を採る**

**プロトタイプ**: [`packages/capsicum/test/deck_scope_spike_test.dart`](../packages/capsicum/test/deck_scope_spike_test.dart)（7 項目・全 pass）。⚠ **使い捨てのつもりだったが契約 pin として残した**（理由はファイル冒頭）。

| # | 確かめたこと | 結果 |
| --- | --- | --- |
| 1 | 子スコープで上書きすると、`dependencies:` を宣言した派生 provider がそのスコープの値を返すか | ✅ **返す**（root / A / B が独立に解決） |
| 2 | `AsyncNotifierProvider.autoDispose`（本線 TL 相当）がスコープごとに別インスタンスか | ✅ **別**（`build` が 2 回走る） |
| 3 | 宣言漏れの provider が**ルートの値を黙って読む**か | ⚠⚠ **読まない。`AssertionError` で落ちる** |
| 3-b | その検出は release でも効くか | ❌ **効かない**（`assert` ブロック内） |
| 4 | **実物**の `currentAccountProvider` を `overrideWithValue` できるか | ✅ **できる** |
| 5 | **実物**の `currentAdapterProvider` は今のままスコープに追随するか | ⚠ **しない**（宣言が要る＝フェーズ 2 の作業そのもの） |
| 6 | ウィジェット階層のネスト `ProviderScope` でも同じか | ✅ **同じ**（子孫は**無改修**で自分のカラムのアカウントを見る） |

#### ⚠⚠ 想定が外れた点（良い方向に）

**「宣言漏れ＝黙って現在のアカウントで動く」という前提で案 S のリスクを見積もっていたが、誤りだった。**Riverpod 2.6.1 は宣言漏れを検出し、**直し方まで書いたメッセージで落とす**:

```text
Tried to read Provider<String> from a place where one of its dependencies were
overridden but the provider is not.

To fix this error, you can add <dependency> (a) to the "dependencies" of <provider> (b)
```

→ **案 S の最大の懸念（silent failure 型・このプロジェクトが 3 リリース連続で踏んだ形）は成立しない。**宣言漏れは**開発中に大声で出る**。

#### ⚠ ただし検出は debug 限定

実体は `riverpod-2.6.1` の `lib/src/framework/container.dart:430` にある `assert(() { ... }(), '')` **ブロック丸ごと**。release では assert が落とされ、`reader.getElement()` が**ルートスコープの element を返す**＝黙って「現在のアカウント」で動く。

| | 宣言漏れの挙動 |
| --- | --- |
| **開発 / CI（debug）** | **AssertionError で落ちる。**自動的に気づく |
| **本番（release）** | ⚠ **黙ってルートを読む。**テストが 1 度も踏まない経路は素通り |

→ ⚠ **走査テストは「唯一の検出手段」から「テストが踏まない経路の網羅保証」へ役割が下がる。不要にはならない**（UI 62 ファイルを全部踏むテストは存在しない）。**成立条件ではなく通常の保険**として置く。

#### 結論

**案 S を採る。**B-2 の性質は「87 ファイルの書き換え」ではなく「**22 の `dependencies:` 宣言 + カラムを包む 1 箇所 + 保険の走査テスト**」。⚠ **UI 62 ファイルは無改修。**

⚠ **Riverpod 3 はスコープの規則を変えている。**上げるときにこの前提が崩れるので、スパイクテストを残して落ちるようにしてある。

### 8. ~~capsicum の投稿タイルが読める最小幅~~ → **2026-09-06 に決着。下限 375px**

> 金星魔術卿（iPhone 13 mini）のカラムが、成り立つがだいぶ狭いというぐらいです。これがミニマムだと言うなら、まぁ納得です。（2026-09-06 pooza）

**最小カラム幅 = 375px**（iPhone 13 mini の論理幅）。⚠ **「快適な幅」ではなく「これ以上狭くしない下限」**として確定。SubwayTooter の 300dp より **75px 広い**。

#### ⚠ なぜ 375 が下限なのか — 律速は最上段

> PostTile の最上段が 375 の時点でかなり窮屈（2026-09-06 pooza）

コードで裏が取れる。`post_tile.dart:544` の最上段は 1 行の `Row`:

| 要素 | 幅の振る舞い |
| --- | --- |
| 表示名（`EmojiText`） | `Expanded` + `maxLines: 1` + ellipsis。**残り全部を取り、足りなければ「…」で削られる** |
| バッジ群（bot / group / **ロール** / 公開範囲 / localOnly / 時刻） | `ConstrainedBox(maxWidth: 0.6 × 利用可能幅)` の中の **`FittedBox(scaleDown)`** |

**この 2 つが同じ 1 行を奪い合う。**幅が減ると**表示名は省略が進み、バッジ群は縮小率が上がる**。両方が同時に劣化するので、体感は本文より最上段のほうが先に苦しくなる。

⚠ **ロールアイコンは個数が可変**（`for (final role in author.roles)`）。ロール運用のあるサーバー（Misskey 系）では**バッジ群が長い投稿ほど不利**なので、最悪ケースは「長い表示名 × ロール多数」の投稿。

⚠ **インスタンスティッカーは最上段ではなく下の別行**（`post_tile.dart:637`）なので、非表示にしても**横方向は 1px も空かない**（縦が詰まるだけ）。

#### ⚠⚠ 方法論の教訓: この下限は overflow 検出では見つからない

**バッジ群が `FittedBox(scaleDown)` なので、狭くしても overflow が起きない。**レイアウトは「壊れる」のではなく**黙って縮む**。

- 実際、2026-09-06 の探りでは **`PostTile` は 300px でも `testWidgets` の overflow 検査を素通りした**
- → ⚠ **②（機械計測）を先に回していたら「300px で問題なし」という誤った結論が出ていた。**①（人の目視）が正解だったのは偶然ではない
- ⚠ **将来ここを自動化しようとする人への警告として残す。**測るべきは overflow ではなく「表示名の省略率」と「`FittedBox` の縮小率」

#### 幅からカラム数がどうなるか

| 窓幅 | ドロワー | 本文に使える幅 | カラム数 | 各カラム |
| --- | --- | --- | --- | --- |
| 750px | オーバーレイ | 750 | **2** | 375 |
| **800px**（pooza の常用域） | オーバーレイ | 800 | **2** | **400** |
| **899px** | オーバーレイ | 899 | **2** | 449 |
| **900px** | ⚠ **常駐 304px** | **596** | ⚠ **1** | 596 |
| 1054px | 常駐 304px | 750 | 2 | 375 |
| 1429px | 常駐 304px | 1125 | 3 | 375 |

⚠ **常用域の 800px で 2 カラム・各 400px。**13 mini の 375px より広いので、**pooza の実況環境でデッキが成立する。**

#### ⚠⚠ 900px でカラムが減る — 常駐ドロワーはデッキと両立しない

**窓を 899px から 900px へ 1px 広げると、カラムが 2 本から 1 本に落ちる。**ドロワーが常駐に切り替わって 304px を持っていくため。

⚠ **これは「参考実装」節 3（SubwayTooter はナビゲーションに横の画素を使わない）の裏返しが、capsicum の実数で出た形。**推測ではなく、現行の 900px 閾値と下限 375px から算術的に出る。

→ **決定: デッキ表示時は常駐ドロワーを出さない。**
- 常駐ドロワーで 2 カラム欲しければ **1054px**、3 カラムなら **1429px** 必要になり、狭幅運用の要件（`project_desktop_split_screen_usage`）と両立しない
- 代替はナビゲーションを縦軸へ移すこと（SubwayTooter の `svColumnStrip` = 高さ 48dp のフッターに載る横スクロールのアイコン列が実例）
- ⚠ **これは #720 に付随する UI 変更ではなく、成立条件。**Issue 分解時に独立した項目として立てる

#### 既定値

**下限 375px・既定も 375px** を推す。既定を 400 以上に上げても常用域 800px でのカラム数は 2 のまま変わらず、**下げ幅の自由（3 カラム欲しい人が詰める）だけが失われる**ため。⚠ **カラム幅はユーザー設定にする**（SubwayTooter と同じ）。

⚠ **375 より下を将来ほしくなったら、触るのは最上段**（上記）。バッジ群の折り返し・優先度の低いバッジの間引きが効く見込み。**ただし今は要らない。**⚠ **#720 のスコープに含めない**（下限が決まった以上、先回りで作ると使われない実装になる）。

<details><summary>決着前の検討（記録）</summary>

⚠ **「600px」は最小幅ではなく、ドロワー閾値を決めるための想定値**だった（`home_screen.dart:574` のコメント）。**capsicum は最小可読幅を一度も確定させていない。**

#### ⚠⚠ ただし、すでに大部分は答えが出ている — **モバイル版がそれ**

2026-09-06 に調べたところ、**この問いは新規の未知ではなかった**:

- ⚠ **`PostTile` に幅の分岐が無い。**`LayoutBuilder` は 3 箇所あるが、いずれも `constraints.maxWidth * 0.6` のような**比例配分**で、閾値で作りを変える分岐ではない。**capsicum の UI 全体でも幅の breakpoint は `home_screen.dart:574` の 900px（ドロワー常駐）1 つだけ**
- → **モバイルとデスクトップは同じタイルを描いている。**幅が違うだけ

したがって:

| 端末 | 論理幅 | 状態 |
| --- | --- | --- |
| iPhone 14（報告者 ore_orue 氏の常用機） | **390px** | **毎日使われている** |
| iPhone SE | 375px | 出荷対象 |
| Android compact | 〜360dp | 出荷対象 |
| SubwayTooter の既定 | 300dp | 参考値 |

⚠⚠ **`PostTile` は実質 375〜390px で本番稼働しており、狭さの苦情は出ていない。**「最小可読幅は不明」ではなく、**「375px 以上は実証済み。未知なのは 300〜375px だけ」**が正確なところ。

⚠ **ただしモバイルの実績をそのまま持ち込めない理由もある**（だから完全な答えではない）:

- **視距離と DPI が違う。**スマホは 30cm・高 DPI、デスクトップは 60cm・低 DPI。同じ論理幅でも見え方が変わる
- **デスクトップにしか出ない要素**（インスタンスティッカー・hover 前提の導線）が幅を食う可能性
- ⚠ **横長カスタム絵文字**（[#858](https://github.com/pooza/capsicum/issues/858)・ダイスキーに定常流入）は**利用可能幅で頭打ち**にする方針なので、カラムが細いほど縮小率が上がる

#### 進め方（安い順・⚠ 1 段ずつ）

**① まず pooza の目視 1 回（コード変更ゼロ・所要 1 分）**

⚠ **デスクトップの窓を縮める方法は使えない。**`window_state_service.dart:26` が `_minSize = Size(640, 480)` を課しているので **640px より狭くできない**（デッキのカラム幅の検証域に届かない）。

代わりに **iPhone の capsicum をそのまま「1 カラム」として見る**。390px はデッキのカラムとしては広いほうなので、⚠ **ここで「これで実況できる」と感じるなら、下限を 320〜360 に置く判断ができる。**逆にここで既に狭いと感じるなら、デッキの前提（同時に複数本見る）自体を見直すことになる。

**② ①で判断がつかないときだけ、機械で詰める（Claude 側で可能）**

⚠ **2026-09-06 に実現性だけ確認済み。**`PostTile` を widget test で幅 300px に描けることを実測した（`initSharedPreferencesCache` の呼び出しが要る・`testWidgets` は overflow を自動で例外にするので破綻点は機械的に取れる）。⚠ **ただし単純な本文では 300px でも破綻しなかった**ので、**現実的な投稿の型**（長い日本語 + タグ多数 / プレビューカード / 添付 4 枚 / 横長絵文字 / 長い表示名 + ティッカー / CW）を並べないと意味が無い。

⚠ **golden 画像を出せば pooza も Claude も同じものを見られる**（PNG はファイルなので `reference_desktop_gui_not_observable` の制約を受けない）。ただし**日本語フォントの読み込みとネットワーク画像の差し替え**が要るぶん、①より高い。

**③ 下限が決まったら、カラム幅はユーザー設定にする**（SubwayTooter と同じ）。**確定させるのは下限値だけでよい。**

→ **①で決着した。**②の機械計測は回さずに済んだ。⚠ **モバイル実績を先に確認したことで、実機検証も golden 画像も不要になった**という記録として残す。

</details>

### 6. ~~着手のタイミング~~ → **2026-09-06 に Issue へ分解済み（16 件）**

**[#720](https://github.com/pooza/capsicum/issues/720) は 16 件に分解して v2.0 へ入れた**（[索引コメント](https://github.com/pooza/capsicum/issues/720)）。設計書の見立て（フェーズ 1〜3 で最低 12〜15 件）とほぼ一致した。

| フェーズ | 件数 | Issue |
| --- | --- | --- |
| **1. 単一アカウントのマルチカラム（土台）** | **9** | #1086 / #1087 / #1088 / #1089 / #1090 / #1091 / #1092 / #1093 / #1094 |
| **2. カラムごとのアカウント束縛** | **3** | #1095 / #1096 / #1097 |
| **3. 仕上げ** | **4** | #1098 / #1099 / #1100 / #1101 |

- **着手順の先頭は [#1086](https://github.com/pooza/capsicum/issues/1086)（カラムの購読モデルの決着）。**⚠ **この答えで streaming 多重化（#1089 / #1090）の作りが変わる**ので、実装より先に決める
- ⚠ **#720 本体は親として残す**（`on-hold` ラベルは分解に伴い外した）。**フェーズ 1 だけをリリースしても close しない**
- **1.x とは並走のまま**（v1.64 を稼働させたまま分解した）。「1.x を止めて設計に寄せる」は結局採らなかった

⚠ **分解の結果、v2.0 の open は 21 → 37 件。**[roadmap.md](roadmap.md)「決定済み事項 3」の閾値（v1.0 の 46 件）にはまだ届かないが、**#597 の分解ぶんが未計上**。逃がす判断はそちらが出てから。

---

## 関連

- [#720](https://github.com/pooza/capsicum/issues/720) — 本 Issue（方針コメント 3 本が本文より重要）
- [roadmap.md](roadmap.md) — v2.0 の枠設計・逃がす順序（⚠ #720 は逃がさない対象）
- [CLAUDE.md「デスクトップ対応」](CLAUDE.md#デスクトップ対応) — 画面幅を分岐軸にする設計指針
- [archive/desktop-notification-design.md](archive/desktop-notification-design.md) — 設計書の型の先例（⚠ 書いた結果 #476 が不要と判明した回）
- [tateisu/SubwayTooter](https://github.com/tateisu/SubwayTooter) — #720 が名指しした参考元（Kotlin / Apache-2.0）。⚠ **狭幅の扱いはここを読んで決着した**（「参考実装」節）。設計の参考に留め、コードは持ち込まない（Kaiteki と同じ扱い）
