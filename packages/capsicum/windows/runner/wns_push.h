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
//
// `on_presented` は in-process 受信がトーストを表示するたびに、その dedup キー
// (`username@host|notificationId`) を伴って**ワーカースレッド上で**呼ばれる
// (#945)。Dart 側 NotificationDedupChannel の `onRemotePresented` へ渡し、
// WebSocket 経路 (#569) に同じ通知を二重表示させないための合図。
// flutter::MethodChannel はプラットフォーム（UI）スレッド affinity を持つので、
// 呼び出し側が PostMessage で marshal すること。省略時は通知しない
// （dedup は WNS→Dart 方向だけ効かなくなる。表示は従来どおり動く）。
void RunWnsChannelReceiver(
    const std::function<void(const std::string&)>& on_uri,
    const std::function<void(const std::string&)>& on_presented = {});

// flutter_secure_storage の現在の push 鍵セットを LocalState の push_keys.json に
// 再同期する (#474 フェーズ C / Option A)。アプリ起動時 ([RunWnsChannelReceiver]
// 内) に加え、ログアウト・アカウント追加など鍵セットを変更した直後にも呼ぶ
// （Dart の WnsService.syncPushKeys → flutter_window のメソッドチャネル経由）。
// これを怠ると、別プロセスのバックグラウンドタスクがログアウト済みアカウントの
// 古い鍵で push を復号・表示し続け、平文の秘密鍵も次回再起動まで LocalState に
// 残る（他プラットフォームは secure storage から鍵を消すと復号できなくなるのと
// parity を取る）。鍵セットが読めない (.dat 不在・DPAPI 失敗) ときは
// push_keys.json を削除する。書き込みは内部 mutex で直列化されスレッドセーフ。
void SyncWnsPushKeysToLocalState();

// Dart（[NotificationLabelCache] 相当の全アカウントのラベル）が用意した
// push_labels.json 内容を LocalState に書き出す (#770)。in-process 受信 / bg task が
// アカウント別の reblog/post 表示ラベル（リノート / リキュア！等）を読むための
// プロセス跨ぎファイル。push 鍵同期（[SyncWnsPushKeysToLocalState]）と同じ
// LocalState 契約で、Dart の WnsService.syncPushLabels → flutter_window の
// メソッドチャネル経由で呼ぶ。`labels_json` が空（ログイン中アカウント無し等）の
// ときは push_labels.json を削除する。書き込みは内部 mutex で直列化する。
void SyncWnsPushLabelsToLocalState(const std::string& labels_json);

// バックグラウンドタスク (#474 フェーズ C) が LocalState に残した観測レコード
// (push_diag.json) を 1 件読み出してファイルを消す。FullTrust 起動時に呼び、
// 内容（push_diagnostics の単一スロット JSON）を `*out_json` に入れて Dart へ
// 渡す（Dart が Sentry へ吸い上げる）。レコードが無ければ false。
bool ConsumePushDiagnosticsJson(std::string* out_json);

#endif  // RUNNER_WNS_PUSH_H_
