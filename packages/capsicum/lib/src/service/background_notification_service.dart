import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../model/account_key.dart';
import 'account_storage.dart';

/// Polls notifications for all accounts in a background isolate.
///
/// This class does NOT depend on Riverpod, so it can run in the
/// workmanager background dispatcher.
class BackgroundNotificationService {
  static const _lastSeenPrefix = 'capsicum_last_notification_';

  static Future<void> checkAllAccounts() async {
    final storage = AccountStorage();
    final prefs = await SharedPreferences.getInstance();
    final plugin = FlutterLocalNotificationsPlugin();

    final keys = await storage.getAccountKeys();
    var notificationId = prefs.getInt('capsicum_notification_id_counter') ?? 0;

    for (final keyStr in keys) {
      try {
        final secrets = await storage.getSecrets(keyStr);
        if (secrets == null) continue;

        final accountKey = AccountKey.fromStorageKey(keyStr);
        final adapter = await accountKey.type.createAdapter(accountKey.host);

        final userSecret = UserSecret(
          accessToken: secrets['access_token']!,
          refreshToken: secrets['refresh_token'],
        );
        final clientSecret = secrets.containsKey('client_id')
            ? ClientSecretData(
                clientId: secrets['client_id']!,
                clientSecret: secrets['client_secret']!,
              )
            : null;

        await adapter.applySecrets(clientSecret, userSecret);

        if (adapter is! NotificationSupport) continue;

        final lastSeenId = prefs.getString('$_lastSeenPrefix$keyStr');
        final notifications = await (adapter as NotificationSupport)
            .getNotifications(
              query: TimelineQuery(sinceId: lastSeenId, limit: 20),
            );

        if (notifications.isEmpty) continue;

        // Store the newest notification ID.
        await prefs.setString(
          '$_lastSeenPrefix$keyStr',
          notifications.first.id,
        );

        // Show a local notification for each new item.
        for (final n in notifications) {
          await plugin.show(
            notificationId++,
            _buildTitle(n, accountKey),
            _buildBody(n),
            _platformDetails(),
          );
        }
      } catch (_) {
        continue;
      }
    }

    await prefs.setInt('capsicum_notification_id_counter', notificationId);
  }

  static String _buildTitle(Notification n, AccountKey key) {
    final name = n.user?.displayName ?? n.user?.username ?? '???';
    return switch (n.type) {
      NotificationType.mention => '$name さんがあなたに返信しました',
      NotificationType.reblog => '$name さんがブーストしました',
      NotificationType.favourite => '$name さんがお気に入りしました',
      NotificationType.follow => '$name さんにフォローされました',
      NotificationType.followRequest => '$name さんからフォローリクエスト',
      NotificationType.reaction => '$name さんがリアクションしました',
      NotificationType.poll => '投票が終了しました',
      NotificationType.update => '$name さんが投稿を編集しました',
      NotificationType.other => '${key.host} からの通知',
    };
  }

  static String _buildBody(Notification n) {
    if (n.post == null) return '';
    final content = n.post!.content ?? '';
    final plain = content.replaceAll(RegExp(r'<[^>]*>'), '');
    return plain.length > 100 ? '${plain.substring(0, 100)}...' : plain;
  }

  static NotificationDetails _platformDetails() {
    return const NotificationDetails(
      android: AndroidNotificationDetails(
        'capsicum_notifications',
        '通知',
        channelDescription: 'Mastodon / Misskey の通知',
        importance: Importance.high,
        priority: Priority.high,
      ),
      iOS: DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      ),
    );
  }

  /// Key used by both background service and foreground provider.
  static String lastSeenKey(String accountStorageKey) =>
      '$_lastSeenPrefix$accountStorageKey';
}
