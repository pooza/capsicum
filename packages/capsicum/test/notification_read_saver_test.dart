import 'dart:io';

import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/provider/marker_provider.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

/// #1205: Misskey の通知の既読を、利用者が一覧の先頭を見たときにサーバーへ返す。
///
/// ⚠⚠ **両側に崖がある。**返さなければ WebUI の未読が永久に消えず (#1205)、
/// 見ていないのに返せば WebUI の未読が黙って消える (#1045)。
class _ReadAdapter extends Mock
    implements DecentralizedBackendAdapter, NotificationReadSupport {
  int calls = 0;
  bool fail = false;

  @override
  Future<void> markAllNotificationsRead() async {
    calls++;
    if (fail) throw Exception('boom');
  }
}

/// 位置で既読を返せるバックエンド（Mastodon）。こちらの保存役は何もしない。
class _PlainAdapter extends Mock implements DecentralizedBackendAdapter {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  (ProviderContainer, NotificationReadSaver) boot(
    DecentralizedBackendAdapter adapter, {
    bool Function()? isAppVisible,
  }) {
    final container = ProviderContainer(
      overrides: [
        currentAdapterProvider.overrideWithValue(adapter),
        notificationReadSaverProvider.overrideWith((ref) {
          final saver = NotificationReadSaver(
            ref,
            isAppVisible: isAppVisible ?? () => true,
          );
          ref.onDispose(saver.dispose);
          return saver;
        }),
      ],
    );
    // autoDispose なので、テストの間は購読して生かしておく。
    container.listen(notificationReadSaverProvider, (_, _) {});
    return (container, container.read(notificationReadSaverProvider));
  }

  test('先頭が見えると、間引きのあとに 1 回だけ返す', () {
    fakeAsync((async) {
      final adapter = _ReadAdapter();
      final (container, saver) = boot(adapter);

      saver.markSeen('n1');
      // スクロールのたびに同じ先頭で呼ばれる。
      saver.markSeen('n1');
      saver.markSeen('n1');
      async.elapse(const Duration(seconds: 4));
      expect(adapter.calls, 0, reason: '間引きの間は返さない');

      async.elapse(const Duration(seconds: 2));
      expect(adapter.calls, 1);

      container.dispose();
    });
  });

  test('⚠ 同じ先頭のままなら、返したあとは呼び直さない', () {
    fakeAsync((async) {
      final adapter = _ReadAdapter();
      final (container, saver) = boot(adapter);

      saver.markSeen('n1');
      async.elapse(const Duration(seconds: 6));
      saver.markSeen('n1');
      async.elapse(const Duration(seconds: 6));

      expect(adapter.calls, 1, reason: 'スクロールのたびに同じ API を叩き続けない');
      container.dispose();
    });
  });

  test('新しい通知が先頭に来たら、もう一度返す', () {
    fakeAsync((async) {
      final adapter = _ReadAdapter();
      final (container, saver) = boot(adapter);

      saver.markSeen('n1');
      async.elapse(const Duration(seconds: 6));
      saver.markSeen('n2');
      async.elapse(const Duration(seconds: 6));

      expect(adapter.calls, 2);
      container.dispose();
    });
  });

  test('⚠ 失敗した回は、同じ先頭でも送り直す', () {
    fakeAsync((async) {
      final adapter = _ReadAdapter()..fail = true;
      final (container, saver) = boot(adapter);

      saver.markSeen('n1');
      async.elapse(const Duration(seconds: 6));
      expect(adapter.calls, 1);

      adapter.fail = false;
      saver.markSeen('n1');
      async.elapse(const Duration(seconds: 6));

      expect(adapter.calls, 2, reason: '失敗を「返した」ことにすると、未読が残ったままになる');
      container.dispose();
    });
  });

  test('⚠⚠ アプリが裏にいる間は返さない（見ていないのに未読が消える・#1045）', () {
    fakeAsync((async) {
      final adapter = _ReadAdapter();
      var visible = false;
      final (container, saver) = boot(adapter, isAppVisible: () => visible);

      // 裏にいる間に streaming で先頭へ通知が足された。
      saver.markSeen('n1');
      async.elapse(const Duration(seconds: 6));
      expect(adapter.calls, 0);

      // 前面へ戻ってから見えた回は返す。
      visible = true;
      saver.markSeen('n1');
      async.elapse(const Duration(seconds: 6));
      expect(adapter.calls, 1);

      container.dispose();
    });
  });

  test('画面を離れるときは、間引きを待たずに返す', () {
    fakeAsync((async) {
      final adapter = _ReadAdapter();
      final (container, saver) = boot(adapter);

      saver.markSeen('n1');
      container.dispose();
      async.flushMicrotasks();

      expect(adapter.calls, 1, reason: '見てすぐ離れた回を取りこぼさない');
    });
  });

  test('全既読の口を持たないバックエンドでは何もしない', () {
    fakeAsync((async) {
      final (container, saver) = boot(_PlainAdapter());

      saver.markSeen('n1');
      async.elapse(const Duration(seconds: 6));

      // 投げなければよい。
      container.dispose();
    });
  });

  /// 保存役が正しくても、画面が呼ばなければ返らない。また「先頭が見えている」
  /// の条件を外すと、途中から読んでいる利用者の未読まで消える。
  group('通知一覧が、先頭が見えたときだけ呼んでいる', () {
    final src = File(
      'lib/src/ui/screen/notification_screen.dart',
    ).readAsStringSync();

    test('保存役を呼んでいる', () {
      expect(src, contains('notificationReadSaverProvider'));
      expect(src, contains('.markSeen(state.notifications.first.id)'));
    });

    test('⚠ 先頭（index 0）が見えていることを条件にしている', () {
      final call = src.indexOf('notificationReadSaverProvider');
      final guard = src.lastIndexOf('positions.any((p) => p.index == 0)', call);
      expect(guard, isNot(-1), reason: '先頭が見えていなくても全既読を返してしまう');
      expect(
        call - guard,
        lessThan(700),
        reason: '条件と呼び出しが離れている。同じ分岐に居るかを確かめること',
      );
    });
  });
}
