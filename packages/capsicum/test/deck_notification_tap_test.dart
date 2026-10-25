import 'dart:async';

import 'package:capsicum/src/model/account.dart';
import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/provider/deck_provider.dart';
import 'package:capsicum/src/provider/preferences_provider.dart';
import 'package:capsicum/src/provider/timeline_provider.dart';
import 'package:capsicum/src/ui/screen/deck_screen.dart';
import 'package:capsicum/src/ui/util/deck_notification_fallback.dart';
import 'package:capsicum/src/util/shared_preferences_cache.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #1295: デッキで使っているとき、通知のタップはデッキの通知カラムへ送る
/// （2026-10-18 pooza 判断・`docs/deck-ui-decisions.md` 9-1 の末尾）。
///
/// 以前は `main.dart` が `/home`（タブ UI）へ決め打ちで遷移していた。
class _Adapter extends Mock implements DecentralizedBackendAdapter {}

const _me = AccountKey(
  type: BackendType.misskey,
  host: 'misskey.example',
  username: 'me',
);
const _other = AccountKey(
  type: BackendType.misskey,
  host: 'misskey.example',
  username: 'other',
);

Account _account(AccountKey key) => Account(
  key: key,
  adapter: _Adapter(),
  user: User(id: key.username, username: key.username),
  userSecret: const UserSecret(accessToken: 'token'),
);

