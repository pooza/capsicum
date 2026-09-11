import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../service/background_notification_service.dart';
import '../util/conversion_skip_report.dart';
import 'account_manager_provider.dart';
import 'is_cat_provider.dart';
import 'timeline_provider.dart';

/// Paginated notification state.
class NotificationState {
  final List<Notification> notifications;
  final bool isLoadingMore;
  final bool hasMore;

  /// The oldest raw notification ID seen so far, before client-side skipping.
  /// Used as the pagination cursor so that skipped (malformed) trailing items
  /// don't stall pagination by re-fetching the same page (#777).
  final String? lastRawId;

  const NotificationState({
    this.notifications = const [],
    this.isLoadingMore = false,
    this.hasMore = true,
    this.lastRawId,
  });

  NotificationState copyWith({
    List<Notification>? notifications,
    bool? isLoadingMore,
    bool? hasMore,
    String? lastRawId,
  }) => NotificationState(
    notifications: notifications ?? this.notifications,
    isLoadingMore: isLoadingMore ?? this.isLoadingMore,
    hasMore: hasMore ?? this.hasMore,
    lastRawId: lastRawId ?? this.lastRawId,
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

    final response = await (adapter as NotificationSupport).getNotifications(
      query: const TimelineQuery(limit: _pageSize),
    );
    reportSkippedNotifications(response.skippedPosts, source: 'notification');
    // ⚠ **猫耳のために通知一覧の表示を止めない (#1080)。**理由と仕組みは
    // `is_cat_provider.dart` の [kIsCatEnrichBudget] の doc が正本。
    // ⚠ **待ち上限は enricher の中で掛かる (#1083-C)。**以前はこの 4 箇所が
    // それぞれ `.timeout` を書いており、超過がどこでも計装されていなかった。
    final notifications = await ref
        .read(isCatEnricherProvider)
        .enrichNotifications(response.notifications);
    // Update last-seen ID so background polling skips already-seen items.
    if (notifications.isNotEmpty) {
      _updateLastSeen(notifications.first.id);
    }

    return NotificationState(
      notifications: notifications,
      lastRawId: response.rawLastId,
      // Judge "more pages" on the raw server count, not the post-skip list
      // length: skipping a malformed notification must not drop a full page
      // (19 < 20) and stall pagination (#777).
      hasMore: response.rawCount >= _pageSize,
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
        // Advance the cursor by the oldest *raw* ID, not the last converted
        // notification's ID: if trailing items were skipped, the converted
        // last ID would re-fetch the same page (#777). Fall back to the
        // converted last ID for older adapters / first page without a raw ID.
        final lastId =
            base.lastRawId ??
            (base.notifications.isNotEmpty ? base.notifications.last.id : null);
        if (lastId == null) {
          state = AsyncData(
            base.copyWith(isLoadingMore: false, hasMore: false),
          );
          return;
        }
        final response = await (adapter as NotificationSupport)
            .getNotifications(
              query: TimelineQuery(maxId: lastId, limit: _pageSize),
            );
        reportSkippedNotifications(
          response.skippedPosts,
          source: 'notification.loadMore',
          maxId: lastId,
        );
        // 追加読み込みも同じ扱い (#1080)。ここで止まるとスクロールが刺さる。
        final older = await ref
            .read(isCatEnricherProvider)
            .enrichNotifications(response.notifications);

        state = AsyncData(
          base.copyWith(
            notifications: [...base.notifications, ...older],
            isLoadingMore: false,
            lastRawId: response.rawLastId ?? base.lastRawId,
            hasMore: response.rawCount >= _pageSize,
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
