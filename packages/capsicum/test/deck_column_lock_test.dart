import 'package:capsicum/src/model/account.dart';
import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/model/deck_column.dart';
import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/provider/preferences_provider.dart';
import 'package:capsicum/src/ui/widget/deck_column_view.dart';
import 'package:capsicum/src/util/shared_preferences_cache.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #1271: カラムのロック（2026-10-12 pooza）。常設のカラムを、見出しの × の
/// 押し間違いで閉じないようにする。
class _Adapter extends Mock implements DecentralizedBackendAdapter {}

class _Capabilities extends Mock implements AdapterCapabilities {}

const _lockedKey = 'deck_locked_columns';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;

  Future<void> seed({List<String> locked = const []}) async {
    SharedPreferences.setMockInitialValues({
      'deck_columns': [
        'x|misskey://me@misskey.example|hashtag:a',
        'y|misskey://me@misskey.example|hashtag:b',
      ],
      if (locked.isNotEmpty) _lockedKey: locked,
    });
    prefs = await SharedPreferences.getInstance();
    initSharedPreferencesCache(prefs);
  }

  group('保存と列への追従', () {
    test('掛けると保存され、外すと消える', () async {
      await seed();
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(deckLockedColumnsProvider.notifier);

      await notifier.setLocked('x', true);
      expect(container.read(deckLockedColumnsProvider), {'x'});
      expect(prefs.getStringList(_lockedKey), ['x']);

      await notifier.setLocked('x', false);
      expect(container.read(deckLockedColumnsProvider), isEmpty);
      expect(prefs.getStringList(_lockedKey), isNull);
    });

    test('⚠ 列に居ない id は読む時点で落とす（閉じた・バックアップから戻した）', () async {
      await seed(locked: ['x', 'gone']);
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(deckLockedColumnsProvider), {'x'});
    });

    test('列に居ない id には掛けられない', () async {
      await seed();
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container
          .read(deckLockedColumnsProvider.notifier)
          .setLocked('gone', true);
      expect(container.read(deckLockedColumnsProvider), isEmpty);
    });

    test('⚠⚠ ロック中でも、列から外す経路（カラム編集・中身の画面が閉じる）は通る', () async {
      // ロックが止めるのは見出しの × の押し間違いだけ。コレクションを削除した
      // カラムが残ると「表示できません」のカラムになる。
      await seed(locked: ['x', 'y']);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(deckLockedColumnsProvider), {'x', 'y'});

      await container.read(deckColumnsProvider.notifier).remove('x');
      await Future<void>.delayed(Duration.zero);

      expect(container.read(deckColumnsProvider).map((c) => c.id), ['y']);
      expect(container.read(deckLockedColumnsProvider), {
        'y',
      }, reason: '居なくなったカラムの id を持ち続けない');
      expect(prefs.getStringList(_lockedKey), ['y']);
    });

    test('並べ替えではロックは動かない', () async {
      await seed(locked: ['x']);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(deckLockedColumnsProvider), {'x'});

      await container.read(deckColumnsProvider.notifier).move('x', 1);

      expect(container.read(deckColumnsProvider).map((c) => c.id), ['y', 'x']);
      expect(container.read(deckLockedColumnsProvider), {'x'});
    });
  });

  group('見出し', () {
    late Account account;

    Future<ProviderContainer> pump(WidgetTester tester) async {
      final adapter = _Adapter();
      final capabilities = _Capabilities();
      when(() => capabilities.supportedTimelines).thenReturn({
        TimelineType.home,
        TimelineType.local,
        TimelineType.social,
      });
      when(() => adapter.capabilities).thenReturn(capabilities);
      account = Account(
        key: const AccountKey(
          type: BackendType.misskey,
          host: 'misskey.example',
          username: 'me',
        ),
        adapter: adapter,
        user: const User(id: 'me', username: 'me'),
        userSecret: const UserSecret(accessToken: 'token'),
      );
      final container = ProviderContainer(
        overrides: [currentAccountProvider.overrideWithValue(account)],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: DeckColumnView(
                // ⚠ 中身は取得を起こさない種別にしてある（見たいのは見出しだけ）。
                column: DeckColumn(
                  id: 'x',
                  account: account.key,
                  tab: const UserListTab(UserListKind.followers, 'u1'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return container;
    }

    testWidgets('掛かっていなければ × で閉じられる（今までどおり）', (tester) async {
      await seed();
      final container = await pump(tester);

      expect(find.byTooltip('ロックを解除'), findsNothing);
      await tester.tap(find.byTooltip('カラムを閉じる'));
      await tester.pumpAndSettle();

      expect(container.read(deckColumnsProvider).map((c) => c.id), ['y']);
    });

    testWidgets('⚠⚠ ロック中は × が出ず、鍵を押すと解除になる（閉じるには 2 回押す）', (tester) async {
      await seed();
      final container = await pump(tester);

      await tester.tap(find.byTooltip('カラムをロック（閉じられないようにする）'));
      await tester.pumpAndSettle();

      expect(container.read(deckLockedColumnsProvider), {'x'});
      expect(find.byTooltip('カラムを閉じる'), findsNothing);
      expect(find.byIcon(Icons.close), findsNothing);

      // × があった位置の鍵を押しても、カラムは閉じない。
      await tester.tap(find.byTooltip('ロックを解除'));
      await tester.pumpAndSettle();

      expect(container.read(deckColumnsProvider).map((c) => c.id), ['x', 'y']);
      expect(container.read(deckLockedColumnsProvider), isEmpty);
      expect(find.byTooltip('カラムを閉じる'), findsOneWidget);
    });

    testWidgets('保存されたロックは、開き直しても掛かっている', (tester) async {
      await seed(locked: ['x']);
      await pump(tester);

      expect(find.byTooltip('ロックを解除'), findsOneWidget);
      expect(find.byTooltip('カラムを閉じる'), findsNothing);
    });

    testWidgets('狭幅（カラム 300px）でも見出しが overflow しない', (tester) async {
      await seed();
      tester.view.physicalSize = const Size(300, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await pump(tester);

      expect(tester.takeException(), isNull);
    });
  });
}
