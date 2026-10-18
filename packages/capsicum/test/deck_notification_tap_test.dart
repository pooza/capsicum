import 'package:capsicum/src/model/account.dart';
import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/provider/deck_provider.dart';
import 'package:capsicum/src/provider/preferences_provider.dart';
import 'package:capsicum/src/ui/screen/deck_screen.dart';
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
          lastMode: LastViewMode.tabs,
          hasColumns: false,
        ),
        isTrue,
      );
    });

    test('⚠ 閉じていても、前回デッキで終えていて列があればデッキ（起動時）', () {
      expect(
        notificationTapGoesToDeck(
          deckOpen: false,
          lastMode: LastViewMode.deck,
          hasColumns: true,
        ),
        isTrue,
      );
    });

    test('タブ UI で使っていればタブ UI（従来どおり）', () {
      expect(
        notificationTapGoesToDeck(
          deckOpen: false,
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
          lastMode: LastViewMode.deck,
          hasColumns: false,
        ),
        isFalse,
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

  testWidgets('⚠ アカウントは切り替えない（デッキでは読み直しを起こす）', (tester) async {
    final container = await pumpDeck(tester, [
      'a|misskey://me@misskey.example|hashtag:a',
    ]);

    await tap(tester, container, _other);

    expect(container.read(accountManagerProvider).current?.key, _me);
  });
}
