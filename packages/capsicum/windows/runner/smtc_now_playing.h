#ifndef RUNNER_SMTC_NOW_PLAYING_H_
#define RUNNER_SMTC_NOW_PLAYING_H_

#include <flutter/encodable_value.h>

// Windows の System Media Transport Controls (SMTC) から「現在のセッション」の
// 再生情報を取得する (#466 / #484)。GlobalSystemMediaTransportControlsSession-
// Manager の GetCurrentSession() がシステム的にアクティブな再生セッションを
// 返すため、列挙せずにそれを使う。
//
// 戻り値は以下のキーを持つ flutter::EncodableMap:
//   - "title"       : String
//   - "artist"      : String
//   - "albumTitle"  : String
//   - "sourceAppId" : String (SourceAppUserModelId)
//   - "status"      : int (GlobalSystemMediaTransportControlsSessionPlaybackStatus)
// 再生中の曲が無い / 取得失敗時は null (std::monostate) の EncodableValue。
//
// WinRT の非同期 API を STA スレッドで blocking 待ちすると停止しうるため、
// 実装は専用の MTA スレッドで実行する。
flutter::EncodableValue GetCurrentNowPlaying();

#endif  // RUNNER_SMTC_NOW_PLAYING_H_
