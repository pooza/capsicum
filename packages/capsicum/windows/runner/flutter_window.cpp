#include "flutter_window.h"

#include <flutter/method_call.h>
#include <flutter/method_result.h>
#include <flutter/standard_method_codec.h>

#include <winrt/Windows.Foundation.h>

#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include "flutter/generated_plugin_registrant.h"
#include "smtc_now_playing.h"
#include "windows_store_iap.h"
#include "wns_push.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // ナウプレ取得 (SMTC) のメソッドチャンネル (#466 / #484)。Dart 側の
  // SmtcNowPlayingProvider が 'getNowPlaying' を呼ぶ。
  now_playing_channel_ = std::make_unique<flutter::MethodChannel<>>(
      flutter_controller_->engine()->messenger(), "capsicum/now_playing",
      &flutter::StandardMethodCodec::GetInstance());
  now_playing_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<>& call,
         std::unique_ptr<flutter::MethodResult<>> result) {
        if (call.method_name() == "getNowPlaying") {
          result->Success(GetCurrentNowPlaying());
        } else {
          result->NotImplemented();
        }
      });

  // WNS push の Channel URI 取得チャンネル (#474 フェーズ1)。Dart 側
  // WnsService が 'requestChannelUri' を呼ぶ。WinRT の取得は STA で .get()
  // ブロックすると停止しうるため MTA ワーカーで実行し、UI スレッドを塞がない。
  // 取得完了後は WM_WNS_CHANNEL_READY を PostMessage し、MessageHandler が
  // UI スレッド上で 'onChannelUri' を InvokeMethod する。
  wns_channel_ = std::make_unique<flutter::MethodChannel<>>(
      flutter_controller_->engine()->messenger(), "capsicum/wns",
      &flutter::StandardMethodCodec::GetInstance());
  wns_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<>& call,
             std::unique_ptr<flutter::MethodResult<>> result) {
        if (call.method_name() == "requestChannelUri") {
          // 受信ワーカーは初回要求でのみ起動する (#763)。requestChannelUri は
          // 起動時に 1 度だけ呼ばれる想定だが、将来 URI 失効再取得などで複数回
          // 呼ばれても MTA スレッドと PushNotificationReceived 購読が多重化
          // しないよう一度きりに倒す。2 回目以降は URI 不変のため即 ack する
          // （初回取得時に onChannelUri で Dart へ渡し済み）。再取得を真に
          // サポートするときは stop イベントで旧購読を解除する設計へ拡張する。
          if (wns_receiver_started_.exchange(true)) {
            result->Success();
            return;
          }
          HWND hwnd = GetHandle();
          // 専用ワーカーで Channel URI 取得 + in-process 受信購読を回す
          // (#474 フェーズ1+3)。WinRT / 受信ロジックは wns_push に集約し、ここは
          // 取得した URI を UI スレッドへ marshal するコールバックだけ渡す。
          // RunWnsChannelReceiver は購読後プロセス終了までブロックするため、
          // スレッドは detach する。
          std::thread([this, hwnd]() {
            RunWnsChannelReceiver([this, hwnd](const std::string& uri) {
              {
                std::lock_guard<std::mutex> lock(wns_mutex_);
                wns_uri_ = uri;
              }
              if (hwnd) {
                PostMessage(hwnd, WM_WNS_CHANNEL_READY, 0, 0);
              }
            });
          }).detach();
          // 取得は非同期。要求受理だけ即 ack し、結果は onChannelUri で返す。
          result->Success();
        } else if (call.method_name() == "syncPushKeys") {
          // ログアウト・アカウント追加など鍵セット変更後に、LocalState の
          // push_keys.json を現在の鍵セットへ再同期する (#474 フェーズ C)。
          // これを怠るとバックグラウンドタスクがログアウト済みアカウントの
          // 古い鍵で復号・表示し続ける。DPAPI 復号 + ファイル I/O のため
          // detached スレッドで実行し UI を塞がない。要求受理だけ即 ack する。
          std::thread([]() { SyncWnsPushKeysToLocalState(); }).detach();
          result->Success();
        } else if (call.method_name() == "syncPushLabels") {
          // Dart（全ログイン中アカウントの reblog/post ラベル）が用意した
          // push_labels.json 内容を LocalState へ書く (#770)。bg task / in-process
          // 受信がアカウント別のカスタムラベル（リノート / リキュア！等）を読む。
          // ファイル I/O のため detached スレッドで実行し UI を塞がない。要求受理
          // だけ即 ack する。空文字列（ログイン中アカウント無し）なら削除される。
          std::string labels_json;
          if (const auto* s = std::get_if<std::string>(call.arguments())) {
            labels_json = *s;
          }
          std::thread([labels_json]() {
            SyncWnsPushLabelsToLocalState(labels_json);
          }).detach();
          result->Success();
        } else if (call.method_name() == "consumePushDiagnostics") {
          // バックグラウンドタスク (#474 フェーズ C) が LocalState に残した観測
          // レコードを 1 件読み出して返す（読んだら消す）。Dart 側が Sentry へ
          // 吸い上げる。レコードが無ければ null。
          std::string diag;
          if (ConsumePushDiagnosticsJson(&diag)) {
            result->Success(flutter::EncodableValue(diag));
          } else {
            result->Success();
          }
        } else {
          result->NotImplemented();
        }
      });

  // 投げ銭 (サポーター) IAP のチャンネル (#599 / plan §E-6-1)。Dart 側
  // WindowsStoreBackend が商品取得・購入・消費報告を呼ぶ。WinRT は STA でブロック
  // すると停止しうるため、いずれも MTA ワーカーで回して結果を UI スレッドへ返す。
  store_iap_channel_ = std::make_unique<flutter::MethodChannel<>>(
      flutter_controller_->engine()->messenger(), "capsicum/store_iap",
      &flutter::StandardMethodCodec::GetInstance());
  store_iap_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<>& call,
             std::unique_ptr<flutter::MethodResult<>> result) {
        const std::string& method = call.method_name();
        if (method == "queryProducts") {
          // args: EncodableList<String> のアプリ内 SKU。
          std::vector<std::string> ids;
          if (const auto* list =
                  std::get_if<flutter::EncodableList>(call.arguments())) {
            for (const auto& v : *list) {
              if (const auto* s = std::get_if<std::string>(&v)) {
                ids.push_back(*s);
              }
            }
          }
          DispatchStoreWork(std::move(result),
                            [ids]() { return QueryStoreProducts(ids); });
        } else if (method == "purchase" || method == "reportFulfillment") {
          // args: EncodableMap { "storeId": String }。
          std::string store_id;
          if (const auto* map =
                  std::get_if<flutter::EncodableMap>(call.arguments())) {
            auto it = map->find(flutter::EncodableValue("storeId"));
            if (it != map->end()) {
              if (const auto* s = std::get_if<std::string>(&it->second)) {
                store_id = *s;
              }
            }
          }
          if (store_id.empty()) {
            result->Error("bad_args", "storeId is required");
            return;
          }
          HWND hwnd = GetHandle();
          if (method == "purchase") {
            DispatchStoreWork(std::move(result), [hwnd, store_id]() {
              return RequestStorePurchase(hwnd, store_id);
            });
          } else {
            DispatchStoreWork(std::move(result), [store_id]() {
              return ReportStoreConsumable(store_id);
            });
          }
        } else {
          result->NotImplemented();
        }
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  // Store IAP ワーカーが結果を marshal する先の HWND を共有状態へ控える (#795)。
  // OnDestroy で nullptr にし、破棄後のワーカーが stale/recycle された HWND へ
  // PostMessage するのを防ぐ。
  {
    std::lock_guard<std::mutex> lock(store_state_->mutex);
    store_state_->hwnd = GetHandle();
  }

  return true;
}

