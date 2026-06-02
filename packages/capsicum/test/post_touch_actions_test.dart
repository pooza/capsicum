import 'package:capsicum/src/provider/preferences_provider.dart';
import 'package:capsicum/src/util/shared_preferences_cache.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// PostTouchActionsNotifier (#565) の永続化セマンティクスのみを検証する。
/// build() は pre-warm 済み SharedPreferences から同期で読むため、各テストで
/// initSharedPreferencesCache() を呼んでからコンテナを生成する。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<ProviderContainer> makeContainer(Map<String, Object> initial) async {
    SharedPreferences.setMockInitialValues(initial);
    initSharedPreferencesCache(await SharedPreferences.getInstance());
    return ProviderContainer();
  }

  test('既定は全アクション OFF (空集合)', () async {
    final container = await makeContainer(<String, Object>{});
    addTearDown(container.dispose);

    expect(container.read(postTouchActionsProvider), isEmpty);
    final notifier = container.read(postTouchActionsProvider.notifier);
    for (final action in PostTouchAction.values) {
      expect(notifier.isEnabled(action), isFalse);
    }
  });

  test('保存済みの名前リストを集合として復元する', () async {
    final container = await makeContainer(<String, Object>{
      'post_touch_actions': <String>['reply', 'boost'],
    });
    addTearDown(container.dispose);

    expect(container.read(postTouchActionsProvider), {
      PostTouchAction.reply,
      PostTouchAction.boost,
    });
  });

  test('未知の名前は無視して復元する (enum 変更耐性)', () async {
    final container = await makeContainer(<String, Object>{
      'post_touch_actions': <String>['reply', 'bogus_removed_action'],
    });
    addTearDown(container.dispose);

    expect(container.read(postTouchActionsProvider), {PostTouchAction.reply});
  });

  test('setEnabled で追加・削除し SharedPreferences に永続化する', () async {
    final container = await makeContainer(<String, Object>{});
    addTearDown(container.dispose);
    final notifier = container.read(postTouchActionsProvider.notifier);

    await notifier.setEnabled(PostTouchAction.favorite, true);
    expect(notifier.isEnabled(PostTouchAction.favorite), isTrue);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('post_touch_actions'), contains('favorite'));

    await notifier.setEnabled(PostTouchAction.favorite, false);
    expect(notifier.isEnabled(PostTouchAction.favorite), isFalse);
    expect(
      prefs.getStringList('post_touch_actions'),
      isNot(contains('favorite')),
    );
  });
}
