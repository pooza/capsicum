import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:workmanager/workmanager.dart';

import 'background_notification_service.dart';

const _taskName = 'capsicum.backgroundNotificationCheck';

/// Top-level callback required by workmanager.
@pragma('vm:entry-point')
void backgroundDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    if (taskName == _taskName || taskName == Workmanager.iOSBackgroundTask) {
      await BackgroundNotificationService.checkAllAccounts();
    }
    return true;
  });
}

/// Initialises local notifications and background polling.
class NotificationInit {
  static final plugin = FlutterLocalNotificationsPlugin();

  static Future<void> initialize({
    required void Function(NotificationResponse) onTap,
  }) async {
    try {
      // Local notifications.
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
      final androidPlugin = plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      await androidPlugin?.requestNotificationsPermission();

      // Background polling.
      await Workmanager().initialize(backgroundDispatcher);
      await Workmanager().registerPeriodicTask(
        _taskName,
        _taskName,
        frequency: const Duration(minutes: 15),
        constraints: Constraints(networkType: NetworkType.connected),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
      );
    } catch (e) {
      debugPrint('NotificationInit failed: $e');
    }
  }
}
