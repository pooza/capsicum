/// WebSocket 経路 (#569) と Windows の WNS 経路 (#474) が、同じ SNS 通知に
/// ついて同じ OS 通知を指すようにするための識別子導出 (#933)。
///
/// Windows のトーストは Tag が一致すると差し替えになるため、両経路が同じ Tag
/// を使えばプロセスをまたいでも OS 側が畳んでくれる（IPC もミューテックスも
/// 要らない）。ただし `flutter_local_notifications_windows` は Tag を
/// `show()` に渡した int の id から機械的に作る（`ffi_api.cpp` の
/// `notification.Tag(winrt::to_hstring(id))`）ため、SNS の通知 ID 文字列を
/// そのまま Tag にはできない。そこで **両経路が同じ整数を導出する**方向で
/// 揃える。
///
/// `String.hashCode` は Dart 実装依存の値で C++ 側と一致させられないため、
/// FNV-1a (32bit) を明示的に実装する。
///
/// **native 側の `windows/runner/notification_tag.h` と同一のアルゴリズム
/// であること。**片方だけ変えると二重通知が復活する（Tag が食い違って OS が
/// 別の通知として扱う）。変更するときは両方と、双方のテストベクタ
/// (`test/notification_tag_test.dart` /
/// `windows/runner/notification_tag_test.cpp`) を揃えて直すこと。
library;

import 'dart:convert';

/// [key] から 31bit の非負整数を導出する。
///
/// [key] は relay / NSE と同じ ID 空間の `username@host|notificationId`
/// （docs/desktop-notification-design.md §5）。UTF-8 のバイト列に対して
/// 計算するので、native 側の `std::string`（UTF-8）と同じ結果になる。
///
/// 31bit に落としているのは、flutter_local_notifications の id が
/// プラットフォームによって 32bit 符号付きで扱われるため。
int stableNotificationTag(String key) {
  const offsetBasis = 0x811c9dc5;
  const prime = 0x01000193;
  var hash = offsetBasis;
  for (final byte in utf8.encode(key)) {
    hash ^= byte;
    hash = (hash * prime) & 0xffffffff;
  }
  return hash & 0x7fffffff;
}

/// relay / NSE と同じ ID 空間のキーを組む。native 側の
/// `capsicum::NotificationTagKey` と同じ組み立てであること。
String notificationTagKey({
  required String account,
  required String notificationId,
}) => '$account|$notificationId';
