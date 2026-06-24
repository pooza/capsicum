#ifndef RUNNER_WIN_TOAST_H_
#define RUNNER_WIN_TOAST_H_

#include <string>

// raw な Windows トースト通知を表示する (#474 フェーズ2)。
//
// WNS raw push を受けて自前で通知を組み立てる経路で使う。アプリ起動中の
// in-process 受信でも、完全終了中の out-of-process バックグラウンドタスクでも、
// 復号・整形済みの title / body からトーストを出す共通部品。Flutter には依存
// せず（バックグラウンドタスクは Flutter エンジンを起こさない）、WinRT の
// `ToastNotificationManager` を直接叩く。
//
// パッケージ ID を持つ起動（MSIX / Microsoft Store）でのみ機能する。呼び出し
// スレッドは WinRT アパートメントが初期化済みであること（SMTC 取得と同じ制約）。
// runner は `_HAS_EXCEPTIONS=0` のため失敗は戻り値 (bool) で表す。
namespace capsicum {

// title / body（いずれも UTF-8）でトーストを表示する。`launch_arg` は通知タップ
// 時にアクティベータへ渡す payload 文字列（capsicum では `{account,type,userId}`
// の JSON を想定。空なら launch 属性を付けない）。`tag` はトーストの差し替え /
// 重複抑止に使う識別子（空可）。
//
// 成功時 true。WinRT 例外・パッケージ ID 無し起動・XML 不正時は false。
bool ShowRawToast(const std::string& title, const std::string& body,
                  const std::string& launch_arg, const std::string& tag);

}  // namespace capsicum

#endif  // RUNNER_WIN_TOAST_H_
