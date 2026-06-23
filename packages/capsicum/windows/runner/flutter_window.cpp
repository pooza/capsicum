#include "flutter_window.h"

#include <flutter/method_call.h>
#include <flutter/method_result.h>
#include <flutter/standard_method_codec.h>

#include <winrt/Windows.Foundation.h>

#include <mutex>
#include <optional>
#include <string>
#include <thread>

#include "flutter/generated_plugin_registrant.h"
#include "smtc_now_playing.h"
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

  return true;
}

void FlutterWindow::OnDestroy() {
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
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
