import 'dart:async';

import 'package:capsicum/src/model/account.dart';
import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/provider/notification_provider.dart';
import 'package:capsicum/src/util/shared_preferences_cache.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// PR #1285 の Codex P1: 伏せた通知だけのページが続いても、通知タブが先へ進む。
///
/// ⚠⚠ 通知に hide を掛けるようになって（#1289）、1 ページ丸ごと落ちることが
/// ある。先頭のページが全部落ちると空表示になり、続き読みの合図が二度と来ない。
class _PagedAdapter extends Mock
    implements DecentralizedBackendAdapter, NotificationSupport {
  _PagedAdapter(this.all);

  /// 新しい順。
  final List<Notification> all;
  final requestedMaxIds = <String?>[];

  /// 立っている間、続き読み（`maxId` あり）の取得をここで待たせる。
  Completer<void>? gate;

  /// 立っている間、続き読み（`maxId` あり）の取得を失敗させる（#1293）。
  bool failOlder = false;

  @override
  Future<NotificationResponse> getNotifications({
    TimelineQuery? query,
    NotificationQuery? filter,
  }) async {
    final maxId = query?.maxId;
    requestedMaxIds.add(maxId);
    final g = gate;
    if (g != null && maxId != null) await g.future;
    if (failOlder && maxId != null) throw Exception('network');
    final start = maxId == null ? 0 : all.indexWhere((n) => n.id == maxId) + 1;
    final page = all.skip(start).take(query?.limit ?? 20).toList();
    return NotificationResponse(
      notifications: page,
      rawCount: page.length,
      rawLastId: page.lastOrNull?.id,
    );
  }
}

Notification _mention(int n, {required bool hidden}) => Notification(
  id: '$n',
  type: NotificationType.mention,
  createdAt: DateTime.utc(2026, 10, 16),
  user: const User(id: 'u', username: 'someone'),
  post: Post(
    id: 'p$n',
    postedAt: DateTime.utc(2026, 10, 16),
    author: const User(id: 'u', username: 'someone'),
    content: 'ほげ',
    filterMatches: [
      if (hidden)
        const FilterMatch(
          action: FilterAction.hide,
          contexts: {FilterContext.notifications},
        ),
    ],
  ),
);

Future<ProviderContainer> _container(_PagedAdapter adapter) async {
  final container = ProviderContainer(
    overrides: [
      currentAccountProvider.overrideWith(
        (ref) => Account(
          key: const AccountKey(
            type: BackendType.mastodon,
            host: 'example.test',
            username: 'me',
          ),
          adapter: adapter,
          user: const User(id: 'me', username: 'me'),
          userSecret: const UserSecret(accessToken: 'token'),
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  container.listen(notificationProvider, (_, _) {}, fireImmediately: true);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(const {});
    initSharedPreferencesCache(await SharedPreferences.getInstance());
  });

  test('⚠⚠ 先頭の 2 ページが全部伏せた通知でも、その先の通知まで読む', () async {
    // 新しい側 40 件は伏せる / 残り 20 件は出る。
    final adapter = _PagedAdapter([
      for (var n = 1060; n > 1000; n--) _mention(n, hidden: n > 1020),
    ]);
    final container = await _container(adapter);

    final state = await container.read(notificationProvider.future);
    expect(state.notifications.length, 20);
    expect(state.notifications.first.id, '1020');
    expect(state.pageCapHit, isFalse);
    expect(state.rawNewestId, '1060', reason: '既読は伏せた通知まで返す');
  });

  test('⚠⚠ 上限（5 ページ）まで全部伏せた通知なら入口の印を立て、次はその先から進む', () async {
    // 新しい側 120 件（6 ページ）は伏せる / 残り 20 件は出る。
    final adapter = _PagedAdapter([
      for (var n = 1140; n > 1000; n--) _mention(n, hidden: n > 1020),
    ]);
    final container = await _container(adapter);

    final first = await container.read(notificationProvider.future);
    expect(first.notifications, isEmpty);
    expect(first.hasMore, isTrue);
    expect(first.pageCapHit, isTrue);

    await container.read(notificationProvider.notifier).loadMore();
    final after = container.read(notificationProvider).requireValue;
    expect(after.notifications.length, 20);
    expect(after.notifications.first.id, '1020');
    expect(after.pageCapHit, isFalse);
    expect(
      adapter.requestedMaxIds.toSet().length,
      adapter.requestedMaxIds.length,
      reason: '同じページを 2 度引いていない',
    );
  });

  test('⚠⚠ 続き読みの途中で読み直したら、古いページもカーソルも書かない', () async {
    final adapter = _PagedAdapter([
      for (var n = 1080; n > 1000; n--) _mention(n, hidden: false),
    ]);
    final container = await _container(adapter);
    await container.read(notificationProvider.future);

    final gate = Completer<void>();
    adapter.gate = gate;
    final pending = container.read(notificationProvider.notifier).loadMore();
    await Future<void>.delayed(Duration.zero);

    adapter.gate = null;
    container.invalidate(notificationProvider);
    final rebuilt = await container.read(notificationProvider.future);
    expect(rebuilt.notifications.length, 20);

    gate.complete();
    await pending;
    final after = container.read(notificationProvider).requireValue;
    expect(after.notifications.length, 20, reason: '古い続き読みのページを足さない');
    expect(after.lastRawId, '1061', reason: '読み直した一覧のカーソルのまま');
  });

  // #1293: 以前は最終失敗で isLoadingMore を下ろすだけで、loadMoreError も Sentry も
  // 無かった。画面は位置の変化で続き読みを叩き続けていた。
  test('⚠⚠ 続き読みが再試行しても失敗したら、loadMoreError を立てる', () async {
    final adapter = _PagedAdapter([
      for (var n = 1040; n > 1000; n--) _mention(n, hidden: false),
    ]);
    final container = await _container(adapter);
    await container.read(notificationProvider.future);

    adapter.failOlder = true;
    await container.read(notificationProvider.notifier).loadMore();
    final failed = container.read(notificationProvider).requireValue;
    expect(failed.loadMoreError, isNotNull);
    expect(failed.isLoadingMore, isFalse);
    expect(failed.notifications.length, 20);

    // 次に成功した続き読みで下ろす。
    adapter.failOlder = false;
    await container.read(notificationProvider.notifier).loadMore();
    final recovered = container.read(notificationProvider).requireValue;
    expect(recovered.loadMoreError, isNull);
    expect(recovered.notifications.length, 40);
  });
}
