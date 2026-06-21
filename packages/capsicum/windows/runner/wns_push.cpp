#include "wns_push.h"

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Networking.PushNotifications.h>

namespace {

using winrt::Windows::Networking::PushNotifications::PushNotificationChannel;
using winrt::Windows::Networking::PushNotifications::
    PushNotificationChannelManager;

}  // namespace

std::string QueryWnsChannelUri() {
  try {
    // CreatePushNotificationChannelForApplicationAsync は静的メソッド。
    // パッケージ ID を持つ起動でのみ成功し、既存チャンネルがあれば即座に
    // 返る（初回 / 期限切れ更新時のみネットワークが走る）。.get() を呼ぶため
    // 呼び出し側は MTA スレッドであることが前提（wns_push.h 参照）。
    PushNotificationChannel channel =
        PushNotificationChannelManager::
            CreatePushNotificationChannelForApplicationAsync()
                .get();
    if (!channel) {
      return std::string();
    }
    return winrt::to_string(channel.Uri());
  } catch (...) {
    // 非 MSIX 起動（パッケージ ID 無し）・ネットワーク不通・WinRT 例外時は
    // 空文字列。Dart 側で noDeviceToken 扱いになり UI は「対象外」に倒れる。
    return std::string();
  }
}
