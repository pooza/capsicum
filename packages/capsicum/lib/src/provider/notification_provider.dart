import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../service/background_notification_service.dart';
import 'account_manager_provider.dart';
import 'is_cat_provider.dart';
import 'timeline_provider.dart';

/// Paginated notification state.
class NotificationState {
  final List<Notification> notifications;
  final bool isLoadingMore;
  final bool hasMore;

  const NotificationState({
    this.notifications = const [],
    this.isLoadingMore = false,
    this.hasMore = true,
  });

  NotificationState copyWith({
    List<Notification>? notifications,
    bool? isLoadingMore,
    bool? hasMore,
  }) => NotificationState(
    notifications: notifications ?? this.notifications,
    isLoadingMore: isLoadingMore ?? this.isLoadingMore,
    hasMore: hasMore ?? this.hasMore,
  );
}

/// Notifier that manages paginated notification fetching.
class NotificationNotifier extends AutoDisposeAsyncNotifier<NotificationState> {
  static const _pageSize = 20;

  @override
  Future<NotificationState> build() async {
    final adapter = ref.watch(currentAdapterProvider);
    if (adapter == null || adapter is! NotificationSupport) {
      return const NotificationState(hasMore: false);
    }

    var notifications = await (adapter as NotificationSupport).getNotifications(
      query: const TimelineQuery(limit: _pageSize),
    );
    notifications = await ref
        .read(isCatEnricherProvider)
        .enrichNotifications(notifications);
    // Update last-seen ID so background polling skips already-seen items.
    if (notifications.isNotEmpty) {
      _updateLastSeen(notifications.first.id);
    }

    return NotificationState(
      notifications: notifications,
      hasMore: notifications.length >= _pageSize,
    );
  }

  /// Persist the newest notification ID for background polling.
  Future<void> _updateLastSeen(String newestId) async {
    final account = ref.read(currentAccountProvider);
    if (account == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      BackgroundNotificationService.lastSeenKey(account.key.toStorageKey()),
      newestId,
    );
  }

  /// Load next page of notifications (older notifications).
  Future<void> loadMore() async {
    final current = state.valueOrNull;
    if (current == null || current.isLoadingMore || !current.hasMore) return;

    state = AsyncData(current.copyWith(isLoadingMore: true));

    for (var attempt = 0; attempt <= loadMoreMaxRetries; attempt++) {
      try {
        final adapter = ref.read(currentAdapterProvider);
        if (adapter == null || adapter is! NotificationSupport) {
          state = AsyncData(current.copyWith(isLoadingMore: false));
          return;
        }

        final base = state.valueOrNull ?? current;
        final lastId = base.notifications.last.id;
        var older = await (adapter as NotificationSupport).getNotifications(
          query: TimelineQuery(maxId: lastId, limit: _pageSize),
        );
        older = await ref
            .read(isCatEnricherProvider)
            .enrichNotifications(older);

        state = AsyncData(
          base.copyWith(
            notifications: [...base.notifications, ...older],
            isLoadingMore: false,
            hasMore: older.length >= _pageSize,
          ),
        );
        return;
      } catch (_) {
        if (attempt < loadMoreMaxRetries) {
          await Future<void>.delayed(loadMoreRetryDelay);
          continue;
        }
        state = AsyncData(
          (state.valueOrNull ?? current).copyWith(isLoadingMore: false),
        );
      }
    }
  }
}

final notificationProvider =
    AsyncNotifierProvider.autoDispose<NotificationNotifier, NotificationState>(
      NotificationNotifier.new,
    );
