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

#include "local_state_files.h"
#include "notification_tag.h"
#include "push_diagnostics.h"
#include "push_diagnostics_store.h"
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
std::wstring LocalStateFilePath(const wchar_t* name) {
  winrt::hstring folder =
      winrt::Windows::Storage::ApplicationData::Current().LocalFolder().Path();
  return std::wstring(folder.c_str(), folder.size()) + L"\\" + name;
}

std::string ReadFileUtf8(const std::wstring& path) {
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
}

std::string ReadLocalStateKeysetJson() {
  try {
    return ReadFileUtf8(LocalStateFilePath(capsicum::kLocalStateKeysetFile));
  } catch (...) {
    return std::string();
  }
}

// FullTrust 本体（Dart 由来）が書いた push_labels.json を読む (#770)。アカウント別
// の reblog/post 表示ラベル。不在・失敗時は空文字列で、トースト側が既定ラベル
// （ブースト / 投稿）にフォールバックする（ラベル欠落は表示を止めない）。
std::string ReadLocalStateLabelsJson() {
  try {
    return ReadFileUtf8(LocalStateFilePath(capsicum::kLocalStatePushLabelsFile));
  } catch (...) {
    return std::string();
  }
}

// bg task の観測コードを LocalState の単一スロットへ記録する (#474 フェーズ C)。
// AppContainer の bg task は Sentry SDK もコンソールも持てないため、ここに
// 残し、次回 FullTrust 起動時に runner が読んで Dart 経由で Sentry へ送る。
// 実体は runner と共有する push_diagnostics_store（#957 で runner 側からも
// 書くようになったため抽出した）。失敗は黙殺される（観測機構が通知本体を
// 巻き込まない）。
void RecordBgDiagnostic(const std::string& code, const std::string& host) {
  capsicum::RecordPushDiagnostic(code, host);
}

// TryBuildAnnouncementDisplay の error 文字列を観測コードへ写す (#978)。
// "not an announcement" は暗号化経路へ回るだけなのでここには来ない。
std::string AnnouncementDiagnosticCodeForError(const std::string& error) {
  // relay が announcement_body を載せていない（capsicum-relay#36 Phase 2 より
  // 古い relay）。お知らせを名乗っているのに表示材料が無い状態で、無記録だと
  // 「Windows だけお知らせが出ない」が手掛かり無しになる。
  if (error == "missing announcement body") {
    return "bgtask.announcement_no_body";
  }
  // invalid envelope / missing account。
  return "bgtask.announcement_bad_payload";
}

// HandleWnsRawPayload の error 文字列を観測コードへ写す。
std::string DiagnosticCodeForError(const std::string& error) {
  if (error == "no push keys") return "bgtask.no_keys";
  if (error == "decryption failed") return "bgtask.decrypt_failed";
  if (error == "payload parse failed") return "bgtask.parse_failed";
  if (error == "not an encrypted notification") return "bgtask.not_encrypted";
  // aes128gcm 以外の暗号化 push を Windows だけ捨てている可能性を、無暗号化
  // (announcement) と区別して観測する (#765)。
  if (error == "unsupported encoding") return "bgtask.unsupported_encoding";
  // invalid envelope / missing account / invalid body base64url 等。
  return "bgtask.bad_payload";
}

// 無暗号化のお知らせ push を表示する (#978)。announcement でなければ false を
// 返し、呼び出し側が暗号化経路へ回す。表示・観測まで完結させたときは true。
bool HandleAnnouncementContent(const std::string& content) {
  capsicum::PushDisplay announcement;
  std::string error;
  if (!capsicum::TryBuildAnnouncementDisplay(content, &announcement, &error)) {
    if (error == "not an announcement") {
      return false;  // 暗号化通知。復号経路へ。
    }
    // announcement を名乗っているのに表示材料が足りない。暗号化経路へ回しても
    // "not an encrypted notification" になるだけで理由が消えるので、ここで
    // 専用コードとして残す。
    RecordBgDiagnostic(
        AnnouncementDiagnosticCodeForError(error),
        capsicum::PushDiagnosticHostFromAccount(announcement.account));
    return true;
  }
  // Tag は WebSocket 経路 (#569) と同じ `announcement:<id>` 由来なので、起動
  // 直後に streaming が同じお知らせを出しても OS 側で畳める (#933)。表示に
  // 成功したときだけ shown を記録するのは暗号化経路と同じ規律 (#957)。
  //
  // ⚠ 通常の通知と**同じ bgtask.shown に合流させない**。「bgtask.shown が
  // 無ければ bg task 未起動」というトリアージ規則は通知 push の母数の上で
  // 成り立っており、配送経路も発火契機も違うお知らせを混ぜると母数が濁る。
  const bool shown = capsicum::ShowRawToast(
      announcement.title, announcement.body,
      /*launch_arg=*/"",
      capsicum::NotificationTagFor(announcement.account,
                                   announcement.notification_id));
  RecordBgDiagnostic(
      shown ? "bgtask.announcement_shown" : "bgtask.announcement_show_failed",
      capsicum::PushDiagnosticHostFromAccount(announcement.account));
  return true;
}

