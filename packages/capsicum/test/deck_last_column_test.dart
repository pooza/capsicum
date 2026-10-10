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

/// #1239: デッキを開いたとき、最後に見ていたカラムの位置から始まる。
///
/// ⚠ 以前は毎回、左端（狭幅では一番上）から始まっていた。フォーカスは覚えて
/// いても、横スクロールが 0 から始まっていたため。
class _Adapter extends Mock implements DecentralizedBackendAdapter {}

final _account = Account(
  key: const AccountKey(
    type: BackendType.misskey,
    host: 'misskey.example',
    username: 'me',
  ),
  adapter: _Adapter(),
  user: const User(id: 'me', username: 'me'),
  userSecret: const UserSecret(accessToken: 'token'),
);

class _TestAccountNotifier extends AccountManagerNotifier {
  @override
  AccountManagerState build() =>
      AccountManagerState(accounts: [_account], current: _account);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<ProviderContainer> pumpDeck(
    WidgetTester tester, {
    required Size size,
    String? lastColumn,
  }) async {
    SharedPreferences.setMockInitialValues({
      'deck_columns': [
        for (final id in ['a', 'b', 'c', 'd'])
          '$id|misskey://me@misskey.example|hashtag:$id',
      ],
      'deck_last_column': ?lastColumn,
    });
    initSharedPreferencesCache(await SharedPreferences.getInstance());
    tester.view.physicalSize = size;
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

  double left(WidgetTester tester, String id) =>
      tester.getTopLeft(find.byKey(ValueKey('stub-$id'))).dx;

  testWidgets('⚠ 狭幅: 最後に見ていたカラムから始まる', (tester) async {
    final container = await pumpDeck(
      tester,
      size: const Size(375, 700),
      lastColumn: 'c',
    );

    expect(left(tester, 'c'), closeTo(0, 1), reason: '左端（a）から始まっている');
    expect(container.read(deckFocusProvider).columnId, 'c');
  });

  testWidgets('覚えているカラムが無ければ、先頭から始まる（従来どおり）', (tester) async {
    await pumpDeck(tester, size: const Size(375, 700));

    expect(left(tester, 'a'), closeTo(0, 1));
  });

  testWidgets('⚠ 列に居ないカラムを覚えていても、先頭から始まる', (tester) async {
    final container = await pumpDeck(
      tester,
      size: const Size(375, 700),
      lastColumn: 'gone',
    );

    expect(left(tester, 'a'), closeTo(0, 1));
    expect(container.read(deckFocusProvider).columnId, 'a');
  });

  testWidgets('広幅: 最後に見ていたカラムが画面に入っている', (tester) async {
    final container = await pumpDeck(
      tester,
      size: const Size(800, 600),
      lastColumn: 'd',
    );

    final x = left(tester, 'd');
    expect(x, greaterThanOrEqualTo(0));
    expect(x, lessThan(800), reason: '画面の外に残っている');
    expect(container.read(deckFocusProvider).columnId, 'd');
  });

  testWidgets('開いている間は「デッキ」、戻ると「タブ UI」と記録する', (tester) async {
    await pumpDeck(tester, size: const Size(375, 700));
    expect(readLastViewMode(), LastViewMode.deck);

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pumpAndSettle();

    expect(readLastViewMode(), LastViewMode.tabs);
  });

  testWidgets('⚠⚠ アプリが前面を離れてから捨てられた回は、「タブ UI」と書かない', (tester) async {
    // デッキを開いたまま終了した人が、次回タブ UI で始まってしまう。
    //
    // ⚠ **`inactive` で見る。**`hidden` / `paused` のあいだは Flutter がフレームを
    // 描かないので、画面の破棄そのものが起きない（＝そこで見ても何も確かめて
    // いない。最初はそう書いて、判定を外しても緑のままだった）。
    await pumpDeck(tester, size: const Size(375, 700));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();

    expect(find.byType(DeckScreen), findsNothing, reason: '前提: 画面は捨てられている');
    expect(readLastViewMode(), LastViewMode.deck);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });
}
