#include "windows_store_iap.h"

#include <objbase.h>
#include <shobjidl_core.h>

#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Services.Store.h>

#include <set>

namespace {

using winrt::Windows::Services::Store::StoreConsumableResult;
using winrt::Windows::Services::Store::StoreContext;
using winrt::Windows::Services::Store::StoreProduct;
using winrt::Windows::Services::Store::StoreProductQueryResult;
using winrt::Windows::Services::Store::StorePurchaseResult;
using winrt::Windows::Services::Store::StorePurchaseStatus;

// アプリに紐づく add-on を列挙する際の商品種別フィルタ。pooza が登録した投げ銭 3
// 商品は開発者管理の消費型 = "UnmanagedConsumable"。将来 Store 管理型に変えても
// 取りこぼさないよう "Consumable" も併記する (どちらも下流で SKU 一致のみ通す)。
winrt::Windows::Foundation::Collections::IIterable<winrt::hstring>
ConsumableKinds() {
  return winrt::single_threaded_vector<winrt::hstring>(
      {L"UnmanagedConsumable", L"Consumable"});
}

flutter::EncodableMap StatusMap(int32_t status) {
  flutter::EncodableMap out;
  out[flutter::EncodableValue("status")] = flutter::EncodableValue(status);
  return out;
}

}  // namespace

flutter::EncodableValue QueryStoreProducts(
    const std::vector<std::string>& product_ids) {
  flutter::EncodableMap out;
  flutter::EncodableList products;

  StoreContext context = StoreContext::GetDefault();
  if (!context) {
    // StoreContext を取れない = 課金経路が成立しない (非 Store / 未パッケージ)。
    out[flutter::EncodableValue("isStoreVersion")] =
        flutter::EncodableValue(false);
    out[flutter::EncodableValue("products")] =
        flutter::EncodableValue(products);
    return flutter::EncodableValue(out);
  }

  StoreProductQueryResult result =
      context.GetAssociatedStoreProductsAsync(ConsumableKinds()).get();
  // ExtendedError が立つのは「Store 版でない」「ライセンス不正」「通信失敗」等。
  // plan §E-2(a) に従い、取得できなければ Store 版でない扱いにして入口を出さない
  // (一過性の通信失敗でも一旦隠れるが、次回問い合わせ/再起動で復帰する)。
  if (static_cast<int32_t>(result.ExtendedError()) != 0) {
    out[flutter::EncodableValue("isStoreVersion")] =
        flutter::EncodableValue(false);
    out[flutter::EncodableValue("products")] =
        flutter::EncodableValue(products);
    return flutter::EncodableValue(out);
  }

  const std::set<std::string> wanted(product_ids.begin(), product_ids.end());
  for (const auto& kv : result.Products()) {
    StoreProduct product = kv.Value();
    std::string token = winrt::to_string(product.InAppOfferToken());
    // 投げ銭 SKU 以外の add-on が将来増えても混ざらないよう明示的に絞る。
    if (wanted.find(token) == wanted.end()) {
      continue;
    }
    flutter::EncodableMap p;
    p[flutter::EncodableValue("productId")] = flutter::EncodableValue(token);
    p[flutter::EncodableValue("storeId")] =
        flutter::EncodableValue(winrt::to_string(product.StoreId()));
    p[flutter::EncodableValue("title")] =
        flutter::EncodableValue(winrt::to_string(product.Title()));
    p[flutter::EncodableValue("description")] =
        flutter::EncodableValue(winrt::to_string(product.Description()));
    p[flutter::EncodableValue("formattedPrice")] =
        flutter::EncodableValue(winrt::to_string(product.Price().FormattedPrice()));
    products.push_back(flutter::EncodableValue(p));
  }

  out[flutter::EncodableValue("isStoreVersion")] =
      flutter::EncodableValue(true);
  out[flutter::EncodableValue("products")] = flutter::EncodableValue(products);
  return flutter::EncodableValue(out);
}

flutter::EncodableValue RequestStorePurchase(HWND hwnd,
                                             const std::string& store_id) {
  StoreContext context = StoreContext::GetDefault();
  if (!context) {
    return flutter::EncodableValue(
        StatusMap(static_cast<int32_t>(StorePurchaseStatus::NetworkError)));
  }

  // RequestPurchaseAsync のダイアログは Win32 デスクトップではアプリの HWND に
  // 親付けが要る (未設定だと例外)。ダイアログのメッセージポンプは UI スレッドが
  // 回すため、本関数を回す MTA ワーカーで .get() ブロックしても UI は塞がない。
  auto init = context.as<::IInitializeWithWindow>();
  init->Initialize(hwnd);

  StorePurchaseResult result =
      context.RequestPurchaseAsync(winrt::to_hstring(store_id)).get();
  return flutter::EncodableValue(
      StatusMap(static_cast<int32_t>(result.Status())));
}

flutter::EncodableValue ReportStoreConsumable(const std::string& store_id) {
  StoreContext context = StoreContext::GetDefault();
  if (!context) {
    // StoreConsumableStatus::NetworkError = 2。
    return flutter::EncodableValue(StatusMap(2));
  }

  GUID guid{};
  CoCreateGuid(&guid);
  StoreConsumableResult result =
      context
          .ReportConsumableFulfillmentAsync(winrt::to_hstring(store_id), 1,
                                            winrt::guid(guid))
          .get();
  return flutter::EncodableValue(
      StatusMap(static_cast<int32_t>(result.Status())));
}
