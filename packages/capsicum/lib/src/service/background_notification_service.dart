import 'package:shared_preferences/shared_preferences.dart';

/// Shared storage keys for per-account notification state.
///
/// Previously populated by the workmanager background dispatcher, which was
/// removed in #348 now that push delivery goes through the APNs / FCM relay.
/// The key helpers remain so that the foreground providers and (eventually)
/// the push receive path can read / write the same shared-preferences slots.
class BackgroundNotificationService {
  static const _lastSeenPrefix = 'capsicum_last_notification_';
  static const _unreadCountPrefix = 'capsicum_unread_notification_count_';

  /// Key used to remember the newest notification id observed for an account.
  static String lastSeenKey(String accountStorageKey) =>
      '$_lastSeenPrefix$accountStorageKey';

  /// Key for the unread notification count of an account.
  static String unreadCountKey(String accountStorageKey) =>
      '$_unreadCountPrefix$accountStorageKey';

  /// Clear unread notification count for the given account.
  static Future<void> clearUnreadCount(String accountStorageKey) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_unreadCountPrefix$accountStorageKey');
  }
}