void FlutterWindow::OnDestroy() {
  // Store IAP の in-flight ワーカー (購入ダイアログ待ちで数分ブロックしうる) が、
  // ウィンドウ破棄後に解放済みメンバや stale HWND を触らないよう、共有状態へ
  // 「ウィンドウ消滅」を通知する (#795)。以降ワーカーは結果を捨て PostMessage
  // しない。ワーカー自身は shared_ptr で状態を延命するので join 不要。
  {
    std::lock_guard<std::mutex> lock(store_state_->mutex);
    store_state_->window_alive = false;
    store_state_->hwnd = nullptr;
  }

  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    case WM_WNS_CHANNEL_READY: {
      // MTA ワーカーが取得した Channel URI を UI スレッド上で Dart へ返す
      // (#474 フェーズ1)。空文字列は「取得不可」として null を渡し、Dart 側で
      // noDeviceToken 扱いにする。
      std::string uri;
      {
        std::lock_guard<std::mutex> lock(wns_mutex_);
        uri = wns_uri_;
      }
      if (wns_channel_) {
        auto arg = uri.empty()
                       ? std::make_unique<flutter::EncodableValue>()
                       : std::make_unique<flutter::EncodableValue>(uri);
        wns_channel_->InvokeMethod("onChannelUri", std::move(arg));
      }
      return 0;
    }
    case WM_STORE_IAP_RESULT: {
      // MTA ワーカーが完了した Store IAP 呼び出しの結果を UI スレッドで Dart へ
      // 返す (#599)。id で保留中の MethodResult と結果値を取り出す。
      int id = static_cast<int>(wparam);
      std::shared_ptr<flutter::MethodResult<>> result;
      flutter::EncodableValue outcome;
      {
        std::lock_guard<std::mutex> lock(store_state_->mutex);
        auto rit = store_state_->pending.find(id);
        if (rit != store_state_->pending.end()) {
          result = rit->second;
          store_state_->pending.erase(rit);
        }
        auto oit = store_state_->outcomes.find(id);
        if (oit != store_state_->outcomes.end()) {
          outcome = std::move(oit->second);
          store_state_->outcomes.erase(oit);
        }
      }
      if (result) {
        if (std::holds_alternative<std::monostate>(outcome)) {
          // ワーカーが例外で null を書いた = WinRT 呼び出し自体が失敗。
          result->Error("store_error", "Windows.Services.Store call failed");
        } else {
          result->Success(outcome);
        }
      }
      return 0;
    }
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

void FlutterWindow::DispatchStoreWork(
    std::unique_ptr<flutter::MethodResult<>> result,
    std::function<flutter::EncodableValue()> work) {
  // 共有状態を shared_ptr でワーカーへ渡す (#795)。ワーカーは FlutterWindow より
  // 長生きしうる (購入ダイアログのブロック中にウィンドウが破棄される) ため、
  // this ではなく state 経由で mutex / map / HWND を触る。
  auto state = store_state_;
  int id;
  {
    std::lock_guard<std::mutex> lock(state->mutex);
    id = state->next_id++;
    state->pending[id] =
        std::shared_ptr<flutter::MethodResult<>>(std::move(result));
  }
  // WinRT 呼び出しは専用 MTA スレッドで回す。購入ダイアログ (RequestPurchaseAsync)
  // はユーザー操作待ちで長時間ブロックしうるため、SMTC のようなタイムアウトは
  // かけず完了まで待つ (UI スレッドは別なので固まらない)。
  std::thread([state, id, work = std::move(work)]() {
    flutter::EncodableValue outcome;  // 既定は null (std::monostate)
    try {
      winrt::init_apartment(winrt::apartment_type::multi_threaded);
      outcome = work();
      winrt::uninit_apartment();
    } catch (...) {
      // WinRT 例外等。outcome は null のままにし、UI 側で Error を返す。
    }
    HWND hwnd = nullptr;
    {
      std::lock_guard<std::mutex> lock(state->mutex);
      if (!state->window_alive) {
        // ウィンドウ破棄済み = アプリ終了中。結果を返す先が無いので捨てる。
        // 保留していた MethodResult は pending に残ったまま state と一緒に破棄
        // される (Dart エンジンも teardown 中で応答先が無い)。
        return;
      }
      state->outcomes[id] = std::move(outcome);
      hwnd = state->hwnd;
    }
    if (hwnd) {
      PostMessage(hwnd, WM_STORE_IAP_RESULT, static_cast<WPARAM>(id), 0);
    }
  }).detach();
}
