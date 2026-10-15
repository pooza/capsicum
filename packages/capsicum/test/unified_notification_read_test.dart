import 'package:capsicum/src/model/account.dart';
import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/provider/marker_provider.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/widgets.dart' hide Notification;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

/// #1291: 「すべての通知」で見た通知の既読を、アカウントごとに返す。
///
/// ⚠⚠ 以前は「すべての通知」で見ても既読が返らず、ほかのアカウントのバッジを
/// 0 にする手段が「切り替えて通知タブを見る」しか無かった。
class _MastodonLike extends Mock
    implements DecentralizedBackendAdapter, MarkerSupport {
  final saved = <String>[];

  /// サーバーが持っている既読位置。
  String? serverMarker;

  @override
  Future<MarkerSet> getMarkers() async => MarkerSet(
    notifications: serverMarker == null
        ? null
        : Marker(
            lastReadId: serverMarker!,
            version: 1,
            updatedAt: DateTime.utc(2026, 10, 16),
          ),
  );

  @override
  Future<void> saveNotificationMarker(String lastReadId) async {
    saved.add(lastReadId);
    serverMarker = lastReadId;
  }
}

class _MisskeyLike extends Mock
    implements
        DecentralizedBackendAdapter,
        NotificationSupport,
        NotificationReadSupport {
  _MisskeyLike({this.latestId});

  var markedAll = 0;

  /// サーバーの一番新しい通知。
  String? latestId;

  @override
  Future<NotificationResponse> getNotifications({
    TimelineQuery? query,
    NotificationQuery? filter,
  }) async => NotificationResponse(
    notifications: [
      if (latestId != null)
        Notification(
          id: latestId!,
          type: NotificationType.mention,
          createdAt: DateTime.utc(2026, 10, 16),
        ),
    ],
    rawCount: latestId == null ? 0 : 1,
  );

  @override
  Future<void> markAllNotificationsRead() async => markedAll++;
}

Account _account(String username, DecentralizedBackendAdapter adapter) =>
    Account(
      key: AccountKey(
        type: BackendType.mastodon,
        host: 'example.test',
        username: username,
      ),
      adapter: adapter,
      user: User(id: username, username: username),
      userSecret: const UserSecret(accessToken: 'token'),
    );

void main() {
  // 5 秒の待ちを pump で進めるために、テスト用のバインディングの時計を使う。
  Future<void> pumpPast5s(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 6));
  }

  testWidgets('Mastodon: 一番新しい通知が 5 秒見えたら、その通知をマーカーに保存する', (tester) async {
    final adapter = _MastodonLike();
    final saver = UnifiedNotificationReadSaver(isAppVisible: () => true);
    addTearDown(saver.dispose);

    saver.seen(_account('a', adapter), '120');
    await pumpPast5s(tester);

    expect(adapter.saved, ['120']);
  });

  testWidgets('Misskey: 一番新しい通知が 5 秒見えたら、全既読を返す', (tester) async {
    final adapter = _MisskeyLike(latestId: 'n9');
    final saver = UnifiedNotificationReadSaver(isAppVisible: () => true);
    addTearDown(saver.dispose);

    saver.seen(_account('a', adapter), 'n9');
    await pumpPast5s(tester);

    expect(adapter.markedAll, 1);
  });

  testWidgets('⚠⚠ 5 秒たつ前に画面から外れたら返さない（見ていない通知を既読にしない）', (tester) async {
    final adapter = _MisskeyLike(latestId: 'n9');
    final saver = UnifiedNotificationReadSaver(isAppVisible: () => true);
    addTearDown(saver.dispose);
    final account = _account('a', adapter);

    saver.seen(account, 'n9');
    saver.unseen(account, 'n9');
    await pumpPast5s(tester);

    expect(adapter.markedAll, 0);
  });

  testWidgets('⚠ アプリが裏にいる間は「見えた」ことにしない', (tester) async {
    final adapter = _MastodonLike();
    final saver = UnifiedNotificationReadSaver(isAppVisible: () => false);
    addTearDown(saver.dispose);

    saver.seen(_account('a', adapter), '120');
    await pumpPast5s(tester);

    expect(adapter.saved, isEmpty);
  });

  testWidgets('⚠ アカウントごとに別々に返す（片方を外しても、もう片方は返す）', (tester) async {
    final a = _MastodonLike();
    final b = _MastodonLike();
    final saver = UnifiedNotificationReadSaver(isAppVisible: () => true);
    addTearDown(saver.dispose);
    final accountA = _account('a', a);
    final accountB = _account('b', b);

    saver.seen(accountA, '120');
    saver.seen(accountB, '80');
    saver.unseen(accountA, '120');
    await pumpPast5s(tester);

    expect(a.saved, isEmpty);
    expect(b.saved, ['80']);
  });

  testWidgets('同じ通知では返し直さない', (tester) async {
    final adapter = _MastodonLike();
    final saver = UnifiedNotificationReadSaver(isAppVisible: () => true);
    addTearDown(saver.dispose);
    final account = _account('a', adapter);

    saver.seen(account, '120');
    await pumpPast5s(tester);
    saver.seen(account, '120');
    await pumpPast5s(tester);
    saver.seen(account, '121');
    await pumpPast5s(tester);

    expect(adapter.saved, ['120', '121']);
  });

  testWidgets('⚠⚠ Mastodon: サーバーの既読位置がこれより新しければ戻さない', (tester) async {
    final adapter = _MastodonLike()..serverMarker = '150';
    final saver = UnifiedNotificationReadSaver(isAppVisible: () => true);
    addTearDown(saver.dispose);

    saver.seen(_account('a', adapter), '120');
    await pumpPast5s(tester);

    expect(adapter.saved, isEmpty, reason: '通知タブで先まで読んだ位置を、古い位置へ戻さない');
  });

  testWidgets('⚠⚠ Misskey: 開いたあとに新着が届いていたら全既読を返さない', (tester) async {
    final adapter = _MisskeyLike(latestId: 'n10');
    final saver = UnifiedNotificationReadSaver(isAppVisible: () => true);
    addTearDown(saver.dispose);

    saver.seen(_account('a', adapter), 'n9');
    await pumpPast5s(tester);

    expect(adapter.markedAll, 0, reason: 'まだ見ていない n10 を巻き込まない');
  });

  testWidgets('⚠ 取り直しで先頭が替わったら、新しい通知で予約し直す', (tester) async {
    final adapter = _MastodonLike();
    final saver = UnifiedNotificationReadSaver(isAppVisible: () => true);
    addTearDown(saver.dispose);
    final account = _account('a', adapter);

    saver.seen(account, '120');
    saver.seen(account, '130');
    await pumpPast5s(tester);

    expect(adapter.saved, ['130']);
  });

  testWidgets('⚠ 古い行の「外れた」は、新しい行の予約を取り消さない', (tester) async {
    final adapter = _MastodonLike();
    final saver = UnifiedNotificationReadSaver(isAppVisible: () => true);
    addTearDown(saver.dispose);
    final account = _account('a', adapter);

    saver.seen(account, '130');
    saver.unseen(account, '120');
    await pumpPast5s(tester);

    expect(adapter.saved, ['130']);
  });
}
