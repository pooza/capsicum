#ifndef RUNNER_WNS_PUSH_H_
#define RUNNER_WNS_PUSH_H_

#include <functional>
#include <string>

// Windows Notification Service (WNS) の Channel URI 取得 + 起動中 (in-process)
// raw 通知受信を回す (#474 フェーズ1 + フェーズ3)。
//
// `PushNotificationChannelManager::CreatePushNotificationChannelForApplication-
// Async()` で channel を取得し、その URI を `on_uri` に 1 度だけ渡す
// （capsicum-relay はこの URI を device token とみなし WNS へ raw 通知を POST
// する）。続けて channel の `PushNotificationReceived` を購読し、raw 通知を受け
// たら復号 → トースト表示する（完全終了中のバックグラウンドタスクと同じ
// web_push_receive → win_toast 経路を共有）。
//
// 購読を維持するため channel と MTA アパートメントを生かし続ける必要があり、
// 本関数は購読後プロセス終了までブロックする。よって呼び出し側は専用の detached
// スレッドで実行すること（WinRT の取得を STA でブロックすると停止しうるため
// 内部で MTA アパートメントを初期化する）。
//
// `on_uri` は本関数のワーカースレッド上で必ず 1 度呼ばれる（取得不可時は空
// 文字列）。channel を取得できない起動（パッケージ ID 無しの非 MSIX 起動・
// ネットワーク不通・WinRT 例外）では `on_uri("")` を呼んで即 return する。
void RunWnsChannelReceiver(
    const std::function<void(const std::string&)>& on_uri);

// バックグラウンドタスク (#474 フェーズ C) が LocalState に残した観測レコード
// (push_diag.json) を 1 件読み出してファイルを消す。FullTrust 起動時に呼び、
// 内容（push_diagnostics の単一スロット JSON）を `*out_json` に入れて Dart へ
// 渡す（Dart が Sentry へ吸い上げる）。レコードが無ければ false。
bool ConsumePushDiagnosticsJson(std::string* out_json);

#endif  // RUNNER_WNS_PUSH_H_
