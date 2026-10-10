import 'dart:async';

import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/provider/notification_provider.dart';
import 'package:capsicum/src/util/shared_preferences_cache.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #1048: グループ化した取得のページング。
///
/// ⚠⚠ **件数で最終ページを判定できない**（サーバーの `limit` は通知の件数に
/// 掛かるのに返るのはグループの件数）ので、`hasMore` はアダプタが決める。その
/// 代わり「サーバーが同じページを返し続ける」ときの歯止めが要る。
class _Adapter extends Mock implements DecentralizedBackendAdapter {}

/// `getNotifications` の応答を順に返すアダプタ。
class _ScriptedAdapter extends _Adapter implements NotificationSupport {
  _ScriptedAdapter(this.pages);

  final List<NotificationResponse> pages;
  final List<String?> requestedMaxIds = [];
  int _index = 0;

  @override
  Set<NotificationType> get filterableNotificationTypes => const {
    NotificationType.mention,
  };

  @override
  Future<void> clearAllNotifications() async {}

  @override
  Future<NotificationResponse> getNotifications({
    TimelineQuery? query,
    NotificationQuery? filter,
  }) async {
    requestedMaxIds.add(query?.maxId);
    final page = pages[_index.clamp(0, pages.length - 1)];
    _index++;
    return page;
  }
}

