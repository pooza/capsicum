import 'dart:async';

import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart' hide Notification;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../../provider/account_manager_provider.dart';
import '../../provider/marker_provider.dart';
import '../../provider/notification_provider.dart';
import '../../provider/server_config_provider.dart';
import '../../service/background_notification_service.dart';
import '../util/op_error.dart';
import '../widget/bottom_safe_area.dart';
import '../widget/notification_filter_button.dart';
import '../widget/notification_tile.dart';
import '../widget/retry_error_view.dart';
import '../widget/timeline_older_prompt.dart';

/// Standalone screen with AppBar.
class NotificationScreen extends ConsumerWidget {
  const NotificationScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('通知'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        // 種別の絞り込み (#1042)。⚠ **設定はアプリ全体で 1 つ**なので、ここと
        // ホームの通知タブ・「すべての通知」・デッキのカラム見出しは同じ値を
        // 出し入れする。
        actions: const [NotificationFilterButton()],
      ),
      // 下端 inset は [NotificationView] が自分で吸う。ここでは包まない
      // （包んでも [BottomSafeArea] は冪等なので壊れないが、吸う場所が
      // 2 つあると「どちらかを直せば足りる」と読まれる）。
      body: const NotificationView(),
    );
  }
}

/// Reusable body widget for embedding as a home-screen tab.
class NotificationView extends ConsumerStatefulWidget {
  const NotificationView({super.key});

  @override
  ConsumerState<NotificationView> createState() => _NotificationViewState();
}

