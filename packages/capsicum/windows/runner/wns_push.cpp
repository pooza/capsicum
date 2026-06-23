#include "wns_push.h"

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Networking.PushNotifications.h>

#include <condition_variable>
#include <mutex>
#include <string>

#include "web_push_key_reader.h"
#include "web_push_receive.h"
#include "win_toast.h"

namespace {

using winrt::Windows::Networking::PushNotifications::PushNotificationChannel;
using winrt::Windows::Networking::PushNotifications::
    PushNotificationChannelManager;
using winrt::Windows::Networking::PushNotifications::
    PushNotificationReceivedEventArgs;
using winrt::Windows::Networking::PushNotifications::PushNotificationType;

// raw 通知 1 通を復号してトースト表示する。失敗（非暗号化通知・鍵不在・復号
// 失敗）は黙って捨てる。title / body はサーバーが生成・ローカライズ済み。
void DisplayRawNotification(const std::string& content) {
  capsicum::PushDisplay display;
  if (!capsicum::HandleWnsRawPayload(
          content, capsicum::DefaultSecureStorageDatPath(), &display,
          nullptr)) {
    return;
  }
  // tag に SNS 通知 ID を使い、#569 WebSocket 経路との将来 dedup / 差し替えに
  // 備える。タップ遷移 (launch_arg) はフェーズ C で COM アクティベータと一緒に
  // 配線するため、ここでは付けない。
  capsicum::ShowRawToast(display.title, display.body, /*launch_arg=*/"",
                         display.notification_id);
}

}  // namespace

void RunWnsChannelReceiver(
    const std::function<void(const std::string&)>& on_uri) {
  PushNotificationChannel channel{nullptr};
  try {
    // .get() でブロックするため MTA。CreatePushNotificationChannelForApplication-
    // Async はパッケージ ID を持つ起動でのみ成功し、既存チャンネルがあれば即座に
    // 返る（初回 / 期限切れ更新時のみネットワークが走る）。
    winrt::init_apartment(winrt::apartment_type::multi_threaded);
    channel = PushNotificationChannelManager::
                  CreatePushNotificationChannelForApplicationAsync()
                      .get();
  } catch (...) {
    // 非 MSIX 起動（パッケージ ID 無し）・ネットワーク不通・WinRT 例外。
  }

  std::string uri;
  if (channel) {
    try {
      uri = winrt::to_string(channel.Uri());
    } catch (...) {
      uri.clear();
    }
  }
  // URI を呼び出し側へ返す（空 = 取得不可。Dart 側で noDeviceToken 扱い）。
  on_uri(uri);

  if (!channel) {
    winrt::uninit_apartment();
    return;
  }

  // 起動中の in-process 受信を購読する。raw 通知は OS が自動表示しないため、
  // 自前で復号 → トースト表示する。
  try {
    channel.PushNotificationReceived(
        [](const PushNotificationChannel&,
           const PushNotificationReceivedEventArgs& args) {
          try {
            if (args.NotificationType() == PushNotificationType::Raw) {
              // 起動中に受けたら自前表示し、OS のバックグラウンドタスク発火
              // （フェーズ C）を抑止して二重処理を防ぐ。
              args.Cancel(true);
              DisplayRawNotification(
                  winrt::to_string(args.RawNotification().Content()));
            }
          } catch (...) {
            // 受信ハンドラ内の例外は握り潰す（プロセスを巻き込まない）。
          }
        });
  } catch (...) {
    winrt::uninit_apartment();
    return;
  }

  // channel と MTA アパートメントを保持したままブロックし、購読を生かし続ける
  // （イベントは MTA の RPC スレッドで発火するためメッセージポンプは不要）。
  std::mutex wait_mutex;
  std::condition_variable wait_cv;
  std::unique_lock<std::mutex> wait_lock(wait_mutex);
  wait_cv.wait(wait_lock, [] { return false; });
}
