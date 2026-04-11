import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../model/account.dart';
import 'account_manager_provider.dart';

/// A notification paired with the account it belongs to.
class UnifiedNotification {
  final Account account;
  final Notification notification;

  const UnifiedNotification({
    required this.account,
    required this.notification,
  });
}

class UnifiedNotificationState {
  final List<UnifiedNotification> items;
  final List<Account> failedAccounts;

  const UnifiedNotificationState({
    this.items = const [],
    this.failedAccounts = const [],
  });
}

/// Fetches the first page of notifications from every logged-in account in
/// parallel and merges them into a single chronological list. Per-account
/// marker state is left untouched — tapping an item should switch to the
/// owning account and open the existing single-account views.
class UnifiedNotificationNotifier
    extends AutoDisposeAsyncNotifier<UnifiedNotificationState> {
  static const _pageSize = 20;

  @override
  Future<UnifiedNotificationState> build() async {
    final accounts = ref.watch(accountManagerProvider).accounts;
    final supported = accounts
        .where((a) => a.adapter is NotificationSupport)
        .toList();
    if (supported.isEmpty) return const UnifiedNotificationState();

    final results = await Future.wait(
      supported.map(_fetchFor),
      eagerError: false,
    );

    final items = <UnifiedNotification>[];
    final failed = <Account>[];
    for (final result in results) {
      if (result.error != null) {
        failed.add(result.account);
        continue;
      }
      for (final n in result.notifications) {
        items.add(
          UnifiedNotification(account: result.account, notification: n),
        );
      }
    }
    items.sort(
      (a, b) => b.notification.createdAt.compareTo(a.notification.createdAt),
    );

    return UnifiedNotificationState(items: items, failedAccounts: failed);
  }

  Future<_FetchResult> _fetchFor(Account account) async {
    try {
      final notifications = await (account.adapter as NotificationSupport)
          .getNotifications(query: const TimelineQuery(limit: _pageSize));
      return _FetchResult(account: account, notifications: notifications);
    } catch (e) {
      return _FetchResult(account: account, notifications: const [], error: e);
    }
  }
}

class _FetchResult {
  final Account account;
  final List<Notification> notifications;
  final Object? error;

  const _FetchResult({
    required this.account,
    required this.notifications,
    this.error,
  });
}

final unifiedNotificationProvider =
    AsyncNotifierProvider.autoDispose<
      UnifiedNotificationNotifier,
      UnifiedNotificationState
    >(UnifiedNotificationNotifier.new);
