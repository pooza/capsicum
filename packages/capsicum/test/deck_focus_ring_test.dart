import 'package:capsicum/src/model/account.dart';
import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/provider/deck_provider.dart';
import 'package:capsicum/src/provider/preferences_provider.dart';
import 'package:capsicum/src/ui/screen/deck_screen.dart';
import 'package:capsicum/src/ui/util/deck_layout.dart';
import 'package:capsicum/src/ui/widget/deck_column_focus.dart';
import 'package:capsicum/src/util/shared_preferences_cache.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #1172: フォーカス中のカラムの見せ方と、フォーカスが移る契機
/// （`docs/deck-ui-plan.md` 決定済み事項 10）。
///
/// ⚠⚠ **スクロールでは移さないことが肝。**ホイールやトラックパッドで読むだけの
/// ことが多いので、そこで移すと**読んでいたカラムのアカウントで ⌘N が開く**。
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

  /// カラム id の列でデッキを開く。中身は差し替えて軽くする。
  Future<ProviderContainer> pumpDeck(
    WidgetTester tester, {
    required Size size,
    required List<String> columnIds,
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

  String? focusedId(ProviderContainer container) =>
      container.read(deckFocusProvider).columnId;

  final pager = find.byWidgetPredicate(
    (w) =>
        w is Scrollable &&
        w.axisDirection == AxisDirection.right &&
        w.physics is DeckSnapScrollPhysics,
  );

  testWidgets('⚠ カラムが 1 本しかないときは枠を出さない', (tester) async {
    final container = await pumpDeck(
      tester,
      size: const Size(800, 600),
      columnIds: const ['a'],
    );

    expect(focusedId(container), 'a', reason: 'フォーカス自体はある（⌘N の宛先）');
    expect(
      find.byKey(deckFocusRingKey('a')),
      findsNothing,
      reason: '⚠ 1 本だけなら「どれか」を示す必要が無い',
    );
    expect(
      tester
          .widget<DeckColumnFocusRing>(find.byType(DeckColumnFocusRing))
          .showRing,
      isFalse,
    );
  });

  testWidgets('2 本以上なら、フォーカス中のカラムにだけ枠が出る', (tester) async {
    final container = await pumpDeck(
      tester,
      size: const Size(800, 600),
      columnIds: const ['a', 'b'],
    );

    expect(focusedId(container), 'a');
    expect(find.byKey(deckFocusRingKey('a')), findsOneWidget);
    expect(find.byKey(deckFocusRingKey('b')), findsNothing);
  });

  testWidgets('⚠ カラムの中を押すとフォーカスが移り、枠も移る', (tester) async {
    final container = await pumpDeck(
      tester,
      size: const Size(800, 600),
      columnIds: const ['a', 'b'],
    );

    await tester.tap(find.byKey(const ValueKey('stub-b')));
    await tester.pumpAndSettle();

    expect(focusedId(container), 'b');
    expect(find.byKey(deckFocusRingKey('b')), findsOneWidget);
    expect(find.byKey(deckFocusRingKey('a')), findsNothing);
  });

  testWidgets('⚠⚠ ポインタスクロール（ホイール / トラックパッド）では移らない', (tester) async {
    final container = await pumpDeck(
      tester,
      size: const Size(800, 600),
      columnIds: const ['a', 'b', 'c', 'd'],
    );
    expect(focusedId(container), 'a');

    // b〜d が見える位置まで横へ送る。⚠ ここで使うのは PointerScrollEvent で、
    // pointerDown は起きない。
    final center = tester.getCenter(pager);
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(center));
    await tester.sendEventToBinding(pointer.scroll(const Offset(600, 0)));
    await tester.pumpAndSettle();

    // ⚠⚠ **空振りしていないことを先に見る。**スクロールが 1px も動いていない
    // なら、下の expect は「移らなかった」ではなく「何も起きなかった」を見ている。
    expect(
      tester.state<ScrollableState>(pager).position.pixels,
      greaterThan(0),
      reason: '⚠ 実際に横へ送れていること',
    );
    expect(
      focusedId(container),
      'a',
      reason: '⚠⚠ 読むだけでフォーカスが移ると、⌘N の宛先が勝手に変わる',
    );
  });

  testWidgets('⚠ 狭幅（1 本ずつ）では、横に送るとフォーカスが移る', (tester) async {
    final container = await pumpDeck(
      tester,
      size: const Size(390, 700),
      columnIds: const ['a', 'b', 'c'],
    );
    expect(focusedId(container), 'a');

    // 1 カラムぶん左へ送る（ページャなのでカラムの境界で止まる）。
    await tester.drag(pager, const Offset(-390, 0));
    await tester.pumpAndSettle();

    expect(focusedId(container), 'b');
  });

  testWidgets('⚠ 枠の条件は「列に 2 本以上」で、「見えているのが 2 本以上」ではない', (tester) async {
    await pumpDeck(
      tester,
      size: const Size(390, 700),
      columnIds: const ['a', 'b'],
    );

    // 狭幅なので見えているのは 1 本だが、列に 2 本あるので枠は出る。⚠ 送った先で
    // 「今どれを見ているか」が分かるので、こちらのほうが親切（害は無い）。
    expect(find.byKey(deckFocusRingKey('a')), findsOneWidget);
  });

  testWidgets('カラムから開いたカラムはフォーカスになり、点滅が要求される', (tester) async {
    final container = await pumpDeck(
      tester,
      size: const Size(800, 600),
      columnIds: const ['a', 'b'],
    );
    final before = container.read(deckFocusProvider).blinkToken;

    final columns = container.read(deckColumnsProvider.notifier);
    final opened = await columns.insertAfter(
      'a',
      const AccountKey(
        type: BackendType.misskey,
        host: 'misskey.example',
        username: 'me',
      ),
      const PostThreadTab('9zx8abc'),
    );
    container.read(deckFocusProvider.notifier).focusAndBlink(opened.id);
    await tester.pumpAndSettle();

    expect(focusedId(container), opened.id);
    expect(container.read(deckFocusProvider).blinkToken, before + 1);
    expect(find.byKey(deckFocusRingKey(opened.id)), findsOneWidget);
  });
}
