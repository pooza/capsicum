#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <atomic>
#include <memory>
#include <mutex>
#include <string>

#include "win32_window.h"

// WNS Channel URI 取得ワーカーが取得完了を UI スレッドへ通知するための
// カスタムメッセージ (#474 フェーズ1)。flutter::MethodChannel の InvokeMethod は
// プラットフォーム（UI）スレッド affinity を持つため、MTA ワーカーで取得した
// 結果を PostMessage で UI スレッドに marshal してから Dart へ返す。
#define WM_WNS_CHANNEL_READY (WM_APP + 1)

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // ナウプレ取得 (SMTC) 用メソッドチャンネル (#466 / #484)。
  std::unique_ptr<flutter::MethodChannel<>> now_playing_channel_;

  // WNS push (Channel URI 取得) 用メソッドチャンネル (#474 フェーズ1)。
  // Dart 側 WnsService が 'requestChannelUri' を呼ぶと MTA ワーカーで URI を
  // 取得し、完了後に 'onChannelUri' を InvokeMethod で Dart へ返す。
  std::unique_ptr<flutter::MethodChannel<>> wns_channel_;
  // ワーカーが取得した Channel URI。UI スレッドの InvokeMethod へ受け渡す。
  std::mutex wns_mutex_;
  std::string wns_uri_;
  // requestChannelUri の受信ワーカーを 1 度だけ起動するための再入ガード
  // (#763)。RunWnsChannelReceiver は購読後プロセス終了までブロックするため、
  // 複数回起動すると MTA スレッドと PushNotificationReceived 購読が多重化し、
  // 同一 raw 通知でトーストが複数回出る。
  std::atomic<bool> wns_receiver_started_{false};
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
