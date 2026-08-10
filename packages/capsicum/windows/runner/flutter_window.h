#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/method_result.h>

#include <atomic>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "win32_window.h"

// WNS Channel URI 取得ワーカーが取得完了を UI スレッドへ通知するための
// カスタムメッセージ (#474 フェーズ1)。flutter::MethodChannel の InvokeMethod は
// プラットフォーム（UI）スレッド affinity を持つため、MTA ワーカーで取得した
// 結果を PostMessage で UI スレッドに marshal してから Dart へ返す。
#define WM_WNS_CHANNEL_READY (WM_APP + 1)

// Store IAP (#599) の非同期ワーカーが結果を UI スレッドへ返すためのメッセージ。
// MethodResult はプラットフォーム（UI）スレッドでしか触れないため、MTA ワーカーで
// 得た結果を PostMessage で marshal し、UI スレッド側で Success/Error を返す。
// wparam に結果 id を載せる。
#define WM_STORE_IAP_RESULT (WM_APP + 2)

// 起動中に WNS 経路がトーストを出したことを Dart へ伝えるためのメッセージ
// (#945)。in-process 受信は MTA ワーカースレッドで走るが、InvokeMethod は
// プラットフォーム（UI）スレッドでしか呼べないため、キーをキューに積んで
// PostMessage し、UI スレッド側で 'onRemotePresented' を投げる。
#define WM_NOTIFICATION_PRESENTED (WM_APP + 3)

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

  // 起動中二重通知の dedup 用メソッドチャンネル (#945)。macOS (#674) と同じ
  // チャネル名・同じキー空間で、Dart 側 NotificationDedupChannel と対になる。
  //
  // - Dart → native: 'addEmitted'（WebSocket 経路が出したキー）を受けて
  //   NotificationDedupRegistry に記録し、WNS 経路の表示を抑止する
  // - native → Dart: WNS 経路が出したら 'onRemotePresented' を投げ、
  //   DesktopNotificationDispatcher に emit をスキップさせる
  std::unique_ptr<flutter::MethodChannel<>> notification_dedup_channel_;

  // WNS 受信ワーカー（detached・プロセス終了までブロック）と UI スレッドが
  // 共有する状態。ワーカーが FlutterWindow より長生きするため、Store IAP
  // (#795) と同じく shared_ptr に載せて延命し、破棄後は書き込まない。
  struct DedupDispatchState {
    std::mutex mutex;
    // ワーカーが積み、UI スレッド (WM_NOTIFICATION_PRESENTED) が引き取る。
    std::vector<std::string> presented;
    bool window_alive = true;
    HWND hwnd = nullptr;
  };
  std::shared_ptr<DedupDispatchState> dedup_state_ =
      std::make_shared<DedupDispatchState>();

  // 投げ銭 IAP (#599) 用メソッドチャンネル。Dart 側 WindowsStoreBackend が
  // 'queryProducts' / 'purchase' / 'reportFulfillment' を呼ぶ。WinRT 呼び出しは
  // MTA ワーカーで回し、完了を WM_STORE_IAP_RESULT で UI スレッドへ marshal する。
  std::unique_ptr<flutter::MethodChannel<>> store_iap_channel_;

  // Store IAP ワーカーの共有状態 (#795)。detached MTA ワーカーは購入ダイアログ
  // (RequestPurchaseAsync) のユーザー操作待ちで数分ブロックしうるため、その間に
  // メインウィンドウを閉じる (= Windows ではアプリ終了) と FlutterWindow が先に
  // 破棄され、ワーカーが解放済みの mutex / map / stale HWND を触る UAF になる。
  // これらを shared_ptr の状態ブロックに移し、ワーカーと UI スレッド (MessageHandler)
  // の双方が所有することで FlutterWindow より長生きさせる。window_alive は
  // OnDestroy で false にし、ワーカーは破棄後は結果を書かず PostMessage もしない。
  struct StoreDispatchState {
    std::mutex mutex;
    int next_id = 0;
    // ワーカー完了までペンディングする MethodResult と、ワーカーが書き込む結果値。
    // id で対応づけ、UI スレッドの WM_STORE_IAP_RESULT ハンドラが取り出して返す。
    std::map<int, std::shared_ptr<flutter::MethodResult<>>> pending;
    std::map<int, flutter::EncodableValue> outcomes;
    // ウィンドウ (と hwnd) が生存しているか。OnDestroy で false + hwnd=nullptr に
    // する。false の間はワーカーは結果を捨て PostMessage しない (返す先が無い)。
    bool window_alive = true;
    HWND hwnd = nullptr;
  };
  std::shared_ptr<StoreDispatchState> store_state_ =
      std::make_shared<StoreDispatchState>();

  // WinRT を叩く |work| を MTA ワーカーで実行し、結果を UI スレッド経由で
  // |result| へ返す。work が例外を投げた / null を返したら Error を返す。
  void DispatchStoreWork(std::unique_ptr<flutter::MethodResult<>> result,
                         std::function<flutter::EncodableValue()> work);
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
