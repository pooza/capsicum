# サポーターサブスクリプション（投げ銭）設計判断ドラフト — 決着した節

> **アーカイブ（現役運用では参照しない）。**[docs/supporter-subscription-plan.md](../supporter-subscription-plan.md) から、決着して経緯になった節を移した（2026-11-28・`/doc-maintenance`）。**決定の正本は本体の「決定事項（2026-05-20 確定）」**で、ここに残る「推奨」「要決定」「次アクション」は当時の下書き。節の名前（A-0〜A-4・B-1〜B-3・D-2・D-3・E-0〜E-7）は本体と同じにしてある。

## A. 長納期の事務手続き（決定不要・午後そのまま実行）

実装より先に走らせる必要のあるボトルネック。pooza さんの作業項目。
**この節は「読めばそのまま着手できる」状態を目標に展開。**

### A-0. 事前に手元に揃える物（着手前チェックリスト）

| 必要物 | 用途 | 備考 |
|---|---|---|
| 屋号・氏名（個人事業主名義） | 契約者情報 | 法人化は不要（docs/CLAUDE.md 記載済み） |
| 法定住所・電話番号 | 契約者情報 / 特商法表記にも流用 | |
| 銀行口座情報（支店・口座番号・SWIFT/BIC） | 売上入金先 | Apple は SWIFT/BIC を要求する場合あり。海外送金対応口座が無難 |
| マイナンバー or 個人事業の税情報 | 国内税務 | |
| 米国向け税務フォーム情報 | W-8BEN（個人）の記入内容 | 居住地・外国 TIN（不要な場合あり）・条約特典 |

→ **A-0 を午前のうちに揃えておけば、午後は登録作業に直行できる。**

### A-1. App Store Connect: 有料 App 契約

1. App Store Connect → **契約/税金/口座情報（「ビジネス」ページ）**
2. 「有料 App（Paid Apps）」契約の **同意（Request/Accept）**
3. **税務情報**: **米国 W-8BEN 相当のみ**（個人で可）。**日本の税フォームは存在しない**（探さなくてよい）。App Store の日本売上の消費税 JCT は Apple がマーケットプレイスとして処理＝開発者の記入項目なし。表示される税フォームは「源泉徴収のある国（米国・ブラジル・メキシコ等）」だけで、米国 W-8BEN だけが必須、他は任意/対象外でスルー可
4. **銀行口座**: 入金先を登録（A-0 の口座情報）
5. ステータスが「有効（Active）」になるまで待機（反映に時間差あり）。「ビジネス」ページで該当契約が有効＝要対応項目が無くなれば完了

※ 商品（サブスク SKU）の作成は B 確定後。ここでは契約・税・口座まで。

**実施記録（2026-05-19）**: 有料 App 契約 同意済み／米国 W-8BEN 提出済み（不変ステータス宣誓の年は新規プロファイルのため作成年を指定）／銀行口座 登録済み／ビジネスページ要対応項目なし＝**A-1 完了**。

### A-2. Google Play Console: 販売者登録

1. payments.google.com（または Play Console の支払い設定）→ **お支払いプロファイルを作成**
2. **アカウントの種類＝個人（Individual）** を選択（後から変更困難。全プラットフォーム主体を揃える）。選択した時点でプロファイルは作成される
3. プロファイル内「設定」で **税務情報** と **銀行口座** を登録
   - 税務情報: プロファイル設定内に出るのは **米国・台湾**のみ。**日本フォームは存在しない**（「税率」ページは別物＝買い手課税設定なので触らない）。**米国の税務情報のみ完了**させる（W-8BEN 相当。非米国＝日本居住の個人。不変ステータス宣誓の年はデフォルト過去年でなく該当年を指定）。台湾は対象外でスルー
   - 銀行口座: 登録後 Google 審査（数日）
4. 銀行審査通過 → お支払いプロファイル/販売者アカウントが「有効」になるまで待機

※ アプリ内課金商品の作成は B 確定後。

**実施記録（2026-05-19）**: お支払いプロファイル作成済み（種類＝個人）／米国税務情報 提出済み／日本・台湾フォーム無し（正常）／銀行口座 登録済み・**審査中**＝有効化待ち（こちらの入力作業は完了、残りは Google 審査待ちのみ）。

