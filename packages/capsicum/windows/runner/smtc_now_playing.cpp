#include "smtc_now_playing.h"

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Media.Control.h>

#include <chrono>
#include <future>
#include <memory>
#include <thread>
#include <utility>

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

// UI スレッドが SMTC 取得で固まる上限。通常の取得は数十 ms で返るが、応答しない
// メディアアプリ（バス名は持つが props を返さない等）に当たると WinRT の .get()
// が長時間ブロックしうる。この上限で打ち切り、無制限フリーズを防ぐ。
constexpr auto kQueryTimeout = std::chrono::seconds(3);

flutter::EncodableValue GetCurrentNowPlaying() {
  // メソッドチャンネルのハンドラはプラットフォーム（UI）スレッドで走り、それは
  // STA。WinRT の非同期 API を STA で .get() ブロックすると停止しうるため、専用の
  // MTA スレッドで実行する。さらにワーカーをタイムアウト付きで待ち、応答しない
  // プレイヤーで UI スレッドが無制限に固まらないようにする。
  //
  // タイムアウト時はワーカーを detach して放置する（最終的に WinRT が返れば
  // promise を立てて自然終了）。ワーカーがタイムアウト後も生存しうるため、結果は
  // 参照キャプチャでなく shared な promise で寿命を分離する（detach 後の
  // use-after-scope を避ける）。
  auto promise = std::make_shared<std::promise<flutter::EncodableValue>>();
  std::future<flutter::EncodableValue> future = promise->get_future();

  std::thread worker([promise]() {
    flutter::EncodableValue value;  // 既定は null (std::monostate)
    try {
      winrt::init_apartment(winrt::apartment_type::multi_threaded);
      value = QueryNowPlaying();
      winrt::uninit_apartment();
    } catch (...) {
      // セッションマネージャ取得不可 / 例外時は null のまま。
    }
    try {
      promise->set_value(std::move(value));
    } catch (...) {
      // 既に satisfied 等。無視（呼び出し側はタイムアウトで null を返す）。
    }
  });

  if (future.wait_for(kQueryTimeout) == std::future_status::ready) {
    worker.join();
    return future.get();
  }

  // タイムアウト: ワーカーは放置し、UI には null（再生中の曲なし扱い）を返す。
  worker.detach();
  return flutter::EncodableValue();
}
