import 'package:capsicum/src/provider/deck_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1157 / #1170: カラムの再読み込みの登録口。
///
/// ⚠⚠ **列の入れ替えでカラムの State が作り直される**ので、「新しいカラムが登録 →
/// 古いカラムが解除」の順で走ることがある。素朴に id で消すと**登録し直したばかりの
/// ぶんが消える**（メニューの「タイムラインを更新」が無効に落ちる）。
void main() {
  ProviderContainer makeContainer() {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    return container;
  }

  test('登録すると id から引ける', () async {
    final container = makeContainer();
    Future<void> refresh() async {}

    container.read(deckColumnRefreshProvider.notifier).register('a', refresh);

    expect(container.read(deckColumnRefreshProvider)['a'], refresh);
  });

  test('解除すると引けなくなる', () async {
    final container = makeContainer();
    final notifier = container.read(deckColumnRefreshProvider.notifier);
    Future<void> refresh() async {}
    notifier.register('a', refresh);

    notifier.unregister('a', refresh);

    expect(container.read(deckColumnRefreshProvider)['a'], isNull);
  });

  test('⚠⚠ 上書きされた後の解除は、新しい登録を消さない', () async {
    final container = makeContainer();
    final notifier = container.read(deckColumnRefreshProvider.notifier);
    Future<void> old() async {}
    Future<void> fresh() async {}
    notifier.register('a', old);
    // 列の入れ替えで作り直されたカラムが先に登録し直す。
    notifier.register('a', fresh);

    // 古いカラムの dispose が後から走る。
    notifier.unregister('a', old);

    expect(
      container.read(deckColumnRefreshProvider)['a'],
      fresh,
      reason: '⚠ 消すと Ctrl+R が黙って効かなくなる',
    );
  });

  test('複数のカラムを別々に持てる', () async {
    final container = makeContainer();
    final notifier = container.read(deckColumnRefreshProvider.notifier);
    Future<void> a() async {}
    Future<void> b() async {}
    notifier.register('a', a);
    notifier.register('b', b);

    notifier.unregister('a', a);

    expect(container.read(deckColumnRefreshProvider).keys, ['b']);
  });

  test('登録していない id の解除は何もしない', () async {
    final container = makeContainer();
    final notifier = container.read(deckColumnRefreshProvider.notifier);
    Future<void> a() async {}
    notifier.register('a', a);

    notifier.unregister('zzz', a);

    expect(container.read(deckColumnRefreshProvider).keys, ['a']);
  });
}
