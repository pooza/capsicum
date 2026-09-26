import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/provider/notification_provider.dart';
import 'package:capsicum/src/util/shared_preferences_cache.dart';
import 'package:capsicum_core/capsicum_core.dart';
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
}