class _TestAccountNotifier extends AccountManagerNotifier {
  @override
  AccountManagerState build() => AccountManagerState(
    accounts: [_account(_me), _account(_other)],
    current: _account(_me),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('notificationTapGoesToDeck', () {
    test('デッキが開いていればデッキ', () {
      expect(
        notificationTapGoesToDeck(
          deckOpen: true,
          startupPending: false,
          lastMode: LastViewMode.tabs,
          hasColumns: false,
        ),
        isTrue,
      );
    });

    test('⚠ 閉じていても、起動の途中で前回デッキで終えていて列があればデッキ', () {
      expect(
        notificationTapGoesToDeck(
          deckOpen: false,
          startupPending: true,
          lastMode: LastViewMode.deck,
          hasColumns: true,
        ),
        isTrue,
      );
    });

    test('⚠⚠ 起動時の判定が済んだあとは、前回デッキで終えていてもデッキが閉じていればタブ UI '
        '(#1304)', () {
      // 共有やディープリンクから起動してデッキで始めなかった回。以前はここが
      // 真になり、タップしても何も起きなかった。
      expect(
        notificationTapGoesToDeck(
          deckOpen: false,
          startupPending: false,
          lastMode: LastViewMode.deck,
          hasColumns: true,
        ),
        isFalse,
      );
    });

    test('タブ UI で使っていればタブ UI（従来どおり）', () {
      expect(
        notificationTapGoesToDeck(
          deckOpen: false,
          startupPending: true,
          lastMode: LastViewMode.tabs,
          hasColumns: true,
        ),
        isFalse,
      );
    });

    test('列が空ならデッキで始まらないので、タブ UI', () {
      expect(
        notificationTapGoesToDeck(
          deckOpen: false,
          startupPending: true,
          lastMode: LastViewMode.deck,
          hasColumns: false,
        ),
        isFalse,
      );
    });
  });

  group('releasePendingDeckNotification (#1304)', () {
    test('⚠⚠ デッキが受けなかった印を、宛先へ切り替えてタブ UI の通知タブへ振り替える', () async {
      // 切り替えは MRU の並びを保存する（失敗しても進む）。
      SharedPreferences.setMockInitialValues({});
      initSharedPreferencesCache(await SharedPreferences.getInstance());
      final container = ProviderContainer(
        overrides: [
          accountManagerProvider.overrideWith(_TestAccountNotifier.new),
        ],
      );
      addTearDown(container.dispose);
      container.read(pendingDeckNotificationsProvider.notifier).state = _other;

      expect(releasePendingDeckNotification(container.read), isTrue);

      // 印が残ると、後で手でデッキを開いたときに頼んでいない通知カラムが足される。
      expect(container.read(pendingDeckNotificationsProvider), isNull);
      expect(container.read(accountManagerProvider).current?.key, _other);
      expect(
        container.read(pendingInitialTabProvider),
        const NotificationsTab(),
      );
    });

    test('印が無ければ何もしない', () {
      final container = ProviderContainer(
        overrides: [
          accountManagerProvider.overrideWith(_TestAccountNotifier.new),
        ],
      );
      addTearDown(container.dispose);

      expect(releasePendingDeckNotification(container.read), isFalse);
      expect(container.read(accountManagerProvider).current?.key, _me);
      expect(container.read(pendingInitialTabProvider), isNull);
    });
  });

  group('settleDeckStartupWithoutDeck (#1332)', () {
    test('⚠⚠ 起動の判定待ちの印を下ろし、デッキ宛ての印をタブ表示へ振り替える（共有から起動した回）', () {
      final container = ProviderContainer(
        overrides: [
          accountManagerProvider.overrideWith(_TestAccountNotifier.new),
        ],
      );
      addTearDown(container.dispose);
      container.read(pendingDeckNotificationsProvider.notifier).state = _other;

      settleDeckStartupWithoutDeck(container.read);

      expect(container.read(deckStartupPendingProvider), isFalse);
      expect(container.read(pendingDeckNotificationsProvider), isNull);
      expect(container.read(accountManagerProvider).current?.key, _other);
      expect(
        container.read(pendingInitialTabProvider),
        const NotificationsTab(),
      );
    });
  });

  Future<ProviderContainer> pumpDeck(
    WidgetTester tester,
    List<String> columns,
  ) async {
    SharedPreferences.setMockInitialValues({'deck_columns': columns});
    initSharedPreferencesCache(await SharedPreferences.getInstance());
    tester.view.physicalSize = const Size(1200, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final container = ProviderContainer(
      overrides: [
        accountManagerProvider.overrideWith(_TestAccountNotifier.new),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: DeckScreen(
            columnBuilder: (column) =>
                SizedBox.expand(key: ValueKey('stub-${column.id}')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  Future<void> tap(
    WidgetTester tester,
    ProviderContainer container,
    AccountKey account,
  ) async {
    container.read(pendingDeckNotificationsProvider.notifier).state = account;
    await tester.pumpAndSettle();
  }

  testWidgets('⚠ デッキの上に全画面の画面が積まれていたら、閉じてデッキを見せる (#1304)', (tester) async {
    final container = await pumpDeck(tester, [
      'n|misskey://other@misskey.example|notifications',
    ]);
    // 投稿の詳細・プロフィールなどを開いている状態。
    unawaited(
      tester
          .state<NavigatorState>(find.byType(Navigator).first)
          .push(
            MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Text('above')),
            ),
          ),
    );
    await tester.pumpAndSettle();
    expect(find.text('above'), findsOneWidget);

    await tap(tester, container, _other);

    // 閉じないと、通知カラムへ送っても上の画面に隠れて見えない。
    expect(find.text('above'), findsNothing);
    expect(container.read(deckFocusProvider).columnId, 'n');
  });

  testWidgets('⚠⚠ 宛先の通知カラムがあれば、足さずにそこへフォーカスする', (tester) async {
    final container = await pumpDeck(tester, [
      'a|misskey://me@misskey.example|hashtag:a',
      'n|misskey://other@misskey.example|notifications',
    ]);

    await tap(tester, container, _other);

    expect(container.read(deckColumnsProvider), hasLength(2));
    expect(container.read(deckFocusProvider).columnId, 'n');
    expect(container.read(pendingDeckNotificationsProvider), isNull);
  });

  testWidgets('⚠⚠ 無ければ通知カラムを足して、そこへフォーカスする', (tester) async {
    final container = await pumpDeck(tester, [
      'a|misskey://me@misskey.example|hashtag:a',
    ]);

    await tap(tester, container, _other);

    final columns = container.read(deckColumnsProvider);
    expect(columns, hasLength(2));
    final added = columns.last;
    expect(added.tab, const NotificationsTab());
    expect(added.account, _other, reason: '宛先のアカウントの通知');
    expect(container.read(deckFocusProvider).columnId, added.id);
  });

  testWidgets('宛先の通知カラムが無く「すべての通知」があれば、そこへ（足さない）', (tester) async {
    final container = await pumpDeck(tester, [
      'a|misskey://me@misskey.example|hashtag:a',
      'all|misskey://me@misskey.example|all_notifications',
    ]);

    await tap(tester, container, _other);

    expect(container.read(deckColumnsProvider), hasLength(2));
    expect(container.read(deckFocusProvider).columnId, 'all');
  });

  testWidgets('⚠ 起動の判定待ちの印は、デッキが開いている数に入ってから下ろす (#1332)', (tester) async {
    final container = await pumpDeck(tester, [
      'a|misskey://me@misskey.example|hashtag:a',
    ]);

    expect(container.read(mountedDeckCountProvider), 1);
    expect(container.read(deckStartupPendingProvider), isFalse);
  });

  testWidgets('⚠⚠ 閉じかけのデッキは通知のタップを受けず、開いている数からも抜けている (#1332)', (tester) async {
    SharedPreferences.setMockInitialValues({
      'deck_columns': ['a|misskey://me@misskey.example|hashtag:a'],
    });
    initSharedPreferencesCache(await SharedPreferences.getInstance());
    tester.view.physicalSize = const Size(1200, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: [
        accountManagerProvider.overrideWith(_TestAccountNotifier.new),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: Text('home'))),
      ),
    );
    // デッキは /home の上に push した画面（決定済み事項 8）。
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => DeckScreen(
            columnBuilder: (column) =>
                SizedBox.expand(key: ValueKey('stub-${column.id}')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(container.read(mountedDeckCountProvider), 1);

    // 閉じるアニメーションの途中。
    navigator.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(DeckScreen), findsOneWidget, reason: 'まだマウントされている');
    expect(
      container.read(mountedDeckCountProvider),
      0,
      reason: 'dispose を待たずに抜ける（通知の経路が振り替えられるように）',
    );

    container.read(pendingDeckNotificationsProvider.notifier).state = _other;
    await tester.pumpAndSettle();

    expect(container.read(pendingDeckNotificationsProvider), _other);
    expect(container.read(deckColumnsProvider), hasLength(1), reason: '足さない');
    expect(find.byType(DeckScreen), findsNothing);
    expect(container.read(mountedDeckCountProvider), 0, reason: '二重に減らさない');
  });

  testWidgets('⚠ アカウントは切り替えない（デッキでは読み直しを起こす）', (tester) async {
    final container = await pumpDeck(tester, [
      'a|misskey://me@misskey.example|hashtag:a',
    ]);

    await tap(tester, container, _other);

    expect(container.read(accountManagerProvider).current?.key, _me);
  });
}
