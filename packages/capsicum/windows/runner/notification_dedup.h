#ifndef RUNNER_NOTIFICATION_DEDUP_H_
#define RUNNER_NOTIFICATION_DEDUP_H_

#include <cstddef>
#include <mutex>
#include <set>
#include <string>

namespace capsicum {

// 起動中の二重通知を抑止する「表示済みキー」レジストリ (#945)。
//
// アプリ起動中は、同じ SNS 通知について 2 つの経路がトーストを出しうる:
//
//   1. WNS 経路 (#474) — in-process 受信 (`wns_push.cpp`) が復号して表示
//   2. WebSocket 経路 (#569) — Dart の DesktopNotificationDispatcher が
//      flutter_local_notifications 経由で表示
//
// #933 は「両経路のトースト Tag を同じ導出に揃えて OS に畳ませる」方式を採ったが、
// **実機で畳まれないことが 2026-08-10 に確認された**（Tag / Group / AUMID は
// いずれも一致しているのに 2 通出る・#945）。加えて Tag 方式は畳めたとしても
// **通知音の重複を防げない**（2 通目のトースト自体は作られるため）。
//
// そこで macOS (#674) と同じ「先に出した方が勝つ」方式へ寄せる。両経路がこの
// レジストリに同じキーで claim し、負けた側は**トーストを作らない**。Windows の
// 起動中 WNS 受信は bg task ではなく本体プロセス (`RunWnsChannelReceiver`) が
// 担うため、プロセスを跨ぐ受け渡しは要らない。
//
// キー形式は relay / NSE と同じ `username@host|notificationId`
// （docs/desktop-notification-design.md §5）。組み立ては [NotificationTagKey]。
//
// **アプリ完全終了中の bg task (`push_background_task.cpp`) はこのレジストリを
// 使わない。**別プロセスで動くうえ、そのとき WebSocket 経路は存在しないので
// 競合しない。
class NotificationDedupRegistry {
 public:
  // 保持するキーの上限。超えたら全消しする。
  //
  // ⚠ **この「全消し」は Dart (#960) と macOS (#983) では既に FIFO 追い出しへ
  // 置き換えられており、ここだけ未追随。** 下の「取りこぼしても二重に出るだけ」
  // という理由づけも、#983 が macOS 側で否定したもの: このレジストリは
  // 「もう出したか」の記録ではなく **表示を抑止するかどうかを決める判定そのもの**
  // なので、全消しの直後に遅れて届いた通知は「未出」と判定されて表示され、
  // 防いでいるはずの二重表示が復活する。500 件は実況運用のセッションで到達しうる。
  //
  // ⚠ **正本が食い違っている状態なので、ここを読んで macOS 側へ「全消しでよい」と
  // 逆輸入しないこと。** 追随は Windows 実機ゲートのため pooza/capsicum#995 へ
  // 分離した（`std::set` は挿入順を持たないので `std::deque` の併走が要る）。
  static constexpr size_t kMaxKeys = 500;

  static NotificationDedupRegistry& Instance();

  // このキーの通知を表示したものとして記録する。
  void MarkShown(const std::string& key);

  // このキーの通知が既にどちらかの経路で表示されているか。
  bool WasShown(const std::string& key);

  // テスト用。プロセス内シングルトンの状態を捨てる。
  void Reset();

  // テスト用。保持しているキー数。
  size_t SizeForTesting();

 private:
  NotificationDedupRegistry() = default;

  std::mutex mutex_;
  std::set<std::string> keys_;
};

}  // namespace capsicum

#endif  // RUNNER_NOTIFICATION_DEDUP_H_
