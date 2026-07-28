# Windows 投げ銭（Microsoft Store IAP）設計（#599）

> **アーカイブ（現役運用では参照しない）**。#599 は v1.43.0（2026-07-02）で出荷完了。正本はコードと [store-release-guide.md](../store-release-guide.md)。以下は設計判断の経緯記録。

## 位置付け

[#428](https://github.com/pooza/capsicum/issues/428)（投げ銭）の Windows 横展開。iOS / Android（v1.27）→ macOS（[#598](https://github.com/pooza/capsicum/issues/598), v1.36）に続く 4 プラットフォーム目。

macOS（#598）は **既存 StoreKit 系統（`in_app_purchase` + `in_app_purchase_storekit`）の解放だけ**で済んだ。iOS と Universal Purchase（同一 App レコード）で消耗型 3 商品を共有できたため、コードは `supporterPurchaseSupported` に `Platform.isMacOS` を足すだけだった。

Windows は事情が違う:

- `in_app_purchase` プラグインに **Windows 実装が無い**（[flutter/flutter#97050](https://github.com/flutter/flutter/issues/97050) が 2022 年から open）。`Windows.Services.Store`（`StoreContext`）を **C++/WinRT メソッドチャネルで叩く自前実装**が要る（[#484](https://github.com/pooza/capsicum/issues/484) Windows SMTC で確立した経路の延長）
- **Microsoft Store 紐付けインストールのコピーのみ購入可能**。GitHub Releases の自己署名 MSIX 直配コピーは Store リスティングと紐づかず購入できない → 「投げ銭が使えるのは Store 版のみ」という **配布経路ごとの非対称**を実装で吸収する必要がある

本書はこの 2 点を踏まえ、(1) 購入バックエンドの抽象化方式、(2) WinRT チャネルの API 形、(3) Store 版判定の置き場所 を確定する。

## 現状コードの結合点

[`supporter_purchase_provider.dart`](../../packages/capsicum/lib/src/provider/supporter_purchase_provider.dart) の `SupporterPurchaseNotifier` が `InAppPurchase.instance` を**直接**参照している:

- `build()` で `purchaseStream.listen` を張る
- `loadProducts()` で `isAvailable()` + `queryProductDetails()`
- `buy()` で `buyConsumable()`
- `_onPurchaseUpdates()` で `PurchaseStatus` を捌き、成功時 `markTipped()` → `completePurchase()`

`in_app_purchase` の app-facing API は **非対応 OS で `InAppPurchase.instance` を触った瞬間に落ちる**ため、Windows ビルドでこのクラスをそのまま走らせることはできない。よって抽象化は「設計の好み」ではなく**必須**。

`SupporterStatusNotifier`（`markTipped` / #596 サーバー同期）より**下**の層だけを差し替える。`markTipped` から先（ローカル保存・relay 同期・バッジ）は購入手段に非依存なので **一切変更しない**。

## 設計判断 1: 購入バックエンドの抽象化

`SupporterPurchaseNotifier` の状態機械（`purchaseInProgress` 固着防止・永続化失敗時は `completePurchase` を呼ばず再配信に委ねる・等）は**プラットフォーム非依存の資産**として残す。差し替えるのは「ストアと話す部分」だけ。

```
SupporterPurchaseNotifier  ← 状態機械（不変）
        │ 参照
        ▼
SupporterPurchaseBackend   ← 新インターフェース
    ├─ InAppPurchaseBackend   (iOS / Android / macOS) … 既存ロジックを移設
    └─ WindowsStoreBackend    (Windows)               … WinRT チャネル
```

### バックエンド・インターフェース

```dart
abstract class SupporterPurchaseBackend {
  /// ストア課金が利用可能か（非対応 OS / ストア不通 / 配布経路不適合なら false）。
  Future<PurchaseAvailability> checkAvailability();

  /// 商品情報を取得（順序は呼び出し側が定義順に整える）。
  Future<List<NormalizedProduct>> queryProducts(List<String> ids);

  /// 購入更新ストリーム。Windows は request/response を内部で
  /// このストリームに正規化して流す（下記）。
  Stream<List<NormalizedPurchase>> get purchaseStream;

  /// 消耗型として購入する。
  Future<void> buy(NormalizedProduct product);

  /// ストアトランザクションを完了/消費する
  /// （StoreKit/Play: completePurchase、Windows: ReportConsumableFulfillment）。
  Future<void> complete(NormalizedPurchase purchase);

  void dispose();
}
```

正規化型（プラグインの `ProductDetails` / WinRT の `StoreProduct` を吸収）:

```dart
class NormalizedProduct {
  final String id;        // supporter.tip.small 等
  final String title;     // ストア表示名
  final String price;     // ローカライズ済み価格文字列（コードに金額を持たない）
  final Object raw;       // backend 内部用（ProductDetails / storeId 等）
}

enum NormalizedPurchaseStatus { pending, purchased, canceled, error }

class NormalizedPurchase {
  final String productId;
  final NormalizedPurchaseStatus status;
  final String? errorCode;
  final bool pendingComplete;
  final Object raw;       // completePurchase / 消費に必要な元オブジェクト
}
```

`PurchaseAvailability` は単なる bool でなく **理由つき**にする（下記「判定の置き場所」で UI 文言の出し分けに使う）:

```dart
enum PurchaseAvailability {
  available,
  unavailable,            // ストア不通・商品取得不可（既存の汎用メッセージ）
  unsupportedDistribution // Windows 自己署名直配版（Store 版へ誘導）
}
```

### 注入点

`supporterStatusStoreProvider` と同じく Provider で差し替え可能にする（テストで fake バックエンドを override）:

```dart
final supporterPurchaseBackendProvider = Provider<SupporterPurchaseBackend>(
  (ref) {
    if (Platform.isWindows) return WindowsStoreBackend();
    if (Platform.isIOS || Platform.isAndroid || Platform.isMacOS) {
      return InAppPurchaseBackend();
    }
    return const UnsupportedPurchaseBackend(); // Linux 等
  },
);
```

`in_app_purchase` の `import` は `InAppPurchaseBackend` のファイル内に閉じ込める。Windows ビルドでは `WindowsStoreBackend` のみ生成され、`InAppPurchase.instance` には**到達しない**。

### Windows の request/response をストリームに正規化

`in_app_purchase`（StoreKit/Play）は購入結果が `purchaseStream` 経由で**後から**届く（アプリ再起動後の再配信もある）。一方 WinRT の `StoreContext.RequestPurchaseAsync(storeId)` は**その場で結果を返す** request/response モデル。

両者を `Notifier` 側で分岐させないため、`WindowsStoreBackend` は内部に `StreamController` を持ち、`buy()` で `purchase` チャネルを叩いて返ってきた結果を**自前ストリームに push** する。これで `Notifier` の状態機械（ストリーム購読前提）は無改造で両モデルに乗る。

> 注: Windows Store の消耗型は「未消費の購入が残っていると同一商品を再購入できない」。`complete()`（= `ReportConsumableFulfillmentAsync`）を確実に呼ぶ。永続化失敗時に `complete` をスキップして再配信に委ねる既存パターンは Windows では効かない（再配信ストリームが無い）ため、`WindowsStoreBackend` は **アプリ起動時に未消費購入を `GetUserCollectionAsync` で回収して消費**する補償経路を持つ（StoreKit の「未完了トランザクション再配信」に相当）。

## 設計判断 2: WinRT メソッドチャネルの API 形

チャネル名 `capsicum/store_billing`（SMTC の `capsicum/now_playing` と同じ命名）。ネイティブ実装は `windows/runner/store_billing.{h,cpp}`、登録は [`flutter_window.cpp`](../../packages/capsicum/windows/runner/flutter_window.cpp)（SMTC と同じ箇所）。

| method | 引数 | 戻り | WinRT |
|--------|------|------|-------|
| `isStoreInstalled` | — | `bool` | `Package::Current().SignatureKind() == Store` |
| `isAvailable` | — | `bool` | `StoreContext` 取得可 + ライセンス active |
| `queryProducts` | `{ids: [String]}` | `[{id, title, price}]` | `GetAssociatedStoreProductsAsync({"Consumable"})` を `InAppOfferToken` で突き合わせ |
| `purchase` | `{id: String}` | `{status, errorCode?}` | `RequestPurchaseAsync(storeId)` |
| `reportConsumed` | `{id, trackingId}` | `bool` | `ReportConsumableFulfillmentAsync` |
| `pendingConsumables` | — | `[{id, quantity}]` | `GetUserCollectionAsync({"Consumable"})` |

実装上の肝（#484 SMTC で得た知見の再利用 + 追加分）:

- **スレッド**: メソッドチャネルのハンドラは UI（STA）スレッド。WinRT の `.get()` を STA でブロックすると停止しうるため、SMTC と同様 **MTA 専用スレッド**で実行しタイムアウト付き `future` で待つ（[`smtc_now_playing.cpp`](../../packages/capsicum/windows/runner/smtc_now_playing.cpp) の `GetCurrentNowPlaying` パターンを踏襲）
- **HWND 受け渡し（Win32 固有・新規）**: `StoreContext::GetDefault()` を Win32 デスクトップで使うには `IInitializeWithWindow::Initialize(hwnd)` で**所有ウィンドウを渡す**手順が要る（購入ダイアログの親にするため）。HWND は runner が持っている（`GetHandle()` / `FlutterWindow` 経由）。`store_billing` 初期化時に HWND を注入する
- **商品 ID マッピング**: Windows のアドオンは `StoreId`（不透明 ID）と `InAppOfferToken`（Partner Center で設定する開発者向け文字列）を持つ。`supporter.tip.small/medium/big` を **各アドオンの InAppOfferToken に設定**し、Dart 側 ID と 1:1 対応させる。`purchase` は `InAppOfferToken → StoreId` 解決を挟む
- **価格**: `StoreProduct.Price().FormattedPrice()` を返す。コードに金額を持たない既存方針を維持

## 設計判断 3: Store 版判定の置き場所

判定は **2 層**にする:

1. **静的ゲート** `supporterPurchaseSupported`（[supporter_purchase_provider.dart:29](../../packages/capsicum/lib/src/provider/supporter_purchase_provider.dart)）に `|| Platform.isWindows` を追加。「このプラットフォームは原理的に対応しうる」までを表す
2. **実行時の配布経路判定**は `WindowsStoreBackend.checkAvailability()` 内で `isStoreInstalled` を見て決める。自己署名直配版なら `PurchaseAvailability.unsupportedDistribution` を返す

UI（[supporter_screen.dart](../../packages/capsicum/lib/src/ui/screen/settings/supporter_screen.dart) `_buildPurchaseSection`）は `PurchaseAvailability` で文言を出し分ける:

- `available` … 商品リスト
- `unavailable` … 既存の「ただいま投げ銭をご利用いただけません…」
- `unsupportedDistribution` … **新規**「この配布版（自己署名直配）では投げ銭をご利用いただけません。Microsoft Store 版からご利用ください。」

> `Notifier` の `SupporterPurchaseState` に bool でなく `PurchaseAvailability` を持たせる小改修が要る（`isAvailable` フィールドを enum に拡張、または並置）。既存の `isAvailable` 参照箇所は限定的なので置換でよい。

## Partner Center 作業（pooza さん手動）

毎リリースの Store publish と同じく Partner Center Web UI 運用。

- [ ] 消耗型（Consumable）アドオン **3 つ**を作成し、各 `InAppOfferToken` を `supporter.tip.small` / `supporter.tip.medium` / `supporter.tip.big` に設定
- [ ] 価格を ¥100 / ¥500 / ¥800 相当に設定（iOS/Android/macOS の階層と揃える）
- [ ] 各アドオンを公開（アプリ本体の Store リスティングに紐付く）

Dart 側 `supporterTipProductIds` は 4 プラットフォーム共通の論理 ID として流用する（Windows は InAppOfferToken に転写するだけ）。

## 検証経路の制約

- **ARM64 Windows ではローカル x64 ビルドが通らない**（ATL / jni / crashpad の x64-on-ARM64）。検証は CI `windows-release.yml` の `capsicum-msix` artifact を `gh run download` → 導入する既存経路（#484 / [reference_windows_local_verification](../../packages/capsicum) 参照）
- **IAP は Store 紐付けインストールでしか動かない**。`Add-AppxPackage` での直導入は SignatureKind=Developer になり `unsupportedDistribution` 扱い。実購入フロー検証は **Partner Center の sandbox（Store 経由の内部テスト / Package flights）** が要る。TestFlight / Play 内部テストに相当する軽い経路が無いのが Windows の難点で、毎イテレーションが Store 提出に縛られる
- ストア提出前に `isStoreInstalled=false`（直配版）で `unsupportedDistribution` UI が正しく出ることだけは MSIX artifact でローカル確認できる

## スコープと非目標

- 本件は **Microsoft Store 版限定**の投げ銭解放。自己署名直配版は明示的に非対応（UI で Store 版へ誘導）
- 外部ユーザー向け有償リレー（[#597](https://github.com/pooza/capsicum/issues/597)）の SKU 統合は別件。`supporter.*` 前方互換命名は維持するが本設計では扱わない
- サブスク型は導入しない（既存どおり消耗型のみ）

## 作業順序（案）

1. **Dart 抽象層**: `SupporterPurchaseBackend` + `NormalizedProduct/Purchase` + `InAppPurchaseBackend`（既存ロジック移設）+ `supporterPurchaseBackendProvider`。`Notifier` を backend 参照に書き換え。**この時点で iOS/Android/macOS が無回帰**であることをテストで担保（既存 `supporter_purchase_state_test` を backend fake に寄せる）
2. **UI**: `PurchaseAvailability` 3 値化 + `unsupportedDistribution` 文言
3. **ネイティブ**: `store_billing.{h,cpp}` + `flutter_window.cpp` 登録 + HWND 注入。`WindowsStoreBackend`（チャネル + ストリーム正規化 + 未消費回収）
4. **Partner Center**: アドオン 3 つ登録（pooza さん）
5. **検証**: 直配版で `unsupportedDistribution` UI → Store sandbox で実購入フロー

## 未決事項

- Windows のマイルストーン割り当て（現状 v1.36 だが、ネイティブ実装 + Store sandbox 検証のコストを踏まえ独立項目として後ろのマイルストーンに切り出すか要判断）
- Store sandbox（Package flights / 内部テスト）で消耗型購入をテストする具体手順の確立（前例なし）
- `RequestPurchaseAsync` のキャンセル / ネットワーク失敗の `errorCode` 体系を Sentry fingerprint にどう正規化するか
