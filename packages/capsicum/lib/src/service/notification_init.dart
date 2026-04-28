import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Initialises local notifications for push-driven delivery.
class NotificationInit {
  static final plugin = FlutterLocalNotificationsPlugin();

  static Future<void> initialize({
    required void Function(NotificationResponse) onTap,
  }) async {
    try {
      const androidSettings = AndroidInitializationSettings(
        '@mipmap/ic_launcher',
      );
      // Darwin (iOS / macOS) は同じ DarwinInitializationSettings を流用できる。
      // macOS 側を渡さないと plugin.initialize が macOS で notification: init
      // failed を返すため、両プラットフォームに同じ設定を渡す (#327)。
      const darwinSettings = DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: true,
        requestSoundPermission: true,
      );
      await plugin.initialize(
        const InitializationSettings(
          android: androidSettings,
          iOS: darwinSettings,
          macOS: darwinSettings,
        ),
        onDidReceiveNotificationResponse: onTap,
      );

      // Request notification permission on Android 13+.
      final androidPlugin = plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      await androidPlugin?.requestNotificationsPermission();
    } catch (e) {
      debugPrint('capsicum: notification: init failed: $e');
    }
  }
}
