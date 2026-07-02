#ifndef RUNNER_WINDOWS_STORE_IAP_H_
#define RUNNER_WINDOWS_STORE_IAP_H_

#include <flutter/encodable_value.h>
#include <windows.h>

#include <string>
#include <vector>

// Windows.Services.Store を薄く叩く投げ銭 (サポーター) IAP の platform channel
// 部品 (#599 / plan §E-6-1)。SMTC (#466/#484) や WNS (#474) と同じく WinRT を
// runner に閉じ、Dart 側 WindowsStoreBackend が 'capsicum/store_iap' チャンネル
// 経由でここを呼ぶ。
//
// いずれの関数も WinRT の IAsyncOperation を .get() で blocking 待ちするため、
// STA な UI スレッドから直接呼ばず、専用の MTA ワーカースレッド上で実行する前提
// (呼び出し側 flutter_window.cpp が apartment 初期化とスレッド marshal を担う)。

// 消耗型アドオン (developer-managed / "UnmanagedConsumable") の商品情報を取得する。
// アプリに紐づく add-on を列挙し、|product_ids| (アプリ内 SKU = InAppOfferToken)
// に一致するものだけ返す。
//
// 戻り値は flutter::EncodableMap:
//   - "isStoreVersion" : bool  (Store からインストールされ課金経路が成立するか)
//   - "products"       : EncodableList<EncodableMap>  各要素は
//       { "productId", "storeId", "title", "description", "formattedPrice" }
// StoreContext 取得不可 / 取得失敗時は isStoreVersion=false・products 空。
flutter::EncodableValue QueryStoreProducts(
    const std::vector<std::string>& product_ids);

// |store_id| (StoreProduct.StoreId) の商品を購入する。RequestPurchaseAsync は
// Win32 デスクトップではモーダルダイアログを出すため、|hwnd| に親付けしてから
// 購入する (IInitializeWithWindow)。
//
// 戻り値は flutter::EncodableMap { "status": int }。int は
// StorePurchaseStatus (Succeeded=0 / AlreadyPurchased=1 / NotPurchased=2 /
// NetworkError=3 / ServerError=4)。
flutter::EncodableValue RequestStorePurchase(HWND hwnd,
                                             const std::string& store_id);

// |store_id| の消耗型購入を「消費済み」として報告し再購入可能に戻す
// (plan §E-4)。developer-managed のため quantity=1・trackingId は都度生成。
//
// 戻り値は flutter::EncodableMap { "status": int }。int は
// StoreConsumableStatus (Succeeded=0 / InsufficentQuantity=1 / NetworkError=2 /
// ServerError=3)。
flutter::EncodableValue ReportStoreConsumable(const std::string& store_id);

#endif  // RUNNER_WINDOWS_STORE_IAP_H_