### A-3. 着手判断

→ **判断事項 A-1**: 上記を午後に実行するか？（推奨: する。最長納期のため）
画面 UI は変わり得るので、文言が手順と違う場合はその場のラベルに読み替え。詰まったら都度質問。


### A-4. A 実施で判明した B/C への制約フラグ（2026-05-19）の 2〜4

（1 の JCT は本体に残した）

2. **特商法表記が Play Console でも必須**: 日本の消費者に有料/IAP を出す場合、事業者の氏名・電話番号・住所の表示義務。→ **C-1/C-3** に直結。主体を「個人」で出すと本名・住所・電話の開示が必要。
3. **主体は現状 個人で全プラットフォーム統一**: Apple＝個人 / コード署名証明書＝IV（個人）/ MS＝個人 / Google＝個人。**法人（ビーショック）への移行は将来課題**（移行時は全ストア同時の付け替えが要るため B-4 はストア非依存設計に寄せると手戻りが少ない）。
4. **Windows 有料化の動機**: OV 証明書（#534）のコスト回収。ただし MS Store 課金は #544（無料版の Store 公開）解決が前提で、直配 MSIX では Store Commerce 不可。**MS は #544 待ちで A と並走不能**＝B では「将来 MS 展開」を見越し B-4 をストア非依存に。

---

## B. 商品設計（要決定）

### B-1. 課金形態

| 選択肢 | 内容 | ストア審査リスク |
|---|---|---|
| (a) サブスクのみ | 月額の継続課金のみ | 低（継続性で trivial 回避しやすい） |
| (b) 都度課金（消耗型）のみ | 「マトンカレーをおごる」的な単発 | 中〜高（純粋投げ銭は trivial 判定の先例あり） |
| (c) サブスク＋単発の併用 | 両方提供 | 低〜中（実装コスト増） |

推奨: **(a) サブスクのみ**でまず開始。単発は需要を見て後追い。

### B-2. 階層と金額

| 選択肢 | 例 |
|---|---|
| (a) 3 階層 | 月額 $1 / $3 / $5 |
| (b) 2 階層 | 月額 $2 / $5 |
| (c) 1 階層のみ | 月額 $3 |

推奨: **(a) 3 階層**。金額の絶対値より「複数階層＋継続」が審査対策上有効。
要決定: 通貨基準（USD 基準にするか、日本円 ¥ 基準にするか）。

### B-3. サポーター特典の範囲

機能差別化なしの方針は確定（docs/CLAUDE.md）。視覚フィードバックの範囲のみ要決定。

| 選択肢 | 内容 |
|---|---|
| (a) プロフィールにサポーターバッジ表示（自分のみ可視） | 最小。実装軽量 |
| (b) (a) ＋アプリ内の装飾（テーマ色・アイコン等） | 中 |
| (c) サーバー側に状態を持ち他者にも可視 | 重（リレー連携・なりすまし対策が必要） |

推奨: **(a)** から開始。(c) は要望が出てから検討（プライバシー・偽装耐性の設計が別途必要）。


### D-2. プラグイン

