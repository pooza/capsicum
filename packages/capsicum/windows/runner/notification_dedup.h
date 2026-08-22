#ifndef RUNNER_NOTIFICATION_DEDUP_H_
#define RUNNER_NOTIFICATION_DEDUP_H_

#include <cstddef>
#include <deque>
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
  // 保持するキーの上限。超えたぶんは**最古から 1 件ずつ押し出す**（FIFO）。
  //
  // ⚠ **全消しにしてはいけない** (#995)。Dart (#960) / macOS (#983) と同じ理由:
  // このレジストリは「もう出したか」の記録ではなく **表示を抑止するかどうかを
  // 決める判定そのもの**なので、全消しの直後に遅れて届いた通知は「未出」と
  // 判定されて表示され、防いでいるはずの二重表示が復活する。500 件は実況運用の
  // セッションで到達しうる。
  //
  // ⚠ **LRU ではなく FIFO。** 既出キーを再び MarkShown しても順序は動かさない。
  // Dart の `LinkedHashSet` / Swift 版 `BoundedKeySet` と意味を揃えるためで、
  // 片方だけ LRU にすると「同じキーなのに経路ごとに覚えている期間が違う」になる。
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

  // テスト用。上限超過で押し出した累計件数。
  size_t DroppedForTesting();

 private:
  NotificationDedupRegistry() = default;

  // 押し出しの観測。⚠ **プロセスにつき 1 回しか出さない。** 一度あふれた後は
  // 通知が来るたびにあふれ続けるので、件数ぶん出すと同じ事実がログを埋める
  // （Dart 側 [BoundedKeySet] が Sentry 送出を 1 回に絞っているのと同じ判断）。
  //
  // ⚠ **これは OutputDebugString であってユーザー端末からは回収できない。**
  // 本番で「上限に達したか」を知る経路は Dart 側の `push.dedup.evicted`
  // （`DesktopNotificationDispatcher` の 500 件集合が同じ通知で埋まるので
  // ほぼ同時にあふれる）。ここを Sentry に繋ぎ直す必要は無い。
  //
  // ⚠ mutex_ を保持したまま呼ぶ。
  void LogFirstEvictionLocked(size_t evicted);

  std::mutex mutex_;
  std::set<std::string> keys_;

  // 挿入順。keys_ と常に同じ要素を持つ。先頭が最古。
  std::deque<std::string> order_;

  // 上限超過で押し出した累計件数（観測用）。
  size_t dropped_ = 0;

  // LogFirstEvictionLocked を既に出したか。
  bool eviction_logged_ = false;
};

}  // namespace capsicum

#endif  // RUNNER_NOTIFICATION_DEDUP_H_
