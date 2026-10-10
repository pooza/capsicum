#include "windows_store_iap.h"

#include <objbase.h>
#include <shobjidl_core.h>

#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Services.Store.h>

#include <chrono>
#include <set>

namespace {

using winrt::Windows::Foundation::AsyncStatus;
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

// 商品問い合わせの上限 (#1248)。Dart 側の時間切れ (15 秒) より短くして、
// 「ネイティブが返らない」と「Store が返らない」を Dart から見分けられるようにする。
constexpr std::chrono::seconds kQueryTimeout{10};

// 問い合わせが商品を返せなかった回の応答 (#1248)。⚠⚠ **どこで止まったかを必ず
// 返す。**以前は「取れなかった」を isStoreVersion=false の 1 種類に潰していて、
// 製品版で入口が出ない理由を外から読めなかった (Windows は内部ベータを配らない
// ので、1 回の出荷で切り分けが進む形にしておく)。
flutter::EncodableValue QueryFailure(
    const char* stage,
    int32_t hresult,
    std::chrono::steady_clock::time_point started) {
  flutter::EncodableMap out;
  out[flutter::EncodableValue("isStoreVersion")] =
      flutter::EncodableValue(false);
  out[flutter::EncodableValue("products")] =
      flutter::EncodableValue(flutter::EncodableList());
  out[flutter::EncodableValue("stage")] = flutter::EncodableValue(stage);
  out[flutter::EncodableValue("hresult")] = flutter::EncodableValue(hresult);
  out[flutter::EncodableValue("elapsedMs")] = flutter::EncodableValue(
      static_cast<int32_t>(
          std::chrono::duration_cast<std::chrono::milliseconds>(
              std::chrono::steady_clock::now() - started)
              .count()));
  return flutter::EncodableValue(out);
}

}  // namespace

flutter::EncodableValue QueryStoreProducts(
    HWND hwnd,
    const std::vector<std::string>& product_ids) {
  const auto started = std::chrono::steady_clock::now();
  flutter::EncodableMap out;
  flutter::EncodableList products;
  int32_t associated_count = 0;

  try {
    StoreContext context = StoreContext::GetDefault();
    if (!context) {
      // StoreContext を取れない = 課金経路が成立しない (非 Store / 未パッケージ)。
      return QueryFailure("no_context", 0, started);
    }

    // ⚠ **問い合わせの前にもウィンドウを渡す (#1248)。**Win32 デスクトップでは
    // StoreContext にアプリの HWND を結び付けるのが前提で、購入 (下の
    // RequestStorePurchase) では渡していたのに、問い合わせでは渡していなかった。
    // ⚠ 製品版で商品が出なかった原因はこれではない (渡さなくても 1 秒ほどで
    // 返ることを実測した。原因は flutter_window.cpp の window_alive)。作法として
    // 残す。渡せなくても問い合わせは試す (try_as / 戻り値を見ない) —— ここを
    // 必須にすると、いま通る環境を壊す。
    if (hwnd) {
      if (auto init = context.try_as<::IInitializeWithWindow>()) {
        init->Initialize(hwnd);
      }
    }

    // 🔴 **`.get()` で無期限に待たない (#1248)。**Store が返さない回に
    // ワーカーが塞がったままにならないよう、上限を切り、切れた回はその旨を返す。
    // ⚠ 製品版 2.0.0 / 2.0.1 で商品が出なかったのは、ここが返らなかったから
    // ではない (返った結果を flutter_window.cpp のワーカーが捨てていた)。
    auto operation = context.GetAssociatedStoreProductsAsync(ConsumableKinds());
    if (operation.wait_for(kQueryTimeout) == AsyncStatus::Started) {
      operation.Cancel();
      return QueryFailure("timeout", 0, started);
    }
    // 失敗で終わっていれば GetResults が例外を投げる (下の catch で拾う)。
    StoreProductQueryResult result = operation.GetResults();

    // ExtendedError が立つのは「Store 版でない」「ライセンス不正」「通信失敗」等。
    const int32_t extended_error = static_cast<int32_t>(result.ExtendedError());
    if (extended_error != 0) {
      return QueryFailure("extended_error", extended_error, started);
    }

    const std::set<std::string> wanted(product_ids.begin(), product_ids.end());
    for (const auto& kv : result.Products()) {
      ++associated_count;
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
      p[flutter::EncodableValue("formattedPrice")] = flutter::EncodableValue(
          winrt::to_string(product.Price().FormattedPrice()));
      products.push_back(flutter::EncodableValue(p));
    }
  } catch (const winrt::hresult_error& e) {
    return QueryFailure("exception", static_cast<int32_t>(e.code()), started);
  } catch (...) {
    return QueryFailure("exception", 0, started);
  }

  out[flutter::EncodableValue("isStoreVersion")] =
      flutter::EncodableValue(true);
  out[flutter::EncodableValue("products")] = flutter::EncodableValue(products);
  out[flutter::EncodableValue("stage")] = flutter::EncodableValue("ok");
  out[flutter::EncodableValue("hresult")] = flutter::EncodableValue(0);
  // ⚠ 絞る前の件数も返す。0 なら「アプリに add-on が紐づいていない」、
  // 1 以上で products が空なら「SKU の綴りが合っていない」と読み分けられる。
  out[flutter::EncodableValue("associatedCount")] =
      flutter::EncodableValue(associated_count);
  out[flutter::EncodableValue("elapsedMs")] = flutter::EncodableValue(
      static_cast<int32_t>(
          std::chrono::duration_cast<std::chrono::milliseconds>(
              std::chrono::steady_clock::now() - started)
              .count()));
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
