import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'notification_subsystem.dart';

/// 全プラットフォーム共通の flutter_local_notifications ベース実装。
///
/// flutter_local_notifications は Android / iOS / macOS / Linux / Windows を
/// 一通りカバーしているため、抽象層では単一実装で済ませてプラットフォーム
/// 差は内部の Details 構築で吸収する。Linux は libnotify、Windows は
/// Toast XML を使う。アクションボタン等は category マトリクス（将来拡張）で
/// 表現する。
class FlutterLocalNotificationSubsystem implements NotificationSubsystem {
  static const _androidChannelId = 'capsicum_push';
  static const _androidChannelName = 'プッシュ通知';

  final FlutterLocalNotificationsPlugin _plugin;

  FlutterLocalNotificationSubsystem({FlutterLocalNotificationsPlugin? plugin})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  @override
  Future<void> initialize({void Function(String? payload)? onTap}) async {
    try {
      const androidSettings = AndroidInitializationSettings(
        '@mipmap/ic_launcher',
      );
      // Darwin (iOS / macOS) は同じ DarwinInitializationSettings を流用する。
      // macOS 側を渡さないと plugin.initialize が macOS で失敗する (#327)。
      const darwinSettings = DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: true,
        requestSoundPermission: true,
      );
      const linuxSettings = LinuxInitializationSettings(
        defaultActionName: '開く',
      );
      await _plugin.initialize(
        const InitializationSettings(
          android: androidSettings,
          iOS: darwinSettings,
          macOS: darwinSettings,
          linux: linuxSettings,
        ),
        onDidReceiveNotificationResponse: onTap == null
            ? null
            : (response) => onTap(response.payload),
      );

      final androidPlugin = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      await androidPlugin?.requestNotificationsPermission();
    } catch (e) {
      debugPrint('capsicum: notification: init failed: $e');
    }
  }

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
    String? payload,
    NotificationCategory category = NotificationCategory.message,
  }) {
    const androidDetails = AndroidNotificationDetails(
      _androidChannelId,
      _androidChannelName,
      importance: Importance.high,
      priority: Priority.high,
    );
    const iosDetails = DarwinNotificationDetails();
    const linuxDetails = LinuxNotificationDetails();
    const details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
      macOS: iosDetails,
      linux: linuxDetails,
    );
    return _plugin.show(id, title, body, details, payload: payload);
  }

  @override
  Future<bool> requestPermission() async {
    final iosPlugin = _plugin
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >();
    if (iosPlugin != null) {
      return await iosPlugin.requestPermissions(
            alert: true,
            badge: true,
            sound: true,
          ) ??
          false;
    }
    final macOSPlugin = _plugin
        .resolvePlatformSpecificImplementation<
          MacOSFlutterLocalNotificationsPlugin
        >();
    if (macOSPlugin != null) {
      return await macOSPlugin.requestPermissions(
            alert: true,
            badge: true,
            sound: true,
          ) ??
          false;
    }
    final androidPlugin = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (androidPlugin != null) {
      return await androidPlugin.requestNotificationsPermission() ?? false;
    }
    // Linux / Windows は OS 設定に従う。
    return true;
  }
}
