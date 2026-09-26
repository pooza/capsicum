import 'package:capsicum/src/model/account.dart';
import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/provider/preferences_provider.dart';
import 'package:capsicum/src/ui/screen/deck_screen.dart';
import 'package:capsicum/src/ui/widget/livecure_filter_button.dart';
import 'package:capsicum/src/util/shared_preferences_cache.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #1173: デッキの AppBar に何を置くか（`docs/deck-ui-plan.md` 決定済み事項 7-3）。
class _Adapter extends Mock implements DecentralizedBackendAdapter {}

Account _account(String username) => Account(
  key: AccountKey(
    type: BackendType.misskey,
    host: 'misskey.example',
    username: username,
  ),
  adapter: _Adapter(),
  user: User(id: username, username: username),
  userSecret: const UserSecret(accessToken: 'token'),
);

class _TestAccountNotifier extends AccountManagerNotifier {
  _TestAccountNotifier(this._accounts);

  final List<Account> _accounts;

  @override
  AccountManagerState build() =>
      AccountManagerState(accounts: _accounts, current: _accounts.first);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<ProviderContainer> pumpDeck(
    WidgetTester tester, {
    Size size = const Size(800, 600),
    List<String> columnIds = const ['a'],
  }) async {
    SharedPreferences.setMockInitialValues({
      'deck_columns': [
        for (final id in columnIds)
          '$id|misskey://me@misskey.example|hashtag:$id',
      ],
    });
    initSharedPreferencesCache(await SharedPreferences.getInstance());
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final container = ProviderContainer(
      overrides: [
        accountManagerProvider.overrideWith(
          () => _TestAccountNotifier([_account('me')]),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: DeckScreen(
            columnBuilder: (column) => ColoredBox(
              key: ValueKey('stub-${column.id}'),
              color: const Color(0xFF202020),
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('⚠ 実況の切り替えがデッキにもある（モバイルには入口が無かった）', (tester) async {
    final container = await pumpDeck(tester);

    expect(find.byType(LivecureFilterButton), findsOneWidget);
    final before = container.read(hideLivecureProvider);

    await tester.tap(find.byType(LivecureFilterButton));
    await tester.pumpAndSettle();

    expect(
      container.read(hideLivecureProvider),
      !before,
      reason: '⚠ ボタンが置いてあるだけでなく、実際に設定が反転すること',
    );
  });

  testWidgets('⚠ ライブ更新の接続インジケータは置かない（カラムの見出しにある）', (tester) async {
    await pumpDeck(tester, columnIds: const ['a', 'b']);

    // 決定済み事項 7-2 / 7-3。画面共通に 1 個置くと「N 本ある購読のどれの状態でも
    // ないもの」を出すことになる（#793 の再発）。⚠ カラムの見出しの接続ドットは
    // 中身を差し替えているこの検査には出ない（`deck_column_view` 側の検査が持つ）。
    expect(find.byIcon(Icons.wifi), findsNothing);
    expect(find.byIcon(Icons.wifi_off), findsNothing);
  });

  testWidgets('狭幅（375px）でも AppBar が overflow しない', (tester) async {
    await pumpDeck(tester, size: const Size(375, 700));

    expect(tester.takeException(), isNull);
  });
}
