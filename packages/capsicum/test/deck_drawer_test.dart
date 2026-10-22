import 'package:capsicum/src/model/account.dart';
import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/provider/account_manager_provider.dart';
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

/// #1272: デッキにも、タブ表示と同じドロワーを置く（2026-10-11 pooza）。
///
/// メニューバーの無い端末では、ブックマーク・予約投稿などへデッキから届かず、
/// 使うたびにタブ表示へ切り替える必要があった。
class _Adapter extends Mock implements DecentralizedBackendAdapter {}

class _ListAdapter extends Mock
    implements DecentralizedBackendAdapter, ListSupport {}

Account _account(String username, [DecentralizedBackendAdapter? adapter]) =>
    Account(
      key: AccountKey(
        type: BackendType.misskey,
        host: 'misskey.example',
        username: username,
      ),
      adapter: adapter ?? _Adapter(),
      user: User(id: username, username: username),
      userSecret: const UserSecret(accessToken: 'token'),
    );

class _TestAccountNotifier extends AccountManagerNotifier {
  _TestAccountNotifier(this._accounts);

  final List<Account> _accounts;

  @override
  AccountManagerState build() =>
      AccountManagerState(accounts: _accounts, current: _accounts.first);

  @override
  Future<void> refreshCurrentServerMetadata() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<ProviderContainer> pumpDeck(
    WidgetTester tester, {
    Size size = const Size(375, 700),
    List<String> usernames = const ['me'],
    DecentralizedBackendAdapter? adapter,
  }) async {
    SharedPreferences.setMockInitialValues({
      'deck_columns': ['a|misskey://me@misskey.example|hashtag:a'],
    });
    initSharedPreferencesCache(await SharedPreferences.getInstance());
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final container = ProviderContainer(
      overrides: [
        accountManagerProvider.overrideWith(
          () => _TestAccountNotifier([
            for (final u in usernames)
              _account(u, u == usernames.first ? adapter : null),
          ]),
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

  Future<void> openDrawer(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
  }

  testWidgets('左端のハンバーガーからドロワーが開き、タブ表示と同じ項目が並ぶ', (tester) async {
    await pumpDeck(tester);

    expect(
      find.byType(Drawer),
      findsNothing,
      reason: '常駐はさせない（決定済み事項 7-1 / 8）',
    );
    await openDrawer(tester);

    expect(find.byType(Drawer), findsOneWidget);
    // どのサーバーでも出る項目で、デッキの AppBar には入口が無いもの。
    expect(find.text('サーバー情報'), findsOneWidget);
    expect(find.text('アカウントを追加'), findsOneWidget);
    // 「ログアウト」から言い換えた (#1297)。
    expect(find.text('このアカウントをこの端末から削除'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('⚠ 右側のアイコンは 6 つのまま、狭幅でも潰れない (#1242)', (tester) async {
    await pumpDeck(tester);

    expect(find.byTooltip('設定'), findsOneWidget);
    expect(find.byTooltip('タブ表示に切り替え'), findsOneWidget);
    expect(find.byTooltip('カラム編集'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('⚠⚠ アカウントの切り替えは持ち込まない（決定済み事項 8 / 11）', (tester) async {
    await pumpDeck(tester, usernames: const ['me', 'other']);
    await openDrawer(tester);

    expect(find.text('アカウント切替'), findsNothing);
    expect(
      find.text('@other@misskey.example'),
      findsNothing,
      reason: '押すと現在のアカウントが変わり、カラムのコンテナの割り当てが組み替わる',
    );
  });

  testWidgets('⚠ 「デッキ」と、AppBar に入口のある検索・通知は出さない', (tester) async {
    await pumpDeck(tester, usernames: const ['me', 'other']);
    await openDrawer(tester);

    final drawer = find.byType(Drawer);
    for (final title in ['デッキ', '検索', '通知', 'すべての通知']) {
      expect(
        find.descendant(of: drawer, matching: find.text(title)),
        findsNothing,
        reason: title,
      );
    }
  });

  testWidgets('⚠⚠ リストは全画面ではなく、フォーカス中のカラムの右隣にカラムで開く', (tester) async {
    // 2026-10-12 pooza: 選ぶとタイムラインになるものだけカラムで開く。
    final adapter = _ListAdapter();
    when(
      adapter.getLists,
    ).thenAnswer((_) async => const [PostList(id: 'l1', title: 'L1')]);
    final container = await pumpDeck(
      tester,
      size: const Size(800, 700),
      adapter: adapter,
    );
    await openDrawer(tester);

    await tester.tap(find.text('リスト'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('L1'));
    await tester.pumpAndSettle();

    final columns = container.read(deckColumnsProvider);
    expect(columns, hasLength(2), reason: '全画面へ push されると列は増えない');
    expect(columns[0].id, 'a');
    expect(columns[1].tab, const ListTab(id: 'l1', name: 'L1'));
    expect(
      columns[1].account,
      container.read(currentAccountKeyProvider),
      reason: 'ドロワーの項目は現在のアカウントのもの。一覧もそのアダプタで引いている',
    );
    expect(find.byType(Drawer), findsNothing, reason: 'ドロワーは閉じている');
    expect(tester.takeException(), isNull);
  });

  testWidgets('⚠⚠ 左端からのスワイプでは開かない（カラムの横送りと競合する）', (tester) async {
    await pumpDeck(tester);

    await tester.dragFrom(const Offset(2, 350), const Offset(300, 0));
    await tester.pumpAndSettle();

    expect(find.byType(Drawer), findsNothing);
  });
}
