#include "wns_push.h"

#include <winrt/Windows.ApplicationModel.Background.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Networking.PushNotifications.h>
#include <winrt/Windows.Storage.h>

#include <condition_variable>
#include <cstdio>
#include <fstream>
#include <mutex>
#include <string>

#include "local_state_files.h"
#include "web_push_key_reader.h"
#include "web_push_receive.h"
#include "win_toast.h"

namespace {

using winrt::Windows::ApplicationModel::Background::BackgroundExecutionManager;
using winrt::Windows::ApplicationModel::Background::BackgroundTaskBuilder;
using winrt::Windows::ApplicationModel::Background::BackgroundTaskRegistration;
using winrt::Windows::ApplicationModel::Background::PushNotificationTrigger;
using winrt::Windows::Networking::PushNotifications::PushNotificationChannel;
using winrt::Windows::Networking::PushNotifications::
    PushNotificationChannelManager;
using winrt::Windows::Networking::PushNotifications::
    PushNotificationReceivedEventArgs;
using winrt::Windows::Networking::PushNotifications::PushNotificationType;

// バックグラウンドタスクの登録名と EntryPoint。push_background_task.cpp の
// ActivatableClassId・patch_appxmanifest_pushtask.ps1 の宣言と完全一致させる。
constexpr wchar_t kBackgroundTaskName[] = L"CapsicumPushTask";
constexpr wchar_t kBackgroundTaskEntryPoint[] =
    L"CapsicumPushTask.PushBackgroundTask";

// push_keys.json の truncate-write / 削除を直列化する。起動時同期と、ログアウト
// /登録後にメソッドチャネルから走る再同期が並走しても書き込みが交錯しないように
// するため。
std::mutex& PushKeysSyncMutex() {
  static std::mutex m;
  return m;
}

// LocalState の push_keys.json 絶対パス。LocalFolder 解決失敗時は空文字列。
std::wstring PushKeysJsonPath() {
  try {
    winrt::hstring folder =
        winrt::Windows::Storage::ApplicationData::Current().LocalFolder().Path();
    return std::wstring(folder.c_str(), folder.size()) + L"\\" +
           capsicum::kLocalStateKeysetFile;
  } catch (...) {
    return std::wstring();
  }
}

// アプリ完全終了中の WNS raw 受信用バックグラウンドタスクを 1 度だけ登録する
// (#474 フェーズ C)。既存登録があればスキップ。MTA スレッドから呼ぶこと。
void RegisterPushBackgroundTaskOnce() {
  try {
    for (auto const& entry : BackgroundTaskRegistration::AllTasks()) {
      if (entry.Value().Name() == kBackgroundTaskName) {
        return;  // 既に登録済み。
      }
    }
    // パッケージ済みアプリのバックグラウンド実行許可（拒否されても登録は試みる）。
    BackgroundExecutionManager::RequestAccessAsync().get();
    BackgroundTaskBuilder builder;
    builder.Name(kBackgroundTaskName);
    builder.TaskEntryPoint(kBackgroundTaskEntryPoint);
    builder.SetTrigger(PushNotificationTrigger());
    builder.Register();
  } catch (...) {
    // 登録失敗（権限拒否・非パッケージ起動・マニフェスト未宣言等）は諦める。
    // 起動中は in-process 受信が動くため push 全体は止めない。
  }
}

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

// push 鍵セットを AppContainer のバックグラウンドタスクが読める LocalState に
// 書き出す (#474 フェーズ C / Option A)。bg task はサンドボックスのため
// ローミング %APPDATA% の flutter_secure_storage.dat を読めず DPAPI 復号も
// できないので、FullTrust 本体がここで鍵セットだけを平文 JSON 化して
// ApplicationData.LocalFolder（パッケージ専有・両者からアクセス可）へ渡す。
//
// 起動時に加えてログアウト・アカウント追加など鍵セット変更後にも呼ばれる
// （flutter_window の syncPushKeys メソッドチャネル経由）。鍵セットが読めない
// （.dat 不在・DPAPI 失敗）ときは push_keys.json を削除し、ログアウト済み
// アカウントの平文鍵を bg task に残さない（鍵が読めない＝通知が出ない安全側に
// 倒す。他プラットフォームが secure storage から鍵を消すと復号できなくなるのと
// parity を取る）。
void SyncWnsPushKeysToLocalState() {
  std::lock_guard<std::mutex> guard(PushKeysSyncMutex());
  try {
    const std::wstring path = PushKeysJsonPath();
    if (path.empty()) {
      return;  // LocalFolder 解決不可。次の機会に再同期される。
    }
    const std::wstring dat = capsicum::DefaultSecureStorageDatPath();
    std::string json;
    if (!capsicum::ExtractPushKeysetMapJson(dat, &json, nullptr)) {
      // .dat 不在・DPAPI 失敗・パース失敗。古い平文鍵を残さないよう既存ファイルを
      // 消す。通常ログアウト（鍵エントリのみ削除）は .dat が読めて空マップ "{}" が
      // 返るため、この分岐ではなく下の truncate-write 側で正しく上書きされる。
      _wremove(path.c_str());
      return;
    }
    std::ofstream f(path, std::ios::binary | std::ios::trunc);
    if (f) {
      f.write(json.data(), static_cast<std::streamsize>(json.size()));
    }
  } catch (...) {
    // 書き出し失敗は致命でない（in-process 受信は引き続き動く）。
  }
}

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

  // アプリ完全終了中の受信用に鍵を AppContainer から読める LocalState に同期して
  // から、バックグラウンドタスクを登録する (#474 フェーズ C)。順序が逆だと
  // 「登録済みだが鍵未同期」の窓で push を受けて bgtask.no_keyset を偽陽性で
  // 記録しうるため、同期を先に済ませる。なお初回起動時は Dart の鍵生成がまだ
  // 走っていないことがあり、その分はログイン/登録完了後に Dart が syncPushKeys
  // メソッドチャネルで再同期する（ログアウト時の鍵削除も同経路）。起動中は下の
  // in-process 受信が args.Cancel(true) でこのタスク発火を抑止する。
  SyncWnsPushKeysToLocalState();
  RegisterPushBackgroundTaskOnce();

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

bool ConsumePushDiagnosticsJson(std::string* out_json) {
  if (out_json == nullptr) {
    return false;
  }
  out_json->clear();
  try {
    winrt::hstring folder =
        winrt::Windows::Storage::ApplicationData::Current().LocalFolder().Path();
    std::wstring path = std::wstring(folder.c_str(), folder.size()) + L"\\" +
                        capsicum::kLocalStateDiagFile;
    {
      std::ifstream f(path, std::ios::binary | std::ios::ate);
      if (!f) {
        return false;  // レコード無し。
      }
      std::streamoff size = f.tellg();
      if (size <= 0) {
        f.close();
        _wremove(path.c_str());
        return false;
      }
      out_json->resize(static_cast<size_t>(size));
      f.seekg(0);
      f.read(out_json->data(), static_cast<std::streamsize>(size));
    }
    // 二重送信を避けるため読み出したら消す。
    _wremove(path.c_str());
    return !out_json->empty();
  } catch (...) {
    out_json->clear();
    return false;
  }
}