Notification _notification(String id) => Notification(
  id: id,
  type: NotificationType.favourite,
  createdAt: DateTime.utc(2026, 9, 27),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(const {});
    initSharedPreferencesCache(await SharedPreferences.getInstance());
  });

  Future<(ProviderContainer, _ScriptedAdapter)> containerFor(
    List<NotificationResponse> pages,
  ) async {
    final adapter = _ScriptedAdapter(pages);
    final container = ProviderContainer(
      overrides: [
        // ⚠ account を null にすると `isCatEnricherProvider` が無害な
        // エンリッチャを返し、`_updateLastSeen` も早期 return する。
        currentAccountProvider.overrideWithValue(null),
        currentAdapterProvider.overrideWithValue(adapter),
      ],
    );
    addTearDown(container.dispose);
    await container.read(notificationProvider.future);
    return (container, adapter);
  }

  test('⚠ グループが 1 件でも続きがあると言われたら続きを読む', () async {
    final (container, _) = await containerFor([
      NotificationResponse(
        notifications: [_notification('9020')],
        rawCount: 1,
        rawLastId: '9001',
        hasMore: true,
      ),
    ]);
    final state = container.read(notificationProvider).requireValue;
    expect(
      state.hasMore,
      isTrue,
      reason: '20 件のリアクションが 1 グループに畳まれただけ。件数で切ると読み止まる',
    );
  });

  test('アダプタが hasMore を返さなければ従来どおり件数で判定する', () async {
    final (container, _) = await containerFor([
      const NotificationResponse(
        notifications: [],
        rawCount: 3,
        rawLastId: '9001',
      ),
    ]);
    expect(container.read(notificationProvider).requireValue.hasMore, isFalse);
  });

  test('⚠ カーソルが進まなかったら打ち切る（同じ通知を足し続けない）', () async {
    final (container, adapter) = await containerFor([
      NotificationResponse(
        notifications: [_notification('9020')],
        rawCount: 1,
        rawLastId: '9001',
        hasMore: true,
      ),
      // サーバーが同じページを返した（= カーソルが進まない）。
      NotificationResponse(
        notifications: [_notification('9020')],
        rawCount: 1,
        rawLastId: '9001',
        hasMore: true,
      ),
    ]);

    await container.read(notificationProvider.notifier).loadMore();
    final state = container.read(notificationProvider).requireValue;

    expect(adapter.requestedMaxIds, [null, '9001']);
    expect(state.notifications.map((n) => n.id), [
      '9020',
    ], reason: '同じページを足し直さない');
    expect(
      state.hasMore,
      isFalse,
      reason: 'hasMore が true のままだとスクロールのたびに同じ通知が積まれる',
    );
  });

  test('カーソルが進めば通常どおり足す', () async {
    final (container, adapter) = await containerFor([
      NotificationResponse(
        notifications: [_notification('9020')],
        rawCount: 1,
        rawLastId: '9001',
        hasMore: true,
      ),
      NotificationResponse(
        notifications: [_notification('8500')],
        rawCount: 1,
        rawLastId: '8400',
        hasMore: true,
      ),
    ]);

    await container.read(notificationProvider.notifier).loadMore();
    final state = container.read(notificationProvider).requireValue;

    expect(adapter.requestedMaxIds, [null, '9001']);
    expect(state.notifications.map((n) => n.id), ['9020', '8500']);
    expect(state.hasMore, isTrue);
    expect(state.lastRawId, '8400');
  });

  /// #1251: 同じ `group_key` のグループがページを跨いで 2 行出ない。
  group('同じグループを 2 行にしない (#1251)', () {
    Notification grouped(String id, String? key, {int count = 1}) =>
        Notification(
          id: id,
          type: NotificationType.favourite,
          createdAt: DateTime.utc(2026, 10, 9),
          groupKey: key,
          groupCount: count,
        );

    test('⚠ 後のページの同じグループは足さず、先に出ている側の件数を保つ', () async {
      final (container, _) = await containerFor([
        NotificationResponse(
          notifications: [
            grouped('9030', 'favourite-1-500', count: 12),
            grouped('9029', 'reblog-1-500', count: 3),
          ],
          rawCount: 2,
          rawLastId: '9010',
          hasMore: true,
        ),
        NotificationResponse(
          notifications: [
            // 1 ページ目と同じグループが、古いページにも出てきた。
            grouped('9009', 'favourite-1-500', count: 5),
            grouped('9008', 'favourite-1-499', count: 2),
          ],
          rawCount: 2,
          rawLastId: '9001',
          hasMore: false,
        ),
      ]);

      await container.read(notificationProvider.notifier).loadMore();

      final list = container.read(notificationProvider).requireValue;
      expect(list.notifications.map((n) => n.groupKey), [
        'favourite-1-500',
        'reblog-1-500',
        'favourite-1-499',
      ]);
      expect(
        list.notifications.first.groupCount,
        12,
        reason: '後のページの件数を足すと、同じ通知を二重に数える',
      );
      // ⚠ 落としたぶんでカーソルを止めない（続きは読めたまま）。
      expect(list.lastRawId, '9001');
    });

    test('グループ化していない通知（groupKey が null）は落とさない', () {
      final shown = [grouped('3', null), grouped('2', null)];
      final older = [grouped('1', null), grouped('0', null)];

      expect(dropAlreadyShownGroups(shown, older).map((n) => n.id), ['1', '0']);
    });

    test('同じページの中で重なっていても 1 つにする', () {
      final older = [grouped('2', 'k'), grouped('1', 'k'), grouped('0', 'j')];

      expect(dropAlreadyShownGroups(const [], older).map((n) => n.id), [
        '2',
        '0',
      ]);
    });
  });

  /// #1251: 手元で絞ったページが続くとき、追加読み込みを連打しない。
  group('手元で絞ったページのあとは間を置く (#1251)', () {
    (ProviderContainer, _ScriptedAdapter) boot(
      FakeAsync async,
      List<NotificationResponse> pages,
    ) {
      final adapter = _ScriptedAdapter(pages);
      final container = ProviderContainer(
        overrides: [
          currentAccountProvider.overrideWithValue(null),
          currentAdapterProvider.overrideWithValue(adapter),
        ],
      );
      container.listen(notificationProvider, (_, _) {});
      async.flushMicrotasks();
      return (container, adapter);
    }

    NotificationResponse page(String lastId, {required bool filtered}) =>
        NotificationResponse(
          // 20 件取って 1 件しか残らなかったページ。
          notifications: [_notification(lastId)],
          rawCount: 20,
          rawLastId: lastId,
          hasMore: true,
          filteredLocally: filtered,
        );

    test('⚠ 次の取得は、間を置いてから飛ぶ（流量制限は 30 回 / 30 秒）', () {
      fakeAsync((async) {
        final (container, adapter) = boot(async, [
          page('9020', filtered: true),
          page('9000', filtered: true),
        ]);
        expect(adapter.requestedMaxIds, [null]);

        unawaited(container.read(notificationProvider.notifier).loadMore());
        async.elapse(const Duration(milliseconds: 1400));
        expect(adapter.requestedMaxIds, [null], reason: '間を置かずに打っている');
        expect(
          container.read(notificationProvider).requireValue.isLoadingMore,
          isTrue,
          reason: '待っている間も「読み込み中」を出す',
        );

        async.elapse(const Duration(milliseconds: 200));
        expect(adapter.requestedMaxIds, [null, '9020']);
        container.dispose();
      });
    });

    test('サーバーが絞ったページのあとは、待たずに読む（従来どおり）', () {
      fakeAsync((async) {
        final (container, adapter) = boot(async, [
          page('9020', filtered: false),
          page('9000', filtered: false),
        ]);

        unawaited(container.read(notificationProvider.notifier).loadMore());
        async.flushMicrotasks();

        expect(adapter.requestedMaxIds, [null, '9020']);
        container.dispose();
      });
    });
  });
}
