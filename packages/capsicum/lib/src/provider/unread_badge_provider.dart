import 'dart:async';

import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../service/background_notification_service.dart';
import 'account_manager_provider.dart';

/// Unread badge counts for a single account.
class UnreadBadge {
  final int notifications;
  final int announcements;

  const UnreadBadge({this.notifications = 0, this.announcements = 0});

  int get total => notifications + announcements;
  bool get hasUnread => total > 0;
}

/// Provides unread badge counts for all non-current accounts.
///
/// Returns a map from account storage key to [UnreadBadge].
/// Refreshes periodically (every 30 seconds) so the drawer stays current.
class UnreadBadgeNotifier
    extends AutoDisposeAsyncNotifier<Map<String, UnreadBadge>> {
  Timer? _refreshTimer;

  @override
  Future<Map<String, UnreadBadge>> build() async {
    final accountState = ref.watch(accountManagerProvider);
    final current = accountState.current;
    final otherAccounts = accountState.accounts
        .where((a) => a.key != current?.key)
        .toList();

    _refreshTimer?.cancel();
    _refreshTimer = null;

    if (otherAccounts.isEmpty) return const {};

    // Set up periodic refresh.
    _refreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      ref.invalidateSelf();
    });
    ref.onDispose(() => _refreshTimer?.cancel());

    final prefs = await SharedPreferences.getInstance();
    final badges = <String, UnreadBadge>{};

    for (final account in otherAccounts) {
      final storageKey = account.key.toStorageKey();

      // Notification count from background service.
      final notifCount =
          prefs.getInt(
            BackgroundNotificationService.unreadCountKey(storageKey),
          ) ??
          0;

      // Announcement count from server.
      var announcementCount = 0;
      final adapter = account.adapter;
      if (adapter is AnnouncementSupport) {
        try {
          final announcements = await (adapter as AnnouncementSupport)
              .getAnnouncements();
          announcementCount = announcements.where((a) => !a.read).length;
        } catch (_) {
          // Non-critical — skip on failure.
        }
      }

      if (notifCount > 0 || announcementCount > 0) {
        badges[storageKey] = UnreadBadge(
          notifications: notifCount,
          announcements: announcementCount,
        );
      }
    }

    return badges;
  }
}

final unreadBadgeProvider =
    AsyncNotifierProvider.autoDispose<
      UnreadBadgeNotifier,
      Map<String, UnreadBadge>
    >(UnreadBadgeNotifier.new);
