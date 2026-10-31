import 'package:capsicum/src/provider/preferences_provider.dart';
import 'package:capsicum/src/ui/screen/settings/preferred_apps_settings_screen.dart';
import 'package:capsicum/src/url_helper.dart';
import 'package:capsicum/src/util/shared_preferences_cache.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #1345: 専用アプリで開くサービスの表と、サービスごとに外す設定。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('hasPreferredApp', () {
    test('足したサービスに当たる（サブドメインも）', () {
      for (final host in [
        'github.com',
        'gist.github.com',
        'x.com',
        'twitter.com',
        'mobile.twitter.com',
        'YouTube.com',
      ]) {
        expect(hasPreferredApp(host), isTrue, reason: host);
      }
    });

    test('⚠ 名前の一部が同じだけのホストには当たらない', () {
      for (final host in [
        'notgithub.com',
        'netflix.com',
        'github.com.example',
        'news.yahoo.co.jp',
      ]) {
        expect(hasPreferredApp(host), isFalse, reason: host);
      }
    });

    test('⚠ 外したサービスだけ当たらなくなる', () {
      const disabled = {'github'};

      expect(hasPreferredApp('github.com', disabled: disabled), isFalse);
      expect(hasPreferredApp('x.com', disabled: disabled), isTrue);
    });

    test('⚠ X は 2 つのドメインをまとめて外せる', () {
      const disabled = {'x'};

      expect(hasPreferredApp('x.com', disabled: disabled), isFalse);
      expect(hasPreferredApp('twitter.com', disabled: disabled), isFalse);
    });

    test('id が重複していない（設定の保存に使う）', () {
      final ids = preferredAppServices.map((s) => s.id);

      expect(ids.toSet().length, ids.length);
    });
  });

  group('設定画面', () {
    Future<ProviderContainer> pump(
      WidgetTester tester,
      Map<String, Object> saved,
    ) async {
      SharedPreferences.setMockInitialValues(saved);
      initSharedPreferencesCache(await SharedPreferences.getInstance());
      final container = ProviderContainer();
      addTearDown(container.dispose);
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: PreferredAppsSettingsScreen()),
        ),
      );
      await tester.pumpAndSettle();
      return container;
    }

    SwitchListTile tile(WidgetTester tester, String label) =>
        tester.widget(find.widgetWithText(SwitchListTile, label));

    testWidgets('表のサービスが全部並び、既定はオン', (tester) async {
      await pump(tester, {});

      for (final service in preferredAppServices) {
        expect(tile(tester, service.label).value, isTrue, reason: service.id);
      }
    });

    testWidgets('オフにすると保存され、戻すと消える', (tester) async {
      final container = await pump(tester, {});

      await tester.tap(find.text('GitHub'));
      await tester.pumpAndSettle();

      expect(container.read(disabledPreferredAppsProvider), {'github'});
      expect(tile(tester, 'GitHub').value, isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('disabled_preferred_apps'), ['github']);

      await tester.tap(find.text('GitHub'));
      await tester.pumpAndSettle();

      expect(container.read(disabledPreferredAppsProvider), isEmpty);
    });

    testWidgets('保存してあるものはオフで出る', (tester) async {
      await pump(tester, {
        'disabled_preferred_apps': ['x'],
      });

      expect(tile(tester, 'X').value, isFalse);
      expect(tile(tester, 'GitHub').value, isTrue);
    });
  });
}