// 暗号化された通知 push を復号して表示する。
void HandleEncryptedContent(const std::string& content) {
  // 鍵は FullTrust 本体が LocalState に同期した push_keys.json から読む
  // （AppContainer はローミング %APPDATA% の .dat を読めないため）。
  const std::string keyset = ReadLocalStateKeysetJson();
  if (keyset.empty()) {
    // Option A の鍵同期がまだ走っていない（FullTrust を一度も起動して
    // いない等）。鍵不在と区別して記録する。
    RecordBgDiagnostic("bgtask.no_keyset", std::string());
    return;
  }
  capsicum::PushDisplay display;
  std::string error;
  // アカウント別 reblog/post ラベルを LocalState から読む (#770)。無ければ
  // 既定ラベルにフォールバックする（title 文言のみ・鍵/復号には無関係）。
  const std::string labels = ReadLocalStateLabelsJson();
  if (capsicum::HandleWnsRawPayloadFromKeysetJson(content, keyset, &display,
                                                  &error, labels)) {
    // title / body はサーバー生成・ローカライズ済み。tag は WebSocket
    // 経路 (#569) と同じ導出に揃える (#933)。bg task が動くのはアプリ
    // 終了中なので二重にはならないが、起動直後に WebSocket 経路が同じ
    // 通知を出したときに OS 側で畳めるよう表現を合わせておく。通知 ID を
    // 持たない払い出しでは Tag を付けない (#956)。付けると連続して届いた
    // 分が同じ Tag で差し替わり、Action Center に最後の 1 件しか残らない。
    const bool shown = capsicum::ShowRawToast(
        display.title, display.body,
        /*launch_arg=*/"",
        capsicum::NotificationTagFor(display.account, display.notification_id));
    // ⚠ 戻り値を捨てて無条件に bgtask.shown を書くと、**復号まで成功
    // したが表示だけ失敗した**（非 MSIX 起動 / WinRT 例外 / XML 不正）
    // ケースが「出したのに届かなかった＝relay / WNS 側の問題」に見える
    // (#957)。「bgtask.shown が無ければ未起動」というトリアージ規則を
    // 成立させるため、成功したときだけ shown を記録する。
    RecordBgDiagnostic(shown ? "bgtask.shown" : "bgtask.show_failed",
                       capsicum::PushDiagnosticHostFromAccount(display.account));
    return;
  }
  // 復号できない通知（鍵不在・レガシー aesgcm 等）は捨てるが、無言だと
  // bg task が動いたかすら分からないため観測コードを残す。account は
  // 復号前にエンベロープから display に載っているので、host を観測へ
  // 出して発生元サーバーを特定できるようにする (#800)。
  RecordBgDiagnostic(DiagnosticCodeForError(error),
                     capsicum::PushDiagnosticHostFromAccount(display.account));
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
        // お知らせ push は無暗号化なので**鍵より先に**判定する (#978)。鍵セット
        // の同期が遅れていてもお知らせは出せるし、読む必要のない
        // push_keys.json を開かずに済む。
        if (!HandleAnnouncementContent(content)) {
          HandleEncryptedContent(content);
        }
      } else {
        // raw push trigger なのに RawNotification 以外（toast/badge/tile 等）が
        // 来た。実害は無いが、無記録だと「bg task が起動したのに何も残らない」
        // 空白になり、push 不達トリアージで本当の問題と区別できない。正常系
        // 扱い（info）で起動した事実だけ残す。
        RecordBgDiagnostic("bgtask.not_raw", std::string());
      }
    } catch (...) {
      // バックグラウンドホストを巻き込まないよう全例外を握り潰す。
      RecordBgDiagnostic("bgtask.exception", std::string());
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
