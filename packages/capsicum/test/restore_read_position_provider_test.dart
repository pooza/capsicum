import 'package:capsicum/src/provider/preferences_provider.dart';
import 'package:capsicum/src/util/shared_preferences_cache.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// restoreReadPositionProvider (#715) の同期復元セマンティクスを検証する。
/// build() は pre-warm 済み SharedPreferences から同期で読むため、コールド
/// スタート直後の同期参照でも保存値を取りこぼさない (#746 race の構造的解消)。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<ProviderContainer> makeContainer(Map<String, Object> initial) async {
    SharedPreferences.setMockInitialValues(initial);
    initSharedPreferencesCache(await SharedPreferences.getInstance());
    return ProviderContainer();
  }

  test('既定は true（既読位置を復元する）', () async {
    final container = await makeContainer(<String, Object>{});
    addTearDown(container.dispose);

    expect(container.read(restoreReadPositionProvider), isTrue);
  });

  test('REPRO: OFF 保存値を最初の同期参照で取りこぼさない (#746)', () async {
    final container = await makeContainer(<String, Object>{
      'restore_read_position': false,
    });
    addTearDown(container.dispose);

    // _load() の await を挟まず、build() 直後の最初の read で false を見る。
    expect(container.read(restoreReadPositionProvider), isFalse);
  });

  test('ON 保存値も同期で復元する', () async {
    final container = await makeContainer(<String, Object>{
      'restore_read_position': true,
    });
    addTearDown(container.dispose);

    expect(container.read(restoreReadPositionProvider), isTrue);
  });

  test('toggle で値が反転し永続化される', () async {
    final container = await makeContainer(<String, Object>{
      'restore_read_position': true,
    });
    addTearDown(container.dispose);

    await container.read(restoreReadPositionProvider.notifier).toggle();
    expect(container.read(restoreReadPositionProvider), isFalse);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('restore_read_position'), isFalse);
  });
}
