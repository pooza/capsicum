import 'dart:async';

import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'account_manager_provider.dart';

/// Unread badge counts for a single account.
class UnreadBadge {
  final int notifications;
  final int announcements;

  const UnreadBadge({this.notifications = 0, this.announcements = 0});

  int get total => notifications + announcements;
  bool get hasUnread => total > 0;
}

/// [adapter] のアカウントの未読を、サーバーの値で引く (#1207)。
///
/// ⚠ **片方が失敗しても、もう片方は出す。**バッジは補助的な表示なので、
/// 取れなかったぶんは 0 として握る（古いサーバーに未読数の口が無い・一時的に
/// 繋がらない、のどちらでも一覧ごと落とさない）。
Future<UnreadBadge> fetchUnreadBadge(
  DecentralizedBackendAdapter adapter,
) async {
  var notifications = 0;
  if (adapter is NotificationUnreadCountSupport) {
    try {
      notifications = await (adapter as NotificationUnreadCountSupport)
          .getUnreadNotificationCount();
    } catch (_) {
      // Non-critical — skip on failure.
    }
  }

  var announcements = 0;
  if (adapter is AnnouncementSupport) {
    try {
      final list = await (adapter as AnnouncementSupport).getAnnouncements();
      announcements = list.where((a) => !a.read).length;
    } catch (_) {
      // Non-critical — skip on failure.
    }
  }

  return UnreadBadge(
    notifications: notifications,
    announcements: announcements,
  );
}

/// Provides unread badge counts for all non-current accounts.
///
/// Returns a map from account storage key to [UnreadBadge].
/// Refreshes periodically (every 30 seconds) so the drawer stays current.
///
/// ⚠ **通知の未読数はサーバーの値** (#1207)。クライアント側では数えない。
/// v1.19 で workmanager / iOS BGTask 経路を撤去してから常に 0 だった欄を、
/// サーバーへの問い合わせで埋め直した。値が減るのは、capsicum が既読を
/// サーバーへ返しているから（Mastodon は marker・Misskey は #1205）。
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

    final badges = <String, UnreadBadge>{};

    for (final account in otherAccounts) {
      final badge = await fetchUnreadBadge(account.adapter);
      if (badge.hasUnread) {
        badges[account.key.toStorageKey()] = badge;
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
