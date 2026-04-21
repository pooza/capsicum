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
      const iosSettings = DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: true,
        requestSoundPermission: true,
      );
      await plugin.initialize(
        const InitializationSettings(
          android: androidSettings,
          iOS: iosSettings,
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
