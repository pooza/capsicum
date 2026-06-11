import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 起動中二重通知 dedup (#674) の Dart 側終端。
///
/// macOS ネイティブの NotificationDedupPlugin (UNUserNotificationCenter
/// delegate proxy) と双方向に「既出キー」を共有する:
///
/// - Dart → native: WebSocket 経由 (#569) で表示する通知のキーを
///   [addEmitted] で伝える → 後着の APNs banner を native 側が黙殺
/// - native → Dart: APNs が先着して表示済みのキーを [onRemotePresented] で
///   受ける → [DesktopNotificationDispatcher] が同じ通知の emit をスキップ
///
/// キー形式は relay / NSE の account 表現に合わせた
/// `username@host|notificationId`（NSE が復号 payload から stamp する ID と
/// 同じ ID 空間。docs/desktop-notification-design.md §5）。
///
/// native push が配線されているのは macOS だけ (#468。Windows WNS #474 は
/// on-hold) のため、macOS 以外では何もしない。
class NotificationDedupChannel {
  NotificationDedupChannel({@visibleForTesting MethodChannel? channel})
    : _channel =
          channel ??
          const MethodChannel('net.shrieker.capsicum/notification_dedup');

  final MethodChannel _channel;

  /// APNs 先着で native 側が表示済みのキーを受けるコールバック。
  /// [DesktopNotificationDispatcher] が配線する。
  void Function(String key)? onRemotePresented;

  bool get _supported => !kIsWeb && Platform.isMacOS;

  /// native からの逆方向通知を listen し始める。アプリ起動時に 1 回呼ぶ。
  void start() {
    if (!_supported) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onRemotePresented') {
        final key = call.arguments as String?;
        if (key != null) onRemotePresented?.call(key);
      }
    });
  }

  /// WebSocket 側で表示する通知のキーを native の既出集合へ伝える。
  Future<void> addEmitted(String key) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>('addEmitted', key);
    } on PlatformException {
      // proxy 未 install (FLN delegate 不在等の想定外) や呼び出し失敗。
      // dedup は成立しないが、設計上「多重表示の方が落とすより安全」に倒す。
    } on MissingPluginException {
      // 同上。native 側が channel を張れなかったケース。
    }
  }
}

final notificationDedupChannelProvider = Provider<NotificationDedupChannel>(
  (_) => NotificationDedupChannel()..start(),
);
