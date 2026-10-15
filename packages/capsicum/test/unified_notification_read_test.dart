import 'package:capsicum/src/model/account.dart';
import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/provider/marker_provider.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

/// #1291: 「すべての通知」で見た通知の既読を、アカウントごとに返す。
///
/// ⚠⚠ 以前は「すべての通知」で見ても既読が返らず、ほかのアカウントのバッジを
/// 0 にする手段が「切り替えて通知タブを見る」しか無かった。
class _MastodonLike extends Mock
    implements DecentralizedBackendAdapter, MarkerSupport {
  final saved = <String>[];

  @override
  Future<void> saveNotificationMarker(String lastReadId) async {
    saved.add(lastReadId);
  }
}

class _MisskeyLike extends Mock
    implements DecentralizedBackendAdapter, NotificationReadSupport {
  var markedAll = 0;

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
    final adapter = _MisskeyLike();
    final saver = UnifiedNotificationReadSaver(isAppVisible: () => true);
    addTearDown(saver.dispose);

    saver.seen(_account('a', adapter), 'n9');
    await pumpPast5s(tester);

    expect(adapter.markedAll, 1);
  });

  testWidgets('⚠⚠ 5 秒たつ前に画面から外れたら返さない（見ていない通知を既読にしない）', (tester) async {
    final adapter = _MisskeyLike();
    final saver = UnifiedNotificationReadSaver(isAppVisible: () => true);
    addTearDown(saver.dispose);
    final account = _account('a', adapter);

    saver.seen(account, 'n9');
    saver.unseen(account);
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
    saver.unseen(accountA);
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
}
