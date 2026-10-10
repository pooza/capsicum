import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../service/background_notification_service.dart';
import '../util/conversion_skip_report.dart';
import 'account_manager_provider.dart';
import 'is_cat_provider.dart';
import 'preferences_provider.dart';
import 'timeline_provider.dart';

/// 追加で読んだページ [older] から、既に [shown] に出ているグループを落とす
/// (#1251)。
///
/// ⚠ **Mastodon のグループ化は、同じ `group_key` のグループをページを跨いで
/// 2 回返しうる**（1 時間に 20 グループ超が動くアカウントで起きる）。そのまま
/// 足すと同じグループが 2 行並び、件数も重なる。
///
/// ⚠ **残すのは先に出ているほう**（新しい側）。WebUI も同じキーのグループは
/// 1 つにまとめる。件数は先に出ているグループの値をそのまま使う —— 後の
/// ページの値を足すと、サーバーが同じ通知を両方に数えているぶん二重になる。
///
/// ⚠ グループ化していない通知（`groupKey == null`）は対象外。id の重複は
/// カーソルの歯止め（下の `stalled`）が見る。
List<Notification> dropAlreadyShownGroups(
  List<Notification> shown,
  List<Notification> older,
) {
  final seen = <String>{
    for (final n in shown)
      if (n.groupKey != null) n.groupKey!,
  };
  return [
    for (final n in older)
      // 同じページの中で重なっていても 1 つにする。
      if (n.groupKey == null || seen.add(n.groupKey!)) n,
  ];
}

/// 手元で絞ったページのあと、次の追加読み込みまで置く間 (#1251)。
///
/// ⚠ **古い Misskey で種別を外していると、20 件取って数件しか残らないページが
/// 続く。**追加読み込みの起点は「一覧の末尾が近い」ことなので、行が増えない
/// あいだ連鎖して打ち続ける。`i/notifications-grouped` の流量制限は
/// 30 回 / 30 秒なので、1 回あたり 1 秒を超える間を置けば届かない。
const locallyFilteredLoadMoreInterval = Duration(milliseconds: 1500);

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

  /// 絞り込みとグループ化 (#1042 / #1048)。
  ///
  /// ⚠ **build() では `watch`、loadMore() では `read`。**build で watch して
  /// いるので、設定が変わると一覧は先頭から取り直しになる（絞り込みを変えた
  /// のに古いページが混ざったままにしない）。
  NotificationQuery _filter({required bool watch}) => NotificationQuery(
    excludeTypes: watch
        ? ref.watch(notificationExcludedTypesProvider)
        : ref.read(notificationExcludedTypesProvider),
    grouped: watch
        ? ref.watch(notificationGroupingProvider)
        : ref.read(notificationGroupingProvider),
  );

  /// 直前に読んだページが、手元で絞ったものだったか (#1251)。
  bool _lastPageFilteredLocally = false;

  /// 「サーバーが除外を断った」を記録済みか。⚠ ページごとに出さない。
  bool _localFilterReported = false;

  void _noteLocalFilter(NotificationResponse response) {
    _lastPageFilteredLocally = response.filteredLocally;
    if (!response.filteredLocally || _localFilterReported) return;
    _localFilterReported = true;
    // ⚠ **記録に残す。**どのサーバーで手元の絞り込みに倒れているかが、これが
    // 無いと分からない（release では Sentry の breadcrumb になり、host は
    // イベントのタグで分かる）。
    debugPrint(
      'notification: server rejected the exclude filter; filtering locally',
    );
  }

  @override
  Future<NotificationState> build() async {
    _lastPageFilteredLocally = false;
    _localFilterReported = false;
    final adapter = ref.watch(currentAdapterProvider);
    if (adapter == null || adapter is! NotificationSupport) {
      return const NotificationState(hasMore: false);
    }

    final response = await (adapter as NotificationSupport).getNotifications(
      query: const TimelineQuery(limit: _pageSize),
      filter: _filter(watch: true),
    );
    reportSkippedNotifications(response.skippedPosts, source: 'notification');
    _noteLocalFilter(response);
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
      //
      // ⚠⚠ **グループ化した取得では件数で判定できない** (#1048)。アダプタが
      // 判断できるときはそちらに従う（理由は [NotificationResponse.hasMore]）。
      hasMore: response.hasMore ?? response.rawCount >= _pageSize,
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

    // 手元で絞ったページが続いているあいだは、間を置いてから読む (#1251)。
    // 理由は [locallyFilteredLoadMoreInterval]。
    if (_lastPageFilteredLocally) {
      await Future<void>.delayed(locallyFilteredLoadMoreInterval);
    }

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
              filter: _filter(watch: false),
            );
        reportSkippedNotifications(
          response.skippedPosts,
          source: 'notification.loadMore',
          maxId: lastId,
        );
        _noteLocalFilter(response);
        // 追加読み込みも同じ扱い (#1080)。ここで止まるとスクロールが刺さる。
        final older = await ref
            .read(isCatEnricherProvider)
            .enrichNotifications(response.notifications);

        // ⚠⚠ **カーソルが進まなかったら打ち切る** (#1048)。グループ化した経路の
        // `hasMore` は「ページが空でなければ続きがありうる」なので、サーバーが
        // 同じページを返し続けると**スクロールのたびに同じ通知を足し続ける**。
        // 件数での判定と違い、ここが最後の歯止めになる。
        final nextRawId = response.rawLastId ?? base.lastRawId;
        final stalled = nextRawId == lastId;
        state = AsyncData(
          base.copyWith(
            notifications: stalled
                ? base.notifications
                : [
                    ...base.notifications,
                    ...dropAlreadyShownGroups(base.notifications, older),
                  ],
            isLoadingMore: false,
            lastRawId: nextRawId,
            hasMore:
                !stalled &&
                (response.hasMore ?? response.rawCount >= _pageSize),
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
      dependencies: [
        currentAdapterProvider,
        isCatEnricherProvider,
        currentAccountProvider,
      ],
    );