公式 [`in_app_purchase`](https://pub.dev/packages/in_app_purchase)（iOS
StoreKit / Android Play Billing の consumable を統一 API で扱える）を採用。
現状 pubspec 未導入のため追加する。abstraction 層の内側に閉じ込め、UI から
直接は触らせない。

### D-3. commit 分割と着手順（#428 を umbrella、commit は概念ごと）

大更新 単独配置のため #428 を tracking issue とし、sub-issue は作らず
[コミットの分割方針](../CLAUDE.md)に従って概念ごとに分割する。

1. `SupporterStatus` 抽象層 + ローカル永続化（shared_preferences の
   「投げ銭済み」フラグ）+ Riverpod provider。UI 非依存で先行
2. `in_app_purchase` 導入 + 消耗型 3 SKU 定義（`supporter.tip.small`
   `.medium` `.big`）+ 購入フロー（pending / 成功で flag 立て / 失敗
   ハンドリング / Android consume で再投げ銭可能に）+ Sentry 計装
3. 投げ銭画面 UI（3 金額・「サポーターになる / 投げ銭」導線）+ 設定 or
   Drawer からのエントリポイント。用語は[用語統一](../CLAUDE.md)準拠
4. サポーターバッジ UI（自プロフィール恒久表示・装飾のみ）
5. 特商法表記リンク（capsicum-site の法人名義ページへ）+ C-2 審査文言の
   反映 + リリース前レビュー対象に追加

各段は単体で動作確認可能な粒度。1 が UI 非依存なので最初に土台を固め、
2 以降を順に積む。サーバー側保持（B-4 後日対応）は 1 の抽象層の内側に
移行経路を残すだけで v1.27 では未実装。

---

## 次アクション

1. ~~pooza さん: A-1（事務手続き着手）の判断~~ → A 完了（2026-05-20）
2. ~~pooza さん: B-1〜B-4・C-1 の選択~~ → 確定（2026-05-20、「決定事項」節）
3. Claude: #428 にスコープ反映（コメント） → D の実装計画を Issue 化／着手
4. pooza さん: ストア側で消耗型 IAP 3 SKU を作成（商品メタデータ・税区分）、
   capsicum-site に法人名義の特商法表記を設置

---

## E. Windows IAP 設計（#599）— decision draft

iOS / Android / macOS（D-1）に続く Windows の投げ銭購入導線の設計叩き台。
**B/C（商品設計・法務）は全プラットフォーム共通で確定済み（上記）を流用**し、
Windows 固有の技術差分と意思決定だけをここに展開する。実装スコープが固まったら
#599 に反映する。

### E-0. 現状と着手ブロッカー（= 設計を先行する理由）

実装は**まだ着手できない**。コードに触れない設計だけ先行する（他端末の作業と
コンフリクトしない）。ブロッカーは 2 つ:

1. **Partner Center で消耗型アドオン 3 つが未登録**（pooza 作業・E-5）。商品 ID が
   確定しないと購入フローを実機検証できない。
2. **Store 配布版でしか IAP を検証できない**（E-2）。`Windows.Services.Store` は
   Microsoft Store リスティングに紐づくため、GitHub 直配の自己署名 MSIX や debug
   ビルドでは購入経路が成立しない。検証は **MS Store の非公開フライト/グループ配布**
   が要る＝ネイティブ push（#474）と同じ「内部ベータ経由検証」ルール
   （MEMORY `feedback_native_change_via_internal_beta`）に乗る。

### E-1. 課金プラグイン方式

公式 [`in_app_purchase`](https://pub.dev/packages/in_app_purchase) には **Windows
federation が存在しない**（iOS StoreKit / Android Play Billing / macOS StoreKit のみ）。
よって `SupporterPurchaseNotifier`（`InAppPurchase.instance` 直叩き）は Windows で
そのまま使えず、`isAvailable()` 取得時点でプラグインが落ちる。

| 選択肢 | 内容 | 評価 |
|---|---|---|
| (a) 自前 platform channel | `Windows.Services.Store`（`StoreContext`）を runner の MethodChannel で薄く叩く（SMTC / WNS と同じ流儀） | **推奨**。消耗型 3 商品の取得・購入・消費報告のみで surface が小さい |
| (b) コミュニティ製プラグイン採用 | 既存の Windows IAP プラグインがあれば利用 | 成熟度・保守性が不確実。要調査だが現状有力なものは確認できていない |

推奨: **(a) 自前 channel**。必要 API は `StoreContext.GetDefault()` →
`GetStoreProductsAsync(["Consumable"], productIds)` / `RequestPurchaseAsync(storeId)`
/ `ReportConsumableFulfillmentAsync`（E-4）の 3 つに限定できる。

### E-2. Store-install 判定と購入導線の可視性

`StoreContext` は **Microsoft Store からインストールされたコピーでのみ**機能し、
直配 MSIX は Store リスティングに紐づかず購入できない（#599 本文の非対称）。
現状の入口ガード `supporterPurchaseSupported`（[supporter_purchase_provider.dart](../../packages/capsicum/lib/src/provider/supporter_purchase_provider.dart)）は
`Platform.is*` のコンパイル時判定だが、Windows は **実行時に Store-install か**を
見分ける必要がある。

| 選択肢 | 入口の出し方 | 直配版の見え方 |
|---|---|---|
| (a) Store-install のみ入口表示 | 起動時に Store 判定 → Store 版だけ「capsicum をサポート」を出す | 直配版は非表示（= 現状の Linux/Win と同じ・混乱なし） |
| (b) 常に入口表示・runtime で degrade | Windows なら常に出し、`isAvailable=false` で「現在利用できません」に倒す | 直配版で空振り。理由が伝わらず不親切 |
| (c) (a) + 直配版に Store 誘導 | 直配版では購入導線でなく「Store 版で応援できます」リンクのみ | 親切だが導線追加。優先度低 |

推奨: **(a)**。判定方法は `StoreContext` で商品取得を試み、パッケージ ID 無し /
取得失敗を「Store 版でない」と扱うのが堅い（WNS Channel URI の noDeviceToken と
同じ握り）。`PackageSignatureKind == Store` でも判別できるが、フライト配布の扱いが
バージョン依存なので商品取得可否を一次情報にする。**(c) は要望が出たら追加**
（overridable）。

⚠⚠ **2026-10-10 に (b) へ切り替えた（pooza・[#1248](https://github.com/pooza/capsicum/issues/1248)）。**製品版 2.0.0 / 2.0.1 で商品の問い合わせの答えがアプリへ届かず（原因はネイティブ側で、同日に特定して直した）、(a) では入口が丸ごと消えた。入口を問い合わせの成否に繋ぐと、問い合わせが壊れた回に**読み直しの口（投げ銭画面の中）へも行けなくなる**。

- (b) を退けた理由（直配版での空振り）は、直配の公式案内をやめた時点（[#760](https://github.com/pooza/capsicum/issues/760)）でほぼ消えている。空振りが出るのは開発ビルドと手で入れた `.msix` だけ。
- 問い合わせは起動時ではなく、投げ銭画面を開いたときに走る。
- ⚠ **入口を再び問い合わせに繋がない。**繋ぐなら、問い合わせが返らない回の逃げ道を先に用意する。

### E-3. 抽象層への接続（UI 無改修を目標）

UI（[supporter_screen.dart](../../packages/capsicum/lib/src/ui/screen/settings/supporter_screen.dart)）は
`supporterPurchaseProvider` の `SupporterPurchaseState`（`isLoadingProducts` /
`isAvailable` / `products` / `buy` / `lastOutcome`）だけを見る。Windows backend が
**同じ state 形を produce**すれば画面は無改修で済む。

設計: 課金 backend を薄いインターフェースに切り出す。

- `InAppPurchaseBackend`（既存・iOS/Android/macOS、`in_app_purchase` ラップ）
- `WindowsStoreBackend`（新規・E-1 の platform channel ラップ）

`SupporterPurchaseNotifier` は `Platform.isWindows` で backend を選ぶだけにし、
**成功時は両 backend とも同じ `supporterStatusProvider.markTipped(sku)` を呼ぶ**
（[supporter_status_provider.dart](../../packages/capsicum/lib/src/provider/supporter_status_provider.dart)
の抽象層。ローカルフラグ + #596 サーバー同期はこの内側）。商品の見せ方は
`ProductDetails`（`id/title/description/price`）が公開コンストラクタを持つので、
Windows channel が返す商品メタから synthetic に組み立てれば `products` 型を保てる
（新モデル導入は不要）。バッジ UI は従来どおり `isSupporterProvider` 参照で
Windows でも自動表示される（既にローカルフラグがあれば desktop 表示済み）。

### E-4. 消耗型の消費報告（再投げ銭可能化）

MS Store の消耗型アドオンは購入後 `ReportConsumableFulfillmentAsync` で**消費報告**
しないと「未消費残高」が残り再購入できない（Android の autoConsume 相当）。Windows
backend は購入成立 → `markTipped` 永続化成功 → 消費報告、の順で確定させる。
**永続化失敗時は消費報告しない**（次回起動でストアが未処理購入を再配信し markTipped
を再試行できる。既存 `_onPurchaseUpdates` の `pendingCompletePurchase` と同じ思想）。

### E-5. Partner Center アドオン登録仕様（pooza 作業）

Microsoft Store パートナーセンターで**消耗型（Consumable）アドオンを 3 つ**作成する。
表示名・説明は既存 C-2c と同一文言で揃える（ストア横断で統一）。

**登録実績（2026-07-02、pooza 作業・登録済み）**: 3 商品とも下表の Product ID で登録。
種別は **開発者管理の消費型（developer-managed consumable）**を選択（残高管理なし・
購入ごとに `ReportConsumableFulfillmentAsync` で消費報告して再投げ銭可能化＝E-4 の設計
どおり。Store 管理は数量残高を持つ通貨型向けなので不採用）。コンテンツの種類は
**電子ソフトウェアのダウンロード（Electronic software download）**（MS 公式の「大半の
アドオンはこれ」ガイダンス準拠。配信物のない投げ銭も総合枠に収める）。個人情報の収集は
「使用しない」。価格帯は MS の最低帯が ¥120 のため small は ¥120、medium/big は ¥500/¥800
ちょうどが取れた。

**進捗（2026-07-02、pooza 作業）**: 税務／支払いプロファイル（銀行口座＋税務フォーム）の
**審査完了**（想定より早く通過。入金受け取りの前提もクリア）。これにより各アドオン商品の
審査提出が可能になり、**3 商品とも審査を提出済み（現在審査中・通過待ち）**。残るは
アドオン審査の通過のみで、その間に §E-6 のコード実装は先行できる（購入の E2E 検証は
審査通過＋ストア反映後）。

| アプリ内 SKU（既存） | MS Store Product ID（登録済み） | 価格（実登録） | 表示名 | 説明 |
|---|---|---|---|---|
| `supporter.tip.small` | `supporter.tip.small` | ¥120（MS 最低帯・¥100 相当枠） | ちょこっとサポート | capsicum の開発と通知リレー運用へのささやかな応援です。 |
| `supporter.tip.medium` | `supporter.tip.medium` | ¥500 | しっかりサポート | capsicum の開発と通知リレー運用へのしっかりした応援です。 |
| `supporter.tip.big` | `supporter.tip.big` | ¥800 | たっぷりサポート | capsicum の開発と通知リレー運用への大きな応援です。 |

- **Product ID をアプリ内 SKU と一致**させると `supporterTipProductIds` をそのまま
  使え分岐が減る（MS は Product ID に英数字ドットを許容）。不一致なら Windows backend
  に ID マッピング表を持たせる。
- MS Store は Apple/Google と価格帯テーブルが異なるため ¥100/¥500/¥800 に**最も近い
  価格帯**を選ぶ（厳密一致は不要・既存も「ストア換算」方針 B-2）。
- 税区分・年齢区分・IAP の申告は MS Store のフローに従う。特商法表記は C-3 の法人名義を
  capsicum-site のページへリンクで流用（新規作成不要）。

### E-6. 実装スコープ（B/C 確定後・E-5 完了後に着手）

D-3 の段階導入に倣い、概念ごとに commit 分割:

1. runner に `Windows.Services.Store` の platform channel（商品取得 / 購入 /
   消費報告 / Store-install 判定）。C++/WinRT、SMTC・WNS と同じ MTA ワーカー流儀。
2. Dart 側 `WindowsStoreBackend` + `SupporterPurchaseNotifier` の backend 切替。
   成功で `markTipped(sku)`。Sentry 計装は既存 fingerprint 規約に合わせる。
3. `supporterPurchaseSupported`（or その runtime 版）に Windows + Store-install
   判定を追加し入口を解放（E-2 (a)）。UI は無改修を確認。
4. MS Store 非公開フライトで内部ベータ検証（購入 → バッジ → 再投げ銭）→ 製品版昇格。

**着手可否そのものの判断**（#599 の主旨）: 自前 channel 実装コスト + 配布経路の
非対称（Store 版のみ）を許容して進めるか。推奨は **E-1(a)/E-2(a) で薄く実装**だが、
母数（Store 版利用者）が読めないうちは優先度低のまま、native push（#474）の片付き
具合を見て着手時期を判断する。

### E-7. 未決事項（pooza 判断待ち）

1. **E-2**: 入口可視性は (a) Store-install のみ表示 / (c) 直配版に Store 誘導も付ける、
   どちらにするか（推奨 (a)）。
2. **E-5**: MS Store Product ID をアプリ内 SKU と一致させるか（推奨：一致）。価格帯の
   最終選択。
3. **着手 GO/保留**: native push（#474）と同じ v1.40 主役群に入れるか、優先度低のまま
   後ろのマイルストーンへ置くか。
