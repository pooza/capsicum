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
import '../widget/notification_tile.dart';

/// Standalone screen with AppBar.
class NotificationScreen extends ConsumerWidget {
  const NotificationScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('通知'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
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
    if (!state.isLoadingMore) {
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
        ref
            .read(notificationMarkerSaverProvider)
            .save(state.notifications[minIndex].id);
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
      final index = notifications.indexWhere((n) => n.id == markerId);
      if (index > 0 && mounted && _itemScrollController.isAttached) {
        _itemScrollController.jumpTo(index: index);
      }
    } catch (_) {
      // Marker fetch failed — silently ignore.
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final notifications = ref.watch(notificationProvider);

    return notifications.when(
      data: (state) {
        if (state.notifications.isEmpty) {
          return const Center(child: Text('通知はありません'));
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
                state.notifications.length + (state.isLoadingMore ? 1 : 0),
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              if (index >= state.notifications.length) {
                return const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(child: CircularProgressIndicator()),
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
      error: (error, stack) => Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('通知の読み込みに失敗しました\n$error', textAlign: TextAlign.center),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () => ref.invalidate(notificationProvider),
                child: const Text('再試行'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
