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
}
