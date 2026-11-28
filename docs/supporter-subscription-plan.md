# サポーターサブスクリプション（投げ銭）設計判断ドラフト

> **状態: 実装済み。** 投げ銭本体は v1.27（[#428](https://github.com/pooza/capsicum/issues/428)）、Windows IAP は v1.43（[#599](https://github.com/pooza/capsicum/issues/599)）で出荷済み。**現況の正本は「決定事項（2026-05-20 確定）」**と [product-policy.md](product-policy.md)「課金の方向性」。本書が現役で担うのは **§C-2 / C-2b / C-2c のストア審査回答文**（提出のたびに再利用する・[store-release スキルの submit-promote.md](../.claude/skills/store-release/submit-promote.md) が参照）と **C-3 の特商法表記**（コードが参照）。⚠ 決着した節（事務手続き A-0〜A-3・B の選択肢・D-2 / D-3・次アクション・§E の Windows IAP の叩き台）は [archive/supporter-subscription-plan-settled.md](archive/supporter-subscription-plan-settled.md) へ移した（2026-11-28）。Windows IAP の実装設計は [archive/windows-iap-design.md](archive/windows-iap-design.md)。

関連 Issue: [#428](https://github.com/pooza/capsicum/issues/428)（v1.27）
関連: [pooza/capsicum-relay](https://github.com/pooza/capsicum-relay)（初期設計経緯は [archive/push-relay-plan.md](archive/push-relay-plan.md)）、docs/CLAUDE.md「運営元」「プッシュ通知」節

## 決定事項（2026-05-20 確定）

A（事務手続き）が App Store / Google Play とも完了し、B / C-1 を確定した。
**以下が正本。B 節内の個別「推奨」記述は本節で上書きされる。**

| 項目 | 決定 | 補足 |
|---|---|---|
| B-1 課金形態 | **単発（消耗型 IAP）で開始** | 審査前提を訂正: 機能差別化なし方針では自動更新サブスクは Apple Guideline 3.1.2「継続的価値の提供」に正面から抵触し、むしろ審査が厳しい。capsicum はアプリ本体が完結した実機能を持つため trivial 判定の土台がなく、消耗型 tip jar は前例豊富で素直。「投げ銭」の語感とも一致 |
| B-2 金額階層 | **3 階層・円基準 ¥100 / ¥500 / ¥800** | 他通貨はストア換算。複数階層は審査対策にも有利。¥150 は App Store の価格ポイントが ¥1,000 まで 100 円刻みのため ¥100 に変更（2026-05-22） |
| B-3 特典範囲 | **一度でも投げ銭で生涯サポーターバッジ**（自分のプロフィールに恒久表示） | 機能差別化なしは確定方針。装飾レベルの恒久バッジのみ |
| B-4 状態保持 | **最終的にサーバー側保持が希望。v1.27 は工数次第で端末ローカルの「投げ銭済み」フラグで開始し、後日サーバーへ汲み上げる段階導入を許容** | 消耗型はストアの購入復元対象外（再インストール・複数端末でレシートが戻らない）。商品タイプ非依存の抽象層（サポーター判定 provider）で包み、保持先を内側に隠す。サーバー化は将来の有償リレー SKU 統合と一本化できる |
| C-1 特商法主体 | **法人名義 有限会社ビーショック** | CLAUDE.md の特商法表示方針と一致。問い合わせ窓口も法人側集約済みで導線が一貫。ストア発行元（個人）と表示主体（法人）が分かれても法的に矛盾しない |

将来のサブスク追加は破棄でなく追加（別商品タイプの併存）。外部ユーザー向け
通知リレー利用権と同一 SKU で束ねれば実機能の継続価値が付き、3.1.2 を正面
突破できる。今回の単発実装はその土台として両立する。

---

## A. 事務手続き

App Store / Google Play とも 2026-05-20 に完了した。手順（A-0〜A-3）と A-4 の 2〜4 は [archive](archive/supporter-subscription-plan-settled.md)。

### A-4. A 実施で判明した B/C への制約フラグ（2026-05-19）

A-1/A-2 を実施して確定した、B（商品設計）・C（法務）に効く事実：

1. **JCT 負担の非対称**: iOS は Apple がマーケットプレイスとして日本売上 JCT を処理。**Google Play は日本在住販売者が JCT を自己判定・徴収・納付する責任を負う**（Google が処理するのは日本国外販売者のみ）。→ **B-2（金額階層）**: Apple と同額でも Google 経由は手取りが JCT 分変わる前提で tier 設計が必要。
   - **扱いは「対応なし」で決着した（2026-10-10 pooza・[#1254](https://github.com/pooza/capsicum/issues/1254)）。**販売の主体は個人で、個人の事業の課税売上は免税点（基準期間で 1,000 万円）に遠く届かないので、免税事業者として消費税の申告・納付は発生しない。投げ銭と利用権（`supporter.relay.monthly`）の両方に当たる。⚠ **見直すのは次の 2 つが起きたとき**: 主体を法人へ移す（下の 3）/ 個人で適格請求書発行事業者の登録をする（登録すると売上の額によらず課税事業者になる）。

---

## B. 商品設計

⚠ **決定は上の「決定事項」の表が正本。**B-1〜B-3 の選択肢と推奨は [archive](archive/supporter-subscription-plan-settled.md)。

### B-1. 課金形態

単発（消耗型 IAP）。理由は「決定事項」の表。

### B-2. 階層と金額

3 階層・円基準 ¥100 / ¥500 / ¥800（他通貨はストア換算）。

### B-3. サポーター特典の範囲

一度でも投げ銭で生涯サポーターバッジ（装飾のみ・機能差別化なし）。

### B-4. サポーター状態の保持先

| 選択肢 | 内容 | 備考 |
|---|---|---|
| (a) 端末ローカル（レシート検証のみ） | StoreKit / Play のレシートで判定 | 最小。複数端末で個別に復元 |
| (b) リレーサーバーに状態を持つ | SKU をリレー利用権と統合 | #428 の「SKU 統合」案。実装重いが将来の有償リレーと一本化できる |

推奨: **(a)** で v1.27 を出し、(b)（リレー統合）は別マイルストーンで段階導入。
※ docs/CLAUDE.md の「同一 SKU で吸収」案は将来目標として保持しつつ、初版はローカル完結で割り切る。

**起票状況（2026-05-22）**: スマホ＋デスクトップ併用が主流という観測を受け、サーバー側保持（バッジのクロスデバイス同期・狭いスコープ）を [#596](https://github.com/pooza/capsicum/issues/596) として起票し v1.30 にアサイン。有償リレー利用権との SKU 統合は [#597](https://github.com/pooza/capsicum/issues/597)（on-hold）として分離し、#596 完了を前提とする後続に位置づけた。

---

## C. ストア審査・法務（要文言整備）

| 項目 | 状態 |
|---|---|
| "What does this app do?" 回答 | 下書きあり（C-2） |
| 特定商取引法に基づく表記 | 雛形あり（C-3）。主体・設置場所は要決定（C-1） |
| 領収書 / 返金ルート | ストア IAP 標準フロー（Apple/Google が一次窓口）で足りる想定。要最終確認 |
| サブスク解約導線の明示 | 方針あり（C-4） |

### C-1. 特商法表記の主体と設置場所（要決定）

CLAUDE.md「運営元」に方針の前提あり：

- サイト運営・問い合わせ窓口・特商法表示は**法人名義（有限会社ビーショック、capsicum-site / Google Workspace アドレス経由）**
- ただし**ストア発行元は個人（小石達也）**（法人化は #428 の必須トリガーではない。税務処理方針を含む判断根拠は非公開メモリ `project_supporter_subscription_individual_entity` が正本）

ここに「表記主体を法人にするか個人事業主にするか」の判断が残る：

| 選択肢 | 整合性・備考 |
|---|---|
| (a) 法人名義（有限会社ビーショック） | CLAUDE.md の特商法表示方針と一致。ストア発行元（個人）と表示主体（法人）が分かれるが、開発/配布/運営は別役割なので法的に矛盾しない（CLAUDE.md 記載） |
| (b) 個人事業主名義（小石達也） | ストア発行元と一致。税務処理方針次第でこちらが自然になりうる（判断根拠は非公開メモリ側）。CLAUDE.md の「特商法表示は法人名義」方針と要すり合わせ |

推奨: **(a) 法人名義**（CLAUDE.md の既定方針に従う。問い合わせ窓口も既に法人側に集約済みのため導線が一貫する）。
→ 設置場所は **capsicum-site に法人名義で設置**し、アプリ内（設定 or サブスク購入導線）からリンクで参照。

### C-2. "What does this app do?"（審査回答ドラフト・要調整）

> capsicum is a Mastodon / Misskey client for the Fediverse. The in-app
> purchase is an optional one-time "Supporter" tip offered in three fixed
> amounts. It does not unlock or gate any functionality — all features
> remain available to every user regardless of whether they tip. Supporters
> receive only a cosmetic acknowledgement: a permanent supporter badge shown
> on their own profile. The tip exists so that users who wish to support
> ongoing development and the operation of the project's push-notification
> relay infrastructure can do so voluntarily.

確定済み（2026-05-20）: 単発（消耗型）・3 階層 ¥100/¥500/¥800・生涯バッジ。
サブスクではないため Guideline 3.1.2（継続価値）の論点は発生しない。

### C-2b. IAP ごとの Review Notes（App Store Connect）

App Store Connect の各 In-App Purchase には「Review Information」があり、レビュー用
スクリーンショットとあわせて **Review Notes**（購入画面までの導線説明）を入れる。
機能アンロックを伴わない投げ銭 IAP は導線・性質を書かないと差し戻されやすいため
必須。下記英文を **3 SKU すべてに同一**で貼る（導線は共通）。導線は実コードで検証
済み（ドロワー →「設定」→「capsicum をサポート」→ 投げ銭画面、2026-05-22）。

```text
This in-app purchase is an optional one-time "Supporter" tip. It does NOT
unlock or gate any feature — every function of the app remains available
to all users whether or not they tip.

How to reach the purchase screen:
1. Launch the app and sign in to any Mastodon or Misskey server.
2. Open the navigation drawer (the menu icon at the top-left of the timeline).
3. Tap "設定" (Settings).
4. Tap "capsicum をサポート" (Support capsicum) — the row with a pink heart icon.
5. The Supporter screen lists three tip amounts (¥100 / ¥500 / ¥800).
   Tapping a price button starts this in-app purchase.

After a successful tip the only change is a cosmetic, permanent "Supporter"
badge shown on the user's own profile. This is a one-time purchase — there
is no subscription and no recurring charge.
```

- レビュー用スクリーンショットは投げ銭画面（3 階層が見える状態）を添付する。IAP
  登録後の TestFlight ビルド or StoreKit Configuration で 3 商品が価格付きで読み
  込まれた状態で撮るときれい。スクリーンショットは IAP の審査提出時にのみ必須で、
  それまでは "Missing Metadata" 状態で保存しておける
- 新規 IAP の初回審査提出は App Store Connect の Web UI 操作で、`fastlane release`
  （`upload_to_app_store`）はバイナリ＋メタデータのみ扱い IAP 提出は行わない。
  v1.27 の iOS 製品版昇格は IAP 提出を手作業で挟む（初回のみ。承認後は通常フロー）
- アプリ本体審査の「App Review Information」のデモアカウント／ログイン手順は別欄。
  v1.27 アプリ提出時に別途用意する

### C-2c. 商品の表示名・説明（IAP ローカリゼーション）

App Store Connect の IAP ローカリゼーション（日本語）に登録した確定文言。表示名・
説明はアプリの投げ銭画面にそのまま表示される（`product.title` を ListTile の
タイトル、`product.description` をサブタイトルに使用）。日本語のみで登録（主要
言語＝日本語のため必須要件を満たす）。文字数上限は表示名 30 字・説明 45 字。

| SKU / 価格 | 表示名 | 説明 |
|---|---|---|
| `supporter.tip.small` ¥100 | ちょこっとサポート | capsicum の開発と通知リレー運用へのささやかな応援です。 |
| `supporter.tip.medium` ¥500 | しっかりサポート | capsicum の開発と通知リレー運用へのしっかりした応援です。 |
| `supporter.tip.big` ¥800 | たっぷりサポート | capsicum の開発と通知リレー運用への大きな応援です。 |

Google Play 側の商品名・説明も同一文言で揃える。

### C-3. 特定商取引法に基づく表記（C-1 確定＝法人名義）

```text
販売事業者名     ：有限会社ビーショック
運営統括責任者   ：小石 達也
所在地           ：〔法定住所〕（請求があったら遅滞なく開示、の運用も可）
連絡先           ：〔法人問い合わせ窓口メール（Google Workspace アドレス）〕
販売価格         ：各サポーター（投げ銭）購入画面に表示（税込・¥100 / ¥500 / ¥800）
対価以外の必要料金：なし（通信料は利用者負担）
支払方法         ：Apple App Store ／ Google Play のアプリ内課金
支払時期         ：購入手続き完了時（単発・消耗型。継続課金なし）
役務提供時期     ：購入手続き完了後ただちに（サポーターバッジの恒久付与）
返品・キャンセル ：デジタルコンテンツ（消耗型）のため購入後の返金は原則不可。
                   返金可否は Apple / Google の各ストアポリシーに従う
```

※ 所在地・連絡先は「請求があれば遅滞なく開示」運用がストア審査・特商法とも許容される場合があるが、IAP では事業者情報の明示を求められやすい。法人名義のため法定住所は法人登記住所を用いる。

### C-4. 解約導線（単発のため不要）

B-1 確定（単発・消耗型）により継続課金がないため、サブスク解約導線は不要。
購入は都度完結し、自動更新・解約の概念がない。返金はストアポリシー準拠
（C-3）。将来サブスクを追加した場合に本節を解約導線方針として復活させる。

---

## D. 実装スコープ（設計確定後）

B/C 確定（2026-05-20）を受けた v1.27 実装スコープ。

- **商品**: iOS は StoreKit 2、Android は Google Play Billing。いずれも
  **消耗型（consumable）IAP を 3 SKU**（¥100 / ¥500 / ¥800 相当）。サブスク
  商品は作らない
- **SKU 命名規約**: 将来のリレー利用権 SKU 統合を見据えた前方互換な命名
  （例 `supporter.tip.small` / `.medium` / `.big`）
- **サポーター判定の抽象層**: 商品タイプ・保持先を内側に隠す
  `SupporterStatus` provider を 1 つ用意。UI（バッジ）はこの抽象層のみ参照。
  これにより (a) 後日のサーバー側移行、(b) 将来のサブスク追加 が抽象層内に
  閉じる
- **状態保持（B-4）**: v1.27 は端末ローカルに「投げ銭済み」フラグを永続化
  （消耗型はストア購入復元の対象外のため、レシート復元に依存しない）。
  サーバー側保持は工数を見て後日対応（ローカルフラグをサーバーへ汲み上げる
  移行経路を抽象層の内側に用意）
- **バッジ UI**: 自分のプロフィールに恒久表示のサポーターバッジ（B-3）。
  他者可視・なりすまし対策は対象外（サーバー側移行時に再検討）
- **特商法表記**: 法人名義（C-3）を capsicum-site に設置し、アプリ内
  購入導線からリンク参照
- **審査提出**: 単発投げ銭用の説明文（C-2）・スクリーンショット。サブスク
  ではないため解約導線・3.1.2 継続価値の論点なし
- 復元（Restore）UI は消耗型につき不要（サーバー側保持を実装した時点で
  「サポーター状態の同期」として別途設計）

### D-1. プラットフォームスコープ（v1.27）

| OS | v1.27 投げ銭購入 | バッジ表示 | 根拠 |
| --- | --- | --- | --- |
| iOS | ✅ StoreKit 経由 | ✅ | 主対象 |
| Android | ✅ Play Billing 経由 | ✅ | 主対象 |
| macOS | ❌ 後日 | ✅（ローカルフラグがあれば） | Mac App Store IAP は技術的に可能だが surface 増。サーバー側保持導入時に同期で対応 |
| Linux / Windows | ❌（ストア IAP 不在） | ✅（ローカルフラグがあれば） | ストア課金経路が無い。購入導線は出さない |

購入導線は iOS / Android のみ。バッジ UI は全 OS で `SupporterStatus`
（抽象層）を参照するだけなので、ローカルフラグ or 将来のサーバー同期で
立てば desktop でも表示される。**macOS への購入導線追加は overridable な
スコープ判断**（必要なら v1.27 に含める）。


D-2（プラグイン）・D-3（commit 分割）・次アクション・§E（Windows IAP の叩き台 E-0〜E-7）は [archive](archive/supporter-subscription-plan-settled.md) へ移した。
