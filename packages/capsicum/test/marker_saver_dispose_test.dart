import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/provider/marker_provider.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

/// #1235: marker の保存役が、スコープごと破棄される経路で最後の 1 回を落とさない。
///
/// ⚠⚠ **`dispose` から呼ばれる処理で `ref.read` しない。**container が破棄中だと
/// 「破棄済みの container を読んだ」と投げる。デッキのカラムを閉じたときなど
/// `ProviderScope` ごと外れる回で、間引きの 5 秒以内に読んだぶんの既読位置が
/// 保存されないままになっていた。
class _MarkerAdapter extends Mock
    implements DecentralizedBackendAdapter, MarkerSupport {
  final List<String> home = [];
  final List<String> notifications = [];

  @override
  Future<void> saveHomeMarker(String lastReadId) async => home.add(lastReadId);

  @override
  Future<void> saveNotificationMarker(String lastReadId) async =>
      notifications.add(lastReadId);
}

void main() {
  ProviderContainer boot(_MarkerAdapter adapter) {
    final container = ProviderContainer(
      overrides: [currentAdapterProvider.overrideWithValue(adapter)],
    );
    // autoDispose なので、テストの間は購読して生かしておく。
    container.listen(homeMarkerSaverProvider, (_, _) {});
    container.listen(notificationMarkerSaverProvider, (_, _) {});
    return container;
  }

  test('⚠⚠ container ごと破棄されても、待っていた保存を落とさない', () {
    fakeAsync((async) {
      final adapter = _MarkerAdapter();
      final container = boot(adapter);

      container.read(homeMarkerSaverProvider).save('h1');
      container.read(notificationMarkerSaverProvider).save('n1');
      // 間引きの 5 秒を待たずにスコープが外れた。
      container.dispose();
      async.flushMicrotasks();

      expect(adapter.home, ['h1']);
      expect(adapter.notifications, ['n1']);
    });
  });

  test('間引きの間は最後の位置だけを保存する（従来どおり）', () {
    fakeAsync((async) {
      final adapter = _MarkerAdapter();
      final container = boot(adapter);

      container.read(homeMarkerSaverProvider)
        ..save('h1')
        ..save('h2');
      container.read(notificationMarkerSaverProvider)
        ..save('n1')
        ..save('n2');
      async.elapse(const Duration(seconds: 6));

      expect(adapter.home, ['h2']);
      expect(adapter.notifications, ['n2']);
      container.dispose();
    });
  });

  // v2.1 のリリース前レビュー（2026-10-10）。サーバーは未読の数を「この位置より
  // 新しい通知」で数えるので、下へ読み進めた位置を保存すると、読んだばかりの
  // 通知が未読として数え直される。
  group('通知の位置は、古いほうへ戻さない', () {
    test('⚠⚠ 下へ読み進めても、保存するのは一番新しく見えた位置', () {
      fakeAsync((async) {
        final adapter = _MarkerAdapter();
        final container = boot(adapter);
        final saver = container.read(notificationMarkerSaverProvider);

        saver.save('1000');
        async.elapse(const Duration(seconds: 6));
        // 一覧を下へ（古いほうへ）読み進める。
        saver
          ..save('999')
          ..save('970');
        async.elapse(const Duration(seconds: 6));

        expect(adapter.notifications, ['1000']);
        container.dispose();
        async.flushMicrotasks();
        expect(adapter.notifications, ['1000'], reason: '破棄のときにも古い位置を送らない');
      });
    });

    test('新しい通知が見えたら保存する', () {
      fakeAsync((async) {
        final adapter = _MarkerAdapter();
        final container = boot(adapter);
        final saver = container.read(notificationMarkerSaverProvider);

        saver.save('999');
        async.elapse(const Duration(seconds: 6));
        // ⚠ 桁が増える境目。文字列で比べると '1000' < '999' になる。
        saver.save('1000');
        async.elapse(const Duration(seconds: 6));

        expect(adapter.notifications, ['999', '1000']);
        container.dispose();
      });
    });

    test('⚠ サーバーが持っている位置より古ければ保存しない', () {
      fakeAsync((async) {
        final adapter = _MarkerAdapter();
        final container = boot(adapter);
        final saver = container.read(notificationMarkerSaverProvider);

        saver.noteServerMarker('1000');
        saver
          ..save('990')
          ..save('1000');
        async.elapse(const Duration(seconds: 6));
        expect(adapter.notifications, isEmpty, reason: '同じ位置も送り直さない');

        saver.save('1001');
        async.elapse(const Duration(seconds: 6));
        expect(adapter.notifications, ['1001']);
        container.dispose();
      });
    });

    test('⚠ ホームの位置は従来どおり戻せる（読んでいる場所の復元に使う）', () {
      fakeAsync((async) {
        final adapter = _MarkerAdapter();
        final container = boot(adapter);

        container.read(homeMarkerSaverProvider).save('1000');
        async.elapse(const Duration(seconds: 6));
        container.read(homeMarkerSaverProvider).save('990');
        async.elapse(const Duration(seconds: 6));

        expect(adapter.home, ['1000', '990']);
        container.dispose();
      });
    });

    test('isNewerNotificationId', () {
      expect(isNewerNotificationId('1000', than: '999'), isTrue);
      expect(isNewerNotificationId('999', than: '1000'), isFalse);
      expect(isNewerNotificationId('1000', than: '1000'), isFalse);
      // 数として読めない ID は、同じでなければ保存する側に倒す。
      expect(isNewerNotificationId('abc', than: '1000'), isTrue);
      expect(isNewerNotificationId('abc', than: 'abc'), isFalse);
    });
  });
}
