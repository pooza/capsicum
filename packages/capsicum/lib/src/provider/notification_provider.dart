import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'account_manager_provider.dart';

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
  }) =>
      NotificationState(
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

    final notifications = await (adapter as NotificationSupport).getNotifications(
      query: const TimelineQuery(limit: _pageSize),
    );
    return NotificationState(
      notifications: notifications,
      hasMore: notifications.length >= _pageSize,
    );
  }

  /// Load next page of notifications (older notifications).
  Future<void> loadMore() async {
    final current = state.valueOrNull;
    if (current == null || current.isLoadingMore || !current.hasMore) return;

    state = AsyncData(current.copyWith(isLoadingMore: true));

    try {
      final adapter = ref.read(currentAdapterProvider);
      if (adapter == null || adapter is! NotificationSupport) return;

      final lastId = current.notifications.last.id;
      final older = await (adapter as NotificationSupport).getNotifications(
        query: TimelineQuery(maxId: lastId, limit: _pageSize),
      );

      state = AsyncData(
        current.copyWith(
          notifications: [...current.notifications, ...older],
          isLoadingMore: false,
          hasMore: older.length >= _pageSize,
        ),
      );
    } catch (e, st) {
      state = AsyncData(current.copyWith(isLoadingMore: false));
      throw AsyncError(e, st);
    }
  }
}

final notificationProvider =
    AsyncNotifierProvider.autoDispose<NotificationNotifier, NotificationState>(
  NotificationNotifier.new,
);