class _NotificationViewState extends ConsumerState<NotificationView>
    with AutomaticKeepAliveClientMixin {
  final _itemScrollController = ItemScrollController();
  final _itemPositionsListener = ItemPositionsListener.create();
  bool _markerRestored = false;
  Timer? _throttleTimer;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _itemPositionsListener.itemPositions.addListener(_onPositionsChanged);
    // ⚠⚠ **保存役を、この画面が生きている間は保持する**（PR #1256 の Codex P2）。
    // どちらも autoDispose で、`ref.read` だけでは数フレームのうちに破棄される
    // （実測）。破棄は待っていた保存をその場で流すので、**5 秒の間引きも、
    // 覚えている位置（古いほうへ戻さない / 同じ先頭で呼び直さない）も効かず、
    // 位置の通知が来るたびにサーバーへ送っていた。**
    ref.listenManual(notificationMarkerSaverProvider, (_, _) {});
    ref.listenManual(notificationReadSaverProvider, (_, _) {});

    // Clear unread notification count for the current account.
    final account = ref.read(currentAccountProvider);
    if (account != null) {
      BackgroundNotificationService.clearUnreadCount(
        account.key.toStorageKey(),
      );
    }
  }

  @override
  void dispose() {
    _itemPositionsListener.itemPositions.removeListener(_onPositionsChanged);
    _throttleTimer?.cancel();
    super.dispose();
  }

  void _onPositionsChanged() {
    if (_throttleTimer?.isActive ?? false) return;
    _throttleTimer = Timer(const Duration(milliseconds: 200), () {});

    final positions = _itemPositionsListener.itemPositions.value;
    if (positions.isEmpty) return;

    final state = ref.read(notificationProvider).valueOrNull;
    if (state == null) return;

    // Load more when near the end.
    // ⚠ 続き読みが失敗し続けているあいだは自動では叩かない（TL と同じ・#678 /
    // #1293）。回復は引っ張って更新か、末尾の入口から手で。
    if (!state.isLoadingMore && state.loadMoreError == null) {
      final maxIndex = positions
          .map((p) => p.index)
          .reduce((a, b) => a > b ? a : b);
      if (maxIndex >= state.notifications.length - 8) {
        ref.read(notificationProvider.notifier).loadMore();
      }
    }

    // Save notification marker (debounced).
    final adapter = ref.read(currentAdapterProvider);
    if (adapter is MarkerSupport) {
      final minIndex = positions
          .map((p) => p.index)
          .reduce((a, b) => a < b ? a : b);
      if (minIndex < state.notifications.length) {
        // ⚠ 先頭が見えているときは、絞り込みで伏せた分も含めた一番新しい通知
        // まで既読にする（伏せた通知が未読のまま残る・#1291 のレビュー）。
        final id = minIndex == 0
            ? state.rawNewestId ?? state.notifications.first.id
            : state.notifications[minIndex].id;
        ref.read(notificationMarkerSaverProvider).save(id);
      }
    } else if (adapter is NotificationReadSupport &&
        state.notifications.isNotEmpty) {
      // 位置を持たないバックエンド（Misskey）は、一番新しい通知が見えたときに
      // 全既読を返す (#1205)。⚠ **先頭が見えていない間は返さない** —— 途中から
      // 読んでいる利用者の、まだ見ていない新着まで既読にしてしまう。
      // ⚠ 先頭から離れたら、まだ返していない予約も取り消す。
      final saver = ref.read(notificationReadSaverProvider);
      if (positions.any((p) => p.index == 0)) {
        saver.markSeen(state.notifications.first.id);
      } else {
        saver.unsee();
      }
    }
  }

  Future<void> _restoreMarker(List<Notification> notifications) async {
    if (_markerRestored) return;
    _markerRestored = true;

    final adapter = ref.read(currentAdapterProvider);
    if (adapter == null || adapter is! MarkerSupport) return;

    try {
      final markers = await (adapter as MarkerSupport).getMarkers();
      if (markers.notifications == null) return;

      final markerId = markers.notifications!.lastReadId;
      // ⚠ サーバーの位置より古いほうへは保存し直さない（未読の数が増える）。
      if (mounted) {
        ref.read(notificationMarkerSaverProvider).noteServerMarker(markerId);
      }
      final index = notifications.indexWhere((n) => n.id == markerId);
      if (index > 0 && mounted && _itemScrollController.isAttached) {
        _itemScrollController.jumpTo(index: index);
      }
    } catch (_) {
      // Marker fetch failed — silently ignore.
    }
  }

  /// 伏せた通知だけのページが上限まで続き、まだ続きがある（PR #1285 の Codex P1）。
  /// ⚠ 続き読みが再試行しても失敗したときも出す（v2.4 リリース前レビュー）。
  /// 失敗の間は位置の変化での自動の続き読みを止めるので、入口が無いと一覧が
  /// 黙ってそこで終わり、「これより古い通知は無い」ように見える。
  static bool _showOlderPrompt(NotificationState state) =>
      state.hasMore &&
      !state.isLoadingMore &&
      (state.pageCapHit || state.loadMoreError != null);

  static const _olderMessage = '絞り込みで多くの通知が除外されています';
  static const _olderAction = 'さらに古い通知を探す';
  static const _olderFailedMessage = '古い通知を読み込めませんでした';
  static const _olderFailedAction = '再読み込み';

  void _loadOlder() => ref.read(notificationProvider.notifier).loadMore();

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final notifications = ref.watch(notificationProvider);

    // ⚠ **下端 inset を吸うのは画面側ではなく View 側**。この View には
    // ホストが 2 つある — 単独画面 [NotificationScreen] と、ホームの通知タブ
    // (`home_screen.dart` の `_buildTabContent`)。#1037 では単独画面の
    // `Scaffold.body` だけを包んだので、**導線の多いホームのタブに穴が
    // 残っていた**（`withBackground(const NotificationView())` は
    // `SimplePostBar` を持つ Column へ落ちる前に早期 return する）。
    //
    // ⚠ 中身が [ScrollablePositionedList] なので、**`ListView` の暗黙吸収は
    // 効かない。**`BoxScrollView` は `padding` 未指定なら `MediaQuery` の
    // 縦 padding を自動で足すが、`ScrollablePositionedList` は
    // `widget.padding` しか見ない（`positioned_list.dart`）。隣の
    // `AnnouncementView` が同じ構造なのに無事なのは、あちらが素の
    // `ListView.separated` で暗黙吸収に乗っているからにすぎない。
    //
    // 共有 View は自分で吸う、が [ChannelTimelineView] と揃えた形。
    return BottomSafeArea(
      child: notifications.when(
        data: (state) {
          if (state.notifications.isEmpty) {
            // ⚠ 伏せた通知だけで空になっていて続きがあるときは、手で先を引ける
            // 入口を出す（PR #1285 の Codex P1）。空の一覧はスクロールできない。
            return TimelineEmptyOrOlder(
              hasMore: state.hasMore,
              isLoadingMore: state.isLoadingMore,
              onLoadOlder: _loadOlder,
              emptyText: '通知はありません',
              message: _olderMessage,
              actionLabel: _olderAction,
            );
          }
          _restoreMarker(state.notifications);
          return RefreshIndicator(
            onRefresh: () {
              _markerRestored = false;
              return ref.refresh(notificationProvider.future);
            },
            child: ScrollablePositionedList.separated(
              itemScrollController: _itemScrollController,
              itemPositionsListener: _itemPositionsListener,
              itemCount:
                  state.notifications.length +
                  olderTailCount(
                    isLoadingMore: state.isLoadingMore,
                    stalled: _showOlderPrompt(state),
                  ),
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                if (index >= state.notifications.length) {
                  // 伏せた通知だけのページが上限まで続いたときか、続き読みが
                  // 失敗したときの入口。何も足されないと一覧の長さが変わらず、
                  // 続き読みの合図が来ない。
                  final failed = state.loadMoreError != null;
                  return TimelineOlderTail(
                    isLoadingMore: state.isLoadingMore,
                    onLoadOlder: _loadOlder,
                    message: failed ? _olderFailedMessage : _olderMessage,
                    actionLabel: failed ? _olderFailedAction : _olderAction,
                  );
                }
                return NotificationTile(
                  notification: state.notifications[index],
                  postLabel: ref.watch(postLabelProvider),
                  reblogLabel: ref.watch(reblogLabelProvider),
                );
              },
            ),
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) => RetryErrorView(
          message: '通知の読み込みに失敗しました\n${summarizeOpError(error)}',
          isRetrying: notifications.isLoading,
          onRetry: () => ref.invalidate(notificationProvider),
        ),
      ),
    );
  }
}
