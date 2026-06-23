// WNS raw push のバックグラウンドタスク (#474 フェーズ C)。
//
// アプリ完全終了中に WNS raw 通知が届くと、OS が PushNotificationTrigger で
// このタスクを起動する。タスクは backgroundTaskHost.exe にロードされる WinRT
// in-process server DLL で、Flutter エンジンを起こさず純 C++ で
//   RawNotification.Content() → HandleWnsRawPayload（復号）→ ShowRawToast
// を実行する。macOS の Notification Service Extension に相当する。
//
// マニフェストに以下を注入して有効化する（msix config では宣言できないため
// build → patch → pack で挿入。#474 フェーズ C 設計）:
//   - Application 配下: windows.backgroundTasks (Task Type="pushNotification")
//     EntryPoint="CapsicumPushTask.PushBackgroundTask"
//   - Package 配下: windows.activatableClass.inProcessServer
//     Path=push_background_task.dll / ActivatableClassId 同上
// runner 側は BackgroundTaskBuilder + PushNotificationTrigger で 1 度登録する。
//
// 実行中はランナーの in-process 受信が args.Cancel(true) でこのタスクの発火を
// 抑止するため、本タスクが走るのは実質「アプリ未起動時」だけになる。

#include <windows.h>
#include <winerror.h>
// windows.h の後に置く（HSTRING / WindowsGetStringRawBuffer / IActivationFactory /
// DllGetActivationFactory 宣言）。
#include <roapi.h>
#include <winstring.h>

#include <winrt/Windows.ApplicationModel.Background.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Networking.PushNotifications.h>
#include <winrt/Windows.Storage.h>

#include <fstream>
#include <string>
#include <string_view>

#include "web_push_receive.h"
#include "win_toast.h"

namespace {

using winrt::Windows::ApplicationModel::Background::IBackgroundTask;
using winrt::Windows::ApplicationModel::Background::IBackgroundTaskInstance;
using winrt::Windows::Networking::PushNotifications::RawNotification;

// このタスクの ActivatableClassId。マニフェストの inProcessServer 宣言と
// runner 側 TaskEntryPoint と完全一致させること。
constexpr wchar_t kRuntimeClassName[] = L"CapsicumPushTask.PushBackgroundTask";

// FullTrust 本体が書き出した LocalState の push_keys.json（平文鍵セット）を読む
// (#474 フェーズ C / Option A)。AppContainer のバックグラウンドタスクは
// ローミング %APPDATA% の flutter_secure_storage.dat を読めず DPAPI 復号も
// できないため、パッケージ専有で両者からアクセスできる ApplicationData の
// LocalFolder 経由で鍵を受け取る。
std::string ReadLocalStateKeysetJson() {
  try {
    winrt::hstring folder =
        winrt::Windows::Storage::ApplicationData::Current().LocalFolder().Path();
    std::wstring path =
        std::wstring(folder.c_str(), folder.size()) + L"\\push_keys.json";
    std::ifstream f(path, std::ios::binary | std::ios::ate);
    if (!f) {
      return std::string();
    }
    std::streamoff size = f.tellg();
    if (size <= 0) {
      return std::string();
    }
    std::string out(static_cast<size_t>(size), '\0');
    f.seekg(0);
    f.read(out.data(), static_cast<std::streamsize>(size));
    return out;
  } catch (...) {
    return std::string();
  }
}

struct PushBackgroundTask
    : winrt::implements<PushBackgroundTask, IBackgroundTask> {
  void Run(IBackgroundTaskInstance const& instance) {
    // 非同期の表示処理を確実に終わらせるため deferral を取る。
    auto deferral = instance.GetDeferral();
    try {
      auto raw = instance.TriggerDetails().try_as<RawNotification>();
      if (raw) {
        const std::string content = winrt::to_string(raw.Content());
        // 鍵は FullTrust 本体が LocalState に同期した push_keys.json から読む
        // （AppContainer はローミング %APPDATA% の .dat を読めないため）。
        const std::string keyset = ReadLocalStateKeysetJson();
        capsicum::PushDisplay display;
        if (capsicum::HandleWnsRawPayloadFromKeysetJson(content, keyset,
                                                        &display, nullptr)) {
          // title / body はサーバー生成・ローカライズ済み。tag に SNS 通知 ID。
          capsicum::ShowRawToast(display.title, display.body,
                                 /*launch_arg=*/"", display.notification_id);
        }
        // 復号できない通知（鍵不在・announcement 等）は黙って捨てる。
      }
    } catch (...) {
      // バックグラウンドホストを巻き込まないよう全例外を握り潰す。
    }
    deferral.Complete();
  }
};

struct PushBackgroundTaskFactory
    : winrt::implements<PushBackgroundTaskFactory,
                        winrt::Windows::Foundation::IActivationFactory> {
  winrt::Windows::Foundation::IInspectable ActivateInstance() {
    return winrt::make<PushBackgroundTask>();
  }
};

}  // namespace

BOOL WINAPI DllMain(HINSTANCE hinst, DWORD reason, LPVOID /*reserved*/) {
  if (reason == DLL_PROCESS_ATTACH) {
    DisableThreadLibraryCalls(hinst);
  }
  return TRUE;
}

// WinRT 活性化エントリポイント。システム（backgroundTaskHost）が
// RoGetActivationFactory 経由で呼ぶ。シグネチャは roapi.h / combaseapi.h の宣言と
// 一致させ、エクスポートは push_background_task.def で行う（dllexport を付けると
// システムヘッダの宣言とリンケージが衝突するため）。
extern "C" HRESULT __stdcall DllGetActivationFactory(
    HSTRING classId, IActivationFactory** factory) {
  if (factory == nullptr) {
    return E_POINTER;
  }
  *factory = nullptr;
  try {
    std::wstring_view name{WindowsGetStringRawBuffer(classId, nullptr)};
    if (name == kRuntimeClassName) {
      *factory = static_cast<IActivationFactory*>(
          winrt::detach_abi(winrt::make<PushBackgroundTaskFactory>()));
      return S_OK;
    }
    return REGDB_E_CLASSNOTREG;
  } catch (...) {
    return winrt::to_hresult();
  }
}

extern "C" HRESULT __stdcall DllCanUnloadNow() {
  return winrt::get_module_lock() ? S_FALSE : S_OK;
}
