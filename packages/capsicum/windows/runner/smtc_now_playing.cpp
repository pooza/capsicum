#include "smtc_now_playing.h"

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Media.Control.h>

#include <thread>

namespace {

using winrt::Windows::Media::Control::
    GlobalSystemMediaTransportControlsSessionManager;
using winrt::Windows::Media::Control::
    GlobalSystemMediaTransportControlsSessionPlaybackStatus;

// 実 WinRT 取得。MTA スレッド上で呼ばれる前提（IAsyncOperation::get() を
// STA でブロックしないため）。
flutter::EncodableValue QueryNowPlaying() {
  auto manager =
      GlobalSystemMediaTransportControlsSessionManager::RequestAsync().get();
  if (!manager) {
    return flutter::EncodableValue();
  }
  auto session = manager.GetCurrentSession();
  if (!session) {
    return flutter::EncodableValue();
  }

  auto status = session.GetPlaybackInfo().PlaybackStatus();
  // Closed / Stopped は「再生中の曲なし」扱い。
  if (status ==
          GlobalSystemMediaTransportControlsSessionPlaybackStatus::Closed ||
      status ==
          GlobalSystemMediaTransportControlsSessionPlaybackStatus::Stopped) {
    return flutter::EncodableValue();
  }

  auto props = session.TryGetMediaPropertiesAsync().get();
  if (!props) {
    return flutter::EncodableValue();
  }

  flutter::EncodableMap map;
  map[flutter::EncodableValue("title")] =
      flutter::EncodableValue(winrt::to_string(props.Title()));
  map[flutter::EncodableValue("artist")] =
      flutter::EncodableValue(winrt::to_string(props.Artist()));
  map[flutter::EncodableValue("albumTitle")] =
      flutter::EncodableValue(winrt::to_string(props.AlbumTitle()));
  map[flutter::EncodableValue("sourceAppId")] =
      flutter::EncodableValue(winrt::to_string(session.SourceAppUserModelId()));
  map[flutter::EncodableValue("status")] =
      flutter::EncodableValue(static_cast<int32_t>(status));
  return flutter::EncodableValue(map);
}

}  // namespace

flutter::EncodableValue GetCurrentNowPlaying() {
  // メソッドチャンネルのハンドラはプラットフォーム（UI）スレッドで走り、
  // それは STA。WinRT の非同期 API を STA で .get() ブロックすると停止し
  // うるため、専用の MTA スレッドで実行して join する。
  flutter::EncodableValue result;  // 既定は null (std::monostate)
  std::thread worker([&result]() {
    try {
      winrt::init_apartment(winrt::apartment_type::multi_threaded);
      result = QueryNowPlaying();
      winrt::uninit_apartment();
    } catch (...) {
      // セッションマネージャ取得不可 / 例外時は null のまま。
    }
  });
  worker.join();
  return result;
}
