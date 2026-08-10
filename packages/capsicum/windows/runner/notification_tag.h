#ifndef RUNNER_NOTIFICATION_TAG_H_
#define RUNNER_NOTIFICATION_TAG_H_

#include <cstdint>
#include <string>

// WebSocket 経路 (#569) と WNS 経路 (#474) が、同じ SNS 通知について同じ
// トーストを指すようにするための Tag 導出 (#933)。
//
// Windows のトーストは Tag が一致すると差し替えになるため、両経路が同じ Tag
// を使えばプロセスをまたいでも OS 側が畳む（IPC もミューテックスも要らない）。
// WebSocket 経路は flutter_local_notifications 経由で表示するが、その
// Windows 実装は Tag を show() に渡した int の id から機械的に作る
// (`ffi_api.cpp` の `notification.Tag(winrt::to_hstring(id))`) ため、SNS の
// 通知 ID 文字列をそのまま Tag にできない。そこで **両経路が同じ整数を導出
// する**方向で揃える。
//
// **Dart 側の lib/src/service/notification_tag.dart と同一のアルゴリズムで
// あること。**片方だけ変えると Tag が食い違い、二重通知が復活する。変更する
// ときは両方と、双方のテストベクタ (notification_tag_test.cpp /
// test/notification_tag_test.dart) を揃えて直すこと。
namespace capsicum {

// FNV-1a (32bit) を UTF-8 バイト列に掛け、31bit の非負整数に落とす。
// Dart の String.hashCode は実装依存で C++ と一致させられないため、明示的な
// アルゴリズムを両側に置いている。
uint32_t StableNotificationTag(const std::string& key);

// relay / NSE と同じ ID 空間のキー `username@host|notificationId` を組む
// (docs/desktop-notification-design.md §5)。Dart 側の notificationTagKey と
// 同じ組み立て。
std::string NotificationTagKey(const std::string& account,
                               const std::string& notification_id);

// [NotificationTagKey] + [StableNotificationTag] を通し、トーストの Tag に
// そのまま渡せる 10 進文字列を返す。flutter_local_notifications 側が
// `to_hstring(int)` で作る Tag と一致する表現。
//
// **notification_id が空なら空文字を返す**（#956）。Tag が一致するトーストは
// OS が差し替えるので、ID を持たない払い出しで `hash("account|")` を返すと
// **そのアカウント宛が全部同じ Tag になり、Action Center に最後の 1 件しか
// 残らない**。ShowRawToast は空 Tag を「Tag を付けない」と解釈する
// (`win_toast.cpp` の `if (!tag.empty())`) ので、#933 以前と同じ「畳まない」
// 挙動に戻る。畳めないのは取りこぼしだが、消えるより軽い。
//
// ⚠ [NotificationTagKey] は**空に正規化しない**。あちらは dedup レジストリの
// キーで、空文字にすると「キー無し」と区別できなくなる。ID が無いときに
// dedup を通さない判断は呼び出し側にある（`wns_push.cpp` の `dedupable`）。
std::string NotificationTagFor(const std::string& account,
                               const std::string& notification_id);

}  // namespace capsicum

#endif  // RUNNER_NOTIFICATION_TAG_H_
