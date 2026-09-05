# デッキ表示 設計スパイク（#720）

[#720](https://github.com/pooza/capsicum/issues/720)（アカウントに依存せず複数カラムを並べて表示する）を「着手可否を判断できる状態」へ動かすための **feasibility spike**。

- 作成日: **2026-09-06**
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

⚠ **いちばん重要な発見: 難所は UI ではなく「アカウントの解決」にある。**「複数カラムを並べる」というレイアウトの話は、実は最も安い部分だった。高いのは**カラムごとにアカウントが違いうる**ことで、現状はアプリ全体が「いま 1 つのアカウントを見ている」前提で書かれている。

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

⚠ **したがって「単一アカウントのマルチカラム」と「マルチアカウントのマルチカラム」は、規模が 1 桁違う。**#720 の題は後者（「アカウントに依存せず」）なので逃げられないが、**段階を切る線はここにある**（段階性の節）。

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

---

### 2. デッキが壊す境界

現構造のどこが破綻するか。severity 順。

| | 境界 | 何が起きるか | 重さ |
| --- | --- | --- | --- |
| **B-1** | **1 アカウント 1 ソケット**（1-4） | 2 本目のカラムを購読した瞬間に 1 本目のライブが止まる。**しかも無音**（例外にならない） | 🔴 大 |
| **B-2** | **`current*` を読む 87 ファイル**（1-1） | **アカウント B のカラムに出ている投稿を、アカウント A としてお気に入り / ブースト / 返信してしまう。**`post_tile.dart` だけで 12 のアクション地点が `ref.read(currentAdapterProvider)` を読んでいる | 🔴 大 |
| **B-3** | **`readVisibleTimelines`**（[visible_timeline.dart:159](../packages/capsicum/lib/src/ui/util/visible_timeline.dart)） | 「表示中の TL」を `selectedTabProvider` **単数**から解決している。デッキでは可視 TL が N 本になり、#887 の保証（**ブロック / ミュートした相手が見えているどの TL からも消える**）が N-1 本で破れる | 🟠 中 |
| **B-4** | **family キーにアカウントが無い**（1-3） | 2 アカウントで**同じタグ**のカラムを並べると、同一 provider インスタンスを共有して**片方のサーバーの投稿がもう片方に混ざる** | 🟠 中 |
| **B-5** | **タグ / リスト / チャンネルに streaming が無い**（1-4） | デッキの主用途で「並べたけど更新されない」 | 🟠 中 |
| **B-6** | **起動キャッシュ 1 スロット**（1-5） | N カラムの先出し不可 | 🟢 小（回避可） |
| **B-7** | **`TimelineCache.clear()` が全体を消す** | `removePostsByUser` がブロック時にキャッシュを丸ごと捨てる。カラム別スロットにすると「どれを捨てるか」の判断が要る | 🟢 小 |

⚠⚠ **B-2 がいちばん危ない。**B-1 は「動かない」なのでユーザーが気づくが、**B-2 は「間違ったアカウントとして成功する」**。しかも [feedback: 隠すべきものを隠していないのは実害] の第 3 の型（見せたくないものが見えている）に隣接する — 別アカウントの identity で操作が外部に出る。

⚠ **B-2 は機械で止められる形をしている。**#1044 の `effectiveReaction()` と同じく、**アダプタの解決を 1 箇所に寄せて、`current*` の直読みをテストで禁止する**（`reaction_acceptance_coverage_test.dart` と同型の走査テスト）。87 ファイルを人手で「全部見たつもり」になるのは、v1.63 で 2 回失敗した形そのもの。

⚠ **B-3 は「デッキにおける『表示中』とは何か」という設計判断を含む**ので、機械的な置き換えでは済まない（未決事項 3）。

---

### 3. 段階性と規模の見立て

**3 段階。境界は 1-2 の非対称（タブ singleton 5 ファイル vs アカウント singleton 87 ファイル）に沿って引く。**

#### フェーズ 1: 単一アカウントのマルチカラム（土台）

- `timelineProvider` を `(AccountKey, TabType)` の family へ（1-3）
- 既存 3 family のキーに `AccountKey` を足す（B-4）
- カラム列の状態・永続化（`TabType.toKey()` + `AccountKey.toStorageKey()` の連結で済む）
- 横スクロールのカラムコンテナ。**既存のタブ UI は残したまま、狭幅では従来どおり 1 カラム**
- B-1 の解消（streaming の多重化）— ⚠ **ここが実装の山**

⚠ **この段階で `current*` には触らない。**アカウントは 1 つのままなので B-2 は発生しない。**フェーズ 1 だけで「タグ TL を 3 本並べる」という実況用途の大半が成立する。**

#### フェーズ 2: カラムごとのアカウント束縛

- カラムが `AccountKey` を持ち、その配下の描画・アクションが**そのアカウントのアダプタ**を使う
- B-2 の解消: `current*` の直読みを、**カラム文脈から解決する 1 本の入口**へ寄せる + 走査テストで禁止
- `unifiedNotificationProvider`（1-6）のパターンを一般化する

⚠ **87 ファイルすべてを直すわけではない。**「カラム内に出る」ものだけが対象（`post_tile` / `post_touch_action_row` / `notification_tile` と、そこから push される詳細系）。**設定・ログイン・バックアップ等は `current` のままで正しい。**⚠ **この仕分けがフェーズ 2 の設計の主題**で、いま件数を見積もれない部分。

#### フェーズ 3: 仕上げ

- B-5（タグ / リスト / チャンネルの live 購読）
- B-3 の再定義（#887 の保証をデッキで何にするか）
- B-6 / B-7、デッキ構成のバックアップ同梱

#### 規模

⚠ **Issue 数の見積もりは出せる段階ではないが、下限は言える。**フェーズ 1 だけで「provider の family 化 + streaming の多重化 + カラムコンテナ + 永続化」の 4 本に割れ、streaming の多重化は Mastodon / Misskey で別実装になるため単独で 1 枠ぶんある。**フェーズ 1〜3 で最低 12〜15 Issue、フェーズ 2 の仕分け次第で増える。**

⚠ **[roadmap.md](roadmap.md)「決定済み事項 3」の閾値（大玉の分解後に v2.0 全体が v1.0 の 46 件を超えるなら分割）に対して、#720 単独で 15 件前後を占める見込み。**#597 の設計書が出た時点で合算して判断する。

⚠ **メジャー判定は維持する。**B-1 / B-2 はどちらも UI ではなくデータ経路の話で、点リリースの粒度に収まらない。

---

## 未決事項

### 1. ⚠⚠ 狭幅運用とデッキは正面から衝突する（pooza への確認事項）

**これがこの spike で最も答えを要する問い。**

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

### 2. カラムの購読モデル（コストの上限）

- **全カラムを常時 live にするか、可視カラムだけか。**N アカウント × M カラムぶんの WebSocket をモバイルで常時張るのは現実的でない
- ⚠ 現状でも `timeline.stream.disconnected` / `reconnect_exhausted` は Sentry の常連（CAPSICUM-37 / 36 / 3D / 25）。**ソケットを N 倍にすると再接続の嵐も N 倍になる**
- 1 アカウント 1 ソケットで多重化する（Misskey はプロトコルが対応）か、カラムごとにソケットを分けるかで、この見積もりが変わる
- **モバイルのバックグラウンド・省電力との兼ね合いは未検討**

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

### 6. 着手のタイミング

- [roadmap.md](roadmap.md)「未決事項 1」のとおり、**1.x と並走させるか 1.x を一旦止めるかは未決**
- ⚠ **未決事項 1 の答え次第で規模が変わる**ので、**フェーズ 1 の Issue 分解より先に 1 を決める**

---

## 関連

- [#720](https://github.com/pooza/capsicum/issues/720) — 本 Issue（方針コメント 3 本が本文より重要）
- [roadmap.md](roadmap.md) — v2.0 の枠設計・逃がす順序（⚠ #720 は逃がさない対象）
- [CLAUDE.md「デスクトップ対応」](CLAUDE.md#デスクトップ対応) — 画面幅を分岐軸にする設計指針
- [archive/desktop-notification-design.md](archive/desktop-notification-design.md) — 設計書の型の先例（⚠ 書いた結果 #476 が不要と判明した回）
