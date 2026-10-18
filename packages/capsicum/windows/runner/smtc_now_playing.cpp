#include "smtc_now_playing.h"

#include <windows.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Media.Control.h>
#include <winrt/Windows.Security.Cryptography.Core.h>
#include <winrt/Windows.Security.Cryptography.h>
#include <winrt/Windows.Storage.Streams.h>

#include <chrono>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <future>
#include <initializer_list>
#include <memory>
#include <string>
#include <system_error>
#include <thread>
#include <utility>
#include <vector>

namespace {

using winrt::Windows::Foundation::AsyncStatus;
using winrt::Windows::Media::Control::
    GlobalSystemMediaTransportControlsSessionManager;
using winrt::Windows::Media::Control::
    GlobalSystemMediaTransportControlsSessionMediaProperties;
using winrt::Windows::Media::Control::
    GlobalSystemMediaTransportControlsSessionPlaybackStatus;

// Dart 側の `kNowPlayingArtworkMaxBytes` と同じ上限。超えるものは書き出さない。
constexpr uint64_t kArtworkMaxBytes = 10 * 1024 * 1024;

// ジャケットの読み出しの 1 段（開く / 読む）ごとの上限 (#1274)。
//
// ⚠⚠ **曲名の取得と同じ 3 秒（kQueryTimeout）の中で走る。**ジャケットで
// 待ちすぎると、打ち切りで曲名ごと失われる（ナウプレそのものが出ない）。
// ジャケットは上積みなので、ここで先に諦める。
constexpr auto kArtworkStepTimeout = std::chrono::milliseconds(750);

// これより古い書き出しは、次に書き出すときに消す（macOS と同じ・#1283）。
//
// ⚠ **「いまの絵以外を全部消す」にしない。**投稿フォームは添付したジャケットを
// 投稿するまでファイルのまま持つので、別の曲で押し直した瞬間に前の絵を消すと、
// 添付済みのほうが読めなくなる。1 日たったものだけを消す。
constexpr auto kArtworkRetention = std::chrono::hours(24);

constexpr wchar_t kArtworkDirPrefix[] = L"nowplaying_native_";

struct ArtworkResult {
  std::string path;     // 書き出したファイルの絶対パス（UTF-8）
  std::string skipped;  // 書き出さなかった理由（Dart の kNowPlayingArtworkSkipReasons）
};

// 先頭のバイトから拡張子を決める。画像でなければ空。
// ⚠ Dart 側の `_extensionByMime` が受け取る形式に限る。
std::wstring ArtworkExtension(const std::vector<uint8_t>& data) {
  auto starts = [&data](std::initializer_list<uint8_t> magic) {
    if (data.size() < magic.size()) return false;
    size_t i = 0;
    for (auto b : magic) {
      if (data[i++] != b) return false;
    }
    return true;
  };
  if (starts({0xFF, 0xD8, 0xFF})) return L"jpg";
  if (starts({0x89, 0x50, 0x4E, 0x47})) return L"png";
  if (starts({'G', 'I', 'F', '8'})) return L"gif";
  if (data.size() >= 12 && starts({'R', 'I', 'F', 'F'}) && data[8] == 'W' &&
      data[9] == 'E' && data[10] == 'B' && data[11] == 'P') {
    return L"webp";
  }
  return L"";
}

// 中身の SHA-256 の先頭 16 桁（置き場所のディレクトリ名に使う）。
std::wstring ArtworkDigest(const std::vector<uint8_t>& data) {
  using winrt::Windows::Security::Cryptography::CryptographicBuffer;
  using winrt::Windows::Security::Cryptography::Core::HashAlgorithmNames;
  using winrt::Windows::Security::Cryptography::Core::HashAlgorithmProvider;
  auto provider =
      HashAlgorithmProvider::OpenAlgorithm(HashAlgorithmNames::Sha256());
  auto hashed = provider.HashData(CryptographicBuffer::CreateFromByteArray(
      winrt::array_view<uint8_t const>(data)));
  std::wstring hex(CryptographicBuffer::EncodeToHexString(hashed));
  return hex.substr(0, 16);
}

// 古い書き出しを消す (#1283 と同じ)。違うジャケットの曲で押すたびに
// 1 ディレクトリ増えるので、放っておくと一時領域に溜まり続ける。
//
// ⚠ 失敗は握る（掃除は上積みで、いまの書き出しの成否に関係しない）。
void PurgeStaleArtwork(const std::filesystem::path& tmp,
                       const std::filesystem::path& current) {
  namespace fs = std::filesystem;
  try {
    std::error_code ec;
    const auto threshold = fs::file_time_type::clock::now() - kArtworkRetention;
    for (fs::directory_iterator it(tmp, ec), end; !ec && it != end;
         it.increment(ec)) {
      const auto name = it->path().filename().wstring();
      if (name.rfind(kArtworkDirPrefix, 0) != 0) continue;
      if (name == current.filename().wstring()) continue;
      std::error_code time_ec;
      const auto modified = fs::last_write_time(it->path(), time_ec);
      if (time_ec || modified >= threshold) continue;
      std::error_code remove_ec;
      fs::remove_all(it->path(), remove_ec);
    }
  } catch (...) {
  }
}

// ジャケットのバイト列を一時ファイルへ書き出す (#1274)。
//
// Dart 側は `file://` として既存の添付の経路（`fetchNowPlayingArtwork`）へ流す。
// ⚠ **置き場所は中身のハッシュで決める**（macOS の #1273 と同じ）。投稿フォームは
// 「同じジャケットを 2 枚添付しない」を URI の一致で見ているので、同じ絵は同じ
// パスに、違う絵は違うパスになる必要がある。押すたびに一時ファイルが増えることもない。
// ⚠ ファイル名は固定（そのまま投稿先のファイル名になる）。
ArtworkResult WriteArtwork(const std::vector<uint8_t>& data) {
  namespace fs = std::filesystem;
  const auto ext = ArtworkExtension(data);
  if (ext.empty()) return {"", "unsupported_format"};
  try {
    wchar_t buffer[MAX_PATH + 1];
    const DWORD length = GetTempPathW(MAX_PATH + 1, buffer);
    if (length == 0 || length > MAX_PATH) return {"", "write_failed"};
    const fs::path tmp(std::wstring(buffer, length));
    const fs::path dir = tmp / (kArtworkDirPrefix + ArtworkDigest(data));
    const fs::path file = dir / (L"nowplaying-artwork." + ext);
    // ⚠ 書きかけの名前はスレッドごとに分ける。3 秒の打ち切りで切り離した
    // ワーカーと次の取得が、同じ絵を同時に書くことがある（v2.4 リリース前レビュー）。
    const fs::path partial =
        dir / (L"nowplaying-artwork." + ext + L"." +
               std::to_wstring(GetCurrentThreadId()) + L".partial");

    std::error_code ec;
    // ⚠⚠ 既にあればそのまま使う（v2.4 リリース前レビュー・PR #1303 の Codex P2）。
    // ディレクトリ名は絵のハッシュなので中身は同じ。書き直すと、置き換えに失敗した
    // ときやアップロード中でファイルが開かれているときに `write_failed` になり、
    // 同じ曲の 2 回目からジャケットが付かなくなる。
    if (fs::is_regular_file(file, ec)) {
      PurgeStaleArtwork(tmp, dir);
      return {winrt::to_string(file.wstring()), ""};
    }
    fs::create_directories(dir, ec);
    if (ec) return {"", "write_failed"};
    {
      std::ofstream out(partial, std::ios::binary | std::ios::trunc);
      out.write(reinterpret_cast<const char*>(data.data()),
                static_cast<std::streamsize>(data.size()));
      if (!out) return {"", "write_failed"};
    }
    // 書きかけを読ませない（macOS の `.atomic` と同じ）。
    fs::rename(partial, file, ec);
    if (ec) {
      std::error_code ignored;
      fs::remove(partial, ignored);
      // 同時に書いた別のスレッドが先に置いていれば、それを使う。
      if (!fs::is_regular_file(file, ignored)) return {"", "write_failed"};
    }
    PurgeStaleArtwork(tmp, dir);
    return {winrt::to_string(file.wstring()), ""};
  } catch (...) {
    // 書けなくても曲の文字情報は返す（ジャケットは上積み）。
    return {"", "write_failed"};
  }
}

// SMTC の `Thumbnail` を読み出して書き出す (#1274)。
//
// ⚠ 各段を kArtworkStepTimeout で打ち切る（上の定数の注記）。
ArtworkResult ReadArtwork(
    const GlobalSystemMediaTransportControlsSessionMediaProperties& props) {
  using winrt::Windows::Storage::Streams::DataReader;
  try {
    auto reference = props.Thumbnail();
    if (!reference) return {"", "no_artwork"};

    auto open = reference.OpenReadAsync();
    if (open.wait_for(kArtworkStepTimeout) != AsyncStatus::Completed) {
      open.Cancel();
      return {"", "read_failed"};
    }
    auto stream = open.GetResults();
    const uint64_t size = stream.Size();
    if (size == 0) return {"", "no_artwork"};
    if (size > kArtworkMaxBytes) return {"", "too_large"};

    DataReader reader(stream);
    auto load = reader.LoadAsync(static_cast<uint32_t>(size));
    if (load.wait_for(kArtworkStepTimeout) != AsyncStatus::Completed) {
      load.Cancel();
      return {"", "read_failed"};
    }
    const uint32_t loaded = load.GetResults();
    if (loaded == 0) return {"", "no_artwork"};
    std::vector<uint8_t> data(loaded);
    reader.ReadBytes(data);
    return WriteArtwork(data);
  } catch (...) {
    return {"", "read_failed"};
  }
}

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
  // ジャケット (#1274)。⚠ 書き出さなかった理由も返す (#1283)。返さないと Dart
  // 側の breadcrumb はどれも「源が絵を持っていない」に見え、「付かない」という
  // 報告を切り分けられない。
  const auto artwork = ReadArtwork(props);
  if (!artwork.path.empty()) {
    map[flutter::EncodableValue("artworkPath")] =
        flutter::EncodableValue(artwork.path);
  } else if (!artwork.skipped.empty()) {
    map[flutter::EncodableValue("artworkSkipped")] =
        flutter::EncodableValue(artwork.skipped);
  }
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
