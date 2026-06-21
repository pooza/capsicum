#ifndef RUNNER_WNS_PUSH_H_
#define RUNNER_WNS_PUSH_H_

#include <string>

// Windows Notification Service (WNS) の Channel URI を取得する (#474 フェーズ1)。
//
// `PushNotificationChannelManager::CreatePushNotificationChannelForApplication-
// Async()` を MTA スレッド上で blocking 取得する純粋部分。capsicum-relay は
// この URI を device token とみなし、WNS へ raw 通知を POST する。
//
// 戻り値は Channel URI 文字列。取得失敗時（パッケージ ID 無しの非 MSIX 起動・
// ネットワーク不通・WinRT 例外）は空文字列を返す。MSIX / Microsoft Store 版の
// ようにパッケージ ID を持つ起動でのみ URI を払い出せる。
//
// WinRT の非同期 API を STA でブロックすると停止しうるため、呼び出し側は必ず
// 専用の MTA ワーカースレッドから呼ぶこと（SMTC 取得と同じ制約）。
std::string QueryWnsChannelUri();

#endif  // RUNNER_WNS_PUSH_H_
