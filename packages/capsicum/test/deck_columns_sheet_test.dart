import 'package:capsicum/src/model/account.dart';
import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/provider/preferences_provider.dart';
import 'package:capsicum/src/ui/widget/deck_columns_sheet.dart';
import 'package:capsicum/src/ui/widget/user_avatar.dart';
import 'package:capsicum/src/util/shared_preferences_cache.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #1093: カラムの追加・削除（並べ替えの永続化は `deck_columns_test`）。
class _Adapter extends Mock implements DecentralizedBackendAdapter {
  @override
  AdapterCapabilities get capabilities => _Capabilities();
}

class _Capabilities extends Mock implements AdapterCapabilities {
  @override
  Set<TimelineType> get supportedTimelines => {
    TimelineType.home,
    TimelineType.local,
    TimelineType.federated,
  };
}

/// 先頭が現在のアカウントになるアカウント管理。
class _TwoAccounts extends AccountManagerNotifier {
  _TwoAccounts(this._accounts);

  final List<Account> _accounts;

  @override
  AccountManagerState build() =>
      AccountManagerState(accounts: _accounts, current: _accounts.first);
}

const _me = AccountKey(
  type: BackendType.mastodon,
  host: 'mstdn.example',
  username: 'me',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<ProviderContainer> pumpSheet(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    initSharedPreferencesCache(await SharedPreferences.getInstance());
    tester.view.physicalSize = const Size(600, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final container = ProviderContainer(
      overrides: [
        currentAccountProvider.overrideWith(
          (ref) => Account(
            key: _me,
            adapter: _Adapter(),
            user: const User(id: 'me', username: 'me'),
            userSecret: const UserSecret(accessToken: 'token'),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: DeckColumnsSheet())),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  Finder candidate(String identityKey) =>
      find.byKey(ValueKey('candidate-$identityKey'));

  testWidgets('候補をタップするとカラムが足され、同じものを重ねて足せる', (tester) async {
    final container = await pumpSheet(tester);

    await tester.tap(candidate('timeline:home'));
    await tester.pumpAndSettle();
    await tester.tap(candidate('timeline:home'));
    await tester.pumpAndSettle();

    final columns = container.read(deckColumnsProvider);
    expect(columns, hasLength(2));
    expect(columns.every((c) => c.account == _me), isTrue);
    expect(columns[0].id, isNot(columns[1].id));
  });

  testWidgets('ハッシュタグを入力してカラムを足せる', (tester) async {
    final container = await pumpSheet(tester);

    await tester.enterText(find.byType(TextField), '#delmulin');
    await tester.tap(find.byTooltip('ハッシュタグのカラムを追加'));
    await tester.pumpAndSettle();

    expect(
      container.read(deckColumnsProvider).single.tab,
      const HashtagTab('delmulin'),
    );
  });

  testWidgets('⚠ 重複カラムの片方を削除すると、その 1 本だけが消える（id で指す）', (tester) async {
    final container = await pumpSheet(tester);
    await tester.tap(candidate('timeline:home'));
    await tester.pumpAndSettle();
    await tester.tap(candidate('timeline:home'));
    await tester.pumpAndSettle();
    final [first, second] = container.read(deckColumnsProvider);

    // 2 本目の削除ボタン。
    await tester.tap(find.byTooltip('カラムを削除').at(1));
    await tester.pumpAndSettle();

    expect(container.read(deckColumnsProvider).map((c) => c.id), [first.id]);
    expect(second.id, isNot(first.id));
  });

  testWidgets('⚠ アカウントを選ぶと、そのアカウントのカラムとして足される (#1096)', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    initSharedPreferencesCache(await SharedPreferences.getInstance());
    tester.view.physicalSize = const Size(600, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const other = AccountKey(
      type: BackendType.mastodon,
      host: 'mstdn.example',
      username: 'other',
    );
    Account account(AccountKey key) => Account(
      key: key,
      adapter: _Adapter(),
      user: User(id: key.username, username: key.username),
      userSecret: const UserSecret(accessToken: 'token'),
    );
    final container = ProviderContainer(
      overrides: [
        accountManagerProvider.overrideWith(
          () => _TwoAccounts([account(_me), account(other)]),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: DeckColumnsSheet())),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('deck-account-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('@other@mstdn.example').last);
    await tester.pumpAndSettle();
    await tester.tap(candidate('timeline:home'));
    await tester.pumpAndSettle();

    expect(container.read(deckColumnsProvider).single.account, other);
  });

  testWidgets('アカウントの選択肢にアイコンと表示名を添える', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    initSharedPreferencesCache(await SharedPreferences.getInstance());
    tester.view.physicalSize = const Size(600, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const other = AccountKey(
      type: BackendType.mastodon,
      host: 'mstdn.example',
      username: 'other',
    );
    Account account(AccountKey key, String name) => Account(
      key: key,
      adapter: _Adapter(),
      user: User(id: key.username, username: key.username, displayName: name),
      userSecret: const UserSecret(accessToken: 'token'),
    );
    final container = ProviderContainer(
      overrides: [
        accountManagerProvider.overrideWith(
          () => _TwoAccounts([account(_me, 'わたし'), account(other, 'べつのわたし')]),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: DeckColumnsSheet())),
      ),
    );
    await tester.pumpAndSettle();

    final selector = find.byKey(const ValueKey('deck-account-selector'));
    // 閉じた状態でも、選ばれているアカウントの表示名とアイコンが見える。
    expect(
      find.descendant(of: selector, matching: find.text('わたし')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: selector, matching: find.byType(UserAvatar)),
      findsOneWidget,
    );

    await tester.tap(selector);
    await tester.pumpAndSettle();
    expect(find.text('べつのわたし'), findsOneWidget);
    expect(find.text('@other@mstdn.example'), findsOneWidget);
  });

  testWidgets('カラム 0 本の状態が壊れない', (tester) async {
    final container = await pumpSheet(tester);
    await tester.tap(candidate('timeline:local'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('カラムを削除'));
    await tester.pumpAndSettle();

    expect(container.read(deckColumnsProvider), isEmpty);
    expect(find.text('カラムがありません'), findsOneWidget);
  });

  /// モーダルとして開く版（#1229 の戻り値を見るため）。返るのは
  /// `showDeckColumnsSheet` の結果を順に溜める配列。
  ///
  /// ⚠ 上の [pumpSheet] は `Scaffold` の body に直接置いているので、
  /// **`Navigator.pop` の戻り値を観測できない**（押すとルートごと落ちる）。
  Future<(ProviderContainer, List<String?>)> pumpModalSheet(
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    initSharedPreferencesCache(await SharedPreferences.getInstance());
    tester.view.physicalSize = const Size(600, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final container = ProviderContainer(
      overrides: [
        currentAccountProvider.overrideWith(
          (ref) => Account(
            key: _me,
            adapter: _Adapter(),
            user: const User(id: 'me', username: 'me'),
            userSecret: const UserSecret(accessToken: 'token'),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    final results = <String?>[];
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async =>
                    results.add(await showDeckColumnsSheet(context)),
                child: const Text('開く'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('開く'));
    await tester.pumpAndSettle();
    return (container, results);
  }

  group('一覧のカラムを押すとそこへ移動する (#1229)', () {
    testWidgets('⚠ 押したカラムの id を返して閉じる', (tester) async {
      final (container, results) = await pumpModalSheet(tester);
      await tester.tap(candidate('timeline:home'));
      await tester.pumpAndSettle();
      await tester.tap(candidate('timeline:local'));
      await tester.pumpAndSettle();
      final [first, second] = container.read(deckColumnsProvider);

      await tester.tap(find.byKey(ValueKey(second.id)));
      await tester.pumpAndSettle();

      expect(results, [second.id]);
      expect(second.id, isNot(first.id), reason: '2 本目を指している');
      // ⚠ 並べ替えや削除と違い、**列そのものは変えない**（送るだけ）。
      expect(container.read(deckColumnsProvider), hasLength(2));
    });

    testWidgets('⚠⚠ 削除ボタンを押したときは移動しない（閉じない）', (tester) async {
      final (container, results) = await pumpModalSheet(tester);
      await tester.tap(candidate('timeline:home'));
      await tester.pumpAndSettle();
      await tester.tap(candidate('timeline:local'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('カラムを削除').at(1));
      await tester.pumpAndSettle();

      // 🔴 行全体のタップが削除まで拾うと、ここで閉じてしまう。
      expect(results, isEmpty, reason: 'シートは開いたまま');
      expect(container.read(deckColumnsProvider), hasLength(1));
    });

    testWidgets('⚠ 閉じるボタンでは何も返さない', (tester) async {
      final (_, results) = await pumpModalSheet(tester);
      await tester.tap(candidate('timeline:home'));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();

      expect(results, [null], reason: '移動の指示ではない');
    });

    testWidgets('⚠ 見出しで押せることを言う。ただし 1 本のときは言わない', (tester) async {
      await pumpModalSheet(tester);
      await tester.tap(candidate('timeline:home'));
      await tester.pumpAndSettle();
      expect(find.text('カラム'), findsOneWidget);
      expect(find.text('カラム（押すと移動）'), findsNothing);

      await tester.tap(candidate('timeline:local'));
      await tester.pumpAndSettle();
      expect(find.text('カラム（押すと移動）'), findsOneWidget);
    });
  });
}
