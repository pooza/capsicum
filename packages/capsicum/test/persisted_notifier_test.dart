import 'dart:async';

import 'package:capsicum/src/provider/preferences_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #927: 単一値設定の共通基底 [PersistedNotifier] へ寄せたことで、これまで
/// [ComposeFontFamilyNotifier] / [LastTabNotifier] にしか無かった「非同期ロードと
/// ユーザー編集の競合」ガードが、全 Notifier で同じ作法になったことを固定する。
///
/// 代表として `streamingEnabledProvider`（旧実装はガード無しだった bool 設定）を
/// 使う。build() は既定 true を返し、保存値 false を非同期に読む。その往復中に
/// setEnabled(true) すると、旧実装なら後から届く false に巻き戻っていた。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ProviderContainer boot(Map<String, Object> initial) {
    SharedPreferences.setMockInitialValues(initial);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.listen(
      streamingEnabledProvider,
      (_, _) {},
      fireImmediately: true,
    );
    return container;
  }

  test('保存値は読み込み後に反映される', () async {
    final container = boot({'streaming_enabled': false});
    await Future<void>.delayed(Duration.zero);
    expect(container.read(streamingEnabledProvider), isFalse);
  });

  test('読み込み中の編集が、後から届く保存値で上書きされない (#927 ガード共通化)', () async {
    final container = boot({'streaming_enabled': false});

    // _load() の往復が終わる前に編集する。
    unawaited(
      container.read(streamingEnabledProvider.notifier).setEnabled(true),
    );

    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(
      container.read(streamingEnabledProvider),
      isTrue,
      reason: '打った値が保存済みの旧値で黙って巻き戻ってはいけない',
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('streaming_enabled'), isTrue, reason: '編集は保存もされる');
  });

  test('保存値が無ければ既定値のまま', () async {
    final container = boot({});
    await Future<void>.delayed(Duration.zero);
    expect(
      container.read(streamingEnabledProvider),
      isTrue,
      reason: 'streaming は既定 ON',
    );
  });
}
